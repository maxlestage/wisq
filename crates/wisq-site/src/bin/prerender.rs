//! Rend en HTML les pages que ce crate porte, pour que la construction les
//! écrive sur le disque.
//!
//! C'est l'équivalent exact de ce que `site/build.tsx` faisait avec
//! `renderToString` de React : le balisage arrive dans la première réponse, un
//! moteur de recherche voit une vraie page, et le WebAssembly n'est nécessaire
//! qu'aux comportements.
//!
//! **Un seul processus pour toutes les pages.** La construction l'appelle une
//! fois et lit un objet JSON — `"<langue>/<route>"` vers le balisage — plutôt
//! que de lancer vingt processus pour vingt pages.
//!
//! **Le JSON est écrit à la main**, comme celui du démon, et pour la même
//! raison : ajouter serde et son dérive à ce crate les ferait entrer dans
//! l'arbre de dépendances du wasm, où chaque octet est compté. L'échappement
//! couvre ce que la spécification JSON exige d'échapper, et un test le vérifie
//! sur le balisage réel plutôt que sur un exemple choisi.

use wisq_site::content::Lang;
use wisq_site::pages::PORTEES;
use wisq_site::{Page, PageProps};
use yew::ServerRenderer;

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

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let mut entrees: Vec<String> = Vec::new();
    for lang in Lang::ALL {
        for route in PORTEES {
            let rendu = ServerRenderer::<Page>::with_props(move || PageProps {
                route: *route,
                lang,
            })
            .render()
            .await;
            // La clé est l'adresse telle que la construction la nomme, langue
            // d'abord : c'est l'ordre dans lequel `build.tsx` boucle.
            let cle = format!("{}/{}", lang.code(), route.slug());
            entrees.push(format!("{}:{}", json(&cle), json(&rendu)));
        }
    }
    println!("{{{}}}", entrees.join(","));
}

#[cfg(test)]
mod tests {
    use super::json;

    #[test]
    fn l_echappement_couvre_ce_que_json_exige() {
        assert_eq!(json(r#"a"b"#), r#""a\"b""#);
        assert_eq!(json(r"a\b"), r#""a\\b""#);
        assert_eq!(json("a\nb"), r#""a\nb""#);
        assert_eq!(json("a\u{1}b"), r#""a\u0001b""#);
        // Ce qui n'a pas à être touché : le balisage, et l'UTF-8 tel quel.
        assert_eq!(json("<p>é & ▚</p>"), "\"<p>é & ▚</p>\"");
    }
}
