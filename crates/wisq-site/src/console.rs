//! Ce que la console de l'invité devient à l'écran : des octets de l'UART en
//! texte qu'un `<pre>` peut montrer.
//!
//! **Un terminal minimal, et c'est assez.** Le noyau et le shell de buildroot
//! écrivent du texte, des fins de ligne `\r\n`, un retour arrière pour effacer
//! un caractère, et quelques séquences ANSI (couleurs, effacement de ligne). Un
//! émulateur VT100 complet serait plus gros que la machine ; ici les séquences
//! sont lues et retirées, le retour arrière efface, et le reste s'ajoute.
//!
//! Pur, sans DOM : la page le nourrit, les tests aussi.

/// Au-delà, le plus ancien part : un invité bavard ne doit pas faire grossir
/// sans fin un nœud de texte que le navigateur remet en page à chaque image.
pub const CAPACITE: usize = 64 * 1024;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
enum Etat {
    #[default]
    Texte,
    /// Après ESC.
    Echap,
    /// Dans `ESC [ … final`.
    Csi,
}

#[derive(Default, Debug)]
pub struct Console {
    octets: Vec<u8>,
    etat: Etat,
}

impl Console {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn ecrire(&mut self, entree: &[u8]) {
        for &b in entree {
            match self.etat {
                Etat::Echap => {
                    self.etat = if b == b'[' { Etat::Csi } else { Etat::Texte };
                }
                Etat::Csi => {
                    if (0x40..=0x7e).contains(&b) {
                        self.etat = Etat::Texte;
                    }
                }
                Etat::Texte => match b {
                    0x1b => self.etat = Etat::Echap,
                    b'\n' | b'\t' => self.octets.push(b),
                    // Le retour arrière efface un caractère entier, pas un
                    // octet, et jamais au-delà du début de la ligne.
                    0x08 | 0x7f => self.effacer(),
                    // `\r` précède `\n` dans tout ce que l'invité écrit : le
                    // garder doublerait chaque fin de ligne à l'écran.
                    b if b < 0x20 => {}
                    b => self.octets.push(b),
                },
            }
        }
        self.borner();
    }

    fn effacer(&mut self) {
        while let Some(&dernier) = self.octets.last() {
            if dernier == b'\n' {
                return;
            }
            self.octets.pop();
            // Un octet de continuation UTF-8 : le caractère n'est pas fini.
            if dernier & 0xc0 != 0x80 {
                return;
            }
        }
    }

    fn borner(&mut self) {
        if self.octets.len() <= CAPACITE {
            return;
        }
        let trop = self.octets.len() - CAPACITE;
        // Couper à une fin de ligne, pour ne jamais laisser la moitié d'un
        // caractère ou d'une ligne en tête.
        let coupe = self.octets[trop..]
            .iter()
            .position(|&b| b == b'\n')
            .map_or(trop, |i| trop + i + 1);
        self.octets.drain(..coupe);
    }

    pub fn texte(&self) -> String {
        String::from_utf8_lossy(&self.octets).into_owned()
    }

    pub fn vider(&mut self) {
        self.octets.clear();
        self.etat = Etat::Texte;
    }
}

/// Une touche du clavier en octets pour l'UART, ou `None` si elle ne dit rien
/// à un terminal (une touche de modification seule, une touche de fonction).
pub fn touche(cle: &str, ctrl: bool) -> Option<Vec<u8>> {
    let octets: &[u8] = match cle {
        "Enter" => b"\r",
        "Backspace" => b"\x7f",
        "Tab" => b"\t",
        "Escape" => b"\x1b",
        "ArrowUp" => b"\x1b[A",
        "ArrowDown" => b"\x1b[B",
        "ArrowRight" => b"\x1b[C",
        "ArrowLeft" => b"\x1b[D",
        _ => {
            let mut caracteres = cle.chars();
            let c = caracteres.next()?;
            if caracteres.next().is_some() {
                return None;
            }
            if ctrl {
                let c = c.to_ascii_lowercase();
                return c.is_ascii_lowercase().then(|| vec![c as u8 & 0x1f]);
            }
            return Some(cle.as_bytes().to_vec());
        }
    };
    Some(octets.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn les_sequences_ansi_sont_retirees_et_les_fins_de_ligne_gardees() {
        let mut c = Console::new();
        c.ecrire(b"\x1b[1;32mroot\x1b[0m@buildroot:~# ls\r\nbin  etc\r\n");
        assert_eq!(c.texte(), "root@buildroot:~# ls\nbin  etc\n");
    }

    #[test]
    fn le_retour_arriere_efface_un_caractere_entier_et_pas_la_ligne_d_avant() {
        let mut c = Console::new();
        c.ecrire("a\né".as_bytes());
        c.ecrire(b"\x08");
        assert_eq!(c.texte(), "a\n");
        c.ecrire(b"\x08\x08");
        assert_eq!(c.texte(), "a\n");
    }

    #[test]
    fn une_sequence_coupee_entre_deux_ecritures_est_retiree_quand_meme() {
        let mut c = Console::new();
        c.ecrire(b"x\x1b[");
        c.ecrire(b"2Ky");
        assert_eq!(c.texte(), "xy");
    }

    #[test]
    fn la_console_garde_les_dernieres_lignes() {
        let mut c = Console::new();
        let ligne = [b'x'; 99];
        for _ in 0..1000 {
            c.ecrire(&ligne);
            c.ecrire(b"\n");
        }
        let texte = c.texte();
        assert!(texte.len() <= CAPACITE);
        assert!(texte.starts_with('x') && texte.ends_with('\n'));
    }

    #[test]
    fn les_touches_deviennent_ce_qu_un_terminal_envoie() {
        assert_eq!(touche("Enter", false), Some(b"\r".to_vec()));
        assert_eq!(touche("c", true), Some(vec![3]));
        assert_eq!(touche("é", false), Some("é".as_bytes().to_vec()));
        assert_eq!(touche("ArrowUp", false), Some(b"\x1b[A".to_vec()));
        assert_eq!(touche("Shift", false), None);
        assert_eq!(touche("1", true), None);
    }
}
