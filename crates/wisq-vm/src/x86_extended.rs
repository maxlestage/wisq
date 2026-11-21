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

#[path = "x86_f80.rs"]
pub mod f80;
#[path = "x86_mmx.rs"]
mod mmx;
#[path = "x86_sse.rs"]
mod sse;
#[path = "x86_x87.rs"]
mod x87;

pub use mmx::Mmx;
pub use sse::{FloatOp, Sse};

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
    /// **Une instruction du x87** (`D8` à `DF`) : l'opcode et le ModRM, que
    /// `x86_x87.rs` lit comme le silicium — l'octet entier en forme registre,
    /// le champ `reg` et l'opcode en forme mémoire. `width` vaut `Word` sous
    /// le préfixe `66` (les environnements de quatorze octets), `Dword` sinon.
    ///
    /// Le décompresseur du noyau en exécute les premiers pour savoir s'il a
    /// un coprocesseur — `fninit`, puis `fnstsw` et `fnstcw` (`dd 7c 24 0e`,
    /// `d9 7c 24 0c`, à 512 529 instructions du démarrage d'Alpine 6.18) ; le
    /// noyau un `fildl` (`X86_BUG_FXSAVE_LEAK`) ; et l'espace utilisateur le
    /// reste : le `long double` de `printf`, la `libm`.
    X87 { opcode: u8, modrm: u8 },
    /// **`emms` (`0F 77`)** : toutes les étiquettes du x87 passent à « vide ».
    /// Rien d'autre ne bouge — ni le sommet, ni les registres.
    ///
    /// Le noyau l'exécute dans `restore_fpregs_from_fpstate`, avec `fnclex` et
    /// un `fildl`, sur tout processeur AMD : c'est sa parade à
    /// `X86_BUG_FXSAVE_LEAK` (`0f 77 db 07`, à 1,48 milliard d'instructions du
    /// démarrage d'Alpine 6.18).
    Emms,
    /// **Une instruction MMX** : voir `x86_mmx.rs`.
    Mmx(Mmx),
    /// **Le calcul flottant de SSE et SSE2** : voir `x86_sse.rs`.
    Sse(Sse),
}

/// Pourquoi une instruction de ce décodeur n'est pas allée au bout.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ExtendedFault {
    /// Un opérande en mémoire n'est pas accessible : `Cpu::unmapped` dit
    /// lequel, et la machine en fait une faute de page.
    Memory,
    /// Une exception flottante de SSE que MXCSR ne masque pas : le drapeau
    /// est posé, rien n'est rangé, et la machine livre `#XM`.
    SimdException,
    /// **Une exception du x87 démasquée, en attente** (ES levé dans le mot
    /// d'état) au moment d'une instruction du x87 qui attend, ou du MMX :
    /// l'instruction ne s'exécute pas, et la machine livre `#MF`.
    FloatingPoint,
    /// `fxrstor` avec un MXCSR aux bits réservés levés : `#GP(0)`, rien de
    /// changé.
    ReservedControl,
}

/// **Ce que `fxsave` écrit vraiment : 416 octets, pas 512.** L'aire que
/// l'instruction réserve fait 512 octets, mais les quatre-vingt-seize derniers
/// sont laissés tels quels — mesuré sur le silicium, voir
/// `x86-fxsave-oracle.tsv`.
pub const FXSAVE_WRITTEN: usize = 416;

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
        // **Le x87.** Le sens n'est pas dans l'opcode mais dans le ModRM : en
        // mémoire, le champ `reg` choisit l'instruction ; en registre, c'est
        // l'octet entier. `66` ne change que la taille des environnements ;
        // `f2` et `f3` ne désignent rien et sont refusés.
        0xd8..=0xdf if !prefixes.repeat && !prefixes.repeat_not => {
            let modrm = *bytes.get(at)?;
            if !x87::valid(opcode, modrm) {
                return None;
            }
            let field = read_modrm(bytes, &mut at, prefixes)?;
            Some(Extended {
                width: if prefixes.operand_size {
                    Width::Word
                } else {
                    Width::Dword
                },
                memory: field.memory,
                ..nothing(Extra::X87 { opcode, modrm }, at)
            })
        }
        0x0f if plain && bytes.get(at) == Some(&0x77) => Some(nothing(Extra::Emms, at + 1)),
        // **La page `0f`** : le MMX et le flottant de SSE. Le préfixe
        // obligatoire fait partie de l'opcode ; deux à la fois ne désignent
        // rien de sûr.
        0x0f => {
            let mandatory = match (prefixes.operand_size, prefixes.repeat, prefixes.repeat_not) {
                (false, false, false) => 0,
                (true, false, false) => 0x66,
                (false, true, false) => 0xf3,
                (false, false, true) => 0xf2,
                _ => return None,
            };
            let second = *bytes.get(at)?;
            at += 1;
            let modrm = *bytes.get(at)?;
            let (op, immediate) =
                if let Some((form, immediate)) = mmx::decode(mandatory, second, modrm) {
                    (Extra::Mmx(form), immediate)
                } else if let Some((form, immediate)) = sse::decode(mandatory, second) {
                    (Extra::Sse(form), immediate)
                } else {
                    return None;
                };
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let imm = if immediate {
                let value = u64::from(*bytes.get(at)?);
                at += 1;
                value
            } else {
                0
            };
            // `movd`/`movq` et les conversions avec un registre général :
            // huit octets sous `REX.W`, quatre sinon. `pinsrw` lit seize bits.
            let wide = prefixes.rex.is_some_and(|rex| rex & 0b1000 != 0);
            let width = if wide { Width::Qword } else { Width::Dword };
            Some(Extended {
                op,
                width,
                reg: field.reg,
                rm: field.register,
                memory: field.memory,
                imm,
                length: at,
            })
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
            Extra::X87 { .. } => self.execute_x87(instruction, at),
            // Le MMX partage l'état du x87 : une exception du x87 en attente
            // l'arrête aussi.
            Extra::Emms | Extra::Mmx(_) if self.x87_pending() => Err(ExtendedFault::FloatingPoint),
            Extra::Emms => {
                self.fpu_tags = 0;
                Ok(())
            }
            Extra::Mmx(_) => self.execute_mmx(instruction, at),
            Extra::Sse(_) => self.execute_sse(instruction, at),
        }
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
