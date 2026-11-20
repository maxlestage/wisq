//! Le chargeur de noyau de la machine PC : l'en-tête du protocole de
//! démarrage de Linux, et ce que le chargeur pose en mémoire. Portés de
//! `LinuxBootProtocolTests.swift` et `X86BootLoaderTests.swift`.

use wisq_vm::pc::chargeur::{
    charger, Ecran, Protocole, Refus, COMPTE_E820, E820_UTILISABLE, LIGNE_PAR_DEFAUT,
    OCTETS_D_EN_TETE, TABLE_E820, TAILLE_DE_LA_PAGE_ZERO,
};
use wisq_vm::pc::memoire;
use wisq_vm::x86::{GuestMemory, Width};

// Les valeurs **mesurées** sur le `vmlinuz-virt` d'Alpine 3.20 : c'est contre
// elles que l'en-tête synthétique est construit.
const VERSION: u16 = 0x020F;
const SECTEURS: u8 = 39;
const OCTETS_DE_SETUP: usize = (39 + 1) * 512;
const PARAGRAPHES: u32 = 683_840;
const OCTETS_PROTEGES: usize = 683_840 * 16;
const DRAPEAUX: u8 = 0x01;
const DRAPEAUX_ETENDUS: u16 = 0x3F;
const ADRESSE_PREFEREE: u64 = 0x0100_0000;
const TAILLE_RESERVEE: u32 = 36_425_728;
const LIMITE_DE_LIGNE: u32 = 2047;
const TOTAL: usize = 10_961_920;

/// Un en-tête, champ par champ, que chaque test abîme à sa façon.
#[derive(Clone, Copy)]
struct EnTete {
    version: u16,
    secteurs: u8,
    paragraphes: u32,
    drapeaux_etendus: u16,
    drapeau_d_amorce: u16,
    magie: [u8; 4],
}

impl Default for EnTete {
    fn default() -> Self {
        Self {
            version: VERSION,
            secteurs: SECTEURS,
            paragraphes: PARAGRAPHES,
            drapeaux_etendus: DRAPEAUX_ETENDUS,
            drapeau_d_amorce: 0xAA55,
            magie: *b"HdrS",
        }
    }
}

impl EnTete {
    fn octets(self) -> Vec<u8> {
        let mut octets = vec![0u8; 0x0300];
        octets[0x01F1] = self.secteurs;
        octets[0x01F4..0x01F8].copy_from_slice(&self.paragraphes.to_le_bytes());
        octets[0x01FE..0x0200].copy_from_slice(&self.drapeau_d_amorce.to_le_bytes());
        octets[0x0202..0x0206].copy_from_slice(&self.magie);
        octets[0x0206..0x0208].copy_from_slice(&self.version.to_le_bytes());
        octets[0x0211] = DRAPEAUX;
        octets[0x0234] = 1;
        octets[0x0236..0x0238].copy_from_slice(&self.drapeaux_etendus.to_le_bytes());
        octets[0x0238..0x023C].copy_from_slice(&LIMITE_DE_LIGNE.to_le_bytes());
        octets[0x0258..0x0260].copy_from_slice(&ADRESSE_PREFEREE.to_le_bytes());
        octets[0x0260..0x0264].copy_from_slice(&TAILLE_RESERVEE.to_le_bytes());
        octets
    }
}

#[test]
fn the_header_of_a_real_kernel_is_read_field_for_field() {
    let en_tete = Protocole::lire(&EnTete::default().octets(), Some(TOTAL)).expect("un en-tête");
    assert_eq!(en_tete.version, VERSION);
    assert_eq!(en_tete.version_dite(), "2.15");
    assert_eq!(en_tete.octets_de_setup, OCTETS_DE_SETUP);
    assert_eq!(en_tete.octets_proteges, OCTETS_PROTEGES);
    assert_eq!(en_tete.drapeaux, DRAPEAUX);
    assert_eq!(en_tete.drapeaux_etendus, DRAPEAUX_ETENDUS);
    assert!(en_tete.deplacable);
    assert_eq!(en_tete.adresse_preferee, ADRESSE_PREFEREE);
    assert_eq!(en_tete.taille_reservee, TAILLE_RESERVEE);
    assert_eq!(en_tete.limite_de_ligne, LIMITE_DE_LIGNE);
    assert_eq!(en_tete.octets_declares(), TOTAL);
}

#[test]
fn the_sixty_four_bit_entry_is_what_names_the_architecture() {
    let avec = Protocole::lire(&EnTete::default().octets(), None).expect("un en-tête");
    assert!(avec.entree_64_bits());
    assert_eq!(avec.architecture(), "x86-64");
    let sans = Protocole::lire(
        &EnTete {
            drapeaux_etendus: 0x3E,
            ..Default::default()
        }
        .octets(),
        None,
    )
    .expect("un en-tête");
    assert!(!sans.entree_64_bits());
    assert_eq!(sans.architecture(), "x86");
}

#[test]
fn fields_older_kernels_never_wrote_are_not_read() {
    let lire = |version: u16| {
        Protocole::lire(
            &EnTete {
                version,
                ..Default::default()
            }
            .octets(),
            None,
        )
        .expect("un en-tête")
    };
    let ancien = lire(0x020B);
    assert_eq!(
        ancien.drapeaux_etendus, 0,
        "xloadflags n'existe qu'à partir de 2.12"
    );
    assert_eq!(ancien.architecture(), "x86");
    assert_eq!(
        ancien.adresse_preferee, ADRESSE_PREFEREE,
        "2.10 l'a introduit"
    );
    let plus_ancien = lire(0x0209);
    assert_eq!(plus_ancien.adresse_preferee, 0);
    assert_eq!(plus_ancien.taille_reservee, 0);
    assert_eq!(
        plus_ancien.limite_de_ligne, LIMITE_DE_LIGNE,
        "2.06 l'a introduit"
    );
    let encore = lire(0x0205);
    assert_eq!(encore.limite_de_ligne, 0);
    assert!(encore.deplacable);
    assert!(!lire(0x0204).deplacable);
}

#[test]
fn zero_setup_sectors_means_four() {
    let en_tete = Protocole::lire(
        &EnTete {
            secteurs: 0,
            ..Default::default()
        }
        .octets(),
        None,
    )
    .expect("un en-tête");
    assert_eq!(en_tete.octets_de_setup, 5 * 512);
}

#[test]
fn neither_mark_alone_is_enough() {
    let lire = |en_tete: EnTete| Protocole::lire(&en_tete.octets(), None);
    assert!(
        lire(EnTete {
            drapeau_d_amorce: 0,
            ..Default::default()
        })
        .is_none(),
        "sans 0xAA55 à 0x1FE, ce n'est pas un secteur d'amorçage"
    );
    assert!(
        lire(EnTete {
            magie: *b"hdrs",
            ..Default::default()
        })
        .is_none(),
        "« HdrS » est sensible à la casse"
    );
    assert!(
        lire(EnTete {
            version: 0x0100,
            ..Default::default()
        })
        .is_none(),
        "une version d'avant 2.00 n'a pas les champs qu'on lit"
    );
}

#[test]
fn a_file_that_announces_more_than_it_weighs_is_not_a_kernel() {
    let octets = EnTete::default().octets();
    assert!(Protocole::lire(&octets, Some(TOTAL - 1)).is_none());
    assert!(
        Protocole::lire(&octets, Some(TOTAL)).is_some(),
        "la borne est exacte : le fichier mesuré tombe pile dessus"
    );
    // Un noyau signé porte des octets après lui, et se lit quand même.
    let signe = Protocole::lire(&octets, Some(TOTAL + 8192)).expect("un en-tête");
    assert_eq!(signe.octets_declares(), TOTAL);
}

#[test]
fn a_file_too_short_for_the_header_does_not_carry_one() {
    assert_eq!(OCTETS_D_EN_TETE, 0x0264);
    assert!(Protocole::lire(&EnTete::default().octets()[..0x0263], None).is_none());
}

/// Un noyau synthétique : l'en-tête mesuré, un setup, et un corps
/// reconnaissable, assez petit pour tenir dans une mémoire de test.
fn noyau() -> Vec<u8> {
    let paragraphes = 1024u32;
    let mut octets = EnTete {
        paragraphes,
        ..Default::default()
    }
    .octets();
    octets.resize(OCTETS_DE_SETUP, 0);
    octets.extend((0..paragraphes as usize * 16).map(|rang| (rang.wrapping_mul(7) & 0xFF) as u8));
    octets
}

const RAM: u64 = 64 << 20;

fn memoire(octets: u64) -> GuestMemory {
    GuestMemory {
        base: 0,
        bytes: vec![0u8; octets as usize],
    }
}

fn lu32(memoire: &GuestMemory, adresse: u64) -> u64 {
    memoire.read(adresse, Width::Dword).expect("dans la RAM")
}

fn page_zero(memoire: &GuestMemory, adresse: u64) -> &[u8] {
    &memoire.bytes[adresse as usize..adresse as usize + TAILLE_DE_LA_PAGE_ZERO]
}

#[test]
fn the_protected_mode_kernel_lands_at_its_preferred_address() {
    let noyau = noyau();
    let mut ram = memoire(RAM);
    let placement = charger(&noyau, &mut ram, RAM, LIGNE_PAR_DEFAUT, None, None).expect("chargé");
    assert_eq!(placement.adresse_du_noyau, ADRESSE_PREFEREE);
    let ou = placement.adresse_du_noyau as usize;
    assert_eq!(
        &ram.bytes[ou..ou + 32],
        &noyau[OCTETS_DE_SETUP..OCTETS_DE_SETUP + 32],
        "ce qui est chargé commence après le setup, pas au début du fichier"
    );
    assert_eq!(
        placement.entree,
        placement.adresse_du_noyau + 0x200,
        "l'entrée 64 bits est à 0x200 du début"
    );
    assert_eq!(placement.octets_reserves, TAILLE_RESERVEE as usize);
}

#[test]
fn the_zero_page_carries_the_setup_header_and_what_only_the_loader_knows() {
    let mut ram = memoire(RAM);
    let placement =
        charger(&noyau(), &mut ram, RAM, "console=ttyS0 quiet", None, None).expect("chargé");
    let page = page_zero(&ram, placement.page_zero);
    assert_eq!(&page[0x202..0x206], b"HdrS");
    assert_eq!(u16::from_le_bytes([page[0x206], page[0x207]]), VERSION);
    assert_eq!(page[0x210], 0xFF, "le noyau doit savoir qui l'a chargé");
    assert_ne!(page[0x211] & 0x01, 0, "LOADED_HIGH");
    assert_ne!(page[0x211] & 0x80, 0, "CAN_USE_HEAP");
    assert_eq!(
        lu32(&ram, placement.page_zero + 0x228),
        placement.ligne_de_commande
    );
    assert_eq!(
        lu32(&ram, placement.page_zero + 0x214),
        ADRESSE_PREFEREE,
        "code32_start : où le noyau a été mis"
    );
    assert_eq!(&page[0x218..0x220], &[0u8; 8], "pas d'initramfs annoncé");
    assert_eq!(placement.adresse_de_l_initramfs, 0);
    // Aucun écran : `orig_video_isVGA` et la géométrie restent nuls.
    assert_eq!(page[0x0F], 0);
    assert_eq!(&page[0x12..0x30], &[0u8; 0x1E]);
}

#[test]
fn the_command_line_is_written_terminated_and_cut_at_the_kernels_limit() {
    // La mémoire n'est pas neuve : le zéro final doit être écrit, pas
    // seulement trouvé là.
    let sale = || {
        let mut ram = memoire(RAM);
        ram.bytes[0x2_0000..0x2_2000].fill(0xFF);
        ram
    };
    let mut ram = sale();
    let placement = charger(&noyau(), &mut ram, RAM, "console=ttyS0", None, None).expect("chargé");
    let ou = placement.ligne_de_commande as usize;
    assert_eq!(ou, 0x2_0000);
    assert_eq!(&ram.bytes[ou..ou + 14], b"console=ttyS0\0");

    let longue = "a".repeat(5000);
    let mut ram = sale();
    let placement = charger(&noyau(), &mut ram, RAM, &longue, None, None).expect("chargé");
    let ou = placement.ligne_de_commande as usize;
    let limite = LIMITE_DE_LIGNE as usize;
    assert_eq!(ram.bytes[ou + limite], 0, "elle reste terminée");
    assert!(ram.bytes[ou..ou + limite]
        .iter()
        .all(|octet| *octet == b'a'));
}

#[test]
fn the_default_command_line_asks_for_early_output() {
    assert!(
        LIGNE_PAR_DEFAUT.contains("earlyprintk=serial"),
        "sans ça, un démarrage qui échoue tôt ne dit rien"
    );
    assert!(LIGNE_PAR_DEFAUT.contains("console=ttyS0"));
}

#[test]
fn the_refusals_are_named() {
    assert_eq!(
        charger(&[0u8; 1024], &mut memoire(RAM), RAM, "", None, None),
        Err(Refus::PasUnNoyau)
    );
    let mut sans_entree = noyau();
    sans_entree[0x236] = 0x3E; // xloadflags sans le bit 0
    assert_eq!(
        charger(&sans_entree, &mut memoire(RAM), RAM, "", None, None),
        Err(Refus::PasDEntree64Bits)
    );
    let mut ancien = noyau();
    ancien[0x206..0x208].copy_from_slice(&0x0205u16.to_le_bytes());
    assert_eq!(
        charger(&ancien, &mut memoire(RAM), RAM, "", None, None),
        Err(Refus::ProtocoleTropAncien(0x0205))
    );
    let petite = 1 << 20;
    assert!(matches!(
        charger(&noyau(), &mut memoire(petite), petite, "", None, None),
        Err(Refus::MemoireInsuffisante { .. })
    ));
}

/// **Un noyau coupé est refusé par son nom**, pas comme « pas un noyau » : un
/// téléchargement interrompu a le bon en-tête, et c'est le même fichier qu'il
/// faut reprendre, pas un autre qu'il faut chercher.
#[test]
fn a_kernel_cut_short_is_refused_as_truncated() {
    let entier = noyau();
    let coupe = &entier[..OCTETS_DE_SETUP + 16];
    assert_eq!(
        charger(coupe, &mut memoire(RAM), RAM, "", None, None),
        Err(Refus::Tronque)
    );
    assert_eq!(
        Refus::Tronque.to_string(),
        "le fichier est plus court que son en-tête ne l'annonce"
    );
    // À un octet près : il manque le dernier.
    assert_eq!(
        charger(
            &entier[..entier.len() - 1],
            &mut memoire(RAM),
            RAM,
            "",
            None,
            None
        ),
        Err(Refus::Tronque)
    );
    assert!(charger(&entier, &mut memoire(RAM), RAM, "", None, None).is_ok());
    // Et rien n'a été posé en mémoire avant le refus.
    let mut ram = memoire(RAM);
    assert!(charger(coupe, &mut ram, RAM, "", None, None).is_err());
    assert!(ram.bytes.iter().all(|octet| *octet == 0));
}

/// **La réserve du noyau doit tenir, pas seulement ses octets** : il se
/// décompresse chez lui, bien au-delà de ce qu'il pèse. Trente-deux
/// mébioctets portent les seize kibioctets du noyau synthétique à seize
/// mébioctets, mais pas les trente-six mébioctets qu'il réserve.
#[test]
fn the_room_a_kernel_reserves_must_fit_not_only_its_bytes() {
    let ram = 32 << 20;
    let mut memoire = memoire(ram);
    assert_eq!(
        charger(&noyau(), &mut memoire, ram, "", None, None),
        Err(Refus::MemoireInsuffisante {
            besoin: ADRESSE_PREFEREE as usize + TAILLE_RESERVEE as usize,
            disponible: ram as usize,
        })
    );
    assert!(
        memoire.bytes.iter().all(|octet| *octet == 0),
        "et rien n'a été posé"
    );
}

/// Poser un bloc ne sort pas de la mémoire : un bloc qui dépasse est refusé
/// en entier.
#[test]
fn a_block_that_does_not_fit_is_not_placed_at_all() {
    let mut ram = memoire(0x1000);
    assert!(
        memoire::poser(&mut ram, 0xFFC, &[1, 2, 3, 4]),
        "pile au bord"
    );
    assert_eq!(&ram.bytes[0xFFC..], &[1, 2, 3, 4]);
    assert!(!memoire::poser(&mut ram, 0xFFD, &[9, 9, 9, 9]));
    assert_eq!(&ram.bytes[0xFFC..], &[1, 2, 3, 4], "rien n'a été écrit");
    assert!(!memoire::poser(&mut ram, u64::MAX, &[9]));
    assert!(!memoire::poser(&mut ram, 0x1000, &[9]));
}

/// **Sans initramfs, ses deux champs sont nuls, quoi que le fichier y ait
/// laissé** : l'en-tête est recopié tel quel dans la page zéro, et un noyau
/// qui y lirait une adresse irait décompresser n'importe quoi.
#[test]
fn without_a_ramdisk_its_fields_are_cleared_whatever_the_file_says() {
    let mut noyau = noyau();
    noyau[0x218..0x21C].copy_from_slice(&0x0123_4000u32.to_le_bytes());
    noyau[0x21C..0x220].copy_from_slice(&0x5678u32.to_le_bytes());
    for initramfs in [None, Some(&[][..])] {
        let mut ram = memoire(RAM);
        let placement = charger(&noyau, &mut ram, RAM, "", initramfs, None).expect("chargé");
        let page = page_zero(&ram, placement.page_zero);
        assert_eq!(&page[0x218..0x220], &[0u8; 8]);
        assert_eq!(placement.octets_de_l_initramfs, 0);
    }
}

#[test]
fn an_initial_ramdisk_is_placed_at_the_top_and_announced() {
    let mut ram = memoire(RAM);
    let archive = vec![0x5Au8; 4097];
    let placement = charger(&noyau(), &mut ram, RAM, "", Some(&archive), None).expect("chargé");
    assert!(placement.adresse_de_l_initramfs > 0);
    assert_eq!(placement.octets_de_l_initramfs, archive.len());
    assert_eq!(
        placement.adresse_de_l_initramfs % 0x1000,
        0,
        "aligné sur une page"
    );
    assert_eq!(
        placement.adresse_de_l_initramfs,
        (RAM - archive.len() as u64) & !0xFFF,
        "en haut de la mémoire"
    );
    let ou = placement.adresse_de_l_initramfs as usize;
    assert_eq!(&ram.bytes[ou..ou + 4], &[0x5A; 4]);
    assert_eq!(
        lu32(&ram, placement.page_zero + 0x218),
        placement.adresse_de_l_initramfs
    );
    assert_eq!(
        lu32(&ram, placement.page_zero + 0x21C),
        archive.len() as u64
    );
}

#[test]
fn a_ramdisk_that_does_not_fit_is_refused_rather_than_written_outside() {
    // Soixante mébioctets ne tiennent pas au-dessus de la réserve du noyau.
    let archive = vec![0u8; 60 << 20];
    assert!(matches!(
        charger(&noyau(), &mut memoire(RAM), RAM, "", Some(&archive), None),
        Err(Refus::MemoireInsuffisante { .. })
    ));
    // Plus grand que la mémoire elle-même : un refus, pas une soustraction
    // qui boucle.
    let enorme = vec![0u8; (RAM + 4096) as usize];
    assert!(matches!(
        charger(&noyau(), &mut memoire(RAM), RAM, "", Some(&enorme), None),
        Err(Refus::MemoireInsuffisante { .. })
    ));
}

/// Les entrées de la carte e820 de la page zéro.
fn carte(page: &[u8]) -> Vec<(u64, u64, u32)> {
    (0..usize::from(page[COMPTE_E820]))
        .map(|rang| {
            let ou = TABLE_E820 + rang * 20;
            (
                u64::from_le_bytes(page[ou..ou + 8].try_into().unwrap()),
                u64::from_le_bytes(page[ou + 8..ou + 16].try_into().unwrap()),
                u32::from_le_bytes(page[ou + 16..ou + 20].try_into().unwrap()),
            )
        })
        .collect()
}

#[test]
fn the_memory_map_says_where_the_ram_is() {
    let mut ram = memoire(RAM);
    let placement = charger(&noyau(), &mut ram, RAM, "", None, None).expect("chargé");
    assert_eq!(
        carte(page_zero(&ram, placement.page_zero)),
        vec![
            (0, 0x9_FC00, E820_UTILISABLE),
            (0x10_0000, RAM - 0x10_0000, E820_UTILISABLE),
        ],
        "ce qui est sous le trou du premier mégaoctet, et tout le reste"
    );
}

#[test]
fn the_zero_page_declares_a_linear_framebuffer_and_reserves_it() {
    for (largeur, hauteur) in [(1024usize, 768usize), (800, 600)] {
        let mut ram = memoire(RAM);
        let ecran = Ecran {
            base: 0xE000_0000,
            largeur,
            hauteur,
        };
        let placement = charger(&noyau(), &mut ram, RAM, "", None, Some(ecran)).expect("chargé");
        let page = page_zero(&ram, placement.page_zero);
        let u16_a = |ou: usize| u16::from_le_bytes([page[ou], page[ou + 1]]);
        let u32_a = |ou: usize| u32::from_le_bytes(page[ou..ou + 4].try_into().unwrap());
        assert_eq!(
            page[0x0F], 0x23,
            "orig_video_isVGA annonce un cadre linéaire"
        );
        assert_eq!(usize::from(u16_a(0x12)), largeur, "lfb_width");
        assert_eq!(usize::from(u16_a(0x14)), hauteur, "lfb_height");
        assert_eq!(u16_a(0x16), 32, "lfb_depth : quatre octets par pixel");
        assert_eq!(u32_a(0x18), 0xE000_0000, "lfb_base");
        assert_eq!(usize::from(u16_a(0x24)), largeur * 4, "lfb_linelength");
        assert_eq!(
            &page[0x26..0x2E],
            &[8, 16, 8, 8, 8, 0, 8, 24],
            "XRGB8888 : rouge, vert, bleu, réservé — taille puis position"
        );
        // **`lfb_size` compte en unités de 64 Kio**, arrondi vers le haut :
        // assez pour le cadre, et pas un octet pris pour 64 Kio.
        let annonce = u64::from(u32_a(0x1C)) << 16;
        let besoin = (hauteur * largeur * 4) as u64;
        assert!(besoin <= annonce, "« VRAM smaller than advertised »");
        assert!(annonce < besoin + 65_536);
        assert!(
            carte(page).contains(&(0xE000_0000, besoin, 2)),
            "le cadre doit être réservé dans la carte e820, sinon il sera distribué"
        );
    }
    assert_eq!(
        Ecran {
            base: 0,
            largeur: 1024,
            hauteur: 768
        }
        .memoire_video_annoncee(),
        48
    );
}

/// Au-delà de trois gibioctets, la RAM a un trou : la carte le dit, et
/// l'initramfs reste sous le trou, où son adresse tient sur trente-deux bits.
#[test]
fn above_three_gibibytes_the_map_has_a_hole() {
    let ram = 4u64 << 30;
    assert_eq!(
        memoire::plages(ram),
        vec![0..0xC000_0000, (1 << 32)..(1 << 32) + (1 << 30)]
    );
    assert_eq!(
        memoire::plages(3 << 30),
        vec![0..3 << 30],
        "trois tout juste : pas de trou"
    );
    let mut cpu = wisq_vm::x86::Cpu::default();
    memoire::brancher(&mut cpu, ram);
    assert_eq!(cpu.memory_hole, (0xC000_0000, 1 << 30));
    assert_eq!(cpu.memory.bytes.len() as u64, ram + (1 << 30));
    let archive = vec![0xA5u8; 8192];
    let placement =
        charger(&noyau(), &mut cpu.memory, ram, "", Some(&archive), None).expect("chargé");
    assert_eq!(placement.adresse_de_l_initramfs, 0xC000_0000 - 8192);
    assert_eq!(
        carte(page_zero(&cpu.memory, placement.page_zero)),
        vec![
            (0, 0x9_FC00, E820_UTILISABLE),
            (0x10_0000, 0xC000_0000 - 0x10_0000, E820_UTILISABLE),
            (1 << 32, 1 << 30, E820_UTILISABLE),
        ]
    );
    // Et le processeur refuse de prendre le trou pour de la RAM.
    assert!(cpu.read_memory(0xC000_0000, Width::Qword).is_err());
    assert!(cpu.write_memory(0xFFFF_FFF8, Width::Qword, 1).is_err());
    cpu.faulted = false;
    assert!(cpu.read_memory(0xBFFF_FFF8, Width::Qword).is_ok());
    assert!(cpu.write_memory(1 << 32, Width::Qword, 7).is_ok());
    assert_eq!(cpu.read_memory(1 << 32, Width::Qword), Ok(7));
}

/// **Une RAM que l'hôte ne peut pas donner est un refus, pas un arrêt du
/// processus.** `vec![0; n]` faisait SIGABRT sur « memory allocation of …
/// failed » ; 2^62 octets ne s'allouent sur aucun hôte, pas même avec la
/// surréservation permise, puisque l'espace d'adresses d'un x86-64 en compte
/// 2^47. Le processeur reste tel qu'il était, et la machine ne se construit
/// pas.
#[test]
fn a_ram_the_host_cannot_give_is_refused_not_aborted() {
    assert!(memoire::bloc_nul(1 << 62).is_none());
    assert!(memoire::bloc_nul(u64::MAX).is_none(), "plus qu'un isize");
    let bloc = memoire::bloc_nul(1 << 20).expect("un mébioctet");
    assert_eq!(bloc.len(), 1 << 20);
    assert!(bloc.iter().all(|&octet| octet == 0), "des pages nulles");
    assert_eq!(memoire::bloc_nul(0), Some(Vec::new()));

    let mut cpu = wisq_vm::x86::Cpu::default();
    assert!(!memoire::essayer_de_brancher(&mut cpu, 1 << 62));
    assert!(cpu.memory.bytes.is_empty(), "rien de branché");
    assert_eq!(cpu.memory_hole, (0, 0));
    assert!(wisq_vm::pc::Machine::essayer(1 << 62).is_none());
    let machine = wisq_vm::pc::Machine::essayer(256 << 20).expect("256 Mio");
    assert_eq!(machine.cpu.memory.bytes.len(), 256 << 20);
}

/// Le vrai noyau, quand on en désigne un : `WISQ_PC_KERNEL`.
#[test]
fn a_real_kernel_is_placed_where_it_asks() {
    let Some(octets) = std::env::var("WISQ_PC_KERNEL")
        .ok()
        .and_then(|chemin| std::fs::read(chemin).ok())
    else {
        eprintln!("noyau PC absent : définir WISQ_PC_KERNEL pour ce test");
        return;
    };
    let en_tete = Protocole::lire(&octets, Some(octets.len())).expect("un en-tête");
    assert!(
        en_tete.entree_64_bits(),
        "un noyau x86_64 a son entrée 64 bits"
    );
    assert!(en_tete.version >= 0x020C);
    let ram = 128u64 << 20;
    let mut memoire = memoire(ram);
    let placement = charger(&octets, &mut memoire, ram, "", None, None).expect("chargé");
    assert_eq!(placement.adresse_du_noyau, en_tete.adresse_preferee);
    assert!(
        placement.octets_reserves > en_tete.octets_proteges,
        "il faut réserver plus que le poids : le noyau se décompresse chez lui"
    );
    let ou = placement.adresse_du_noyau as usize;
    assert_eq!(
        &memoire.bytes[ou..ou + 64],
        &octets[en_tete.octets_de_setup..en_tete.octets_de_setup + 64]
    );
}
