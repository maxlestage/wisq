//! **Le secours de l'émetteur : une instruction qu'il ne traduit pas,
//! exécutée par l'interpréteur.**
//!
//! L'émetteur ne produit pas le x87, ni une partie du MMX et du SSE : il
//! n'en a ni les registres ni le calcul sur quatre-vingts bits. La machine PC
//! native les a (`x86_extended.rs`, jugé contre le silicium). Sans secours,
//! une instruction que l'émetteur refuse arrêtait la machine de la page —
//! Alpine 3.24 s'arrêtait sur `fildl 0x20(%rsp)` (`db 44 24 20`) dans la
//! libc de musl, à l'installation de ses paquets.
//!
//! **Le partage.** La boucle de la page (JavaScript) sait lire et écrire la
//! mémoire de l'invité à travers ses tables de pages, et livrer une faute ;
//! ce module sait lire et exécuter l'instruction. L'échange tient en trois
//! temps :
//!
//! 1. [`Secours::executer`] sans fenêtre : l'instruction se lit, et si elle a
//!    un opérande en mémoire, la réponse est [`Issue::Memoire`] — son adresse,
//!    et combien d'octets lire (jusqu'au bout de sa page).
//! 2. La page lit ces octets par les tables de pages (une faute de page s'y
//!    livre comme toute autre) et rappelle avec la fenêtre. Si l'opérande
//!    déborde sur la page suivante, la réponse redemande une fenêtre plus
//!    longue.
//! 3. [`Issue::Faite`] : la fenêtre porte ce que l'instruction y a écrit,
//!    l'état ce qu'elle a changé. La page récrit les octets changés (une page
//!    en lecture seule y fait faute) puis appelle [`Secours::valider`] — ou
//!    [`Secours::annuler`] si l'écriture a fauté : rien n'a alors changé, ni
//!    dans les registres, ni dans la pile du x87.
//!
//! **La pile du x87 vit ici**, et nulle part ailleurs : l'émetteur n'en a pas.
//! `fninit`, `fxsave` et `fxrstor` restent à l'émetteur, qui les traduit avec
//! une pile vide. **C'est une limite, et elle est connue** : un programme
//! préempté au milieu d'une suite de x87 (musl le fait dans `printf` et
//! `strtod`, sur quelques instructions) retrouve la pile telle que le suivant
//! l'a laissée. Les faire passer par le secours tient la pile juste, mais
//! coûte un aller-retour par changement de contexte et, mesuré au démarrage
//! d'Alpine 3.24, un `fninit` qu'une interruption d'horloge devançait sans
//! fin : le noyau ne passait plus l'initialisation du coprocesseur.

use super::machine::{lire, Lue};
use crate::x86::{decode, Cpu, ExtendedFault, GuestMemory, Op};

/// **Ce que la page tient en globales**, et que le secours lit et rend.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Etat {
    pub regs: [u64; 16],
    pub rip: u64,
    pub rflags: u64,
    pub fs_base: u64,
    pub gs_base: u64,
    pub cr0: u64,
    pub cr4: u64,
    pub fpu_control: u16,
    pub fpu_status: u16,
    pub xmm: [[u64; 2]; 16],
    pub mxcsr: u32,
}

/// Ce qu'une tentative rend.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Issue {
    /// Exécutée. L'état est à jour ; la fenêtre, s'il y en avait une, porte
    /// ce que l'instruction y a écrit. Rien n'est acquis avant `valider`.
    Faite,
    /// Il faut les octets de `[adresse, adresse + taille)`.
    Memoire { adresse: u64, taille: usize },
    /// Une exception à livrer : son vecteur, et son code d'erreur s'il en a.
    Exception { vecteur: u8, code: Option<u32> },
    /// Aucun des décodeurs ne la lit, ou c'est une instruction que seule la
    /// machine peut faire (un port, `cpuid`, la pile…) : refusée.
    Illisible,
}

/// `#UD`, `#GP`, `#MF`, `#XM`.
const INDEFINIE: u8 = 6;
const PROTECTION: u8 = 13;
const FLOTTANT: u8 = 16;
const FLOTTANT_SIMD: u8 = 19;

/// La fenêtre la plus longue qu'on demande : deux pages, de quoi tenir
/// l'aire de `fxsave` à cheval sur deux.
pub const FENETRE_MAX: usize = 8192;

/// **Le secours** : la pile du x87, gardée d'un appel à l'autre.
#[derive(Default)]
pub struct Secours {
    cpu: Cpu,
    /// L'état d'après la dernière instruction faite, en attente de `valider`.
    attente: Option<Cpu>,
}

impl Secours {
    pub fn new() -> Self {
        Self::default()
    }

    /// **Lire, et exécuter si on a ce qu'il faut.** `code` porte
    /// l'instruction (quinze octets suffisent) ; `fenetre`, quand l'appel
    /// précédent a rendu `Memoire`, la mémoire lue à partir de son adresse.
    pub fn executer(
        &mut self,
        etat: &mut Etat,
        code: &[u8],
        fenetre: Option<(u64, &mut [u8])>,
    ) -> Issue {
        self.attente = None;
        let Some(lue) = lire(code) else {
            return Issue::Illisible;
        };
        let mut cpu = self.cpu.clone();
        charger(&mut cpu, etat);
        let (memoire, longueur) = match &lue {
            Lue::Etendue(instruction) => (instruction.memory, instruction.length),
            Lue::Commune(instruction) => {
                // **Ce que le décodeur de l'émetteur lit, l'émetteur l'a
                // refusé pour une raison** : le secours ne le reprend pas. Ce
                // qu'il reprend, ce sont les formes que seul le lecteur de la
                // machine native lit (`67` devant une instruction qui
                // n'adresse rien, les rangements non temporels).
                if decode(code).is_some() || !secourable(instruction.op) {
                    return Issue::Illisible;
                }
                (instruction.memory, instruction.length)
            }
            Lue::Attente(longueur) => (None, *longueur),
        };
        let apres = etat.rip.wrapping_add(longueur as u64);
        let adresse = memoire.map(|adresse| cpu.effective_address(&adresse, apres));
        // **La fenêtre** : la mémoire de l'instruction, seule. La pagination
        // est éteinte dans cette copie du processeur : l'adresse linéaire
        // est celle de la fenêtre, que la page a déjà traduite.
        let fenetre = match (adresse, fenetre) {
            (None, _) => None,
            (Some(adresse), None) => {
                return Issue::Memoire {
                    adresse,
                    taille: 4096 - (adresse & 0xFFF) as usize,
                }
            }
            (Some(_), Some((base, octets))) => {
                cpu.memory = GuestMemory {
                    base,
                    bytes: octets.to_vec(),
                };
                Some((base, octets))
            }
        };
        let rendu = match lue {
            Lue::Etendue(instruction) => cpu.execute_extended(&instruction),
            Lue::Attente(_) => {
                if cpu.x87_pending() {
                    Err(ExtendedFault::FloatingPoint)
                } else {
                    Ok(())
                }
            }
            Lue::Commune(instruction) => {
                cpu.jumped = false;
                cpu.execute(&instruction);
                if cpu.faulted {
                    Err(ExtendedFault::Memory)
                } else {
                    Ok(())
                }
            }
        };
        match rendu {
            Ok(()) => {}
            // **Hors de la fenêtre** : l'opérande déborde sur la page
            // suivante. Une fenêtre de deux pages, une seule fois.
            Err(ExtendedFault::Memory) => {
                return match (adresse, fenetre) {
                    (Some(adresse), Some((_, octets))) if octets.len() < FENETRE_MAX => {
                        Issue::Memoire {
                            adresse,
                            taille: (4096 - (adresse & 0xFFF) as usize) + 4096,
                        }
                    }
                    _ => Issue::Exception {
                        vecteur: PROTECTION,
                        code: Some(0),
                    },
                }
            }
            Err(ExtendedFault::ReservedControl) => {
                return Issue::Exception {
                    vecteur: PROTECTION,
                    code: Some(0),
                }
            }
            Err(ExtendedFault::SimdException) => {
                let vecteur = if etat.cr4 & (1 << 10) != 0 {
                    FLOTTANT_SIMD
                } else {
                    INDEFINIE
                };
                return Issue::Exception {
                    vecteur,
                    code: None,
                };
            }
            Err(ExtendedFault::FloatingPoint) => {
                return Issue::Exception {
                    vecteur: FLOTTANT,
                    code: None,
                }
            }
        }
        if !cpu.jumped {
            cpu.rip = apres;
        }
        if let Some((_, octets)) = fenetre {
            octets.copy_from_slice(&cpu.memory.bytes);
        }
        rendre(&cpu, etat);
        cpu.memory = GuestMemory::default();
        self.attente = Some(cpu);
        Issue::Faite
    }

    /// **La page a récrit la fenêtre** : la pile du x87 d'après l'instruction
    /// devient celle de la machine.
    pub fn valider(&mut self) {
        if let Some(cpu) = self.attente.take() {
            self.cpu = cpu;
        }
    }

    /// **L'écriture a fauté** : rien n'est acquis.
    pub fn annuler(&mut self) {
        self.attente = None;
    }
}

/// **Ce que le secours exécute de ce que le lecteur de la machine native rend
/// sous la forme du premier décodeur** : les instructions sans autre mémoire
/// que leur opérande. La pile, les chaînes, le coprocesseur et tout ce qui
/// parle à la machine (ports, `cpuid`, registres de contrôle) adressent une
/// mémoire que la fenêtre ne porte pas, ou demandent la machine elle-même.
fn secourable(op: Op) -> bool {
    !matches!(
        op,
        Op::FpuInit
            | Op::FxSave
            | Op::FxRestore
            | Op::Push
            | Op::Pop
            | Op::Call
            | Op::CallIndirect
            | Op::Return
            | Op::Leave
            | Op::PushFlags
            | Op::PopFlags
            | Op::StringMove { .. }
            | Op::StringStore { .. }
            | Op::StringLoad { .. }
            | Op::StringCompare { .. }
            | Op::StringScan { .. }
            | Op::PortIn
            | Op::PortOut
            | Op::ReadTimestamp
            | Op::ReadTimestampAndProcessor
            | Op::CpuId
            | Op::ReadModelRegister
            | Op::WriteModelRegister
            | Op::FarReturn
            | Op::InterruptReturn
            | Op::SoftwareInterrupt
            | Op::LoadDescriptorTable { .. }
            | Op::StoreDescriptorTable { .. }
            | Op::SwapGs
            | Op::LoadKernelGs
            | Op::HypervisorCall { .. }
            | Op::InvalidatePcid
            | Op::LoadTaskRegister
            | Op::SystemCall
            | Op::SystemReturn
            | Op::LoadLocalDescriptorTable
            | Op::ReadDebugRegister { .. }
            | Op::WriteDebugRegister { .. }
            | Op::LoadSegment { .. }
            | Op::StoreSegment { .. }
            | Op::InterruptFlag(_)
            | Op::Halt
            | Op::Undefined
            | Op::InvalidatePage
            | Op::ReadControlRegister { .. }
            | Op::WriteControlRegister { .. }
            | Op::ReadRandom { .. }
            | Op::Vector(_)
    )
}

fn charger(cpu: &mut Cpu, etat: &Etat) {
    cpu.regs = etat.regs;
    cpu.rip = etat.rip;
    cpu.flags.write(etat.rflags);
    cpu.fs_base = etat.fs_base;
    cpu.gs_base = etat.gs_base;
    // La pagination éteinte : la fenêtre est déjà traduite.
    cpu.control[0] = etat.cr0 & !(1 << 31);
    cpu.control[4] = etat.cr4;
    cpu.fpu_control = etat.fpu_control;
    cpu.fpu_status = etat.fpu_status;
    cpu.xmm = etat.xmm;
    cpu.mxcsr = etat.mxcsr;
    cpu.tlb = None;
    cpu.faulted = false;
    cpu.unmapped = None;
    cpu.memory = GuestMemory::default();
}

fn rendre(cpu: &Cpu, etat: &mut Etat) {
    etat.regs = cpu.regs;
    etat.rip = cpu.rip;
    etat.rflags = cpu.flags.read();
    etat.fpu_control = cpu.fpu_control;
    etat.fpu_status = cpu.fpu_status;
    etat.xmm = cpu.xmm;
    etat.mxcsr = cpu.mxcsr;
}

#[cfg(test)]
mod tests {
    use super::*;

    const RSP: u64 = 0x7000;

    fn etat() -> Etat {
        let mut etat = Etat {
            rip: 0x40_0000,
            rflags: 0x2,
            cr0: 0x8000_0033,
            fpu_control: 0x037F,
            mxcsr: 0x1F80,
            ..Etat::default()
        };
        etat.regs[4] = RSP;
        etat
    }

    /// Le temps 1 puis le temps 2 : demander la fenêtre, puis l'exécuter.
    fn faire(
        secours: &mut Secours,
        etat: &mut Etat,
        code: &[u8],
        memoire: &mut [u8; 0x2000],
    ) -> Issue {
        match secours.executer(etat, code, None) {
            Issue::Memoire { adresse, taille } => {
                let debut = (adresse - 0x6000) as usize;
                let mut fenetre = memoire[debut..debut + taille].to_vec();
                let issue = secours.executer(etat, code, Some((adresse, &mut fenetre)));
                if issue == Issue::Faite {
                    memoire[debut..debut + taille].copy_from_slice(&fenetre);
                    secours.valider();
                }
                issue
            }
            Issue::Faite => {
                secours.valider();
                Issue::Faite
            }
            autre => autre,
        }
    }

    /// **`fild` puis `fistp` : la pile du x87 tient d'un appel à l'autre.**
    /// `fildl 0x20(%rsp)` charge 21, `fildq (%rsp)` 2, `fmulp`, puis
    /// `fistpq 8(%rsp)` range 42 — et RIP avance chaque fois de la longueur.
    #[test]
    fn the_x87_stack_survives_between_calls() {
        let mut secours = Secours::new();
        let mut etat = etat();
        let mut memoire = [0u8; 0x2000];
        let pile = (RSP - 0x6000) as usize;
        memoire[pile + 0x20..pile + 0x24].copy_from_slice(&21u32.to_le_bytes());
        memoire[pile..pile + 8].copy_from_slice(&2u64.to_le_bytes());
        for code in [
            &[0xdb, 0x44, 0x24, 0x20][..], // fildl 0x20(%rsp)
            &[0xdf, 0x2c, 0x24],           // fildll (%rsp)
            &[0xde, 0xc9],                 // fmulp
            &[0xdf, 0x7c, 0x24, 0x08],     // fistpll 8(%rsp)
        ] {
            let avant = etat.rip;
            assert_eq!(
                faire(&mut secours, &mut etat, code, &mut memoire),
                Issue::Faite
            );
            assert_eq!(etat.rip, avant + code.len() as u64);
        }
        assert_eq!(
            u64::from_le_bytes(memoire[pile + 8..pile + 16].try_into().unwrap()),
            42
        );
        // La pile est de nouveau vide : `fistp` a dépilé, `fmulp` aussi.
        assert_eq!(secours.cpu.fpu_tags, 0);
    }

    /// **Une écriture qui faute n'a rien changé** : sans `valider`, la pile
    /// du x87 est celle d'avant.
    #[test]
    fn a_cancelled_instruction_leaves_the_stack_as_it_was() {
        let mut secours = Secours::new();
        let mut etat = etat();
        let mut memoire = [0u8; 0x2000];
        assert_eq!(
            faire(&mut secours, &mut etat, &[0xd9, 0xe8], &mut memoire),
            Issue::Faite
        ); // fld1
        let mut fenetre = vec![0u8; 8];
        let mut copie = etat;
        assert!(matches!(
            secours.executer(&mut copie, &[0xdd, 0x1c, 0x24], None), // fstpl (%rsp)
            Issue::Memoire { .. }
        ));
        assert_eq!(
            secours.executer(&mut copie, &[0xdd, 0x1c, 0x24], Some((RSP, &mut fenetre))),
            Issue::Faite
        );
        assert_eq!(f64::from_le_bytes(fenetre[..8].try_into().unwrap()), 1.0);
        secours.annuler();
        assert_ne!(secours.cpu.fpu_tags, 0, "`fld1` est toujours sur la pile");
    }

    /// **Ce que l'émetteur lit et refuse reste refusé** — `cpuid`, `push`,
    /// `ud2`, et même `add (%rax),%al` : s'il l'a refusé, c'est pour une
    /// raison, et le secours n'est pas un second émetteur.
    #[test]
    fn what_the_emitter_reads_stays_refused() {
        let mut secours = Secours::new();
        let mut etat = etat();
        for code in [&[0x0f, 0xa2][..], &[0x50], &[0x0f, 0x0b], &[0x00, 0x00]] {
            assert_eq!(
                secours.executer(&mut etat, code, None),
                Issue::Illisible,
                "{code:02x?}"
            );
        }
        // `fninit` aussi : l'émetteur le traduit.
        assert_eq!(
            secours.executer(&mut etat, &[0xdb, 0xe3], None),
            Issue::Illisible
        );
    }
}
