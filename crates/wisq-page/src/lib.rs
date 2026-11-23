//! **L'émetteur dans la page.**
//!
//! Aujourd'hui une région se traduit par un aller-retour : la page lit la
//! fenêtre, l'envoie à Swift par `postMessage`, Swift appelle l'émetteur par le
//! C ABI, puis renvoie le module sous forme de source JavaScript que la page
//! analyse. La CI l'a relevé entre 5,35 et 8,68 ms par région sur un iPhone
//! simulé (`docs/DEMARRAGE.md`), soit 80 à 135 s pour les quinze mille régions
//! d'un noyau. Presque tout ce temps est du transport.
//!
//! Ce crate supprime le transport : il compile **le même émetteur**
//! (`wisq_vm::x86_wasm::Module::resolving_or_why`, sans une ligne recopiée) en
//! un module WebAssembly que la page instancie une fois, à côté de sa boucle
//! hôte. Une traduction devient un appel de fonction dans le même fil.
//!
//! **Le contrat, en quatre exports**, lus par `web/page-emitter.js` :
//!
//! - `allouer(longueur) → adresse` : la place où la page copie sa fenêtre ;
//! - `emettre(longueur, base, entree, emplacement, pages) → code` : traduit
//!   les `longueur` premiers octets posés là ; rend la longueur du module
//!   (≥ 0), [`ENCORE`] quand la première instruction a pu être coupée par le
//!   bord, [`REFUS`] pour un refus franc, [`MAL_FORME`] pour un appel qui ne
//!   tient pas ;
//! - `dernier() → adresse` : le dernier résultat — les octets du module, ou,
//!   après un refus, **pourquoi**, en texte (la forme `{:?}` de
//!   `Refused`, la même que `x86-translate` écrit sur sa sortie d'erreur) ;
//! - `taille() → longueur` : la longueur de ce dernier résultat.
//!
//! **Pourquoi ces fonctions ne sont pas `pub`.** Ce ne sont pas des fonctions
//! Rust que quelqu'un appelle, ce sont les exports d'un module WebAssembly : ce
//! qui les exporte est `#[no_mangle]`, pas la visibilité. Elles ne font pas non
//! plus partie du C ABI de l'application — lui vit en entier dans
//! `crates/wisq-vm/src/ffi.rs`, l'application le lie, et le site le compte.
//! Celles-ci ne sont jamais liées dans l'application : seule la page les
//! appelle, à travers `WebAssembly.Instance`.
//!
//! **Pourquoi un seul fil d'état.** Une page n'a qu'un fil pour sa boucle, et
//! l'émetteur ne garde rien d'une région à l'autre ; l'état se réduit aux deux
//! tampons (l'entrée et le dernier résultat). Le `Mutex` ne sert qu'à le dire
//! au compilateur sans `static mut` : sur `wasm32-unknown-unknown` sans fils,
//! il ne coûte rien.
//!
//! **Ce qu'une trappe laisse derrière elle.** Le profil `release` du workspace
//! a `panic = "abort"` : dans la page, un panic — ou une allocation qui
//! échoue — est une trappe `unreachable`, et rien n'est déroulé. Le verrou
//! reste donc pris, et chaque appel suivant de cette instance trappe à son
//! tour (reproduit sous Bun). Ce n'est pas réparable de l'intérieur : une
//! instance trappée a pu s'arrêter au milieu de n'importe quoi. C'est
//! `web/page-emitter.js` qui la jette et en recrée une, et
//! `tests/page.rs` qui le juge.
//!
//! **Et la carte de la machine PC.** Le même module porte les périphériques
//! que la boucle hôte ne modélise pas — l'i8042 et l'horloge CMOS d'abord —,
//! derrière une seconde famille d'exports, préfixés `carte_` : voir
//! [`carte`]. `web/carte.js` les sert à `host.js`. Les périphériques sont le
//! crate `wisq-carte` (`src/carte/`), que la machine native prend aussi ; les
//! exports, qui ne valent que pour la page, sont ici (`carte_porte`).

/// **La carte de la machine PC** : le crate `wisq-carte`, sous le nom qu'il
/// avait quand il était un module d'ici.
pub use wisq_carte as carte;

mod carte_porte;
pub mod hote;
pub mod puces;
pub mod secours;

use std::sync::Mutex;

use wisq_vm::x86_wasm::{Module, Refused};

/// **« Il m'en faut plus. »** La première instruction s'est arrêtée à moins de
/// quinze octets du bord : elle a pu être coupée. La page redemande la même
/// région avec une fenêtre plus large — c'est le `"encore"` de `web/host.js`.
pub const ENCORE: i32 = -1;

/// **Un refus franc** : une instruction que le décodeur ne lit pas, ou que
/// l'émetteur ne sait pas traduire, ou une RAM qui n'est pas une puissance de
/// deux. Redemander n'apporterait rien ; `dernier()` dit lequel.
pub const REFUS: i32 = -2;

/// **L'appel lui-même ne tient pas** : la page annonce plus d'octets qu'elle
/// n'en a alloué. Distinct d'un refus de l'émetteur, parce qu'il se corrige
/// dans le JavaScript et pas dans le décodeur.
pub const MAL_FORME: i32 = -3;

struct Porte {
    /// La fenêtre, telle que la page l'a copiée.
    entree: Vec<u8>,
    /// Le module rendu, ou la raison du refus.
    dernier: Vec<u8>,
}

static PORTE: Mutex<Porte> = Mutex::new(Porte {
    entree: Vec::new(),
    dernier: Vec::new(),
});

fn porte() -> std::sync::MutexGuard<'static, Porte> {
    // **L'empoisonnement ne sert qu'aux tests natifs**, où un panic se
    // déroule et lâche le verrou : les deux tampons y sont réécrits en entier
    // à chaque appel, donc rien d'à moitié écrit ne vaut d'être protégé. Dans
    // la page il n'y a pas de déroulement, et pas d'empoisonnement non plus :
    // voir « Ce qu'une trappe laisse derrière elle », plus haut.
    PORTE.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// **La place où copier la fenêtre**, d'au moins `longueur` octets.
///
/// L'adresse ne vaut que jusqu'au prochain appel : `emettre` peut faire
/// grandir la mémoire du module, et `allouer` peut déplacer le tampon. La page
/// la redemande donc à chaque région — un appel, pas une copie.
#[no_mangle]
extern "C" fn allouer(longueur: u32) -> *mut u8 {
    let mut porte = porte();
    porte.entree.resize(longueur as usize, 0);
    porte.entree.as_mut_ptr()
}

/// **Traduire la fenêtre posée par `allouer`**, exactement comme
/// `Module::resolving_or_why(fenêtre, base, entree, emplacement, pages)`.
#[no_mangle]
extern "C" fn emettre(longueur: u32, base: u64, entree: u32, emplacement: u32, pages: u32) -> i32 {
    let mut porte = porte();
    let Porte {
        entree: fenetre,
        dernier,
    } = &mut *porte;
    let Some(octets) = fenetre.get(..longueur as usize) else {
        *dernier = format!(
            "appel mal formé : {longueur} octets annoncés, {} alloués",
            fenetre.len()
        )
        .into_bytes();
        return MAL_FORME;
    };
    match Module::resolving_for_page_or_why(octets, base, entree as usize, emplacement, pages) {
        Ok(module) => {
            *dernier = module;
            // Un module tient toujours dans un `i32` : il traduit au plus une
            // fenêtre de seize kibioctets. Le dire plutôt que tronquer.
            i32::try_from(dernier.len()).unwrap_or(MAL_FORME)
        }
        Err(pourquoi) => {
            let code = match pourquoi {
                Refused::MayBeCut { .. } => ENCORE,
                _ => REFUS,
            };
            *dernier = format!("{pourquoi:?}").into_bytes();
            code
        }
    }
}

/// **Le dernier résultat** : les octets du module, ou la raison du refus.
#[no_mangle]
extern "C" fn dernier() -> *const u8 {
    porte().dernier.as_ptr()
}

/// **La longueur du dernier résultat.**
#[no_mangle]
extern "C" fn taille() -> u32 {
    // Borné par la fenêtre, donc bien en deçà de 4 Gio.
    porte().dernier.len() as u32
}

#[cfg(test)]
mod tests {
    //! Les exports appelés en natif, comme la page les appelle : `allouer`,
    //! copier, `emettre`, puis lire `dernier()` sur `taille()` octets. Ce que
    //! ces tests jugent, c'est la porte — le passage des arguments et le
    //! classement des refus. Que le module wasm32 rende les mêmes octets sous
    //! un vrai moteur est le travail de `tests/page.rs`.
    use super::*;

    /// `mov $1,%eax ; ret` : une région de deux instructions.
    const PETIT: [u8; 6] = [0xb8, 0x01, 0x00, 0x00, 0x00, 0xc3];

    /// Les tests de ce module partagent la porte, et `cargo test` les lance
    /// en parallèle : chacun la tient d'un bout à l'autre de son appel.
    static UN_A_LA_FOIS: Mutex<()> = Mutex::new(());

    fn par_la_porte(fenetre: &[u8], base: u64, slot: u32, pages: u32) -> (i32, Vec<u8>) {
        let _tour = UN_A_LA_FOIS
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let longueur = u32::try_from(fenetre.len()).expect("une fenêtre de test");
        let place = allouer(longueur);
        // SAFETY : `allouer` vient de rendre au moins `longueur` octets à
        // cette adresse, et rien ne la déplace avant la copie.
        unsafe { std::ptr::copy_nonoverlapping(fenetre.as_ptr(), place, fenetre.len()) };
        let code = emettre(longueur, base, 0, slot, pages);
        // SAFETY : `dernier()` et `taille()` décrivent le même tampon, que
        // rien ne touche entre ces deux appels et la copie.
        let rendu = unsafe { std::slice::from_raw_parts(dernier(), taille() as usize) }.to_vec();
        (code, rendu)
    }

    #[test]
    fn the_gate_returns_the_very_module_the_emitter_builds() {
        let attendu = Module::resolving_or_why(&PETIT, 0x10_0000, 0, 7, 16).expect("traduit");
        let (code, rendu) = par_la_porte(&PETIT, 0x10_0000, 7, 16);
        assert_eq!(code, attendu.len() as i32, "la longueur rendue");
        assert_eq!(rendu, attendu, "les octets du module");
        // L'emplacement et la base sont dans les octets : un argument perdu
        // ou décalé en chemin rendrait un autre module.
        let ailleurs = Module::resolving_or_why(&PETIT, 0x20_0000, 0, 9, 16).expect("traduit");
        assert_ne!(ailleurs, attendu, "base et emplacement changent le module");
        assert_eq!(par_la_porte(&PETIT, 0x20_0000, 9, 16).1, ailleurs);
    }

    #[test]
    fn a_window_cut_inside_its_first_instruction_asks_for_more() {
        // `mov $imm32,%eax` coupé après deux octets : rien de complet avant.
        let (code, pourquoi) = par_la_porte(&PETIT[..2], 0x10_0000, 0, 16);
        assert_eq!(code, ENCORE);
        let pourquoi = String::from_utf8(pourquoi).expect("du texte");
        assert!(pourquoi.starts_with("MayBeCut"), "{pourquoi}");
    }

    #[test]
    fn a_frank_refusal_is_not_a_request_for_more_and_says_why() {
        // Seize pages n'est pas le problème, quinze l'est : la RAM doit être
        // une puissance de deux, et la raison doit le dire.
        let (code, pourquoi) = par_la_porte(&PETIT, 0x10_0000, 0, 15);
        assert_eq!(code, REFUS);
        assert_eq!(
            String::from_utf8(pourquoi).expect("du texte"),
            format!("{:?}", Refused::RamIsNotAPowerOfTwo(15))
        );
    }

    #[test]
    fn announcing_more_bytes_than_were_allocated_is_named() {
        let _tour = UN_A_LA_FOIS
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        allouer(4);
        assert_eq!(emettre(5, 0x10_0000, 0, 0, 16), MAL_FORME);
        // SAFETY : comme ci-dessus, un tampon que rien ne touche entre-temps.
        let pourquoi = unsafe { std::slice::from_raw_parts(dernier(), taille() as usize) };
        assert!(
            std::str::from_utf8(pourquoi)
                .expect("du texte")
                .contains("5 octets annoncés, 4 alloués"),
            "{pourquoi:?}"
        );
    }
}
