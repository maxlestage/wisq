//! **Le compilateur que j'écris, jugé par le moteur qui l'exécutera.**
//!
//! iOS interdit d'écrire une page exécutable ; il n'interdit pas de produire
//! une **donnée** que WebKit compile. C'est le contournement, et il ne déplace
//! pas le travail : le décodage, la traduction et la génération de code sont
//! ici. WebKit n'a que la dernière étape, l'assemblage machine.
//!
//! **Pourquoi ce test peut exister sur Linux.** Bun embarque JavaScriptCore,
//! le moteur exact de `WKWebView`. Un module émis ici et exécuté sous Bun
//! passe par le même compilateur WebAssembly que sur un iPhone. Le juge, lui,
//! reste extérieur : les cas de `x86-oracle.tsv` viennent d'un vrai
//! processeur.
//!
//! Sans Bun, le test **saute bruyamment** plutôt que de passer en silence : un
//! émetteur que rien n'exécute n'est pas un émetteur vérifié.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use wisq_vm::x86::{Cpu, Step, Width};
use wisq_vm::x86_wasm::{Module, GLOBAL_COUNT, GS_SLOT, GUEST_PAGES, RFLAGS_SLOT, RIP_SLOT};

fn workspace_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("racine de l'espace de travail")
        .to_path_buf()
}

fn bun() -> Option<PathBuf> {
    for candidate in ["/root/.bun/bin/bun", "/usr/local/bin/bun", "bun"] {
        if Command::new(candidate).arg("--version").output().is_ok() {
            return Some(PathBuf::from(candidate));
        }
    }
    None
}

/// **Le pilote, et pourquoi il prend tout d'un coup.**
///
/// La première version lançait un processus Bun par cas : 2664 démarrages de
/// moteur pour une mesure, dix minutes par tour. La boucle de retour était le
/// goulot, pas le code — et un test qu'on n'ose pas relancer cesse d'être un
/// test. Celui-ci reçoit tous les modules et tous les états en une fois,
/// instancie **une fois par instruction** plutôt qu'une fois par cas, et rend
/// tout.
const DRIVER: &str = r#"
const fs = require("fs");
const job = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const out = {};
// **Deux fenêtres, pas une.** Les données d'un côté, la pile de l'autre : un
// `push` qui écrit à la mauvaise adresse laisse la fenêtre de données intacte.
const windows = job.windows.map(w => ({
  at: w.at,
  bytes: Uint8Array.from(w.pristine.match(/../g).map(pair => parseInt(pair, 16))),
}));
// **L'hôte possède la machine.** Une seule RAM, un seul fichier de registres,
// et autant de modules qu'il en faut : c'est ce que les imports permettent, et
// c'est ce que fera l'application. Avant, chaque module portait sa propre RAM
// de 768 Mio — deux régions ne partageaient rien, et passer de l'une à l'autre
// aurait demandé de tout recopier.
const memory = new WebAssembly.Memory({ initial: job.pages });
const slots = [];
for (let slot = 0; slot < job.globals; slot++) {
  slots.push(new WebAssembly.Global({ value: "i64", mutable: true }, 0n));
}
const imports = { env: { mem: memory } };
slots.forEach((global, slot) => { imports.env["g" + slot] = global; });
const guest = new Uint8Array(memory.buffer);
// L'étendue telle qu'elle est au départ de chaque cas. Elle sert de référence :
// la rendre pour les onze mille cas qui n'y touchent pas ferait deux cents
// mégaoctets de JSON, et le harnais passait plus de temps à les relire qu'à
// vérifier quoi que ce soit.
const reference = new Uint8Array(job.span.length);
for (const window of windows) { reference.set(window.bytes, window.at - job.span.at); }
const same = (a, b) => {
  if (a.length !== b.length) { return false; }
  for (let i = 0; i < a.length; i++) { if (a[i] !== b[i]) { return false; } }
  return true;
};
for (const unit of job.jobs) {
  const bytes = fs.readFileSync(unit.module);
  const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
  const base = 0x30000000, end = base + unit.length;
  for (const test of unit.cases) {
    // Remettre à zéro : un résidu du cas précédent ferait lire à une
    // instruction un registre que l'oracle n'a pas posé.
    for (const global of slots) { global.value = 0n; }
    // **La base du segment GS, reposée à chaque cas.** Elle appartient à
    // l'hôte, pas au module : c'est lui qui la pose, comme le noyau la poserait
    // par `wrmsr`, et la remise à zéro ci-dessus vient de l'effacer. Sans cette
    // ligne, chaque accès `%gs:` lirait la page zéro là où le silicium lisait
    // la fenêtre de données.
    slots[job.gsSlot].value = BigInt("0x" + job.gsBase);
    // Et remettre les fenêtres dans leur motif d'origine, pour la même raison :
    // le silicium les reçoit propres à chaque cas. L'intervalle entre les deux
    // est remis à zéro plutôt que laissé : ce qu'un cas y aurait écrit
    // deviendrait, au cas suivant, un écart qu'on attribuerait à l'instruction.
    guest.fill(0, job.span.at, job.span.at + job.span.length);
    for (const window of windows) { guest.set(window.bytes, window.at); }
    for (const [slot, value] of Object.entries(test.regs)) {
      slots[Number(slot)].value = BigInt("0x" + value);
    }
    try {
      // Le budget : un cœur qui partirait en rond doit être arrêté plutôt
      // qu'attendu. Les programmes du corpus sont courts ; le plus long boucle
      // dix fois.
      instance.exports.run(10000n);
    } catch (error) {
      // **Dire lequel.** Sans le nom du cas, « Out of bounds memory access »
      // ne désigne rien : il y a des centaines de modules dans un tour.
      throw new Error(test.id + " (" + unit.module + ") : " + error.message);
    }
    // **Une globale i64 se lit en BigInt signé.** `BigUint64Array` masquait
    // ce détail : ici, un registre à tous les bits à un rend -1n, qui s'écrit
    // « -1 » en hexadécimal et n'est plus un nombre pour personne.
    const seen = guest.subarray(job.span.at, job.span.at + job.span.length);
    // **Le module a-t-il fini, ou rendu la main ?** Rendre la main est une
    // conduite juste — il le fait quand il ne sait pas — mais l'état n'est
    // alors pas celui d'après le programme : il manque ce que l'hôte aurait
    // exécuté ensuite. Comparer ça au silicium reprocherait à l'émetteur ce
    // qu'il n'a pas prétendu faire.
    const rip = BigInt.asUintN(64, slots[job.ripSlot].value);
    out[test.id] = {
      unfinished: rip >= BigInt(base) && rip < BigInt(end),
      // Quatre valeurs, puis les trois pointeurs : RSP, RBP, RSI.
      regs: [0, 1, 2, job.flagsSlot, 4, 5, 6]
        .map(s => BigInt.asUintN(64, slots[s].value).toString(16)),
      // « - » veut dire « la mémoire est telle qu'elle était », comme dans le
      // corpus. Rendre le motif entier dirait la même chose en cent fois plus.
      memory: same(seen, reference) ? "-"
        : [...seen].map(b => b.toString(16).padStart(2, "0")).join(""),
    };
  }
}
fs.writeFileSync(process.argv[3], JSON.stringify(out));
"#;

/// Un cas de l'oracle. Nommé plutôt que laissé en tuple : six champs anonymes
/// manipulés par référence forment un type que personne ne relit — clippy le
/// refuse, et il a raison.
struct Case {
    instruction: String,
    state: String,
    rax: u64,
    rcx: u64,
    rdx: u64,
    flags: u64,
    /// La fenêtre de données après l'instruction, ou rien quand elle n'a pas
    /// bougé — le corpus écrit « - » dans ce cas.
    memory: Option<Vec<u8>>,
    /// La fenêtre de pile, à la même enseigne.
    stack: Option<Vec<u8>>,
    /// **RSP, RBP et RSI** — les trois seuls registres que le corpus autorise
    /// à bouger, et donc les trois seuls qu'il relève. Sans eux, un `leave`
    /// qui dépile avant de reprendre RBP passe : RAX, RCX, RDX, les drapeaux
    /// et les deux fenêtres restent exactement justes.
    pointers: (u64, u64, u64),
}

struct Oracle {
    states: HashMap<String, (u64, u64, u64, u64)>,
    instructions: HashMap<String, (Vec<u8>, u64, String)>,
    cases: Vec<Case>,
    /// **Ce que le silicium avait dans les registres que « état » ne porte
    /// pas.** Les laisser à zéro rendait ce harnais faux en silence : il
    /// tombait juste tant qu'aucune instruction traduite n'en lisait un, et
    /// `movzbl %bh, %eax` lit RBX.
    fixed: [u64; 16],
    /// **Les fenêtres de mémoire**, et le motif dont chacune part à chaque cas.
    windows: Vec<(u64, Vec<u8>)>,
    /// **La base du segment GS**, posée par le pilote et invisible dans les
    /// registres. Même leçon que `fixed` et `windows`, pour la troisième fois :
    /// devinée, elle ferait comparer ce résultat à celui d'un processeur parti
    /// d'ailleurs.
    gs_base: u64,
}

/// L'étendue contiguë qui couvre les fenêtres : l'adresse de départ et les
/// octets, l'intervalle entre deux fenêtres mis à zéro. C'est sous cette forme
/// que le pilote rend la mémoire, donc c'est sous cette forme qu'on la compare.
fn span(windows: &[(u64, Vec<u8>)]) -> (u64, Vec<u8>) {
    let base = windows.iter().map(|(at, _)| *at).min().unwrap_or(0);
    let end = windows
        .iter()
        .map(|(at, pattern)| *at + pattern.len() as u64)
        .max()
        .unwrap_or(0);
    let mut bytes = vec![0u8; (end - base) as usize];
    for (at, pattern) in windows {
        let start = (*at - base) as usize;
        bytes[start..start + pattern.len()].copy_from_slice(pattern);
    }
    (base, bytes)
}

/// **L'adresse à laquelle le code de l'invité est chargé**, la même que celle
/// de `oracle.c`. Un `call` empile une adresse de retour, et cette adresse
/// dépend de l'endroit où le programme est posé : compiler la région comme si
/// elle vivait à zéro laisserait les registres justes et la pile fausse.
const CODE: u64 = 0x3000_0000;

/// Une suite d'octets en hexadécimal.
fn bytes(text: &str) -> Vec<u8> {
    (0..text.len() / 2)
        .map(|i| u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).expect("un octet"))
        .collect()
}

fn hex(text: &str) -> u64 {
    u64::from_str_radix(text, 16).expect("un nombre hexadécimal")
}

fn read_oracle() -> Oracle {
    let text = std::fs::read_to_string(workspace_root().join("Tests/Fixtures/x86-oracle.tsv"))
        .expect("l'oracle matériel doit être lisible");
    let mut oracle = Oracle {
        states: HashMap::new(),
        instructions: HashMap::new(),
        cases: Vec::new(),
        fixed: [0; 16],
        windows: Vec::new(),
        gs_base: 0,
    };
    let mut segment = false;
    let mut seeded = 0usize;
    for line in text.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            "état" => {
                oracle
                    .states
                    .insert(f[1].into(), (hex(f[2]), hex(f[3]), hex(f[4]), hex(f[5])));
            }
            "fenêtre" => oracle.windows.push((hex(f[1]), bytes(f[2]))),
            "segment" if f[1] == "gs" => {
                oracle.gs_base = hex(f[2]);
                segment = true;
            }
            "fixe" => {
                let register: usize = f[1].parse().expect("un numéro de registre");
                oracle.fixed[register] = hex(f[2]);
                seeded += 1;
            }
            "instr" => {
                let bytes = (0..f[2].len() / 2)
                    .map(|i| u8::from_str_radix(&f[2][i * 2..i * 2 + 2], 16).expect("octet"))
                    .collect();
                oracle
                    .instructions
                    .insert(f[1].into(), (bytes, hex(f[3]), f[4].into()));
            }
            "cas" => oracle.cases.push(Case {
                instruction: f[1].into(),
                state: f[2].into(),
                rax: hex(f[3]),
                rcx: hex(f[4]),
                rdx: hex(f[5]),
                flags: hex(f[6]),
                memory: match f.get(7) {
                    Some(&"-") | None => None,
                    Some(text) => Some(bytes(text)),
                },
                stack: match f.get(8) {
                    Some(&"-") | None => None,
                    Some(text) => Some(bytes(text)),
                },
                pointers: (hex(f[9]), hex(f[10]), hex(f[11])),
            }),
            _ => {}
        }
    }
    assert_eq!(
        oracle.windows.len(),
        2,
        "l'oracle doit déclarer la fenêtre de données et celle de pile"
    );
    assert_eq!(
        seeded, 13,
        "l'oracle doit déclarer les treize registres fixes, il en déclare {seeded}"
    );
    // Un enregistrement inconnu est ignoré en silence, exprès ; celui-ci ne
    // doit pas l'être, sans quoi le harnais lirait la page zéro sans se
    // plaindre dès qu'un cas porte le préfixe.
    assert!(segment, "l'oracle doit déclarer la base du segment GS");
    oracle
}

/// **Chaque instruction que l'émetteur accepte doit, une fois compilée par
/// JavaScriptCore, rendre exactement ce que le silicium a rendu.**
/// Décoder une séquence entière, ou rien. Un décodage partiel n'est pas une

#[test]
fn what_the_emitter_produces_matches_the_silicon_under_javascriptcore() {
    let Some(bun) = bun() else {
        panic!(
            "Bun est absent : l'émetteur ne serait vérifié par rien. \
             Ce test refuse de passer en silence."
        );
    };
    let oracle = read_oracle();
    // **Un chemin par processus.** Un chemin fixe se fait écraser dès que deux
    // exécutions se croisent — la CI parallélise, et j'ai moi-même lancé deux
    // tours concurrents : le module se lisait à moitié écrit et JavaScriptCore
    // refusait « un module d'au moins huit octets ». Le défaut était dans le
    // harnais, pas dans l'émetteur.
    let scratch = std::env::temp_dir().join(format!("wisq-x86-wasm-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let driver = scratch.join("driver.js");
    std::fs::write(&driver, DRIVER).expect("le pilote");

    let flags_slot = RFLAGS_SLOT;
    // Regrouper les cas par instruction : un module par instruction, instancié
    // une seule fois pour tous ses états.
    let mut by_instruction: Vec<(String, Vec<&Case>)> = Vec::new();
    let mut seen: HashMap<String, usize> = HashMap::new();
    for case in &oracle.cases {
        match seen.get(&case.instruction) {
            Some(&at) => by_instruction[at].1.push(case),
            None => {
                seen.insert(case.instruction.clone(), by_instruction.len());
                by_instruction.push((case.instruction.clone(), vec![case]));
            }
        }
    }

    let mut jobs = String::from("{\"pages\":");
    jobs.push_str(&GUEST_PAGES.to_string());
    jobs.push_str(",\"globals\":");
    jobs.push_str(&GLOBAL_COUNT.to_string());
    jobs.push_str(",\"ripSlot\":");
    jobs.push_str(&RIP_SLOT.to_string());
    jobs.push_str(",\"flagsSlot\":");
    jobs.push_str(&flags_slot.to_string());
    // **La base du segment, lue dans le corpus.** Le pilote la pose par
    // `arch_prctl` avant le premier cas ; le module la reçoit par une globale
    // importée, exactement comme il reçoit les registres.
    jobs.push_str(",\"gsSlot\":");
    jobs.push_str(&GS_SLOT.to_string());
    jobs.push_str(&format!(",\"gsBase\":\"{:x}\"", oracle.gs_base));
    // La fenêtre de données et son motif viennent du fichier, jamais du code :
    // un harnais qui les devine compare son résultat à celui d'un processeur
    // parti d'ailleurs.
    let (span_at, span_bytes) = span(&oracle.windows);
    jobs.push_str(&format!(
        ",\"span\":{{\"at\":{span_at},\"length\":{}}},\"windows\":[",
        span_bytes.len()
    ));
    for (index, (at, pattern)) in oracle.windows.iter().enumerate() {
        if index > 0 {
            jobs.push(',');
        }
        jobs.push_str(&format!("{{\"at\":{at},\"pristine\":\""));
        for byte in pattern {
            jobs.push_str(&format!("{byte:02x}"));
        }
        jobs.push_str("\"}");
    }
    jobs.push_str("],\"jobs\":[");
    let mut emitted = 0usize;
    let mut refused = 0usize;
    #[allow(clippy::type_complexity)]
    type Wanted = (u64, u64, u64, u64, u64, String, Vec<u8>, (u64, u64, u64));
    let mut expected: HashMap<String, Wanted> = HashMap::new();

    for (index, (instruction, cases)) in by_instruction.iter().enumerate() {
        let (bytes, defined, mnemonic) = &oracle.instructions[instruction];
        // **Décoder la séquence entière, ou refuser l'entrée.** Certaines
        // entrées de l'oracle portent plusieurs instructions, et quelques-unes
        // une boucle complète. N'en traduire que la première rend un état que
        // rien ne distingue d'un état juste — c'est ce qui a produit les faux
        // écarts portant « une boucle qui additionne » ou « un saut
        // conditionnel long » dans leur nom.
        // **Une région, pas une suite d'instructions.** Le compilateur découvre
        // lui-même les blocs atteignables : linéariser les octets reviendrait à
        // ignorer les sauts tout en prétendant les traduire.
        let Some(module) = Module::region(bytes, CODE, 0) else {
            refused += cases.len();
            continue;
        };
        let path = scratch.join(format!("m{index}.wasm"));
        std::fs::write(&path, &module).expect("le module");

        if emitted > 0 {
            jobs.push(',');
        }
        emitted += 1;
        jobs.push_str(&format!(
            "{{\"module\":{:?},\"length\":{},\"cases\":[",
            path.to_string_lossy(),
            bytes.len()
        ));
        for (position, case) in cases.iter().enumerate() {
            let (rax, rcx, rdx, flags) = oracle.states[&case.state];
            let id = format!("{}|{}", case.instruction, case.state);
            if position > 0 {
                jobs.push(',');
            }
            // Les treize registres fixes sont posés **avant** les trois de
            // l'état, pour qu'un chevauchement futur soit décidé par l'état
            // et pas par l'ordre d'écriture d'un objet JSON.
            let mut regs = String::new();
            for (slot, value) in oracle.fixed.iter().enumerate() {
                if *value != 0 {
                    regs.push_str(&format!("\"{slot}\":\"{value:x}\","));
                }
            }
            jobs.push_str(&format!(
                "{{\"id\":{id:?},\"regs\":{{{regs}\"0\":\"{rax:x}\",\"1\":\"{rcx:x}\",\
                 \"2\":\"{rdx:x}\",\"{flags_slot}\":\"{flags:x}\"}}}}"
            ));
            expected.insert(
                id,
                (
                    case.rax,
                    case.rcx,
                    case.rdx,
                    case.flags,
                    *defined,
                    mnemonic.clone(),
                    span(&[
                        (
                            oracle.windows[0].0,
                            case.memory
                                .clone()
                                .unwrap_or_else(|| oracle.windows[0].1.clone()),
                        ),
                        (
                            oracle.windows[1].0,
                            case.stack
                                .clone()
                                .unwrap_or_else(|| oracle.windows[1].1.clone()),
                        ),
                    ])
                    .1,
                    case.pointers,
                ),
            );
        }
        jobs.push_str("]}");
    }
    jobs.push_str("]}");

    let job_path = scratch.join("job.json");
    let result_path = scratch.join("result.json");
    std::fs::write(&job_path, &jobs).expect("la liste de travail");

    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .arg(&job_path)
        .arg(&result_path)
        .output()
        .expect("bun doit démarrer");
    assert!(
        output.status.success(),
        "JavaScriptCore a refusé un module émis :\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = std::fs::read_to_string(&result_path).expect("le résultat");

    let mut checked = 0usize;
    let mut handed_back = 0usize;
    let mut wrong: Vec<String> = Vec::new();
    let produced = results(&text);
    let (_, pristine_span) = span(&oracle.windows);
    for (
        id,
        (want_rax, want_rcx, want_rdx, want_flags, mask, mnemonic, want_memory, want_pointers),
    ) in &expected
    {
        let Some(raw) = produced.get(id) else {
            wrong.push(format!("{mnemonic} : aucun résultat rendu pour {id}"));
            continue;
        };
        // **Rendre la main n'est pas se tromper.** Le module le fait quand il
        // ne sait pas — une division qu'il refuse, un saut indirect vers un
        // bloc qu'il n'a pas découvert — et l'état n'est alors pas celui
        // d'après le programme : il manque ce que l'hôte aurait exécuté
        // ensuite. Le comparer au silicium reprocherait à l'émetteur ce qu'il
        // n'a jamais prétendu faire.
        //
        // C'est la seule entorse au « les deux cœurs tombent sur le même
        // nombre », et elle disparaîtra avec l'hôte : quand la mémoire et les
        // registres seront **importés** au lieu d'être définis par le module,
        // le harnais pourra recompiler depuis la nouvelle adresse et
        // poursuivre, comme le fera l'application.
        if raw.6 {
            handed_back += 1;
            continue;
        }
        let got = (
            raw.0,
            raw.1,
            raw.2,
            raw.3,
            raw.5.clone().unwrap_or_else(|| pristine_span.clone()),
        );
        let pointers = raw.4;
        checked += 1;
        // **La fenêtre compte autant que les registres.** Une écriture au
        // mauvais endroit laisse les trois registres justes.
        if got.0 != *want_rax
            || got.1 != *want_rcx
            || got.2 != *want_rdx
            || (got.3 & mask) != (want_flags & mask)
            || &got.4 != want_memory
            || pointers != *want_pointers
        {
            if wrong.len() < 10 {
                wrong.push(format!(
                    "{mnemonic} [{id}] : rax {:x}≠{want_rax:x} rcx {:x}≠{want_rcx:x} \
                     rdx {:x}≠{want_rdx:x} rsp {:x}≠{:x} rbp {:x}≠{:x} rsi {:x}≠{:x} \
                     drapeaux {:x}≠{:x} (masque {mask:x}){}",
                    got.0,
                    got.1,
                    got.2,
                    pointers.0,
                    want_pointers.0,
                    pointers.1,
                    want_pointers.1,
                    pointers.2,
                    want_pointers.2,
                    got.3 & mask,
                    want_flags & mask,
                    if &got.4 != want_memory {
                        format!(
                            "\n  mémoire {}\n       ≠ {}",
                            got.4.iter().map(|b| format!("{b:02x}")).collect::<String>(),
                            want_memory
                                .iter()
                                .map(|b| format!("{b:02x}"))
                                .collect::<String>()
                        )
                    } else {
                        String::new()
                    }
                ));
            } else {
                wrong.push(String::new());
            }
        }
    }

    println!(
        "x86 → WebAssembly : {checked} cas passés sous JavaScriptCore ({emitted} modules), \
         {refused} refusés par l'émetteur, {handed_back} rendus à l'hôte"
    );
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        wrong.is_empty(),
        "{} cas sur {checked} ne rendent pas ce que le processeur rend :\n{}",
        wrong.len(),
        wrong
            .iter()
            .filter(|l| !l.is_empty())
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
    // **Le plancher monte avec chaque famille traduite.** Il ne dit pas
    // « c'est assez » : il dit « ne recule pas ». Après les décalages, les
    // transferts, les rotations simples et `lea`, la mémoire a ajouté
    // cinquante-trois instructions et quatre programmes entiers ; la pile en
    // a ajouté trois, et le même nombre doit tomber des deux côtés — ce
    // harnais et celui du silicium comptent 9168 cas, pas l'un 9168 et
    // l'autre 9144.
    // Le plancher porte sur **les deux ensemble** : un cas rendu à l'hôte
    // reste un cas que l'émetteur a compilé et fait tourner. La somme est
    // exactement le compte de l'interpréteur, et c'est ce qui garde le signal
    // qui a déjà servi une fois — un écart entre les deux cœurs.
    assert!(
        checked + handed_back > 12420,
        "l'émetteur ne couvre plus que {checked} cas : la couverture a reculé"
    );
}

/// **Tout lire d'un coup, et non chercher chaque cas dans le tout.**
///
/// La version d'avant faisait un `find` sur le résultat entier par cas. Tant
/// que la mémoire tenait en soixante-quatre octets ça ne se voyait pas ; avec
/// deux fenêtres et l'intervalle entre elles, le résultat a grossi et la
/// recherche est devenue quadratique — le test tournait plus de dix minutes
/// sans rien vérifier de plus.
#[allow(clippy::type_complexity)]
type Produced = (u64, u64, u64, u64, (u64, u64, u64), Option<Vec<u8>>, bool);

fn results(text: &str) -> HashMap<String, Produced> {
    let mut out = HashMap::new();
    let mut rest = text;
    while let Some(at) = rest.find("\":{\"unfinished\":") {
        // La clé est la chaîne JSON qui précède, entre guillemets.
        let head = &rest[..at];
        let Some(open) = head.rfind('"') else { break };
        let id = head[open + 1..].to_string();
        let body = &rest[at + "\":{\"unfinished\":".len()..];
        let unfinished = body.starts_with("true");
        let Some(regs) = body.find("\"regs\":[") else {
            break;
        };
        let body = &body[regs + "\"regs\":[".len()..];
        let Some(end) = body.find(']') else { break };
        let values: Vec<u64> = body[..end]
            .split(',')
            .map(|piece| hex(piece.trim().trim_matches('"')))
            .collect();
        let memory_key = "\"memory\":\"";
        let Some(start) = body[end..]
            .find(memory_key)
            .map(|i| i + end + memory_key.len())
        else {
            break;
        };
        let Some(stop) = body[start..].find('"').map(|i| i + start) else {
            break;
        };
        let memory = match &body[start..stop] {
            "-" => None,
            hexadecimal => Some(bytes(hexadecimal)),
        };
        if values.len() == 7 {
            out.insert(
                id,
                (
                    values[0],
                    values[1],
                    values[2],
                    values[3],
                    (values[4], values[5], values[6]),
                    memory,
                    unfinished,
                ),
            );
        }
        rest = &body[stop..];
    }
    out
}

/// Un garde-fou sur la largeur : elle vient du décodeur et sert d'index.
#[test]
fn widths_are_the_ones_the_decoder_speaks() {
    assert_eq!(Width::Qword.mask(), u64::MAX);
    assert_eq!(Width::Byte.mask(), 0xff);
}

/// **Ce que le module fait d'une adresse qu'il ne connaît pas.**
///
/// Un `ret` vers l'extérieur de la région est le cas courant : l'appelé rend la
/// main à un appelant compilé ailleurs, ou pas encore compilé. Le module doit
/// alors **s'arrêter** en disant où l'exécution en est, pour que l'hôte
/// compile la région qui commence là.
///
/// Le corpus matériel ne peut pas l'éprouver : ses programmes sont fermés sur
/// eux-mêmes, chaque `ret` retombe sur un bloc connu. Un sabotage l'a montré —
/// faire rendre le bloc zéro au lieu de -1 ne faisait tomber aucun des 9168
/// cas. Ce test-ci sort du corpus exprès.
#[test]
fn a_return_out_of_the_region_hands_control_back() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    // `incq %rdx` puis `pushq %rax` puis `ret` : RAX porte une adresse qui
    // n'est aucun bloc, donc le `ret` doit rendre la main au premier tour.
    let bytes = [0x48, 0xff, 0xc2, 0x50, 0xc3];
    let module = Module::region(&bytes, CODE, 0).expect("la région doit se compiler");

    let scratch = std::env::temp_dir().join(format!("wisq-x86-ret-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let path = scratch.join("m.wasm");
    std::fs::write(&path, &module).expect("le module");
    let driver = scratch.join("d.js");
    // Le budget est large exprès : si le module bouclait, RDX les compterait
    // tous. C'est ce qui distingue « rendu la main » de « reparti au début ».
    std::fs::write(
        &driver,
        format!(
            r#"
const fs = require("fs");
const bytes = fs.readFileSync({:?});
const memory = new WebAssembly.Memory({{ initial: {} }});
const slots = [];
for (let slot = 0; slot < {}; slot++) {{
  slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
}}
const imports = {{ env: {{ mem: memory }} }};
slots.forEach((global, slot) => {{ imports.env["g" + slot] = global; }});
const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
slots[0].value = 0x40001000n;   // rax : hors de la région
slots[2].value = 0n;            // rdx : le compteur de tours
slots[4].value = 0x30003000n;   // rsp
instance.exports.run(64n);
console.log(JSON.stringify({{
  rdx: slots[2].value.toString(),
  rip: BigInt.asUintN(64, slots[{}].value).toString(16),
  rsp: BigInt.asUintN(64, slots[4].value).toString(16),
}}));
"#,
            path.to_string_lossy(),
            GUEST_PAGES,
            GLOBAL_COUNT,
            RIP_SLOT
        ),
    )
    .expect("le pilote");

    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        output.status.success(),
        "JavaScriptCore a refusé le module :\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        text.contains("\"rdx\":\"1\""),
        "le module devait faire un seul tour puis rendre la main, il a rendu {text}"
    );
    assert!(
        text.contains("\"rip\":\"40001000\""),
        "le module devait dire où reprendre — l'adresse sortie de la pile — il a rendu {text}"
    );
    assert!(
        text.contains("\"rsp\":\"30003000\""),
        "le `ret` devait remonter RSP là où il était, il a rendu {text}"
    );
}

/// **Ce que le module fait d'une division qu'il refuse.**
///
/// Trois raisons de refuser, et le corpus n'en exerce aucune : `division_state`
/// écarte d'avance tout état où le processeur lèverait, et ses dividendes
/// tiennent tous dans la largeur simple. Un sabotage l'a montré — supprimer la
/// garde du diviseur nul ne faisait tomber aucun des 10 524 cas, et le module
/// se faisait tuer par une **trappe** WebAssembly au lieu de rendre la main.
///
/// Le refus n'est pas un échec : c'est le filet. Le module pose RIP sur la
/// division elle-même et rend -1 ; l'hôte reprend là avec l'interpréteur, qui
/// sait lever une faute et sait diviser sur cent vingt-huit bits.
#[test]
fn a_division_the_module_refuses_hands_the_instruction_back() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    // `incq %rdx` puis `divq %rcx`. Le `incq` d'abord, exprès : rendre la main
    // n'annule pas ce qui a déjà eu lieu dans le bloc, et RDX doit le montrer.
    let wide = [0x48, 0xff, 0xc2, 0x48, 0xf7, 0xf1];
    // `divw %cx` seule. Le débordement de quotient ne se voit qu'en largeur
    // étroite : en soixante-quatre bits, la moitié haute non banale est
    // refusée avant qu'on arrive à diviser.
    let narrow = [0x66, 0xf7, 0xf1];
    // `divl %ecx` : trente-deux bits de large, donc le dividende double tient
    // dans soixante-quatre et le module n'a **pas** à refuser. C'est la forme
    // qu'un noyau emploie le plus, et le corpus ne la produit jamais avec une
    // moitié haute qui porte de l'information.
    let real = [0xf7, 0xf1];
    // `idivl %ecx` : le même, **signé**. Un sabotage a montré que l'étendue du
    // dividende double n'était tenue par rien du côté signé — les deux calculs
    // tombent d'accord sur tous les états du corpus, et divergent dès que la
    // moitié haute porte de l'information.
    let real_signed = [0xf7, 0xf9];

    let scratch = std::env::temp_dir().join(format!("wisq-x86-div-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut paths = Vec::new();
    for (name, bytes) in [
        ("wide", &wide[..]),
        ("narrow", &narrow[..]),
        ("real", &real[..]),
        ("realSigned", &real_signed[..]),
    ] {
        let module = Module::region(bytes, CODE, 0).expect("la région doit se compiler");
        let path = scratch.join(format!("{name}.wasm"));
        std::fs::write(&path, &module).expect("le module");
        paths.push(path.to_string_lossy().to_string());
    }
    let driver = scratch.join("d.js");
    std::fs::write(
        &driver,
        format!(
            r#"
const fs = require("fs");
const modules = {{
  wide: fs.readFileSync({:?}),
  narrow: fs.readFileSync({:?}),
  real: fs.readFileSync({:?}),
  realSigned: fs.readFileSync({:?}),
}};
// -1 dans RDX puis `incq` le remet à zéro : c'est comme ça qu'on obtient une
// moitié haute banale **après** l'instruction qui précède la division.
const ZERO_AFTER_INC = (1n << 64n) - 1n;
const cases = [
  {{name: "diviseur nul", of: "wide", rax: 100n, rdx: ZERO_AFTER_INC, rcx: 0n, rip: "30000003"}},
  {{name: "dividende de 128 bits", of: "wide", rax: 1n, rdx: 7n, rcx: 3n, rip: "30000003"}},
  {{name: "quotient qui deborde", of: "narrow", rax: 0n, rdx: 1n, rcx: 1n, rip: "30000000"}},
  // Et celui qui **doit** passer, pour que le refus ne soit pas un refus de
  // tout : 100 / 7 fait 14, reste 2.
  {{name: "une division ordinaire", of: "wide", rax: 100n, rdx: ZERO_AFTER_INC, rcx: 7n,
    rax_after: "e", rdx_after: "2"}},
  // 2^32 divisé par trois, en trente-deux bits : la moitié basse seule dirait
  // « zéro ». Le module doit calculer, pas refuser.
  {{name: "un dividende sur deux registres", of: "real", rax: 0n, rdx: 1n, rcx: 3n,
    rax_after: "55555555", rdx_after: "1"}},
  // -2^32 divisé par trois : le quotient tronque **vers zéro**, donc
  // -1 431 655 765, reste -1. Une écriture de 32 bits étend par zéro.
  {{name: "un dividende signé sur deux registres", of: "realSigned",
    rax: 0n, rdx: 0xffffffffn, rcx: 3n, rax_after: "aaaaaaab", rdx_after: "ffffffff"}},
];
const out = [];
for (const test of cases) {{
  // Une machine neuve par cas : l'hôte la possède, le module l'emprunte.
  const memory = new WebAssembly.Memory({{ initial: {} }});
  const slots = [];
  for (let slot = 0; slot < {}; slot++) {{
    slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
  }}
  const imports = {{ env: {{ mem: memory }} }};
  slots.forEach((global, slot) => {{ imports.env["g" + slot] = global; }});
  const instance = new WebAssembly.Instance(
    new WebAssembly.Module(modules[test.of]), imports);
  slots[0].value = test.rax;
  slots[1].value = test.rcx;
  slots[2].value = test.rdx;
  slots[4].value = 0x30003000n;
  let threw = "";
  try {{ instance.exports.run(64n); }} catch (error) {{ threw = error.message; }}
  out.push({{
    name: test.name,
    threw,
    rax: BigInt.asUintN(64, slots[0].value).toString(16),
    rdx: BigInt.asUintN(64, slots[2].value).toString(16),
    rip: BigInt.asUintN(64, slots[{}].value).toString(16),
    want: test.rip || "",
    wantRax: test.rax_after || "",
    wantRdx: test.rdx_after || "",
  }});
}}
console.log(JSON.stringify(out, null, 1));
"#,
            paths[0], paths[1], paths[2], paths[3], GUEST_PAGES, GLOBAL_COUNT, RIP_SLOT
        ),
    )
    .expect("le pilote");

    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        output.status.success(),
        "JavaScriptCore a refusé le module :\n{}",
        String::from_utf8_lossy(&output.stderr)
    );

    let produced: Vec<HashMap<String, String>> =
        serde_free_objects(&text).expect("le pilote doit rendre du JSON lisible");
    assert_eq!(produced.len(), 6, "six cas attendus : {text}");
    for case in &produced {
        let name = &case["name"];
        // **Aucune trappe, dans aucun cas.** Une trappe tue le module entier,
        // et l'hôte n'a plus de machine à reprendre.
        assert_eq!(case["threw"], "", "{name} a piégé le module : {text}");
        if !case["want"].is_empty() {
            assert_eq!(
                case["rip"], case["want"],
                "{name} : le module devait poser RIP sur la division elle-même"
            );
        }
        if !case["wantRax"].is_empty() {
            assert_eq!(case["rax"], case["wantRax"], "{name} : le quotient");
            assert_eq!(case["rdx"], case["wantRdx"], "{name} : le reste");
        }
    }
}

/// Lire la liste d'objets plats que le pilote rend. Le dépôt n'a pas de
/// dépendance JSON, et en ajouter une pour quatre objets à cinq champs coûterait
/// plus cher que de les lire.
fn serde_free_objects(text: &str) -> Option<Vec<HashMap<String, String>>> {
    let mut objects = Vec::new();
    let mut rest = text;
    while let Some(open) = rest.find('{') {
        let close = rest[open..].find('}')? + open;
        let mut fields = HashMap::new();
        for pair in rest[open + 1..close].split(',') {
            let (key, value) = pair.split_once(':')?;
            fields.insert(
                key.trim().trim_matches('"').to_string(),
                value.trim().trim_matches('"').to_string(),
            );
        }
        objects.push(fields);
        rest = &rest[close + 1..];
    }
    Some(objects)
}

/// **Deux régions, une seule machine.**
///
/// C'est l'hôte au complet, en petit. Un saut indirect vers un bloc que la
/// première région n'a pas découvert : elle rend la main en disant où reprendre,
/// l'hôte compile la région qui commence là, et l'exécution continue — **sans
/// rien recopier**, parce que la mémoire et les registres appartiennent à
/// l'hôte et que les deux modules les empruntent.
///
/// Avant les imports, ce test aurait été impossible autrement qu'en recopiant
/// tout l'état entre deux machines de sept cent soixante-huit mébioctets.
///
/// Le juge n'est pas une valeur écrite à la main : c'est l'interpréteur, qui
/// est lui-même jugé par le silicium sur douze mille cas.
#[test]
fn two_regions_share_one_machine_and_the_switch_continues() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    // leaq 1f(%rip), %rdx ; jmp *%rdx ; movq $0, %rax ; 1: incq %rdx
    let bytes: [u8; 19] = [
        0x48, 0x8d, 0x15, 0x09, 0x00, 0x00, 0x00, // 0  : lea, sept octets
        0xff, 0xe2, // 7  : jmp *%rdx
        0x48, 0xc7, 0xc0, 0x00, 0x00, 0x00, 0x00, // 9  : que personne n'atteint
        0x48, 0xff, 0xc2, // 16 : incq %rdx, la cible
    ];

    // Ce que l'interpréteur — vérifié contre le silicium — en fait.
    let mut cpu = Cpu {
        rip: CODE,
        ..Default::default()
    };
    let mut steps = 0;
    while (cpu.rip.wrapping_sub(CODE) as usize) < bytes.len() && steps < 16 {
        steps += 1;
        let at = cpu.rip.wrapping_sub(CODE) as usize;
        assert_ne!(cpu.step(&bytes[at..]), Step::Unknown, "à l'adresse {at}");
    }
    let expected = cpu.regs[2];
    assert_eq!(
        expected,
        CODE + 17,
        "l'interpréteur doit poser RDX sur 1: + 1"
    );

    let scratch = std::env::temp_dir().join(format!("wisq-x86-switch-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    // La première région part de l'entrée ; la seconde de l'adresse que la
    // première a rendue. C'est exactement ce que l'hôte fera.
    let mut paths = Vec::new();
    for (name, entry) in [("first", 0usize), ("second", 16usize)] {
        let module = Module::region(&bytes, CODE, entry).expect("la région doit se compiler");
        let path = scratch.join(format!("{name}.wasm"));
        std::fs::write(&path, &module).expect("le module");
        paths.push(path.to_string_lossy().to_string());
    }
    let driver = scratch.join("d.js");
    std::fs::write(
        &driver,
        format!(
            r#"
const fs = require("fs");
// **Une seule machine**, empruntée par les deux régions.
const memory = new WebAssembly.Memory({{ initial: {} }});
const slots = [];
for (let slot = 0; slot < {}; slot++) {{
  slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
}}
const imports = {{ env: {{ mem: memory }} }};
slots.forEach((global, slot) => {{ imports.env["g" + slot] = global; }});
const load = path =>
  new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(path)), imports);

// **Le module dit de quoi il a besoin.** Un import déclare un *minimum* de
// pages ; un hôte qui en offrirait moins doit être refusé ici, à
// l'instanciation, et non plus tard par une trappe au premier accès invité.
let refused = "";
try {{
  new WebAssembly.Instance(
    new WebAssembly.Module(fs.readFileSync({:?})),
    {{ env: {{ ...imports.env, mem: new WebAssembly.Memory({{ initial: 1 }}) }} }});
}} catch (error) {{ refused = error.constructor.name; }}

slots[4].value = 0x30003000n;               // rsp
const first = load({:?});
first.exports.run(64n);
const handed = BigInt.asUintN(64, slots[{}].value);
const between = BigInt.asUintN(64, slots[2].value);

// L'hôte reprend là où la première région s'est arrêtée.
const second = load({:?});
second.exports.run(64n);

console.log(JSON.stringify({{
  refused,
  handed: handed.toString(16),
  between: between.toString(16),
  rdx: BigInt.asUintN(64, slots[2].value).toString(16),
}}));
"#,
            GUEST_PAGES, GLOBAL_COUNT, paths[0], paths[0], RIP_SLOT, paths[1]
        ),
    )
    .expect("le pilote");

    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        output.status.success(),
        "JavaScriptCore a refusé un module :\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    // Une machine trop petite est refusée au moment de la lier, pas au premier
    // accès : c'est la déclaration d'import qui le tient.
    assert!(
        text.contains("\"refused\":\"LinkError\""),
        "une mémoire d'une page devait être refusée à l'instanciation — {text}"
    );
    // La première rend la main sur la cible du saut, pas ailleurs.
    assert!(
        text.contains(&format!("\"handed\":\"{:x}\"", CODE + 16)),
        "la première région devait rendre la main sur 1: — {text}"
    );
    // Et elle a bien posé RDX au passage : ce qu'elle a fait avant de rendre la
    // main compte, et la seconde région le retrouve.
    assert!(
        text.contains(&format!("\"between\":\"{:x}\"", CODE + 16)),
        "le `lea` de la première région doit survivre à la bascule — {text}"
    );
    assert!(
        text.contains(&format!("\"rdx\":\"{expected:x}\"")),
        "après la bascule, les deux cœurs doivent dire la même chose — {text}"
    );
}
