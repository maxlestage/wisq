//! Rend en HTML toutes les pages du site, et dit à la construction tout ce
//! qu'elle doit savoir pour les écrire.
//!
//! C'est l'équivalent exact de ce que `site/build.tsx` faisait avec
//! `renderToString` de React : le balisage arrive dans la première réponse, un
//! moteur de recherche voit une vraie page, et le WebAssembly n'est nécessaire
//! qu'aux deux îlots et au mouvement.
//!
//! **Un catalogue, pas seulement du balisage.** La construction avait besoin de
//! la liste des routes, des titres, des descriptions, des couleurs de barre et
//! de l'auteur ; elle les lisait dans `src/routes.ts`, `src/content.ts`,
//! `src/pages/*.ts` et `src/theme.ts`, qui étaient des copies de ce que ce crate
//! déclare. Ces fichiers sont partis avec React. Tout passe maintenant par ce
//! binaire, une fois, et les tests lisent le même catalogue : une seule source
//! pour la page, la construction et la garde.
//!
//! **Le JSON est écrit à la main**, comme celui du démon, et pour la même
//! raison : ajouter serde et son dérive à ce crate les ferait entrer dans
//! l'arbre de dépendances du wasm, où chaque octet est compté. L'échappement
//! couvre ce que la spécification JSON exige d'échapper, et un test le vérifie.

use wisq_site::content::{Lang, AUTHOR, AUTHOR_URL, SITE_VERSION};
use wisq_site::installation::{InstallPrompt, InstallProps};
use wisq_site::pages::{self, RELEASED_VERSIONS};
use wisq_site::routes::{output_path, page_path, relative_base, RouteId, ROUTES};
use wisq_site::shell::{Reglages, ReglagesProps};
use wisq_site::theme::{BAR_CLAIR, BAR_SOMBRE};
use wisq_site::{Page, PageProps};
use yew::{BaseComponent, ServerRenderer};

/// Échappe une chaîne pour un littéral JSON.
///
/// Les trois obligations de la spécification : le guillemet, la barre inverse,
/// et tout ce qui est sous U+0020. Le balisage HTML contient `<`, `>` et `&`,
/// qui n'ont rien à y faire. `/` n'a pas besoin d'être échappé.
fn json(texte: &str) -> String {
    let mut sortie = String::with_capacity(texte.len() + 2);
    sortie.push('"');
    for c in texte.chars() {
        match c {
            '"' => sortie.push_str("\\\""),
            '\\' => sortie.push_str("\\\\"),
            '\n' => sortie.push_str("\\n"),
            '\r' => sortie.push_str("\\r"),
            '\t' => sortie.push_str("\\t"),
            '\u{08}' => sortie.push_str("\\b"),
            '\u{0c}' => sortie.push_str("\\f"),
            c if (c as u32) < 0x20 => sortie.push_str(&format!("\\u{:04x}", c as u32)),
            c => sortie.push(c),
        }
    }
    sortie.push('"');
    sortie
}

/// Un objet JSON à partir de paires déjà écrites.
fn objet(paires: &[(&str, String)]) -> String {
    let corps: Vec<String> = paires
        .iter()
        .map(|(cle, valeur)| format!("{}:{valeur}", json(cle)))
        .collect();
    format!("{{{}}}", corps.join(","))
}

fn liste(valeurs: impl IntoIterator<Item = String>) -> String {
    format!("[{}]", valeurs.into_iter().collect::<Vec<_>>().join(","))
}

/// La copie que la construction et les gardes lisent, par langue.
fn copie(lang: Lang) -> String {
    let c = lang.copy();
    let a = lang.accueil();
    objet(&[
        (
            "pages",
            objet(
                &ROUTES
                    .iter()
                    .map(|r| (r.id.slug(), json(r.id.label(c))))
                    .collect::<Vec<_>>(),
            ),
        ),
        (
            "footer",
            objet(&[
                ("author", json(c.footer.author)),
                ("rights", json(c.footer.rights)),
                ("copyright", json(c.footer.copyright)),
                ("backToTop", json(c.footer.back_to_top)),
                ("version", json(c.footer.version)),
            ]),
        ),
        (
            "hero",
            objet(&[
                ("tagline", json(a.hero.tagline)),
                ("lede", json(a.hero.lede)),
            ]),
        ),
        (
            "facts",
            liste(
                a.facts
                    .items
                    .iter()
                    .map(|f| objet(&[("value", json(f.value)), ("label", json(f.label))])),
            ),
        ),
    ])
}

/// Le titre et la description d'une page : ceux du document pour une page
/// écrite, ceux de l'accueil sinon.
fn tete(route: RouteId, lang: Lang) -> (String, &'static str) {
    match pages::doc(route, lang) {
        Some(d) => (format!("{} — wisq", d.title), d.lede),
        None => (lang.accueil().title.to_string(), lang.accueil().hero.lede),
    }
}

/// Une phrase de prose de la page, assez longue pour qu'aucune autre ne la
/// contienne par hasard. Les gardes la cherchent dans le balisage — elle doit
/// y être — et dans le module — elle ne doit pas y être.
fn phrase(route: RouteId, lang: Lang) -> Option<&'static str> {
    pages::doc(route, lang)?
        .blocks
        .iter()
        .find_map(|b| match b {
            wisq_site::doc::Block::P(t) if t.len() > 40 => Some(*t),
            _ => None,
        })
}

/// Un composant rendu en HTML, avec ou sans les marqueurs d'hydratation.
async fn rendre<C>(props: C::Properties, hydratable: bool) -> String
where
    C: BaseComponent,
    C::Properties: Send + Clone,
{
    ServerRenderer::<C>::with_props(move || props.clone())
        .hydratable(hydratable)
        .render()
        .await
}

/// **La page sans marqueurs, et les îlots avec.**
///
/// Yew pose un commentaire `<!--<[]>-->` à chaque bord de composant pour
/// retrouver son arbre à l'hydratation. Rendue d'un bloc, la page en portait
/// une vingtaine — autour de l'accueil, du pied, de chaque logo — pour des
/// régions que rien n'hydratera jamais. La page est donc rendue sans eux, et
/// chacun des deux îlots est rendu une seconde fois, avec, puis remis à sa
/// place. La frontière se lit dans le HTML publié : là où il y a des
/// marqueurs, il y a un îlot, et nulle part ailleurs.
///
/// **Et la substitution refuse plutôt que de deviner.** Le rendu sans
/// marqueurs d'un îlot doit apparaître exactement une fois dans la page : zéro
/// voudrait dire que la coquille ne le rend plus comme ce binaire le croit,
/// deux qu'il ne saurait pas lequel remplacer. Dans les deux cas, la page
/// publiée aurait un îlot que le module ne pourrait pas reprendre.
async fn page(route: RouteId, lang: Lang) -> String {
    let mut balisage = rendre::<Page>(PageProps { route, lang }, false).await;
    let ilots = [
        (
            "reglages",
            rendre::<Reglages>(ReglagesProps { route, lang }, false).await,
            rendre::<Reglages>(ReglagesProps { route, lang }, true).await,
        ),
        (
            "installation",
            rendre::<InstallPrompt>(InstallProps { lang }, false).await,
            rendre::<InstallPrompt>(InstallProps { lang }, true).await,
        ),
    ];
    for (nom, inerte, hydratable) in ilots {
        let vus = balisage.matches(&inerte).count();
        assert!(
            vus == 1,
            "{}/{} : l'îlot « {nom} » apparaît {vus} fois dans la page, il en faut une",
            lang.code(),
            route.slug()
        );
        balisage = balisage.replacen(&inerte, &hydratable, 1);
    }
    balisage
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let mut rendues: Vec<String> = Vec::new();
    for lang in Lang::ALL {
        for route in ROUTES.iter().map(|r| r.id) {
            let balisage = page(route, lang).await;
            let (titre, description) = tete(route, lang);
            rendues.push(objet(&[
                ("route", json(route.slug())),
                ("lang", json(lang.code())),
                ("file", json(&output_path(route, lang))),
                ("path", json(&page_path(route, lang))),
                ("base", json(&relative_base(route, lang))),
                ("title", json(&titre)),
                ("description", json(description)),
                (
                    "sentence",
                    phrase(route, lang).map(json).unwrap_or("null".into()),
                ),
                ("markup", json(&balisage)),
            ]));
        }
    }

    let catalogue = objet(&[
        ("langs", liste(Lang::ALL.iter().map(|l| json(l.code())))),
        (
            "bar",
            objet(&[("light", json(BAR_CLAIR)), ("dark", json(BAR_SOMBRE))]),
        ),
        ("author", json(AUTHOR)),
        ("authorUrl", json(AUTHOR_URL)),
        ("version", json(SITE_VERSION)),
        (
            "releasedVersions",
            liste(RELEASED_VERSIONS.iter().map(|v| json(v))),
        ),
        (
            "routes",
            liste(ROUTES.iter().map(|r| {
                objet(&[
                    ("id", json(r.id.slug())),
                    ("path", json(r.path)),
                    ("listed", r.listed.to_string()),
                    ("output", r.output.map(json).unwrap_or("null".into())),
                ])
            })),
        ),
        ("copy", objet(&Lang::ALL.map(|l| (l.code(), copie(l))))),
        ("pages", liste(rendues)),
    ]);
    println!("{catalogue}");
}

#[cfg(test)]
mod tests {
    use super::{json, objet};

    #[test]
    fn l_echappement_couvre_ce_que_json_exige() {
        assert_eq!(json(r#"a"b"#), r#""a\"b""#);
        assert_eq!(json(r"a\b"), r#""a\\b""#);
        assert_eq!(json("a\nb"), r#""a\nb""#);
        assert_eq!(json("a\u{1}b"), r#""a\u0001b""#);
        // Ce qui n'a pas à être touché : le balisage, et l'UTF-8 tel quel.
        assert_eq!(json("<p>é & ▚</p>"), "\"<p>é & ▚</p>\"");
        assert_eq!(
            objet(&[("a", "1".into()), ("b", json("x"))]),
            r#"{"a":1,"b":"x"}"#
        );
    }
}
