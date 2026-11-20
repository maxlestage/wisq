//! **Le calcul flottant de SSE et SSE2**, que `x86_vector.rs` décode
//! (`Vector::Float`) : l'arithmétique scalaire et empaquetée, les
//! comparaisons (en masque ou en drapeaux) et les conversions.
//!
//! **Le mur qui l'a fait écrire.** Sous l'émetteur, Alpine démarré depuis son
//! ISO monte son média, puis s'arrête sur `f2 0f 2a 43 cc` — `cvtsi2sd
//! -0x34(%rbx),%xmm0` — dans un programme de l'espace utilisateur : le
//! premier calcul flottant de tout le démarrage. Le cœur Swift avait passé ce
//! mur à son heure (`Sources/WisqVM/X86Float.swift`) ; ce fichier en porte les
//! règles, que le silicium a fixées dans `Tests/Fixtures/x86-float-oracle.tsv`
//! et que `tests/x86_wasm.rs` rejoue sous JavaScriptCore.
//!
//! **Les NaN ne sont pas laissés à l'hôte.** WebAssembly laisse au moteur le
//! signe et la charge d'un NaN calculé, et un moteur sur ARM ne rend pas ce
//! qu'un moteur sur x86 rend (`0/0` donne `7ff8…` sur l'un, `fff8…` sur
//! l'autre). Les règles de x86 sont donc écrites ici, sur les bits :
//!
//! 1. si la destination est un NaN, c'est **elle** qui ressort, rendue
//!    silencieuse, sa charge gardée ;
//! 2. sinon, si la source en est un, c'est elle, de même ;
//! 3. sinon le calcul — et un NaN né de deux nombres (`inf - inf`, `0/0`, la
//!    racine d'un négatif) devient l'**indéfini réel**, le NaN négatif.
//!
//! `min` et `max` ne calculent pas : ils comparent et choisissent, et rendent
//! **la source**, bit pour bit, dès que la comparaison échoue (un NaN d'un
//! côté ou de l'autre, deux zéros de signes opposés). Une conversion vers un
//! entier qui ne tient pas rend l'**entier indéfini** (le bit de signe seul),
//! sans faute. Les conversions entre simples et doubles gardent le signe et
//! la charge d'un NaN, et le rendent silencieux.
//!
//! **Ce qui n'est pas modélisé, et c'est dit** : les bits d'exception de
//! MXCSR (aucune instruction d'ici ne les lève), son mode d'arrondi (tout
//! arrondit au plus proche, pair en cas d'égalité, comme MXCSR à l'allumage)
//! et ses bits DAZ et FTZ. Un programme qui change d'arrondi par `ldmxcsr`
//! serait servi au plus proche. Les formes de SSE3 (`haddps`…) ne sont pas
//! lues : CPUID ne les annonce pas.
//!
//! **Une instruction qui faute n'a rien fait** : les opérandes en mémoire
//! sont lus dans des cases de travail avant qu'un registre change, comme
//! dans `x86_wasm_vector.rs`.

use super::vector::xmm;
use super::{code, Body, Module, RFLAGS_SLOT, SCRATCH_SLOT};
use crate::x86::{Decoded, Float, FloatOp, Width};

/// Les opcodes flottants de WebAssembly dont ce fichier se sert.
mod f {
    pub const F32_EQ: u8 = 0x5b;
    pub const F32_NE: u8 = 0x5c;
    pub const F32_LT: u8 = 0x5d;
    pub const F32_GT: u8 = 0x5e;
    pub const F32_LE: u8 = 0x5f;
    pub const F64_EQ: u8 = 0x61;
    pub const F64_NE: u8 = 0x62;
    pub const F64_LT: u8 = 0x63;
    pub const F64_GT: u8 = 0x64;
    pub const F64_LE: u8 = 0x65;
    pub const F64_GE: u8 = 0x66;
    pub const F32_SQRT: u8 = 0x91;
    pub const F32_ADD: u8 = 0x92;
    pub const F32_SUB: u8 = 0x93;
    pub const F32_MUL: u8 = 0x94;
    pub const F32_DIV: u8 = 0x95;
    pub const F64_TRUNC: u8 = 0x9d;
    pub const F64_NEAREST: u8 = 0x9e;
    pub const F64_SQRT: u8 = 0x9f;
    pub const F64_ADD: u8 = 0xa0;
    pub const F64_SUB: u8 = 0xa1;
    pub const F64_MUL: u8 = 0xa2;
    pub const F64_DIV: u8 = 0xa3;
    pub const I64_TRUNC_F64_S: u8 = 0xb0;
    pub const F32_CONVERT_I32_S: u8 = 0xb2;
    pub const F32_CONVERT_I64_S: u8 = 0xb4;
    pub const F32_DEMOTE_F64: u8 = 0xb6;
    pub const F64_CONVERT_I32_S: u8 = 0xb7;
    pub const F64_CONVERT_I64_S: u8 = 0xb9;
    pub const F64_PROMOTE_F32: u8 = 0xbb;
    pub const I32_REINTERPRET_F32: u8 = 0xbc;
    pub const I64_REINTERPRET_F64: u8 = 0xbd;
    pub const F32_REINTERPRET_I32: u8 = 0xbe;
    pub const F64_REINTERPRET_I64: u8 = 0xbf;
}

/// Les cases de travail : la source entière (deux moitiés), le résultat
/// entier, les deux opérandes d'un élément, le calcul, et une case de plus.
/// Les mêmes que `x86_wasm_vector.rs` pour les six premières.
const SOURCE: (usize, usize) = (SCRATCH_SLOT, SCRATCH_SLOT + 1);
const RESULT: (usize, usize) = (SCRATCH_SLOT + 2, SCRATCH_SLOT + 3);
const LEFT: usize = SCRATCH_SLOT + 4;
const RIGHT: usize = SCRATCH_SLOT + 5;
const COMPUTED: usize = SCRATCH_SLOT + 6;
const HELD: usize = SCRATCH_SLOT + 8;

/// Les bits RFLAGS qu'une comparaison ordonnée écrit ou efface : CF, PF, AF,
/// ZF, SF et OF.
const ORDER_FLAGS: u64 = 0x8d5;

/// **Simple ou double** : la largeur d'un élément, et ses constantes.
#[derive(Clone, Copy)]
struct Kind {
    double: bool,
}

impl Kind {
    /// Les bits d'un élément.
    fn mask(self) -> u64 {
        if self.double {
            u64::MAX
        } else {
            0xffff_ffff
        }
    }
    /// Sans le signe.
    fn magnitude(self) -> u64 {
        if self.double {
            0x7fff_ffff_ffff_ffff
        } else {
            0x7fff_ffff
        }
    }
    /// L'infini positif : un élément dont la grandeur est au-dessus est un NaN.
    fn infinity(self) -> u64 {
        if self.double {
            0x7ff0_0000_0000_0000
        } else {
            0x7f80_0000
        }
    }
    /// Le bit qui rend un NaN silencieux.
    fn quiet(self) -> u64 {
        if self.double {
            0x0008_0000_0000_0000
        } else {
            0x0040_0000
        }
    }
    /// L'indéfini réel : le NaN que x86 fabrique d'une opération invalide.
    fn indefinite(self) -> u64 {
        if self.double {
            0xfff8_0000_0000_0000
        } else {
            0xffc0_0000
        }
    }
    fn width(self) -> Width {
        if self.double {
            Width::Qword
        } else {
            Width::Dword
        }
    }
    fn bits(self) -> u64 {
        if self.double {
            64
        } else {
            32
        }
    }
}

/// `2³¹` et `2⁶³` en double : la borne d'une conversion vers un entier.
const TWO_TO_31: u64 = 0x41e0_0000_0000_0000;
const MINUS_TWO_TO_31: u64 = 0xc1e0_0000_0000_0000;
const TWO_TO_63: u64 = 0x43e0_0000_0000_0000;
const MINUS_TWO_TO_63: u64 = 0xc3e0_0000_0000_0000;

impl Body {
    /// Des bits (un `i64`, dont seuls les bas comptent pour un simple) vers le
    /// flottant qu'ils portent.
    fn as_float(&mut self, kind: Kind) -> &mut Self {
        if kind.double {
            self.op(f::F64_REINTERPRET_I64)
        } else {
            self.op(code::I32_WRAP_I64).op(f::F32_REINTERPRET_I32)
        }
    }

    /// Un flottant vers ses bits, en `i64` étendu par zéro.
    fn as_bits(&mut self, kind: Kind) -> &mut Self {
        if kind.double {
            self.op(f::I64_REINTERPRET_F64)
        } else {
            self.op(f::I32_REINTERPRET_F32).op(code::I64_EXTEND_I32_U)
        }
    }

    /// `1` si la case porte un NaN (ses bits d'élément déjà masqués).
    fn is_nan(&mut self, kind: Kind, slot: usize) -> &mut Self {
        self.load(slot)
            .constant(kind.magnitude())
            .op(code::I64_AND)
            .constant(kind.infinity())
            .op(code::I64_GT_U)
    }

    /// La case, rendue silencieuse.
    fn quieted(&mut self, kind: Kind, slot: usize) -> &mut Self {
        self.load(slot).constant(kind.quiet()).op(code::I64_OR)
    }

    /// `then` si la condition que `test` pousse tient, sinon `otherwise`,
    /// sans branchement.
    fn either(
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

    /// Les deux cases comme flottants, comparées par `simple`/`double`.
    fn compared(&mut self, kind: Kind, single: u8, double: u8) -> &mut Self {
        self.load(LEFT)
            .as_float(kind)
            .load(RIGHT)
            .as_float(kind)
            .op(if kind.double { double } else { single })
    }

    /// **Les trois règles des NaN**, autour du calcul que `compute` pousse
    /// (des bits) : `LEFT` et `RIGHT` portent les deux éléments, masqués.
    fn nan_rules(&mut self, kind: Kind, compute: impl FnOnce(&mut Body)) -> &mut Self {
        self.store(COMPUTED, compute);
        self.either(
            |b| {
                b.quieted(kind, LEFT);
            },
            |b| {
                b.either(
                    |b| {
                        b.quieted(kind, RIGHT);
                    },
                    |b| {
                        b.either(
                            |b| {
                                b.constant(kind.indefinite());
                            },
                            |b| {
                                b.load(COMPUTED);
                            },
                            |b| {
                                b.is_nan(kind, COMPUTED);
                            },
                        );
                    },
                    |b| {
                        b.is_nan(kind, RIGHT);
                    },
                );
            },
            |b| {
                b.is_nan(kind, LEFT);
            },
        )
    }

    /// **Un élément de `LEFT op RIGHT`**, poussé en bits.
    fn element(&mut self, kind: Kind, operation: FloatOp) -> &mut Self {
        let arithmetic = |single: u8, double: u8| {
            move |b: &mut Body| {
                b.load(LEFT)
                    .as_float(kind)
                    .load(RIGHT)
                    .as_float(kind)
                    .op(if kind.double { double } else { single })
                    .as_bits(kind);
            }
        };
        match operation {
            FloatOp::Add => self.nan_rules(kind, arithmetic(f::F32_ADD, f::F64_ADD)),
            FloatOp::Sub => self.nan_rules(kind, arithmetic(f::F32_SUB, f::F64_SUB)),
            FloatOp::Mul => self.nan_rules(kind, arithmetic(f::F32_MUL, f::F64_MUL)),
            FloatOp::Div => self.nan_rules(kind, arithmetic(f::F32_DIV, f::F64_DIV)),
            // **`min` et `max` choisissent**, rien n'est calculé : la
            // destination si la comparaison la garde, la source sinon.
            FloatOp::Min | FloatOp::Max => self.either(
                |b| {
                    b.load(LEFT);
                },
                |b| {
                    b.load(RIGHT);
                },
                |b| {
                    if operation == FloatOp::Min {
                        b.compared(kind, f::F32_LT, f::F64_LT);
                    } else {
                        b.compared(kind, f::F32_GT, f::F64_GT);
                    }
                },
            ),
            // **La racine ne regarde que la source** : la destination n'entre
            // pas dans la règle des NaN.
            FloatOp::Sqrt => {
                self.store(COMPUTED, |b| {
                    b.load(RIGHT)
                        .as_float(kind)
                        .op(if kind.double {
                            f::F64_SQRT
                        } else {
                            f::F32_SQRT
                        })
                        .as_bits(kind);
                });
                self.either(
                    |b| {
                        b.quieted(kind, RIGHT);
                    },
                    |b| {
                        b.either(
                            |b| {
                                b.constant(kind.indefinite());
                            },
                            |b| {
                                b.load(COMPUTED);
                            },
                            |b| {
                                b.is_nan(kind, COMPUTED);
                            },
                        );
                    },
                    |b| {
                        b.is_nan(kind, RIGHT);
                    },
                )
            }
        }
    }

    /// **Le prédicat de `cmpss`… `cmppd`**, ses trois bits bas, en masque :
    /// l'élément tout à un s'il tient, tout à zéro sinon. Les quatre premiers
    /// sont faux sur un NaN, les quatre suivants sont leurs négations.
    fn predicate(&mut self, kind: Kind, code: u64) -> &mut Self {
        let unordered = |b: &mut Body| {
            b.is_nan(kind, LEFT).is_nan(kind, RIGHT).op(code::I32_OR);
        };
        self.either(
            |b| {
                b.constant(kind.mask());
            },
            |b| {
                b.constant(0);
            },
            |b| match code & 7 {
                0 => {
                    b.compared(kind, f::F32_EQ, f::F64_EQ);
                }
                1 => {
                    b.compared(kind, f::F32_LT, f::F64_LT);
                }
                2 => {
                    b.compared(kind, f::F32_LE, f::F64_LE);
                }
                3 => unordered(b),
                4 => {
                    b.compared(kind, f::F32_NE, f::F64_NE);
                }
                5 => {
                    b.compared(kind, f::F32_LT, f::F64_LT).op(code::I32_EQZ);
                }
                6 => {
                    b.compared(kind, f::F32_LE, f::F64_LE).op(code::I32_EQZ);
                }
                _ => {
                    unordered(b);
                    b.op(code::I32_EQZ);
                }
            },
        )
    }

    /// **Un simple de `RIGHT` élargi en double**, poussé en bits. Un NaN
    /// garde son signe et sa charge, montée de vingt-neuf bits, et devient
    /// silencieux.
    fn widened(&mut self) -> &mut Self {
        let single = Kind { double: false };
        self.either(
            |b| {
                b.load(RIGHT)
                    .constant(0x8000_0000)
                    .op(code::I64_AND)
                    .constant(32)
                    .op(code::I64_SHL)
                    .constant(0x7ff8_0000_0000_0000)
                    .op(code::I64_OR)
                    .load(RIGHT)
                    .constant(0x007f_ffff)
                    .op(code::I64_AND)
                    .constant(29)
                    .op(code::I64_SHL)
                    .op(code::I64_OR);
            },
            |b| {
                b.load(RIGHT)
                    .as_float(single)
                    .op(f::F64_PROMOTE_F32)
                    .op(f::I64_REINTERPRET_F64);
            },
            |b| {
                b.is_nan(single, RIGHT);
            },
        )
    }

    /// **Un double de `RIGHT` ramené en simple**, poussé en bits (les trente-
    /// deux bas). Un NaN garde son signe et le haut de sa charge.
    fn narrowed(&mut self) -> &mut Self {
        let double = Kind { double: true };
        self.either(
            |b| {
                b.load(RIGHT)
                    .constant(32)
                    .op(code::I64_SHR_U)
                    .constant(0x8000_0000)
                    .op(code::I64_AND)
                    .constant(0x7fc0_0000)
                    .op(code::I64_OR)
                    .load(RIGHT)
                    .constant(0x000f_ffff_ffff_ffff)
                    .op(code::I64_AND)
                    .constant(29)
                    .op(code::I64_SHR_U)
                    .op(code::I64_OR);
            },
            |b| {
                b.load(RIGHT)
                    .op(f::F64_REINTERPRET_I64)
                    .op(f::F32_DEMOTE_F64)
                    .op(f::I32_REINTERPRET_F32)
                    .op(code::I64_EXTEND_I32_U);
            },
            |b| {
                b.is_nan(double, RIGHT);
            },
        )
    }

    /// **L'élément de `RIGHT` vers un entier signé de `wide` (64) ou 32
    /// bits**, tronqué ou arrondi au plus proche, poussé étendu par zéro.
    /// Ce qui ne tient pas — un NaN, un infini, un nombre trop grand — rend
    /// l'entier indéfini. La conversion de WebAssembly trappe hors de sa
    /// portée : elle ne voit donc jamais que zéro à la place.
    fn to_integer(&mut self, kind: Kind, truncate: bool, wide: bool) -> &mut Self {
        let (low, high, indefinite) = if wide {
            (MINUS_TWO_TO_63, TWO_TO_63, 0x8000_0000_0000_0000)
        } else {
            (MINUS_TWO_TO_31, TWO_TO_31, 0x8000_0000)
        };
        self.store(COMPUTED, |b| {
            b.load(RIGHT).as_float(kind);
            if !kind.double {
                b.op(f::F64_PROMOTE_F32);
            }
            b.op(if truncate {
                f::F64_TRUNC
            } else {
                f::F64_NEAREST
            })
            .op(f::I64_REINTERPRET_F64);
        });
        // La valeur arrondie tient-elle ? Un NaN rend faux aux deux.
        self.store(HELD, |b| {
            b.load(COMPUTED)
                .op(f::F64_REINTERPRET_I64)
                .constant(low)
                .op(f::F64_REINTERPRET_I64)
                .op(f::F64_GE)
                .load(COMPUTED)
                .op(f::F64_REINTERPRET_I64)
                .constant(high)
                .op(f::F64_REINTERPRET_I64)
                .op(f::F64_LT)
                .op(code::I32_AND)
                .op(code::I64_EXTEND_I32_U);
        });
        self.either(
            |b| {
                b.either(
                    |b| {
                        b.load(COMPUTED);
                    },
                    |b| {
                        b.constant(0);
                    },
                    |b| {
                        b.load(HELD).op(code::I32_WRAP_I64);
                    },
                )
                .op(f::F64_REINTERPRET_I64)
                .op(f::I64_TRUNC_F64_S);
                if !wide {
                    b.constant(0xffff_ffff).op(code::I64_AND);
                }
            },
            |b| {
                b.constant(indefinite);
            },
            |b| {
                b.load(HELD).op(code::I32_WRAP_I64);
            },
        )
    }

    /// **Un entier signé de `RIGHT`** (`wide` : soixante-quatre bits, sinon
    /// les trente-deux bas) vers un flottant, au plus proche, poussé en bits.
    fn from_integer(&mut self, kind: Kind, wide: bool) -> &mut Self {
        self.load(RIGHT);
        if !wide {
            self.op(code::I32_WRAP_I64).op(match kind.double {
                true => f::F64_CONVERT_I32_S,
                false => f::F32_CONVERT_I32_S,
            });
        } else {
            self.op(match kind.double {
                true => f::F64_CONVERT_I64_S,
                false => f::F32_CONVERT_I64_S,
            });
        }
        self.as_bits(kind)
    }

    /// Poser dans `slot` l'élément `index` (de `bits` bits) d'une moitié
    /// gardée dans `from`, étendu par zéro.
    fn take(&mut self, slot: usize, from: usize, index: u64, bits: u64) -> &mut Self {
        self.store(slot, |b| {
            b.load(from);
            if index > 0 {
                b.constant(index * bits).op(code::I64_SHR_U);
            }
            if bits < 64 {
                b.constant((1u64 << bits) - 1).op(code::I64_AND);
            }
        })
    }

    /// **Bâtir une moitié de `RESULT`** élément par élément : `value` pousse
    /// l'élément `index` (masqué à `bits`), après avoir posé ses opérandes.
    fn build_half(
        &mut self,
        slot: usize,
        bits: u64,
        mut value: impl FnMut(&mut Body, u64),
    ) -> &mut Self {
        let count = 64 / bits;
        for index in 0..count {
            value(self, index);
            if index > 0 {
                self.constant(index * bits)
                    .op(code::I64_SHL)
                    .load(slot)
                    .op(code::I64_OR);
            }
            self.store(slot, |_| {});
        }
        self
    }
}

impl Module {
    /// **La source entière** (seize octets de la mémoire, ou le XMM `rm`)
    /// dans `SOURCE`.
    fn float_source(step: &Decoded, body: &mut Body) {
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

    /// **La moitié basse de la source** — `bytes` octets de la mémoire, ou le
    /// bas du XMM `rm` masqué à la même largeur — dans `SOURCE.0`.
    fn float_low_source(step: &Decoded, body: &mut Body, width: Width) {
        body.store(SOURCE.0, |b| match &step.memory {
            Some(address) => {
                b.load_memory(address, width);
            }
            None => {
                b.load(xmm(step.src, false))
                    .constant(width.mask())
                    .op(code::I64_AND);
            }
        });
    }

    /// Poser `RESULT` dans le XMM `reg`.
    fn float_commit(register: u8, body: &mut Body) {
        body.store(xmm(register, false), |b| {
            b.load(RESULT.0);
        });
        body.store(xmm(register, true), |b| {
            b.load(RESULT.1);
        });
    }

    /// **L'élément bas du XMM `reg` remplacé** par la valeur que `value`
    /// pousse (de la largeur de `kind`), le reste du registre laissé.
    fn float_scalar_result(
        register: u8,
        kind: Kind,
        body: &mut Body,
        value: impl FnOnce(&mut Body),
    ) {
        body.store(HELD, value);
        body.store(xmm(register, false), |b| {
            if kind.double {
                b.load(HELD);
            } else {
                b.load(xmm(register, false))
                    .constant(!0xffff_ffffu64)
                    .op(code::I64_AND)
                    .load(HELD)
                    .op(code::I64_OR);
            }
        });
    }

    /// **Traduire une instruction flottante.** Toutes les formes que le
    /// décodeur lit se traduisent : le balayage de `tests/x86_wasm.rs` le
    /// vérifie.
    pub(super) fn float(float: Float, step: &Decoded, body: &mut Body) -> Option<()> {
        let reg = step.dst;
        match float {
            Float::Scalar { operation, double } => {
                let kind = Kind { double };
                Self::float_low_source(step, body, kind.width());
                body.store(RIGHT, |b| {
                    b.load(SOURCE.0);
                });
                body.store(LEFT, |b| {
                    b.load(xmm(reg, false))
                        .constant(kind.mask())
                        .op(code::I64_AND);
                });
                Self::float_scalar_result(reg, kind, body, |b| {
                    b.element(kind, operation);
                });
            }
            Float::Packed { operation, double } => {
                let kind = Kind { double };
                Self::float_source(step, body);
                for (half, out) in [(false, RESULT.0), (true, RESULT.1)] {
                    let source = if half { SOURCE.1 } else { SOURCE.0 };
                    body.build_half(out, kind.bits(), |b, index| {
                        b.take(LEFT, xmm(reg, half), index, kind.bits());
                        b.take(RIGHT, source, index, kind.bits());
                        b.element(kind, operation);
                    });
                }
                Self::float_commit(reg, body);
            }
            Float::CompareScalar { double } => {
                let kind = Kind { double };
                Self::float_low_source(step, body, kind.width());
                body.store(RIGHT, |b| {
                    b.load(SOURCE.0);
                });
                body.store(LEFT, |b| {
                    b.load(xmm(reg, false))
                        .constant(kind.mask())
                        .op(code::I64_AND);
                });
                Self::float_scalar_result(reg, kind, body, |b| {
                    b.predicate(kind, step.imm);
                });
            }
            Float::ComparePacked { double } => {
                let kind = Kind { double };
                Self::float_source(step, body);
                for (half, out) in [(false, RESULT.0), (true, RESULT.1)] {
                    let source = if half { SOURCE.1 } else { SOURCE.0 };
                    body.build_half(out, kind.bits(), |b, index| {
                        b.take(LEFT, xmm(reg, half), index, kind.bits());
                        b.take(RIGHT, source, index, kind.bits());
                        b.predicate(kind, step.imm);
                    });
                }
                Self::float_commit(reg, body);
            }
            // **Les seules instructions flottantes qui écrivent les
            // drapeaux.** Non ordonnée : ZF, PF et CF ; égale : ZF ; plus
            // petite : CF ; plus grande : rien. OF, SF et AF effacés.
            Float::Order { double } => {
                let kind = Kind { double };
                Self::float_low_source(step, body, kind.width());
                body.store(RIGHT, |b| {
                    b.load(SOURCE.0);
                });
                body.store(LEFT, |b| {
                    b.load(xmm(reg, false))
                        .constant(kind.mask())
                        .op(code::I64_AND);
                });
                body.store(HELD, |b| {
                    b.is_nan(kind, LEFT)
                        .is_nan(kind, RIGHT)
                        .op(code::I32_OR)
                        .op(code::I64_EXTEND_I32_U);
                });
                body.store(RFLAGS_SLOT, |b| {
                    b.load(RFLAGS_SLOT).constant(!ORDER_FLAGS).op(code::I64_AND);
                    // ZF : non ordonnée, ou égale.
                    b.load(HELD)
                        .compared(kind, f::F32_EQ, f::F64_EQ)
                        .op(code::I64_EXTEND_I32_U)
                        .op(code::I64_OR)
                        .constant(6)
                        .op(code::I64_SHL)
                        .op(code::I64_OR);
                    // PF : non ordonnée.
                    b.load(HELD).constant(2).op(code::I64_SHL).op(code::I64_OR);
                    // CF : non ordonnée, ou plus petite.
                    b.load(HELD)
                        .compared(kind, f::F32_LT, f::F64_LT)
                        .op(code::I64_EXTEND_I32_U)
                        .op(code::I64_OR)
                        .op(code::I64_OR);
                });
            }
            Float::Widen => {
                Self::float_low_source(step, body, Width::Dword);
                body.store(RIGHT, |b| {
                    b.load(SOURCE.0);
                });
                Self::float_scalar_result(reg, Kind { double: true }, body, |b| {
                    b.widened();
                });
            }
            Float::Narrow => {
                Self::float_low_source(step, body, Width::Qword);
                body.store(RIGHT, |b| {
                    b.load(SOURCE.0);
                });
                Self::float_scalar_result(reg, Kind { double: false }, body, |b| {
                    b.narrowed();
                });
            }
            Float::FromInteger { double } => {
                let wide = step.width == Width::Qword;
                body.store(RIGHT, |b| match &step.memory {
                    Some(address) => {
                        b.load_memory(address, step.width);
                    }
                    None => {
                        b.load(Self::slot(step.src));
                    }
                });
                let kind = Kind { double };
                Self::float_scalar_result(reg, kind, body, |b| {
                    b.from_integer(kind, wide);
                });
            }
            Float::ToInteger { double, truncate } => {
                let kind = Kind { double };
                let wide = step.width == Width::Qword;
                Self::float_low_source(step, body, kind.width());
                body.store(RIGHT, |b| {
                    b.load(SOURCE.0);
                });
                body.store(Self::slot(reg), |b| {
                    b.to_integer(kind, truncate, wide);
                });
            }
            // `cvtps2pd` : les deux simples du bas, huit octets lus.
            Float::PackedWiden => {
                Self::float_low_source(step, body, Width::Qword);
                for (index, out) in [(0, RESULT.0), (1, RESULT.1)] {
                    body.take(RIGHT, SOURCE.0, index, 32);
                    body.store(out, |b| {
                        b.widened();
                    });
                }
                Self::float_commit(reg, body);
            }
            // `cvtpd2ps` : deux doubles en deux simples, le haut effacé.
            Float::PackedNarrow => {
                Self::float_source(step, body);
                body.build_half(RESULT.0, 32, |b, index| {
                    b.store(RIGHT, |b| {
                        b.load(if index == 0 { SOURCE.0 } else { SOURCE.1 });
                    });
                    b.narrowed();
                });
                body.store(RESULT.1, |b| {
                    b.constant(0);
                });
                Self::float_commit(reg, body);
            }
            // `cvtdq2pd` : deux entiers de trente-deux bits, exacts en double.
            Float::FromIntegers { double: true } => {
                Self::float_low_source(step, body, Width::Qword);
                let kind = Kind { double: true };
                for (index, out) in [(0, RESULT.0), (1, RESULT.1)] {
                    body.take(RIGHT, SOURCE.0, index, 32);
                    body.store(out, |b| {
                        b.from_integer(kind, false);
                    });
                }
                Self::float_commit(reg, body);
            }
            // `cvtdq2ps` : quatre entiers en quatre simples, au plus proche.
            Float::FromIntegers { double: false } => {
                Self::float_source(step, body);
                let kind = Kind { double: false };
                for (source, out) in [(SOURCE.0, RESULT.0), (SOURCE.1, RESULT.1)] {
                    body.build_half(out, 32, |b, index| {
                        b.take(RIGHT, source, index, 32);
                        b.from_integer(kind, false);
                    });
                }
                Self::float_commit(reg, body);
            }
            // `cvt(t)pd2dq` : deux doubles en deux entiers, le haut effacé.
            Float::ToIntegers {
                double: true,
                truncate,
            } => {
                Self::float_source(step, body);
                let kind = Kind { double: true };
                body.build_half(RESULT.0, 32, |b, index| {
                    b.store(RIGHT, |b| {
                        b.load(if index == 0 { SOURCE.0 } else { SOURCE.1 });
                    });
                    b.to_integer(kind, truncate, false);
                });
                body.store(RESULT.1, |b| {
                    b.constant(0);
                });
                Self::float_commit(reg, body);
            }
            // `cvt(t)ps2dq` : quatre simples en quatre entiers.
            Float::ToIntegers {
                double: false,
                truncate,
            } => {
                Self::float_source(step, body);
                let kind = Kind { double: false };
                for (source, out) in [(SOURCE.0, RESULT.0), (SOURCE.1, RESULT.1)] {
                    body.build_half(out, 32, |b, index| {
                        b.take(RIGHT, source, index, 32);
                        b.to_integer(kind, truncate, false);
                    });
                }
                Self::float_commit(reg, body);
            }
        }
        Some(())
    }
}
