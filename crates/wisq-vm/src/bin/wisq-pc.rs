//! **Démarrer un vrai Linux sur la machine PC native**, et dire ce que ça a
//! coûté.
//!
//!     wisq-pc --kernel vmlinuz --initrd initramfs --cmdline 'console=ttyS0' \
//!             --ram 512 [--budget N] [--input 'cmd;;cmd'] [--until TEXTE]
//!
//! Le port série de l'invité sort sur la sortie standard. À la fin, la sortie
//! d'erreur dit les instructions retirées, les secondes et les MIPS — le
//! chiffre que le banc commun compare à celui du cœur Swift.
//!
//! `--input` tape des lignes au shell, séparées par `;;` : chacune part quand
//! l'invite (`--prompt`, `# ` par défaut ; plusieurs, séparées par `;;`, comme
//! `login: ;;# `) paraît sur le port série. `--until`
//! arrête la course dès que le port série a dit ce texte ; sans lui, elle
//! s'arrête quand l'invite revient après la dernière ligne tapée. `--budget`
//! borne les instructions retirées, et `--patience` les secondes de l'invité
//! passées à dormir sans rien dire.
//!
//! `--disque` branche un fichier en disque virtio (`vda`, 00:03.0, ligne 5)
//! par la carte des périphériques (`wisq-carte`) : le fichier est lu sur
//! place et jamais écrit ; ce que l'invité écrit va dans une couche
//! (`--couche`, `<disque>.couche` par défaut, et sa carte `.map`), reprise à
//! la course suivante. Sans `--disque`, la carte est branchée quand même : le
//! clavier, le pont PCI ; `--sans-carte` la débranche (les seuls 8259,
//! 8253, 16550 et CMOS de la machine, ce qu'était `wisq-pc` avant elle).
//!
//! `--horloge` pose l'heure de l'horloge CMOS (des secondes depuis 1970) au
//! lieu de celle de l'hôte : deux courses du même noyau retirent alors les
//! mêmes instructions. `--sans-jit` éteint le JIT (`x86::jit`) : les blocs
//! sont interprétés, aux mêmes instructions près. `--sans-blocs` éteint le
//! chemin rapide (`pc::blocs`), JIT compris :
//! chaque instruction passe par le pas à pas, le terme de comparaison.
//!
//! **L'écran** : `--display 1280x800` branche la carte de Bochs (00:02.0,
//! seize mébioctets de mémoire vidéo à `0xE000_0000`) et la tablette
//! (00:07.0, ligne 10), annonce le cadre au noyau par la page zéro, et met
//! `console=tty0` devant la ligne, quelle qu'elle soit (`--cmdline`, celle
//! d'une image, ou celle par défaut) : `Machine::charger` le fait sous un
//! écran, comme `X86Machine.load`. `--screen-dump image.ppm` y range l'image
//! à la fin ; `--screen-every N` aussi toutes les N secondes de l'hôte quand
//! elle a changé, numérotée à côté (`image-0001.ppm`…).
//!
//! **Une image d'installation** : `--iso fichier.iso` lit sa recette (le
//! `grub.cfg` ou l'`isolinux.cfg` qu'elle porte), en sort le noyau et les
//! initramfs, fait la ligne de commande de l'application
//! (`chargeur::ligne_d_une_image`) et branche l'image en disque — ce que fait
//! `IsoBoot` côté Swift. `--disk` est `--disque`.
//!
//! **Le clavier** : `--keys '30:root\n;;45:uname -a\n'` tape chaque texte au
//! clavier PS/2 de la carte (l'i8042, ligne 1) quand le temps de l'invité
//! passe ses secondes ; `\n` y est la touche Entrée. `--status N` dit sur la
//! sortie d'erreur, toutes les N secondes de l'hôte, où en est la course :
//! pour une course longue dont le noyau ne dit rien sur la console.
//! `--input-file f` tape au port série ce qu'on ajoute au fichier `f` pendant
//! la course (`echo 'ps' >> f`) : parler à un invité qu'on n'a pas fini de
//! comprendre sans le redémarrer.
//!
//! **Sauver et reprendre** : `--sauver f` écrit l'instantané de la machine
//! (`pc::instantane`, la carte comprise) à la fin de la course, les disques
//! scellés d'abord ; `--reprendre f` le reprend à la place du noyau, dans un
//! processus neuf, sur les mêmes disques (`--disque`, ou `--iso`) et le même
//! écran (`--display`). La première ligne de `--input` part alors tout de
//! suite : l'invite a été dite avant l'instantané.

use std::io::Write;
use std::time::Instant;

use std::path::Path;

use wisq_carte::fichier::DisqueFichier;
use wisq_carte::pc::{horloge_du_systeme, Disque};
use wisq_vm::iso9660::{Iso, OnDisk, Recipe};
use wisq_vm::pc::carte::CartePartagee;
use wisq_vm::pc::chargeur::{initramfs_bout_a_bout, ligne_d_une_image, ligne_posee};
use wisq_vm::pc::herites::HERTZ_DU_8253;
use wisq_vm::pc::instantane;
use wisq_vm::pc::memoire::RAM_MINIMALE;
use wisq_vm::pc::Poste;
use wisq_vm::x86_paging::Devices;

/// Ce que `--ram` accepte au plus, en mébioctets : soixante-quatre gibioctets.
/// Au-delà, c'est une faute de frappe plus sûrement qu'une machine. **Ce
/// plafond ne promet pas que le bloc s'alloue** : sous lui, c'est l'hôte qui
/// dit s'il a la place (`Machine::essayer`), et un refus sort en code 2
/// comme celui-ci, plutôt qu'en SIGABRT.
const RAM_MAXIMALE_EN_MEBIOCTETS: u64 = 64 << 10;

/// **Les octets que `--ram` demande**, ou rien quand le nombre dépasse le
/// plafond. Un décalage nu débordait en silence : 2^44 mébioctets valaient
/// zéro octet, et la machine démarrait sur son plancher sans rien dire.
fn ram_en_octets(mebioctets: u64) -> Option<u64> {
    if mebioctets > RAM_MAXIMALE_EN_MEBIOCTETS {
        return None;
    }
    mebioctets.checked_mul(1 << 20)
}

/// **Où `motif` paraît dans `texte`, à partir de l'octet `depuis`** : la
/// position, en octets depuis le début. Par octets, pour qu'un départ au
/// milieu d'un caractère ne fasse pas paniquer.
fn trouver(texte: &str, motif: &str, depuis: usize) -> Option<usize> {
    let octets = texte.as_bytes().get(depuis..)?;
    let motif = motif.as_bytes();
    if motif.is_empty() {
        return Some(depuis);
    }
    octets
        .windows(motif.len())
        .position(|fenetre| fenetre == motif)
        .map(|ici| ici + depuis)
}

/// **L'heure que l'horloge CMOS de l'invité reçoit**, en secondes depuis
/// 1970 : celle que `--horloge` donne, sinon celle de l'hôte.
fn heure(fixee: Option<u64>) -> u64 {
    fixee.unwrap_or_else(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |depuis| depuis.as_secs())
    })
}

/// Jusqu'où une recherche de `motif` qui n'a rien trouvé dans `texte` n'a
/// plus à revenir : tout sauf la fin, où un motif à cheval peut commencer.
fn deja_examine(texte: &str, motif: &str) -> usize {
    texte.len().saturating_sub(motif.len().saturating_sub(1))
}

struct Options {
    noyau: String,
    initramfs: Option<String>,
    ligne: Option<String>,
    ram: u64,
    budget: u64,
    entree: Vec<String>,
    jusqu_a: Option<String>,
    invite: String,
    patience: u64,
    muet: bool,
    battement: Option<u64>,
    horloge: Option<u64>,
    sans_blocs: bool,
    sans_jit: bool,
    disque: Option<String>,
    couche: Option<String>,
    sans_carte: bool,
    ecran: Option<(u32, u32)>,
    image: Option<String>,
    image_toutes: Option<f64>,
    iso: Option<String>,
    touches: Vec<(f64, String)>,
    etat_toutes: Option<f64>,
    fichier_d_entree: Option<String>,
    sauver: Option<String>,
    reprendre: Option<String>,
}

/// **`--keys`** : des `secondes:texte` séparés par `;;`, rangés par heure ;
/// `\n` dans le texte est la touche Entrée.
fn frappes(texte: &str) -> Option<Vec<(f64, String)>> {
    let mut frappes = texte
        .split(";;")
        .filter(|morceau| !morceau.is_empty())
        .map(|morceau| {
            let (quand, quoi) = morceau.split_once(':')?;
            let quand: f64 = quand.parse().ok().filter(|quand: &f64| *quand >= 0.0)?;
            Some((quand, quoi.replace("\\n", "\n")))
        })
        .collect::<Option<Vec<_>>>()?;
    frappes.sort_by(|a, b| a.0.total_cmp(&b.0));
    Some(frappes)
}

/// **`--display LxH`** : deux nombres non nuls, séparés par un `x`.
fn taille_d_ecran(texte: &str) -> Option<(u32, u32)> {
    let (largeur, hauteur) = texte.split_once('x')?;
    let largeur: u32 = largeur.parse().ok()?;
    let hauteur: u32 = hauteur.parse().ok()?;
    (largeur > 0 && hauteur > 0).then_some((largeur, hauteur))
}

/// **Une image au format PPM** (P6) : l'en-tête, puis rouge, vert, bleu par
/// pixel, pris de l'XRGB8888 de la carte (le bleu dans l'octet bas).
fn ppm(largeur: u32, hauteur: u32, xrgb: &[u8]) -> Vec<u8> {
    let mut sortie = format!("P6\n{largeur} {hauteur}\n255\n").into_bytes();
    sortie.reserve(xrgb.len() / 4 * 3);
    for pixel in xrgb.chunks_exact(4) {
        sortie.extend_from_slice(&[pixel[2], pixel[1], pixel[0]]);
    }
    sortie
}

/// L'image de l'écran de la carte, en PPM, et sa révision ; rien sans écran.
fn capturer(carte: &CartePartagee) -> Option<(u64, Vec<u8>)> {
    let carte = carte.tenir();
    let cadre = &carte.ecran()?.cadre;
    let (mode, octets) = cadre.image();
    Some((cadre.revision(), ppm(mode.largeur, mode.hauteur, &octets)))
}

/// Le nom de la `rang`-ième image : `image.ppm` donne `image-0001.ppm`.
/// L'extension se cherche dans le nom du fichier seul, après le dernier `/` ;
/// un nom qui commence par son seul point (`.ppm`, un fichier caché) n'en a
/// pas, et le rang va au bout.
fn nom_numerote(chemin: &str, rang: u32) -> String {
    let debut_du_nom = chemin.rfind('/').map_or(0, |ici| ici + 1);
    let (dossier, nom) = chemin.split_at(debut_du_nom);
    match nom.rsplit_once('.') {
        Some((tete, extension)) if !tete.is_empty() => {
            format!("{dossier}{tete}-{rang:04}.{extension}")
        }
        _ => format!("{chemin}-{rang:04}"),
    }
}

/// **Ce qui a été ajouté au fichier depuis la dernière fois** (`--input-file`) :
/// les octets au-delà de `lu`, qui avance jusqu'à la fin. Rien quand le
/// fichier n'a pas grandi, ou qu'il ne se lit pas (pas encore créé).
fn ajoute_depuis(chemin: &Path, lu: &mut usize) -> Option<Vec<u8>> {
    let contenu = std::fs::read(chemin).ok()?;
    let neuf = contenu.get(*lu..).filter(|neuf| !neuf.is_empty())?.to_vec();
    *lu = contenu.len();
    Some(neuf)
}

/// **Les `combien` RIP les plus relevés**, les plus fréquents d'abord, à
/// égalité le plus bas d'abord (pour que deux courses pareilles disent la
/// même chose).
fn plus_frequents(releves: impl Iterator<Item = (u64, u64)>, combien: usize) -> Vec<(u64, u64)> {
    let mut tries: Vec<(u64, u64)> = releves.collect();
    tries.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    tries.truncate(combien);
    tries
}

/// Ce qu'une image donne : le noyau, les initramfs, la ligne, la recette.
struct DeLImage {
    noyau: Vec<u8>,
    initramfs: Option<Vec<u8>>,
    ligne: String,
    recette: String,
}

/// **Ce qu'une image d'installation donne pour démarrer** : le noyau, les
/// initramfs mis bout à bout, la ligne de sa recette et le fichier d'où elle
/// vient. Chaque membre est borné à un gibioctet.
fn sortir_de_l_image(chemin: &str) -> Result<DeLImage, String> {
    const PLAFOND: usize = 1 << 30;
    let source = OnDisk::open(Path::new(chemin)).ok_or("illisible")?;
    let iso = Iso::open(source).ok_or("pas une image ISO 9660")?;
    let recette = Recipe::of(&iso).ok_or("aucune recette de démarrage")?;
    let lire = |dedans: &str| {
        iso.find(dedans)
            .filter(|entree| !entree.directory)
            .and_then(|entree| iso.read(&entree, PLAFOND))
            .ok_or_else(|| format!("{dedans} : introuvable dans l'image"))
    };
    let noyau = lire(&recette.kernel)?;
    let initramfs = match &recette.initrd {
        Some(liste) => {
            let parties = liste.split(' ').map(lire).collect::<Result<Vec<_>, _>>()?;
            Some(initramfs_bout_a_bout(&parties))
        }
        None => None,
    };
    Ok(DeLImage {
        noyau,
        initramfs,
        ligne: recette.command_line,
        recette: recette.from,
    })
}

fn usage() -> ! {
    eprintln!(
        "usage : wisq-pc --kernel <bzImage> [--initrd <fichier>] [--cmdline <texte>] \
         [--ram <Mio>] [--budget <instructions>] [--input 'cmd;;cmd'] [--until <texte>] \
         [--prompt <texte>] [--patience <secondes>] [--tick <instructions>] [--quiet] \
         [--horloge <secondes>] [--sans-blocs] [--sans-jit] [--disque <fichier> [--couche <fichier>]] [--sans-carte] \
         [--iso <image>] [--display <L>x<H>] [--screen-dump <image.ppm>] [--screen-every <secondes>] \
         [--keys 'secondes:texte;;…'] [--status <secondes>] [--input-file <fichier>] \
         [--sauver <instantané>] [--reprendre <instantané>]"
    );
    std::process::exit(2);
}

fn options() -> Options {
    let mut options = Options {
        noyau: String::new(),
        initramfs: None,
        ligne: None,
        ram: 512,
        budget: 20_000_000_000,
        entree: Vec::new(),
        jusqu_a: None,
        invite: "# ".to_string(),
        patience: 24,
        muet: false,
        battement: None,
        horloge: None,
        sans_blocs: false,
        sans_jit: false,
        disque: None,
        couche: None,
        sans_carte: false,
        ecran: None,
        image: None,
        image_toutes: None,
        iso: None,
        touches: Vec::new(),
        etat_toutes: None,
        fichier_d_entree: None,
        sauver: None,
        reprendre: None,
    };
    let mut arguments = std::env::args().skip(1);
    while let Some(nom) = arguments.next() {
        let mut valeur = || arguments.next().unwrap_or_else(|| usage());
        match nom.as_str() {
            "--kernel" => options.noyau = valeur(),
            "--initrd" => options.initramfs = Some(valeur()),
            "--cmdline" => options.ligne = Some(valeur()),
            "--ram" => options.ram = valeur().parse().unwrap_or_else(|_| usage()),
            "--budget" => options.budget = valeur().parse().unwrap_or_else(|_| usage()),
            "--input" => {
                options.entree = valeur()
                    .split(";;")
                    .filter(|ligne| !ligne.is_empty())
                    .map(str::to_string)
                    .collect();
            }
            "--until" => options.jusqu_a = Some(valeur()),
            "--prompt" => options.invite = valeur(),
            "--patience" => options.patience = valeur().parse().unwrap_or_else(|_| usage()),
            "--tick" => options.battement = Some(valeur().parse().unwrap_or_else(|_| usage())),
            "--quiet" => options.muet = true,
            "--horloge" => options.horloge = Some(valeur().parse().unwrap_or_else(|_| usage())),
            "--sans-blocs" => options.sans_blocs = true,
            "--sans-jit" => options.sans_jit = true,
            "--disque" | "--disk" => options.disque = Some(valeur()),
            "--iso" => options.iso = Some(valeur()),
            "--keys" => options.touches = frappes(&valeur()).unwrap_or_else(|| usage()),
            "--input-file" => options.fichier_d_entree = Some(valeur()),
            "--status" => {
                options.etat_toutes = Some(
                    valeur()
                        .parse()
                        .ok()
                        .filter(|secondes: &f64| *secondes > 0.0)
                        .unwrap_or_else(|| usage()),
                );
            }
            "--display" => {
                options.ecran = Some(taille_d_ecran(&valeur()).unwrap_or_else(|| usage()));
            }
            "--screen-dump" => options.image = Some(valeur()),
            "--screen-every" => {
                options.image_toutes = Some(
                    valeur()
                        .parse()
                        .ok()
                        .filter(|secondes: &f64| *secondes > 0.0)
                        .unwrap_or_else(|| usage()),
                );
            }
            "--couche" => options.couche = Some(valeur()),
            "--sauver" | "--save" => options.sauver = Some(valeur()),
            "--reprendre" | "--resume" => options.reprendre = Some(valeur()),
            "--sans-carte" => options.sans_carte = true,
            _ => usage(),
        }
    }
    if options.noyau.is_empty() && options.iso.is_none() && options.reprendre.is_none() {
        usage();
    }
    if options.sans_carte
        && (options.ecran.is_some()
            || options.iso.is_some()
            || !options.touches.is_empty()
            || options.sauver.is_some()
            || options.reprendre.is_some())
    {
        usage();
    }
    options
}

fn main() {
    let mut options = options();
    let lire = |chemin: &str| {
        std::fs::read(chemin).unwrap_or_else(|erreur| {
            eprintln!("wisq-pc : {chemin} : {erreur}");
            std::process::exit(1);
        })
    };
    // **Une image d'installation** : son noyau et ses initramfs, sauf ceux
    // qu'on nomme, sa ligne sauf celle qu'on donne, et l'image en disque.
    let mut ligne = options.ligne.clone();
    let (noyau, initramfs) = match options.iso.clone() {
        Some(image) => {
            let DeLImage {
                noyau,
                initramfs,
                ligne: recette,
                recette: depuis,
            } = sortir_de_l_image(&image).unwrap_or_else(|refus| {
                eprintln!("wisq-pc : --iso {image} : {refus}");
                std::process::exit(1);
            });
            eprintln!("recette : {depuis} : {recette}");
            if ligne.is_none() {
                ligne = Some(ligne_d_une_image(&recette));
            }
            options.disque.get_or_insert(image);
            let noyau = if options.noyau.is_empty() {
                noyau
            } else {
                lire(&options.noyau)
            };
            let initramfs = options.initramfs.as_deref().map(lire).or(initramfs);
            (noyau, initramfs)
        }
        // Une machine reprise n'a pas de noyau à charger.
        None if options.noyau.is_empty() => (Vec::new(), None),
        None => (lire(&options.noyau), options.initramfs.as_deref().map(lire)),
    };

    let Some(ram) = ram_en_octets(options.ram) else {
        eprintln!(
            "wisq-pc : --ram {} : au plus {RAM_MAXIMALE_EN_MEBIOCTETS} Mio",
            options.ram
        );
        std::process::exit(2);
    };
    if ram < RAM_MINIMALE {
        eprintln!(
            "wisq-pc : --ram {} : sous le plancher, la machine prend {} Mio",
            options.ram,
            RAM_MINIMALE >> 20
        );
    }
    // **Un poste** (`pc::poste`), comme l'application : la machine et sa
    // carte, branchée d'office. `--sans-carte` la débranche aussitôt.
    let Some(mut poste) = Poste::essayer(ram) else {
        eprintln!(
            "wisq-pc : --ram {} : l'hôte ne peut pas donner cette mémoire",
            options.ram
        );
        std::process::exit(2);
    };
    if let Some(battement) = options.battement {
        poste.machine.instructions_par_battement = battement.max(1);
    }
    // L'heure de l'hôte, lue une fois : l'horloge CMOS de l'invité part de là,
    // sauf quand `--horloge` en donne une.
    poste.machine.herites.cmos.regler(heure(options.horloge));
    poste.machine.blocs_actifs = !options.sans_blocs;
    if options.sans_jit {
        poste.machine.jit = None;
    }
    let carte = poste.commandes().carte().clone();
    // L'horloge CMOS de la carte, qui répond aux ports 0x70 et 0x71 : l'heure
    // figée par `--horloge`, celle de l'hôte sinon.
    match options.horloge {
        Some(secondes) => carte
            .tenir()
            .regler_heure((secondes as i64).saturating_mul(1000)),
        None => carte.tenir().horloge(horloge_du_systeme),
    }
    if let Some(disque) = options.disque.as_deref() {
        let couche = options
            .couche
            .clone()
            .unwrap_or_else(|| format!("{disque}.couche"));
        match DisqueFichier::ouvrir(Path::new(disque), Path::new(&couche)) {
            Ok(fichier) => poste
                .brancher_disque(Disque::Premier, fichier)
                .expect("machine éteinte"),
            Err(refus) => {
                eprintln!("wisq-pc : --disque {disque} : {refus}");
                std::process::exit(1);
            }
        }
    }
    // **L'écran et la tablette**, derrière la mémoire : la carte est tenue
    // des deux côtés (`pc::carte::brancher`), et le noyau reçoit le cadre.
    if let Some((largeur, hauteur)) = options.ecran {
        if poste.brancher_ecran(largeur, hauteur).is_err() {
            eprintln!("wisq-pc : --display {largeur}x{hauteur} : plus que seize mébioctets");
            std::process::exit(2);
        }
    }
    let carte = if options.sans_carte {
        poste.machine.peripheriques = None;
        poste.machine.cpu.devices = Devices(None);
        poste.machine.herites.cmos_ailleurs = false;
        None
    } else {
        Some(carte)
    };
    match options.reprendre.as_deref() {
        // **Une machine reprise** : l'instantané d'une autre course, sur les
        // mêmes disques et le même écran, au lieu du noyau.
        Some(chemin) => {
            let octets = lire(chemin);
            if let Err(refus) = instantane::reprendre(&mut poste, &octets) {
                eprintln!("wisq-pc : --reprendre {chemin} : {refus:?}");
                std::process::exit(1);
            }
            eprintln!(
                "reprise : {chemin} ({} octets) ; {} instructions déjà retirées",
                octets.len(),
                poste.machine.retirees
            );
        }
        None => {
            let placement = poste
                .charger(&noyau, ligne.as_deref(), initramfs.as_deref())
                .unwrap_or_else(|refus| {
                    eprintln!("wisq-pc : {refus}");
                    std::process::exit(1);
                });
            // La ligne que le noyau recevra, lue là où `Machine::charger` l'a
            // posée (`console=tty0` devant sous un écran) : rien n'est
            // recalculé ici.
            eprintln!(
                "ligne : {}",
                ligne_posee(&poste.machine.cpu.memory.bytes, &placement).unwrap_or_default()
            );
        }
    }
    let machine = &mut poste.machine;

    let hertz = machine.instructions_par_battement * HERTZ_DU_8253;
    let patience = options.patience.saturating_mul(hertz);
    let mut a_taper = options.entree.clone().into_iter();
    let mut prochaine = a_taper.next();
    let mut tapees = 0usize;
    // **Une machine reprise a déjà dit son invite**, avant d'être sauvée : la
    // première ligne part tout de suite, les suivantes à l'invite.
    if options.reprendre.is_some() {
        if let Some(ligne) = prochaine.take() {
            machine.taper(ligne.as_bytes());
            machine.taper(b"\n");
            tapees += 1;
            prochaine = a_taper.next();
        }
    }
    let mut serie = String::new();
    // Où la recherche de l'invite reprend : derrière ce qui a déjà servi.
    let mut depuis = 0usize;
    // **Ne chercher que dans ce qui n'a pas encore été examiné**, plus de quoi
    // tenir un motif à cheval : chercher dans toute la sortie à chaque tranche
    // faisait un coût qui croît avec elle, et que le banc comptait. Ce qui est
    // avant ces positions a été examiné sans rien trouver (ou a déjà servi).
    let mut examine_invite = 0usize;
    let mut examine_jusqu_a = 0usize;
    // L'attente au dernier signe de vie, pour compter le silence.
    let mut attente_au_dernier_signe = 0u64;
    let sortie = std::io::stdout();
    let debut = Instant::now();
    let fin: String;
    // Les images prises en route : la dernière révision rangée, son rang, et
    // l'instant de la prochaine.
    let mut revision_rangee = 0u64;
    let mut images = 0u32;
    let mut prochaine_image = options.image_toutes;
    let mut revision_au_dernier_signe = 0u64;
    let mut touches = options.touches.clone().into_iter().peekable();
    let mut prochain_etat = options.etat_toutes;
    // Où était RIP à chaque tranche, depuis le dernier état : ce que dit
    // `--status`, les plus fréquents d'abord, pour savoir où la course passe
    // son temps quand la console se tait.
    let mut releves: std::collections::HashMap<u64, u64> = std::collections::HashMap::new();
    // Les refus déjà dits en route : chacun une fois, dès qu'il arrive.
    let mut refus_dits = std::collections::BTreeSet::new();
    let mut refus_vus = 0usize;
    // Ce qui a déjà été lu du fichier d'entrée.
    let mut entree_lue = 0usize;
    let mut premiere = true;
    loop {
        // Entre deux tranches, cette boucle lit la RAM (l'écran) et tape au
        // port série ou au clavier, sans jamais écrire la RAM : après la
        // première, `poursuivre` garde les blocs décodés d'une tranche à
        // l'autre.
        let rendu = if std::mem::take(&mut premiere) {
            machine.tourner(200_000)
        } else {
            machine.poursuivre(200_000)
        };
        let octets = machine.sortie();
        if !octets.is_empty() {
            if !options.muet {
                let mut verrou = sortie.lock();
                let _ = verrou.write_all(&octets);
                let _ = verrou.flush();
            }
            serie.push_str(&String::from_utf8_lossy(&octets));
            attente_au_dernier_signe = machine.attente;
        }
        match rendu {
            Err(pourquoi) => {
                fin = format!("faute : {pourquoi}");
                break;
            }
            Ok(0) => {
                fin = "éteinte : un hlt que rien ne peut réveiller".to_string();
                break;
            }
            Ok(_) => {}
        }
        if let Some(texte) = &options.jusqu_a {
            if trouver(&serie, texte, examine_jusqu_a).is_some() {
                fin = format!("le port série a dit « {texte} »");
                break;
            }
            examine_jusqu_a = deja_examine(&serie, texte);
        }
        // La première des invites qui paraît, et sa longueur.
        let trouvee = options
            .invite
            .split(";;")
            .filter_map(|invite| {
                trouver(&serie, invite, depuis.max(examine_invite)).map(|ici| (ici, invite.len()))
            })
            .min();
        if trouvee.is_none() {
            examine_invite = options
                .invite
                .split(";;")
                .map(|invite| deja_examine(&serie, invite))
                .min()
                .unwrap_or(0);
        }
        if let Some((position, longueur)) = trouvee.map(|(ici, longueur)| (ici - depuis, longueur))
        {
            match prochaine.take() {
                Some(ligne) => {
                    machine.taper(ligne.as_bytes());
                    machine.taper(b"\n");
                    tapees += 1;
                    depuis += position + longueur;
                    prochaine = a_taper.next();
                    attente_au_dernier_signe = machine.attente;
                }
                None if options.jusqu_a.is_none() && tapees > 0 => {
                    fin = "l'invite est revenue après la dernière ligne tapée".to_string();
                    break;
                }
                None => {}
            }
        }
        if options.etat_toutes.is_some() {
            *releves.entry(machine.cpu.rip).or_default() += 1;
        }
        if let Some(quand) = prochain_etat {
            let ecoule = debut.elapsed().as_secs_f64();
            if ecoule >= quand {
                prochain_etat = options.etat_toutes.map(|toutes| quand + toutes);
                let revision = carte
                    .as_ref()
                    .and_then(|carte| carte.tenir().ecran().map(|ecran| ecran.cadre.revision()));
                eprintln!(
                    "état : {ecoule:.0} s ; {} instructions ({:.1} MIPS) ; invité {:.1} s ; \
                     rip {:#x} anneau {} IF {} ; écran {revision:?}",
                    machine.retirees,
                    machine.retirees as f64 / ecoule / 1e6,
                    (machine.retirees + machine.attente) as f64 / hertz as f64,
                    machine.cpu.rip,
                    machine.cpu.privilege(),
                    u8::from(machine.cpu.flags.interrupts_enabled()),
                );
                for (rip, fois) in plus_frequents(releves.drain(), 4) {
                    let octets: Vec<String> = (0..12u64)
                        .map_while(|rang| {
                            let octet = machine
                                .cpu
                                .fetch_memory(rip.wrapping_add(rang), wisq_vm::x86::Width::Byte)
                                .ok();
                            machine.cpu.faulted = false;
                            machine.cpu.unmapped = None;
                            octet.map(|octet| format!("{octet:02x}"))
                        })
                        .collect();
                    eprintln!("    rip {rip:#x} ×{fois} : {}", octets.join(" "));
                }
            }
        }
        for refus in &machine.refus[refus_vus..] {
            if refus_dits.len() < 64 && refus_dits.insert(refus.clone()) {
                eprintln!("refus dans un programme (en route) : {refus}");
            }
        }
        refus_vus = machine.refus.len();
        if let Some(neuf) = options
            .fichier_d_entree
            .as_deref()
            .and_then(|chemin| ajoute_depuis(Path::new(chemin), &mut entree_lue))
        {
            machine.taper(&neuf);
            attente_au_dernier_signe = machine.attente;
        }
        // Les frappes dont l'heure de l'invité est passée.
        if let Some(carte) = &carte {
            let maintenant = (machine.retirees + machine.attente) as f64 / hertz as f64;
            while let Some((_, texte)) = touches.next_if(|(quand, _)| *quand <= maintenant) {
                carte.tenir().taper_texte(&texte);
                attente_au_dernier_signe = machine.attente;
            }
        }
        // **Une image qui change est un signe de vie**, comme le port série :
        // un bureau ne dit plus rien sur la console.
        if let Some(carte) = &carte {
            let revision = carte
                .tenir()
                .ecran()
                .map_or(0, |ecran| ecran.cadre.revision());
            if revision != revision_au_dernier_signe {
                revision_au_dernier_signe = revision;
                attente_au_dernier_signe = machine.attente;
            }
        }
        if let (Some(chemin), Some(quand), Some(carte)) = (&options.image, prochaine_image, &carte)
        {
            if debut.elapsed().as_secs_f64() >= quand {
                prochaine_image = options.image_toutes.map(|toutes| quand + toutes);
                if let Some((revision, octets)) = capturer(carte) {
                    if revision != revision_rangee {
                        revision_rangee = revision;
                        images += 1;
                        let nom = nom_numerote(chemin, images);
                        let _ = std::fs::write(&nom, &octets);
                        let _ = std::fs::write(chemin, &octets);
                        eprintln!(
                            "image : {nom} ; {} instructions ; {:.1} s ; invité {:.1} s",
                            machine.retirees,
                            debut.elapsed().as_secs_f64(),
                            (machine.retirees + machine.attente) as f64 / hertz as f64,
                        );
                    }
                }
            }
        }
        if machine.retirees >= options.budget {
            fin = "budget épuisé".to_string();
            break;
        }
        if machine.arretee && machine.attente - attente_au_dernier_signe >= patience {
            fin = format!(
                "attente épuisée : {} s de l'invité sans rien dire",
                options.patience
            );
            break;
        }
    }
    let secondes = debut.elapsed().as_secs_f64();
    let retirees = machine.retirees;
    if !options.muet {
        println!();
    }
    for refus in &machine.refus {
        eprintln!("refus dans un programme : {refus}");
    }
    if !machine.ports_muets.is_empty() {
        let ports: Vec<String> = machine
            .ports_muets
            .iter()
            .map(|(port, fois)| format!("{port:#x}×{fois}"))
            .collect();
        eprintln!("ports sans réponse : {}", ports.join(" "));
    }
    eprintln!("fin : {fin}");
    if let (Some(chemin), Some(carte)) = (&options.image, &carte) {
        match capturer(carte) {
            Some((revision, octets)) => match std::fs::write(chemin, &octets) {
                Ok(()) => {
                    eprintln!("écran : {chemin} (révision {revision}, {images} images en route)")
                }
                Err(erreur) => eprintln!("écran : {chemin} : {erreur}"),
            },
            None => eprintln!("écran : aucun (--display manque)"),
        }
    }
    eprintln!("ram : {} Mio", machine.ram >> 20);
    eprintln!(
        "instructions retirées : {retirees} ; attente : {} ; temps de l'invité : {:.1} s",
        machine.attente,
        (retirees + machine.attente) as f64 / hertz as f64
    );
    if machine.blocs_actifs {
        eprintln!("blocs construits : {}", machine.blocs.construits);
        match machine.jit.as_deref() {
            Some(jit) => eprintln!(
                "JIT : {} blocs traduits ({} octets), {} passages par du code traduit dont {} chaînés",
                jit.traduits, jit.octets, jit.passages, jit.enchaines
            ),
            None => eprintln!("JIT : éteint"),
        }
    }
    eprintln!(
        "secondes : {secondes:.2} ; MIPS : {:.1}",
        retirees as f64 / secondes.max(1e-9) / 1e6
    );
    // **L'instantané, à la fin de la course** : les disques scellés d'abord,
    // comme `flushDisk` avant `snapshot` du côté Swift.
    if let Some(chemin) = &options.sauver {
        let debut = Instant::now();
        if !poste.commandes().vider_les_disques() {
            eprintln!("wisq-pc : --sauver : un disque a refusé de se vider");
            std::process::exit(1);
        }
        // Page par page, comme l'application (`wisq_pc_snapshot_to_file`) :
        // un instantané de plusieurs gibioctets ne passe jamais en mémoire.
        let ecrit = std::fs::File::create(chemin)
            .map_err(instantane::ErreurDEcriture::Io)
            .and_then(|fichier| {
                let mut tampon = std::io::BufWriter::with_capacity(1 << 20, fichier);
                instantane::sauver_vers(&poste, &mut tampon)
            });
        match ecrit {
            Ok(()) => eprintln!(
                "instantané : {chemin} ({} octets, {:.2} s)",
                std::fs::metadata(chemin).map_or(0, |m| m.len()),
                debut.elapsed().as_secs_f64()
            ),
            Err(erreur) => {
                eprintln!("wisq-pc : --sauver {chemin} : {erreur:?}");
                std::process::exit(1);
            }
        }
    }
    if fin.starts_with("faute") {
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **`--horloge` fixe l'heure de l'invité** ; sans lui, c'est celle de
    /// l'hôte (après le 20 novembre 2026, jour où ceci est écrit).
    #[test]
    fn the_clock_is_the_one_given_or_the_hosts() {
        assert_eq!(heure(Some(1_800_000_000)), 1_800_000_000);
        assert_eq!(heure(Some(0)), 0);
        assert!(heure(None) > 1_795_000_000);
    }

    /// **La recherche reprend où elle s'était arrêtée**, sans rien manquer
    /// d'un motif à cheval sur deux tranches, ni d'un caractère sur deux
    /// octets.
    #[test]
    fn the_search_resumes_where_it_stopped() {
        let mut texte = String::from("démarrage... (no");
        assert_eq!(trouver(&texte, "(none) # ", 0), None);
        let reprise = deja_examine(&texte, "(none) # ");
        assert_eq!(reprise, texte.len() - 8);
        texte.push_str("ne) # ");
        assert_eq!(trouver(&texte, "(none) # ", reprise), Some(14));
        assert_eq!(trouver(&texte, "# ", 14), Some(21));
        // Un départ au milieu de « é » ne panique pas.
        assert_eq!(trouver(&texte, "m", 2), Some(3));
        assert_eq!(trouver(&texte, "x", 99), None);
        assert_eq!(deja_examine("ab", "abcdef"), 0);
    }

    /// **`--display`** : deux nombres non nuls, séparés par un `x`.
    #[test]
    fn the_display_size_is_two_numbers() {
        assert_eq!(taille_d_ecran("1280x800"), Some((1280, 800)));
        assert_eq!(taille_d_ecran("1280x0"), None);
        assert_eq!(taille_d_ecran("0x800"), None, "une largeur nulle");
        assert_eq!(taille_d_ecran("0x0"), None);
        assert_eq!(taille_d_ecran("1280"), None);
        assert_eq!(taille_d_ecran("ax800"), None);
    }

    /// **`--keys`** : rangées par heure, `\n` pour Entrée, un deux-points
    /// après le premier gardé dans le texte ; une heure illisible refuse tout.
    #[test]
    fn keys_are_sorted_by_guest_time() {
        assert_eq!(
            frappes("45:uname -a\\n;;30:root\\n;;50:a:b"),
            Some(vec![
                (30.0, "root\n".to_string()),
                (45.0, "uname -a\n".to_string()),
                (50.0, "a:b".to_string()),
            ])
        );
        assert_eq!(frappes("x:root"), None);
        assert_eq!(frappes("-1:root"), None);
        assert_eq!(frappes("root"), None);
        // Un `;;` de trop, en queue ou doublé, ne refuse pas le reste.
        assert_eq!(
            frappes("30:root;;;;45:ls;;"),
            Some(vec![(30.0, "root".to_string()), (45.0, "ls".to_string())])
        );
    }

    /// **Les RIP les plus relevés d'abord**, à égalité le plus bas d'abord,
    /// pas plus que demandé.
    #[test]
    fn the_most_frequent_rips_come_first() {
        let releves = [(0x30, 2), (0x10, 5), (0x20, 2), (0x40, 1)];
        assert_eq!(
            plus_frequents(releves.into_iter(), 3),
            vec![(0x10, 5), (0x20, 2), (0x30, 2)]
        );
        assert_eq!(plus_frequents(releves.into_iter(), 9).len(), 4);
    }

    /// **`--input-file`** : seul ce qui a été ajouté depuis la dernière
    /// lecture est rendu, une fois ; rien quand le fichier n'a pas grandi ou
    /// n'existe pas.
    #[test]
    fn only_what_was_appended_is_typed() {
        let dossier = std::env::temp_dir().join(format!("wisq-pc-entree-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dossier);
        let chemin = dossier.join("entree.txt");
        let _ = std::fs::remove_file(&chemin);
        let mut lu = 0;
        assert_eq!(ajoute_depuis(&chemin, &mut lu), None, "pas de fichier");
        std::fs::write(&chemin, b"ps\n").unwrap();
        assert_eq!(ajoute_depuis(&chemin, &mut lu), Some(b"ps\n".to_vec()));
        assert_eq!(ajoute_depuis(&chemin, &mut lu), None, "rien de neuf");
        std::fs::write(&chemin, b"ps\nls /\n").unwrap();
        assert_eq!(ajoute_depuis(&chemin, &mut lu), Some(b"ls /\n".to_vec()));
        assert_eq!(lu, 8);
        let _ = std::fs::remove_dir_all(&dossier);
    }

    /// **Le PPM** : l'en-tête, puis rouge, vert, bleu — l'XRGB de la carte a
    /// le bleu dans l'octet bas.
    #[test]
    fn a_screen_is_written_as_ppm() {
        let image = ppm(2, 1, &[0x11, 0x22, 0x33, 0xFF, 1, 2, 3, 0]);
        assert_eq!(image, b"P6\n2 1\n255\n\x33\x22\x11\x03\x02\x01");
        assert_eq!(nom_numerote("/a/b.ppm", 7), "/a/b-0007.ppm");
        assert_eq!(nom_numerote("/a.d/b", 7), "/a.d/b-0007");
        assert_eq!(nom_numerote("b.ppm", 1), "b-0001.ppm");
        // Un nom fait de son seul point n'a pas d'extension, dans un dossier
        // ou non : le rang va au bout, pas devant le point.
        assert_eq!(nom_numerote(".ppm", 1), ".ppm-0001");
        assert_eq!(nom_numerote("/a/.ppm", 1), "/a/.ppm-0001");
        assert_eq!(nom_numerote("/a.d/.b.ppm", 2), "/a.d/.b-0002.ppm");
    }

    /// **Un mébioctet fait 2^20 octets, et le plafond est compris** : 65 536
    /// Mio s'acceptent, 65 537 non.
    #[test]
    fn la_ram_se_compte_en_mebioctets_jusqu_au_plafond_compris() {
        assert_eq!(ram_en_octets(512), Some(512 << 20));
        assert_eq!(ram_en_octets(1), Some(1 << 20));
        assert_eq!(ram_en_octets(65_536), Some(64 << 30));
        assert_eq!(ram_en_octets(65_537), None);
        assert_eq!(ram_en_octets(u64::MAX), None);
    }
}
