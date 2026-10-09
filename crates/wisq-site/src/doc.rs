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

use yew::prelude::*;

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

fn rendre(bloc: &Block) -> Html {
    match bloc {
        Block::P(texte) => html! { <p>{ *texte }</p> },

        // Chaque section est adressable, pour qu'un lien vers le milieu du guide
        // arrive là où il le dit.
        Block::H2(texte) => {
            let id = slug(texte);
            html! {
                <h2 id={id.clone()}>
                    <a class="anchor" href={format!("#{id}")} aria-label={*texte}>{ *texte }</a>
                </h2>
            }
        }

        Block::H3(texte) => html! { <h3 id={slug(texte)}>{ *texte }</h3> },

        Block::Ul(items) => html! {
            <ul class="doc-list">
                { for items.iter().map(|i| html! { <li>{ *i }</li> }) }
            </ul>
        },

        Block::Ol(items) => html! {
            <ol class="doc-list doc-steps">
                { for items.iter().map(|i| html! { <li>{ *i }</li> }) }
            </ol>
        },

        // Le code arrive ligne par ligne, comme dans un terminal : chaque ligne
        // est sa propre boîte, avec son rang. Les fins de ligne restent de
        // vrais nœuds de texte **entre** les boîtes, donc ce qu'on sélectionne
        // et copie est le texte exact, et sans le module le bloc est le même
        // `pre` qu'avant.
        Block::Code { code, caption } => html! {
            <figure class="doc-code">
                { caption.map(|c| html! { <figcaption>{ c }</figcaption> }).unwrap_or_default() }
                <pre><code>{ lignes(code) }</code></pre>
            </figure>
        },

        Block::Note { tone, text } => html! {
            <aside class={format!("doc-note doc-note-{}", tone.slug())}>
                <p>{ *text }</p>
            </aside>
        },

        Block::Table { columns, rows } => html! {
            <div class="table-scroll">
                <table>
                    <thead>
                        <tr>
                            { for columns.iter().map(|c| html! { <th scope="col">{ *c }</th> }) }
                        </tr>
                    </thead>
                    <tbody>
                        { for rows.iter().map(|ligne| html! {
                            <tr>{ for ligne.iter().map(|cell| html! { <td>{ *cell }</td> }) }</tr>
                        }) }
                    </tbody>
                </table>
            </div>
        },

        Block::Dl(items) => html! {
            <dl class="doc-dl">
                { for items.iter().map(|i| html! {
                    <div><dt>{ i.term }</dt><dd>{ i.detail }</dd></div>
                }) }
            </dl>
        },
    }
}

/// Les lignes d'un bloc de code, chacune dans sa boîte.
fn lignes(code: &'static str) -> Html {
    let total = code.split('\n').count();
    html! {
        { for code.split('\n').enumerate().map(|(i, ligne)| html! {
            <>
                <span class="ligne" style={format!("--l:{i}")}>{ ligne }</span>
                { if i + 1 < total { html! { "\n" } } else { html! {} } }
            </>
        }) }
    }
}

/// Une phrase, mot par mot : le titre du héros et celui de chaque page écrite.
///
/// **Chaque mot est un masque et son contenu**, pour que l'entrée soit celle de
/// la référence : le mot monte depuis sous sa ligne au lieu d'apparaître. Le
/// rang part dans `--i`, dont la feuille de style fait un retard. Les espaces
/// restent de vrais nœuds de texte entre les mots : un titre se lit, se
/// sélectionne et se copie avec ses espaces, et un lecteur d'écran lit une
/// suite de `span` en ligne comme la phrase qu'elle est.
pub(crate) fn mots(phrase: &'static str) -> Html {
    let total = phrase.split(' ').count();
    html! {
        { for phrase.split(' ').enumerate().map(|(i, mot)| html! {
            <>
                <span class="mot" style={format!("--i:{i}")}><span>{ mot }</span></span>
                { if i + 1 < total { html! { " " } } else { html! {} } }
            </>
        }) }
    }
}

/// À partir de combien de sections une page a un sommaire. En dessous, la page
/// tient sur un écran ou deux, et un sommaire de deux lignes serait plus long à
/// lire que ce qu'il résume.
const SECTIONS_MIN: usize = 3;

/// Le sommaire d'une page écrite : ses `h2`, dans l'ordre, chacun vers son
/// ancre. Rendu à la construction comme le reste, donc il marche sans le
/// module ; le module ne fait que suivre la section lue.
fn sommaire(doc: &Doc, lang: Lang) -> Html {
    let titres: Vec<&'static str> = doc
        .blocks
        .iter()
        .filter_map(|b| match b {
            Block::H2(t) => Some(*t),
            _ => None,
        })
        .collect();
    if titres.len() < SECTIONS_MIN {
        return html! {};
    }
    let nom = match lang {
        Lang::En => "On this page",
        Lang::Fr => "Sur cette page",
    };
    html! {
        // Le corps est une boîte à part pour pouvoir coller : sur un grand
        // écran, le sommaire est une colonne aussi haute que la page, et c'est
        // son contenu qui reste sous l'en-tête pendant qu'on lit.
        <nav class="sommaire" aria-label={nom}>
            <div class="sommaire-corps">
                <p class="sommaire-titre">{ nom }</p>
                <ol>
                    { for titres.into_iter().map(|t| html! {
                        <li><a href={format!("#{}", slug(t))}>{ t }</a></li>
                    }) }
                </ol>
            </div>
        </nav>
    }
}

#[derive(Properties, PartialEq)]
pub struct DocPageProps {
    pub doc: Doc,
    pub lang: Lang,
}

#[function_component]
pub fn DocPage(props: &DocPageProps) -> Html {
    html! {
        <article class="doc">
            <div class="wrap">
                <header class="doc-head">
                    <h1>{ mots(props.doc.title) }</h1>
                    <p class="lede">{ props.doc.lede }</p>
                </header>
                { sommaire(&props.doc, props.lang) }
                { for props.doc.blocks.iter().map(rendre) }
            </div>
        </article>
    }
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
