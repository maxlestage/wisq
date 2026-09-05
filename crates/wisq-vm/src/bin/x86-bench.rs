//! **Ce que rend un cœur x86 sans JIT, quand on le fait bien.**
//!
//! La boucle est celle du banc x86 et du module WebAssembly du lot 8, à
//! l'identique, pour que les chiffres se comparent :
//!
//! ```text
//!     add  %rcx, %rax
//!     cmp  %rdx, %rax        ; puis rdx += 1 si égal
//!     dec  %rcx              ; jusqu'à zéro
//! ```
//!
//! **Ce que ce chiffre ne couvre pas, dit avant de le lire** : cette tranche
//! n'a ni branchements ni mémoire, donc la boucle est conduite depuis Rust et
//! seules les instructions arithmétiques sont exécutées et comptées. C'est
//! donc un **plafond** pour un cœur complet, pas sa vitesse. Il répond à une
//! question précise : est-ce que les drapeaux paresseux valent le détour ?
//!
//! Les deux passes se distinguent sur un seul point — la seconde lit `ZF`
//! après chaque comparaison, la première ne le lit jamais. C'est exactement la
//! différence que les drapeaux paresseux exploitent, et le rapport entre les
//! deux la mesure.

use std::time::Instant;
use wisq_vm::x86::{decode, Cpu, Decoded, ZF};

fn assemble(bytes: &[u8]) -> Decoded {
    decode(bytes).expect("le banc n'assemble que ce que le décodeur connaît")
}

fn main() {
    let rounds: u64 = std::env::args()
        .nth(1)
        .and_then(|v| v.parse().ok())
        .unwrap_or(20_000_000);

    // add %rcx,%rax — cmp %rdx,%rax — inc %rdx — dec %rcx
    let add = assemble(&[0x48, 0x01, 0xc8]);
    let cmp = assemble(&[0x48, 0x39, 0xd0]);
    let inc = assemble(&[0x48, 0xff, 0xc2]);
    let dec = assemble(&[0x48, 0xff, 0xc9]);

    // **Passe zéro : les drapeaux calculés tout de suite.** C'est le terme de
    // comparaison. Sans lui, « les drapeaux paresseux rapportent » serait une
    // croyance, pas une mesure.
    let mut cpu = Cpu::default();
    cpu.regs[1] = rounds;
    let started = Instant::now();
    for _ in 0..rounds {
        cpu.execute_eagerly(&add);
        cpu.execute_eagerly(&cmp);
        cpu.execute_eagerly(&dec);
    }
    let seconds = started.elapsed().as_secs_f64();
    let executed = rounds * 3;
    let eager = executed as f64 / seconds / 1e6;
    println!(
        "x86 Rust, drapeaux calculés tout de suite : {eager:.0} MIPS sur {} M instructions",
        executed / 1_000_000
    );

    // **Première passe : aucun drapeau n'est lu.** C'est le cas fréquent dans
    // du vrai code, et celui où garder l'opération au lieu du résultat ne
    // coûte rien et fait tout gagner.
    let mut cpu = Cpu::default();
    cpu.regs[1] = rounds;
    let started = Instant::now();
    for _ in 0..rounds {
        cpu.execute(&add);
        cpu.execute(&cmp);
        cpu.execute(&dec);
    }
    let seconds = started.elapsed().as_secs_f64();
    let executed = rounds * 3;
    let unread = executed as f64 / seconds / 1e6;
    println!(
        "x86 Rust, drapeaux jamais lus : {unread:.0} MIPS sur {} M instructions",
        executed / 1_000_000
    );

    // **Deuxième passe : ZF est lu après chaque comparaison**, comme le ferait
    // le `jne` que cette tranche n'implémente pas encore. C'est le pire cas
    // pour des drapeaux paresseux, puisqu'ils sont alors calculés à chaque
    // tour — et c'est celui qu'il faut publier à côté de l'autre.
    let mut cpu = Cpu::default();
    cpu.regs[1] = rounds;
    let started = Instant::now();
    let mut taken = 0u64;
    for _ in 0..rounds {
        cpu.execute(&add);
        cpu.execute(&cmp);
        if cpu.flags.read() & ZF != 0 {
            cpu.execute(&inc);
            taken += 1;
        }
        cpu.execute(&dec);
    }
    let seconds = started.elapsed().as_secs_f64();
    let executed = rounds * 3 + taken;
    let read = executed as f64 / seconds / 1e6;
    println!(
        "x86 Rust, ZF lu à chaque tour : {read:.0} MIPS sur {} M instructions",
        executed / 1_000_000
    );
    println!(
        "x86 Rust, ce que la paresse rapporte quand rien ne lit : ×{:.2}",
        unread / eager
    );
    println!(
        "x86 Rust, ce qu'elle rapporte quand tout est lu : ×{:.2}",
        read / eager
    );
}
