//! **Le disque virtio de la page, de forme ancienne, servi plus tard.**
//! Porté depuis `VirtioBlock` du cœur Swift (`Sources/WisqVM/VirtioBlock.swift`),
//! dans sa forme par ports : mêmes registres, même file, mêmes refus. Une
//! chose change, et c'est toute la raison de ce fichier : **la réponse n'est
//! pas rendue pendant la notification**.
//!
//! **Pourquoi plus tard.** Du côté Swift, `serve` lit le disque pendant
//! l'`out` qui notifie, parce que les octets sont à portée de main. Dans la
//! page, ils ne le sont pas : une ISO de 1,4 Gio ne tient pas à côté de 1 Gio
//! de RAM, et Swift, qui la tient, n'est joignable que par message, donc de
//! façon asynchrone (carte du 14 novembre, § 4.2). Le disque se coupe donc en
//! deux :
//!
//! - **l'avant, ici** : les registres, la file lue et écrite dans la RAM de
//!   l'invité par le trait [`Ram`], et la liste des requêtes parties ;
//! - **l'arrière, ailleurs** : n'importe quoi qui sait lire et écrire des
//!   plages d'octets et répondre quand il peut — un fichier lu par plages, le
//!   `DiskStore` de Swift derrière une URL. Ce fichier n'en connaît que le
//!   contrat.
//!
//! Le trajet d'une requête : le pilote notifie ; l'avant lit la chaîne de
//! descripteurs, la juge, et pose une [`RequeteDisque`] ; la boucle hôte la
//! prend ([`VirtioBlk::prendre_requete`]) et la confie à l'arrière ; quand
//! l'arrière répond, la boucle rend la réponse ([`VirtioBlk::lu`] ou
//! [`VirtioBlk::fini`]), et c'est alors seulement que l'avant copie les
//! octets dans la RAM, pose l'octet de statut, écrit l'anneau des servies et
//! lève la ligne. Virtio est fait pour cela : le pilote notifie, puis attend
//! une interruption, et rien ne l'oblige à attendre peu.
//!
//! **Ce qui ne part pas** : ce qui se juge sans les octets du disque. Une
//! chaîne mal formée, un secteur au-delà du disque, un type inconnu, la
//! demande d'identifiant : la réponse est rendue tout de suite, comme du côté
//! Swift.
//!
//! **Ce qui est implémenté** : la forme ancienne de virtio-pci, aucune
//! fonction optionnelle annoncée (ni `SEG_MAX`, ni `SIZE_MAX`, ni `FLUSH`, ni
//! lecture seule), une seule file de 128 descripteurs, ce que fait le cœur
//! Swift. Le transport MMIO de `VirtioBlock` n'est pas porté : la page ne sait
//! pas encore servir un accès mémoire hors RAM.

use std::collections::VecDeque;

use super::etat::{Ecrivain, Lecteur};
use super::Ram;

/// **Le registre de notification** de la fenêtre : le pilote y écrit le
/// numéro de la file qu'il vient de garnir, et c'est le seul registre dont
/// l'écriture lit la RAM de l'invité.
pub const REGISTRE_DE_NOTIFICATION: u16 = 0x10;

/// La taille de la file, que le pilote ne peut pas changer en forme
/// ancienne : il la lit au registre `0x0C`, et c'est sur elle qu'il calcule
/// ses anneaux (`vring_init`).
pub const LIMITE_DE_FILE: u32 = 128;

/// **Ce que la carte tient au plus, en octets, pour toutes les requêtes
/// parties à la fois** : la somme des longueurs de celles qui attendent leur
/// réponse, prises ou non — **y compris celles qu'une remise à zéro ou une
/// file reposée a oubliées** et que l'arrière sert encore.
///
/// Le cœur Swift n'en a pas besoin : ses octets sont là, et il copie ce qu'on
/// lui demande pendant la notification. Ici, une écriture est recopiée de la
/// RAM dans la mémoire de la carte au moment où elle part (puis encore une
/// fois par `web/carte.js`, qui la donne à l'arrière), et une lecture fait
/// allouer autant à l'arrière. Une borne par requête ne suffit pas : une
/// seule notification peut faire partir cent vingt-huit requêtes, et cent
/// vingt-huit fois 64 Mio font 8 Gio, plus que les 4 Gio d'une mémoire
/// wasm32 — l'allocation échouerait, et la carte trapperait.
///
/// **Une requête oubliée reste comptée jusqu'à sa réponse.** Une remise à
/// zéro ne rappelle pas ce qui est déjà confié : `web/carte.js` a donné la
/// requête à l'arrière, qui alloue toute sa longueur pour la lire, et la
/// réponse viendra quand même (elle ne touchera simplement plus à la RAM).
/// Si l'oubli rendait la place, un invité qui boucle « remise, file, lecture
/// de 64 Mio, notification » ferait partir 64 Mio de plus à chaque tour, sans
/// limite, chez l'arrière. Une requête qui n'avait pas encore été prise,
/// elle, n'est jamais partie : l'oubli la lâche pour de bon.
///
/// **Au-delà, la file attend** plutôt que de refuser : la requête qui ne
/// tient plus reste dans l'anneau des disponibles, non lue, avec toutes
/// celles d'après, et la carte la reprend dès qu'une réponse rend de la
/// place. Virtio le permet (rien n'oblige le disque à lire l'anneau au
/// rythme du pilote), et un pilote correct qui charge beaucoup ne reçoit
/// ainsi jamais d'erreur d'entrée-sortie qu'il n'a pas méritée. Un noyau à
/// qui l'on n'annonce ni `SEG_MAX` ni `SIZE_MAX` découpe ses requêtes à
/// 1 280 Kio par défaut (`max_sectors_kb`, de mémoire du pilote, non mesuré
/// ici) : il lui faudrait plus de cinquante requêtes dehors pour attendre.
pub const PLUS_TENU: u64 = 64 << 20;

/// **La plus grande requête qui part vers l'arrière**, en octets : celle
/// qui, seule, remplit [`PLUS_TENU`]. Au-delà, elle ne tiendrait jamais, et
/// la file l'attendrait pour toujours : elle est refusée par une erreur
/// d'entrée-sortie, que le pilote voit.
pub const PLUS_GRANDE_REQUETE: u64 = PLUS_TENU;

/// Le sens d'une requête qui part vers l'arrière.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sens {
    Lire,
    Ecrire,
}

/// **Une requête pour l'arrière** : une plage du disque à lire, ou à écrire
/// avec ses octets.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequeteDisque {
    /// Le nom de la requête pour la réponse. Jamais réemployé tant que la
    /// carte vit, même quand le disque est rebranché : une réponse en retard,
    /// après une remise à zéro ou un disque neuf, ne peut pas tomber sur une
    /// requête plus jeune.
    pub id: u32,
    pub sens: Sens,
    /// Le début de la plage, en octets depuis le début du disque.
    pub decalage: u64,
    /// Sa longueur, en octets.
    pub longueur: u64,
    /// Les octets à écrire, recopiés de la RAM au départ ; vide pour une
    /// lecture.
    pub octets: Vec<u8>,
}

/// Un descripteur de la file : seize octets dans la RAM de l'invité. La
/// carte réseau lit les siens de la même façon ([`super::virtio_net`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Descripteur {
    pub(crate) adresse: u64,
    pub(crate) longueur: u32,
    pub(crate) drapeaux: u16,
    pub(crate) suivant: u16,
}

impl Descripteur {
    /// **Le descripteur `index` de la table posée à `table`**, ou rien si ses
    /// seize octets ne sont pas dans la RAM.
    pub(crate) fn lire(table: u64, index: u16, ram: &dyn Ram) -> Option<Self> {
        let a = table.wrapping_add(u64::from(index).wrapping_mul(16));
        let mut seize = [0u8; 16];
        if !ram.lire(a, &mut seize) {
            return None;
        }
        let [a0, a1, a2, a3, a4, a5, a6, a7, l0, l1, l2, l3, d0, d1, s0, s1] = seize;
        Some(Self {
            adresse: u64::from_le_bytes([a0, a1, a2, a3, a4, a5, a6, a7]),
            longueur: u32::from_le_bytes([l0, l1, l2, l3]),
            drapeaux: u16::from_le_bytes([d0, d1]),
            suivant: u16::from_le_bytes([s0, s1]),
        })
    }

    pub(crate) fn chaine(&self) -> bool {
        self.drapeaux & 1 != 0
    }
    pub(crate) fn inscriptible(&self) -> bool {
        self.drapeaux & 2 != 0
    }
}

/// **Une requête partie**, et ce qu'il faudra pour la rendre.
#[derive(Clone, Debug, PartialEq, Eq)]
struct EnVol {
    id: u32,
    /// La tête de la chaîne : ce que l'anneau des servies rend au pilote.
    tete: u16,
    sens: Sens,
    longueur: u64,
    /// Où copier les octets d'une lecture, dans l'ordre de la chaîne.
    tampons: Vec<(u64, u32)>,
    /// L'adresse de l'octet de statut, s'il y en a un où écrire.
    statut_a: Option<u64>,
}

/// Les trois statuts d'une requête virtio-blk.
const REUSSI: u8 = 0;
const ERREUR: u8 = 1;
const NON_SUPPORTE: u8 = 2;

/// **Le disque** : les registres de la forme ancienne, la file, et les
/// requêtes parties.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VirtioBlk {
    /// La capacité, en secteurs de 512 octets. Connue d'avance, parce que le
    /// pilote la lit par un `in`, qui n'attend pas.
    secteurs: u64,
    /// Ce que le pilote a accepté des fonctions (aucune n'est offerte).
    pub fonctions_du_pilote: u32,
    statut: u8,
    file_choisie: u16,
    /// Le numéro de page où le pilote a posé sa file : les trois anneaux s'en
    /// déduisent.
    page_de_file: u32,
    taille_de_file: u32,
    prete: bool,
    table: u64,
    anneau_disponible: u64,
    anneau_servi: u64,
    /// L'état d'interruption : le bit 0 dit « une requête est servie ». Lu au
    /// registre `0x13`, il s'acquitte.
    isr: u8,
    /// L'index de la prochaine entrée à lire dans l'anneau des disponibles,
    /// et de la prochaine à écrire dans celui des servies.
    prochain_disponible: u16,
    prochain_servi: u16,
    /// Combien de requêtes ont été servies, et combien refusées : un disque
    /// qui refuse tout et un disque que personne n'appelle se lisent pareil
    /// sans ces deux nombres.
    pub servies: u64,
    pub refusees: u64,
    prochain_id: u32,
    /// Les requêtes qui attendent que la boucle hôte les prenne.
    a_envoyer: VecDeque<RequeteDisque>,
    /// Celles qui attendent leur réponse, prises ou non.
    en_vol: Vec<EnVol>,
    /// **Les requêtes confiées puis oubliées** (une remise à zéro, une file
    /// reposée, un disque rebranché), par leur nom et leur longueur : leur
    /// réponse ne trouvera personne, mais l'arrière les sert encore, et elles
    /// comptent dans [`PLUS_TENU`] et dans les 128 places jusqu'à ce qu'elle
    /// vienne.
    oubliees: Vec<(u32, u64)>,
    /// **La file attend** : le dernier passage s'est arrêté sur une requête
    /// qui ne tenait pas encore. Une réponse, même celle d'une requête
    /// oubliée, la fera reprendre ; un `hlt` qui attend le disque attend
    /// donc une réponse.
    file_attend: bool,
}

impl VirtioBlk {
    /// Un disque de `secteurs` secteurs de 512 octets, comme le laisse un
    /// BIOS.
    pub const fn nouveau(secteurs: u64) -> Self {
        Self {
            secteurs,
            fonctions_du_pilote: 0,
            statut: 0,
            file_choisie: 0,
            page_de_file: 0,
            taille_de_file: 0,
            prete: false,
            table: 0,
            anneau_disponible: 0,
            anneau_servi: 0,
            isr: 0,
            prochain_disponible: 0,
            prochain_servi: 0,
            servies: 0,
            refusees: 0,
            prochain_id: 1,
            a_envoyer: VecDeque::new(),
            en_vol: Vec::new(),
            oubliees: Vec::new(),
            file_attend: false,
        }
    }

    pub fn secteurs(&self) -> u64 {
        self.secteurs
    }

    pub fn statut(&self) -> u8 {
        self.statut
    }

    pub fn file_choisie(&self) -> u16 {
        self.file_choisie
    }

    pub fn file_prete(&self) -> bool {
        self.prete
    }

    /// Vrai quand le disque demande l'interruption.
    pub fn interrompt(&self) -> bool {
        self.isr != 0
    }

    /// **Une réponse peut encore lever la ligne sans que l'invité agisse** :
    /// des requêtes sont parties et n'ont pas leur réponse, ou la file attend
    /// de la place (qu'une réponse, même d'une requête oubliée, lui rendra).
    /// Ce que `wakeable` doit compter : un `hlt` qui attend le disque attend
    /// cette réponse-là. Une requête oubliée seule, sans file qui attend, ne
    /// lèvera rien : sa réponse ne touche pas à la RAM.
    pub fn en_attente(&self) -> bool {
        !self.en_vol.is_empty() || self.file_attend
    }

    /// Combien de requêtes attendent que la boucle hôte les prenne.
    pub fn a_prendre(&self) -> usize {
        self.a_envoyer.len()
    }

    /// **Combien d'octets la carte tient pour l'arrière** : la somme des
    /// longueurs des requêtes parties qui attendent leur réponse, oubliées
    /// comprises. Jamais plus que [`PLUS_TENU`].
    pub fn tenus(&self) -> u64 {
        self.en_vol.iter().map(|v| v.longueur).sum::<u64>()
            + self.oubliees.iter().map(|&(_, n)| n).sum::<u64>()
    }

    /// Combien de requêtes la carte compte dehors : en vol, et oubliées sans
    /// réponse encore.
    pub fn dehors(&self) -> usize {
        self.en_vol.len() + self.oubliees.len()
    }

    /// **Prendre la suite d'un disque débranché** : ses noms, et ce qu'il a
    /// confié à l'arrière sans réponse encore, qui reste compté ici jusqu'à
    /// la réponse (voir [`PLUS_TENU`]). Ses requêtes sont oubliées : leurs
    /// réponses ne toucheront pas à la RAM.
    pub fn succeder_a(&mut self, ancien: &VirtioBlk) {
        self.reprendre_les_noms(ancien.prochain_nom());
        self.oubliees = ancien.oubliees.clone();
        self.oubliees.extend(ancien.confiees());
    }

    /// Les requêtes en vol déjà prises par la boucle hôte, donc confiées à
    /// l'arrière : celles d'`a_envoyer` ne sont jamais parties.
    fn confiees(&self) -> impl Iterator<Item = (u32, u64)> + '_ {
        self.en_vol
            .iter()
            .filter(|v| !self.a_envoyer.iter().any(|r| r.id == v.id))
            .map(|v| (v.id, v.longueur))
    }

    /// **Le nom que portera la prochaine requête partie.** Un disque neuf
    /// branché à la place de celui-ci le reprend ([`VirtioBlk::reprendre_les_noms`]) :
    /// les réponses de l'ancien, qui peuvent encore arriver, ne doivent pas
    /// nommer une requête du neuf.
    pub fn prochain_nom(&self) -> u32 {
        self.prochain_id
    }

    /// **Continuer les noms d'un disque d'avant** : la prochaine requête
    /// partie s'appellera `nom` (ramené entre 1 et 2³¹ − 1, comme tous).
    pub fn reprendre_les_noms(&mut self, nom: u32) {
        self.prochain_id = (nom.wrapping_sub(1) % 0x7FFF_FFFF) + 1;
    }

    // ---------------------------------------------------------------- ports

    /// **Lire un registre de la fenêtre**, à `decalage` de son début. Le
    /// registre entier : la carte garde les bits de la largeur demandée.
    pub fn lire_port(&mut self, decalage: u16, largeur: u8) -> u32 {
        match decalage {
            0x00 => 0, // aucune fonction optionnelle annoncée
            0x08 => self.page_de_file,
            0x0C => LIMITE_DE_FILE,
            0x12 => u32::from(self.statut),
            0x13 => {
                // Lire l'état d'interruption l'acquitte : c'est la règle de la
                // forme ancienne, et le pilote ne fait rien d'autre pour ça.
                let isr = self.isr;
                self.isr = 0;
                u32::from(isr)
            }
            // L'espace de configuration : la capacité, en secteurs, sur huit
            // octets lus d'où l'on veut.
            0x14..=0x1B => {
                let champ = u32::from(decalage - 0x14);
                let mut valeur = 0u32;
                for rang in 0..u32::from(largeur) {
                    if champ + rang >= 8 {
                        break;
                    }
                    let octet = (self.secteurs >> (8 * (champ + rang))) & 0xFF;
                    valeur |= (octet as u32) << (8 * rang);
                }
                valeur
            }
            _ => 0,
        }
    }

    /// **Écrire un registre de la fenêtre.** `valeur` est déjà ramenée à la
    /// largeur de l'accès. La notification (`0x10`) lit la file dans `ram`.
    pub fn ecrire_port(&mut self, decalage: u16, valeur: u32, ram: &mut dyn Ram) {
        match decalage {
            0x04 => self.fonctions_du_pilote = valeur,
            0x08 => {
                // Le numéro de page de la file. Zéro la retire. Une file
                // reposée ailleurs oublie ce qui était parti : les réponses
                // viseraient des anneaux que le pilote a quittés.
                self.page_de_file = valeur;
                self.taille_de_file = if valeur == 0 { 0 } else { LIMITE_DE_FILE };
                self.prete = valeur != 0;
                (self.table, self.anneau_disponible, self.anneau_servi) =
                    anneaux(valeur, LIMITE_DE_FILE);
                self.prochain_disponible = 0;
                self.prochain_servi = 0;
                self.oublier_les_requetes();
            }
            0x0E => self.file_choisie = valeur as u16,
            REGISTRE_DE_NOTIFICATION => {
                if self.prete {
                    self.servir(ram);
                }
            }
            0x12 => {
                self.statut = valeur as u8;
                if self.statut == 0 {
                    self.remettre_a_zero();
                }
            }
            _ => {}
        }
    }

    /// **La remise à zéro** (statut zéro) : un pilote qui recommence ne doit
    /// pas retrouver les anneaux du précédent, ni recevoir ses réponses. Le
    /// numéro de page et la file choisie restent, comme du côté Swift.
    fn remettre_a_zero(&mut self) {
        self.prete = false;
        self.taille_de_file = 0;
        self.table = 0;
        self.anneau_disponible = 0;
        self.anneau_servi = 0;
        self.isr = 0;
        self.prochain_disponible = 0;
        self.prochain_servi = 0;
        self.fonctions_du_pilote = 0;
        self.oublier_les_requetes();
    }

    /// Les requêtes parties sont oubliées : leur réponse, quand elle viendra,
    /// ne trouvera personne et ne touchera pas à la RAM. Celles déjà confiées
    /// à l'arrière restent pourtant comptées jusqu'à cette réponse
    /// ([`PLUS_TENU`]) ; celles que la boucle n'avait pas prises ne sont
    /// jamais parties, et sont lâchées.
    fn oublier_les_requetes(&mut self) {
        let confiees: Vec<(u32, u64)> = self.confiees().collect();
        self.oubliees.extend(confiees);
        self.a_envoyer.clear();
        self.en_vol.clear();
        self.file_attend = false;
    }

    // ----------------------------------------------------------------- file

    fn descripteur(&self, index: u16, ram: &dyn Ram) -> Option<Descripteur> {
        Descripteur::lire(self.table, index, ram)
    }

    /// **Recevoir tout ce que le pilote a rendu disponible.** L'index des
    /// disponibles se suit, il ne se relit pas : deux notifications pour deux
    /// requêtes avancent de deux.
    fn servir(&mut self, ram: &mut dyn Ram) {
        if self.taille_de_file == 0
            || self.table == 0
            || self.anneau_disponible == 0
            || self.anneau_servi == 0
        {
            return;
        }
        self.file_attend = false;
        let Some(cible) = lire_u16(ram, self.anneau_disponible.wrapping_add(2)) else {
            return;
        };
        let taille = self.taille_de_file as u16;
        while self.prochain_disponible != cible {
            let place = u64::from(self.prochain_disponible % taille);
            let Some(tete) = lire_u16(ram, self.anneau_disponible.wrapping_add(4 + place * 2))
            else {
                return;
            };
            // La file attend : cette entrée et les suivantes restent dans
            // l'anneau, et une réponse les fera reprendre.
            if !self.recevoir(tete, ram) {
                self.file_attend = true;
                return;
            }
            self.prochain_disponible = self.prochain_disponible.wrapping_add(1);
        }
    }

    /// **Une requête** : l'en-tête, les données, puis l'octet de statut.
    ///
    /// Le silence est un mensonge : une chaîne mal formée, un secteur hors du
    /// disque ou un type inconnu se répondent par un statut d'erreur, jamais
    /// en ne répondant rien — un pilote sans réponse attend pour toujours.
    ///
    /// Rend `false` quand la requête ne tient pas encore ([`PLUS_TENU`]) :
    /// elle n'est pas lue, et la file attend. `true` quand elle est reçue —
    /// partie, ou déjà rendue.
    fn recevoir(&mut self, tete: u16, ram: &mut dyn Ram) -> bool {
        let mut chaine: Vec<Descripteur> = Vec::new();
        let mut index = tete;
        while chaine.len() <= LIMITE_DE_FILE as usize {
            let Some(un) = self.descripteur(index, ram) else {
                break;
            };
            chaine.push(un);
            if !un.chaine() {
                break;
            }
            index = un.suivant;
        }
        // L'octet de statut est le dernier du dernier tampon, s'il est au
        // disque d'y écrire.
        let statut_a = chaine
            .last()
            .filter(|d| d.inscriptible() && d.longueur >= 1)
            .map(|d| d.adresse.wrapping_add(u64::from(d.longueur) - 1));

        // **Une tête encore partie, ou un octet de statut qu'une requête
        // partie attend d'écrire, n'appartient pas à cette entrée.** Le
        // pilote ne republie une tête qu'après l'avoir reçue servie ; celle-ci
        // est donc une erreur du pilote, rendue en erreur pour ne pas le
        // laisser attendre — mais sans écrire l'octet de statut, qui est
        // celui de la requête en vol : son « réussi », plus tard, ne doit pas
        // avoir été précédé d'un « erreur » qu'elle n'a pas mérité.
        if self
            .en_vol
            .iter()
            .any(|v| v.tete == tete || (statut_a.is_some() && v.statut_a == statut_a))
        {
            self.refuser(tete, None, ram);
            return true;
        }

        let (Some(entete), Some(dernier)) = (chaine.first().copied(), chaine.last().copied())
        else {
            self.refuser(tete, statut_a, ram);
            return true;
        };
        if chaine.len() < 2
            || entete.longueur < 16
            || !dernier.inscriptible()
            || dernier.longueur < 1
        {
            self.refuser(tete, statut_a, ram);
            return true;
        }
        let (Some(genre), Some(secteur)) = (
            lire_u32(ram, entete.adresse),
            lire_u64(ram, entete.adresse.wrapping_add(8)),
        ) else {
            self.refuser(tete, statut_a, ram);
            return true;
        };
        let donnees = &chaine[1..chaine.len() - 1];
        let etendue: u64 = donnees.iter().map(|d| u64::from(d.longueur)).sum();
        // **Un secteur qui n'existe pas est une erreur, pas des zéros** :
        // un système de fichiers y lirait un superbloc vide au lieu
        // d'apprendre qu'il a demandé trop loin.
        if (genre == 0 || genre == 1) && au_dela_du_disque(secteur, etendue, self.secteurs) {
            self.refuser(tete, statut_a, ram);
            return true;
        }
        match genre {
            0 | 1 => {
                let sens = if genre == 0 { Sens::Lire } else { Sens::Ecrire };
                return self.faire_partir(tete, sens, secteur, etendue, donnees, statut_a, ram);
            }
            8 => {
                // L'identifiant du disque, vingt octets, que le noyau lit pour
                // son attribut `serial`.
                let mut ecrits = 0u32;
                for tampon in donnees.iter().filter(|d| d.inscriptible()) {
                    ecrire_le_nom(ram, tampon.adresse, tampon.longueur);
                    ecrits = ecrits.wrapping_add(tampon.longueur);
                }
                self.servies += 1;
                self.rendre(tete, ecrits, REUSSI, statut_a, ram);
            }
            _ => {
                self.refusees += 1;
                self.rendre(tete, 0, NON_SUPPORTE, statut_a, ram);
            }
        }
        true
    }

    /// **Faire partir une lecture ou une écriture**, ou la refuser tout de
    /// suite si elle ne peut pas aboutir. `false` : elle ne tient pas encore,
    /// rien n'est fait, la file attend.
    #[allow(clippy::too_many_arguments)]
    fn faire_partir(
        &mut self,
        tete: u16,
        sens: Sens,
        secteur: u64,
        etendue: u64,
        donnees: &[Descripteur],
        statut_a: Option<u64>,
        ram: &mut dyn Ram,
    ) -> bool {
        // Le sens de chaque tampon : le disque écrit dans ceux d'une
        // lecture, et lit ceux d'une écriture.
        let lecture = sens == Sens::Lire;
        if donnees.iter().any(|d| d.inscriptible() != lecture) || etendue > PLUS_GRANDE_REQUETE {
            self.refuser(tete, statut_a, ram);
            return true;
        }
        // **Chaque tampon entier dans la RAM, vérifié avant de partir.** Le
        // cœur Swift perd en silence l'octet d'une lecture qui tombe hors de
        // la RAM, et lit zéro pour une écriture ; ici la requête partirait,
        // et l'arrière lirait la plage pour rien. Un tampon qui sort de la
        // RAM est une erreur que le pilote voit. La RAM de l'invité est d'un
        // seul bloc : son premier et son dernier octet suffisent.
        if !donnees
            .iter()
            .all(|d| dans_la_ram(ram, d.adresse, d.longueur))
        {
            self.refuser(tete, statut_a, ram);
            return true;
        }
        // Rien à lire ni à écrire : réussi, sans déranger l'arrière.
        if donnees.is_empty() {
            self.servies += 1;
            self.rendre(tete, 0, REUSSI, statut_a, ram);
            return true;
        }
        // **Pas plus de 128 requêtes dehors.** Une tête encore partie est déjà
        // refusée plus haut ; mais rien n'oblige le pilote à nommer des têtes
        // de moins de 128 (le cœur Swift ne le vérifie pas non plus, et suit
        // la table aussi loin qu'on lui dit), si bien qu'un pilote fautif
        // pourrait en faire partir des milliers. La 129ᵉ est refusée.
        if self.en_vol.len() >= LIMITE_DE_FILE as usize {
            self.refuser(tete, statut_a, ram);
            return true;
        }
        // Les oubliées prennent aussi une place : sans quoi un invité qui
        // boucle « remise, 128 requêtes » en ferait partir sans fin. Le
        // pilote n'y est pour rien (ses têtes sont distinctes) : sa requête
        // attend, et la réponse d'une oubliée la fera reprendre.
        if self.dehors() >= LIMITE_DE_FILE as usize {
            return false;
        }
        // **La borne de la somme, avant d'allouer quoi que ce soit.** Ce qui
        // ne tient pas attend une réponse ; une requête seule tient toujours
        // (la borne par requête vaut la borne de la somme), donc la file ne
        // peut pas attendre sans requête dehors, en vol ou oubliée, dont la
        // réponse la reprendra.
        if self.tenus() + etendue > PLUS_TENU {
            return false;
        }
        let mut octets = Vec::new();
        if sens == Sens::Ecrire {
            octets.resize(etendue as usize, 0);
            let mut a = 0usize;
            for d in donnees {
                let fin = a + d.longueur as usize;
                if !ram.lire(d.adresse, &mut octets[a..fin]) {
                    self.refuser(tete, statut_a, ram);
                    return true;
                }
                a = fin;
            }
        }
        let id = self.prochain_id;
        // Jamais zéro, et jamais au-delà de 2³¹ : la page le reçoit en
        // nombre signé.
        self.prochain_id = (self.prochain_id % 0x7FFF_FFFF) + 1;
        self.a_envoyer.push_back(RequeteDisque {
            id,
            sens,
            decalage: secteur * 512,
            longueur: etendue,
            octets,
        });
        self.en_vol.push(EnVol {
            id,
            tete,
            sens,
            longueur: etendue,
            tampons: if lecture {
                donnees.iter().map(|d| (d.adresse, d.longueur)).collect()
            } else {
                Vec::new()
            },
            statut_a,
        });
        true
    }

    fn refuser(&mut self, tete: u16, statut_a: Option<u64>, ram: &mut dyn Ram) {
        self.refusees += 1;
        self.rendre(tete, 0, ERREUR, statut_a, ram);
    }

    /// **Rendre une requête** : poser le statut, la ranger dans l'anneau des
    /// servies, et lever la ligne. Le statut d'abord, l'index ensuite : le
    /// pilote ne lit pas une requête que l'index n'a pas publiée.
    fn rendre(
        &mut self,
        tete: u16,
        ecrits: u32,
        statut: u8,
        statut_a: Option<u64>,
        ram: &mut dyn Ram,
    ) {
        if let Some(a) = statut_a {
            ram.ecrire(a, &[statut]);
        }
        if self.taille_de_file == 0 {
            return;
        }
        let place = u64::from(self.prochain_servi % self.taille_de_file as u16);
        let entree = self.anneau_servi.wrapping_add(4 + place * 8);
        ram.ecrire(entree, &u32::from(tete).to_le_bytes());
        ram.ecrire(entree.wrapping_add(4), &ecrits.to_le_bytes());
        self.prochain_servi = self.prochain_servi.wrapping_add(1);
        ram.ecrire(
            self.anneau_servi.wrapping_add(2),
            &self.prochain_servi.to_le_bytes(),
        );
        self.isr |= 1;
    }

    // ---------------------------------------------------------- l'arrière

    /// **La prochaine requête pour l'arrière**, dans l'ordre où le pilote les
    /// a posées. Une fois prise, elle attend sa réponse.
    pub fn prendre_requete(&mut self) -> Option<RequeteDisque> {
        self.a_envoyer.pop_front()
    }

    fn retirer(&mut self, id: u32) -> Option<EnVol> {
        let rang = self.en_vol.iter().position(|v| v.id == id)?;
        // Une réponse peut venir pour une requête que la boucle n'a pas encore
        // prise (un arrière qui répond de lui-même) : elle ne partira plus.
        self.a_envoyer.retain(|r| r.id != id);
        Some(self.en_vol.remove(rang))
    }

    /// **Les octets d'une lecture sont arrivés.** Ils sont copiés dans les
    /// tampons du pilote, la requête est rendue, la ligne se lève.
    ///
    /// Rend `false` quand `id` ne nomme aucune requête partie — déjà rendue,
    /// ou oubliée par une remise à zéro : rien n'est touché. Des octets qui ne
    /// sont pas de la longueur demandée (un fichier plus court que le disque
    /// annoncé) rendent la requête en erreur d'entrée-sortie : jamais des
    /// zéros à la place de ce qui manque.
    ///
    /// La place rendue fait partir ce que la file laissait attendre : de
    /// nouvelles requêtes peuvent être à prendre après la réponse.
    pub fn lu(&mut self, id: u32, octets: &[u8], ram: &mut dyn Ram) -> bool {
        let Some(vol) = self.retirer(id) else {
            self.liberer_une_oubliee(id, ram);
            return false;
        };
        self.copier_et_rendre(&vol, octets, ram);
        self.reprendre(ram);
        true
    }

    fn copier_et_rendre(&mut self, vol: &EnVol, octets: &[u8], ram: &mut dyn Ram) {
        if vol.sens != Sens::Lire || octets.len() as u64 != vol.longueur {
            return self.refuser(vol.tete, vol.statut_a, ram);
        }
        let mut a = 0usize;
        for &(adresse, longueur) in &vol.tampons {
            let fin = a + longueur as usize;
            if !ram.ecrire(adresse, &octets[a..fin]) {
                return self.refuser(vol.tete, vol.statut_a, ram);
            }
            a = fin;
        }
        self.servies += 1;
        self.rendre(vol.tete, vol.longueur as u32, REUSSI, vol.statut_a, ram);
    }

    /// **Une réponse a rendu de la place** : ce que la file avait laissé
    /// attendre ([`PLUS_TENU`]) est lu maintenant, sans attendre une autre
    /// notification que le pilote n'enverra pas — il a déjà publié. La boucle
    /// hôte prend donc les requêtes après chaque réponse, comme après chaque
    /// `out`.
    fn reprendre(&mut self, ram: &mut dyn Ram) {
        if self.prete {
            self.servir(ram);
        }
    }

    /// **La réponse d'une requête oubliée** : rien n'est rendu au pilote, rien
    /// n'est écrit dans la RAM, mais sa place est rendue, et la file qui
    /// l'attendait reprend.
    fn liberer_une_oubliee(&mut self, id: u32, ram: &mut dyn Ram) {
        let Some(rang) = self.oubliees.iter().position(|&(nom, _)| nom == id) else {
            return;
        };
        self.oubliees.swap_remove(rang);
        self.reprendre(ram);
    }

    /// **Une requête est finie sans octets à rendre** : une écriture que
    /// l'arrière a faite (`reussi`), ou toute requête qu'il n'a pas pu faire.
    /// Une lecture « réussie » sans ses octets n'existe pas : elle est rendue
    /// en erreur. `false` quand `id` ne nomme aucune requête partie. Comme
    /// [`VirtioBlk::lu`], la réponse peut faire partir ce qui attendait.
    pub fn fini(&mut self, id: u32, reussi: bool, ram: &mut dyn Ram) -> bool {
        let Some(vol) = self.retirer(id) else {
            self.liberer_une_oubliee(id, ram);
            return false;
        };
        if reussi && vol.sens == Sens::Ecrire {
            self.servies += 1;
            self.rendre(vol.tete, 0, REUSSI, vol.statut_a, ram);
        } else {
            self.refuser(vol.tete, vol.statut_a, ram);
        }
        self.reprendre(ram);
        true
    }
}

/// **Où tombent les trois anneaux** de la forme ancienne, pour une page et
/// une taille : `vring_init`, à la lettre. Se tromper d'un octet fait lire au
/// disque un anneau que personne n'a écrit.
pub fn anneaux(page: u32, taille: u32) -> (u64, u64, u64) {
    let descripteurs = u64::from(page) * 4096;
    let disponibles = descripteurs + u64::from(taille) * 16;
    let apres = disponibles + 6 + u64::from(taille) * 2;
    let servies = (apres + 4095) & !4095;
    (descripteurs, disponibles, servies)
}

/// **La requête sort-elle du disque ?** Sans arithmétique qui fait le tour :
/// `secteur` est lu dans la RAM de l'invité, il le choisit entièrement, et
/// `secteur × 512 + étendue` en arithmétique enveloppante peut retomber à
/// zéro — donc « pas au-delà » — pour un secteur astronomique (le cas est
/// démontré du côté Swift, `beyondTheDisk`).
pub fn au_dela_du_disque(secteur: u64, etendue: u64, secteurs: u64) -> bool {
    let Some(debut) = secteur.checked_mul(512) else {
        return true;
    };
    let Some(fin) = debut.checked_add(etendue) else {
        return true;
    };
    // La capacité vient du disque réel et ne peut pas déborder ; un disque
    // impossible ne refuse rien de plus.
    let Some(capacite) = secteurs.checked_mul(512) else {
        return false;
    };
    fin > capacite
}

pub(crate) fn lire_u16(ram: &dyn Ram, a: u64) -> Option<u16> {
    let mut o = [0; 2];
    ram.lire(a, &mut o).then(|| u16::from_le_bytes(o))
}

fn lire_u32(ram: &dyn Ram, a: u64) -> Option<u32> {
    let mut o = [0; 4];
    ram.lire(a, &mut o).then(|| u32::from_le_bytes(o))
}

fn lire_u64(ram: &dyn Ram, a: u64) -> Option<u64> {
    let mut o = [0; 8];
    ram.lire(a, &mut o).then(|| u64::from_le_bytes(o))
}

/// Le premier et le dernier octet d'un tampon sont-ils dans la RAM ?
fn dans_la_ram(ram: &dyn Ram, adresse: u64, longueur: u32) -> bool {
    if longueur == 0 {
        return true;
    }
    let Some(dernier) = adresse.checked_add(u64::from(longueur) - 1) else {
        return false;
    };
    let mut un = [0u8];
    ram.lire(adresse, &mut un) && ram.lire(dernier, &mut un)
}

/// Le nom du disque, puis des zéros jusqu'au bout du tampon, par morceaux :
/// un tampon de quatre gibioctets ne fait rien allouer.
fn ecrire_le_nom(ram: &mut dyn Ram, adresse: u64, longueur: u32) {
    const NOM: &[u8] = b"wisq-disk";
    const MORCEAU: usize = 4096;
    let mut zeros = [0u8; MORCEAU];
    let mut fait = 0u64;
    let longueur = u64::from(longueur);
    while fait < longueur {
        let n = (longueur - fait).min(MORCEAU as u64) as usize;
        zeros.fill(0);
        if fait == 0 {
            let k = NOM.len().min(n);
            zeros[..k].copy_from_slice(&NOM[..k]);
        }
        ram.ecrire(adresse.wrapping_add(fait), &zeros[..n]);
        fait += n as u64;
    }
}

// ------------------------------------------------- l'état, pour l'instantané

impl VirtioBlk {
    /// **Le disque est au repos** : aucune requête partie, oubliée ou en
    /// attente d'une réponse, et la file n'attend rien. C'est toujours le
    /// cas entre deux instructions de la machine native, qui sert chaque
    /// requête pendant l'`out` qui la notifie ([`super::pc::CartePc::servir`]) ;
    /// l'instantané ne prend que ce disque-là.
    pub fn au_repos(&self) -> bool {
        self.a_envoyer.is_empty()
            && self.en_vol.is_empty()
            && self.oubliees.is_empty()
            && !self.file_attend
    }

    /// **L'état du disque au repos**, pour l'instantané de la machine native
    /// ([`super::etat`]) : sa capacité, ce que le pilote a écrit (les
    /// fonctions acceptées, le statut, la file choisie, sa page, sa taille et
    /// ses trois anneaux), l'ISR, **les deux index** que seul le disque
    /// tient (le prochain disponible à lire, le prochain servi à écrire), les
    /// compteurs, et le nom de la prochaine requête. À n'appeler que sur un
    /// disque [`VirtioBlk::au_repos`] : rien de ce qui est en vol n'est écrit.
    pub(crate) fn sauver(&self, e: &mut Ecrivain) {
        e.u64(self.secteurs);
        e.u32(self.fonctions_du_pilote);
        e.u8(self.statut);
        e.u16(self.file_choisie);
        e.u32(self.page_de_file);
        e.u32(self.taille_de_file);
        e.oui(self.prete);
        e.u64(self.table);
        e.u64(self.anneau_disponible);
        e.u64(self.anneau_servi);
        e.u8(self.isr);
        e.u16(self.prochain_disponible);
        e.u16(self.prochain_servi);
        e.u64(self.servies);
        e.u64(self.refusees);
        e.u32(self.prochain_id);
    }

    /// Relu, au repos, ou rien. Sont refusés : une taille de file qui n'est
    /// ni zéro ni [`LIMITE_DE_FILE`] ; une file prête sans sa taille, sans sa
    /// page, ou dont les anneaux ne sont pas ceux de sa page ; une file qui
    /// n'est pas prête et garde une taille ; un ISR qui n'est pas un bit de
    /// file ; **deux index qui ne se suivent pas** — au repos, chaque entrée
    /// lue a reçu sa réponse, donc le prochain servi est le prochain
    /// disponible ; un nom de requête nul ou au-delà de 2³¹ − 1.
    pub(crate) fn relire(l: &mut Lecteur) -> Option<Self> {
        let mut disque = Self::nouveau(l.u64()?);
        disque.fonctions_du_pilote = l.u32()?;
        disque.statut = l.u8()?;
        disque.file_choisie = l.u16()?;
        disque.page_de_file = l.u32()?;
        disque.taille_de_file = l.u32()?;
        disque.prete = l.oui()?;
        disque.table = l.u64()?;
        disque.anneau_disponible = l.u64()?;
        disque.anneau_servi = l.u64()?;
        disque.isr = l.u8()?;
        disque.prochain_disponible = l.u16()?;
        disque.prochain_servi = l.u16()?;
        disque.servies = l.u64()?;
        disque.refusees = l.u64()?;
        disque.prochain_id = l.u32()?;
        let file = if disque.prete {
            disque.taille_de_file == LIMITE_DE_FILE
                && disque.page_de_file != 0
                && (disque.table, disque.anneau_disponible, disque.anneau_servi)
                    == anneaux(disque.page_de_file, LIMITE_DE_FILE)
        } else {
            disque.taille_de_file == 0
        };
        let valide = file
            && disque.isr <= 1
            && disque.prochain_servi == disque.prochain_disponible
            && (1..=0x7FFF_FFFF).contains(&disque.prochain_id);
        valide.then_some(disque)
    }
}

#[cfg(test)]
mod tests {
    //! **Le disque, conduit comme le pilote de Linux le conduit** : les dix-sept
    //! cas de `Tests/WisqVMTests/VirtioBlockTests.swift`, portés à la forme
    //! ancienne, puis ce que l'asynchronie ajoute. La file est bâtie en
    //! mémoire à la main, comme `Tests/WisqVMTests/VirtioQueue.swift` la bâtit,
    //! mais là où la forme ancienne la met : un numéro de page, et
    //! `vring_init` pour le reste.
    //!
    //! Les cas Swift qui jugent le transport MMIO (le magique, la version,
    //! `VERSION_1`, la fenêtre derrière la mémoire) sont portés vers ce que la
    //! forme ancienne présente à leur place, et le disent dans leur nom. Une
    //! requête de lecture ou d'écriture **part** ici au lieu d'être servie
    //! pendant la notification : chaque cas vérifie que rien n'est rendu avant
    //! la réponse de l'arrière, puis tout ce que le cas Swift vérifie après.
    use super::super::{Carte, RamPlate, SansRam};
    use super::*;

    /// La file, posée à la page 1 : les descripteurs à `0x1000`, les
    /// disponibles à `0x1800`, les servies à `0x2000`. L'en-tête et le statut
    /// à `0x4000`, les tampons à `0x5000` et au-delà.
    pub(crate) struct File;

    impl File {
        pub(crate) const PAGE: u32 = 1;
        pub(crate) const DESCRIPTEURS: u64 = 0x1000;
        pub(crate) const DISPONIBLES: u64 = 0x1800;
        pub(crate) const SERVIES: u64 = 0x2000;
        pub(crate) const BROUILLON: u64 = 0x4000;
        pub(crate) const STATUT: u64 = 0x4800;

        /// **La poignée de main du pilote, dans son ordre** (`virtio_pci_legacy`) :
        /// remise à zéro, ACKNOWLEDGE, DRIVER, les fonctions lues puis
        /// acceptées, FEATURES_OK, la file zéro choisie, sa taille lue, son
        /// numéro de page écrit, DRIVER_OK.
        pub(crate) fn demarrer(disque: &mut VirtioBlk, ram: &mut RamPlate) {
            disque.ecrire_port(0x12, 0, ram);
            disque.ecrire_port(0x12, 1, ram);
            disque.ecrire_port(0x12, 3, ram);
            let offertes = disque.lire_port(0x00, 4);
            disque.ecrire_port(0x04, offertes, ram);
            disque.ecrire_port(0x12, 11, ram);
            disque.ecrire_port(0x0E, 0, ram);
            assert_eq!(disque.lire_port(0x0C, 2), LIMITE_DE_FILE);
            assert_eq!(disque.lire_port(0x08, 4), 0, "aucune file encore");
            disque.ecrire_port(0x08, Self::PAGE, ram);
            disque.ecrire_port(0x12, 15, ram);
        }

        /// Poser un descripteur.
        pub(crate) fn decrire(
            ram: &mut RamPlate,
            index: u64,
            a: u64,
            longueur: u32,
            inscriptible: bool,
            suivant: Option<u16>,
        ) {
            let at = Self::DESCRIPTEURS + index * 16;
            ram.ecrire(at, &a.to_le_bytes());
            ram.ecrire(at + 8, &longueur.to_le_bytes());
            let drapeaux = u16::from(inscriptible) * 2 + u16::from(suivant.is_some());
            ram.ecrire(at + 12, &drapeaux.to_le_bytes());
            ram.ecrire(at + 14, &suivant.unwrap_or(0).to_le_bytes());
        }

        /// **Une requête complète**, en descripteurs 0, 1, 2 : l'en-tête, un
        /// tampon, l'octet de statut (posé à `0xFF`, ni réussite ni échec),
        /// puis publiée à l'entrée `entree` de l'anneau des disponibles.
        pub(crate) fn requete(
            ram: &mut RamPlate,
            genre: u32,
            secteur: u64,
            tampon: (u64, u32, bool),
            entree: u16,
        ) {
            ram.ecrire(Self::BROUILLON, &genre.to_le_bytes());
            ram.ecrire(Self::BROUILLON + 4, &0u32.to_le_bytes());
            ram.ecrire(Self::BROUILLON + 8, &secteur.to_le_bytes());
            Self::decrire(ram, 0, Self::BROUILLON, 16, false, Some(1));
            Self::decrire(ram, 1, tampon.0, tampon.1, tampon.2, Some(2));
            Self::decrire(ram, 2, Self::STATUT, 1, true, None);
            ram.ecrire(Self::STATUT, &[0xFF]);
            // L'entrée, puis l'index qui la publie.
            ram.ecrire(
                Self::DISPONIBLES + 4 + u64::from(entree) * 2,
                &0u16.to_le_bytes(),
            );
            ram.ecrire(Self::DISPONIBLES + 2, &(entree + 1).to_le_bytes());
        }

        pub(crate) fn statut(ram: &RamPlate) -> u8 {
            ram.0[Self::STATUT as usize]
        }

        pub(crate) fn servies(ram: &RamPlate) -> u16 {
            u16::from_le_bytes([ram.0[0x2002], ram.0[0x2003]])
        }

        /// L'entrée `n` de l'anneau des servies : la tête et la longueur.
        pub(crate) fn servie(ram: &RamPlate, n: u64) -> (u32, u32) {
            let a = (Self::SERVIES + 4 + n * 8) as usize;
            let mot =
                |a: usize| u32::from_le_bytes([ram.0[a], ram.0[a + 1], ram.0[a + 2], ram.0[a + 3]]);
            (mot(a), mot(a + 4))
        }
    }

    /// Un disque de quatre secteurs, chacun rempli de son propre numéro.
    fn image() -> Vec<u8> {
        (0..4u8).flat_map(|s| [s + 1; 512]).collect()
    }

    fn demarre() -> (VirtioBlk, RamPlate) {
        let mut disque = VirtioBlk::nouveau(4);
        let mut ram = RamPlate(vec![0; 0x10000]);
        File::demarrer(&mut disque, &mut ram);
        (disque, ram)
    }

    /// **L'arrière des tests** : une image en mémoire. Il prend tout ce qui
    /// est parti et y répond, d'un coup — ce que la boucle hôte fera quand la
    /// réponse arrivera.
    fn repondre(disque: &mut VirtioBlk, image: &mut [u8], ram: &mut RamPlate) -> usize {
        let mut n = 0;
        while let Some(r) = disque.prendre_requete() {
            let plage = r.decalage as usize..(r.decalage + r.longueur) as usize;
            match r.sens {
                Sens::Lire => assert!(disque.lu(r.id, &image[plage], ram)),
                Sens::Ecrire => {
                    image[plage].copy_from_slice(&r.octets);
                    assert!(disque.fini(r.id, true, ram));
                }
            }
            n += 1;
        }
        n
    }

    fn notifier(disque: &mut VirtioBlk, ram: &mut RamPlate) {
        disque.ecrire_port(0x10, 0, ram);
    }

    // --------------------------------------------------------- la découverte

    /// **Ce que la forme ancienne présente à la place du magique** : ses
    /// identifiants sont au bus (`1AF4:1001`, jugés dans `pci.rs`), et sa
    /// fenêtre dit d'abord la taille de sa file, puis qu'aucune file n'est
    /// posée, aucun statut, aucune interruption. C'est ce que lit `setup_vq`
    /// avant tout : une taille nulle ou une file déjà posée, et le pilote
    /// renonce.
    #[test]
    fn the_device_introduces_itself_through_its_window() {
        let mut disque = VirtioBlk::nouveau(4);
        assert_eq!(disque.lire_port(0x0C, 2), 128, "la taille de la file");
        assert_eq!(disque.lire_port(0x08, 4), 0, "aucune file posée");
        assert_eq!(disque.lire_port(0x12, 1), 0, "aucun statut");
        assert_eq!(disque.lire_port(0x13, 1), 0, "aucune interruption");
        assert_eq!(
            disque.lire_port(0x3F, 1),
            0,
            "un registre inconnu se lit zéro"
        );
    }

    /// **Aucune fonction n'est offerte**, et c'est ce qu'il faut à la forme
    /// ancienne : `VERSION_1`, le seul bit que la forme moderne annonce, n'y
    /// existe pas (les fonctions n'y ont que trente-deux bits). Ce que le
    /// pilote accepte est gardé.
    #[test]
    fn no_feature_is_offered_in_the_old_form() {
        let mut disque = VirtioBlk::nouveau(4);
        for largeur in [1, 2, 4] {
            assert_eq!(disque.lire_port(0x00, largeur), 0);
        }
        disque.ecrire_port(0x04, 0, &mut SansRam);
        assert_eq!(disque.fonctions_du_pilote, 0);
    }

    /// La capacité, en secteurs de 512 octets, aux octets `0x14` à `0x1B` :
    /// ce que le noyau imprime, « [vda] 4 512-byte logical blocks ». Et une
    /// ISO de 1,4 Gio et au-delà de 2³² secteurs se lit en deux mots.
    #[test]
    fn the_capacity_is_the_disk_in_sectors() {
        let mut disque = VirtioBlk::nouveau(4);
        assert_eq!(disque.lire_port(0x14, 4), 4);
        assert_eq!(disque.lire_port(0x18, 4), 0);
        assert_eq!(disque.lire_port(0x14, 1), 4, "lue d'un octet");
        let mut grand = VirtioBlk::nouveau((2 << 32) + 0x0102_0304);
        assert_eq!(grand.lire_port(0x14, 4), 0x0102_0304);
        assert_eq!(grand.lire_port(0x18, 4), 2);
        assert_eq!(grand.lire_port(0x15, 2), 0x0203, "d'où l'on veut");
        assert_eq!(grand.lire_port(0x1A, 4), 0, "pas au-delà du huitième");
        assert_eq!(grand.lire_port(0x1B, 1), 0);
    }

    // ---------------------------------------------------------- les requêtes

    /// **Une lecture part, puis revient.** Avant la réponse : rien n'est
    /// rendu, aucune ligne, et l'arrière a une plage à lire — le secteur deux,
    /// 512 octets à 1 024. Après : le secteur dans le tampon, l'octet de
    /// statut à « réussi », l'anneau des servies d'un cran, la ligne levée.
    #[test]
    fn a_read_brings_the_sector_back() {
        let (mut disque, mut ram) = demarre();
        File::requete(&mut ram, 0, 2, (0x5000, 512, true), 0);
        assert!(!disque.interrompt(), "rien n'a encore été demandé");
        notifier(&mut disque, &mut ram);

        assert!(!disque.interrompt(), "partie, pas revenue");
        assert_eq!(File::statut(&ram), 0xFF, "ni réussite ni échec");
        assert_eq!(File::servies(&ram), 0);
        assert!(disque.en_attente());
        let requete = disque.prendre_requete().expect("une requête partie");
        assert_eq!(
            (requete.sens, requete.decalage, requete.longueur),
            (Sens::Lire, 1024, 512)
        );
        assert!(requete.octets.is_empty());
        assert!(disque.lu(requete.id, &image()[1024..1536], &mut ram));

        assert_eq!(File::statut(&ram), 0, "réussi");
        assert_eq!(ram.0[0x5000], 3, "le secteur deux porte des 3");
        assert_eq!(ram.0[0x5000 + 511], 3, "jusqu'au bout");
        assert_eq!(ram.0[0x5000 + 512], 0, "et pas un octet de plus");
        assert_eq!(File::servies(&ram), 1, "une requête servie");
        assert_eq!(File::servie(&ram, 0), (0, 512), "la tête zéro, 512 octets");
        assert!(disque.interrompt());
        assert!(!disque.en_attente());
        assert_eq!(disque.servies, 1);
        assert!(
            !disque.lu(requete.id, &image()[..512], &mut ram),
            "une fois"
        );
    }

    /// **L'interruption s'acquitte en lisant le registre `0x13`**, la règle
    /// de la forme ancienne, et pas autrement.
    #[test]
    fn the_interrupt_is_acknowledged() {
        let (mut disque, mut ram) = demarre();
        File::requete(&mut ram, 0, 0, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        repondre(&mut disque, &mut image(), &mut ram);
        assert!(disque.interrompt());
        assert_eq!(disque.lire_port(0x12, 1), 15, "le statut ne l'acquitte pas");
        assert!(disque.interrompt());
        assert_eq!(disque.lire_port(0x13, 1), 1);
        assert!(!disque.interrompt());
        assert_eq!(disque.lire_port(0x13, 1), 0, "une fois");
    }

    /// **Une écriture part avec ses octets**, recopiés de la RAM au départ,
    /// et ne change que le secteur demandé.
    #[test]
    fn a_write_changes_the_disk() {
        let (mut disque, mut ram) = demarre();
        let mut disque_image = image();
        ram.0[0x5000..0x5200].fill(0xAB);
        File::requete(&mut ram, 1, 1, (0x5000, 512, false), 0);
        notifier(&mut disque, &mut ram);
        // Le pilote ne touche plus au tampon, mais s'il le faisait, c'est ce
        // qui était là à la notification qui part.
        ram.0[0x5000..0x5200].fill(0xCD);
        assert_eq!(File::statut(&ram), 0xFF);
        let requete = disque.prendre_requete().expect("partie");
        assert_eq!((requete.sens, requete.decalage), (Sens::Ecrire, 512));
        assert_eq!(requete.octets, vec![0xAB; 512]);
        disque_image[512..1024].copy_from_slice(&requete.octets);
        assert!(disque.fini(requete.id, true, &mut ram));

        assert_eq!(File::statut(&ram), 0);
        assert_eq!(File::servie(&ram, 0), (0, 0), "rien d'écrit en RAM");
        assert_eq!(disque_image[512], 0xAB, "le secteur un a changé");
        assert_eq!(disque_image[1023], 0xAB);
        assert_eq!(disque_image[0], 1, "le secteur zéro, non");
        assert_eq!(disque_image[1024], 3, "le secteur deux non plus");
    }

    /// **Un secteur au-delà du disque est une erreur**, rendue tout de suite :
    /// rien ne part vers l'arrière.
    #[test]
    fn a_sector_beyond_the_disk_is_refused() {
        let (mut disque, mut ram) = demarre();
        File::requete(&mut ram, 0, 99, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        assert_eq!(File::statut(&ram), 1, "erreur d'entrée-sortie");
        assert_eq!(disque.refusees, 1);
        assert_eq!(disque.servies, 0);
        assert_eq!(disque.prendre_requete(), None, "rien n'est parti");
        assert!(disque.interrompt(), "et la réponse est là");
        // Le dernier secteur, tout juste, part ; un de plus, non.
        File::requete(&mut ram, 0, 3, (0x5000, 1024, true), 1);
        notifier(&mut disque, &mut ram);
        assert_eq!(disque.prendre_requete(), None);
        assert_eq!(disque.refusees, 2);
    }

    /// Un type que ce disque ne connaît pas se répond « non supporté », tout
    /// de suite — pas par le silence.
    #[test]
    fn an_unknown_request_is_answered_anyway() {
        let (mut disque, mut ram) = demarre();
        File::requete(&mut ram, 99, 0, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        assert_eq!(File::statut(&ram), 2, "non supporté");
        assert_eq!(File::servies(&ram), 1, "et la requête est rendue");
        assert_eq!(disque.prendre_requete(), None);
        // Un « flush » (genre 4) aussi : il n'est pas annoncé.
        File::requete(&mut ram, 4, 0, (0x5000, 512, true), 1);
        notifier(&mut disque, &mut ram);
        assert_eq!(File::statut(&ram), 2);
    }

    /// L'identifiant du disque, vingt octets, rendu tout de suite.
    #[test]
    fn the_disk_says_its_name() {
        let (mut disque, mut ram) = demarre();
        ram.0[0x5000..0x5020].fill(0x55);
        File::requete(&mut ram, 8, 0, (0x5000, 20, true), 0);
        notifier(&mut disque, &mut ram);
        assert_eq!(File::statut(&ram), 0);
        assert_eq!(&ram.0[0x5000..0x5009], b"wisq-disk");
        assert_eq!(ram.0[0x5009..0x5014], [0; 11], "puis des zéros");
        assert_eq!(ram.0[0x5014], 0x55, "et pas au-delà du tampon");
        assert_eq!(File::servie(&ram, 0), (0, 20));
        assert_eq!(disque.prendre_requete(), None);
    }

    /// **Deux requêtes d'affilée avancent l'anneau de deux** : l'index des
    /// disponibles se suit.
    #[test]
    fn two_requests_in_a_row_are_both_served() {
        let (mut disque, mut ram) = demarre();
        let mut disque_image = image();
        File::requete(&mut ram, 0, 0, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        repondre(&mut disque, &mut disque_image, &mut ram);
        // La seconde entrée de l'anneau des disponibles, puis son index ; le
        // secteur un, cette fois.
        File::requete(&mut ram, 0, 1, (0x5000, 512, true), 1);
        notifier(&mut disque, &mut ram);
        assert_eq!(
            repondre(&mut disque, &mut disque_image, &mut ram),
            1,
            "une seule part"
        );
        assert_eq!(disque.servies, 2);
        assert_eq!(File::servies(&ram), 2);
        assert_eq!(ram.0[0x5000], 2, "le secteur un porte des 2");
    }

    /// Une file que le pilote a retirée (numéro de page zéro) ne sert rien.
    #[test]
    fn a_queue_that_is_not_ready_serves_nothing() {
        let (mut disque, mut ram) = demarre();
        disque.ecrire_port(0x08, 0, &mut ram);
        assert!(!disque.file_prete());
        File::requete(&mut ram, 0, 0, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        assert_eq!(disque.servies + disque.refusees, 0);
        assert_eq!(disque.prendre_requete(), None);
        assert_eq!(File::statut(&ram), 0xFF, "personne n'a répondu");
    }

    // ------------------------------------------------- branché derrière la carte

    /// **Les registres répondent par la fenêtre que le noyau a placée**, et
    /// seulement là : le pendant, en forme ancienne, du disque qui répondait
    /// derrière la mémoire.
    #[test]
    fn the_device_answers_through_its_window_only() {
        let mut carte = Carte::nouvelle();
        assert_eq!(
            carte.port_lire(0xC00C, 2, &mut SansRam),
            None,
            "sans disque, personne"
        );
        carte.brancher_disque(4);
        assert_eq!(
            carte.port_lire(0xC00C, 2, &mut SansRam),
            None,
            "pas encore placée"
        );
        ouvrir(&mut carte, 0xC000);
        assert_eq!(carte.port_lire(0xC00C, 2, &mut SansRam), Some(128));
        assert_eq!(carte.port_lire(0xC014, 4, &mut SansRam), Some(4));
        assert_eq!(
            carte.port_lire(0xC040, 1, &mut SansRam),
            None,
            "au-delà, personne"
        );
        // La largeur demandée borne ce qui revient.
        assert_eq!(carte.port_lire(0xC00C, 1, &mut SansRam), Some(128));
    }

    /// **Les ports fixes de la carte gardent la priorité** : une fenêtre
    /// placée par-dessus l'i8042 et l'horloge ne leur vole rien, comme la RAM
    /// gardait ses adresses devant le disque de forme moderne.
    #[test]
    fn the_cards_own_ports_keep_their_priority() {
        let mut carte = Carte::nouvelle();
        carte.brancher_disque(4);
        ouvrir(&mut carte, 0x40);
        assert_eq!(
            carte.pci.premier.dans_la_fenetre(0x60),
            Some(0x20),
            "dans la fenêtre"
        );
        assert_eq!(
            carte.port_lire(0x64, 1, &mut SansRam),
            Some(0x14),
            "l'i8042"
        );
        carte.port_ecrire(0x70, 1, 0x0F, &mut SansRam);
        carte.port_ecrire(0x71, 1, 0x5A, &mut SansRam);
        assert_eq!(
            carte.port_lire(0x71, 1, &mut SansRam),
            Some(0x5A),
            "l'horloge"
        );
        assert_eq!(
            carte.port_lire(0x4C, 2, &mut SansRam),
            Some(128),
            "le disque"
        );
    }

    /// **L'interruption arrive sur la ligne cinq**, quand la réponse arrive et
    /// pas avant ; elle retombe à la lecture de `0x13`. Et c'est la ligne que
    /// le noyau a écrite qui frappe, à l'esclave s'il le faut.
    #[test]
    fn the_disk_interrupt_reaches_line_five() {
        let mut carte = Carte::nouvelle();
        carte.brancher_disque(4);
        assert_ne!(carte.tenues() & (1 << 5), 0, "la ligne du disque est tenue");
        ouvrir(&mut carte, 0xC000);
        let mut ram = RamPlate(vec![0; 0x10000]);
        par_les_ports(&mut carte, &mut ram);
        File::requete(&mut ram, 0, 0, (0x5000, 512, true), 0);
        assert!(!carte.reveil());
        carte.port_ecrire(0xC010, 2, 0, &mut ram);
        assert_eq!(carte.lignes() & (1 << 5), 0, "partie, pas revenue");
        assert!(carte.reveil(), "un hlt attend cette réponse");
        let r = carte.requete_disque().expect("partie");
        assert!(carte.disque_lu(r.id, &image()[..512], &mut ram));
        assert_eq!(carte.lignes(), 1 << 5, "revenue : la ligne cinq");
        assert!(carte.reveil(), "levée, la ligne attend son gestionnaire");
        assert_eq!(carte.port_lire(0xC013, 1, &mut ram), Some(1));
        assert_eq!(carte.lignes(), 0, "acquittée, elle retombe");
        assert!(!carte.reveil());
        // Le noyau écrit la ligne onze : la quatrième de l'esclave frappe.
        carte.port_ecrire(
            0xCF8,
            4,
            super::super::pci::tests::adresse(3, 0x3C),
            &mut ram,
        );
        carte.port_ecrire(0xCFC, 1, 11, &mut ram);
        File::requete(&mut ram, 0, 0, (0x5000, 512, true), 1);
        carte.port_ecrire(0xC010, 2, 0, &mut ram);
        let r = carte.requete_disque().expect("partie");
        carte.disque_lu(r.id, &image()[..512], &mut ram);
        assert_eq!(carte.lignes(), 1 << 11);
        assert_eq!(carte.tenues() & ((1 << 5) | (1 << 11)), 1 << 11);
    }

    /// **Une remise à zéro efface la file**, et la réponse d'une requête
    /// partie avant elle ne trouve plus personne : rien n'est écrit dans la
    /// RAM, ni tampon, ni statut, ni anneau.
    #[test]
    fn a_reset_forgets_the_queue() {
        let (mut disque, mut ram) = demarre();
        File::requete(&mut ram, 0, 0, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        let partie = disque.prendre_requete().expect("partie");
        disque.ecrire_port(0x12, 0, &mut ram);
        assert!(!disque.file_prete());
        assert_eq!(disque.statut(), 0);
        assert!(!disque.en_attente());
        assert!(!disque.lu(partie.id, &image()[..512], &mut ram), "oubliée");
        assert_eq!(ram.0[0x5000], 0, "rien n'est copié");
        assert_eq!(File::statut(&ram), 0xFF);
        assert_eq!(File::servies(&ram), 0);
        assert!(!disque.interrompt());
        // Et la file d'avant ne sert plus rien.
        notifier(&mut disque, &mut ram);
        assert_eq!(disque.prendre_requete(), None);
        assert_eq!(disque.servies, 0);
    }

    // ----------------------------------------- le garde-fou du bout du disque

    /// **Le garde-fou ne fait pas le tour** : `secteur × 512 + étendue`
    /// retomberait à zéro pour `étendue` = 512 × 8 388 607 et `secteur` =
    /// 2⁵⁵ − 8 388 607.
    #[test]
    fn the_end_of_disk_guard_cannot_be_wrapped_past() {
        let etendue: u64 = 512 * 8_388_607;
        let secteur: u64 = (1 << 55) - 8_388_607;
        assert_eq!(
            secteur.wrapping_mul(512).wrapping_add(etendue),
            0,
            "le témoin ne vaut rien si la somme ne retombe pas à zéro"
        );
        assert!(au_dela_du_disque(secteur, etendue, 64));
        assert!(au_dela_du_disque(u64::MAX, 0, 64), "le produit déborde");
    }

    /// Et il laisse passer ce qui tient.
    #[test]
    fn the_end_of_disk_guard_still_lets_an_ordinary_request_through() {
        assert!(!au_dela_du_disque(0, 512, 64), "le premier secteur");
        assert!(!au_dela_du_disque(63, 512, 64), "le dernier, tout juste");
        assert!(au_dela_du_disque(64, 512, 64), "un de trop");
        assert!(au_dela_du_disque(63, 1024, 64), "le dernier, et un de plus");
        assert!(!au_dela_du_disque(1, 0, u64::MAX), "un disque impossible");
    }

    // --------------------------------------------------- ce que l'attente ajoute

    /// **Les réponses peuvent revenir dans le désordre** : virtio le permet,
    /// et l'anneau des servies rend chaque tête avec sa longueur, dans
    /// l'ordre où elles reviennent.
    #[test]
    fn answers_may_come_back_out_of_order() {
        let (mut disque, mut ram) = demarre();
        // Deux chaînes : 0-1-2 (secteur 0 vers 0x5000) et 3-4-5 (secteur 3
        // vers 0x6000, 1 024 octets demandés en deux tampons de 512).
        File::requete(&mut ram, 0, 0, (0x5000, 512, true), 0);
        ram.ecrire(0x4100, &0u32.to_le_bytes());
        ram.ecrire(0x4108, &2u64.to_le_bytes());
        File::decrire(&mut ram, 3, 0x4100, 16, false, Some(4));
        File::decrire(&mut ram, 4, 0x6000, 512, true, Some(6));
        File::decrire(&mut ram, 6, 0x7000, 512, true, Some(5));
        File::decrire(&mut ram, 5, 0x4900, 1, true, None);
        ram.ecrire(File::DISPONIBLES + 6, &3u16.to_le_bytes());
        ram.ecrire(File::DISPONIBLES + 2, &2u16.to_le_bytes());
        notifier(&mut disque, &mut ram);
        let premiere = disque.prendre_requete().expect("la première");
        let seconde = disque.prendre_requete().expect("la seconde");
        assert_eq!((seconde.decalage, seconde.longueur), (1024, 1024));
        assert!(disque.lu(seconde.id, &image()[1024..2048], &mut ram));
        assert_eq!(File::servie(&ram, 0), (3, 1024), "la seconde d'abord");
        assert_eq!(
            (ram.0[0x6000], ram.0[0x61FF], ram.0[0x7000], ram.0[0x71FF]),
            (3, 3, 4, 4)
        );
        assert_eq!(ram.0[0x4900], 0);
        assert_eq!(File::statut(&ram), 0xFF, "la première attend encore");
        assert!(disque.en_attente());
        assert!(disque.lu(premiere.id, &image()[..512], &mut ram));
        assert_eq!(File::servie(&ram, 1), (0, 512));
        assert_eq!(File::servies(&ram), 2);
        assert_eq!(File::statut(&ram), 0);
    }

    /// Une réponse de l'arrière : le disque, le nom de la requête, la RAM.
    type Reponse = dyn Fn(&mut VirtioBlk, u32, &mut RamPlate) -> bool;

    /// **Une réponse qui ne va pas est une erreur que le pilote voit** : des
    /// octets trop courts (un fichier plus petit que le disque annoncé) ou
    /// trop longs, une lecture « finie » sans ses octets, une écriture que
    /// l'arrière n'a pas pu faire. Jamais des zéros à la place de ce qui
    /// manque, ni le début d'une plage qui n'est pas celle demandée.
    #[test]
    fn a_wrong_answer_is_an_io_error() {
        let (mut disque, mut ram) = demarre();
        let cas: [(u32, &Reponse); 4] = [
            (0, &|d, id, ram| d.lu(id, &[7; 511], ram)),
            (0, &|d, id, ram| d.lu(id, &[7; 513], ram)),
            (0, &|d, id, ram| d.fini(id, true, ram)),
            (1, &|d, id, ram| d.fini(id, false, ram)),
        ];
        for (n, (genre, reponse)) in cas.iter().enumerate() {
            File::requete(&mut ram, *genre, 0, (0x5000, 512, *genre == 0), n as u16);
            notifier(&mut disque, &mut ram);
            let r = disque.prendre_requete().expect("partie");
            assert!(reponse(&mut disque, r.id, &mut ram), "cas {n}");
            assert_eq!(File::statut(&ram), 1, "cas {n}");
            assert_eq!(File::servie(&ram, n as u64), (0, 0), "cas {n}");
        }
        assert_eq!(
            ram.0[0x5000], 0,
            "les octets de la mauvaise longueur ne sont pas copiés"
        );
        assert_eq!((disque.servies, disque.refusees), (0, 4));
        // Une écriture « lue » n'en est pas une non plus.
        File::requete(&mut ram, 1, 0, (0x5000, 512, false), 4);
        notifier(&mut disque, &mut ram);
        let r = disque.prendre_requete().expect("partie");
        assert!(disque.lu(r.id, &[0; 512], &mut ram));
        assert_eq!(File::statut(&ram), 1);
        assert!(!disque.fini(9_999, true, &mut ram), "un nom inconnu");
    }

    /// **Ce qui ne peut pas aboutir ne part pas** : un tampon hors de la RAM,
    /// un tampon dans le mauvais sens, une requête plus grande que la borne.
    /// Chacun est rendu en erreur tout de suite, et l'arrière n'en sait rien.
    #[test]
    fn what_cannot_succeed_never_leaves() {
        let (mut disque, mut ram) = demarre();
        let tampons = [
            (0xFF00, 512, true),  // déborde de la RAM de 0x10000
            (0x5000, 512, false), // une lecture vers un tampon que le disque ne peut écrire
        ];
        for (n, tampon) in tampons.into_iter().enumerate() {
            File::requete(&mut ram, 0, 0, tampon, n as u16);
            notifier(&mut disque, &mut ram);
            assert_eq!(disque.prendre_requete(), None, "cas {n}");
            assert_eq!(File::statut(&ram), 1, "cas {n}");
        }
        // Plus grande que la borne : un disque assez grand, et une RAM où le
        // tampon tient.
        let mut grand = VirtioBlk::nouveau(1 << 20);
        // Deux mébioctets de marge : le tampon de la borne plus 512 tient
        // dans la RAM, et c'est la borne seule qui le refuse.
        let mut ram = RamPlate(vec![0; (PLUS_GRANDE_REQUETE + 0x20_0000) as usize]);
        File::demarrer(&mut grand, &mut ram);
        File::requete(
            &mut ram,
            0,
            0,
            (0x10_0000, PLUS_GRANDE_REQUETE as u32 + 512, true),
            0,
        );
        notifier(&mut grand, &mut ram);
        assert_eq!(grand.prendre_requete(), None);
        assert_eq!(File::statut(&ram), 1);
        // La borne elle-même passe.
        File::requete(
            &mut ram,
            0,
            0,
            (0x10_0000, PLUS_GRANDE_REQUETE as u32, true),
            1,
        );
        notifier(&mut grand, &mut ram);
        assert_eq!(
            grand.prendre_requete().map(|r| r.longueur),
            Some(PLUS_GRANDE_REQUETE)
        );
    }

    /// **Une file reposée ailleurs oublie ce qui était parti**, comme une
    /// remise à zéro : la réponse viserait des anneaux que le pilote a
    /// quittés.
    #[test]
    fn a_queue_moved_elsewhere_drops_what_was_in_flight() {
        let (mut disque, mut ram) = demarre();
        File::requete(&mut ram, 0, 0, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        disque.ecrire_port(0x08, 8, &mut ram);
        assert_eq!(disque.a_prendre(), 0, "elle ne partira plus");
        assert!(!disque.en_attente());
        assert_eq!(disque.lire_port(0x08, 4), 8);
        assert!(disque.file_prete());
    }

    /// **Les noms ne reviennent pas** : une requête partie après une remise
    /// à zéro a un autre nom que celle d'avant, et la réponse d'avant ne la
    /// rend pas.
    #[test]
    fn a_late_answer_never_lands_on_a_younger_request() {
        let (mut disque, mut ram) = demarre();
        File::requete(&mut ram, 0, 0, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        let vieille = disque.prendre_requete().expect("partie");
        // Le pilote s'en va et revient : remise à zéro, file rendue (le
        // numéro de page survit à la remise à zéro, comme du côté Swift, et
        // `del_vq` le remet à zéro lui-même), puis la poignée de main.
        disque.ecrire_port(0x12, 0, &mut ram);
        disque.ecrire_port(0x08, 0, &mut ram);
        File::demarrer(&mut disque, &mut ram);
        File::requete(&mut ram, 0, 1, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        let jeune = disque.prendre_requete().expect("partie");
        assert_ne!(vieille.id, jeune.id);
        assert!(!disque.lu(vieille.id, &image()[..512], &mut ram));
        assert_eq!(File::statut(&ram), 0xFF);
        assert!(disque.lu(jeune.id, &image()[512..1024], &mut ram));
        assert_eq!(ram.0[0x5000], 2);
    }

    /// **Une requête aux descripteurs `tete`, `tete + 1`, `tete + 2`**, chacune
    /// avec son en-tête et son octet de statut à elle (posé à `0xFF`), mise à
    /// l'entrée `entree` de l'anneau des disponibles. L'index, qui publie,
    /// est laissé au test.
    fn poser(
        ram: &mut RamPlate,
        tete: u16,
        (genre, secteur): (u32, u64),
        tampon: (u64, u32, bool),
        (entete, statut): (u64, u64),
        entree: u16,
    ) {
        ram.ecrire(entete, &genre.to_le_bytes());
        ram.ecrire(entete + 4, &0u32.to_le_bytes());
        ram.ecrire(entete + 8, &secteur.to_le_bytes());
        let t = u64::from(tete);
        File::decrire(ram, t, entete, 16, false, Some(tete + 1));
        File::decrire(ram, t + 1, tampon.0, tampon.1, tampon.2, Some(tete + 2));
        File::decrire(ram, t + 2, statut, 1, true, None);
        ram.ecrire(statut, &[0xFF]);
        ram.ecrire(
            File::DISPONIBLES + 4 + u64::from(entree % 128) * 2,
            &tete.to_le_bytes(),
        );
    }

    fn publier(ram: &mut RamPlate, index: u16) {
        ram.ecrire(File::DISPONIBLES + 2, &index.to_le_bytes());
    }

    /// **Une tête encore partie est refusée, sans toucher à son statut** : le
    /// pilote ne republie une tête qu'après l'avoir reçue servie. La tête 0,
    /// publiée deux cents fois d'un coup, ne part qu'une fois ; les cent
    /// quatre-vingt-dix-neuf autres entrées sont rendues en erreur dans
    /// l'anneau des servies (aucune ne reste sans réponse), mais l'octet de
    /// statut reste celui de la requête en vol, jusqu'à sa réponse. Même chose
    /// pour une autre tête dont l'octet de statut est celui d'une requête en
    /// vol, même quand elle se répondrait tout de suite (l'identifiant).
    #[test]
    fn a_head_still_out_is_refused_without_touching_its_status() {
        let (mut disque, mut ram) = demarre();
        File::requete(&mut ram, 0, 0, (0x5000, 512, true), 0);
        // L'index publié 200 entrées plus loin ; la RAM est à zéro, donc
        // toutes les entrées nomment la tête 0.
        publier(&mut ram, 200);
        notifier(&mut disque, &mut ram);
        assert_eq!(disque.a_prendre(), 1, "une seule fois dehors");
        assert_eq!(disque.refusees, 199);
        assert_eq!(File::servies(&ram), 199, "chacune a sa réponse");
        assert_eq!(File::servie(&ram, 198 % 128), (0, 0));
        assert_eq!(File::statut(&ram), 0xFF, "le statut de la requête en vol");
        // Une autre tête, la demande d'identifiant, dont le statut est celui
        // de la requête en vol.
        File::decrire(&mut ram, 3, File::BROUILLON + 0x100, 16, false, Some(4));
        ram.ecrire(File::BROUILLON + 0x100, &8u32.to_le_bytes());
        File::decrire(&mut ram, 4, 0x6000, 20, true, Some(5));
        File::decrire(&mut ram, 5, File::STATUT, 1, true, None);
        ram.ecrire(File::DISPONIBLES + 4 + (200 % 128) * 2, &3u16.to_le_bytes());
        publier(&mut ram, 201);
        notifier(&mut disque, &mut ram);
        assert_eq!(disque.refusees, 200);
        assert_eq!(File::servie(&ram, 199 % 128), (3, 0));
        assert_eq!(ram.0[0x6000], 0, "refusée, elle n'a rien écrit");
        assert_eq!(File::statut(&ram), 0xFF);
        // La réponse arrive : elle seule pose le statut.
        assert_eq!(repondre(&mut disque, &mut image(), &mut ram), 1);
        assert_eq!(File::statut(&ram), 0);
        assert_eq!(File::servies(&ram), 201);
        assert_eq!(File::servie(&ram, 200 % 128), (0, 512));
        assert_eq!(ram.0[0x5000], 1);
    }

    /// **Pas plus de requêtes dehors que la file n'a de places**, même pour
    /// un pilote qui nomme des têtes au-delà de la table (rien ne l'en
    /// empêche, du côté Swift non plus) : cent vingt-huit têtes distinctes,
    /// chacune avec son statut, partent ; la cent vingt-neuvième est refusée,
    /// dans son propre octet de statut, et la liste ne grossit pas.
    #[test]
    fn no_more_requests_are_out_than_the_queue_has_places() {
        let (mut disque, mut ram) = demarre();
        // Les têtes à partir de 0x600 : leurs descripteurs tombent de 0x7000
        // à 0x8830, sous les statuts à 0x9000 et au-delà.
        let tete = |k: u16| 0x600 + 3 * k;
        let statut = |k: u16| 0x9000 + u64::from(k);
        for k in 0..128 {
            poser(
                &mut ram,
                tete(k),
                (0, 0),
                (0x5000, 512, true),
                (0x4000, statut(k)),
                k,
            );
        }
        publier(&mut ram, 128);
        notifier(&mut disque, &mut ram);
        assert_eq!(disque.a_prendre(), 128);
        assert_eq!(disque.refusees, 0);
        poser(
            &mut ram,
            tete(128),
            (0, 0),
            (0x5000, 512, true),
            (0x4000, statut(128)),
            128,
        );
        publier(&mut ram, 129);
        notifier(&mut disque, &mut ram);
        assert_eq!(disque.a_prendre(), 128, "la liste ne grossit pas");
        assert_eq!(disque.refusees, 1);
        assert_eq!(ram.0[statut(128) as usize], 1, "son statut à elle");
        assert!((0..128).all(|k| ram.0[statut(k) as usize] == 0xFF));
        assert_eq!(File::servie(&ram, 0), (u32::from(tete(128)), 0));
        assert_eq!(repondre(&mut disque, &mut image(), &mut ram), 128);
        assert_eq!(File::servies(&ram), 129, "chacune a sa réponse");
        assert!((0..128).all(|k| ram.0[statut(k) as usize] == 0));
    }

    /// **La carte ne tient jamais plus que sa borne à la fois** : trois
    /// lectures de 32 Mio publiées d'une seule notification. Les deux
    /// premières partent (64 Mio, la borne tout juste) ; la troisième ne
    /// tient plus et **attend**, non lue, sans refus ni statut posé. La
    /// première réponse lui rend sa place, et elle part alors d'elle-même,
    /// sans autre notification.
    ///
    /// C'est le cas que la borne par requête laissait passer : cent
    /// vingt-huit requêtes de 64 Mio, 8 Gio, dans une mémoire wasm32 de
    /// 4 Gio au plus.
    #[test]
    fn the_card_never_holds_more_than_its_bound_at_once() {
        const MORCEAU: u32 = 32 << 20;
        const TAMPON: u64 = 0x10_0000;
        let mut disque = VirtioBlk::nouveau(1 << 20);
        let mut ram = RamPlate(vec![0; TAMPON as usize + MORCEAU as usize]);
        File::demarrer(&mut disque, &mut ram);
        let secteurs = u64::from(MORCEAU / 512);
        for k in 0..3u16 {
            poser(
                &mut ram,
                3 * k,
                (0, secteurs * u64::from(k)),
                (TAMPON, MORCEAU, true),
                (0x4000 + 0x10 * u64::from(k), 0x4800 + u64::from(k)),
                k,
            );
        }
        publier(&mut ram, 3);
        notifier(&mut disque, &mut ram);
        assert_eq!(disque.a_prendre(), 2, "la troisième ne tient plus");
        assert_eq!(disque.tenus(), PLUS_TENU);
        assert_eq!(disque.refusees, 0, "elle attend, elle n'est pas refusée");
        assert_eq!(File::servies(&ram), 0);
        assert_eq!(ram.0[0x4802], 0xFF);
        // Une notification de plus n'y change rien : la place manque encore.
        notifier(&mut disque, &mut ram);
        assert_eq!(disque.a_prendre(), 2);
        let premiere = disque.prendre_requete().expect("partie");
        let deuxieme = disque.prendre_requete().expect("partie");
        assert_eq!(premiere.decalage, 0);
        assert!(disque.lu(premiere.id, &vec![7; MORCEAU as usize], &mut ram));
        assert_eq!(File::servies(&ram), 1);
        assert_eq!(ram.0[0x4800], 0);
        // La place rendue fait partir la troisième.
        let troisieme = disque.prendre_requete().expect("partie après la réponse");
        assert_eq!(troisieme.decalage, 2 * u64::from(MORCEAU));
        assert_eq!(disque.tenus(), PLUS_TENU);
        assert!(disque.fini(deuxieme.id, false, &mut ram));
        assert!(disque.lu(troisieme.id, &vec![9; MORCEAU as usize], &mut ram));
        assert_eq!(disque.tenus(), 0);
        assert!(!disque.en_attente());
        assert_eq!(File::servies(&ram), 3);
        assert_eq!(ram.0[0x4801..0x4803], [1, 0]);
        assert_eq!((disque.servies, disque.refusees), (2, 1));
        assert_eq!(ram.0[TAMPON as usize], 9);
    }

    /// **Une écriture finie, ou un échec, fait aussi partir ce qui
    /// attendait** : `fini` rend de la place comme `lu`. Trois écritures de
    /// 32 Mio publiées d'un coup : deux partent, la troisième attend. La
    /// première finie avec succès la fait partir ; une quatrième publiée
    /// ensuite attend à son tour, et l'échec de la deuxième la fait partir.
    /// Sans cette reprise, l'invité resterait figé : son pilote a publié, il
    /// ne notifiera plus.
    #[test]
    fn a_finished_write_or_a_failure_lets_what_waited_leave() {
        const MORCEAU: u32 = 32 << 20;
        const TAMPON: u64 = 0x10_0000;
        let mut disque = VirtioBlk::nouveau(1 << 20);
        let mut ram = RamPlate(vec![0x5A; TAMPON as usize + MORCEAU as usize]);
        ram.0[..TAMPON as usize].fill(0);
        File::demarrer(&mut disque, &mut ram);
        let secteurs = u64::from(MORCEAU / 512);
        let ecriture = |ram: &mut RamPlate, k: u16| {
            poser(
                ram,
                3 * k,
                (1, secteurs * u64::from(k)),
                (TAMPON, MORCEAU, false),
                (0x4000 + 0x10 * u64::from(k), 0x4800 + u64::from(k)),
                k,
            );
        };
        for k in 0..3u16 {
            ecriture(&mut ram, k);
        }
        publier(&mut ram, 3);
        notifier(&mut disque, &mut ram);
        let premiere = disque.prendre_requete().expect("partie");
        let deuxieme = disque.prendre_requete().expect("partie");
        assert_eq!(disque.prendre_requete(), None, "la troisième attend");
        assert!(disque.en_attente());
        // Une écriture faite : sans octets à rendre, elle rend sa place.
        assert!(disque.fini(premiere.id, true, &mut ram));
        assert_eq!(ram.0[0x4800], 0);
        let troisieme = disque.prendre_requete().expect("partie à la réponse");
        assert_eq!(troisieme.sens, Sens::Ecrire);
        assert_eq!(troisieme.decalage, 2 * u64::from(MORCEAU));
        assert_eq!(troisieme.octets.len(), MORCEAU as usize);
        // Une quatrième attend ; l'échec de la deuxième la fait partir.
        ecriture(&mut ram, 3);
        publier(&mut ram, 4);
        notifier(&mut disque, &mut ram);
        assert_eq!(disque.prendre_requete(), None, "la quatrième attend");
        assert!(disque.fini(deuxieme.id, false, &mut ram));
        assert_eq!(ram.0[0x4801], 1, "l'échec est dit au pilote");
        let quatrieme = disque.prendre_requete().expect("partie à l'échec");
        assert_eq!(quatrieme.decalage, 3 * u64::from(MORCEAU));
        assert!(disque.fini(troisieme.id, true, &mut ram));
        assert!(disque.fini(quatrieme.id, true, &mut ram));
        assert_eq!(disque.tenus(), 0);
        assert!(!disque.en_attente());
        assert_eq!(File::servies(&ram), 4);
        assert_eq!(ram.0[0x4800..0x4804], [0, 1, 0, 0]);
        assert_eq!((disque.servies, disque.refusees), (3, 1));
    }

    /// Le pilote recommence : sa file rendue (`del_vq` remet le numéro de
    /// page à zéro), l'index des disponibles remis à zéro, puis la poignée de
    /// main, qui commence par la remise à zéro et repose la file à la même
    /// page.
    fn recommencer(disque: &mut VirtioBlk, ram: &mut RamPlate) {
        disque.ecrire_port(0x08, 0, ram);
        ram.ecrire(File::DISPONIBLES + 2, &0u16.to_le_bytes());
        File::demarrer(disque, ram);
    }

    /// **Une remise à zéro ne rend pas la place de ce que l'arrière tient
    /// encore** : dix fois de suite, le pilote recommence et demande une
    /// lecture de 64 Mio. La première part ; les neuf autres attendent, car
    /// la lecture oubliée est toujours chez l'arrière, qui alloue toute sa
    /// longueur pour la servir. Sans cela, dix tours confieraient 640 Mio à
    /// l'arrière pendant que la carte en annonce 64. Quand la réponse oubliée
    /// arrive, elle ne touche à rien, mais la requête du pilote d'aujourd'hui
    /// part, et se sert normalement.
    #[test]
    fn a_reset_does_not_give_back_what_the_backend_still_holds() {
        const TAMPON: u64 = 0x10_0000;
        let longueur = PLUS_TENU as u32;
        let mut disque = VirtioBlk::nouveau(1 << 20);
        let mut ram = RamPlate(vec![0; TAMPON as usize + longueur as usize]);
        let mut confiees = Vec::new();
        for tour in 0..10u64 {
            recommencer(&mut disque, &mut ram);
            poser(
                &mut ram,
                0,
                (0, tour),
                (TAMPON, longueur, true),
                (0x4000, 0x4800),
                0,
            );
            publier(&mut ram, 1);
            notifier(&mut disque, &mut ram);
            confiees.extend(disque.prendre_requete());
            assert!(disque.tenus() <= PLUS_TENU, "tour {tour}");
        }
        assert_eq!(confiees.len(), 1, "une seule lecture confiée en dix tours");
        let somme: u64 = confiees.iter().map(|r| r.longueur).sum();
        assert_eq!(somme, PLUS_TENU);
        assert_eq!(disque.tenus(), PLUS_TENU, "l'oubliée compte encore");
        assert_eq!(disque.refusees, 0, "le pilote d'aujourd'hui attend");
        assert_eq!(ram.0[0x4800], 0xFF);
        assert!(disque.en_attente(), "sa réponse viendra d'une oubliée");
        // La réponse de l'oubliée : rien n'est rendu, rien n'est copié.
        let vieille = &confiees[0];
        assert!(!disque.lu(vieille.id, &vec![7; longueur as usize], &mut ram));
        assert_eq!(ram.0[TAMPON as usize], 0, "rien n'est copié");
        assert_eq!(File::servies(&ram), 0);
        // Mais la place est rendue : la lecture du dernier tour part.
        let jeune = disque.prendre_requete().expect("partie à la réponse");
        assert_eq!(jeune.decalage, 9 * 512);
        assert_eq!(disque.tenus(), PLUS_TENU);
        assert!(disque.lu(jeune.id, &vec![9; longueur as usize], &mut ram));
        assert_eq!(ram.0[TAMPON as usize], 9);
        assert_eq!(ram.0[0x4800], 0);
        assert_eq!(disque.tenus(), 0);
        assert!(!disque.en_attente());
    }

    /// **Les oubliées prennent aussi leur place parmi les 128** : cent
    /// vingt-huit lectures confiées, puis une remise à zéro. La première
    /// requête du pilote qui recommence attend, sans refus ; la première
    /// réponse oubliée la fait partir. Sans cela, un invité qui boucle
    /// « remise, 128 requêtes » ferait grossir sans fin ce que l'arrière sert.
    #[test]
    fn forgotten_requests_still_take_their_place_in_the_queue() {
        let (mut disque, mut ram) = demarre();
        let tete = |k: u16| 0x600 + 3 * k;
        for k in 0..128 {
            poser(
                &mut ram,
                tete(k),
                (0, 0),
                (0x5000, 512, true),
                (0x4000, 0x9000 + u64::from(k)),
                k,
            );
        }
        publier(&mut ram, 128);
        notifier(&mut disque, &mut ram);
        let vieilles: Vec<_> = std::iter::from_fn(|| disque.prendre_requete()).collect();
        assert_eq!(vieilles.len(), 128);
        recommencer(&mut disque, &mut ram);
        assert_eq!(disque.dehors(), 128);
        File::requete(&mut ram, 0, 1, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        assert_eq!(disque.prendre_requete(), None, "elle attend une place");
        assert_eq!(disque.refusees, 0);
        assert_eq!(File::statut(&ram), 0xFF);
        assert!(disque.en_attente());
        assert!(!disque.fini(vieilles[0].id, false, &mut ram));
        let jeune = disque.prendre_requete().expect("partie à la réponse");
        assert_eq!(disque.dehors(), 128);
        assert!(disque.lu(jeune.id, &image()[512..1024], &mut ram));
        assert_eq!(ram.0[0x5000], 2);
        for vieille in &vieilles[1..] {
            assert!(!disque.lu(vieille.id, &image()[..512], &mut ram));
        }
        assert_eq!(disque.dehors(), 0);
        assert_eq!(ram.0[0x5000], 2, "aucune oubliée n'a rien copié");
    }

    /// **Un disque rebranché garde le compte de ce que l'ancien a confié** :
    /// la lecture de 64 Mio de l'ancien est encore chez l'arrière, et la
    /// première lecture du neuf attend sa réponse, qui ne remplit rien.
    #[test]
    fn a_disk_plugged_anew_still_counts_what_the_old_one_left_out() {
        const TAMPON: u64 = 0x10_0000;
        let longueur = PLUS_TENU as u32;
        let mut carte = Carte::nouvelle();
        let mut ram = RamPlate(vec![0; TAMPON as usize + longueur as usize]);
        carte.brancher_disque(1 << 20);
        ouvrir(&mut carte, 0xC000);
        par_les_ports(&mut carte, &mut ram);
        poser(
            &mut ram,
            0,
            (0, 0),
            (TAMPON, longueur, true),
            (0x4000, 0x4800),
            0,
        );
        publier(&mut ram, 1);
        carte.port_ecrire(0xC010, 2, 0, &mut ram);
        let vieille = carte.requete_disque().expect("partie");
        carte.brancher_disque(1 << 20);
        ram.ecrire(File::DISPONIBLES + 2, &0u16.to_le_bytes());
        ouvrir(&mut carte, 0xC000);
        par_les_ports(&mut carte, &mut ram);
        File::requete(&mut ram, 0, 3, (0x5000, 512, true), 0);
        carte.port_ecrire(0xC010, 2, 0, &mut ram);
        assert_eq!(carte.requete_disque(), None, "elle attend l'ancienne");
        assert!(carte.reveil(), "une réponse la fera partir");
        assert!(!carte.disque_lu(vieille.id, &vec![7; longueur as usize], &mut ram));
        assert_eq!(ram.0[TAMPON as usize], 0);
        let jeune = carte.requete_disque().expect("partie à la réponse");
        assert!(carte.disque_lu(jeune.id, &image()[1536..], &mut ram));
        assert_eq!(ram.0[0x5000], 4, "le secteur 3");
    }

    /// **Une requête que la boucle n'a pas encore prise est lâchée par une
    /// remise** : elle n'a jamais été confiée à l'arrière, aucune réponse ne
    /// viendra, donc elle ne doit plus rien compter. Sans cela, une lecture
    /// de 64 Mio restée dans `a_envoyer` au moment d'une remise ferait
    /// attendre le disque pour toujours.
    #[test]
    fn a_reset_drops_a_request_the_loop_never_took() {
        let (mut disque, mut ram) = demarre();
        File::requete(&mut ram, 0, 1, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        assert_eq!(disque.a_prendre(), 1);
        recommencer(&mut disque, &mut ram);
        assert_eq!(disque.dehors(), 0, "rien n'est parti");
        assert_eq!(disque.tenus(), 0);
        assert_eq!(disque.prendre_requete(), None, "elle ne part plus");
        File::requete(&mut ram, 0, 2, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        let jeune = disque.prendre_requete().expect("partie tout de suite");
        assert!(disque.lu(jeune.id, &image()[1024..1536], &mut ram));
        assert_eq!(ram.0[0x5000], 3, "le secteur 2");
    }

    /// **Un disque rebranché après une remise compte encore les oubliées de
    /// l'ancien** : une lecture confiée, une remise qui l'oublie, puis un
    /// disque neuf à la place. Sa réponse peut encore venir : le neuf la
    /// compte jusqu'à elle, et elle ne touche à rien.
    #[test]
    fn a_disk_plugged_anew_after_a_reset_still_counts_the_forgotten() {
        let (mut disque, mut ram) = demarre();
        File::requete(&mut ram, 0, 1, (0x5000, 512, true), 0);
        notifier(&mut disque, &mut ram);
        let vieille = disque.prendre_requete().expect("partie");
        recommencer(&mut disque, &mut ram);
        assert_eq!(disque.dehors(), 1, "oubliée, mais dehors");
        let mut neuf = VirtioBlk::nouveau(4);
        neuf.succeder_a(&disque);
        assert_eq!(neuf.dehors(), 1);
        assert_eq!(neuf.tenus(), 512);
        assert!(!neuf.lu(vieille.id, &image()[512..1024], &mut ram));
        assert_eq!(neuf.dehors(), 0);
        assert_eq!(ram.0[0x5000], 0, "rien n'est copié");
    }

    /// **Un disque rebranché ne reprend pas les noms de l'ancien** : la
    /// réponse en retard d'une lecture de l'ancien disque (le secteur 0) ne
    /// remplit pas la première lecture du neuf (le secteur 3), et ne la dit
    /// pas réussie.
    #[test]
    fn a_disk_plugged_anew_never_reuses_a_name() {
        let mut carte = Carte::nouvelle();
        let mut ram = RamPlate(vec![0; 0x10000]);
        let lire = |carte: &mut Carte, ram: &mut RamPlate, secteur| {
            ouvrir(carte, 0xC000);
            par_les_ports(carte, ram);
            File::requete(ram, 0, secteur, (0x5000, 512, true), 0);
            carte.port_ecrire(0xC010, 2, 0, ram);
            carte.requete_disque().expect("partie")
        };
        carte.brancher_disque(4);
        let vieille = lire(&mut carte, &mut ram, 0);
        carte.brancher_disque(4);
        let jeune = lire(&mut carte, &mut ram, 3);
        assert_ne!(vieille.id, jeune.id);
        assert!(!carte.disque_lu(vieille.id, &[0xAA; 512], &mut ram));
        assert_eq!(File::statut(&ram), 0xFF, "rien n'est dit au pilote");
        assert_eq!(ram.0[0x5000], 0, "rien n'est copié");
        assert!(carte.disque_lu(jeune.id, &image()[1536..], &mut ram));
        assert_eq!(ram.0[0x5000], 4, "le secteur 3");
        assert_eq!(File::statut(&ram), 0);
    }

    /// Les noms continuent tels quels, et restent entre 1 et 2³¹ − 1.
    #[test]
    fn names_carry_over_within_their_range() {
        let mut disque = VirtioBlk::nouveau(4);
        assert_eq!(disque.prochain_nom(), 1);
        for nom in [1, 2, 0x7FFF_FFFE, 0x7FFF_FFFF] {
            disque.reprendre_les_noms(nom);
            assert_eq!(disque.prochain_nom(), nom);
        }
        disque.reprendre_les_noms(0x8000_0000);
        assert_eq!(disque.prochain_nom(), 1, "ramené dans l'intervalle");
    }

    /// Ouvrir la fenêtre du disque à `base`, par les ports, comme le noyau.
    fn ouvrir(carte: &mut Carte, base: u32) {
        use super::super::pci::tests::adresse;
        carte.port_ecrire(0xCF8, 4, adresse(3, 0x10), &mut SansRam);
        carte.port_ecrire(0xCFC, 4, base, &mut SansRam);
        carte.port_ecrire(0xCF8, 4, adresse(3, 0x04), &mut SansRam);
        carte.port_ecrire(0xCFC, 2, 0x0005, &mut SansRam);
    }

    /// La poignée de main par la fenêtre à `0xC000`.
    fn par_les_ports(carte: &mut Carte, ram: &mut RamPlate) {
        for statut in [0, 1, 3, 11] {
            carte.port_ecrire(0xC012, 1, statut, ram);
        }
        carte.port_ecrire(0xC00E, 2, 0, ram);
        carte.port_ecrire(0xC008, 4, File::PAGE, ram);
        carte.port_ecrire(0xC012, 1, 15, ram);
    }
}

#[cfg(test)]
mod tests_de_l_etat {
    //! **Le disque au repos, sauvé et relu** ([`VirtioBlk::sauver`]) : la
    //! file reprend où elle en était, et ce qu'aucun disque ne tient est
    //! refusé.
    use super::super::etat::essais::{chaque_coupure_refusee, octets_de, relu, se_relit};
    use super::super::{Ram, RamPlate};
    use super::*;

    /// Un disque de huit secteurs, sa file à la page 1, après une lecture.
    fn servi() -> (VirtioBlk, RamPlate) {
        let mut disque = VirtioBlk::nouveau(8);
        let mut ram = RamPlate(vec![0; 0x10000]);
        for (port, valeur) in [(0x12, 0), (0x12, 1), (0x12, 3), (0x04, 0), (0x12, 11)] {
            disque.ecrire_port(port, valeur, &mut ram);
        }
        disque.ecrire_port(0x08, 1, &mut ram);
        disque.ecrire_port(0x12, 15, &mut ram);
        lire_le_secteur(&mut disque, &mut ram, 3, 0);
        (disque, ram)
    }

    /// Une lecture du secteur `secteur`, publiée à l'entrée `entree`, servie
    /// par une image dont chaque secteur vaut son numéro.
    fn lire_le_secteur(disque: &mut VirtioBlk, ram: &mut RamPlate, secteur: u64, entree: u16) {
        let (table, disponibles, _) = anneaux(1, LIMITE_DE_FILE);
        ram.ecrire(0x4000, &0u32.to_le_bytes());
        ram.ecrire(0x4008, &secteur.to_le_bytes());
        for (index, (a, longueur, drapeaux, suivant)) in [
            (0x4000u64, 16u32, 1u16, 1u16),
            (0x5000, 512, 3, 2),
            (0x4800, 1, 2, 0),
        ]
        .into_iter()
        .enumerate()
        {
            let at = table + index as u64 * 16;
            ram.ecrire(at, &a.to_le_bytes());
            ram.ecrire(at + 8, &longueur.to_le_bytes());
            ram.ecrire(at + 12, &drapeaux.to_le_bytes());
            ram.ecrire(at + 14, &suivant.to_le_bytes());
        }
        ram.ecrire(
            disponibles + 4 + u64::from(entree % 128) * 2,
            &0u16.to_le_bytes(),
        );
        ram.ecrire(disponibles + 2, &(entree.wrapping_add(1)).to_le_bytes());
        disque.ecrire_port(REGISTRE_DE_NOTIFICATION, 0, ram);
        while let Some(requete) = disque.prendre_requete() {
            let octets = vec![(requete.decalage / 512) as u8; requete.longueur as usize];
            assert!(disque.lu(requete.id, &octets, ram));
        }
        assert!(disque.au_repos());
    }

    #[test]
    fn a_resting_disk_reads_back_and_its_queue_goes_on() {
        let (disque, ram) = servi();
        assert_eq!((disque.prochain_disponible, disque.prochain_servi), (1, 1));
        let octets = octets_de(&disque, VirtioBlk::sauver);
        let mut repris = relu(&octets, VirtioBlk::relire).expect("relu");
        assert_eq!(repris, disque);
        chaque_coupure_refusee(&octets, VirtioBlk::relire);
        // **La file continue** : la requête suivante, servie par l'original
        // et par le disque repris, rend les mêmes octets au même endroit.
        let (mut original, mut ram_a) = (disque, RamPlate(ram.0.clone()));
        let mut ram_b = RamPlate(ram.0);
        lire_le_secteur(&mut original, &mut ram_a, 6, 1);
        lire_le_secteur(&mut repris, &mut ram_b, 6, 1);
        assert_eq!(repris, original);
        assert_eq!(ram_b.0, ram_a.0);
        assert_eq!(ram_b.0[0x5000], 6, "le secteur 6 est arrivé");
        assert_eq!(repris.prochain_servi, 2);
        // Un disque neuf, et un disque dont la file a été retirée, se relisent.
        let neuf = VirtioBlk::nouveau(8);
        assert_eq!(
            relu(&octets_de(&neuf, VirtioBlk::sauver), VirtioBlk::relire),
            Some(neuf)
        );
        let mut retire = original.clone();
        retire.ecrire_port(0x08, 0, &mut ram_a);
        assert_eq!(
            relu(&octets_de(&retire, VirtioBlk::sauver), VirtioBlk::relire),
            Some(retire)
        );
    }

    #[test]
    fn what_no_disk_holds_is_refused() {
        let (disque, _) = servi();
        let relit = |abimer: fn(&mut VirtioBlk)| {
            se_relit(&disque, abimer, VirtioBlk::sauver, VirtioBlk::relire)
        };
        assert!(relit(|_| {}), "tel quel");
        assert!(relit(|d| d.isr = 1), "un ISR levé");
        assert!(
            !relit(|d| d.taille_de_file = 64),
            "une taille de file que le disque n'annonce pas"
        );
        assert!(
            !relit(|d| d.prete = false),
            "une file retirée qui garde sa taille"
        );
        assert!(
            !relit(|d| d.page_de_file = 2),
            "des anneaux qui ne sont pas ceux de la page"
        );
        assert!(
            !relit(|d| {
                d.page_de_file = 0;
                (d.table, d.anneau_disponible, d.anneau_servi) = anneaux(0, LIMITE_DE_FILE);
            }),
            "une file prête à la page zéro"
        );
        assert!(!relit(|d| d.isr = 2), "un ISR qui n'est pas un bit de file");
        assert!(
            !relit(|d| d.prochain_servi = 0),
            "un index servi en retard sur le disponible"
        );
        assert!(
            !relit(|d| d.prochain_disponible = 5),
            "un index disponible en avance"
        );
        assert!(!relit(|d| d.prochain_id = 0), "un nom de requête nul");
        assert!(
            !relit(|d| d.prochain_id = 0x8000_0000),
            "un nom au-delà de 2³¹ − 1"
        );
        assert!(
            relit(|d| d.prochain_id = 0x7FFF_FFFF),
            "le dernier nom est permis"
        );
    }
}
