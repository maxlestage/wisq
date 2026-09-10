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

use wisq_vm::x86::{decode, Cpu, Op, Step, Width};
use wisq_vm::x86_wasm::{
    host_pages, table_base, table_slot, tlb_base, Module, Refused, BENCH_MEMORY_ACCESSES_PER_TURN,
    BENCH_MEMORY_LOOP, BENCH_MEMORY_PER_TURN, GLOBAL_COUNT, GS_SLOT, GUEST_PAGES, RFLAGS_SLOT,
    RIP_SLOT, TABLE_IMPORT, TABLE_MIX, TLB_PAGES,
};

// **Pourquoi chacun des dix pilotes de ce fichier porte `out` et `in`.**
//
// Aucun de ces tests ne fait d'entrée-sortie : ils comparent du calcul à ce que
// le vrai processeur en fait. Mais tout module émis les **déclare** depuis que
// l'invité sait parler, et un module qui déclare un import que l'objet ne porte
// pas est refusé à l'instanciation — `LinkError: import function env:out must
// be callable`, et pas une ligne sur le calcul qu'on croyait mesurer.
//
// La répétition est assumée plutôt que factorisée : elle est **comparée**, et
// par le moteur lui-même. Un pilote à qui il manquerait ces deux fonctions ne
// se tairait pas, il refuserait bruyamment.
//
// **Et ça n'a pas suffi.** L'argument suppose que quelqu'un *entende* le bruit.
// Les trois pilotes de `examples/` ont refusé bruyamment pendant toute une
// tranche — personne ne les lance en intégration continue — et `speed.rs`
// traduisait même le refus en « Bun est absent » alors que Bun avait répondu.
// `every_driver_supplies_the_functions_a_module_imports`, en bas de ce fichier,
// écoute à leur place, et les noms qu'il vérifie viennent de la section
// d'import d'un vrai module plutôt que d'une liste écrite à la main.

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
const imports = { env: { mem: memory, out: () => undefined, in: () => 0n } };
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
      // Quatre valeurs, puis les quatre pointeurs : RSP, RBP, RSI, RDI.
      regs: [0, 1, 2, job.flagsSlot, 4, 5, 6, 7]
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
    /// **RSP, RBP, RSI et RDI** — les quatre seuls registres que le corpus
    /// autorise à bouger, et donc les quatre seuls qu'il relève. Sans eux, un
    /// `leave` qui dépile avant de reprendre RBP passe : RAX, RCX, RDX, les
    /// drapeaux et les deux fenêtres restent exactement justes. RDI est arrivé
    /// avec les instructions de chaîne, qui l'avancent.
    pointers: (u64, u64, u64, u64),
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
                pointers: (hex(f[9]), hex(f[10]), hex(f[11]), hex(f[12])),
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
    type Wanted = (
        u64,
        u64,
        u64,
        u64,
        u64,
        String,
        Vec<u8>,
        (u64, u64, u64, u64),
    );
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
    // **Quelles instructions rendent la main, et pas seulement combien.** Le
    // compte seul laisserait `rep` sortir du champ de la comparaison sans que
    // rien ne le dise : un cas rendu n'est pas un cas faux, il est un cas non
    // jugé, et la différence ne se voit pas dans un total.
    // La clé est **l'identifiant** de l'instruction, pas son nom : c'est lui
    // qui retrouve les octets dans le corpus, et les octets sont ce qui dit si
    // un programme porte un `rep`.
    let mut gave_up: std::collections::BTreeSet<(String, String)> = Default::default();
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
            // L'identifiant d'un cas est « instruction|état » ; c'est la
            // première moitié qui retrouve les octets dans le corpus.
            let instruction = id.split('|').next().unwrap_or(id).to_string();
            gave_up.insert((instruction, mnemonic.clone()));
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
                     rdi {:x}≠{:x} drapeaux {:x}≠{:x} (masque {mask:x}){}",
                    got.0,
                    got.1,
                    got.2,
                    pointers.0,
                    want_pointers.0,
                    pointers.1,
                    want_pointers.1,
                    pointers.2,
                    want_pointers.2,
                    pointers.3,
                    want_pointers.3,
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
        checked + handed_back > 13210,
        "l'émetteur ne couvre plus que {checked} cas : la couverture a reculé"
    );
    // **Et un plancher sur les cas réellement jugés, pas seulement sur la
    // somme.** La somme seule laisserait une famille repasser de « comparée »
    // à « rendue » sans que rien ne tombe : le total ne bouge pas, et pourtant
    // le silicium ne juge plus rien de cette famille. La boucle du `rep` a fait
    // monter ce compte de 12836 à 12980, puis les conseils au cache et les
    // barrières mémoire de 12980 à 13052 ; c'est lui qui ne doit pas
    // redescendre.
    assert!(
        checked > 13040,
        "seuls {checked} cas sont jugés contre le silicium : une famille est \
         repassée derrière un retour de main"
    );

    // **`rep` ne peut plus rendre la main, et ce n'est pas une question de
    // vitesse.** Ce qui reprend après un retour de main doit lire la RAM de
    // l'invité, qui est la mémoire linéaire du module, dans le processus de
    // contenu de WebKit. Un secours qui vit ailleurs ne le peut pas — et
    // « ailleurs » comprend l'application. Les deux seules issues étaient un
    // quatrième cœur écrit en JavaScript, ou la boucle dans le module ; c'est
    // la boucle.
    // **Le filtre porte sur les octets, pas sur le nom.** Un programme du corpus
    // s'appelle « remplir la mémoire par répétition » : chercher « rep » dedans
    // ne trouve rien, et le test aurait passé sans rien vérifier. C'est le
    // préfixe `f3` devant une instruction de chaîne qui dit `rep`, et lui seul.
    let repeats: Vec<&String> = gave_up
        .iter()
        .filter(|(id, _)| {
            oracle.instructions.get(id).is_some_and(|(code, _, _)| {
                code.windows(2)
                    .any(|pair| pair[0] == 0xf3 && matches!(pair[1], 0xa4 | 0xa5 | 0xaa | 0xab))
                    || code.windows(3).any(|three| {
                        three[0] == 0xf3
                            && three[1] == 0x48
                            && matches!(three[2], 0xa4 | 0xa5 | 0xaa | 0xab)
                    })
            })
        })
        .map(|(_, name)| name)
        .collect();
    assert!(
        repeats.is_empty(),
        "ces programmes rendent encore la main, donc rien ne les juge contre le \
         silicium : {repeats:?}"
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
type Produced = (
    u64,
    u64,
    u64,
    u64,
    (u64, u64, u64, u64),
    Option<Vec<u8>>,
    bool,
);

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
        if values.len() == 8 {
            out.insert(
                id,
                (
                    values[0],
                    values[1],
                    values[2],
                    values[3],
                    (values[4], values[5], values[6], values[7]),
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
const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n }} }};
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

/// **`ud2` : rendre la main **sur** elle, pas après.**
///
/// Le corpus ne peut pas juger cette instruction — elle lève une exception, et
/// le pilote de l'oracle mourrait avec. Ce qu'il faut tenir est donc ici :
/// l'adresse à laquelle le module rend la main est celle du `ud2` lui-même.
/// Reprendre un octet plus loin ferait exécuter à l'interpréteur ce que le
/// noyau range derrière son `BUG()`, qui n'est pas du code.
///
/// Le `incq` d'avant est le témoin : rendre la main n'annule pas ce qui a déjà
/// eu lieu dans le bloc.
#[test]
fn an_undefined_instruction_hands_back_its_own_address() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    // `incq %rdx` (trois octets) puis `ud2` (deux).
    let bytes = [0x48, 0xff, 0xc2, 0x0f, 0x0b];
    let module = Module::region(&bytes, CODE, 0).expect("la région doit se compiler");

    let scratch = std::env::temp_dir().join(format!("wisq-x86-ud2-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let path = scratch.join("m.wasm");
    std::fs::write(&path, &module).expect("le module");
    let driver = scratch.join("d.js");
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
const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n }} }};
slots.forEach((global, slot) => {{ imports.env["g" + slot] = global; }});
const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
slots[2].value = 0n;            // rdx : le témoin
slots[4].value = 0x30003000n;   // rsp
instance.exports.run(64n);
console.log(JSON.stringify({{
  rdx: slots[2].value.toString(),
  rip: BigInt.asUintN(64, slots[{}].value).toString(16),
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
        "l'instruction d'avant devait avoir eu lieu, il a rendu {text}"
    );
    assert!(
        text.contains("\"rip\":\"30000003\""),
        "le module devait rendre la main **sur** le `ud2`, à 0x30000003, \
         et non après lui : il a rendu {text}"
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
  const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n }} }};
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
const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n }} }};
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

/// **Ce qu'une région coûtera à l'hôte, compté avant de l'exécuter.**
///
/// `survey` sert à une mesure qui décide de l'architecture du bureau local :
/// ce qui reprend après un retour de main doit pouvoir lire la RAM invitée, et
/// la RAM invitée est la mémoire linéaire du module. Un compte faux ferait
/// conclure de travers, donc il est tenu instruction par instruction.
#[test]
fn a_survey_counts_where_a_region_will_hand_back() {
    // Quatre calculs et un saut : rien ne rend la main.
    let plain = Module::survey(&wisq_vm::x86_wasm::BENCH_LOOP, 0).expect("la boucle du banc");
    assert_eq!(plain.blocks, 1);
    assert_eq!(plain.instructions, 5);
    assert_eq!(plain.always, 0, "aucune de ces cinq ne rend la main");
    assert_eq!(plain.perhaps, 0);

    // **`rep movsq` ne rend plus la main** : sa boucle est émise, parce que
    // l'hôte n'a nulle part où l'exécuter. `f3 48 a5` = rep movsq ; `c3` = ret.
    let repeated = Module::survey(&[0xf3, 0x48, 0xa5, 0xc3], 0).expect("rep movsq puis ret");
    assert_eq!(repeated.always, 0, "le `rep` reste dans le module");
    assert_eq!(repeated.repeats, 1, "et il est compté comme chaîne répétée");
    assert_eq!(
        repeated.perhaps, 1,
        "le `ret` peut rendre la main, pas plus"
    );

    // `ud2` aussi, mais ce n'est pas un `rep` : une boucle émise n'y changerait
    // rien, la faute appartient à l'hôte.
    let faulting = Module::survey(&[0x0f, 0x0b], 0).expect("ud2");
    assert_eq!(faulting.always, 1);
    assert_eq!(faulting.repeats, 0, "un `ud2` n'est pas une copie");

    // **Et les blocs se comptent.** Un saut conditionnel en ouvre deux de plus :
    // la cible et la suite. Sans ce cas, toutes les régions du test tiendraient
    // en un bloc et le compte pourrait dire n'importe quoi.
    //   cmpq $1, %rax ; jne +2 ; incq %rax ; ret
    let branching = Module::survey(
        &[0x48, 0x83, 0xf8, 0x01, 0x75, 0x03, 0x48, 0xff, 0xc0, 0xc3],
        0,
    )
    .expect("une comparaison, un saut, deux suites");
    assert!(
        branching.blocks >= 2,
        "un saut conditionnel ouvre plus d'un bloc, {} relevé",
        branching.blocks
    );
    assert!(
        branching.instructions >= 4,
        "et les quatre instructions sont comptées, {} relevées",
        branching.instructions
    );

    // Une copie **sans** `rep` reste dans le module : c'est le préfixe qui
    // décide, pas l'instruction.
    let once = Module::survey(&[0x48, 0xa5, 0xc3], 0).expect("movsq puis ret");
    assert_eq!(once.always, 0, "un `movsq` seul ne rend pas la main");
    assert_eq!(once.repeats, 0);
}

/// **Ce que `outline` dit, et qui a démenti une hypothèse écrite.**
///
/// La feuille de route portait deux explications de l'arrêt d'un vrai noyau à
/// `__startup_64 + 658` : le bloc terminé sans que son `jmp` en soit le
/// terminateur, ou le `jmp` émis comme une chute. Toutes les deux supposaient
/// que le saut n'était **pas pris**. Le relevé a montré une troisième chose,
/// qu'aucune relecture n'aurait proposée : le bloc d'à côté finit sur un saut
/// **conditionnel** dont la cible est cette adresse, et l'adresse porte
/// `eb fe` — la boucle de parking d'un `for (;;)` que le noyau écrit lui-même.
/// Le saut est pris, exprès, et il n'y avait pas de défaut d'émission là.
///
/// Ce test tient les trois choses dont cette lecture dépendait, sur des octets
/// écrits ici plutôt que sur un noyau qui n'est pas dans le dépôt.
#[test]
fn an_outline_names_where_each_block_leads() {
    // `eb fe` seul : un saut inconditionnel sur lui-même. C'est la forme que
    // prend `for (;;)`, et c'est elle qu'il fallait pouvoir reconnaître.
    let parked = Module::outline(&[0xeb, 0xfe], 0).expect("la boucle de parking");
    assert_eq!(parked.len(), 1);
    assert_eq!(parked[0].steps, 1);
    assert_eq!(parked[0].after, 2, "un `eb fe` occupe deux octets");
    assert_eq!(parked[0].ends, Some(Op::Jump(None)));
    assert_eq!(parked[0].target, Some(0), "il retombe sur lui-même");
    assert_eq!(
        parked[0].goes,
        Some(0),
        "et sa cible est son propre bloc, ce qui est tout le sens d'un parking"
    );

    // Un saut **conditionnel** vers une boucle de parking, exactement la forme
    // trouvée en tête de `__startup_64` : la cible est nommée, et c'est un
    // bloc de la région. Sans ce cas, rien ne distinguerait « le saut n'est pas
    // pris » de « le saut mène là ».
    //   cmpq $1,%rax ; jne +4 ; xorq %rax,%rax ; ret ; eb fe
    let guarded = Module::outline(
        &[
            0x48, 0x83, 0xf8, 0x01, 0x75, 0x04, 0x48, 0x31, 0xc0, 0xc3, 0xeb, 0xfe,
        ],
        0,
    )
    .expect("une garde et son parking");
    let first = guarded.first().expect("le bloc d'entrée");
    assert_eq!(first.start, 0);
    assert_eq!(first.after, 6, "la comparaison et le saut");
    assert!(
        matches!(first.ends, Some(Op::Jump(Some(_)))),
        "le bloc finit sur un saut conditionnel, {:?} relevé",
        first.ends
    );
    assert_eq!(first.target, Some(10), "et sa cible est le `eb fe`");
    let goes = first.goes.expect("la cible est dans la région");
    assert_eq!(guarded[goes].start, 10, "l'indice désigne bien ce bloc-là");
    assert_eq!(guarded[goes].ends, Some(Op::Jump(None)));
    assert_eq!(guarded[goes].goes, Some(goes), "qui se gare sur lui-même");

    // **Une cible hors de la région n'a pas d'indice**, et c'est ce qui fait
    // rendre la main plutôt que sauter. `e9 rel32` très loin devant.
    let leaves = Module::outline(&[0xe9, 0x00, 0x10, 0x00, 0x00], 0).expect("un saut lointain");
    assert_eq!(leaves[0].ends, Some(Op::Jump(None)));
    assert_eq!(leaves[0].target, Some(0x1005));
    assert_eq!(
        leaves[0].goes, None,
        "hors région : le module rend la main, il ne saute pas"
    );

    // **Un bloc coupé par le bord de la région n'a pas de terminateur**, et
    // c'est le seul cas où la reprise est `after`. C'est la distinction que le
    // relevé existe pour rendre lisible : sans elle, « le saut mène après » et
    // « il n'y a pas de saut » se ressemblent.
    //   xorq %rax,%rax — et plus rien après.
    let cut = Module::outline(&[0x48, 0x31, 0xc0], 0).expect("un bloc sans fin");
    assert_eq!(cut[0].steps, 1);
    assert_eq!(cut[0].after, 3);
    assert_eq!(cut[0].ends, None, "aucune instruction ne termine ce bloc");
    assert_eq!(cut[0].target, None);
    assert_eq!(cut[0].goes, None);

    // Un `ret` n'a pas de cible statique : elle sort de la pile. Dire `None`
    // ici est une absence de réponse, pas une réponse.
    let returns = Module::outline(&[0xc3], 0).expect("un ret");
    assert_eq!(returns[0].ends, Some(Op::Return));
    assert_eq!(returns[0].target, None);
    assert_eq!(returns[0].goes, None);
}

/// **La boucle hôte, et pas seulement une bascule.**
///
/// Le test voisin montre *une* région qui rend la main et *une* qui reprend.
/// Celui-ci enchaîne : huit régions en anneau, chacune sautant indirectement à
/// la suivante, l'hôte cherchant à chaque tour laquelle commence à RIP. C'est
/// la conduite du bureau local en petit, et rien ne la tenait — `--example
/// chain` la chronomètre, ce qui ne dit pas qu'elle calcule juste.
///
/// Ce qui est vérifié : la chaîne ne se perd pas, chaque maillon a bien tourné,
/// et l'accumulateur porte à la fin ce qu'un modèle écrit en clair calcule. Un
/// anneau qui sauterait un maillon rendrait un total plus petit, et un anneau
/// qui recompterait le même rendrait un total plus grand.
#[test]
fn the_host_loop_chains_regions_and_keeps_the_machine() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const LINKS: u64 = 8;
    const STRIDE: u64 = 64;
    let address = |index: u64| CODE + index * STRIDE;

    // movabs $suivant, %rax ; addq %rax, %rdx ; jmp *%rax
    let link = |next: u64| {
        let mut code = vec![0x48u8, 0xb8];
        code.extend_from_slice(&next.to_le_bytes());
        code.extend_from_slice(&[0x48, 0x01, 0xc2, 0xff, 0xe0]);
        code
    };

    let scratch = std::env::temp_dir().join(format!("wisq-chain-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut listing = String::new();
    for index in 0..LINKS {
        let module = Module::region(&link(address((index + 1) % LINKS)), address(index), 0)
            .expect("l'émetteur traduit un maillon");
        let path = scratch.join(format!("m{index}.wasm"));
        std::fs::write(&path, &module).expect("le module");
        listing.push_str(&format!(
            "[{}n,{:?}],",
            address(index),
            path.to_string_lossy()
        ));
    }

    // **Le modèle, écrit en clair.** RDX accumule l'adresse de chaque maillon
    // suivant, dans l'ordre où l'anneau les visite.
    let steps = 8 * LINKS + 3;
    let mut rdx = 0u64;
    let mut at = 0u64;
    for _ in 0..steps {
        rdx = rdx.wrapping_add(address((at + 1) % LINKS));
        at = (at + 1) % LINKS;
    }

    let driver = scratch.join("d.js");
    std::fs::write(
        &driver,
        format!(
            r#"
const fs = require("fs");
const memory = new WebAssembly.Memory({{ initial: {pages} }});
const slots = [];
const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n }} }};
for (let slot = 0; slot < {globals}; slot++) {{
  slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
  imports.env["g" + slot] = slots[slot];
}}
const cache = new Map();
for (const [base, path] of [{listing}]) {{
  const bytes = fs.readFileSync(path);
  cache.set(base, new WebAssembly.Instance(new WebAssembly.Module(bytes), imports).exports.run);
}}
const u = slot => BigInt.asUintN(64, slots[slot].value);
slots[{rip}].value = {entry}n;
let taken = 0, lost = "";
for (let step = 0; step < {steps}; step++) {{
  const run = cache.get(u({rip}));
  if (run === undefined) {{ lost = u({rip}).toString(16); break; }}
  run(16n);
  taken++;
}}
console.log(JSON.stringify({{ taken, lost, rdx: u(2).toString(16), rip: u({rip}).toString(16) }}));
"#,
            pages = GUEST_PAGES,
            globals = GLOBAL_COUNT,
            listing = listing,
            rip = RIP_SLOT,
            entry = CODE,
            steps = steps
        ),
    )
    .expect("le pilote");

    let output = Command::new(bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        output.status.success(),
        "JavaScriptCore a refusé la chaîne :\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        text.contains("\"lost\":\"\""),
        "la chaîne s'est perdue en route — {text}"
    );
    assert!(
        text.contains(&format!("\"taken\":{steps}")),
        "les {steps} maillons devaient tous tourner — {text}"
    );
    assert!(
        text.contains(&format!("\"rdx\":\"{rdx:x}\"")),
        "l'anneau ne calcule pas ce que le modèle calcule — {text}"
    );
    // Et il s'est arrêté là où l'anneau l'a mené, pas ailleurs.
    assert!(
        text.contains(&format!("\"rip\":\"{:x}\"", address(steps % LINKS))),
        "RIP ne désigne pas le maillon attendu — {text}"
    );
}

/// **La forme liée : les blocs vivent dans la table de l'hôte.**
///
/// C'est la première moitié de ce que la mesure a désigné. Un module lié
/// n'a plus sa propre table : il importe celle de l'hôte et y pose ses blocs à
/// l'emplacement qu'on lui donne. Deux régions liées à la même table pourront
/// alors s'appeler sans repasser par JavaScript — 7,2 ns contre 192.
///
/// **Cette tranche ne prend pas le gain, elle le prépare**, et c'est
/// exactement ce que ce test doit établir : le module lié se lie, il tourne, et
/// il calcule **la même chose** que la forme historique. Un émetteur qui
/// changerait de résultat en changeant de forme de table serait un émetteur à
/// deux vérités.
#[test]
fn a_linked_region_lives_in_the_hosts_table_and_computes_the_same() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la forme liée ne serait vérifiée par rien.");
    };
    // addq %rax, %rdx ; xorq %rcx, %rbx ; addq %rdx, %rax ; subq $1, %rsi ; jnz
    let code = wisq_vm::x86_wasm::BENCH_LOOP;
    // Pas zéro : un décalage nul cacherait une addition oubliée.
    const SLOT: u32 = 5;
    let plain = Module::region(&code, CODE, 0).expect("la forme historique");
    let linked = Module::linked(&code, CODE, 0, SLOT).expect("la forme liée");
    assert_ne!(
        plain, linked,
        "les deux formes ne peuvent pas être le même module"
    );

    // **L'import est là, et il demande la place qu'il faut.** Le minimum couvre
    // l'emplacement plus les blocs : une table plus petite doit refuser.
    let entry: Vec<u8> = [3u8]
        .iter()
        .copied()
        .chain(b"env".iter().copied())
        .chain([TABLE_IMPORT.len() as u8])
        .chain(TABLE_IMPORT.bytes())
        .chain([0x01, 0x70, 0x00])
        .collect();
    assert!(
        linked.windows(entry.len()).any(|window| window == entry),
        "le module lié doit importer env.{TABLE_IMPORT}"
    );
    assert!(
        !plain.windows(entry.len()).any(|window| window == entry),
        "et la forme historique ne doit pas"
    );

    let scratch = std::env::temp_dir().join(format!("wisq-linked-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let path = scratch.join("linked.wasm");
    std::fs::write(&path, &linked).expect("le module");
    let driver = scratch.join("d.js");
    let turns = 1000u64;
    std::fs::write(
        &driver,
        format!(
            r#"
const fs = require("fs");
const bytes = fs.readFileSync({path:?});
const memory = new WebAssembly.Memory({{ initial: {pages} }});
const slots = [];
const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n }} }};
for (let slot = 0; slot < {globals}; slot++) {{
  slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
  imports.env["g" + slot] = slots[slot];
}}
const u = slot => BigInt.asUintN(64, slots[slot].value);
const out = {{}};

// **Une table trop petite doit refuser.** Le module en demande {slot} + ses
// blocs ; une table de {slot} entrées n'a de place pour aucun.
try {{
  imports.env.{table} = new WebAssembly.Table({{ element: "anyfunc", initial: {slot} }});
  new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
  out.small = "acceptée";
}} catch (why) {{ out.small = why.constructor.name; }}

imports.env.{table} = new WebAssembly.Table({{ element: "anyfunc", initial: 64 }});
const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
// Les blocs sont bien posés à l'emplacement, pas au début.
out.before = imports.env.{table}.get({slot} - 1) === null ? "vide" : "occupée";
out.at = imports.env.{table}.get({slot}) === null ? "vide" : "occupée";

slots[0].value = 1n;                    // rax
slots[1].value = 0x0123456789abcdefn;   // rcx
slots[6].value = {turns}n;              // rsi
instance.exports.run({turns}n + 8n);
out.rax = u(0).toString(16);
out.rbx = u(3).toString(16);
out.rdx = u(2).toString(16);
out.rsi = u(6).toString(16);
out.rip = u({rip}).toString(16);
console.log(JSON.stringify(out));
"#,
            path = path.to_string_lossy(),
            pages = GUEST_PAGES,
            globals = GLOBAL_COUNT,
            table = TABLE_IMPORT,
            slot = SLOT,
            turns = turns,
            rip = RIP_SLOT
        ),
    )
    .expect("le pilote");

    let output = Command::new(bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        output.status.success(),
        "JavaScriptCore a refusé le module lié :\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        text.contains("\"small\":\"LinkError\""),
        "une table trop petite devait refuser la liaison — {text}"
    );
    assert!(
        text.contains("\"before\":\"vide\"") && text.contains("\"at\":\"occupée\""),
        "les blocs doivent être posés à l'emplacement, pas avant — {text}"
    );

    // **Et le résultat est celui de l'interpréteur**, qui est celui du
    // silicium : la forme de la table ne change pas ce que la région calcule.
    let mut cpu = Cpu {
        rip: CODE,
        ..Default::default()
    };
    cpu.regs[0] = 1;
    cpu.regs[1] = 0x0123_4567_89ab_cdef;
    cpu.regs[6] = turns;
    while (cpu.rip.wrapping_sub(CODE) as usize) < code.len() {
        let at = cpu.rip.wrapping_sub(CODE) as usize;
        if cpu.step(&code[at..]) == Step::Unknown {
            break;
        }
    }
    for (slot, name) in [(0usize, "rax"), (3, "rbx"), (2, "rdx"), (6, "rsi")] {
        assert!(
            text.contains(&format!("\"{name}\":\"{:x}\"", cpu.regs[slot])),
            "{name} : le module lié ne calcule pas comme l'interpréteur — {text}"
        );
    }
    assert!(
        text.contains(&format!("\"rip\":\"{:x}\"", CODE + code.len() as u64)),
        "et il rend la main à la sortie de la boucle — {text}"
    );
}

/// **L'invité ne peut pas sortir de sa RAM — et la preuve est une écriture qui
/// n'arrive pas là où elle visait.**
///
/// La feuille de route disait qu'il faudrait une **seconde mémoire** pour
/// mettre la correspondance adresse → indice hors de portée de l'invité, et
/// que rien ne prouvait qu'un vrai iPhone l'accepte. Un masque n'a besoin
/// d'aucune extension : l'hôte fournit une mémoire plus grande que ce que le
/// module déclare, et le module ne peut pas l'atteindre.
///
/// Ce test le montre dans les deux sens sur le **même programme**, parce qu'un
/// seul sens ne prouve rien : une écriture absente peut venir d'un module qui
/// n'écrit nulle part. La forme libre doit atteindre la page haute, la forme
/// confinée doit retomber dans la basse.
#[test]
fn a_confined_region_cannot_reach_past_the_ram_it_was_given() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    // `movq %rax, (%rsi)` : une écriture, à une adresse qui vient d'un
    // registre — la seule forme que l'émetteur produise.
    let bytes = [0x48, 0x89, 0x06];
    // Une seule page de RAM : le masque vaut 0xFFFF, et l'hôte en donnera deux.
    let confined = Module::confined(&bytes, CODE, 0, 1).expect("la forme confinée");
    let free = Module::region(&bytes, CODE, 0).expect("la forme libre");
    assert_ne!(
        confined, free,
        "le masque doit se voir dans les octets, sinon il n'a pas été posé"
    );

    let scratch = std::env::temp_dir().join(format!("wisq-x86-confine-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let held = scratch.join("confined.wasm");
    let loose = scratch.join("free.wasm");
    std::fs::write(&held, &confined).expect("le module confiné");
    std::fs::write(&loose, &free).expect("le module libre");
    let driver = scratch.join("d.js");
    std::fs::write(
        &driver,
        format!(
            r#"
const fs = require("fs");
// L'adresse visée est dans la **seconde** page, que le masque d'une page ne
// peut pas atteindre : 0x10008 se replie sur 0x0008.
const TARGET = 0x10008;
const FOLDED = 0x00008;
const MARK = 0xc0ffeen;

// **Ce qu'un hôte doit allouer, calculé une seule fois.** Le nombre vient de
// `host_pages`, côté Rust : la RAM de l'invité, la correspondance, et le
// tampon de traduction. Un pilote qui refaisait la somme lui-même a manqué le
// tampon et ne s'instanciait plus.
const rooms = {rooms};
const hostPages = pages => pages + rooms;

function run(path, pages) {{
  // **La mémoire doit couvrir ce que le module déclare** : la RAM de
  // l'invité, la correspondance, et le tampon de traduction. Un hôte qui
  // n'en pose pas assez ne démarre pas — c'est voulu, et c'est ce que ce
  // pilote a appris le jour où la pagination est entrée.
  const memory = new WebAssembly.Memory({{ initial: hostPages(pages) }});
  const slots = [];
  for (let slot = 0; slot < {}; slot++) {{
    slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
  }}
  const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n }} }};
  slots.forEach((global, slot) => {{ imports.env["g" + slot] = global; }});
  const instance = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(path)), imports);
  slots[0].value = MARK;              // rax : ce qu'on écrit
  slots[6].value = BigInt(TARGET);    // rsi : où on croit l'écrire
  slots[4].value = 0x30003000n;       // rsp
  instance.exports.run(4n);
  const words = new BigUint64Array(memory.buffer);
  return [words[TARGET / 8].toString(), words[FOLDED / 8].toString()];
}}

// Quatre lignes plates plutôt que du JSON : ce harnais n'a pas de lecteur de
// JSON, et en ajouter un pour quatre nombres serait une dépendance de plus.
const held = run({:?}, 2);
const loose = run({:?}, {});
console.log("confinée.visée " + held[0]);
console.log("confinée.repliée " + held[1]);
console.log("libre.visée " + loose[0]);
console.log("libre.repliée " + loose[1]);
"#,
            GLOBAL_COUNT,
            held.to_string_lossy(),
            loose.to_string_lossy(),
            GUEST_PAGES,
            rooms = host_pages(0),
        ),
    )
    .expect("le pilote");

    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let complaint = String::from_utf8_lossy(&output.stderr).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        output.status.success(),
        "le pilote a échoué : {complaint}\n{text}"
    );
    let seen = |label: &str| -> String {
        text.lines()
            .find_map(|line| line.strip_prefix(label).map(|rest| rest.trim().to_string()))
            .unwrap_or_else(|| panic!("le pilote n'a pas dit « {label} » :\n{text}"))
    };
    let mark = 0xc0ffee_u64.to_string();
    let nothing = "0";

    // La forme libre atteint la seconde page : c'est ce que le confinement
    // interdit, et sans cette moitié le test passerait sur un module muet.
    assert_eq!(
        seen("libre.visée"),
        mark,
        "sans masque, l'écriture doit atteindre l'adresse visée"
    );
    assert_eq!(
        seen("libre.repliée"),
        nothing,
        "sans masque, rien ne doit tomber à l'adresse repliée"
    );

    // Et la forme confinée fait exactement l'inverse.
    assert_eq!(
        seen("confinée.repliée"),
        mark,
        "avec masque, l'écriture doit retomber dans la RAM déclarée"
    );
    assert_eq!(
        seen("confinée.visée"),
        nothing,
        "avec masque, la page au-dessus de la RAM doit rester intacte — \
         c'est là que vivra la correspondance adresse → indice"
    );
}

/// **Un masque qui ne décrit pas un intervalle n'en est pas un.**
///
/// `pages − 1` ne vaut comme masque que si `pages` est une puissance de deux :
/// avec trois pages il vaudrait 0x2FFFF, qui laisse passer 0x2FFFF mais coupe
/// 0x20000. Un module qui replie de travers écrit au hasard dans la RAM de
/// l'invité, ce qu'aucun test de conformité ne verrait — l'émetteur refuse
/// plutôt que d'y consentir.
#[test]
fn a_confinement_that_is_not_a_power_of_two_is_refused() {
    let bytes = [0x48, 0x89, 0x06];
    for pages in [0u32, 3, 5, 0x3001] {
        assert!(
            Module::confined(&bytes, CODE, 0, pages).is_none(),
            "{pages} pages ne donnent pas un masque"
        );
    }
    for pages in [1u32, 2, 4, 0x4000] {
        assert!(
            Module::confined(&bytes, CODE, 0, pages).is_some(),
            "{pages} pages en donnent un"
        );
    }
}

/// **Une région saute dans une autre sans repasser par l'hôte.**
///
/// C'est le but de tout ce qui précède. Jusqu'ici, un saut vers une adresse
/// que la région ne contient pas rendait la main : environ 190 ns, dont
/// l'essentiel n'est pas WebAssembly mais le site d'appel JavaScript qui perd
/// son cache en ligne. Avec la correspondance, le module trouve l'indice
/// lui-même et y va par `call_indirect`, mesuré à 7,2 ns.
///
/// Le test se juge sur **le nombre de tours de la boucle hôte** : un seul
/// appel à `run` doit exécuter les deux régions. Et il se juge dans les deux
/// sens — la même paire, avec la correspondance laissée vide, doit rendre la
/// main. Sans cette seconde moitié, un module qui exécuterait tout par hasard
/// passerait pour un module qui cherche.
#[test]
fn a_region_finds_another_region_through_the_correspondence() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    // Une page de RAM invitée suffit : ce qui compte est ce qu'il y a
    // au-dessus.
    const PAGES: u32 = 1;
    const HERE: u32 = 1; // l'emplacement de la première région
    const THERE: u32 = 4; // celui de la seconde, ni zéro ni voisin
    const AWAY: u64 = CODE + 0x2000;

    // `incq %rdx` puis `jmp *%rax` : la cible ne se connaît qu'à l'exécution,
    // donc c'est bien `resolve` qui décide, et pas un indice compilé.
    let leaves = [0x48, 0xff, 0xc2, 0xff, 0xe0];
    // `incq %rdx` deux fois, puis la fin de la région : elle rend la main, ce
    // qui distingue « la seconde région a tourné » de « la boucle est partie
    // en rond ».
    let arrives = [0x48, 0xff, 0xc2, 0x48, 0xff, 0xc2];

    let first = Module::resolving(&leaves, CODE, 0, HERE, PAGES).expect("la première région");
    let second = Module::resolving(&arrives, AWAY, 0, THERE, PAGES).expect("la seconde");

    let scratch = std::env::temp_dir().join(format!("wisq-corresp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let one = scratch.join("first.wasm");
    let two = scratch.join("second.wasm");
    std::fs::write(&one, &first).expect("la première");
    std::fs::write(&two, &second).expect("la seconde");
    let driver = scratch.join("d.js");
    std::fs::write(
        &driver,
        format!(
            r#"
const fs = require("fs");

// Même règle que l'autre pilote : la taille que l'hôte doit fournir vient de
// `host_pages`, pas d'une addition écrite ici.
const rooms = {rooms};
const hostPages = pages => pages + rooms;

// `fill` : 0 rien, 1 la bonne adresse, 2 une **autre** adresse dans la même
// case. Le troisième cas est celui qui compte le plus : sans la comparaison,
// le module sauterait dans un bloc qui n'a rien à voir.
function attempt(fill, pages) {{
  const memory = new WebAssembly.Memory({{ initial: pages }});
  const blocks = new WebAssembly.Table({{ element: "anyfunc", initial: 16 }});
  const slots = [];
  const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n, {tableName}: blocks }} }};
  for (let slot = 0; slot < {globals}; slot++) {{
    slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
    imports.env["g" + slot] = slots[slot];
  }}
  const here = new WebAssembly.Instance(
    new WebAssembly.Module(fs.readFileSync({one:?})), imports);
  new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync({two:?})), imports);

  // **L'hôte remplit la correspondance avec le même calcul que le module.**
  // Les deux nombres viennent de `table_base` et `table_slot`, côté Rust.
  if (fill) {{
    const at = {base} + {slot} * 16;
    new BigUint64Array(memory.buffer, at, 1)[0] = fill === 1 ? {away}n : {away}n + 1n;
    new Int32Array(memory.buffer, at + 8, 1)[0] = {there};
  }}

  slots[0].value = {away}n;   // rax : la cible du saut indirect
  slots[2].value = 0n;        // rdx : le compteur
  here.exports.run(16n);
  return slots[2].value.toString();
}}

console.log("remplie " + attempt(1, hostPages({pages})));
console.log("vide " + attempt(0, hostPages({pages})));
console.log("etrangere " + attempt(2, hostPages({pages})));

// **Et une mémoire sans place pour la correspondance ni pour le tampon de
// traduction ne doit pas démarrer.**
// Le module la lirait au-delà de ce qui existe, ce qui *piège* — et un piège
// WebAssembly est sans retour. Le refus au démarrage est bruyant ; le piège
// ne l'est pas.
try {{
  attempt(1, {pages});
  console.log("courte acceptee");
}} catch (why) {{
  console.log("courte " + why.constructor.name);
}}
"#,
            one = one.to_string_lossy(),
            two = two.to_string_lossy(),
            pages = PAGES,
            tableName = TABLE_IMPORT,
            globals = GLOBAL_COUNT,
            rooms = host_pages(0),
            base = table_base(PAGES),
            slot = table_slot(AWAY),
            away = AWAY,
            there = THERE,
        ),
    )
    .expect("le pilote");

    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let complaint = String::from_utf8_lossy(&output.stderr).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        output.status.success(),
        "le pilote a échoué : {complaint}\n{text}"
    );
    let seen = |label: &str| -> String {
        text.lines()
            .find_map(|line| line.strip_prefix(label).map(|rest| rest.trim().to_string()))
            .unwrap_or_else(|| panic!("le pilote n'a pas dit « {label} » :\n{text}"))
    };
    // Un `incq` dans la première région, deux dans la seconde : trois en un
    // seul appel à `run` veut dire que le saut n'est pas repassé par l'hôte.
    assert_eq!(
        seen("remplie"),
        "3",
        "avec la correspondance, les deux régions doivent tourner en un appel"
    );
    // Et sans elle, la première seule : c'est la moitié qui empêche ce test
    // de passer sur un module qui exécuterait tout par hasard.
    assert_eq!(
        seen("vide"),
        "1",
        "sans la correspondance, le saut doit rendre la main comme avant"
    );
    // **La case occupée par quelqu'un d'autre.** C'est le défaut le plus grave
    // que cette tranche puisse porter : sans la comparaison d'adresse, le
    // module saute dans un bloc au hasard, et rien de ce qui précède ne s'en
    // plaindrait — le sabotage l'a montré en survivant aux deux premières
    // moitiés.
    assert_eq!(
        seen("etrangere"),
        "1",
        "une case qui range une autre adresse ne doit pas faire sauter le module"
    );
    // Et une mémoire trop courte doit refuser au démarrage plutôt que piéger
    // au premier saut.
    assert_eq!(
        seen("courte"),
        "LinkError",
        "une mémoire sans place pour la correspondance doit être refusée"
    );
}

/// **L'hôte et le module doivent tomber sur la même case, et rien dans le
/// module ne le dit à haute voix.**
///
/// `table_slot` est écrite deux fois : en Rust, pour que l'hôte range ; et en
/// octets WebAssembly, pour que le module relise. Si les deux divergent, rien
/// n'est jamais trouvé — le module rend la main comme avant, tous les tests de
/// conformité restent verts, et la seule chose perdue est la vitesse. Un
/// défaut muet, donc, et c'est pourquoi il faut un test qui regarde les octets.
#[test]
fn the_module_hashes_an_address_the_same_way_the_host_does() {
    const PAGES: u32 = 1;
    let module = Module::resolving(&[0x48, 0xff, 0xc2, 0xff, 0xe0], CODE, 0, 1, PAGES)
        .expect("la région cherchante");

    // Le multiplicateur, en octets, tel que `i64.const` l'écrit. L'encodage se
    // **recalcule ici** plutôt que de s'écrire en dur : mon premier jet l'avait
    // deviné, et quatre de ses dix octets étaient faux. Une constante devinée
    // qui passe pour vérifiée est pire que pas de test du tout.
    let mix = {
        let mut value = TABLE_MIX as i64;
        let mut out = Vec::new();
        loop {
            let byte = (value & 0x7f) as u8;
            value >>= 7;
            let done = (value == 0 && byte & 0x40 == 0) || (value == -1 && byte & 0x40 != 0);
            out.push(if done { byte } else { byte | 0x80 });
            if done {
                break out;
            }
        }
    };
    assert!(
        module.windows(mix.len()).any(|window| window == mix),
        "le module doit porter le multiplicateur du hachage"
    );
    // Et une forme qui ne cherche pas ne doit pas le porter : sinon
    // l'assertion du dessus tiendrait pour une raison sans rapport.
    let plain = Module::region(&[0x48, 0xff, 0xc2, 0xff, 0xe0], CODE, 0).expect("la forme simple");
    assert!(
        !plain.windows(mix.len()).any(|window| window == mix),
        "et la forme qui ne cherche pas ne doit pas le porter"
    );

    // Le calcul lui-même, sur des adresses réelles : chaque case doit tenir
    // dans la table, et deux adresses voisines ne doivent pas s'entasser.
    let mut seen = std::collections::HashSet::new();
    for step in 0..1024u64 {
        let slot = table_slot(CODE + step * 16);
        assert!(
            slot < wisq_vm::x86_wasm::TABLE_SLOTS,
            "la case doit tenir dans la table"
        );
        seen.insert(slot);
    }
    // Le produit prend les bits **hauts**, précisément pour que des adresses
    // alignées ne se disputent pas les mêmes cases. Les bits bas d'un produit
    // de Knuth, eux, n'auraient rien mélangé — la sonde de table l'a montré.
    assert!(
        seen.len() > 1000,
        "1024 adresses alignées doivent trouver plus de 1000 cases distinctes, \
         pas {} : le hachage ne mélange pas",
        seen.len()
    );
    assert_eq!(
        table_base(PAGES),
        65536,
        "la correspondance vit juste au-dessus de la RAM confinée"
    );

    // Une région cherchante hérite de la contrainte du confinement : sans une
    // puissance de deux, le masque ne décrit pas un intervalle, et la
    // correspondance se retrouverait *dans* ce que l'invité peut écrire.
    for pages in [0u32, 3, 5, 0x3001] {
        assert!(
            Module::resolving(&[0x48, 0xff, 0xc2, 0xff, 0xe0], CODE, 0, 1, pages).is_none(),
            "{pages} pages ne donnent pas un masque"
        );
    }
}

/// **Un saut indirect qui revient dans sa propre région, posée ailleurs qu'au
/// début de la table.**
///
/// `resolve` compare l'adresse aux blocs de la région avant de consulter la
/// correspondance, et l'indice qu'il rend doit être **absolu**. Tant qu'une
/// région vit à l'emplacement zéro, un numéro local et un numéro absolu sont
/// le même nombre : la faute est invisible. À l'emplacement cinq, elle envoie
/// la machine dans la région d'à côté.
///
/// Ce test existe parce qu'un sabotage a survécu à tout le reste — les autres
/// sauts indirects du dépôt visent une *autre* région, jamais la leur.
#[test]
fn an_indirect_jump_back_into_its_own_region_lands_on_the_right_block() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const SLOT: u32 = 5;
    // `incq %rdx` ; `movabs $ici, %rax` ; `jmp *%rax` — la cible est l'entrée
    // de la région elle-même, donc la chaîne de `resolve` doit la trouver.
    let mut code = vec![0x48, 0xff, 0xc2, 0x48, 0xb8];
    code.extend_from_slice(&CODE.to_le_bytes());
    code.extend_from_slice(&[0xff, 0xe0]);
    let module = Module::linked(&code, CODE, 0, SLOT).expect("la région liée");

    let scratch = std::env::temp_dir().join(format!("wisq-self-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let path = scratch.join("m.wasm");
    std::fs::write(&path, &module).expect("le module");
    let driver = scratch.join("d.js");
    std::fs::write(
        &driver,
        format!(
            r#"
const fs = require("fs");
const memory = new WebAssembly.Memory({{ initial: {pages} }});
const blocks = new WebAssembly.Table({{ element: "anyfunc", initial: 16 }});
const slots = [];
const imports = {{ env: {{ mem: memory, out: () => undefined, in: () => 0n, {table}: blocks }} }};
for (let slot = 0; slot < {globals}; slot++) {{
  slots.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
  imports.env["g" + slot] = slots[slot];
}}
const run = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync({path:?})), imports)
  .exports.run;
slots[{rip}].value = {code}n;
run(1000n);
console.log("rdx " + slots[2].value.toString());
"#,
            pages = GUEST_PAGES,
            table = TABLE_IMPORT,
            globals = GLOBAL_COUNT,
            path = path.to_string_lossy(),
            rip = RIP_SLOT,
            code = CODE,
        ),
    )
    .expect("le pilote");
    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let complaint = String::from_utf8_lossy(&output.stderr).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        output.status.success(),
        "le pilote a échoué : {complaint}\n{text}"
    );
    // Mille blocs de budget, un `incq` par bloc : la boucle doit les consommer
    // tous. Un indice relatif enverrait le premier saut ailleurs, et RDX
    // s'arrêterait à un.
    assert_eq!(
        text.trim(),
        "rdx 1000",
        "le saut doit retomber sur le bloc de sa propre région"
    );
}

/// **`0f 0b` est `ud2`, `06` n'est rien.** Le second est `push es`, qui
/// n'existe pas en mode 64 bits : le décodeur le refuse, et c'est un refus
/// franc — aucune quantité d'octets supplémentaires ne le rendrait lisible.
const UNKNOWN: u8 = 0x06;

/// **Une région coupée en plein milieu d'une instruction le dit.**
///
/// `48 b8` suivi de huit octets charge une constante de soixante-quatre bits
/// dans RAX. Coupée à cinq octets, elle ne se décode pas — mais elle se
/// décoderait très bien avec la suite, et c'est toute la différence : la vue
/// doit redemander, pas abandonner.
#[test]
fn a_region_cut_in_the_middle_of_an_instruction_asks_for_more() {
    let whole = [0x48, 0xb8, 1, 2, 3, 4, 5, 6, 7, 8, 0xc3];
    assert!(
        Module::region_or_why(&whole, CODE, 0).is_ok(),
        "entière, la région se traduit"
    );
    assert_eq!(
        Module::region_or_why(&whole[..5], CODE, 0),
        Err(Refused::MayBeCut { at: 0 }),
        "coupée, elle demande davantage d'octets"
    );
}

/// **Une instruction que le décodeur ne connaît pas est un refus franc**, et
/// redemander n'y changerait rien.
#[test]
fn an_instruction_the_decoder_does_not_know_is_a_flat_refusal() {
    let mut bytes = vec![0x90; 4];
    bytes.push(UNKNOWN);
    bytes.extend(std::iter::repeat_n(0x90, 40));
    assert_eq!(
        Module::region_or_why(&bytes, CODE, 0),
        Err(Refused::CannotDecode { at: 4 }),
        "l'octet fautif est nommé, et le refus est franc"
    );
}

/// **Le seuil de quinze octets, tenu des deux côtés.**
///
/// C'est le test qui compte : le même octet inconnu, à la même place, ne rend
/// pas la même réponse selon ce qui le suit. Quinze octets après lui, le
/// décodeur avait toute la place qu'une instruction x86-64 peut demander —
/// donc c'est un vrai refus. Quatorze, et ça pourrait n'être qu'une coupe.
///
/// Sans les deux moitiés, un seuil de zéro ou de mille passerait aussi bien.
#[test]
fn the_edge_is_fifteen_bytes_and_both_sides_are_held() {
    // `restants` compte à partir de l'octet fautif, celui-ci compris : c'est la
    // place dont le décodeur disposait pour lire une instruction entière.
    let region = |restants: usize| {
        let mut bytes = vec![0x90; 3];
        bytes.push(UNKNOWN);
        bytes.extend(std::iter::repeat_n(0x90, restants - 1));
        assert_eq!(bytes.len() - 3, restants, "le montage du cas lui-même");
        Module::region_or_why(&bytes, CODE, 0)
    };
    assert_eq!(
        region(14),
        Err(Refused::MayBeCut { at: 3 }),
        "quatorze octets restants : le décodeur a pu manquer de place"
    );
    assert_eq!(
        region(15),
        Err(Refused::CannotDecode { at: 3 }),
        "quinze restants : il avait toute la place, donc c'est un vrai refus"
    );
}

/// La forme du bureau rend les mêmes raisons, plus la sienne : une RAM qui
/// n'est pas une puissance de deux ne se replie pas par un masque.
#[test]
fn the_desktop_form_says_why_too() {
    let cut = [0x48, 0xb8, 1, 2, 3];
    assert_eq!(
        Module::resolving_or_why(&cut, CODE, 0, 0, 16),
        Err(Refused::MayBeCut { at: 0 })
    );
    let loop_ = [0x48, 0x01, 0xc2, 0x75, 0xfb];
    assert!(Module::resolving_or_why(&loop_, CODE, 0, 0, 16).is_ok());
    assert_eq!(
        Module::resolving_or_why(&loop_, CODE, 0, 0, 3),
        Err(Refused::RamIsNotAPowerOfTwo(3)),
        "trois pages ne se replient pas par un masque"
    );
    assert_eq!(
        Module::resolving_or_why(&loop_, CODE, 0, 0, 0),
        Err(Refused::RamIsNotAPowerOfTwo(0))
    );
}

/// Une entrée hors des octets fournis ne donne aucun bloc, et le dit plutôt
/// que de se faire passer pour un refus de décodage.
#[test]
fn an_entry_that_reaches_nothing_says_so() {
    let bytes = [0x90, 0x90, 0xc3];
    assert_eq!(
        Module::region_or_why(&bytes, CODE, 9),
        Err(Refused::NothingAtEntry)
    );
}

/// **La boucle mémoire du banc touche vraiment la mémoire.**
///
/// Sans ce test, elle serait le même défaut d'un cran au-dessus. `BENCH_LOOP`
/// est cinq instructions de registres, sans un seul accès mémoire, et les bancs
/// s'en sont servis pour chiffrer un émetteur dont tout le surcoût est
/// justement **sur les accès mémoire**. Une seconde boucle qui n'en ferait pas
/// non plus — un encodage mal recopié suffit — rendrait des nombres qu'on
/// croirait comparables.
///
/// Le décodeur est le juge : il dit lesquelles de ces instructions portent un
/// opérande mémoire, et c'est lui qui l'a appris de l'oracle matériel.
#[test]
fn the_memory_bench_loop_really_touches_memory() {
    let mut at = 0usize;
    let mut steps = Vec::new();
    while at < BENCH_MEMORY_LOOP.len() {
        let step = decode(&BENCH_MEMORY_LOOP[at..])
            .unwrap_or_else(|| panic!("l'octet {at} de la boucle mémoire ne se lit pas"));
        at += step.length.max(1);
        steps.push(step);
    }
    assert_eq!(
        steps.len() as u64,
        BENCH_MEMORY_PER_TURN,
        "le compte annoncé par tour ne correspond pas à ce qui se décode"
    );
    let touching = steps.iter().filter(|step| step.memory.is_some()).count() as u64;
    assert_eq!(
        touching, BENCH_MEMORY_ACCESSES_PER_TURN,
        "une boucle de banc « mémoire » sans accès mémoire mesurerait \
         exactement ce que `BENCH_LOOP` mesure déjà"
    );
    // **Une lecture et une écriture**, et pas deux du même côté : `guest()` est
    // traversée par `load_at` et par `store_at`, et rien ne dit que les deux
    // coûtent la même chose.
    assert!(
        steps
            .iter()
            .any(|step| matches!(step.op, Op::Mov) && step.memory.is_some()),
        "il faut au moins un déplacement qui passe par la mémoire"
    );
    // Et le saut ramène bien au début : une boucle qui tomberait droit
    // mesurerait un tour, pas une boucle.
    let last = steps.last().expect("la boucle n'est pas vide");
    assert_eq!(
        BENCH_MEMORY_LOOP.len() as i64 + last.imm as i64,
        0,
        "le déplacement du saut ne revient pas à l'entrée"
    );
}

/// **Et la boucle historique, elle, n'en touche aucune** — ce qui est la moitié
/// qui donne son sens à l'autre.
///
/// C'est le fait qui a rendu tous les chiffres de vitesse incomparables à ce
/// que l'application exécute, et il n'était écrit nulle part. Il l'est ici :
/// si quelqu'un ajoute un accès mémoire à `BENCH_LOOP`, les deux bancs
/// mesureront la même chose et ce test le dira.
#[test]
fn the_historic_bench_loop_touches_no_memory_at_all() {
    let mut at = 0usize;
    let mut touching = 0usize;
    while at < wisq_vm::x86_wasm::BENCH_LOOP.len() {
        let step = decode(&wisq_vm::x86_wasm::BENCH_LOOP[at..]).expect("la boucle du banc se lit");
        at += step.length.max(1);
        touching += usize::from(step.memory.is_some());
    }
    assert_eq!(
        touching, 0,
        "`BENCH_LOOP` sans accès mémoire est ce qui justifie l'existence de \
         `BENCH_MEMORY_LOOP` : si elle en gagne un, les deux bancs se confondent"
    );
}

/// **Les deux *mises en forme*, elles, divergent — et il faut le savoir.**
///
/// Rien n'oblige la forme libre et la forme confinée à accepter les mêmes
/// régions, et depuis la pagination elles ne le font plus : la marche dans les
/// tables n'existe que sous confinement, donc l'écriture de `cr3` qui la
/// pilote n'y est acceptée que là. Le nier serait une hypothèse ; ce test en
/// fait un fait, parce que **trois outils de mesure ont publié pendant une
/// tranche des chiffres pris sur la forme libre en les présentant comme ceux
/// de l'application**, qui n'exécute que la confinée.
///
/// Les deux moitiés comptent. Sans la seconde, un émetteur qui refuserait
/// *toute* écriture de registre de contrôle passerait le test.
#[test]
fn only_the_confined_form_accepts_the_write_that_drives_paging() {
    // `mov %rax,%cr3` puis `ret`.
    let paging = [0x0f, 0x22, 0xd8, 0xc3];
    assert!(
        matches!(
            Module::region_or_why(&paging, CODE, 0),
            Err(Refused::CannotTranslate { at: 0 })
        ),
        "la forme libre n'a pas de tables où marcher : elle doit refuser `mov %rax,%cr3`, \
         et le refuser à l'octet zéro"
    );
    assert!(
        Module::resolving_or_why(&paging, CODE, 0, 0, 16).is_ok(),
        "la forme confinée porte la marche : elle doit accepter `mov %rax,%cr3`"
    );

    // `mov %rax,%cr4` puis `ret` : accepté des deux côtés depuis toujours, il
    // ne pilote aucune traduction.
    let flags = [0x0f, 0x22, 0xe0, 0xc3];
    assert!(
        Module::region_or_why(&flags, CODE, 0).is_ok(),
        "la forme libre accepte `cr4`, et le refus ci-dessus porte donc bien sur `cr3` \
         et non sur la famille entière"
    );
}

/// **Les deux formes ne peuvent pas diverger** : celle qui rend un `Option` est
/// celle qui explique, avec la raison jetée. Deux implémentations séparées
/// finiraient par ne plus refuser les mêmes régions.
#[test]
fn the_short_form_refuses_exactly_what_the_explaining_one_refuses() {
    let cases: [&[u8]; 5] = [
        &[0x48, 0x01, 0xc2, 0x75, 0xfb],
        &[0x48, 0xb8, 1, 2, 3],
        &[UNKNOWN],
        &[0x90, 0x90, 0xc3],
        &[],
    ];
    for bytes in cases {
        assert_eq!(
            Module::region(bytes, CODE, 0).is_some(),
            Module::region_or_why(bytes, CODE, 0).is_ok(),
            "{bytes:02x?}"
        );
        assert_eq!(
            Module::resolving(bytes, CODE, 0, 0, 16).is_some(),
            Module::resolving_or_why(bytes, CODE, 0, 0, 16).is_ok(),
            "{bytes:02x?}"
        );
    }
}

/// **Ce qu'un module importe, et ce que ses pilotes lui donnent.**
///
/// L'argument écrit en tête de ce fichier — « la répétition est comparée par le
/// moteur lui-même, un pilote incomplet refuserait bruyamment » — est vrai et
/// il n'a pas suffi. Il suppose que quelqu'un **entende** le bruit. Trois
/// pilotes, `examples/speed.rs`, `examples/chain.rs` et `examples/resolved.rs`,
/// ont refusé bruyamment pendant toute une tranche : personne ne les lance en
/// intégration continue, et `speed.rs` traduisait même le refus en « Bun est
/// absent » alors que Bun avait répondu.
///
/// Ce test entend à leur place. **Les noms viennent du module**, lus dans sa
/// section d'import : ajouter une troisième fonction hôte fera tomber ce test
/// sur les pilotes qui ne la portent pas, sans qu'on ait à penser à eux.
///
/// Ce qu'il ne couvre pas, et pourquoi : `web/host.js` et la sonde de
/// l'iPhone construisent leur `env` autrement — par affectations successives —
/// et ce sont les chemins que l'application emprunte vraiment. Un manque là se
/// verrait au premier lancement ; ici, il ne se voyait nulle part.
///
/// **Et une phrase de ce commentaire est devenue fausse**, ce qui a coûté une
/// série de tranches. « La mémoire, la table et les globales — un pilote les
/// fournit par construction » supposait qu'un pilote qui les fournit les
/// fournit *assez grandes*. La pagination l'a démenti : un module confiné
/// réclame une page de tampon en plus, et `examples/resolved.rs` la fournissait
/// trop petite. Ce n'est plus tenu par une hypothèse mais par
/// `a_confined_module_asks_for_exactly_what_host_pages_says` et
/// `no_host_adds_up_the_pages_itself`, juste en dessous.
#[test]
fn every_driver_supplies_the_functions_a_module_imports() {
    let module =
        Module::region(&wisq_vm::x86_wasm::BENCH_LOOP, CODE, 0).expect("la boucle du banc");
    let wanted = function_imports(&module);
    assert!(
        !wanted.is_empty(),
        "un module sans import de fonction rendrait ce test creux"
    );

    for relative in [
        "crates/wisq-vm/examples/speed.rs",
        "crates/wisq-vm/examples/chain.rs",
        "crates/wisq-vm/examples/resolved.rs",
        "crates/wisq-vm/tests/x86_wasm.rs",
    ] {
        let text = std::fs::read_to_string(workspace_root().join(relative))
            .unwrap_or_else(|_| panic!("{relative}"));
        // La fenêtre s'arrête à la première accolade fermante, ce qui suppose
        // que les fonctions rendues n'en ouvrent aucune — d'où
        // `() => undefined` plutôt que `() => {}`.
        let mut seen = 0;
        for (at, _) in text.match_indices("env: {") {
            let rest = &text[at..];
            let stop = rest.find('}').unwrap_or(rest.len());
            let object = &rest[..stop];
            // **Un objet qui en étale un autre hérite de ses fonctions.** Il en
            // existe deux, qui remplacent la mémoire ou ajoutent la table sans
            // toucher au reste. Celui dont ils héritent est vérifié, lui.
            if object.contains("...") {
                continue;
            }
            // **Et ce test se cite lui-même.** Le motif qu'il cherche apparaît
            // dans son propre code, quelques lignes plus haut. Un `env` de
            // pilote porte toujours la mémoire de l'invité ; cette citation,
            // non.
            if !object.contains("mem") {
                continue;
            }
            for name in &wanted {
                assert!(
                    object.contains(&format!("{name}:")),
                    "{relative} construit un `env` sans « {name} » : \
                     le module l'importe, et l'instanciation le refusera\n  {object}"
                );
            }
            seen += 1;
        }
        assert!(
            seen > 0,
            "{relative} ne construit aucun `env` — ce test le croit vérifié \
             alors qu'il ne l'a pas regardé"
        );
    }
}

/// **Ce qu'un module déclare comme mémoire minimale, et ce que les hôtes lui
/// donnent.**
///
/// Le test voisin vérifie les **fonctions** importées, et son propre
/// commentaire écarte « la mémoire, la table et les globales » au motif qu'un
/// pilote les fournit par construction. C'était vrai, et la pagination l'a
/// rendu faux : depuis qu'un module confiné réclame une page de tampon en
/// plus, un hôte peut fournir la mémoire *et* se faire refuser sur sa taille.
///
/// C'est arrivé. `examples/resolved.rs` allouait `pages + TABLE_PAGES`,
/// échouait à l'instanciation avec `LinkError`, imprimait « le pilote a
/// échoué » et **sortait avec zéro**. Rien ne le lançait, rien ne l'entendait.
///
/// **Ce test tient les deux bouts** : le nombre que le module grave dans ses
/// octets, et `host_pages`, la fonction que les hôtes appellent. Les faire
/// diverger casse ici, pas six tranches plus tard sur un pilote que personne
/// ne lance.
#[test]
fn a_confined_module_asks_for_exactly_what_host_pages_says() {
    let code = [0x48, 0xff, 0xc2, 0xc3]; // incq %rdx ; ret
    for pages in [1u32, 16, 1024, 0x4000] {
        let confined = Module::confined(&code, CODE, 0, pages).expect("la forme confinée");
        assert_eq!(
            memory_minimum(&confined),
            u64::from(host_pages(pages)),
            "la forme confinée à {pages} pages"
        );
        // **Et le même nombre par un autre chemin.** `host_pages` seul serait
        // creux : le module tire son minimum de cette fonction, donc les deux
        // côtés bougeraient ensemble. Celui-ci vient de `tlb_base`, la
        // fonction que l'hôte emploie pour **placer** le tampon : le minimum
        // doit couvrir le sommet de ce tampon, sinon l'hôte écrirait au-delà
        // de ce que le module déclare. Deux dérivations qui ne partagent que
        // les constantes.
        assert_eq!(
            memory_minimum(&confined),
            u64::from(tlb_base(pages) / 65536 + TLB_PAGES),
            "le minimum déclaré ne couvre pas le sommet du tampon, à {pages} pages"
        );
        let resolving = Module::resolving(&code, CODE, 0, 0, pages).expect("la forme résolvante");
        assert_eq!(
            memory_minimum(&resolving),
            u64::from(host_pages(pages)),
            "la forme résolvante à {pages} pages"
        );
    }
    // **Et la forme libre ne suit pas la même règle**, exprès : sans masque le
    // module adresse toute la RAM du corpus. Sans cette moitié, un émetteur qui
    // déclarerait `host_pages` partout passerait le test.
    let free = Module::region(&code, CODE, 0).expect("la forme libre");
    assert_eq!(memory_minimum(&free), u64::from(GUEST_PAGES));
}

/// **Aucun hôte n'a le droit de refaire la somme lui-même.**
///
/// C'est la garde qui manquait, et elle porte sur le *texte* parce que le
/// défaut était dans le texte : cinq pilotes écrivaient chacun leur addition,
/// et l'un d'eux ne l'a pas mise à jour. Un hôte qui instancie un module
/// confiné doit interpoler **une** valeur, venue de `host_pages` ; une
/// addition dans la ligne `WebAssembly.Memory` est refusée ici.
///
/// **Les modules libres sont hors de portée de cette règle**, et c'est pour ça
/// que le motif cherché est l'addition, pas la fonction : un pilote qui émet
/// `Module::region` demande `GUEST_PAGES`, une valeur seule, et passe.
#[test]
fn no_host_adds_up_the_pages_itself() {
    for relative in [
        "crates/wisq-vm/examples/speed.rs",
        "crates/wisq-vm/examples/chain.rs",
        "crates/wisq-vm/examples/resolved.rs",
        "crates/wisq-vm/examples/kernel-entry.rs",
        "crates/wisq-vm/tests/x86_wasm.rs",
        "crates/wisq-vm/tests/host_loop.rs",
        // **Et l'hôte que l'application exécute vraiment.** Il ne peut pas
        // appeler `host_pages` — c'est du JavaScript — mais il porte le même
        // pendant, et la règle vaut pour lui comme pour les autres. Il est
        // même celui pour qui elle compte le plus.
        "web/host.js",
    ] {
        let text = std::fs::read_to_string(workspace_root().join(relative))
            .unwrap_or_else(|_| panic!("{relative}"));
        for (at, _) in text.match_indices("WebAssembly.Memory({") {
            let rest = &text[at..];
            let stop = rest.find("})").map_or(rest.len(), |end| end + 2);
            let line = &rest[..stop];
            // Ce test se cite lui-même : sa propre phrase porte le motif.
            if line.contains("host_pages") || line.contains("hostPages") {
                continue;
            }
            assert!(
                !line.contains('+'),
                "{relative} additionne les pages sur place :
  {line}
                 un hôte de module confiné interpole `host_pages(pages)`,                  une valeur et pas une somme — c'est l'oubli qui a laissé                  `resolved.rs` cassé pendant toute une série"
            );
        }
    }
}

/// Le minimum de mémoire qu'un module déclare, lu dans sa section d'import.
fn memory_minimum(module: &[u8]) -> u64 {
    let mut at = 8;
    while at < module.len() {
        let id = module[at];
        at += 1;
        let (size, read) = unsigned_at(module, at);
        at += read;
        let end = at + size as usize;
        if id != 2 {
            at = end;
            continue;
        }
        let (count, read) = unsigned_at(module, at);
        at += read;
        for _ in 0..count {
            for _ in 0..2 {
                let (length, read) = unsigned_at(module, at);
                at += read + length as usize;
            }
            let kind = module[at];
            at += 1;
            match kind {
                0x00 => {
                    let (_, read) = unsigned_at(module, at);
                    at += read;
                }
                0x01 => at += 1 + skip_limits(module, at + 1),
                // La mémoire : ses bornes commencent par un drapeau, puis le
                // minimum. C'est lui qu'on cherche.
                0x02 => {
                    let (least, _) = unsigned_at(module, at + 1);
                    return least;
                }
                0x03 => at += 2,
                other => panic!("sorte d'import inconnue : {other}"),
            }
        }
        break;
    }
    panic!("le module n'importe aucune mémoire");
}

/// Les noms des fonctions qu'un module importe, lus dans sa section d'import.
///
/// La mémoire, la table et les globales sont écartées : elles s'importent
/// aussi, mais un pilote les fournit par construction — c'est la fonction
/// oubliée qui a coûté une tranche.
fn function_imports(module: &[u8]) -> Vec<String> {
    let mut at = 8; // l'en-tête : « \0asm » et la version
    while at < module.len() {
        let id = module[at];
        at += 1;
        let (size, read) = unsigned_at(module, at);
        at += read;
        let end = at + size as usize;
        if id != 2 {
            at = end;
            continue;
        }
        let (count, read) = unsigned_at(module, at);
        at += read;
        let mut names = Vec::new();
        for _ in 0..count {
            // Le nom du module, puis celui du champ. C'est le second qu'on garde.
            let mut field = String::new();
            for which in 0..2 {
                let (length, read) = unsigned_at(module, at);
                at += read;
                if which == 1 {
                    field = String::from_utf8_lossy(&module[at..at + length as usize]).into_owned();
                }
                at += length as usize;
            }
            let kind = module[at];
            at += 1;
            match kind {
                // fonction : l'indice de son type
                0x00 => {
                    let (_, read) = unsigned_at(module, at);
                    at += read;
                    names.push(field);
                }
                // table : le type d'élément, puis les bornes
                0x01 => at += 1 + skip_limits(module, at + 1),
                // mémoire : les bornes seules
                0x02 => at += skip_limits(module, at),
                // globale : le type, puis la mutabilité
                0x03 => at += 2,
                other => panic!("sorte d'import inconnue : {other}"),
            }
        }
        return names;
    }
    Vec::new()
}

fn unsigned_at(bytes: &[u8], mut at: usize) -> (u64, usize) {
    let (mut value, mut shift, mut read) = (0u64, 0u32, 0usize);
    loop {
        let byte = bytes[at];
        value |= u64::from(byte & 0x7f) << shift;
        shift += 7;
        at += 1;
        read += 1;
        if byte & 0x80 == 0 {
            return (value, read);
        }
    }
}

fn skip_limits(bytes: &[u8], at: usize) -> usize {
    let flags = bytes[at];
    let (_, read) = unsigned_at(bytes, at + 1);
    let mut total = 1 + read;
    if flags & 0x01 != 0 {
        let (_, more) = unsigned_at(bytes, at + total);
        total += more;
    }
    total
}

/// **Le repli sur la RAM déclarée, une seule règle.**
///
/// L'invité tient des adresses que la mémoire linéaire du module ne porte pas
/// telles quelles : le noyau bascule à l'adressage virtuel en cours de
/// démarrage et réclame `0xffffffff8100013e` alors que ses octets sont à
/// `0x100013e`. C'est le confinement qui les relie — `web/host.js` lit ses
/// octets à `address & (base - 1)` — et cette règle était réécrite à chaque
/// endroit qui en avait besoin. `--example kernel-entry` en avait deux : une
/// qui repliait, une qui soustrayait à cru. La seconde **paniquait** sur une
/// adresse virtuelle, « range start index 18446744071564165438 out of range »,
/// dès que la première laissait passer une région virtuelle.
#[test]
fn a_folded_address_always_lands_inside_the_declared_ram() {
    // La vraie mesure : l'adresse virtuelle où Alpine bascule, et l'adresse
    // physique où ses octets vivent, sur les 64 Mio que déclare l'outil.
    const PAGES: u32 = 1024;
    assert_eq!(
        Module::fold(0xffff_ffff_8100_013e, PAGES),
        0x0100_013e,
        "l'adresse virtuelle du noyau retombe sur ses octets"
    );
    // Une adresse déjà physique ne bouge pas : le repli n'est pas une
    // conversion, c'est une projection.
    assert_eq!(Module::fold(0x0100_013e, PAGES), 0x0100_013e);

    // **La propriété qui rend l'indexation sûre**, et c'est elle qui remplace
    // la panique : quoi qu'on donne, le résultat est dans la RAM déclarée.
    let ram = u64::from(PAGES) * 65536;
    for address in [
        0,
        u64::MAX,
        ram,
        ram - 1,
        0xffff_ffff_8100_0000,
        0x8000_0000_0000_0000,
    ] {
        assert!(
            Module::fold(address, PAGES) < ram,
            "0x{address:x} replié sort de la RAM"
        );
    }

    // Une seule page, pour que la borne ne soit pas tenue par la seule taille
    // choisie par l'outil.
    assert!(Module::fold(u64::MAX, 1) < 65536);
    assert_eq!(Module::fold(0x1_0000, 1), 0);
}
