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

use wisq_vm::x86::{ALWAYS_ONE, WRITABLE_FLAGS};
use wisq_vm::x86_wasm::{
    table_slot, Module, CONTROL_SLOT, FAULT_SLOT, FS_BASE_SLOT, GLOBAL_COUNT, GS_SLOT, RFLAGS_SLOT,
    RIP_SLOT, SYSCALL_COUNT, SYSCALL_SLOT, TABLE_ENTRY, TABLE_PAGES, TABLE_SLOTS, TASK_SLOT,
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
    // **Le compteur d'horodatage, que l'hôte fait avancer.** Une case fausse
    // ici ferait avancer autre chose que l'horloge — un registre de segment,
    // par exemple — sans que rien ne s'arrête : le noyau lirait une heure figée
    // et attendrait pour toujours, et un segment porterait un nombre qui monte.
    // Deux défauts silencieux pour une constante recopiée.
    assert_eq!(
        value("tsc"),
        wisq_vm::x86_wasm::TSC_SLOT.to_string(),
        "l'emplacement du compteur d'horodatage"
    );
    // **Ajouté après coup, et c'est l'aveu qui compte.** `rflags` est arrivé
    // dans `SLOTS` avec `pushf`, et il n'était comparé à rien — dans un
    // fichier dont le commentaire affirme que sa répétition l'est. Une case
    // fausse ici ne casserait rien de visible : la boucle poserait le bit
    // réservé sur **une autre globale**, et `pushf` empilerait quelque chose
    // qui n'est pas RFLAGS. Exactement la panne silencieuse que cette
    // comparaison existe pour empêcher.
    assert_eq!(
        value("rflags"),
        wisq_vm::x86_wasm::RFLAGS_SLOT.to_string(),
        "l'emplacement de RFLAGS"
    );
    assert_eq!(
        value("globalCount"),
        GLOBAL_COUNT.to_string(),
        "le nombre de globales"
    );
    // **Les sélecteurs de segment, comparés dès leur arrivée.** La tranche
    // précédente avait laissé `rflags` entrer dans `SLOTS` sans comparaison ;
    // faire entrer deux constantes de plus sans les tenir répéterait la faute
    // le temps d'une tranche.
    assert_eq!(
        value("segment"),
        wisq_vm::x86_wasm::SEGMENT_SLOT.to_string(),
        "le premier sélecteur de segment"
    );
    assert_eq!(
        value("segmentCount"),
        wisq_vm::x86_wasm::SEGMENT_COUNT.to_string(),
        "le nombre de sélecteurs"
    );
    assert_eq!(
        value("table"),
        wisq_vm::x86_wasm::TABLE_SLOT.to_string(),
        "la première table de descripteurs"
    );
    assert_eq!(
        value("tableCount"),
        wisq_vm::x86_wasm::TABLE_COUNT.to_string(),
        "le nombre d'emplacements de table"
    );
    assert_eq!(
        value("fsBase"),
        wisq_vm::x86_wasm::FS_BASE_SLOT.to_string(),
        "la base de FS"
    );
    assert_eq!(
        value("kernelGs"),
        wisq_vm::x86_wasm::KERNEL_GS_SLOT.to_string(),
        "la base que swapgs échange avec celle de GS"
    );
    // **EFER était entré sans comparaison, comme `rflags` avant lui** — dans
    // un test dont le commentaire dit que la répétition est comparée. Le
    // registre de tâche arrive tenu, et EFER l'est enfin.
    assert_eq!(
        value("efer"),
        wisq_vm::x86_wasm::EFER_SLOT.to_string(),
        "l'emplacement d'EFER"
    );
    assert_eq!(value("task"), TASK_SLOT.to_string(), "le registre de tâche");
    assert_eq!(
        value("syscall"),
        SYSCALL_SLOT.to_string(),
        "le premier registre de l'appel système"
    );
    assert_eq!(
        value("syscallCount"),
        SYSCALL_COUNT.to_string(),
        "le nombre de registres de l'appel système"
    );
    assert_eq!(
        value("control"),
        wisq_vm::x86_wasm::CONTROL_SLOT.to_string(),
        "le premier registre de contrôle"
    );
    assert_eq!(
        value("controlCount"),
        wisq_vm::x86_wasm::CONTROL_COUNT.to_string(),
        "le nombre de registres de contrôle"
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

/// **Les MSR : huit numéros modélisés, et un arrêt nommé pour tous les autres.**
///
/// **Le numéro d'un MSR vit dans ECX, pas dans l'instruction.** Le traducteur
/// ne peut donc pas le connaître : « refuser tel MSR » n'est pas une décision
/// de traduction, c'est un aiguillage à l'exécution. C'est ce qui distingue
/// cette tranche des précédentes, et ce qui change le sens du relevé — une
/// région *compilée* n'est plus forcément une région qui *va au bout*.
///
/// **`GS_BASE` n'est pas un aller-retour, c'est un vrai modèle.** L'émetteur
/// consulte déjà cette base à chaque adresse préfixée par `%gs:` — un noyau
/// x86-64 y range tout ce qui est propre à un cœur. L'écrire par `wrmsr` change
/// donc réellement où l'invité lit, et ce test le mesure par un accès mémoire,
/// pas par une relecture de registre.
///
/// **Un numéro qu'on ne modélise pas est une `#GP` à délivrer, et sans porte
/// c'est un arrêt nommé qui porte le numéro.** Ne rien faire serait le pire
/// des choix : le noyau croirait avoir posé une valeur, et la panne tomberait
/// ailleurs. Rendre la main sans témoin — ce que la machine faisait — laissait
/// l'hôte devant un noyau « sur place », et il a fallu désassembler
/// `syscall_init` pour apprendre que c'était `MSR_STAR`. Le témoin porte le
/// numéro dans ses trente-deux bits bas, RIP reste **sur** l'instruction ; ce
/// test n'a pas d'IDT, donc la délivrance ne peut pas avoir lieu et l'arrêt
/// dit le numéro et le vecteur. Le test le vérifie en distinguant l'adresse
/// de celle du `ud2` qui suit — sans quoi « ça s'est arrêté » ne prouverait
/// pas « ça s'est arrêté là ».
#[test]
fn an_unmodelled_model_register_stops_the_machine_where_it_stands() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let head: Vec<u8> = vec![
        0xb8, 0xbe, 0xba, 0xfe, 0xca, // mov $0xcafebabe,%eax
        0x48, 0x89, 0x04, 0x25, 0x10, 0x10, 0x00, 0x00, // mov %rax,0x1010
        0xb9, 0x01, 0x01, 0x00, 0xc0, // mov $0xc0000101,%ecx — GS_BASE
        0xb8, 0x00, 0x10, 0x00, 0x00, // mov $0x1000,%eax — la moitié basse
        // **Une moitié haute non nulle, et c'est délibéré.** Avec une base qui
        // tient sur trente-deux bits, laisser tomber EDX ou oublier le décalage
        // de rdmsr ne se voit nulle part — deux sabotages ont survécu comme ça.
        // L'adresse, elle, est repliée dans la RAM, donc l'accès atterrit au
        // même endroit : la moitié haute ne se lit que par `rdmsr`.
        0xba, 0x00, 0x00, 0xad, 0xde, // mov $0xdead0000,%edx — la moitié haute
        0x0f, 0x30, // wrmsr — la base de GS vaut 0xdead000000001000
        0x65, 0x48, 0x8b, 0x3c, 0x25, 0x10, 0x00, 0x00,
        0x00, // mov %gs:0x10,%rdi — donc 0x1010
        0xb9, 0x01, 0x01, 0x00, 0xc0, // mov $0xc0000101,%ecx
        0x0f, 0x32, // rdmsr
        0x48, 0x89, 0xc6, // mov %rax,%rsi — la valeur relue
        0xb9, 0x23, 0x01, 0x00, 0x00, // mov $0x123,%ecx — un MSR qu'on ne modélise pas
    ];
    // L'adresse où la machine doit s'arrêter : celle du `wrmsr` inconnu, et
    // **pas** celle du `ud2` qui le suit.
    let stops_at = BASE + head.len() as u64;
    let mut program = head;
    program.extend_from_slice(&[0x0f, 0x30]); // wrmsr — numéro inconnu
    program.extend_from_slice(&[0x0f, 0x0b]); // ud2, jamais atteint
    let scratch = std::env::temp_dir().join(format!("wisq-host-msr-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("msr.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("ou " + BigInt.asUintN(64, why.at).toString());
console.log("gs " + lire(7));
console.log("relu " + lire(6));
console.log("haut " + lire(2));
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
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };
    assert_eq!(
        text.lines().next(),
        Some("arret un registre spécifique au modèle que cette machine ne modélise pas (0x123) sans porte : aucune IDT ne porte le vecteur 13"),
        "sans IDT, la #GP ne peut pas être délivrée, et l'arrêt porte le numéro : {text}"
    );
    assert_eq!(
        line("ou "),
        stops_at,
        "et elle s'arrête sur le `wrmsr` inconnu, pas sur le `ud2` d'après"
    );
    // **La preuve que `GS_BASE` est un modèle et non un rangement** : la
    // lecture est passée par la base que `wrmsr` vient d'écrire.
    assert_eq!(
        line("gs "),
        0xcafe_babe,
        "l'accès %gs:0x10 doit être parti de la base posée par wrmsr"
    );
    assert_eq!(
        line("relu "),
        0x1000,
        "et rdmsr rend la moitié basse dans EAX"
    );
    assert_eq!(
        line("haut "),
        0xdead_0000,
        "et la moitié haute dans EDX — les deux moitiés font l'aller-retour"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}
/// **`lretq` doit sauter là où la pile le dit, pas continuer tout droit.**
///
/// Mesuré sur un vrai noyau, et c'est ce qui a mené ici : `secondary_startup_64`
/// finit par `mov %r15,%rdi ; push $retour ; push $0x10 ; push %rax ; lretq`,
/// où `%rax` porte l'adresse de `x86_64_start_kernel` et `%r15` le pointeur
/// vers les `boot_params`. La machine arrivait bien dans
/// `x86_64_start_kernel` — mais avec `RDI = 0`, et la faute tombait vingt
/// fonctions plus loin, dans `copy_bootdata`.
///
/// **La panne qui ressemble à un succès.** Un saut qui n'est pas pris ne
/// s'arrête pas : il continue dans les octets suivants, qui sont du
/// rembourrage, puis du code. La machine finit par retomber sur ses pieds — par
/// une autre route, avec d'autres registres. Rien ne rougit, et la cause est à
/// des milliers d'instructions de l'effet.
///
/// Ce test l'attrape par où il faut : la chute écrit une valeur reconnaissable.
/// Sans elle, « RDI ne vaut pas ce qu'on attend » ne distinguerait pas « le
/// saut n'a pas eu lieu » de « la cible n'a rien fait ».
#[test]
fn a_far_return_lands_where_the_stack_says() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let mut program: Vec<u8> = vec![
        0x48, 0xc7, 0xc4, 0x00, 0xf0, 0x00, 0x00, // mov $0xf000,%rsp — une pile
        0x48, 0xc7, 0xc0, 0x30, 0x00, 0x01, 0x00, // mov $0x10030,%rax — la cible
        // **L'ordre compte, et c'est le noyau qui le donne** : à
        // `secondary_startup_64 + 371` il fait `push $0x10` puis `push %rax`.
        // `lretq` dépile le pointeur d'instruction **en premier**, donc c'est
        // lui qui doit être au sommet, et le sélecteur juste au-dessus. Écrit
        // dans l'autre sens, ce test a d'abord rendu « RIP = 16 » — le
        // sélecteur pris pour une adresse.
        0x6a, 0x10, // push $0x10 — le sélecteur
        0x50, // push %rax — le RIP, dépilé en premier
        0x48, 0xcb, // lretq
        // **La chute**, si le saut n'est pas pris.
        0x48, 0xc7, 0xc7, 0xad, 0xde, 0x00, 0x00, // mov $0xdead,%rdi
        0x0f, 0x0b, // ud2
    ];
    program.resize(0x30, 0x90); // du rembourrage, comme le noyau en pose
    program.extend_from_slice(&[
        0x48, 0xc7, 0xc7, 0x37, 0x13, 0x00, 0x00, // mov $0x1337,%rdi — la cible
        0x0f, 0x0b, // ud2
    ]);
    let scratch = std::env::temp_dir().join(format!("wisq-host-lret-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("lret.wasm");
    std::fs::write(&path, &module).expect("le module");
    // **La cible est une région à part, et elle doit l'être.** `discover` ne
    // peut pas savoir où mène un `lretq` : la cible sort de la pile, à
    // l'exécution. Le module rend donc la main sur elle, et c'est l'hôte qui
    // sert la région d'arrivée — exactement ce que fait le pilote du noyau.
    let arrival =
        Module::resolving(&program[0x30..], BASE + 0x30, 0, 1, PAGES).expect("la cible se traduit");
    let arrival_path = scratch.join("cible.wasm");
    std::fs::write(&arrival_path, &arrival).expect("le module d'arrivée");
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
let asked = 0;
const vm = machine({{
  // **Le bouchon sert par ADRESSE, et refuse tout le reste.** Servi par
  // compteur, il rendait la région d'arrivée à *n'importe quelle* demande —
  // y compris celle qui suit une chute — et l'hôte l'exécutait quand même. Le
  // test passait alors avec le défaut en place : un bouchon complaisant cache
  // ce qu'il devrait montrer.
  translate: async (address) => {{
    asked++;
    if (address === {base}n) return readFileSync({path:?});
    if (address === {base}n + 0x30n) return readFileSync({arrival:?});
    return null;
  }},
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("rdi " + lire(7));
console.log("rip " + lire({rip}));
console.log("rsp " + lire(4));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            arrival = arrival_path.to_string_lossy(),
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
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };
    // **RIP dit où elle est allée**, et c'est ce qui distingue les deux pannes.
    // La cible finit sur un `ud2`, qui laisse RIP sur lui-même : `0x10037`. Une
    // chute laisserait RIP juste après le `lretq`, à `0x10013` — et, dans le
    // vrai noyau, la machine repartirait de là dans le rembourrage.
    assert_ne!(
        line("rip "),
        BASE + 0x13,
        "RIP est juste après le `lretq` : le saut n'a pas été pris, la machine a continué tout droit"
    );
    assert_eq!(
        line("rip "),
        BASE + 0x37,
        "elle doit s'arrêter sur le `ud2` de la cible"
    );
    assert_eq!(
        line("rdi "),
        0x1337,
        "et avoir exécuté la cible que la pile portait"
    );
    // **Seize octets, pas huit.** `lretq` dépile deux mots ; un `ret` ordinaire
    // n'en dépile qu'un. Sans cette assertion, un bras qui n'avance la pile que
    // de huit passe — mesuré : ce sabotage-là survivait.
    assert_eq!(
        line("rsp "),
        0xf000,
        "le `lretq` a consommé ses deux mots, et la pile est revenue où elle était"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **`mov %r15,%rdi` — le préfixe REX qui désigne la source, pas la destination.**
///
/// Mesuré sur un vrai noyau : à l'entrée de `x86_64_start_kernel`, RDI vaut
/// zéro alors que le pointeur vers les `boot_params` avait bien été posé et
/// que R15 le portait encore à l'arrêt. Quatorze octets avant le saut,
/// `secondary_startup_64` fait pourtant `4c 89 ff`.
///
/// Ces trois octets sont un piège de décodage : `4c` est un REX avec **W et R**
/// à un, et `89 ff` un ModRM `mod=11, reg=111, rm=111`. C'est **REX.R** qui
/// étend le champ `reg` — donc la **source** est `r15` — et REX.B qui étendrait
/// `rm`, la destination, qui reste `rdi`. Un décodeur qui applique le mauvais
/// bit lit `mov %rdi,%rdi` : pas une erreur, un **non-événement**, et la valeur
/// disparaît sans que rien ne rougisse.
///
/// Le test tient les deux sens, parce qu'un seul ne distingue pas « la source
/// est juste » de « les deux sont le même registre ».
#[test]
fn a_rex_r_move_reads_the_extended_register_as_its_source() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program: Vec<u8> = vec![
        0x49, 0xc7, 0xc7, 0x00, 0x90, 0x00, 0x00, // mov $0x9000,%r15
        0x4c, 0x89, 0xff, // mov %r15,%rdi — celui du noyau
        0x48, 0xc7, 0xc6, 0x37, 0x13, 0x00, 0x00, // mov $0x1337,%rsi
        0x49, 0x89, 0xf6, // mov %rsi,%r14 — l'autre sens, REX.B cette fois
        0x0f, 0x0b, // ud2
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-rex-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("rex.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("rdi " + lire(7));
console.log("r15 " + lire(15));
console.log("r14 " + lire(14));
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
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };
    assert_eq!(
        line("r15 "),
        0x9000,
        "la constante est bien arrivée dans r15 — sinon le reste ne mesure rien"
    );
    assert_eq!(
        line("rdi "),
        0x9000,
        "REX.R étend le champ reg : la source est r15, la destination reste rdi"
    );
    assert_eq!(
        line("r14 "),
        0x1337,
        "et dans l'autre sens, REX.B étend rm : la destination est r14"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **EFER, quatrième MSR modélisé, et le premier qu'un vrai noyau ait réclamé.**
///
/// Alpine s'arrêtait à `secondary_startup_64_no_verify + 308`, sur `0f 32` avec
/// `rcx = 0xc0000080`. Rien n'était cassé : le numéro n'était pas dans les
/// trois modélisés, le module rendait la main à l'adresse de l'instruction, et
/// l'hôte n'avait rien à répondre. Douze régions traduites, et la machine sur
/// place.
///
/// **La valeur initiale n'est pas zéro, et ce n'est pas une commodité.** Le
/// noyau *lit* EFER, pose ses bits et le *réécrit* — la séquence est
/// `cpuid ; mov $0xc0000080,%ecx ; rdmsr ; …`. Ce qu'il relit doit donc dire la
/// vérité sur la machine, et la vérité est que le long mode est actif : LME
/// (bit 8) et LMA (bit 10). À zéro, le noyau rangerait un EFER qui prétend que
/// la machine n'est pas en 64 bits, et il le relirait plus tard pour décider,
/// entre autres, s'il peut poser le bit NX dans ses tables de pages.
#[test]
fn efer_starts_in_long_mode_and_reads_back_what_was_written() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    // `or $1,%eax` plutôt que `bts $0,%eax` : c'est le même bit SCE, et le
    // `0f ba` du noyau appartient à une autre tranche que celle-ci.
    let program: Vec<u8> = vec![
        0xb9, 0x80, 0x00, 0x00, 0xc0, // mov $0xc0000080,%ecx — EFER
        0x0f, 0x32, // rdmsr
        0x48, 0x89, 0xc7, // mov %rax,%rdi — ce que la machine annonce
        0x83, 0xc8, 0x01, // or $1,%eax — SCE, comme le fait le noyau
        0x0f, 0x30, // wrmsr
        0xb9, 0x80, 0x00, 0x00, 0xc0, // mov $0xc0000080,%ecx
        0x0f, 0x32, // rdmsr
        0x48, 0x89, 0xc6, // mov %rax,%rsi — ce qu'elle rend ensuite
        0x0f, 0x0b, // ud2 — rendre la main pour qu'on puisse lire
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-efer-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("efer.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("avant " + lire(7));
console.log("apres " + lire(6));
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
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };
    assert_eq!(
        line("avant "),
        0x500,
        "la machine est en long mode : LME et LMA, et rien d'autre"
    );
    assert_eq!(
        line("apres "),
        0x501,
        "et le bit que l'invité pose est celui qu'il relit — un registre, pas une constante"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Ici, contrairement aux MSR, le numéro est dans l'instruction.** Il vit
/// dans le champ `reg` du ModRM, que le décodeur lit.
///
/// | | ce qu'on en fait |
/// | --- | --- |
/// | lire CR0, CR2, CR3, CR4, CR8 | rangé et rendu |
/// | écrire CR4, CR8 | accepté : rien ne consulte ces bits |
/// | **écrire CR0 ou CR3** | **accepté depuis que la traduction existe** |
///
/// **Ce test disait le contraire, et il avait raison de le dire.** Écrire CR3
/// était refusé — la région entière ne se traduisait pas — parce que
/// l'accepter aurait fait croire au noyau qu'il a une table de pages sans
/// qu'aucune adresse ne la traverse : une panne loin de sa cause. C'est la
/// traduction, posée par la tranche P2, qui les débloque. Le refus n'était pas
/// une limite qu'on lève, c'était une garde qui a tenu jusqu'à ce que la chose
/// gardée existe.
///
/// **Ce que CR4 et CR8 ne font toujours pas.** Rien ne lit leurs bits : ni le
/// SMEP ni le SMAP. Accepter l'écriture dit « on la range », pas « on
/// l'applique ». CR0 et CR3, eux, sont désormais **lus** — par la marche.
#[test]
fn every_control_register_makes_a_round_trip() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program: Vec<u8> = vec![
        0x48, 0xb8, 0xef, 0xbe, 0xad, 0xde, 0x22, 0x11, 0x00,
        0x00, // movabs $0x1122deadbeef,%rax
        0x0f, 0x22, 0xe0, // mov %rax,%cr4
        0x0f, 0x20, 0xe6, // mov %cr4,%rsi — l'aller-retour
        0x0f, 0x22, 0xd8, // mov %rax,%cr3 — la racine des tables
        0x0f, 0x20, 0xdb, // mov %cr3,%rbx
        0x0f, 0x20, 0xc7, // mov %cr0,%rdi — jamais écrit
        0x0f, 0x0b, // ud2
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-cr-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES)
        .expect("une région qui écrit CR3 se traduit maintenant");
    let path = scratch.join("cr.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("cr4 " + lire(6));
console.log("cr3 " + lire(3));
console.log("cr0 " + lire(7));
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
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };
    assert_eq!(
        text.lines().next(),
        Some("arret refusée"),
        "le `ud2` arrête : {text}"
    );
    assert_eq!(
        line("cr4 "),
        0x1122_dead_beef,
        "CR4 rend les soixante-quatre bits qu'on lui a donnés"
    );
    assert_eq!(
        line("cr3 "),
        0x1122_dead_beef,
        "CR3 aussi, et c'est ce qui a changé"
    );
    // **Un registre jamais écrit vaut zéro**, et deux registres qui
    // partageraient un emplacement se trahiraient ici — CR3 vient d'être
    // écrit avec la même valeur que CR4, donc seul CR0 peut le dire.
    assert_eq!(
        line("cr0 "),
        0,
        "CR0 n'a jamais été écrit : il ne peut porter ni CR4 ni CR3"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **`cli`, `sti` et `hlt` ne font plus refuser la région entière.**
///
/// **D'où ça vient, et c'est une mesure.** `--example kernel-entry` traduit
/// trois régions d'un vrai noyau Alpine puis s'arrête :
/// `0xffffffff810000c6` ne se traduit pas, `CannotTranslate { at: 237 }`.
/// L'octet 237 porte `fa f4 eb fc` — `cli`, `hlt`, et un saut sur soi-même :
/// la boucle d'arrêt que `head_64.S` place au bout de son chemin d'erreur.
///
/// **Une région est refusée en entier**, donc les 237 octets qui précèdent ne
/// s'exécutaient pas non plus — alors que le noyau **atteint** cette région, et
/// que rien ne dit qu'il irait jusqu'à ce `hlt`, qui est au bout d'un chemin
/// d'erreur. La feuille de route l'écrivait déjà : « un refus de traduction
/// n'est pas la preuve que le noyau y serait allé ».
///
/// **Ce qui est produit, et ce qui ne l'est pas.** `cli` et `sti` posent et
/// effacent IF, l'effet architectural exact : un bit, rien de feint. `hlt`,
/// lui, n'est pas simulé — il **s'arrête et le dit**, en posant son témoin et
/// en rendant la main. C'est plus honnête que le refus d'avant, qui affirmait
/// « je ne sais pas traduire ce code » quand la vérité est « je sais, et si
/// l'exécution arrive là je n'ai rien pour la réveiller ».
///
/// `popf` reste refusé : il restaure **tous** les drapeaux, pas seulement IF,
/// et c'est une autre question.
#[test]
fn the_halt_loop_of_a_real_kernel_translates_and_names_its_stop() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program: Vec<u8> = vec![
        0x48, 0xc7, 0xc0, 0x2a, 0x00, 0x00, 0x00, // movq $42, %rax
        0xfb, // sti — IF allumé
        0xfa, // cli — puis éteint
        0xfb, // sti — et rallumé, pour que le drapeau se lise posé
        0xf4, // hlt — l'arrêt qui doit se nommer
        0xeb, 0xfe, // jmp -2 : la boucle où le silicium tournerait
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-hlt-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES)
        .expect("la boucle d'arrêt de head_64.S doit se traduire, pas faire refuser la région");
    let path = scratch.join("hlt.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("rax " + lire(0));
console.log("rflags " + lire({rflags}));
console.log("rip " + lire({rip}));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            rflags = RFLAGS_SLOT,
            base = BASE,
        ),
    )
    .expect("le pilote");
    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };
    // **L'arrêt porte un nom, et ce n'est pas « refusée ».** Un `hlt` sans rien
    // pour réveiller la machine est un fait à énoncer, pas une panne de
    // traduction : les deux ne se corrigent pas au même endroit.
    assert_eq!(
        text.lines().next(),
        Some("arret arrêtée sur hlt"),
        "l'arrêt doit se nommer : {text}"
    );
    // Le début de la région s'exécute — c'est tout ce que le refus d'avant
    // empêchait, et le noyau y arrive.
    assert_eq!(
        line("rax "),
        42,
        "les instructions d'avant le `hlt` tournent"
    );
    // **IF est un vrai bit**, pas un vœu : `sti` le pose, `cli` l'efface, et
    // c'est le dernier des trois qui décide.
    assert_eq!(
        line("rflags ") & (1 << 9),
        1 << 9,
        "le dernier `sti` laisse IF posé : {text}"
    );
    // **RIP est passé le `hlt`.** Sur le silicium, une interruption reprend à
    // l'instruction *suivante* ; laisser RIP sur le `hlt` ferait re-exécuter
    // l'arrêt le jour où quelque chose réveillera la machine.
    assert_eq!(
        line("rip "),
        BASE + 11,
        "RIP doit avoir dépassé le `hlt`, pas rester dessus : {text}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Un sélecteur nul dans FS ou GS n'a besoin d'aucune table.**
///
/// **D'où ça vient.** Après la tranche du `hlt`, `--example kernel-entry`
/// s'arrête plus loin : la quatrième région d'Alpine refuse à l'octet **319**
/// au lieu de 237, et 319 porte `mov %eax,%fs`. Les octets d'avant, décodés :
///
/// ```text
/// 311  31 c0     xor  %eax,%eax
/// 313  8e d8     mov  %eax,%ds     produit — base morte en mode 64 bits
/// 315  8e d0     mov  %eax,%ss     produit
/// 317  8e c0     mov  %eax,%es     produit
/// 319  8e e0     mov  %eax,%fs     refusé
/// ```
///
/// Le refus est écrit avec sa raison : charger FS ou GS relit un descripteur
/// dans la table globale pour en tirer une base, et cette table n'existe pas.
/// **Mais le sélecteur vaut zéro** — le `xor` est juste avant — et un sélecteur
/// nul ne lit aucun descripteur. Le refus était donc, à cet endroit, plus large
/// que sa raison.
///
/// **Ce que le silicium fait du nul, mesuré et pas supposé.** Un programme à
/// syscalls bruts sur le processeur de ce conteneur — la libc entre les deux
/// relevés toucherait errno, qui vit dans le TLS pointé par FS :
///
/// ```text
/// FS.base avant = 0x7f7da625f740
/// xorl %eax,%eax ; movl %eax,%fs
/// FS.base apres = 0x0
/// ```
///
/// La base est **effacée**. C'est ce que l'émetteur produit.
///
/// **Et le non-nul s'arrête au lieu de mentir.** Ranger le sélecteur sans en
/// tirer de base donnerait au noyau une adresse fausse, silencieusement, loin
/// de sa cause — exactement ce que le refus d'origine voulait éviter. Le
/// contrôle est donc à l'exécution : nul, on produit ; non nul, on rend la main
/// en nommant ce qui manque.
#[test]
fn a_null_selector_needs_no_descriptor_and_a_real_one_says_what_is_missing() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    // Ce que fait `head_64.S`, à l'octet près, plus un `hlt` pour finir.
    let null_load: Vec<u8> = vec![
        0x31, 0xc0, // xor  %eax,%eax
        0x8e, 0xd8, // mov  %eax,%ds
        0x8e, 0xd0, // mov  %eax,%ss
        0x8e, 0xc0, // mov  %eax,%es
        0x8e, 0xe0, // mov  %eax,%fs — celui qui refusait
        0x8e, 0xe8, // mov  %eax,%gs
        0xf4, // hlt
    ];
    // Le même, avec un vrai sélecteur : celui-là demande un descripteur.
    let real_load: Vec<u8> = vec![
        0xb8, 0x23, 0x00, 0x00, 0x00, // mov $0x23,%eax
        0x8e, 0xe0, // mov %eax,%fs
        0xf4, // hlt
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-sel-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let run = |nom: &str, program: &[u8]| -> String {
        let module = Module::resolving(program, BASE, 0, 0, PAGES)
            .unwrap_or_else(|| panic!("`{nom}` doit se traduire"));
        let path = scratch.join(format!("{nom}.wasm"));
        std::fs::write(&path, &module).expect("le module");
        let driver = scratch.join(format!("{nom}.mjs"));
        std::fs::write(
            &driver,
            format!(
                r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
let asked = 0;
const vm = machine({{
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
// Une base déjà posée : le chargement nul doit l'effacer, comme le silicium.
vm.globals[{fs}].value = 0x7f0011223344n;
vm.globals[{gs}].value = 0x7f0055667788n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("fsbase " + lire({fs}));
console.log("gsbase " + lire({gs}));
console.log("rip " + lire({rip}));
"#,
                host = workspace_root().join("web/host.js").to_string_lossy(),
                path = path.to_string_lossy(),
                pages = PAGES,
                rip = RIP_SLOT,
                fs = FS_BASE_SLOT,
                gs = GS_SLOT,
                base = BASE,
            ),
        )
        .expect("le pilote");
        let output = Command::new(&bun)
            .arg("run")
            .arg(&driver)
            .output()
            .expect("bun");
        let errors = String::from_utf8_lossy(&output.stderr).to_string();
        assert!(
            errors.is_empty(),
            "`{nom}` ne doit rien écrire en erreur : {errors}"
        );
        String::from_utf8_lossy(&output.stdout).to_string()
    };
    let value = |text: &str, name: &str| -> u64 {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };

    // **Le nul traverse la région entière** et va jusqu'au `hlt`.
    let text = run("nul", &null_load);
    assert_eq!(
        text.lines().next(),
        Some("arret arrêtée sur hlt"),
        "la suite de `head_64.S` doit s'exécuter jusqu'au bout : {text}"
    );
    // Et les deux bases sont effacées, comme sur le processeur mesuré.
    assert_eq!(
        value(&text, "fsbase "),
        0,
        "un sélecteur nul efface FS.base : {text}"
    );
    assert_eq!(value(&text, "gsbase "), 0, "et GS.base aussi : {text}");

    // **Le non-nul s'arrête, et l'arrêt nomme ce qui manque.**
    let text = run("vrai", &real_load);
    assert_eq!(
        text.lines().next(),
        Some("arret un sélecteur non nul dans FS ou GS, sans table de descripteurs"),
        "un vrai sélecteur doit nommer la table absente : {text}"
    );
    // **RIP reste sur l'instruction**, qui n'a rien fait : c'est la seule façon
    // de la rejouer le jour où les descripteurs existeront.
    assert_eq!(
        value(&text, "rip "),
        BASE + 5,
        "RIP doit rester sur le `mov %eax,%fs` : {text}"
    );
    // Et la base n'a pas bougé : on n'invente pas une base qu'on n'a pas lue.
    assert_eq!(
        value(&text, "fsbase "),
        0x7f00_1122_3344,
        "aucune base n'est inventée quand le descripteur manque : {text}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **`popf` : ce qu'un noyau relit doit être ce qu'il a empilé.**
///
/// **D'où ça vient.** Après la tranche du sélecteur nul, la quatrième région
/// d'Alpine refuse à l'octet **400** au lieu de 319, et 400 porte `popfq` :
///
/// ```text
/// 390  b8 33 00 05 80   mov  $0x80050033,%eax
/// 395  0f 22 c0         mov  %rax,%cr0
/// 398  6a 00            push $0
/// 400  9d               popfq            <-- le mur
/// ```
///
/// **La valeur dépilée est un zéro empilé deux octets plus tôt** — la même
/// forme que le sélecteur nul : le cas que le noyau exécute vraiment est celui
/// qui ne demande rien.
///
/// **Et la raison du refus a cessé de tenir.** Elle était écrite à côté de
/// `pushf` : « un module qui accepte `popf` accepte un `sti` déguisé ». C'était
/// juste tant que `sti` était refusé ; il est produit depuis la tranche
/// précédente. L'asymétrie « lire oui, écrire non » n'a plus de raison.
///
/// **Le masque vient du cœur Swift**, où il est décidé et tenu : les bits
/// réservés ne se laissent pas écrire, et le bit 1 vaut toujours un. Un noyau
/// qui relit ce qu'il a empilé doit retrouver la même chose, et les deux cœurs
/// doivent en dire autant — un test à part compare les deux littéraux.
#[test]
fn what_a_kernel_pushes_is_what_it_reads_back() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program: Vec<u8> = vec![
        // Tous les bits à un : le masque doit se voir en entier.
        0x48, 0xc7, 0xc0, 0xff, 0xff, 0xff, 0xff, // movq $-1,%rax
        0x50, // push %rax
        0x9d, // popfq
        0x9c, // pushfq
        0x5b, // pop  %rbx
        // Puis le cas du noyau, à l'octet près : un zéro empilé, dépilé.
        0x6a, 0x00, // push $0
        0x9d, // popfq
        0x9c, // pushfq
        0x59, // pop  %rcx
        0xf4, // hlt
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-popf-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES)
        .expect("`popf` doit se traduire, pas faire refuser la région");
    let path = scratch.join("popf.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
// Une pile qui tient dans la RAM déclarée.
vm.globals[4].value = 0x8000n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("rbx " + lire(3));
console.log("rcx " + lire(1));
console.log("rflags " + lire({rflags}));
console.log("rsp " + lire(4));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            rflags = RFLAGS_SLOT,
            base = BASE,
        ),
    )
    .expect("le pilote");
    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };
    assert_eq!(
        text.lines().next(),
        Some("arret arrêtée sur hlt"),
        "le programme doit aller jusqu'au bout : {text}"
    );
    // **Les bits réservés ne se laissent pas écrire, et le bit 1 vaut un.**
    // Empiler tout à un et relire doit rendre exactement le masque, bit 1
    // compris — pas moins, ce qui perdrait un drapeau, ni plus, ce qui
    // inventerait un état que le silicium n'a pas.
    assert_eq!(
        line("rbx "),
        WRITABLE_FLAGS | ALWAYS_ONE,
        "ce qu'un noyau relit doit être ce que le masque laisse passer : {text}"
    );
    // **Et le cas que le noyau exécute vraiment** : `push $0 ; popfq` laisse
    // RFLAGS à deux, le seul bit que l'architecture impose.
    assert_eq!(
        line("rcx "),
        ALWAYS_ONE,
        "`push $0 ; popfq` laisse le bit réservé seul : {text}"
    );
    assert_eq!(
        line("rflags "),
        ALWAYS_ONE,
        "et la case elle-même le porte : {text}"
    );
    // **Et la pile revient où elle était.**
    //
    // Ce test manquait, et un sabotage l'a montré en survivant : ne pas
    // remonter RSP après un `popf` ne changeait **aucune** valeur lue. Les
    // quatre `push` et les quatre dépilements se décalent ensemble, donc les
    // drapeaux restaient justes pendant que la pile fuyait d'un mot à chaque
    // `popf`. C'est l'assertion qui a l'air d'une garde : elle mesurait
    // l'empreinte — ce qu'on relit — au lieu de l'acte.
    //
    // Le programme empile et dépile quatre fois chacun : RSP doit revenir
    // exactement à son point de départ, ni au-dessus ni en dessous.
    assert_eq!(
        line("rsp "),
        0x8000,
        "quatre empilements et quatre dépilements ramènent RSP à son départ : {text}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Le masque de `popf` est écrit deux fois, et il ne peut pas diverger.**
///
/// Le cœur Swift le porte depuis la tranche du x87 ; l'émetteur le reprend.
/// Deux littéraux dans deux langages, c'est exactement la forme qui a déjà
/// menti dans ce dépôt — d'où cette garde, qui lit le fichier Swift plutôt que
/// de faire confiance à la recopie.
#[test]
fn both_cores_mask_the_same_flag_bits() {
    let swift = workspace_root().join("Sources/WisqVM/X86CoreDispatch.swift");
    let text = std::fs::read_to_string(&swift).expect("le cœur Swift se lit");
    let wanted = format!("0x{:016X}", WRITABLE_FLAGS);
    let underscored = format!(
        "0x{}_{}_{}_{}",
        &wanted[2..6],
        &wanted[6..10],
        &wanted[10..14],
        &wanted[14..18]
    );
    assert!(
        text.contains(&underscored),
        "{} doit porter le masque {underscored} : sinon les deux cœurs \
         répondent deux choses différentes au même `popfq`",
        swift.display()
    );
}

/// **Un invité paginé lit à travers ses tables, et le tampon répond.**
///
/// C'est la tranche P2 : `guest()` ne replie plus, il traduit. Cinq choses
/// sont éprouvées dans un seul programme, parce qu'un sabotage a survécu à
/// chacune d'elles quand le test n'en tenait qu'une :
///
/// | ce que le programme fait | ce que ça tient |
/// | --- | --- |
/// | lit à `VA1 + 0x18` | le décalage dans la page, pas seulement la trame |
/// | réécrit sa propre entrée de table par un alias | **le tampon**, qui doit encore répondre l'ancienne trame |
/// | lit une page dont la trame est **au-dessus de la RAM** | le repliement, qui met le tampon hors de portée de l'invité |
/// | lit à travers une **grande page** de deux mébioctets | le bit PS, qui arrête le parcours au répertoire |
/// | et le même programme sans CR0.PG | le contraste : sans traduction, l'adresse repliée ne porte rien |
///
/// **Le tampon se mesure par ce qui devient faux quand il manque.** L'invité
/// change sa propre entrée de feuille entre deux lectures de la même page :
/// avec tampon, la seconde lecture rend encore l'ancienne trame ; sans, elle
/// suit la nouvelle. Un vrai noyau vide le tampon par `invlpg` — **que cette
/// tranche ne produit pas**, et c'est exactement ce que ce test exhibe.
///
/// **Ce que cette tranche ne fait pas.** La lecture des **instructions** n'est
/// pas paginée : l'hôte résout une région par son adresse telle quelle, donc
/// RIP est traité comme physique. Un noyau à demi-haut, dont le texte vit à
/// `0xffffffff8...`, ne se traduirait pas. Seules les **données** passent par
/// les tables.
#[test]
fn a_paged_guest_reads_through_its_page_tables() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    // Quatre mébioctets, une puissance de deux, que le confinement exige.
    const PAGES: u32 = 64;
    const RAM: u64 = PAGES as u64 * 65536;
    const BASE: u64 = 0x1_0000;
    const PML4: u64 = 0x2_0000;
    const PDPT: u64 = 0x2_1000;
    const PD: u64 = 0x2_2000;
    const PT: u64 = 0x2_3000;
    const FRAME_A: u64 = 0x3_0000;
    const FRAME_B: u64 = 0x3_1000;
    // Repliée sur quatre mébioctets, `VA1` donne `0x201000`, où il n'y a
    // rien : sans traduction, la lecture rendrait zéro.
    const VA1: u64 = 0xFFFF_8000_0020_1000;
    const VA_TABLE: u64 = VA1 + 0x1000; // l'alias sur la table de feuilles
    const VA_ABOVE: u64 = VA1 + 0x2000; // une trame au-dessus de la RAM
    const VA_HUGE: u64 = 0xFFFF_8000_0040_0000; // couverte par une grande page
    const WITNESS_A: u64 = 0x0123_4567_89AB_CDEF;
    const WITNESS_B: u64 = 0x7777_7777_7777_7777;
    const WITNESS_ZERO: u64 = 0x5555_5555_5555_5555;
    const WITNESS_HUGE: u64 = 0x2222_2222_2222_2222;

    let leaf = |at: u64| (at >> 12) & 0x1ff;
    let mut program: Vec<u8> = Vec::new();
    let mut push = |bytes: &[u8]| program.extend_from_slice(bytes);
    push(&[0x48, 0xb8]); // movabs $PML4,%rax
    push(&PML4.to_le_bytes());
    push(&[0x0f, 0x22, 0xd8]); // mov %rax,%cr3
    push(&[0x48, 0xb8]); // movabs $PG,%rax
    push(&(1u64 << 31).to_le_bytes());
    push(&[0x0f, 0x22, 0xc0]); // mov %rax,%cr0
    push(&[0x48, 0xbe]); // movabs $VA1,%rsi
    push(&VA1.to_le_bytes());
    push(&[0x48, 0x8b, 0x56, 0x18]); // mov 0x18(%rsi),%rdx — remplit le tampon
                                     // Réécrire sa propre entrée de feuille, par l'alias.
    push(&[0x48, 0xbf]); // movabs $VA_TABLE,%rdi
    push(&VA_TABLE.to_le_bytes());
    push(&[0x48, 0xb8]); // movabs $(FRAME_B|présente),%rax
    push(&(FRAME_B | 0x3).to_le_bytes());
    push(&[0x48, 0x89, 0x87]); // mov %rax,disp32(%rdi)
    push(&((leaf(VA1) * 8) as u32).to_le_bytes());
    push(&[0x48, 0x8b, 0x5e, 0x18]); // mov 0x18(%rsi),%rbx — le tampon parle-t-il ?
    push(&[0x48, 0xb9]); // movabs $VA_ABOVE,%rcx
    push(&VA_ABOVE.to_le_bytes());
    push(&[0x48, 0x8b, 0x29]); // mov (%rcx),%rbp
    push(&[0x48, 0xbf]); // movabs $VA_HUGE,%rdi
    push(&VA_HUGE.to_le_bytes());
    push(&[0x4c, 0x8b, 0x47, 0x28]); // mov 0x28(%rdi),%r8
    push(&[0x0f, 0x0b]); // ud2 : rendre la main

    // **Le même programme sans la pagination**, pour le contraste : les deux
    // écritures de registre de contrôle remplacées par des `nop`.
    let mut flat = program.clone();
    for at in 0..flat.len() - 2 {
        if flat[at] == 0x0f && flat[at + 1] == 0x22 {
            flat[at..at + 3].copy_from_slice(&[0x90, 0x90, 0x90]);
        }
    }

    let scratch = std::env::temp_dir().join(format!("wisq-host-pg-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module =
        Module::resolving(&program, BASE, 0, 0, PAGES).expect("une région paginée se traduit");
    let path = scratch.join("pg.wasm");
    std::fs::write(&path, &module).expect("le module");
    let sans = Module::resolving(&flat, BASE, 0, 0, PAGES).expect("la même sans pagination");
    let flat_path = scratch.join("flat.wasm");
    std::fs::write(&flat_path, &sans).expect("le module plat");

    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";

// Les tables, posées à la main. Chaque niveau prend neuf bits de l'adresse,
// du haut vers le bas ; la grande page s'arrête au répertoire.
function monter(vm) {{
  const vue = new DataView(vm.memory.buffer);
  const present = 0x3n;                     // présente et inscriptible
  const feuille = (va) => Number((BigInt(va) >> 12n) & 0x1ffn);
  const idx = (va, shift) => Number((BigInt(va) >> BigInt(shift)) & 0x1ffn);
  vue.setBigUint64({pml4} + idx({va1}n, 39) * 8, {pdpt}n | present, true);
  vue.setBigUint64({pdpt} + idx({va1}n, 30) * 8, {pd}n | present, true);
  vue.setBigUint64({pd} + idx({va1}n, 21) * 8, {pt}n | present, true);
  vue.setBigUint64({pt} + feuille({va1}n) * 8, {frameA}n | present, true);
  // L'alias : la table de feuilles vue comme une page de données.
  vue.setBigUint64({pt} + feuille({vaTable}n) * 8, {pt}n | present, true);
  // Une trame juste au-dessus de la RAM : repliée, elle doit tomber sur zéro.
  vue.setBigUint64({pt} + feuille({vaAbove}n) * 8, {ram}n | present, true);
  // **La grande page** : le bit 7 posé sur l'entrée du répertoire.
  vue.setBigUint64({pd} + idx({vaHuge}n, 21) * 8, 0x20_0000n | present | 0x80n, true);

  vue.setBigUint64({frameA} + 0x18, {witnessA}n, true);
  vue.setBigUint64({frameB} + 0x18, {witnessB}n, true);
  vue.setBigUint64(0, {witnessZero}n, true);
  // La grande page couvre 0x200000..0x3fffff ; l'octet visé est à +0x28.
  vue.setBigUint64(0x20_0000 + 0x28, {witnessHuge}n, true);
}}

async function tourner(fichier) {{
  let asked = 0;
  const vm = machine({{
    translate: async () => (asked++ === 0 ? readFileSync(fichier) : null),
    pages: {pages},
  }});
  monter(vm);
  vm.globals[{rip}].value = {base}n;
  const why = await vm.run({{ budget: 256n, rounds: 16 }});
  const lire = (at) => BigInt.asUintN(64, vm.globals[at].value).toString();
  return {{ why, rdx: lire(2), rbx: lire(3), rbp: lire(5), r8: lire(8) }};
}}

const p = await tourner({path:?});
console.log("arret " + p.why.stopped);
console.log("rdx " + p.rdx);
console.log("rbx " + p.rbx);
console.log("rbp " + p.rbp);
console.log("r8 " + p.r8);
const plat = await tourner({flat:?});
console.log("plat " + plat.rdx);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            flat = flat_path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            va1 = VA1,
            vaTable = VA_TABLE,
            vaAbove = VA_ABOVE,
            vaHuge = VA_HUGE,
            pml4 = PML4,
            pdpt = PDPT,
            pd = PD,
            pt = PT,
            frameA = FRAME_A,
            frameB = FRAME_B,
            ram = RAM,
            witnessA = WITNESS_A,
            witnessB = WITNESS_B,
            witnessZero = WITNESS_ZERO,
            witnessHuge = WITNESS_HUGE,
        ),
    )
    .expect("le pilote");
    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    let number = |name: &str| line(name).parse::<u64>().expect("un nombre");
    assert_eq!(line("arret "), "refusée", "le `ud2` arrête : {text}");
    assert_eq!(
        number("rdx "),
        WITNESS_A,
        "la lecture a suivi les tables jusqu'à la trame, décalage compris"
    );
    assert_eq!(
        number("rbx "),
        WITNESS_A,
        "le tampon répond encore l'ancienne trame — l'entrée a pourtant changé"
    );
    assert_eq!(
        number("rbp "),
        WITNESS_ZERO,
        "une trame au-dessus de la RAM est repliée dedans, pas laissée passer"
    );
    assert_eq!(
        number("r8 "),
        WITNESS_HUGE,
        "la grande page s'arrête au répertoire et porte son décalage"
    );
    assert_eq!(
        number("plat "),
        0,
        "pagination éteinte, l'adresse repliée ne porte rien"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Une page absente arrête la machine avant l'accès, et dit où.**
///
/// C'est la moitié du mécanisme que la sonde a tranché : pas de piège — un
/// piège WebAssembly est sans retour — mais un témoin posé, CR2 rempli, et un
/// indice de bloc négatif qui rend la main à l'hôte, comme le fait déjà chaque
/// fin de région.
///
/// **Le contrôle est en ligne, donc avant l'accès**, et c'est ce que la
/// dernière assertion tient : le registre de destination n'a pas bougé. Une
/// instruction qui faute ne doit rien laisser derrière elle, sans quoi le
/// noyau invité ne pourrait pas la rejouer une fois la page posée.
///
/// **RIP nomme l'instruction fautive**, pas la fin du bloc. Il n'était écrit
/// qu'à la terminaison d'un bloc tant que rien ne pouvait s'arrêter au milieu ;
/// la traduction l'oblige à être juste à chaque accès, et son coût a été mesuré
/// avant d'être payé — voir `docs/DEMARRAGE.md`.
///
/// **Et sans IDT, l'arrêt est nommé.** Cette machine n'a chargé aucune table
/// d'interruptions : la faute ne peut être délivrée à personne, et l'hôte le
/// dit — « sans porte » — au lieu de relancer un bloc, retomber sur la même
/// faute, et conclure « sur place ». Une faute délivrée, avec une porte, est
/// le test qui suit.
#[test]
fn a_missing_page_stops_before_the_access_and_names_it() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 64;
    const BASE: u64 = 0x1_0000;
    const PML4: u64 = 0x2_0000;
    const PDPT: u64 = 0x2_1000;
    const PD: u64 = 0x2_2000;
    const PT: u64 = 0x2_3000;
    // Son entrée de feuille n'est jamais posée : aucune table ne la porte.
    const ABSENT: u64 = 0xFFFF_8000_0020_5000;
    const UNTOUCHED: u64 = 0x1111;

    let mut program: Vec<u8> = Vec::new();
    program.extend_from_slice(&[0x48, 0xb8]); // movabs $PML4,%rax
    program.extend_from_slice(&PML4.to_le_bytes());
    program.extend_from_slice(&[0x0f, 0x22, 0xd8]); // mov %rax,%cr3
    program.extend_from_slice(&[0x48, 0xb8]); // movabs $PG,%rax
    program.extend_from_slice(&(1u64 << 31).to_le_bytes());
    program.extend_from_slice(&[0x0f, 0x22, 0xc0]); // mov %rax,%cr0
    program.extend_from_slice(&[0x48, 0xba]); // movabs $UNTOUCHED,%rdx
    program.extend_from_slice(&UNTOUCHED.to_le_bytes());
    program.extend_from_slice(&[0x48, 0xbe]); // movabs $ABSENT,%rsi
    program.extend_from_slice(&ABSENT.to_le_bytes());
    // **L'adresse de l'instruction fautive**, celle que RIP doit porter.
    let faults_at = BASE + program.len() as u64;
    program.extend_from_slice(&[0x48, 0x8b, 0x16]); // mov (%rsi),%rdx
    program.extend_from_slice(&[0x0f, 0x0b]); // ud2, jamais atteint

    let scratch = std::env::temp_dir().join(format!("wisq-host-pf-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("la région se traduit");
    let path = scratch.join("pf.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
// Les trois premiers niveaux existent ; la feuille visée, non.
const vue = new DataView(vm.memory.buffer);
const idx = (va, shift) => Number((BigInt(va) >> BigInt(shift)) & 0x1ffn);
vue.setBigUint64({pml4} + idx({absent}n, 39) * 8, {pdpt}n | 3n, true);
vue.setBigUint64({pdpt} + idx({absent}n, 30) * 8, {pd}n | 3n, true);
vue.setBigUint64({pd} + idx({absent}n, 21) * 8, {pt}n | 3n, true);
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 256n, rounds: 4 }});
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("faute " + lire({fault}));
console.log("cr2 " + lire({cr2}));
console.log("rdx " + lire(2));
console.log("rip " + lire({rip}));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            absent = ABSENT,
            pml4 = PML4,
            pdpt = PDPT,
            pd = PD,
            pt = PT,
            fault = FAULT_SLOT,
            cr2 = CONTROL_SLOT + 1,
        ),
    )
    .expect("le pilote");
    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let number = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };
    // **Le témoin reste posé et l'arrêt le nomme.** Sans IDT il n'y a
    // personne à qui délivrer ; l'hôte ne l'efface pas et ne relance rien.
    assert_ne!(number("faute "), 0, "le témoin de faute est posé : {text}");
    let stopped = text
        .lines()
        .find_map(|l| l.strip_prefix("arret "))
        .unwrap_or_else(|| panic!("le pilote doit dire « arret » : {text}"));
    assert_eq!(
        stopped, "une faute de page sans porte : aucune IDT ne porte le vecteur 14",
        "sans IDT, la faute n'est délivrée à personne et l'arrêt le dit : {text}"
    );
    assert_eq!(
        number("cr2 "),
        ABSENT,
        "CR2 porte l'adresse entière, pas sa page"
    );
    assert_eq!(
        number("rdx "),
        UNTOUCHED,
        "l'accès n'a pas eu lieu : la destination n'a pas bougé"
    );
    assert_eq!(
        number("rip "),
        faults_at,
        "RIP nomme l'instruction fautive, pas la fin du bloc"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **`swapgs` échange deux bases, et n'en écrase aucune.**
///
/// Un noyau x86-64 l'exécute à **chaque** entrée d'anneau : la base de GS
/// pointe l'espace utilisateur, celle du noyau attend dans `KERNEL_GS_BASE`, et
/// l'échange les permute. Un `swapgs` qui écraserait au lieu d'échanger
/// marcherait la première fois et perdrait la base utilisateur au retour.
///
/// Ce test existe parce qu'il manquait : `swapgs` a été produit dans la même
/// tranche que les MSR, et un sabotage — « écraser au lieu d'échanger » — a
/// survécu faute de quoi que ce soit qui l'exerce.
#[test]
fn swapgs_exchanges_the_two_bases_instead_of_overwriting_one() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program = [
        0xb9, 0x01, 0x01, 0x00, 0xc0, // mov $0xc0000101,%ecx — GS_BASE
        0xb8, 0x11, 0x11, 0x00, 0x00, // mov $0x1111,%eax
        0x31, 0xd2, // xor %edx,%edx
        0x0f, 0x30, // wrmsr
        0xb9, 0x02, 0x01, 0x00, 0xc0, // mov $0xc0000102,%ecx — KERNEL_GS_BASE
        0xb8, 0x22, 0x22, 0x00, 0x00, // mov $0x2222,%eax
        0x0f, 0x30, // wrmsr
        0x0f, 0x01, 0xf8, // swapgs
        0xb9, 0x01, 0x01, 0x00, 0xc0, // mov $0xc0000101,%ecx
        0x0f, 0x32, // rdmsr
        0x48, 0x89, 0xc6, // mov %rax,%rsi — GS après l'échange
        0xb9, 0x02, 0x01, 0x00, 0xc0, // mov $0xc0000102,%ecx
        0x0f, 0x32, // rdmsr
        0x48, 0x89, 0xc7, // mov %rax,%rdi — celle du noyau après l'échange
        0x0f, 0x0b, // ud2
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-swapgs-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("swapgs.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("gs " + lire(6));
console.log("noyau " + lire(7));
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
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };
    assert_eq!(
        text.lines().next(),
        Some("arret refusée"),
        "le `ud2` arrête : {text}"
    );
    // **Les deux moitiés de l'échange, séparément.** Vérifier une seule des
    // deux laisserait passer un écrasement : c'est exactement ce qu'un sabotage
    // a fait ici avant que ce test existe.
    assert_eq!(line("gs "), 0x2222, "GS porte maintenant la base du noyau");
    assert_eq!(
        line("noyau "),
        0x1111,
        "et le noyau porte celle qu'avait GS"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Les tables de descripteurs : dix octets qui font l'aller-retour.**
///
/// `lgdt` lit une limite de seize bits et une base de soixante-quatre, `sgdt`
/// les rend. C'est tout ce que cette tranche prétend : le couple est rangé et
/// rendu, dans l'ordre où le processeur le pose — la limite d'abord, la base
/// deux octets plus loin.
///
/// **Ce que ça ne veut pas dire.** Il n'y a toujours aucune table derrière ces
/// nombres, et rien ne les consulte : charger FS ou GS reste refusé, `cli` et
/// `sti` aussi, et aucune interruption n'est délivrée. Un `lgdt` produit ne dit
/// donc pas « les descripteurs marchent » — il dit « ce registre se relit ».
/// Le jour où quelque chose *lira* la table, ce test ne suffira plus, et c'est
/// écrit ici pour qu'on ne s'y trompe pas.
///
/// La table des interruptions est lue sans avoir jamais été chargée, exprès :
/// deux registres qui partageraient un emplacement se trahiraient là.
#[test]
fn a_descriptor_table_register_makes_a_ten_byte_round_trip() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program = [
        0xb8, 0x00, 0x01, 0x00, 0x00, // mov $0x100,%eax — où l'invité pose le descripteur
        0xb9, 0xad, 0xde, 0x00, 0x00, // mov $0xdead,%ecx — la limite
        0x66, 0x89, 0x08, // mov %cx,(%rax)
        0x48, 0xb9, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22,
        0x11, // movabs $0x1122334455667788,%rcx
        0x48, 0x89, 0x48, 0x02, // mov %rcx,2(%rax) — la base, deux octets plus loin
        0x0f, 0x01, 0x10, // lgdt (%rax)
        0xba, 0x00, 0x02, 0x00, 0x00, // mov $0x200,%edx — et on redemande ailleurs
        0x0f, 0x01, 0x02, // sgdt (%rdx)
        0x48, 0x8b, 0x32, // mov (%rdx),%rsi — limite et six octets de base
        0x48, 0x8b, 0x7a, 0x02, // mov 2(%rdx),%rdi — la base entière
        0xbb, 0x00, 0x03, 0x00, 0x00, // mov $0x300,%ebx
        0x0f, 0x01, 0x0b, // sidt (%rbx) — jamais chargée
        0x48, 0x8b, 0x2b, // mov (%rbx),%rbp
        0x0f, 0x0b, // ud2
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-idt-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("table.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("dix " + lire(6));
console.log("base " + lire(7));
console.log("interruptions " + lire(5));
console.log("limite " + lire({limit}));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            limit = wisq_vm::x86_wasm::TABLE_SLOT,
        ),
    )
    .expect("le pilote");
    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };
    assert_eq!(
        text.lines().next(),
        Some("arret refusée"),
        "le `ud2` arrête : {text}"
    );
    // **L'emplacement lui-même, et pas seulement l'aller-retour.** Un sabotage
    // a survécu ici : lire la limite sur soixante-quatre bits laissait six
    // octets de base dans le registre, et le rangement les tronquait — donc
    // l'aller-retour restait juste sur du faux. Ce que l'invité ne peut pas
    // voir, un instantané le verrait.
    assert_eq!(
        line("limite "),
        0xdead,
        "une limite fait seize bits, et le registre n'en garde pas davantage"
    );
    // **La disposition, pas seulement les valeurs.** Ces huit octets couvrent
    // la limite **et** les six premiers de la base : les intervertir, ou les
    // séparer d'un octet de plus, change ce nombre sans changer le suivant.
    assert_eq!(
        line("dix "),
        0x3344_5566_7788_dead,
        "la limite d'abord, la base collée deux octets plus loin"
    );
    assert_eq!(
        line("base "),
        0x1122_3344_5566_7788,
        "et la base entière ressort telle qu'elle est entrée"
    );
    assert_eq!(
        line("interruptions "),
        0,
        "la table des interruptions n'a jamais été chargée : elle ne peut pas porter celle des descripteurs"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Les sélecteurs de segment : un aller-retour, et rien de plus.**
///
/// En mode 64 bits, CS, SS, DS et ES ont une base **forcée à zéro** — le dépôt
/// le tient déjà ailleurs, en montrant que leurs préfixes ne changent aucune
/// adresse. Un sélecteur y est donc un nombre que l'invité range et relit, et
/// c'est précisément ce qui se modélise honnêtement : ce qu'il écrit, il le
/// retrouve.
///
/// **FS et GS sont l'exception, et restent refusés.** Les charger relit un
/// descripteur dans la table globale pour en tirer une base — une table qu'on
/// n'a pas. Les produire ferait croire au noyau qu'on a implémenté des
/// descripteurs, et la panne arriverait bien plus loin que sa cause.
///
/// **La largeur a été mesurée sur un vrai processeur, pas citée de mémoire**,
/// parce que le décodeur enregistrait la même largeur pour deux formes qui
/// n'en ont pas la même :
///
/// | forme | ce que fait le processeur |
/// | --- | --- |
/// | `8c /r` | le sélecteur **zéro-étendu sur 64 bits** |
/// | `66 8c /r` | seulement les seize bits bas, le reste préservé |
///
/// Personne ne l'avait vu : rien ne produisait l'instruction, donc rien ne
/// pouvait s'en plaindre.
#[test]
fn a_segment_selector_makes_a_faithful_round_trip_and_nothing_more() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program = [
        // L'aller-retour, avec un bit **au-delà des seize** : un sélecteur en
        // fait seize, quelle que soit la largeur de l'opérande source, et
        // ranger les trente-deux ferait relire un nombre qu'aucun processeur
        // ne rendrait.
        0xb8, 0x18, 0x00, 0x01, 0x00, // mov $0x10018,%eax
        0x8e, 0xd8, // mov %ax,%ds
        0x8c, 0xd9, // mov %ds,%ecx — sans préfixe : zéro-étendu
        // La zéro-extension : RDX part avec ses bits hauts posés par le pilote,
        // et la forme sans préfixe doit les effacer.
        0x8c, 0xda, // mov %ds,%edx
        // La forme à seize bits : RBX garde ses bits hauts.
        0x66, 0x8c, 0xdb, // mov %ds,%bx
        // Un segment que personne n'a chargé.
        0x8c, 0xc6, // mov %es,%esi
        0x0f, 0x0b, // ud2
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-segment-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("segment.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
vm.globals[2].value = 0xdeadbeef11112222n;  // RDX
vm.globals[3].value = 0xdeadbeef11112222n;  // RBX
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("relu " + lire(1));
console.log("etendu " + lire(2));
console.log("seize " + lire(3));
console.log("jamais " + lire(6));
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
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };
    assert_eq!(
        text.lines().next(),
        Some("arret refusée"),
        "le `ud2` arrête : {text}"
    );
    assert_eq!(
        line("relu "),
        0x18,
        "ce que l'invité range dans DS il le relit, ramené à seize bits"
    );
    assert_eq!(
        line("etendu "),
        0x18,
        "sans préfixe 0x66, le sélecteur est zéro-étendu — les bits hauts partent"
    );
    assert_eq!(
        line("seize "),
        0xdead_beef_1111_0018,
        "avec le préfixe 0x66, seuls les seize bits bas changent"
    );
    // **Zéro veut dire « aucun chargeur n'est passé ici ».** Il n'y a pas de
    // table de descripteurs derrière ces nombres, et rien ne prétend le
    // contraire : la valeur de départ n'est pas une affirmation sur l'état
    // d'amorçage, c'est l'absence d'affirmation.
    assert_eq!(
        line("jamais "),
        0,
        "un segment que personne n'a chargé vaut zéro"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **`cpuid`, et la seule règle qui le rend sûr : ne déclarer que ce qu'on
/// exécute.**
///
/// `cpuid` n'est pas une lecture, c'est une **promesse**. Chaque bit mis dit au
/// noyau « tu peux utiliser ça », et il le croit sur parole — il n'y a pas de
/// second contrôle. Déclarer une extension qu'on n'émule pas ne donne pas une
/// panne franche : ça donne un noyau qui prend un chemin qu'on ne sait pas
/// exécuter, plus loin, sans rapport visible avec la cause.
///
/// D'où le choix : **un zéro partout, sauf ce qui est vrai**. Aujourd'hui il
/// n'y a qu'un bit vrai à déclarer — le compteur d'horodatage, produit depuis
/// la tranche précédente. Tout le reste est à zéro, ce qui veut dire « on ne
/// l'a pas », et c'est exact.
///
/// **Le fournisseur est volontairement inconnu.** Se faire passer pour Intel ou
/// AMD ferait prendre au noyau les contournements d'errata de leurs puces —
/// du code écrit pour des défauts que cette machine n'a pas. Un nom qu'il ne
/// reconnaît pas le renvoie sur son chemin générique, qui est exactement ce
/// qu'on veut.
#[test]
fn cpuid_declares_only_what_the_emitter_actually_does() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    // Le nom du fournisseur sort en trois morceaux — EBX, puis EDX, puis ECX —
    // et il faut les mettre tous les trois à l'abri avant la seconde feuille,
    // sans quoi les deux tiers du nom ne seraient regardés par personne.
    let program = [
        0xb8, 0x00, 0x00, 0x00, 0x00, // mov $0,%eax
        0x0f, 0xa2, // cpuid
        0x48, 0x89, 0xc6, // mov %rax,%rsi — le nombre de feuilles
        0x48, 0x89, 0xdf, // mov %rbx,%rdi — le premier quart du nom
        0x48, 0x89, 0xd5, // mov %rdx,%rbp — le deuxième
        0x49, 0x89, 0xc8, // mov %rcx,%r8  — le troisième
        // Une feuille qu'on ne sert pas : celle du sommet des feuilles
        // étendues, la première que Linux demande après les deux basses. Les
        // quatre registres sont réunis par des `or` pour qu'un seul nombre
        // suffise à dire « rien n'en est sorti ».
        0xb8, 0x00, 0x00, 0x00, 0x80, // mov $0x80000000,%eax
        0x0f, 0xa2, // cpuid
        0x48, 0x09, 0xd8, // or %rbx,%rax
        0x48, 0x09, 0xc8, // or %rcx,%rax
        0x48, 0x09, 0xd0, // or %rdx,%rax
        0x49, 0x89, 0xc1, // mov %rax,%r9
        0xb8, 0x01, 0x00, 0x00, 0x00, // mov $1,%eax
        0x0f, 0xa2, // cpuid
        0x0f, 0x0b, // ud2
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-cpuid-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("cpuid.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("feuilles " + lire(6));
console.log("nom " + lire(7));
console.log("nom2 " + lire(5));
console.log("nom3 " + lire(8));
console.log("inconnue " + lire(9));
console.log("signature " + lire(0));
console.log("edx " + lire(2));
console.log("ecx " + lire(1));
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
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .parse::<u64>()
            .expect("un nombre")
    };
    assert_eq!(
        text.lines().next(),
        Some("arret refusée"),
        "le `ud2` arrête : {text}"
    );
    // **Les valeurs sont écrites en toutes lettres, et c'est délibéré.** Une
    // première version comparait chaque registre à la constante qui le produit
    // — les deux côtés de l'égalité bougeaient ensemble, si bien que déclarer
    // SSE2 ou se faire passer pour Intel laissait le test vert. Un test sur une
    // promesse doit tenir la promesse, pas la répéter.
    assert_eq!(
        line("feuilles "),
        1,
        "la feuille zéro annonce combien il y en a"
    );
    assert_eq!(
        line("nom "),
        0x7173_6977,
        "« wisq » : un fournisseur qu'aucun noyau ne reconnaît, donc aucun contournement d'errata"
    );
    assert_eq!(
        line("nom2 "),
        0x7361_7720,
        "« was », la suite du nom, sortie par EDX"
    );
    assert_eq!(
        line("nom3 "),
        0x6d76_206d,
        "« m vm », la fin du nom, sortie par ECX"
    );
    // **Une feuille qu'on ne sert pas ne rend rien.** Un vrai processeur rend
    // dans ce cas la plus haute feuille qu'il connaît ; nous rendons zéro, et
    // c'est la réponse honnête : zéro à la feuille 0x8000_0000 dit « aucune
    // feuille étendue », ce qui est exactement vrai ici.
    assert_eq!(
        line("inconnue "),
        0,
        "hors des deux feuilles connues, les quatre registres sont nuls"
    );
    assert_eq!(
        line("signature "),
        0x0000_0600,
        "une famille 6 nue, sans modèle ni pas"
    );
    // **Le seul bit vrai, et rien d'autre.** Une capacité déclarée est une
    // promesse : ce test tient l'ensemble exact, pas seulement « le TSC est
    // là ». Un bit de plus le ferait tomber, et c'est le but.
    assert_eq!(
        line("edx "),
        0x10,
        "le bit 4, le compteur d'horodatage, seul : c'est la seule chose qu'on exécute"
    );
    assert_eq!(line("ecx "), 0, "et aucune des extensions récentes");
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Le compteur d'horodatage, et la seule propriété qui compte.**
///
/// **Le temps de l'invité avance avec le travail, et pas seulement avec les
/// lectures.**
///
/// C'est le mensonge que `docs/DEMARRAGE.md` nomme et que cette tranche
/// retire : le compteur n'avançait qu'à chaque `rdtsc`, donc
/// `t0 = rdtsc() ; travail ; t1 = rdtsc()` rendait toujours le même écart. Un
/// noyau qui attend une durée sur cette horloge attend pour toujours — le cœur
/// Swift l'a payé douze secondes de blocage sur « Mounting boot media... »
/// (`Tests/WisqVMTests/X86GuestClockTests.swift`).
///
/// **C'est l'hôte qui avance l'horloge, pas le module**, et c'est un choix
/// mesuré. Le faire dans le module coûterait un ajout par bloc, payé sur tous
/// les modules et pour toujours, au bénéfice d'une instruction que le noyau
/// Alpine exécute vingt-huit fois. La boucle hôte, elle, accorde déjà un budget
/// par tour : elle sait combien de travail elle vient de laisser passer, et
/// l'ajouter ne coûte rien à l'invité. C'est le même endroit que la sonde
/// `--example deliver-probe` a désigné pour la délivrance des interruptions,
/// et pour la même raison.
///
/// **Ce que ce test tient** : deux exécutions du même programme, avec deux
/// budgets différents, ne rendent pas la même heure. Avant cette tranche elles
/// rendaient exactement la même — le compteur ne connaissait que ses lectures.
#[test]
fn the_guest_clock_advances_with_the_work_the_host_let_through() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    // `rdtsc ; ud2` : une lecture, puis la main rendue. Un seul tour de la
    // boucle hôte exécute quelque chose ; le suivant ne trouve plus de région
    // à cette adresse et s'arrête. Le budget est donc accordé une fois, ce qui
    // rend l'écart entre les deux exécutions lisible.
    let program = [0x0f, 0x31, 0x0f, 0x0b];
    let scratch = std::env::temp_dir().join(format!("wisq-host-clock-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("clock.wasm");
    std::fs::write(&path, &module).expect("le module");

    let read = |budget: u64| -> u64 {
        let driver = scratch.join(format!("d{budget}.mjs"));
        std::fs::write(
            &driver,
            format!(
                r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
let asked = 0;
const vm = machine({{
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
await vm.run({{ budget: {budget}n, rounds: 8 }});
console.log(BigInt.asUintN(64, vm.globals[{tsc}].value).toString());
"#,
                host = workspace_root().join("web/host.js").to_string_lossy(),
                path = path.to_string_lossy(),
                pages = PAGES,
                rip = RIP_SLOT,
                base = BASE,
                budget = budget,
                tsc = wisq_vm::x86_wasm::TSC_SLOT,
            ),
        )
        .expect("le pilote");
        let output = Command::new(&bun)
            .arg("run")
            .arg(&driver)
            .output()
            .expect("bun doit démarrer");
        let errors = String::from_utf8_lossy(&output.stderr).to_string();
        assert!(
            errors.is_empty(),
            "le pilote ne doit rien écrire en erreur : {errors}"
        );
        String::from_utf8_lossy(&output.stdout)
            .trim()
            .parse()
            .expect("une heure lisible")
    };

    let small = read(64);
    let large = read(1024);
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        large > small,
        "deux budgets différents doivent rendre deux heures différentes — \
         petit {small}, grand {large} : l'horloge ne connaît que ses lectures"
    );
    // **L'écart est exactement la différence des budgets**, et le dire vaut
    // mieux qu'une simple inégalité : une horloge qui avancerait d'un montant
    // arbitraire passerait l'inégalité tout en étant fausse.
    assert_eq!(
        large - small,
        1024 - 64,
        "un tour a laissé passer un budget : l'écart doit être celui des budgets"
    );
}

/// `rdtsc` est la deuxième instruction que l'émetteur produit, et son choix de
/// conception tient en une phrase : **un compteur virtuel, pas un import**.
///
/// L'autre voie était d'appeler l'hôte pour une vraie horloge, au prix d'un
/// retour de main — 125 à 190 ns, mesuré. Elle n'achète pourtant rien : le
/// noyau calibre la fréquence de son TSC contre une **autre** horloge, un PIT
/// ou un HPET, dont cette machine n'a aucun. La calibration est donc fausse
/// dans les deux cas, et la voie chère ne l'est pas moins.
///
/// **Ce qui décide vraiment est ailleurs, et c'est une question de blocage.**
/// Un noyau écrit `while (rdtsc() - début < n)`. Si deux lectures successives
/// rendaient la même valeur, cette boucle ne se terminerait **jamais** — une
/// machine qui pend, le pire mode de panne, indiscernable d'un calcul long.
/// Le compteur avance donc à **chaque lecture**, strictement, et c'est ce que
/// ce test tient.
///
/// **Ce que ce test ne tient pas, et son voisin s'en charge** : que le temps
/// avance avec le *travail*. Le module ne connaît que ses lectures ; c'est
/// l'hôte qui ajoute le budget accordé à chaque tour, et
/// `the_guest_clock_advances_with_the_work_the_host_let_through` le tient.
#[test]
fn the_timestamp_counter_always_moves_forward() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    // Un compteur qui déborde franchement les trente-deux bits bas.
    const SEED: u64 = 0x1234_5678_9abc_def0;
    // rdtsc ; mov %rax,%rbx ; rdtsc ; ud2
    let program = [
        0x0f, 0x31, // rdtsc
        0x48, 0x89, 0xc3, // mov %rax,%rbx
        0x0f, 0x31, // rdtsc
        0x0f, 0x0b, // ud2
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-rdtsc-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("tsc.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
// **Le compteur part au-dessus de deux puissance trente-deux**, et c'est ce
// qui rend le test capable de voir quelque chose : avec un petit compteur, la
// moitié haute est nulle, donc masquer RAX ou ne pas le masquer donne le même
// résultat. Un premier essai l'a laissé petit, et le sabotage du masque a
// survécu — un test qui ne peut pas distinguer n'est pas une garde.
vm.globals[{tsc}].value = {seed}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
console.log("arret " + why.stopped);
console.log("avant " + BigInt.asUintN(64, vm.globals[3].value).toString());
console.log("apres " + BigInt.asUintN(64, vm.globals[0].value).toString());
console.log("haut " + BigInt.asUintN(64, vm.globals[2].value).toString());
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            tsc = wisq_vm::x86_wasm::TSC_SLOT,
            seed = SEED,
        ),
    )
    .expect("le pilote");
    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    assert_eq!(line("arret "), "refusée", "la région s'arrête sur le `ud2`");
    let avant: u64 = line("avant ").parse().expect("un nombre");
    let apres: u64 = line("apres ").parse().expect("un nombre");
    assert!(
        apres > avant,
        "deux lectures successives doivent croître, sinon `while (rdtsc() - début < n)` \
         ne se termine jamais : {avant} puis {apres}"
    );
    // **RAX ne porte que les trente-deux bits bas.** `rdtsc` écrit EAX, et le
    // processeur met la moitié haute de RAX à zéro ; la laisser passer
    // donnerait un compteur faux d'un facteur 2³², qu'un noyau lirait sans se
    // plaindre.
    assert!(
        apres < 1 << 32,
        "RAX ne doit porter que la moitié basse : {apres:#x}"
    );
    let expected = SEED.wrapping_add(2 * wisq_vm::x86_wasm::TSC_STEP);
    assert_eq!(apres, expected & 0xffff_ffff, "et c'est celle du compteur");
    // **La moitié haute part dans RDX, et pas ailleurs.**
    let haut: u64 = line("haut ").parse().expect("un nombre");
    assert_eq!(
        haut,
        expected >> 32,
        "RDX porte la moitié haute : {haut:#x}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **`pushf` produit, et le bit réservé qui ne ment plus.**
///
/// C'est la première instruction qu'un émetteur *refusait* et qu'il *produit*.
/// Elle est arrivée par un relevé, pas par une relecture : `coverage` a mis un
/// nombre en face d'un nom — six régions perdues pour `pushf` — et ce nom
/// n'aurait jamais dû être dans la liste. `popf` peut rallumer le drapeau
/// d'interruption sans nommer `sti`, donc il reste refusé ; `pushf` ne fait que
/// **lire** RFLAGS, qui est déjà modélisé, et ne peut rien rallumer. Je l'avais
/// refusé par symétrie, et la symétrie n'existait pas.
///
/// **Et produire cette lecture a rendu visible une divergence entre les deux
/// cœurs.** Le bit 1 de RFLAGS vaut toujours un sur x86 — l'interpréteur Rust
/// le pose (`Flags::read` rend `… | ALWAYS_ONE`), et l'oracle matériel le
/// porte. La boucle hôte, elle, partait de zéro et rien ne le posait jamais.
/// Tant que personne ne *lisait* RFLAGS comme une valeur, ça ne se voyait pas ;
/// le premier `pushf` aurait empilé un RFLAGS qu'aucun processeur ne produit.
///
/// Le test regarde donc les deux moitiés : la pile a bien descendu de huit, et
/// ce qui y est écrit porte le bit que l'architecture garantit.
#[test]
fn a_guest_that_pushes_its_flags_writes_a_real_rflags() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    const TOP: u64 = 0x1000;
    // mov $0x1000, %rsp ; pushfq ; ud2
    let program = [
        0x48, 0xc7, 0xc4, 0x00, 0x10, 0x00, 0x00, // mov $0x1000, %rsp
        0x9c, // pushfq
        0x0f, 0x0b, // ud2 — la machine s'arrête là, et le dit
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-pushf-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("pushf.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
// La pile de l'invité est repliée dans la RAM comme toute adresse.
const octets = new DataView(vm.memory.buffer);
console.log("arret " + why.stopped);
console.log("rsp " + BigInt.asUintN(64, vm.globals[4].value).toString(16));
console.log("empile " + octets.getBigUint64({empile}, true).toString(16));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            empile = TOP - 8,
        ),
    )
    .expect("le pilote");
    let output = Command::new(&bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun doit démarrer");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire sur la sortie d'erreur : {errors}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    assert_eq!(line("arret "), "refusée", "la région s'arrête sur le `ud2`");
    assert_eq!(
        line("rsp "),
        format!("{:x}", TOP - 8),
        "`pushf` descend la pile de huit octets"
    );
    let empile = u64::from_str_radix(&line("empile "), 16).expect("un nombre");
    assert_ne!(
        empile & wisq_vm::x86::ALWAYS_ONE,
        0,
        "le bit 1 de RFLAGS vaut toujours un sur x86 : {empile:#x}"
    );
    // Et rien d'impossible autour : aucun des bits que ce cœur ne modélise pas
    // ne doit apparaître de nulle part. Le drapeau d'interruption en fait
    // partie — rien n'en délivre, donc il est à zéro, et c'est cohérent.
    assert_eq!(
        empile & !(wisq_vm::x86::ALWAYS_ONE | wisq_vm::x86::ARITHMETIC | wisq_vm::x86::DF),
        0,
        "RFLAGS ne doit porter que ce que ce cœur modélise : {empile:#x}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Un invité qui parle, et un hôte qui l'entend.**
///
/// C'est la première fois que quelque chose sort de la machine autrement que
/// par des pixels. Le programme est écrit à la main et fait ce que fait la
/// console d'un noyau au tout début de son démarrage, avant que le moindre
/// pilote existe : charger le port dans `dx`, l'octet dans `al`, et `out`.
///
/// **Ce que ce test prouve et que rien d'autre ne pouvait prouver.** Les tests
/// Rust de l'émetteur lisent les octets du module : ils disent que `env.out`
/// est déclaré à la bonne place, pas qu'un moteur l'appelle avec les bons
/// arguments. Ici le module est compilé par JavaScriptCore, lié à l'hôte, et
/// exécuté. Si le port, la valeur ou la largeur étaient poussés dans le mauvais
/// ordre, le moteur ne s'en plaindrait pas — les trois sont des `i64` — et
/// c'est la chaîne reçue qui ne serait pas « hi ».
#[test]
fn a_guest_that_writes_to_the_serial_port_is_heard() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    // mov $0x3f8, %dx ; mov $'h', %al ; out %al, %dx
    //                 ; mov $'i', %al ; out %al, %dx ; ud2
    let program = [
        0x66, 0xba, 0xf8, 0x03, // mov $0x3f8, %dx
        0xb0, b'h', // mov $'h', %al
        0xee, // out %al, %dx
        0xb0, b'i', // mov $'i', %al
        0xee, // out %al, %dx
        0x0f, 0x0b, // ud2 — la machine s'arrête là, et le dit
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-serial-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("hi.wasm");
    std::fs::write(&path, &module).expect("le module");
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
let said = "";
let asked = 0;
const vm = machine({{
  // La région s'arrête sur le `ud2`, et la machine redemande à cette
  // adresse-là. Reservir le même module l'installerait à un emplacement où il
  // n'a pas de bloc ; un refus est ce que l'application répondrait vraiment
  // pour une instruction qu'elle ne sait pas traduire.
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
  serial: byte => {{ said += String.fromCharCode(byte); }},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
console.log("dit " + said);
console.log("arret " + why.stopped);
console.log("ou " + why.at.toString(16));
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
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        output.status.success(),
        "le pilote a échoué :\n{text}\n{errors}"
    );
    let seen = |label: &str| -> String {
        text.lines()
            .find_map(|line| line.strip_prefix(label).map(|rest| rest.trim().to_string()))
            .unwrap_or_else(|| panic!("le pilote n'a pas dit « {label} » :\n{text}"))
    };
    assert_eq!(seen("dit"), "hi", "les deux octets, dans l'ordre");
    // Et la machine s'est arrêtée là où le programme s'arrête : sur le `ud2`,
    // dix octets après le début. Sans cette ligne, un « hi » dit deux fois par
    // une machine qui boucle passerait pour un succès.
    assert_eq!(seen("arret"), "refusée");
    assert_eq!(seen("ou"), format!("{:x}", BASE + 10), "sur le `ud2`");
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
/// **`wisqRun` est la dernière chose que le pilote installe, et c'est un
/// contrat que le côté Swift lit sans le savoir.**
///
/// `LocalDesktop.load()` attend que `window.wisqRun` soit une fonction pour
/// déclarer la page prête. Cette attente n'a de sens que si `wisqRun` arrive
/// **après** tout le reste : la machine, l'écran, les fonctions de peinture.
/// Sinon elle rendrait la main sur un pilote à moitié monté, et l'appel
/// suivant partirait dans le vide — exactement la panne qu'on a mis trois
/// tours de CI à nommer.
///
/// **Pourquoi ce contrat compte maintenant.** La page charge son pilote dans un
/// `<script type="module">`, donc évalué après l'analyse du document. Un
/// `didFinish` peut arriver avant. Interroger la page une seule fois à cet
/// instant-là est une course, et elle se perd d'autant plus volontiers que le
/// module a plus à faire — c'est-à-dire quand il y a un canvas.
///
/// Le test est écrit sur la forme **avec** écran, celle qui a le plus à
/// installer, et il vérifie l'ordre plutôt qu'une présence : `contains` seul
/// serait satisfait par un pilote qui pose `wisqRun` en premier.
#[test]
fn the_driver_installs_wisq_run_last_of_all() {
    for screen in [
        None,
        Some(wisq_vm::desktop::Screen {
            base: 0x8000,
            width: 32,
            height: 16,
        }),
    ] {
        let driver = wisq_vm::desktop::driver(1, 0x1000, "wisq", screen);
        let run = driver
            .find("window.wisqRun =")
            .expect("le pilote installe `wisqRun`");
        for earlier in [
            "window.wisqMachine =",
            "window.wisqAfficher =",
            "window.wisqCesser =",
            "window.wisqTranslated =",
            "window.wisqNeedsMore =",
        ] {
            let at = driver
                .find(earlier)
                .unwrap_or_else(|| panic!("le pilote installe `{earlier}`"));
            assert!(
                at < run,
                "`{earlier}` doit être posé avant `wisqRun` : sa présence est ce qui \
                 dit que tout le reste est monté"
            );
        }
    }
}

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
    let driver_source = wisq_vm::desktop::driver(PAGES, BASE, "wisq", None);
    let page = wisq_vm::desktop::page(PAGES, BASE, "wisq", None).expect("la page");
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
    use wisq_vm::desktop::{page, Refusal, Screen};
    assert_eq!(
        page(3, 0x1000, "wisq", None),
        Err(Refusal::RamIsNotAPowerOfTwo(3)),
        "la RAM d'un invité confiné est une puissance de deux"
    );
    assert_eq!(
        page(0, 0x1000, "wisq", None),
        Err(Refusal::RamIsNotAPowerOfTwo(0))
    );
    for name in ["", "wisq; alert(1)", "wisq.autre", "wisq-2", "a b", "é"] {
        assert_eq!(
            page(1, 0x1000, name, None),
            Err(Refusal::ChannelIsNotAName(name.to_string())),
            "« {name} » ne peut pas être recollé dans du JavaScript"
        );
    }
    for name in ["wisq", "w", "canal2"] {
        assert!(page(1, 0x1000, name, None).is_ok(), "« {name} » est un nom");
    }

    // **Le cadre, contre la même frontière que tout le reste de ce lot.** Une
    // RAM d'une page fait 65 536 octets, et la correspondance vit juste
    // au-dessus : un cadre à cheval sur ce bord afficherait la table des blocs
    // à l'écran tout en la détruisant. La borne est vérifiée **à l'octet
    // près**, des deux côtés — sans le cas qui passe, un refus qui refuserait
    // tout aurait l'air d'une garde.
    let ram = 65536u64;
    let juste = Screen {
        base: 0,
        width: 128,
        height: 128,
    };
    assert_eq!(
        u64::from(juste.width) * u64::from(juste.height) * 4,
        ram,
        "ce cadre doit remplir la RAM exactement, sinon le test ne borde rien"
    );
    assert!(
        page(1, 0x1000, "wisq", Some(juste)).is_ok(),
        "un cadre qui remplit la RAM au dernier octet tient"
    );
    assert_eq!(
        page(1, 0x1000, "wisq", Some(Screen { base: 4, ..juste })),
        Err(Refusal::ScreenDoesNotFit {
            folded: 4,
            bytes: ram,
            ram
        }),
        "quatre octets plus loin, il déborde"
    );
    // Et l'adresse est **repliée**, comme partout ailleurs : un cadre déclaré
    // très haut dans l'espace invité retombe au même endroit.
    assert!(
        page(
            1,
            0x1000,
            "wisq",
            Some(Screen {
                base: ram * 7,
                ..juste
            })
        )
        .is_ok(),
        "l'adresse du cadre se replie comme celle du code"
    );
    for creux in [(0, 64), (64, 0), (0, 0)] {
        assert_eq!(
            page(
                1,
                0x1000,
                "wisq",
                Some(Screen {
                    base: 0,
                    width: creux.0,
                    height: creux.1,
                })
            ),
            Err(Refusal::ScreenHasNoSurface {
                width: creux.0,
                height: creux.1
            }),
            "un cadre de {}×{} n'a pas de surface",
            creux.0,
            creux.1
        );
    }

    // **Un cadre dont la surface déborde d'un entier de soixante-quatre bits.**
    // `largeur × hauteur × 4` sur deux entiers de trente-deux bits vaut jusqu'à
    // deux puissance soixante-six : en release, la multiplication enroule en
    // silence et peut retomber sur un petit nombre — c'est-à-dire qu'un cadre
    // impossible serait **accepté**. Vu en écrivant la même garde en Swift,
    // pas en relisant celle-ci.
    for (width, height) in [(u32::MAX, u32::MAX), (1 << 31, 1 << 31), (1 << 20, 1 << 20)] {
        assert!(
            matches!(
                page(
                    1,
                    0x1000,
                    "wisq",
                    Some(Screen {
                        base: 0,
                        width,
                        height
                    })
                ),
                Err(Refusal::ScreenDoesNotFit { .. })
            ),
            "un cadre de {width}×{height} doit être refusé, pas enroulé"
        );
    }

    // **Le canvas est dans la page, et seulement quand un cadre est déclaré.**
    // Une page qui en porterait un sans cadre montrerait un rectangle vide que
    // rien ne peindrait.
    let avec = page(1, 0x1000, "wisq", Some(juste)).expect("la page avec cadre");
    assert!(
        avec.contains("<canvas id=\"wisqEcran\" width=\"128\" height=\"128\">"),
        "le canvas doit porter les dimensions du cadre"
    );
    assert!(avec.contains("window.wisqPaint"), "et de quoi le peindre");
    let sans = page(1, 0x1000, "wisq", None).expect("la page sans cadre");
    assert!(
        !sans.contains("<canvas"),
        "sans cadre, pas de canvas : {sans}"
    );
    assert!(
        !sans.contains("window.wisqPaint ="),
        "et rien qui prétende peindre"
    );

    // Et le refus se lit : un message qui ne nomme pas ce qu'il refuse envoie
    // chercher la cause ailleurs.
    assert!(
        Refusal::RamIsNotAPowerOfTwo(3).to_string().contains('3'),
        "le refus doit nommer le nombre refusé"
    );
    assert!(
        Refusal::ScreenDoesNotFit {
            folded: 4,
            bytes: 65536,
            ram: 65536
        }
        .to_string()
        .contains("65536"),
        "et celui du cadre doit nommer la RAM qu'il déborde"
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
    assert!(
        output.status.success(),
        "le pilote a échoué : {complaint}\n{text}"
    );
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

/// **La boucle rend-elle jamais la main ?**
///
/// La question est venue en dessinant le canvas, pas en relisant du code.
/// Peindre demande que quelque chose d'autre que la machine puisse tourner :
/// un `requestAnimationFrame`, un toucher, un timer. Or `run()` n'attend que
/// sur `translate`. Une fois toutes les régions connues — c'est-à-dire dès la
/// fin du démarrage, pour un noyau — la boucle enchaîne les tours sans jamais
/// repasser par la boucle d'événements. **La vue serait gelée**, et le canvas
/// afficherait éternellement sa première image.
///
/// Ce test mesure exactement ça : un timer armé pendant que la machine tourne
/// a-t-il eu son tour avant que `run()` ne rende la main ? La réponse était
/// non, et rien ne l'aurait dit avant un appareil.
///
/// **Un `await` ne suffit pas.** Attendre une promesse déjà tenue ne cède
/// qu'aux micro-tâches ; les timers et `requestAnimationFrame` sont des
/// *tâches*, et n'y passent pas. C'est pourquoi le harnais compte des timers
/// et pas des `Promise.resolve()`.
#[test]
fn the_machine_lets_the_page_breathe_while_it_runs() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la respiration de la boucle ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    const STRIDE: u64 = 0x100;
    const LINKS: u64 = 3;

    // Le même anneau de trois maillons que la découverte : chacun saute
    // indirectement au suivant, donc les trois sont des régions distinctes, et
    // une fois traduites l'anneau tourne **sans plus rien demander**. C'est le
    // régime établi, celui où la famine se produit.
    let region = |index: u64| -> Vec<u8> {
        let mut code = vec![0x48, 0xc7, 0xc0];
        code.extend_from_slice(&(index as u32 + 1).to_le_bytes()); // movq $n, %rax
        code.extend_from_slice(&[0x48, 0x01, 0xc2]); // addq %rax, %rdx
        code.extend_from_slice(&[0x48, 0xb8]);
        code.extend_from_slice(&(BASE + ((index + 1) % LINKS) * STRIDE).to_le_bytes());
        code.extend_from_slice(&[0xff, 0xe0]); // jmp *%rax
        code
    };

    let scratch = std::env::temp_dir().join(format!("wisq-souffle-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut catalogue = String::new();
    let mut loaded = String::new();
    for index in 0..LINKS {
        let address = BASE + index * STRIDE;
        let code = region(index);
        let raw = scratch.join(format!("souffle{index}.bin"));
        std::fs::write(&raw, &code).expect("le code de la région");
        loaded.push_str(&format!(
            "[{},{:?}],",
            address & u64::from(PAGES * 65536 - 1),
            raw.to_string_lossy()
        ));
        for slot in 0..4u32 {
            let module = Module::resolving(&code, address, 0, slot, PAGES)
                .unwrap_or_else(|| panic!("l'émetteur doit compiler la région {index}"));
            let path = scratch.join(format!("souffle{index}-{slot}.wasm"));
            std::fs::write(&path, &module).expect("le module");
            catalogue.push_str(&format!(
                "[\"{address}:{slot}\",{:?}],",
                path.to_string_lossy()
            ));
        }
    }

    let driver = scratch.join("s.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";

const catalogue = new Map([{catalogue}]);
const posé = new Map(
  [{loaded}].map(([at, path]) => [at, new Uint8Array(readFileSync(path))]),
);
const translate = async (address, slot, code) => {{
  if (!(code instanceof Uint8Array) || code.length === 0) {{
    throw new Error("la demande ne porte pas d'octets");
  }}
  const path = catalogue.get(address + ":" + slot);
  return path === undefined ? null : readFileSync(path);
}};

const vm = machine({{ translate, pages: {pages} }});
for (const [at, octets] of posé) {{
  new Uint8Array(vm.memory.buffer, at, octets.length).set(octets);
}}
vm.globals[{rip}].value = {base}n;

// **Découverte d'abord.** Les trois traductions passent par l'application, et
// chacune rend la main : ce n'est pas là que la famine se produit.
await vm.run({{ budget: 1000n, rounds: {links} }});
if (vm.known.size !== {links}) throw new Error("les trois régions doivent être connues");

// **Régime établi.** Plus rien à traduire ; à partir d'ici, tout ce que la
// boucle rend à la page, elle le rend de son plein gré.
//
// Le même travail est fait **deux fois** : une fois avec la respiration par
// défaut, une fois avec `breath: Infinity`, c'est-à-dire jamais. Le second
// tour est le sabotage inscrit dans le test : sans lui, un compteur de
// battements qui monterait tout seul aurait l'air d'une garde.
async function régime(souffle) {{
  vm.globals[{rip}].value = {base}n;
  vm.globals[2].value = 0n;
  let battements = 0;
  // Un timer qui se réarme : c'est le plus fidèle tenant-lieu de « la page
  // peut faire quoi que ce soit » — `requestAnimationFrame`, un toucher, un
  // timer sont tous des tâches, et ils passent ou ne passent pas ensemble.
  let vivant = true;
  const battre = () => {{ if (!vivant) return; battements++; setTimeout(battre, 0); }};
  setTimeout(battre, 0);
  const départ = performance.now();
  const fin = await vm.run({{ budget: {budget}n, rounds: {rounds}, breath: souffle }});
  const durée = performance.now() - départ;
  vivant = false;
  return {{ battements, durée, stopped: fin.stopped, rdx: vm.globals[2].value }};
}}

const respiré = await régime(8);
const apnée = await régime(Infinity);
console.log("arret " + respiré.stopped);
console.log("battements " + respiré.battements);
console.log("duree " + Math.round(respiré.durée));
console.log("apnee " + apnée.battements);
console.log("duree-apnee " + Math.round(apnée.durée));
console.log("rdx " + respiré.rdx.toString());
console.log("rdx-apnee " + apnée.rdx.toString());
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            catalogue = catalogue,
            loaded = loaded,
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            links = LINKS,
            // **Le travail est découpé en tours larges, exprès.** Sept
            // millions et demi de blocs sont nécessaires pour que le régime
            // dure assez longtemps qu'un timer ait sa chance ; les découper en
            // sept millions et demi de tours rendrait le sabotage « respirer à
            // chaque tour » indiscernable d'un blocage — vingt-huit minutes au
            // lieu d'une assertion. En mille cinq cents tours, il échoue en
            // deux secondes, et il le dit.
            budget = 20_000,
            rounds = 1_500,
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
    let breathing: u64 = seen("duree").parse().expect("la durée en millisecondes");
    let holding: u64 = seen("duree-apnee").parse().expect("la durée en apnée");
    let beats: u64 = seen("battements").parse().expect("les battements");
    let held: u64 = seen("apnee").parse().expect("les battements en apnée");

    // **Le même travail des deux côtés.** Sans cette ligne, une respiration
    // qui écourterait la boucle passerait pour un gain de réactivité.
    assert_eq!(
        seen("rdx"),
        seen("rdx-apnee"),
        "les deux régimes doivent avoir fait exactement le même travail"
    );
    assert_eq!(
        seen("arret"),
        "tours épuisés",
        "l'anneau tourne jusqu'au bout"
    );

    // **Le test ne veut rien dire si le travail est court.** Cent
    // millisecondes valent douze respirations : en dessous, un zéro
    // n'accuserait personne.
    assert!(
        breathing >= 100,
        "le régime doit durer assez pour qu'un timer ait sa chance : {breathing} ms"
    );

    // **La famine, mesurée.** En apnée, la page n'a pas eu un seul tour de
    // toute la durée du régime. C'est l'état dans lequel la boucle était, et
    // il aurait gelé le canvas dès la fin du démarrage.
    assert_eq!(
        held, 0,
        "en apnée, la page ne doit avoir aucun tour — sinon ce test ne mesure \
         pas ce qu'il croit ({holding} ms)"
    );
    assert!(
        beats >= 1,
        "en respirant, la page doit avoir eu son tour : {beats} battements en \
         {breathing} ms"
    );

    // **Et la respiration ne doit pas coûter le débit.** Elle se règle sur le
    // temps et non sur les tours : à un souffle par tour, ce régime en
    // paierait un million et demi au lieu d'une trentaine. La comparaison est
    // un rapport et non un seuil, parce qu'un runner lent reste un runner
    // honnête.
    assert!(
        breathing < holding * 3 + 100,
        "respirer ne doit pas tripler le temps de calcul : {breathing} ms \
         contre {holding} ms en apnée"
    );
}

/// **L'écran de la page, et la seule chose qui prouve qu'il vit.**
///
/// `vm.paint` était jugé sur un tampon rendu au test. Ici c'est la page
/// entière qui est jugée : le canvas que `desktop::page` déclare, le contexte
/// que le pilote demande, l'`ImageData` qu'il réutilise, et la boucle
/// `requestAnimationFrame` qui appelle `wisqPaint`.
///
/// **Trois choses distinctes, et aucune ne prouve les autres.**
/// 1. `wisqPaint` peint **sans** boucle d'affichage. C'est délibéré : un
///    `WKWebView` construit sans être ajouté à une fenêtre — exactement ce que
///    fait `LocalDesktopTests` — pourrait ne recevoir aucune image de rendu, et
///    un test qui en attendrait une n'aurait rien à attendre.
/// 2. La boucle peint **pendant** que la machine tourne. C'est ce que la
///    respiration de `run()` rend possible, et rien d'autre ne le vérifie
///    bout à bout.
/// 3. `wisqCesser` peint **une dernière fois**. Sans ça, la dernière image
///    montrée serait celle d'avant l'arrêt : on regarderait un écran qui n'est
///    pas l'état dans lequel la machine s'est arrêtée.
///
/// **Le faux canvas refuse ce que la vraie page ne pourrait pas faire** : un
/// `putImageData` avec autre chose que l'`ImageData` que ce contexte a rendue —
/// un vrai navigateur lève — et une image plus grande que le canvas, où une
/// vraie page **tronque en silence**, ce qui est pire qu'une erreur.
#[test]
fn the_pages_driver_paints_the_screen_while_the_machine_runs() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : l'écran de la page ne serait vérifié par rien.");
    };
    const PAGES: u32 = 2;
    const RAM: u64 = PAGES as u64 * 65536;
    const BASE: u64 = 0x1_0000;
    // Le cadre vit **en bas** de la RAM, le code au-dessus : sans cette
    // séparation, l'invité peindrait son propre code et le test mesurerait un
    // écrasement plutôt qu'un affichage.
    const FRAME: u64 = 0;
    const WIDTH: u32 = 2;
    const HEIGHT: u32 = 2;

    // Chaque maillon écrit une couleur dans le premier pixel, puis saute au
    // suivant. C'est ce qui distingue « le canvas montre l'invité » de « le
    // canvas montre ce que le harnais a posé avant de démarrer ».
    let region = |colour: u32, target: u64| -> Vec<u8> {
        let mut code = vec![0x48, 0xb8];
        code.extend_from_slice(&FRAME.to_le_bytes()); // movq $cadre, %rax
        code.push(0xbb);
        code.extend_from_slice(&colour.to_le_bytes()); // movl $couleur, %ebx
        code.extend_from_slice(&[0x89, 0x18]); // movl %ebx, (%rax)
        code.extend_from_slice(&[0x48, 0xb8]);
        code.extend_from_slice(&target.to_le_bytes());
        code.extend_from_slice(&[0xff, 0xe0]); // jmp *%rax
        code
    };
    // **XRGB8888** : les octets en mémoire sont B, G, R, X, donc un mot de
    // trente-deux bits en petit-boutien porte le rouge en troisième octet.
    const ROUGE: u32 = 0x00ff_0000;
    const BLEU: u32 = 0x0000_00ff;
    let programs: [(u64, Vec<u8>); 3] = [
        (BASE, region(ROUGE, BASE + 0x100)),
        (BASE + 0x100, region(BLEU, BASE)),
        (BASE + 0x200, vec![0x0f, 0x0b]), // ud2, pour l'arrêt de la phase 3
    ];

    let scratch = std::env::temp_dir().join(format!("wisq-ecran-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut catalogue = String::new();
    let mut loaded = String::new();
    for (index, (address, code)) in programs.iter().enumerate() {
        loaded.push_str(&format!("[\"{address}\",{code:?}],"));
        for slot in 0..6u32 {
            let module = Module::resolving(code, *address, 0, slot, PAGES).unwrap_or_else(|| {
                panic!(
                    "l'émetteur doit compiler la région {index} — si elle écrit en \
                     mémoire et qu'il refuse, c'est le programme d'essai qu'il faut \
                     changer, pas le test"
                )
            });
            let path = scratch.join(format!("ecran{index}-{slot}.wasm"));
            std::fs::write(&path, &module).expect("le module");
            catalogue.push_str(&format!(
                "[\"{address}:{slot}\",{:?}],",
                path.to_string_lossy()
            ));
        }
    }

    let driver_source = wisq_vm::desktop::driver(
        PAGES,
        BASE,
        "wisq",
        Some(wisq_vm::desktop::Screen {
            base: FRAME,
            width: WIDTH,
            height: HEIGHT,
        }),
    );
    let harness = scratch.join("e.mjs");
    std::fs::write(
        &harness,
        format!(
            r#"
import {{ machine, SLOTS }} from {host:?};
import {{ readFileSync }} from "fs";

const catalogue = new Map([{catalogue}]);
const posé = new Map([{loaded}]);

// **Le faux canvas, et ce qu'il refuse.** Un bouchon complaisant dirait « oui »
// à tout et laisserait passer précisément ce qu'un navigateur refuse.
const images = [];
const sienne = Symbol("ImageData de ce contexte");
const contexte = {{
  createImageData(w, h) {{
    if (w !== {width} || h !== {height}) {{
      throw new Error(`une ImageData de ${{w}}×${{h}} pour un canvas de {width}×{height}`);
    }}
    return {{ [sienne]: true, width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }};
  }},
  putImageData(image, x, y) {{
    // Un vrai navigateur lève sur autre chose qu'une ImageData : un objet
    // `{{ data, width, height }}` fabriqué à la main marcherait ici et nulle
    // part ailleurs.
    if (image === null || typeof image !== "object" || image[sienne] !== true) {{
      throw new Error("putImageData n'accepte qu'une ImageData de ce contexte");
    }}
    // Une vraie page **tronque en silence** une image plus grande que son
    // canvas. Un écran amputé se met sur le compte du noyau ; une erreur, non.
    if (image.width > {width} || image.height > {height}) {{
      throw new Error(`une image de ${{image.width}}×${{image.height}} déborde du canvas`);
    }}
    if (x !== 0 || y !== 0) throw new Error("le cadre se pose à l'origine");
    images.push(Array.from(image.data).join(","));
  }},
}};
const toile = {{
  width: {width},
  height: {height},
  getContext: (kind) => (kind === "2d" ? contexte : null),
}};
globalThis.window = globalThis;
globalThis.document = {{
  // Un vrai document rend `null` pour un identifiant qu'il ne porte pas.
  getElementById: (id) => (id === "wisqEcran" ? toile : null),
}};
// `requestAnimationFrame` n'existe pas sous Bun ; une vraie page en a un. Ce
// qui compte ici est qu'il soit une **tâche** — comme le vrai —, donc qu'il ne
// tourne que si la boucle de la machine rend la main.
// **Et il refuse une boucle emballée.** Une vraie page ne dirait rien d'une
// boucle d'affichage qui survit à la machine : elle repeindrait le même écran
// soixante fois par seconde jusqu'à la fermeture, en silence. Ce plafond-là
// transforme un gaspillage muet — qui, sous ce harnais, ferait tourner Bun
// sans fin plutôt qu'échouer — en un fait qu'on peut lire.
let dessins = 0;
let emballée = 0;
globalThis.requestAnimationFrame = (fn) => {{
  if (++dessins > {plafond}) {{ emballée = 1; return 0; }}
  return setTimeout(fn, 0);
}};

const stopped = [];
globalThis.webkit = {{
  messageHandlers: {{
    wisq: {{
      postMessage: note => {{
        if (note.kind === "arrêt") {{ stopped.push(note.stopped); return; }}
        const brut = atob(note.octets);
        const attendu = posé.get(note.address);
        if (attendu !== undefined) {{
          for (let at = 0; at < attendu.length; at++) {{
            if (brut.charCodeAt(at) !== attendu[at]) {{
              throw new Error("la fenêtre ne porte pas le code de " + note.address);
            }}
          }}
        }}
        setTimeout(() => {{
          const path = catalogue.get(note.address + ":" + note.slot);
          window.wisqTranslated(note.id, path === undefined ? null : [...readFileSync(path)]);
        }}, 0);
      }},
    }},
  }},
}};

{driver}

const laVM = window.wisqMachine;
for (const [adresse, octets] of posé) {{
  const at = Number(BigInt(adresse) & BigInt({ram} - 1));
  new Uint8Array(laVM.memory.buffer, at, octets.length).set(octets);
}}

// Une couleur que l'invité n'écrit jamais, pour distinguer « le canvas montre
// ce que le harnais a posé » de « le canvas montre l'invité ».
const VERT = 0x0000ff00;
const cadre = new Uint32Array(laVM.memory.buffer, {frame}, {width} * {height});
cadre.fill(VERT);

// **Phase 1 : peindre sans boucle d'affichage.**
console.log("pixels " + window.wisqPaint());
console.log("manuelle " + images[images.length - 1]);

// **Phase 2 : peindre pendant que la machine tourne.**
const avant = images.length;
window.wisqAfficher();
await laVM.run({{ budget: {budget}n, rounds: {rounds} }});
const pendant = images.length - avant;
// **Cesser doit peindre exactement une fois de plus**, et c'est mesuré ici
// plutôt que déduit de la couleur finale : la boucle d'affichage peut très
// bien avoir déjà peint le même état, et une assertion sur la couleur serait
// alors satisfaite sans que `wisqCesser` ait rien fait. Un sabotage l'a
// montré.
const avantCesser = images.length;
window.wisqCesser();
console.log("cesser " + (images.length - avantCesser));
console.log("pendant " + pendant);
console.log("invite " + images[images.length - 1]);
// **Et la boucle doit s'être arrêtée.** Une boucle d'affichage qui survit à la
// machine repeindrait le même écran soixante fois par seconde, pour rien,
// jusqu'à ce que l'application se ferme.
const aprèsCesser = images.length;
await new Promise((fin) => setTimeout(fin, 50));
console.log("apres " + (images.length - aprèsCesser));
console.log("emballee " + emballée);

// **Phase 3 : `wisqRun` peint une dernière fois après l'arrêt.**
const BLANC = 0x00ffffff;
cadre.fill(BLANC);
laVM.globals[SLOTS.rip].value = {stop}n;
const pourquoi = await window.wisqRun();
console.log("arret " + pourquoi + " " + stopped.join(","));
console.log("finale " + images[images.length - 1]);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            catalogue = catalogue,
            loaded = loaded,
            ram = RAM,
            frame = FRAME,
            width = WIDTH,
            height = HEIGHT,
            budget = 20_000,
            rounds = 1_500,
            // Le régime peint quelques centaines d'images ; ce plafond est
            // loin au-dessus, et n'est atteint que par une boucle qui ne
            // s'arrête pas.
            plafond = 3_000,
            stop = BASE + 0x200,
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

    // **Phase 1.** Quatre pixels verts, dans l'ordre qu'un canvas attend :
    // R, G, B, A — et l'opacité **forcée**, sans quoi l'écran serait
    // entièrement transparent, c'est-à-dire indistinguable d'une machine qui
    // n'a pas démarré.
    assert_eq!(
        seen("manuelle"),
        ["0,255,0,255"; 4].join(","),
        "wisqPaint doit peindre sans qu'aucune image de rendu n'ait été demandée"
    );
    // **Et elle rend le compte de pixels.** Une fonction qui ne rend rien ne se
    // distingue pas d'une fonction qui n'a rien fait, et c'est la seule chose
    // que l'application pourra lire depuis l'autre côté du pont.
    assert_eq!(
        seen("pixels"),
        (WIDTH * HEIGHT).to_string(),
        "wisqPaint doit dire combien de pixels elle a peints"
    );

    // **Phase 2.** La boucle a bien tourné pendant que la machine tournait.
    let during: u32 = seen("pendant").parse().expect("les images peintes");
    assert!(
        during >= 2,
        "la boucle d'affichage doit peindre pendant que la machine tourne, \
         pas seulement à l'arrêt : {during} images"
    );
    // **Et `wisqCesser` peint, lui, exactement une fois.** Mesuré et non déduit
    // d'une couleur : la boucle peut avoir déjà peint le même état, et une
    // assertion sur la couleur finale serait alors verte sans que `wisqCesser`
    // ait rien fait. C'est ce qu'un sabotage a montré.
    assert_eq!(
        seen("cesser"),
        "1",
        "wisqCesser doit peindre une dernière image, et une seule"
    );
    // **Et la boucle s'arrête vraiment.** Une boucle qui survit à la machine
    // repeindrait le même écran soixante fois par seconde jusqu'à la fermeture
    // de l'application.
    assert_eq!(
        seen("apres"),
        "0",
        "plus rien ne doit être peint après l'arrêt de la boucle"
    );
    assert_eq!(
        seen("emballee"),
        "0",
        "la boucle d'affichage ne doit jamais s'emballer"
    );
    // Et le premier pixel porte une couleur de l'invité, pas celle du harnais.
    let guest = seen("invite");
    let first = guest.split(',').take(4).collect::<Vec<_>>().join(",");
    assert!(
        first == "255,0,0,255" || first == "0,0,255,255",
        "le canvas doit montrer ce que l'invité a écrit, pas le vert du \
         harnais : {first}"
    );
    // Les trois autres pixels n'ont pas été touchés par l'invité : ils sont
    // restés verts. Sans cette ligne, un `paint` qui écraserait tout d'une
    // seule couleur passerait.
    assert!(
        guest.ends_with(&["0,255,0,255"; 3].join(",")),
        "l'invité n'a écrit qu'un pixel : {guest}"
    );

    // **Phase 3.** L'arrêt remonte, et l'image d'après l'arrêt est celle de
    // l'arrêt.
    assert_eq!(seen("arret"), "sur place sur place", "le `ud2` arrête tout");
    assert_eq!(
        seen("finale"),
        ["255,255,255,255"; 4].join(","),
        "wisqCesser doit peindre l'état dans lequel la machine s'est arrêtée"
    );
}

/// **Une page qui n'arrive pas à s'installer doit le dire.**
///
/// Le script du module peut lever : un canvas absent du corps, un contexte 2d
/// refusé, une RAM que la boucle hôte n'accepte pas. La vue finit quand même
/// de charger — `didFinish` ne dit rien de ce que le script a fait — et sans
/// trace, l'application ne l'apprendrait que plusieurs appels plus loin, par le
/// symptôme.
///
/// Le pilote retient donc sa raison dans `window.wisqFailure`. **Et c'est une
/// garde que rien ne tenait** : elle a été écrite pour diagnostiquer un échec
/// de la CI, ce qui est précisément le moment où l'on ajoute du code qu'aucun
/// test ne juge.
#[test]
fn a_page_that_cannot_install_itself_says_so() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : cette garde ne serait vérifiée par rien.");
    };
    let scratch = std::env::temp_dir().join(format!("wisq-panne-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");

    // Un cadre déclaré, et **aucun canvas dans le corps**. C'est exactement ce
    // qui arriverait si la page et le pilote divergeaient.
    let driver_source = wisq_vm::desktop::driver(
        1,
        0x1000,
        "wisq",
        Some(wisq_vm::desktop::Screen {
            base: 0,
            width: 8,
            height: 8,
        }),
    );
    let harness = scratch.join("p.mjs");
    std::fs::write(
        &harness,
        format!(
            r#"
import {{ machine, SLOTS }} from {host:?};
globalThis.window = globalThis;
globalThis.webkit = {{ messageHandlers: {{ wisq: {{ postMessage: () => {{}} }} }} }};
globalThis.requestAnimationFrame = (fn) => setTimeout(fn, 0);
// Le document ne porte pas le canvas que la page déclarerait.
globalThis.document = {{ getElementById: () => null }};

{driver}

console.log("raison " + window.wisqFailure);
console.log("run " + typeof window.wisqRun);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
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

    // **Le pilote ne doit pas emporter la page avec lui.** Une exception qui
    // remonte jusqu'au module laisse la vue sans rien à interroger ; retenue,
    // elle se lit.
    assert!(
        output.status.success(),
        "le pilote doit retenir sa panne, pas la laisser sortir : {complaint}\n{text}"
    );
    let seen = |label: &str| -> String {
        text.lines()
            .find_map(|line| line.strip_prefix(label).map(|rest| rest.trim().to_string()))
            .unwrap_or_else(|| panic!("le harnais n'a pas dit « {label} » :\n{text}"))
    };
    assert!(
        seen("raison").contains("canvas"),
        "la raison doit nommer ce qui manque : « {} »",
        seen("raison")
    );
    // Et `wisqRun` ne doit pas exister : une page à moitié montée qui offrirait
    // quand même de démarrer est pire qu'une page qui refuse.
    assert_eq!(
        seen("run"),
        "undefined",
        "une page qui n'a pas fini de s'installer ne doit pas offrir de démarrer"
    );
}

/// **Le montage d'une machine qui a une IDT** — partagé par les deux tests de
/// délivrance, parce qu'ils ne diffèrent que par la pile.
///
/// Trois régions, servies **par adresse et par créneau** : le programme qui
/// faute, le gestionnaire, et la reprise sur l'instruction fautive — un `iretq`
/// atterrit au milieu de la première région, donc l'hôte en demande une qui
/// commence là. Le bouchon refuse tout le reste, adresse ou créneau : servi
/// par compteur, il a déjà fait survivre un sabotage.
struct FaultRig {
    program: Vec<u8>,
    handler: Vec<u8>,
    faults_at: u64,
    ud2_at: u64,
}

const RIG_PAGES: u32 = 64;
const RIG_BASE: u64 = 0x1_0000;
const RIG_HANDLER: u64 = 0x1_1000;
const RIG_IDT: u64 = 0x1_2000;
const RIG_IDT_POINTER: u64 = 0x1_3000;
const RIG_PML4: u64 = 0x2_0000;
const RIG_PDPT: u64 = 0x2_1000;
const RIG_PD: u64 = 0x2_2000;
const RIG_PT: u64 = 0x2_3000;
const RIG_PDPT_LOW: u64 = 0x2_4000;
const RIG_PD_LOW: u64 = 0x2_5000;
const RIG_FRAME: u64 = 0x3_0000;
/// Sa feuille n'est pas posée : c'est le gestionnaire qui la posera.
const RIG_ABSENT: u64 = 0xFFFF_8000_0020_5000;
const RIG_WITNESS: u64 = 0x0BAD_CAFE_F00D_1234;
const RIG_AFTER: u64 = 0x1111;

fn fault_rig(stack: u64) -> FaultRig {
    fn put(into: &mut Vec<u8>, bytes: &[u8]) {
        into.extend_from_slice(bytes);
    }
    let mut program: Vec<u8> = Vec::new();
    put(&mut program, &[0x48, 0xb8]); // movabs $PML4,%rax
    put(&mut program, &RIG_PML4.to_le_bytes());
    put(&mut program, &[0x0f, 0x22, 0xd8]); // mov %rax,%cr3
    put(&mut program, &[0x48, 0xb8]); // movabs $PG,%rax
    put(&mut program, &(1u64 << 31).to_le_bytes());
    put(&mut program, &[0x0f, 0x22, 0xc0]); // mov %rax,%cr0
    put(&mut program, &[0x48, 0xbb]); // movabs $IDT_POINTER,%rbx
    put(&mut program, &RIG_IDT_POINTER.to_le_bytes());
    put(&mut program, &[0x0f, 0x01, 0x1b]); // lidt (%rbx)
    put(&mut program, &[0x48, 0xbc]); // movabs $stack,%rsp
    put(&mut program, &stack.to_le_bytes());
    put(&mut program, &[0x48, 0xbe]); // movabs $ABSENT,%rsi
    put(&mut program, &RIG_ABSENT.to_le_bytes());
    put(&mut program, &[0xfb]); // sti — pour que l'entrée ait quelque chose à éteindre
    let faults_at = RIG_BASE + program.len() as u64;
    put(&mut program, &[0x48, 0x8b, 0x16]); // mov (%rsi),%rdx — faute, puis rejouée
    put(&mut program, &[0x48, 0xc7, 0xc3]); // mov $AFTER,%rbx — la preuve que ça continue
    put(&mut program, &(RIG_AFTER as u32).to_le_bytes());
    let ud2_at = RIG_BASE + program.len() as u64;
    put(&mut program, &[0x0f, 0x0b]); // ud2

    // **Le gestionnaire fait ce que fait `early_make_pgtable`** : il pose la
    // feuille manquante, jette le code d'erreur, et rend la main par `iretq`.
    // CR2 est lu dans RAX pour que le test voie ce que l'invité a vu.
    let leaf = (RIG_ABSENT >> 12) & 0x1ff;
    let mut handler: Vec<u8> = Vec::new();
    put(&mut handler, &[0x0f, 0x20, 0xd0]); // mov %cr2,%rax
    put(&mut handler, &[0x9c]); // pushfq — les drapeaux **dans** le gestionnaire
    put(&mut handler, &[0x41, 0x58]); // pop %r8
    put(&mut handler, &[0x48, 0xb9]); // movabs $(FRAME|présente|inscriptible),%rcx
    put(&mut handler, &(RIG_FRAME | 0x3).to_le_bytes());
    put(&mut handler, &[0x48, 0xbf]); // movabs $(PT + feuille*8),%rdi
    put(&mut handler, &(RIG_PT + leaf * 8).to_le_bytes());
    put(&mut handler, &[0x48, 0x89, 0x0f]); // mov %rcx,(%rdi)
    put(&mut handler, &[0x48, 0x83, 0xc4, 0x08]); // add $8,%rsp — le code d'erreur
    put(&mut handler, &[0x48, 0xcf]); // iretq
    FaultRig {
        program,
        handler,
        faults_at,
        ud2_at,
    }
}

/// Le pilote commun : les tables, l'IDT, et les trois régions par adresse.
fn fault_driver(rig: &FaultRig, scratch: &Path, prints: &str) -> PathBuf {
    let modules = [
        ("programme.wasm", &rig.program[..], RIG_BASE, 0u32),
        ("gestionnaire.wasm", &rig.handler[..], RIG_HANDLER, 1),
        (
            "reprise.wasm",
            &rig.program[(rig.faults_at - RIG_BASE) as usize..],
            rig.faults_at,
            2,
        ),
    ];
    let mut served = String::new();
    for (name, bytes, at, slot) in modules {
        let module = Module::resolving(bytes, at, 0, slot, RIG_PAGES)
            .unwrap_or_else(|| panic!("{name} se traduit"));
        let path = scratch.join(name);
        std::fs::write(&path, &module).expect(name);
        served.push_str(&format!(
            "    if (address === {at}n && slot === {slot}) return readFileSync({:?});\n",
            path.to_string_lossy()
        ));
    }
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
let asked = 0;
const vm = machine({{
  translate: async (address, slot) => {{
    asked++;
{served}    return null;
  }},
  pages: {pages},
}});
const vue = new DataView(vm.memory.buffer);
const present = 0x3n;
const idx = (va, shift) => Number((BigInt(va) >> BigInt(shift)) & 0x1ffn);
// L'identité sur les quatre premiers mébioctets, en deux grandes pages : le
// code, les tables, l'IDT et la pile y vivent.
vue.setBigUint64({pml4} + 0 * 8, {pdptLow}n | present, true);
vue.setBigUint64({pdptLow} + 0 * 8, {pdLow}n | present, true);
vue.setBigUint64({pdLow} + 0 * 8, 0n | present | 0x80n, true);
vue.setBigUint64({pdLow} + 1 * 8, 0x20_0000n | present | 0x80n, true);
// Les trois niveaux au-dessus de la page absente ; la feuille, non.
vue.setBigUint64({pml4} + idx({absent}n, 39) * 8, {pdpt}n | present, true);
vue.setBigUint64({pdpt} + idx({absent}n, 30) * 8, {pd}n | present, true);
vue.setBigUint64({pd} + idx({absent}n, 21) * 8, {pt}n | present, true);
vue.setBigUint64({frame}, {witness}n, true);
// La porte 14 : une porte d'interruption (0x0E), présente, sélecteur 0x10,
// sans pile d'interruption, vers le gestionnaire.
const porte = (offset) => {{
  const low = (BigInt(offset) & 0xffffn) | (0x10n << 16n) | (0x0en << 40n) | (1n << 47n)
    | ((BigInt(offset) & 0xffff0000n) << 32n);
  return [low, BigInt(offset) >> 32n];
}};
const [bas, haut] = porte({handler});
vue.setBigUint64({idt} + 14 * 16, bas, true);
vue.setBigUint64({idt} + 14 * 16 + 8, haut, true);
vue.setUint16({idtPointer}, 256 * 16 - 1, true);
vue.setBigUint64({idtPointer} + 2, {idt}n, true);
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 256n, rounds: 16 }});
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("demandes " + asked);
{prints}
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            pages = RIG_PAGES,
            rip = RIP_SLOT,
            base = RIG_BASE,
            handler = RIG_HANDLER,
            idt = RIG_IDT,
            idtPointer = RIG_IDT_POINTER,
            absent = RIG_ABSENT,
            pml4 = RIG_PML4,
            pdpt = RIG_PDPT,
            pd = RIG_PD,
            pt = RIG_PT,
            pdptLow = RIG_PDPT_LOW,
            pdLow = RIG_PD_LOW,
            frame = RIG_FRAME,
            witness = RIG_WITNESS,
        ),
    )
    .expect("le pilote");
    driver
}

fn run_driver(bun: &Path, driver: &Path) -> String {
    let output = Command::new(bun)
        .arg("run")
        .arg(driver)
        .output()
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    text
}

/// **Une faute de page est délivrée à l'invité, et `iretq` rejoue
/// l'instruction fautive.**
///
/// C'est le mécanisme par lequel un noyau Linux cartographie à la demande :
/// `idt_setup_early_handler` pose une IDT juste avant `copy_bootdata`, et
/// `early_make_pgtable` pose la page que la faute désigne. Sans délivrance, la
/// machine s'arrêtait à `copy_bootdata + 38` — sur une lecture correcte d'une
/// adresse que ses tables ne portaient pas encore. Ce test est ce chemin-là en
/// petit : une lecture qui faute, un gestionnaire qui pose la feuille, un
/// `iretq`, et la même lecture qui aboutit.
///
/// **Ce que chaque assertion tient**, et pourquoi elle est là :
/// - `rdx` porte le témoin : la lecture **rejouée** a traversé la page que le
///   gestionnaire vient de poser ;
/// - `rbx` a changé : l'exécution a **continué** après, elle ne s'est pas
///   arrêtée à la reprise ;
/// - `rax` porte CR2 : l'invité a vu l'adresse fautive, pas l'hôte seul ;
/// - `rsp` est revenu : les cinq mots ont été dépilés, ni plus ni moins ;
/// - le cadre en mémoire porte l'adresse fautive et un code d'erreur nul, à
///   l'alignement de seize que le silicium impose ;
/// - le témoin est effacé, et l'arrêt final est le `ud2`, pas une faute.
#[test]
fn a_page_fault_is_delivered_to_the_guest_and_iretq_resumes_the_faulting_instruction() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const STACK: u64 = 0x4_0000;
    let rig = fault_rig(STACK);
    let scratch = std::env::temp_dir().join(format!("wisq-host-deliver-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let driver = fault_driver(
        &rig,
        &scratch,
        r#"console.log("rdx " + lire(2));
console.log("rbx " + lire(3));
console.log("rax " + lire(0));
console.log("rsp " + lire(4));
console.log("rip " + lire(RIP));
console.log("faute " + lire(FAULT));
const mot = (at) => vue.getBigUint64(at, true).toString();
console.log("cadre-rip " + mot(STACK - 8 * 5));
console.log("cadre-code " + mot(STACK - 8 * 6));
console.log("cadre-rsp " + mot(STACK - 8 * 2));
console.log("cadre-rflags " + mot(STACK - 8 * 3));
console.log("r8 " + lire(8));
console.log("rflags " + lire(RFLAGS));"#
            .replace("RIP", &RIP_SLOT.to_string())
            .replace("RFLAGS", &RFLAGS_SLOT.to_string())
            .replace("FAULT", &FAULT_SLOT.to_string())
            .replace("STACK", &STACK.to_string())
            .as_str(),
    );
    let text = run_driver(&bun, &driver);
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    let number = |name: &str| line(name).parse::<u64>().expect("un nombre");
    assert_eq!(
        line("arret "),
        "refusée",
        "l'arrêt final est le ud2 : {text}"
    );
    // **Quatre demandes, et chacune se nomme** : le programme, le
    // gestionnaire, la reprise sur l'instruction fautive, et le `ud2` — pour
    // lequel l'hôte demande une région qui commence là, et que le bouchon
    // refuse. C'est ce refus-là qui fait l'arrêt « refusée ».
    assert_eq!(
        number("demandes "),
        4,
        "quatre régions demandées, pas une de plus : {text}"
    );
    assert_eq!(
        number("rdx "),
        RIG_WITNESS,
        "la lecture rejouée a traversé la page posée"
    );
    assert_eq!(
        number("rbx "),
        RIG_AFTER,
        "l'exécution a continué après la reprise"
    );
    assert_eq!(number("rax "), RIG_ABSENT, "l'invité a lu CR2");
    assert_eq!(
        number("rsp "),
        STACK,
        "iretq a dépilé les cinq mots, ni plus ni moins"
    );
    assert_eq!(number("rip "), rig.ud2_at, "RIP est sur le ud2");
    assert_eq!(
        number("faute "),
        0,
        "le témoin est effacé une fois la faute délivrée"
    );
    assert_eq!(
        number("cadre-rip "),
        rig.faults_at,
        "le cadre porte l'instruction fautive"
    );
    assert_eq!(
        number("cadre-code "),
        0,
        "une lecture sur une page absente : code d'erreur nul"
    );
    assert_eq!(
        number("cadre-rsp "),
        STACK,
        "le cadre porte la pile d'avant"
    );
    // **IF : empilé allumé, éteint dans le gestionnaire, rallumé par `iretq`.**
    // Une porte d'interruption masque les interruptions en entrant ; un
    // gestionnaire qui les trouverait encore ouvertes pourrait être
    // réinterrompu sur sa propre pile. Et c'est le cadre qui les rend.
    const INTERRUPT_FLAG: u64 = 0x200;
    assert_ne!(
        number("cadre-rflags ") & INTERRUPT_FLAG,
        0,
        "le cadre porte IF allumé"
    );
    assert_eq!(
        number("r8 ") & INTERRUPT_FLAG,
        0,
        "IF est éteint dans le gestionnaire"
    );
    assert_ne!(number("rflags ") & INTERRUPT_FLAG, 0, "iretq rallume IF");
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Une faute pendant la délivrance est nommée, pas cachée.** La pile de
/// l'invité n'est cartographiée nulle part : poser le cadre faute à son tour.
/// Sur le silicium c'est une double faute ; ici la machine s'arrête et dit
/// que c'est la délivrance elle-même qui a fauté — sans quoi un noyau dont la
/// pile d'entrée manque s'arrêterait « sur place » sans un mot, exactement la
/// panne que le cœur Swift a mise une journée à trouver.
#[test]
fn a_fault_while_delivering_is_named_rather_than_hidden() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const UNMAPPED_STACK: u64 = 0xFFFF_8000_0030_0000;
    let rig = fault_rig(UNMAPPED_STACK);
    let scratch = std::env::temp_dir().join(format!("wisq-host-double-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let driver = fault_driver(&rig, &scratch, "");
    let text = run_driver(&bun, &driver);
    let stopped = text
        .lines()
        .find_map(|l| l.strip_prefix("arret "))
        .unwrap_or_else(|| panic!("le pilote doit dire « arret » : {text}"));
    assert_eq!(
        stopped,
        "une faute pendant la délivrance d'une faute de page : la pile de l'invité n'est pas cartographiée",
        "{text}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Un `int3` est délivré à l'invité, et `iretq` reprend à l'instruction
/// suivante — pas sur l'`int3`.** C'est ce qui distingue une interruption
/// logicielle d'une faute : c'est un appel, et RIP avance avant d'être
/// empilé. Le cœur Swift le fait ainsi (`X86CoreDispatch.swift`, 0xCC/0xCD),
/// et c'est la même délivrance que la faute de page, sans code d'erreur.
///
/// Pagination éteinte, exprès : ce test tient le chemin du témoin d'arrêt et
/// l'adresse de reprise ; la marche est tenue par la délivrance de la faute.
#[test]
fn a_software_interrupt_is_delivered_and_returns_after_the_instruction() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    // **Quatre pages, pas une** : l'IDT et son pointeur vivent à 0x12000 et
    // 0x13000, et le pilote les écrit sans repli. Dans une RAM de 64 Kio ces
    // écritures tombaient au-dessus de la RAM invitée — dans la correspondance
    // de l'hôte — et la machine ne trouvait aucune porte.
    const PAGES: u32 = 4;
    const BASE: u64 = 0x1_0000;
    const HANDLER: u64 = 0x1_1000;
    const IDT: u64 = 0x1_2000;
    const IDT_POINTER: u64 = 0x1_3000;
    const STACK: u64 = 0xf000;
    fn put(into: &mut Vec<u8>, bytes: &[u8]) {
        into.extend_from_slice(bytes);
    }
    let mut program: Vec<u8> = Vec::new();
    put(&mut program, &[0x48, 0xbb]); // movabs $IDT_POINTER,%rbx
    put(&mut program, &IDT_POINTER.to_le_bytes());
    put(&mut program, &[0x0f, 0x01, 0x1b]); // lidt (%rbx)
    put(&mut program, &[0x48, 0xc7, 0xc4]); // mov $STACK,%rsp
    put(&mut program, &(STACK as u32).to_le_bytes());
    put(&mut program, &[0x48, 0xc7, 0xc3, 0x11, 0x11, 0x00, 0x00]); // mov $0x1111,%rbx
    put(&mut program, &[0xcc]); // int3
    let after_int3 = BASE + program.len() as u64;
    put(&mut program, &[0x48, 0xc7, 0xc3, 0x22, 0x22, 0x00, 0x00]); // mov $0x2222,%rbx
    let ud2_at = BASE + program.len() as u64;
    put(&mut program, &[0x0f, 0x0b]); // ud2
    let handler: Vec<u8> = vec![
        0x48, 0xc7, 0xc1, 0x33, 0x33, 0x00, 0x00, // mov $0x3333,%rcx
        0x48, 0xcf, // iretq — pas de code d'erreur pour le vecteur 3
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-int3-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut served = String::new();
    for (name, bytes, at, slot) in [
        ("programme.wasm", &program[..], BASE, 0u32),
        ("gestionnaire.wasm", &handler[..], HANDLER, 1),
        (
            "reprise.wasm",
            &program[(after_int3 - BASE) as usize..],
            after_int3,
            2,
        ),
    ] {
        let module = Module::resolving(bytes, at, 0, slot, PAGES)
            .unwrap_or_else(|| panic!("{name} se traduit"));
        let path = scratch.join(name);
        std::fs::write(&path, &module).expect(name);
        served.push_str(&format!(
            "    if (address === {at}n && slot === {slot}) return readFileSync({:?});\n",
            path.to_string_lossy()
        ));
    }
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
const vm = machine({{
  translate: async (address, slot) => {{
{served}    return null;
  }},
  pages: {pages},
}});
const vue = new DataView(vm.memory.buffer);
const porte = (offset) => [
  (BigInt(offset) & 0xffffn) | (0x10n << 16n) | (0x0en << 40n) | (1n << 47n)
    | ((BigInt(offset) & 0xffff0000n) << 32n),
  BigInt(offset) >> 32n,
];
const [bas, haut] = porte({handler});
vue.setBigUint64({idt} + 3 * 16, bas, true);
vue.setBigUint64({idt} + 3 * 16 + 8, haut, true);
vue.setUint16({idtPointer}, 256 * 16 - 1, true);
vue.setBigUint64({idtPointer} + 2, {idt}n, true);
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 256n, rounds: 16 }});
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value).toString();
const mot = (at) => vue.getBigUint64(at, true).toString();
console.log("arret " + why.stopped);
console.log("rbx " + lire(3));
console.log("rcx " + lire(1));
console.log("rsp " + lire(4));
console.log("rip " + lire({rip}));
console.log("stop " + lire({stop}));
console.log("cadre-rip " + mot({stack} - 8 * 5));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            stop = wisq_vm::x86_wasm::STOP_SLOT,
            base = BASE,
            handler = HANDLER,
            idt = IDT,
            idtPointer = IDT_POINTER,
            stack = STACK,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    let number = |name: &str| line(name).parse::<u64>().expect("un nombre");
    assert_eq!(
        line("arret "),
        "refusée",
        "l'arrêt final est le ud2 : {text}"
    );
    assert_eq!(
        number("rcx "),
        0x3333,
        "le gestionnaire du vecteur 3 a tourné"
    );
    assert_eq!(
        number("rbx "),
        0x2222,
        "la reprise est après l'int3, pas dessus"
    );
    assert_eq!(
        number("cadre-rip "),
        after_int3,
        "le cadre porte l'instruction suivante"
    );
    assert_eq!(
        number("rsp "),
        STACK,
        "iretq a rendu la pile : cinq mots, sans code d'erreur"
    );
    assert_eq!(number("rip "), ud2_at, "RIP est sur le ud2");
    assert_eq!(
        number("stop "),
        0,
        "le témoin d'arrêt est effacé une fois délivré"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Sans porte, une interruption logicielle est nommée**, comme la faute :
/// « sur place » ne dirait pas qu'un `int3` a été exécuté sans IDT.
#[test]
fn a_software_interrupt_without_a_gate_is_named() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program: Vec<u8> = vec![
        0x48, 0xc7, 0xc4, 0x00, 0xf0, 0x00, 0x00, // mov $0xf000,%rsp
        0xcc, // int3
        0x0f, 0x0b, // ud2
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-int3-nu-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("la région se traduit");
    let path = scratch.join("int3.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 256n, rounds: 4 }});
console.log("arret " + why.stopped);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let stopped = text
        .lines()
        .find_map(|l| l.strip_prefix("arret "))
        .unwrap_or_else(|| panic!("le pilote doit dire « arret » : {text}"));
    assert_eq!(
        stopped, "une interruption logicielle sans porte : aucune IDT ne porte le vecteur 3",
        "{text}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **La table des blocs grandit devant les régions, au lieu de refuser le
/// noyau.**
///
/// C'est le mur du premier `printk` : la 155ᵉ région du noyau Alpine réclamait
/// l'emplacement 4049 d'une table de 4096, et son minimum déclaré —
/// l'emplacement plus ses blocs — dépassait ce que l'hôte avait alloué une fois
/// pour toutes. `LinkError`, sans retour, sur une machine qui avançait encore.
///
/// Ici le même mur, en deux régions et une table d'**un seul** emplacement.
/// La première pose deux blocs : elle déborde déjà, et la table doit grandir
/// **avant** de l'instancier — après, c'est trop tard, c'est l'instanciation
/// qui compare. La seconde reçoit l'emplacement 2, au-delà de tout ce que
/// l'hôte avait alloué. Avec la croissance, l'anneau tourne, et la table le
/// dit. Un sabotage qui grandissait après l'instanciation a survécu à une
/// première forme de ce test, à deux emplacements : la première région
/// tenait, et grandir après elle suffisait à la seconde.
#[test]
fn the_block_table_grows_ahead_of_the_regions_instead_of_refusing_them() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    const NEXT: u64 = BASE + 0x100;
    // **Un seul emplacement, exprès.** La première région en veut deux : la
    // table est trop courte dès le départ, et seule une croissance **avant**
    // l'instanciation la laisse passer.
    const REGIONS: u32 = 1;

    // Deux maillons : le premier coupé en deux blocs par un saut sur place,
    // le second d'un seul bloc. Chacun ajoute son numéro à RDX et saute
    // indirectement à l'autre.
    let region = |index: u64| -> Vec<u8> {
        let mut code = vec![0x48, 0xc7, 0xc0];
        code.extend_from_slice(&(index as u32 + 1).to_le_bytes()); // movq $n, %rax
        if index == 0 {
            code.extend_from_slice(&[0x48, 0x85, 0xc0]); // testq %rax, %rax
            code.extend_from_slice(&[0x75, 0x00]); // jnz +0 : coupe le bloc
        }
        code.extend_from_slice(&[0x48, 0x01, 0xc2]); // addq %rax, %rdx
        code.extend_from_slice(&[0x48, 0xb8]);
        code.extend_from_slice(&(if index == 0 { NEXT } else { BASE }).to_le_bytes());
        code.extend_from_slice(&[0xff, 0xe0]); // jmp *%rax
        code
    };
    let first = Module::survey(&region(0), 0).expect("le relevé").blocks;
    let second = Module::survey(&region(1), 0).expect("le relevé").blocks;
    assert_eq!(
        (first, second),
        (2, 1),
        "la première région doit déborder la table à elle seule : sans ça un \
         hôte qui grandit après l'instanciation passerait"
    );

    let scratch = std::env::temp_dir().join(format!("wisq-table-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut catalogue = String::new();
    let mut loaded = String::new();
    for (index, address) in [BASE, NEXT].into_iter().enumerate() {
        let code = region(index as u64);
        let raw = scratch.join(format!("region{index}.bin"));
        std::fs::write(&raw, &code).expect("le code de la région");
        loaded.push_str(&format!(
            "[{},{:?}],",
            address & u64::from(PAGES * 65536 - 1),
            raw.to_string_lossy()
        ));
        for slot in 0..4u32 {
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

    let laps = 200u64;
    let blocks_per_lap = (first + second) as u64;
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";

const catalogue = new Map([{catalogue}]);
const posé = new Map(
  [{loaded}].map(([at, path]) => [at, new Uint8Array(readFileSync(path))]),
);
let asked = 0;
const translate = async (address, slot) => {{
  asked++;
  const path = catalogue.get(address + ":" + slot);
  return path === undefined ? null : readFileSync(path);
}};

const vm = machine({{ translate, pages: {pages}, regions: {regions} }});
for (const [at, octets] of posé) {{
  new Uint8Array(vm.memory.buffer, at, octets.length).set(octets);
}}
console.log("avant " + vm.blocks.length);
vm.globals[{rip}].value = {base}n;

// **Premier temps : la découverte.** Deux tours, une région chacun ; la
// première déborde déjà la table d'un emplacement, la seconde reçoit
// l'emplacement 2.
const first = await vm.run({{ budget: 1000n, rounds: 2 }});
console.log("decouverte " + first.stopped);
console.log("demandes " + asked);
console.log("regions " + vm.known.size);
console.log("emplacements " + Array.from(vm.known.values()).map((r) => r.slot).join(","));
console.log("apres " + vm.blocks.length);

// **Second temps : l'anneau tourne**, à travers l'emplacement que la table
// n'avait pas.
vm.globals[{rip}].value = {base}n;
vm.globals[2].value = 0n;
const second = await vm.run({{ budget: {budget}n, rounds: 1 }});
console.log("regime " + second.stopped);
console.log("retraductions " + (asked - 2));
console.log("rdx " + vm.globals[2].value.toString());
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            catalogue = catalogue,
            loaded = loaded,
            pages = PAGES,
            regions = REGIONS,
            rip = RIP_SLOT,
            base = BASE,
            budget = laps * blocks_per_lap,
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
    // **C'est ici que le mur tombe ou non.** Sans croissance, la seconde
    // région lève `LinkError` dans `install`, et le pilote meurt en erreur.
    assert!(
        output.status.success(),
        "la seconde région doit s'instancier au-delà de la table initiale : {complaint}\n{text}"
    );
    let seen = |label: &str| -> String {
        text.lines()
            .find_map(|line| line.strip_prefix(label).map(|rest| rest.trim().to_string()))
            .unwrap_or_else(|| panic!("le pilote n'a pas dit « {label} » :\n{text}"))
    };

    // La table a bien commencé à un : sinon le test ne déborde rien.
    assert_eq!(seen("avant"), REGIONS.to_string(), "la table demandée");
    assert_eq!(seen("demandes"), "2", "une traduction par région");
    assert_eq!(seen("regions"), "2", "les deux sont retenues");
    // **La seconde région commence bien à l'emplacement 2** — la première a
    // posé ses deux blocs dans une table qui n'en offrait qu'un.
    assert_eq!(
        seen("emplacements"),
        "0,2",
        "la seconde région commence après les deux blocs de la première"
    );
    let after: u32 = seen("apres").parse().expect("une taille de table");
    assert!(
        after >= 3,
        "la table doit porter au moins l'emplacement 2 et son bloc, pas {after}"
    );
    assert_eq!(
        seen("retraductions"),
        "0",
        "en régime établi, plus rien à traduire"
    );
    assert_eq!(
        seen("regime"),
        "tours épuisés",
        "un anneau revenu à son point de départ n'est pas une machine bloquée"
    );
    assert_eq!(
        seen("rdx"),
        (laps * (1 + 2)).to_string(),
        "l'anneau doit avoir tourné {laps} fois à travers l'emplacement gagné"
    );
}

/// **Un noyau qui atteint `lkgs` s'arrête dessus, et l'arrêt se nomme.**
///
/// `f2 0f 00 f7` — `lkgs %edi` — charge la base GS du noyau depuis un
/// sélecteur. Cette machine n'a pas de table de descripteurs pour en lire une,
/// et le noyau Alpine ne l'exécute que si CPUID annonce `LKGS`, ce que `cpuid`
/// n'annonce pas : elle ne sera pas atteinte. Mais elle vit dans
/// `native_lkgs`, à portée statique de `init_scattered_cpuid_features`, et un
/// décodeur qui ne la lit pas refusait la région entière.
///
/// Ce que chaque assertion tient : l'arrêt est nommé, et ce n'est pas
/// « refusée » ; ce qui précède a tourné ; RIP est posé **sur** l'instruction,
/// pas après — rien ne la reprendra, et c'est elle qu'il faut montrer ; ce qui
/// suit n'a pas tourné.
#[test]
fn a_kernel_that_reaches_lkgs_is_stopped_by_name_on_the_instruction() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program: Vec<u8> = vec![
        0x48, 0xc7, 0xc0, 0x2a, 0x00, 0x00, 0x00, // movq $42, %rax
        0xf2, 0x0f, 0x00, 0xf7, // lkgs %edi — l'arrêt qui doit se nommer
        0x48, 0xff, 0xc2, // incq %rdx — ne doit pas tourner
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-lkgs-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = match Module::resolving_or_why(&program, BASE, 0, 0, PAGES) {
        Ok(module) => module,
        Err(why) => panic!("`native_lkgs` doit se traduire, pas faire refuser la région : {why:?}"),
    };
    let path = scratch.join("lkgs.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("rax " + lire(0));
console.log("rdx " + lire(2));
console.log("rip " + lire({rip}));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    assert_eq!(
        line("arret "),
        "arrêtée sur lkgs : la base GS du noyau depuis un sélecteur, sans table de descripteurs",
        "l'arrêt doit se nommer : {text}"
    );
    assert_eq!(line("rax "), "42", "les instructions d'avant tournent");
    assert_eq!(
        line("rip "),
        (BASE + 7).to_string(),
        "RIP est posé sur le `lkgs`, pas après : rien ne le reprendra"
    );
    assert_eq!(line("rdx "), "0", "et rien d'après n'a tourné");
}

/// **Une cible statique hors région passe par la correspondance, et l'anneau
/// tourne sans repasser par l'hôte.**
///
/// C'est le mur de `jump_label_init` : `sort_r` appelle son comparateur par
/// un `call` direct, et chaque appel rendait la main à l'hôte — `place`
/// rendait `-1` pour tout ce qui n'est pas un bloc de la région, et seule
/// `resolve` (les formes indirectes) consultait la correspondance. Une
/// comparaison par tour, 4096 tours, et le pilote prenait ça pour la fin.
///
/// Ici le même trajet en petit, et les **trois** formes statiques qui sortent
/// d'une région : un `call` direct vers B, un `ret` qui revient au milieu de A
/// (donc dans une troisième région, qui commence là), et un `jnz` direct qui
/// revient à l'entrée de A. Ce que chaque assertion tient :
/// - trois régions, trois demandes : la découverte n'en coûte pas plus ;
/// - en régime établi, **un seul appel**, aucune retraduction, et l'anneau a
///   tourné jusqu'au bout du budget — c'est la correspondance qui a servi, à
///   chaque `call`, chaque `ret` et chaque `jnz` ;
/// - RSP est revenu : les `call` et les `ret` se répondent un pour un.
#[test]
fn a_static_target_out_of_the_region_goes_through_the_correspondence() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    const CALLEE: u64 = BASE + 0x100;
    const STACK: u64 = 0x8000;
    // A : `incq %rdx ; call B ; testq %rdx,%rdx ; jnz A ; ud2`. Le `jnz` est
    // toujours pris — RDX ne retombe jamais à zéro — et sa cible est l'entrée
    // de A : depuis la région qui commence au `testq`, c'est une sortie.
    let a: Vec<u8> = vec![
        0x48, 0xff, 0xc2, // incq %rdx
        0xe8, 0xf8, 0x00, 0x00, 0x00, // call +0xf8 → B
        0x48, 0x85, 0xd2, // testq %rdx, %rdx
        0x75, 0xf3, // jnz -13 → A
        0x0f, 0x0b, // ud2 : jamais atteint
    ];
    // B : `addq $2, %rdx ; ret`.
    let b: Vec<u8> = vec![0x48, 0x83, 0xc2, 0x02, 0xc3];
    // Le `ret` revient à A + 8, au milieu de A : l'hôte y demandera une région
    // qui commence là. Ses octets sont ceux de A à partir du `testq`.
    let after_call: Vec<u8> = a[8..].to_vec();

    let scratch = std::env::temp_dir().join(format!("wisq-host-statique-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut catalogue = String::new();
    let mut loaded = String::new();
    for (name, address, code) in [
        ("a", BASE, &a),
        ("b", CALLEE, &b),
        ("a8", BASE + 8, &after_call),
    ] {
        if name != "a8" {
            let raw = scratch.join(format!("{name}.bin"));
            std::fs::write(&raw, code).expect("le code de la région");
            loaded.push_str(&format!(
                "[{},{:?}],",
                address & u64::from(PAGES * 65536 - 1),
                raw.to_string_lossy()
            ));
        }
        for slot in 0..10u32 {
            let module = Module::resolving(code, address, 0, slot, PAGES)
                .unwrap_or_else(|| panic!("l'émetteur doit compiler la région {name}"));
            let path = scratch.join(format!("{name}-{slot}.wasm"));
            std::fs::write(&path, &module).expect("le module");
            catalogue.push_str(&format!(
                "[\"{address}:{slot}\",{:?}],",
                path.to_string_lossy()
            ));
        }
    }

    // Un tour d'anneau : le bloc d'entrée de A (`incq`, `call`), B (`addq`,
    // `ret`), le bloc du `testq` (`jnz`). Trois blocs, et RDX gagne trois.
    let laps = 200u64;
    let blocks_per_lap = 3u64;
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";

const catalogue = new Map([{catalogue}]);
const posé = new Map(
  [{loaded}].map(([at, path]) => [at, new Uint8Array(readFileSync(path))]),
);
let asked = 0;
const translate = async (address, slot) => {{
  asked++;
  const path = catalogue.get(address + ":" + slot);
  return path === undefined ? null : readFileSync(path);
}};

const vm = machine({{ translate, pages: {pages} }});
for (const [at, octets] of posé) {{
  new Uint8Array(vm.memory.buffer, at, octets.length).set(octets);
}}
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value);
vm.globals[{rip}].value = {base}n;
vm.globals[4].value = {stack}n;

// **Premier temps : la découverte.** A, puis B par le `call`, puis la région
// qui commence après le `call` par le `ret`. Trois tours suffisent ; au
// troisième, l'anneau est complet et tourne jusqu'au bout du budget.
const first = await vm.run({{ budget: 1000n, rounds: 3 }});
console.log("decouverte " + first.stopped);
console.log("demandes " + asked);
console.log("regions " + vm.known.size);

// **Second temps : un seul appel.** Si les cibles statiques passent par la
// correspondance, la boucle ne ressort qu'au bout du budget. Sinon le premier
// `call` rend la main, et RDX s'arrête à un.
vm.globals[{rip}].value = {base}n;
vm.globals[4].value = {stack}n;
vm.globals[2].value = 0n;
const before = asked;
const second = await vm.run({{ budget: {budget}n, rounds: 1 }});
console.log("regime " + second.stopped);
console.log("retraductions " + (asked - before));
console.log("rdx " + lire(2).toString());
console.log("rsp " + lire(4).toString());
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            catalogue = catalogue,
            loaded = loaded,
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            stack = STACK,
            budget = laps * blocks_per_lap,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let seen = |label: &str| -> String {
        text.lines()
            .find_map(|line| line.strip_prefix(label).map(|rest| rest.trim().to_string()))
            .unwrap_or_else(|| panic!("le pilote n'a pas dit « {label} » :\n{text}"))
    };
    assert_eq!(
        seen("demandes"),
        "3",
        "une traduction par région : A, B, et l'après-`call`"
    );
    assert_eq!(seen("regions"), "3", "les trois sont retenues");
    assert_eq!(
        seen("retraductions"),
        "0",
        "en régime établi, plus rien à traduire"
    );
    assert_eq!(
        seen("regime"),
        "tours épuisés",
        "un seul appel doit épuiser le budget, pas rendre la main au premier `call`"
    );
    // **Plus un.** Le budget s'épuise pile sur l'entrée de A, et l'hôte
    // exécute alors **un bloc de plus** pour distinguer un anneau d'une machine
    // bloquée (voir `run` dans `web/host.js`) : ce bloc est l'`incq` de A.
    assert_eq!(
        seen("rdx"),
        (laps * 3 + 1).to_string(),
        "l'anneau doit avoir tourné {laps} fois dans un seul appel : chaque `call`, `ret` et \
         `jnz` hors région est passé par la correspondance"
    );
    // Deux cents `call`, deux cents `ret` — et le bloc de plus finit sur un
    // `call` dont l'adresse de retour est encore empilée : huit octets sous la
    // pile de départ, ni plus ni moins.
    assert_eq!(
        seen("rsp"),
        (STACK - 8).to_string(),
        "les `call` et les `ret` se répondent un pour un, sauf celui du bloc de plus"
    );
}

/// **`invlpg` fait oublier une page au tampon, et la lecture suivante suit la
/// nouvelle entrée.**
///
/// Le test du tampon (`a_paged_guest_reads_through_its_page_tables`) tient
/// qu'après avoir réécrit sa propre entrée de feuille, l'invité relit encore
/// **l'ancienne** trame : c'est le tampon qui répond. Un vrai noyau vide ce
/// tampon par `invlpg` — « que cette tranche ne produit pas », disait-il. Le
/// noyau Alpine y arrive dans `flush_tlb_one_kernel`, et l'instruction refusait
/// sa région.
///
/// Le même montage, un `invlpg (%rsi)` entre la réécriture et la relecture :
/// la relecture doit rendre la **nouvelle** trame. Et le même programme avec
/// trois `nop` à la place, pour le contraste : l'ancienne. Sans ce contraste,
/// un tampon qui ne répondrait plus du tout rendrait le test vert pour la
/// mauvaise raison.
#[test]
fn invlpg_makes_the_buffer_forget_the_page_and_the_next_read_follows_the_new_entry() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 64;
    const BASE: u64 = 0x1_0000;
    const PML4: u64 = 0x2_0000;
    const PDPT: u64 = 0x2_1000;
    const PD: u64 = 0x2_2000;
    const PT: u64 = 0x2_3000;
    const FRAME_A: u64 = 0x3_0000;
    const FRAME_B: u64 = 0x3_1000;
    const VA1: u64 = 0xFFFF_8000_0020_1000;
    const VA_TABLE: u64 = VA1 + 0x1000; // l'alias sur la table de feuilles
    const WITNESS_A: u64 = 0x0123_4567_89AB_CDEF;
    const WITNESS_B: u64 = 0x7777_7777_7777_7777;

    let leaf = |at: u64| (at >> 12) & 0x1ff;
    let build = |flush: &[u8]| -> Vec<u8> {
        let mut program: Vec<u8> = Vec::new();
        let mut push = |bytes: &[u8]| program.extend_from_slice(bytes);
        push(&[0x48, 0xb8]); // movabs $PML4,%rax
        push(&PML4.to_le_bytes());
        push(&[0x0f, 0x22, 0xd8]); // mov %rax,%cr3
        push(&[0x48, 0xb8]); // movabs $PG,%rax
        push(&(1u64 << 31).to_le_bytes());
        push(&[0x0f, 0x22, 0xc0]); // mov %rax,%cr0
        push(&[0x48, 0xbe]); // movabs $VA1,%rsi
        push(&VA1.to_le_bytes());
        push(&[0x48, 0x8b, 0x56, 0x18]); // mov 0x18(%rsi),%rdx — remplit le tampon
        push(&[0x48, 0xbf]); // movabs $VA_TABLE,%rdi
        push(&VA_TABLE.to_le_bytes());
        push(&[0x48, 0xb8]); // movabs $(FRAME_B|présente),%rax
        push(&(FRAME_B | 0x3).to_le_bytes());
        push(&[0x48, 0x89, 0x87]); // mov %rax,disp32(%rdi) — réécrit la feuille
        push(&((leaf(VA1) * 8) as u32).to_le_bytes());
        push(flush); // invlpg (%rsi), ou trois nop
        push(&[0x48, 0x8b, 0x5e, 0x18]); // mov 0x18(%rsi),%rbx — que répond-on ?
        push(&[0x0f, 0x0b]); // ud2 : rendre la main
        program
    };
    let with = build(&[0x0f, 0x01, 0x3e]);
    let without = build(&[0x90, 0x90, 0x90]);

    let scratch = std::env::temp_dir().join(format!("wisq-host-invlpg-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = match Module::resolving_or_why(&with, BASE, 0, 0, PAGES) {
        Ok(module) => module,
        Err(why) => panic!("`invlpg` doit se traduire, pas faire refuser la région : {why:?}"),
    };
    let path = scratch.join("invlpg.wasm");
    std::fs::write(&path, &module).expect("le module");
    let contrast = Module::resolving(&without, BASE, 0, 0, PAGES).expect("le même sans invlpg");
    let contrast_path = scratch.join("nop.wasm");
    std::fs::write(&contrast_path, &contrast).expect("le module de contraste");

    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";

function monter(vm) {{
  const vue = new DataView(vm.memory.buffer);
  const present = 0x3n;
  const feuille = (va) => Number((BigInt(va) >> 12n) & 0x1ffn);
  const idx = (va, shift) => Number((BigInt(va) >> BigInt(shift)) & 0x1ffn);
  vue.setBigUint64({pml4} + idx({va1}n, 39) * 8, {pdpt}n | present, true);
  vue.setBigUint64({pdpt} + idx({va1}n, 30) * 8, {pd}n | present, true);
  vue.setBigUint64({pd} + idx({va1}n, 21) * 8, {pt}n | present, true);
  vue.setBigUint64({pt} + feuille({va1}n) * 8, {frameA}n | present, true);
  vue.setBigUint64({pt} + feuille({vaTable}n) * 8, {pt}n | present, true);
  vue.setBigUint64({frameA} + 0x18, {witnessA}n, true);
  vue.setBigUint64({frameB} + 0x18, {witnessB}n, true);
}}

async function tourner(fichier) {{
  let asked = 0;
  const vm = machine({{
    translate: async () => (asked++ === 0 ? readFileSync(fichier) : null),
    pages: {pages},
  }});
  monter(vm);
  vm.globals[{rip}].value = {base}n;
  const why = await vm.run({{ budget: 256n, rounds: 16 }});
  const lire = (at) => BigInt.asUintN(64, vm.globals[at].value).toString();
  return {{ why, rdx: lire(2), rbx: lire(3) }};
}}

const avec = await tourner({path:?});
console.log("arret " + avec.why.stopped);
console.log("rdx " + avec.rdx);
console.log("rbx " + avec.rbx);
const sans = await tourner({contrast:?});
console.log("contraste " + sans.rbx);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            contrast = contrast_path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            va1 = VA1,
            vaTable = VA_TABLE,
            pml4 = PML4,
            pdpt = PDPT,
            pd = PD,
            pt = PT,
            frameA = FRAME_A,
            frameB = FRAME_B,
            witnessA = WITNESS_A,
            witnessB = WITNESS_B,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    let number = |name: &str| line(name).parse::<u64>().expect("un nombre");
    assert_eq!(line("arret "), "refusée", "le `ud2` arrête : {text}");
    assert_eq!(
        number("rdx "),
        WITNESS_A,
        "la première lecture a rempli le tampon"
    );
    assert_eq!(
        number("rbx "),
        WITNESS_B,
        "après `invlpg`, la relecture suit la nouvelle entrée de feuille"
    );
    assert_eq!(
        number("contraste "),
        WITNESS_A,
        "sans `invlpg`, le tampon répond encore l'ancienne trame : c'est bien lui que \
         `invlpg` a fait taire"
    );
}

/// **Un noyau qui atteint `vmcall` ou `vmmcall` s'arrête dessus, et l'arrêt
/// se nomme.**
///
/// Cette machine n'a pas d'hyperviseur au-dessus d'elle : un appel à
/// l'hyperviseur n'a personne pour répondre. Le noyau Alpine ne les exécute
/// que si CPUID annonce la signature VMware, ce que `cpuid` n'annonce pas ;
/// mais ils vivent dans `vmware_platform`, à portée statique de
/// `init_hypervisor_platform`, et un décodeur qui ne les lit pas refusait la
/// région entière.
///
/// Les deux encodages, dans le même test : ce qui précède a tourné, RIP est
/// posé **sur** l'instruction, ce qui suit n'a pas tourné, et l'arrêt porte le
/// même nom pour les deux.
#[test]
fn a_kernel_that_reaches_a_hypervisor_call_is_stopped_by_name_on_the_instruction() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program = |call: [u8; 3]| -> Vec<u8> {
        let mut bytes = vec![0x48, 0xc7, 0xc0, 0x2a, 0x00, 0x00, 0x00]; // movq $42, %rax
        bytes.extend_from_slice(&call); // vmcall ou vmmcall
        bytes.extend_from_slice(&[0x48, 0xff, 0xc2]); // incq %rdx — ne doit pas tourner
        bytes
    };
    let scratch = std::env::temp_dir().join(format!("wisq-host-vmcall-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut listing = String::new();
    for (name, call) in [("intel", [0x0f, 0x01, 0xc1]), ("amd", [0x0f, 0x01, 0xd9])] {
        let module = match Module::resolving_or_why(&program(call), BASE, 0, 0, PAGES) {
            Ok(module) => module,
            Err(why) => panic!("`vmware_platform` doit se traduire, pas faire refuser la région ({name}) : {why:?}"),
        };
        let path = scratch.join(format!("{name}.wasm"));
        std::fs::write(&path, &module).expect("le module");
        listing.push_str(&format!("[{name:?},{:?}],", path.to_string_lossy()));
    }
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
for (const [name, path] of [{listing}]) {{
  let asked = 0;
  const vm = machine({{
    translate: async () => (asked++ === 0 ? readFileSync(path) : null),
    pages: {pages},
  }});
  vm.globals[{rip}].value = {base}n;
  const why = await vm.run({{ budget: 64n, rounds: 16 }});
  const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
  console.log(name + "-arret " + why.stopped);
  console.log(name + "-rax " + lire(0));
  console.log(name + "-rdx " + lire(2));
  console.log(name + "-rip " + lire({rip}));
}}
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            listing = listing,
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    for name in ["intel", "amd"] {
        assert_eq!(
            line(&format!("{name}-arret ")),
            "arrêtée sur un appel à l'hyperviseur (vmcall ou vmmcall) : cette machine n'en a pas",
            "l'arrêt doit se nommer ({name}) : {text}"
        );
        assert_eq!(
            line(&format!("{name}-rax ")),
            "42",
            "les instructions d'avant tournent ({name})"
        );
        assert_eq!(
            line(&format!("{name}-rip ")),
            (BASE + 7).to_string(),
            "RIP est posé sur l'appel, pas après ({name}) : rien ne le reprendra"
        );
        assert_eq!(
            line(&format!("{name}-rdx ")),
            "0",
            "et rien d'après n'a tourné ({name})"
        );
    }
}

/// **Un noyau qui atteint `invpcid` est arrêté par son nom, RIP dessus.**
///
/// `66 0f 38 82 /r` purge le tampon par identifiant de contexte (PCID), et
/// cette machine n'a pas de PCID : `cpuid` n'annonce ni `PCID` ni `INVPCID`, et
/// le noyau Alpine ne l'exécute que si les deux sont promis. Mais elle est à
/// 103 octets de `native_flush_tlb_one_user`, atteinte statiquement depuis le
/// trampoline des alternatives, et un décodeur qui ne la lisait pas refusait
/// la région entière — la même famille que l'`int3`, `lkgs` et `vmcall`.
///
/// Ce qui précède a tourné, RIP est posé **sur** l'instruction, ce qui suit
/// n'a pas tourné, et l'arrêt porte son nom.
#[test]
fn a_kernel_that_reaches_invpcid_is_stopped_by_name_on_the_instruction() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let mut program = vec![0x48, 0xc7, 0xc0, 0x2a, 0x00, 0x00, 0x00]; // movq $42, %rax
    program.extend_from_slice(&[0x66, 0x0f, 0x38, 0x82, 0x04, 0x24]); // invpcid (%rsp), %rax
    program.extend_from_slice(&[0x48, 0xff, 0xc2]); // incq %rdx — ne doit pas tourner
    let module = match Module::resolving_or_why(&program, BASE, 0, 0, PAGES) {
        Ok(module) => module,
        Err(why) => panic!(
            "`native_flush_tlb_one_user` doit se traduire, pas faire refuser la région : {why:?}"
        ),
    };
    let scratch = std::env::temp_dir().join(format!("wisq-host-invpcid-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let path = scratch.join("m.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("rax " + lire(0));
console.log("rdx " + lire(2));
console.log("rip " + lire({rip}));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    assert_eq!(
        line("arret "),
        "arrêtée sur invpcid : purger le tampon par identifiant de contexte, et cette machine n'a pas de PCID",
        "l'arrêt doit se nommer : {text}"
    );
    assert_eq!(line("rax "), "42", "les instructions d'avant tournent");
    assert_eq!(
        line("rip "),
        (BASE + 7).to_string(),
        "RIP est posé sur l'instruction, pas après : rien ne la reprendra"
    );
    assert_eq!(line("rdx "), "0", "et rien d'après n'a tourné");
}

/// **Un noyau qui charge le registre de tâche garde le sélecteur, et continue.**
///
/// `0f 00 d8`, `ltr %eax` : le noyau Alpine l'exécute dans
/// `cpu_init_exception_handling`, avec `0x40` — le sélecteur de son TSS — et
/// c'est le premier mur depuis la retpoline qui n'est pas de la famille de
/// l'`int3` : celui-là tourne pour de vrai. Le module range le sélecteur dans
/// sa case, seize bits quelle que soit la largeur de la source, et **ne
/// s'arrête pas** : ce qui suit tourne, jusqu'au `hlt`.
///
/// **Ce que ce nombre n'est pas** : aucun descripteur n'est lu derrière lui.
/// La délivrance de l'hôte dit toujours « cette machine n'a pas de TSS » ;
/// ce que les piles IST en feront est une question de direction, posée quand
/// elle sera atteinte.
#[test]
fn a_kernel_that_loads_the_task_register_keeps_the_selector_and_goes_on() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program: Vec<u8> = vec![
        0xb8, 0x40, 0x00, 0x34, 0x12, // movl $0x12340040, %eax — seize bits comptent
        0x0f, 0x00, 0xd8, // ltr %eax
        0x48, 0xff, 0xc2, // incq %rdx — doit tourner
        0xf4, // hlt
    ];
    let module = match Module::resolving_or_why(&program, BASE, 0, 0, PAGES) {
        Ok(module) => module,
        Err(why) => {
            panic!("`native_load_tr_desc` doit se traduire, pas faire refuser la région : {why:?}")
        }
    };
    let scratch = std::env::temp_dir().join(format!("wisq-host-ltr-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let path = scratch.join("m.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
console.log("arret " + why.stopped);
console.log("tache " + lire({task}));
console.log("rdx " + lire(2));
console.log("rip " + lire({rip}));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            task = TASK_SLOT,
            base = BASE,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    assert_eq!(
        line("arret "),
        "arrêtée sur hlt",
        "la machine ne s'arrête pas sur ltr, elle continue jusqu'au hlt : {text}"
    );
    assert_eq!(
        line("tache "),
        "64",
        "le sélecteur 0x40 est rangé, et seize bits seulement"
    );
    assert_eq!(line("rdx "), "1", "ce qui suit a tourné");
    assert_eq!(
        line("rip "),
        (BASE + program.len() as u64).to_string(),
        "RIP est après le hlt"
    );
}

/// **Les quatre registres de l'appel système sont rangés, et se relisent.**
///
/// `syscall_init` écrit `STAR`, `LSTAR`, `CSTAR` et `SYSCALL_MASK` — c'est là
/// que le noyau Alpine s'arrêtait « sur place », sur le premier des quatre.
/// Ce sont les registres que `syscall` lira un jour : la cible dans LSTAR, les
/// sélecteurs dans STAR, les drapeaux à éteindre dans le masque. Ils ont donc
/// une case chacun, comme EFER, et l'aller-retour `wrmsr` → `rdmsr` est
/// fidèle sur soixante-quatre bits — la moitié haute non nulle, exprès, parce
/// qu'une moitié haute perdue ne se voit que par la relecture.
///
/// **Ce que ces nombres ne sont pas** : rien ne les lit. `syscall` n'est pas
/// produite par l'émetteur ; accepter l'écriture dit « on la range », pas « on
/// l'applique », comme pour les registres de contrôle.
#[test]
fn the_four_syscall_registers_are_kept_and_read_back() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let mut program: Vec<u8> = Vec::new();
    // Quatre écritures : le numéro dans ECX, la moitié basse dans EAX, la haute
    // dans EDX — chacune reconnaissable.
    for (rank, number) in [0xc000_0081u32, 0xc000_0082, 0xc000_0083, 0xc000_0084]
        .into_iter()
        .enumerate()
    {
        let low = 0x1000_0000u32 + rank as u32;
        let high = 0xdead_0000u32 + rank as u32;
        program.push(0xb9);
        program.extend_from_slice(&number.to_le_bytes()); // mov $numéro,%ecx
        program.push(0xb8);
        program.extend_from_slice(&low.to_le_bytes()); // mov $bas,%eax
        program.push(0xba);
        program.extend_from_slice(&high.to_le_bytes()); // mov $haut,%edx
        program.extend_from_slice(&[0x0f, 0x30]); // wrmsr
    }
    // Relire LSTAR dans RSI, entière : la cible que `syscall` chargerait.
    program.extend_from_slice(&[0xb9, 0x82, 0x00, 0x00, 0xc0]); // mov $0xc0000082,%ecx
    program.extend_from_slice(&[0x0f, 0x32]); // rdmsr
    program.extend_from_slice(&[0x48, 0xc1, 0xe2, 0x20]); // shl $32,%rdx
    program.extend_from_slice(&[0x48, 0x09, 0xc2]); // or %rax,%rdx
    program.extend_from_slice(&[0x48, 0x89, 0xd6]); // mov %rdx,%rsi
    program.push(0xf4); // hlt
    let module = match Module::resolving_or_why(&program, BASE, 0, 0, PAGES) {
        Ok(module) => module,
        Err(why) => panic!("`syscall_init` doit se traduire : {why:?}"),
    };
    let scratch =
        std::env::temp_dir().join(format!("wisq-host-syscall-msr-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let path = scratch.join("m.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString(16);
console.log("arret " + why.stopped);
for (let i = 0; i < {count}; i++) console.log("case" + i + " " + lire({first} + i));
console.log("lstar " + lire(6));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            first = SYSCALL_SLOT,
            count = SYSCALL_COUNT,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    assert_eq!(
        line("arret "),
        "arrêtée sur hlt",
        "les quatre écritures passent, la machine va jusqu'au hlt : {text}"
    );
    for rank in 0..SYSCALL_COUNT {
        assert_eq!(
            line(&format!("case{rank} ")),
            format!("dead{rank:04x}1000{rank:04x}"),
            "STAR, LSTAR, CSTAR, SYSCALL_MASK dans cet ordre, soixante-quatre bits chacun"
        );
    }
    assert_eq!(
        line("lstar "),
        "dead000110000001",
        "et rdmsr relit LSTAR entière, moitié haute comprise"
    );
}

/// **Un MSR inconnu est délivré à l'invité comme une `#GP(0)`, et c'est le
/// gestionnaire qui décide.**
///
/// Sur le silicium, `wrmsr` sur un numéro qui n'existe pas lève une faute de
/// protection générale, code d'erreur zéro, RIP **sur** l'instruction — une
/// faute, pas un piège. Le noyau Linux le sait : `wrmsrl_safe` a une entrée
/// de table d'exceptions qui rend `-EIO`, et `native_write_msr` en a une
/// aussi qui écrit « unchecked MSR access error » sur le port série et
/// continue. C'est sur le premier registre SYSENTER, écrit par `wrmsrl_safe`
/// dans `syscall_init`, que le noyau Alpine s'arrêtait. Délivrer la faute,
/// c'est le laisser faire ce qu'il fait sur une vraie machine.
///
/// Le gestionnaire de ce test fait ce que fait la table d'exceptions du
/// noyau : il dépile le code d'erreur, avance le RIP empilé **après** le
/// `wrmsr`, et `iretq` reprend là. Ce que chaque assertion tient : le
/// gestionnaire a tourné (`rcx`), le code d'erreur est nul (`r8`), le cadre
/// porte l'instruction fautive et non la suivante, l'exécution a continué
/// après (`rbx`), la pile est revenue (six mots, code d'erreur compris), le
/// témoin d'arrêt est effacé, et l'arrêt final est le `ud2`.
#[test]
fn an_unknown_model_register_is_delivered_as_a_general_protection_fault() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 4;
    const BASE: u64 = 0x1_0000;
    const HANDLER: u64 = 0x1_1000;
    const IDT: u64 = 0x1_2000;
    const IDT_POINTER: u64 = 0x1_3000;
    const STACK: u64 = 0xf000;
    fn put(into: &mut Vec<u8>, bytes: &[u8]) {
        into.extend_from_slice(bytes);
    }
    let mut program: Vec<u8> = Vec::new();
    put(&mut program, &[0x48, 0xbb]); // movabs $IDT_POINTER,%rbx
    put(&mut program, &IDT_POINTER.to_le_bytes());
    put(&mut program, &[0x0f, 0x01, 0x1b]); // lidt (%rbx)
    put(&mut program, &[0x48, 0xc7, 0xc4]); // mov $STACK,%rsp
    put(&mut program, &(STACK as u32).to_le_bytes());
    put(&mut program, &[0x48, 0xc7, 0xc3, 0x11, 0x11, 0x00, 0x00]); // mov $0x1111,%rbx
    put(&mut program, &[0xb9, 0x23, 0x01, 0x00, 0x00]); // mov $0x123,%ecx — un MSR inconnu
    put(&mut program, &[0xb8, 0x01, 0x00, 0x00, 0x00]); // mov $1,%eax
    put(&mut program, &[0x31, 0xd2]); // xor %edx,%edx
    let faults_at = BASE + program.len() as u64;
    put(&mut program, &[0x0f, 0x30]); // wrmsr — la #GP
    let after_wrmsr = BASE + program.len() as u64;
    put(&mut program, &[0x48, 0xc7, 0xc3, 0x22, 0x22, 0x00, 0x00]); // mov $0x2222,%rbx
    let ud2_at = BASE + program.len() as u64;
    put(&mut program, &[0x0f, 0x0b]); // ud2
                                      // Le gestionnaire fait ce que fait la table d'exceptions du noyau :
                                      // dépiler le code d'erreur, avancer le RIP empilé après le wrmsr, rendre.
    let handler: Vec<u8> = vec![
        0x48, 0xc7, 0xc1, 0x33, 0x33, 0x00, 0x00, // mov $0x3333,%rcx
        0x41, 0x58, // pop %r8 — le code d'erreur
        0x4c, 0x8b, 0x0c, 0x24, // mov (%rsp),%r9 — le RIP empilé, tel que délivré
        0x48, 0x83, 0x04, 0x24, 0x02, // addq $2,(%rsp) — RIP après le wrmsr
        0x48, 0xcf, // iretq
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-gp-msr-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut served = String::new();
    for (name, bytes, at, slot) in [
        ("programme.wasm", &program[..], BASE, 0u32),
        ("gestionnaire.wasm", &handler[..], HANDLER, 1),
        (
            "reprise.wasm",
            &program[(after_wrmsr - BASE) as usize..],
            after_wrmsr,
            2,
        ),
    ] {
        let module = Module::resolving(bytes, at, 0, slot, PAGES)
            .unwrap_or_else(|| panic!("{name} se traduit"));
        let path = scratch.join(name);
        std::fs::write(&path, &module).expect(name);
        served.push_str(&format!(
            "    if (address === {at}n && slot === {slot}) return readFileSync({:?});\n",
            path.to_string_lossy()
        ));
    }
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
const vm = machine({{
  translate: async (address, slot) => {{
{served}    return null;
  }},
  pages: {pages},
}});
const vue = new DataView(vm.memory.buffer);
const porte = (offset) => [
  (BigInt(offset) & 0xffffn) | (0x10n << 16n) | (0x0en << 40n) | (1n << 47n)
    | ((BigInt(offset) & 0xffff0000n) << 32n),
  BigInt(offset) >> 32n,
];
const [bas, haut] = porte({handler});
vue.setBigUint64({idt} + 13 * 16, bas, true);
vue.setBigUint64({idt} + 13 * 16 + 8, haut, true);
vue.setUint16({idtPointer}, 256 * 16 - 1, true);
vue.setBigUint64({idtPointer} + 2, {idt}n, true);
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 256n, rounds: 16 }});
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value).toString();
const mot = (at) => vue.getBigUint64(at, true).toString();
console.log("arret " + why.stopped);
console.log("rbx " + lire(3));
console.log("rcx " + lire(1));
console.log("r8 " + lire(8));
console.log("r9 " + lire(9));
console.log("rsp " + lire(4));
console.log("rip " + lire({rip}));
console.log("stop " + lire({stop}));
console.log("cadre-rip " + mot({stack} - 8 * 5));
console.log("cadre-code " + mot({stack} - 8 * 6));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            stop = wisq_vm::x86_wasm::STOP_SLOT,
            base = BASE,
            handler = HANDLER,
            idt = IDT,
            idtPointer = IDT_POINTER,
            stack = STACK,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    let number = |name: &str| line(name).parse::<u64>().expect("un nombre");
    assert_eq!(
        line("arret "),
        "refusée",
        "l'arrêt final est le ud2, pas le MSR : {text}"
    );
    assert_eq!(
        number("rcx "),
        0x3333,
        "le gestionnaire du vecteur 13 a tourné"
    );
    assert_eq!(
        number("r8 "),
        0,
        "le code d'erreur d'une #GP sur un MSR est nul"
    );
    // **Le RIP délivré se lit dans le gestionnaire, pas dans la mémoire après
    // coup** : le gestionnaire l'a avancé dans le cadre avant `iretq`, comme la
    // table d'exceptions du noyau le fait, et c'est ce cadre-là qui reste.
    assert_eq!(
        number("r9 "),
        faults_at,
        "le cadre portait le wrmsr lui-même : une faute, pas un piège"
    );
    assert_eq!(
        number("cadre-rip "),
        after_wrmsr,
        "et c'est le gestionnaire qui l'a avancé, dans le cadre"
    );
    assert_eq!(
        number("cadre-code "),
        0,
        "et le code d'erreur empilé est nul"
    );
    assert_eq!(
        number("rbx "),
        0x2222,
        "l'exécution a repris après le wrmsr, là où le gestionnaire l'a posée"
    );
    assert_eq!(
        number("rsp "),
        STACK,
        "iretq a rendu la pile : six mots, code d'erreur compris"
    );
    assert_eq!(number("rip "), ud2_at, "RIP est sur le ud2");
    assert_eq!(
        number("stop "),
        0,
        "le témoin d'arrêt est effacé une fois la faute délivrée"
    );
}

/// **Un `lldt` nul passe et continue ; un `lldt` non nul s'arrête par son
/// nom, RIP dessus.**
///
/// Le noyau Alpine n'a pas de LDT : `native_set_ldt` charge le sélecteur nul
/// depuis `load_mm_ldt`, dans `cpu_init`, et c'est exactement ce qu'une
/// machine sans table de descripteurs sait faire — rien. Un sélecteur non
/// nul désignerait un descripteur dans la GDT, qu'aucune table ne porte ici :
/// l'arrêt le dit, comme pour FS et GS, plutôt que de faire croire à une LDT
/// chargée.
///
/// Les deux cas dans le même test, seize bits dans les deux : `%si` porte
/// zéro sous une moitié haute non nulle dans le premier, `0x28` dans le
/// second.
#[test]
fn a_null_ldt_goes_on_and_a_real_one_is_stopped_by_name() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program = |selector: u32| -> Vec<u8> {
        let mut bytes = vec![0xbe]; // movl $…,%esi
        bytes.extend_from_slice(&selector.to_le_bytes());
        bytes.extend_from_slice(&[0x0f, 0x00, 0xd6]); // lldt %esi
        bytes.extend_from_slice(&[0x48, 0xff, 0xc2]); // incq %rdx
        bytes.push(0xf4); // hlt
        bytes
    };
    let scratch = std::env::temp_dir().join(format!("wisq-host-lldt-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut listing = String::new();
    // La moitié haute non nulle du premier : seuls seize bits comptent.
    for (name, selector) in [("nul", 0xabcd_0000u32), ("reel", 0x28)] {
        let module = match Module::resolving_or_why(&program(selector), BASE, 0, 0, PAGES) {
            Ok(module) => module,
            Err(why) => panic!("`native_set_ldt` doit se traduire ({name}) : {why:?}"),
        };
        let path = scratch.join(format!("{name}.wasm"));
        std::fs::write(&path, &module).expect("le module");
        listing.push_str(&format!("[{name:?},{:?}],", path.to_string_lossy()));
    }
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
for (const [name, path] of [{listing}]) {{
  let asked = 0;
  const vm = machine({{
    translate: async () => (asked++ === 0 ? readFileSync(path) : null),
    pages: {pages},
  }});
  vm.globals[{rip}].value = {base}n;
  const why = await vm.run({{ budget: 64n, rounds: 16 }});
  const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString();
  console.log(name + "-arret " + why.stopped);
  console.log(name + "-rdx " + lire(2));
  console.log(name + "-rip " + lire({rip}));
}}
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            listing = listing,
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    assert_eq!(
        line("nul-arret "),
        "arrêtée sur hlt",
        "le sélecteur nul passe, la machine va jusqu'au hlt : {text}"
    );
    assert_eq!(line("nul-rdx "), "1", "et ce qui suit a tourné");
    assert_eq!(
        line("nul-rip "),
        (BASE + 12).to_string(),
        "RIP est après le hlt"
    );
    assert_eq!(
        line("reel-arret "),
        "arrêtée sur lldt : une table de descripteurs locale non nulle, sans table globale où la trouver",
        "le sélecteur non nul s'arrête par son nom : {text}"
    );
    assert_eq!(line("reel-rdx "), "0", "et rien d'après n'a tourné");
    assert_eq!(
        line("reel-rip "),
        (BASE + 5).to_string(),
        "RIP est posé sur le lldt, pas après"
    );
}

/// **Effacer les registres de débogage passe et se relit ; en armer un
/// s'arrête par son nom.**
///
/// `cpu_init` écrit zéro dans DR0 à DR3 et DR7, et `DR6_RESERVED`
/// (`0xffff0ff0`) dans DR6 : c'est l'état de repos du silicium, et c'est
/// l'état de cette machine, qui n'a pas de points d'arrêt matériels. Ces
/// écritures-là passent, parce qu'elles ne changent rien de vrai. Une
/// lecture rend ce que le silicium rend au repos : DR7 porte son bit 10
/// toujours à un, DR6 ses bits réservés, les quatre adresses valent zéro.
/// Écrire autre chose — armer un point d'arrêt — est un arrêt nommé, RIP
/// dessus : le dire vaut mieux qu'un point d'arrêt qui ne déclencherait
/// jamais.
#[test]
fn clearing_the_debug_registers_goes_on_and_arming_one_is_stopped_by_name() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let mut clearing: Vec<u8> = Vec::new();
    clearing.extend_from_slice(&[0x31, 0xc0]); // xor %eax,%eax
    for which in [0u8, 1, 2, 3] {
        clearing.extend_from_slice(&[0x0f, 0x23, 0xc0 | (which << 3)]); // mov %rax,%drN
    }
    clearing.extend_from_slice(&[0xb8, 0xf0, 0x0f, 0xff, 0xff]); // mov $0xffff0ff0,%eax
    clearing.extend_from_slice(&[0x0f, 0x23, 0xf0]); // mov %rax,%dr6
    clearing.extend_from_slice(&[0x31, 0xc0]); // xor %eax,%eax
    clearing.extend_from_slice(&[0x0f, 0x23, 0xf8]); // mov %rax,%dr7
    clearing.extend_from_slice(&[0x0f, 0x21, 0xfb]); // mov %dr7,%rbx
    clearing.extend_from_slice(&[0x0f, 0x21, 0xf1]); // mov %dr6,%rcx
    clearing.extend_from_slice(&[0x0f, 0x21, 0xc6]); // mov %dr0,%rsi
    clearing.extend_from_slice(&[0x48, 0xff, 0xc2]); // incq %rdx
    clearing.push(0xf4); // hlt
    let arming: Vec<u8> = vec![
        0xb8, 0x01, 0x00, 0x00, 0x00, // mov $1,%eax — L0 : armer le point d'arrêt 0
        0x0f, 0x23, 0xf8, // mov %rax,%dr7
        0x48, 0xff, 0xc2, // incq %rdx — ne doit pas tourner
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-host-debugreg-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut listing = String::new();
    for (name, program) in [("efface", &clearing), ("arme", &arming)] {
        let module = match Module::resolving_or_why(program, BASE, 0, 0, PAGES) {
            Ok(module) => module,
            Err(why) => panic!("`cpu_init` doit se traduire ({name}) : {why:?}"),
        };
        let path = scratch.join(format!("{name}.wasm"));
        std::fs::write(&path, &module).expect("le module");
        listing.push_str(&format!("[{name:?},{:?}],", path.to_string_lossy()));
    }
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
for (const [name, path] of [{listing}]) {{
  let asked = 0;
  const vm = machine({{
    translate: async () => (asked++ === 0 ? readFileSync(path) : null),
    pages: {pages},
  }});
  vm.globals[{rip}].value = {base}n;
  const why = await vm.run({{ budget: 64n, rounds: 16 }});
  const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString(16);
  console.log(name + "-arret " + why.stopped);
  console.log(name + "-rbx " + lire(3));
  console.log(name + "-rcx " + lire(1));
  console.log(name + "-rsi " + lire(6));
  console.log(name + "-rdx " + lire(2));
  console.log(name + "-rip " + lire({rip}));
}}
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            listing = listing,
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    assert_eq!(
        line("efface-arret "),
        "arrêtée sur hlt",
        "effacer les six registres passe, la machine va jusqu'au hlt : {text}"
    );
    assert_eq!(
        line("efface-rbx "),
        "400",
        "DR7 se relit avec son bit 10 toujours à un"
    );
    assert_eq!(
        line("efface-rcx "),
        "ffff0ff0",
        "DR6 se relit avec ses bits réservés"
    );
    assert_eq!(line("efface-rsi "), "0", "DR0 se relit à zéro");
    assert_eq!(line("efface-rdx "), "1", "et ce qui suit a tourné");
    assert_eq!(
        line("arme-arret "),
        "arrêtée sur une écriture dans un registre de débogage : cette machine n'a pas de points d'arrêt matériels",
        "armer un point d'arrêt s'arrête par son nom : {text}"
    );
    assert_eq!(line("arme-rdx "), "0", "et rien d'après n'a tourné");
    assert_eq!(
        line("arme-rip "),
        format!("{:x}", BASE + 5),
        "RIP est posé sur l'écriture, pas après"
    );
}

/// **`cmpxchg16b`, compilé par JavaScriptCore : la paire écrite quand les deux
/// moitiés tiennent, relue sinon, et ZF seul qui bouge.**
///
/// C'est le mur de `___slab_alloc + 275`, le chemin rapide de la liste libre
/// de SLUB. Les tests Rust de l'émetteur lisent les octets du module ; ici le
/// module tourne. Le programme pose une paire en mémoire, la remplace par un
/// `cmpxchg16b` qui réussit, dépile ses drapeaux dans R8, change la moitié
/// basse de RAX, réessaie — l'échec recharge RDX:RAX depuis la mémoire —, et
/// dépile ses drapeaux dans R9. Les drapeaux partent de zéro et rien d'autre
/// ne les touche : ZF doit être **le seul** bit arithmétique après le succès,
/// et aucun après l'échec.
#[test]
fn cmpxchg16b_under_javascriptcore_writes_the_pair_or_reloads_it_and_moves_only_zf() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    const DATA: u64 = 0x2000;
    const A_LOW: u64 = 0x1111_2222_3333_4444;
    const A_HIGH: u64 = 0x5555_6666_7777_8888;
    const N_LOW: u64 = 0x9999_aaaa_bbbb_cccc;
    const N_HIGH: u64 = 0xdddd_eeee_ffff_0000;
    const P_LOW: u64 = 0x0123_4567_89ab_cdef;
    const P_HIGH: u64 = 0xfedc_ba98_7654_3210;
    let mut program: Vec<u8> = Vec::new();
    let mut push = |bytes: &[u8]| program.extend_from_slice(bytes);
    push(&[0x48, 0xc7, 0xc4, 0x00, 0x10, 0x00, 0x00]); // mov $0x1000,%rsp
    push(&[0x48, 0xc7, 0xc6]);
    push(&(DATA as u32).to_le_bytes()); // mov $DATA,%rsi
    push(&[0x48, 0xb8]);
    push(&A_LOW.to_le_bytes()); // movabs $A_LOW,%rax
    push(&[0x48, 0xba]);
    push(&A_HIGH.to_le_bytes()); // movabs $A_HIGH,%rdx
    push(&[0x48, 0xbb]);
    push(&N_LOW.to_le_bytes()); // movabs $N_LOW,%rbx
    push(&[0x48, 0xb9]);
    push(&N_HIGH.to_le_bytes()); // movabs $N_HIGH,%rcx
    push(&[0x48, 0x89, 0x46, 0x20]); // mov %rax,0x20(%rsi)
    push(&[0x48, 0x89, 0x56, 0x28]); // mov %rdx,0x28(%rsi)
    push(&[0xf0, 0x48, 0x0f, 0xc7, 0x4e, 0x20]); // lock cmpxchg16b 0x20(%rsi) — réussit
    push(&[0x9c, 0x41, 0x58]); // pushfq ; pop %r8
    push(&[0x48, 0xb8]);
    push(&(A_LOW ^ 1).to_le_bytes()); // movabs $A_LOW^1,%rax
    push(&[0x48, 0x0f, 0xc7, 0x4e, 0x20]); // cmpxchg16b 0x20(%rsi) — échoue, recharge
    push(&[0x9c, 0x41, 0x59]); // pushfq ; pop %r9
                               // RDX:RAX portent maintenant la paire neuve. Seule la moitié haute est
                               // changée : un émetteur qui ne comparerait que huit octets écrirait ici.
    push(&[0x48, 0xba]);
    push(&(N_HIGH ^ 1).to_le_bytes()); // movabs $N_HIGH^1,%rdx
    push(&[0x48, 0xbb]);
    push(&P_LOW.to_le_bytes()); // movabs $P_LOW,%rbx
    push(&[0x48, 0xb9]);
    push(&P_HIGH.to_le_bytes()); // movabs $P_HIGH,%rcx
    push(&[0xf0, 0x48, 0x0f, 0xc7, 0x4e, 0x20]); // lock cmpxchg16b — échoue sur la moitié haute
    push(&[0x9c, 0x41, 0x5a]); // pushfq ; pop %r10
    push(&[0xf4]); // hlt
    let module = match Module::resolving_or_why(&program, BASE, 0, 0, PAGES) {
        Ok(module) => module,
        Err(why) => {
            panic!("`___slab_alloc` doit se traduire, pas faire refuser la région : {why:?}")
        }
    };
    let scratch = std::env::temp_dir().join(format!("wisq-host-cmpxchg16b-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let path = scratch.join("m.wasm");
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
  translate: async () => (asked++ === 0 ? readFileSync({path:?}) : null),
  pages: {pages},
}});
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString(16);
const vue = new DataView(vm.memory.buffer);
console.log("arret " + why.stopped);
console.log("rax " + lire(0));
console.log("rdx " + lire(2));
console.log("rbx " + lire(3));
console.log("rcx " + lire(1));
console.log("r8 " + lire(8));
console.log("r9 " + lire(9));
console.log("r10 " + lire(10));
console.log("bas " + vue.getBigUint64({low}, true).toString(16));
console.log("haut " + vue.getBigUint64({high}, true).toString(16));
console.log("rip " + lire({rip}));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            low = DATA + 0x20,
            high = DATA + 0x28,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or_else(|| panic!("le pilote doit dire « {name} » : {text}"))
            .trim()
            .to_string()
    };
    let hex = |name: &str| u64::from_str_radix(&line(name), 16).expect("un nombre");
    assert_eq!(
        line("arret "),
        "arrêtée sur hlt",
        "la machine ne s'arrête pas sur cmpxchg16b, elle continue jusqu'au hlt : {text}"
    );
    // Le succès a écrit RCX:RBX en mémoire ; les deux échecs n'y ont rien
    // touché.
    assert_eq!(hex("bas "), N_LOW, "la moitié basse reçoit RBX");
    assert_eq!(hex("haut "), N_HIGH, "la moitié haute reçoit RCX");
    // Chaque échec a rechargé RDX:RAX depuis la mémoire — donc la paire
    // neuve, la moitié haute comprise après le troisième essai.
    assert_eq!(hex("rax "), N_LOW, "l'échec recharge RAX depuis la mémoire");
    assert_eq!(
        hex("rdx "),
        N_HIGH,
        "l'échec recharge RDX depuis la mémoire"
    );
    assert_eq!(hex("rbx "), P_LOW, "RBX n'est que lu");
    assert_eq!(hex("rcx "), P_HIGH, "RCX n'est que lu");
    let after_success = hex("r8 ");
    let after_failure = hex("r9 ");
    let after_high_failure = hex("r10 ");
    assert_eq!(
        after_high_failure & wisq_vm::x86::ARITHMETIC,
        0,
        "la moitié haute seule qui diffère est un échec : {after_high_failure:#x}"
    );
    assert_eq!(
        after_success & wisq_vm::x86::ARITHMETIC,
        wisq_vm::x86::ZF,
        "le succès pose ZF et rien d'autre : {after_success:#x}"
    );
    assert_eq!(
        after_failure & wisq_vm::x86::ARITHMETIC,
        0,
        "l'échec éteint ZF et ne pose rien : {after_failure:#x}"
    );
    assert_ne!(after_success & ALWAYS_ONE, 0, "un vrai RFLAGS");
    assert_eq!(
        hex("rip "),
        BASE + program.len() as u64,
        "RIP est après le hlt"
    );
}
