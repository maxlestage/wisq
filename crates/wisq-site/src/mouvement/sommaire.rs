//! **Le sommaire suit la lecture.**
//!
//! Les pages écrites ont grandi, et un sommaire qui ne dit pas où l'on est n'est
//! qu'une deuxième table des matières. Chaque titre de section est observé ; celui
//! qui entre dans la bande du haut de la fenêtre devient la section lue, son
//! lien prend `aria-current="location"`, et le trait du sommaire glisse jusqu'à
//! lui.
//!
//! **Le sommaire existe sans le module** — il est rendu à la construction, ses
//! liens sont des ancres. Ce fichier n'ajoute que le suivi.

use std::rc::Rc;

use super::outils;
use web_sys::{Document, HtmlElement};

/// La bande où un titre devient « la section lue » : sous l'en-tête, dans le
/// tiers haut de la fenêtre. Plus bas, un titre qu'on vient d'apercevoir
/// volerait la place de la section qu'on lit encore.
const BANDE: &str = "-12% 0px -70% 0px";

pub fn demarrer(document: &Document) {
    let Some(liste) = outils::un::<HtmlElement>(document, ".sommaire ol") else {
        return;
    };
    let liens = Rc::new(outils::tous::<HtmlElement>(document, ".sommaire a"));
    if liens.is_empty() {
        return;
    }

    let marquer = {
        let liens = liens.clone();
        move |id: &str| {
            for lien in liens.iter() {
                let vise = lien
                    .get_attribute("href")
                    .is_some_and(|h| h.trim_start_matches('#') == id);
                if vise {
                    let _ = lien.set_attribute("aria-current", "location");
                    outils::poser(&liste, "--y", &(outils::entier(lien.offset_top()) + "px"));
                    outils::poser(
                        &liste,
                        "--h",
                        &(outils::entier(lien.offset_height()) + "px"),
                    );
                } else {
                    let _ = lien.remove_attribute("aria-current");
                }
            }
        }
    };

    let Some(observateur) = outils::observer(BANDE, move |entree, _| {
        if entree.is_intersecting() {
            marquer(&entree.target().id());
        }
    }) else {
        return;
    };
    for lien in liens.iter() {
        let Some(cible) = lien.get_attribute("href") else {
            continue;
        };
        if let Some(titre) = document.get_element_by_id(cible.trim_start_matches('#')) {
            observateur.observe(&titre);
        }
    }
}
