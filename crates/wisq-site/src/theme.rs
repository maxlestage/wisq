//! Clair, sombre, ou ce que dit le système.
//!
//! Trois états plutôt que deux, parce qu'un interrupteur ne sait pas exprimer
//! « suis mon téléphone » : un lecteur dont l'appareil passe en sombre au
//! coucher du soleil veut que le site en fasse autant, et une bascule à deux
//! positions l'en sort en silence la première fois qu'il y touche.
//!
//! **Ce que le passage à Yew change ici, et c'est l'argument de la bascule.**
//! La version React portait en commentaire : « this component never runs in a
//! browser ». Elle rendait des boutons porteurs de `data-theme-choice`, et
//! `src/main.ts` leur rattachait le comportement de loin, en code DOM. Les deux
//! moitiés d'un même objet vivaient dans deux fichiers et deux langages, et la
//! seule chose qui les tenait ensemble était le nom d'un attribut.
//!
//! Ici le composant se comporte. Le clic, l'état, la lecture du choix mémorisé
//! et l'écriture de `data-theme` sont dans ce fichier, avec le balisage qu'ils
//! pilotent.
//!
//! **L'ordre compte, et il est contraint par l'hydratation.** Le rendu du
//! serveur et le premier rendu du client doivent coïncider, sinon Yew signale
//! un décalage ; or le choix mémorisé n'est lisible que dans le navigateur.
//! D'où `auto` au premier rendu des deux côtés, puis la correction dans un
//! `use_effect`, qui ne tourne pas au pré-rendu. Le script bloquant de la tête
//! continue d'appliquer le thème **avant la première peinture** : sans lui, un
//! lecteur qui a choisi « clair » sur un système sombre verrait un éclair de
//! sombre à chaque navigation, et aucun wasm n'arrive assez tôt pour l'éviter.

use yew::prelude::*;

/// Les deux `--bg` de `styles.css`, et ce que le navigateur peint autour de la
/// page : la barre d'état sur iOS, le bandeau d'onglet ailleurs.
///
/// **Une seule source.** Ces deux couleurs étaient écrites à la main en cinq
/// endroits et rien ne les comparait ; `src/theme.ts` les a d'abord réunies,
/// et elles vivent ici depuis que le front est en Rust. La construction les lit
/// dans le catalogue du pré-rendu pour les métas, le script de la tête et le
/// manifeste, et `tests/build.test.ts` les confronte à la feuille de style
/// construite plutôt qu'à une copie.
pub const BAR_CLAIR: &str = "#fff";
pub const BAR_SOMBRE: &str = "#0b0a14";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Theme {
    Light,
    Dark,
    Auto,
}

impl Theme {
    pub fn slug(self) -> &'static str {
        match self {
            Theme::Light => "light",
            Theme::Dark => "dark",
            Theme::Auto => "auto",
        }
    }

    /// Tout ce qui n'est pas un choix explicite est `auto`, y compris un
    /// navigateur qui refuse le stockage.
    pub fn parse(value: &str) -> Theme {
        match value {
            "light" => Theme::Light,
            "dark" => Theme::Dark,
            _ => Theme::Auto,
        }
    }
}

/// La langue plutôt qu'une référence vers tout le bloc de copie.
///
/// Yew compare les propriétés à chaque rendu pour décider s'il doit retravailler
/// un composant. Passer `&'static Copy` exigerait `PartialEq` sur `Copy`, donc
/// une comparaison champ par champ de toute la copie du site — une quarantaine
/// de chaînes — à chaque fois. `Lang` est une énumération de deux variantes : la
/// comparaison est un entier, et la copie se retrouve par `lang.copy()`.
#[derive(Properties, PartialEq)]
pub struct ThemeSwitchProps {
    pub lang: crate::content::Lang,
}

#[function_component]
pub fn ThemeSwitch(props: &ThemeSwitchProps) -> Html {
    // `auto` est ce avec quoi le balisage part, parce que c'est la seule réponse
    // juste pour un lecteur dont le choix n'a pas encore été lu — et pour celui
    // qui n'a pas de JavaScript du tout, où la page suit simplement le système
    // et où cette bascule ne fait rien.
    let choisi = use_state(|| Theme::Auto);

    {
        let choisi = choisi.clone();
        use_effect_with((), move |()| {
            if let Some(stored) = lire_choix() {
                choisi.set(stored);
            }
        });
    }

    let copy = props.lang.copy();
    let options = [
        (Theme::Light, copy.theme.light, icone_soleil()),
        (Theme::Dark, copy.theme.dark, icone_lune()),
        (Theme::Auto, copy.theme.auto, icone_auto()),
    ];

    html! {
        <div class="theme-switch" role="group" aria-label={copy.theme.label}>
            { for options.into_iter().map(|(id, label, icone)| {
                let presse = id == *choisi;
                let au_clic = {
                    let choisi = choisi.clone();
                    Callback::from(move |e: MouseEvent| {
                        choisi.set(id);
                        basculer(id, &e);
                        retenir(id);
                    })
                };
                html! {
                    <button type="button" data-theme-choice={id.slug()}
                            aria-pressed={presse.to_string()} aria-label={label} title={label}
                            onclick={au_clic}>
                        { icone }
                    </button>
                }
            }) }
        </div>
    }
}

/// Les icônes sont dessinées plutôt que tapées : un soleil en emoji est une
/// image différente dans chaque fonte, et une fonte qui ne l'a pas dessine un
/// carré.
fn icone_soleil() -> Html {
    html! {
        <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" focusable="false">
            <circle cx="12" cy="12" r="4.4" fill="currentColor" />
            { for [0, 45, 90, 135, 180, 225, 270, 315].into_iter().map(|angle| html! {
                <rect x="11.1" y="1.4" width="1.8" height="3.6" rx="0.9" fill="currentColor"
                      transform={format!("rotate({angle} 12 12)")} />
            }) }
        </svg>
    }
}

fn icone_lune() -> Html {
    html! {
        <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" focusable="false">
            <path d="M20 14.4A8.6 8.6 0 0 1 9.6 4 8.6 8.6 0 1 0 20 14.4Z" fill="currentColor" />
        </svg>
    }
}

/// Un cercle éclairé d'un côté : la page qui prend son parti ailleurs.
fn icone_auto() -> Html {
    html! {
        <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" focusable="false">
            <circle cx="12" cy="12" r="8" fill="none" stroke="currentColor" stroke-width="2" />
            <path d="M12 4a8 8 0 0 1 0 16Z" fill="currentColor" />
        </svg>
    }
}

// Le choix mémorisé passe par `crate::stockage`, qui porte la chaîne de refus
// une seule fois pour les trois comportements qui mémorisent. Ne reste ici que
// ce qui est propre au thème : qu'un `auto` stocké n'est pas un choix, et que
// l'attribut se pose sur la racine du document.

fn lire_choix() -> Option<Theme> {
    // Un `auto` stocké n'est pas un choix : c'est l'absence de choix, et les
    // confondre empêcherait de distinguer « suis le système » de « on n'a rien
    // lu encore ». `retenir` l'efface donc, et cette lecture le refuse.
    match crate::stockage::lire(crate::stockage::THEME)?.as_str() {
        "light" => Some(Theme::Light),
        "dark" => Some(Theme::Dark),
        _ => None,
    }
}

fn retenir(theme: Theme) {
    match theme {
        Theme::Auto => crate::stockage::effacer(crate::stockage::THEME),
        other => crate::stockage::ecrire(crate::stockage::THEME, other.slug()),
    }
}

/// Poser l'attribut, qui est la seule chose qu'un lecteur voie tout de suite —
/// et les deux métas `theme-color`, qui sont la seconde.
///
/// **Les métas manquaient au portage, et rien ne le disait.** La version DOM
/// les réécrivait à chaque choix ; la première version Yew ne posait que
/// `data-theme`. Les deux métas portent une requête `media`, donc sur `auto`
/// elles suivent déjà le système — mais un choix explicite doit les forcer
/// toutes les deux, sinon le navigateur peint sa barre pour un thème que la
/// page n'emploie pas. Sur la page `offline`, seule page portée à l'époque, un
/// lecteur qui choisissait « clair » sur un téléphone sombre gardait une barre
/// d'état noire au-dessus d'une page crème.
///
/// Sous `ssr` il n'y a pas de document, et le bouchon du bas ne fait rien —
/// ce qui est juste : le pré-rendu part de `auto`, et c'est le script bloquant
/// de la tête qui applique les couleurs avant la première peinture.
#[cfg(feature = "hydrate")]
fn appliquer(theme: Theme) {
    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    if let Some(racine) = document.document_element() {
        let _ = match theme {
            Theme::Auto => racine.remove_attribute("data-theme"),
            other => racine.set_attribute("data-theme", other.slug()),
        };
    }
    let Ok(metas) = document.query_selector_all(r#"meta[name="theme-color"]"#) else {
        return;
    };
    for i in 0..metas.length() {
        let Some(meta) = metas
            .item(i)
            .and_then(|n| wasm_bindgen::JsCast::dyn_into::<web_sys::Element>(n).ok())
        else {
            continue;
        };
        let propre = if meta
            .get_attribute("media")
            .unwrap_or_default()
            .contains("dark")
        {
            BAR_SOMBRE
        } else {
            BAR_CLAIR
        };
        let couleur = match theme {
            Theme::Auto => propre,
            Theme::Light => BAR_CLAIR,
            Theme::Dark => BAR_SOMBRE,
        };
        let _ = meta.set_attribute("content", couleur);
    }
}

#[cfg(not(feature = "hydrate"))]
fn appliquer(_: Theme) {}

/// **Le thème s'ouvre en cercle**, depuis le bouton qu'on vient de presser.
///
/// La transition de vue du navigateur photographie la page, applique le
/// thème, et la feuille de style découvre la nouvelle par un cercle qui part du
/// centre du bouton (`--bx`, `--by`). Deux conditions, et aucune n'est un
/// réglage de plus : `[data-motion]` sur la racine — le module ne le pose pas
/// quand on a demandé le calme — et `document.startViewTransition`, que Chrome
/// et Safari connaissent et les autres pas. Sans l'une ou l'autre, le thème
/// s'applique comme avant, d'un coup.
///
/// **Jamais au prix du thème.** Si l'appel échoue, le rappel n'a peut-être pas
/// tourné : le thème est appliqué directement, et la classe retirée.
#[cfg(feature = "hydrate")]
fn basculer(theme: Theme, e: &MouseEvent) {
    use wasm_bindgen::closure::Closure;
    use wasm_bindgen::JsCast;

    let document = web_sys::window().and_then(|w| w.document());
    let racine = document
        .as_ref()
        .and_then(|d| d.document_element())
        .and_then(|r| r.dyn_into::<web_sys::HtmlElement>().ok());
    let demarrer = document.as_ref().and_then(|d| {
        js_sys::Reflect::get(d, &"startViewTransition".into())
            .ok()?
            .dyn_into::<js_sys::Function>()
            .ok()
    });
    let (Some(document), Some(racine), Some(demarrer)) = (document, racine, demarrer) else {
        appliquer(theme);
        return;
    };
    if !racine.has_attribute("data-motion") {
        appliquer(theme);
        return;
    }

    // Le centre du bouton, pas la position du clic : au clavier, il n'y a pas
    // de pointeur, et le cercle partirait du coin de l'écran.
    if let Some(bouton) = e
        .current_target()
        .and_then(|t| t.dyn_into::<web_sys::Element>().ok())
    {
        let boite = bouton.get_bounding_client_rect();
        let x = (boite.left() + boite.width() / 2.0).round() as i32;
        let y = (boite.top() + boite.height() / 2.0).round() as i32;
        let style = racine.style();
        let _ = style.set_property("--bx", &(crate::mouvement::calcul::entier(x) + "px"));
        let _ = style.set_property("--by", &(crate::mouvement::calcul::entier(y) + "px"));
    }
    let _ = racine.class_list().add_1("bascule");

    let rappel = Closure::once_into_js(move || appliquer(theme));
    let Ok(transition) = demarrer.call1(&document, &rappel) else {
        appliquer(theme);
        let _ = racine.class_list().remove_1("bascule");
        return;
    };
    let fin = js_sys::Reflect::get(&transition, &"finished".into())
        .ok()
        .and_then(|p| p.dyn_into::<js_sys::Promise>().ok());
    let Some(fin) = fin else {
        let _ = racine.class_list().remove_1("bascule");
        return;
    };
    let retirer = Closure::<dyn FnMut()>::new(move || {
        let _ = racine.class_list().remove_1("bascule");
    });
    let _ = fin.finally(&retirer);
    retirer.forget();
}

#[cfg(not(feature = "hydrate"))]
fn basculer(theme: Theme, _: &MouseEvent) {
    appliquer(theme);
}
