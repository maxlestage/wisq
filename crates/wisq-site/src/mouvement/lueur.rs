//! **La lueur qui suit le pointeur.**
//!
//! Deux nombres posés sur la carte survolée, dont la feuille de style fait le
//! centre d'un halo. Un seul écouteur par grille — un par carte serait douze
//! écouteurs pour un effet qui n'en demande qu'un.
//!
//! **Et la carte s'incline.** Les mêmes coordonnées, rapportées à sa taille,
//! donnent un axe et un angle : le point sous le pointeur s'enfonce, comme une
//! carte qu'on presse du doigt (`calcul::inclinaison`). Quand le pointeur
//! s'en va, l'angle revient à zéro et la transition de la feuille de style la
//! redresse.
//!
//! **Rien sur un écran tactile.** Un doigt n'a pas de position au repos : le
//! halo resterait figé là où l'on a touché, ce qui est pire que pas de halo du
//! tout. `(hover: hover)` est la question exacte à poser — pas la largeur de
//! l'écran, qu'un portable à écran tactile démentirait.

use super::calcul::inclinaison;
use super::outils;
use wasm_bindgen::JsCast;
use web_sys::{Document, HtmlElement, PointerEvent, Window};

/// L'angle au milieu d'un bord, en dixièmes de degré. Six degrés : assez pour
/// qu'une carte ait l'air d'un objet, trop peu pour que son texte se lise mal.
const INCLINAISON_MAX: f64 = 60.0;

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
            if boite.width() > 0.0 && boite.height() > 0.0 {
                let (ax, ay, angle) = inclinaison(
                    f64::from(x) / boite.width(),
                    f64::from(y) / boite.height(),
                    INCLINAISON_MAX,
                );
                outils::poser(&carte, "--ax", &outils::entier(ax));
                outils::poser(&carte, "--ay", &outils::entier(ay));
                outils::poser(&carte, "--aa", &outils::entier(angle));
            }
        });
    }
    // Un écouteur par carte pour la sortie : `pointerleave` ne remonte pas, et
    // c'est ce qu'on veut — quitter un titre pour le paragraphe d'à côté n'est
    // pas quitter la carte.
    for carte in outils::tous::<HtmlElement>(document, ".cards > .card") {
        let tenue = carte.clone();
        outils::ecouter::<PointerEvent>(&carte, "pointerleave", true, move |_| {
            outils::poser(&tenue, "--aa", "0");
        });
    }
}
