// **Ce qu'il y a dans une image de disque optique, et comment elle démarre.**
//
//     cargo run -p wisq-vm --release --example iso -- une-image.iso
//
// Cet outil existe pour que la vérification soit **refaisable**. Le lecteur a
// été conçu sur `alpine-virt 3.20.3` — 61 Mo, téléchargé et parcouru avant
// qu'une ligne soit écrite — et les tests, eux, bâtissent un ISO minuscule :
// la CI n'a pas soixante mégaoctets à prendre, et un fichier construit permet
// de mentir exprès. Ni l'un ni l'autre ne remplace l'autre, et celui-ci est
// celui qui juge une vraie image.
//
// L'image est lue **par tranches depuis le disque**, jamais tenue en mémoire :
// une image d'installation pèse des gibioctets, et un téléphone n'a pas ça.
use std::cell::RefCell;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use wisq_vm::iso9660::{Bytes, Iso, Recipe};

struct OnDisk(RefCell<File>);

impl Bytes for OnDisk {
    fn read(&self, at: u64, into: &mut [u8]) -> bool {
        let mut file = self.0.borrow_mut();
        file.seek(SeekFrom::Start(at)).is_ok() && file.read_exact(into).is_ok()
    }
}

/// Le contenu, jusqu'à trois niveaux : au-delà, une image d'installation
/// noie sa propre recette sous des milliers de paquets.
fn walk<B: Bytes>(iso: &Iso<B>, at: &wisq_vm::iso9660::Entry, path: &str, depth: usize) {
    if depth > 3 {
        return;
    }
    for entry in iso.list(at) {
        let full = format!("{path}/{}", entry.name);
        if entry.directory {
            walk(iso, &entry, &full, depth + 1);
        } else {
            println!("{:>10}  {full}", entry.size);
        }
    }
}

fn main() {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("usage : iso <image.iso>");
        std::process::exit(2);
    };
    let Ok(file) = File::open(&path) else {
        eprintln!("{path} ne s'ouvre pas");
        std::process::exit(2);
    };
    let Some(iso) = Iso::open(OnDisk(RefCell::new(file))) else {
        eprintln!("{path} n'est pas une image ISO 9660");
        std::process::exit(2);
    };
    println!("étiquette : « {} »", iso.volume_label());
    let root = iso.root().clone();
    walk(&iso, &root, "", 0);
    match Recipe::of(&iso) {
        Some(recipe) => {
            println!("\nrecette lue dans {}", recipe.from);
            println!("  noyau      : {}", recipe.kernel);
            println!("  initramfs  : {:?}", recipe.initrd);
            println!("  arguments  : « {} »", recipe.command_line);
            let kernel = iso
                .find(&recipe.kernel)
                .and_then(|entry| iso.read(&entry, 128 << 20))
                .expect("le noyau");
            println!("\nnoyau extrait : {} octets", kernel.len());
            match wisq_vm::kernel_image::recognise(&kernel) {
                wisq_vm::kernel_image::KernelImage::Compressed { how, at } => {
                    println!(
                        "  reconnu : bzImage, charge utile en {} à l'octet {at}",
                        how.name()
                    )
                }
                other => println!("  reconnu : {other:?}"),
            }
        }
        None => println!("\naucune recette trouvée"),
    }
}
