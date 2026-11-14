//! **La carte de la machine PC, dans la page** : ce qui répond aux ports
//! d'E/S que ni les deux 8259, ni le 8254, ni le 16550 de `web/host.js` ne
//! prennent, et les lignes d'interruption que ces périphériques tiennent.
//!
//! **Pourquoi en Rust, et pourquoi ici.** Un port est un appel synchrone :
//! `env.in` est appelé depuis le module d'une région et doit rendre sa valeur
//! tout de suite. Swift n'est joignable que par message, donc aucun registre
//! ne peut vivre de son côté ; tout ce qui lit ou écrit un registre vit dans
//! la page. La carte du 14 novembre (§ 4.3) a tranché pour du Rust compilé en
//! wasm32 à côté de l'émetteur, dans le même module : les modèles se testent
//! en natif sans moteur JavaScript, se portent un pour un depuis le cœur
//! Swift, et se répartissent entre agents un fichier par périphérique, sans
//! que personne n'écrive dans `host.js`.
//!
//! **La carte est celle du cœur Swift, exactement** : mêmes ports, mêmes
//! lignes, mêmes réponses (`X86CoreDispatch.swift`, `portWrite` et
//! `portRead`). Un instantané pris par un cœur pourra un jour être repris par
//! l'autre seulement à ce prix.
//!
//! | ports | périphérique | ligne |
//! | --- | --- | --- |
//! | `0x60`, `0x64` | i8042, clavier et souris ([`i8042`]) | 1 et 12 |
//! | `0x70`, `0x71` | CMOS, horloge ([`cmos`]) | aucune |
//!
//! **Les lignes sont à niveau.** [`Carte::lignes`] dit, à l'instant, quelles
//! lignes ses périphériques tiennent levées, et [`Carte::tenues`] lesquelles
//! elle tient tout court : la boucle hôte recopie les premières dans les
//! registres de requête de ses 8259 et efface le reste des secondes, à chaque
//! tour — ce que `serviceInterrupts` fait du côté Swift. Une source qui n'est
//! pas un registre (une fin de lecture disque venue de Swift, un jour) lève et
//! baisse la sienne par [`Carte::lever`] et [`Carte::baisser`].
//!
//! **La RAM de l'invité** n'est pas dans la mémoire de ce module : elle est
//! dans la `WebAssembly.Memory` de la boucle hôte. Un périphérique qui la lit
//! (une file virtio, demain) passe donc par le trait [`Ram`], que chaque appel
//! de port reçoit. Aucun des deux périphériques de cette tranche ne la lit.

pub mod cmos;
pub mod i8042;
mod porte;

use cmos::Cmos;
use i8042::{CodeTouche, I8042, LIGNE_CLAVIER, LIGNE_SOURIS, PORT_COMMANDE, PORT_DONNEES};

/// **La RAM de l'invité, vue d'un périphérique**, par adresse physique.
///
/// Rend `false`, sans rien toucher, quand la plage ne tient pas entière dans
/// la RAM : un périphérique qui suit un descripteur mal formé doit pouvoir le
/// refuser plutôt que lire à côté.
pub trait Ram {
    fn lire(&self, adresse: u64, vers: &mut [u8]) -> bool;
    fn ecrire(&mut self, adresse: u64, depuis: &[u8]) -> bool;
}

/// **Une RAM en un seul bloc**, à partir de l'adresse zéro : celle des tests
/// natifs, et de tout appelant qui tient la RAM dans un `Vec`.
pub struct RamPlate(pub Vec<u8>);

impl RamPlate {
    fn plage(&self, adresse: u64, longueur: usize) -> Option<std::ops::Range<usize>> {
        let debut = usize::try_from(adresse).ok()?;
        let fin = debut.checked_add(longueur)?;
        (fin <= self.0.len()).then_some(debut..fin)
    }
}

impl Ram for RamPlate {
    fn lire(&self, adresse: u64, vers: &mut [u8]) -> bool {
        let Some(plage) = self.plage(adresse, vers.len()) else {
            return false;
        };
        vers.copy_from_slice(&self.0[plage]);
        true
    }

    fn ecrire(&mut self, adresse: u64, depuis: &[u8]) -> bool {
        let Some(plage) = self.plage(adresse, depuis.len()) else {
            return false;
        };
        self.0[plage].copy_from_slice(depuis);
        true
    }
}

/// **Aucune RAM** : tout accès est refusé. C'est ce que la porte de la page
/// passe tant qu'aucun périphérique de la carte ne lit la RAM — la brancher
/// demandera deux fonctions importées (`ram_lire`, `ram_ecrire`), et le
/// module n'en importe aucune aujourd'hui, ce qui garde l'émetteur
/// instanciable sans rien (`web/page-emitter.js`).
pub struct SansRam;

impl Ram for SansRam {
    fn lire(&self, _: u64, _: &mut [u8]) -> bool {
        false
    }
    fn ecrire(&mut self, _: u64, _: &[u8]) -> bool {
        false
    }
}

/// Les lignes que les périphériques de la carte tiennent par eux-mêmes.
pub const LIGNES_DES_PERIPHERIQUES: u16 = (1 << LIGNE_CLAVIER) | (1 << LIGNE_SOURIS);

/// **Les lignes que la boucle hôte tient elle-même**, et que la carte refuse
/// donc de lever : la 0 (le 8254), la 2 (la cascade de l'esclave) et la 4 (le
/// port série). Si la carte les déclarait tenues, l'aiguillage de `host.js`
/// effacerait à chaque tour ce que ses propres puces y ont posé.
pub const LIGNES_DE_L_HOTE: u16 = (1 << 0) | (1 << 2) | (1 << 4);

/// **La carte** : les périphériques, et les lignes levées du dehors.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Carte {
    pub cmos: Cmos,
    pub ps2: I8042,
    /// Les lignes levées par [`Carte::lever`] et pas encore baissées.
    levees_du_dehors: u16,
    /// Toutes celles que [`Carte::lever`] ou [`Carte::baisser`] ont nommées :
    /// une fois nommée, la carte la tient, et une ligne baissée doit retomber
    /// chez les 8259.
    nommees_du_dehors: u16,
}

impl Default for Carte {
    fn default() -> Self {
        Self::nouvelle()
    }
}

impl Carte {
    /// Une carte comme la laisse un BIOS. `const` pour tenir dans une
    /// `static` (la porte de la page).
    pub const fn nouvelle() -> Self {
        Self {
            cmos: Cmos::nouvelle(),
            ps2: I8042::nouveau(),
            levees_du_dehors: 0,
            nommees_du_dehors: 0,
        }
    }

    /// **Lire un port**, de `largeur` octets (1, 2 ou 4). `None` : personne
    /// ici — la boucle hôte rend alors ce qu'elle rend pour un port vide
    /// (`0xff`, le bus qui flotte).
    ///
    /// Les deux périphériques de cette carte sont des puces à registres d'un
    /// octet : une lecture plus large rend l'octet, et zéro au-dessus, comme
    /// `portRead` du cœur Swift (qui ne regarde pas la largeur pour eux).
    pub fn port_lire(&mut self, port: u16, largeur: u8, _ram: &mut dyn Ram) -> Option<u32> {
        if !largeur_valide(largeur) {
            return None;
        }
        let octet = match port {
            PORT_DONNEES => self.ps2.lire_donnee(),
            PORT_COMMANDE => self.ps2.etat(),
            // L'index ne se relit pas : le cœur Swift rend zéro (il tombe
            // dans son cas par défaut), et Linux ne le lit jamais.
            0x70 => 0,
            0x71 => self.cmos.lire(),
            _ => return None,
        };
        Some(u32::from(octet))
    }

    /// **Écrire un port**, de `largeur` octets. `false` : personne ici, et
    /// l'écriture tombe dans le vide. Une écriture plus large qu'un octet
    /// n'en garde que l'octet bas, comme `portWrite` du cœur Swift.
    pub fn port_ecrire(&mut self, port: u16, largeur: u8, valeur: u32, _ram: &mut dyn Ram) -> bool {
        if !largeur_valide(largeur) {
            return false;
        }
        let octet = valeur as u8;
        match port {
            PORT_DONNEES => self.ps2.ecrire_donnee(octet),
            PORT_COMMANDE => self.ps2.ecrire_commande(octet),
            0x70 => self.cmos.choisir(octet),
            0x71 => self.cmos.ecrire(octet),
            _ => return false,
        }
        true
    }

    /// **Les seize lignes, à niveau** : le bit `n` est la ligne `n` (0 à 7 au
    /// maître, 8 à 15 à l'esclave). Seules les lignes de [`Carte::tenues`]
    /// peuvent y paraître.
    pub fn lignes(&self) -> u16 {
        let mut lignes = self.levees_du_dehors;
        // Le clavier sur la ligne 1, la souris sur la ligne 12 — la
        // quatrième de l'esclave. À niveau, comme le port série.
        if self.ps2.clavier_interrompt() {
            lignes |= 1 << LIGNE_CLAVIER;
        }
        if self.ps2.souris_interrompt() {
            lignes |= 1 << LIGNE_SOURIS;
        }
        lignes
    }

    /// **Les lignes que la carte tient**, levées ou non : celles que la
    /// boucle hôte doit effacer quand [`Carte::lignes`] ne les lève pas.
    pub fn tenues(&self) -> u16 {
        LIGNES_DES_PERIPHERIQUES | self.nommees_du_dehors
    }

    /// **Lever une ligne du dehors**, jusqu'à [`Carte::baisser`]. Refusé
    /// (`false`) pour une ligne au-delà de 15 et pour celles de l'hôte
    /// ([`LIGNES_DE_L_HOTE`]).
    pub fn lever(&mut self, ligne: u8) -> bool {
        let Some(bit) = bit_du_dehors(ligne) else {
            return false;
        };
        self.nommees_du_dehors |= bit;
        self.levees_du_dehors |= bit;
        true
    }

    /// **Baisser une ligne levée du dehors.** Une ligne qu'un périphérique de
    /// la carte tient reste levée tant que lui la tient.
    pub fn baisser(&mut self, ligne: u8) -> bool {
        let Some(bit) = bit_du_dehors(ligne) else {
            return false;
        };
        self.nommees_du_dehors |= bit;
        self.levees_du_dehors &= !bit;
        true
    }

    /// **Le temps qui passe**, en tics du 8254 (1,193182 MHz) depuis le
    /// départ de la machine : ce qui pose les frappes de l'hôte à leur heure.
    /// La boucle hôte l'appelle à chaque tour, avant de relire les lignes.
    pub fn battre(&mut self, tics: u64) {
        if !self.ps2.frappes.is_empty() {
            self.ps2.rythmer(tics);
        }
    }

    /// **L'heure UTC de l'hôte**, en millisecondes depuis 1970 : voir
    /// [`Cmos::regler_heure_hote`].
    pub fn regler_heure(&mut self, ms: i64) {
        self.cmos.regler_heure_hote(ms);
    }

    /// Une touche posée tout de suite (un geste, une touche tenue par la
    /// barre de l'application).
    pub fn touche(&mut self, code: CodeTouche, enfoncee: bool) {
        self.ps2.touche(code, enfoncee);
    }

    /// Une frappe posée à son tour, au rythme d'une main ([`Carte::battre`]).
    /// `false` si la file pleine la refuse ; le relâchement d'une touche que
    /// la file laisse enfoncée n'est jamais refusé ([`I8042::taper`]).
    pub fn taper(&mut self, code: CodeTouche, enfoncee: bool) -> bool {
        self.ps2.taper(code, enfoncee)
    }

    /// **Un texte**, tapé sur un clavier américain, au rythme d'une main.
    /// Rend le nombre de frappes mises en file.
    ///
    /// La file est bornée ([`i8042::LIMITE_DE_FRAPPE`]), et un caractère y
    /// entre **entier ou pas du tout** : couper Maj, A, A, Maj après le
    /// premier A laissait A et Maj enfoncées dans l'invité. Le texte s'arrête
    /// au premier caractère qui ne tient plus, plutôt que de sauter celui-là
    /// et de taper les suivants, plus courts : l'invité reçoit le début du
    /// texte, pas un texte troué.
    pub fn taper_texte(&mut self, texte: &str) -> usize {
        let avant = self.ps2.frappes.len();
        for caractere in texte.chars() {
            let groupe = i8042::frappes_du_caractere(caractere);
            if !self.ps2.taper_groupe(&groupe) {
                break;
            }
        }
        self.ps2.frappes.len() - avant
    }

    /// Un mouvement de souris, Y vers le bas comme à l'écran.
    pub fn souris(&mut self, dx: i32, dy: i32, boutons: u8) {
        self.ps2.souris(dx, dy, boutons);
    }

    /// **L'invité a tiré la ligne de remise à zéro** (`0xFE` sur `0x64`) : la
    /// boucle hôte doit rendre « redémarrage ».
    pub fn remise_demandee(&self) -> bool {
        self.ps2.remise_demandee
    }

    /// **Quelque chose peut encore lever une ligne sans que l'invité
    /// agisse** : des frappes attendent leur tour. Ce que `wakeable` de la
    /// boucle hôte doit compter, comme `devicesArmed` du côté Swift.
    pub fn reveil(&self) -> bool {
        !self.ps2.frappes.is_empty()
    }
}

fn largeur_valide(largeur: u8) -> bool {
    matches!(largeur, 1 | 2 | 4)
}

fn bit_du_dehors(ligne: u8) -> Option<u16> {
    let bit = 1u16.checked_shl(u32::from(ligne))?;
    (ligne < 16 && bit & LIGNES_DE_L_HOTE == 0).then_some(bit)
}

#[cfg(test)]
mod tests {
    //! La carte par ses ports et ses lignes, comme la boucle hôte la voit :
    //! le cinquième cas de `X86CMOSClockTests` (par les ports), le neuvième
    //! de `X86PS2Tests` (la cascade, réduite à ce que la carte en tient : la
    //! ligne 12, quatrième de l'esclave), le rythme de frappe vu des lignes,
    //! et ce que la carte ne prend pas.
    use super::cmos::tests::MOMENT_MS;
    use super::*;

    fn lire(carte: &mut Carte, port: u16) -> Option<u32> {
        carte.port_lire(port, 1, &mut SansRam)
    }

    fn ecrire(carte: &mut Carte, port: u16, valeur: u32) -> bool {
        carte.port_ecrire(port, 1, valeur, &mut SansRam)
    }

    /// **Par les ports de la machine**, comme le noyau y accède.
    #[test]
    fn the_clock_answers_through_the_ports() {
        let mut carte = Carte::nouvelle();
        carte.regler_heure(MOMENT_MS);
        assert!(ecrire(&mut carte, 0x70, 0x09));
        assert_eq!(lire(&mut carte, 0x71), Some(0x26));
        ecrire(&mut carte, 0x70, 0x08);
        assert_eq!(lire(&mut carte, 0x71), Some(0x10));
        ecrire(&mut carte, 0x70, 0x0F);
        ecrire(&mut carte, 0x71, 0x5A);
        assert_eq!(lire(&mut carte, 0x71), Some(0x5A));
        // L'index ne se relit pas, mais le port est pris.
        assert_eq!(lire(&mut carte, 0x70), Some(0));
    }

    /// Le 8042 par ses deux ports : la sonde de Linux, et la largeur d'un
    /// accès qui ne change rien à une puce d'un octet.
    #[test]
    fn the_keyboard_controller_answers_through_the_ports() {
        let mut carte = Carte::nouvelle();
        assert_eq!(
            lire(&mut carte, 0x64),
            Some(0x14),
            "rien à lire, non verrouillé"
        );
        assert!(ecrire(&mut carte, 0x64, 0xAA));
        assert_eq!(lire(&mut carte, 0x64).map(|e| e & 0x09), Some(0x09));
        assert_eq!(carte.port_lire(0x60, 4, &mut SansRam), Some(0x55));
        // Une écriture large ne garde que l'octet bas : `0x1_2347` écrit
        // `0x47` dans le CTR.
        carte.port_ecrire(0x64, 1, 0x60, &mut SansRam);
        carte.port_ecrire(0x60, 2, 0x1_2347, &mut SansRam);
        ecrire(&mut carte, 0x64, 0x20);
        assert_eq!(lire(&mut carte, 0x60), Some(0x47));
        // Une largeur que l'émetteur ne rend pas n'est à personne.
        assert_eq!(carte.port_lire(0x60, 3, &mut SansRam), None);
        assert!(!carte.port_ecrire(0x64, 8, 0xFE, &mut SansRam));
        assert!(!carte.remise_demandee());
        // **L'impulsion de Linux** par le port : la ligne de remise à zéro.
        ecrire(&mut carte, 0x64, 0xFE);
        assert!(carte.remise_demandee());
    }

    /// **Ce que la carte ne prend pas** reste à la boucle hôte : ses puces,
    /// et les ports où il n'y a personne.
    #[test]
    fn ports_that_are_not_the_cards_are_left_to_the_host() {
        let mut carte = Carte::nouvelle();
        for port in [
            0x20, 0x21, 0x40, 0x43, 0x61, 0x3F8, 0x72, 0x80, 0xCF8, 0xCFC, 0x5F,
        ] {
            assert_eq!(lire(&mut carte, port), None, "{port:#x}");
            assert!(!ecrire(&mut carte, port, 0), "{port:#x}");
        }
        assert_eq!(carte, Carte::nouvelle(), "et rien n'a bougé");
    }

    /// **La ligne 12 est la quatrième de l'esclave** : une demande de la
    /// souris se lit au bit 12, et la carte tient les deux lignes de son
    /// 8042 — levées ou non — pour que la boucle hôte les efface quand elles
    /// retombent.
    #[test]
    fn the_mouse_line_is_the_fourth_of_the_slave() {
        let mut carte = Carte::nouvelle();
        assert_eq!(carte.lignes(), 0);
        assert_eq!(carte.tenues(), (1 << 1) | (1 << 12));
        ecrire(&mut carte, 0x64, 0xD3);
        ecrire(&mut carte, 0x60, 1);
        assert_eq!(carte.lignes(), 1 << 12);
        assert_eq!(
            (carte.lignes() >> 8) as u8,
            1 << 4,
            "quatrième ligne de l'esclave"
        );
        // Plus d'interruption de la souris : la ligne retombe, l'octet reste.
        ecrire(&mut carte, 0x64, 0x60);
        ecrire(&mut carte, 0x60, 0x44);
        assert_eq!(carte.lignes(), 0);
        assert_eq!(lire(&mut carte, 0x64).map(|e| e & 0x21), Some(0x21));
        // Une touche : la ligne 1, au maître.
        ecrire(&mut carte, 0x64, 0x60);
        ecrire(&mut carte, 0x60, 0x47);
        assert_eq!(lire(&mut carte, 0x60), Some(1), "l'octet bouclé, lu");
        carte.touche(CodeTouche::ESPACE, true);
        assert_eq!(carte.lignes(), 1 << 1);
        assert_eq!(lire(&mut carte, 0x60), Some(0x39));
        assert_eq!(carte.lignes(), 0, "lu, la ligne retombe");
    }

    /// **Le rythme de frappe, vu des lignes** : un texte tapé ne lève la
    /// ligne 1 qu'à l'heure de chaque frappe, une à la fois, et la carte se
    /// dit réveillable tant qu'il en reste.
    #[test]
    fn typed_text_raises_the_keyboard_line_at_the_pace_of_a_hand() {
        let mut carte = Carte::nouvelle();
        assert!(!carte.reveil());
        assert_eq!(carte.taper_texte("A"), 4, "Maj, A, A, Maj");
        assert!(carte.reveil());
        assert_eq!(carte.lignes(), 0, "rien avant le premier battement");
        let mut lus = Vec::new();
        let mut tics = 10_000u64;
        let mut battements_leves = 0;
        // Une milliseconde de l'invité par battement (1 193 tics).
        while carte.reveil() || carte.lignes() != 0 {
            carte.battre(tics);
            if carte.lignes() & (1 << 1) != 0 {
                battements_leves += 1;
                lus.push((tics, lire(&mut carte, 0x60).expect("le 8042 répond")));
            }
            tics += 1_193;
            assert!(tics < 10_000 + 1_193 * 1_000, "la frappe ne finit pas");
        }
        assert_eq!(battements_leves, 4);
        assert_eq!(
            lus.iter().map(|l| l.1).collect::<Vec<_>>(),
            [0x2A, 0x1E, 0x9E, 0xAA]
        );
        // Une touche enfoncée (Maj, puis A) est tenue trente millisecondes ;
        // une relâchée (A) en laisse vingt avant la suivante. Au battement
        // près.
        let ecarts: Vec<u64> = lus.windows(2).map(|w| w[1].0 - w[0].0).collect();
        let attendus = [i8042::TENUE_TICS, i8042::TENUE_TICS, i8042::ECART_TICS];
        assert_eq!(ecarts.len(), attendus.len());
        for (ecart, attendu) in ecarts.iter().zip(attendus) {
            assert!(
                (attendu..attendu + 1_193).contains(ecart),
                "{ecarts:?} : attendu {attendus:?}, au battement près"
            );
        }
        assert!(!carte.reveil());
    }

    /// **Un texte qui remplit la file s'arrête sur un caractère entier.**
    /// Avant, la borne coupait `Maj A A Maj` après l'enfoncement : A et Maj
    /// restaient enfoncées dans l'invité, et Xorg répétait A sans fin. Ici
    /// le texte s'arrête au premier caractère qui ne tient plus, même si le
    /// suivant, plus court, tiendrait : pas de texte troué.
    #[test]
    fn a_text_that_fills_the_queue_ends_on_a_whole_character() {
        let mut carte = Carte::nouvelle();
        let texte = format!("a{}Ab", "A".repeat(2047));
        // « a » : deux frappes ; chaque « A » : quatre. 2 + 4 × 2 047 = 8 190,
        // et le « A » suivant n'a plus que deux places.
        assert_eq!(carte.taper_texte(&texte), 8_190);
        let file: Vec<_> = carte.ps2.frappes.iter().copied().collect();
        let fin: Vec<_> = file[file.len() - 4..]
            .iter()
            .map(|f| (f.code.jeu1, f.enfoncee))
            .collect();
        assert_eq!(
            fin,
            [(0x2A, true), (0x1E, true), (0x1E, false), (0x2A, false)],
            "le dernier caractère est entier"
        );
        let compte = |jeu1, enfoncee| {
            file.iter()
                .filter(|f| f.code.jeu1 == jeu1 && f.enfoncee == enfoncee)
                .count()
        };
        assert_eq!((compte(0x2A, true), compte(0x2A, false)), (2_047, 2_047));
        assert_eq!((compte(0x1E, true), compte(0x1E, false)), (2_048, 2_048));
        assert_eq!(compte(0x30, true), 0, "« b » ne passe pas devant « A »");
        // Un autre texte, plus tard, prend les places qui restent.
        assert_eq!(carte.taper_texte("b"), 2);
        assert_eq!(carte.taper_texte("c"), 0);
    }

    /// **Les lignes du dehors, à niveau**, et le refus des lignes de l'hôte.
    #[test]
    fn lines_raised_from_outside_stay_up_until_lowered() {
        let mut carte = Carte::nouvelle();
        assert!(carte.lever(5));
        assert!(carte.lever(10));
        assert_eq!(carte.lignes(), (1 << 5) | (1 << 10));
        assert!(carte.baisser(5));
        assert_eq!(carte.lignes(), 1 << 10);
        assert_ne!(carte.tenues() & (1 << 5), 0, "baissée, mais tenue");
        // Une ligne qu'un périphérique tient ne retombe pas parce qu'on la
        // baisse du dehors.
        carte.touche(CodeTouche::ESPACE, true);
        carte.baisser(1);
        assert_ne!(carte.lignes() & (1 << 1), 0);
        for ligne in [0, 2, 4, 16, 200] {
            assert!(!carte.lever(ligne), "ligne {ligne}");
            assert!(!carte.baisser(ligne), "ligne {ligne}");
        }
        assert_eq!(carte.tenues() & LIGNES_DE_L_HOTE, 0);
    }

    /// **La RAM vue d'un périphérique** : une plage entière ou rien.
    #[test]
    fn the_ram_refuses_what_does_not_fit_whole() {
        let mut ram = RamPlate(vec![0; 16]);
        assert!(ram.ecrire(12, &[1, 2, 3, 4]));
        let mut lu = [0; 4];
        assert!(ram.lire(12, &mut lu));
        assert_eq!(lu, [1, 2, 3, 4]);
        assert!(!ram.ecrire(13, &[9; 4]), "déborde d'un octet");
        assert!(
            !ram.lire(u64::MAX, &mut lu),
            "l'addition ne fait pas le tour"
        );
        assert_eq!(ram.0[12..], [1, 2, 3, 4], "un refus ne touche à rien");
        assert!(!SansRam.lire(0, &mut lu));
        assert!(!SansRam.ecrire(0, &lu));
    }
}
