//! **Le pont PCI** : la configuration par les ports `0xCF8` et `0xCFC`, un
//! pont hôte 440FX en 00:00.0, la carte graphique en 00:02.0, deux disques
//! virtio de forme ancienne en 00:03.0 et 00:04.0, la carte réseau virtio de
//! forme ancienne en 00:05.0, et la tablette virtio en 00:07.0. Porté depuis `X86PCIHost` du cœur Swift
//! (`Sources/WisqVM/X86PCI.swift`), registre pour registre.
//!
//! **Pourquoi un bus.** Le noyau d'Alpine refuse le transport MMIO de virtio
//! par la ligne de commande (son `virtio_mmio` est compilé sans
//! `CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES` : mesuré du côté Swift, pas supposé),
//! et sans bus ni table ACPI il ne reste rien où accrocher un disque. PCI
//! s'énumère tout seul, et un périphérique PCI porte un `modalias` qui fait
//! charger `virtio_blk` sans rien demander.
//!
//! **La forme ancienne, par ports, et c'est ce qui la rend possible ici.**
//! La page ne sait pas encore servir un accès mémoire hors RAM (il se replie
//! dans la RAM, `host.js`) : un disque de forme moderne, dont les registres
//! sont en mémoire, n'y répondrait pas. La forme ancienne vit entière dans
//! une fenêtre de ports, que `env.in` et `env.out` suffisent à servir.
//!
//! **La même carte que le cœur Swift** : mêmes identifiants (`1AF4:1001`,
//! sous-système `1AF4:0002`, pont `8086:1237`), même fenêtre de `0x40` ports,
//! même ligne 5 tant que le noyau n'en écrit pas une autre ; le second disque
//! en 00:04.0, ligne 6 (`X86PCIHost.secondSlot`, `secondInterruptLine`).
//! L'écran (00:02.0, [`ecran`](super::ecran)) et la tablette (00:07.0,
//! [`tablette`](super::tablette)) tiennent chacun leur espace de
//! configuration, et le bus le leur passe dans l'ordre du cœur Swift : le
//! pont, l'écran, la tablette, puis les disques et la carte réseau.
//!
//! **La carte réseau** ([`virtio_net`](super::virtio_net)) est en 00:05.0,
//! après les deux disques, sur la ligne 3 — celle du second port série d'un
//! PC, que cette machine n'a pas (`X86PCIHost.networkSlot`,
//! `networkInterruptLine`) : `1AF4:1000`, un contrôleur Ethernet, sous-système
//! `1AF4:0001`. Sa fenêtre de ports est du même modèle que celle d'un disque
//! ([`Emplacement`]), et un port que les deux fenêtres couvriraient va au
//! disque, comme `portWrite` du cœur Swift.
//!
//! **Pourquoi un second disque.** Une image d'installation *est* le disque de
//! sa machine : sa racine y vit. Installer une distribution demande un autre
//! disque à côté, vierge, sur lequel l'installateur écrit. Le noyau énumère
//! les emplacements dans l'ordre, et `virtio_blk` nomme les disques dans
//! l'ordre où il les trouve : trois devient `vda`, quatre `vdb`.
//!
//! **Deux emplacements du même modèle** ([`Emplacement`]), là où le cœur
//! Swift a deux hôtes du même type : chacun a sa commande, sa fenêtre et sa
//! ligne, et l'adresse est celle du bus.

use super::ecran::{Ecran, EMPLACEMENT_DE_L_ECRAN};
use super::tablette::{Tablette, EMPLACEMENT_DE_LA_TABLETTE};
use super::virtio_blk::VirtioBlk;
use super::virtio_net::VirtioNet;

pub const PORT_ADRESSE: u16 = 0xCF8;
pub const PORT_DONNEE: u16 = 0xCFC;
/// L'emplacement du pont hôte. **Sans lui rien n'existe** : Linux parcourt
/// les trente-deux emplacements et exige d'y trouver un pont hôte, une carte
/// VGA ou un fabricant Intel ou Compaq (`pci_sanity_check`), sinon « PCI:
/// System does not support PCI ». Celui de QEMU, un 440FX, qu'un noyau
/// connaît par cœur et à qui il ne demande rien.
pub const EMPLACEMENT_DU_PONT: u32 = 0;
/// L'emplacement du disque : `virtio_blk` nomme les disques dans l'ordre où il
/// les trouve, et trois devient `vda`.
pub const EMPLACEMENT_DU_DISQUE: u32 = 3;
/// **L'emplacement du second disque**, celui que le noyau nomme `vdb`
/// (`X86PCIHost.secondSlot`).
pub const EMPLACEMENT_DU_SECOND_DISQUE: u32 = 4;
/// La taille de la fenêtre de ports que chaque disque demande.
pub const TAILLE_DE_FENETRE: u32 = 0x40;
/// **La ligne du disque, sur le 8259 maître**, celle que le cœur Swift
/// annonce (`VirtioBlock.pc.interruptLine`) : zéro est l'horloge, quatre le
/// port série, cinq le disque.
pub const LIGNE_DU_DISQUE: u8 = 5;
/// **La ligne annoncée pour le second disque** (`X86PCIHost.secondInterruptLine`),
/// sur le maître elle aussi : six est celle de la disquette sur un PC, et
/// cette machine n'en a pas.
pub const LIGNE_DU_SECOND_DISQUE: u8 = 6;
/// **L'emplacement de la carte réseau**, après les deux disques
/// (`X86PCIHost.networkSlot`).
pub const EMPLACEMENT_DU_RESEAU: u32 = 5;
/// **Sa ligne** : trois, celle du second port série sur un PC, que cette
/// machine n'a pas ; sur le maître, pour la raison du second disque
/// (`X86PCIHost.networkInterruptLine`).
pub const LIGNE_DU_RESEAU: u8 = 3;

/// **Lequel des deux disques.** Le premier est celui de la machine (`vda`,
/// l'image qu'on démarre) ; le second celui qu'on lui ajoute (`vdb`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Disque {
    Premier,
    Second,
}

impl Disque {
    /// Les deux, dans l'ordre où le noyau les trouve.
    pub const TOUS: [Disque; 2] = [Disque::Premier, Disque::Second];

    /// Son emplacement sur le bus zéro.
    pub const fn emplacement(self) -> u32 {
        match self {
            Disque::Premier => EMPLACEMENT_DU_DISQUE,
            Disque::Second => EMPLACEMENT_DU_SECOND_DISQUE,
        }
    }

    /// La ligne qu'il annonce tant que le noyau n'en écrit pas une autre.
    pub const fn ligne(self) -> u8 {
        match self {
            Disque::Premier => LIGNE_DU_DISQUE,
            Disque::Second => LIGNE_DU_SECOND_DISQUE,
        }
    }

    /// Son rang dans un tableau de deux.
    pub const fn rang(self) -> usize {
        match self {
            Disque::Premier => 0,
            Disque::Second => 1,
        }
    }
}

/// **Ce qu'une fonction virtio de forme ancienne dit d'elle au bus** : les
/// trois registres qui la distinguent d'une autre. Tout le reste de son
/// espace de configuration — la commande, la fenêtre de ports, sa mesure, la
/// ligne — est le même pour toutes, et c'est [`Emplacement`] qui le tient.
pub trait Fonction {
    /// Le registre `0x00` : le modèle en haut, le fabricant (`1AF4`) en bas.
    const IDENTIFIANT: u32;
    /// Le registre `0x08` : la classe, la sous-classe, l'interface et la
    /// révision (zéro : la forme ancienne).
    const CLASSE: u32;
    /// Le registre `0x2C` : le sous-système. C'est de là que vient le
    /// `modalias` qui fait charger le pilote.
    const SOUS_SYSTEME: u32;
}

/// Un disque : virtio-blk en version ancienne (`0x1001`), du stockage de
/// masse, un bloc virtio (`X86PCIHost.configuration`).
impl Fonction for VirtioBlk {
    const IDENTIFIANT: u32 = 0x1001_1AF4;
    const CLASSE: u32 = 0x0100_0000;
    const SOUS_SYSTEME: u32 = 0x0002_1AF4;
}

/// La carte réseau : virtio-net en version ancienne (`0x1000`), un
/// contrôleur Ethernet, une carte réseau virtio (`X86PCIHost.configuration`,
/// `isNetwork`).
impl Fonction for VirtioNet {
    const IDENTIFIANT: u32 = 0x1000_1AF4;
    const CLASSE: u32 = 0x0200_0000;
    const SOUS_SYSTEME: u32 = 0x0001_1AF4;
}

/// **Un emplacement d'une fonction virtio de forme ancienne** — un disque, ou
/// la carte réseau : ce que le noyau y a réglé, et le périphérique lui-même
/// s'il y en a un. Le cœur Swift a un `X86PCIHost` par emplacement, du même
/// type pour les trois ; ici, un `Emplacement` du même modèle, que le
/// périphérique distingue ([`Fonction`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Emplacement<P = VirtioBlk> {
    /// Ce que le noyau a activé : bit 0 les ports, bit 2 la maîtrise du bus.
    pub commande: u16,
    /// Où le noyau a placé la fenêtre de ports du périphérique (la BAR0).
    pub fenetre: u32,
    /// La ligne d'interruption, telle que le noyau la lit **et l'écrit** :
    /// c'est elle qui décide où le périphérique frappe.
    pub ligne: u8,
    /// Vrai entre l'écriture de tous les uns dans la BAR0 et l'écriture qui
    /// suit : c'est ainsi qu'un noyau demande la **taille** de la fenêtre.
    mesure: bool,
    /// Le périphérique, ou rien. Sans lui l'emplacement est vide, ce qui est
    /// une réponse honnête : le noyau énumère, ne trouve rien, et continue.
    pub peripherique: Option<P>,
}

impl<P: Fonction> Emplacement<P> {
    const fn nouveau(ligne: u8) -> Self {
        Self {
            commande: 0,
            fenetre: 0,
            ligne,
            mesure: false,
            peripherique: None,
        }
    }

    /// Les trente-deux bits du registre `registre` de ce périphérique.
    fn configuration(&self, registre: u32) -> u32 {
        match registre {
            // virtio, en version ancienne : l'identifiant du périphérique.
            0x00 => P::IDENTIFIANT,
            0x04 => u32::from(self.commande), // aucun bit d'état à annoncer
            // Sa classe, révision zéro : la forme ancienne.
            0x08 => P::CLASSE,
            0x10 => {
                // Pendant la mesure, le masque : les bits que le noyau ne peut
                // pas changer disent la taille. Le bit 0 dit « des ports ».
                if self.mesure {
                    !(TAILLE_DE_FENETRE - 1) | 1
                } else {
                    self.fenetre | 1
                }
            }
            0x2C => P::SOUS_SYSTEME,
            // La ligne, puis la broche A.
            0x3C => u32::from(self.ligne) | (1 << 8),
            _ => 0,
        }
    }

    fn ecrire_configuration(&mut self, registre: u32, valeur: u32, largeur: u8, octet: u32) {
        match registre {
            0x04 => self.commande = valeur as u16,
            0x10 => {
                if valeur == 0xFFFF_FFFF {
                    self.mesure = true;
                } else {
                    self.mesure = false;
                    // Les bits bas ne sont pas au noyau : ils disent le type et
                    // l'alignement, et les garder placerait la fenêtre de
                    // travers.
                    self.fenetre = valeur & !(TAILLE_DE_FENETRE - 1);
                }
            }
            0x3C if (largeur == 1 && octet == 0) || largeur >= 2 => self.ligne = valeur as u8,
            _ => {}
        }
    }

    /// Vrai quand les ports du périphérique sont placés et activés.
    pub fn fenetre_ouverte(&self) -> bool {
        self.peripherique.is_some() && self.fenetre != 0 && self.commande & 0x01 != 0
    }

    /// **Le décalage d'un port dans la fenêtre de ce périphérique**, ou rien. Une
    /// fenêtre placée mais pas activée ne répond pas : un périphérique qui
    /// répondrait avant volerait des ports à un autre.
    pub fn dans_la_fenetre(&self, port: u16) -> Option<u16> {
        let port = u32::from(port);
        (self.fenetre_ouverte() && port >= self.fenetre && port - self.fenetre < TAILLE_DE_FENETRE)
            .then(|| (port - self.fenetre) as u16)
    }
}

/// **Le bus** : l'adresse choisie, les deux emplacements de disque, l'écran
/// et sa tablette, et la carte réseau.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pci {
    /// Ce que le noyau a écrit dans le port d'adresse.
    adresse: u32,
    /// Le disque de la machine, en 00:03.0.
    pub premier: Emplacement,
    /// Le second disque, en 00:04.0.
    pub second: Emplacement,
    /// La carte graphique, en 00:02.0, ou rien : une machine en console
    /// série n'a pas d'écran, et l'emplacement est vide.
    pub ecran: Option<Ecran>,
    /// La tablette, en 00:07.0, ou rien. Un écran vient avec la sienne.
    pub tablette: Option<Tablette>,
    /// La carte réseau, en 00:05.0.
    pub reseau: Emplacement<VirtioNet>,
}

impl Default for Pci {
    fn default() -> Self {
        Self::nouveau()
    }
}

/// L'adresse de configuration, décodée.
struct Choix {
    active: bool,
    bus: u32,
    emplacement: u32,
    fonction: u32,
    registre: u32,
}

impl Pci {
    /// Un bus vide. `const` pour tenir dans la `static` de la porte.
    pub const fn nouveau() -> Self {
        Self {
            adresse: 0,
            premier: Emplacement::nouveau(Disque::Premier.ligne()),
            second: Emplacement::nouveau(Disque::Second.ligne()),
            ecran: None,
            tablette: None,
            reseau: Emplacement::nouveau(LIGNE_DU_RESEAU),
        }
    }

    /// L'emplacement d'un des deux disques.
    pub fn emplacement(&self, quel: Disque) -> &Emplacement {
        match quel {
            Disque::Premier => &self.premier,
            Disque::Second => &self.second,
        }
    }

    pub fn emplacement_mut(&mut self, quel: Disque) -> &mut Emplacement {
        match quel {
            Disque::Premier => &mut self.premier,
            Disque::Second => &mut self.second,
        }
    }

    /// Le dernier mot écrit au port d'adresse, tel que le noyau le relit.
    pub fn adresse(&self) -> u32 {
        self.adresse
    }

    /// **Le port d'adresse.** L'adresse est celle du bus, pas d'un
    /// emplacement : elle est gardée telle quelle, bit d'activation compris.
    pub fn ecrire_adresse(&mut self, valeur: u32) {
        self.adresse = valeur;
    }

    fn choix(&self) -> Choix {
        let a = self.adresse;
        Choix {
            active: a & 0x8000_0000 != 0,
            bus: (a >> 16) & 0xFF,
            emplacement: (a >> 11) & 0x1F,
            fonction: (a >> 8) & 0x07,
            registre: a & 0xFC,
        }
    }

    fn vise(&self, emplacement: u32) -> bool {
        let c = self.choix();
        c.active && c.bus == 0 && c.emplacement == emplacement && c.fonction == 0
    }

    /// **Le disque que l'adresse désigne**, s'il est branché. Un emplacement
    /// sans disque n'est à personne.
    fn disque_vise(&self) -> Option<Disque> {
        Disque::TOUS.into_iter().find(|&quel| {
            self.emplacement(quel).peripherique.is_some() && self.vise(quel.emplacement())
        })
    }

    /// **L'adresse désigne la carte réseau**, et elle est branchée.
    fn reseau_vise(&self) -> bool {
        self.reseau.peripherique.is_some() && self.vise(EMPLACEMENT_DU_RESEAU)
    }

    /// **Les trente-deux bits du registre choisi.**
    ///
    /// Un emplacement vide rend **tous les uns**, et c'est ce qui dit au noyau
    /// qu'il n'y a personne : des zéros lui feraient croire à un périphérique
    /// de fabricant zéro.
    pub fn configuration(&self) -> u32 {
        let registre = self.choix().registre;
        if self.vise(EMPLACEMENT_DU_PONT) {
            // Le pont : quatre registres, ni fenêtre ni interruption. Il est
            // là pour être reconnu. **Annoncé une seule fois**, quel que soit
            // le nombre de disques.
            return match registre {
                0x00 => 0x1237_8086, // Intel 440FX, comme chez QEMU
                0x04 => 0x0000_0006, // mémoire et maîtrise du bus
                0x08 => 0x0600_0002, // pont hôte, révision deux
                _ => 0,              // en-tête de type zéro, et le reste
            };
        }
        // L'écran, puis la tablette, avant les disques : l'ordre du cœur
        // Swift (`X86PCIHost.configuration`).
        if let (Some(ecran), true) = (&self.ecran, self.vise(EMPLACEMENT_DE_L_ECRAN)) {
            return ecran.configuration(registre);
        }
        if let (Some(tablette), true) = (&self.tablette, self.vise(EMPLACEMENT_DE_LA_TABLETTE)) {
            return tablette.configuration(registre);
        }
        if let Some(quel) = self.disque_vise() {
            return self.emplacement(quel).configuration(registre);
        }
        if self.reseau_vise() {
            return self.reseau.configuration(registre);
        }
        0xFFFF_FFFF
    }

    /// **Écrire le registre choisi**, déjà recomposé sur trente-deux bits.
    /// `largeur` et `octet` disent ce que l'invité a vraiment écrit : la ligne
    /// d'interruption ne change que si son octet est visé.
    ///
    /// L'écran et la tablette reçoivent le mot entier, sans la largeur : une
    /// écriture partielle a déjà relu le registre et remplacé ses octets
    /// ([`Pci::ecrire_donnee`]), comme du côté Swift.
    pub fn ecrire_configuration(&mut self, valeur: u32, largeur: u8, octet: u32) {
        let registre = self.choix().registre;
        if self.vise(EMPLACEMENT_DE_L_ECRAN) {
            if let Some(ecran) = self.ecran.as_mut() {
                ecran.ecrire_configuration(registre, valeur);
                return;
            }
        }
        if self.vise(EMPLACEMENT_DE_LA_TABLETTE) {
            if let Some(tablette) = self.tablette.as_mut() {
                tablette.ecrire_configuration(registre, valeur);
                return;
            }
        }
        if let Some(quel) = self.disque_vise() {
            self.emplacement_mut(quel)
                .ecrire_configuration(registre, valeur, largeur, octet);
        } else if self.reseau_vise() {
            self.reseau
                .ecrire_configuration(registre, valeur, largeur, octet);
        }
    }

    /// **Lire le port de donnée** `0xCFC + n`, de `largeur` octets : le mot
    /// du registre choisi, décalé de `n` octets.
    pub fn lire_donnee(&self, dedans: u32, largeur: u8) -> u32 {
        let mot = u64::from(self.configuration()) >> (8 * dedans);
        (mot & masque(largeur)) as u32
    }

    /// **Écrire le port de donnée** `0xCFC + n`. Un mot entier passe tel
    /// quel ; une écriture partielle relit le registre, remplace les octets
    /// visés et réécrit — le noyau écrit la ligne d'interruption ainsi, d'un
    /// seul octet.
    pub fn ecrire_donnee(&mut self, dedans: u32, largeur: u8, valeur: u32) {
        if largeur == 4 && dedans == 0 {
            self.ecrire_configuration(valeur, 4, 0);
            return;
        }
        let mut mot = self.configuration();
        for rang in 0..u32::from(largeur) {
            let decalage = 8 * (dedans + rang);
            if decalage >= 32 {
                break;
            }
            mot &= !(0xFF << decalage);
            mot |= ((valeur >> (8 * rang)) & 0xFF) << decalage;
        }
        self.ecrire_configuration(mot, largeur, dedans);
    }

    /// **Le disque dont la fenêtre contient ce port, et le décalage dedans** —
    /// le premier d'abord, puis le second, comme `device(atPort:)` du cœur
    /// Swift : deux fenêtres qu'un noyau poserait l'une sur l'autre ne
    /// donnent jamais un port aux deux.
    pub fn au_port(&self, port: u16) -> Option<(Disque, u16)> {
        Disque::TOUS.into_iter().find_map(|quel| {
            self.emplacement(quel)
                .dans_la_fenetre(port)
                .map(|decalage| (quel, decalage))
        })
    }

    /// **Le décalage d'un port dans la fenêtre de la carte réseau**, s'il
    /// n'est d'aucun disque : la fenêtre d'un disque passe devant, comme
    /// `portWrite` et `portRead` du cœur Swift essaient `device(atPort:)`
    /// avant `networkDevice(atPort:)`.
    pub fn reseau_au_port(&self, port: u16) -> Option<u16> {
        if self.au_port(port).is_some() {
            return None;
        }
        self.reseau.dans_la_fenetre(port)
    }
}

/// Les bits d'un accès de `largeur` octets.
pub(crate) fn masque(largeur: u8) -> u64 {
    match largeur {
        1 => 0xFF,
        2 => 0xFFFF,
        _ => 0xFFFF_FFFF,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    //! **Le bus PCI, conduit comme le noyau le conduit** : les douze cas de
    //! `Tests/WisqVMTests/X86PCITests.swift`, portés un pour un. Sans réponse
    //! aux ports `0xCF8`/`0xCFC`, le noyau conclut « PCI: Fatal: No config
    //! space access function found » et aucun disque n'existera jamais. Avec,
    //! il énumère : il demande le fabricant de chaque emplacement, mesure la
    //! fenêtre que le disque réclame, la place, l'active, et lit la ligne.
    //!
    //! Les trois cas Swift « par les instructions » font exécuter des `out` et
    //! des `in` à un vrai processeur. Ici il n'y a pas de processeur : ils
    //! passent par [`Carte::port_ecrire`] et [`Carte::port_lire`], avec la
    //! largeur que l'instruction donne — c'est exactement ce que `env.out` et
    //! `env.in` recevront de l'émetteur.
    use super::super::virtio_blk::{self, VirtioBlk};
    use super::super::{Carte, RamPlate, SansRam};
    use super::*;

    pub(crate) fn adresse(emplacement: u32, registre: u32) -> u32 {
        0x8000_0000 | (emplacement << 11) | registre
    }

    /// Le bus du cœur Swift dans ses tests : un disque de huit secteurs.
    fn bus() -> Pci {
        let mut pci = Pci::nouveau();
        pci.premier.peripherique = Some(VirtioBlk::nouveau(8));
        pci
    }

    fn carte() -> Carte {
        let mut carte = Carte::nouvelle();
        carte.brancher_disque(8);
        carte
    }

    /// L'emplacement qu'on occupe se présente ; les autres rendent tous les
    /// uns. Sans le bit d'activation, rien.
    #[test]
    fn only_our_slot_answers() {
        let mut pci = bus();
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0));
        assert_eq!(pci.configuration(), 0x1001_1AF4, "virtio, forme ancienne");
        pci.ecrire_adresse(adresse(4, 0));
        assert_eq!(pci.configuration(), 0xFFFF_FFFF);
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0) & !0x8000_0000);
        assert_eq!(pci.configuration(), 0xFFFF_FFFF, "sans activation, rien");
        // Une fonction ou un bus de plus ne sont pas le disque non plus.
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0) | (1 << 8));
        assert_eq!(pci.configuration(), 0xFFFF_FFFF, "la fonction un");
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0) | (1 << 16));
        assert_eq!(pci.configuration(), 0xFFFF_FFFF, "le bus un");
    }

    /// **Le pont hôte, sans lequel le bus n'existe pas** (`pci_sanity_check`).
    #[test]
    fn a_host_bridge_answers_at_slot_zero() {
        let mut pci = bus();
        pci.ecrire_adresse(adresse(0, 0));
        assert_eq!(pci.configuration() & 0xFFFF, 0x8086, "un fabricant connu");
        assert_eq!(pci.configuration(), 0x1237_8086, "un 440FX");
        pci.ecrire_adresse(adresse(0, 0x08));
        assert_eq!(pci.configuration() >> 16, 0x0600, "la classe pont hôte");
        pci.ecrire_adresse(adresse(0, 0x04));
        assert_eq!(pci.configuration(), 6);
        // Le pont ne se laisse pas écrire : il n'a rien à régler.
        pci.ecrire_configuration(0, 4, 0);
        assert_eq!(pci.configuration(), 6);
        pci.ecrire_adresse(adresse(0, 0x10));
        assert_eq!(pci.configuration(), 0, "ni fenêtre");
    }

    /// Le pont répond même sans disque : c'est le bus qui existe.
    #[test]
    fn the_bridge_is_there_even_without_a_disk() {
        let mut pci = Pci::nouveau();
        pci.ecrire_adresse(adresse(0, 0));
        assert_eq!(pci.configuration() & 0xFFFF, 0x8086);
    }

    /// Un bus sans disque est un bus vide, et le dit.
    #[test]
    fn an_empty_bus_is_honest() {
        let mut pci = Pci::nouveau();
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0));
        assert_eq!(pci.configuration(), 0xFFFF_FFFF, "l'emplacement, vide");
        pci.ecrire_adresse(adresse(7, 0));
        assert_eq!(pci.configuration(), 0xFFFF_FFFF, "et tous les autres");
        // Sans disque, les écritures ne vont nulle part, et aucune fenêtre ne
        // s'ouvre.
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0x10));
        pci.ecrire_configuration(0xC000, 4, 0);
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0x04));
        pci.ecrire_configuration(1, 4, 0);
        assert_eq!((pci.premier.fenetre, pci.premier.commande), (0, 0));
        assert_eq!(pci.premier.dans_la_fenetre(0xC000), None);
    }

    /// La classe et le sous-système : c'est de là que vient le `modalias`.
    #[test]
    fn it_calls_itself_a_disk() {
        let mut pci = bus();
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0x08));
        assert_eq!(pci.configuration() >> 24, 0x01, "stockage de masse");
        assert_eq!(pci.configuration() & 0xFF, 0x00, "révision zéro");
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0x2C));
        assert_eq!(pci.configuration(), 0x0002_1AF4, "un bloc virtio");
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0x0C));
        assert_eq!(pci.configuration(), 0, "en-tête de type zéro");
    }

    /// **La mesure de la fenêtre** : tous les uns écrits, le masque relu.
    #[test]
    fn the_window_size_is_measured_the_way_firmware_expects() {
        let mut pci = bus();
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0x10));
        pci.ecrire_configuration(0xFFFF_FFFF, 4, 0);
        assert_eq!(
            pci.configuration(),
            !(TAILLE_DE_FENETRE - 1) | 1,
            "le masque, avec le bit des ports"
        );
        assert_eq!(pci.configuration(), 0xFFFF_FFC1);
        pci.ecrire_configuration(0xC000, 4, 0);
        assert_eq!(pci.configuration(), 0xC000 | 1, "puis la fenêtre placée");
        // Les bits bas écrits ne sont pas gardés.
        pci.ecrire_configuration(0xC03F, 4, 0);
        assert_eq!(pci.configuration(), 0xC001);
    }

    /// Placée mais pas activée, la fenêtre ne répond pas ; activée, ses
    /// soixante-quatre ports, et pas un de plus.
    #[test]
    fn the_window_opens_only_when_enabled() {
        let mut pci = bus();
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0x10));
        pci.ecrire_configuration(0xC000, 4, 0);
        assert_eq!(
            pci.premier.dans_la_fenetre(0xC000),
            None,
            "placée, pas ouverte"
        );
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0x04));
        pci.ecrire_configuration(0x0005, 4, 0); // ports + maîtrise du bus
        assert_eq!(pci.premier.dans_la_fenetre(0xC000), Some(0));
        assert_eq!(pci.premier.dans_la_fenetre(0xC012), Some(0x12));
        assert_eq!(pci.premier.dans_la_fenetre(0xC03F), Some(0x3F));
        assert_eq!(
            pci.premier.dans_la_fenetre(0xC040),
            None,
            "pas un octet au-delà"
        );
        assert_eq!(pci.premier.dans_la_fenetre(0xBFFF), None, "ni en deçà");
        // La maîtrise seule (bit 2) n'ouvre pas les ports.
        pci.ecrire_configuration(0x0004, 4, 0);
        assert_eq!(pci.premier.dans_la_fenetre(0xC000), None);
    }

    /// La ligne est **écrite** par le noyau, d'un octet, et relue.
    #[test]
    fn the_interrupt_line_is_what_the_kernel_wrote() {
        let mut pci = bus();
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0x3C));
        assert_eq!(pci.configuration() >> 8 & 0xFF, 1, "broche A");
        assert_eq!(pci.configuration() & 0xFF, 5, "la ligne cinq au départ");
        pci.ecrire_configuration(0x0000_010B, 1, 0);
        assert_eq!(pci.premier.ligne, 11);
        assert_eq!(pci.configuration() & 0xFF, 11);
        // L'octet de la broche, écrit seul, ne touche pas à la ligne.
        pci.ecrire_configuration(0x0000_0207, 1, 1);
        assert_eq!(pci.premier.ligne, 11);
        // Par le port de donnée, d'un octet, comme Linux : `0xCFC`.
        pci.ecrire_donnee(0, 1, 0x09);
        assert_eq!(pci.premier.ligne, 9);
        assert_eq!(pci.lire_donnee(1, 1), 1, "la broche n'a pas bougé");
    }

    /// **Le noyau trouve le disque par ses deux ports** : `out` de quatre
    /// octets à `0xCF8`, `in` de quatre à `0xCFC`. Et chaque octet du port de
    /// donnée se lit à son rang, comme `inb(0xCFE)` le demande.
    #[test]
    fn the_kernel_finds_the_device_through_the_ports() {
        let mut carte = carte();
        assert!(carte.port_ecrire(0xCF8, 4, 0x8000_1800, &mut SansRam));
        assert_eq!(carte.port_lire(0xCFC, 4, &mut SansRam), Some(0x1001_1AF4));
        assert_eq!(carte.port_lire(0xCF8, 4, &mut SansRam), Some(0x8000_1800));
        assert_eq!(carte.port_lire(0xCFE, 2, &mut SansRam), Some(0x1001));
        assert_eq!(carte.port_lire(0xCFD, 1, &mut SansRam), Some(0x1A));
        assert_eq!(carte.port_lire(0xCF8, 1, &mut SansRam), Some(0x00));
        // Un emplacement vide, par les ports : tous les uns, à la largeur
        // demandée.
        carte.port_ecrire(0xCF8, 4, 0x8000_3800, &mut SansRam);
        assert_eq!(carte.port_lire(0xCFC, 2, &mut SansRam), Some(0xFFFF));
        // Un `outb` à `0xCF8` n'écrit qu'un octet : l'adresse devient `0x80`,
        // sans bit d'activation, comme l'`out` du cœur Swift la laisse.
        carte.port_ecrire(0xCF8, 1, 0x8000_1880, &mut SansRam);
        assert_eq!(carte.port_lire(0xCF8, 4, &mut SansRam), Some(0x80));
        assert_eq!(carte.port_lire(0xCFC, 4, &mut SansRam), Some(0xFFFF_FFFF));
    }

    /// Fenêtre placée à `0xC000` et ouverte, par les ports comme le noyau.
    fn ouverte(commande: u32) -> Carte {
        let mut carte = carte();
        carte.port_ecrire(0xCF8, 4, adresse(3, 0x10), &mut SansRam);
        carte.port_ecrire(0xCFC, 4, 0xC000, &mut SansRam);
        carte.port_ecrire(0xCF8, 4, adresse(3, 0x04), &mut SansRam);
        carte.port_ecrire(0xCFC, 4, commande, &mut SansRam);
        carte
    }

    /// **Un port s'écrit en deux octets quand le préfixe le dit** : un
    /// `outw %ax` de `0xFFFF_0001` choisit la file un, pas `0xFFFF_0001`.
    #[test]
    fn a_two_byte_write_reaches_the_device_as_two_bytes() {
        let mut carte = ouverte(0x0005);
        assert!(carte.port_ecrire(0xC00E, 2, 0xFFFF_0001, &mut SansRam));
        let disque = carte.pci.premier.peripherique.as_ref().expect("le disque");
        assert_eq!(disque.file_choisie(), 1, "deux octets, et pas quatre");
        // Et une écriture partielle du registre de commande, d'un mot de
        // deux octets, ne garde que ceux-là.
        carte.port_ecrire(0xCF8, 4, adresse(3, 0x04), &mut SansRam);
        carte.port_ecrire(0xCFC, 2, 0x1234_0001, &mut SansRam);
        assert_eq!(carte.pci.premier.commande, 0x0001);
    }

    /// La capacité se lit par la fenêtre, en deux mots de quatre octets.
    #[test]
    fn the_capacity_is_readable_through_the_window() {
        let mut carte = ouverte(0x0001);
        assert_eq!(carte.port_lire(0xC014, 4, &mut SansRam), Some(8), "huit");
        assert_eq!(carte.port_lire(0xC018, 4, &mut SansRam), Some(0));
        // Fermée, la fenêtre n'est à personne.
        carte.port_ecrire(0xCF8, 4, adresse(3, 0x04), &mut SansRam);
        carte.port_ecrire(0xCFC, 4, 0, &mut SansRam);
        assert_eq!(carte.port_lire(0xC014, 4, &mut SansRam), None);
        let mut ram = RamPlate(vec![0; 16]);
        assert!(!carte.port_ecrire(0xC012, 1, 1, &mut ram));
    }

    // ------------------------------------------------------- le second disque

    /// Le bus du cœur Swift dans `X86SecondDiskTests` : huit secteurs en
    /// 00:03.0, seize en 00:04.0.
    fn bus_a_deux_disques() -> Pci {
        let mut pci = bus();
        pci.second.peripherique = Some(VirtioBlk::nouveau(16));
        pci
    }

    /// **L'emplacement quatre se présente comme un second disque virtio**,
    /// le trois reste le premier, chacun sa ligne, et **le pont n'est annoncé
    /// qu'une fois** (`testSlotFourIsASecondVirtioDiskAndTheBridgeStaysSingle`).
    #[test]
    fn slot_four_is_a_second_virtio_disk_and_the_bridge_stays_single() {
        let mut pci = bus_a_deux_disques();
        assert_eq!(EMPLACEMENT_DU_SECOND_DISQUE, 4);
        assert_eq!(Disque::Second.emplacement(), 4);
        pci.ecrire_adresse(adresse(4, 0));
        assert_eq!(pci.configuration(), 0x1001_1AF4);
        pci.ecrire_adresse(adresse(4, 0x08));
        assert_eq!(pci.configuration() >> 24, 0x01, "stockage de masse");
        pci.ecrire_adresse(adresse(4, 0x2C));
        assert_eq!(pci.configuration(), 0x0002_1AF4, "un bloc virtio");
        pci.ecrire_adresse(adresse(4, 0x3C));
        assert_eq!(pci.configuration() & 0xFF, 6, "la ligne six");
        assert_eq!(pci.configuration() >> 8 & 0xFF, 1, "broche A");
        pci.ecrire_adresse(adresse(3, 0x3C));
        assert_eq!(pci.configuration() & 0xFF, 5, "deux lignes, pas une");
        // Le pont, une fois : en zéro, et nulle part ailleurs.
        pci.ecrire_adresse(adresse(0, 0));
        assert_eq!(pci.configuration(), 0x1237_8086);
        for emplacement in (1..32).filter(|e| ![3, 4].contains(e)) {
            pci.ecrire_adresse(adresse(emplacement, 0));
            assert_eq!(pci.configuration(), 0xFFFF_FFFF, "{emplacement}");
        }
    }

    /// Sans second disque, l'emplacement quatre est vide — tous les uns — et
    /// ses écritures ne vont nulle part.
    #[test]
    fn without_a_second_disk_slot_four_is_empty() {
        let mut pci = bus();
        pci.ecrire_adresse(adresse(4, 0));
        assert_eq!(pci.configuration(), 0xFFFF_FFFF);
        pci.ecrire_adresse(adresse(4, 0x10));
        pci.ecrire_configuration(0xC040, 4, 0);
        pci.ecrire_adresse(adresse(4, 0x04));
        pci.ecrire_configuration(1, 4, 0);
        assert_eq!((pci.second.fenetre, pci.second.commande), (0, 0));
        assert_eq!(pci.au_port(0xC040), None);
        // Et le second seul n'est pas le premier.
        let mut pci = Pci::nouveau();
        pci.second.peripherique = Some(VirtioBlk::nouveau(16));
        pci.ecrire_adresse(adresse(3, 0));
        assert_eq!(pci.configuration(), 0xFFFF_FFFF, "trois, vide");
        pci.ecrire_adresse(adresse(4, 0));
        assert_eq!(pci.configuration(), 0x1001_1AF4);
        pci.ecrire_adresse(adresse(0, 0));
        assert_eq!(pci.configuration(), 0x1237_8086, "le pont, toujours");
    }

    /// Placer et ouvrir la fenêtre d'un emplacement, comme le noyau.
    fn placer(pci: &mut Pci, emplacement: u32, fenetre: u32) {
        pci.ecrire_adresse(adresse(emplacement, 0x10));
        pci.ecrire_configuration(fenetre, 4, 0);
        pci.ecrire_adresse(adresse(emplacement, 0x04));
        pci.ecrire_configuration(0x0005, 2, 0);
    }

    /// **Chaque disque a sa fenêtre**, placée et ouverte par le noyau, et un
    /// port de l'une ne tombe jamais sur l'autre
    /// (`testEachDiskAnswersItsOwnWindow`).
    #[test]
    fn each_disk_answers_its_own_window() {
        let mut pci = bus_a_deux_disques();
        placer(&mut pci, 3, 0xC000);
        assert_eq!(
            pci.au_port(0xC044),
            None,
            "le second n'est pas encore placé"
        );
        placer(&mut pci, 4, 0xC040);
        assert_eq!(pci.au_port(0xC004), Some((Disque::Premier, 4)));
        assert_eq!(pci.au_port(0xC03F), Some((Disque::Premier, 0x3F)));
        assert_eq!(pci.au_port(0xC040), Some((Disque::Second, 0)));
        assert_eq!(pci.au_port(0xC044), Some((Disque::Second, 4)));
        assert_eq!(pci.au_port(0xC07F), Some((Disque::Second, 0x3F)));
        assert_eq!(pci.au_port(0xC080), None);
        assert_eq!(pci.au_port(0xBFFF), None);
        // La capacité de chacun, lue par sa fenêtre : huit et seize secteurs.
        let capacite = |pci: &mut Pci, quel| {
            let disque = pci.emplacement_mut(quel).peripherique.as_mut().unwrap();
            disque.lire_port(0x14, 4)
        };
        assert_eq!(capacite(&mut pci, Disque::Premier), 8);
        assert_eq!(capacite(&mut pci, Disque::Second), 16);
        // Ce que le noyau règle sur l'un ne touche pas à l'autre : la
        // mesure, la fenêtre, la commande, la ligne.
        pci.ecrire_adresse(adresse(4, 0x10));
        pci.ecrire_configuration(0xFFFF_FFFF, 4, 0);
        assert_eq!(pci.configuration(), 0xFFFF_FFC1, "le second se mesure");
        pci.ecrire_adresse(adresse(3, 0x10));
        assert_eq!(pci.configuration(), 0xC001, "le premier, non");
        pci.ecrire_adresse(adresse(4, 0x10));
        pci.ecrire_configuration(0xD000, 4, 0);
        pci.ecrire_adresse(adresse(4, 0x3C));
        pci.ecrire_donnee(0, 1, 11);
        pci.ecrire_adresse(adresse(4, 0x04));
        pci.ecrire_configuration(0, 2, 0);
        assert_eq!(
            (pci.premier.fenetre, pci.premier.commande, pci.premier.ligne),
            (0xC000, 5, 5)
        );
        assert_eq!(
            (pci.second.fenetre, pci.second.commande, pci.second.ligne),
            (0xD000, 0, 11)
        );
        assert_eq!(pci.au_port(0xD000), None, "fermée, à personne");
        assert_eq!(pci.au_port(0xC000), Some((Disque::Premier, 0)));
    }

    /// **Deux fenêtres posées l'une sur l'autre ne donnent jamais un port aux
    /// deux** : le premier disque d'abord, comme `device(atPort:)`.
    #[test]
    fn overlapping_windows_go_to_the_first_disk() {
        let mut pci = bus_a_deux_disques();
        placer(&mut pci, 4, 0xC000);
        assert_eq!(pci.au_port(0xC010), Some((Disque::Second, 0x10)));
        placer(&mut pci, 3, 0xC000);
        assert_eq!(pci.au_port(0xC010), Some((Disque::Premier, 0x10)));
        // Le premier fermé, le second reprend ses ports.
        pci.ecrire_adresse(adresse(3, 0x04));
        pci.ecrire_configuration(0, 2, 0);
        assert_eq!(pci.au_port(0xC010), Some((Disque::Second, 0x10)));
    }

    /// **Les trois anneaux de la forme ancienne** se calculent à partir d'un
    /// seul nombre, à l'octet près : `vring_init`, à la lettre.
    #[test]
    fn the_old_form_places_its_rings_where_the_driver_put_them() {
        let taille = 128u64;
        let (descripteurs, disponibles, servies) = virtio_blk::anneaux(4, 128);
        assert_eq!(descripteurs, 4 * 4096);
        assert_eq!(disponibles, descripteurs + 16 * taille);
        // Après l'anneau des disponibles — drapeaux, index, la table et le mot
        // d'événement —, on arrondit à la page suivante.
        let apres = disponibles + 6 + 2 * taille;
        assert_eq!(servies, (apres + 4095) & !4095);
        assert_eq!(servies % 4096, 0);
        // 128 descripteurs font deux kibioctets, l'anneau des disponibles
        // 262 octets : l'anneau des servies tombe à la page qui suit.
        assert_eq!(servies, 5 * 4096, "une page plus loin");
    }
}
