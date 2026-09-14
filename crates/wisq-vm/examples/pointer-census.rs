//! **Recompter les pointeurs d'une image de noyau, plutôt que citer un nombre.**
//!
//! ```text
//! cargo run -p wisq-vm --release --example pointer-census -- <noyau>
//! ```
//!
//! Le relevé que `docs/DEMARRAGE.md` cite pour dire qu'un repli d'adresses ne
//! mènera jamais un noyau là où il s'attend à vivre. Le document portait deux
//! nombres sans la commande qui les produit ; c'est celle-ci.

use std::env;
use std::fs;
use std::process::ExitCode;

use wisq_vm::census::Census;

fn main() -> ExitCode {
    let Some(chemin) = env::args().nth(1) else {
        eprintln!("usage : pointer-census <image de noyau>");
        return ExitCode::FAILURE;
    };
    let octets = match fs::read(&chemin) {
        Ok(octets) => octets,
        Err(erreur) => {
            eprintln!("{chemin} illisible : {erreur}");
            return ExitCode::FAILURE;
        }
    };
    let Some(recensement) = Census::of(&octets) else {
        eprintln!(
            "{chemin} fait {} octets : pas un mot aligné de huit, rien à recenser",
            octets.len()
        );
        return ExitCode::FAILURE;
    };

    println!(
        "{} octets, {} mots alignés de huit{}",
        octets.len(),
        recensement.words(),
        match recensement.tail() {
            0 => String::new(),
            n => format!(" ({n} octets de queue, hors du compte)"),
        }
    );
    println!(
        "adresses noyau hautes (0xffffffff8…) : {}",
        recensement.high()
    );
    println!(
        "adresses de chargement physique [0x1000000, 0x4000000) : {}",
        recensement.low()
    );
    match recensement.low() {
        0 => println!("aucune adresse basse : le rapport ne veut rien dire ici"),
        bas => println!(
            "soit {:.1} fois plus de hautes que de basses",
            recensement.high() as f64 / bas as f64
        ),
    }
    ExitCode::SUCCESS
}
