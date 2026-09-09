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

/// **Le nombre de pages de 64 Kio du confinement.**
///
/// Cet outil a mesuré la forme *libre* pendant toute une série, et
/// l'application n'exécute que la forme *confinée et liée*. Depuis la
/// pagination les deux divergent : la marche dans les tables n'existe que sous
/// confinement, donc l'écriture de `cr3` n'y est acceptée que là. Sur le point
/// d'entrée d'Alpine, l'écart n'est pas théorique — la forme libre s'arrête à
/// l'octet 89 sur `mov …,%cr3`, que la confinée traduit.
///
/// La valeur ne change pas ce qui compile : dans `build`, le nombre de pages
/// sert à refuser ce qui n'est pas une puissance de deux, puis à graver un
/// masque et un minimum de mémoire déclaré. C'est le confinement qui décide,
/// pas sa taille. Soixante-quatre mébioctets, comme `examples/kernel-entry.rs`.
const PAGES: u32 = 1024;

/// L'emplacement dans la table partagée. Cet outil ne charge rien — il demande
/// une traduction et jette le module — donc aucune région n'en écrase une
/// autre, et zéro convient.
const SLOT: u32 = 0;

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

    // **Et ce que l'émetteur en fait**, ce qui est une autre question — posée
    // deux fois, parce qu'il y a deux émetteurs.
    //
    // La forme *confinée et liée* est celle que l'application exécute :
    // `LocalDesktop` passe par `DesktopTranslator.resolvingRegion`, donc par
    // `Module::resolving`. C'est elle le verdict.
    //
    // La forme *libre* est celle que cet outil mesurait avant, et elle reste
    // imprimée à côté. Pas par nostalgie : depuis la pagination les deux
    // n'acceptent plus la même chose, et **c'est un désaccord entre deux outils
    // qui a révélé que celui-ci mesurait la mauvaise** — pas une relecture. Un
    // outil qui affiche les deux ne peut plus cacher l'écart.
    verdict(
        "confinée (ce que l'application exécute)",
        Module::resolving_or_why(&bytes, ENTRY, 0, SLOT, PAGES),
        &bytes,
    );
    verdict("libre", Module::region_or_why(&bytes, ENTRY, 0), &bytes);
}

/// Ce qu'une mise en forme a fait de la région, en trois lignes au plus.
fn verdict(shape: &str, outcome: Result<Vec<u8>, Refused>, bytes: &[u8]) {
    match outcome {
        Ok(module) => println!(
            "traduction {shape} : la région entière, {} octets de module",
            module.len()
        ),
        Err(Refused::CannotDecode { at }) => {
            println!("traduction {shape} : arrêtée faute de savoir **lire** l'octet {at}");
            println!(
                "  adresse 0x{:x}, octets {}",
                ENTRY + at as u64,
                show(bytes, at)
            );
        }
        Err(Refused::CannotTranslate { at }) => {
            println!("traduction {shape} : l'octet {at} se **lit** mais ne se **produit** pas");
            if let Some(step) = decode(&bytes[at..]) {
                println!("  {:?}, largeur {:?}", step.op, step.width);
            }
            println!(
                "  adresse 0x{:x}, octets {}",
                ENTRY + at as u64,
                show(bytes, at)
            );
        }
        Err(other) => println!("traduction {shape} : refusée autrement — {other:?}"),
    }
}

fn show(bytes: &[u8], at: usize) -> String {
    bytes[at..(at + 8).min(bytes.len())]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(" ")
}
