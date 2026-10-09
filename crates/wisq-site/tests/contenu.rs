//! **Les gardes du contenu, portées avec lui.** Elles vivaient dans
//! `site/tests/render.test.tsx`, qui lisait les pages en TypeScript ; le
//! contenu est dans ce crate maintenant, donc elles aussi. Une traduction
//! absente ne compile déjà pas — `Doc` n'a pas de valeur par défaut — et ces
//! trois-ci attrapent l'autre moitié : une chaîne qui existe mais qui est vide,
//! une langue plus riche que l'autre, une page qui n'en est pas une.
//!
//! **Ici et non à côté des pages, et c'est une garde qui l'a dit.**
//! `site/tests/claims.test.ts` relit chaque fichier de `src/pages/` et exige
//! une provenance pour chaque nombre qu'il porte ; un seuil de test écrit là
//! passerait pour un chiffre que le site publie.

use wisq_site::content::Lang;
use wisq_site::doc::{Block, Doc};
use wisq_site::pages::doc;
use wisq_site::routes::{RouteId, ROUTES};

/// En dessous, une page écrite n'en est pas une : c'est un bouchon.
const MOTS_MINIMUM: usize = 200;

fn chaines(d: &Doc) -> Vec<&'static str> {
    let mut out = vec![d.title, d.lede];
    for b in d.blocks {
        match b {
            Block::P(t) | Block::H2(t) | Block::H3(t) | Block::Note { text: t, .. } => out.push(t),
            Block::Ul(items) | Block::Ol(items) => out.extend(items.iter().copied()),
            Block::Code { code, caption } => {
                out.push(code);
                out.extend(caption.iter().copied());
            }
            Block::Table { columns, rows } => {
                out.extend(columns.iter().copied());
                for r in rows.iter() {
                    out.extend(r.iter().copied());
                }
            }
            Block::Dl(items) => {
                for i in items.iter() {
                    out.push(i.term);
                    out.push(i.detail);
                }
            }
        }
    }
    out
}

fn documents() -> impl Iterator<Item = (RouteId, &'static Doc, &'static Doc)> {
    ROUTES
        .iter()
        .filter_map(|r| Some((r.id, doc(r.id, Lang::En)?, doc(r.id, Lang::Fr)?)))
}

#[test]
fn les_deux_langues_remplissent_chaque_page() {
    let accueil = ROUTES
        .iter()
        .filter(|r| doc(r.id, Lang::En).is_none())
        .count();
    assert_eq!(accueil, 1, "seul l'accueil n'est pas un document");
    for (id, en, fr) in documents() {
        for (lang, d) in [("en", en), ("fr", fr)] {
            for s in chaines(d) {
                assert!(!s.trim().is_empty(), "chaîne vide : {lang}/{}", id.slug());
            }
        }
    }
}

#[test]
fn les_deux_langues_ont_les_memes_pages_bloc_pour_bloc() {
    for (id, en, fr) in documents() {
        let forme = |d: &Doc| {
            d.blocks
                .iter()
                .map(std::mem::discriminant)
                .collect::<Vec<_>>()
        };
        assert_eq!(forme(en), forme(fr), "structure : {}", id.slug());
    }
}

#[test]
fn aucune_page_ecrite_n_est_un_bouchon() {
    for (id, en, fr) in documents() {
        if matches!(id, RouteId::Offline | RouteId::NotFound) {
            continue;
        }
        for (lang, d) in [("en", en), ("fr", fr)] {
            let mots: usize = chaines(d)
                .iter()
                .map(|s| s.split_whitespace().count())
                .sum();
            assert!(
                mots > MOTS_MINIMUM,
                "{lang}/{} est trop court pour être une page",
                id.slug()
            );
        }
    }
}
