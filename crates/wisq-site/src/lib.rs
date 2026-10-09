//! Le front du site de wisq, en Yew.
//!
//! **Un seul arbre de composants, deux cibles.** La construction le rend en
//! HTML avec `ServerRenderer` (drapeau `ssr`), exactement comme `build.tsx`
//! appelait `renderToString` pour React, et le navigateur reprend cet HTML et
//! lui rattache les comportements (drapeau `hydrate`). La première peinture ne
//! dépend donc pas du WebAssembly, et c'était la première chose vérifiée :
//! `ServerRenderer` produit bien le balisage.
//!
//! **Ce que ce passage coûte, mesuré avant d'écrire une ligne.** Un composant
//! Yew trivial, avec `opt-level = "z"`, LTO, `panic = "abort"`, strip et
//! `wasm-opt -Oz`, rend 188 859 octets de wasm, soit **80 196 gzippés**, plus
//! 6 163 gzippés de colle wasm-bindgen. Le code DOM qu'il remplace en coûtait
//! **1 062**, et le React hydratant que le dépôt avait retiré en coûtait 65 794.
//! Le chiffre est donc au-dessus des deux, et il est écrit ici parce qu'un
//! lecteur de ce fichier doit pouvoir le trouver sans fouiller le journal.
//!
//! **Ce qu'il rachète.** Les quatre comportements du site vivaient dans
//! `src/main.ts`, en code DOM, à côté de composants qui portaient en commentaire
//! « this component never runs in a browser ». Les deux moitiés d'un même objet
//! étaient dans deux fichiers et deux langages, tenues ensemble par le nom d'un
//! attribut. Ici un composant interactif s'écrit comme un composant, et tout le
//! front devient vérifiable par `cargo clippy -D warnings` et `cargo test` —
//! ce qui, dans ce conteneur, est plus que ce qu'on peut dire de l'application.

pub mod content;
pub mod doc;
pub mod installation;
pub mod logo;
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

#[derive(Properties, PartialEq)]
pub struct PageProps {
    pub route: RouteId,
    pub lang: Lang,
}

/// Une page complète : la coquille, et le document de la route à l'intérieur.
#[function_component]
pub fn Page(props: &PageProps) -> Html {
    let corps = match pages::doc(props.route, props.lang) {
        Some(d) => html! { <DocPage doc={d.clone()} /> },
        // Impossible par construction : la construction ne demande que les
        // routes de `pages::PORTEES`, et le binaire de pré-rendu refuse avant
        // d'arriver ici. Le texte est là pour que, si cela arrivait quand même,
        // la page dise ce qui manque au lieu d'être vide.
        None => html! {
            <article class="doc"><div class="wrap">
                <p>{ format!("route non portée en Yew : {}", props.route.slug()) }</p>
            </div></article>
        },
    };
    html! { <Shell route={props.route} lang={props.lang}>{ corps }</Shell> }
}

/// Le point d'entrée du navigateur.
///
/// `hydrate` et non `render` : le HTML est déjà là, produit par la construction,
/// et le reconstruire ferait clignoter la page qu'on vient de peindre.
///
/// La route et la langue viennent du document plutôt que de l'adresse —
/// `build.tsx` les écrit déjà sur `#root` en `data-route` et `data-lang`, et un
/// routeur qui redéduirait l'adresse referait, en wasm, un travail que le
/// serveur a déjà fait et dont le résultat est dans la page.
#[cfg(feature = "hydrate")]
#[wasm_bindgen::prelude::wasm_bindgen(start)]
pub fn hydrater() -> Result<(), wasm_bindgen::JsValue> {
    let document = web_sys::window()
        .and_then(|w| w.document())
        .ok_or_else(|| wasm_bindgen::JsValue::from_str("aucun document"))?;
    let racine = document
        .get_element_by_id("root")
        .ok_or_else(|| wasm_bindgen::JsValue::from_str("aucun #root à hydrater"))?;

    // Un attribut absent ou illisible est un refus, pas un repli : hydrater la
    // mauvaise route produirait une page qui ne correspond pas à son adresse,
    // et le décalage serait silencieux.
    let lire = |nom: &str| -> Result<String, wasm_bindgen::JsValue> {
        racine
            .get_attribute(nom)
            .ok_or_else(|| wasm_bindgen::JsValue::from_str(&format!("#root sans {nom}")))
    };
    let route = RouteId::parse(&lire("data-route")?)
        .ok_or_else(|| wasm_bindgen::JsValue::from_str("data-route inconnue"))?;
    let lang = Lang::parse(&lire("data-lang")?)
        .ok_or_else(|| wasm_bindgen::JsValue::from_str("data-lang inconnue"))?;

    yew::Renderer::<Page>::with_root_and_props(racine, PageProps { route, lang }).hydrate();
    Ok(())
}
