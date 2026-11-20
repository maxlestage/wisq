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
//!
//! `--horloge` pose l'heure de l'horloge CMOS (des secondes depuis 1970) au
//! lieu de celle de l'hôte : deux courses du même noyau retirent alors les
//! mêmes instructions. `--sans-blocs` éteint le chemin rapide (`pc::blocs`) :
//! chaque instruction passe par le pas à pas, le terme de comparaison.

use std::io::Write;
use std::time::Instant;

use wisq_vm::pc::herites::HERTZ_DU_8253;
use wisq_vm::pc::memoire::RAM_MINIMALE;
use wisq_vm::pc::Machine;

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
}

fn usage() -> ! {
    eprintln!(
        "usage : wisq-pc --kernel <bzImage> [--initrd <fichier>] [--cmdline <texte>] \
         [--ram <Mio>] [--budget <instructions>] [--input 'cmd;;cmd'] [--until <texte>] \
         [--prompt <texte>] [--patience <secondes>] [--tick <instructions>] [--quiet] \
         [--horloge <secondes>] [--sans-blocs]"
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
    let Some(mut machine) = Machine::essayer(ram) else {
        eprintln!(
            "wisq-pc : --ram {} : l'hôte ne peut pas donner cette mémoire",
            options.ram
        );
        std::process::exit(2);
    };
    if let Some(battement) = options.battement {
        machine.instructions_par_battement = battement.max(1);
    }
    // L'heure de l'hôte, lue une fois : l'horloge CMOS de l'invité part de là,
    // sauf quand `--horloge` en donne une.
    machine.herites.cmos.regler(heure(options.horloge));
    machine.blocs_actifs = !options.sans_blocs;
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
            if trouver(&serie, texte, examine_jusqu_a).is_some() {
                fin = format!("le port série a dit « {texte} »");
                break;
            }
            examine_jusqu_a = deja_examine(&serie, texte);
        }
        let trouvee = trouver(&serie, &options.invite, depuis.max(examine_invite));
        if trouvee.is_none() {
            examine_invite = deja_examine(&serie, &options.invite);
        }
        if let Some(position) = trouvee.map(|ici| ici - depuis) {
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
    eprintln!("ram : {} Mio", machine.ram >> 20);
    eprintln!(
        "instructions retirées : {retirees} ; attente : {} ; temps de l'invité : {:.1} s",
        machine.attente,
        (retirees + machine.attente) as f64 / hertz as f64
    );
    if machine.blocs_actifs {
        eprintln!("blocs construits : {}", machine.blocs.construits);
    }
    eprintln!(
        "secondes : {secondes:.2} ; MIPS : {:.1}",
        retirees as f64 / secondes.max(1e-9) / 1e6
    );
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
