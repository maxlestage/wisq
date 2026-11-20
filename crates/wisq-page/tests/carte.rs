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
/// `i32`. Et le module n'importe **que les deux fonctions de la RAM**
/// (`carte.ram_lire`, `carte.ram_ecrire`), rien d'autre : l'émetteur,
/// instancié sur le même module par `web/page-emitter.js`, les reçoit de lui
/// sous une forme qui lève, et une mémoire ou une table importée le
/// casserait.
#[test]
fn a_port_round_trip_through_the_page_module() {
    let module = page_module();
    let script = format!(
        r#"{prelude}
console.log("imports " + WebAssembly.Module.imports(module).map((i) => i.module + "." + i.name + ":" + i.kind).sort().join(" "));
console.log("emetteur " + emetteur(module).instances);
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
        "carte.ram_ecrire:function carte.ram_lire:function",
        "la RAM, et rien d'autre"
    );
    assert_eq!(said(&text, "emetteur "), "1", "l'émetteur s'instancie");
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

/// **Un disque de 1,4 Gio lu par plages, servi plus tard, qui lève la ligne
/// 5 à la fin.**
///
/// Le fichier est creux (`ftruncate`) : 1,4 Gio annoncés, quelques kibioctets
/// sur le disque, deux marques — l'une à 4 Kio de la fin, l'autre écrite par
/// l'invité. `Bun.serve` le sert par plages, `?a=…&n=…`, en lisant
/// `Bun.file(…).slice(a, a + n)` : jamais le fichier entier. C'est le contrat
/// que le magasin de la page tiendra par `wisq://`, et `arriereParUrl` de
/// `web/carte.js` est l'arrière qui le parle.
///
/// Le noyau est joué par les ports, dans son ordre : l'énumération du bus,
/// la mesure de la BAR, son placement, la ligne lue, la capacité, la poignée
/// de main, la file posée à la page 1 dans la RAM de l'invité (une
/// `WebAssembly.Memory` à part, comme celle de `host.js`). Puis :
///
/// - la notification rend tout de suite, la ligne reste basse, la carte se
///   dit réveillable, et **tant que l'arrière tarde** (une porte fermée devant
///   lui), rien n'est rendu, même vingt millisecondes plus tard ;
/// - la porte ouverte, une seule lecture de 4 096 octets part, à
///   `taille − 4096`, la marque arrive dans la RAM, l'octet de statut dit
///   « réussi », l'anneau des servies avance, **la ligne 5 monte** au 8259
///   maître, et retombe quand le noyau lit l'état d'interruption ;
/// - une écriture part par `PUT` et change le fichier, au bon endroit ;
/// - l'arrière refuse une plage que le magasin rend tronquée ;
/// - un secteur au-delà du disque est refusé tout de suite, sans requête.
///
/// Et une mesure : seize lectures d'un mébioctet de suite, par la file, de
/// la notification à la ligne levée.
#[test]
fn a_disk_read_by_ranges_is_served_later_and_raises_line_five() {
    let module = page_module();
    let carte_js = workspace_root().join("web/carte.js");
    let script = format!(
        r#"{prelude}
import {{ arriereParUrl, ramDeMemoire }} from {carte_js:?};
import {{ openSync, ftruncateSync, writeSync, readSync, closeSync, statSync }} from "fs";

// Le disque : 1,4 Gio annoncés, creux.
const TAILLE = 1503238144;
const chemin = import.meta.dir + "/disque.iso";
let fd = openSync(chemin, "w");
ftruncateSync(fd, TAILLE);
writeSync(fd, new TextEncoder().encode("la fin du disque"), 0, 16, TAILLE - 4096);
closeSync(fd);
console.log("creux " + (statSync(chemin).blocks * 512 < 1048576));

// Le magasin, par plages.
const lectures = [];
const serveur = Bun.serve({{
  port: 0,
  async fetch(requete) {{
    const u = new URL(requete.url);
    const a = Number(u.searchParams.get("a"));
    if (requete.method === "PUT") {{
      const corps = new Uint8Array(await requete.arrayBuffer());
      const f = openSync(chemin, "r+");
      writeSync(f, corps, 0, corps.length, a);
      closeSync(f);
      return new Response(null, {{ status: 204 }});
    }}
    const n = Number(u.searchParams.get("n"));
    lectures.push(a + "+" + n);
    return new Response(Bun.file(chemin).slice(a, a + n));
  }},
}});
const parUrl = arriereParUrl("http://127.0.0.1:" + serveur.port + "/disque/0", TAILLE);
// Une porte fermée devant l'arrière : la réponse tarde autant qu'on veut.
let ouvrir;
const porteDeLArriere = new Promise((r) => (ouvrir = r));
const arriere = {{
  octets: TAILLE,
  lire: async (a, n) => {{ await porteDeLArriere; return parUrl.lire(a, n); }},
  ecrire: (a, o) => parUrl.ecrire(a, o),
}};

// La RAM de l'invité : 4 Mio, dans une mémoire à elle.
const memoire = new WebAssembly.Memory({{ initial: 64 }});
const vue = () => new DataView(memoire.buffer);
let reponses = 0;
const c = carte(module, {{ heure: () => 0, ram: ramDeMemoire(memoire, 64 * 65536), disque: arriere, surReponse: () => (reponses += 1) }});
const sortir = (port, valeur, largeur) => c.ports.out(BigInt(port), BigInt(valeur), BigInt(largeur));
const entrer = (port, largeur) => {{ const v = c.ports.in(BigInt(port), BigInt(largeur)); return v === null ? "personne" : "0x" + v.toString(16); }};
const pics = {{ master: {{ request: 0x11 }}, slave: {{ request: 0 }} }};
const recopier = () => {{
  const l = c.lignes();
  pics.master.request = (pics.master.request & ~l.tenuesMaitre) | l.maitre;
  pics.slave.request = (pics.slave.request & ~l.tenuesEsclave) | l.esclave;
  return pics.master.request.toString(16) + "/" + pics.slave.request.toString(16);
}};

// L'énumération, comme le noyau.
sortir(0xcf8, 0x80000000, 4);
console.log("pont " + entrer(0xcfc, 4));
sortir(0xcf8, 0x80001800, 4);
console.log("disque " + entrer(0xcfc, 4));
sortir(0xcf8, 0x80001810, 4);
sortir(0xcfc, 0xffffffff, 4);
console.log("masque " + entrer(0xcfc, 4));
sortir(0xcfc, 0xc000, 4);
sortir(0xcf8, 0x80001804, 4);
sortir(0xcfc, 0x0005, 2);
sortir(0xcf8, 0x8000183c, 4);
console.log("ligne " + entrer(0xcfc, 1));
console.log("capacite " + entrer(0xc018, 4) + " " + entrer(0xc014, 4));
// La poignée de main, et la file à la page 1.
for (const s of [0, 1, 3]) sortir(0xc012, s, 1);
sortir(0xc004, Number(entrer(0xc000, 4)), 4);
sortir(0xc012, 11, 1);
sortir(0xc00e, 0, 2);
console.log("taille " + entrer(0xc00c, 2));
sortir(0xc008, 1, 4);
sortir(0xc012, 15, 1);

// Une requête : l'en-tête à 0x4000, le tampon à 0x10000, le statut à 0x4800.
let publiees = 0;
function requete(genre, secteur, longueur, inscriptible) {{
  const v = vue();
  v.setUint32(0x4000, genre, true);
  v.setBigUint64(0x4008, BigInt(secteur), true);
  const dire = (i, a, n, drapeaux, suivant) => {{
    v.setBigUint64(0x1000 + i * 16, BigInt(a), true);
    v.setUint32(0x1008 + i * 16, n, true);
    v.setUint16(0x100c + i * 16, drapeaux, true);
    v.setUint16(0x100e + i * 16, suivant, true);
  }};
  dire(0, 0x4000, 16, 1, 1);
  dire(1, 0x10000, longueur, inscriptible ? 3 : 1, 2);
  dire(2, 0x4800, 1, 2, 0);
  v.setUint8(0x4800, 0xff);
  v.setUint16(0x1804 + (publiees % 128) * 2, 0, true);
  publiees += 1;
  v.setUint16(0x1802, publiees, true);
  return sortir(0xc010, 0, 2);
}}
const statut = () => "0x" + vue().getUint8(0x4800).toString(16);
const servies = () => vue().getUint16(0x2002, true);
const attendre = async () => {{ while (c.disque.enVol() > 0) await new Promise((r) => setTimeout(r, 1)); }};

console.log("notifie " + requete(0, (TAILLE - 4096) / 512, 4096, true));
console.log("tout_de_suite " + recopier() + " " + statut() + " " + c.reveil() + " " + c.disque.enVol() + " " + lectures.length);
await new Promise((r) => setTimeout(r, 20));
console.log("en_attente " + recopier() + " " + statut() + " " + servies() + " " + lectures.length + " " + reponses);
ouvrir();
await attendre();
const lu = new TextDecoder().decode(new Uint8Array(memoire.buffer, 0x10000, 16));
console.log("revenue " + recopier() + " " + statut() + " " + servies() + " " + vue().getUint32(0x2008, true) + " " + reponses);
console.log("marque " + lu);
console.log("lectures " + lectures.join(","));
console.log("acquitte " + entrer(0xc013, 1) + " " + recopier() + " " + c.reveil());

// Une écriture, au secteur 8.
new Uint8Array(memoire.buffer, 0x10000, 512).fill(0).set(new TextEncoder().encode("écrit par l'invité"));
console.log("ecriture " + requete(1, 8, 512, false));
await attendre();
const relu = new Uint8Array(20);
fd = openSync(chemin, "r");
readSync(fd, relu, 0, 20, 8 * 512);
closeSync(fd);
console.log("ecrite " + statut() + " " + new TextDecoder().decode(relu) + " " + recopier());
entrer(0xc013, 1);

// L'arrière refuse une plage plus courte que demandée : les dix derniers
// octets du fichier, quand on en demande vingt.
console.log("court " + (await parUrl.lire(TAILLE - 10, 20).then(() => "rendu", (e) => "refuse")));

// Au-delà du disque : refusé tout de suite, rien ne part.
const avant = lectures.length;
requete(0, TAILLE / 512, 512, true);
console.log("au_dela " + statut() + " " + c.disque.enVol() + " " + (lectures.length - avant) + " " + recopier());
entrer(0xc013, 1);

// La mesure : seize mébioctets, un par requête, de la notification à la
// ligne levée.
const debut = performance.now();
for (let i = 0; i < 16; i++) {{
  requete(0, (i * 1048576) / 512, 1048576, true);
  await attendre();
  if ((recopier(), pics.master.request & 0x20) === 0 || statut() !== "0x0") throw new Error("lecture " + i);
  entrer(0xc013, 1);
}}
const ms = performance.now() - debut;
console.log("mesure " + (ms / 16).toFixed(2) + " ms par Mio, " + (16 / (ms / 1000)).toFixed(0) + " Mio/s");
serveur.stop(true);
"#,
        prelude = prelude(&module),
    );
    let text = run_driver("disque", &script);
    assert_eq!(
        said(&text, "creux "),
        "true",
        "le fichier n'occupe presque rien"
    );
    assert_eq!(said(&text, "pont "), "0x12378086", "le 440FX en 00:00.0");
    assert_eq!(
        said(&text, "disque "),
        "0x10011af4",
        "virtio-blk ancien en 00:03.0"
    );
    assert_eq!(said(&text, "masque "), "0xffffffc1", "64 ports");
    assert_eq!(said(&text, "ligne "), "0x5");
    // 1 503 238 144 / 512 = 2 936 012 = 0x2C_CCCC.
    assert_eq!(said(&text, "capacite "), "0x0 0x2ccccc");
    assert_eq!(said(&text, "taille "), "0x80");
    assert_eq!(said(&text, "notifie "), "true", "l'out rend tout de suite");
    assert_eq!(
        said(&text, "tout_de_suite "),
        "11/0 0xff true 1 0",
        "ligne basse, statut intact, réveillable, une en vol, rien de lu"
    );
    assert_eq!(
        said(&text, "en_attente "),
        "11/0 0xff 0 0 0",
        "l'arrière tarde : rien n'est rendu"
    );
    assert_eq!(
        said(&text, "revenue "),
        "31/0 0x0 1 4096 1",
        "la ligne 5 au maître, réussi, une servie de 4 096 octets"
    );
    assert_eq!(said(&text, "marque "), "la fin du disque");
    assert_eq!(
        said(&text, "lectures "),
        "1503234048+4096",
        "une seule plage, celle demandée"
    );
    assert_eq!(said(&text, "acquitte "), "0x1 11/0 false");
    assert_eq!(said(&text, "ecriture "), "true");
    assert_eq!(said(&text, "court "), "refuse", "jamais une plage tronquée");
    assert_eq!(
        said(&text, "ecrite "),
        "0x0 écrit par l'invité 31/0",
        "le fichier a changé, au secteur 8"
    );
    assert_eq!(
        said(&text, "au_dela "),
        "0x1 0 0 31/0",
        "erreur, rien en vol, rien lu, la réponse déjà là"
    );
    let mesure = said(&text, "mesure ");
    eprintln!("disque par plages : {mesure}");
}

/// **Le noyau, joué par les ports, pour les tests du disque** : un fragment
/// JavaScript qui attend `c` (la carte) et `memoire` (la RAM de l'invité),
/// et définit `brancher()` (l'énumération, la BAR à `0xC000`, la poignée de
/// main, la file à la page 1), `requete(…)` (une chaîne de trois
/// descripteurs à partir de `tete`, publiée, puis la notification),
/// `statut(a)`, `servies()` et `attendre()` (jusqu'à ce que l'arrière n'ait
/// plus rien, ou deux secondes au plus : un test qui attend pour rien tombe
/// au lieu de pendre).
const PILOTE_DU_DISQUE: &str = r#"
const vue = () => new DataView(memoire.buffer);
const sortir = (port, valeur, largeur) => c.ports.out(BigInt(port), BigInt(valeur), BigInt(largeur));
const entrer = (port, largeur) => Number(c.ports.in(BigInt(port), BigInt(largeur)));
function brancher() {
  sortir(0xcf8, 0x80001810, 4);
  sortir(0xcfc, 0xc000, 4);
  sortir(0xcf8, 0x80001804, 4);
  sortir(0xcfc, 0x0005, 2);
  for (const s of [0, 1, 3]) sortir(0xc012, s, 1);
  sortir(0xc004, entrer(0xc000, 4), 4);
  sortir(0xc012, 11, 1);
  sortir(0xc00e, 0, 2);
  sortir(0xc008, 1, 4);
  sortir(0xc012, 15, 1);
}
let publiees = 0;
function poser({ tete = 0, genre, secteur, tampon = 0x10000, longueur = 512, entete = 0x4000, statut = 0x4800 }) {
  const v = vue();
  v.setUint32(entete, genre, true);
  v.setBigUint64(entete + 8, BigInt(secteur), true);
  const dire = (i, a, n, drapeaux, suivant) => {
    v.setBigUint64(0x1000 + i * 16, BigInt(a), true);
    v.setUint32(0x1008 + i * 16, n, true);
    v.setUint16(0x100c + i * 16, drapeaux, true);
    v.setUint16(0x100e + i * 16, suivant, true);
  };
  dire(tete, entete, 16, 1, tete + 1);
  dire(tete + 1, tampon, longueur, genre === 0 ? 3 : 1, tete + 2);
  dire(tete + 2, statut, 1, 2, 0);
  v.setUint8(statut, 0xff);
  v.setUint16(0x1804 + (publiees % 128) * 2, tete, true);
  publiees += 1;
}
function requete(...demandes) {
  for (const d of demandes) poser(d);
  vue().setUint16(0x1802, publiees, true);
  return sortir(0xc010, 0, 2);
}
const statut = (a = 0x4800) => "0x" + vue().getUint8(a).toString(16);
const servies = () => vue().getUint16(0x2002, true);
const attendre = async () => {
  const fin = performance.now() + 2000;
  while (c.disque.enVol() > 0 && performance.now() < fin) await new Promise((r) => setTimeout(r, 1));
};
"#;

/// **Un arrière qui échoue est une erreur d'entrée-sortie pour le pilote**,
/// jamais une réussite : c'est ce que `web/carte.js` promet, jugé par la
/// carte entière, de l'`out` qui notifie à l'octet de statut.
///
/// Le magasin est un faux `fetch` donné à `arriereParUrl`, qui répond selon
/// le cas : un `PUT` refusé (500), un `GET` refusé (500), une plage rendue
/// tronquée. Puis un arrière dont l'écriture rejette sa promesse, un dont
/// l'écriture lève tout de suite, et un qui ne sait pas écrire du tout.
/// Chaque cas doit rendre le statut `0x1` ; une lecture refusée ne doit
/// rien laisser dans le tampon. Et, pour que les refus ne viennent pas du
/// montage, le même magasin qui répond bien rend `0x0`, dans les deux sens.
#[test]
fn a_failing_backend_is_an_io_error_for_the_driver() {
    let module = page_module();
    let carte_js = workspace_root().join("web/carte.js");
    let script = format!(
        r#"{prelude}
import {{ arriereParUrl, ramDeMemoire }} from {carte_js:?};
let mode = "bien";
const faux = async (url, init) => {{
  const n = Number(new URL(url).searchParams.get("n"));
  if (init?.method === "PUT") return new Response(null, {{ status: mode === "put_refuse" ? 500 : 204 }});
  if (mode === "get_refuse") return new Response("non", {{ status: 500 }});
  if (mode === "tronquee") return new Response(new Uint8Array(n - 10).fill(0x5a));
  return new Response(new Uint8Array(n).fill(0x5a));
}};
const parUrl = arriereParUrl("http://magasin/disque/0", 1 << 20, {{ fetch: faux }});
const arriere = {{
  octets: 1 << 20,
  lire: (a, n) => parUrl.lire(a, n),
  ecrire: (a, o) => {{
    if (mode === "rejette") return Promise.reject(new Error("panne"));
    if (mode === "leve") throw new Error("panne tout de suite");
    return parUrl.ecrire(a, o);
  }},
}};
const memoire = new WebAssembly.Memory({{ initial: 64 }});
const c = carte(module, {{ heure: () => 0, ram: ramDeMemoire(memoire, 64 * 65536), disque: arriere }});
{pilote}
brancher();
const tampon = () => "0x" + new Uint8Array(memoire.buffer)[0x10000].toString(16);
async function cas(nom, genre) {{
  mode = nom;
  new Uint8Array(memoire.buffer, 0x10000, 512).fill(0);
  requete({{ genre, secteur: 1 }});
  await attendre();
  entrer(0xc013, 1);
  console.log(nom + (genre === 0 ? "_lu " : "_ecrit ") + statut() + " " + tampon() + " " + c.disque.enVol());
}}
await cas("bien", 0);
await cas("bien", 1);
await cas("put_refuse", 1);
await cas("get_refuse", 0);
await cas("tronquee", 0);
await cas("rejette", 1);
await cas("leve", 1);
delete arriere.ecrire;
await cas("sans", 1);
console.log("servies " + servies());
"#,
        prelude = prelude(&module),
        pilote = PILOTE_DU_DISQUE,
    );
    let text = run_driver("arriere-en-panne", &script);
    assert_eq!(
        said(&text, "bien_lu "),
        "0x0 0x5a 0",
        "le montage répond bien"
    );
    assert_eq!(said(&text, "bien_ecrit "), "0x0 0x0 0");
    assert_eq!(
        said(&text, "put_refuse_ecrit "),
        "0x1 0x0 0",
        "un PUT refusé n'est pas une écriture faite"
    );
    assert_eq!(said(&text, "get_refuse_lu "), "0x1 0x0 0");
    assert_eq!(
        said(&text, "tronquee_lu "),
        "0x1 0x0 0",
        "une plage tronquée n'est pas complétée"
    );
    assert_eq!(
        said(&text, "rejette_ecrit "),
        "0x1 0x0 0",
        "une promesse rejetée n'est pas une écriture faite"
    );
    assert_eq!(said(&text, "leve_ecrit "), "0x1 0x0 0");
    assert_eq!(said(&text, "sans_ecrit "), "0x1 0x0 0");
    assert_eq!(said(&text, "servies "), "8", "chaque requête a sa réponse");
}

/// **Ce qui attendait de la place part à la réponse**, par `web/carte.js`,
/// sans autre notification. Deux lectures de 40 Mio publiées d'un coup : la
/// carte n'en tient que 64 à la fois, si bien qu'une seule est confiée à
/// l'arrière ; la seconde attend dans la file. Quand la première revient,
/// la seconde est confiée aussitôt, et le compte de ce qui est en vol ne
/// passe jamais par zéro entre les deux — une boucle hôte qui dort tant
/// qu'il est à zéro ne la manquerait donc pas.
///
/// **Ce « jamais » est observé, microtâche par microtâche** : pendant que la
/// réponse se rend, une autre chaîne de promesses relève `enVol` à chacun de
/// ses pas, comme le ferait la réaction d'une autre requête ou son
/// `surReponse`. Elle voit 2 (la seconde confiée, la première pas encore
/// décomptée) et jamais 0. Le compte relevé dans `surReponse` seul ne le
/// prouve pas : il vaut 1 dans les deux ordres.
#[test]
fn what_waits_for_room_leaves_on_the_answer() {
    let module = page_module();
    let carte_js = workspace_root().join("web/carte.js");
    let script = format!(
        r#"{prelude}
import {{ ramDeMemoire }} from {carte_js:?};
const MORCEAU = 40 << 20;
const attentes = [];
const arriere = {{
  octets: 1 << 30,
  lire: (a, n) => new Promise((rendre) => attentes.push({{ a, n, rendre }})),
}};
const pages = (0x100000 + MORCEAU) / 65536;
const memoire = new WebAssembly.Memory({{ initial: pages }});
const enVolALaReponse = [];
const c = carte(module, {{ heure: () => 0, ram: ramDeMemoire(memoire, pages * 65536), disque: arriere, surReponse: () => enVolALaReponse.push(c.disque.enVol()) }});
{pilote}
brancher();
const lecture = (k) => ({{ tete: 3 * k, genre: 0, secteur: (k * MORCEAU) / 512, tampon: 0x100000, longueur: MORCEAU, entete: 0x4000 + 0x10 * k, statut: 0x4800 + k }});
console.log("notifie " + requete(lecture(0), lecture(1)));
// L'arrière est appelé une tâche plus tard (`servir` passe par une
// promesse) : le laisser venir avant de compter.
await new Promise((r) => setTimeout(r, 5));
console.log("confiees " + attentes.length + " " + c.disque.enVol() + " " + statut(0x4801));
attentes[0].rendre(new Uint8Array(attentes[0].n).fill(1));
// Une autre chaîne de promesses, qui relève le compte à chaque microtâche
// pendant que la réponse se rend.
const releves = [];
for (let pas = 0; pas < 200; pas++) {{
  releves.push(c.disque.enVol());
  await null;
}}
console.log("releves " + Math.min(...releves) + " " + Math.max(...releves) + " " + releves.at(-1));
const fin = performance.now() + 2000;
while (attentes.length < 2 && performance.now() < fin) await new Promise((r) => setTimeout(r, 1));
console.log("apres_la_premiere " + attentes.length + " " + c.disque.enVol() + " " + statut(0x4800) + " " + servies());
console.log("seconde " + (attentes[1] ? attentes[1].a + "+" + attentes[1].n : "aucune"));
attentes[1]?.rendre(new Uint8Array(attentes[1].n).fill(2));
await attendre();
console.log("fin " + statut(0x4800) + " " + statut(0x4801) + " " + servies() + " " + new Uint8Array(memoire.buffer)[0x100000] + " " + c.disque.enVol());
console.log("en_vol_a_chaque_reponse " + enVolALaReponse.join(","));
"#,
        prelude = prelude(&module),
        pilote = PILOTE_DU_DISQUE,
    );
    let text = run_driver("attente", &script);
    assert_eq!(said(&text, "notifie "), "true");
    assert_eq!(
        said(&text, "confiees "),
        "1 1 0xff",
        "une seule confiée, la seconde attend sans refus"
    );
    assert_eq!(
        said(&text, "apres_la_premiere "),
        "2 1 0x0 1",
        "la seconde confiée dès la réponse"
    );
    assert_eq!(
        said(&text, "releves "),
        "1 2 1",
        "la seconde confiée avant que la première ne soit décomptée, à chaque microtâche"
    );
    assert_eq!(said(&text, "seconde "), "41943040+41943040");
    assert_eq!(said(&text, "fin "), "0x0 0x0 2 2 0");
    assert_eq!(
        said(&text, "en_vol_a_chaque_reponse "),
        "1,0",
        "jamais zéro tant qu'une requête reste à servir"
    );
}

/// **L'écran et la tablette, par les exports du module wasm32**, instancié
/// nu, sans `web/carte.js` (qui ne les sert pas encore à `host.js`) : une
/// RAM de 64 Kio en JavaScript derrière les deux imports.
///
/// L'écran : branché, sa carte en 00:02.0, l'identifiant DISPI par les ports
/// et par la BAR2, un mode posé par la BAR2 et lu par `carte_ecran_mode`, un
/// pixel écrit par l'invité et relu **dans la mémoire du module** à
/// l'adresse que `carte_ecran_pixels` rend (un pointeur de 32 bits), la
/// révision, et un mot de huit octets au-delà de 2⁵³ dans les deux sens.
///
/// La tablette : 00:07.0, la poignée de main de `virtio_input` par
/// `carte_mem_ecrire`, un toucher qui attend faute de tampons, la sonnette
/// qui en apporte et le rend en lisant la file dans la RAM de la page
/// pendant l'appel, la ligne 10, que la lecture de l'ISR baisse, puis trois
/// crans de molette rendus par `carte_livrer` au rythme d'un doigt.
#[test]
fn the_screen_and_the_tablet_answer_through_the_page_module() {
    let module = page_module();
    let script = format!(
        r#"import {{ readFileSync }} from "fs";
const module = new WebAssembly.Module(readFileSync({module:?}));
const ram = new Uint8Array(0x10000);
let m;
const ici = () => new Uint8Array(m.memory.buffer);
const dedans = (a, n) => a >= 0n && a + BigInt(n) <= BigInt(ram.length);
const instance = new WebAssembly.Instance(module, {{ carte: {{
  ram_lire: (a, vers, n) => {{ if (!dedans(a, n)) return 0; ici().set(ram.subarray(Number(a), Number(a) + n), vers); return 1; }},
  ram_ecrire: (a, depuis, n) => {{ if (!dedans(a, n)) return 0; ram.set(ici().subarray(depuis, depuis + n), Number(a)); return 1; }},
}} }});
m = instance.exports;
const hex = (v) => "0x" + BigInt.asUintN(64, BigInt(v)).toString(16);
const mem = (a, n) => m.carte_mem_lire(BigInt(a), n) === 1 ? hex(m.carte_mem_valeur()) : "personne";
const ecrire = (a, n, v) => m.carte_mem_ecrire(BigInt(a), n, BigInt(v));
const mode = () => Array.from(new Uint32Array(m.memory.buffer, m.carte_ecran_mode(), 4)).join(" ");
console.log("sans " + m.carte_ecran_pixels() + " " + mode() + " " + mem(0xe0000000, 4));
console.log("trop " + m.carte_ecran(4096, 4096));
console.log("branche " + m.carte_ecran(1024, 768) + " " + hex(m.carte_ecran_base()) + " " + m.carte_ecran_taille() + " " + mode());
m.carte_ecrire(0xcf8, 4, 0x80001000);
console.log("bus " + hex(m.carte_lire(0xcfc, 4) & 0xffffffffn));
m.carte_ecrire(0x1ce, 2, 0);
console.log("dispi " + hex(m.carte_lire(0x1cf, 2)) + " " + mem(0xe1000500, 2));
for (const [d, v] of [[0x508, 0], [0x502, 800], [0x504, 600], [0x506, 32], [0x508, 0x41]]) ecrire(0xe1000000 + d, 2, v);
console.log("mode " + mode());
ecrire(0xe100050c, 2, 1024);
console.log("virtuelle " + mode());
ecrire(0xe1000510, 2, 8);
ecrire(0xe1000512, 2, 600);
const decale = mode();
ecrire(0xe1000510, 2, 0);
ecrire(0xe1000512, 2, 0);
console.log("debut " + decale + " / " + mode());
const avant = m.carte_ecran_revision();
console.log("pixel " + ecrire(0xe0000004, 4, 0x00112233) + " " + (m.carte_ecran_revision() - avant));
const p = m.carte_ecran_pixels();
console.log("pixels " + typeof p + " " + Array.from(ici().subarray(p + 4, p + 8)).join(" ") + " " + mem(0xe0000004, 4));
console.log("large " + ecrire(0xe0fffff8, 8, 0xfedcba9876543211n) + " " + mem(0xe0fffff8, 8) + " " + mem(0xe0fffff9, 8));
// La tablette : la mémoire du périphérique allumée, puis virtio_input.
m.carte_ecrire(0xcf8, 4, 0x80003800);
console.log("tablette " + hex(m.carte_lire(0xcfc, 4) & 0xffffffffn) + " " + m.carte_toucher(0.5, 0.5, 1));
m.carte_ecrire(0xcf8, 4, 0x80003804);
m.carte_ecrire(0xcfc, 2, 6);
const t = 0xe1010000;
for (const [d, n, v] of [[0x14, 1, 0], [0x14, 1, 3], [0x08, 4, 1], [0x0c, 4, 1], [0x14, 1, 11], [0x16, 2, 0], [0x18, 2, 8],
  [0x20, 8, 0x1000], [0x28, 8, 0x2000], [0x30, 8, 0x3000], [0x1c, 2, 1], [0x14, 1, 15]]) ecrire(t + d, n, v);
const vue = new DataView(ram.buffer);
for (let r = 0; r < 8; r++) {{
  vue.setBigUint64(0x1000 + r * 16, BigInt(0x4000 + r * 8), true);
  vue.setUint32(0x1000 + r * 16 + 8, 8, true);
  vue.setUint16(0x1000 + r * 16 + 12, 2, true);
  vue.setUint16(0x2004 + r * 2, r, true);
}}
console.log("toucher " + m.carte_toucher(0.25, 0.75, 1) + " " + m.carte_reveil() + " " + m.carte_lignes());
m.carte_livrer(1000n);
console.log("a_court " + vue.getUint16(0x3002, true) + " " + m.carte_lignes());
vue.setUint16(0x2002, 8, true);
console.log("sonnette " + ecrire(t + 0x3000, 2, 0) + " " + vue.getUint16(0x3002, true));
const evenement = (k) => {{ const a = 0x4000 + vue.getUint32(0x3004 + (k % 8) * 8, true) * 8; return vue.getUint16(a, true) + "," + vue.getUint16(a + 2, true) + "," + vue.getUint32(a + 4, true); }};
console.log("rendus " + vue.getUint16(0x3002, true) + " " + [0, 1, 2, 3, 4, 5].map(evenement).join(" ") + " " + m.carte_lignes());
console.log("isr " + mem(t + 0x1000, 1) + " " + m.carte_lignes());
console.log("molette " + m.carte_defiler(-3));
vue.setUint16(0x2002, 16, true);
m.carte_livrer(2000n);
m.carte_livrer(2000n + 35794n);
const tot = vue.getUint16(0x3002, true);
m.carte_livrer(2000n + 35795n);
console.log("cran " + tot + " " + vue.getUint16(0x3002, true) + " " + [6, 7, 8, 9, 10, 11].map(evenement).join(" "));
"#,
        module = module.to_string_lossy(),
    );
    let text = run_driver("ecran", &script);
    assert_eq!(said(&text, "sans "), "0 0 0 0 0 personne", "sans écran");
    assert_eq!(said(&text, "trop "), "0", "64 Mio ne tiennent pas");
    assert_eq!(
        said(&text, "branche "),
        "1 0xe0000000 16777216 1024 768 4096 0"
    );
    assert_eq!(said(&text, "bus "), "0x11111234", "Bochs / QEMU std VGA");
    assert_eq!(said(&text, "dispi "), "0xb0c5 0xb0c5");
    assert_eq!(said(&text, "mode "), "800 600 3200 0");
    assert_eq!(
        said(&text, "virtuelle "),
        "800 600 4096 0",
        "la ligne virtuelle"
    );
    assert_eq!(
        said(&text, "debut "),
        "800 600 4096 2457632 / 800 600 4096 0",
        "le premier pixel montré : (600 × 1 024 + 8) × 4, puis la première page"
    );
    assert_eq!(said(&text, "pixel "), "1 1", "une écriture, une révision");
    assert_eq!(
        said(&text, "pixels "),
        "number 51 34 17 0 0x112233",
        "les pixels, dans la mémoire du module"
    );
    assert_eq!(
        said(&text, "large "),
        "1 0xfedcba9876543211 personne",
        "64 bits dans les deux sens, et la fin exacte"
    );
    assert_eq!(said(&text, "tablette "), "0x10521af4 0");
    assert_eq!(said(&text, "toucher "), "1 1 0", "en attente");
    assert_eq!(said(&text, "a_court "), "0 0", "aucun tampon offert");
    assert_eq!(
        said(&text, "sonnette "),
        "1 6",
        "la sonnette lit la file dans la RAM de la page, pendant l'appel"
    );
    assert_eq!(
        said(&text, "rendus "),
        "6 3,0,8192 3,1,24575 1,272,1 1,273,0 1,274,0 0,0,0 1024",
        "un paquet, la ligne 10"
    );
    assert_eq!(said(&text, "isr "), "0x1 0", "l'ISR lu baisse la ligne");
    assert_eq!(said(&text, "molette "), "1");
    assert_eq!(
        said(&text, "cran "),
        "6 12 2,8,4294967295 0,0,0 2,8,4294967295 0,0,0 2,8,4294967295 0,0,0",
        "trois crans, trente millisecondes après la lecture, pas une de moins"
    );
}
