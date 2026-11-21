//! **La machine de l'émetteur, telle que l'application la monte.**
//!
//! `examples/kernel-entry.rs` fait tourner la boucle hôte, la carte et
//! l'émetteur de la page sous Bun ; l'application les fait tourner dans un
//! `WKWebView`, et c'est la même machine. Ce module porte ce que les deux ont
//! en commun et que l'application ne peut pas écrire elle-même :
//!
//! - **les fichiers de la page** (`asset`) : `host.js`, `carte.js`,
//!   `page-emitter.js`, `machine.js` et `machine.html`, recopiés dans la
//!   bibliothèque à la compilation, et `wisq_page.wasm` quand la construction
//!   l'a embarqué (`WISQ_PAGE_WASM`, voir `build.rs`) ;
//! - **la page zéro** (`boot_page`) : celle de `kernel-entry`, ligne de
//!   commande, écran de la carte et archive compris, assemblée par les mêmes
//!   fonctions de `kernel_image`.
//!
//! Le reste — lire le noyau, le décompresser, servir l'ISO par plages — est
//! côté Swift (`EmitterMachine`, `EmitterStore`), où vivent les fichiers.
use crate::kernel_image::{
    declare_ramdisk, zero_page, zero_page_with_device_screen, CommandLineRefusal, Ramdisk,
    RamdiskRefusal, ScreenRefusal, COMMAND_LINE_AT, MONTAGE_COMMAND_LINE,
    MONTAGE_COMMAND_LINE_ROOM, ZERO_PAGE_AT,
};

/// La carte des périphériques, dans la page.
pub const CARTE_SCRIPT: &str = include_str!("../../../web/carte.js");
/// L'émetteur de la page, appelé dans le fil de la page.
pub const EMITTER_SCRIPT: &str = include_str!("../../../web/page-emitter.js");
/// Le conducteur : ce qui assemble la boucle, la carte et l'émetteur.
pub const MACHINE_SCRIPT: &str = include_str!("../../../web/machine.js");
/// La page elle-même, un raccord de quelques lignes.
pub const MACHINE_PAGE: &str = include_str!("../../../web/machine.html");

/// **Le module de la page, quand la construction l'a embarqué** : vide sinon.
///
/// Il est compilé pour `wasm32-unknown-unknown` par
/// `scripts/build-page-emitter.sh`, une autre cible que cette bibliothèque :
/// `build.rs` ne le construit pas, il le prend où `WISQ_PAGE_WASM` le désigne
/// (ce que fait `scripts/build-xcframework.sh` pour l'application). Une
/// construction sans lui n'en est pas moins juste : l'application dit alors
/// que la machine de l'émetteur n'est pas dans cette construction, au lieu
/// d'en démarrer une qui n'aurait ni traducteur ni carte.
#[cfg(wisq_page_module)]
pub static PAGE_MODULE: &[u8] = include_bytes!(env!("WISQ_PAGE_WASM_EMBARQUE"));
/// Voir l'autre déclaration : sans `WISQ_PAGE_WASM`, rien d'embarqué.
#[cfg(not(wisq_page_module))]
pub static PAGE_MODULE: &[u8] = &[];

/// **Un fichier de la page, par son nom**, ou rien. Les noms sont ceux que la
/// page importe et que son magasin sert, sans dossier : un nom inconnu n'est
/// pas un fichier vide, c'est une absence.
#[must_use]
pub fn asset(name: &str) -> Option<&'static [u8]> {
    match name {
        "host.js" => Some(crate::desktop::HOST_SCRIPT.as_bytes()),
        "carte.js" => Some(CARTE_SCRIPT.as_bytes()),
        "page-emitter.js" => Some(EMITTER_SCRIPT.as_bytes()),
        "machine.js" => Some(MACHINE_SCRIPT.as_bytes()),
        "machine.html" => Some(MACHINE_PAGE.as_bytes()),
        "wisq_page.wasm" if !PAGE_MODULE.is_empty() => Some(PAGE_MODULE),
        _ => None,
    }
}

/// **Où l'invité voit la mémoire vidéo de la carte de Bochs** : sa BAR0 au
/// départ, `BASE_DE_LA_MEMOIRE_VIDEO` dans `crates/wisq-page/src/carte/ecran.rs`.
/// Répétée ici comme dans `kernel-entry`, parce que ce crate ne dépend pas de
/// la carte ; `machine.js` la relit dans la carte et refuse de partir si les
/// deux diffèrent.
pub const SCREEN_BASE: u64 = 0xE000_0000;

/// Ce que Linux ajoute à une adresse physique de texte pour en faire une
/// adresse virtuelle : `__START_KERNEL_map`, comme dans `kernel-entry`.
pub const KERNEL_MAP: u64 = 0xffff_ffff_8000_0000;

/// **Cette RAM peut-elle porter ce noyau ?** Le jugement de `kernel-entry`
/// (`usable_ram`) : une puissance de deux de pages, assez pour le sommet du
/// noyau (BSS compris), et un repli qui amène l'adresse **virtuelle** que le
/// noyau réclamera une fois CR3 chargé (`entry + KERNEL_MAP`) sur son adresse
/// physique. Sous 32 Mio le noyau ne tient pas ; à 4 Gio, le repli rate.
pub fn usable(pages: u32, entry: u64, top: u64) -> Result<(), crate::x86_wasm::RamRefusal> {
    crate::x86_wasm::usable_ram(pages, entry.wrapping_add(KERNEL_MAP), entry, top)
}

/// **La ligne que le noyau lit dans la machine de l'application** : celle du
/// montage, puis celle de l'image **telle quelle**.
///
/// **Pas par `montage_command_line`.** Celle-là est l'instrument de
/// `kernel-entry` : un mot qui commence par `-` y est un retrait, et un
/// retrait qui n'enlève rien est refusé. C'est juste pour `WISQ_CMDLINE`, que
/// quelqu'un tape ; c'est faux pour la ligne d'une image, qui n'a jamais
/// entendu parler de cette syntaxe. `---` est le séparateur des recettes
/// Ubuntu et Debian (« boot=casper quiet splash --- »), `--` celui des
/// arguments d'init : la ligne de l'image passait par la syntaxe de retrait,
/// et une ISO qui les portait ne s'ouvrait pas, sous un refus qui parlait de
/// la page zéro.
///
/// **`keep_bootcon` part quand l'image nomme `console=ttyS0`** — le port
/// 0x3f8, celui de `earlycon` ([`names_the_early_console_port`]). Les deux
/// ensemble font écrire la console précoce et la vraie sur le même port, et
/// chaque ligne arrive deux fois — #306 l'a mesuré (367 lignes contre 222), et
/// la course d'Alpine de la tranche précédente en portait les doubles. Sans
/// console nommée sur le série, `keep_bootcon` reste : c'est lui qui garde la
/// console précoce une fois la vraie (`tty0`, qui n'écrit nulle part) en
/// place, et sans lui le noyau se tairait au milieu de son démarrage. Il reste
/// aussi quand l'image nomme **un autre** port série (`console=ttyS1`) : la
/// console précoce, sur 0x3f8, serait rendue à l'arrivée de `ttyS1`, et la
/// sortie de 0x3f8 se tairait.
///
/// Refusée seulement quand elle ne peut pas être posée : un octet nul, ou plus
/// long que la place que la page zéro lui laisse.
pub fn command_line(image: Option<&str>) -> Result<String, CommandLineRefusal> {
    let image = image.unwrap_or_default().trim();
    if image.as_bytes().contains(&0) {
        return Err(CommandLineRefusal::EmbeddedNul);
    }
    let serial = image.split_whitespace().any(names_the_early_console_port);
    let mut line: Vec<&str> = MONTAGE_COMMAND_LINE
        .split_whitespace()
        .filter(|&word| !(serial && word == "keep_bootcon"))
        .collect();
    if !image.is_empty() {
        line.push(image);
    }
    let line = line.join(" ");
    if line.len() > MONTAGE_COMMAND_LINE_ROOM {
        return Err(CommandLineRefusal::TooLong {
            bytes: line.len(),
            room: MONTAGE_COMMAND_LINE_ROOM,
        });
    }
    Ok(line)
}

/// **Ce mot nomme-t-il `ttyS0` comme console**, comme le noyau le lit ?
///
/// Le découpage de `console_setup` (`kernel/printk/printk.c`) : un nom qui
/// commence par un chiffre est un `ttyS` (`console=0` est `ttyS0`) ; le nom
/// s'arrête au premier chiffre ou à la première virgule, et l'index est le
/// nombre qui suit, zéro s'il n'y en a pas. `ttyS0`, `ttyS0,115200n8`,
/// `ttyS00` sont donc le port 0 ; `ttyS01` et `ttyS10` ne le sont pas — un
/// simple préfixe `console=ttyS0` les y aurait mis. Une console nommée par
/// son périphérique (`console=00:01.0`, un deux-points) n'a pas d'index :
/// ce n'est pas `ttyS0` par son nom.
fn names_the_early_console_port(word: &str) -> bool {
    let Some(value) = word.strip_prefix("console=") else {
        return false;
    };
    if value.contains(':') {
        return false;
    }
    let name = if value.starts_with(|c: char| c.is_ascii_digit()) {
        format!("ttyS{value}")
    } else {
        value.to_string()
    };
    let cut = name
        .find(|c: char| c.is_ascii_digit() || c == ',')
        .unwrap_or(name.len());
    let (device, rest) = name.split_at(cut);
    // L'index : les chiffres qui suivent le nom, tous des zéros (ou aucun).
    let index_is_zero = rest
        .bytes()
        .take_while(u8::is_ascii_digit)
        .all(|digit| digit == b'0');
    device == "ttyS" && index_is_zero
}

/// Pourquoi la page zéro ne peut pas être écrite.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// La RAM n'est pas une puissance de deux de pages, ou n'en a aucune : le
    /// repli de l'émetteur est un masque.
    RamIsNotAPowerOfTwo(u32),
    /// La ligne de commande ne tient pas, ou porte un octet nul.
    CommandLine(CommandLineRefusal),
    /// L'écran ne peut pas être décrit au noyau.
    Screen(ScreenRefusal),
    /// L'archive ne peut pas être décrite au noyau.
    Ramdisk(RamdiskRefusal),
}

/// **La page zéro de la machine de l'émetteur**, ligne de commande comprise :
/// quatre kibioctets à poser à [`ZERO_PAGE_AT`].
///
/// - la ligne est celle du montage suivie de `extra`, la ligne de l'image,
///   telle quelle ([`command_line`]), posée à [`COMMAND_LINE_AT`], dans la
///   page ;
/// - `screen`, quand il est donné, décrit la mémoire vidéo de la carte, hors
///   de la RAM (`zero_page_with_device_screen`) ;
/// - `initramfs` est dit au noyau, au-dessus de `floor` (le sommet du noyau)
///   et sous le bout de la RAM — l'écran n'y prend rien.
pub fn boot_page(
    pages: u32,
    extra: Option<&str>,
    screen: Option<(u32, u32)>,
    initramfs: Option<Ramdisk>,
    floor: u64,
) -> Result<Vec<u8>, Refusal> {
    if pages == 0 || !pages.is_power_of_two() {
        return Err(Refusal::RamIsNotAPowerOfTwo(pages));
    }
    let ram = u64::from(pages) * 65536;
    let line = command_line(extra).map_err(Refusal::CommandLine)?;
    let mut page = match screen {
        None => zero_page(ram, COMMAND_LINE_AT as u32),
        Some((width, height)) => zero_page_with_device_screen(
            ram,
            COMMAND_LINE_AT as u32,
            crate::desktop::Screen {
                base: SCREEN_BASE,
                width,
                height,
            },
        )
        .map_err(Refusal::Screen)?,
    };
    // La ligne, dans la page, terminée par un zéro : `command_line` l'a déjà
    // bornée à la place qu'elle a.
    let at = (COMMAND_LINE_AT - ZERO_PAGE_AT) as usize;
    page[at..at + line.len()].copy_from_slice(line.as_bytes());
    page[at + line.len()] = 0;
    if let Some(archive) = initramfs {
        declare_ramdisk(&mut page, archive, floor, ram).map_err(Refusal::Ramdisk)?;
    }
    Ok(page)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn le32(page: &[u8], at: usize) -> u32 {
        u32::from_le_bytes(page[at..at + 4].try_into().expect("quatre octets"))
    }

    #[test]
    fn the_boot_page_carries_the_line_the_screen_and_the_archive() {
        let archive = Ramdisk {
            at: 0x0400_0000,
            bytes: 0x1234,
        };
        let page = boot_page(
            16384,
            Some("console=ttyS0 quiet"),
            Some((1280, 800)),
            Some(archive),
            0x0300_0000,
        )
        .expect("la page");
        assert_eq!(page.len(), 4096);
        let at = (COMMAND_LINE_AT - ZERO_PAGE_AT) as usize;
        // `keep_bootcon` est parti : l'image nomme `console=ttyS0`.
        let line = b"earlycon=uart8250,io,0x3f8 console=ttyS0 quiet\0";
        assert_eq!(
            &page[at..at + line.len()],
            line,
            "la ligne du montage, puis celle de l'image"
        );
        assert_eq!(le32(&page, 0x228), COMMAND_LINE_AT as u32, "cmd_line_ptr");
        assert_eq!(page[0x0f], 0x23, "VIDEO_TYPE_VLFB");
        assert_eq!(le32(&page, 0x18), SCREEN_BASE as u32, "lfb_base : la carte");
        assert_eq!(
            (le32(&page, 0x218), le32(&page, 0x21c)),
            (0x0400_0000, 0x1234),
            "ramdisk_image et ramdisk_size"
        );
        // Deux entrées e820, la RAM entière au-dessus du mégaoctet : l'écran
        // n'y prend rien, il est hors de la RAM.
        assert_eq!(page[0x1e8], 2);
        assert_eq!(
            u64::from_le_bytes(page[0x2d0 + 28..0x2d0 + 36].try_into().expect("huit")),
            (16384u64 << 16) - 0x10_0000
        );
    }

    /// **La ligne d'une image passe telle quelle**, ses `---` et ses `--`
    /// compris : ce sont les séparateurs des recettes Ubuntu et Debian, et
    /// celui des arguments d'init, pas des retraits.
    #[test]
    fn the_image_line_passes_as_it_is_dashes_included() {
        for image in [
            "boot=casper quiet splash ---",
            "vga=788 --- quiet",
            "init=/bin/sh -- -x",
            "-keep_bootcon",
        ] {
            assert_eq!(
                command_line(Some(image)),
                Ok(format!("{MONTAGE_COMMAND_LINE} {image}")),
                "« {image} »"
            );
            let page = boot_page(16384, Some(image), None, None, 0).expect("la page");
            let at = (COMMAND_LINE_AT - ZERO_PAGE_AT) as usize;
            let line = format!("{MONTAGE_COMMAND_LINE} {image}\0");
            assert_eq!(&page[at..at + line.len()], line.as_bytes(), "« {image} »");
        }
        // Rien, ou des blancs : la ligne du montage seule.
        assert_eq!(command_line(None), Ok(MONTAGE_COMMAND_LINE.to_string()));
        assert_eq!(
            command_line(Some("  ")),
            Ok(MONTAGE_COMMAND_LINE.to_string())
        );
    }

    /// **`keep_bootcon` part quand l'image nomme le série**, sous toutes ses
    /// formes, et reste sinon : avec, chaque ligne arrive deux fois ; sans
    /// console nommée sur le série, il garde la seule qui écrit quelque part.
    #[test]
    fn keep_bootcon_leaves_when_the_image_names_the_serial_console() {
        for image in [
            "console=ttyS0",
            "console=ttyS0,115200",
            "root=/dev/vda console=tty0 console=ttyS0,115200n8 rw",
            // Comme le noyau les lit : l'index 00 est 0, et un nom qui
            // commence par un chiffre est un `ttyS`.
            "console=ttyS00",
            "console=0,115200",
        ] {
            assert_eq!(
                command_line(Some(image)),
                Ok(format!("earlycon=uart8250,io,0x3f8 {image}")),
                "« {image} »"
            );
        }
        // Un autre port série que celui de `earlycon` garde `keep_bootcon` :
        // sans lui, 0x3f8 se tairait à l'arrivée de `ttyS1`. `ttyS01` est le
        // port 1, pas le 0 suivi d'un 1.
        for image in [
            "root=/dev/vda",
            "console=tty0",
            "xconsole=ttyS0",
            "console=ttyS1",
            "console=ttyS1,115200 console=tty0",
            "console=ttyS10,115200",
            "console=ttyS01",
            "console=ttyUSB0",
            "console=00:01.0,115200",
        ] {
            assert_eq!(
                command_line(Some(image)),
                Ok(format!("earlycon=uart8250,io,0x3f8 keep_bootcon {image}")),
                "« {image} »"
            );
        }
    }

    /// La place de la ligne, à l'octet près : le montage et l'image ensemble.
    #[test]
    fn the_line_fills_its_room_and_not_one_byte_more() {
        let prefix = MONTAGE_COMMAND_LINE.len() + 1;
        let fits = "a".repeat(MONTAGE_COMMAND_LINE_ROOM - prefix);
        assert_eq!(
            command_line(Some(&fits)).map(|line| line.len()),
            Ok(MONTAGE_COMMAND_LINE_ROOM)
        );
        let over = "a".repeat(MONTAGE_COMMAND_LINE_ROOM - prefix + 1);
        assert_eq!(
            command_line(Some(&over)),
            Err(CommandLineRefusal::TooLong {
                bytes: MONTAGE_COMMAND_LINE_ROOM + 1,
                room: MONTAGE_COMMAND_LINE_ROOM
            })
        );
        assert_eq!(
            command_line(Some("a\0b")),
            Err(CommandLineRefusal::EmbeddedNul)
        );
    }

    #[test]
    fn what_does_not_fit_is_refused_by_name() {
        assert_eq!(
            boot_page(3, None, None, None, 0),
            Err(Refusal::RamIsNotAPowerOfTwo(3))
        );
        assert!(matches!(
            boot_page(16384, Some("a\0b"), None, None, 0),
            Err(Refusal::CommandLine(_))
        ));
        assert!(matches!(
            boot_page(16384, None, Some((70000, 1)), None, 0),
            Err(Refusal::Screen(ScreenRefusal::TooLarge { .. }))
        ));
        // 64 Mio de RAM : une archive qui finirait au-delà est refusée.
        assert!(matches!(
            boot_page(
                1024,
                None,
                None,
                Some(Ramdisk {
                    at: 0x0300_0000,
                    bytes: 0x0200_0000
                }),
                0x0200_0000
            ),
            Err(Refusal::Ramdisk(RamdiskRefusal::PastCeiling { .. }))
        ));
        // Sous le sommet du noyau, aussi.
        assert!(matches!(
            boot_page(
                16384,
                None,
                None,
                Some(Ramdisk {
                    at: 0x0100_0000,
                    bytes: 16
                }),
                0x0200_0000
            ),
            Err(Refusal::Ramdisk(RamdiskRefusal::BelowFloor { .. }))
        ));
    }

    #[test]
    fn the_ram_must_fold_the_kernel_onto_itself() {
        use crate::x86_wasm::RamRefusal;
        let entry = 0x0100_0000;
        assert_eq!(usable(16384, entry, 0x0300_0000), Ok(()), "1 Gio");
        assert_eq!(usable(32768, entry, 0x0300_0000), Ok(()), "2 Gio");
        assert!(matches!(
            usable(65536, entry, 0x0300_0000),
            Err(RamRefusal::FoldMisses {
                folded: 0x8100_0000
            })
        ));
        assert!(matches!(
            usable(512, entry, 0x0300_0000),
            Err(RamRefusal::TooSmall { .. })
        ));
        assert_eq!(usable(3000, entry, 0), Err(RamRefusal::NotAPowerOfTwo));
    }

    #[test]
    fn the_page_files_are_the_ones_on_disk() {
        for (name, path) in [
            ("host.js", "host.js"),
            ("carte.js", "carte.js"),
            ("page-emitter.js", "page-emitter.js"),
            ("machine.js", "machine.js"),
            ("machine.html", "machine.html"),
        ] {
            let disk = std::fs::read(
                std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../../web")
                    .join(path),
            )
            .expect("le fichier");
            assert_eq!(asset(name), Some(disk.as_slice()), "{name}");
        }
        assert_eq!(asset("autre.js"), None);
        assert_eq!(asset("../host.js"), None, "un nom, pas un chemin");
    }

    /// **Le module n'est là que si la construction l'a demandé** : sans
    /// `WISQ_PAGE_WASM`, `wisq_page.wasm` est une absence, pas un fichier
    /// vide ; avec, c'est le fichier désigné, octet pour octet.
    #[test]
    fn the_page_module_is_there_only_when_the_build_asked_for_it() {
        #[cfg(not(wisq_page_module))]
        assert_eq!(asset("wisq_page.wasm"), None);
        #[cfg(wisq_page_module)]
        {
            let disk = std::fs::read(env!("WISQ_PAGE_WASM_EMBARQUE")).expect("le module");
            assert_eq!(asset("wisq_page.wasm"), Some(disk.as_slice()));
            assert_eq!(&disk[..4], b"\0asm");
        }
    }
}
