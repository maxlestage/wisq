//! **La bande que le défilement pousse.**
//!
//! Au repos elle avance seule, lentement. Quand on défile, elle prend de
//! l'élan dans le sens du défilement — vers le bas, elle file ; vers le haut,
//! elle repart à l'envers — et se penche un peu sous la vitesse, puis l'élan
//! s'éteint et elle reprend son pas. C'est le geste de la référence, et une
//! animation CSS ne sait pas le faire : sa vitesse est écrite d'avance.
//!
//! **Elle ne tourne que visible.** Un observateur compte les bandes à l'écran ;
//! quand il n'y en a plus, la boucle s'arrête, et la première qui revient la
//! relance. Sous le pointeur, elle ralentit presque à l'arrêt, pour qu'on
//! puisse lire un mot.

use std::cell::Cell;
use std::rc::Rc;

use super::calcul::{amortir, borne, enrouler};
use super::outils;
use web_sys::{Document, HtmlElement, Window};

/// Le pas de la bande au repos, en pixels par seconde.
const PAS: f64 = 55.0;
/// Ce qu'un pixel défilé ajoute à l'élan, en pixels par seconde.
const POUSSEE: f64 = 9.0;
/// L'élan le plus fort, dans un sens comme dans l'autre.
const ELAN_MAX: f64 = 2400.0;
/// Le temps que met l'élan à retomber de moitié, à peu près, en millisecondes.
const EXTINCTION: f64 = 280.0;
/// La part du pas qui reste sous le pointeur.
const SOUS_LE_POINTEUR: f64 = 0.12;

struct Piste {
    element: HtmlElement,
    tour: Cell<f64>,
    decalage: Cell<f64>,
}

impl Piste {
    /// La piste porte deux fois ses mots : un tour, c'est la moitié de sa
    /// largeur. Mesuré au départ et à chaque redimensionnement, jamais à
    /// chaque image.
    fn mesurer(&self) {
        self.tour.set(f64::from(self.element.scroll_width()) / 2.0);
    }
}

pub fn demarrer(fenetre: &Window, document: &Document) {
    let pistes: Rc<Vec<Piste>> = Rc::new(
        outils::tous::<HtmlElement>(document, ".bande-piste")
            .into_iter()
            .map(|element| Piste {
                element,
                tour: Cell::new(0.0),
                decalage: Cell::new(0.0),
            })
            .collect(),
    );
    if pistes.is_empty() {
        return;
    }
    for piste in pistes.iter() {
        piste.mesurer();
    }

    let elan = Rc::new(Cell::new(0.0));
    let sens = Rc::new(Cell::new(1.0));
    let visibles = Rc::new(Cell::new(0));
    let survolees = Rc::new(Cell::new(0));
    let dernier = Rc::new(Cell::new(0.0));

    let image = {
        let (pistes, elan, sens) = (pistes.clone(), elan.clone(), sens.clone());
        let (visibles, survolees, dernier) = (visibles.clone(), survolees.clone(), dernier.clone());
        outils::Image::nouvelle(move |instant| {
            let dt = if dernier.get() == 0.0 {
                0.0
            } else {
                borne(instant - dernier.get(), 0.0, 64.0)
            };
            dernier.set(instant);
            elan.set(amortir(elan.get(), dt, EXTINCTION));
            let frein = if survolees.get() > 0 {
                SOUS_LE_POINTEUR
            } else {
                1.0
            };
            let vitesse = (PAS * sens.get() + elan.get()) * frein;
            // La pente vient de l'élan seul : au repos, la bande est droite.
            let penche = (borne(elan.get() / ELAN_MAX, -1.0, 1.0) * 60.0).round() as i32;
            for piste in pistes.iter() {
                let d = enrouler(
                    piste.decalage.get() + vitesse * dt / 1000.0,
                    piste.tour.get(),
                );
                piste.decalage.set(d);
                let px = outils::entier(-(d.round() as i32)) + "px";
                outils::poser(&piste.element, "--d", &px);
                outils::poser(&piste.element, "--penche", &outils::entier(penche));
            }
            visibles.get() > 0
        })
    };

    {
        let (fenetre_, elan, sens, image) = (fenetre.clone(), elan.clone(), sens, image.clone());
        let precedent = Cell::new(fenetre.scroll_y().unwrap_or(0.0));
        outils::ecouter::<web_sys::Event>(fenetre, "scroll", true, move |_| {
            let y = fenetre_.scroll_y().unwrap_or(0.0);
            let dy = y - precedent.get();
            precedent.set(y);
            if dy == 0.0 {
                return;
            }
            sens.set(if dy > 0.0 { 1.0 } else { -1.0 });
            elan.set(borne(elan.get() + dy * POUSSEE, -ELAN_MAX, ELAN_MAX));
            image.programmer();
        });
    }
    {
        let pistes = pistes.clone();
        outils::ecouter::<web_sys::Event>(fenetre, "resize", true, move |_| {
            for piste in pistes.iter() {
                piste.mesurer();
            }
        });
    }

    let Some(observateur) = outils::observer("0px", {
        let (visibles, dernier, image) = (visibles.clone(), dernier.clone(), image.clone());
        move |entree, _| {
            let n = visibles.get() + if entree.is_intersecting() { 1 } else { -1 };
            visibles.set(n.max(0));
            if entree.is_intersecting() {
                // Repartir d'un instant neuf : sans ça, la première image après
                // une longue absence avancerait de tout le temps écoulé.
                dernier.set(0.0);
                image.programmer();
            }
        }
    }) else {
        return;
    };
    for bande in outils::tous::<HtmlElement>(document, ".bande") {
        observateur.observe(&bande);
        let survolees_ = survolees.clone();
        outils::ecouter::<web_sys::PointerEvent>(&bande, "pointerenter", true, move |_| {
            survolees_.set(survolees_.get() + 1);
        });
        let survolees_ = survolees.clone();
        outils::ecouter::<web_sys::PointerEvent>(&bande, "pointerleave", true, move |_| {
            survolees_.set((survolees_.get() - 1).max(0));
        });
    }
}
