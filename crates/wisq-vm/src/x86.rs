//! **Un cœur x86-64 sans JIT — et pourquoi « sans JIT » n'est pas « lent ».**
//!
//! Ce qu'on sait, mesuré : l'interpréteur x86 en Swift rend **10,6 MIPS**, le
//! cœur rv32 en Rust en rend **157**, et un module WebAssembly compilé par
//! WebKit en rend **1103**. Rien sans JIT ne rattrapera 1103. Mais 10,6 n'est
//! pas la limite de ce qu'on peut faire sans JIT, et ce fichier va chercher ce
//! qui manque entre les deux.
//!
//! Ce que ce cœur a de mieux qu'un JIT, et qui ne se voit pas dans un débit :
//! il ne demande **aucune permission**. Pas de `WKWebView`, pas de pont, pas
//! de droit spécial, rien à négocier avec Apple. Il tourne partout où le
//! binaire tourne, sur l'App Store aujourd'hui, derrière l'API C qui existe
//! déjà.
//!
//! **Les drapeaux paresseux, et c'est le cœur du sujet.** x86 pose six
//! drapeaux à presque chaque opération arithmétique, et un programme en lit
//! une poignée. Les calculer tous, tout le temps, est le gros du coût d'un
//! interpréteur x86 — le module WebAssembly « réaliste » du lot 8 paie
//! exactement ça, quatre drapeaux calculés par tour. Ici on ne garde que
//! **l'opération et ses deux opérandes** ; un drapeau ne se calcule que
//! lorsqu'on le lit. C'est ce que font QEMU, Bochs et v86, et pour la même
//! raison.
//!
//! **Ce qui est jugé, et par quoi.** Les 2016 cas de `x86-oracle.tsv` qui
//! portent sur ce groupe viennent d'un vrai processeur, pas d'un modèle. Un
//! cœur qui se juge lui-même ne se juge pas.

/// La largeur d'une opération, en octets.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Width {
    Byte = 1,
    Word = 2,
    Dword = 4,
    Qword = 8,
}

impl Width {
    /// Le masque des bits que cette largeur retient.
    pub const fn mask(self) -> u64 {
        match self {
            Width::Byte => 0xff,
            Width::Word => 0xffff,
            Width::Dword => 0xffff_ffff,
            Width::Qword => u64::MAX,
        }
    }

    /// Le bit de signe.
    pub const fn sign(self) -> u64 {
        match self {
            Width::Byte => 1 << 7,
            Width::Word => 1 << 15,
            Width::Dword => 1 << 31,
            Width::Qword => 1 << 63,
        }
    }
}

pub const CF: u64 = 1 << 0;
/// Le bit 1 de RFLAGS vaut toujours 1 sur x86. Ce n'est pas un drapeau, c'est
/// une constante de l'architecture, et l'oracle matériel la porte.
pub const ALWAYS_ONE: u64 = 1 << 1;
pub const PF: u64 = 1 << 2;
pub const AF: u64 = 1 << 4;
pub const ZF: u64 = 1 << 6;
pub const SF: u64 = 1 << 7;
pub const OF: u64 = 1 << 11;

/// Les six que l'arithmétique définit. Tout le reste — DF, IF, TF… — survit à
/// une opération arithmétique et vit ailleurs.
pub const ARITHMETIC: u64 = CF | PF | AF | ZF | SF | OF;

/// L'opération qui a posé les drapeaux, gardée **à la place** des drapeaux.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum FlagOp {
    /// Les six bits sont déjà connus : une écriture explicite, ou un `popfq`.
    Known,
    Add,
    /// `adc`, dont la retenue sortante dépend de la retenue entrante.
    AddCarry,
    Sub,
    /// `sbb`, même remarque.
    SubBorrow,
    /// `and`, `or`, `xor`, `test` : CF et OF sont mis à zéro par définition.
    Logic,
    /// `inc` : comme `add`, **sauf que CF est préservé**. C'est la seule
    /// raison pour laquelle `inc` n'est pas `add $1`.
    Inc,
    /// `dec` : comme `sub`, CF préservé.
    Dec,
}

/// Les drapeaux, gardés sous la forme la moins chère à produire.
#[derive(Clone, Copy, Debug)]
pub struct Flags {
    op: FlagOp,
    left: u64,
    right: u64,
    result: u64,
    width: Width,
    carry_in: u64,
    /// Les six bits arithmétiques quand `op` vaut `Known`, et la retenue
    /// préservée que `inc` et `dec` reliront.
    arithmetic: u64,
    /// Tout ce que l'arithmétique ne touche pas, gardé tel quel.
    other: u64,
}

impl Default for Flags {
    fn default() -> Self {
        Self {
            op: FlagOp::Known,
            left: 0,
            right: 0,
            result: 0,
            width: Width::Qword,
            carry_in: 0,
            arithmetic: 0,
            other: 0,
        }
    }
}

impl Flags {
    /// **RFLAGS, calculé maintenant parce qu'on le demande maintenant.**
    pub fn read(&self) -> u64 {
        let arithmetic = match self.op {
            FlagOp::Known => self.arithmetic & ARITHMETIC,
            _ => self.compute(),
        };
        arithmetic | self.other | ALWAYS_ONE
    }

    /// Poser les six bits en clair — après un `popfq`, ou une restauration.
    pub fn write(&mut self, value: u64) {
        self.op = FlagOp::Known;
        self.arithmetic = value & ARITHMETIC;
        self.other = value & !ARITHMETIC & !ALWAYS_ONE;
    }

    /// La retenue seule, dont `adc` et `sbb` ont besoin avant de calculer.
    pub fn carry(&self) -> u64 {
        u64::from(self.read() & CF != 0)
    }

    fn compute(&self) -> u64 {
        let mask = self.width.mask();
        let sign = self.width.sign();
        let result = self.result & mask;
        let left = self.left & mask;
        let right = self.right & mask;

        let mut flags = 0;
        if result == 0 {
            flags |= ZF;
        }
        if result & sign != 0 {
            flags |= SF;
        }
        // La parité ne regarde que l'octet de poids faible : c'est un legs du
        // 8080, et le vrai processeur le fait toujours.
        if (result as u8).count_ones() % 2 == 0 {
            flags |= PF;
        }
        // La demi-retenue sort de la même identité pour l'addition et la
        // soustraction, parce que a - b, c'est a + (-b).
        if (left ^ right ^ result) & 0x10 != 0 {
            flags |= AF;
        }

        match self.op {
            FlagOp::Known => unreachable!("Known ne passe pas par compute"),
            FlagOp::Logic => {}
            FlagOp::Add => {
                if result < left {
                    flags |= CF;
                }
                if (left ^ result) & (right ^ result) & sign != 0 {
                    flags |= OF;
                }
            }
            FlagOp::AddCarry => {
                // Avec une retenue entrante, l'égalité compte aussi : 0xff + 0
                // + 1 rend 0, et il y a bien eu retenue.
                if result < left || (self.carry_in == 1 && result == left) {
                    flags |= CF;
                }
                if (left ^ result) & (right ^ result) & sign != 0 {
                    flags |= OF;
                }
            }
            FlagOp::Sub => {
                if left < right {
                    flags |= CF;
                }
                if (left ^ right) & (left ^ result) & sign != 0 {
                    flags |= OF;
                }
            }
            FlagOp::SubBorrow => {
                if left < right || (self.carry_in == 1 && left == right) {
                    flags |= CF;
                }
                if (left ^ right) & (left ^ result) & sign != 0 {
                    flags |= OF;
                }
            }
            FlagOp::Inc => {
                flags |= self.arithmetic & CF;
                if (left ^ result) & (right ^ result) & sign != 0 {
                    flags |= OF;
                }
            }
            FlagOp::Dec => {
                flags |= self.arithmetic & CF;
                if (left ^ right) & (left ^ result) & sign != 0 {
                    flags |= OF;
                }
            }
        }
        flags
    }
}

/// Le processeur : seize registres, un pointeur d'instruction, les drapeaux.
///
/// Pas de mémoire dans cette tranche, et c'est délibéré : les 84 instructions
/// du groupe arithmétique que l'oracle matériel couvre travaillent toutes sur
/// des registres et des immédiats. Ajouter un modèle mémoire ici serait du
/// code qu'aucune mesure ne juge.
#[derive(Clone, Debug, Default)]
pub struct Cpu {
    pub regs: [u64; 16],
    pub rip: u64,
    pub flags: Flags,
}

/// Ce qu'un pas d'exécution a produit.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Step {
    /// L'instruction a été exécutée ; le pointeur avance de tant d'octets.
    Ran { length: usize },
    /// Le décodeur ne connaît pas ces octets. **Refuser plutôt que deviner** :
    /// un cœur qui invente une instruction corrompt l'invité en silence.
    Unknown,
}

/// L'opération, telle que le décodeur la rend.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Op {
    Add,
    Or,
    Adc,
    Sbb,
    And,
    Sub,
    Xor,
    Cmp,
    Test,
    Not,
    Neg,
    Inc,
    Dec,
}

/// Une instruction décodée, prête à rejouer sans relire d'octets.
///
/// C'est la moitié « cache de décodage » du sujet : décoder coûte 30 % du
/// temps du cœur Swift, mesuré, et ce temps-là ne se paie qu'une fois par
/// adresse quand on garde ceci.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Decoded {
    pub op: Op,
    pub width: Width,
    /// Le registre destination, ou la source unique pour `not`/`neg`.
    pub dst: u8,
    /// Le registre source, quand la source est un registre.
    pub src: u8,
    /// L'immédiat, déjà étendu en signe à la largeur de l'opération.
    pub imm: u64,
    /// La source est-elle l'immédiat plutôt que `src` ?
    pub immediate: bool,
    /// `cmp` et `test` posent les drapeaux sans écrire le résultat.
    pub discards: bool,
    /// Les octets consommés.
    pub length: usize,
    /// Un registre d'octet haut : `%ah`, `%ch`, `%dh`, `%bh`, qui n'existent
    /// que sans préfixe REX et qui désignent l'octet 8-15 du registre.
    pub dst_high: bool,
    pub src_high: bool,
}

impl Cpu {
    /// Lire un opérande de la largeur voulue.
    fn get(&self, reg: u8, width: Width, high: bool) -> u64 {
        let whole = self.regs[reg as usize];
        if high {
            return (whole >> 8) & 0xff;
        }
        whole & width.mask()
    }

    /// Écrire un opérande, avec la règle x86-64 que tout le monde oublie :
    /// **une écriture 32 bits efface les 32 bits de poids fort**, alors qu'une
    /// écriture 8 ou 16 bits préserve le reste du registre.
    fn set(&mut self, reg: u8, width: Width, high: bool, value: u64) {
        let slot = &mut self.regs[reg as usize];
        if high {
            *slot = (*slot & !0xff00) | ((value & 0xff) << 8);
            return;
        }
        match width {
            Width::Qword => *slot = value,
            Width::Dword => *slot = value & 0xffff_ffff,
            _ => {
                let mask = width.mask();
                *slot = (*slot & !mask) | (value & mask);
            }
        }
    }

    /// **Exécuter une instruction déjà décodée.** C'est ici que les drapeaux
    /// ne sont pas calculés : on garde l'opération et ses opérandes, rien de
    /// plus.
    pub fn execute(&mut self, instruction: &Decoded) {
        let width = instruction.width;
        let left = self.get(instruction.dst, width, instruction.dst_high);
        let right = if instruction.immediate {
            instruction.imm & width.mask()
        } else {
            self.get(instruction.src, width, instruction.src_high)
        };

        let (result, op) = match instruction.op {
            Op::Add => (left.wrapping_add(right), FlagOp::Add),
            Op::Sub | Op::Cmp => (left.wrapping_sub(right), FlagOp::Sub),
            Op::Adc => {
                let carry = self.flags.carry();
                (
                    left.wrapping_add(right).wrapping_add(carry),
                    FlagOp::AddCarry,
                )
            }
            Op::Sbb => {
                let carry = self.flags.carry();
                (
                    left.wrapping_sub(right).wrapping_sub(carry),
                    FlagOp::SubBorrow,
                )
            }
            Op::And | Op::Test => (left & right, FlagOp::Logic),
            Op::Or => (left | right, FlagOp::Logic),
            Op::Xor => (left ^ right, FlagOp::Logic),
            Op::Inc => (left.wrapping_add(1), FlagOp::Inc),
            Op::Dec => (left.wrapping_sub(1), FlagOp::Dec),
            // `neg` est `0 - src`, drapeaux compris : rien à traiter à part.
            Op::Neg => (0u64.wrapping_sub(left), FlagOp::Sub),
            // `not` est la seule du groupe qui ne touche à aucun drapeau.
            Op::Not => (!left, FlagOp::Known),
        };

        match instruction.op {
            Op::Not => {}
            Op::Inc | Op::Dec => {
                // La retenue préservée doit être lue **avant** d'écraser
                // l'état, sinon `inc` la perdrait.
                let carry = self.flags.read() & CF;
                self.flags = Flags {
                    op,
                    left,
                    right: 1,
                    result,
                    width,
                    carry_in: 0,
                    arithmetic: carry,
                    other: self.flags.other,
                };
            }
            Op::Neg => {
                self.flags = Flags {
                    op,
                    left: 0,
                    right: left,
                    result,
                    width,
                    carry_in: 0,
                    arithmetic: 0,
                    other: self.flags.other,
                };
            }
            _ => {
                let carry_in = match instruction.op {
                    Op::Adc | Op::Sbb => self.flags.carry(),
                    _ => 0,
                };
                self.flags = Flags {
                    op,
                    left,
                    right,
                    result,
                    width,
                    carry_in,
                    arithmetic: 0,
                    other: self.flags.other,
                };
            }
        }

        if !instruction.discards {
            self.set(instruction.dst, width, instruction.dst_high, result);
        }
    }
}

/// Les huit opérations que la grille 0x00–0x3F range dans cet ordre. Ce n'est
/// pas un choix, c'est l'encodage : l'opcode porte l'opération dans ses bits
/// 3 à 5, et le décodeur n'a donc qu'à indexer.
const GRID: [Op; 8] = [
    Op::Add,
    Op::Or,
    Op::Adc,
    Op::Sbb,
    Op::And,
    Op::Sub,
    Op::Xor,
    Op::Cmp,
];

/// L'état des préfixes lus avant l'opcode.
#[derive(Clone, Copy, Default)]
struct Prefixes {
    operand_size: bool,
    rex: Option<u8>,
}

impl Prefixes {
    fn width(self, byte_form: bool) -> Width {
        if byte_form {
            return Width::Byte;
        }
        if self.rex.is_some_and(|rex| rex & 0b1000 != 0) {
            return Width::Qword;
        }
        if self.operand_size {
            return Width::Word;
        }
        Width::Dword
    }

    /// Le bit R de REX, qui donne son quatrième bit au champ `reg`.
    fn reg_extension(self) -> u8 {
        self.rex.map_or(0, |rex| (rex & 0b0100) << 1)
    }

    /// Le bit B, qui fait la même chose pour `rm`.
    fn rm_extension(self) -> u8 {
        self.rex.map_or(0, |rex| (rex & 0b0001) << 3)
    }

    /// **`%ah` n'existe que sans REX.** Le moindre préfixe REX, même vide,
    /// transforme les numéros 4 à 7 en `%spl`, `%bpl`, `%sil`, `%dil`. C'est
    /// une des façons les plus discrètes de corrompre un invité.
    fn high_byte(self, number: u8, width: Width) -> bool {
        width == Width::Byte && self.rex.is_none() && (4..8).contains(&number)
    }

    fn normalise_high(self, number: u8, width: Width) -> u8 {
        if self.high_byte(number, width) {
            number - 4
        } else {
            number
        }
    }
}

/// **Décoder, sans exécuter.** Rendre `None` plutôt que deviner.
pub fn decode(bytes: &[u8]) -> Option<Decoded> {
    let mut at = 0usize;
    let mut prefixes = Prefixes::default();

    // Les préfixes, dans l'ordre où le processeur les accepte : 0x66 peut
    // précéder REX, jamais l'inverse — un REX suivi d'un autre préfixe ne
    // compte plus comme REX.
    while at < bytes.len() {
        match bytes[at] {
            0x66 => {
                prefixes.operand_size = true;
                prefixes.rex = None;
                at += 1;
            }
            rex @ 0x40..=0x4f => {
                prefixes.rex = Some(rex);
                at += 1;
                break;
            }
            _ => break,
        }
    }

    let opcode = *bytes.get(at)?;
    at += 1;

    // La grille arithmétique : huit opérations, six formes chacune.
    if opcode < 0x40 && (opcode & 0b111) < 6 {
        let op = GRID[(opcode >> 3) as usize];
        let form = opcode & 0b111;
        let byte_form = form == 0 || form == 2 || form == 4;
        let width = prefixes.width(byte_form);

        // Formes 4 et 5 : l'accumulateur et un immédiat.
        if form >= 4 {
            let imm = read_immediate(bytes, &mut at, width, false)?;
            return Some(Decoded {
                op,
                width,
                dst: 0,
                src: 0,
                imm,
                immediate: true,
                discards: op == Op::Cmp,
                length: at,
                dst_high: false,
                src_high: false,
            });
        }

        let (reg, rm) = read_modrm(bytes, &mut at, prefixes)?;
        let to_register = form == 2 || form == 3;
        let (dst, src) = if to_register { (reg, rm) } else { (rm, reg) };
        return Some(Decoded {
            op,
            width,
            dst: prefixes.normalise_high(dst, width),
            src: prefixes.normalise_high(src, width),
            imm: 0,
            immediate: false,
            discards: op == Op::Cmp,
            length: at,
            dst_high: prefixes.high_byte(dst, width),
            src_high: prefixes.high_byte(src, width),
        });
    }

    match opcode {
        // Groupe 1 : l'opération est dans le champ `reg` du ModRM.
        0x80 | 0x81 | 0x83 => {
            let width = prefixes.width(opcode == 0x80);
            let (reg, rm) = read_modrm(bytes, &mut at, prefixes)?;
            let op = GRID[(reg & 0b111) as usize];
            // 0x83 porte un immédiat d'un octet, étendu en signe.
            let imm = read_immediate(bytes, &mut at, width, opcode == 0x83)?;
            Some(Decoded {
                op,
                width,
                dst: prefixes.normalise_high(rm, width),
                src: 0,
                imm,
                immediate: true,
                discards: op == Op::Cmp,
                length: at,
                dst_high: prefixes.high_byte(rm, width),
                src_high: false,
            })
        }
        // `test` entre deux registres.
        0x84 | 0x85 => {
            let width = prefixes.width(opcode == 0x84);
            let (reg, rm) = read_modrm(bytes, &mut at, prefixes)?;
            Some(Decoded {
                op: Op::Test,
                width,
                dst: prefixes.normalise_high(rm, width),
                src: prefixes.normalise_high(reg, width),
                imm: 0,
                immediate: false,
                discards: true,
                length: at,
                dst_high: prefixes.high_byte(rm, width),
                src_high: prefixes.high_byte(reg, width),
            })
        }
        // `test` sur l'accumulateur.
        0xa8 | 0xa9 => {
            let width = prefixes.width(opcode == 0xa8);
            let imm = read_immediate(bytes, &mut at, width, false)?;
            Some(Decoded {
                op: Op::Test,
                width,
                dst: 0,
                src: 0,
                imm,
                immediate: true,
                discards: true,
                length: at,
                dst_high: false,
                src_high: false,
            })
        }
        // Groupe 3 : `test`, `not`, `neg` — et les multiplications et
        // divisions, que cette tranche ne prétend pas connaître.
        0xf6 | 0xf7 => {
            let width = prefixes.width(opcode == 0xf6);
            let (reg, rm) = read_modrm(bytes, &mut at, prefixes)?;
            let op = match reg & 0b111 {
                0 | 1 => Op::Test,
                2 => Op::Not,
                3 => Op::Neg,
                _ => return None,
            };
            let immediate = op == Op::Test;
            let imm = if immediate {
                read_immediate(bytes, &mut at, width, false)?
            } else {
                0
            };
            Some(Decoded {
                op,
                width,
                dst: prefixes.normalise_high(rm, width),
                src: 0,
                imm,
                immediate,
                discards: op == Op::Test,
                length: at,
                dst_high: prefixes.high_byte(rm, width),
                src_high: false,
            })
        }
        // Groupes 4 et 5 : `inc` et `dec`.
        0xfe | 0xff => {
            let width = prefixes.width(opcode == 0xfe);
            let (reg, rm) = read_modrm(bytes, &mut at, prefixes)?;
            let op = match reg & 0b111 {
                0 => Op::Inc,
                1 => Op::Dec,
                _ => return None,
            };
            Some(Decoded {
                op,
                width,
                dst: prefixes.normalise_high(rm, width),
                src: 0,
                imm: 0,
                immediate: false,
                discards: false,
                length: at,
                dst_high: prefixes.high_byte(rm, width),
                src_high: false,
            })
        }
        _ => None,
    }
}

/// Le ModRM, **mode registre seulement**. Une adresse mémoire est refusée
/// plutôt que mal calculée : cette tranche n'a pas de mémoire, et l'oracle
/// qui la juge n'en demande pas.
fn read_modrm(bytes: &[u8], at: &mut usize, prefixes: Prefixes) -> Option<(u8, u8)> {
    let modrm = *bytes.get(*at)?;
    *at += 1;
    if modrm >> 6 != 0b11 {
        return None;
    }
    let reg = ((modrm >> 3) & 0b111) | prefixes.reg_extension();
    let rm = (modrm & 0b111) | prefixes.rm_extension();
    Some((reg, rm))
}

/// L'immédiat, **étendu en signe** à la largeur de l'opération. Une extension
/// par zéro donnerait un résultat juste sur les petits nombres et faux sur les
/// négatifs, ce qu'aucun test rapide n'attrape.
fn read_immediate(bytes: &[u8], at: &mut usize, width: Width, byte_sized: bool) -> Option<u64> {
    let size = if byte_sized {
        1
    } else {
        match width {
            Width::Byte => 1,
            Width::Word => 2,
            // Un immédiat de 64 bits n'existe pas ici : la forme longue porte
            // quatre octets, étendus en signe.
            Width::Dword | Width::Qword => 4,
        }
    };
    let slice = bytes.get(*at..*at + size)?;
    *at += size;
    let raw = match size {
        1 => u64::from(slice[0]),
        2 => u64::from(u16::from_le_bytes([slice[0], slice[1]])),
        _ => u64::from(u32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]])),
    };
    let sign_bit = 1u64 << (size * 8 - 1);
    let extended = if raw & sign_bit != 0 {
        raw | !((sign_bit << 1).wrapping_sub(1))
    } else {
        raw
    };
    Some(extended & width.mask())
}

impl Cpu {
    /// **La même chose, mais en calculant les drapeaux tout de suite.**
    ///
    /// C'est le terme de comparaison, et il n'existe que pour ça : sans une
    /// version qui matérialise RFLAGS à chaque instruction, dire que la
    /// paresse rapporte quelque chose serait une croyance. Le reste du chemin
    /// est identique — même décodage, même arithmétique — pour que la seule
    /// différence mesurée soit le moment où les drapeaux sont calculés.
    pub fn execute_eagerly(&mut self, instruction: &Decoded) {
        self.execute(instruction);
        let now = self.flags.read();
        self.flags.write(now);
    }

    /// Décoder puis exécuter, en avançant le pointeur d'instruction.
    pub fn step(&mut self, bytes: &[u8]) -> Step {
        match decode(bytes) {
            Some(instruction) => {
                self.execute(&instruction);
                self.rip = self.rip.wrapping_add(instruction.length as u64);
                Step::Ran {
                    length: instruction.length,
                }
            }
            None => Step::Unknown,
        }
    }
}
