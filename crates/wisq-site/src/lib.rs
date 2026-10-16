//! Le front du site de wisq, écrit avec **Active** — la bibliothèque
//! front-end en Rust de Maxime Nathan Lestage, <https://github.com/maxlestage/Active>.
//! Tout le front, depuis que React puis Yew sont partis.
//!
//! **Un seul arbre de vues, trois cibles.** La construction le rend en HTML
//! avec `Node::render` (drapeau `ssr`, binaire `wisq-site-prerender`), et le
//! navigateur en reprend **les îlots** — les réglages de l'en-tête, l'invite
//! d'installation, et sur la page `linux/` le terminal — en WebAssembly
//! (drapeau `hydrate`, et `linux` pour le module qui porte la machine). La
//! première peinture ne dépend donc pas du module.
//!
//! **Ce que le passage à Active change.** Une vue est une fonction qui rend un
//! `Node`, construit par des appels chaînés plutôt que par une macro ; l'état
//! est un `State<T>` qu'on déplace dans les fermetures, et un changement ne
//! réécrit que le texte, l'attribut ou la classe qui en dépend — pas de DOM
//! virtuel, pas de second rendu du contenu statique. Les îlots sont un concept
//! de la bibliothèque (`active::island`, `active::hydrate`) plutôt qu'une
//! construction de ce crate : le pré-rendu n'a plus à rendre chaque îlot deux
//! fois pour poser des marqueurs à la main.
//!
//! **Ce que le module pèse est tenu par un plafond, et par lui seul** —
//! `site/tests/build.test.ts`, « le front en WebAssembly reste dans son
//! budget ». L'historique des mesures de l'époque Yew est dans `docs/JOURNAL.md`.

pub mod accueil;
pub mod console;
pub mod content;
#[cfg(test)]
mod contenu_tests;
pub mod doc;
pub mod installation;
pub mod linux;
pub mod logo;
pub mod mouvement;
#[cfg(feature = "hydrate")]
mod navigateur;
pub mod pages;
pub mod routes;
pub mod shell;
pub mod stockage;
pub mod theme;

use active::Node;
use content::Lang;
use routes::RouteId;

/// Une page complète : la coquille, et ce que la route montre à l'intérieur —
/// la mise en page de l'accueil, celle de la page Linux, ou le document d'une
/// page écrite.
pub fn page(route: RouteId, lang: Lang) -> Node {
    let corps = match (route, pages::doc(route, lang)) {
        (_, Some(d)) => doc::doc_page(d, lang),
        (RouteId::Linux, None) => linux::page(lang),
        (_, None) => accueil::accueil(lang),
    };
    shell::shell(route, lang, corps)
}

/// Le point d'entrée du navigateur.
///
/// **Des îlots, pas la page.** Le HTML est déjà là, produit par la
/// construction, et il est complet : seuls les îlots ont un état, donc seuls
/// eux sont hydratés, chacun sur sa racine `<active-island>`. Le reste — la
/// prose, l'accueil, le pied — n'est jamais repris par Active, et c'est ce qui
/// garde la prose hors du module : voir `shell::reglages` pour la mesure.
///
/// La route et la langue viennent du document plutôt que de l'adresse : la
/// construction les écrit sur `#root` en `data-route` et `data-lang`, et un
/// routeur qui redéduirait l'adresse referait, en wasm, un travail que le
/// serveur a déjà fait et dont le résultat est dans la page.
#[cfg(feature = "hydrate")]
#[wasm_bindgen::prelude::wasm_bindgen(start)]
pub fn hydrater() -> Result<(), wasm_bindgen::JsValue> {
    let fenetre =
        web_sys::window().ok_or_else(|| wasm_bindgen::JsValue::from_str("aucune fenêtre"))?;
    let document = fenetre
        .document()
        .ok_or_else(|| wasm_bindgen::JsValue::from_str("aucun document"))?;
    let racine = document
        .get_element_by_id("root")
        .ok_or_else(|| wasm_bindgen::JsValue::from_str("aucun #root"))?;

    // Un attribut absent ou illisible est un refus, pas un repli : hydrater
    // avec la mauvaise route produirait des liens de langue qui ne mènent pas
    // à la contrepartie de la page, et le décalage serait silencieux.
    let lire = |nom: &str| -> Result<String, wasm_bindgen::JsValue> {
        racine
            .get_attribute(nom)
            .ok_or_else(|| wasm_bindgen::JsValue::from_str(&format!("#root sans {nom}")))
    };
    let route = RouteId::parse(&lire("data-route")?)
        .ok_or_else(|| wasm_bindgen::JsValue::from_str("data-route inconnue"))?;
    let lang = Lang::parse(&lire("data-lang")?)
        .ok_or_else(|| wasm_bindgen::JsValue::from_str("data-lang inconnue"))?;
    let base = lire("data-base")?;

    navigateur::demarrer(&fenetre, &document, route, lang, &base)
}
