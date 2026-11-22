//! **La carte réseau virtio, de forme ancienne**, en 00:05.0, ligne 3.
//! Portée depuis `VirtioNet` du cœur Swift (`Sources/WisqVM/VirtioNet.swift`),
//! registre pour registre : la même porte que le disque ([`virtio_blk`]) —
//! une fenêtre de ports, le numéro de page de chaque file, l'octet d'état
//! d'interruption qui s'acquitte en le lisant —, deux files au lieu d'une :
//! la zéro reçoit, la une émet.
//!
//! **Ce qui est annoncé, et seulement ça** : `VIRTIO_NET_F_MAC`, pour que le
//! pilote lise l'adresse dans l'espace de configuration plutôt que d'en tirer
//! une au hasard à chaque démarrage. Sans `MRG_RXBUF`, l'en-tête de chaque
//! trame fait dix octets ; sans les fonctions de déchargement, le pilote
//! calcule ses sommes de contrôle et découpe ses segments lui-même, et la
//! carte ne voit que des trames entières.
//!
//! **Pas de statut du lien**, comme du côté Swift : `VIRTIO_NET_F_STATUS`
//! n'est pas offert, et le pilote tient alors le lien pour toujours établi
//! (`netif_carrier_on` à la sonde, sans rien lire). Un câble débranché ne se
//! voit donc pas de l'invité : ce qu'il envoie se perd et rien n'arrive, ce
//! qu'un pilote et les protocoles au-dessus savent vivre. Annoncer le lien
//! serait une carte différente de celle du cœur Swift.
//!
//! **Ce qui est de l'autre côté du câble** ([`Cable`]) n'est pas ici : pas de
//! pile réseau, pas de sockets. La carte ne sait que deux choses — prendre
//! les trames que l'invité envoie, et lui rendre celles qui arrivent. Le
//! réseau en mode utilisateur du cœur Swift (`UserNetwork`, `HostDatagrams`)
//! se branchera derrière ce trait par le C ABI ; la page, elle, passe les
//! trames par ses exports (`carte_reseau_*`).
//!
//! **Ce que l'invité envoie attend dans la carte**, et c'est la seule
//! différence de forme avec le cœur Swift, où `transmit` appelle
//! `backend.send` pendant l'`out`. Ici, l'écriture d'un port n'a pas le câble
//! sous la main : la [`Carte`](super::Carte) se clone et se compare, et vit
//! dans une `static` de la page. Une trame émise est donc rangée
//! ([`VirtioNet::sortir`]), et c'est la machine — [`CartePc`](super::pc::CartePc)
//! dans le même [`servir`](super::pc::CartePc::servir), la page après chaque
//! `out` — qui la donne au câble. Les compteurs sont ceux du cœur Swift : une
//! trame rangée est émise, une trame sans câble est perdue.

use std::collections::VecDeque;

use super::etat::{Ecrivain, Lecteur};
use super::virtio_blk::{anneaux, lire_u16, Descripteur};
use super::Ram;

/// **L'autre bout du câble** (`NetworkBackend` du cœur Swift) : il prend ce
/// que l'invité envoie, et rend ce qui arrive pour lui.
///
/// Les deux appels viennent du fil de la machine : `envoyer` quand elle sert
/// une émission, `recevoir` quand elle sonde ([`VirtioNet::sonder`]). Un
/// câble qui reçoit d'ailleurs (un socket de l'hôte, un autre fil) range ses
/// trames et les rend là.
///
/// `Send`, parce que la machine tourne sur le fil que l'application lui
/// donne, pas sur celui qui l'a bâtie.
pub trait Cable: Send {
    /// Une trame Ethernet que l'invité vient d'envoyer, sans l'en-tête virtio.
    fn envoyer(&mut self, trame: &[u8]);
    /// Les trames qui attendent l'invité, retirées de l'attente.
    fn recevoir(&mut self) -> Vec<Vec<u8>>;
}

/// **Un câble en boucle** : ce que l'invité envoie lui revient à la sonde
/// suivante. Celui des tests, et d'un invité qui se parle à lui-même.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CableEnBoucle {
    /// Ce qui a été envoyé et n'est pas encore revenu.
    pub en_route: Vec<Vec<u8>>,
    /// Combien de trames sont passées par lui.
    pub envoyees: u64,
}

impl Cable for CableEnBoucle {
    fn envoyer(&mut self, trame: &[u8]) {
        self.envoyees += 1;
        self.en_route.push(trame.to_vec());
    }

    fn recevoir(&mut self) -> Vec<Vec<u8>> {
        std::mem::take(&mut self.en_route)
    }
}

/// L'adresse par défaut (`VirtioNet.defaultMAC`) : `02` (administrée
/// localement, individuelle : une adresse d'aucun fabricant), puis « wisq ».
pub const MAC_PAR_DEFAUT: [u8; 6] = [0x02, 0x77, 0x69, 0x73, 0x71, 0x01];
/// La seule fonction offerte : `VIRTIO_NET_F_MAC`.
pub const FONCTION_MAC: u32 = 1 << 5;
/// La taille de chaque file, que le pilote lit au registre `0x0C` et sur
/// laquelle il calcule ses anneaux (`queueLimit`).
pub const LIMITE_DE_FILE: u32 = 256;
/// L'en-tête `virtio_net_hdr` sans tampons fusionnés : dix octets.
pub const OCTETS_D_EN_TETE: usize = 10;
/// **Ce qui attend au plus**, de chaque côté (`waitingLimit`). Un invité qui
/// ne pose plus de tampons — pilote déchargé, machine arrêtée sur autre chose
/// — ne doit pas faire grandir l'attente sans fin : au-delà, on perd, comme
/// un vrai câble. La même borne tient les trames émises qu'une page ne
/// prendrait pas.
pub const PLUS_EN_ATTENTE: usize = 512;
/// La plus grande trame Ethernet sans les jumbos (`largestFrame`) : au-delà,
/// ce n'est pas une trame qu'un pilote de ce genre a demandée.
pub const PLUS_GRANDE_TRAME: usize = 1514;
/// **Les passages qu'on laisse filer, au travail, entre deux questions au
/// câble** (`busyPollInterval`). Du côté Swift, chaque question au réseau en
/// mode utilisateur prend quatre verrous, même quand rien n'est arrivé ;
/// mesuré sur l'Alpine installé (six milliards d'instructions) : 200 s sans
/// carte, 223 s avec, et une question sur quatre passages (toutes les
/// 1 024 instructions) ne se voit plus. Au repos, à chaque passage : une
/// machine endormie n'exécute rien, et attendre, ce serait attendre des
/// battements.
pub const PASSAGES_AU_TRAVAIL: u32 = 4;

/// La file de réception.
pub const FILE_DE_RECEPTION: usize = 0;
/// La file d'émission.
pub const FILE_D_EMISSION: usize = 1;

/// **Une file** : sa page, ses trois anneaux, et où on en est.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct File {
    pub page: u32,
    pub descripteurs: u64,
    pub disponibles: u64,
    pub servies: u64,
    pub prochaine_disponible: u16,
    pub prochaine_servie: u16,
}

impl File {
    const fn vide() -> Self {
        Self {
            page: 0,
            descripteurs: 0,
            disponibles: 0,
            servies: 0,
            prochaine_disponible: 0,
            prochaine_servie: 0,
        }
    }

    /// Une file est prête quand le pilote a écrit sa page.
    pub fn prete(&self) -> bool {
        self.page != 0
    }
}

/// **La carte réseau** : ses registres, ses deux files, ce qui attend de
/// chaque côté, et ses compteurs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VirtioNet {
    mac: [u8; 6],
    files: [File; 2],
    file_choisie: u16,
    fonctions_du_pilote: u32,
    statut: u8,
    isr: u8,
    /// Un câble est branché : ce que l'invité envoie est rangé pour lui, et
    /// pas perdu.
    branche: bool,
    /// Ce qui est arrivé et n'a pas encore trouvé de tampon chez l'invité.
    attente: VecDeque<Vec<u8>>,
    /// Ce que l'invité a envoyé et que le câble n'a pas encore pris.
    sortantes: VecDeque<Vec<u8>>,
    /// Les passages au travail depuis la dernière question au câble.
    passages: u32,
    emises: u64,
    livrees: u64,
    perdues: u64,
}

impl Default for VirtioNet {
    fn default() -> Self {
        Self::nouvelle(MAC_PAR_DEFAUT)
    }
}

impl VirtioNet {
    /// Une carte d'adresse `mac`, câble débranché.
    pub const fn nouvelle(mac: [u8; 6]) -> Self {
        Self {
            mac,
            files: [File::vide(), File::vide()],
            file_choisie: 0,
            fonctions_du_pilote: 0,
            statut: 0,
            isr: 0,
            branche: false,
            attente: VecDeque::new(),
            sortantes: VecDeque::new(),
            passages: 0,
            emises: 0,
            livrees: 0,
            perdues: 0,
        }
    }

    pub fn mac(&self) -> [u8; 6] {
        self.mac
    }

    /// Les deux files : la réception, puis l'émission.
    pub fn files(&self) -> &[File; 2] {
        &self.files
    }

    pub fn file_choisie(&self) -> u16 {
        self.file_choisie
    }

    pub fn fonctions_du_pilote(&self) -> u32 {
        self.fonctions_du_pilote
    }

    pub fn statut(&self) -> u8 {
        self.statut
    }

    /// Les trames envoyées au câble (`transmitted`).
    pub fn emises(&self) -> u64 {
        self.emises
    }

    /// Les trames rendues à l'invité (`delivered`).
    pub fn livrees(&self) -> u64 {
        self.livrees
    }

    /// Les trames perdues, d'un côté ou de l'autre (`dropped`).
    pub fn perdues(&self) -> u64 {
        self.perdues
    }

    /// Combien de trames arrivées attendent un tampon de l'invité.
    pub fn en_attente(&self) -> usize {
        self.attente.len()
    }

    /// Vrai quand la carte demande l'interruption.
    pub fn interrompt(&self) -> bool {
        self.isr != 0
    }

    /// **Brancher ou débrancher le câble.** Débranché, ce que l'invité envoie
    /// est perdu, comme du côté Swift sans `backend` ; ce qui attendait déjà
    /// un tampon reste, et part quand il vient.
    pub fn brancher_cable(&mut self, branche: bool) {
        self.branche = branche;
    }

    pub fn cable_branche(&self) -> bool {
        self.branche
    }

    // -------------------------------------------------------- la fenêtre

    /// **Lire un registre de la fenêtre**, à `decalage` de son début : le
    /// registre entier, que la carte ramène à la largeur de l'accès.
    pub fn lire_port(&mut self, decalage: u16, largeur: u8) -> u32 {
        match decalage {
            0x00 => FONCTION_MAC,
            0x04 => self.fonctions_du_pilote,
            0x08 => self.files[usize::from(self.file_choisie)].page,
            0x0C => LIMITE_DE_FILE,
            0x0E => u32::from(self.file_choisie),
            0x12 => u32::from(self.statut),
            0x13 => {
                // Lire l'état d'interruption l'acquitte.
                let isr = self.isr;
                self.isr = 0;
                u32::from(isr)
            }
            // L'adresse, octet par octet, quelle que soit la largeur lue.
            0x14..=0x19 => {
                let premier = usize::from(decalage - 0x14);
                (0..usize::from(largeur))
                    .filter(|rang| premier + rang < 6)
                    .fold(0, |valeur, rang| {
                        valeur | (u32::from(self.mac[premier + rang]) << (8 * rang))
                    })
            }
            _ => 0,
        }
    }

    /// **Écrire un registre de la fenêtre.** `valeur` est déjà ramenée à la
    /// largeur de l'accès. La notification (`0x10`) lit la file dans `ram` :
    /// un, l'émission ; zéro, la réception.
    pub fn ecrire_port(&mut self, decalage: u16, valeur: u32, ram: &mut dyn Ram) {
        match decalage {
            // Le pilote ne peut accepter que ce qui est offert.
            0x04 => self.fonctions_du_pilote = valeur & FONCTION_MAC,
            0x08 => {
                let mut file = File {
                    page: valeur,
                    ..File::vide()
                };
                if valeur != 0 {
                    (file.descripteurs, file.disponibles, file.servies) =
                        anneaux(valeur, LIMITE_DE_FILE);
                }
                self.files[usize::from(self.file_choisie)] = file;
            }
            // Deux files seulement ; une autre se lit comme la zéro, ce que
            // le pilote prend pour « pas de file ici » (`queueSelect`).
            0x0E => {
                let file = valeur as u16;
                self.file_choisie = if file < 2 { file } else { 0 };
            }
            0x10 => match valeur {
                1 => self.emettre(ram),
                0 => self.livrer(ram),
                _ => {}
            },
            0x12 => {
                self.statut = valeur as u8;
                if self.statut == 0 {
                    self.remettre_a_zero();
                }
            }
            _ => {}
        }
    }

    /// **La remise à zéro** (statut zéro) : les files, la file choisie, les
    /// fonctions, l'interruption, et ce qui attendait un tampon. Les trames
    /// déjà émises sont sur le fil : le câble les prend quand même.
    fn remettre_a_zero(&mut self) {
        self.files = [File::vide(), File::vide()];
        self.file_choisie = 0;
        self.fonctions_du_pilote = 0;
        self.isr = 0;
        self.attente.clear();
    }

    // ---------------------------------------------------------- les files

    /// **La chaîne de descripteurs qui commence à `tete`**, bornée à la
    /// taille de la file : une chaîne qui boucle ne fait pas tourner la
    /// carte pour toujours.
    fn chaine(&self, quelle: usize, tete: u16, ram: &dyn Ram) -> Vec<Descripteur> {
        let file = &self.files[quelle];
        let mut trouves = Vec::new();
        let mut index = tete;
        while trouves.len() < LIMITE_DE_FILE as usize {
            let Some(un) = Descripteur::lire(file.descripteurs, index % LIMITE_DE_FILE as u16, ram)
            else {
                break;
            };
            trouves.push(un);
            if !un.chaine() {
                break;
            }
            index = un.suivant;
        }
        trouves
    }

    /// **La prochaine tête que le pilote a rendue disponible**, ou rien.
    fn prochaine_tete(&mut self, quelle: usize, ram: &dyn Ram) -> Option<u16> {
        let file = self.files[quelle];
        if !file.prete() {
            return None;
        }
        let index = lire_u16(ram, file.disponibles.wrapping_add(2))?;
        if index == file.prochaine_disponible {
            return None;
        }
        let place = u64::from(file.prochaine_disponible % LIMITE_DE_FILE as u16);
        let tete = lire_u16(ram, file.disponibles.wrapping_add(4 + place * 2))?;
        self.files[quelle].prochaine_disponible = file.prochaine_disponible.wrapping_add(1);
        Some(tete)
    }

    /// Range une tête dans l'anneau des servies, et lève l'interruption.
    fn rendre(&mut self, quelle: usize, tete: u16, longueur: u32, ram: &mut dyn Ram) {
        let file = self.files[quelle];
        let place = u64::from(file.prochaine_servie % LIMITE_DE_FILE as u16);
        let entree = file.servies.wrapping_add(4 + place * 8);
        ram.ecrire(entree, &u32::from(tete).to_le_bytes());
        ram.ecrire(entree.wrapping_add(4), &longueur.to_le_bytes());
        let prochaine = file.prochaine_servie.wrapping_add(1);
        self.files[quelle].prochaine_servie = prochaine;
        ram.ecrire(file.servies.wrapping_add(2), &prochaine.to_le_bytes());
        self.isr |= 1;
    }

    /// **Ce que l'invité envoie** : chaque chaîne de la file d'émission, ses
    /// tampons lisibles lus bout à bout jusqu'à l'en-tête et une trame pleine,
    /// l'en-tête retiré, et la trame rangée pour le câble.
    ///
    /// Une trame sans octet après l'en-tête, sans câble, ou que la page
    /// laisse s'entasser au-delà de [`PLUS_EN_ATTENTE`], est perdue ; la
    /// requête est rendue dans tous les cas. **Un tampon hors de la RAM la
    /// perd aussi**, dès qu'on doit y lire : le cœur Swift y lirait des
    /// zéros, mais une trame faite en partie de zéros que l'invité n'a pas
    /// écrits n'est pas à envoyer. Un tampon dont on ne lit rien — vide, ou
    /// venu après une trame pleine — ne la perd pas, où qu'il pointe.
    pub fn emettre(&mut self, ram: &mut dyn Ram) {
        while let Some(tete) = self.prochaine_tete(FILE_D_EMISSION, ram) {
            let mut octets = Vec::new();
            let mut lisible = true;
            for tampon in self.chaine(FILE_D_EMISSION, tete, ram) {
                if tampon.inscriptible() {
                    continue;
                }
                let place = (OCTETS_D_EN_TETE + PLUS_GRANDE_TRAME).saturating_sub(octets.len());
                let n = (tampon.longueur as usize).min(place);
                // Rien à lire ici — un tampon vide, ou la trame déjà pleine :
                // aucun octet n'en viendrait, pas même un zéro, et son adresse
                // ne compte pas (le cœur Swift y copie zéro octet).
                if n == 0 {
                    continue;
                }
                let debut = octets.len();
                octets.resize(debut + n, 0);
                lisible &= ram.lire(tampon.adresse, &mut octets[debut..]);
            }
            if lisible
                && octets.len() > OCTETS_D_EN_TETE
                && self.branche
                && self.sortantes.len() < PLUS_EN_ATTENTE
            {
                octets.drain(..OCTETS_D_EN_TETE);
                self.sortantes.push_back(octets);
                self.emises = self.emises.wrapping_add(1);
            } else {
                self.perdues = self.perdues.wrapping_add(1);
            }
            self.rendre(FILE_D_EMISSION, tete, 0, ram);
        }
    }

    /// **La prochaine trame émise**, que le câble doit prendre ; dans l'ordre
    /// où l'invité les a envoyées.
    pub fn sortir(&mut self) -> Option<Vec<u8>> {
        self.sortantes.pop_front()
    }

    /// **Une trame arrive du câble.** Elle attend un tampon de l'invité ;
    /// `false`, et elle est perdue, si elle est plus grande qu'une trame
    /// Ethernet ou si [`PLUS_EN_ATTENTE`] trames attendent déjà.
    pub fn entrer(&mut self, trame: Vec<u8>) -> bool {
        if trame.len() > PLUS_GRANDE_TRAME || self.attente.len() >= PLUS_EN_ATTENTE {
            self.perdues = self.perdues.wrapping_add(1);
            return false;
        }
        self.attente.push_back(trame);
        true
    }

    /// **Ce qui arrive** : les trames en attente, rangées dans les tampons que
    /// le pilote a posés sur la file de réception, chacune derrière un
    /// en-tête nul. Celles qui ne trouvent pas de tampon attendent.
    ///
    /// Un tampon trop petit pour la trame la perd et est rendu vide : la
    /// rendre tronquée ferait lire au pilote un paquet qui n'a jamais existé.
    /// Un tampon hors de la RAM compte comme trop petit ; un tampon vide ne
    /// compte pas, où qu'il pointe.
    pub fn livrer(&mut self, ram: &mut dyn Ram) {
        while !self.attente.is_empty() {
            let Some(tete) = self.prochaine_tete(FILE_DE_RECEPTION, ram) else {
                return;
            };
            let Some(trame) = self.attente.pop_front() else {
                return;
            };
            let mut octets = vec![0u8; OCTETS_D_EN_TETE];
            octets.extend_from_slice(&trame);
            let mut posees = 0;
            for tampon in self.chaine(FILE_DE_RECEPTION, tete, ram) {
                if !tampon.inscriptible() {
                    continue;
                }
                let n = (tampon.longueur as usize).min(octets.len() - posees);
                // Un tampon vide ne reçoit rien, où qu'il soit : il ne coupe
                // pas la chaîne (le cœur Swift y copie zéro octet et passe au
                // suivant). La trame déjà posée en entier, il ne reste rien à
                // écrire, et chaque tampon qui suit est vide de même.
                if n == 0 {
                    continue;
                }
                // Hors de la RAM : la chaîne est coupée, et la trame perdue.
                // Passer au tampon suivant rendrait au pilote une longueur
                // qui couvre celui-ci, jamais écrit.
                if !ram.ecrire(tampon.adresse, &octets[posees..posees + n]) {
                    break;
                }
                posees += n;
            }
            if posees < octets.len() {
                self.perdues = self.perdues.wrapping_add(1);
                self.rendre(FILE_DE_RECEPTION, tete, 0, ram);
            } else {
                self.livrees = self.livrees.wrapping_add(1);
                self.rendre(FILE_DE_RECEPTION, tete, octets.len() as u32, ram);
            }
        }
    }

    /// **Prendre ce que le câble a pour l'invité**, et le lui donner si ses
    /// tampons sont là (`poll`). La machine l'appelle à chaque passage de son
    /// contrôleur d'interruptions ; `occupe` dit que le processeur travaille,
    /// et le câble n'est alors questionné qu'un passage sur
    /// [`PASSAGES_AU_TRAVAIL`] — ce qui attend un tampon part, lui, à chaque
    /// passage. Sans câble, rien n'arrive.
    pub fn sonder(&mut self, cable: Option<&mut dyn Cable>, ram: &mut dyn Ram, occupe: bool) {
        if occupe {
            self.passages = self.passages.saturating_add(1);
            if self.passages < PASSAGES_AU_TRAVAIL {
                if !self.attente.is_empty() {
                    self.livrer(ram);
                }
                return;
            }
        }
        self.passages = 0;
        if let Some(cable) = cable {
            for trame in cable.recevoir() {
                self.entrer(trame);
            }
        }
        self.livrer(ram);
    }
}

// ------------------------------------------------- l'état, pour l'instantané

impl File {
    fn sauver(&self, e: &mut Ecrivain) {
        e.u32(self.page);
        e.u64(self.descripteurs);
        e.u64(self.disponibles);
        e.u64(self.servies);
        e.u16(self.prochaine_disponible);
        e.u16(self.prochaine_servie);
    }

    /// Relue, ou rien : une file posée a les anneaux de sa page, une file
    /// retirée n'a rien (`ecrire_port`, registre `0x08`) ; et chaque tête
    /// lue a reçu sa réponse dans le même appel ([`VirtioNet::emettre`],
    /// [`VirtioNet::livrer`]), donc les deux index se suivent.
    fn relire(l: &mut Lecteur) -> Option<Self> {
        let file = Self {
            page: l.u32()?,
            descripteurs: l.u64()?,
            disponibles: l.u64()?,
            servies: l.u64()?,
            prochaine_disponible: l.u16()?,
            prochaine_servie: l.u16()?,
        };
        let anneaux = if file.page == 0 {
            (0, 0, 0)
        } else {
            anneaux(file.page, LIMITE_DE_FILE)
        };
        let valide = (file.descripteurs, file.disponibles, file.servies) == anneaux
            && file.prochaine_servie == file.prochaine_disponible
            && (file.page != 0 || file.prochaine_disponible == 0);
        valide.then_some(file)
    }
}

impl VirtioNet {
    /// **L'état de la carte réseau**, pour l'instantané de la machine native
    /// ([`super::etat`]) : son adresse, ses deux files, la file choisie, les
    /// fonctions acceptées, le statut, l'ISR, **les trames qui attendent un
    /// tampon de l'invité et celles qui attendent le câble**, le passage du
    /// sondage et les compteurs. Pas le câble : il est autour de la machine,
    /// pas dedans, et la carte reprise prend celui de la machine qui reprend.
    pub(crate) fn sauver(&self, e: &mut Ecrivain) {
        e.0.extend_from_slice(&self.mac);
        for file in &self.files {
            file.sauver(e);
        }
        e.u16(self.file_choisie);
        e.u32(self.fonctions_du_pilote);
        e.u8(self.statut);
        e.u8(self.isr);
        for trames in [&self.attente, &self.sortantes] {
            e.compte(trames.len());
            for trame in trames {
                e.octets(trame);
            }
        }
        e.u32(self.passages);
        e.u64(self.emises);
        e.u64(self.livrees);
        e.u64(self.perdues);
    }

    /// Relue, câble débranché, ou rien. Sont refusés : une file choisie
    /// au-delà des deux (elle indexe les files), une fonction acceptée qui
    /// n'est pas offerte, un ISR qui n'est pas un bit de file, plus de
    /// [`PLUS_EN_ATTENTE`] trames d'un côté ou une trame plus longue que
    /// [`PLUS_GRANDE_TRAME`].
    pub(crate) fn relire(l: &mut Lecteur) -> Option<Self> {
        let mac: [u8; 6] = l.prendre(6)?.try_into().ok()?;
        let mut carte = Self::nouvelle(mac);
        for file in &mut carte.files {
            *file = File::relire(l)?;
        }
        carte.file_choisie = l.u16()?;
        carte.fonctions_du_pilote = l.u32()?;
        carte.statut = l.u8()?;
        carte.isr = l.u8()?;
        for trames in [&mut carte.attente, &mut carte.sortantes] {
            let combien = l.compte(PLUS_EN_ATTENTE)?;
            for _ in 0..combien {
                trames.push_back(l.octets(PLUS_GRANDE_TRAME)?.to_vec());
            }
        }
        carte.passages = l.u32()?;
        carte.emises = l.u64()?;
        carte.livrees = l.u64()?;
        carte.perdues = l.u64()?;
        let valide = carte.file_choisie < 2
            && carte.fonctions_du_pilote & !FONCTION_MAC == 0
            && carte.isr <= 1;
        valide.then_some(carte)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    //! **La carte réseau, conduite comme son pilote la conduit** : les cas de
    //! `Tests/WisqVMTests/VirtioNetTests.swift` et les deux de
    //! `GuestMemoryBlockTests.swift` qui jugent l'interrogation du réseau,
    //! portés un pour un, puis ce que le Swift ne jugeait pas : les files
    //! pleines des deux côtés, les tampons en plusieurs morceaux, les bords
    //! de la trame, la remise à zéro. Le cas de l'instantané n'est pas porté :
    //! la carte n'a pas d'instantané (JOURNAL).
    use super::super::RamPlate;
    use super::*;

    /// **Un pilote minimal** (`VirtioNetTests.Driver`) : une page par file
    /// (`0x10` la réception, `0x20` l'émission), des tampons dans la mémoire
    /// qui suit, et les anneaux tenus comme Linux les tient.
    pub(crate) struct Pilote {
        pub(crate) ram: RamPlate,
        pub(crate) carte: VirtioNet,
        posees: [u16; 2],
    }

    pub(crate) const PAGES: [u32; 2] = [0x10, 0x20];

    impl Pilote {
        pub(crate) fn nouveau(carte: VirtioNet) -> Self {
            let mut pilote = Self {
                ram: RamPlate(vec![0; 1 << 20]),
                carte,
                posees: [0; 2],
            };
            for file in 0..2 {
                pilote.carte.ecrire_port(0x0E, file, &mut pilote.ram);
                pilote
                    .carte
                    .ecrire_port(0x08, PAGES[file as usize], &mut pilote.ram);
            }
            pilote
        }

        pub(crate) fn branche() -> Self {
            let mut carte = VirtioNet::default();
            carte.brancher_cable(true);
            Self::nouveau(carte)
        }

        pub(crate) fn anneaux(file: usize) -> (u64, u64, u64) {
            anneaux(PAGES[file], LIMITE_DE_FILE)
        }

        /// **Une chaîne de tampons** — `(adresse, longueur, inscriptible)` —,
        /// rendue disponible d'un coup ; ses descripteurs suivent ceux déjà
        /// posés.
        pub(crate) fn poser_chaine(&mut self, file: usize, tampons: &[(u64, u32, bool)]) {
            let (descripteurs, disponibles, _) = Self::anneaux(file);
            let tete = self.posees[file];
            for (rang, &(adresse, longueur, inscriptible)) in tampons.iter().enumerate() {
                let index = tete.wrapping_add(rang as u16) % LIMITE_DE_FILE as u16;
                let suivant = tete.wrapping_add(rang as u16 + 1) % LIMITE_DE_FILE as u16;
                let a = descripteurs + u64::from(index) * 16;
                let dernier = rang + 1 == tampons.len();
                let drapeaux = u16::from(inscriptible) * 2 + u16::from(!dernier);
                self.ram.ecrire(a, &adresse.to_le_bytes());
                self.ram.ecrire(a + 8, &longueur.to_le_bytes());
                self.ram.ecrire(a + 12, &drapeaux.to_le_bytes());
                self.ram
                    .ecrire(a + 14, &if dernier { 0 } else { suivant }.to_le_bytes());
            }
            // L'entrée de l'anneau, puis l'index qui la publie : une entrée
            // par chaîne, comme une requête du disque.
            let entree = self.entrees(file);
            let place = u64::from(entree % LIMITE_DE_FILE as u16);
            self.ram.ecrire(
                disponibles + 4 + place * 2,
                &(tete % LIMITE_DE_FILE as u16).to_le_bytes(),
            );
            self.ram
                .ecrire(disponibles + 2, &entree.wrapping_add(1).to_le_bytes());
            self.posees[file] = tete.wrapping_add(tampons.len() as u16);
        }

        /// Un tampon de `longueur` octets à `adresse`, rendu disponible.
        pub(crate) fn poser(
            &mut self,
            file: usize,
            adresse: u64,
            longueur: u32,
            inscriptible: bool,
        ) {
            self.poser_chaine(file, &[(adresse, longueur, inscriptible)]);
        }

        /// L'index publié de l'anneau des disponibles.
        fn entrees(&self, file: usize) -> u16 {
            let (_, disponibles, _) = Self::anneaux(file);
            let a = disponibles as usize + 2;
            u16::from_le_bytes([self.ram.0[a], self.ram.0[a + 1]])
        }

        /// L'entrée `n` de l'anneau des servies : la tête et la longueur, et
        /// l'index des servies.
        pub(crate) fn servie(&self, file: usize, n: u64) -> (u32, u32, u16) {
            let (_, _, servies) = Self::anneaux(file);
            let mot = |a: u64| {
                let a = a as usize;
                u32::from_le_bytes([
                    self.ram.0[a],
                    self.ram.0[a + 1],
                    self.ram.0[a + 2],
                    self.ram.0[a + 3],
                ])
            };
            let index = u16::from_le_bytes([
                self.ram.0[servies as usize + 2],
                self.ram.0[servies as usize + 3],
            ]);
            (mot(servies + 4 + n * 8), mot(servies + 8 + n * 8), index)
        }

        pub(crate) fn octets(&self, adresse: u64, n: usize) -> Vec<u8> {
            self.ram.0[adresse as usize..adresse as usize + n].to_vec()
        }

        pub(crate) fn ecrire(&mut self, octets: &[u8], adresse: u64) {
            self.ram.ecrire(adresse, octets);
        }

        pub(crate) fn notifier(&mut self, file: u32) {
            self.carte.ecrire_port(0x10, file, &mut self.ram);
        }

        /// Une trame à émettre à `adresse` : l'en-tête nul, puis la trame.
        pub(crate) fn emettre(&mut self, trame: &[u8], adresse: u64) {
            let mut octets = vec![0u8; OCTETS_D_EN_TETE];
            octets.extend_from_slice(trame);
            self.ecrire(&octets, adresse);
            self.poser(FILE_D_EMISSION, adresse, octets.len() as u32, false);
            self.notifier(1);
        }
    }

    /// **La trame des tests Swift** : une demande ARP diffusée, depuis
    /// l'adresse de la carte, et vingt-huit octets.
    pub(crate) fn trame() -> Vec<u8> {
        let mut trame = vec![0xFF; 6];
        trame.extend_from_slice(&MAC_PAR_DEFAUT);
        trame.extend_from_slice(&[0x08, 0x06]);
        trame.extend_from_slice(&[0xAB; 28]);
        trame
    }

    /// Une trame de `n` octets dont chaque octet dit sa place.
    fn trame_de(n: usize, graine: u8) -> Vec<u8> {
        (0..n)
            .map(|i| (i as u8).wrapping_mul(7).wrapping_add(graine))
            .collect()
    }

    /// **Un câble qui compte ses questions** (`Counting` du Swift).
    #[derive(Default)]
    struct Compteur {
        questions: usize,
        arrivent: Vec<Vec<u8>>,
        envoyees: Vec<Vec<u8>>,
    }

    impl Cable for Compteur {
        fn envoyer(&mut self, trame: &[u8]) {
            self.envoyees.push(trame.to_vec());
        }
        fn recevoir(&mut self) -> Vec<Vec<u8>> {
            self.questions += 1;
            std::mem::take(&mut self.arrivent)
        }
    }

    // -------------------------------------------------------- VirtioNetTests

    /// L'adresse se lit dans l'espace de configuration, à toute largeur, et
    /// la seule fonction annoncée est `MAC`
    /// (`testTheAddressAndTheFeatureAreAnnounced`).
    #[test]
    fn the_address_and_the_feature_are_announced() {
        let mut carte = VirtioNet::default();
        assert_eq!(carte.lire_port(0x00, 4), 1 << 5);
        let octets: Vec<u8> = (0..6).map(|i| carte.lire_port(0x14 + i, 1) as u8).collect();
        assert_eq!(octets, MAC_PAR_DEFAUT);
        assert_eq!(carte.lire_port(0x14, 4), 0x7369_7702);
        assert_eq!(carte.lire_port(0x0C, 2), LIMITE_DE_FILE);
        // Ce que le Swift ne jugeait pas : l'adresse lue de travers, à cheval
        // sur sa fin, ne rend que ses octets — rien au-delà du sixième.
        assert_eq!(carte.lire_port(0x16, 4), 0x0171_7369);
        assert_eq!(carte.lire_port(0x18, 4), 0x0171, "deux octets restent");
        assert_eq!(carte.lire_port(0x19, 2), 0x01, "un seul");
        assert_eq!(carte.lire_port(0x15, 2), 0x6977);
        assert_eq!(carte.lire_port(0x1A, 4), 0, "pas de statut du lien");
        // Une autre adresse que celle par défaut.
        let mut autre = VirtioNet::nouvelle([0x02, 1, 2, 3, 4, 5]);
        assert_eq!(autre.lire_port(0x14, 4), 0x0302_0102);
        assert_eq!(autre.lire_port(0x18, 2), 0x0504);
        assert_eq!(autre.mac(), [0x02, 1, 2, 3, 4, 5]);
    }

    /// **Envoyer** : l'en-tête de dix octets retiré, la trame au câble, la
    /// requête rendue et l'interruption levée
    /// (`testATransmittedFrameReachesTheCableWithoutItsHeader`).
    #[test]
    fn a_transmitted_frame_reaches_the_cable_without_its_header() {
        let mut pilote = Pilote::branche();
        pilote.emettre(&trame(), 0x40000);
        assert_eq!(pilote.carte.sortir(), Some(trame()));
        assert_eq!(pilote.carte.sortir(), None, "une seule");
        assert_eq!(pilote.servie(FILE_D_EMISSION, 0), (0, 0, 1));
        assert_eq!(pilote.carte.emises(), 1);
        assert!(pilote.carte.interrompt());
        assert_eq!(pilote.carte.lire_port(0x13, 1), 1, "l'état d'interruption…");
        assert!(!pilote.carte.interrompt(), "…s'acquitte en le lisant");
        assert_eq!(pilote.carte.lire_port(0x13, 1), 0);
    }

    /// **Recevoir** : la trame derrière un en-tête nul, dans le tampon posé,
    /// la longueur servie, et l'interruption
    /// (`testAReceivedFrameLandsInThePostedBuffer`).
    #[test]
    fn a_received_frame_lands_in_the_posted_buffer() {
        let mut pilote = Pilote::branche();
        pilote.poser(FILE_DE_RECEPTION, 0x50000, 2048, true);
        let mut cable = Compteur {
            arrivent: vec![trame()],
            ..Compteur::default()
        };
        pilote
            .carte
            .sonder(Some(&mut cable), &mut pilote.ram, false);
        let (tete, longueur, index) = pilote.servie(FILE_DE_RECEPTION, 0);
        assert_eq!((tete, index), (0, 1));
        assert_eq!(longueur as usize, OCTETS_D_EN_TETE + trame().len());
        let mut attendu = vec![0u8; OCTETS_D_EN_TETE];
        attendu.extend_from_slice(&trame());
        assert_eq!(pilote.octets(0x50000, attendu.len()), attendu);
        assert!(pilote.carte.interrompt());
        assert_eq!(pilote.carte.livrees(), 1);
    }

    /// Sans tampon, la trame attend ; le tampon posé et la file notifiée,
    /// elle arrive (`testAFrameWaitsForABuffer`).
    #[test]
    fn a_frame_waits_for_a_buffer() {
        let mut pilote = Pilote::branche();
        let mut cable = Compteur {
            arrivent: vec![trame()],
            ..Compteur::default()
        };
        pilote
            .carte
            .sonder(Some(&mut cable), &mut pilote.ram, false);
        assert_eq!(pilote.servie(FILE_DE_RECEPTION, 0).2, 0);
        assert!(!pilote.carte.interrompt());
        assert_eq!(pilote.carte.en_attente(), 1);
        pilote.poser(FILE_DE_RECEPTION, 0x50000, 2048, true);
        pilote.notifier(0);
        assert_eq!(pilote.servie(FILE_DE_RECEPTION, 0).2, 1);
        assert_eq!(pilote.carte.livrees(), 1);
        assert_eq!(pilote.carte.en_attente(), 0);
    }

    /// Un tampon trop petit ne reçoit pas une trame tronquée : elle est
    /// perdue, et le tampon rendu vide
    /// (`testATooSmallBufferGetsNothingRatherThanHalf`).
    #[test]
    fn a_too_small_buffer_gets_nothing_rather_than_half() {
        let mut pilote = Pilote::branche();
        pilote.poser(FILE_DE_RECEPTION, 0x50000, 20, true);
        pilote.carte.entrer(trame());
        pilote.carte.livrer(&mut pilote.ram);
        let (tete, longueur, index) = pilote.servie(FILE_DE_RECEPTION, 0);
        assert_eq!((tete, longueur, index), (0, 0, 1));
        assert_eq!(pilote.carte.perdues(), 1);
        assert_eq!(pilote.carte.livrees(), 0);
        assert!(pilote.carte.interrompt(), "le tampon rendu vide se signale");
        // Un tampon d'un octet de moins que l'en-tête et la trame : perdue
        // aussi ; tout juste assez, elle passe.
        let juste = (OCTETS_D_EN_TETE + trame().len()) as u32;
        pilote.poser(FILE_DE_RECEPTION, 0x50000, juste - 1, true);
        pilote.carte.entrer(trame());
        pilote.carte.livrer(&mut pilote.ram);
        assert_eq!(pilote.servie(FILE_DE_RECEPTION, 1).1, 0);
        pilote.poser(FILE_DE_RECEPTION, 0x50000, juste, true);
        pilote.carte.entrer(trame());
        pilote.carte.livrer(&mut pilote.ram);
        assert_eq!(pilote.servie(FILE_DE_RECEPTION, 2).1, juste);
        assert_eq!((pilote.carte.perdues(), pilote.carte.livrees()), (2, 1));
    }

    // --------------------------------------------------- GuestMemoryBlockTests

    /// **Le câble n'est questionné qu'un passage sur quatre** quand le
    /// processeur travaille, et à chaque passage au repos ; ce qui attend un
    /// tampon, lui, part à chaque passage
    /// (`testTheCardAsksTheNetworkLessOftenWhileBusy`).
    #[test]
    fn the_card_asks_the_cable_less_often_while_busy() {
        let mut pilote = Pilote::branche();
        let mut cable = Compteur::default();
        for _ in 0..PASSAGES_AU_TRAVAIL * 3 {
            pilote.carte.sonder(Some(&mut cable), &mut pilote.ram, true);
        }
        assert_eq!(cable.questions, 3);
        for _ in 0..5 {
            pilote
                .carte
                .sonder(Some(&mut cable), &mut pilote.ram, false);
        }
        assert_eq!(cable.questions, 8, "au repos, à chaque passage");
        // Une trame arrivée sans tampon attend ; le tampon posé, le passage
        // suivant la livre, même sans questionner le câble.
        cable.arrivent = vec![trame()];
        pilote
            .carte
            .sonder(Some(&mut cable), &mut pilote.ram, false);
        assert_eq!(pilote.carte.livrees(), 0);
        pilote.poser(FILE_DE_RECEPTION, 0x50000, 2048, true);
        let avant = cable.questions;
        pilote.carte.sonder(Some(&mut cable), &mut pilote.ram, true);
        assert_eq!(cable.questions, avant, "pas une question au câble");
        assert_eq!(pilote.carte.livrees(), 1);
        assert_eq!(pilote.octets(0x5000A, trame().len()), trame());
    }

    /// **Au repos, le câble est questionné à chaque passage** ; au travail,
    /// un sur quatre, et le compte repart d'un passage au repos
    /// (`testAHaltedCoreAsksTheNetworkEveryPass`, réduit à la carte : le
    /// processeur n'est pas ici).
    #[test]
    fn an_idle_machine_asks_the_cable_every_pass() {
        let mut pilote = Pilote::branche();
        let mut cable = Compteur::default();
        for _ in 0..3 {
            pilote
                .carte
                .sonder(Some(&mut cable), &mut pilote.ram, false);
        }
        assert_eq!(cable.questions, 3, "au repos : à chaque passage");
        for _ in 0..3 {
            pilote.carte.sonder(Some(&mut cable), &mut pilote.ram, true);
        }
        assert_eq!(cable.questions, 3, "au travail : pas avant le quatrième");
        pilote.carte.sonder(Some(&mut cable), &mut pilote.ram, true);
        assert_eq!(cable.questions, 4, "le quatrième");
        // Un passage au repos remet le compte à zéro.
        pilote.carte.sonder(Some(&mut cable), &mut pilote.ram, true);
        pilote
            .carte
            .sonder(Some(&mut cable), &mut pilote.ram, false);
        assert_eq!(cable.questions, 5);
        for _ in 0..3 {
            pilote.carte.sonder(Some(&mut cable), &mut pilote.ram, true);
        }
        assert_eq!(cable.questions, 5, "trois passages après le repos");
        // Sans câble, rien n'arrive, et rien ne casse.
        pilote.carte.sonder(None, &mut pilote.ram, false);
        assert_eq!(pilote.carte.en_attente(), 0);
    }

    // ------------------------------------------------------ ce que le Swift ne jugeait pas

    /// **Débranché**, ce que l'invité envoie est perdu (le cœur Swift sans
    /// `backend`), et la requête est rendue quand même : un pilote ne
    /// l'attend pas pour toujours.
    #[test]
    fn an_unplugged_cable_loses_what_the_guest_sends() {
        let mut pilote = Pilote::nouveau(VirtioNet::default());
        assert!(!pilote.carte.cable_branche());
        pilote.emettre(&trame(), 0x40000);
        assert_eq!(pilote.carte.sortir(), None);
        assert_eq!((pilote.carte.emises(), pilote.carte.perdues()), (0, 1));
        assert_eq!(pilote.servie(FILE_D_EMISSION, 0).2, 1, "rendue");
        assert!(pilote.carte.interrompt());
        // Branché, la suivante part.
        pilote.carte.brancher_cable(true);
        pilote.emettre(&trame_de(60, 3), 0x40000);
        assert_eq!(pilote.carte.sortir(), Some(trame_de(60, 3)));
        assert_eq!((pilote.carte.emises(), pilote.carte.perdues()), (1, 1));
        // Débranché de nouveau : ce qui attendait un tampon reste, et part.
        pilote.carte.entrer(trame());
        pilote.carte.brancher_cable(false);
        pilote.poser(FILE_DE_RECEPTION, 0x50000, 2048, true);
        pilote.notifier(0);
        assert_eq!(pilote.carte.livrees(), 1);
    }

    /// **Une trame faite seulement d'un en-tête** n'est pas une trame : elle
    /// est perdue. Un octet de plus, et elle part.
    #[test]
    fn a_header_alone_is_not_a_frame() {
        let mut pilote = Pilote::branche();
        pilote.ecrire(&[0; OCTETS_D_EN_TETE + 1], 0x40000);
        pilote.poser(FILE_D_EMISSION, 0x40000, OCTETS_D_EN_TETE as u32, false);
        pilote.notifier(1);
        assert_eq!((pilote.carte.emises(), pilote.carte.perdues()), (0, 1));
        pilote.ecrire(&[0x5A], 0x40000 + OCTETS_D_EN_TETE as u64);
        pilote.poser(FILE_D_EMISSION, 0x40000, OCTETS_D_EN_TETE as u32 + 1, false);
        pilote.notifier(1);
        assert_eq!(pilote.carte.sortir(), Some(vec![0x5A]));
        assert_eq!(pilote.servie(FILE_D_EMISSION, 1).2, 2);
    }

    /// **Une trame en plusieurs tampons** s'émet bout à bout — l'en-tête dans
    /// le premier, comme Linux le pose —, les tampons inscriptibles d'une
    /// chaîne d'émission ne comptent pas, et ce qui dépasse une trame
    /// pleine n'est pas lu.
    #[test]
    fn a_frame_in_pieces_is_sent_end_to_end_and_capped() {
        let mut pilote = Pilote::branche();
        let corps = trame_de(100, 1);
        pilote.ecrire(&[0; OCTETS_D_EN_TETE], 0x40000);
        pilote.ecrire(&corps[..30], 0x41000);
        pilote.ecrire(&[0xEE; 16], 0x42000);
        pilote.ecrire(&corps[30..], 0x43000);
        pilote.poser_chaine(
            FILE_D_EMISSION,
            &[
                (0x40000, OCTETS_D_EN_TETE as u32, false),
                (0x41000, 30, false),
                (0x42000, 16, true),
                (0x43000, 70, false),
            ],
        );
        pilote.notifier(1);
        assert_eq!(pilote.carte.sortir(), Some(corps));
        assert_eq!(pilote.servie(FILE_D_EMISSION, 0), (0, 0, 1));
        // Une trame plus grande qu'une trame pleine : coupée à 1 514 octets
        // après l'en-tête, en travers d'un tampon.
        let grande = trame_de(2000, 9);
        pilote.ecrire(&[0; OCTETS_D_EN_TETE], 0x40000);
        pilote.ecrire(&grande[..1000], 0x41000);
        pilote.ecrire(&grande[1000..], 0x50000);
        pilote.poser_chaine(
            FILE_D_EMISSION,
            &[
                (0x40000, OCTETS_D_EN_TETE as u32, false),
                (0x41000, 1000, false),
                (0x50000, 1000, false),
            ],
        );
        pilote.notifier(1);
        let partie = pilote.carte.sortir().expect("la trame coupée");
        assert_eq!(partie.len(), PLUS_GRANDE_TRAME);
        assert_eq!(partie, grande[..PLUS_GRANDE_TRAME]);
        assert_eq!(
            pilote.servie(FILE_D_EMISSION, 1).0,
            4,
            "la tête de la chaîne"
        );
    }

    /// **Une trame reçue en plusieurs tampons** : l'en-tête et la trame
    /// répartis dans l'ordre de la chaîne, les tampons en lecture seule
    /// sautés, la longueur servie entière, et rien d'écrit au-delà.
    #[test]
    fn a_frame_received_in_pieces_fills_the_chain_in_order() {
        let mut pilote = Pilote::branche();
        let t = trame_de(80, 5);
        pilote.ecrire(&[0x77; 64], 0x52000);
        pilote.poser_chaine(
            FILE_DE_RECEPTION,
            &[
                (0x50000, 4, true),
                (0x52000, 64, false),
                (0x51000, 50, true),
                (0x53000, 4096, true),
            ],
        );
        pilote.ecrire(&[0xCC; 64], 0x53000);
        pilote.carte.entrer(t.clone());
        pilote.carte.livrer(&mut pilote.ram);
        let mut attendu = vec![0u8; OCTETS_D_EN_TETE];
        attendu.extend_from_slice(&t);
        let mut rendu = pilote.octets(0x50000, 4);
        rendu.extend(pilote.octets(0x51000, 50));
        rendu.extend(pilote.octets(0x53000, attendu.len() - 54));
        assert_eq!(rendu, attendu);
        assert_eq!(
            pilote.octets(0x52000, 64),
            vec![0x77; 64],
            "en lecture seule"
        );
        assert_eq!(
            pilote.octets(0x53000 + (attendu.len() - 54) as u64, 4),
            vec![0xCC; 4],
            "rien au-delà"
        );
        assert_eq!(
            pilote.servie(FILE_DE_RECEPTION, 0).1 as usize,
            attendu.len()
        );
    }

    /// **La file pleine, du côté qui arrive** : cinq cent douze trames
    /// attendent au plus, la suivante est perdue et le dit ; une trame plus
    /// grande qu'une trame Ethernet aussi, une de 1 514 octets tout juste
    /// entre.
    #[test]
    fn what_arrives_waits_up_to_its_bound() {
        // Les nombres du Swift (`waitingLimit`, `largestFrame`), écrits en
        // clair : une borne déplacée se voit ici.
        let mut carte = VirtioNet::default();
        for n in 0..512 {
            assert!(carte.entrer(trame_de(60, n as u8)), "{n}");
        }
        assert!(!carte.entrer(trame()), "la cinq cent treizième");
        assert_eq!((carte.en_attente(), carte.perdues()), (512, 1));
        let mut carte = VirtioNet::default();
        assert!(!carte.entrer(vec![0; 1515]));
        assert!(carte.entrer(vec![0; 1514]));
        assert_eq!((carte.en_attente(), carte.perdues()), (1, 1));
        // Par le câble : la file pleine perd ce qui reste de la réponse, et
        // garde les cinq cent douze premières, dans l'ordre.
        let mut pilote = Pilote::branche();
        let mut cable = Compteur {
            arrivent: (0..PLUS_EN_ATTENTE + 3)
                .map(|n| trame_de(60, n as u8))
                .collect(),
            ..Compteur::default()
        };
        pilote
            .carte
            .sonder(Some(&mut cable), &mut pilote.ram, false);
        assert_eq!(
            (pilote.carte.en_attente(), pilote.carte.perdues()),
            (PLUS_EN_ATTENTE, 3)
        );
        pilote.poser(FILE_DE_RECEPTION, 0x50000, 2048, true);
        pilote.poser(FILE_DE_RECEPTION, 0x51000, 2048, true);
        pilote.notifier(0);
        assert_eq!(pilote.octets(0x5000A, 60), trame_de(60, 0));
        assert_eq!(pilote.octets(0x5100A, 60), trame_de(60, 1));
        assert_eq!(pilote.carte.en_attente(), PLUS_EN_ATTENTE - 2);
    }

    /// **La file pleine, du côté qui part** : une page qui ne prend pas les
    /// trames émises en garde cinq cent douze ; la suivante est perdue, la
    /// requête rendue quand même. Une trame prise refait de la place.
    #[test]
    fn what_leaves_waits_up_to_its_bound() {
        let mut pilote = Pilote::branche();
        for n in 0..PLUS_EN_ATTENTE {
            pilote.emettre(&trame_de(60, n as u8), 0x40000);
        }
        assert_eq!(
            (pilote.carte.emises(), pilote.carte.perdues()),
            (PLUS_EN_ATTENTE as u64, 0)
        );
        pilote.emettre(&trame(), 0x40000);
        assert_eq!(
            (pilote.carte.emises(), pilote.carte.perdues()),
            (PLUS_EN_ATTENTE as u64, 1)
        );
        assert_eq!(
            pilote.servie(FILE_D_EMISSION, 0).2,
            PLUS_EN_ATTENTE as u16 + 1
        );
        assert_eq!(
            pilote.carte.sortir(),
            Some(trame_de(60, 0)),
            "la première d'abord"
        );
        pilote.emettre(&trame(), 0x40000);
        assert_eq!(pilote.carte.emises(), PLUS_EN_ATTENTE as u64 + 1);
        let mut toutes = Vec::new();
        while let Some(t) = pilote.carte.sortir() {
            toutes.push(t);
        }
        assert_eq!(toutes.len(), PLUS_EN_ATTENTE);
        assert_eq!(toutes[0], trame_de(60, 1));
        assert_eq!(toutes.last(), Some(&trame()));
    }

    /// **Un tampon hors de la RAM** : la trame émise est perdue plutôt que
    /// faite de zéros, la trame reçue aussi plutôt que posée à moitié ; les
    /// deux requêtes sont rendues.
    #[test]
    fn a_buffer_outside_the_ram_loses_the_frame() {
        let mut pilote = Pilote::branche();
        let dehors = pilote.ram.0.len() as u64 - 20;
        pilote.ecrire(&[0; 20], dehors);
        pilote.poser(FILE_D_EMISSION, dehors, 60, false);
        pilote.notifier(1);
        assert_eq!(pilote.carte.sortir(), None);
        assert_eq!((pilote.carte.emises(), pilote.carte.perdues()), (0, 1));
        assert_eq!(pilote.servie(FILE_D_EMISSION, 0).2, 1);
        pilote.poser(FILE_DE_RECEPTION, dehors, 2048, true);
        pilote.carte.entrer(trame());
        pilote.carte.livrer(&mut pilote.ram);
        assert_eq!(pilote.servie(FILE_DE_RECEPTION, 0), (0, 0, 1));
        assert_eq!((pilote.carte.livrees(), pilote.carte.perdues()), (0, 2));
    }

    /// **Un tampon hors de la RAM au milieu d'une chaîne de réception la
    /// coupe** : la trame est perdue, même si les tampons qui suivent ont la
    /// place. Les sauter rendrait au pilote une longueur qui couvre un
    /// tampon jamais écrit, qu'il lirait en premier — un paquet corrompu.
    /// Les tampons qui suivent restent intacts, et la trame suivante passe.
    #[test]
    fn a_buffer_outside_the_ram_in_a_receive_chain_cuts_it() {
        let mut pilote = Pilote::branche();
        let dehors = 0xFFFF_FFFF_0000;
        // En tête de chaîne : rien n'est écrit, la trame est perdue.
        pilote.poser_chaine(
            FILE_DE_RECEPTION,
            &[(dehors, 2048, true), (0x50000, 2048, true)],
        );
        pilote.carte.entrer(trame_de(60, 7));
        pilote.carte.livrer(&mut pilote.ram);
        assert_eq!(pilote.servie(FILE_DE_RECEPTION, 0), (0, 0, 1));
        assert_eq!((pilote.carte.livrees(), pilote.carte.perdues()), (0, 1));
        assert_eq!(pilote.octets(0x50000, 70), vec![0; 70], "le second intact");
        // Au milieu, après un morceau posé : perdue de même, le troisième
        // tampon jamais écrit.
        pilote.poser_chaine(
            FILE_DE_RECEPTION,
            &[
                (0x51000, 30, true),
                (dehors, 2048, true),
                (0x52000, 2048, true),
            ],
        );
        pilote.carte.entrer(trame_de(60, 8));
        pilote.carte.livrer(&mut pilote.ram);
        assert_eq!(pilote.servie(FILE_DE_RECEPTION, 1), (2, 0, 2));
        assert_eq!((pilote.carte.livrees(), pilote.carte.perdues()), (0, 2));
        assert_eq!(
            pilote.octets(0x52000, 70),
            vec![0; 70],
            "le troisième intact"
        );
        // La carte n'est pas bloquée : la trame suivante arrive.
        pilote.poser(FILE_DE_RECEPTION, 0x53000, 2048, true);
        pilote.carte.entrer(trame_de(60, 9));
        pilote.carte.livrer(&mut pilote.ram);
        assert_eq!(pilote.servie(FILE_DE_RECEPTION, 2), (5, 70, 3));
        assert_eq!(pilote.octets(0x5300A, 60), trame_de(60, 9));
        assert_eq!((pilote.carte.livrees(), pilote.carte.perdues()), (1, 2));
    }

    /// **Deux trames, deux tampons, une notification** : les deux arrivent,
    /// chacune dans le sien, dans l'ordre ; deux émissions d'une
    /// notification partent toutes les deux.
    #[test]
    fn one_notification_serves_every_posted_buffer() {
        let mut pilote = Pilote::branche();
        pilote.poser(FILE_DE_RECEPTION, 0x50000, 2048, true);
        pilote.poser(FILE_DE_RECEPTION, 0x51000, 2048, true);
        pilote.carte.entrer(trame_de(60, 1));
        pilote.carte.entrer(trame_de(70, 2));
        pilote.carte.entrer(trame_de(80, 3));
        pilote.notifier(0);
        assert_eq!(pilote.servie(FILE_DE_RECEPTION, 0), (0, 70, 2));
        assert_eq!(pilote.servie(FILE_DE_RECEPTION, 1).1, 80);
        assert_eq!(pilote.octets(0x5100A, 70), trame_de(70, 2));
        assert_eq!(pilote.carte.en_attente(), 1, "la troisième attend");
        let mut octets = vec![0u8; OCTETS_D_EN_TETE];
        octets.extend(trame_de(50, 4));
        pilote.ecrire(&octets, 0x40000);
        pilote.ecrire(&octets, 0x41000);
        pilote.poser(FILE_D_EMISSION, 0x40000, 60, false);
        pilote.poser(FILE_D_EMISSION, 0x41000, 60, false);
        pilote.notifier(1);
        assert_eq!(pilote.carte.emises(), 2);
        assert_eq!(pilote.servie(FILE_D_EMISSION, 1), (1, 0, 2));
        // Une notification d'une file qui n'existe pas ne sert rien.
        pilote.poser(FILE_DE_RECEPTION, 0x52000, 2048, true);
        pilote.notifier(2);
        assert_eq!(pilote.carte.en_attente(), 1);
        pilote.notifier(0);
        assert_eq!(pilote.carte.en_attente(), 0);
    }

    /// **Les registres de la poignée de main** : les fonctions acceptées ne
    /// gardent que `MAC`, la file choisie revient à zéro au-delà de un, la
    /// page de chaque file se relit, et zéro la retire.
    #[test]
    fn the_handshake_registers_read_back() {
        let mut ram = RamPlate(vec![0; 1 << 16]);
        let mut carte = VirtioNet::default();
        carte.ecrire_port(0x04, 0xFFFF_FFFF, &mut ram);
        assert_eq!(carte.lire_port(0x04, 4), FONCTION_MAC);
        carte.ecrire_port(0x04, 0, &mut ram);
        assert_eq!(carte.lire_port(0x04, 4), 0);
        carte.ecrire_port(0x0E, 1, &mut ram);
        assert_eq!(carte.lire_port(0x0E, 2), 1);
        carte.ecrire_port(0x08, 0x20, &mut ram);
        carte.ecrire_port(0x0E, 2, &mut ram);
        assert_eq!(carte.lire_port(0x0E, 2), 0, "deux files seulement");
        assert_eq!(carte.lire_port(0x08, 4), 0, "la zéro, vide");
        carte.ecrire_port(0x0E, 0x1_0001, &mut ram);
        assert_eq!(carte.lire_port(0x0E, 2), 1, "seize bits");
        assert_eq!(carte.lire_port(0x08, 4), 0x20);
        let (descripteurs, disponibles, servies) = anneaux(0x20, LIMITE_DE_FILE);
        assert_eq!(
            carte.files()[1],
            File {
                page: 0x20,
                descripteurs,
                disponibles,
                servies,
                prochaine_disponible: 0,
                prochaine_servie: 0,
            }
        );
        assert_eq!(
            servies - descripteurs,
            0x2000,
            "256 descripteurs : les servies deux pages plus loin"
        );
        carte.ecrire_port(0x08, 0, &mut ram);
        assert_eq!(carte.files()[1], File::default(), "zéro la retire");
        carte.ecrire_port(0x12, 7, &mut ram);
        assert_eq!(carte.lire_port(0x12, 1), 7);
        assert_eq!(
            carte.lire_port(0x10, 2),
            0,
            "la notification ne se relit pas"
        );
    }

    /// **La remise à zéro** (statut zéro) oublie les files, la file choisie,
    /// les fonctions, l'interruption et ce qui attendait ; un statut non nul
    /// ne remet rien à zéro. Ce qui est déjà émis reste au câble.
    #[test]
    fn a_reset_forgets_the_queues_and_what_waited() {
        let mut pilote = Pilote::branche();
        pilote
            .carte
            .ecrire_port(0x04, FONCTION_MAC, &mut pilote.ram);
        pilote.emettre(&trame(), 0x40000);
        pilote.carte.entrer(trame());
        pilote.carte.ecrire_port(0x0E, 1, &mut pilote.ram);
        pilote.carte.ecrire_port(0x12, 0x80, &mut pilote.ram);
        assert_eq!(
            pilote.carte.files()[1].page,
            PAGES[1],
            "0x80 n'est pas zéro"
        );
        assert!(pilote.carte.interrompt());
        pilote.carte.ecrire_port(0x12, 0, &mut pilote.ram);
        assert_eq!(pilote.carte.files(), &[File::default(); 2]);
        assert_eq!(pilote.carte.file_choisie(), 0);
        assert_eq!(pilote.carte.fonctions_du_pilote(), 0);
        assert!(!pilote.carte.interrompt());
        assert_eq!(pilote.carte.en_attente(), 0);
        assert_eq!(pilote.carte.statut(), 0);
        assert_eq!(pilote.carte.sortir(), Some(trame()), "déjà sur le fil");
        // Sans files, une notification ne sert rien.
        pilote.carte.entrer(trame());
        pilote.notifier(0);
        pilote.notifier(1);
        assert_eq!((pilote.carte.livrees(), pilote.carte.emises()), (0, 1));
    }

    /// **L'anneau des servies fait le tour** : au-delà de 256 tampons, la
    /// place repart de zéro et l'index continue, comme celui du pilote.
    #[test]
    fn the_rings_wrap_around() {
        let mut pilote = Pilote::branche();
        // Chaque trame a sa longueur (60 à 66 octets) : la place 2 de
        // l'anneau, écrite par la troisième puis par la 259e, dit laquelle
        // l'a écrite en dernier.
        for n in 0..LIMITE_DE_FILE + 3 {
            pilote.poser(FILE_DE_RECEPTION, 0x50000, 2048, true);
            pilote
                .carte
                .entrer(trame_de(60 + (n % 7) as usize, n as u8));
            pilote.notifier(0);
        }
        assert_eq!(
            pilote.servie(FILE_DE_RECEPTION, 2).1 as usize,
            OCTETS_D_EN_TETE + 60 + 258 % 7,
            "la longueur de la 259e, pas celle de la troisième"
        );
        assert_eq!(pilote.carte.livrees(), u64::from(LIMITE_DE_FILE) + 3);
        assert_eq!(
            pilote.servie(FILE_DE_RECEPTION, 2).2,
            LIMITE_DE_FILE as u16 + 3
        );
        assert_eq!(
            pilote.servie(FILE_DE_RECEPTION, 2).0,
            2,
            "la 259e à la place 2"
        );
        assert_eq!(
            pilote.octets(0x5000A, 60),
            trame_de(60, (LIMITE_DE_FILE + 2) as u8)
        );
    }

    /// **Une chaîne qui boucle** sur elle-même ne fait pas tourner la carte
    /// pour toujours : elle s'arrête à la taille de la file.
    #[test]
    fn a_looping_chain_is_bounded() {
        let mut pilote = Pilote::branche();
        let (descripteurs, _, _) = Pilote::anneaux(FILE_D_EMISSION);
        pilote.poser(FILE_D_EMISSION, 0x40000, 4, false);
        // Le descripteur zéro se suit lui-même.
        pilote.ram.ecrire(descripteurs + 12, &1u16.to_le_bytes());
        pilote.ram.ecrire(descripteurs + 14, &0u16.to_le_bytes());
        pilote.ecrire(&[0x11; 4], 0x40000);
        pilote.notifier(1);
        let partie = pilote.carte.sortir().expect("une trame, bornée");
        assert_eq!(partie.len(), LIMITE_DE_FILE as usize * 4 - OCTETS_D_EN_TETE);
        assert_eq!(pilote.servie(FILE_D_EMISSION, 0).2, 1);
    }

    /// **Une tête ou un suivant au-delà de la file se lit modulo sa taille**
    /// (`index % queueLimit` du Swift) : un invité qui publie 256 ou 257 ne
    /// fait pas lire la carte hors de la table des descripteurs — dans
    /// l'anneau des disponibles, puis au-delà. La tête rendue est celle que
    /// le pilote a publiée, telle quelle, comme `complete(head)`.
    #[test]
    fn a_head_or_a_next_past_the_table_wraps_into_it() {
        let mut pilote = Pilote::branche();
        let (descripteurs, disponibles, _) = Pilote::anneaux(FILE_D_EMISSION);
        pilote.ecrire(&[0; OCTETS_D_EN_TETE], 0x40000);
        pilote.ecrire(&trame(), 0x41000);
        pilote.poser_chaine(
            FILE_D_EMISSION,
            &[
                (0x40000, OCTETS_D_EN_TETE as u32, false),
                (0x41000, trame().len() as u32, false),
            ],
        );
        // La tête publiée : 256, soit le descripteur zéro ; son suivant :
        // 257, soit le un.
        pilote.ram.ecrire(disponibles + 4, &256u16.to_le_bytes());
        pilote.ram.ecrire(descripteurs + 14, &257u16.to_le_bytes());
        pilote.notifier(1);
        assert_eq!(pilote.carte.sortir(), Some(trame()));
        assert_eq!((pilote.carte.emises(), pilote.carte.perdues()), (1, 0));
        assert_eq!(pilote.servie(FILE_D_EMISSION, 0), (256, 0, 1));
        // Du côté qui reçoit : la tête 0x0300, soit le descripteur zéro —
        // sans le modulo, la carte la lirait trois tables plus loin, au-delà
        // des anneaux de la file.
        let (_, disponibles, _) = Pilote::anneaux(FILE_DE_RECEPTION);
        pilote.poser(FILE_DE_RECEPTION, 0x50000, 2048, true);
        pilote.ram.ecrire(disponibles + 4, &0x0300u16.to_le_bytes());
        pilote.carte.entrer(trame_de(60, 4));
        pilote.notifier(0);
        assert_eq!(pilote.octets(0x5000A, 60), trame_de(60, 4));
        assert_eq!(pilote.carte.livrees(), 1);
        assert_eq!(pilote.servie(FILE_DE_RECEPTION, 0), (0x0300, 70, 1));
    }

    /// **Une file sans page ne lit rien** (`queue.ready` du Swift) : avant la
    /// poignée de main, après une remise à zéro, ou une page retirée, une
    /// notification ne prend pas la RAM basse pour un anneau. Ici, la RAM
    /// basse en a l'air : à l'adresse deux un index publié, et à l'adresse
    /// zéro un descripteur lisible qui pointe une trame entière — lue comme
    /// une file, elle partirait.
    #[test]
    fn a_queue_without_a_page_reads_nothing() {
        let mut ram = RamPlate(vec![0; 1 << 20]);
        // L'index publié (un) est aussi le troisième octet de l'adresse du
        // descripteur zéro : 0x1_0000, où l'on pose la trame.
        ram.ecrire(2, &1u16.to_le_bytes());
        let longueur = (OCTETS_D_EN_TETE + trame().len()) as u32;
        ram.ecrire(8, &longueur.to_le_bytes());
        let mut octets = vec![0u8; OCTETS_D_EN_TETE];
        octets.extend(trame());
        ram.ecrire(0x1_0000, &octets);
        let avant = ram.0.clone();
        let rien = |carte: &VirtioNet, ram: &RamPlate, quand: &str| {
            assert_eq!(
                (carte.emises(), carte.livrees(), carte.perdues()),
                (0, 0, 0),
                "{quand}"
            );
            assert!(!carte.interrompt(), "{quand}");
            assert_eq!(carte.en_attente(), 1, "{quand} : la trame attend");
            assert!(ram.0 == avant, "{quand} : la RAM basse intacte");
        };
        // Avant la poignée de main.
        let mut carte = VirtioNet::default();
        carte.brancher_cable(true);
        carte.entrer(trame());
        carte.ecrire_port(0x10, 1, &mut ram);
        carte.ecrire_port(0x10, 0, &mut ram);
        assert_eq!(carte.sortir(), None);
        rien(&carte, &ram, "avant la poignée de main");
        // Une page posée puis retirée.
        for file in 0..2 {
            carte.ecrire_port(0x0E, file, &mut ram);
            carte.ecrire_port(0x08, PAGES[file as usize], &mut ram);
            carte.ecrire_port(0x08, 0, &mut ram);
        }
        carte.ecrire_port(0x10, 1, &mut ram);
        carte.ecrire_port(0x10, 0, &mut ram);
        rien(&carte, &ram, "page retirée");
        // Après la remise à zéro.
        for file in 0..2 {
            carte.ecrire_port(0x0E, file, &mut ram);
            carte.ecrire_port(0x08, PAGES[file as usize], &mut ram);
        }
        carte.ecrire_port(0x12, 0, &mut ram);
        carte.entrer(trame());
        carte.ecrire_port(0x10, 1, &mut ram);
        carte.ecrire_port(0x10, 0, &mut ram);
        carte.sonder(None, &mut ram, false);
        rien(&carte, &ram, "après la remise");
    }

    /// **Un tampon dont on ne lit rien ne perd pas la trame**, où qu'il
    /// pointe : un descripteur vide hors de la RAM, ou un tampon hors de la
    /// RAM après une trame déjà pleine. Aucun octet n'en vient, pas même un
    /// zéro ; le cœur Swift y copie zéro octet et envoie. Du côté qui reçoit,
    /// un tampon vide hors de la RAM ne coupe pas la chaîne. Un tampon hors
    /// de la RAM dont il faut lire, lui, perd toujours la trame.
    #[test]
    fn a_buffer_with_nothing_to_read_never_loses_the_frame() {
        let mut pilote = Pilote::branche();
        let dehors = 0xFFFF_FFFF_0000;
        let mut octets = vec![0u8; OCTETS_D_EN_TETE];
        octets.extend(trame());
        pilote.ecrire(&octets, 0x40000);
        pilote.poser_chaine(
            FILE_D_EMISSION,
            &[(0x40000, octets.len() as u32, false), (dehors, 0, false)],
        );
        pilote.notifier(1);
        assert_eq!(
            pilote.carte.sortir(),
            Some(trame()),
            "le vide hors de la RAM"
        );
        assert_eq!((pilote.carte.emises(), pilote.carte.perdues()), (1, 0));
        // Une trame de 1 600 octets, puis un tampon hors de la RAM : la trame
        // est pleine avant lui, rien n'y est lu.
        let grande = trame_de(1600, 6);
        let mut octets = vec![0u8; OCTETS_D_EN_TETE];
        octets.extend(&grande);
        pilote.ecrire(&octets, 0x41000);
        pilote.poser_chaine(
            FILE_D_EMISSION,
            &[(0x41000, octets.len() as u32, false), (dehors, 100, false)],
        );
        pilote.notifier(1);
        assert_eq!(
            pilote.carte.sortir(),
            Some(grande[..PLUS_GRANDE_TRAME].to_vec()),
            "après une trame pleine"
        );
        assert_eq!((pilote.carte.emises(), pilote.carte.perdues()), (2, 0));
        // Hors de la RAM et à lire : perdue.
        pilote.poser_chaine(
            FILE_D_EMISSION,
            &[
                (0x40000, OCTETS_D_EN_TETE as u32, false),
                (dehors, 60, false),
            ],
        );
        pilote.notifier(1);
        assert_eq!((pilote.carte.emises(), pilote.carte.perdues()), (2, 1));
        assert_eq!(pilote.servie(FILE_D_EMISSION, 2).2, 3, "toutes rendues");
        // Recevoir : un tampon vide hors de la RAM, puis un vrai.
        pilote.poser_chaine(
            FILE_DE_RECEPTION,
            &[(dehors, 0, true), (0x50000, 2048, true)],
        );
        pilote.carte.entrer(trame_de(60, 7));
        pilote.carte.livrer(&mut pilote.ram);
        assert_eq!(pilote.octets(0x5000A, 60), trame_de(60, 7));
        assert_eq!(pilote.servie(FILE_DE_RECEPTION, 0), (0, 70, 1));
        assert_eq!((pilote.carte.livrees(), pilote.carte.perdues()), (1, 1));
    }

    /// **Le câble en boucle** rend à l'invité ce qu'il a envoyé.
    #[test]
    fn a_loop_cable_brings_back_what_was_sent() {
        let mut pilote = Pilote::branche();
        let mut cable = CableEnBoucle::default();
        pilote.emettre(&trame(), 0x40000);
        while let Some(t) = pilote.carte.sortir() {
            cable.envoyer(&t);
        }
        assert_eq!(cable.envoyees, 1);
        pilote.poser(FILE_DE_RECEPTION, 0x50000, 2048, true);
        pilote
            .carte
            .sonder(Some(&mut cable), &mut pilote.ram, false);
        assert_eq!(pilote.octets(0x5000A, trame().len()), trame());
        assert!(cable.en_route.is_empty());
    }

    // ------------------------------------------------------- sur le bus, par la carte

    use super::super::pci::tests::adresse;
    use super::super::pci::{EMPLACEMENT_DU_RESEAU, LIGNE_DU_RESEAU};
    use super::super::{Carte, SansRam};

    /// La configuration par les deux ports, comme le noyau.
    fn config(carte: &mut Carte, emplacement: u32, registre: u32) -> u32 {
        carte.port_ecrire(0xCF8, 4, adresse(emplacement, registre), &mut SansRam);
        carte
            .port_lire(0xCFC, 4, &mut SansRam)
            .expect("le bus répond")
    }

    fn regler(carte: &mut Carte, emplacement: u32, registre: u32, largeur: u8, valeur: u32) {
        carte.port_ecrire(0xCF8, 4, adresse(emplacement, registre), &mut SansRam);
        carte.port_ecrire(0xCFC, largeur, valeur, &mut SansRam);
    }

    /// Placer et ouvrir la fenêtre d'un emplacement.
    fn ouvrir(carte: &mut Carte, emplacement: u32, fenetre: u32) {
        regler(carte, emplacement, 0x10, 4, fenetre);
        regler(carte, emplacement, 0x04, 2, 0x0005);
    }

    /// **Sur le bus : une carte Ethernet virtio à l'emplacement cinq**, à
    /// côté du pont et du disque, qui ne changent pas
    /// (`testTheCardAnswersOnSlotFiveAndNothingElseMoves`). Sans carte,
    /// l'emplacement est vide.
    #[test]
    fn the_card_answers_on_slot_five_and_nothing_else_moves() {
        let mut carte = Carte::nouvelle();
        carte.brancher_disque(1);
        assert_eq!(
            config(&mut carte, 5, 0x00),
            0xFFFF_FFFF,
            "pas encore de carte"
        );
        carte.brancher_reseau(MAC_PAR_DEFAUT);
        assert_eq!(EMPLACEMENT_DU_RESEAU, 5);
        assert_eq!(LIGNE_DU_RESEAU, 3);
        assert_eq!(config(&mut carte, 5, 0x00), 0x1000_1AF4);
        assert_eq!(config(&mut carte, 5, 0x08), 0x0200_0000);
        assert_eq!(config(&mut carte, 5, 0x2C), 0x0001_1AF4);
        assert_eq!(
            config(&mut carte, 5, 0x3C) & 0xFF,
            u32::from(LIGNE_DU_RESEAU)
        );
        assert_eq!(config(&mut carte, 5, 0x3C) >> 8 & 0xFF, 1, "broche A");
        assert_eq!(config(&mut carte, 5, 0x0C), 0, "en-tête de type zéro");
        assert_eq!(config(&mut carte, 3, 0x00), 0x1001_1AF4);
        assert_eq!(config(&mut carte, 3, 0x08), 0x0100_0000);
        assert_eq!(config(&mut carte, 3, 0x2C), 0x0002_1AF4);
        assert_eq!(config(&mut carte, 0, 0x00), 0x1237_8086);
        assert_eq!(config(&mut carte, 6, 0x00), 0xFFFF_FFFF);
        for emplacement in (1..32).filter(|e| ![3, 5].contains(e)) {
            assert_eq!(
                config(&mut carte, emplacement, 0x00),
                0xFFFF_FFFF,
                "{emplacement}"
            );
        }
        // La carte seule, sans disque : son emplacement, et lui seul.
        let mut seule = Carte::nouvelle();
        seule.brancher_reseau(MAC_PAR_DEFAUT);
        assert_eq!(config(&mut seule, 5, 0x00), 0x1000_1AF4);
        assert_eq!(config(&mut seule, 3, 0x00), 0xFFFF_FFFF);
        assert_eq!(
            config(&mut seule, 0, 0x00),
            0x1237_8086,
            "le pont, toujours"
        );
    }

    /// **La fenêtre se mesure, se place et s'ouvre** comme celle d'un disque,
    /// sans toucher à la sienne ; la ligne s'écrit d'un octet.
    #[test]
    fn the_window_and_the_line_are_the_kernels() {
        let mut carte = Carte::nouvelle();
        carte.brancher_disque(1);
        carte.brancher_reseau(MAC_PAR_DEFAUT);
        regler(&mut carte, 5, 0x10, 4, 0xFFFF_FFFF);
        assert_eq!(
            config(&mut carte, 5, 0x10),
            0xFFFF_FFC1,
            "soixante-quatre ports"
        );
        assert_eq!(config(&mut carte, 3, 0x10), 1, "le disque ne se mesure pas");
        regler(&mut carte, 5, 0x10, 4, 0xC07F);
        assert_eq!(config(&mut carte, 5, 0x10), 0xC041);
        assert_eq!(
            carte.port_lire(0xC054, 4, &mut SansRam),
            None,
            "placée, pas ouverte"
        );
        regler(&mut carte, 5, 0x04, 2, 0x0005);
        assert_eq!(config(&mut carte, 5, 0x04), 5);
        assert_eq!(config(&mut carte, 3, 0x04), 0, "la commande du disque");
        assert_eq!(carte.port_lire(0xC054, 4, &mut SansRam), Some(0x7369_7702));
        assert_eq!(carte.port_lire(0xC058, 2, &mut SansRam), Some(0x0171));
        assert_eq!(carte.port_lire(0xC04C, 2, &mut SansRam), Some(256));
        assert_eq!(
            carte.port_lire(0xC04C, 1, &mut SansRam),
            Some(0),
            "ramené à un octet"
        );
        assert_eq!(
            carte.port_lire(0xC07F, 1, &mut SansRam),
            Some(0),
            "le dernier port"
        );
        assert_eq!(
            carte.port_lire(0xC080, 1, &mut SansRam),
            None,
            "pas un de plus"
        );
        assert_eq!(
            carte.port_lire(0xC03F, 1, &mut SansRam),
            None,
            "ni un de moins"
        );
        // La ligne : trois, puis celle que le noyau écrit d'un octet ; la
        // broche ne bouge pas, et le disque garde la sienne.
        regler(&mut carte, 5, 0x3C, 1, 9);
        assert_eq!(config(&mut carte, 5, 0x3C), 0x109);
        assert_eq!(carte.pci.reseau.ligne, 9);
        assert_eq!(config(&mut carte, 3, 0x3C) & 0xFF, 5);
        // Fermée, la fenêtre n'est à personne.
        regler(&mut carte, 5, 0x04, 2, 0);
        assert_eq!(carte.port_lire(0xC054, 4, &mut SansRam), None);
        assert!(!carte.port_ecrire(0xC052, 1, 1, &mut SansRam));
    }

    /// **Un port que la fenêtre d'un disque et celle de la carte couvrent va
    /// au disque** (`portWrite`, `portRead` du cœur Swift) ; un port fixe
    /// n'est jamais à la carte réseau. Le disque fermé, elle reprend ses
    /// ports.
    #[test]
    fn a_disk_window_comes_before_the_cards() {
        let mut carte = Carte::nouvelle();
        carte.brancher_disque(8);
        carte.brancher_reseau(MAC_PAR_DEFAUT);
        ouvrir(&mut carte, 5, 0xC000);
        assert_eq!(carte.port_lire(0xC014, 4, &mut SansRam), Some(0x7369_7702));
        ouvrir(&mut carte, 3, 0xC000);
        assert_eq!(
            carte.port_lire(0xC014, 4, &mut SansRam),
            Some(8),
            "la capacité"
        );
        assert_eq!(carte.reseau_au_port(0xC014), None);
        regler(&mut carte, 3, 0x04, 2, 0);
        assert_eq!(carte.port_lire(0xC014, 4, &mut SansRam), Some(0x7369_7702));
        // Une fenêtre posée sur l'i8042 ne lui vole rien.
        ouvrir(&mut carte, 5, 0x40);
        assert_eq!(carte.reseau_au_port(0x60), None);
        assert_eq!(carte.reseau_au_port(0x54), Some(0x14));
        assert_eq!(
            carte.port_lire(0x64, 1, &mut SansRam),
            Some(0x14),
            "l'état du 8042"
        );
    }

    /// **Par les ports, jusqu'à la ligne 3** : la poignée de main, une trame
    /// émise par la notification de la file un — rangée pour le câble —, la
    /// ligne levée à niveau, tenue, et baissée par la lecture de l'ISR ; une
    /// trame entrée, livrée par la notification de la file zéro.
    #[test]
    fn a_frame_goes_through_the_ports_and_raises_line_three() {
        let mut carte = Carte::nouvelle();
        carte.brancher_reseau(MAC_PAR_DEFAUT);
        assert_eq!(carte.tenues() & (1 << 3), 1 << 3, "la carte tient sa ligne");
        assert!(!carte.reveil(), "câble débranché, rien ne viendra");
        carte.reseau_mut().expect("branchée").brancher_cable(true);
        assert!(carte.reveil(), "une trame peut arriver");
        ouvrir(&mut carte, 5, 0xC040);
        let mut pilote = Pilote::nouveau(VirtioNet::default());
        let mut ram = std::mem::replace(&mut pilote.ram, RamPlate(Vec::new()));
        for (port, largeur, valeur) in [
            (0xC052, 1, 0),
            (0xC052, 1, 3),
            (0xC044, 4, FONCTION_MAC),
            (0xC04E, 2, 0),
            (0xC048, 4, PAGES[0]),
            (0xC04E, 2, 1),
            (0xC048, 4, PAGES[1]),
            (0xC052, 1, 7),
        ] {
            assert!(carte.port_ecrire(port, largeur, valeur, &mut ram));
        }
        pilote.ram = ram;
        pilote.ecrire(&[0; OCTETS_D_EN_TETE], 0x40000);
        pilote.ecrire(&trame(), 0x4000A);
        pilote.poser(
            FILE_D_EMISSION,
            0x40000,
            (OCTETS_D_EN_TETE + trame().len()) as u32,
            false,
        );
        assert_eq!(carte.lignes() & (1 << 3), 0);
        // `outw` de 0x1_0001 : deux octets, la file un.
        assert!(carte.port_ecrire(0xC050, 2, 0x1_0001, &mut pilote.ram));
        let reseau = carte.reseau_mut().expect("branchée");
        assert_eq!(reseau.sortir(), Some(trame()));
        assert_eq!(pilote.servie(FILE_D_EMISSION, 0).2, 1);
        assert_eq!(carte.lignes(), 1 << 3, "la ligne 3, et elle seule");
        assert_eq!(carte.lignes(), 1 << 3, "à niveau : elle reste");
        assert_eq!(carte.port_lire(0xC053, 1, &mut SansRam), Some(1));
        assert_eq!(carte.lignes(), 0, "l'ISR lu la baisse");
        // Une trame entrée, et la réception notifiée.
        pilote.poser(FILE_DE_RECEPTION, 0x50000, 2048, true);
        assert!(carte
            .reseau_mut()
            .expect("branchée")
            .entrer(trame_de(64, 8)));
        assert!(carte.port_ecrire(0xC050, 2, 0, &mut pilote.ram));
        assert_eq!(pilote.octets(0x5000A, 64), trame_de(64, 8));
        assert_eq!(carte.lignes(), 1 << 3);
        // La ligne que le noyau écrit : la neuf, sur l'esclave.
        regler(&mut carte, 5, 0x3C, 1, 9);
        assert_eq!(carte.lignes(), 1 << 9);
        assert_eq!(carte.tenues() & (1 << 3), 0, "la trois n'est plus tenue");
        assert_ne!(carte.tenues() & (1 << 9), 0);
        // Une ligne de l'hôte n'est jamais tenue : la carte s'y tait.
        regler(&mut carte, 5, 0x3C, 1, 4);
        assert_eq!(carte.lignes(), 0);
        assert_eq!(carte.tenues() & (1 << 4), 0);
        let reseau = carte.reseau().expect("branchée");
        assert_eq!(
            (reseau.emises(), reseau.livrees(), reseau.perdues()),
            (1, 1, 0)
        );
    }

    /// **Le réveil, câble débranché** : la ligne levée ou une trame qui
    /// attend comptent ; rien d'autre.
    #[test]
    fn an_unplugged_card_wakes_only_for_what_it_holds() {
        let mut carte = Carte::nouvelle();
        assert!(!carte.reveil());
        carte.brancher_reseau(MAC_PAR_DEFAUT);
        assert!(!carte.reveil());
        let reseau = carte.reseau_mut().expect("branchée");
        reseau.entrer(trame());
        assert!(carte.reveil(), "une trame attend un tampon");
        let mut pilote = Pilote::nouveau(VirtioNet::default());
        pilote.poser(FILE_DE_RECEPTION, 0x50000, 2048, true);
        let reseau = carte.reseau_mut().expect("branchée");
        reseau.ecrire_port(0x0E, 0, &mut pilote.ram);
        reseau.ecrire_port(0x08, PAGES[0], &mut pilote.ram);
        reseau.livrer(&mut pilote.ram);
        assert_eq!(reseau.en_attente(), 0);
        assert!(carte.reveil(), "la ligne levée");
        carte.reseau_mut().expect("branchée").lire_port(0x13, 1);
        assert!(!carte.reveil(), "plus rien");
        // Une carte rebranchée repart neuve, à l'adresse donnée.
        carte.brancher_reseau([0x02, 9, 9, 9, 9, 9]);
        assert_eq!(
            carte.reseau().map(VirtioNet::mac),
            Some([0x02, 9, 9, 9, 9, 9])
        );
        assert_eq!(carte.reseau().map(VirtioNet::livrees), Some(0));
    }

    /// **Une écriture de configuration ailleurs ne touche pas la carte** : le
    /// pont, un emplacement vide (00:06.0, le second disque absent en
    /// 00:04.0, l'écran et la tablette absents), le disque, une autre
    /// fonction ou un autre bus de l'emplacement cinq, une adresse sans son
    /// bit d'activation. La commande, la fenêtre, la mesure et la ligne de
    /// la carte restent celles que le noyau lui a écrites.
    #[test]
    fn a_configuration_write_elsewhere_leaves_the_card_alone() {
        let mut carte = Carte::nouvelle();
        carte.brancher_disque(1);
        carte.brancher_reseau(MAC_PAR_DEFAUT);
        ouvrir(&mut carte, 5, 0xC040);
        ouvrir(&mut carte, 3, 0xC000);
        let ailleurs = [
            adresse(0, 0),
            adresse(3, 0),
            adresse(6, 0),
            adresse(4, 0),
            adresse(2, 0),
            adresse(7, 0),
            adresse(31, 0),
            adresse(5, 0) | (1 << 8),
            adresse(5, 0) | (1 << 16),
            adresse(5, 0) & !0x8000_0000,
        ];
        for base in ailleurs {
            for (registre, largeur, valeur) in [
                (0x04, 2, 0),
                (0x10, 4, 0xFFFF_FFFF),
                (0x10, 4, 0xD000),
                (0x3C, 1, 11),
            ] {
                carte.port_ecrire(0xCF8, 4, base | registre, &mut SansRam);
                carte.port_ecrire(0xCFC, largeur, valeur, &mut SansRam);
            }
            assert_eq!(
                carte.port_lire(0xC054, 4, &mut SansRam),
                Some(0x7369_7702),
                "{base:#x} : la fenêtre répond encore"
            );
            assert_eq!(config(&mut carte, 5, 0x04), 5, "{base:#x}");
            assert_eq!(config(&mut carte, 5, 0x10), 0xC041, "{base:#x}");
            assert_eq!(carte.pci.reseau.ligne, LIGNE_DU_RESEAU, "{base:#x}");
        }
        // Le disque, lui, a reçu ce qui était pour lui.
        assert_eq!(config(&mut carte, 3, 0x04), 0);
        assert_eq!(config(&mut carte, 3, 0x3C) & 0xFF, 11);
    }

    /// **Une carte rebranchée a un emplacement neuf**
    /// (`bus.network = X86PCIHost(network: nic)` dans
    /// `X86Machine.attach(network:)`) : fenêtre fermée, commande nulle, pas
    /// en mesure, ligne 3 — rien de ce que le noyau avait réglé pour
    /// l'ancienne. Rouverte par le noyau, elle répond de sa nouvelle adresse.
    /// Les disques gardent le leur.
    #[test]
    fn a_replugged_card_gets_a_new_slot() {
        let mut carte = Carte::nouvelle();
        carte.brancher_disque(1);
        carte.brancher_reseau(MAC_PAR_DEFAUT);
        ouvrir(&mut carte, 3, 0xC000);
        ouvrir(&mut carte, 5, 0xC040);
        regler(&mut carte, 5, 0x3C, 1, 9);
        regler(&mut carte, 5, 0x10, 4, 0xFFFF_FFFF);
        assert_eq!(config(&mut carte, 5, 0x10), 0xFFFF_FFC1, "en mesure");
        assert_eq!(carte.port_lire(0xC054, 4, &mut SansRam), Some(0x7369_7702));
        carte.brancher_reseau([0x02, 9, 9, 9, 9, 9]);
        assert_eq!(
            carte.port_lire(0xC054, 4, &mut SansRam),
            None,
            "la fenêtre de l'ancienne"
        );
        assert_eq!(config(&mut carte, 5, 0x04), 0, "la commande");
        assert_eq!(config(&mut carte, 5, 0x10), 1, "ni fenêtre ni mesure");
        assert_eq!(carte.pci.reseau.ligne, LIGNE_DU_RESEAU);
        assert_eq!(
            config(&mut carte, 5, 0x3C),
            0x100 | u32::from(LIGNE_DU_RESEAU)
        );
        assert_ne!(carte.tenues() & (1 << 3), 0, "la ligne 3 tenue");
        assert_eq!(carte.tenues() & (1 << 9), 0, "la neuf rendue");
        // Le disque n'a pas bougé.
        assert_eq!(config(&mut carte, 3, 0x04), 5);
        assert_eq!(carte.port_lire(0xC014, 4, &mut SansRam), Some(1));
        ouvrir(&mut carte, 5, 0xC040);
        assert_eq!(carte.port_lire(0xC054, 4, &mut SansRam), Some(0x0909_0902));
    }
}

#[cfg(test)]
mod tests_de_l_etat {
    //! **La carte réseau sauvée et relue** ([`VirtioNet::sauver`]) : ses
    //! files, ses trames en attente des deux côtés ; le câble reste dehors.
    use super::super::etat::essais::{chaque_coupure_refusee, octets_de, relu, se_relit};
    use super::tests::Pilote;
    use super::*;

    /// Une carte branchée, une trame émise et rendue, une qui attend un
    /// tampon de l'invité, une qui attend le câble.
    fn occupee() -> VirtioNet {
        let mut pilote = Pilote::branche();
        pilote
            .carte
            .ecrire_port(0x04, FONCTION_MAC, &mut pilote.ram);
        pilote.poser_chaine(FILE_D_EMISSION, &[(0x8000, 10, false), (0x9000, 60, false)]);
        pilote.carte.emettre(&mut pilote.ram);
        assert!(pilote.carte.entrer(vec![0xAB; 60]));
        pilote.carte.ecrire_port(0x0E, 1, &mut pilote.ram);
        assert_eq!(pilote.carte.sortantes.len(), 1);
        pilote.carte
    }

    #[test]
    fn a_busy_card_reads_back_without_its_cable() {
        let carte = occupee();
        let octets = octets_de(&carte, VirtioNet::sauver);
        let relue = relu(&octets, VirtioNet::relire).expect("relue");
        assert!(
            !relue.cable_branche(),
            "le câble n'est pas dans l'instantané"
        );
        let mut rebranchee = relue.clone();
        rebranchee.brancher_cable(true);
        assert_eq!(rebranchee, carte);
        chaque_coupure_refusee(&octets, VirtioNet::relire);
        let neuve = VirtioNet::nouvelle(MAC_PAR_DEFAUT);
        assert_eq!(
            relu(&octets_de(&neuve, VirtioNet::sauver), VirtioNet::relire),
            Some(neuve)
        );
    }

    #[test]
    fn what_no_card_holds_is_refused() {
        let carte = occupee();
        let relit = |abimer: fn(&mut VirtioNet)| {
            se_relit(&carte, abimer, VirtioNet::sauver, VirtioNet::relire)
        };
        assert!(relit(|_| {}), "telle quelle");
        assert!(
            !relit(|c| c.file_choisie = 2),
            "une file choisie au-delà des deux"
        );
        assert!(
            !relit(|c| c.fonctions_du_pilote |= 1),
            "une fonction qui n'est pas offerte"
        );
        assert!(!relit(|c| c.isr = 2), "un ISR qui n'est pas un bit de file");
        assert!(
            !relit(|c| c.files[0].servies += 8),
            "des anneaux qui ne sont pas ceux de la page"
        );
        assert!(
            !relit(|c| c.files[1].prochaine_servie = 7),
            "deux index qui ne se suivent pas"
        );
        assert!(
            !relit(|c| c.files[0] = File {
                prochaine_disponible: 3,
                prochaine_servie: 3,
                ..File::vide()
            }),
            "une file retirée qui garde ses index"
        );
        assert!(
            !relit(|c| c.attente[0] = vec![0; PLUS_GRANDE_TRAME + 1]),
            "une trame plus longue qu'une trame"
        );
        assert!(
            relit(|c| c.attente[0] = vec![0; PLUS_GRANDE_TRAME]),
            "la plus longue passe"
        );
        let trop = |c: &mut VirtioNet| {
            c.sortantes = std::iter::repeat_n(vec![1], PLUS_EN_ATTENTE + 1).collect()
        };
        assert!(
            !se_relit(&carte, trop, VirtioNet::sauver, VirtioNet::relire),
            "trop de trames qui attendent le câble"
        );
    }
}
