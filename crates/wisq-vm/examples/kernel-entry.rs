//! **Le point d'entrée d'un vrai noyau, exécuté — pas seulement compilé.**
//!
//!     cargo run -p wisq-vm --release --example kernel-entry -- vmlinux.bin [System.map]
//!
//! **Le second argument est facultatif et change tout ce qu'on peut conclure.**
//! Sans lui l'outil rend « rip 0xffffffff81000642 », et la feuille de route a
//! porté une tranche entière un « on ne sait pas si ce `jmp .` est un chemin
//! d'erreur ou une boucle de parking ». Avec la carte du noyau — celle
//! d'Alpine vit dans `boot/System.map-…` de l'ISO *standard*, et il faut
//! **exactement** la version qu'on exécute — la même adresse se lit
//! `__startup_64 + 658` : le rembourrage posé après le retour de la fonction,
//! ce qui n'est ni l'un ni l'autre.
//!
//! `coverage` et `first-region` disent ce qui **se traduit**. Depuis la tranche
//! des MSR, ce n'est plus la même chose que ce qui **s'exécute**, et le dépôt
//! le répète sans l'avoir jamais éprouvé sur autre chose que quelques régions
//! écrites à la main. Cet outil pose l'autre question : la région d'entrée
//! d'Alpine, compilée à sa base virtuelle et posée à son adresse physique,
//! tourne-t-elle sous `web/host.js`, et où s'arrête-t-elle ?
//!
//! **Le montage est fait pour échouer d'abord.** Aucun `boot_params` n'est
//! posé, aucune table de pages, aucun descripteur : le noyau reçoit une machine
//! nue. Ce qui compte n'est pas qu'il aille loin, c'est que l'endroit où il
//! s'arrête ait un **nom**.
//!
//! **Le fichier attendu est la charge utile décompressée**, pas le `bzImage` :
//!
//! ```text
//! python3 -c 'import zlib,sys; d=open(sys.argv[1],"rb").read()[21188:]; \
//!   open(sys.argv[2],"wb").write(zlib.decompressobj(16+zlib.MAX_WBITS).decompress(d))' \
//!   vmlinuz-lts vmlinux.bin
//! ```
//!
//! **Et c'est un ELF.** Chercher le point d'entrée à l'octet 0x90 du fichier
//! décode l'en-tête ELF comme du code — l'erreur a été faite une fois, elle
//! rendait « quatre instructions puis un octet illisible », ce qui ressemblait
//! à un résultat. L'adresse du point d'entrée est **virtuelle** ; le décalage
//! se lit par les en-têtes de programme, et c'est cet outil qui le fait.
use wisq_vm::symbols::Symbols;
use wisq_vm::x86_wasm::{Module, RIP_SLOT};

/// La RAM déclarée, en pages de 64 Kio. **Une puissance de deux**, que le
/// confinement exige, et assez grande pour que le texte du noyau y tienne : il
/// commence à seize mébioctets physiques et en fait une vingtaine.
///
/// Le choix n'est pas neutre et la feuille de route le dit : c'est le **repli**
/// par le masque de la RAM qui fait tomber `0xffffffff81000090` sur
/// `0x1000090`. À quatre gibioctets il ne tomberait plus juste.
const PAGES: u32 = 1024; // 64 Mio

/// Ce que Linux ajoute à une adresse physique de texte pour en faire une
/// adresse virtuelle. `__START_KERNEL_map`, dans ses propres termes.
const KERNEL_MAP: u64 = 0xffff_ffff_8000_0000;

/// Un segment `PT_LOAD` de l'ELF : où il vit, et ce qu'il porte.
struct Load {
    offset: u64,
    virtual_address: u64,
    size: u64,
}

/// Lire les en-têtes de programme. Fait à la main plutôt qu'avec une
/// bibliothèque : cinq champs, et une dépendance de plus pour un outil de
/// mesure serait un coût permanent pour un besoin unique.
fn segments(image: &[u8]) -> Option<(u64, Vec<Load>)> {
    (image.get(..4)? == b"\x7fELF").then_some(())?;
    let word = |at: usize| -> Option<u64> {
        Some(u64::from_le_bytes(image.get(at..at + 8)?.try_into().ok()?))
    };
    let half = |at: usize| -> Option<u16> {
        Some(u16::from_le_bytes(image.get(at..at + 2)?.try_into().ok()?))
    };
    let entry = word(24)?;
    let table = word(32)? as usize;
    let each = half(54)? as usize;
    let count = half(56)? as usize;
    let mut loads = Vec::new();
    for index in 0..count {
        let at = table + index * each;
        let kind = u32::from_le_bytes(image.get(at..at + 4)?.try_into().ok()?);
        if kind != 1 {
            continue;
        }
        loads.push(Load {
            offset: word(at + 8)?,
            virtual_address: word(at + 16)?,
            size: word(at + 32)?,
        });
    }
    Some((entry, loads))
}

/// **Toute adresse imprimée passe par là.** Un relevé qui rend
/// « rip 0xffffffff81000642 » n'apprend rien à personne : la feuille de route a
/// porté pendant une tranche entière un « on ne sait pas si ce `jmp .` est un
/// chemin d'erreur ou une boucle de parking », alors que la carte du noyau
/// exact était dans l'ISO d'Alpine. Avec elle, l'adresse se lit
/// « __startup_64 + 658 » — le rembourrage posé après le retour de la fonction,
/// ce qui n'est ni l'un ni l'autre.
///
/// Sans carte, les adresses sortent nues, comme avant : un outil de diagnostic
/// qui refuse de fonctionner sans son confort casse ce qu'il mesure.
fn name_addresses(text: &str, map: &Symbols) -> String {
    if map.is_empty() {
        return text.to_string();
    }
    text.split_inclusive(char::is_whitespace)
        .map(|word| {
            let bare = word.trim_end();
            let named = bare
                .strip_prefix("0x")
                .and_then(|hex| u64::from_str_radix(hex, 16).ok())
                .map(|address| map.describe(address));
            match named {
                Some(named) => format!("{named}{}", &word[bare.len()..]),
                None => word.to_string(),
            }
        })
        .collect()
}

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("le chemin de la charge utile");
    // **La carte est facultative, et son absence se dit.** Un fichier donné
    // mais illisible serait pire que pas de fichier du tout : l'outil
    // imprimerait des adresses nues en laissant croire qu'elles n'ont pas de
    // nom, alors que c'est la carte qui n'a pas été lue.
    let map = match std::env::args().nth(2) {
        Some(path) => {
            let map = std::fs::read_to_string(&path)
                .map(|text| Symbols::parse(&text))
                .unwrap_or_default();
            if map.is_empty() {
                eprintln!("{path} ne porte aucun symbole : les adresses resteront nues");
            }
            map
        }
        None => Symbols::default(),
    };
    let image = std::fs::read(&path).expect("le fichier");
    let Some((entry, loads)) = segments(&image) else {
        eprintln!(
            "{path} n'est pas un ELF. Ce n'est pas le bzImage qu'il faut donner \
             mais sa charge utile décompressée — voir l'en-tête de ce fichier."
        );
        std::process::exit(1);
    };

    // **Le point d'entrée est physique, les segments sont virtuels.** Linux
    // saute à l'adresse physique après la décompression, avant toute table de
    // pages ; l'ELF, lui, est lié pour le demi-haut.
    let entry_virtual = entry + KERNEL_MAP;
    let Some(text) = loads.iter().find(|load| {
        load.virtual_address <= entry_virtual && entry_virtual < load.virtual_address + load.size
    }) else {
        eprintln!("aucun segment ne porte le point d'entrée 0x{entry_virtual:x}");
        std::process::exit(1);
    };
    let physical = text.virtual_address - KERNEL_MAP;
    let ram = u64::from(PAGES) * 65536;
    println!("point d'entrée : 0x{entry:x} physique, 0x{entry_virtual:x} virtuel");
    println!(
        "texte : 0x{physical:x} physique, {:.1} Mio, décalage 0x{:x} dans le fichier",
        text.size as f64 / (1024.0 * 1024.0),
        text.offset
    );
    let folded = entry_virtual & (ram - 1);
    println!(
        "repli sur {} Mio de RAM : 0x{folded:x} — {}",
        ram / (1024 * 1024),
        if folded == entry {
            "tombe sur l'adresse physique"
        } else {
            "NE TOMBE PAS sur l'adresse physique ; la région ne sera pas trouvée"
        }
    );
    if physical + text.size > ram {
        println!(
            "le texte déborde la RAM déclarée : il en faudrait {:.0} Mio",
            (physical + text.size) as f64 / (1024.0 * 1024.0)
        );
    }

    // **Traduire la région qui commence à une adresse virtuelle**, en allant
    // chercher ses octets là où le segment les porte.
    // **L'emplacement compte.** L'hôte donne à chaque région une place dans sa
    // table de blocs, et la région y pose les siens. Compiler tout le monde à
    // l'emplacement zéro les fait s'écraser : l'hôte s'en aperçoit, dit « la
    // région n'a posé aucun bloc à l'emplacement N », et c'est cette garde qui
    // a attrapé la première version de cet outil.
    let compile = |at: u64, slot: u32| -> Result<Vec<u8>, String> {
        if at < text.virtual_address || at >= text.virtual_address + text.size {
            return Err("hors du segment de texte".to_string());
        }
        let from = (at - text.virtual_address + text.offset) as usize;
        let window = &image[from..(from + 16384).min(image.len())];
        Module::resolving_or_why(window, at, 0, slot, PAGES).map_err(|why| format!("{why:?}"))
    };

    let Some(bun) = ["/root/.bun/bin/bun", "bun"].into_iter().find(|path| {
        std::process::Command::new(path)
            .arg("--version")
            .output()
            .is_ok()
    }) else {
        println!("Bun est absent : l'exécution n'est pas mesurée. Elle n'est pas nulle, elle est inconnue.");
        return;
    };

    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("la racine")
        .to_path_buf();
    let scratch = std::env::temp_dir().join(format!("wisq-kernel-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).expect("répertoire de travail");
    // Le texte entier, pour que les sauts internes trouvent quelque chose
    // plutôt que des zéros — ce qui ferait décoder du vide comme du code.
    let text_path = scratch.join("texte.bin");
    let end = (text.offset + text.size).min(image.len() as u64) as usize;
    std::fs::write(&text_path, &image[text.offset as usize..end]).expect("le texte");

    // **Une région de plus par tour, et on recommence depuis le début.**
    //
    // Le pilote ne peut pas appeler l'émetteur : il est en JavaScript, et
    // l'émetteur en Rust. Alors chaque tour lui donne l'ensemble des régions
    // déjà traduites, la machine repart du point d'entrée, et l'adresse qu'elle
    // réclame en s'arrêtant devient la région du tour suivant.
    //
    // **C'est déterministe**, donc chaque tour va au moins aussi loin que le
    // précédent : la machine est neuve, le texte est reposé, rien ne persiste.
    // C'est quadratique et ça n'a aucune importance — l'outil mesure une
    // distance, pas une vitesse.
    let mut regions: Vec<(u64, Vec<u8>)> = Vec::new();
    match compile(entry_virtual, 0) {
        Ok(module) => regions.push((entry_virtual, module)),
        Err(why) => {
            println!("la région d'entrée ne se traduit pas : {why}");
            std::process::exit(1);
        }
    }
    println!();

    const ROUNDS: usize = 64;
    let mut last = String::new();
    for round in 1..=ROUNDS {
        let mut listing = String::new();
        for (index, (at, module)) in regions.iter().enumerate() {
            let path = scratch.join(format!("r{index}.wasm"));
            std::fs::write(&path, module).expect("le module");
            listing.push_str(&format!("[{at}n,{:?}],", path.to_string_lossy()));
        }
        let driver = scratch.join("d.mjs");
        std::fs::write(
            &driver,
            format!(
                r#"
import {{ machine }} from {host:?};
import {{ readFileSync }} from "fs";

const connues = new Map([{listing}]);
let manquante = null;
let place = 0;
const vm = machine({{
  translate: async (address, slot) => {{
    const path = connues.get(address);
    if (path !== undefined) return readFileSync(path);
    // **L'adresse qu'on ne sait pas servir est le résultat du tour.**
    if (manquante === null) {{
      manquante = address;
      place = slot;
    }}
    return null;
  }},
  pages: {pages},
}});
new Uint8Array(vm.memory.buffer).set(readFileSync({text:?}), {physical});
vm.globals[{rip}].value = {entry}n;
const why = await vm.run({{ budget: 1n << 24n, rounds: 4096 }});
const lire = (at) => BigInt.asUintN(64, vm.globals[at].value);
console.log("arret " + why.stopped);
console.log("manquante " + (manquante === null ? "aucune" : "0x" + manquante.toString(16)));
console.log("emplacement " + place);
console.log("rip 0x" + lire({rip}).toString(16));
console.log("rsp 0x" + lire(4).toString(16));
"#,
                host = root.join("web/host.js").to_string_lossy(),
                text = text_path.to_string_lossy(),
                physical = physical,
                pages = PAGES,
                rip = RIP_SLOT,
                entry = entry_virtual,
            ),
        )
        .expect("le pilote");

        let output = std::process::Command::new(bun)
            .arg("run")
            .arg(&driver)
            .output()
            .expect("bun");
        let text_out = String::from_utf8_lossy(&output.stdout).to_string();
        let errors = String::from_utf8_lossy(&output.stderr);
        if !errors.is_empty() {
            println!("tour {round} : le pilote a écrit en erreur");
            print!("{errors}");
            break;
        }
        last = text_out.clone();
        let line = |name: &str| -> Option<String> {
            text_out
                .lines()
                .find_map(|l| l.strip_prefix(name))
                .map(|rest| rest.trim().to_string())
        };
        let missing = line("manquante ").unwrap_or_default();
        if missing == "aucune" {
            println!(
                "tour {round} : {} régions, et plus rien à traduire — {}",
                regions.len(),
                line("arret ").unwrap_or_default()
            );
            break;
        }
        let Some(at) = missing
            .strip_prefix("0x")
            .and_then(|hex| u64::from_str_radix(hex, 16).ok())
        else {
            println!("tour {round} : adresse illisible « {missing} »");
            break;
        };
        let place: u32 = line("emplacement ")
            .and_then(|text| text.parse().ok())
            .unwrap_or(0);
        match compile(at, place) {
            Ok(module) => {
                println!(
                    "tour {round} : {} régions traduites, la machine réclame {} \
                     à l'emplacement {place} ({} octets)",
                    regions.len(),
                    map.describe(at),
                    module.len()
                );
                regions.push((at, module));
            }
            Err(why) => {
                println!(
                    "tour {round} : {} régions traduites, et {} **ne se traduit pas** — {why}",
                    regions.len(),
                    map.describe(at)
                );
                break;
            }
        }
        if round == ROUNDS {
            println!("tour {round} : la limite de tours est atteinte, la machine avançait encore");
        }
    }
    println!();
    print!("{}", name_addresses(&last, &map));
    let _ = std::fs::remove_dir_all(&scratch);
}
