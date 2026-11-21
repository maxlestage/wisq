//! **Démarrer quelque chose sur la machine PC native, du chargeur au dernier
//! `hlt`.**
//!
//! Un vrai noyau ne se commite pas — douze mégaoctets de binaire sous GPL n'ont
//! rien à faire dans le dépôt —, donc le test de tous les jours démarre un
//! **noyau factice** : un `bzImage` de quelques centaines d'octets, avec un
//! vrai en-tête de démarrage, qui fait en petit ce qu'un Linux fait en grand.
//! Il lit la page zéro que RSI désigne, écrit sur le port série, pose une
//! IDT, initialise le 8259, arme le 8253, dort sur `hlt`, se fait réveiller
//! cinq fois par l'horloge, et s'éteint.
//!
//! Le vrai noyau, lui, se démarre quand on le désigne : `WISQ_PC_KERNEL`
//! (et `WISQ_PC_INITRD`, `WISQ_PC_ATTENDU`) — voir le dernier test, qui se
//! tait bruyamment quand il n'a rien à démarrer.

use wisq_vm::pc::chargeur::LIGNE_PAR_DEFAUT;
use wisq_vm::pc::herites::{HERTZ_DU_8253, INSTRUCTIONS_PAR_BATTEMENT};
use wisq_vm::pc::{Issue, Machine};

mod noyau_factice;
use noyau_factice::image;

fn demarrer(ligne: &str) -> (Machine, Issue, String) {
    let mut machine = Machine::nouvelle(0);
    machine
        .charger(&image(), Some(ligne), None, None)
        .expect("le noyau factice doit se charger");
    let issue = machine.executer(50_000_000);
    let sortie = String::from_utf8(machine.sortie()).expect("du texte");
    (machine, issue, sortie)
}

#[test]
fn a_tiny_kernel_boots_ticks_five_times_and_powers_off() {
    let (machine, issue, sortie) = demarrer("console=ttyS0 un=deux");
    assert_eq!(
        sortie, "wisq-noyau-factice\nconsole=ttyS0 un=deux\n.....\nFIN\n",
        "la bannière, la ligne de commande lue dans la page zéro, cinq battements, la fin"
    );
    assert_eq!(
        issue,
        Issue::Eteinte,
        "un hlt avec les interruptions coupées : plus rien ne peut arriver"
    );
    assert!(machine.arretee);
    assert!(
        !machine.cpu.flags.interrupts_enabled(),
        "le noyau a coupé les interruptions avant de s'arrêter"
    );
    // Le processeur est dans l'état que le noyau a posé.
    assert_eq!(machine.systeme.idt.limite, 0x21 * 16 - 1);
    assert_eq!(machine.herites.maitre.base_des_vecteurs, 0x20);
    assert_eq!(machine.herites.maitre.masque, 0xFE);
    assert_eq!(
        machine.herites.maitre.service, 0,
        "chaque battement a été acquitté"
    );
    assert_eq!(machine.herites.minuterie.rechargement, 1193);
    assert_eq!(machine.cpu.regs[3], 5, "cinq battements comptés");
    // **Le temps a passé à dormir, pas à tourner** : cinq millisecondes de
    // l'invité, pour quelques centaines d'instructions.
    assert!(machine.retirees < 1000, "{} instructions", machine.retirees);
    let millisecondes =
        (machine.retirees + machine.attente) * 1000 / (INSTRUCTIONS_PAR_BATTEMENT * HERTZ_DU_8253);
    assert_eq!(millisecondes, 5, "cinq battements d'une milliseconde");
    assert!(machine.refus.is_empty() && machine.ports_muets.is_empty());
}

/// Le démarrage est conduit par le compte d'instructions, pas par l'horloge
/// de l'hôte : deux courses du même noyau arrivent au même endroit. Un
/// démarrage qui n'est pas reproductible est un démarrage dont une panne ne
/// se rejoue pas.
#[test]
fn the_same_image_boots_the_same_way_twice() {
    let (premiere, _, dit) = demarrer("a");
    let (seconde, _, redit) = demarrer("a");
    assert_eq!(dit, redit);
    assert_eq!(premiere.retirees, seconde.retirees);
    assert_eq!(premiere.attente, seconde.attente);
    assert_eq!(premiere.cpu.regs, seconde.cpu.regs);
}

/// Le budget compte le temps, pas seulement le travail : une machine qui dort
/// le consomme aussi, et rend la main à l'heure dite.
#[test]
fn the_budget_counts_sleeping_time_too() {
    let mut machine = Machine::nouvelle(0);
    machine.charger(&image(), None, None, None).expect("chargé");
    // Moins de deux millisecondes de l'invité : un battement, pas cinq.
    let budget = 2 * 1193 * INSTRUCTIONS_PAR_BATTEMENT - 1000;
    assert_eq!(machine.executer(budget), Issue::Arretee);
    let sortie = String::from_utf8(machine.sortie()).expect("du texte");
    assert!(sortie.ends_with("\n."), "un seul battement : {sortie:?}");
    assert!(machine.retirees + machine.attente >= budget);
    assert!(machine.retirees + machine.attente < budget + 300);
    // Et la course reprend où elle s'était arrêtée.
    assert_eq!(machine.executer(50_000_000), Issue::Eteinte);
    assert_eq!(String::from_utf8(machine.sortie()).unwrap(), "....\nFIN\n");
}

/// Un fichier qui n'est pas un noyau est refusé au chargement, et la machine
/// le dit plutôt que de sauter dans des zéros.
#[test]
fn what_is_not_a_kernel_is_refused() {
    let mut machine = Machine::nouvelle(0);
    assert_eq!(
        machine.charger(&[0u8; 4096], None, None, None),
        Err(wisq_vm::pc::Refus::PasUnNoyau)
    );
    assert!(machine.placement().is_none());
}

// ---- L'outil `wisq-pc`, lancé pour de bon ----

/// Un fichier de travail, dans le dossier que Cargo donne aux tests.
fn fichier(nom: &str, octets: &[u8]) -> String {
    let chemin = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join(nom);
    std::fs::write(&chemin, octets).expect("le dossier de travail des tests s'écrit");
    chemin.to_str().expect("un chemin lisible").to_string()
}

/// Lancer `wisq-pc`, et rendre son code de sortie, sa sortie et sa sortie
/// d'erreur.
fn wisq_pc(arguments: &[&str]) -> (Option<i32>, String, String) {
    let rendu = std::process::Command::new(env!("CARGO_BIN_EXE_wisq-pc"))
        .args(arguments)
        .output()
        .expect("wisq-pc se lance");
    (
        rendu.status.code(),
        String::from_utf8_lossy(&rendu.stdout).into_owned(),
        String::from_utf8_lossy(&rendu.stderr).into_owned(),
    )
}

/// L'outil démarre le noyau factice : le port série sort sur la sortie
/// standard, et la fin est dite sur la sortie d'erreur.
#[test]
fn the_tool_boots_the_tiny_kernel_and_says_how_it_ended() {
    let noyau = fichier("outil-noyau.bin", &image());
    let (code, sortie, erreurs) = wisq_pc(&["--kernel", &noyau, "--cmdline", "console=ttyS0 a=b"]);
    assert_eq!(code, Some(0), "{erreurs}");
    assert!(
        sortie.starts_with("wisq-noyau-factice\nconsole=ttyS0 a=b\n.....\nFIN\n"),
        "{sortie:?}"
    );
    assert!(erreurs.contains("fin : éteinte"), "{erreurs}");
    assert!(erreurs.contains("instructions retirées : "), "{erreurs}");
    assert!(
        !erreurs.contains("--ram"),
        "512 Mio : rien à dire : {erreurs}"
    );
    assert!(erreurs.contains("\nram : 512 Mio\n"), "{erreurs}");
}

/// **La ligne que l'outil affiche est celle que le noyau reçoit** : le noyau
/// factice renvoie la sienne sur le port série, et `ligne : …` la dit
/// octet pour octet — `console=tty0` devant sous un écran, rien devant sans
/// lui, la ligne par défaut quand aucune n'est donnée.
#[test]
fn the_tool_shows_the_line_the_kernel_receives() {
    let noyau = fichier("outil-ligne.bin", &image());
    for (arguments, attendue) in [
        (
            &["--cmdline", "console=ttyS0 a=b", "--display", "640x480"][..],
            "console=tty0 console=ttyS0 a=b".to_string(),
        ),
        (
            &["--cmdline", "console=ttyS0 a=b"],
            "console=ttyS0 a=b".to_string(),
        ),
        (
            &["--display", "640x480"],
            format!("console=tty0 {LIGNE_PAR_DEFAUT}"),
        ),
        (&[], LIGNE_PAR_DEFAUT.to_string()),
    ] {
        let mut tous = vec!["--kernel", noyau.as_str()];
        tous.extend_from_slice(arguments);
        let (code, sortie, erreurs) = wisq_pc(&tous);
        assert_eq!(code, Some(0), "{arguments:?} : {erreurs}");
        assert!(
            sortie.starts_with(&format!("wisq-noyau-factice\n{attendue}\n")),
            "{arguments:?} : le noyau a reçu {sortie:?}"
        );
        assert!(
            erreurs.contains(&format!("\nligne : {attendue}\n"))
                || erreurs.starts_with(&format!("ligne : {attendue}\n")),
            "{arguments:?} : l'outil a dit {erreurs:?}"
        );
    }
}

/// **Avec ou sans blocs, l'outil retire les mêmes instructions** : le
/// chemin rapide (`pc::blocs`) ne change pas ce que l'invité exécute, et
/// `--sans-blocs` l'éteint — l'outil ne dit alors aucun bloc construit.
#[test]
fn the_tool_retires_the_same_instructions_with_and_without_blocks() {
    let noyau = fichier("outil-blocs.bin", &image());
    let compte = |erreurs: &str| {
        erreurs
            .lines()
            .find(|ligne| ligne.starts_with("instructions retirées : "))
            .map(str::to_string)
    };
    let (code, sortie, erreurs) = wisq_pc(&["--kernel", &noyau, "--horloge", "1800000000"]);
    assert_eq!(code, Some(0), "{erreurs}");
    let (code_lent, sortie_lente, erreurs_lentes) = wisq_pc(&[
        "--kernel",
        &noyau,
        "--horloge",
        "1800000000",
        "--sans-blocs",
    ]);
    assert_eq!(code_lent, Some(0), "{erreurs_lentes}");
    assert_eq!(sortie, sortie_lente);
    assert!(compte(&erreurs).is_some(), "{erreurs}");
    assert_eq!(compte(&erreurs), compte(&erreurs_lentes));
    assert!(erreurs.contains("blocs construits : "), "{erreurs}");
    assert!(
        !erreurs_lentes.contains("blocs construits"),
        "{erreurs_lentes}"
    );
}

/// **Ce que `--ram` demande est ce que la machine reçoit**, au mébioctet près,
/// jusqu'au plafond compris : 65 536 Mio ne sont pas refusés par le plafond.
/// Sur un hôte qui n'a pas la place, c'est l'hôte qui refuse, en code 2 et
/// avec son propre message — jamais un SIGABRT.
#[test]
fn the_tool_gives_the_ram_it_was_asked_for() {
    let noyau = fichier("outil-ram-donnee.bin", &image());
    for demande in ["200", "1000"] {
        let (code, sortie, erreurs) = wisq_pc(&["--kernel", &noyau, "--ram", demande]);
        assert_eq!(code, Some(0), "--ram {demande} : {erreurs}");
        assert!(sortie.contains("FIN"), "{sortie:?}");
        assert!(
            erreurs.contains(&format!("\nram : {demande} Mio\n")),
            "{erreurs}"
        );
    }
    let (code, _, erreurs) = wisq_pc(&["--kernel", &noyau, "--ram", "65536", "--budget", "1000"]);
    assert!(
        !erreurs.contains("au plus"),
        "le plafond est compris : {erreurs}"
    );
    match code {
        Some(0) => assert!(erreurs.contains("\nram : 65536 Mio\n"), "{erreurs}"),
        Some(2) => assert!(
            erreurs.contains("--ram 65536 : l'hôte ne peut pas donner cette mémoire"),
            "{erreurs}"
        ),
        autre => panic!("--ram 65536 : {autre:?}, ni démarré ni refusé : {erreurs}"),
    }
}

/// **Un noyau coupé est nommé comme tel**, et l'outil sort avec le code 1 sans
/// rien démarrer.
#[test]
fn the_tool_names_a_truncated_kernel() {
    let entier = image();
    let noyau = fichier("outil-coupe.bin", &entier[..entier.len() - 100]);
    let (code, sortie, erreurs) = wisq_pc(&["--kernel", &noyau]);
    assert_eq!(code, Some(1));
    assert!(
        erreurs.contains("le fichier est plus court que son en-tête ne l'annonce"),
        "{erreurs}"
    );
    assert_eq!(sortie, "", "rien n'a démarré");
}

/// **`--ram` ne déborde pas en silence.** Deux puissance quarante-quatre
/// mébioctets font zéro octet après un décalage de vingt bits, et la machine
/// démarrait sur son plancher sans rien dire : c'est un refus. Sous le
/// plancher, elle démarre — et le dit.
#[test]
fn the_tool_refuses_a_ram_size_it_cannot_give() {
    let noyau = fichier("outil-ram.bin", &image());
    for demande in ["17592186044416", "65537", "18446744073709551615"] {
        let (code, sortie, erreurs) = wisq_pc(&["--kernel", &noyau, "--ram", demande]);
        assert_eq!(code, Some(2), "--ram {demande} : {erreurs}");
        assert!(
            erreurs.contains(&format!("--ram {demande} : au plus 65536 Mio")),
            "{erreurs}"
        );
        assert_eq!(sortie, "", "--ram {demande} : rien n'a démarré");
    }
    let (code, sortie, erreurs) = wisq_pc(&["--kernel", &noyau, "--ram", "4"]);
    assert_eq!(code, Some(0), "{erreurs}");
    assert!(sortie.contains("FIN"), "{sortie:?}");
    assert!(
        erreurs.contains("--ram 4 : sous le plancher, la machine prend 128 Mio"),
        "{erreurs}"
    );
}

/// **Un vrai noyau, quand on en désigne un.**
///
///     WISQ_PC_KERNEL=vmlinuz-virt WISQ_PC_INITRD=initramfs.cpio \
///       WISQ_PC_ATTENDU=WISQ-USERSPACE-OK cargo test --release -p wisq-vm --test pc_demarrage
///
/// Sans `WISQ_PC_ATTENDU`, le test attend « Run /init as init process » : le
/// noyau s'est décompressé, a trouvé son horloge et ses interruptions, et a
/// déballé son initramfs. Avec l'initramfs de `scripts/build-userspace-probe.py`,
/// `WISQ-USERSPACE-OK` dit qu'un programme a tourné en anneau trois et que son
/// appel système a écrit sur la console.
#[test]
fn a_real_kernel_reaches_what_is_expected_of_it() {
    let Some(noyau) = std::env::var("WISQ_PC_KERNEL")
        .ok()
        .and_then(|chemin| std::fs::read(chemin).ok())
    else {
        eprintln!("noyau PC absent : définir WISQ_PC_KERNEL pour ce test");
        return;
    };
    let initramfs = std::env::var("WISQ_PC_INITRD")
        .ok()
        .and_then(|chemin| std::fs::read(chemin).ok());
    let attendu = std::env::var("WISQ_PC_ATTENDU")
        .unwrap_or_else(|_| "Run /init as init process".to_string());
    let budget = std::env::var("WISQ_PC_BUDGET")
        .ok()
        .and_then(|texte| texte.parse().ok())
        .unwrap_or(3_000_000_000u64);
    let mut machine = Machine::nouvelle(512 << 20);
    machine
        .charger(
            &noyau,
            Some("console=ttyS0,115200 earlyprintk=serial,ttyS0,115200,keep console=ttyS0"),
            initramfs.as_deref(),
            None,
        )
        .expect("le noyau doit se charger");
    let mut sortie = String::new();
    let issue = loop {
        let issue = machine.executer(20_000_000);
        sortie.push_str(&String::from_utf8_lossy(&machine.sortie()));
        if sortie.contains(&attendu) || issue != Issue::Arretee || machine.retirees >= budget {
            break issue;
        }
    };
    let fin = &sortie[sortie.len().saturating_sub(1500)..];
    assert!(
        sortie.contains("Linux version"),
        "la bannière du noyau doit apparaître ; issue {issue:?}, sortie : {fin}"
    );
    assert!(
        sortie.contains(&attendu),
        "« {attendu} » n'a pas été dit en {} instructions ; issue {issue:?}, fin de la sortie : {fin}",
        machine.retirees
    );
    assert!(
        machine.refus.is_empty(),
        "aucun programme ne doit avoir reçu d'instruction refusée : {:?}",
        machine.refus
    );
}
