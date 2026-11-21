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
//! **Là où le cœur Swift se tait, le silicium de l'hôte décide** —
//! `tests/x86_float_host.rs` compare l'état entier, rangé par `fnsave`, sur
//! toutes les classes de l'étendu et toutes les piles :
//!
//! - *Lire un registre vide* est un débordement par le bas, quelle que soit
//!   l'instruction : invalide et faute de pile levés, C1 à zéro, et — masquée,
//!   ce qu'elle est après `fninit` — l'indéfini à la place de la valeur. Le
//!   cœur Swift ne le faisait que pour `fxch` et quelques fonctions.
//! - *Empiler sur un registre occupé* déborde par le haut (`x87_push`), jugé
//!   avant l'opérande : ni son dénormal ni son NaN signalant ne se disent.
//!   `fxtract` et `fptan` sur une pile pleine rangent l'indéfini deux fois ;
//!   sur une pile pleine dont ST(0) est vide, aussi, mais C1 reste à zéro.
//! - *C1 tombe* sur tout chargement, `fchs`, `fabs`, `fxch`, `fst` entre
//!   registres, `ffree` ; il ne dit « monté » qu'après un arrondi. `fcomi` et
//!   les siens, qui n'écrivent que RFLAGS, ne le touchent pas.
//! - *`fucomp` dépile*, ce que le cœur Swift oubliait.
//! - *`fcmov` lit ses deux registres* que la condition tienne ou non.
//! - *Un réel lu en mémoire* (`fld m32`, `fadd m64`…) signale son dénormal et
//!   son NaN signalant, et `fld` range ce dernier rendu silencieux ; le
//!   dénormal se tait devant un NaN, une opération invalide ou une division
//!   par zéro, en mémoire comme entre registres.
//! - *Une valeur que le processeur refuse* (non normalisée, pseudo-NaN,
//!   pseudo-infini) est invalide pour tout calcul, toute comparaison, tout
//!   rangement converti ; un pseudo-dénormal revient renormalisé.
//! - *La précision du mot de contrôle* (bits 8 et 9) arrondit `fadd`, `fsub`,
//!   `fmul`, `fdiv` et `fsqrt` à 24 ou 53 bits ; `fldcw`, `fldenv`,
//!   `frstor` et `fxrstor` gardent le mot comme le silicium (`control_word`).
//! - *`fnsave`, `frstor`, `fbld`, `fbstp`, `fdecstp`, `fincstp`, `fnop`* et les
//!   fonctions transcendantes, que le cœur Swift n'a pas.
//! - *Une exception démasquée* : celles qui précèdent le calcul (invalide,
//!   dénormal, division par zéro) arrêtent l'instruction sans rien ranger, C1
//!   tombé, et la suivante qui attend livre `#MF` (`execute_x87`).
//!
//! **Ce qui n'est pas modélisé** : un dépassement démasqué vers un registre,
//! où le silicium range le résultat au biais ajusté de 24 576 (ici, la
//! réponse masquée) ; les pointeurs de la dernière instruction (FIP, FDP,
//! FOP), rangés à zéro ; `fisttp`, du SSE3, que CPUID n'annonce pas.

use super::f80::{self, Order, Report, Rounding, F80};
use super::{Extended, ExtendedFault};
use crate::x86::{Cpu, Width, AF, CF, OF, PF, SF, ZF};
use crate::x86_paging::Access;

const INVALID: u16 = 1 << 0;
const STACK_FAULT: u16 = 1 << 6;
/// Les six drapeaux d'exception et la faute de pile.
const EXCEPTIONS: u16 = 0x7F;
/// Le résumé d'erreur : une exception démasquée attend.
const PENDING: u16 = 1 << 7;
const C0: u16 = 1 << 8;
const C1: u16 = 1 << 9;
const C2: u16 = 1 << 10;
const C3: u16 = 1 << 14;
const CONDITIONS: u16 = C0 | C1 | C2 | C3;

/// **La forme est-elle une instruction ?** Les octets de registre que le
/// manuel ne nomme pas (les alias non documentés de `fcom`, `fstp`, `fxch`)
/// et les champs mémoire réservés restent illisibles. **`fisttp`** (`DB /1`,
/// `DD /1`, `DF /1`) aussi : c'est une instruction de SSE3, que CPUID
/// n'annonce pas (`pc::systeme`) — un programme qui la tente sur ce
/// processeur reçoit `#UD`, comme sur un x86-64 de base. Le cœur Swift la
/// lit ; il se trompe.
pub(super) fn valid(opcode: u8, modrm: u8) -> bool {
    let field = (modrm >> 3) & 7;
    if modrm < 0xC0 {
        return match opcode {
            0xD9 => field != 1,
            0xDB => !matches!(field, 1 | 4 | 6),
            0xDD => !matches!(field, 1 | 5),
            0xDF => field != 1,
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

    /// **Un empilement débordera-t-il ?** Le registre sous le sommet est
    /// occupé : c'est la pile pleine, que le silicium juge **avant** de lire
    /// l'opérande — ni le dénormal ni le NaN signalant de la valeur ne se
    /// signalent alors, seul le débordement.
    fn push_overflows(&self) -> bool {
        self.fpu_tags & (1 << ((self.x87_top() + 7) & 7)) != 0
    }

    /// **Une exception démasquée attend-elle ?** ES, le résumé d'erreur : la
    /// prochaine instruction du x87 qui attend (ou du MMX, ou `fwait`) livre
    /// `#MF` au lieu de s'exécuter.
    pub fn x87_pending(&self) -> bool {
        self.fpu_status & PENDING != 0
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
    /// « non ordonnée » devant un NaN signalant seulement. Un opérande que le
    /// processeur refuse (non normalisé, pseudo-NaN) est invalide pour les
    /// deux. Sinon, un dénormal se signale — **sauf à côté d'un NaN**, même
    /// silencieux : le silicium de l'hôte le tait. `in_memory` dit que
    /// l'opérande de droite était un dénormal de son format en mémoire (le
    /// simple ou le double élargi n'en est plus un).
    fn note_comparison(&mut self, left: F80, right: F80, quiet_is_invalid: bool, in_memory: bool) {
        if left.is_unsupported() || right.is_unsupported() {
            self.fpu_status |= INVALID;
            return;
        }
        let signaling = left.is_signaling_nan() || right.is_signaling_nan();
        if signaling || (quiet_is_invalid && (left.is_nan() || right.is_nan())) {
            self.fpu_status |= INVALID;
            return;
        }
        if left.is_nan() || right.is_nan() {
            return;
        }
        if left.is_denormal_operand() || right.is_denormal_operand() || in_memory {
            self.fpu_status |= f80::DENORMAL;
        }
    }

    /// La même comparaison dans ZF, PF et CF (`fcomi`) ; OF, SF et AF tombent.
    /// Le mot d'état n'est pas touché : C1 reste ce qu'il était, comme sur
    /// le silicium de l'hôte (le manuel le dit mis à zéro).
    fn set_comparison_flags(&mut self, order: Order) {
        let set = match order {
            Order::Greater => 0,
            Order::Less => CF,
            Order::Equal => ZF,
            Order::Unordered => ZF | PF | CF,
        };
        let flags = self.flags.read() & !(ZF | PF | CF | OF | SF | AF);
        self.flags.write(flags | set);
    }

    /// Une comparaison de `ST(0)` à `right` : `None` pour un registre vide,
    /// qui ne laisse que le débordement par le bas — pas le dénormal d'un
    /// opérande en mémoire (`in_memory`).
    fn compare_top(
        &mut self,
        right: Option<F80>,
        quiet_is_invalid: bool,
        flags: bool,
        in_memory: bool,
    ) {
        let left = self.operand(0);
        let order = match (left, right) {
            (Some(left), Some(right)) => {
                self.note_comparison(left, right, quiet_is_invalid, in_memory);
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
    ///
    /// **Une exception que le mot de contrôle ne masque pas** change la
    /// réponse, comme sur le silicium de l'hôte :
    ///
    /// - *en attente* (ES levé), elle arrête toute instruction qui attend —
    ///   toutes sauf `fninit`, `fnclex`, `fnstsw`, `fnstcw`, `fnstenv`,
    ///   `fnsave`, et `fneni`, `fndisi`, `fnsetpm`, qui ne font rien : rien ne
    ///   s'exécute, et la machine livre `#MF` ;
    /// - *invalide (faute de pile comprise), dénormal ou division par zéro*,
    ///   elle arrête l'instruction avant qu'elle ne range : la pile, ses
    ///   registres et la mémoire restent ce qu'ils étaient, seuls son drapeau
    ///   (sans l'inexact d'un calcul qui n'a pas eu lieu), ES et B se lèvent,
    ///   C1 tombe (sauf sur un débordement de la pile par le haut), et une
    ///   comparaison pose quand même C3, C2 et C0. Un chargement
    ///   (`fld m32`, `fld m64`) d'un dénormal se fait pourtant ;
    /// - *dépassement par le haut ou par le bas d'un rangement en mémoire*,
    ///   elle l'arrête aussi, son seul drapeau levé (`x87_store_stops`).
    pub(super) fn execute_x87(
        &mut self,
        instruction: &Extended,
        at: Option<u64>,
    ) -> Result<(), ExtendedFault> {
        let super::Extra::X87 { opcode, modrm } = instruction.op else {
            unreachable!("execute_x87 ne reçoit que le x87")
        };
        let field = (modrm >> 3) & 7;
        // `fcomi` et les siens n'écrivent que RFLAGS : C1 reste ce qu'il était,
        // arrêtés ou non (sur l'hôte, C1 levé par `fsqrt` passe `fcomi`,
        // `fucomip`, et `fucomip` arrêté par un NaN signalant).
        let keeps_c1 = at.is_none() && matches!((opcode, modrm), (0xDB | 0xDF, 0xE8..=0xF7));
        let (waits, control, load, compares) = match at {
            None => {
                // `fneni`, `fndisi` et `fnsetpm` (`db e0`, `e1`, `e4`), des
                // restes du 8087 et du 80287 qui ne font plus rien, n'attendent
                // pas non plus : l'hôte les passe sous une exception en attente.
                let control = matches!((opcode, modrm), (0xDB, 0xE0..=0xE4) | (0xDF, 0xE0));
                let compares = matches!(
                    (opcode, modrm),
                    (0xD8, 0xD0..=0xDF)
                        | (0xDD, 0xE0..=0xEF)
                        | (0xDA, 0xE9)
                        | (0xDE, 0xD9)
                        | (0xD9, 0xE4)
                );
                (!control, control, false, compares)
            }
            Some(_) => (
                !matches!((opcode, field), (0xD9, 6 | 7) | (0xDD, 6 | 7)),
                matches!((opcode, field), (0xD9, 4..=7) | (0xDD, 4 | 6 | 7)),
                matches!((opcode, field), (0xD9 | 0xDD, 0)),
                matches!((opcode, field), (0xD8 | 0xDA | 0xDC | 0xDE, 2 | 3)),
            ),
        };
        if waits && self.x87_pending() {
            return Err(ExtendedFault::FloatingPoint);
        }
        if control {
            // Les mots, l'environnement, `fninit` : ils posent l'état
            // eux-mêmes.
            match at {
                None => self.x87_register_form(opcode, modrm),
                Some(at) => {
                    let short = instruction.width == Width::Word;
                    self.x87_memory_form(opcode, field, at, short)?;
                }
            }
            self.x87_summarise();
            return Ok(());
        }
        let before = (self.x87, self.fpu_tags, self.fpu_status);
        // Les drapeaux de cette instruction seule : ceux d'avant reviennent
        // après.
        self.fpu_status &= !EXCEPTIONS;
        let outcome = match at {
            None => {
                self.x87_register_form(opcode, modrm);
                Ok(())
            }
            Some(at) => self.x87_memory_form(opcode, field, at, false),
        };
        if let Err(fault) = outcome {
            (self.x87, self.fpu_tags, self.fpu_status) = before;
            return Err(fault);
        }
        let own = self.fpu_status & EXCEPTIONS;
        let stopping = if load {
            INVALID | f80::ZERO_DIVIDE
        } else {
            INVALID | f80::DENORMAL | f80::ZERO_DIVIDE
        };
        if own & !self.fpu_control & stopping != 0 {
            (self.x87, self.fpu_tags) = (before.0, before.1);
            // **C1 tombe**, sauf sur une faute de pile, où il dit son sens
            // (débordement par le haut), et pour `fcomi`, qui ne le touche
            // pas. C3, C2 et C0 disent ce qu'une comparaison a trouvé ;
            // sinon ils restent ce qu'ils étaient — `fprem` arrêté ne dit
            // rien de son quotient. Sur l'hôte, C1 levé par l'arrondi de
            // `fsqrt`, puis `fdiv` par zéro arrêté : 0xb0a4, C1 tombé.
            let c1 = if own & STACK_FAULT != 0 || keeps_c1 {
                self.fpu_status & C1
            } else {
                0
            };
            let found = if compares { self.fpu_status } else { before.2 };
            let codes = (found & (C0 | C2 | C3)) | c1;
            let raised = own & (stopping | STACK_FAULT);
            self.fpu_status = (before.2 & !CONDITIONS) | codes | raised;
        } else {
            self.fpu_status |= before.2 & EXCEPTIONS;
        }
        self.x87_summarise();
        Ok(())
    }

    /// **Un rangement en mémoire qu'une exception démasquée arrête** : ni
    /// écriture ni dépilement. `flags` est ce que la conversion signale, en
    /// plus de ce que l'instruction a déjà levé (le débordement par le bas
    /// d'une pile vide). Un dépassement démasqué, par le haut ou par le bas,
    /// ne lève que lui — le silicium de l'hôte ne dit pas l'inexact d'un
    /// résultat qu'il n'a pas rangé. **C1 tombe**, comme sur toute instruction
    /// arrêtée (sur l'hôte, `fsts` d'un 2·10¹⁵⁰ au dépassement démasqué, C1
    /// levé juste avant : 0xb8a8).
    fn x87_store_stops(&mut self, flags: u16) -> bool {
        let unmasked = ((self.fpu_status & EXCEPTIONS) | flags) & !self.fpu_control;
        let before = INVALID | f80::DENORMAL | f80::ZERO_DIVIDE;
        let after = f80::OVERFLOW | f80::UNDERFLOW;
        let raised = if unmasked & before != 0 {
            flags & before
        } else if unmasked & after != 0 {
            flags & after
        } else {
            return false;
        };
        self.fpu_status = (self.fpu_status | raised) & !C1;
        true
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
            (0xD9, 0xE4) => self.compare_top(Some(F80::ZERO), true, false, false),
            (0xD9, 0xE5) => {
                self.fpu_status = (self.fpu_status & !CONDITIONS) | self.examined();
            }
            (0xD9, 0xE8) => self.x87_push(F80::ONE.pair()),
            (0xD9, 0xEE) => self.x87_push(F80::ZERO.pair()),
            (0xD9, 0xE9..=0xED) => {
                let (value, _) = f80::constant(modrm, rounding).expect("une constante");
                self.x87_push(value.pair());
            }
            (0xD9, 0xF0) => {
                self.on_top(|cpu, value| f80::two_to_the_minus_one(value, cpu.rounding()))
            }
            (0xD9, 0xF1) | (0xD9, 0xF9) => {
                // fyl2x, fyl2xp1 : ST(1) = ST(1) · log₂(ST(0) [+ 1]), dépiler.
                let (x, y) = (self.operand(0), self.operand(1));
                let result = match (x, y) {
                    (Some(x), Some(y)) => {
                        let (result, report) = if modrm == 0xF9 {
                            f80::y_log2_one_plus_x(y, x, rounding)
                        } else {
                            f80::y_log2_x(y, x, rounding)
                        };
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
                        let (result, report) = f80::arctangent(y, x, rounding);
                        self.x87_note(report);
                        result
                    }
                    _ => F80::INDEFINITE,
                };
                self.set_st(1, result);
                self.x87_pop();
            }
            (0xD9, 0xF4) if !self.st_empty(0) && self.push_overflows() => {
                self.overflow_into_two();
            }
            (0xD9, 0xF4) => {
                // fxtract : l'exposant reste, la mantisse s'empile.
                match self.operand(0) {
                    Some(value) => {
                        let (exponent, significand, report) = f80::extracted(value);
                        self.x87_note(report);
                        self.set_st(0, exponent);
                        self.x87_push(significand.pair());
                    }
                    None => self.empty_into_two(),
                }
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
            // `DB` sur leurs négations. La pile ne bouge pas. **Les deux
            // registres sont lus que la condition tienne ou non** : un vide
            // est un débordement par le bas, et ST(0) prend l'indéfini, comme
            // sur le silicium de l'hôte.
            (0xDA | 0xDB, 0xC0..=0xDF) => {
                let flags = self.flags.read();
                let holds = match field {
                    0 => flags & CF != 0,
                    1 => flags & ZF != 0,
                    2 => flags & (CF | ZF) != 0,
                    _ => flags & PF != 0,
                };
                let top = self.operand(0);
                let source = self.operand(index);
                match (top, source) {
                    (Some(_), Some(source)) if holds != (opcode == 0xDB) => self.set_st(0, source),
                    (Some(_), Some(_)) => {}
                    _ => self.set_st(0, F80::INDEFINITE),
                }
            }
            (0xDA, 0xE9) | (0xDE, 0xD9) => {
                // fucompp, fcompp.
                let right = self.operand(1);
                self.compare_top(right, opcode == 0xDE, false, false);
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
                self.compare_top(right, field == 6, true, false);
                if opcode == 0xDF {
                    self.x87_pop();
                }
            }
            // ffree, ffreep : **C1 tombe** — le manuel dit les codes non
            // définis ; sur l'hôte, C1 levé par `fsqrt` retombe.
            (0xDD, 0xC0..=0xC7) => {
                let physical = (self.x87_top() + index) & 7;
                self.fpu_tags &= !(1 << physical);
                self.fpu_status &= !C1;
            }
            (0xDF, 0xC0..=0xC7) => {
                let physical = (self.x87_top() + index) & 7;
                self.fpu_tags &= !(1 << physical);
                self.fpu_status &= !C1;
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
                self.compare_top(right, opcode == 0xD8, false, false);
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

    /// **`fxtract` et `fptan` sur une pile pleine** : le silicium ne calcule
    /// rien — ST(0) et le registre empilé prennent l'un et l'autre
    /// l'indéfini, et seul le débordement se signale.
    fn overflow_into_two(&mut self) {
        self.set_st(0, F80::INDEFINITE);
        self.x87_push(F80::INDEFINITE.pair());
    }

    /// **`fxtract`, `fptan` et `fsincos` d'un ST(0) vide** : le débordement
    /// par le bas est déjà signalé, ST(0) et le registre empilé prennent
    /// l'indéfini, et **C1 reste à zéro** — même quand l'empilement trouve
    /// le registre d'en dessous occupé (la pile pleine dont ST(0) est vide :
    /// sur l'hôte, `fninit ; fld1 ×7 ; fldpi ; ffree %st(0) ; fxtract` rend
    /// sw 0x3841, C1 tombé, et deux indéfinis).
    fn empty_into_two(&mut self) {
        self.set_st(0, F80::INDEFINITE);
        self.x87_push(F80::INDEFINITE.pair());
        self.fpu_status &= !C1;
    }

    /// `fsin`, `fcos`, `fsincos`, `fptan`. Au-delà de 2⁶³, C2 levé et
    /// l'opérande laissé tel quel. **C2 tombe dès que l'argument est dans le
    /// domaine** : la boucle de réduction de la `libm` (`fsin ; fnstsw ;
    /// test $0x400`) en dépend.
    fn sine_cosine(&mut self, modrm: u8) {
        let pushes = matches!(modrm, 0xF2 | 0xFB);
        if pushes && !self.st_empty(0) && self.push_overflows() {
            self.overflow_into_two();
            return;
        }
        let Some(x) = self.operand(0) else {
            if pushes {
                self.empty_into_two();
            } else {
                self.set_st(0, F80::INDEFINITE);
            }
            return;
        };
        let Some(outcome) = f80::sine_cosine(x, self.rounding()) else {
            self.fpu_status = (self.fpu_status | C2) & !C1;
            return;
        };
        self.fpu_status &= !C2;
        let f80::Trigonometric {
            sine,
            cosine,
            tangent,
        } = outcome;
        match modrm {
            0xFE => {
                self.x87_note(sine.1);
                self.set_st(0, sine.0);
            }
            0xFF => {
                self.x87_note(cosine.1);
                self.set_st(0, cosine.0);
            }
            // Ce qui s'empile ne fait pas tomber C1 : il dit l'arrondi de la
            // valeur calculée.
            0xFB => {
                self.set_st(0, sine.0);
                self.x87_push(cosine.0.pair());
                self.fpu_status |= sine.1.flags;
                self.x87_note(cosine.1);
            }
            _ => {
                self.set_st(0, tangent.0);
                // D'un NaN ou d'un infini, le silicium range le NaN (ou
                // l'indéfini) **dans les deux registres**, et non 1,0.
                if x.is_nan() || x.is_infinite() || x.is_unsupported() {
                    self.x87_push(tangent.0.pair());
                } else {
                    self.x87_push(F80::ONE.pair());
                }
                self.x87_note(tangent.1);
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
                if !self.push_overflows() {
                    self.fpu_status |= report.flags;
                }
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
                let value = self.operand(0);
                let (bits, report) = match value {
                    Some(value) if double => value.narrowed(52, 11, rounding),
                    Some(value) => value.narrowed(23, 8, rounding),
                    None if double => (0xFFF8_0000_0000_0000, Report::default()),
                    None => (0xFFC0_0000, Report::default()),
                };
                if self.x87_store_stops(report.flags) {
                    return Ok(());
                }
                if value.is_some() {
                    self.x87_note(report);
                }
                self.x87_write(at, width, bits)?;
                if field == 3 {
                    self.x87_pop();
                }
            }
            (0xDB, 7) => {
                self.x87_probe(at, 10, Access::Write)?;
                let value = self.operand(0).unwrap_or(F80::INDEFINITE);
                if self.x87_store_stops(0) {
                    return Ok(());
                }
                self.x87_write_ten(at, value)?;
                self.fpu_status &= !C1;
                self.x87_pop();
            }
            (0xDF, 2 | 3 | 7) | (0xDB, 2 | 3) => {
                // fist, fistp, selon le mode d'arrondi.
                let bits = match (opcode, field) {
                    (0xDF, 7) => 64,
                    (0xDB, _) => 32,
                    _ => 16,
                };
                let width = width_of(bits);
                self.x87_probe(at, width as u64, Access::Write)?;
                let value = self.operand(0);
                let whole = self.x87_integer(value, bits, rounding);
                if self.x87_store_stops(0) {
                    return Ok(());
                }
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
                if self.x87_store_stops(0) {
                    return Ok(());
                }
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
                    // qui le signale elle-même ; le dénormal aussi, avec les
                    // mêmes règles qu'entre registres.
                    let in_memory = opening.flags & f80::DENORMAL != 0;
                    self.compare_top(Some(value), true, false, in_memory);
                    if field == 3 {
                        self.x87_pop();
                    }
                } else {
                    let result = match self.operand(0) {
                        Some(top) => {
                            // Le dénormal de l'opérande en mémoire : les règles
                            // du calcul entre registres — tu devant un NaN,
                            // une opération invalide ou une division par zéro.
                            let (result, mut report) = self.combine(field, top, value);
                            let silenced = report.flags & (INVALID | f80::ZERO_DIVIDE) != 0
                                || top.is_nan()
                                || value.is_nan();
                            if !silenced {
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
                self.fpu_control = control_word(self.x87_read(at, Width::Word)? as u16);
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

    /// **`fldenv`** : le mot de contrôle passe par `control_word`, ES et B se
    /// recalculent, et une étiquette non vide se relit dans la valeur.
    fn x87_load_environment(&mut self, at: u64, short: bool) -> Result<(), ExtendedFault> {
        let step = if short { 2 } else { 4 };
        let control = self.x87_read(at, Width::Word)? as u16;
        let status = self.x87_read(at.wrapping_add(step), Width::Word)? as u16;
        let tags = self.x87_read(at.wrapping_add(2 * step), Width::Word)? as u16;
        self.fpu_control = control_word(control);
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

/// **Le mot de contrôle tel que le silicium le garde** (`fldcw`, `fldenv`,
/// `frstor`, `fxrstor`) : le bit 6 toujours levé, les bits 7 et 13 à 15
/// toujours nuls. Relu par `fnstcw` ou `fnsave` sur l'hôte, `fldcw 0x0000`
/// rend 0x0040 et `fldcw 0xe97a` rend 0x097a ; `fxrstor` d'une aire qui dit
/// 0xffff rend 0x1f7f, et 0x0080 rend 0x0040.
pub(super) fn control_word(word: u16) -> u16 {
    (word & 0x1F7F) | 0x40
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
