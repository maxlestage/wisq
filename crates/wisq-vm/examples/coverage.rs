// Combien du vrai noyau le compilateur accepte-t-il ?
use std::fs;
use wisq_vm::x86::{decode, Op};
use wisq_vm::x86_wasm::{Module, Survey};

fn main() {
    let path = std::env::args().nth(1).expect("le chemin du noyau");
    let bytes = fs::read(&path).expect("le noyau");
    // Le texte du noyau : on part du début et on désassemble linéairement pour
    // compter, puis on compile des régions depuis chaque début de bloc.
    let mut at = 0usize;
    let (mut decoded, mut unknown) = (0usize, 0usize);
    let mut refused: std::collections::BTreeMap<String, usize> = Default::default();
    // Un échantillon : les huit premiers mégaoctets de texte suffisent à donner
    // la proportion, et le fichier entier prendrait des minutes.
    let limit = bytes.len().min(8 << 20);
    while at < limit {
        match decode(&bytes[at..]) {
            Some(step) => {
                decoded += 1;
                at += step.length.max(1);
            }
            None => {
                unknown += 1;
                *refused.entry(format!("{:02x}", bytes[at])).or_default() += 1;
                at += 1;
            }
        }
    }
    println!("décodage linéaire : {decoded} instructions lues, {unknown} octets refusés");
    let total = decoded + unknown;
    println!(
        "  soit {:.1} % de succès",
        100.0 * decoded as f64 / total as f64
    );
    let mut worst: Vec<_> = refused.into_iter().collect();
    worst.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
    print!("  opcodes refusés les plus fréquents :");
    for (op, n) in worst.iter().take(12) {
        print!(" {op}×{n}");
    }
    println!();

    // Et la vraie question : combien de **régions** se compilent entièrement ?
    //
    // **Deux sondes, et elles ne mesurent pas la même chose.** La première part
    // tous les 512 octets depuis le début du fichier. C'est simple, et c'est
    // pour ça qu'elle a servi longtemps — mais un processeur n'entre pas comme
    // ça : elle tombe au milieu des instructions, dans les tables de données,
    // dans le bourrage entre fonctions. Le taux qu'elle rend mélange donc « le
    // compilateur ne sait pas » et « ce n'est pas du code », et les deux ne se
    // corrigent pas de la même façon. Elle est gardée comme repère, parce que
    // toute la série l'a citée.
    let (mut ok, mut no) = (0usize, 0usize);
    let mut cursor = 0usize;
    let mut tried = 0usize;
    while cursor < limit && tried < 20000 {
        if Module::region(&bytes[cursor..limit.min(cursor + 4096)], 0x30000000, 0).is_some() {
            ok += 1;
        } else {
            no += 1;
        }
        tried += 1;
        cursor += 512;
    }
    println!(
        "régions tous les 512 octets : {ok} compilées, {no} refusées ({:.1} %)",
        100.0 * ok as f64 / (ok + no) as f64
    );

    // **La seconde part de là où l'exécution entre vraiment.** Les cibles des
    // `call` à déplacement fixe sont des débuts de fonction — c'est la
    // définition d'un appel — et elles se relèvent au passage du décodage
    // linéaire, sans rien de plus qu'un ensemble.
    let mut entries: std::collections::BTreeSet<usize> = Default::default();
    let mut at = 0usize;
    while at < limit {
        match decode(&bytes[at..]) {
            Some(step) => {
                if step.op == Op::Call {
                    let target = at as i64 + step.length as i64 + step.imm as i64;
                    if target >= 0 && (target as usize) < limit {
                        entries.insert(target as usize);
                    }
                }
                at += step.length.max(1);
            }
            None => at += 1,
        }
    }
    // **Et pourquoi les autres sont refusées.** Un refus a deux causes possibles
    // et elles ne se corrigent pas pareil : un octet que le décodeur ne lit pas,
    // ou une instruction que l'émetteur ne sait pas traduire. Les confondre
    // ferait chercher une instruction manquante là où c'est la traduction qui
    // manque.
    let (mut hit, mut refused) = (0usize, 0usize);
    let mut blame: std::collections::BTreeMap<String, usize> = Default::default();
    for entry in entries.iter().take(20000) {
        let end = limit.min(entry + 4096);
        if Module::region(&bytes[*entry..end], 0x30000000, 0).is_some() {
            hit += 1;
            continue;
        }
        refused += 1;
        let mut walk = *entry;
        let mut culprit = None;
        while walk < end {
            match decode(&bytes[walk..end]) {
                Some(step) => walk += step.length.max(1),
                None => {
                    // **Coupé par la fenêtre, ou vraiment inconnu ?** La région
                    // s'arrête à quatre kibioctets, et une instruction à cheval
                    // sur ce bord ne se décode pas — pas parce que le décodeur
                    // l'ignore, mais parce qu'il lui manque des octets. Compter
                    // ça comme un manque gonfle le refus et désigne des
                    // opcodes qui ne sont pas en cause : le relevé accusait
                    // `48`, `4c` et `0f 85`, qui sont tous décodés depuis
                    // toujours. On rejuge donc avec le reste du fichier.
                    if decode(&bytes[walk..limit]).is_some() {
                        culprit = Some("coupé par la fenêtre".into());
                        break;
                    }
                    // Un préfixe ne dit rien tout seul : c'est l'octet d'après
                    // qui nomme l'instruction refusée.
                    culprit = Some(match bytes[walk] {
                        0xf2 | 0xf3 | 0x0f | 0x66 => format!(
                            "{:02x}-{:02x}",
                            bytes[walk],
                            bytes.get(walk + 1).copied().unwrap_or(0)
                        ),
                        other => format!("{other:02x}"),
                    });
                    break;
                }
            }
        }
        *blame
            .entry(culprit.unwrap_or_else(|| "l'émetteur refuse".into()))
            .or_default() += 1;
    }
    println!(
        "régions depuis les cibles de `call` : {hit} compilées, {refused} refusées ({:.1} %) \
         — {} entrées distinctes",
        100.0 * hit as f64 / (hit + refused).max(1) as f64,
        entries.len()
    );
    let mut worst: Vec<_> = blame.into_iter().collect();
    worst.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
    // **Séparer ce qui manque de ce qui a été coupé.** Le second n'est pas un
    // trou du décodeur : c'est la fenêtre de la sonde, et l'annoncer avec le
    // reste ferait chercher une instruction là où il n'y a qu'un bord.
    let cut = worst
        .iter()
        .find(|(why, _)| why == "coupé par la fenêtre")
        .map(|(_, n)| *n)
        .unwrap_or(0);
    println!(
        "  dont {cut} coupées par le bord de la fenêtre de 4 Kio — pas un manque du décodeur, \
         {} vraiment refusées",
        refused - cut
    );
    print!("  ce qui les refuse :");
    for (why, n) in worst
        .iter()
        .filter(|(why, _)| why != "coupé par la fenêtre")
        .take(10)
    {
        print!(" {why}×{n}");
    }
    println!();

    // **Et ce que ces régions coûteront à l'hôte.**
    //
    // Le module ne va pas jusqu'au bout : il rend la main. La question n'est
    // pas cosmétique, elle décide de l'architecture du bureau local — la RAM
    // invitée **est** la mémoire linéaire du module, dans le processus de
    // contenu de WebKit, et ce qui reprend après un retour de main doit
    // pouvoir la lire. Un interpréteur qui vit dans l'application ne le peut
    // pas.
    //
    // Le `rep` a quitté cette liste : sa boucle est émise, parce que ce qui
    // reprend après un retour de main doit lire la RAM invitée et qu'un hôte
    // hors de la vue ne le peut pas. Il reste compté à part, parce que sa
    // densité dit ce que la boucle a rapatrié.
    let mut total = Survey::default();
    let mut regions = 0usize;
    let mut with_repeat = 0usize;
    for entry in entries.iter().take(20000) {
        let end = limit.min(entry + 4096);
        let Some(survey) = Module::survey(&bytes[*entry..end], 0) else {
            continue;
        };
        regions += 1;
        with_repeat += usize::from(survey.repeats > 0);
        total.blocks += survey.blocks;
        total.instructions += survey.instructions;
        total.always += survey.always;
        total.repeats += survey.repeats;
        total.perhaps += survey.perhaps;
    }
    println!(
        "forme des régions : {regions} régions, {} blocs, {} instructions \
         ({:.1} instructions par bloc)",
        total.blocks,
        total.instructions,
        total.instructions as f64 / total.blocks.max(1) as f64
    );
    println!(
        "  rendent la main à coup sûr (`ud2`) : {} ({:.2} % des instructions, \
         une toutes les {:.0})",
        total.always,
        100.0 * total.always as f64 / total.instructions.max(1) as f64,
        total.instructions as f64 / total.always.max(1) as f64
    );
    println!(
        "  chaînes répétées, désormais dans le module : {} ({:.2} % des instructions)",
        total.repeats,
        100.0 * total.repeats as f64 / total.instructions.max(1) as f64
    );
    println!(
        "  régions contenant au moins un `rep` : {with_repeat} sur {regions} ({:.1} %)",
        100.0 * with_repeat as f64 / regions.max(1) as f64
    );
    println!(
        "  peuvent rendre la main (`ret`, `jmp *`, `call *`) : {} ({:.2} % des instructions)",
        total.perhaps,
        100.0 * total.perhaps as f64 / total.instructions.max(1) as f64
    );
}
