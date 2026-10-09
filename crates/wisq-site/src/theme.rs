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
                    Callback::from(move |_: MouseEvent| {
                        choisi.set(id);
                        appliquer(id);
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

/// Poser l'attribut, qui est la seule chose qu'un lecteur voie tout de suite.
///
/// Sous `ssr` il n'y a pas de document, et le bouchon du bas ne fait rien —
/// ce qui est juste : le pré-rendu part de `auto`, et c'est le script bloquant
/// de la tête qui applique les couleurs avant la première peinture.
#[cfg(feature = "hydrate")]
fn appliquer(theme: Theme) {
    let Some(racine) = web_sys::window()
        .and_then(|w| w.document())
        .and_then(|d| d.document_element())
    else {
        return;
    };
    match theme {
        Theme::Auto => {
            let _ = racine.remove_attribute("data-theme");
        }
        other => {
            let _ = racine.set_attribute("data-theme", other.slug());
        }
    }
}

#[cfg(not(feature = "hydrate"))]
fn appliquer(_: Theme) {}
