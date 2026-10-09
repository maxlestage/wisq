//! **La lueur qui suit le pointeur.**
//!
//! Deux nombres posés sur la carte survolée, dont la feuille de style fait le
//! centre d'un halo. Un seul écouteur par grille — un par carte serait douze
//! écouteurs pour un effet qui n'en demande qu'un.
//!
//! **Rien sur un écran tactile.** Un doigt n'a pas de position au repos : le
//! halo resterait figé là où l'on a touché, ce qui est pire que pas de halo du
//! tout. `(hover: hover)` est la question exacte à poser — pas la largeur de
//! l'écran, qu'un portable à écran tactile démentirait.

use super::outils;
use wasm_bindgen::JsCast;
use web_sys::{Document, HtmlElement, PointerEvent, Window};

pub fn demarrer(fenetre: &Window, document: &Document) {
    if !outils::requete(fenetre, "(hover: hover)") {
        return;
    }
    for grille in outils::tous::<HtmlElement>(document, ".cards") {
        outils::ecouter::<PointerEvent>(&grille, "pointermove", true, |evenement| {
            let Some(carte) = evenement
                .target()
                .and_then(|t| t.dyn_into::<web_sys::Element>().ok())
                .and_then(|e| e.closest(".card").ok().flatten())
                .and_then(|c| c.dyn_into::<HtmlElement>().ok())
            else {
                return;
            };
            let boite = carte.get_bounding_client_rect();
            let x = (f64::from(evenement.client_x()) - boite.left()).round() as i32;
            let y = (f64::from(evenement.client_y()) - boite.top()).round() as i32;
            outils::poser(&carte, "--mx", &(outils::entier(x) + "px"));
            outils::poser(&carte, "--my", &(outils::entier(y) + "px"));
        });
    }
}
