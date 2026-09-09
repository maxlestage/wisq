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
    RIP_SLOT, TABLE_ENTRY, TABLE_PAGES, TABLE_SLOTS,
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

/// **Les MSR : trois numéros modélisés, et un arrêt nommé pour tous les autres.**
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
/// **Un numéro qu'on ne modélise pas rend la main à son adresse.** Ne rien
/// faire serait le pire des trois choix : le noyau croirait avoir posé une
/// valeur, et la panne tomberait ailleurs. L'arrêt porte l'adresse de
/// l'instruction, et le test le vérifie en la distinguant de celle du `ud2`
/// qui suit — sans quoi « ça s'est arrêté » ne prouverait pas « ça s'est
/// arrêté là ».
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
        Some("arret refusée"),
        "la machine s'arrête : {text}"
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
/// **Ce que ça ne fait pas** : aucune `#PF` n'est délivrée à l'invité. Le
/// noyau ne reprend pas la main sur son propre gestionnaire ; c'est l'hôte qui
/// s'arrête. Les interruptions sont le mur suivant.
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
await vm.run({{ budget: 256n, rounds: 4 }});
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value).toString();
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
    assert_ne!(number("faute "), 0, "le témoin de faute est posé : {text}");
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
