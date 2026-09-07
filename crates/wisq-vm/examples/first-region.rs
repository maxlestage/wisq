//! **Jusqu'où va un noyau avant que l'émetteur ne s'arrête ?**
//!
//! La couverture moyenne — 98,2 % des entrées de fonction d'un noyau Linux —
//! ne répond pas à cette question, et c'est la seule qui compte pour démarrer :
//! un noyau n'exécute pas une fonction moyenne, il exécute la **première**.
//!
//! Cet outil prend les octets d'un point d'entrée et dit où la région s'arrête,
//! après combien d'instructions, et sur quels octets. La réponse a fait passer
//! cette tranche de « il faut mesurer la couverture » à « il manque quatre
//! instructions privilégiées » : le point d'entrée d'Alpine 6.6.134 s'arrêtait
//! après **sept** instructions, sur `wrmsr`.
//!
//!     cargo run -p wisq-vm --release --example first-region -- <octets>
//!
//! Les octets s'extraient du `vmlinux` décompressé, à l'offset que donne son
//! en-tête ELF. `kernel_image` refuse un bzImage avant d'en arriver là.
use wisq_vm::x86::decode;
use wisq_vm::x86_wasm::{Module, Refused};

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("le chemin des octets d'entrée");
    let bytes = std::fs::read(&path).expect("le fichier");
    // L'adresse d'un noyau Linux x86-64 chargé là où le protocole d'amorçage le
    // met. Elle ne change rien au décodage ; elle rend les adresses lisibles.
    let base = 0x1000090u64;
    match Module::region_or_why(&bytes, base, 0) {
        Ok(_) => println!("la région d'entrée se traduit entièrement"),
        Err(Refused::CannotTranslate { at }) | Err(Refused::CannotDecode { at }) => {
            println!("arrêtée à l'octet {at} (adresse 0x{:x})", base + at as u64);
            let (mut cursor, mut n) = (0usize, 0usize);
            while cursor < at {
                match decode(&bytes[cursor..]) {
                    Some(step) => {
                        n += 1;
                        cursor += step.length.max(1);
                    }
                    None => break,
                }
            }
            println!("soit après {n} instructions");
            // **Nommer l'instruction quand on le peut.** Un `CannotTranslate`
            // porte un nom — le décodeur l'a lue — ; un `CannotDecode` n'en a
            // pas, et c'est précisément ce qui rendait la liste des manques
            // impossible à suivre.
            match decode(&bytes[at..]) {
                Some(step) => println!("l'instruction qui arrête : {:?}", step.op),
                None => println!("l'instruction qui arrête n'est pas décodée du tout"),
            }
            let end = (at + 8).min(bytes.len());
            let shown: Vec<String> = bytes[at..end].iter().map(|b| format!("{b:02x}")).collect();
            println!("ses octets : {}", shown.join(" "));
        }
        Err(other) => println!("refusée autrement : {other:?}"),
    }
}
