//! **Le MMX** — le port de `X86MMX.swift` : les instructions entières sur
//! soixante-quatre bits, sans préfixe, et les ponts avec les XMM.
//!
//! **Les registres MMX sont la pile du x87.** MMn est la mantisse du registre
//! physique n. Toute instruction MMX, sauf `emms`, remet le sommet à zéro et
//! marque les huit registres occupés ; écrire MMn met son exposant à tout-un.
//! C'est ce que fait le silicium, et ce que `fxsave` rend ensuite.
//!
//! Le juge est `x86-mmx-oracle.tsv`, relevé sur le silicium et rejoué par
//! `tests/x86_float_oracle.rs`. Les formes de SSSE3 (`pshufb`, `phaddw`,
//! `palignr`…) que le corpus porte aussi restent illisibles : CPUID ne les
//! annonce pas.

use super::{Extended, ExtendedFault, Extra};
use crate::x86::{Cpu, Width};
use crate::x86_paging::Access;

/// Une instruction MMX. Les champs d'`Extended` : `reg` le MMX (ou le
/// registre général, ou le XMM) du champ `reg`, `rm` celui du champ `rm`,
/// `memory` l'opérande en mémoire, `imm` l'immédiat, `width` quatre ou huit
/// octets pour `movd`/`movq`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mmx {
    /// Un calcul à deux opérandes, `mm = f(mm, mm/m64)` : l'octet d'opcode
    /// nomme le calcul (`0F 60`… `0F FE`).
    Lanes(u8),
    /// `movd`/`movq` d'un registre général ou de la mémoire vers un MMX
    /// (`0F 6E`).
    MoveIn,
    /// `movd`/`movq` d'un MMX vers un registre général ou la mémoire
    /// (`0F 7E`).
    MoveOut,
    /// `movq mm, mm/m64` (`0F 6F`).
    Load,
    /// `movq mm/m64, mm` (`0F 7F`), et `movntq m64, mm` (`0F E7`).
    Store,
    /// Les décalages par immédiat (`0F 71`/`72`/`73`) : la largeur de voie,
    /// et le champ `reg` — 2 à droite, 4 arithmétique, 6 à gauche.
    ShiftImmediate { lane: Width, kind: u8 },
    /// `pmovmskb r32, mm` (`0F D7`).
    MoveMask,
    /// `pinsrw mm, r32/m16, imm8` (`0F C4`).
    InsertWord,
    /// `pextrw r32, mm, imm8` (`0F C5`).
    ExtractWord,
    /// `pshufw mm, mm/m64, imm8` (`0F 70`).
    ShuffleWords,
    /// `maskmovq mm, mm` (`0F F7`) : les octets choisis par le bit fort du
    /// masque, rangés à `[RDI]`.
    MaskedStore,
    /// `movdq2q mm, xmm` (`F2 0F D6`).
    FromXmm,
    /// `movq2dq xmm, mm` (`F3 0F D6`).
    ToXmm,
}

/// **Décoder une forme MMX de la page `0f`**, `second` lu, `mandatory` le
/// préfixe obligatoire, `register` vrai quand le ModRM désigne un registre.
/// Rend la forme et si elle lit un immédiat.
pub(super) fn decode(mandatory: u8, second: u8, modrm: u8) -> Option<(Mmx, bool)> {
    let register = modrm >> 6 == 0b11;
    let field = (modrm >> 3) & 7;
    let form = match (mandatory, second) {
        (0xf2, 0xd6) if register => Mmx::FromXmm,
        (0xf3, 0xd6) if register => Mmx::ToXmm,
        (0, 0x6e) => Mmx::MoveIn,
        (0, 0x7e) => Mmx::MoveOut,
        (0, 0x6f) => Mmx::Load,
        (0, 0x7f) => Mmx::Store,
        (0, 0xe7) if !register => Mmx::Store,
        (0, 0x71..=0x73) if register => {
            let lane = match second {
                0x71 => Width::Word,
                0x72 => Width::Dword,
                _ => Width::Qword,
            };
            if !(field == 2 || field == 6 || (field == 4 && second != 0x73)) {
                return None;
            }
            Mmx::ShiftImmediate { lane, kind: field }
        }
        (0, 0xd7) if register => Mmx::MoveMask,
        (0, 0xc4) => Mmx::InsertWord,
        (0, 0xc5) if register => Mmx::ExtractWord,
        (0, 0x70) => Mmx::ShuffleWords,
        (0, 0xf7) if register => Mmx::MaskedStore,
        (
            0,
            0x60..=0x6b
            | 0x74..=0x76
            | 0xd1..=0xd5
            | 0xd8..=0xdf
            | 0xe0..=0xe5
            | 0xe8..=0xef
            | 0xf1..=0xf6
            | 0xf8..=0xfe,
        ) => Mmx::Lanes(second),
        _ => return None,
    };
    let immediate = matches!(
        form,
        Mmx::ShiftImmediate { .. } | Mmx::InsertWord | Mmx::ExtractWord | Mmx::ShuffleWords
    );
    Some((form, immediate))
}

/// `operation` voie par voie, sur des voies de `bytes` octets.
fn zip(a: u64, b: u64, bytes: u32, operation: impl Fn(u64, u64) -> u64) -> u64 {
    let bits = 8 * bytes;
    let mask = if bits == 64 {
        u64::MAX
    } else {
        (1u64 << bits) - 1
    };
    (0..64 / bits).fold(0u64, |out, index| {
        let shift = index * bits;
        out | ((operation((a >> shift) & mask, (b >> shift) & mask) & mask) << shift)
    })
}

/// Une voie de `bits` bits, lue signée.
fn signed(value: u64, bits: u32) -> i64 {
    ((value << (64 - bits)) as i64) >> (64 - bits)
}

fn clamp(value: i64, low: i64, high: i64) -> u64 {
    value.clamp(low, high) as u64
}

/// Un décalage de chaque voie : `kind` 2 logique à droite, 4 arithmétique,
/// 6 à gauche. Un compte au-delà de la largeur rend zéro — ou le signe étalé.
fn shift(value: u64, count: u64, bytes: u32, kind: u8) -> u64 {
    let bits = u64::from(8 * bytes);
    zip(value, 0, bytes, |lane, _| match kind {
        2 if count >= bits => 0,
        2 => lane >> count,
        6 if count >= bits => 0,
        6 => lane << count,
        _ => (signed(lane, bits as u32) >> count.min(bits - 1)) as u64,
    })
}

/// Entrelacer les voies des moitiés basses (ou hautes) de `a` et `b`.
fn unpack(a: u64, b: u64, bytes: u32, high: bool) -> u64 {
    let bits = 8 * bytes;
    let mask = (1u64 << bits) - 1;
    let half = 32 / bits;
    (0..half).fold(0u64, |out, index| {
        let from = (if high { half + index } else { index }) * bits;
        out | (((a >> from) & mask) << (2 * index * bits))
            | (((b >> from) & mask) << ((2 * index + 1) * bits))
    })
}

/// Les voies de `a` puis de `b`, saturées en voies deux fois plus étroites.
fn pack(a: u64, b: u64, bytes: u32, unsigned: bool) -> u64 {
    let bits = 8 * bytes;
    let narrow = bits / 2;
    let (low, high) = if unsigned {
        (0, (1i64 << narrow) - 1)
    } else {
        (-(1i64 << (narrow - 1)), (1i64 << (narrow - 1)) - 1)
    };
    let mask = (1u64 << narrow) - 1;
    let count = 64 / bits;
    let mut out = 0u64;
    for (part, value) in [a, b].into_iter().enumerate() {
        for index in 0..count {
            let lane = signed(value >> (index * bits), bits);
            out |= (clamp(lane, low, high) & mask) << ((part as u32 * count + index) * narrow);
        }
    }
    out
}

/// **Les calculs à deux opérandes**, par l'octet d'opcode.
pub(super) fn lanes(opcode: u8, a: u64, b: u64) -> u64 {
    match opcode {
        0x60 => unpack(a, b, 1, false),
        0x61 => unpack(a, b, 2, false),
        0x62 => unpack(a, b, 4, false),
        0x68 => unpack(a, b, 1, true),
        0x69 => unpack(a, b, 2, true),
        0x6a => unpack(a, b, 4, true),
        0x63 => pack(a, b, 2, false),
        0x6b => pack(a, b, 4, false),
        0x67 => pack(a, b, 2, true),
        // Les comparaisons : tout à un ou tout à zéro par voie.
        0x74..=0x76 => {
            let bytes = 1 << (opcode - 0x74);
            zip(a, b, bytes, |x, y| if x == y { u64::MAX } else { 0 })
        }
        0x64..=0x66 => {
            let bytes = 1u32 << (opcode - 0x64);
            zip(a, b, bytes, |x, y| {
                if signed(x, 8 * bytes) > signed(y, 8 * bytes) {
                    u64::MAX
                } else {
                    0
                }
            })
        }
        // Les décalages par registre : le compte est la source entière.
        0xd1 => shift(a, b, 2, 2),
        0xd2 => shift(a, b, 4, 2),
        0xd3 => shift(a, b, 8, 2),
        0xe1 => shift(a, b, 2, 4),
        0xe2 => shift(a, b, 4, 4),
        0xf1 => shift(a, b, 2, 6),
        0xf2 => shift(a, b, 4, 6),
        0xf3 => shift(a, b, 8, 6),
        0xfc => zip(a, b, 1, u64::wrapping_add),
        0xfd => zip(a, b, 2, u64::wrapping_add),
        0xfe => zip(a, b, 4, u64::wrapping_add),
        0xd4 => a.wrapping_add(b),
        0xf8 => zip(a, b, 1, u64::wrapping_sub),
        0xf9 => zip(a, b, 2, u64::wrapping_sub),
        0xfa => zip(a, b, 4, u64::wrapping_sub),
        0xfb => a.wrapping_sub(b),
        0xec => zip(a, b, 1, |x, y| {
            clamp(signed(x, 8) + signed(y, 8), -128, 127)
        }),
        0xed => zip(a, b, 2, |x, y| {
            clamp(signed(x, 16) + signed(y, 16), -32768, 32767)
        }),
        0xe8 => zip(a, b, 1, |x, y| {
            clamp(signed(x, 8) - signed(y, 8), -128, 127)
        }),
        0xe9 => zip(a, b, 2, |x, y| {
            clamp(signed(x, 16) - signed(y, 16), -32768, 32767)
        }),
        0xdc => zip(a, b, 1, |x, y| (x + y).min(0xff)),
        0xdd => zip(a, b, 2, |x, y| (x + y).min(0xffff)),
        0xd8 => zip(a, b, 1, u64::saturating_sub),
        0xd9 => zip(a, b, 2, u64::saturating_sub),
        0xd5 => zip(a, b, 2, u64::wrapping_mul),
        0xe5 => zip(a, b, 2, |x, y| {
            ((signed(x, 16) * signed(y, 16)) >> 16) as u64
        }),
        0xe4 => zip(a, b, 2, |x, y| (x * y) >> 16),
        0xf4 => (a & 0xffff_ffff).wrapping_mul(b & 0xffff_ffff),
        0xf5 => zip(a, b, 4, |x, y| {
            (signed(x, 16) * signed(y, 16) + signed(x >> 16, 16) * signed(y >> 16, 16)) as u64
        }),
        0xda => zip(a, b, 1, u64::min),
        0xde => zip(a, b, 1, u64::max),
        0xea => zip(
            a,
            b,
            2,
            |x, y| {
                if signed(x, 16) < signed(y, 16) {
                    x
                } else {
                    y
                }
            },
        ),
        0xee => zip(
            a,
            b,
            2,
            |x, y| {
                if signed(x, 16) > signed(y, 16) {
                    x
                } else {
                    y
                }
            },
        ),
        0xe0 => zip(a, b, 1, |x, y| (x + y + 1) >> 1),
        0xe3 => zip(a, b, 2, |x, y| (x + y + 1) >> 1),
        0xf6 => (0..8).fold(0u64, |sum, byte| {
            let x = (a >> (8 * byte)) & 0xff;
            let y = (b >> (8 * byte)) & 0xff;
            sum + x.abs_diff(y)
        }),
        0xdb => a & b,
        0xdf => !a & b,
        0xeb => a | b,
        0xef => a ^ b,
        _ => unreachable!("decode() a refusé {opcode:#x}"),
    }
}

impl Cpu {
    /// Ce que fait toute instruction MMX avant le reste : le sommet à zéro,
    /// les huit registres occupés.
    pub(super) fn enter_mmx(&mut self) {
        self.fpu_status &= !(7 << 11);
        self.fpu_tags = 0xff;
    }

    /// Écrire MMn : la mantisse, et l'exposant à tout-un.
    pub(super) fn set_mmx(&mut self, index: usize, value: u64) {
        self.x87[index & 7] = (value, 0xffff);
    }

    fn mmx(&self, index: u8) -> u64 {
        self.x87[usize::from(index & 7)].0
    }

    /// **Exécuter une instruction MMX.** Tout est lu, et toute écriture en
    /// mémoire sondée, avant que l'état ne change : une faute n'a rien fait,
    /// pas même entrer dans le MMX.
    pub(super) fn execute_mmx(
        &mut self,
        instruction: &Extended,
        at: Option<u64>,
    ) -> Result<(), ExtendedFault> {
        let Extra::Mmx(form) = instruction.op else {
            unreachable!("execute_mmx ne reçoit que le MMX")
        };
        let (reg, rm) = (instruction.reg, instruction.rm);
        let source = |cpu: &mut Self| -> Result<u64, ExtendedFault> {
            match at {
                Some(at) => cpu.mmx_read(at, Width::Qword),
                None => Ok(cpu.mmx(rm)),
            }
        };
        match form {
            Mmx::Lanes(opcode) => {
                let b = source(self)?;
                self.enter_mmx();
                let value = lanes(opcode, self.mmx(reg), b);
                self.set_mmx(usize::from(reg), value);
            }
            Mmx::MoveIn => {
                let value = match at {
                    Some(at) => self.mmx_read(at, instruction.width)?,
                    None => self.get(rm, instruction.width, false),
                };
                self.enter_mmx();
                self.set_mmx(usize::from(reg), value);
            }
            Mmx::MoveOut => {
                let value = self.mmx(reg) & instruction.width.mask();
                match at {
                    Some(at) => {
                        self.mmx_write(at, instruction.width, value)?;
                        self.enter_mmx();
                    }
                    None => {
                        self.enter_mmx();
                        self.set(rm, instruction.width, false, value);
                    }
                }
            }
            Mmx::Load => {
                let value = source(self)?;
                self.enter_mmx();
                self.set_mmx(usize::from(reg), value);
            }
            Mmx::Store => {
                let value = self.mmx(reg);
                if let Some(at) = at {
                    self.mmx_write(at, Width::Qword, value)?;
                }
                self.enter_mmx();
                if at.is_none() {
                    self.set_mmx(usize::from(rm), value);
                }
            }
            Mmx::ShiftImmediate { lane, kind } => {
                self.enter_mmx();
                let value = shift(self.mmx(rm), instruction.imm & 0xff, lane as u32, kind);
                self.set_mmx(usize::from(rm), value);
            }
            Mmx::MoveMask => {
                self.enter_mmx();
                let value = self.mmx(rm);
                let mask = (0..8).fold(0u64, |mask, byte| {
                    mask | (((value >> (8 * byte + 7)) & 1) << byte)
                });
                self.set(reg, Width::Dword, false, mask);
            }
            Mmx::InsertWord => {
                let word = match at {
                    Some(at) => self.mmx_read(at, Width::Word)?,
                    None => self.get(rm, Width::Word, false),
                } & 0xffff;
                self.enter_mmx();
                let shift = 16 * (instruction.imm & 3);
                let value = (self.mmx(reg) & !(0xffff << shift)) | (word << shift);
                self.set_mmx(usize::from(reg), value);
            }
            Mmx::ExtractWord => {
                self.enter_mmx();
                let word = (self.mmx(rm) >> (16 * (instruction.imm & 3))) & 0xffff;
                self.set(reg, Width::Dword, false, word);
            }
            Mmx::ShuffleWords => {
                let b = source(self)?;
                self.enter_mmx();
                let value = (0..4).fold(0u64, |out, lane| {
                    let pick = (instruction.imm >> (2 * lane)) & 3;
                    out | (((b >> (16 * pick)) & 0xffff) << (16 * lane))
                });
                self.set_mmx(usize::from(reg), value);
            }
            Mmx::MaskedStore => {
                let (data, mask) = (self.mmx(reg), self.mmx(rm));
                // `[RDI]` : un préfixe de segment devant `maskmovq` n'est pas
                // suivi (personne ne l'écrit).
                let base = self.regs[7];
                // Chaque octet choisi doit pouvoir s'écrire avant le premier.
                for byte in 0..8u64 {
                    if (mask >> (8 * byte + 7)) & 1 != 0 {
                        self.probe_memory(base.wrapping_add(byte), Access::Write)
                            .map_err(|_| ExtendedFault::Memory)?;
                    }
                }
                self.enter_mmx();
                for byte in 0..8u64 {
                    if (mask >> (8 * byte + 7)) & 1 != 0 {
                        self.mmx_write(base.wrapping_add(byte), Width::Byte, data >> (8 * byte))?;
                    }
                }
            }
            Mmx::FromXmm => {
                self.enter_mmx();
                let value = self.xmm[usize::from(rm & 15)][0];
                self.set_mmx(usize::from(reg), value);
            }
            Mmx::ToXmm => {
                self.enter_mmx();
                self.xmm[usize::from(reg & 15)] = [self.mmx(rm), 0];
            }
        }
        Ok(())
    }

    fn mmx_read(&mut self, at: u64, width: Width) -> Result<u64, ExtendedFault> {
        self.read_memory(at, width)
            .map_err(|_| ExtendedFault::Memory)
    }

    fn mmx_write(&mut self, at: u64, width: Width, value: u64) -> Result<(), ExtendedFault> {
        self.write_memory(at, width, value)
            .map_err(|_| ExtendedFault::Memory)
    }
}
