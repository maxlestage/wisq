//! L'accueil : la seule page du site qui ne soit pas un document.
//!
//! Le héros, la bande, les deux modes, les trois protocoles, les deux machines
//! locales, la comparaison, le toucher, l'appairage, la sécurité, les chiffres,
//! l'état du projet et le plan des pages. Toute la copie vient de
//! `crate::content` ; ce fichier n'est que de la mise en page.
//!
//! **Le mouvement vit ailleurs, et ce n'est pas un hasard.** Ce composant n'est
//! jamais hydraté : il est rendu à la construction, et le navigateur garde son
//! balisage tel quel. Ce qu'il porte pour l'ouverture façon zamocorp — la toile
//! de la poussière, les mots du titre, l'invitation à défiler, la piste de la
//! bande — est du balisage inerte, que la feuille de style laisse immobile et
//! que `crate::mouvement` anime quand il le peut. Sans script, ou avec « réduire
//! les animations », la page est celle-ci, entière et immobile.

use yew::prelude::*;

use crate::content::{ExplorerCopy, Lang, TraitCopy};
use crate::doc::mots;
use crate::logo::Logo;
use crate::routes::RouteId;
use crate::shell::{bande, href};

#[derive(Properties, PartialEq)]
pub struct AccueilProps {
    pub lang: Lang,
}

#[function_component]
pub fn Accueil(props: &AccueilProps) -> Html {
    let lang = props.lang;
    let copy = lang.accueil();
    let vers = move |cible: RouteId| href(RouteId::Home, lang, cible, lang);
    html! {
        <>
            // **L'ouverture.** Au repos, un héros plein écran. Avec du mouvement,
            // la section s'allonge, la scène s'épingle, et le défilement forme
            // la marque dans la poussière avant de la rendre — voir
            // `crate::mouvement::ouverture`. Les deux états ont la même scène à
            // la même place au premier pixel : rien ne saute quand le module
            // arrive.
            <section class="hero" data-ouverture="">
                <div class="hero-scene">
                    <canvas class="hero-dust" aria-hidden="true"></canvas>
                    <div class="wrap hero-grid">
                        <div class="hero-text">
                            <p class="badge">{ copy.hero.badge }</p>
                            <h1 class="hero-title">{ mots(copy.hero.tagline) }</h1>
                            <p class="lede">{ copy.hero.lede }</p>
                            <div class="cta-row">
                                <a class="btn btn-primary" data-aimant="" href={vers(RouteId::Docs)}>
                                    { copy.cta.primary }
                                </a>
                                <a class="btn btn-secondary" data-aimant="" href={vers(RouteId::Releases)}>
                                    { copy.cta.secondary }
                                </a>
                            </div>
                        </div>
                        // La marque et le nom d'un seul bloc. La marque seule est
                        // un dessin de `▚`, qui dit ce que fait le produit mais pas
                        // comment il s'appelle ; les deux ensemble sont ce qu'un
                        // lecteur reconnaît plus tard. Le nom est du vrai texte et
                        // non une partie du dessin : il se sélectionne, se cherche,
                        // se lit.
                        <div class="hero-lockup">
                            <Logo class="hero-logo" instance="hero" />
                            <p class="hero-wordmark">{ "wisq" }</p>
                        </div>
                    </div>
                    // L'invitation à défiler : une goutte qui tombe le long d'un
                    // fil, et qui s'efface dès qu'on a commencé. Décorative —
                    // une flèche qui ne dit rien de plus que la barre de
                    // défilement.
                    <div class="hero-hint" aria-hidden="true"><span></span></div>
                </div>
            </section>

            // **La bande.** Les mots-clés des sections du dessous, qui défilent —
            // et que le défilement de la page pousse, dans son sens.
            { bande(copy.bande.words) }

            <section id="modes">
                <div class="wrap">
                    { titre(1, copy.modes.title) }
                    <div class="cards">
                        { for [&copy.modes.remote, &copy.modes.local].into_iter().map(|mode| html! {
                            <article class="card">
                                <span class="tag">{ mode.name }</span>
                                <h3>{ mode.head }</h3>
                                <p>{ mode.body }</p>
                                <ul>
                                    { for mode.points.iter().map(|point| html! { <li>{ *point }</li> }) }
                                </ul>
                            </article>
                        }) }
                    </div>
                </div>
            </section>

            // **Les trois protocoles**, chacun avec sa réserve. La réserve a sa
            // propre ligne, sous les points, pour qu'elle ne se lise pas comme
            // un point de plus.
            <section id="protocoles">
                <div class="wrap">
                    { titre(2, copy.protocoles.title) }
                    <p class="lede">{ copy.protocoles.lede }</p>
                    <div class="cards cards-3">
                        { for copy.protocoles.items.iter().map(|p| html! {
                            <article class="card">
                                <span class="tag">{ p.name }</span>
                                <p>{ p.reach }</p>
                                <ul>
                                    { for p.points.iter().map(|point| html! { <li>{ *point }</li> }) }
                                </ul>
                                <p class="card-reserve">{ p.caveat }</p>
                            </article>
                        }) }
                    </div>
                </div>
            </section>

            <section id="machines">
                <div class="wrap">
                    { titre(3, copy.machines.title) }
                    <p class="lede">{ copy.machines.lede }</p>
                    { tableau(&copy.machines.columns, copy.machines.rows, true) }
                    <p class="table-note">{ copy.machines.note }</p>
                </div>
            </section>

            <section id="compare">
                <div class="wrap">
                    { titre(4, copy.compare.title) }
                    <p class="lede">{ copy.compare.lede }</p>
                    { tableau(&copy.compare.columns, copy.compare.rows, false) }
                </div>
            </section>

            <section id="toucher">
                <div class="wrap">
                    { titre(5, copy.toucher.title) }
                    <p class="lede">{ copy.toucher.lede }</p>
                    { traits(copy.toucher.items) }
                </div>
            </section>

            <section id="how">
                <div class="wrap">
                    { titre(6, copy.how.title) }
                    <div class="steps">
                        { for copy.how.steps.iter().map(|step| html! {
                            <div class="step">
                                <div class="step-num" aria-hidden="true"></div>
                                <div>
                                    <h3>{ step.title }</h3>
                                    <p>{ step.body }</p>
                                </div>
                            </div>
                        }) }
                    </div>
                </div>
            </section>

            <section id="securite">
                <div class="wrap">
                    { titre(7, copy.securite.title) }
                    <p class="lede">{ copy.securite.lede }</p>
                    { traits(copy.securite.items) }
                </div>
            </section>

            <section id="facts">
                <div class="wrap">
                    { titre(8, copy.facts.title) }
                    <div class="facts">
                        { for copy.facts.items.iter().map(|fact| html! {
                            <div class="fact">
                                <div class="value">{ fact.value }</div>
                                <div class="label">{ fact.label }</div>
                            </div>
                        }) }
                    </div>
                </div>
            </section>

            // **L'état**, en deux listes. La seconde est dessinée comme la
            // première, sans atténuation : ce qui manque n'est pas une note de
            // bas de page.
            <section id="etat">
                <div class="wrap">
                    { titre(9, copy.etat.title) }
                    <p class="lede">{ copy.etat.lede }</p>
                    <div class="etat">
                        <div>
                            <h3>{ copy.etat.done_label }</h3>
                            <ul class="etat-liste etat-fait">
                                { for copy.etat.done.iter().map(|ligne| html! { <li>{ *ligne }</li> }) }
                            </ul>
                        </div>
                        <div>
                            <h3>{ copy.etat.next_label }</h3>
                            <ul class="etat-liste">
                                { for copy.etat.next.iter().map(|ligne| html! { <li>{ *ligne }</li> }) }
                            </ul>
                        </div>
                    </div>
                </div>
            </section>

            // **Le plan des pages.** Chaque carte est un lien entier : le nom
            // de la page en titre, ce qu'on y trouve dessous.
            <section id="explorer">
                <div class="wrap">
                    { titre(10, copy.explorer.title) }
                    <div class="cards cards-3">
                        { for pistes(&copy.explorer).into_iter().map(|(route, ligne)| html! {
                            <a class="card card-lien" href={vers(route)}>
                                <h3>{ route.label(lang.copy()) }</h3>
                                <p>{ ligne }</p>
                            </a>
                        }) }
                    </div>
                </div>
            </section>
        </>
    }
}

/// Le titre d'une section : ses mots, qui montent un à un quand la section
/// arrive, et son rang en très grand derrière lui, que le défilement fait
/// glisser. Le rang est décoratif — la page se lit dans l'ordre sans lui — et
/// il le dit.
fn titre(rang: u8, texte: &'static str) -> Html {
    html! {
        <>
            <span class="sec-num" aria-hidden="true">{ format!("{rang:02}") }</span>
            <h2>{ mots(texte) }</h2>
        </>
    }
}

/// Un tableau dont la première ligne nomme les colonnes. `en_tete_de_ligne`
/// fait de la première cellule de chaque ligne un en-tête : dans le tableau des
/// machines, « Mémoire » est ce dont la ligne parle, pas une donnée.
fn tableau(
    colonnes: &[&'static str; 3],
    lignes: &'static [[&'static str; 3]],
    en_tete_de_ligne: bool,
) -> Html {
    html! {
        <div class="table-scroll">
            <table>
                <thead>
                    <tr>
                        { for colonnes.iter().map(|c| html! { <th scope="col">{ *c }</th> }) }
                    </tr>
                </thead>
                <tbody>
                    { for lignes.iter().map(|ligne| html! {
                        <tr>
                            { for ligne.iter().enumerate().map(|(i, cell)| if i == 0 && en_tete_de_ligne {
                                html! { <th scope="row">{ *cell }</th> }
                            } else {
                                html! { <td>{ *cell }</td> }
                            }) }
                        </tr>
                    }) }
                </tbody>
            </table>
        </div>
    }
}

/// Une liste de termes et de ce qu'ils veulent dire, en grille.
fn traits(items: &'static [TraitCopy]) -> Html {
    html! {
        <dl class="traits">
            { for items.iter().map(|t| html! {
                <div>
                    <dt>{ t.term }</dt>
                    <dd>{ t.detail }</dd>
                </div>
            }) }
        </dl>
    }
}

/// Les pages écrites, dans l'ordre de la navigation, avec leur ligne.
fn pistes(e: &'static ExplorerCopy) -> [(RouteId, &'static str); 7] {
    [
        (RouteId::Docs, e.docs),
        (RouteId::Protocol, e.protocol),
        (RouteId::Architecture, e.architecture),
        (RouteId::Faq, e.faq),
        (RouteId::Roadmap, e.roadmap),
        (RouteId::Releases, e.releases),
        (RouteId::Privacy, e.privacy),
    ]
}
