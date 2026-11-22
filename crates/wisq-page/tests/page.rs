//! **L'émetteur de la page, jugé sous le moteur de la page.**
//!
//! `crates/wisq-page` compile l'émetteur en WebAssembly ; `web/page-emitter.js`
//! le charge et le sert à la boucle hôte. Ce qui doit être vrai, et que ces
//! tests tiennent : **pour chaque fenêtre, la porte wasm rend les mêmes
//! octets que `Module::resolving_or_why` en natif**, au même octet, et refuse
//! là où il refuse, pour la même raison.
//!
//! Ce n'est pas acquis. L'émetteur compilé pour `wasm32` n'est pas le même
//! programme que celui de l'application : `usize` y fait 32 bits, l'allocateur
//! est un autre, et une arithmétique qui déborderait sur une adresse du noyau
//! (au-dessus de 2⁶³) donnerait un module valide qui saute ailleurs. La carte
//! du 14 novembre le disait : son banc comptait les régions traduites et leur
//! taille, il ne comparait pas les octets.
//!
//! **Le texte jugé** est celui de `Tests/Fixtures/x86-corpus.tsv` : neuf mille
//! vraies instructions x86-64 relevées par `objdump` dans de vrais binaires,
//! posées bout à bout à l'adresse où un noyau lie son texte. Ce n'est pas un
//! programme, mais chaque fenêtre y commence sur une vraie instruction et en
//! enchaîne des centaines d'autres, sauts et appels compris. **Un vrai noyau
//! s'ajoute** quand on le donne : `WISQ_PAGE_NOYAU=<vmlinux>` et
//! `WISQ_PAGE_CARTE=<System.map>` prennent des fenêtres aux entrées de ses
//! fonctions (`WISQ_PAGE_FENETRES`, deux mille par défaut). Aucun noyau n'est
//! dans le dépôt, donc la CI ne juge que le premier.
//!
//! **La mesure vient avec**, parce qu'elle est le but : le pilote chronomètre
//! chaque traduction par la porte, et, sous `WISQ_PAGE_BANC=1`, la même
//! traduction par `x86-translate` lancé en `Bun.spawnSync` — ce que
//! `examples/kernel-entry.rs` payait par région jusqu'ici. Les deux chiffres
//! s'impriment (`cargo test -p wisq-page -- --nocapture`).
//!
//! Sans Bun, ou sans la cible `wasm32-unknown-unknown`, les tests **tombent**
//! plutôt que de passer en silence : un module que rien n'exécute n'est pas un
//! module vérifié.

use std::path::{Path, PathBuf};
use std::process::Command;

use wisq_vm::x86_wasm::{Module, Refused, RIP_SLOT};

fn workspace_root() -> PathBuf {
    let mut at = Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf();
    while !at.join("Cargo.lock").exists() {
        at = at.parent().expect("la racine du dépôt").to_path_buf();
    }
    at
}

fn bun() -> PathBuf {
    ["/root/.bun/bin/bun", "bun"]
        .into_iter()
        .map(PathBuf::from)
        .find(|path| Command::new(path).arg("--version").output().is_ok())
        .unwrap_or_else(|| {
            panic!("Bun est absent : la porte de la page ne serait vérifiée par rien.")
        })
}

/// **Le module de la page, construit par le script que tout le monde lance.**
/// Le test ne recopie pas la commande cargo : s'il la recopiait, il pourrait
/// juger un module que personne d'autre ne construit ainsi.
fn page_module() -> PathBuf {
    let root = workspace_root();
    let output = Command::new("bash")
        .arg(root.join("scripts/build-page-emitter.sh"))
        .arg(&root)
        .output()
        .expect("le script de construction doit démarrer");
    assert!(
        output.status.success(),
        "l'émetteur de la page ne se construit pas :\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let path = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
    assert!(
        path.exists(),
        "le script a nommé {path:?}, qui n'existe pas"
    );
    path
}

/// Un dossier de travail par test et par processus : `cargo test` lance les
/// tests en parallèle, et deux pilotes qui s'écriraient dessus se jugeraient
/// l'un l'autre.
fn scratch(name: &str) -> PathBuf {
    let at = std::env::temp_dir().join(format!("wisq-page-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&at);
    std::fs::create_dir_all(&at).expect("dossier de travail");
    at
}

/// Où un noyau x86-64 lie son texte : `__START_KERNEL_map` + 16 Mio. Une
/// adresse au-dessus de 2⁶³, exprès — c'est elle qui passe la frontière entre
/// `BigInt` et `i64`, et l'arithmétique 32 bits de `wasm32`.
const TEXT_BASE: u64 = 0xffff_ffff_8100_0000;

/// **Une fenêtre à juger** : un morceau du texte, l'adresse de son premier
/// octet, et les deux autres arguments de la traduction.
struct Window {
    from: usize,
    length: usize,
    base: u64,
    slot: u32,
    pages: u32,
}

/// Le texte du corpus : les octets de chaque ligne, bout à bout, et l'indice
/// où chaque instruction commence.
fn corpus_text() -> (Vec<u8>, Vec<usize>) {
    let fixture = std::fs::read_to_string(workspace_root().join("Tests/Fixtures/x86-corpus.tsv"))
        .expect("le corpus");
    let mut text = Vec::new();
    let mut starts = Vec::new();
    for line in fixture.lines().filter(|line| !line.starts_with('#')) {
        let Some(hex) = line.split('\t').next().filter(|hex| !hex.is_empty()) else {
            continue;
        };
        starts.push(text.len());
        for pair in hex.as_bytes().chunks(2) {
            let pair = std::str::from_utf8(pair).expect("de l'ASCII");
            text.push(u8::from_str_radix(pair, 16).expect("de l'hexadécimal"));
        }
    }
    (text, starts)
}

/// Les fenêtres du corpus : une toutes les cinq instructions, de 4 Kio sauf
/// une sur sept de 16 Kio (les deux tailles que la boucle hôte demande), sur
/// des emplacements et des RAM qui changent. **Une RAM sur trente et une n'est
/// pas une puissance de deux**, pour juger aussi le refus franc. **Une sur
/// onze s'arrête au milieu de sa première instruction**, quand elle en a plus
/// d'un octet : c'est la coupe que la boucle hôte redemande plus large.
fn corpus_windows(text: &[u8], starts: &[usize]) -> Vec<Window> {
    starts
        .iter()
        .enumerate()
        .step_by(5)
        .enumerate()
        .map(|(rank, (index, &from))| {
            let first = starts.get(index + 1).copied().unwrap_or(text.len()) - from;
            let wanted = match rank % 11 {
                5 if first > 1 => first - 1,
                _ if rank % 7 == 3 => 16384,
                _ => 4096,
            };
            Window {
                from,
                length: wanted.min(text.len() - from),
                base: TEXT_BASE + from as u64,
                slot: (rank as u32 * 37) % 20_000,
                pages: match rank % 31 {
                    30 => 3,
                    n if n % 2 == 0 => 1024,
                    _ => 16384,
                },
            }
        })
        .collect()
}

/// **Les fenêtres d'un vrai noyau**, si on en donne un : aux entrées de ses
/// fonctions de texte, prises régulièrement, lues dans le fichier ELF.
fn kernel_windows() -> Option<(Vec<u8>, Vec<Window>)> {
    let image = std::env::var_os("WISQ_PAGE_NOYAU")?;
    let map = std::env::var_os("WISQ_PAGE_CARTE")
        .expect("WISQ_PAGE_NOYAU demande sa carte : WISQ_PAGE_CARTE=<System.map>");
    let wanted: usize = std::env::var("WISQ_PAGE_FENETRES")
        .ok()
        .map(|value| value.parse().expect("WISQ_PAGE_FENETRES est un nombre"))
        .unwrap_or(2000);
    let bytes = std::fs::read(&image).expect("le noyau");
    let (_, loads) = wisq_vm::kernel_image::loads(&bytes).expect("un ELF64");
    let map = std::fs::read_to_string(&map).expect("la carte");
    let (mut stext, mut etext) = (None, None);
    let mut entries = Vec::new();
    for line in map.lines() {
        let mut fields = line.split_whitespace();
        let (Some(hex), Some(kind), Some(name)) = (fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        let Ok(address) = u64::from_str_radix(hex, 16) else {
            continue;
        };
        match name {
            "_stext" => stext = Some(address),
            "_etext" => etext = Some(address),
            _ => {}
        }
        if kind == "T" || kind == "t" {
            entries.push(address);
        }
    }
    let (stext, etext) = (stext.expect("_stext"), etext.expect("_etext"));
    entries.retain(|&address| address >= stext && address < etext);
    entries.sort_unstable();
    entries.dedup();
    let step = (entries.len() / wanted).max(1);
    let windows = entries
        .iter()
        .step_by(step)
        .take(wanted)
        .filter_map(|&address| {
            let load = loads.iter().find(|load| {
                address >= load.virtual_address && address - load.virtual_address < load.file_size
            })?;
            let delta = address - load.virtual_address;
            let from = (load.offset + delta) as usize;
            Some(Window {
                from,
                length: 4096.min((load.file_size - delta) as usize),
                base: address,
                slot: 0,
                // 64 Mio, la RAM que `kernel-entry` déclare par défaut.
                pages: 1024,
            })
        })
        .collect();
    Some((bytes, windows))
}

/// Ce que la porte a rendu pour une fenêtre : son code, et ses octets.
struct Answer {
    code: i32,
    bytes: Vec<u8>,
}

/// Ce que le pilote a mesuré, tel qu'il l'imprime.
struct Run {
    answers: Vec<Answer>,
    summary: String,
}

/// **Le pilote** : charge le module de la page par `web/page-emitter.js`,
/// traduit chaque fenêtre, écrit les réponses, et chronomètre. Sous
/// `WISQ_PAGE_BANC=1`, il refait chaque traduction par `x86-translate`, et
/// vérifie au passage que ce dernier rend les mêmes octets.
const DRIVER: &str = r#"
import { readFileSync, writeFileSync } from "fs";
import { emetteur } from "__EMITTER__";

const [modulePath, textPath, tablePath, outPath, translator] = process.argv.slice(2);
const t0 = performance.now();
const porte = emetteur(new WebAssembly.Module(readFileSync(modulePath)));
const tCharge = performance.now() - t0;
const text = new Uint8Array(readFileSync(textPath));
const table = new DataView(readFileSync(tablePath).buffer);
const count = table.byteLength / 24;
const chunks = [];
let total = 0;
let tPorte = 0;
let tProcessus = 0;
let divergences = 0;
for (let i = 0; i < count; i++) {
  const at = i * 24;
  const from = table.getUint32(at, true);
  const length = table.getUint32(at + 4, true);
  const base = table.getBigUint64(at + 8, true);
  const slot = table.getUint32(at + 16, true);
  const pages = table.getUint32(at + 20, true);
  const fenetre = text.subarray(from, from + length);
  const t1 = performance.now();
  const rendu = porte.resoudre(fenetre, base, slot, pages);
  tPorte += performance.now() - t1;
  let code, octets;
  if (rendu.module !== undefined) { code = rendu.module.length; octets = rendu.module; }
  else if (rendu.encore !== undefined) { code = -1; octets = new TextEncoder().encode(rendu.encore); }
  else { code = -2; octets = new TextEncoder().encode(rendu.refus); }
  if (translator) {
    // **Ce que `kernel-entry` faisait par région**, à l'identique : un
    // processus, la fenêtre sur l'entrée standard, le module sur la sortie.
    const t2 = performance.now();
    const out = Bun.spawnSync({
      cmd: [translator, String(pages), base.toString(), String(slot)],
      stdin: fenetre,
    });
    tProcessus += performance.now() - t2;
    const lui = out.exitCode === 0 ? new Uint8Array(out.stdout) : null;
    const moi = code >= 0 ? octets : null;
    const memes = lui === null || moi === null
      ? lui === moi
      : lui.length === moi.length && lui.every((o, k) => o === moi[k]);
    if (!memes) divergences++;
  }
  const head = new DataView(new ArrayBuffer(8));
  head.setInt32(0, code, true);
  head.setUint32(4, octets.length, true);
  chunks.push(new Uint8Array(head.buffer), octets);
  total += 8 + octets.length;
}
const out = new Uint8Array(total);
let put = 0;
for (const chunk of chunks) { out.set(chunk, put); put += chunk.length; }
writeFileSync(outPath, out);
console.log("fenetres " + count);
console.log("chargement_ms " + tCharge.toFixed(2));
console.log("porte_ms_par_region " + (tPorte / count).toFixed(4));
console.log("memoire_emetteur_Mio " + (porte.memoire / 1048576).toFixed(1));
if (translator) {
  console.log("processus_ms_par_region " + (tProcessus / count).toFixed(4));
  console.log("divergences_processus " + divergences);
}
"#;

/// Faire passer `windows` (prises dans `text`) par la porte wasm, sous Bun.
fn through_the_page(name: &str, text: &[u8], windows: &[Window]) -> Run {
    let bun = bun();
    let module = page_module();
    let root = workspace_root();
    let work = scratch(name);
    let mut table = Vec::with_capacity(windows.len() * 24);
    for window in windows {
        table.extend_from_slice(&(window.from as u32).to_le_bytes());
        table.extend_from_slice(&(window.length as u32).to_le_bytes());
        table.extend_from_slice(&window.base.to_le_bytes());
        table.extend_from_slice(&window.slot.to_le_bytes());
        table.extend_from_slice(&window.pages.to_le_bytes());
    }
    std::fs::write(work.join("text.bin"), text).expect("le texte");
    std::fs::write(work.join("table.bin"), &table).expect("la table");
    let driver = work.join("d.mjs");
    std::fs::write(
        &driver,
        DRIVER.replace(
            "__EMITTER__",
            &root.join("web/page-emitter.js").to_string_lossy(),
        ),
    )
    .expect("le pilote");
    let mut command = Command::new(&bun);
    command
        .arg("run")
        .arg(&driver)
        .arg(&module)
        .arg(work.join("text.bin"))
        .arg(work.join("table.bin"))
        .arg(work.join("out.bin"));
    if std::env::var("WISQ_PAGE_BANC").is_ok_and(|value| value != "0") {
        let translator = root.join("target/release/x86-translate");
        assert!(
            translator.exists(),
            "WISQ_PAGE_BANC compare à `x86-translate`, qui n'est pas construit : \
             cargo build --release -p wisq-vm --bin x86-translate"
        );
        command.arg(translator);
    }
    let output = command.output().expect("bun doit démarrer");
    let summary = String::from_utf8_lossy(&output.stdout).to_string();
    assert!(
        output.status.success(),
        "le pilote a échoué :\n{}\n{summary}",
        String::from_utf8_lossy(&output.stderr)
    );
    let raw = std::fs::read(work.join("out.bin")).expect("les réponses");
    let _ = std::fs::remove_dir_all(&work);
    let mut answers = Vec::with_capacity(windows.len());
    let mut at = 0;
    while at < raw.len() {
        let code = i32::from_le_bytes(raw[at..at + 4].try_into().expect("4 octets"));
        let length = u32::from_le_bytes(raw[at + 4..at + 8].try_into().expect("4 octets")) as usize;
        answers.push(Answer {
            code,
            bytes: raw[at + 8..at + 8 + length].to_vec(),
        });
        at += 8 + length;
    }
    assert_eq!(answers.len(), windows.len(), "une réponse par fenêtre");
    Run { answers, summary }
}

/// Ce que les deux côtés ont fait, compté.
#[derive(Default, Debug)]
struct Tally {
    translated: usize,
    more: usize,
    refused: usize,
}

/// **La comparaison**, fenêtre par fenêtre. Un module doit être identique au
/// natif ; un refus doit être de la même espèce et dire la même raison.
fn judge(text: &[u8], windows: &[Window], run: &Run) -> Tally {
    let mut tally = Tally::default();
    for (window, answer) in windows.iter().zip(&run.answers) {
        let bytes = &text[window.from..window.from + window.length];
        let native = Module::resolving_or_why(bytes, window.base, 0, window.slot, window.pages);
        let place = format!(
            "0x{:x} (emplacement {}, {} pages, {} octets)",
            window.base, window.slot, window.pages, window.length
        );
        match native {
            Ok(module) => {
                assert_eq!(
                    answer.code,
                    module.len() as i32,
                    "à {place}, le natif traduit et la page rend le code {} : {}",
                    answer.code,
                    String::from_utf8_lossy(&answer.bytes)
                );
                // `assert!` plutôt que `assert_eq!` : imprimer deux modules de
                // treize kibioctets noierait l'adresse qui compte.
                assert!(
                    answer.bytes == module,
                    "à {place}, la page rend un autre module que le natif \
                     (premier octet qui diffère : {:?})",
                    answer.bytes.iter().zip(&module).position(|(a, b)| a != b)
                );
                tally.translated += 1;
            }
            Err(why) => {
                let expected = if matches!(why, Refused::MayBeCut { .. }) {
                    tally.more += 1;
                    wisq_page::ENCORE
                } else {
                    tally.refused += 1;
                    wisq_page::REFUS
                };
                assert_eq!(
                    answer.code, expected,
                    "à {place}, le natif refuse : {why:?}"
                );
                assert_eq!(
                    String::from_utf8_lossy(&answer.bytes),
                    format!("{why:?}"),
                    "à {place}, la raison du refus"
                );
            }
        }
    }
    tally
}

#[test]
fn the_page_emitter_returns_the_native_modules_byte_for_byte() {
    let (text, starts) = corpus_text();
    let windows = corpus_windows(&text, &starts);
    let run = through_the_page("corpus", &text, &windows);
    let tally = judge(&text, &windows, &run);
    println!("corpus : {tally:?}\n{}", run.summary);
    // **Le juge doit avoir eu de quoi juger**, dans les trois cas. Une
    // comparaison où tout serait refusé passerait en ne comparant que des
    // messages ; une où rien ne le serait ne jugerait pas le classement.
    //
    // **Un tiers, pas la moitié** : le corpus porte un représentant de chaque
    // forme, SSE et AVX comprises, que l'émetteur refuse encore. Mesuré le
    // 14 novembre : 888 traduites, 163 coupées, 794 refusées sur 1 845.
    assert!(
        tally.translated * 3 > windows.len(),
        "moins d'une fenêtre sur trois traduite : {tally:?}"
    );
    assert!(tally.more > 0, "aucune coupe jugée : {tally:?}");
    assert!(tally.refused > 0, "aucun refus franc jugé : {tally:?}");
    if run.summary.contains("divergences_processus") {
        assert!(
            run.summary.contains("divergences_processus 0"),
            "`x86-translate` et la page ne rendent pas les mêmes modules :\n{}",
            run.summary
        );
    }

    if let Some((image, windows)) = kernel_windows() {
        let run = through_the_page("noyau", &image, &windows);
        let tally = judge(&image, &windows, &run);
        println!("noyau : {tally:?}\n{}", run.summary);
        assert!(tally.translated > 0, "aucune fenêtre du noyau traduite");
        if run.summary.contains("divergences_processus") {
            assert!(
                run.summary.contains("divergences_processus 0"),
                "{}",
                run.summary
            );
        }
    }
}

/// **Les codes du JavaScript sont ceux du Rust.** `web/page-emitter.js` les
/// recopie, faute de pouvoir les importer ; une recopie que rien ne compare
/// finit par mentir.
#[test]
fn the_javascript_side_repeats_the_gates_codes_and_they_still_agree() {
    let text =
        std::fs::read_to_string(workspace_root().join("web/page-emitter.js")).expect("le fichier");
    let line = text
        .lines()
        .find(|line| line.contains("export const CODES"))
        .expect("page-emitter.js déclare CODES");
    for (name, value) in [
        ("encore", wisq_page::ENCORE),
        ("refus", wisq_page::REFUS),
        ("malForme", wisq_page::MAL_FORME),
    ] {
        assert!(
            line.contains(&format!("{name}: {value}")),
            "« {name} » ne vaut plus {value} dans « {line} »"
        );
    }
}

/// **La boucle hôte, inchangée, avec le traducteur de la page.**
///
/// `web/host.js` reçoit son traducteur en paramètre de `machine()` ; ce test
/// lui donne celui de `page-emitter.js` et rien d'autre — aucun module
/// préparé d'avance, aucun catalogue. Trois maillons en anneau, découverts un
/// par un et traduits dans le moteur au moment où la machine y arrive, puis un
/// long régime établi : RDX doit porter la somme de tous les tours. C'est le
/// pendant de `the_view_discovers_regions_as_it_reaches_them_and_keeps_the_machine`
/// (`crates/wisq-vm/tests/host_loop.rs`), qui devait, lui, tout traduire
/// d'avance faute de pouvoir appeler l'émetteur depuis JavaScript.
#[test]
fn the_host_loop_runs_on_the_page_translator_alone() {
    let bun = bun();
    let module = page_module();
    let root = workspace_root();
    let work = scratch("boucle");
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    const STRIDE: u64 = 0x100;
    const LINKS: u64 = 3;
    const LAPS: u64 = 200;
    // Chaque maillon : `movq $n,%rax ; addq %rax,%rdx ; movabs $suivant,%rax ;
    // jmp *%rax`. Le saut est indirect : une cible connue à la traduction
    // resterait dans la région, et il n'y aurait rien à découvrir.
    let region = |index: u64| -> Vec<u8> {
        let mut code = vec![0x48, 0xc7, 0xc0];
        code.extend_from_slice(&(index as u32 + 1).to_le_bytes());
        code.extend_from_slice(&[0x48, 0x01, 0xc2]);
        code.extend_from_slice(&[0x48, 0xb8]);
        code.extend_from_slice(&(BASE + ((index + 1) % LINKS) * STRIDE).to_le_bytes());
        code.extend_from_slice(&[0xff, 0xe0]);
        code
    };
    let mut placed = String::new();
    for index in 0..LINKS {
        let path = work.join(format!("maillon{index}.bin"));
        std::fs::write(&path, region(index)).expect("le maillon");
        placed.push_str(&format!(
            "[{},{:?}],",
            (BASE + index * STRIDE) & u64::from(PAGES * 65536 - 1),
            path.to_string_lossy()
        ));
    }
    let driver = work.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ emetteur }} from {page:?};
import {{ readFileSync }} from "fs";

const porte = emetteur(new WebAssembly.Module(readFileSync({module:?})));
const traduire = porte.traducteur({pages});
let demandes = 0;
const translate = (address, slot, code) => {{ demandes++; return traduire(address, slot, code); }};
const vm = machine({{ translate, pages: {pages} }});
for (const [at, path] of [{placed}]) {{
  new Uint8Array(vm.memory.buffer).set(readFileSync(path), at);
}}
vm.globals[{rip}].value = {base}n;
const premier = await vm.run({{ budget: 1000n, rounds: {links} }});
console.log("decouverte " + premier.stopped);
console.log("demandes " + demandes);
vm.globals[{rip}].value = {base}n;
vm.globals[2].value = 0n;
const second = await vm.run({{ budget: {budget}n, rounds: 1 }});
console.log("regime " + second.stopped);
console.log("demandes_en_regime " + (demandes - {links}));
console.log("rdx " + vm.globals[2].value.toString());
"#,
            host = root.join("web/host.js").to_string_lossy(),
            page = root.join("web/page-emitter.js").to_string_lossy(),
            module = module.to_string_lossy(),
            pages = PAGES,
            placed = placed,
            rip = RIP_SLOT,
            base = BASE,
            links = LINKS,
            // **Deux blocs de plus qu'un nombre rond de tours**, exprès : un
            // budget qui s'épuise pile sur le départ de l'anneau fait jouer à
            // `host.js` un bloc de plus pour distinguer une boucle d'une
            // machine bloquée (`rip() === here`), et ce bloc-là ajoute 1 à RDX.
            // Finir sur le troisième maillon garde le compte sans ambiguïté.
            budget = LAPS * LINKS + 2,
        ),
    )
    .expect("le pilote");
    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let _ = std::fs::remove_dir_all(&work);
    assert!(
        output.status.success(),
        "le pilote a échoué : {}\n{text}",
        String::from_utf8_lossy(&output.stderr)
    );
    let said = |label: &str| -> String {
        text.lines()
            .find_map(|line| line.strip_prefix(label).map(|rest| rest.trim().to_string()))
            .unwrap_or_else(|| panic!("le pilote n'a pas dit « {label} » :\n{text}"))
    };
    assert_eq!(
        said("demandes "),
        "3",
        "une traduction par maillon :\n{text}"
    );
    assert_eq!(
        said("demandes_en_regime"),
        "0",
        "plus rien à traduire en régime"
    );
    assert_eq!(said("regime"), "tours épuisés", "{text}");
    assert_eq!(
        said("rdx"),
        (LAPS * (1 + 2 + 3) + 1 + 2).to_string(),
        "l'anneau traduit dans la page doit avoir tourné {LAPS} fois"
    );
}

/// **Lancer un pilote Bun** écrit dans un dossier de travail à part, et rendre
/// ce qu'il a imprimé. Un pilote qui échoue fait tomber le test avec sa sortie
/// d'erreur : une exception JavaScript non rattrapée ne doit jamais passer
/// pour une réponse.
fn run_driver(name: &str, script: &str) -> String {
    let bun = bun();
    let work = scratch(name);
    let driver = work.join("d.mjs");
    std::fs::write(&driver, script).expect("le pilote");
    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let _ = std::fs::remove_dir_all(&work);
    assert!(
        output.status.success(),
        "le pilote a échoué : {}\n{text}",
        String::from_utf8_lossy(&output.stderr)
    );
    text
}

/// La valeur que le pilote a imprimée après `label`, ou le test tombe.
fn said(text: &str, label: &str) -> String {
    text.lines()
        .find_map(|line| line.strip_prefix(label).map(|rest| rest.trim().to_string()))
        .unwrap_or_else(|| panic!("le pilote n'a pas dit « {label} » :\n{text}"))
}

/// L'en-tête commun des pilotes : la boucle hôte, l'émetteur de la page, et
/// la porte instanciée sur le module que le script construit.
fn prelude(module: &Path) -> String {
    let root = workspace_root();
    format!(
        "import {{ machine }} from {host:?};\n\
         import {{ emetteur }} from {page:?};\n\
         import {{ readFileSync }} from \"fs\";\n\
         const porte = emetteur(new WebAssembly.Module(readFileSync({module:?})));\n\
         const hex = (octets) => Array.from(octets, (o) => o.toString(16).padStart(2, \"0\")).join(\"\");\n",
        host = root.join("web/host.js").to_string_lossy(),
        page = root.join("web/page-emitter.js").to_string_lossy(),
        module = module.to_string_lossy(),
    )
}

/// `mov $1,%eax ; ret` : une région de deux instructions.
const PETIT: [u8; 6] = [0xb8, 0x01, 0x00, 0x00, 0x00, 0xc3];

/// `push %es` : invalide en mode 64 bits, suivi d'assez de `nop` pour que le
/// bord soit loin. Le décodeur a toute la place qu'il lui faut et ne lit pas
/// l'instruction : c'est un refus franc, pas une coupe.
fn illisible() -> Vec<u8> {
    let mut octets = vec![0x06];
    octets.extend_from_slice(&[0x90; 31]);
    octets
}

fn as_js(octets: &[u8]) -> String {
    format!(
        "new Uint8Array([{}])",
        octets
            .iter()
            .map(u8::to_string)
            .collect::<Vec<_>>()
            .join(",")
    )
}

/// **Les trois réponses du traducteur, telles que `host.js` les lit.**
///
/// La comparaison du corpus passe par `resoudre` ; la boucle hôte, elle,
/// n'appelle que `traducteur`, et c'est sa traduction des trois cas qui décide
/// de ce qu'elle fait : des octets s'instancient, `"encore"` fait relire la
/// fenêtre à seize kibioctets, `null` arrête la machine sur « refusée ». Rendre
/// une coupe comme un refus ferait perdre en silence chaque région que le
/// second essai aurait traduite. Chaque branche est donc appelée ici, avec ce
/// qu'elle laisse dans `pourquoi` et ce qu'elle passe à `surRefus`, et jugée
/// contre `Module::resolving_or_why` en natif.
#[test]
fn the_page_translator_answers_each_way_the_host_loop_reads() {
    let module = page_module();
    let script = format!(
        r#"{prelude}
const refus = [];
const traduire = porte.traducteur(16, (adresse, raison) => refus.push([adresse, raison]));
const quinze = porte.traducteur(15, (adresse, raison) => refus.push([adresse, raison]));
const decrire = (rendu) =>
  rendu === null ? "null" : typeof rendu === "string" ? rendu : "octets " + hex(rendu);

console.log("module " + decrire(traduire(0x100000n, 7, {petit})));
console.log("pourquoi_module " + porte.pourquoi);
console.log("coupe " + decrire(traduire(0x100000n, 0, {coupe})));
console.log("pourquoi_coupe " + porte.pourquoi);
console.log("refus_apres_coupe " + refus.length);
console.log("illisible " + decrire(traduire(0x200000n, 0, {illisible})));
console.log("pourquoi_illisible " + porte.pourquoi);
console.log("ram " + decrire(quinze(0x300000n, 0, {petit})));
console.log("pourquoi_ram " + porte.pourquoi);
console.log("refus_vus " + refus.map(([a, r]) => "0x" + a.toString(16) + "=" + r).join(" | "));
// **Un module après un refus, puis après une coupe** : le premier appel du
// pilote trouvait `pourquoi` déjà à `null`, sa valeur de départ, et ne
// prouvait donc pas que la branche module l'efface.
console.log("module_apres_refus " + decrire(traduire(0x100000n, 7, {petit})));
console.log("pourquoi_apres_refus " + porte.pourquoi);
traduire(0x100000n, 0, {coupe});
console.log("pourquoi_avant_effacement " + porte.pourquoi);
console.log("module_apres_coupe " + decrire(traduire(0x100000n, 7, {petit})));
console.log("pourquoi_apres_coupe " + porte.pourquoi);
console.log("instances " + porte.instances);
"#,
        prelude = prelude(&module),
        petit = as_js(&PETIT),
        coupe = as_js(&PETIT[..2]),
        illisible = as_js(&illisible()),
    );
    let text = run_driver("traducteur", &script);

    let attendu = Module::resolving_or_why(&PETIT, 0x10_0000, 0, 7, 16).expect("traduit");
    let hex = |octets: &[u8]| -> String { octets.iter().map(|o| format!("{o:02x}")).collect() };
    assert_eq!(said(&text, "module "), format!("octets {}", hex(&attendu)));
    assert_eq!(said(&text, "pourquoi_module "), "null", "{text}");

    // **La coupe** : la seule réponse qui fait relire la fenêtre plus large.
    let coupe = Module::resolving_or_why(&PETIT[..2], 0x10_0000, 0, 0, 16)
        .expect_err("deux octets d'un `mov $imm32` ne se traduisent pas");
    assert!(matches!(coupe, Refused::MayBeCut { .. }), "{coupe:?}");
    assert_eq!(said(&text, "coupe "), "encore", "{text}");
    assert_eq!(said(&text, "pourquoi_coupe "), format!("{coupe:?}"));
    assert_eq!(
        said(&text, "refus_apres_coupe "),
        "0",
        "une coupe n'est pas un refus : `surRefus` ne doit pas l'avoir vue"
    );

    // **Deux refus francs**, d'espèces différentes : l'un vient du décodeur,
    // l'autre de la RAM déclarée au traducteur.
    let illisible_natif = Module::resolving_or_why(&illisible(), 0x20_0000, 0, 0, 16)
        .expect_err("`push %es` n'existe pas en mode 64 bits");
    assert!(
        matches!(illisible_natif, Refused::CannotDecode { .. }),
        "{illisible_natif:?}"
    );
    assert_eq!(said(&text, "illisible "), "null", "{text}");
    assert_eq!(
        said(&text, "pourquoi_illisible "),
        format!("{illisible_natif:?}")
    );
    assert_eq!(said(&text, "ram "), "null", "{text}");
    let ram = format!("{:?}", Refused::RamIsNotAPowerOfTwo(15));
    assert_eq!(said(&text, "pourquoi_ram "), ram);
    assert_eq!(
        said(&text, "refus_vus "),
        format!("0x200000={illisible_natif:?} | 0x300000={ram}"),
        "`surRefus` reçoit l'adresse et la raison de chaque refus franc, et rien d'autre"
    );

    // **La branche module efface la raison**, qu'elle suive un refus ou une
    // coupe : sans cela, `pourquoi` nommerait après une traduction réussie un
    // refus qui ne la concerne plus.
    assert_eq!(
        said(&text, "module_apres_refus "),
        format!("octets {}", hex(&attendu))
    );
    assert_eq!(said(&text, "pourquoi_apres_refus "), "null", "{text}");
    assert_eq!(
        said(&text, "pourquoi_avant_effacement "),
        format!("{coupe:?}"),
        "la coupe doit avoir laissé sa raison, sinon l'effacement ne prouve rien"
    );
    assert_eq!(
        said(&text, "module_apres_coupe "),
        format!("octets {}", hex(&attendu))
    );
    assert_eq!(said(&text, "pourquoi_apres_coupe "), "null", "{text}");
    assert_eq!(said(&text, "instances "), "1", "aucune trappe ici");
}

/// **Un anneau de maillons** : `movq $n,%rax ; addq %rax,%rdx ; movabs
/// $suivant,%rax ; jmp *%rax`, le saut indirect pour que chaque maillon soit
/// une région à découvrir. RDX finit par porter la somme des tours.
fn ring_link(base: u64, stride: u64, links: u64, index: u64) -> Vec<u8> {
    let mut code = vec![0x48, 0xc7, 0xc0];
    code.extend_from_slice(&(index as u32 + 1).to_le_bytes());
    code.extend_from_slice(&[0x48, 0x01, 0xc2]);
    code.extend_from_slice(&[0x48, 0xb8]);
    code.extend_from_slice(&(base + ((index + 1) % links) * stride).to_le_bytes());
    code.extend_from_slice(&[0xff, 0xe0]);
    code
}

/// Les maillons, en littéral JavaScript `[[adresse, octets], …]`, pour une RAM
/// d'une page de 64 Kio.
fn ring_literal(base: u64, stride: u64, links: u64) -> String {
    let placed = (0..links)
        .map(|index| {
            format!(
                "[{}, {}]",
                (base + index * stride) & 0xffff,
                as_js(&ring_link(base, stride, links, index))
            )
        })
        .collect::<Vec<_>>()
        .join(", ");
    format!("[{placed}]")
}

/// **`"encore"` fait vraiment relire la fenêtre, et le second essai compte.**
///
/// Deux machines, la boucle hôte inchangée et ce seul traducteur :
///
/// - **Au bord de la RAM**, une instruction de dix octets dont quatre seulement
///   existent : `host.js` lit 4 octets, reçoit `"encore"`, relit à seize
///   kibioctets — et retrouve les mêmes 4 octets, puisque la RAM s'arrête là.
///   Deux demandes, puis « refusée ». C'est la coupe qu'aucun second essai ne
///   guérit, et la seule que la vraie boucle peut rencontrer quand la
///   pagination est éteinte.
/// - **Une première lecture courte**, comme celle qu'une page absente juste
///   après le point d'entrée produirait : la première demande ne reçoit que
///   3 octets du premier maillon. `"encore"` fait relire 16 384 octets, le
///   module de ce second essai est celui qui s'installe, et l'anneau tourne.
///
/// Rendre la coupe comme un refus (`null`) laisse une seule demande dans les
/// deux cas, et la seconde machine s'arrête sur « refusée ».
#[test]
fn a_cut_first_instruction_makes_the_host_loop_read_a_wider_window() {
    const BASE: u64 = 0x1_0000;
    const STRIDE: u64 = 0x100;
    const LINKS: u64 = 3;
    const LAPS: u64 = 200;
    const EDGE: u64 = 0xfffc;
    let module = page_module();
    let script = format!(
        r#"{prelude}
const traduire = porte.traducteur(1);

// **Au bord de la RAM.**
const auBord = [];
const bord = machine({{
  translate: (adresse, emplacement, code) => {{ auBord.push(code.length); return traduire(adresse, emplacement, code); }},
  pages: 1,
}});
new Uint8Array(bord.memory.buffer).set({bord_octets}, {edge});
bord.globals[{rip}].value = {edge}n;
const arret = await bord.run({{ budget: 1000n, rounds: 2 }});
console.log("bord_arret " + arret.stopped + " 0x" + arret.at.toString(16));
console.log("bord_fenetres " + auBord.join(","));

// **Une première lecture courte.**
const fenetres = [];
const anneau = machine({{
  translate: (adresse, emplacement, code) => {{
    const vue = fenetres.length === 0 ? code.subarray(0, 3) : code;
    fenetres.push(vue.length);
    return traduire(adresse, emplacement, vue);
  }},
  pages: 1,
}});
for (const [at, octets] of {ring}) new Uint8Array(anneau.memory.buffer).set(octets, at);
anneau.globals[{rip}].value = {base}n;
// La découverte d'abord, un tour par maillon (le motif de
// `the_host_loop_runs_on_the_page_translator_alone`), puis le régime établi.
await anneau.run({{ budget: 1000n, rounds: {links} }});
console.log("anneau_fenetres " + fenetres.join(","));
anneau.globals[{rip}].value = {base}n;
anneau.globals[2].value = 0n;
const tour = await anneau.run({{ budget: {budget}n, rounds: 1 }});
console.log("anneau_arret " + tour.stopped);
console.log("rdx " + anneau.globals[2].value.toString());
"#,
        prelude = prelude(&module),
        // `movabs $0x…,%rax`, dont seuls l'opcode et deux octets de
        // l'immédiat tiennent avant la fin de la RAM.
        bord_octets = as_js(&[0x48, 0xb8, 0x01, 0x02]),
        edge = EDGE,
        rip = RIP_SLOT,
        ring = ring_literal(BASE, STRIDE, LINKS),
        base = BASE,
        links = LINKS,
        // Le même compte que `the_host_loop_runs_on_the_page_translator_alone` :
        // finir sur le troisième maillon garde la somme sans ambiguïté.
        budget = LAPS * LINKS + 2,
    );
    let text = run_driver("coupe", &script);
    assert_eq!(
        said(&text, "bord_fenetres "),
        "4,4",
        "une coupe doit faire relire la fenêtre une fois, et une seule :\n{text}"
    );
    assert_eq!(said(&text, "bord_arret "), format!("refusée 0x{EDGE:x}"));
    assert_eq!(
        said(&text, "anneau_fenetres "),
        "3,16384,4096,4096",
        "la coupe relue à seize kibioctets, puis les deux autres maillons :\n{text}"
    );
    assert_eq!(said(&text, "anneau_arret "), "tours épuisés", "{text}");
    assert_eq!(
        said(&text, "rdx "),
        (LAPS * (1 + 2 + 3) + 1 + 2).to_string(),
        "le module du second essai est celui qui tourne"
    );
}

/// **Une trappe de l'émetteur ne coûte qu'une région.**
///
/// Dans la page, l'émetteur est construit avec `panic = "abort"` : un panic,
/// ou une allocation qui échoue, est une trappe, et rien n'est déroulé — le
/// verrou de la porte reste pris. Sans rien de plus, chaque appel suivant
/// trappait à son tour, et `host.js` aurait vu « traduction en panne » sur
/// toutes les régions à venir. La trappe vient ici d'une fenêtre que
/// l'émetteur ne peut pas allouer (4 Gio moins un octet annoncés : seule sa
/// `length` est lue avant `allouer`), le déclencheur réaliste étant un manque
/// de mémoire. Ce qui doit suivre : une instance neuve, les mêmes octets
/// qu'avant pour la même fenêtre, et, dans la boucle hôte, une panne nommée
/// sur cette région-là — puis la machine qui repart.
#[test]
fn a_trap_in_the_page_emitter_costs_one_region_not_the_emitter() {
    const BASE: u64 = 0x1_0000;
    const STRIDE: u64 = 0x100;
    const LINKS: u64 = 3;
    const LAPS: u64 = 200;
    let module = page_module();
    let script = format!(
        r#"{prelude}
const impossible = {{ length: 0xffffffff }};
const avant = porte.resoudre({petit}, 0x100000n, 7, 16);
console.log("avant " + hex(avant.module));
const trappe = porte.resoudre(impossible, 0x100000n, 7, 16);
console.log("trappe " + (trappe.trappe !== undefined));
console.log("trappe_texte " + trappe.trappe);
const apres = porte.resoudre({petit}, 0x100000n, 7, 16);
console.log("apres " + (apres.module === undefined ? JSON.stringify(apres) : hex(apres.module)));
console.log("instances " + porte.instances);

// **Par le traducteur** : une trappe lève (`host.js` la nomme « en panne »),
// et la traduction suivante rend des octets.
const traduire = porte.traducteur(16);
let leve = "non";
let message = "";
try {{ traduire(0x100000n, 7, impossible); }} catch (erreur) {{ leve = "oui"; message = erreur.message; }}
console.log("leve " + leve);
console.log("leve_message " + message);
// **Ce que la trappe laisse dans `pourquoi`** : le getter promet « la raison
// du dernier refus — ou de la dernière trappe ».
console.log("pourquoi_trappe " + porte.pourquoi);
const ensuite = traduire(0x100000n, 7, {petit});
console.log("ensuite " + (ensuite instanceof Uint8Array ? hex(ensuite) : String(ensuite)));
console.log("pourquoi_ensuite " + porte.pourquoi);

// **Dans la boucle hôte** : la première demande trappe, la machine s'arrête
// sur cette région, et un second départ la retraduit et fait tourner l'anneau.
const unique = porte.traducteur(1);
let demandes = 0;
const vm = machine({{
  translate: (adresse, emplacement, code) => {{
    demandes++;
    return unique(adresse, emplacement, demandes === 1 ? impossible : code);
  }},
  pages: 1,
}});
for (const [at, octets] of {ring}) new Uint8Array(vm.memory.buffer).set(octets, at);
vm.globals[{rip}].value = {base}n;
const panne = await vm.run({{ budget: 1000n, rounds: 1 }});
console.log("panne " + panne.stopped + " 0x" + panne.at.toString(16));
// Repartir du même endroit : la région qui a trappé n'est pas connue, elle se
// redemande, puis les deux autres se découvrent ; enfin le régime établi.
await vm.run({{ budget: 1000n, rounds: {links} }});
console.log("demandes " + demandes);
vm.globals[{rip}].value = {base}n;
vm.globals[2].value = 0n;
const repart = await vm.run({{ budget: {budget}n, rounds: 1 }});
console.log("repart " + repart.stopped);
console.log("demandes_en_regime " + (demandes - 4));
console.log("rdx " + vm.globals[2].value.toString());
console.log("instances_fin " + porte.instances);
"#,
        prelude = prelude(&module),
        petit = as_js(&PETIT),
        ring = ring_literal(BASE, STRIDE, LINKS),
        rip = RIP_SLOT,
        base = BASE,
        links = LINKS,
        budget = LAPS * LINKS + 2,
    );
    let text = run_driver("trappe", &script);
    let attendu = Module::resolving_or_why(&PETIT, 0x10_0000, 0, 7, 16).expect("traduit");
    let hex: String = attendu.iter().map(|o| format!("{o:02x}")).collect();
    assert_eq!(said(&text, "avant "), hex);
    assert_eq!(said(&text, "trappe "), "true", "{text}");
    assert_eq!(
        said(&text, "apres "),
        hex,
        "après une trappe, la même fenêtre doit rendre le même module"
    );
    assert_eq!(
        said(&text, "instances "),
        "2",
        "une instance neuve, une seule"
    );
    assert_eq!(said(&text, "leve "), "oui", "une trappe n'est pas un refus");
    // **La raison d'une trappe est le message du moteur**, le même que
    // `resoudre` a rendu pour la même fenêtre : il ne vient pas des octets de
    // l'invité, et c'est ce que le pilote doit pouvoir journaliser.
    let raison = said(&text, "trappe_texte ");
    assert!(
        raison.starts_with("RuntimeError"),
        "une trappe du module est une `RuntimeError` du moteur : {text}"
    );
    // Le nom seul ne suffit pas : c'est le message entier qu'il faut garder,
    // celui qui dit *quelle* trappe (`String(trappe)`, pas `trappe.name`).
    assert!(
        raison.contains("Unreachable"),
        "la raison garde le message du moteur, pas seulement son nom : {text}"
    );
    assert_eq!(said(&text, "pourquoi_trappe "), raison, "{text}");
    assert_eq!(
        said(&text, "leve_message "),
        format!("l'émetteur de la page a trappé : {raison}"),
        "l'erreur levée nomme la trappe"
    );
    assert_eq!(said(&text, "ensuite "), hex);
    assert_eq!(said(&text, "pourquoi_ensuite "), "null", "{text}");
    assert_eq!(
        said(&text, "panne "),
        format!("traduction en panne 0x{BASE:x}"),
        "{text}"
    );
    assert_eq!(said(&text, "repart "), "tours épuisés", "{text}");
    assert_eq!(
        said(&text, "demandes "),
        "4",
        "la région qui a trappé, retraduite, puis les deux autres"
    );
    assert_eq!(said(&text, "demandes_en_regime "), "0", "{text}");
    assert_eq!(
        said(&text, "rdx "),
        (LAPS * (1 + 2 + 3) + 1 + 2).to_string(),
        "l'anneau doit avoir tourné sur l'instance neuve"
    );
    assert_eq!(said(&text, "instances_fin "), "4", "{text}");
}

/// **Le socle de la boucle hôte en Rust** (`src/hote.rs`) : depuis le module
/// de la page, l'état d'une machine traduite se lit et s'écrit.
///
/// Le pilote fait ce que fera la boucle : une mémoire et les quatre-vingt-
/// treize globales des modules traduits, données au Rust par `brancher`. Puis
/// chaque sens : un registre posé en JavaScript lu par le Rust, un registre
/// écrit par le Rust lu en JavaScript, huit octets et un octet de la mémoire
/// dans les deux sens, un numéro de registre hors bornes. **Après une trappe
/// de l'émetteur**, l'instance est neuve et sa table aussi : le Rust doit
/// encore atteindre la machine. Le banc chiffre ce qu'un appel coûte, contre
/// la même lecture faite en JavaScript.
#[test]
fn rust_in_the_page_reads_and_writes_the_translated_machine() {
    use wisq_vm::x86_wasm::GLOBAL_COUNT;
    let module = page_module();
    let script = format!(
        r#"{prelude}
const memoire = new WebAssembly.Memory({{ initial: 4 }});
const globales = [];
for (let rang = 0; rang < {count}; rang++) {{
  globales.push(new WebAssembly.Global({{ value: "i64", mutable: true }}, 0n));
}}
const p = () => porte.porte;
console.log("avant " + p().hote_lire({rip}));
porte.brancher(memoire, globales);
globales[{rip}].value = 0xffffffff81000000n;
console.log("rip " + BigInt.asUintN(64, p().hote_lire({rip})).toString(16));
p().hote_ecrire({last}, -2n);
console.log("ecrit " + globales[{last}].value);
console.log("hors " + p().hote_lire(100000));
new DataView(memoire.buffer).setBigUint64(0x2000, 0x1122334455667788n, true);
console.log("lire64 " + p().hote_lire64(0x2000).toString(16));
p().hote_ecrire64(0x3000, 0x0102030405060708n);
console.log("ecrire64 " + new DataView(memoire.buffer).getBigUint64(0x3000, true).toString(16));
p().hote_ecrire8(0x10, 0x1ab);
console.log("octet " + new Uint8Array(memoire.buffer)[0x10] + " " + p().hote_lire8(0x10));

// Une trappe de l'émetteur : instance neuve, table neuve, machine rebranchée.
porte.resoudre({{ length: 0xffffffff }}, 0x100000n, 7, 16);
globales[{rip}].value = 42n;
console.log("apres_trappe " + porte.instances + " " + p().hote_lire({rip}));

const fois = 2000000;
let debut = performance.now();
const somme = p().hote_banc({rip}, fois);
const rust = performance.now() - debut;
debut = performance.now();
let js = 0n;
for (let i = 0; i < fois; i++) js += globales[{rip}].value;
const parJs = performance.now() - debut;
console.log("banc " + somme + " " + (rust * 1e6 / fois).toFixed(1) + " ns/appel Rust, "
  + (parJs * 1e6 / fois).toFixed(1) + " ns/lecture JS");
"#,
        prelude = prelude(&module),
        count = GLOBAL_COUNT,
        rip = RIP_SLOT,
        last = GLOBAL_COUNT - 1,
    );
    let out = run_driver("hote", &script);
    eprintln!("{}", said(&out, "banc"));
    assert_eq!(said(&out, "avant"), "-1", "rien de branché : -1");
    assert_eq!(said(&out, "rip"), "ffffffff81000000");
    assert_eq!(said(&out, "ecrit"), "-2");
    assert_eq!(
        said(&out, "hors"),
        "0",
        "un registre hors bornes se lit zéro"
    );
    assert_eq!(said(&out, "lire64"), "1122334455667788");
    assert_eq!(said(&out, "ecrire64"), "102030405060708");
    assert_eq!(said(&out, "octet"), "171 171");
    assert_eq!(said(&out, "apres_trappe"), "2 42");
    assert!(said(&out, "banc").starts_with(&format!("{}", 42u64 * 2_000_000)));
}
