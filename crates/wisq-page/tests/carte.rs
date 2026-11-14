//! **La carte de la page, jugée sous le moteur de la page.**
//!
//! Les périphériques sont jugés cas par cas en natif (`src/carte/`). Ce qui
//! reste à tenir ne se voit que sous un vrai moteur : que le module wasm32 —
//! où `usize` fait 32 bits, où un `i64` arrive en `BigInt` et un `u32` en
//! nombre signé — réponde comme le natif, et que `web/carte.js` présente à
//! `host.js` la forme exacte d'`env.in`, `env.out` et des lignes.
//!
//! Sans Bun, ou sans la cible `wasm32-unknown-unknown`, ces tests **tombent**
//! plutôt que de passer en silence, comme ceux de `tests/page.rs`.

use std::path::{Path, PathBuf};
use std::process::Command;

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
            panic!("Bun est absent : la carte de la page ne serait vérifiée par rien.")
        })
}

/// Le module de la page, construit par le script que tout le monde lance
/// (`scripts/build-page-emitter.sh`), comme dans `tests/page.rs`.
fn page_module() -> PathBuf {
    let root = workspace_root();
    let output = Command::new("bash")
        .arg(root.join("scripts/build-page-emitter.sh"))
        .arg(&root)
        .output()
        .expect("le script de construction doit démarrer");
    assert!(
        output.status.success(),
        "le module de la page ne se construit pas :\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    PathBuf::from(String::from_utf8_lossy(&output.stdout).trim())
}

/// Lancer un pilote Bun et rendre ce qu'il a imprimé ; un pilote qui échoue
/// fait tomber le test avec sa sortie d'erreur.
fn run_driver(name: &str, script: &str) -> String {
    let work = std::env::temp_dir().join(format!("wisq-carte-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work).expect("dossier de travail");
    let driver = work.join("d.mjs");
    std::fs::write(&driver, script).expect("le pilote");
    let output = Command::new(bun())
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

fn prelude(module: &Path) -> String {
    let root = workspace_root();
    format!(
        "import {{ carte }} from {carte:?};\n\
         import {{ emetteur }} from {page:?};\n\
         import {{ readFileSync }} from \"fs\";\n\
         const module = new WebAssembly.Module(readFileSync({module:?}));\n",
        carte = root.join("web/carte.js").to_string_lossy(),
        page = root.join("web/page-emitter.js").to_string_lossy(),
        module = module.to_string_lossy(),
    )
}

/// **Un aller-retour de port, et la sonde de Linux, par le module wasm32.**
///
/// L'horloge lit l'heure figée qu'on lui donne (le moment des tests Swift,
/// le 30 octobre 2026 à 17 h 05 min 09 s UTC), relue à chaque accès ; le
/// 8042 répond à son autotest ; un port des puces de `host.js` n'est pas à
/// la carte ; une valeur de 64 bits garde son octet bas en passant l'export
/// `i32`. Et le module n'a **aucun import** : l'émetteur, instancié avec
/// `{}` par `web/page-emitter.js`, en dépend.
#[test]
fn a_port_round_trip_through_the_page_module() {
    let module = page_module();
    let script = format!(
        r#"{prelude}
console.log("imports " + WebAssembly.Module.imports(module).length);
let maintenant = 1793379909000;
const c = carte(module, {{ heure: () => maintenant }});
const lire = (port) => {{ const v = c.ports.in(BigInt(port), 1n); return v === null ? "personne" : "0x" + v.toString(16); }};
console.log("type " + typeof c.ports.in(0x71n, 1n));
c.ports.out(0x70n, 0x09n, 1n);
console.log("annee " + lire(0x71));
c.ports.out(0x70n, 0x04n, 1n);
console.log("heure " + lire(0x71));
maintenant += 3600000;
console.log("heure_plus_une " + lire(0x71));
c.ports.out(0x70n, 0x0fn, 1n);
console.log("pris " + c.ports.out(0x71n, 0x5an, 1n));
console.log("memoire " + lire(0x71));
console.log("serie " + lire(0x3f8) + " " + c.ports.out(0x3f8n, 0x41n, 1n));
console.log("pic " + lire(0x21));
c.ports.out(0x64n, 0xaan, 1n);
console.log("etat " + lire(0x64));
console.log("autotest " + lire(0x60));
// Un registre entier, tel qu'`env.out` le reçoit : au-delà de 2⁵³, où un
// `Number` perdrait l'octet bas. Ce qui compte est `0xaa`, l'autotest.
c.ports.out(0x64n, 0x12345678000000aan, 4n);
console.log("large " + "0x" + c.ports.in(0x60n, 4n).toString(16));
console.log("remise_avant " + c.remise());
c.ports.out(0x64n, 0xfen, 1n);
console.log("remise_apres " + c.remise());
"#,
        prelude = prelude(&module),
    );
    let text = run_driver("ports", &script);
    assert_eq!(
        said(&text, "imports "),
        "0",
        "l'émetteur s'instancie avec {{}}"
    );
    assert_eq!(said(&text, "type "), "bigint", "la forme d'env.in");
    assert_eq!(said(&text, "annee "), "0x26");
    assert_eq!(said(&text, "heure "), "0x17");
    assert_eq!(
        said(&text, "heure_plus_une "),
        "0x18",
        "l'heure est relue à chaque accès"
    );
    assert_eq!(said(&text, "pris "), "true");
    assert_eq!(said(&text, "memoire "), "0x5a");
    assert_eq!(
        said(&text, "serie "),
        "personne false",
        "le port série est à host.js"
    );
    assert_eq!(said(&text, "pic "), "personne");
    assert_eq!(
        said(&text, "etat "),
        "0x1d",
        "sortie pleine, commande, système, non verrouillé"
    );
    assert_eq!(said(&text, "autotest "), "0x55");
    assert_eq!(said(&text, "large "), "0x55");
    assert_eq!(said(&text, "remise_avant "), "false");
    assert_eq!(said(&text, "remise_apres "), "true");
}

/// **Les lignes, telles que l'aiguillage de `host.js` les recopiera.**
///
/// Un faux couple de 8259 reçoit, à chaque tour, ce que la carte lève sur
/// ce qu'elle tient : la ligne 1 monte au maître pour une touche et retombe
/// quand le noyau l'a lue, la ligne 12 monte à l'esclave (quatrième bit) pour
/// la souris, et **les lignes 0 et 4, que les puces de `host.js` posent, ne
/// sont jamais touchées**. Un texte tapé arrive au rythme d'une main, en tics
/// du 8254 passés en `BigInt`. Et une trappe de l'émetteur, instancié sur le
/// même module, ne coûte rien à la carte : ce sont deux instances.
#[test]
fn the_lines_reach_the_two_8259s_at_level_and_typing_is_paced() {
    let module = page_module();
    let script = format!(
        r#"{prelude}
const c = carte(module, {{ heure: () => 0 }});
// Les 8259 de `host.js`, réduits à leurs registres de requête. Les lignes 0
// (le 8254) et 4 (le 16550) sont levées par l'hôte et doivent le rester.
const pics = {{ master: {{ request: 0x11 }}, slave: {{ request: 0 }} }};
const recopier = () => {{
  const l = c.lignes();
  pics.master.request = (pics.master.request & ~l.tenuesMaitre) | l.maitre;
  pics.slave.request = (pics.slave.request & ~l.tenuesEsclave) | l.esclave;
  return pics.master.request.toString(16) + "/" + pics.slave.request.toString(16);
}};
console.log("depart " + recopier());
c.touche(0x39, false, true);
console.log("touche " + recopier());
console.log("lue 0x" + c.ports.in(0x60n, 1n).toString(16));
console.log("retombee " + recopier());
// La souris : allumée comme Linux le fait, puis un mouvement.
c.ports.out(0x64n, 0xa8n, 1n);
c.ports.out(0x64n, 0xd4n, 1n);
c.ports.out(0x60n, 0xf4n, 1n);
console.log("accuse " + recopier());
const paquet = [];
c.ports.in(0x60n, 1n);
c.souris(3, -2, 1);
console.log("souris " + recopier());
for (let i = 0; i < 3; i++) paquet.push(c.ports.in(0x60n, 1n).toString(16));
console.log("paquet " + paquet.join(","));
console.log("calme " + recopier());

// Une trappe de l'émetteur, sur le même module : la carte n'en sait rien.
const porte = emetteur(module);
const trappe = porte.resoudre({{ length: 0xffffffff }}, 0x100000n, 0, 16);
console.log("trappe " + (trappe.trappe !== undefined) + " " + porte.instances);

// Un texte, au rythme d'une main : une milliseconde (1 193 tics) par tour.
console.log("frappes " + c.taperTexte("Hé!"));
const lus = [];
let tics = 0n;
while ((c.reveil() || c.lignes().maitre !== 0) && tics < 1193n * 2000n) {{
  c.battre(tics);
  recopier();
  if (pics.master.request & 2) lus.push(tics + ":" + c.ports.in(0x60n, 1n).toString(16));
  tics += 1193n;
}}
console.log("lus " + lus.join(" "));
console.log("fin " + recopier() + " " + c.reveil());
"#,
        prelude = prelude(&module),
    );
    let text = run_driver("lignes", &script);
    assert_eq!(
        said(&text, "depart "),
        "11/0",
        "les lignes de l'hôte restent"
    );
    assert_eq!(said(&text, "touche "), "13/0", "la ligne 1 au maître");
    assert_eq!(said(&text, "lue "), "0x39");
    assert_eq!(said(&text, "retombee "), "11/0");
    assert_eq!(
        said(&text, "accuse "),
        "11/10",
        "l'accusé de la souris, ligne 12"
    );
    assert_eq!(said(&text, "souris "), "11/10");
    assert_eq!(
        said(&text, "paquet "),
        "9,3,2",
        "Y vers le haut dans le paquet"
    );
    assert_eq!(said(&text, "calme "), "11/0");
    assert_eq!(said(&text, "trappe "), "true 2");
    // « Hé! » : H avec Maj, é sauté (pas sur un clavier américain), ! avec
    // Maj. Huit frappes.
    assert_eq!(said(&text, "frappes "), "8");
    let lus = said(&text, "lus ");
    let codes: Vec<&str> = lus
        .split(' ')
        .map(|l| l.split(':').nth(1).unwrap_or("?"))
        .collect();
    assert_eq!(
        codes,
        ["2a", "23", "a3", "aa", "2a", "2", "82", "aa"],
        "{lus}"
    );
    // Tenue trente millisecondes (35 795 tics), au battement près : la
    // deuxième frappe ne part pas avant.
    let quand: Vec<u64> = lus
        .split(' ')
        .map(|l| {
            l.split(':')
                .next()
                .and_then(|t| t.parse().ok())
                .expect("un tic")
        })
        .collect();
    assert!(
        (35_795..35_795 + 1_193).contains(&(quand[1] - quand[0])),
        "{lus}"
    );
    assert!(
        (23_864..23_864 + 1_193).contains(&(quand[3] - quand[2])),
        "{lus}"
    );
    assert_eq!(said(&text, "fin "), "11/0 false");
}

/// **Ce que l'application envoie, par le module wasm32** : une touche
/// étendue posée tout de suite ou à son tour (`E0` devant), les lignes du
/// dehors levées, baissées et refusées, et **un texte qui remplit la file
/// sans laisser de touche enfoncée** — le défaut d'avant : `"a" + "A" ×
/// 2048` finissait sur `Maj↓ A↓`, et Xorg répétait A sans fin.
#[test]
fn what_the_app_sends_reaches_the_guest_and_never_sticks_a_key() {
    let module = page_module();
    let script = format!(
        r#"{prelude}
const c = carte(module, {{ heure: () => 0 }});
const hex = (v) => Number(v).toString(16);
const vider = () => {{ const lus = []; while (c.lignes().maitre & 2) lus.push(hex(c.ports.in(0x60n, 1n))); return lus; }};
// Tout de suite : la flèche haut, enfoncée.
c.touche(0x48, true, true);
console.log("touche " + vider().join(","));
// À son tour : la flèche gauche, enfoncée puis relâchée.
console.log("taper " + c.taper(0x4b, true, true) + " " + c.taper(0x4b, true, false));
let tics = 0n;
const jouer = () => {{ const lus = []; while (c.reveil()) {{ c.battre(tics); lus.push(...vider()); tics += 100000n; }} return lus; }};
console.log("tapees " + jouer().join(","));
// Les lignes du dehors.
console.log("lever " + c.lever(5) + " " + c.lever(10));
const l = c.lignes();
console.log("levees " + hex(l.maitre) + "/" + hex(l.esclave) + " " + hex(l.tenuesMaitre & 0x20) + "/" + hex(l.tenuesEsclave & 0x04));
console.log("baisser " + c.baisser(5) + " " + hex(c.lignes().maitre) + "/" + hex(c.lignes().esclave));
console.log("refus " + [c.lever(0), c.lever(2), c.lever(4), c.lever(16), c.baisser(4)].join(","));
c.baisser(10);
// Le texte qui remplit la file : 2 + 4 × 2047 frappes, le « A » suivant ne
// tient plus.
console.log("frappes " + c.taperTexte("a" + "A".repeat(2048)));
// La file est pleine à deux places près : deux touches enfoncées passent,
// une troisième non ; leurs relâchements passent au-delà de la borne, pas
// celui d'une touche relevée.
console.log("borne " + [c.taper(0x30, false, true), c.taper(0x31, false, true), c.taper(0x32, false, true),
  c.taper(0x30, false, false), c.taper(0x31, false, false), c.taper(0x32, false, false)].join(","));
const lus = jouer();
console.log("derniers " + lus.slice(-8).join(" "));
const compte = (o) => lus.filter((x) => x === o).length;
console.log("comptes " + [compte("2a"), compte("aa"), compte("1e"), compte("9e")].join(","));
"#,
        prelude = prelude(&module),
    );
    let text = run_driver("application", &script);
    assert_eq!(
        said(&text, "touche "),
        "e0,48",
        "E0 devant une touche étendue"
    );
    assert_eq!(said(&text, "taper "), "true true");
    assert_eq!(said(&text, "tapees "), "e0,4b,e0,cb", "E0 à son tour aussi");
    assert_eq!(said(&text, "lever "), "true true");
    assert_eq!(
        said(&text, "levees "),
        "20/4 20/4",
        "ligne 5 au maître, 10 à l'esclave"
    );
    assert_eq!(said(&text, "baisser "), "true 0/4");
    assert_eq!(
        said(&text, "refus "),
        "false,false,false,false,false",
        "les lignes de l'hôte, et au-delà de 15"
    );
    assert_eq!(said(&text, "frappes "), "8190");
    assert_eq!(said(&text, "borne "), "true,true,false,true,true,false");
    assert_eq!(
        said(&text, "derniers "),
        "2a 1e 9e aa 30 31 b0 b1",
        "un caractère entier, puis chaque touche relâchée"
    );
    // « a » sans Maj, puis 2 047 « A » : Maj enfoncée et relâchée autant de
    // fois, A aussi.
    assert_eq!(said(&text, "comptes "), "2047,2047,2048,2048");
}
