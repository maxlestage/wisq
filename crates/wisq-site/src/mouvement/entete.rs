//! L'en-tête se pose sur la page dès qu'on a quitté le haut, et dit sa hauteur
//! à l'ouverture.

use super::outils;
use web_sys::{Document, Element, HtmlElement, Window};

pub fn demarrer(fenetre: &Window, document: &Document, racine: &HtmlElement) {
    let marquer = {
        let fenetre = fenetre.clone();
        let racine = racine.clone();
        move || {
            let defile = fenetre.scroll_y().unwrap_or(0.0) > 8.0;
            let _ = if defile {
                racine.set_attribute("data-scrolled", "")
            } else {
                racine.remove_attribute("data-scrolled")
            };
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
