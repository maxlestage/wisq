//! Les pages écrites : un modèle de blocs, et le rendu qui en fait du HTML.
//!
//! Le jeu de blocs est volontairement petit. Chaque sorte ici gagne sa place en
//! portant quelque chose qu'un paragraphe ne porterait pas.
//!
//! **Les neuf sortes sont écrites maintenant, alors qu'une seule page est
//! portée.** C'est la leçon la plus rentable des tranches précédentes : une
//! garde — ou ici un rendu — écrite une tranche en avance rend la suivante
//! presque gratuite. Les pages qui arrivent n'auront que du contenu à ajouter,
//! pas du code.

use active::prelude::*;
use active::Node;

use crate::content::Lang;

#[derive(Clone, PartialEq)]
pub enum Tone {
    Info,
    Warn,
}

impl Tone {
    fn slug(&self) -> &'static str {
        match self {
            Tone::Info => "info",
            Tone::Warn => "warn",
        }
    }
}

#[derive(Clone, PartialEq)]
pub struct DlItem {
    pub term: &'static str,
    pub detail: &'static str,
}

#[derive(Clone, PartialEq)]
pub enum Block {
    P(&'static str),
    H2(&'static str),
    H3(&'static str),
    Ul(&'static [&'static str]),
    Ol(&'static [&'static str]),
    Code {
        code: &'static str,
        caption: Option<&'static str>,
    },
    Note {
        tone: Tone,
        text: &'static str,
    },
    Table {
        columns: &'static [&'static str],
        rows: &'static [&'static [&'static str]],
    },
    Dl(&'static [DlItem]),
}

#[derive(Clone, PartialEq)]
pub struct Doc {
    pub title: &'static str,
    pub lede: &'static str,
    pub blocks: &'static [Block],
}

/// L'ancre d'un titre, dérivée de son texte.
///
/// Le même calcul que la version TypeScript : minuscules, accents retirés, tout
/// ce qui n'est pas alphanumérique replié en tirets, et pas de tiret aux bouts.
/// La décomposition NFD de JavaScript n'existe pas dans la bibliothèque standard
/// de Rust, et l'ajouter coûterait une table Unicode dans le wasm ; les accents
/// qui apparaissent réellement dans les titres du site sont donc dépliés à la
/// main, et tout caractère non ASCII restant devient un tiret comme le ferait
/// l'original après décomposition.
pub fn slug(texte: &str) -> String {
    let mut sortie = String::with_capacity(texte.len());
    let mut tiret_en_attente = false;
    for brut in texte.chars() {
        // **Minuscule d'abord, et le test a dit pourquoi.** Le premier jet
        // repliait les accents puis appelait `to_ascii_lowercase`, qui ne touche
        // pas le non-ASCII : « À propos » rendait « propos », le A initial
        // tombant comme un caractère non alphanumérique. `to_lowercase` est la
        // version Unicode, et elle rend un itérateur parce qu'un caractère peut
        // en donner plusieurs ; aucun de ceux qui nous concernent ne le fait,
        // donc le premier suffit, et le repli garde l'original si jamais.
        let c = brut.to_lowercase().next().unwrap_or(brut);
        let base = match c {
            'à' | 'â' | 'ä' | 'á' | 'ã' | 'å' => 'a',
            'ç' => 'c',
            'è' | 'é' | 'ê' | 'ë' => 'e',
            'ì' | 'í' | 'î' | 'ï' => 'i',
            'ñ' => 'n',
            'ò' | 'ó' | 'ô' | 'ö' | 'õ' => 'o',
            'ù' | 'ú' | 'û' | 'ü' => 'u',
            'ý' | 'ÿ' => 'y',
            autre => autre.to_ascii_lowercase(),
        };
        if base.is_ascii_alphanumeric() {
            if tiret_en_attente && !sortie.is_empty() {
                sortie.push('-');
            }
            tiret_en_attente = false;
            sortie.push(base);
        } else {
            tiret_en_attente = true;
        }
    }
    sortie
}

fn rendre(bloc: &Block) -> Node {
    match bloc {
        Block::P(texte) => p().text(*texte).into(),

        // Chaque section est adressable, pour qu'un lien vers le milieu du guide
        // arrive là où il le dit.
        Block::H2(texte) => {
            let id = slug(texte);
            h2().id(id.clone())
                .child(
                    a().class("anchor")
                        .href(format!("#{id}"))
                        .attr("aria-label", *texte)
                        .child(mots(texte)),
                )
                .into()
        }

        Block::H3(texte) => h3().id(slug(texte)).text(*texte).into(),

        Block::Ul(items) => ul()
            .class("doc-list")
            .children(items.iter().map(|i| li().text(*i)))
            .into(),

        Block::Ol(items) => ol()
            .class("doc-list doc-steps")
            .children(items.iter().map(|i| li().text(*i)))
            .into(),

        // Le code arrive ligne par ligne, comme dans un terminal : chaque ligne
        // est sa propre boîte, avec son rang. Les fins de ligne restent de
        // vrais nœuds de texte **entre** les boîtes, donc ce qu'on sélectionne
        // et copie est le texte exact, et sans le module le bloc est le même
        // `pre` qu'avant.
        Block::Code { code, caption } => figure()
            .class("doc-code")
            .child(caption.map(|c| figcaption().text(c)))
            .child(pre().child(el("code").child(lignes(code))))
            .into(),

        Block::Note { tone, text } => aside()
            .class(format!("doc-note doc-note-{}", tone.slug()))
            .child(p().text(*text))
            .into(),

        Block::Table { columns, rows } => {
            div()
                .class("table-scroll")
                .child(
                    table()
                        .child(thead().child(
                            tr().children(
                                columns.iter().map(|c| th().attr("scope", "col").text(*c)),
                            ),
                        ))
                        .child(tbody().children(rows.iter().map(|ligne| {
                            tr().children(ligne.iter().map(|cell| td().text(*cell)))
                        }))),
                )
                .into()
        }

        Block::Dl(items) => dl()
            .class("doc-dl")
            .children(
                items
                    .iter()
                    .map(|i| div().child(dt().text(i.term)).child(dd().text(i.detail))),
            )
            .into(),
    }
}

/// Les lignes d'un bloc de code, chacune dans sa boîte.
fn lignes(code: &'static str) -> Node {
    let total = code.split('\n').count();
    let mut noeuds: Vec<Node> = Vec::with_capacity(total * 2);
    for (i, ligne) in code.split('\n').enumerate() {
        noeuds.push(
            span()
                .class("ligne")
                .style(format!("--l:{i}"))
                .text(ligne)
                .into(),
        );
        if i + 1 < total {
            noeuds.push("\n".into());
        }
    }
    noeuds.into()
}

/// Une phrase, mot par mot : le titre du héros et celui de chaque page écrite.
///
/// **Chaque mot est un masque et son contenu**, pour que l'entrée soit celle de
/// la référence : le mot monte depuis sous sa ligne au lieu d'apparaître. Le
/// rang part dans `--i`, dont la feuille de style fait un retard. Les espaces
/// restent de vrais nœuds de texte entre les mots : un titre se lit, se
/// sélectionne et se copie avec ses espaces, et un lecteur d'écran lit une
/// suite de `span` en ligne comme la phrase qu'elle est.
pub(crate) fn mots(phrase: &'static str) -> Node {
    let total = phrase.split(' ').count();
    let mut noeuds: Vec<Node> = Vec::with_capacity(total * 2);
    for (i, mot) in phrase.split(' ').enumerate() {
        noeuds.push(
            span()
                .class("mot")
                .style(format!("--i:{i}"))
                .child(span().text(mot))
                .into(),
        );
        if i + 1 < total {
            noeuds.push(" ".into());
        }
    }
    noeuds.into()
}

/// À partir de combien de sections une page a un sommaire. En dessous, la page
/// tient sur un écran ou deux, et un sommaire de deux lignes serait plus long à
/// lire que ce qu'il résume.
const SECTIONS_MIN: usize = 3;

/// Le sommaire d'une page écrite : ses `h2`, dans l'ordre, chacun vers son
/// ancre. Rendu à la construction comme le reste, donc il marche sans le
/// module ; le module ne fait que suivre la section lue.
fn sommaire(doc: &Doc, lang: Lang) -> Node {
    let titres: Vec<&'static str> = doc
        .blocks
        .iter()
        .filter_map(|b| match b {
            Block::H2(t) => Some(*t),
            _ => None,
        })
        .collect();
    if titres.len() < SECTIONS_MIN {
        return Node::Empty;
    }
    let nom = match lang {
        Lang::En => "On this page",
        Lang::Fr => "Sur cette page",
    };
    // Le corps est une boîte à part pour pouvoir coller : sur un grand écran, le
    // sommaire est une colonne aussi haute que la page, et c'est son contenu
    // qui reste sous l'en-tête pendant qu'on lit.
    nav()
        .class("sommaire")
        .attr("aria-label", nom)
        .child(
            div()
                .class("sommaire-corps")
                .child(p().class("sommaire-titre").text(nom))
                .child(
                    ol().children(
                        titres
                            .into_iter()
                            .map(|t| li().child(a().href(format!("#{}", slug(t))).text(t))),
                    ),
                ),
        )
        .into()
}

/// Une page écrite : son titre, son accroche, son sommaire et ses blocs.
pub fn doc_page(doc: &Doc, lang: Lang) -> Node {
    article()
        .class("doc")
        .child(
            div()
                .class("wrap")
                .child(
                    header()
                        .class("doc-head")
                        .child(h1().child(mots(doc.title)))
                        .child(p().class("lede").text(doc.lede)),
                )
                .child(sommaire(doc, lang))
                .children(doc.blocks.iter().map(rendre)),
        )
        .into()
}

#[cfg(test)]
mod tests {
    use super::slug;

    /// Les ancres que le site publie réellement, et le repli des accents que la
    /// version TypeScript obtenait par décomposition NFD.
    #[test]
    fn les_ancres_se_derivent_du_titre() {
        assert_eq!(slug("Agent protocol"), "agent-protocol");
        assert_eq!(slug("Feuille de route"), "feuille-de-route");
        assert_eq!(slug("Vie privée"), "vie-privee");
        assert_eq!(slug("Hors ligne"), "hors-ligne");
        assert_eq!(slug("Thème — réglages"), "theme-reglages");
        // Ni tiret de tête ni tiret de queue, et jamais deux de suite.
        assert_eq!(slug("  À propos ?  "), "a-propos");
        assert_eq!(slug("x86-64 / arm64"), "x86-64-arm64");
    }
}
