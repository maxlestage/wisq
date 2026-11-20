//! **La carte, exportée par le module de la page.**
//!
//! Le même module que l'émetteur (`wisq_page.wasm`), d'autres exports, tous
//! préfixés `carte_`. `web/carte.js` les lit et les sert à la boucle hôte ;
//! ce fichier ne fait que passer des nombres, la carte est dans
//! [`Carte`] (le crate `wisq-carte`, `src/carte/`).
//!
//! **Une carte par instance.** L'état vit dans une `static` du module : deux
//! instances du même `WebAssembly.Module` ont deux mémoires, donc deux cartes.
//! `web/carte.js` instancie la sienne à part de celle de l'émetteur — une
//! trappe de l'émetteur fait jeter son instance (`web/page-emitter.js`), et
//! elle ne doit pas emporter le clavier et l'horloge avec elle.
//!
//! **Deux imports, et rien d'autre** : `carte.ram_lire` et `carte.ram_ecrire`.
//! La file du disque virtio vit dans la RAM de l'invité, qui est dans une
//! autre `WebAssembly.Memory` que celle de ce module ; la seule façon de la
//! lire pendant l'`out` qui notifie est de demander à la page de recopier.
//! `web/carte.js` les fournit à partir de la RAM qu'on lui donne. L'émetteur,
//! instancié sur le même module, ne les appelle jamais : `web/page-emitter.js`
//! lui en donne qui lèvent une erreur. L'heure, elle, reste posée
//! (`carte_heure`) plutôt qu'importée.
//!
//! **Un seul disque, côté page.** Le bus a deux emplacements de disque
//! (00:03.0 et 00:04.0), mais la page n'en branche qu'un : aucun export ne
//! touche au second, que seule la machine native emploie
//! (`wisq_carte::pc::CartePc`). Son emplacement reste vide ici.
//!
//! **Le disque, côté page** : `carte_disque` le branche ; après un `out`,
//! `carte_requete` prend la prochaine requête partie et ses quatre
//! accesseurs la décrivent ; `carte_disque_lu` et `carte_disque_fini`
//! rendent la réponse quand l'arrière l'a. Voir `web/carte.js`, `servir`.
//!
//! **Pourquoi ces fonctions ne sont pas `pub`** : pour la même raison que
//! celles de l'émetteur (`lib.rs`). Ce sont les exports d'un module
//! WebAssembly, `#[no_mangle]` suffit ; elles ne font pas partie du C ABI de
//! l'application, que `crates/wisq-vm/src/ffi.rs` tient en entier.

use std::sync::{Mutex, MutexGuard};

use wisq_carte::i8042::CodeTouche;
use wisq_carte::pci::Disque;
use wisq_carte::virtio_blk::{RequeteDisque, Sens};
use wisq_carte::{Carte, Ram, SansRam};

static CARTE: Mutex<Carte> = Mutex::new(Carte::nouvelle());
/// La place où la page copie un texte à taper, en UTF-8.
static TEXTE: Mutex<Vec<u8>> = Mutex::new(Vec::new());
/// La dernière requête du disque prise par `carte_requete`, que ses
/// accesseurs décrivent jusqu'à la suivante.
static PRISE: Mutex<Option<RequeteDisque>> = Mutex::new(None);
/// La place où la page copie les octets d'une lecture revenue.
static LUS: Mutex<Vec<u8>> = Mutex::new(Vec::new());

/// **La RAM de l'invité, par les deux imports de la page.** Une adresse
/// au-delà de 2⁶⁴ n'existe pas ; une longueur au-delà de 4 Gio non plus dans
/// la page (wasm32), et la file n'en demande jamais tant.
#[cfg(target_arch = "wasm32")]
mod ram_de_la_page {
    #[link(wasm_import_module = "carte")]
    extern "C" {
        /// Recopier `longueur` octets de la RAM de l'invité, depuis
        /// l'adresse physique `adresse`, vers `vers` dans la mémoire de ce
        /// module. 1 si la plage entière est dans la RAM, 0 sinon.
        fn ram_lire(adresse: u64, vers: *mut u8, longueur: u32) -> u32;
        /// L'inverse.
        fn ram_ecrire(adresse: u64, depuis: *const u8, longueur: u32) -> u32;
    }

    pub struct RamDeLaPage;

    impl wisq_carte::Ram for RamDeLaPage {
        fn lire(&self, adresse: u64, vers: &mut [u8]) -> bool {
            let Ok(longueur) = u32::try_from(vers.len()) else {
                return false;
            };
            // SAFETY : la page écrit au plus `longueur` octets à `vers`, qui
            // les a ; c'est le contrat de l'import, tenu par `web/carte.js`.
            unsafe { ram_lire(adresse, vers.as_mut_ptr(), longueur) == 1 }
        }

        fn ecrire(&mut self, adresse: u64, depuis: &[u8]) -> bool {
            let Ok(longueur) = u32::try_from(depuis.len()) else {
                return false;
            };
            // SAFETY : la page lit au plus `longueur` octets à `depuis`.
            unsafe { ram_ecrire(adresse, depuis.as_ptr(), longueur) == 1 }
        }
    }
}

/// **En natif, la RAM d'un test** : un tableau que les tests de ce fichier
/// remplissent, à la place de celle que la page tiendrait.
#[cfg(not(target_arch = "wasm32"))]
static RAM_D_ESSAI: Mutex<wisq_carte::RamPlate> = Mutex::new(wisq_carte::RamPlate(Vec::new()));

/// Faire `f` avec la RAM de l'invité.
fn avec_la_ram<T>(f: impl FnOnce(&mut dyn Ram) -> T) -> T {
    #[cfg(target_arch = "wasm32")]
    {
        f(&mut ram_de_la_page::RamDeLaPage)
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        let mut ram = RAM_D_ESSAI
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        f(&mut *ram)
    }
}

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
    // Aucune lecture de port ne touche à la RAM : l'acquittement du disque
    // (`0x13`) ne fait que lire son état.
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
    avec_la_ram(|ram| u32::from(carte().port_ecrire(port, largeur, valeur, ram)))
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

/// Une frappe posée à son tour, au rythme d'une main : 1 si elle est en
/// file, 0 si la file pleine la refuse.
#[no_mangle]
extern "C" fn carte_taper(jeu1: u32, etendue: u32, enfoncee: u32) -> u32 {
    u32::from(carte().taper(code(jeu1, etendue), enfoncee != 0))
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
    // Borné par la file des frappes (8 192) : un texte n'y entre jamais
    // au-delà de la borne. Bien en deçà d'un `i32`.
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

/// **Brancher le disque** : sa capacité, en secteurs de 512 octets. Un
/// `u64` (un `BigInt` de l'autre côté) : une capacité au-delà de 2³² secteurs
/// doit passer.
#[no_mangle]
extern "C" fn carte_disque(secteurs: u64) {
    carte().brancher_disque(secteurs);
}

/// Combien de requêtes du disque attendent d'être prises.
#[no_mangle]
extern "C" fn carte_requetes() -> u32 {
    carte()
        .disque(Disque::Premier)
        .map_or(0, |d| d.a_prendre() as u32)
}

/// **Prendre la prochaine requête du disque** : 1 si elle est prise, et les
/// accesseurs `carte_requete_*` la décrivent jusqu'au prochain appel ; 0 s'il
/// n'y en a pas.
#[no_mangle]
extern "C" fn carte_requete() -> u32 {
    let requete = carte().requete_disque();
    let prise = requete.is_some();
    *PRISE.lock().unwrap_or_else(|poison| poison.into_inner()) = requete;
    u32::from(prise)
}

fn prise<T>(f: impl FnOnce(&RequeteDisque) -> T, sinon: T) -> T {
    PRISE
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .as_ref()
        .map_or(sinon, f)
}

/// Le nom de la requête prise, entre 1 et 2³¹ − 1 ; 0 sans requête.
#[no_mangle]
extern "C" fn carte_requete_id() -> u32 {
    prise(|r| r.id, 0)
}

/// Son sens : 0 lire, 1 écrire.
#[no_mangle]
extern "C" fn carte_requete_sens() -> u32 {
    prise(|r| u32::from(r.sens == Sens::Ecrire), 0)
}

/// Son début, en octets depuis le début du disque.
#[no_mangle]
extern "C" fn carte_requete_decalage() -> u64 {
    prise(|r| r.decalage, 0)
}

/// Sa longueur, en octets : jamais plus que la borne du disque (64 Mio).
#[no_mangle]
extern "C" fn carte_requete_longueur() -> u32 {
    prise(|r| r.longueur as u32, 0)
}

/// **Où lire les octets d'une écriture**, dans la mémoire de ce module :
/// `carte_requete_longueur` octets, valables jusqu'au prochain
/// `carte_requete`. Nul pour une lecture.
#[no_mangle]
extern "C" fn carte_requete_octets() -> *const u8 {
    prise(
        |r| {
            if r.octets.is_empty() {
                std::ptr::null()
            } else {
                r.octets.as_ptr()
            }
        },
        std::ptr::null(),
    )
}

/// La place où copier les `longueur` octets d'une lecture revenue. Ne vaut
/// que jusqu'au prochain appel.
#[no_mangle]
extern "C" fn carte_disque_place(longueur: u32) -> *mut u8 {
    let mut lus = LUS.lock().unwrap_or_else(|poison| poison.into_inner());
    lus.resize(longueur as usize, 0);
    lus.as_mut_ptr()
}

/// **Les octets d'une lecture sont revenus**, posés à `carte_disque_place` :
/// 1 si `id` nommait une requête partie (elle est rendue, et la ligne
/// levée), 0 sinon ou pour une longueur plus grande que la place.
#[no_mangle]
extern "C" fn carte_disque_lu(id: u32, longueur: u32) -> u32 {
    let lus = LUS.lock().unwrap_or_else(|poison| poison.into_inner());
    let Some(octets) = lus.get(..longueur as usize) else {
        return 0;
    };
    avec_la_ram(|ram| u32::from(carte().disque_lu(id, octets, ram)))
}

/// **Une requête est finie sans octets** : une écriture faite (`reussi` = 1)
/// ou toute requête manquée (0). 1 si `id` nommait une requête partie.
#[no_mangle]
extern "C" fn carte_disque_fini(id: u32, reussi: u32) -> u32 {
    avec_la_ram(|ram| u32::from(carte().disque_fini(id, reussi != 0, ram)))
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
        RAM_D_ESSAI
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .0
            .clear();
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
        assert_eq!(carte_taper(0x1E, 0, 1), 1);
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

    /// **Le disque par les exports** : branché, placé, une lecture qui part,
    /// décrite par ses accesseurs, rendue par la place des octets — et une
    /// écriture dont les octets se lisent à l'adresse rendue. La RAM est
    /// celle d'essai, à la place des deux imports de la page.
    #[test]
    fn a_disk_request_leaves_and_comes_back_through_the_exports() {
        let _tour = tour();
        let ram = |f: &mut dyn FnMut(&mut Vec<u8>)| {
            f(&mut RAM_D_ESSAI.lock().unwrap_or_else(|p| p.into_inner()).0)
        };
        ram(&mut |r| *r = vec![0; 0x10000]);
        carte_disque((1 << 32) + 3);
        // Le bus, la fenêtre à 0xC000, ouverte.
        carte_ecrire(0xCF8, 4, 0x8000_1810);
        carte_ecrire(0xCFC, 4, 0xC000);
        carte_ecrire(0xCF8, 4, 0x8000_1804);
        carte_ecrire(0xCFC, 2, 1);
        assert_eq!(carte_lire(0xC018, 4), 1, "au-delà de 2³² secteurs");
        assert_eq!(carte_lire(0xC014, 4), 3);
        // La file à la page 1, une lecture du secteur 5 vers 0x5000.
        carte_ecrire(0xC008, 4, 1);
        ram(&mut |r| {
            let mut ram = wisq_carte::RamPlate(std::mem::take(r));
            let dire = |ram: &mut wisq_carte::RamPlate, i: u64, a: u64, n: u32, d: u16, s: u16| {
                let at = 0x1000 + i * 16;
                ram.ecrire(at, &a.to_le_bytes());
                ram.ecrire(at + 8, &n.to_le_bytes());
                ram.ecrire(at + 12, &d.to_le_bytes());
                ram.ecrire(at + 14, &s.to_le_bytes());
            };
            ram.ecrire(0x4008, &5u64.to_le_bytes());
            dire(&mut ram, 0, 0x4000, 16, 1, 1);
            dire(&mut ram, 1, 0x5000, 1024, 3, 2);
            dire(&mut ram, 2, 0x4800, 1, 2, 0);
            ram.ecrire(0x1802, &1u16.to_le_bytes());
            *r = ram.0;
        });
        assert_eq!(carte_requetes(), 0);
        assert_eq!(carte_ecrire(0xC010, 2, 0), 1);
        assert_eq!(carte_requetes(), 1);
        assert_eq!(carte_reveil(), 1);
        assert_eq!(carte_lignes() & (1 << 5), 0);
        assert_eq!(carte_requete(), 1);
        let id = carte_requete_id();
        assert_ne!(id, 0);
        assert_eq!(
            (
                carte_requete_sens(),
                carte_requete_decalage(),
                carte_requete_longueur()
            ),
            (0, 5 * 512, 1024)
        );
        assert!(
            carte_requete_octets().is_null(),
            "une lecture n'a pas d'octets"
        );
        assert_eq!(carte_requete(), 0, "plus rien");
        assert_eq!(carte_requete_id(), 0);
        let place = carte_disque_place(1024);
        // SAFETY : la place vient d'être rendue, de 1 024 octets.
        unsafe { std::ptr::write_bytes(place, 0x5A, 1024) };
        assert_eq!(carte_disque_lu(id, 1025), 0, "plus long que la place");
        assert_eq!(carte_disque_lu(id, 1024), 1);
        assert_eq!(carte_disque_lu(id, 1024), 0, "déjà rendue");
        assert_eq!(carte_lignes(), 1 << 5);
        ram(&mut |r| {
            assert_eq!((r[0x5000], r[0x53FF], r[0x5400]), (0x5A, 0x5A, 0));
            assert_eq!(r[0x4800], 0, "réussi");
            // Une écriture, cette fois : le même tampon, en lecture seule.
            r[0x4000] = 1;
            r[0x1000 + 16 + 12] = 1;
            r[0x1804] = 0;
            r[0x1806] = 0;
            r[0x1802] = 2;
        });
        carte_ecrire(0xC010, 2, 0);
        assert_eq!(carte_requete(), 1);
        assert_eq!(carte_requete_sens(), 1);
        let octets = carte_requete_octets();
        // SAFETY : l'adresse rendue porte `carte_requete_longueur` octets.
        let ecrits =
            unsafe { std::slice::from_raw_parts(octets, carte_requete_longueur() as usize) };
        assert_eq!(ecrits, [0x5A; 1024]);
        assert_eq!(carte_disque_fini(carte_requete_id(), 1), 1);
        assert_eq!(carte_disque_fini(carte_requete_id(), 1), 0);
        assert_eq!(carte_lire(0xC013, 1), 1);
        assert_eq!(carte_reveil(), 0);
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
