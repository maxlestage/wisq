//! **Le pont PCI de la page** : la configuration par les ports `0xCF8` et
//! `0xCFC`, un pont hôte 440FX en 00:00.0 et le disque virtio de forme
//! ancienne en 00:03.0. Porté depuis `X86PCIHost` du cœur Swift
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
//! même ligne 5 tant que le noyau n'en écrit pas une autre. Le second disque
//! (00:04.0), la carte réseau (00:05.0), l'écran (00:02.0) et la tablette
//! viendront chacun à leur tranche ; leurs emplacements rendent aujourd'hui
//! tous les uns, « personne ».

use super::virtio_blk::VirtioBlk;

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
/// La taille de la fenêtre de ports que le disque demande.
pub const TAILLE_DE_FENETRE: u32 = 0x40;
/// **La ligne du disque, sur le 8259 maître**, celle que le cœur Swift
/// annonce (`VirtioBlock.pc.interruptLine`) : zéro est l'horloge, quatre le
/// port série, cinq le disque.
pub const LIGNE_DU_DISQUE: u8 = 5;

/// **Le bus** : l'adresse choisie, l'espace de configuration du disque, et le
/// disque lui-même s'il y en a un.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pci {
    /// Ce que le noyau a écrit dans le port d'adresse.
    adresse: u32,
    /// Ce que le noyau a activé : bit 0 les ports, bit 2 la maîtrise du bus.
    pub commande: u16,
    /// Où le noyau a placé la fenêtre de ports du disque (la BAR0).
    pub fenetre: u32,
    /// La ligne d'interruption, telle que le noyau la lit **et l'écrit** :
    /// c'est elle qui décide où le disque frappe.
    pub ligne: u8,
    /// Vrai entre l'écriture de tous les uns dans la BAR0 et l'écriture qui
    /// suit : c'est ainsi qu'un noyau demande la **taille** de la fenêtre.
    mesure: bool,
    /// Le disque, ou rien. Sans lui le bus existe mais reste vide, ce qui est
    /// une réponse honnête : le noyau énumère, ne trouve rien, et continue.
    pub disque: Option<VirtioBlk>,
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
            commande: 0,
            fenetre: 0,
            ligne: LIGNE_DU_DISQUE,
            mesure: false,
            disque: None,
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

    fn vise_le_disque(&self) -> bool {
        self.disque.is_some() && self.vise(EMPLACEMENT_DU_DISQUE)
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
            // là pour être reconnu.
            return match registre {
                0x00 => 0x1237_8086, // Intel 440FX, comme chez QEMU
                0x04 => 0x0000_0006, // mémoire et maîtrise du bus
                0x08 => 0x0600_0002, // pont hôte, révision deux
                _ => 0,              // en-tête de type zéro, et le reste
            };
        }
        if !self.vise_le_disque() {
            return 0xFFFF_FFFF;
        }
        match registre {
            // virtio-blk, en version ancienne (l'identifiant 0x1001).
            0x00 => 0x1001_1AF4,
            0x04 => u32::from(self.commande), // aucun bit d'état à annoncer
            // Stockage de masse, révision zéro : la forme ancienne.
            0x08 => 0x0100_0000,
            0x10 => {
                // Pendant la mesure, le masque : les bits que le noyau ne peut
                // pas changer disent la taille. Le bit 0 dit « des ports ».
                if self.mesure {
                    !(TAILLE_DE_FENETRE - 1) | 1
                } else {
                    self.fenetre | 1
                }
            }
            // Le sous-système : un bloc virtio. C'est de là que vient le
            // `modalias` qui fait charger le pilote.
            0x2C => 0x0002_1AF4,
            // La ligne, puis la broche A.
            0x3C => u32::from(self.ligne) | (1 << 8),
            _ => 0,
        }
    }

    /// **Écrire le registre choisi**, déjà recomposé sur trente-deux bits.
    /// `largeur` et `octet` disent ce que l'invité a vraiment écrit : la ligne
    /// d'interruption ne change que si son octet est visé.
    pub fn ecrire_configuration(&mut self, valeur: u32, largeur: u8, octet: u32) {
        if !self.vise_le_disque() {
            return;
        }
        match self.choix().registre {
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

    /// Vrai quand les ports du disque sont placés et activés.
    pub fn fenetre_ouverte(&self) -> bool {
        self.disque.is_some() && self.fenetre != 0 && self.commande & 0x01 != 0
    }

    /// **Le décalage d'un port dans la fenêtre du disque**, ou rien. Une
    /// fenêtre placée mais pas activée ne répond pas : un périphérique qui
    /// répondrait avant volerait des ports à un autre.
    pub fn dans_la_fenetre(&self, port: u16) -> Option<u16> {
        let port = u32::from(port);
        (self.fenetre_ouverte() && port >= self.fenetre && port - self.fenetre < TAILLE_DE_FENETRE)
            .then(|| (port - self.fenetre) as u16)
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
        pci.disque = Some(VirtioBlk::nouveau(8));
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
        assert_eq!((pci.fenetre, pci.commande), (0, 0));
        assert_eq!(pci.dans_la_fenetre(0xC000), None);
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
        assert_eq!(pci.dans_la_fenetre(0xC000), None, "placée, pas ouverte");
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0x04));
        pci.ecrire_configuration(0x0005, 4, 0); // ports + maîtrise du bus
        assert_eq!(pci.dans_la_fenetre(0xC000), Some(0));
        assert_eq!(pci.dans_la_fenetre(0xC012), Some(0x12));
        assert_eq!(pci.dans_la_fenetre(0xC03F), Some(0x3F));
        assert_eq!(pci.dans_la_fenetre(0xC040), None, "pas un octet au-delà");
        assert_eq!(pci.dans_la_fenetre(0xBFFF), None, "ni en deçà");
        // La maîtrise seule (bit 2) n'ouvre pas les ports.
        pci.ecrire_configuration(0x0004, 4, 0);
        assert_eq!(pci.dans_la_fenetre(0xC000), None);
    }

    /// La ligne est **écrite** par le noyau, d'un octet, et relue.
    #[test]
    fn the_interrupt_line_is_what_the_kernel_wrote() {
        let mut pci = bus();
        pci.ecrire_adresse(adresse(EMPLACEMENT_DU_DISQUE, 0x3C));
        assert_eq!(pci.configuration() >> 8 & 0xFF, 1, "broche A");
        assert_eq!(pci.configuration() & 0xFF, 5, "la ligne cinq au départ");
        pci.ecrire_configuration(0x0000_010B, 1, 0);
        assert_eq!(pci.ligne, 11);
        assert_eq!(pci.configuration() & 0xFF, 11);
        // L'octet de la broche, écrit seul, ne touche pas à la ligne.
        pci.ecrire_configuration(0x0000_0207, 1, 1);
        assert_eq!(pci.ligne, 11);
        // Par le port de donnée, d'un octet, comme Linux : `0xCFC`.
        pci.ecrire_donnee(0, 1, 0x09);
        assert_eq!(pci.ligne, 9);
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
        let disque = carte.pci.disque.as_ref().expect("le disque");
        assert_eq!(disque.file_choisie(), 1, "deux octets, et pas quatre");
        // Et une écriture partielle du registre de commande, d'un mot de
        // deux octets, ne garde que ceux-là.
        carte.port_ecrire(0xCF8, 4, adresse(3, 0x04), &mut SansRam);
        carte.port_ecrire(0xCFC, 2, 0x1234_0001, &mut SansRam);
        assert_eq!(carte.pci.commande, 0x0001);
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
