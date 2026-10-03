//! Compiles the C conformance program against the header and runs it.
//!
//! `include/wisq_vm.h` is hand-written, and a hand-written header is a
//! promise nothing enforces: a signature that drifts from `src/ffi.rs` is
//! not a Rust error, not a Swift error, and not a crash until memory is
//! already wrong — on a phone. This runs the same program that
//! `scripts/test-ios.sh` runs inside a simulator, so the ABI is checked on
//! every commit on Linux rather than only on the macOS job.
//!
//! It skips loudly when a C compiler or the kernel image is missing, which
//! is the same posture as the boot test beside it.

use std::path::{Path, PathBuf};
use std::process::Command;

fn workspace_root() -> PathBuf {
    // CARGO_MANIFEST_DIR is crates/wisq-vm.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("racine de l'espace de travail")
        .to_path_buf()
}

fn kernel_image() -> Option<PathBuf> {
    let candidates = [
        std::env::var("WISQ_LINUX_IMAGE").ok(),
        Some("/tmp/wisq-test-linux-image/Image".to_string()),
    ];
    candidates
        .into_iter()
        .flatten()
        .map(PathBuf::from)
        .find(|path| path.is_file())
}

/// The static library the C program links. `cargo test` builds the rlib but
/// not necessarily the staticlib for this profile, so it is built explicitly.
fn static_library(root: &Path) -> Option<PathBuf> {
    let built = Command::new(env!("CARGO"))
        .args(["build", "--release", "-p", "wisq-vm"])
        .current_dir(root)
        .status()
        .ok()?;
    if !built.success() {
        return None;
    }
    let path = root.join("target/release/libwisq_vm.a");
    path.is_file().then_some(path)
}

#[test]
fn the_c_header_matches_the_library_it_describes() {
    let root = workspace_root();

    let Some(image) = kernel_image() else {
        eprintln!("image Linux absente : définissez WISQ_LINUX_IMAGE pour ce test");
        return;
    };
    let compiler = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
    if Command::new(&compiler).arg("--version").output().is_err() {
        eprintln!("aucun compilateur C ({compiler}) : test d'ABI ignoré");
        return;
    }
    let Some(library) = static_library(&root) else {
        eprintln!("libwisq_vm.a introuvable : test d'ABI ignoré");
        return;
    };

    let out = std::env::temp_dir().join(format!("wisq-abi-{}", std::process::id()));
    let compiled = Command::new(&compiler)
        .args(["-O2", "-Wall", "-Wextra", "-Werror"])
        .arg("-I")
        .arg(root.join("crates/wisq-vm/include"))
        .arg(root.join("crates/wisq-vm/tests/abi/main.c"))
        .arg("-L")
        .arg(library.parent().expect("dossier de la bibliothèque"))
        .args(["-lwisq_vm", "-lpthread", "-ldl", "-lm", "-o"])
        .arg(&out)
        .output()
        .expect("compilation du programme d'ABI");
    assert!(
        compiled.status.success(),
        "l'en-tête ne compile pas contre la bibliothèque :\n{}",
        String::from_utf8_lossy(&compiled.stderr)
    );

    let ran = Command::new(&out)
        .arg(&image)
        .output()
        .expect("exécution du programme d'ABI");
    let _ = std::fs::remove_file(&out);
    assert!(
        ran.status.success(),
        "le programme d'ABI a échoué :\n{}\n{}",
        String::from_utf8_lossy(&ran.stdout),
        String::from_utf8_lossy(&ran.stderr)
    );
    let stdout = String::from_utf8_lossy(&ran.stdout);
    assert!(
        stdout.contains("ABI conforme"),
        "sortie inattendue :\n{stdout}"
    );

    // The throughput line, because it is the only performance figure the
    // repository takes from the Apple toolchain — scripts/test-ios.sh spawns
    // this same program inside a booted iPhone, and what it prints is what the
    // CI log carries. Nothing there would notice the line quietly disappearing,
    // or a clock that returns zero and makes the whole thing vanish behind its
    // guard, so it is checked here where a test can run.
    //
    // No *lower* threshold: a shared runner cannot hold one without flaking, and
    // the number this machine produces has no bearing on the number a phone
    // would. There is an upper one, and it is not decoration — sabotage moved
    // the stopwatch to after the run, which measures nothing, and a "greater
    // than zero" check waved through a throughput of 4 × 10¹⁶ instructions a
    // second. A stopwatch that measures nothing produces an enormous number,
    // not a small one.
    //
    // Ten billion guest instructions a second is impossible by an order of
    // magnitude for any machine this could run on: a core retires perhaps 10¹⁰
    // of its *own* instructions a second at the very best, and an interpreter
    // spends many of those on each guest instruction. Anything above it is a
    // broken clock rather than a fast computer.
    const IMPOSSIBLE_MILLIONS_PER_SECOND: f64 = 10_000.0;
    let throughput = stdout
        .lines()
        .find_map(|line| line.strip_prefix("débit "))
        .and_then(|rest| rest.split(' ').next())
        .and_then(|number| number.parse::<f64>().ok())
        .unwrap_or_else(|| panic!("aucun débit mesuré :\n{stdout}"));
    assert!(
        throughput > 0.0 && throughput < IMPOSSIBLE_MILLIONS_PER_SECOND,
        "débit implausible ({throughput} M inst/s) : le chronomètre ne mesure \
         probablement pas l'exécution\n{stdout}"
    );
}

/// **Le traducteur x86, à travers le même en-tête écrit à la main.**
///
/// Séparé du test de la machine, et sans image de noyau : celui-ci se saute
/// quand l'image manque, et il n'y a aucune raison que le traducteur se saute
/// avec lui — il ne démarre rien, il traduit des octets.
#[test]
fn the_c_header_matches_the_x86_translator() {
    let root = workspace_root();
    let compiler = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
    if Command::new(&compiler).arg("--version").output().is_err() {
        eprintln!("aucun compilateur C ({compiler}) : conformité du traducteur ignorée");
        return;
    }
    let Some(library) = static_library(&root) else {
        eprintln!("libwisq_vm.a introuvable : conformité du traducteur ignorée");
        return;
    };

    let out = std::env::temp_dir().join(format!("wisq-abi-x86-{}", std::process::id()));
    let compiled = Command::new(&compiler)
        .args(["-O2", "-Wall", "-Wextra", "-Werror"])
        .arg("-I")
        .arg(root.join("crates/wisq-vm/include"))
        .arg(root.join("crates/wisq-vm/tests/abi/x86.c"))
        .arg("-L")
        .arg(library.parent().expect("dossier de la bibliothèque"))
        .args(["-lwisq_vm", "-lpthread", "-ldl", "-lm", "-o"])
        .arg(&out)
        .output()
        .expect("compilation du programme d'ABI du traducteur");
    assert!(
        compiled.status.success(),
        "l'en-tête ne décrit pas le traducteur qu'il déclare :\n{}",
        String::from_utf8_lossy(&compiled.stderr)
    );

    // **L'ELF est gravé ici et son chemin passé au programme.** Le fabriquer en
    // C demanderait un **second** constructeur d'ELF — il y en a déjà un dans
    // `tests/kernel_elf.rs` — et deux copies d'un gréement finissent par ne
    // plus décrire la même chose. C'est la même raison qui fait graver l'image
    // ISO ici plutôt qu'en C.
    //
    // Celui-ci est délibérément plus pauvre que l'autre : trois en-têtes dont
    // une `PT_NOTE`, et c'est tout. **Ce n'est pas le lecteur qu'il juge, c'est
    // la frontière.**
    let elf = std::env::temp_dir().join(format!("wisq-abi-elf-{}.bin", std::process::id()));
    std::fs::write(&elf, forged_elf()).expect("graver l'ELF du programme d'ABI");
    let ran = Command::new(&out).arg(&elf).output().expect("exécution");
    let _ = std::fs::remove_file(&out);
    let _ = std::fs::remove_file(&elf);
    assert!(
        ran.status.success(),
        "le traducteur ne se comporte pas comme l'en-tête le promet :\n{}{}",
        String::from_utf8_lossy(&ran.stdout),
        String::from_utf8_lossy(&ran.stderr)
    );
}

/// **Un ELF64 minimal, pour que le programme C ait quelque chose à lire.**
///
/// Trois en-têtes de programme, dont une `PT_NOTE` qu'un lecteur naïf
/// compterait comme chargeable, et un second segment qui porte du **BSS** —
/// quatre cents octets qui existent en mémoire et pas dans le fichier. C'est
/// la distinction qui coûte cher quand on la rate : confondre les deux tailles
/// fait lire hors du fichier, ou laisser un trou là où le noyau attend des
/// zéros.
///
/// Le fichier est **rempli jusqu'à ce que ses en-têtes annoncent**, parce que
/// le lecteur refuse un ELF qui promet plus d'octets qu'il n'en porte — et un
/// refus ici ressemblerait à une frontière cassée.
fn forged_elf() -> Vec<u8> {
    const ENTRY: u64 = 0x0100_0090;
    let headers: [(u32, u64, u64, u64, u64, u64); 3] = [
        (1, 0x1000, 0xffff_ffff_8100_0000, 0x0100_0000, 1000, 1000),
        (4, 0x2000, 0, 0, 32, 32), // PT_NOTE : pas un segment à charger
        (1, 0x3000, 0xffff_ffff_8240_0000, 0x0240_0000, 500, 900),
    ];
    let mut bytes = vec![0u8; 64];
    bytes[0..4].copy_from_slice(&[0x7f, b'E', b'L', b'F']);
    bytes[4] = 2; // ELFCLASS64
    bytes[5] = 1; // petit-boutien
    bytes[16..18].copy_from_slice(&2u16.to_le_bytes()); // ET_EXEC
    bytes[18..20].copy_from_slice(&62u16.to_le_bytes()); // EM_X86_64
    bytes[24..32].copy_from_slice(&ENTRY.to_le_bytes());
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
    bytes.resize(0x3000 + 500, 0);
    bytes
}

/// **Ce que C voit du lecteur d'image de disque optique.**
///
/// Même forme que les deux tests au-dessus : le programme C se compile contre
/// l'en-tête écrit à la main, se lie à la vraie bibliothèque, et vérifie que
/// les deux fonctions se comportent comme il est promis.
///
/// La différence est qu'il lui faut une **image**. Le harnais la grave ici,
/// minimale, et lui passe le chemin. La fabriquer en C demanderait un
/// troisième constructeur d'ISO — après celui de `tests/iso9660.rs` — et trois
/// copies d'un gréement finissent par ne plus décrire la même chose. Celui-ci
/// est délibérément plus pauvre que l'autre : ni bourrage, ni entrée de
/// chargeur, ni intrus. **Ce n'est pas le lecteur qu'il juge, c'est la
/// frontière.**
#[test]
fn the_c_header_matches_the_disc_image_reader() {
    let root = workspace_root();
    let compiler = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
    if Command::new(&compiler).arg("--version").output().is_err() {
        eprintln!("aucun compilateur C ({compiler}) : conformité du lecteur ignorée");
        return;
    }
    let Some(library) = static_library(&root) else {
        eprintln!("libwisq_vm.a introuvable : conformité du lecteur ignorée");
        return;
    };

    let scratch = std::env::temp_dir().join(format!("wisq-abi-iso-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let image = scratch.join("essai.iso");
    std::fs::write(&image, tiny_image()).expect("l'image d'essai");

    let out = scratch.join("programme");
    let compiled = Command::new(&compiler)
        .args(["-O2", "-Wall", "-Wextra", "-Werror"])
        .arg("-I")
        .arg(root.join("crates/wisq-vm/include"))
        .arg(root.join("crates/wisq-vm/tests/abi/iso.c"))
        .arg("-L")
        .arg(library.parent().expect("dossier de la bibliothèque"))
        .args(["-lwisq_vm", "-lpthread", "-ldl", "-lm", "-o"])
        .arg(&out)
        .output()
        .expect("compilation du programme d'ABI du lecteur");
    assert!(
        compiled.status.success(),
        "l'en-tête ne décrit pas le lecteur qu'il déclare :\n{}",
        String::from_utf8_lossy(&compiled.stderr)
    );

    let ran = Command::new(&out)
        .arg(&image)
        .arg(scratch.join("extrait"))
        .output()
        .expect("exécution");
    let stdout = String::from_utf8_lossy(&ran.stdout).to_string();
    let stderr = String::from_utf8_lossy(&ran.stderr).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        ran.status.success(),
        "le lecteur ne se comporte pas comme l'en-tête le promet :\n{stdout}{stderr}"
    );
}

/// **Une image minuscule, gravée pour la frontière et pas pour le lecteur.**
///
/// Un descripteur, une racine, `/boot`, `/boot/syslinux`, un noyau de trois
/// mille octets au motif reconnaissable, un initramfs et une recette. Tout
/// tient dans une poignée de secteurs, et chaque champ est écrit à la main :
/// c'est long, et c'est ce qui permet de le lire.
fn tiny_image() -> Vec<u8> {
    const SECTOR: usize = 2048;
    let mut sectors: Vec<[u8; SECTOR]> = vec![[0u8; SECTOR]; 18];

    let push = |sectors: &mut Vec<[u8; SECTOR]>, bytes: &[u8]| -> (u32, u32) {
        let lba = sectors.len() as u32;
        for chunk in bytes.chunks(SECTOR) {
            let mut sector = [0u8; SECTOR];
            sector[..chunk.len()].copy_from_slice(chunk);
            sectors.push(sector);
        }
        (lba, bytes.len() as u32)
    };

    fn both32(value: u32) -> [u8; 8] {
        let mut out = [0u8; 8];
        out[..4].copy_from_slice(&value.to_le_bytes());
        out[4..].copy_from_slice(&value.to_be_bytes());
        out
    }
    fn both16(value: u16) -> [u8; 4] {
        let mut out = [0u8; 4];
        out[..2].copy_from_slice(&value.to_le_bytes());
        out[2..].copy_from_slice(&value.to_be_bytes());
        out
    }
    fn record(lba: u32, size: u32, directory: bool, name: &[u8], rock: Option<&str>) -> Vec<u8> {
        let mut out = vec![0u8; 33];
        out[2..10].copy_from_slice(&both32(lba));
        out[10..18].copy_from_slice(&both32(size));
        out[25] = if directory { 2 } else { 0 };
        out[28..32].copy_from_slice(&both16(1));
        out[32] = name.len() as u8;
        out.extend_from_slice(name);
        if name.len() % 2 == 0 {
            out.push(0);
        }
        if let Some(rock) = rock {
            out.extend_from_slice(b"NM");
            out.push((5 + rock.len()) as u8);
            out.push(1);
            out.push(0);
            out.extend_from_slice(rock.as_bytes());
        }
        let length = out.len();
        out[0] = length as u8;
        out
    }
    fn directory(own: u32, children: &[Vec<u8>]) -> Vec<u8> {
        let mut out = record(own, SECTOR as u32, true, &[0], None);
        out.extend(record(0, SECTOR as u32, true, &[1], None));
        for child in children {
            out.extend_from_slice(child);
        }
        out
    }

    let kernel: Vec<u8> = (0..3000u32).map(|n| (n % 251) as u8).collect();
    let (kernel_lba, kernel_size) = push(&mut sectors, &kernel);
    let (initrd_lba, initrd_size) = push(&mut sectors, &[0x1f, 0x8b, 0x08, 0x00]);
    let (cfg_lba, cfg_size) = push(
        &mut sectors,
        b"DEFAULT virt\nLABEL virt\n  KERNEL /boot/vmlinuz-virt\n  INITRD /boot/initramfs-virt\n  APPEND modules=loop,squashfs quiet\n",
    );

    let syslinux_lba = sectors.len() as u32;
    let syslinux = directory(
        syslinux_lba,
        &[record(
            cfg_lba,
            cfg_size,
            false,
            b"SYSLINUX.CFG;1",
            Some("syslinux.cfg"),
        )],
    );
    let (syslinux_lba, _) = push(&mut sectors, &syslinux);

    let boot_lba = sectors.len() as u32;
    let boot = directory(
        boot_lba,
        &[
            record(
                kernel_lba,
                kernel_size,
                false,
                b"VMLINUZ_.VIR;1",
                Some("vmlinuz-virt"),
            ),
            record(
                initrd_lba,
                initrd_size,
                false,
                b"INITRAMF.VIR;1",
                Some("initramfs-virt"),
            ),
            record(syslinux_lba, SECTOR as u32, true, b"SYSLINUX", None),
        ],
    );
    let (boot_lba, _) = push(&mut sectors, &boot);

    let root_lba = sectors.len() as u32;
    let root = directory(
        root_lba,
        &[record(boot_lba, SECTOR as u32, true, b"BOOT", None)],
    );
    let (root_lba, _) = push(&mut sectors, &root);

    let mut pvd = [0u8; SECTOR];
    pvd[0] = 1;
    pvd[1..6].copy_from_slice(b"CD001");
    pvd[6] = 1;
    pvd[8..40].fill(b' ');
    pvd[40..72].fill(b' ');
    pvd[40..48].copy_from_slice(b"WISQABI ");
    pvd[80..88].copy_from_slice(&both32(sectors.len() as u32));
    pvd[128..132].copy_from_slice(&both16(SECTOR as u16));
    let root_record = record(root_lba, SECTOR as u32, true, &[0], None);
    pvd[156..156 + root_record.len()].copy_from_slice(&root_record);
    sectors[16] = pvd;

    let mut end = [0u8; SECTOR];
    end[0] = 255;
    end[1..6].copy_from_slice(b"CD001");
    end[6] = 1;
    sectors[17] = end;

    sectors.concat()
}

/// **Le disque, l'arbre de périphériques et la frappe.**
///
/// Ni image de noyau ni dossier inscriptible : ce programme n'a besoin que
/// d'un compilateur, comme celui du traducteur. Il tient les onze fonctions
/// que les trois autres laissaient dehors — neuf pour le disque,
/// `wisq_vm_load_with_tree`, `wisq_vm_send` — plus `wisq_desktop_tlb_pages`,
/// que l'en-tête demande à un hôte d'additionner et qu'aucun C n'avait lue.
#[test]
fn the_c_header_matches_the_disk_and_the_keyboard() {
    let root = workspace_root();
    let compiler = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
    if Command::new(&compiler).arg("--version").output().is_err() {
        eprintln!("aucun compilateur C ({compiler}) : conformité du disque ignorée");
        return;
    }
    let Some(library) = static_library(&root) else {
        eprintln!("libwisq_vm.a introuvable : conformité du disque ignorée");
        return;
    };

    let out = std::env::temp_dir().join(format!("wisq-abi-disk-{}", std::process::id()));
    let compiled = Command::new(&compiler)
        .args(["-O2", "-Wall", "-Wextra", "-Werror"])
        .arg("-I")
        .arg(root.join("crates/wisq-vm/include"))
        .arg(root.join("crates/wisq-vm/tests/abi/disk.c"))
        .arg("-L")
        .arg(library.parent().expect("dossier de la bibliothèque"))
        .args(["-lwisq_vm", "-lpthread", "-ldl", "-lm", "-o"])
        .arg(&out)
        .output()
        .expect("compilation du programme d'ABI du disque");
    assert!(
        compiled.status.success(),
        "l'en-tête ne décrit pas le disque qu'il déclare :\n{}",
        String::from_utf8_lossy(&compiled.stderr)
    );

    let ran = Command::new(&out).output().expect("exécution");
    let _ = std::fs::remove_file(&out);
    assert!(
        ran.status.success(),
        "le disque ne se comporte pas comme l'en-tête le promet :\n{}{}",
        String::from_utf8_lossy(&ran.stdout),
        String::from_utf8_lossy(&ran.stderr)
    );
    // Un programme qui sortirait 0 sans rien vérifier passerait la ligne
    // au-dessus : c'est sa dernière ligne qui dit qu'il est allé au bout.
    let stdout = String::from_utf8_lossy(&ran.stdout);
    assert!(
        stdout.contains("ABI conforme"),
        "sortie inattendue :\n{stdout}"
    );
}

/// **Le périmètre de l'en-tête, et non plus seulement une partie.**
///
/// Les trois tests au-dessus jugent chacun une famille — la machine, le
/// traducteur, le lecteur d'image — et chacun le fait bien. Ce qu'aucun ne
/// disait, c'est **combien de l'en-tête reste dehors**. Il en restait onze
/// fonctions sur trente et une : toute la famille du disque, `load_with_tree`,
/// `send`, et `wisq_desktop_tlb_pages`.
///
/// Onze déclarations écrites à la main que rien ne confrontait à `src/ffi.rs`.
/// L'en-tête, lui, affirmait le contraire en toutes lettres : « a signature
/// that drifts from src/ffi.rs fails that test rather than crashing on a
/// phone ». C'était vrai pour vingt fonctions et faux pour onze, et la
/// différence ne se voyait nulle part — la même forme que les trois tranches
/// d'avant : **une garde qui tient deux copies sur trois laisse la troisième
/// dériver**.
///
/// **Ce que cette garde tient, et ce qu'elle ne tient pas.** Elle tient le
/// périmètre : aucune fonction déclarée ne reste hors d'atteinte d'un
/// programme C. Elle ne tient pas le contrat de chacune — qu'un appel vérifie
/// son résultat, c'est le programme C qui le fait, et c'est le sabotage qui
/// le prouve. Un appel dont personne ne regarde le résultat passerait ici ;
/// c'est pourquoi la garde est le plancher et non le plafond.
///
/// **Elle compte un appel, pas une mention.** Les commentaires et les chaînes
/// sont retirés d'abord : `fprintf(stderr, "ABI: wisq_vm_snapshot a échoué")`
/// nomme la fonction sans l'appeler, et une garde satisfaite par une
/// empreinte au lieu de l'acte est exactement ce qui a survécu six sabotages
/// la semaine dernière.
#[test]
fn every_declared_function_is_exercised_from_c() {
    let root = workspace_root();
    let header = std::fs::read_to_string(root.join("crates/wisq-vm/include/wisq_vm.h"))
        .expect("l'en-tête C");

    // Dans l'en-tête débarrassé de ses commentaires il ne reste que des
    // déclarations et des `#define`. Ceux-ci sont en capitales et ne peuvent
    // donc pas être pris pour des fonctions, qui sont toutes en minuscules.
    let declared = called_names(&header);
    assert!(
        declared.len() >= 31,
        "l'en-tête ne déclare plus que {} fonctions : la surface a reculé",
        declared.len()
    );

    let directory = root.join("crates/wisq-vm/tests/abi");
    let mut exercised = std::collections::BTreeSet::new();
    let mut programs = Vec::new();
    for entry in std::fs::read_dir(&directory).expect("le dossier des programmes d'ABI") {
        let path = entry.expect("une entrée").path();
        if path.extension().is_some_and(|it| it == "c") {
            let source = std::fs::read_to_string(&path).expect("un programme d'ABI");
            exercised.extend(called_names(&source));
            programs.push(path);
        }
    }
    // Le dossier pourrait se vider sans que rien ne le dise : une garde qui
    // lit zéro fichier et n'en tire aucune conclusion est une garde muette.
    assert!(
        programs.len() >= 3,
        "seulement {} programmes C lus dans {}",
        programs.len(),
        directory.display()
    );

    let missing: Vec<&String> = declared.difference(&exercised).collect();
    assert!(
        missing.is_empty(),
        "{} fonctions déclarées par l'en-tête qu'aucun programme C n'appelle :\n{}\n\
         Une signature écrite à la main que rien n'exerce n'est pas vérifiée : elle \
         est crue.",
        missing.len(),
        missing
            .iter()
            .map(|name| format!("  {name}"))
            .collect::<Vec<_>>()
            .join("\n")
    );
}

/// Les noms `wisq_…` **appelés** par une source C : un identifiant suivi d'une
/// parenthèse ouvrante, une fois les commentaires et les chaînes retirés.
///
/// Sur l'en-tête, la même lecture rend les noms **déclarés** — une déclaration
/// a exactement la même forme qu'un appel. Une seule fonction pour les deux
/// côtés de la comparaison, donc, et pas deux lectures qui pourraient diverger.
fn called_names(source: &str) -> std::collections::BTreeSet<String> {
    let bytes: Vec<char> = strip_comments_and_literals(source).chars().collect();
    let mut names = std::collections::BTreeSet::new();
    let mut index = 0;
    while index < bytes.len() {
        let start = index;
        if bytes[index].is_ascii_alphabetic() || bytes[index] == '_' {
            while index < bytes.len()
                && (bytes[index].is_ascii_alphanumeric() || bytes[index] == '_')
            {
                index += 1;
            }
            let name: String = bytes[start..index].iter().collect();
            let mut after = index;
            while after < bytes.len() && bytes[after].is_whitespace() {
                after += 1;
            }
            if name.starts_with("wisq_") && after < bytes.len() && bytes[after] == '(' {
                names.insert(name);
            }
        } else {
            index += 1;
        }
    }
    names
}

/// Retire les commentaires C et le contenu des chaînes et des caractères.
///
/// Les échappements comptent : `"\\"` finit la chaîne, `"\""` non. Sans ça,
/// une chaîne se fermerait au mauvais endroit et la moitié du fichier
/// deviendrait du texte.
fn strip_comments_and_literals(source: &str) -> String {
    let source: Vec<char> = source.chars().collect();
    let mut out = String::new();
    let mut index = 0;
    while index < source.len() {
        let two = |at: usize| -> Option<(char, char)> {
            (at + 1 < source.len()).then(|| (source[at], source[at + 1]))
        };
        match two(index) {
            Some(('/', '*')) => {
                index += 2;
                while index + 1 < source.len()
                    && !(source[index] == '*' && source[index + 1] == '/')
                {
                    index += 1;
                }
                index = (index + 2).min(source.len());
                out.push(' ');
            }
            Some(('/', '/')) => {
                while index < source.len() && source[index] != '\n' {
                    index += 1;
                }
                out.push('\n');
            }
            _ if source[index] == '"' || source[index] == '\'' => {
                let quote = source[index];
                index += 1;
                while index < source.len() && source[index] != quote {
                    index += if source[index] == '\\' { 2 } else { 1 };
                }
                index += 1;
                out.push(' ');
            }
            _ => {
                out.push(source[index]);
                index += 1;
            }
        }
    }
    out
}
