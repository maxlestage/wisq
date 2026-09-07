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
    // **Ce que l'application a posé dans la mémoire de la vue.** Le vrai
    // bureau y charge l'image du noyau ; ce test y pose ses trois maillons, au
    // même endroit que l'adresse repliée les met. Sans ça la vue lirait des
    // zéros — et c'est précisément ce que le bouchon d'avant ne pouvait pas
    // remarquer, puisqu'il ne regardait pas les octets.
    let mut loaded = String::new();
    for index in 0..LINKS {
        let address = BASE + index * STRIDE;
        let code = region(index);
        let raw = scratch.join(format!("region{index}.bin"));
        std::fs::write(&raw, &code).expect("le code de la région");
        loaded.push_str(&format!(
            "[{},{:?}],",
            address & u64::from(PAGES * 65536 - 1),
            raw.to_string_lossy()
        ));
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
// Ce que l'application a chargé dans la RAM de l'invité, par adresse repliée.
const posé = new Map(
  [{loaded}].map(([at, path]) => [at, new Uint8Array(readFileSync(path))]),
);
let asked = 0;
const seen = [];
// **Le bouchon refuse ce que la vraie application ne pourrait pas faire.**
// C'est un bouchon complaisant — qui répondait sans regarder les octets — qui
// a caché pendant quatre tranches que la demande n'en portait pas. Celui-ci
// exige la fenêtre, et vérifie qu'elle commence bien par le code de la région
// : sans quoi il rendrait la bonne réponse à une mauvaise question.
const translate = async (address, slot, code) => {{
  asked++;
  seen.push(address.toString(16));
  if (!(code instanceof Uint8Array) || code.length === 0) {{
    throw new Error(`la demande à ${{address.toString(16)}} ne porte pas d'octets`);
  }}
  const expected = posé.get(Number(address & {mask}n));
  if (expected !== undefined) {{
    for (let at = 0; at < expected.length; at++) {{
      if (code[at] !== expected[at]) {{
        throw new Error(`la fenêtre à ${{address.toString(16)}} ne porte pas le code de la région`);
      }}
    }}
  }}
  const path = catalogue.get(address + ":" + slot);
  return path === undefined ? null : readFileSync(path);
}};

const vm = machine({{ translate, pages: {pages} }});
// **L'application pose l'image avant de lancer la machine**, exactement comme
// elle le fera avec un noyau. La vue lit ensuite ses fenêtres là-dedans.
for (const [at, octets] of posé) {{
  new Uint8Array(vm.memory.buffer, at, octets.length).set(octets);
}}
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
            loaded = loaded,
            mask = u64::from(PAGES * 65536 - 1),
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
    // Ce que l'application aura chargé dans la RAM de la vue, indexé par
    // l'adresse **en texte** — c'est sous cette forme qu'elle traverse.
    let mut loaded = String::new();
    for (address, code) in &programs {
        loaded.push_str(&format!("[\"{address}\",{code:?}],"));
    }
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
// Ce que l'application a posé dans la RAM de la vue, par adresse en texte.
const posé = new Map([{loaded}]);
const asked = [];
const fenêtres = [];
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
        // **L'application refuse une demande qui ne porte pas les octets.**
        // C'est le bouchon complaisant — qui répondait sans les regarder — qui
        // a caché que la demande n'en portait pas. Celui-ci vérifie qu'ils
        // arrivent en base64, qu'ils font la taille d'une fenêtre, et que la
        // région commence bien par le code qu'on a posé à cette adresse.
        if (typeof note.octets !== "string" || note.octets.length === 0) {{
          throw new Error("la demande ne porte pas d'octets");
        }}
        const brut = atob(note.octets);
        const attendu = posé.get(note.address);
        if (attendu !== undefined) {{
          for (let at = 0; at < attendu.length; at++) {{
            if (brut.charCodeAt(at) !== attendu[at]) {{
              throw new Error("la fenêtre ne porte pas le code de " + note.address);
            }}
          }}
        }}
        fenêtres.push(brut.length);
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

// **L'application pose son image avant de lancer la machine.** Le pilote vient
// de créer la vue ; c'est le moment où le vrai bureau y écrirait le noyau.
for (const [adresse, octets] of posé) {{
  const at = Number(BigInt(adresse) & BigInt({pages} * 65536 - 1));
  new Uint8Array(window.wisqMachine.memory.buffer, at, octets.length).set(octets);
}}

const why = await window.wisqRun();
console.log("arret " + why);
console.log("demandes " + asked.length);
console.log("vues " + asked.join(","));
console.log("rdx " + window.wisqMachine.globals[2].value.toString());
console.log("postes " + stopped.join("|"));
console.log("fenetres " + fenêtres.join(","));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            catalogue = catalogue,
            loaded = loaded,
            pages = PAGES,
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
    // **Et chaque demande porte une fenêtre pleine.** Sans cette ligne, le
    // harnais imprimerait les tailles sans que rien ne les lise — une mesure
    // morte, qui a l'air d'une garde.
    assert_eq!(
        seen("fenetres"),
        "4096,4096,4096",
        "la vue envoie quatre kibioctets par demande"
    );
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

/// **Une application qui ne répond jamais ne doit pas figer la vue en
/// silence.**
///
/// `translate` rend une promesse : dans l'application c'est un aller-retour
/// par message, et rien ne garantit qu'il revienne — l'hôte peut être occupé,
/// avoir planté, ou avoir perdu le message. Sans garde, la promesse n'est
/// jamais tenue, `await` ne rend jamais la main, et l'écran reste tel quel
/// **sans un mot**. C'est le pire mode de panne pour diagnostiquer : rien à
/// lire, rien à chercher.
///
/// Le trou a été trouvé par accident. Le sabotage « la promesse n'est jamais
/// tenue » a bien été attrapé — mais par le **délai du harnais**, pas par le
/// code. Autrement dit, ce qui protégeait était mon outil de test, pas la
/// boucle hôte.
#[test]
fn the_view_gives_up_on_an_application_that_never_answers() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    let scratch = std::env::temp_dir().join(format!("wisq-mute-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};

// **Trois ponts, trois pannes.** Le muet ne répond jamais ; le cassé lève ;
// le lent répond, mais après la patience. Les trois doivent être nommés
// différemment — « ça ne marche pas » n'aide personne à chercher.
const muet = () => new Promise(() => {{}});
const casse = () => {{ throw new Error("le pont est rompu"); }};
const lent = () => new Promise(settle => setTimeout(() => settle(null), 400));

for (const [nom, translate] of [["muet", muet], ["casse", casse], ["lent", lent]]) {{
  const vm = machine({{ translate, pages: 1, patience: 60 }});
  vm.globals[17].value = 0x1000n;
  const began = Date.now();
  const why = await vm.run();
  const took = Date.now() - began;
  console.log(nom + " " + why.stopped + " " + why.at.toString() + " " + (took < 300));
}}

// **Et la patience se désarme.** Une traduction qui arrive à temps ne doit
// pas laisser un réveil derrière elle : dans une machine qui traduit des
// milliers de régions, ça ferait des milliers de minuteries en attente.
const vm = machine({{ translate: async () => null, pages: 1, patience: 60 }});
vm.globals[17].value = 0x1000n;
const why = await vm.run();
console.log("refus " + why.stopped);
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
    // `true` à la fin veut dire « rendu la main en moins de 300 ms » : sans la
    // garde, le muet et le lent n'auraient jamais rendu la main du tout, et le
    // test ne finirait pas.
    assert_eq!(
        seen("muet"),
        "traduction sans réponse 4096 true",
        "un pont muet doit être nommé, et l'adresse avec"
    );
    assert_eq!(
        seen("casse"),
        "traduction en panne 4096 true",
        "un pont qui lève est autre chose qu'un pont muet"
    );
    assert_eq!(
        seen("lent"),
        "traduction sans réponse 4096 true",
        "une réponse qui arrive après la patience ne compte pas"
    );
    assert_eq!(
        seen("refus"),
        "refusée",
        "et un refus franc reste un refus, pas une attente"
    );
}

/// **Une traduction qui arrive à temps ne doit pas laisser un réveil
/// derrière elle.**
///
/// La garde de patience arme une minuterie par traduction. Si elle n'est pas
/// désarmée quand la réponse arrive, une machine qui traduit des milliers de
/// régions laisse des milliers de réveils en attente — invisible à l'œil, et
/// invisible à toutes les assertions de ce fichier : un sabotage qui retire le
/// désarmement y a survécu.
///
/// Ce qui le rend visible est **l'horloge**. Une boucle d'événements ne se
/// ferme pas tant qu'une minuterie est en attente : le programme sort donc
/// tout de suite si les réveils sont désarmés, et attend la patience entière
/// sinon. Le test mesure le temps du processus, pas ce qu'il imprime.
#[test]
fn a_translation_that_arrives_leaves_no_alarm_behind() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    /// Assez long pour que l'attente se voie, assez court pour que le test
    /// n'y passe pas la journée s'il tombe.
    const PATIENCE: u64 = 4000;

    let scratch = std::env::temp_dir().join(format!("wisq-alarm-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut catalogue = String::new();
    for index in 0..3u64 {
        let address = BASE + index * 0x100;
        let next = BASE + ((index + 1) % 3) * 0x100;
        let mut code = vec![0x48, 0xff, 0xc2, 0x48, 0xb8];
        code.extend_from_slice(&next.to_le_bytes());
        code.extend_from_slice(&[0xff, 0xe0]);
        for slot in 0..4u32 {
            let module = Module::resolving(&code, address, 0, slot, PAGES).expect("la région");
            let path = scratch.join(format!("alarm{index}-{slot}.wasm"));
            std::fs::write(&path, &module).expect("le module");
            catalogue.push_str(&format!(
                "[\"{address}:{slot}\",{:?}],",
                path.to_string_lossy()
            ));
        }
    }
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
const catalogue = new Map([{catalogue}]);
const vm = machine({{
  translate: async (address, slot) => {{
    const path = catalogue.get(address + ":" + slot);
    return path === undefined ? null : readFileSync(path);
  }},
  pages: {pages},
  patience: {patience},
}});
vm.globals[{rip}].value = {base}n;
// Trois tours d'un bloc chacun : trois traductions, donc trois réveils armés
// puis désarmés.
await vm.run({{ budget: 1n, rounds: 3 }});
console.log("regions " + vm.known.size);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            catalogue = catalogue,
            pages = PAGES,
            patience = PATIENCE,
            rip = RIP_SLOT,
            base = BASE,
        ),
    )
    .expect("le pilote");

    let began = std::time::Instant::now();
    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let took = began.elapsed();
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(output.status.success(), "le pilote a échoué :\n{text}");
    assert!(
        text.contains("regions 3"),
        "les trois régions doivent avoir été traduites, sinon aucun réveil \
         n'a jamais été armé et le chronomètre ne prouve rien :\n{text}"
    );
    assert!(
        took < std::time::Duration::from_millis(PATIENCE / 2),
        "le programme a mis {took:?} à sortir, pour une patience de {PATIENCE} ms : \
         un réveil n'a pas été désarmé et tient la boucle d'événements ouverte"
    );
}

/// **« Il m'en faut plus » : la vue redemande, une seule fois, plus grand.**
///
/// C'est le comportement neuf de la fenêtre, et le seul qui ne se voie pas
/// dans un module produit : il vit entre deux demandes. Le bouchon répond
/// « encore » au premier appel, puis le module au second — et il **vérifie que
/// la seconde fenêtre est plus grande que la première**, sans quoi une vue qui
/// redemanderait la même chose passerait le test en tournant en rond.
#[test]
fn the_view_asks_again_with_more_bytes_and_only_once() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let scratch = std::env::temp_dir().join(format!("wisq-host-encore-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    // `ud2` seul : la machine s'arrête aussitôt, ce qui rend le compte des
    // demandes lisible sans qu'un anneau ne le brouille.
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

const tailles = [];
// Le premier appel réclame des octets, le second se contente de ce qu'il a.
const traduit = async (_address, _slot, code) => {{
  tailles.push(code.length);
  return tailles.length === 1 ? "encore" : readFileSync({path:?});
}};
const vm = machine({{ translate: traduit, pages: {pages} }});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 8 }});
console.log("demandes " + tailles.length);
console.log("tailles " + tailles.join(","));
console.log("plus grande " + (tailles[1] > tailles[0]));
console.log("arret " + why.stopped);

// **Et quand la seconde fenêtre ne suffit toujours pas**, la vue abandonne au
// lieu de redemander sans fin. Une machine neuve, pour repartir d'un état
// propre.
const jamais = [];
const têtu = async (_address, _slot, code) => {{ jamais.push(code.length); return "encore"; }};
const deux = machine({{ translate: têtu, pages: {pages} }});
deux.globals[{rip}].value = {base}n;
const pourquoi = await deux.run({{ budget: 64n, rounds: 8 }});
console.log("têtu " + jamais.length);
console.log("abandon " + pourquoi.stopped);
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
    assert_eq!(seen("demandes"), "2", "une demande, puis une seule de plus");
    assert_eq!(
        seen("plus grande"),
        "true",
        "redemander la même fenêtre ne servirait à rien"
    );
    assert_eq!(seen("arret"), "sur place", "le `ud2` arrête la machine");
    // **Deux et pas trois.** Une vue qui redemanderait tant qu'on lui répond
    // « encore » tournerait sans fin sur une région vraiment intraduisible.
    assert_eq!(
        seen("têtu"),
        "2",
        "un seul second essai, même si l'application en réclame encore"
    );
    assert_eq!(
        seen("abandon"),
        "refusée",
        "une région qui manque encore de place à seize kibioctets est refusée"
    );
}

/// **L'image de l'invité, convertie pour un dessinateur.**
///
/// Le noyau écrit en XRGB8888 — les octets en mémoire sont `B, G, R, X` —
/// parce que c'est ce que `simpledrm` prend sans conversion. Une `ImageData`
/// veut `R, G, B, A`. Ce test tient les deux choses qu'une recopie naïve
/// casserait, et la seconde est la pire : **l'opacité**. Un cadre passé tel
/// quel arriverait avec un alpha à zéro, c'est-à-dire un écran entièrement
/// transparent — rien à l'écran, et rien qui dise pourquoi.
#[test]
fn the_view_paints_the_guests_frame_in_the_order_a_canvas_expects() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    // Un cadre minuscule, posé loin du début de la RAM : deux pixels suffisent
    // à tenir l'ordre des composantes, et l'adresse non nulle attrape un repli
    // oublié.
    const SCREEN: u64 = 0x2000;
    let scratch = std::env::temp_dir().join(format!("wisq-host-frame-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
const vm = machine({{
  translate: async () => null,
  pages: {pages},
  screen: {{ base: {screen}, width: 2, height: 1 }},
}});

// Deux pixels écrits comme le noyau les écrit : B, G, R, X.
// Le premier est rouge pur, le second bleu pur.
const cadre = new Uint8Array(vm.memory.buffer, {screen}, 8);
cadre.set([0x00, 0x00, 0xff, 0x00,   0xff, 0x00, 0x00, 0x00]);

const sortie = new Uint8ClampedArray(8);
vm.paint(sortie);
console.log("pixels " + Array.from(sortie).join(","));

// Un cadre qui déborderait de la RAM invitée doit être refusé à la
// construction : au-dessus vit la correspondance.
let refuse = "non";
try {{
  machine({{
    translate: async () => null,
    pages: {pages},
    screen: {{ base: {screen}, width: 1024, height: 1024 }},
  }});
}} catch (pourquoi) {{
  refuse = "oui";
}}
console.log("deborde " + refuse);

// Et un tampon trop petit ne se fait pas peindre à moitié.
let court = "non";
try {{ vm.paint(new Uint8ClampedArray(4)); }} catch (pourquoi) {{ court = "oui"; }}
console.log("court " + court);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            pages = PAGES,
            screen = SCREEN,
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
    assert!(output.status.success(), "le pilote a échoué : {complaint}\n{text}");
    let seen = |label: &str| -> String {
        text.lines()
            .find_map(|line| line.strip_prefix(label).map(|rest| rest.trim().to_string()))
            .unwrap_or_else(|| panic!("le pilote n'a pas dit « {label} » :\n{text}"))
    };
    // Rouge pur puis bleu pur, tous deux **opaques**. Sans l'opacité forcée,
    // les deux derniers nombres seraient des zéros et l'écran serait vide.
    assert_eq!(
        seen("pixels"),
        "255,0,0,255,0,0,255,255",
        "les composantes doivent être remises dans l'ordre, et l'opacité forcée"
    );
    assert_eq!(seen("deborde"), "oui", "un cadre hors de la RAM est refusé");
    assert_eq!(seen("court"), "oui", "un tampon trop petit est refusé");
}
