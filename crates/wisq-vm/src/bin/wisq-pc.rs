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
//! l'invite (`--prompt`, `# ` par défaut) paraît sur le port série. `--until`
//! arrête la course dès que le port série a dit ce texte ; sans lui, elle
//! s'arrête quand l'invite revient après la dernière ligne tapée. `--budget`
//! borne les instructions retirées, et `--patience` les secondes de l'invité
//! passées à dormir sans rien dire.

use std::io::Write;
use std::time::Instant;

use wisq_vm::pc::herites::HERTZ_DU_8253;
use wisq_vm::pc::memoire::RAM_MINIMALE;
use wisq_vm::pc::Machine;

/// Ce que `--ram` accepte au plus, en mébioctets : soixante-quatre gibioctets.
/// Au-delà, c'est une faute de frappe plus sûrement qu'une machine — et le
/// bloc de l'hôte ne s'allouerait pas.
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
}

fn usage() -> ! {
    eprintln!(
        "usage : wisq-pc --kernel <bzImage> [--initrd <fichier>] [--cmdline <texte>] \
         [--ram <Mio>] [--budget <instructions>] [--input 'cmd;;cmd'] [--until <texte>] \
         [--prompt <texte>] [--patience <secondes>] [--tick <instructions>] [--quiet]"
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
            _ => usage(),
        }
    }
    if options.noyau.is_empty() {
        usage();
    }
    options
}

fn main() {
    let options = options();
    let lire = |chemin: &str| {
        std::fs::read(chemin).unwrap_or_else(|erreur| {
            eprintln!("wisq-pc : {chemin} : {erreur}");
            std::process::exit(1);
        })
    };
    let noyau = lire(&options.noyau);
    let initramfs = options.initramfs.as_deref().map(lire);

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
    let mut machine = Machine::nouvelle(ram);
    if let Some(battement) = options.battement {
        machine.instructions_par_battement = battement.max(1);
    }
    // L'heure de l'hôte, lue une fois : l'horloge CMOS de l'invité part de là.
    let maintenant = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |depuis| depuis.as_secs());
    machine.herites.cmos.regler(maintenant);
    if let Err(refus) =
        machine.charger(&noyau, options.ligne.as_deref(), initramfs.as_deref(), None)
    {
        eprintln!("wisq-pc : {refus}");
        std::process::exit(1);
    }

    let hertz = machine.instructions_par_battement * HERTZ_DU_8253;
    let patience = options.patience.saturating_mul(hertz);
    let mut a_taper = options.entree.clone().into_iter();
    let mut prochaine = a_taper.next();
    let mut tapees = 0usize;
    let mut serie = String::new();
    // Où la recherche de l'invite reprend : derrière ce qui a déjà servi.
    let mut depuis = 0usize;
    // L'attente au dernier signe de vie, pour compter le silence.
    let mut attente_au_dernier_signe = 0u64;
    let sortie = std::io::stdout();
    let debut = Instant::now();
    let fin: String;
    loop {
        let rendu = machine.tourner(200_000);
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
            if serie.contains(texte.as_str()) {
                fin = format!("le port série a dit « {texte} »");
                break;
            }
        }
        if let Some(position) = serie[depuis..].find(&options.invite) {
            match prochaine.take() {
                Some(ligne) => {
                    machine.taper(ligne.as_bytes());
                    machine.taper(b"\n");
                    tapees += 1;
                    depuis += position + options.invite.len();
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
    eprintln!(
        "instructions retirées : {retirees} ; attente : {} ; temps de l'invité : {:.1} s",
        machine.attente,
        (retirees + machine.attente) as f64 / hertz as f64
    );
    eprintln!(
        "secondes : {secondes:.2} ; MIPS : {:.1}",
        retirees as f64 / secondes.max(1e-9) / 1e6
    );
    if fin.starts_with("faute") {
        std::process::exit(1);
    }
}
