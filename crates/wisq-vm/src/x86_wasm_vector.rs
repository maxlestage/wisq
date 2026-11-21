//! **L'émission des instructions SSE et SSE2 entières**, que `x86_vector.rs`
//! décode.
//!
//! Chaque registre XMM tient dans deux globales `i64` (voir `XMM_SLOT`), et
//! chaque instruction s'écrit en arithmétique de soixante-quatre bits : une
//! voie après l'autre, extraite, calculée, remise en place. C'est plus de
//! code que SIMD n'en demanderait, et c'est exprès — voir `XMM_SLOT` pour
//! pourquoi pas `v128`. Ce que ça coûte en taille de module se mesure
//! (`docs/JOURNAL.md`) ; ce que ça vaut se juge contre le silicium, par
//! `x86-xmm-oracle.tsv` et `x86-simd-oracle.tsv` rejoués sous JavaScriptCore.
//!
//! **Une instruction qui faute n'a rien fait.** Les opérandes mémoire sont lus
//! en entier dans des cases de travail avant qu'un registre change ; une
//! écriture de seize octets est jugée entière pour l'écriture, sans rien
//! écrire, puis écrit ses deux moitiés, qui ne peuvent plus fauter. Les deux
//! tiennent par un test chacune
//! (`a_sixteen_byte_load_that_faults_changes_no_register`,
//! `a_sixteen_byte_store_faults_where_the_silicon_does_and_writes_nothing`).
//! Aucune de ces instructions ne touche RFLAGS.
//!
//! **Ce que l'alignement ne fait pas ici.** `movaps`, `movdqa` et les formes
//! arithmétiques en mémoire exigent seize octets alignés, et le silicium lève
//! `#GP(0)` sinon. Ce cœur ne le vérifie pas : un programme juste n'en
//! dépend pas, et un programme faux lirait ici ce que `movups` lirait. C'est
//! une infidélité connue, pas un oubli.

use super::{code, Body, Module, STOP_MXCSR};
use super::{MXCSR_MASK, MXCSR_SLOT, XMM_SLOT};
use crate::x86::{Decoded, Lanes, Logic, Mask, Shift, Shuffle, Vector, Width};

/// La globale d'une moitié de registre XMM.
pub(super) fn xmm(register: u8, high: bool) -> usize {
    XMM_SLOT + 2 * register as usize + usize::from(high)
}

/// Les cases de travail, nommées une fois. Les blocs n'ont aucune locale :
/// ces globales en tiennent lieu, le temps d'une instruction.
const SOURCE: (usize, usize) = (SCRATCH, SCRATCH + 1);
const RESULT: (usize, usize) = (SCRATCH + 2, SCRATCH + 3);
const FIRST: usize = SCRATCH + 4;
const SECOND: usize = SCRATCH + 5;
const HELD: usize = SCRATCH + 6;
const COUNT: usize = SCRATCH + 7;
const SCRATCH: usize = super::SCRATCH_SLOT;

/// Les bits d'une voie de cette largeur.
fn bits(lane: Width) -> u32 {
    lane as u32 * 8
}

/// Le masque d'une voie, en bits.
fn lane_mask(bits: u32) -> u64 {
    if bits == 64 {
        u64::MAX
    } else {
        (1u64 << bits) - 1
    }
}

impl Body {
    /// Pousser la voie `index` d'un registre de cent vingt-huit bits tenu dans
    /// deux globales, **étendue par zéro ou en signe** à soixante-quatre bits.
    fn lane(&mut self, pair: (usize, usize), index: u32, bits: u32, signed: bool) -> &mut Self {
        let at = index * bits;
        let slot = if at >= 64 { pair.1 } else { pair.0 };
        let position = u64::from(at % 64);
        self.load(slot);
        if bits == 64 {
            return self;
        }
        if signed {
            let up = 64 - position - u64::from(bits);
            if up > 0 {
                self.constant(up).op(code::I64_SHL);
            }
            self.constant(64 - u64::from(bits)).op(code::I64_SHR_S)
        } else {
            if position > 0 {
                self.constant(position).op(code::I64_SHR_U);
            }
            if position + u64::from(bits) < 64 {
                self.constant(lane_mask(bits)).op(code::I64_AND);
            }
            self
        }
    }

    /// **Bâtir un registre de cent vingt-huit bits voie par voie**, dans
    /// `RESULT`. `value` pousse la voie `index` : n'importe quel `i64`, dont
    /// seuls les `bits` bas comptent. Le résultat n'est écrit dans aucun XMM :
    /// les opérandes restent lisibles jusqu'au bout, même quand la
    /// destination est aussi une source.
    fn build_lanes(&mut self, bits: u32, mut value: impl FnMut(&mut Body, u32)) -> &mut Self {
        let per_half = 64 / bits;
        for (half, slot) in [RESULT.0, RESULT.1].into_iter().enumerate() {
            for within in 0..per_half {
                let index = half as u32 * per_half + within;
                value(self, index);
                if bits < 64 {
                    self.constant(lane_mask(bits)).op(code::I64_AND);
                    let position = u64::from(within * bits);
                    if position > 0 {
                        self.constant(position).op(code::I64_SHL);
                    }
                    if within > 0 {
                        self.op(code::I64_OR);
                    }
                }
            }
            self.store(slot, |_| {});
        }
        self
    }

    /// Poser `RESULT` dans un registre XMM.
    fn commit(&mut self, register: u8) -> &mut Self {
        self.store(xmm(register, false), |b| {
            b.load(RESULT.0);
        });
        self.store(xmm(register, true), |b| {
            b.load(RESULT.1);
        })
    }

    /// **Choisir entre deux valeurs gardées dans des cases**, sans
    /// branchement : `then` si la condition que `test` pousse tient.
    fn pick(
        &mut self,
        then: impl FnOnce(&mut Body),
        otherwise: impl FnOnce(&mut Body),
        test: impl FnOnce(&mut Body),
    ) -> &mut Self {
        then(self);
        otherwise(self);
        test(self);
        self.op(code::SELECT)
    }

    /// Ramener la valeur de `HELD` dans `[low, high]`, comparée en signé.
    fn clamp(&mut self, low: i64, high: i64) -> &mut Self {
        self.store(HELD, |b| {
            b.pick(
                |b| {
                    b.constant(high as u64);
                },
                |b| {
                    b.load(HELD);
                },
                |b| {
                    b.load(HELD).constant(high as u64).op(code::I64_GT_S);
                },
            );
        });
        self.pick(
            |b| {
                b.constant(low as u64);
            },
            |b| {
                b.load(HELD);
            },
            |b| {
                b.load(HELD).constant(low as u64).op(code::I64_LT_S);
            },
        )
    }

    /// Rendre la main **sur** l'instruction si la condition (un `i32`) tient,
    /// le témoin d'arrêt posé.
    fn stop_if(&mut self, stop: u64) -> &mut Self {
        self.op(code::IF).op(code::VOID);
        Module::stop_on(self.here, stop, self);
        self.op(code::END)
    }
}

impl Module {
    /// **Traduire une instruction vectorielle.** `None` ne se produit pas pour
    /// une forme que `x86_vector.rs` a lue : le décodeur et l'émetteur tiennent
    /// la même liste.
    pub(super) fn vector(vector: Vector, step: &Decoded, body: &mut Body) -> Option<()> {
        let (reg, rm) = (step.dst, step.src);
        match vector {
            Vector::MoveIn => {
                let mask = step.width.mask();
                body.store(SOURCE.0, |b| {
                    match &step.memory {
                        Some(address) => {
                            b.load_memory(address, step.width);
                        }
                        None => {
                            b.load(Self::slot(rm)).constant(mask).op(code::I64_AND);
                        }
                    };
                });
                body.store(xmm(reg, false), |b| {
                    b.load(SOURCE.0);
                });
                body.store(xmm(reg, true), |b| {
                    b.constant(0);
                });
            }
            Vector::MoveOut => {
                let mask = step.width.mask();
                match &step.memory {
                    Some(address) => {
                        body.store_memory(address, step.width, |b| {
                            b.load(xmm(reg, false));
                        });
                    }
                    // Une écriture de trente-deux bits efface le haut du
                    // registre général : le masque le fait.
                    None => {
                        body.store(Self::slot(rm), |b| {
                            b.load(xmm(reg, false)).constant(mask).op(code::I64_AND);
                        });
                    }
                }
            }
            Vector::LoadQuad => {
                body.store(SOURCE.0, |b| {
                    match &step.memory {
                        Some(address) => {
                            b.load_memory(address, Width::Qword);
                        }
                        None => {
                            b.load(xmm(rm, false));
                        }
                    };
                });
                body.store(xmm(reg, false), |b| {
                    b.load(SOURCE.0);
                });
                body.store(xmm(reg, true), |b| {
                    b.constant(0);
                });
            }
            Vector::StoreQuad => match &step.memory {
                Some(address) => {
                    body.store_memory(address, Width::Qword, |b| {
                        b.load(xmm(reg, false));
                    });
                }
                None => {
                    body.store(xmm(rm, false), |b| {
                        b.load(xmm(reg, false));
                    });
                    body.store(xmm(rm, true), |b| {
                        b.constant(0);
                    });
                }
            },
            Vector::Load => {
                Self::source(step, body);
                body.store(xmm(reg, false), |b| {
                    b.load(SOURCE.0);
                });
                body.store(xmm(reg, true), |b| {
                    b.load(SOURCE.1);
                });
            }
            Vector::Store => match &step.memory {
                Some(address) => Self::store_wide(address, reg, body),
                None => {
                    body.store(xmm(rm, false), |b| {
                        b.load(xmm(reg, false));
                    });
                    body.store(xmm(rm, true), |b| {
                        b.load(xmm(reg, true));
                    });
                }
            },
            Vector::LoadScalar => match &step.memory {
                // Depuis la mémoire : le reste du registre à zéro.
                Some(address) => {
                    body.store(SOURCE.0, |b| {
                        b.load_memory(address, step.width);
                    });
                    body.store(xmm(reg, false), |b| {
                        b.load(SOURCE.0);
                    });
                    body.store(xmm(reg, true), |b| {
                        b.constant(0);
                    });
                }
                // Depuis un registre : seule la largeur change, le reste reste.
                None => Self::merge_scalar(rm, reg, step.width, body),
            },
            Vector::StoreScalar => match &step.memory {
                Some(address) => {
                    body.store_memory(address, step.width, |b| {
                        b.load(xmm(reg, false));
                    });
                }
                None => Self::merge_scalar(reg, rm, step.width, body),
            },
            Vector::LoadHalf { high } => {
                let address = step.memory.as_ref()?;
                body.store(SOURCE.0, |b| {
                    b.load_memory(address, Width::Qword);
                });
                body.store(xmm(reg, high), |b| {
                    b.load(SOURCE.0);
                });
            }
            Vector::StoreHalf { high } => {
                let address = step.memory.as_ref()?;
                body.store_memory(address, Width::Qword, |b| {
                    b.load(xmm(reg, high));
                });
            }
            Vector::HighToLow => {
                body.store(xmm(reg, false), |b| {
                    b.load(xmm(rm, true));
                });
            }
            Vector::LowToHigh => {
                body.store(xmm(reg, true), |b| {
                    b.load(xmm(rm, false));
                });
            }
            Vector::Logic(logic) => {
                Self::source(step, body);
                for (high, source) in [(false, SOURCE.0), (true, SOURCE.1)] {
                    body.store(xmm(reg, high), |b| {
                        b.load(xmm(reg, high));
                        if logic == Logic::AndNot {
                            b.constant(u64::MAX).op(code::I64_XOR);
                        }
                        b.load(source).op(match logic {
                            Logic::And | Logic::AndNot => code::I64_AND,
                            Logic::Or => code::I64_OR,
                            Logic::Xor => code::I64_XOR,
                        });
                    });
                }
            }
            Vector::Unpack { lane, high } => {
                Self::source(step, body);
                let width = bits(lane);
                let offset = if high { 64 / width } else { 0 };
                let destination = (xmm(reg, false), xmm(reg, true));
                body.build_lanes(width, |b, index| {
                    let from = offset + index / 2;
                    let pair = if index % 2 == 0 { destination } else { SOURCE };
                    b.lane(pair, from, width, false);
                });
                body.commit(reg);
            }
            Vector::Lanes(lanes) => {
                Self::source(step, body);
                Self::lanes(lanes, reg, body);
                body.commit(reg);
            }
            Vector::ShiftImmediate { lane, kind } => {
                let width = bits(lane);
                let count = step.imm;
                let pair = (xmm(reg, false), xmm(reg, true));
                body.build_lanes(width, |b, index| {
                    if count >= u64::from(width) && kind != Shift::RightArithmetic {
                        b.constant(0);
                        return;
                    }
                    let count = count.min(u64::from(width) - 1);
                    b.lane(pair, index, width, kind == Shift::RightArithmetic);
                    if count > 0 {
                        b.constant(count).op(match kind {
                            Shift::Left => code::I64_SHL,
                            Shift::Right => code::I64_SHR_U,
                            Shift::RightArithmetic => code::I64_SHR_S,
                        });
                    }
                });
                body.commit(reg);
            }
            Vector::ShiftBy { lane, kind } => {
                Self::source(step, body);
                let width = u64::from(bits(lane));
                // Le compte : les soixante-quatre bits bas de la source, non
                // signés. Au-delà de la largeur, un décalage logique rend
                // zéro et un décalage arithmétique recopie le signe partout.
                body.store(COUNT, |b| {
                    if kind == Shift::RightArithmetic {
                        b.pick(
                            |b| {
                                b.load(SOURCE.0);
                            },
                            |b| {
                                b.constant(width - 1);
                            },
                            |b| {
                                b.load(SOURCE.0).constant(width).op(code::I64_LT_U);
                            },
                        );
                    } else {
                        b.load(SOURCE.0);
                    }
                });
                let pair = (xmm(reg, false), xmm(reg, true));
                body.build_lanes(width as u32, |b, index| {
                    b.pick(
                        |b| {
                            b.lane(pair, index, width as u32, kind == Shift::RightArithmetic);
                            b.load(COUNT).op(match kind {
                                Shift::Left => code::I64_SHL,
                                Shift::Right => code::I64_SHR_U,
                                Shift::RightArithmetic => code::I64_SHR_S,
                            });
                        },
                        |b| {
                            b.constant(0);
                        },
                        |b| {
                            b.load(COUNT).constant(width).op(code::I64_LT_U);
                        },
                    );
                });
                body.commit(reg);
            }
            Vector::ShiftBytes { left } => {
                // Le registre entier, décalé de `8 × n` bits : connu à la
                // traduction, donc rien ne se décide à l'exécution.
                let shift = step.imm.min(16) * 8;
                let (low, high_slot) = (xmm(reg, false), xmm(reg, true));
                if shift == 0 {
                    return Some(());
                }
                for high in [false, true] {
                    body.store(if high { RESULT.1 } else { RESULT.0 }, |b| {
                        Self::shifted_half(b, (low, high_slot), left, shift, high);
                    });
                }
                body.commit(reg);
            }
            Vector::Shuffle(shuffle) => {
                Self::source(step, body);
                let order = step.imm as u32;
                let destination = (xmm(reg, false), xmm(reg, true));
                match shuffle {
                    Shuffle::Dwords => {
                        body.build_lanes(32, |b, index| {
                            b.lane(SOURCE, (order >> (2 * index)) & 3, 32, false);
                        });
                    }
                    Shuffle::LowWords | Shuffle::HighWords => {
                        let moved = if shuffle == Shuffle::LowWords { 0 } else { 4 };
                        body.build_lanes(16, |b, index| {
                            if index / 4 * 4 == moved {
                                let pick = (order >> (2 * (index - moved))) & 3;
                                b.lane(SOURCE, moved + pick, 16, false);
                            } else {
                                b.lane(SOURCE, index, 16, false);
                            }
                        });
                    }
                    Shuffle::Singles => {
                        body.build_lanes(32, |b, index| {
                            let pair = if index < 2 { destination } else { SOURCE };
                            b.lane(pair, (order >> (2 * index)) & 3, 32, false);
                        });
                    }
                    Shuffle::Doubles => {
                        body.build_lanes(64, |b, index| {
                            let pair = if index == 0 { destination } else { SOURCE };
                            b.lane(pair, (order >> index) & 1, 64, false);
                        });
                    }
                }
                body.commit(reg);
            }
            Vector::MoveMask(mask) => {
                body.store(Self::slot(reg), |b| match mask {
                    // **Les huit bits de signe d'une moitié en une
                    // multiplication.** Le bit `8k + 7` multiplié par
                    // `2^(7(7 - k))` tombe au bit `56 + k`, et aucune autre
                    // paire ne tombe au-dessous de soixante-quatre sur la même
                    // position : les huit bits arrivent dans l'octet haut sans
                    // retenue.
                    Mask::Bytes => {
                        for high in [false, true] {
                            b.load(xmm(rm, high))
                                .constant(0x8080_8080_8080_8080)
                                .op(code::I64_AND)
                                .constant(0x0002_0408_1020_4081)
                                .op(code::I64_MUL)
                                .constant(56)
                                .op(code::I64_SHR_U);
                        }
                        b.constant(8).op(code::I64_SHL).op(code::I64_OR);
                    }
                    Mask::Singles => {
                        for (index, (high, at)) in
                            [(false, 31), (false, 63), (true, 31), (true, 63)]
                                .into_iter()
                                .enumerate()
                        {
                            b.load(xmm(rm, high))
                                .constant(at)
                                .op(code::I64_SHR_U)
                                .constant(1)
                                .op(code::I64_AND);
                            if index > 0 {
                                b.constant(index as u64).op(code::I64_SHL).op(code::I64_OR);
                            }
                        }
                    }
                    Mask::Doubles => {
                        b.load(xmm(rm, false)).constant(63).op(code::I64_SHR_U);
                        b.load(xmm(rm, true))
                            .constant(63)
                            .op(code::I64_SHR_U)
                            .constant(1)
                            .op(code::I64_SHL)
                            .op(code::I64_OR);
                    }
                });
            }
            Vector::ExtractWord => {
                let index = (step.imm & 7) as u32;
                body.store(Self::slot(reg), |b| {
                    b.lane((xmm(rm, false), xmm(rm, true)), index, 16, false);
                });
            }
            Vector::InsertWord => {
                let index = (step.imm & 7) as u32;
                body.store(SOURCE.0, |b| {
                    match &step.memory {
                        Some(address) => {
                            b.load_memory(address, Width::Word);
                        }
                        None => {
                            b.load(Self::slot(rm)).constant(0xffff).op(code::I64_AND);
                        }
                    };
                });
                let slot = xmm(reg, index >= 4);
                let position = u64::from(index % 4 * 16);
                body.store(slot, |b| {
                    b.load(slot)
                        .constant(!(0xffff << position))
                        .op(code::I64_AND)
                        .load(SOURCE.0)
                        .constant(position)
                        .op(code::I64_SHL)
                        .op(code::I64_OR);
                });
            }
            Vector::Float(float) => return Self::float(float, step, body),
            Vector::LoadControl => {
                let address = step.memory.as_ref()?;
                body.store(SOURCE.0, |b| {
                    b.load_memory(address, Width::Dword);
                });
                body.load(SOURCE.0)
                    .constant(!MXCSR_MASK)
                    .op(code::I64_AND)
                    .op(code::I64_EQZ)
                    .op(code::I32_EQZ);
                body.stop_if(STOP_MXCSR);
                body.store(MXCSR_SLOT, |b| {
                    b.load(SOURCE.0);
                });
            }
            Vector::StoreControl => {
                let address = step.memory.as_ref()?;
                body.store_memory(address, Width::Dword, |b| {
                    b.load(MXCSR_SLOT);
                });
            }
        }
        Some(())
    }

    /// **La source de cent vingt-huit bits, dans `SOURCE`** : un XMM, ou seize
    /// octets de mémoire lus en deux moitiés. Les deux lectures ont lieu avant
    /// que rien ne change : une faute sur la seconde laisse la machine telle
    /// qu'elle était.
    fn source(step: &Decoded, body: &mut Body) {
        match &step.memory {
            Some(address) => {
                body.store(SOURCE.0, |b| {
                    b.load_memory(address, Width::Qword);
                });
                body.store(SOURCE.1, |b| {
                    b.wide_address(address)
                        .constant(8)
                        .op(code::I64_ADD)
                        .peek(Width::Qword);
                });
            }
            None => {
                body.store(SOURCE.0, |b| {
                    b.load(xmm(step.src, false));
                });
                body.store(SOURCE.1, |b| {
                    b.load(xmm(step.src, true));
                });
            }
        }
    }

    /// **Seize octets écrits sans jamais en écrire la moitié.** Les seize
    /// octets sont d'abord **jugés pour l'écriture**, sans rien écrire
    /// (`Body::claim`) : si la page du premier octet ou celle du dernier manque
    /// ou refuse l'écriture, la faute part là, avec le code d'une écriture et
    /// CR2 où le silicium le met. Après elle, les deux moitiés tiennent dans
    /// des pages déjà jugées, et ne fautent plus.
    ///
    /// Ce n'était pas le cas avant : le dernier octet était **relu** puis
    /// réécrit. Sur une page absente, la relecture fautait en lecture (code 0,
    /// pas W), CR2 sur le dernier octet. Mesuré sur le silicium : W, et CR2
    /// sur le premier octet de l'accès qui tombe dans la page fautive
    /// (`docs/JOURNAL.md`).
    fn store_wide(address: &crate::x86::Address, register: u8, body: &mut Body) {
        body.claim(16, |b| {
            b.wide_address(address);
        });
        body.store_memory(address, Width::Qword, |b| {
            b.load(xmm(register, false));
        });
        body.poke(
            Width::Qword,
            |b| {
                b.wide_address(address).constant(8).op(code::I64_ADD);
            },
            |b| {
                b.load(xmm(register, true));
            },
        );
    }

    /// **Une moitié d'un registre de cent vingt-huit bits décalé de `shift`
    /// bits** (`0 < shift ≤ 128`, un multiple de huit), vers le haut si
    /// `left`. Ce qui sort d'une moitié entre dans l'autre.
    fn shifted_half(b: &mut Body, pair: (usize, usize), left: bool, shift: u64, high: bool) {
        let (low, top) = pair;
        if shift >= 128 {
            b.constant(0);
            return;
        }
        match (left, high, shift < 64) {
            (true, false, true) => {
                b.load(low).constant(shift).op(code::I64_SHL);
            }
            (true, false, false) | (false, true, false) => {
                b.constant(0);
            }
            (true, true, true) => {
                b.load(top)
                    .constant(shift)
                    .op(code::I64_SHL)
                    .load(low)
                    .constant(64 - shift)
                    .op(code::I64_SHR_U)
                    .op(code::I64_OR);
            }
            (true, true, false) => {
                b.load(low).constant(shift - 64).op(code::I64_SHL);
            }
            (false, false, true) => {
                b.load(low)
                    .constant(shift)
                    .op(code::I64_SHR_U)
                    .load(top)
                    .constant(64 - shift)
                    .op(code::I64_SHL)
                    .op(code::I64_OR);
            }
            (false, false, false) => {
                b.load(top).constant(shift - 64).op(code::I64_SHR_U);
            }
            (false, true, true) => {
                b.load(top).constant(shift).op(code::I64_SHR_U);
            }
        }
    }

    /// `movss`/`movsd` entre deux registres : la largeur basse de `from`
    /// entre dans `to`, le reste de `to` ne bouge pas.
    fn merge_scalar(from: u8, to: u8, width: Width, body: &mut Body) {
        let mask = width.mask();
        body.store(xmm(to, false), |b| {
            b.load(xmm(to, false))
                .constant(!mask)
                .op(code::I64_AND)
                .load(xmm(from, false))
                .constant(mask)
                .op(code::I64_AND)
                .op(code::I64_OR);
        });
    }

    /// **L'arithmétique entière voie par voie**, `RESULT = f(reg, SOURCE)`.
    fn lanes(lanes: Lanes, reg: u8, body: &mut Body) {
        let destination = (xmm(reg, false), xmm(reg, true));
        // Les deux voies d'indice `index` dans `FIRST` et `SECOND`, étendues
        // comme l'opération le demande.
        let operands = |b: &mut Body, index: u32, width: u32, signed: bool| {
            b.store(FIRST, |b| {
                b.lane(destination, index, width, signed);
            });
            b.store(SECOND, |b| {
                b.lane(SOURCE, index, width, signed);
            });
        };
        match lanes {
            Lanes::Add(lane) | Lanes::Sub(lane) => {
                let width = bits(lane);
                let add = matches!(lanes, Lanes::Add(_));
                body.build_lanes(width, |b, index| {
                    b.lane(destination, index, width, false);
                    b.lane(SOURCE, index, width, false);
                    b.op(if add { code::I64_ADD } else { code::I64_SUB });
                });
            }
            Lanes::AddSaturate { lane, signed } | Lanes::SubSaturate { lane, signed } => {
                let width = bits(lane);
                let add = matches!(lanes, Lanes::AddSaturate { .. });
                let (low, high) = if signed {
                    (-(1i64 << (width - 1)), (1i64 << (width - 1)) - 1)
                } else {
                    (0, (1i64 << width) - 1)
                };
                body.build_lanes(width, |b, index| {
                    b.store(HELD, |b| {
                        b.lane(destination, index, width, signed);
                        b.lane(SOURCE, index, width, signed);
                        b.op(if add { code::I64_ADD } else { code::I64_SUB });
                    });
                    b.clamp(low, high);
                });
            }
            Lanes::Equal(lane) | Lanes::Greater(lane) => {
                let width = bits(lane);
                let greater = matches!(lanes, Lanes::Greater(_));
                body.build_lanes(width, |b, index| {
                    b.pick(
                        |b| {
                            b.constant(u64::MAX);
                        },
                        |b| {
                            b.constant(0);
                        },
                        |b| {
                            b.lane(destination, index, width, greater);
                            b.lane(SOURCE, index, width, greater);
                            b.op(if greater {
                                code::I64_GT_S
                            } else {
                                code::I64_EQ
                            });
                        },
                    );
                });
            }
            Lanes::Minimum { lane, signed } | Lanes::Maximum { lane, signed } => {
                let width = bits(lane);
                let minimum = matches!(lanes, Lanes::Minimum { .. });
                body.build_lanes(width, |b, index| {
                    operands(b, index, width, signed);
                    b.pick(
                        |b| {
                            b.load(FIRST);
                        },
                        |b| {
                            b.load(SECOND);
                        },
                        |b| {
                            b.load(FIRST).load(SECOND).op(if minimum {
                                code::I64_LT_S
                            } else {
                                code::I64_GT_S
                            });
                        },
                    );
                });
            }
            Lanes::Average(lane) => {
                let width = bits(lane);
                body.build_lanes(width, |b, index| {
                    b.lane(destination, index, width, false);
                    b.lane(SOURCE, index, width, false);
                    b.op(code::I64_ADD)
                        .constant(1)
                        .op(code::I64_ADD)
                        .constant(1)
                        .op(code::I64_SHR_U);
                });
            }
            Lanes::MultiplyLow => {
                body.build_lanes(16, |b, index| {
                    b.lane(destination, index, 16, false);
                    b.lane(SOURCE, index, 16, false);
                    b.op(code::I64_MUL);
                });
            }
            Lanes::MultiplyHigh { signed } => {
                body.build_lanes(16, |b, index| {
                    b.lane(destination, index, 16, signed);
                    b.lane(SOURCE, index, 16, signed);
                    b.op(code::I64_MUL).constant(16).op(code::I64_SHR_S);
                });
            }
            Lanes::MultiplyUnsignedDwords => {
                body.build_lanes(64, |b, index| {
                    b.lane(destination, 2 * index, 32, false);
                    b.lane(SOURCE, 2 * index, 32, false);
                    b.op(code::I64_MUL);
                });
            }
            Lanes::MultiplyAdd => {
                body.build_lanes(32, |b, index| {
                    for word in [2 * index, 2 * index + 1] {
                        b.lane(destination, word, 16, true);
                        b.lane(SOURCE, word, 16, true);
                        b.op(code::I64_MUL);
                    }
                    b.op(code::I64_ADD);
                });
            }
            Lanes::SumOfDifferences => {
                body.build_lanes(64, |b, index| {
                    for byte in 8 * index..8 * index + 8 {
                        b.store(HELD, |b| {
                            b.lane(destination, byte, 8, false);
                            b.lane(SOURCE, byte, 8, false);
                            b.op(code::I64_SUB);
                        });
                        b.pick(
                            |b| {
                                b.load(HELD);
                            },
                            |b| {
                                b.constant(0).load(HELD).op(code::I64_SUB);
                            },
                            |b| {
                                b.load(HELD).constant(0).op(code::I64_GE_S);
                            },
                        );
                        if byte > 8 * index {
                            b.op(code::I64_ADD);
                        }
                    }
                });
            }
            Lanes::PackUnsignedBytes | Lanes::PackSignedBytes | Lanes::PackSignedWords => {
                // La moitié basse du résultat vient de la destination, la
                // haute de la source, chacune en entier.
                let (out, from, low, high) = match lanes {
                    Lanes::PackUnsignedBytes => (8, 16, 0, 255),
                    Lanes::PackSignedBytes => (8, 16, -128, 127),
                    _ => (16, 32, -32768, 32767),
                };
                let per_operand = 128 / from;
                body.build_lanes(out, |b, index| {
                    let pair = if index < per_operand {
                        destination
                    } else {
                        SOURCE
                    };
                    b.store(HELD, |b| {
                        b.lane(pair, index % per_operand, from, true);
                    });
                    b.clamp(low, high);
                });
            }
        }
    }
}
