//! Le mouvement du site, en Rust, et la règle qui le gouverne.
//!
//! **Rien ici n'est porteur.** Un navigateur sans `IntersectionObserver`, une
//! personne qui a demandé moins d'animation, un module qui n'arrive pas —
//! chacun doit obtenir le site tel qu'il est, entier et lisible, pas une page
//! vide en attente d'être révélée. C'est pour ça que **rien n'est caché par la
//! feuille de style seule** : les règles qui masquent vivent toutes sous
//! `[data-motion]`, un attribut que ce module pose et que rien d'autre ne pose.
//!
//! Deux familles, et la seconde est la demande :
//!
//! - **ce que `src/motion.ts` faisait** — les révélations au défilement et leur
//!   cascade, l'en-tête qui se pose, la barre de lecture, les chiffres qui
//!   montent, la lueur sous le pointeur. Porté tel quel, comportement pour
//!   comportement ;
//! - **ce que fait zamocorp.com** — une ouverture épinglée que le défilement
//!   déroule et où la marque se forme dans la poussière, un balayage de
//!   lumière, des boutons aimantés, la bande qui défile, et le défilement lissé
//!   de Lenis. Le rideau et le titre mot par mot n'ont pas besoin de ce
//!   module : ce sont des animations CSS qui s'achèvent d'elles-mêmes,
//!   décidées par le script de la tête avant la première peinture. La bande,
//!   elle, ne s'achève jamais : elle attend `[data-motion]`.
//!
//! **Ce que la référence fait et que ce module ne fait pas.** zamocorp joue son
//! ouverture avec une séquence d'images AVIF pré-rendues et 54 Ko gzippés de
//! GSAP et de Lenis. Ici la poussière est calculée depuis la géométrie exacte
//! de la marque — celle que `crate::logo` dessine —, et le défilement lissé
//! tient en une centaine de lignes qui ne s'activent qu'à la souris.

#[cfg(feature = "hydrate")]
mod aimants;
#[cfg(feature = "hydrate")]
mod bande;
pub mod calcul;
#[cfg(feature = "hydrate")]
mod chiffres;
#[cfg(feature = "hydrate")]
mod curseur;
#[cfg(feature = "hydrate")]
mod defilement;
#[cfg(feature = "hydrate")]
mod entete;
#[cfg(feature = "hydrate")]
mod lecture;
#[cfg(feature = "hydrate")]
mod lueur;
#[cfg(feature = "hydrate")]
pub(crate) mod outils;
#[cfg(feature = "hydrate")]
mod ouverture;
#[cfg(feature = "hydrate")]
mod revelation;
#[cfg(feature = "hydrate")]
mod sommaire;

#[cfg(feature = "hydrate")]
use wasm_bindgen::JsCast;

/// De combien un bloc descend avant d'être remonté. Assez pour se voir, trop
/// peu pour déplacer la lecture.
#[cfg(feature = "hydrate")]
const RISE: &str = "0.6rem";

#[cfg(feature = "hydrate")]
pub fn demarrer() {
    let Some(fenetre) = web_sys::window() else {
        return;
    };
    // **La demande de la personne passe avant tout le reste.** Un système
    // réglé sur « moins d'animation » n'obtient rien : ni mouvement, ni
    // attribut, donc pas une seule règle de masquage.
    if outils::requete(&fenetre, "(prefers-reduced-motion: reduce)") {
        return;
    }
    // Sans observateur, on ne saurait pas quand révéler — donc on ne cache pas.
    if !js_sys::Reflect::has(&fenetre, &"IntersectionObserver".into()).unwrap_or(false) {
        return;
    }
    let Some(document) = fenetre.document() else {
        return;
    };
    let Some(racine) = document
        .document_element()
        .and_then(|r| r.dyn_into::<web_sys::HtmlElement>().ok())
    else {
        return;
    };
    let _ = racine.set_attribute("data-motion", "on");
    outils::poser(&racine, "--rise", RISE);

    revelation::demarrer(&document);
    entete::demarrer(&fenetre, &document, &racine);
    chiffres::demarrer(&fenetre, &document);
    lueur::demarrer(&fenetre, &document);
    lecture::demarrer(&fenetre, &document);
    ouverture::demarrer(&fenetre, &document);
    aimants::demarrer(&fenetre, &document);
    defilement::demarrer(&fenetre, &document);
    sommaire::demarrer(&document);
    bande::demarrer(&fenetre, &document);
    curseur::demarrer(&fenetre, &document);

    surveiller(&fenetre, &racine);
}

/// Quelqu'un qui active « réduire les animations » en cours de route retrouve
/// la page immobile, sans recharger : l'attribut part, donc toutes les règles
/// qui masquent ou déplacent tombent avec lui, et chaque boucle s'arrête à sa
/// prochaine image.
#[cfg(feature = "hydrate")]
fn surveiller(fenetre: &web_sys::Window, racine: &web_sys::HtmlElement) {
    let Ok(Some(requete)) = fenetre.match_media("(prefers-reduced-motion: reduce)") else {
        return;
    };
    let racine = racine.clone();
    outils::ecouter::<web_sys::Event>(&requete.clone(), "change", true, move |_| {
        if !requete.matches() {
            return;
        }
        outils::arreter();
        let _ = racine.remove_attribute("data-motion");
        let _ = racine.style().remove_property("--rise");
    });
}
