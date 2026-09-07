//! **Ce que le décodeur ne sait pas lire, nommé par sa forme.**
//!
//! `coverage` compte les refus par leur **premier** octet, ce qui met tous les
//! opcodes de la deuxième page dans un même seau appelé « 0f » — un seau qui ne
//! dit rien. Ici la forme complète est nommée : `0f 30` est `wrmsr`, `0f a2`
//! est `cpuid`, et la liste devient une liste de travail.
//!
//!     cargo run -p wisq-vm --release --example unknown-opcodes -- <vmlinux>
//!
//! **Deux choses à savoir en lisant le résultat**, sans quoi il trompe :
//!
//! - un opcode de deux octets est compté **deux fois**. Le décodeur échoue sur
//!   `0f`, l'outil avance d'un octet, et échoue à nouveau sur le second. Les
//!   lignes `ae` et `a2` sont donc les mêmes instructions que `0f ae` et
//!   `0f a2`, pas des formes de plus ;
//! - `cc` en tête de liste est `int3`, le bourrage entre fonctions. Ce ne sont
//!   pas des instructions manquantes, c'est du remplissage qui n'est jamais
//!   exécuté.
use std::collections::BTreeMap;
use wisq_vm::x86::decode;

fn main() {
    let path = std::env::args().nth(1).expect("le chemin du noyau");
    let bytes = std::fs::read(&path).expect("le fichier");
    // Huit mégaoctets suffisent à donner les proportions, et le fichier entier
    // prendrait des minutes — le même échantillon que `coverage`.
    let limit = bytes.len().min(8 << 20);
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut at = 0usize;
    while at < limit {
        match decode(&bytes[at..]) {
            Some(step) => at += step.length.max(1),
            None => {
                let name = if bytes[at] == 0x0f && at + 1 < limit {
                    format!("0f {:02x}", bytes[at + 1])
                } else {
                    format!("{:02x}", bytes[at])
                };
                *counts.entry(name).or_default() += 1;
                at += 1;
            }
        }
    }
    let mut worst: Vec<_> = counts.into_iter().collect();
    worst.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
    for (op, n) in worst.iter().take(24) {
        println!("{op} × {n}");
    }
}
