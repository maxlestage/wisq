//! **Le point d'entrée d'un vrai noyau, exécuté — pas seulement compilé.**
//!
//!     cargo run -p wisq-vm --release --example kernel-entry -- vmlinux.bin [System.map]
//!
//! **Le second argument est facultatif et change tout ce qu'on peut conclure.**
//! Sans lui l'outil rend « rip 0xffffffff81000642 », et la feuille de route a
//! porté une tranche entière un « on ne sait pas si ce `jmp .` est un chemin
//! d'erreur ou une boucle de parking ». Avec la carte du noyau — celle
//! d'Alpine vit dans `boot/System.map-…` de l'ISO *standard*, et il faut
//! **exactement** la version qu'on exécute — la même adresse se lit
//! `__startup_64 + 658`. Ce n'était toujours pas la réponse : le relevé des
//! blocs a montré que cette adresse porte `eb fe` — un `for (;;)` que le noyau
//! écrit derrière une garde sur son argument — et qu'un saut **conditionnel
//! pris** y mène. Une adresse nommée dit où ; il faut un relevé de plus pour
//! dire par où.
//!
//! `coverage` et `first-region` disent ce qui **se traduit**. Depuis la tranche
//! des MSR, ce n'est plus la même chose que ce qui **s'exécute**, et le dépôt
//! le répète sans l'avoir jamais éprouvé sur autre chose que quelques régions
//! écrites à la main. Cet outil pose l'autre question : la région d'entrée
//! d'Alpine, compilée à sa base virtuelle et posée à son adresse physique,
//! tourne-t-elle sous `web/host.js`, et où s'arrête-t-elle ?
//!
//! **Le montage a été fait pour échouer d'abord**, et il a échoué là où il
//! devait : sans `boot_params`, la carte e820 est vide et le noyau s'arrêtait
//! « sur place » dans `extend_brk`, à sa 1067ᵉ région. Depuis, il pose une
//! page zéro — la carte e820 de sa RAM et une ligne de commande qui branche la
//! console 8250 précoce sur le port série — et RSI dessus. Aucune table de
//! pages, aucun descripteur : le noyau construit le reste lui-même. Ce qui
//! compte n'est toujours pas qu'il aille loin, c'est que l'endroit où il
//! s'arrête ait un **nom** — et, depuis la page zéro, qu'il **dise** ce qu'il
//! fait sur `0x3f8`.
//!
//! **Le fichier attendu est la charge utile décompressée**, pas le `bzImage` :
//!
//! ```text
//! python3 -c 'import zlib,sys; d=open(sys.argv[1],"rb").read()[21188:]; \
//!   open(sys.argv[2],"wb").write(zlib.decompressobj(16+zlib.MAX_WBITS).decompress(d))' \
//!   vmlinuz-lts vmlinux.bin
//! ```
//!
//! **Et c'est un ELF.** Chercher le point d'entrée à l'octet 0x90 du fichier
//! décode l'en-tête ELF comme du code — l'erreur a été faite une fois, elle
//! rendait « quatre instructions puis un octet illisible », ce qui ressemblait
//! à un résultat. L'adresse du point d'entrée est **virtuelle** ; le décalage
//! se lit par les en-têtes de programme, et c'est cet outil qui le fait.
use std::io::BufRead;
use std::path::Path;

use wisq_vm::desktop::Screen;
use wisq_vm::kernel_image::{
    declare_ramdisk, loads, zero_page, zero_page_with_screen, Ramdisk, MONTAGE_COMMAND_LINE,
};
use wisq_vm::progress::Progress;
use wisq_vm::symbols::Symbols;
use wisq_vm::x86_wasm::{
    usable_ram, Module, RamRefusal, CONTROL_SLOT, FAULT_SLOT, RIP_SLOT, STOP_SLOT,
};

/// La RAM déclarée, en pages de 64 Kio. **Une puissance de deux**, que le
/// confinement exige, et assez grande pour que le texte du noyau y tienne : il
/// commence à seize mébioctets physiques et en fait une vingtaine.
///
/// Le choix n'est pas neutre et la feuille de route le dit : c'est le **repli**
/// par le masque de la RAM qui fait tomber `0xffffffff81000090` sur
/// `0x1000090`. À quatre gibioctets il ne tomberait plus juste.
const PAGES: u32 = 1024; // 64 Mio

/// **Ce que `WISQ_RAM` déclare, en mébioctets**, quand il est posé.
///
/// Le défaut ne bouge pas : les relevés des tranches précédentes ont été pris à
/// 64 Mio, et les changer en silence rendrait incomparables des mesures que la
/// feuille de route met côte à côte.
///
/// La taille est **refusée** plutôt qu'ajustée quand elle ne peut pas servir —
/// `usable_ram` dit pourquoi. Arrondir à la puissance de deux voisine serait
/// obligeant et faux : le relevé porterait un chiffre que personne n'a demandé.
fn declared_pages() -> Result<u32, String> {
    let Some(value) = std::env::var("WISQ_RAM").ok() else {
        return Ok(PAGES);
    };
    let mib: u64 = value
        .parse()
        .map_err(|_| format!("WISQ_RAM={value} ne se lit pas comme un nombre de mébioctets"))?;
    u32::try_from(mib * 1024 * 1024 / 65536)
        .map_err(|_| format!("WISQ_RAM={mib} est trop grand pour être compté en pages"))
}

/// **L'archive que `WISQ_INITRAMFS` demande, ou aucune.**
///
/// Absente, le montage décrit une machine sans racine — ce qu'il a été jusqu'à
/// cette tranche, et qui se termine par « VFS: Unable to mount root fs on
/// unknown-block(0,0) » une fois tous les `initcall` passés.
///
/// **Elle est posée juste au-dessus du noyau, alignée sur une page.** Le noyau
/// la réserve lui-même dès qu'il la connaît, et la libère après l'avoir
/// déballée ; l'endroit n'a donc pas à survivre, il doit seulement ne marcher
/// sur personne. Le plafond est le cadre s'il y en a un, le bout de la RAM
/// sinon — c'est `declare_ramdisk` qui le vérifie, pas ce code.
fn declared_initramfs(floor: u64) -> Result<Option<(Vec<u8>, Ramdisk)>, String> {
    let Ok(path) = std::env::var("WISQ_INITRAMFS") else {
        return Ok(None);
    };
    let path = path.trim().to_string();
    if path.is_empty() {
        return Ok(None);
    }
    let bytes = std::fs::read(&path).map_err(|why| format!("{path} ne se lit pas : {why}"))?;
    if bytes.is_empty() {
        return Err(format!("{path} est vide : ce n'est pas une archive"));
    }
    let at = (floor + 0xFFF) & !0xFFF;
    let count = bytes.len() as u64;
    Ok(Some((bytes, Ramdisk { at, bytes: count })))
}

/// **L'écran que `WISQ_SCREEN` demande, ou aucun.**
///
/// Absent, le montage décrit une machine sans affichage — ce que toutes les
/// mesures de la feuille de route ont supposé jusqu'ici. `1024x768` en pose un
/// **en haut de la RAM**, aligné sur une page : c'est l'endroit le plus loin du
/// noyau et de sa réserve, et l'entrée e820 qui le protège n'a alors à couvrir
/// que la fin de la mémoire.
///
/// La forme est refusée plutôt que devinée. Un `WISQ_SCREEN` mal écrit qui
/// donnerait silencieusement « pas d'écran » ferait croire à une mesure sans
/// affichage alors qu'on en avait demandé un.
fn declared_screen(ram: u64, floor: u64) -> Result<Option<Screen>, String> {
    let Ok(value) = std::env::var("WISQ_SCREEN") else {
        return Ok(None);
    };
    let value = value.trim();
    if value.is_empty() {
        return Ok(None);
    }
    let Some((width, height)) = value.split_once(['x', 'X']) else {
        return Err(format!(
            "WISQ_SCREEN={value} ne se lit pas : il faut « largeur x hauteur », par exemple 1024x768"
        ));
    };
    let (Ok(width), Ok(height)) = (width.trim().parse::<u32>(), height.trim().parse::<u32>())
    else {
        return Err(format!(
            "WISQ_SCREEN={value} ne se lit pas : les deux nombres doivent être entiers"
        ));
    };
    let bytes = u64::from(width) * u64::from(height) * 4;
    // **Il doit rester au-dessus de ce que le chargeur a posé, pas seulement
    // tenir dans la RAM.** 4096 x 4096 en XRGB8888 fait exactement 64 Mio :
    // sur une machine de 64 Mio il « tient », et se pose à l'adresse zéro,
    // par-dessus le noyau. `zero_page_with_screen` le refuse ; la place est
    // calculée ici, donc la demande se refuse ici aussi, avec la taille qu'il
    // faudrait pour qu'elle passe.
    if bytes == 0 || bytes > ram.saturating_sub(floor) {
        return Err(format!(
            "un cadre {width}x{height} demande {} Kio, et il reste {} Kio \
             au-dessus de ce que le noyau occupe — WISQ_RAM peut l'agrandir",
            bytes / 1024,
            ram.saturating_sub(floor) / 1024
        ));
    }
    // En haut de la RAM, aligné sur une page : le noyau pose son texte en bas.
    Ok(Some(Screen {
        base: (ram - bytes) & !0xFFF,
        width,
        height,
    }))
}

/// Ce que Linux ajoute à une adresse physique de texte pour en faire une
/// adresse virtuelle. `__START_KERNEL_map`, dans ses propres termes.
const KERNEL_MAP: u64 = 0xffff_ffff_8000_0000;

/// **Toute adresse imprimée passe par là.** Un relevé qui rend
/// « rip 0xffffffff81000642 » n'apprend rien à personne : la feuille de route a
/// porté pendant une tranche entière un « on ne sait pas si ce `jmp .` est un
/// chemin d'erreur ou une boucle de parking », alors que la carte du noyau
/// exact était dans l'ISO d'Alpine. Avec elle, l'adresse se lit
/// « __startup_64 + 658 » — la boucle de parking d'un `for (;;)` du noyau,
/// derrière une garde sur son argument. C'était donc bien une des deux
/// réponses envisagées, et le nom seul ne suffisait pas à trancher : il a
/// fallu demander en plus **qui mène là**.
///
/// Sans carte, les adresses sortent nues, comme avant : un outil de diagnostic
/// qui refuse de fonctionner sans son confort casse ce qu'il mesure.
fn name_addresses(text: &str, map: &Symbols) -> String {
    if map.is_empty() {
        return text.to_string();
    }
    text.split_inclusive(char::is_whitespace)
        .map(|word| {
            let bare = word.trim_end();
            let named = bare
                .strip_prefix("0x")
                .and_then(|hex| u64::from_str_radix(hex, 16).ok())
                .map(|address| map.describe_loaded(address, KERNEL_MAP));
            match named {
                Some(named) => format!("{named}{}", &word[bare.len()..]),
                None => word.to_string(),
            }
        })
        .collect()
}

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("le chemin de la charge utile");
    // **La carte est facultative, et son absence se dit.** Un fichier donné
    // mais illisible serait pire que pas de fichier du tout : l'outil
    // imprimerait des adresses nues en laissant croire qu'elles n'ont pas de
    // nom, alors que c'est la carte qui n'a pas été lue.
    let map = match std::env::args().nth(2) {
        Some(path) => {
            let map = std::fs::read_to_string(&path)
                .map(|text| Symbols::parse(&text))
                .unwrap_or_default();
            if map.is_empty() {
                eprintln!("{path} ne porte aucun symbole : les adresses resteront nues");
            }
            map
        }
        None => Symbols::default(),
    };
    let image = std::fs::read(&path).expect("le fichier");
    let Some((entry, segments)) = loads(&image) else {
        eprintln!(
            "{path} n'est pas un ELF. Ce n'est pas le bzImage qu'il faut donner \
             mais sa charge utile décompressée — voir l'en-tête de ce fichier."
        );
        std::process::exit(1);
    };

    // **Le point d'entrée est physique, les segments sont virtuels.** Linux
    // saute à l'adresse physique après la décompression, avant toute table de
    // pages ; l'ELF, lui, est lié pour le demi-haut.
    // **La machine tourne aux adresses PHYSIQUES, et c'est la correction de
    // cette tranche.**
    //
    // Le montage compilait chaque région à sa base *virtuelle*. Tout ce qui est
    // relatif à `%rip` rendait donc du virtuel, alors que la RAM invitée est
    // physique — et le code de démarrage de Linux compte sur le contraire :
    // à `startup_64`, la pagination n'est pas encore la sienne et `%rip` **est**
    // l'adresse physique. `__startup_64` le vérifie lui-même, dès sa quatrième
    // instruction, par `physaddr >> 46` ; l'outil échouait ce test et le noyau
    // se garait dans son propre `for (;;)`, ce qui a coûté une tranche entière
    // à comprendre.
    //
    // **La sonde mesurait donc un chemin que l'application n'emprunte pas** :
    // `X86BootLoader` charge le noyau à `preferredAddress` et saute à
    // `kernelAddress + 0x200`, en physique, depuis toujours. C'est la troisième
    // fois qu'une sonde de ce dépôt mesure autre chose que ce qui tourne.
    let entry_virtual = entry;
    let Some(text) = segments.iter().find(|load| {
        load.physical_address <= entry_virtual
            && entry_virtual < load.physical_address + load.memory_size
    }) else {
        eprintln!("aucun segment ne porte le point d'entrée 0x{entry_virtual:x}");
        std::process::exit(1);
    };
    let physical = text.physical_address;
    let pages = match declared_pages() {
        Ok(pages) => pages,
        Err(why) => {
            eprintln!("{why}");
            std::process::exit(1);
        }
    };
    let ram = u64::from(pages) * 65536;
    // **Le sommet de tout ce qui sera posé**, pas seulement du texte. C'est le
    // BSS du dernier segment qui décide, et il n'est porté par aucun octet du
    // fichier.
    let top = segments
        .iter()
        .map(|load| load.physical_address + load.memory_size)
        .max()
        .unwrap_or(0);
    // **Un refus, pas un avertissement.** Le pilote imprimait « NE TOMBE PAS
    // sur l'adresse physique » et continuait ; le relevé parlait ensuite d'une
    // région introuvable, trois écrans plus loin, sans que rien ne relie les
    // deux. Une machine qui démarre sur une adresse repliée de travers ne se
    // plaint pas : elle s'égare.
    // **L'adresse à replier n'est pas celle de l'ELF.** Pour cette image le
    // point d'entrée est déjà physique — `0x1000090` des deux côtés — et un
    // repli qui le prendrait pour témoin passerait toujours, quelle que soit la
    // taille. Ce que la machine replie pour de vrai, ce sont les adresses
    // **virtuelles** : le noyau bascule à l'adressage virtuel dès que
    // `secondary_startup_64` a chargé CR3, et réclame alors
    // `0xffffffff81000090` pour l'octet qui est à `0x1000090`.
    //
    // La première version de cette garde interrogeait `entry_virtual` et
    // acceptait quatre gibioctets. Elle n'était pas fausse par erreur de
    // calcul : elle mesurait la mauvaise adresse, et un bouchon qui approuve
    // pour une raison qui n'est pas la bonne est pire qu'aucun bouchon.
    let claimed = entry.wrapping_add(KERNEL_MAP);
    if let Err(why) = usable_ram(pages, claimed, entry, top) {
        eprintln!(
            "{} Mio de RAM ne peuvent pas servir à ce noyau : {}",
            ram / (1024 * 1024),
            match why {
                RamRefusal::Empty => "il n'y a pas de machine sans mémoire".to_string(),
                RamRefusal::NotAPowerOfTwo => format!(
                    "{pages} pages n'est pas une puissance de deux, et le confinement \
                     de l'émetteur travaille par masque"
                ),
                RamRefusal::TooSmall { needed } => format!(
                    "le noyau en réclame {:.0} Mio, BSS compris",
                    needed as f64 / (1024.0 * 1024.0)
                ),
                RamRefusal::FoldMisses { folded } => format!(
                    "le repli amène 0x{claimed:x} sur 0x{folded:x} au lieu de \
                     0x{entry:x} — les régions réclamées en virtuel ne seraient \
                     pas trouvées"
                ),
            }
        );
        std::process::exit(1);
    }
    println!("point d'entrée : 0x{entry:x} physique, 0x{entry_virtual:x} virtuel");
    println!(
        "texte : 0x{physical:x} physique, {:.1} Mio, décalage 0x{:x} dans le fichier",
        text.file_size as f64 / (1024.0 * 1024.0),
        text.offset
    );
    let folded = Module::fold(entry_virtual, pages);
    println!(
        "repli sur {} Mio de RAM : 0x{folded:x} — tombe sur l'adresse physique",
        ram / (1024 * 1024)
    );
    // **Traduire la région qui commence à une adresse virtuelle**, en allant
    // chercher ses octets là où le segment les porte.
    // **L'emplacement compte.** L'hôte donne à chaque région une place dans sa
    // table de blocs, et la région y pose les siens. Compiler tout le monde à
    // l'emplacement zéro les fait s'écraser : l'hôte s'en aperçoit, dit « la
    // région n'a posé aucun bloc à l'emplacement N », et c'est cette garde qui
    // a attrapé la première version de cet outil.
    let compile = |at: u64, slot: u32| -> Result<Vec<u8>, String> {
        // **L'adresse réclamée est repliée, comme l'hôte le fait pour lire.**
        // `web/host.js` va chercher ses octets à `address & (base - 1)` ; sans
        // le même repli ici, toute adresse virtuelle était refusée « hors du
        // segment de texte » — et le noyau bascule à l'adressage virtuel dès
        // que `secondary_startup_64` a chargé CR3. L'outil s'arrêtait donc
        // exactement là, sur une région qu'il avait les octets pour traduire.
        let folded = Module::fold(at, pages);
        // **Dans n'importe quel segment, pas seulement le texte.** Une fois
        // les quatre posés, le noyau saute pour de bon dans le dernier :
        // `x86_64_start_kernel` vit à `0xffffffff82a3b700`. Ne chercher que
        // dans le texte rendait « hors du segment de texte » sur une adresse
        // dont les octets étaient là.
        let Some(load) = segments.iter().find(|load| {
            folded >= load.physical_address && folded < load.physical_address + load.file_size
        }) else {
            return Err("hors de tout segment chargeable".to_string());
        };
        let from = (folded - load.physical_address + load.offset) as usize;
        let window = &image[from..(from + 16384).min(image.len())];
        Module::resolving_or_why(window, at, 0, slot, pages).map_err(|why| format!("{why:?}"))
    };

    let Some(bun) = ["/root/.bun/bin/bun", "bun"].into_iter().find(|path| {
        std::process::Command::new(path)
            .arg("--version")
            .output()
            .is_ok()
    }) else {
        println!("Bun est absent : l'exécution n'est pas mesurée. Elle n'est pas nulle, elle est inconnue.");
        return;
    };

    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("la racine")
        .to_path_buf();
    let scratch = std::env::temp_dir().join(format!("wisq-kernel-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    // **Tous les segments, pas seulement le texte.**
    //
    // Le montage n'en posait qu'un, et le noyau en a quatre. `.data` porte
    // `initial_stack`, d'où `secondary_startup_64` charge son pointeur de
    // pile : sans ce segment la lecture rendait zéro, RSP valait zéro, et les
    // empilements descendaient en négatif — `rsp = 0xffffffffffffffe8`, relevé
    // à `secondary_startup_64_no_verify + 339`.
    //
    // Le BSS n'a rien à écrire : une `WebAssembly.Memory` neuve est à zéro, et
    // c'est exactement ce que le BSS demande. Ce qui compte est de ne pas
    // *lire* au-delà du fichier, d'où `file_size` et non `memory_size`.
    let mut placed: Vec<(std::path::PathBuf, u64)> = Vec::new();
    for (index, load) in segments.iter().enumerate() {
        if load.file_size == 0 {
            continue;
        }
        let path = scratch.join(format!("segment{index}.bin"));
        let from = load.offset as usize;
        let to = (load.offset + load.file_size) as usize;
        std::fs::write(&path, &image[from..to]).expect("le segment");
        let bss = if load.memory_size > load.file_size {
            format!(
                " (+ {:.1} Mio de BSS, déjà à zéro)",
                (load.memory_size - load.file_size) as f64 / (1024.0 * 1024.0)
            )
        } else {
            String::new()
        };
        println!(
            "segment {index} : 0x{:x} physique, {:.1} Mio{bss}",
            load.physical_address,
            load.file_size as f64 / (1024.0 * 1024.0)
        );
        placed.push((path, load.physical_address));
    }

    // **La page zéro, et la ligne de commande qu'elle désigne.** Posées là où
    // un chargeur les pose : sous le premier mégaoctet, hors du noyau. Le
    // noyau les recopie chez lui dès `copy_bootdata`, donc l'endroit n'a pas
    // à survivre. Sans cette page, la carte e820 est vide, et le noyau
    // s'arrête « sur place » dans `extend_brk` à sa 1067ᵉ région — c'est
    // écrit dans la feuille de route, et c'est ce que le montage a mesuré
    // tant qu'il n'en posait pas.
    const ZERO_PAGE_AT: u64 = 0x9000;
    const COMMAND_LINE_AT: u64 = 0x9800;
    let ram = u64::from(pages) * 65536;
    // **L'écran est facultatif, et il est éteint par défaut.** Les relevés des
    // tranches précédentes ont été pris sans, et en déclarer un en silence
    // rendrait incomparables des mesures que la feuille de route met côte à
    // côte : le noyau qui voit un cadre linéaire enregistre `simpledrm`, donc
    // traduit d'autres régions et s'arrête ailleurs.
    //
    // `WISQ_SCREEN=1024x768` en pose un en haut de la RAM, aligné sur une page.
    // Le refus est **nommé** plutôt qu'arrondi : un montage qui corrigerait en
    // douce la demande mesurerait autre chose que ce qu'on lui a demandé.
    let page = match declared_screen(ram, top) {
        Ok(None) => zero_page(ram, COMMAND_LINE_AT as u32),
        Ok(Some(screen)) => match zero_page_with_screen(ram, COMMAND_LINE_AT as u32, screen, top) {
            Ok(page) => {
                println!(
                    "écran : 0x{:x}, {}x{} en XRGB8888, {} Kio réservés dans l'e820",
                    screen.base,
                    screen.width,
                    screen.height,
                    u64::from(screen.width) * u64::from(screen.height) * 4 / 1024
                );
                page
            }
            Err(why) => {
                eprintln!("cet écran ne peut pas être décrit au noyau : {why:?}");
                std::process::exit(1);
            }
        },
        Err(why) => {
            eprintln!("{why}");
            std::process::exit(1);
        }
    };
    // **L'archive, si on en demande une.** Le plafond est le cadre quand il y
    // en a un : une archive qui tiendrait dans la RAM peut déborder sur
    // l'écran, et `declare_ramdisk` le refuse plutôt que de l'accepter.
    let mut page = page;
    match declared_initramfs(top) {
        Ok(None) => {}
        Ok(Some((bytes, archive))) => {
            let ceiling = declared_screen(ram, top)
                .ok()
                .flatten()
                .map_or(ram, |screen| screen.base);
            if let Err(why) = declare_ramdisk(&mut page, archive, top, ceiling) {
                eprintln!("cette archive ne peut pas être décrite au noyau : {why:?}");
                std::process::exit(1);
            }
            let at = scratch.join("initramfs.bin");
            std::fs::write(&at, &bytes).expect("l'archive");
            placed.push((at, archive.at));
            println!(
                "initramfs : 0x{:x}, {} Kio — le noyau a une racine à déballer",
                archive.at,
                archive.bytes / 1024
            );
        }
        Err(why) => {
            eprintln!("{why}");
            std::process::exit(1);
        }
    }
    let page_path = scratch.join("zero-page.bin");
    std::fs::write(&page_path, &page).expect("la page zéro");
    placed.push((page_path, ZERO_PAGE_AT));
    let mut line = MONTAGE_COMMAND_LINE.as_bytes().to_vec();
    line.push(0);
    let line_path = scratch.join("cmdline.bin");
    std::fs::write(&line_path, &line).expect("la ligne de commande");
    placed.push((line_path, COMMAND_LINE_AT));
    println!(
        "page zéro : 0x{ZERO_PAGE_AT:x}, e820 sur {} Mio, ligne « {MONTAGE_COMMAND_LINE} »",
        u64::from(pages) / 16
    );

    // **Ce que le pilote JavaScript recevra**, calculé ici plutôt que dans les
    // arguments du `format!` d'après : un `format!` dans un `format!` est
    // refusé par clippy, et il a raison — le texte engendré s'y lit deux fois
    // moins bien.
    let placements = format!(
        "[{}]",
        placed
            .iter()
            .map(|(path, at)| format!("[{:?}, {at}]", path.to_string_lossy()))
            .collect::<Vec<_>>()
            .join(", ")
    );

    // **Une seule exécution, et le pilote va chercher ce qui lui manque.**
    //
    // Il ne pouvait pas appeler l'émetteur — JavaScript d'un côté, Rust de
    // l'autre — alors chaque tour lui donnait l'ensemble des régions déjà
    // traduites et **rejouait le démarrage depuis le début**. C'était
    // quadratique, et longtemps sans importance : l'outil mesure une distance,
    // pas une vitesse. Ça a cessé d'être vrai le jour où la distance s'est mise
    // à dépendre du budget — cinq secondes par tour à la 512ᵉ région, une
    // vingtaine d'heures pour en atteindre quatre mille. Le mur mesuré n'était
    // plus celui du noyau, c'était celui de l'outil.
    //
    // Ce que le pilote ne peut pas appeler, il peut le **lancer** :
    // `Bun.spawnSync` sur `x86-translate` rend une région en quelques
    // millisecondes, et la machine n'est plus jamais rejouée.
    match compile(entry_virtual, 0) {
        Ok(_) => {}
        Err(why) => {
            println!("la région d'entrée ne se traduit pas : {why}");
            std::process::exit(1);
        }
    }

    // **Le manifeste que le traducteur relira**, écrit une fois : le chemin de
    // l'image, la RAM déclarée, puis un segment par ligne. Le refaire à chaque
    // région rouvrirait trente-cinq mébioctets par appel.
    let manifest = scratch.join("manifeste.txt");
    let mut lines = format!("{path}\n{pages}\n");
    for load in &segments {
        lines.push_str(&format!(
            "{} {} {}\n",
            load.physical_address, load.offset, load.file_size
        ));
    }
    std::fs::write(&manifest, lines).expect("le manifeste");

    // **Où le traducteur se trouve.** À côté de cet exemple dans `target`, ou
    // sous la racine. S'il manque, le dire avec la commande qui le construit
    // plutôt que d'échouer sur un `spawnSync` dont le message ne nomme rien.
    let translator = std::env::current_exe()
        .ok()
        .and_then(|exe| {
            exe.parent()
                .and_then(|dir| dir.parent())
                .map(Path::to_path_buf)
        })
        .map(|dir| dir.join("x86-translate"))
        .filter(|at| at.exists())
        .or_else(|| {
            let at = root.join("target/release/x86-translate");
            at.exists().then_some(at)
        });
    let Some(translator) = translator else {
        println!("`x86-translate` n'est pas construit : cargo build -p wisq-vm --release --bin x86-translate");
        std::process::exit(1);
    };
    println!();

    // **Le nombre de tours se règle**, parce qu'il a cessé d'être le mur.
    // Soixante-quatre suffisaient tant que la machine s'arrêtait bien avant ;
    // depuis que la faute de page est délivrée, elle les épuise en avançant
    // encore. `WISQ_ROUNDS=2048` va voir plus loin, au prix d'un relevé plus
    // long à lire.
    let rounds: usize = std::env::var("WISQ_ROUNDS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(64);
    // **Les tours accordés à `vm.run` se règlent aussi**, et séparément : ce
    // sont des retours de main entre régions déjà traduites, pas des
    // traductions. Quatre mille suffisaient tant qu'un mur venait avant ;
    // depuis les registres de débogage, le noyau les épuise dans `mem_init`
    // sans réclamer une seule adresse, et deux mesures — 4096 et 16384 tours
    // de traduction — finissaient au même octet de `__pud_alloc`, parce que
    // ce nombre-ci était écrit en dur. `WISQ_TURNS=65536` va voir plus loin.
    let turns: usize = std::env::var("WISQ_TURNS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(4096);
    let driver = scratch.join("d.mjs");
    {
        std::fs::write(
            &driver,
            format!(
                r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";

let manquante = null;
let place = 0;
// **Combien de régions le pilote s'autorise à traduire.** C'est ce que
// `WISQ_ROUNDS` réglait quand chaque région coûtait une exécution entière ;
// le nom du réglage ne change pas, ce qu'il coûte, si.
let traduites = 0;
const plafond = {rounds};
// **Ce que le noyau écrit sur le port série**, octet par octet. C'est la
// seule voix qu'il a : un `printk` qui aboutit finit sur `0x3f8`, et
// `host.js` l'écoute déjà. Gardé en entier et imprimé à la fin, pour ne pas se
// mêler au relevé.
let serie = "";
const vm = machine({{
  serial: (octet) => {{ serie += String.fromCharCode(octet); }},
  // **Le pilote va chercher l'émetteur au lieu d'attendre le tour suivant.**
  //
  // `x86-translate` rend les octets d'une région en quelques millisecondes.
  // C'est ce qui remplace le rejeu du démarrage — et la seule chose qui a
  // changé de ce côté-ci : la boucle hôte voit toujours une fonction à qui
  // elle donne une adresse et qui rend des octets, ou rien.
  translate: (address, slot) => {{
    if (traduites >= plafond) {{
      if (manquante === null) {{ manquante = address; place = slot; }}
      console.log("plafond 0x" + address.toString(16));
      return null;
    }}
    const out = Bun.spawnSync(
      [{translator:?}, {manifest:?}, address.toString(), String(slot)]
    );
    if (out.exitCode !== 0) {{
      if (manquante === null) {{ manquante = address; place = slot; }}
      console.log("refusée 0x" + address.toString(16) + " emplacement " + slot
        + " " + out.stderr.toString().trim());
      return null;
    }}
    traduites += 1;
    console.log("traduit 0x" + address.toString(16) + " emplacement " + slot
      + " octets " + out.stdout.length);
    return out.stdout;
  }},
  pages: {pages},
}});
for (const [path, at] of {placements}) {{
  new Uint8Array(vm.memory.buffer).set(readFileSync(path), at);
}}
vm.globals[{rip}].value = {entry}n;
// **RSI désigne la page zéro**, comme un chargeur le fait en entrant dans
// `startup_64` : c'est de là que le noyau recopie ses `boot_params`.
vm.globals[6].value = {zero_page}n;
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value);
// **Un tour à la fois, et l'adresse de chaque retour de main comptée.**
// « Tours épuisés » disait combien de fois la machine avait rendu la main,
// pas d'où : quarante et un mille sites modifiés par `text_poke_early` et
// soixante-cinq mille tours, sans savoir si c'est le budget qui est court ou
// un appel indirect qui rend la main à tort vers une région déjà traduite.
// Conduire `vm.run` un tour à la fois ne change rien à ce que la machine
// fait — une faute délivrée ou un `hlt` finissent le tour de la même façon —,
// et permet de lire RIP entre deux tours.
const retours = new Map();
// **Et les douze derniers, dans l'ordre.** Le compte dit *où* la main est
// rendue, pas *après quoi* : deux adresses qui reviennent par paires ne se
// lisent que dans la suite.
const derniers = [];
// **Depuis quand plus rien n'est neuf.** « La machine avançait encore » se
// déduisait du seul fait que le budget s'était épuisé sans qu'une adresse
// manque — ce qu'une boucle qui tourne sans progresser produit à l'identique.
// Ces trois compteurs sont ce qu'il faut pour ne plus le déduire : le tour où
// une adresse a été vue pour la dernière fois *pour la première fois*, et
// l'étroitesse du dernier dixième du budget. `Progress`, côté Rust, les met en
// forme — et refuse de conclure, parce qu'une boucle chaude légitime n'ouvre
// pas de terrain neuf non plus.
let neuf = null;
const queue = new Set();
const debutDeLaQueue = {turns} - Math.floor({turns} / 10);
// **Le vrai indice de tour.** Le relevé imprimait « tour N » en y mettant le
// rang de la traduction, et concluait sur « les N tours du pilote » qui, eux,
// étaient de vrais tours. Le même mot comptait deux choses.
let tours = 0;
let why = {{ stopped: "tours épuisés", at: lire({rip}) }};
for (let tour = 0; tour < {turns}; tour++) {{
  why = await vm.run({{ budget: 1n << 24n, rounds: 1 }});
  tours = tour + 1;
  if (why.stopped !== "tours épuisés") break;
  const at = lire({rip});
  if (!retours.has(at)) neuf = tour + 1;
  retours.set(at, (retours.get(at) ?? 0) + 1);
  if (tour >= debutDeLaQueue) queue.add(at);
  derniers.push(at);
  if (derniers.length > 12) derniers.shift();
}}
console.log("arret " + why.stopped);
console.log("marche " + tours + " " + (neuf === null ? "aucun" : neuf)
  + " " + retours.size + " " + queue.size);
console.log("retours " + [...retours.entries()]
  .sort((a, b) => b[1] - a[1])
  .slice(0, 10)
  .map(([at, n]) => n + " fois 0x" + at.toString(16))
  .join(" ; "));
console.log("derniers " + derniers.map((at) => "0x" + at.toString(16)).join(" ; "));
// **Et ce que l'hôte sait de chacune** : l'emplacement qu'il lui a donné à
// l'installation, et ce que la case de la correspondance tient — l'adresse
// rangée et l'indice. Une adresse installée dont la case porte une autre
// adresse a perdu sa place ; une case intacte qui rend quand même la main
// désigne autre chose que la correspondance.
const cases = [...retours.entries()]
  .sort((a, b) => b[1] - a[1])
  .slice(0, 10)
  .map(([at]) => {{
    const region = vm.known.get(at);
    const slot = vm.tableSlot(at);
    const vue = new DataView(vm.memory.buffer);
    const rangee = vue.getBigUint64(vm.tableBase + slot * 16, true);
    const indice = vue.getInt32(vm.tableBase + slot * 16 + 8, true);
    return "0x" + at.toString(16)
      + " emplacement=" + (region === undefined ? "inconnue" : region.slot)
      + " case=" + (rangee === at ? "intacte" : "0x" + rangee.toString(16))
      + " indice=" + indice;
  }});
console.log("cases " + cases.join(" ; "));
console.log("serie " + JSON.stringify(serie));
console.log("manquante " + (manquante === null ? "aucune" : "0x" + manquante.toString(16)));
console.log("emplacement " + place);
console.log("rip 0x" + lire({rip}).toString(16));
console.log("rsp 0x" + lire(4).toString(16));
// **Ce que la pile porte à l'arrêt, et pourquoi ça vaut d'être imprimé.**
// Le relevé dit où la machine est ; la pile dit d'où elle vient. Huit mots
// suffisent — le montage n'a que trois appels de profondeur — et c'est ce
// qui a permis d'établir qu'un `ret` attendu n'avait pas eu lieu, avant que
// le relevé des blocs n'explique pourquoi.
//
// L'adresse invitée est repliée par masque sur la RAM déclarée, comme
// partout ailleurs : c'est la même arithmétique que l'émetteur, pas une
// seconde façon de traduire.
const vue = new DataView(vm.memory.buffer);
const masque = BigInt({pages}) * 65536n - 1n;
const sommet = Number(lire(4) & masque);
const mots = [];
for (let i = 0; i < 8; i++) {{
  const at = sommet + i * 8;
  mots.push(at + 8 <= vm.memory.buffer.byteLength
    ? "0x" + vue.getBigUint64(at, true).toString(16)
    : "hors-RAM");
}}
console.log("pile " + mots.join(" "));
// **Les seize registres généraux, dans l'ordre du codage x86.** Ils coûtent
// une ligne et ils répondent à la question que la pile ne répond pas : la
// machine s'est-elle garée sur une valeur qu'on lui a donnée ? Un `for (;;)`
// écrit par le noyau derrière un test sur un argument ne se comprend qu'en
// lisant l'argument.
const noms = ["rax","rcx","rdx","rbx","rsp","rbp","rsi","rdi",
              "r8","r9","r10","r11","r12","r13","r14","r15"];
console.log("registres " + noms
  .map((nom, at) => nom + "=0x" + lire(at).toString(16))
  .join(" "));
// **Pourquoi elle s'est arrêtée, et pas seulement où.**
//
// Trois globales que le relevé ne montrait pas, et sans lesquelles « sur
// place » ne dit pas s'il s'agit d'un budget épuisé, d'une faute de page, ou
// d'un `hlt`. La question du moment est de savoir si le module **pagine** :
// le noyau a écrit CR0 et CR3, et ce que le module en fait décide si une
// adresse haute comme `page_offset_base` est traduite ou repliée par masque.
console.log("arret-code " + lire({stop}));
console.log("faute " + lire({fault}));
const controle = ["cr0", "cr2", "cr3", "cr4", "cr8"];
console.log("controle " + controle
  .map((nom, at) => nom + "=0x" + lire({control} + at).toString(16))
  .join(" "));
"#,
                host = root.join("web/host.js").to_string_lossy(),
                placements = placements,
                zero_page = ZERO_PAGE_AT,
                turns = turns,
                rounds = rounds,
                translator = translator.to_string_lossy(),
                manifest = manifest.to_string_lossy(),
                pages = pages,
                rip = RIP_SLOT,
                stop = STOP_SLOT,
                fault = FAULT_SLOT,
                control = CONTROL_SLOT,
                entry = entry_virtual,
            ),
        )
        .expect("le pilote");
    }

    // **Les erreurs du pilote vont dans un fichier**, pas dans un tuyau que
    // personne ne vide : lire sa sortie standard ligne à ligne pendant qu'il
    // tourne et laisser l'autre tuyau se remplir bloquerait les deux.
    let errors_path = scratch.join("erreurs.txt");
    let mut child = std::process::Command::new(bun)
        .arg("run")
        .arg(&driver)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::from(
            std::fs::File::create(&errors_path).expect("le fichier d'erreurs"),
        ))
        .spawn()
        .expect("bun");

    // **Les régions, nommées au fur et à mesure.** Le pilote ne connaît pas la
    // carte des symboles ; il imprime des adresses nues et c'est ici qu'elles
    // prennent un nom, à mesure qu'elles arrivent — un relevé qui n'arriverait
    // qu'à la fin ne dirait pas si la machine avance encore.
    let mut regions: Vec<u64> = Vec::new();
    let mut last = String::new();
    {
        let out = child.stdout.take().expect("la sortie du pilote");
        let hex = |text: &str| u64::from_str_radix(text.trim_start_matches("0x"), 16).ok();
        for line in std::io::BufReader::new(out).lines().map_while(Result::ok) {
            let fields: Vec<&str> = line.split_whitespace().collect();
            match fields.as_slice() {
                ["traduit", at, "emplacement", slot, "octets", size] => {
                    if let Some(at) = hex(at) {
                        println!(
                            "traduction {} : {} régions posées, la machine réclame {} \
                             à l'emplacement {slot} ({size} octets)",
                            regions.len() + 1,
                            regions.len(),
                            map.describe_loaded(at, KERNEL_MAP)
                        );
                        regions.push(at);
                    }
                }
                ["refusée", at, "emplacement", _, why @ ..] => {
                    if let Some(at) = hex(at) {
                        println!(
                            "traduction {} : {} régions posées, et {} **ne se traduit pas** — {}",
                            regions.len() + 1,
                            regions.len(),
                            map.describe_loaded(at, KERNEL_MAP),
                            why.join(" ")
                        );
                    }
                }
                ["plafond", _] => {
                    println!(
                        "après {} régions posées, le plafond de traductions \
                         (WISQ_ROUNDS) est atteint",
                        regions.len()
                    );
                }
                _ => {
                    last.push_str(&line);
                    last.push('\n');
                }
            }
        }
    }
    let status = child.wait().expect("bun");
    let errors = std::fs::read_to_string(&errors_path).unwrap_or_default();
    if !errors.is_empty() {
        println!("le pilote a écrit en erreur");
        print!("{errors}");
    }
    if !status.success() {
        println!("le pilote s'est arrêté sur {status}");
    }
    {
        let line = |name: &str| -> Option<String> {
            last.lines()
                .find_map(|l| l.strip_prefix(name))
                .map(|rest| rest.trim().to_string())
        };
        let missing = line("manquante ").unwrap_or_default();
        if missing == "aucune" {
            let why = line("arret ").unwrap_or_default();
            // **« Tours épuisés » n'est pas « terminé ».** Le pilote accorde
            // `WISQ_TURNS` tours à `vm.run` ; s'ils s'épuisent sans qu'une
            // adresse manque, la machine tournait dans ce qu'elle connaît déjà
            // — un tri, une boucle — et rien ne dit qu'elle s'est arrêtée. Le
            // dire comme la fin a fait prendre `sort_r` pour un mur.
            if why == "tours épuisés" {
                // **Ce que le pilote a le droit de dire, et ce qu'il disait.**
                // « La machine avançait encore » se déduisait du seul fait que
                // le budget s'était épuisé sans qu'une adresse manque — ce
                // qu'une boucle qui tourne sans progresser produit aussi. La
                // ligne `marche` porte maintenant de quoi ne plus le déduire.
                println!(
                    "{} régions, aucune adresse ne manque, et les {turns} tours du \
                     pilote (WISQ_TURNS) sont épuisés",
                    regions.len()
                );
                let walked = line("marche ").unwrap_or_default();
                let seen = (|| {
                    let fields: Vec<&str> = walked.split_whitespace().collect();
                    let [turns, fresh, distinct, tail] = fields.as_slice() else {
                        return None;
                    };
                    let count = |text: &str| text.parse::<usize>().ok();
                    Progress::of(
                        count(turns)?,
                        match *fresh {
                            "aucun" => None,
                            text => Some(count(text)?),
                        },
                        count(distinct)?,
                        count(tail)?,
                    )
                })();
                // **Un comptage qu'on n'a pas eu n'est pas un comptage nul.**
                // Le dire manquant vaut mieux qu'une phrase d'aplomb sur des
                // nombres qui ne sont pas arrivés.
                match seen {
                    Some(seen) => println!("{}", seen.describe()),
                    None => println!(
                        "le pilote n'a pas rendu de comptage de marche lisible : \
                         on ne sait donc pas si la machine ouvrait encore du terrain"
                    ),
                }
            } else {
                println!("{} régions, et plus rien à traduire — {why}", regions.len());
            }
        } else {
            println!(
                "{} régions, et la machine s'est arrêtée sur {}",
                regions.len(),
                match missing
                    .strip_prefix("0x")
                    .and_then(|hex| u64::from_str_radix(hex, 16).ok())
                {
                    Some(at) => map.describe_loaded(at, KERNEL_MAP),
                    None => missing.clone(),
                }
            );
        }
    }
    println!();
    print!("{}", name_addresses(&last, &map));

    // **Et d'où vient l'adresse où elle s'est arrêtée.**
    //
    // Le relevé de la pile disait *où* la machine est ; il ne disait pas
    // *comment* elle y est arrivée, et deux explications tenaient — un saut
    // non pris, ou un bloc terminé sans son saut. C'est cette impasse qui a
    // fait écrire `Module::outline` : il lit les blocs de la même découverte
    // que l'émission, donc ce qu'il dit d'un bloc est ce que le module fait
    // de lui. Poser la question ici, sur les vraies régions, remplace un
    // choix de relecture par une lecture.
    if let Some(stopped) = last
        .lines()
        .find_map(|line| line.strip_prefix("rip 0x"))
        .and_then(|hex| u64::from_str_radix(hex.trim(), 16).ok())
    {
        println!();
        println!("qui mène à {} :", map.describe_loaded(stopped, KERNEL_MAP));
        let mut named = false;
        // Les régions se chevauchent — la même adresse est traduite dans
        // plusieurs fenêtres — donc le même bloc serait nommé plusieurs fois.
        // Ce n'est pas une redite décorative : trois lignes identiques
        // ressemblent à trois chemins, et il n'y en a qu'un.
        let mut seen = std::collections::BTreeSet::new();
        for base in &regions {
            // Le même repli, et il n'est pas décoratif : sans lui cette
            // soustraction sur une base virtuelle ne rendait pas un mauvais
            // nombre, elle **paniquait** — « range start index
            // 18446744071564165438 out of range for slice of length 35842660 ».
            let folded = Module::fold(*base, pages);
            let Some(load) = segments.iter().find(|load| {
                folded >= load.physical_address && folded < load.physical_address + load.file_size
            }) else {
                continue;
            };
            let Ok(from) = usize::try_from(folded - load.physical_address + load.offset) else {
                continue;
            };
            let window = &image[from..(from + 16384).min(image.len())];
            let Ok(blocks) = Module::outline(window, 0) else {
                continue;
            };
            for block in &blocks {
                let target = match block.target {
                    Some(target) => base.wrapping_add(target as u64),
                    None => continue,
                };
                if target != stopped {
                    continue;
                }
                if !seen.insert(base + block.start as u64) {
                    continue;
                }
                named = true;
                println!(
                    "  {} finit sur {:?} vers {}{}",
                    map.describe_loaded(base + block.start as u64, KERNEL_MAP),
                    block
                        .ends
                        .expect("un bloc qui a une cible a un terminateur"),
                    map.describe_loaded(target, KERNEL_MAP),
                    match block.goes {
                        Some(_) => " — dans la même région",
                        None => " — hors région, le module rend la main",
                    }
                );
            }
        }
        if !named {
            println!("  aucun bloc des régions traduites n'y mène par une cible statique.");
            println!("  L'adresse vient donc de la pile, d'une forme indirecte, ou de la reprise après une coupe.");
        }
    }

    let _ = std::fs::remove_dir_all(&scratch);
}
