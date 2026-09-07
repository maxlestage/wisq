//! **Jusqu'où va le point d'entrée d'un noyau, et qu'est-ce qui l'arrête ?**
//!
//! La couverture moyenne ne dit pas si un noyau démarre : il n'exécute pas une
//! fonction moyenne, il exécute la **première**. Cet outil pose l'autre
//! question, celle qui a fait passer la tranche 2 d'une mesure globale à une
//! liste de manques nommés.
//!
//! **Deux refus, deux travaux différents.** `CannotDecode` dit « je ne sais pas
//! *lire* ces octets » — une table à compléter. `CannotTranslate` dit « je les
//! lis, je ne sais pas les *produire* » — une sémantique à écrire. Les
//! confondre ferait croire qu'il reste des octets illisibles là où il reste une
//! décision à prendre, et cet outil l'a fait une fois : il annonçait l'octet
//! 1512 quand la première chose qui bloquait vraiment était à l'octet 35.
//!
//!     cargo run -p wisq-vm --release --example first-region -- entree.bin
use wisq_vm::x86::decode;
use wisq_vm::x86_wasm::{Module, Refused};

/// L'adresse du point d'entrée d'un noyau x86-64 chargé à un mégaoctet — la
/// valeur que porte l'en-tête ELF d'Alpine. Elle ne change rien au verdict, et
/// tout aux adresses imprimées.
const ENTRY: u64 = 0x1000090;

fn main() {
    let path = std::env::args().nth(1).expect("le chemin");
    let bytes = std::fs::read(&path).expect("le fichier");

    // **Ce que le décodeur lit, en ligne droite.** Ce compte-là ne dépend pas
    // de l'émetteur, et c'est lui qui bouge quand une table se complète.
    let mut at = 0usize;
    let mut read = 0usize;
    while at < bytes.len() {
        match decode(&bytes[at..]) {
            Some(step) => {
                at += step.length.max(1);
                read += 1;
            }
            None => break,
        }
    }
    if at >= bytes.len() {
        println!("lecture : les {read} instructions du tampon se lisent toutes");
    } else {
        println!("lecture : {read} instructions, puis l'octet {at} ne se lit pas");
        println!(
            "  adresse 0x{:x}, octets {}",
            ENTRY + at as u64,
            show(&bytes, at)
        );
    }

    // **Et ce que l'émetteur en fait**, ce qui est une autre question.
    match Module::region_or_why(&bytes, ENTRY, 0) {
        Ok(module) => println!(
            "traduction : la région entière, {} octets de module",
            module.len()
        ),
        Err(Refused::CannotDecode { at }) => {
            println!("traduction : arrêtée faute de savoir **lire** l'octet {at}");
            println!(
                "  adresse 0x{:x}, octets {}",
                ENTRY + at as u64,
                show(&bytes, at)
            );
        }
        Err(Refused::CannotTranslate { at }) => {
            println!("traduction : l'octet {at} se **lit** mais ne se **produit** pas");
            if let Some(step) = decode(&bytes[at..]) {
                println!("  {:?}, largeur {:?}", step.op, step.width);
            }
            println!(
                "  adresse 0x{:x}, octets {}",
                ENTRY + at as u64,
                show(&bytes, at)
            );
        }
        Err(other) => println!("traduction : refusée autrement — {other:?}"),
    }
}

fn show(bytes: &[u8], at: usize) -> String {
    bytes[at..(at + 8).min(bytes.len())]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(" ")
}
