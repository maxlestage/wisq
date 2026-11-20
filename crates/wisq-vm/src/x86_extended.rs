//! **Les instructions que la machine PC native exécute, et que l'émetteur ne
//! traduit pas.**
//!
//! `decode` ne lit que ce que l'émetteur sait produire : une instruction lue
//! et non traduite refuserait sa région entière, et `Op` est jugé cas par cas
//! dans `x86_wasm.rs`. Y ajouter une forme, c'est la demander à l'émetteur.
//! Ce fichier est donc **un second décodeur, à côté**, que seule la machine
//! native consulte, et seulement quand le premier a refusé : `decode_extended`
//! rend une `Extended`, `Cpu::execute_extended` l'exécute. L'émetteur ne voit
//! ni l'un ni l'autre.
//!
//! **Chaque forme d'ici a été trouvée par un arrêt** — la machine s'arrête en
//! nommant les octets qu'elle ne lit pas — et dit où. Aucune n'est devinée :
//! une forme absente reste un arrêt nommé (dans le noyau) ou une `#UD` (dans
//! un programme).

use super::{read_modrm, Address, Cpu, Prefixes, Width};

/// Une instruction de ce second décodeur.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Extended {
    pub op: Extra,
    /// La largeur de l'opération.
    pub width: Width,
    /// Le champ `reg` du ModRM, quand la forme en a un.
    pub reg: u8,
    /// Le registre `rm`, quand l'opérande n'est pas en mémoire.
    pub rm: u8,
    /// L'opérande mémoire, quand il y en a un.
    pub memory: Option<Address>,
    pub imm: u64,
    /// Les octets consommés.
    pub length: usize,
}

/// Ce que l'instruction fait.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Extra {
    /// **Les mots du coprocesseur x87 qui se lisent et s'écrivent sans
    /// calculer.** Le décompresseur du noyau les exécute pour savoir s'il a
    /// un coprocesseur — `fninit`, puis il relit les deux mots et les compare
    /// à ce que le silicium y laisse (`dd 7c 24 0e`, `d9 7c 24 0c`, à 512 529
    /// instructions du démarrage d'Alpine 6.18) —, et la bibliothèque C sauve
    /// et rétablit le mot de contrôle autour de ses arrondis. Aucune ne touche
    /// à la pile du x87 : ni au sommet, ni aux registres, ni aux étiquettes.
    FpuWord(FpuWord),
    /// **`emms` (`0F 77`)** : toutes les étiquettes du x87 passent à « vide ».
    /// Rien d'autre ne bouge — ni le sommet, ni les registres.
    ///
    /// Le noyau l'exécute dans `restore_fpregs_from_fpstate`, avec `fnclex` et
    /// un `fildl`, sur tout processeur AMD : c'est sa parade à
    /// `X86_BUG_FXSAVE_LEAK` (`0f 77 db 07`, à 1,48 milliard d'instructions du
    /// démarrage d'Alpine 6.18).
    Emms,
    /// **`fild`** : empiler un entier signé lu en mémoire — seize bits
    /// (`DF /0`), trente-deux (`DB /0`) ou soixante-quatre (`DF /5`). La
    /// conversion est exacte : un entier de soixante-quatre bits tient dans
    /// la mantisse d'un registre du x87.
    FpuLoadInteger,
}

/// Lequel des mots d'état du x87 une instruction lit ou écrit.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FpuWord {
    /// `fnstcw m16` (`D9 /7`) : le mot de contrôle, vers la mémoire.
    StoreControl,
    /// `fldcw m16` (`D9 /5`) : le mot de contrôle, depuis la mémoire.
    LoadControl,
    /// `fnstsw m16` (`DD /7`) : le mot d'état, vers la mémoire.
    StoreStatus,
    /// `fnstsw %ax` (`DF E0`) : le mot d'état, dans AX.
    StatusToAccumulator,
    /// `fnclex` (`DB E2`) : effacer les exceptions en attente du mot d'état.
    ClearExceptions,
}

/// Pourquoi une instruction de ce décodeur n'est pas allée au bout.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ExtendedFault {
    /// Un opérande en mémoire n'est pas accessible : `Cpu::unmapped` dit
    /// lequel, et la machine en fait une faute de page.
    Memory,
    /// `fxrstor` avec un MXCSR aux bits réservés levés : `#GP(0)`, rien de
    /// changé.
    ReservedControl,
}

/// **Ce que `fxsave` écrit vraiment : 416 octets, pas 512.** L'aire que
/// l'instruction réserve fait 512 octets, mais les quatre-vingt-seize derniers
/// sont laissés tels quels — mesuré sur le silicium, voir
/// `x86-fxsave-oracle.tsv`.
pub const FXSAVE_WRITTEN: usize = 416;

/// Les bits du mot d'état du x87.
const INVALID: u16 = 1 << 0;
const STACK_FAULT: u16 = 1 << 6;
const ERROR_SUMMARY: u16 = 1 << 7;
const C1: u16 = 1 << 9;
const BUSY: u16 = 1 << 15;

/// **Lire les préfixes**, comme `decode` les lit : 0x66, 0xF3, 0xF2, les
/// segments, `lock`, puis REX — qui doit toucher l'opcode, un préfixe hérité
/// lu après lui l'annule. Rend les préfixes et la place de l'opcode.
fn prefixes(bytes: &[u8]) -> (Prefixes, usize) {
    let mut at = 0usize;
    let mut prefixes = Prefixes::default();
    while at < bytes.len() {
        match bytes[at] {
            0x66 => prefixes.operand_size = true,
            0xf3 => prefixes.repeat = true,
            0xf2 => prefixes.repeat_not = true,
            0x2e | 0x36 | 0x3e | 0x26 | 0xf0 => {}
            0x65 => {
                prefixes.segment_gs = true;
                prefixes.segment_fs = false;
            }
            0x64 => {
                prefixes.segment_fs = true;
                prefixes.segment_gs = false;
            }
            0x67 => prefixes.address_size = true,
            rex @ 0x40..=0x4f => {
                prefixes.rex = Some(rex);
                at += 1;
                break;
            }
            _ => break,
        }
        prefixes.rex = None;
        at += 1;
    }
    (prefixes, at)
}

/// **Décoder ce que `decode` refuse et que la machine native sait faire.**
/// `None` pour tout le reste : refuser plutôt que deviner.
pub fn decode_extended(bytes: &[u8]) -> Option<Extended> {
    let (prefixes, mut at) = prefixes(bytes);
    // La taille d'adresse de trente-deux bits n'est pas portée ici non plus.
    if prefixes.address_size {
        return None;
    }
    let opcode = *bytes.get(at)?;
    at += 1;
    let plain = !prefixes.operand_size && !prefixes.repeat && !prefixes.repeat_not;
    let nothing = |op: Extra, length: usize| Extended {
        op,
        width: Width::Word,
        reg: 0,
        rm: 0,
        memory: None,
        imm: 0,
        length,
    };
    match opcode {
        // **Le x87, par ses seuls mots d'état.** Le sens n'est pas dans
        // l'opcode mais dans le ModRM : en mémoire, le champ `reg` choisit
        // l'instruction ; en registre, c'est l'octet entier.
        0xd9 | 0xdd if plain => {
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let memory = field.memory?;
            let word = match (opcode, field.reg & 0b111) {
                (0xd9, 5) => FpuWord::LoadControl,
                (0xd9, 7) => FpuWord::StoreControl,
                (0xdd, 7) => FpuWord::StoreStatus,
                _ => return None,
            };
            Some(Extended {
                memory: Some(memory),
                ..nothing(Extra::FpuWord(word), at)
            })
        }
        // **`fild`, aux trois largeurs.** `DB /0` charge trente-deux bits,
        // `DF /0` seize, `DF /5` soixante-quatre.
        0xdb | 0xdf if plain && bytes.get(at).is_some_and(|modrm| modrm >> 6 != 0b11) => {
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let width = match (opcode, field.reg & 0b111) {
                (0xdb, 0) => Width::Dword,
                (0xdf, 0) => Width::Word,
                (0xdf, 5) => Width::Qword,
                _ => return None,
            };
            Some(Extended {
                width,
                memory: field.memory,
                ..nothing(Extra::FpuLoadInteger, at)
            })
        }
        0x0f if plain && bytes.get(at) == Some(&0x77) => Some(nothing(Extra::Emms, at + 1)),
        0xdf if plain && bytes.get(at) == Some(&0xe0) => Some(nothing(
            Extra::FpuWord(FpuWord::StatusToAccumulator),
            at + 1,
        )),
        0xdb if plain && bytes.get(at) == Some(&0xe2) => {
            Some(nothing(Extra::FpuWord(FpuWord::ClearExceptions), at + 1))
        }
        _ => None,
    }
}

impl Cpu {
    /// **Exécuter une instruction du second décodeur.** RIP n'est pas avancé :
    /// c'est l'appelant qui le fait, comme pour `execute`. Une instruction qui
    /// faute n'a rien changé.
    pub fn execute_extended(&mut self, instruction: &Extended) -> Result<(), ExtendedFault> {
        let at = instruction.memory.map(|address| {
            let after = self.rip.wrapping_add(instruction.length as u64);
            self.effective_address(&address, after)
        });
        match instruction.op {
            Extra::FpuWord(word) => match word {
                FpuWord::StoreControl => {
                    let at = at.expect("fnstcw écrit la mémoire");
                    self.extended_write(at, Width::Word, u64::from(self.fpu_control))?;
                }
                FpuWord::LoadControl => {
                    let at = at.expect("fldcw lit la mémoire");
                    self.fpu_control = self.extended_read(at, Width::Word)? as u16;
                }
                FpuWord::StoreStatus => {
                    let at = at.expect("fnstsw écrit la mémoire");
                    self.extended_write(at, Width::Word, u64::from(self.fpu_status))?;
                }
                FpuWord::StatusToAccumulator => {
                    self.set(0, Width::Word, false, u64::from(self.fpu_status));
                }
                // Les sept bits d'exception, et « occupé » : les autres — la
                // pile, les codes de condition — restent.
                FpuWord::ClearExceptions => self.fpu_status &= 0x7f00,
            },
            Extra::Emms => self.fpu_tags = 0,
            Extra::FpuLoadInteger => {
                let at = at.expect("fild lit la mémoire");
                let raw = self.extended_read(at, instruction.width)?;
                let shift = 64 - instruction.width.bits() as u32;
                let value = ((raw << shift) as i64) >> shift;
                self.x87_push(Self::x87_from_integer(value));
            }
        }
        Ok(())
    }

    /// Le sommet de la pile du x87 : les bits 11 à 13 du mot d'état.
    pub fn x87_top(&self) -> usize {
        usize::from((self.fpu_status >> 11) & 7)
    }

    /// Un entier signé, en registre du x87. Exact : la mantisse a
    /// soixante-quatre bits, son bit de tête explicite.
    pub fn x87_from_integer(value: i64) -> (u64, u16) {
        if value == 0 {
            return (0, 0);
        }
        let magnitude = value.unsigned_abs();
        let lead = magnitude.leading_zeros();
        let exponent = 16383 + 63 - lead as u16;
        (
            magnitude << lead,
            exponent | if value < 0 { 0x8000 } else { 0 },
        )
    }

    /// **Empiler une valeur.** Le sommet descend d'un cran ; si le registre
    /// qu'il désigne alors est occupé, c'est un débordement de pile : le mot
    /// d'état le dit (invalide, faute de pile, C1), et — l'exception masquée,
    /// ce qu'elle est après `fninit` — la valeur empilée est le NaN indéfini.
    pub fn x87_push(&mut self, value: (u64, u16)) {
        let top = (self.x87_top() + 7) & 7;
        self.fpu_status = (self.fpu_status & !(7 << 11)) | ((top as u16) << 11);
        if self.fpu_tags & (1 << top) != 0 {
            self.fpu_status |= INVALID | STACK_FAULT | C1;
            self.x87[top] = (0xC000_0000_0000_0000, 0xFFFF);
            self.x87_summarise();
            return;
        }
        self.fpu_status &= !C1;
        self.x87[top] = value;
        self.fpu_tags |= 1 << top;
    }

    /// Les bits « résumé d'erreur » et « occupé » suivent les exceptions en
    /// attente que le mot de contrôle ne masque pas — ce que le silicium
    /// recalcule lui-même, y compris en relisant une aire de `fxrstor`.
    fn x87_summarise(&mut self) {
        if self.fpu_status & !self.fpu_control & 0x3f != 0 {
            self.fpu_status |= ERROR_SUMMARY | BUSY;
        } else {
            self.fpu_status &= !(ERROR_SUMMARY | BUSY);
        }
    }

    /// **Le mot d'étiquettes complet**, deux bits par registre physique, tel
    /// que `fnstenv` et `fnsave` le rendent : 00 valide, 01 zéro, 10 spécial
    /// (NaN, infini, dénormalisé), 11 vide. Il se recalcule des registres :
    /// le processeur ne garde que « occupé ou non ».
    pub fn x87_tag_word(&self) -> u16 {
        (0..8).fold(0u16, |word, index| {
            let (significand, sign_exponent) = self.x87[index];
            let exponent = sign_exponent & 0x7fff;
            let tag = if self.fpu_tags & (1 << index) == 0 {
                0b11
            } else if exponent == 0 && significand == 0 {
                0b01
            } else if exponent == 0 || exponent == 0x7fff || significand >> 63 == 0 {
                0b10
            } else {
                0b00
            };
            word | tag << (2 * index)
        })
    }

    /// **`fxsave`** : écrire l'aire de 512 octets — dont 416 seulement sont
    /// écrits. Les deux bouts de l'aire sont traduits avant qu'un octet ne
    /// soit posé : elle doit être accessible **en entier**, ce que le silicium
    /// exige aussi, et une faute ne laisse rien derrière elle.
    ///
    /// Le format est celui du mode 64 bits : les deux mots, les étiquettes
    /// abrégées, MXCSR et son masque, les huit registres du x87 **dans l'ordre
    /// de la pile**, puis les seize XMM. FOP, FIP et FDP sont nuls : ce cœur
    /// ne les tient pas.
    pub fn save_floating_point_state(&mut self, at: u64) -> Result<(), ExtendedFault> {
        use crate::x86_paging::Access;
        for edge in [at, at.wrapping_add(511)] {
            self.probe_memory(edge, Access::Write)
                .map_err(|_| ExtendedFault::Memory)?;
        }
        let mut area = [0u8; FXSAVE_WRITTEN];
        area[0..2].copy_from_slice(&self.fpu_control.to_le_bytes());
        area[2..4].copy_from_slice(&self.fpu_status.to_le_bytes());
        area[4] = self.fpu_tags;
        area[0x18..0x1c].copy_from_slice(&self.mxcsr.to_le_bytes());
        // Le masque de MXCSR : les bits qu'un programme a le droit de poser.
        area[0x1c..0x20].copy_from_slice(&super::MXCSR_MASK.to_le_bytes());
        let top = self.x87_top();
        for index in 0..8 {
            let (significand, sign_exponent) = self.x87[(top + index) & 7];
            let slot = 0x20 + 16 * index;
            area[slot..slot + 8].copy_from_slice(&significand.to_le_bytes());
            area[slot + 8..slot + 10].copy_from_slice(&sign_exponent.to_le_bytes());
        }
        for (index, register) in self.xmm.iter().enumerate() {
            let slot = 0xa0 + 16 * index;
            area[slot..slot + 8].copy_from_slice(&register[0].to_le_bytes());
            area[slot + 8..slot + 16].copy_from_slice(&register[1].to_le_bytes());
        }
        for (index, word) in area.chunks_exact(8).enumerate() {
            let value = u64::from_le_bytes(word.try_into().expect("huit octets"));
            self.extended_write(at.wrapping_add(8 * index as u64), Width::Qword, value)?;
        }
        Ok(())
    }

    /// **`fxrstor`** : relire l'aire. Elle doit être lisible en entier, et un
    /// MXCSR aux bits réservés levés est une `#GP(0)` qui ne change rien.
    ///
    /// **Ce que le silicium corrige en relisant**, mesuré par
    /// `x86-fxsave-oracle.tsv` : le bit 6 du mot de contrôle se relit toujours
    /// à un, et les bits « résumé d'erreur » et « occupé » du mot d'état sont
    /// recalculés des exceptions en attente — ce que l'aire en dit est ignoré.
    pub fn restore_floating_point_state(&mut self, at: u64) -> Result<(), ExtendedFault> {
        use crate::x86_paging::Access;
        for edge in [at, at.wrapping_add(511)] {
            self.probe_memory(edge, Access::Read)
                .map_err(|_| ExtendedFault::Memory)?;
        }
        let mut area = [0u8; FXSAVE_WRITTEN];
        for (index, word) in area.chunks_exact_mut(8).enumerate() {
            let value = self.extended_read(at.wrapping_add(8 * index as u64), Width::Qword)?;
            word.copy_from_slice(&value.to_le_bytes());
        }
        let half = |slot: usize| u16::from_le_bytes([area[slot], area[slot + 1]]);
        let whole =
            |slot: usize| u64::from_le_bytes(area[slot..slot + 8].try_into().expect("huit octets"));
        let mxcsr = whole(0x18) as u32;
        if mxcsr & !super::MXCSR_MASK != 0 {
            return Err(ExtendedFault::ReservedControl);
        }
        self.fpu_control = half(0) | 0x40;
        self.fpu_status = half(2);
        self.x87_summarise();
        self.fpu_tags = area[4];
        self.mxcsr = mxcsr;
        let top = self.x87_top();
        for index in 0..8 {
            let slot = 0x20 + 16 * index;
            self.x87[(top + index) & 7] = (whole(slot), half(slot + 8));
        }
        for (index, register) in self.xmm.iter_mut().enumerate() {
            let slot = 0xa0 + 16 * index;
            *register = [whole(slot), whole(slot + 8)];
        }
        Ok(())
    }

    fn extended_read(&mut self, at: u64, width: Width) -> Result<u64, ExtendedFault> {
        self.read_memory(at, width)
            .map_err(|_| ExtendedFault::Memory)
    }

    fn extended_write(&mut self, at: u64, width: Width, value: u64) -> Result<(), ExtendedFault> {
        self.write_memory(at, width, value)
            .map_err(|_| ExtendedFault::Memory)
    }
}
