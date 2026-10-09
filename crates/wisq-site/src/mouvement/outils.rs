//! Les quelques gestes que tous les mouvements répètent, écrits une fois.
//!
//! **Rien ici ne lève.** Chaque appel au navigateur peut échouer — un élément
//! absent, une API refusée, un contexte sans fenêtre — et chacun rend `None` ou
//! ne fait rien. Le module est compilé avec `panic = "abort"` : un `unwrap` qui
//! cède n'emporte pas un comportement, il emporte le module entier, thème et
//! invite compris.

use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

use wasm_bindgen::closure::Closure;
use wasm_bindgen::{JsCast, JsValue};
use web_sys::{Document, EventTarget, HtmlElement, Window};

thread_local! {
    /// Levé quand la personne demande moins d'animation en cours de route.
    /// Chaque boucle le lit à chaque image et s'arrête d'elle-même.
    static ARRET: Cell<bool> = const { Cell::new(false) };
}

pub fn arrete() -> bool {
    ARRET.with(Cell::get)
}

pub fn arreter() {
    ARRET.with(|a| a.set(true));
}

/// Une requête média, et `false` pour tout ce qui n'a pas de réponse.
pub fn requete(fenetre: &Window, media: &str) -> bool {
    matches!(fenetre.match_media(media), Ok(Some(r)) if r.matches())
}

/// Tous les éléments d'un sélecteur, déjà convertis.
pub fn tous<T: JsCast>(depuis: &Document, selecteur: &str) -> Vec<T> {
    let Ok(liste) = depuis.query_selector_all(selecteur) else {
        return Vec::new();
    };
    (0..liste.length())
        .filter_map(|i| liste.item(i))
        .filter_map(|n| n.dyn_into::<T>().ok())
        .collect()
}

pub fn un<T: JsCast>(depuis: &Document, selecteur: &str) -> Option<T> {
    depuis.query_selector(selecteur).ok()??.dyn_into::<T>().ok()
}

/// Un écouteur qui vit autant que la page.
///
/// `passif` dit au navigateur que le gestionnaire n'appellera pas
/// `prevent_default`, ce qui le laisse défiler sans attendre le module : c'est
/// vrai de tous les écouteurs du site sauf un, la molette du défilement lissé,
/// qui doit pouvoir reprendre la main.
pub fn ecouter<E: JsCast + 'static>(
    cible: &EventTarget,
    evenement: &str,
    passif: bool,
    gestionnaire: impl FnMut(E) + 'static,
) {
    let mut gestionnaire = gestionnaire;
    let rappel = Closure::<dyn FnMut(JsValue)>::new(move |brut: JsValue| {
        if let Ok(e) = brut.dyn_into::<E>() {
            gestionnaire(e);
        }
    });
    let options = web_sys::AddEventListenerOptions::new();
    options.set_passive(passif);
    let _ = cible.add_event_listener_with_callback_and_add_event_listener_options(
        evenement,
        rappel.as_ref().unchecked_ref(),
        &options,
    );
    rappel.forget();
}

/// Une propriété de style, posée sans lever.
pub fn poser(element: &HtmlElement, nom: &str, valeur: &str) {
    let _ = element.style().set_property(nom, valeur);
}

pub use super::calcul::{borne, entier, milliemes, sortie_cubique};

/// **Une image à la fois, et seulement quand on la demande.**
///
/// Le motif `requestAnimationFrame` qui se reprogramme, écrit une fois : le
/// rappel rend `true` pour demander l'image suivante, et `programmer` ne
/// demande jamais deux fois la même. La fermeture tient un lien faible vers son
/// propre support, sinon les deux se tiendraient en vie l'un l'autre ; ce sont
/// les écouteurs qui gardent le support vivant, et ils vivent autant que la
/// page.
/// Le rappel d'image, tel que `requestAnimationFrame` l'appelle.
type Rappel = Closure<dyn FnMut(f64)>;

pub struct Image {
    rappel: RefCell<Option<Rappel>>,
    attendue: Cell<bool>,
}

impl Image {
    pub fn nouvelle(dessiner: impl FnMut(f64) -> bool + 'static) -> Rc<Image> {
        let mut dessiner = dessiner;
        let image = Rc::new(Image {
            rappel: RefCell::new(None),
            attendue: Cell::new(false),
        });
        let faible: Weak<Image> = Rc::downgrade(&image);
        *image.rappel.borrow_mut() = Some(Closure::new(move |instant: f64| {
            let Some(image) = faible.upgrade() else {
                return;
            };
            image.attendue.set(false);
            if !arrete() && dessiner(instant) {
                image.programmer();
            }
        }));
        image
    }

    pub fn programmer(&self) {
        if self.attendue.get() || arrete() {
            return;
        }
        let Some(fenetre) = web_sys::window() else {
            return;
        };
        if let Some(rappel) = self.rappel.borrow().as_ref() {
            if fenetre
                .request_animation_frame(rappel.as_ref().unchecked_ref())
                .is_ok()
            {
                self.attendue.set(true);
            }
        }
    }
}

/// L'instant présent, en millisecondes, sur l'horloge des images.
pub fn maintenant(fenetre: &Window) -> f64 {
    fenetre.performance().map(|p| p.now()).unwrap_or(0.0)
}

/// Un observateur d'entrée dans la vue, dont le rappel reçoit chaque élément
/// qui entre ou sort.
pub fn observer(
    marge: &str,
    mut rappel: impl FnMut(&web_sys::IntersectionObserverEntry, &web_sys::IntersectionObserver)
        + 'static,
) -> Option<web_sys::IntersectionObserver> {
    let fermeture = Closure::<dyn FnMut(js_sys::Array, web_sys::IntersectionObserver)>::new(
        move |entrees: js_sys::Array, observateur: web_sys::IntersectionObserver| {
            for entree in entrees.iter() {
                if let Ok(entree) = entree.dyn_into::<web_sys::IntersectionObserverEntry>() {
                    rappel(&entree, &observateur);
                }
            }
        },
    );
    let options = web_sys::IntersectionObserverInit::new();
    options.set_root_margin(marge);
    let observateur = web_sys::IntersectionObserver::new_with_options(
        fermeture.as_ref().unchecked_ref(),
        &options,
    )
    .ok()?;
    fermeture.forget();
    Some(observateur)
}
