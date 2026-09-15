//! **Les segments d'un noyau ELF, et pourquoi ils comptent tous.**
//!
//! `--example kernel-entry` ne posait dans la RAM invitée que le segment qui
//! porte le point d'entrée — le texte. Le vmlinux d'Alpine en a **quatre** :
//! le texte, `.data`, le percpu, et un dernier qui traîne cinq mébioctets de
//! BSS. `secondary_startup_64` charge son pointeur de pile depuis
//! `initial_stack`, qui vit dans `.data` ; sans ce segment la lecture rend
//! zéro, RSP vaut zéro, et les empilements descendent en négatif. C'est
//! exactement le `rsp = 0xffffffffffffffe8` relevé à
//! `secondary_startup_64_no_verify + 339`.
//!
//! Lire ces segments était fait à la main dans l'exemple, donc tenu par rien.
//! Ici, sur un ELF construit pour la circonstance : un outil de diagnostic qui
//! se trompe de segment ne rend pas une erreur, il rend un résultat.
use wisq_vm::kernel_image::{loads, MONTAGE_COMMAND_LINE};

/// Un ELF64 minimal : l'en-tête, puis `count` en-têtes de programme.
fn elf(entry: u64, headers: &[(u32, u64, u64, u64, u64, u64)]) -> Vec<u8> {
    let mut bytes = vec![0u8; 64];
    bytes[..4].copy_from_slice(b"\x7fELF");
    bytes[4] = 2; // 64 bits
    bytes[5] = 1; // petit-boutiste
    bytes[16..18].copy_from_slice(&2u16.to_le_bytes()); // ET_EXEC
    bytes[18..20].copy_from_slice(&62u16.to_le_bytes()); // x86-64
    bytes[24..32].copy_from_slice(&entry.to_le_bytes());
    bytes[32..40].copy_from_slice(&64u64.to_le_bytes()); // e_phoff
    bytes[52..54].copy_from_slice(&64u16.to_le_bytes()); // e_ehsize
    bytes[54..56].copy_from_slice(&56u16.to_le_bytes()); // e_phentsize
    bytes[56..58].copy_from_slice(&(headers.len() as u16).to_le_bytes());
    for (kind, offset, virtual_address, physical_address, file, memory) in headers {
        let mut header = vec![0u8; 56];
        header[0..4].copy_from_slice(&kind.to_le_bytes());
        header[8..16].copy_from_slice(&offset.to_le_bytes());
        header[16..24].copy_from_slice(&virtual_address.to_le_bytes());
        header[24..32].copy_from_slice(&physical_address.to_le_bytes());
        header[32..40].copy_from_slice(&file.to_le_bytes());
        header[40..48].copy_from_slice(&memory.to_le_bytes());
        bytes.extend_from_slice(&header);
    }
    bytes
}

#[test]
fn every_loadable_segment_is_reported_and_nothing_else_is() {
    // Trois entrées, dont une PT_NOTE (4) qui n'est pas chargeable et qu'un
    // lecteur naïf compterait quand même.
    let mut image = elf(
        0x0100_0090,
        &[
            (1, 0x1000, 0xffff_ffff_8100_0000, 0x0100_0000, 1000, 1000),
            (4, 0x2000, 0, 0, 32, 32), // PT_NOTE
            (1, 0x3000, 0xffff_ffff_8240_0000, 0x0240_0000, 500, 900),
        ],
    );
    // Le fichier doit porter ce que ses en-têtes annoncent, sinon le lecteur
    // refuse — c'est ce que vérifie le test d'après.
    image.resize(0x3000 + 500, 0);
    let (entry, segments) = loads(&image).expect("l'ELF se lit");
    assert_eq!(entry, 0x0100_0090);
    assert_eq!(segments.len(), 2, "la note n'est pas un segment à charger");
    assert_eq!(segments[0].physical_address, 0x0100_0000);
    assert_eq!(segments[0].file_size, 1000);

    // **Le second porte du BSS**, et c'est la distinction qui compte : quatre
    // cents octets qui existent en mémoire et pas dans le fichier. Confondre
    // les deux tailles fait soit lire hors du fichier, soit laisser un trou
    // là où le noyau attend des zéros.
    assert_eq!(segments[1].file_size, 500);
    assert_eq!(segments[1].memory_size, 900);
    assert_eq!(segments[1].physical_address, 0x0240_0000);
    assert_eq!(segments[1].virtual_address, 0xffff_ffff_8240_0000);
}

#[test]
fn a_segment_that_reaches_past_the_file_is_refused() {
    // Un `p_filesz` qui déborde du fichier : le lire ferait paniquer une
    // tranche, ou pire, servir les octets d'à côté.
    let image = elf(
        0x1000,
        &[(1, 0x20_0000, 0x1000, 0x1000, 1_000_000, 1_000_000)],
    );
    assert!(
        loads(&image).is_none(),
        "un segment qui sort du fichier n'est pas lisible"
    );
}

#[test]
fn something_that_is_not_an_elf_is_refused() {
    assert!(loads(b"MZ\x90\x00 ce n'est pas un ELF").is_none());
    assert!(loads(&[]).is_none());
    // Un ELF 32 bits : le lecteur ne sait pas le lire, et le dire vaut mieux
    // que décoder ses en-têtes comme s'ils faisaient soixante-quatre bits.
    let mut small = elf(0x1000, &[(1, 0, 0x1000, 0x1000, 16, 16)]);
    small[4] = 1; // ELFCLASS32
    assert!(loads(&small).is_none());
}

/// **La page zéro que le montage pose, et ce qu'un noyau y lit.**
///
/// `--example kernel-entry` n'en posait aucune : « le montage est fait pour
/// échouer d'abord ». Il a échoué là où il devait — `extend_brk`, le
/// `BUG_ON(_brk_start == 0)`, dernière issue d'`alloc_low_pages` quand memblock
/// n'a rien, parce que la carte e820 était vide et que le noyau ne connaissait
/// que les 640 Kio du repli BIOS-88.
///
/// Les décalages viennent de `struct boot_params` et ne se déduisent d'aucune
/// règle : le compteur e820 à `0x1e8`, la table à `0x2d0` par entrées de vingt
/// octets, `type_of_loader` à `0x210`, `loadflags` à `0x211`, `cmd_line_ptr` à
/// `0x228`. Un octet posé à côté donne un noyau qui croit n'avoir aucune RAM,
/// sans rien dire. **Et rien d'autre n'est écrit** : une page zéro qui porterait
/// un champ de plus ferait croire au noyau à un chargeur qu'il n'a pas eu.
#[test]
fn the_zero_page_declares_the_ram_and_names_its_loader() {
    use wisq_vm::kernel_image::zero_page;
    const RAM: u64 = 64 * 1024 * 1024;
    const COMMAND_LINE: u32 = 0x9800;
    let page = zero_page(RAM, COMMAND_LINE);
    assert_eq!(page.len(), 4096, "une page, exactement");

    let byte = |at: usize| page[at];
    let dword = |at: usize| u32::from_le_bytes(page[at..at + 4].try_into().unwrap());
    let qword = |at: usize| u64::from_le_bytes(page[at..at + 8].try_into().unwrap());
    // Deux entrées : sous le trou du premier mégaoctet, et tout le reste.
    assert_eq!(byte(0x1e8), 2, "deux entrées e820");
    assert_eq!(
        (qword(0x2d0), qword(0x2d8), dword(0x2e0)),
        (0, 0x9fc00, 1),
        "la mémoire basse, utilisable, jusqu'à la zone des données du BIOS"
    );
    assert_eq!(
        (qword(0x2e4), qword(0x2ec), dword(0x2f4)),
        (0x10_0000, RAM - 0x10_0000, 1),
        "et tout ce qui est au-dessus du mégaoctet, jusqu'au bout de la RAM"
    );
    assert_eq!(byte(0x210), 0xff, "un chargeur non enregistré");
    assert_eq!(
        byte(0x211) & 0x81,
        0x81,
        "LOADED_HIGH et CAN_USE_HEAP : le noyau est au-dessus du mégaoctet"
    );
    assert_eq!(
        dword(0x228),
        COMMAND_LINE,
        "où la ligne de commande est posée"
    );

    // **Rien d'autre.** Les champs écrits sont retirés ; ce qui reste doit être
    // nul, sans quoi le noyau lirait un champ que personne n'a voulu.
    let written: [(usize, usize); 5] =
        [(0x1e8, 1), (0x210, 2), (0x228, 4), (0x2d0, 20), (0x2e4, 20)];
    let stray: Vec<usize> = (0..page.len())
        .filter(|at| {
            page[*at] != 0
                && !written
                    .iter()
                    .any(|(from, len)| (from..&(from + len)).contains(&at))
        })
        .collect();
    assert!(
        stray.is_empty(),
        "des octets écrits hors des champs voulus : {stray:x?}"
    );
}

/// **Le noyau se taisait juste au moment où il avait le plus à dire.**
///
/// La ligne de commande du montage ne demandait qu'`earlycon`. C'est une
/// console de **démarrage** : dès que la vraie console s'enregistre — la
/// console d'écran, `tty0`, qui existe même sans écran — Linux désenregistre
/// la première et bascule dessus. Le relevé le montrait en toutes lettres sans
/// que personne le lise :
///
/// ```text
/// printk: console [tty0] enabled
/// printk: bootconsole [uart8250] disabled
/// ```
///
/// Après ces deux lignes, la machine avançait encore mais **le port série
/// était muet**, et le silence ressemblait à un arrêt. C'est un défaut du
/// montage de mesure, pas du noyau : `web/host.js` n'écoute que `0x3f8`, et
/// `tty0` n'y écrit rien.
///
/// **Ce que `keep_bootcon` a fait apparaître, six lignes, mesurées** :
///
/// ```text
/// APIC disabled by BIOS
/// Failed to register legacy timer interrupt
/// APIC: Keep in PIC mode(8259)
/// tsc: Unable to calibrate against PIT
/// tsc: No reference (HPET/PMTIMER) available
/// tsc: Marking TSC unstable due to could not calculate TSC khz
/// ```
///
/// Le noyau nomme lui-même ce qui lui manque. Jusque-là, le mur de l'horloge
/// se **déduisait** d'une adresse — un saut conditionnel vers lui-même dans
/// `calibrate_delay` ; maintenant il se lit.
///
/// **Et le port est vérifié des deux côtés.** Une ligne de commande qui
/// nommerait un port que `web/host.js` n'écoute pas ne rendrait pas une erreur,
/// elle rendrait un silence — exactement le défaut que ce test existe pour
/// empêcher. Les deux fichiers sont donc comparés l'un à l'autre plutôt que
/// chacun à une constante écrite deux fois.
#[test]
fn the_mount_keeps_the_boot_console_on_the_port_the_host_listens_to() {
    let mut root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf();
    while !root.join("Cargo.lock").exists() {
        root = root.parent().expect("la racine du dépôt").to_path_buf();
    }
    let host = std::fs::read_to_string(root.join("web/host.js")).expect("web/host.js");
    let port = host
        .lines()
        .find_map(|line| line.strip_prefix("const SERIAL = "))
        .map(|rest| rest.trim_end_matches(';').trim().to_string())
        .expect("`web/host.js` doit déclarer le port série qu'il écoute");
    assert!(
        MONTAGE_COMMAND_LINE.contains(&format!("earlycon=uart8250,io,{port}")),
        "le montage doit brancher la console précoce sur le port que l'hôte \
         écoute ({port}) : « {MONTAGE_COMMAND_LINE} »"
    );
    assert!(
        MONTAGE_COMMAND_LINE
            .split_whitespace()
            .any(|arg| arg == "keep_bootcon"),
        "et la garder après que `tty0` s'enregistre, sans quoi le noyau se tait \
         au milieu de son démarrage : « {MONTAGE_COMMAND_LINE} »"
    );
}

/// **Le montage de l'émetteur déclarait un écran à la vue, et les mêmes octets
/// au noyau comme mémoire libre.**
///
/// `desktop::Screen` traverse le C ABI, la page et la boucle hôte : la vue sait
/// où peindre. `zero_page` ne le savait pas — deux entrées e820, toutes deux
/// utilisables, et pas un octet de `screen_info`. Le noyau distribuait donc à
/// qui voulait les pages que la vue peignait, et n'avait aucun moyen de savoir
/// qu'il y avait un écran.
///
/// Son jumeau Swift, `X86BootLoader`, écrit ces champs depuis #147 et nomme la
/// conséquence en toutes lettres : « un écran non réservé est de la mémoire que
/// le noyau donnera à quelqu'un d'autre ». Les décalages sont les siens, aux
/// mêmes valeurs — **c'est la même page zéro, écrite par deux chargeurs**, et
/// #250 a dû corriger `lfb_size` avant que cette copie soit permise.
///
/// **L'entrée réservée chevauche l'entrée utilisable, et c'est voulu.** Le cadre
/// est au-dessus du mégaoctet, donc dans l'intervalle que la deuxième entrée
/// déclare utilisable. Linux résout un recouvrement dans `e820__update_table` en
/// gardant le **type le plus élevé** des entrées qui se recouvrent, et
/// `E820_TYPE_RESERVED` (2) l'emporte sur `E820_TYPE_RAM` (1). C'est une
/// hypothèse sur le noyau, pas une évidence : elle est écrite ici pour qu'on
/// sache quoi vérifier si un jour l'écran se fait piétiner.
#[test]
fn the_zero_page_reserves_and_describes_the_screen_it_declares() {
    use wisq_vm::desktop::Screen;
    use wisq_vm::kernel_image::zero_page_with_screen;
    const RAM: u64 = 64 * 1024 * 1024;
    const COMMAND_LINE: u32 = 0x9800;
    /// Le sommet de ce que le chargeur a posé : au-dessous, le noyau.
    const FLOOR: u64 = 0x0100_0000;
    let screen = Screen {
        base: 0x0200_0000,
        width: 1024,
        height: 768,
    };
    let page =
        zero_page_with_screen(RAM, COMMAND_LINE, screen, FLOOR).expect("un écran descriptible");
    assert_eq!(page.len(), 4096, "une page, exactement");

    let byte = |at: usize| page[at];
    let word = |at: usize| u16::from_le_bytes(page[at..at + 2].try_into().unwrap());
    let dword = |at: usize| u32::from_le_bytes(page[at..at + 4].try_into().unwrap());
    let qword = |at: usize| u64::from_le_bytes(page[at..at + 8].try_into().unwrap());

    // **Trois entrées, et la troisième est l'écran.** Sans elle, l'allocateur
    // distribue les pages que la vue peint.
    assert_eq!(
        byte(0x1e8),
        3,
        "trois entrées e820 : la basse, la haute, l'écran"
    );
    assert_eq!(
        (qword(0x2f8), qword(0x300), dword(0x308)),
        (
            screen.base,
            u64::from(screen.width) * u64::from(screen.height) * 4,
            2
        ),
        "le cadre, réservé : le noyau le lit, ne l'alloue jamais"
    );

    // **`VIDEO_TYPE_VLFB`, sans quoi tout le reste est ignoré.** Le chemin
    // moderne — `sysfb`, puis `simpledrm` — s'accroche à cette valeur et ne
    // regarde même pas les champs suivants si elle n'y est pas.
    assert_eq!(byte(0x0f), 0x23, "orig_video_isVGA : un cadre linéaire");
    assert_eq!(word(0x12), 1024, "lfb_width");
    assert_eq!(word(0x14), 768, "lfb_height");
    assert_eq!(word(0x16), 32, "lfb_depth : quatre octets par pixel");
    assert_eq!(dword(0x18), 0x0200_0000, "lfb_base");
    assert_eq!(
        dword(0x1c),
        48,
        "lfb_size : la VRAM annoncée, en unités de 64 Kio"
    );
    assert_eq!(
        word(0x24),
        1024 * 4,
        "lfb_linelength : une ligne, en octets"
    );

    // La vérification que le noyau fait lui-même, refaite ici. Voir #250 : le
    // champ est décalé de seize bits pour VIDEO_TYPE_VLFB, et une valeur trop
    // grande passe toujours — d'où la seconde borne.
    let advertised = u64::from(dword(0x1c)) << 16;
    let needed = u64::from(word(0x14)) * u64::from(word(0x24));
    assert!(
        needed <= advertised,
        "le noyau refuserait le cadre : « VRAM smaller than advertised », \
         {needed} octets demandés contre {advertised} annoncés"
    );
    assert!(
        advertised < needed + 65_536,
        "{advertised} octets annoncés pour un cadre de {needed} — \
         le champ est en unités de 64 Kio, pas en octets"
    );

    // XRGB8888 : bleu en bas, vert, rouge, l'octet inutilisé en haut. Se
    // tromper d'ordre rend un bureau aux couleurs inversées, ce qu'aucune
    // assertion de géométrie n'attrape.
    assert_eq!(
        [
            byte(0x26),
            byte(0x27),
            byte(0x28),
            byte(0x29),
            byte(0x2a),
            byte(0x2b),
            byte(0x2c),
            byte(0x2d)
        ],
        [8, 16, 8, 8, 8, 0, 8, 24],
        "la place de chaque couleur dans le mot de trente-deux bits"
    );

    // **Rien d'autre.** Même garde que pour la page sans écran : les champs
    // voulus sont retirés, ce qui reste doit être nul.
    let written: [(usize, usize); 9] = [
        (0x0f, 1),
        (0x12, 6),
        (0x18, 8),
        (0x24, 2),
        (0x26, 8),
        (0x1e8, 1),
        (0x210, 2),
        (0x228, 4),
        (0x2d0, 60),
    ];
    let stray: Vec<usize> = (0..page.len())
        .filter(|at| {
            page[*at] != 0
                && !written
                    .iter()
                    .any(|(from, len)| (from..&(from + len)).contains(&at))
        })
        .collect();
    assert!(
        stray.is_empty(),
        "des octets écrits hors des champs voulus : {stray:x?}"
    );
}

/// **Un écran que la page ne saurait pas décrire est refusé, et le refus dit
/// laquelle des quatre raisons.**
///
/// Les champs de `screen_info` sont étroits et ne le disent pas : `lfb_width` et
/// `lfb_height` sont des `u16`, `lfb_base` un `u32`. Écrire dedans en tronquant
/// donnerait un écran d'une autre taille, à une autre adresse, **sans rien
/// signaler** — la famille de défauts que ce dépôt passe son temps à corriger.
/// Un cadre hors de la RAM déclarée est refusé pour une autre raison : l'entrée
/// e820 décrirait de la mémoire qui n'existe pas.
#[test]
fn a_screen_the_page_could_not_describe_is_refused() {
    use wisq_vm::desktop::Screen;
    use wisq_vm::kernel_image::{zero_page_with_screen, ScreenRefusal};
    const RAM: u64 = 64 * 1024 * 1024;
    const COMMAND_LINE: u32 = 0x9800;
    const FLOOR: u64 = 0x0100_0000;
    let refuse =
        |screen: Screen| zero_page_with_screen(RAM, COMMAND_LINE, screen, FLOOR).unwrap_err();

    assert_eq!(
        refuse(Screen {
            base: 0x0200_0000,
            width: 1024,
            height: 0
        }),
        ScreenRefusal::Empty,
        "un cadre sans hauteur n'a aucun pixel à peindre"
    );
    assert_eq!(
        refuse(Screen {
            base: 0x0200_0000,
            width: 70_000,
            height: 768
        }),
        ScreenRefusal::TooLarge {
            width: 70_000,
            height: 768
        },
        "70 000 ne tient pas dans le u16 de lfb_width : tronqué, il vaudrait 4464"
    );
    assert_eq!(
        refuse(Screen {
            base: 0x1_0000_0000,
            width: 1024,
            height: 768
        }),
        ScreenRefusal::BaseTooHigh {
            base: 0x1_0000_0000
        },
        "lfb_base est un u32 : au-delà de quatre gibioctets l'adresse serait tronquée"
    );
    assert_eq!(
        refuse(Screen {
            base: RAM - 4096,
            width: 1024,
            height: 768
        }),
        ScreenRefusal::OutsideRam {
            top: RAM - 4096 + 1024 * 768 * 4,
            ram: RAM
        },
        "l'entrée e820 décrirait de la mémoire que la machine n'a pas"
    );
    // **Celui-ci tient dans la RAM, et c'est justement le piège.**
    // 4096 x 4096 x 4 fait exactement 64 Mio : il « rentre » dans une machine de
    // 64 Mio en la couvrant entièrement, noyau compris. Un premier jet acceptait
    // ce cadre et le posait à l'adresse zéro ; l'e820 aurait déclaré toute la
    // mémoire réservée. C'est un essai à la main sur le vrai pilote qui l'a
    // montré, pas une relecture.
    assert_eq!(
        refuse(Screen {
            base: 0,
            width: 4096,
            height: 4096
        }),
        ScreenRefusal::WouldOverwrite {
            base: 0,
            floor: FLOOR
        },
        "un cadre qui tient dans la RAM peut tenir par-dessus le noyau"
    );
}
