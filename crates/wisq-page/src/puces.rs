//! **Les puces de la machine de l'émetteur, en Rust** : le 8254 (trois
//! compteurs et le portillon `0x61`), les deux 8259 en cascade et le 16550
//! de `0x3F8`.
//!
//! Étape 2 du port de `web/host.js` vers Rust. Ce fichier **reproduit**,
//! décision pour décision, ce que `host.js` fait de ces ports (ses lignes
//! 583 à 1505) : la même horloge (le TSC de l'invité, à un gigahertz, et les
//! pas du 8254 à 1 193 182 Hz), les mêmes cas, les mêmes valeurs rendues. Il
//! n'invente rien de mieux, exprès : la boucle JavaScript est jugée par 253
//! tests sous Bun, et c'est contre eux que cette version se branchera. Une
//! « amélioration » glissée ici serait un écart que personne n'aurait voulu.
//!
//! **L'état est pur** : l'heure arrive en argument (`maintenant`, le TSC), et
//! les octets que l'invité écrit sur la ligne série sont gardés jusqu'à ce que
//! la page les relève. Rien ici n'appelle personne — c'est ce qui le laisse
//! se juger en natif.

use std::collections::VecDeque;

/// La fréquence du 8254, en pas par seconde.
pub const PIT_HZ: u128 = 1_193_182;
/// Celle du TSC de l'invité : une nanoseconde par pas.
pub const TSC_HZ: u128 = 1_000_000_000;

const SERIE: u16 = 0x3f8;
const SERIE_DERNIER: u16 = SERIE + 7;
const EMETTEUR_LIBRE: u8 = 0x60;
const PIT_CANAL: u16 = 0x40;
const PIT_COMMANDE: u16 = 0x43;
const PIT_PORTILLON: u16 = 0x61;
const PIT_PORTILLON_OUVERT: u8 = 0x01;
const PIT_SORTIE_DEUX: u8 = 0x20;
const PIC_MAITRE: u16 = 0x20;
const PIC_ESCLAVE: u16 = 0xa0;
const PIC_INIT: u8 = 0x10;
const PIC_VEUT_ICW4: u8 = 0x01;
const PIC_MOT: u8 = 0x18;
const PIC_EST_OCW3: u8 = 0x08;
const PIC_EOI: u8 = 0x20;
const PIC_PRECIS: u8 = 0x40;
const PIC_LIRE_SERVICE: u8 = 0x01;
/// La ligne du maître où l'esclave est branché.
pub const PIC_CASCADE: u8 = 2;

/// Un compteur du 8254 (`counter()` de `host.js`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Compteur {
    pub mode: u8,
    pub acces: u8,
    pub recharge: u32,
    /// Les pas déjà comptés avant la dernière fermeture du portillon.
    pub consommes: i128,
    pub ouvert_a: u64,
    pub ouvert: bool,
    pub bas: u8,
    pub lire_haut: bool,
    pub ecrire_haut: bool,
    pub verrouille: Option<u32>,
    pub leves: i128,
    pub charge: bool,
}

impl Default for Compteur {
    fn default() -> Self {
        Self {
            mode: 0,
            acces: 3,
            recharge: 0,
            consommes: 0,
            ouvert_a: 0,
            ouvert: true,
            bas: 0,
            lire_haut: false,
            ecrire_haut: false,
            verrouille: None,
            leves: 0,
            charge: false,
        }
    }
}

/// Un 8259 (`controller()` de `host.js`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Controleur {
    pub masque: u8,
    pub base: u8,
    pub attend: u8,
    pub veut_quatre: bool,
    pub demande: u8,
    pub service: u8,
    /// `true` quand OCW3 a demandé le registre de service.
    pub lit_service: bool,
}

impl Default for Controleur {
    fn default() -> Self {
        Self {
            masque: 0xff,
            base: 0,
            attend: 0,
            veut_quatre: false,
            demande: 0,
            service: 0,
            lit_service: false,
        }
    }
}

/// Le 16550 (`uart` de `host.js`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Uart {
    pub interruptions: u8,
    pub fifo: u8,
    pub ligne: u8,
    pub modem: u8,
    pub brouillon: u8,
    pub diviseur: u16,
    pub emission_due: bool,
    pub entree: VecDeque<u8>,
}

/// Une interruption prête : la ligne, le contrôleur, le vecteur.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Irq {
    pub ligne: u8,
    pub esclave: bool,
    pub vecteur: u8,
}

/// Les trois puces, et ce que la ligne série a émis depuis le dernier relevé.
#[derive(Debug, Clone, Default)]
pub struct Puces {
    pub compteurs: [Compteur; 3],
    pub portillon: u8,
    pub maitre: Controleur,
    pub esclave: Controleur,
    pub uart: Uart,
    /// Les octets que l'invité a écrits sur `0x3F8`, dans l'ordre.
    pub serie: Vec<u8>,
}

/// L'indice du bit le plus bas, ou `None` (`highest` de `host.js`, qui rend
/// le bit de plus haute **priorité**, c'est-à-dire le plus bas).
fn plus_prioritaire(bits: u8) -> Option<u8> {
    (bits != 0).then(|| bits.trailing_zeros() as u8)
}

fn recharge_reelle(compteur: &Compteur) -> u32 {
    if compteur.recharge == 0 {
        0x10000
    } else {
        compteur.recharge
    }
}

fn a_un_coup(mode: u8) -> bool {
    mode == 0 || mode == 4
}

fn compte(mode: u8) -> bool {
    a_un_coup(mode) || mode == 2 || mode == 6
}

impl Puces {
    /// Les pas du 8254 depuis le chargement (`stepsOf`).
    pub fn pas(compteur: &Compteur, maintenant: u64) -> i128 {
        let courant = if compteur.ouvert {
            (i128::from(maintenant) - i128::from(compteur.ouvert_a)) * PIT_HZ as i128
                / TSC_HZ as i128
        } else {
            0
        };
        compteur.consommes + courant
    }

    /// La valeur que le compteur montrerait (`countOf`).
    pub fn valeur(compteur: &Compteur, maintenant: u64) -> u32 {
        let recharge = recharge_reelle(compteur);
        let pas = Self::pas(compteur, maintenant);
        if compteur.mode == 2 || compteur.mode == 6 {
            return (i128::from(recharge) - pas % i128::from(recharge)) as u32;
        }
        ((i128::from(recharge) - pas) & 0xffff) as u32
    }

    fn charger(compteur: &mut Compteur, valeur: u32, maintenant: u64) {
        compteur.recharge = valeur & 0xffff;
        compteur.consommes = 0;
        compteur.ouvert_a = maintenant;
        compteur.verrouille = None;
        compteur.lire_haut = false;
        compteur.leves = 0;
        compteur.charge = true;
    }

    /// La sortie du canal deux, lue sur `0x61` (`outTwo`).
    pub fn sortie_deux(&self, maintenant: u64) -> bool {
        let compteur = &self.compteurs[2];
        if compteur.mode != 0 {
            return false;
        }
        Self::pas(compteur, maintenant) >= i128::from(recharge_reelle(compteur))
    }

    fn dlab(&self) -> bool {
        self.uart.ligne & 0x80 != 0
    }

    fn boucle(&self) -> bool {
        self.uart.modem & 0x10 != 0
    }

    /// La ligne série demande-t-elle une interruption (`serialInterrupting`).
    pub fn serie_interrompt(&self) -> bool {
        if self.uart.interruptions & 0x01 != 0 && !self.uart.entree.is_empty() {
            return true;
        }
        self.uart.interruptions & 0x02 != 0 && self.uart.emission_due
    }

    fn serie_ecrire(&mut self, decalage: u16, octet: u8) {
        match decalage {
            0 => {
                if self.dlab() {
                    self.uart.diviseur = (self.uart.diviseur & 0xff00) | u16::from(octet);
                    return;
                }
                if self.boucle() {
                    self.uart.entree.push_back(octet);
                } else {
                    self.serie.push(octet);
                }
                self.uart.emission_due = true;
            }
            1 => {
                if self.dlab() {
                    self.uart.diviseur = (self.uart.diviseur & 0x00ff) | (u16::from(octet) << 8);
                    return;
                }
                let avant = self.uart.interruptions;
                self.uart.interruptions = octet & 0x0f;
                if octet & 0x02 != 0 && avant & 0x02 == 0 {
                    self.uart.emission_due = true;
                }
            }
            2 => self.uart.fifo = octet,
            3 => self.uart.ligne = octet,
            4 => self.uart.modem = octet & 0x1f,
            7 => self.uart.brouillon = octet,
            _ => {}
        }
    }

    fn serie_lire(&mut self, decalage: u16) -> u8 {
        match decalage {
            0 => {
                if self.dlab() {
                    return (self.uart.diviseur & 0xff) as u8;
                }
                self.uart.entree.pop_front().unwrap_or(0)
            }
            1 => {
                if self.dlab() {
                    return (self.uart.diviseur >> 8) as u8;
                }
                self.uart.interruptions
            }
            2 => {
                let fifo = if self.uart.fifo & 0x01 != 0 { 0xc0 } else { 0 };
                if self.uart.interruptions & 0x01 != 0 && !self.uart.entree.is_empty() {
                    return fifo | 0x04;
                }
                if self.uart.interruptions & 0x02 != 0 && self.uart.emission_due {
                    self.uart.emission_due = false;
                    return fifo | 0x02;
                }
                fifo | 0x01
            }
            3 => self.uart.ligne,
            4 => self.uart.modem,
            5 => EMETTEUR_LIBRE | u8::from(!self.uart.entree.is_empty()),
            6 => {
                if !self.boucle() {
                    return 0xb0;
                }
                let modem = self.uart.modem;
                (if modem & 0x01 != 0 { 0x20 } else { 0 })
                    | (if modem & 0x02 != 0 { 0x10 } else { 0 })
                    | (if modem & 0x04 != 0 { 0x40 } else { 0 })
                    | (if modem & 0x08 != 0 { 0x80 } else { 0 })
            }
            _ => self.uart.brouillon,
        }
    }

    /// Lève ou baisse la ligne quatre du maître selon la ligne série
    /// (`raiseSerial`).
    pub fn lever_serie(&mut self) {
        if self.serie_interrompt() {
            self.maitre.demande |= 0x10;
        } else {
            self.maitre.demande &= !0x10;
        }
    }

    /// Lève la ligne zéro quand le compteur zéro a fait un tour de plus
    /// (`raise8254`).
    pub fn lever_8254(&mut self, maintenant: u64) {
        let compteur = &self.compteurs[0];
        if !compteur.charge || !compte(compteur.mode) {
            return;
        }
        let recharge = i128::from(recharge_reelle(compteur));
        let pas = Self::pas(compteur, maintenant);
        let tours = if a_un_coup(compteur.mode) {
            i128::from(pas >= recharge)
        } else {
            pas / recharge
        };
        if tours > self.compteurs[0].leves {
            self.compteurs[0].leves = tours;
            self.maitre.demande |= 1;
        }
    }

    fn prete(controleur: &Controleur) -> Option<u8> {
        let pretes = controleur.demande & !controleur.masque;
        let ligne = plus_prioritaire(pretes)?;
        let servie = plus_prioritaire(controleur.service).unwrap_or(8);
        (ligne < servie).then_some(ligne)
    }

    /// L'interruption à délivrer, s'il y en a une (`pendingIrq`). La ligne
    /// de cascade du maître suit l'esclave, comme dans `host.js`.
    pub fn en_attente(&mut self) -> Option<Irq> {
        let dessous = Self::prete(&self.esclave);
        if dessous.is_some() {
            self.maitre.demande |= 1 << PIC_CASCADE;
        } else {
            self.maitre.demande &= !(1 << PIC_CASCADE);
        }
        let dessus = Self::prete(&self.maitre)?;
        if dessus != PIC_CASCADE {
            return Some(Irq {
                ligne: dessus,
                esclave: false,
                vecteur: self.maitre.base.wrapping_add(dessus),
            });
        }
        let ligne = dessous?;
        Some(Irq {
            ligne,
            esclave: true,
            vecteur: self.esclave.base.wrapping_add(ligne),
        })
    }

    /// Le compteur zéro peut-il réveiller un `hlt` (`wakeable`).
    pub fn reveillable(&self) -> bool {
        let compteur = &self.compteurs[0];
        if !compteur.charge || !compte(compteur.mode) {
            return false;
        }
        if a_un_coup(compteur.mode) && compteur.leves > 0 {
            return false;
        }
        self.maitre.masque & 1 == 0 && self.maitre.service & 1 == 0
    }

    /// L'interruption est prise : sa demande tombe, son service se lève
    /// (`takeIrq`).
    pub fn prendre(&mut self, irq: Irq) {
        let controleur = if irq.esclave {
            &mut self.esclave
        } else {
            &mut self.maitre
        };
        controleur.demande &= !(1 << irq.ligne);
        controleur.service |= 1 << irq.ligne;
        if irq.esclave {
            self.maitre.demande &= !(1 << PIC_CASCADE);
            self.maitre.service |= 1 << PIC_CASCADE;
        }
    }

    /// Les lignes que la carte tient (`recopierLignes`) : celles qu'elle
    /// tenait et ne tient plus tombent, celles qu'elle lève se lèvent.
    pub fn recopier_lignes(
        &mut self,
        maitre: u8,
        tenues_maitre: u8,
        esclave: u8,
        tenues_esclave: u8,
    ) {
        self.maitre.demande = (self.maitre.demande & !(tenues_maitre & !maitre)) | maitre;
        self.esclave.demande = (self.esclave.demande & !(tenues_esclave & !esclave)) | esclave;
    }

    fn controleur(&mut self, port: u16) -> Option<(&mut Controleur, bool)> {
        match port {
            PIC_MAITRE | 0x21 => Some((&mut self.maitre, port & 1 == 1)),
            PIC_ESCLAVE | 0xa1 => Some((&mut self.esclave, port & 1 == 1)),
            _ => None,
        }
    }

    /// **Une écriture de port** (`env.out`, la part des puces). `false` quand
    /// le port n'est pas à elles : la page le passe à la carte.
    pub fn sortir(&mut self, port: u16, valeur: u64, maintenant: u64) -> bool {
        let octet = (valeur & 0xff) as u8;
        if (SERIE..=SERIE_DERNIER).contains(&port) {
            self.serie_ecrire(port - SERIE, octet);
            return true;
        }
        if port == PIT_PORTILLON {
            self.portillon = octet & !PIT_SORTIE_DEUX;
            let voulu = octet & PIT_PORTILLON_OUVERT != 0;
            let compteur = &mut self.compteurs[2];
            if voulu != compteur.ouvert {
                if !voulu {
                    compteur.consommes = Self::pas(compteur, maintenant);
                }
                compteur.ouvert = voulu;
                compteur.ouvert_a = maintenant;
            }
            return true;
        }
        if port == PIT_COMMANDE {
            let lequel = usize::from(octet >> 6);
            if lequel == 3 {
                return true;
            }
            let acces = (octet >> 4) & 3;
            if acces == 0 {
                let valeur = Self::valeur(&self.compteurs[lequel], maintenant);
                let compteur = &mut self.compteurs[lequel];
                compteur.verrouille = Some(valeur);
                compteur.lire_haut = false;
                return true;
            }
            let compteur = &mut self.compteurs[lequel];
            compteur.mode = (octet >> 1) & 7;
            compteur.acces = acces;
            compteur.bas = 0;
            compteur.lire_haut = false;
            compteur.ecrire_haut = false;
            compteur.verrouille = None;
            return true;
        }
        if (PIT_CANAL..PIT_CANAL + 3).contains(&port) {
            let compteur = &mut self.compteurs[usize::from(port - PIT_CANAL)];
            match compteur.acces {
                1 => Self::charger(compteur, u32::from(octet), maintenant),
                2 => Self::charger(compteur, u32::from(octet) << 8, maintenant),
                _ if !compteur.ecrire_haut => {
                    compteur.bas = octet;
                    compteur.ecrire_haut = true;
                }
                _ => {
                    compteur.ecrire_haut = false;
                    let valeur = (u32::from(octet) << 8) | u32::from(compteur.bas);
                    Self::charger(compteur, valeur, maintenant);
                }
            }
            return true;
        }
        if let Some((controleur, donnee)) = self.controleur(port) {
            if !donnee {
                if octet & PIC_INIT != 0 {
                    controleur.attend = 2;
                    controleur.veut_quatre = octet & PIC_VEUT_ICW4 != 0;
                    return true;
                }
                if octet & PIC_MOT == PIC_EST_OCW3 {
                    controleur.lit_service = octet & PIC_LIRE_SERVICE != 0;
                    return true;
                }
                if octet & PIC_EOI != 0 {
                    let ligne = if octet & PIC_PRECIS != 0 {
                        Some(octet & 0x07)
                    } else {
                        plus_prioritaire(controleur.service)
                    };
                    if let Some(ligne) = ligne {
                        controleur.service &= !(1 << ligne);
                    }
                }
                return true;
            }
            match controleur.attend {
                2 => {
                    controleur.base = octet;
                    controleur.attend = 3;
                }
                3 => controleur.attend = if controleur.veut_quatre { 4 } else { 0 },
                4 => controleur.attend = 0,
                _ => controleur.masque = octet,
            }
            return true;
        }
        false
    }

    /// **Une lecture de port** (`env.in`, la part des puces), ou `None`
    /// quand le port n'est pas à elles.
    pub fn entrer(&mut self, port: u16, maintenant: u64) -> Option<u8> {
        if (SERIE..=SERIE_DERNIER).contains(&port) {
            return Some(self.serie_lire(port - SERIE));
        }
        if port == PIT_PORTILLON {
            let sortie = if self.sortie_deux(maintenant) {
                PIT_SORTIE_DEUX
            } else {
                0
            };
            return Some(self.portillon | sortie);
        }
        if (PIT_CANAL..PIT_CANAL + 3).contains(&port) {
            let indice = usize::from(port - PIT_CANAL);
            let valeur = match self.compteurs[indice].verrouille {
                Some(valeur) => valeur,
                None => Self::valeur(&self.compteurs[indice], maintenant),
            };
            let compteur = &mut self.compteurs[indice];
            return Some(match compteur.acces {
                1 => (valeur & 0xff) as u8,
                2 => ((valeur >> 8) & 0xff) as u8,
                _ if !compteur.lire_haut => {
                    compteur.lire_haut = true;
                    (valeur & 0xff) as u8
                }
                _ => {
                    compteur.lire_haut = false;
                    compteur.verrouille = None;
                    ((valeur >> 8) & 0xff) as u8
                }
            });
        }
        let lit_donnee = matches!(port, 0x21 | 0xa1);
        if matches!(port, PIC_MAITRE | 0x21 | PIC_ESCLAVE | 0xa1) {
            if lit_donnee {
                return self
                    .controleur(port)
                    .map(|(controleur, _)| controleur.masque);
            }
            self.en_attente();
            return self.controleur(port).map(|(controleur, _)| {
                if controleur.lit_service {
                    controleur.service
                } else {
                    controleur.demande
                }
            });
        }
        None
    }

    /// Les octets émis sur la ligne série depuis le dernier relevé.
    pub fn relever_serie(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.serie)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Une milliseconde de TSC.
    const MS: u64 = 1_000_000;

    #[test]
    fn the_8254_counts_down_in_mode_two_and_latches() {
        let mut puces = Puces::default();
        // Canal 0, octet bas puis haut, mode 2 : `0x34`, puis 1193 (≈ 1 ms).
        assert!(puces.sortir(PIT_COMMANDE, 0x34, 0));
        puces.sortir(PIT_CANAL, 1193 & 0xff, 0);
        puces.sortir(PIT_CANAL, 1193 >> 8, 0);
        assert_eq!(Puces::valeur(&puces.compteurs[0], 0), 1193);
        // Une demi-milliseconde : 596 pas consommés.
        let demi = MS / 2;
        assert_eq!(Puces::valeur(&puces.compteurs[0], demi), 1193 - 596);
        // Verrouillé, la valeur ne bouge plus jusqu'aux deux lectures.
        puces.sortir(PIT_COMMANDE, 0x00, demi);
        let bas = puces.entrer(PIT_CANAL, 10 * MS).unwrap();
        let haut = puces.entrer(PIT_CANAL, 10 * MS).unwrap();
        assert_eq!(u32::from(bas) | (u32::from(haut) << 8), 1193 - 596);
        // Le tour suivant lève la ligne zéro, une fois par tour.
        puces.lever_8254(3 * MS);
        assert_eq!(puces.maitre.demande & 1, 1);
        // 3 ms font 3 579 pas : exactement trois tours de 1 193.
        assert_eq!(puces.compteurs[0].leves, 3);
    }

    #[test]
    fn the_gate_stops_channel_two_and_its_output_is_read_on_0x61() {
        let mut puces = Puces::default();
        puces.sortir(PIT_COMMANDE, 0xb0, 0); // canal 2, bas/haut, mode 0
        puces.sortir(PIT_CANAL + 2, 100, 0);
        puces.sortir(PIT_CANAL + 2, 0, 0);
        puces.sortir(PIT_PORTILLON, 0x01, 0);
        assert_eq!(puces.entrer(PIT_PORTILLON, 0), Some(0x01));
        assert_eq!(
            puces.entrer(PIT_PORTILLON, MS),
            Some(0x21),
            "100 pas sont passés"
        );
        puces.sortir(PIT_PORTILLON, 0x00, MS);
        assert!(!puces.compteurs[2].ouvert);
    }

    #[test]
    fn the_8259_pair_is_initialised_and_serves_the_highest_priority() {
        let mut puces = Puces::default();
        for (port, octet) in [
            (0x20, 0x11),
            (0x21, 0x20),
            (0x21, 0x04),
            (0x21, 0x01),
            (0xa0, 0x11),
            (0xa1, 0x28),
            (0xa1, 0x02),
            (0xa1, 0x01),
        ] {
            puces.sortir(port, octet, 0);
        }
        puces.sortir(0x21, 0x00, 0);
        puces.sortir(0xa1, 0x00, 0);
        assert_eq!((puces.maitre.base, puces.esclave.base), (0x20, 0x28));
        // Une demande sur l'esclave, ligne 4 (IRQ 12) : vecteur 0x2c.
        puces.esclave.demande |= 1 << 4;
        let irq = puces.en_attente().unwrap();
        assert_eq!(
            irq,
            Irq {
                ligne: 4,
                esclave: true,
                vecteur: 0x2c
            }
        );
        puces.prendre(irq);
        assert_eq!(puces.maitre.service, 1 << PIC_CASCADE);
        assert!(puces.en_attente().is_none());
        // EOI non précis sur chacun.
        puces.sortir(0xa0, 0x20, 0);
        puces.sortir(0x20, 0x20, 0);
        assert_eq!((puces.maitre.service, puces.esclave.service), (0, 0));
        // OCW3 : lire le registre de service.
        puces.sortir(0x20, 0x0b, 0);
        assert!(puces.maitre.lit_service);
        assert_eq!(puces.entrer(0x20, 0), Some(0));
    }

    #[test]
    fn the_16550_sends_loops_back_and_reports_its_interrupts() {
        let mut puces = Puces::default();
        for octet in *b"ok" {
            puces.sortir(SERIE, u64::from(octet), 0);
        }
        assert_eq!(puces.relever_serie(), b"ok");
        assert_eq!(puces.entrer(SERIE + 5, 0), Some(EMETTEUR_LIBRE));
        // Boucle : ce qui part revient, et l'IIR le dit.
        puces.sortir(SERIE + 4, 0x10, 0);
        puces.sortir(SERIE + 1, 0x01, 0);
        puces.sortir(SERIE, u64::from(b'x'), 0);
        assert!(puces.relever_serie().is_empty());
        assert_eq!(puces.entrer(SERIE + 2, 0), Some(0x04));
        assert_eq!(puces.entrer(SERIE, 0), Some(b'x'));
        assert_eq!(puces.entrer(SERIE + 2, 0), Some(0x01));
        // Le diviseur derrière DLAB.
        puces.sortir(SERIE + 3, 0x80, 0);
        puces.sortir(SERIE, 0x01, 0);
        puces.sortir(SERIE + 1, 0x00, 0);
        assert_eq!(puces.uart.diviseur, 1);
        assert!(!puces.sortir(0x80, 0, 0), "un port qui n'est pas aux puces");
        assert_eq!(puces.entrer(0x60, 0), None);
    }
}

/// **Les puces telles que la page les appelle** (wasm32 seulement : l'heure
/// est le TSC de l'invité, lu à travers le module d'accès de `hote.rs`).
///
/// Les réponses sont des `i32` et pas des `i64` : un `i64` qui traverse vers
/// JavaScript devient un BigInt, et la boucle les appelle à chaque port.
#[cfg(target_arch = "wasm32")]
mod page {
    use super::{Irq, Puces};
    use std::sync::Mutex;

    static PUCES: Mutex<Option<Puces>> = Mutex::new(None);

    /// Aucun appel sortant n'est fait sous ce verrou, sauf la lecture du TSC,
    /// qui ne peut pas rappeler la page.
    fn avec<R>(faire: impl FnOnce(&mut Puces, u64) -> R) -> R {
        let maintenant = crate::hote::lire(wisq_vm::x86_wasm::TSC_SLOT as i32).unwrap_or(0) as u64;
        let mut verrou = PUCES.lock().unwrap_or_else(|poison| poison.into_inner());
        faire(verrou.get_or_insert_with(Puces::default), maintenant)
    }

    #[no_mangle]
    extern "C" fn puces_remettre() {
        *PUCES.lock().unwrap_or_else(|poison| poison.into_inner()) = Some(Puces::default());
    }

    /// `0` : le port n'est pas aux puces ; `1` : fait ; `0x100 | octet` :
    /// fait, et cet octet est parti sur la ligne série.
    #[no_mangle]
    extern "C" fn puces_sortir(port: u32, valeur: u32) -> u32 {
        avec(|puces, maintenant| {
            let Ok(port) = u16::try_from(port) else {
                return 0;
            };
            if !puces.sortir(port, u64::from(valeur), maintenant) {
                return 0;
            }
            match puces.serie.pop() {
                Some(octet) => 0x100 | u32::from(octet),
                None => 1,
            }
        })
    }

    /// L'octet lu, ou `-1` quand le port n'est pas aux puces.
    #[no_mangle]
    extern "C" fn puces_entrer(port: u32) -> i32 {
        avec(|puces, maintenant| {
            u16::try_from(port)
                .ok()
                .and_then(|port| puces.entrer(port, maintenant))
                .map_or(-1, i32::from)
        })
    }

    fn coder(irq: Irq) -> i32 {
        i32::from(irq.vecteur) | (i32::from(irq.ligne) << 8) | (i32::from(irq.esclave) << 16)
    }

    fn decoder(code: u32) -> Irq {
        Irq {
            vecteur: (code & 0xff) as u8,
            ligne: ((code >> 8) & 0xff) as u8,
            esclave: code >> 16 & 1 == 1,
        }
    }

    /// L'interruption prête, codée `vecteur | ligne << 8 | esclave << 16`, ou
    /// `-1`.
    #[no_mangle]
    extern "C" fn puces_en_attente() -> i32 {
        avec(|puces, _| puces.en_attente().map_or(-1, coder))
    }

    #[no_mangle]
    extern "C" fn puces_prendre(code: u32) {
        avec(|puces, _| puces.prendre(decoder(code)));
    }

    #[no_mangle]
    extern "C" fn puces_reveillable() -> u32 {
        avec(|puces, _| u32::from(puces.reveillable()))
    }

    #[no_mangle]
    extern "C" fn puces_lever_8254() {
        avec(Puces::lever_8254);
    }

    #[no_mangle]
    extern "C" fn puces_lever_serie() {
        avec(|puces, _| puces.lever_serie());
    }

    #[no_mangle]
    extern "C" fn puces_recopier(
        maitre: u32,
        tenues_maitre: u32,
        esclave: u32,
        tenues_esclave: u32,
    ) {
        avec(|puces, _| {
            puces.recopier_lignes(
                maitre as u8,
                tenues_maitre as u8,
                esclave as u8,
                tenues_esclave as u8,
            );
        });
    }

    /// Un octet arrivé sur la ligne série (`vm.send`).
    #[no_mangle]
    extern "C" fn puces_recevoir(octet: u32) {
        avec(|puces, _| puces.uart.entree.push_back(octet as u8));
    }

    /// **Poser un champ**, pour la façade : quelques tests règlent un
    /// contrôleur ou la ligne série à la main (`vm.pics.master.base = 0x20`,
    /// `vm.uart.interruptEnable = 1`), sans passer par les ports. Mêmes
    /// numéros que [`puces_champ`] ; un numéro inconnu ne pose rien.
    #[no_mangle]
    extern "C" fn puces_poser(champ: u32, valeur: u32) {
        avec(|puces, _| {
            let octet = valeur as u8;
            let pic = |c: &mut super::Controleur, k: u32| match k {
                0 => c.demande = octet,
                1 => c.masque = octet,
                2 => c.base = octet,
                3 => c.service = octet,
                _ => {}
            };
            match champ {
                0..=3 => pic(&mut puces.maitre, champ),
                10..=13 => pic(&mut puces.esclave, champ - 10),
                20 => puces.uart.diviseur = valeur as u16,
                21 => puces.uart.interruptions = octet,
                _ => {}
            }
        });
    }

    /// **Un champ, pour la façade de `host.js`** (`vm.pics`, `vm.uart`,
    /// `vm.pits`), que les relevés et les tests lisent.
    #[no_mangle]
    extern "C" fn puces_champ(champ: u32) -> i32 {
        avec(|puces, _| {
            let pic = |c: &super::Controleur, k: u32| match k {
                0 => i32::from(c.demande),
                1 => i32::from(c.masque),
                2 => i32::from(c.base),
                3 => i32::from(c.service),
                _ => -1,
            };
            match champ {
                0..=3 => pic(&puces.maitre, champ),
                10..=13 => pic(&puces.esclave, champ - 10),
                20 => i32::from(puces.uart.diviseur),
                21 => i32::from(puces.uart.interruptions),
                30..=32 => puces.compteurs[(champ - 30) as usize].recharge as i32,
                _ => -1,
            }
        })
    }
}
