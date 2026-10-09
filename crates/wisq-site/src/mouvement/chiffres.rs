//! Les chiffres de l'accueil montent jusqu'à leur valeur.
//!
//! **Ils finissent exactement sur le texte d'origine**, remis tel quel à la
//! dernière image plutôt que reconstruit : ce sont des affirmations qu'un test
//! tient — le nombre de tests, celui des portes d'intégration — et un chiffre
//! approché serait un mensonge que l'animation aurait introduit.

use super::outils;
use web_sys::{Document, HtmlElement, Window};

const DUREE_MS: f64 = 900.0;

pub fn demarrer(fenetre: &Window, document: &Document) {
    let valeurs = outils::tous::<HtmlElement>(document, ".fact .value");
    if valeurs.is_empty() {
        return;
    }
    let fenetre = fenetre.clone();
    let Some(observateur) = outils::observer("0px", move |entree, observateur| {
        if !entree.is_intersecting() {
            return;
        }
        let cible = entree.target();
        observateur.unobserve(&cible);
        let Ok(cellule) = wasm_bindgen::JsCast::dyn_into::<HtmlElement>(cible) else {
            return;
        };
        let texte = cellule.text_content().unwrap_or_default();
        // Ce qui n'est pas un entier ordinaire ne compte pas : on le laisse.
        let Ok(valeur) = texte.parse::<i32>() else {
            return;
        };
        if valeur <= 0 {
            return;
        }
        monter(&fenetre, cellule, valeur, texte);
    }) else {
        return;
    };
    for valeur in &valeurs {
        observateur.observe(valeur);
    }
}

fn monter(fenetre: &Window, cellule: HtmlElement, valeur: i32, texte: String) {
    let debut = outils::maintenant(fenetre);
    let image = outils::Image::nouvelle(move |instant| {
        let part = (instant - debut) / DUREE_MS;
        if part >= 1.0 {
            // Le texte d'origine, à l'octet près.
            cellule.set_text_content(Some(&texte));
            return false;
        }
        let courant = (f64::from(valeur) * outils::sortie_cubique(part)).round() as i32;
        cellule.set_text_content(Some(&outils::entier(courant)));
        true
    });
    image.programmer();
    // L'image se tient elle-même tant qu'elle se reprogramme ; ce lien la garde
    // jusqu'à la première.
    std::mem::forget(image);
}
