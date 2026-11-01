//! **Lire ce qu'il y a dans une image de disque optique.**
//!
//! Maxime a chargé `omarchy-4.0.2.iso` et wisq a refusé, en disant lui-même
//! quoi faire : « s'il y a un noyau là-dedans, il est **dedans**, sous `/boot`,
//! avec son initramfs ». Ce module va le chercher.
//!
//! **L'ISO qui a servi à concevoir ceci est réel** — `alpine-virt 3.20.3`,
//! 61 Mo, parcouru avant qu'une ligne soit écrite. Ce qu'on y a trouvé :
//!
//! | | |
//! | --- | --- |
//! | les noms | Rock Ridge les rend en clair ; Joliet n'est pas nécessaire |
//! | le noyau | `/boot/vmlinuz-virt`, un bzImage que le reconnaisseur accepte |
//! | l'initramfs | `/boot/initramfs-virt` |
//! | la recette | `/boot/syslinux/syslinux.cfg` **et** `/boot/grub/grub.cfg` |
//!
//! La recette porte la ligne de commande — `modules=loop,squashfs,sd-mod,…` —
//! et c'est le point qui décide de la forme de ce code : **on ne l'invente
//! pas, on la lit.** Une ligne de commande devinée démarre un noyau qui ne
//! trouve pas sa racine, et la panne tombe loin de sa cause.
//!
//! Les tests d'ici bâtissent un ISO minuscule plutôt que d'en télécharger un :
//! la CI n'a pas soixante mégaoctets à prendre, et un fichier construit permet
//! de mentir exprès — une taille de répertoire fausse, un nom trop long — ce
//! qu'une vraie image ne fait jamais.

use wisq_vm::iso9660::{Iso, Recipe};

/// La taille d'un secteur ISO 9660, et la seule que ce format emploie en
/// pratique. Le descripteur la déclare quand même, et le lecteur la lit
/// plutôt que de la supposer.
const SECTOR: usize = 2048;

/// **Un ISO bâti ici.**
///
/// Assez pour porter une arborescence, des noms Rock Ridge, et une recette de
/// démarrage. Chaque champ est écrit à la main : c'est long, et c'est ce qui
/// permet d'en fausser un seul à la fois.
struct Builder {
    sectors: Vec<[u8; SECTOR]>,
}

impl Builder {
    fn new() -> Self {
        Builder {
            // Seize secteurs de zone système, que le format réserve et que
            // personne ne lit.
            sectors: vec![[0u8; SECTOR]; 16],
        }
    }

    fn push(&mut self, bytes: &[u8]) -> (u32, u32) {
        let lba = self.sectors.len() as u32;
        for chunk in bytes.chunks(SECTOR) {
            let mut sector = [0u8; SECTOR];
            sector[..chunk.len()].copy_from_slice(chunk);
            self.sectors.push(sector);
        }
        if bytes.is_empty() {
            self.sectors.push([0u8; SECTOR]);
        }
        (lba, bytes.len() as u32)
    }

    /// **Un répertoire, avec la taille que le format lui donne** : celle de son
    /// extension, arrondie au secteur. C'est ce qu'écrivent les vrais graveurs,
    /// et c'est ce qui met du bourrage entre le dernier enregistrement d'un
    /// secteur et le premier du suivant.
    fn push_directory(&mut self, bytes: &[u8]) -> (u32, u32) {
        let (lba, _) = self.push(bytes);
        let padded = bytes.len().div_ceil(SECTOR) * SECTOR;
        (lba, padded as u32)
    }

    fn finish(self) -> Vec<u8> {
        self.sectors.concat()
    }
}

/// Les deux boutismes, l'un après l'autre : c'est ainsi que l'ISO range ses
/// nombres, pour qu'une machine de chaque famille puisse lire le sien.
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

/// Un enregistrement de répertoire, avec son nom Rock Ridge quand il en a un.
fn record(lba: u32, size: u32, directory: bool, name: &[u8], rock: Option<&str>) -> Vec<u8> {
    let mut out = vec![0u8; 33];
    out[2..10].copy_from_slice(&both32(lba));
    out[10..18].copy_from_slice(&both32(size));
    out[25] = if directory { 2 } else { 0 };
    out[28..32].copy_from_slice(&both16(1));
    out[32] = name.len() as u8;
    out.extend_from_slice(name);
    // Le champ de nom est suivi d'un octet de bourrage quand sa longueur est
    // paire, pour que la zone d'usage système commence sur un mot.
    if name.len() % 2 == 0 {
        out.push(0);
    }
    if let Some(rock) = rock {
        // Une entrée `NM` : deux octets de nom, la longueur, la version, un
        // octet de drapeaux, puis le nom.
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

/// Un répertoire complet : ses deux entrées obligatoires, puis ses enfants.
///
/// **Aucun enregistrement ne chevauche deux secteurs.** C'est une règle du
/// format, et c'est elle qui crée le bourrage : quand le suivant ne tient plus,
/// le reste du secteur est mis à zéro et il commence au secteur d'après. Un
/// lecteur qui avancerait d'un octet sur ce zéro lirait du bourrage comme une
/// structure — d'où un répertoire d'essai assez gros pour en contenir.
///
/// L'entrée « parent » porte ici une adresse nulle : ce lecteur ne remonte
/// jamais par elle, il descend depuis la racine. La mettre juste demanderait
/// deux passes pour un champ que rien ne lit.
fn directory(own: u32, own_size: u32, children: &[Vec<u8>]) -> Vec<u8> {
    let mut out = record(own, own_size, true, &[0], None);
    out.extend(record(0, own_size, true, &[1], None));
    for child in children {
        if out.len() % SECTOR + child.len() > SECTOR {
            out.resize(out.len().div_ceil(SECTOR) * SECTOR, 0);
        }
        out.extend_from_slice(child);
    }
    out
}

/// L'image d'essai, et ce qu'elle contient.
///
/// La forme de l'ISO d'Alpine, en quelques kilooctets — plus trois cas que la
/// vraie image ne présente pas, et qui sont exactement ceux qu'un test
/// complaisant laisserait passer :
///
/// * `/boot` déborde d'un secteur, donc il porte du **bourrage** ;
/// * `/boot/README.TXT;1` n'a **pas** de nom Rock Ridge, donc il faut savoir
///   couper le numéro de version ;
/// * `/boot/grub/grub.cfg` dit la même chose que syslinux dans un **autre
///   dialecte**.
fn tiny() -> (Vec<u8>, Vec<u8>) {
    image(false)
}

/// La même image, **plus une entrée de chargeur `systemd-boot`** sous
/// `/loader/entries`. C'est la disposition de la famille Arch — celle
/// d'`omarchy` — et elle exerce deux choses que l'autre laisse dormir : la
/// branche qui *liste un répertoire* de recettes au lieu d'ouvrir un fichier,
/// et l'ordre de préférence.
fn arch_like() -> Vec<u8> {
    image(true).0
}

fn image(loader: bool) -> (Vec<u8>, Vec<u8>) {
    let kernel: Vec<u8> = (0..3000u32).map(|n| (n % 251) as u8).collect();
    let syslinux_text = b"SERIAL 0 115200\nDEFAULT virt\n\nLABEL virt\n  KERNEL /boot/vmlinuz-virt\n  INITRD /boot/initramfs-virt\n  APPEND modules=loop,squashfs quiet\n";
    let grub_text = b"set timeout=1\n\nmenuentry \"Linux virt\" {\nlinux\t/boot/vmlinuz-virt modules=loop,squashfs quiet\ninitrd\t/boot/initramfs-virt\n}\n";

    let mut build = Builder::new();
    // Le descripteur principal et son terminateur occupent les secteurs 16 et
    // 17 ; on les réserve maintenant et on les remplira à la fin, quand
    // l'adresse de la racine sera connue.
    build.sectors.push([0u8; SECTOR]);
    build.sectors.push([0u8; SECTOR]);

    let (kernel_lba, kernel_size) = build.push(&kernel);
    let (initrd_lba, initrd_size) = build.push(&[0x1f, 0x8b, 0x08, 0x00, 9, 9, 9]);
    let (syslinux_cfg_lba, syslinux_cfg_size) = build.push(syslinux_text);
    let (grub_cfg_lba, grub_cfg_size) = build.push(grub_text);
    let (readme_lba, readme_size) = build.push(b"rien a voir ici\n");

    // `/boot/syslinux`, puis `/boot/grub`, puis `/boot`, puis la racine :
    // chaque parent a besoin de l'adresse **et** de la taille de ses enfants,
    // donc on construit de bas en haut.
    let syslinux_lba = build.sectors.len() as u32;
    let syslinux = directory(
        syslinux_lba,
        SECTOR as u32,
        &[record(
            syslinux_cfg_lba,
            syslinux_cfg_size,
            false,
            b"SYSLINUX.CFG;1",
            Some("syslinux.cfg"),
        )],
    );
    let (syslinux_lba, syslinux_size) = build.push_directory(&syslinux);

    let grub_lba = build.sectors.len() as u32;
    let grub = directory(
        grub_lba,
        SECTOR as u32,
        &[record(
            grub_cfg_lba,
            grub_cfg_size,
            false,
            b"GRUB.CFG;1",
            Some("grub.cfg"),
        )],
    );
    let (grub_lba, grub_size) = build.push_directory(&grub);

    let mut children = vec![
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
        // **Sans nom Rock Ridge, exprès.** Une vraie image n'en manque jamais
        // depuis vingt ans ; mais le lecteur porte du code pour ce cas, et du
        // code que rien n'exerce est du code qu'on croit juste.
        record(readme_lba, readme_size, false, b"README.TXT;1", None),
        record(syslinux_lba, syslinux_size, true, b"SYSLINUX", None),
        record(grub_lba, grub_size, true, b"GRUB", None),
    ];
    // De quoi déborder du premier secteur, et donc du bourrage entre les deux.
    for index in 0..40u32 {
        let name = format!("filler-{index:02}");
        children.push(record(
            readme_lba,
            readme_size,
            false,
            b"FILLER.TXT;1",
            Some(&name),
        ));
    }

    let boot_lba = build.sectors.len() as u32;
    // La taille se connaît une fois les enfants posés ; on bâtit deux fois,
    // la première pour l'apprendre.
    let probe = directory(boot_lba, SECTOR as u32, &children);
    let boot_size = probe.len().div_ceil(SECTOR) * SECTOR;
    let boot = directory(boot_lba, boot_size as u32, &children);
    let (boot_lba, boot_size) = build.push_directory(&boot);
    assert!(
        boot_size > SECTOR as u32,
        "le répertoire d'essai doit déborder d'un secteur, sinon rien ne teste le bourrage"
    );

    // `/loader/entries/01-archiso.conf`, quand on le demande. Il nomme un
    // **autre** noyau que syslinux : c'est ainsi qu'on voit lequel gagne.
    let mut root_children = vec![record(boot_lba, boot_size, true, b"BOOT", None)];
    if loader {
        let (conf_lba, conf_size) = build.push(
            b"title Arch Linux\nlinux /arch/boot/x86_64/vmlinuz-linux\ninitrd /arch/boot/x86_64/initramfs-linux.img\noptions archisobasedir=arch archisolabel=WISQTEST\n",
        );
        // **Un intrus, posé avant le vrai.** Un fichier qui n'est pas une
        // entrée mais qui en a l'air : il porte une ligne `linux`, et il
        // arrive en premier dans le répertoire. Sans le filtre sur `.conf`,
        // c'est lui qui serait lu — et wisq démarrerait un noyau cité dans
        // une documentation.
        let (readme_lba, readme_size) = build
            .push(b"Exemple d'entree :\n\nlinux /ceci/nest/pas/un/noyau\ninitrd /ceci/non/plus\n");
        let entries_lba = build.sectors.len() as u32;
        let entries = directory(
            entries_lba,
            SECTOR as u32,
            &[
                record(readme_lba, readme_size, false, b"00README.TXT;1", None),
                record(
                    conf_lba,
                    conf_size,
                    false,
                    b"01ARCHIS.CON;1",
                    Some("01-archiso.conf"),
                ),
            ],
        );
        let (entries_lba, entries_size) = build.push_directory(&entries);

        let loader_lba = build.sectors.len() as u32;
        let loader_dir = directory(
            loader_lba,
            SECTOR as u32,
            &[record(entries_lba, entries_size, true, b"ENTRIES", None)],
        );
        let (loader_lba, loader_size) = build.push_directory(&loader_dir);
        root_children.push(record(loader_lba, loader_size, true, b"LOADER", None));
    }

    let root_lba = build.sectors.len() as u32;
    let root = directory(root_lba, SECTOR as u32, &root_children);
    let (root_lba, root_size) = build.push_directory(&root);

    let mut pvd = [0u8; SECTOR];
    pvd[0] = 1;
    pvd[1..6].copy_from_slice(b"CD001");
    pvd[6] = 1;
    pvd[8..40].fill(b' ');
    pvd[40..72].fill(b' ');
    pvd[40..48].copy_from_slice(b"WISQTEST");
    pvd[80..88].copy_from_slice(&both32(build.sectors.len() as u32));
    pvd[128..132].copy_from_slice(&both16(SECTOR as u16));
    let root_record = record(root_lba, root_size, true, &[0], None);
    pvd[156..156 + root_record.len()].copy_from_slice(&root_record);
    build.sectors[16] = pvd;

    let mut end = [0u8; SECTOR];
    end[0] = 255;
    end[1..6].copy_from_slice(b"CD001");
    end[6] = 1;
    build.sectors[17] = end;

    (build.finish(), kernel)
}

/// **Un ISO se reconnaît, et son étiquette se lit.**
#[test]
fn an_image_opens_and_names_itself() {
    let (image, _) = tiny();
    let iso = Iso::open(&image[..]).expect("l'image s'ouvre");
    assert_eq!(iso.volume_label(), "WISQTEST");
}

/// **Le vrai nom sort de Rock Ridge, pas du champ ISO.**
///
/// Sans lui, le chemin serait `/BOOT/VMLINUZ_.VIR;1` — et aucune recette de
/// démarrage ne parle ce dialecte-là. C'est le champ que le format réserve
/// aux systèmes qui savent lire autre chose que huit majuscules et trois.
#[test]
fn rock_ridge_gives_the_real_name() {
    let (image, _) = tiny();
    let iso = Iso::open(&image[..]).expect("l'image s'ouvre");
    let names: Vec<String> = iso
        .list(&iso.find("/boot").expect("/boot"))
        .into_iter()
        .map(|entry| entry.name)
        .collect();
    assert!(
        names.contains(&"vmlinuz-virt".to_string()),
        "le nom Rock Ridge doit gagner : {names:?}"
    );
    assert!(
        !names.iter().any(|name| name.contains("VMLINUZ_")),
        "et le nom ISO ne doit pas rester : {names:?}"
    );
}

/// **Un fichier se retrouve par son chemin, et ressort octet pour octet.**
#[test]
fn a_file_comes_back_whole() {
    let (image, kernel) = tiny();
    let iso = Iso::open(&image[..]).expect("l'image s'ouvre");
    let entry = iso.find("/boot/vmlinuz-virt").expect("le noyau");
    assert_eq!(entry.size as usize, kernel.len());
    let bytes = iso.read(&entry, 1 << 20).expect("les octets");
    // **Octet pour octet, et pas seulement la bonne longueur.** Une lecture
    // qui rendrait le bon nombre d'octets pris au mauvais secteur passerait
    // une vérification de taille sans broncher.
    assert_eq!(bytes, kernel);
}

/// **La recette est lue, pas devinée.**
///
/// Le noyau, l'initramfs et la ligne de commande viennent du fichier que la
/// distribution a écrit. Inventer cette ligne démarrerait un noyau incapable
/// de trouver sa racine, et la panne tomberait très loin de sa cause.
#[test]
fn the_recipe_is_read_from_the_image() {
    let (image, _) = tiny();
    let iso = Iso::open(&image[..]).expect("l'image s'ouvre");
    let recipe = Recipe::of(&iso).expect("la recette");
    assert_eq!(recipe.kernel, "/boot/vmlinuz-virt");
    assert_eq!(recipe.initrd.as_deref(), Some("/boot/initramfs-virt"));
    assert_eq!(recipe.command_line, "modules=loop,squashfs quiet");
    assert_eq!(recipe.from, "/boot/syslinux/syslinux.cfg");
}

/// **Un répertoire qui ment sur sa taille ne fait pas lire tout le disque.**
///
/// Les tailles d'un ISO sont des entiers de trente-deux bits venus du fichier,
/// c'est-à-dire de n'importe où. Le dépôt a déjà payé le prix de croire un
/// nombre de longueur sur parole, plus d'une fois.
#[test]
fn a_lying_directory_size_is_refused() {
    let (mut image, _) = tiny();
    let iso = Iso::open(&image[..]).expect("l'image s'ouvre");
    let boot = iso.find("/boot").expect("/boot");
    // **On réécrit la taille de `/boot` là où elle est, pas là où elle
    // ressemble.** La première version de ce test cherchait le motif d'octets
    // dans toute l'image ; il en existe d'autres copies dès que deux objets
    // font la même taille, et elle en a réécrit un autre — le test tombait
    // sans que le code y soit pour rien.
    let root = u32::from_le_bytes(
        image[16 * SECTOR + 158..16 * SECTOR + 162]
            .try_into()
            .unwrap(),
    );
    let sector = root as usize * SECTOR;
    let at = (sector..sector + SECTOR)
        .step_by(1)
        .find(|&at| image[at + 2..at + 6] == boot.start.to_le_bytes())
        .expect("l'enregistrement de /boot dans la racine");
    image[at + 10..at + 18].copy_from_slice(&both32(u32::MAX));
    let iso = Iso::open(&image[..]).expect("l'image s'ouvre encore");
    assert!(
        iso.find("/boot/vmlinuz-virt").is_none(),
        "une taille impossible se refuse plutôt que de se lire"
    );
}

/// **Un fichier plus grand que ce qu'on accepte n'est pas rendu à moitié.**
#[test]
fn a_file_beyond_the_ceiling_is_refused_rather_than_truncated() {
    let (image, kernel) = tiny();
    let iso = Iso::open(&image[..]).expect("l'image s'ouvre");
    let entry = iso.find("/boot/vmlinuz-virt").expect("le noyau");
    assert!(
        iso.read(&entry, kernel.len() - 1).is_none(),
        "sous le plafond, on refuse — rendre le début serait pire"
    );
    assert!(
        iso.read(&entry, kernel.len()).is_some(),
        "et le plafond exact passe"
    );
}

/// **Sans Rock Ridge, le numéro de version doit partir.**
///
/// Le champ de nom d'ISO 9660 porte un point-virgule et un numéro. Une recette
/// de démarrage écrit `vmlinuz`, jamais `vmlinuz;1` — garder le suffixe ferait
/// chercher un fichier qui n'existe sous ce nom nulle part.
///
/// Le cas n'apparaît dans aucune image moderne, et c'est exactement pour ça
/// qu'il est ici : le lecteur porte du code pour lui, et du code que rien
/// n'exerce est du code qu'on croit juste.
#[test]
fn without_rock_ridge_the_version_suffix_is_dropped() {
    let (image, _) = tiny();
    let iso = Iso::open(&image[..]).expect("l'image s'ouvre");
    let names: Vec<String> = iso
        .list(&iso.find("/boot").expect("/boot"))
        .into_iter()
        .map(|entry| entry.name)
        .collect();
    assert!(
        names.contains(&"README.TXT".to_string()),
        "le nom ISO reste, sans son « ;1 » : {names:?}"
    );
    assert!(
        iso.find("/boot/README.TXT").is_some(),
        "et il se retrouve par ce nom-là"
    );
}

/// **Le bourrage entre deux secteurs ne fait pas perdre la suite.**
///
/// Un enregistrement ne chevauche jamais deux secteurs : quand le suivant ne
/// tient plus, le reste du secteur est mis à zéro. Un lecteur qui avancerait
/// d'un octet sur ce zéro lirait du bourrage comme une structure et perdrait
/// tout ce qui suit.
///
/// C'est le cas qu'aucun petit répertoire ne présente — d'où les quarante
/// entrées de remplissage de l'image d'essai.
#[test]
fn padding_between_sectors_does_not_swallow_what_follows() {
    let (image, _) = tiny();
    let iso = Iso::open(&image[..]).expect("l'image s'ouvre");
    let boot = iso.find("/boot").expect("/boot");
    assert!(
        boot.size > 2048,
        "l'image d'essai doit avoir un répertoire à cheval sur deux secteurs"
    );
    let names: Vec<String> = iso
        .list(&boot)
        .into_iter()
        .map(|entry| entry.name)
        .collect();
    assert_eq!(
        names.len(),
        45,
        "les cinq entrées et les quarante : {names:?}"
    );
    assert!(
        names.contains(&"filler-39".to_string()),
        "la dernière entrée, au-delà du bourrage, est là : {names:?}"
    );
}

/// **Grub dit la même chose autrement, et il faut le lire aussi.**
///
/// Il met le noyau et ses arguments sur une seule ligne, là où syslinux les
/// sépare. Une image qui ne porterait que `grub.cfg` — et il en existe — ne
/// démarrerait pas si le lecteur ne connaissait qu'un dialecte.
#[test]
fn the_grub_dialect_says_the_same_thing() {
    let (image, _) = tiny();
    let iso = Iso::open(&image[..]).expect("l'image s'ouvre");
    let grub = iso.find("/boot/grub/grub.cfg").expect("grub.cfg");
    let text = String::from_utf8(iso.read(&grub, 1 << 20).expect("les octets")).expect("du texte");
    let recipe = Recipe::read(&text, "/boot/grub/grub.cfg").expect("la recette grub");
    assert_eq!(recipe.kernel, "/boot/vmlinuz-virt");
    assert_eq!(recipe.initrd.as_deref(), Some("/boot/initramfs-virt"));
    assert_eq!(
        recipe.command_line, "modules=loop,squashfs quiet",
        "les arguments sont sur la ligne du noyau, pas sur une ligne à part"
    );
}

/// **Un octet parasite dans le bourrage ne déraille pas le parcours.**
///
/// Ce test-ci existe parce qu'un sabotage a **survécu**. Remplacer le saut au
/// secteur suivant par « avance d'un octet » ne changeait rien : le bourrage
/// étant des zéros, avancer un par un finit par retomber pile sur
/// l'enregistrement suivant. Les deux formes se valaient — sur une image bien
/// formée.
///
/// La différence est ailleurs, et elle est réelle : **un seul octet non nul
/// dans le bourrage**. Avec le saut, il est ignoré ; sans lui, il devient une
/// longueur d'enregistrement et le parcours part ailleurs. Une image gravée
/// n'en met pas ; une image tronquée, recopiée de travers ou hostile, si.
#[test]
fn a_stray_byte_in_the_padding_does_not_derail_the_walk() {
    let (clean, _) = tiny();
    let iso = Iso::open(&clean[..]).expect("l'image s'ouvre");
    let boot = iso.find("/boot").expect("/boot");
    let expected = iso.list(&boot).len();

    let mut soiled = clean.clone();
    // Le dernier octet du premier secteur de `/boot` : dans le bourrage, à
    // coup sûr, puisque aucun enregistrement ne chevauche la frontière.
    let at = boot.start as usize * SECTOR + SECTOR - 1;
    assert_eq!(
        soiled[at], 0,
        "on veut salir du bourrage, pas une structure"
    );
    soiled[at] = 0x7f;

    let iso = Iso::open(&soiled[..]).expect("l'image s'ouvre encore");
    let boot = iso.find("/boot").expect("/boot");
    assert_eq!(
        iso.list(&boot).len(),
        expected,
        "le bourrage est du bourrage, quoi qu'on y mette"
    );
}

/// **Le plafond d'un répertoire empêche une allocation, et c'est ce qu'il faut
/// observer.**
///
/// Ce test-ci aussi vient d'un sabotage qui a survécu. Retirer le plafond ne
/// changeait pas la réponse : la lecture échouait plus loin, sur une image trop
/// courte, et `find` rendait `None` dans les deux cas. Le test regardait le
/// verdict, pas ce que le plafond protège.
///
/// Ce qu'il protège, c'est **ce qu'on demande**. Une source qui compte la plus
/// grosse demande le rend visible : sans plafond, le lecteur réclame quatre
/// gibioctets pour une image de quelques kilooctets.
#[test]
fn the_ceiling_stops_the_reader_from_asking_for_the_impossible() {
    struct Counting<'a> {
        image: &'a [u8],
        largest: std::cell::Cell<usize>,
    }
    impl wisq_vm::iso9660::Bytes for Counting<'_> {
        fn read(&self, at: u64, into: &mut [u8]) -> bool {
            self.largest.set(self.largest.get().max(into.len()));
            self.image.read(at, into)
        }
    }

    let (mut image, _) = tiny();
    let iso = Iso::open(&image[..]).expect("l'image s'ouvre");
    let boot = iso.find("/boot").expect("/boot");
    let root = u32::from_le_bytes(
        image[16 * SECTOR + 158..16 * SECTOR + 162]
            .try_into()
            .unwrap(),
    );
    let sector = root as usize * SECTOR;
    let at = (sector..sector + SECTOR)
        .find(|&at| image[at + 2..at + 6] == boot.start.to_le_bytes())
        .expect("l'enregistrement de /boot dans la racine");
    image[at + 10..at + 18].copy_from_slice(&both32(u32::MAX));

    let length = image.len();
    let counting = Counting {
        image: &image,
        largest: std::cell::Cell::new(0),
    };
    let iso = Iso::open(counting).expect("l'image s'ouvre encore");
    let boot = iso.find("/boot").expect("/boot est toujours nommé");
    assert!(iso.list(&boot).is_empty(), "et son contenu est refusé");
    // La source est consommée par `Iso` ; on la relit à travers lui.
    assert!(
        iso.source().largest.get() <= length,
        "le lecteur ne doit jamais demander plus que l'image ne fait : {} octets",
        iso.source().largest.get()
    );
}

/// **Une entrée Rock Ridge qui ment sur sa longueur ne fait pas sortir du
/// tampon.**
///
/// Troisième test venu d'un sabotage qui a survécu : rien n'exerçait la garde
/// de longueur, parce qu'aucune image bien formée ne la met en défaut. Celle-ci
/// le fait exprès.
///
/// Sans la garde, la tranche `[at + 5 .. at + length]` sort de
/// l'enregistrement et le programme s'arrête. Avec, la lecture du nom
/// s'interrompt, et l'entrée retombe sur son nom ISO — laid, mais lisible, et
/// surtout : elle ne prend rien qui ne lui appartienne.
#[test]
fn a_rock_ridge_entry_that_lies_about_its_length_is_dropped() {
    let (mut image, _) = tiny();
    // L'entrée `NM` du noyau : deux lettres, la longueur, la version, les
    // drapeaux, puis le nom.
    let needle: Vec<u8> = [b"NM".as_slice(), &[17, 1, 0], b"vmlinuz-virt".as_slice()].concat();
    let at = image
        .windows(needle.len())
        .position(|window| window == needle)
        .expect("l'entrée Rock Ridge du noyau");
    image[at + 2] = 250;

    let iso = Iso::open(&image[..]).expect("l'image s'ouvre");
    let names: Vec<String> = iso
        .list(&iso.find("/boot").expect("/boot"))
        .into_iter()
        .map(|entry| entry.name)
        .collect();
    assert!(
        names.contains(&"VMLINUZ_.VIR".to_string()),
        "le nom ISO reprend la main quand Rock Ridge est illisible : {names:?}"
    );
}

/// **Une recette peut être un répertoire d'entrées, et c'est elle qui gagne.**
///
/// Ce test-ci a été ajouté avant la fusion, en relisant : la branche de
/// `Recipe::of` qui *liste* un répertoire au lieu d'ouvrir un fichier n'était
/// exercée par rien. Du code que rien n'exerce est du code qu'on croit juste —
/// et c'est justement la disposition de la famille Arch, donc celle de l'image
/// qui a déclenché tout ce travail.
///
/// L'ordre compte autant que la lecture. Un `archiso.cfg` de syslinux se
/// compose d'`INCLUDE` qui pointent d'autres fichiers ; une entrée de chargeur
/// tient en cinq lignes sans indirection. Quand les deux sont là, la seconde
/// répond mieux à la même question — et l'image d'essai les met en désaccord
/// exprès pour qu'on voie laquelle a servi.
#[test]
fn a_directory_of_loader_entries_wins_over_syslinux() {
    let image = arch_like();
    let iso = Iso::open(&image[..]).expect("l'image s'ouvre");
    // Les deux recettes sont bien là, et elles ne disent pas la même chose.
    assert!(iso.find("/boot/syslinux/syslinux.cfg").is_some());
    assert!(iso.find("/loader/entries/01-archiso.conf").is_some());

    let recipe = Recipe::of(&iso).expect("la recette");
    assert_eq!(
        recipe.from, "/loader/entries/01-archiso.conf",
        "l'entrée de chargeur passe avant syslinux"
    );
    assert_eq!(recipe.kernel, "/arch/boot/x86_64/vmlinuz-linux");
    assert_eq!(
        recipe.initrd.as_deref(),
        Some("/arch/boot/x86_64/initramfs-linux.img")
    );
    assert_eq!(
        recipe.command_line, "archisobasedir=arch archisolabel=WISQTEST",
        "les arguments d'une entrée de chargeur sont sur leur propre ligne"
    );
    // **Et l'intrus n'a pas été lu.** Le répertoire porte aussi un fichier qui
    // ressemble à une entrée sans en être une, placé avant la vraie : sans le
    // filtre sur `.conf`, c'est lui qui aurait répondu.
    assert!(
        iso.find("/loader/entries/00README.TXT").is_some(),
        "l'intrus doit être là, sinon ce test ne vérifie rien"
    );
    assert_ne!(recipe.kernel, "/ceci/nest/pas/un/noyau");
}

/// **Une recette vient d'UNE entrée de menu, jamais de plusieurs.**
///
/// C'est le défaut que Maxime a vu sur son téléphone, et qu'aucune fixture
/// d'ici ne pouvait montrer : elles n'avaient qu'une entrée.
///
/// Le vrai `grub.cfg` d'Omarchy 4.0.2 en porte quatre. Le lecteur parcourait le
/// fichier d'un bout à l'autre en gardant le **dernier** `linux` et le
/// **dernier** `initrd` rencontrés, et rendait donc une chimère : le noyau de
/// memtest, l'initramfs d'Arch, et la ligne de commande d'une troisième entrée.
/// L'application construisait alors une machine RISC-V — memtest n'est pas un
/// bzImage — et refusait l'initramfs.
///
/// Le texte ci-dessous est celui de l'image, réduit à ses entrées.
#[test]
fn a_recipe_comes_from_one_menu_entry() {
    let text = "\
set default=archlinux
timeout=0

menuentry \"Omarchy (x86_64)\" --class arch --id 'archlinux' {
    set gfxpayload=keep
    linux /arch/boot/x86_64/vmlinuz-linux-t2 archisobasedir=arch quiet splash
    initrd /arch/boot/x86_64/initramfs-linux-t2.img
}

menuentry \"Omarchy with speakup screen reader\" --id 'archlinux-accessibility' {
    linux /arch/boot/x86_64/vmlinuz-linux-t2 archisobasedir=arch accessibility=on
    initrd /arch/boot/x86_64/initramfs-linux-t2.img
}

menuentry \"Run Memtest86+ (RAM test)\" --class memtest {
    linux /boot/memtest86+/memtest
}
";
    let recipe = Recipe::read(text, "/boot/grub/grub.cfg").expect("la recette grub");
    assert_eq!(recipe.kernel, "/arch/boot/x86_64/vmlinuz-linux-t2");
    assert_eq!(
        recipe.initrd.as_deref(),
        Some("/arch/boot/x86_64/initramfs-linux-t2.img")
    );
    assert_eq!(recipe.command_line, "archisobasedir=arch quiet splash");
    // **Ce que le défaut rendait**, nommé pour qu'on voie ce qui est refusé.
    assert_ne!(recipe.kernel, "/boot/memtest86+/memtest");
    assert!(!recipe.command_line.contains("accessibility"));
}

/// La même règle pour syslinux, dont les entrées commencent par `LABEL`.
#[test]
fn a_syslinux_recipe_stops_at_the_next_label() {
    let text = "\
DEFAULT virt
LABEL virt
  KERNEL /boot/vmlinuz-virt
  INITRD /boot/initramfs-virt
  APPEND modules=loop,squashfs quiet

LABEL secours
  KERNEL /boot/vmlinuz-secours
  APPEND single
";
    let recipe = Recipe::read(text, "/boot/syslinux/syslinux.cfg").expect("la recette");
    assert_eq!(recipe.kernel, "/boot/vmlinuz-virt");
    assert_eq!(recipe.initrd.as_deref(), Some("/boot/initramfs-virt"));
    assert_eq!(recipe.command_line, "modules=loop,squashfs quiet");
}

/// **Une entrée sans arguments n'hérite pas de ceux de la précédente.**
///
/// C'est la moitié du défaut qui ne se voit pas dans le noyau rendu : memtest
/// n'écrit aucun argument, et la ligne de commande gardait celle d'avant. Un
/// noyau démarré avec les arguments d'un autre cherche une racine qui n'existe
/// pas, et la panne tombe très loin de sa cause.
#[test]
fn an_entry_without_arguments_inherits_none() {
    let text = "\
menuentry \"premier\" {
    linux /boot/un archisobasedir=arch quiet
}

menuentry \"second\" {
    linux /boot/deux
}
";
    let recipe = Recipe::read(text, "/boot/grub/grub.cfg").expect("la recette");
    assert_eq!(recipe.kernel, "/boot/un");
    assert_eq!(recipe.command_line, "archisobasedir=arch quiet");

    // Et si la première entrée est celle sans arguments, elle n'en invente pas.
    let inverse = "\
menuentry \"second\" {
    linux /boot/deux
}

menuentry \"premier\" {
    linux /boot/un archisobasedir=arch quiet
}
";
    let recipe = Recipe::read(inverse, "/boot/grub/grub.cfg").expect("la recette");
    assert_eq!(recipe.kernel, "/boot/deux");
    assert_eq!(recipe.command_line, "", "des arguments venus d'ailleurs");
}

/// **Une entrée `systemd-boot` n'a aucun mot d'ouverture** : le fichier entier
/// est l'entrée. Découper par blocs ne doit pas casser ce dialecte-là.
#[test]
fn a_loader_entry_is_a_whole_file() {
    let text = "\
title   Arch Linux install medium
linux   /arch/boot/x86_64/vmlinuz-linux
initrd  /arch/boot/x86_64/initramfs-linux.img
options archisobasedir=arch quiet
";
    let recipe = Recipe::read(text, "/loader/entries/01-archiso.conf").expect("la recette");
    assert_eq!(recipe.kernel, "/arch/boot/x86_64/vmlinuz-linux");
    assert_eq!(
        recipe.initrd.as_deref(),
        Some("/arch/boot/x86_64/initramfs-linux.img")
    );
    assert_eq!(recipe.command_line, "archisobasedir=arch quiet");
}

/// **L'initramfs nommé dans `APPEND`**, comme l'écrit Void Linux : syslinux
/// n'a pas besoin de ligne `INITRD`, et la recette en était rendue sans
/// initramfs — un noyau démarré sans sa racine.
#[test]
fn an_initrd_in_the_append_line_is_the_initrd() {
    let text = "\
UI vesamenu.c32
ONTIMEOUT linux

LABEL linux
MENU LABEL Void Linux 6.12.11_1 x86_64-musl
KERNEL /boot/vmlinuz
APPEND initrd=/boot/initrd root=live:CDLABEL=VOID_LIVE init=/sbin/init ro loglevel=4
";
    let recipe = Recipe::read(text, "/boot/isolinux/isolinux.cfg").expect("la recette");
    assert_eq!(recipe.kernel, "/boot/vmlinuz");
    assert_eq!(recipe.initrd.as_deref(), Some("/boot/initrd"));
    assert_eq!(
        recipe.command_line, "root=live:CDLABEL=VOID_LIVE init=/sbin/init ro loglevel=4",
        "le mot `initrd=` a servi : il ne reste pas sur la ligne"
    );
}

/// Une ligne `INITRD` reste la réponse quand elle est là : le mot de
/// `APPEND` ne la remplace pas.
#[test]
fn an_initrd_line_wins_over_the_append_word() {
    let text = "\
label corepure64
\tkernel /boot/vmlinuz64
\tinitrd /boot/corepure64.gz
\tappend loglevel=3 initrd=/ailleurs
";
    let recipe = Recipe::read(text, "/boot/isolinux/isolinux.cfg").expect("la recette");
    assert_eq!(recipe.kernel, "/boot/vmlinuz64");
    assert_eq!(recipe.initrd.as_deref(), Some("/boot/corepure64.gz"));
    assert_eq!(recipe.command_line, "loglevel=3 initrd=/ailleurs");
}

/// **Grub coupe ses lignes**, et nomme le périphérique devant le chemin.
/// C'est l'entrée de Void Linux, telle quelle.
#[test]
fn grub_continued_lines_and_device_prefixes_are_read() {
    let text = "\
menuentry \"Void Linux 6.12.11_1 (x86_64-musl)\" --id \"linux\"  {
    set gfxpayload=\"keep\"
    linux (${voidlive})/boot/vmlinuz \\
        root=live:CDLABEL=VOID_LIVE ro init=/sbin/init \\
        rd.luks=0 rd.md=0 rd.dm=0 loglevel=4
    initrd (${voidlive})/boot/initrd
}
";
    let recipe = Recipe::read(text, "/boot/grub/grub_void.cfg").expect("la recette");
    assert_eq!(recipe.kernel, "/boot/vmlinuz");
    assert_eq!(recipe.initrd.as_deref(), Some("/boot/initrd"));
    assert_eq!(
        recipe.command_line,
        "root=live:CDLABEL=VOID_LIVE ro init=/sbin/init rd.luks=0 rd.md=0 rd.dm=0 loglevel=4"
    );
}

/// **Plusieurs initramfs sur une ligne** : les deux microcodes puis
/// l'initramfs, comme l'écrit l'entrée grub d'Artix. Tous sont gardés, dans
/// l'ordre, séparés par une espace.
#[test]
fn several_initrds_on_one_grub_line_are_all_kept() {
    let text = "\
menuentry \"From CD/DVD/ISO: artix.x86_64 \" {
    linux /boot/vmlinuz-x86_64 label=ARTIX_202608
    initrd /boot/intel-ucode.img /boot/amd-ucode.img /boot/initramfs-x86_64.img
}
";
    let recipe = Recipe::read(text, "/boot/grub/kernels.cfg").expect("la recette");
    assert_eq!(
        recipe.initrd.as_deref(),
        Some("/boot/intel-ucode.img /boot/amd-ucode.img /boot/initramfs-x86_64.img")
    );
}

/// La même liste, aux trois formes des chargeurs : les virgules de syslinux,
/// une ligne par fichier chez systemd-boot, et les mots `initrd=` de
/// `APPEND`. Une variable de grub n'est pas un fichier : elle tombe.
#[test]
fn every_form_of_initrd_list_is_read() {
    let syslinux = "LABEL a\nKERNEL /k\nINITRD /u.img,/i.img\n";
    let recipe = Recipe::read(syslinux, "/isolinux/isolinux.cfg").expect("syslinux");
    assert_eq!(recipe.initrd.as_deref(), Some("/u.img /i.img"));

    let entry = "linux /k\ninitrd /u.img\ninitrd /i.img\noptions quiet\n";
    let recipe = Recipe::read(entry, "/loader/entries/a.conf").expect("systemd-boot");
    assert_eq!(recipe.initrd.as_deref(), Some("/u.img /i.img"));
    assert_eq!(recipe.command_line, "quiet");

    let append = "LABEL a\nKERNEL /k\nAPPEND initrd=/u.img,/i.img root=/dev/sr0\n";
    let recipe = Recipe::read(append, "/isolinux/isolinux.cfg").expect("APPEND");
    assert_eq!(recipe.initrd.as_deref(), Some("/u.img /i.img"));
    assert_eq!(recipe.command_line, "root=/dev/sr0");

    let variable = "menuentry \"a\" {\n linux /k\n initrd /i.img $tuned_initrd\n}\n";
    let recipe = Recipe::read(variable, "/boot/grub/grub.cfg").expect("variable");
    assert_eq!(recipe.initrd.as_deref(), Some("/i.img"));
}

/// **Un chemin relatif part du dossier de la recette chez syslinux.** C'est
/// l'entrée de Mageia telle quelle, dans `/isolinux/isolinux.cfg` : le noyau
/// est en `/isolinux/x86_64/vmlinuz`, pas en `/x86_64/vmlinuz`.
#[test]
fn a_relative_syslinux_path_starts_at_the_recipes_folder() {
    let text = "\
default linux
label linux
  kernel x86_64/vmlinuz
  append initrd=x86_64/all.rdz audit=0 noiswmd audit=0 vga=791 splash quiet
";
    let recipe = Recipe::read(text, "/isolinux/isolinux.cfg").expect("la recette");
    assert_eq!(recipe.kernel, "/isolinux/x86_64/vmlinuz");
    assert_eq!(recipe.initrd.as_deref(), Some("/isolinux/x86_64/all.rdz"));

    // Un chemin absolu reste ce qu'il est, et grub part de la racine.
    let absolute = Recipe::read("label a\n kernel /boot/k\n", "/isolinux/isolinux.cfg");
    assert_eq!(absolute.expect("absolu").kernel, "/boot/k");
    let grub = Recipe::read(
        "menuentry \"a\" {\n linux boot/k\n}\n",
        "/boot/grub/grub.cfg",
    );
    assert_eq!(grub.expect("grub").kernel, "/boot/k");
}

/// Une image en mémoire pour `Recipe::read_in` : des fichiers par chemin, et
/// les noms d'un dossier tirés de ces chemins.
fn files(
    table: &'static [(&'static str, &'static str)],
) -> (
    impl Fn(&str) -> Option<String>,
    impl Fn(&str) -> Vec<String>,
) {
    let file = move |path: &str| {
        table
            .iter()
            .find(|(name, _)| *name == path)
            .map(|(_, text)| text.to_string())
    };
    let names = move |folder: &str| {
        table
            .iter()
            .filter_map(|(name, _)| name.strip_prefix(folder)?.strip_prefix('/'))
            .filter(|rest| !rest.contains('/'))
            .map(str::to_string)
            .collect()
    };
    (file, names)
}

/// La disposition d'Artix, réduite à ce qui compte : `grub.cfg` n'a aucune
/// ligne `linux`, il lit `kernels.cfg`, dont l'entrée nomme son noyau par
/// `$2` — une boucle `for` que wisq ne joue pas.
const ARTIX: &[(&str, &str)] = &[
    (
        "/boot/grub/grub.cfg",
        "function menu_reload {\n    configfile /boot/grub/grub.cfg\n}\nfunction memtest_detect {\n    menuentry --class=memtest \"memtest\" {linux16 /boot/$1}\n}\nsource /boot/grub/defaults.cfg\nsource /boot/grub/kernels.cfg\nsource /boot/grub/locales/${1}\n",
    ),
    ("/boot/grub/defaults.cfg", "timeout=-1\n"),
    (
        "/boot/grub/kernels.cfg",
        "if cpuid -l; then\n    title=\"\"\n    for kopt in x86_64 $kopts label=ARTIX_202608; do\n        title=\"$title $kopt\";\n    done\n    menuentry \"From CD/DVD/ISO: artix.x86_64 \" --class=artix.x86_64 \"$title \" {# set arguments above with the editor\n        linux /boot/vmlinuz-$2\n        initrd /boot/intel-ucode.img /boot/amd-ucode.img /boot/initramfs-x86_64.img\n    }\nfi\n",
    ),
    ("/boot/vmlinuz-x86_64", ""),
    ("/boot/initramfs-x86_64.img", ""),
    ("/boot/intel-ucode.img", ""),
    ("/boot/amd-ucode.img", ""),
];

/// **Artix démarre** : la recette suit `source`, passe `$2` à l'entrée,
/// trouve le seul `vmlinuz-…` du dossier, et garde l'argument qui nomme le
/// support — sans lui, l'initramfs ne retrouve pas le disque.
#[test]
fn a_grub_script_that_names_its_kernel_by_a_variable_is_read() {
    let (file, names) = files(ARTIX);
    let text = file("/boot/grub/grub.cfg").unwrap();
    let recipe = Recipe::read_in(&text, "/boot/grub/grub.cfg", "ARTIX_202608", &file, &names)
        .expect("la recette d'Artix");
    assert_eq!(recipe.kernel, "/boot/vmlinuz-x86_64");
    assert_eq!(
        recipe.initrd.as_deref(),
        Some("/boot/intel-ucode.img /boot/amd-ucode.img /boot/initramfs-x86_64.img")
    );
    assert_eq!(recipe.command_line, "label=ARTIX_202608");
    assert_eq!(recipe.from, "/boot/grub/grub.cfg");
}

/// **Deux noyaux qui conviennent, aucun choisi.** Entre `vmlinuz-lts` et
/// `vmlinuz-zen`, prendre l'un serait deviner ; l'image est refusée plutôt
/// que démarrée sur un noyau que personne n'a nommé.
#[test]
fn a_variable_kernel_with_two_candidates_is_not_guessed() {
    const TWO: &[(&str, &str)] = &[
        (
            "/boot/grub/grub.cfg",
            "menuentry \"a\" {\n linux /boot/vmlinuz-$flavour quiet\n}\n",
        ),
        ("/boot/vmlinuz-lts", ""),
        ("/boot/vmlinuz-zen", ""),
    ];
    let (file, names) = files(TWO);
    let text = file("/boot/grub/grub.cfg").unwrap();
    assert_eq!(
        Recipe::read_in(&text, "/boot/grub/grub.cfg", "X", &file, &names),
        None
    );
}

/// Les paramètres d'une entrée remplacent `$1`, `${2}` ; une variable qui
/// n'est pas lue tombe de la ligne, comme chez grub quand elle n'est pas
/// posée, au lieu d'arriver au noyau en toutes lettres.
#[test]
fn entry_parameters_are_passed_and_unset_variables_vanish() {
    let text = "menuentry 'Live' --class=live \"k1\" \"root=live\" {\n linux /boot/$2 ${3} $kopts quiet ${auto}x\n}\n";
    let recipe = Recipe::read(text, "/boot/grub/grub.cfg").expect("la recette");
    assert_eq!(recipe.kernel, "/boot/k1");
    assert_eq!(recipe.command_line, "root=live quiet x");
}

/// **Un `configfile` qui se relit lui-même ne fait pas tourner la lecture
/// en rond** : `menu_reload` relit `grub.cfg`, et chaque fichier n'est lu
/// qu'une fois.
#[test]
fn a_grub_file_that_sources_itself_is_read_once() {
    const LOOP: &[(&str, &str)] = &[
        (
            "/boot/grub/grub.cfg",
            "configfile /boot/grub/grub.cfg\nsource /boot/grub/b.cfg\n",
        ),
        (
            "/boot/grub/b.cfg",
            "source /boot/grub/grub.cfg\nmenuentry \"b\" {\n linux /boot/k\n}\n",
        ),
    ];
    let (file, names) = files(LOOP);
    let text = file("/boot/grub/grub.cfg").unwrap();
    let recipe =
        Recipe::read_in(&text, "/boot/grub/grub.cfg", "", &file, &names).expect("la recette");
    assert_eq!(recipe.kernel, "/boot/k");
}

/// **Fedora Workstation 44** : `/EFI/BOOT/grub.cfg` ne fait que relire
/// `($root)/boot/grub2/grub.cfg`. Le périphérique devant le chemin est
/// l'image elle-même ; le prendre pour une variable laissait l'image sans
/// recette.
#[test]
fn a_configfile_behind_a_device_prefix_is_followed() {
    const FEDORA: &[(&str, &str)] = &[
        (
            "/EFI/BOOT/grub.cfg",
            "search --file --set=root /boot/0xf20784ad\nset prefix=($root)/boot/grub2\nconfigfile ($root)/boot/grub2/grub.cfg\n",
        ),
        (
            "/boot/grub2/grub.cfg",
            "set default=\"1\"\nmenuentry \"Start Fedora-Workstation-Live\" --class fedora {\n\tlinux ($root)/boot/x86_64/loader/linux quiet rhgb  root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image\n\tinitrd ($root)/boot/x86_64/loader/initrd\n}\n",
        ),
    ];
    let (file, names) = files(FEDORA);
    let text = file("/EFI/BOOT/grub.cfg").unwrap();
    let recipe = Recipe::read_in(
        &text,
        "/EFI/BOOT/grub.cfg",
        "Fedora-WS-Live-44",
        &file,
        &names,
    )
    .expect("la recette de Fedora");
    assert_eq!(recipe.kernel, "/boot/x86_64/loader/linux");
    assert_eq!(recipe.initrd.as_deref(), Some("/boot/x86_64/loader/initrd"));
    assert_eq!(
        recipe.command_line,
        "quiet rhgb root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image"
    );
}

/// **Tails** : `isolinux.cfg` ouvre un menu (`kernel vesamenu.c32`, `append
/// live64.cfg`), et c'est `live64.cfg` qui porte le noyau, après un
/// `include`. Le module de menu n'est pas un noyau ; le fichier qu'il ouvre
/// est suivi, depuis le dossier de la recette.
#[test]
fn a_syslinux_menu_module_is_followed_to_its_entries() {
    const TAILS: &[(&str, &str)] = &[
        (
            "/isolinux/isolinux.cfg",
            "label select_menu\n       com32 ifcpu64.c32\n       append menu_64 -- menu_32 -- menu_32\nlabel menu_64\n       kernel vesamenu.c32\n       append live64.cfg\nlabel menu_32\n       com32 cat.c32\n       append sorry32.txt\ndefault select_menu\n",
        ),
        ("/isolinux/live64.cfg", "include menu.cfg\n\nlabel live\n\tmenu label Tails\n\tkernel /live/vmlinuz\n\tappend initrd=/live/initrd.img boot=live config quiet\n"),
        ("/isolinux/menu.cfg", "menu title SYSLINUX\ninclude stdmenu.cfg\n"),
        ("/isolinux/stdmenu.cfg", "menu color sel * #ffffffff #55555555 *\n"),
    ];
    let (file, names) = files(TAILS);
    let text = file("/isolinux/isolinux.cfg").unwrap();
    let recipe = Recipe::read_in(&text, "/isolinux/isolinux.cfg", "TAILS", &file, &names)
        .expect("la recette de Tails");
    assert_eq!(recipe.kernel, "/live/vmlinuz");
    assert_eq!(recipe.initrd.as_deref(), Some("/live/initrd.img"));
    assert_eq!(recipe.command_line, "boot=live config quiet");
}

/// **antiX et MX Linux reçoivent l'étiquette de leur volume.** Leur `init`
/// trie les disques par numéro majeur, et celui du disque virtio n'est pas
/// dans sa liste : MX s'arrêtait sur « No all devices found », son disque
/// présent. `blab=` lui fait chercher le volume par son nom. Pas pour un autre
/// système, ni quand l'image désigne déjà son support.
#[test]
fn antix_is_given_its_volume_label() {
    let mx = "label live\n kernel /antiX/vmlinuz\n append quiet splasht initrd=/antiX/initrd.gz\n";
    let none = |_: &str| None;
    let empty = |_: &str| Vec::new();
    let recipe = Recipe::read_in(mx, "/boot/syslinux/syslinux.cfg", "MX-Live", &none, &empty)
        .expect("la recette de MX");
    assert!(
        recipe.command_line.ends_with(" blab=MX-Live"),
        "{}",
        recipe.command_line
    );

    let own = "label live\n kernel /antiX/vmlinuz\n append buuid=1234 initrd=/antiX/initrd.gz\n";
    let recipe = Recipe::read_in(own, "/boot/syslinux/syslinux.cfg", "MX-Live", &none, &empty)
        .expect("la recette");
    assert!(
        !recipe.command_line.contains("blab="),
        "{}",
        recipe.command_line
    );

    let arch = "label arch\n kernel /arch/boot/x86_64/vmlinuz-linux\n append archisobasedir=arch\n";
    let recipe = Recipe::read_in(
        arch,
        "/boot/syslinux/syslinux.cfg",
        "ARCH_202611",
        &none,
        &empty,
    )
    .expect("la recette d'Arch");
    assert!(
        !recipe.command_line.contains("blab="),
        "{}",
        recipe.command_line
    );
}
