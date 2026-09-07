//! **La boucle hôte du bureau local, jugée ici plutôt que sur un téléphone.**
//!
//! `web/host.js` est le code qui vivra dans le `WKWebView` : il tient la RAM
//! de l'invité, les globales, la table des blocs et la correspondance, demande
//! une traduction à l'application quand il tombe sur une adresse inconnue, et
//! enchaîne. Rien de ce fichier n'est vérifiable depuis un simulateur ; tout
//! l'est sous Bun, qui embarque le même JavaScriptCore.
//!
//! **Le traducteur est injecté**, et c'est ce qui rend le test possible : dans
//! l'application c'est un aller-retour par message vers le processus hôte, où
//! vit l'émetteur ; ici c'est une table d'octets préparés par ce test avec le
//! même émetteur. La boucle ne voit pas la différence — elle voit une fonction
//! qui rend une promesse.

use std::path::{Path, PathBuf};
use std::process::Command;

use wisq_vm::x86_wasm::{
    table_slot, Module, GLOBAL_COUNT, RIP_SLOT, TABLE_ENTRY, TABLE_PAGES, TABLE_SLOTS,
};

fn workspace_root() -> PathBuf {
    let mut at = Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf();
    while !at.join("Cargo.lock").exists() {
        at = at.parent().expect("la racine du dépôt").to_path_buf();
    }
    at
}

fn bun() -> Option<PathBuf> {
    ["/root/.bun/bin/bun", "bun"]
        .into_iter()
        .map(PathBuf::from)
        .find(|path| Command::new(path).arg("--version").output().is_ok())
}

/// **Les constantes que `web/host.js` répète, et qu'il ne peut pas importer.**
///
/// Rien ne traverse la frontière entre Rust et la vue à part des octets : le
/// fichier JavaScript ne peut pas lire `GLOBAL_COUNT`, il le recopie. Une
/// répétition que rien ne compare finit toujours par mentir — celle-ci est
/// comparée.
#[test]
fn the_view_repeats_the_emitters_numbers_and_they_still_agree() {
    let text = std::fs::read_to_string(workspace_root().join("web/host.js")).expect("host.js");
    let value = |name: &str| -> String {
        text.lines()
            .find_map(|line| {
                let line = line.trim();
                line.strip_prefix(&format!("{name}: "))
                    .map(|rest| rest.trim_end_matches(',').trim().to_string())
            })
            .unwrap_or_else(|| panic!("host.js ne déclare pas « {name} »"))
    };
    assert_eq!(value("rip"), RIP_SLOT.to_string(), "l'emplacement de RIP");
    assert_eq!(
        value("globalCount"),
        GLOBAL_COUNT.to_string(),
        "le nombre de globales"
    );
    assert_eq!(
        value("tablePages"),
        TABLE_PAGES.to_string(),
        "les pages de la correspondance"
    );
    assert_eq!(
        value("tableEntry"),
        TABLE_ENTRY.to_string(),
        "la taille d'une case"
    );
    assert_eq!(
        value("mix"),
        format!("0x{:x}n", wisq_vm::x86_wasm::TABLE_MIX),
        "le multiplicateur du hachage"
    );
    assert_eq!(
        value("tableSlots"),
        format!("1 << {}", TABLE_SLOTS.trailing_zeros()),
        "le nombre de cases"
    );
}

/// **La machine tourne dans la vue, et l'application ne fait que traduire.**
///
/// Trois régions en anneau, aucune traduite d'avance : la boucle les demande
/// une par une, au moment où elle tombe dessus. C'est ce que fera le bureau —
/// un noyau n'annonce pas ses fonctions, on les découvre en y arrivant.
///
/// **Le test se joue en deux temps, et le second est celui qui compte.** Au
/// premier tour, chaque saut vers une région pas encore traduite rend la main :
/// la correspondance ne peut pas aider, puisque la cible n'y est pas encore.
/// C'est un fait sur la conception, pas un défaut — elle ne rapporte qu'à
/// partir du deuxième passage, ce qui est précisément le régime d'un noyau.
///
/// Le second temps le vérifie : **un seul appel**, et l'anneau tourne des
/// centaines de fois sans jamais ressortir. Sans cette moitié, tout ce qui
/// touche à la correspondance — la case, l'adresse rangée, l'emplacement,
/// l'endroit où elle vit — resterait tenu par rien. Cinq sabotages y ont
/// survécu avant qu'elle existe.
#[test]
fn the_view_discovers_regions_as_it_reaches_them_and_keeps_the_machine() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    const STRIDE: u64 = 0x100;
    const LINKS: u64 = 3;

    // Trois maillons en anneau. Chacun ajoute son numéro à RDX puis saute
    // **indirectement** au suivant — une cible connue à la compilation
    // resterait dans la région, et il n'y aurait rien à enchaîner.
    let region = |index: u64| -> Vec<u8> {
        let mut code = vec![0x48, 0xc7, 0xc0];
        code.extend_from_slice(&(index as u32 + 1).to_le_bytes()); // movq $n, %rax
                                                                   // **Le premier maillon porte deux blocs, exprès.** Une région d'un
                                                                   // seul bloc laisse passer une faute entière : l'hôte avance son
                                                                   // emplacement de un au lieu de compter les blocs réellement posés, et
                                                                   // rien ne s'en aperçoit tant que chaque région n'en pose qu'un. Un
                                                                   // vrai noyau en pose des dizaines par fonction.
        if index == 0 {
            code.extend_from_slice(&[0x48, 0x85, 0xc0]); // testq %rax, %rax
            code.extend_from_slice(&[0x75, 0x00]); // jnz +0 : coupe le bloc
        }
        // Et le deuxième par un saut **inconditionnel**, qui prend l'autre
        // chemin de l'émetteur : `place` au lieu de `choose`. Sans lui, un
        // indice de bloc rendu par `place` pourrait rester relatif sans que
        // rien ne tombe.
        if index == 1 {
            code.extend_from_slice(&[0xeb, 0x00]); // jmp +0
        }
        code.extend_from_slice(&[0x48, 0x01, 0xc2]); // addq %rax, %rdx
        code.extend_from_slice(&[0x48, 0xb8]);
        code.extend_from_slice(&(BASE + ((index + 1) % LINKS) * STRIDE).to_le_bytes());
        code.extend_from_slice(&[0xff, 0xe0]); // jmp *%rax
        code
    };
    let blocks: u64 = (0..LINKS)
        .map(|index| Module::survey(&region(index), 0).expect("le relevé").blocks as u64)
        .sum();
    assert_eq!(
        blocks, 5,
        "deux maillons à deux blocs et un à un : sans ça le test ne couvre ni \
         le comptage des emplacements ni les deux chemins de l'émetteur"
    );

    let scratch = std::env::temp_dir().join(format!("wisq-host-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    // **Une région par emplacement possible.** La vue choisit l'emplacement et
    // le passe avec la demande ; l'application, elle, compilera à ce moment-là.
    // Ce test ne peut pas appeler l'émetteur depuis JavaScript, alors il
    // prépare d'avance ce que chaque demande pourrait valoir, et le catalogue
    // est indexé par **adresse et emplacement** — les deux choses que la vue
    // envoie.
    let mut catalogue = String::new();
    for index in 0..LINKS {
        let address = BASE + index * STRIDE;
        let code = region(index);
        for slot in 0..6u32 {
            let module = Module::resolving(&code, address, 0, slot, PAGES)
                .unwrap_or_else(|| panic!("l'émetteur doit compiler la région {index}"));
            let path = scratch.join(format!("region{index}-{slot}.wasm"));
            std::fs::write(&path, &module).expect("le module");
            catalogue.push_str(&format!(
                "[\"{address}:{slot}\",{:?}],",
                path.to_string_lossy()
            ));
        }
    }

    // Un tour d'anneau coûte cinq blocs, pas trois : deux maillons en portent
    // deux. Le budget est un multiple exact de ce compte, **exprès** —
    // l'anneau s'épuise alors pile sur son point de départ, et c'est le cas
    // qu'une détection naïve du blocage prendrait pour une machine arrêtée.
    let blocks_per_lap = blocks;
    let laps = 300u64;
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";

const catalogue = new Map([{catalogue}]);
let asked = 0;
const seen = [];
const translate = async (address, slot) => {{
  asked++;
  seen.push(address.toString(16));
  const path = catalogue.get(address + ":" + slot);
  return path === undefined ? null : readFileSync(path);
}};

const vm = machine({{ translate, pages: {pages} }});
vm.globals[{rip}].value = {base}n;

// **Premier temps : la découverte.** Le budget est large ; ce qui ramène à
// l'hôte, c'est que la cible de chaque saut n'est pas encore dans la
// correspondance. Trois tours, un par région : au quatrième l'anneau
// tournerait déjà tout seul, et le budget finirait par expirer **au milieu**
// d'une région — l'hôte en traduirait alors une nouvelle qui commence là, ce
// qui est correct mais n'est pas ce qu'on compte ici.
const first = await vm.run({{ budget: 1000n, rounds: {links} }});
console.log("decouverte " + first.stopped);
console.log("demandes " + asked);
console.log("vues " + seen.join(","));
console.log("regions " + vm.known.size);

// **Second temps : l'anneau tourne tout seul.** Un seul appel, un gros budget.
// Si la correspondance sert, la boucle ne ressort qu'une fois le budget épuisé
// et RDX porte la somme de tous les tours. Si elle ne sert pas, le premier saut
// rend la main et RDX ne bouge presque pas.
vm.globals[{rip}].value = {base}n;
vm.globals[2].value = 0n;
const before = asked;
const second = await vm.run({{ budget: {blocks}n, rounds: 1 }});
console.log("regime " + second.stopped);
console.log("retraductions " + (asked - before));
console.log("rdx " + vm.globals[2].value.toString());
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            catalogue = catalogue,
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            links = LINKS,
            blocks = laps * blocks_per_lap,
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

    // **Premier temps.** Trois régions découvertes, dans l'ordre où on y
    // arrive. Une seule demande voudrait dire que la boucle n'a pas suivi les
    // sauts ; quatre, qu'elle a redemandé ce qu'elle avait déjà.
    assert_eq!(seen("demandes"), "3", "une traduction par région, pas plus");
    assert_eq!(
        seen("vues"),
        "10000,10100,10200",
        "et dans l'ordre où la machine y arrive"
    );
    assert_eq!(seen("regions"), "3", "les trois sont retenues");

    // **Second temps, et c'est ici que la correspondance se prouve.** Un seul
    // appel, aucune retraduction, et l'anneau a tourné jusqu'au bout du budget.
    assert_eq!(
        seen("retraductions"),
        "0",
        "en régime établi, plus rien à traduire"
    );
    // **Et l'arrêt ne doit pas être « sur place ».** Le budget s'épuise pile
    // sur le point de départ de l'anneau : RIP retombe sur l'adresse d'où il
    // est parti, exactement comme le ferait une machine bloquée. Ce qui les
    // distingue est un bloc de plus, et cette ligne est la seule à le tenir.
    assert_eq!(
        seen("regime"),
        "tours épuisés",
        "un anneau revenu à son point de départ n'est pas une machine bloquée"
    );
    // Chaque tour d'anneau ajoute 1 + 2 + 3 à RDX.
    assert_eq!(
        seen("rdx"),
        (laps * (1 + 2 + 3)).to_string(),
        "l'anneau doit avoir tourné {laps} fois dans un seul appel"
    );
}

/// **Et une machine vraiment bloquée doit être nommée.**
///
/// Une région qui se réduit à `ud2` rend la main sur sa propre adresse, à
/// chaque appel, éternellement. La boucle doit le dire au lieu de tourner. Le
/// test existe parce que la garde qui le tient a d'abord été **trop large** :
/// elle prenait tout retour à l'adresse de départ pour un blocage, y compris
/// un anneau qui vient de tourner trois cents fois.
#[test]
fn the_view_names_a_machine_that_cannot_advance() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let scratch = std::env::temp_dir().join(format!("wisq-host-stuck-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&[0x0f, 0x0b], BASE, 0, 0, PAGES).expect("un `ud2` seul");
    let path = scratch.join("ud2.wasm");
    std::fs::write(&path, &module).expect("le module");
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
let asked = 0;
const vm = machine({{
  translate: async () => {{ asked++; return readFileSync({path:?}); }},
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 1024 }});
console.log("arret " + why.stopped);
console.log("ou " + why.at.toString(16));
console.log("demandes " + asked);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
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
    assert!(output.status.success(), "le pilote a échoué :\n{text}");
    let seen = |label: &str| -> String {
        text.lines()
            .find_map(|line| line.strip_prefix(label).map(|rest| rest.trim().to_string()))
            .unwrap_or_else(|| panic!("le pilote n'a pas dit « {label} » :\n{text}"))
    };
    assert_eq!(seen("arret"), "sur place", "le blocage doit se nommer");
    assert_eq!(seen("ou"), format!("{BASE:x}"), "et dire où");
    // Mille vingt-quatre tours étaient permis : s'y être arrêté au premier
    // veut dire que la boucle n'a pas tourné pour rien.
    assert_eq!(seen("demandes"), "1", "une seule traduction, puis l'arrêt");
}

/// **Une RAM qui n'est pas une puissance de deux se refuse ici aussi.**
///
/// La contrainte vient du confinement, mais c'est la vue qui crée la mémoire :
/// si elle acceptait une taille que l'émetteur refuse, la panne arriverait à la
/// première traduction, loin de sa cause.
#[test]
fn the_view_refuses_a_ram_the_emitter_could_not_confine() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    let scratch = std::env::temp_dir().join(format!("wisq-host-ram-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
for (const pages of [0, 3, 5, 12289]) {{
  try {{
    machine({{ translate: async () => null, pages }});
    console.log(pages + " acceptee");
  }} catch (why) {{
    console.log(pages + " refusee");
  }}
}}
machine({{ translate: async () => null, pages: 4 }});
console.log("4 acceptee");
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
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
    assert!(output.status.success(), "le pilote a échoué :\n{text}");
    for line in [
        "0 refusee",
        "3 refusee",
        "5 refusee",
        "12289 refusee",
        "4 acceptee",
    ] {
        assert!(
            text.lines().any(|seen| seen.trim() == line),
            "le pilote devait dire « {line} » :\n{text}"
        );
    }
}

/// La correspondance se calcule des deux côtés de la frontière, et il n'y a
/// aucun moyen de s'en apercevoir si elles divergent : le module rendrait la
/// main comme avant, et seule la vitesse serait perdue.
#[test]
fn the_view_and_the_emitter_hash_an_address_the_same_way() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    let addresses: Vec<u64> = (0..64)
        .map(|step: u64| 0x1000 + step * 0x137)
        .chain([0, 1, u64::MAX, 0x3000_0000])
        .collect();
    let scratch = std::env::temp_dir().join(format!("wisq-host-hash-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let driver = scratch.join("d.mjs");
    let listing: String = addresses
        .iter()
        .map(|address| format!("{address}n,"))
        .collect();
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ tableSlot }} from {host:?};
console.log([{listing}].map(tableSlot).join(","));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
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
    assert!(output.status.success(), "le pilote a échoué :\n{text}");
    let expected: String = addresses
        .iter()
        .map(|address| table_slot(*address).to_string())
        .collect::<Vec<_>>()
        .join(",");
    assert_eq!(
        text.trim(),
        expected,
        "la vue et l'émetteur doivent tomber sur les mêmes cases"
    );
}

/// **La page du bureau, et son pilote exécuté pour de vrai.**
///
/// `wisq_vm::desktop::page` habille la boucle hôte de ce qu'il faut pour vivre
/// dans un `WKWebView` : un pont vers l'application, l'état de départ, et de
/// quoi lancer la machine. Rien de tout ça ne serait exécuté par quoi que ce
/// soit avant un envoi TestFlight — sauf ici : un moteur JavaScript en ligne
/// de commande n'a pas de `WKWebView`, mais il sait parfaitement bouchonner
/// `window.webkit.messageHandlers`.
///
/// Ce que le test fait tourner est **le pilote que l'application chargera**,
/// pas une imitation : la même chaîne, extraite de la même fonction.
#[test]
fn the_pages_driver_talks_to_the_application_and_runs_the_machine() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : le pilote de la page ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    // **Une adresse au-dessus de deux puissance cinquante-trois**, et c'est
    // délibéré : un `Number` JavaScript perd des bits au-delà, alors qu'un
    // noyau x86-64 vit couramment dans le haut de l'espace d'adressage. Le
    // pont fait donc traverser l'adresse **en texte**. Avec une adresse
    // petite, écrire `Number(address)` à la place marcherait aussi bien — un
    // sabotage y a survécu avant que cette constante ne monte.
    const BASE: u64 = 0x0100_0000_0000_1000;

    // Deux régions : la première saute dans la seconde, la seconde s'arrête
    // sur un `ud2`. L'application devra donc répondre trois fois — la
    // troisième pour l'adresse du `ud2` lui-même.
    let scratch = std::env::temp_dir().join(format!("wisq-page-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut catalogue = String::new();
    let programs: [(u64, Vec<u8>); 3] = [
        (BASE, {
            let mut code = vec![0x48, 0xff, 0xc2, 0x48, 0xb8];
            code.extend_from_slice(&(BASE + 0x100).to_le_bytes());
            code.extend_from_slice(&[0xff, 0xe0]);
            code
        }),
        (BASE + 0x100, vec![0x48, 0xff, 0xc2, 0x0f, 0x0b]),
        (BASE + 0x103, vec![0x0f, 0x0b]),
    ];
    for (index, (address, code)) in programs.iter().enumerate() {
        for slot in 0..6u32 {
            let module = Module::resolving(code, *address, 0, slot, PAGES)
                .unwrap_or_else(|| panic!("l'émetteur doit compiler la région {index}"));
            let path = scratch.join(format!("page{index}-{slot}.wasm"));
            std::fs::write(&path, &module).expect("le module");
            catalogue.push_str(&format!(
                "[\"{address}:{slot}\",{:?}],",
                path.to_string_lossy()
            ));
        }
    }

    // Le pilote tel que la page le porte. Il est extrait plutôt que réécrit :
    // un test qui exécute une copie ne dit rien de l'original.
    let driver_source = wisq_vm::desktop::driver(PAGES, BASE, "wisq");
    let page = wisq_vm::desktop::page(PAGES, BASE, "wisq").expect("la page");
    assert!(
        page.contains(&driver_source),
        "la page doit porter exactement ce pilote"
    );
    assert!(
        page.contains(wisq_vm::desktop::HOST_SCRIPT),
        "et la boucle hôte, mot pour mot"
    );

    let harness = scratch.join("d.mjs");
    std::fs::write(
        &harness,
        format!(
            r#"
import {{ machine, SLOTS }} from {host:?};
import {{ readFileSync }} from "fs";

const catalogue = new Map([{catalogue}]);
const asked = [];
// **Le pont bouchonné.** Il fait ce que fera l'application : recevoir un
// message, traduire, et rappeler la vue. Le décalage est volontaire — un
// `setTimeout` de zéro — parce que dans l'application la réponse ne peut pas
// arriver dans le même tour de boucle, et un pilote qui en dépendrait
// marcherait ici et nulle part ailleurs.
const stopped = [];
globalThis.window = globalThis;
globalThis.webkit = {{
  messageHandlers: {{
    wisq: {{
      postMessage: note => {{
        if (note.kind === "arrêt") {{ stopped.push(note.stopped + " " + note.at); return; }}
        asked.push(note.address + ":" + note.slot);
        setTimeout(() => {{
          const path = catalogue.get(note.address + ":" + note.slot);
          const octets = path === undefined ? null : [...readFileSync(path)];
          window.wisqTranslated(note.id, octets);
        }}, 0);
      }},
    }},
  }},
}};

{driver}

const why = await window.wisqRun();
console.log("arret " + why);
console.log("demandes " + asked.length);
console.log("vues " + asked.join(","));
console.log("rdx " + window.wisqMachine.globals[2].value.toString());
console.log("postes " + stopped.join("|"));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            catalogue = catalogue,
            driver = driver_source,
        ),
    )
    .expect("le harnais");

    let output = Command::new(&bun)
        .arg("run")
        .arg(&harness)
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
            .unwrap_or_else(|| panic!("le harnais n'a pas dit « {label} » :\n{text}"))
    };
    // Trois adresses demandées, chacune avec l'emplacement que la vue a
    // choisi : c'est le contrat que l'application devra tenir.
    assert_eq!(seen("demandes"), "3", "une traduction par adresse atteinte");
    assert_eq!(
        seen("vues"),
        format!("{}:0,{}:1,{}:2", BASE, BASE + 0x100, BASE + 0x103),
        "l'adresse **et** l'emplacement traversent le pont"
    );
    // Deux `incq %rdx` : les deux régions ont tourné, pas seulement été
    // traduites.
    assert_eq!(seen("rdx"), "2", "les deux régions ont calculé");
    assert_eq!(seen("arret"), "sur place", "le `ud2` arrête la machine");
    assert_eq!(
        seen("postes"),
        format!("sur place {}", BASE + 0x103),
        "et l'arrêt remonte à l'application par le pont, l'adresse en décimal \
         comme celle d'une demande de traduction"
    );
}

/// **Ce que la page refuse de construire.**
///
/// Le nom du canal est recollé dans du JavaScript. Tout ce qui n'est pas une
/// lettre ou un chiffre pourrait en sortir et devenir du code — la même faute
/// que l'identifiant de VM recollé dans une ligne de commande, que ce dépôt a
/// déjà payée une fois.
#[test]
fn the_page_refuses_what_it_cannot_paste_safely() {
    use wisq_vm::desktop::{page, Refusal};
    assert_eq!(
        page(3, 0x1000, "wisq"),
        Err(Refusal::RamIsNotAPowerOfTwo(3)),
        "la RAM d'un invité confiné est une puissance de deux"
    );
    assert_eq!(
        page(0, 0x1000, "wisq"),
        Err(Refusal::RamIsNotAPowerOfTwo(0))
    );
    for name in ["", "wisq; alert(1)", "wisq.autre", "wisq-2", "a b", "é"] {
        assert_eq!(
            page(1, 0x1000, name),
            Err(Refusal::ChannelIsNotAName(name.to_string())),
            "« {name} » ne peut pas être recollé dans du JavaScript"
        );
    }
    for name in ["wisq", "w", "canal2"] {
        assert!(page(1, 0x1000, name).is_ok(), "« {name} » est un nom");
    }
    // Et le refus se lit : un message qui ne nomme pas ce qu'il refuse envoie
    // chercher la cause ailleurs.
    assert!(
        Refusal::RamIsNotAPowerOfTwo(3).to_string().contains('3'),
        "le refus doit nommer le nombre refusé"
    );
}
