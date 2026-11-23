//! **Le socle de la boucle hôte en Rust** : atteindre, depuis le module de la
//! page, l'état d'une machine traduite.
//!
//! La boucle hôte de l'émetteur vit aujourd'hui dans `web/host.js`. Elle va
//! passer ici, en Rust compilé en WebAssembly, morceau par morceau ; ce
//! fichier pose ce dont tous les morceaux auront besoin.
//!
//! **Le problème.** Une machine traduite, ce sont des modules que la page
//! instancie à la volée : ils importent leur mémoire (`env.mem`, la RAM de
//! l'invité et les tables de l'hôte) et leurs registres (`env.g0` …
//! `env.g92`, des globales mutables). Le module Rust a sa propre mémoire. Or
//! Rust ne sait ni importer une globale mutable d'une autre instance, ni lire
//! une seconde mémoire, ni compiler du WebAssembly.
//!
//! **La réponse** : le module d'accès (`wisq_vm::x86_wasm::access_module`),
//! qui importe ce qu'importent les modules traduits et rend six fonctions. La
//! page l'instancie et pose ses fonctions dans la table de fonctions du module
//! Rust (exportée, et extensible : voir `build.rs`) ; elle donne l'indice de
//! la première à [`brancher_acces`]. Un appel de Rust y devient un
//! `call_indirect` : de WebAssembly à WebAssembly, sans JavaScript entre les
//! deux. Les `run` des modules traduits passeront par la même table.
//!
//! **Aucun verrou n'est tenu pendant un appel sortant.** Un appel dans une
//! autre instance peut trapper, et une trappe ne déroule rien : un verrou pris
//! resterait pris. L'indice est donc un atome, lu puis relâché.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::OnceLock;

/// L'indice, dans la table de fonctions, de la première fonction d'accès ;
/// `u32::MAX` tant que la page n'a rien branché.
static ACCES: AtomicU32 = AtomicU32::new(u32::MAX);

/// Les octets du module d'accès, faits une fois.
fn octets() -> &'static [u8] {
    static OCTETS: OnceLock<Vec<u8>> = OnceLock::new();
    OCTETS.get_or_init(wisq_vm::x86_wasm::access_module)
}

/// **Où sont les octets du module d'accès**, pour que la page l'instancie.
#[no_mangle]
extern "C" fn acces_octets() -> *const u8 {
    octets().as_ptr()
}

/// Leur longueur.
#[no_mangle]
extern "C" fn acces_longueur() -> u32 {
    octets().len() as u32
}

/// **La page a posé les fonctions d'accès** à partir de l'indice `base` de la
/// table, dans l'ordre de `wisq_vm::x86_wasm::ACCESS_EXPORTS`.
#[no_mangle]
extern "C" fn brancher_acces(base: u32) {
    ACCES.store(base, Ordering::Release);
}

/// Les fonctions d'accès, telles qu'un appel Rust les voit.
#[cfg(target_arch = "wasm32")]
mod appels {
    use super::{Ordering, ACCES};

    /// L'indice de la fonction `rang` d'accès, ou `None` si rien n'est branché.
    fn indice(rang: u32) -> Option<usize> {
        let base = ACCES.load(Ordering::Acquire);
        (base != u32::MAX).then(|| (base + rang) as usize)
    }

    /// **Un indice de la table, vu comme une fonction.** En wasm32, un
    /// pointeur de fonction *est* un indice de la table de fonctions, et
    /// l'appel est un `call_indirect` qui vérifie la signature : une fonction
    /// posée au mauvais rang trappe, elle ne s'exécute pas de travers.
    macro_rules! fonction {
        ($nom:ident, $rang:expr, fn($($arg:ident: $type:ty),*) $(-> $rendu:ty)?) => {
            pub fn $nom($($arg: $type),*) $(-> Option<$rendu>)? {
                let indice = indice($rang)?;
                // SAFETY : en wasm32, un `extern "C" fn` est un indice de la
                // table de fonctions ; `call_indirect` vérifie la signature
                // à l'appel, et la page a posé à ce rang la fonction d'accès
                // de cette signature.
                let appel: extern "C" fn($($type),*) $(-> $rendu)? =
                    unsafe { core::mem::transmute::<usize, _>(indice) };
                #[allow(clippy::unit_arg)]
                Some(appel($($arg),*))
            }
        };
    }

    fonction!(lire, 0, fn(registre: i32) -> i64);
    fonction!(ecrire, 1, fn(registre: i32, valeur: i64) -> ());
    fonction!(lire64, 2, fn(adresse: i32) -> i64);
    fonction!(ecrire64, 3, fn(adresse: i32, valeur: i64) -> ());
    fonction!(lire8, 4, fn(adresse: i32) -> i32);
    fonction!(ecrire8, 5, fn(adresse: i32, valeur: i32) -> ());
}

#[cfg(target_arch = "wasm32")]
pub use appels::*;

/// **Les essais de la page** : chaque fonction d'accès, appelée depuis Rust,
/// pour que `tests/page.rs` juge le chemin entier sous Bun. Ils rendent `-1`
/// (ou ne font rien) tant que rien n'est branché.
#[cfg(target_arch = "wasm32")]
mod essais {
    #[no_mangle]
    extern "C" fn hote_lire(registre: i32) -> i64 {
        super::lire(registre).unwrap_or(-1)
    }

    #[no_mangle]
    extern "C" fn hote_ecrire(registre: i32, valeur: i64) {
        let _ = super::ecrire(registre, valeur);
    }

    #[no_mangle]
    extern "C" fn hote_lire64(adresse: i32) -> i64 {
        super::lire64(adresse).unwrap_or(-1)
    }

    #[no_mangle]
    extern "C" fn hote_ecrire64(adresse: i32, valeur: i64) {
        let _ = super::ecrire64(adresse, valeur);
    }

    #[no_mangle]
    extern "C" fn hote_lire8(adresse: i32) -> i32 {
        super::lire8(adresse).unwrap_or(-1)
    }

    #[no_mangle]
    extern "C" fn hote_ecrire8(adresse: i32, valeur: i32) {
        let _ = super::ecrire8(adresse, valeur);
    }

    /// **Le banc** : `fois` lectures du registre `registre`, sommées, pour
    /// mesurer ce que coûte un appel de Rust à travers la table.
    #[no_mangle]
    extern "C" fn hote_banc(registre: i32, fois: u32) -> i64 {
        let mut somme = 0i64;
        for _ in 0..fois {
            somme = somme.wrapping_add(super::lire(registre).unwrap_or(0));
        }
        somme
    }
}
