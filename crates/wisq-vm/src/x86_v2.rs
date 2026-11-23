//! **x86-64-v2, la part entière** : SSSE3, les formes entières de SSE4.1,
//! `pcmpgtq` et `crc32` de SSE4.2, les copies de SSE3, `lahf` et `sahf`.
//!
//! **Pourquoi.** La glibc de RHEL 9 (AlmaLinux, Rocky) s'arrête au premier
//! programme sur un processeur qui n'annonce pas x86-64-v2 — « Fatal glibc
//! error: CPU does not support x86-64-v2 » — et ses programmes, compilés pour
//! lui, emploient ces instructions partout. Les formes flottantes (`haddps`,
//! `roundsd`, `dpps`…) vivent dans `x86_sse.rs`, avec l'arithmétique IEEE ;
//! les comparaisons de chaînes de SSE4.2, ici.
//!
//! **Le juge** est le processeur qui fait tourner les tests
//! (`tests/x86_v2_host.rs`) : chaque forme y est exécutée par le silicium et
//! par ce module sur des états tirés au hasard, au bit près.
//!
//! **Ce qui n'est pas modélisé** : l'alignement de seize octets que les
//! formes de SSE exigent d'un opérande mémoire (`#GP`) — un programme juste
//! ne le viole pas — et les formes MMX de SSSE3, que les compilateurs
//! n'émettent pas.

use super::{Extended, ExtendedFault, Extra};
use crate::x86::{read_modrm, Cpu, Prefixes, Width, AF, CF, OF, PF, SF, ZF};

/// Une instruction de x86-64-v2, par sa table et son opcode.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum V2 {
    /// `66 0F 38 xx` : SSSE3 et SSE4.1, deux opérandes XMM.
    Table38(u8),
    /// `66 0F 3A xx ib` : les formes à immédiat.
    Table3A(u8),
    /// `F2 0F 38 F0/F1` : le CRC-32C de `bytes` octets.
    Crc32 {
        bytes: u8,
    },
    /// `F2 0F 12` `movddup`, `F3 0F 12` `movsldup`, `F3 0F 16` `movshdup`.
    Duplicate {
        high: bool,
        double: bool,
    },
    /// `F2 0F F0` : `lddqu`, une lecture de seize octets.
    LoadUnaligned,
    /// `9F` et `9E`.
    Lahf,
    Sahf,
}

/// **Lire une forme de x86-64-v2** derrière `0F` (`at` sur l'octet d'après),
/// ou `None` si ce n'en est pas une. Les flottantes rendent `Extra::Sse`.
pub(super) fn decode(bytes: &[u8], mut at: usize, prefixes: Prefixes) -> Option<Extended> {
    let second = *bytes.get(at)?;
    at += 1;
    let p66 = prefixes.operand_size;
    let f2 = prefixes.repeat_not;
    let f3 = prefixes.repeat;
    let wide = prefixes.rex.is_some_and(|rex| rex & 0b1000 != 0);
    let (op, immediate) = match second {
        0x38 => {
            let third = *bytes.get(at)?;
            at += 1;
            match third {
                0xF0 | 0xF1 if f2 && !f3 => {
                    let bytes_ = match (third, p66, wide) {
                        (0xF0, _, _) => 1,
                        (_, true, false) => 2,
                        (_, _, true) => 8,
                        _ => 4,
                    };
                    (Extra::V2(V2::Crc32 { bytes: bytes_ }), false)
                }
                0x00..=0x0B
                | 0x10
                | 0x14
                | 0x15
                | 0x17
                | 0x1C..=0x1E
                | 0x20..=0x25
                | 0x28..=0x2B
                | 0x30..=0x35
                | 0x37..=0x41
                    if p66 && !f2 && !f3 =>
                {
                    (Extra::V2(V2::Table38(third)), false)
                }
                _ => return None,
            }
        }
        0x3A => {
            let third = *bytes.get(at)?;
            at += 1;
            if !p66 || f2 || f3 {
                return None;
            }
            match third {
                0x08..=0x0B => (
                    Extra::Sse(super::Sse::Round {
                        double: third & 1 != 0,
                        scalar: third >= 0x0A,
                    }),
                    true,
                ),
                0x40 | 0x41 => (
                    Extra::Sse(super::Sse::Dot {
                        double: third == 0x41,
                    }),
                    true,
                ),
                0x0C..=0x0F | 0x14..=0x17 | 0x20..=0x22 | 0x42 | 0x60..=0x63 => {
                    (Extra::V2(V2::Table3A(third)), true)
                }
                _ => return None,
            }
        }
        0x12 if f2 && !p66 && !f3 => (
            Extra::V2(V2::Duplicate {
                high: false,
                double: true,
            }),
            false,
        ),
        0x12 if f3 && !p66 && !f2 => (
            Extra::V2(V2::Duplicate {
                high: false,
                double: false,
            }),
            false,
        ),
        0x16 if f3 && !p66 && !f2 => (
            Extra::V2(V2::Duplicate {
                high: true,
                double: false,
            }),
            false,
        ),
        0xF0 if f2 && !p66 && !f3 => (Extra::V2(V2::LoadUnaligned), false),
        // Le flottant de SSE3 : `addsubpd`/`addsubps`, `haddpd`/`haddps`,
        // `hsubpd`/`hsubps`.
        0xD0 | 0x7C | 0x7D if (p66 || f2) && !f3 && !(p66 && f2) => {
            let double = p66;
            let form = match second {
                0xD0 => super::Sse::AddSub { double },
                _ => super::Sse::Horizontal {
                    double,
                    sub: second == 0x7D,
                },
            };
            (Extra::Sse(form), false)
        }
        _ => return None,
    };
    let field = read_modrm(bytes, &mut at, prefixes)?;
    // `lddqu` et `movntdqa` ne lisent que la mémoire.
    if field.memory.is_none() && matches!(op, Extra::V2(V2::LoadUnaligned | V2::Table38(0x2A))) {
        return None;
    }
    let imm = if immediate {
        let value = u64::from(*bytes.get(at)?);
        at += 1;
        value
    } else {
        0
    };
    Some(Extended {
        op,
        width: if wide { Width::Qword } else { Width::Dword },
        reg: field.reg,
        rm: field.register,
        memory: field.memory,
        imm,
        length: at,
    })
}

fn join(value: [u64; 2]) -> u128 {
    u128::from(value[0]) | (u128::from(value[1]) << 64)
}

fn split(value: u128) -> [u64; 2] {
    [value as u64, (value >> 64) as u64]
}

/// La voie `index` de `bits` bits.
fn voie(value: u128, bits: u32, index: u32) -> u64 {
    ((value >> (bits * index)) & ((1u128 << bits) - 1)) as u64
}

fn poser(value: &mut u128, bits: u32, index: u32, lane: u64) {
    let mask = ((1u128 << bits) - 1) << (bits * index);
    *value = (*value & !mask) | ((u128::from(lane) << (bits * index)) & mask);
}

fn signe(value: u64, bits: u32) -> i64 {
    ((value << (64 - bits)) as i64) >> (64 - bits)
}

/// Saturer un entier signé dans `bits` bits, signé ou non.
fn saturer(value: i64, bits: u32, signed: bool) -> u64 {
    let (low, high) = if signed {
        (-(1i64 << (bits - 1)), (1i64 << (bits - 1)) - 1)
    } else {
        (0, (1i64 << bits) - 1)
    };
    (value.clamp(low, high) as u64) & ((1u64 << bits) - 1)
}

/// `f` voie par voie, sur deux valeurs.
fn voies(x: u128, y: u128, bits: u32, f: impl Fn(u64, u64) -> u64) -> u128 {
    let mut out = 0;
    for index in 0..128 / bits {
        poser(
            &mut out,
            bits,
            index,
            f(voie(x, bits, index), voie(y, bits, index)),
        );
    }
    out
}

/// **Horizontal** : les paires de `x`, puis celles de `y`.
fn horizontal(x: u128, y: u128, bits: u32, f: impl Fn(u64, u64) -> u64) -> u128 {
    let count = 128 / bits;
    let mut out = 0;
    for index in 0..count {
        let (from, pair) = if index < count / 2 {
            (x, index)
        } else {
            (y, index - count / 2)
        };
        poser(
            &mut out,
            bits,
            index,
            f(voie(from, bits, 2 * pair), voie(from, bits, 2 * pair + 1)),
        );
    }
    out
}

/// **Le CRC-32C** (Castagnoli, réfléchi), un octet à la fois.
fn crc32c(mut crc: u32, value: u64, bytes: u8) -> u32 {
    for rang in 0..bytes {
        crc ^= u32::from((value >> (8 * rang)) as u8);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0x82F6_3B78 & (crc & 1).wrapping_neg());
        }
    }
    crc
}

impl Cpu {
    fn v2_read(&mut self, at: u64, width: Width) -> Result<u64, ExtendedFault> {
        self.read_memory_fast(at, width)
            .map_err(|_| ExtendedFault::Memory)
    }

    /// La source : `bytes` octets à `at`, ou le registre XMM `rm`.
    fn v2_source(&mut self, at: Option<u64>, rm: usize, bytes: u32) -> Result<u128, ExtendedFault> {
        let Some(at) = at else {
            return Ok(join(self.xmm[rm]));
        };
        Ok(match bytes {
            16 => join([
                self.v2_read(at, Width::Qword)?,
                self.v2_read(at.wrapping_add(8), Width::Qword)?,
            ]),
            8 => u128::from(self.v2_read(at, Width::Qword)?),
            4 => u128::from(self.v2_read(at, Width::Dword)?),
            2 => u128::from(self.v2_read(at, Width::Word)?),
            _ => u128::from(self.v2_read(at, Width::Byte)?),
        })
    }

    /// **Exécuter une forme de x86-64-v2** (la part entière).
    pub(super) fn execute_v2(
        &mut self,
        instruction: &Extended,
        at: Option<u64>,
    ) -> Result<(), ExtendedFault> {
        let Extra::V2(form) = instruction.op else {
            unreachable!("execute_v2 ne reçoit que x86-64-v2")
        };
        let d = usize::from(instruction.reg & 15);
        let s = usize::from(instruction.rm & 15);
        let imm = instruction.imm as u32;
        match form {
            V2::Lahf => {
                let flags = self.flags.read() & (SF | ZF | AF | PF | CF);
                let ah = flags | 0x02;
                self.regs[0] = (self.regs[0] & !0xFF00) | (ah << 8);
            }
            V2::Sahf => {
                let ah = (self.regs[0] >> 8) & (SF | ZF | AF | PF | CF);
                let flags = self.flags.read() & !(SF | ZF | AF | PF | CF);
                self.flags.write(flags | ah);
            }
            V2::Crc32 { bytes } => {
                let width = match bytes {
                    1 => Width::Byte,
                    2 => Width::Word,
                    4 => Width::Dword,
                    _ => Width::Qword,
                };
                let value = match at {
                    Some(at) => self.v2_read(at, width)?,
                    None => self.regs[s] & width.mask(),
                };
                let crc = crc32c(self.regs[d] as u32, value, bytes);
                self.regs[d] = u64::from(crc);
            }
            V2::Duplicate { high, double } => {
                let y = self.v2_source(at, s, if double { 8 } else { 16 })?;
                let out = if double {
                    let low = y as u64;
                    join([low, low])
                } else {
                    let pick = u32::from(high);
                    let a = voie(y, 32, pick);
                    let b = voie(y, 32, 2 + pick);
                    u128::from(a)
                        | (u128::from(a) << 32)
                        | (u128::from(b) << 64)
                        | (u128::from(b) << 96)
                };
                self.xmm[d] = split(out);
            }
            V2::LoadUnaligned => {
                let y = self.v2_source(at, s, 16)?;
                self.xmm[d] = split(y);
            }
            V2::Table38(opcode) => self.table38(opcode, d, s, at)?,
            V2::Table3A(opcode) => self.table3a(opcode, d, s, at, imm, instruction)?,
        }
        Ok(())
    }

    fn table38(
        &mut self,
        opcode: u8,
        d: usize,
        s: usize,
        at: Option<u64>,
    ) -> Result<(), ExtendedFault> {
        // Les extensions lisent la moitié, le quart ou le huitième.
        let bytes = match opcode {
            0x20 | 0x23 | 0x25 | 0x30 | 0x33 | 0x35 => 8,
            0x21 | 0x24 | 0x31 | 0x34 => 4,
            0x22 | 0x32 => 2,
            _ => 16,
        };
        let y = self.v2_source(at, s, bytes)?;
        let x = join(self.xmm[d]);
        let mask = join(self.xmm[0]);
        let signed_op = |bits: u32, f: fn(i64, i64) -> i64| {
            voies(x, y, bits, move |a, b| {
                (f(signe(a, bits), signe(b, bits)) as u64) & ((1u64 << bits) - 1)
            })
        };
        let out = match opcode {
            0x00 => {
                let mut out = 0;
                for index in 0..16 {
                    let select = voie(y, 8, index);
                    let byte = if select & 0x80 != 0 {
                        0
                    } else {
                        voie(x, 8, (select & 15) as u32)
                    };
                    poser(&mut out, 8, index, byte);
                }
                out
            }
            0x01 => horizontal(x, y, 16, |a, b| a.wrapping_add(b)),
            0x02 => horizontal(x, y, 32, |a, b| a.wrapping_add(b)),
            0x03 => horizontal(x, y, 16, |a, b| {
                saturer(signe(a, 16) + signe(b, 16), 16, true)
            }),
            0x05 => horizontal(x, y, 16, |a, b| a.wrapping_sub(b)),
            0x06 => horizontal(x, y, 32, |a, b| a.wrapping_sub(b)),
            0x07 => horizontal(x, y, 16, |a, b| {
                saturer(signe(a, 16) - signe(b, 16), 16, true)
            }),
            0x04 => {
                let mut out = 0;
                for index in 0..8 {
                    let p = |k: u32| {
                        voie(x, 8, 2 * index + k) as i64 * signe(voie(y, 8, 2 * index + k), 8)
                    };
                    poser(&mut out, 16, index, saturer(p(0) + p(1), 16, true));
                }
                out
            }
            0x08..=0x0A => {
                let bits = 8 << (opcode - 0x08);
                voies(x, y, bits, |a, b| {
                    let sign = signe(b, bits);
                    let value = if sign < 0 {
                        a.wrapping_neg()
                    } else if sign == 0 {
                        0
                    } else {
                        a
                    };
                    value & ((1u64 << bits) - 1)
                })
            }
            0x0B => voies(x, y, 16, |a, b| {
                let product = signe(a, 16) * signe(b, 16);
                (((product >> 14) + 1) >> 1) as u64 & 0xFFFF
            }),
            0x10 => {
                let mut out = 0;
                for index in 0..16 {
                    let pick = if voie(mask, 8, index) & 0x80 != 0 {
                        y
                    } else {
                        x
                    };
                    poser(&mut out, 8, index, voie(pick, 8, index));
                }
                out
            }
            0x14 | 0x15 => {
                let bits = if opcode == 0x14 { 32 } else { 64 };
                let mut out = 0;
                for index in 0..128 / bits {
                    let sign = voie(mask, bits, index) >> (bits - 1);
                    let pick = if sign != 0 { y } else { x };
                    poser(&mut out, bits, index, voie(pick, bits, index));
                }
                out
            }
            0x17 => {
                let zf = (x & y) == 0;
                let cf = (!x & y) == 0;
                let flags = self.flags.read() & !(CF | PF | AF | ZF | SF | OF);
                self.flags
                    .write(flags | if zf { ZF } else { 0 } | if cf { CF } else { 0 });
                return Ok(());
            }
            0x1C..=0x1E => {
                let bits = 8 << (opcode - 0x1C);
                voies(y, y, bits, |a, _| {
                    signe(a, bits).unsigned_abs() & ((1u64 << bits) - 1)
                })
            }
            0x20..=0x25 | 0x30..=0x35 => {
                let signed = opcode < 0x30;
                let (from, to) = match opcode & 0x0F {
                    0 => (8, 16),
                    1 => (8, 32),
                    2 => (8, 64),
                    3 => (16, 32),
                    4 => (16, 64),
                    _ => (32, 64),
                };
                let mut out = 0;
                for index in 0..128 / to {
                    let value = voie(y, from, index);
                    let wide = if signed {
                        signe(value, from) as u64
                    } else {
                        value
                    };
                    let mask = if to == 64 { u64::MAX } else { (1u64 << to) - 1 };
                    poser(&mut out, to, index, wide & mask);
                }
                out
            }
            0x28 => {
                let low = |v: u128, i: u32| signe(voie(v, 32, i), 32);
                join([
                    (low(x, 0) * low(y, 0)) as u64,
                    (low(x, 2) * low(y, 2)) as u64,
                ])
            }
            0x29 => voies(x, y, 64, |a, b| if a == b { u64::MAX } else { 0 }),
            0x37 => voies(
                x,
                y,
                64,
                |a, b| if (a as i64) > (b as i64) { u64::MAX } else { 0 },
            ),
            0x2A => y,
            0x2B => {
                let mut out = 0;
                for index in 0..8 {
                    let (from, lane) = if index < 4 {
                        (x, index)
                    } else {
                        (y, index - 4)
                    };
                    poser(
                        &mut out,
                        16,
                        index,
                        saturer(signe(voie(from, 32, lane), 32), 16, false),
                    );
                }
                out
            }
            0x38 => signed_op(8, i64::min),
            0x39 => signed_op(32, i64::min),
            0x3C => signed_op(8, i64::max),
            0x3D => signed_op(32, i64::max),
            0x3A => voies(x, y, 16, u64::min),
            0x3B => voies(x, y, 32, u64::min),
            0x3E => voies(x, y, 16, u64::max),
            0x3F => voies(x, y, 32, u64::max),
            0x40 => voies(x, y, 32, |a, b| a.wrapping_mul(b) & 0xFFFF_FFFF),
            0x41 => {
                let (mut best, mut index) = (voie(y, 16, 0), 0);
                for lane in 1..8 {
                    let value = voie(y, 16, lane);
                    if value < best {
                        best = value;
                        index = lane;
                    }
                }
                u128::from(best) | (u128::from(index) << 16)
            }
            _ => unreachable!("une forme de 0F 38 que `decode` ne rend pas : {opcode:#x}"),
        };
        self.xmm[d] = split(out);
        Ok(())
    }

    fn table3a(
        &mut self,
        opcode: u8,
        d: usize,
        s: usize,
        at: Option<u64>,
        imm: u32,
        instruction: &Extended,
    ) -> Result<(), ExtendedFault> {
        let x = join(self.xmm[d]);
        let wide = instruction.width == Width::Qword;
        match opcode {
            // Les extractions : de XMM `d` (le champ reg) vers un registre
            // général ou la mémoire.
            0x14..=0x17 => {
                let (bits, lane) = match opcode {
                    0x14 => (8, imm & 15),
                    0x15 => (16, imm & 7),
                    0x16 if wide => (64, imm & 1),
                    _ => (32, imm & 3),
                };
                let value = voie(x, bits, lane);
                match at {
                    Some(at) => {
                        let width = match bits {
                            8 => Width::Byte,
                            16 => Width::Word,
                            32 => Width::Dword,
                            _ => Width::Qword,
                        };
                        self.write_memory_fast(at, width, value)
                            .map_err(|_| ExtendedFault::Memory)?;
                    }
                    None => self.regs[s] = value,
                }
                return Ok(());
            }
            0x20 | 0x22 => {
                let (bits, lane) = match opcode {
                    0x20 => (8, imm & 15),
                    _ if wide => (64, imm & 1),
                    _ => (32, imm & 3),
                };
                let value = match at {
                    Some(_) => voie(self.v2_source(at, s, bits / 8)?, bits, 0),
                    None => {
                        self.regs[s]
                            & if bits == 64 {
                                u64::MAX
                            } else {
                                (1u64 << bits) - 1
                            }
                    }
                };
                let mut out = x;
                poser(&mut out, bits, lane, value);
                self.xmm[d] = split(out);
                return Ok(());
            }
            _ => {}
        }
        let bytes = if opcode == 0x21 && at.is_some() {
            4
        } else {
            16
        };
        let y = self.v2_source(at, s, bytes)?;
        let out = match opcode {
            0x0C..=0x0E => {
                let bits = match opcode {
                    0x0C => 32,
                    0x0D => 64,
                    _ => 16,
                };
                let mut out = 0;
                for index in 0..128 / bits {
                    let pick = if imm >> index & 1 != 0 { y } else { x };
                    poser(&mut out, bits, index, voie(pick, bits, index));
                }
                out
            }
            0x0F => {
                let shift = imm & 0xFF;
                if shift >= 32 {
                    0
                } else {
                    // (x:y) sur 256 bits, décalé de `shift` octets à droite.
                    let low = y;
                    let high = x;
                    let bits = shift * 8;
                    if bits == 0 {
                        low
                    } else if bits < 128 {
                        (low >> bits) | (high << (128 - bits))
                    } else if bits == 128 {
                        high
                    } else {
                        high >> (bits - 128)
                    }
                }
            }
            0x21 => {
                let value = if at.is_some() {
                    voie(y, 32, 0)
                } else {
                    voie(y, 32, (imm >> 6) & 3)
                };
                let mut out = x;
                poser(&mut out, 32, (imm >> 4) & 3, value);
                for index in 0..4 {
                    if imm >> index & 1 != 0 {
                        poser(&mut out, 32, index, 0);
                    }
                }
                out
            }
            0x42 => {
                let from_x = 4 * ((imm >> 2) & 1);
                let from_y = 4 * (imm & 3);
                let mut out = 0;
                for index in 0..8 {
                    let sum: u64 = (0..4)
                        .map(|k| voie(x, 8, from_x + index + k).abs_diff(voie(y, 8, from_y + k)))
                        .sum();
                    poser(&mut out, 16, index, sum);
                }
                out
            }
            0x60..=0x63 => {
                self.string_compare(opcode, x, y, imm);
                return Ok(());
            }
            _ => unreachable!("une forme de 0F 3A que `decode` ne rend pas : {opcode:#x}"),
        };
        self.xmm[d] = split(out);
        Ok(())
    }

    /// **`pcmpestri`, `pcmpestrm`, `pcmpistri`, `pcmpistrm`** — les
    /// comparaisons de chaînes de SSE4.2, telles que le manuel les décrit :
    /// le format (octets ou mots, signés ou non), l'agrégation (un parmi,
    /// intervalles, égalité voie à voie, sous-chaîne), la polarité, puis la
    /// sortie — un indice dans ECX ou un masque dans XMM0 — et les drapeaux.
    fn string_compare(&mut self, opcode: u8, x: u128, y: u128, imm: u32) {
        let words = imm & 1 != 0;
        let signed = imm & 2 != 0;
        let bits = if words { 16 } else { 8 };
        let count = 128 / bits;
        let explicit = opcode <= 0x61;
        let valeur = |v: u128, i: u32| {
            let raw = voie(v, bits, i);
            if signed {
                signe(raw, bits)
            } else {
                raw as i64
            }
        };
        // Les longueurs : RAX et RDX (explicites, valeur absolue saturée),
        // ou jusqu'au premier élément nul (implicites).
        let longueur = |v: u128, registre: u64| -> u32 {
            if explicit {
                // EAX et EDX, signés, en valeur absolue, saturés au nombre
                // d'éléments (REX.W, qui les lirait sur 64 bits, n'est pas
                // émis par les compilateurs ici).
                i64::from(registre as i32)
                    .unsigned_abs()
                    .min(u64::from(count)) as u32
            } else {
                (0..count).find(|&i| voie(v, bits, i) == 0).unwrap_or(count)
            }
        };
        let la = longueur(x, self.regs[0]);
        let lb = longueur(y, self.regs[2]);
        let aggregation = (imm >> 2) & 3;
        let mut res1: u32 = 0;
        for j in 0..count {
            let hit = match aggregation {
                // Un parmi : b[j] est-il l'un des a[i] ?
                0 => j < lb && (0..la).any(|i| valeur(x, i) == valeur(y, j)),
                // Intervalles : a[2k] <= b[j] <= a[2k+1].
                1 => {
                    j < lb
                        && (0..la / 2 * 2).step_by(2).any(|i| {
                            i + 1 < la
                                && valeur(x, i) <= valeur(y, j)
                                && valeur(y, j) <= valeur(x, i + 1)
                        })
                }
                // Égalité voie à voie : deux invalides sont égaux.
                2 => match (j < la, j < lb) {
                    (true, true) => valeur(x, j) == valeur(y, j),
                    (false, false) => true,
                    _ => false,
                },
                // Sous-chaîne : a commence-t-il à b[j] ?
                _ => (0..count - j).all(|i| {
                    let k = i + j;
                    match (i < la, k < lb) {
                        (false, _) => true,
                        (true, false) => false,
                        (true, true) => valeur(x, i) == valeur(y, k),
                    }
                }),
            };
            if hit {
                res1 |= 1 << j;
            }
        }
        let all = (1u32 << count) - 1;
        let res2 = match (imm >> 4) & 3 {
            1 => !res1 & all,
            3 => res1 ^ ((1u32 << lb) - 1),
            _ => res1,
        };
        if opcode & 1 != 0 {
            // L'indice : le plus bas ou le plus haut bit levé, `count` sinon.
            let index = if res2 == 0 {
                count
            } else if imm & 0x40 != 0 {
                31 - res2.leading_zeros()
            } else {
                res2.trailing_zeros()
            };
            self.regs[1] = u64::from(index);
        } else {
            // Le masque : des bits, ou des éléments entiers.
            let out = if imm & 0x40 != 0 {
                let mut out = 0;
                for j in 0..count {
                    let lane = if res2 >> j & 1 != 0 {
                        (1u64 << bits) - 1
                    } else {
                        0
                    };
                    poser(&mut out, bits, j, lane);
                }
                out
            } else {
                u128::from(res2)
            };
            self.xmm[0] = split(out);
        }
        let mut flags = self.flags.read() & !(CF | PF | AF | ZF | SF | OF);
        if res2 != 0 {
            flags |= CF;
        }
        if lb < count {
            flags |= ZF;
        }
        if la < count {
            flags |= SF;
        }
        if res2 & 1 != 0 {
            flags |= OF;
        }
        self.flags.write(flags);
    }
}
