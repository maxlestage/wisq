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

    /// Le nombre de bits. L'énumération porte des octets ; la confusion entre
    /// les deux donne des décalages huit fois trop courts.
    pub const fn bits(self) -> u64 {
        self as u64 * 8
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
    pub memory: GuestMemory,
    /// **Un accès hors de la mémoire attachée.** Le cœur définitif aura la RAM
    /// entière et n'aura rien à refuser ; ici la mémoire est une fenêtre, et un
    /// accès qui en sort est une faute du harnais ou du corpus, pas de
    /// l'invité. L'instruction n'est alors **pas** exécutée — à moitié
    /// exécutée, elle rendrait un état que rien ne distingue d'un état juste —
    /// et ce témoin le dit.
    pub faulted: bool,
}

/// **La mémoire de l'invité, telle que cette tranche la connaît** : une fenêtre
/// contiguë, parce que c'est tout ce que le corpus matériel expose.
#[derive(Clone, Default, Debug)]
pub struct GuestMemory {
    pub base: u64,
    pub bytes: Vec<u8>,
}

impl GuestMemory {
    /// Le décalage d'un accès, ou rien s'il sort de la fenêtre — bord compris.
    /// Le calcul se fait en `u64` et vérifie la **fin** de l'accès, pas son
    /// début : une lecture de huit octets à un octet de la fin tient dans la
    /// fenêtre par son adresse et pas par sa taille.
    fn window(&self, address: u64, width: Width) -> Option<std::ops::Range<usize>> {
        let start = address.checked_sub(self.base)?;
        let size = width as u64;
        let end = start.checked_add(size)?;
        if end > self.bytes.len() as u64 {
            return None;
        }
        Some(start as usize..end as usize)
    }

    pub fn read(&self, address: u64, width: Width) -> Option<u64> {
        let window = self.window(address, width)?;
        let mut value = 0u64;
        // Petit-boutiste : l'octet de poids faible est à l'adresse la plus
        // basse. L'inverser rendrait des valeurs plausibles sur les motifs
        // symétriques et fausses partout ailleurs.
        for (rank, byte) in self.bytes[window].iter().enumerate() {
            value |= u64::from(*byte) << (rank * 8);
        }
        Some(value)
    }

    pub fn write(&mut self, address: u64, width: Width, value: u64) -> Option<()> {
        let window = self.window(address, width)?;
        for (rank, byte) in self.bytes[window].iter_mut().enumerate() {
            *byte = (value >> (rank * 8)) as u8;
        }
        Some(())
    }
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
    /// Décalage à gauche. `sal` est le même opcode : l'architecture ne les
    /// distingue pas, seul l'assembleur donne deux noms.
    Shl,
    /// Décalage à droite **logique** : des zéros entrent par le haut.
    Shr,
    /// Décalage à droite **arithmétique** : le bit de signe se recopie.
    Sar,
    /// Un transfert **sans extension de signe**. Couvre `mov` et `movzx` d'un
    /// seul bras, et ce n'est pas un raccourci : étendre par zéro une valeur
    /// déjà de la largeur de destination ne fait rien, donc `movl %ecx, %eax`
    /// et `movzbl %cl, %eax` sont la même opération à la largeur source près.
    Mov,
    /// Un transfert **avec extension de signe** : `movsx`, et `movsxd`.
    Movsx,
    /// Rotation à gauche. Rien ne sort : le bit du haut revient par le bas.
    Rol,
    /// Rotation à droite.
    Ror,
    /// **Calculer une adresse sans y toucher.** `lea` est la seule instruction
    /// qui porte un opérande mémoire et ne lit pas la mémoire : elle écrit
    /// l'adresse elle-même. C'est aussi la seule façon d'éprouver tout le
    /// calcul d'adresse — base, index, échelle, déplacement — contre le
    /// silicium sans avoir encore de mémoire à comparer.
    Lea,
    /// `setcc` : écrire **un octet**, zéro ou un, selon les drapeaux.
    Set(Condition),
    /// `cmovcc` : écrire la source, ou laisser la destination telle quelle.
    CondMove(Condition),
    /// `bt`, `bts`, `btr`, `btc` : lire un bit dans la retenue, et
    /// éventuellement le changer. Seule la retenue est définie.
    Bit(BitAction),
    /// `bsf` et `bsr` : trouver le premier bit à un, par le bas ou par le haut.
    BitScan {
        from_the_top: bool,
    },
    /// `popcnt` : compter les bits à un.
    Popcount,
    /// `bswap` : renverser l'ordre des octets.
    ByteSwap,
}

/// Ce qu'une instruction de bit fait au bit qu'elle vient de lire.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BitAction {
    /// `bt` : rien. Elle le lit et s'arrête.
    Test,
    Set,
    Reset,
    Complement,
}

/// **Une condition, telle que l'opcode la porte.**
///
/// C'est le quartet bas de l'opcode, et il n'est pas arbitraire : son bit de
/// poids faible dit « ou le contraire ». Les seize conditions sont donc huit
/// prédicats et leur négation, et c'est comme ça qu'on les traduit — une fois
/// chacun, plus un ou exclusif.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Condition(pub u8);

impl Condition {
    /// Le prédicat, hors négation : huit et pas seize.
    pub fn base(self) -> u8 {
        (self.0 >> 1) & 0b111
    }

    pub fn negated(self) -> bool {
        self.0 & 1 != 0
    }

    /// La condition tient-elle, pour cet état de RFLAGS ?
    pub fn holds(self, flags: u64) -> bool {
        let bit = |flag: u64| flags & flag != 0;
        let held = match self.base() {
            0 => bit(OF),
            1 => bit(CF),
            2 => bit(ZF),
            // « au-dessous ou égal » : la retenue **ou** le zéro.
            3 => bit(CF) || bit(ZF),
            4 => bit(SF),
            5 => bit(PF),
            // « plus petit », au sens signé : le signe et le débordement en
            // désaccord. Confondre avec le seul bit de signe donne un cœur qui
            // compare juste jusqu'au premier débordement.
            6 => bit(SF) != bit(OF),
            _ => bit(ZF) || (bit(SF) != bit(OF)),
        };
        held != self.negated()
    }
}

/// **Une adresse effective, telle que le ModRM et le SIB la décrivent.**
///
/// C'est la forme complète que x86-64 permet : une base, un index mis à
/// l'échelle, un déplacement, et le cas particulier du déplacement relatif au
/// pointeur d'instruction. Ni la base ni l'index ne sont optionnels par
/// confort — le codage les rend indépendamment absents, et confondre « base
/// zéro » avec « pas de base » désignerait le registre RAX à la place de rien.
///
/// Le mode **relatif à RIP** n'est pas ici : il est reconnu par le décodeur et
/// **refusé**. Aucun cas du corpus ne l'exerce, et un champ que rien ne peut
/// tenir finit par mentir.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Address {
    pub base: Option<u8>,
    pub index: Option<u8>,
    /// Un, deux, quatre ou huit. Jamais zéro : l'échelle du SIB est une
    /// puissance de deux, et l'absence d'index se dit par `index`.
    pub scale: u8,
    /// Le déplacement, **étendu en signe**. Il est négatif plus souvent qu'on
    /// ne croit : un cadre de pile est fait de `-8(%rbp)`.
    pub displacement: i64,
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
    /// **Le compte d'un décalage vient de `%cl`**, l'octet bas de `rcx`, et
    /// pas de la largeur de l'opération. Le confondre décalerait d'un nombre
    /// tiré des octets hauts de `rcx` — juste tant que `rcx` est petit, faux
    /// dès qu'il ne l'est plus.
    pub count_is_cl: bool,
    /// **La largeur de la source, quand elle diffère de la destination.**
    ///
    /// Une seule largeur suffit à tout le reste du jeu : `add %cl, %al` lit et
    /// écrit un octet. `movzbl %cl, %eax` lit un octet et en écrit quatre, et
    /// c'est toute la raison d'être de l'instruction. Confondre les deux
    /// rendrait `movzbq` identique à `movq` — juste tant que le registre
    /// source tient sur un octet, faux dès qu'il déborde.
    pub src_width: Width,
    /// L'adresse effective, quand l'opérande `rm` n'est pas un registre.
    pub memory: Option<Address>,
    /// De quel côté se trouve cet opérande mémoire. Le codage x86 met toujours
    /// l'accès du côté `rm`, et c'est le bit de direction de l'opcode qui dit
    /// si `rm` est la destination ou la source — la même adresse est lue puis
    /// réécrite dans un cas, seulement lue dans l'autre.
    ///
    /// Sans objet quand `memory` est absente, et pour `lea`, dont l'adresse
    /// **est** le résultat.
    pub memory_is_source: bool,
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

    /// **Un décalage, avec les quatre règles que l'architecture impose.**
    ///
    /// 1. Le compte est masqué : cinq bits, six en soixante-quatre. Une
    ///    machine qui décalerait de 32 un mot de 32 bits rendrait zéro ; le
    ///    vrai processeur rend l'opérande inchangé, parce que 32 & 31 vaut 0.
    /// 2. **Un compte nul ne touche à rien** — pas même un drapeau. C'est la
    ///    règle qu'on oublie, et elle se voit quand un `shr %cl` avec `cl` à
    ///    zéro efface une retenue que le code suivant attendait.
    /// 3. La retenue est le **dernier bit sorti**, pas un bit du résultat.
    /// 4. Le débordement n'est défini que pour un décalage de un ; ailleurs le
    ///    processeur y met ce qu'il veut, et le masque de l'oracle l'ignore.
    fn shift(&mut self, instruction: &Decoded, left: u64) {
        let width = instruction.width;
        let mask = width.mask();
        let bits = if width == Width::Qword {
            64
        } else {
            (width as u32) * 8
        };
        // Le compte vient de `%cl` ou d'un immédiat. Pas de masque à 0xff :
        // celui à 31 ou 63 juste en dessous le subsume.
        let raw = if instruction.count_is_cl {
            self.regs[1]
        } else {
            instruction.imm
        };
        let count = raw & if width == Width::Qword { 63 } else { 31 };
        let value = left & mask;
        if count == 0 {
            // **Aucun drapeau ne bouge — mais la destination est écrite.** Un
            // `shll %cl, %eax` avec `cl` à zéro laisse `eax` tel quel *et*
            // efface les trente-deux bits de poids fort, parce que c'est ce
            // que fait toute écriture 32 bits. Sortir sans écrire préserverait
            // une moitié haute que le processeur, lui, met à zéro.
            if !instruction.discards {
                self.faulted |= self.write_destination(instruction, value).is_none();
            }
            return;
        }

        let (result, carry, overflow) = match instruction.op {
            Op::Shl => {
                let result = (value << count.min(63)) & mask;
                // Le dernier bit sorti par le haut. Au-delà de la largeur il
                // n'y a plus rien à sortir, et l'architecture ne définit plus
                // la retenue.
                let carry = if count <= u64::from(bits) {
                    (value >> (u64::from(bits) - count)) & 1
                } else {
                    0
                };
                let sign = u64::from(result & width.sign() != 0);
                (result, carry, sign ^ carry)
            }
            Op::Shr => {
                let result = value >> count.min(63);
                let carry = if count <= u64::from(bits) {
                    (value >> (count - 1)) & 1
                } else {
                    0
                };
                // Pour un décalage de un, le débordement est le bit de signe
                // **d'origine** : c'est lui qui disparaît.
                (result, carry, u64::from(value & width.sign() != 0))
            }
            _ => {
                // Arithmétique : le signe se recopie, donc on étend d'abord à
                // soixante-quatre bits avant de décaler.
                let shift_up = 64 - bits;
                let extended = ((value << shift_up) as i64) >> shift_up;
                let result = ((extended >> count.min(63)) as u64) & mask;
                let carry = if count < u64::from(bits) {
                    (value >> (count - 1)) & 1
                } else {
                    u64::from(extended < 0)
                };
                (result, carry, 0)
            }
        };

        let mut flags = self.flags.read() & !(CF | PF | AF | ZF | SF | OF);
        if result & mask == 0 {
            flags |= ZF;
        }
        if result & width.sign() != 0 {
            flags |= SF;
        }
        if (result as u8).count_ones() % 2 == 0 {
            flags |= PF;
        }
        flags |= carry * CF;
        flags |= overflow * OF;
        // La demi-retenue est **indéfinie** après un décalage. On la laisse à
        // zéro et l'oracle ne la compare pas ; prétendre une valeur serait
        // inventer une règle que le processeur n'a pas.
        self.flags.write(flags);

        if !instruction.discards {
            self.faulted |= self.write_destination(instruction, result).is_none();
        }
    }

    /// **Exécuter une instruction déjà décodée.** C'est ici que les drapeaux
    /// ne sont pas calculés : on garde l'opération et ses opérandes, rien de
    /// plus.
    /// **Lire l'opérande de destination**, en mémoire ou en registre.
    ///
    /// C'est le `rm` du ModRM dans le cas mémoire, et le codage garantit qu'il
    /// n'y en a qu'un : jamais deux accès dans la même instruction.
    fn read_destination(&mut self, instruction: &Decoded) -> Option<u64> {
        match instruction.memory {
            Some(address) if !instruction.memory_is_source => {
                let at = self.effective_address(&address);
                self.memory.read(at, instruction.width)
            }
            _ => Some(self.get(instruction.dst, instruction.width, instruction.dst_high)),
        }
    }

    fn read_source(&mut self, instruction: &Decoded, width: Width) -> Option<u64> {
        match instruction.memory {
            Some(address) if instruction.memory_is_source => {
                let at = self.effective_address(&address);
                self.memory.read(at, width)
            }
            _ => Some(self.get(instruction.src, width, instruction.src_high)),
        }
    }

    /// Écrire le résultat là où l'opérande de destination se trouvait.
    fn write_destination(&mut self, instruction: &Decoded, value: u64) -> Option<()> {
        match instruction.memory {
            Some(address) if !instruction.memory_is_source => {
                let at = self.effective_address(&address);
                self.memory.write(at, instruction.width, value)
            }
            _ => {
                self.set(
                    instruction.dst,
                    instruction.width,
                    instruction.dst_high,
                    value,
                );
                Some(())
            }
        }
    }

    /// Base + index × échelle + déplacement, sur soixante-quatre bits qui
    /// bouclent. Le débordement n'est pas une erreur : c'est ainsi que se
    /// codent les index négatifs.
    fn effective_address(&self, address: &Address) -> u64 {
        let mut value = address.displacement as u64;
        if let Some(base) = address.base {
            value = value.wrapping_add(self.regs[base as usize]);
        }
        if let Some(index) = address.index {
            value = value
                .wrapping_add(self.regs[index as usize].wrapping_mul(u64::from(address.scale)));
        }
        value
    }

    /// **Une rotation, et les deux seuls drapeaux qu'elle touche.**
    ///
    /// 1. Le compte est masqué comme celui d'un décalage — cinq bits, six en
    ///    soixante-quatre — puis **ramené modulo la largeur** : tourner un
    ///    octet de neuf crans revient à le tourner d'un.
    /// 2. Un compte masqué nul ne touche à rien, drapeaux compris. Mais un
    ///    compte **non** nul dont le reste est nul touche quand même la
    ///    retenue : `rolb $8, %al` rend l'octet inchangé et pose CF sur son
    ///    bit bas. C'est pour ça que la retenue se lit sur le résultat et pas
    ///    sur un « dernier bit sorti » qui n'existe pas ici.
    /// 3. Seuls CF et OF bougent. PF, AF, ZF et SF sont préservés — une
    ///    rotation ne change aucun bit, seulement leur place.
    /// 4. Le débordement n'est défini que pour un cran.
    fn rotate(&mut self, instruction: &Decoded, left: u64) {
        let width = instruction.width;
        let mask = width.mask();
        let bits = width.bits();
        let raw = if instruction.count_is_cl {
            self.regs[1]
        } else {
            instruction.imm
        };
        let count = raw & if width == Width::Qword { 63 } else { 31 };
        let value = left & mask;
        if count == 0 {
            // Comme pour un décalage : aucun drapeau, mais la destination est
            // écrite, et une écriture 32 bits efface la moitié haute.
            if !instruction.discards {
                self.faulted |= self.write_destination(instruction, value).is_none();
            }
            return;
        }

        let turn = count % bits;
        let result = match (turn, instruction.op) {
            // Un tour complet : les bits sont revenus à leur place. Le
            // décalage complémentaire vaudrait `bits`, que Rust refuse.
            (0, _) => value,
            (_, Op::Rol) => ((value << turn) | (value >> (bits - turn))) & mask,
            _ => ((value >> turn) | (value << (bits - turn))) & mask,
        };

        let top = u64::from(result & width.sign() != 0);
        let (carry, overflow) = if instruction.op == Op::Rol {
            // À gauche, le bit sorti par le haut est rentré par le bas.
            let carry = result & 1;
            (carry, top ^ carry)
        } else {
            // À droite, il est rentré par le haut — et le débordement est le
            // désaccord des deux bits de tête du résultat.
            let second = (result >> (bits - 2)) & 1;
            (top, top ^ second)
        };

        let mut flags = self.flags.read() & !(CF | OF);
        flags |= carry * CF;
        flags |= overflow * OF;
        self.flags.write(flags);

        if !instruction.discards {
            self.faulted |= self.write_destination(instruction, result).is_none();
        }
    }

    /// **Un bit, lu dans la retenue et parfois changé.**
    ///
    /// Le numéro est réduit modulo la largeur — et c'est vrai **parce que
    /// l'opérande est un registre**. En mémoire ce serait faux : le numéro y
    /// est signé et désigne un bit qui peut être très loin. Le décodeur refuse
    /// cette forme-là plutôt que de la traiter comme celle-ci.
    ///
    /// Seule la retenue est définie ; les cinq autres drapeaux ne sont pas
    /// touchés, ce que le masque du corpus ne compare pas mais qui est ce que
    /// fait le processeur.
    fn bit(&mut self, instruction: &Decoded, action: BitAction) {
        let width = instruction.width;
        let bits = width.bits();
        let number = if instruction.immediate {
            instruction.imm
        } else {
            self.regs[instruction.src as usize]
        } % bits;
        let value = self.get(instruction.dst, width, false);
        let carry = (value >> number) & 1;

        let mut flags = self.flags.read() & !CF;
        flags |= carry * CF;
        self.flags.write(flags);

        if action == BitAction::Test {
            return;
        }
        let mask = 1u64 << number;
        let changed = match action {
            BitAction::Set => value | mask,
            BitAction::Reset => value & !mask,
            _ => value ^ mask,
        };
        self.set(instruction.dst, width, false, changed);
    }

    /// **Chercher le premier bit à un, par le bas ou par le haut.**
    ///
    /// Quand la source est nulle, le manuel déclare la destination
    /// **indéfinie**. Les deux fondeurs la laissent inchangée, et c'est ce que
    /// le corpus a relevé sur la machine qui l'a produit — ce test ne peut
    /// donc pas prouver plus que « comme cette machine-là ».
    fn scan(&mut self, instruction: &Decoded, from_the_top: bool) {
        let width = instruction.width;
        let Some(source) = self.read_source(instruction, width) else {
            self.faulted = true;
            return;
        };
        let source = source & width.mask();

        let without_zero = self.flags.read() & !ZF;
        if source == 0 {
            // La destination ne bouge pas : le manuel la dit indéfinie, les
            // deux fondeurs la laissent telle quelle.
            self.flags.write(without_zero | ZF);
            return;
        }
        self.flags.write(without_zero);
        let index = if from_the_top {
            63 - u64::from(source.leading_zeros())
        } else {
            u64::from(source.trailing_zeros())
        };
        self.faulted |= self.write_destination(instruction, index).is_none();
    }

    /// **Un transfert, avec ou sans extension de signe.**
    ///
    /// Ce qui distingue cette famille du reste : elle a deux largeurs. La
    /// source est lue à `src_width`, la destination écrite à `width`, et
    /// c'est l'écart entre les deux qui fait tout le travail de `movzx` et
    /// `movsx`. La règle d'écriture ne change pas — une destination de 32 bits
    /// efface toujours la moitié haute du registre.
    fn transfer(&mut self, instruction: &Decoded) {
        // La source se lit à **sa** largeur, qui n'est pas celle de l'écriture,
        // et l'accès mémoire éventuel doit donc porter la même.
        let Some(source) = self.read_source(instruction, instruction.src_width) else {
            self.faulted = true;
            return;
        };
        let value = match instruction.op {
            Op::Movsx => sign_extend(source, instruction.src_width),
            // `mov` et `movzx` : la valeur est déjà masquée par la lecture, et
            // les bits hauts de la destination valent zéro.
            _ => source,
        };
        self.faulted |= self.write_destination(instruction, value).is_none();
    }

    pub fn execute(&mut self, instruction: &Decoded) {
        let width = instruction.width;

        // **`lea` calcule et n'accède à rien**, et elle sort donc avant même la
        // lecture des opérandes : elle porte une adresse mémoire que personne
        // ne doit déréférencer. La lire comme un opérande la faisait échouer
        // sur toute adresse hors de la fenêtre — c'est-à-dire sur toutes.
        if instruction.op == Op::Lea {
            if let Some(address) = instruction.memory {
                let value = self.effective_address(&address);
                self.set(instruction.dst, width, false, value);
            }
            return;
        }

        // **`setcc` et `cmovcc` lisent les drapeaux et n'en écrivent aucun.**
        // Ils sortent avant la machinerie à deux opérandes, qui en pose à
        // chaque passage.
        if let Op::Set(condition) = instruction.op {
            let value = u64::from(condition.holds(self.flags.read()));
            self.faulted |= self.write_destination(instruction, value).is_none();
            return;
        }
        if let Op::CondMove(condition) = instruction.op {
            let (Some(source), Some(current)) = (
                self.read_source(instruction, width),
                self.read_destination(instruction),
            ) else {
                self.faulted = true;
                return;
            };
            let value = if condition.holds(self.flags.read()) {
                source
            } else {
                current
            };
            self.faulted |= self.write_destination(instruction, value).is_none();
            return;
        }

        // **Les bits, le balayage, le compte, et le renversement.** Chacun a
        // ses propres drapeaux — de la seule retenue à aucun — et aucun ne
        // rentre dans la machinerie à deux opérandes.
        if let Op::Bit(action) = instruction.op {
            self.bit(instruction, action);
            return;
        }
        if let Op::BitScan { from_the_top } = instruction.op {
            self.scan(instruction, from_the_top);
            return;
        }
        if instruction.op == Op::Popcount {
            let Some(source) = self.read_source(instruction, width) else {
                self.faulted = true;
                return;
            };
            let count = u64::from((source & width.mask()).count_ones());
            // **Tous les drapeaux sont définis, et cinq valent zéro.**
            //
            // Le manuel énonce le zéro sur la **source**. Le lire sur le
            // résultat donnerait exactement le même bit — le compte est nul si
            // et seulement si la source l'est — et un sabotage l'a confirmé en
            // ne faisant tomber aucun cas. On garde la formulation du manuel
            // parce que c'est elle qui est vraie par définition ; l'autre ne
            // l'est que par coïncidence arithmétique.
            let mut flags = self.flags.read() & !(CF | PF | AF | ZF | SF | OF);
            if source & width.mask() == 0 {
                flags |= ZF;
            }
            self.flags.write(flags);
            self.faulted |= self.write_destination(instruction, count).is_none();
            return;
        }
        if instruction.op == Op::ByteSwap {
            let value = self.get(instruction.dst, width, false);
            let swapped = value.swap_bytes() >> (64 - width.bits());
            self.set(instruction.dst, width, false, swapped);
            return;
        }

        // **Lire les deux opérandes avant de rien changer.** Un accès qui
        // échoue doit laisser la machine intacte : une instruction à moitié
        // exécutée rend un état que rien ne distingue d'un état juste.
        let (Some(left), Some(right)) = (
            self.read_destination(instruction),
            if instruction.immediate {
                Some(instruction.imm & width.mask())
            } else {
                self.read_source(instruction, width)
            },
        ) else {
            self.faulted = true;
            return;
        };

        // **Les décalages ne rentrent pas dans le moule.** Leur retenue vient
        // du dernier bit sorti, leur débordement n'est défini que pour un
        // décalage de un, et un compte nul ne touche à **rien** — ni au
        // résultat, ni à un seul drapeau. Les faire passer par la machinerie
        // des opérations à deux opérandes donnerait quatre règles fausses.
        if matches!(instruction.op, Op::Shl | Op::Shr | Op::Sar) {
            self.shift(instruction, left);
            return;
        }

        // **Un transfert ne touche à aucun drapeau**, et il lit sa source à
        // une largeur qui n'est pas forcément celle de l'écriture. Les deux
        // raisons suffisent à le sortir du moule : la machinerie ci-dessous
        // pose des drapeaux à chaque passage, et lit ses deux opérandes à la
        // largeur de l'instruction.
        if matches!(instruction.op, Op::Mov | Op::Movsx) {
            self.transfer(instruction);
            return;
        }

        // **Une rotation ne perd rien et ne pose que deux drapeaux.** Le
        // résultat a exactement les mêmes bits que l'opérande, dans un autre
        // ordre : le zéro, le signe et la parité de l'un ne disent rien de
        // l'autre, et l'architecture les déclare donc **non affectés**. Les
        // recalculer les écraserait avec des valeurs plausibles et fausses.
        if matches!(instruction.op, Op::Rol | Op::Ror) {
            self.rotate(instruction, left);
            return;
        }

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
            // Traités plus haut : leur retenue et leur débordement ne suivent
            // aucune des règles de ce tableau.
            Op::Shl | Op::Shr | Op::Sar => unreachable!("les décalages sortent avant"),
            Op::Mov | Op::Movsx => unreachable!("les transferts sortent avant"),
            Op::Rol | Op::Ror => unreachable!("les rotations sortent avant"),
            Op::Lea => unreachable!("lea sort avant"),
            Op::Set(_) | Op::CondMove(_) => unreachable!("les conditions sortent avant"),
            Op::Bit(_) | Op::BitScan { .. } | Op::Popcount | Op::ByteSwap => {
                unreachable!("les bits sortent avant")
            }
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
            self.faulted |= self.write_destination(instruction, result).is_none();
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
    repeat: bool,
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

    /// Le bit X, qui donne son quatrième bit à l'index du SIB. Il n'a pas
    /// d'autre usage, et c'est lui qui fait la différence entre « pas d'index »
    /// et « index R12 ».
    fn index_extension(self) -> u8 {
        self.rex.map_or(0, |rex| (rex & 0b0010) << 2)
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
            // 0xF3 est le préfixe de répétition, mais il sert aussi à
            // distinguer des opcodes entiers : `popcnt` est `bsf` avec 0xF3
            // devant. Le confondre avec `bsf` rendrait un nombre plausible et
            // faux — le premier bit à un au lieu de leur compte.
            0xf3 => {
                prefixes.repeat = true;
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

    // **La deuxième page.** 0x0F n'est pas une instruction, c'est une bascule :
    // l'octet suivant recommence une grille entière. La confondre avec un
    // opcode ferait décoder l'octet d'après comme un ModRM, et le décodeur
    // rendrait une instruction plausible et fausse.
    if opcode == 0x0f {
        let second = *bytes.get(at)?;
        at += 1;
        return match second {
            // **Les bits.** Le numéro vient d'un registre (`reg`) ou d'un
            // immédiat, et l'opérande est le `rm`. Quand cet opérande est en
            // **mémoire**, la règle change du tout au tout : le numéro n'est
            // plus réduit modulo la largeur, il est signé, et le processeur va
            // chercher le mot qui contient ce bit-là, aussi loin soit-il. Ce
            // n'est pas une variante, c'est une autre instruction — refusée
            // ici plutôt que traduite comme sa jumelle à registre.
            0xa3 | 0xab | 0xb3 | 0xbb => {
                let action = match second {
                    0xa3 => BitAction::Test,
                    0xab => BitAction::Set,
                    0xb3 => BitAction::Reset,
                    _ => BitAction::Complement,
                };
                let width = prefixes.width(false);
                let field = read_modrm(bytes, &mut at, prefixes)?;
                if field.memory.is_some() {
                    return None;
                }
                Some(Decoded {
                    op: Op::Bit(action),
                    width,
                    dst: field.register,
                    src: field.reg,
                    imm: 0,
                    immediate: false,
                    discards: action == BitAction::Test,
                    length: at,
                    dst_high: false,
                    src_high: false,
                    count_is_cl: false,
                    src_width: width,
                    memory: None,
                    memory_is_source: false,
                })
            }
            // Le même groupe, numéro en immédiat. Le champ `reg` porte alors
            // l'opération, pas un registre.
            0xba => {
                let width = prefixes.width(false);
                let field = read_modrm(bytes, &mut at, prefixes)?;
                if field.memory.is_some() {
                    return None;
                }
                let action = match field.reg & 0b111 {
                    4 => BitAction::Test,
                    5 => BitAction::Set,
                    6 => BitAction::Reset,
                    7 => BitAction::Complement,
                    _ => return None,
                };
                let number = *bytes.get(at)?;
                at += 1;
                Some(Decoded {
                    op: Op::Bit(action),
                    width,
                    dst: field.register,
                    src: 0,
                    // **Un numéro de bit s'étend par zéro**, comme un compte de
                    // décalage : il n'est jamais négatif.
                    imm: u64::from(number),
                    immediate: true,
                    discards: action == BitAction::Test,
                    length: at,
                    dst_high: false,
                    src_high: false,
                    count_is_cl: false,
                    src_width: width,
                    memory: None,
                    memory_is_source: false,
                })
            }
            // `bsf`, `bsr`, et `popcnt` qui partage l'un de leurs opcodes.
            0xbc | 0xbd | 0xb8 => {
                if second == 0xb8 && !prefixes.repeat {
                    // Sans 0xF3, 0x0F 0xB8 n'est pas `popcnt` : c'est un opcode
                    // que cette tranche ne connaît pas.
                    return None;
                }
                let width = prefixes.width(false);
                let field = read_modrm(bytes, &mut at, prefixes)?;
                Some(Decoded {
                    op: match second {
                        0xb8 => Op::Popcount,
                        0xbc => Op::BitScan {
                            from_the_top: false,
                        },
                        _ => Op::BitScan { from_the_top: true },
                    },
                    width,
                    dst: field.reg,
                    src: field.register,
                    imm: 0,
                    immediate: false,
                    discards: false,
                    length: at,
                    dst_high: false,
                    src_high: false,
                    count_is_cl: false,
                    src_width: width,
                    memory: field.memory,
                    memory_is_source: true,
                })
            }
            // `bswap` : le registre est dans les trois bits bas de l'opcode.
            0xc8..=0xcf => {
                let width = prefixes.width(false);
                Some(Decoded {
                    op: Op::ByteSwap,
                    width,
                    dst: (second & 0b111) | prefixes.rm_extension(),
                    src: 0,
                    imm: 0,
                    immediate: false,
                    discards: false,
                    length: at,
                    dst_high: false,
                    src_high: false,
                    count_is_cl: false,
                    src_width: width,
                    memory: None,
                    memory_is_source: false,
                })
            }
            // `cmovcc` : la source est lue, la destination écrite seulement si
            // la condition tient. Sans elle, la destination garde sa valeur —
            // mais elle est quand même **écrite**, donc la règle de largeur
            // s'applique et une destination de 32 bits efface sa moitié haute.
            0x40..=0x4f => {
                let width = prefixes.width(false);
                let field = read_modrm(bytes, &mut at, prefixes)?;
                Some(Decoded {
                    op: Op::CondMove(Condition(second & 0x0f)),
                    width,
                    dst: field.reg,
                    src: field.register,
                    imm: 0,
                    immediate: false,
                    discards: false,
                    length: at,
                    dst_high: false,
                    src_high: false,
                    count_is_cl: false,
                    src_width: width,
                    memory: field.memory,
                    memory_is_source: true,
                })
            }
            // `setcc` : **un octet**, quelle que soit la largeur des préfixes.
            // Un REX.W ne l'élargit pas ; il ne fait que changer le sens des
            // numéros de registre 4 à 7.
            0x90..=0x9f => {
                let field = read_modrm(bytes, &mut at, prefixes)?;
                let rm = field.register;
                Some(Decoded {
                    op: Op::Set(Condition(second & 0x0f)),
                    width: Width::Byte,
                    dst: prefixes.normalise_high(rm, Width::Byte),
                    src: 0,
                    imm: 0,
                    immediate: false,
                    discards: false,
                    length: at,
                    dst_high: field.memory.is_none() && prefixes.high_byte(rm, Width::Byte),
                    src_high: false,
                    count_is_cl: false,
                    src_width: Width::Byte,
                    memory: field.memory,
                    memory_is_source: false,
                })
            }
            // `movzx` et `movsx` : la source est un octet (B6/BE) ou un mot
            // (B7/BF), la destination a la largeur que les préfixes donnent.
            0xb6 | 0xb7 | 0xbe | 0xbf => {
                let src_width = if second & 1 == 0 {
                    Width::Byte
                } else {
                    Width::Word
                };
                let width = prefixes.width(false);
                let field = read_modrm(bytes, &mut at, prefixes)?;
                let (reg, rm) = (field.reg, field.register);
                Some(Decoded {
                    op: if second < 0xbe { Op::Mov } else { Op::Movsx },
                    width,
                    // La destination est le champ `reg`, la source le `rm` :
                    // l'inverse de la grille arithmétique en forme 0.
                    dst: reg,
                    src: prefixes.normalise_high(rm, src_width),
                    imm: 0,
                    immediate: false,
                    discards: false,
                    length: at,
                    // La destination fait au moins deux octets : elle ne peut
                    // pas être un registre d'octet haut.
                    dst_high: false,
                    // **Le registre haut se juge à la largeur de la source**,
                    // pas à celle de l'instruction. `movzbl %ah, %eax` est une
                    // opération de 32 bits dont la source est `%ah`.
                    src_high: field.memory.is_none() && prefixes.high_byte(rm, src_width),
                    count_is_cl: false,
                    src_width,
                    memory: field.memory,
                    memory_is_source: true,
                })
            }
            _ => None,
        };
    }

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
                count_is_cl: false,
                src_width: width,
                memory: None,
                memory_is_source: false,
            });
        }

        let field = read_modrm(bytes, &mut at, prefixes)?;
        let (reg, rm) = (field.reg, field.register);
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
            // Un opérande en mémoire n'est jamais un registre d'octet haut :
            // le codage `rm` sert alors à l'adresse, pas à un numéro.
            dst_high: (field.memory.is_none() || to_register) && prefixes.high_byte(dst, width),
            src_high: (field.memory.is_none() || !to_register) && prefixes.high_byte(src, width),
            count_is_cl: false,
            src_width: width,
            memory: field.memory,
            memory_is_source: to_register,
        });
    }

    match opcode {
        // `mov` d'un registre vers un autre. Seule la forme « registre vers
        // r/m » est ici : la forme inverse (0x8A/0x8B) lit une source `rm` qui,
        // en mode registre, donne exactement les mêmes couples — l'oracle ne la
        // relève pas, et l'ajouter sans cas pour la juger serait du code que
        // rien ne tient.
        0x88..=0x8b => {
            let width = prefixes.width(opcode & 1 == 0);
            // Le bit 1 de l'opcode est le bit de direction : à zéro, `reg` va
            // vers `rm` ; à un, l'inverse. C'est lui, et rien d'autre, qui dit
            // de quel côté se trouve l'accès mémoire.
            let to_register = opcode & 0b10 != 0;
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let (reg, rm) = (field.reg, field.register);
            let (dst, src) = if to_register { (reg, rm) } else { (rm, reg) };
            Some(Decoded {
                op: Op::Mov,
                width,
                dst: prefixes.normalise_high(dst, width),
                src: prefixes.normalise_high(src, width),
                imm: 0,
                immediate: false,
                discards: false,
                length: at,
                dst_high: (field.memory.is_none() || to_register) && prefixes.high_byte(dst, width),
                src_high: (field.memory.is_none() || !to_register)
                    && prefixes.high_byte(src, width),
                count_is_cl: false,
                src_width: width,
                memory: field.memory,
                memory_is_source: to_register,
            })
        }
        // `lea` : le seul opérande mémoire de cette tranche, et le seul qui ne
        // lise rien. Le mode registre est **invalide** pour cette instruction —
        // il n'y a pas d'adresse d'un registre — et l'assembleur ne le produit
        // pas ; le décodeur le refuse plutôt que d'inventer.
        0x8d => {
            let width = prefixes.width(false);
            let modrm = *bytes.get(at)?;
            at += 1;
            if modrm >> 6 == 0b11 {
                return None;
            }
            let reg = ((modrm >> 3) & 0b111) | prefixes.reg_extension();
            let memory = read_address(bytes, &mut at, prefixes, modrm)?;
            Some(Decoded {
                op: Op::Lea,
                width,
                dst: reg,
                src: 0,
                imm: 0,
                immediate: false,
                discards: false,
                length: at,
                dst_high: false,
                src_high: false,
                count_is_cl: false,
                src_width: width,
                memory: Some(memory),
                memory_is_source: false,
            })
        }
        // `movsxd` : quatre octets lus, étendus en signe vers la destination.
        // Sans REX.W la destination fait aussi 32 bits et l'instruction ne
        // fait plus rien d'observable ; c'est quand même le même chemin.
        0x63 => {
            let width = prefixes.width(false);
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let (reg, rm) = (field.reg, field.register);
            Some(Decoded {
                op: Op::Movsx,
                width,
                dst: reg,
                src: rm,
                imm: 0,
                immediate: false,
                discards: false,
                length: at,
                dst_high: false,
                src_high: false,
                count_is_cl: false,
                src_width: Width::Dword,
                memory: field.memory,
                memory_is_source: true,
            })
        }
        // Groupe 1 : l'opération est dans le champ `reg` du ModRM.
        0x80 | 0x81 | 0x83 => {
            let width = prefixes.width(opcode == 0x80);
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let (reg, rm) = (field.reg, field.register);
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
                dst_high: field.memory.is_none() && prefixes.high_byte(rm, width),
                src_high: false,
                count_is_cl: false,
                src_width: width,
                memory: field.memory,
                memory_is_source: false,
            })
        }
        // `test` entre deux registres.
        0x84 | 0x85 => {
            let width = prefixes.width(opcode == 0x84);
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let (reg, rm) = (field.reg, field.register);
            Some(Decoded {
                op: Op::Test,
                width,
                dst: prefixes.normalise_high(rm, width),
                src: prefixes.normalise_high(reg, width),
                imm: 0,
                immediate: false,
                discards: true,
                length: at,
                dst_high: field.memory.is_none() && prefixes.high_byte(rm, width),
                src_high: prefixes.high_byte(reg, width),
                count_is_cl: false,
                src_width: width,
                memory: field.memory,
                memory_is_source: false,
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
                count_is_cl: false,
                src_width: width,
                memory: None,
                memory_is_source: false,
            })
        }
        // Groupe 3 : `test`, `not`, `neg` — et les multiplications et
        // divisions, que cette tranche ne prétend pas connaître.
        0xf6 | 0xf7 => {
            let width = prefixes.width(opcode == 0xf6);
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let (reg, rm) = (field.reg, field.register);
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
                dst_high: field.memory.is_none() && prefixes.high_byte(rm, width),
                src_high: false,
                count_is_cl: false,
                src_width: width,
                memory: field.memory,
                memory_is_source: false,
            })
        }
        // **Groupe 2 : les décalages.** Trois sources pour le compte, et c'est
        // la seule famille où le compte n'est pas un opérande comme un autre :
        // 0xC0/0xC1 le portent en immédiat, 0xD0/0xD1 valent toujours un, et
        // 0xD2/0xD3 le lisent dans `%cl` — l'octet **bas** de `rcx`, pas un
        // opérande de la largeur de l'opération.
        0xc0 | 0xc1 | 0xd0 | 0xd1 | 0xd2 | 0xd3 => {
            let byte_form = opcode & 1 == 0;
            let width = prefixes.width(byte_form);
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let (reg, rm) = (field.reg, field.register);
            let op = match reg & 0b111 {
                // 4 et 6 sont le même décalage à gauche : l'architecture ne
                // distingue pas `shl` de `sal`.
                4 | 6 => Op::Shl,
                5 => Op::Shr,
                7 => Op::Sar,
                0 => Op::Rol,
                1 => Op::Ror,
                // `rcl` et `rcr` tournent **à travers** la retenue : leur
                // rotation porte sur la largeur **plus un bit**, soixante-cinq
                // pour un quadruple mot, ce qui ne tient pas dans un registre
                // de la machine hôte. C'est une tranche à part, pas une
                // variante — les traduire comme une rotation simple serait
                // faux en silence.
                _ => return None,
            };
            let (imm, immediate, count_is_cl) = match opcode {
                0xc0 | 0xc1 => {
                    // **Un compte s'étend par zéro**, pas par signe : c'est un
                    // nombre de bits, jamais négatif. Passer par le lecteur
                    // d'immédiats signés donnerait 0xFF pour un décalage de
                    // 255, masqué ensuite en 31 — juste par accident.
                    let byte = *bytes.get(at)?;
                    at += 1;
                    (u64::from(byte), true, false)
                }
                0xd0 | 0xd1 => (1, true, false),
                _ => (0, false, true),
            };
            Some(Decoded {
                op,
                width,
                dst: prefixes.normalise_high(rm, width),
                src: 1, // `%cl` vit dans `rcx`
                imm,
                immediate,
                discards: false,
                length: at,
                dst_high: field.memory.is_none() && prefixes.high_byte(rm, width),
                src_high: false,
                count_is_cl,
                src_width: width,
                memory: field.memory,
                memory_is_source: false,
            })
        }
        // Groupes 4 et 5 : `inc` et `dec`.
        0xfe | 0xff => {
            let width = prefixes.width(opcode == 0xfe);
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let (reg, rm) = (field.reg, field.register);
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
                dst_high: field.memory.is_none() && prefixes.high_byte(rm, width),
                src_high: false,
                count_is_cl: false,
                src_width: width,
                memory: field.memory,
                memory_is_source: false,
            })
        }
        _ => None,
    }
}

/// Étendre en signe une valeur déjà masquée à sa largeur.
///
/// La valeur arrive **propre** : `get` l'a masquée. Il ne reste donc qu'à
/// recopier le bit de signe vers le haut, et pour une source de 64 bits il n'y
/// a rien à recopier — le masque complémentaire est nul.
fn sign_extend(value: u64, width: Width) -> u64 {
    let sign = width.sign();
    if value & sign == 0 {
        return value;
    }
    value | !width.mask()
}

/// **L'adresse effective d'un ModRM qui n'est pas en mode registre.**
///
/// Trois pièges y sont codés, et chacun se traduit par une adresse plausible
/// quand on l'oublie :
///
/// 1. `rm == 100` n'est pas le registre RSP : c'est l'annonce d'un octet SIB.
/// 2. Dans ce SIB, `index == 100` **sans REX.X** veut dire « pas d'index ».
///    Avec REX.X il désigne R12, qui est un index parfaitement valable — le
///    même champ dit deux choses selon un bit qui est ailleurs.
/// 3. `mod == 00` avec `base == 101` ne veut pas dire « base RBP » mais
///    « pas de base, un déplacement de quatre octets suit ».
fn read_address(bytes: &[u8], at: &mut usize, prefixes: Prefixes, modrm: u8) -> Option<Address> {
    let mode = modrm >> 6;
    let rm = modrm & 0b111;

    let mut address = Address {
        scale: 1,
        ..Address::default()
    };

    if rm == 0b100 {
        let sib = *bytes.get(*at)?;
        *at += 1;
        let index = ((sib >> 3) & 0b111) | prefixes.index_extension();
        // Le quatre nu, et lui seul, dit « aucun index ».
        if index != 0b100 {
            address.index = Some(index);
            address.scale = 1 << (sib >> 6);
        }
        let base = sib & 0b111;
        if mode == 0 && base == 0b101 {
            address.displacement = i64::from(read_i32(bytes, at)?);
        } else {
            address.base = Some(base | prefixes.rm_extension());
        }
    } else if mode == 0 && rm == 0b101 {
        // Relatif à RIP. Reconnu pour être refusé : le décodeur ne sait pas
        // encore où l'instruction se trouve, et rendre une base RBP à la place
        // donnerait une adresse absolue minuscule au lieu d'une erreur.
        return None;
    } else {
        address.base = Some(rm | prefixes.rm_extension());
    }

    match mode {
        1 => address.displacement = i64::from(*bytes.get(*at)? as i8),
        2 => address.displacement = i64::from(read_i32(bytes, at)?),
        _ => {}
    }
    if mode == 1 {
        *at += 1;
    }
    Some(address)
}

/// Quatre octets, en petit-boutiste, **signés**.
fn read_i32(bytes: &[u8], at: &mut usize) -> Option<i32> {
    let slice = bytes.get(*at..*at + 4)?;
    *at += 4;
    Some(i32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]]))
}

/// Ce qu'un octet ModRM désigne : un champ `reg`, et un `rm` qui est soit un
/// registre, soit une adresse.
struct ModRm {
    reg: u8,
    /// Le registre `rm`. Sans objet quand `memory` est présente.
    register: u8,
    memory: Option<Address>,
}

/// Le ModRM, registre **ou** mémoire.
///
/// Il a longtemps refusé tout ce qui n'était pas le mode registre, et le corpus
/// ne le lui reprochait pas : aucune instruction isolée n'y portait d'accès
/// mémoire. Les quinze programmes en portent, mais ils demandent aussi des
/// sauts — leur refus avait donc une autre cause, qui couvrait celle-ci.
fn read_modrm(bytes: &[u8], at: &mut usize, prefixes: Prefixes) -> Option<ModRm> {
    let modrm = *bytes.get(*at)?;
    *at += 1;
    let reg = ((modrm >> 3) & 0b111) | prefixes.reg_extension();
    if modrm >> 6 == 0b11 {
        return Some(ModRm {
            reg,
            register: (modrm & 0b111) | prefixes.rm_extension(),
            memory: None,
        });
    }
    Some(ModRm {
        reg,
        register: 0,
        memory: Some(read_address(bytes, at, prefixes, modrm)?),
    })
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

#[cfg(test)]
mod tests {
    use super::*;

    /// **Ce que le corpus matériel ne peut pas juger, et pourquoi.**
    ///
    /// Le mode « relatif au pointeur d'instruction » est reconnu par le
    /// décodeur puis refusé, faute de savoir où l'instruction se trouve. Aucun
    /// cas de `x86-oracle.tsv` ne l'exerce seul, et un sabotage l'a montré :
    /// accepter ce codage comme une base RBP ne faisait tomber aucun cas.
    ///
    /// Ce test n'est donc pas du silicium — c'est une lecture du codage, et il
    /// vaut ce que vaut cette lecture. Il tient une chose et une seule : que le
    /// refus soit un refus, et pas une adresse plausible calculée depuis le
    /// mauvais registre. Le jour où les sauts arriveront, RIP sera connu et ce
    /// test devra changer de sens.
    #[test]
    fn a_displacement_relative_to_the_instruction_pointer_is_refused() {
        // 48 8d 05 <disp32> — `leaq disp(%rip), %rax`. Le champ `rm` vaut 101
        // avec un `mod` nul : le même codage qui, ailleurs, désigne RBP.
        assert_eq!(decode(&[0x48, 0x8d, 0x05, 0x10, 0x00, 0x00, 0x00]), None);
        // Et la preuve que c'est bien le `mod` qui décide : avec un
        // déplacement d'un octet, 101 redevient RBP et l'instruction se lit.
        let step = decode(&[0x48, 0x8d, 0x45, 0x10]).expect("8d 45 est lisible");
        let address = step.memory.expect("un opérande mémoire");
        assert_eq!(address.base, Some(5));
        assert_eq!(address.index, None);
        assert_eq!(address.displacement, 0x10);
    }
}
