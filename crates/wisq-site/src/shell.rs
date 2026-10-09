//! La coquille que toutes les pages partagent : le lien d'évitement, l'en-tête,
//! les deux navigations, le pied, et l'invite d'installation.
//!
//! La langue est l'adresse, pas un réglage. Chaque page existe deux fois —
//! `docs/` et `fr/docs/` — chacune pré-rendue dans sa langue, pour que la
//! première peinture soit déjà juste, qu'un lien partagé s'ouvre dans la langue
//! où il a été écrit, et qu'un moteur de recherche puisse indexer les deux.

use yew::prelude::*;

use crate::content::{Lang, AUTHOR, AUTHOR_URL, SITE_VERSION};
use crate::installation::InstallPrompt;
use crate::logo::Logo;
use crate::routes::{page_path, relative_base, RouteId, ROUTES};
use crate::theme::ThemeSwitch;

/// L'adresse d'une route depuis la page courante, toujours relative — c'est ce
/// qui garde le site déplaçable.
fn href(depuis: RouteId, langue: Lang, vers: RouteId, langue_cible: Lang) -> String {
    let base = relative_base(depuis, langue);
    let chemin = page_path(vers, langue_cible);
    if chemin.is_empty() {
        base
    } else {
        format!("{base}{chemin}")
    }
}

#[derive(Properties, PartialEq)]
pub struct ShellProps {
    pub route: RouteId,
    pub lang: Lang,
    pub children: Html,
}

#[function_component]
pub fn Shell(props: &ShellProps) -> Html {
    let (route, lang) = (props.route, props.lang);
    let copy = lang.copy();
    let vers = move |cible: RouteId| href(route, lang, cible, lang);

    html! {
        <>
            <a class="skip-link" href="#main">{ copy.pages.home }</a>

            <header class="site-header">
                <div class="wrap header-bar">
                    <a class="brand" href={vers(RouteId::Home)}>
                        { "wisq" }<span>{ "▚" }</span>
                    </a>
                    <ThemeSwitch lang={lang} />
                    // Des liens, pas des boutons : chacun est une vraie adresse,
                    // donc il s'ouvre dans un nouvel onglet, se met en favori, et
                    // se suit sans aucun JavaScript.
                    //
                    // **Le clic ne fait rien d'autre que se souvenir.** Il
                    // n'empêche pas la navigation, il ne la provoque pas : le
                    // navigateur suit le lien comme il l'aurait fait, et la seule
                    // chose ajoutée est la mémoire d'avoir choisi — qui ne nourrit
                    // qu'une décision, la redirection depuis l'accueil anglais.
                    // C'est pour ça qu'aucun `prevent_default` n'apparaît ici : un
                    // lecteur dont le wasm n'arrive jamais garde un lien qui marche.
                    <nav class="lang-switch" aria-label={copy.language}>
                        { for Lang::ALL.into_iter().map(|code| {
                            let au_clic = Callback::from(move |_: MouseEvent| {
                                crate::stockage::ecrire(crate::stockage::LANGUE, code.code());
                            });
                            html! {
                                <a href={href(route, lang, route, code)} hreflang={code.code()}
                                   aria-current={(code == lang).then(|| AttrValue::from("true"))}
                                   onclick={au_clic}>
                                    { code.code().to_uppercase() }
                                </a>
                            }
                        }) }
                    </nav>
                </div>
                // Toutes les pages du site, en une bande défilante. Des liens
                // plutôt qu'un menu, pour la même raison que ci-dessus.
                <nav class="site-nav" aria-label={copy.footer.docs}>
                    <div class="wrap site-nav-inner">
                        { for ROUTES.iter().filter(|r| r.listed).map(|r| html! {
                            <a href={vers(r.id)}
                               aria-current={(r.id == route).then(|| AttrValue::from("page"))}>
                                { r.id.label(copy) }
                            </a>
                        }) }
                    </div>
                </nav>
            </header>

            <main id="main">{ props.children.clone() }</main>

            <Footer route={route} lang={lang} />
            <InstallPrompt lang={lang} />
        </>
    }
}

#[derive(Properties, PartialEq)]
struct FooterProps {
    route: RouteId,
    lang: Lang,
}

/// Le pied porte ce que l'en-tête ne peut pas.
///
/// Le pied d'un site de projet est là où l'on va quand la page n'a pas répondu
/// à la question : où est la source, comment signaler quelque chose, quelle est
/// la licence, est-ce qu'on est pisté. Les grouper par ce que le lecteur veut —
/// l'utiliser, le comprendre, y contribuer — vaut mieux qu'une longue rangée de
/// liens où tout est également introuvable.
#[function_component]
fn Footer(props: &FooterProps) -> Html {
    let (route, lang) = (props.route, props.lang);
    let copy = lang.copy();
    let vers = move |cible: RouteId| href(route, lang, cible, lang);

    let groupes: [(&'static str, &[RouteId]); 3] = [
        (
            copy.footer.groups.product,
            &[RouteId::Docs, RouteId::Releases, RouteId::Roadmap],
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

    html! {
        <footer class="site-footer">
            <div class="wrap footer-top">
                <div class="footer-brand">
                    // La marque et le nom, la même paire que le héros à une
                    // taille que le pied peut tenir. À l'intérieur du lien, pour
                    // que tout le bloc soit le chemin du retour et pas seulement
                    // les quatre lettres.
                    <a class="brand footer-brand-link" href={vers(RouteId::Home)}>
                        <Logo class="footer-logo" instance="footer" />
                        <span class="footer-wordmark">{ "wisq" }<span>{ "▚" }</span></span>
                    </a>
                    <p>{ copy.footer.tagline }</p>
                    // Une seule chaîne plutôt que trois enfants : un moteur de
                    // rendu qui sépare deux nœuds de texte adjacents pose des
                    // marqueurs dans le HTML, et une ligne ainsi coupée est plus
                    // dure à lire pour tout ce qui lit du HTML.
                    <p class="footer-version">
                        { format!("{} {} · {}", copy.footer.version, SITE_VERSION, copy.footer.rights) }
                    </p>
                    // La paternité est auprès du mot-symbole, là où un lecteur
                    // cherche qui a fait une chose. Le crédit au travail d'autrui
                    // reste dans la barre du bas et n'est pas touché par ceci :
                    // une ligne qui dit ce qui est à moi ne doit jamais se lire
                    // comme une revendication sur ce qui ne l'est pas.
                    <p class="footer-author">
                        { format!("{} ", copy.footer.author) }
                        <a href={AUTHOR_URL} rel="author">{ AUTHOR }</a>
                    </p>
                </div>

                <nav class="footer-groups" aria-label={copy.footer.docs}>
                    { for groupes.into_iter().map(|(titre, liens)| html! {
                        <div>
                            <h2>{ titre }</h2>
                            <ul>
                                { for liens.iter().map(|id| html! {
                                    <li><a href={vers(*id)}>{ id.label(copy) }</a></li>
                                }) }
                            </ul>
                        </div>
                    }) }
                </nav>
            </div>

            <div class="wrap footer-bottom">
                <p class="footer-note">{ copy.footer.note }</p>
                <p class="footer-note">{ copy.footer.privacy_note }</p>
                <p class="footer-note">{ copy.footer.attribution }</p>
                <div class="footer-legal">
                    <span>{ copy.footer.copyright }</span>
                    <a href={vers(RouteId::Privacy)}>{ copy.pages.privacy }</a>
                    <a href="#main">{ copy.footer.back_to_top }</a>
                </div>
            </div>
        </footer>
    }
}
