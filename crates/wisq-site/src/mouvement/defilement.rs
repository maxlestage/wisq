//! **Le défilement lissé**, ce que Lenis fait pour la référence.
//!
//! La molette d'une souris avance par crans ; Lenis les accumule dans une cible
//! et y fait glisser la page, image après image. C'est ce qui donne à la
//! référence son poids, et c'est ce que fait ce module — en mode natif, comme
//! le recommande la documentation de Lenis elle-même : la page défile vraiment,
//! par `scrollTo`, donc la barre de défilement, la recherche dans la page, les
//! ancres et les technologies d'assistance voient un défilement ordinaire.
//!
//! **Et seulement là où il a un sens.** À la souris (`pointer: fine` et
//! `hover: hover`) : un écran tactile a déjà son inertie, et l'iPhone, qui est
//! le sujet de ce projet, la fait mieux que n'importe quel script. Jamais avec
//! « réduire les animations » : `crate::mouvement` ne démarre pas du tout.
//! Jamais pour un défilement horizontal, un zoom au clavier (`ctrl`/`meta`), ou
//! un élément qui défile lui-même : le lecteur garde la main sur tout ce qui
//! n'est pas la page.
//!
//! Le clavier, la barre et les ancres ne passent pas par ici. Un appui de
//! touche ou un clic pendant le glissement l'interrompt, pour qu'il ne se batte
//! jamais contre un geste du lecteur.

use std::cell::Cell;
use std::rc::Rc;

use super::outils;
use wasm_bindgen::JsCast;
use web_sys::{Document, Element, Window};

/// La part du chemin restant parcourue par image à 60 Hz. Celle de Lenis par
/// défaut : 0,1.
const LISSAGE: f64 = 0.1;
/// Une image à 60 Hz, en millisecondes : la part se recalcule sur le temps
/// réellement écoulé, sinon un écran à 120 Hz glisserait deux fois plus vite.
const IMAGE_MS: f64 = 1000.0 / 60.0;

struct Etat {
    courant: Cell<f64>,
    cible: Cell<f64>,
    actif: Cell<bool>,
    precedent: Cell<f64>,
}

pub fn demarrer(fenetre: &Window, document: &Document) {
    if !outils::requete(fenetre, "(pointer: fine)") || !outils::requete(fenetre, "(hover: hover)") {
        return;
    }
    let etat = Rc::new(Etat {
        courant: Cell::new(0.0),
        cible: Cell::new(0.0),
        actif: Cell::new(false),
        precedent: Cell::new(0.0),
    });

    let image = {
        let etat = etat.clone();
        let fenetre = fenetre.clone();
        outils::Image::nouvelle(move |instant| {
            if !etat.actif.get() {
                return false;
            }
            let ecoule = if etat.precedent.get() > 0.0 {
                (instant - etat.precedent.get()).clamp(1.0, 100.0)
            } else {
                IMAGE_MS
            };
            etat.precedent.set(instant);
            let part = 1.0 - (1.0 - LISSAGE).powf(ecoule / IMAGE_MS);
            let (c, t) = (etat.courant.get(), etat.cible.get());
            let suivant = c + (t - c) * part;
            let fini = (t - suivant).abs() < 0.5;
            let y = if fini { t } else { suivant };
            etat.courant.set(y);
            aller(&fenetre, y);
            if fini {
                etat.actif.set(false);
            }
            !fini
        })
    };

    {
        let etat = etat.clone();
        let fenetre = fenetre.clone();
        let document = document.clone();
        outils::ecouter::<web_sys::WheelEvent>(
            &fenetre.clone(),
            "wheel",
            false,
            move |evenement| {
                if outils::arrete() || evenement.ctrl_key() || evenement.meta_key() {
                    return;
                }
                let facteur = match evenement.delta_mode() {
                    1 => 16.0,
                    2 => fenetre
                        .inner_height()
                        .ok()
                        .and_then(|v| v.as_f64())
                        .unwrap_or(800.0),
                    _ => 1.0,
                };
                let (dx, dy) = (evenement.delta_x() * facteur, evenement.delta_y() * facteur);
                if dy == 0.0 || dx.abs() > dy.abs() || evenement.shift_key() {
                    return;
                }
                if defile_lui_meme(&fenetre, evenement.target()) {
                    return;
                }
                evenement.prevent_default();
                if !etat.actif.get() {
                    let ici = fenetre.scroll_y().unwrap_or(0.0);
                    etat.courant.set(ici);
                    etat.cible.set(ici);
                    etat.precedent.set(0.0);
                }
                let maximum = document
                    .document_element()
                    .map(|r| f64::from(r.scroll_height()))
                    .unwrap_or(0.0)
                    - fenetre
                        .inner_height()
                        .ok()
                        .and_then(|v| v.as_f64())
                        .unwrap_or(0.0);
                etat.cible
                    .set(outils::borne(etat.cible.get() + dy, 0.0, maximum.max(0.0)));
                etat.actif.set(true);
                image.programmer();
            },
        );
    }

    // Un geste du lecteur reprend la main : on lâche au lieu de lutter.
    for evenement in ["keydown", "pointerdown"] {
        let etat = etat.clone();
        outils::ecouter::<web_sys::Event>(fenetre, evenement, true, move |_| {
            etat.actif.set(false);
        });
    }
}

/// `scrollTo` immédiat. `html` porte `scroll-behavior: smooth` pour les ancres,
/// et un `scrollTo` ordinaire hériterait de ce lissage à chaque image : le
/// navigateur lancerait une animation par image, chacune annulant la
/// précédente.
fn aller(fenetre: &Window, y: f64) {
    let options = web_sys::ScrollToOptions::new();
    options.set_top(y);
    options.set_behavior(web_sys::ScrollBehavior::Instant);
    fenetre.scroll_to_with_scroll_to_options(&options);
}

/// Un ancêtre de la cible qui défile verticalement par lui-même.
fn defile_lui_meme(fenetre: &Window, cible: Option<web_sys::EventTarget>) -> bool {
    let mut courant = cible.and_then(|c| c.dyn_into::<Element>().ok());
    while let Some(element) = courant {
        if element.scroll_height() > element.client_height() + 1 {
            if let Ok(Some(style)) = fenetre.get_computed_style(&element) {
                let debord = style.get_property_value("overflow-y").unwrap_or_default();
                if debord == "auto" || debord == "scroll" {
                    return true;
                }
            }
        }
        courant = element.parent_element();
    }
    false
}
