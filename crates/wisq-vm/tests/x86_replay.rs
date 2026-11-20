//! **Ce qu'un processeur doit à un noyau qui rejoue ses instructions.**
//!
//! Un noyau cartographie à la demande : une instruction faute, le
//! gestionnaire donne la page, l'instruction est **rejouée**. Tout ce qu'elle
//! avait changé avant de fauter fausse la seconde exécution. Ces tests
//! tiennent les règles que la machine PC native a fait poser dans
//! l'interpréteur — une instruction qui faute n'a rien fait, un `mov` ne lit
//! pas sa destination, un `rep` par pages rend ce que le même `rep` rend
//! élément par élément — et celles de la traduction d'adresses avec tampon.

use wisq_vm::x86::{decode, Cpu, GuestMemory, Width, CF, OF, ZF};
use wisq_vm::x86_paging::{Access, Unmapped};

const PRESENT: u64 = 1;
const WRITABLE: u64 = 2;
const USER: u64 = 4;
const ACCESSED: u64 = 1 << 5;
const DIRTY: u64 = 1 << 6;
const WRITE_PROTECT: u64 = 1 << 16;

/// Un processeur qui pagine : la racine à 0x1000, et une page virtuelle par
/// entrée de `pages` (adresse virtuelle, page physique, droits de la feuille).
/// `cached` lui donne le tampon de traduction de la machine.
fn paged(pages: &[(u64, u64, u64)], cached: bool) -> Cpu {
    let mut cpu = Cpu {
        memory: GuestMemory {
            base: 0,
            bytes: vec![0u8; 0x40000],
        },
        ..Default::default()
    };
    if cached {
        cpu = cpu.with_translation_cache();
    }
    let open = PRESENT | WRITABLE | USER;
    let mut put = |at: u64, value: u64| {
        cpu.memory.write(at, Width::Qword, value).unwrap();
    };
    put(0x1000, 0x2000 | open);
    put(0x2000, 0x3000 | open);
    put(0x3000, 0x4000 | open);
    for &(virtual_address, frame, rights) in pages {
        put(
            0x4000 + ((virtual_address >> 12) & 0x1FF) * 8,
            frame | rights,
        );
    }
    cpu.control[3] = 0x1000;
    cpu.control[0] = (1 << 31) | 1 | WRITE_PROTECT;
    cpu
}

fn leaf(cpu: &Cpu, virtual_address: u64) -> u64 {
    cpu.memory
        .read(0x4000 + ((virtual_address >> 12) & 0x1FF) * 8, Width::Qword)
        .unwrap()
}

/// Exécuter une instruction posée à 0x10000 (page de code cartographiée en
/// identité par les appelants).
fn run(cpu: &mut Cpu, code: &[u8]) {
    let instruction = decode(code).expect("une instruction que le décodeur lit");
    cpu.rip = 0x10000;
    cpu.jumped = false;
    cpu.execute(&instruction);
}

const DATA: u64 = 0x20000;
const CODE_PAGE: (u64, u64, u64) = (0x10000, 0x10000, PRESENT | WRITABLE);
/// La page de données, en lecture seule : celle d'une copie sur écriture.
const READ_ONLY: (u64, u64, u64) = (DATA, 0x20000, PRESENT);

/// **Une instruction qui écrit en mémoire et faute n'a rien changé** : ni les
/// drapeaux, ni le registre qu'elle allait échanger. C'est ce qui permet au
/// noyau de la rejouer une fois la page copiée.
#[test]
fn a_write_that_faults_leaves_flags_and_registers_as_they_were() {
    let forms: [(&str, &[u8]); 12] = [
        ("adc %rax,(%rbx)", &[0x48, 0x11, 0x03]),
        ("sbb %rax,(%rbx)", &[0x48, 0x19, 0x03]),
        ("add %rax,(%rbx)", &[0x48, 0x01, 0x03]),
        ("inc (%rbx)", &[0x48, 0xff, 0x03]),
        ("neg (%rbx)", &[0x48, 0xf7, 0x1b]),
        ("shl $3,(%rbx)", &[0x48, 0xc1, 0x23, 0x03]),
        ("rcl $1,(%rbx)", &[0x48, 0xd1, 0x13]),
        ("rol $5,(%rbx)", &[0x48, 0xc1, 0x03, 0x05]),
        ("shld $4,%rax,(%rbx)", &[0x48, 0x0f, 0xa4, 0x03, 0x04]),
        ("xchg %rax,(%rbx)", &[0x48, 0x87, 0x03]),
        ("xadd %rax,(%rbx)", &[0x48, 0x0f, 0xc1, 0x03]),
        ("cmpxchg %rcx,(%rbx)", &[0x48, 0x0f, 0xb1, 0x0b]),
    ];
    for cached in [false, true] {
        for (name, code) in forms {
            let mut cpu = paged(&[CODE_PAGE, READ_ONLY], cached);
            cpu.memory
                .write(0x20000, Width::Qword, 0x8000_0000_0000_0001)
                .unwrap();
            // RAX diffère de la mémoire, pour qu'un échange se voie — sauf
            // devant `cmpxchg`, qui n'écrit que s'ils sont égaux.
            let rax = if name.starts_with("cmpxchg") {
                0x8000_0000_0000_0001
            } else {
                0x4000_0000_0000_0003
            };
            cpu.regs[0] = rax;
            cpu.regs[1] = 0x77;
            cpu.regs[3] = DATA;
            let flags = CF | OF | 2;
            cpu.flags.write(flags);
            run(&mut cpu, code);
            assert!(cpu.faulted, "{name} : la page est en lecture seule");
            assert_eq!(
                cpu.unmapped,
                Some(Unmapped::ReadOnly { address: DATA }),
                "{name}"
            );
            assert_eq!(
                cpu.flags.read(),
                flags,
                "{name} : les drapeaux n'ont pas bougé"
            );
            assert_eq!(cpu.regs[0], rax, "{name} : RAX n'a pas bougé");
            assert_eq!(cpu.regs[1], 0x77, "{name} : RCX n'a pas bougé");
            assert_eq!(
                cpu.memory.read(0x20000, Width::Qword),
                Some(0x8000_0000_0000_0001),
                "{name} : la mémoire n'a pas bougé"
            );

            // Le noyau rend la page inscriptible (et, avec un tampon, le dit) ;
            // rejouée, l'instruction rend ce qu'elle aurait rendu d'emblée.
            let mut direct = paged(&[CODE_PAGE, (DATA, 0x20000, PRESENT | WRITABLE)], cached);
            direct
                .memory
                .write(0x20000, Width::Qword, 0x8000_0000_0000_0001)
                .unwrap();
            direct.regs = cpu.regs;
            direct.flags.write(flags);
            run(&mut direct, code);
            assert!(!direct.faulted, "{name}");

            let entry = 0x4000 + ((DATA >> 12) & 0x1FF) * 8;
            cpu.memory
                .write(entry, Width::Qword, 0x20000 | PRESENT | WRITABLE)
                .unwrap();
            cpu.flush_translations();
            cpu.faulted = false;
            cpu.unmapped = None;
            run(&mut cpu, code);
            assert!(!cpu.faulted, "{name} : rejouée");
            assert_eq!(
                cpu.regs, direct.regs,
                "{name} : les registres de la reprise"
            );
            assert_eq!(
                cpu.flags.read(),
                direct.flags.read(),
                "{name} : ses drapeaux"
            );
            assert_eq!(
                cpu.memory.read(0x20000, Width::Qword),
                direct.memory.read(0x20000, Width::Qword),
                "{name} : sa mémoire"
            );
        }
    }
}

/// **Un `mov` vers la mémoire ne lit pas sa destination.** Sur une page
/// absente, la faute est une faute d'**écriture** — le code d'erreur que le
/// noyau reçoit, et qui lui fait donner d'emblée une page inscriptible.
#[test]
fn a_store_faults_as_a_write_and_never_reads_its_destination() {
    let mut cpu = paged(&[CODE_PAGE], true);
    cpu.regs[3] = DATA;
    // mov %rax,(%rbx)
    run(&mut cpu, &[0x48, 0x89, 0x03]);
    assert!(cpu.faulted);
    assert_eq!(cpu.fault_code, 1 << 1, "absente, en écriture");
    // mov (%rbx),%rax : une lecture, elle.
    cpu.faulted = false;
    run(&mut cpu, &[0x48, 0x8b, 0x03]);
    assert_eq!(cpu.fault_code, 0, "absente, en lecture");
    // Sur une page présente mais jamais lue, le rangement ne la marque
    // « accédée » que par son écriture — et « salie » du même coup.
    let mut cpu = paged(&[CODE_PAGE, (DATA, 0x20000, PRESENT | WRITABLE)], true);
    cpu.regs[3] = DATA;
    cpu.regs[0] = 0x1234;
    run(&mut cpu, &[0x48, 0x89, 0x03]);
    assert!(!cpu.faulted);
    assert_eq!(cpu.memory.read(0x20000, Width::Qword), Some(0x1234));
    assert_eq!(leaf(&cpu, DATA) & (ACCESSED | DIRTY), ACCESSED | DIRTY);
}

/// **Les bits que le processeur pose lui-même**, avec le tampon : « accédée »
/// à la lecture, « salie » à la première écriture seulement — même quand la
/// traduction est déjà gardée pour la lecture.
#[test]
fn the_translation_cache_marks_accessed_and_dirty_like_the_silicon() {
    let mut cpu = paged(&[(DATA, 0x20000, PRESENT | WRITABLE)], true);
    assert_eq!(leaf(&cpu, DATA) & (ACCESSED | DIRTY), 0);
    assert_eq!(cpu.read_memory(DATA + 8, Width::Qword), Ok(0));
    assert_eq!(
        leaf(&cpu, DATA) & (ACCESSED | DIRTY),
        ACCESSED,
        "lue : accédée, pas salie"
    );
    assert_eq!(cpu.read_memory(DATA + 16, Width::Qword), Ok(0));
    assert_eq!(cpu.write_memory(DATA + 8, Width::Qword, 7), Ok(()));
    assert_eq!(
        leaf(&cpu, DATA) & (ACCESSED | DIRTY),
        ACCESSED | DIRTY,
        "écrite : salie"
    );
    // Les tables aussi sont marquées « accédée », à chaque niveau.
    for table in [0x1000u64, 0x2000, 0x3000] {
        assert_ne!(cpu.memory.read(table, Width::Qword).unwrap() & ACCESSED, 0);
    }
    // Sans tampon, l'interpréteur de référence ne touche pas aux tables.
    let mut plain = paged(&[(DATA, 0x20000, PRESENT | WRITABLE)], false);
    assert_eq!(plain.write_memory(DATA, Width::Qword, 7), Ok(()));
    assert_eq!(leaf(&plain, DATA) & (ACCESSED | DIRTY), 0);
}

/// **Le tampon garde, et les trois vidages le vident.** Une table changée
/// sans rien dire reste invisible — comme sur le silicium — jusqu'à ce que
/// l'invité écrive CR3, CR4 ou les bits de CR0, ou que la machine vide.
#[test]
fn the_translation_cache_holds_until_one_of_its_flushes() {
    let entry = 0x4000 + ((DATA >> 12) & 0x1FF) * 8;
    let remap = |cpu: &mut Cpu| {
        cpu.memory
            .write(entry, Width::Qword, 0x21000 | PRESENT | WRITABLE)
            .unwrap();
    };
    type Flush = (&'static str, fn(&mut Cpu));
    let flushes: [Flush; 5] = [
        ("écrire CR3", |cpu| cpu.write_control_register(3, 0x1000)),
        ("écrire CR4", |cpu| cpu.write_control_register(4, 1 << 5)),
        ("changer CR0.WP", |cpu| {
            cpu.write_control_register(0, (1 << 31) | 1)
        }),
        ("éteindre et rallumer la pagination", |cpu| {
            cpu.write_control_register(0, 1 | WRITE_PROTECT);
            cpu.write_control_register(0, (1 << 31) | 1 | WRITE_PROTECT);
        }),
        ("flush_translations", Cpu::flush_translations),
    ];
    for (name, flush) in flushes {
        let mut cpu = paged(&[(DATA, 0x20000, PRESENT | WRITABLE)], true);
        cpu.memory.write(0x20000, Width::Qword, 0xAAAA).unwrap();
        cpu.memory.write(0x21000, Width::Qword, 0xBBBB).unwrap();
        assert_eq!(cpu.read_memory(DATA, Width::Qword), Ok(0xAAAA));
        let generation = cpu.tlb.as_ref().unwrap().generation;
        remap(&mut cpu);
        assert_eq!(
            cpu.read_memory(DATA, Width::Qword),
            Ok(0xAAAA),
            "{name} : la traduction gardée sert encore"
        );
        flush(&mut cpu);
        assert_eq!(
            cpu.read_memory(DATA, Width::Qword),
            Ok(0xBBBB),
            "{name} : vidée, la nouvelle table est lue"
        );
        assert!(cpu.tlb.as_ref().unwrap().generation > generation, "{name}");
    }
    // Écrire CR0 sans changer ses deux bits ne vide rien.
    let mut cpu = paged(&[(DATA, 0x20000, PRESENT | WRITABLE)], true);
    cpu.memory.write(0x20000, Width::Qword, 0xAAAA).unwrap();
    assert_eq!(cpu.read_memory(DATA, Width::Qword), Ok(0xAAAA));
    remap(&mut cpu);
    cpu.write_control_register(0, (1 << 31) | 1 | WRITE_PROTECT | (1 << 3));
    assert_eq!(cpu.read_memory(DATA, Width::Qword), Ok(0xAAAA));
}

/// **L'anneau trois n'a droit qu'aux pages qui portent le bit utilisateur à
/// chaque niveau**, et le droit se juge à chaque accès : la même traduction
/// gardée sert le noyau et refuse le programme.
#[test]
fn ring_three_needs_the_user_bit_and_the_cache_does_not_forget_it() {
    for cached in [false, true] {
        let mut cpu = paged(
            &[
                (DATA, 0x20000, PRESENT | WRITABLE),
                (DATA + 0x1000, 0x21000, PRESENT | USER),
            ],
            cached,
        );
        // Le noyau lit et écrit sa page.
        assert_eq!(cpu.write_memory(DATA, Width::Qword, 5), Ok(()));
        assert_eq!(cpu.read_memory(DATA, Width::Qword), Ok(5));
        // Le programme, non — par la même traduction, déjà gardée.
        cpu.segments[1] = 0x33;
        assert_eq!(
            cpu.read_memory(DATA, Width::Qword),
            Err(Unmapped::Forbidden { address: DATA })
        );
        if cached {
            assert_eq!(cpu.fault_code, 1 | (1 << 2), "présente, anneau trois");
        }
        assert_eq!(
            cpu.write_memory(DATA, Width::Qword, 6),
            Err(Unmapped::Forbidden { address: DATA })
        );
        // Sa page à lui se lit, et ne s'écrit pas : lecture seule.
        assert_eq!(cpu.read_memory(DATA + 0x1000, Width::Qword), Ok(0));
        assert_eq!(
            cpu.write_memory(DATA + 0x1000, Width::Qword, 6),
            Err(Unmapped::ReadOnly {
                address: DATA + 0x1000
            })
        );
        if cached {
            assert_eq!(cpu.fault_code, 1 | (1 << 1) | (1 << 2));
        }
        // Une lecture que le processeur fait pour lui-même passe quand même.
        assert_eq!(cpu.read_memory_as_machine(DATA, Width::Qword), Ok(5));
        // En anneau trois, CR0.WP ne change rien : la page reste fermée.
        cpu.write_control_register(0, (1 << 31) | 1);
        assert!(cpu.write_memory(DATA + 0x1000, Width::Qword, 6).is_err());
        // Revenu en anneau zéro sans WP, le noyau écrit à travers.
        cpu.segments[1] = 0x10;
        cpu.faulted = false;
        assert_eq!(cpu.write_memory(DATA + 0x1000, Width::Qword, 6), Ok(()));
    }
}

/// **Le bit 63 interdit d'exécuter, quand EFER.NXE le permet** — et seulement
/// d'exécuter.
#[test]
fn the_no_execute_bit_refuses_a_fetch_only_under_nxe() {
    let nx = 1u64 << 63;
    for cached in [false, true] {
        let mut cpu = paged(&[(DATA, 0x20000, PRESENT | WRITABLE | nx)], cached);
        assert_eq!(
            cpu.translate_cached(DATA, Access::Fetch),
            Ok(0x20000),
            "sans NXE, rien"
        );
        cpu.efer |= 1 << 11;
        cpu.flush_translations();
        assert_eq!(
            cpu.translate_cached(DATA, Access::Fetch),
            Err(Unmapped::Forbidden { address: DATA })
        );
        if cached {
            assert_eq!(
                cpu.fault_code,
                1 | (1 << 4),
                "présente, lecture d'instruction"
            );
        }
        assert_eq!(cpu.translate_cached(DATA, Access::Read), Ok(0x20000));
        assert_eq!(cpu.translate_cached(DATA + 5, Access::Write), Ok(0x20005));
    }
}

/// **`rep movs` et `rep stos` par pages entières rendent ce que le même `rep`
/// rend élément par élément**, registres compris — y compris quand la
/// destination commence dans la source, où la copie répète un motif, et quand
/// une page manque au milieu.
#[test]
fn bulk_strings_match_the_element_by_element_path() {
    // La référence : la même boucle, écrite ici, un élément à la fois.
    fn reference(cpu: &mut Cpu, moves: bool, size: u64) {
        let width = match size {
            1 => Width::Byte,
            2 => Width::Word,
            4 => Width::Dword,
            _ => Width::Qword,
        };
        while cpu.regs[1] != 0 {
            let value = if moves {
                match cpu.read_memory(cpu.regs[6], width) {
                    Ok(value) => value,
                    Err(_) => return,
                }
            } else {
                cpu.regs[0] & width.mask()
            };
            if cpu.write_memory(cpu.regs[7], width, value).is_err() {
                return;
            }
            if moves {
                cpu.regs[6] += size;
            }
            cpu.regs[7] += size;
            cpu.regs[1] -= 1;
        }
    }
    let pages = [
        CODE_PAGE,
        (0x20000, 0x20000, PRESENT | WRITABLE),
        (0x21000, 0x21000, PRESENT | WRITABLE),
        (0x22000, 0x22000, PRESENT | WRITABLE),
        // 0x23000 manque : une copie qui l'atteint faute à sa frontière.
        (0x28000, 0x28000, PRESENT | WRITABLE),
        (0x29000, 0x29000, PRESENT | WRITABLE),
    ];
    // (code, élément, source, destination, compte)
    type Case = (&'static str, &'static [u8], u64, u64, u64, u64);
    let cases: [Case; 9] = [
        (
            "rep movsb, deux pages et demie",
            &[0xf3, 0xa4],
            1,
            0x20010,
            0x28020,
            0x1800,
        ),
        ("rep movsq", &[0xf3, 0x48, 0xa5], 8, 0x20008, 0x28010, 0x180),
        (
            "rep movsl, désaligné",
            &[0xf3, 0xa5],
            4,
            0x20ffe,
            0x28003,
            0x300,
        ),
        (
            "rep movsw à cheval sur chaque page",
            &[0xf3, 0x66, 0xa5],
            2,
            0x20fff,
            0x28fff,
            0x500,
        ),
        (
            "rep movsb, destination dans la source",
            &[0xf3, 0xa4],
            1,
            0x20000,
            0x20003,
            0x1200,
        ),
        (
            "rep movsb, destination sous la source",
            &[0xf3, 0xa4],
            1,
            0x20100,
            0x20000,
            0x1200,
        ),
        (
            "rep movsb jusqu'à la page absente",
            &[0xf3, 0xa4],
            1,
            0x28000,
            0x22800,
            0x1000,
        ),
        ("rep stosb", &[0xf3, 0xaa], 1, 0, 0x28ff0, 0x1010),
        (
            "rep stosq jusqu'à la page absente",
            &[0xf3, 0x48, 0xab],
            8,
            0,
            0x22f00,
            0x400,
        ),
    ];
    for cached in [false, true] {
        for (name, code, size, source, destination, count) in cases {
            let build = || {
                let mut cpu = paged(&pages, cached);
                for (index, byte) in cpu.memory.bytes[0x20000..0x2a000].iter_mut().enumerate() {
                    *byte = (index * 31 + (index >> 8)) as u8;
                }
                cpu.regs[0] = 0x1122_3344_5566_7788;
                cpu.regs[1] = count;
                cpu.regs[6] = source;
                cpu.regs[7] = destination;
                cpu
            };
            let mut bulk = build();
            run(&mut bulk, code);
            let mut slow = build();
            reference(
                &mut slow,
                code.contains(&0xa4) || code.contains(&0xa5),
                size,
            );
            assert_eq!(bulk.regs, slow.regs, "{name} : RSI, RDI et RCX");
            assert_eq!(bulk.faulted, slow.faulted, "{name}");
            assert_eq!(bulk.unmapped, slow.unmapped, "{name} : la même faute");
            assert!(
                bulk.memory.bytes[0x20000..0x2a000] == slow.memory.bytes[0x20000..0x2a000],
                "{name} : la mémoire"
            );
        }
    }
}

/// Le sens arrière ne passe pas par les pages entières, et reste juste.
#[test]
fn a_backward_copy_still_goes_one_element_at_a_time() {
    let mut cpu = paged(&[CODE_PAGE, (DATA, 0x20000, PRESENT | WRITABLE)], true);
    for (index, byte) in cpu.memory.bytes[0x20000..0x20100].iter_mut().enumerate() {
        *byte = index as u8;
    }
    cpu.flags.write(1 << 10); // DF
    cpu.regs[1] = 0x20;
    cpu.regs[6] = DATA + 0x3f;
    cpu.regs[7] = DATA + 0x4f;
    run(&mut cpu, &[0xf3, 0xa4]);
    assert_eq!(cpu.regs[1], 0);
    assert_eq!((cpu.regs[6], cpu.regs[7]), (DATA + 0x1f, DATA + 0x2f));
    let got: Vec<u8> = cpu.memory.bytes[0x20030..0x20050].to_vec();
    let wanted: Vec<u8> = (0x20u8..0x40).collect();
    assert_eq!(got, wanted);
    assert_eq!(cpu.flags.read() & ZF, 0, "aucun drapeau n'a bougé");
}
