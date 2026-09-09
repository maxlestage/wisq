// Combien du vrai noyau le compilateur accepte-t-il ?
use std::fs;
use wisq_vm::kernel_image::{recognise, KernelImage};
use wisq_vm::x86::{decode, Op};
use wisq_vm::x86_wasm::{Module, Refused, Survey};

/// L'adresse invitée où cette sonde suppose la région chargée. Elle n'est pas
/// décorative : `call` empile une adresse de retour et `ret` la relit.
const BASE: u64 = 0x3000_0000;

/// **Le nombre de pages de 64 Kio du confinement, et pourquoi il y en a un.**
///
/// Cette sonde a mesuré pendant toute une série la forme *libre*
/// (`Module::region`). L'application n'exécute que la forme *confinée et
/// liée* — `resolvingRegion`, donc `Module::resolving` — et depuis la
/// pagination les deux n'acceptent plus la même chose : la marche dans les
/// tables n'existe que sous confinement, donc l'écriture de `cr3` qui la
/// pilote n'y est acceptée que là. Les chiffres publiés décrivaient un
/// émetteur que l'application ne fait pas tourner. C'est la forme confinée qui
/// est mesurée maintenant.
///
/// **La valeur ne change pas ce qui compile.** Dans `build`, le nombre de
/// pages sert à deux choses : refuser ce qui n'est pas une puissance de deux,
/// et graver un masque plus un minimum de mémoire déclaré. Aucune des deux ne
/// décide d'accepter ou de refuser une instruction — c'est le *confinement*
/// qui le fait, pas sa taille. Un giboctet est pris parce que c'est ce que
/// `examples/resolved.rs` prend, et parce que `BASE` tombe dedans.
const PAGES: u32 = 0x4000; // 1 Gio

/// **L'emplacement dans la table partagée, et pourquoi zéro convient ici.**
///
/// Poser deux régions au même emplacement les ferait s'écraser — c'est un
/// défaut qu'un pilote de ce dépôt a déjà commis. Ici il n'y en a pas : cette
/// sonde ne charge rien, elle demande une traduction et jette le module. Rien
/// n'est jamais posé dans une table.
const SLOT: u32 = 0;

/// Le nom court d'une instruction que l'émetteur refuse.
///
/// Un `{:?}` suffirait pour les formes sans champ, mais pas pour celles qui en
/// portent : `LoadDescriptorTable { interrupts: false }` occupe une ligne de
/// relevé à lui seul, et ce relevé en aligne dix. Les familles nommées ici
/// sont exactement celles que les tranches privilégiées ont ajoutées.
fn name_of(op: Op) -> String {
    match op {
        Op::LoadDescriptorTable { interrupts } => {
            if interrupts { "lidt" } else { "lgdt" }.to_string()
        }
        Op::StoreDescriptorTable { interrupts } => {
            if interrupts { "sidt" } else { "sgdt" }.to_string()
        }
        Op::SwapGs => "swapgs".to_string(),
        Op::LoadSegment { .. } => "mov-vers-segment".to_string(),
        Op::StoreSegment { .. } => "mov-depuis-segment".to_string(),
        Op::ReadControlRegister { which } => format!("lire-cr{which}"),
        Op::WriteControlRegister { which } => format!("écrire-cr{which}"),
        Op::InterruptFlag(set) => if set { "sti" } else { "cli" }.to_string(),
        Op::Halt => "hlt".to_string(),
        Op::PushFlags => "pushf".to_string(),
        Op::PopFlags => "popf".to_string(),
        Op::ReadTimestamp => "rdtsc".to_string(),
        Op::CpuId => "cpuid".to_string(),
        Op::ReadModelRegister => "rdmsr".to_string(),
        Op::WriteModelRegister => "wrmsr".to_string(),
        other => format!("{other:?}"),
    }
}

fn main() {
    let path = std::env::args().nth(1).expect("le chemin du noyau");
    let bytes = fs::read(&path).expect("le noyau");

    // **Un nombre faux qui ressemble à un nombre est pire qu'un refus.**
    //
    // Lancé sur le `vmlinuz-lts` d'Alpine tel qu'il se télécharge, cet outil a
    // rendu 106 entrées de fonction et 6,6 % de régions compilées — contre
    // 10 116 et 98,2 % sur la charge utile décompressée du **même** fichier.
    // Rien n'avait régressé : il décodait du gzip comme si c'était du x86. Un
    // `vmlinuz` de distribution est un bzImage, et les octets qui suivent son
    // talon d'amorçage sont des données.
    match recognise(&bytes) {
        KernelImage::Compressed { how, at } => {
            eprintln!(
                "{path} est un bzImage : le noyau y est compressé en {}, à partir de l'octet {at}.",
                how.name()
            );
            eprintln!("Mesurer ces octets décoderait une archive comme du code, et rendrait un chiffre qui n'en est pas un.");
            eprintln!();
            eprintln!("Extraire la charge utile d'abord, par exemple :");
            eprintln!(
                "  python3 -c 'import zlib,sys; d=open(sys.argv[1],\"rb\").read()[{at}:]; \\"
            );
            eprintln!("    open(sys.argv[2],\"wb\").write(zlib.decompressobj(16+zlib.MAX_WBITS).decompress(d))' \\");
            eprintln!("    {path} vmlinux.bin");
            std::process::exit(2);
        }
        KernelImage::CompressedUnknown => {
            eprintln!("{path} est un bzImage dont la compression n'est pas reconnue.");
            eprintln!("Ses octets ne sont pas du code : les mesurer ne dirait rien.");
            std::process::exit(2);
        }
        // Un ELF porte son code tel quel. « Autre chose » est laissé passer :
        // cet outil sert aussi à mesurer des fragments extraits à la main, qui
        // n'ont ni en-tête ELF ni talon d'amorçage.
        KernelImage::Elf | KernelImage::Unknown => {}
    }
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
        let window = &bytes[cursor..limit.min(cursor + 4096)];
        if Module::resolving(window, BASE, 0, SLOT, PAGES).is_some() {
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
    let mut wasted = 0usize;
    let mut blame: std::collections::BTreeMap<String, usize> = Default::default();
    for entry in entries.iter().take(20000) {
        let end = limit.min(entry + 4096);
        if Module::resolving(&bytes[*entry..end], BASE, 0, SLOT, PAGES).is_some() {
            hit += 1;
            continue;
        }
        refused += 1;
        // **La raison vient de l'émetteur, plus d'une déduction d'ici.**
        //
        // Cette sonde séparait « coupé par la fenêtre » de « vraiment inconnu »
        // en rejugeant l'octet fautif avec **tout le reste du fichier** — un
        // détour qu'elle seule pouvait faire, parce qu'elle a le fichier entier
        // sous la main. La vue du bureau ne l'a pas : elle a la fenêtre qu'elle
        // a envoyée, et rien d'autre. `resolving_or_why` répond donc à sa place,
        // et cette sonde s'en sert maintenant aussi — ce qui la fait vérifier
        // la réponse à chaque exécution plutôt que la deviner deux fois.
        let culprit = match Module::resolving_or_why(&bytes[*entry..end], BASE, 0, SLOT, PAGES) {
            Ok(_) => unreachable!("la région vient d'être refusée"),
            Err(Refused::MayBeCut { at }) => {
                // **De combien la prudence dépasse.** `MayBeCut` dit « le
                // décodeur a manqué de place », pas « la suite l'aurait
                // sauvé » — il ne peut pas le savoir, et la vue non plus.
                // Cette sonde, elle, a tout le fichier : elle peut donc
                // compter les fois où le second essai sera perdu. C'est le
                // prix exact de la règle, mesuré à chaque exécution plutôt
                // qu'estimé une fois.
                if decode(&bytes[*entry + at..limit]).is_none() {
                    wasted += 1;
                }
                "coupé par la fenêtre".to_string()
            }
            Err(Refused::NothingAtEntry) => "rien à cette entrée".to_string(),
            Err(Refused::RamIsNotAPowerOfTwo(pages)) => format!("{pages} pages"),
            // **Nommer l'instruction qui refuse, et pas seulement l'émetteur.**
            //
            // « L'émetteur refuse » était vrai et inutile : c'est le premier
            // poste de refus, et il ne disait pas de quoi il est fait. Or
            // c'est exactement ce qui départage les deux voies ouvertes dans
            // `ROADMAP.md` — fauter vers l'hôte pour tout, ou modéliser une
            // poignée de registres. Si ces refus tiennent à trois formes, la
            // seconde vaut le coup ; s'ils sont éparpillés, elle ne vaut rien.
            //
            // Le décodeur relit l'octet que le refus désigne. Il l'a déjà lu
            // une fois — c'est la définition d'un `CannotTranslate` — donc
            // l'absence de nom ici serait un défaut, pas un cas.
            Err(Refused::CannotTranslate { at }) => match decode(&bytes[*entry + at..end]) {
                Some(step) => format!("refus:{}", name_of(step.op)),
                None => "refus:illisible-au-relire".to_string(),
            },
            Err(Refused::CannotDecode { at }) => {
                // Un préfixe ne dit rien tout seul : c'est l'octet d'après qui
                // nomme l'instruction refusée.
                let walk = *entry + at;
                match bytes[walk] {
                    0xf2 | 0xf3 | 0x0f | 0x66 => format!(
                        "{:02x}-{:02x}",
                        bytes[walk],
                        bytes.get(walk + 1).copied().unwrap_or(0)
                    ),
                    other => format!("{other:02x}"),
                }
            }
        };
        *blame.entry(culprit).or_default() += 1;
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
        "  dont {cut} où le décodeur a manqué de place au bord des 4 Kio — la vue redemanderait \
         avec plus d'octets — et {} refusées franchement",
        refused - cut
    );
    // **Ce que la prudence coûte, en clair.** La règle des quinze octets ne
    // peut pas distinguer une coupe d'un refus qui tombe près du bord : elle
    // choisit de redemander. Ces `wasted` régions sont celles où ce second
    // essai sera perdu, et les compter est la seule façon de savoir si le
    // choix reste bon quand le décodeur progresse.
    println!(
        "  dont {wasted} qui se feront refuser au second essai — {:.2} % des entrées, \
         le prix de ne pas abandonner les {} autres",
        100.0 * wasted as f64 / entries.len().max(1) as f64,
        cut - wasted
    );
    // **Les deux postes ne se lisent pas de la même façon**, et les mêler sur
    // une ligne les rendait incomparables. Un trou de décodage se comble en
    // apprenant une forme ; un refus nommé ne se comble qu'en sachant la
    // *produire*. Mesuré : trois tranches de décodage n'ont pas déplacé le
    // total d'une unité, elles ont vidé la première colonne dans la seconde.
    let (nommés, trous): (Vec<_>, Vec<_>) = worst
        .iter()
        .filter(|(why, _)| why != "coupé par la fenêtre")
        .partition(|(why, _)| why.starts_with("refus:"));
    let total_nommés: usize = nommés.iter().map(|(_, n)| *n).sum();
    let total_trous: usize = trous.iter().map(|(_, n)| *n).sum();
    print!("  ce que l'émetteur sait lire et refuse de produire ({total_nommés}) :");
    for (why, n) in &nommés {
        print!(" {}×{n}", why.trim_start_matches("refus:"));
    }
    println!();
    // **Les deux postes doivent recouvrir exactement les refus francs.** Ils
    // sont comptés par deux chemins différents — l'un par soustraction, l'autre
    // par accumulation — et c'est ce qui en fait une garde plutôt qu'une
    // redondance. Un écart voudrait dire qu'une catégorie de refus a été
    // introduite sans être classée, et le relevé mentirait par omission.
    let francs = refused - cut;
    if total_nommés + total_trous != francs {
        println!(
            "  /!\\ le relevé ne boucle pas : {total_nommés} + {total_trous} au lieu de {francs}"
        );
    }
    print!("  ce que le décodeur ne lit pas ({total_trous}) :");
    for (why, n) in trous.iter().take(12) {
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
    //
    // **`survey` ne prend pas de mise en forme, et ce n'est pas un oubli.** Il
    // ne traduit rien : il parcourt le graphe des blocs et compte les formes de
    // retour de main. Ce parcours est le même sous confinement et sans — c'est
    // `discover`, et `discover` n'a jamais vu de masque. Lui passer un nombre
    // de pages ferait croire que le chiffre en dépend.
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
