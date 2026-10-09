//! **Le curseur qui suit.**
//!
//! Un anneau violet qui rattrape la flèche avec un temps de retard, grossit
//! au-dessus de ce qu'on peut cliquer et se resserre quand on presse. La flèche
//! du système **reste** : l'anneau l'accompagne, il ne la remplace pas — une
//! page qui cache le pointeur oblige à deviner où l'on clique, et c'est un défaut
//! d'accessibilité avant d'être un choix de style.
//!
//! Seulement à la souris, comme les aimants : un doigt n'a pas de position au
//! repos, et sur un écran hybride, un stylet ou un toucher ne déplace pas
//! l'anneau. Hors de `#root`, au bout du `body` et `aria-hidden` : aucun îlot ne
//! le voit, aucune technologie d'assistance non plus.

use std::cell::Cell;
use std::rc::Rc;

use super::calcul::approcher;
use super::outils;
use wasm_bindgen::JsCast;
use web_sys::{Document, Element, HtmlElement, PointerEvent, Window};

/// La part du chemin restant que l'anneau parcourt à chaque image.
const SUIVI: f64 = 0.2;

/// Ce au-dessus de quoi l'anneau grossit : tout ce qui répond à un clic.
const CLIQUABLE: &str = "a, button, summary, label, input, select, textarea, [data-aimant]";

fn placer(anneau: &HtmlElement, (x, y): (f64, f64)) {
    let x = outils::entier(x.round() as i32);
    let y = outils::entier(y.round() as i32);
    outils::poser(
        anneau,
        "transform",
        &("translate3d(".to_owned() + &x + "px," + &y + "px,0)"),
    );
}

pub fn demarrer(fenetre: &Window, document: &Document) {
    if !outils::requete(fenetre, "(pointer: fine)") || !outils::requete(fenetre, "(hover: hover)") {
        return;
    }
    let Some(corps) = document.body() else {
        return;
    };
    let Some(anneau) = document
        .create_element("div")
        .ok()
        .and_then(|e| e.dyn_into::<HtmlElement>().ok())
    else {
        return;
    };
    anneau.set_class_name("curseur");
    let _ = anneau.set_attribute("aria-hidden", "true");
    let _ = corps.append_child(&anneau);

    let cible = Rc::new(Cell::new((0.0, 0.0)));
    let position = Rc::new(Cell::new((0.0, 0.0)));

    // **L'image ne tourne que pendant le rattrapage.** Arrivé à moins d'un
    // tiers de pixel, l'anneau est posé et la boucle s'arrête ; le prochain
    // mouvement la relance. Une souris immobile ne coûte rien.
    let image = {
        let (cible, position, anneau) = (cible.clone(), position.clone(), anneau.clone());
        outils::Image::nouvelle(move |_| {
            let ((cx, cy), (x, y)) = (cible.get(), position.get());
            let suivant = (approcher(x, cx, SUIVI), approcher(y, cy, SUIVI));
            position.set(suivant);
            placer(&anneau, suivant);
            (suivant.0 - cx).abs() > 0.3 || (suivant.1 - cy).abs() > 0.3
        })
    };

    {
        let anneau = anneau.clone();
        outils::ecouter::<PointerEvent>(document, "pointermove", true, move |e| {
            if e.pointer_type() != "mouse" {
                return;
            }
            let ici = (f64::from(e.client_x()), f64::from(e.client_y()));
            cible.set(ici);
            // Le premier mouvement pose l'anneau sous la flèche : sans ça, il
            // traverserait l'écran depuis le coin en haut à gauche.
            if anneau.get_attribute("data-visible").is_none() {
                position.set(ici);
                placer(&anneau, ici);
                let _ = anneau.set_attribute("data-visible", "");
            }
            let sur = e
                .target()
                .and_then(|t| t.dyn_into::<Element>().ok())
                .and_then(|el| el.closest(CLIQUABLE).ok().flatten())
                .is_some();
            let _ = if sur {
                anneau.set_attribute("data-lien", "")
            } else {
                anneau.remove_attribute("data-lien")
            };
            image.programmer();
        });
    }
    {
        let anneau = anneau.clone();
        outils::ecouter::<PointerEvent>(document, "pointerdown", true, move |_| {
            let _ = anneau.set_attribute("data-presse", "");
        });
    }
    {
        let anneau = anneau.clone();
        outils::ecouter::<PointerEvent>(document, "pointerup", true, move |_| {
            let _ = anneau.remove_attribute("data-presse");
        });
    }
    // La flèche qui sort de la fenêtre emporte l'anneau : laissé là, il
    // marquerait un endroit où personne ne pointe plus.
    outils::ecouter::<PointerEvent>(document, "pointerleave", true, move |_| {
        let _ = anneau.remove_attribute("data-visible");
    });
}
