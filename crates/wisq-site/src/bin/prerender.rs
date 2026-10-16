//! Rend en HTML toutes les pages du site, et dit à la construction tout ce
//! qu'elle doit savoir pour les écrire.
//!
//! Les vues sont celles d'Active : `Node::render` écrit chaque page dans une
//! `String`, de façon synchrone. Le balisage arrive dans la première réponse,
//! un moteur de recherche voit une vraie page, et le WebAssembly n'est
//! nécessaire qu'aux îlots et au mouvement.
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

use wisq_site::content::{Lang, ACTIVE_URL, AUTHOR, AUTHOR_URL, SITE_VERSION};
use wisq_site::pages::{self, RELEASED_VERSIONS};
use wisq_site::routes::{output_path, page_path, relative_base, RouteId, ROUTES};
use wisq_site::theme::{BAR_CLAIR, BAR_SOMBRE};

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
    match (route, pages::doc(route, lang)) {
        (_, Some(d)) => (format!("{} — wisq", d.title), d.lede),
        (RouteId::Linux, None) => (format!("{} — wisq", lang.linux().title), lang.linux().lede),
        (_, None) => (lang.accueil().title.to_string(), lang.accueil().hero.lede),
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

/// **La page, et les îlots marqués par Active.**
///
/// Active n'écrit de marque que là où le navigateur aura quelque chose à
/// reprendre : `<active-island data-island=… data-props=…>` autour de chaque
/// îlot, et à l'intérieur les commentaires qui situent un texte ou une région
/// dynamique. Le reste de la page est du HTML nu. La frontière se lit donc dans
/// le HTML publié, comme avant — sans que ce binaire ait à rendre chaque îlot
/// deux fois pour la tracer à la main, ce que demandait Yew.
fn page(route: RouteId, lang: Lang) -> String {
    wisq_site::page(route, lang).render()
}

fn main() {
    let mut rendues: Vec<String> = Vec::new();
    for lang in Lang::ALL {
        for route in ROUTES.iter().map(|r| r.id) {
            let balisage = page(route, lang);
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
        // Avec quoi le front est écrit : la construction en fait le
        // `<meta name="generator">` de chaque page.
        (
            "generator",
            objet(&[
                ("name", json("Active")),
                ("version", json(active::VERSION)),
                ("url", json(ACTIVE_URL)),
            ]),
        ),
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
