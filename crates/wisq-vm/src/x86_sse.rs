//! **Le calcul flottant de SSE et SSE2** — le port de `X86Float.swift` et
//! des formes de base de `X86VectorArithmetic.swift`, pour la machine PC
//! native.
//!
//! **Rien n'est laissé à l'hôte.** Le cœur Swift déléguait les sommes et les
//! produits de valeurs ordinaires à Swift, donc au processeur qui fait tourner
//! wisq, et ne tenait ni le mode d'arrondi de MXCSR ni ses drapeaux. Ici tout
//! est calculé sur des entiers et arrondi **une fois** (`round_pack`), comme
//! l'étendu du x87 (`x86_f80.rs`) : le résultat est le même sur tout hôte,
//! dans les quatre modes d'arrondi, avec les six drapeaux de MXCSR, FTZ et
//! DAZ. Une exception **démasquée** ne range rien et rend
//! `ExtendedFault::SimdException`, que la machine livre en `#XM`.
//!
//! **Trois règles que le calcul ne donne pas**, fixées par le silicium
//! (`x86-float-oracle.tsv`) :
//!
//! 1. *Seule la partie basse change* pour une forme scalaire.
//! 2. *`min` et `max` rendent la source* quand la comparaison échoue — un NaN,
//!    ou deux zéros de signes opposés —, telle quelle, bit pour bit.
//! 3. *Une conversion qui déborde ne faute pas* : l'entier indéfini.
//!
//! Et une règle des NaN : la destination si c'en est un, sinon la source,
//! rendus silencieux ; un NaN né de deux nombres est l'indéfini, **négatif**.
//!
//! **Où ces formes sont lues.** `decode`, que l'émetteur partage, ne les lit
//! pas sur cette branche : `decode_extended` les rend, et la machine native
//! les exécute. Le jour où `decode` les lira (`Vector::Float`, branche de
//! l'émetteur), `execute_vector` devra les confier à `execute_sse`, qui ne
//! dépend que de l'opération, des registres et de l'adresse.

use super::f80::{rounds_up, Rounding};
use super::{Extended, ExtendedFault, Extra};
use crate::x86::{Cpu, Width, AF, CF, OF, PF, SF, ZF};

/// Les drapeaux d'exception de MXCSR (bits 0 à 5), et leurs masques (7 à 12).
pub const IE: u32 = 1 << 0;
pub const DE: u32 = 1 << 1;
pub const ZE: u32 = 1 << 2;
pub const OE: u32 = 1 << 3;
pub const UE: u32 = 1 << 4;
pub const PE: u32 = 1 << 5;
/// `DAZ` : un dénormal lu vaut zéro.
const DAZ: u32 = 1 << 6;
/// `FTZ` : un résultat qui sous-déborde vaut zéro.
const FTZ: u32 = 1 << 15;

/// L'opération d'un élément.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FloatOp {
    Add,
    Sub,
    Mul,
    Div,
    Min,
    Max,
    Sqrt,
}

/// **Une instruction flottante de SSE ou SSE2.** `double` : des doubles (`f2`
/// en scalaire, `66` en empaqueté), sinon des simples. Les champs de
/// `Extended` : `reg` le XMM (ou le registre général, ou le MMX) du champ
/// `reg`, `rm` celui du champ `rm`, `memory` l'opérande en mémoire, `imm` le
/// prédicat d'une comparaison, `width` la largeur d'un entier (`REX.W`).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Sse {
    /// `addss`… `sqrtsd` : l'élément bas, le reste de la destination laissé.
    Scalar { op: FloatOp, double: bool },
    /// Leurs formes empaquetées.
    Packed { op: FloatOp, double: bool },
    /// `cmpss`/`cmpsd` : un masque dans l'élément bas.
    CompareScalar { double: bool },
    /// `cmpps`/`cmppd`.
    ComparePacked { double: bool },
    /// `ucomiss`, `ucomisd` (`signaling` faux), `comiss`, `comisd` : ZF, PF,
    /// CF.
    Order { double: bool, signaling: bool },
    /// `cvtss2sd`.
    Widen,
    /// `cvtsd2ss`.
    Narrow,
    /// `cvtps2pd`.
    PackedWiden,
    /// `cvtpd2ps`.
    PackedNarrow,
    /// `cvtsi2ss`/`cvtsi2sd` : depuis un registre général ou la mémoire.
    FromInteger { double: bool },
    /// `cvt(t)ss2si`/`cvt(t)sd2si` : vers le registre général `reg`.
    ToInteger { double: bool, truncate: bool },
    /// `cvtdq2pd`, `cvtdq2ps`.
    FromIntegers { double: bool },
    /// `cvtpd2dq`, `cvttpd2dq`, `cvtps2dq`, `cvttps2dq`.
    ToIntegers { double: bool, truncate: bool },
    /// `cvtpi2ps`, `cvtpi2pd` : deux entiers d'un MMX ou de la mémoire.
    FromMmx { double: bool },
    /// `cvt(t)ps2pi`, `cvt(t)pd2pi` : vers le MMX `reg`.
    ToMmx { double: bool, truncate: bool },
    /// `rcpss`, `rcpps`, `rsqrtss`, `rsqrtps` : une approximation, que le
    /// manuel borne à 1,5 · 2⁻¹² en relatif. Ce cœur rend le quotient ou la
    /// racine **justes**, arrondis au plus proche : c'est dans la borne, et le
    /// même sur tout hôte.
    Reciprocal { scalar: bool, root: bool },
}

/// **Décoder une instruction flottante de la page `0f`**, l'octet `second`
/// lu ; `mandatory` est le préfixe obligatoire (`0`, `0x66`, `0xf3`, `0xf2`).
/// Rend la forme et si elle lit un immédiat.
pub(super) fn decode(mandatory: u8, second: u8) -> Option<(Sse, bool)> {
    let double_scalar = mandatory == 0xf2;
    let double_packed = mandatory == 0x66;
    let op = |second: u8| match second {
        0x51 => FloatOp::Sqrt,
        0x58 => FloatOp::Add,
        0x59 => FloatOp::Mul,
        0x5c => FloatOp::Sub,
        0x5d => FloatOp::Min,
        0x5e => FloatOp::Div,
        _ => FloatOp::Max,
    };
    let form = match (mandatory, second) {
        (0xf3 | 0xf2, 0x51 | 0x58 | 0x59 | 0x5c..=0x5f) => Sse::Scalar {
            op: op(second),
            double: double_scalar,
        },
        (0 | 0x66, 0x51 | 0x58 | 0x59 | 0x5c..=0x5f) => Sse::Packed {
            op: op(second),
            double: double_packed,
        },
        (0xf3 | 0xf2, 0xc2) => Sse::CompareScalar {
            double: double_scalar,
        },
        (0 | 0x66, 0xc2) => Sse::ComparePacked {
            double: double_packed,
        },
        (0 | 0x66, 0x2e | 0x2f) => Sse::Order {
            double: double_packed,
            signaling: second == 0x2f,
        },
        (0xf3, 0x5a) => Sse::Widen,
        (0xf2, 0x5a) => Sse::Narrow,
        (0, 0x5a) => Sse::PackedWiden,
        (0x66, 0x5a) => Sse::PackedNarrow,
        (0xf3 | 0xf2, 0x2a) => Sse::FromInteger {
            double: double_scalar,
        },
        (0xf3 | 0xf2, 0x2c | 0x2d) => Sse::ToInteger {
            double: double_scalar,
            truncate: second == 0x2c,
        },
        (0xf3, 0xe6) => Sse::FromIntegers { double: true },
        (0x66 | 0xf2, 0xe6) => Sse::ToIntegers {
            double: true,
            truncate: mandatory == 0x66,
        },
        (0, 0x5b) => Sse::FromIntegers { double: false },
        (0x66 | 0xf3, 0x5b) => Sse::ToIntegers {
            double: false,
            truncate: mandatory == 0xf3,
        },
        (0 | 0x66, 0x2a) => Sse::FromMmx {
            double: double_packed,
        },
        (0 | 0x66, 0x2c | 0x2d) => Sse::ToMmx {
            double: double_packed,
            truncate: second == 0x2c,
        },
        (0 | 0xf3, 0x52 | 0x53) => Sse::Reciprocal {
            scalar: mandatory == 0xf3,
            root: second == 0x52,
        },
        _ => return None,
    };
    Some((form, second == 0xc2))
}

/// Un format IEEE : les bits de fraction et d'exposant.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Format {
    fraction: u32,
    exponent: u32,
}

const SINGLE: Format = Format {
    fraction: 23,
    exponent: 8,
};
const DOUBLE: Format = Format {
    fraction: 52,
    exponent: 11,
};

impl Format {
    fn of(double: bool) -> Self {
        if double {
            DOUBLE
        } else {
            SINGLE
        }
    }

    fn bias(self) -> i32 {
        (1 << (self.exponent - 1)) - 1
    }

    fn all_ones(self) -> u64 {
        (1 << self.exponent) - 1
    }

    fn sign_bit(self) -> u64 {
        1 << (self.fraction + self.exponent)
    }

    fn mask(self) -> u64 {
        if self.fraction == 52 {
            u64::MAX
        } else {
            0xFFFF_FFFF
        }
    }

    fn infinity(self, negative: bool) -> u64 {
        (if negative { self.sign_bit() } else { 0 }) | (self.all_ones() << self.fraction)
    }

    fn zero(self, negative: bool) -> u64 {
        if negative {
            self.sign_bit()
        } else {
            0
        }
    }

    /// L'indéfini réel : le NaN silencieux **négatif**.
    fn indefinite(self) -> u64 {
        self.infinity(true) | (1 << (self.fraction - 1))
    }

    fn largest(self, negative: bool) -> u64 {
        self.infinity(negative) - 1
    }

    fn quiet(self, bits: u64) -> u64 {
        bits | (1 << (self.fraction - 1))
    }
}

/// Ce qu'un élément est.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Class {
    Zero,
    Finite,
    Infinite,
    Quiet,
    Signaling,
}

/// **Un élément déballé** : le signe, la classe, et pour un nombre fini la
/// mantisse **normalisée** (bit de tête au rang 63) et l'exposant de ce bit.
/// Un dénormal est normalisé ; `denormal` le retient pour le drapeau.
#[derive(Clone, Copy, Debug)]
struct Unpacked {
    negative: bool,
    class: Class,
    significand: u64,
    exponent: i32,
    denormal: bool,
}

fn unpack(bits: u64, format: Format, daz: bool) -> Unpacked {
    let negative = bits & format.sign_bit() != 0;
    let biased = (bits >> format.fraction) & format.all_ones();
    let fraction = bits & ((1u64 << format.fraction) - 1);
    let mut out = Unpacked {
        negative,
        class: Class::Finite,
        significand: 0,
        exponent: 0,
        denormal: false,
    };
    if biased == format.all_ones() {
        out.class = if fraction == 0 {
            Class::Infinite
        } else if fraction >> (format.fraction - 1) != 0 {
            Class::Quiet
        } else {
            Class::Signaling
        };
        return out;
    }
    if biased == 0 {
        if fraction == 0 || daz {
            out.class = Class::Zero;
            return out;
        }
        let lead = fraction.leading_zeros();
        out.significand = fraction << lead;
        out.exponent = 1 - format.bias() - (lead as i32 - (63 - format.fraction as i32));
        out.denormal = true;
        return out;
    }
    out.significand = (1u64 << 63) | (fraction << (63 - format.fraction));
    out.exponent = biased as i32 - format.bias();
    out
}

/// **Arrondir une fois et ranger.** `wide` porte la valeur exacte, bit de
/// tête au rang 127 (`value = wide · 2^(exponent − 127)`), un bit collant
/// dans les rangs bas s'il le faut. Rend les bits et les drapeaux.
///
/// La petitesse se juge **après** l'arrondi, comme sur x86 : un résultat qui
/// s'arrondit au plus petit normal n'a pas sous-débordé.
fn round_pack(
    negative: bool,
    mut exponent: i32,
    mut wide: u128,
    format: Format,
    rounding: Rounding,
    flush: bool,
) -> (u64, u32) {
    let precision = format.fraction + 1;
    let minimum = 1 - format.bias();
    let maximum = format.bias();
    // Normaliser (une soustraction peut laisser des zéros de tête).
    let lead = wide.leading_zeros() as i32;
    wide <<= lead;
    exponent -= lead;
    // Arrondir `wide` à `bits` bits : la mantisse gardée, et si elle a
    // débordé d'un rang.
    let round = |wide: u128, bits: u32| -> (u64, bool, bool) {
        let kept = (wide >> (128 - bits)) as u64;
        let below = wide << bits;
        let rest = (below >> 64) as u64 | u64::from(below as u64 != 0);
        let mut kept = kept;
        if rounds_up(rest, kept & 1 == 0, negative, rounding) {
            kept += 1;
        }
        (kept, rest != 0, kept >> bits != 0)
    };
    let mut flags = 0;
    if exponent < minimum {
        // Petit avant l'arrondi ; l'est-il encore après, exposant non borné ?
        let carries = exponent == minimum - 1 && round(wide, precision).2;
        let tiny = !carries;
        // Dénormaliser, puis arrondir à la place qui reste.
        let shift = (minimum - exponent) as u32;
        let shifted = if shift >= 128 {
            u128::from(wide != 0)
        } else {
            (wide >> shift) | u128::from(wide & ((1u128 << shift) - 1) != 0)
        };
        let (kept, inexact, _) = round(shifted, precision);
        if tiny && flush {
            return (format.zero(negative), UE | PE);
        }
        if inexact {
            flags |= PE;
            if tiny {
                flags |= UE;
            }
        }
        // `kept` a son bit implicite au rang `fraction` s'il est remonté au
        // plus petit normal : l'exposant biaisé un s'y lit tout seul.
        return (format.zero(negative) | kept, flags);
    }
    let (mut kept, inexact, carry) = round(wide, precision);
    if inexact {
        flags |= PE;
    }
    if carry {
        kept >>= 1;
        exponent += 1;
    }
    if exponent > maximum {
        flags |= OE | PE;
        let refuses = rounding == Rounding::TowardZero
            || (rounding == Rounding::Down && !negative)
            || (rounding == Rounding::Up && negative);
        return (
            if refuses {
                format.largest(negative)
            } else {
                format.infinity(negative)
            },
            flags,
        );
    }
    let biased = (exponent + format.bias()) as u64;
    (
        format.zero(negative)
            | (biased << format.fraction)
            | (kept & ((1u64 << format.fraction) - 1)),
        flags,
    )
}

/// Le contexte d'un calcul : le mode, FTZ, DAZ, et les drapeaux rencontrés.
struct Context {
    rounding: Rounding,
    flush: bool,
    daz: bool,
    flags: u32,
}

impl Context {
    fn of(mxcsr: u32) -> Self {
        Self {
            rounding: Rounding::from_field(mxcsr >> 13),
            flush: mxcsr & FTZ != 0,
            daz: mxcsr & DAZ != 0,
            flags: 0,
        }
    }

    fn unpack(&mut self, bits: u64, format: Format) -> Unpacked {
        let value = unpack(bits, format, self.daz);
        if value.denormal {
            self.flags |= DE;
        }
        value
    }

    fn pack(&mut self, negative: bool, exponent: i32, wide: u128, format: Format) -> u64 {
        let (bits, flags) = round_pack(negative, exponent, wide, format, self.rounding, self.flush);
        self.flags |= flags;
        bits
    }

    /// La règle des NaN d'une opération à deux opérandes : la destination si
    /// c'en est un, sinon la source, rendus silencieux.
    fn nan(&mut self, a: (u64, Unpacked), b: (u64, Unpacked), format: Format) -> Option<u64> {
        let is_nan = |class| matches!(class, Class::Quiet | Class::Signaling);
        if a.1.class == Class::Signaling || b.1.class == Class::Signaling {
            self.flags |= IE;
        }
        if is_nan(a.1.class) {
            return Some(format.quiet(a.0));
        }
        if is_nan(b.1.class) {
            return Some(format.quiet(b.0));
        }
        None
    }

    fn invalid(&mut self, format: Format) -> u64 {
        self.flags |= IE;
        format.indefinite()
    }

    /// **Une opération sur un élément**, `a` la destination, `b` la source.
    fn arithmetic(&mut self, op: FloatOp, a: u64, b: u64, format: Format) -> u64 {
        if op == FloatOp::Sqrt {
            return self.square_root(b, format);
        }
        if matches!(op, FloatOp::Min | FloatOp::Max) {
            return self.select(op, a, b, format);
        }
        // **L'ordre des exceptions** : un NaN, puis l'invalide et la division
        // par zéro, puis le dénormal, puis le reste. Un dénormal ne se signale
        // que si rien de plus prioritaire ne l'a fait.
        let x = unpack(a, format, self.daz);
        let y = unpack(b, format, self.daz);
        if let Some(nan) = self.nan((a, x), (b, y), format) {
            return nan;
        }
        let before = self.flags;
        self.flags = 0;
        let result = self.compute(op, x, y, format);
        if (x.denormal || y.denormal) && self.flags & (IE | ZE) == 0 {
            self.flags |= DE;
        }
        self.flags |= before;
        result
    }

    /// Le calcul d'un élément, ni l'un ni l'autre NaN.
    fn compute(&mut self, op: FloatOp, x: Unpacked, y: Unpacked, format: Format) -> u64 {
        match op {
            FloatOp::Add | FloatOp::Sub => {
                let y = Unpacked {
                    negative: y.negative != (op == FloatOp::Sub),
                    ..y
                };
                self.add(x, y, format)
            }
            FloatOp::Mul => {
                let negative = x.negative != y.negative;
                match (x.class, y.class) {
                    (Class::Infinite, Class::Zero) | (Class::Zero, Class::Infinite) => {
                        self.invalid(format)
                    }
                    (Class::Infinite, _) | (_, Class::Infinite) => format.infinity(negative),
                    (Class::Zero, _) | (_, Class::Zero) => format.zero(negative),
                    _ => {
                        let product = u128::from(x.significand) * u128::from(y.significand);
                        self.pack(negative, x.exponent + y.exponent + 1, product, format)
                    }
                }
            }
            _ => {
                let negative = x.negative != y.negative;
                match (x.class, y.class) {
                    (Class::Infinite, Class::Infinite) | (Class::Zero, Class::Zero) => {
                        self.invalid(format)
                    }
                    (Class::Infinite, _) => format.infinity(negative),
                    (_, Class::Infinite) | (Class::Zero, _) => format.zero(negative),
                    (_, Class::Zero) => {
                        self.flags |= ZE;
                        format.infinity(negative)
                    }
                    _ => {
                        // Le quotient de 2¹²⁷ · m_a par m_b : soixante-quatre
                        // bits au moins, le reste dans un bit collant.
                        let dividend = u128::from(x.significand) << 64;
                        let divisor = u128::from(y.significand);
                        let quotient = dividend / divisor;
                        let sticky = u128::from(dividend % divisor != 0);
                        // quotient vaut entre 2⁶⁴ et 2⁶⁵ : rang 64 ou 63.
                        let wide = (quotient << 62) | sticky;
                        self.pack(negative, x.exponent - y.exponent + 1, wide, format)
                    }
                }
            }
        }
    }

    fn add(&mut self, x: Unpacked, y: Unpacked, format: Format) -> u64 {
        match (x.class, y.class) {
            (Class::Infinite, Class::Infinite) if x.negative != y.negative => {
                return self.invalid(format)
            }
            (Class::Infinite, _) => return format.infinity(x.negative),
            (_, Class::Infinite) => return format.infinity(y.negative),
            (Class::Zero, Class::Zero) => {
                let negative = if x.negative == y.negative {
                    x.negative
                } else {
                    self.rounding == Rounding::Down
                };
                return format.zero(negative);
            }
            (Class::Zero, _) => return self.pack(y.negative, y.exponent, wide_of(y), format),
            (_, Class::Zero) => return self.pack(x.negative, x.exponent, wide_of(x), format),
            _ => {}
        }
        let (big, small) = if (x.exponent, x.significand) >= (y.exponent, y.significand) {
            (x, y)
        } else {
            (y, x)
        };
        // Un rang de marge en tête pour la retenue : bit de tête au rang 126.
        let first = u128::from(big.significand) << 63;
        let gap = (big.exponent - small.exponent) as u32;
        let second = u128::from(small.significand) << 63;
        let second = if gap >= 127 {
            u128::from(second != 0)
        } else {
            (second >> gap) | u128::from(second & ((1u128 << gap) - 1) != 0)
        };
        if big.negative == small.negative {
            return self.pack(big.negative, big.exponent + 1, first + second, format);
        }
        let difference = first - second;
        if difference == 0 {
            return format.zero(self.rounding == Rounding::Down);
        }
        self.pack(big.negative, big.exponent + 1, difference, format)
    }

    /// **`min` et `max` ne calculent pas** : ils comparent et choisissent. Un
    /// NaN d'un côté ou de l'autre, ou deux zéros, rendent la source telle
    /// quelle ; un NaN, même silencieux, est une opération invalide.
    fn select(&mut self, op: FloatOp, a: u64, b: u64, format: Format) -> u64 {
        let x = unpack(a, format, self.daz);
        let y = unpack(b, format, self.daz);
        // Sous DAZ, un dénormal compte et ressort comme un zéro — même quand
        // c'est la source qu'un NaN fait rendre.
        let a = if x.class == Class::Zero {
            a & format.sign_bit()
        } else {
            a
        };
        let b = if y.class == Class::Zero {
            b & format.sign_bit()
        } else {
            b
        };
        let nan = |class| matches!(class, Class::Quiet | Class::Signaling);
        if nan(x.class) || nan(y.class) {
            self.flags |= IE;
            return b;
        }
        if x.denormal || y.denormal {
            self.flags |= DE;
        }
        let order = compare(x, y);
        let keep = match op {
            FloatOp::Min => order == std::cmp::Ordering::Less,
            _ => order == std::cmp::Ordering::Greater,
        };
        if keep {
            a
        } else {
            b
        }
    }

    /// La racine, qui **ne regarde que sa source**.
    fn square_root(&mut self, b: u64, format: Format) -> u64 {
        let y = unpack(b, format, self.daz);
        match y.class {
            Class::Signaling => {
                self.flags |= IE;
                return format.quiet(b);
            }
            Class::Quiet => return b,
            Class::Zero => return format.zero(y.negative),
            _ if y.negative => return self.invalid(format),
            Class::Infinite => return b,
            Class::Finite => {}
        }
        if y.denormal {
            self.flags |= DE;
        }
        // valeur = m · 2^(e − 63) ; une puissance paire, et la racine entière
        // d'un nombre de cent vingt-huit bits.
        let odd = y.exponent & 1 != 0;
        let number = if odd {
            u128::from(y.significand) << 64
        } else {
            u128::from(y.significand) << 63
        };
        let (root, remainder) = integer_square_root(number);
        // root ≈ √number, bit de tête au rang 63 ; la valeur vaut
        // root · 2^((e − odd)/2 − 63 + …).
        let exponent = (y.exponent - i32::from(odd)) / 2;
        let wide = (u128::from(root) << 64) | u128::from(remainder != 0);
        self.pack(false, exponent, wide, format)
    }

    /// La comparaison qui rend un **masque** : les huit prédicats de
    /// l'immédiat. Un NaN signalant est toujours invalide ; un NaN silencieux
    /// l'est pour `lt`, `le`, `nlt` et `nle`.
    fn predicate(&mut self, code: u64, a: u64, b: u64, format: Format) -> bool {
        let x = unpack(a, format, self.daz);
        let y = unpack(b, format, self.daz);
        let signaling = x.class == Class::Signaling || y.class == Class::Signaling;
        let unordered = signaling || x.class == Class::Quiet || y.class == Class::Quiet;
        if signaling || (unordered && matches!(code & 7, 1 | 2 | 5 | 6)) {
            self.flags |= IE;
        }
        if !unordered && (x.denormal || y.denormal) {
            self.flags |= DE;
        }
        let order = if unordered { None } else { Some(compare(x, y)) };
        use std::cmp::Ordering::{Equal, Less};
        match code & 7 {
            0 => order == Some(Equal),
            1 => order == Some(Less),
            2 => matches!(order, Some(Less | Equal)),
            3 => unordered,
            4 => order != Some(Equal),
            5 => order != Some(Less),
            6 => !matches!(order, Some(Less | Equal)),
            _ => !unordered,
        }
    }

    /// **Vers un entier signé** de 32 ou 64 bits, arrondi selon le mode (ou
    /// tronqué). Hors de portée, ou d'un NaN : l'entier indéfini, invalide.
    fn integer_of(&mut self, bits: u64, format: Format, wide: bool, truncate: bool) -> u64 {
        let width = if wide { 64 } else { 32 };
        let indefinite = 1u64 << (width - 1);
        let x = unpack(bits, format, self.daz);
        match x.class {
            Class::Zero => return 0,
            Class::Finite => {}
            _ => {
                self.flags |= IE;
                return indefinite;
            }
        }
        let rounding = if truncate {
            Rounding::TowardZero
        } else {
            self.rounding
        };
        // La partie entière et ce qui suit la virgule, cadré en tête.
        let (whole, rest) = if x.exponent >= 63 {
            (u128::from(x.significand) << (x.exponent - 63).min(64), 0u64)
        } else if x.exponent >= 0 {
            (
                u128::from(x.significand >> (63 - x.exponent)),
                x.significand << (x.exponent + 1),
            )
        } else if x.exponent == -1 {
            (0, x.significand)
        } else {
            (0, 1)
        };
        let mut whole = whole;
        if rounds_up(rest, whole & 1 == 0, x.negative, rounding) {
            whole += 1;
        }
        let limit = 1u128 << (width - 1);
        let fits = if x.negative {
            whole <= limit
        } else {
            whole < limit
        };
        if !fits || x.exponent >= 64 {
            self.flags |= IE;
            return indefinite;
        }
        if rest != 0 {
            self.flags |= PE;
        }
        let value = if x.negative {
            (whole as u64).wrapping_neg()
        } else {
            whole as u64
        };
        if wide {
            value
        } else {
            value & 0xFFFF_FFFF
        }
    }

    /// Un entier signé vers le format : exact, ou arrondi une fois.
    fn float_of(&mut self, value: i64, format: Format) -> u64 {
        if value == 0 {
            return 0;
        }
        let magnitude = value.unsigned_abs();
        let lead = magnitude.leading_zeros();
        let wide = u128::from(magnitude << lead) << 64;
        self.pack(value < 0, 63 - lead as i32, wide, format)
    }

    /// **Changer de format** : `cvtss2sd`, `cvtsd2ss` et leurs formes
    /// empaquetées. Un NaN garde son signe et le haut de sa charge, et
    /// devient silencieux ; un signalant est invalide.
    fn convert(&mut self, bits: u64, from: Format, to: Format) -> u64 {
        let x = self.unpack(bits, from);
        match x.class {
            Class::Signaling | Class::Quiet => {
                if x.class == Class::Signaling {
                    self.flags |= IE;
                }
                let payload = bits & ((1u64 << from.fraction) - 1);
                let payload = if to.fraction > from.fraction {
                    payload << (to.fraction - from.fraction)
                } else {
                    payload >> (from.fraction - to.fraction)
                };
                to.quiet(to.infinity(x.negative) | payload)
            }
            Class::Infinite => to.infinity(x.negative),
            Class::Zero => to.zero(x.negative),
            Class::Finite => self.pack(x.negative, x.exponent, wide_of(x), to),
        }
    }

    /// `rcp` et `rsqrt` : 1/x ou 1/√x, juste et arrondi au plus proche, sur
    /// des simples. Un dénormal lu vaut zéro, un résultat dénormal aussi ;
    /// aucune exception, aucun drapeau.
    fn reciprocal(&mut self, bits: u64, root: bool) -> u64 {
        let saved = (self.flags, self.rounding, self.flush, self.daz);
        self.rounding = Rounding::NearestEven;
        self.flush = true;
        self.daz = true;
        let x = unpack(bits, SINGLE, true);
        let result = match x.class {
            Class::Quiet | Class::Signaling => SINGLE.quiet(bits),
            Class::Zero => SINGLE.infinity(x.negative),
            Class::Infinite if x.negative && root => SINGLE.indefinite(),
            Class::Infinite => SINGLE.zero(x.negative),
            Class::Finite if x.negative && root => SINGLE.indefinite(),
            Class::Finite => {
                let source = if root {
                    self.square_root(bits, SINGLE)
                } else {
                    bits
                };
                self.arithmetic(FloatOp::Div, 0x3F80_0000, source, SINGLE)
            }
        };
        (self.flags, self.rounding, self.flush, self.daz) = saved;
        result
    }
}

/// Une valeur finie déballée, en mantisse de cent vingt-huit bits.
fn wide_of(x: Unpacked) -> u128 {
    u128::from(x.significand) << 64
}

/// L'ordre de deux nombres (ni l'un ni l'autre NaN) ; deux zéros sont égaux.
fn compare(x: Unpacked, y: Unpacked) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let magnitude = |v: Unpacked| match v.class {
        Class::Zero => (0, i32::MIN, 0),
        Class::Infinite => (2, 0, 0),
        _ => (1, v.exponent, v.significand),
    };
    if x.class == Class::Zero && y.class == Class::Zero {
        return Ordering::Equal;
    }
    match (x.negative, y.negative) {
        (false, true) => return Ordering::Greater,
        (true, false) => return Ordering::Less,
        _ => {}
    }
    let order = magnitude(x).cmp(&magnitude(y));
    if x.negative {
        order.reverse()
    } else {
        order
    }
}

/// La racine entière d'un nombre d'au moins 2¹²⁶, et si elle est exacte.
fn integer_square_root(number: u128) -> (u64, u128) {
    let mut root = ((number as f64).sqrt() as u64).max(1 << 63);
    let square = |value: u64| u128::from(value) * u128::from(value);
    for _ in 0..4 {
        if ((number >> 64) as u64) >= root {
            break;
        }
        let quotient = (number / u128::from(root)) as u64;
        let (sum, carry) = root.overflowing_add(quotient);
        root = if carry {
            (sum >> 1) | (1 << 63)
        } else {
            sum >> 1
        };
    }
    while square(root) > number {
        root -= 1;
    }
    while root < u64::MAX && square(root + 1) <= number {
        root += 1;
    }
    (root, number - square(root))
}

/// Les éléments d'un registre de seize octets : quatre simples ou deux
/// doubles, rangés dans leurs mots.
fn lanes(value: [u64; 2], double: bool) -> Vec<u64> {
    if double {
        vec![value[0], value[1]]
    } else {
        vec![
            value[0] & 0xFFFF_FFFF,
            value[0] >> 32,
            value[1] & 0xFFFF_FFFF,
            value[1] >> 32,
        ]
    }
}

fn join_lanes(values: &[u64], double: bool) -> [u64; 2] {
    if double {
        [values[0], values[1]]
    } else {
        [values[0] | (values[1] << 32), values[2] | (values[3] << 32)]
    }
}

impl Cpu {
    /// **Exécuter une instruction flottante de SSE ou SSE2.** RIP n'est pas
    /// avancé. Une instruction qui faute — en mémoire, ou d'une exception
    /// démasquée — n'a rien écrit dans un registre.
    pub(super) fn execute_sse(
        &mut self,
        instruction: &Extended,
        at: Option<u64>,
    ) -> Result<(), ExtendedFault> {
        let Extra::Sse(form) = instruction.op else {
            unreachable!("execute_sse ne reçoit que le flottant de SSE")
        };
        let d = usize::from(instruction.reg & 15);
        let s = usize::from(instruction.rm & 15);
        let mut context = Context::of(self.mxcsr);
        // La source : seize octets, ou l'élément bas qu'une forme scalaire lit.
        let read = |cpu: &mut Self, bytes: u64| -> Result<[u64; 2], ExtendedFault> {
            match at {
                Some(at) if bytes == 16 => Ok([
                    cpu.sse_read(at, Width::Qword)?,
                    cpu.sse_read(at.wrapping_add(8), Width::Qword)?,
                ]),
                Some(at) => {
                    let width = if bytes == 8 {
                        Width::Qword
                    } else {
                        Width::Dword
                    };
                    Ok([cpu.sse_read(at, width)?, 0])
                }
                None => Ok(cpu.xmm[s]),
            }
        };
        // Ce qui sera rangé, une fois les exceptions jugées.
        enum Write {
            Xmm([u64; 2]),
            General(u64),
            Mmx(u64),
            Flags(u64),
        }
        let write = match form {
            Sse::Scalar { op, double } => {
                let format = Format::of(double);
                let source = read(self, if double { 8 } else { 4 })?;
                let destination = self.xmm[d];
                let result = context.arithmetic(
                    op,
                    destination[0] & format.mask(),
                    source[0] & format.mask(),
                    format,
                );
                Write::Xmm([(destination[0] & !format.mask()) | result, destination[1]])
            }
            Sse::Packed { op, double } => {
                let format = Format::of(double);
                let source = lanes(read(self, 16)?, double);
                let destination = lanes(self.xmm[d], double);
                let results: Vec<u64> = destination
                    .iter()
                    .zip(&source)
                    .map(|(a, b)| context.arithmetic(op, *a, *b, format))
                    .collect();
                Write::Xmm(join_lanes(&results, double))
            }
            Sse::CompareScalar { double } => {
                let format = Format::of(double);
                let source = read(self, if double { 8 } else { 4 })?;
                let destination = self.xmm[d];
                let holds = context.predicate(
                    instruction.imm,
                    destination[0] & format.mask(),
                    source[0] & format.mask(),
                    format,
                );
                let mask = if holds { format.mask() } else { 0 };
                Write::Xmm([(destination[0] & !format.mask()) | mask, destination[1]])
            }
            Sse::ComparePacked { double } => {
                let format = Format::of(double);
                let source = lanes(read(self, 16)?, double);
                let destination = lanes(self.xmm[d], double);
                let results: Vec<u64> = destination
                    .iter()
                    .zip(&source)
                    .map(|(a, b)| {
                        if context.predicate(instruction.imm, *a, *b, format) {
                            format.mask()
                        } else {
                            0
                        }
                    })
                    .collect();
                Write::Xmm(join_lanes(&results, double))
            }
            Sse::Order { double, signaling } => {
                let format = Format::of(double);
                let source = read(self, if double { 8 } else { 4 })?;
                let x = unpack(self.xmm[d][0] & format.mask(), format, context.daz);
                let y = unpack(source[0] & format.mask(), format, context.daz);
                let quiet = x.class == Class::Quiet || y.class == Class::Quiet;
                let loud = x.class == Class::Signaling || y.class == Class::Signaling;
                if loud || (signaling && quiet) {
                    context.flags |= IE;
                }
                if !(loud || quiet) && (x.denormal || y.denormal) {
                    context.flags |= DE;
                }
                let set = if loud || quiet {
                    ZF | PF | CF
                } else {
                    match compare(x, y) {
                        std::cmp::Ordering::Less => CF,
                        std::cmp::Ordering::Equal => ZF,
                        std::cmp::Ordering::Greater => 0,
                    }
                };
                Write::Flags(set)
            }
            Sse::Widen => {
                let source = read(self, 4)?;
                let wide = context.convert(source[0] & 0xFFFF_FFFF, SINGLE, DOUBLE);
                Write::Xmm([wide, self.xmm[d][1]])
            }
            Sse::Narrow => {
                let source = read(self, 8)?;
                let narrow = context.convert(source[0], DOUBLE, SINGLE);
                let destination = self.xmm[d];
                Write::Xmm([(destination[0] & !0xFFFF_FFFF) | narrow, destination[1]])
            }
            Sse::PackedWiden => {
                let source = read(self, 8)?;
                Write::Xmm([
                    context.convert(source[0] & 0xFFFF_FFFF, SINGLE, DOUBLE),
                    context.convert(source[0] >> 32, SINGLE, DOUBLE),
                ])
            }
            Sse::PackedNarrow => {
                let source = read(self, 16)?;
                let low = context.convert(source[0], DOUBLE, SINGLE);
                let high = context.convert(source[1], DOUBLE, SINGLE);
                Write::Xmm([low | (high << 32), 0])
            }
            Sse::FromInteger { double } => {
                let wide = instruction.width == Width::Qword;
                let raw = match at {
                    Some(at) => self.sse_read(at, instruction.width)?,
                    None => self.get(instruction.rm, instruction.width, false),
                };
                let value = if wide {
                    raw as i64
                } else {
                    i64::from(raw as u32 as i32)
                };
                let format = Format::of(double);
                let result = context.float_of(value, format);
                let destination = self.xmm[d];
                Write::Xmm([(destination[0] & !format.mask()) | result, destination[1]])
            }
            Sse::ToInteger { double, truncate } => {
                let format = Format::of(double);
                let source = read(self, if double { 8 } else { 4 })?;
                let wide = instruction.width == Width::Qword;
                Write::General(context.integer_of(
                    source[0] & format.mask(),
                    format,
                    wide,
                    truncate,
                ))
            }
            Sse::FromIntegers { double } => {
                let source = read(self, if double { 8 } else { 16 })?;
                let integers = lanes(source, false);
                let format = Format::of(double);
                let count = if double { 2 } else { 4 };
                let results: Vec<u64> = integers[..count]
                    .iter()
                    .map(|raw| context.float_of(i64::from(*raw as u32 as i32), format))
                    .collect();
                Write::Xmm(join_lanes(&results, double))
            }
            Sse::ToIntegers { double, truncate } => {
                let format = Format::of(double);
                let source = lanes(read(self, 16)?, double);
                let mut integers: Vec<u64> = source
                    .iter()
                    .map(|bits| context.integer_of(*bits, format, false, truncate))
                    .collect();
                // Deux doubles donnent deux entiers : le haut s'efface.
                integers.resize(4, 0);
                Write::Xmm(join_lanes(&integers, false))
            }
            Sse::FromMmx { double } => {
                let raw = match at {
                    Some(at) => self.sse_read(at, Width::Qword)?,
                    None => {
                        self.enter_mmx();
                        self.x87[s & 7].0
                    }
                };
                let format = Format::of(double);
                let low = context.float_of(i64::from(raw as u32 as i32), format);
                let high = context.float_of(i64::from((raw >> 32) as u32 as i32), format);
                if double {
                    Write::Xmm([low, high])
                } else {
                    Write::Xmm([low | (high << 32), self.xmm[d][1]])
                }
            }
            Sse::ToMmx { double, truncate } => {
                let format = Format::of(double);
                let source = lanes(read(self, if double { 16 } else { 8 })?, double);
                let low = context.integer_of(source[0], format, false, truncate);
                let high = context.integer_of(source[1], format, false, truncate);
                Write::Mmx(low | (high << 32))
            }
            Sse::Reciprocal { scalar, root } => {
                let source = read(self, if scalar { 4 } else { 16 })?;
                if scalar {
                    let result = context.reciprocal(source[0] & 0xFFFF_FFFF, root);
                    let destination = self.xmm[d];
                    Write::Xmm([(destination[0] & !0xFFFF_FFFF) | result, destination[1]])
                } else {
                    let results: Vec<u64> = lanes(source, false)
                        .iter()
                        .map(|bits| context.reciprocal(*bits, root))
                        .collect();
                    Write::Xmm(join_lanes(&results, false))
                }
            }
        };
        // **Une exception démasquée ne range rien** : les drapeaux, puis #XM.
        self.mxcsr |= context.flags;
        let masks = (self.mxcsr >> 7) & 0x3F;
        if context.flags & !masks != 0 {
            return Err(ExtendedFault::SimdException);
        }
        match write {
            Write::Xmm(value) => self.xmm[d] = value,
            Write::General(value) => {
                self.set(instruction.reg, instruction.width, false, value);
            }
            Write::Mmx(value) => {
                self.enter_mmx();
                self.set_mmx(d & 7, value);
            }
            Write::Flags(set) => {
                let flags = self.flags.read() & !(ZF | PF | CF | OF | SF | AF);
                self.flags.write(flags | set);
            }
        }
        Ok(())
    }

    fn sse_read(&mut self, at: u64, width: Width) -> Result<u64, ExtendedFault> {
        self.read_memory_fast(at, width)
            .map_err(|_| ExtendedFault::Memory)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(op: FloatOp, a: u64, b: u64, double: bool, mxcsr: u32) -> (u64, u32) {
        let mut context = Context::of(mxcsr);
        let result = context.arithmetic(op, a, b, Format::of(double));
        (result, context.flags)
    }

    /// Les cas où l'arithmétique IEEE ne laisse aucun choix, dans les quatre
    /// modes : l'arrondi d'un tiers, la division par zéro, l'invalide, le
    /// débordement refusé, le sous-débordement graduel et FTZ.
    #[test]
    fn the_rounding_modes_and_flags_follow_ieee() {
        let one = 1.0f64.to_bits();
        let three = 3.0f64.to_bits();
        let third = (1.0f64 / 3.0).to_bits();
        assert_eq!(run(FloatOp::Div, one, three, true, 0x1F80), (third, PE));
        // Vers −∞ et vers zéro : le tiers tronqué ; vers +∞ : un rang plus haut.
        assert_eq!(run(FloatOp::Div, one, three, true, 0x3F80).0, third);
        assert_eq!(run(FloatOp::Div, one, three, true, 0x7F80).0, third);
        assert_eq!(run(FloatOp::Div, one, three, true, 0x5F80).0, third + 1);
        // 1/0 : l'infini, ZE ; 0/0 : l'indéfini négatif, IE.
        assert_eq!(
            run(FloatOp::Div, one, 0, true, 0x1F80),
            (0x7FF0_0000_0000_0000, ZE)
        );
        assert_eq!(
            run(FloatOp::Div, 0, 0, true, 0x1F80),
            (0xFFF8_0000_0000_0000, IE)
        );
        // max · 2 : l'infini au plus près, le plus grand fini vers zéro.
        let max = f64::MAX.to_bits();
        let two = 2.0f64.to_bits();
        assert_eq!(
            run(FloatOp::Mul, max, two, true, 0x1F80),
            (0x7FF0_0000_0000_0000, OE | PE)
        );
        assert_eq!(run(FloatOp::Mul, max, two, true, 0x7F80), (max, OE | PE));
        // Le plus petit normal divisé par trois : un dénormal inexact, UE ;
        // sous FTZ, zéro.
        let tiny = f64::MIN_POSITIVE.to_bits();
        let (result, flags) = run(FloatOp::Div, tiny, three, true, 0x1F80);
        assert_eq!(f64::from_bits(result), f64::MIN_POSITIVE / 3.0);
        assert_eq!(flags, UE | PE);
        assert_eq!(run(FloatOp::Div, tiny, three, true, 0x9F80), (0, UE | PE));
        // Un dénormal exact (le plus petit normal divisé par deux) : pas UE.
        let (result, flags) = run(FloatOp::Div, tiny, two, true, 0x1F80);
        assert_eq!(f64::from_bits(result), f64::MIN_POSITIVE / 2.0);
        assert_eq!(flags, 0);
        // DAZ : un dénormal lu vaut zéro, sans DE.
        let denormal = 1u64;
        assert_eq!(run(FloatOp::Add, denormal, 0, true, 0x1F80), (1, DE));
        assert_eq!(run(FloatOp::Add, denormal, 0, true, 0x1FC0), (0, 0));
        // x − x vaut +0, et −0 vers −∞.
        assert_eq!(run(FloatOp::Sub, one, one, true, 0x1F80).0, 0);
        assert_eq!(
            run(FloatOp::Sub, one, one, true, 0x3F80).0,
            0x8000_0000_0000_0000
        );
        // La racine de deux, au plus près et vers zéro.
        let root = 2.0f64.sqrt().to_bits();
        assert_eq!(run(FloatOp::Sqrt, 0, two, true, 0x1F80), (root, PE));
        assert_eq!(
            run(FloatOp::Sqrt, 0, 4.0f64.to_bits(), true, 0x1F80),
            (two, 0)
        );
        // En simple aussi.
        let (result, flags) = run(
            FloatOp::Div,
            1.0f32.to_bits().into(),
            3.0f32.to_bits().into(),
            false,
            0x1F80,
        );
        assert_eq!((result as u32, flags), ((1.0f32 / 3.0).to_bits(), PE));
    }
}
