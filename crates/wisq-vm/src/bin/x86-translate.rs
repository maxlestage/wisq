//! **Traduire une région, une seule, et rendre les octets du module.**
//!
//!     x86-translate <pages de 64 Kio> <adresse invitée> <emplacement>
//!
//! **La fenêtre arrive sur l'entrée standard.** C'est le changement de #254 et
//! ce n'est pas une commodité : les octets d'une région ne sont pas dans le
//! fichier du noyau, ils sont dans la **mémoire de l'invité**. Le noyau y
//! réécrit son propre texte — alternatives, retpolines, appels statiques,
//! `ftrace` — et l'espace utilisateur n'y arrive qu'après avoir été déballé
//! d'une archive. Ce binaire lisait l'image ELF ; sur un vrai noyau d'Alpine,
//! **15 761 des 16 189 fenêtres traduites différaient** de ce que la mémoire
//! portait à la même adresse. Il traduisait donc un texte que la machine
//! n'exécute pas.
//!
//! L'hôte, lui, a la mémoire : `web/host.js` passe déjà la fenêtre en
//! troisième argument de `translate`. Elle n'avait personne pour la prendre.
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
//! est la même — une adresse et des octets entrent, un module sort — et c'est
//! tout ce que `web/host.js` voit.
//!
//! **Les codes de sortie sont le protocole** : 0 avec le module sur la sortie
//! standard ; 2 quand l'émetteur refuse, la raison sur la sortie d'erreur ;
//! 3 quand il n'y a **aucun octet** à traduire ; 1 quand l'appel lui-même est
//! mal formé. Un pilote qui confondrait 2 et 3 chercherait une instruction
//! manquante là où il n'y a rien du tout.
//!
//! **Le manifeste a disparu avec la lecture du fichier.** Il portait le chemin
//! de l'image et la table des segments chargeables, qui ne servaient qu'à
//! retrouver un décalage dans ce fichier. Le nombre de pages, lui, reste — il
//! décide du masque de confinement du module — et il tient dans un argument.
use std::io::{Read, Write};

use wisq_vm::x86_wasm::Module;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let [_, pages, address, slot] = args.as_slice() else {
        eprintln!("usage: x86-translate <pages> <adresse> <emplacement>");
        std::process::exit(1);
    };
    let (Ok(pages), Ok(at), Ok(slot)) = (
        pages.trim().parse::<u32>(),
        parse(address),
        slot.parse::<u32>(),
    ) else {
        eprintln!("les pages, l'adresse et l'emplacement doivent être des nombres");
        std::process::exit(1);
    };

    // **Toute l'entrée, et l'hôte décide de sa longueur.** Elle n'est pas
    // bornée ici : c'est `web/host.js` qui sait ce qu'une fenêtre coûte, et
    // qui la raccourcit quand la page de l'invité s'arrête avant.
    let mut window = Vec::new();
    if let Err(why) = std::io::stdin().lock().read_to_end(&mut window) {
        eprintln!("la fenêtre ne se lit pas : {why}");
        std::process::exit(1);
    }
    if window.is_empty() {
        eprintln!("aucun octet : la fenêtre est vide");
        std::process::exit(3);
    }

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
