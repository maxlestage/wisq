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
//! c'est ce que l'hydratation exige, le premier rendu du client devant
//! coïncider avec le pré-rendu — et un effet décide ensuite.
//!
//! **Ce que le portage rachète.** La version DOM révélait la bannière en
//! retirant des attributs `hidden` posés sur un balisage qu'elle n'avait pas
//! écrit, retrouvé par des sélecteurs. Ici l'état décide du balisage, et le
//! balisage est à côté de l'état.

use yew::prelude::*;

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

#[derive(Properties, PartialEq, Clone)]
pub struct InstallProps {
    pub lang: Lang,
}

#[function_component]
pub fn InstallPrompt(props: &InstallProps) -> Html {
    let variante = use_state(|| None::<Variante>);
    let renvoyee = use_state(|| false);
    let retenu = use_mut_ref(|| Retenu::None);

    {
        let montrer = variante.setter();
        let retenu = retenu.clone();
        use_effect_with((), move |()| {
            guetter(move |v| montrer.set(Some(v)), retenu);
        });
    }

    let cacher = {
        let renvoyee = renvoyee.setter();
        Callback::from(move |()| {
            renvoyee.set(true);
            crate::stockage::ecrire(RENVOI, "1");
        })
    };
    let au_renvoi = {
        let cacher = cacher.clone();
        Callback::from(move |_: MouseEvent| cacher.emit(()))
    };
    let a_l_acceptation = {
        let retenu = retenu.clone();
        Callback::from(move |_: MouseEvent| rejouer(&retenu.borrow(), cacher.clone()))
    };

    let copy = props.lang.copy();
    let montree = variante.is_some() && !*renvoyee;
    let invite = *variante == Some(Variante::Invite);
    let ios = *variante == Some(Variante::Ios);
    html! {
        <aside class="install-banner" role="complementary" hidden={!montree} data-install="">
            <div class="wrap install-banner-inner">
                <div data-install-variant="prompt" hidden={!invite}>
                    <strong>{ copy.pwa.title }</strong>
                    <p>{ copy.pwa.body }</p>
                </div>
                <div data-install-variant="ios" hidden={!ios}>
                    <strong>{ copy.pwa.ios_title }</strong>
                    <p>{ copy.pwa.ios_body }</p>
                </div>
                <div class="install-banner-actions">
                    // Seul le chemin de Chromium a un bouton qui puisse faire
                    // quelque chose : sur iOS il n'y a aucune API à appeler, donc
                    // la formulation est toute la fonctionnalité.
                    <button type="button" class="btn btn-primary" data-install-accept=""
                            hidden={!invite} onclick={a_l_acceptation}>
                        { copy.pwa.action }
                    </button>
                    <button type="button" class="btn btn-quiet" data-install-dismiss=""
                            onclick={au_renvoi}>
                        { copy.pwa.dismiss }
                    </button>
                </div>
            </div>
        </aside>
    }
}

/// Décide s'il y a quelque chose à proposer, et quoi.
///
/// Rien pour une application déjà installée, rien pour qui a dit « plus
/// tard ». Sur iOS, la formulation tout de suite ; ailleurs, seulement si le
/// navigateur propose l'installation, et l'événement est **retenu** : le
/// navigateur n'accepte de montrer l'invite qu'en réponse à un geste, donc il
/// faut la garder jusqu'au toucher.
#[cfg(feature = "hydrate")]
fn guetter(montrer: impl Fn(Variante) + 'static, retenu: std::rc::Rc<std::cell::RefCell<Retenu>>) {
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
fn guetter(_: impl Fn(Variante) + 'static, _: std::rc::Rc<std::cell::RefCell<Retenu>>) {}

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
fn rejouer(retenu: &Retenu, cacher: Callback<()>) {
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
            let suite = Closure::once(move |_: wasm_bindgen::JsValue| cacher.emit(()));
            let _ = promesse.then(&suite);
            suite.forget();
        }
        None => cacher.emit(()),
    }
}

#[cfg(not(feature = "hydrate"))]
fn rejouer(_: &Retenu, _: Callback<()>) {}
