//! Les documents des pages écrites, dans les deux langues.
//!
//! **Toutes les routes sont portées.** La page `offline` a prouvé la chaîne
//! seule — pré-rendu, hydratation, émission du wasm, budgets, outillage de la
//! CI et d'Heroku — et les huit autres documents n'ont apporté que du contenu :
//! le rendu des neuf sortes de blocs était écrit d'avance. L'accueil n'est pas
//! un document, il a sa propre mise en page (`crate::accueil`), donc il est la
//! seule route pour laquelle `doc` rend `None`.
//!
//! **Le texte a été engendré depuis le TypeScript, pas recopié**, et la
//! construction a confronté les deux rendus avant que le TypeScript ne parte :
//! après normalisation des quatre classes d'écart de sérialisation nommées dans
//! le journal, chaque page Yew était identique à la page React.

mod architecture;
mod docs;
mod faq;
mod offline;
mod privacy;
mod protocol;
mod releases;
mod roadmap;

pub use releases::RELEASED_VERSIONS;

use crate::content::Lang;
use crate::doc::Doc;
use crate::routes::RouteId;

/// Le document d'une route, ou `None` pour l'accueil, qui n'en est pas un.
pub fn doc(route: RouteId, lang: Lang) -> Option<&'static Doc> {
    let en = lang == Lang::En;
    let choisir =
        |anglais: &'static Doc, francais: &'static Doc| Some(if en { anglais } else { francais });
    match route {
        RouteId::Home => None,
        RouteId::Docs => choisir(&docs::DOCS_EN, &docs::DOCS_FR),
        RouteId::Protocol => choisir(&protocol::PROTOCOL_EN, &protocol::PROTOCOL_FR),
        RouteId::Architecture => choisir(
            &architecture::ARCHITECTURE_EN,
            &architecture::ARCHITECTURE_FR,
        ),
        RouteId::Faq => choisir(&faq::FAQ_EN, &faq::FAQ_FR),
        RouteId::Roadmap => choisir(&roadmap::ROADMAP_EN, &roadmap::ROADMAP_FR),
        RouteId::Releases => choisir(&releases::RELEASES_EN, &releases::RELEASES_FR),
        RouteId::Privacy => choisir(&privacy::PRIVACY_EN, &privacy::PRIVACY_FR),
        RouteId::Offline => choisir(&offline::OFFLINE_EN, &offline::OFFLINE_FR),
        RouteId::NotFound => choisir(&offline::NOT_FOUND_EN, &offline::NOT_FOUND_FR),
    }
}
