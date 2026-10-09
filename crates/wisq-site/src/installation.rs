//! L'invite qui fait de ce site quelque chose sur l'écran d'accueil.
//!
//! **Deux plateformes, deux mécanismes, et celui qui compte ici n'a pas d'API.**
//! Chromium envoie `beforeinstallprompt` et confie une invite à rejouer plus
//! tard ; Safari sur iOS n'envoie rien du tout et installe par la feuille de
//! partage. La seule chose honnête à offrir là-bas, ce sont les trois gestes qui
//! marchent — donc la formulation *est* toute la fonctionnalité.
//!
//! **Les deux formulations sont rendues, et les deux partent masquées.** Savoir
//! laquelle s'applique est un fait sur le navigateur, donc impossible à la
//! construction. L'alternative était pire : construire cette bannière dans le
//! navigateur voudrait dire y expédier ses quatre chaînes, dans la langue de la
//! page.
//!
//! **C'est aussi ce que l'hydratation exige.** Le rendu du serveur et le premier
//! rendu du client doivent coïncider ; or rien de ce qui décide ici n'est
//! lisible au pré-rendu — ni le mode d'affichage, ni l'agent, ni le stockage,
//! ni un événement qui n'est pas encore arrivé. D'où `Masquee` au premier rendu
//! des deux côtés, et la décision dans un `use_effect`, qui ne tourne pas au
//! pré-rendu. Le balisage pré-rendu est donc, octet pour octet, celui d'avant ce
//! portage, et `site/tests/render.test.tsx` le tient.
//!
//! **Rien ici n'est porteur.** Un navigateur qui n'envoie jamais l'événement, un
//! stockage refusé, un agent qu'on ne sait pas lire : chacun donne une bannière
//! qui reste masquée, c'est-à-dire le site tel qu'il est. Ce qui se perd est une
//! proposition, jamais une page.

use yew::prelude::*;

use crate::content::Lang;

/// La clé du renvoi. La même orthographe que celle du script, parce que les deux
/// moitiés du site ont lu et écrit ce fait pendant toute la migration.
pub const RENVOI: &str = "wisq.install.dismissed";

/// Ce que la bannière montre — et `Masquee` est la seule valeur que le pré-rendu
/// puisse produire.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Invite {
    Masquee,
    /// La feuille de partage : des mots, et aucun bouton qui puisse agir.
    Ios,
    /// L'invite de Chromium, qu'on a retenue et qu'un geste rejouera.
    Navigateur,
}

#[derive(Properties, PartialEq)]
pub struct InstallProps {
    pub lang: Lang,
}

#[function_component]
pub fn InstallPrompt(props: &InstallProps) -> Html {
    let copy = props.lang.copy();
    let invite = use_state(|| Invite::Masquee);

    // L'événement de Chromium, retenu : le navigateur n'autorise l'invite qu'en
    // réponse à un geste, donc il faut le garder jusqu'au clic. Il vit dans une
    // référence et non dans un état parce que le reprendre ne doit pas
    // provoquer de rendu — c'est le `Invite` à côté qui le fait.
    let retenu = use_mut_ref(|| None::<retenue::Retenue>);

    {
        let invite = invite.clone();
        let retenu = retenu.clone();
        use_effect_with((), move |()| decider(invite, retenu));
    }

    let renvoyer = {
        let invite = invite.clone();
        Callback::from(move |_: MouseEvent| {
            invite.set(Invite::Masquee);
            // Et une fois renvoyée, elle ne revient pas : proposer deux fois ce
            // qu'on a refusé une fois est la définition d'un harcèlement.
            crate::stockage::ecrire(RENVOI, "1");
        })
    };

    let accepter = {
        let invite = invite.clone();
        let retenu = retenu.clone();
        Callback::from(move |_: MouseEvent| {
            retenue::jouer(&retenu, invite.clone());
        })
    };

    let masquee = *invite == Invite::Masquee;
    html! {
        <aside class="install-banner" role="complementary" hidden={masquee} data-install="">
            <div class="wrap install-banner-inner">
                <div data-install-variant="prompt" hidden={*invite != Invite::Navigateur}>
                    <strong>{ copy.pwa.title }</strong>
                    <p>{ copy.pwa.body }</p>
                </div>
                <div data-install-variant="ios" hidden={*invite != Invite::Ios}>
                    <strong>{ copy.pwa.ios_title }</strong>
                    <p>{ copy.pwa.ios_body }</p>
                </div>
                <div class="install-banner-actions">
                    // Seul le chemin de Chromium a un bouton qui puisse faire
                    // quelque chose : sur iOS il n'y a aucune API à appeler, donc
                    // le bouton reste masqué là-bas.
                    <button type="button" class="btn btn-primary" data-install-accept=""
                            hidden={*invite != Invite::Navigateur} onclick={accepter}>
                        { copy.pwa.action }
                    </button>
                    <button type="button" class="btn btn-quiet" data-install-dismiss=""
                            onclick={renvoyer}>
                        { copy.pwa.dismiss }
                    </button>
                </div>
            </div>
        </aside>
    }
}

/// Ce que l'effet décide, et dans cet ordre — chaque refus avant les suivants.
#[cfg(feature = "hydrate")]
fn decider(
    invite: UseStateHandle<Invite>,
    retenu: std::rc::Rc<std::cell::RefCell<Option<retenue::Retenue>>>,
) -> Box<dyn FnOnce()> {
    use wasm_bindgen::JsCast;

    // Déjà installée : proposer d'installer ce qui est installé serait dire au
    // lecteur qu'on ne sait pas où il est.
    if deja_installee() {
        return retenue::rien();
    }
    // Déjà renvoyée.
    if crate::stockage::lire(RENVOI).as_deref() == Some("1") {
        return retenue::rien();
    }
    // iOS : aucun événement n'arrivera jamais, et les mots sont la
    // fonctionnalité.
    if sur_ios() {
        invite.set(Invite::Ios);
        return retenue::rien();
    }

    // Et ailleurs, on attend l'événement — qui peut ne jamais venir, auquel cas
    // la bannière reste masquée et le site est entier.
    let Some(fenetre) = web_sys::window() else {
        return retenue::rien();
    };
    let ecouteur = wasm_bindgen::closure::Closure::<dyn FnMut(web_sys::Event)>::new(
        move |brut: web_sys::Event| {
            // Empêcher le navigateur de proposer lui-même : c'est ce qui nous
            // confie l'invite, et sans ça il n'y a rien à rejouer.
            brut.prevent_default();
            if let Some(garde) = retenue::retenir(brut) {
                *retenu.borrow_mut() = Some(garde);
                invite.set(Invite::Navigateur);
            }
        },
    );
    let _ = fenetre
        .add_event_listener_with_callback("beforeinstallprompt", ecouteur.as_ref().unchecked_ref());
    // Le nettoyage retire l'écouteur **et** garde la fermeture en vie jusque-là :
    // la lâcher plus tôt libérerait la fonction que le navigateur appellera.
    Box::new(move || {
        let _ = fenetre.remove_event_listener_with_callback(
            "beforeinstallprompt",
            ecouteur.as_ref().unchecked_ref(),
        );
        drop(ecouteur);
    })
}

#[cfg(not(feature = "hydrate"))]
fn decider(
    _: UseStateHandle<Invite>,
    _: std::rc::Rc<std::cell::RefCell<Option<retenue::Retenue>>>,
) -> Box<dyn FnOnce()> {
    // Le pré-rendu n'a ni navigateur ni événement : il n'y a rien à décider, et
    // un bouchon qui choisirait une formulation en rendrait une visible dans le
    // HTML livré — ce que le premier rendu du client démentirait.
    retenue::rien()
}

/// **Deux questions, parce qu'une seule laisse passer iOS.** `display-mode`
/// est la question standard ; Safari sur iOS est antérieur à cette requête et
/// répond `navigator.standalone` à la place.
#[cfg(feature = "hydrate")]
fn deja_installee() -> bool {
    let Some(fenetre) = web_sys::window() else {
        return false;
    };
    if let Ok(Some(requete)) = fenetre.match_media("(display-mode: standalone)") {
        if requete.matches() {
            return true;
        }
    }
    js_sys::Reflect::get(
        &fenetre.navigator(),
        &wasm_bindgen::JsValue::from_str("standalone"),
    )
    .map(|v| v.as_bool() == Some(true))
    .unwrap_or(false)
}

/// **Et iPadOS se présente comme un Mac**, ce que les points de contact
/// trahissent. Poser la question sur l'agent plutôt que sur la largeur de
/// l'écran, qu'un portable à écran tactile démentirait.
#[cfg(feature = "hydrate")]
fn sur_ios() -> bool {
    let Some(fenetre) = web_sys::window() else {
        return false;
    };
    let navigateur = fenetre.navigator();
    let Ok(agent) = navigateur.user_agent() else {
        return false;
    };
    if agent.contains("iPad") || agent.contains("iPhone") || agent.contains("iPod") {
        return true;
    }
    agent.contains("Macintosh") && navigateur.max_touch_points() > 1
}

/// L'événement de Chromium, et ce qu'on en fait.
///
/// `BeforeInstallPromptEvent` n'est pas dans `web-sys` : il n'est pas
/// standardisé, et c'est précisément pour ça qu'il est déclaré ici, en toutes
/// lettres, plutôt que deviné par un accès dynamique. Les deux membres dont ce
/// fichier a besoin sont nommés ; le reste n'existe pas pour nous.
#[cfg(feature = "hydrate")]
mod retenue {
    use super::Invite;
    use wasm_bindgen::prelude::*;
    use yew::UseStateHandle;

    #[wasm_bindgen]
    extern "C" {
        #[wasm_bindgen(extends = web_sys::Event)]
        pub type Retenue;

        #[wasm_bindgen(method, js_name = prompt)]
        pub fn invite(this: &Retenue) -> js_sys::Promise;

        #[wasm_bindgen(method, getter, js_name = userChoice)]
        pub fn choix(this: &Retenue) -> js_sys::Promise;
    }

    /// **Reconnaître l'événement par ses membres, pas par sa classe.**
    ///
    /// Le premier jet écrivait `dyn_into::<Retenue>()`, ce qui semblait la
    /// forme sûre. Elle ne pouvait pas marcher : wasm-bindgen engendre pour un
    /// type externe un `instanceof` sur un identifiant **du même nom**, et la
    /// colle livrée portait littéralement `getObject(arg0) instanceof Retenue`
    /// — un nom qu'aucun navigateur ne définit. Le `try/catch` de la colle
    /// rendait donc `false` à chaque fois, partout, Chromium compris : la
    /// bannière n'aurait jamais pu apparaître. C'est
    /// `site/tests/hydration.test.ts` qui l'a dit, en appuyant sur le bouton.
    ///
    /// Nommer la classe réelle, `BeforeInstallPromptEvent`, n'aurait fait que
    /// déplacer la faute : elle n'est pas standardisée et n'existe que dans
    /// Chromium, donc la question serait restée fausse partout ailleurs.
    ///
    /// La question honnête est donc celle-ci : **cet événement porte-t-il les
    /// deux membres dont nous avons besoin ?** Et le refus a un objet — un
    /// événement qu'on ne peut pas rejouer ne doit pas faire apparaître un
    /// bouton « Installer » qui ne ferait rien.
    pub fn retenir(brut: web_sys::Event) -> Option<Retenue> {
        let valeur: JsValue = brut.into();
        let invite = js_sys::Reflect::get(&valeur, &JsValue::from_str("prompt")).ok()?;
        if !invite.is_function() {
            return None;
        }
        let choix = js_sys::Reflect::get(&valeur, &JsValue::from_str("userChoice")).ok()?;
        if choix.is_undefined() || choix.is_null() {
            return None;
        }
        Some(wasm_bindgen::JsCast::unchecked_into(valeur))
    }

    /// Un nettoyage qui n'a rien à défaire. Boîté comme l'autre, parce que
    /// `decider` a plusieurs sorties et qu'elles doivent rendre le même type.
    pub fn rien() -> Box<dyn FnOnce()> {
        Box::new(|| {})
    }

    /// Rejouer l'invite retenue, puis se taire quoi qu'il arrive.
    ///
    /// **Le résultat du choix n'est pas lu, et c'est délibéré.** Accepté ou
    /// refusé, la bannière a fait son travail : la remontrer à qui vient de
    /// répondre serait reposer une question déjà répondue. Ce que le lecteur a
    /// choisi est l'affaire du système, pas la nôtre — et nous n'avons aucun
    /// moyen honnête de savoir si l'installation a abouti.
    pub fn jouer(
        garde: &std::rc::Rc<std::cell::RefCell<Option<Retenue>>>,
        invite: UseStateHandle<Invite>,
    ) {
        // Reprise, pas emprunt : l'invite ne se rejoue pas deux fois, et un
        // emprunt gardé pendant l'attente bloquerait le nettoyage.
        let Some(retenue) = garde.borrow_mut().take() else {
            return;
        };
        wasm_bindgen_futures::spawn_local(async move {
            if wasm_bindgen_futures::JsFuture::from(retenue.invite())
                .await
                .is_ok()
            {
                let _ = wasm_bindgen_futures::JsFuture::from(retenue.choix()).await;
            }
            invite.set(Invite::Masquee);
            crate::stockage::ecrire(super::RENVOI, "1");
        });
    }
}

/// Sous `ssr` il n'y a pas d'événement à retenir, donc pas de type à déclarer —
/// mais le composant parle quand même de cette place. Un type vide qui ne peut
/// rien faire est ici la bonne réponse : il refuse par construction, puisqu'il
/// n'a aucun membre.
#[cfg(not(feature = "hydrate"))]
mod retenue {
    use super::Invite;
    use yew::UseStateHandle;

    pub struct Retenue;

    /// Un nettoyage qui n'a rien à défaire. Boîté comme l'autre, parce que
    /// `decider` a plusieurs sorties et qu'elles doivent rendre le même type.
    pub fn rien() -> Box<dyn FnOnce()> {
        Box::new(|| {})
    }

    pub fn jouer(_: &std::rc::Rc<std::cell::RefCell<Option<Retenue>>>, _: UseStateHandle<Invite>) {}
}
