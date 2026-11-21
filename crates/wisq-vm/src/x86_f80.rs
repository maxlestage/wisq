//! **Le flottant de quatre-vingts bits du x87, en logiciel** — le port de
//! `X86Extended.swift`, `X86ExtendedArithmetic.swift` et
//! `X86ExtendedFunctions.swift`.
//!
//! Rust n'a pas de `f80`, et l'hôte ne doit rien décider : un émulateur dont
//! le résultat dépend de la machine qui l'exécute n'émule rien. Tout est donc
//! calculé sur des entiers, puis arrondi **une fois** (`assemble`). Le bit
//! entier de la mantisse est **explicite** : une mantisse dont le bit de tête
//! est nul alors que l'exposant ne l'est pas est un « non pris en charge »,
//! que le processeur refuse.
//!
//! Le juge est le silicium : `x86-x87-oracle.tsv` (121 formes, 7 260 cas) et
//! `x86-x87-rounding-oracle.tsv` (les quatre modes d'arrondi, là où le
//! résultat ne tient pas), rejoués par `tests/x86_float_oracle.rs`.
//!
//! **Ce qui n'est pas du cœur Swift**, et le dit : la précision réduite du mot
//! de contrôle (les bits 8 et 9, `assemble_to`) ; les valeurs que le
//! processeur refuse (non normalisées, pseudo-NaN, pseudo-infinis : invalides,
//! l'indéfini) et celles qu'il renormalise (un pseudo-dénormal revient à
//! l'exposant 1, `canonical`) ; et les fonctions transcendantes (`sine_cosine`,
//! `arctangent`, `two_to_the_minus_one`…), que le cœur Swift refuse. Elles
//! sont calculées ici sur cent vingt-huit bits (`Big`), par des séries, puis
//! arrondies une fois selon le mode : le résultat est le même sur tout hôte,
//! et à l'unité du dernier rang du silicium — que `tests/x86_float_host.rs`
//! compare, drapeaux compris, sur toutes les classes de l'étendu.

/// **Un registre du x87** : la mantisse, bit entier compris en tête, puis le
/// signe (bit 15) et l'exposant biaisé de 16 383.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct F80 {
    pub significand: u64,
    pub sign_exponent: u16,
}

/// Le biais de l'exposant.
pub const BIAS: i32 = 16383;
/// L'exposant biaisé des infinis et des NaN.
pub const SPECIAL: i32 = 0x7FFF;
const INTEGER: u64 = 1 << 63;

/// Les quatre modes d'arrondi, tels que les bits 10 et 11 du mot de contrôle
/// (ou 13 et 14 de MXCSR) les nomment.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Rounding {
    NearestEven,
    Down,
    Up,
    TowardZero,
}

impl Rounding {
    /// Depuis le champ de deux bits : 0 au plus proche, 1 vers −∞, 2 vers +∞,
    /// 3 vers zéro.
    pub fn from_field(field: u32) -> Self {
        match field & 3 {
            1 => Self::Down,
            2 => Self::Up,
            3 => Self::TowardZero,
            _ => Self::NearestEven,
        }
    }

    /// Depuis le mot de contrôle du x87.
    pub fn from_control(control: u16) -> Self {
        Self::from_field(u32::from(control >> 10))
    }
}

/// **Ce que le calcul a rencontré en chemin.** Les six drapeaux d'exception
/// occupent les bits 0 à 5 du mot d'état du x87, dans l'ordre de MXCSR ; et
/// C1 dit si l'arrondi est monté.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Report {
    pub flags: u16,
    pub rounded_up: bool,
}

pub const INVALID: u16 = 1 << 0;
pub const DENORMAL: u16 = 1 << 1;
pub const ZERO_DIVIDE: u16 = 1 << 2;
pub const OVERFLOW: u16 = 1 << 3;
pub const UNDERFLOW: u16 = 1 << 4;
pub const INEXACT: u16 = 1 << 5;

impl Report {
    pub fn of(flags: u16) -> Self {
        Self {
            flags,
            rounded_up: false,
        }
    }

    fn note(&mut self, bit: u16) {
        self.flags |= bit;
    }
}

/// La comparaison, avec la quatrième réponse : **non ordonné**.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Order {
    Less,
    Equal,
    Greater,
    Unordered,
}

/// **Une mantisse de cent vingt-huit bits** : les soixante-quatre du haut
/// comptent, ceux du bas servent à arrondir.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Wide(u128);

impl Wide {
    fn new(high: u64, low: u64) -> Self {
        Self((u128::from(high) << 64) | u128::from(low))
    }

    fn high(self) -> u64 {
        (self.0 >> 64) as u64
    }

    fn low(self) -> u64 {
        self.0 as u64
    }

    /// Décaler à droite **en gardant** ce qui sort : le bit de poids faible
    /// devient collant. Sans lui, une valeur écartée de justesse serait
    /// arrondie comme une valeur exacte.
    fn shift_right(&mut self, count: i32) {
        if count <= 0 {
            return;
        }
        if count >= 128 {
            self.0 = u128::from(self.0 != 0);
            return;
        }
        let lost = self.0 & ((1u128 << count) - 1) != 0;
        self.0 = (self.0 >> count) | u128::from(lost);
    }
}

impl F80 {
    pub const ZERO: Self = Self {
        significand: 0,
        sign_exponent: 0,
    };
    /// **L'indéfini réel** : le NaN que le processeur fabrique quand
    /// l'opération elle-même est invalide. Il est négatif, comme en SSE.
    pub const INDEFINITE: Self = Self {
        significand: 0xC000_0000_0000_0000,
        sign_exponent: 0xFFFF,
    };
    pub const ONE: Self = Self {
        significand: INTEGER,
        sign_exponent: 0x3FFF,
    };

    pub fn new(significand: u64, sign_exponent: u16) -> Self {
        Self {
            significand,
            sign_exponent,
        }
    }

    pub fn from_pair((significand, sign_exponent): (u64, u16)) -> Self {
        Self::new(significand, sign_exponent)
    }

    pub fn pair(self) -> (u64, u16) {
        (self.significand, self.sign_exponent)
    }

    pub fn infinity(negative: bool) -> Self {
        Self::new(INTEGER, if negative { 0xFFFF } else { 0x7FFF })
    }

    fn signed_zero(negative: bool) -> Self {
        Self::new(0, if negative { 0x8000 } else { 0 })
    }

    pub fn negative(self) -> bool {
        self.sign_exponent & 0x8000 != 0
    }

    pub fn biased(self) -> i32 {
        i32::from(self.sign_exponent & 0x7FFF)
    }

    pub fn negated(self) -> Self {
        Self::new(self.significand, self.sign_exponent ^ 0x8000)
    }

    pub fn absolute(self) -> Self {
        Self::new(self.significand, self.sign_exponent & 0x7FFF)
    }

    pub fn is_zero(self) -> bool {
        self.biased() == 0 && self.significand == 0
    }

    pub fn is_special(self) -> bool {
        self.biased() == SPECIAL
    }

    pub fn is_infinite(self) -> bool {
        self.is_special() && self.significand == INTEGER
    }

    pub fn is_nan(self) -> bool {
        self.is_special() && self.significand & !INTEGER != 0
    }

    /// Un NaN dont le bit 62 est nul **signale** ; le bit 63 est le bit
    /// entier, à un pour tout NaN bien formé.
    pub fn is_signaling_nan(self) -> bool {
        self.is_nan() && self.significand & 0x4000_0000_0000_0000 == 0
    }

    pub fn quieted(self) -> Self {
        Self::new(self.significand | 0x4000_0000_0000_0000, self.sign_exponent)
    }

    /// Bit entier absent alors que l'exposant ne l'est pas : le processeur
    /// refuse ces valeurs comme opérandes.
    pub fn is_unsupported(self) -> bool {
        self.biased() != 0 && self.significand & INTEGER == 0
    }

    /// **La forme que le processeur rend d'un pseudo-dénormal** (exposant nul,
    /// bit entier levé) : la même valeur, à l'exposant 1. Le silicium ne le
    /// rend jamais tel quel — un pseudo-dénormal ajouté à zéro revient
    /// renormalisé, et étiqueté « valide ».
    pub fn canonical(self) -> Self {
        if self.biased() == 0 && self.significand & INTEGER != 0 {
            Self::new(self.significand, self.sign_exponent | 1)
        } else {
            self
        }
    }

    /// Un opérande dénormal se signale, même quand le résultat est exact.
    pub fn is_denormal_operand(self) -> bool {
        !self.is_zero()
            && !self.is_special()
            && (self.biased() == 0 || self.significand & INTEGER == 0)
    }

    /// **Le mot d'étiquettes** à deux bits : 00 valide, 01 zéro, 10
    /// particulier (NaN, infini, dénormal, non pris en charge).
    pub fn tag(self) -> u16 {
        if self.is_zero() {
            0b01
        } else if self.is_special() || self.biased() == 0 || self.significand & INTEGER == 0 {
            0b10
        } else {
            0b00
        }
    }

    /// Les dix octets tels qu'ils vivent en mémoire.
    pub fn to_bytes(self) -> [u8; 10] {
        let mut out = [0u8; 10];
        out[..8].copy_from_slice(&self.significand.to_le_bytes());
        out[8..].copy_from_slice(&self.sign_exponent.to_le_bytes());
        out
    }

    pub fn from_bytes(bytes: [u8; 10]) -> Self {
        Self::new(
            u64::from_le_bytes(bytes[..8].try_into().expect("huit octets")),
            u16::from_le_bytes([bytes[8], bytes[9]]),
        )
    }

    // ---- Les conversions ----

    /// Un entier signé, exact : soixante-quatre bits de mantisse portent
    /// n'importe quel entier de soixante-quatre bits.
    pub fn from_integer(value: i64) -> Self {
        if value == 0 {
            return Self::ZERO;
        }
        let magnitude = value.unsigned_abs();
        let lead = magnitude.leading_zeros() as i32;
        let exponent = (63 - lead + BIAS) as u16;
        Self::new(
            magnitude << lead,
            exponent | if value < 0 { 0x8000 } else { 0 },
        )
    }

    /// **Un flottant IEEE de `fraction_bits` et `exponent_bits`**, exact : le
    /// simple et le double tiennent dans l'étendu. Un dénormal devient un
    /// nombre normal ; un NaN garde sa charge, montée, **et son bit de
    /// silence tel quel** — c'est l'opération qui le lit qui décide.
    pub fn from_ieee(bits: u64, fraction_bits: u32, exponent_bits: u32) -> Self {
        let negative = (bits >> (fraction_bits + exponent_bits)) & 1 != 0;
        let all = (1u64 << exponent_bits) - 1;
        let exponent = (bits >> fraction_bits) & all;
        let fraction = bits & ((1u64 << fraction_bits) - 1);
        let sign = if negative { 0x8000 } else { 0 };
        let format_bias = (1i32 << (exponent_bits - 1)) - 1;
        if exponent == all {
            return Self::new(
                INTEGER | (fraction << (63 - fraction_bits)),
                SPECIAL as u16 | sign,
            );
        }
        if exponent == 0 {
            if fraction == 0 {
                return Self::signed_zero(negative);
            }
            let lead = fraction.leading_zeros() as i32;
            let real = 1 - format_bias - (lead - (63 - fraction_bits as i32)) + BIAS;
            return Self::new(fraction << lead, real as u16 | sign);
        }
        Self::new(
            INTEGER | (fraction << (63 - fraction_bits)),
            (exponent as i32 - format_bias + BIAS) as u16 | sign,
        )
    }

    pub fn from_f64_bits(bits: u64) -> Self {
        Self::from_ieee(bits, 52, 11)
    }

    pub fn from_f32_bits(bits: u32) -> Self {
        Self::from_ieee(u64::from(bits), 23, 8)
    }

    /// **La mantisse et l'exposant vrais, bit de tête posé.** Un dénormal a
    /// l'exposant du plus petit normal ; le calcul se fait sur une forme
    /// normalisée, quitte à ce que l'exposant devienne négatif.
    fn normalized(self) -> (u64, i32) {
        if self.is_zero() || self.is_special() {
            return (self.significand, self.biased());
        }
        let real = if self.biased() == 0 { 1 } else { self.biased() };
        if self.significand & INTEGER != 0 {
            return (self.significand, real);
        }
        let lead = self.significand.leading_zeros() as i32;
        (self.significand << lead, real - lead)
    }

    /// **Rétrécir vers un format IEEE**, avec ce que ça coûte : inexact,
    /// débordement, sous-débordement, invalide pour un NaN signalant.
    pub fn narrowed(
        self,
        fraction_bits: u32,
        exponent_bits: u32,
        rounding: Rounding,
    ) -> (u64, Report) {
        let mut report = Report::default();
        let maximum = (1i32 << (exponent_bits - 1)) - 1;
        let minimum = 2 - (1i32 << (exponent_bits - 1));
        let sign_bit = u64::from(self.negative()) << (fraction_bits + exponent_bits);
        let all_ones = (1u64 << exponent_bits) - 1;
        if self.is_zero() {
            return (sign_bit, report);
        }
        if self.is_unsupported() {
            // L'indéfini du format : négatif, silencieux, sans charge.
            let indefinite = (1u64 << (fraction_bits + exponent_bits))
                | (all_ones << fraction_bits)
                | (1u64 << (fraction_bits - 1));
            return (indefinite, Report::of(INVALID));
        }
        if self.is_special() {
            if self.is_infinite() {
                return (sign_bit | (all_ones << fraction_bits), report);
            }
            if self.is_signaling_nan() {
                report.note(INVALID);
            }
            // La charge descend, et le bit de silence est posé.
            let payload = (self.significand & !INTEGER) >> (63 - fraction_bits);
            let quiet = 1u64 << (fraction_bits - 1);
            return (
                sign_bit | (all_ones << fraction_bits) | quiet | payload,
                report,
            );
        }
        let (significand, real) = self.normalized();
        let mut exponent = real - BIAS;
        let mut value = Wide::new(significand, 0);
        // Aligner : garder un bit de plus que la fraction, l'entier compris.
        value.shift_right(63 - fraction_bits as i32);
        if exponent < minimum {
            value.shift_right((minimum - exponent).min(127));
            exponent = minimum;
            if value.0 == 0 {
                report.note(UNDERFLOW | INEXACT);
                return (sign_bit, report);
            }
        }
        if value.low() != 0 {
            report.note(INEXACT);
        }
        let mut high = value.high();
        if rounds_up(value.low(), high & 1 == 0, self.negative(), rounding) {
            high += 1;
            report.rounded_up = true;
        }
        let implicit = 1u64 << fraction_bits;
        if high >= implicit << 1 {
            high >>= 1;
            exponent += 1;
        }
        if exponent > maximum {
            // **Trois modes sur quatre refusent l'infini** ici aussi, et C1
            // dit alors « vers le bas » : le silicium de l'hôte le montre, le
            // cœur Swift rendait l'infini dans tous les modes.
            report.note(OVERFLOW | INEXACT);
            let negative = self.negative();
            let refuses = rounding == Rounding::TowardZero
                || (rounding == Rounding::Down && !negative)
                || (rounding == Rounding::Up && negative);
            report.rounded_up = !refuses;
            let infinity = sign_bit | (all_ones << fraction_bits);
            return (if refuses { infinity - 1 } else { infinity }, report);
        }
        if high < implicit {
            if report.flags & INEXACT != 0 {
                report.note(UNDERFLOW);
            }
            return (sign_bit | high, report);
        }
        let biased = (exponent - minimum + 1) as u64;
        (
            sign_bit | (biased << fraction_bits) | (high & (implicit - 1)),
            report,
        )
    }

    /// **Vers un entier signé de `bits` bits**, arrondi selon le mode. `None`
    /// quand la valeur ne tient pas : l'appelant range l'entier indéfini.
    pub fn as_integer(self, bits: u32, rounding: Rounding) -> Option<i64> {
        if self.is_zero() {
            return Some(0);
        }
        if self.is_special() || self.is_unsupported() {
            return None;
        }
        let exponent = self.biased() - BIAS;
        if !(exponent >= 0 || rounding != Rounding::TowardZero || exponent >= -1) {
            return Some(0);
        }
        if exponent >= bits as i32 {
            // Le seul débordement acceptable est la borne négative exacte.
            if self.negative() && exponent == bits as i32 - 1 && self.significand == INTEGER {
                return Some(if bits == 64 {
                    i64::MIN
                } else {
                    -(1i64 << (bits - 1))
                });
            }
            return None;
        }
        let (mut whole, rest) = if exponent >= 63 {
            (self.significand, 0)
        } else if exponent >= 0 {
            (
                self.significand >> (63 - exponent),
                self.significand << (exponent + 1),
            )
        } else {
            (0, if exponent == -1 { self.significand } else { 0 })
        };
        // **Un reste sous la demie compte aussi** pour les arrondis dirigés :
        // 0,1 arrondi vers +∞ rend 1. Le cœur Swift rendait zéro, ici comme
        // dans `integral` plus bas, qui s'en garde.
        let rest = if exponent < -1 && self.significand != 0 {
            1
        } else {
            rest
        };
        if rounds_up(rest, whole & 1 == 0, self.negative(), rounding) {
            whole += 1;
        }
        let limit = if bits == 64 {
            INTEGER
        } else {
            1u64 << (bits - 1)
        };
        if self.negative() {
            if whole > limit {
                return None;
            }
            return Some(if whole == limit {
                if bits == 64 {
                    i64::MIN
                } else {
                    -(limit as i64)
                }
            } else {
                -(whole as i64)
            });
        }
        if whole >= limit {
            return None;
        }
        Some(whole as i64)
    }

    /// **`frndint`** : la valeur arrondie à l'entier selon le mode, exacte en
    /// étendu. Un NaN signalant devient silencieux, un « non pris en charge »
    /// devient l'indéfini, l'un et l'autre invalides.
    pub fn integral(self, rounding: Rounding) -> (Self, Report) {
        let mut report = Report::default();
        if self.is_special() || self.is_unsupported() {
            if self.significand & INTEGER == 0 {
                return (Self::INDEFINITE, Report::of(INVALID));
            }
            if self.is_signaling_nan() {
                return (self.quieted(), Report::of(INVALID));
            }
            return (self, report);
        }
        if self.is_zero() {
            return (self, report);
        }
        if self.biased() == 0 {
            report.note(DENORMAL);
        }
        let sign = self.sign_exponent & 0x8000;
        let exponent = self.biased() - BIAS;
        if exponent >= 63 {
            return (self, report);
        }
        let (mut whole, rest) = if exponent >= 0 {
            (
                self.significand >> (63 - exponent),
                self.significand << (exponent + 1),
            )
        } else {
            // Moins d'une demie se résume à un reste petit et non nul.
            (0, if exponent == -1 { self.significand } else { 1 })
        };
        if rest == 0 {
            return (self, report);
        }
        report.note(INEXACT);
        if rounds_up(rest, whole & 1 == 0, self.negative(), rounding) {
            whole += 1;
            report.rounded_up = true;
        }
        if whole == 0 {
            return (Self::new(0, sign), report);
        }
        let shift = whole.leading_zeros() as i32;
        (
            Self::new(whole << shift, sign | (BIAS + 63 - shift) as u16),
            report,
        )
    }
}

/// **Faut-il monter ?** `rest` est ce qui suit le dernier bit gardé, cadré en
/// tête d'un mot : la demie vaut `0x8000…`.
pub fn rounds_up(rest: u64, even: bool, negative: bool, rounding: Rounding) -> bool {
    if rest == 0 {
        return false;
    }
    match rounding {
        Rounding::NearestEven => rest > INTEGER || (rest == INTEGER && !even),
        Rounding::TowardZero => false,
        Rounding::Down => negative,
        Rounding::Up => !negative,
    }
}

/// Les drapeaux rencontrés à l'entrée s'ajoutent à ceux du calcul.
fn merged(outcome: (F80, Report), opening: Report) -> (F80, Report) {
    let (value, mut report) = outcome;
    report.flags |= opening.flags;
    (value, report)
}

/// **Ranger une mantisse de cent vingt-huit bits** dans un étendu : la
/// normaliser, puis l'arrondir une fois, à soixante-quatre bits.
fn assemble(wide: Wide, exponent: i32, negative: bool, rounding: Rounding) -> (F80, Report) {
    assemble_to(wide, exponent, negative, rounding, 64)
}

/// **La même chose à `precision` bits** — 24, 53 ou 64, ce que les bits 8 et
/// 9 du mot de contrôle demandent. L'exposant garde sa plage étendue : la
/// précision réduite ne touche que la mantisse, comme sur le silicium.
fn assemble_to(
    wide: Wide,
    exponent: i32,
    negative: bool,
    rounding: Rounding,
    precision: u32,
) -> (F80, Report) {
    let mut report = Report::default();
    let mut value = wide;
    let mut power = exponent;
    if value.0 == 0 {
        return (F80::signed_zero(negative), report);
    }
    // Normaliser : le bit de tête à la place du bit entier.
    let lead = value.0.leading_zeros() as i32;
    value.0 <<= lead;
    power -= lead;
    // **Sous-débordement graduel : décaler avant d'arrondir.** Deux arrondis
    // successifs ne valent pas un arrondi.
    let subnormal = power <= 0;
    if subnormal {
        value.shift_right(1 - power);
    }
    // Ce qui tombe sous le dernier bit gardé, cadré en tête d'un mot.
    let drop = 64 - precision;
    let (mut high, rest) = if drop == 0 {
        (value.high(), value.low())
    } else {
        let kept = value.high() & !((1u64 << drop) - 1);
        // Les `drop` bits bas du haut et tout le bas, cadrés en tête.
        let below = value.0 << precision;
        let rest = (below >> 64) as u64 | u64::from(below as u64 != 0);
        (kept, rest)
    };
    if rest != 0 {
        report.note(if subnormal {
            UNDERFLOW | INEXACT
        } else {
            INEXACT
        });
    }
    if rounds_up(rest, (high >> drop) & 1 == 0, negative, rounding) {
        report.rounded_up = true;
        let (sum, carry) = high.overflowing_add(1u64 << drop);
        high = sum;
        if carry {
            high = INTEGER;
            power += 1;
        }
    }
    let sign = if negative { 0x8000 } else { 0 };
    if subnormal {
        // L'arrondi peut faire remonter au plus petit normal.
        let exponent = u16::from(high & INTEGER != 0);
        return (F80::new(high, exponent | sign), report);
    }
    if power >= SPECIAL {
        report.note(OVERFLOW | INEXACT);
        report.rounded_up = true;
        // **Trois modes sur quatre refusent l'infini** et rendent le plus
        // grand fini : la troncature toujours, vers −∞ un positif, vers +∞
        // un négatif.
        let refuses = rounding == Rounding::TowardZero
            || (rounding == Rounding::Down && !negative)
            || (rounding == Rounding::Up && negative);
        if refuses {
            // Le plus grand fini est un arrondi **vers le bas** en grandeur :
            // C1 tombe. Le cœur Swift le laissait levé, et son test ne
            // comparait pas le mot d'état ; le corpus le compare ici.
            report.rounded_up = false;
            let largest = !((1u64 << drop) - 1);
            return (F80::new(largest, (SPECIAL - 1) as u16 | sign), report);
        }
        return (F80::infinity(negative), report);
    }
    (F80::new(high, power as u16 | sign), report)
}

/// **Ce que le processeur rend quand un opérande est un NaN.** Entre deux
/// NaN, celui dont la mantisse est la plus grande ; à égalité, la
/// destination. Un NaN signalant est rendu silencieux au passage.
fn nan(left: F80, right: F80) -> Option<F80> {
    if left.is_nan() && right.is_nan() {
        return Some(
            if right.significand > left.significand {
                right
            } else {
                left
            }
            .quieted(),
        );
    }
    if left.is_nan() {
        return Some(left.quieted());
    }
    if right.is_nan() {
        return Some(right.quieted());
    }
    None
}

/// L'ouverture d'une addition ou d'une multiplication : **l'invalidité prime
/// sur le dénormal**, et un NaN silencieux aussi — le silicium de l'hôte ne
/// signale pas le dénormal d'un opérande quand l'autre est un NaN.
fn opening_of(left: F80, right: F80) -> Report {
    if left.is_signaling_nan() || right.is_signaling_nan() {
        Report::of(INVALID)
    } else if left.is_nan() || right.is_nan() {
        Report::default()
    } else if left.is_denormal_operand() || right.is_denormal_operand() {
        Report::of(DENORMAL)
    } else {
        Report::default()
    }
}

/// **Un opérande que le processeur refuse** — non normalisé, pseudo-NaN,
/// pseudo-infini : l'opération est invalide et rend l'indéfini, avant tout
/// NaN de l'autre côté.
fn refused(left: F80, right: F80) -> Option<(F80, Report)> {
    (left.is_unsupported() || right.is_unsupported())
        .then_some((F80::INDEFINITE, Report::of(INVALID)))
}

pub fn add(left: F80, right: F80, rounding: Rounding, precision: u32) -> (F80, Report) {
    if let Some(answer) = refused(left, right) {
        return answer;
    }
    let mut opening = opening_of(left, right);
    if let Some(answer) = nan(left, right) {
        return (answer, opening);
    }
    if left.is_infinite() || right.is_infinite() {
        if !(left.is_infinite() && right.is_infinite()) {
            return (if left.is_infinite() { left } else { right }, opening);
        }
        if left.negative() != right.negative() {
            opening.note(INVALID);
            return (F80::INDEFINITE, opening);
        }
        return (left, opening);
    }
    if left.is_zero() && right.is_zero() {
        let negative = if left.negative() == right.negative() {
            left.negative()
        } else {
            rounding == Rounding::Down
        };
        return (F80::signed_zero(negative), opening);
    }
    // Un zéro ajouté rend l'autre opérande — **arrondi à la précision du mot
    // de contrôle** quand elle est réduite : le silicium de l'hôte le fait.
    if left.is_zero() || right.is_zero() {
        let other = if left.is_zero() { right } else { left };
        if precision == 64 {
            return (other.canonical(), opening);
        }
        let (significand, exponent) = other.normalized();
        return merged(
            assemble_to(
                Wide::new(significand, 0),
                exponent,
                other.negative(),
                rounding,
                precision,
            ),
            opening,
        );
    }
    let (mut high, mut low) = (left, right);
    let (mut bigger, mut smaller) = (left.normalized(), right.normalized());
    if smaller.1 > bigger.1 || (smaller.1 == bigger.1 && smaller.0 > bigger.0) {
        std::mem::swap(&mut high, &mut low);
        std::mem::swap(&mut bigger, &mut smaller);
    }
    let first = Wide::new(bigger.0, 0);
    let mut second = Wide::new(smaller.0, 0);
    second.shift_right(bigger.1 - smaller.1);
    if high.negative() == low.negative() {
        let mut exponent = bigger.1;
        let (sum, carry) = first.0.overflowing_add(second.0);
        let mut sum = Wide(sum);
        if carry {
            sum.shift_right(1);
            sum.0 |= 1u128 << 127;
            exponent += 1;
        }
        return merged(
            assemble_to(sum, exponent, high.negative(), rounding, precision),
            opening,
        );
    }
    // Signes opposés : une soustraction, et le plus grand décide du signe.
    let difference = Wide(first.0.wrapping_sub(second.0));
    // **Deux valeurs égales qui s'annulent rendent un zéro positif**, sauf en
    // arrondi vers le bas.
    if difference.0 == 0 {
        return (F80::signed_zero(rounding == Rounding::Down), opening);
    }
    merged(
        assemble_to(difference, bigger.1, high.negative(), rounding, precision),
        opening,
    )
}

pub fn subtract(left: F80, right: F80, rounding: Rounding, precision: u32) -> (F80, Report) {
    if let Some(answer) = refused(left, right) {
        return answer;
    }
    if let Some(answer) = nan(left, right) {
        let flags = if left.is_signaling_nan() || right.is_signaling_nan() {
            INVALID
        } else {
            0
        };
        return (answer, Report::of(flags));
    }
    add(left, right.negated(), rounding, precision)
}

pub fn multiply(left: F80, right: F80, rounding: Rounding, precision: u32) -> (F80, Report) {
    if let Some(answer) = refused(left, right) {
        return answer;
    }
    let mut opening = opening_of(left, right);
    if let Some(answer) = nan(left, right) {
        return (answer, opening);
    }
    let negative = left.negative() != right.negative();
    if left.is_infinite() || right.is_infinite() {
        if left.is_zero() || right.is_zero() {
            opening.note(INVALID);
            return (F80::INDEFINITE, opening);
        }
        return (F80::infinity(negative), opening);
    }
    if left.is_zero() || right.is_zero() {
        return (F80::signed_zero(negative), opening);
    }
    let (a, ea) = left.normalized();
    let (b, eb) = right.normalized();
    let product = u128::from(a) * u128::from(b);
    merged(
        assemble_to(
            Wide(product),
            ea + eb - BIAS + 1,
            negative,
            rounding,
            precision,
        ),
        opening,
    )
}

pub fn divide(left: F80, right: F80, rounding: Rounding, precision: u32) -> (F80, Report) {
    // **L'ordre des exceptions** : un NaN, puis l'invalide (∞/∞, 0/0) et la
    // division par zéro, qui abandonnent l'opération, puis le dénormal —
    // **même quand l'autre opérande est infini** : le silicium de l'hôte
    // signale le dénormal de `x/∞` et de `∞/x`, ce que le cœur Swift taisait.
    if let Some(answer) = refused(left, right) {
        return answer;
    }
    let mut opening = Report::default();
    if left.is_signaling_nan() || right.is_signaling_nan() {
        opening.note(INVALID);
    }
    if let Some(answer) = nan(left, right) {
        return (answer, opening);
    }
    let negative = left.negative() != right.negative();
    if (left.is_infinite() && right.is_infinite()) || (left.is_zero() && right.is_zero()) {
        opening.note(INVALID);
        return (F80::INDEFINITE, opening);
    }
    if right.is_zero() && !left.is_infinite() {
        opening.note(ZERO_DIVIDE);
        return (F80::infinity(negative), opening);
    }
    if left.is_denormal_operand() || right.is_denormal_operand() {
        opening.note(DENORMAL);
    }
    if left.is_infinite() {
        return (F80::infinity(negative), opening);
    }
    if right.is_infinite() || left.is_zero() {
        return (F80::signed_zero(negative), opening);
    }
    // **Le quotient sort déjà normalisé**, et le reste dit s'il restait moins,
    // autant ou plus que la moitié : un bit collant fabriqué et décalé ensuite
    // entrerait dans la mantisse.
    let (numerator, en) = left.normalized();
    let (denominator, ed) = right.normalized();
    let mut exponent = en - ed + BIAS;
    let dividend = u128::from(numerator) << 63;
    let d = u128::from(denominator);
    let mut quotient = (dividend / d) as u64;
    let mut remainder = dividend % d;
    if quotient & INTEGER == 0 {
        quotient <<= 1;
        remainder <<= 1;
        if remainder >= d {
            quotient |= 1;
            remainder -= d;
        }
        exponent -= 1;
    }
    let half = d - remainder;
    let rest: u64 = if remainder == 0 {
        0
    } else if remainder > half {
        0xC000_0000_0000_0000
    } else if remainder == half {
        0x8000_0000_0000_0000
    } else {
        0x4000_0000_0000_0000
    };
    merged(
        assemble_to(
            Wide::new(quotient, rest),
            exponent,
            negative,
            rounding,
            precision,
        ),
        opening,
    )
}

/// La comparaison ; un NaN, ou un opérande refusé, rend « non ordonné ».
pub fn compare(left: F80, right: F80) -> Order {
    if left.is_nan() || right.is_nan() || left.is_unsupported() || right.is_unsupported() {
        return Order::Unordered;
    }
    if left.is_zero() && right.is_zero() {
        return Order::Equal;
    }
    // Un pseudo-dénormal vaut le normal d'exposant 1 de même mantisse.
    let (left, right) = (left.canonical(), right.canonical());
    if left.negative() != right.negative() {
        return if left.negative() {
            Order::Less
        } else {
            Order::Greater
        };
    }
    let bigger = if left.biased() != right.biased() {
        left.biased() > right.biased()
    } else if left.significand != right.significand {
        left.significand > right.significand
    } else {
        return Order::Equal;
    };
    if bigger != left.negative() {
        Order::Greater
    } else {
        Order::Less
    }
}

/// **`fsqrt`** : la racine d'un nombre positif, arrondie une fois.
pub fn square_root(value: F80, rounding: Rounding, precision: u32) -> (F80, Report) {
    if value.is_unsupported() {
        return (F80::INDEFINITE, Report::of(INVALID));
    }
    if value.is_nan() {
        return if value.is_signaling_nan() {
            (value.quieted(), Report::of(INVALID))
        } else {
            (value, Report::default())
        };
    }
    if value.is_zero() {
        return (value, Report::default());
    }
    if value.negative() {
        return (F80::INDEFINITE, Report::of(INVALID));
    }
    if value.is_infinite() {
        return (value, Report::default());
    }
    let opening = Report::of(if value.biased() == 0 { DENORMAL } else { 0 });
    let (significand, real) = value.normalized();
    // valeur = m · 2^(e − biais − 63) ; la puissance doit être paire.
    let power = real - BIAS - 63;
    let even = power & 1 == 0;
    let number = if even {
        u128::from(significand) << 64
    } else {
        u128::from(significand) << 63
    };
    let (root, remainder) = integer_square_root(number);
    let exponent = BIAS + 63 + (power - if even { 64 } else { 63 }) / 2;
    let rest = if remainder == 0 {
        0
    } else if remainder > u128::from(root) {
        0xC000_0000_0000_0000
    } else {
        0x4000_0000_0000_0000
    };
    merged(
        assemble_to(Wide::new(root, rest), exponent, false, rounding, precision),
        opening,
    )
}

/// La racine entière d'un nombre d'au moins 2¹²⁶ — elle tient sur
/// soixante-quatre bits, bit de tête posé — et le reste `n − r²`. Newton, puis
/// la correction d'une unité.
fn integer_square_root(number: u128) -> (u64, u128) {
    let approximate = (number as f64).sqrt();
    let mut root = if approximate >= 18_446_744_073_709_551_615.0 {
        u64::MAX
    } else {
        approximate as u64
    }
    .max(INTEGER);
    for _ in 0..3 {
        if ((number >> 64) as u64) >= root {
            break;
        }
        let quotient = (number / u128::from(root)) as u64;
        let (sum, carry) = root.overflowing_add(quotient);
        root = if carry {
            (sum >> 1) | INTEGER
        } else {
            sum >> 1
        };
    }
    let square = |value: u64| u128::from(value) * u128::from(value);
    while square(root) > number {
        root -= 1;
    }
    while root < u64::MAX && square(root + 1) <= number {
        root += 1;
    }
    (root, number - square(root))
}

/// Ce que rend `fprem` ou `fprem1` : le reste, les trois bits bas du
/// quotient, et si la réduction est finie.
pub struct Remainder {
    pub value: F80,
    pub quotient: u64,
    pub complete: bool,
    pub report: Report,
}

/// **`fprem` et `fprem1`** : le reste de `ST(0)` par `ST(1)`, exact. `fprem`
/// tronque le quotient, `fprem1` l'arrondit au plus proche. Au-delà de
/// soixante-trois rangs d'écart, le processeur ne fait qu'une partie du
/// chemin et lève C2.
pub fn partial_remainder(dividend: F80, divisor: F80, nearest: bool) -> Remainder {
    let done = |value: F80, report: Report| Remainder {
        value,
        quotient: 0,
        complete: true,
        report,
    };
    let mut opening = Report::default();
    if dividend.is_unsupported() || divisor.is_unsupported() {
        return done(F80::INDEFINITE, Report::of(INVALID));
    }
    if dividend.is_signaling_nan() || divisor.is_signaling_nan() {
        opening.note(INVALID);
    }
    if let Some(answer) = nan(dividend, divisor) {
        return done(answer, opening);
    }
    if dividend.is_infinite() || divisor.is_zero() {
        opening.note(INVALID);
        return done(F80::INDEFINITE, opening);
    }
    if dividend.is_denormal_operand() || divisor.is_denormal_operand() {
        opening.note(DENORMAL);
    }
    if dividend.is_zero() || divisor.is_infinite() {
        return done(dividend.canonical(), opening);
    }
    let (top, top_exponent) = dividend.normalized();
    let (bottom, bottom_exponent) = divisor.normalized();
    let mut difference = top_exponent - bottom_exponent;
    let mut complete = true;
    let mut offset = 0;
    if difference >= 64 {
        complete = false;
        offset = difference - (32 + (difference - 32) % 32);
        difference -= offset;
    }
    let mut quotient: u64;
    let mut magnitude: u64;
    let exponent;
    let mut negative = dividend.negative();
    if difference < 0 {
        if !(nearest && difference == -1 && top > bottom) {
            return Remainder {
                value: dividend.canonical(),
                quotient: 0,
                complete,
                report: opening,
            };
        }
        // |x| entre la moitié de |y| et |y| : le reste est |y| − |x|, de signe
        // opposé, à l'exposant du dividende.
        magnitude = (bottom << 1).wrapping_sub(top);
        exponent = top_exponent;
        negative = !negative;
        quotient = 1;
    } else {
        let shifted = u128::from(top) << difference;
        quotient = (shifted / u128::from(bottom)) as u64;
        magnitude = (shifted % u128::from(bottom)) as u64;
        if nearest && complete && magnitude != 0 {
            let half = bottom - magnitude;
            if magnitude > half || (magnitude == half && quotient & 1 == 1) {
                magnitude = half;
                negative = !negative;
                quotient = quotient.wrapping_add(1);
            }
        }
        exponent = bottom_exponent + offset;
    }
    if !complete {
        quotient = 0;
    }
    let (result, _) = assemble(
        Wide::new(magnitude, 0),
        exponent,
        negative,
        Rounding::NearestEven,
    );
    // Un reste nul garde le signe du dividende.
    let value = if magnitude == 0 {
        F80::signed_zero(dividend.negative())
    } else {
        result
    };
    Remainder {
        value,
        quotient,
        complete,
        report: opening,
    }
}

/// **`fscale`** : `ST(0) · 2^n`, où `n` est `ST(1)` tronqué vers zéro.
pub fn scaled(value: F80, power: F80, rounding: Rounding) -> (F80, Report) {
    let mut opening = Report::default();
    if value.is_unsupported() || power.is_unsupported() {
        return (F80::INDEFINITE, Report::of(INVALID));
    }
    if value.is_signaling_nan() || power.is_signaling_nan() {
        opening.note(INVALID);
    }
    if let Some(answer) = nan(value, power) {
        return (answer, opening);
    }
    if power.is_infinite() {
        // 0 · 2^+∞ et ∞ · 2^−∞ sont invalides.
        if (value.is_zero() && !power.negative()) || (value.is_infinite() && power.negative()) {
            opening.note(INVALID);
            return (F80::INDEFINITE, opening);
        }
        if value.is_zero() || value.is_infinite() {
            return (value, opening);
        }
        if value.is_denormal_operand() {
            opening.note(DENORMAL);
        }
        return (
            if power.negative() {
                F80::signed_zero(value.negative())
            } else {
                F80::infinity(value.negative())
            },
            opening,
        );
    }
    if value.is_denormal_operand() || power.is_denormal_operand() {
        opening.note(DENORMAL);
    }
    if value.is_zero() || value.is_infinite() {
        return (value, opening);
    }
    // Au-delà de ±2¹⁶, le résultat déborde ou s'évanouit de toute façon.
    let whole = power
        .as_integer(64, Rounding::TowardZero)
        .unwrap_or(if power.negative() { -65_536 } else { 65_536 });
    let shift = whole.clamp(-65_536, 65_536) as i32;
    let (significand, exponent) = value.normalized();
    merged(
        assemble(
            Wide::new(significand, 0),
            exponent + shift,
            value.negative(),
            rounding,
        ),
        opening,
    )
}

/// **`fxtract`** : l'exposant vrai, en étendu, et la mantisse ramenée entre
/// 1 et 2, de même signe.
pub fn extracted(value: F80) -> (F80, F80, Report) {
    if value.is_unsupported() {
        return (F80::INDEFINITE, F80::INDEFINITE, Report::of(INVALID));
    }
    if value.is_nan() {
        let quiet = value.quieted();
        let flags = if value.is_signaling_nan() { INVALID } else { 0 };
        return (quiet, quiet, Report::of(flags));
    }
    if value.is_zero() {
        return (F80::infinity(true), value, Report::of(ZERO_DIVIDE));
    }
    if value.is_infinite() {
        return (F80::infinity(false), value, Report::default());
    }
    let (significand, exponent) = value.normalized();
    let report = Report::of(if value.biased() == 0 { DENORMAL } else { 0 });
    (
        F80::from_integer(i64::from(exponent - BIAS)),
        F80::new(
            significand,
            BIAS as u16 | if value.negative() { 0x8000 } else { 0 },
        ),
        report,
    )
}

/// **Les constantes du x87**, arrondies juste depuis leur valeur vraie, selon
/// le mode. Chacune est gardée en soixante-quatre bits, deux bits de garde,
/// et un bit collant toujours levé : aucune ne s'arrête au soixante-sixième.
pub fn constant(modrm: u8, rounding: Rounding) -> Option<(F80, Report)> {
    let (significand, guard, sign_exponent) = match modrm {
        0xE9 => (0xD49A_784B_CD1B_8AFE, 1, 0x4000),
        0xEA => (0xB8AA_3B29_5C17_F0BB, 2, 0x3FFF),
        0xEB => (0xC90F_DAA2_2168_C234, 3, 0x4000),
        0xEC => (0x9A20_9A84_FBCF_F798, 2, 0x3FFD),
        0xED => (0xB172_17F7_D1CF_79AB, 3, 0x3FFE),
        _ => return None,
    };
    let mut report = Report::default();
    let mut value = significand;
    if rounds_up((guard << 62) | 1, value & 1 == 0, false, rounding) {
        value += 1;
        report.rounded_up = true;
    }
    Some((F80::new(value, sign_exponent), report))
}

// ---- Les fonctions transcendantes ----
//
// Le cœur Swift ne les a pas ; la `libm` de musl les appelle pour ses
// `long double` (`expl`, `logl`, `atan2l`, `log1pl`…). Elles sont calculées
// ici **sur cent vingt-huit bits** (`Big`), par des séries, sur des entiers :
// le résultat ne dépend pas de l'hôte. Il est arrondi **une fois**, selon le
// mode du mot de contrôle, ce qui donne le dépassement par le bas, l'inexact
// et C1 comme le reste du x87. Juste à 2⁻¹²⁰ près avant l'arrondi, il ne
// s'écarte du résultat correctement arrondi qu'au voisinage d'une demie —
// et le silicium, lui, ne promet que l'unité du dernier rang.
//
// **Là où le silicium ne calcule pas, il est suivi tel qu'on le voit sur
// l'hôte** : `fsin`, `fcos` et `fptan` d'un argument sous 2⁻⁶⁸ rendent
// l'argument (ou 1) sans l'arrondir ; `fpatan` d'un quotient sous 2⁻⁴⁰ rend
// le quotient arrondi ; `f2xm1` hors de [−1, 1] et `fyl2xp1` sous −1 rendent
// leur argument. Un résultat non nul lève toujours l'inexact, même exact
// (`fyl2x` de 8 et 1 rend 3, inexact).

/// **Un nombre de travail** : cent vingt-huit bits de mantisse, bit de tête
/// posé (ou zéro), un exposant sans borne et un signe. Sa valeur est
/// `m · 2^(e − 127)`. Chaque opération tronque à cent vingt-huit bits ; un
/// dénormal de l'étendu y est un nombre comme un autre.
#[derive(Clone, Copy, Debug)]
struct Big {
    m: u128,
    e: i32,
    negative: bool,
}

/// ln 2 et π/2 sur cent vingt-huit bits, et les soixante-quatre suivants de
/// π/2 pour réduire un grand argument.
const LN2: Big = Big {
    m: 0xB172_17F7_D1CF_79AB_C9E3_B398_03F2_F6AF,
    e: -1,
    negative: false,
};
const HALF_PI: Big = Big {
    m: 0xC90F_DAA2_2168_C234_C4C6_628B_80DC_1CD1,
    e: 0,
    negative: false,
};
/// Ce que π/2 a sous ses soixante-quatre premiers bits, sur cent vingt-huit.
const HALF_PI_TAIL: Big = Big {
    m: 0xC4C6_628B_80DC_1CD1_2902_4E08_8A67_CC74,
    e: -64,
    negative: false,
};
/// La partie haute de π/2 en étendu : `fprem1` en retire un multiple exact.
const HALF_PI_HIGH: F80 = F80 {
    significand: 0xC90F_DAA2_2168_C234,
    sign_exponent: 0x3FFF,
};

impl Big {
    const ZERO: Self = Self {
        m: 0,
        e: 0,
        negative: false,
    };

    fn new(m: u128, e: i32, negative: bool) -> Self {
        if m == 0 {
            return Self::ZERO;
        }
        let lead = m.leading_zeros() as i32;
        Self {
            m: m << lead,
            e: e - lead,
            negative,
        }
    }

    /// Un étendu fini, exact : un dénormal y est normalisé.
    fn of(x: F80) -> Self {
        if x.is_zero() {
            return Self::ZERO;
        }
        let (significand, real) = x.normalized();
        Self::new(u128::from(significand) << 64, real - BIAS, x.negative())
    }

    fn integer(value: i64) -> Self {
        Self::new(u128::from(value.unsigned_abs()), 127, value < 0)
    }

    fn negated(self) -> Self {
        Self {
            negative: !self.negative,
            ..self
        }
    }

    fn absolute(self) -> Self {
        Self {
            negative: false,
            ..self
        }
    }

    fn half(self) -> Self {
        Self {
            e: self.e - 1,
            ..self
        }
    }

    fn twice(self) -> Self {
        Self {
            e: self.e + 1,
            ..self
        }
    }

    /// La grandeur dépasse-t-elle celle de `other` ?
    fn exceeds(self, other: Self) -> bool {
        if self.m == 0 || other.m == 0 {
            return self.m != 0;
        }
        (self.e, self.m) > (other.e, other.m)
    }

    fn times(self, other: Self) -> Self {
        if self.m == 0 || other.m == 0 {
            return Self::ZERO;
        }
        let (a1, a0) = ((self.m >> 64) as u64, self.m as u64);
        let (b1, b0) = ((other.m >> 64) as u64, other.m as u64);
        let wide = |a: u64, b: u64| u128::from(a) * u128::from(b);
        let (middle, first) = wide(a1, b0).overflowing_add(wide(a0, b1));
        let (middle, second) = middle.overflowing_add(wide(a0, b0) >> 64);
        let carries = (u128::from(first) + u128::from(second)) << 64;
        let high = wide(a1, b1) + (middle >> 64) + carries;
        Self::new(high, self.e + other.e + 1, self.negative != other.negative)
    }

    fn plus(self, other: Self) -> Self {
        if self.m == 0 {
            return other;
        }
        if other.m == 0 {
            return self;
        }
        let (big, small) = if other.exceeds(self) {
            (other, self)
        } else {
            (self, other)
        };
        let shift = big.e - small.e;
        let aligned = if shift >= 128 { 0 } else { small.m >> shift };
        if big.negative == small.negative {
            let (sum, carry) = big.m.overflowing_add(aligned);
            if carry {
                return Self::new((sum >> 1) | (1 << 127), big.e + 1, big.negative);
            }
            return Self::new(sum, big.e, big.negative);
        }
        Self::new(big.m - aligned, big.e, big.negative)
    }

    fn minus(self, other: Self) -> Self {
        self.plus(other.negated())
    }

    /// La division, bit à bit : cent vingt-huit bits de quotient.
    fn over(self, other: Self) -> Self {
        if self.m == 0 {
            return Self::ZERO;
        }
        let divisor = other.m;
        let (mut rest, mut quotient, mut carry) = (self.m, 0u128, false);
        for _ in 0..128 {
            quotient <<= 1;
            if carry || rest >= divisor {
                rest = rest.wrapping_sub(divisor);
                quotient |= 1;
            }
            carry = rest >> 127 != 0;
            rest <<= 1;
        }
        Self::new(quotient, self.e - other.e, self.negative != other.negative)
    }

    /// La racine d'un nombre positif proche de un : celle de l'étendu, puis
    /// deux pas de Newton.
    fn square_root(self) -> Self {
        let (seed, _) = square_root(
            self.rounded(Rounding::NearestEven, Side::Exact).0,
            Rounding::NearestEven,
            64,
        );
        let mut root = Self::of(seed);
        for _ in 0..2 {
            root = root.plus(self.over(root)).half();
        }
        root
    }

    /// **L'arrondi, une fois**, selon le mode. La valeur vraie n'est pas la
    /// troncature : `m` porte un bit collant. Quand les soixante-quatre bits
    /// bas sont nuls, le calcul est tombé sur un étendu — juste, ou parce que
    /// la correction est passée sous les cent vingt-huit bits (le sinus d'un
    /// argument sous 2⁻⁶², x − x³/6) : `side` dit alors de quel côté est la
    /// valeur vraie.
    fn rounded(self, rounding: Rounding, side: Side) -> (F80, Report) {
        if self.m == 0 {
            return (F80::signed_zero(self.negative), Report::default());
        }
        let m = match side {
            _ if self.m as u64 != 0 => self.m | 1,
            Side::Exact => self.m,
            Side::Below => self.m - 1,
            Side::Above => self.m | 1,
        };
        assemble(Wide(m), self.e + BIAS, self.negative, rounding)
    }
}

/// De quel côté d'un résultat tombé juste est la valeur vraie, en grandeur.
#[derive(Clone, Copy)]
enum Side {
    Exact,
    Below,
    Above,
}

/// Un résultat non nul des fonctions transcendantes : arrondi selon le mode,
/// inexact toujours, et les drapeaux de l'ouverture.
fn transcendental(value: Big, rounding: Rounding, opening: Report) -> (F80, Report) {
    toward(value, rounding, opening, Side::Exact)
}

/// La même chose, la valeur vraie d'un résultat tombé juste étant du côté
/// `side`.
fn toward(value: Big, rounding: Rounding, opening: Report, side: Side) -> (F80, Report) {
    let (result, report) = value.rounded(rounding, side);
    inexact(result, report, opening)
}

/// **Inexact, donc un dénormal est un dépassement par le bas** — même tombé
/// juste : le silicium lève UE avec PE.
fn inexact(result: F80, mut report: Report, opening: Report) -> (F80, Report) {
    report.flags |= opening.flags | INEXACT;
    if result.biased() == 0 && result.significand != 0 {
        report.flags |= UNDERFLOW;
    }
    (result, report)
}

/// Le dénormal d'un opérande, ou de l'un des deux.
fn denormal_of(values: &[F80]) -> Report {
    Report::of(if values.iter().any(|value| value.is_denormal_operand()) {
        DENORMAL
    } else {
        0
    })
}

/// Ce qu'une fonction rend d'un NaN : le plus grand des deux, silencieux,
/// invalide s'il signalait.
fn nan_answer(left: F80, right: F80) -> Option<(F80, Report)> {
    let answer = nan(left, right)?;
    let flags = if left.is_signaling_nan() || right.is_signaling_nan() {
        INVALID
    } else {
        0
    };
    Some((answer, Report::of(flags)))
}

fn indefinite() -> (F80, Report) {
    (F80::INDEFINITE, Report::of(INVALID))
}

/// `atanh(s) · 2 = ln((1 + s) / (1 − s))`, |s| petit.
fn twice_atanh(s: Big) -> Big {
    let square = s.times(s);
    // s + s³/3 + s⁵/5… : le terme k est s^(2k+1) / (2k+1).
    let mut power = s;
    let mut sum = s;
    for index in 1..400 {
        power = power.times(square);
        let term = power.over(Big::integer(2 * index + 1));
        if term.m == 0 || term.e < sum.e - 130 {
            break;
        }
        sum = sum.plus(term);
    }
    sum.twice()
}

/// log₂ d'un nombre positif : l'exposant, plus log₂ de la mantisse ramenée
/// entre √½ et √2, où s = (m − 1)/(m + 1) reste sous 0,172. **Exact pour une
/// puissance de deux.**
fn log2(value: Big) -> Big {
    let mut exponent = value.e;
    let mut mantissa = Big { e: 0, ..value }.absolute();
    if value.m > 0xB504_F333_F9DE_6484_597D_89B3_754A_BE9F {
        mantissa = mantissa.half();
        exponent += 1;
    }
    let one = Big::integer(1);
    let s = mantissa.minus(one).over(mantissa.plus(one));
    Big::integer(i64::from(exponent)).plus(twice_atanh(s).over(LN2))
}

/// log₂(1 + x) : sous 0,29 en grandeur, `2 atanh(x / (2 + x)) / ln 2`, sans
/// perdre x ; au-delà, log₂ de la somme.
fn log2_one_plus(x: F80) -> Big {
    let x = Big::of(x);
    if x.e < -2 {
        let s = x.over(Big::integer(2).plus(x));
        return twice_atanh(s).over(LN2);
    }
    log2(Big::integer(1).plus(x))
}

/// e^t − 1, |t| sous un : la série de Taylor, sans le un.
fn exp_minus_one(t: Big) -> Big {
    let mut term = t;
    let mut sum = t;
    for index in 2..200 {
        term = term.times(t).over(Big::integer(index));
        if term.m == 0 || term.e < sum.e - 130 {
            break;
        }
        sum = sum.plus(term);
    }
    sum
}

/// atan(z), |z| ≤ 1 : deux réductions `atan z = 2 atan(z / (1 + √(1 + z²)))`,
/// puis la série alternée.
fn arctangent_small(z: Big) -> Big {
    let one = Big::integer(1);
    let mut z = z;
    for _ in 0..2 {
        let root = one.plus(z.times(z)).square_root();
        z = z.over(one.plus(root));
    }
    let square = z.times(z);
    let mut power = z;
    let mut sum = z;
    for index in 1..400 {
        power = power.times(square);
        let term = power.over(Big::integer(2 * index + 1));
        if term.m == 0 || term.e < sum.e - 130 {
            break;
        }
        sum = if index % 2 == 1 {
            sum.minus(term)
        } else {
            sum.plus(term)
        };
    }
    // Deux réductions : quatre fois l'angle réduit.
    sum.twice().twice()
}

/// **`fpatan`** : atan2(y, x), le quadrant compris. `ST(1)` est y, `ST(0)`
/// est x.
pub fn arctangent(y: F80, x: F80, rounding: Rounding) -> (F80, Report) {
    if let Some(answer) = refused(y, x) {
        return answer;
    }
    if let Some(answer) = nan_answer(y, x) {
        return answer;
    }
    let opening = denormal_of(&[y, x]);
    let pi = HALF_PI.twice();
    let signed = |value: Big| if y.negative() { value.negated() } else { value };
    // Les angles exacts : ±0 devant un x positif (ou +0, ou +∞).
    let exact_zero =
        (y.is_zero() && !x.negative()) || (!y.is_infinite() && x.is_infinite() && !x.negative());
    if exact_zero {
        return (F80::signed_zero(y.negative()), opening);
    }
    let angle = if y.is_zero() || (!y.is_infinite() && x.is_infinite()) {
        // ±π : y nul devant un x négatif, ou y fini devant −∞.
        pi
    } else if y.is_infinite() && x.is_infinite() {
        let quarter = HALF_PI.half();
        if x.negative() {
            quarter.times(Big::integer(3))
        } else {
            quarter
        }
    } else if y.is_infinite() || x.is_zero() {
        HALF_PI
    } else {
        let (ay, ax) = (Big::of(y).absolute(), Big::of(x).absolute());
        let quotient = ay.over(ax);
        if !x.negative() && quotient.e < -40 {
            // Le silicium rend le quotient, arrondi, sans le corriger.
            let (result, report) = divide(y, x, rounding, 64);
            return inexact(result, report, Report::default());
        }
        let angle = if ax.exceeds(ay) || (ax.e, ax.m) == (ay.e, ay.m) {
            arctangent_small(quotient)
        } else {
            HALF_PI.minus(arctangent_small(ax.over(ay)))
        };
        if x.negative() {
            pi.minus(angle)
        } else {
            angle
        }
    };
    transcendental(signed(angle), rounding, opening)
}

/// **`f2xm1`** : 2^x − 1, pour |x| ≤ 1. Hors de ce domaine, le manuel ne
/// promet rien, et le silicium de l'hôte rend x, inexact.
pub fn two_to_the_minus_one(x: F80, rounding: Rounding) -> (F80, Report) {
    if x.is_unsupported() {
        return indefinite();
    }
    if let Some(answer) = nan_answer(x, x) {
        return answer;
    }
    if x.is_infinite() {
        return (
            if x.negative() { F80::ONE.negated() } else { x },
            Report::default(),
        );
    }
    if x.is_zero() {
        return (x, Report::default());
    }
    match compare(x.absolute(), F80::ONE) {
        Order::Greater => return (x, Report::of(INEXACT)),
        // 2¹ − 1 = 1 et 2⁻¹ − 1 = −½, exacts, et pourtant inexacts.
        Order::Equal if x.negative() => return (F80::new(INTEGER, 0xBFFE), Report::of(INEXACT)),
        Order::Equal => return (F80::ONE, Report::of(INEXACT)),
        _ => {}
    }
    let t = Big::of(x).times(LN2);
    transcendental(exp_minus_one(t), rounding, denormal_of(&[x]))
}

/// **`fyl2x`** : y · log₂ x. `ST(1)` est y, `ST(0)` est x.
pub fn y_log2_x(y: F80, x: F80, rounding: Rounding) -> (F80, Report) {
    if let Some(answer) = refused(y, x) {
        return answer;
    }
    if let Some(answer) = nan_answer(y, x) {
        return answer;
    }
    if x.negative() && !x.is_zero() {
        return indefinite();
    }
    if x.is_zero() {
        // log₂ 0 = −∞ : y · −∞, invalide si y est nul. La division par zéro
        // prime sur le dénormal de y.
        if y.is_zero() {
            return indefinite();
        }
        let flags = if y.is_infinite() { 0 } else { ZERO_DIVIDE };
        return (F80::infinity(!y.negative()), Report::of(flags));
    }
    let opening = denormal_of(&[y, x]);
    if x.is_infinite() {
        if y.is_zero() {
            return indefinite();
        }
        return (F80::infinity(y.negative()), opening);
    }
    let logarithm = log2(Big::of(x));
    if y.is_infinite() {
        if logarithm.m == 0 {
            return indefinite();
        }
        return (F80::infinity(y.negative() != logarithm.negative), opening);
    }
    if y.is_zero() || logarithm.m == 0 {
        let negative = y.negative() != (logarithm.negative && logarithm.m != 0);
        return (F80::signed_zero(negative), opening);
    }
    transcendental(Big::of(y).times(logarithm), rounding, opening)
}

/// **`fyl2xp1`** : y · log₂(1 + x), pour |x| sous 1 − √2/2. Au-delà, le
/// silicium calcule encore, sauf à −1 et en dessous, où il rend x tel quel
/// (et l'indéfini pour −∞).
pub fn y_log2_one_plus_x(y: F80, x: F80, rounding: Rounding) -> (F80, Report) {
    if let Some(answer) = refused(y, x) {
        return answer;
    }
    if let Some(answer) = nan_answer(y, x) {
        return answer;
    }
    if x.is_infinite() && x.negative() {
        return indefinite();
    }
    let opening = denormal_of(&[y, x]);
    if x.is_infinite() {
        if y.is_zero() {
            return indefinite();
        }
        return (F80::infinity(y.negative()), opening);
    }
    if y.is_infinite() {
        if x.is_zero() {
            return indefinite();
        }
        return (F80::infinity(y.negative() != x.negative()), opening);
    }
    if y.is_zero() || x.is_zero() {
        return (F80::signed_zero(y.negative() != x.negative()), opening);
    }
    if x.negative() && compare(x, F80::ONE.negated()) != Order::Greater {
        return (x, Report::of(opening.flags | INEXACT));
    }
    transcendental(Big::of(y).times(log2_one_plus(x)), rounding, opening)
}

/// **L'argument réduit modulo π/2** : `x − k·π/2` et `k mod 4`. La partie
/// haute de π/2 est retirée exactement (`partial_remainder` fait le calcul
/// de `fprem1`), puis k fois les cent vingt-huit bits suivants.
fn reduced(x: F80) -> (Big, u64) {
    if !Big::of(x).absolute().exceeds(HALF_PI.half()) {
        return (Big::of(x), 0);
    }
    let remainder = partial_remainder(x, HALF_PI_HIGH, true).value;
    // Le quotient entier, signé comme x : (x − r) / (π/2), juste à la demie
    // près, s'arrondit à lui.
    let (difference, _) = subtract(x, remainder, Rounding::NearestEven, 64);
    let (quotient, _) = divide(difference, HALF_PI_HIGH, Rounding::NearestEven, 64);
    let k = quotient.as_integer(64, Rounding::NearestEven).unwrap_or(0);
    let r = Big::of(remainder).minus(Big::integer(k).times(HALF_PI_TAIL));
    (r, k as u64 & 3)
}

/// sin et cos d'un argument réduit, |r| ≤ π/4.
fn sine_and_cosine_small(r: Big) -> (Big, Big) {
    let square = r.times(r);
    let mut sine = r;
    let mut cosine = Big::integer(1);
    let mut term = r;
    for index in 1..200 {
        term = term
            .times(square)
            .over(Big::integer(i64::from((2 * index) * (2 * index + 1))));
        if term.m == 0 || term.e < sine.e - 130 {
            break;
        }
        sine = if index % 2 == 1 {
            sine.minus(term)
        } else {
            sine.plus(term)
        };
    }
    let mut term = Big::integer(1);
    for index in 1..200 {
        term = term
            .times(square)
            .over(Big::integer(i64::from((2 * index - 1) * (2 * index))));
        if term.m == 0 || term.e < -130 {
            break;
        }
        cosine = if index % 2 == 1 {
            cosine.minus(term)
        } else {
            cosine.plus(term)
        };
    }
    (sine, cosine)
}

/// Ce que rendent `fsin`, `fcos`, `fsincos` et `fptan` : chaque valeur avec
/// son compte rendu.
pub struct Trigonometric {
    pub sine: (F80, Report),
    pub cosine: (F80, Report),
    pub tangent: (F80, Report),
}

/// **`fsin`, `fcos`, `fsincos`, `fptan`** : `None` quand |x| ≥ 2⁶³ — le
/// processeur lève C2 et laisse l'opérande tel quel.
pub fn sine_cosine(x: F80, rounding: Rounding) -> Option<Trigonometric> {
    let all = |value: (F80, Report)| Trigonometric {
        sine: value,
        cosine: value,
        tangent: value,
    };
    if x.is_unsupported() || x.is_infinite() {
        return Some(all(indefinite()));
    }
    if let Some(answer) = nan_answer(x, x) {
        return Some(all(answer));
    }
    if x.biased() - BIAS >= 63 {
        return None;
    }
    if x.is_zero() {
        return Some(Trigonometric {
            sine: (x, Report::default()),
            cosine: (F80::ONE, Report::default()),
            tangent: (x, Report::default()),
        });
    }
    let opening = denormal_of(&[x]);
    let x = x.canonical();
    if x.biased() <= 0x3FBA {
        // **Sous 2⁻⁶⁸, le silicium rend l'argument**, et 1 pour le cosinus,
        // inexacts mais non arrondis : C1 reste à zéro, et le mode n'y fait
        // rien. Un dénormal rendu tel quel est un dépassement par le bas.
        let tiny = if x.biased() == 0 { UNDERFLOW } else { 0 };
        let flags = opening.flags | INEXACT;
        return Some(Trigonometric {
            sine: (x, Report::of(flags | tiny)),
            cosine: (F80::ONE, Report::of(flags)),
            tangent: (x, Report::of(flags | tiny)),
        });
    }
    let (r, quarter) = reduced(x);
    let (s, c) = sine_and_cosine_small(r);
    let (sine, cosine) = match quarter {
        0 => (s, c),
        1 => (c, s.negated()),
        2 => (s.negated(), c.negated()),
        _ => (c.negated(), s),
    };
    // Tombés juste, |sin x| est sous |x|, cos x sous 1, |tan x| au-dessus
    // de |x| : la correction est passée sous les cent vingt-huit bits.
    Some(Trigonometric {
        sine: toward(sine, rounding, opening, Side::Below),
        cosine: toward(cosine, rounding, opening, Side::Below),
        tangent: toward(sine.over(cosine), rounding, opening, Side::Above),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn value(x: f64) -> F80 {
        F80::from_f64_bits(x.to_bits())
    }

    fn sine_and_cosine(x: F80) -> (F80, F80) {
        let outcome = sine_cosine(x, Rounding::NearestEven).expect("dans le domaine");
        (outcome.sine.0, outcome.cosine.0)
    }

    fn back(x: F80) -> f64 {
        f64::from_bits(x.narrowed(52, 11, Rounding::NearestEven).0)
    }

    /// Les fonctions transcendantes, contre les valeurs connues à seize
    /// chiffres : la série doit au moins rendre le double juste.
    #[test]
    fn the_transcendental_functions_give_the_known_values() {
        let close = |got: f64, want: f64| (got - want).abs() <= want.abs() * 4e-16 + 1e-300;
        let (s, c) = sine_and_cosine(value(1.0));
        assert!(close(back(s), 0.841_470_984_807_896_5), "{}", back(s));
        assert!(close(back(c), 0.540_302_305_868_139_8), "{}", back(c));
        let (s, c) = sine_and_cosine(value(10.0));
        assert!(close(back(s), -0.544_021_110_889_369_8), "{}", back(s));
        assert!(close(back(c), -0.839_071_529_076_452_4), "{}", back(c));
        let (a, _) = arctangent(value(1.0), value(1.0), Rounding::NearestEven);
        assert!(close(back(a), std::f64::consts::FRAC_PI_4));
        let (a, _) = arctangent(value(1.0), value(-1.0), Rounding::NearestEven);
        assert!(close(back(a), 3.0 * std::f64::consts::FRAC_PI_4));
        let (a, _) = arctangent(value(-2.0), value(0.5), Rounding::NearestEven);
        assert!(close(back(a), (-2.0f64).atan2(0.5)), "{}", back(a));
        let (e, _) = two_to_the_minus_one(value(0.5), Rounding::NearestEven);
        assert!(
            close(back(e), std::f64::consts::SQRT_2 - 1.0),
            "{}",
            back(e)
        );
        let (e, _) = two_to_the_minus_one(value(-1.0), Rounding::NearestEven);
        assert!(close(back(e), -0.5));
        let (l, _) = y_log2_x(value(3.0), value(10.0), Rounding::NearestEven);
        assert!(
            close(back(l), 3.0 * std::f64::consts::LOG2_10),
            "{}",
            back(l)
        );
        let (l, _) = y_log2_one_plus_x(value(1.0), value(0.25), Rounding::NearestEven);
        assert!(close(back(l), 1.25f64.log2()), "{}", back(l));
        // Exact là où il doit l'être : log₂ 8 = 3, 2^1 − 1 = 1.
        assert_eq!(
            back(y_log2_x(value(1.0), value(8.0), Rounding::NearestEven).0),
            3.0
        );
        assert_eq!(
            back(two_to_the_minus_one(value(1.0), Rounding::NearestEven).0),
            1.0
        );
        // Au-delà de 2⁶³ : C2, l'opérande intact.
        assert!(sine_cosine(value(1e19), Rounding::NearestEven).is_none());
        // **Un grand argument** : la réduction par π/2 retire k · π/2 sur cent
        // vingt-huit bits. La partie basse de π/2 y compte : sans elle, sin
        // 10⁶ se tromperait de 3 · 10⁻¹⁴, sin 10¹⁰ de 10⁻¹⁰.
        for (x, sine, cosine) in [
            (1e6, -0.349_993_502_171_292_94, 0.936_752_127_533_144_7),
            (1e10, -0.487_506_025_087_510_7, 0.873_119_622_676_856),
            (
                123_456.789,
                -0.998_664_082_343_224_6,
                0.051_672_532_718_701_38,
            ),
        ] {
            let (s, c) = sine_and_cosine(value(x));
            assert!(close(back(s), sine), "sin {x} : {}", back(s));
            assert!(close(back(c), cosine), "cos {x} : {}", back(c));
        }
    }
}
