//! **Une tablette virtio : toucher l'écran là où l'on veut cliquer.** Portée
//! depuis `VirtioTablet` du cœur Swift (`Sources/WisqVM/VirtioTablet.swift`),
//! registre pour registre.
//!
//! La souris PS/2 ([`i8042`](super::i8042)) est relative : le doigt la pousse
//! comme un pavé tactile, et le pointeur ne va jamais exactement sous le
//! doigt — Xorg accélère ce qu'on lui envoie. Une tablette dit **où** : une
//! position absolue entre 0 et 32 767 sur chaque axe, que Linux
//! (`virtio_input`, puis `evdev`) et Xorg (`libinput`) rapportent à l'écran
//! entier. C'est ce que fait la `virtio-tablet` de QEMU : mêmes axes, mêmes
//! boutons, plus la molette.
//!
//! **Le transport « moderne » de virtio 1.0, et pas l'ancien.** Les disques
//! parlent l'ancien transport, par des ports ; `virtio_input` le refuse (il
//! exige `VIRTIO_F_VERSION_1`). Ici donc : l'espace de configuration PCI
//! porte une **liste de capacités** qui disent où, dans la BAR0 (seize
//! kibioctets **en mémoire**), trouver les registres communs, l'ISR, la
//! configuration du périphérique et les sonnettes. Les files sont décrites
//! par trois adresses de 64 bits, et le pilote les active une à une.
//!
//! **Pas de MSI-X** : le pilote retombe sur la ligne d'interruption (INTx).
//! Les vecteurs demandés sont refusés (`0xFFFF`).
//!
//! **Sur le bus** : 00:07.0, `1AF4:1052`, révision 1, classe `0980`, ligne 10
//! tant que le noyau n'en écrit pas une autre ([`EMPLACEMENT_DE_LA_TABLETTE`],
//! [`LIGNE_DE_LA_TABLETTE`]) ; sa BAR0 à `0xE101_0000` au départ
//! ([`BASE_DE_LA_TABLETTE`]), comme `X86Machine.tabletBase`.
//!
//! **Ce qui change par rapport au Swift** : pas de verrou — la carte a un
//! seul propriétaire, la machine, et c'est elle qui reçoit les gestes de
//! l'application — et un drapeau de plus, [`Tablette::reveil`], qui dit si un
//! événement en attente peut encore partir sans que l'invité agisse. Le
//! cœur Swift, lui, tient la machine éveillée dès qu'une tablette existe.
//!
//! **Ce qui n'est pas porté** : l'instantané (`save`, `restore`).

use std::collections::VecDeque;

use super::ecran::BASE_DES_REGISTRES;
use super::Ram;

/// Le nom que `evdev` donne au périphérique.
pub const NOM: &str = "wisq tablet";
/// L'étendue de chaque axe : de 0 à 32 767, comme la tablette de QEMU.
pub const AXE_MAXIMUM: u32 = 0x7FFF;

// Les codes de `linux/input-event-codes.h`.
const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const EV_REL: u16 = 0x02;
const EV_ABS: u16 = 0x03;
const REL_WHEEL: u16 = 0x08;
const ABS_X: u16 = 0x00;
const ABS_Y: u16 = 0x01;
/// `BTN_LEFT`, `BTN_RIGHT`, `BTN_MIDDLE`.
const BOUTONS: [u16; 3] = [0x110, 0x111, 0x112];

/// virtio 1.0 : `0x1040` plus le numéro du périphérique, 18 pour l'entrée.
const IDENTITE: u32 = 0x1052_1AF4;
/// Révision 1 (« moderne ») ; classe 09, sous-classe 80 : « entrée, autre ».
const CLASSE_ET_REVISION: u32 = 0x0980_0001;
/// La taille de la BAR0 : quatre pages, une par structure.
pub const TAILLE_DE_LA_FENETRE: u64 = 0x4000;

const COMMUN: u64 = 0x0000;
const ISR: u64 = 0x1000;
const PERIPHERIQUE: u64 = 0x2000;
const SONNETTES: u64 = 0x3000;
/// L'écart entre deux sonnettes : `queue_notify_off` fois ce nombre.
const MULTIPLICATEUR: u32 = 4;

/// **L'emplacement sur le bus** (`VirtioTablet.slot`).
pub const EMPLACEMENT_DE_LA_TABLETTE: u32 = 7;
/// **Sa ligne d'interruption** (`VirtioTablet.line`) : la 10, libre — le
/// disque, le second disque, la carte réseau, le port série, le clavier et la
/// souris ont les leurs. À l'esclave, comme la souris.
pub const LIGNE_DE_LA_TABLETTE: u8 = 10;
/// **Où sa BAR0 se pose au départ** (`X86Machine.tabletBase`) : seize
/// kibioctets, alignés, après les registres de la carte graphique.
pub const BASE_DE_LA_TABLETTE: u64 = BASE_DES_REGISTRES + 0x1_0000;

/// Où commence la liste des capacités dans l'espace de configuration.
const PREMIERE_CAPACITE: u32 = 0x40;

/// **La liste des capacités**, telle que le pilote la parcourt depuis le
/// pointeur `0x34` : une par structure, seize octets chacune (vingt pour les
/// sonnettes, qui ajoutent leur multiplicateur), chaînées. Le type (1
/// commun, 2 sonnettes, 3 ISR, 4 périphérique), le décalage dans la BAR0, la
/// longueur.
const CAPACITES: [(u8, u64, u32); 4] = [
    (1, COMMUN, 0x38),
    (3, ISR, 4),
    (4, PERIPHERIQUE, 0x88),
    (2, SONNETTES, 2 * MULTIPLICATEUR),
];

/// La taille des deux files, que le pilote peut réduire.
pub const TAILLE_DE_FILE: u16 = 64;
/// La file des événements, puis celle de l'état (les voyants du clavier).
pub const FILE_DES_EVENEMENTS: usize = 0;
pub const FILE_DE_L_ETAT: usize = 1;
/// `VIRTIO_F_VERSION_1`, le bit 32 : le seul offert, le seul exigé.
pub const VERSION_1: u64 = 1 << 32;

/// **Ce que l'application peut laisser en attente**, en événements : une
/// machine qui ne lit plus ses événements ne fait pas grossir l'application.
pub const LIMITE_EN_ATTENTE: usize = 1024;
/// **La molette, au plus tant de crans d'un coup.**
pub const PLUS_DE_CRANS: u32 = 32;
/// **Le rythme d'un doigt autour des boutons**, en tics du 8254 : 30 ms,
/// l'appui du clavier. Voir [`Tablette::livrer`].
pub const TICS_DES_BOUTONS: u64 = 35_795;

/// Une file : ce que le pilote en a dit, et où elle en est.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct File {
    pub taille: u16,
    pub active: bool,
    pub descripteurs: u64,
    pub disponibles: u64,
    pub servies: u64,
    pub prochaine_disponible: u16,
    pub prochaine_servie: u16,
}

impl File {
    const fn neuve() -> Self {
        Self {
            taille: TAILLE_DE_FILE,
            active: false,
            descripteurs: 0,
            disponibles: 0,
            servies: 0,
            prochaine_disponible: 0,
            prochaine_servie: 0,
        }
    }
}

/// Un `virtio_input_event` : type, code, valeur, huit octets.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Evenement {
    pub genre: u16,
    pub code: u16,
    pub valeur: u32,
}

impl Evenement {
    fn octets(&self) -> [u8; 8] {
        let mut huit = [0u8; 8];
        huit[..2].copy_from_slice(&self.genre.to_le_bytes());
        huit[2..4].copy_from_slice(&self.code.to_le_bytes());
        huit[4..].copy_from_slice(&self.valeur.to_le_bytes());
        huit
    }
}

/// Le premier descripteur d'un tampon offert : il suffit à un événement de
/// huit octets.
struct Tampon {
    tete: u16,
    adresse: u64,
    longueur: u32,
    inscriptible: bool,
}

/// **La tablette.**
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tablette {
    /// L'adresse de la BAR0, que le micrologiciel ou le noyau choisit.
    base: u64,
    commande: u16,
    mesure: bool,
    /// La ligne d'interruption, telle que le noyau la lit et l'écrit.
    pub ligne: u8,

    files: [File; 2],
    choix_de_file: u16,
    choix_des_offertes: u32,
    choix_des_acceptees: u32,
    acceptees: u64,
    statut: u8,
    etat_d_interruption: u8,
    /// Le choix de la configuration du périphérique (`select`, `subsel`).
    choix: u8,
    sous_choix: u8,

    /// Ce que l'application a demandé, en attente d'un tampon de l'invité.
    en_attente: VecDeque<Evenement>,
    /// Les boutons du dernier paquet rendu.
    boutons_rendus: u8,
    /// Le dernier paquet rendu changeait les boutons.
    dernier_changeait: bool,
    /// La dernière heure qu'on a donnée à [`Tablette::livrer`], pour la
    /// sonnette, qui n'en a pas. Sans aucune (les tests), rien n'est retenu.
    horloge: Option<u64>,
    /// L'invité a lu l'ISR depuis le dernier dépôt.
    acquitte: bool,
    /// L'heure où l'attente a commencé : le premier passage après la lecture.
    retenu_depuis: Option<u64>,
    /// Ce qui reste à rendre du paquet commencé, faute de tampons.
    reste_du_paquet: usize,
    /// La dernière livraison s'est arrêtée faute de tampon : rien ne partira
    /// avant que le pilote en offre et sonne.
    a_court: bool,
}

impl Tablette {
    /// Une tablette comme la laisse la mise sous tension : ni BAR, ni files.
    pub const fn nouvelle(ligne: u8) -> Self {
        Self {
            base: 0,
            commande: 0,
            mesure: false,
            ligne,
            files: [File::neuve(), File::neuve()],
            choix_de_file: 0,
            choix_des_offertes: 0,
            choix_des_acceptees: 0,
            acceptees: 0,
            statut: 0,
            etat_d_interruption: 0,
            choix: 0,
            sous_choix: 0,
            en_attente: VecDeque::new(),
            boutons_rendus: 0,
            dernier_changeait: false,
            horloge: None,
            acquitte: true,
            retenu_depuis: None,
            reste_du_paquet: 0,
            a_court: false,
        }
    }

    /// **La tablette d'une machine** (`X86Machine.attachDisplay`) : sur la
    /// ligne 10, sa BAR0 déjà posée à [`BASE_DE_LA_TABLETTE`].
    pub fn de_machine() -> Self {
        let mut tablette = Self::nouvelle(LIGNE_DE_LA_TABLETTE);
        tablette.ecrire_configuration(0x10, BASE_DE_LA_TABLETTE as u32);
        tablette
    }

    // ----------------------------------------- l'espace de configuration PCI

    /// L'adresse de la BAR0.
    pub fn base(&self) -> u64 {
        self.base
    }

    /// Le mot de configuration à `registre` (aligné sur quatre).
    pub fn configuration(&self, registre: u32) -> u32 {
        match registre {
            0x00 => IDENTITE,
            // L'état dit « liste de capacités présente » (bit 4 du mot d'état).
            0x04 => u32::from(self.commande) | (1 << 20),
            0x08 => CLASSE_ET_REVISION,
            0x0C => 0,
            0x10 => {
                if self.mesure {
                    !((TAILLE_DE_LA_FENETRE - 1) as u32)
                } else {
                    self.base as u32
                }
            }
            0x2C => 0x1100_1AF4,
            0x34 => PREMIERE_CAPACITE,
            0x3C => u32::from(self.ligne) | (1 << 8),
            _ => mot_de_capacite(registre).unwrap_or(0),
        }
    }

    /// Une écriture de configuration, déjà recomposée en un mot.
    pub fn ecrire_configuration(&mut self, registre: u32, valeur: u32) {
        match registre {
            0x04 => self.commande = valeur as u16,
            0x10 => {
                if valeur == 0xFFFF_FFFF {
                    self.mesure = true;
                } else {
                    self.mesure = false;
                    self.base = u64::from(valeur) & !(TAILLE_DE_LA_FENETRE - 1);
                }
            }
            0x3C => self.ligne = valeur as u8,
            _ => {}
        }
    }

    /// **Le décalage dans la BAR0**, ou rien si l'adresse est ailleurs ou que
    /// la mémoire du périphérique n'est pas encore allumée (bit 1 de la
    /// commande).
    pub fn decalage(&self, adresse: u64, largeur: usize) -> Option<u64> {
        if self.base == 0 || self.commande & 0x02 == 0 {
            return None;
        }
        let decalage = adresse.checked_sub(self.base)?;
        (decalage.checked_add(largeur as u64)? <= TAILLE_DE_LA_FENETRE).then_some(decalage)
    }

    // -------------------------------------------------- ce que la machine lit

    /// L'état posé par le pilote (`ACKNOWLEDGE`, `DRIVER`, `DRIVER_OK`,
    /// `FEATURES_OK`).
    pub fn statut(&self) -> u8 {
        self.statut
    }

    /// Les fonctions que le pilote a acceptées.
    pub fn acceptees(&self) -> u64 {
        self.acceptees
    }

    /// Les deux files, telles que le pilote les a posées.
    pub fn files(&self) -> &[File; 2] {
        &self.files
    }

    /// La ligne est demandée : l'ISR n'a pas été lu depuis le dernier dépôt.
    pub fn interrompt(&self) -> bool {
        self.etat_d_interruption != 0
    }

    /// **Le pilote l'a prise** : `DRIVER_OK` posé et la file des événements
    /// active. Avant, ou sur un système sans `virtio_input`, un toucher ne
    /// mènerait nulle part, et l'application garde la souris PS/2.
    pub fn prete(&self) -> bool {
        self.statut & 0x04 != 0 && self.files[FILE_DES_EVENEMENTS].active
    }

    /// Des événements attendent un tampon de l'invité.
    pub fn en_attente(&self) -> bool {
        !self.en_attente.is_empty()
    }

    /// Les événements en attente, dans l'ordre.
    pub fn attendus(&self) -> impl Iterator<Item = &Evenement> {
        self.en_attente.iter()
    }

    /// **Quelque chose peut encore lever la ligne sans que l'invité
    /// agisse** : elle est levée, ou un événement attend son heure dans une
    /// file que le pilote garnit. Faux quand il ne reste qu'à attendre le
    /// pilote : avant `DRIVER_OK`, ou une fois ses tampons épuisés, jusqu'à
    /// sa sonnette.
    pub fn reveil(&self) -> bool {
        self.interrompt() || (self.statut & 0x04 != 0 && self.en_attente() && !self.a_court)
    }

    // ----------------------------------------------------------- les registres

    /// Lire `largeur` octets au décalage `decalage` de la BAR0.
    pub fn lire(&mut self, decalage: u64, largeur: usize) -> u64 {
        match decalage {
            COMMUN..=0x37 => self.lire_commun(decalage - COMMUN, largeur),
            ISR => {
                // Lire l'ISR l'efface : c'est l'accusé de réception de l'INTx.
                let valeur = self.etat_d_interruption;
                self.etat_d_interruption = 0;
                if valeur & 1 != 0 {
                    self.acquitte = true;
                }
                u64::from(valeur)
            }
            PERIPHERIQUE..=0x2087 => {
                let octets = self.configuration_du_peripherique();
                let debut = (decalage - PERIPHERIQUE) as usize;
                (0..largeur.min(8)).fold(0u64, |valeur, rang| {
                    let octet = octets.get(debut + rang).copied().unwrap_or(0);
                    valeur | (u64::from(octet) << (8 * rang))
                })
            }
            _ => 0,
        }
    }

    /// **La file que ce décalage sonne**, si c'est une sonnette : ce qu'une
    /// machine qui n'a pas la RAM sous la main note, pour sonner plus tard
    /// ([`Tablette::sonner`]).
    pub fn sonnette(decalage: u64) -> Option<usize> {
        (SONNETTES..SONNETTES + 2 * u64::from(MULTIPLICATEUR))
            .contains(&decalage)
            .then(|| ((decalage - SONNETTES) / u64::from(MULTIPLICATEUR)) as usize)
    }

    /// Écrire `largeur` octets au décalage `decalage` de la BAR0. `ram` est
    /// celle de l'invité : une sonnette y lit sa file.
    pub fn ecrire(&mut self, decalage: u64, largeur: usize, valeur: u64, ram: &mut dyn Ram) {
        if let Some(file) = Self::sonnette(decalage) {
            self.sonner(file, ram);
            return;
        }
        match decalage {
            COMMUN..=0x37 => self.ecrire_commun(decalage - COMMUN, largeur, valeur),
            PERIPHERIQUE => {
                self.choix = valeur as u8;
                if largeur > 1 {
                    self.sous_choix = (valeur >> 8) as u8;
                }
            }
            0x2001 => self.sous_choix = valeur as u8,
            _ => {}
        }
    }

    /// **La sonnette d'une file** : des tampons neufs. La file d'état porte
    /// les voyants du clavier, qu'il n'y a pas : on les rend. Celle des
    /// événements livre **à la dernière heure connue** : sans elle, la
    /// sonnette rendait tout d'un coup, retenu compris, et l'appui et la
    /// relâche d'un toucher arrivaient à 27 µs d'écart.
    pub fn sonner(&mut self, file: usize, ram: &mut dyn Ram) {
        if file == FILE_DE_L_ETAT {
            self.vider_l_etat(ram);
        } else {
            self.a_court = false;
            self.livrer_depuis(ram, self.horloge, true);
        }
    }

    fn lire_commun(&self, decalage: u64, largeur: usize) -> u64 {
        let file = &self.files[usize::from(self.choix_de_file.min(1))];
        let valide = self.choix_de_file < 2;
        let valeur = match decalage {
            0x00 => u64::from(self.choix_des_offertes),
            0x04 => u64::from(self.choix_des_offertes == 1) * (VERSION_1 >> 32),
            0x08 => u64::from(self.choix_des_acceptees),
            0x0C => {
                (self.acceptees >> (32 * u64::from(self.choix_des_acceptees & 1))) & 0xFFFF_FFFF
            }
            0x10 => 0xFFFF, // msix_config : aucun vecteur
            0x12 => 2,      // num_queues
            0x14 => u64::from(self.statut),
            0x15 => 0, // config_generation : rien ne change
            0x16 => u64::from(self.choix_de_file),
            0x18 => u64::from(valide) * u64::from(file.taille),
            0x1A => 0xFFFF, // queue_msix_vector
            0x1C => u64::from(valide && file.active),
            0x1E => u64::from(valide) * u64::from(self.choix_de_file), // queue_notify_off
            0x20 => file.descripteurs,
            0x24 => file.descripteurs >> 32,
            0x28 => file.disponibles,
            0x2C => file.disponibles >> 32,
            0x30 => file.servies,
            0x34 => file.servies >> 32,
            _ => 0,
        };
        if largeur >= 8 {
            valeur
        } else {
            valeur & ((1u64 << (8 * largeur)) - 1)
        }
    }

    fn ecrire_commun(&mut self, decalage: u64, largeur: usize, valeur: u64) {
        let choisie = usize::from(self.choix_de_file);
        let valide = choisie < 2;
        // Une adresse de 64 bits, écrite d'un coup ou en deux moitiés.
        let bas = |champ: &mut u64| {
            *champ = if largeur >= 8 {
                valeur
            } else {
                (*champ & !0xFFFF_FFFF) | (valeur & 0xFFFF_FFFF)
            }
        };
        let haut =
            |champ: &mut u64| *champ = (*champ & 0xFFFF_FFFF) | ((valeur & 0xFFFF_FFFF) << 32);
        match decalage {
            0x00 => self.choix_des_offertes = valeur as u32,
            0x08 => self.choix_des_acceptees = valeur as u32,
            0x0C => {
                let rang = 32 * u64::from(self.choix_des_acceptees & 1);
                // Le pilote ne peut accepter que ce qui est offert.
                let offertes = (VERSION_1 >> rang) & 0xFFFF_FFFF;
                self.acceptees =
                    (self.acceptees & !(0xFFFF_FFFF << rang)) | ((valeur & offertes) << rang);
            }
            0x14 => {
                self.statut = valeur as u8;
                if self.statut == 0 {
                    self.remettre_a_zero();
                }
            }
            0x16 => self.choix_de_file = valeur as u16,
            0x18 if valide => {
                // Une taille plus petite, puissance de deux, est permise.
                let taille = valeur as u16;
                if taille != 0 && taille <= TAILLE_DE_FILE && taille & (taille - 1) == 0 {
                    self.files[choisie].taille = taille;
                }
            }
            0x1C if valide => self.files[choisie].active = valeur & 1 != 0,
            0x20 if valide => bas(&mut self.files[choisie].descripteurs),
            0x24 if valide => haut(&mut self.files[choisie].descripteurs),
            0x28 if valide => bas(&mut self.files[choisie].disponibles),
            0x2C if valide => haut(&mut self.files[choisie].disponibles),
            0x30 if valide => bas(&mut self.files[choisie].servies),
            0x34 if valide => haut(&mut self.files[choisie].servies),
            _ => {}
        }
    }

    /// La remise à zéro du pilote : les files, l'état, et ce qui attendait —
    /// un pilote qui recommence ne reçoit pas les gestes d'avant.
    ///
    /// **La tablette de la mise sous tension, moins ce qui n'est pas au
    /// pilote** : l'espace de configuration PCI (la BAR, la commande, la
    /// mesure, la ligne), que le noyau a posé et ne repose pas ; les deux
    /// sélecteurs de fonctions, que `reset` du Swift garde aussi ; et
    /// l'heure de la machine, qui ne recommence pas avec le pilote. Tout le
    /// reste repart de [`Tablette::nouvelle`] : un champ ajouté plus tard —
    /// comme `a_court`, que le Swift n'a pas — ne peut pas être oublié ici.
    fn remettre_a_zero(&mut self) {
        *self = Self {
            base: self.base,
            commande: self.commande,
            mesure: self.mesure,
            choix_des_offertes: self.choix_des_offertes,
            choix_des_acceptees: self.choix_des_acceptees,
            horloge: self.horloge,
            ..Self::nouvelle(self.ligne)
        };
    }

    // ------------------------------------- la configuration du périphérique

    /// `virtio_input_config` pour le couple (`select`, `subsel`) courant :
    /// les deux octets de choix, la taille, cinq réservés, puis la réponse.
    /// Une question sans réponse a une taille nulle.
    fn configuration_du_peripherique(&self) -> Vec<u8> {
        let reponse = reponse(self.choix, self.sous_choix);
        let mut octets = vec![
            self.choix,
            self.sous_choix,
            reponse.len() as u8,
            0,
            0,
            0,
            0,
            0,
        ];
        octets.extend_from_slice(&reponse);
        octets
    }

    // ---------------------------------------------------------- les événements

    /// **Un toucher** : la position, rapportée à l'écran (0 à 1 sur chaque
    /// axe, rognée), et l'état des trois boutons (bit 0 gauche, 1 droit,
    /// 2 milieu). Un paquet par appel, terminé par `SYN_REPORT`. `false` si
    /// la file pleine le refuse — entier.
    pub fn pointer(&mut self, x: f64, y: f64, boutons: u8) -> bool {
        // `as` sature, et un NaN devient zéro : aucune valeur ne fait trapper.
        let axe =
            |fraction: f64| (fraction.clamp(0.0, 1.0) * f64::from(AXE_MAXIMUM)).round() as u32;
        let mut paquet = [Evenement {
            genre: EV_SYN,
            code: 0,
            valeur: 0,
        }; 6];
        paquet[0] = Evenement {
            genre: EV_ABS,
            code: ABS_X,
            valeur: axe(x),
        };
        paquet[1] = Evenement {
            genre: EV_ABS,
            code: ABS_Y,
            valeur: axe(y),
        };
        for (rang, code) in BOUTONS.into_iter().enumerate() {
            paquet[2 + rang] = Evenement {
                genre: EV_KEY,
                code,
                valeur: u32::from((boutons >> rang) & 1),
            };
        }
        self.mettre_en_file(&paquet)
    }

    /// **La molette** : des crans, positifs vers le haut. **Un paquet par
    /// cran**, comme une vraie souris : cinq crans d'un coup, `REL_WHEEL` 5,
    /// arrivaient bien dans evdev, mais le terminal de Xfce ne défilait pas.
    /// Au plus [`PLUS_DE_CRANS`] d'un coup. `false` pour zéro cran, ou si la
    /// file pleine les refuse — tous.
    pub fn defiler(&mut self, crans: i32) -> bool {
        let pas: i32 = if crans < 0 { -1 } else { 1 };
        let combien = crans.unsigned_abs().min(PLUS_DE_CRANS) as usize;
        if combien == 0 {
            return false;
        }
        let mut paquets = Vec::with_capacity(2 * combien);
        for _ in 0..combien {
            paquets.push(Evenement {
                genre: EV_REL,
                code: REL_WHEEL,
                valeur: pas as u32,
            });
            paquets.push(Evenement {
                genre: EV_SYN,
                code: 0,
                valeur: 0,
            });
        }
        self.mettre_en_file(&paquets)
    }

    /// Un paquet entier ou rien : un `SYN` perdu collerait deux gestes.
    fn mettre_en_file(&mut self, paquet: &[Evenement]) -> bool {
        if self.en_attente.len() + paquet.len() > LIMITE_EN_ATTENTE {
            return false;
        }
        self.en_attente.extend(paquet.iter().copied());
        true
    }

    /// Les boutons que porte le paquet de tête, long de `fin` événements, ou
    /// ceux d'avant s'il n'en dit rien (la molette).
    fn boutons_du_paquet(&self, fin: usize) -> u8 {
        let mut boutons = self.boutons_rendus;
        for evenement in self.en_attente.iter().take(fin) {
            if evenement.genre != EV_KEY {
                continue;
            }
            let Some(rang) = BOUTONS.iter().position(|&code| code == evenement.code) else {
                continue;
            };
            if evenement.valeur != 0 {
                boutons |= 1 << rang;
            } else {
                boutons &= !(1 << rang);
            }
        }
        boutons
    }

    /// **Les événements en attente, dans les tampons que l'invité a
    /// offerts**, tant qu'il y en a. Chaque tampon reçoit un événement. Avec
    /// `maintenant` (les tics du 8254 de la machine), au rythme d'un doigt ;
    /// sans, tout part.
    ///
    /// **Le rythme d'un doigt autour des boutons.** Un appui, puis le glissé,
    /// puis la relâche, rendus d'un coup à l'invité, portent la même heure :
    /// xfwm4 voit l'appui sur la barre de titre, demande où en est le bouton,
    /// et le trouve déjà relâché — la fenêtre ne bouge pas. Un paquet qui
    /// suit un changement de boutons attend donc [`TICS_DES_BOUTONS`] : la
    /// relâche d'un toucher, le premier pas d'un glissé. Le reste passe sans
    /// attendre — l'appui lui-même, sans latence ajoutée, et les
    /// déplacements, qui retenus s'entasseraient dès que la machine prend du
    /// retard sur le doigt.
    ///
    /// **Les 30 ms comptent depuis que l'invité a lu** (l'ISR), pas depuis le
    /// dépôt : compté depuis le dépôt, une machine endormie sautait jusqu'au
    /// battement suivant et trouvait l'appui *et* la relâche dans ses
    /// tampons, datés à 17 µs d'écart.
    pub fn livrer(&mut self, ram: &mut dyn Ram, maintenant: Option<u64>) {
        self.livrer_depuis(ram, maintenant, false);
    }

    fn livrer_depuis(&mut self, ram: &mut dyn Ram, maintenant: Option<u64>, de_la_sonnette: bool) {
        if self.statut & 0x04 == 0 {
            return; // DRIVER_OK
        }
        if let (Some(heure), false) = (maintenant, de_la_sonnette) {
            self.horloge = Some(heure);
        }
        while !self.en_attente.is_empty() {
            // Un paquet qui commence en tête de file : peut-il partir ? Un
            // paquet commencé, lui, finit sans attendre.
            if self.reste_du_paquet == 0 {
                let fin = self
                    .en_attente
                    .iter()
                    .position(|e| e.genre == EV_SYN)
                    .unwrap_or(self.en_attente.len() - 1)
                    + 1;
                let boutons = self.boutons_du_paquet(fin);
                let change = boutons != self.boutons_rendus;
                if let (Some(heure), true) = (maintenant, self.dernier_changeait) {
                    if !self.acquitte {
                        return;
                    }
                    // L'heure de la sonnette est celle d'un passage ancien :
                    // elle ne commence pas l'attente, elle la laisse au 8254.
                    if self.retenu_depuis.is_none() && !de_la_sonnette {
                        self.retenu_depuis = Some(heure);
                    }
                    match self.retenu_depuis {
                        Some(depuis) if heure >= depuis.wrapping_add(TICS_DES_BOUTONS) => {}
                        _ => return,
                    }
                }
                let Some(tampon) = self.prochain_tampon(FILE_DES_EVENEMENTS, ram) else {
                    self.a_court = true;
                    return;
                };
                self.reste_du_paquet = fin;
                self.dernier_changeait = change;
                self.boutons_rendus = boutons;
                self.acquitte = false;
                self.retenu_depuis = None;
                self.livrer_un(tampon, ram);
            } else {
                let Some(tampon) = self.prochain_tampon(FILE_DES_EVENEMENTS, ram) else {
                    self.a_court = true;
                    return;
                };
                self.livrer_un(tampon, ram);
            }
            self.reste_du_paquet -= 1;
        }
    }

    fn livrer_un(&mut self, tampon: Tampon, ram: &mut dyn Ram) {
        let Some(evenement) = self.en_attente.pop_front() else {
            return;
        };
        if tampon.inscriptible && tampon.longueur >= 8 {
            // Un tampon hors de la RAM ne reçoit rien, et est rendu quand
            // même, comme `copyIn` du côté Swift.
            let _ = ram.ecrire(tampon.adresse, &evenement.octets());
            self.rendre(FILE_DES_EVENEMENTS, tampon.tete, 8, ram);
        } else {
            self.rendre(FILE_DES_EVENEMENTS, tampon.tete, 0, ram);
        }
    }

    /// La file d'état : les voyants que le pilote envoie. Rendus tels quels.
    fn vider_l_etat(&mut self, ram: &mut dyn Ram) {
        while let Some(tampon) = self.prochain_tampon(FILE_DE_L_ETAT, ram) {
            self.rendre(FILE_DE_L_ETAT, tampon.tete, 0, ram);
        }
    }

    /// Le prochain tampon offert dans une file : la tête de chaîne et son
    /// premier descripteur.
    fn prochain_tampon(&mut self, laquelle: usize, ram: &dyn Ram) -> Option<Tampon> {
        let file = self.files[laquelle];
        if !file.active || file.descripteurs == 0 {
            return None;
        }
        let publiees = lire_u16(ram, file.disponibles.wrapping_add(2))?;
        if publiees == file.prochaine_disponible {
            return None;
        }
        let place = u64::from(file.prochaine_disponible % file.taille);
        let entree = lire_u16(
            ram,
            file.disponibles.wrapping_add(4).wrapping_add(place * 2),
        )?;
        // La place est prise dès que l'entrée est lue, comme du côté Swift :
        // un descripteur illisible ne la rend pas.
        self.files[laquelle].prochaine_disponible = file.prochaine_disponible.wrapping_add(1);
        let tete = entree % file.taille;
        let a = file.descripteurs.wrapping_add(u64::from(tete) * 16);
        let adresse = lire_u64(ram, a)?;
        let longueur = lire_u32(ram, a.wrapping_add(8))?;
        let drapeaux = lire_u16(ram, a.wrapping_add(12))?;
        Some(Tampon {
            tete,
            adresse,
            longueur,
            inscriptible: drapeaux & 2 != 0, // VRING_DESC_F_WRITE
        })
    }

    /// Rendre un tampon au pilote : l'anneau des servies, et la ligne.
    fn rendre(&mut self, laquelle: usize, tete: u16, longueur: u32, ram: &mut dyn Ram) {
        let file = self.files[laquelle];
        let place = u64::from(file.prochaine_servie % file.taille);
        let entree = file.servies.wrapping_add(4).wrapping_add(place * 8);
        let _ = ram.ecrire(entree, &u32::from(tete).to_le_bytes());
        let _ = ram.ecrire(entree.wrapping_add(4), &longueur.to_le_bytes());
        let suivante = file.prochaine_servie.wrapping_add(1);
        self.files[laquelle].prochaine_servie = suivante;
        let _ = ram.ecrire(file.servies.wrapping_add(2), &suivante.to_le_bytes());
        self.etat_d_interruption |= 1;
    }
}

/// Un mot de la liste des capacités, ou rien hors de la liste.
fn mot_de_capacite(registre: u32) -> Option<u32> {
    let mut debut = PREMIERE_CAPACITE;
    for (rang, &(genre, decalage, longueur)) in CAPACITES.iter().enumerate() {
        let taille: u32 = if genre == 2 { 20 } else { 16 };
        if registre < debut || registre >= debut + taille {
            debut += taille;
            continue;
        }
        let suivante = if rang + 1 < CAPACITES.len() {
            debut + taille
        } else {
            0
        };
        return Some(match registre - debut {
            // `cap_vndr` (0x09, « propre au vendeur »), la suivante, la
            // longueur, le type.
            0 => 0x09 | (suivante << 8) | (taille << 16) | (u32::from(genre) << 24),
            4 => 0, // BAR0, et le remplissage
            8 => decalage as u32,
            12 => longueur,
            _ => MULTIPLICATEUR, // la seule entrée de vingt octets
        });
    }
    None
}

/// La réponse de `virtio_input_config` à (`select`, `subsel`).
fn reponse(choix: u8, sous_choix: u8) -> Vec<u8> {
    match (choix, sous_choix) {
        // VIRTIO_INPUT_CFG_ID_NAME
        (0x01, _) => NOM.as_bytes().to_vec(),
        // VIRTIO_INPUT_CFG_ID_DEVIDS : BUS_VIRTUAL, puis le vendeur, le
        // produit et la version de QEMU.
        (0x03, _) => vec![0x06, 0x00, 0xF4, 0x1A, 0x03, 0x00, 0x01, 0x00],
        // VIRTIO_INPUT_CFG_EV_BITS, pour EV_KEY, EV_REL, EV_ABS.
        (0x11, 0x01) => champ_de_bits(&BOUTONS),
        (0x11, 0x02) => champ_de_bits(&[REL_WHEEL]),
        (0x11, 0x03) => champ_de_bits(&[ABS_X, ABS_Y]),
        // VIRTIO_INPUT_CFG_ABS_INFO : min, max, fuzz, flat, res.
        (0x12, 0x00) | (0x12, 0x01) => [0, AXE_MAXIMUM, 0, 0, 0]
            .into_iter()
            .flat_map(u32::to_le_bytes)
            .collect(),
        _ => Vec::new(),
    }
}

/// Un champ de bits, octet de poids faible d'abord, assez long pour le plus
/// grand code.
fn champ_de_bits(codes: &[u16]) -> Vec<u8> {
    let plus_grand = codes.iter().copied().max().unwrap_or(0);
    let mut octets = vec![0u8; usize::from(plus_grand) / 8 + 1];
    for &code in codes {
        octets[usize::from(code) / 8] |= 1 << (code % 8);
    }
    octets
}

fn lire_u16(ram: &dyn Ram, a: u64) -> Option<u16> {
    let mut deux = [0u8; 2];
    ram.lire(a, &mut deux).then(|| u16::from_le_bytes(deux))
}

fn lire_u32(ram: &dyn Ram, a: u64) -> Option<u32> {
    let mut quatre = [0u8; 4];
    ram.lire(a, &mut quatre).then(|| u32::from_le_bytes(quatre))
}

fn lire_u64(ram: &dyn Ram, a: u64) -> Option<u64> {
    let mut huit = [0u8; 8];
    ram.lire(a, &mut huit).then(|| u64::from_le_bytes(huit))
}

#[cfg(test)]
pub(crate) mod tests {
    //! **La tablette virtio, conduite comme Linux la conduit** : `virtio_pci`
    //! parcourt les capacités, `virtio_pci_modern` négocie et pose les files,
    //! `virtio_input` lit le nom, les bits et les axes, offre ses tampons, et
    //! lit ce qui y tombe. Les cas de
    //! `Tests/WisqVMTests/VirtioTabletTests.swift`, portés un pour un : les
    //! dix du périphérique seul, puis ceux « sur la machine » à travers la
    //! [`Carte`] et la façade [`CartePc`]. Le cas d'instantané n'est pas
    //! porté (pas d'instantané), ni `ScreenTouch.fraction`, qui est à
    //! l'application.
    use super::super::pc::CartePc;
    use super::super::pci::tests::adresse;
    use super::super::{Carte, RamPlate, SansRam};
    use super::*;

    const DESCRIPTEURS: u64 = 0x1000;
    const DISPONIBLES: u64 = 0x2000;
    const SERVIES: u64 = 0x3000;
    const TAMPONS: u64 = 0x4000;

    fn ram() -> RamPlate {
        RamPlate(vec![0; 0x10000])
    }

    fn poser(ram: &mut RamPlate, a: u64, octets: &[u8]) {
        assert!(ram.ecrire(a, octets), "{a:#x}");
    }

    fn u16_a(ram: &RamPlate, a: u64) -> u16 {
        lire_u16(ram, a).expect("dans la RAM")
    }

    fn u32_a(ram: &RamPlate, a: u64) -> u32 {
        lire_u32(ram, a).expect("dans la RAM")
    }

    /// La BAR posée, la mémoire du périphérique allumée.
    fn posee() -> Tablette {
        let mut tablette = Tablette::nouvelle(10);
        tablette.ecrire_configuration(0x10, 0xFE00_0000);
        tablette.ecrire_configuration(0x04, 0x0006);
        tablette
    }

    /// Les huit descripteurs de la file des événements, des tampons de huit
    /// octets inscriptibles, et les `combien` premiers offerts.
    fn garnir(ram: &mut RamPlate, combien: u16) {
        for rang in 0..8u64 {
            let a = DESCRIPTEURS + rang * 16;
            poser(ram, a, &(TAMPONS + rang * 8).to_le_bytes());
            poser(ram, a + 8, &8u32.to_le_bytes());
            poser(ram, a + 12, &2u16.to_le_bytes()); // VRING_DESC_F_WRITE
        }
        for rang in 0..combien {
            poser(
                ram,
                DISPONIBLES + 4 + u64::from(rang) * 2,
                &rang.to_le_bytes(),
            );
        }
        poser(ram, DISPONIBLES + 2, &combien.to_le_bytes());
    }

    /// La poignée de main de `virtio_pci_modern`, puis la file des
    /// événements posée et garnie de `combien` tampons de huit octets.
    fn demarree(ram: &mut RamPlate, combien: u16) -> Tablette {
        let mut tablette = posee();
        tablette.ecrire(0x14, 1, 0, ram); // remise à zéro
        tablette.ecrire(0x14, 1, 1 | 2, ram); // ACKNOWLEDGE | DRIVER
        tablette.ecrire(0x00, 4, 1, ram); // les bits 32 à 63 offerts…
        assert_eq!(tablette.lire(0x04, 4), 1, "VIRTIO_F_VERSION_1");
        tablette.ecrire(0x08, 4, 1, ram);
        tablette.ecrire(0x0C, 4, 1, ram); // …acceptés
        tablette.ecrire(0x14, 1, 1 | 2 | 8, ram); // FEATURES_OK
        assert_eq!(
            tablette.lire(0x14, 1) & 8,
            8,
            "le périphérique garde FEATURES_OK"
        );
        tablette.ecrire(0x16, 2, 0, ram); // la file des événements
        tablette.ecrire(0x18, 2, 8, ram);
        tablette.ecrire(0x1A, 2, 0, ram); // un vecteur MSI-X…
        assert_eq!(tablette.lire(0x1A, 2), 0xFFFF, "…refusé : l'INTx sert");
        tablette.ecrire(0x20, 8, DESCRIPTEURS, ram);
        tablette.ecrire(0x28, 4, DISPONIBLES, ram); // en deux moitiés, comme sur 32 bits
        tablette.ecrire(0x2C, 4, 0, ram);
        tablette.ecrire(0x30, 8, SERVIES, ram);
        tablette.ecrire(0x1C, 2, 1, ram); // activée
        tablette.ecrire(0x14, 1, 1 | 2 | 8 | 4, ram); // DRIVER_OK
        garnir(ram, combien);
        tablette
    }

    /// Combien d'événements ont été rendus : l'index de l'anneau des servies.
    fn rendus(ram: &RamPlate) -> usize {
        usize::from(u16_a(ram, SERVIES + 2))
    }

    /// Le `k`-ième événement rendu (type, code, valeur), dans une file de
    /// huit places.
    fn evenement(ram: &RamPlate, k: usize) -> [u32; 3] {
        let tete = u64::from(u32_a(ram, SERVIES + 4 + (k as u64 % 8) * 8));
        let a = TAMPONS + tete * 8;
        [
            u32::from(u16_a(ram, a)),
            u32::from(u16_a(ram, a + 2)),
            u32_a(ram, a + 4),
        ]
    }

    /// Les événements rendus, dans l'ordre : (type, code, valeur).
    fn evenements(ram: &RamPlate) -> Vec<[u32; 3]> {
        (0..rendus(ram)).map(|k| evenement(ram, k)).collect()
    }

    /// **Rien n'est écrit au-delà de l'anneau des servies** d'une file de
    /// huit places : `flags`, `idx`, huit entrées de huit octets, puis
    /// `avail_event`. [`evenement`] relit la place `k % 8`, comme le
    /// pilote : une entrée écrite hors de l'anneau ne s'y verrait pas, mais
    /// tomberait ici, dans la mémoire du noyau.
    fn rien_apres_l_anneau(ram: &RamPlate) {
        let fin = (SERVIES + 4 + 8 * 8 + 2) as usize;
        assert!(
            ram.0[fin..TAMPONS as usize].iter().all(|&octet| octet == 0),
            "une entrée servie écrite hors de l'anneau"
        );
    }

    // --------------------------------------------------- ce que voit `virtio_pci`

    /// **L'identité et la liste des capacités**
    /// (`testThePCIConfigurationListsTheFourStructures`) : 1AF4:1052,
    /// révision 1, et les quatre structures, chaînées, chacune dans la BAR0
    /// à son décalage.
    #[test]
    fn the_pci_configuration_lists_the_four_structures() {
        let tablette = posee();
        assert_eq!(tablette.configuration(0x00), 0x1052_1AF4);
        assert_eq!(
            tablette.configuration(0x08) & 0xFF,
            1,
            "révision 1 : moderne"
        );
        assert_eq!(tablette.configuration(0x08) >> 16, 0x0980, "entrée, autre");
        assert_ne!(
            tablette.configuration(0x04) & (1 << 20),
            0,
            "liste de capacités présente"
        );
        assert_eq!(tablette.configuration(0x2C), 0x1100_1AF4);
        assert_eq!(
            tablette.configuration(0x3C),
            10 | (1 << 8),
            "ligne 10, broche A"
        );
        assert_eq!(tablette.configuration(0x0C), 0);
        let mut trouvees = Vec::new();
        let mut a = tablette.configuration(0x34) & 0xFF;
        assert_eq!(a, 0x40);
        while a != 0 && trouvees.len() < 8 {
            let tete = tablette.configuration(a);
            assert_eq!(tete & 0xFF, 0x09, "propre au vendeur");
            assert_eq!(tablette.configuration(a + 4) & 0xFF, 0, "dans la BAR0");
            let genre = tete >> 24;
            let longueur = (tete >> 16) & 0xFF;
            assert_eq!(longueur, if genre == 2 { 20 } else { 16 });
            trouvees.push((
                genre,
                tablette.configuration(a + 8),
                tablette.configuration(a + 12),
            ));
            if genre == 2 {
                assert_eq!(tablette.configuration(a + 16), 4, "le multiplicateur");
            }
            a = (tete >> 8) & 0xFF;
        }
        // Dans l'ordre de la chaîne : le commun, l'ISR, le périphérique, les
        // sonnettes — chacun à sa page, avec sa longueur.
        assert_eq!(
            trouvees,
            [
                (1, 0, 0x38),
                (3, 0x1000, 4),
                (4, 0x2000, 0x88),
                (2, 0x3000, 8)
            ]
        );
        for &(_, decalage, longueur) in &trouvees {
            assert!(u64::from(decalage) + u64::from(longueur) <= TAILLE_DE_LA_FENETRE);
        }
        // Après la dernière capacité, plus rien.
        assert_eq!(tablette.configuration(0x40 + 16 * 3 + 20), 0);
        assert_eq!(tablette.configuration(0x38), 0);
    }

    /// **La BAR0 se mesure et se pose** comme toute BAR de seize kibioctets,
    /// et ne répond qu'une fois la mémoire du périphérique allumée
    /// (`testTheBarIsSizedPlacedAndGated`).
    #[test]
    fn the_bar_is_sized_placed_and_gated() {
        let mut tablette = Tablette::nouvelle(10);
        assert_eq!(tablette.decalage(0, 1), None, "sans BAR, nulle part");
        // **Sans BAR, nulle part, même la mémoire allumée** : une base nulle
        // prendrait les seize premiers kibioctets, ceux de la RAM
        // (`registerOffset`, `guard base != 0`).
        tablette.ecrire_configuration(0x04, 0x0002);
        for adresse in [0, 0x14, 0x3FFC] {
            assert_eq!(tablette.decalage(adresse, 4), None, "{adresse:#x}");
        }
        tablette.ecrire_configuration(0x04, 0x0000);
        tablette.ecrire_configuration(0x10, 0xFFFF_FFFF);
        assert_eq!(tablette.configuration(0x10), 0xFFFF_C000);
        tablette.ecrire_configuration(0x10, 0xFE00_1234);
        assert_eq!(tablette.configuration(0x10), 0xFE00_0000);
        assert_eq!(tablette.base(), 0xFE00_0000);
        assert_eq!(
            tablette.decalage(0xFE00_0014, 1),
            None,
            "mémoire du périphérique éteinte"
        );
        tablette.ecrire_configuration(0x04, 0x0001);
        assert_eq!(tablette.decalage(0xFE00_0014, 1), None, "les ports seuls");
        tablette.ecrire_configuration(0x04, 0x0002);
        assert_eq!(tablette.decalage(0xFE00_2004, 4), Some(0x2004));
        assert_eq!(tablette.decalage(0xFE00_3FFC, 4), Some(0x3FFC));
        assert_eq!(
            tablette.decalage(0xFE00_3FFE, 4),
            None,
            "à cheval sur la fin"
        );
        assert_eq!(tablette.decalage(0xFDFF_FFFF, 1), None, "juste avant");
        assert_eq!(tablette.decalage(0xFE00_4000, 1), None, "juste après");
        assert_eq!(tablette.decalage(u64::MAX, 4), None, "sans faire le tour");
        // La commande se relit, avec le bit des capacités ; la ligne est
        // celle que le noyau écrit.
        assert_eq!(tablette.configuration(0x04), 0x0002 | (1 << 20));
        tablette.ecrire_configuration(0x3C, 0x010B);
        assert_eq!(tablette.ligne, 11);
        assert_eq!(tablette.configuration(0x3C), 11 | (1 << 8));
        // Une tablette de machine a sa BAR déjà posée, mémoire éteinte.
        let de_machine = Tablette::de_machine();
        assert_eq!(de_machine.base(), 0xE101_0000);
        assert_eq!(de_machine.ligne, 10);
        assert_eq!(de_machine.decalage(0xE101_0000, 1), None);
    }

    // ------------------------------------------------- ce que lit `virtio_input`

    /// **Le nom, les boutons, les axes et la molette**, par `select` et
    /// `subsel`, avec leur taille ; une question sans réponse a une taille
    /// nulle (`testTheConfigurationAnswersWhatVirtioInputAsks`).
    #[test]
    fn the_configuration_answers_what_virtio_input_asks() {
        let mut tablette = posee();
        let mut ram = ram();
        let mut demander = |tablette: &mut Tablette, choix: u8, sous_choix: u8| -> Vec<u8> {
            tablette.ecrire(0x2000, 1, u64::from(choix), &mut ram);
            tablette.ecrire(0x2001, 1, u64::from(sous_choix), &mut ram);
            let taille = tablette.lire(0x2002, 1);
            (0..taille)
                .map(|rang| tablette.lire(0x2008 + rang, 1) as u8)
                .collect()
        };
        assert_eq!(demander(&mut tablette, 0x01, 0), b"wisq tablet");
        let touches = demander(&mut tablette, 0x11, 0x01);
        assert_eq!(touches.len(), 0x112 / 8 + 1);
        for code in [0x110usize, 0x111, 0x112] {
            assert_ne!(touches[code / 8] & (1 << (code % 8)), 0, "bouton {code:#x}");
        }
        assert_eq!(
            touches.iter().map(|o| o.count_ones()).sum::<u32>(),
            3,
            "ces trois boutons, et aucune autre touche"
        );
        assert_eq!(
            demander(&mut tablette, 0x11, 0x03),
            [0x03],
            "ABS_X et ABS_Y"
        );
        assert_eq!(
            demander(&mut tablette, 0x11, 0x02),
            [0x00, 0x01],
            "REL_WHEEL"
        );
        for axe in [0x00, 0x01] {
            let info = demander(&mut tablette, 0x12, axe);
            assert_eq!(info.len(), 20);
            assert_eq!(info[..4], [0; 4], "le minimum");
            assert_eq!(info[4..8], [0xFF, 0x7F, 0, 0], "le maximum de l'axe");
            assert_eq!(info[8..], [0; 12], "ni bruit, ni zone morte, ni résolution");
        }
        assert_eq!(demander(&mut tablette, 0x12, 0x02), [], "pas d'axe Z");
        assert_eq!(demander(&mut tablette, 0x11, 0x05), [], "pas de EV_SW");
        assert_eq!(
            demander(&mut tablette, 0x02, 0),
            [],
            "pas de numéro de série"
        );
        assert_eq!(
            demander(&mut tablette, 0x03, 0),
            [0x06, 0x00, 0xF4, 0x1A, 0x03, 0x00, 0x01, 0x00],
            "BUS_VIRTUAL, le vendeur, le produit et la version de QEMU"
        );
        // Lu d'un coup sur quatre octets, comme `virtio_cread`.
        tablette.ecrire(0x2000, 2, 0x0012, &mut ram);
        assert_eq!(tablette.lire(0x2000, 4) & 0xFF_FFFF, 0x14_0012);
        // Le sous-choix écrit avec le choix, d'un mot de deux octets.
        tablette.ecrire(0x2000, 2, 0x0311, &mut ram);
        assert_eq!(tablette.lire(0x2000, 4), 0x0001_0311);
        assert_eq!(tablette.lire(0x2008, 1), 0x03);
        // Au-delà de la réponse, des zéros ; au-delà de la structure, rien.
        assert_eq!(tablette.lire(0x2009, 8), 0);
        assert_eq!(tablette.lire(0x2086, 4), 0);
        assert_eq!(tablette.lire(0x2088, 1), 0);
        // **Un choix écrit sur un octet garde le sous-choix** (`width > 1`
        // du Swift) : seul un mot de deux octets porte les deux.
        tablette.ecrire(0x2001, 1, 0x03, &mut ram);
        tablette.ecrire(0x2000, 1, 0x11, &mut ram);
        assert_eq!(tablette.lire(0x2000, 2), 0x0311, "le sous-choix reste");
        // Huit octets d'un coup : les huit premiers du nom.
        tablette.ecrire(0x2000, 2, 0x0001, &mut ram);
        assert_eq!(
            tablette.lire(0x2008, 8).to_le_bytes(),
            *b"wisq tab",
            "lus d'un coup, sur huit octets"
        );
    }

    // ---------------------------------------------------------- les événements

    /// **Un toucher arrive en un paquet** (`testATouchArrivesAsOnePacket`) :
    /// X, Y, les trois boutons, puis `SYN_REPORT`, chacun dans son tampon, et
    /// l'interruption levée.
    #[test]
    fn a_touch_arrives_as_one_packet() {
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 8);
        assert!(tablette.prete() && !tablette.en_attente());
        assert!(tablette.pointer(0.5, 1.25, 1));
        assert!(tablette.en_attente() && tablette.reveil());
        assert!(!tablette.interrompt(), "rien avant la livraison");
        tablette.livrer(&mut ram, None);
        assert_eq!(
            evenements(&ram),
            [
                [3, 0, 16384],
                [3, 1, 32767],
                [1, 0x110, 1],
                [1, 0x111, 0],
                [1, 0x112, 0],
                [0, 0, 0]
            ]
        );
        // Chaque tampon rendu dit ses huit octets.
        for place in 0..6 {
            assert_eq!(u32_a(&ram, SERVIES + 8 + place * 8), 8);
            assert_eq!(u32_a(&ram, SERVIES + 4 + place * 8), place as u32);
        }
        assert!(tablette.interrompt());
        assert_eq!(tablette.lire(0x1000, 1), 1, "l'ISR dit la file");
        assert!(!tablette.interrompt(), "lire l'ISR l'efface");
        assert_eq!(tablette.lire(0x1000, 1), 0);
        assert!(!tablette.en_attente() && !tablette.reveil());
        // **La position et les boutons nommés** : un autre toucher, d'autres
        // valeurs dans chaque événement. Rogné à l'écran ; un nombre qui
        // n'en est pas un tombe à zéro, sans trapper.
        garnir(&mut ram, 8);
        poser(&mut ram, DISPONIBLES + 2, &14u16.to_le_bytes());
        assert!(tablette.pointer(-0.5, 0.25, 6));
        tablette.livrer(&mut ram, None);
        assert_eq!(
            (6..12).map(|k| evenement(&ram, k)).collect::<Vec<_>>(),
            [
                [3, 0, 0],
                [3, 1, 8192],
                [1, 0x110, 0],
                [1, 0x111, 1],
                [1, 0x112, 1],
                [0, 0, 0]
            ]
        );
        assert!(tablette.pointer(f64::NAN, f64::INFINITY, 0));
        let dernier: Vec<_> = tablette.attendus().map(|e| e.valeur).collect();
        assert_eq!(dernier, [0, 32767, 0, 0, 0, 0]);
    }

    /// **Un glissé au rythme d'un doigt**
    /// (`testButtonChangesArePacedLikeAFinger`) : l'appui part seul ; le
    /// glissé attend que l'invité l'ait lu, puis 30 ms. Rendus d'un coup,
    /// xfwm4 trouvait le bouton déjà relâché en commençant à déplacer la
    /// fenêtre, et elle ne bougeait pas.
    #[test]
    fn button_changes_are_paced_like_a_finger() {
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 8);
        // La file a huit places : le pilote rend chaque tampon lu, comme
        // `virtinput_recv_events`, et la file en offre `total` en tout.
        let offrir = |ram: &mut RamPlate, total: u16| {
            for rang in 0..total {
                poser(
                    ram,
                    DISPONIBLES + 4 + u64::from(rang % 8) * 2,
                    &(rang % 8).to_le_bytes(),
                );
            }
            poser(ram, DISPONIBLES + 2, &total.to_le_bytes());
        };
        let ecart = TICS_DES_BOUTONS;
        assert_eq!(ecart, 35_795, "30 ms du 8254");
        // L'appui part tout de suite : aucune latence ajoutée au toucher.
        tablette.pointer(0.1, 0.1, 1);
        tablette.livrer(&mut ram, Some(1000));
        assert_eq!(rendus(&ram), 6, "l'appui, sans attendre");
        assert_eq!(evenement(&ram, 2), [1, 0x110, 1]);
        tablette.pointer(0.2, 0.1, 1); // le glissé…
        tablette.pointer(0.3, 0.1, 1);
        tablette.pointer(0.3, 0.1, 0); // …et la relâche
        offrir(&mut ram, 64);
        // **Tant que l'invité n'a pas lu, rien ne suit**, quel que soit le
        // temps passé : c'est ce qui datait l'appui et la relâche à 17 µs.
        tablette.livrer(&mut ram, Some(1000 + 10 * ecart));
        assert_eq!(rendus(&ram), 6, "l'invité n'a pas encore lu l'appui");
        assert_eq!(tablette.lire(0x1000, 1), 1); // `vp_interrupt`
                                                 // L'attente part du premier passage après la lecture.
        tablette.livrer(&mut ram, Some(5_000_000));
        tablette.livrer(&mut ram, Some(5_000_000 + ecart - 1));
        assert_eq!(rendus(&ram), 6, "le glissé attend que l'appui ait duré");
        assert!(tablette.reveil(), "et la machine ne s'endort pas dessus");
        // Sans place pour plus de huit à la fois, la file se vide en
        // plusieurs passes : les deux pas, puis la relâche, à la même heure —
        // la relâche suit un déplacement, pas un changement de boutons.
        for _ in 0..4 {
            tablette.livrer(&mut ram, Some(5_000_000 + ecart));
        }
        assert_eq!(rendus(&ram), 24);
        assert_eq!(
            evenement(&ram, 20),
            [1, 0x110, 0],
            "la relâche du bouton gauche"
        );
        assert!(!tablette.en_attente());
        // Après la relâche, le premier déplacement attend à son tour la
        // lecture puis l'écart ; ensuite ils partent tous ensemble.
        for pas in 0..3 {
            tablette.pointer(f64::from(pas) / 10.0, 0.5, 0);
        }
        tablette.livrer(&mut ram, Some(6_000_000));
        assert_eq!(rendus(&ram), 24, "la relâche n'est pas lue");
        tablette.lire(0x1000, 1);
        tablette.livrer(&mut ram, Some(6_000_001));
        assert_eq!(rendus(&ram), 24, "l'écart commence");
        for _ in 0..3 {
            tablette.livrer(&mut ram, Some(6_000_001 + ecart));
        }
        assert_eq!(rendus(&ram), 24 + 18);
        // Et sans heure, comme avant, tout part.
        tablette.pointer(0.5, 0.5, 1);
        tablette.pointer(0.5, 0.5, 0);
        for _ in 0..2 {
            tablette.livrer(&mut ram, None);
        }
        assert_eq!(rendus(&ram), 24 + 18 + 12);
        // Cinquante-quatre entrées servies, dans un anneau de huit : chacune
        // à sa place `k % 8`, aucune au-delà.
        rien_apres_l_anneau(&ram);
    }

    /// **La sonnette ne passe pas outre**
    /// (`testTheDoorbellDoesNotReleaseWhatIsHeld`) : le pilote qui rend ses
    /// tampons sonne la file, et la sonnette rendait tout, retenu compris —
    /// l'appui et la relâche d'un toucher arrivaient encore à 27 µs d'écart.
    #[test]
    fn the_doorbell_does_not_release_what_is_held() {
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 8);
        tablette.pointer(0.5, 0.5, 2); // l'appui du clic droit
        tablette.pointer(0.5, 0.5, 0); // sa relâche
        tablette.livrer(&mut ram, Some(1000));
        assert_eq!(rendus(&ram), 6, "l'appui seul");
        assert_eq!(evenement(&ram, 3), [1, 0x111, 1], "le bouton droit");
        tablette.lire(0x1000, 1); // lu
        tablette.ecrire(0x3000, 2, 0, &mut ram); // la sonnette, aussitôt
        assert_eq!(rendus(&ram), 6, "la relâche reste retenue");
        tablette.livrer(&mut ram, Some(2000));
        tablette.ecrire(0x3000, 2, 0, &mut ram);
        assert_eq!(rendus(&ram), 6, "l'écart court depuis 2000");
        tablette.livrer(&mut ram, Some(2000 + TICS_DES_BOUTONS - 1));
        assert_eq!(rendus(&ram), 6, "un tic avant l'heure");
        tablette.livrer(&mut ram, Some(2000 + TICS_DES_BOUTONS));
        assert_eq!(
            rendus(&ram),
            8,
            "la relâche part, jusqu'au dernier tampon offert"
        );
        // Une tablette qui n'a jamais reçu d'heure ne retient rien à la
        // sonnette : c'est le chemin des tests sans horloge.
        let mut ram = self::ram();
        let mut tablette = demarree(&mut ram, 2);
        tablette.pointer(0.5, 0.5, 1);
        tablette.pointer(0.5, 0.5, 0);
        tablette.livrer(&mut ram, None);
        assert_eq!(rendus(&ram), 2, "faute de tampons");
        garnir(&mut ram, 8);
        tablette.ecrire(0x3000, 2, 0, &mut ram);
        assert_eq!(
            rendus(&ram),
            8,
            "le reste de l'appui et le début de la relâche"
        );
    }

    /// **Un paquet commencé finit sans attendre**
    /// (`testAStartedPacketFinishesWithoutWaiting`) : faute de tampons, la
    /// moitié d'un appui reste en file ; la suite n'est pas retenue comme un
    /// nouveau changement de boutons.
    #[test]
    fn a_started_packet_finishes_without_waiting() {
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 4);
        tablette.pointer(0.1, 0.1, 1);
        tablette.livrer(&mut ram, Some(1000));
        assert_eq!(evenements(&ram).len(), 4);
        garnir(&mut ram, 8);
        tablette.livrer(&mut ram, Some(1001));
        assert_eq!(
            evenements(&ram).len(),
            6,
            "le bouton droit, le milieu et SYN, tout de suite"
        );
        assert!(!tablette.en_attente());
    }

    /// **Faute de tampons, les événements attendent** — dans l'ordre — et
    /// partent à la sonnette suivante. La molette va vers le haut en positif
    /// (`testEventsWaitForBuffersAndKeepTheirOrder`).
    #[test]
    fn events_wait_for_buffers_and_keep_their_order() {
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 2);
        assert!(tablette.defiler(-1));
        assert!(tablette.pointer(0.0, 0.0, 0));
        tablette.livrer(&mut ram, None);
        assert_eq!(evenements(&ram), [[2, 8, u32::MAX], [0, 0, 0]]);
        assert!(tablette.en_attente());
        // **Il ne reste qu'à attendre le pilote** : la ligne est levée, donc
        // la machine se réveille ; une fois l'ISR lu, plus rien ne peut
        // partir sans tampons, et elle peut dormir jusqu'à la sonnette.
        assert!(tablette.reveil(), "la ligne est levée");
        tablette.lire(0x1000, 1);
        assert!(
            !tablette.reveil(),
            "à court de tampons : au pilote de jouer"
        );
        tablette.livrer(&mut ram, None);
        assert!(!tablette.reveil() && !tablette.interrompt());
        // Deux tampons de plus, et la sonnette de la file zéro.
        garnir(&mut ram, 8);
        tablette.ecrire(0x3000, 2, 0, &mut ram);
        assert_eq!(evenements(&ram)[2], [3, 0, 0]);
        assert_eq!(evenements(&ram).len(), 8);
        assert!(!tablette.en_attente());
        // La molette vers le haut, et plusieurs crans : un paquet par cran.
        garnir(&mut ram, 8);
        poser(&mut ram, DISPONIBLES + 2, &12u16.to_le_bytes());
        assert!(tablette.defiler(2));
        tablette.livrer(&mut ram, None);
        let derniers: Vec<_> = (8..12).map(|k| evenement(&ram, k)).collect();
        assert_eq!(derniers, [[2, 8, 1], [0, 0, 0], [2, 8, 1], [0, 0, 0]]);
    }

    /// **Rien ne part avant `DRIVER_OK`**, et une remise à zéro oublie ce
    /// qui attendait : un pilote qui recommence ne reçoit pas les gestes
    /// d'avant
    /// (`testNothingIsDeliveredBeforeTheDriverIsReadyAndResetForgets`).
    #[test]
    fn nothing_is_delivered_before_the_driver_is_ready_and_reset_forgets() {
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 8);
        // Les files posées et garnies, mais l'état retiré à FEATURES_OK.
        tablette.ecrire(0x14, 1, 1 | 2 | 8, &mut ram);
        assert!(!tablette.prete());
        tablette.pointer(0.1, 0.1, 0);
        tablette.livrer(&mut ram, None);
        tablette.ecrire(0x3000, 2, 0, &mut ram);
        assert!(!tablette.interrompt());
        assert_eq!(rendus(&ram), 0);
        assert!(tablette.en_attente());
        assert!(!tablette.reveil(), "rien ne partira sans le pilote");
        tablette.ecrire(0x14, 1, 0, &mut ram);
        assert!(!tablette.en_attente());
        // Et tout ce que le pilote avait posé est oublié avec.
        assert_eq!(tablette.statut(), 0);
        assert_eq!(tablette.acceptees(), 0);
        assert_eq!(*tablette.files(), [File::neuve(), File::neuve()]);
        assert_eq!(tablette.lire(0x18, 2), u64::from(TAILLE_DE_FILE));
        // Une remise à zéro baisse aussi la ligne.
        let mut tablette = demarree(&mut ram, 8);
        tablette.pointer(0.1, 0.1, 0);
        tablette.livrer(&mut ram, None);
        assert!(tablette.interrompt());
        tablette.ecrire(0x14, 1, 0, &mut ram);
        assert!(!tablette.interrompt() && !tablette.reveil());
    }

    /// **Le pilote n'accepte que ce qui est offert**
    /// (`testTheDriverCannotAcceptWhatIsNotOffered`) : un bit inconnu écrit
    /// dans les fonctions du pilote ne reste pas.
    #[test]
    fn the_driver_cannot_accept_what_is_not_offered() {
        let mut ram = ram();
        let mut tablette = posee();
        tablette.ecrire(0x08, 4, 0, &mut ram);
        tablette.ecrire(0x0C, 4, 0xFFFF_FFFF, &mut ram);
        assert_eq!(tablette.acceptees(), 0, "rien d'offert dans les bits bas");
        tablette.ecrire(0x08, 4, 1, &mut ram);
        tablette.ecrire(0x0C, 4, 0xFFFF_FFFF, &mut ram);
        assert_eq!(tablette.acceptees(), 1 << 32);
        assert_eq!(tablette.lire(0x0C, 4), 1, "la moitié haute, relue");
        tablette.ecrire(0x08, 4, 0, &mut ram);
        assert_eq!(tablette.lire(0x0C, 4), 0, "la moitié basse");
        // Les fonctions offertes : le bit 32, et lui seul.
        tablette.ecrire(0x00, 4, 0, &mut ram);
        assert_eq!(tablette.lire(0x04, 4), 0);
        tablette.ecrire(0x00, 4, 1, &mut ram);
        assert_eq!(tablette.lire(0x04, 4), 1);
        tablette.ecrire(0x00, 4, 2, &mut ram);
        assert_eq!(tablette.lire(0x04, 4), 0);
        // Le pilote peut retirer ce qu'il avait accepté.
        tablette.ecrire(0x08, 4, 1, &mut ram);
        tablette.ecrire(0x0C, 4, 0, &mut ram);
        assert_eq!(tablette.acceptees(), 0);
    }

    // --------------------------------------- au-delà des cas du cœur Swift

    /// **La remise à zéro rend la tablette de la mise sous tension** — moins
    /// la configuration PCI, les deux sélecteurs de fonctions et l'heure de
    /// la machine —, champ par champ : un pilote qui recommence ne reçoit
    /// pas les gestes d'avant, ni le rythme qu'ils imposaient.
    #[test]
    fn a_reset_brings_back_the_tablet_of_power_on() {
        // Ce qu'une tablette neuve devient sous la même poignée de main, une
        // fois remise : la BAR, la commande, les sélecteurs, l'heure.
        let attendue = |horloge: Option<u64>| {
            let mut neuve = posee();
            neuve.ecrire(0x00, 4, 1, &mut SansRam);
            neuve.ecrire(0x08, 4, 1, &mut SansRam);
            neuve.horloge = horloge;
            neuve
        };
        // Un seul tampon : l'appui en est à son premier événement, la
        // tablette à court, les boutons rendus, la ligne levée ; puis un
        // sous-choix de configuration et la file un choisie.
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 1);
        assert!(tablette.pointer(0.1, 0.1, 1));
        tablette.livrer(&mut ram, Some(1_000));
        assert_eq!(rendus(&ram), 1);
        assert!(tablette.a_court && tablette.reste_du_paquet == 5);
        assert!(tablette.dernier_changeait && !tablette.acquitte);
        assert_eq!(tablette.boutons_rendus, 1);
        tablette.ecrire(0x2000, 2, 0x0311, &mut ram);
        tablette.ecrire(0x16, 2, 1, &mut ram);
        assert_eq!(
            (tablette.lire(0x2000, 2), tablette.lire(0x16, 2)),
            (0x0311, 1)
        );
        tablette.ecrire(0x14, 1, 0, &mut ram);
        assert_eq!(tablette, attendue(Some(1_000)));
        // Ce que le pilote relit aussitôt : ni choix, ni file choisie.
        assert_eq!((tablette.lire(0x2000, 2), tablette.lire(0x16, 2)), (0, 0));

        // **Ce que le pilote qui recommence voit**, ses anneaux refaits :
        // un appui, puis sa relâche, comme sur une tablette neuve.
        ram.0.fill(0);
        tablette.ecrire(0x14, 1, 1 | 2, &mut ram);
        tablette.ecrire(0x08, 4, 1, &mut ram);
        tablette.ecrire(0x0C, 4, 1, &mut ram);
        tablette.ecrire(0x14, 1, 1 | 2 | 8, &mut ram);
        tablette.ecrire(0x16, 2, 0, &mut ram);
        tablette.ecrire(0x18, 2, 8, &mut ram);
        tablette.ecrire(0x20, 8, DESCRIPTEURS, &mut ram);
        tablette.ecrire(0x28, 8, DISPONIBLES, &mut ram);
        tablette.ecrire(0x30, 8, SERVIES, &mut ram);
        tablette.ecrire(0x1C, 2, 1, &mut ram);
        tablette.ecrire(0x14, 1, 15, &mut ram);
        garnir(&mut ram, 8);
        poser(&mut ram, DISPONIBLES + 2, &16u16.to_le_bytes());
        assert!(tablette.pointer(0.2, 0.2, 1));
        // Plus « à court » : l'appui partira sans sonnette.
        assert!(tablette.reveil(), "un geste peut partir");
        assert!(tablette.pointer(0.2, 0.2, 0));
        tablette.livrer(&mut ram, Some(2_000));
        // L'appui part entier et tout de suite — ni retenu comme s'il
        // suivait l'appui d'avant, ni jugé « sans changement » d'après les
        // boutons d'avant, ni coupé par le reste du paquet d'avant — et la
        // relâche, elle, attend la lecture puis ses trente millisecondes.
        assert_eq!(
            evenements(&ram),
            [
                [3, 0, 6553],
                [3, 1, 6553],
                [1, 0x110, 1],
                [1, 0x111, 0],
                [1, 0x112, 0],
                [0, 0, 0]
            ]
        );
        assert_eq!(tablette.lire(0x1000, 1), 1);
        tablette.livrer(&mut ram, Some(3_000));
        tablette.livrer(&mut ram, Some(3_000 + TICS_DES_BOUTONS - 1));
        assert_eq!(rendus(&ram), 6, "la relâche est retenue");
        tablette.livrer(&mut ram, Some(3_000 + TICS_DES_BOUTONS));
        assert_eq!(rendus(&ram), 12);
        assert_eq!(evenement(&ram, 8), [1, 0x110, 0]);

        // Une relâche retenue, l'attente commencée : remise, elle n'attend
        // plus rien.
        let mut ram = self::ram();
        let mut tablette = demarree(&mut ram, 8);
        tablette.pointer(0.5, 0.5, 1);
        tablette.livrer(&mut ram, Some(1_000));
        tablette.lire(0x1000, 1);
        tablette.pointer(0.5, 0.5, 0);
        tablette.livrer(&mut ram, Some(2_000));
        assert_eq!(tablette.retenu_depuis, Some(2_000));
        tablette.ecrire(0x14, 1, 0, &mut ram);
        assert_eq!(tablette, attendue(Some(2_000)));

        // **La configuration PCI que le noyau a posée reste** : la ligne 11
        // qu'il a écrite en 0x3C, et la BAR qu'il est en train de mesurer
        // (0xFFFF_FFFF écrit en 0x10). Toutes les tablettes d'avant étaient
        // sur la ligne 10, celle de `nouvelle` : elles ne pouvaient pas voir
        // une remise qui la reprendrait de là.
        let mut ram = self::ram();
        let mut tablette = demarree(&mut ram, 8);
        tablette.ecrire_configuration(0x3C, 11);
        tablette.ecrire_configuration(0x10, 0xFFFF_FFFF);
        tablette.pointer(0.5, 0.5, 1);
        tablette.livrer(&mut ram, Some(1_000));
        tablette.ecrire(0x14, 1, 0, &mut ram);
        let mut la_meme = attendue(Some(1_000));
        la_meme.ecrire_configuration(0x3C, 11);
        la_meme.ecrire_configuration(0x10, 0xFFFF_FFFF);
        assert_eq!(tablette, la_meme);
        assert_eq!(tablette.configuration(0x3C), 11 | (1 << 8), "la ligne 11");
        assert_eq!(
            tablette.configuration(0x10),
            !((TAILLE_DE_LA_FENETRE - 1) as u32),
            "la BAR toujours en mesure"
        );
    }

    /// **Seul un statut nul remet la tablette à zéro** (`if status == 0 {
    /// reset() }` du Swift) : `FAILED` (0x80) seul, sans `ACKNOWLEDGE`, est
    /// gardé tel quel, et la tablette ne livre plus faute de `DRIVER_OK` ;
    /// mais ses files, ses fonctions acceptées et ce qui attend restent.
    #[test]
    fn a_failed_status_alone_is_not_a_reset() {
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 8);
        assert!(tablette.pointer(0.5, 0.5, 1));
        let files = *tablette.files();
        tablette.ecrire(0x14, 1, 0x80, &mut ram);
        assert_eq!(tablette.lire(0x14, 1), 0x80);
        assert!(!tablette.prete());
        assert_eq!(*tablette.files(), files);
        assert_eq!(tablette.acceptees(), 1 << 32);
        assert!(tablette.en_attente(), "le geste attend toujours");
        tablette.livrer(&mut ram, None);
        assert_eq!(rendus(&ram), 0, "rien ne part sans DRIVER_OK");
        // `DRIVER_OK` de retour : le geste d'avant part, rien n'a été oublié.
        tablette.ecrire(0x14, 1, 15, &mut ram);
        tablette.livrer(&mut ram, None);
        assert_eq!(rendus(&ram), 6);
        assert_eq!(evenement(&ram, 2), [1, 0x110, 1]);
    }

    /// **Une tête de chaîne hors de la file y est ramenée** (`% queue.size`
    /// du Swift) : un pilote qui offre la tête 11 dans une file de huit
    /// désigne le descripteur 3, pas le seizième octet après la table.
    #[test]
    fn a_head_beyond_the_queue_is_brought_back_into_it() {
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 0);
        for (place, tete) in [8u16 + 3, 16 + 5].into_iter().enumerate() {
            poser(
                &mut ram,
                DISPONIBLES + 4 + place as u64 * 2,
                &tete.to_le_bytes(),
            );
        }
        poser(&mut ram, DISPONIBLES + 2, &2u16.to_le_bytes());
        assert!(tablette.pointer(1.0, 0.0, 0));
        tablette.livrer(&mut ram, None);
        assert_eq!(rendus(&ram), 2);
        let rendues: Vec<_> = (0..2)
            .map(|k| {
                (
                    u32_a(&ram, SERVIES + 4 + k * 8),
                    u32_a(&ram, SERVIES + 8 + k * 8),
                )
            })
            .collect();
        assert_eq!(rendues, [(3, 8), (5, 8)], "les têtes 3 et 5, pleines");
        assert_eq!(u32_a(&ram, TAMPONS + 3 * 8 + 4), 32767, "ABS_X au bord");
        assert_eq!(u16_a(&ram, TAMPONS + 5 * 8 + 2), 1, "puis ABS_Y");
    }

    /// **Une RAM au-dessus de 4 Gio** : les 64 Kio d'une [`RamPlate`], vus à
    /// partir de [`HAUT`], et rien en dessous.
    struct RamHaute(RamPlate);
    const HAUT: u64 = 1 << 32;

    impl Ram for RamHaute {
        fn lire(&self, adresse: u64, vers: &mut [u8]) -> bool {
            adresse
                .checked_sub(HAUT)
                .is_some_and(|a| self.0.lire(a, vers))
        }

        fn ecrire(&mut self, adresse: u64, depuis: &[u8]) -> bool {
            adresse
                .checked_sub(HAUT)
                .is_some_and(|a| self.0.ecrire(a, depuis))
        }
    }

    /// **Des files au-dessus de 4 Gio**, posées en deux mots de 32 bits
    /// chacune (`vp_iowrite64_twopart`, le bas puis le haut) : la moitié
    /// haute de chaque adresse compte, et le toucher y arrive.
    #[test]
    fn queues_above_four_gibibytes_are_served() {
        let mut haute = RamHaute(ram());
        let mut tablette = posee();
        for (decalage, largeur, valeur) in [
            (0x14, 1, 0),
            (0x14, 1, 3),
            (0x08, 4, 1),
            (0x0C, 4, 1),
            (0x14, 1, 11),
            (0x16, 2, 0),
            (0x18, 2, 8),
            (0x20, 4, DESCRIPTEURS),
            (0x24, 4, HAUT >> 32),
            (0x28, 4, DISPONIBLES),
            (0x2C, 4, HAUT >> 32),
            (0x30, 4, SERVIES),
            (0x34, 4, HAUT >> 32),
            (0x1C, 2, 1),
            (0x14, 1, 15),
        ] {
            tablette.ecrire(decalage, largeur, valeur, &mut haute);
        }
        let file = tablette.files()[FILE_DES_EVENEMENTS];
        assert_eq!(
            (file.descripteurs, file.disponibles, file.servies),
            (HAUT + DESCRIPTEURS, HAUT + DISPONIBLES, HAUT + SERVIES)
        );
        garnir(&mut haute.0, 8);
        for rang in 0..8u64 {
            poser(
                &mut haute.0,
                DESCRIPTEURS + rang * 16,
                &(HAUT + TAMPONS + rang * 8).to_le_bytes(),
            );
        }
        assert!(tablette.pointer(0.5, 0.5, 1));
        tablette.livrer(&mut haute, None);
        assert_eq!(
            evenements(&haute.0),
            [
                [3, 0, 16384],
                [3, 1, 16384],
                [1, 0x110, 1],
                [1, 0x111, 0],
                [1, 0x112, 0],
                [0, 0, 0]
            ]
        );
        rien_apres_l_anneau(&haute.0);
    }

    /// **Les registres communs se relisent comme le pilote les a écrits**,
    /// file par file, à la largeur de l'accès ; une file qui n'existe pas ne
    /// se laisse ni lire ni poser.
    #[test]
    fn the_common_registers_read_back_per_queue() {
        let mut ram = ram();
        let mut tablette = posee();
        assert_eq!(tablette.lire(0x12, 2), 2, "deux files");
        assert_eq!(tablette.lire(0x10, 2), 0xFFFF, "pas de MSI-X");
        assert_eq!(tablette.lire(0x15, 1), 0, "la génération ne bouge pas");
        tablette.ecrire(0x16, 2, 1, &mut ram);
        assert_eq!(tablette.lire(0x16, 2), 1);
        assert_eq!(tablette.lire(0x1E, 2), 1, "la sonnette de la file un");
        // Les descripteurs en deux mots de 32 bits, le bas puis le haut,
        // comme `vp_iowrite64_twopart` : c'est ainsi que Linux pose une
        // table au-dessus de 4 Gio.
        tablette.ecrire(0x20, 4, 0x5566_7788, &mut ram);
        tablette.ecrire(0x24, 4, 0x1122_3344, &mut ram);
        tablette.ecrire(0x28, 4, 0xAAAA_BBBB, &mut ram);
        tablette.ecrire(0x2C, 4, 0xCCCC_DDDD, &mut ram);
        tablette.ecrire(0x34, 4, 0x0000_0001, &mut ram);
        tablette.ecrire(0x30, 4, 0x0000_2000, &mut ram);
        assert_eq!(tablette.lire(0x20, 8), 0x1122_3344_5566_7788);
        assert_eq!(tablette.lire(0x20, 4), 0x5566_7788);
        assert_eq!(tablette.lire(0x24, 4), 0x1122_3344);
        assert_eq!(tablette.lire(0x28, 8), 0xCCCC_DDDD_AAAA_BBBB);
        // Chaque moitié se relit seule aussi, comme `vp_ioread32`.
        assert_eq!(tablette.lire(0x28, 4), 0xAAAA_BBBB);
        assert_eq!(tablette.lire(0x2C, 4), 0xCCCC_DDDD);
        assert_eq!(tablette.lire(0x30, 8), 0x0000_0001_0000_2000);
        assert_eq!(tablette.lire(0x30, 4), 0x0000_2000);
        assert_eq!(tablette.lire(0x34, 4), 1);
        // `queue_enable` ne lit que son bit 0 (`value & 1 != 0` du Swift) :
        // 2 ne l'active pas, 3 si.
        assert_eq!(tablette.lire(0x1C, 2), 0);
        tablette.ecrire(0x1C, 2, 2, &mut ram);
        assert_eq!(tablette.lire(0x1C, 2), 0, "2 n'active pas la file");
        tablette.ecrire(0x1C, 2, 3, &mut ram);
        assert_eq!(tablette.lire(0x1C, 2), 1, "3 l'active");
        tablette.ecrire(0x1C, 2, 2, &mut ram);
        assert_eq!(tablette.lire(0x1C, 2), 0, "2 la désactive");
        tablette.ecrire(0x1C, 2, 1, &mut ram);
        assert_eq!(tablette.lire(0x1C, 2), 1);
        // La file zéro n'a rien reçu de tout cela.
        tablette.ecrire(0x16, 2, 0, &mut ram);
        assert_eq!(tablette.lire(0x1E, 2), 0);
        assert_eq!(
            (
                tablette.lire(0x20, 8),
                tablette.lire(0x28, 8),
                tablette.lire(0x1C, 2)
            ),
            (0, 0, 0)
        );
        assert_eq!(tablette.files()[1].descripteurs, 0x1122_3344_5566_7788);
        assert!(tablette.files()[1].active && !tablette.files()[0].active);
        // La taille : une puissance de deux, 64 au plus, jamais zéro.
        assert_eq!(tablette.lire(0x18, 2), 64);
        for (ecrite, gardee) in [(32, 32), (0, 32), (48, 32), (128, 32), (64, 64), (1, 1)] {
            tablette.ecrire(0x18, 2, ecrite, &mut ram);
            assert_eq!(tablette.lire(0x18, 2), gardee, "{ecrite} écrite");
        }
        assert_eq!(
            tablette.files()[1].taille,
            64,
            "celle de l'autre file reste"
        );
        // Une file qui n'existe pas : taille nulle, rien ne s'y pose.
        tablette.ecrire(0x16, 2, 2, &mut ram);
        assert_eq!(
            (
                tablette.lire(0x18, 2),
                tablette.lire(0x1C, 2),
                tablette.lire(0x1E, 2)
            ),
            (0, 0, 0)
        );
        // Chaque registre d'une file, écrit à zéro puis à un : la file un est
        // active et a ses descripteurs, la file zéro ni l'un ni l'autre, et
        // l'une comme l'autre verrait une écriture qui s'égarerait.
        let avant = *tablette.files();
        for (decalage, largeur) in [
            (0x18, 2),
            (0x1C, 2),
            (0x20, 8),
            (0x24, 4),
            (0x28, 4),
            (0x2C, 4),
            (0x30, 4),
            (0x34, 4),
        ] {
            for valeur in [0, 1] {
                tablette.ecrire(decalage, largeur, valeur, &mut ram);
                assert_eq!(*tablette.files(), avant, "{decalage:#x} à {valeur}");
            }
        }
        // Hors des registres, rien.
        assert_eq!(tablette.lire(0x38, 4), 0);
        assert_eq!(tablette.lire(0x1004, 4), 0);
        assert_eq!(tablette.lire(0x3000, 4), 0);
    }

    /// **Un tampon qui ne peut pas recevoir un événement est rendu vide**,
    /// et l'événement est perdu plutôt que la file bloquée : en lecture
    /// seule, ou trop court. Un tampon hors de la RAM est rendu aussi.
    #[test]
    fn a_buffer_that_cannot_take_an_event_is_returned_empty() {
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 8);
        poser(&mut ram, DESCRIPTEURS + 12, &0u16.to_le_bytes()); // le premier, en lecture seule
        poser(&mut ram, DESCRIPTEURS + 16 + 8, &7u32.to_le_bytes()); // le deuxième, trop court
        poser(&mut ram, DESCRIPTEURS + 32, &0xFFFF_0000u64.to_le_bytes()); // le troisième, hors RAM
        ram.0[TAMPONS as usize..TAMPONS as usize + 64].fill(0xEE);
        tablette.pointer(1.0, 0.5, 5);
        tablette.livrer(&mut ram, None);
        assert_eq!(rendus(&ram), 6);
        let longueurs: Vec<u32> = (0..6).map(|k| u32_a(&ram, SERVIES + 8 + k * 8)).collect();
        assert_eq!(longueurs, [0, 0, 8, 8, 8, 8]);
        assert_eq!(ram.0[TAMPONS as usize..TAMPONS as usize + 24], [0xEE; 24]);
        assert_eq!(evenement(&ram, 3), [1, 0x111, 0]);
        assert_eq!(evenement(&ram, 4), [1, 0x112, 1]);
        assert_eq!(evenement(&ram, 5), [0, 0, 0]);
        assert!(!tablette.en_attente() && tablette.interrompt());
    }

    /// **Une file que la RAM ne porte pas ne sert rien** : l'anneau des
    /// disponibles hors de la RAM, une file sans descripteurs, une file
    /// éteinte. Les événements attendent, et rien n'est écrit.
    #[test]
    fn a_queue_the_ram_does_not_hold_serves_nothing() {
        for casse in ["disponibles", "descripteurs", "eteinte"] {
            let mut ram = ram();
            let mut tablette = demarree(&mut ram, 8);
            match casse {
                "disponibles" => tablette.ecrire(0x28, 8, 0xFFFF_0000, &mut ram),
                "descripteurs" => tablette.ecrire(0x20, 8, 0, &mut ram),
                _ => tablette.ecrire(0x1C, 2, 0, &mut ram),
            }
            let avant = ram.0.clone();
            tablette.pointer(0.5, 0.5, 1);
            tablette.livrer(&mut ram, None);
            tablette.ecrire(0x3000, 2, 0, &mut ram);
            assert!(tablette.en_attente() && !tablette.interrompt(), "{casse}");
            assert!(!tablette.reveil(), "{casse} : au pilote de jouer");
            assert_eq!(ram.0, avant, "{casse} : la RAM n'a pas bougé");
        }
        // Avec `SansRam`, rien non plus, et rien ne casse.
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 8);
        tablette.pointer(0.5, 0.5, 1);
        tablette.livrer(&mut SansRam, Some(5));
        tablette.sonner(FILE_DES_EVENEMENTS, &mut SansRam);
        tablette.sonner(FILE_DE_L_ETAT, &mut SansRam);
        assert!(tablette.en_attente() && !tablette.interrompt());
        tablette.livrer(&mut ram, None);
        assert_eq!(rendus(&ram), 6, "la RAM revenue, le toucher part");
    }

    /// **Des tampons neufs rendent le réveil** : à court de tampons, la
    /// tablette n'a qu'à attendre le pilote, et `reveil` le dit ; la sonnette
    /// qui en apporte rend l'appui aussitôt, et, l'ISR lu, la relâche qui
    /// attend son heure tient de nouveau la machine éveillée — elle partira
    /// sans que l'invité agisse, un `hlt` ne doit pas dormir dessus.
    #[test]
    fn a_doorbell_with_new_buffers_wakes_the_machine_again() {
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 0);
        assert!(tablette.pointer(0.5, 0.5, 1));
        assert!(tablette.pointer(0.5, 0.5, 0));
        tablette.livrer(&mut ram, Some(1_000));
        assert_eq!(rendus(&ram), 0, "aucun tampon offert");
        assert!(!tablette.reveil(), "à court : au pilote de jouer");
        garnir(&mut ram, 8);
        // Huit tampons, puis les mêmes rendus de nouveau : seize offerts.
        poser(&mut ram, DISPONIBLES + 2, &16u16.to_le_bytes());
        tablette.ecrire(0x3000, 2, 0, &mut ram);
        assert_eq!(rendus(&ram), 6, "l'appui, dès la sonnette");
        assert_eq!(tablette.lire(0x1000, 1), 1, "l'ISR lu");
        assert!(!tablette.interrompt());
        assert!(tablette.reveil(), "la relâche attend son heure");
        tablette.livrer(&mut ram, Some(2_000));
        tablette.livrer(&mut ram, Some(2_000 + TICS_DES_BOUTONS));
        assert_eq!(rendus(&ram), 12, "et part à son heure");
        assert_eq!(evenement(&ram, 8), [1, 0x110, 0]);
        rien_apres_l_anneau(&ram);
    }

    /// **La carte de la page rend le toucher à l'heure qu'on lui donne**
    /// ([`Carte::livrer`], ce que l'export `carte_livrer` appelle) : sans la
    /// façade, la sonnette sert tout de suite, par la RAM passée à
    /// [`Carte::mem_ecrire`] ; l'appui part au premier `livrer`, la relâche
    /// trente millisecondes du 8254 après la lecture de l'ISR, pas une de
    /// moins.
    #[test]
    fn the_card_delivers_at_the_time_it_is_given() {
        let mut ram = ram();
        let mut carte = Carte::nouvelle();
        assert!(carte.brancher_ecran(1024, 768));
        carte.port_ecrire(0xCF8, 4, adresse(7, 0x04), &mut ram);
        carte.port_ecrire(0xCFC, 2, 0x0006, &mut ram);
        let base = BASE_DE_LA_TABLETTE;
        for (decalage, largeur, valeur) in [
            (0x14, 1, 0),
            (0x14, 1, 3),
            (0x08, 4, 1),
            (0x0C, 4, 1),
            (0x14, 1, 11),
            (0x16, 2, 0),
            (0x18, 2, 8),
            (0x20, 8, DESCRIPTEURS),
            (0x28, 8, DISPONIBLES),
            (0x30, 8, SERVIES),
            (0x1C, 2, 1),
            (0x14, 1, 15),
        ] {
            assert!(carte.mem_ecrire(base + decalage, largeur, valeur, &mut ram));
        }
        garnir(&mut ram, 8);
        // Les huit tampons offerts quatre fois de suite, à mesure.
        poser(&mut ram, DISPONIBLES + 2, &32u16.to_le_bytes());
        assert!(carte.toucher(0.5, 0.5, 1) && carte.toucher(0.5, 0.5, 0));
        assert!(carte.reveil());
        carte.livrer(1_000, &mut ram);
        assert_eq!(rendus(&ram), 6, "l'appui");
        assert_eq!(carte.lignes(), 1 << 10);
        assert_eq!(carte.mem_lire(base + 0x1000, 1), Some(1));
        carte.livrer(5_000, &mut ram);
        carte.livrer(5_000 + TICS_DES_BOUTONS - 1, &mut ram);
        assert_eq!(rendus(&ram), 6, "un tic avant l'heure");
        carte.livrer(5_000 + TICS_DES_BOUTONS, &mut ram);
        assert_eq!(rendus(&ram), 12, "la relâche");
        assert_eq!(evenement(&ram, 8), [1, 0x110, 0]);
        assert_eq!(carte.lignes(), 1 << 10);
        // Un déplacement après la relâche attend aussi : il suit un
        // changement de boutons.
        assert_eq!(carte.mem_lire(base + 0x1000, 1), Some(1));
        assert!(carte.toucher(0.1, 0.1, 0));
        carte.livrer(9_000_000, &mut ram);
        assert_eq!(rendus(&ram), 12);
        carte.livrer(9_000_000 + TICS_DES_BOUTONS, &mut ram);
        assert_eq!(rendus(&ram), 18);
        // Le suivant, non ; et la sonnette, sans façade, le sert pendant
        // l'écriture, par la RAM qu'on lui passe.
        assert!(carte.toucher(0.2, 0.2, 0));
        assert!(carte.mem_ecrire(base + 0x3000, 2, 0, &mut ram));
        assert_eq!(rendus(&ram), 24, "servi par la sonnette");
        assert_eq!(evenement(&ram, 18), [3, 0, 6553]);
        let avant = ram.0.clone();
        carte.livrer(9_000_001 + TICS_DES_BOUTONS, &mut ram);
        assert_eq!(
            ram.0, avant,
            "sans rien en attente, la RAM n'est pas touchée"
        );
    }

    /// **La file d'état** porte les voyants du clavier, qu'il n'y a pas :
    /// la sonnette de la file un rend ses tampons tels quels, sans rien y
    /// écrire, et ne livre aucun événement.
    #[test]
    fn the_status_queue_hands_its_buffers_back() {
        let mut ram = ram();
        let mut tablette = demarree(&mut ram, 0);
        const D: u64 = 0x8000;
        const A: u64 = 0x9000;
        const S: u64 = 0xA000;
        tablette.ecrire(0x16, 2, 1, &mut ram);
        tablette.ecrire(0x18, 2, 4, &mut ram);
        tablette.ecrire(0x20, 8, D, &mut ram);
        tablette.ecrire(0x28, 8, A, &mut ram);
        tablette.ecrire(0x30, 8, S, &mut ram);
        tablette.ecrire(0x1C, 2, 1, &mut ram);
        for rang in 0..4u64 {
            poser(&mut ram, D + rang * 16, &(0xB000 + rang * 8).to_le_bytes());
            poser(&mut ram, D + rang * 16 + 8, &8u32.to_le_bytes());
        }
        // Trois tampons offerts : les têtes 2, 0 et 3.
        for (place, tete) in [2u16, 0, 3].into_iter().enumerate() {
            poser(&mut ram, A + 4 + place as u64 * 2, &tete.to_le_bytes());
        }
        poser(&mut ram, A + 2, &3u16.to_le_bytes());
        tablette.pointer(0.5, 0.5, 0);
        assert_eq!(Tablette::sonnette(0x3004), Some(1));
        tablette.ecrire(0x3004, 2, 1, &mut ram);
        assert_eq!(u16_a(&ram, S + 2), 3, "les trois rendus");
        let rendus_ici: Vec<_> = (0..3)
            .map(|k| (u32_a(&ram, S + 4 + k * 8), u32_a(&ram, S + 8 + k * 8)))
            .collect();
        assert_eq!(rendus_ici, [(2, 0), (0, 0), (3, 0)], "dans l'ordre, vides");
        assert!(tablette.interrompt());
        assert_eq!(rendus(&ram), 0, "la file des événements n'a rien reçu");
        assert!(tablette.en_attente());
        assert_eq!(tablette.files()[1].prochaine_disponible, 3);
        // Les sonnettes : quatre octets chacune, deux en tout.
        assert_eq!(Tablette::sonnette(0x3000), Some(0));
        assert_eq!(Tablette::sonnette(0x3003), Some(0));
        assert_eq!(Tablette::sonnette(0x3007), Some(1));
        assert_eq!(Tablette::sonnette(0x3008), None);
        assert_eq!(Tablette::sonnette(0x2FFF), None);
    }

    /// **Ce qui attend est borné, et un paquet y entre entier ou pas du
    /// tout** : un `SYN` perdu collerait deux gestes. La molette est bornée
    /// à trente-deux crans, et zéro cran ne fait rien.
    #[test]
    fn what_waits_is_bounded_and_packets_stay_whole() {
        let mut tablette = Tablette::nouvelle(10);
        assert_eq!(LIMITE_EN_ATTENTE, 1024);
        // 170 touchers de six événements : 1 020. Le 171e ne tient plus.
        for rang in 0..170 {
            assert!(tablette.pointer(0.0, 0.0, 0), "le toucher {rang}");
        }
        assert!(
            !tablette.pointer(0.5, 0.5, 1),
            "il ne reste que quatre places"
        );
        assert_eq!(tablette.attendus().count(), 1020);
        // Deux crans (quatre événements) tiennent tout juste ; un de plus non.
        assert!(!tablette.defiler(3), "six événements pour quatre places");
        assert_eq!(tablette.attendus().count(), 1020);
        assert!(tablette.defiler(2));
        assert_eq!(tablette.attendus().count(), 1024);
        assert!(!tablette.defiler(1) && !tablette.pointer(0.0, 0.0, 0));
        let derniers: Vec<_> = tablette.attendus().skip(1020).copied().collect();
        assert_eq!(derniers[0].valeur, 1);
        assert_eq!(derniers[3].genre, EV_SYN, "la file finit sur un SYN");
        // La molette : zéro cran ne fait rien, un nombre démesuré est borné,
        // dans un sens comme dans l'autre.
        let mut tablette = Tablette::nouvelle(10);
        assert!(!tablette.defiler(0));
        assert!(!tablette.en_attente());
        assert!(tablette.defiler(i32::MAX));
        assert_eq!(tablette.attendus().count(), 2 * 32);
        assert!(tablette.defiler(i32::MIN));
        assert_eq!(tablette.attendus().count(), 4 * 32);
        assert!(tablette.defiler(-33));
        assert_eq!(tablette.attendus().count(), 6 * 32);
        let crans: Vec<_> = tablette
            .attendus()
            .filter(|e| e.genre == EV_REL)
            .map(|e| (e.code, e.valeur as i32))
            .collect();
        assert_eq!(crans.len(), 96);
        assert!(crans[..32].iter().all(|&c| c == (REL_WHEEL, 1)));
        assert!(crans[32..].iter().all(|&c| c == (REL_WHEEL, -1)));
        // Trente-deux tout juste, et un de moins.
        let mut tablette = Tablette::nouvelle(10);
        assert!(tablette.defiler(32) && tablette.defiler(-31));
        assert_eq!(tablette.attendus().count(), 2 * 63);
    }

    // ------------------------------------------------------- sur la machine

    /// La mémoire de la tablette allumée par le bus, comme le noyau.
    fn allumer(carte: &mut Carte) {
        carte.port_ecrire(0xCF8, 4, adresse(7, 0x04), &mut SansRam);
        assert!(carte.port_ecrire(0xCFC, 2, 0x0006, &mut SansRam));
    }

    /// **Un écran vient avec sa tablette** (`testTheScreenComesWithItsTablet`) :
    /// en 00:07.0 sur le bus, sa BAR0 déjà posée après les registres de la
    /// carte, ses registres joignables par la mémoire une fois allumée — et
    /// sans écran, pas de tablette.
    #[test]
    fn the_screen_comes_with_its_tablet() {
        let mut carte = Carte::nouvelle();
        assert!(carte.brancher_ecran(1024, 768));
        assert_eq!(EMPLACEMENT_DE_LA_TABLETTE, 7);
        assert_eq!(BASE_DE_LA_TABLETTE, 0xE101_0000);
        let cfg = |carte: &mut Carte, registre: u32| {
            carte.port_ecrire(0xCF8, 4, adresse(7, registre), &mut SansRam);
            carte.port_lire(0xCFC, 4, &mut SansRam).expect("le bus")
        };
        assert_eq!(cfg(&mut carte, 0x00), 0x1052_1AF4);
        assert_eq!(cfg(&mut carte, 0x10), 0xE101_0000);
        assert_eq!(cfg(&mut carte, 0x3C), 10 | (1 << 8));
        assert_eq!(cfg(&mut carte, 0x34), 0x40);
        assert_eq!(cfg(&mut carte, 0x40) & 0xFF, 0x09, "la première capacité");
        // Éteinte, sa mémoire n'est à personne.
        assert_eq!(carte.mem_lire(BASE_DE_LA_TABLETTE + 0x2002, 1), None);
        allumer(&mut carte);
        assert_eq!(cfg(&mut carte, 0x04), 0x0006 | (1 << 20));
        // Le nom, lu par la mémoire comme le pilote le lit.
        assert!(carte.mem_ecrire(BASE_DE_LA_TABLETTE + 0x2000, 1, 1, &mut SansRam));
        assert_eq!(
            carte.mem_lire(BASE_DE_LA_TABLETTE + 0x2002, 1),
            Some(NOM.len() as u64)
        );
        assert_eq!(
            carte.mem_lire(BASE_DE_LA_TABLETTE + 0x2008, 4),
            Some(0x7173_6977)
        );
        assert_eq!(
            carte.mem_lire(BASE_DE_LA_TABLETTE + 0x12, 2),
            Some(2),
            "deux files"
        );
        // La mesure et le déplacement de sa BAR, par le bus.
        carte.port_ecrire(0xCF8, 4, adresse(7, 0x10), &mut SansRam);
        carte.port_ecrire(0xCFC, 4, 0xFFFF_FFFF, &mut SansRam);
        assert_eq!(cfg(&mut carte, 0x10), 0xFFFF_C000);
        carte.port_ecrire(0xCFC, 4, 0xF200_0000, &mut SansRam);
        assert_eq!(carte.mem_lire(0xF200_0012, 2), Some(2), "elle suit");
        assert_eq!(carte.mem_lire(BASE_DE_LA_TABLETTE + 0x12, 2), None);
        // Les emplacements voisins sont vides, et la fonction un aussi.
        for ailleurs in [adresse(6, 0), adresse(8, 0), adresse(7, 0) | (1 << 8)] {
            carte.port_ecrire(0xCF8, 4, ailleurs, &mut SansRam);
            assert_eq!(carte.port_lire(0xCFC, 4, &mut SansRam), Some(0xFFFF_FFFF));
        }
        // Sans écran, pas de tablette.
        let mut sans = Carte::nouvelle();
        assert!(sans.tablette().is_none());
        sans.port_ecrire(0xCF8, 4, adresse(7, 0), &mut SansRam);
        assert_eq!(sans.port_lire(0xCFC, 4, &mut SansRam), Some(0xFFFF_FFFF));
    }

    /// Une carte avec écran, la tablette allumée et sa file des événements
    /// posée par la mémoire, comme le pilote : huit tampons.
    fn carte_prete(ram: &mut RamPlate) -> CartePc {
        let mut carte = CartePc::nouvelle();
        assert!(carte.brancher_ecran(1024, 768));
        assert!(carte.port_ecrire(0xCF8, 4, adresse(7, 0x04)));
        assert!(carte.port_ecrire(0xCFC, 2, 0x0006));
        prendre(&mut carte);
        garnir(ram, 8);
        carte
    }

    /// La poignée de main du pilote par la mémoire, de la remise à zéro à
    /// `DRIVER_OK`, la file des événements posée.
    fn prendre(carte: &mut CartePc) {
        let base = BASE_DE_LA_TABLETTE;
        for (decalage, largeur, valeur) in [
            (0x14, 1, 0),
            (0x14, 1, 3),
            (0x08, 4, 1),
            (0x0C, 4, 1),
            (0x14, 1, 11),
            (0x16, 2, 0),
            (0x18, 2, 8),
            (0x20, 8, DESCRIPTEURS),
            (0x28, 8, DISPONIBLES),
            (0x30, 8, SERVIES),
            (0x1C, 2, 1),
            (0x14, 1, 15),
        ] {
            assert!(
                carte.mem_ecrire(base + decalage, largeur, valeur),
                "{decalage:#x}"
            );
        }
    }

    /// **Un toucher ne passe par la tablette que si l'invité l'a prise**
    /// (`testATouchGoesThroughTheTabletOnlyOnceTheGuestTookIt`) : avant
    /// `DRIVER_OK`, `toucher` répond non et l'application garde la souris
    /// PS/2 ; après, le toucher attend son tampon.
    #[test]
    fn a_touch_goes_through_the_tablet_only_once_the_guest_took_it() {
        let mut carte = CartePc::nouvelle();
        assert!(!carte.toucher(0.5, 0.5, 1), "sans écran, pas de tablette");
        assert!(carte.brancher_ecran(1024, 768));
        assert!(!carte.toucher(0.5, 0.5, 1));
        assert!(!carte.tablette().unwrap().en_attente());
        assert!(carte.port_ecrire(0xCF8, 4, adresse(7, 0x04)));
        assert!(carte.port_ecrire(0xCFC, 2, 0x0006));
        let base = BASE_DE_LA_TABLETTE;
        assert!(carte.mem_ecrire(base + 0x16, 2, 0));
        assert!(carte.mem_ecrire(base + 0x1C, 2, 1));
        assert!(!carte.toucher(0.5, 0.5, 1), "la file active, pas DRIVER_OK");
        assert!(carte.mem_ecrire(base + 0x14, 1, 1 | 2 | 8 | 4));
        assert!(carte.tablette().unwrap().prete());
        assert!(carte.toucher(0.5, 0.5, 1));
        assert!(carte.tablette().unwrap().en_attente());
        // `DRIVER_OK` sans la file des événements : pas prise non plus.
        assert!(carte.mem_ecrire(base + 0x1C, 2, 0));
        assert!(!carte.toucher(0.5, 0.5, 1));
        assert_eq!(carte.tablette().unwrap().attendus().count(), 6);
    }

    /// **La molette passe par la tablette**, une fois prise, un paquet par
    /// cran ; zéro cran ne fait rien, et un nombre démesuré est borné
    /// (`testTheWheelGoesThroughTheTabletOnceTheGuestTookIt`).
    #[test]
    fn the_wheel_goes_through_the_tablet_once_the_guest_took_it() {
        let mut ram = ram();
        let mut carte = CartePc::nouvelle();
        assert!(carte.brancher_ecran(1024, 768));
        assert!(!carte.defiler(1), "la souris PS/2 n'a pas de molette");
        let mut carte = carte_prete(&mut ram);
        assert!(!carte.defiler(0));
        assert!(!carte.tablette().unwrap().en_attente());
        assert!(carte.defiler(-2));
        // Un paquet par cran, comme une vraie souris.
        let attendus: Vec<_> = carte.tablette().unwrap().attendus().copied().collect();
        assert_eq!(
            attendus.iter().map(|e| e.valeur).collect::<Vec<_>>(),
            [u32::MAX, 0, u32::MAX, 0],
            "deux crans vers le bas"
        );
        assert_eq!((attendus[0].genre, attendus[0].code), (EV_REL, REL_WHEEL));
        assert!(carte.defiler(i32::MAX));
        let tablette = carte.tablette().unwrap();
        assert_eq!(tablette.attendus().count(), 4 + 2 * 32, "borné");
        assert_eq!(
            tablette
                .attendus()
                .filter(|e| e.genre == EV_REL)
                .last()
                .map(|e| e.valeur),
            Some(1)
        );
    }

    /// **La façade rend le toucher à l'invité, à l'heure de la machine** :
    /// `toucher` ne touche pas à la RAM ; `servir` le pose dans les tampons
    /// du pilote et lève la ligne 10 — la deuxième de l'esclave — ; l'ISR lu
    /// la baisse ; et la relâche attend trente millisecondes de `battre`.
    #[test]
    fn the_facade_delivers_touches_at_the_machines_time() {
        let mut ram = ram();
        let mut carte = carte_prete(&mut ram);
        let isr = BASE_DE_LA_TABLETTE + 0x1000;
        assert_eq!(carte.tenues(), (1 << 1) | (1 << 10) | (1 << 12));
        assert!(!carte.reveil() && !carte.a_servir());
        assert_eq!(carte.servir(&mut ram), 0);
        assert_eq!(rendus(&ram), 0);

        carte.battre(1_000);
        assert!(carte.toucher(0.25, 0.75, 1)); // l'appui
        assert!(carte.toucher(0.25, 0.75, 0)); // la relâche
        assert!(carte.reveil(), "un toucher attend");
        assert_eq!(carte.lignes(), 0, "pas avant `servir`");
        assert_eq!(rendus(&ram), 0, "`toucher` n'a pas la RAM");
        assert_eq!(
            carte.servir(&mut ram),
            0,
            "un toucher n'est pas une requête"
        );
        assert_eq!(
            evenements(&ram),
            [
                [3, 0, 8192],
                [3, 1, 24575],
                [1, 0x110, 1],
                [1, 0x111, 0],
                [1, 0x112, 0],
                [0, 0, 0]
            ],
            "l'appui seul"
        );
        assert_eq!(carte.lignes(), 1 << 10, "la ligne 10");
        assert_eq!((carte.lignes() >> 8) as u8, 1 << 2, "deuxième de l'esclave");
        // Tant que l'invité n'a pas lu, la relâche ne suit pas.
        carte.battre(1_000 + 10 * TICS_DES_BOUTONS);
        carte.servir(&mut ram);
        assert_eq!(rendus(&ram), 6);
        assert_eq!(carte.mem_lire(isr, 1), Some(1), "`vp_interrupt`");
        assert_eq!(carte.lignes(), 0, "lu, la ligne retombe");
        assert!(carte.reveil(), "la relâche attend son heure");
        // Le pilote rend ses tampons et sonne : la sonnette est notée, pas
        // servie, et ne libère pas ce qui est retenu.
        garnir(&mut ram, 8);
        poser(&mut ram, DISPONIBLES + 2, &16u16.to_le_bytes());
        assert!(carte.mem_ecrire(BASE_DE_LA_TABLETTE + 0x3000, 2, 0));
        assert!(carte.a_servir(), "la sonnette attend `servir`");
        assert_eq!(rendus(&ram), 6);
        carte.battre(2_000_000);
        carte.servir(&mut ram);
        assert!(!carte.a_servir());
        assert_eq!(rendus(&ram), 6, "l'écart court depuis 2 000 000");
        carte.battre(2_000_000 + TICS_DES_BOUTONS - 1);
        carte.servir(&mut ram);
        assert_eq!(rendus(&ram), 6, "un tic avant l'heure");
        assert_eq!(carte.lignes(), 0);
        carte.battre(2_000_000 + TICS_DES_BOUTONS);
        carte.servir(&mut ram);
        assert_eq!(rendus(&ram), 12, "la relâche");
        assert_eq!(evenement(&ram, 8), [1, 0x110, 0]);
        assert_eq!(carte.lignes(), 1 << 10);
        assert!(carte.reveil(), "tant que la ligne est tenue");
        assert_eq!(carte.mem_lire(isr, 1), Some(1));
        assert!(!carte.reveil(), "plus rien");

        // La molette, par la façade : deux crans vers le haut. Le premier
        // paquet suit un changement de boutons : il attend son heure aussi.
        assert!(carte.defiler(2));
        carte.servir(&mut ram);
        carte.battre(3_000_000);
        carte.servir(&mut ram);
        carte.battre(3_000_000 + TICS_DES_BOUTONS);
        carte.servir(&mut ram);
        assert_eq!(rendus(&ram), 16);
        assert_eq!(evenement(&ram, 12), [2, 8, 1]);
        assert_eq!(evenement(&ram, 14), [2, 8, 1]);

        // **Le noyau déplace la ligne** : onze, puis une ligne de l'hôte, où
        // la tablette se tait plutôt que d'effacer ce que le 16550 y pose.
        assert!(carte.port_ecrire(0xCF8, 4, adresse(7, 0x3C)));
        assert!(carte.port_ecrire(0xCFC, 1, 11));
        assert_eq!(carte.lignes(), 1 << 11);
        assert_eq!(carte.tenues(), (1 << 1) | (1 << 11) | (1 << 12));
        assert!(carte.port_ecrire(0xCFC, 1, 4));
        assert_eq!(carte.lignes(), 0);
        assert_eq!(carte.tenues(), (1 << 1) | (1 << 12));
        assert!(carte.port_ecrire(0xCFC, 1, 10));
        assert_eq!(carte.lignes(), 1 << 10);

        // **La remise du pilote garde la ligne que le noyau a posée** : le
        // noyau écrit 11, puis le pilote remet le statut à zéro et
        // recommence ; son geste suivant arrive sur la ligne 11, pas sur la
        // 10 d'une tablette neuve.
        assert_eq!(carte.mem_lire(isr, 1), Some(1));
        assert!(carte.port_ecrire(0xCFC, 1, 11));
        assert!(carte.mem_ecrire(BASE_DE_LA_TABLETTE + 0x14, 1, 0));
        assert_eq!(carte.tablette().unwrap().statut(), 0, "remise");
        assert_eq!(carte.tenues(), (1 << 1) | (1 << 11) | (1 << 12));
        ram.0.fill(0);
        prendre(&mut carte);
        garnir(&mut ram, 8);
        assert!(carte.toucher(0.5, 0.5, 0));
        carte.servir(&mut ram);
        assert_eq!(rendus(&ram), 6);
        assert_eq!(carte.lignes(), 1 << 11, "la ligne 11, après la remise");
    }

    /// **Une sonnette de la file d'état passe la façade aussi**, et une
    /// sonnette notée pour une tablette remplacée n'est pas pour la neuve.
    #[test]
    fn the_facade_notes_each_doorbell_for_its_queue() {
        let mut ram = ram();
        let mut carte = carte_prete(&mut ram);
        let base = BASE_DE_LA_TABLETTE;
        // La file d'état, à part : deux tampons offerts.
        const D: u64 = 0x8000;
        const A: u64 = 0x9000;
        const S: u64 = 0xA000;
        for (decalage, largeur, valeur) in [
            (0x16, 2, 1),
            (0x20, 8, D),
            (0x28, 8, A),
            (0x30, 8, S),
            (0x1C, 2, 1),
        ] {
            assert!(carte.mem_ecrire(base + decalage, largeur, valeur));
        }
        poser(&mut ram, A + 4, &0u16.to_le_bytes());
        poser(&mut ram, A + 6, &1u16.to_le_bytes());
        poser(&mut ram, A + 2, &2u16.to_le_bytes());
        assert!(carte.toucher(0.5, 0.5, 0));
        assert!(
            carte.mem_ecrire(base + 0x3004, 2, 1),
            "la sonnette de la file un"
        );
        assert!(carte.a_servir() && carte.reveil());
        assert_eq!(u16_a(&ram, S + 2), 0, "notée, pas servie");
        carte.servir(&mut ram);
        assert_eq!(u16_a(&ram, S + 2), 2, "les deux tampons d'état rendus");
        assert_eq!(rendus(&ram), 6, "et le toucher, par la livraison du tour");
        assert!(!carte.a_servir());
        // Une largeur impossible n'est une sonnette pour personne.
        assert!(!carte.mem_ecrire(base + 0x3000, 0, 0));
        assert!(!carte.mem_ecrire(base + 0x3000, 9, 0));
        assert!(!carte.a_servir());
        // À cheval sur la fin de la fenêtre : pas à la tablette.
        assert!(!carte.mem_ecrire(base + 0x3FFE, 4, 0));
        // Notée, puis l'écran rebranché : la tablette neuve n'a rien à relire.
        assert!(carte.mem_ecrire(base + 0x3000, 2, 0));
        assert!(carte.a_servir());
        assert!(carte.brancher_ecran(800, 600));
        assert!(!carte.a_servir() && !carte.reveil());
        let avant = ram.0.clone();
        carte.servir(&mut ram);
        assert_eq!(ram.0, avant);
        assert_eq!(carte.tablette().unwrap().statut(), 0, "une tablette neuve");
    }
}
