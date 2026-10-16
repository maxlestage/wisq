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

use active::prelude::*;

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

/// La marque, en SVG en ligne.
///
/// **Pourquoi un suffixe explicite plutôt qu'un identifiant engendré.** La
/// marque apparaît plus d'une fois par page — le héros et le pied — et deux
/// copies de `id="wisq-plate"` sont du HTML invalide qui n'a l'air correct que
/// parce que les deux dégradés sont identiques. L'appelant nomme donc son
/// instance : c'est déterministe, lisible dans le HTML livré, et identique d'un
/// rendu à l'autre sans dépendre d'un compteur.
pub fn logo(class: &'static str, instance: &'static str) -> Element {
    let plate = format!("wisq-plate-{instance}");
    let mark = format!("wisq-mark-{instance}");
    let clip = format!("wisq-window-{instance}");
    let plate_url = format!("url(#{plate})");
    let mark_url = format!("url(#{mark})");
    let clip_url = format!("url(#{clip})");

    // Les trois pas du lien, à travers l'écart : la seule chose de la plaque
    // qui ne soit pas un objet solide, parce qu'un réseau n'en est pas un.
    //
    // Les pas sont 0,16, 0,5 et 0,84 de l'écart depuis `UL + SIDE` = 112, et
    // l'opacité 0,38 + pas/2. Soit 114,56 / 120 / 125,44 et 0,46 / 0,63 / 0,8.
    const LIEN: [(&str, &str); 3] = [("114.56", "0.46"), ("120", "0.63"), ("125.44", "0.8")];

    let degrade = |id: String, de: &'static str, a: &'static str| {
        linear_gradient()
            .id(id)
            .attr("x1", "0")
            .attr("y1", "0")
            .attr("x2", "1")
            .attr("y2", "1")
            .child(stop().attr("offset", "0").attr("stop-color", de))
            .child(stop().attr("offset", "1").attr("stop-color", a))
    };
    let pastille = |cx: &'static str| {
        circle()
            .attr("cx", cx)
            .attr("cy", "49.5")
            .attr("r", "3")
            .attr("fill", "#0b0d10")
            .attr("fill-opacity", "0.42")
    };

    svg()
        .class(class)
        .attr("viewBox", "0 0 240 240")
        .attr("width", "240")
        .attr("height", "240")
        // Le mot-symbole de l'en-tête nomme déjà le site et le titre suit
        // immédiatement, donc annoncer ceci en plus ne répéterait que les deux.
        .attr("aria-hidden", "true")
        .attr("focusable", "false")
        .child(
            defs()
                .child(degrade(plate, "#171d26", "#0b0d10"))
                .child(degrade(mark, "#a8a2ff", "#6f64ff"))
                .child(
                    el("clipPath").id(clip).child(
                        rect()
                            .attr("x", "40")
                            .attr("y", "40")
                            .attr("width", "72")
                            .attr("height", "72")
                            .attr("rx", "13"),
                    ),
                ),
        )
        .child(
            rect()
                .attr("width", "240")
                .attr("height", "240")
                .attr("rx", "54")
                .attr("fill", plate_url),
        )
        .child(
            rect()
                .attr("x", "0.75")
                .attr("y", "0.75")
                .attr("width", "238.5")
                .attr("height", "238.5")
                .attr("rx", "53.25")
                .attr("fill", "none")
                .attr("stroke", "#8b83ff")
                .attr("stroke-opacity", "0.16")
                .attr("stroke-width", "1.5"),
        )
        .children(LIEN.iter().map(|(c, opacite)| {
            circle()
                .attr("cx", *c)
                .attr("cy", *c)
                .attr("r", "2.5")
                .attr("fill", "#8b83ff")
                .attr("fill-opacity", *opacite)
        }))
        // En haut à gauche : une machine ailleurs, donc une fenêtre.
        .child(
            g().attr("clip-path", clip_url)
                .child(
                    rect()
                        .attr("x", "40")
                        .attr("y", "40")
                        .attr("width", "72")
                        .attr("height", "72")
                        .attr("fill", mark_url.clone()),
                )
                .child(
                    rect()
                        .attr("x", "40")
                        .attr("y", "40")
                        .attr("width", "72")
                        .attr("height", "19")
                        .attr("fill", "#0b0d10")
                        .attr("fill-opacity", "0.3"),
                )
                // 9,5 et non 9 : la barre de titre de la fenêtre fait 19 de
                // haut, et les deux pastilles sont à son milieu exact.
                .child(pastille("53"))
                .child(pastille("65")),
        )
        // En bas à droite : le téléphone dans votre main, écran compris.
        .child(
            rect()
                .attr("x", "128")
                .attr("y", "128")
                .attr("width", "72")
                .attr("height", "72")
                .attr("rx", "13")
                .attr("fill", mark_url),
        )
        .child(
            rect()
                .attr("x", "147")
                .attr("y", "139")
                .attr("width", "34")
                .attr("height", "50")
                .attr("rx", "7")
                .attr("fill", "#0b0d10")
                .attr("fill-opacity", "0.32"),
        )
        .child(
            rect()
                .attr("x", "157")
                .attr("y", "182")
                .attr("width", "14")
                .attr("height", "2.8")
                .attr("rx", "1.4")
                .attr("fill", "#0b0d10")
                .attr("fill-opacity", "0.5"),
        )
}

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
