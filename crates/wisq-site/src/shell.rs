//! La coquille que toutes les pages partagent : le lien d'évitement, l'en-tête,
//! les deux navigations, le pied, et les deux îlots que le navigateur hydrate —
//! les réglages de l'en-tête et l'invite d'installation.
//!
//! La langue est l'adresse, pas un réglage. Chaque page existe deux fois —
//! `docs/` et `fr/docs/` — chacune pré-rendue dans sa langue, pour que la
//! première peinture soit déjà juste, qu'un lien partagé s'ouvre dans la langue
//! où il a été écrit, et qu'un moteur de recherche puisse indexer les deux.

use active::prelude::*;
use active::Node;

use crate::content::{Lang, ACTIVE_URL, AUTHOR, AUTHOR_URL, SITE_VERSION};
use crate::installation::install_prompt;
use crate::logo::logo;
use crate::routes::{page_path, relative_base, RouteId, ROUTES};
use crate::theme::theme_switch;

/// L'adresse d'une route depuis la page courante, toujours relative — c'est ce
/// qui garde le site déplaçable.
pub(crate) fn href(depuis: RouteId, langue: Lang, vers: RouteId, langue_cible: Lang) -> String {
    let base = relative_base(depuis, langue);
    let chemin = page_path(vers, langue_cible);
    if chemin.is_empty() {
        base
    } else {
        format!("{base}{chemin}")
    }
}

/// La coquille autour du contenu d'une route.
pub fn shell(route: RouteId, lang: Lang, contenu: Node) -> Node {
    let copy = lang.copy();
    let vers = move |cible: RouteId| href(route, lang, cible, lang);

    fragment([
        Node::from(a().class("skip-link").href("#main").text(copy.pages.home)),
        Node::from(
            header()
                .class("site-header")
                .child(
                    div()
                        .class("wrap header-bar")
                        .child(
                            a().class("brand")
                                .href(vers(RouteId::Home))
                                .text("wisq")
                                .child(span().text("▚")),
                        )
                        // **Le premier îlot.** Le seul endroit de l'en-tête qui
                        // ait un état — le thème choisi — et le seul dont les
                        // liens se souviennent de quelque chose. Le reste de la
                        // page est du balisage que le navigateur garde tel qu'il
                        // arrive.
                        .child(
                            div()
                                .class("header-controls")
                                .attr("data-ilot", "reglages")
                                .child(island("reglages", reglages_props(route, lang), reglages)),
                        ),
                )
                // Toutes les pages du site, en une bande défilante. Des liens
                // plutôt qu'un menu, pour la même raison que ci-dessus.
                .child(
                    nav()
                        .class("site-nav")
                        .attr("aria-label", copy.footer.docs)
                        .child(div().class("wrap site-nav-inner").children(
                            ROUTES.iter().filter(|r| r.listed).map(|r| {
                                let lien = a().href(vers(r.id)).text(r.id.label(copy));
                                if r.id == route {
                                    lien.attr("aria-current", "page")
                                } else {
                                    lien
                                }
                            }),
                        )),
                ),
        ),
        Node::from(main().id("main").child(contenu)),
        footer_(route, lang),
        // **Le second îlot.** Son propre conteneur, comme le premier : la racine
        // d'un îlot est un repère dans la page, et la feuille de style le pose
        // en bas de l'écran.
        Node::from(
            div()
                .class("install-dock")
                .attr("data-ilot", "installation")
                .child(island("installation", lang.code(), install_prompt)),
        ),
    ])
}

/// Les propriétés de l'îlot des réglages : la route et la langue, séparées par
/// une espace — `docs fr`. Elles voyagent dans `data-props`, et le navigateur
/// les relit au lieu de redéduire l'adresse.
pub fn reglages_props(route: RouteId, lang: Lang) -> String {
    format!("{} {}", route.slug(), lang.code())
}

/// La bascule de thème et le choix de langue : ce que l'en-tête a de vivant.
///
/// **Un îlot, et la raison est mesurée.** Hydrater la page entière demandait au
/// module de porter tout ce qu'elle affiche, pour pouvoir le comparer au
/// balisage : avec les dix pages portées, le wasm passait de 254 112 à 351 822
/// octets, soit 148 277 gzippés — la prose des neuf documents et de l'accueil,
/// dans les deux langues, téléchargée par chaque lecteur pour être confrontée à
/// un texte que la page avait déjà. Seuls deux endroits de la page ont un état,
/// donc seuls deux endroits sont des îlots ; le reste est du HTML, et les
/// comportements qui le touchent sont des fonctions Rust sur le DOM.
pub fn reglages(props: &str) -> Node {
    let mut parts = props.split(' ');
    let route = parts
        .next()
        .and_then(RouteId::parse)
        .unwrap_or(RouteId::Home);
    let lang = parts.next().and_then(Lang::parse).unwrap_or(Lang::En);
    let copy = lang.copy();
    fragment([
        theme_switch(lang),
        // Des liens, pas des boutons : chacun est une vraie adresse, donc il
        // s'ouvre dans un nouvel onglet, se met en favori, et se suit sans
        // aucun JavaScript.
        //
        // **Le clic ne fait rien d'autre que se souvenir.** Il n'empêche pas la
        // navigation, il ne la provoque pas : le navigateur suit le lien comme
        // il l'aurait fait, et la seule chose ajoutée est la mémoire d'avoir
        // choisi — qui ne nourrit qu'une décision, la redirection depuis
        // l'accueil anglais. C'est pour ça qu'aucun `prevent_default`
        // n'apparaît ici : un lecteur dont le wasm n'arrive jamais garde un
        // lien qui marche.
        Node::from(
            nav()
                .class("lang-switch")
                .attr("aria-label", copy.language)
                .children(Lang::ALL.into_iter().map(|code| {
                    let lien = a()
                        .href(href(route, lang, route, code))
                        .attr("hreflang", code.code());
                    let lien = if code == lang {
                        lien.attr("aria-current", "true")
                    } else {
                        lien
                    };
                    lien.on_click(move |_| {
                        crate::stockage::ecrire(crate::stockage::LANGUE, code.code());
                    })
                    .text(code.code().to_uppercase())
                })),
        ),
    ])
}

/// Le pied porte ce que l'en-tête ne peut pas.
///
/// Le pied d'un site de projet est là où l'on va quand la page n'a pas répondu
/// à la question : où est la source, comment signaler quelque chose, quelle est
/// la licence, est-ce qu'on est pisté. Les grouper par ce que le lecteur veut —
/// l'utiliser, le comprendre, y contribuer — vaut mieux qu'une longue rangée de
/// liens où tout est également introuvable.
fn footer_(route: RouteId, lang: Lang) -> Node {
    let copy = lang.copy();
    let vers = move |cible: RouteId| href(route, lang, cible, lang);

    let groupes: [(&'static str, &[RouteId]); 3] = [
        (
            copy.footer.groups.product,
            &[
                RouteId::Docs,
                RouteId::Linux,
                RouteId::Releases,
                RouteId::Roadmap,
            ],
        ),
        (
            copy.footer.groups.documentation,
            &[RouteId::Protocol, RouteId::Architecture, RouteId::Faq],
        ),
        (
            copy.footer.groups.project,
            &[RouteId::Home, RouteId::Privacy],
        ),
    ];

    footer()
        .class("site-footer")
        // La bande de l'accueil, au pied de chaque page : la même piste, que le
        // défilement pousse aussi ici.
        .child(bande(lang.accueil().bande.words))
        .child(
            div()
                .class("wrap footer-top")
                .child(
                    div()
                        .class("footer-brand")
                        // La marque et le nom, la même paire que le héros à une
                        // taille que le pied peut tenir. À l'intérieur du lien,
                        // pour que tout le bloc soit le chemin du retour et pas
                        // seulement les quatre lettres.
                        .child(
                            a().class("brand footer-brand-link")
                                .href(vers(RouteId::Home))
                                .child(logo("footer-logo", "footer"))
                                .child(
                                    span()
                                        .class("footer-wordmark")
                                        .text("wisq")
                                        .child(span().text("▚")),
                                ),
                        )
                        .child(p().text(copy.footer.tagline))
                        // Une seule chaîne plutôt que trois enfants : une ligne
                        // coupée en nœuds de texte adjacents est plus dure à
                        // lire pour tout ce qui lit du HTML.
                        .child(p().class("footer-version").text(format!(
                            "{} {} · {}",
                            copy.footer.version, SITE_VERSION, copy.footer.rights
                        )))
                        // La paternité est auprès du mot-symbole, là où un
                        // lecteur cherche qui a fait une chose. Le crédit au
                        // travail d'autrui reste dans la barre du bas et n'est
                        // pas touché par ceci : une ligne qui dit ce qui est à
                        // moi ne doit jamais se lire comme une revendication sur
                        // ce qui ne l'est pas.
                        .child(
                            p().class("footer-author")
                                .text(format!("{} ", copy.footer.author))
                                .child(a().href(AUTHOR_URL).attr("rel", "author").text(AUTHOR)),
                        )
                        // **Avec quoi ce site est fait, et par qui.** Le front
                        // est écrit avec Active, la bibliothèque front-end en
                        // Rust du même auteur : c'est dit ici, sur chaque page,
                        // avec un lien vers elle — et `<meta name="generator">`
                        // le dit aux machines.
                        .child(
                            p().class("footer-built")
                                .attr("data-built-with", "active")
                                .text(format!("{} ", copy.footer.built_with))
                                .child(a().href(ACTIVE_URL).text("Active"))
                                .text(format!("{} ", copy.footer.built_by))
                                .child(a().href(AUTHOR_URL).attr("rel", "author").text(AUTHOR))
                                .text("."),
                        ),
                )
                .child(
                    nav()
                        .class("footer-groups")
                        .attr("aria-label", copy.footer.docs)
                        .children(groupes.into_iter().map(|(titre, liens)| {
                            div().child(h2().text(titre)).child(
                                ul().children(liens.iter().map(|id| {
                                    li().child(a().href(vers(*id)).text(id.label(copy)))
                                })),
                            )
                        })),
                ),
        )
        .child(
            div()
                .class("wrap footer-bottom")
                .child(p().class("footer-note").text(copy.footer.note))
                .child(p().class("footer-note").text(copy.footer.privacy_note))
                .child(p().class("footer-note").text(copy.footer.attribution))
                .child(
                    div()
                        .class("footer-legal")
                        .child(span().text(copy.footer.copyright))
                        .child(a().href(vers(RouteId::Privacy)).text(copy.pages.privacy))
                        .child(a().href("#main").text(copy.footer.back_to_top)),
                ),
        )
        // **Le nom, en très grand, pour finir.** Décoratif — le pied le dit déjà
        // en haut, en texte qu'on lit —, et chaque lettre est sa propre boîte
        // pour monter à son tour quand le pied arrive.
        .child(
            p().class("pied-geant")
                .attr("aria-hidden", "true")
                .children("wisq▚".chars().map(|c| span().text(c.to_string()))),
        )
        .into()
}

/// **La bande** : des mots-clés en très grand, qui défilent.
///
/// Deux fois la liste, parce qu'une piste qui avance de la moitié de sa largeur
/// et recommence n'a pas de couture ; au repos, la seconde copie est masquée et
/// la première va à la ligne. Décorative, et elle le dit : elle répète en mots
/// ce que la page explique en phrases.
pub(crate) fn bande(mots: &'static [&'static str]) -> Node {
    div()
        .class("bande")
        .attr("aria-hidden", "true")
        .child(
            div()
                .class("bande-piste")
                .children(mots.iter().map(|mot| span().class("bande-mot").text(*mot)))
                .children(
                    mots.iter()
                        .map(|mot| span().class("bande-mot bande-double").text(*mot)),
                ),
        )
        .into()
}
