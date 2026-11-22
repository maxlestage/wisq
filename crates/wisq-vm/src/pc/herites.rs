//! **Les périphériques hérités d'un PC** : deux 8259, un 8253, un 16550 et une
//! horloge CMOS — le port de `X86LegacyDevices.swift`, `X86SerialPort.swift`,
//! des ports de `X86CoreDispatch.swift` et de `X86CMOSClock.swift`.
//!
//! **Pourquoi ceux-là et pas un APIC.** La sonde du contrôleur d'interruptions
//! de Linux est trois lignes — écrire un masque dans le port 0x21 et le relire
//! — et tout le reste en découle ; un APIC demanderait dix fois plus de code
//! pour la même conclusion.
//!
//! **Le temps de l'invité vient du compteur d'instructions**, pas d'une
//! horloge : deux démarrages du même noyau donnent la même chose, et un
//! instantané rend la machine telle quelle. Toutes les fonctions d'ici qui
//! dépendent du temps reçoivent `tics`, le nombre de battements du 8253
//! écoulés ; c'est la machine qui le calcule.

use std::collections::VecDeque;

/// Combien d'instructions valent un battement du 8253 (1,193182 MHz) : la
/// vitesse que l'invité croit à son processeur. Deux cent quatre-vingt-huit
/// font un processeur de 344 MHz — la valeur du cœur Swift, dont le
/// commentaire dit par quelles distributions elle a été mesurée.
pub const INSTRUCTIONS_PAR_BATTEMENT: u64 = 288;

/// La fréquence du 8253, en hertz.
pub const HERTZ_DU_8253: u64 = 1_193_182;

/// L'intervalle le plus court qu'on accorde à un coup unique : quatre
/// millisecondes, le battement d'un noyau à 250 Hz. Un noyau en coup unique ne
/// compte pas les échéances, il lit l'heure au compteur de cycles : en livrer
/// une sur quatre ne lui fait rien perdre, et lui épargne de passer son temps
/// à traiter des échéances.
pub const PLUS_COURT_COUP_UNIQUE: u64 = 4773;

/// Le premier port du 16550.
pub const PORT_SERIE: u16 = 0x3F8;
/// La ligne d'interruption du port série, et celle de l'horloge.
pub const LIGNE_SERIE: u8 = 4;
pub const LIGNE_HORLOGE: u8 = 0;
/// La ligne par laquelle le second 8259 demande au premier.
pub const LIGNE_CASCADE: u8 = 2;

/// Un 8259. Deux en cascade forment le contrôleur d'un PC.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Controleur {
    /// Les lignes masquées. Toutes, tant que le noyau n'a rien dit.
    pub masque: u8,
    /// Les lignes qui demandent, et celles qui sont en cours de service.
    pub demande: u8,
    pub service: u8,
    /// Le vecteur de la ligne zéro. Linux met le maître à 0x20.
    pub base_des_vecteurs: u8,
    /// Où en est la séquence d'initialisation : ICW1 la lance, puis ICW2, ICW3
    /// et ICW4 arrivent par le port de données. Sans ce compte, le premier
    /// octet écrit après ICW1 serait pris pour un masque.
    pub etape: u8,
    /// Ce que le port de commande rend : le registre de demande, ou celui de
    /// service. C'est OCW3 qui choisit.
    pub lit_le_service: bool,
}

impl Default for Controleur {
    fn default() -> Self {
        Self {
            masque: 0xFF,
            demande: 0,
            service: 0,
            base_des_vecteurs: 0,
            etape: 0,
            lit_le_service: false,
        }
    }
}

impl Controleur {
    /// Une écriture sur le port de commande (0x20 ou 0xA0).
    fn commande(&mut self, octet: u8) {
        if octet & 0x10 != 0 {
            self.etape = 1;
        } else if octet & 0x08 != 0 {
            self.lit_le_service = octet & 0x01 != 0;
        } else if octet & 0x20 != 0 {
            // Fin d'interruption. **Deux formes, et Linux envoie la seconde** :
            // `mask_and_ack_8259A` écrit `0x60 + irq`, qui nomme la ligne à
            // retirer du service. Prendre la plus prioritaire à sa place
            // laisserait la ligne nommée en service pour toujours.
            if octet & 0x40 != 0 {
                self.service &= !(1 << (octet & 0x07));
            } else if self.service != 0 {
                self.service &= !(1 << self.service.trailing_zeros());
            }
        }
    }

    /// Une écriture sur le port de données (0x21 ou 0xA1).
    fn donnee(&mut self, octet: u8) {
        match self.etape {
            1 => {
                self.base_des_vecteurs = octet & 0xF8;
                self.etape = 2;
            }
            2 | 3 => {
                self.etape += 1;
                if self.etape > 3 {
                    self.etape = 0;
                }
            }
            _ => self.masque = octet,
        }
    }

    /// La ligne que ce 8259 livrerait maintenant : démasquée, et devant tout
    /// ce qu'il sert déjà. **Une ligne en service bloque ses égales et ses
    /// inférieures** : un gestionnaire rouvre les interruptions avant d'avoir
    /// fini, et sans cette règle la même ligne le réinterromprait aussitôt,
    /// sur sa propre pile.
    pub fn livrable(&self) -> Option<u8> {
        let attente = self.demande & !self.masque;
        if attente == 0 {
            return None;
        }
        let ligne = attente.trailing_zeros() as u8;
        if self.service != 0 && u32::from(ligne) >= self.service.trailing_zeros() {
            return None;
        }
        Some(ligne)
    }

    fn pose(&mut self, ligne: u8, levee: bool) {
        if levee {
            self.demande |= 1 << ligne;
        } else {
            self.demande &= !(1 << ligne);
        }
    }
}

/// Le 16550, tel que le pilote 8250 de Linux le sonde, et pas seulement tel
/// que `printk` l'écrit : la sonde demande que le registre d'autorisation se
/// relise, que la boucle de test du modem renvoie `DCD | CTS`, que le registre
/// de brouillon garde ce qu'on y met, et que l'identification dise s'il y a
/// une FIFO. Puis, pour que l'espace utilisateur écrive, l'interruption
/// d'émission doit arriver.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Serie {
    /// IER : réception (bit 0), émission (bit 1), état de ligne (2), modem (3).
    pub autorisation: u8,
    /// FCR : le bit 0 active la FIFO, que l'identification répète dans ses
    /// deux bits hauts — « 16550A ».
    pub fifo: u8,
    /// LCR : le bit 7 (`DLAB`) fait apparaître le diviseur.
    pub ligne: u8,
    /// MCR : le bit 4 met la puce en boucle sur elle-même.
    pub modem: u8,
    /// SCR : aucun rôle, sinon garder ce qu'on y met.
    pub brouillon: u8,
    /// Le diviseur de bauds. Douze pour 115 200.
    pub diviseur: u16,
    /// L'émission a quelque chose à dire : levée quand on l'autorise ou qu'un
    /// octet part — le transmetteur est vide aussitôt, ici —, acquittée par la
    /// lecture du registre d'identification.
    pub emission_en_attente: bool,
    /// Ce que l'hôte a tapé et que l'invité n'a pas encore lu.
    pub entree: VecDeque<u8>,
    /// Ce que l'invité a écrit et que l'hôte n'a pas encore pris.
    pub sortie: Vec<u8>,
}

impl Serie {
    fn dlab(&self) -> bool {
        self.ligne & 0x80 != 0
    }

    fn boucle(&self) -> bool {
        self.modem & 0x10 != 0
    }

    /// La ligne quatre demande. Réception avant émission, comme sur la puce.
    pub fn interrompt(&self) -> bool {
        if self.autorisation & 0x01 != 0 && !self.entree.is_empty() {
            return true;
        }
        self.autorisation & 0x02 != 0 && self.emission_en_attente
    }

    pub fn ecrire(&mut self, registre: u16, octet: u8) {
        match registre {
            0 if self.dlab() => self.diviseur = (self.diviseur & 0xFF00) | u16::from(octet),
            1 if self.dlab() => self.diviseur = (self.diviseur & 0x00FF) | (u16::from(octet) << 8),
            0 => {
                // En boucle, l'octet revient par la réception ; sinon il sort.
                if self.boucle() {
                    self.entree.push_back(octet);
                } else {
                    self.sortie.push(octet);
                }
                self.emission_en_attente = true;
            }
            1 => {
                let avant = self.autorisation;
                self.autorisation = octet & 0x0F;
                if octet & 0x02 != 0 && avant & 0x02 == 0 {
                    self.emission_en_attente = true;
                }
            }
            2 => self.fifo = octet,
            3 => self.ligne = octet,
            4 => self.modem = octet & 0x1F,
            7 => self.brouillon = octet,
            _ => {}
        }
    }

    pub fn lire(&mut self, registre: u16) -> u8 {
        match registre {
            0 if self.dlab() => self.diviseur as u8,
            1 if self.dlab() => (self.diviseur >> 8) as u8,
            0 => self.entree.pop_front().unwrap_or(0),
            1 => self.autorisation,
            2 => {
                // L'identification : la cause la plus prioritaire, bit 0 à
                // zéro quand il y en a une, et la FIFO dans les deux bits
                // hauts.
                let fifo = if self.fifo & 0x01 != 0 { 0xC0 } else { 0 };
                if self.autorisation & 0x01 != 0 && !self.entree.is_empty() {
                    return fifo | 0x04;
                }
                if self.autorisation & 0x02 != 0 && self.emission_en_attente {
                    self.emission_en_attente = false;
                    return fifo | 0x02;
                }
                fifo | 0x01
            }
            3 => self.ligne,
            4 => self.modem,
            // L'état de la ligne : « le transmetteur est vide ». Sans ça, un
            // noyau attend indéfiniment de pouvoir écrire.
            5 => 0x60 | u8::from(!self.entree.is_empty()),
            6 => {
                // En boucle, les sorties reviennent sur les entrées : DTR →
                // DSR, RTS → CTS, OUT1 → RI, OUT2 → DCD. Sinon, un câble
                // branché.
                if !self.boucle() {
                    return 0xB0;
                }
                let controle = self.modem;
                (if controle & 0x01 != 0 { 0x20 } else { 0 })
                    | (if controle & 0x02 != 0 { 0x10 } else { 0 })
                    | (if controle & 0x04 != 0 { 0x40 } else { 0 })
                    | (if controle & 0x08 != 0 { 0x80 } else { 0 })
            }
            7 => self.brouillon,
            _ => 0,
        }
    }
}

/// Le 8253 : le canal zéro, qui bat, et le canal deux, par lequel Linux
/// étalonne son compteur de cycles.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Minuterie {
    /// La valeur de rechargement du canal zéro.
    pub rechargement: u16,
    /// L'état d'accès du canal zéro : le 8253 se lit et s'écrit un octet à la
    /// fois, et se souvient duquel c'est le tour.
    pub ecrit_le_haut: bool,
    pub lit_le_haut: bool,
    /// La valeur figée par une commande de verrouillage, s'il y en a une.
    pub verrou: Option<u16>,
    /// Le battement du dernier rechargement, pour compter à partir de là.
    pub recharge_a: u64,
    /// Le canal zéro programmé pour **un** coup (modes 0 et 4, et leurs
    /// variantes à porte), et non pour battre (modes 2 et 3). C'est ce que
    /// fait Linux dès que son horloge de référence est le compteur de cycles —
    /// l'horloge sans tic : il réarme le canal à chaque échéance.
    pub coup_unique: bool,
    /// Combien d'interruptions zéro ont déjà été levées : ce qui évite d'en
    /// lever deux pour le même battement.
    pub levees: u64,
    /// Le canal deux : il ne bat pas, il compte une fois jusqu'à zéro, et le
    /// port 0x61 dit quand c'est fait.
    pub haut_parleur: u16,
    pub haut_parleur_ecrit_le_haut: bool,
    pub haut_parleur_lit_le_haut: bool,
    pub haut_parleur_parti_a: u64,
    pub porte: bool,
}

impl Minuterie {
    /// La période du canal zéro, en battements.
    fn periode(&self) -> u64 {
        if self.coup_unique {
            u64::from(self.rechargement).max(PLUS_COURT_COUP_UNIQUE)
        } else {
            u64::from(self.rechargement)
        }
    }

    /// Le compte du canal zéro, tel qu'une lecture le verrait.
    pub fn compte(&self, tics: u64) -> u16 {
        if self.rechargement == 0 {
            return 0;
        }
        let ecoule = tics.wrapping_sub(self.recharge_a) % u64::from(self.rechargement);
        (u64::from(self.rechargement) - ecoule) as u16
    }

    /// Combien de fois le canal zéro a débordé depuis son rechargement.
    pub fn echeances(&self, tics: u64) -> u64 {
        if self.rechargement == 0 {
            return 0;
        }
        tics.wrapping_sub(self.recharge_a) / self.periode()
    }

    /// Le battement de la prochaine échéance pas encore levée.
    pub fn prochaine(&self) -> Option<u64> {
        if self.rechargement == 0 {
            return None;
        }
        Some(
            self.recharge_a
                .wrapping_add((self.levees + 1).wrapping_mul(self.periode())),
        )
    }

    /// Ce que le bit 5 du port 0x61 rend : « le canal deux est arrivé à zéro ».
    pub fn haut_parleur_fini(&self, tics: u64) -> bool {
        self.porte
            && self.haut_parleur != 0
            && tics.wrapping_sub(self.haut_parleur_parti_a) >= u64::from(self.haut_parleur)
    }

    /// Ce qu'une lecture du canal deux rend.
    pub fn compte_du_haut_parleur(&self, tics: u64) -> u16 {
        if !self.porte || self.haut_parleur == 0 {
            return self.haut_parleur;
        }
        let ecoule = tics.wrapping_sub(self.haut_parleur_parti_a);
        if ecoule >= u64::from(self.haut_parleur) {
            0
        } else {
            self.haut_parleur - ecoule as u16
        }
    }
}

/// **Une horloge CMOS minimale** (MC146818, ports 0x70 et 0x71) : la date, lue
/// en BCD et sur vingt-quatre heures, et cent vingt-huit octets de mémoire.
///
/// L'heure est celle que l'hôte a donnée (`regler`), en secondes depuis 1970 ;
/// rien n'est lu au système ici, pour que deux machines réglées pareil lisent
/// la même date. Le noyau ne la lit qu'une fois, au démarrage. L'écriture de
/// la date n'est pas portée : la carte de `wisq-page`, qui a la sienne, la
/// remplacera quand elle sera branchée.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct HorlogeCmos {
    pub index: u8,
    /// Le registre B : binaire (bit 2), vingt-quatre heures (bit 1).
    pub etat_b: u8,
    pub secondes_depuis_1970: u64,
    pub memoire: [u8; 128],
}

impl Default for HorlogeCmos {
    fn default() -> Self {
        Self {
            index: 0,
            etat_b: 0x02,
            secondes_depuis_1970: 0,
            memoire: [0; 128],
        }
    }
}

impl HorlogeCmos {
    pub fn regler(&mut self, secondes_depuis_1970: u64) {
        self.secondes_depuis_1970 = secondes_depuis_1970;
    }

    fn choisir(&mut self, octet: u8) {
        self.index = octet & 0x7F;
    }

    /// La date civile (UTC) : année, mois, jour, heure, minute, seconde, jour
    /// de la semaine (1 = dimanche). L'algorithme des jours est celui de
    /// Howard Hinnant, sans table.
    pub fn date(&self) -> [u64; 7] {
        let jours = self.secondes_depuis_1970 / 86_400;
        let reste = self.secondes_depuis_1970 % 86_400;
        let z = jours + 719_468;
        let ere = z / 146_097;
        let jour_de_l_ere = z % 146_097;
        let annee_de_l_ere = (jour_de_l_ere - jour_de_l_ere / 1460 + jour_de_l_ere / 36_524
            - jour_de_l_ere / 146_096)
            / 365;
        let jour_de_l_annee =
            jour_de_l_ere - (365 * annee_de_l_ere + annee_de_l_ere / 4 - annee_de_l_ere / 100);
        let mp = (5 * jour_de_l_annee + 2) / 153;
        let jour = jour_de_l_annee - (153 * mp + 2) / 5 + 1;
        let mois = if mp < 10 { mp + 3 } else { mp - 9 };
        let annee = annee_de_l_ere + ere * 400 + u64::from(mois <= 2);
        // Le premier janvier 1970 était un jeudi : le cinquième jour.
        let semaine = (jours + 4) % 7 + 1;
        [
            annee,
            mois,
            jour,
            reste / 3600,
            reste % 3600 / 60,
            reste % 60,
            semaine,
        ]
    }

    fn encode(&self, valeur: u64) -> u8 {
        if self.etat_b & 0x04 != 0 {
            valeur as u8
        } else {
            (((valeur / 10) << 4) | (valeur % 10)) as u8
        }
    }

    fn lire(&self) -> u8 {
        let [annee, mois, jour, heure, minute, seconde, semaine] = self.date();
        match self.index {
            0x00 => self.encode(seconde),
            0x02 => self.encode(minute),
            0x04 => self.encode(heure),
            0x06 => self.encode(semaine),
            0x07 => self.encode(jour),
            0x08 => self.encode(mois),
            0x09 => self.encode(annee % 100),
            0x32 => self.encode(annee / 100),
            // Le registre A : aucune mise à jour en cours, 32,768 kHz.
            0x0A => 0x26,
            0x0B => self.etat_b,
            0x0C => 0,
            // Le registre D : la pile est bonne.
            0x0D => 0x80,
            autre => self.memoire[usize::from(autre)],
        }
    }

    fn ecrire(&mut self, octet: u8) {
        match self.index {
            0x0B => self.etat_b = octet,
            0x00 | 0x02 | 0x04 | 0x06 | 0x07 | 0x08 | 0x09 | 0x32 | 0x0A | 0x0C | 0x0D => {}
            autre => self.memoire[usize::from(autre)] = octet,
        }
    }
}

/// Ce qu'un 8259 propose de livrer.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Candidat {
    pub vecteur: u8,
    /// La ligne du maître.
    pub ligne: u8,
    /// La ligne du second contrôleur, quand c'est lui qui demande par la
    /// cascade.
    pub seconde: Option<u8>,
}

/// Les périphériques hérités, ensemble.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Herites {
    pub maitre: Controleur,
    pub second: Controleur,
    pub minuterie: Minuterie,
    pub serie: Serie,
    pub cmos: HorlogeCmos,
    /// **Une autre horloge CMOS répond aux ports 0x70 et 0x71** : celle de
    /// la carte (`pc::carte::brancher`), complète — le réglage de la date par
    /// l'invité, l'heure qui avance. Celle-ci se tait alors.
    pub cmos_ailleurs: bool,
}

impl Herites {
    /// **Lire un port.** `None` quand aucun de ces périphériques n'y répond.
    pub fn port_lire(&mut self, port: u16, tics: u64) -> Option<u32> {
        let octet = match port {
            PORT_SERIE..=0x3FF => self.serie.lire(port - PORT_SERIE),
            0x20 => {
                if self.maitre.lit_le_service {
                    self.maitre.service
                } else {
                    self.maitre.demande
                }
            }
            // Le masque relu. C'est **toute** la sonde de Linux : il écrit une
            // valeur dans ce port et la relit ; si elle ne revient pas, il
            // conclut qu'il n'y a pas de contrôleur — `Using NULL legacy PIC`.
            0x21 => self.maitre.masque,
            0xA0 => {
                if self.second.lit_le_service {
                    self.second.service
                } else {
                    self.second.demande
                }
            }
            0xA1 => self.second.masque,
            0x71 if !self.cmos_ailleurs => self.cmos.lire(),
            0x61 => {
                // Le bit 5 : « le canal deux est arrivé à zéro ». Le bit 4
                // change à chaque rafraîchissement mémoire sur un vrai PC ; le
                // faire basculer évite qu'un noyau qui l'attend tourne
                // indéfiniment.
                (if self.minuterie.haut_parleur_fini(tics) {
                    0x20
                } else {
                    0
                }) | ((tics & 1) as u8) << 4
                    | u8::from(self.minuterie.porte)
            }
            0x42 => {
                let compte = self.minuterie.compte_du_haut_parleur(tics);
                let haut = self.minuterie.haut_parleur_lit_le_haut;
                self.minuterie.haut_parleur_lit_le_haut = !haut;
                if haut {
                    (compte >> 8) as u8
                } else {
                    compte as u8
                }
            }
            0x40 => {
                let valeur = self
                    .minuterie
                    .verrou
                    .unwrap_or_else(|| self.minuterie.compte(tics));
                let haut = self.minuterie.lit_le_haut;
                self.minuterie.lit_le_haut = !haut;
                if haut {
                    // Le second octet lu : le verrou a servi.
                    self.minuterie.verrou = None;
                    (valeur >> 8) as u8
                } else {
                    valeur as u8
                }
            }
            _ => return None,
        };
        Some(u32::from(octet))
    }

    /// **Écrire un port.** `false` quand aucun de ces périphériques n'y répond.
    pub fn port_ecrire(&mut self, port: u16, valeur: u32, tics: u64) -> bool {
        let octet = valeur as u8;
        match port {
            PORT_SERIE..=0x3FF => self.serie.ecrire(port - PORT_SERIE, octet),
            0x20 => self.maitre.commande(octet),
            0x21 => self.maitre.donnee(octet),
            0xA0 => self.second.commande(octet),
            0xA1 => self.second.donnee(octet),
            0x70 if !self.cmos_ailleurs => self.cmos.choisir(octet),
            0x71 if !self.cmos_ailleurs => self.cmos.ecrire(octet),
            0x61 => {
                // Le port B : le bit 0 ouvre la porte du canal deux. C'est par
                // là que Linux étalonne son compteur de cycles — il lance le
                // canal, puis attend que le bit 5 lui dise que c'est fini.
                let ouverte = octet & 0x01 != 0;
                if ouverte && !self.minuterie.porte {
                    self.minuterie.haut_parleur_parti_a = tics;
                }
                self.minuterie.porte = ouverte;
            }
            0x42 => {
                let m = &mut self.minuterie;
                if m.haut_parleur_ecrit_le_haut {
                    m.haut_parleur = (m.haut_parleur & 0x00FF) | (u16::from(octet) << 8);
                    m.haut_parleur_ecrit_le_haut = false;
                    m.haut_parleur_parti_a = tics;
                } else {
                    m.haut_parleur = (m.haut_parleur & 0xFF00) | u16::from(octet);
                    m.haut_parleur_ecrit_le_haut = true;
                }
            }
            0x43 if octet >> 6 == 2 => {
                self.minuterie.haut_parleur_ecrit_le_haut = false;
                self.minuterie.haut_parleur_lit_le_haut = false;
            }
            0x43 => {
                if octet >> 6 != 0 {
                    return true;
                }
                let m = &mut self.minuterie;
                if (octet >> 4) & 0x03 == 0 {
                    // Commande de verrouillage : figer le compte pour qu'une
                    // lecture en deux octets voie la **même** valeur deux fois.
                    m.verrou = Some(m.compte(tics));
                    m.lit_le_haut = false;
                } else {
                    m.ecrit_le_haut = false;
                    m.lit_le_haut = false;
                    m.verrou = None;
                    // Les bits 1 à 3 : le mode. 0 et 4 (et leurs variantes à
                    // porte, 1 et 5) comptent une fois ; 2 et 3 battent.
                    m.coup_unique = (octet >> 1) & 0x03 <= 1;
                }
            }
            0x40 => {
                let m = &mut self.minuterie;
                if m.ecrit_le_haut {
                    m.rechargement = (m.rechargement & 0x00FF) | (u16::from(octet) << 8);
                    m.ecrit_le_haut = false;
                    // Un rechargement repart de maintenant, et ce qui était dû
                    // avant ne l'est plus.
                    m.recharge_a = tics;
                    m.levees = 0;
                } else {
                    m.rechargement = (m.rechargement & 0xFF00) | u16::from(octet);
                    m.ecrit_le_haut = true;
                }
            }
            _ => return false,
        }
        true
    }

    /// **Lever ce qui est dû**, sans rien livrer : l'horloge par front, le port
    /// série et les lignes des autres périphériques (`lignes`, un bit par
    /// ligne de 0 à 15) à niveau — la demande suit la condition, dans les deux
    /// sens —, puis la cascade.
    ///
    /// Les lignes 0, 2 et 4 appartiennent à cette carte : ce que `lignes` en
    /// dirait est ignoré.
    pub fn lever(&mut self, tics: u64, lignes: u16) {
        let dues = self.minuterie.echeances(tics);
        if dues > self.minuterie.levees {
            self.minuterie.levees = dues;
            self.maitre.demande |= 1 << LIGNE_HORLOGE;
        }
        self.maitre.pose(LIGNE_SERIE, self.serie.interrompt());
        // Les autres lignes recopiées à niveau, d'un coup : toutes celles du
        // second, et celles du maître sauf l'horloge, la cascade et le port
        // série, qui sont à cette carte. (Une ligne après l'autre, la boucle
        // pesait le tiers de ce service, fait toutes les deux cent
        // cinquante-six instructions.)
        const A_LA_CARTE: u8 = (1 << LIGNE_HORLOGE) | (1 << LIGNE_CASCADE) | (1 << LIGNE_SERIE);
        self.maitre.demande = (self.maitre.demande & A_LA_CARTE) | (lignes as u8 & !A_LA_CARTE);
        self.second.demande = (lignes >> 8) as u8;
        // **La cascade** : le second demande par la ligne 2 du maître, quand
        // une de ses lignes est démasquée et passe devant ce qu'il sert déjà.
        self.maitre
            .pose(LIGNE_CASCADE, self.second.livrable().is_some());
    }

    /// Ce que le contrôleur livrerait maintenant, si le processeur l'accepte.
    pub fn candidat(&self) -> Option<Candidat> {
        let ligne = self.maitre.livrable()?;
        if ligne == LIGNE_CASCADE {
            if let Some(seconde) = self.second.livrable() {
                return Some(Candidat {
                    vecteur: self.second.base_des_vecteurs.wrapping_add(seconde),
                    ligne,
                    seconde: Some(seconde),
                });
            }
        }
        Some(Candidat {
            vecteur: self.maitre.base_des_vecteurs.wrapping_add(ligne),
            ligne,
            seconde: None,
        })
    }

    /// Le processeur est entré dans le gestionnaire : la demande passe en
    /// service. **Seulement alors** — une demande que rien n'a pu livrer
    /// reste, et le noyau la trouvera quand il aura posé sa porte.
    pub fn livree(&mut self, candidat: Candidat) {
        if let Some(seconde) = candidat.seconde {
            // Les deux gardent la ligne en service jusqu'à leur fin
            // d'interruption — Linux l'envoie aux deux.
            self.second.demande &= !(1 << seconde);
            self.second.service |= 1 << seconde;
        }
        self.maitre.demande &= !(1 << candidat.ligne);
        self.maitre.service |= 1 << candidat.ligne;
    }

    /// Vrai quand quelque chose de cette carte peut arriver : une horloge
    /// armée, ou un port série dont on a autorisé la réception ou l'émission.
    pub fn armes(&self) -> bool {
        self.minuterie.rechargement != 0 || self.serie.autorisation & 0x03 != 0
    }
}
