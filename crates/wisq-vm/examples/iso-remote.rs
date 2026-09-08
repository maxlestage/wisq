// **La même lecture, sur une image qu'on ne télécharge pas.**
//
//     cargo run -p wisq-vm --release --example iso-remote -- https://…/une.iso
//
// Une image d'installation de bureau pèse six gigaoctets. Ce conteneur n'en a
// pas la place, un téléphone non plus, et pourtant c'est **sur une vraie image
// que le lecteur doit être jugé** : les fixtures construites ici disent ce
// qu'on a pensé, pas ce que les distributions écrivent. Le défaut qui a envoyé
// Omarchy sur le mauvais cœur ne se voyait sur aucune d'elles.
//
// Le seul point d'entrée du lecteur est `Bytes::read(at, into)`. Une requête
// HTTP à intervalle en est une implémentation, et il ne passe alors sur le
// réseau que les secteurs demandés — quelques centaines de kibioctets pour
// parcourir une image entière.
//
// **Le cache n'est pas un raffinement.** Sans lui, chaque enregistrement de
// répertoire relu coûterait un aller-retour : le parcours d'une image passerait
// de secondes à heures, et personne ne s'en servirait.
use std::cell::RefCell;
use std::collections::HashMap;
use std::process::Command;

use wisq_vm::iso9660::{Bytes, Iso, Recipe};

/// La taille d'une tranche demandée au serveur. Un secteur ISO fait deux
/// kibioctets ; en demander soixante-quatre d'un coup amortit la latence sans
/// rapatrier l'image.
const CHUNK: u64 = 128 * 1024;

struct OverHttp {
    url: String,
    chunks: RefCell<HashMap<u64, Vec<u8>>>,
    fetched: RefCell<u64>,
}

impl OverHttp {
    fn new(url: &str) -> Self {
        OverHttp {
            url: url.to_string(),
            chunks: RefCell::new(HashMap::new()),
            fetched: RefCell::new(0),
        }
    }

    /// La tranche qui contient cet octet, rapatriée une seule fois.
    fn chunk(&self, index: u64) -> Option<Vec<u8>> {
        if let Some(have) = self.chunks.borrow().get(&index) {
            return Some(have.clone());
        }
        let first = index * CHUNK;
        let last = first + CHUNK - 1;
        // `curl` plutôt qu'une bibliothèque : il honore le mandataire de cet
        // environnement, et cet outil est un instrument de diagnostic, pas un
        // chemin d'exécution.
        let out = Command::new("curl")
            .args([
                "-sS",
                "--fail",
                "-r",
                &format!("{first}-{last}"),
                "--output",
                "-",
                &self.url,
            ])
            .output()
            .ok()?;
        if !out.status.success() || out.stdout.is_empty() {
            return None;
        }
        *self.fetched.borrow_mut() += out.stdout.len() as u64;
        self.chunks.borrow_mut().insert(index, out.stdout.clone());
        Some(out.stdout)
    }
}

impl Bytes for OverHttp {
    fn read(&self, at: u64, into: &mut [u8]) -> bool {
        let mut done = 0usize;
        while done < into.len() {
            let position = at + done as u64;
            let index = position / CHUNK;
            let Some(chunk) = self.chunk(index) else {
                return false;
            };
            let inside = (position % CHUNK) as usize;
            if inside >= chunk.len() {
                return false;
            }
            let take = (chunk.len() - inside).min(into.len() - done);
            into[done..done + take].copy_from_slice(&chunk[inside..inside + take]);
            done += take;
        }
        true
    }
}

fn main() {
    let Some(url) = std::env::args().nth(1) else {
        eprintln!("usage : iso-remote <url d'une image> [chemin à afficher]");
        std::process::exit(2);
    };
    // Un second argument affiche un fichier de l'image au lieu de la parcourir :
    // c'est ainsi qu'on lit la recette telle que la distribution l'a écrite,
    // plutôt que telle qu'on l'imagine.
    let show = std::env::args().nth(2);
    let source = OverHttp::new(&url);
    let Some(iso) = Iso::open(source) else {
        eprintln!("ce n'est pas une image ISO 9660 lisible");
        std::process::exit(1);
    };
    println!("étiquette : « {} »", iso.volume_label());

    if let Some(path) = show {
        match iso.find(&path).and_then(|entry| iso.read(&entry, 1 << 20)) {
            None => println!("\n{path} : introuvable ou illisible"),
            Some(bytes) => println!("\n----- {path} -----\n{}", String::from_utf8_lossy(&bytes)),
        }
        return;
    }

    match Recipe::of(&iso) {
        None => println!("\naucune recette de démarrage trouvée"),
        Some(recipe) => {
            println!("\nrecette lue dans {}", recipe.from);
            println!("  noyau      : {}", recipe.kernel);
            println!("  initramfs  : {:?}", recipe.initrd);
            println!("  arguments  : « {} »", recipe.command_line);

            // **Ce que le noyau annoncé est vraiment**, jugé sur ses premiers
            // octets : c'est cette réponse-là qui décide du cœur, et c'est
            // elle qui manquait.
            match iso.find(&recipe.kernel) {
                None => println!("\n  ce chemin ne mène nulle part dans l'image"),
                Some(entry) => {
                    println!("\n  le fichier existe, {} octets", entry.size);
                    // **L'en-tête seul, lu là où le fichier commence.**
                    // `Iso::read` rend un fichier entier sous un plafond : un
                    // noyau de dix-sept mébioctets le dépasse, et le premier
                    // jet de cet outil concluait « illisible » sur un fichier
                    // parfaitement lisible. Ce qui décide du cœur tient dans
                    // les premiers octets, et c'est eux qu'on demande.
                    let mut head = vec![0u8; 256 * 1024];
                    if iso.source().read(u64::from(entry.start) * 2048, &mut head) {
                        // **Ce que l'application voit vraiment** : elle ne lit
                        // que 40 Kio pour décider (`KernelImageKind.bytesNeeded`).
                        // Si la charge utile compressée commence au-delà, elle
                        // conclut « compressé, architecture inconnue » — donc
                        // pas de cœur x86, donc la machine RISC-V.
                        for budget in [40 * 1024usize, head.len()] {
                            println!(
                                "  sur {:>6} Kio : {:?}",
                                budget / 1024,
                                wisq_vm::kernel_image::recognise(&head[..budget])
                            );
                        }
                        // Les premiers octets en clair : quand le
                        // reconnaisseur dit « je ne sais pas », c'est eux qui
                        // disent pourquoi.
                        let show: Vec<String> =
                            head[..16].iter().map(|b| format!("{b:02x}")).collect();
                        println!("  16 premiers octets : {}", show.join(" "));
                        println!(
                            "  octets 512-520     : {}",
                            head[512..520]
                                .iter()
                                .map(|b| format!("{b:02x}"))
                                .collect::<Vec<_>>()
                                .join(" ")
                        );
                    } else {
                        println!("  illisible");
                    }
                }
            }
        }
    }
}
