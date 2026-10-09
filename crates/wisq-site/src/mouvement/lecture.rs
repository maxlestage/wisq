//! **Où l'on en est dans un document.**
//!
//! Les pages écrites sont longues — la feuille de route, l'architecture, le
//! protocole — et une barre de défilement de navigateur est fine, grise et
//! souvent cachée. Celle-ci est posée par le module, donc elle n'existe que là
//! où quelque chose peut la remplir.
//!
//! **Elle est décorative et le dit** : `aria-hidden`. Un lecteur d'écran
//! annonce déjà la position dans le document, et une seconde voix qui répète
//! « douze pour cent » à chaque défilement serait du bruit.
//!
//! Hors de `#root`, au bout du `body` : aucun îlot ne la voit, donc aucune
//! hydratation ne peut la trouver de trop.

use super::outils;
use wasm_bindgen::JsCast;
use web_sys::{Document, HtmlElement, Window};

pub fn demarrer(fenetre: &Window, document: &Document) {
    if outils::un::<web_sys::Element>(document, ".doc").is_none() {
        return;
    }
    let Some(corps) = document.body() else {
        return;
    };
    let Some(barre) = document
        .create_element("div")
        .ok()
        .and_then(|e| e.dyn_into::<HtmlElement>().ok())
    else {
        return;
    };
    barre.set_class_name("reading-progress");
    let _ = barre.set_attribute("aria-hidden", "true");
    let _ = corps.append_child(&barre);

    let dessiner = {
        let fenetre = fenetre.clone();
        let document = document.clone();
        move || {
            let hauteur = document
                .document_element()
                .map(|r| f64::from(r.scroll_height()))
                .unwrap_or(0.0);
            let vue = fenetre
                .inner_height()
                .ok()
                .and_then(|v| v.as_f64())
                .unwrap_or(0.0);
            let course = hauteur - vue;
            // Une page plus courte que la fenêtre n'a pas de progression : la
            // barre resterait pleine, ce qui dirait quelque chose de faux.
            let part = if course > 0.0 {
                fenetre.scroll_y().unwrap_or(0.0) / course
            } else {
                0.0
            };
            outils::poser(&barre, "--read", &outils::milliemes(part));
        }
    };
    dessiner();
    let rappel = std::rc::Rc::new(dessiner);
    let au_defilement = rappel.clone();
    outils::ecouter::<web_sys::Event>(fenetre, "scroll", true, move |_| au_defilement());
    outils::ecouter::<web_sys::Event>(fenetre, "resize", true, move |_| rappel());
}
