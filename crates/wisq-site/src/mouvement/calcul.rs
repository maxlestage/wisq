//! Le calcul du mouvement, sans navigateur.
//!
//! **Toujours compilé, et c'est pour les tests.** Le reste de `mouvement` n'existe
//! que sous `hydrate`, et `cargo test --release` — ce que lance la CI — construit
//! les fonctionnalités par défaut. Ce qui se calcule sans fenêtre vit donc ici :
//! les nombres écrits sans `core::fmt`, les courbes, et la géométrie de la marque
//! que la poussière rejoint. C'est ce qui peut être faux sans que rien ne le
//! montre, et c'est donc ce qui doit être tenu.

/// Un entier en texte, sans `core::fmt`.
///
/// **Ce n'est pas de la coquetterie, c'est du poids.** Le logo a appris au
/// module que formater des nombres à l'exécution tire dans le wasm la
/// machinerie de `core::fmt` — 10 880 octets la première fois. Le mouvement
/// pose des dizaines de valeurs par image ; il les pose en entiers (pixels,
/// millièmes), et les écrit à la main.
pub fn entier(n: i32) -> String {
    let mut chiffres = [0u8; 11];
    let mut i = chiffres.len();
    let negatif = n < 0;
    let mut reste = n.unsigned_abs();
    loop {
        i -= 1;
        chiffres[i] = b'0' + (reste % 10) as u8;
        reste /= 10;
        if reste == 0 {
            break;
        }
    }
    let mut sortie = String::with_capacity(12);
    if negatif {
        sortie.push('-');
    }
    for c in &chiffres[i..] {
        sortie.push(char::from(*c));
    }
    sortie
}

/// Une fraction de 0 à 1, en millièmes : `calc(var(--x) / 1000)` côté CSS.
pub fn milliemes(x: f64) -> String {
    entier((borne(x, 0.0, 1.0) * 1000.0).round() as i32)
}

pub fn borne(x: f64, bas: f64, haut: f64) -> f64 {
    x.max(bas).min(haut)
}

/// Vite au début, lent à la fin : la valeur se lit avant de s'arrêter.
pub fn sortie_cubique(t: f64) -> f64 {
    let u = 1.0 - borne(t, 0.0, 1.0);
    1.0 - u * u * u
}

/// Une rampe de 0 à 1 entre deux instants de la course.
pub fn rampe(p: f64, (debut, fin): (f64, f64)) -> f64 {
    borne((p - debut) / (fin - debut), 0.0, 1.0)
}

// La géométrie de `crate::logo`, et rien d'autre : un quadrant fait 72 de côté,
// arrondi de 13 ; la fenêtre est à 40, le téléphone à 128 ; l'écran du
// téléphone est un trou arrondi de 7 entre 147 et 181 sur 139 à 189 ; les trois
// pas du lien sont des disques de 2,5 sur la diagonale. Le test du bas confronte
// ces nombres à ceux que `logo.rs` écrit.
pub const COTE: f64 = 72.0;
pub const RAYON: f64 = 13.0;
pub const FENETRE: f64 = 40.0;
pub const TELEPHONE: f64 = 128.0;
pub const ECRAN: (f64, f64, f64, f64, f64) = (147.0, 139.0, 34.0, 50.0, 7.0);
pub const PAS: [f64; 3] = [114.56, 120.0, 125.44];

pub fn dans_carre_arrondi(x: f64, y: f64, gauche: f64, haut: f64, l: f64, h: f64, r: f64) -> bool {
    if x < gauche || y < haut || x > gauche + l || y > haut + h {
        return false;
    }
    // La distance au coin intérieur le plus proche, seulement dans les coins.
    let qx = (x - gauche).min(gauche + l - x);
    let qy = (y - haut).min(haut + h - y);
    if qx >= r || qy >= r {
        return true;
    }
    let (dx, dy) = (r - qx, r - qy);
    dx * dx + dy * dy <= r * r
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **La poussière se forme sur le dessin du SVG, pas sur un dessin voisin.**
    /// Les nombres d'ici et ceux que `logo.rs` écrit en littéraux disent la
    /// même chose ; sinon, la marque apparaîtrait à côté de la poussière qui
    /// vient de la former.
    #[test]
    fn la_geometrie_est_celle_du_logo() {
        let svg = include_str!("../logo.rs");
        let attendu = [
            format!(
                r#"<rect x="{FENETRE}" y="{FENETRE}" width="{COTE}" height="{COTE}" rx="{RAYON}" />"#
            ),
            format!(
                r#"<rect x="{TELEPHONE}" y="{TELEPHONE}" width="{COTE}" height="{COTE}" rx="{RAYON}""#
            ),
            format!(
                r#"<rect x="{}" y="{}" width="{}" height="{}" rx="{}""#,
                ECRAN.0, ECRAN.1, ECRAN.2, ECRAN.3, ECRAN.4
            ),
        ];
        for a in attendu {
            assert!(svg.contains(&a), "logo.rs ne dessine pas {a}");
        }
        for c in PAS {
            assert!(
                svg.contains(&format!("(\"{c}\"")),
                "logo.rs n'a pas le pas {c}"
            );
        }
    }

    #[test]
    fn les_coins_sont_arrondis() {
        // Le coin exact est dehors, le centre est dedans, le milieu d'un bord
        // aussi.
        assert!(!dans_carre_arrondi(
            40.0, 40.0, 40.0, 40.0, 72.0, 72.0, 13.0
        ));
        assert!(dans_carre_arrondi(76.0, 76.0, 40.0, 40.0, 72.0, 72.0, 13.0));
        assert!(dans_carre_arrondi(40.5, 76.0, 40.0, 40.0, 72.0, 72.0, 13.0));
    }

    #[test]
    fn les_entiers_s_ecrivent_sans_fmt() {
        for n in [0, 7, 10, 999, -42, 1000, i32::MAX, i32::MIN] {
            assert_eq!(entier(n), n.to_string());
        }
        assert_eq!(milliemes(0.5234), "523");
        assert_eq!(milliemes(-1.0), "0");
        assert_eq!(milliemes(2.0), "1000");
        assert_eq!(sortie_cubique(1.0), 1.0);
        assert_eq!(sortie_cubique(0.0), 0.0);
        assert!((rampe(0.56, (0.5, 0.62)) - 0.5).abs() < 1e-9);
        assert_eq!(rampe(0.1, (0.5, 0.62)), 0.0);
        assert_eq!(rampe(0.9, (0.5, 0.62)), 1.0);
    }
}
