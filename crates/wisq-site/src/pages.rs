//! Les documents des pages écrites, dans les deux langues.
//!
//! **Une seule page est portée pour l'instant, et c'est voulu.** La page
//! `offline` est la plus petite page réelle du site : pas de comportement
//! propre, servie par le service worker, et son corps tient en deux blocs.
//! Elle suffit donc à prouver toute la chaîne — pré-rendu, hydratation,
//! émission du wasm, budgets, outillage de la CI et d'Heroku — sans porter
//! d'abord les 97 Ko de prose des neuf autres. Elles suivent, une tranche par
//! famille, et n'auront que du contenu à ajouter : le rendu des neuf sortes de
//! blocs est déjà écrit.

use crate::content::Lang;
use crate::doc::{Block, Doc, Tone};
use crate::routes::RouteId;

static OFFLINE_EN: Doc = Doc {
    title: "Offline",
    lede: "This page was never visited while you had a connection, so there was nothing cached to show.",
    blocks: &[
        Block::P("Every page you have opened before is still available — the site keeps them on the device once they have been read. Navigate back to one, or return when you have a network."),
        Block::Note {
            tone: Tone::Info,
            text: "This is the site being offline, not wisq. The local Linux machine in the app needs no network at all.",
        },
    ],
};

static OFFLINE_FR: Doc = Doc {
    title: "Hors ligne",
    lede: "Cette page n'a jamais été visitée pendant que vous aviez une connexion : il n'y avait rien en cache à afficher.",
    blocks: &[
        Block::P("Toutes les pages déjà ouvertes restent disponibles — le site les garde sur l'appareil une fois lues. Revenez à l'une d'elles, ou repassez ici quand vous aurez du réseau."),
        Block::Note {
            tone: Tone::Info,
            text: "C'est le site qui est hors ligne, pas wisq. La machine Linux locale de l'application n'a besoin d'aucun réseau.",
        },
    ],
};

/// Le document d'une route, ou `None` quand cette route n'est pas encore portée
/// en Yew.
///
/// **Le `None` est l'inverse d'un bouchon complaisant.** Il ne rend pas une page
/// vide : il dit que cette route appartient encore à React, et le binaire de
/// pré-rendu refuse en la nommant. Une coquille qui rendrait un document vide
/// pour une route non portée publierait une page blanche, et personne ne le
/// verrait avant un lecteur.
pub fn doc(route: RouteId, lang: Lang) -> Option<&'static Doc> {
    match (route, lang) {
        (RouteId::Offline, Lang::En) => Some(&OFFLINE_EN),
        (RouteId::Offline, Lang::Fr) => Some(&OFFLINE_FR),
        _ => None,
    }
}

/// Les routes que ce crate sait rendre. La construction lit cette liste plutôt
/// que de deviner, et React garde les autres tant qu'elles n'y sont pas.
pub static PORTEES: &[RouteId] = &[RouteId::Offline];
