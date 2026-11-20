//! **La carte mémoire d'un PC**, celle de `X86Memory.pc` du cœur Swift : la RAM
//! d'un seul tenant jusqu'à trois gibioctets, et au-delà un trou sous quatre
//! gibioctets, comme sur un vrai PC et chez QEMU.
//!
//! Sans le trou, une machine de plus de trois gibioctets étalait sa RAM sur
//! les adresses des périphériques, et Linux ne trouvait plus où poser leurs
//! fenêtres : « Cannot find an available gap in the 32-bit address range ».

use std::ops::Range;

use crate::x86::{Cpu, GuestMemory};

/// Où la RAM s'arrête quand il y a un trou.
pub const DEBUT_DU_TROU: u64 = 0xC000_0000;
/// Où elle reprend.
pub const FIN_DU_TROU: u64 = 1 << 32;

/// La mémoire par défaut, et le plancher : les valeurs du cœur Swift, mesurées
/// sur le noyau d'Alpine, qui ne se décompresse pas sous cent vingt-huit
/// mébioctets.
pub const RAM_PAR_DEFAUT: u64 = 256 << 20;
pub const RAM_MINIMALE: u64 = 128 << 20;

/// La RAM a-t-elle un trou ?
pub fn a_un_trou(ram: u64) -> bool {
    ram > DEBUT_DU_TROU
}

/// **Les plages de RAM, dans l'ordre** : une sans trou, deux avec. C'est ce
/// que la carte e820 annonce au noyau.
pub fn plages(ram: u64) -> Vec<Range<u64>> {
    let mut plages = Vec::with_capacity(2);
    plages.push(0..ram.min(DEBUT_DU_TROU));
    if a_un_trou(ram) {
        plages.push(FIN_DU_TROU..FIN_DU_TROU + (ram - DEBUT_DU_TROU));
    }
    plages
}

/// **Un bloc de `octets` octets nuls, ou rien quand le système le refuse.**
///
/// Les pages sont demandées nulles au système (`alloc_zeroed`, le `calloc`
/// de l'hôte) sans être écrites : la mémoire que l'invité ne touche jamais ne
/// pèse rien dans l'hôte. C'est ce que fait `vec![0; n]` — qui, lui, arrête
/// le processus quand le système dit non : « memory allocation of
/// 35433480192 bytes failed », puis SIGABRT, pour `--ram 32768` sur un hôte
/// de quinze gibioctets. Ici le refus se rend, et l'appelant le dit.
///
/// Un nombre qui ne tient pas dans l'espace d'adresses de l'hôte (un `usize`
/// de trente-deux bits en wasm32) est un refus aussi, pas une troncature.
pub fn bloc_nul(octets: u64) -> Option<Vec<u8>> {
    let octets = usize::try_from(octets).ok()?;
    if octets == 0 {
        return Some(Vec::new());
    }
    let disposition = std::alloc::Layout::array::<u8>(octets).ok()?;
    // SÛRETÉ : la disposition n'est pas de taille nulle (vérifié ci-dessus).
    let pointeur = unsafe { std::alloc::alloc_zeroed(disposition) };
    if pointeur.is_null() {
        return None;
    }
    // SÛRETÉ : le pointeur vient de l'allocateur global, avec la disposition
    // d'un tableau de `octets` octets — l'alignement de `u8`, et la taille que
    // `Vec` rendra en libérant une capacité de `octets`. Les `octets` premiers
    // octets sont initialisés : `alloc_zeroed` les a mis à zéro.
    Some(unsafe { Vec::from_raw_parts(pointeur, octets, octets) })
}

/// **Brancher `ram` octets de RAM sur le processeur**, à la carte d'un PC,
/// ou `false` — le processeur intact — quand l'hôte ne peut pas les donner.
///
/// Le bloc de l'hôte couvre le trou — il est demandé nul au système, qui ne
/// rend résident que ce qu'on touche, et personne ne touche le trou — si bien
/// qu'une adresse physique reste un décalage dans le bloc, sans calcul. Le
/// trou lui-même est déclaré au processeur (`Cpu::memory_hole`), qui refuse
/// d'y lire de la RAM.
pub fn essayer_de_brancher(cpu: &mut Cpu, ram: u64) -> bool {
    let trou = if a_un_trou(ram) {
        FIN_DU_TROU - DEBUT_DU_TROU
    } else {
        0
    };
    let Some(bytes) = ram.checked_add(trou).and_then(bloc_nul) else {
        return false;
    };
    cpu.memory = GuestMemory { base: 0, bytes };
    cpu.memory_hole = if trou == 0 {
        (0, 0)
    } else {
        (DEBUT_DU_TROU, trou)
    };
    true
}

/// `essayer_de_brancher`, pour qui ne sait pas quoi faire d'un refus : un
/// arrêt qui dit combien était demandé.
pub fn brancher(cpu: &mut Cpu, ram: u64) {
    assert!(
        essayer_de_brancher(cpu, ram),
        "l'hôte ne peut pas donner {ram} octets de RAM"
    );
}

/// Poser un bloc à une adresse physique — ce que fait un chargeur. `false`
/// quand il ne tient pas dans la RAM.
pub fn poser(memoire: &mut GuestMemory, adresse: u64, bloc: &[u8]) -> bool {
    let Some(debut) = adresse.checked_sub(memoire.base) else {
        return false;
    };
    let Some(fin) = debut.checked_add(bloc.len() as u64) else {
        return false;
    };
    if fin > memoire.bytes.len() as u64 {
        return false;
    }
    memoire.bytes[debut as usize..fin as usize].copy_from_slice(bloc);
    true
}
