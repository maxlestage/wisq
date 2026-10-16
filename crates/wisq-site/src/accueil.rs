//! L'accueil : la seule page du site qui ne soit pas un document.
//!
//! Le héros, la bande, les deux modes, les trois protocoles, les deux machines
//! locales, la comparaison, le toucher, l'appairage, la sécurité, les chiffres,
//! l'état du projet et le plan des pages. Toute la copie vient de
//! `crate::content` ; ce fichier n'est que de la mise en page.
//!
//! **Le mouvement vit ailleurs, et ce n'est pas un hasard.** Cette vue n'est
//! jamais hydratée : il est rendu à la construction, et le navigateur garde son
//! balisage tel quel. Ce qu'il porte pour l'ouverture façon zamocorp — la toile
//! de la poussière, les mots du titre, l'invitation à défiler, la piste de la
//! bande — est du balisage inerte, que la feuille de style laisse immobile et
//! que `crate::mouvement` anime quand il le peut. Sans script, ou avec « réduire
//! les animations », la page est celle-ci, entière et immobile.

use active::prelude::*;
use active::Node;

use crate::content::{ExplorerCopy, Lang, TraitCopy};
use crate::doc::mots;
use crate::logo::logo;
use crate::routes::RouteId;
use crate::shell::{bande, href};

/// Une section de l'accueil : son ancre, et son contenu dans la colonne.
fn section_(id: &'static str, contenu: Vec<Node>) -> Element {
    section()
        .id(id)
        .child(div().class("wrap").children(contenu))
}

pub fn accueil(lang: Lang) -> Node {
    let copy = lang.accueil();
    let vers = move |cible: RouteId| href(RouteId::Home, lang, cible, lang);
    let points =
        |liste: &'static [&'static str]| ul().children(liste.iter().map(|p| li().text(*p)));

    fragment([
        // **L'ouverture.** Au repos, un héros plein écran. Avec du mouvement, la
        // section s'allonge, la scène s'épingle, et le défilement forme la
        // marque dans la poussière avant de la rendre — voir
        // `crate::mouvement::ouverture`. Les deux états ont la même scène à la
        // même place au premier pixel : rien ne saute quand le module arrive.
        Node::from(
            section().class("hero").attr("data-ouverture", "").child(
                div()
                    .class("hero-scene")
                    .child(canvas().class("hero-dust").attr("aria-hidden", "true"))
                    .child(
                        div()
                            .class("wrap hero-grid")
                            .child(
                                div()
                                    .class("hero-text")
                                    .child(p().class("badge").text(copy.hero.badge))
                                    .child(h1().class("hero-title").child(mots(copy.hero.tagline)))
                                    .child(p().class("lede").text(copy.hero.lede))
                                    .child(
                                        div()
                                            .class("cta-row")
                                            .child(
                                                a().class("btn btn-primary")
                                                    .attr("data-aimant", "")
                                                    .href(vers(RouteId::Docs))
                                                    .text(copy.cta.primary),
                                            )
                                            .child(
                                                a().class("btn btn-secondary")
                                                    .attr("data-aimant", "")
                                                    .href(vers(RouteId::Releases))
                                                    .text(copy.cta.secondary),
                                            ),
                                    ),
                            )
                            // La marque et le nom d'un seul bloc. La marque seule
                            // est un dessin de `▚`, qui dit ce que fait le
                            // produit mais pas comment il s'appelle ; les deux
                            // ensemble sont ce qu'un lecteur reconnaît plus
                            // tard. Le nom est du vrai texte et non une partie
                            // du dessin : il se sélectionne, se cherche, se lit.
                            .child(
                                div()
                                    .class("hero-lockup")
                                    .child(logo("hero-logo", "hero"))
                                    .child(p().class("hero-wordmark").text("wisq")),
                            ),
                    )
                    // L'invitation à défiler : une goutte qui tombe le long d'un
                    // fil, et qui s'efface dès qu'on a commencé. Décorative —
                    // une flèche qui ne dit rien de plus que la barre de
                    // défilement.
                    .child(
                        div()
                            .class("hero-hint")
                            .attr("aria-hidden", "true")
                            .child(span()),
                    ),
            ),
        ),
        // **La bande.** Les mots-clés des sections du dessous, qui défilent —
        // et que le défilement de la page pousse, dans son sens.
        bande(copy.bande.words),
        section_(
            "modes",
            vec![
                titre(1, copy.modes.title),
                div()
                    .class("cards")
                    .children(
                        [&copy.modes.remote, &copy.modes.local]
                            .into_iter()
                            .map(|mode| {
                                article()
                                    .class("card")
                                    .child(span().class("tag").text(mode.name))
                                    .child(h3().text(mode.head))
                                    .child(p().text(mode.body))
                                    .child(points(mode.points))
                            }),
                    )
                    .into(),
            ],
        )
        .into(),
        // **Les trois protocoles**, chacun avec sa réserve. La réserve a sa
        // propre ligne, sous les points, pour qu'elle ne se lise pas comme un
        // point de plus.
        section_(
            "protocoles",
            vec![
                titre(2, copy.protocoles.title),
                p().class("lede").text(copy.protocoles.lede).into(),
                div()
                    .class("cards cards-3")
                    .children(copy.protocoles.items.iter().map(|p_| {
                        article()
                            .class("card")
                            .child(span().class("tag").text(p_.name))
                            .child(p().text(p_.reach))
                            .child(points(p_.points))
                            .child(p().class("card-reserve").text(p_.caveat))
                    }))
                    .into(),
            ],
        )
        .into(),
        section_(
            "machines",
            vec![
                titre(3, copy.machines.title),
                p().class("lede").text(copy.machines.lede).into(),
                tableau(&copy.machines.columns, copy.machines.rows, true),
                p().class("table-note").text(copy.machines.note).into(),
            ],
        )
        .into(),
        section_(
            "compare",
            vec![
                titre(4, copy.compare.title),
                p().class("lede").text(copy.compare.lede).into(),
                tableau(&copy.compare.columns, copy.compare.rows, false),
            ],
        )
        .into(),
        section_(
            "toucher",
            vec![
                titre(5, copy.toucher.title),
                p().class("lede").text(copy.toucher.lede).into(),
                traits(copy.toucher.items),
            ],
        )
        .into(),
        section_(
            "how",
            vec![
                titre(6, copy.how.title),
                div()
                    .class("steps")
                    .children(copy.how.steps.iter().map(|step| {
                        div()
                            .class("step")
                            .child(div().class("step-num").attr("aria-hidden", "true"))
                            .child(
                                div()
                                    .child(h3().text(step.title))
                                    .child(p().text(step.body)),
                            )
                    }))
                    .into(),
            ],
        )
        .into(),
        section_(
            "securite",
            vec![
                titre(7, copy.securite.title),
                p().class("lede").text(copy.securite.lede).into(),
                traits(copy.securite.items),
            ],
        )
        .into(),
        section_(
            "facts",
            vec![
                titre(8, copy.facts.title),
                div()
                    .class("facts")
                    .children(copy.facts.items.iter().map(|fact| {
                        div()
                            .class("fact")
                            .child(div().class("value").text(fact.value))
                            .child(div().class("label").text(fact.label))
                    }))
                    .into(),
            ],
        )
        .into(),
        // **L'état**, en deux listes. La seconde est dessinée comme la
        // première, sans atténuation : ce qui manque n'est pas une note de bas
        // de page.
        section_(
            "etat",
            vec![
                titre(9, copy.etat.title),
                p().class("lede").text(copy.etat.lede).into(),
                div()
                    .class("etat")
                    .child(
                        div().child(h3().text(copy.etat.done_label)).child(
                            ul().class("etat-liste etat-fait")
                                .children(copy.etat.done.iter().map(|l| li().text(*l))),
                        ),
                    )
                    .child(
                        div().child(h3().text(copy.etat.next_label)).child(
                            ul().class("etat-liste")
                                .children(copy.etat.next.iter().map(|l| li().text(*l))),
                        ),
                    )
                    .into(),
            ],
        )
        .into(),
        // **Le plan des pages.** Chaque carte est un lien entier : le nom de la
        // page en titre, ce qu'on y trouve dessous.
        section_(
            "explorer",
            vec![
                titre(10, copy.explorer.title),
                div()
                    .class("cards cards-3")
                    .children(pistes(&copy.explorer).into_iter().map(|(route, ligne)| {
                        a().class("card card-lien")
                            .href(vers(route))
                            .child(h3().text(route.label(lang.copy())))
                            .child(p().text(ligne))
                    }))
                    .into(),
            ],
        )
        .into(),
    ])
}

/// Le titre d'une section : ses mots, qui montent un à un quand la section
/// arrive, et son rang en très grand derrière lui, que le défilement fait
/// glisser. Le rang est décoratif — la page se lit dans l'ordre sans lui — et
/// il le dit.
fn titre(rang: u8, texte: &'static str) -> Node {
    fragment([
        Node::from(
            span()
                .class("sec-num")
                .attr("aria-hidden", "true")
                .text(format!("{rang:02}")),
        ),
        Node::from(h2().child(mots(texte))),
    ])
}

/// Un tableau dont la première ligne nomme les colonnes. `en_tete_de_ligne`
/// fait de la première cellule de chaque ligne un en-tête : dans le tableau des
/// machines, « Mémoire » est ce dont la ligne parle, pas une donnée.
fn tableau(
    colonnes: &[&'static str; 3],
    lignes: &'static [[&'static str; 3]],
    en_tete_de_ligne: bool,
) -> Node {
    div()
        .class("table-scroll")
        .child(
            table()
                .child(thead().child(
                    tr().children(colonnes.iter().map(|c| th().attr("scope", "col").text(*c))),
                ))
                .child(tbody().children(lignes.iter().map(|ligne| {
                    tr().children(ligne.iter().enumerate().map(|(i, cell)| {
                        if i == 0 && en_tete_de_ligne {
                            th().attr("scope", "row").text(*cell)
                        } else {
                            td().text(*cell)
                        }
                    }))
                }))),
        )
        .into()
}

/// Une liste de termes et de ce qu'ils veulent dire, en grille.
fn traits(items: &'static [TraitCopy]) -> Node {
    dl().class("traits")
        .children(
            items
                .iter()
                .map(|t| div().child(dt().text(t.term)).child(dd().text(t.detail))),
        )
        .into()
}

/// Les pages écrites, dans l'ordre de la navigation, avec leur ligne.
fn pistes(e: &'static ExplorerCopy) -> [(RouteId, &'static str); 8] {
    [
        (RouteId::Docs, e.docs),
        (RouteId::Linux, e.linux),
        (RouteId::Protocol, e.protocol),
        (RouteId::Architecture, e.architecture),
        (RouteId::Faq, e.faq),
        (RouteId::Roadmap, e.roadmap),
        (RouteId::Releases, e.releases),
        (RouteId::Privacy, e.privacy),
    ]
}
