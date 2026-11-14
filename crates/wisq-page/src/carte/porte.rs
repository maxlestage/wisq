//! **La carte, exportée par le module de la page.**
//!
//! Le même module que l'émetteur (`wisq_page.wasm`), d'autres exports, tous
//! préfixés `carte_`. `web/carte.js` les lit et les sert à la boucle hôte ;
//! ce fichier ne fait que passer des nombres, la carte est dans
//! [`Carte`](super::Carte).
//!
//! **Une carte par instance.** L'état vit dans une `static` du module : deux
//! instances du même `WebAssembly.Module` ont deux mémoires, donc deux cartes.
//! `web/carte.js` instancie la sienne à part de celle de l'émetteur — une
//! trappe de l'émetteur fait jeter son instance (`web/page-emitter.js`), et
//! elle ne doit pas emporter le clavier et l'horloge avec elle.
//!
//! **Aucun import, toujours.** La carte ne lit ni la RAM ni l'heure par
//! elle-même : l'heure lui est posée (`carte_heure`), et aucun de ses
//! périphériques ne lit la RAM (ils reçoivent [`SansRam`]). Le module reste
//! donc instanciable avec `{}`, ce que l'émetteur suppose. Le premier
//! périphérique qui lira la RAM (une file virtio) ajoutera `ram_lire` et
//! `ram_ecrire`, et `web/page-emitter.js` devra alors les fournir aussi.
//!
//! **Pourquoi ces fonctions ne sont pas `pub`** : pour la même raison que
//! celles de l'émetteur (`lib.rs`). Ce sont les exports d'un module
//! WebAssembly, `#[no_mangle]` suffit ; elles ne font pas partie du C ABI de
//! l'application, que `crates/wisq-vm/src/ffi.rs` tient en entier.

use std::sync::{Mutex, MutexGuard};

use super::i8042::CodeTouche;
use super::{Carte, SansRam};

static CARTE: Mutex<Carte> = Mutex::new(Carte::nouvelle());
/// La place où la page copie un texte à taper, en UTF-8.
static TEXTE: Mutex<Vec<u8>> = Mutex::new(Vec::new());

/// **« Personne ici »**, pour une lecture de port : la boucle hôte rend alors
/// `0xff`. Négatif, donc distinct de toute valeur d'un port de 32 bits.
const PERSONNE: i64 = -1;

fn carte() -> MutexGuard<'static, Carte> {
    // Comme pour la porte de l'émetteur : l'empoisonnement ne sert qu'aux
    // tests natifs ; dans la page, un panic est une trappe sans déroulement.
    CARTE.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// **Lire un port.** La valeur (zéro-étendue), ou [`PERSONNE`].
#[no_mangle]
extern "C" fn carte_lire(port: u32, largeur: u32) -> i64 {
    let (Ok(port), Ok(largeur)) = (u16::try_from(port), u8::try_from(largeur)) else {
        return PERSONNE;
    };
    carte()
        .port_lire(port, largeur, &mut SansRam)
        .map_or(PERSONNE, i64::from)
}

/// **Écrire un port.** 1 si la carte l'a pris, 0 sinon.
#[no_mangle]
extern "C" fn carte_ecrire(port: u32, largeur: u32, valeur: u32) -> u32 {
    let (Ok(port), Ok(largeur)) = (u16::try_from(port), u8::try_from(largeur)) else {
        return 0;
    };
    u32::from(carte().port_ecrire(port, largeur, valeur, &mut SansRam))
}

/// Les seize lignes, à niveau.
#[no_mangle]
extern "C" fn carte_lignes() -> u32 {
    u32::from(carte().lignes())
}

/// Les lignes que la carte tient.
#[no_mangle]
extern "C" fn carte_tenues() -> u32 {
    u32::from(carte().tenues())
}

/// Lever une ligne du dehors : 1 si elle l'est, 0 si elle est refusée.
#[no_mangle]
extern "C" fn carte_lever(ligne: u32) -> u32 {
    u8::try_from(ligne).map_or(0, |ligne| u32::from(carte().lever(ligne)))
}

/// Baisser une ligne levée du dehors : 1, ou 0 si elle est refusée.
#[no_mangle]
extern "C" fn carte_baisser(ligne: u32) -> u32 {
    u8::try_from(ligne).map_or(0, |ligne| u32::from(carte().baisser(ligne)))
}

/// Le temps, en tics du 8254 depuis le départ de la machine.
#[no_mangle]
extern "C" fn carte_battre(tics: u64) {
    carte().battre(tics);
}

/// **L'heure UTC de l'hôte**, en millisecondes depuis 1970. Un `f64` parce
/// que c'est ce que rend `Date.now()`, exact jusqu'à 2⁵³ ms ; un `i64`
/// demanderait un `BigInt` de l'autre côté à chaque accès.
#[no_mangle]
extern "C" fn carte_heure(ms: f64) {
    // `as` sature, et un NaN devient zéro : aucune valeur ne fait trapper.
    carte().regler_heure(ms.floor() as i64);
}

fn code(jeu1: u32, etendue: u32) -> CodeTouche {
    CodeTouche {
        jeu1: jeu1 as u8,
        etendue: etendue != 0,
    }
}

/// Une touche posée tout de suite.
#[no_mangle]
extern "C" fn carte_touche(jeu1: u32, etendue: u32, enfoncee: u32) {
    carte().touche(code(jeu1, etendue), enfoncee != 0);
}

/// Une frappe posée à son tour, au rythme d'une main.
#[no_mangle]
extern "C" fn carte_taper(jeu1: u32, etendue: u32, enfoncee: u32) {
    carte().taper(code(jeu1, etendue), enfoncee != 0);
}

/// La place où copier un texte de `longueur` octets. Ne vaut que jusqu'au
/// prochain appel, comme celle de l'émetteur.
#[no_mangle]
extern "C" fn carte_texte_place(longueur: u32) -> *mut u8 {
    let mut texte = TEXTE.lock().unwrap_or_else(|poison| poison.into_inner());
    texte.resize(longueur as usize, 0);
    texte.as_mut_ptr()
}

/// **Taper le texte posé à `carte_texte_place`**, au rythme d'une main. Rend
/// le nombre de frappes mises en file, ou -1 pour un texte qui n'est pas de
/// l'UTF-8 ou plus long que la place.
#[no_mangle]
extern "C" fn carte_texte(longueur: u32) -> i32 {
    let texte = TEXTE.lock().unwrap_or_else(|poison| poison.into_inner());
    let Some(Ok(texte)) = texte.get(..longueur as usize).map(std::str::from_utf8) else {
        return -1;
    };
    // Borné par la file des frappes (8 192), donc bien en deçà d'un `i32`.
    carte().taper_texte(texte) as i32
}

/// Un mouvement de souris, Y vers le bas comme à l'écran.
#[no_mangle]
extern "C" fn carte_souris(dx: i32, dy: i32, boutons: u32) {
    carte().souris(dx, dy, boutons as u8);
}

/// 1 si l'invité a tiré la ligne de remise à zéro.
#[no_mangle]
extern "C" fn carte_remise() -> u32 {
    u32::from(carte().remise_demandee())
}

/// 1 si une ligne peut encore monter sans que l'invité agisse.
#[no_mangle]
extern "C" fn carte_reveil() -> u32 {
    u32::from(carte().reveil())
}

#[cfg(test)]
mod tests {
    //! Les exports appelés en natif, comme la page les appelle. Ce qui est
    //! jugé ici, c'est le passage des nombres (bornes, signes, refus) ; que le
    //! module wasm32 réponde pareil sous un vrai moteur est le travail de
    //! `tests/carte.rs`.
    use super::*;

    /// Les tests de ce module partagent la carte, et `cargo test` les lance
    /// en parallèle.
    static UN_A_LA_FOIS: Mutex<()> = Mutex::new(());

    fn tour() -> MutexGuard<'static, ()> {
        let tour = UN_A_LA_FOIS
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        *carte() = Carte::nouvelle();
        tour
    }

    #[test]
    fn the_exports_pass_ports_lines_and_keys_through() {
        let _tour = tour();
        assert_eq!(carte_lire(0x3F8, 1), PERSONNE, "le port série est à l'hôte");
        assert_eq!(
            carte_lire(0x1_0060, 1),
            PERSONNE,
            "un port au-delà de 16 bits"
        );
        assert_eq!(carte_lire(0x60, 0x101), PERSONNE, "une largeur impossible");
        assert_eq!(carte_ecrire(0x80, 1, 0), 0);
        assert_eq!(carte_ecrire(0x64, 1, 0xAA), 1);
        assert_eq!(carte_lire(0x60, 1), 0x55);
        // L'heure, en millisecondes flottantes, puis par les ports.
        carte_heure(1_793_379_909_000.0);
        carte_ecrire(0x70, 1, 0x09);
        assert_eq!(carte_lire(0x71, 1), 0x26);
        carte_heure(f64::NAN);
        assert_eq!(carte_lire(0x71, 1), 0x70, "NaN : 1970, sans trapper");
        // Une touche tout de suite, une frappe à son tour.
        carte_touche(0x48, 1, 1);
        assert_eq!(carte_lignes(), 1 << 1);
        assert_eq!((carte_lire(0x60, 1), carte_lire(0x60, 1)), (0xE0, 0x48));
        carte_taper(0x1E, 0, 1);
        assert_eq!(carte_reveil(), 1);
        assert_eq!(carte_lignes(), 0);
        carte_battre(1);
        assert_eq!(carte_lignes(), 1 << 1);
        assert_eq!(carte_lire(0x60, 1), 0x1E);
        assert_eq!(carte_reveil(), 0);
        // Les lignes du dehors, et leurs refus.
        assert_eq!(carte_lever(9), 1);
        assert_eq!(carte_lignes(), 1 << 9);
        assert_eq!(carte_tenues(), (1 << 1) | (1 << 9) | (1 << 12));
        assert_eq!(carte_baisser(9), 1);
        assert_eq!((carte_lever(4), carte_lever(0x1_0005)), (0, 0));
        assert_eq!(carte_lignes(), 0);
        // La souris, allumée par le noyau, puis un mouvement.
        carte_ecrire(0x64, 1, 0xA8);
        carte_ecrire(0x64, 1, 0xD4);
        carte_ecrire(0x60, 1, 0xF4);
        assert_eq!(carte_lire(0x60, 1), 0xFA);
        carte_souris(-1, 1, 2);
        assert_eq!(carte_lignes(), 1 << 12);
        let paquet: Vec<i64> = (0..3).map(|_| carte_lire(0x60, 1)).collect();
        assert_eq!(paquet, [0x08 | 0x02 | 0x10 | 0x20, 0xFF, 0xFF]);
        // Et la remise à zéro.
        assert_eq!(carte_remise(), 0);
        carte_ecrire(0x64, 1, 0xFE);
        assert_eq!(carte_remise(), 1);
    }

    #[test]
    fn a_text_is_typed_from_the_place_the_page_copies_it_to() {
        let _tour = tour();
        let texte = "ls\n".as_bytes();
        let place = carte_texte_place(texte.len() as u32);
        // SAFETY : la place vient d'être rendue, d'au moins cette longueur.
        unsafe { std::ptr::copy_nonoverlapping(texte.as_ptr(), place, texte.len()) };
        assert_eq!(
            carte_texte(texte.len() as u32),
            6,
            "trois touches, enfoncées puis relâchées"
        );
        assert_eq!(
            carte_texte(texte.len() as u32 + 1),
            -1,
            "plus long que la place"
        );
        let place = carte_texte_place(2);
        // SAFETY : comme ci-dessus ; `0xC3 0x28` n'est pas de l'UTF-8.
        unsafe { std::ptr::copy_nonoverlapping([0xC3u8, 0x28].as_ptr(), place, 2) };
        assert_eq!(carte_texte(2), -1, "pas de l'UTF-8");
        assert_eq!(carte().ps2.frappes.len(), 6, "un refus ne tape rien");
    }
}
