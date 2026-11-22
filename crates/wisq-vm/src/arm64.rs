//! **Un cœur ARM64 (A64), interprété** — première tranche : le jeu entier en
//! mode utilisateur.
//!
//! wisq reconnaît les images ARM depuis longtemps et les refusait faute de
//! cœur ; la feuille d'avant le démarrage le dit depuis #727. Ce fichier est
//! le début de ce cœur, et il commence par ce qu'on peut **prouver** : les
//! instructions entières d'A64 — arithmétique et logique, champs de bits,
//! multiplications et divisions, sauts, chargements et rangements, accès
//! exclusifs —, exécutées une à une comme le pseudocode du manuel d'ARM les
//! décrit, et confrontées à `qemu-aarch64` par les tests de
//! `tests/arm64.rs`.
//!
//! **Ce qui n'y est pas encore, et qui est dit.** Pas de virgule flottante
//! ni de NEON (le groupe rend [`Arm64Step::Undefined`]), pas de niveaux
//! d'exception ni de MMU, pas de GIC, de minuterie ni d'UART : c'est un
//! processeur d'application en EL0, qui rend la main sur `SVC`. Démarrer un
//! noyau Linux demande tout cela en plus — les tranches suivantes. Rien de ce
//! fichier n'est encore branché dans l'application, qui continue d'annoncer
//! qu'elle n'a pas de cœur ARM.
//!
//! Interpréter est le seul choix, pour la même raison que pour les deux autres
//! cœurs : iOS n'accorde pas de mémoire exécutable aux applications de l'App
//! Store, même quand l'invité et l'hôte parlent la même langue.

/// La mémoire vue par le cœur. Les accès sont de 1, 2, 4 ou 8 octets, petit
/// boutiste ; `None` ou `false` veut dire « rien à cette adresse », et le pas
/// rend [`Arm64Step::Fault`].
pub trait Arm64Bus {
    fn load(&mut self, address: u64, size: u8) -> Option<u64>;
    fn store(&mut self, address: u64, size: u8, value: u64) -> bool;
}

/// Une mémoire plate, d'un seul tenant, à partir de `base` : ce que les tests
/// emploient, et ce qu'emploiera le premier chargeur.
pub struct FlatMemory {
    pub base: u64,
    pub bytes: Vec<u8>,
}

impl FlatMemory {
    pub fn new(base: u64, size: usize) -> Self {
        Self {
            base,
            bytes: vec![0; size],
        }
    }

    fn range(&self, address: u64, size: u8) -> Option<std::ops::Range<usize>> {
        let offset = usize::try_from(address.checked_sub(self.base)?).ok()?;
        let end = offset.checked_add(usize::from(size))?;
        (end <= self.bytes.len()).then_some(offset..end)
    }
}

impl Arm64Bus for FlatMemory {
    fn load(&mut self, address: u64, size: u8) -> Option<u64> {
        let range = self.range(address, size)?;
        let mut word = [0u8; 8];
        word[..usize::from(size)].copy_from_slice(&self.bytes[range]);
        Some(u64::from_le_bytes(word))
    }

    fn store(&mut self, address: u64, size: u8, value: u64) -> bool {
        let Some(range) = self.range(address, size) else {
            return false;
        };
        self.bytes[range].copy_from_slice(&value.to_le_bytes()[..usize::from(size)]);
        true
    }
}

/// Ce qu'un pas a donné.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Arm64Step {
    /// L'instruction est faite, `pc` est sur la suivante.
    Ran,
    /// `SVC #imm` : `pc` est déjà sur l'instruction suivante, comme
    /// `ELR_EL1` le serait ; l'appelant sert l'appel et reprend.
    Svc(u16),
    /// `BRK #imm` : `pc` reste sur l'instruction.
    Brk(u16),
    /// Une instruction que ce cœur ne sait pas (encore) exécuter, ou que le
    /// manuel déclare indéfinie. `pc` reste dessus.
    Undefined(u32),
    /// Un accès mémoire sans rien derrière, à cette adresse. `pc` reste sur
    /// l'instruction, et aucun registre n'a changé.
    Fault(u64),
}

/// Les registres système d'EL0 que ce cœur tient. Les numéros sont le champ
/// `o0:op1:CRn:CRm:op2` de `MRS` et `MSR`, bits 19 à 5.
const SYSREG_NZCV: u32 = 0x5a10;
const SYSREG_FPCR: u32 = 0x5a20;
const SYSREG_FPSR: u32 = 0x5a21;
const SYSREG_TPIDR_EL0: u32 = 0x5e82;

/// Un processeur A64 en EL0.
#[derive(Debug, Clone, Default)]
pub struct Arm64Core {
    /// X0 à X30. Le numéro 31 n'est pas ici : selon l'instruction, il veut
    /// dire XZR (zéro) ou SP.
    pub x: [u64; 31],
    pub sp: u64,
    pub pc: u64,
    pub n: bool,
    pub z: bool,
    pub c: bool,
    pub v: bool,
    pub tpidr_el0: u64,
    pub fpcr: u64,
    pub fpsr: u64,
    /// L'adresse que le moniteur exclusif garde, après `LDXR`.
    exclusive: Option<u64>,
}

/// Les deux largeurs d'une opération entière.
#[inline]
fn mask(sf: bool) -> u64 {
    if sf {
        u64::MAX
    } else {
        u64::from(u32::MAX)
    }
}

#[inline]
fn width(sf: bool) -> u32 {
    if sf {
        64
    } else {
        32
    }
}

#[inline]
fn bits(insn: u32, low: u32, count: u32) -> u32 {
    (insn >> low) & ((1u32 << count) - 1)
}

#[inline]
fn bit(insn: u32, at: u32) -> bool {
    (insn >> at) & 1 == 1
}

/// Étend le signe d'un champ de `count` bits.
#[inline]
fn sext(value: u64, count: u32) -> u64 {
    let shift = 64 - count;
    (((value << shift) as i64) >> shift) as u64
}

/// Rotation à droite dans une largeur de `size` bits (1 à 64).
#[inline]
fn ror(value: u64, amount: u32, size: u32) -> u64 {
    let size_mask = ones(size);
    let value = value & size_mask;
    let amount = amount % size;
    if amount == 0 {
        value
    } else {
        ((value >> amount) | (value << (size - amount))) & size_mask
    }
}

#[inline]
fn ones(count: u32) -> u64 {
    if count >= 64 {
        u64::MAX
    } else {
        (1u64 << count) - 1
    }
}

/// Répète un élément de `esize` bits sur 64.
fn replicate(element: u64, esize: u32) -> u64 {
    let mut out = 0u64;
    let mut at = 0;
    while at < 64 {
        out |= element << at;
        at += esize;
    }
    out
}

/// `DecodeBitMasks` du manuel : les deux masques d'une instruction logique
/// immédiate ou d'un champ de bits. `None` pour une combinaison réservée.
fn decode_bit_masks(
    n: bool,
    imms: u32,
    immr: u32,
    immediate: bool,
    sf: bool,
) -> Option<(u64, u64)> {
    let combined = (u32::from(n) << 6) | (!imms & 0x3f);
    if combined == 0 {
        return None;
    }
    let len = 31 - combined.leading_zeros();
    if len < 1 {
        return None;
    }
    let levels = (1u32 << len) - 1;
    if immediate && (imms & levels) == levels {
        return None;
    }
    let s = imms & levels;
    let r = immr & levels;
    let esize = 1u32 << len;
    let d = s.wrapping_sub(r) & (esize - 1);
    let welem = ones(s + 1);
    let telem = ones(d + 1);
    let wmask = replicate(ror(welem, r, esize), esize) & mask(sf);
    let tmask = replicate(telem, esize) & mask(sf);
    Some((wmask, tmask))
}

impl Arm64Core {
    pub fn new(pc: u64, sp: u64) -> Self {
        Self {
            pc,
            sp,
            ..Self::default()
        }
    }

    /// Le registre `r`, où 31 vaut zéro.
    #[inline]
    fn xr(&self, r: u32) -> u64 {
        if r == 31 {
            0
        } else {
            self.x[r as usize]
        }
    }

    /// Le registre `r`, où 31 est SP.
    #[inline]
    fn xsp(&self, r: u32) -> u64 {
        if r == 31 {
            self.sp
        } else {
            self.x[r as usize]
        }
    }

    /// Écrit `r` (31 jeté), à la largeur dite : W met à zéro le haut.
    #[inline]
    fn set_xr(&mut self, r: u32, value: u64, sf: bool) {
        if r != 31 {
            self.x[r as usize] = value & mask(sf);
        }
    }

    /// Écrit `r` où 31 est SP.
    #[inline]
    fn set_xsp(&mut self, r: u32, value: u64, sf: bool) {
        if r == 31 {
            self.sp = value & mask(sf);
        } else {
            self.x[r as usize] = value & mask(sf);
        }
    }

    pub fn nzcv(&self) -> u64 {
        (u64::from(self.n) << 31)
            | (u64::from(self.z) << 30)
            | (u64::from(self.c) << 29)
            | (u64::from(self.v) << 28)
    }

    pub fn set_nzcv(&mut self, value: u64) {
        self.n = value >> 31 & 1 == 1;
        self.z = value >> 30 & 1 == 1;
        self.c = value >> 29 & 1 == 1;
        self.v = value >> 28 & 1 == 1;
    }

    /// `ConditionHolds` du manuel.
    fn condition(&self, cond: u32) -> bool {
        let result = match cond >> 1 {
            0 => self.z,
            1 => self.c,
            2 => self.n,
            3 => self.v,
            4 => self.c && !self.z,
            5 => self.n == self.v,
            6 => self.n == self.v && !self.z,
            _ => true,
        };
        if cond & 1 == 1 && cond != 0xf {
            !result
        } else {
            result
        }
    }

    /// `AddWithCarry` : le résultat, et les drapeaux qu'il poserait.
    fn add_with_carry(x: u64, y: u64, carry: bool, sf: bool) -> (u64, [bool; 4]) {
        let m = mask(sf);
        let (x, y) = (x & m, y & m);
        let w = width(sf);
        let unsigned = u128::from(x) + u128::from(y) + u128::from(carry);
        let result = (unsigned as u64) & m;
        let signed =
            i128::from(sext(x, w) as i64) + i128::from(sext(y, w) as i64) + i128::from(carry);
        let n = result >> (w - 1) & 1 == 1;
        let z = result == 0;
        let c = unsigned >> w != 0;
        let v = i128::from(sext(result, w) as i64) != signed;
        (result, [n, z, c, v])
    }

    fn set_flags(&mut self, flags: [bool; 4]) {
        [self.n, self.z, self.c, self.v] = flags;
    }

    fn logic_flags(&mut self, result: u64, sf: bool) {
        self.n = result >> (width(sf) - 1) & 1 == 1;
        self.z = result & mask(sf) == 0;
        self.c = false;
        self.v = false;
    }

    /// Exécute une instruction.
    pub fn step(&mut self, bus: &mut impl Arm64Bus) -> Arm64Step {
        let Some(word) = bus.load(self.pc, 4) else {
            return Arm64Step::Fault(self.pc);
        };
        let insn = word as u32;
        let outcome = match bits(insn, 25, 4) {
            0b1000 | 0b1001 => self.data_immediate(insn),
            0b1010 | 0b1011 => return self.branch_system(insn),
            0b0100 | 0b0110 | 0b1100 | 0b1110 => self.load_store(insn, bus),
            0b0101 | 0b1101 => self.data_register(insn),
            _ => Err(Arm64Step::Undefined(insn)),
        };
        match outcome {
            Ok(()) => {
                self.pc = self.pc.wrapping_add(4);
                Arm64Step::Ran
            }
            Err(step) => step,
        }
    }

    // MARK: - Traitement de données, immédiat

    fn data_immediate(&mut self, insn: u32) -> Result<(), Arm64Step> {
        let undefined = Err(Arm64Step::Undefined(insn));
        let sf = bit(insn, 31);
        let rd = bits(insn, 0, 5);
        let rn = bits(insn, 5, 5);
        match bits(insn, 23, 3) {
            0b000 | 0b001 => {
                // ADR, ADRP.
                let imm = sext(u64::from((bits(insn, 5, 19) << 2) | bits(insn, 29, 2)), 21);
                let value = if bit(insn, 31) {
                    (self.pc & !0xfff).wrapping_add(imm << 12)
                } else {
                    self.pc.wrapping_add(imm)
                };
                self.set_xr(rd, value, true);
            }
            0b010 => {
                // ADD, ADDS, SUB, SUBS (immédiat).
                let mut imm = u64::from(bits(insn, 10, 12));
                if bit(insn, 22) {
                    imm <<= 12;
                }
                let sub = bit(insn, 30);
                let set = bit(insn, 29);
                let operand = self.xsp(rn);
                let (result, flags) = if sub {
                    Self::add_with_carry(operand, !imm, true, sf)
                } else {
                    Self::add_with_carry(operand, imm, false, sf)
                };
                if set {
                    self.set_flags(flags);
                    self.set_xr(rd, result, sf);
                } else {
                    self.set_xsp(rd, result, sf);
                }
            }
            0b100 => {
                // AND, ORR, EOR, ANDS (immédiat).
                let n = bit(insn, 22);
                if !sf && n {
                    return undefined;
                }
                let Some((imm, _)) =
                    decode_bit_masks(n, bits(insn, 10, 6), bits(insn, 16, 6), true, sf)
                else {
                    return undefined;
                };
                let operand = self.xr(rn);
                match bits(insn, 29, 2) {
                    0b00 => self.set_xsp(rd, operand & imm, sf),
                    0b01 => self.set_xsp(rd, operand | imm, sf),
                    0b10 => self.set_xsp(rd, operand ^ imm, sf),
                    _ => {
                        let result = operand & imm & mask(sf);
                        self.logic_flags(result, sf);
                        self.set_xr(rd, result, sf);
                    }
                }
            }
            0b101 => {
                // MOVN, MOVZ, MOVK.
                let hw = bits(insn, 21, 2);
                if !sf && hw > 1 {
                    return undefined;
                }
                let shift = hw * 16;
                let imm = u64::from(bits(insn, 5, 16)) << shift;
                match bits(insn, 29, 2) {
                    0b00 => self.set_xr(rd, !imm, sf),
                    0b10 => self.set_xr(rd, imm, sf),
                    0b11 => {
                        let kept = self.xr(rd) & !(0xffffu64 << shift);
                        self.set_xr(rd, kept | imm, sf);
                    }
                    _ => return undefined,
                }
            }
            0b110 => {
                // SBFM, BFM, UBFM.
                let n = bit(insn, 22);
                let opc = bits(insn, 29, 2);
                let immr = bits(insn, 16, 6);
                let imms = bits(insn, 10, 6);
                if n != sf || opc == 0b11 || (!sf && (immr > 31 || imms > 31)) {
                    return undefined;
                }
                let Some((wmask, tmask)) = decode_bit_masks(n, imms, immr, false, sf) else {
                    return undefined;
                };
                let w = width(sf);
                let src = self.xr(rn) & mask(sf);
                let bot_src = ror(src, immr, w);
                let result = match opc {
                    0b00 => {
                        let bot = bot_src & wmask;
                        let top = if src >> imms & 1 == 1 { mask(sf) } else { 0 };
                        (top & !tmask) | (bot & tmask)
                    }
                    0b01 => {
                        let dst = self.xr(rd);
                        let bot = (dst & !wmask) | (bot_src & wmask);
                        (dst & !tmask) | (bot & tmask)
                    }
                    _ => bot_src & wmask & tmask,
                };
                self.set_xr(rd, result, sf);
            }
            0b111 => {
                // EXTR.
                let n = bit(insn, 22);
                let imms = bits(insn, 10, 6);
                if n != sf || bits(insn, 29, 2) != 0 || bit(insn, 21) || (!sf && imms > 31) {
                    return undefined;
                }
                let w = width(sf);
                let high = u128::from(self.xr(rn) & mask(sf));
                let low = u128::from(self.xr(bits(insn, 16, 5)) & mask(sf));
                let concat = (high << w) | low;
                self.set_xr(rd, (concat >> imms) as u64, sf);
            }
            _ => return undefined,
        }
        Ok(())
    }

    // MARK: - Sauts, exceptions, système

    fn branch_system(&mut self, insn: u32) -> Arm64Step {
        let next = self.pc.wrapping_add(4);
        let undefined = Arm64Step::Undefined(insn);
        if bits(insn, 26, 5) == 0b00101 {
            // B, BL.
            let offset = sext(u64::from(bits(insn, 0, 26)) << 2, 28);
            if bit(insn, 31) {
                self.x[30] = next;
            }
            self.pc = self.pc.wrapping_add(offset);
            return Arm64Step::Ran;
        }
        if bits(insn, 25, 6) == 0b011010 {
            // CBZ, CBNZ.
            let sf = bit(insn, 31);
            let value = self.xr(bits(insn, 0, 5)) & mask(sf);
            let take = (value == 0) != bit(insn, 24);
            let offset = sext(u64::from(bits(insn, 5, 19)) << 2, 21);
            self.pc = if take {
                self.pc.wrapping_add(offset)
            } else {
                next
            };
            return Arm64Step::Ran;
        }
        if bits(insn, 25, 6) == 0b011011 {
            // TBZ, TBNZ.
            let position = (bits(insn, 31, 1) << 5) | bits(insn, 19, 5);
            let set = self.xr(bits(insn, 0, 5)) >> position & 1 == 1;
            let take = set == bit(insn, 24);
            let offset = sext(u64::from(bits(insn, 5, 14)) << 2, 16);
            self.pc = if take {
                self.pc.wrapping_add(offset)
            } else {
                next
            };
            return Arm64Step::Ran;
        }
        if bits(insn, 24, 8) == 0b0101_0100 {
            // B.cond.
            if bit(insn, 4) {
                return undefined;
            }
            let offset = sext(u64::from(bits(insn, 5, 19)) << 2, 21);
            self.pc = if self.condition(bits(insn, 0, 4)) {
                self.pc.wrapping_add(offset)
            } else {
                next
            };
            return Arm64Step::Ran;
        }
        if bits(insn, 24, 8) == 0b1101_0100 {
            let imm = bits(insn, 5, 16) as u16;
            return match (bits(insn, 21, 3), bits(insn, 0, 5)) {
                (0b000, 0b00001) => {
                    self.pc = next;
                    Arm64Step::Svc(imm)
                }
                (0b001, 0b00000) => Arm64Step::Brk(imm),
                _ => undefined,
            };
        }
        if bits(insn, 25, 7) == 0b110_1011 {
            // BR, BLR, RET.
            if bits(insn, 16, 5) != 0b11111 || bits(insn, 10, 6) != 0 || bits(insn, 0, 5) != 0 {
                return undefined;
            }
            let target = self.xr(bits(insn, 5, 5));
            match bits(insn, 21, 4) {
                0b0000 | 0b0010 => {}
                0b0001 => self.x[30] = next,
                _ => return undefined,
            }
            self.pc = target;
            return Arm64Step::Ran;
        }
        if bits(insn, 22, 10) == 0b11_0101_0100 {
            return match self.system(insn) {
                Ok(()) => {
                    self.pc = next;
                    Arm64Step::Ran
                }
                Err(step) => step,
            };
        }
        undefined
    }

    fn system(&mut self, insn: u32) -> Result<(), Arm64Step> {
        let undefined = Err(Arm64Step::Undefined(insn));
        // Les indications (NOP, YIELD, WFE, BTI, PACIASP en espace NOP…)
        // et les barrières : rien à faire pour un seul processeur
        // interprété. CLREX vide le moniteur.
        if insn & 0xffff_f01f == 0xd503_201f {
            return Ok(());
        }
        if insn & 0xffff_f0ff == 0xd503_305f {
            self.exclusive = None;
            return Ok(());
        }
        if insn & 0xffff_f01f == 0xd503_301f {
            return Ok(());
        }
        let rt = bits(insn, 0, 5);
        let register = bits(insn, 5, 15);
        if insn & 0xfff0_0000 == 0xd530_0000 {
            // MRS.
            let value = match register {
                SYSREG_NZCV => self.nzcv(),
                SYSREG_FPCR => self.fpcr,
                SYSREG_FPSR => self.fpsr,
                SYSREG_TPIDR_EL0 => self.tpidr_el0,
                _ => return undefined,
            };
            self.set_xr(rt, value, true);
            return Ok(());
        }
        if insn & 0xfff0_0000 == 0xd510_0000 {
            // MSR (registre).
            let value = self.xr(rt);
            match register {
                SYSREG_NZCV => self.set_nzcv(value),
                SYSREG_FPCR => self.fpcr = value,
                SYSREG_FPSR => self.fpsr = value,
                SYSREG_TPIDR_EL0 => self.tpidr_el0 = value,
                _ => return undefined,
            }
            return Ok(());
        }
        undefined
    }

    // MARK: - Chargements et rangements

    fn load_store(&mut self, insn: u32, bus: &mut impl Arm64Bus) -> Result<(), Arm64Step> {
        let undefined = Err(Arm64Step::Undefined(insn));
        if bit(insn, 26) {
            // Registres SIMD et flottants : pas dans cette tranche.
            return undefined;
        }
        match bits(insn, 27, 3) {
            0b011 if bits(insn, 24, 2) == 0 => self.load_literal(insn, bus),
            0b101 => self.load_store_pair(insn, bus),
            0b111 => self.load_store_register(insn, bus),
            0b001 if bits(insn, 24, 2) == 0 => self.exclusive_access(insn, bus),
            _ => undefined,
        }
    }

    fn load(bus: &mut impl Arm64Bus, address: u64, size: u8) -> Result<u64, Arm64Step> {
        bus.load(address, size).ok_or(Arm64Step::Fault(address))
    }

    fn store(bus: &mut impl Arm64Bus, address: u64, size: u8, value: u64) -> Result<(), Arm64Step> {
        if bus.store(address, size, value) {
            Ok(())
        } else {
            Err(Arm64Step::Fault(address))
        }
    }

    fn load_literal(&mut self, insn: u32, bus: &mut impl Arm64Bus) -> Result<(), Arm64Step> {
        let address = self
            .pc
            .wrapping_add(sext(u64::from(bits(insn, 5, 19)) << 2, 21));
        let rt = bits(insn, 0, 5);
        match bits(insn, 30, 2) {
            0b00 => {
                let value = Self::load(bus, address, 4)?;
                self.set_xr(rt, value, false);
            }
            0b01 => {
                let value = Self::load(bus, address, 8)?;
                self.set_xr(rt, value, true);
            }
            0b10 => {
                let value = Self::load(bus, address, 4)?;
                self.set_xr(rt, sext(value, 32), true);
            }
            _ => {} // PRFM : une indication.
        }
        Ok(())
    }

    fn load_store_pair(&mut self, insn: u32, bus: &mut impl Arm64Bus) -> Result<(), Arm64Step> {
        let undefined = Err(Arm64Step::Undefined(insn));
        let opc = bits(insn, 30, 2);
        let load = bit(insn, 22);
        let (size, signed) = match (opc, load) {
            (0b00, _) => (4u8, false),
            (0b01, true) => (4, true),
            (0b10, _) => (8, false),
            _ => return undefined,
        };
        let mode = bits(insn, 23, 2);
        let offset = sext(u64::from(bits(insn, 15, 7)), 7) << size.trailing_zeros();
        let rn = bits(insn, 5, 5);
        let rt = bits(insn, 0, 5);
        let rt2 = bits(insn, 10, 5);
        let base = self.xsp(rn);
        let address = if mode == 0b01 {
            base
        } else {
            base.wrapping_add(offset)
        };
        let writeback = mode == 0b01 || mode == 0b11;
        if load && rt == rt2 {
            return undefined;
        }
        let second = address.wrapping_add(u64::from(size));
        if load {
            let first_value = Self::load(bus, address, size)?;
            let second_value = Self::load(bus, second, size)?;
            let widen = |value: u64| if signed { sext(value, 32) } else { value };
            let sf = size == 8 || signed;
            self.set_xr(rt, widen(first_value), sf);
            self.set_xr(rt2, widen(second_value), sf);
        } else {
            let first_value = self.xr(rt);
            let second_value = self.xr(rt2);
            Self::store(bus, address, size, first_value)?;
            Self::store(bus, second, size, second_value)?;
        }
        if writeback {
            self.set_xsp(rn, base.wrapping_add(offset), true);
        }
        Ok(())
    }

    fn load_store_register(&mut self, insn: u32, bus: &mut impl Arm64Bus) -> Result<(), Arm64Step> {
        let undefined = Err(Arm64Step::Undefined(insn));
        let size_log = bits(insn, 30, 2);
        let size = 1u8 << size_log;
        let opc = bits(insn, 22, 2);
        let rn = bits(insn, 5, 5);
        let rt = bits(insn, 0, 5);
        let base = self.xsp(rn);
        let (address, writeback) = if bits(insn, 24, 2) == 0b01 {
            (
                base.wrapping_add(u64::from(bits(insn, 10, 12)) << size_log),
                None,
            )
        } else if bits(insn, 24, 2) == 0b00 && !bit(insn, 21) {
            let imm = sext(u64::from(bits(insn, 12, 9)), 9);
            match bits(insn, 10, 2) {
                0b00 | 0b10 => (base.wrapping_add(imm), None),
                0b01 => (base, Some(base.wrapping_add(imm))),
                _ => (base.wrapping_add(imm), Some(base.wrapping_add(imm))),
            }
        } else if bits(insn, 24, 2) == 0b00 && bit(insn, 21) && bits(insn, 10, 2) == 0b10 {
            let option = bits(insn, 13, 3);
            if option & 0b010 == 0 {
                return undefined;
            }
            let shift = if bit(insn, 12) { size_log } else { 0 };
            let offset = Self::extend(self.xr(bits(insn, 16, 5)), option, shift);
            (base.wrapping_add(offset), None)
        } else {
            return undefined;
        };
        // Ce que l'instruction fait de l'octet lu : rangé, chargé tel quel,
        // ou étendu en signe vers 64 ou 32 bits.
        match (size_log, opc) {
            (_, 0b00) => {
                Self::store(bus, address, size, self.xr(rt))?;
            }
            (_, 0b01) => {
                let value = Self::load(bus, address, size)?;
                self.set_xr(rt, value, true);
            }
            (0b11, 0b10) => {} // PRFM.
            (0b00..=0b10, 0b10) => {
                let value = Self::load(bus, address, size)?;
                self.set_xr(rt, sext(value, u32::from(size) * 8), true);
            }
            (0b00 | 0b01, 0b11) => {
                let value = Self::load(bus, address, size)?;
                self.set_xr(rt, sext(value, u32::from(size) * 8), false);
            }
            _ => return undefined,
        }
        if let Some(updated) = writeback {
            self.set_xsp(rn, updated, true);
        }
        Ok(())
    }

    /// `LDXR`, `STXR`, `LDAXR`, `STLXR`, `LDAR`, `STLR`, et leurs paires.
    ///
    /// Un seul processeur, aucun autre observateur : le moniteur exclusif se
    /// réduit à l'adresse du dernier `LDXR`, et un `STXR` réussit quand il
    /// vise la même. C'est ce que le manuel autorise d'une implémentation qui
    /// n'a qu'un fil d'exécution.
    fn exclusive_access(&mut self, insn: u32, bus: &mut impl Arm64Bus) -> Result<(), Arm64Step> {
        let undefined = Err(Arm64Step::Undefined(insn));
        let size_log = bits(insn, 30, 2);
        let o2 = bit(insn, 23);
        let load = bit(insn, 22);
        let o1 = bit(insn, 21);
        let rs = bits(insn, 16, 5);
        let rt2 = bits(insn, 10, 5);
        let rn = bits(insn, 5, 5);
        let rt = bits(insn, 0, 5);
        let address = self.xsp(rn);
        let sf = size_log == 3;
        match (o2, o1) {
            (false, false) => {
                let size = 1u8 << size_log;
                if load {
                    let value = Self::load(bus, address, size)?;
                    self.exclusive = Some(address);
                    self.set_xr(rt, value, true);
                } else {
                    let success = self.exclusive == Some(address);
                    if success {
                        Self::store(bus, address, size, self.xr(rt))?;
                    }
                    self.exclusive = None;
                    self.set_xr(rs, u64::from(!success), false);
                }
            }
            (false, true) => {
                // LDXP, STXP : deux registres de 32 ou 64 bits.
                if size_log < 2 {
                    return undefined;
                }
                let size = 1u8 << size_log;
                let second = address.wrapping_add(u64::from(size));
                if load {
                    let first = Self::load(bus, address, size)?;
                    let next = Self::load(bus, second, size)?;
                    self.exclusive = Some(address);
                    self.set_xr(rt, first, sf);
                    self.set_xr(rt2, next, sf);
                } else {
                    let success = self.exclusive == Some(address);
                    if success {
                        Self::store(bus, address, size, self.xr(rt))?;
                        Self::store(bus, second, size, self.xr(rt2))?;
                    }
                    self.exclusive = None;
                    self.set_xr(rs, u64::from(!success), false);
                }
            }
            (true, false) => {
                // LDAR, STLR (et LDLAR, STLLR) : des accès ordinaires, ici.
                let size = 1u8 << size_log;
                if load {
                    let value = Self::load(bus, address, size)?;
                    self.set_xr(rt, value, true);
                } else {
                    Self::store(bus, address, size, self.xr(rt))?;
                }
            }
            (true, true) => return undefined,
        }
        Ok(())
    }

    /// `ExtendReg` : `option` dit la largeur et le signe, puis le décalage.
    fn extend(value: u64, option: u32, shift: u32) -> u64 {
        let size = 8u32 << (option & 0b11);
        let extended = if option & 0b100 != 0 {
            sext(value & ones(size), size)
        } else {
            value & ones(size)
        };
        extended << shift
    }

    // MARK: - Traitement de données, registres

    fn data_register(&mut self, insn: u32) -> Result<(), Arm64Step> {
        let undefined = Err(Arm64Step::Undefined(insn));
        let sf = bit(insn, 31);
        let rd = bits(insn, 0, 5);
        let rn = bits(insn, 5, 5);
        let rm = bits(insn, 16, 5);
        let op1 = bit(insn, 28);
        let op2 = bits(insn, 21, 4);
        if !op1 {
            if op2 & 0b1000 == 0 {
                // Logique, registre décalé.
                let amount = bits(insn, 10, 6);
                if !sf && amount > 31 {
                    return undefined;
                }
                let mut operand = Self::arith_shift(self.xr(rm), bits(insn, 22, 2), amount, sf);
                if bit(insn, 21) {
                    operand = !operand & mask(sf);
                }
                let first = self.xr(rn) & mask(sf);
                let result = match bits(insn, 29, 2) {
                    0b00 | 0b11 => first & operand,
                    0b01 => first | operand,
                    _ => first ^ operand,
                };
                if bits(insn, 29, 2) == 0b11 {
                    self.logic_flags(result, sf);
                }
                self.set_xr(rd, result, sf);
                return Ok(());
            }
            let sub = bit(insn, 30);
            let set = bit(insn, 29);
            if op2 & 0b0001 == 0 {
                // ADD, SUB, registre décalé.
                let kind = bits(insn, 22, 2);
                let amount = bits(insn, 10, 6);
                if kind == 0b11 || (!sf && amount > 31) {
                    return undefined;
                }
                let operand = Self::arith_shift(self.xr(rm), kind, amount, sf);
                let first = self.xr(rn);
                let (result, flags) = if sub {
                    Self::add_with_carry(first, !operand, true, sf)
                } else {
                    Self::add_with_carry(first, operand, false, sf)
                };
                if set {
                    self.set_flags(flags);
                }
                self.set_xr(rd, result, sf);
                return Ok(());
            }
            // ADD, SUB, registre étendu.
            let amount = bits(insn, 10, 3);
            if bits(insn, 22, 2) != 0 || amount > 4 {
                return undefined;
            }
            let operand = Self::extend(self.xr(rm), bits(insn, 13, 3), amount) & mask(sf);
            let first = self.xsp(rn);
            let (result, flags) = if sub {
                Self::add_with_carry(first, !operand, true, sf)
            } else {
                Self::add_with_carry(first, operand, false, sf)
            };
            if set {
                self.set_flags(flags);
                self.set_xr(rd, result, sf);
            } else {
                self.set_xsp(rd, result, sf);
            }
            return Ok(());
        }
        match op2 {
            0b0000 => {
                // ADC, ADCS, SBC, SBCS.
                if bits(insn, 10, 6) != 0 {
                    return undefined;
                }
                let operand = if bit(insn, 30) {
                    !self.xr(rm)
                } else {
                    self.xr(rm)
                };
                let (result, flags) = Self::add_with_carry(self.xr(rn), operand, self.c, sf);
                if bit(insn, 29) {
                    self.set_flags(flags);
                }
                self.set_xr(rd, result, sf);
            }
            0b0010 => {
                // CCMN, CCMP, registre ou immédiat.
                if !bit(insn, 29) || bit(insn, 10) || bit(insn, 4) {
                    return undefined;
                }
                if self.condition(bits(insn, 12, 4)) {
                    let operand = if bit(insn, 11) {
                        u64::from(rm)
                    } else {
                        self.xr(rm)
                    };
                    let (_, flags) = if bit(insn, 30) {
                        Self::add_with_carry(self.xr(rn), !operand, true, sf)
                    } else {
                        Self::add_with_carry(self.xr(rn), operand, false, sf)
                    };
                    self.set_flags(flags);
                } else {
                    self.set_nzcv(u64::from(bits(insn, 0, 4)) << 28);
                }
            }
            0b0100 => {
                // CSEL, CSINC, CSINV, CSNEG.
                if bit(insn, 29) || bit(insn, 11) {
                    return undefined;
                }
                let result = if self.condition(bits(insn, 12, 4)) {
                    self.xr(rn)
                } else {
                    let other = self.xr(rm);
                    match (bit(insn, 30), bit(insn, 10)) {
                        (false, false) => other,
                        (false, true) => other.wrapping_add(1),
                        (true, false) => !other,
                        (true, true) => other.wrapping_neg(),
                    }
                };
                self.set_xr(rd, result, sf);
            }
            0b0110 if !bit(insn, 30) => {
                if bit(insn, 29) {
                    return undefined;
                }
                let w = width(sf);
                let first = self.xr(rn) & mask(sf);
                let second = self.xr(rm) & mask(sf);
                let result = match bits(insn, 10, 6) {
                    0b00_0010 => first.checked_div(second).unwrap_or(0),
                    0b00_0011 => {
                        let a = sext(first, w) as i64;
                        let b = sext(second, w) as i64;
                        if b == 0 {
                            0
                        } else {
                            a.wrapping_div(b) as u64
                        }
                    }
                    0b00_1000 => first << (second % u64::from(w)),
                    0b00_1001 => first >> (second % u64::from(w)),
                    0b00_1010 => Self::arith_shift(first, 0b10, (second % u64::from(w)) as u32, sf),
                    0b00_1011 => ror(first, (second % u64::from(w)) as u32, w),
                    _ => return undefined,
                };
                self.set_xr(rd, result, sf);
            }
            0b0110 => {
                // Une seule source.
                if bit(insn, 29) || rm != 0 {
                    return undefined;
                }
                let w = width(sf);
                let value = self.xr(rn) & mask(sf);
                let result = match bits(insn, 10, 6) {
                    0b00_0000 => value.reverse_bits() >> (64 - w),
                    0b00_0001 => Self::reverse_bytes_in(value, 2),
                    0b00_0010 if sf => Self::reverse_bytes_in(value, 4),
                    0b00_0010 => u64::from((value as u32).swap_bytes()),
                    0b00_0011 if sf => value.swap_bytes(),
                    0b00_0100 => u64::from((value << (64 - w)).leading_zeros().min(w)),
                    0b00_0101 => {
                        let signed = sext(value, w);
                        let leading = if signed >> 63 == 1 {
                            (!signed).leading_zeros()
                        } else {
                            signed.leading_zeros()
                        };
                        u64::from(leading - 1 - (64 - w))
                    }
                    _ => return undefined,
                };
                self.set_xr(rd, result, sf);
            }
            0b1000..=0b1111 => {
                // MADD, MSUB, SMADDL, SMSUBL, SMULH, UMADDL, UMSUBL, UMULH.
                if bits(insn, 29, 2) != 0 {
                    return undefined;
                }
                let ra = bits(insn, 10, 5);
                let subtract = bit(insn, 15);
                let first = self.xr(rn);
                let second = self.xr(rm);
                let accumulate = self.xr(ra);
                let result = match (bits(insn, 21, 3), sf) {
                    (0b000, _) => {
                        let product = first.wrapping_mul(second);
                        if subtract {
                            accumulate.wrapping_sub(product)
                        } else {
                            accumulate.wrapping_add(product)
                        }
                    }
                    (0b001, true) => {
                        let product =
                            i64::from(first as i32).wrapping_mul(i64::from(second as i32)) as u64;
                        if subtract {
                            accumulate.wrapping_sub(product)
                        } else {
                            accumulate.wrapping_add(product)
                        }
                    }
                    (0b101, true) => {
                        let product = u64::from(first as u32) * u64::from(second as u32);
                        if subtract {
                            accumulate.wrapping_sub(product)
                        } else {
                            accumulate.wrapping_add(product)
                        }
                    }
                    (0b010, true) if !subtract => {
                        ((i128::from(first as i64) * i128::from(second as i64)) >> 64) as u64
                    }
                    (0b110, true) if !subtract => {
                        ((u128::from(first) * u128::from(second)) >> 64) as u64
                    }
                    _ => return undefined,
                };
                self.set_xr(rd, result, sf);
            }
            _ => return undefined,
        }
        Ok(())
    }

    /// `ShiftReg` : LSL, LSR, ASR, ROR d'un opérande.
    fn arith_shift(value: u64, kind: u32, amount: u32, sf: bool) -> u64 {
        let w = width(sf);
        let value = value & mask(sf);
        let result = match kind {
            0b00 => value << amount,
            0b01 => value >> amount,
            0b10 => ((sext(value, w) as i64) >> amount) as u64,
            _ => ror(value, amount, w),
        };
        result & mask(sf)
    }

    /// Retourne les octets de chaque morceau de `chunk` octets.
    fn reverse_bytes_in(value: u64, chunk: u32) -> u64 {
        let bytes = value.to_le_bytes();
        let mut out = [0u8; 8];
        for (index, piece) in bytes.chunks(chunk as usize).enumerate() {
            for (offset, byte) in piece.iter().rev().enumerate() {
                out[index * chunk as usize + offset] = *byte;
            }
        }
        u64::from_le_bytes(out)
    }
}
