//! **Les boutons aimantés**, comme ceux de la référence : ils suivent le
//! pointeur, puis reviennent en rebondissant.
//!
//! Seulement à la souris. Au doigt il n'y a pas de survol, et un bouton qui
//! bougerait sous le pouce au moment de le toucher serait un piège. Délégué
//! depuis le document plutôt qu'attaché à chaque bouton : un seul écouteur, et
//! rien à rebrancher si le balisage change.
//!
//! Le rebond n'est pas ici : c'est la transition de retour de la feuille de
//! style (`--rebond`, une courbe `linear()`), qui joue quand ce module retire
//! les deux décalages.

use std::cell::RefCell;
use std::rc::Rc;

use super::outils;
use wasm_bindgen::JsCast;
use web_sys::{Document, Element, HtmlElement, PointerEvent, Window};

/// Quelle part du chemin vers le pointeur le bouton parcourt. Moins d'un tiers :
/// assez pour qu'on le sente, trop peu pour qu'il fuie la flèche.
const ATTRAIT_X: f64 = 0.3;
const ATTRAIT_Y: f64 = 0.35;

pub fn demarrer(fenetre: &Window, document: &Document) {
    if !outils::requete(fenetre, "(pointer: fine)") || !outils::requete(fenetre, "(hover: hover)") {
        return;
    }
    let actif: Rc<RefCell<Option<HtmlElement>>> = Rc::new(RefCell::new(None));

    let relacher = |bouton: &HtmlElement| {
        let _ = bouton.style().remove_property("--mx");
        let _ = bouton.style().remove_property("--my");
    };

    {
        let actif = actif.clone();
        outils::ecouter::<PointerEvent>(document, "pointermove", true, move |evenement| {
            let cible = evenement
                .target()
                .and_then(|t| t.dyn_into::<Element>().ok())
                .and_then(|e| e.closest("[data-aimant]").ok().flatten())
                .and_then(|e| e.dyn_into::<HtmlElement>().ok());
            let mut tenu = actif.borrow_mut();
            if let Some(ancien) = tenu.as_ref() {
                if cible.as_ref() != Some(ancien) {
                    relacher(ancien);
                }
            }
            *tenu = cible.clone();
            let Some(bouton) = cible else {
                return;
            };
            if outils::arrete() {
                return;
            }
            let boite = bouton.get_bounding_client_rect();
            let dx = f64::from(evenement.client_x()) - (boite.left() + boite.width() / 2.0);
            let dy = f64::from(evenement.client_y()) - (boite.top() + boite.height() / 2.0);
            let x = (dx * ATTRAIT_X).round() as i32;
            let y = (dy * ATTRAIT_Y).round() as i32;
            outils::poser(&bouton, "--mx", &(outils::entier(x) + "px"));
            outils::poser(&bouton, "--my", &(outils::entier(y) + "px"));
        });
    }

    // Le pointeur qui quitte la fenêtre par-dessus un bouton ne déclenche aucun
    // `pointermove` de plus : sans ceci, le bouton resterait déporté.
    outils::ecouter::<PointerEvent>(document, "pointerleave", true, move |_| {
        if let Some(bouton) = actif.borrow_mut().take() {
            relacher(&bouton);
        }
    });
}
