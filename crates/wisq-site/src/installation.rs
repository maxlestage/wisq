//! Ce qui transforme le site en quelque chose sur l'écran d'accueil.
//!
//! Deux plateformes, deux mécanismes, et celui qui intéresse ce projet est
//! celui qui n'a pas d'API. Chromium émet `beforeinstallprompt` et confie une
//! invite à appeler plus tard ; Safari sur iOS n'émet rien du tout et installe
//! par la feuille de partage, donc la seule chose honnête à y proposer est les
//! trois gestes qui marchent.
//!
//! **Les deux formulations sont rendues, et les deux partent masquées.** Savoir
//! laquelle s'applique est un fait sur le navigateur, donc impossible à la
//! construction. Le composant part donc de « rien à montrer » des deux côtés —
//! Active reprend le balisage tel que le serveur l'a écrit — et un `on_mount`,
//! qui ne tourne que dans le navigateur, décide ensuite.
//!
//! **Ce que le portage rachète.** La version DOM révélait la bannière en
//! retirant des attributs `hidden` posés sur un balisage qu'elle n'avait pas
//! écrit, retrouvé par des sélecteurs. Ici l'état décide du balisage, et le
//! balisage est à côté de l'état.

use std::cell::RefCell;
use std::rc::Rc;

use active::prelude::*;
use active::Node;

use crate::content::Lang;

/// La clé du renvoi : un lecteur qui a dit « plus tard » ne doit pas se voir
/// redemander à chaque page.
pub const RENVOI: &str = "wisq.install.dismissed";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Variante {
    /// Chromium : un bouton qui rejoue l'invite retenue.
    Invite,
    /// iOS : les trois gestes, et aucun bouton qui puisse rien faire.
    Ios,
}

/// L'événement retenu pour être rejoué sur un geste. Un `JsValue` dans le
/// navigateur ; rien au pré-rendu, qui n'a ni événement ni geste.
#[cfg(feature = "hydrate")]
type Retenu = Option<wasm_bindgen::JsValue>;
#[cfg(not(feature = "hydrate"))]
type Retenu = Option<()>;

/// L'îlot de l'invite. Ses propriétés sont le code de la langue.
pub fn install_prompt(props: &str) -> Node {
    let lang = Lang::parse(props).unwrap_or(Lang::En);
    let variante = use_state(None::<Variante>);
    let renvoyee = use_state(false);
    let retenu: Rc<RefCell<Retenu>> = Rc::new(RefCell::new(None));

    let cacher = move || {
        renvoyee.set(true);
        crate::stockage::ecrire(RENVOI, "1");
    };
    let montree = move || variante.get().is_some() && !renvoyee.get();
    let est = move |v: Variante| move || variante.get() == Some(v);

    let copy = lang.copy();
    let guet = retenu.clone();
    aside()
        .class("install-banner")
        .attr("role", "complementary")
        .bool_attr("hidden", move || !montree())
        .attr("data-install", "")
        .on_mount(move |_| guetter(move |v| variante.set(Some(v)), guet.clone()))
        .child(
            div()
                .class("wrap install-banner-inner")
                .child(
                    div()
                        .attr("data-install-variant", "prompt")
                        .bool_attr("hidden", {
                            let oui = est(Variante::Invite);
                            move || !oui()
                        })
                        .child(strong().text(copy.pwa.title))
                        .child(p().text(copy.pwa.body)),
                )
                .child(
                    div()
                        .attr("data-install-variant", "ios")
                        .bool_attr("hidden", {
                            let oui = est(Variante::Ios);
                            move || !oui()
                        })
                        .child(strong().text(copy.pwa.ios_title))
                        .child(p().text(copy.pwa.ios_body)),
                )
                .child(
                    div()
                        .class("install-banner-actions")
                        // Seul le chemin de Chromium a un bouton qui puisse faire
                        // quelque chose : sur iOS il n'y a aucune API à appeler,
                        // donc la formulation est toute la fonctionnalité.
                        .child(
                            button()
                                .attr("type", "button")
                                .class("btn btn-primary")
                                .attr("data-install-accept", "")
                                .bool_attr("hidden", {
                                    let oui = est(Variante::Invite);
                                    move || !oui()
                                })
                                .on_click(move |_| rejouer(&retenu.borrow(), cacher))
                                .text(copy.pwa.action),
                        )
                        .child(
                            button()
                                .attr("type", "button")
                                .class("btn btn-quiet")
                                .attr("data-install-dismiss", "")
                                .on_click(move |_| cacher())
                                .text(copy.pwa.dismiss),
                        ),
                ),
        )
        .into()
}

/// Décide s'il y a quelque chose à proposer, et quoi.
///
/// Rien pour une application déjà installée, rien pour qui a dit « plus
/// tard ». Sur iOS, la formulation tout de suite ; ailleurs, seulement si le
/// navigateur propose l'installation, et l'événement est **retenu** : le
/// navigateur n'accepte de montrer l'invite qu'en réponse à un geste, donc il
/// faut la garder jusqu'au toucher.
#[cfg(feature = "hydrate")]
fn guetter(montrer: impl Fn(Variante) + 'static, retenu: Rc<RefCell<Retenu>>) {
    use wasm_bindgen::closure::Closure;
    use wasm_bindgen::JsCast;

    let Some(fenetre) = web_sys::window() else {
        return;
    };
    if autonome(&fenetre) || crate::stockage::lire(RENVOI).as_deref() == Some("1") {
        return;
    }
    if ios(&fenetre) {
        montrer(Variante::Ios);
        return;
    }
    let au_signal = Closure::<dyn FnMut(web_sys::Event)>::new(move |evenement: web_sys::Event| {
        evenement.prevent_default();
        *retenu.borrow_mut() = Some(evenement.into());
        montrer(Variante::Invite);
    });
    let _ = fenetre.add_event_listener_with_callback(
        "beforeinstallprompt",
        au_signal.as_ref().unchecked_ref(),
    );
    // L'écouteur vit autant que la page : il n'y a pas de moment où le retirer.
    au_signal.forget();
}

#[cfg(not(feature = "hydrate"))]
fn guetter(_: impl Fn(Variante) + 'static, _: Rc<RefCell<Retenu>>) {}

/// Déjà lancé depuis l'écran d'accueil : rien à proposer.
#[cfg(feature = "hydrate")]
fn autonome(fenetre: &web_sys::Window) -> bool {
    if let Ok(Some(requete)) = fenetre.match_media("(display-mode: standalone)") {
        if requete.matches() {
            return true;
        }
    }
    // Safari sur iOS précède `display-mode` et répond par ceci à la place.
    js_sys::Reflect::get(&fenetre.navigator(), &"standalone".into())
        .map(|v| v.as_bool() == Some(true))
        .unwrap_or(false)
}

#[cfg(feature = "hydrate")]
fn ios(fenetre: &web_sys::Window) -> bool {
    let navigateur = fenetre.navigator();
    let agent = navigateur.user_agent().unwrap_or_default();
    if ["iPad", "iPhone", "iPod"].iter().any(|m| agent.contains(m)) {
        return true;
    }
    // iPadOS se déclare Mac ; ses points de contact le trahissent.
    agent.contains("Macintosh") && navigateur.max_touch_points() > 1
}

/// Rejoue l'invite retenue, puis cache la bannière quand le lecteur a répondu.
///
/// `beforeinstallprompt` n'est pas normalisé, donc `web-sys` ne le nomme pas :
/// `prompt` et `userChoice` sont lus par réflexion. Une invite absente — un
/// événement qu'on n'aurait pas retenu — ne fait rien plutôt que de lever.
#[cfg(feature = "hydrate")]
fn rejouer(retenu: &Retenu, cacher: impl Fn() + 'static) {
    use wasm_bindgen::closure::Closure;
    use wasm_bindgen::JsCast;

    let Some(evenement) = retenu else {
        return;
    };
    let Ok(prompt) = js_sys::Reflect::get(evenement, &"prompt".into()) else {
        return;
    };
    let Ok(prompt) = prompt.dyn_into::<js_sys::Function>() else {
        return;
    };
    let _ = prompt.call0(evenement);
    let choix = js_sys::Reflect::get(evenement, &"userChoice".into())
        .ok()
        .and_then(|v| v.dyn_into::<js_sys::Promise>().ok());
    match choix {
        Some(promesse) => {
            let suite = Closure::once(move |_: wasm_bindgen::JsValue| cacher());
            let _ = promesse.then(&suite);
            suite.forget();
        }
        None => cacher(),
    }
}

#[cfg(not(feature = "hydrate"))]
fn rejouer(_: &Retenu, _: impl Fn() + 'static) {}
