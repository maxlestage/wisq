//! **Traduire une région, une seule, et rendre les octets du module.**
//!
//!     x86-translate <manifeste> <adresse invitée> <emplacement>
//!
//! **Pourquoi un binaire plutôt qu'une fonction.** L'émetteur est en Rust ; la
//! boucle hôte qui rencontre les adresses inconnues est en JavaScript, sous
//! Bun. Les pilotes de mesure de ce dépôt contournaient l'écart en **rejouant
//! le démarrage depuis le début** à chaque nouvelle région — une exécution de
//! Bun par région, donc un coût quadratique : cinq secondes par tour à la
//! 512ᵉ région d'un vrai noyau, une vingtaine d'heures pour en atteindre
//! quatre mille. Ce que le pilote ne pouvait pas appeler, il peut le
//! **lancer** : `Bun.spawnSync` sur ce binaire rend un module en quelques
//! millisecondes, et la mesure redevient linéaire.
//!
//! **Ce n'est pas ce que fait l'application.** Là-bas l'émetteur vit dans le
//! processus hôte et répond par message, sans processus ni fichier. La forme
//! est la même — une adresse entre, des octets sortent — et c'est tout ce que
//! `web/host.js` voit.
//!
//! **Le manifeste**, parce qu'un noyau n'est pas un fichier plat :
//!
//! ```text
//! <chemin de l'image>
//! <pages de 64 Kio de la RAM déclarée>
//! <adresse physique> <décalage dans le fichier> <taille> …une ligne par segment
//! ```
//!
//! Il est écrit par celui qui a lu l'ELF, une fois. Le refaire ici à chaque
//! appel rouvrirait trente-cinq mébioctets par région.
//!
//! **Les codes de sortie sont le protocole** : 0 avec le module sur la sortie
//! standard ; 2 quand l'émetteur refuse, la raison sur la sortie d'erreur ;
//! 3 quand l'adresse ne tombe dans aucun segment ; 1 quand l'appel lui-même est
//! mal formé. Un pilote qui confondrait 2 et 3 chercherait une instruction
//! manquante là où il n'y a que des octets absents.
use std::io::{Read, Seek, SeekFrom, Write};

use wisq_vm::x86_wasm::Module;

/// **Ce que le traducteur lit devant l'adresse demandée.**
///
/// La même fenêtre que `examples/kernel-entry.rs` prenait : seize kibioctets.
/// Elle décide de ce que la découverte peut avaler dans une région, donc du
/// nombre de régions — la changer déplacerait toutes les mesures, et c'est
/// pour ça qu'elle est écrite une fois, ici, plutôt que passée en argument.
const WINDOW: usize = 16384;

/// Un segment chargeable, tel que le manifeste le décrit.
struct Segment {
    physical: u64,
    offset: u64,
    size: u64,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let [_, manifest, address, slot] = args.as_slice() else {
        eprintln!("usage: x86-translate <manifeste> <adresse> <emplacement>");
        std::process::exit(1);
    };
    let (Ok(at), Ok(slot)) = (parse(address), slot.parse::<u32>()) else {
        eprintln!("l'adresse et l'emplacement doivent être des nombres");
        std::process::exit(1);
    };

    let text = match std::fs::read_to_string(manifest) {
        Ok(text) => text,
        Err(why) => {
            eprintln!("le manifeste ne se lit pas : {why}");
            std::process::exit(1);
        }
    };
    let mut lines = text.lines();
    let (Some(image), Some(pages)) = (lines.next(), lines.next()) else {
        eprintln!("le manifeste doit porter au moins le chemin et le nombre de pages");
        std::process::exit(1);
    };
    let Ok(pages) = pages.trim().parse::<u32>() else {
        eprintln!("le nombre de pages doit être un nombre");
        std::process::exit(1);
    };
    let segments: Vec<Segment> = lines
        .filter(|line| !line.trim().is_empty())
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            Some(Segment {
                physical: parse(fields.next()?).ok()?,
                offset: parse(fields.next()?).ok()?,
                size: parse(fields.next()?).ok()?,
            })
        })
        .collect();

    // **L'adresse est repliée, comme l'hôte le fait pour lire.** `web/host.js`
    // va chercher ses octets à `address & (ram - 1)` ; sans le même repli ici,
    // toute adresse virtuelle serait « hors de tout segment » — et un noyau
    // bascule à l'adressage virtuel dès qu'il a chargé CR3.
    let folded = Module::fold(at, pages);
    let Some(segment) = segments
        .iter()
        .find(|load| folded >= load.physical && folded < load.physical + load.size)
    else {
        eprintln!("hors de tout segment chargeable");
        std::process::exit(3);
    };

    let from = folded - segment.physical + segment.offset;
    let mut file = match std::fs::File::open(image) {
        Ok(file) => file,
        Err(why) => {
            eprintln!("l'image ne s'ouvre pas : {why}");
            std::process::exit(1);
        }
    };
    if file.seek(SeekFrom::Start(from)).is_err() {
        eprintln!("le décalage {from} est hors de l'image");
        std::process::exit(1);
    }
    // **Une lecture courte n'est pas une erreur** : la fenêtre déborde la fin
    // du fichier dès la dernière région, et c'est le cas normal.
    let mut window = vec![0u8; WINDOW];
    let mut filled = 0;
    while filled < WINDOW {
        match file.read(&mut window[filled..]) {
            Ok(0) => break,
            Ok(read) => filled += read,
            Err(why) => {
                eprintln!("l'image ne se lit pas : {why}");
                std::process::exit(1);
            }
        }
    }
    window.truncate(filled);

    match Module::resolving_or_why(&window, at, 0, slot, pages) {
        Ok(module) => {
            let mut out = std::io::stdout().lock();
            if out.write_all(&module).and_then(|()| out.flush()).is_err() {
                std::process::exit(1);
            }
        }
        Err(why) => {
            eprintln!("{why:?}");
            std::process::exit(2);
        }
    }
}

/// Un nombre en décimal, ou en hexadécimal s'il porte le préfixe `0x`.
fn parse(text: &str) -> Result<u64, std::num::ParseIntError> {
    match text.trim().strip_prefix("0x") {
        Some(hex) => u64::from_str_radix(hex, 16),
        None => text.trim().parse(),
    }
}
