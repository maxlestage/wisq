//! Le front du site de wisq, en Yew — tout le front, depuis que React est parti.
//!
//! **Un seul arbre de composants, deux cibles.** La construction le rend en
//! HTML avec `ServerRenderer` (drapeau `ssr`, binaire `wisq-site-prerender`), et
//! le navigateur en reprend **deux îlots** — les réglages de l'en-tête et
//! l'invite d'installation — en WebAssembly (drapeau `hydrate`). La première
//! peinture ne dépend donc pas du module, et c'était la première chose
//! vérifiée : `ServerRenderer` produit bien le balisage.
//!
//! **Ce que ce passage coûte, mesuré à chaque tranche.**
//!
//! | | brut | gzip |
//! | --- | --- | --- |
//! | un composant Yew trivial, première sonde | 188 859 | 80 196 |
//! | une page portée, thème seul (#331) | 253 728 | 106 392 |
//! | toutes les pages, hydratées entières | 351 822 | 148 277 |
//! | deux îlots, tout le mouvement | 261 252 | 112 436 |
//!
//! Le code DOM que Yew a remplacé en coûtait 1 062 gzippés, et le React
//! hydratant que le dépôt avait retiré avant lui 65 794. La troisième ligne est
//! celle qu'on n'a pas prise : voir `shell::Reglages` pour la raison, et
//! `mouvement` pour ce que coûte la quatrième au-delà des îlots.
//!
//! **Ce qu'il rachète.** Les comportements du site vivaient dans `src/main.ts`,
//! en code DOM, à côté de composants React qui portaient en commentaire « this
//! component never runs in a browser ». Les deux moitiés d'un même objet étaient
//! dans deux fichiers et deux langages, tenues ensemble par le nom d'un
//! attribut. Ici un composant interactif s'écrit comme un composant, le
//! mouvement comme du Rust, et tout le front est vérifiable par `cargo clippy
//! -D warnings` et `cargo test` — ce qui, dans ce conteneur, est plus que ce
//! qu'on peut dire de l'application.

pub mod accueil;
pub mod content;
#[cfg(test)]
mod contenu_tests;
pub mod doc;
pub mod installation;
pub mod logo;
pub mod mouvement;
#[cfg(feature = "hydrate")]
mod navigateur;
pub mod pages;
pub mod routes;
pub mod shell;
pub mod stockage;
pub mod theme;

use content::Lang;
use doc::DocPage;
use routes::RouteId;
use shell::Shell;
use yew::prelude::*;

#[derive(Properties, PartialEq, Clone)]
pub struct PageProps {
    pub route: RouteId,
    pub lang: Lang,
}

/// Une page complète : la coquille, et ce que la route montre à l'intérieur —
/// la mise en page de l'accueil, ou le document d'une page écrite.
#[function_component]
pub fn Page(props: &PageProps) -> Html {
    let corps = match pages::doc(props.route, props.lang) {
        Some(d) => html! { <DocPage doc={d.clone()} /> },
        None => html! { <accueil::Accueil lang={props.lang} /> },
    };
    html! { <Shell route={props.route} lang={props.lang}>{ corps }</Shell> }
}

/// Le point d'entrée du navigateur.
///
/// **Des îlots, pas la page.** Le HTML est déjà là, produit par la
/// construction, et il est complet : seuls deux endroits ont un état — les
/// réglages de l'en-tête, l'invite d'installation —, donc seuls ces deux-là
/// sont hydratés, chacun sur sa racine. Le reste — la prose, l'accueil, le
/// pied — n'est jamais repris par Yew, et c'est ce qui garde la prose hors du
/// module : voir `shell::Reglages` pour la mesure.
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
