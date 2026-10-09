//! Ce que le module fait en arrivant dans une page, dans l'ordre.
//!
//! 1. **La redirection**, d'abord, parce qu'elle rend tout le reste inutile.
//! 2. **Les deux îlots**, hydratés chacun sur sa racine.
//! 3. **Le mouvement**, qui ne touche qu'au balisage qu'aucun îlot ne tient.
//! 4. **Le service worker**, en dernier : il ne doit jamais disputer à la page
//!    ses premiers octets.
//!
//! Chaque étape refuse en silence plutôt que de lever : un navigateur qui
//! refuse le stockage, un élément absent, une page en cache d'une version
//! précédente doivent laisser un site ordinaire et lisible, pas une erreur.

use wasm_bindgen::closure::Closure;
use wasm_bindgen::{JsCast, JsValue};
use web_sys::{Document, Element, Window};

use crate::content::Lang;
use crate::installation::{InstallPrompt, InstallProps};
use crate::routes::RouteId;
use crate::shell::{Reglages, ReglagesProps};

pub fn demarrer(
    fenetre: &Window,
    document: &Document,
    route: RouteId,
    lang: Lang,
    base: &str,
) -> Result<(), JsValue> {
    if rediriger(fenetre, route, lang) {
        return Ok(());
    }

    // Une racine absente n'est pas un refus : une page d'une version
    // précédente, servie par le cache, peut ne pas avoir l'un des deux îlots,
    // et elle doit garder l'autre.
    if let Some(racine) = ilot(document, "reglages") {
        yew::Renderer::<Reglages>::with_root_and_props(racine, ReglagesProps { route, lang })
            .hydrate();
    }
    if let Some(racine) = ilot(document, "installation") {
        yew::Renderer::<InstallPrompt>::with_root_and_props(racine, InstallProps { lang })
            .hydrate();
    }

    crate::mouvement::demarrer();
    enregistrer(fenetre, document, base);
    Ok(())
}

/// La racine d'un îlot, seulement si elle porte de quoi être hydratée.
///
/// **Un îlot qui ne s'hydrate pas ne doit pas emporter l'autre.** Yew ne sait
/// reprendre un balisage qu'à partir des marqueurs qu'il a posés au pré-rendu ;
/// sans eux il cède, et un module compilé avec `panic = "abort"` ne cède pas à
/// moitié — le sabordage qui retirait les marqueurs des réglages a fait tomber
/// l'invite d'installation et le mouvement avec eux. Un îlot dont la racine ne
/// commence pas par le marqueur d'ouverture reste donc ce qu'il est : du HTML
/// qui marche sans module — des liens, des boutons inertes —, et le reste de la
/// page garde le sien.
fn ilot(document: &Document, nom: &str) -> Option<Element> {
    let racine = document
        .query_selector(&format!(r#"[data-ilot="{nom}"]"#))
        .ok()
        .flatten()?;
    let premier = racine.first_child()?;
    let marque = premier.node_type() == web_sys::Node::COMMENT_NODE
        && premier.node_value().as_deref() == Some("<[]>");
    marque.then_some(racine)
}

/// Envoie un lecteur francophone de l'accueil anglais vers l'accueil français.
///
/// Seulement depuis l'accueil, et seulement s'il n'a jamais choisi : une
/// redirection sur chaque page casserait un lien profond que quelqu'un a
/// délibérément partagé en anglais, ce qui est pire qu'un lecteur qui clique
/// FR une fois.
///
/// `replace` et non `assign` : le retour arrière ne doit pas ramener sur une
/// page qui redirigerait aussitôt.
fn rediriger(fenetre: &Window, route: RouteId, lang: Lang) -> bool {
    if route != RouteId::Home || lang != Lang::En {
        return false;
    }
    if crate::stockage::lire(crate::stockage::LANGUE).is_some() {
        return false;
    }
    let langue = fenetre.navigator().language().unwrap_or_default();
    if !langue.to_lowercase().starts_with("fr") {
        return false;
    }
    let lieu = fenetre.location();
    let Ok(ici) = lieu.href() else {
        return false;
    };
    let Ok(cible) = web_sys::Url::new_with_base("./fr/", &ici) else {
        return false;
    };
    lieu.replace(&cible.href()).is_ok()
}

/// Ce qui rend le site ouvrable sans réseau, et lançable depuis l'écran
/// d'accueil.
///
/// Après `load`, pour ne jamais disputer à la page ses premiers octets — et
/// tout de suite si `load` est déjà passé, ce qui est le cas courant : le
/// module arrive par un `fetch` que `load` n'attend pas.
///
/// **`serviceWorker` est cherché avant d'être appelé.** `web-sys` le déclare
/// non optionnel, donc un navigateur qui ne l'a pas — un contexte non sécurisé,
/// une navigation privée de certains navigateurs — rendrait `undefined` là où
/// la liaison promet un objet, et le premier appel lèverait. Un navigateur qui
/// refuse l'enregistrement obtient un site ordinaire : la promesse rejetée est
/// attrapée, rien ici n'est porteur.
fn enregistrer(fenetre: &Window, document: &Document, base: &str) {
    let navigateur = fenetre.navigator();
    if !js_sys::Reflect::has(&navigateur, &"serviceWorker".into()).unwrap_or(false) {
        return;
    }
    let Ok(ici) = fenetre.location().href() else {
        return;
    };
    let Ok(adresse) = web_sys::Url::new_with_base(&format!("{base}sw.js"), &ici) else {
        return;
    };
    let adresse = adresse.href();
    let inscrire = move || {
        let promesse = navigateur.service_worker().register(&adresse);
        let refus = Closure::once(|_: JsValue| {});
        let _ = promesse.catch(&refus);
        refus.forget();
    };
    if document.ready_state() == "complete" {
        inscrire();
        return;
    }
    let au_chargement = Closure::once(inscrire);
    let _ =
        fenetre.add_event_listener_with_callback("load", au_chargement.as_ref().unchecked_ref());
    au_chargement.forget();
}
