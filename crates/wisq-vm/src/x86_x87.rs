//! **La pile du x87** — le port de `X86X87.swift`, `X86X87Dispatch.swift` et
//! de ce que `X86FloatingPointState.swift` dit de `fnstenv` et `fldenv`.
//!
//! `D8` à `DF` se lisent de deux façons selon le ModRM. Quand il désigne la
//! mémoire, le champ `reg` choisit l'opération et l'opcode donne la largeur ;
//! quand il vaut `11`, l'octet entier nomme une instruction, et le bas du
//! ModRM désigne un registre de la pile. **Ce n'est pas un banc de registres,
//! c'est une pile** : `ST(0)` est le sommet, chaque chargement le fait
//! descendre, chaque rangement qui dépile le fait monter.
//!
//! Le juge est `x86-x87-oracle.tsv` (121 formes, 7 260 cas) et
//! `x86-x87-rounding-oracle.tsv`, rejoués par `tests/x86_float_oracle.rs`.
//!
//! **Là où le cœur Swift se tait, le manuel décide**, et le test le dit :
//!
//! - *Lire un registre vide* est un débordement par le bas, quelle que soit
//!   l'instruction : invalide et faute de pile levés, C1 à zéro, et — masquée,
//!   ce qu'elle est après `fninit` — l'indéfini à la place de la valeur. Le
//!   cœur Swift ne le faisait que pour `fxch` et quelques fonctions.
//! - *Empiler sur un registre occupé* déborde par le haut (`x87_push`).
//! - *C1 tombe* sur tout chargement, `fchs`, `fabs`, `fxch`, `fst` entre
//!   registres ; il ne dit « monté » qu'après un arrondi.
//! - *`fucomp` dépile*, ce que le cœur Swift oubliait.
//! - *Un réel lu en mémoire* (`fld m32`, `fadd m64`…) signale son dénormal et
//!   son NaN signalant, et `fld` range ce dernier rendu silencieux.
//! - *La précision du mot de contrôle* (bits 8 et 9) arrondit `fadd`, `fsub`,
//!   `fmul`, `fdiv` et `fsqrt` à 24 ou 53 bits.
//! - *`fnsave`, `frstor`, `fbld`, `fbstp`, `fdecstp`, `fincstp`, `fnop`* et les
//!   fonctions transcendantes, que le cœur Swift n'a pas.
//!
//! **Ce qui n'est pas modélisé** : une exception **démasquée** pose son
//! drapeau, et ES et B la résument, mais ni `#MF` ni la réponse démasquée
//! (le résultat laissé en place) ne suivent ; les pointeurs de la dernière
//! instruction (FIP, FDP, FOP) sont rangés à zéro.

use super::f80::{self, Order, Report, Rounding, F80};
use super::{Extended, ExtendedFault};
use crate::x86::{Cpu, Width, AF, CF, OF, PF, SF, ZF};
use crate::x86_paging::Access;

const INVALID: u16 = 1 << 0;
const STACK_FAULT: u16 = 1 << 6;
const C0: u16 = 1 << 8;
const C1: u16 = 1 << 9;
const C2: u16 = 1 << 10;
const C3: u16 = 1 << 14;
const CONDITIONS: u16 = C0 | C1 | C2 | C3;

/// **La forme est-elle une instruction ?** Les octets de registre que le
/// manuel ne nomme pas (les alias non documentés de `fcom`, `fstp`, `fxch`)
/// et les champs mémoire réservés restent illisibles.
pub(super) fn valid(opcode: u8, modrm: u8) -> bool {
    let field = (modrm >> 3) & 7;
    if modrm < 0xC0 {
        return match opcode {
            0xD9 => field != 1,
            0xDB => !matches!(field, 4 | 6),
            0xDD => field != 5,
            _ => true,
        };
    }
    match opcode {
        0xD8 => true,
        0xD9 => {
            matches!(modrm, 0xC0..=0xCF | 0xD0 | 0xE0 | 0xE1 | 0xE4 | 0xE5 | 0xE8..=0xEE | 0xF0..=0xFF)
        }
        0xDA => matches!(modrm, 0xC0..=0xDF | 0xE9),
        0xDB => matches!(modrm, 0xC0..=0xDF | 0xE0..=0xE4 | 0xE8..=0xF7),
        0xDC => !matches!(modrm, 0xD0..=0xDF),
        0xDD => matches!(modrm, 0xC0..=0xC7 | 0xD0..=0xEF),
        0xDE => !matches!(modrm, 0xD0..=0xD8 | 0xDA..=0xDF),
        0xDF => matches!(modrm, 0xC0..=0xC7 | 0xE0 | 0xE8..=0xF7),
        _ => false,
    }
}

impl Cpu {
    /// Le sommet de la pile du x87 : les bits 11 à 13 du mot d'état.
    pub fn x87_top(&self) -> usize {
        usize::from((self.fpu_status >> 11) & 7)
    }

    fn x87_set_top(&mut self, top: usize) {
        self.fpu_status = (self.fpu_status & !(7 << 11)) | (((top & 7) as u16) << 11);
    }

    /// Un entier signé, en registre du x87. Exact.
    pub fn x87_from_integer(value: i64) -> (u64, u16) {
        F80::from_integer(value).pair()
    }

    /// **Empiler une valeur.** Le sommet descend d'un cran ; si le registre
    /// qu'il désigne alors est occupé, c'est un débordement de pile : le mot
    /// d'état le dit (invalide, faute de pile, C1), et — l'exception masquée —
    /// la valeur empilée est le NaN indéfini.
    pub fn x87_push(&mut self, value: (u64, u16)) {
        let top = (self.x87_top() + 7) & 7;
        self.x87_set_top(top);
        if self.fpu_tags & (1 << top) != 0 {
            self.fpu_status |= INVALID | STACK_FAULT | C1;
            self.x87[top] = F80::INDEFINITE.pair();
            self.x87_summarise();
            return;
        }
        self.fpu_status &= !C1;
        self.x87[top] = value;
        self.fpu_tags |= 1 << top;
    }

    /// Les bits « résumé d'erreur » et « occupé » suivent les exceptions en
    /// attente que le mot de contrôle ne masque pas.
    pub(super) fn x87_summarise(&mut self) {
        if self.fpu_status & !self.fpu_control & 0x3f != 0 {
            self.fpu_status |= 0x8080;
        } else {
            self.fpu_status &= !0x8080;
        }
    }

    /// **Le mot d'étiquettes complet**, deux bits par registre physique : il
    /// se recalcule des registres, le processeur ne garde que « occupé ».
    pub fn x87_tag_word(&self) -> u16 {
        (0..8).fold(0u16, |word, index| {
            let tag = if self.fpu_tags & (1 << index) == 0 {
                0b11
            } else {
                F80::from_pair(self.x87[index]).tag()
            };
            word | tag << (2 * index)
        })
    }

    fn st(&self, index: usize) -> F80 {
        F80::from_pair(self.x87[(self.x87_top() + index) & 7])
    }

    fn st_empty(&self, index: usize) -> bool {
        self.fpu_tags & (1 << ((self.x87_top() + index) & 7)) == 0
    }

    fn set_st(&mut self, index: usize, value: F80) {
        let physical = (self.x87_top() + index) & 7;
        self.x87[physical] = value.pair();
        self.fpu_tags |= 1 << physical;
    }

    fn x87_pop(&mut self) {
        let top = self.x87_top();
        self.fpu_tags &= !(1 << top);
        self.x87_set_top(top + 1);
    }

    /// **Le débordement par le bas** : invalide, faute de pile, C1 à zéro.
    fn underflow(&mut self) {
        self.fpu_status = (self.fpu_status | INVALID | STACK_FAULT) & !C1;
    }

    /// `ST(i)`, ou `None` après avoir signalé qu'il est vide.
    fn operand(&mut self, index: usize) -> Option<F80> {
        if self.st_empty(index) {
            self.underflow();
            return None;
        }
        Some(self.st(index))
    }

    /// **Ce que le calcul a rencontré s'écrit dans le mot d'état** : les
    /// drapeaux s'accumulent, et C1 dit si l'arrondi est monté.
    fn x87_note(&mut self, report: Report) {
        self.fpu_status |= report.flags;
        if report.rounded_up {
            self.fpu_status |= C1;
        } else {
            self.fpu_status &= !C1;
        }
    }

    fn rounding(&self) -> Rounding {
        Rounding::from_control(self.fpu_control)
    }

    /// La précision des quatre opérations et de la racine : 24, 53 ou 64 bits.
    fn precision(&self) -> u32 {
        match (self.fpu_control >> 8) & 3 {
            0 => 24,
            2 => 53,
            _ => 64,
        }
    }

    /// C3, C2 et C0 d'une comparaison ; C1 tombe.
    fn set_condition(&mut self, order: Order) {
        self.fpu_status &= !CONDITIONS;
        self.fpu_status |= match order {
            Order::Greater => 0,
            Order::Less => C0,
            Order::Equal => C3,
            Order::Unordered => C3 | C2 | C0,
        };
    }

    /// **`fcom` et `fucom` ne diffèrent que sur un point** : la forme
    /// ordinaire signale une opération invalide devant n'importe quel NaN, la
    /// « non ordonnée » devant un NaN signalant seulement. Sinon, un dénormal
    /// se signale.
    fn note_comparison(&mut self, left: F80, right: F80, quiet_is_invalid: bool) {
        let signaling = left.is_signaling_nan() || right.is_signaling_nan();
        if signaling || (quiet_is_invalid && (left.is_nan() || right.is_nan())) {
            self.fpu_status |= INVALID;
            return;
        }
        if left.is_denormal_operand() || right.is_denormal_operand() {
            self.fpu_status |= f80::DENORMAL;
        }
    }

    /// La même comparaison dans ZF, PF et CF (`fcomi`) ; OF, SF et AF tombent.
    fn set_comparison_flags(&mut self, order: Order) {
        self.fpu_status &= !C1;
        let set = match order {
            Order::Greater => 0,
            Order::Less => CF,
            Order::Equal => ZF,
            Order::Unordered => ZF | PF | CF,
        };
        let flags = self.flags.read() & !(ZF | PF | CF | OF | SF | AF);
        self.flags.write(flags | set);
    }

    /// Une comparaison de `ST(0)` à `right` : `None` pour un registre vide.
    fn compare_top(&mut self, right: Option<F80>, quiet_is_invalid: bool, flags: bool) {
        let left = self.operand(0);
        let order = match (left, right) {
            (Some(left), Some(right)) => {
                self.note_comparison(left, right, quiet_is_invalid);
                f80::compare(left, right)
            }
            // Un registre vide : `operand` a signalé le débordement.
            _ => Order::Unordered,
        };
        if flags {
            self.set_comparison_flags(order);
        } else {
            self.set_condition(order);
        }
    }

    /// L'une des six opérations d'un champ `reg` : `0` add, `1` mul, `4` sub,
    /// `5` subr, `6` div, `7` divr.
    fn combine(&self, field: u8, left: F80, right: F80) -> (F80, Report) {
        let (rounding, precision) = (self.rounding(), self.precision());
        match field {
            0 => f80::add(left, right, rounding, precision),
            1 => f80::multiply(left, right, rounding, precision),
            4 => f80::subtract(left, right, rounding, precision),
            5 => f80::subtract(right, left, rounding, precision),
            6 => f80::divide(left, right, rounding, precision),
            _ => f80::divide(right, left, rounding, precision),
        }
    }

    /// `ST(dst) = ST(dst) op ST(src)`, puis dépiler si demandé. Un registre
    /// vide : l'indéfini dans la destination.
    fn arithmetic_on_stack(&mut self, field: u8, destination: usize, source: usize, popping: bool) {
        let (left, right) = (self.operand(destination), self.operand(source));
        let result = match (left, right) {
            (Some(left), Some(right)) => {
                let (result, report) = self.combine(field, left, right);
                self.x87_note(report);
                result
            }
            _ => F80::INDEFINITE,
        };
        self.set_st(destination, result);
        if popping {
            self.x87_pop();
        }
    }

    /// Une fonction d'un argument sur `ST(0)` : `frndint`, `fsqrt`…
    fn on_top(&mut self, function: impl FnOnce(&Self, F80) -> (F80, Report)) {
        let result = match self.operand(0) {
            Some(value) => {
                let (result, report) = function(self, value);
                self.x87_note(report);
                result
            }
            None => F80::INDEFINITE,
        };
        self.set_st(0, result);
    }

    /// L'entier que rend un rangement, ou l'entier indéfini quand la valeur
    /// ne tient pas. **Ce qui coûte, c'est la partie fractionnaire** : 2,5
    /// arrondi au pair rend 2, la troncature — et pourtant une demie s'est
    /// perdue.
    fn x87_integer(&mut self, value: Option<F80>, bits: u32, rounding: Rounding) -> u64 {
        let indefinite = 1u64 << (bits - 1);
        let Some(value) = value else {
            return indefinite;
        };
        let Some(whole) = value.as_integer(bits, rounding) else {
            self.x87_note(Report::of(INVALID));
            return indefinite;
        };
        let (_, rounded) = value.integral(rounding);
        self.x87_note(Report {
            flags: rounded.flags & f80::INEXACT,
            rounded_up: rounded.rounded_up,
        });
        whole as u64 & width_of(bits).mask()
    }

    /// Ce que `fxam` dit de `ST(0)` : C3, C2 et C0 nomment la classe, C1 le
    /// signe. Un registre vide se dit à part, quoi qu'il contienne.
    fn examined(&self) -> u16 {
        let value = self.st(0);
        let sign = if value.negative() { C1 } else { 0 };
        if self.st_empty(0) {
            return C3 | C0 | sign;
        }
        let integer = value.significand >> 63 != 0;
        if value.is_special() {
            if !integer {
                return sign;
            }
            return if value.is_infinite() { C2 | C0 } else { C0 } | sign;
        }
        if value.biased() == 0 {
            return if value.significand == 0 { C3 } else { C3 | C2 } | sign;
        }
        if integer {
            C2 | sign
        } else {
            sign
        }
    }

    /// **Un réel lu en mémoire**, simple ou double : la valeur exacte, et ce
    /// que la lecture signale — un dénormal de son format, un NaN signalant.
    fn x87_read_real(&mut self, at: u64, double: bool) -> Result<(F80, Report), ExtendedFault> {
        let (fraction, exponent, width) = if double {
            (52, 11, Width::Qword)
        } else {
            (23, 8, Width::Dword)
        };
        let bits = self.x87_read(at, width)?;
        let value = F80::from_ieee(bits, fraction, exponent);
        let biased = (bits >> fraction) & ((1 << exponent) - 1);
        let mut report = Report::default();
        if value.is_signaling_nan() {
            report.flags |= INVALID;
        } else if biased == 0 && bits & ((1 << fraction) - 1) != 0 {
            report.flags |= f80::DENORMAL;
        }
        Ok((value, report))
    }

    fn x87_read(&mut self, at: u64, width: Width) -> Result<u64, ExtendedFault> {
        self.read_memory(at, width)
            .map_err(|_| ExtendedFault::Memory)
    }

    fn x87_write(&mut self, at: u64, width: Width, value: u64) -> Result<(), ExtendedFault> {
        self.write_memory(at, width, value)
            .map_err(|_| ExtendedFault::Memory)
    }

    /// Une aire de `size` octets doit s'écrire **en entier** : son premier
    /// octet, et le premier de la page suivante quand elle déborde, sont
    /// traduits avant qu'un octet ne soit posé. C'est ce dernier qu'une faute
    /// nomme (CR2), comme pour un accès ordinaire à cheval.
    fn x87_probe(&mut self, at: u64, size: u64, access: Access) -> Result<(), ExtendedFault> {
        let last = at.wrapping_add(size - 1);
        self.probe_memory(at, access)
            .map_err(|_| ExtendedFault::Memory)?;
        if last >> 12 != at >> 12 {
            self.probe_memory(last & !0xFFF, access)
                .map_err(|_| ExtendedFault::Memory)?;
        }
        Ok(())
    }

    fn x87_read_ten(&mut self, at: u64) -> Result<F80, ExtendedFault> {
        let low = self.x87_read(at, Width::Qword)?;
        let high = self.x87_read(at.wrapping_add(8), Width::Word)?;
        Ok(F80::new(low, high as u16))
    }

    fn x87_write_ten(&mut self, at: u64, value: F80) -> Result<(), ExtendedFault> {
        self.x87_probe(at, 10, Access::Write)?;
        self.x87_write(at, Width::Qword, value.significand)?;
        self.x87_write(
            at.wrapping_add(8),
            Width::Word,
            u64::from(value.sign_exponent),
        )
    }

    /// **Exécuter une instruction du x87.** `at` est l'adresse de l'opérande
    /// mémoire, s'il y en a un. Une instruction qui faute n'a rien changé :
    /// chaque lecture et chaque sonde d'écriture précèdent le premier
    /// changement d'état.
    pub(super) fn execute_x87(
        &mut self,
        instruction: &Extended,
        at: Option<u64>,
    ) -> Result<(), ExtendedFault> {
        let super::Extra::X87 { opcode, modrm } = instruction.op else {
            unreachable!("execute_x87 ne reçoit que le x87")
        };
        match at {
            None => self.x87_register_form(opcode, modrm),
            Some(at) => {
                let short = instruction.width == Width::Word;
                self.x87_memory_form(opcode, (modrm >> 3) & 7, at, short)?;
            }
        }
        self.x87_summarise();
        Ok(())
    }

    /// La forme registre : l'octet entier nomme l'instruction.
    fn x87_register_form(&mut self, opcode: u8, modrm: u8) {
        let field = (modrm >> 3) & 7;
        let index = usize::from(modrm & 7);
        let rounding = self.rounding();
        match (opcode, modrm) {
            (0xD9, 0xC0..=0xC7) => {
                // fld ST(i) : la valeur lue avant que le sommet ne bouge.
                let value = self.operand(index).unwrap_or(F80::INDEFINITE);
                self.x87_push(value.pair());
            }
            (0xD9, 0xC8..=0xCF) => {
                // fxch : un registre vide prend l'indéfini.
                let top = self.operand(0).unwrap_or(F80::INDEFINITE);
                let other = self.operand(index).unwrap_or(F80::INDEFINITE);
                self.set_st(0, other);
                self.set_st(index, top);
                self.fpu_status &= !C1;
            }
            (0xD9, 0xD0) => {}
            (0xD9, 0xE0) => {
                self.on_top(|_, value| (value.negated(), Report::default()));
            }
            (0xD9, 0xE1) => {
                self.on_top(|_, value| (value.absolute(), Report::default()));
            }
            (0xD9, 0xE4) => self.compare_top(Some(F80::ZERO), true, false),
            (0xD9, 0xE5) => {
                self.fpu_status = (self.fpu_status & !CONDITIONS) | self.examined();
            }
            (0xD9, 0xE8) => self.x87_push(F80::ONE.pair()),
            (0xD9, 0xEE) => self.x87_push(F80::ZERO.pair()),
            (0xD9, 0xE9..=0xED) => {
                let (value, _) = f80::constant(modrm, rounding).expect("une constante");
                self.x87_push(value.pair());
            }
            (0xD9, 0xF0) => self.on_top(|_, value| f80::two_to_the_minus_one(value)),
            (0xD9, 0xF1) | (0xD9, 0xF9) => {
                // fyl2x, fyl2xp1 : ST(1) = ST(1) · log₂(ST(0) [+ 1]), dépiler.
                let (x, y) = (self.operand(0), self.operand(1));
                let result = match (x, y) {
                    (Some(x), Some(y)) => {
                        let (result, report) = f80::y_log2_x(y, x, modrm == 0xF9);
                        self.x87_note(report);
                        result
                    }
                    _ => F80::INDEFINITE,
                };
                self.set_st(1, result);
                self.x87_pop();
            }
            (0xD9, 0xF2) | (0xD9, 0xFB) => self.sine_cosine(modrm),
            (0xD9, 0xF3) => {
                // fpatan : ST(1) = atan2(ST(1), ST(0)), dépiler.
                let (x, y) = (self.operand(0), self.operand(1));
                let result = match (x, y) {
                    (Some(x), Some(y)) => {
                        let (result, report) = f80::arctangent(y, x);
                        self.x87_note(report);
                        result
                    }
                    _ => F80::INDEFINITE,
                };
                self.set_st(1, result);
                self.x87_pop();
            }
            (0xD9, 0xF4) => {
                // fxtract : l'exposant reste, la mantisse s'empile.
                let (exponent, significand) = match self.operand(0) {
                    Some(value) => {
                        let (exponent, significand, report) = f80::extracted(value);
                        self.x87_note(report);
                        (exponent, significand)
                    }
                    None => (F80::INDEFINITE, F80::INDEFINITE),
                };
                self.set_st(0, exponent);
                self.x87_push(significand.pair());
            }
            (0xD9, 0xF5) | (0xD9, 0xF8) => {
                // fprem1, fprem : C2 dit « pas fini » ; C0, C3 et C1 portent
                // Q2, Q1 et Q0.
                let (x, y) = (self.operand(0), self.operand(1));
                let outcome = match (x, y) {
                    (Some(x), Some(y)) => f80::partial_remainder(x, y, modrm == 0xF5),
                    _ => f80::Remainder {
                        value: F80::INDEFINITE,
                        quotient: 0,
                        complete: true,
                        report: Report::default(),
                    },
                };
                self.set_st(0, outcome.value);
                self.fpu_status |= outcome.report.flags;
                let q = outcome.quotient;
                self.fpu_status &= !CONDITIONS;
                if !outcome.complete {
                    self.fpu_status |= C2;
                }
                if q & 4 != 0 {
                    self.fpu_status |= C0;
                }
                if q & 2 != 0 {
                    self.fpu_status |= C3;
                }
                if q & 1 != 0 {
                    self.fpu_status |= C1;
                }
            }
            (0xD9, 0xF6) => {
                self.x87_set_top(self.x87_top() + 7);
                self.fpu_status &= !C1;
            }
            (0xD9, 0xF7) => {
                self.x87_set_top(self.x87_top() + 1);
                self.fpu_status &= !C1;
            }
            (0xD9, 0xFA) => {
                self.on_top(|cpu, value| f80::square_root(value, cpu.rounding(), cpu.precision()))
            }
            (0xD9, 0xFC) => self.on_top(|cpu, value| value.integral(cpu.rounding())),
            (0xD9, 0xFD) => {
                let (x, y) = (self.operand(0), self.operand(1));
                let result = match (x, y) {
                    (Some(x), Some(y)) => {
                        let (result, report) = f80::scaled(x, y, rounding);
                        self.x87_note(report);
                        result
                    }
                    _ => F80::INDEFINITE,
                };
                self.set_st(0, result);
            }
            (0xD9, 0xFE) | (0xD9, 0xFF) => self.sine_cosine(modrm),
            // Les copies conditionnelles : `DA` sur CF, ZF, CF ou ZF, et PF ;
            // `DB` sur leurs négations. La pile ne bouge pas.
            (0xDA | 0xDB, 0xC0..=0xDF) => {
                let flags = self.flags.read();
                let holds = match field {
                    0 => flags & CF != 0,
                    1 => flags & ZF != 0,
                    2 => flags & (CF | ZF) != 0,
                    _ => flags & PF != 0,
                };
                if holds != (opcode == 0xDB) {
                    let value = self.operand(index).unwrap_or(F80::INDEFINITE);
                    self.set_st(0, value);
                }
            }
            (0xDA, 0xE9) | (0xDE, 0xD9) => {
                // fucompp, fcompp.
                let right = self.operand(1);
                self.compare_top(right, opcode == 0xDE, false);
                self.x87_pop();
                self.x87_pop();
            }
            (0xDB, 0xE0 | 0xE1 | 0xE4) => {}
            (0xDB, 0xE2) => self.fpu_status &= 0x7F00,
            (0xDB, 0xE3) => {
                self.fpu_control = 0x037F;
                self.fpu_status = 0;
                self.fpu_tags = 0;
            }
            (0xDB | 0xDF, 0xE8..=0xF7) => {
                // fucomi, fcomi (et leurs formes qui dépilent).
                let right = self.operand(index);
                self.compare_top(right, field == 6, true);
                if opcode == 0xDF {
                    self.x87_pop();
                }
            }
            (0xDD, 0xC0..=0xC7) => {
                let physical = (self.x87_top() + index) & 7;
                self.fpu_tags &= !(1 << physical);
            }
            (0xDF, 0xC0..=0xC7) => {
                let physical = (self.x87_top() + index) & 7;
                self.fpu_tags &= !(1 << physical);
                self.x87_pop();
            }
            (0xDD, 0xD0..=0xDF) => {
                // fst, fstp ST(i).
                let value = self.operand(0).unwrap_or(F80::INDEFINITE);
                self.fpu_status &= !C1;
                self.set_st(index, value);
                if field == 3 {
                    self.x87_pop();
                }
            }
            (0xD8, 0xD0..=0xDF) | (0xDD, 0xE0..=0xEF) => {
                // fcom, fcomp ; fucom, fucomp.
                let right = self.operand(index);
                self.compare_top(right, opcode == 0xD8, false);
                if field == 3 || field == 5 {
                    self.x87_pop();
                }
            }
            (0xDF, 0xE0) => {
                self.set(0, Width::Word, false, u64::from(self.fpu_status));
            }
            // L'arithmétique sur la pile. `D8` écrit dans ST(0), `DC` dans
            // ST(i), `DE` dans ST(i) puis dépile — et `DC`, `DE` **échangent**
            // la soustraction et la division avec leurs formes renversées.
            (0xD8, _) => self.arithmetic_on_stack(field, 0, index, false),
            (0xDC, _) => self.arithmetic_on_stack(reversed(field), index, 0, false),
            (0xDE, _) => self.arithmetic_on_stack(reversed(field), index, 0, true),
            _ => unreachable!("valid() a refusé cette forme"),
        }
    }

    /// `fsin`, `fcos`, `fsincos`, `fptan`. Au-delà de 2⁶³, C2 levé et
    /// l'opérande laissé tel quel.
    fn sine_cosine(&mut self, modrm: u8) {
        let Some(x) = self.operand(0) else {
            self.set_st(0, F80::INDEFINITE);
            if matches!(modrm, 0xF2 | 0xFB) {
                self.x87_push(F80::INDEFINITE.pair());
            }
            return;
        };
        let Some((sine, cosine, report)) = f80::sine_cosine(x) else {
            self.fpu_status = (self.fpu_status | C2) & !C1;
            return;
        };
        self.fpu_status &= !C2;
        self.x87_note(report);
        match modrm {
            0xFE => self.set_st(0, sine),
            0xFF => self.set_st(0, cosine),
            0xFB => {
                self.set_st(0, sine);
                self.x87_push(cosine.pair());
            }
            _ => {
                let tangent = if x.is_nan() || x.is_infinite() {
                    sine
                } else {
                    f80::tangent(sine, cosine)
                };
                self.set_st(0, tangent);
                self.x87_push(F80::ONE.pair());
            }
        }
    }

    /// La forme mémoire : le champ `reg` choisit, l'opcode donne la largeur.
    fn x87_memory_form(
        &mut self,
        opcode: u8,
        field: u8,
        at: u64,
        short: bool,
    ) -> Result<(), ExtendedFault> {
        let rounding = self.rounding();
        match (opcode, field) {
            (0xD9, 0) | (0xDD, 0) => {
                let (value, report) = self.x87_read_real(at, opcode == 0xDD)?;
                self.fpu_status |= report.flags;
                let value = if value.is_signaling_nan() {
                    value.quieted()
                } else {
                    value
                };
                self.x87_push(value.pair());
            }
            (0xDB, 5) => {
                let value = self.x87_read_ten(at)?;
                self.x87_push(value.pair());
            }
            (0xDF, 0) | (0xDB, 0) | (0xDF, 5) => {
                let width = match (opcode, field) {
                    (0xDF, 0) => Width::Word,
                    (0xDB, 0) => Width::Dword,
                    _ => Width::Qword,
                };
                let raw = self.x87_read(at, width)?;
                let shift = 64 - width.bits() as u32;
                let value = ((raw << shift) as i64) >> shift;
                self.x87_push(F80::from_integer(value).pair());
            }
            (0xD9, 2 | 3) | (0xDD, 2 | 3) => {
                let double = opcode == 0xDD;
                let width = if double { Width::Qword } else { Width::Dword };
                self.x87_probe(at, width as u64, Access::Write)?;
                let bits = match self.operand(0) {
                    Some(value) => {
                        let (bits, report) = if double {
                            value.narrowed(52, 11, rounding)
                        } else {
                            value.narrowed(23, 8, rounding)
                        };
                        self.x87_note(report);
                        bits
                    }
                    None if double => 0xFFF8_0000_0000_0000,
                    None => 0xFFC0_0000,
                };
                self.x87_write(at, width, bits)?;
                if field == 3 {
                    self.x87_pop();
                }
            }
            (0xDB, 7) => {
                let value = self.operand(0).unwrap_or(F80::INDEFINITE);
                self.x87_write_ten(at, value)?;
                self.fpu_status &= !C1;
                self.x87_pop();
            }
            (0xDF, 1 | 2 | 3 | 7) | (0xDB, 1..=3) | (0xDD, 1) => {
                // fist, fistp, fisttp : la troncature pour ce dernier, quel
                // que soit le mode.
                let bits = match (opcode, field) {
                    (0xDF, 7) | (0xDD, 1) => 64,
                    (0xDB, _) => 32,
                    _ => 16,
                };
                let width = width_of(bits);
                self.x87_probe(at, width as u64, Access::Write)?;
                let mode = if field == 1 {
                    Rounding::TowardZero
                } else {
                    rounding
                };
                let value = self.operand(0);
                let whole = self.x87_integer(value, bits, mode);
                self.x87_write(at, width, whole)?;
                if field != 2 {
                    self.x87_pop();
                }
            }
            (0xDF, 4) => {
                let value = self.x87_read_bcd(at)?;
                self.x87_push(value.pair());
            }
            (0xDF, 6) => {
                self.x87_probe(at, 10, Access::Write)?;
                let value = self.operand(0);
                let bcd = self.x87_to_bcd(value, rounding);
                self.x87_write(at, Width::Qword, bcd as u64)?;
                self.x87_write(at.wrapping_add(8), Width::Word, (bcd >> 64) as u64)?;
                self.x87_pop();
            }
            // **L'arithmétique avec un opérande en mémoire** : un simple
            // (`D8`), un double (`DC`), un entier de trente-deux bits (`DA`)
            // ou de seize (`DE`). `/2` et `/3` comparent, `/3` dépile.
            (0xD8 | 0xDA | 0xDC | 0xDE, _) => {
                let (value, opening) = match opcode {
                    0xD8 => self.x87_read_real(at, false)?,
                    0xDC => self.x87_read_real(at, true)?,
                    0xDA => {
                        let raw = self.x87_read(at, Width::Dword)?;
                        (
                            F80::from_integer(i64::from(raw as u32 as i32)),
                            Report::default(),
                        )
                    }
                    _ => {
                        let raw = self.x87_read(at, Width::Word)?;
                        (
                            F80::from_integer(i64::from(raw as u16 as i16)),
                            Report::default(),
                        )
                    }
                };
                if field == 2 || field == 3 {
                    // Le NaN signalant lu en mémoire passe par la comparaison,
                    // qui le signale elle-même ; le dénormal aussi.
                    self.fpu_status |= opening.flags & f80::DENORMAL;
                    self.compare_top(Some(value), true, false);
                    if field == 3 {
                        self.x87_pop();
                    }
                } else {
                    let result = match self.operand(0) {
                        Some(top) => {
                            let (result, mut report) = self.combine(field, top, value);
                            if report.flags & INVALID == 0 {
                                report.flags |= opening.flags & f80::DENORMAL;
                            }
                            self.x87_note(report);
                            result
                        }
                        None => F80::INDEFINITE,
                    };
                    self.set_st(0, result);
                }
            }
            (0xD9, 4) => self.x87_load_environment(at, short)?,
            (0xD9, 6) => {
                self.x87_store_environment(at, short)?;
                self.fpu_control |= 0x3F;
            }
            (0xD9, 5) => {
                self.fpu_control = self.x87_read(at, Width::Word)? as u16;
            }
            (0xD9, 7) => {
                self.x87_write(at, Width::Word, u64::from(self.fpu_control))?;
            }
            (0xDD, 7) => {
                self.x87_write(at, Width::Word, u64::from(self.fpu_status))?;
            }
            (0xDD, 4) => {
                // frstor : l'environnement, puis les huit registres dans
                // l'ordre de la pile. Tout est lu avant que rien ne change.
                let size = if short { 14 } else { 28 };
                self.x87_probe(at, size + 80, Access::Read)?;
                let mut registers = [F80::ZERO; 8];
                for (index, register) in registers.iter_mut().enumerate() {
                    *register = self.x87_read_ten(at.wrapping_add(size + 10 * index as u64))?;
                }
                self.x87_load_environment(at, short)?;
                let top = self.x87_top();
                for (index, register) in registers.iter().enumerate() {
                    self.x87[(top + index) & 7] = register.pair();
                }
            }
            (0xDD, 6) => {
                // fnsave : l'environnement, les huit registres, puis fninit.
                let size = if short { 14 } else { 28 };
                self.x87_probe(at, size + 80, Access::Write)?;
                self.x87_store_environment(at, short)?;
                for index in 0..8 {
                    let value = self.st(index);
                    self.x87_write_ten(at.wrapping_add(size + 10 * index as u64), value)?;
                }
                self.fpu_control = 0x037F;
                self.fpu_status = 0;
                self.fpu_tags = 0;
            }
            _ => unreachable!("valid() a refusé cette forme"),
        }
        Ok(())
    }

    /// **`fnstenv`** : le mot de contrôle, le mot d'état et le mot
    /// d'étiquettes complet, puis les pointeurs de la dernière instruction,
    /// que ce cœur ne suit pas. Vingt-huit octets, ou quatorze sous `66`.
    fn x87_store_environment(&mut self, at: u64, short: bool) -> Result<(), ExtendedFault> {
        let words: [u64; 7] = if short {
            [
                u64::from(self.fpu_control),
                u64::from(self.fpu_status),
                u64::from(self.x87_tag_word()),
                0,
                0,
                0,
                0,
            ]
        } else {
            [
                u64::from(self.fpu_control) | 0xFFFF_0000,
                u64::from(self.fpu_status) | 0xFFFF_0000,
                u64::from(self.x87_tag_word()) | 0xFFFF_0000,
                0,
                0,
                0,
                0xFFFF_0000,
            ]
        };
        let (step, width) = if short {
            (2, Width::Word)
        } else {
            (4, Width::Dword)
        };
        self.x87_probe(at, 7 * step, Access::Write)?;
        for (index, word) in words.iter().enumerate() {
            self.x87_write(at.wrapping_add(step * index as u64), width, *word)?;
        }
        Ok(())
    }

    /// **`fldenv`** : le bit 6 du mot de contrôle revient levé, ES et B se
    /// recalculent, et une étiquette non vide se relit dans la valeur.
    fn x87_load_environment(&mut self, at: u64, short: bool) -> Result<(), ExtendedFault> {
        let step = if short { 2 } else { 4 };
        let control = self.x87_read(at, Width::Word)? as u16;
        let status = self.x87_read(at.wrapping_add(step), Width::Word)? as u16;
        let tags = self.x87_read(at.wrapping_add(2 * step), Width::Word)? as u16;
        self.fpu_control = control | 0x40;
        self.fpu_status = status;
        self.x87_summarise();
        self.fpu_tags = (0..8).fold(0u8, |occupied, physical| {
            if (tags >> (2 * physical)) & 3 == 3 {
                occupied
            } else {
                occupied | 1 << physical
            }
        });
        Ok(())
    }

    /// **`fbld`** : dix-huit chiffres décimaux, deux par octet, le signe dans
    /// le bit fort du dixième. Un chiffre au-delà de neuf n'est pas défini ;
    /// il est lu pour ce qu'il vaut.
    fn x87_read_bcd(&mut self, at: u64) -> Result<F80, ExtendedFault> {
        let low = self.x87_read(at, Width::Qword)?;
        let high = self.x87_read(at.wrapping_add(8), Width::Word)?;
        let bytes = u128::from(low) | (u128::from(high) << 64);
        let mut value: i64 = 0;
        for digit in (0..18).rev() {
            value = value * 10 + ((bytes >> (4 * digit)) & 0xF) as i64;
        }
        let negative = high & 0x8000 != 0;
        Ok(if value == 0 {
            F80::new(0, if negative { 0x8000 } else { 0 })
        } else {
            F80::from_integer(if negative { -value } else { value })
        })
    }

    /// **`fbstp`** : l'entier arrondi selon le mode, en dix-huit chiffres ; au
    ///-delà, ou d'un NaN, l'indéfini décimal (`FFFF C000 0000 0000 0000`).
    fn x87_to_bcd(&mut self, value: Option<F80>, rounding: Rounding) -> u128 {
        const INDEFINITE: u128 = 0xFFFF_C000_0000_0000_0000;
        let Some(value) = value else {
            return INDEFINITE;
        };
        let whole = value.as_integer(64, rounding);
        let Some(whole) = whole.filter(|whole| whole.unsigned_abs() < 1_000_000_000_000_000_000)
        else {
            self.x87_note(Report::of(INVALID));
            return INDEFINITE;
        };
        let (_, rounded) = value.integral(rounding);
        self.x87_note(Report {
            flags: rounded.flags & f80::INEXACT,
            rounded_up: rounded.rounded_up,
        });
        let mut magnitude = whole.unsigned_abs();
        let mut bcd = 0u128;
        for digit in 0..18 {
            bcd |= u128::from(magnitude % 10) << (4 * digit);
            magnitude /= 10;
        }
        if value.negative() {
            bcd |= 0x8000u128 << 64;
        }
        bcd
    }
}

/// La largeur d'un entier de `bits` bits.
fn width_of(bits: u32) -> Width {
    match bits {
        16 => Width::Word,
        32 => Width::Dword,
        _ => Width::Qword,
    }
}

/// `DC` et `DE` **échangent** la soustraction et la division avec leurs
/// formes renversées par rapport à `D8`.
fn reversed(field: u8) -> u8 {
    match field {
        4 => 5,
        5 => 4,
        6 => 7,
        7 => 6,
        other => other,
    }
}
