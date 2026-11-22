//! **Le contrôleur de clavier du PC, un i8042, et ses deux appareils** : le
//! clavier sur la ligne 1, la souris PS/2 sur la ligne 12. Porté depuis
//! `X86PS2Controller` du cœur Swift (`Sources/WisqVM/X86PS2.swift`), commande
//! pour commande, octet pour octet.
//!
//! **Pourquoi lui.** Un bureau Linux veut un clavier et un pointeur, et le
//! noyau d'une distribution les cherche d'abord ici — `i8042`, `atkbd`,
//! `psmouse` sont compilés dedans ou chargés tôt. Sans ces deux ports, le
//! noyau dit « i8042: Can't read CTR while initializing i8042 » et renonce :
//! c'est ce que la page lui répond aujourd'hui (`0xff`, personne).
//!
//! **Ce qui est tenu** : le registre de configuration (CTR), les commandes du
//! contrôleur que Linux envoie — lecture et écriture du CTR, tests,
//! activation et désactivation des deux ports, bouclage de la souris (`D3`),
//! envoi à la souris (`D4`) — et celles des deux appareils : remise à zéro,
//! identification, activation, réglages qui se contentent d'un accusé. Et la
//! **ligne de remise à zéro** du processeur, que Linux tire par `0xFE` sur le
//! port de commande pour redémarrer.
//!
//! **Les codes de touche** sont ceux du jeu 1, quand le contrôleur traduit
//! (bit 6 du CTR, ce que Linux laisse), et du jeu 2 sinon. La souris parle en
//! paquets de trois octets : boutons et signes, puis X, puis Y, Y vers le
//! haut.

use std::collections::VecDeque;

use super::etat::{Ecrivain, Lecteur};

pub const PORT_DONNEES: u16 = 0x60;
pub const PORT_COMMANDE: u16 = 0x64;
pub const LIGNE_CLAVIER: u8 = 1;
pub const LIGNE_SOURIS: u8 = 12;

/// Les bits du CTR.
const INTERRUPTION_CLAVIER: u8 = 0x01;
const INTERRUPTION_SOURIS: u8 = 0x02;
const CLAVIER_COUPE: u8 = 0x10;
const SOURIS_COUPEE: u8 = 0x20;
const TRADUCTION: u8 = 0x40;

/// **Les frappes de l'hôte, au rythme d'une main.** L'application tape un
/// texte d'un coup ; posées telles quelles, presser et relâcher une touche
/// tenaient en dix-huit microsecondes de l'invité. Le noyau les voyait toutes
/// (`evtest` les montrait, une à une), et le terminal d'Xfce n'en affichait
/// **aucune**. Tenues une seconde au contraire, Xorg les répétait :
/// « chhhhhhhhhhooooooooo ». Trente millisecondes tenue, vingt entre deux
/// touches, en tics du 8254 (1,193182 MHz) : les nombres du cœur Swift.
pub const TENUE_TICS: u64 = 35_795;
pub const ECART_TICS: u64 = 23_864;
/// **Une file bornée** : un collage démesuré ne fait pas grossir la machine.
///
/// La borne ne doit jamais couper une touche en deux. Une file pleine qui
/// gardait l'enfoncement et jetait le relâchement laissait la touche (et Maj)
/// enfoncées dans l'invité, et Xorg la répétait sans fin. D'où deux règles :
/// un texte entre caractère par caractère, entier ou pas du tout
/// ([`I8042::taper_groupe`]), et le relâchement d'une touche que la file
/// laisse enfoncée passe toujours ([`I8042::taper`]). La file peut donc
/// dépasser la borne, de [`TOUCHES`] relâchements au plus.
pub const LIMITE_DE_FRAPPE: usize = 8192;
/// Le nombre de touches distinctes : un code du jeu 1 sur un octet, avec ou
/// sans `E0`.
pub const TOUCHES: usize = 512;

/// **Une touche du PC**, par son code du jeu 1 et son préfixe `E0`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CodeTouche {
    pub jeu1: u8,
    pub etendue: bool,
}

impl CodeTouche {
    pub const fn simple(jeu1: u8) -> Self {
        Self {
            jeu1,
            etendue: false,
        }
    }
    pub const fn etendue(jeu1: u8) -> Self {
        Self {
            jeu1,
            etendue: true,
        }
    }

    pub const ENTREE: Self = Self::simple(0x1C);
    pub const MAJ_GAUCHE: Self = Self::simple(0x2A);
    pub const ESPACE: Self = Self::simple(0x39);
    pub const HAUT: Self = Self::etendue(0x48);
}

/// Un octet qui attend au port 0x60, et de quel appareil il vient.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Sortie {
    pub octet: u8,
    pub de_la_souris: bool,
}

/// Une frappe de l'hôte en attente de son tour.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Frappe {
    pub code: CodeTouche,
    pub enfoncee: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct I8042 {
    /// Ce qu'un BIOS laisse : les deux interruptions, le drapeau système, la
    /// traduction, la souris éteinte jusqu'à ce que le noyau l'allume.
    pub configuration: u8,
    /// Ce qui attend d'être lu au port 0x60. Le premier octet décide de
    /// l'état et de la ligne.
    pub sortie: VecDeque<Sortie>,
    /// La commande du contrôleur qui attend son octet au port 0x60.
    commande_en_attente: Option<u8>,
    /// La commande d'un appareil qui attend son paramètre.
    parametre_du_clavier: Option<u8>,
    parametre_de_la_souris: Option<u8>,
    /// Le dernier octet écrit l'a été au port de commande : bit 3 de l'état.
    derniere_ecriture_commande: bool,
    /// Les touches perdues, et pourquoi : le clavier ne balayait pas (`F5`),
    /// ou le contrôleur avait coupé son port (`AD`).
    pub perdues_sans_balayage: u32,
    pub perdues_port_coupe: u32,
    /// La souris envoie-t-elle ses mouvements (`F4`) ?
    pub souris_rapporte: bool,
    /// Le clavier envoie-t-il ses touches ? Allumé au départ, comme un vrai.
    pub clavier_balaye: bool,
    /// **La ligne de remise à zéro du processeur**, que le 8042 tient sur le
    /// bit zéro de son port de sortie. Linux la tire pour redémarrer, juste
    /// après ACPI qu'il n'y a pas : `outb(0xfe, 0x64)`. Sans elle, le noyau
    /// passe au saut long vers le code en mode réel du BIOS, que l'émetteur
    /// n'exécute pas. Elle reste tirée : c'est la boucle hôte qui la lit et
    /// rend « redémarrage », et une machine neuve qui repart à zéro.
    pub remise_demandee: bool,
    /// Les frappes de l'hôte, posées une à une par [`I8042::rythmer`].
    pub frappes: VecDeque<Frappe>,
    /// Le tic avant lequel rien d'autre ne part.
    frappe_reprend_a: u64,
    /// **Les touches que la file laisse enfoncées** : celles dont la dernière
    /// frappe admise est un enfoncement, un bit par touche (rang
    /// [`rang_de_touche`]). C'est l'état de l'invité une fois la file jouée
    /// jusqu'au bout ; qu'une frappe parte ne le change donc pas.
    enfoncees_en_file: [u64; TOUCHES / 64],
}

impl Default for I8042 {
    fn default() -> Self {
        Self::nouveau()
    }
}

impl I8042 {
    pub const fn nouveau() -> Self {
        Self {
            configuration: 0x47 | SOURIS_COUPEE,
            sortie: VecDeque::new(),
            commande_en_attente: None,
            parametre_du_clavier: None,
            parametre_de_la_souris: None,
            derniere_ecriture_commande: false,
            perdues_sans_balayage: 0,
            perdues_port_coupe: 0,
            souris_rapporte: false,
            clavier_balaye: true,
            remise_demandee: false,
            frappes: VecDeque::new(),
            frappe_reprend_a: 0,
            enfoncees_en_file: [0; TOUCHES / 64],
        }
    }

    // --- Les ports ---

    /// L'état (0x64) : sortie pleine, système, commande, clavier non
    /// verrouillé, et sortie souris. Le bit 4 à zéro dirait « clavier
    /// verrouillé » : Linux l'a vu et l'a écrit, « i8042: Warning: Keylock
    /// active ».
    pub fn etat(&self) -> u8 {
        let mut valeur = 0x04 | 0x10;
        if let Some(premier) = self.sortie.front() {
            valeur |= 0x01;
            if premier.de_la_souris {
                valeur |= 0x20;
            }
        }
        if self.derniere_ecriture_commande {
            valeur |= 0x08;
        }
        valeur
    }

    pub fn lire_donnee(&mut self) -> u8 {
        self.sortie.pop_front().map_or(0, |sortie| sortie.octet)
    }

    pub fn ecrire_commande(&mut self, commande: u8) {
        self.derniere_ecriture_commande = true;
        self.commande_en_attente = None;
        match commande {
            0x20 => self.repondre(self.configuration, false),
            0x60 | 0xD1 | 0xD2 | 0xD3 | 0xD4 => self.commande_en_attente = Some(commande),
            0xA7 => self.configuration |= SOURIS_COUPEE,
            0xA8 => self.configuration &= !SOURIS_COUPEE,
            // Les deux ports se testent bien.
            0xA9 | 0xAB => self.repondre(0x00, false),
            // Le contrôleur se teste bien.
            0xAA => self.repondre(0x55, false),
            0xAD => self.configuration |= CLAVIER_COUPE,
            0xAE => self.configuration &= !CLAVIER_COUPE,
            // Le port de sortie : la ligne de remise à zéro au repos.
            0xD0 => self.repondre(0x01, false),
            // Une impulsion sur les lignes du port de sortie dont le bit est
            // à zéro : le bit zéro, c'est la remise à zéro.
            0xF0..=0xFF if commande & 0x01 == 0 => self.remise_demandee = true,
            _ => {}
        }
    }

    pub fn ecrire_donnee(&mut self, octet: u8) {
        self.derniere_ecriture_commande = false;
        if let Some(commande) = self.commande_en_attente.take() {
            match commande {
                0x60 => self.configuration = octet,
                // Le port de sortie écrit d'un coup : le bit zéro à zéro tire
                // la même ligne. Linux y écrit `0xDF` pour ouvrir la porte
                // A20, bit zéro à un : la machine tourne.
                0xD1 if octet & 0x01 == 0 => self.remise_demandee = true,
                0xD2 => self.repondre(octet, false),
                // Le bouclage : Linux s'en sert pour savoir s'il y a un port
                // de souris, en lisant l'octet revenu « de la souris ».
                0xD3 => self.repondre(octet, true),
                0xD4 => self.commande_de_la_souris(octet),
                _ => {}
            }
            return;
        }
        self.commande_du_clavier(octet);
    }

    // --- Les appareils ---

    fn commande_du_clavier(&mut self, octet: u8) {
        if let Some(commande) = self.parametre_du_clavier.take() {
            self.repondre(0xFA, false);
            // `F0 00` demande le jeu en cours : le 2, que le contrôleur
            // traduit.
            if commande == 0xF0 && octet == 0 {
                self.repondre(if self.traduit() { 0x41 } else { 0x02 }, false);
            }
            return;
        }
        match octet {
            0xFF => {
                self.clavier_balaye = true;
                self.repondre(0xFA, false);
                self.repondre(0xAA, false);
            }
            0xF2 => {
                // L'identification d'un clavier MF2 : AB 83, que le
                // contrôleur traduit en AB 41.
                self.repondre(0xFA, false);
                self.repondre(0xAB, false);
                self.repondre(if self.traduit() { 0x41 } else { 0x83 }, false);
            }
            0xF4 | 0xF6 => {
                self.clavier_balaye = true;
                self.repondre(0xFA, false);
            }
            0xF5 => {
                self.clavier_balaye = false;
                self.repondre(0xFA, false);
            }
            0xED | 0xF3 | 0xF0 => {
                self.parametre_du_clavier = Some(octet);
                self.repondre(0xFA, false);
            }
            0xEE => self.repondre(0xEE, false),
            _ => self.repondre(0xFA, false),
        }
    }

    fn commande_de_la_souris(&mut self, octet: u8) {
        if self.parametre_de_la_souris.take().is_some() {
            self.repondre(0xFA, true);
            return;
        }
        match octet {
            0xFF => {
                self.souris_rapporte = false;
                for reponse in [0xFA, 0xAA, 0x00] {
                    self.repondre(reponse, true);
                }
            }
            // Une souris standard, sans molette : identifiant zéro.
            0xF2 => {
                self.repondre(0xFA, true);
                self.repondre(0x00, true);
            }
            0xF4 => {
                self.souris_rapporte = true;
                self.repondre(0xFA, true);
            }
            0xF5 | 0xF6 => {
                self.souris_rapporte = false;
                self.repondre(0xFA, true);
            }
            0xF3 | 0xE8 => {
                self.parametre_de_la_souris = Some(octet);
                self.repondre(0xFA, true);
            }
            0xE9 => {
                // L'état : flux, désactivée ou non, quatre comptes par
                // millimètre, cent paquets par seconde.
                let rapporte = if self.souris_rapporte { 0x20 } else { 0x00 };
                for reponse in [0xFA, rapporte, 0x02, 100] {
                    self.repondre(reponse, true);
                }
            }
            0xEB => {
                self.repondre(0xFA, true);
                for octet in paquet(0, 0, 0) {
                    self.repondre(octet, true);
                }
            }
            _ => self.repondre(0xFA, true),
        }
    }

    fn repondre(&mut self, octet: u8, de_la_souris: bool) {
        self.sortie.push_back(Sortie {
            octet,
            de_la_souris,
        });
    }

    fn traduit(&self) -> bool {
        self.configuration & TRADUCTION != 0
    }

    // --- Ce que l'hôte envoie ---

    /// **Une frappe de l'hôte**, à poser quand son tour viendra
    /// ([`I8042::rythmer`]). Rend `false` si la file pleine la refuse.
    ///
    /// Un enfoncement n'entre que sous la borne. Le relâchement d'une touche
    /// que la file laisse enfoncée entre toujours, même au-delà : le refuser
    /// laisserait la touche enfoncée dans l'invité pour de bon. Un autre
    /// relâchement (d'une touche déjà relevée) n'entre que sous la borne,
    /// comme un enfoncement, pour que rien ne fasse grossir la file sans fin.
    pub fn taper(&mut self, code: CodeTouche, enfoncee: bool) -> bool {
        let (mot, bit) = rang_de_touche(code);
        let tenue = self.enfoncees_en_file[mot] & bit != 0;
        if self.frappes.len() >= LIMITE_DE_FRAPPE && (enfoncee || !tenue) {
            return false;
        }
        self.poser(Frappe { code, enfoncee });
        true
    }

    /// **Des frappes qui vont ensemble** (un caractère : Maj, la touche
    /// enfoncée puis relâchée, Maj), admises toutes ou aucune : `false`, et
    /// rien en file, si elles ne tiennent pas entières sous la borne.
    pub fn taper_groupe(&mut self, groupe: &[Frappe]) -> bool {
        if self.frappes.len().saturating_add(groupe.len()) > LIMITE_DE_FRAPPE {
            return false;
        }
        for &frappe in groupe {
            self.poser(frappe);
        }
        true
    }

    fn poser(&mut self, frappe: Frappe) {
        let (mot, bit) = rang_de_touche(frappe.code);
        if frappe.enfoncee {
            self.enfoncees_en_file[mot] |= bit;
        } else {
            self.enfoncees_en_file[mot] &= !bit;
        }
        self.frappes.push_back(frappe);
    }

    /// Pose la frappe suivante si son heure est venue, à `maintenant` tics du
    /// 8254 : une à la fois, et seulement quand le noyau a lu ce qui précède.
    pub fn rythmer(&mut self, maintenant: u64) {
        if maintenant < self.frappe_reprend_a || !self.sortie.is_empty() {
            return;
        }
        let Some(suivante) = self.frappes.pop_front() else {
            return;
        };
        self.touche(suivante.code, suivante.enfoncee);
        self.frappe_reprend_a = maintenant.wrapping_add(if suivante.enfoncee {
            TENUE_TICS
        } else {
            ECART_TICS
        });
    }

    /// Une touche, en codes du jeu 1 — `E0` compris pour les touches
    /// étendues —, enfoncée ou relâchée, posée tout de suite. Traduite en
    /// jeu 2 quand le noyau a coupé la traduction.
    pub fn touche(&mut self, code: CodeTouche, enfoncee: bool) {
        if !self.clavier_balaye {
            self.perdues_sans_balayage = self.perdues_sans_balayage.wrapping_add(1);
            return;
        }
        if self.configuration & CLAVIER_COUPE != 0 {
            self.perdues_port_coupe = self.perdues_port_coupe.wrapping_add(1);
            return;
        }
        if self.traduit() {
            if code.etendue {
                self.repondre(0xE0, false);
            }
            self.repondre(
                if enfoncee {
                    code.jeu1
                } else {
                    code.jeu1 | 0x80
                },
                false,
            );
        } else {
            let Some(jeu2) = jeu2_de(code.jeu1) else {
                return;
            };
            if code.etendue {
                self.repondre(0xE0, false);
            }
            if !enfoncee {
                self.repondre(0xF0, false);
            }
            self.repondre(jeu2, false);
        }
    }

    /// Un mouvement de souris, en comptes, Y vers le **bas** comme à l'écran ;
    /// le paquet le retourne. Découpé en pas de ±255, ce qu'un paquet porte.
    pub fn souris(&mut self, dx: i32, dy: i32, boutons: u8) {
        if !self.souris_rapporte || self.configuration & SOURIS_COUPEE != 0 {
            return;
        }
        // En `i64` : retourner `i32::MIN` ne déborde pas.
        let (mut reste_x, mut reste_y) = (i64::from(dx), -i64::from(dy));
        loop {
            let pas_x = reste_x.clamp(-255, 255);
            let pas_y = reste_y.clamp(-255, 255);
            reste_x -= pas_x;
            reste_y -= pas_y;
            for octet in paquet(pas_x, pas_y, boutons) {
                self.repondre(octet, true);
            }
            if reste_x == 0 && reste_y == 0 {
                break;
            }
        }
    }

    // --- Les lignes ---

    /// La ligne 1 : un octet du clavier attend, et le noyau veut être
    /// prévenu. À niveau, comme le port série.
    pub fn clavier_interrompt(&self) -> bool {
        matches!(self.sortie.front(), Some(premier) if !premier.de_la_souris)
            && self.configuration & INTERRUPTION_CLAVIER != 0
    }

    /// La ligne 12 : de même, pour la souris.
    pub fn souris_interrompt(&self) -> bool {
        matches!(self.sortie.front(), Some(premier) if premier.de_la_souris)
            && self.configuration & INTERRUPTION_SOURIS != 0
    }
}

/// Le mot et le bit d'une touche dans [`I8042::enfoncees_en_file`].
fn rang_de_touche(code: CodeTouche) -> (usize, u64) {
    let rang = usize::from(code.jeu1) | (usize::from(code.etendue) << 8);
    (rang / 64, 1 << (rang % 64))
}

fn paquet(dx: i64, dy: i64, boutons: u8) -> [u8; 3] {
    let mut premier = 0x08 | (boutons & 0x07);
    if dx < 0 {
        premier |= 0x10;
    }
    if dy < 0 {
        premier |= 0x20;
    }
    [premier, dx as u8, dy as u8]
}

/// Le jeu 2 vers le jeu 1, pour les touches de base : la table de traduction
/// du contrôleur (IBM PC AT, reprise par `drivers/input/keyboard/atkbd.c`),
/// la même que celle du modèle Swift. `0xFF` : pas de touche.
const JEU1_DU_JEU2: [u8; 128] = [
    0xFF, 0x43, 0x41, 0x3F, 0x3D, 0x3B, 0x3C, 0x58, 0x64, 0x44, 0x42, 0x40, 0x3E, 0x0F, 0x29, 0x59,
    0x65, 0x38, 0x2A, 0x70, 0x1D, 0x10, 0x02, 0x5A, 0x66, 0x71, 0x2C, 0x1F, 0x1E, 0x11, 0x03, 0x5B,
    0x67, 0x2E, 0x2D, 0x20, 0x12, 0x05, 0x04, 0x5C, 0x68, 0x39, 0x2F, 0x21, 0x14, 0x13, 0x06, 0x5D,
    0x69, 0x31, 0x30, 0x23, 0x22, 0x15, 0x07, 0x5E, 0x6A, 0x72, 0x32, 0x24, 0x16, 0x08, 0x09, 0x5F,
    0x6B, 0x33, 0x25, 0x17, 0x18, 0x0B, 0x0A, 0x60, 0x6C, 0x34, 0x35, 0x26, 0x27, 0x19, 0x0C, 0x61,
    0x6D, 0x73, 0x28, 0x74, 0x1A, 0x0D, 0x62, 0x6E, 0x3A, 0x36, 0x1C, 0x1B, 0x75, 0x2B, 0x63, 0x76,
    0x55, 0x56, 0x77, 0x78, 0x79, 0x7A, 0x0E, 0x7B, 0x7C, 0x4F, 0x7D, 0x4B, 0x47, 0x7E, 0x7F, 0x6F,
    0x52, 0x53, 0x50, 0x4C, 0x4D, 0x48, 0x01, 0x45, 0x57, 0x4E, 0x51, 0x4A, 0x37, 0x49, 0x46, 0x54,
];

/// L'inverse de [`JEU1_DU_JEU2`] : le **premier** code du jeu 2 qui donne ce
/// code du jeu 1, comme le dictionnaire du modèle Swift, qui garde la
/// première entrée rencontrée.
fn jeu2_de(jeu1: u8) -> Option<u8> {
    if jeu1 == 0xFF {
        return None;
    }
    JEU1_DU_JEU2
        .iter()
        .position(|&code| code == jeu1)
        .map(|rang| rang as u8)
}

/// **Un caractère, sur un clavier américain** — la disposition qu'un invité
/// prend par défaut : la touche, et s'il faut Maj. Rien pour ce qu'un clavier
/// QWERTY n'a pas.
pub fn touche_du_caractere(caractere: char) -> Option<(CodeTouche, bool)> {
    const RANGEES: [(&str, &str, u8); 4] = [
        ("1234567890-=", "!@#$%^&*()_+", 0x02),
        ("qwertyuiop[]", "QWERTYUIOP{}", 0x10),
        ("asdfghjkl;'`", "ASDFGHJKL:\"~", 0x1E),
        ("\\zxcvbnm,./", "|ZXCVBNM<>?", 0x2B),
    ];
    match caractere {
        ' ' => return Some((CodeTouche::ESPACE, false)),
        '\n' | '\r' => return Some((CodeTouche::ENTREE, false)),
        '\t' => return Some((CodeTouche::simple(0x0F), false)),
        _ => {}
    }
    for (simple, avec_maj, premier) in RANGEES {
        for (maj, rangee) in [(false, simple), (true, avec_maj)] {
            if let Some(rang) = rangee.chars().position(|c| c == caractere) {
                return Some((CodeTouche::simple(premier + rang as u8), maj));
            }
        }
    }
    None
}

/// **Les frappes d'un caractère** : la touche enfoncée puis relâchée, Maj
/// autour quand il le faut. Vide pour ce qu'un clavier QWERTY n'a pas. Un
/// caractère est l'unité qu'admet la file ([`I8042::taper_groupe`]) : chaque
/// touche y est relâchée.
pub fn frappes_du_caractere(caractere: char) -> Vec<Frappe> {
    let Some((code, maj)) = touche_du_caractere(caractere) else {
        return Vec::new();
    };
    let mut frappes = Vec::with_capacity(4);
    let mut poser = |code, enfoncee| frappes.push(Frappe { code, enfoncee });
    if maj {
        poser(CodeTouche::MAJ_GAUCHE, true);
    }
    poser(code, true);
    poser(code, false);
    if maj {
        poser(CodeTouche::MAJ_GAUCHE, false);
    }
    frappes
}

/// **Ce qu'on tape, en touches enfoncées puis relâchées**, caractère par
/// caractère : le pendant de `X86Keystrokes.typing`. Ce qu'un clavier QWERTY
/// n'a pas est laissé de côté.
pub fn frappes_du_texte(texte: &str) -> Vec<Frappe> {
    texte.chars().flat_map(frappes_du_caractere).collect()
}

// ------------------------------------------------- l'état, pour l'instantané

/// Ce que la file des frappes peut tenir au plus : la borne, et un
/// relâchement par touche au-delà ([`LIMITE_DE_FRAPPE`]).
pub const PLUS_DE_FRAPPES: usize = LIMITE_DE_FRAPPE + TOUCHES;

impl I8042 {
    /// **L'état du contrôleur**, pour l'instantané de la machine native
    /// ([`super::etat`]) : le CTR, ce qui attend au port 0x60, les commandes
    /// qui attendent leur octet, les deux appareils, la ligne de remise à
    /// zéro, et **les frappes de l'hôte pas encore posées**, avec leur heure
    /// et les touches que la file laisse enfoncées.
    pub(crate) fn sauver(&self, e: &mut Ecrivain) {
        e.u8(self.configuration);
        e.compte(self.sortie.len());
        for sortie in &self.sortie {
            e.u8(sortie.octet);
            e.oui(sortie.de_la_souris);
        }
        e.peut_etre_u8(self.commande_en_attente);
        e.peut_etre_u8(self.parametre_du_clavier);
        e.peut_etre_u8(self.parametre_de_la_souris);
        e.oui(self.derniere_ecriture_commande);
        e.u32(self.perdues_sans_balayage);
        e.u32(self.perdues_port_coupe);
        e.oui(self.souris_rapporte);
        e.oui(self.clavier_balaye);
        e.oui(self.remise_demandee);
        e.compte(self.frappes.len());
        for frappe in &self.frappes {
            e.u8(frappe.code.jeu1);
            e.oui(frappe.code.etendue);
            e.oui(frappe.enfoncee);
        }
        e.u64(self.frappe_reprend_a);
        for mot in self.enfoncees_en_file {
            e.u64(mot);
        }
    }

    /// Relu, ou rien : une commande en attente que le contrôleur ne met
    /// jamais en attente (seules `60`, `D1` à `D4` attendent leur octet), un
    /// paramètre que ni le clavier (`ED`, `F3`, `F0`) ni la souris (`F3`,
    /// `E8`) n'attendent, plus de frappes que la file n'en admet.
    pub(crate) fn relire(l: &mut Lecteur) -> Option<Self> {
        let configuration = l.u8()?;
        let combien = l.compte(usize::MAX)?;
        let mut sortie = VecDeque::new();
        for _ in 0..combien {
            sortie.push_back(Sortie {
                octet: l.u8()?,
                de_la_souris: l.oui()?,
            });
        }
        let commande_en_attente = l.peut_etre_u8()?;
        let parametre_du_clavier = l.peut_etre_u8()?;
        let parametre_de_la_souris = l.peut_etre_u8()?;
        if !commande_en_attente.is_none_or(|c| matches!(c, 0x60 | 0xD1..=0xD4))
            || !parametre_du_clavier.is_none_or(|c| matches!(c, 0xED | 0xF3 | 0xF0))
            || !parametre_de_la_souris.is_none_or(|c| matches!(c, 0xF3 | 0xE8))
        {
            return None;
        }
        let derniere_ecriture_commande = l.oui()?;
        let perdues_sans_balayage = l.u32()?;
        let perdues_port_coupe = l.u32()?;
        let souris_rapporte = l.oui()?;
        let clavier_balaye = l.oui()?;
        let remise_demandee = l.oui()?;
        let combien = l.compte(PLUS_DE_FRAPPES)?;
        let mut frappes = VecDeque::with_capacity(combien.min(LIMITE_DE_FRAPPE));
        for _ in 0..combien {
            let jeu1 = l.u8()?;
            let etendue = l.oui()?;
            frappes.push_back(Frappe {
                code: CodeTouche { jeu1, etendue },
                enfoncee: l.oui()?,
            });
        }
        let frappe_reprend_a = l.u64()?;
        let mut enfoncees_en_file = [0u64; TOUCHES / 64];
        for mot in &mut enfoncees_en_file {
            *mot = l.u64()?;
        }
        Some(Self {
            configuration,
            sortie,
            commande_en_attente,
            parametre_du_clavier,
            parametre_de_la_souris,
            derniere_ecriture_commande,
            perdues_sans_balayage,
            perdues_port_coupe,
            souris_rapporte,
            clavier_balaye,
            remise_demandee,
            frappes,
            frappe_reprend_a,
            enfoncees_en_file,
        })
    }
}

#[cfg(test)]
mod tests {
    //! **Le clavier et la souris PS/2**, tels que Linux les sonde : les cas
    //! de `Tests/WisqVMTests/X86PS2Tests.swift` portés un pour un, ceux de
    //! `X86KeystrokesTests` qui touchent au texte, et les trois de
    //! `X86RebootTests` qui tiennent la ligne de remise à zéro. La cascade
    //! (le neuvième cas Swift) passe par la carte et les 8259 de `host.js` :
    //! elle est jugée dans `carte/mod.rs`, ligne pour ligne.
    use super::*;

    fn vider(ps2: &mut I8042) -> Vec<u8> {
        let mut octets = Vec::new();
        while ps2.etat() & 0x01 != 0 {
            octets.push(ps2.lire_donnee());
        }
        octets
    }

    /// Le contrôleur répond à la sonde de Linux : CTR, test, bouclage.
    #[test]
    fn the_controller_answers_linuxs_probe() {
        let mut ps2 = I8042::nouveau();
        assert_eq!(ps2.etat() & 0x01, 0, "rien à lire au départ");
        assert_ne!(ps2.etat() & 0x10, 0, "le clavier n'est pas verrouillé");
        ps2.ecrire_commande(0x20);
        let ctr = vider(&mut ps2);
        assert_eq!(ctr.len(), 1);
        assert_ne!(ctr[0] & 0x40, 0, "la traduction, comme un BIOS la laisse");
        ps2.ecrire_commande(0x60);
        ps2.ecrire_donnee(0x47);
        ps2.ecrire_commande(0x20);
        assert_eq!(vider(&mut ps2), [0x47], "le CTR écrit se relit");
        ps2.ecrire_commande(0xAA);
        assert_eq!(vider(&mut ps2), [0x55], "le contrôleur se teste bien");
        // Le bouclage : l'octet revient, marqué comme venant de la souris.
        ps2.ecrire_commande(0xD3);
        ps2.ecrire_donnee(0x5A);
        assert_ne!(ps2.etat() & 0x20, 0, "sortie de la souris");
        assert_eq!(vider(&mut ps2), [0x5A]);
        ps2.ecrire_commande(0xA9);
        assert_eq!(
            vider(&mut ps2),
            [0x00],
            "le port de la souris se teste bien"
        );
        // Éteindre et rallumer la souris se lit dans le CTR.
        ps2.ecrire_commande(0xA7);
        ps2.ecrire_commande(0x20);
        assert_ne!(vider(&mut ps2)[0] & 0x20, 0);
        ps2.ecrire_commande(0xA8);
        ps2.ecrire_commande(0x20);
        assert_eq!(vider(&mut ps2)[0] & 0x20, 0);
        // Le bit 3 de l'état dit où est allé le dernier octet écrit.
        assert_ne!(ps2.etat() & 0x08, 0, "dernier octet au port de commande");
        ps2.ecrire_donnee(0xEE);
        assert_eq!(ps2.etat() & 0x08, 0, "dernier octet au port de données");
    }

    /// Le clavier se présente en MF2 traduit, et la souris en souris
    /// standard.
    #[test]
    fn the_devices_identify_themselves() {
        let mut ps2 = I8042::nouveau();
        ps2.ecrire_donnee(0xF2);
        assert_eq!(vider(&mut ps2), [0xFA, 0xAB, 0x41]);
        ps2.ecrire_donnee(0xFF);
        assert_eq!(vider(&mut ps2), [0xFA, 0xAA]);
        ps2.ecrire_commande(0xD4);
        ps2.ecrire_donnee(0xF2);
        assert_eq!(vider(&mut ps2), [0xFA, 0x00]);
        ps2.ecrire_commande(0xD4);
        ps2.ecrire_donnee(0xF3);
        ps2.ecrire_commande(0xD4);
        ps2.ecrire_donnee(100);
        assert_eq!(vider(&mut ps2), [0xFA, 0xFA], "le paramètre a son accusé");
    }

    /// Une touche : en jeu 1 quand le contrôleur traduit, en jeu 2 sinon,
    /// avec `E0` pour les touches étendues.
    #[test]
    fn a_key_is_sent_in_the_set_the_controller_expects() {
        let mut ps2 = I8042::nouveau();
        ps2.touche(CodeTouche::simple(0x1E), true);
        ps2.touche(CodeTouche::simple(0x1E), false);
        ps2.touche(CodeTouche::HAUT, true);
        assert_eq!(
            vider(&mut ps2),
            [0x1E, 0x9E, 0xE0, 0x48],
            "A, puis la flèche haut, en jeu 1"
        );
        ps2.ecrire_commande(0x60);
        ps2.ecrire_donnee(0x07); // sans traduction
        ps2.touche(CodeTouche::simple(0x1E), true);
        ps2.touche(CodeTouche::simple(0x1E), false);
        ps2.touche(CodeTouche::ENTREE, true);
        assert_eq!(
            vider(&mut ps2),
            [0x1C, 0xF0, 0x1C, 0x5A],
            "A puis Entrée, en jeu 2"
        );
    }

    /// **Les frappes de l'hôte, au rythme d'une main** (`rythmer`) : une à
    /// la fois, la touche tenue `TENUE_TICS`, puis `ECART_TICS` avant la
    /// suivante, et rien tant que le noyau n'a pas lu l'octet d'avant.
    #[test]
    fn typed_keys_are_paced_like_a_hand() {
        let mut ps2 = I8042::nouveau();
        for frappe in frappes_du_texte("ab") {
            ps2.taper(frappe.code, frappe.enfoncee);
        }
        assert_eq!(ps2.frappes.len(), 4);
        assert!(ps2.sortie.is_empty(), "rien ne part avant son heure");
        ps2.rythmer(1_000);
        assert_eq!(vider(&mut ps2), [0x1E], "A enfoncée");
        ps2.rythmer(1_000 + TENUE_TICS - 1);
        assert!(ps2.sortie.is_empty(), "tenue");
        ps2.rythmer(1_000 + TENUE_TICS);
        assert_eq!(vider(&mut ps2), [0x9E], "A relâchée");
        let relachee = 1_000 + TENUE_TICS;
        ps2.rythmer(relachee + ECART_TICS - 1);
        assert!(ps2.sortie.is_empty(), "l'écart entre deux touches");
        ps2.rythmer(relachee + ECART_TICS);
        assert_eq!(vider(&mut ps2), [0x30], "B enfoncée");
        // Un octet que le noyau n'a pas lu retient la suite, même à l'heure.
        ps2.rythmer(u64::MAX / 2);
        assert_eq!(ps2.sortie.len(), 1);
        ps2.rythmer(u64::MAX / 2);
        assert_eq!(
            ps2.sortie.len(),
            1,
            "pas de deuxième octet avant la lecture du premier"
        );
        assert_eq!(vider(&mut ps2), [0xB0]);
        assert!(ps2.frappes.is_empty());
        // **Ce que le cas Swift ne tenait pas** : ci-dessus, la seconde
        // demande tombe aussi avant l'heure, et la file est vide ensuite.
        // Retirer la condition « le noyau a tout lu » le laissait vert (le
        // sabotage l'a montré). Ici l'heure est largement passée, une frappe
        // attend encore, et seul l'octet non lu la retient.
        ps2.taper(CodeTouche::ESPACE, true);
        ps2.taper(CodeTouche::ESPACE, false);
        let depart = u64::MAX / 2 + 10 * TENUE_TICS;
        ps2.rythmer(depart);
        ps2.rythmer(depart + 10 * TENUE_TICS);
        assert_eq!(
            vider(&mut ps2),
            [0x39],
            "l'espace relâché attend la lecture"
        );
        ps2.rythmer(depart + 10 * TENUE_TICS);
        assert_eq!(vider(&mut ps2), [0xB9]);
    }

    /// La file des frappes est bornée : un collage démesuré s'arrête là.
    #[test]
    fn the_typing_queue_is_bounded() {
        let mut ps2 = I8042::nouveau();
        for _ in 0..LIMITE_DE_FRAPPE + 10 {
            ps2.taper(CodeTouche::ESPACE, true);
        }
        assert_eq!(ps2.frappes.len(), LIMITE_DE_FRAPPE);
    }

    /// **Une file pleine ne coupe jamais une touche en deux.** Le défaut
    /// hérité du cœur Swift : à la borne, l'enfoncement entrait et le
    /// relâchement était jeté, et la touche restait enfoncée dans l'invité
    /// — Xorg la répétait sans fin.
    #[test]
    fn a_full_queue_never_leaves_a_key_down() {
        let mut ps2 = I8042::nouveau();
        let (a, b) = (CodeTouche::simple(0x1E), CodeTouche::simple(0x30));
        // Remplie jusqu'à une place de la borne, l'espace enfoncé en dernier.
        while ps2.frappes.len() < LIMITE_DE_FRAPPE - 1 {
            let enfoncee = ps2.frappes.len() % 2 == 0;
            assert!(ps2.taper(CodeTouche::ESPACE, enfoncee));
        }
        assert!(ps2.taper(a, true), "la dernière place");
        assert!(!ps2.taper(b, true), "plus de place pour un enfoncement");
        assert!(!ps2.taper(b, false), "ni pour relâcher une touche relevée");
        assert!(
            ps2.taper(a, false),
            "A était enfoncée : son relâchement passe"
        );
        assert!(ps2.taper(CodeTouche::ESPACE, false), "l'espace aussi");
        assert!(!ps2.taper(a, false), "mais une seule fois");
        assert_eq!(ps2.frappes.len(), LIMITE_DE_FRAPPE + 2);
        // Joué jusqu'au bout, chaque touche est relevée.
        let mut tenues = std::collections::HashSet::new();
        for frappe in &ps2.frappes {
            if frappe.enfoncee {
                tenues.insert(frappe.code);
            } else {
                tenues.remove(&frappe.code);
            }
        }
        assert!(tenues.is_empty(), "{tenues:?}");
    }

    /// **Le dépassement est borné** : au plus un relâchement par touche
    /// distincte, quoi que l'hôte envoie.
    #[test]
    fn the_queue_overflows_by_one_release_per_key_at_most() {
        let mut ps2 = I8042::nouveau();
        let toutes: Vec<CodeTouche> = (0..=u8::MAX)
            .flat_map(|jeu1| [CodeTouche::simple(jeu1), CodeTouche::etendue(jeu1)])
            .collect();
        assert_eq!(toutes.len(), TOUCHES);
        for &code in &toutes {
            assert!(ps2.taper(code, true));
        }
        while ps2.taper(CodeTouche::ESPACE, true) {}
        assert_eq!(ps2.frappes.len(), LIMITE_DE_FRAPPE);
        for &code in &toutes {
            assert!(ps2.taper(code, false), "{code:?}");
        }
        for &code in &toutes {
            assert!(!ps2.taper(code, false), "déjà relâchée : {code:?}");
            assert!(!ps2.taper(code, true), "{code:?}");
        }
        assert_eq!(ps2.frappes.len(), LIMITE_DE_FRAPPE + TOUCHES);
    }

    /// **Un groupe entre entier ou pas du tout**, sous la borne.
    #[test]
    fn a_group_of_keystrokes_is_taken_whole_or_not_at_all() {
        let mut ps2 = I8042::nouveau();
        let maj_a = frappes_du_caractere('A');
        assert_eq!(maj_a.len(), 4);
        while ps2.frappes.len() + 2 <= LIMITE_DE_FRAPPE - 2 {
            assert!(ps2.taper_groupe(&frappes_du_caractere('a')));
        }
        assert_eq!(ps2.frappes.len(), LIMITE_DE_FRAPPE - 2);
        assert!(!ps2.taper_groupe(&maj_a), "quatre frappes, deux places");
        assert_eq!(ps2.frappes.len(), LIMITE_DE_FRAPPE - 2, "rien n'est entré");
        assert!(
            ps2.taper_groupe(&frappes_du_caractere('a')),
            "deux tiennent"
        );
        assert!(ps2.taper_groupe(&[]), "un groupe vide tient toujours");
        assert!(!ps2.taper_groupe(&frappes_du_caractere('a')));
        assert_eq!(ps2.frappes.len(), LIMITE_DE_FRAPPE);
    }

    /// **Chaque octet écrit va où sa commande le dit**, et à personne
    /// d'autre : `D2` le rend comme venant du clavier (ligne 1, pas 12), et
    /// une nouvelle commande du contrôleur annule celle qui attendait son
    /// octet — l'octet suivant va alors au clavier.
    #[test]
    fn each_written_byte_goes_where_its_command_says() {
        let mut ps2 = I8042::nouveau();
        ps2.ecrire_commande(0xD2);
        ps2.ecrire_donnee(0x1E);
        assert_eq!(ps2.etat() & 0x20, 0, "pas une sortie de la souris");
        assert!(ps2.clavier_interrompt());
        assert!(!ps2.souris_interrompt());
        assert_eq!(vider(&mut ps2), [0x1E]);
        // `60` attend la configuration ; `AA` passe avant, et l'octet
        // suivant n'est plus à `60`.
        let avant = ps2.configuration;
        ps2.ecrire_commande(0x60);
        ps2.ecrire_commande(0xAA);
        assert_eq!(vider(&mut ps2), [0x55]);
        ps2.ecrire_donnee(0xF2);
        assert_eq!(ps2.configuration, avant, "le CTR n'a pas bougé");
        assert_eq!(vider(&mut ps2), [0xFA, 0xAB, 0x41], "le clavier l'a reçu");
    }

    /// **Le clavier prend ses paramètres** : après `ED`, `F3` ou `F0`,
    /// l'octet suivant est un paramètre, pas une commande. `F0 00` demande
    /// le jeu en cours : le jeu 2, que le contrôleur rend `41` quand il
    /// traduit.
    #[test]
    fn the_keyboard_takes_its_parameters() {
        let mut ps2 = I8042::nouveau();
        ps2.ecrire_donnee(0xF0);
        ps2.ecrire_donnee(0x00);
        assert_eq!(vider(&mut ps2), [0xFA, 0xFA, 0x41], "jeu 2, traduit");
        // Les voyants à `FF` : un paramètre, pas une remise à zéro.
        ps2.ecrire_donnee(0xED);
        ps2.ecrire_donnee(0xFF);
        assert_eq!(vider(&mut ps2), [0xFA, 0xFA]);
        ps2.ecrire_donnee(0xF3);
        ps2.ecrire_donnee(0xF2);
        assert_eq!(vider(&mut ps2), [0xFA, 0xFA], "la cadence, pas l'identité");
        // Choisir un jeu n'est qu'accusé ; sans traduction, le jeu se dit 2.
        ps2.ecrire_donnee(0xF0);
        ps2.ecrire_donnee(0x02);
        assert_eq!(vider(&mut ps2), [0xFA, 0xFA]);
        ps2.ecrire_commande(0x60);
        ps2.ecrire_donnee(0x07);
        ps2.ecrire_donnee(0xF0);
        ps2.ecrire_donnee(0x00);
        assert_eq!(vider(&mut ps2), [0xFA, 0xFA, 0x02], "jeu 2, non traduit");
    }

    /// **La souris dit son état, et sa remise à zéro l'éteint** : `E9`
    /// rend le bit « rapporte » tel qu'il est, et `FF` coupe les paquets
    /// jusqu'au prochain `F4`.
    #[test]
    fn the_mouse_reports_its_status_and_its_reset_silences_it() {
        let mut ps2 = I8042::nouveau();
        ps2.ecrire_commande(0xA8);
        let souris = |ps2: &mut I8042, octet: u8| {
            ps2.ecrire_commande(0xD4);
            ps2.ecrire_donnee(octet);
            vider(ps2)
        };
        assert_eq!(souris(&mut ps2, 0xE9), [0xFA, 0x00, 0x02, 100]);
        assert_eq!(souris(&mut ps2, 0xF4), [0xFA]);
        assert_eq!(souris(&mut ps2, 0xE9), [0xFA, 0x20, 0x02, 100]);
        assert_eq!(souris(&mut ps2, 0xFF), [0xFA, 0xAA, 0x00]);
        assert!(!ps2.souris_rapporte);
        ps2.souris(4, 4, 0);
        assert!(
            vider(&mut ps2).is_empty(),
            "remise à zéro : plus de paquets"
        );
        assert_eq!(souris(&mut ps2, 0xE9), [0xFA, 0x00, 0x02, 100]);
    }

    /// **Une souris coupée par le contrôleur se tait**, même allumée : `A7`
    /// coupe le port, `A8` le rouvre.
    #[test]
    fn a_mouse_port_disabled_by_the_controller_sends_nothing() {
        let mut ps2 = I8042::nouveau();
        ps2.ecrire_commande(0xA8);
        ps2.ecrire_commande(0xD4);
        ps2.ecrire_donnee(0xF4);
        vider(&mut ps2);
        ps2.ecrire_commande(0xA7);
        ps2.souris(4, 4, 1);
        assert!(vider(&mut ps2).is_empty(), "port coupé");
        ps2.ecrire_commande(0xA8);
        ps2.souris(4, 4, 1);
        assert_eq!(vider(&mut ps2).len(), 3, "port rouvert : un paquet");
    }

    /// Un caractère se tape sur un clavier américain.
    #[test]
    fn a_character_maps_to_its_us_key() {
        assert_eq!(
            touche_du_caractere('a'),
            Some((CodeTouche::simple(0x1E), false))
        );
        assert_eq!(touche_du_caractere('A').map(|t| t.1), Some(true));
        assert_eq!(
            touche_du_caractere('1').map(|t| t.0),
            Some(CodeTouche::simple(0x02))
        );
        assert_eq!(touche_du_caractere('!').map(|t| t.1), Some(true));
        assert_eq!(
            touche_du_caractere('/').map(|t| t.0),
            Some(CodeTouche::simple(0x35))
        );
        assert_eq!(
            touche_du_caractere('\\').map(|t| t.0),
            Some(CodeTouche::simple(0x2B))
        );
        assert_eq!(
            touche_du_caractere('~'),
            Some((CodeTouche::simple(0x29), true))
        );
        assert_eq!(
            touche_du_caractere('é'),
            None,
            "rien pour ce qu'un clavier QWERTY n'a pas"
        );
    }

    /// **Ce qu'on tape devient des touches**, Maj autour (le cas
    /// `testTextIsTypedWithShiftWhereNeeded` de `X86KeystrokesTests`).
    #[test]
    fn text_is_typed_with_shift_where_needed() {
        let ecrire = |texte: &str| -> Vec<String> {
            frappes_du_texte(texte)
                .iter()
                .map(|f| {
                    format!(
                        "{}{:02X}{}",
                        if f.code.etendue { "E0 " } else { "" },
                        f.code.jeu1,
                        if f.enfoncee { "↓" } else { "↑" }
                    )
                })
                .collect()
        };
        assert_eq!(ecrire("aB"), ["1E↓", "1E↑", "2A↓", "30↓", "30↑", "2A↑"]);
        assert!(ecrire("é").is_empty(), "ce qu'un clavier QWERTY n'a pas");
        assert_eq!(ecrire("\n"), ["1C↓", "1C↑"]);
    }

    /// La souris ne parle qu'une fois allumée, et ses paquets disent Y vers
    /// le haut ; un grand mouvement se découpe.
    #[test]
    fn the_mouse_sends_packets_once_enabled() {
        let mut ps2 = I8042::nouveau();
        ps2.ecrire_commande(0xA8);
        ps2.souris(5, 5, 1);
        assert!(vider(&mut ps2).is_empty(), "rien avant F4");
        ps2.ecrire_commande(0xD4);
        ps2.ecrire_donnee(0xF4);
        vider(&mut ps2);
        ps2.souris(5, 3, 1);
        assert_eq!(
            vider(&mut ps2),
            [0x08 | 0x01 | 0x20, 5, 0xFD],
            "Y vers le bas à l'écran, négatif dans le paquet"
        );
        ps2.souris(-300, 0, 0);
        let octets = vider(&mut ps2);
        assert_eq!(octets.len(), 6, "deux paquets");
        // −300 en deux pas : −255 puis −45, signe de X levé dans les deux.
        assert_ne!(octets[0] & 0x10, 0);
        assert_eq!(octets[1], (-255i32) as u8);
        assert_ne!(octets[3] & 0x10, 0);
        assert_eq!(octets[4], (-45i32) as u8);
    }

    /// Les lignes suivent ce qui attend : la 1 pour le clavier, la 12 pour la
    /// souris, et rien quand le noyau a coupé l'interruption.
    #[test]
    fn the_lines_follow_what_is_waiting() {
        let mut ps2 = I8042::nouveau();
        ps2.touche(CodeTouche::ESPACE, true);
        assert!(ps2.clavier_interrompt());
        assert!(!ps2.souris_interrompt());
        vider(&mut ps2);
        assert!(!ps2.clavier_interrompt());
        ps2.ecrire_commande(0xD3);
        ps2.ecrire_donnee(1);
        assert!(ps2.souris_interrompt());
        ps2.ecrire_commande(0x60);
        ps2.ecrire_donnee(0x44); // plus d'interruption de la souris
        assert!(!ps2.souris_interrompt());
    }

    /// Les touches perdues sont comptées, et pourquoi.
    #[test]
    fn keys_lost_while_not_scanning_or_port_disabled_are_counted() {
        let mut ps2 = I8042::nouveau();
        ps2.ecrire_donnee(0xF5);
        vider(&mut ps2);
        ps2.touche(CodeTouche::ESPACE, true);
        assert_eq!(ps2.perdues_sans_balayage, 1);
        ps2.ecrire_donnee(0xF4);
        vider(&mut ps2);
        ps2.ecrire_commande(0xAD);
        ps2.touche(CodeTouche::ESPACE, true);
        assert_eq!(ps2.perdues_port_coupe, 1);
        assert!(ps2.sortie.is_empty());
    }

    /// **L'impulsion de Linux** : `0xFE` sur le port de commande du 8042.
    #[test]
    fn the_pulse_linux_sends_resets_the_processor() {
        let mut ps2 = I8042::nouveau();
        ps2.ecrire_commande(0xFE);
        assert!(ps2.remise_demandee);
    }

    /// Les autres commandes ne tirent pas la ligne : `0xFF` n'envoie aucune
    /// impulsion, les autres de la plage n'en envoient pas sur le bit zéro,
    /// et l'autotest du contrôleur ou l'écriture de la configuration ne
    /// touchent pas le port de sortie.
    #[test]
    fn other_commands_leave_the_line_alone() {
        for commande in [0xFF, 0xF1, 0xFD, 0xAA, 0x20, 0x60, 0xA7, 0xAD, 0xD0] {
            let mut ps2 = I8042::nouveau();
            ps2.ecrire_commande(commande);
            assert!(!ps2.remise_demandee, "{commande:#x}");
        }
    }

    /// **Le port de sortie écrit d'un coup** (`0xD1`) : le bit zéro à zéro
    /// remet à zéro, à un il laisse tourner — c'est ce que Linux écrit au
    /// démarrage pour ouvrir la porte A20, `0xDF`.
    #[test]
    fn writing_the_output_port_resets_only_with_bit_zero_low() {
        let mut tourne = I8042::nouveau();
        tourne.ecrire_commande(0xD1);
        tourne.ecrire_donnee(0xDF);
        assert!(!tourne.remise_demandee);
        let mut remise = I8042::nouveau();
        remise.ecrire_commande(0xD1);
        remise.ecrire_donnee(0xDE);
        assert!(remise.remise_demandee);
    }
}

#[cfg(test)]
mod tests_de_l_etat {
    //! **Le contrôleur sauvé et relu** ([`I8042::sauver`]) : ce qui attend au
    //! port 0x60, les commandes en attente et les frappes passent ; ce que le
    //! contrôleur ne met jamais en attente est refusé.
    use super::super::etat::essais::{chaque_coupure_refusee, octets_de, relu, se_relit};
    use super::*;

    fn occupe() -> I8042 {
        let mut ps2 = I8042::nouveau();
        ps2.ecrire_commande(0xA8); // la souris allumée
        ps2.ecrire_commande(0xD4);
        ps2.ecrire_donnee(0xF4); // elle rapporte
        ps2.souris(3, -2, 1);
        ps2.ecrire_donnee(0xED); // le clavier attend son paramètre
        ps2.ecrire_commande(0x60); // le contrôleur attend son octet
        for frappe in frappes_du_caractere('A') {
            assert!(ps2.taper(frappe.code, frappe.enfoncee));
        }
        ps2.rythmer(10);
        ps2
    }

    #[test]
    fn a_busy_controller_reads_back_with_its_waiting_keystrokes() {
        let ps2 = occupe();
        assert!(!ps2.sortie.is_empty() && !ps2.frappes.is_empty());
        assert_eq!(ps2.commande_en_attente, Some(0x60));
        assert_eq!(ps2.parametre_du_clavier, Some(0xED));
        let octets = octets_de(&ps2, I8042::sauver);
        let relu = relu(&octets, I8042::relire).expect("relu");
        assert_eq!(relu, ps2);
        chaque_coupure_refusee(&octets, I8042::relire);
        // Les frappes repartent à leur heure, des deux côtés pareil.
        let (mut a, mut b) = (ps2, relu);
        for tics in [10, TENUE_TICS + 10, TENUE_TICS + ECART_TICS + 10] {
            a.sortie.clear();
            b.sortie.clear();
            a.rythmer(tics);
            b.rythmer(tics);
            assert_eq!(a, b);
        }
    }

    #[test]
    fn what_the_controller_never_waits_for_is_refused() {
        let ps2 = occupe();
        let relit = |abimer: fn(&mut I8042)| se_relit(&ps2, abimer, I8042::sauver, I8042::relire);
        assert!(relit(|_| {}), "tel quel");
        assert!(
            relit(|p| p.parametre_de_la_souris = Some(0xE8)),
            "un paramètre de souris"
        );
        assert!(
            !relit(|p| p.commande_en_attente = Some(0x20)),
            "0x20 répond tout de suite"
        );
        assert!(
            !relit(|p| p.parametre_du_clavier = Some(0xF4)),
            "F4 n'a pas de paramètre"
        );
        assert!(
            !relit(|p| p.parametre_de_la_souris = Some(0xF4)),
            "ni pour la souris"
        );
        let pleine = |p: &mut I8042| {
            let frappe = p.frappes[0];
            p.frappes = std::iter::repeat_n(frappe, PLUS_DE_FRAPPES + 1).collect();
        };
        assert!(
            !se_relit(&ps2, pleine, I8042::sauver, I8042::relire),
            "plus de frappes que la file n'en admet"
        );
        let juste = |p: &mut I8042| {
            let frappe = p.frappes[0];
            p.frappes = std::iter::repeat_n(frappe, PLUS_DE_FRAPPES).collect();
        };
        assert!(
            se_relit(&ps2, juste, I8042::sauver, I8042::relire),
            "la borne est comprise"
        );
    }
}
