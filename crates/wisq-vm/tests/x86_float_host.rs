//! **Le flottant, contre le silicium de l'hôte**, là où les corpus se taisent.
//!
//! Les corpus matériels (`x86_float_oracle.rs`) sont relevés MXCSR à 0x1F80
//! et le mot de contrôle du x87 à 0x37F : au plus proche, en pleine
//! précision, sans regarder les drapeaux de MXCSR. Le reste — les trois
//! autres modes d'arrondi, les six drapeaux, FTZ et DAZ, la précision réduite
//! du x87 — se juge ici, **sur un hôte x86-64**, en faisant faire la même
//! instruction au processeur qui exécute le test, sur des valeurs tirées au
//! hasard et aux bords (zéros, dénormaux, plus petits normaux, plus grands
//! finis, infinis, NaN silencieux et signalants). Le résultat doit être le
//! même **au bit près**, et MXCSR (ou le mot d'état) aussi.
//!
//! Ailleurs (ARM), ce fichier ne compile rien : les corpus restent le juge.
//!
//! Les fonctions transcendantes du x87 ne sont pas au bit près du silicium —
//! aucun processeur ne s'accorde avec un autre là-dessus — et sont jugées à
//! une tolérance près, sur le domaine où le silicium est lui-même juste.

#![cfg(target_arch = "x86_64")]

use std::arch::asm;

use wisq_vm::x86::{decode, decode_extended, Cpu, GuestMemory, Op};

const CODE: u64 = 0x3000_0000;
const DATA: u64 = 0x3000_1000;

/// SplitMix64 : un tirage reproductible.
struct Hasard(u64);

impl Hasard {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// **Un flottant aux bords**, de `fraction` et `exponent` bits : la moitié
    /// des tirages tombe sur une classe particulière, l'autre sur des bits
    /// quelconques.
    fn ieee(&mut self, fraction: u32, exponent: u32) -> u64 {
        let sign = (self.next() & 1) << (fraction + exponent);
        let all = (1u64 << exponent) - 1;
        let fraction_mask = (1u64 << fraction) - 1;
        let random_fraction = self.next() & fraction_mask;
        let bias = (1u64 << (exponent - 1)) - 1;
        let body = match self.next() % 16 {
            0 => 0,
            1 => 1,
            2 => random_fraction,
            3 => 1 << fraction,
            4 => (1 << fraction) | random_fraction & 0xFF,
            5 => (all - 1) << fraction | fraction_mask,
            6 => (all - 1) << fraction | random_fraction,
            7 => all << fraction,
            8 => all << fraction | 1 << (fraction - 1) | random_fraction >> 1,
            9 => all << fraction | (random_fraction >> 1).max(1),
            10 => bias << fraction,
            11 => (bias + self.next() % 64) << fraction | random_fraction,
            12 => (bias - self.next() % 64) << fraction | random_fraction,
            13 => (self.next() % 3 + 1) << fraction | random_fraction,
            _ => self.next() & ((all << fraction) | fraction_mask),
        };
        sign | body
    }

    fn double(&mut self) -> u64 {
        self.ieee(52, 11)
    }

    /// Un simple dans les 32 bits bas, du bruit au-dessus : le haut doit
    /// rester ce qu'il était.
    fn single(&mut self) -> u64 {
        (self.next() & 0xFFFF_FFFF_0000_0000) | self.ieee(23, 8)
    }
}

fn processor(code: &[u8]) -> Cpu {
    let mut ram = vec![0u8; 0x4000];
    ram[..code.len()].copy_from_slice(code);
    let mut cpu = Cpu {
        rip: CODE,
        memory: GuestMemory {
            base: CODE,
            bytes: ram,
        },
        mxcsr: 0x1f80,
        fpu_control: 0x037f,
        ..Default::default()
    };
    cpu.regs[6] = DATA;
    cpu.flags.write(2);
    cpu
}

fn run(cpu: &mut Cpu, length: usize) {
    while cpu.rip < CODE + length as u64 {
        let at = (cpu.rip - CODE) as usize;
        let window = cpu.memory.bytes[at..at + 15].to_vec();
        if let Some(decoded) = decode(&window) {
            match decoded.op {
                Op::Vector(_) => cpu.execute_vector(&decoded).expect("sans faute"),
                _ => cpu.execute(&decoded),
            }
            assert!(!cpu.faulted, "{window:02x?}");
            cpu.rip += decoded.length as u64;
        } else {
            let extended = decode_extended(&window).unwrap_or_else(|| panic!("{window:02x?}"));
            cpu.execute_extended(&extended).expect("sans faute");
            cpu.rip += extended.length as u64;
        }
    }
}

/// Ce qu'une instruction de SSE rend : XMM0, RAX, MXCSR, les drapeaux.
type Outcome = ([u64; 2], u64, u32, u64);

/// **La même instruction, sur l'hôte.** MXCSR est posé, l'instruction
/// exécutée entre XMM0 et XMM1 (et RAX), puis MXCSR relu et celui du test
/// rendu.
macro_rules! host {
    ($instruction:literal) => {
        |xmm0: [u64; 2], xmm1: [u64; 2], rax: u64, mxcsr: u32| -> Outcome {
            let mut a = xmm0;
            let b = xmm1;
            let mut control = mxcsr;
            let mut saved = 0u32;
            let mut accumulator = rax;
            let flags: u64;
            // SAFETY: les pointeurs désignent des tampons vivants de seize
            // octets (ou quatre) ; MXCSR est rendu à sa valeur d'avant, toutes
            // les exceptions masquées pendant l'instruction ; XMM0, XMM1 et
            // RAX sont déclarés écrits.
            unsafe {
                asm!(
                    "stmxcsr [{saved}]",
                    "ldmxcsr [{control}]",
                    "movups xmm0, [{a}]",
                    "movups xmm1, [{b}]",
                    $instruction,
                    "movups [{a}], xmm0",
                    "stmxcsr [{control}]",
                    "ldmxcsr [{saved}]",
                    "pushfq",
                    "pop {flags}",
                    saved = in(reg) &mut saved,
                    control = in(reg) &mut control,
                    a = in(reg) a.as_mut_ptr(),
                    b = in(reg) b.as_ptr(),
                    flags = out(reg) flags,
                    inout("rax") accumulator,
                    out("xmm0") _,
                    out("xmm1") _,
                );
            }
            (a, accumulator, control, flags & 0x8d5)
        }
    };
}

/// Une forme de SSE, ses octets, et le tirage de ses opérandes.
struct Form {
    name: &'static str,
    code: &'static [u8],
    host: fn([u64; 2], [u64; 2], u64, u32) -> Outcome,
    double: bool,
}

fn forms() -> Vec<Form> {
    macro_rules! form {
        ($name:literal, $code:expr, $double:expr) => {
            Form {
                name: $name,
                code: &$code,
                host: host!($name),
                double: $double,
            }
        };
    }
    vec![
        form!("addsd xmm0, xmm1", [0xf2, 0x0f, 0x58, 0xc1], true),
        form!("subsd xmm0, xmm1", [0xf2, 0x0f, 0x5c, 0xc1], true),
        form!("mulsd xmm0, xmm1", [0xf2, 0x0f, 0x59, 0xc1], true),
        form!("divsd xmm0, xmm1", [0xf2, 0x0f, 0x5e, 0xc1], true),
        form!("sqrtsd xmm0, xmm1", [0xf2, 0x0f, 0x51, 0xc1], true),
        form!("minsd xmm0, xmm1", [0xf2, 0x0f, 0x5d, 0xc1], true),
        form!("maxsd xmm0, xmm1", [0xf2, 0x0f, 0x5f, 0xc1], true),
        form!("addss xmm0, xmm1", [0xf3, 0x0f, 0x58, 0xc1], false),
        form!("subss xmm0, xmm1", [0xf3, 0x0f, 0x5c, 0xc1], false),
        form!("mulss xmm0, xmm1", [0xf3, 0x0f, 0x59, 0xc1], false),
        form!("divss xmm0, xmm1", [0xf3, 0x0f, 0x5e, 0xc1], false),
        form!("sqrtss xmm0, xmm1", [0xf3, 0x0f, 0x51, 0xc1], false),
        form!("minss xmm0, xmm1", [0xf3, 0x0f, 0x5d, 0xc1], false),
        form!("maxss xmm0, xmm1", [0xf3, 0x0f, 0x5f, 0xc1], false),
        form!("addpd xmm0, xmm1", [0x66, 0x0f, 0x58, 0xc1], true),
        form!("mulps xmm0, xmm1", [0x0f, 0x59, 0xc1], false),
        form!("divps xmm0, xmm1", [0x0f, 0x5e, 0xc1], false),
        form!("sqrtpd xmm0, xmm1", [0x66, 0x0f, 0x51, 0xc1], true),
        form!("cvtsd2ss xmm0, xmm1", [0xf2, 0x0f, 0x5a, 0xc1], true),
        form!("cvtss2sd xmm0, xmm1", [0xf3, 0x0f, 0x5a, 0xc1], false),
        form!("cvtpd2ps xmm0, xmm1", [0x66, 0x0f, 0x5a, 0xc1], true),
        form!("cvtps2pd xmm0, xmm1", [0x0f, 0x5a, 0xc1], false),
        form!("cvtsd2si rax, xmm1", [0xf2, 0x48, 0x0f, 0x2d, 0xc1], true),
        form!("cvttsd2si rax, xmm1", [0xf2, 0x48, 0x0f, 0x2c, 0xc1], true),
        form!("cvtsd2si eax, xmm1", [0xf2, 0x0f, 0x2d, 0xc1], true),
        form!("cvtss2si rax, xmm1", [0xf3, 0x48, 0x0f, 0x2d, 0xc1], false),
        form!("cvttss2si eax, xmm1", [0xf3, 0x0f, 0x2c, 0xc1], false),
        form!("cvtsi2sd xmm0, rax", [0xf2, 0x48, 0x0f, 0x2a, 0xc0], true),
        form!("cvtsi2ss xmm0, rax", [0xf3, 0x48, 0x0f, 0x2a, 0xc0], false),
        form!("cvtsi2ss xmm0, eax", [0xf3, 0x0f, 0x2a, 0xc0], false),
        form!("cvtps2dq xmm0, xmm1", [0x66, 0x0f, 0x5b, 0xc1], false),
        form!("cvttpd2dq xmm0, xmm1", [0x66, 0x0f, 0xe6, 0xc1], true),
        form!("cvtpd2dq xmm0, xmm1", [0xf2, 0x0f, 0xe6, 0xc1], true),
        form!("cvtdq2ps xmm0, xmm1", [0x0f, 0x5b, 0xc1], false),
        form!("ucomisd xmm0, xmm1", [0x66, 0x0f, 0x2e, 0xc1], true),
        form!("comisd xmm0, xmm1", [0x66, 0x0f, 0x2f, 0xc1], true),
        form!("ucomiss xmm0, xmm1", [0x0f, 0x2e, 0xc1], false),
        form!("comiss xmm0, xmm1", [0x0f, 0x2f, 0xc1], false),
        form!("cmpsd xmm0, xmm1, 1", [0xf2, 0x0f, 0xc2, 0xc1, 1], true),
        form!("cmpsd xmm0, xmm1, 2", [0xf2, 0x0f, 0xc2, 0xc1, 2], true),
        form!("cmpsd xmm0, xmm1, 3", [0xf2, 0x0f, 0xc2, 0xc1, 3], true),
        form!("cmpsd xmm0, xmm1, 4", [0xf2, 0x0f, 0xc2, 0xc1, 4], true),
        form!("cmpss xmm0, xmm1, 5", [0xf3, 0x0f, 0xc2, 0xc1, 5], false),
        form!("cmpps xmm0, xmm1, 0", [0x0f, 0xc2, 0xc1, 0], false),
        form!("cmppd xmm0, xmm1, 6", [0x66, 0x0f, 0xc2, 0xc1, 6], true),
    ]
}

/// **Chaque forme, dans les quatre modes d'arrondi, avec et sans FTZ et DAZ,
/// sur six mille tirages** : XMM0, RAX, MXCSR et les drapeaux, au bit près du
/// processeur de l'hôte.
#[test]
fn sse_matches_the_host_silicon_in_every_mode() {
    let mut h = Hasard(0x5EED_F10A);
    let mut wrong = Vec::new();
    let mut cases = 0;
    for form in forms() {
        for draw in 0..6000 {
            let rounding = (draw % 4) << 13;
            let ftz = if draw % 7 == 3 { 1 << 15 } else { 0 };
            let daz = if draw % 5 == 2 { 1 << 6 } else { 0 };
            let mxcsr = 0x1f80 | rounding | ftz | daz;
            let operand = |h: &mut Hasard| {
                if form.double {
                    [h.double(), h.double()]
                } else {
                    [
                        (h.single() & 0xFFFF_FFFF) | (h.single() << 32),
                        (h.single() & 0xFFFF_FFFF) | (h.single() << 32),
                    ]
                }
            };
            let (xmm0, xmm1) = (operand(&mut h), operand(&mut h));
            let rax = match h.next() % 4 {
                0 => h.next(),
                1 => h.next() % 1000,
                2 => (h.next() % 1000).wrapping_neg(),
                _ => h.next() >> (h.next() % 64),
            };
            let wanted = (form.host)(xmm0, xmm1, rax, mxcsr);
            let mut cpu = processor(form.code);
            cpu.xmm[0] = xmm0;
            cpu.xmm[1] = xmm1;
            cpu.regs[0] = rax;
            cpu.mxcsr = mxcsr;
            run(&mut cpu, form.code.len());
            let mut got = (cpu.xmm[0], cpu.regs[0], cpu.mxcsr, cpu.flags.read() & 0x8d5);
            // Seules les comparaisons écrivent les drapeaux ; pour les autres,
            // ceux de l'hôte sont ce que le test y a laissé.
            let mut wanted = wanted;
            if !form.name.contains("comis") {
                got.3 = 0;
                wanted.3 = 0;
            }
            cases += 1;
            if got != wanted && wrong.len() < 40 {
                wrong.push(format!(
                    "{} : xmm0 {xmm0:x?} xmm1 {xmm1:x?} rax {rax:x} mxcsr {mxcsr:x}\n    \
                     attendu {wanted:x?}\n    obtenu  {got:x?}",
                    form.name
                ));
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "{} écarts sur {cases} :\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

/// **La petitesse se juge après l'arrondi**, comme sur x86 : `1,5 · 2⁻¹⁰²²
/// × (2/3 − ε)` vaut exactement `(1 − 2⁻⁵⁵) · 2⁻¹⁰²²`, sous le plus petit
/// normal ; arrondi à cinquante-trois bits, exposant non borné, il **monte**
/// au plus petit normal. Le silicium ne lève donc pas UE (PE seul), et FTZ
/// ne l'efface pas. Un cœur qui jugerait avant l'arrondi lèverait UE, et
/// rendrait zéro sous FTZ. Les tirages au hasard ne tombent pas sur ce cas.
#[test]
fn tininess_is_judged_after_rounding_like_the_host() {
    let mulsd = host!("mulsd xmm0, xmm1");
    let (a, b) = (0x0018_0000_0000_0000u64, 0x3FE5_5555_5555_5555u64);
    for rounding in 0..4u32 {
        for ftz in [0, 1 << 15] {
            let mxcsr = 0x1f80 | (rounding << 13) | ftz;
            let wanted = mulsd([a, 0], [b, 0], 0, mxcsr);
            let mut cpu = processor(&[0xf2, 0x0f, 0x59, 0xc1]);
            cpu.xmm[0] = [a, 0];
            cpu.xmm[1] = [b, 0];
            cpu.mxcsr = mxcsr;
            run(&mut cpu, 4);
            assert_eq!(
                (cpu.xmm[0], cpu.mxcsr),
                (wanted.0, wanted.2),
                "mxcsr {mxcsr:x}"
            );
        }
    }
    // Au plus proche, le silicium rend le plus petit normal, PE seul.
    let wanted = mulsd([a, 0], [b, 0], 0, 0x1f80);
    assert_eq!((wanted.0[0], wanted.2), (0x0010_0000_0000_0000, 0x1fa0));
}

// ---- Le x87, contre l'hôte ----

/// Un registre du x87 tiré aux bords : un double élargi, ou une mantisse de
/// soixante-quatre bits quelconque (le bit entier posé), ou une classe
/// particulière de l'étendu.
fn extended(h: &mut Hasard) -> [u8; 10] {
    let (significand, sign_exponent): (u64, u16) = match h.next() % 6 {
        0 => {
            let value = wisq_vm::x86::f80::F80::from_f64_bits(h.double());
            (value.significand, value.sign_exponent)
        }
        1 => (
            h.next() | 1 << 63,
            (0x3FFF + (h.next() % 128) as u16 - 64) | (h.next() as u16 & 0x8000),
        ),
        2 => (h.next() >> 1, h.next() as u16 & 0x8000),
        3 => (h.next() | 1 << 63, 0x7FFE | (h.next() as u16 & 0x8000)),
        4 => (h.next() | 1 << 63, 1 | (h.next() as u16 & 0x8000)),
        _ => (h.next() | 1 << 63, h.next() as u16),
    };
    let mut out = [0u8; 10];
    out[..8].copy_from_slice(&significand.to_le_bytes());
    out[8..].copy_from_slice(&sign_exponent.to_le_bytes());
    out
}

/// Ce qu'une instruction du x87 rend : ST(0) et le mot d'état juste après.
type X87Outcome = ([u8; 10], u16);

macro_rules! host_x87 {
    ($instruction:literal) => {
        |a: [u8; 10], b: [u8; 10], control: u16| -> X87Outcome {
            let mut top = a;
            let status: u16;
            // SAFETY: la pile du x87 est vide à l'entrée (la convention
            // d'appel l'exige) et rendue vide ; les pointeurs désignent des
            // tampons vivants de dix octets.
            unsafe {
                asm!(
                    "fninit",
                    "fldcw [{control}]",
                    "fld tbyte ptr [{b}]",
                    "fld tbyte ptr [{a}]",
                    $instruction,
                    "fnstsw ax",
                    "fstp tbyte ptr [{a}]",
                    "fninit",
                    control = in(reg) &control,
                    a = in(reg) top.as_mut_ptr(),
                    b = in(reg) b.as_ptr(),
                    out("ax") status,
                    out("st(0)") _, out("st(1)") _, out("st(2)") _, out("st(3)") _,
                    out("st(4)") _, out("st(5)") _, out("st(6)") _, out("st(7)") _,
                );
            }
            (top, status)
        }
    };
}

/// **Les quatre opérations, la racine, `frndint`, `fscale`, `fprem` et
/// `fprem1` du x87, dans les quatre modes et les trois précisions** : ST(0)
/// au bit près, les six drapeaux, C0 à C3 et le sommet.
#[test]
fn the_x87_matches_the_host_silicon_in_every_mode_and_precision() {
    type Host = fn([u8; 10], [u8; 10], u16) -> X87Outcome;
    let forms: [(&str, &[u8], Host); 10] = [
        ("fadd", &[0xd8, 0xc1], host_x87!("fadd st, st(1)")),
        ("fsub", &[0xd8, 0xe1], host_x87!("fsub st, st(1)")),
        ("fmul", &[0xd8, 0xc9], host_x87!("fmul st, st(1)")),
        ("fdiv", &[0xd8, 0xf1], host_x87!("fdiv st, st(1)")),
        ("fsqrt", &[0xd9, 0xfa], host_x87!("fsqrt")),
        ("frndint", &[0xd9, 0xfc], host_x87!("frndint")),
        ("fscale", &[0xd9, 0xfd], host_x87!("fscale")),
        ("fprem", &[0xd9, 0xf8], host_x87!("fprem")),
        ("fprem1", &[0xd9, 0xf5], host_x87!("fprem1")),
        ("fxch", &[0xd9, 0xc9], host_x87!("fxch st(1)")),
    ];
    let mut h = Hasard(0x5EED_0087);
    let mut wrong = Vec::new();
    let mut cases = 0;
    for (name, code, host) in forms {
        for draw in 0..4000u32 {
            let rounding = ((draw % 4) as u16) << 10;
            let precision = [0x300u16, 0x200, 0x000][(draw / 4 % 3) as usize];
            let control = 0x007F | rounding | precision;
            let (a, mut b) = (extended(&mut h), extended(&mut h));
            if name == "fscale" && draw % 2 == 0 {
                // Une puissance raisonnable, le plus souvent.
                let power = wisq_vm::x86::f80::F80::from_integer(h.next() as i64 % 200);
                b[..8].copy_from_slice(&power.significand.to_le_bytes());
                b[8..].copy_from_slice(&power.sign_exponent.to_le_bytes());
            }
            let (wanted_top, wanted_status) = host(a, b, control);
            let mut cpu = processor(code);
            cpu.fpu_control = control;
            cpu.fpu_status = 6 << 11;
            cpu.fpu_tags = 0b1100_0000;
            cpu.x87[6] = (
                u64::from_le_bytes(a[..8].try_into().unwrap()),
                u16::from_le_bytes([a[8], a[9]]),
            );
            cpu.x87[7] = (
                u64::from_le_bytes(b[..8].try_into().unwrap()),
                u16::from_le_bytes([b[8], b[9]]),
            );
            run(&mut cpu, code.len());
            let (significand, sign_exponent) = cpu.x87[cpu.x87_top()];
            let mut got_top = [0u8; 10];
            got_top[..8].copy_from_slice(&significand.to_le_bytes());
            got_top[8..].copy_from_slice(&sign_exponent.to_le_bytes());
            // Le sommet de l'hôte part de 7 (deux chargements après fninit) ;
            // celui de la machine de 6 : on compare tout sauf le sommet.
            let mask = 0x47FFu16 & !0x0080;
            let got_status = cpu.fpu_status & mask;
            cases += 1;
            if (got_top, got_status) != (wanted_top, wanted_status & mask) && wrong.len() < 40 {
                wrong.push(format!(
                    "{name} cw {control:x} : a {a:02x?} b {b:02x?}\n    attendu {wanted_top:02x?} \
                     {:x}\n    obtenu  {got_top:02x?} {got_status:x}",
                    wanted_status & mask
                ));
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "{} écarts sur {cases} :\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

macro_rules! host_store {
    ($instruction:literal) => {
        |a: [u8; 10], control: u16| -> (u64, u16) {
            let mut stored = [0u8; 16];
            let status: u16;
            // SAFETY: comme `host_x87` ; le rangement écrit au plus huit
            // octets dans un tampon de seize.
            unsafe {
                asm!(
                    "fninit",
                    "fldcw [{control}]",
                    "fld tbyte ptr [{a}]",
                    $instruction,
                    "fnstsw ax",
                    "fninit",
                    control = in(reg) &control,
                    a = in(reg) a.as_ptr(),
                    out = in(reg) stored.as_mut_ptr(),
                    out("ax") status,
                    out("st(0)") _, out("st(1)") _, out("st(2)") _, out("st(3)") _,
                    out("st(4)") _, out("st(5)") _, out("st(6)") _, out("st(7)") _,
                );
            }
            (u64::from_le_bytes(stored[..8].try_into().unwrap()), status)
        }
    };
}

/// **Les rangements du x87 en mémoire, dans les quatre modes** : `fst` en
/// simple et en double (l'arrondi, le débordement, le sous-débordement, le NaN
/// rendu silencieux), `fist` et `fisttp` aux trois largeurs (l'entier
/// indéfini), `fbstp`. Les octets rangés et le mot d'état, au bit près.
#[test]
fn x87_stores_match_the_host_silicon_in_every_mode() {
    type Host = fn([u8; 10], u16) -> (u64, u16);
    let forms: [(&str, &[u8], Host, usize); 9] = [
        (
            "fstps",
            &[0xd9, 0x5e, 0x20],
            host_store!("fstp dword ptr [{out}]"),
            4,
        ),
        (
            "fstpl",
            &[0xdd, 0x5e, 0x20],
            host_store!("fstp qword ptr [{out}]"),
            8,
        ),
        (
            "fistps",
            &[0xdf, 0x5e, 0x20],
            host_store!("fistp word ptr [{out}]"),
            2,
        ),
        (
            "fistpl",
            &[0xdb, 0x5e, 0x20],
            host_store!("fistp dword ptr [{out}]"),
            4,
        ),
        (
            "fistpll",
            &[0xdf, 0x7e, 0x20],
            host_store!("fistp qword ptr [{out}]"),
            8,
        ),
        (
            "fisttpll",
            &[0xdd, 0x4e, 0x20],
            host_store!("fisttp qword ptr [{out}]"),
            8,
        ),
        (
            "fisttps",
            &[0xdf, 0x4e, 0x20],
            host_store!("fisttp word ptr [{out}]"),
            2,
        ),
        (
            "fbstp",
            &[0xdf, 0x76, 0x20],
            host_store!("fbstp tbyte ptr [{out}]"),
            8,
        ),
        (
            "frndint",
            &[0xd9, 0xfc, 0xdd, 0x5e, 0x20],
            host_store!("frndint\nfstp qword ptr [{out}]"),
            8,
        ),
    ];
    let mut h = Hasard(0x5EED_57A4);
    let mut wrong = Vec::new();
    for (name, code, host, size) in forms {
        for draw in 0..6000u32 {
            let control = 0x037F | (((draw % 4) as u16) << 10);
            let a = if draw % 3 == 0 {
                // Des entiers et des demies, que les arrondis départagent.
                let value = (h.next() % 4_000_001) as f64 / 4.0 - 500_000.0;
                let x = wisq_vm::x86::f80::F80::from_f64_bits(value.to_bits());
                let mut out = [0u8; 10];
                out[..8].copy_from_slice(&x.significand.to_le_bytes());
                out[8..].copy_from_slice(&x.sign_exponent.to_le_bytes());
                out
            } else {
                extended(&mut h)
            };
            let (wanted, wanted_status) = host(a, control);
            let mut cpu = processor(code);
            cpu.fpu_control = control;
            cpu.fpu_status = 7 << 11;
            cpu.fpu_tags = 0b1000_0000;
            cpu.x87[7] = (
                u64::from_le_bytes(a[..8].try_into().unwrap()),
                u16::from_le_bytes([a[8], a[9]]),
            );
            let before = cpu.memory.bytes[0x1020..0x1028].to_vec();
            run(&mut cpu, code.len());
            let mut stored = [0u8; 8];
            stored.copy_from_slice(&cpu.memory.bytes[0x1020..0x1028]);
            let got = u64::from_le_bytes(stored) & mask_of(size);
            // L'hôte range dans un tampon nul : ce qui suit l'entier est zéro.
            let _ = before;
            let mask = 0x47FFu16 & !0x0080;
            let got_status = cpu.fpu_status & mask;
            if (got, got_status) != (wanted & mask_of(size), wanted_status & mask)
                && wrong.len() < 40
            {
                wrong.push(format!(
                    "{name} cw {control:x} : {a:02x?}\n    attendu {:x} {:x}\n    obtenu  {got:x} \
                     {got_status:x}",
                    wanted & mask_of(size),
                    wanted_status & mask
                ));
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "{} écarts :\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

fn mask_of(size: usize) -> u64 {
    if size == 8 {
        u64::MAX
    } else {
        (1u64 << (8 * size)) - 1
    }
}

/// **Les fonctions transcendantes, à une tolérance près.** Aucun processeur
/// ne s'accorde avec un autre au bit près sur `fsin` ; le juste est la valeur
/// vraie. Sur le domaine où le silicium est lui-même juste (|x| ≤ 3 pour le
/// sinus, 1,5 pour la tangente, |x| ≤ 1 pour `f2xm1`…), l'écart doit rester sous 2⁻⁵⁸ en relatif —
/// soixante bits justes sur soixante-quatre —, ou 2⁻⁶² en absolu près d'un
/// zéro de la fonction.
#[test]
fn x87_transcendentals_agree_with_the_host_silicon() {
    use wisq_vm::x86::f80::{self, Rounding, F80};
    type Host = fn([u8; 10], [u8; 10], u16) -> X87Outcome;
    let forms: [(&str, &[u8], Host); 8] = [
        ("fsin", &[0xd9, 0xfe], host_x87!("fsin")),
        ("fcos", &[0xd9, 0xff], host_x87!("fcos")),
        (
            "fptan",
            &[0xd9, 0xf2, 0xdd, 0xd8],
            host_x87!("fptan\nfstp st(0)"),
        ),
        (
            "fsincos",
            &[0xd9, 0xfb, 0xdd, 0xd8],
            host_x87!("fsincos\nfstp st(0)"),
        ),
        ("fpatan", &[0xd9, 0xf3], host_x87!("fpatan")),
        ("f2xm1", &[0xd9, 0xf0], host_x87!("f2xm1")),
        ("fyl2x", &[0xd9, 0xf1], host_x87!("fyl2x")),
        ("fyl2xp1", &[0xd9, 0xf9], host_x87!("fyl2xp1")),
    ];
    let to_bytes = |value: F80| {
        let mut out = [0u8; 10];
        out[..8].copy_from_slice(&value.significand.to_le_bytes());
        out[8..].copy_from_slice(&value.sign_exponent.to_le_bytes());
        out
    };
    let from_bytes = |bytes: [u8; 10]| {
        F80::new(
            u64::from_le_bytes(bytes[..8].try_into().unwrap()),
            u16::from_le_bytes([bytes[8], bytes[9]]),
        )
    };
    let mut h = Hasard(0x5EED_7A45);
    let mut wrong = Vec::new();
    let mut worst = 0f64;
    for (name, code, host) in forms {
        for _ in 0..3000 {
            let uniform = |h: &mut Hasard, low: f64, high: f64| {
                let unit = (h.next() >> 11) as f64 / (1u64 << 53) as f64;
                // Une mantisse de soixante-quatre bits quelconque : du bruit
                // sous le double.
                let x = F80::from_f64_bits((low + (high - low) * unit).to_bits());
                F80::new(x.significand | (h.next() & 0x7FF), x.sign_exponent)
            };
            let (x, y) = match name {
                "fsin" | "fcos" | "fsincos" => (uniform(&mut h, -3.0, 3.0), F80::ONE),
                // Loin du pôle : près de π/2, le π de soixante-six bits du
                // silicium perd lui-même des bits.
                "fptan" => (uniform(&mut h, -1.5, 1.5), F80::ONE),
                "f2xm1" => (uniform(&mut h, -1.0, 1.0), F80::ONE),
                "fyl2x" => (uniform(&mut h, 1e-6, 1e6), uniform(&mut h, -100.0, 100.0)),
                "fyl2xp1" => (uniform(&mut h, -0.29, 0.29), uniform(&mut h, -100.0, 100.0)),
                _ => (uniform(&mut h, -1e3, 1e3), uniform(&mut h, -1e3, 1e3)),
            };
            let (wanted, _) = host(to_bytes(x), to_bytes(y), 0x037F);
            let mut cpu = processor(code);
            cpu.fpu_status = 6 << 11;
            cpu.fpu_tags = 0b1100_0000;
            cpu.x87[6] = x.pair();
            cpu.x87[7] = y.pair();
            run(&mut cpu, code.len());
            let got = F80::from_pair(cpu.x87[cpu.x87_top()]);
            let wanted = from_bytes(wanted);
            let (difference, _) = f80::subtract(got, wanted, Rounding::NearestEven, 64);
            let scale =
                |value: F80| f64::from_bits(value.narrowed(52, 11, Rounding::NearestEven).0);
            let error = scale(difference).abs();
            let size = scale(wanted).abs();
            let tolerance = (size * 2f64.powi(-58)).max(2f64.powi(-62));
            if size > 0.0 {
                worst = worst.max(error / size.max(2f64.powi(-4)));
            }
            if (error.is_nan() || error > tolerance) && wrong.len() < 30 {
                wrong.push(format!(
                    "{name}({:e}, {:e}) : {:e} au lieu de {:e} (écart {error:e})",
                    scale(x),
                    scale(y),
                    scale(got),
                    scale(wanted)
                ));
            }
        }
    }
    assert!(
        wrong.is_empty(),
        "{} écarts :\n{}",
        wrong.len(),
        wrong.join("\n")
    );
    assert!(worst < 2f64.powi(-58), "le pire écart relatif : {worst:e}");
}
