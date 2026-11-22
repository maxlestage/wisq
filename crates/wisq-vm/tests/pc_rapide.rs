//! **Le chemin rapide n'exécute rien autrement que le chemin général.**
//!
//! La machine PC exécute par blocs d'instructions décodées côte à côte
//! (`pc::blocs`), chacune par une forme choisie au décodage
//! (`x86::rapide`), la mémoire par le plus court du tampon de traduction
//! (`Cpu::read_memory_fast`). Le juge est `Cpu::execute`, que les corpus
//! matériels jugent. Ces tests comparent les deux :
//!
//! - chaque forme contre `execute`, sur des instructions tirées au hasard,
//!   sous pagination, dans les deux anneaux, avec des pages absentes, en
//!   lecture seule, réservées au noyau, propres ou salies, et des accès à
//!   cheval sur deux pages ;
//! - des programmes entiers, avec et sans blocs, l'horloge qui interrompt,
//!   et des budgets hachés : le même état à chaque arrêt, la même mémoire, le
//!   même compte ;
//! - puis chaque garde des blocs, une par une : le code qui se réécrit (dans
//!   le bloc, du dehors, pendant une coupure), ce qu'un bloc compare, le
//!   budget et le service du matériel à l'instruction près, `hlt`, une table
//!   de pages rechargée, l'instruction à cheval sur deux pages, le code au
//!   bout de la RAM, une adresse `%fs:`.
//!
//! **Et le JIT** (`x86::jit`) : chaque programme et chaque garde tourne sur
//! trois machines — le pas à pas, les blocs interprétés, et les blocs
//! traduits dès leur première entrée —, qui doivent rester dans le même
//! état à chaque arrêt.

use wisq_vm::pc::systeme::Table;
use wisq_vm::pc::Machine;
use wisq_vm::x86::rapide::{executer_une, specialisee, Suite, Uop};
use wisq_vm::x86::{decode, Cpu, GuestMemory, Op, Width};

// ---- Le hasard, reproductible ----

/// SplitMix64 : la même graine rend les mêmes tirages, donc un échec se
/// rejoue.
struct Hasard(u64, &'static [u8]);

/// Le registre d'une forme registre, et celui du champ `reg`, parmi ceux
/// que le tirage permet d'écrire.
fn bases_et_registres(h: &mut Hasard) -> (u8, u8) {
    let permis = h.1;
    (h.parmi(permis), h.parmi(permis))
}

impl Hasard {
    fn suivant(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn sous(&mut self, borne: u64) -> u64 {
        self.suivant() % borne
    }

    fn un_sur(&mut self, n: u64) -> bool {
        self.sous(n) == 0
    }

    fn parmi<T: Copy>(&mut self, choix: &[T]) -> T {
        choix[self.sous(choix.len() as u64) as usize]
    }
}

// ---- Les instructions tirées au hasard ----

/// Un ModRM (et son SIB, son déplacement) : registre ou mémoire. `bases`
/// sont les registres permis comme base d'une adresse (leur numéro sur trois
/// bits : REX.B n'est pas posé pour eux), `relatif` permet l'adresse relative
/// à RIP.
fn modrm(h: &mut Hasard, reg: u8, memoire: bool, bases: &[u8], relatif: bool) -> Vec<u8> {
    let mut octets = Vec::new();
    if !memoire {
        let rm = bases_et_registres(h).1;
        octets.push(0xC0 | (reg << 3) | rm);
        return octets;
    }
    if relatif && h.un_sur(6) {
        octets.push((reg << 3) | 5);
        octets.extend((h.sous(0x2000) as i32 + 0x0F00).to_le_bytes());
        return octets;
    }
    let base = h.parmi(bases);
    let mode = h.parmi(&[0u8, 1, 1, 2]);
    if h.un_sur(4) {
        // Un SIB : un index (4 : aucun), une échelle.
        octets.push((mode << 6) | (reg << 3) | 4);
        let index = h.parmi(&[4u8, 4, 1, 2]);
        octets.push(((h.sous(4) as u8) << 6) | (index << 3) | base);
    } else {
        octets.push((mode << 6) | (reg << 3) | base);
    }
    match mode {
        0 if base == 5 => octets.extend((h.sous(0x100) as i32).to_le_bytes()),
        1 => octets.push(h.suivant() as u8),
        2 => octets.extend((h.sous(0x3000) as i32 - 0x1000).to_le_bytes()),
        _ => {}
    }
    octets
}

/// **Une instruction tirée au hasard** parmi les familles que le chemin
/// rapide spécialise, et quelques-unes qu'il laisse au chemin général. `dst`
/// est le registre que le champ `reg` désigne (sur trois bits).
fn tirer(h: &mut Hasard, bases: &[u8], relatif: bool, sauts: bool) -> Vec<u8> {
    let mut octets = Vec::new();
    if h.un_sur(8) {
        octets.push(0x66);
    }
    if h.un_sur(16) {
        octets.push(h.parmi(&[0x64u8, 0x65]));
    }
    if h.un_sur(2) {
        // REX : W au hasard, R au hasard, X et B jamais (les bases restent
        // celles qu'on a choisies).
        octets.push(0x40 | ((h.sous(2) as u8) << 3) | ((h.sous(2) as u8) << 2));
    }
    let memoire = h.un_sur(2);
    let reg = bases_et_registres(h).0;
    let famille = h.sous(if sauts { 26 } else { 22 });
    match famille {
        // Les huit opérations de la grille, dans les quatre sens.
        0..=3 => {
            octets.push(((h.sous(8) as u8) << 3) | h.sous(4) as u8);
            octets.extend(modrm(h, reg, memoire, bases, relatif));
        }
        // Le groupe 1, avec un immédiat.
        4 => {
            let opcode = h.parmi(&[0x80u8, 0x81, 0x83]);
            octets.push(opcode);
            let extension = h.sous(8) as u8;
            octets.extend(modrm(h, extension, memoire, bases, relatif));
            if opcode == 0x81 {
                octets.extend((h.suivant() as u32).to_le_bytes());
            } else {
                octets.push(h.suivant() as u8);
            }
        }
        // `test`.
        5 => {
            octets.push(h.parmi(&[0x84u8, 0x85]));
            octets.extend(modrm(h, reg, memoire, bases, relatif));
        }
        6 => {
            let opcode = h.parmi(&[0xF6u8, 0xF7]);
            octets.push(opcode);
            let extension = h.parmi(&[0u8, 2, 3]);
            octets.extend(modrm(h, extension, memoire, bases, relatif));
            if opcode == 0xF6 {
                octets.push(h.suivant() as u8);
            } else {
                octets.extend((h.suivant() as u32).to_le_bytes());
            }
        }
        // `mov` dans les quatre sens, et d'un immédiat.
        7 | 8 => {
            octets.push(h.parmi(&[0x88u8, 0x89, 0x8A, 0x8B]));
            octets.extend(modrm(h, reg, memoire, bases, relatif));
        }
        9 => {
            let opcode = h.parmi(&[0xC6u8, 0xC7]);
            octets.push(opcode);
            octets.extend(modrm(h, 0, memoire, bases, relatif));
            if opcode == 0xC6 {
                octets.push(h.suivant() as u8);
            } else {
                octets.extend((h.suivant() as u32).to_le_bytes());
            }
        }
        10 => {
            let registre = h.parmi(&[0u8, 1, 2]);
            if h.un_sur(2) {
                octets.push(0xB0 | registre);
                octets.push(h.suivant() as u8);
            } else {
                octets.push(0xB8 | registre);
                let w = octets.iter().any(|o| o & 0xF8 == 0x48);
                let taille = if w { 8 } else { 4 };
                octets.extend(&h.suivant().to_le_bytes()[..taille]);
            }
        }
        // `movzx`, `movsx`, `movsxd`.
        11 => {
            let second = h.parmi(&[0xB6u8, 0xB7, 0xBE, 0xBF]);
            octets.extend([0x0F, second]);
            octets.extend(modrm(h, reg, memoire, bases, relatif));
        }
        12 => {
            octets.push(0x63);
            octets.extend(modrm(h, reg, memoire, bases, relatif));
        }
        // `lea`.
        13 => {
            octets.push(0x8D);
            octets.extend(modrm(h, reg, true, bases, relatif));
        }
        // `inc`, `dec`, `not`, `neg`.
        14 => {
            let (opcode, r) = h.parmi(&[
                (0xFEu8, 0u8),
                (0xFE, 1),
                (0xFF, 0),
                (0xFF, 1),
                (0xF6, 2),
                (0xF7, 2),
                (0xF6, 3),
                (0xF7, 3),
            ]);
            octets.push(opcode);
            octets.extend(modrm(h, r, memoire, bases, relatif));
        }
        // Les décalages et les rotations.
        15 | 16 => {
            let opcode = h.parmi(&[0xC0u8, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3]);
            octets.push(opcode);
            let extension = h.parmi(&[4u8, 5, 7, 0, 1]);
            octets.extend(modrm(h, extension, memoire, bases, relatif));
            if opcode <= 0xC1 {
                octets.push(h.parmi(&[0u8, 1, 2, 7, 31, 32, 33, 63, 64, 200]));
            }
        }
        // `cmov`, `setcc` et `imul` (des formes, comme `adc` et `sbb` de la
        // grille), puis `xchg`, `xadd`, `bt`, `bts`, `bsf` : le chemin
        // général, au milieu des formes.
        17 => {
            octets.extend([0x0F, 0x40 | h.sous(16) as u8]);
            octets.extend(modrm(h, reg, memoire, bases, relatif));
        }
        18 => {
            octets.extend([0x0F, 0x90 | h.sous(16) as u8]);
            octets.extend(modrm(h, 0, memoire, bases, relatif));
        }
        19 => {
            octets.push(h.parmi(&[0x87u8, 0x86]));
            octets.extend(modrm(h, reg, memoire, bases, relatif));
        }
        // `imul` à trois opérandes, un immédiat d'un octet ou de quatre.
        20 if h.un_sur(3) => {
            let opcode = h.parmi(&[0x69u8, 0x6B]);
            octets.push(opcode);
            octets.extend(modrm(h, reg, memoire, bases, relatif));
            let taille = if opcode == 0x6B {
                1
            } else if octets.contains(&0x66) {
                2
            } else {
                4
            };
            octets.extend(&h.suivant().to_le_bytes()[..taille]);
        }
        20 => {
            octets.extend([0x0F, h.parmi(&[0xAFu8, 0xC1, 0xA3, 0xAB, 0xBC])]);
            octets.extend(modrm(h, reg, memoire, bases, relatif));
        }
        // `bswap`, puis `nop`, `cltq`, `cqto`, `clc`, `stc`, `cmc`, `xchg`
        // avec l'accumulateur.
        21 if h.un_sur(4) => {
            octets.extend([0x0F, 0xC8 | bases_et_registres(h).1]);
        }
        21 => {
            octets.push(h.parmi(&[0x90u8, 0x98, 0x99, 0xF8, 0xF9, 0xF5, 0x91, 0x92]));
        }
        // Les sauts : relatifs, conditionnels, appels et retours (le
        // programme les rend inoffensifs, voir `programme`).
        22 => {
            octets.push(0x70 | h.sous(16) as u8);
            octets.push(h.suivant() as u8);
        }
        23 => {
            octets.extend([0x0F, 0x80 | h.sous(16) as u8]);
            octets.extend((h.suivant() as u32).to_le_bytes());
        }
        24 => octets.push(h.parmi(&[0x50u8, 0x51, 0x52, 0x58, 0x59, 0x5A])),
        // `call *` et `jmp *`, vers un registre ou la mémoire.
        25 if h.un_sur(2) => {
            octets.push(0xFF);
            let extension = h.parmi(&[2u8, 4]);
            octets.extend(modrm(h, extension, memoire, bases, relatif));
        }
        _ => {
            octets.push(0x6A);
            octets.push(h.suivant() as u8);
        }
    }
    octets
}

// ---- Chaque forme contre `execute` ----

const PRESENT: u64 = 1;
const ECRITURE: u64 = 2;
const UTILISATEUR: u64 = 4;
/// « Accédée » et « salie », posées d'avance sur certaines pages : le
/// chemin rapide ne doit pas écrire sur une page qui n'est pas encore salie
/// sans la salir.
const ACCEDEE: u64 = 1 << 5;
const SALIE: u64 = 1 << 6;

const CODE: u64 = 0x10000;
/// Les données : seize pages à partir d'ici, de droits variés.
const DONNEES: u64 = 0x20000;

/// Un processeur qui pagine, avec le tampon de traduction de la machine :
/// le code en identité, puis seize pages de données aux droits tirés — dont
/// des absentes, des lectures seules, des pages du noyau, des propres et des
/// salies, et des trames qui ne se suivent pas (un accès à cheval va dans
/// deux trames éloignées).
fn processeur(h: &mut Hasard) -> Cpu {
    let mut cpu = Cpu {
        memory: GuestMemory {
            base: 0,
            bytes: vec![0u8; 0x80000],
        },
        ..Default::default()
    }
    .with_translation_cache();
    let ouverte = PRESENT | ECRITURE | UTILISATEUR;
    let poser = |cpu: &mut Cpu, ou: u64, valeur: u64| {
        cpu.memory.write(ou, Width::Qword, valeur).unwrap();
    };
    poser(&mut cpu, 0x1000, 0x2000 | ouverte);
    poser(&mut cpu, 0x2000, 0x3000 | ouverte);
    poser(&mut cpu, 0x3000, 0x4000 | ouverte);
    poser(&mut cpu, 0x4000 + (CODE >> 12) * 8, CODE | ouverte);
    for rang in 0..16u64 {
        let virtuelle = DONNEES + rang * 0x1000;
        // La trame : à l'envers, pour que deux pages voisines ne le soient
        // pas en mémoire physique.
        let trame = 0x40000 + (15 - rang) * 0x1000;
        let droits = match h.sous(10) {
            0 => 0,
            1 => PRESENT | UTILISATEUR,
            2 => PRESENT | ECRITURE,
            3 => PRESENT | ECRITURE | UTILISATEUR | ACCEDEE | SALIE,
            // Salies puis protégées — la copie sur écriture d'après un
            // `fork` —, au programme ou au noyau seul.
            4 => PRESENT | UTILISATEUR | ACCEDEE | SALIE,
            5 => PRESENT | ECRITURE | ACCEDEE | SALIE,
            _ => ouverte,
        };
        poser(&mut cpu, 0x4000 + (virtuelle >> 12) * 8, trame | droits);
        for octet in 0..0x1000u64 {
            cpu.memory.bytes[(trame + octet) as usize] = h.suivant() as u8;
        }
    }
    cpu.control[3] = 0x1000;
    cpu.control[0] = (1 << 31) | 1 | if h.un_sur(4) { 0 } else { 1 << 16 };
    cpu
}

/// Ce qui doit être égal entre les deux chemins.
fn etat(cpu: &Cpu) -> (Vec<u64>, u64, u64, bool, String, u64) {
    (
        cpu.regs.to_vec(),
        cpu.rip,
        cpu.flags.read(),
        cpu.faulted,
        format!("{:?}", cpu.unmapped),
        cpu.fault_code,
    )
}

/// **Chaque forme du chemin rapide rend ce que `execute` rend** : vingt mille
/// instructions tirées, chacune exécutée par les deux chemins depuis le même
/// état — registres pointant dans les données ou ailleurs, drapeaux posés en
/// clair ou laissés à la demande par une opération du juge, l'anneau zéro ou
/// trois, le tampon de traduction déjà rempli par des accès du noyau (pour
/// que le chemin rapide y trouve des cases qu'un programme n'a pas le droit
/// de lire, ou qu'une écriture n'a pas encore salies). Tout est comparé :
/// registres, RIP, RFLAGS, la faute et son code, la mémoire entière — les
/// bits « accédée » et « salie » des tables compris.
#[test]
fn every_fast_form_does_what_execute_does() {
    let mut h = Hasard(0x5EED_0001, &[0, 1, 2, 3, 4, 5, 6, 7]);
    let mut specialisees = 0usize;
    let mut fautes = 0usize;
    let mut anneau_trois = 0usize;
    let mut par_un_segment = 0usize;
    let bases = [0u8, 1, 2, 3, 6, 7, 5];
    for tirage in 0..20_000 {
        let mut cpu = processeur(&mut h);
        let octets = tirer(&mut h, &bases, true, true);
        let Some(instruction) = decode(&octets) else {
            continue;
        };
        if !wisq_vm::pc::blocs::blocable(instruction.op) {
            continue;
        }
        for registre in cpu.regs.iter_mut().take(16) {
            *registre = match h.sous(5) {
                0 => h.suivant(),
                1 => h.sous(0x40),
                // Au bout d'une page : les accès à cheval.
                2 => DONNEES + h.sous(16) * 0x1000 + 0xFF8 + h.sous(8),
                _ => DONNEES + h.sous(0x10000),
            };
        }
        cpu.rip = CODE + h.sous(0x800);
        // Le tampon rempli par le noyau : une lecture de chaque page de
        // données présente.
        for rang in 0..16u64 {
            let _ = cpu.read_memory(DONNEES + rang * 0x1000, Width::Byte);
        }
        cpu.faulted = false;
        cpu.unmapped = None;
        cpu.fault_code = 0;
        // Les drapeaux : en clair, ou laissés à la demande par le juge.
        if h.un_sur(2) {
            cpu.flags.write(h.suivant() & 0x8D5);
        } else {
            let posee = decode(&[0x48, 0x01, 0xD8]).expect("add %rbx,%rax");
            cpu.regs[3] = h.suivant();
            cpu.execute(&posee);
        }
        if h.un_sur(3) {
            cpu.segments[1] = 0x33;
            anneau_trois += 1;
        }
        // Les bases de FS et de GS : nulles, ou une page ou trois plus loin,
        // ou deux plus près — l'adresse `%fs:` d'un programme (le canari en
        // `%fs:0x28`, le pointeur de fil de musl en `%fs:0`) tombe encore
        // dans les données, mais n'est plus celle qu'on lirait sans la base.
        let bases_de_segment = [0u64, 0x1000, 0x3000, 0u64.wrapping_sub(0x2000)];
        cpu.fs_base = h.parmi(&bases_de_segment);
        cpu.gs_base = h.parmi(&bases_de_segment);
        if let Some(adresse) = instruction.memory {
            let base = if adresse.fs {
                cpu.fs_base
            } else if adresse.gs {
                cpu.gs_base
            } else {
                0
            };
            if base != 0 && instruction.op != Op::Lea && specialisee(&instruction) {
                par_un_segment += 1;
            }
        }
        let mut juge = cpu.clone();
        juge.jumped = false;
        juge.execute(&instruction);
        // Comme `Machine::pas` : RIP n'avance ni sur un saut, ni sur une
        // faute.
        if !juge.jumped && !juge.faulted {
            juge.rip = juge.rip.wrapping_add(instruction.length as u64);
        }
        let suite = executer_une(&mut cpu, &instruction);
        if suite == Suite::Suivante {
            cpu.rip = cpu.rip.wrapping_add(instruction.length as u64);
        }
        assert_eq!(
            suite == Suite::Faute,
            juge.faulted,
            "tirage {tirage} : {octets:02x?} ({:?}) : la faute",
            instruction.op
        );
        assert_eq!(
            etat(&cpu),
            etat(&juge),
            "tirage {tirage} : {octets:02x?} ({:?})",
            instruction.op
        );
        assert!(
            cpu.memory.bytes == juge.memory.bytes,
            "tirage {tirage} : {octets:02x?} ({:?}) : la mémoire",
            instruction.op
        );
        if specialisee(&instruction) {
            specialisees += 1;
        }
        if juge.faulted {
            fautes += 1;
        }
    }
    // Une instruction prête tient sur trente-deux octets.
    assert_eq!(std::mem::size_of::<Uop>(), 32);
    // Les tirages ont bien exercé ce qu'ils prétendent : les formes, les
    // fautes, l'anneau trois.
    assert!(specialisees > 10_000, "{specialisees} formes spécialisées");
    assert!(fautes > 1_000, "{fautes} fautes");
    assert!(anneau_trois > 4_000, "{anneau_trois} en anneau trois");
    assert!(
        par_un_segment > 100,
        "{par_un_segment} formes par FS ou GS, la base non nulle"
    );
}

// ---- Des programmes entiers, avec et sans blocs ----

const IDT: u64 = 0x9000;
const GESTIONNAIRE: u64 = 0x8000;
const PILE: u64 = 0x7000;
/// Où les programmes écrivent et lisent : deux pages.
const ZONE: u64 = 0xA000;
/// Le compteur d'interruptions de l'horloge.
const COMPTEUR: u64 = 0x8800;
/// Les quatre niveaux de tables de la machine des programmes.
const TABLES: u64 = 0x5_0000;

fn ecrire(machine: &mut Machine, adresse: u64, valeur: u64) {
    machine
        .cpu
        .memory
        .write(adresse, Width::Qword, valeur)
        .expect("dans la RAM");
}

fn poser(machine: &mut Machine, adresse: u64, octets: &[u8]) {
    let ou = adresse as usize;
    machine.cpu.memory.bytes[ou..ou + octets.len()].copy_from_slice(octets);
}

fn porte(machine: &mut Machine, vecteur: u64, cible: u64) {
    let bas = (cible & 0xFFFF) | (0x10 << 16) | (0x8E << 40) | ((cible & 0xFFFF_0000) << 32);
    ecrire(machine, IDT + vecteur * 16, bas);
    ecrire(machine, IDT + vecteur * 16 + 8, cible >> 32);
}

/// **Une machine en mode long**, les pages basses en identité, le code à
/// 0x1000 (trois pages), une IDT dont chaque faute va à un gestionnaire qui
/// jette son code d'erreur et saute l'instruction fautive (`skip` : RIP du
/// cadre plus la longueur rangée en 0x8F00 — un octet par adresse de code),
/// et l'horloge (le vecteur 0x20) qui compte ses battements et acquitte.
fn machine(code: &[u8], blocs: bool) -> Machine {
    let mut machine = Machine::nouvelle(0);
    machine.blocs_actifs = blocs;
    // Les blocs interprétés : le JIT a sa machine à lui (`traduite`).
    machine.jit = None;
    // Un battement du 8253 pour quatre instructions : l'horloge interrompt
    // toutes les quelques centaines d'instructions.
    machine.instructions_par_battement = 4;
    // Les tables, hors de l'espace cartographié (elles se lisent en
    // physique) : le code peut couvrir trois pages sans les écraser.
    let ouverte = 0x7;
    ecrire(&mut machine, TABLES, (TABLES + 0x1000) | ouverte);
    ecrire(&mut machine, TABLES + 0x1000, (TABLES + 0x2000) | ouverte);
    ecrire(&mut machine, TABLES + 0x2000, (TABLES + 0x3000) | ouverte);
    for page in [
        0x1000u64, 0x2000, 0x3000, 0x6000, 0x7000, 0x8000, 0x9000, 0xA000, 0xB000, 0xC000, 0xD000,
    ] {
        ecrire(
            &mut machine,
            TABLES + 0x3000 + ((page >> 12) & 0x1FF) * 8,
            page | ouverte,
        );
    }
    // Le code occupe 0x1000-0x3FFF dans l'espace virtuel : la page 0x4000
    // virtuelle va à la trame 0xD000, pour qu'un bloc ne lise pas la suite
    // d'une instruction dans la trame voisine.
    ecrire(&mut machine, TABLES + 0x3000 + 4 * 8, 0xD000 | ouverte);
    poser(&mut machine, 0x1000, code);
    // Le gestionnaire des fautes : `add $8,%rsp ; push %rax ; mov 8(%rsp),%rax
    // ; add $2,%rax ; mov %rax,8(%rsp) ; pop %rax ; iretq` — il saute deux
    // octets, assez pour sortir d'une boucle de fautes.
    let fautes: [u8; 23] = [
        0x48, 0x83, 0xC4, 0x08, 0x50, 0x48, 0x8B, 0x44, 0x24, 0x08, 0x48, 0x83, 0xC0, 0x02, 0x48,
        0x89, 0x44, 0x24, 0x08, 0x58, 0x48, 0xCF, 0x90,
    ];
    poser(&mut machine, GESTIONNAIRE, &fautes);
    // L'horloge : `push %rax ; incq COMPTEUR ; mov $0x20,%al ; out %al,$0x20
    // ; pop %rax ; iretq`.
    let horloge: [u8; 17] = [
        0x50, 0x48, 0xFF, 0x04, 0x25, 0x00, 0x88, 0x00, 0x00, 0xB0, 0x20, 0xE6, 0x20, 0x58, 0x48,
        0xCF, 0x90,
    ];
    poser(&mut machine, GESTIONNAIRE + 0x100, &horloge);
    for vecteur in 0..32 {
        let genre = if [8u64, 10, 11, 12, 13, 14, 17].contains(&vecteur) {
            GESTIONNAIRE
        } else {
            // Sans code d'erreur : on saute l'`add $8,%rsp`.
            GESTIONNAIRE + 4
        };
        porte(&mut machine, vecteur, genre);
    }
    porte(&mut machine, 0x20, GESTIONNAIRE + 0x100);
    machine.cpu.rip = 0x1000;
    machine.cpu.control[3] = TABLES;
    machine.cpu.control[4] = 1 << 5;
    machine.cpu.efer = (1 << 8) | (1 << 10);
    machine.cpu.control[0] = (1 << 31) | 1;
    machine.cpu.regs[4] = PILE;
    machine.systeme.idt = Table {
        base: IDT,
        limite: 0x2FF,
    };
    machine
}

/// **La machine du JIT** : les blocs traduits dès leur première entrée.
/// Sur un hôte que le JIT ne sait pas traduire, elle interprète, et les
/// tests le disent (`jit_attendu`).
fn traduite(code: &[u8]) -> Machine {
    let mut machine = machine(code, true);
    machine.jit = wisq_vm::x86::jit::Jit::nouveau().map(Box::new);
    if let Some(jit) = machine.jit.as_deref_mut() {
        jit.seuil = 1;
    }
    machine
}

/// Le JIT existe-t-il sur cet hôte ? Là où il existe, il doit avoir servi.
fn jit_attendu() -> bool {
    cfg!(all(target_arch = "x86_64", unix))
}

/// Les passages par du code traduit d'une machine.
fn passages(machine: &Machine) -> u64 {
    machine.jit.as_deref().map_or(0, |jit| jit.passages)
}

/// Le prologue qui arme l'horloge : le 8259 à la base 0x20, seule l'horloge
/// démasquée, le 8253 en mode 2 sur un compte court, puis `sti`.
fn prologue(compte: u16) -> Vec<u8> {
    let mut octets = Vec::new();
    for (valeur, port) in [
        (0x11u8, 0x20u8),
        (0x20, 0x21),
        (0x04, 0x21),
        (0x01, 0x21),
        (0xFE, 0x21),
        (0x34, 0x43),
        (compte as u8, 0x40),
        ((compte >> 8) as u8, 0x40),
    ] {
        octets.extend([0xB0, valeur, 0xE6, port]);
    }
    octets.push(0xFB);
    octets
}

/// **Un programme tiré au hasard** : des instructions dont les adresses
/// tombent dans `ZONE` (les bases RBX, RSI, RDI, RBP y pointent, et aucune
/// instruction n'écrit ces registres ni RSP — sauf des `push` et des `pop`
/// par paires), et des sauts conditionnels vers le début d'une instruction
/// voisine, devant ou derrière.
fn programme(h: &mut Hasard) -> Vec<u8> {
    programme_avec(h, false)
}

/// `programme`, et des adresses relatives à RIP quand `relatif` le dit.
fn programme_avec(h: &mut Hasard, relatif: bool) -> Vec<u8> {
    let mut instructions: Vec<Vec<u8>> = Vec::new();
    let nombre = 20 + h.sous(60) as usize;
    while instructions.len() < nombre {
        let relative = relatif && h.un_sur(3);
        let octets = tirer(h, &[3, 6, 7, 5], relative, false);
        let Some(instruction) = decode(&octets) else {
            continue;
        };
        if !wisq_vm::pc::blocs::blocable(instruction.op) {
            continue;
        }
        instructions.push(octets);
        // Une paire `push`/`pop` de temps en temps.
        if h.un_sur(10) {
            instructions.push(vec![0x50 | h.parmi(&[0u8, 1, 2])]);
            instructions.push(vec![0x58 | h.parmi(&[0u8, 1, 2])]);
        }
    }
    // Les sauts : remplacer quelques instructions par un saut relatif vers
    // le début d'une autre.
    let mut positions = Vec::new();
    let mut ici = 0u64;
    for instruction in &instructions {
        positions.push(ici);
        ici += instruction.len() as u64 + 6;
    }
    let mut octets = Vec::new();
    for (rang, instruction) in instructions.iter().enumerate() {
        octets.extend(instruction);
        // Après chaque instruction, six octets : un saut conditionnel long
        // (`0f 8x rel32`) une fois sur quatre, sinon des `nop`.
        if h.un_sur(4) {
            let cible = positions[h.sous(positions.len() as u64) as usize];
            let apres = positions[rang] + instruction.len() as u64 + 6;
            let deplacement = cible as i64 - apres as i64;
            octets.extend([0x0F, 0x80 | h.sous(16) as u8]);
            octets.extend((deplacement as i32).to_le_bytes());
        } else if h.un_sur(20) {
            // Un `nop` de six octets, qui porte un ModRM.
            octets.extend([0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00]);
        } else {
            octets.extend([0x90; 6]);
        }
    }
    // Puis revenir au début.
    let retour = -(octets.len() as i64 + 5);
    octets.push(0xE9);
    octets.extend((retour as i32).to_le_bytes());
    octets
}

/// L'état complet d'une machine, à comparer.
fn tout(machine: &Machine) -> (Vec<u64>, u64, u64, u64, u64, bool, Vec<u8>) {
    (
        machine.cpu.regs.to_vec(),
        machine.cpu.rip,
        machine.cpu.flags.read(),
        machine.retirees,
        machine.attente,
        machine.arretee,
        machine.cpu.memory.bytes[..0x10000].to_vec(),
    )
}

/// **Des programmes tirés au hasard s'exécutent pareil avec et sans
/// blocs** : cent programmes, l'horloge armée (elle interrompt à cadence
/// fixe et son gestionnaire écrit en mémoire), les fautes livrées à un
/// gestionnaire qui saute l'instruction, et des budgets hachés — un, deux,
/// sept, deux cent cinquante-cinq, mille instructions. À chaque arrêt, les
/// deux machines sont dans le même état : registres, RIP, drapeaux,
/// instructions retirées, temps d'attente, mémoire. Et le chemin rapide a
/// bien servi : des blocs ont été construits.
#[test]
fn random_programs_run_the_same_with_and_without_blocks() {
    // Le champ `reg` et les formes registre ne désignent que RAX, RCX, RDX (et
    // R8 à R10 sous REX.R) : les bases et la pile ne s'écrivent pas.
    let mut h = Hasard(0x5EED_0002, &[0, 1, 2]);
    let mut construits = 0u64;
    let mut traduits = 0u64;
    let mut interrompus = 0;
    let mut retirees = 0;
    for tirage in 0..100 {
        let mut code = prologue(200 + h.sous(3000) as u16);
        code.extend(programme(&mut h));
        let mut lent = machine(&code, false);
        let mut rapide = machine(&code, true);
        let mut jit = traduite(&code);
        for m in [&mut lent, &mut rapide, &mut jit] {
            for (registre, valeur) in [
                (3usize, ZONE + 0x400),
                (6, ZONE + 0x800),
                (7, ZONE + 0xC00),
                (5, ZONE + 0x1000),
            ] {
                m.cpu.regs[registre] = valeur;
            }
        }
        let mut total = 0u64;
        while total < 60_000 {
            let tranche = h.parmi(&[1u64, 2, 7, 255, 256, 257, 1000, 5000]);
            let a = lent.tourner(tranche);
            let b = rapide.tourner(tranche);
            let c = jit.tourner(tranche);
            assert_eq!(a, b, "tirage {tirage}, après {total} : le rendu");
            assert_eq!(a, c, "tirage {tirage}, après {total} : le rendu du JIT");
            assert_eq!(
                tout(&lent),
                tout(&rapide),
                "tirage {tirage}, après {total} instructions, tranche {tranche}"
            );
            assert_eq!(
                tout(&lent),
                tout(&jit),
                "tirage {tirage}, après {total} instructions, tranche {tranche} : le JIT"
            );
            if a.is_err() || a == Ok(0) {
                break;
            }
            total += tranche;
        }
        if lent.cpu.memory.read(COMPTEUR, Width::Qword) > Some(0) {
            interrompus += 1;
        }
        retirees += lent.retirees;
        construits += rapide.blocs.construits;
        traduits += passages(&jit);
    }
    if jit_attendu() {
        assert!(
            traduits > 100_000,
            "{traduits} passages par du code traduit"
        );
    }
    // Les tirages ont exercé ce qu'ils prétendent : l'horloge a interrompu
    // la plupart des programmes, et les blocs ont servi.
    assert!(interrompus > 50, "{interrompus} programmes interrompus");
    assert!(retirees > 2_000_000, "{retirees} instructions retirées");
    assert!(construits > 1000, "{construits} blocs construits");
}

/// **Le JIT, sur des adresses relatives à RIP** : la forme d'adresse que le
/// code traduit calcule depuis un RIP en retard (`x86_jit_x64.rs`). Les
/// déplacements tirés au hasard tombent où ils tombent — dans une page
/// présente, ou en faute que le gestionnaire saute — et les trois machines
/// doivent en faire la même chose.
#[test]
fn rip_relative_programs_run_the_same_through_the_jit() {
    let mut h = Hasard(0x5EED_0009, &[0, 1, 2]);
    let mut traduits = 0u64;
    for tirage in 0..40 {
        let mut code = prologue(200 + h.sous(3000) as u16);
        code.extend(programme_avec(&mut h, true));
        let mut lent = machine(&code, false);
        let mut jit = traduite(&code);
        for m in [&mut lent, &mut jit] {
            for (registre, valeur) in [
                (3usize, ZONE + 0x400),
                (6, ZONE + 0x800),
                (7, ZONE + 0xC00),
                (5, ZONE + 0x1000),
            ] {
                m.cpu.regs[registre] = valeur;
            }
        }
        let mut total = 0u64;
        while total < 30_000 {
            let tranche = h.parmi(&[1u64, 7, 256, 1000, 5000]);
            let a = lent.tourner(tranche);
            let b = jit.tourner(tranche);
            assert_eq!(a, b, "tirage {tirage}, après {total} : le rendu");
            assert_eq!(tout(&lent), tout(&jit), "tirage {tirage}, après {total}");
            if a.is_err() || a == Ok(0) {
                break;
            }
            total += tranche;
        }
        traduits += passages(&jit);
    }
    if jit_attendu() {
        assert!(traduits > 10_000, "{traduits} passages par du code traduit");
    }
}

// ---- Chaque garde, une par une ----

/// Faire tourner les deux machines du même code, jusqu'à `budget`, et rendre
/// la rapide après avoir vérifié qu'elles sont d'accord.
fn les_deux(code: &[u8], budget: u64, preparer_les: impl Fn(&mut Machine)) -> Machine {
    let mut lent = machine(code, false);
    let mut rapide = machine(code, true);
    let mut jit = traduite(code);
    preparer_les(&mut lent);
    preparer_les(&mut rapide);
    preparer_les(&mut jit);
    let a = lent.tourner(budget);
    let b = rapide.tourner(budget);
    let c = jit.tourner(budget);
    assert_eq!(a, b);
    assert_eq!(a, c, "le JIT");
    assert_eq!(tout(&lent), tout(&rapide));
    assert_eq!(tout(&lent), tout(&jit), "le JIT");
    rapide
}

/// **Un bloc qui se réécrit exécute les octets neufs.** Une boucle dont le
/// corps range un octet dans l'immédiat d'une instruction plus loin du même
/// bloc : par une forme spécialisée (`mov %al, (%rbx)`), puis par le chemin
/// général (`xchg %al, (%rbx)`, `stosb`), puis par une forme de la grille
/// (`add %al, (%rbx)`). L'instruction réécrite doit rendre ce que la boucle
/// vient d'y poser, à chaque tour.
#[test]
fn a_block_that_rewrites_itself_runs_the_new_bytes() {
    // Les quatre façons d'écrire l'octet : chacune range AL en (%rbx), puis
    // `mov $0x00,%cl` (l'octet réécrit est son immédiat), `add %cl,%dl`,
    // `inc %al`, et retour au début.
    for (nom, ecriture) in [
        ("mov", vec![0x88u8, 0x03]),
        ("xchg", vec![0x86, 0x03]),
        ("stosb", vec![0x48, 0x89, 0xDF, 0xAA]),
        ("add", vec![0x00, 0x03]),
    ] {
        let mut code = ecriture.clone();
        let immediat = 0x1000 + code.len() as u64 + 1;
        code.extend([0xB1, 0x00, 0x00, 0xCA, 0xFE, 0xC0]);
        let retour = -(code.len() as i64 + 2);
        code.extend([0xEB, retour as u8]);
        let rapide = les_deux(&code, 4000, |m| m.cpu.regs[3] = immediat);
        assert!(rapide.blocs.construits > 0, "{nom} : des blocs");
        assert!(
            rapide.cpu.regs[1] != 0 || rapide.cpu.regs[2] != 0,
            "{nom} : l'immédiat réécrit a été lu"
        );
    }
}

/// **Un `push` qui réécrit son bloc exécute les octets neufs** : `push %rax`
/// n'a pas d'opérande mémoire, sa pile est implicite. RSP juste derrière
/// l'immédiat de `mov $0,%ecx` qui le suit : les huit octets empilés
/// deviennent cet immédiat (0x11223344), puis le `hlt` d'après. Un bloc qui
/// ne compterait pas `push` parmi les écritures exécuterait l'immédiat qu'il
/// a rangé : zéro.
#[test]
fn a_push_that_rewrites_its_block_runs_the_new_bytes() {
    // 0x1000 : push %rax ; 0x1001 : mov $0,%ecx ; 0x1006 : hlt.
    let code = [0x50, 0xB9, 0x00, 0x00, 0x00, 0x00, 0xF4];
    let rapide = les_deux(&code, 10, |m| {
        m.cpu.regs[4] = 0x100A;
        m.cpu.regs[0] = 0x9090_90F4_1122_3344;
    });
    assert!(rapide.blocs.construits > 0, "un bloc a servi");
    assert!(rapide.arretee);
    assert_eq!(rapide.cpu.regs[1], 0x1122_3344, "l'immédiat empilé");
}

/// **Un `movs` qui réécrit son bloc exécute les octets neufs** : `movsb` n'a
/// pas d'opérande mémoire non plus, ses deux adresses sont RSI et RDI. RDI
/// sur l'immédiat de `mov $0,%cl` qui le suit, RSI sur l'octet 0x5A : CL
/// doit valoir 0x5A, pas l'immédiat que le bloc avait rangé.
#[test]
fn a_movs_that_rewrites_its_block_runs_the_new_bytes() {
    // 0x1000 : movsb ; 0x1001 : mov $0,%cl ; 0x1003 : hlt.
    let code = [0xA4, 0xB1, 0x00, 0xF4];
    let rapide = les_deux(&code, 10, |m| {
        m.cpu.regs[6] = ZONE;
        m.cpu.regs[7] = 0x1002;
        m.cpu.memory.bytes[ZONE as usize] = 0x5A;
    });
    assert!(rapide.blocs.construits > 0, "un bloc a servi");
    assert!(rapide.arretee);
    assert_eq!(rapide.cpu.regs[1] & 0xFF, 0x5A, "l'octet copié");
}

/// **Du code dans les derniers octets de la RAM prend le pas à pas** : un
/// bloc se compare sur soixante-quatre octets lus d'un coup, qu'il n'y a
/// pas au bout de la RAM. Sans pagination, `mov $7,%al ; hlt` dans les
/// trois derniers octets : les deux machines s'arrêtent sur le `hlt`, AL à
/// sept, et aucun bloc n'est construit — l'hôte ne lit rien au-delà.
#[test]
fn code_at_the_end_of_ram_takes_the_step_by_step_path() {
    let rapide = les_deux(&[0xF4], 5, |m| {
        let taille = m.cpu.memory.bytes.len();
        m.cpu.control[0] = 1;
        m.cpu.rip = (taille - 3) as u64;
        m.cpu.memory.bytes[taille - 3..].copy_from_slice(&[0xB0, 0x07, 0xF4]);
    });
    assert!(rapide.arretee);
    assert_eq!(rapide.cpu.regs[0] & 0xFF, 7);
    assert_eq!(rapide.cpu.rip, rapide.cpu.memory.bytes.len() as u64);
    assert_eq!(rapide.blocs.construits, 0);
}

/// **La borne de la fin de la RAM est juste, à l'octet près**, pour tous les
/// débuts de L−64 à L−1 (L, la taille de la RAM). Le code remplit les `n`
/// derniers octets et s'arrête pile au bout : des `inc %ecx`, un `nop` quand
/// il faut pour la parité, et un `jmp` qui revient au début (`hlt` seul pour
/// n = 1). Le bloc qu'on y construirait couvrirait les `n` octets et en
/// comparerait le multiple de huit d'au-dessus : au-delà de la RAM dès que
/// `n` n'en est pas un. Le test de trois octets plus haut laissait passer
/// toute borne de quatre octets ou plus ; ici, une borne de seize (ou de
/// huit) tombe dès n = 16 (ou n = 8) : un bloc s'y construit là où le pas à
/// pas est attendu, avant même qu'un `n` fasse lire l'hôte hors de la RAM.
/// Et la borne n'est pas trop large : à L−64, les soixante-quatre octets
/// tiennent, le bloc se construit.
#[test]
fn every_start_in_the_last_64_bytes_of_ram_is_bounded_exactly() {
    for n in 1usize..=64 {
        let mut code = Vec::new();
        if n == 1 {
            code.push(0xF4);
        } else {
            if n % 2 == 1 {
                code.push(0x90);
            }
            while code.len() < n - 2 {
                code.extend([0xFF, 0xC1]);
            }
            code.extend([0xEB, (-(n as i64)) as u8]);
        }
        assert_eq!(code.len(), n);
        let rapide = les_deux(&[0xF4], 300, |m| {
            let taille = m.cpu.memory.bytes.len();
            m.cpu.control[0] = 1;
            m.cpu.rip = (taille - n) as u64;
            m.cpu.memory.bytes[taille - n..].copy_from_slice(&code);
        });
        let incs = (n.saturating_sub(2) / 2) as u64;
        if n == 1 {
            assert!(rapide.arretee, "n = {n} : le hlt");
        } else if incs > 0 {
            assert!(rapide.cpu.regs[1] > 0, "n = {n} : la boucle a tourné");
        }
        if n < 64 {
            assert_eq!(rapide.blocs.construits, 0, "n = {n} : le pas à pas");
        } else {
            assert!(rapide.blocs.construits > 0, "n = {n} : le bloc tient");
        }
    }
}

/// **Une adresse `%fs:` dans un bloc ajoute la base de FS**, par ses deux
/// formes : sans base ni index (`%fs:0x10`, comme le canari `%fs:0x28`) et
/// par une base (`%fs:(%rbx)`). FS à 0xA000 : RAX lit 0xA010, RCX 0xA020 —
/// et non 0x10 ni 0x20, ce qu'on lirait sans la base.
#[test]
fn an_fs_address_in_a_block_adds_the_fs_base() {
    // mov %fs:0x10,%rax ; mov %fs:(%rbx),%rcx ; hlt.
    let code = [
        0x64, 0x48, 0x8B, 0x04, 0x25, 0x10, 0x00, 0x00, 0x00, 0x64, 0x48, 0x8B, 0x0B, 0xF4,
    ];
    let rapide = les_deux(&code, 10, |m| {
        m.cpu.fs_base = ZONE;
        m.cpu.regs[3] = 0x20;
        ecrire(m, ZONE + 0x10, 0x1111);
        ecrire(m, ZONE + 0x20, 0x2222);
        ecrire(m, 0x10, 0xDEAD);
        ecrire(m, 0x20, 0xBEEF);
    });
    assert!(rapide.blocs.construits > 0, "un bloc a servi");
    assert_eq!(rapide.cpu.regs[0], 0x1111, "%fs:0x10");
    assert_eq!(rapide.cpu.regs[1], 0x2222, "%fs:(%rbx)");
}

/// **Un code réécrit du dehors ne retrouve pas son bloc**, où que tombe
/// l'octet changé parmi ceux qu'un bloc couvre — jusqu'au dernier : quinze
/// `add $imm8,%rcx` et le saut qui revient (soixante-deux octets, le dernier
/// mot comparé en partie), ou seize (soixante-quatre, tout le bloc). La
/// machine qui a déjà rangé le bloc lit l'octet neuf, comme celle qui n'a pas
/// de blocs.
#[test]
fn code_rewritten_from_outside_is_read_again() {
    for nombre in [15usize, 16] {
        let mut code = Vec::new();
        for _ in 0..nombre {
            code.extend([0x48, 0x83, 0xC1, 0x01]);
        }
        code.extend([0xEB, (-(code.len() as i64 + 2)) as u8]);
        // Chaque immédiat, puis le déplacement du saut (vers lui-même : la
        // boucle s'arrête de compter).
        let mut changes: Vec<(usize, u8)> = (0..nombre).map(|rang| (rang * 4 + 3, 0x10)).collect();
        changes.push((nombre * 4 + 1, 0xFE));
        for (octet, valeur) in changes {
            let mut lent = machine(&code, false);
            let mut rapide = machine(&code, true);
            for m in [&mut lent, &mut rapide] {
                m.tourner(100).expect("sans faute");
                m.cpu.memory.bytes[0x1000 + octet] = valeur;
                m.cpu.rip = 0x1000;
                m.cpu.regs[1] = 0;
                m.tourner(3 * nombre as u64).expect("sans faute");
            }
            assert_eq!(
                tout(&lent),
                tout(&rapide),
                "{nombre} instructions, octet {octet} réécrit"
            );
        }
    }
}

/// **Le budget se tient au milieu d'un bloc, à l'instruction près**, et ce
/// qui suit la coupure reprend où il faut : pour chaque budget de un à
/// quarante, les deux machines s'arrêtent sur la même instruction.
#[test]
fn the_budget_stops_inside_a_block_and_resumes_there() {
    let mut code = Vec::new();
    for rang in 0..12u8 {
        code.extend([0x48, 0x83, 0xC0, rang + 1]); // add $n,%rax
    }
    code.extend([0xEB, (-(code.len() as i64 + 2)) as u8]);
    for budget in 1..40 {
        let mut lent = machine(&code, false);
        let mut rapide = machine(&code, true);
        for _ in 0..3 {
            assert_eq!(lent.tourner(budget), Ok(budget));
            assert_eq!(rapide.tourner(budget), Ok(budget));
            assert_eq!(tout(&lent), tout(&rapide), "budget {budget}");
        }
    }
}

/// **Une coupure ne reprend que si rien n'a changé** : coupé au milieu d'un
/// bloc, puis l'instruction d'après réécrite (le bloc n'est plus intact), ou
/// RIP posé ailleurs (l'adresse n'est plus celle de la suite) — la machine à
/// blocs exécute ce qui est là, pas ce que son bloc tenait.
#[test]
fn a_cut_block_resumes_only_where_and_as_it_was() {
    let mut code = Vec::new();
    for rang in 0..12u8 {
        code.extend([0x48, 0x83, 0xC0, rang + 1]); // add $n,%rax
    }
    code.extend([0xEB, (-(code.len() as i64 + 2)) as u8]);
    // Réécrite : l'immédiat de la cinquième instruction.
    let mut lent = machine(&code, false);
    let mut rapide = machine(&code, true);
    for m in [&mut lent, &mut rapide] {
        m.tourner(13 + 4).expect("un tour, puis quatre");
        m.cpu.memory.bytes[0x1000 + 4 * 4 + 3] = 0x40;
        m.tourner(1).expect("la cinquième");
    }
    assert_eq!(tout(&lent), tout(&rapide), "l'instruction réécrite");
    // Ailleurs : RIP sur la deuxième instruction, au lieu de la cinquième.
    let mut lent = machine(&code, false);
    let mut rapide = machine(&code, true);
    for m in [&mut lent, &mut rapide] {
        m.tourner(13 + 4).expect("un tour, puis quatre");
        m.cpu.rip = 0x1004;
        m.tourner(1).expect("la deuxième");
    }
    assert_eq!(tout(&lent), tout(&rapide), "RIP posé ailleurs");
}

/// **Un bloc coupé reprend sans qu'un autre se construise** : la boucle de
/// douze `add` et d'un `jmp`, par tranches de cinq instructions (`tourner`,
/// dont l'époque neuve fait recomparer le bloc à chaque reprise). Chaque
/// tranche s'arrête au milieu du bloc, la suivante y reprend : un seul bloc
/// construit en tout. Sans la reprise, chaque tranche commencerait un bloc
/// neuf à l'adresse de la coupure — treize débuts possibles, cinq et treize
/// étant premiers entre eux.
#[test]
fn a_cut_block_resumes_without_building_another() {
    let mut code = Vec::new();
    for rang in 0..12u8 {
        code.extend([0x48, 0x83, 0xC0, rang + 1]); // add $n,%rax
    }
    code.extend([0xEB, (-(code.len() as i64 + 2)) as u8]);
    let mut lent = machine(&code, false);
    let mut rapide = machine(&code, true);
    for _ in 0..60 {
        assert_eq!(lent.tourner(5), Ok(5));
        assert_eq!(rapide.tourner(5), Ok(5));
    }
    assert_eq!(tout(&lent), tout(&rapide));
    assert_eq!(
        rapide.blocs.construits, 1,
        "la coupure reprend le même bloc"
    );
}

/// **Une écriture dans son propre bloc, après une reprise, est vue** : le
/// bloc (`add $1,%rax` deux fois, `movb $5` sur l'immédiat de l'`add
/// $1,%rbx` qui suit, cet `add`) est coupé après sa première instruction,
/// puis repris à la deuxième. Le `movb` est la troisième du bloc et la
/// deuxième de la reprise : c'est après lui, à son rang dans le bloc, que la
/// génération se relit et que la suite se recompare — et l'`add` exécute
/// l'immédiat neuf, dans un bloc refait à son adresse.
#[test]
fn a_write_into_its_own_block_after_a_resume_is_seen() {
    let mut code = vec![0x48, 0x83, 0xC0, 0x01, 0x48, 0x83, 0xC0, 0x01];
    // movb $5,3(%rip) : l'immédiat de l'instruction suivante.
    code.extend([0xC6, 0x05, 0x03, 0x00, 0x00, 0x00, 0x05]);
    code.extend([0x48, 0x83, 0xC3, 0x01, 0xF4]); // add $1,%rbx ; hlt
    let mut lent = machine(&code, false);
    let mut rapide = machine(&code, true);
    for m in [&mut lent, &mut rapide] {
        assert_eq!(m.tourner(1), Ok(1));
        m.tourner(10).expect("la suite");
    }
    assert_eq!(tout(&lent), tout(&rapide));
    assert_eq!(rapide.cpu.regs[3], 5, "l'immédiat réécrit");
    // Le premier bloc, celui de l'`add` réécrit, et la case vide de `hlt` :
    // la reprise a bien servi (sans elle, un bloc de plus à la deuxième
    // instruction), et c'est elle qui a vu l'écriture.
    assert_eq!(
        rapide.blocs.construits, 3,
        "la reprise, puis la suite relue"
    );
}

/// **L'horloge interrompt à la même instruction**, avec ou sans blocs : le
/// service du matériel tombe toutes les deux cent cinquante-six
/// instructions, au milieu des blocs, et le compteur du gestionnaire comme
/// RIP au moment de l'interruption sont les mêmes.
#[test]
fn the_clock_interrupts_at_the_same_instruction() {
    let mut code = prologue(300);
    let boucle = code.len();
    for rang in 0..12u8 {
        code.extend([0x48, 0x83, 0xC0, rang + 1]);
    }
    code.extend([0xEB, (-((code.len() - boucle) as i64 + 2)) as u8]);
    let mut lent = machine(&code, false);
    let mut rapide = machine(&code, true);
    for pas in 0..400 {
        assert_eq!(lent.tourner(97), rapide.tourner(97));
        assert_eq!(tout(&lent), tout(&rapide), "pas {pas}");
    }
    assert!(lent.cpu.memory.read(COMPTEUR, Width::Qword) > Some(5));
}

/// **`hlt` au milieu d'une suite arrête là** : il n'entre dans aucun bloc,
/// et ce qui le suit ne s'exécute pas.
#[test]
fn a_halt_in_the_middle_stops_there() {
    let code = [
        0x48, 0x83, 0xC0, 0x01, 0x48, 0x83, 0xC0, 0x01, 0xFA, 0xF4, 0x48, 0x83, 0xC0, 0x01,
    ];
    let rapide = les_deux(&code, 100, |_| {});
    assert!(rapide.arretee);
    assert_eq!(rapide.cpu.regs[0], 2);
    assert_eq!(rapide.cpu.rip, 0x100A);
}

/// **Une table de pages rechargée au milieu d'une suite est suivie** : `mov
/// %rax,%cr3` n'entre dans aucun bloc, et l'instruction d'après vient de la
/// trame que la table neuve désigne.
#[test]
fn a_reloaded_page_table_is_followed() {
    // `mov %rax,%cr3`, puis `mov $1,%ecx` à 0x1003 — que la table neuve
    // fait lire dans une autre trame, où c'est `mov $2,%ecx`.
    let code = [0x0F, 0x22, 0xD8, 0xB9, 0x01, 0x00, 0x00, 0x00, 0xF4];
    let rapide = les_deux(&code, 3, |m| {
        // La table neuve, hors de l'espace cartographié (les tables se
        // lisent en physique) : les trois premiers niveaux neufs, la
        // dernière table recopiée, sauf la page de code, qui va à la trame
        // 0xC000.
        let ouverte = 0x7u64;
        let derniere: Vec<u8> = m.cpu.memory.bytes[0x5_3000..0x5_4000].to_vec();
        m.cpu.memory.bytes[0x10_3000..0x10_4000].copy_from_slice(&derniere);
        for (ou, valeur) in [
            (0x10_0000u64, 0x10_1000 | ouverte),
            (0x10_1000, 0x10_2000 | ouverte),
            (0x10_2000, 0x10_3000 | ouverte),
            (0x10_3000 + 8, 0xC000 | ouverte),
        ] {
            m.cpu.memory.write(ou, Width::Qword, valeur).unwrap();
        }
        m.cpu.memory.bytes[0xC000..0xC009]
            .copy_from_slice(&[0x0F, 0x22, 0xD8, 0xB9, 0x02, 0x00, 0x00, 0x00, 0xF4]);
        m.cpu.regs[0] = 0x10_0000;
    });
    assert_eq!(rapide.cpu.regs[1], 2, "l'instruction de la trame neuve");
}

/// **Une instruction à cheval sur deux pages ne se lit pas dans la trame
/// voisine** : la page virtuelle 0x4000 va à la trame 0xD000, et une
/// instruction qui commence au bout de la page 0x3000 prend sa fin là-bas,
/// pas dans la trame 0x4000 qui suit 0x3000 en mémoire.
#[test]
fn an_instruction_across_two_pages_takes_its_end_from_the_right_frame() {
    // Du code jusqu'au bout de la page 0x3000 : des `nop`, puis `mov
    // $imm32,%ecx` dont l'opcode et deux octets sont à 0x3FFD-0x3FFF.
    let mut code = vec![0x90u8; 0x3000 - 3];
    code.extend([0xB9, 0x11, 0x22]);
    let rapide = les_deux(&code, 0x3000, |m| {
        m.cpu.memory.bytes[0xD000..0xD003].copy_from_slice(&[0x33, 0x44, 0xF4]);
        m.cpu.memory.bytes[0x4000..0x4003].copy_from_slice(&[0x55, 0x66, 0xF4]);
    });
    assert_eq!(rapide.cpu.regs[1], 0x4433_2211);
}

/// **Une faute au milieu d'un bloc est nommée par sa propre instruction** :
/// une forme spécialisée ne garde pas son `Decoded`, et la machine relit
/// l'instruction à son adresse pour livrer la faute. `nop` puis `mov
/// (%rbp),%rax`, RBP hors de la moitié canonique : c'est une référence par
/// la pile, `#SS(0)` au vecteur douze — relue au début du bloc, ce serait le
/// `nop`, et `#GP(0)`.
#[test]
fn a_fault_inside_a_block_is_named_by_its_own_instruction() {
    let code = [0x90, 0x90, 0x48, 0x8B, 0x45, 0x00, 0xF4];
    // Deux `nop`, la faute (qui compte au budget sans être retirée), le
    // `hlt` du gestionnaire.
    let rapide = les_deux(&code, 4, |m| {
        porte(m, 12, GESTIONNAIRE + 0x200);
        poser(m, GESTIONNAIRE + 0x200, &[0xF4]);
        m.cpu.regs[5] = 0x8000_0000_0000_6000;
    });
    assert_eq!(rapide.cpu.rip, GESTIONNAIRE + 0x201, "#SS livrée, puis hlt");
    assert_eq!(rapide.retirees, 3, "deux nop, puis le hlt du gestionnaire");
    assert!(rapide.blocs.construits > 0);
}

/// **Un déplacement qui ne tient pas sur trente-deux bits prend le chemin
/// général** : l'instruction prête n'en garde que trente-deux. Le décodeur
/// n'en produit pas aujourd'hui (il ne lit pas les formes `moffs` à
/// soixante-quatre bits), mais une instruction décodée qui en porterait un
/// ne doit pas être tronquée.
#[test]
fn a_displacement_wider_than_32_bits_takes_the_general_path() {
    let mut instruction =
        decode(&[0x48, 0x8B, 0x04, 0x25, 0x00, 0x10, 0x00, 0x00]).expect("mov 0x1000,%rax");
    let mut adresse = instruction.memory.expect("une adresse");
    adresse.displacement = 0x1_0000_1000;
    instruction.memory = Some(adresse);
    assert!(!specialisee(&instruction));
    let mut h = Hasard(0x5EED_0003, &[0]);
    let mut cpu = processeur(&mut h);
    cpu.rip = CODE;
    let mut juge = cpu.clone();
    juge.execute(&instruction);
    executer_une(&mut cpu, &instruction);
    assert_eq!(etat(&cpu), etat(&juge));
}

/// **Un bloc s'arrête au plafond de soixante-quatre octets**, même en ligne
/// droite. Seize `mov $imm32,%eax` (cinq octets chacun) puis un saut qui
/// revient : douze instructions font soixante octets, la treizième finirait
/// au soixante-cinquième. `Blocs::construire` doit donc en ranger douze,
/// comparer huit mots, et la machine à blocs doit faire ce que fait le pas à
/// pas. Un plafond plus large (`PORTEE + 8 - position`) rangerait la
/// treizième, comparerait neuf mots alors que le bloc n'en a que huit, et
/// l'hôte paniquerait en construisant le bloc ; il lirait aussi au-delà des
/// soixante-quatre octets que la borne de la fin de la RAM vérifie.
#[test]
fn a_straight_block_stops_at_sixty_four_bytes() {
    let mut code = Vec::new();
    for rang in 0..16u8 {
        code.extend([0xB8, rang + 1, 0x00, 0x00, 0x00]);
    }
    code.extend([0xEB, (-(code.len() as i64 + 2)) as u8]);
    // Par la table seule : la même construction que la machine fait.
    let mut ram = vec![0u8; 0x2000];
    ram[0x1000..0x1000 + code.len()].copy_from_slice(&code);
    let mut blocs = wisq_vm::pc::blocs::Blocs::default();
    let copie = ram.clone();
    let mut lire = |debut: usize, disponibles: usize| decode(&copie[debut..debut + disponibles]);
    let place = blocs.construire(&ram, 0x1000, 0x1000, &mut lire);
    let bloc = blocs.bloc(place);
    assert_eq!(bloc.nombre, 12, "douze instructions de cinq octets");
    assert_eq!(bloc.mots, 8, "soixante octets : huit mots comparés");
    // Et par la machine : les deux chemins s'accordent, des blocs ont servi.
    let rapide = les_deux(&code, 400, |_| {});
    assert!(rapide.blocs.construits > 0, "des blocs ont servi");
    assert!(
        (1..=16).contains(&(rapide.cpu.regs[0] & 0xFFFF_FFFF)),
        "un des seize mov a été exécuté"
    );
}

/// **Un bloc vide compare quand même seize octets** : la case retient que la
/// première instruction (`in (%dx),%al`, qu'aucun bloc ne prend) passe par le
/// pas à pas, et un code réécrit dans ces seize octets la fait refaire. Un
/// octet changé au douzième rang perd la case ; un octet changé au vingtième
/// ne la perd pas. Avec huit octets comparés, le douzième ne se verrait plus.
#[test]
fn an_empty_block_compares_its_first_sixteen_bytes() {
    let mut ram = vec![0x90u8; 0x2000];
    ram[0x1000] = 0xEC;
    let mut blocs = wisq_vm::pc::blocs::Blocs::default();
    let copie = ram.clone();
    let mut lire = |debut: usize, disponibles: usize| decode(&copie[debut..debut + disponibles]);
    let place = blocs.construire(&ram, 0x1000, 0x1000, &mut lire);
    assert_eq!(blocs.bloc(place).nombre, 0, "un bloc vide");
    assert_eq!(blocs.bloc(place).mots, 2, "seize octets comparés");
    assert_eq!(blocs.trouver_par_les_octets(&ram, 0x1000), Some(place));
    let mut loin = ram.clone();
    loin[0x1000 + 20] = 0xCC;
    assert_eq!(
        blocs.trouver_par_les_octets(&loin, 0x1000),
        Some(place),
        "au-delà des seize"
    );
    for rang in [0usize, 7, 8, 12, 15] {
        let mut change = ram.clone();
        change[0x1000 + rang] = 0xCC;
        assert_eq!(
            blocs.trouver_par_les_octets(&change, 0x1000),
            None,
            "octet {rang} réécrit"
        );
    }
}

// ---- Le vectoriel entier dans les blocs ----

/// **Une instruction vectorielle entière tirée au hasard** : `movdqu`,
/// `movdqa`, `movq`, `movd` dans les deux sens, la logique, l'addition, la
/// comparaison, `pmovmskb` (vers RAX, RCX ou RDX), `pshufd`, un décalage
/// d'octets, `stmxcsr` et `ldmxcsr` (ce dernier n'entre dans aucun bloc : sa
/// `#GP(0)` d'un bit réservé n'est pas une faute d'accès). Les adresses
/// tombent dans `ZONE`, par les mêmes bases que `programme`.
fn tirer_vectorielle(h: &mut Hasard) -> Vec<u8> {
    let memoire = h.un_sur(2);
    let reg = bases_et_registres(h).0;
    let rex = if h.un_sur(3) { Some(0x44u8) } else { None };
    let (prefixe, opcode, sans_memoire, avec_immediat): (Option<u8>, u8, bool, bool) =
        match h.sous(16) {
            0 => (Some(0xF3), 0x6F, false, false),
            1 => (Some(0xF3), 0x7F, false, false),
            2 => (Some(0x66), 0x6F, false, false),
            3 => (Some(0x66), 0x7F, false, false),
            4 => (Some(0xF3), 0x7E, false, false),
            5 => (Some(0x66), 0xD6, false, false),
            6 => (Some(0x66), 0x6E, false, false),
            7 => (Some(0x66), 0x7E, false, false),
            8 => (Some(0x66), h.parmi(&[0xEFu8, 0xEB, 0xDB]), false, false),
            9 => (Some(0x66), h.parmi(&[0xFEu8, 0xF8, 0xD4]), false, false),
            10 => (
                Some(0x66),
                h.parmi(&[0x74u8, 0x75, 0x76, 0xDA]),
                false,
                false,
            ),
            11 => (Some(0x66), 0xD7, true, false),
            12 => (Some(0x66), 0x70, false, true),
            13 => (Some(0x66), 0x60, false, false),
            14 => (Some(0x66), 0x73, true, true),
            _ => (None, 0xAE, false, false),
        };
    let mut octets = Vec::new();
    octets.extend(prefixe);
    octets.extend(rex);
    octets.extend([0x0F, opcode]);
    match (opcode, prefixe) {
        // `stmxcsr` et `ldmxcsr` : la mémoire seulement.
        (0xAE, None) => {
            let extension = h.parmi(&[2u8, 3, 3]);
            octets.extend(modrm(h, extension, true, &[3, 6, 7, 5], false));
        }
        // `psrldq` : le champ `reg` est l'extension 3, `rm` le registre.
        (0x73, _) => {
            octets.extend(modrm(h, 3, false, &[3, 6, 7, 5], false));
        }
        _ => {
            octets.extend(modrm(
                h,
                reg,
                memoire && !sans_memoire,
                &[3, 6, 7, 5],
                false,
            ));
        }
    }
    if avec_immediat {
        octets.push(h.suivant() as u8);
    }
    octets
}

/// L'état de `tout`.
type Tout = (Vec<u64>, u64, u64, u64, u64, bool, Vec<u8>);

/// L'état complet d'une machine, les seize registres XMM et MXCSR compris.
fn tout_et_xmm(machine: &Machine) -> (Tout, Vec<u64>, u32) {
    let xmm = machine.cpu.xmm.iter().flatten().copied().collect();
    (tout(machine), xmm, machine.cpu.mxcsr)
}

/// **Le vectoriel entier s'exécute pareil dans un bloc et au pas à pas** :
/// soixante programmes où une instruction sur deux est vectorielle (dont des
/// accès à cheval sur la fin de `ZONE`, des pages absentes derrière, et des
/// `ldmxcsr` dont la valeur lue lève parfois `#GP(0)`), l'horloge armée, des
/// budgets hachés. À chaque arrêt : les registres, la mémoire, les seize XMM
/// et MXCSR. Et les blocs ont bien pris des vectorielles : seize `pxor`
/// entre registres en remplissent un jusqu'à ses générales.
#[test]
fn integer_vector_instructions_run_the_same_inside_blocks() {
    let mut h = Hasard(0x5EED_0003, &[0, 1, 2]);
    let mut construits = 0u64;
    for tirage in 0..60 {
        let mut code = prologue(200 + h.sous(3000) as u16);
        let mut corps = Vec::new();
        for _ in 0..(20 + h.sous(40)) {
            if h.un_sur(2) {
                corps.extend(tirer_vectorielle(&mut h));
            } else {
                loop {
                    let octets = tirer(&mut h, &[3, 6, 7, 5], false, false);
                    if decode(&octets)
                        .is_some_and(|instruction| wisq_vm::pc::blocs::blocable(instruction.op))
                    {
                        corps.extend(octets);
                        break;
                    }
                }
            }
        }
        let retour = -(corps.len() as i64 + 5);
        corps.push(0xE9);
        corps.extend((retour as i32).to_le_bytes());
        code.extend(corps);
        let mut lent = machine(&code, false);
        let mut rapide = machine(&code, true);
        for m in [&mut lent, &mut rapide] {
            for (registre, valeur) in [
                (3usize, ZONE + 0x400),
                (6, ZONE + 0x800),
                (7, ZONE + 0xC00),
                (5, ZONE + 0x1FF8),
            ] {
                m.cpu.regs[registre] = valeur;
            }
            for (rang, mot) in m.cpu.xmm.iter_mut().enumerate() {
                *mot = [0x0123_4567_89AB_CDEF ^ rang as u64, rang as u64 * 0x1111];
            }
        }
        let mut total = 0u64;
        while total < 40_000 {
            let tranche = h.parmi(&[1u64, 3, 255, 256, 1000, 5000]);
            let a = lent.tourner(tranche);
            let b = rapide.tourner(tranche);
            assert_eq!(a, b, "tirage {tirage}, après {total} : le rendu");
            assert_eq!(
                tout_et_xmm(&lent),
                tout_et_xmm(&rapide),
                "tirage {tirage}, après {total} instructions, tranche {tranche}"
            );
            if a.is_err() || a == Ok(0) {
                break;
            }
            total += tranche;
        }
        construits += rapide.blocs.construits;
    }
    assert!(construits > 500, "{construits} blocs construits");
    // Seize `pxor %xmm1,%xmm0` : un bloc en prend autant que ses générales.
    let mut code = Vec::new();
    for _ in 0..16 {
        code.extend([0x66, 0x0F, 0xEF, 0xC1]);
    }
    let mut ram = vec![0u8; 0x2000];
    ram[0x1000..0x1000 + code.len()].copy_from_slice(&code);
    let mut blocs = wisq_vm::pc::blocs::Blocs::default();
    let copie = ram.clone();
    let mut lire = |debut: usize, disponibles: usize| decode(&copie[debut..debut + disponibles]);
    let place = blocs.construire(&ram, 0x1000, 0x1000, &mut lire);
    assert_eq!(
        blocs.bloc(place).nombre as usize,
        wisq_vm::pc::blocs::GENERALES,
        "des vectorielles dans un bloc"
    );
    // `ldmxcsr (%rbx)` n'y entre pas.
    ram[0x1000..0x1003].copy_from_slice(&[0x0F, 0xAE, 0x13]);
    let copie = ram.clone();
    let mut lire = |debut: usize, disponibles: usize| decode(&copie[debut..debut + disponibles]);
    let place = blocs.construire(&ram, 0x1000, 0x1000, &mut lire);
    assert_eq!(blocs.bloc(place).nombre, 0, "ldmxcsr reste au pas à pas");
}

// ---- Les générations des pages de code ----

/// **Une page écrite par le chemin rapide avant de porter du code le perd
/// dès qu'elle en porte.** Le programme écrit `mov $0x11111111,%eax ; ret`
/// dans la page 0xB000 — la seconde écriture par le chemin rapide, la case
/// du tampon déjà salie —, l'appelle (un bloc s'y construit, la page est
/// marquée), puis y écrit `mov $0x22222222,%eax ; ret` par les mêmes
/// instructions et l'appelle de nouveau, dans le même appel de `tourner`
/// (aucune époque neuve entre les deux). Si le marquage laissait à la case
/// du tampon son écriture rapide, la seconde écriture ne serait pas notée,
/// le bloc garderait son tampon, et l'appel rendrait l'ancienne valeur.
#[test]
fn a_page_written_fast_before_it_held_code_loses_its_fast_writes() {
    let mut code = Vec::new();
    for valeur in [0x11u8, 0x22] {
        // movl $0x..b8,(%rbx) ; movw $0xc3..,4(%rbx) ; call *%rbx
        code.extend([0xC7, 0x03, 0xB8, valeur, valeur, valeur]);
        code.extend([0x66, 0xC7, 0x43, 0x04, valeur, 0xC3]);
        code.extend([0xFF, 0xD3]);
        // mov %eax,%esi (la première fois), mov %eax,%edi (la seconde).
        code.extend(if valeur == 0x11 {
            [0x89, 0xC6]
        } else {
            [0x89, 0xC7]
        });
    }
    code.push(0xF4);
    let rapide = les_deux(&code, 100, |m| {
        m.cpu.regs[3] = 0xB000;
    });
    assert!(rapide.arretee);
    assert_eq!(rapide.cpu.regs[6], 0x1111_1111, "le premier appel");
    assert_eq!(
        rapide.cpu.regs[7], 0x2222_2222,
        "le second appel exécute les octets neufs"
    );
    assert!(rapide.blocs.construits >= 3, "des blocs ont servi");
}

/// **Une page de code écrite par un autre chemin que l'écriture rapide est
/// relue** : par une écriture virtuelle du chemin lent (un `xchg`, qui
/// passe par `execute`), et par une chaîne par pages entières (`rep
/// stosb`, `bulk_string`). Chaque fois la page 0xB000 porte un bloc (`mov
/// $imm32,%eax ; ret`) tamponné, et l'écriture remplace l'immédiat.
#[test]
fn slow_writes_and_page_strings_into_cached_code_are_seen() {
    let mut code = Vec::new();
    // Le code de départ : mov $0x11111111,%eax ; ret, posé par le test ;
    // un premier appel tamponne son bloc.
    code.extend([0xFF, 0xD3, 0x41, 0x89, 0xC2]); // call *%rbx ; mov %eax,%r10d
                                                 // xchg %cl,1(%rbx) : CL vaut 0x33.
    code.extend([0x86, 0x4B, 0x01]);
    code.extend([0xFF, 0xD3, 0x41, 0x89, 0xC0]); // call *%rbx ; mov %eax,%r8d
                                                 // rdi = rbx + 2 ; rcx = 2 ; al = 0x44 ; rep stosb
    code.extend([0x48, 0x8D, 0x7B, 0x02]);
    code.extend([0xB9, 0x02, 0x00, 0x00, 0x00]);
    code.extend([0xB0, 0x44]);
    code.extend([0xF3, 0xAA]);
    code.extend([0xFF, 0xD3, 0x41, 0x89, 0xC1]); // call *%rbx ; mov %eax,%r9d
                                                 // rdi = rbx + 3 ; rcx = 2 ; rep movsb depuis ZONE (0x66, 0x77)
    code.extend([0x48, 0x8D, 0x7B, 0x03]);
    code.extend([0xB9, 0x02, 0x00, 0x00, 0x00]);
    code.extend([0xF3, 0xA4]);
    code.extend([0xFF, 0xD3]); // call *%rbx
    code.push(0xF4);
    let rapide = les_deux(&code, 100, |m| {
        m.cpu.regs[3] = 0xB000;
        m.cpu.regs[6] = ZONE;
        m.cpu.memory.bytes[ZONE as usize..ZONE as usize + 2].copy_from_slice(&[0x66, 0x77]);
        m.cpu.regs[1] = 0x33;
        m.cpu.memory.bytes[0xB000..0xB006].copy_from_slice(&[0xB8, 0x11, 0x11, 0x11, 0x11, 0xC3]);
    });
    assert!(rapide.arretee);
    assert_eq!(rapide.cpu.regs[10], 0x1111_1111, "avant toute écriture");
    assert_eq!(rapide.cpu.regs[8], 0x1111_1133, "après le xchg");
    assert_eq!(
        rapide.cpu.regs[9], 0x1144_4433,
        "après la chaîne qui remplit"
    );
    assert_eq!(
        rapide.cpu.regs[0] & 0xFFFF_FFFF,
        0x7766_4433,
        "après la chaîne qui copie"
    );
}

/// **Du code réécrit entre deux appels d'`executer` est relu**, comme entre
/// deux `tourner` : l'hôte a pu écrire la RAM, et la première tranche fait
/// tout recomparer. Une boucle de `add $1,%rcx`, puis l'immédiat d'une des
/// instructions changé à 0x10.
#[test]
fn code_rewritten_between_two_runs_is_read_again() {
    let mut code = Vec::new();
    for _ in 0..8 {
        code.extend([0x48, 0x83, 0xC1, 0x01]);
    }
    code.extend([0xEB, (-(code.len() as i64 + 2)) as u8]);
    let mut lent = machine(&code, false);
    let mut rapide = machine(&code, true);
    for m in [&mut lent, &mut rapide] {
        m.executer(1000);
        m.cpu.memory.bytes[0x1000 + 3 * 4 + 3] = 0x10;
        m.cpu.rip = 0x1000;
        m.cpu.regs[1] = 0;
        m.executer(9);
    }
    assert_eq!(tout(&lent), tout(&rapide));
    assert_eq!(rapide.cpu.regs[1], 7 + 0x10, "l'immédiat neuf");
}

/// **Un périphérique qui ne dit pas ce qu'il écrit fait tout recomparer.**
/// Un `out` sur un port de ce périphérique de test réécrit l'immédiat d'un
/// `mov` de la page 0xB000, déjà tamponné par un premier appel, sans rien
/// noter : le défaut de `Peripheriques::port_ecrire_suivi` suppose tout
/// réécrit, et le second appel exécute les octets neufs.
#[test]
fn a_device_that_does_not_say_what_it_wrote_makes_every_block_compare() {
    struct Ecrivain;
    impl wisq_vm::pc::Peripheriques for Ecrivain {
        fn port_lire(&mut self, _: u16, _: u8, _: &mut [u8]) -> Option<u32> {
            None
        }
        fn port_ecrire(&mut self, port: u16, _: u8, valeur: u32, ram: &mut [u8]) -> bool {
            if port != 0x2F0 {
                return false;
            }
            ram[0xB001] = valeur as u8;
            true
        }
        fn lignes(&self) -> u16 {
            0
        }
    }
    let mut code = Vec::new();
    code.extend([0xFF, 0xD3, 0x89, 0xC6]); // call *%rbx ; mov %eax,%esi
                                           // mov $0x2f0,%dx ; mov $0x55,%al ; out %al,(%dx)
    code.extend([0x66, 0xBA, 0xF0, 0x02, 0xB0, 0x55, 0xEE]);
    code.extend([0xFF, 0xD3]); // call *%rbx
    code.push(0xF4);
    let rapide = les_deux(&code, 100, |m| {
        m.cpu.regs[3] = 0xB000;
        m.cpu.memory.bytes[0xB000..0xB006].copy_from_slice(&[0xB8, 0x11, 0x11, 0x11, 0x11, 0xC3]);
        m.peripheriques = Some(Box::new(Ecrivain));
    });
    assert!(rapide.arretee);
    assert_eq!(rapide.cpu.regs[6], 0x1111_1111);
    assert_eq!(rapide.cpu.regs[0] & 0xFFFF_FFFF, 0x1111_1155);
}

/// **`invlpg` sur la page même qu'on exécute la fait relire dans sa trame
/// neuve.** Le programme range dans la table l'entrée de sa propre page
/// (0x1000 vers la trame 0xC000, la table vue à 0x6000), puis `invlpg
/// 0x1000` : l'instruction d'après, à la même adresse virtuelle, vient de la
/// trame neuve — `mov $2,%eax` au lieu de `mov $1,%eax`. La page
/// d'instructions que la machine garde hors du tampon (`physique_de_rip`)
/// doit se retraduire : `invlpg` fait avancer le compte de vidages, même
/// sans vider tout le tampon.
#[test]
fn invlpg_on_the_running_page_reads_the_next_instruction_from_the_new_frame() {
    // movq $0xc007,0x6008 ; invlpg 0x1000 ; mov $1,%eax ; hlt
    let mut code = vec![
        0x48, 0xC7, 0x04, 0x25, 0x08, 0x60, 0x00, 0x00, 0x07, 0xC0, 0x00, 0x00,
    ];
    code.extend([0x0F, 0x01, 0x3C, 0x25, 0x00, 0x10, 0x00, 0x00]);
    let suite = code.len();
    code.extend([0xB8, 0x01, 0x00, 0x00, 0x00, 0xF4]);
    let rapide = les_deux(&code, 10, |m| {
        // La table des pages vue à 0x6000, pour que le programme l'écrive.
        m.cpu
            .memory
            .write(TABLES + 0x3000 + 6 * 8, Width::Qword, (TABLES + 0x3000) | 7)
            .unwrap();
        // La trame neuve : la même suite, `mov $2,%eax`.
        let neuve = 0xC000 + suite;
        m.cpu.memory.bytes[neuve..neuve + 6].copy_from_slice(&[0xB8, 0x02, 0x00, 0x00, 0x00, 0xF4]);
    });
    assert!(rapide.arretee);
    assert_eq!(rapide.cpu.regs[0], 2, "la suite vient de la trame neuve");
}

// ---- Le chemin rapide de la mémoire, jugé par le chemin lent ----

/// Ce que deux processeurs doivent avoir d'égal après un même accès : la
/// faute et son code, la mémoire entière (les bits « accédée » et « salie »
/// des tables compris), et, pour chaque page, sa marque de code
/// (`PagesDeCode`) et, si elle est marquée, sa génération. Celle d'une page
/// non marquée ne dit rien : aucun bloc ne porte son tampon (la marque tombe
/// quand elle avance, et se repose quand un bloc la retient), et c'est
/// pourquoi l'écriture rapide, qui n'y va que là, n'a rien à noter.
fn apres_l_acces(cpu: &Cpu) -> (bool, String, u64, Vec<Option<Option<u32>>>) {
    let pages = cpu.code.as_deref().expect("le suivi des pages de code");
    (
        cpu.faulted,
        format!("{:?}", cpu.unmapped),
        cpu.fault_code,
        (0..cpu.memory.bytes.len() as u64 / 0x1000)
            .map(|page| {
                pages
                    .marquee(page << 12)
                    .then(|| pages.generation(page << 12))
            })
            .collect(),
    )
}

/// **`read_memory_fast` et `write_memory_fast` rendent ce que `read_memory`
/// et `write_memory` rendent**, jugés seuls et non par une instruction : les
/// formes du chemin rapide et `execute` peuvent partager ces deux chemins
/// sans qu'un défaut de l'un se cache derrière l'autre. Trente mille accès
/// tirés sur le processeur de `processeur` (seize pages de données aux
/// droits tirés, des trames qui ne se suivent pas), le suivi des pages de
/// code posé : certaines trames sont marquées de code avant le remplissage
/// du tampon, d'autres après ; le tampon est rempli page par page par une
/// lecture ou une écriture du noyau, une lecture du programme, ou rien ;
/// l'anneau zéro ou trois, CR0.WP tiré, et parfois la pagination éteinte le
/// tampon encore plein. Les adresses : au bout d'une page (à cheval sur
/// deux trames éloignées), n'importe où dans les données, sur une page
/// absente (dont une qui partage la case du tampon d'une page présente),
/// hors de l'espace canonique. Chaque accès, lecture ou écriture d'une à
/// huit octets, est fait par les deux chemins depuis le même état, et tout
/// est comparé : la valeur ou le refus, `faulted`, `unmapped`, le code de
/// faute, la mémoire, la marque de chaque page et la génération de celles
/// qui restent marquées.
#[test]
fn the_fast_memory_paths_do_what_the_slow_ones_do() {
    let mut h = Hasard(0x5EED_0042, &[0]);
    let largeurs = [Width::Byte, Width::Word, Width::Dword, Width::Qword];
    let (mut a_cheval, mut fautes, mut sur_du_code, mut anneau_trois) = (0, 0, 0, 0);
    let mut sans_pagination = 0;
    for tirage in 0..30_000 {
        let mut cpu = processeur(&mut h).with_code_tracking();
        let trame = |rang: u64| 0x40000 + (15 - rang) * 0x1000;
        let mut marquees = Vec::new();
        for rang in 0..16u64 {
            if h.un_sur(4) {
                cpu.marquer_code(trame(rang));
                marquees.push(trame(rang));
            }
        }
        // Le tampon rempli page par page, puis d'autres trames marquées.
        for rang in 0..16u64 {
            let ici = DONNEES + rang * 0x1000 + h.sous(0x1000);
            match h.sous(4) {
                0 => {}
                1 => {
                    let _ = cpu.read_memory(ici, Width::Byte);
                }
                2 => {
                    let valeur = cpu.read_memory(ici, Width::Byte).unwrap_or(0);
                    let _ = cpu.write_memory(ici, Width::Byte, valeur);
                }
                _ => {
                    cpu.segments[1] = 0x33;
                    let _ = cpu.read_memory(ici, Width::Byte);
                    cpu.segments[1] = 0;
                }
            }
        }
        for rang in 0..16u64 {
            if h.un_sur(6) {
                cpu.marquer_code(trame(rang));
                marquees.push(trame(rang));
            }
        }
        cpu.faulted = false;
        cpu.unmapped = None;
        cpu.fault_code = 0;
        if h.un_sur(3) {
            cpu.segments[1] = 0x33;
            anneau_trois += 1;
        }
        if h.un_sur(16) {
            // Sans `write_control_register` : le tampon reste plein, et rien
            // ne doit plus le lire.
            cpu.control[0] &= !(1 << 31);
            sans_pagination += 1;
        }
        let largeur = h.parmi(&largeurs);
        let adresse = match h.sous(9) {
            0..=2 => DONNEES + h.sous(16) * 0x1000 + 0x1000 - h.sous(8) - 1,
            3..=5 => DONNEES + h.sous(0x10000),
            6 => DONNEES + 0x10000 + h.sous(0x4000),
            // Quatre mébioctets plus loin : une page absente, dans la même
            // case du tampon qu'une page de données présente.
            7 => DONNEES + (1 << 22) + h.sous(0x10000),
            _ => 0x8000_0000_0000_0000 | h.sous(0x1_0000_0000),
        };
        if (adresse & 0xFFF) + largeur as u64 > 0x1000 {
            a_cheval += 1;
        }
        let ecrit = h.un_sur(2);
        let valeur = h.suivant();
        let mut lent = cpu.clone();
        let rendu_rapide;
        let rendu_lent;
        if ecrit {
            rendu_rapide = format!("{:?}", cpu.write_memory_fast(adresse, largeur, valeur));
            rendu_lent = format!("{:?}", lent.write_memory(adresse, largeur, valeur));
            let visee = if lent.control[0] & (1 << 31) == 0 {
                Some(adresse & !0xFFF)
            } else {
                adresse
                    .checked_sub(DONNEES)
                    .filter(|&ecart| ecart < 0x10000)
                    .map(|ecart| trame(ecart >> 12))
            };
            if visee.is_some_and(|visee| marquees.contains(&visee)) {
                sur_du_code += 1;
            }
        } else {
            rendu_rapide = format!("{:?}", cpu.read_memory_fast(adresse, largeur));
            rendu_lent = format!("{:?}", lent.read_memory(adresse, largeur));
        }
        if lent.faulted {
            fautes += 1;
        }
        let quoi = format!(
            "tirage {tirage} : {} de {largeur:?} à {adresse:#x}, anneau {}, CR0 {:#x}",
            if ecrit { "écriture" } else { "lecture" },
            lent.segments[1] & 3,
            lent.control[0]
        );
        assert_eq!(rendu_rapide, rendu_lent, "{quoi} : ce qui est rendu");
        assert_eq!(apres_l_acces(&cpu), apres_l_acces(&lent), "{quoi} : l'état");
        assert!(cpu.memory.bytes == lent.memory.bytes, "{quoi} : la mémoire");
    }
    // Les tirages ont exercé ce qu'ils disent.
    assert!(a_cheval > 3_000, "{a_cheval} accès à cheval");
    assert!(fautes > 3_000, "{fautes} fautes");
    assert!(
        sur_du_code > 1_000,
        "{sur_du_code} écritures sur une trame de code"
    );
    assert!(anneau_trois > 8_000, "{anneau_trois} en anneau trois");
    assert!(sans_pagination > 1_000, "{sans_pagination} sans pagination");
}
