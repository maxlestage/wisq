//! **Le code machine x86-64 du JIT**, assemblé à la main.
//!
//! Les registres de l'hôte, pendant un bloc :
//!
//! | registre | ce qu'il tient |
//! | --- | --- |
//! | `rbx` | le processeur invité (`Cpu`) |
//! | `r12` | le contexte (`Contexte`) |
//! | `r13` | le début de la RAM de l'invité |
//! | `r14` | sa longueur |
//! | `r15` | l'adresse physique de son premier octet |
//! | `rbp` | le rang de l'instruction confiée à sa forme |
//! | `rsi` | l'adresse invitée d'un accès |
//! | `rdi` | l'adresse de l'hôte où l'accès tombe |
//! | `rax`, `rcx`, `rdx`, `r8` à `r11` | des calculs |
//!
//! Les registres de l'invité restent dans `Cpu::regs` : chaque instruction
//! les lit et les écrit là, comme la forme qu'elle remplace.
//!
//! **RIP avance en retard** : le traducteur compte ce dont il a avancé
//! (`Traducteur::pendant`) et ne l'écrit dans `Cpu::rip` qu'avant ce qui le
//! lit — l'appel d'une forme, une sortie. Une adresse relative et la cible
//! d'un saut le comptent. Huit additions en mémoire par bloc, chacune
//! attendant la précédente, n'en font plus qu'une.
//!
//! **Ce qui se répète vit une fois** au début de la zone (`routines`) : le
//! chemin rapide du tampon pour chaque largeur et chaque sens, l'appel d'une
//! forme, la lecture des drapeaux, la sortie. Un bloc les appelle : un code
//! de bloc de 1,6 Kio en moyenne débordait le cache d'instructions de
//! l'hôte, et le JIT perdait contre l'interpréteur.

use super::contexte;
use super::disposition as d;
use super::{Appels, Instruction, ARRET, FAUTE, FIN, SAUT};
use crate::x86::rapide::{
    Gabarit, Uop, ADD, AND, BASE, CMP, DEC, INC, INDEXEE, MI, MR, NEG, NOT, OR, RELATIVE, RI, RM,
    RR, SAR, SHL, SHR, SUB, TEST, XOR,
};
use crate::x86_paging::disposition as tlb;
use crate::x86_paging::TLB_SLOTS;

const RAX: u8 = 0;
const RCX: u8 = 1;
const RDX: u8 = 2;
const RBX: u8 = 3;
const RSP: u8 = 4;
const RBP: u8 = 5;
const RSI: u8 = 6;
const RDI: u8 = 7;
const R8: u8 = 8;
const R9: u8 = 9;
const R10: u8 = 10;
const R12: u8 = 12;
const R13: u8 = 13;
const R14: u8 = 14;
const R15: u8 = 15;

// La case du tampon se calcule en `index * 3 * 8`, et une `Uop` en
// `rang << 5`.
const _: () = assert!(tlb::TAILLE_CASE == 24);
const _: () = assert!(TLB_SLOTS == 1024);
const _: () = assert!(d::TAILLE_UOP == 32);

/// Une opérande : un registre, ou la mémoire à `base + index << echelle +
/// deplacement`.
#[derive(Clone, Copy)]
enum Rm {
    R(u8),
    M {
        base: u8,
        index: Option<(u8, u8)>,
        deplacement: i32,
    },
}

fn m(base: u8, deplacement: i32) -> Rm {
    Rm::M {
        base,
        index: None,
        deplacement,
    }
}

/// Un registre de l'invité, dans `Cpu::regs`.
fn reg(numero: u8) -> Rm {
    m(RBX, d::REGS + 8 * i32::from(numero & 15))
}

#[derive(Clone, Copy)]
struct Etiquette(usize);

/// **L'assembleur** : des octets, l'adresse où ils seront posés (pour les
/// appels aux routines), des étiquettes, et les sauts à reprendre quand
/// toutes les étiquettes sont posées.
struct Asm {
    origine: u64,
    code: Vec<u8>,
    etiquettes: Vec<Option<usize>>,
    /// (l'octet du déplacement de 32 bits, l'étiquette visée)
    reprises: Vec<(usize, usize)>,
}

impl Asm {
    fn new(origine: u64) -> Self {
        Self {
            origine,
            code: Vec::with_capacity(1024),
            etiquettes: Vec::new(),
            reprises: Vec::new(),
        }
    }

    /// L'adresse absolue du prochain octet.
    fn ici(&self) -> u64 {
        self.origine + self.code.len() as u64
    }

    fn octet(&mut self, b: u8) {
        self.code.push(b);
    }

    fn octets(&mut self, b: &[u8]) {
        self.code.extend_from_slice(b);
    }

    fn i32(&mut self, v: i32) {
        self.code.extend_from_slice(&v.to_le_bytes());
    }

    fn etiquette(&mut self) -> Etiquette {
        self.etiquettes.push(None);
        Etiquette(self.etiquettes.len() - 1)
    }

    fn poser(&mut self, e: Etiquette) {
        self.etiquettes[e.0] = Some(self.code.len());
    }

    fn vers(&mut self, e: Etiquette) {
        self.reprises.push((self.code.len(), e.0));
        self.i32(0);
    }

    /// Un déplacement de 32 bits vers une adresse absolue (une routine), à
    /// compter de la fin de l'instruction : les quatre octets sont les
    /// derniers.
    fn vers_absolu(&mut self, cible: u64) {
        let apres = self.ici() + 4;
        let relatif = cible.wrapping_sub(apres) as i64;
        self.i32(i32::try_from(relatif).expect("une routine dans la zone"));
    }

    fn finir(mut self) -> Vec<u8> {
        for (ou, e) in std::mem::take(&mut self.reprises) {
            let cible = self.etiquettes[e].expect("une étiquette posée");
            let relatif = cible as i64 - (ou as i64 + 4);
            self.code[ou..ou + 4].copy_from_slice(&(relatif as i32).to_le_bytes());
        }
        self.code
    }

    // ---- L'encodage ----

    /// **Une instruction à ModRM** : `taille` en octets (1, 2, 4, 8) pour les
    /// préfixes, l'opcode, le champ `reg` (un registre ou une extension
    /// d'opcode), et l'opérande `rm`. `octet` : l'instruction lit ou écrit
    /// des registres d'un octet, qui demandent REX dès le quatrième (sinon
    /// AH, CH, DH, BH).
    fn modrm(&mut self, taille: u8, opcode: &[u8], r: u8, rm: Rm, octet: bool) {
        if taille == 2 {
            self.octet(0x66);
        }
        let (b, x) = match rm {
            Rm::R(registre) => (registre, 0),
            Rm::M { base, index, .. } => (base, index.map_or(0, |(i, _)| i)),
        };
        let w = u8::from(taille == 8);
        let rex = 0x40 | (w << 3) | ((r >> 3) << 2) | ((x >> 3) << 1) | (b >> 3);
        let octet_haut = |registre: u8| (4..8).contains(&registre);
        let force =
            octet && (octet_haut(r) || matches!(rm, Rm::R(registre) if octet_haut(registre)));
        if rex != 0x40 || force {
            self.octet(rex);
        }
        self.octets(opcode);
        match rm {
            Rm::R(registre) => self.octet(0xC0 | ((r & 7) << 3) | (registre & 7)),
            Rm::M {
                base,
                index,
                deplacement,
            } => {
                let mode = if deplacement == 0 && base & 7 != RBP {
                    0
                } else if i8::try_from(deplacement).is_ok() {
                    1
                } else {
                    2
                };
                if index.is_some() || base & 7 == RSP {
                    let (i, echelle) = index.unwrap_or((RSP, 0));
                    self.octet((mode << 6) | ((r & 7) << 3) | 4);
                    self.octet((echelle << 6) | ((i & 7) << 3) | (base & 7));
                } else {
                    self.octet((mode << 6) | ((r & 7) << 3) | (base & 7));
                }
                match mode {
                    1 => self.octet(deplacement as i8 as u8),
                    2 => self.i32(deplacement),
                    _ => {}
                }
            }
        }
    }

    /// `mov` à `taille` octets, d'un registre vers `rm`.
    fn ranger(&mut self, taille: u8, rm: Rm, source: u8) {
        let opcode = if taille == 1 { 0x88 } else { 0x89 };
        self.modrm(taille, &[opcode], source, rm, taille == 1);
    }

    /// `mov r64, rm64`.
    fn mov(&mut self, cible: u8, rm: Rm) {
        self.modrm(8, &[0x8B], cible, rm, false);
    }

    /// `mov` de registre à registre, sur `taille` octets (4 : la moitié
    /// haute s'efface).
    fn copier(&mut self, taille: u8, cible: u8, source: u8) {
        self.modrm(taille, &[0x89], source, Rm::R(cible), false);
    }

    /// **Lire `taille` octets de `rm`, étendus de zéros** sur soixante-quatre
    /// bits.
    fn charger(&mut self, taille: u8, cible: u8, rm: Rm) {
        match taille {
            1 => self.modrm(4, &[0x0F, 0xB6], cible, rm, true),
            2 => self.modrm(4, &[0x0F, 0xB7], cible, rm, false),
            4 => self.modrm(4, &[0x8B], cible, rm, false),
            _ => self.mov(cible, rm),
        }
    }

    /// Étendre en signe les `taille` octets bas de `registre`.
    fn etendre(&mut self, taille: u8, registre: u8) {
        match taille {
            1 => self.modrm(8, &[0x0F, 0xBE], registre, Rm::R(registre), true),
            2 => self.modrm(8, &[0x0F, 0xBF], registre, Rm::R(registre), false),
            4 => self.modrm(8, &[0x63], registre, Rm::R(registre), false),
            _ => {}
        }
    }

    /// `lea r64, m`.
    fn lea(&mut self, cible: u8, rm: Rm) {
        self.modrm(8, &[0x8D], cible, rm, false);
    }

    /// Une constante dans un registre, par le plus court.
    fn constante(&mut self, cible: u8, valeur: u64) {
        if let Ok(petite) = u32::try_from(valeur) {
            if cible >= 8 {
                self.octet(0x41);
            }
            self.octet(0xB8 + (cible & 7));
            self.i32(petite as i32);
        } else if let Ok(signee) = i32::try_from(valeur as i64) {
            // `mov r/m64, imm32` étendu en signe.
            self.modrm(8, &[0xC7], 0, Rm::R(cible), false);
            self.i32(signee);
        } else {
            self.octet(0x48 | (cible >> 3));
            self.octet(0xB8 + (cible & 7));
            self.octets(&valeur.to_le_bytes());
        }
    }

    /// Une opération à deux opérandes, `rm op= registre` : `numero` est le
    /// champ des opcodes `00`..`3f` (0 add, 1 or, 4 and, 5 sub, 6 xor, 7
    /// cmp) ; `0x85` pour `test`.
    fn alu_rr(&mut self, numero: u8, taille: u8, rm: Rm, source: u8) {
        let opcode = if numero == 0x85 {
            if taille == 1 {
                0x84
            } else {
                0x85
            }
        } else {
            (numero << 3) | u8::from(taille != 1)
        };
        self.modrm(taille, &[opcode], source, rm, taille == 1);
    }

    /// `rm op= immédiat` (8 ou 32 bits étendus en signe), même champ.
    fn alu_ri(&mut self, numero: u8, taille: u8, rm: Rm, valeur: i32) {
        if taille == 1 {
            self.modrm(1, &[0x80], numero, rm, true);
            self.octet(valeur as u8);
        } else if let Ok(petite) = i8::try_from(valeur) {
            self.modrm(taille, &[0x83], numero, rm, false);
            self.octet(petite as u8);
        } else if taille == 2 {
            self.modrm(2, &[0x81], numero, rm, false);
            self.octets(&(valeur as u16).to_le_bytes());
        } else {
            self.modrm(taille, &[0x81], numero, rm, false);
            self.i32(valeur);
        }
    }

    /// `test rm, immédiat`.
    fn test_ri(&mut self, taille: u8, rm: Rm, valeur: i32) {
        if taille == 1 {
            self.modrm(1, &[0xF6], 0, rm, true);
            self.octet(valeur as u8);
        } else {
            self.modrm(taille, &[0xF7], 0, rm, false);
            self.i32(valeur);
        }
    }

    /// `test r, r` sur 32 ou 64 bits.
    fn tester(&mut self, taille: u8, registre: u8) {
        self.modrm(taille, &[0x85], registre, Rm::R(registre), false);
    }

    /// `inc`, `dec` (`FE`/`FF` /0 /1), `not`, `neg` (`F6`/`F7` /2 /3).
    fn unaire(&mut self, extension: u8, taille: u8, registre: u8) {
        let opcode = match (extension, taille) {
            (0 | 1, 1) => 0xFE,
            (0 | 1, _) => 0xFF,
            (_, 1) => 0xF6,
            _ => 0xF7,
        };
        self.modrm(taille, &[opcode], extension, Rm::R(registre), taille == 1);
    }

    /// `shl`/`shr`/`sar` (/4 /5 /7) d'un registre de 64 ou 32 bits.
    fn decaler(&mut self, extension: u8, taille: u8, registre: u8, compte: u8) {
        self.modrm(taille, &[0xC1], extension, Rm::R(registre), false);
        self.octet(compte);
    }

    /// `jcc rel32` vers une étiquette.
    fn jcc(&mut self, condition: u8, e: Etiquette) {
        self.octets(&[0x0F, 0x80 | condition]);
        self.vers(e);
    }

    /// `jcc rel32` vers une routine.
    fn jcc_absolu(&mut self, condition: u8, cible: u64) {
        self.octets(&[0x0F, 0x80 | condition]);
        self.vers_absolu(cible);
    }

    fn jmp(&mut self, e: Etiquette) {
        self.octet(0xE9);
        self.vers(e);
    }

    fn jmp_absolu(&mut self, cible: u64) {
        self.octet(0xE9);
        self.vers_absolu(cible);
    }

    /// `call rel32` vers une routine.
    fn call_absolu(&mut self, cible: u64) {
        self.octet(0xE8);
        self.vers_absolu(cible);
    }

    /// `call` d'une fonction de Rust, par `rax`.
    fn appeler(&mut self, adresse: u64) {
        self.constante(RAX, adresse);
        self.octets(&[0xFF, 0xD0]);
    }

    /// `jmp` vers une fonction de Rust, par `rax` : un appel terminal, depuis
    /// une routine, qui rend la main à l'appelant de la routine.
    fn sauter(&mut self, adresse: u64) {
        self.constante(RAX, adresse);
        self.octets(&[0xFF, 0xE0]);
    }

    fn push(&mut self, registre: u8) {
        if registre >= 8 {
            self.octet(0x41);
        }
        self.octet(0x50 + (registre & 7));
    }

    fn pop(&mut self, registre: u8) {
        if registre >= 8 {
            self.octet(0x41);
        }
        self.octet(0x58 + (registre & 7));
    }
}

// Les conditions de l'hôte.
const JAE: u8 = 0x3;
const JE: u8 = 0x4;
const JNE: u8 = 0x5;
const JA: u8 = 0x7;

/// Les registres que le code d'un bloc garde à l'hôte qui l'appelle.
const GARDES: [u8; 6] = [RBX, RBP, R12, R13, R14, R15];

/// **Le prologue de tout bloc**, toujours les mêmes octets : le chaînage
/// entre dans le bloc suivant juste après lui (`longueur_du_prologue`).
fn prologue(a: &mut Asm) {
    for registre in GARDES {
        a.push(registre);
    }
    // Six registres et l'adresse de retour : la pile reste alignée sur
    // seize octets pour les appels.
    a.alu_ri(5, 8, Rm::R(RSP), 8);
    a.copier(8, RBX, RDI);
    a.copier(8, R12, RSI);
    a.mov(R13, m(R12, contexte::RAM));
    a.mov(R14, m(R12, contexte::LONGUEUR));
    a.mov(R15, m(R12, contexte::BASE));
}

fn longueur_du_prologue() -> u64 {
    let mut a = Asm::new(0);
    prologue(&mut a);
    a.code.len() as u64
}

/// Le hachage de `pc::blocs::case`, et la largeur de la table.
const HACHAGE: u64 = 0x9E37_79B9_7F4A_7C15;
const _: () = assert!(crate::pc::blocs::LOGEMENTS == 1 << 15);

// ---- Les routines ----

/// **Les adresses des routines** que les blocs appellent.
pub(super) struct Routines {
    /// `tampon[largeur][ecriture]` : l'adresse invitée dans `rsi`, rend dans
    /// `rdi` l'adresse de l'hôte, ou zéro quand le chemin rapide ne passe
    /// pas. Prend `rax`, `rcx` et `r11`.
    tampon: [[u64; 2]; 4],
    /// Appeler la forme de l'instruction `rbp` ; rend `Suite` dans `eax`.
    appel: u64,
    /// Sortir après une forme qui a rendu `eax` (1, un saut ; 2, une faute)
    /// pour l'instruction `rbp`.
    non_suivante: u64,
    /// Sortir avec `rax`.
    sortie: u64,
    /// Les six bits arithmétiques dans `rax` (`rapide::arithmetiques`).
    /// Prend tout ce qu'un appel de C prend.
    drapeaux: u64,
    /// **Passer au bloc suivant sans sortir** : `rax` porte la sortie du bloc
    /// courant (rendue telle quelle si le suivant ne se prend pas), `rsi`
    /// l'adresse physique du suivant, RIP exact.
    enchainer: u64,
}

impl Routines {
    pub(super) fn vides() -> Self {
        Self {
            tampon: [[0; 2]; 4],
            appel: 0,
            non_suivante: 0,
            sortie: 0,
            drapeaux: 0,
            enchainer: 0,
        }
    }
}

fn rang_de_largeur(taille: u8) -> usize {
    match taille {
        1 => 0,
        2 => 1,
        4 => 2,
        _ => 3,
    }
}

/// **Les routines**, assemblées pour vivre à `origine`.
pub(super) fn routines(origine: u64, appels: &Appels) -> (Vec<u8>, Routines) {
    let mut a = Asm::new(origine);
    let mut r = Routines::vides();

    r.sortie = a.ici();
    a.alu_ri(0, 8, Rm::R(RSP), 8);
    for registre in GARDES.iter().rev() {
        a.pop(*registre);
    }
    a.octet(0xC3);

    r.non_suivante = a.ici();
    let faute = a.etiquette();
    a.alu_ri(7, 4, Rm::R(RAX), 1);
    a.jcc(JNE, faute);
    // Un saut : l'instruction compte.
    a.modrm(4, &[0x8D], RAX, m(RBP, 1), false);
    a.constante(RCX, SAUT << 32);
    a.alu_rr(1, 8, Rm::R(RAX), RCX);
    a.jmp_absolu(r.sortie);
    a.poser(faute);
    a.copier(4, RAX, RBP);
    a.constante(RCX, FAUTE << 32);
    a.alu_rr(1, 8, Rm::R(RAX), RCX);
    a.jmp_absolu(r.sortie);

    r.appel = a.ici();
    a.copier(8, RDI, RBX);
    a.mov(RSI, m(R12, contexte::BLOC));
    a.lea(RDX, m(RSI, d::GENERALES));
    a.copier(4, RAX, RBP);
    a.decaler(4, 4, RAX, 5);
    a.lea(
        RSI,
        Rm::M {
            base: RSI,
            index: Some((RAX, 0)),
            deplacement: d::UOPS,
        },
    );
    a.sauter(appels.appeler);

    r.drapeaux = a.ici();
    let calcul = a.etiquette();
    a.alu_ri(7, 1, m(RBX, d::DRAPEAUX_OP), 0);
    a.jcc(JNE, calcul);
    a.mov(RAX, m(RBX, d::DRAPEAUX_ARITH));
    a.octet(0xC3);
    a.poser(calcul);
    a.copier(8, RDI, RBX);
    a.sauter(appels.arithmetiques);

    r.enchainer = a.ici();
    routine_d_enchainement(&mut a, r.sortie);

    for taille in [1u8, 2, 4, 8] {
        for ecriture in [false, true] {
            r.tampon[rang_de_largeur(taille)][usize::from(ecriture)] = a.ici();
            routine_du_tampon(&mut a, taille, ecriture);
        }
    }
    (a.finir(), r)
}

/// **Le chaînage** : ce que `Machine::un_bloc` ferait du bloc suivant,
/// quand il tombe dans la même page — le budget, la RAM, la case par le
/// hachage de `Blocs::trouver`, le tampon (l'époque et la génération de sa
/// page : `Trouve::Juste`), un bloc entier dans ce qui reste, et son code
/// traduit dans la zone d'aujourd'hui. Tout cela tient : on entre dans son
/// code après le prologue. Une seule chose manque : on sort, et la boucle
/// décide comme toujours.
fn routine_d_enchainement(a: &mut Asm, sortie: u64) {
    let sortir = a.etiquette();
    let trouve = a.etiquette();
    // rcx : les instructions du bloc courant ; rdx : le budget après lui.
    a.copier(4, RCX, RAX);
    a.mov(RDX, m(R12, contexte::RESTE));
    a.alu_rr(5, 8, Rm::R(RDX), RCX);
    // Soixante-quatre octets dans la RAM (`un_bloc`).
    a.lea(RDI, m(RSI, 64));
    a.alu_rr(7, 8, Rm::R(RDI), R14);
    a.jcc(JA, sortir);
    // La génération de sa page, dans la RAM suivie.
    a.copier(8, RDI, RSI);
    a.decaler(5, 8, RDI, 12);
    a.alu_rr(7, 8, m(R12, contexte::PAGES), RDI);
    a.jcc(0x6, sortir); // jbe : pages <= page
    a.mov(R8, m(R12, contexte::GENERATIONS));
    a.charger(
        4,
        R8,
        Rm::M {
            base: R8,
            index: Some((RDI, 2)),
            deplacement: 0,
        },
    );
    // La case : `(physique * HACHAGE) >> 49`, paire.
    a.constante(RDI, HACHAGE);
    a.modrm(8, &[0x0F, 0xAF], RDI, Rm::R(RSI), false); // imul rdi, rsi
    a.decaler(5, 8, RDI, 49);
    a.alu_ri(4, 4, Rm::R(RDI), !1);
    // imul r9, rdi, TAILLE_BLOC
    a.modrm(8, &[0x69], R9, Rm::R(RDI), false);
    a.i32(d::TAILLE_BLOC);
    a.mov(R10, m(R12, contexte::CASES));
    a.alu_rr(0, 8, Rm::R(R9), R10);
    a.lea(R10, m(RSI, 1));
    a.alu_rr(7, 8, m(R9, d::ETIQUETTE), R10);
    a.jcc(JE, trouve);
    a.alu_ri(0, 8, Rm::R(R9), d::TAILLE_BLOC);
    a.alu_ri(0, 4, Rm::R(RDI), 1);
    a.alu_rr(7, 8, m(R9, d::ETIQUETTE), R10);
    a.jcc(JNE, sortir);
    a.poser(trouve);
    // Le tampon : l'époque, puis la génération.
    a.mov(R10, m(R12, contexte::EPOQUE));
    a.mov(R10, m(R10, 0));
    a.alu_rr(7, 8, m(R9, d::EPOQUE), R10);
    a.jcc(JNE, sortir);
    a.alu_rr(7, 4, m(R9, d::GENERATION), R8);
    a.jcc(JNE, sortir);
    // Entier dans le budget, et pas vide.
    a.charger(1, R10, m(R9, d::NOMBRE));
    a.tester(4, R10);
    a.jcc(JE, sortir);
    a.alu_rr(7, 8, Rm::R(R10), RDX);
    a.jcc(JA, sortir);
    // Son code, dans la zone d'aujourd'hui.
    a.charger(4, R10, m(R9, d::JIT_ZONE));
    a.alu_rr(7, 8, m(R12, contexte::ZONE), R10);
    a.jcc(JNE, sortir);
    a.mov(R10, m(R9, d::JIT_CODE));
    a.tester(8, R10);
    a.jcc(JE, sortir);
    // Y aller.
    a.ranger(8, m(R12, contexte::RESTE), RDX);
    a.alu_rr(0, 8, m(R12, contexte::DEJA), RCX);
    a.ranger(8, m(R12, contexte::BLOC), R9);
    a.ranger(8, m(R12, contexte::DEBUT), RSI);
    a.ranger(8, m(R12, contexte::PLACE), RDI);
    a.alu_ri(0, 8, m(R12, contexte::ENCHAINES), 1);
    a.alu_ri(0, 8, Rm::R(R10), longueur_du_prologue() as i32);
    a.octets(&[0x41, 0xFF, 0xE2]); // jmp r10
    a.poser(sortir);
    a.jmp_absolu(sortie);
}

/// **Le chemin rapide du tampon**, refait : ce que `Cpu::fast_place` puis
/// `GuestMemory::read`/`write` décident, au bit près — `rdi` à zéro
/// exactement quand `read_memory_fast` (`ecriture` faux) ou
/// `write_memory_fast` iraient à leur chemin lent.
///
/// Trois raccourcis, chacun exact :
///
/// - *les droits demandés sont posés à l'entrée* (`Contexte::droits`) :
///   l'anneau ne change jamais dans un bloc ni d'un bloc chaîné à l'autre
///   (`syscall`, `iretq`, `sysret` n'entrent dans aucun bloc) ;
/// - *l'accès qui sort de sa page manque l'étiquette* : la page de son
///   dernier octet est comparée à celle de la case, et une case ne tient que
///   des pages de son rang — la page d'après n'y est jamais ;
/// - *la fenêtre de la RAM se juge sur la trame* : `r14` est la longueur de
///   la RAM arrondie à la page en dessous, donc une trame qui commence dedans
///   y tient entière, et l'accès qui tient dans sa page aussi.
fn routine_du_tampon(a: &mut Asm, taille: u8, ecriture: bool) {
    let droits = if ecriture {
        contexte::DROITS_ECRITURE
    } else {
        contexte::DROITS_LECTURE
    };
    let cases = tlb::CASES as i32;
    let lent = a.etiquette();
    // La pagination : le bit 31 de CR0, dans son quatrième octet.
    a.test_ri(1, m(RBX, d::CONTROLE + 3), 0x80);
    a.jcc(JE, lent);
    // La case : `entries[(page >> 12) & 1023]`, de vingt-quatre octets.
    a.mov(RDI, m(RBX, d::TLB));
    a.tester(8, RDI);
    a.jcc(JE, lent);
    a.copier(4, RAX, RSI);
    a.decaler(5, 4, RAX, 12);
    a.alu_ri(4, 4, Rm::R(RAX), (TLB_SLOTS - 1) as i32);
    a.lea(
        RAX,
        Rm::M {
            base: RAX,
            index: Some((RAX, 1)),
            deplacement: 0,
        },
    );
    a.lea(
        RDI,
        Rm::M {
            base: RDI,
            index: Some((RAX, 3)),
            deplacement: 0,
        },
    );
    // L'étiquette : la page du dernier octet, plus un.
    a.lea(RAX, m(RSI, i32::from(taille) - 1));
    a.alu_ri(4, 8, Rm::R(RAX), -4096);
    a.alu_ri(0, 8, Rm::R(RAX), 1);
    a.alu_rr(7, 8, m(RDI, cases + tlb::ETIQUETTE as i32), RAX);
    a.jcc(JNE, lent);
    // Les droits.
    a.charger(1, RAX, m(RDI, cases + tlb::DROITS as i32));
    a.charger(4, RCX, m(R12, droits));
    a.alu_rr(4, 4, Rm::R(RAX), RCX);
    a.alu_rr(7, 4, Rm::R(RAX), RCX);
    a.jcc(JNE, lent);
    // La trame dans la RAM, puis l'adresse de l'hôte.
    a.mov(RAX, m(RDI, cases + tlb::TRAME as i32));
    a.alu_rr(5, 8, Rm::R(RAX), R15);
    a.alu_rr(7, 8, Rm::R(RAX), R14);
    a.jcc(JAE, lent);
    a.copier(4, RCX, RSI);
    a.alu_ri(4, 4, Rm::R(RCX), 0xFFF);
    a.alu_rr(0, 8, Rm::R(RAX), R13);
    a.lea(
        RDI,
        Rm::M {
            base: RAX,
            index: Some((RCX, 0)),
            deplacement: 0,
        },
    );
    a.octet(0xC3);
    a.poser(lent);
    // `xor edi, edi`
    a.modrm(4, &[0x31], RDI, Rm::R(RDI), false);
    a.octet(0xC3);
}

// ---- Les blocs ----

/// Le champ d'opcode de chaque opération de `rapide`.
fn numero_alu(op: u8) -> u8 {
    match op {
        ADD => 0,
        OR => 1,
        SUB | CMP => 5,
        XOR => 6,
        // `and`, et `test`, qui se calcule comme lui sans rien ranger.
        _ => 4,
    }
}

/// Ce qu'une instruction laisse au bout du bloc : du code hors du chemin.
struct Annexe {
    /// Appeler la forme de l'instruction `rang` depuis l'état d'avant elle
    /// (RIP en retard de `pendant`), puis reprendre à `retour`.
    entree: Etiquette,
    retour: Etiquette,
    rang: usize,
    pendant: i32,
}

struct Traducteur<'a> {
    a: Asm,
    appels: &'a Appels,
    routines: &'a Routines,
    instructions: &'a [Instruction],
    annexes: Vec<Annexe>,
    /// De combien RIP est en retard sur l'instruction courante.
    pendant: i32,
    /// L'adresse physique du premier octet du bloc.
    debut: u64,
    /// Les drapeaux de chaque instruction sont-ils morts (`drapeaux_morts`) ?
    morts: Vec<bool>,
    /// Ceux de l'instruction en cours.
    mort: bool,
}

/// **Traduire un bloc** en une fonction `extern "C" fn(*mut Cpu, *mut
/// Contexte) -> u64` qui rend `(raison << 32) | instructions retirées`,
/// assemblée pour vivre à `origine`.
pub(super) fn traduire(
    instructions: &[Instruction],
    origine: u64,
    debut: u64,
    routines: &Routines,
    appels: &Appels,
) -> Vec<u8> {
    let mut t = Traducteur {
        a: Asm::new(origine),
        appels,
        routines,
        instructions,
        annexes: Vec::new(),
        pendant: 0,
        debut,
        morts: drapeaux_morts(instructions),
        mort: false,
    };
    prologue(&mut t.a);
    debug_assert_eq!(t.a.code.len() as u64, longueur_du_prologue());
    for rang in 0..instructions.len() {
        t.instruction(rang);
    }
    t.rip_exact();
    // Le bloc d'après, à la suite, s'il est dans la même page.
    let fin = debut
        + instructions
            .iter()
            .map(|i| u64::from(i.uop.longueur))
            .sum::<u64>();
    if fin & !0xFFF == debut & !0xFFF {
        t.a.constante(RSI, fin);
        t.a.constante(RAX, (FIN << 32) | instructions.len() as u64);
        let enchainer = t.routines.enchainer;
        t.a.jmp_absolu(enchainer);
    } else {
        t.sortir_tel_quel(FIN, instructions.len());
    }
    for annexe in std::mem::take(&mut t.annexes) {
        t.annexe(annexe);
    }
    t.a.finir()
}

impl Traducteur<'_> {
    /// **Écrire le retard de RIP**, sans l'oublier : pour un chemin de côté
    /// (une sortie), après lequel le chemin principal le doit encore.
    fn rip_exact(&mut self) {
        if self.pendant != 0 {
            let pendant = self.pendant;
            self.a.alu_ri(0, 8, m(RBX, d::RIP), pendant);
        }
    }

    /// Écrire le retard de RIP, et repartir de zéro.
    fn materialiser(&mut self) {
        self.rip_exact();
        self.pendant = 0;
    }

    /// Rendre `(raison, rang)` à la boucle, RIP tel qu'il est en mémoire.
    fn sortir_tel_quel(&mut self, raison: u64, rang: usize) {
        self.a.constante(RAX, (raison << 32) | rang as u64);
        let sortie = self.routines.sortie;
        self.a.jmp_absolu(sortie);
    }

    fn longueur(&self, rang: usize) -> i32 {
        i32::from(self.instructions[rang].uop.longueur)
    }

    /// **Appeler la forme de l'instruction `rang`**, RIP déjà exact : un
    /// saut ou une faute sortent du bloc ; une suite normale relit le bloc
    /// si l'instruction a pu écrire.
    fn appeler_la_forme(&mut self, rang: usize) {
        let routines = self.routines;
        let a = &mut self.a;
        a.constante(RBP, rang as u64);
        a.call_absolu(routines.appel);
        a.tester(4, RAX);
        a.jcc_absolu(JNE, routines.non_suivante);
        let instruction = &self.instructions[rang];
        if instruction.ecrit && rang + 1 < self.instructions.len() {
            let octet = self.instructions[rang + 1].octet;
            let longueur = self.longueur(rang);
            let verifier = self.appels.verifier;
            let a = &mut self.a;
            a.copier(8, RDI, R12);
            a.constante(RSI, u64::from(octet));
            a.appeler(verifier);
            a.tester(4, RAX);
            let intact = a.etiquette();
            a.jcc(JNE, intact);
            a.alu_ri(0, 8, m(RBX, d::RIP), longueur);
            self.sortir_tel_quel(ARRET, rang + 1);
            self.a.poser(intact);
        }
    }

    fn instruction(&mut self, rang: usize) {
        let instruction = &self.instructions[rang];
        let longueur = self.longueur(rang);
        self.mort = self.morts[rang];
        let Some(gabarit) = instruction.gabarit.filter(|g| traduisible(*g)) else {
            self.materialiser();
            self.appeler_la_forme(rang);
            self.pendant = longueur;
            return;
        };
        let lent = self.a.etiquette();
        let retour = self.a.etiquette();
        // Le chemin hors ligne n'existe que pour les gabarits qui peuvent
        // renoncer : un accès à la mémoire, une cible à juger.
        if renonce(gabarit) {
            self.annexes.push(Annexe {
                entree: lent,
                retour,
                rang,
                pendant: self.pendant,
            });
        }
        let uop = instruction.uop;
        match gabarit {
            Gabarit::Alu {
                op,
                w,
                forme,
                adresse,
            } => self.alu(op, w, forme, adresse, &uop, lent),
            Gabarit::Unaire { op, w } => self.unaire(op, w, &uop),
            Gabarit::Decalage { op, w, cl } => self.decalage(op, w, cl, &uop),
            Gabarit::Transfert { w, s, imm } => {
                if imm {
                    self.a.constante(RDX, uop.imm & masque(s));
                } else {
                    self.a.charger(s, RDX, reg(uop.src));
                }
                self.ecrire_registre(w, uop.dst, RDX);
            }
            Gabarit::Extension { w, s } => {
                self.a.charger(s, RDX, reg(uop.src));
                self.a.etendre(s, RDX);
                self.ecrire_registre(w, uop.dst, RDX);
            }
            Gabarit::Chargement {
                w,
                s,
                signe,
                adresse,
            } => {
                self.adresse(adresse, &uop);
                self.tampon(s, false, lent);
                self.a.charger(s, RDX, m(RDI, 0));
                if signe {
                    self.a.etendre(s, RDX);
                }
                self.ecrire_registre(w, uop.dst, RDX);
            }
            Gabarit::Rangement { w, imm, adresse } => {
                self.adresse(adresse, &uop);
                self.tampon(w, true, lent);
                if imm {
                    self.a.constante(RDX, uop.imm & masque(w));
                } else {
                    self.a.charger(w, RDX, reg(uop.src));
                }
                self.a.ranger(w, m(RDI, 0), RDX);
            }
            Gabarit::Lea { w, adresse } => {
                self.adresse(adresse, &uop);
                self.ecrire_registre(w, uop.dst, RSI);
            }
            Gabarit::Jcc(condition) => {
                self.drapeaux();
                let pris = self.condition(condition);
                let suite = self.a.etiquette();
                self.a.jcc(if pris { JE } else { JNE }, suite);
                self.saut_relatif(&uop, lent, rang);
                self.a.poser(suite);
            }
            Gabarit::Jmp => self.saut_relatif(&uop, lent, rang),
            Gabarit::Call => {
                // `apres` dans r8, la cible dans r9, jugée avant d'empiler.
                let pendant = self.pendant;
                let a = &mut self.a;
                a.mov(R8, m(RBX, d::RIP));
                a.alu_ri(0, 8, Rm::R(R8), pendant + i32::from(uop.longueur));
                a.constante(R9, uop.imm);
                a.alu_rr(0, 8, Rm::R(R9), R8);
                self.canonique(R9, lent);
                let a = &mut self.a;
                a.mov(RSI, reg(4));
                a.alu_ri(5, 8, Rm::R(RSI), 8);
                self.tampon(8, true, lent);
                let a = &mut self.a;
                a.ranger(8, m(RDI, 0), R8);
                a.ranger(8, reg(4), RSI);
                a.ranger(8, m(RBX, d::RIP), R9);
                self.sortir_tel_quel(SAUT, rang + 1);
            }
            Gabarit::Ret => {
                self.a.mov(RSI, reg(4));
                self.tampon(8, false, lent);
                self.a.mov(R9, m(RDI, 0));
                self.canonique(R9, lent);
                let a = &mut self.a;
                a.alu_ri(0, 8, Rm::R(RSI), 8 + (uop.imm & 0xFFFF) as i32);
                a.ranger(8, reg(4), RSI);
                a.ranger(8, m(RBX, d::RIP), R9);
                self.sortir_tel_quel(SAUT, rang + 1);
            }
            Gabarit::PushRegistre => {
                let a = &mut self.a;
                a.mov(R8, reg(uop.dst));
                a.mov(RSI, reg(4));
                a.alu_ri(5, 8, Rm::R(RSI), 8);
                self.tampon(8, true, lent);
                let a = &mut self.a;
                a.ranger(8, m(RDI, 0), R8);
                a.ranger(8, reg(4), RSI);
            }
            Gabarit::PopRegistre => {
                self.a.mov(RSI, reg(4));
                self.tampon(8, false, lent);
                let a = &mut self.a;
                a.mov(R8, m(RDI, 0));
                a.alu_ri(0, 8, Rm::R(RSI), 8);
                a.ranger(8, reg(4), RSI);
                a.ranger(8, reg(uop.dst), R8);
            }
            Gabarit::Nop => {}
        }
        self.a.poser(retour);
        self.pendant += longueur;
    }

    /// **`jmp`, ou `jcc` pris** : la cible depuis RIP, jugée (une cible qui
    /// n'est pas canonique rend l'instruction à sa forme, qui faute), posée,
    /// et la sortie.
    fn saut_relatif(&mut self, uop: &Uop, lent: Etiquette, rang: usize) {
        let decalage = (self.pendant as u64)
            .wrapping_add(u64::from(uop.longueur))
            .wrapping_add(uop.imm);
        let a = &mut self.a;
        a.mov(R9, m(RBX, d::RIP));
        // RIP de l'instruction, exact, dans r8 : pour la page.
        a.lea(R8, m(R9, self.pendant));
        a.constante(RCX, decalage);
        a.alu_rr(0, 8, Rm::R(R9), RCX);
        self.canonique(R9, lent);
        let enchainer = self.routines.enchainer;
        let page = self.debut & !0xFFF;
        let a = &mut self.a;
        a.ranger(8, m(RBX, d::RIP), R9);
        // **La cible dans la même page virtuelle que le bloc** : la même page
        // physique, que rien n'a pu remapper depuis l'entrée (aucune
        // instruction de système n'entre dans un bloc). Le bloc d'y être se
        // juge par la routine.
        let ailleurs = a.etiquette();
        a.alu_rr(6, 8, Rm::R(R8), R9);
        a.decaler(5, 8, R8, 12);
        a.jcc(JNE, ailleurs);
        a.copier(4, RSI, R9);
        a.alu_ri(4, 4, Rm::R(RSI), 0xFFF);
        a.constante(RCX, page);
        a.alu_rr(1, 8, Rm::R(RSI), RCX);
        a.constante(RAX, (SAUT << 32) | (rang as u64 + 1));
        a.jmp_absolu(enchainer);
        a.poser(ailleurs);
        self.sortir_tel_quel(SAUT, rang + 1);
    }

    /// `registre` est-il canonique ? Sinon, vers `lent`. Prend `rcx`.
    fn canonique(&mut self, registre: u8, lent: Etiquette) {
        let a = &mut self.a;
        a.copier(8, RCX, registre);
        a.decaler(4, 8, RCX, 16);
        a.decaler(7, 8, RCX, 16);
        a.alu_rr(7, 8, Rm::R(RCX), registre);
        a.jcc(JNE, lent);
    }

    /// **Les six bits arithmétiques dans `rax`.** Prend tout ce qu'un appel
    /// de C prend : à faire avant de charger quoi que ce soit.
    fn drapeaux(&mut self) {
        let drapeaux = self.routines.drapeaux;
        self.a.call_absolu(drapeaux);
    }

    /// **La condition `c` sur les bits de `rax`** : laisse ZF de l'hôte à
    /// zéro quand le prédicat de base (`c >> 1`) tient. Rend vrai quand le
    /// saut est pris sur ce prédicat (`c` pair), faux quand il l'est sur son
    /// contraire. Prend `rcx` et `rdx`.
    fn condition(&mut self, c: u8) -> bool {
        let a = &mut self.a;
        match c >> 1 {
            0 => a.test_ri(4, Rm::R(RAX), 0x800),
            1 => a.test_ri(4, Rm::R(RAX), 0x1),
            2 => a.test_ri(4, Rm::R(RAX), 0x40),
            3 => a.test_ri(4, Rm::R(RAX), 0x41),
            4 => a.test_ri(4, Rm::R(RAX), 0x80),
            5 => a.test_ri(4, Rm::R(RAX), 0x4),
            predicat => {
                // SF ^ OF, sur le bit 7 de rcx.
                a.copier(4, RCX, RAX);
                a.decaler(5, 4, RCX, 4);
                a.alu_rr(6, 4, Rm::R(RCX), RAX);
                a.alu_ri(4, 4, Rm::R(RCX), 0x80);
                if predicat == 7 {
                    a.copier(4, RDX, RAX);
                    a.alu_ri(4, 4, Rm::R(RDX), 0x40);
                    a.alu_rr(1, 4, Rm::R(RCX), RDX);
                }
                a.tester(4, RCX);
            }
        }
        c & 1 == 0
    }

    /// **L'adresse de l'opérande dans `rsi`**, par la forme choisie au
    /// décodage. Prend `rdi`.
    fn adresse(&mut self, forme: u8, uop: &Uop) {
        let pendant = self.pendant;
        let a = &mut self.a;
        match forme {
            BASE => {
                a.mov(RSI, reg(uop.base));
                a.lea(RSI, m(RSI, uop.deplacement));
            }
            INDEXEE => {
                a.mov(RSI, reg(uop.base));
                a.mov(RDI, reg(uop.index));
                a.lea(
                    RSI,
                    Rm::M {
                        base: RSI,
                        index: Some((RDI, uop.echelle)),
                        deplacement: uop.deplacement,
                    },
                );
            }
            _ => {
                // Relative : depuis l'octet qui suit l'instruction, RIP en
                // retard de `pendant`.
                debug_assert_eq!(forme, RELATIVE);
                a.mov(RSI, m(RBX, d::RIP));
                let decalage =
                    i64::from(uop.deplacement) + i64::from(uop.longueur) + i64::from(pendant);
                match i32::try_from(decalage) {
                    Ok(petit) => a.lea(RSI, m(RSI, petit)),
                    Err(_) => {
                        a.constante(RDI, decalage as u64);
                        a.alu_rr(0, 8, Rm::R(RSI), RDI);
                    }
                }
            }
        }
    }

    /// **L'accès de `taille` octets à `rsi`** par la routine du tampon :
    /// l'adresse de l'hôte dans `rdi`, ou `lent`.
    fn tampon(&mut self, taille: u8, ecriture: bool, lent: Etiquette) {
        let routine = self.routines.tampon[rang_de_largeur(taille)][usize::from(ecriture)];
        let a = &mut self.a;
        a.call_absolu(routine);
        a.tester(8, RDI);
        a.jcc(JE, lent);
    }

    /// **Écrire un registre de l'invité à sa largeur** (`rapide::ecrire`) :
    /// huit octets entiers, quatre étendus de zéros, deux et un rangés dans
    /// ses octets bas — la mémoire du registre est petit-boutiste.
    fn ecrire_registre(&mut self, w: u8, numero: u8, source: u8) {
        let a = &mut self.a;
        match w {
            8 => a.ranger(8, reg(numero), source),
            4 => {
                a.copier(4, source, source);
                a.ranger(8, reg(numero), source);
            }
            _ => a.ranger(w, reg(numero), source),
        }
    }

    /// **Les six bits d'une opération que l'hôte vient de faire**, dans
    /// `rax` : SF, ZF, AF, PF et CF par `lahf`, OF par `seto`. Le résultat
    /// doit déjà être à l'abri : `lahf` écrit AH. Prend `rcx`.
    fn bits_de_l_hote(&mut self) {
        let a = &mut self.a;
        a.octets(&[0x0F, 0x90, 0xC1]); // seto cl
        a.octet(0x9F); // lahf
        a.octets(&[0x0F, 0xB6, 0xC4]); // movzx eax, ah
        a.alu_ri(4, 4, Rm::R(RAX), 0xD5);
        a.charger(1, RCX, Rm::R(RCX));
        a.decaler(4, 4, RCX, 11);
        a.alu_rr(1, 4, Rm::R(RAX), RCX);
    }

    /// Poser les six bits de `rax`, connus (`rapide::poser`).
    fn poser_drapeaux(&mut self) {
        let a = &mut self.a;
        a.modrm(1, &[0xC6], 0, m(RBX, d::DRAPEAUX_OP), false);
        a.octet(0);
        a.ranger(8, m(RBX, d::DRAPEAUX_ARITH), RAX);
    }

    /// **`rapide::alu`** : la gauche dans r8, la droite dans r9, le résultat
    /// dans rdx, l'opération faite par l'hôte à la même largeur — ses
    /// drapeaux sont ceux du silicium, et ceux de `rapide`, sauf AF des
    /// opérations logiques, que `rapide` calcule sur les trois termes.
    fn alu(&mut self, op: u8, w: u8, forme: u8, adresse: u8, uop: &Uop, lent: Etiquette) {
        let ecrit = op != CMP && op != TEST;
        match forme {
            MR | MI => {
                self.adresse(adresse, uop);
                self.tampon(w, ecrit, lent);
                self.a.charger(w, R8, m(RDI, 0));
            }
            RM => {
                self.adresse(adresse, uop);
                self.tampon(w, false, lent);
                self.a.charger(w, R9, m(RDI, 0));
                self.a.charger(w, R8, reg(uop.dst));
            }
            _ => self.a.charger(w, R8, reg(uop.dst)),
        }
        match forme {
            RI | MI => self.a.constante(R9, uop.imm & masque(w)),
            RR | MR => self.a.charger(w, R9, reg(uop.src)),
            _ => {}
        }
        let a = &mut self.a;
        a.copier(8, RAX, R8);
        a.alu_rr(numero_alu(op), w, Rm::R(RAX), R9);
        a.copier(8, RDX, RAX);
        if !self.mort {
            self.bits_de_l_hote();
        }
        if !self.mort && matches!(op, OR | AND | XOR | TEST) {
            let a = &mut self.a;
            a.alu_ri(4, 4, Rm::R(RAX), 0xC5);
            a.copier(8, RCX, R8);
            a.alu_rr(6, 8, Rm::R(RCX), R9);
            a.alu_rr(6, 8, Rm::R(RCX), RDX);
            a.alu_ri(4, 4, Rm::R(RCX), 0x10);
            a.alu_rr(1, 4, Rm::R(RAX), RCX);
        }
        if ecrit {
            match forme {
                MR | MI => self.a.ranger(w, m(RDI, 0), RDX),
                _ => self.ecrire_registre(w, uop.dst, RDX),
            }
        }
        if !self.mort {
            self.poser_drapeaux();
        }
    }

    /// **`rapide::decalage`** sur trente-deux ou soixante-quatre bits : le
    /// compte masqué ; nul, la destination récrite à sa largeur et aucun
    /// drapeau ; sinon le décalage de l'hôte, dont CF (le dernier bit sorti),
    /// ZF, SF et PF sont ceux de `rapide` pour un compte sous la largeur, AF
    /// à zéro, et OF calculé comme `rapide` le pose — l'hôte ne le définit
    /// que pour un compte d'un.
    fn decalage(&mut self, op: u8, w: u8, cl: bool, uop: &Uop) {
        let mort = self.mort;
        let a = &mut self.a;
        a.charger(w, R8, reg(uop.dst));
        if cl {
            a.charger(4, RCX, reg(1));
        } else {
            a.constante(RCX, uop.imm & 0xFF);
        }
        a.alu_ri(4, 4, Rm::R(RCX), if w == 8 { 63 } else { 31 });
        let nul = a.etiquette();
        let fin = a.etiquette();
        a.jcc(JE, nul);
        a.copier(8, RAX, R8);
        // `shl`/`shr`/`sar` rax (ou eax), cl : D3 /4 /5 /7.
        let extension = match op {
            SHL => 4,
            SHR => 5,
            _ => 7,
        };
        a.modrm(w, &[0xD3], extension, Rm::R(RAX), false);
        a.copier(8, RDX, RAX);
        if !mort {
            a.octet(0x9F); // lahf
            a.octets(&[0x0F, 0xB6, 0xC4]); // movzx eax, ah
            a.alu_ri(4, 4, Rm::R(RAX), 0xC5);
            match op {
                SHL => {
                    // OF = SF ^ CF.
                    a.copier(4, RCX, RAX);
                    a.decaler(5, 4, RCX, 7);
                    a.alu_rr(6, 4, Rm::R(RCX), RAX);
                    a.alu_ri(4, 4, Rm::R(RCX), 1);
                    a.decaler(4, 4, RCX, 11);
                    a.alu_rr(1, 4, Rm::R(RAX), RCX);
                }
                SHR => {
                    // OF = le signe d'avant.
                    a.copier(8, RCX, R8);
                    a.decaler(5, 8, RCX, w * 8 - 1);
                    a.alu_ri(4, 4, Rm::R(RCX), 1);
                    a.decaler(4, 4, RCX, 11);
                    a.alu_rr(1, 4, Rm::R(RAX), RCX);
                }
                _ => debug_assert_eq!(op, SAR),
            }
        }
        self.ecrire_registre(w, uop.dst, RDX);
        if !mort {
            self.poser_drapeaux();
        }
        let a = &mut self.a;
        a.jmp(fin);
        a.poser(nul);
        self.ecrire_registre(w, uop.dst, R8);
        self.a.poser(fin);
    }

    /// **`rapide::unaire`** sur un registre.
    fn unaire(&mut self, op: u8, w: u8, uop: &Uop) {
        if op == NOT {
            let a = &mut self.a;
            a.charger(w, RDX, reg(uop.dst));
            a.unaire(2, w, RDX);
            self.ecrire_registre(w, uop.dst, RDX);
            return;
        }
        debug_assert!(matches!(op, INC | DEC | NEG));
        let mort = self.mort;
        if !mort && (op == INC || op == DEC) {
            // La retenue d'avant, dans r10.
            self.drapeaux();
            self.a.copier(8, R10, RAX);
        }
        let a = &mut self.a;
        a.charger(w, RAX, reg(uop.dst));
        a.unaire(
            match op {
                INC => 0,
                DEC => 1,
                _ => 3,
            },
            w,
            RAX,
        );
        a.copier(8, RDX, RAX);
        if mort {
            self.ecrire_registre(w, uop.dst, RDX);
            return;
        }
        self.bits_de_l_hote();
        if op == INC || op == DEC {
            let a = &mut self.a;
            a.alu_ri(4, 4, Rm::R(RAX), 0x8D4);
            a.alu_ri(4, 4, Rm::R(R10), 1);
            a.alu_rr(1, 4, Rm::R(RAX), R10);
        }
        self.ecrire_registre(w, uop.dst, RDX);
        self.poser_drapeaux();
    }

    /// **Le chemin hors ligne d'une instruction** : RIP rendu exact, la
    /// forme appelée, puis RIP remis en retard pour le chemin principal.
    fn annexe(&mut self, annexe: Annexe) {
        self.a.poser(annexe.entree);
        if annexe.pendant != 0 {
            self.a.alu_ri(0, 8, m(RBX, d::RIP), annexe.pendant);
        }
        self.appeler_la_forme(annexe.rang);
        if annexe.pendant != 0 {
            self.a.alu_ri(5, 8, m(RBX, d::RIP), annexe.pendant);
        }
        self.a.jmp(annexe.retour);
    }
}

/// **Le gabarit peut-il renoncer ?** Un accès à la mémoire qui manque le
/// tampon, une cible à juger : il rend alors l'instruction à sa forme, qui
/// peut fauter.
fn renonce(gabarit: Gabarit) -> bool {
    match gabarit {
        Gabarit::Alu { forme, .. } => !matches!(forme, RR | RI),
        Gabarit::Unaire { .. }
        | Gabarit::Decalage { .. }
        | Gabarit::Transfert { .. }
        | Gabarit::Extension { .. }
        | Gabarit::Lea { .. }
        | Gabarit::Nop => false,
        _ => true,
    }
}

/// **Les drapeaux de chaque instruction sont-ils morts ?** Ceux de
/// l'instruction `i` le sont quand une instruction plus loin les réécrit tous
/// les six (une opération à deux opérandes, `neg`) sans pouvoir renoncer, et
/// que rien entre les deux ne les lit, ne renonce ni n'appelle une forme : nul
/// ne les verra jamais — pas même une faute, qui laisserait l'état d'avant
/// une instruction. Tout ce qui n'est pas sûr les garde vivants, la fin du
/// bloc comprise.
fn drapeaux_morts(instructions: &[Instruction]) -> Vec<bool> {
    let gabarit = |i: &Instruction| i.gabarit.filter(|g| traduisible(*g));
    (0..instructions.len())
        .map(|rang| {
            for suivante in &instructions[rang + 1..] {
                let Some(g) = gabarit(suivante) else {
                    return false;
                };
                if renonce(g) {
                    return false;
                }
                match g {
                    Gabarit::Alu { .. } | Gabarit::Unaire { op: NEG, .. } => return true,
                    Gabarit::Unaire { op: INC | DEC, .. } | Gabarit::Jcc(_) => return false,
                    _ => {}
                }
            }
            false
        })
        .collect()
}

/// Ce que le code natif refait : les adresses à segment (`GENERALE`) vont à
/// la forme.
fn traduisible(gabarit: Gabarit) -> bool {
    let adresse_simple = |adresse: u8| matches!(adresse, BASE | INDEXEE | RELATIVE);
    match gabarit {
        Gabarit::Alu { forme, adresse, .. } => matches!(forme, RR | RI) || adresse_simple(adresse),
        Gabarit::Chargement { adresse, .. }
        | Gabarit::Rangement { adresse, .. }
        | Gabarit::Lea { adresse, .. } => adresse_simple(adresse),
        Gabarit::Unaire { op, .. } => matches!(op, INC | DEC | NOT | NEG),
        // Sur trente-deux et soixante-quatre bits, le compte masqué reste
        // sous la largeur : les règles de `decalage` pour un compte plus
        // large ne servent pas.
        Gabarit::Decalage { w, .. } => matches!(w, 4 | 8),
        _ => true,
    }
}

fn masque(octets: u8) -> u64 {
    match octets {
        1 => 0xFF,
        2 => 0xFFFF,
        4 => 0xFFFF_FFFF,
        _ => u64::MAX,
    }
}
