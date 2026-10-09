//! **Où l'on en est dans la page.**
//!
//! Deux témoins, une seule mesure. Sur un document, une barre fine en haut de
//! l'écran : les pages écrites sont longues — l'architecture, le protocole, les
//! versions —, et une barre de défilement de navigateur est fine, grise et
//! souvent cachée. Sur toutes les pages, un bouton de retour en haut dont
//! l'anneau se remplit avec la lecture, et qui n'apparaît qu'une fois qu'on a
//! quitté le haut.
//!
//! **La barre est décorative et le dit** : `aria-hidden`. Un lecteur d'écran
//! annonce déjà la position dans le document, et une seconde voix qui répète
//! « douze pour cent » à chaque défilement serait du bruit.
//!
//! **Le bouton, lui, est un vrai lien**, vers `#main` comme celui du pied, et
//! il porte le nom de celui du pied : le module ne connaît pas la langue de la
//! page, la page la connaît. Invisible, il est aussi hors du parcours au
//! clavier — `visibility` et non seulement l'opacité.
//!
//! Hors de `#root`, au bout du `body` : aucun îlot ne les voit, donc aucune
//! hydratation ne peut les trouver de trop.

use super::outils;
use wasm_bindgen::JsCast;
use web_sys::{Document, Element, HtmlElement, Window};

/// Ce qu'il faut avoir défilé pour que le retour en haut ait un sens : un peu
/// plus qu'un écran de téléphone.
const SEUIL_HAUT: f64 = 600.0;

fn creer(document: &Document, classe: &str) -> Option<HtmlElement> {
    let element = document
        .create_element(if classe == "haut" { "a" } else { "div" })
        .ok()?
        .dyn_into::<HtmlElement>()
        .ok()?;
    element.set_class_name(classe);
    Some(element)
}

pub fn demarrer(fenetre: &Window, document: &Document) {
    let Some(corps) = document.body() else {
        return;
    };

    let barre = if outils::un::<Element>(document, ".doc").is_some() {
        creer(document, "reading-progress")
    } else {
        None
    };
    if let Some(barre) = &barre {
        let _ = barre.set_attribute("aria-hidden", "true");
        let _ = corps.append_child(barre);
    }

    // Le nom vient du lien du pied, dans la langue de la page. Sans lui, pas
    // de bouton : un lien sans nom est un lien qu'on ne peut pas annoncer.
    let haut = outils::un::<Element>(document, r##".footer-legal a[href="#main"]"##)
        .and_then(|lien| lien.text_content())
        .filter(|nom| !nom.trim().is_empty())
        .and_then(|nom| {
            let haut = creer(document, "haut")?;
            let _ = haut.set_attribute("href", "#main");
            let _ = haut.set_attribute("aria-label", nom.trim());
            let _ = haut.set_attribute("data-aimant", "");
            let _ = corps.append_child(&haut);
            Some(haut)
        });

    if barre.is_none() && haut.is_none() {
        return;
    }

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
            let y = fenetre.scroll_y().unwrap_or(0.0);
            // Une page plus courte que la fenêtre n'a pas de progression : la
            // barre resterait pleine, ce qui dirait quelque chose de faux.
            let part = if course > 0.0 { y / course } else { 0.0 };
            let milliemes = outils::milliemes(part);
            for temoin in [&barre, &haut].into_iter().flatten() {
                outils::poser(temoin, "--read", &milliemes);
            }
            if let Some(haut) = &haut {
                let _ = if y > SEUIL_HAUT {
                    haut.set_attribute("data-visible", "")
                } else {
                    haut.remove_attribute("data-visible")
                };
            }
        }
    };
    dessiner();
    let rappel = std::rc::Rc::new(dessiner);
    let au_defilement = rappel.clone();
    outils::ecouter::<web_sys::Event>(fenetre, "scroll", true, move |_| au_defilement());
    outils::ecouter::<web_sys::Event>(fenetre, "resize", true, move |_| rappel());
}
