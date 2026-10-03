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
use wisq_vm::kernel_image::{
    loads, montage_command_line, CommandLineRefusal, COMMAND_LINE_AT, MONTAGE_COMMAND_LINE,
    MONTAGE_COMMAND_LINE_ROOM, ZERO_PAGE_AT,
};

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
/// montage de mesure, pas du noyau : l'hôte n'a pas d'écran de texte, et
/// `tty0` n'écrit pas sur le port série.
///
/// **« `web/host.js` n'écoute que `0x3f8` » disait cette phrase**, et c'était
/// vrai jusqu'à #305 : l'hôte y tient maintenant les huit registres du 16550 et
/// lève IRQ4. Ça ne change rien à ce que ce test mesure — `tty0` est un écran,
/// pas une liaison série, et aucun registre du port ne le ferait parler — mais
/// une raison périmée laissée dans un commentaire se fait recopier.
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

/// **Une mesure devait éditer une constante gardée pour nommer une console.**
///
/// #305 a rendu au port série les huit registres du 16550 et la ligne quatre ;
/// #306 a mesuré ce que l'espace utilisateur en fait. La mesure qui comptait —
/// le message de `/init` sort-il du fil ? — demandait `console=ttyS0` dans la
/// ligne de commande, et il n'y avait aucun moyen de le demander : la ligne est
/// une constante, tenue par le test au-dessus, et la mesure a donc été prise
/// sur une édition **non commise** de cette constante. C'est la pire forme
/// d'instrument : celui qui n'existe pas dans le dépôt, qu'il faut refabriquer
/// de mémoire, et dont rien ne dit s'il a été remis en place.
///
/// `WISQ_CMDLINE` le demande maintenant, comme `WISQ_RAM` demande la RAM. La
/// ligne gardée ne bouge pas ; ce qui s'y ajoute est séparé par une espace et
/// **refusé** quand il ne tiendrait pas où le montage le pose.
#[test]
fn the_mount_command_line_is_untouched_when_a_measurement_adds_nothing() {
    for nothing in [None, Some(""), Some("   "), Some("\t")] {
        assert_eq!(
            montage_command_line(nothing).as_deref(),
            Ok(MONTAGE_COMMAND_LINE),
            "rien à ajouter doit rendre la ligne gardée, à l'octet près : {nothing:?}"
        );
    }
}

/// Et ce qu'on ajoute s'ajoute : une espace, puis le fragment, et la ligne
/// gardée intacte devant.
///
/// **L'espace est exigée.** Sans elle, `console=ttyS0` collé à `keep_bootcon`
/// donnerait `keep_bootconconsole=ttyS0` — un paramètre que le noyau ignore
/// en silence, et une mesure qui rendrait exactement ce qu'elle rendait sans.
/// C'est le défaut que ce test existe pour empêcher, et il est muet par nature.
#[test]
fn a_measurement_can_name_a_console_without_touching_the_guarded_line() {
    let line = montage_command_line(Some("console=ttyS0")).expect("elle tient");
    assert_eq!(line, format!("{MONTAGE_COMMAND_LINE} console=ttyS0"));
    assert!(
        line.split_whitespace().any(|arg| arg == "keep_bootcon"),
        "et la ligne gardée est toujours là, entière : « {line} »"
    );
    assert!(
        line.split_whitespace().any(|arg| arg == "console=ttyS0"),
        "le fragment est un argument à lui, pas un suffixe : « {line} »"
    );
    // Les blancs autour du fragment sont à l'enveloppe, pas au noyau : une
    // variable d'environnement en porte souvent un.
    assert_eq!(
        montage_command_line(Some("  console=ttyS0  ")).expect("elle tient"),
        line,
        "les blancs autour ne font pas une autre ligne"
    );
}

/// **Et une ligne qui ne tiendrait pas est refusée, avec le nombre.**
///
/// Le montage pose la ligne à `0x800` dans la page zéro elle-même, donc elle a
/// la fin de cette page pour elle et rien de plus. Tronquer donnerait au noyau
/// une ligne coupée au milieu d'un paramètre ; déborder écraserait ce qui suit
/// la page. Un refus nommé est la seule réponse qui ne mente pas.
///
/// **La place est dérivée des deux adresses, pas écrite une seconde fois.**
/// C'est la leçon de #289 : un nombre écrit à deux endroits dérive, et celui-ci
/// dépend de l'endroit où le montage pose la ligne.
#[test]
fn a_command_line_that_would_not_fit_where_the_mount_puts_it_is_refused() {
    assert_eq!(
        MONTAGE_COMMAND_LINE_ROOM,
        4096 - (COMMAND_LINE_AT - ZERO_PAGE_AT) as usize - 1,
        "la place est ce qui reste de la page zéro après l'endroit où la ligne \
         est posée, moins l'octet nul qui la termine"
    );
    // **Et c'est aussi la limite du noyau**, à un octet près : `COMMAND_LINE_SIZE`
    // vaut 2048 sur x86-64. Les deux coïncident, et c'est une coïncidence qu'il
    // vaut mieux écrire que découvrir.
    assert_eq!(MONTAGE_COMMAND_LINE_ROOM, 2047);

    let room = MONTAGE_COMMAND_LINE_ROOM;
    let juste = "x".repeat(room - MONTAGE_COMMAND_LINE.len() - 1);
    assert!(
        montage_command_line(Some(&juste)).is_ok(),
        "une ligne qui remplit la place exactement passe"
    );
    let un_de_trop = "x".repeat(room - MONTAGE_COMMAND_LINE.len());
    assert_eq!(
        montage_command_line(Some(&un_de_trop)),
        Err(CommandLineRefusal::TooLong {
            bytes: room + 1,
            room,
        }),
        "un octet de plus est refusé, et le refus porte les deux nombres"
    );
    assert_eq!(
        montage_command_line(Some("console=ttyS0\0keep_bootcon")),
        Err(CommandLineRefusal::EmbeddedNul),
        "un nul au milieu couperait la ligne là, sans rien signaler"
    );
}

/// **Un fragment qui ne fait qu'ajouter ne refait pas la mesure de #306.**
///
/// La forme mesurée est `console=ttyS0` **à la place** de `keep_bootcon` : les
/// deux ensemble font écrire les deux consoles sur le même port et dédoublent
/// chaque ligne, 367 contre 222. Un `WISQ_CMDLINE` qui n'ajoutait que rendait
/// donc l'autre forme — celle qui a servi — inatteignable, et c'est exactement
/// le défaut que cette tranche-ci reproche à #304 : un instrument qui ne refait
/// pas la mesure dont il porte le nom.
///
/// Un `-` devant un argument l'enlève.
#[test]
fn a_measurement_can_take_an_argument_out_as_well_as_put_one_in() {
    assert_eq!(
        montage_command_line(Some("-keep_bootcon console=ttyS0")).expect("elle tient"),
        "earlycon=uart8250,io,0x3f8 console=ttyS0",
        "la forme que #306 a mesurée, et qui ne dédouble rien"
    );
    // L'ordre dans le fragment n'a pas d'importance : le retrait porte sur la
    // ligne gardée, l'ajout vient après elle.
    assert_eq!(
        montage_command_line(Some("console=ttyS0 -keep_bootcon")).expect("elle tient"),
        "earlycon=uart8250,io,0x3f8 console=ttyS0"
    );
    assert_eq!(
        montage_command_line(Some("-keep_bootcon")).expect("elle tient"),
        "earlycon=uart8250,io,0x3f8",
        "et un retrait seul laisse la ligne sans espace en trop"
    );
}

/// **Et un retrait qui n'enlève rien est refusé.**
///
/// C'est la garde qui compte des deux : `-keepbootcon`, `-keep-bootcon`,
/// `-keep_bootcon=1` sont trois fautes de frappe plausibles, et chacune
/// laisserait la ligne **inchangée**. La mesure rendrait alors ce qu'elle
/// rendait sans le fragment, et ce serait lu comme un résultat. C'est la
/// troisième fois dans ce dépôt qu'un instrument muet est le vrai danger.
#[test]
fn taking_out_an_argument_that_is_not_there_is_refused() {
    for typo in [
        "-keepbootcon",
        "-keep-bootcon",
        "-keep_bootcon=1",
        "-console=ttyS0",
    ] {
        assert_eq!(
            montage_command_line(Some(typo)),
            Err(CommandLineRefusal::NothingToRemove {
                argument: typo[1..].to_string(),
            }),
            "« {typo} » n'enlève rien et doit être refusé plutôt que subi"
        );
    }
    // Et un `-` seul ne désigne aucun argument.
    assert_eq!(
        montage_command_line(Some("-")),
        Err(CommandLineRefusal::NothingToRemove {
            argument: String::new(),
        })
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

    // **`VIDEO_TYPE_VLFB` : un cadre linéaire, et le seul type pour lequel le
    // noyau décale `lfb_size` de seize bits.** Ce qui était écrit ici jusqu'à
    // #260 — « sans quoi tout le reste est ignoré », et « le chemin moderne,
    // `sysfb` puis `simpledrm`, s'accroche à cette valeur » — était faux deux
    // fois : `sysfb` accepte `VIDEO_TYPE_EFI` tout autant, et le chemin qu'il
    // prend ne dépend pas que du type. En revanche ce noyau **porte bien**
    // `simpledrm`, en module — #260 avait conclu le contraire de chaînes
    // absentes de `vmlinux`, et #261 l'a défait. Le couple type + unité est
    // tenu par `the_video_type_and_the_size_unit_are_one_pair`, juste après.
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

/// **Le type vidéo et l'unité de `lfb_size` sont un seul couple, et c'est le
/// couple qui choisit le pilote.**
///
/// `sysfb_create_simplefb` décale la taille de seize bits **pour ce seul
/// type** : `if (si->orig_video_isVGA == VIDEO_TYPE_VLFB) size <<= 16;`.
/// Changer l'un des deux champs sans l'autre ne donne donc pas un écran un peu
/// faux : cela envoie le noyau chez un autre pilote, ou chez aucun.
///
/// **Mesuré (#260, relu par #261)** — trois démarrages du noyau de référence,
/// Alpine 6.6.134-0-lts, à travers l'émetteur, avec un initramfs de cinq
/// kibioctets qui **ne porte aucun module**, et qui ne diffèrent que par ces
/// deux champs :
///
/// | déclaration | ce que le noyau en fait |
/// |---|---|
/// | `VLFB` + unités de 64 Kio | `Console: colour dummy device 80x25`, aucun `fb0` |
/// | `EFI` + unités de 64 Kio | `sysfb: VRAM smaller than advertised`, puis `fb0: EFI VGA frame buffer device` |
/// | `EFI` + octets | `Console: colour dummy device 80x25`, aucun `fb0` |
///
/// **Sans modules, le seul pilote de tampon atteignable est celui qui est
/// intégré : `efifb`.** Et `efifb` ne se lie qu'au périphérique
/// `efi-framebuffer`, que `sysfb` ne pose que si le chemin
/// `simple-framebuffer` a refusé — il refuse ici sur la taille. D'où la
/// deuxième ligne, et sa forme désagréable : l'écran y marche **parce que** la
/// taille est fausse.
///
/// **Ce tableau mesure le montage, pas le noyau — et #260 l'a mal lu.** Il en
/// avait conclu que ce noyau ne portait qu'`efifb`, parce que `simpledrm`,
/// `simplefb` et `vesafb` sont absents des chaînes de `vmlinux`. L'inférence
/// est invalide : `ext4`, `virtio_blk`, `nvme` et `usbcore` en sont absents
/// aussi, parce qu'Alpine en fait des **modules**. Le témoin du 6 septembre
/// 2026, dans `Tests/WisqVMTests/X86BootAttemptTests.swift`, montre
/// `[drm] Initialized simpledrm 1.0.0 for simple-framebuffer.0` sur **ce même
/// noyau**, avec l'initramfs d'Alpine et ses modules. `VLFB` + unités est donc
/// la bonne déclaration ; ce qui manquait à la mesure de #260, ce sont les
/// modules.
///
/// Reste ce que la mesure établit vraiment, et qui vaut d'être su : **un
/// démarrage sans modules n'a pas d'écran**, à moins de déclarer `EFI` — au
/// prix d'une taille fausse.
///
/// Le commentaire que #260 a corrigé, lui, était bien faux : « sans
/// `VIDEO_TYPE_VLFB`, tout le reste est ignoré ». La mesure montre le noyau
/// relire les champs suivants un par un sous `VIDEO_TYPE_EFI` — `efifb: mode is
/// 1024x768x32, linelength=4096` et `Truecolor: size=8:8:8:8, shift=24:16:8:0`
/// sont les octets de wisq, rendus.
#[test]
fn the_video_type_and_the_size_unit_are_one_pair() {
    use wisq_vm::desktop::Screen;
    use wisq_vm::kernel_image::zero_page_with_screen;
    const RAM: u64 = 64 * 1024 * 1024;
    /// Le sommet de ce que le chargeur a posé : au-dessous, le noyau.
    const FLOOR: u64 = 0x0100_0000;
    /// `VIDEO_TYPE_VLFB` — **le seul** type pour lequel le noyau décale.
    const VLFB: u8 = 0x23;
    // 800 × 600 × 4 fait 1 920 000 octets, que 64 Kio ne divise pas : l'arrondi
    // vers le haut de #250 porte quelque chose ici, ce que 1024 × 768 — quarante-huit
    // blocs tout juste — ne demanderait pas.
    let screen = Screen {
        base: 0x0200_0000,
        width: 800,
        height: 600,
    };
    let page = zero_page_with_screen(RAM, 0x9800, screen, FLOOR).expect("un écran descriptible");

    let kind = page[0x0f];
    let word = |at: usize| u16::from_le_bytes(page[at..at + 2].try_into().unwrap());
    let dword = |at: usize| u32::from_le_bytes(page[at..at + 4].try_into().unwrap());

    // La règle du noyau, refaite sur le type que la page déclare vraiment — et
    // non sur celui qu'on croit qu'elle déclare.
    let advertised = if kind == VLFB {
        u64::from(dword(0x1c)) << 16
    } else {
        u64::from(dword(0x1c))
    };
    let needed = u64::from(word(0x14)) * u64::from(word(0x24));
    assert!(
        needed <= advertised,
        "type 0x{kind:02x} : le noyau refuserait le cadre sur son propre \
         « VRAM smaller than advertised » — {needed} octets demandés contre \
         {advertised} annoncés. Sous ce type, l'unité de `lfb_size` est {}.",
        if kind == VLFB {
            "le bloc de 64 Kio"
        } else {
            "l'octet"
        }
    );
    // Et pas trop non plus. Annoncer beaucoup plus que le cadre passe la garde
    // du noyau **en silence**, et c'est exactement ce qui détourne le chemin
    // moderne vers l'ancien : une taille trop petite fait refuser
    // `simple-framebuffer`, une taille trop grande le fait accepter.
    let slack = if kind == VLFB { 0x1_0000 } else { 1 };
    assert!(
        advertised < needed + slack,
        "type 0x{kind:02x} : {advertised} octets annoncés pour un cadre de \
         {needed} — l'unité de `lfb_size` ne correspond pas au type déclaré"
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

/// **Le montage de l'émetteur ne pouvait pas dire au noyau où est son
/// initramfs.**
///
/// `zero_page` écrit cinq champs et pas un de plus — la garde du « rien
/// d'autre » le tient. Ni `ramdisk_image` (0x218) ni `ramdisk_size` (0x21c) n'en
/// font partie, alors que son jumeau Swift les écrit depuis toujours. Le noyau
/// n'avait donc aucun moyen d'apprendre qu'une archive était posée dans sa RAM,
/// et finissait dans `prepare_namespace` sur
/// « VFS: Unable to mount root fs on unknown-block(0,0) » — mesuré à 8 000 000
/// tours, tous les `initcall` passés.
///
/// **La pose est indépendante de celle de l'écran, et c'est voulu.** Ce sont
/// deux champs de `boot_params` sans rapport ; deux fonctions qui écriraient
/// chacune sa moitié de la page finiraient par diverger. Celle-ci s'applique à
/// une page nue comme à une page qui porte déjà un écran.
#[test]
fn the_zero_page_points_the_kernel_at_the_initramfs_it_was_given() {
    use wisq_vm::desktop::Screen;
    use wisq_vm::kernel_image::{declare_ramdisk, zero_page, zero_page_with_screen, Ramdisk};
    const RAM: u64 = 64 * 1024 * 1024;
    const COMMAND_LINE: u32 = 0x9800;
    const FLOOR: u64 = 0x0100_0000;
    let archive = Ramdisk {
        at: 0x0200_0000,
        bytes: 3_000_000,
    };

    let mut page = zero_page(RAM, COMMAND_LINE);
    declare_ramdisk(&mut page, archive, FLOOR, RAM).expect("une archive descriptible");
    let dword = |page: &[u8], at: usize| u32::from_le_bytes(page[at..at + 4].try_into().unwrap());
    assert_eq!(dword(&page, 0x218), 0x0200_0000, "ramdisk_image");
    assert_eq!(dword(&page, 0x21c), 3_000_000, "ramdisk_size");

    // **Rien d'autre que les deux champs, en plus de ce que `zero_page` pose.**
    let written: [(usize, usize); 6] = [
        (0x1e8, 1),
        (0x210, 2),
        (0x218, 8),
        (0x228, 4),
        (0x2d0, 20),
        (0x2e4, 20),
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

    // **Et la même pose sur une page qui porte déjà un écran.** Le plafond est
    // alors la base du cadre, pas le bout de la RAM : l'archive n'a pas le droit
    // d'aller peindre sur l'écran.
    let screen = Screen {
        base: 0x03D0_0000,
        width: 1024,
        height: 768,
    };
    let mut both =
        zero_page_with_screen(RAM, COMMAND_LINE, screen, FLOOR).expect("un écran descriptible");
    declare_ramdisk(&mut both, archive, FLOOR, screen.base).expect("sous le cadre");
    assert_eq!(
        dword(&both, 0x218),
        0x0200_0000,
        "ramdisk_image, avec écran"
    );
    assert_eq!(dword(&both, 0x21c), 3_000_000, "ramdisk_size, avec écran");
    assert_eq!(both[0x0f], 0x23, "et l'écran est toujours déclaré");
    assert_eq!(both[0x1e8], 3, "et ses trois entrées e820 sont intactes");
}

/// **Une archive que la page ne saurait pas décrire est refusée, et le refus dit
/// laquelle des quatre raisons.**
///
/// `ramdisk_image` et `ramdisk_size` sont des `u32`. Le demi-haut de chacun vit
/// dans `ext_ramdisk_image` et `ext_ramdisk_size`, que cette page n'écrit pas —
/// au-delà de quatre gibioctets, écrire en tronquant donnerait au noyau une
/// autre archive, à une autre adresse, **sans rien signaler**.
///
/// Le plafond est demandé plutôt que deviné : c'est le bout de la RAM quand il
/// n'y a pas d'écran, et la base du cadre quand il y en a un. La page zéro ne
/// peut pas le savoir seule.
#[test]
fn a_ramdisk_the_page_could_not_describe_is_refused() {
    use wisq_vm::kernel_image::{declare_ramdisk, zero_page, Ramdisk, RamdiskRefusal};
    const RAM: u64 = 64 * 1024 * 1024;
    const FLOOR: u64 = 0x0100_0000;
    let refuse = |archive: Ramdisk, ceiling: u64| {
        let mut page = zero_page(RAM, 0x9800);
        declare_ramdisk(&mut page, archive, FLOOR, ceiling).unwrap_err()
    };

    assert_eq!(
        refuse(
            Ramdisk {
                at: 0x0200_0000,
                bytes: 0
            },
            RAM
        ),
        RamdiskRefusal::Empty,
        "une archive vide n'est pas une archive"
    );
    assert_eq!(
        refuse(
            Ramdisk {
                at: 0x1_0000_0000,
                bytes: 4096
            },
            0x2_0000_0000
        ),
        RamdiskRefusal::TooHigh { top: 0x1_0000_1000 },
        "ramdisk_image est un u32 : au-delà, l'adresse serait tronquée"
    );
    assert_eq!(
        refuse(
            Ramdisk {
                at: 0x0080_0000,
                bytes: 4096
            },
            RAM
        ),
        RamdiskRefusal::BelowFloor {
            at: 0x0080_0000,
            floor: FLOOR
        },
        "sous le plancher, l'archive écraserait le noyau"
    );
    // **Celui-ci tient dans la RAM, et c'est le piège de #251 à nouveau.**
    // L'archive rentre sous le bout de la mémoire mais déborde sur le cadre :
    // le plafond n'est pas la RAM, c'est la base de l'écran.
    assert_eq!(
        refuse(
            Ramdisk {
                at: 0x03C0_0000,
                bytes: 3_000_000
            },
            0x03D0_0000
        ),
        RamdiskRefusal::PastCeiling {
            top: 0x03C0_0000 + 3_000_000,
            ceiling: 0x03D0_0000
        },
        "tenir dans la RAM ne suffit pas quand un écran occupe le haut"
    );
}
