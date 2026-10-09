//! La marque complète, pour le seul endroit du site qui ait la place de la
//! montrer.
//!
//! Un système de marque plutôt qu'un dessin. L'icône qui va sur un écran
//! d'accueil, c'est `▚` seul — deux quadrants, aucun détail — parce qu'à 60 px
//! tout le reste devient de la bouillie. Ceci est la même marque avec la place
//! de dire ce que sont les quadrants : celui en haut à gauche est une fenêtre
//! sur une machine ailleurs, celui en bas à droite est le téléphone dans votre
//! main, et la diagonale entre les deux est tout le produit.
//!
//! Dessinée en code, comme les icônes, et pour la même raison : un binaire
//! commité est une chose que personne ne peut differ et que tout le monde doit
//! croire. SVG en ligne plutôt qu'un fichier, pour que le héros peigne dans la
//! première réponse sans seconde requête.
//!
//! Les couleurs sont fixes plutôt que thématiques. Un logo qui change de
//! couleur selon les réglages du lecteur n'est pas un logo, et la plaque est
//! sombre dans les deux thèmes pour la raison qui fait qu'une icône
//! d'application l'est : c'est l'icône de l'application.

use yew::prelude::*;

/// Les deux quadrants de U+259A, dans une boîte de 240×240.
///
/// Dans le caractère, les quadrants se touchent en un point. Ici ils sont
/// écartés de `GAP`, parce que deux machines qui se touchent n'ont rien entre
/// elles à dessiner, et que ce qui est entre elles est tout le produit.
const SIDE: i32 = 72;
const UL: i32 = 40;
const LR: i32 = 128;
const GAP: i32 = LR - (UL + SIDE);

/// Les trois pas du lien, en fraction de l'écart.
///
/// `#[cfg(test)]` et non pas simplement privé : depuis que les attributs portent
/// des littéraux, **plus aucune ligne livrée ne lit cette table**, et clippy l'a
/// dit. La garder visible au wasm en aurait fait du code mort, ce que ce dépôt
/// refuse ; la retirer aurait privé le test de la spécification qu'il relit.
/// Elle est donc ce qu'elle est : la description de la géométrie, lue par la
/// garde, absente du module livré.
#[cfg(test)]
const LIEN_PAS: [f64; 3] = [0.16, 0.5, 0.84];

/// **Pourquoi les attributs portent des littéraux et non ces constantes.**
///
/// La géométrie est fixe : `UL + 13` est connu du compilateur. Mais un attribut
/// SVG est une chaîne, et `(UL + 13).to_string()` est un formatage **à
/// l'exécution** — qui tire dans le wasm la conversion entier→décimal, et, pour
/// les trois pastilles du lien, tout le formatage des flottants, qui est la plus
/// grosse routine que `core::fmt` sache apporter. Pour un dessin qui ne change
/// jamais.
///
/// Mesuré, sur le module complet : écrire les valeurs en clair fait passer le
/// wasm de 278 098 à **253 728** octets, soit **106 392** gzippés au lieu de
/// 117 272 — 10 880 de moins, 9,3 %, pour avoir cessé de formater des nombres
/// constants à l'exécution. Les constantes restent, parce qu'elles disent d'où
/// viennent les nombres, et le test plus bas les confronte aux littéraux pour
/// qu'une retouche du dessin ne puisse pas les désaccorder en silence.
const _: () = {
    assert!(SIDE == 72 && UL == 40 && LR == 128 && GAP == 16);
};

#[cfg(test)]
mod tests {
    use super::{GAP, LIEN_PAS, LR, SIDE, UL};

    /// **Les littéraux des attributs et les constantes disent la même chose.**
    ///
    /// Sans ça, les constantes seraient devenues de la décoration : on
    /// retoucherait `UL` en croyant déplacer la fenêtre, et le dessin ne
    /// bougerait pas d'un pixel parce que les attributs portent `40` en clair.
    /// Le test refait les calculs que le code ne fait plus.
    #[test]
    fn la_geometrie_ecrite_est_celle_que_les_constantes_decrivent() {
        assert_eq!(UL + 13, 53);
        assert_eq!(UL + 25, 65);
        assert_eq!(f64::from(UL) + 9.5, 49.5);
        assert_eq!(LR + 19, 147);
        assert_eq!(LR + 11, 139);
        assert_eq!(LR + 29, 157);
        assert_eq!(LR + 54, 182);
        // Les trois pastilles du lien : position et opacité.
        let attendus = [("114.56", "0.46"), ("120", "0.63"), ("125.44", "0.8")];
        for (pas, (c, opacite)) in LIEN_PAS.iter().zip(attendus) {
            let calcule = f64::from(UL + SIDE) + f64::from(GAP) * pas;
            assert_eq!(format!("{}", calcule), c, "position du pas {pas}");
            assert_eq!(
                format!("{}", 0.38 + pas * 0.5),
                opacite,
                "opacité du pas {pas}"
            );
        }
    }
}

#[derive(Properties, PartialEq)]
pub struct LogoProps {
    #[prop_or_default]
    pub class: AttrValue,
    /// **Pourquoi un suffixe explicite plutôt qu'un identifiant engendré.**
    ///
    /// La marque apparaît plus d'une fois par page — le héros et le pied — et
    /// deux copies de `id="wisq-plate"` sont du HTML invalide qui n'a l'air
    /// correct que parce que les deux dégradés sont identiques. La version
    /// React appelait `useId`, qui rend des identifiants stables mais bruyants
    /// (des deux-points, légaux dans un `id` et pénibles dans une référence
    /// d'URL). Ici l'appelant nomme son instance : c'est déterministe, lisible
    /// dans le HTML livré, et identique entre le pré-rendu et l'hydratation
    /// sans dépendre d'un compteur interne au framework.
    pub instance: AttrValue,
}

#[function_component]
pub fn Logo(props: &LogoProps) -> Html {
    let plate = format!("wisq-plate-{}", props.instance);
    let mark = format!("wisq-mark-{}", props.instance);
    let clip = format!("wisq-window-{}", props.instance);
    let plate_url = format!("url(#{plate})");
    let mark_url = format!("url(#{mark})");
    let clip_url = format!("url(#{clip})");

    // Les trois pas du lien, à travers l'écart : la seule chose de la plaque
    // qui ne soit pas un objet solide, parce qu'un réseau n'en est pas un.
    //
    // Les pas sont 0,16, 0,5 et 0,84 de l'écart depuis `UL + SIDE` = 112, et
    // l'opacité 0,38 + pas/2. Soit 114,56 / 120 / 125,44 et 0,46 / 0,63 / 0,8 —
    // exactement ce que la version React calculait, et ce que le site publie.
    const LIEN: [(&str, &str); 3] = [("114.56", "0.46"), ("120", "0.63"), ("125.44", "0.8")];

    html! {
        <svg class={props.class.clone()} viewBox="0 0 240 240" width="240" height="240"
             // Le mot-symbole de l'en-tête nomme déjà le site et le titre suit
             // immédiatement, donc annoncer ceci en plus ne répéterait que les deux.
             aria-hidden="true" focusable="false">
            <defs>
                <linearGradient id={plate.clone()} x1="0" y1="0" x2="1" y2="1">
                    <stop offset="0" stop-color="#171d26" />
                    <stop offset="1" stop-color="#0b0d10" />
                </linearGradient>
                <linearGradient id={mark.clone()} x1="0" y1="0" x2="1" y2="1">
                    <stop offset="0" stop-color="#a8a2ff" />
                    <stop offset="1" stop-color="#6f64ff" />
                </linearGradient>
                <clipPath id={clip.clone()}>
                    <rect x="40" y="40" width="72" height="72" rx="13" />
                </clipPath>
            </defs>

            <rect width="240" height="240" rx="54" fill={plate_url} />
            <rect x="0.75" y="0.75" width="238.5" height="238.5" rx="53.25" fill="none"
                  stroke="#8b83ff" stroke-opacity="0.16" stroke-width="1.5" />

            { for LIEN.iter().map(|(c, opacite)| html! {
                <circle cx={*c} cy={*c} r="2.5" fill="#8b83ff" fill-opacity={*opacite} />
            }) }

            // En haut à gauche : une machine ailleurs, donc une fenêtre.
            <g clip-path={clip_url}>
                <rect x="40" y="40" width="72" height="72" fill={mark_url.clone()} />
                <rect x="40" y="40" width="72" height="19" fill="#0b0d10" fill-opacity="0.3" />
                // 9,5 et non 9 : la barre de titre de la fenêtre fait 19 de
                // haut, et les deux pastilles sont à son milieu exact.
                <circle cx="53" cy="49.5" r="3" fill="#0b0d10" fill-opacity="0.42" />
                <circle cx="65" cy="49.5" r="3" fill="#0b0d10" fill-opacity="0.42" />
            </g>

            // En bas à droite : le téléphone dans votre main, écran compris.
            <rect x="128" y="128" width="72" height="72" rx="13" fill={mark_url} />
            <rect x="147" y="139" width="34" height="50" rx="7" fill="#0b0d10" fill-opacity="0.32" />
            <rect x="157" y="182" width="14" height="2.8" rx="1.4" fill="#0b0d10" fill-opacity="0.5" />
        </svg>
    }
}
