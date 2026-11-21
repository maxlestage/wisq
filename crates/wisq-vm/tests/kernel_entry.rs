//! **`--example kernel-entry`, lancé : ce que le montage promet au noyau.**
//!
//! L'exemple est l'outil des courses de Void et d'Alpine. Ce qu'il pose à
//! l'entrée et ce que ses variables font n'était tenu par aucun test : CS à
//! `__BOOT_CS` (`0x10`) et les données à `__BOOT_DS` (`0x18`) — la correction
//! du mur « exception précoce refusée parce que CS valait 0 » —, `WISQ_ECRAN`,
//! `WISQ_GESTES`, `WISQ_HEURE`, `WISQ_CAPTURE` et l'ordre de ses couleurs.
//! Remettre `0x10n` à `0x0n` ne faisait rien tomber.
//!
//! Ici, sur un « noyau » de quelques dizaines d'octets, un ELF construit pour
//! la circonstance et chargé à seize mébioctets comme un vrai : il relève CS
//! et DS, lit l'horloge CMOS, pagine pour atteindre la mémoire vidéo de la
//! carte (une page de 1 Gio sur `0xC000_0000`), y peint un pixel rouge et un
//! bleu, attend une touche par l'i8042, et s'arrête.
use std::path::{Path, PathBuf};
use std::process::Command;

fn workspace_root() -> PathBuf {
    let mut at = Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf();
    while !at.join("Cargo.lock").exists() {
        at = at.parent().expect("la racine du dépôt").to_path_buf();
    }
    at
}

/// **L'exemple construit**, dans le profil de ce test : `cargo test` ne
/// construit pas les exemples quand on ne lui demande que ce fichier.
fn kernel_entry() -> PathBuf {
    let root = workspace_root();
    let release = !cfg!(debug_assertions);
    let mut cargo = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()));
    cargo
        .current_dir(&root)
        .args(["build", "-p", "wisq-vm", "--example", "kernel-entry"]);
    if release {
        cargo.arg("--release");
    }
    let output = cargo.output().expect("cargo");
    assert!(
        output.status.success(),
        "l'exemple ne se construit pas :\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let target = std::env::var("CARGO_TARGET_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| root.join("target"));
    target
        .join(if release { "release" } else { "debug" })
        .join("examples/kernel-entry")
}

/// Un ELF64 d'un seul segment chargeable, à `physique`, le point d'entrée à
/// son premier octet — ce que `loads` lit d'un vmlinux.
fn elf(physique: u64, code: &[u8]) -> Vec<u8> {
    let mut bytes = vec![0u8; 64];
    bytes[..4].copy_from_slice(b"\x7fELF");
    bytes[4] = 2; // 64 bits
    bytes[5] = 1; // petit-boutiste
    bytes[16..18].copy_from_slice(&2u16.to_le_bytes()); // ET_EXEC
    bytes[18..20].copy_from_slice(&62u16.to_le_bytes()); // x86-64
    bytes[24..32].copy_from_slice(&physique.to_le_bytes());
    bytes[32..40].copy_from_slice(&64u64.to_le_bytes()); // e_phoff
    bytes[52..54].copy_from_slice(&64u16.to_le_bytes());
    bytes[54..56].copy_from_slice(&56u16.to_le_bytes());
    bytes[56..58].copy_from_slice(&1u16.to_le_bytes());
    let mut header = vec![0u8; 56];
    header[0..4].copy_from_slice(&1u32.to_le_bytes()); // PT_LOAD
    header[8..16].copy_from_slice(&0x1000u64.to_le_bytes());
    header[16..24].copy_from_slice(&(physique + 0xffff_ffff_8000_0000).to_le_bytes());
    header[24..32].copy_from_slice(&physique.to_le_bytes());
    header[32..40].copy_from_slice(&(code.len() as u64).to_le_bytes());
    header[40..48].copy_from_slice(&(code.len() as u64).to_le_bytes());
    bytes.extend_from_slice(&header);
    bytes.resize(0x1000, 0);
    bytes.extend_from_slice(code);
    bytes
}

/// `movabs $valeur,%rax`.
fn rax(code: &mut Vec<u8>, valeur: u64) {
    code.extend_from_slice(&[0x48, 0xb8]);
    code.extend_from_slice(&valeur.to_le_bytes());
}

/// `mov $valeur,(adresse)` sur huit octets, par RAX et RDI.
fn poser(code: &mut Vec<u8>, adresse: u64, valeur: u64) {
    rax(code, valeur);
    code.extend_from_slice(&[0x48, 0xbf]); // movabs $adresse,%rdi
    code.extend_from_slice(&adresse.to_le_bytes());
    code.extend_from_slice(&[0x48, 0x89, 0x07]); // mov %rax,(%rdi)
}

/// Le petit noyau. Ses tables : la PML4 à 1 Mio, la PDPT juste après, une
/// page de 1 Gio en identité (le code, la RAM) et une sur `0xC000_0000`.
fn petit_noyau() -> Vec<u8> {
    const PML4: u64 = 0x10_0000;
    const PDPT: u64 = 0x10_1000;
    let mut code = vec![
        0x8c, 0xcb, // mov %cs,%ebx — CS à l'entrée
        0x41, 0x8c, 0xd8, // mov %ds,%r8d — DS à l'entrée
        0xb0, 0x00, 0xe6, 0x70, // mov $0,%al ; out %al,$0x70 — les secondes
        0xe4, 0x71, // in $0x71,%al
        0x44, 0x0f, 0xb6, 0xe8, // movzbl %al,%r13d
        0xb0, 0x02, 0xe6, 0x70, // les minutes
        0xe4, 0x71, // in $0x71,%al
        0x44, 0x0f, 0xb6, 0xf0, // movzbl %al,%r14d
    ];
    poser(&mut code, PML4, PDPT | 3);
    poser(&mut code, PDPT, 0x83);
    poser(&mut code, PDPT + 3 * 8, 0xC000_0000 | 0x83);
    rax(&mut code, PML4);
    code.extend_from_slice(&[0x0f, 0x22, 0xd8]); // mov %rax,%cr3
    rax(&mut code, 1 << 31);
    code.extend_from_slice(&[0x0f, 0x22, 0xc0]); // mov %rax,%cr0
    rax(&mut code, 0xE000_0000);
    code.extend_from_slice(&[0xc7, 0x00, 0x00, 0x00, 0xff, 0x00]); // movl $0xff0000,(%rax) : rouge
    code.extend_from_slice(&[0xc7, 0x40, 0x04, 0xff, 0x00, 0x00, 0x00]); // movl $0xff,4(%rax) : bleu
    code.extend_from_slice(&[
        0xe4, 0x64, // attendre : in $0x64,%al
        0xa8, 0x01, // test $1,%al
        0x74, 0xfa, // jz attendre
        0xe4, 0x60, // in $0x60,%al
        0x44, 0x0f, 0xb6, 0xf8, // movzbl %al,%r15d
        0xfa, 0xf4, // cli ; hlt
    ]);
    code
}

/// Le releve d'une course, ou son refus : le code de sortie, la sortie et
/// l'erreur. **Et le dossier de travail de l'exemple effacé**, quelle que
/// soit la sortie : `/tmp/wisq-kernel-<pid>`, que chaque refus laissait
/// derrière lui, `std::process::exit` ne lançant aucun destructeur.
fn lancer(noyau: &Path, variables: &[(&str, &str)]) -> (Option<i32>, String, String) {
    let mut commande = Command::new(kernel_entry());
    commande.arg(noyau).env("WISQ_TURNS", "256");
    for nom in [
        "WISQ_ECRAN",
        "WISQ_SCREEN",
        "WISQ_GESTES",
        "WISQ_CAPTURE",
        "WISQ_CAPTURE_TOUTES",
        "WISQ_HEURE",
        "WISQ_DISQUE",
        "WISQ_INITRAMFS",
        "WISQ_RAM",
    ] {
        commande.env_remove(nom);
    }
    for (nom, valeur) in variables {
        commande.env(nom, valeur);
    }
    // Le dossier du noyau comme répertoire courant : une capture au chemin
    // relatif, si une course partait quand elle devait être refusée, y
    // tomberait, et pas dans le dépôt.
    if let Some(dossier) = noyau.parent() {
        commande.current_dir(dossier);
    }
    let enfant = commande
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("kernel-entry");
    let travail = std::env::temp_dir().join(format!("wisq-kernel-{}", enfant.id()));
    let sortie = enfant.wait_with_output().expect("kernel-entry");
    let releve = (
        sortie.status.code(),
        String::from_utf8_lossy(&sortie.stdout).into_owned(),
        String::from_utf8_lossy(&sortie.stderr).into_owned(),
    );
    let reste = travail.exists();
    let _ = std::fs::remove_dir_all(&travail);
    assert!(
        !reste,
        "{variables:?} : {} est resté après la sortie :\n{}\n{}",
        travail.display(),
        releve.1,
        releve.2
    );
    releve
}

/// La valeur d'un registre dans la ligne `registres` du releve.
fn registre(releve: &str, nom: &str) -> String {
    let ligne = releve
        .lines()
        .find(|l| l.starts_with("registres "))
        .unwrap_or_else(|| panic!("pas de ligne « registres » :\n{releve}"));
    ligne
        .split(' ')
        .find_map(|champ| champ.strip_prefix(&format!("{nom}=")))
        .unwrap_or_else(|| panic!("{nom} absent de « {ligne} »"))
        .to_string()
}

/// **Le dossier d'un test, effacé quoi qu'il arrive** : à la fin du test, et
/// aussi quand une assertion tombe, puisque le déroulement de la panique
/// lance les destructeurs.
struct Dossier(PathBuf);

impl Dossier {
    fn neuf(nom: &str) -> Self {
        let chemin = std::env::temp_dir().join(format!("wisq-kernel-{nom}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&chemin);
        std::fs::create_dir_all(&chemin).expect("dossier");
        Dossier(chemin)
    }
}

impl Drop for Dossier {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn bun_present() -> bool {
    ["/root/.bun/bin/bun", "bun"]
        .into_iter()
        .any(|path| Command::new(path).arg("--version").output().is_ok())
}

/// **Ce que le montage pose et ce que ses variables font, sur une course.**
///
/// - CS vaut `0x10` et DS `0x18` à la première instruction ;
/// - `WISQ_HEURE` fige l'horloge CMOS : le 20 novembre 2026 à 12:34:56 UTC
///   se lit `0x56` secondes et `0x34` minutes, en BCD ;
/// - `WISQ_GESTES=0:texte:a` tape `a` : le scancode `0x1e` arrive à l'i8042 ;
/// - `WISQ_ECRAN=8x4` branche l'écran de la carte, et `WISQ_CAPTURE` écrit à
///   la fin un PPM de 8 sur 4 dont les deux premiers pixels sont rouge
///   (`ff 00 00`) et bleu (`00 00 ff`) : le XRGB8888 de la carte porte le bleu
///   dans son octet bas, et le PPM le veut en dernier.
#[test]
fn the_montage_enters_like_a_loader_and_its_variables_do_what_they_say() {
    assert!(
        bun_present(),
        "Bun est absent : ce test ne serait vérifié par rien."
    );
    let travail = Dossier::neuf("entry");
    let dossier = &travail.0;
    let noyau = dossier.join("vmlinux");
    std::fs::write(&noyau, elf(0x0100_0000, &petit_noyau())).expect("le noyau");
    let capture = dossier.join("c.ppm");
    let (code, releve, erreurs) = lancer(
        &noyau,
        &[
            ("WISQ_ECRAN", "8x4"),
            ("WISQ_HEURE", "1795178096000"),
            ("WISQ_GESTES", "0:texte:a"),
            ("WISQ_CAPTURE", capture.to_str().expect("chemin")),
        ],
    );
    assert_eq!(code, Some(0), "{releve}\n{erreurs}");
    assert!(
        releve.lines().any(|l| l == "arret arrêtée sur hlt"),
        "la course va jusqu'au hlt :\n{releve}\n{erreurs}"
    );
    assert_eq!(
        (registre(&releve, "rbx"), registre(&releve, "r8")),
        ("0x10".to_string(), "0x18".to_string()),
        "CS à __BOOT_CS, DS à __BOOT_DS dès l'entrée :\n{releve}"
    );
    assert_eq!(
        (registre(&releve, "r13"), registre(&releve, "r14")),
        ("0x56".to_string(), "0x34".to_string()),
        "l'horloge CMOS figée par WISQ_HEURE :\n{releve}"
    );
    assert_eq!(
        registre(&releve, "r15"),
        "0x1e",
        "« a » enfoncé, tapé par WISQ_GESTES :\n{releve}"
    );
    let image = std::fs::read(&capture).expect("la capture");
    let entete = b"P6\n8 4\n255\n";
    assert_eq!(&image[..entete.len()], entete, "l'en-tête du PPM");
    assert_eq!(
        image.len(),
        entete.len() + 8 * 4 * 3,
        "trois octets par pixel"
    );
    assert_eq!(
        &image[entete.len()..entete.len() + 9],
        &[0xff, 0, 0, 0, 0, 0xff, 0, 0, 0],
        "rouge, puis bleu, puis rien : l'ordre des couleurs du PPM"
    );
}

/// **Ce qui ne se lit pas est refusé, avec un message lisible**, avant que
/// la machine parte : `inf`, `NaN` et les secondes négatives d'un geste (le
/// pilote recevait `[inf, …]`, une `ReferenceError`), un `WISQ_CAPTURE_TOUTES`
/// qui n'est pas un nombre (il devenait « jamais » sans le dire), infini
/// (`const captureToutes = inf;`, la même `ReferenceError`) ou négatif, et les
/// messages qui portaient une ligne coupée sans `\` : quatorze à vingt-six
/// espaces au milieu du texte. Aucun refus ne laisse son dossier de travail
/// (`lancer`).
#[test]
fn what_does_not_read_is_refused_in_plain_words() {
    let travail = Dossier::neuf("refus");
    let dossier = &travail.0;
    let noyau = dossier.join("vmlinux");
    std::fs::write(&noyau, elf(0x0100_0000, &petit_noyau())).expect("le noyau");
    for (variables, attendu) in [
        (
            vec![("WISQ_ECRAN", "8x4"), ("WISQ_GESTES", "inf:texte:x")],
            "WISQ_GESTES : « inf » n'est pas un nombre de secondes",
        ),
        (
            vec![("WISQ_ECRAN", "8x4"), ("WISQ_GESTES", "NaN:texte:x")],
            "WISQ_GESTES : « NaN » n'est pas un nombre de secondes",
        ),
        (
            vec![("WISQ_ECRAN", "8x4"), ("WISQ_GESTES", "-1:capture")],
            "WISQ_GESTES : « -1 » n'est pas un nombre de secondes",
        ),
        (
            vec![("WISQ_ECRAN", "8x4"), ("WISQ_GESTES", "1:toucher:inf,0,1")],
            "WISQ_GESTES : « toucher:inf,0,1 » — il faut x,y,boutons, par exemple 0.5,0.5,1",
        ),
        (
            vec![
                ("WISQ_ECRAN", "8x4"),
                ("WISQ_CAPTURE", "c.ppm"),
                ("WISQ_CAPTURE_TOUTES", "souvent"),
            ],
            "WISQ_CAPTURE_TOUTES=souvent ne se lit pas : un nombre de secondes",
        ),
        (
            vec![
                ("WISQ_ECRAN", "8x4"),
                ("WISQ_CAPTURE", "c.ppm"),
                ("WISQ_CAPTURE_TOUTES", "inf"),
            ],
            "WISQ_CAPTURE_TOUTES=inf ne se lit pas : un nombre de secondes",
        ),
        (
            vec![
                ("WISQ_ECRAN", "8x4"),
                ("WISQ_CAPTURE", "c.ppm"),
                ("WISQ_CAPTURE_TOUTES", "-1"),
            ],
            "WISQ_CAPTURE_TOUTES=-1 ne se lit pas : un nombre de secondes",
        ),
        (
            vec![("WISQ_ECRAN", "8x4"), ("WISQ_SCREEN", "8x4")],
            "WISQ_ECRAN et WISQ_SCREEN décrivent deux écrans : l'un sur la carte, l'autre dans la RAM ; il n'en faut qu'un",
        ),
        (
            vec![("WISQ_ECRAN", "grand")],
            "WISQ_ECRAN=grand ne se lit pas : il faut « largeur x hauteur », par exemple 1280x800, et seize mébioctets au plus",
        ),
    ] {
        let (code, releve, erreurs) = lancer(&noyau, &variables);
        assert_eq!(code, Some(2), "{variables:?} :\n{releve}\n{erreurs}");
        assert!(
            erreurs.lines().any(|l| l == attendu),
            "{variables:?} : « {attendu} » attendu, et :\n{erreurs}"
        );
    }
}

/// **Un pilote qui meurt fait échouer la course.** La capture demandée dans
/// un dossier qui n'existe pas : le pilote Bun lève `ENOENT` en l'écrivant, à
/// la fin, et meurt. L'exemple le disait (« le pilote s'est arrêté sur… »)
/// mais rendait zéro, et un script qui enchaîne les courses — ou attend
/// l'image — y voyait un succès. Il rend un, et n'en efface pas moins son
/// dossier de travail.
#[test]
fn a_driver_that_dies_makes_the_run_fail() {
    assert!(
        bun_present(),
        "Bun est absent : ce test ne serait vérifié par rien."
    );
    let travail = Dossier::neuf("mort");
    let dossier = &travail.0;
    let noyau = dossier.join("vmlinux");
    std::fs::write(&noyau, elf(0x0100_0000, &petit_noyau())).expect("le noyau");
    let capture = dossier.join("absent").join("c.ppm");
    let (code, releve, erreurs) = lancer(
        &noyau,
        &[
            ("WISQ_ECRAN", "8x4"),
            ("WISQ_GESTES", "0:texte:a"),
            ("WISQ_CAPTURE", capture.to_str().expect("chemin")),
        ],
    );
    assert!(
        releve
            .lines()
            .any(|l| l.starts_with("le pilote s'est arrêté sur ")),
        "la mort du pilote est dite :\n{releve}\n{erreurs}"
    );
    assert_eq!(
        code,
        Some(1),
        "et la sortie la dit aussi :\n{releve}\n{erreurs}"
    );
}
