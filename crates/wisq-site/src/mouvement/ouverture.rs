//! **L'ouverture : la marque se forme dans la poussière.**
//!
//! C'est la pièce de la référence. Sur zamocorp.com, le héros s'épingle et le
//! défilement ne fait plus descendre la page : il déroule une scène, où la
//! marque se rassemble à partir d'une poussière qui flotte, puis un balayage de
//! lumière la traverse. Ici la scène est la même et la marque est `▚` — les
//! deux quadrants de `crate::logo`, la fenêtre sur une machine ailleurs et le
//! téléphone dans la main, plus les trois pas du lien entre eux.
//!
//! **La poussière est calculée, pas filmée.** La référence joue une séquence
//! d'images AVIF pré-rendues ; ici chaque grain est tiré au hasard *dans* la
//! géométrie exacte du logo, avec les mêmes nombres que le SVG, puis rapproché
//! de sa place au fil du défilement. Quand la marque est formée, le SVG
//! apparaît exactement par-dessus — même boîte, mêmes coordonnées — et la
//! poussière s'efface sous lui.
//!
//! **Trois règles, parce que la page a des îlots hydratés :**
//!
//! - ce module ne crée, ne retire et ne déplace **aucun nœud**. Il dessine dans
//!   une toile que le pré-rendu a posée, et il écrit ses variables sur la
//!   section ;
//! - **au repos, la page est celle d'avant.** Sans module, ou avec « réduire les
//!   animations », rien ne s'épingle, la toile n'est pas affichée, la marque
//!   est le SVG fixe : chaque variable a la valeur de l'état final par défaut ;
//! - le dessin ne tourne que quand la scène est visible, et ne redessine plus
//!   qu'au défilement une fois la marque formée.

use std::cell::Cell;
use std::rc::Rc;

use super::outils;
use wasm_bindgen::JsCast;
use web_sys::{
    CanvasRenderingContext2d, Document, Element, HtmlCanvasElement, HtmlElement, Window,
};

/// Un grain : sa place dans la marque (en unités du SVG, boîte de 240), d'où il
/// part (un angle et une distance au centre de la marque), et ce qui le rend
/// vivant.
struct Grain {
    cx: f64,
    cy: f64,
    depart: (f64, f64),
    retard: f64,
    phase: f64,
    taille: f64,
    teinte: Teinte,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Teinte {
    /// Le haut du dégradé de la marque, `#a8a2ff`.
    Claire,
    /// Le bas, `#6f64ff`.
    Profonde,
    /// Les trois pas du lien, `#8b83ff` — la couleur du filet de la plaque.
    Lien,
}

impl Teinte {
    fn couleur(self) -> &'static str {
        match self {
            Teinte::Claire => "#a8a2ff",
            Teinte::Profonde => "#6f64ff",
            Teinte::Lien => "#8b83ff",
        }
    }
}

const TEINTES: [Teinte; 3] = [Teinte::Claire, Teinte::Profonde, Teinte::Lien];

use super::calcul::{dans_carre_arrondi, rampe, COTE, ECRAN, FENETRE, PAS, RAYON, TELEPHONE};

/// Où tombe un point de la boîte de 240 : dans quelle partie de la marque, et de
/// quelle teinte. `None` hors de la marque — et dans l'écran du téléphone, qui
/// est un trou : c'est lui qui fait d'un carré un téléphone.
fn dans_la_marque(x: f64, y: f64) -> Option<Teinte> {
    let degrade = |x: f64, y: f64| {
        // Le dégradé du SVG va du coin haut-gauche au coin bas-droit de chaque
        // quadrant ; la teinte suit, avec du désordre pour qu'une moitié ne
        // soit pas d'une seule encre.
        if (x + y) / 480.0 + 0.25 * (hasard() - 0.5) < 0.5 {
            Teinte::Claire
        } else {
            Teinte::Profonde
        }
    };
    if dans_carre_arrondi(x, y, FENETRE, FENETRE, COTE, COTE, RAYON) {
        return Some(degrade(x, y));
    }
    if dans_carre_arrondi(x, y, TELEPHONE, TELEPHONE, COTE, COTE, RAYON) {
        let (ex, ey, el, eh, er) = ECRAN;
        if dans_carre_arrondi(x, y, ex, ey, el, eh, er) {
            return None;
        }
        return Some(degrade(x, y));
    }
    None
}

fn hasard() -> f64 {
    js_sys::Math::random()
}

fn echantillonner(nombre: usize) -> Vec<Grain> {
    let mut grains = Vec::with_capacity(nombre + 36);
    let nouveau = |cx: f64, cy: f64, teinte: Teinte| Grain {
        cx,
        cy,
        // D'où vient chaque grain : un nuage autour de la marque plutôt
        // qu'une pluie sur toute la scène. Le premier jet tirait les départs
        // n'importe où dans la toile, et la capture l'a montré : une poussière
        // uniforme sur le titre et l'accroche ne se lit pas comme une marque
        // qui se forme, elle se lit comme une page sale. La racine carrée
        // répartit les grains uniformément dans le disque ; le plancher garde
        // le centre un peu plus clair que les bords.
        depart: (
            hasard() * std::f64::consts::TAU,
            0.18 + 0.82 * hasard().sqrt(),
        ),
        // La marque se forme de gauche à droite — la fenêtre d'abord, le
        // téléphone ensuite —, avec du désordre dedans.
        retard: 0.1 * hasard() + 0.14 * ((cx - FENETRE) / (TELEPHONE + COTE - FENETRE)),
        phase: hasard() * std::f64::consts::TAU,
        taille: 0.75 + hasard() * 0.6,
        teinte,
    };
    let mut essais = 0;
    while grains.len() < nombre && essais < nombre * 8 {
        essais += 1;
        let x = FENETRE + hasard() * (TELEPHONE + COTE - FENETRE);
        let y = FENETRE + hasard() * (TELEPHONE + COTE - FENETRE);
        if let Some(teinte) = dans_la_marque(x, y) {
            grains.push(nouveau(x, y, teinte));
        }
    }
    // Les trois pas du lien : douze grains chacun, serrés sur leur disque.
    for c in PAS {
        for _ in 0..12 {
            let angle = hasard() * std::f64::consts::TAU;
            let r = 2.5 * hasard().sqrt();
            grains.push(nouveau(
                c + r * angle.cos(),
                c + r * angle.sin(),
                Teinte::Lien,
            ));
        }
    }
    grains
}

/// Où en est le défilement de l'ouverture, de 0 à 1. Une section qui n'est pas
/// plus haute que la fenêtre n'a pas de course — c'est le cas au repos, et sur
/// un écran trop court pour épingler — : elle est à 1, l'état final.
fn progression(fenetre: &Window, section: &Element) -> f64 {
    let cadre = section.get_bounding_client_rect();
    let vue = fenetre
        .inner_height()
        .ok()
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    let course = cadre.height() - vue;
    if course > 1.0 {
        outils::borne(-cadre.top() / course, 0.0, 1.0)
    } else {
        1.0
    }
}

/// Les étapes de la scène, en fraction de la course. Écrites ensemble pour
/// qu'on les lise comme une partition.
mod partition {
    /// La poussière est rassemblée quand le dernier grain a fini son voyage :
    /// retard maximal 0,24, plus 0,3 de voyage.
    pub const FORMEE: f64 = 0.54;
    /// Le SVG apparaît par-dessus la poussière formée…
    pub const MARQUE: (f64, f64) = (0.5, 0.62);
    /// …puis la poussière s'efface sous lui…
    pub const POUSSIERE: (f64, f64) = (0.6, 0.7);
    /// …et la lumière traverse la marque et le nom.
    pub const LUEUR: (f64, f64) = (0.62, 0.9);
    /// La durée du voyage d'un grain, en fraction de la course.
    pub const VOYAGE: f64 = 0.3;
}

pub fn demarrer(fenetre: &Window, document: &Document) {
    let Some(section) = outils::un::<HtmlElement>(document, "[data-ouverture]") else {
        return;
    };
    let Some(toile) = section
        .query_selector(".hero-dust")
        .ok()
        .flatten()
        .and_then(|t| t.dyn_into::<HtmlCanvasElement>().ok())
    else {
        return;
    };
    let Some(logo) = section.query_selector(".hero-logo").ok().flatten() else {
        return;
    };
    let etroit = fenetre
        .inner_width()
        .ok()
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0)
        < 600.0;
    let grains = echantillonner(if etroit { 1100 } else { 2200 });

    let visible = Rc::new(Cell::new(true));
    let derniere = Rc::new(Cell::new(-1.0_f64));

    let image = {
        let fenetre = fenetre.clone();
        let section = section.clone();
        let visible = visible.clone();
        outils::Image::nouvelle(move |instant| {
            dessiner(
                &fenetre, &section, &toile, &logo, &grains, &visible, &derniere, instant,
            )
        })
    };

    if let Some(observateur) = {
        let visible = visible.clone();
        let image = image.clone();
        outils::observer("0px", move |entree, _| {
            visible.set(entree.is_intersecting());
            if entree.is_intersecting() {
                image.programmer();
            }
        })
    } {
        observateur.observe(&section);
    }

    for evenement in ["scroll", "resize"] {
        let image = image.clone();
        outils::ecouter::<web_sys::Event>(fenetre, evenement, true, move |_| image.programmer());
    }
    image.programmer();
}

#[allow(clippy::too_many_arguments)]
fn dessiner(
    fenetre: &Window,
    section: &HtmlElement,
    toile: &HtmlCanvasElement,
    logo: &Element,
    grains: &[Grain],
    visible: &Cell<bool>,
    derniere: &Cell<f64>,
    instant: f64,
) -> bool {
    let p = progression(fenetre, section);
    let forme = rampe(p, partition::MARQUE);
    let poussiere = 1.0 - rampe(p, partition::POUSSIERE);
    let lueur = rampe(p, partition::LUEUR);

    // Les variables de la scène, en millièmes : la feuille de style en fait une
    // opacité, un éclat, une position. Absentes, elles valent l'état final. La
    // poussière n'en a pas : c'est la toile qui l'efface, par son alpha.
    outils::poser(section, "--ouverture", &outils::milliemes(p));
    outils::poser(section, "--forme", &outils::milliemes(forme));
    outils::poser(section, "--lueur", &outils::milliemes(lueur));

    if !visible.get() {
        return false;
    }
    // Tant que la poussière flotte, chaque image compte ; une fois la marque
    // formée, on ne redessine qu'au défilement.
    let vivante = p < partition::FORMEE;
    if !vivante && (p - derniere.get()).abs() < 0.0005 {
        return false;
    }
    derniere.set(p);

    let Some(ctx) = toile
        .get_context("2d")
        .ok()
        .flatten()
        .and_then(|c| c.dyn_into::<CanvasRenderingContext2d>().ok())
    else {
        return false;
    };
    let ratio = fenetre.device_pixel_ratio().clamp(1.0, 2.0);
    let (largeur, hauteur) = (
        f64::from(toile.client_width()),
        f64::from(toile.client_height()),
    );
    if largeur <= 0.0 || hauteur <= 0.0 {
        return vivante;
    }
    let (lp, hp) = (
        (largeur * ratio).round() as u32,
        (hauteur * ratio).round() as u32,
    );
    if toile.width() != lp || toile.height() != hp {
        toile.set_width(lp);
        toile.set_height(hp);
    }
    let _ = ctx.set_transform(ratio, 0.0, 0.0, ratio, 0.0, 0.0);
    ctx.clear_rect(0.0, 0.0, largeur, hauteur);
    if poussiere <= 0.0 {
        return false;
    }
    ctx.set_global_alpha(poussiere);

    // La marque cible : la boîte du SVG, dans le repère de la toile. Relue à
    // chaque image, parce que la mise en page bouge — une police qui arrive,
    // un écran qu'on tourne.
    let cible = logo.get_bounding_client_rect();
    let origine = toile.get_bounding_client_rect();
    let echelle = cible.width() / 240.0;
    let (ox, oy) = (cible.left() - origine.left(), cible.top() - origine.top());
    let t = instant / 1000.0;
    // Le nuage : centré sur la marque, plus large que haut, et à l'échelle de
    // la scène pour qu'il ait la même allure sur un téléphone et sur un écran
    // de bureau.
    let (cx, cy) = (ox + cible.width() / 2.0, oy + cible.height() / 2.0);
    let (rx, ry) = (largeur.max(hauteur) * 0.42, hauteur.min(largeur) * 0.36);
    // Un grain trop fin disparaît sur un écran ordinaire ; trop gros, la marque
    // formée a l'air pixelisée. Il suit la taille du logo, avec un plancher.
    let grain = (echelle * 1.6).max(1.1);

    for teinte in TEINTES {
        ctx.set_fill_style_str(teinte.couleur());
        for g in grains.iter().filter(|g| g.teinte == teinte) {
            let a = outils::sortie_cubique((p - g.retard) / partition::VOYAGE);
            let flotte = (1.0 - a) * 22.0;
            let (angle, rayon) = g.depart;
            let sx = cx + angle.cos() * rayon * rx + (t * 0.6 + g.phase).sin() * flotte;
            let sy = cy + angle.sin() * rayon * ry + (t * 0.5 + g.phase).cos() * flotte;
            let x = sx + (ox + g.cx * echelle - sx) * a;
            let y = sy + (oy + g.cy * echelle - sy) * a;
            let cote = grain * g.taille * (1.0 + (1.0 - a) * 0.8);
            ctx.fill_rect(x - cote / 2.0, y - cote / 2.0, cote, cote);
        }
    }
    ctx.set_global_alpha(1.0);
    vivante
}
