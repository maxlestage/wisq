//! L'en-tête se pose sur la page dès qu'on a quitté le haut, s'efface quand on
//! descend, revient dès qu'on remonte, et dit sa hauteur à l'ouverture.
//!
//! **S'effacer en descendant**, parce que sur un téléphone l'en-tête et sa
//! bande de navigation prennent un sixième de l'écran à un lecteur qui lit vers
//! le bas, et ne servent qu'à celui qui remonte chercher autre chose. La
//! feuille de style le garde en place tant qu'il a le focus : un lecteur au
//! clavier ne tabule jamais vers un en-tête invisible.

use std::cell::Cell;

use super::outils;
use web_sys::{Document, Element, HtmlElement, Window};

/// En dessous, l'en-tête ne s'efface jamais : le haut de la page est l'endroit
/// où l'on cherche où aller.
const SEUIL: f64 = 320.0;
/// Le moindre défilement qui compte comme un sens : en dessous, une molette qui
/// tremble ferait clignoter l'en-tête.
const SENS: f64 = 6.0;

pub fn demarrer(fenetre: &Window, document: &Document, racine: &HtmlElement) {
    let marquer = {
        let fenetre = fenetre.clone();
        let racine = racine.clone();
        let precedent = Cell::new(fenetre.scroll_y().unwrap_or(0.0));
        move || {
            let y = fenetre.scroll_y().unwrap_or(0.0);
            let _ = if y > 8.0 {
                racine.set_attribute("data-scrolled", "")
            } else {
                racine.remove_attribute("data-scrolled")
            };
            let dy = y - precedent.get();
            if dy > SENS && y > SEUIL {
                let _ = racine.set_attribute("data-cache", "");
            } else if dy < -SENS || y <= SEUIL {
                let _ = racine.remove_attribute("data-cache");
            }
            if dy.abs() > SENS {
                precedent.set(y);
            }
        }
    };
    marquer();
    let au_defilement = marquer;
    outils::ecouter::<web_sys::Event>(fenetre, "scroll", true, move |_| au_defilement());

    // **La hauteur de l'en-tête, mesurée plutôt que supposée.** L'ouverture se
    // glisse sous l'en-tête et réserve sa hauteur en haut de la scène ; la
    // feuille de style part d'une estimation, et l'en-tête va à la ligne sur
    // les écrans étroits. Une estimation fausse de quelques pixels poserait le
    // badge sous la barre.
    let Some(entete) = outils::un::<Element>(document, ".site-header") else {
        return;
    };
    let mesurer = {
        let racine = racine.clone();
        move || {
            let hauteur = entete.get_bounding_client_rect().height().round() as i32;
            if hauteur > 0 {
                outils::poser(&racine, "--entete", &(outils::entier(hauteur) + "px"));
            }
        }
    };
    mesurer();
    let au_redimensionnement = mesurer;
    outils::ecouter::<web_sys::Event>(fenetre, "resize", true, move |_| au_redimensionnement());
}
