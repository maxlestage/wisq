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

use wisq_vm::x86::{ALWAYS_ONE, WRITABLE_FLAGS, ZF};
use wisq_vm::x86_wasm::{
    table_slot, Module, CONTROL_SLOT, EFER_SLOT, FAULT_SLOT, FPU_CONTROL_POWER_ON,
    FPU_CONTROL_SLOT, FPU_STATUS_SLOT, FS_BASE_SLOT, FXSAVE_WRITTEN, GLOBAL_COUNT, GS_SLOT,
    RFLAGS_SLOT, RIP_SLOT, SEGMENT_SLOT, SYSCALL_COUNT, SYSCALL_SLOT, TABLE_ENTRY, TABLE_PAGES,
    TABLE_SLOT, TABLE_SLOTS, TASK_SLOT,
};

/// **Ce qu'un `ud2` rend quand aucune IDT ne le rattrape**, depuis #227.
///
/// Avant, un `ud2` ne posait aucun témoin : l'hôte ne voyait qu'un retour de
/// main sur une adresse inconnue, redemandait la même région, et concluait
/// « refusée » ou « sur place » selon ce que le pilote répondait. Les deux
/// noms décrivaient le pilote, pas la machine. Celui-ci décrit la machine.
const UD2_SANS_PORTE: &str =
    "une instruction indéfinie (ud2) sans porte : aucune IDT ne porte le vecteur 6";

/// **La faute de page quand aucune IDT ne la recueille.** Le pendant du
/// précédent pour le vecteur 14 ; le montage de `fxrstor` s'en sert pour
/// montrer qu'une aire incomplète fait faute au lieu de passer.
const FAUTE_SANS_PORTE: &str = "une faute de page sans porte : aucune IDT ne porte le vecteur 14";

/// **La même, quand une IDT existe mais ne porte pas la porte 6.** Les trois
/// montages à IDT de ce fichier n'installent que la porte dont ils ont besoin ;
/// leur `ud2` final tombe donc sur une porte absente, ce que l'hôte distingue
/// d'une IDT manquante — et c'est la distinction qui compte pour diagnostiquer.
const UD2_PORTE_ABSENTE: &str =
    "une instruction indéfinie (ud2) sans porte : la porte du vecteur 6 n'est pas présente";

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
    // **Le nombre de voies par seau, comparé dès son arrivée.** L'hôte choisit
    // la voie où il range une adresse ; le module, lui, consulte un nombre de
    // voies gravé dans ses octets. S'ils divergent, l'hôte rangerait dans une
    // voie que le module ne lit jamais — et rien ne s'arrêterait : la région
    // ne serait simplement plus trouvée, le défaut muet que cette tranche
    // vient de réduire, revenu par la porte de derrière.
    assert_eq!(
        value("tableWays"),
        wisq_vm::x86_wasm::TABLE_WAYS.to_string(),
        "le nombre de voies par seau"
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
    // **Les deux mots du coprocesseur, tenus dès leur arrivée.** Ils ne sont
    // relus par personne côté hôte, et c'est justement pourquoi une case
    // fausse ici ne se verrait pas : `fninit` remettrait à 0x037F une autre
    // globale — un sélecteur de segment, un registre de contrôle — pendant
    // que le mot de contrôle garderait ce qu'il avait. Rien ne s'arrêterait ;
    // le noyau lirait plus tard un état qu'il n'a pas posé.
    assert_eq!(
        value("fpuControl"),
        FPU_CONTROL_SLOT.to_string(),
        "l'emplacement du mot de contrôle du coprocesseur"
    );
    assert_eq!(
        value("fpuStatus"),
        FPU_STATUS_SLOT.to_string(),
        "l'emplacement du mot d'état du coprocesseur"
    );
    assert_eq!(
        value("fpuControlPowerOn"),
        format!("0x{:x}", FPU_CONTROL_POWER_ON),
        "le mot de contrôle que l'hôte pose au démarrage"
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

/// **Une adresse de retour au milieu d'une région connue est une région de
/// plus, et elle n'a pas lieu d'être.**
///
/// La correspondance est indexée par l'adresse d'**entrée** d'une région, pas
/// par les débuts de blocs qu'elle contient. Une cible indirecte qui retombe
/// au milieu d'une région déjà traduite n'y est donc pas trouvée : le module
/// rend la main, et l'hôte fabrique une seconde région qui **recouvre** la
/// première. C'est correct, et c'est du gaspillage.
///
/// **Ce n'est pas un cas de laboratoire.** Sur le relevé du noyau Alpine,
/// 1559 des 5514 régions demandées — 28 % — sont à moins de seize octets après
/// une région déjà demandée, l'écart le plus fréquent étant neuf octets
/// (743 fois), puis cinq (395). Ce sont les octets qui **suivent** un `call`,
/// c'est-à-dire les adresses où les `ret` retombent.
///
/// **Le montage, et pourquoi cet anneau-là.** Deux régions seulement, et l'une
/// des deux jambes de l'anneau vise un bloc qui n'est l'entrée de rien :
///
///   * `A` à `BASE` porte deux blocs. Le premier charge `SECOND` dans RAX et
///     se coupe sur un `jnz` ; le second est un `jmp *%rax`.
///   * `B` à `SECOND` charge l'adresse du **second bloc de A** dans RBX,
///     incrémente RDX, et y saute indirectement.
///
/// L'anneau tourne donc entre le second bloc de A et B — et la cible qui
/// revient vers A n'est pas son entrée.
///
/// **Le second temps tient en un seul appel, et c'est ce qui le rend
/// concluant.** Sur plusieurs tours, l'hôte finirait par redemander le bloc
/// pour une raison qui n'est pas celle qu'on mesure : le budget s'épuise
/// quelque part dans l'anneau, et si c'est sur le second bloc de A, la boucle
/// hôte ne reconnaît pas cette adresse — sa carte `known` est indexée par
/// entrée de région, comme la correspondance l'était. C'est un cas résiduel,
/// nommé plus bas, et le mesurer ici masquerait le mécanisme.
///
/// Un seul appel l'isole : si la correspondance porte le second bloc de A,
/// l'anneau tourne entièrement dans WebAssembly et RDX compte des centaines
/// de tours ; sinon la première jambe rend la main et RDX vaut un. Les deux
/// assertions se tiennent l'une l'autre — RDX dit que l'anneau a tourné, le
/// compte de traductions dit qu'il l'a fait sans repasser par l'hôte.
///
/// **Ce que cette tranche ne fait pas.** Quand le budget expire exactement sur
/// un début de bloc, l'hôte traduit encore une région qui commence là : la
/// correspondance connaît l'adresse, sa carte `known` non. C'est une fois par
/// budget au pire, contre une fois par `ret` avant, et le corriger demanderait
/// que `run` puisse démarrer ailleurs qu'à l'entrée de sa région — un
/// changement de sa signature, donc une autre tranche.
#[test]
fn a_target_inside_a_known_region_needs_no_second_translation() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    const SECOND: u64 = BASE + 0x100;
    // Le second bloc de A commence après `incq %r8` (3), `movabs` (10),
    // `testq` (3) et `jnz` (2). Écrit en toutes lettres plutôt que recalculé :
    // le relevé le vérifie juste après, donc un décalage faux se voit ici et
    // pas trois assertions plus loin.
    const INSIDE: u64 = BASE + 18;

    // **`incq %r8` est le témoin du bon bloc, et il a fallu un sabotage pour
    // qu'il existe.** Sans lui, ranger l'emplacement de la **région** au lieu
    // de celui du **bloc** passait le test : l'invité rentrait par l'entrée de
    // A à chaque tour au lieu de son second bloc, refaisait le `movabs` et
    // repartait — un anneau qui tourne, un RDX qui monte, et personne pour
    // dire que la machine n'était pas là où la correspondance prétendait
    // l'envoyer. C'est le défaut le plus difficile à voir de toute cette
    // machinerie, et il avait survécu.
    //
    // R8 ne s'incrémente que dans le premier bloc. Il doit valoir **un** :
    // l'entrée de A est franchie une seule fois, au tout début.
    let mut first = vec![0x49, 0xff, 0xc0]; // incq %r8
    first.extend_from_slice(&[0x48, 0xb8]); // movabs $SECOND, %rax
    first.extend_from_slice(&SECOND.to_le_bytes());
    first.extend_from_slice(&[0x48, 0x85, 0xc0]); // testq %rax, %rax
    first.extend_from_slice(&[0x75, 0x00]); // jnz +0 : coupe le bloc
    first.extend_from_slice(&[0xff, 0xe0]); // jmp *%rax

    let mut second = vec![0x48, 0xbb]; // movabs $INSIDE, %rbx
    second.extend_from_slice(&INSIDE.to_le_bytes());
    second.extend_from_slice(&[0x48, 0xff, 0xc2]); // incq %rdx
    second.extend_from_slice(&[0xff, 0xe3]); // jmp *%rbx

    // **Le relevé, avant toute exécution.** Sans lui, une région d'un seul
    // bloc rendrait le test vert pour la mauvaise raison : la cible serait
    // l'entrée, et il n'y aurait rien à trouver au milieu.
    let outline = Module::outline(&first, 0).expect("le relevé de la première région");
    assert_eq!(
        outline.len(),
        2,
        "la première région doit porter deux blocs"
    );
    assert_eq!(
        BASE + outline[1].start as u64,
        INSIDE,
        "et son second bloc doit commencer là où la seconde région vise"
    );

    let scratch = std::env::temp_dir().join(format!("wisq-inside-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut catalogue = String::new();
    let mut loaded = String::new();
    for (address, code) in [(BASE, &first), (SECOND, &second), (INSIDE, &first)] {
        // La troisième entrée est ce que l'hôte demanderait s'il ne trouvait
        // pas `INSIDE` : une région qui **commence** au second bloc de A. Le
        // catalogue la porte exprès — sans elle le pilote échouerait sur une
        // traduction manquante au lieu de la compter, et « ça s'est arrêté »
        // ne dirait pas *pourquoi*.
        let entry = usize::try_from(address - BASE.min(address)).unwrap_or(0);
        let bytes = if address == INSIDE {
            &code[15..]
        } else {
            &code[..]
        };
        let _ = entry;
        let raw = scratch.join(format!("r{address:x}.bin"));
        std::fs::write(&raw, bytes).expect("le code");
        if address != INSIDE {
            loaded.push_str(&format!(
                "[{},{:?}],",
                address & u64::from(PAGES * 65536 - 1),
                raw.to_string_lossy()
            ));
        }
        for slot in 0..8u32 {
            let module = Module::resolving(bytes, address, 0, slot, PAGES)
                .unwrap_or_else(|| panic!("l'émetteur doit compiler la région {address:x}"));
            let path = scratch.join(format!("r{address:x}-{slot}.wasm"));
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
const posé = new Map(
  [{loaded}].map(([at, path]) => [at, new Uint8Array(readFileSync(path))]),
);
let asked = 0;
const seen = [];
const translate = async (address, slot, code) => {{
  asked++;
  seen.push(address.toString(16));
  if (!(code instanceof Uint8Array) || code.length === 0) {{
    throw new Error(`la demande à ${{address.toString(16)}} ne porte pas d'octets`);
  }}
  const path = catalogue.get(address + ":" + slot);
  return path === undefined ? null : readFileSync(path);
}};

const vm = machine({{ translate, pages: {pages} }});
for (const [at, octets] of posé) {{
  new Uint8Array(vm.memory.buffer, at, octets.length).set(octets);
}}
vm.globals[{rip}].value = {base}n;
// **Premier temps : la découverte.** Deux régions, deux traductions. Rien ne
// se prouve ici — la correspondance ne peut pas aider tant que la cible n'y
// est pas.
await vm.run({{ budget: 40n, rounds: 2 }});
console.log("demandes " + asked);
console.log("vues " + seen.join(","));

// **Second temps, et c'est celui qui compte.** Un seul tour, gros budget, en
// repartant de l'entrée. Si la correspondance porte le second bloc de A,
// l'anneau tourne entièrement dans WebAssembly jusqu'au bout du budget.
// Sinon, la jambe qui revient vers A rend la main au premier passage.
vm.globals[{rip}].value = {base}n;
vm.globals[2].value = 0n;
// R8 est remis à zéro ici, pas au début : le premier temps franchit l'entrée
// lui aussi, et compter les deux rendrait l'attente dépendante du montage.
vm.globals[8].value = 0n;
const avant = asked;
const run = await vm.run({{ budget: 400n, rounds: 1 }});
console.log("arret " + run.stopped);
console.log("retraductions " + (asked - avant));
console.log("regions " + vm.known.size);
console.log("rdx " + vm.globals[2].value.toString());
console.log("r8 " + vm.globals[8].value.toString());
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            catalogue = catalogue,
            loaded = loaded,
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

    // La découverte : une traduction par région, dans l'ordre où on y arrive.
    assert_eq!(
        seen("demandes"),
        "2",
        "deux régions, deux traductions : {text}"
    );
    assert_eq!(seen("vues"), "10000,10100", "et dans cet ordre : {text}");

    // **L'anneau doit avoir tourné.** Sans cette ligne, une machine qui
    // s'arrête au premier saut passerait les deux assertions suivantes en
    // n'ayant rien traduit du tout — le zéro le plus facile à obtenir.
    let laps: u64 = seen("rdx").parse().expect("RDX est un nombre");
    assert!(
        laps > 100,
        "l'anneau doit avoir tourné des dizaines de fois dans un seul appel ; \
         un ou deux tours veut dire que la jambe qui revient vers la première \
         région a rendu la main : {text}"
    );
    assert_eq!(
        seen("retraductions"),
        "0",
        "une cible qui tombe sur un bloc déjà traduit se trouve dans la \
         correspondance, et ne coûte pas une région de plus : {text}"
    );
    assert_eq!(
        seen("regions"),
        "2",
        "et aucune région ne recouvre la première : {text}"
    );
    // **Et l'invité est allé dans le bon bloc, pas seulement dans la bonne
    // région.** R8 ne bouge que dans le premier bloc de A ; s'il vaut plus de
    // un, la correspondance renvoie à l'**entrée** de la région au lieu du
    // bloc visé. C'est ce qu'un mauvais emplacement rangé produirait, et rien
    // d'autre ici ne le distinguerait d'un anneau correct.
    assert_eq!(
        seen("r8"),
        "1",
        "le premier bloc de la première région ne doit être franchi qu'une \
         fois : la correspondance doit désigner le bloc, pas la région : {text}"
    );
}

/// **Un début de bloc n'évince jamais l'entrée d'une région.**
///
/// La correspondance a deux voies par seau. Y ranger les débuts de blocs
/// multiplie par dix le nombre d'adresses qui s'y disputent la place, et la
/// première version de cette tranche laissait un bloc chasser une entrée
/// quand les deux voies étaient prises. Le noyau Alpine allait alors **moins**
/// loin qu'avant la correction : 72 lignes série au lieu de 87, et les retours
/// de main sur `pv_native_irq_disable` passaient de 2938 à 66 340 — les
/// fonctions les plus chaudes se faisaient évincer par des blocs visités une
/// seule fois.
///
/// L'entrée d'une région est la seule adresse par laquelle toute la région
/// reste atteignable ; un début de bloc n'est qu'un raccourci. Ce test tient
/// la règle qui en découle, et il la tient **sur la case**, pas sur une
/// conséquence : la mesure du noyau est ce qui l'a trouvée, elle ne peut pas
/// être ce qui la garde.
///
/// **Le montage force la collision au lieu de l'espérer.** Les deux voies du
/// seau sont d'abord remplies à la main par deux adresses étrangères ; on
/// installe ensuite une région dont un bloc tombe dans ce seau-là, cherché
/// avec le même `table_slot` que l'émetteur grave dans ses octets. Sans cette
/// recherche, le test passerait pour la seule raison que 65 536 seaux rendent
/// les collisions rares.
#[test]
fn a_block_start_never_evicts_a_region_entry() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    use wisq_vm::x86_wasm::table_slot;
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    // Le second bloc de la région, comme dans le test voisin : `incq %r8` (3),
    // `movabs` (10), `testq` (3), `jnz` (2).
    const INSIDE: u64 = BASE + 18;
    let bucket = |at: u64| table_slot(at) & !(wisq_vm::x86_wasm::TABLE_WAYS - 1);

    // Deux adresses étrangères qui tombent dans le seau du **bloc**, pour le
    // remplir avant qu'il n'arrive. Cherchées, pas devinées.
    let squatters: Vec<u64> = (1u64..2_000_000)
        .map(|n| 0x8000_0000 + n * 8)
        .filter(|at| bucket(*at) == bucket(INSIDE))
        .take(2)
        .collect();
    assert_eq!(
        squatters.len(),
        2,
        "il faut deux adresses dans le seau du bloc pour le remplir"
    );

    let mut region = vec![0x49, 0xff, 0xc0]; // incq %r8
    region.extend_from_slice(&[0x48, 0xb8]); // movabs $BASE, %rax
    region.extend_from_slice(&BASE.to_le_bytes());
    region.extend_from_slice(&[0x48, 0x85, 0xc0]); // testq %rax, %rax
    region.extend_from_slice(&[0x75, 0x00]); // jnz +0 : coupe le bloc
    region.extend_from_slice(&[0x0f, 0x0b]); // ud2
    let outline = Module::outline(&region, 0).expect("le relevé");
    assert_eq!(outline.len(), 2, "la région doit porter deux blocs");
    assert_eq!(BASE + outline[1].start as u64, INSIDE, "et le second ici");

    let scratch = std::env::temp_dir().join(format!("wisq-evict-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&region, BASE, 0, 0, PAGES).expect("l'émetteur");
    let wasm = scratch.join("r.wasm");
    std::fs::write(&wasm, &module).expect("le module");
    let raw = scratch.join("r.bin");
    std::fs::write(&raw, &region).expect("le code");

    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine, tableSlot }} from {host:?};
import {{ readFileSync }} from "fs";
const octets = new Uint8Array(readFileSync({raw:?}));
const vm = machine({{
  translate: async (address, slot) =>
    address === {base}n && slot === 0 ? new Uint8Array(readFileSync({wasm:?})) : null,
  pages: {pages},
}});
new Uint8Array(vm.memory.buffer, {physical}, octets.length).set(octets);
const seau = (at) => vm.tableBase + (tableSlot(at) & ~1) * 16;
// Les deux voies du seau du bloc, occupées par des étrangères.
for (let voie = 0; voie < 2; voie += 1) {{
  const at = seau({inside}n) + voie * 16;
  new BigUint64Array(vm.memory.buffer, at, 1)[0] = [{squat0}n, {squat1}n][voie];
  new Int32Array(vm.memory.buffer, at + 8, 1)[0] = 999;
}}
vm.globals[{rip}].value = {base}n;
await vm.run({{ budget: 20n, rounds: 1 }});
// Ce que les deux voies portent après l'installation.
const lire = (at) => {{
  const out = [];
  for (let voie = 0; voie < 2; voie += 1) {{
    out.push(new BigUint64Array(vm.memory.buffer, seau(at) + voie * 16, 1)[0].toString(16));
  }}
  return out.join(",");
}};
console.log("bloc " + lire({inside}n));
console.log("entree " + lire({base}n));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            raw = raw.to_string_lossy(),
            wasm = wasm.to_string_lossy(),
            pages = PAGES,
            physical = BASE,
            rip = RIP_SLOT,
            base = BASE,
            inside = INSIDE,
            squat0 = squatters[0],
            squat1 = squatters[1],
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
    assert_eq!(
        seen("bloc"),
        format!("{:x},{:x}", squatters[0], squatters[1]),
        "les deux voies du seau étaient prises : le début de bloc doit \\
         renoncer, pas évincer : {text}"
    );
    // **Et l'entrée, elle, est bien rangée.** Sans cette ligne, un hôte qui ne
    // rangerait plus rien du tout passerait la première assertion.
    assert_eq!(
        seen("entree"),
        format!("{BASE:x},0"),
        "l'entrée de la région, elle, se range toujours : {text}"
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
        Some(format!("arret {UD2_SANS_PORTE}")).as_deref(),
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
/// **Ce que cette tranche ne faisait pas, et qui est fait depuis #254.** La
/// lecture des **instructions** n'était pas paginée : l'hôte résolvait une
/// région par son adresse repliée sur le masque de la RAM, donc RIP était
/// traité comme physique, et seules les **données** passaient par les tables.
/// Cette phrase-là est restée écrite pendant des tranches entières : le dépôt
/// **garantissait** par un commentaire que la moitié « chercher le code » du
/// couple resterait manquante. C'est
/// `the_host_reads_the_code_through_the_page_tables_and_not_by_folding` qui
/// tient l'autre moitié maintenant.
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
    assert_eq!(line("arret "), UD2_SANS_PORTE, "le `ud2` arrête : {text}");
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

/// **Changer d'espace d'adressage vide le tampon de traduction — CR3, CR4 et
/// CR0.**
///
/// C'est ce qu'un vrai processeur fait, et c'est la seule chose que le tampon
/// de `guest()` ne faisait pas : il n'était vidé que par `invlpg`, une entrée à
/// la fois. **Les deux autres cœurs ne se conduisent pas comme ça** —
/// `X86Paging.swift` vide sur les trois, et l'interpréteur Rust n'a aucun cache
/// à vider. Le cœur qui fait tourner le vrai noyau était le seul à diverger.
///
/// **Ce que ça tue, mesuré.** `__text_poke` écrit un correctif à travers une
/// cartographie temporaire : `use_temporary_mm` **écrit CR3**, `text_poke_memcpy`
/// écrit, `unuse_temporary_mm` **réécrit CR3**, puis le noyau relit à l'adresse
/// d'origine et compare. Avec un tampon qui garde tout, l'écriture peut
/// atterrir dans la trame qu'un correctif précédent avait cartographiée là. Le
/// noyau Alpine s'arrêtait sur le `BUG_ON(memcmp(addr, opcode, len))` de
/// `__text_poke + 1093`.
///
/// **Et CR4 n'est pas un extra** : `__flush_tlb_global()` de Linux sans
/// `INVPCID` est exactement `native_write_cr4(cr4 ^ X86_CR4_PGE)` puis la
/// valeur d'origine. Le cœur Swift a déjà payé son absence — c'est la tâche
/// #136, « Invalid relocation target, existing value is nonzero », puis
/// « bad pud ».
///
/// Les trois phases lisent **trois adresses distinctes**, pour qu'une phase ne
/// remplisse pas le tampon d'une autre : chaque vidage est tenu pour lui-même.
#[test]
fn changing_the_address_space_empties_the_translation_buffer() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 64;
    const BASE: u64 = 0x1_0000;
    // La première table, celle du départ.
    const PML4_A: u64 = 0x2_0000;
    const PDPT_A: u64 = 0x2_1000;
    const PD_A: u64 = 0x2_2000;
    const PT_A: u64 = 0x2_3000;
    // La seconde, vers laquelle CR3 bascule.
    const PML4_B: u64 = 0x2_4000;
    const PDPT_B: u64 = 0x2_5000;
    const PD_B: u64 = 0x2_6000;
    const PT_B: u64 = 0x2_7000;
    const FRAME_A: u64 = 0x3_0000;
    const FRAME_B: u64 = 0x3_1000;
    const FRAME_C: u64 = 0x3_2000;
    const FRAME_D: u64 = 0x3_3000;
    const FRAME_E: u64 = 0x3_4000;
    const FRAME_F: u64 = 0x3_5000;
    const VA1: u64 = 0xFFFF_8000_0020_0000; // la phase CR3
    const VA2: u64 = VA1 + 0x1000; // la phase CR4
    const VA3: u64 = VA1 + 0x2000; // la phase CR0
    const VA_TABLE: u64 = VA1 + 0x3000; // l'alias qui expose PT_B comme données
    const PAGING: u64 = 1 << 31;
    const PAGE_GLOBAL: u64 = 0x80; // CR4.PGE, le bit que Linux bascule

    let leaf = |at: u64| (at >> 12) & 0x1ff;
    let mut program: Vec<u8> = Vec::new();
    let mut push = |bytes: &[u8]| program.extend_from_slice(bytes);
    push(&[0x48, 0xb8]); // movabs $PML4_A,%rax
    push(&PML4_A.to_le_bytes());
    push(&[0x0f, 0x22, 0xd8]); // mov %rax,%cr3
    push(&[0x48, 0xb8]); // movabs $PAGING,%rax
    push(&PAGING.to_le_bytes());
    push(&[0x0f, 0x22, 0xc0]); // mov %rax,%cr0

    // **Phase CR3.** Une lecture remplit le tampon, puis l'espace change.
    push(&[0x48, 0xbe]); // movabs $VA1,%rsi
    push(&VA1.to_le_bytes());
    push(&[0x48, 0x8b, 0x16]); // mov (%rsi),%rdx — témoin A, et le tampon retient
    push(&[0x48, 0xb8]); // movabs $PML4_B,%rax
    push(&PML4_B.to_le_bytes());
    push(&[0x0f, 0x22, 0xd8]); // mov %rax,%cr3 — **aucun invlpg**
    push(&[0x48, 0x8b, 0x1e]); // mov (%rsi),%rbx — doit suivre la nouvelle table

    // **Phase CR4.** La même chose, mais c'est l'entrée de feuille qui change,
    // et le vidage passe par une écriture de CR4 — `__flush_tlb_global`.
    push(&[0x48, 0xbe]); // movabs $VA2,%rsi
    push(&VA2.to_le_bytes());
    push(&[0x48, 0x8b, 0x0e]); // mov (%rsi),%rcx — témoin C
    push(&[0x48, 0xbf]); // movabs $VA_TABLE,%rdi — l'alias sur PT_B
    push(&VA_TABLE.to_le_bytes());
    push(&[0x48, 0xb8]); // movabs $(FRAME_D|présente),%rax
    push(&(FRAME_D | 0x3).to_le_bytes());
    push(&[0x48, 0x89, 0x87]); // mov %rax,disp32(%rdi)
    push(&((leaf(VA2) * 8) as u32).to_le_bytes());
    push(&[0x48, 0xb8]); // movabs $PAGE_GLOBAL,%rax
    push(&PAGE_GLOBAL.to_le_bytes());
    push(&[0x0f, 0x22, 0xe0]); // mov %rax,%cr4
    push(&[0x48, 0x8b, 0x2e]); // mov (%rsi),%rbp — doit suivre la nouvelle trame

    // **Phase CR0.** La pagination s'éteint et se rallume ; tout ce que le
    // tampon savait était vrai d'un monde qui n'existe plus.
    push(&[0x48, 0xbe]); // movabs $VA3,%rsi
    push(&VA3.to_le_bytes());
    push(&[0x4c, 0x8b, 0x0e]); // mov (%rsi),%r9 — témoin E
    push(&[0x48, 0xb8]); // movabs $(FRAME_F|présente),%rax
    push(&(FRAME_F | 0x3).to_le_bytes());
    push(&[0x48, 0x89, 0x87]); // mov %rax,disp32(%rdi)
    push(&((leaf(VA3) * 8) as u32).to_le_bytes());
    push(&[0x31, 0xc0]); // xor %eax,%eax
    push(&[0x0f, 0x22, 0xc0]); // mov %rax,%cr0 — pagination éteinte
    push(&[0x48, 0xb8]); // movabs $PAGING,%rax
    push(&PAGING.to_le_bytes());
    push(&[0x0f, 0x22, 0xc0]); // mov %rax,%cr0 — et rallumée
    push(&[0x4c, 0x8b, 0x06]); // mov (%rsi),%r8 — doit suivre la nouvelle trame
    push(&[0x0f, 0x0b]); // ud2

    let scratch = std::env::temp_dir().join(format!("wisq-flush-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module =
        Module::resolving(&program, BASE, 0, 0, PAGES).expect("une région paginée se traduit");
    let path = scratch.join("f.wasm");
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
const vue = new DataView(vm.memory.buffer);
const present = 0x3n;
const idx = (va, shift) => Number((BigInt(va) >> BigInt(shift)) & 0x1ffn);
// La première table : VA1 seule, vers la trame A.
vue.setBigUint64({pml4a} + idx({va1}n, 39) * 8, {pdpta}n | present, true);
vue.setBigUint64({pdpta} + idx({va1}n, 30) * 8, {pda}n | present, true);
vue.setBigUint64({pda} + idx({va1}n, 21) * 8, {pta}n | present, true);
vue.setBigUint64({pta} + idx({va1}n, 12) * 8, {frameA}n | present, true);
// La seconde : les trois adresses, et l'alias qui expose sa table de feuilles.
vue.setBigUint64({pml4b} + idx({va1}n, 39) * 8, {pdptb}n | present, true);
vue.setBigUint64({pdptb} + idx({va1}n, 30) * 8, {pdb}n | present, true);
vue.setBigUint64({pdb} + idx({va1}n, 21) * 8, {ptb}n | present, true);
vue.setBigUint64({ptb} + idx({va1}n, 12) * 8, {frameB}n | present, true);
vue.setBigUint64({ptb} + idx({va2}n, 12) * 8, {frameC}n | present, true);
vue.setBigUint64({ptb} + idx({va3}n, 12) * 8, {frameE}n | present, true);
vue.setBigUint64({ptb} + idx({vatable}n, 12) * 8, {ptb}n | present, true);
// Un témoin distinct au début de chaque trame.
for (const [trame, temoin] of [[{frameA}, 0xa1n], [{frameB}, 0xb2n], [{frameC}, 0xc3n],
                               [{frameD}, 0xd4n], [{frameE}, 0xe5n], [{frameF}, 0xf6n]]) {{
  vue.setBigUint64(trame, temoin, true);
}}
vm.globals[{rip}].value = {base}n;
const why = await vm.run({{ budget: 512n, rounds: 16 }});
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value).toString(16);
console.log("arret " + why.stopped);
console.log("rdx " + lire(2));
console.log("rbx " + lire(3));
console.log("rcx " + lire(1));
console.log("rbp " + lire(5));
console.log("r9 " + lire(9));
console.log("r8 " + lire(8));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            va1 = VA1,
            va2 = VA2,
            va3 = VA3,
            vatable = VA_TABLE,
            pml4a = PML4_A,
            pdpta = PDPT_A,
            pda = PD_A,
            pta = PT_A,
            pml4b = PML4_B,
            pdptb = PDPT_B,
            pdb = PD_B,
            ptb = PT_B,
            frameA = FRAME_A,
            frameB = FRAME_B,
            frameC = FRAME_C,
            frameD = FRAME_D,
            frameE = FRAME_E,
            frameF = FRAME_F,
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
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    assert_eq!(
        line_of(&text, "arret "),
        UD2_SANS_PORTE,
        "le `ud2` arrête : {text}"
    );
    assert_eq!(
        line_of(&text, "rdx "),
        "a1",
        "la première lecture suit la première table : {text}"
    );
    assert_eq!(
        line_of(&text, "rbx "),
        "b2",
        "**écrire CR3 change d'espace d'adressage** : la même adresse doit \
         suivre la nouvelle table, pas ce que le tampon avait retenu de \
         l'ancienne — c'est ce que fait `use_temporary_mm` deux fois par \
         `__text_poke` : {text}"
    );
    assert_eq!(
        line_of(&text, "rcx "),
        "c3",
        "la lecture qui remplit le tampon pour la phase CR4 : {text}"
    );
    assert_eq!(
        line_of(&text, "rbp "),
        "d4",
        "**écrire CR4 vide tout**, et c'est la seule façon dont Linux sans \
         INVPCID y arrive — `native_write_cr4(cr4 ^ X86_CR4_PGE)` : {text}"
    );
    assert_eq!(
        line_of(&text, "r9 "),
        "e5",
        "la lecture qui remplit le tampon pour la phase CR0 : {text}"
    );
    assert_eq!(
        line_of(&text, "r8 "),
        "f6",
        "**éteindre puis rallumer la pagination vide aussi** : tout ce que le \
         tampon savait était vrai d'un monde qui n'existe plus : {text}"
    );
}

/// **`ud2` est délivré au vecteur 6, et le gestionnaire reprend après — c'est
/// la mécanique de `WARN` de Linux.**
///
/// Un noyau Linux exécute `ud2` **exprès**, des dizaines de fois pendant son
/// démarrage : `WARN()` compile en un appel à `__warn_printk` suivi d'un
/// `ud2`, et son gestionnaire `#UD` consulte `__bug_table`, y trouve
/// `BUGFLAG_WARNING`, **avance RIP de deux** et reprend. Tant que le vecteur 6
/// n'est pas délivré, chaque avertissement du noyau est un arrêt définitif —
/// c'est le mur mesuré après #226, à `do_one_initcall + 673`, derrière
/// « initcall inet_init+0x0/0x560 returned with preemption imbalance ».
///
/// **Ce que le test tient et qu'on ne peut pas obtenir autrement.** Le RIP
/// empilé doit être celui du `ud2` lui-même, **pas celui d'après** : `#UD` est
/// une *faute*, pas un piège, et c'est le gestionnaire qui décide d'avancer.
/// Le confondre avec un piège ferait reprendre le noyau deux octets trop loin
/// — après que son gestionnaire y a lui-même ajouté deux — au milieu de
/// l'instruction suivante. Le gestionnaire range donc le RIP empilé tel quel
/// dans RAX avant d'y toucher.
///
/// Et sans IDT, l'arrêt reste et se nomme : c'est la conduite que #194 a
/// posée pour la faute de page — « sans porte », la machine le dit au lieu de
/// boucler.
#[test]
fn an_undefined_instruction_is_delivered_and_the_handler_resumes_past_it() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 64;
    const BASE: u64 = 0x1_0000;
    const HANDLER: u64 = 0x1_1000;
    const IDT: u64 = 0x1_2000;
    const IDT_POINTER: u64 = 0x1_3000;
    const STACK: u64 = 0x8_0000;
    /// La valeur que la reprise pose dans RBX : elle ne peut y être que si la
    /// machine a repris **après** le `ud2`.
    const AFTER: u32 = 0x1111;

    fn put(into: &mut Vec<u8>, bytes: &[u8]) {
        into.extend_from_slice(bytes);
    }
    // Le programme, en deux formes : avec l'IDT chargée, et sans.
    let build = |with_idt: bool| -> (Vec<u8>, u64) {
        let mut program: Vec<u8> = Vec::new();
        if with_idt {
            put(&mut program, &[0x48, 0xbb]); // movabs $IDT_POINTER,%rbx
            put(&mut program, &IDT_POINTER.to_le_bytes());
            put(&mut program, &[0x0f, 0x01, 0x1b]); // lidt (%rbx)
        }
        put(&mut program, &[0x48, 0xbc]); // movabs $STACK,%rsp
        put(&mut program, &STACK.to_le_bytes());
        put(&mut program, &[0xfb]); // sti — pour que l'entrée ait quelque chose à éteindre
        let ud2_at = BASE + program.len() as u64;
        put(&mut program, &[0x0f, 0x0b]); // ud2
        put(&mut program, &[0x48, 0xc7, 0xc3]); // mov $AFTER,%rbx — la preuve que ça reprend
        put(&mut program, &AFTER.to_le_bytes());
        put(&mut program, &[0xf4]); // hlt — un arrêt propre et nommé
        (program, ud2_at)
    };
    let (program, ud2_at) = build(true);
    let (flat, flat_ud2_at) = build(false);

    // **Le gestionnaire fait ce que fait `handle_bug` de Linux** : il range le
    // RIP empilé tel quel — pour que le test voie que c'est une faute —, y
    // ajoute la longueur du `ud2`, et rend la main.
    let mut handler: Vec<u8> = Vec::new();
    put(&mut handler, &[0x48, 0x8b, 0x04, 0x24]); // mov (%rsp),%rax
    put(&mut handler, &[0x48, 0x83, 0x04, 0x24, 0x02]); // addq $2,(%rsp)
    put(&mut handler, &[0x48, 0xcf]); // iretq

    let scratch = std::env::temp_dir().join(format!("wisq-ud2-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    // **Une carte par exécution.** L'hôte alloue ses emplacements de table à
    // partir de zéro pour chaque machine, et c'est lui qui les passe à
    // `translate(address, slot, code)` : un pilote qui les compterait lui-même
    // servirait le mauvais module au deuxième tour.
    let compile = |name: &str, bytes: &[u8], at: u64, slot: u32| -> String {
        let module = Module::resolving(bytes, at, 0, slot, PAGES)
            .unwrap_or_else(|| panic!("{name} se traduit"));
        let path = scratch.join(name);
        std::fs::write(&path, &module).expect(name);
        format!(
            "  if (address === {at}n && slot === {slot}) return readFileSync({:?});\n",
            path.to_string_lossy()
        )
    };
    let served = compile("programme.wasm", &program, BASE, 0)
        + &compile("gestionnaire.wasm", &handler, HANDLER, 1)
        + &compile(
            "reprise.wasm",
            &program[(ud2_at + 2 - BASE) as usize..],
            ud2_at + 2,
            2,
        );
    let served_flat = compile("plat.wasm", &flat, BASE, 0);

    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";

function servir(address, slot) {{
{served}  return null;
}}

function servirPlat(address, slot) {{
{servedFlat}  return null;
}}

// La porte 6 : une porte d'interruption (0x0E), présente, sélecteur 0x10,
// sans pile d'interruption, vers le gestionnaire.
const porte = (offset) => {{
  const low = (BigInt(offset) & 0xffffn) | (0x10n << 16n) | (0x0en << 40n) | (1n << 47n)
    | ((BigInt(offset) & 0xffff0000n) << 32n);
  return [low, BigInt(offset) >> 32n];
}};

async function tourner(avecIdt) {{
  const vm = machine({{
    translate: async (address, slot) =>
      avecIdt ? servir(address, slot) : servirPlat(address, slot),
    pages: {pages},
  }});
  if (avecIdt) {{
    const vue = new DataView(vm.memory.buffer);
    const [bas, haut] = porte({handler});
    vue.setBigUint64({idt} + 6 * 16, bas, true);
    vue.setBigUint64({idt} + 6 * 16 + 8, haut, true);
    vue.setUint16({idtPointer}, 16 * 256 - 1, true);
    vue.setBigUint64({idtPointer} + 2, {idt}n, true);
  }}
  vm.globals[{rip}].value = {base}n;
  const why = await vm.run({{ budget: 256n, rounds: 32 }});
  const lire = (at) => BigInt.asUintN(64, vm.globals[at].value).toString(16);
  return {{ why, rax: lire(0), rbx: lire(3) }};
}}

const avec = await tourner(true);
console.log("arret " + avec.why.stopped);
console.log("rax " + avec.rax);
console.log("rbx " + avec.rbx);
const sans = await tourner(false);
console.log("sans " + sans.why.stopped);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            served = served,
            servedFlat = served_flat,
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            handler = HANDLER,
            idt = IDT,
            idtPointer = IDT_POINTER,
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
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        errors.is_empty(),
        "le pilote ne doit rien écrire en erreur : {errors}"
    );
    assert_eq!(
        line_of(&text, "arret "),
        "arrêtée sur hlt",
        "la machine doit être allée jusqu'au `hlt` qui suit la reprise — donc \
         avoir franchi le `ud2` au lieu de tourner dessus : {text}"
    );
    assert_eq!(
        line_of(&text, "rax "),
        format!("{ud2_at:x}"),
        "**le RIP empilé est celui du `ud2` lui-même** : `#UD` est une faute, \
         pas un piège, et c'est le gestionnaire qui décide d'avancer. Empiler \
         l'adresse d'après ferait reprendre Linux deux octets trop loin, \
         puisque `handle_bug` y ajoute lui-même la longueur du `ud2` : {text}"
    );
    assert_eq!(
        line_of(&text, "rbx "),
        format!("{AFTER:x}"),
        "et la reprise a bien exécuté l'instruction qui suit le `ud2` : {text}"
    );
    assert!(
        line_of(&text, "sans ").contains("sans porte") && line_of(&text, "sans ").contains("6"),
        "sans IDT, l'arrêt reste et se nomme — la conduite que #194 a posée \
         pour la faute de page : {text}"
    );
    let _ = flat_ud2_at;
}

/// **« Sur place » existe encore, et quelque chose doit le tenir.**
///
/// Avant #227, c'était le `ud2` qui y menait : il rendait la main sans dire
/// pourquoi, l'hôte redemandait la même adresse, et la boucle constatait que
/// RIP n'avait pas bougé. Maintenant qu'un `ud2` se nomme, **plus aucun test
/// n'exerçait ce chemin** — et il est loin d'être mort : le noyau Alpine y
/// tombe encore, mesuré, à `do_one_initcall + 673`.
///
/// Un saut indirect vers sa propre adresse y mène de la façon la plus simple
/// qui soit : le bloc rend la main avec RIP inchangé, l'hôte le rappelle, et
/// rien n'avance. C'est exactement ce qu'un noyau fait quand il boucle sur une
/// faute qu'il ne sait pas traiter.
///
/// **Ce n'est pas « le budget s'est épuisé »**, et la distinction est celle
/// qu'un test voisin défend déjà : un anneau qui revient à son point de départ
/// après trois cents tours a *avancé*. Ici la machine ne fait rien du tout.
#[test]
fn a_machine_that_returns_to_the_same_address_is_named_in_place() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    // `movabs` fait dix octets : le `jmp *%rax` commence juste après.
    const HERE: u64 = BASE + 10;
    let mut program: Vec<u8> = vec![0x48, 0xb8];
    program.extend_from_slice(&HERE.to_le_bytes());
    program.extend_from_slice(&[0xff, 0xe0]); // jmp *%rax — vers lui-même

    let scratch = std::env::temp_dir().join(format!("wisq-surplace-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    // Deux régions : le programme, et celle qui commence **sur** le saut — la
    // seule que l'hôte redemandera, et dans laquelle il tournera sans avancer.
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("la région se traduit");
    let path = scratch.join("s.wasm");
    std::fs::write(&path, &module).expect("le module");
    let loop_module =
        Module::resolving(&program[10..], HERE, 0, 1, PAGES).expect("la région du saut se traduit");
    let loop_path = scratch.join("boucle.wasm");
    std::fs::write(&loop_path, &loop_module).expect("le module du saut");
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
let asked = 0;
const vm = machine({{
  translate: async (address) => {{
    asked += 1;
    if (address === {base}n) return readFileSync({path:?});
    if (address === {here}n) return readFileSync({loopPath:?});
    return null;
  }},
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
            loopPath = loop_path.to_string_lossy(),
            here = HERE,
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
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        errors.is_empty(),
        "le pilote n'écrit rien en erreur : {errors}"
    );
    assert_eq!(
        line_of(&text, "arret "),
        "sur place",
        "une machine qui revient à la même adresse doit être nommée, pas \
         laissée tourner mille vingt-quatre fois pour rien : {text}"
    );
    assert_eq!(
        line_of(&text, "ou "),
        format!("{HERE:x}"),
        "et l'arrêt dit **où** : l'adresse du saut, pas celle de l'entrée : {text}"
    );
    assert_eq!(
        line_of(&text, "demandes "),
        "2",
        "deux traductions, et pas une de plus : l'hôte reconnaît l'adresse au \
         tour suivant, et c'est là qu'il voit qu'elle n'a pas bougé : {text}"
    );
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
        Some(format!("arret {UD2_SANS_PORTE}")).as_deref(),
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
        Some(format!("arret {UD2_SANS_PORTE}")).as_deref(),
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
        Some(format!("arret {UD2_SANS_PORTE}")).as_deref(),
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
/// D'où le choix : **un zéro partout, sauf ce qui est vrai**. Trois bits le
/// sont : le compteur d'horodatage, `clflush` (#211) et `cmpxchg16b` (#210) —
/// tous trois exécutés pour de vrai par l'émetteur. Tout le reste est à zéro,
/// ce qui veut dire « on ne l'a pas », et c'est exact.
///
/// **`RDRAND` reste tu, et c'est le cas le plus intéressant.** L'émetteur le
/// *décode* depuis #212, mais il ne rend aucun aléa : il pose zéro et laisse CF
/// à zéro, ce qui veut dire « raté, réessaie ». Un noyau qui verrait le bit
/// annoncé rejouerait sa boucle dix fois pour rien avant de se rabattre. Décoder
/// n'est pas exécuter, et seul ce qu'on exécute se déclare.
///
/// **Et annoncer `clflush` oblige à donner sa taille de ligne.** Linux lit
/// `x86_clflush_size` dans EBX de la feuille un, bits 15:8, multipliés par huit.
/// À zéro, `clflush_cache_range` calcule un pas nul et **boucle sans jamais
/// avancer** : la promesse serait tenue à moitié, et la moitié manquante
/// pendrait la machine au lieu de la faire échouer.
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
console.log("ebx " + lire(3));
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
        Some(format!("arret {UD2_SANS_PORTE}")).as_deref(),
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
    // **L'ensemble exact, et rien d'autre.** Une capacité déclarée est une
    // promesse : ce test tient l'ensemble exact, pas seulement « le TSC est
    // là ». Un bit de plus le ferait tomber, et c'est le but.
    //
    // Le bit 0 est le seul des trois qui promette plus que la machine ne
    // tient : il dit « il y a un coprocesseur », et de ce coprocesseur seule
    // `fninit` s'exécute. Ce n'est pas un mensonge muet pour autant — les
    // autres instructions x87 restent illisibles, et une région qui en porte
    // une est refusée en le nommant. Le noyau qui croit ce bit va donc plus
    // loin qu'avant, puis bute sur `fxsave` avec une raison écrite, au lieu
    // de renoncer à tout le coprocesseur sur un test de bit.
    assert_eq!(
        line("edx "),
        0x8_0011,
        "le bit 0 (coprocesseur), le bit 4 (compteur d'horodatage) et le bit 19 \
         (clflush), et eux seuls"
    );
    assert_eq!(
        line("ecx "),
        0x2000,
        "le bit 13 (cmpxchg16b) seul — et surtout pas le bit 30, RDRAND, que la \
         machine décode sans avoir d'aléa à rendre"
    );
    assert_eq!(
        line("ebx "),
        0x800,
        "la taille de ligne de clflush : huit quantums de huit octets, soit \
         soixante-quatre. À zéro, la boucle de vidage du noyau ne fait pas un pas"
    );
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

/// **`rdtscp` à travers l'émetteur : la même horloge, et ECX écrasé.**
///
/// Le troisième cœur émet trois écritures là où `rdtsc` en émet deux. Les deux
/// premières, `EDX:EAX`, sont le même code — un seul `matches!` couvre les deux
/// instructions, donc les tenir une fois les tient. **La troisième n'était
/// tenue par rien**, et un sabotage l'a montré : retirer l'écriture d'ECX
/// laissait tous les tests passer.
///
/// Ce que cette écriture achète se lit à l'envers. Sans elle, ECX garde ce
/// qu'il portait en entrant dans la région — une valeur quelconque, laissée là
/// par l'instruction d'avant. `vgetcpu` la lirait comme un numéro de
/// processeur, et le noyau irait chercher sa zone par processeur à un indice
/// qu'aucun `wrmsr` n'a jamais posé. Une valeur d'avant qui traîne ressemble à
/// une réponse : c'est exactement le mode de panne que ce dépôt refuse.
///
/// Le test sème donc RCX d'une valeur qui déborde les trente-deux bits, pour
/// que **ne pas écrire** et **écrire un ECX qui ne remet pas la moitié haute à
/// zéro** se distinguent l'un de l'autre.
#[test]
fn rdtscp_reads_the_same_counter_and_clears_the_processor_number() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    const SEED: u64 = 0x1234_5678_9abc_def0;
    // Ce que RCX porte en entrant. S'il ressort tel quel, l'écriture manque ;
    // s'il ressort avec sa moitié haute, l'écriture n'est pas une écriture
    // trente-deux bits.
    const STALE: u64 = 0xdead_beef_cafe_babe;
    // 0f 01 f9 = rdtscp ; 0f 0b = ud2 pour rendre la main proprement.
    let program = [0x0f, 0x01, 0xf9, 0x0f, 0x0b];
    let scratch = std::env::temp_dir().join(format!("wisq-host-rdtscp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module = Module::resolving(&program, BASE, 0, 0, PAGES).expect("le programme se traduit");
    let path = scratch.join("tscp.wasm");
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
vm.globals[{tsc}].value = {seed}n;
vm.globals[1].value = {stale}n;
const why = await vm.run({{ budget: 64n, rounds: 16 }});
console.log("arret " + why.stopped);
console.log("bas " + BigInt.asUintN(64, vm.globals[0].value).toString());
console.log("haut " + BigInt.asUintN(64, vm.globals[2].value).toString());
console.log("aux " + BigInt.asUintN(64, vm.globals[1].value).toString());
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            tsc = wisq_vm::x86_wasm::TSC_SLOT,
            seed = SEED,
            stale = STALE,
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
    assert_eq!(
        line("arret "),
        UD2_SANS_PORTE,
        "la région s'arrête sur le `ud2`, donc le `rdtscp` d'avant a bien été traduit"
    );
    let expected = SEED.wrapping_add(wisq_vm::x86_wasm::TSC_STEP);
    let bas: u64 = line("bas ").parse().expect("un nombre");
    let haut: u64 = line("haut ").parse().expect("un nombre");
    assert_eq!(
        bas,
        expected & 0xffff_ffff,
        "`rdtscp` lit le même compteur que `rdtsc`, d'un pas"
    );
    assert_eq!(haut, expected >> 32, "et sa moitié haute va dans RDX");
    let aux: u64 = line("aux ").parse().expect("un nombre");
    assert_eq!(
        aux, 0,
        "ECX porte IA32_TSC_AUX ; personne ne l'a écrit, donc zéro — et surtout \
         pas {STALE:#x}, que `vgetcpu` lirait comme un numéro de processeur"
    );
    let _ = std::fs::remove_dir_all(&scratch);
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
    assert_eq!(
        line("arret "),
        UD2_SANS_PORTE,
        "la région s'arrête sur le `ud2`"
    );
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
    assert_eq!(
        line("arret "),
        UD2_SANS_PORTE,
        "la région s'arrête sur le `ud2`"
    );
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
    assert_eq!(seen("arret"), UD2_SANS_PORTE);
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
    assert_eq!(
        seen("arret"),
        UD2_SANS_PORTE,
        "le blocage doit se nommer — et depuis #227 il se nomme mieux qu'avant : \
         la machine dit l'instruction qui l'arrête au lieu de constater \
         qu'elle n'avance plus"
    );
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
    // Deux adresses demandées, chacune avec l'emplacement que la vue a
    // choisi : c'est le contrat que l'application devra tenir.
    //
    // **Deux, et non trois depuis #227.** La troisième était l'adresse du
    // `ud2` final : l'hôte la réclamait faute de savoir pourquoi le bloc lui
    // rendait la main, et il le sait désormais.
    assert_eq!(seen("demandes"), "2", "une traduction par adresse atteinte");
    // **Et chaque demande porte une fenêtre pleine.** Sans cette ligne, le
    // harnais imprimerait les tailles sans que rien ne les lise — une mesure
    // morte, qui a l'air d'une garde.
    //
    // **Deux fenêtres, et non trois depuis #227** : la troisième était celle du
    // `ud2` final, que l'hôte ne réclame plus.
    assert_eq!(
        seen("fenetres"),
        "4096,4096",
        "la vue envoie quatre kibioctets par demande"
    );
    assert_eq!(
        seen("vues"),
        format!("{}:0,{}:1", BASE, BASE + 0x100),
        "l'adresse **et** l'emplacement traversent le pont"
    );
    // Deux `incq %rdx` : les deux régions ont tourné, pas seulement été
    // traduites.
    assert_eq!(seen("rdx"), "2", "les deux régions ont calculé");
    assert_eq!(
        seen("arret"),
        UD2_SANS_PORTE,
        "le `ud2` arrête la machine, et le dit"
    );
    assert_eq!(
        seen("postes"),
        format!("{UD2_SANS_PORTE} {}", BASE + 0x103),
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
    assert_eq!(
        seen("arret"),
        UD2_SANS_PORTE,
        "le `ud2` arrête la machine, et le dit"
    );
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

    // **Ce que la respiration coûte, imprimé plutôt que jeté.**
    //
    // Ce test mesure les deux durées sur le même travail — `rdx` le prouve
    // trois assertions plus bas — et les comparait à un seuil sans jamais dire
    // combien. Pendant ce temps le commentaire de `web/host.js` gelait « dix-
    // neuf pour cent de débit », relevé par un protocole décrit mais qu'aucune
    // commande ne refait. L'instrument existait, tournait à chaque commit, et
    // c'est le chiffre qui manquait.
    //
    //     cargo test -p wisq-vm --release --test host_loop \
    //         the_machine_lets_the_page_breathe_while_it_runs -- --nocapture
    //
    // Le seuil reste un rapport et non une valeur : un coureur lent reste un
    // coureur honnête, et ce qui suit est un relevé, pas une garde.
    println!(
        "respiration : {holding} ms en apnée contre {breathing} ms en respirant \
         — la respiration coûte {:.0} % du débit, {beats} battements de page \
         obtenus contre {held}",
        if breathing == 0 {
            0.0
        } else {
            (breathing as f64 - holding as f64) / breathing as f64 * 100.0
        }
    );

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
    assert_eq!(
        seen("arret"),
        format!("{UD2_SANS_PORTE} {UD2_SANS_PORTE}"),
        "le `ud2` arrête tout"
    );
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
/// **Une seconde page absente, dans la même table que la première** — ses
/// trois niveaux sont donc déjà posés, et sa feuille pas davantage. Elle sert
/// à #258 : deux chargements fautifs **séparés** par une région installée,
/// c'est-à-dire ce que fait un noyau qui cartographie à la demande.
const RIG_ABSENT_TOO: u64 = RIG_ABSENT + 0x1000;
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
        UD2_PORTE_ABSENTE,
        "l'arrêt final est le ud2 : {text}"
    );
    // **Trois demandes, et chacune se nomme** : le programme, le gestionnaire,
    // et la reprise sur l'instruction fautive.
    //
    // **Trois, et non quatre depuis #227.** La quatrième était le `ud2` final :
    // l'hôte réclamait une région qui commence là, le bouchon la refusait, et
    // c'est ce refus qui faisait l'arrêt « refusée ». Le module pose désormais
    // un témoin, donc l'hôte sait ce qu'il tient sans avoir à le demander — et
    // l'arrêt nomme l'instruction plutôt que le silence du bouchon.
    assert_eq!(
        number("demandes "),
        3,
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
/// Le message ne dit plus « la pile de l'invité » depuis #257, parce que ce
/// n'est plus forcément la sienne : quand l'anneau change, le cadre s'écrit
/// sur celle que `RSP0` nomme.
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
        "une faute pendant la délivrance d'une faute de page : la pile où le cadre \
         s'écrit n'est pas cartographiée",
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
        UD2_PORTE_ABSENTE,
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
        wisq_vm::x86_wasm::STOP_UNDEFINED,
        "le témoin de la faute délivrée est effacé, et celui du `ud2` final est \
         **remis** : sa délivrance, elle, n'a pas pu avoir lieu — la porte 6 \
         manque —, et le relevé doit montrer ce qui a arrêté la machine"
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
    assert_eq!(line("arret "), UD2_SANS_PORTE, "le `ud2` arrête : {text}");
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
/// **Ce que ce nombre n'est pas, et ce qu'il est devenu.** À #204, aucun
/// descripteur n'était lu derrière lui, et la délivrance disait toujours
/// « cette machine n'a pas de TSS ». Depuis **#257** elle lit le descripteur
/// dans la GDT et y trouve `RSP0` — mais *ce* test ne tient toujours que le
/// rangement du sélecteur, seize bits dans sa case, et rien d'autre ; la
/// délivrance est tenue par les trois tests de #257.
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
/// témoin de la faute délivrée est effacé, et l'arrêt final est le `ud2` —
/// que la porte 6, absente de ce montage, ne peut pas rattraper.
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
        UD2_PORTE_ABSENTE,
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
        wisq_vm::x86_wasm::STOP_UNDEFINED,
        "le témoin de la faute délivrée est effacé, et celui du `ud2` final est \
         **remis** : sa délivrance, elle, n'a pas pu avoir lieu — la porte 6 \
         manque —, et le relevé doit montrer ce qui a arrêté la machine"
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

/// **`clflush` ne fait pas refuser la région, et la machine continue.**
///
/// C'est le mur de `cpa_flush + 309` : `3e 0f ae 38`, `clflush (%rax)`, la
/// boucle `clflush_cache_range` de `change_page_attr_set_clr`. Les trois
/// formes que le noyau peut écrire se suivent — avec le préfixe `3e`, nue, et
/// `clflushopt` —, puis une instruction qui doit tourner, puis le `hlt`. Le
/// test des octets du décodeur dit qu'elles se lisent ; celui-ci dit que le
/// module compilé par JavaScriptCore passe dessus sans rien faire.
#[test]
fn a_kernel_that_flushes_a_cache_line_goes_on() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program: Vec<u8> = vec![
        0x48, 0xc7, 0xc0, 0x00, 0x20, 0x00, 0x00, // mov $0x2000,%rax
        0x3e, 0x0f, 0xae, 0x38, // ds clflush (%rax) — ce que le noyau écrit
        0x0f, 0xae, 0x38, // clflush (%rax)
        0x66, 0x0f, 0xae, 0x78, 0x40, // clflushopt 0x40(%rax)
        0x48, 0xff, 0xc2, // incq %rdx — doit tourner
        0xf4, // hlt
    ];
    let module = match Module::resolving_or_why(&program, BASE, 0, 0, PAGES) {
        Ok(module) => module,
        Err(why) => panic!("`cpa_flush` doit se traduire, pas faire refuser la région : {why:?}"),
    };
    let scratch = std::env::temp_dir().join(format!("wisq-host-clflush-{}", std::process::id()));
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
        "arrêtée sur hlt",
        "la machine ne s'arrête sur aucun clflush, elle continue jusqu'au hlt : {text}"
    );
    assert_eq!(line("rdx "), "1", "ce qui suit a tourné");
    assert_eq!(
        line("rip "),
        (BASE + program.len() as u64).to_string(),
        "RIP est après le hlt"
    );
}

/// **La boucle de dix essais du noyau, sans aléa : elle épuise ses essais et
/// retombe.**
///
/// C'est `kaslr_get_random_long`, à l'octet près : `mov $10,%eax`, puis
/// `rdrand %rdx ; jb pris ; sub $1,%eax ; jne` dix fois. Sous JavaScriptCore,
/// chaque `rdrand` doit laisser CF nul — sinon le `jb` sort de la boucle —,
/// et la sortie par épuisement doit écrire son témoin. Puis la règle de
/// largeur, dans l'émetteur cette fois : la forme de trente-deux bits efface
/// RCX entier, celle de seize garde le haut de RBX.
#[test]
fn the_kernels_ten_rdrand_tries_all_fail_and_it_falls_back() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : la boucle hôte ne serait vérifiée par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let mut program: Vec<u8> = Vec::new();
    {
        let mut push = |bytes: &[u8]| program.extend_from_slice(bytes);
        push(&[0xb8, 0x0a, 0x00, 0x00, 0x00]); // mov $10,%eax            (0)
        push(&[0x48, 0x0f, 0xc7, 0xf2]); // rdrand %rdx                    (5)
        push(&[0x72, 0x28]); // jb +40 → « pris »                          (9)
        push(&[0x83, 0xe8, 0x01]); // sub $1,%eax                          (11)
        push(&[0x75, 0xf5]); // jne -11 → rdrand                           (14)
        push(&[0x48, 0xc7, 0xc6, 0x01, 0x00, 0x00, 0x00]); // mov $1,%rsi  (16) épuisé
        push(&[0x48, 0xb9]);
        push(&u64::MAX.to_le_bytes()); // movabs $-1,%rcx                  (23)
        push(&[0x0f, 0xc7, 0xf1]); // rdrand %ecx                          (33)
        push(&[0x48, 0xbb]);
        push(&0xdead_beef_cafe_f00du64.to_le_bytes()); // movabs …,%rbx    (36)
        push(&[0x66, 0x0f, 0xc7, 0xf3]); // rdrand %bx                     (46)
        push(&[0xf4]); // hlt                                              (50)
    }
    let taken = program.len() as u64; // « pris » : 51
    program.extend_from_slice(&[0x48, 0xc7, 0xc6, 0x02, 0x00, 0x00, 0x00]); // mov $2,%rsi
    program.push(0xf4); // hlt
    assert_eq!(
        taken, 51,
        "le déplacement du jb (0x28 depuis 11) vise « pris »"
    );
    let module = match Module::resolving_or_why(&program, BASE, 0, 0, PAGES) {
        Ok(module) => module,
        Err(why) => panic!(
            "`kaslr_get_random_long` doit se traduire, pas faire refuser la région : {why:?}"
        ),
    };
    let scratch = std::env::temp_dir().join(format!("wisq-host-rdrand-{}", std::process::id()));
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
const why = await vm.run({{ budget: 256n, rounds: 16 }});
const lire = at => BigInt.asUintN(64, vm.globals[at].value).toString(16);
console.log("arret " + why.stopped);
console.log("rax " + lire(0));
console.log("rcx " + lire(1));
console.log("rdx " + lire(2));
console.log("rbx " + lire(3));
console.log("rsi " + lire(6));
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
        "la machine va jusqu'au hlt : {text}"
    );
    assert_eq!(
        hex("rsi "),
        1,
        "les dix essais échouent : le noyau retombe, le jb n'est jamais pris"
    );
    assert_eq!(hex("rax "), 0, "les dix essais ont été comptés");
    assert_eq!(hex("rdx "), 0, "sans aléa, RDX vaut zéro");
    assert_eq!(hex("rcx "), 0, "rdrand %ecx efface RCX entier");
    assert_eq!(
        hex("rbx "),
        0xdead_beef_cafe_0000,
        "rdrand %bx garde le haut de RBX"
    );
    assert_eq!(
        hex("rflags ") & wisq_vm::x86::ARITHMETIC,
        0,
        "le dernier rdrand a tout effacé, CF compris"
    );
    assert_eq!(
        hex("rip "),
        BASE + 51,
        "arrêtée sur le premier hlt, pas sur celui de « pris »"
    );
}

/// **Une case de correspondance volée coûte un retour de main, jamais la
/// correctitude.**
///
/// La correspondance adresse → indice tient **une seule case par empreinte,
/// sans sondage** : deux adresses qui tombent au même endroit ne se disputent
/// pas, la seconde installée écrase la première. La tranche #213 a mesuré, sur
/// le vrai noyau, que 85 régions sur 3314 perdent ainsi leur case au profit
/// d'une région installée plus tard — et que ces régions rendent alors la main
/// à chaque appel. La question restée ouverte : est-ce seulement plus lent, ou
/// est-ce faux ?
///
/// Ce test répond en petit. Une région A boucle trois fois : elle appelle B
/// (`endbr64 ; cli ; ret`) puis, à son retour, un appel **indirect** vers C
/// (`ret`) par un pointeur en mémoire. On la fait tourner deux fois : une fois
/// sans rien toucher, une fois en **volant** la case de l'adresse de retour à
/// chaque tour — en y écrivant une autre adresse, comme le ferait une région
/// installée plus tard sur la même empreinte. Les deux fois, la machine
/// **atteint son `hlt` avec `r12 == 0`** : la correctitude tient. Mais voler la
/// case **augmente strictement** le nombre de retours de main, parce que
/// l'adresse dont la case est fausse doit être re-résolue par l'hôte à chaque
/// passage. Le défaut « muet » de #213 est donc bien muet : une perte de
/// vitesse, pas de justesse. Réduire ces pertes demanderait un sondage
/// (plusieurs cases par empreinte) — un renversement de la conception, laissé à
/// une décision, pas à ce test.
#[test]
fn a_stolen_correspondence_cell_costs_a_hand_back_but_never_correctness() {
    let Some(bun) = bun() else {
        return;
    };
    const PAGES: u32 = 4;
    const BASE: u64 = 0x1_0000;
    const B: u64 = 0x2_0000;
    const C: u64 = 0x2_1000;
    const P: u64 = 0x3_0000;
    // A : pose la pile, compte à trois, appelle B puis *P (indirect) à chaque
    // tour, décrémente, recommence, puis s'arrête.
    let a: Vec<u8> = vec![
        0x48, 0xc7, 0xc4, 0x00, 0xf0, 0x00, 0x00, // mov $0xf000,%rsp        (0)
        0x41, 0xbc, 0x03, 0x00, 0x00, 0x00, // mov $3,%r12d                  (7)
        0xe8, 0xee, 0xff, 0x00, 0x00, // loop: call B                       (13)
        0xff, 0x15, 0xe8, 0xff, 0x01, 0x00, // retour: call *P(%rip)        (18)
        0x41, 0xff, 0xcc, // dec %r12d                                      (24)
        0x75, 0xf0, // jnz loop                                            (27)
        0xf4, // hlt                                                       (29)
    ];
    let b: Vec<u8> = vec![0xf3, 0x0f, 0x1e, 0xfa, 0xfa, 0xc3]; // endbr64 ; cli ; ret
    let c: Vec<u8> = vec![0xc3]; // ret
                                 // L'adresse de retour de `call B`, dont on volera la case : elle porte
                                 // `call *P`, réatteinte à chaque tour de boucle.
    const RETOUR: u64 = BASE + 18;
    let regions: Vec<(u64, Vec<u8>)> = vec![
        (BASE, a.clone()),
        (BASE + 13, a[13..].to_vec()),
        (BASE + 18, a[18..].to_vec()),
        (BASE + 24, a[24..].to_vec()),
        (B, b),
        (C, c),
    ];
    let scratch = std::env::temp_dir().join(format!("wisq-vol-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let mut listing = String::new();
    for (at, bytes) in &regions {
        let mut variants = String::new();
        for slot in 0..48u32 {
            let module = Module::resolving_or_why(bytes, *at, 0, slot, PAGES)
                .unwrap_or_else(|why| panic!("la région {at:#x} se traduit : {why:?}"));
            let path = scratch.join(format!("r{at:x}_{slot}.wasm"));
            std::fs::write(&path, &module).expect("le module");
            variants.push_str(&format!("{:?},", path.to_string_lossy()));
        }
        listing.push_str(&format!("[{at}n,[{variants}]],"));
    }
    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
const connues = new Map([{listing}]);
async function courir(vole) {{
  const vm = machine({{
    translate: async (address, slot) => {{
      const variants = connues.get(address);
      if (variants === undefined) return null;
      return readFileSync(variants[slot]);
    }},
    pages: {pages},
  }});
  new DataView(vm.memory.buffer).setBigUint64({p}, {c}n, true);
  vm.globals[{rip}].value = {base}n;
  const lire = (at) => BigInt.asUintN(64, vm.globals[at].value);
  let retours = 0;
  let why = {{ stopped: "tours épuisés" }};
  for (let tour = 0; tour < 64; tour++) {{
    why = await vm.run({{ budget: 4096n, rounds: 1 }});
    if (why.stopped !== "tours épuisés") break;
    retours++;
    // **Le vol efface les deux voies du seau, et il ne demande la
    // permission à personne.**
    //
    // Il était conditionné à ce que l'hôte ait installé une région dont
    // l'entrée est l'adresse de retour — ce qui n'arrive plus depuis que la
    // correspondance porte les débuts de blocs : l'adresse s'y trouve sans
    // qu'aucune région ne commence là. Le vol ne se déclenchait donc jamais,
    // et les deux moitiés du test devenaient identiques. Une garde qui se
    // tait est pire qu'une garde absente ; celle-ci a échoué, et c'est ce
    // qu'on lui demande.
    //
    // Et il efface **les deux voies** : viser la seule que l'empreinte
    // désigne laissait l'autre répondre, ce qui rendait le vol inoffensif
    // pour une raison qui n'a rien à voir avec ce qu'on mesure.
    if (vole) {{
      const seau = vm.tableBase + (vm.tableSlot({retour}n) & ~1) * 16;
      for (let voie = 0; voie < 2; voie += 1) {{
        new DataView(vm.memory.buffer).setBigUint64(
          seau + voie * 16, {retour}n + 1n, true);
      }}
    }}
  }}
  return {{ arret: why.stopped, r12: lire(12).toString(), retours }};
}}
const sans = await courir(false);
const avec = await courir(true);
console.log("sans " + sans.arret + " r12=" + sans.r12 + " retours=" + sans.retours);
console.log("avec " + avec.arret + " r12=" + avec.r12 + " retours=" + avec.retours);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            c = C,
            p = P,
            retour = RETOUR,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let ligne = |prefixe: &str| -> &str {
        text.lines()
            .find(|l| l.starts_with(prefixe))
            .unwrap_or_else(|| panic!("ligne « {prefixe} » absente : {text}"))
    };
    let sans = ligne("sans ");
    let avec = ligne("avec ");
    // Les deux fois, la machine finit son compte et s'arrête sur son hlt.
    assert!(
        sans.contains("arrêtée sur hlt") && sans.contains("r12=0"),
        "sans vol, la boucle doit finir sur hlt avec r12=0 : {text}"
    );
    assert!(
        avec.contains("arrêtée sur hlt") && avec.contains("r12=0"),
        "avec vol, la correctitude tient : même hlt, même r12=0 : {text}"
    );
    // Mais voler la case coûte : strictement plus de retours de main.
    let compte = |ligne: &str| -> u32 {
        ligne
            .rsplit_once("retours=")
            .and_then(|(_, n)| n.trim().parse().ok())
            .unwrap_or_else(|| panic!("compte de retours illisible : {ligne}"))
    };
    assert!(
        compte(avec) > compte(sans),
        "une case volée doit forcer des retours de main en plus : {text}"
    );
}

/// **Deux régions dont les adresses tombent dans la même case sont toutes deux
/// retrouvées.**
///
/// La correspondance adresse → indice tenait **une seule case par empreinte**.
/// Deux adresses qui tombent au même endroit ne se disputaient pas : la
/// seconde installée écrasait la première, et la première repassait par l'hôte
/// à chaque appel. #213 a compté ce que ça coûte sur le vrai noyau — 85 régions
/// sur 3314 perdent leur case — et #214 a établi que c'est muet : une perte de
/// vitesse, jamais de justesse.
///
/// **Ce test compare deux nombres qui doivent s'accorder.** Le même programme
/// tourne deux fois, sur deux machines neuves : il appelle `x`, puis `y`, puis
/// `x` de nouveau. Une fois avec `x` et `y` sur des empreintes **distinctes**
/// — le témoin —, une fois avec `x` et `y` qui **se disputent** la même. Les
/// deux doivent atteindre leur `hlt`, et surtout faire **le même nombre de
/// tours de répartition** : si la case de `x` lui est prise par `y`, le
/// troisième appel ne la trouve plus et coûte un tour de plus.
///
/// Le second appel, lui, tient l'autre moitié : `y` est rangée dans la seconde
/// voie du même seau, et seule une recherche qui consulte les deux voies l'y
/// trouve. Un correctif qui ne toucherait que l'installation, sans la
/// recherche, laisserait ce tour de plus en place.
#[test]
fn two_regions_that_share_a_cell_are_both_found() {
    let Some(bun) = bun() else {
        return;
    };
    const PAGES: u32 = 4;
    const BASE: u64 = 0x1_0000;

    /// `call` relatif : l'octet e8 puis l'écart jusqu'à la cible, compté
    /// depuis l'instruction suivante.
    fn appel(cible: u64, suivante: u64) -> [u8; 5] {
        let ecart = (cible as i64 - suivante as i64) as i32;
        let mut octets = [0xe8u8, 0, 0, 0, 0];
        octets[1..].copy_from_slice(&ecart.to_le_bytes());
        octets
    }

    // mov $0xf000,%rsp ; call x ; call y ; call x ; call y ; hlt
    //
    // **Chacune est appelée deux fois, et c'est ce qui tient les deux moitiés.**
    // Le premier appel d'une adresse la fait installer : il rend la main de
    // toute façon, quoi que la correspondance contienne. Seul le second dit si
    // elle a été retrouvée. Avec un seul appel par adresse, un correctif qui
    // rangerait bien les deux voies sans les **relire** toutes les deux
    // passerait le test : `x` occuperait la première voie, `y` la seconde, et
    // la seconde ne serait jamais consultée. Le sabotage l'a montré.
    let programme = |x: u64, y: u64| -> Vec<u8> {
        let mut octets = vec![0x48, 0xc7, 0xc4, 0x00, 0xf0, 0x00, 0x00];
        octets.extend_from_slice(&appel(x, BASE + 12));
        octets.extend_from_slice(&appel(y, BASE + 17));
        octets.extend_from_slice(&appel(x, BASE + 22));
        octets.extend_from_slice(&appel(y, BASE + 27));
        octets.push(0xf4);
        octets
    };

    // Les empreintes du programme lui-même : les deux paires doivent les
    // éviter, sinon la comparaison mesurerait une collision qu'on n'a pas
    // voulue.
    let interdites: std::collections::HashSet<u32> =
        [BASE, BASE + 12, BASE + 17, BASE + 22, BASE + 27]
            .iter()
            .map(|at| table_slot(*at))
            .collect();

    // La paire qui se dispute une case : deux adresses de même empreinte.
    let (xc, yc) = {
        let mut vues: std::collections::HashMap<u32, u64> = std::collections::HashMap::new();
        let mut paire = None;
        let mut at = 0x2_0000u64;
        while at < 0x3_F000 {
            let empreinte = table_slot(at);
            if !interdites.contains(&empreinte) {
                if let Some(&premiere) = vues.get(&empreinte) {
                    paire = Some((premiere, at));
                    break;
                }
                vues.insert(empreinte, at);
            }
            at += 16;
        }
        paire.expect("deux adresses de même empreinte dans la RAM de l'invité")
    };

    // Le témoin : deux adresses d'empreintes distinctes, et distinctes de
    // celles du programme.
    let (xt, yt) = {
        let mut vues = interdites.clone();
        let mut choisies = Vec::new();
        let mut at = 0x2_0000u64;
        while choisies.len() < 2 && at < 0x3_F000 {
            let empreinte = table_slot(at);
            if !vues.contains(&empreinte) {
                vues.insert(empreinte);
                choisies.push(at);
            }
            at += 16;
        }
        (choisies[0], choisies[1])
    };
    assert_eq!(
        table_slot(xc),
        table_slot(yc),
        "la paire en dispute doit partager une empreinte"
    );
    assert_ne!(
        table_slot(xt),
        table_slot(yt),
        "le témoin ne doit pas en partager"
    );

    let montage = |x: u64, y: u64| -> Vec<(u64, Vec<u8>)> {
        let p = programme(x, y);
        vec![
            (BASE, p.clone()),
            (BASE + 12, p[12..].to_vec()),
            (BASE + 17, p[17..].to_vec()),
            (BASE + 22, p[22..].to_vec()),
            (BASE + 27, p[27..].to_vec()),
            (x, vec![0xc3]),
            (y, vec![0xc3]),
        ]
    };

    let scratch = std::env::temp_dir().join(format!("wisq-seau-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let compiler = |nom: &str, regions: &[(u64, Vec<u8>)]| -> String {
        let mut listing = String::new();
        for (at, bytes) in regions {
            let mut variantes = String::new();
            for slot in 0..48u32 {
                let module = Module::resolving_or_why(bytes, *at, 0, slot, PAGES)
                    .unwrap_or_else(|why| panic!("la région {at:#x} se traduit : {why:?}"));
                let chemin = scratch.join(format!("{nom}_{at:x}_{slot}.wasm"));
                std::fs::write(&chemin, &module).expect("le module");
                variantes.push_str(&format!("{:?},", chemin.to_string_lossy()));
            }
            listing.push_str(&format!("[{at}n,[{variantes}]],"));
        }
        listing
    };
    let temoin = compiler("t", &montage(xt, yt));
    let dispute = compiler("d", &montage(xc, yc));

    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
async function courir(connues) {{
  const vm = machine({{
    translate: async (address, slot) => {{
      const variantes = connues.get(address);
      if (variantes === undefined) return null;
      return readFileSync(variantes[slot]);
    }},
    pages: {pages},
  }});
  vm.globals[{rip}].value = {base}n;
  let tours = 0;
  let why = {{ stopped: "tours épuisés" }};
  for (let pas = 0; pas < 256; pas++) {{
    why = await vm.run({{ budget: 4096n, rounds: 1 }});
    if (why.stopped !== "tours épuisés") break;
    tours++;
  }}
  return {{ arret: why.stopped, tours }};
}}
const t = await courir(new Map([{temoin}]));
const d = await courir(new Map([{dispute}]));
console.log("temoin " + t.arret + " tours=" + t.tours);
console.log("dispute " + d.arret + " tours=" + d.tours);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
        ),
    )
    .expect("le pilote");
    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    let ligne = |prefixe: &str| -> &str {
        text.lines()
            .find(|l| l.starts_with(prefixe))
            .unwrap_or_else(|| panic!("ligne « {prefixe} » absente : {text}"))
    };
    let tours = |ligne: &str| -> u32 {
        ligne
            .rsplit_once("tours=")
            .and_then(|(_, n)| n.trim().parse().ok())
            .unwrap_or_else(|| panic!("compte de tours illisible : {ligne}"))
    };
    let t = ligne("temoin ");
    let d = ligne("dispute ");
    assert!(
        t.contains("arrêtée sur hlt"),
        "le témoin doit finir sur son hlt : {text}"
    );
    assert!(
        d.contains("arrêtée sur hlt"),
        "la dispute aussi : une case prise n'a jamais coûté la justesse : {text}"
    );
    assert_eq!(
        tours(d),
        tours(t),
        "deux adresses qui partagent une empreinte doivent être retrouvées \
         toutes les deux, donc coûter autant de tours que si elles ne la \
         partageaient pas : {text}"
    );
}

/// **Le pilote traduit à la demande, sans connaître les régions d'avance.**
///
/// C'est le mécanisme qui manquait, et son absence coûtait cher : `kernel-entry`
/// ne pouvait pas appeler l'émetteur — JavaScript d'un côté, Rust de l'autre —
/// alors il **rejouait le démarrage depuis le début** à chaque nouvelle région,
/// une exécution de Bun par région. Quadratique : cinq secondes par tour à la
/// 512ᵉ région, une vingtaine d'heures pour en atteindre quatre mille. Ce n'est
/// pas le jeu d'instructions qui bornait la profondeur de démarrage depuis
/// #215, c'est ce coût-là.
///
/// **Ce que ce test tient, et qu'aucun autre ne tenait.** Tous les pilotes de
/// ce fichier servent des modules **préparés d'avance** : le test connaît les
/// régions parce qu'il les a compilées lui-même. Ici le pilote n'en connaît
/// aucune. Il reçoit une adresse et va chercher un traducteur, comme
/// l'application ira chercher l'émetteur dans son processus hôte.
///
/// **Le montage force trois régions distinctes**, et c'est le point : les deux
/// cibles de `call` sont à trente-deux et soixante-cinq kibioctets, donc hors
/// de la fenêtre de seize kibioctets que le traducteur lit. La découverte ne
/// peut pas les avaler dans la première région ; il **faut** que la boucle
/// redemande, deux fois, à des adresses que rien n'a annoncées.
///
/// Un bouchon complaisant — qui rendrait la même région à n'importe quelle
/// demande — ferait tomber `rdx`, parce que les deux `incq` n'auraient pas lieu
/// aux bons endroits. C'est pour ça que le témoin est un compteur et pas un
/// drapeau.
///
/// **Et il en demande quatre, pas trois.** Ce test attendait trois régions et
/// en a trouvé cinq ; les deux de plus étaient des adresses de **retour**.
/// L'une des deux a disparu depuis que la correspondance porte les débuts de
/// blocs ; l'autre tombe sur le `ud2`, qui rend la main par conception.
/// L'assertion dit lequel est lequel — c'était une trouvaille, ce n'est pas un
/// réglage d'attente.
#[test]
fn the_driver_translates_on_demand_without_knowing_the_regions_in_advance() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 8;
    // **Une base virtuelle qui se replie sur l'adresse physique**, comme celle
    // d'un noyau : `0xffffffff80010000 & (512 Kio - 1)` vaut `0x10000`. Ce
    // n'est pas de la décoration — le traducteur doit replier avant de
    // chercher le segment, sinon toute adresse virtuelle serait « hors de tout
    // segment » et la machine s'arrêterait à sa première.
    const BASE: u64 = 0xffff_ffff_8001_0000;
    const PHYSICAL: u64 = 0x1_0000;
    // Trois régions, à trente-deux kibioctets l'une de l'autre.
    const SECOND: u64 = 0x8000;
    const THIRD: u64 = 0x1_0000;
    const UNREADABLE: u64 = 0x4000;

    let mut image = vec![0u8; (THIRD + 0x10) as usize];
    // `call +0x7ffb` vers 0x8000, `call +0xfff6` vers 0x10000, puis `ud2`.
    image[0..5].copy_from_slice(&[0xe8, 0xfb, 0x7f, 0x00, 0x00]);
    image[5..10].copy_from_slice(&[0xe8, 0xf6, 0xff, 0x00, 0x00]);
    image[10..12].copy_from_slice(&[0x0f, 0x0b]);
    // Chacune des deux régions appelées incrémente RDX et rend la main.
    for at in [SECOND, THIRD] {
        image[at as usize..at as usize + 4].copy_from_slice(&[0x48, 0xff, 0xc2, 0xc3]);
    }
    // **Un octet que le décodeur ne lit pas**, à seize kibioctets pile — donc
    // hors de la fenêtre de la première région, et sur la route de personne.
    // Il n'est là que pour qu'on puisse demander au traducteur une région
    // qu'il doit refuser, et vérifier *comment* il le dit.
    image[UNREADABLE as usize] = 0x06;

    let scratch = std::env::temp_dir().join(format!("wisq-demande-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let image_path = scratch.join("image.bin");
    std::fs::write(&image_path, &image).expect("l'image");

    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";
const demandées = [];
const tailles = [];
const vm = machine({{
  // **Le pilote ne sait rien des régions.** Il reçoit une adresse, il va
  // chercher un traducteur, il rend les octets. C'est exactement la forme que
  // l'application a — un aller-retour vers le processus où vit l'émetteur.
  // **Les octets arrivent par l'hôte.** Il les a lus dans la mémoire de
  // l'invité — repliés par le masque ici, puisque rien n'a allumé la
  // pagination — et le traducteur ne connaît plus d'autre source : c'est la
  // tranche #254, et c'est ce qui rend ce test capable de dire *où* les
  // octets ont été pris.
  translate: (address, slot, code) => {{
    demandées.push(address);
    const out = Bun.spawnSync({{
      cmd: [{translator:?}, String({pages}), address.toString(), String(slot)],
      stdin: code,
    }});
    if (out.exitCode !== 0) return null;
    tailles.push(out.stdout.length);
    return out.stdout;
  }},
  pages: {pages},
}});
new Uint8Array(vm.memory.buffer).set(readFileSync({image:?}), {physical});
vm.globals[{rip}].value = {base}n;
vm.globals[4].value = 0x70000n;  // rsp
vm.globals[2].value = 0n;        // rdx : le témoin
const why = await vm.run({{ budget: 1000n, rounds: 32 }});
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value);
console.log("arret " + why.stopped);
console.log("rdx " + lire(2).toString());
console.log("rip 0x" + lire({rip}).toString(16));
console.log("demandées " + demandées.map((a) => "0x" + a.toString(16)).join(" "));
console.log("octets " + tailles[0]);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            translator = env!("CARGO_BIN_EXE_x86-translate"),
            image = image_path.to_string_lossy(),
            physical = PHYSICAL,
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
        output.status.success(),
        "le pilote a échoué :\n{errors}\n{text}"
    );
    let line = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .unwrap_or("")
            .trim()
            .to_string()
    };
    // **Les quatre adresses, dans l'ordre, et rien d'autre.** C'est la seule
    // assertion qui dit que rien n'était connu d'avance : aucune des trois
    // dernières ne se lit ailleurs que dans l'exécution de la première.
    //
    // **Il y en avait cinq, et la cinquième était `0x10005`** — l'octet qui
    // suit le premier `call`, c'est-à-dire un bloc que la première région
    // porte déjà. Elle a disparu quand la correspondance a cessé de n'y ranger
    // que l'adresse d'entrée : le `ret` qui y retombe la trouve maintenant, et
    // le module continue sans repasser par l'hôte. C'est cette tranche-ci, et
    // c'est le seul changement d'attente qu'elle demande.
    //
    // **`0x1000a` reste demandée, et pas pour la même raison.** Le bloc qui
    // commence là est le `ud2` : il rend la main **par conception**, quoi que
    // la correspondance sache. L'hôte se retrouve alors avec une adresse que
    // sa carte `known` ne connaît pas — elle est encore indexée par entrée de
    // région, comme la correspondance l'était — et il traduit une région qui
    // commence là. C'est le cas résiduel nommé dans
    // `a_target_inside_a_known_region_needs_no_second_translation` : une fois
    // par retour de main au pire, contre une fois par `ret` avant.
    assert_eq!(
        line("demandées "),
        format!("0x{BASE:x} 0x{:x} 0x{:x}", BASE + SECOND, BASE + THIRD),
        // **Trois, et non quatre depuis #227.** La quatrième était l'adresse du
        // `ud2` : l'hôte y réclamait une région parce qu'il ne savait pas
        // pourquoi le bloc lui rendait la main. Il le sait maintenant — le
        // module pose un témoin —, et il nomme l'arrêt au lieu de demander à
        // traduire une instruction qui n'en est pas une.
        "trois demandes, dans l'ordre où la machine les rencontre : {text}"
    );
    assert_eq!(
        line("rdx "),
        "2",
        "les deux régions appelées ont chacune incrémenté RDX : {text}"
    );
    assert_eq!(
        line("rip "),
        format!("0x{:x}", BASE + 10),
        "et la machine finit sur le `ud2` de la première région : {text}"
    );

    // **Le traducteur rend le module que l'émetteur rendrait**, au même octet
    // près. C'est ce qui tient la fenêtre qu'il lit : avec une fenêtre plus
    // courte, la première région ne porterait pas ses trois blocs, et la suite
    // marcherait quand même — par d'autres régions, sans que rien ne rougisse.
    let expected = Module::resolving_or_why(&image[..16384], BASE, 0, 0, PAGES)
        .expect("la région d'entrée se traduit");
    assert_eq!(
        line("octets "),
        expected.len().to_string(),
        "le premier module fait la taille que l'émetteur lui donne : {text}"
    );

    // **Les codes de sortie sont le protocole**, et rien ne les tenait : un
    // pilote qui confondrait « je ne sais pas lire cet octet » et « il n'y a
    // pas d'octets là » chercherait une instruction manquante là où il n'y a
    // qu'une adresse hors image.
    let ask = |at: u64, window: &[u8]| {
        let mut child = Command::new(env!("CARGO_BIN_EXE_x86-translate"))
            .arg(PAGES.to_string())
            .arg(at.to_string())
            .arg("0")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .expect("le traducteur");
        std::io::Write::write_all(child.stdin.as_mut().expect("l'entrée"), window)
            .expect("la fenêtre");
        drop(child.stdin.take());
        child.wait().expect("le traducteur").code()
    };
    // **La fenêtre telle que l'hôte la lirait** : l'adresse repliée sur la RAM
    // déclarée, moins l'adresse physique où ce test a posé l'image.
    let window = |at: u64| {
        let from = (Module::fold(at, PAGES) - PHYSICAL) as usize;
        &image[from..(from + 16384).min(image.len())]
    };
    assert_eq!(
        ask(BASE, window(BASE)),
        Some(0),
        "la région d'entrée se traduit"
    );
    assert_eq!(
        ask(BASE + UNREADABLE, window(BASE + UNREADABLE)),
        Some(2),
        "un octet illisible à l'entrée est un refus franc, et le dit par 2"
    );
    // **Et une fenêtre vide dit 3, pas 2.** C'est ce que le code 3 veut dire
    // depuis #254 : non plus « cette adresse ne tombe dans aucun segment du
    // fichier » — il n'y a plus de fichier — mais « il n'y a aucun octet ».
    // Un pilote qui confondrait les deux chercherait une instruction
    // manquante là où il n'y a rien du tout.
    assert_eq!(
        ask(BASE, &[]),
        Some(3),
        "une fenêtre vide n'est pas un refus de l'émetteur : elle le dit par 3"
    );

    let _ = std::fs::remove_dir_all(&scratch);
}

/// **La sonde du noyau, exécutée telle quelle, trouve enfin un 8259.**
///
/// « Using NULL legacy PIC » : c'est ce que le noyau d'Alpine imprime, et il le
/// dit depuis toujours sans que personne aille voir pourquoi. La raison tient
/// en cinq instructions, lues dans le binaire plutôt que supposées —
/// `probe_8259A`, à `0xffffffff8104e7a0` :
///
/// ```text
/// mov $0xff,%eax ; out %al,$0xa1     ; masque tout sur l'esclave
/// mov $0xfb,%eax ; out %al,$0x21     ; masque tout sauf la cascade sur le maître
/// in  $0x21,%al                      ; et relit
/// cmp $0xfb,%al                      ; ce qu'il vient d'écrire
/// ```
///
/// `web/host.js` rendait `0xff` pour tout port sans personne — le bus qui
/// flotte, ce qui est la bonne réponse quand il n'y a personne. La relecture ne
/// pouvait donc jamais valoir `0xfb`, et le noyau concluait, correctement,
/// qu'il n'y a pas de contrôleur d'interruptions. Sans contrôleur, pas de
/// routage d'IRQ0 ; sans IRQ0, pas d'horloge ; sans horloge, `calibrate_delay`
/// tourne sur lui-même. Tout le mur tient à un registre de huit bits qui se
/// relit.
///
/// **Le programme de ce test est la sonde du noyau, octet pour octet**, avec un
/// `xor` devant pour que ce qui reste dans RAX vienne du port et de rien
/// d'autre — `in %al` n'écrit que l'octet bas.
#[test]
fn the_kernels_own_probe_finds_the_interrupt_controller() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program = [
        0x31, 0xc0, // xor %eax,%eax
        0xb0, 0xff, // mov $0xff,%al
        0xe6, 0xa1, // out %al,$0xa1
        0xb0, 0xfb, // mov $0xfb,%al
        0xe6, 0x21, // out %al,$0x21
        0x31, 0xc0, // xor %eax,%eax  — RAX ne portera que ce que le port rend
        0xe4, 0x21, // in  $0x21,%al
        0x0f, 0x0b, // ud2            — rend la main
    ];
    let text = drive(&bun, &program, BASE, PAGES, "sonde-8259", "");
    assert_eq!(
        line_of(&text, "rax "),
        "fb",
        "le maître doit rendre le masque qu'on vient de lui écrire : {text}"
    );
}

/// **La séquence d'initialisation pose une base de vecteur, et ce n'est pas
/// celle qu'on aurait écrite de mémoire.**
///
/// Lue dans `init_8259A`, à `0xffffffff8104e620`, et c'est la raison d'être de
/// ce test : la base du maître est **`0x30`**, pas `0x20`. Un modèle écrit de
/// tête aurait porté `0x20` — la valeur du PC d'origine, celle de tous les
/// manuels — et la tranche qui délivre IRQ0 aurait sauté dans la mauvaise
/// porte de l'IDT, vingt tranches plus loin, sans que rien ne dise pourquoi.
///
/// ```text
/// out 0xff→0x21   out 0x11→0x20   out 0x30→0x21   out 0x04→0x21   out 0x03→0x21
/// out 0x11→0xa0   out 0x38→0xa1   out 0x02→0xa1   out 0x01→0xa1
/// ```
///
/// `0x11` porte le bit d'initialisation : ce qui suit sur le port de données
/// n'est plus un masque mais ICW2, ICW3, ICW4. **C'est la seule chose que ce
/// test tient et que la sonde ne tenait pas** : un modèle qui rangerait ICW2
/// dans le masque rendrait la sonde verte quand même — le noyau repose son
/// masque juste après — et se tromperait de vecteur pour toujours.
#[test]
fn the_init_sequence_sets_the_vector_base_the_kernel_actually_uses() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let mut program = Vec::new();
    for (value, port) in [
        (0xffu8, 0x21u8), // masque tout sur le maître
        (0x11, 0x20),     // ICW1 : initialisation, ICW4 suivra
        (0x30, 0x21),     // ICW2 : la base de vecteur du maître
        (0x04, 0x21),     // ICW3 : l'esclave est sur IR2
        (0x03, 0x21),     // ICW4 : mode 8086, fin automatique
        (0x11, 0xa0),     // et la même chose pour l'esclave
        (0x38, 0xa1),     // ICW2 : sa base à lui
        (0x02, 0xa1),     // ICW3 : son identité de cascade
        (0x01, 0xa1),     // ICW4
        (0xfb, 0x21),     // le masque que le noyau repose après l'initialisation
    ] {
        program.extend_from_slice(&[0xb0, value, 0xe6, port]);
    }
    program.extend_from_slice(&[0x31, 0xc0, 0xe4, 0x21, 0x0f, 0x0b]);
    let text = drive(
        &bun,
        &program,
        BASE,
        PAGES,
        "init-8259",
        r#"console.log("bases " + vm.pics.master.base + " " + vm.pics.slave.base);"#,
    );
    assert_eq!(
        line_of(&text, "bases "),
        "48 56",
        "les bases posées par ICW2 sont 0x30 et 0x38 — celles que ce noyau \
         emploie, pas celles du PC d'origine : {text}"
    );
    assert_eq!(
        line_of(&text, "rax "),
        "fb",
        "et le port de données redevient le masque une fois l'initialisation \
         finie : ICW4 ne doit pas rester dedans : {text}"
    );
}

/// Compiler un programme, le faire tourner sous `web/host.js`, et rendre ce que
/// le pilote a imprimé. `extra` ajoute des lignes au relevé.
fn drive(bun: &Path, program: &[u8], base: u64, pages: u32, name: &str, extra: &str) -> String {
    drive_with(bun, program, base, pages, name, "", extra)
}

/// La même, avec des lignes posées **avant** que la machine ne parte : c'est la
/// seule façon de partir d'un état que le programme lui-même n'aurait pas pu
/// écrire.
#[allow(clippy::too_many_arguments)]
fn drive_with(
    bun: &Path,
    program: &[u8],
    base: u64,
    pages: u32,
    name: &str,
    setup: &str,
    extra: &str,
) -> String {
    let module = Module::resolving(program, base, 0, 0, pages).expect("la région se traduit");
    let scratch = std::env::temp_dir().join(format!("wisq-{name}-{}", std::process::id()));
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
{setup}
await vm.run({{ budget: 1000n, rounds: 4 }});
console.log("rax " + BigInt.asUintN(64, vm.globals[0].value).toString(16));
console.log("rbx " + BigInt.asUintN(64, vm.globals[3].value).toString());
{extra}
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = pages,
            rip = RIP_SLOT,
            base = base,
            setup = setup,
            extra = extra,
        ),
    )
    .expect("le pilote");
    let output = Command::new(bun)
        .arg("run")
        .arg(&driver)
        .output()
        .expect("bun");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let errors = String::from_utf8_lossy(&output.stderr).to_string();
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        output.status.success(),
        "le pilote a échoué :\n{errors}\n{text}"
    );
    text
}

/// La valeur qui suit une étiquette dans le relevé du pilote.
fn line_of(text: &str, label: &str) -> String {
    text.lines()
        .find_map(|line| line.strip_prefix(label))
        .unwrap_or_default()
        .trim()
        .to_string()
}

/// **Le prologue d'étalonnage du noyau, exécuté tel quel, trouve un 8254.**
///
/// Lu dans `quick_pit_calibrate`, à `0xffffffff81056382`, et c'est du canal
/// **deux** qu'il se sert — celui du haut-parleur, dont le portillon est sur le
/// port `0x61` :
///
/// ```text
/// in  $0x61,%al ; and $0xfc,%eax ; or $0x1,%eax ; out %al,$0x61
/// mov $0xb0,%al ; out %al,$0x43     ; canal 2, accès bas/haut, mode 0, binaire
/// mov $0xff,%al ; out %al,$0x42     ; le compteur bas
///                 out %al,$0x42     ; puis le haut — 0xffff
/// in  $0x42,%al ×4
/// ```
///
/// **Ce test n'assène pas la valeur que le noyau compare.** Il compare `%al` à
/// `0xff` après ces quatre lectures — et `0xff` est *exactement* ce que rend un
/// port où il n'y a personne. Une assertion sur cette valeur-là serait verte
/// sans le moindre 8254, et c'est le piège que ce dépôt s'est déjà interdit.
///
/// Ce qu'il tient à la place est le **portillon** : `0x61` doit rendre ce que le
/// noyau vient d'y écrire. Un port qui flotte rend `0xff` ; celui-ci doit rendre
/// `0x01` — le bit du portillon allumé, celui du haut-parleur éteint, et la
/// sortie du canal 2 encore basse parce qu'un compteur en mode 0 ne la lève
/// qu'en atteignant zéro.
#[test]
fn the_kernels_calibration_prologue_finds_a_timer() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let program = [
        0x31, 0xc0, // xor %eax,%eax
        0xe4, 0x61, // in  $0x61,%al        — lire le portillon
        0x83, 0xe0, 0xfc, // and $0xfffffffc,%eax
        0x83, 0xc8, 0x01, // or  $0x1,%eax
        0xe6, 0x61, // out %al,$0x61        — portillon ouvert, haut-parleur muet
        0xb0, 0xb0, // mov $0xb0,%al
        0xe6, 0x43, // out %al,$0x43        — le mot de commande
        0xb0, 0xff, // mov $0xff,%al
        0xe6, 0x42, // out %al,$0x42        — le compteur bas
        0xe6, 0x42, // out %al,$0x42        — puis le haut
        0xe4, 0x42, // in  $0x42,%al        — les quatre lectures du noyau
        0xe4, 0x42, //
        0xe4, 0x42, //
        0xe4, 0x42, //
        0x31, 0xc0, // xor %eax,%eax
        0xe4, 0x61, // in  $0x61,%al        — et c'est ÇA que le test tient
        0x0f, 0x0b, // ud2
    ];
    let text = drive(&bun, &program, BASE, PAGES, "prologue-8254", "");
    assert_eq!(
        line_of(&text, "rax "),
        "1",
        "le port du portillon doit rendre ce qu'on vient d'y écrire — pas le \
         0xff d'un bus qui flotte, et pas la sortie d'un compteur qui n'a pas \
         fini : {text}"
    );
}

/// **Le compteur descend, et il descend au bon rythme.**
///
/// C'est la seule propriété dont l'étalonnage a besoin, et la seule qu'un
/// modèle puisse se tromper en silence. Le noyau ne lit pas l'heure : il compte
/// combien de fois son propre `rdtsc` avance pendant que le compteur du 8254
/// perd un octet de poids fort, et il en déduit une fréquence. Un compteur qui
/// ne bouge pas fait échouer l'étalonnage ; un compteur qui bouge au mauvais
/// rythme fait **annoncer une fréquence fausse**, ce qui est pire — la machine
/// dormirait trop peu ou trop longtemps partout, sans que rien ne rougisse.
///
/// **Le montage.** Le compteur est chargé à `0xffff`, puis lu trois fois,
/// séparées par quatre mille `rdtsc`. Chaque `rdtsc` avance l'horloge de
/// `TSC_STEP`, cent — c'est le contrat de l'émetteur, et le seul mouvement
/// d'horloge de ce test : un seul tour est accordé, donc le budget que la
/// boucle hôte ajoute d'ordinaire tombe après tout le monde.
///
/// Quatre mille lectures font donc 400 000 unités d'horloge. À 1 193 182 Hz
/// pour le 8254 contre le gigahertz nominal du compteur d'horodatage, cela fait
/// **477** pas — et ce nombre est écrit ici en toutes lettres plutôt que
/// recalculé depuis les deux constantes, sans quoi les deux côtés bougeraient
/// ensemble et le test ne tiendrait plus rien.
#[test]
fn the_timer_counts_down_at_the_rate_the_kernel_will_measure() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    /// Ce que quatre mille `rdtsc` font perdre au compteur. Écrit, pas calculé.
    const STEPS: u64 = 477;
    let mut program: Vec<u8> = vec![
        0xb0, 0x01, 0xe6, 0x61, // portillon ouvert
        0xb0, 0xb0, 0xe6, 0x43, // canal 2, accès bas/haut, mode 0
        0xb0, 0xff, 0xe6, 0x42, 0xe6, 0x42, // chargé à 0xffff
    ];
    // Lire les deux octets du compteur et les recomposer dans un registre que
    // `rdtsc` ne touche pas — il n'écrit qu'EAX et EDX.
    let read_into = |program: &mut Vec<u8>, keep: u8| {
        program.extend_from_slice(&[
            0x31, 0xc0, // xor %eax,%eax
            0xe4, 0x42, // in  $0x42,%al   — l'octet bas
            0x89, 0xc1, // mov %eax,%ecx
            0x31, 0xc0, // xor %eax,%eax
            0xe4, 0x42, // in  $0x42,%al   — puis le haut
            0xc1, 0xe0, 0x08, // shl $8,%eax
            0x09, 0xc8, // or  %ecx,%eax
            0x89, keep, // mov %eax,<registre gardé>
        ]);
    };
    read_into(&mut program, 0xc3); // → %ebx
    program.extend(std::iter::repeat_n([0x0f, 0x31], 4000).flatten());
    read_into(&mut program, 0xc6); // → %esi
    program.extend(std::iter::repeat_n([0x0f, 0x31], 4000).flatten());
    read_into(&mut program, 0xc7); // → %edi
    program.extend_from_slice(&[0x0f, 0x0b]);

    let text = drive(
        &bun,
        &program,
        BASE,
        PAGES,
        "rythme-8254",
        r#"const lire = (at) => BigInt.asUintN(64, vm.globals[at].value);
console.log("compteurs " + lire(3) + " " + lire(6) + " " + lire(7));"#,
    );
    let counts: Vec<u64> = line_of(&text, "compteurs ")
        .split_whitespace()
        .filter_map(|value| value.parse().ok())
        .collect();
    assert_eq!(counts.len(), 3, "trois lectures du compteur : {text}");
    assert_eq!(
        counts[0], 0xffff,
        "la première lecture voit le compteur tel qu'il vient d'être chargé, \
         parce que rien n'a encore fait avancer l'horloge : {text}"
    );
    assert_eq!(
        (counts[0] - counts[1], counts[1] - counts[2]),
        (STEPS, STEPS),
        "et il perd le même nombre de pas pour la même durée, {STEPS} — \
         c'est ce rapport que le noyau prendra pour la fréquence de son \
         compteur d'horodatage : {text}"
    );
}

/// **Écrire un diviseur et lire un compteur sont deux séquences, pas une.**
///
/// En accès bas-puis-haut, la puce se souvient de deux choses différentes : de
/// quel octet du diviseur elle attend l'écriture, et quel octet du compte elle
/// rendra à la prochaine lecture. Les tenir dans un seul drapeau marche tant
/// que personne n'entrelace les deux — et ce test entrelace, exprès.
///
/// Le montage est la programmation périodique du noyau, lue dans
/// `pit_set_periodic` à `0xffffffff818f8b60` — `0x34` sur le port de commande
/// (canal 0, bas/haut, **mode 2**), puis `0x89` et `0x0f`, soit un diviseur de
/// 3977 : 1 193 182 hertz divisés par 3977 font trois cents, et ce noyau est
/// bâti à trois cents hertz. Une lecture est glissée **entre les deux
/// écritures**.
///
/// Avec deux séquences séparées, le diviseur vaut `0x0f89` et le compte ne peut
/// pas le dépasser. Avec une seule, la lecture consomme la moitié de
/// l'écriture, les octets se décalent, et le diviseur devient un autre nombre —
/// que le compte trahit aussitôt.
#[test]
fn writing_a_divisor_and_reading_a_count_are_two_sequences() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    const DIVISOR: u64 = 0x0f89;
    let program = [
        0xb0, 0x34, 0xe6, 0x43, // mot de commande : canal 0, bas/haut, mode 2
        0xb0, 0x89, 0xe6, 0x40, // l'octet bas du diviseur
        0xe4, 0x40, // et une lecture glissée au milieu
        0xb0, 0x0f, 0xe6, 0x40, // l'octet haut
        // puis le compte, recomposé dans RBX
        0x31, 0xc0, 0xe4, 0x40, 0x89, 0xc1, 0x31, 0xc0, 0xe4, 0x40, 0xc1, 0xe0, 0x08, 0x09, 0xc8,
        0x89, 0xc3, //
        0x0f, 0x0b, // ud2
    ];
    let text = drive(
        &bun,
        &program,
        BASE,
        PAGES,
        "sequences-8254",
        r#"console.log("compte " + BigInt.asUintN(64, vm.globals[3].value));
console.log("diviseur " + vm.pits[0].reload);"#,
    );
    assert_eq!(
        line_of(&text, "diviseur "),
        DIVISOR.to_string(),
        "les deux écritures composent 0x0f89, que la lecture du milieu ne doit \
         pas décaler : {text}"
    );
    let count: u64 = line_of(&text, "compte ").parse().unwrap_or(u64::MAX);
    assert!(
        count > 0 && count <= DIVISOR,
        "et un compteur en mode 2 ne dépasse jamais son diviseur : {count} \
         pour {DIVISOR} — {text}"
    );
}

/// **Le canal périodique recharge, il ne court pas après zéro.**
///
/// C'est ce qui distingue le mode 2 — celui de la cadence, que `pit_set_periodic`
/// programme — du mode 0 de l'étalonnage. En mode 0 le compteur descend et
/// **boucle** par en bas ; en mode 2 il repart de son diviseur à chaque fois
/// qu'il l'atteint. T3 fera monter IRQ0 sur ce rechargement : un compteur qui
/// boucle au lieu de recharger donnerait une cadence de soixante-cinq mille
/// pas au lieu de son diviseur, soit une interruption toutes les cinquante-cinq
/// millisecondes au lieu de trois — et rien ne rougirait.
///
/// **Le montage rend le tour court exprès.** Un diviseur de seize pas se
/// franchit en deux cents `rdtsc` ; celui du noyau, 3977, en demanderait
/// trente-trois mille, soit un programme plus gros que la fenêtre que le
/// traducteur lit. Deux cents lectures font vingt mille unités d'horloge, donc
/// vingt-trois pas du 8254 — un tour entier et sept de plus. Le compteur doit
/// donc rendre **neuf** : seize moins sept. S'il bouclait, il rendrait 65 529.
#[test]
fn the_periodic_channel_reloads_instead_of_running_past_zero() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let mut program: Vec<u8> = vec![
        0xb0, 0x34, 0xe6, 0x43, // canal 0, bas/haut, mode 2
        0xb0, 0x10, 0xe6, 0x40, // diviseur : seize
        0xb0, 0x00, 0xe6, 0x40, //
    ];
    program.extend(std::iter::repeat_n([0x0f, 0x31], 200).flatten());
    program.extend_from_slice(&[
        0x31, 0xc0, 0xe4, 0x40, 0x89, 0xc1, 0x31, 0xc0, 0xe4, 0x40, 0xc1, 0xe0, 0x08, 0x09, 0xc8,
        0x89, 0xc3, // le compte, dans RBX
        0x0f, 0x0b,
    ]);
    let text = drive(&bun, &program, BASE, PAGES, "periodique-8254", "");
    assert_eq!(
        line_of(&text, "rbx "),
        "9",
        "seize moins les sept pas du second tour — un compteur qui bouclerait \
         rendrait 65529 : {text}"
    );
}

/// **`fninit` remet le coprocesseur à son allumage, et c'est ce que le noyau
/// vérifiera.**
///
/// Annoncer le bit zéro d'EDX ne suffit pas : `fpu__init_system` exécute
/// `fninit` derrière sa garde, puis lit l'état qu'elle laisse. Le mot de
/// contrôle doit valoir `0x037f` — toutes les exceptions masquées, précision
/// étendue, arrondi au plus proche — et le mot d'état zéro. Linux exige
/// exactement `mot & 0x103f == 0x003f`, ce que `0x037f` satisfait.
///
/// **Les deux mots partent d'une valeur que le programme n'aurait pas pu
/// écrire**, et c'est tout l'intérêt : un émetteur qui traduirait `fninit` en
/// rien du tout laisserait `0xabcd` dans le mot d'état, et le noyau
/// effacerait le bit de capacité qu'on vient de lui annoncer. Partir de zéro
/// rendrait ce test vert sans la moindre remise à l'état d'allumage.
#[test]
fn fninit_resets_the_coprocessor_to_its_power_on_state() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let text = drive_with(
        &bun,
        &[0xdb, 0xe3, 0x0f, 0x0b], // fninit ; ud2
        BASE,
        PAGES,
        "fninit",
        &format!(
            "vm.globals[{control}].value = 0x1234n;\nvm.globals[{status}].value = 0xabcdn;",
            control = FPU_CONTROL_SLOT,
            status = FPU_STATUS_SLOT,
        ),
        &format!(
            r#"console.log("fcw " + vm.globals[{control}].value);
console.log("fsw " + vm.globals[{status}].value);"#,
            control = FPU_CONTROL_SLOT,
            status = FPU_STATUS_SLOT,
        ),
    );
    assert_eq!(
        line_of(&text, "fcw "),
        "895",
        "le mot de contrôle doit valoir 0x037f, ce que `fninit` pose — et ce \
         que Linux exige : {text}"
    );
    assert_eq!(
        line_of(&text, "fsw "),
        "0",
        "et le mot d'état doit être remis à zéro, pas laissé tel quel : {text}"
    );
}

/// **`fxsave` écrit l'aire de 512 octets : ce que la machine a, et zéro pour
/// ce qu'elle n'a pas.**
///
/// C'est le mur mesuré après #224 — la machine s'arrête pour de vrai à
/// `fpu__init_system + 183`, sur `0f ae 05 d2 f1 13 00`.
///
/// **Les zéros ne sont pas un remplissage, ils sont la vérité.** L'émetteur
/// n'a aucun registre XMM et aucune instruction XMM ne se décode : personne
/// n'a jamais pu écrire dans cette moitié de l'aire. Le mot d'étiquettes
/// abrégé vaut zéro pour la même raison — aucun registre x87 n'est occupé.
/// MXCSR et son masque valent zéro parce que cette machine n'a pas de MXCSR,
/// et Linux prévoit ce cas : masque nul, il prend sa valeur par défaut
/// documentée.
///
/// **Ce que le test tient et qu'un bouchon ne tiendrait pas.** L'aire est
/// pré-remplie de `0xee` : un `fxsave` qui n'écrirait rien, ou qui n'écrirait
/// que les quatre premiers octets, laisserait ces témoins en place. Et les
/// deux mots venus des globales portent des valeurs que `fninit` ne produit
/// pas — `0x1234` et `0xabcd` —, donc un émetteur qui écrirait `0x037f` et
/// zéro en dur tomberait aussi.
///
/// Les huit octets de part et d'autre sont gardés : une aire de 513 octets
/// écraserait la mémoire du voisin.
#[test]
fn fxsave_writes_the_state_the_machine_has_and_zero_for_what_it_has_not() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    const AREA: u32 = 0x2000;
    // **Le nombre est écrit ici en toutes lettres, et non lu dans la
    // constante que ce test garde.** Le lire là-bas rendrait le test complice :
    // changer 416 en 512 changerait l'attente en même temps que le code, et
    // rien ne tomberait — deux sabotages l'ont montré en survivant.
    const WRITTEN: usize = 416;
    assert_eq!(
        FXSAVE_WRITTEN as usize, WRITTEN,
        "un vrai processeur n'écrit que 416 des 512 octets de l'aire — mesuré \
         par le corpus matériel, et le cœur Swift s'arrête au même octet"
    );
    let text = drive_with(
        &bun,
        &[0x0f, 0xae, 0x00, 0x0f, 0x0b], // fxsave (%rax) ; ud2
        BASE,
        PAGES,
        "fxsave",
        &format!(
            r#"vm.globals[0].value = {area}n;
vm.globals[{control}].value = 0x1234n;
vm.globals[{status}].value = 0xabcdn;
new Uint8Array(vm.memory.buffer, {area} - 8, 512 + 16).fill(0xee);"#,
            area = AREA,
            control = FPU_CONTROL_SLOT,
            status = FPU_STATUS_SLOT,
        ),
        &format!(
            r#"const aire = new Uint8Array(vm.memory.buffer, {area}, 512);
console.log("tete " + Array.from(aire.slice(0, 8)).map((o) => o.toString(16).padStart(2, "0")).join(""));
console.log("reste " + aire.slice(4, {written}).reduce((n, o) => n + (o === 0 ? 0 : 1), 0));
console.log("reserve " + aire.slice({written}).every((o) => o === 0xee));
console.log("avant " + new Uint8Array(vm.memory.buffer, {area} - 8, 8).join(","));
console.log("apres " + new Uint8Array(vm.memory.buffer, {area} + 512, 8).join(","));
console.log("fcw " + vm.globals[{control}].value);
console.log("fsw " + vm.globals[{status}].value);"#,
            area = AREA,
            written = WRITTEN,
            control = FPU_CONTROL_SLOT,
            status = FPU_STATUS_SLOT,
        ),
    );
    assert_eq!(
        line_of(&text, "tete "),
        "3412cdab00000000",
        "le mot de contrôle en 0x00, le mot d'état en 0x02, et le mot \
         d'étiquettes abrégé nul en 0x04 — aucun registre x87 n'est occupé : \
         {text}"
    );
    assert_eq!(
        line_of(&text, "reste "),
        "0",
        "les 412 octets qui suivent doivent être écrits à zéro, pas laissés \
         tels quels : ST0-7 et XMM0-15 n'existent pas ici, et MXCSR non plus \
         — Linux prend sa valeur par défaut quand le masque lit zéro : {text}"
    );
    assert_eq!(
        line_of(&text, "reserve "),
        "true",
        "et les 96 derniers octets de l'aire restent tels quels : le corpus \
         matériel a mesuré qu'un vrai processeur ne les touche pas, et le \
         cœur Swift s'arrête au même octet : {text}"
    );
    assert_eq!(
        line_of(&text, "avant "),
        "238,238,238,238,238,238,238,238",
        "rien au-dessous de l'aire : {text}"
    );
    assert_eq!(
        line_of(&text, "apres "),
        "238,238,238,238,238,238,238,238",
        "ni au-dessus : 512 octets, pas un de plus : {text}"
    );
    assert_eq!(
        line_of(&text, "fcw "),
        "4660",
        "`fxsave` ne modifie pas le coprocesseur : 0x1234 doit être intact, \
         ce qui est aussi ce qui la rend rejouable après une faute : {text}"
    );
    assert_eq!(line_of(&text, "fsw "), "43981", "et le mot d'état : {text}");
}

/// **`fxrstor` relit ce que `fxsave` a écrit, et ne touche pas l'aire.**
///
/// Le mur mesuré à #252 : la machine s'arrête pour de vrai à
/// `0xffffffff8105a57c`, sur `48 0f ae 4b 40` — `restore_fpregs_from_fpstate`,
/// qui relit l'état neuf du coprocesseur au moment de basculer vers `/init`.
/// **`fxsave` était décodée depuis #225 ; celle-ci ne l'a jamais été.**
///
/// **Ce que le test tient et qu'un bouchon ne tiendrait pas.** Les deux
/// globales portent avant l'instruction des valeurs que l'aire ne contient
/// pas : un `fxrstor` qui ne ferait rien les laisserait en place, un qui
/// n'en relirait qu'une laisserait l'autre, et un qui les échangerait
/// donnerait deux fois le mauvais mot. L'aire est en outre relue après coup :
/// `fxrstor` **lit**, elle n'écrit pas — la confondre avec son jumeau
/// écraserait l'état qu'on vient de lui donner.
#[test]
fn fxrstor_reads_the_state_back_into_the_machine_and_writes_nothing() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    const AREA: u32 = 0x2000;
    let text = drive_with(
        &bun,
        &[0x0f, 0xae, 0x08, 0x0f, 0x0b], // fxrstor (%rax) ; ud2
        BASE,
        PAGES,
        "fxrstor",
        &format!(
            r#"vm.globals[0].value = {area}n;
// L'aire est remplie de témoins, puis les deux mots que la machine porte
// vraiment y sont posés. Les témoins doivent être lus sans être consommés.
new Uint8Array(vm.memory.buffer, {area} - 8, 512 + 16).fill(0xaa);
const vue = new DataView(vm.memory.buffer);
vue.setUint16({area} + 0x00, 0x0ff1, true);
vue.setUint16({area} + 0x02, 0x0ee2, true);
// Et les globales portent autre chose : ce qui doit être remplacé.
vm.globals[{control}].value = 0x1234n;
vm.globals[{status}].value = 0xabcdn;"#,
            area = AREA,
            control = FPU_CONTROL_SLOT,
            status = FPU_STATUS_SLOT,
        ),
        &format!(
            r#"console.log("fcw " + vm.globals[{control}].value);
console.log("fsw " + vm.globals[{status}].value);
const aire = new Uint8Array(vm.memory.buffer, {area}, 512);
console.log("tete " + Array.from(aire.slice(0, 8)).map((o) => o.toString(16).padStart(2, "0")).join(""));
console.log("temoins " + aire.slice(4).every((o) => o === 0xaa));
console.log("avant " + new Uint8Array(vm.memory.buffer, {area} - 8, 8).every((o) => o === 0xaa));
console.log("apres " + new Uint8Array(vm.memory.buffer, {area} + 512, 8).every((o) => o === 0xaa));"#,
            area = AREA,
            control = FPU_CONTROL_SLOT,
            status = FPU_STATUS_SLOT,
        ),
    );
    assert_eq!(
        line_of(&text, "fcw "),
        "4081",
        "le mot de contrôle vient de l'aire, en 0x00 : 0x0ff1 = 4081, et non \
         le 0x1234 que la globale portait avant : {text}"
    );
    assert_eq!(
        line_of(&text, "fsw "),
        "3810",
        "et le mot d'état vient de 0x02 : 0x0ee2 = 3810. Les deux valeurs \
         diffèrent exprès — les échanger donnerait 3810 et 4081 : {text}"
    );
    assert_eq!(
        line_of(&text, "tete "),
        "f10fe20eaaaaaaaa",
        "`fxrstor` **lit** l'aire : les deux mots doivent y être restés tels \
         quels, et les témoins juste après aussi. La confondre avec `fxsave` \
         écraserait l'état qu'on vient de lui donner : {text}"
    );
    assert_eq!(
        line_of(&text, "temoins "),
        "true",
        "et les 508 octets qui suivent restent 0xaa — rien n'est écrit dans \
         l'aire : {text}"
    );
    assert_eq!(line_of(&text, "avant "), "true", "rien au-dessous : {text}");
    assert_eq!(line_of(&text, "apres "), "true", "ni au-dessus : {text}");
}

/// **Une aire de `fxrstor` dont un octet manque ne restaure rien du tout.**
///
/// Ce test tient les deux faits **mesurés sur le silicium** le 15 septembre,
/// et non lus dans un manuel — la commande est à la feuille de route :
///
/// 1. Un vrai processeur exige que **les 512 octets** soient lisibles. L'aire
///    posée à cheval sur une page rendue illisible par `mprotect`, `fxrstor`
///    fait faute dès qu'il n'y a que 496 octets en page — bien au-delà des
///    416 que `fxsave` écrit. (Le contrôle sur `fxsave` fait faute dès 448 :
///    l'instrument mesure **l'accès**, pas l'écriture. Les deux nombres sont
///    différents et c'est exactement le piège.)
/// 2. Le **contenu** des quatre-vingt-seize derniers octets, lui, ne change
///    rien : zéro octet de différence entre une queue à `0x00` et à `0xff`.
///
/// Un `fxrstor` qui ne lirait que les quatre octets dont il se sert
/// passerait sans broncher là où le silicium fait faute — un émetteur plus
/// permissif que la machine qu'il imite, c'est-à-dire un bouchon complaisant.
///
/// **Et l'ordre est tenu ici, pas seulement écrit dans un commentaire.** Le
/// balayage vient avant la restauration, donc les deux globales doivent être
/// **intactes** après la faute : ou tout est lisible et l'état change, ou rien
/// ne change. Poser les deux mots d'abord laisserait un coprocesseur à moitié
/// restauré, et le rejeu par `iretq` ne le rattraperait pas.
#[test]
fn an_fxrstor_area_missing_one_page_restores_nothing_at_all() {
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
    const VA: u64 = 0xFFFF_8000_0020_0000;
    /// **Le décalage est choisi sur la frontière, et c'est tout le test.**
    ///
    /// `0xE60 + 416 = 0x1000` **exactement** : les 416 octets que `fxsave`
    /// écrit tiennent au dernier octet près dans la page cartographiée, et le
    /// 417e est le premier de la page absente. Un balayage de 512 fait donc
    /// faute, un balayage de 416 passe.
    ///
    /// La première version de ce test posait l'aire à `0xF00`, où
    /// `0xF00 + 416` déborde déjà : elle ne distinguait pas 416 de 512, et un
    /// sabotage qui ramenait le balayage aux 416 du jumeau y a **survécu**.
    /// C'est la leçon de #250 à l'envers — là un nombre tombait pile sur une
    /// frontière et cachait un arrondi, ici il en était trop loin et cachait
    /// une troncature. Un témoin doit être posé **sur** la frontière.
    ///
    /// Et `0xE60` est aligné sur seize, ce que `fxrstor` exige.
    const AT: u64 = 0xE60;

    let mut program: Vec<u8> = Vec::new();
    let mut push = |bytes: &[u8]| program.extend_from_slice(bytes);
    push(&[0x48, 0xb8]); // movabs $PML4,%rax
    push(&PML4.to_le_bytes());
    push(&[0x0f, 0x22, 0xd8]); // mov %rax,%cr3
    push(&[0x48, 0xb8]); // movabs $PG,%rax
    push(&(1u64 << 31).to_le_bytes());
    push(&[0x0f, 0x22, 0xc0]); // mov %rax,%cr0
    push(&[0x48, 0xb8]); // movabs $VA+AT,%rax
    push(&(VA + AT).to_le_bytes());
    push(&[0x0f, 0xae, 0x08]); // fxrstor (%rax)
    push(&[0x0f, 0x0b]); // ud2

    let scratch = std::env::temp_dir().join(format!("wisq-fxrstor-pg-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module =
        Module::resolving(&program, BASE, 0, 0, PAGES).expect("une région paginée se traduit");
    let path = scratch.join("fx.wasm");
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
const vue = new DataView(vm.memory.buffer);
const present = 0x3n;
const idx = (va, shift) => Number((BigInt(va) >> BigInt(shift)) & 0x1ffn);
vue.setBigUint64({pml4} + idx({va}n, 39) * 8, {pdpt}n | present, true);
vue.setBigUint64({pdpt} + idx({va}n, 30) * 8, {pd}n | present, true);
vue.setBigUint64({pd} + idx({va}n, 21) * 8, {pt}n | present, true);
vue.setBigUint64({pt} + idx({va}n, 12) * 8, {frameA}n | present, true);
// **La page suivante n'est délibérément pas cartographiée** : c'est elle qui
// porte les 256 derniers octets de l'aire.
new Uint8Array(vm.memory.buffer, {frameA}, 0x1000).fill(0xaa);
// Un état parfaitement valide dans la moitié lisible : si la machine ne
// lisait que ce dont elle se sert, elle le prendrait et n'y verrait rien.
vue.setUint16({frameA} + {at} + 0x00, 0x0ff1, true);
vue.setUint16({frameA} + {at} + 0x02, 0x0ee2, true);
vm.globals[{rip}].value = {base}n;
vm.globals[{control}].value = 0x1234n;
vm.globals[{status}].value = 0xabcdn;
const why = await vm.run({{ budget: 256n, rounds: 8 }});
console.log("arret " + why.stopped);
console.log("fcw " + vm.globals[{control}].value);
console.log("fsw " + vm.globals[{status}].value);
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            control = FPU_CONTROL_SLOT,
            status = FPU_STATUS_SLOT,
            pml4 = PML4,
            pdpt = PDPT,
            pd = PD,
            pt = PT,
            frameA = FRAME_A,
            va = VA,
            at = AT,
        ),
    )
    .expect("le pilote");

    let text = run_driver(&bun, &driver);
    let _ = std::fs::remove_dir_all(&scratch);
    assert_eq!(
        line_of(&text, "arret "),
        FAUTE_SANS_PORTE,
        "la seconde moitié de l'aire n'est pas cartographiée : un vrai \
         processeur fait faute, mesuré. Un `fxrstor` qui ne lirait que les \
         quatre octets dont il se sert passerait ici sans broncher : {text}"
    );
    assert_eq!(
        line_of(&text, "fcw "),
        "4660",
        "et **rien n'a été restauré** : 0x1234 = 4660 est intact. Le balayage \
         passe avant la restauration, donc ou tout est lisible et l'état \
         change, ou rien ne change : {text}"
    );
    assert_eq!(
        line_of(&text, "fsw "),
        "43981",
        "de même pour le mot d'état : 0xabcd = 43981 : {text}"
    );
}

/// **L'aire de `fxsave` à cheval sur deux pages tombe dans les deux trames.**
///
/// C'est ce que la forme en boucle achète, et il fallait le tenir plutôt que
/// l'affirmer. Chaque tour écrit huit octets par le chemin ordinaire, donc
/// chaque tour traduit son adresse pour son propre compte. La forme évidente
/// — traduire une fois, puis écrire à `adresse + 8`, `adresse + 16`… par le
/// décalage statique de WebAssembly — aurait été juste tant que l'aire tient
/// dans une page, et aurait écrit **dans la trame d'à côté** dès qu'elle n'y
/// tient plus. Un noyau ne choisit pas où `struct fxregs_state` atterrit.
///
/// Les deux pages sont mappées sur des trames **non contiguës** : la seconde
/// moitié de l'aire ne peut atterrir au bon endroit que par une vraie seconde
/// traduction. La trame qui suit la première en mémoire physique est
/// pré-remplie et doit rester intacte — c'est elle que la forme évidente
/// aurait écrasée.
#[test]
fn an_fxsave_area_that_straddles_two_pages_lands_in_both_frames() {
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
    /// **Pas `FRAME_A + 0x1000`** : la seconde page est délibérément ailleurs.
    const FRAME_B: u64 = 0x3_8000;
    /// La trame qui suit `FRAME_A` en physique, que rien ne doit toucher.
    const NEXT: u64 = FRAME_A + 0x1000;
    const VA: u64 = 0xFFFF_8000_0020_0000;
    /// 0xF00 + 416 = 0x10a0 : 256 octets écrits dans la première page, 160
    /// dans la seconde. Et 0xF00 est aligné sur seize, ce que `fxsave` exige.
    const AT: u64 = 0xF00;
    /// Écrit en toutes lettres, et non lu dans la constante gardée : voir le
    /// test voisin.
    const WRITTEN: u64 = 416;

    let mut program: Vec<u8> = Vec::new();
    let mut push = |bytes: &[u8]| program.extend_from_slice(bytes);
    push(&[0x48, 0xb8]); // movabs $PML4,%rax
    push(&PML4.to_le_bytes());
    push(&[0x0f, 0x22, 0xd8]); // mov %rax,%cr3
    push(&[0x48, 0xb8]); // movabs $PG,%rax
    push(&(1u64 << 31).to_le_bytes());
    push(&[0x0f, 0x22, 0xc0]); // mov %rax,%cr0
    push(&[0x48, 0xb8]); // movabs $VA+AT,%rax
    push(&(VA + AT).to_le_bytes());
    push(&[0x0f, 0xae, 0x00]); // fxsave (%rax)
    push(&[0x0f, 0x0b]); // ud2

    let scratch = std::env::temp_dir().join(format!("wisq-fxsave-pg-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module =
        Module::resolving(&program, BASE, 0, 0, PAGES).expect("une région paginée se traduit");
    let path = scratch.join("fx.wasm");
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
const vue = new DataView(vm.memory.buffer);
const present = 0x3n;
const idx = (va, shift) => Number((BigInt(va) >> BigInt(shift)) & 0x1ffn);
vue.setBigUint64({pml4} + idx({va}n, 39) * 8, {pdpt}n | present, true);
vue.setBigUint64({pdpt} + idx({va}n, 30) * 8, {pd}n | present, true);
vue.setBigUint64({pd} + idx({va}n, 21) * 8, {pt}n | present, true);
vue.setBigUint64({pt} + idx({va}n, 12) * 8, {frameA}n | present, true);
vue.setBigUint64({pt} + idx({va}n + 0x1000n, 12) * 8, {frameB}n | present, true);
// Les trois trames pré-remplies : les deux mappées, et celle qui suit la
// première en physique et que personne ne doit toucher.
for (const trame of [{frameA}, {frameB}, {next}]) {{
  new Uint8Array(vm.memory.buffer, trame, 0x1000).fill(0xee);
}}
vm.globals[{rip}].value = {base}n;
vm.globals[{control}].value = 0x1234n;
vm.globals[{status}].value = 0xabcdn;
const why = await vm.run({{ budget: 256n, rounds: 8 }});
console.log("arret " + why.stopped);
const octets = (at, n) => Array.from(new Uint8Array(vm.memory.buffer, at, n))
  .map((o) => o.toString(16).padStart(2, "0")).join("");
const compte = (at, n) => new Uint8Array(vm.memory.buffer, at, n)
  .reduce((c, o) => c + (o === 0 ? 0 : 1), 0);
console.log("tete " + octets({frameA} + {at}, 8));
console.log("basse " + compte({frameA} + {at} + 4, 0x100 - 4));
console.log("haute " + compte({frameB}, {written} - 0x100));
console.log("avant " + octets({frameA} + {at} - 8, 8));
console.log("apres " + octets({frameB} + {written} - 0x100, 8));
console.log("voisine " + compte({next}, 0x1000));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            control = FPU_CONTROL_SLOT,
            status = FPU_STATUS_SLOT,
            va = VA,
            at = AT,
            written = WRITTEN,
            pml4 = PML4,
            pdpt = PDPT,
            pd = PD,
            pt = PT,
            frameA = FRAME_A,
            frameB = FRAME_B,
            next = NEXT,
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
    let _ = std::fs::remove_dir_all(&scratch);
    assert!(
        errors.is_empty(),
        "le pilote n'écrit rien en erreur : {errors}"
    );
    assert_eq!(
        line_of(&text, "arret "),
        UD2_SANS_PORTE,
        "le `ud2` arrête : {text}"
    );
    assert_eq!(
        line_of(&text, "tete "),
        "3412cdab00000000",
        "les deux mots du coprocesseur sont au début de l'aire, dans la \
         première trame : {text}"
    );
    assert_eq!(
        line_of(&text, "basse "),
        "0",
        "le reste de la première page est écrit à zéro : {text}"
    );
    assert_eq!(
        line_of(&text, "haute "),
        "0",
        "et les 160 octets qui débordent tombent dans la **seconde** trame, \
         que seule une vraie deuxième traduction peut atteindre : {text}"
    );
    assert_eq!(
        line_of(&text, "avant "),
        "eeeeeeeeeeeeeeee",
        "rien au-dessous de l'aire : {text}"
    );
    assert_eq!(
        line_of(&text, "apres "),
        "eeeeeeeeeeeeeeee",
        "ni au-dessus : 416 octets écrits, pas un de plus : {text}"
    );
    assert_eq!(
        line_of(&text, "voisine "),
        "4096",
        "la trame qui suit la première en physique n'est pas touchée — c'est \
         elle qu'un décalage statique aurait écrasée : {text}"
    );
}

/// **Avant `fninit`, le mot de contrôle n'est pas zéro non plus.**
///
/// Le silicium sort de RESET avec `0x0040`, et `fninit` y pose ensuite
/// `0x037f` : deux valeurs distinctes, qu'il est facile de confondre parce
/// qu'un noyau n'en lit qu'une. Personne ici ne lit la première — c'est
/// précisément pourquoi elle a besoin d'un test : une globale laissée à zéro
/// donnerait un mot légal qu'aucun processeur ne produit au démarrage, et la
/// divergence ne se verrait que le jour où on comparerait une trace au vrai
/// matériel.
///
/// Le programme n'exécute rien du coprocesseur : `ud2` tout de suite. Ce qui
/// est jugé, c'est donc l'état que **l'hôte** pose, et rien d'autre.
#[test]
fn the_coprocessor_starts_at_the_word_a_processor_leaves_after_reset() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    let text = drive_with(
        &bun,
        &[0x0f, 0x0b], // ud2, sans toucher au coprocesseur
        BASE,
        PAGES,
        "fpu-allumage",
        "",
        &format!(
            r#"console.log("fcw " + vm.globals[{control}].value);
console.log("fsw " + vm.globals[{status}].value);"#,
            control = FPU_CONTROL_SLOT,
            status = FPU_STATUS_SLOT,
        ),
    );
    assert_eq!(
        line_of(&text, "fcw "),
        FPU_CONTROL_POWER_ON.to_string(),
        "le mot de contrôle avant toute initialisation vaut 0x0040, pas zéro \
         et pas 0x037f : {text}"
    );
    assert_eq!(
        line_of(&text, "fsw "),
        "0",
        "le mot d'état, lui, sort bien de RESET à zéro : {text}"
    );
}

/// **L'hôte va chercher les octets d'une région là où la machine les lirait.**
///
/// C'est la tranche #254, et c'est le défaut que la tranche P2 avait **écrit**
/// plutôt que corrigé : « la lecture des **instructions** n'est pas paginée :
/// l'hôte résout une région par son adresse telle quelle, donc RIP est traité
/// comme physique ». Le dépôt garantissait donc, par un commentaire, que la
/// moitié « chercher le code » du couple resterait manquante — la même forme
/// que #253.
///
/// **Deux réponses à la même question, et elles ne s'accordent pas.** Le
/// module traduit ses accès mémoire par la marche à quatre niveaux ;
/// `web/host.js` allait chercher les octets à `adresse & (RAM - 1)`. Les deux
/// ne tombent juste ensemble que parce que le noyau est chargé bas dans une
/// RAM dont la taille divise l'écart entre ses deux formes d'adresse —
/// `Module::fold` le dit déjà. Dès que la cartographie n'est plus celle-là —
/// l'espace utilisateur, une cartographie temporaire, un noyau ailleurs — le
/// repli nomme **autre chose**.
///
/// **Mesuré sur le vrai noyau, pas supposé.** Au moment où Alpine saute dans
/// `/init` à `0x401000`, le repli désigne le physique `0x401000`, où les 4096
/// octets sont **tous nuls** : l'hôte aurait traduit quatre kibioctets de
/// `add %al,(%rax)` et la machine serait partie en morceaux loin de la cause.
///
/// **Ce programme pose deux leurres, et chacun attrape un sabotage
/// différent :**
///
/// | leurre | où | ce qu'il attrape |
/// | --- | --- | --- |
/// | `mov $9,%edx` | au **repli** de l'adresse virtuelle | un hôte qui replie au lieu de marcher |
/// | `mov $8,%ecx` | à la trame **physiquement suivante** | un hôte qui marche une fois puis lit tout droit |
///
/// Le second n'est pas décoratif : la fenêtre commence à `0xF00` d'une page et
/// **traverse** la frontière. Les deux pages virtuelles sont contiguës ; leurs
/// trames ne le sont pas. Un hôte qui marche pour la première et continue dans
/// la mémoire linéaire lirait le leurre.
///
/// **Et une seconde région dont la fenêtre butte sur une page absente**, parce
/// qu'un sabotage a survécu sans elle : la marche pose le témoin de faute et
/// CR2 quand une entrée manque, et l'hôte doit les rendre tels qu'il les a
/// trouvés. Tant qu'aucune lecture ne fautait, l'assertion sur le témoin était
/// vide — elle ne pouvait qu'être vraie. Ici la seconde page de la seconde
/// région **manque** : la fenêtre s'arrête court, le programme tient dans ce
/// qui reste, et l'invité ne doit pas hériter d'une faute que l'hôte a causée
/// en lisant.
#[test]
fn the_host_reads_the_code_through_the_page_tables_and_not_by_folding() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    // Quatre mébioctets, une puissance de deux, que le confinement exige.
    const PAGES: u32 = 64;
    const ENTRY: u64 = 0x1_0000;
    const PML4: u64 = 0x2_0000;
    const PDPT: u64 = 0x2_1000;
    const PD: u64 = 0x2_2000;
    const PT: u64 = 0x2_3000;
    /// La trame de la première page virtuelle de la région.
    const FRAME_ONE: u64 = 0x3_0000;
    /// Celle qui la suit **physiquement**, et que rien ne cartographie : le
    /// leurre de la lecture tout droit.
    const FRAME_NEXT: u64 = 0x3_1000;
    /// La trame de la **seconde** page virtuelle, ailleurs.
    const FRAME_TWO: u64 = 0x4_0000;
    /// La trame de la seconde région, dont la page **suivante** manque.
    const FRAME_THREE: u64 = 0x5_0000;
    /// L'adresse virtuelle de la région, à `0xF00` dans sa page : la fenêtre
    /// de 4096 octets que l'hôte lit traverse donc la frontière de page.
    const VA: u64 = 0xFFFF_8000_0030_0F00;
    /// Là où le repli par le masque de la RAM enverrait `VA`.
    const FOLDED: u64 = VA & (PAGES as u64 * 65536 - 1);
    /// La seconde région, elle aussi à `0xF00` dans sa page : sa fenêtre de
    /// 4096 octets réclame la page suivante, que rien ne cartographie.
    const VA_SHORT: u64 = 0xFFFF_8000_0030_2F00;
    const FOLDED_SHORT: u64 = VA_SHORT & (PAGES as u64 * 65536 - 1);

    // **La région d'entrée**, pagination éteinte : elle charge CR3, allume
    // CR0.PG, puis saute à l'adresse virtuelle.
    let mut entry: Vec<u8> = Vec::new();
    entry.extend_from_slice(&[0x48, 0xb8]); // movabs $PML4,%rax
    entry.extend_from_slice(&PML4.to_le_bytes());
    entry.extend_from_slice(&[0x0f, 0x22, 0xd8]); // mov %rax,%cr3
    entry.extend_from_slice(&[0x48, 0xb8]); // movabs $PG,%rax
    entry.extend_from_slice(&(1u64 << 31).to_le_bytes());
    entry.extend_from_slice(&[0x0f, 0x22, 0xc0]); // mov %rax,%cr0
    entry.extend_from_slice(&[0x48, 0xb8]); // movabs $VA,%rax
    entry.extend_from_slice(&VA.to_le_bytes());
    entry.extend_from_slice(&[0xff, 0xe0]); // jmp *%rax

    // **La vraie région**, coupée en deux par la frontière de page. Les 256
    // octets du haut de la première page portent le témoin et de quoi remplir
    // jusqu'au bord ; la suite vit dans l'autre trame.
    let mut first = vec![0x90u8; 0x100];
    first[0..5].copy_from_slice(&[0xba, 0x01, 0x00, 0x00, 0x00]); // mov $1,%edx
    let mut second: Vec<u8> = Vec::new();
    second.extend_from_slice(&[0xb9, 0x02, 0x00, 0x00, 0x00]); // mov $2,%ecx
    second.extend_from_slice(&[0x48, 0xb8]); // movabs $VA_SHORT,%rax
    second.extend_from_slice(&VA_SHORT.to_le_bytes());
    second.extend_from_slice(&[0xff, 0xe0]); // jmp *%rax
                                             // **La seconde région**, qui tient dans les 256 octets que sa page laisse.
    let short = [
        0xbb, 0x03, 0x00, 0x00, 0x00, // mov $3,%ebx
        0x0f, 0x0b, // ud2 : rendre la main
    ];
    // Les deux leurres, chacun avec un témoin qui ne peut venir que de lui.
    let decoy_folded = [
        0xba, 0x09, 0x00, 0x00, 0x00, // mov $9,%edx
        0xb9, 0x09, 0x00, 0x00, 0x00, // mov $9,%ecx
        0x0f, 0x0b, // ud2
    ];
    let decoy_next = [
        0xb9, 0x08, 0x00, 0x00, 0x00, // mov $8,%ecx
        0x0f, 0x0b, // ud2
    ];
    let decoy_short = [
        0xbb, 0x09, 0x00, 0x00, 0x00, // mov $9,%ebx
        0x0f, 0x0b, // ud2
    ];

    let scratch = std::env::temp_dir().join(format!("wisq-fetch-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let place = |name: &str, bytes: &[u8]| {
        let path = scratch.join(name);
        std::fs::write(&path, bytes).expect("un morceau de mémoire");
        path
    };
    let entry_path = place("entree.bin", &entry);
    let first_path = place("premiere.bin", &first);
    let second_path = place("seconde.bin", &second);
    let folded_path = place("leurre-repli.bin", &decoy_folded);
    let next_path = place("leurre-suite.bin", &decoy_next);
    let short_path = place("courte.bin", &short);
    let decoy_short_path = place("leurre-courte.bin", &decoy_short);

    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";

const vm = machine({{
  // **Le vrai chemin, de bout en bout** : l'hôte lit la fenêtre dans la
  // mémoire de l'invité, l'émetteur traduit *ces* octets. Rien n'est préparé
  // d'avance par ce test, et c'est tout l'intérêt — un module pré-construit
  // ne dirait rien de l'endroit où les octets ont été pris.
  translate: (address, slot, code) => {{
    const out = Bun.spawnSync({{
      cmd: [{translator:?}, String({pages}), address.toString(), String(slot)],
      stdin: code,
    }});
    if (out.exitCode !== 0) {{
      console.log("refusée 0x" + address.toString(16) + " "
        + out.stderr.toString().trim());
      return null;
    }}
    return out.stdout;
  }},
  pages: {pages},
}});
for (const [chemin, at] of [
  [{entry_path:?}, {entry_at}],
  [{first_path:?}, {first_at}],
  [{second_path:?}, {second_at}],
  [{folded_path:?}, {folded_at}],
  [{next_path:?}, {next_at}],
  [{short_path:?}, {short_at}],
  [{decoy_short_path:?}, {decoy_short_at}],
]) {{
  new Uint8Array(vm.memory.buffer).set(readFileSync(chemin), at);
}}
// Les tables, posées à la main : deux pages virtuelles contiguës, deux trames
// qui ne le sont pas.
const vue = new DataView(vm.memory.buffer);
const present = 0x3n;
const idx = (va, shift) => Number((va >> BigInt(shift)) & 0x1ffn);
const va = {va}n;
vue.setBigUint64({pml4} + idx(va, 39) * 8, {pdpt}n | present, true);
vue.setBigUint64({pdpt} + idx(va, 30) * 8, {pd}n | present, true);
vue.setBigUint64({pd} + idx(va, 21) * 8, {pt}n | present, true);
vue.setBigUint64({pt} + idx(va, 12) * 8, {frame_one}n | present, true);
vue.setBigUint64({pt} + idx(va + 0x1000n, 12) * 8, {frame_two}n | present, true);
// La seconde région : sa page est là, celle d'après **ne l'est pas**.
vue.setBigUint64({pt} + idx({va_short}n, 12) * 8, {frame_three}n | present, true);
vm.globals[{rip}].value = {entry_at}n;
vm.globals[4].value = 0x8000n; // rsp, que rien n'utilise ici
const why = await vm.run({{ budget: 1n << 20n, rounds: 64 }});
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value);
console.log("arret " + why.stopped);
console.log("rdx " + lire(2).toString());
console.log("rcx " + lire(1).toString());
console.log("rbx " + lire(3).toString());
console.log("faute " + lire({fault}).toString());
console.log("cr2 0x" + lire({control} + 1).toString(16));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            translator = env!("CARGO_BIN_EXE_x86-translate"),
            pages = PAGES,
            entry_path = entry_path.to_string_lossy(),
            first_path = first_path.to_string_lossy(),
            second_path = second_path.to_string_lossy(),
            folded_path = folded_path.to_string_lossy(),
            next_path = next_path.to_string_lossy(),
            short_path = short_path.to_string_lossy(),
            decoy_short_path = decoy_short_path.to_string_lossy(),
            entry_at = ENTRY,
            first_at = FRAME_ONE + 0xF00,
            second_at = FRAME_TWO,
            folded_at = FOLDED,
            next_at = FRAME_NEXT,
            short_at = FRAME_THREE + 0xF00,
            decoy_short_at = FOLDED_SHORT,
            pml4 = PML4,
            pdpt = PDPT,
            pd = PD,
            pt = PT,
            frame_one = FRAME_ONE,
            frame_two = FRAME_TWO,
            frame_three = FRAME_THREE,
            va = VA,
            va_short = VA_SHORT,
            rip = RIP_SLOT,
            fault = FAULT_SLOT,
            control = CONTROL_SLOT,
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
        output.status.success(),
        "le pilote a échoué :\n{errors}\n{text}"
    );
    let line = |name: &str| line_of(&text, name);
    assert_eq!(
        line("rdx "),
        "1",
        "**la première page vient de sa trame, pas du repli** : `9` voudrait \
         dire que l'hôte est allé chercher les octets à `adresse & (RAM - 1)`, \
         où ce test a posé un leurre : {text}"
    );
    assert_eq!(
        line("rcx "),
        "2",
        "**la seconde page vient de sa trame à elle** : `8` voudrait dire que \
         l'hôte a marché pour la première page puis lu tout droit dans la \
         mémoire linéaire, où ce test a posé l'autre leurre : {text}"
    );
    assert_eq!(
        line("rbx "),
        "3",
        "**la seconde région a tourné bien que sa fenêtre soit courte** : sa \
         seconde page manque, la lecture de l'hôte s'arrête là, et les 256 \
         octets qui restent suffisent. `9` voudrait dire le repli, `0` que la \
         région n'a pas tourné du tout : {text}"
    );
    assert_eq!(
        line("arret "),
        "une instruction indéfinie (ud2) sans porte : aucune IDT ne porte le vecteur 6",
        "et la machine finit sur le `ud2` de la seconde région : {text}"
    );
    // **La lecture de l'hôte ne laisse aucune trace.** La marche pose le
    // témoin de faute et CR2 quand une entrée manque ; si l'hôte ne les
    // rendait pas tels qu'il les a trouvés, l'invité prendrait plus tard une
    // faute qu'il n'a pas causée — et rien ici ne la relierait à cette
    // lecture-là.
    assert_eq!(
        line("faute "),
        "0",
        "le témoin de faute est intact après les lectures de l'hôte : {text}"
    );
    assert_eq!(line("cr2 "), "0x0", "et CR2 aussi : {text}");

    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Une adresse que les tables ne cartographient pas s'arrête en le disant.**
///
/// C'est l'autre moitié de #254, et c'est ce qui empêche la correction d'être
/// complaisante. Sans elle, l'hôte n'a que deux réponses possibles à « donne-
/// moi les octets de cette adresse » : des octets, ou le repli — et le repli
/// rend **toujours** quelque chose, parce que toute la RAM est lisible. Quatre
/// kibioctets de zéros se décodent en `add %al,(%rax)` répété : la machine
/// partirait en morceaux très loin de la cause.
///
/// C'est exactement ce qui attendait au mur mesuré : au saut dans `/init`, le
/// repli désignait 4096 octets tous nuls.
///
/// **Le nom est l'intérêt.** « refusée » dit que l'émetteur n'a pas su lire un
/// octet ; « aucune page derrière l'adresse » dit que la machine demande du
/// code là où son propre espace d'adressage ne met rien. Les deux se
/// corrigent à des kilomètres l'un de l'autre.
#[test]
fn an_address_the_page_tables_do_not_map_is_named_rather_than_folded() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 64;
    const ENTRY: u64 = 0x1_0000;
    const PML4: u64 = 0x2_0000;
    /// **Aucune entrée de PML4 n'est posée** : la marche échoue au premier
    /// niveau, comme elle le fait sur le vrai noyau à `0x401000`.
    const VA: u64 = 0x40_1000;
    /// Et au repli de cette adresse, un programme parfaitement valide — celui
    /// que l'hôte exécuterait s'il repliait. Le témoin est ce qu'il **n'a pas
    /// fait**.
    const FOLDED: u64 = VA & (PAGES as u64 * 65536 - 1);

    let mut entry: Vec<u8> = Vec::new();
    entry.extend_from_slice(&[0x48, 0xb8]); // movabs $PML4,%rax
    entry.extend_from_slice(&PML4.to_le_bytes());
    entry.extend_from_slice(&[0x0f, 0x22, 0xd8]); // mov %rax,%cr3
    entry.extend_from_slice(&[0x48, 0xb8]); // movabs $PG,%rax
    entry.extend_from_slice(&(1u64 << 31).to_le_bytes());
    entry.extend_from_slice(&[0x0f, 0x22, 0xc0]); // mov %rax,%cr0
    entry.extend_from_slice(&[0x48, 0xb8]); // movabs $VA,%rax
    entry.extend_from_slice(&VA.to_le_bytes());
    entry.extend_from_slice(&[0xff, 0xe0]); // jmp *%rax
    let decoy = [
        0xba, 0x07, 0x00, 0x00, 0x00, // mov $7,%edx
        0x0f, 0x0b, // ud2
    ];

    let scratch = std::env::temp_dir().join(format!("wisq-absente-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let entry_path = scratch.join("entree.bin");
    std::fs::write(&entry_path, &entry).expect("l'entrée");
    let decoy_path = scratch.join("leurre.bin");
    std::fs::write(&decoy_path, decoy).expect("le leurre");

    let driver = scratch.join("d.mjs");
    std::fs::write(
        &driver,
        format!(
            r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";

const vm = machine({{
  translate: (address, slot, code) => {{
    const out = Bun.spawnSync({{
      cmd: [{translator:?}, String({pages}), address.toString(), String(slot)],
      stdin: code,
    }});
    if (out.exitCode !== 0) return null;
    return out.stdout;
  }},
  pages: {pages},
}});
for (const [chemin, at] of [
  [{entry_path:?}, {entry_at}],
  [{decoy_path:?}, {decoy_at}],
]) {{
  new Uint8Array(vm.memory.buffer).set(readFileSync(chemin), at);
}}
vm.globals[{rip}].value = {entry_at}n;
vm.globals[4].value = 0x8000n;
vm.globals[2].value = 0n; // rdx : le témoin du leurre
const why = await vm.run({{ budget: 1n << 20n, rounds: 64 }});
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value);
console.log("arret " + why.stopped);
console.log("ou 0x" + BigInt.asUintN(64, why.at).toString(16));
console.log("rdx " + lire(2).toString());
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            translator = env!("CARGO_BIN_EXE_x86-translate"),
            pages = PAGES,
            entry_path = entry_path.to_string_lossy(),
            decoy_path = decoy_path.to_string_lossy(),
            entry_at = ENTRY,
            decoy_at = FOLDED,
            rip = RIP_SLOT,
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
        output.status.success(),
        "le pilote a échoué :\n{errors}\n{text}"
    );
    let line = |name: &str| line_of(&text, name);
    // **Le nom a changé à #258, et il en dit plus.** Tant que rien ne
    // délivrait, l'arrêt était « aucune page derrière l'adresse » : l'hôte
    // constatait qu'il ne savait pas lire et s'arrêtait là. Depuis, il
    // **faute** — et ce montage n'a pas d'IDT, donc c'est la délivrance qui
    // n'aboutit pas, en le disant. Ce que le test tient n'a pas bougé : la
    // page absente est nommée, ce n'est ni « refusée » ni un module traduit
    // depuis des zéros.
    assert_eq!(
        line("arret "),
        "une faute de page sur un chargement d'instruction sans porte : \
         aucune IDT ne porte le vecteur 14",
        "l'arrêt **nomme** ce qui manque, et ce n'est ni « refusée » ni un \
         module traduit depuis des zéros : {text}"
    );
    assert_eq!(
        line("ou "),
        format!("0x{VA:x}"),
        "et il dit à quelle adresse : {text}"
    );
    assert_eq!(
        line("rdx "),
        "0",
        "le leurre posé au repli n'a pas tourné : {text}"
    );

    let _ = std::fs::remove_dir_all(&scratch);
}

/// **`verw` tourne, lit son opérande, et ne touche à aucun drapeau.**
///
/// Le mur mesuré à #254 : `0f 00 2d d6 e6 ff ff`, `verw -0x192a(%rip)`, à
/// `0xffffffff81c01963`, sur le chemin du retour vers l'espace utilisateur.
/// Dans le **fichier** ELF, aux mêmes sept octets, sept `nop` — c'est un site
/// d'`alternative` que le noyau corrige au démarrage (la parade MDS), et
/// l'ancien instrument, qui lisait le fichier, passait outre sans un mot.
///
/// **Ce que ce test tient sur l'émetteur, et ce qu'un sabotage ferait
/// tomber :**
///
/// | | ce qui casse sans ça |
/// | --- | --- |
/// | la région se traduit et va jusqu'au bout | l'émetteur refusait tout le retour vers l'anneau trois |
/// | RBX, écrit **après** le `verw`, porte son témoin | une région traduite qui ne s'exécute pas ressemblerait à un succès |
/// | les drapeaux sont **intacts** | un ZF inventé serait une valeur plausible et fausse |
/// | l'opérande est **lu** | c'est la seule chose observable de l'instruction ici, et elle fait fauter une page absente |
///
/// **La troisième ligne est l'infidélité assumée de la tranche.** Sur du
/// silicium, `verw $__KERNEL_DS` rendrait ZF à un ; rien ici ne lit la GDT, et
/// inventer la valeur serait inventer un descripteur. Mesuré sans conséquence
/// sur le seul chemin où ce noyau l'exécute : après le `verw` viennent `eb 20`,
/// un saut **inconditionnel**, puis `add $8,%rsp`, un saut, et `iretq`, qui
/// recharge RFLAGS depuis la pile.
///
/// **Et elle est éprouvée dans les deux sens, parce qu'un sabotage a survécu
/// au premier essai.** Le test partait d'un état où *tous* les drapeaux
/// inscriptibles étaient posés, ZF compris : un émetteur qui *ajoutait* ZF —
/// exactement la valeur du silicium — n'y changeait rien, et l'assertion ne
/// pouvait pas échouer. Deux exécutions donc, une avec ZF posé et une sans :
/// la première attrape un ZF effacé, la seconde un ZF inventé. C'est la même
/// leçon que le sabotage S4 de #254, une tranche plus tôt, et elle est
/// arrivée deux fois de suite.
#[test]
fn verw_runs_reads_its_operand_and_leaves_every_flag_alone() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 1;
    const BASE: u64 = 0x1_0000;
    /// Où vit le sélecteur. `__KERNEL_DS` y sera posé, comme le noyau le fait
    /// dans `mds_verw_sel`.
    const SELECTOR_AT: u32 = 0x2000;
    for (before, sens) in [
        (
            ALWAYS_ONE | WRITABLE_FLAGS,
            "ZF posé au départ : un ZF effacé se verrait",
        ),
        (
            ALWAYS_ONE | (WRITABLE_FLAGS & !ZF),
            "ZF absent au départ : un ZF inventé se verrait",
        ),
    ] {
        let text = drive_with(
            &bun,
            &[
                0x0f, 0x00, 0x28, // verw (%rax)
                0x48, 0xc7, 0xc3, 0x07, 0x00, 0x00,
                0x00, // mov $7,%rbx — le témoin d'après
                0x0f, 0x0b, // ud2
            ],
            BASE,
            PAGES,
            "verw",
            &format!(
                r#"vm.globals[0].value = {at}n;
new DataView(vm.memory.buffer).setUint16({at}, 0x0018, true); // __KERNEL_DS
vm.globals[{flags}].value = {before}n;"#,
                at = SELECTOR_AT,
                flags = RFLAGS_SLOT,
                before = before,
            ),
            &format!(
                r#"console.log("flags " + BigInt.asUintN(64, vm.globals[{flags}].value).toString(16));
console.log("selecteur " + new DataView(vm.memory.buffer).getUint16({at}, true).toString(16));"#,
                flags = RFLAGS_SLOT,
                at = SELECTOR_AT,
            ),
        );
        assert_eq!(
            line_of(&text, "rbx "),
            "7",
            "**la région tourne jusqu'au bout** : le témoin posé après le \
             `verw` est là, donc l'instruction n'a ni refusé la région ni rendu \
             la main ({sens}) : {text}"
        );
        assert_eq!(
            line_of(&text, "flags "),
            format!("{before:x}"),
            "**aucun drapeau ne bouge**, ZF compris : cette machine ne \
             consulte aucun descripteur, donc elle ne peut pas le calculer, et \
             en inventer un serait inventer un descripteur ({sens}) : {text}"
        );
        assert_eq!(
            line_of(&text, "selecteur "),
            "18",
            "et le sélecteur n'est pas écrasé : `verw` le lit, elle ne l'écrit \
             pas ({sens}) : {text}"
        );
    }
}

/// **`verw` sur une page absente faute, et le témoin d'après ne tourne pas.**
///
/// C'est l'assertion qui rend la lecture de l'opérande **observable**, et sans
/// elle un sabotage survit : le test frère vérifie que la région tourne, que
/// les drapeaux ne bougent pas et que le sélecteur n'est pas écrasé — un
/// émetteur qui ne lirait rien du tout passerait les trois. Or la lecture est
/// tout ce que l'instruction fait ici, et c'est elle que le manuel assortit
/// d'une faute d'accès, contrairement à `clflush`.
///
/// La même leçon que le sabotage S4 de #254, une tranche plus tôt : **une
/// assertion qui ne peut pas échouer n'est pas une garde.**
#[test]
fn a_verw_whose_operand_page_is_absent_faults_before_the_next_instruction() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    const PAGES: u32 = 64;
    const BASE: u64 = 0x1_0000;
    const PML4: u64 = 0x2_0000;
    const PDPT: u64 = 0x2_1000;
    const PD: u64 = 0x2_2000;
    const PT: u64 = 0x2_3000;
    /// **Aucune entrée de feuille n'est posée** : la marche échoue au dernier
    /// niveau, et l'opérande n'a pas de page derrière lui.
    const VA: u64 = 0xFFFF_8000_0020_0000;

    let mut program: Vec<u8> = Vec::new();
    let mut push = |bytes: &[u8]| program.extend_from_slice(bytes);
    push(&[0x48, 0xb8]); // movabs $PML4,%rax
    push(&PML4.to_le_bytes());
    push(&[0x0f, 0x22, 0xd8]); // mov %rax,%cr3
    push(&[0x48, 0xb8]); // movabs $PG,%rax
    push(&(1u64 << 31).to_le_bytes());
    push(&[0x0f, 0x22, 0xc0]); // mov %rax,%cr0
    push(&[0x48, 0xb8]); // movabs $VA,%rax
    push(&VA.to_le_bytes());
    push(&[0x0f, 0x00, 0x28]); // verw (%rax)
                               // **Le témoin est après**, et il ne doit pas être atteint : une faute
                               // d'accès laisse RIP sur l'instruction qui l'a causée.
    push(&[0x48, 0xc7, 0xc3, 0x07, 0x00, 0x00, 0x00]); // mov $7,%rbx
    push(&[0x0f, 0x0b]); // ud2

    let scratch = std::env::temp_dir().join(format!("wisq-verw-pg-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    let module =
        Module::resolving(&program, BASE, 0, 0, PAGES).expect("une région paginée se traduit");
    let path = scratch.join("verw.wasm");
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
const vue = new DataView(vm.memory.buffer);
const present = 0x3n;
const idx = (va, shift) => Number((BigInt(va) >> BigInt(shift)) & 0x1ffn);
vue.setBigUint64({pml4} + idx({va}n, 39) * 8, {pdpt}n | present, true);
vue.setBigUint64({pdpt} + idx({va}n, 30) * 8, {pd}n | present, true);
vue.setBigUint64({pd} + idx({va}n, 21) * 8, {pt}n | present, true);
// **Et rien dans la table de feuilles** : l'opérande n'a pas de page.
vm.globals[{rip}].value = {base}n;
vm.globals[3].value = 0n; // rbx : le témoin d'après
const why = await vm.run({{ budget: 256n, rounds: 8 }});
console.log("arret " + why.stopped);
console.log("rbx " + BigInt.asUintN(64, vm.globals[3].value).toString());
console.log("cr2 0x" + BigInt.asUintN(64, vm.globals[{control} + 1].value).toString(16));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            path = path.to_string_lossy(),
            pages = PAGES,
            rip = RIP_SLOT,
            base = BASE,
            control = CONTROL_SLOT,
            pml4 = PML4,
            pdpt = PDPT,
            pd = PD,
            pt = PT,
            va = VA,
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
        output.status.success(),
        "le pilote a échoué :\n{errors}\n{text}"
    );
    assert_eq!(
        line_of(&text, "arret "),
        "une faute de page sans porte : aucune IDT ne porte le vecteur 14",
        "**l'opérande est lu pour de vrai** : sa page manque, donc la machine \
         faute. Un émetteur qui n'émettrait aucune lecture passerait outre \
         sans un mot : {text}"
    );
    assert_eq!(
        line_of(&text, "rbx "),
        "0",
        "et le témoin d'après n'a pas tourné : la faute laisse RIP sur le \
         `verw` : {text}"
    );
    assert_eq!(
        line_of(&text, "cr2 "),
        format!("0x{VA:x}"),
        "CR2 porte l'adresse de l'opérande, pas une autre : {text}"
    );

    let _ = std::fs::remove_dir_all(&scratch);
}

// **Le montage du segment de tâche**, partagé par les trois tests de #257.
//
// Il reprend le plan mémoire de #194 — l'identité sur les quatre premiers
// mébioctets, et une adresse haute dont les trois niveaux sont posés mais pas
// la feuille — et y ajoute deux pages : la GDT et le TSS.
//
// **Le pilote pose l'anneau plutôt que de le rejouer.** #256 a mesuré qu'au
// saut dans `/init` l'`iretq` charge bien `CS = 0x33` et `SS = 0x2b` ; ce qui
// est éprouvé ici est la **délivrance**, pas le chemin qui y mène, donc le
// pilote écrit les deux sélecteurs et la pagination avant de lancer.
/// La GDT, une page libre du plan de #194, identité oblige : sa base est une
/// globale, pas un descripteur empaqueté.
const TSS_GDT: u64 = 0x1_4000;
/// **Le TSS vit derrière les tables, et son adresse n'est pas un choix de
/// confort.** Une base de descripteur s'écrit en quatre morceaux dispersés ;
/// posée bas, ses octets 31:24 et 63:32 seraient nuls, et un émetteur qui les
/// oublierait passerait le test. Celle-ci les porte : 0xab pour les bits
/// 39:32, 0x82 pour les bits 31:24, 0x015000 pour le reste. Elle oblige du même
/// coup la lecture du TSS à passer par les tables, comme la vraie.
const TSS_AT: u64 = 0x0000_00ab_8201_5000;
/// La trame où cette page virtuelle atterrit — c'est là que le pilote écrit,
/// parce qu'il écrit dans la mémoire linéaire et non par les tables.
const TSS_FRAME: u64 = 0x2_c000;
/// Les trois niveaux qui portent `TSS_AT`, et sa feuille.
const TSS_PDPT: u64 = 0x2_6000;
const TSS_PD: u64 = 0x2_7000;
const TSS_PT: u64 = 0x2_b000;
/// La pile du **programme**, celle qu'il faut retrouver dans le cadre.
const TSS_OLD_STACK: u64 = 0x2_8000;
/// Celle du **noyau**, que `RSP0` nomme.
const TSS_KERNEL_STACK: u64 = 0x2_9000;
/// Et celle qu'une porte à pile d'interruption impose, `IST1`.
const TSS_IST_STACK: u64 = 0x2_a000;
/// Le sélecteur de TSS que Linux charge : `GDT_ENTRY_TSS * 8`.
const TSS_SELECTOR: u64 = 0x40;
/// Les deux sélecteurs d'anneau trois de Linux, `__USER_CS` et `__USER_DS`.
const TSS_USER_CODE: u64 = 0x33;
const TSS_USER_STACK_SELECTOR: u64 = 0x2b;
/// Et ceux d'anneau zéro, `__KERNEL_CS` et `__KERNEL_DS`.
const TSS_KERNEL_CODE: u64 = 0x10;
const TSS_KERNEL_STACK_SELECTOR: u64 = 0x18;
/// La limite du TSS de Linux, `sizeof(struct x86_hw_tss) - 1`. Elle couvre la
/// fin d'`IST7`, à 0x5b — un TSS plus court doit être refusé.
const TSS_LIMIT: u64 = 0x67;
const TSS_WITNESS: u64 = 0x0FED_BEEF_1234_5678;
/// Ce que le témoin d'après la faute écrirait s'il tournait.
const TSS_AFTER: u32 = 9;

/// **Le programme qui faute, et l'adresse de sa faute.** Il lit une adresse
/// dont la feuille n'est pas posée ; le témoin d'après ne doit pas tourner.
fn tss_program(fetch: bool) -> (Vec<u8>, u64) {
    let mut program: Vec<u8> = Vec::new();
    if fetch {
        // **Le saut indirect, parce qu'un `jmp` direct ne porte pas si loin.**
        // `RIG_ABSENT` est à plus de deux gibioctets d'ici ; un `rel32` ne l'
        // atteint pas. L'indirect rend la main à l'hôte avec RIP **sur** la
        // cible, ce que #199 a posé — et c'est le chargement d'instruction
        // dont la page manque.
        program.extend_from_slice(&[0x48, 0xb8]); // movabs $ABSENT,%rax
        program.extend_from_slice(&RIG_ABSENT.to_le_bytes());
        program.extend_from_slice(&[0xff, 0xe0]); // jmp *%rax
                                                  // Ce qui suit n'est jamais atteint — mais il faut de quoi finir la
                                                  // région, sinon l'émetteur n'a pas de terminateur.
        program.extend_from_slice(&[0x0f, 0x0b]); // ud2
                                                  // L'adresse fautive **est** la cible, et pas une adresse de ce bloc.
        return (program, RIG_ABSENT);
    }
    program.extend_from_slice(&[0x48, 0xbe]); // movabs $ABSENT,%rsi
    program.extend_from_slice(&RIG_ABSENT.to_le_bytes());
    let faults_at = RIG_BASE + program.len() as u64;
    program.extend_from_slice(&[0x48, 0x8b, 0x16]); // mov (%rsi),%rdx — la faute
    program.extend_from_slice(&[0x48, 0xc7, 0xc2]); // mov $AFTER,%rdx
    program.extend_from_slice(&TSS_AFTER.to_le_bytes());
    program.extend_from_slice(&[0x0f, 0x0b]); // ud2
    (program, faults_at)
}

/// Le pilote commun. `code` et `stack` sont les sélecteurs posés avant de
/// lancer, `ist` le champ de pile d'interruption de la porte, et `tweaks` du
/// JavaScript glissé juste avant `run` — c'est par là que les cinq refus
/// abîment une pièce du montage, et une seule.
fn tss_driver(
    scratch: &Path,
    code: u64,
    stack: u64,
    ist: u64,
    fetch: bool,
    chain: bool,
    tweaks: &str,
) -> PathBuf {
    let (program, _) = tss_program(fetch);
    let mut handler: Vec<u8> = Vec::new();
    if chain {
        // **Le gestionnaire qui refaute, et qui compte ses passages.** Il
        // n'installe rien : il saute sur une *seconde* page absente. Entre les
        // deux chargements fautifs, sa propre région s'est installée — donc le
        // compteur de double faute doit être retombé, et ce nombre de passages
        // est la seule chose qui le dise.
        handler.extend_from_slice(&[0x48, 0xff, 0xc3]); // incq %rbx
        handler.extend_from_slice(&[0x48, 0xb8]); // movabs $ABSENT_TOO,%rax
        handler.extend_from_slice(&RIG_ABSENT_TOO.to_le_bytes());
        handler.extend_from_slice(&[0xff, 0xe0]); // jmp *%rax
        handler.extend_from_slice(&[0x0f, 0x0b]); // ud2 — jamais atteint
    } else {
        // **Le gestionnaire, en anneau zéro.** Il pose son témoin et s'arrête :
        // ce qui est éprouvé est l'arrivée, pas le retour — #194 tient le
        // retour.
        handler.extend_from_slice(&[0x48, 0xbb]); // movabs $WITNESS,%rbx
        handler.extend_from_slice(&TSS_WITNESS.to_le_bytes());
        handler.extend_from_slice(&[0x0f, 0x0b]); // ud2
    }

    // **Les octets vivent en mémoire invitée, et la traduction est à la
    // demande.** Un module préconstruit porte son créneau **gravé**, et le
    // créneau dépend du nombre de blocs que la région précédente a posés : un
    // `jmp *%rax` en pose deux là où une lecture n'en pose qu'un. Le
    // gestionnaire était alors compilé pour l'emplacement 1 et installé au 2,
    // où il n'avait rien posé — « la région à 69632 n'a posé aucun bloc à
    // l'emplacement 2 ». Le protocole de #254 est ce qui tient ici : l'hôte
    // passe la fenêtre qu'il a lue **par les tables**, et `x86-translate`
    // traduit pour l'emplacement demandé, quel qu'il soit.
    let mut placed = String::new();
    for (name, bytes, at) in [
        ("programme.bin", &program[..], RIG_BASE),
        ("gestionnaire.bin", &handler[..], RIG_HANDLER),
    ] {
        let path = scratch.join(name);
        std::fs::write(&path, bytes).expect(name);
        placed.push_str(&format!(
            "new Uint8Array(vm.memory.buffer).set(readFileSync({:?}), {at});\n",
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
  translate: (address, slot, code) => {{
    const out = Bun.spawnSync({{
      cmd: [{translator:?}, String({pages}), address.toString(), String(slot)],
      stdin: code,
    }});
    if (out.exitCode !== 0) return null;
    return out.stdout;
  }},
  pages: {pages},
}});
{placed}const vue = new DataView(vm.memory.buffer);
const present = 0x3n;
const idx = (va, shift) => Number((BigInt(va) >> BigInt(shift)) & 0x1ffn);
// L'identité sur les quatre premiers mébioctets : le code, les tables, la GDT,
// le TSS et les trois piles y vivent.
vue.setBigUint64({pml4} + 0 * 8, {pdptLow}n | present, true);
vue.setBigUint64({pdptLow} + 0 * 8, {pdLow}n | present, true);
vue.setBigUint64({pdLow} + 0 * 8, 0n | present | 0x80n, true);
vue.setBigUint64({pdLow} + 1 * 8, 0x20_0000n | present | 0x80n, true);
// Les trois niveaux au-dessus de la page que le programme lira ; la feuille,
// non : c'est elle qui fait la faute.
vue.setBigUint64({pml4} + idx({absent}n, 39) * 8, {pdpt}n | present, true);
vue.setBigUint64({pdpt} + idx({absent}n, 30) * 8, {pd}n | present, true);
vue.setBigUint64({pd} + idx({absent}n, 21) * 8, {pt}n | present, true);
// Et les quatre niveaux du TSS, jusqu'à sa feuille : c'est la seule page de ce
// montage que l'identité ne couvre pas, et c'est exprès.
vue.setBigUint64({pml4} + idx({tss}n, 39) * 8, {tssPdpt}n | present, true);
vue.setBigUint64({tssPdpt} + idx({tss}n, 30) * 8, {tssPd}n | present, true);
vue.setBigUint64({tssPd} + idx({tss}n, 21) * 8, {tssPt}n | present, true);
vue.setBigUint64({tssPt} + idx({tss}n, 12) * 8, {tssFrame}n | present, true);

// **Le descripteur de tâche, seize octets en mode long**, avec sa base en
// quatre morceaux. Le type 9 est « TSS long disponible », ce que `ltr` laisse
// derrière lui ; 11 serait « occupé ».
const poser = (base, limite, type) => {{
  const bas = BigInt(limite)
    | ((BigInt(base) & 0xffffffn) << 16n)
    | (BigInt(type) << 40n)
    | (1n << 47n)
    | (((BigInt(base) >> 24n) & 0xffn) << 56n);
  vue.setBigUint64({gdt} + {selector}, bas, true);
  vue.setBigUint64({gdt} + {selector} + 8, BigInt(base) >> 32n, true);
}};
poser({tss}n, {tssLimit}, 9);
vm.globals[{table}].value = 0xffffn;       // limite de la GDT
vm.globals[{table} + 1].value = BigInt({gdt});

// **`RSP0` à l'offset quatre, `IST1` à 0x24** — ce n'est pas un choix, c'est
// le format du mode long.
vue.setBigUint64({tssFrame} + 4, BigInt({kernelStack}), true);
vue.setBigUint64({tssFrame} + 0x24, BigInt({istStack}), true);

// **L'IDT : une porte d'interruption pour le vecteur 14**, sélecteur d'anneau
// zéro. Le champ de pile d'interruption occupe les trois bits du bas de
// l'octet qui suit le sélecteur.
const porte = (offset) => {{
  const low = (BigInt(offset) & 0xffffn) | (BigInt({kernelCode}) << 16n)
    | (BigInt({ist}) << 32n) | (0x0en << 40n) | (1n << 47n)
    | ((BigInt(offset) & 0xffff0000n) << 32n);
  return [low, BigInt(offset) >> 32n];
}};
const [porteBas, porteHaut] = porte({handler});
vue.setBigUint64({idt} + 14 * 16, porteBas, true);
vue.setBigUint64({idt} + 14 * 16 + 8, porteHaut, true);
vm.globals[{table} + 2].value = 0xffffn;   // limite de l'IDT
vm.globals[{table} + 3].value = BigInt({idt});

// **Le registre de tâche**, comme `ltr` le laisse : seize bits, rien de plus.
vm.globals[{task}].value = BigInt({selector});

// La pagination, posée par le pilote : un programme d'anneau trois ne pourrait
// écrire ni CR0 ni CR3.
vm.globals[{control}].value = BigInt(1) << 31n;
vm.globals[{control} + 2].value = {pml4}n;

// L'anneau, posé plutôt que rejoué.
vm.globals[{segment} + 1].value = BigInt({code});
vm.globals[{segment} + 2].value = BigInt({stack});
vm.globals[4].value = BigInt({oldStack});
vm.globals[{rip}].value = {base}n;

{tweaks}
const why = await vm.run({{ budget: 256n, rounds: 16 }});
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value);
console.log("arret " + why.stopped);
console.log("rbx 0x" + lire(3).toString(16));
console.log("rdx " + lire(2).toString());
console.log("cs 0x" + (lire({segment} + 1) & 0xffffn).toString(16));
console.log("ss 0x" + (lire({segment} + 2) & 0xffffn).toString(16));
console.log("rsp 0x" + lire(4).toString(16));
console.log("cr2 0x" + lire({control} + 1).toString(16));
// **Le cadre lu depuis RSP**, et non depuis un sommet supposé : ce que le
// gestionnaire trouverait. De bas en haut c'est le code d'erreur, RIP, CS,
// RFLAGS, RSP, SS — l'ordre du manuel, et en oublier un décale tout.
const bas = Number(lire(4));
const cadre = [];
for (let i = 0; i < 6; i++) {{
  cadre.push("0x" + vue.getBigUint64(bas + i * 8, true).toString(16));
}}
console.log("cadre " + cadre.join(" "));
"#,
            host = workspace_root().join("web/host.js").to_string_lossy(),
            translator = env!("CARGO_BIN_EXE_x86-translate"),
            placed = placed,
            pages = RIG_PAGES,
            pml4 = RIG_PML4,
            pdpt = RIG_PDPT,
            pd = RIG_PD,
            pt = RIG_PT,
            pdptLow = RIG_PDPT_LOW,
            pdLow = RIG_PD_LOW,
            absent = RIG_ABSENT,
            gdt = TSS_GDT,
            tss = TSS_AT,
            tssFrame = TSS_FRAME,
            tssPdpt = TSS_PDPT,
            tssPd = TSS_PD,
            tssPt = TSS_PT,
            tssLimit = TSS_LIMIT,
            selector = TSS_SELECTOR,
            idt = RIG_IDT,
            handler = RIG_HANDLER,
            kernelCode = TSS_KERNEL_CODE,
            kernelStack = TSS_KERNEL_STACK,
            istStack = TSS_IST_STACK,
            oldStack = TSS_OLD_STACK,
            code = code,
            stack = stack,
            ist = ist,
            base = RIG_BASE,
            table = TABLE_SLOT,
            task = TASK_SLOT,
            control = CONTROL_SLOT,
            segment = SEGMENT_SLOT,
            rip = RIP_SLOT,
            tweaks = tweaks,
        ),
    )
    .expect("le pilote");
    driver
}

/// Un répertoire de travail neuf, nommé par le cas — cinq refus dans le même
/// répertoire se marcheraient dessus.
fn tss_scratch(what: &str) -> PathBuf {
    let scratch = std::env::temp_dir().join(format!("wisq-tss-{what}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    scratch
}

/// **Une faute prise en anneau trois atterrit sur la pile du noyau, lue dans
/// le segment d'état de tâche.**
///
/// C'est la tranche #257, et c'est le mur que #256 a nommé avec deux nombres :
/// au saut dans `/init`, `CS = 0x33` — anneau trois — et `TR = 0x40` — un
/// sélecteur de TSS **est** chargé. Or la délivrance refusait par son nom :
/// « un changement d'anneau à la délivrance, sans segment de tâche : cette
/// machine n'a pas de TSS », alors que la machine en a un. Le dépôt l'avait
/// écrit plutôt que corrigé, depuis #204 : « Aucun descripteur n'est lu
/// derrière ».
///
/// **L'oracle est le cœur Swift**, qui fait ça depuis #127 et dont les
/// commentaires portent les pièges déjà payés : le descripteur de seize octets
/// en mode long, la base en quatre morceaux, `RSP0` à l'offset 4, la limite qui
/// doit couvrir jusqu'à la fin d'`IST7`, et surtout — « **l'anneau change avant
/// les empilements, pas après** », parce que le cadre s'écrit sur une pile
/// interdite au programme.
///
/// **Ce que chaque assertion tient, et ce qu'un sabotage y ferait tomber :**
///
/// | assertion | ce qui casse sans elle |
/// | --- | --- |
/// | le gestionnaire a tourné | la machine s'arrêtait, et tout l'espace utilisateur avec |
/// | `RSP` est sur `RSP0`, pas sur la pile du programme | le noyau écrirait son cadre sur une pile que le programme peut lire et écrire |
/// | le cadre porte le **SS et le RSP du programme** | l'`iretq` ne saurait pas où rendre la main |
/// | `SS` devient **nul** | le processeur le fait en mode long ; le garder ferait croire au noyau qu'il vient d'où il venait |
/// | `CS` est celui de la porte | l'anneau doit changer **avant** les empilements |
#[test]
fn a_fault_taken_in_ring_three_lands_on_the_kernel_stack_from_the_task_segment() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    let (_, faults_at) = tss_program(false);
    let scratch = tss_scratch("anneau");
    let driver = tss_driver(
        &scratch,
        TSS_USER_CODE,
        TSS_USER_STACK_SELECTOR,
        0,
        false,
        false,
        "// rien à abîmer : c'est le montage sain.",
    );
    let text = run_driver(&bun, &driver);
    let line = |name: &str| line_of(&text, name);
    assert_eq!(
        line("rbx "),
        format!("0x{TSS_WITNESS:x}"),
        "**le gestionnaire a tourné** : la faute prise en anneau trois a été \
         délivrée au lieu d'arrêter la machine : {text}"
    );
    assert_eq!(
        line("arret "),
        UD2_PORTE_ABSENTE,
        "et l'arrêt final est le `ud2` du gestionnaire, pas la faute : {text}"
    );
    assert_eq!(
        line("rdx "),
        "0",
        "l'instruction d'après la faute n'a pas tourné : la faute laisse RIP \
         dessus : {text}"
    );
    assert_eq!(
        line("cs "),
        format!("0x{TSS_KERNEL_CODE:x}"),
        "CS est celui de la porte : l'anneau a changé : {text}"
    );
    assert_eq!(
        line("ss "),
        "0x0",
        "**SS est nul** : le processeur l'annule en mode long, et le garder \
         ferait croire au noyau qu'il vient d'où il venait : {text}"
    );
    // Cinq mots plus le code d'erreur, donc quarante-huit octets sous le
    // sommet aligné. C'est **la** case qui distingue les deux piles.
    assert_eq!(
        line("rsp "),
        format!("0x{:x}", (TSS_KERNEL_STACK & !0xf) - 48),
        "**le cadre est sur la pile du noyau**, celle que `RSP0` nomme, et pas \
         sur celle du programme : {text}"
    );
    let frame = line("cadre ");
    let words: Vec<&str> = frame.split(' ').collect();
    assert_eq!(
        words.len(),
        6,
        "le pilote doit rendre les six mots du cadre : {text}"
    );
    assert_eq!(
        words[1],
        format!("0x{faults_at:x}"),
        "le cadre porte l'adresse de l'instruction fautive, pas la suivante : \
         {text}"
    );
    assert_eq!(
        words[2],
        format!("0x{TSS_USER_CODE:x}"),
        "et le CS du programme, celui de l'anneau trois : {text}"
    );
    assert_eq!(
        words[4],
        format!("0x{TSS_OLD_STACK:x}"),
        "et son RSP, celui d'avant la faute : {text}"
    );
    assert_eq!(
        words[5],
        format!("0x{TSS_USER_STACK_SELECTOR:x}"),
        "**et son SS** — c'est de là que l'`iretq` rendra la main : {text}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Une porte à pile d'interruption prend sa pile dans `IST1`, même sans
/// changement d'anneau.**
///
/// C'est l'autre moitié du refus que #257 remplace : la délivrance disait
/// « une porte à pile d'interruption, sans segment de tâche » et s'arrêtait,
/// même quand le noyau était déjà en anneau zéro. Linux pose des IST sur la
/// double faute, le NMI et `#MC` dès `cpu_init_exception_handling` — celles-là
/// arriveront avant la première faute d'espace utilisateur.
///
/// **Les deux raisons de changer de pile ne se recouvrent pas**, et ce test
/// tient celle que l'autre ne tient pas : ici l'anneau ne bouge pas, et la
/// pile bouge quand même.
#[test]
fn an_interrupt_stack_gate_takes_its_stack_from_the_task_segment_without_changing_ring() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    let scratch = tss_scratch("ist");
    let driver = tss_driver(
        &scratch,
        TSS_KERNEL_CODE,
        TSS_KERNEL_STACK_SELECTOR,
        1,
        false,
        false,
        "// la porte nomme IST1 ; l'anneau, lui, ne bouge pas.",
    );
    let text = run_driver(&bun, &driver);
    let line = |name: &str| line_of(&text, name);
    assert_eq!(
        line("rbx "),
        format!("0x{TSS_WITNESS:x}"),
        "**le gestionnaire a tourné** : une porte à IST est délivrée au lieu \
         d'arrêter la machine : {text}"
    );
    assert_eq!(
        line("rsp "),
        format!("0x{:x}", (TSS_IST_STACK & !0xf) - 48),
        "**le cadre est sur `IST1`**, pas sur la pile courante ni sur `RSP0` : \
         un TSS lu au mauvais offset les confondrait : {text}"
    );
    assert_eq!(
        line("cs "),
        format!("0x{TSS_KERNEL_CODE:x}"),
        "l'anneau n'a pas bougé, et c'est exprès : {text}"
    );
    assert_eq!(
        line("ss "),
        "0x0",
        "SS est nul quand même : le processeur l'annule à tout changement de \
         pile, pas seulement à un changement d'anneau : {text}"
    );
    let words: Vec<String> = line("cadre ").split(' ').map(str::to_string).collect();
    assert_eq!(
        words[5],
        format!("0x{TSS_KERNEL_STACK_SELECTOR:x}"),
        "et le cadre porte le SS d'avant, celui du noyau : {text}"
    );
    assert_eq!(
        words[4],
        format!("0x{TSS_OLD_STACK:x}"),
        "et le RSP d'avant : {text}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Cinq façons d'avoir un segment de tâche qui ne vaut rien, et cinq refus
/// qui ne se ressemblent pas.**
///
/// Le prochain mur sera diagnostiqué depuis un relevé de noyau, pas depuis un
/// débogueur : « cette machine n'a pas de TSS » ne disait pas quoi corriger.
/// Un registre de tâche vide, un sélecteur hors de la GDT, un descripteur qui
/// n'est pas un TSS, un TSS trop court pour porter ses piles et un TSS dont la
/// base n'est pas cartographiée demandent cinq corrections différentes.
///
/// **Aucun n'écrit un cadre quelque part au hasard**, et c'est ce que le refus
/// achète : le témoin du gestionnaire reste à zéro dans les cinq cas.
#[test]
fn a_task_segment_that_cannot_carry_a_stack_is_refused_by_name() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    let cases: [(&str, String, String); 5] = [
        (
            "sans-tr",
            format!("vm.globals[{TASK_SLOT}].value = 0n;"),
            "une faute de page avec un changement de pile, et aucun registre de \
             tâche chargé : aucun `ltr` n'est passé"
                .to_string(),
        ),
        (
            "hors-gdt",
            format!("vm.globals[{TABLE_SLOT}].value = 0x3fn;"),
            format!(
                "une faute de page avec un changement de pile : le sélecteur de \
                 tâche 0x{TSS_SELECTOR:x} est hors de la GDT"
            ),
        ),
        (
            "mauvais-type",
            format!("poser({TSS_AT}n, {TSS_LIMIT}, 2);"),
            format!(
                "une faute de page avec un changement de pile : le descripteur \
                 0x{TSS_SELECTOR:x} n'est pas un segment de tâche"
            ),
        ),
        (
            "trop-court",
            format!("poser({TSS_AT}n, 0x3f, 9);"),
            "une faute de page avec un changement de pile : le segment de tâche \
             ne porte que 64 octets, il en faut 92"
                .to_string(),
        ),
        (
            "hors-carte",
            format!("poser({RIG_ABSENT}n, {TSS_LIMIT}, 9);"),
            "une faute pendant la délivrance d'une faute de page : le segment de \
             tâche n'est pas cartographié"
                .to_string(),
        ),
    ];
    for (name, tweak, expected) in cases {
        let scratch = tss_scratch(name);
        let driver = tss_driver(
            &scratch,
            TSS_USER_CODE,
            TSS_USER_STACK_SELECTOR,
            0,
            false,
            false,
            &tweak,
        );
        let text = run_driver(&bun, &driver);
        assert_eq!(
            line_of(&text, "arret "),
            expected,
            "le refus « {name} » doit nommer ce qui manque, et lui seul : {text}"
        );
        assert_eq!(
            line_of(&text, "rbx "),
            "0x0",
            "et « {name} » ne doit pas avoir délivré : un cadre écrit au hasard \
             est pire qu'un arrêt : {text}"
        );
        let _ = std::fs::remove_dir_all(&scratch);
    }
}

/// **Un chargement d'instruction dont la page manque est délivré au noyau, pas
/// nommé comme un arrêt.**
///
/// C'est la tranche #258, et c'est exactement ce que `/init` réclame. #257 a
/// mesuré la machine à `rip 0x401000` — le point d'entrée de `/init` — sur
/// « aucune page derrière l'adresse », en anneau trois, avec un TSS chargé. Le
/// texte d'un programme est cartographié **à la demande** : le noyau pose la
/// première page quand le processeur faute dessus. Ici personne ne fautait ;
/// l'hôte constatait qu'il ne savait pas lire les octets et s'arrêtait.
///
/// **La différence tient en une phrase :** `install` ne sait pas lire une page
/// absente, mais ce n'est pas une panne de l'hôte — c'est l'événement que le
/// noyau attend.
///
/// **Le cadre doit pointer sur la cible, pas sur le saut.** RIP empilé est
/// l'adresse qu'on n'a pas pu lire, sinon l'`iretq` du noyau rejouerait le
/// `jmp` — ce qui marcherait par accident ici et pas quand la cible arrive
/// d'un appel indirect.
#[test]
fn a_fetch_whose_page_is_absent_is_delivered_instead_of_stopping_the_machine() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    let scratch = tss_scratch("fetch");
    let driver = tss_driver(
        &scratch,
        TSS_USER_CODE,
        TSS_USER_STACK_SELECTOR,
        0,
        true,
        false,
        "// le programme saute sur la page absente : rien à abîmer.",
    );
    let text = run_driver(&bun, &driver);
    let line = |name: &str| line_of(&text, name);
    assert_eq!(
        line("rbx "),
        format!("0x{TSS_WITNESS:x}"),
        "**le gestionnaire a tourné** : la faute de chargement a été délivrée \
         au lieu d'arrêter la machine sur « aucune page derrière l'adresse » : \
         {text}"
    );
    assert_eq!(
        line("cr2 "),
        format!("0x{RIG_ABSENT:x}"),
        "CR2 porte l'adresse qu'on n'a pas pu lire : c'est là que le noyau \
         posera la page : {text}"
    );
    assert_eq!(
        line("rsp "),
        format!("0x{:x}", (TSS_KERNEL_STACK & !0xf) - 48),
        "et le cadre est sur la pile du noyau : une faute de chargement en \
         anneau trois passe par `RSP0` comme les autres : {text}"
    );
    let words: Vec<String> = line("cadre ").split(' ').map(str::to_string).collect();
    assert_eq!(
        words[1],
        format!("0x{RIG_ABSENT:x}"),
        "**le cadre pointe sur la cible, pas sur le saut** : c'est l'adresse \
         que l'`iretq` rejouera, et elle sera cartographiée : {text}"
    );
    assert_eq!(
        words[2],
        format!("0x{TSS_USER_CODE:x}"),
        "avec le CS du programme : {text}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Le code d'erreur d'une faute de page dit qui l'a demandée.**
///
/// Le bit 2 dit que l'accès vient de l'espace utilisateur, et c'est **le** bit
/// que Linux regarde pour trancher entre « une page manque à un programme, je
/// la lui pose » et « le noyau est parti dans le décor, j'affiche un oops ».
/// Le cœur Swift l'a payé une fois, au lot 7 : premier programme jamais lancé,
/// `Oops: 0010`, `Kernel panic - not syncing: Attempted to kill init!`. Le
/// journal le dit en une phrase — « le programme n'avait rien fait de mal, on
/// avait juste oublié de dire qu'il était le programme ».
///
/// `web/host.js` ne le posait pas : le module range « code d'erreur zéro, plus
/// un » et l'hôte soustrayait un. Zéro veut dire « une lecture du noyau sur une
/// page absente », ce qui était vrai tant qu'aucune faute d'anneau trois ne
/// pouvait être délivrée. Depuis #257 elles le peuvent.
///
/// **Le niveau vient des deux bits du bas de CS, et de rien d'autre.**
#[test]
fn a_page_fault_error_code_says_whether_the_access_came_from_user_space() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    // Une **lecture de donnée**, pas un chargement : le bit utilisateur ne
    // dépend pas de la nature de l'accès, et les deux chemins doivent le poser.
    for (name, code, stack, expected) in [
        (
            "anneau-trois",
            TSS_USER_CODE,
            TSS_USER_STACK_SELECTOR,
            0x4u64,
        ),
        (
            "anneau-zero",
            TSS_KERNEL_CODE,
            TSS_KERNEL_STACK_SELECTOR,
            0x0,
        ),
    ] {
        let scratch = tss_scratch(name);
        let driver = tss_driver(
            &scratch,
            code,
            stack,
            0,
            false,
            false,
            "// une lecture de donnée, et l'anneau est posé plus haut.",
        );
        let text = run_driver(&bun, &driver);
        assert_eq!(
            line_of(&text, "rbx "),
            format!("0x{TSS_WITNESS:x}"),
            "le gestionnaire doit avoir tourné pour que le cadre existe : {text}"
        );
        let words: Vec<String> = line_of(&text, "cadre ")
            .split(' ')
            .map(str::to_string)
            .collect();
        assert_eq!(
            words[0],
            format!("0x{expected:x}"),
            "**le code d'erreur de « {name} » doit porter le bit 2 selon \
             l'anneau**, et rien de plus : ni le bit de présence, ni celui \
             d'écriture, ni celui de chargement — cette machine n'arme ni NXE \
             ni SMEP : {text}"
        );
        let _ = std::fs::remove_dir_all(&scratch);
    }
}

/// **Le bit de chargement d'instruction n'apparaît que quand le processeur le
/// poserait.**
///
/// Le manuel est explicite : le bit 4 du code d'erreur « is reserved (set to 0)
/// if CR4.SMEP = 0 and either CR4.PAE = 0 or IA32_EFER.NXE = 0 ». Or cette
/// machine n'annonce pas NX — son propre noyau le dit au démarrage, « Notice:
/// NX (Execute Disable) protection missing in CPU! » — et n'applique pas SMEP.
/// Le poser toujours serait une infidélité **silencieuse** : un noyau qui
/// distingue les deux causes agirait sur un bit que le silicium ne lui aurait
/// pas donné.
///
/// **Ce qui est éprouvé ici est donc la condition, pas le bit.** Le même
/// chargement, deux fois : sans NXE il ne porte que l'anneau, avec NXE il
/// porte les deux. Un hôte qui poserait le bit inconditionnellement passerait
/// la seconde moitié et tomberait sur la première.
#[test]
fn the_instruction_bit_appears_only_where_the_processor_would_set_it() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    for (name, tweak, expected) in [
        (
            "sans-nxe",
            "// EFER reste tel que le module le pose : NXE éteint.".to_string(),
            0x4u64,
        ),
        (
            "avec-nxe",
            format!("vm.globals[{EFER_SLOT}].value |= 1n << 11n; // NXE, que le manuel exige"),
            0x14,
        ),
        (
            "avec-smep",
            format!(
                "vm.globals[{}].value |= 1n << 20n; // SMEP, l'autre moitié de la règle",
                CONTROL_SLOT + 3
            ),
            0x14,
        ),
    ] {
        let scratch = tss_scratch(name);
        let driver = tss_driver(
            &scratch,
            TSS_USER_CODE,
            TSS_USER_STACK_SELECTOR,
            0,
            true,
            false,
            &tweak,
        );
        let text = run_driver(&bun, &driver);
        assert_eq!(
            line_of(&text, "rbx "),
            format!("0x{TSS_WITNESS:x}"),
            "le gestionnaire doit avoir tourné pour que le cadre existe : {text}"
        );
        let words: Vec<String> = line_of(&text, "cadre ")
            .split(' ')
            .map(str::to_string)
            .collect();
        assert_eq!(
            words[0],
            format!("0x{expected:x}"),
            "« {name} » : le bit 4 suit la règle du manuel, il n'est pas posé \
             d'office : {text}"
        );
        let _ = std::fs::remove_dir_all(&scratch);
    }
}

/// **Un gestionnaire dont la page manque à son tour est nommé, pas bouclé.**
///
/// C'est le piège que la délivrance d'une faute de chargement ouvre : si la
/// porte mène à une adresse que les tables ne portent pas non plus, la boucle
/// faute, délivre, refaute, redélivre — et rend « tours épuisés », un relevé
/// qui ne dit pas ce qui manque. Sur le silicium c'est une double faute.
///
/// **La garde compte les chargements fautifs d'affilée, pas les fautes.** Un
/// noyau qui cartographie à la demande en enchaîne autant qu'il veut : entre
/// chacun une région s'installe, et le compteur retombe. Deux d'affilée sans
/// qu'une seule région s'installe ne peut vouloir dire qu'une chose.
///
/// Le montage le pose en une ligne : la porte du vecteur 14 mène à la page
/// absente elle-même.
#[test]
fn a_handler_whose_own_page_is_absent_is_named_instead_of_looping() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    let scratch = tss_scratch("double");
    let driver = tss_driver(
        &scratch,
        TSS_USER_CODE,
        TSS_USER_STACK_SELECTOR,
        0,
        true,
        false,
        &format!(
            "// La porte mène là où la page manque : le gestionnaire est \
             hors de la carte.\n\
             const [b2, h2] = porte({RIG_ABSENT}n);\n\
             vue.setBigUint64({RIG_IDT} + 14 * 16, b2, true);\n\
             vue.setBigUint64({RIG_IDT} + 14 * 16 + 8, h2, true);"
        ),
    );
    let text = run_driver(&bun, &driver);
    assert_eq!(
        line_of(&text, "arret "),
        "une faute pendant la délivrance d'une faute de page sur un chargement \
         d'instruction : le gestionnaire lui-même n'est pas cartographié",
        "**l'arrêt nomme la double faute** au lieu d'épuiser les tours : \
         {text}"
    );
    assert_eq!(
        line_of(&text, "rbx "),
        "0x0",
        "et aucun témoin n'a tourné : il n'y avait pas de gestionnaire à \
         atteindre : {text}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}

/// **Le compteur de double faute retombe dès qu'une région s'installe.**
///
/// C'est la garde qu'aucune assertion ne tenait, et le sabotage l'a dit :
/// retirer la remise à zéro ne faisait tomber aucun test, parce qu'aucun
/// montage ne délivrait **deux** chargements fautifs séparés par une région
/// installée. Or c'est exactement ce que fait un noyau qui cartographie à la
/// demande : il en enchaîne autant que le programme a de pages.
///
/// **Le montage : deux pages absentes, et un gestionnaire qui refaute.** Il
/// compte ses passages dans RBX et saute sur la seconde. Entre les deux
/// chargements fautifs, sa propre région s'est installée.
///
/// | | avec la remise à zéro | sans |
/// | --- | --- | --- |
/// | passages du gestionnaire | **2** | 1 |
/// | arrêt | la double faute nommée | la même, un tour plus tôt |
///
/// **L'arrêt est le même des deux côtés** — c'est le nombre de passages qui
/// tranche, et c'est pour ça que l'assertion porte sur lui. Une assertion sur
/// l'arrêt aurait eu l'air d'une garde sans en être une.
#[test]
fn the_double_fault_counter_falls_back_as_soon_as_a_region_installs() {
    let Some(bun) = bun() else {
        panic!("Bun est absent : ce test ne serait vérifié par rien.");
    };
    let scratch = tss_scratch("chaine");
    let driver = tss_driver(
        &scratch,
        TSS_USER_CODE,
        TSS_USER_STACK_SELECTOR,
        0,
        true,
        true,
        "// deux pages absentes, et le gestionnaire saute sur la seconde.",
    );
    let text = run_driver(&bun, &driver);
    assert_eq!(
        line_of(&text, "rbx "),
        "0x2",
        "**le gestionnaire est passé deux fois** : le premier chargement \
         fautif a été délivré, sa région s'est installée, le compteur est \
         retombé, et le second a été délivré aussi. Sans la remise à zéro il \
         ne passerait qu'une fois : {text}"
    );
    assert_eq!(
        line_of(&text, "arret "),
        "une faute pendant la délivrance d'une faute de page sur un chargement \
         d'instruction : le gestionnaire lui-même n'est pas cartographié",
        "et le troisième chargement, lui, n'a rien installé entre-temps : la \
         garde le nomme : {text}"
    );
    let _ = std::fs::remove_dir_all(&scratch);
}
