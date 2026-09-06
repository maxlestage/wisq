// Combien du vrai noyau le compilateur accepte-t-il ?
use std::fs;
use wisq_vm::x86::decode;
use wisq_vm::x86_wasm::Module;

fn main() {
    let path = std::env::args().nth(1).expect("le chemin du noyau");
    let bytes = fs::read(&path).expect("le noyau");
    // Le texte du noyau : on part du début et on désassemble linéairement pour
    // compter, puis on compile des régions depuis chaque début de bloc.
    let mut at = 0usize;
    let (mut decoded, mut unknown) = (0usize, 0usize);
    let mut refused: std::collections::BTreeMap<String, usize> = Default::default();
    // Un échantillon : les huit premiers mégaoctets de texte suffisent à donner
    // la proportion, et le fichier entier prendrait des minutes.
    let limit = bytes.len().min(8 << 20);
    while at < limit {
        match decode(&bytes[at..]) {
            Some(step) => {
                decoded += 1;
                at += step.length.max(1);
            }
            None => {
                unknown += 1;
                *refused.entry(format!("{:02x}", bytes[at])).or_default() += 1;
                at += 1;
            }
        }
    }
    println!("décodage linéaire : {decoded} instructions lues, {unknown} octets refusés");
    let total = decoded + unknown;
    println!(
        "  soit {:.1} % de succès",
        100.0 * decoded as f64 / total as f64
    );
    let mut worst: Vec<_> = refused.into_iter().collect();
    worst.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
    print!("  opcodes refusés les plus fréquents :");
    for (op, n) in worst.iter().take(12) {
        print!(" {op}×{n}");
    }
    println!();

    // Et la vraie question : combien de **régions** se compilent entièrement ?
    let (mut ok, mut no) = (0usize, 0usize);
    let mut cursor = 0usize;
    let mut tried = 0usize;
    while cursor < limit && tried < 20000 {
        if Module::region(&bytes[cursor..limit.min(cursor + 4096)], 0x30000000, 0).is_some() {
            ok += 1;
        } else {
            no += 1;
        }
        tried += 1;
        cursor += 512;
    }
    println!(
        "régions de 4 Kio : {ok} compilées, {no} refusées ({:.1} %)",
        100.0 * ok as f64 / (ok + no) as f64
    );
}
