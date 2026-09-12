//! **Un cœur x86-64 sans JIT — et pourquoi « sans JIT » n'est pas « lent ».**
//!
//! Ce qu'on savait, mesuré : l'interpréteur x86 en Swift rend **10,6 MIPS**, le
//! cœur rv32 en Rust en rend **157**, et un module WebAssembly **écrit à la
//! main** et compilé par WebKit en rend **1103**. Rien sans JIT ne rattrapera
//! 1103. Mais 10,6 n'est pas la limite de ce qu'on peut faire sans JIT, et ce
//! fichier va chercher ce qui manque entre les deux.
//!
//! **Ce qu'on sait maintenant**, et qu'aucun de ces trois chiffres ne disait —
//! `cargo run -p wisq-vm --release --example speed`, sur une boucle de cinq
//! instructions, la taille moyenne d'un bloc de base relevée sur le noyau
//! Alpine :
//!
//! | | débit |
//! |---|---|
//! | ce cœur-ci, en Rust | **49 MIPS** |
//! | ce que l'émetteur engendre, sous JavaScriptCore | **247 MIPS** |
//!
//! Cinq fois, et c'est la première fois que le rapport est chiffré plutôt que
//! supposé. Deux choses s'y lisent. La première : l'interpréteur en Rust rend
//! déjà **4,6 fois** celui en Swift, sans WebView ni permission. La seconde :
//! 247 n'est pas 1103, et l'écart est celui entre du code engendré et du code
//! écrit à la main — le module de l'émetteur matérialise des drapeaux et passe
//! par une boucle de répartition à chaque bloc, ce que le module écrit à la
//! main n'avait pas à faire.
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
/// **Le drapeau de direction.** Il ne fait pas partie de l'arithmétique — rien
/// ne le touche sauf `cld` et `std` — et il décide du sens dans lequel les
/// instructions de chaîne avancent. `Flags` le garde dans `other`, avec tout ce
/// que l'arithmétique ne concerne pas, donc il survit à chaque opération.
pub const DF: u64 = 1 << 10;

/// **Le drapeau d'interruption.** `cli` l'éteint, `sti` l'allume, et `popf` le
/// change sans le nommer. Comme DF, il survit à l'arithmétique et vit dans
/// `other` : rien de ce qui calcule ne le touche.
pub const IF: u64 = 1 << 9;

/// Les six que l'arithmétique définit. Tout le reste — DF, IF, TF… — survit à
/// une opération arithmétique et vit ailleurs.
pub const ARITHMETIC: u64 = CF | PF | AF | ZF | SF | OF;

/// **Ce que `popf` a le droit d'écrire.** Les bits réservés ne se laissent pas
/// poser : un noyau qui relit ce qu'il vient d'empiler doit retrouver la même
/// chose, et poser un bit que le silicium refuse ferait diverger le premier
/// `pushf` d'après.
///
/// **Écrit deux fois, et gardé.** Le cœur Swift le porte dans
/// `X86CoreDispatch.swift`, `case 0x9D` ; celui-ci est sa copie pour
/// l'émetteur. Deux littéraux dans deux langages sont exactement la forme qui
/// a déjà menti ici, donc `both_cores_mask_the_same_flag_bits` lit le fichier
/// Swift plutôt que de faire confiance à la recopie.
pub const WRITABLE_FLAGS: u64 = 0x0000_0000_003F_7FD5;

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
    /// **L'instruction a-t-elle écrit le pointeur d'instruction elle-même ?**
    /// Sans ce témoin, `step` avancerait par-dessus le saut qu'il vient de
    /// prendre, et le cœur exécuterait l'instruction d'après la cible.
    pub jumped: bool,
    /// **Un accès hors de la mémoire attachée.** Le cœur définitif aura la RAM
    /// entière et n'aura rien à refuser ; ici la mémoire est une fenêtre, et un
    /// accès qui en sort est une faute du harnais ou du corpus, pas de
    /// l'invité. L'instruction n'est alors **pas** exécutée — à moitié
    /// exécutée, elle rendrait un état que rien ne distingue d'un état juste —
    /// et ce témoin le dit.
    pub faulted: bool,
    /// **La base du segment GS.** Le processeur la tient dans un registre
    /// caché qu'aucune instruction ordinaire ne montre ; ici elle est un champ,
    /// posé par l'hôte comme le noyau la poserait par `wrmsr`. Zéro par défaut,
    /// ce qui rend `%gs:x` équivalent à `x` — la conduite d'un noyau qui n'a
    /// pas encore installé ses variables par cœur.
    pub gs_base: u64,
    /// **Les registres de contrôle**, par leur numéro. Cinq existent — 0, 2, 3,
    /// 4 et 8 — et le tableau en porte neuf pour que l'indice *soit* le numéro
    /// : une table compacte demanderait une correspondance, et c'est
    /// exactement le genre d'endroit où l'on finit par lire CR4 pour CR3.
    ///
    /// CR0 porte la pagination et la protection en écriture, CR3 la racine de
    /// la table de pages, CR4 les extensions. Voir `crate::x86_paging`.
    pub control: [u64; 9],
    /// **L'adresse invitée sur laquelle la traduction s'est arrêtée**, quand
    /// elle s'est arrêtée. `faulted` dit qu'il y a eu faute ; celui-ci dit
    /// laquelle et pourquoi, ce qu'aucun booléen ne peut porter.
    pub unmapped: Option<crate::x86_paging::Unmapped>,
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
    fn window(&self, address: u64, size: usize) -> Option<std::ops::Range<usize>> {
        let start = address.checked_sub(self.base)?;
        let end = start.checked_add(size as u64)?;
        if end > self.bytes.len() as u64 {
            return None;
        }
        Some(start as usize..end as usize)
    }

    /// La fenêtre porte-t-elle cet accès ? **Vérifier sans écrire**, pour
    /// qu'un accès à cheval sur deux pages puisse s'assurer de ses deux
    /// moitiés avant d'en poser une seule.
    pub fn holds(&self, address: u64, size: usize) -> bool {
        self.window(address, size).is_some()
    }

    pub fn read(&self, address: u64, width: Width) -> Option<u64> {
        self.read_bytes(address, width as usize)
    }

    /// **Lire un nombre d'octets qui n'est pas forcément une largeur
    /// d'opérande.** Un accès coupé par une frontière de page se répartit en
    /// deux moitiés de tailles quelconques : trois octets et cinq, par
    /// exemple. Au-delà de huit, les octets hauts se perdraient en silence, et
    /// la fonction rend `None` plutôt que la moitié d'une réponse.
    pub fn read_bytes(&self, address: u64, size: usize) -> Option<u64> {
        if size > 8 {
            return None;
        }
        let window = self.window(address, size)?;
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
        self.write_bytes(address, width as usize, value)
    }

    /// L'écriture correspondante. Voir `read_bytes`.
    pub fn write_bytes(&mut self, address: u64, size: usize, value: u64) -> Option<()> {
        if size > 8 {
            return None;
        }
        let window = self.window(address, size)?;
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
    /// **Lire un port d'entrée-sortie.** Le port vient d'un octet immédiat
    /// (`E4`, `E5`) ou de DX (`EC`, `ED`) ; la largeur vient de l'opcode pair —
    /// un octet — ou impair — celle des préfixes. Le résultat va dans
    /// l'accumulateur, à cette largeur.
    ///
    /// **Pourquoi ces deux-là existent maintenant** : un noyau Linux écrit sur
    /// sa console dans ses premières centaines d'instructions, par `out` sur le
    /// port 0x3F8. Sans elles le décodeur rendait `None`, l'émetteur refusait
    /// la région, et un noyau lancé par le bureau s'arrêtait avant d'avoir rien
    /// dit — un silence indiscernable d'une panne.
    PortIn,
    /// **Écrire sur un port d'entrée-sortie.** `E6`, `E7` avec un port
    /// immédiat ; `EE`, `EF` avec DX. La valeur vient de l'accumulateur.
    PortOut,
    /// **Les quatre instructions privilégiées qu'un noyau atteint tout de
    /// suite**, et qu'aucune grille ne connaissait.
    ///
    /// Mesuré, pas supposé : le point d'entrée d'un noyau Linux 6.6 x86-64
    /// exécute **sept** instructions avant d'arriver sur `wrmsr`. Le décodeur
    /// rendait `None` là, et l'émetteur ne pouvait pas même dire pourquoi — un
    /// `CannotDecode` ne nomme rien. Sur les huit mégaoctets de texte du même
    /// noyau : `wrmsr` 34 fois, `rdmsr` 34, `rdtsc` 28, `cpuid` 27.
    ///
    /// Elles sont **décodées** ici, et refusées ailleurs : les exécuter demande
    /// un modèle de MSR, de compteur d'horodatage et de capacités que rien
    /// n'a encore. Ce qui change est qu'un refus porte maintenant un nom.
    /// `0F 31` — le compteur d'horodatage, dans EDX:EAX.
    ReadTimestamp,
    /// `0F A2` — les capacités du processeur, dans EAX/EBX/ECX/EDX.
    CpuId,
    /// `0F 32` — lire le registre spécifique au modèle que ECX désigne.
    ReadModelRegister,
    /// `0F 30` — y écrire. C'est l'instruction sur laquelle un noyau s'arrête,
    /// à sa huitième.
    WriteModelRegister,
    /// **Charger une table de descripteurs.** `0F 01 /2` est `lgdt`, `/3` est
    /// `lidt` : le même opcode, et trois bits de ModRM pour tout écart. Le
    /// processeur lit à l'adresse donnée une limite de deux octets suivie
    /// d'une base de huit, et s'en sert ensuite pour interpréter chaque
    /// sélecteur — et, pour `lidt`, chaque interruption.
    ///
    /// Un noyau les écrit tôt : le `lgdt` d'Alpine est à l'octet 1512 de son
    /// point d'entrée, et c'est là que l'exploration de la région s'arrêtait.
    LoadDescriptorTable {
        /// `lidt` plutôt que `lgdt` : la table des interruptions, pas celle
        /// des segments. Deux tables, deux registres, aucun rapport entre
        /// elles — les confondre chargerait l'une à la place de l'autre sans
        /// que rien ne le signale.
        interrupts: bool,
    },
    /// **Ranger une table de descripteurs.** `0F 01 /0` (`sgdt`) et `/1`
    /// (`sidt`) font le trajet inverse : ils écrivent les dix octets en
    /// mémoire. Non privilégiées, celles-là, ce qui les rend fréquentes hors
    /// du noyau aussi.
    StoreDescriptorTable {
        /// `sidt` plutôt que `sgdt`.
        interrupts: bool,
    },
    /// **`0F 01 F8` : échanger la base de GS avec celle du noyau.**
    ///
    /// Une seule encodage dans tout le groupe — `reg=7`, `rm=0`, opérande
    /// registre — et ses voisins immédiats n'ont rien à voir : `F9` est
    /// `rdtscp`, `C1` est `vmcall`. C'est la première instruction d'un
    /// gestionnaire d'interruption, celle par laquelle le noyau retrouve ses
    /// propres données quand il interrompt un programme.
    SwapGs,
    /// **`F2 0F 00 /6` : charger la base GS du noyau depuis un sélecteur.**
    ///
    /// `lkgs`, arrivée avec FRED : elle écrit `IA32_KERNEL_GS_BASE` à partir
    /// du descripteur que le sélecteur désigne, sans toucher GS lui-même. Le
    /// noyau Alpine la porte dans `native_lkgs` et ne l'exécute que si CPUID
    /// annonce `LKGS` — ce que `cpuid` n'annonce pas. Elle est décodée parce
    /// qu'elle est **atteinte statiquement** depuis `init_scattered_cpuid_features`
    /// et qu'un décodeur qui ne la lit pas refusait la région entière ; elle
    /// est refusée par nom à l'exécution, faute de table de descripteurs.
    /// Seule la forme à registre, sans REX, est lue : c'est celle du noyau.
    LoadKernelGs,
    /// **`0F 01 /7`, forme mémoire : oublier la traduction d'une page.**
    ///
    /// `invlpg` prend une adresse, pas une valeur : l'opérande n'est jamais
    /// lu, et une page absente ne faute pas. Le noyau l'exécute dans
    /// `native_flush_tlb_one_user` après avoir changé une entrée de table.
    /// L'émetteur efface la case du tampon que la page occupe ; l'interpréteur,
    /// qui marche les tables à chaque accès, n'a rien à oublier. La forme à
    /// registre du même `/7` est `swapgs`, et seulement avec `rm` à zéro.
    InvalidatePage,
    /// **`0F 01 C1` et `0F 01 D9` : l'appel à l'hyperviseur**, `vmcall` chez
    /// Intel, `vmmcall` chez AMD. Cette machine n'a pas d'hyperviseur
    /// au-dessus d'elle : personne pour répondre. Le noyau Alpine les porte
    /// dans `vmware_platform`, sa sonde d'hyperviseur, et ne les exécute que si
    /// CPUID annonce la signature VMware, ce que `cpuid` n'annonce pas. Ils
    /// sont décodés parce qu'ils sont **atteints statiquement** depuis
    /// `init_hypervisor_platform`, et refusés par nom à l'exécution. Deux
    /// paires exactes `(reg, rm)` de la forme à registre, comme `swapgs` : leurs
    /// voisins `vmlaunch` et `vmrun` restent illisibles.
    HypervisorCall {
        /// `vmmcall` plutôt que `vmcall` : la forme d'AMD.
        amd: bool,
    },
    /// **`66 0F 38 82 /r` : purger le tampon par identifiant de contexte.**
    ///
    /// `invpcid` prend le type de purge dans le registre `reg` et un
    /// descripteur de seize octets en mémoire — il n'a pas de forme à
    /// registre. Cette machine n'a pas de PCID : `cpuid` n'annonce ni `PCID`
    /// ni `INVPCID`, et le noyau Alpine ne l'exécute que si les deux sont
    /// promis. Mais elle est à 103 octets de `native_flush_tlb_one_user`,
    /// **atteinte statiquement** depuis le trampoline des alternatives, et un
    /// décodeur qui ne la lit pas refusait la région entière. Décodée pour
    /// cela, refusée par nom à l'exécution ; le préfixe `66` fait partie de
    /// l'opcode, et le reste de la page `0F 38` reste illisible.
    InvalidatePcid,
    /// **`0F 00 /3`, forme à registre : charger le registre de tâche.**
    ///
    /// `ltr` prend un sélecteur, celui du TSS du processeur — la structure
    /// où le silicium va chercher la pile de secours à chaque entrée
    /// d'exception. Le noyau Alpine l'exécute dans
    /// `cpu_init_exception_handling`, avec `0x40`, à 72 octets de
    /// `native_load_tr_desc` : ce n'est pas la famille de l'`int3`, celle-là
    /// tourne. L'émetteur range le sélecteur, seize bits, dans sa case ;
    /// l'interpréteur la refuse par nom, faute de table où trouver le TSS. Le
    /// reste du groupe 6 — `sldt`, `str`, `lldt`, `verr`, `verw` — et la forme
    /// mémoire restent illisibles : le noyau ne les écrit pas ici.
    LoadTaskRegister,
    /// **`0F 00 /2`, forme à registre : charger la table de descripteurs
    /// locale.**
    ///
    /// `lldt` prend un sélecteur qui désigne, dans la GDT, le descripteur de
    /// la LDT. Le noyau Alpine l'exécute dans `native_set_ldt`, depuis
    /// `load_mm_ldt` dans `cpu_init`, avec **zéro** : il n'a pas de LDT, et
    /// le sélecteur nul le dit. L'émetteur laisse passer le nul — rien à
    /// charger, c'est exactement ce que demande le noyau — et s'arrête par
    /// son nom sur tout autre, faute de table globale où le trouver.
    /// L'interpréteur la refuse par nom. Le reste du groupe 6 reste illisible.
    LoadLocalDescriptorTable,
    /// **Charger un sélecteur de segment.** `8E /r`, où le champ `reg`
    /// désigne lequel des six. Le noyau en charge trois d'affilée — DS, SS,
    /// ES — à l'octet 1524 de son point d'entrée, juste après avoir chargé sa
    /// table de descripteurs globale : les sélecteurs n'ont de sens qu'une
    /// fois la table en place, et l'ordre le dit.
    LoadSegment {
        /// Lequel des six. `Cs` n'apparaît jamais ici : `8E /1` lève `#UD`.
        segment: Segment,
    },
    /// **Ranger un sélecteur de segment.** `8C /r`, le trajet inverse. Non
    /// privilégiée, celle-là : c'est ainsi qu'un programme lit son propre
    /// anneau, en regardant les deux bits bas de CS.
    StoreSegment {
        /// Lequel des six, `Cs` compris.
        segment: Segment,
    },
    /// **Lire un registre de contrôle.** `0F 20 /r` : le numéro vient du champ
    /// `reg`, la destination du `rm`, et l'opérande fait **huit octets sans
    /// REX.W** — la taille est forcée en mode 64 bits.
    ///
    /// C'est l'instruction sur laquelle la lecture en ligne droite du point
    /// d'entrée s'arrêtait, à l'octet 113 : `0F 20 E1`, `mov %cr4,%rcx`.
    ReadControlRegister {
        /// CR0 la pagination, CR2 l'adresse fautive, CR3 la racine de la table
        /// de pages, CR4 les extensions, CR8 la priorité d'interruption. Cinq
        /// registres sans rien de commun ; un seul nom les confondrait.
        which: u8,
    },
    /// **Lire un registre de débogage.** `0F 21 /r`, le numéro dans `reg`,
    /// la destination dans `rm`, toujours en forme à registre. Cette machine
    /// n'a pas de points d'arrêt matériels : l'émetteur rend l'état de repos
    /// du silicium — zéro pour les quatre adresses, les bits réservés de DR6,
    /// le bit 10 de DR7. DR4 et DR5 ne se décodent pas : alias ou `#UD`
    /// selon CR4.DE, les lire inventerait un registre.
    ReadDebugRegister {
        /// 0 à 3 (les adresses), 6 (l'état), 7 (le contrôle).
        which: u8,
    },
    /// **Écrire un registre de débogage.** `0F 23 /r`. Le noyau Alpine
    /// efface les six dans `cpu_init` — `pv_native_set_debugreg` — et le
    /// décodeur les laissait illisibles exprès. L'émetteur laisse passer une
    /// écriture qui ne change rien de vrai (l'état de repos) et s'arrête par
    /// son nom sur une qui armerait un point d'arrêt ; l'interpréteur refuse
    /// par nom.
    WriteDebugRegister {
        /// 0 à 3 (les adresses), 6 (l'état), 7 (le contrôle).
        which: u8,
    },
    /// **Écrire un registre de contrôle.** `0F 22 /r`. Écrire CR3 change la
    /// table de pages entière ; écrire CR0 allume ou éteint la pagination.
    WriteControlRegister {
        /// Voir `ReadControlRegister`.
        which: u8,
    },
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
    /// Un saut relatif, conditionnel ou non. Le déplacement est dans `imm`,
    /// **relatif à l'instruction suivante** — pas à celle-ci.
    Jump(Option<Condition>),
    /// `loop` : décrémenter RCX et sauter tant qu'il n'est pas nul. Il ne
    /// touche à aucun drapeau, ce qui le distingue d'un `dec` suivi d'un `jnz`.
    LoopWhile,
    /// Un saut dont la cible est dans un registre. Le module ne peut pas savoir
    /// à quel bloc elle correspond : il rend la main.
    JumpIndirect,
    /// **`ud2` : l'instruction indéfinie, que Linux exécute exprès.**
    ///
    /// `BUG()` et `WARN()` se compilent en `0f 0b`, et un noyau en sème par
    /// milliers — un à chaque chemin d'erreur. La décoder est indispensable
    /// pour que la région qui la contient se compile ; l'exécuter est une
    /// faute, et c'est tout son propos.
    Undefined,
    /// **`call *r/m`** : la cible est une valeur, pas un déplacement. C'est
    /// l'appel par pointeur de fonction, dont un noyau est fait. Distinguée de
    /// `Call` parce que les deux n'ont rien en commun côté émetteur : l'un a
    /// une cible connue à la compilation, l'autre pas.
    CallIndirect,
    /// `push` : descendre la pile de huit octets, puis y écrire.
    Push,
    /// `pop` : lire au sommet, puis remonter la pile.
    Pop,
    /// `call` relatif : empiler l'adresse de retour, puis sauter.
    Call,
    /// `ret` : dépiler l'adresse de retour et y aller.
    Return,
    /// **Le retour lointain.** Dépile RIP *et* CS, là où `Return` ne dépile que
    /// RIP. Un noyau s'en sert une fois, au démarrage, pour charger son propre
    /// sélecteur de code : c'est la treizième instruction du point d'entrée
    /// d'Alpine, et la première chose qui l'arrêtait après `wrmsr`.
    FarReturn,
    /// **Le retour d'interruption.** `48 cf` dépile **cinq** mots — RIP, CS,
    /// RFLAGS, RSP, SS — dans cet ordre : c'est le cadre qu'une faute ou une
    /// interruption a posé en entrant, défait en sortant. Un gestionnaire de
    /// faute de page se termine par lui, et l'instruction fautive est alors
    /// **rejouée** : c'est ainsi qu'un noyau cartographie à la demande.
    ///
    /// Le code d'erreur, lui, n'en fait pas partie : le processeur l'empile
    /// mais ne le dépile pas, et c'est au gestionnaire d'ajouter huit à RSP
    /// avant — Linux le fait. Le dépiler ici décalerait tout le cadre.
    InterruptReturn,
    /// `leave` : défaire le cadre de pile — RSP reprend RBP, puis RBP se
    /// dépile. Deux instructions en une, et c'est ce qui la rend commode.
    Leave,
    /// **La multiplication à un opérande.** Le produit fait **deux fois** la
    /// largeur, et il sort en deux morceaux : RDX:RAX, ou AX seul quand
    /// l'opérande est un octet. Rien d'autre dans le jeu n'écrit deux
    /// registres à la fois, et c'est ce qui l'empêche de passer par la
    /// machinerie à une destination.
    WideMultiply {
        signed: bool,
    },
    /// **La multiplication à deux ou trois opérandes.** Le produit est tronqué
    /// à la largeur, et la retenue et le débordement disent — ensemble, ils ne
    /// disent jamais autre chose — que le résultat ne tenait pas.
    Multiply,
    /// **La division.** RDX:RAX par l'opérande ; quotient dans RAX, reste dans
    /// RDX. C'est la seule instruction arithmétique du jeu qui peut **lever** :
    /// diviseur nul, ou quotient qui ne tient pas dans la largeur.
    Divide {
        signed: bool,
    },
    /// `cbw`, `cwde`, `cdqe` : l'accumulateur s'étend dans lui-même, de la
    /// demi-largeur à la largeur.
    WidenAccumulator,
    /// `cwd`, `cdq`, `cqo` : le signe de l'accumulateur remplit RDX. Tout
    /// compilateur l'émet juste avant `idiv` — sans lui, le dividende n'a pas
    /// de moitié haute.
    SignIntoData,
    /// `clc`, `stc`, `cmc` : la retenue posée à la main, les cinq autres
    /// drapeaux intacts.
    CarryFlag(CarryAction),
    /// **`cld` et `std`.** Le seul moyen de changer le sens des instructions de
    /// chaîne, et donc le seul moyen de le vérifier.
    DirectionFlag(bool),
    /// **Le drapeau d'interruption.** `FA` l'éteint (`cli`), `FB` l'allume
    /// (`sti`). Un noyau les écrit partout : autour de chaque section
    /// critique, et une dernière fois avant de s'arrêter pour de bon.
    ///
    /// **Décodées, pas produites.** Le poser dans RFLAGS serait presque juste
    /// — un bit, à la même place que le drapeau de direction juste au-dessus —
    /// et c'est ce qui le rend dangereux : rien ne délivre d'interruption, donc
    /// un module qui accepte `sti` prétendrait en attendre. Un refus nommé vaut
    /// mieux qu'une machine qui a l'air d'écouter.
    InterruptFlag(bool),
    /// **`F4` : arrêter le processeur jusqu'à la prochaine interruption.**
    ///
    /// C'est la troisième instruction du point d'entrée d'Alpine à l'octet 291,
    /// entre un `cli` et un `jmp -4` : la boucle d'arrêt d'un noyau qui n'a
    /// plus rien à faire, ou qui a paniqué. Sans interruptions, la produire
    /// donnerait un arrêt définitif déguisé en attente.
    Halt,
    /// **`CC` et `CD nn` : une interruption demandée par le code.** Le vecteur
    /// est dans `imm` — trois pour `int3`, l'octet suivant pour `int n`.
    ///
    /// C'est un **appel**, pas une faute : l'adresse empilée est celle de
    /// l'instruction *suivante*, et l'`iretq` du gestionnaire y reprend. Le
    /// cœur Swift avance RIP avant d'entrer, et c'est la même règle ici.
    ///
    /// Ce qui l'a fait entrer : `__x86_indirect_thunk_rax`, la retpoline que
    /// le noyau porte avant que les alternatives ne la réécrivent —
    /// `call +1 ; int3 ; …` — dont l'`int3` n'est jamais exécuté mais doit se
    /// lire, sans quoi la région entière est refusée.
    SoftwareInterrupt,
    /// **`9C` : empiler RFLAGS.** Huit octets en mode 64 bits, deux avec le
    /// préfixe 0x66. La moitié qui *sauve* l'état des interruptions avant de
    /// les couper.
    PushFlags,
    /// **`9D` : dépiler RFLAGS.** La moitié qui le rend. Elle peut rallumer le
    /// drapeau d'interruption sans jamais nommer `sti`, et c'est ce qui
    /// l'empêche d'être produite tant que rien ne délivre d'interruption : un
    /// module qui accepte `popf` accepte un `sti` déguisé.
    PopFlags,
    /// **`movs` : de la mémoire vers la mémoire, RSI vers RDI.** Avec `repeat`,
    /// c'est le `memcpy` d'un noyau — 949 des 1 092 régions que le compilateur
    /// refusait encore depuis un vrai point d'entrée en portaient un.
    StringMove {
        repeat: bool,
    },
    /// **`stos` : l'accumulateur vers RDI.** Avec `repeat`, c'est `memset`.
    StringStore {
        repeat: bool,
    },
    /// **`rcl` et `rcr`** : la rotation passe **à travers** la retenue. Le
    /// registre tourné fait donc la largeur **plus un bit** — soixante-cinq
    /// pour un quadruple mot — et c'est ce qui les sépare de `rol` et `ror`.
    RotateThroughCarry {
        left: bool,
    },
    /// **`shld` et `shrd`** : un décalage dont les bits entrants viennent d'un
    /// **second** opérande au lieu d'être des zéros ou des copies du signe.
    /// C'est ce qui déplace un champ à cheval sur deux mots.
    DoubleShift {
        left: bool,
    },
    /// **`xchg`** : les deux opérandes échangent leur contenu, et aucun drapeau
    /// ne bouge. En mémoire elle est implicitement verrouillée — ce qui ne
    /// change rien ici, où il n'y a qu'un fil.
    Exchange,
    /// **`xadd`** : la somme va dans la destination, et l'**ancienne**
    /// destination dans la source. Les drapeaux sont ceux d'un `add`.
    ExchangeAndAdd,
    /// **`cmpxchg`** : comparer l'accumulateur à la destination, puis écrire
    /// l'un ou l'autre selon le verdict. C'est sur elle que reposent tous les
    /// verrous d'un noyau.
    CompareAndExchange,
    /// **`cmpxchg16b`** : comparer seize octets de mémoire à RDX:RAX ; s'ils
    /// tiennent tous deux, y écrire RCX:RBX et poser ZF ; sinon relire la
    /// paire dans RDX:RAX et l'éteindre. Aucun autre drapeau ne bouge. C'est
    /// le chemin rapide de la liste libre de SLUB, que le noyau ne prend que
    /// si CPUID annonce `CX16`. REX.W obligatoire : sans lui c'est
    /// `cmpxchg8b`, que rien n'exécute ici.
    CompareAndExchangeSixteen,
    /// Ne rien faire. Un noyau en est plein : c'est ce qui aligne les cibles de
    /// saut sur des frontières de cache, et ce qui reste quand une correction
    /// à chaud efface une instruction.
    Nop,
}

/// Ce que `clc`, `stc` et `cmc` font de la retenue.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CarryAction {
    Clear,
    Set,
    Complement,
}

/// **Les six sélecteurs de segment**, dans l'ordre où le champ `reg` d'un
/// ModRM les désigne. Le mode 64 bits a vidé quatre d'entre eux de leur base
/// — mais pas de leur existence : un noyau les charge quand même, et FS et GS
/// gardent la leur.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Segment {
    /// `reg=0`.
    Es,
    /// `reg=1`. Se **range** mais ne se charge pas : changer de segment de code
    /// par un `mov` lève `#UD`, et c'est le retour lointain qui le fait.
    Cs,
    /// `reg=2`. Changer SS change la pile, et inhibe les interruptions
    /// jusqu'à l'instruction suivante.
    Ss,
    /// `reg=3`.
    Ds,
    /// `reg=4`. Garde une base en mode 64 bits.
    Fs,
    /// `reg=5`. Garde une base en mode 64 bits — celle qu'un noyau échange
    /// par `swapgs`.
    Gs,
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
    /// **Relatif au pointeur d'instruction.** Le déplacement se compte alors
    /// depuis l'octet qui **suit** l'instruction — pas depuis son début, et
    /// c'est l'erreur d'un octet la plus facile à écrire. Un noyau moderne en
    /// est fait : toute variable globale s'atteint comme ça, et tout appel
    /// indirect passe par une table adressée comme ça.
    pub relative: bool,
    /// **Le préfixe de segment GS.** L'adresse calculée n'est alors pas
    /// l'adresse finale : la base du segment s'y ajoute. Un noyau x86-64 range
    /// derrière ce préfixe tout ce qui est propre à un cœur — la tâche
    /// courante, la pile d'interruption, le compteur de préemption — et il y
    /// accède des dizaines de milliers de fois. Ignorer le préfixe rendrait
    /// une adresse plausible et fausse ; le refuser rejetait, à la mesure sur
    /// un vrai noyau Alpine, 18 795 instructions.
    ///
    /// **FS n'a pas d'équivalent ici**, et le décodeur le refuse : l'oracle
    /// matériel ne peut pas poser sa base sans se détruire lui-même, donc
    /// aucune conduite ne serait vérifiée.
    pub gs: bool,
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

impl Decoded {
    /// Le squelette d'une instruction qui ne porte ni opérande ni mémoire —
    /// un saut, essentiellement. Écrit une fois plutôt que quinze, pour que
    /// l'ajout d'un champ ne se rate pas à la quinzième.
    fn nothing(width: Width) -> Self {
        Decoded {
            op: Op::Not,
            width,
            dst: 0,
            src: 0,
            imm: 0,
            immediate: false,
            discards: false,
            length: 0,
            dst_high: false,
            src_high: false,
            count_is_cl: false,
            src_width: width,
            memory: None,
            memory_is_source: false,
        }
    }
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
                let at = self.after(instruction);
                let at = self.effective_address(&address, at);
                self.read_memory(at, instruction.width).ok()
            }
            _ => Some(self.get(instruction.dst, instruction.width, instruction.dst_high)),
        }
    }

    fn read_source(&mut self, instruction: &Decoded, width: Width) -> Option<u64> {
        match instruction.memory {
            Some(address) if instruction.memory_is_source => {
                let at = self.after(instruction);
                let at = self.effective_address(&address, at);
                self.read_memory(at, width).ok()
            }
            _ => Some(self.get(instruction.src, width, instruction.src_high)),
        }
    }

    /// Écrire le résultat là où l'opérande de destination se trouvait.
    fn write_destination(&mut self, instruction: &Decoded, value: u64) -> Option<()> {
        match instruction.memory {
            Some(address) if !instruction.memory_is_source => {
                let at = self.after(instruction);
                let at = self.effective_address(&address, at);
                self.write_memory(at, instruction.width, value).ok()
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
    /// L'adresse de l'octet qui **suit** l'instruction — celle depuis laquelle
    /// un déplacement relatif au pointeur d'instruction se compte.
    fn after(&self, instruction: &Decoded) -> u64 {
        self.rip.wrapping_add(instruction.length as u64)
    }

    fn effective_address(&self, address: &Address, after: u64) -> u64 {
        let mut value = address.displacement as u64;
        // **La base du segment s'ajoute au tout, pas à la base du ModRM.** Elle
        // vient avant le calcul plutôt qu'après pour la même raison que
        // l'adressage boucle sur soixante-quatre bits : l'ordre ne change rien
        // au résultat, et le dire ici évite d'avoir à le redire à chaque bras.
        //
        // **Elle s'ajoute aussi au mode relatif**, et c'est le seul endroit où
        // le placer le garantit. Le bras relatif sortait avant, et les deux
        // cœurs auraient divergé sur `%gs:x(%rip)` — l'émetteur ajoutait la
        // base, l'interpréteur non. Personne n'écrit cette forme ; le corpus
        // en porte un cas exprès, parce que « personne » n'est pas « jamais ».
        if address.gs {
            value = value.wrapping_add(self.gs_base);
        }
        if address.relative {
            return value.wrapping_add(after);
        }
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

        // **La rotation à travers la retenue tourne sur un bit de plus.** Le
        // registre effectif fait `bits + 1` — soixante-cinq pour un quadruple
        // mot — et c'est pour ça qu'elle passe par cent vingt-huit bits ici :
        // rien de plus étroit ne peut la porter.
        if let Op::RotateThroughCarry { left: to_the_left } = instruction.op {
            let span = bits + 1;
            let turn = count % span;
            let carry_in = u128::from(self.flags.read() & CF);
            let wide = (carry_in << bits) | u128::from(value);
            let rotated = if turn == 0 {
                wide
            } else if to_the_left {
                ((wide << turn) | (wide >> (span - turn))) & ((1u128 << span) - 1)
            } else {
                ((wide >> turn) | (wide << (span - turn))) & ((1u128 << span) - 1)
            };
            let result = (rotated as u64) & mask;
            let carry = (rotated >> bits) as u64 & 1;
            // Le débordement n'est défini que pour un tour de un, et il se lit
            // sur les **deux bits de tête du résultat élargi** : la retenue
            // sortante et le bit de signe.
            let top = u64::from(result & width.sign() != 0);
            let overflow = if to_the_left {
                carry ^ top
            } else {
                top ^ ((result >> (bits - 2)) & 1)
            };
            let mut flags = self.flags.read() & !(CF | OF);
            flags |= carry * CF;
            flags |= overflow * OF;
            self.flags.write(flags);
            if !instruction.discards {
                self.faulted |= self.write_destination(instruction, result).is_none();
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

    /// **Le décalage double.** Ce qui le distingue d'un décalage ordinaire :
    /// les bits qui entrent ne sont ni des zéros ni des copies du signe, mais
    /// les bits de tête — ou de queue — d'un **second** registre. C'est
    /// l'instruction qui déplace un champ à cheval sur deux mots, et un noyau
    /// s'en sert pour tout ce qui est bitmap ou décalage de grand entier.
    fn double_shift(&mut self, instruction: &Decoded, value: u64, to_the_left: bool) {
        let width = instruction.width;
        let mask = width.mask();
        let bits = width.bits();
        let raw = if instruction.count_is_cl {
            self.regs[1]
        } else {
            instruction.imm
        };
        let count = raw & if width == Width::Qword { 63 } else { 31 };
        let value = value & mask;
        // Comme partout dans cette famille : un compte nul ne touche à aucun
        // drapeau — mais il **écrit** la destination, et une écriture de
        // trente-deux bits efface la moitié haute. Le silicium l'a dit sur
        // deux états, ceux où `%cl` vaut zéro une fois masqué.
        if count == 0 {
            self.faulted |= self.write_destination(instruction, value).is_none();
            return;
        }
        let Some(source) = self.read_source(instruction, width) else {
            self.faulted = true;
            return;
        };
        let source = source & mask;
        // **Le compte peut dépasser la largeur, et l'architecture ne dit alors
        // rien.** En seize bits le masque du compte vaut trente et un : un
        // `shldw %cl` avec vingt dans `%cl` demande un décalage que le manuel
        // déclare indéfini. Il ne peut donc pas se vérifier contre le silicium
        // — un processeur a le droit de rendre autre chose — mais les deux
        // cœurs doivent quand même **s'accorder entre eux**, sans quoi une
        // divergence serait imputée à l'émetteur alors qu'elle vient d'ici. Le
        // décalage enveloppant est ce que WebAssembly fait de son côté ; c'est
        // donc lui qu'on prend, et le corpus n'exerce aucun de ces cas.
        let back = bits.wrapping_sub(count);
        let (result, carry) = if to_the_left {
            let out = (value.wrapping_shr(back as u32)) & 1;
            (
                (value.wrapping_shl(count as u32) | source.wrapping_shr(back as u32)) & mask,
                out,
            )
        } else {
            let out = value.wrapping_shr(count.wrapping_sub(1) as u32) & 1;
            (
                (value.wrapping_shr(count as u32) | source.wrapping_shl(back as u32)) & mask,
                out,
            )
        };
        // Le débordement n'est défini que pour un compte de un : c'est le
        // changement de signe.
        let sign = width.sign();
        let overflow = u64::from((value ^ result) & sign != 0);
        self.flags = Flags {
            op: FlagOp::Known,
            left: 0,
            right: 0,
            result,
            width,
            carry_in: 0,
            arithmetic: (carry * CF)
                | (overflow * OF)
                | (u64::from(result == 0) * ZF)
                | (u64::from(result & sign != 0) * SF)
                | (u64::from((result as u8).count_ones() % 2 == 0) * PF),
            other: self.flags.other,
        };
        self.faulted |= self.write_destination(instruction, result).is_none();
    }

    /// **La pile, et le seul registre qui la porte.**
    ///
    /// Rien ici ne touche aux drapeaux — pas même `call` ni `ret`. Et chaque
    /// opération écrit **deux** choses : RSP et la mémoire, ou RSP et un
    /// registre. C'est ce qui les sort de la machinerie à une destination.
    ///
    /// L'ordre compte : `push` descend RSP **puis** écrit, et `pop` lit
    /// **puis** remonte. L'inverser écrirait huit octets au-dessus du sommet,
    /// là où une interruption a le droit de passer.
    fn stack(&mut self, instruction: &Decoded) {
        let after = self.rip.wrapping_add(instruction.length as u64);
        match instruction.op {
            Op::Push => {
                let value = if instruction.immediate {
                    instruction.imm
                } else {
                    // Un registre, ou huit octets de mémoire — `read_destination`
                    // fait les deux. Et dans les deux cas la valeur est lue
                    // **avant** que RSP ne bouge : `push %rsp` empile la valeur
                    // d'avant la descente.
                    let Some(value) = self.read_destination(instruction) else {
                        self.faulted = true;
                        return;
                    };
                    value
                };
                self.push(value);
            }
            Op::Pop => {
                let Some(value) = self.pop() else { return };
                self.regs[instruction.dst as usize] = value;
            }
            Op::Call => {
                self.push(after);
                if self.faulted {
                    return;
                }
                self.rip = after.wrapping_add(instruction.imm);
                self.jumped = true;
            }
            Op::CallIndirect => {
                // **La cible se lit avant que la pile ne bouge.** L'inverse
                // marcherait tant que la cible n'est pas `-8(%rsp)` — et un
                // noyau qui appelle par un pointeur pris sur sa propre pile
                // existe.
                let Some(target) = self.read_destination(instruction) else {
                    self.faulted = true;
                    return;
                };
                self.push(after);
                if self.faulted {
                    return;
                }
                self.rip = target;
                self.jumped = true;
            }
            Op::Return => {
                let Some(value) = self.pop() else { return };
                self.rip = value;
                self.jumped = true;
            }
            _ => {
                // `leave` : RSP reprend RBP, puis RBP se dépile.
                self.regs[4] = self.regs[5];
                let Some(value) = self.pop() else { return };
                self.regs[5] = value;
            }
        }
    }

    /// **Les trois échanges.** Ce qui les réunit : elles écrivent **deux**
    /// endroits, et l'ordre compte. Lire la destination après avoir écrit la
    /// source rendrait la valeur qu'on vient d'y mettre.
    fn exchange(&mut self, instruction: &Decoded) {
        if instruction.op == Op::CompareAndExchangeSixteen {
            self.compare_and_exchange_sixteen(instruction);
            return;
        }
        let width = instruction.width;
        let (Some(destination), Some(source)) = (
            self.read_destination(instruction),
            self.read_source(instruction, width),
        ) else {
            self.faulted = true;
            return;
        };
        match instruction.op {
            Op::Exchange => {
                // Aucun drapeau. C'est la seule des trois dans ce cas, et
                // l'oublier écraserait ce que le processeur préserve.
                self.faulted |= self.write_destination(instruction, source).is_none();
                self.set(instruction.src, width, instruction.src_high, destination);
            }
            Op::ExchangeAndAdd => {
                let sum = destination.wrapping_add(source);
                self.faulted |= self.write_destination(instruction, sum).is_none();
                self.set(instruction.src, width, instruction.src_high, destination);
                self.flags = Flags {
                    op: FlagOp::Add,
                    left: destination,
                    right: source,
                    result: sum,
                    width,
                    carry_in: 0,
                    arithmetic: 0,
                    other: self.flags.other,
                };
            }
            _ => {
                // **`cmpxchg` compare l'accumulateur à la destination**, et
                // les drapeaux sont ceux de cette comparaison — pas ceux d'une
                // comparaison entre la destination et la source.
                let accumulator = self.get(0, width, false);
                let difference = accumulator.wrapping_sub(destination);
                let equal = difference & width.mask() == 0;
                // **Quand l'égalité ne tient pas, la destination n'est pas
                // écrite du tout.** Pas même réécrite avec sa propre valeur :
                // le silicium l'a dit. `cmpxchgl %ecx, %edx` qui échoue laisse
                // RDX entier, alors qu'une écriture de trente-deux bits — même
                // de la même valeur — en effacerait la moitié haute. Sept cas
                // sur les vingt-quatre, tous sur ce seul bit de conduite.
                if equal {
                    self.faulted |= self.write_destination(instruction, source).is_none();
                } else {
                    self.set(0, width, false, destination);
                }
                self.flags = Flags {
                    op: FlagOp::Sub,
                    left: accumulator,
                    right: destination,
                    result: difference,
                    width,
                    carry_in: 0,
                    arithmetic: 0,
                    other: self.flags.other,
                };
            }
        }
    }

    /// **`cmpxchg16b` : seize octets contre RDX:RAX.** La machinerie des
    /// échanges lit et écrit un mot ; celle-ci en lit deux, les compare tous
    /// deux, et n'écrit RCX:RBX que si les deux tiennent — sinon RDX:RAX
    /// relisent la paire. ZF est le seul drapeau qui bouge.
    ///
    /// **Les deux mots sont lus avant qu'un seul ne soit écrit**, et si la
    /// seconde écriture faute, la première est défaite : une instruction qui
    /// faute ne laisse aucune trace, et RIP reste dessus.
    fn compare_and_exchange_sixteen(&mut self, instruction: &Decoded) {
        let Some(address) = instruction.memory else {
            unreachable!("le décodeur ne rend `cmpxchg16b` qu'en mémoire")
        };
        let at = self.effective_address(&address, self.after(instruction));
        let high_at = at.wrapping_add(8);
        let fault = |cpu: &mut Cpu| {
            cpu.faulted = true;
            cpu.jumped = true;
        };
        let (Ok(low), Ok(high)) = (
            self.read_memory(at, Width::Qword),
            self.read_memory(high_at, Width::Qword),
        ) else {
            fault(self);
            return;
        };
        let equal = low == self.regs[0] && high == self.regs[2];
        if equal {
            let (rbx, rcx) = (self.regs[3], self.regs[1]);
            if self.write_memory(at, Width::Qword, rbx).is_err() {
                fault(self);
                return;
            }
            if self.write_memory(high_at, Width::Qword, rcx).is_err() {
                let _ = self.write_memory(at, Width::Qword, low);
                fault(self);
                return;
            }
        } else {
            self.regs[0] = low;
            self.regs[2] = high;
        }
        let now = self.flags.read();
        self.flags.write((now & !ZF) | if equal { ZF } else { 0 });
    }

    /// **Les multiplications, les divisions, les extensions de signe, et la
    /// retenue posée à la main.**
    ///
    /// Elles sont ensemble parce qu'elles partagent ce qui les sort de la
    /// machinerie ordinaire : leur destination n'est pas l'opérande qu'elles
    /// lisent. `mul` et `div` écrivent RDX **et** RAX ; `cqto` écrit RDX en
    /// lisant RAX ; `clc` n'écrit qu'un bit de RFLAGS.
    fn arithmetic_in_two_registers(&mut self, instruction: &Decoded) {
        let width = instruction.width;
        let mask = width.mask();
        let bits = width.bits();
        match instruction.op {
            Op::CarryFlag(action) => {
                let now = self.flags.read();
                let carry = match action {
                    CarryAction::Clear => 0,
                    CarryAction::Set => CF,
                    CarryAction::Complement => (now & CF) ^ CF,
                };
                self.flags.write((now & !CF) | carry);
            }
            // La source fait la demi-largeur, et c'est tout ce qui distingue
            // `cbtw` de `cltq` : le même opcode, trois tailles.
            Op::WidenAccumulator => {
                let half = instruction.src_width;
                let value = sign_extend(self.regs[0] & half.mask(), half);
                self.set(0, width, false, value);
            }
            // RDX ne reçoit pas le signe : il reçoit **tous les bits** du
            // signe. Y mettre 0 ou 1 rendrait un dividende faux de tout sauf
            // du bit de poids faible.
            Op::SignIntoData => {
                let negative = sign_extend(self.regs[0] & mask, width) >> 63 != 0;
                self.set(2, width, false, if negative { u64::MAX } else { 0 });
            }
            Op::WideMultiply { signed } => {
                let Some(operand) = self.read_destination(instruction) else {
                    self.faulted = true;
                    return;
                };
                let accumulator = self.get(0, width, false);
                let (low, high, overflowed) = if signed {
                    let left = sign_extend(accumulator, width) as i64 as i128;
                    let right = sign_extend(operand, width) as i64 as i128;
                    let product = left * right;
                    let low = product as u64 & mask;
                    // **Le débordement d'un produit signé n'est pas « le haut
                    // est non nul ».** Un produit négatif a un haut plein de
                    // uns et tient pourtant. Ce qui compte, c'est que le haut
                    // ne soit que la recopie du signe du bas.
                    let fits = sign_extend(low, width) as i64 as i128 == product;
                    (low, (product >> bits) as u64 & mask, !fits)
                } else {
                    let product = u128::from(accumulator) * u128::from(operand);
                    let high = (product >> bits) as u64 & mask;
                    (product as u64 & mask, high, high != 0)
                };
                // En octet le produit ne va pas dans RDX : il tient dans AX,
                // moitié basse dans AL et moitié haute dans **AH**.
                if width == Width::Byte {
                    self.set(0, Width::Byte, false, low);
                    self.set(0, Width::Byte, true, high);
                } else {
                    self.set(0, width, false, low);
                    self.set(2, width, false, high);
                }
                let now = self.flags.read();
                let raised = if overflowed { CF | OF } else { 0 };
                self.flags.write((now & !(CF | OF)) | raised);
            }
            Op::Multiply => {
                let Some(source) = self.read_source(instruction, width) else {
                    self.faulted = true;
                    return;
                };
                // À trois opérandes les deux facteurs sont `rm` et l'immédiat ;
                // à deux, c'est la destination et `rm`. La destination ne se
                // lit donc que dans le second cas.
                let (left, right) = if instruction.immediate {
                    (source, instruction.imm)
                } else {
                    (self.get(instruction.dst, width, false), source)
                };
                let product = sign_extend(left, width) as i64 as i128
                    * sign_extend(right, width) as i64 as i128;
                let low = product as u64 & mask;
                let fits = sign_extend(low, width) as i64 as i128 == product;
                self.set(instruction.dst, width, false, low);
                let now = self.flags.read();
                let raised = if fits { 0 } else { CF | OF };
                self.flags.write((now & !(CF | OF)) | raised);
            }
            _ => self.divide(
                instruction,
                matches!(instruction.op, Op::Divide { signed: true }),
            ),
        }
    }

    /// **La seule instruction arithmétique qui peut lever.**
    ///
    /// Deux façons : un diviseur nul, et un quotient qui ne tient pas dans la
    /// largeur — `0x8000 / -1` en seize bits, par exemple. Le processeur lève
    /// `#DE` dans les deux cas, et n'écrit **rien**. Les six drapeaux sont
    /// laissés indéfinis par le manuel, donc le corpus ne les compare pas ;
    /// seuls le quotient et le reste sont prouvés, ce qui est tout ce qui
    /// compte.
    fn divide(&mut self, instruction: &Decoded, signed: bool) {
        let width = instruction.width;
        let mask = width.mask();
        let bits = width.bits();
        let Some(divisor) = self.read_destination(instruction) else {
            self.faulted = true;
            return;
        };
        if divisor & mask == 0 {
            self.faulted = true;
            return;
        }
        // En octet le dividende est AX tout entier : sa moitié haute est AH,
        // elle vit dans RAX et pas dans RDX.
        let (low, high) = if width == Width::Byte {
            (self.regs[0] & 0xff, (self.regs[0] >> 8) & 0xff)
        } else {
            (self.get(0, width, false), self.get(2, width, false))
        };
        let whole = (u128::from(high) << bits) | u128::from(low);
        let (quotient, remainder) = if signed {
            // Le dividende fait **deux fois** la largeur, et c'est de là qu'il
            // faut étendre son signe : le prendre pour un nombre de la largeur
            // simple rendrait un quotient faux dès qu'il est négatif.
            let double = bits * 2;
            let dividend = if double == 128 {
                whole as i128
            } else {
                let sign = 1u128 << (double - 1);
                if whole & sign != 0 {
                    (whole | !(sign.wrapping_sub(1) | sign)) as i128
                } else {
                    whole as i128
                }
            };
            let by = sign_extend(divisor, width) as i64 as i128;
            let (Some(quotient), Some(remainder)) =
                (dividend.checked_div(by), dividend.checked_rem(by))
            else {
                self.faulted = true;
                return;
            };
            let limit = 1i128 << (bits - 1);
            if quotient < -limit || quotient >= limit {
                self.faulted = true;
                return;
            }
            (quotient as u64 & mask, remainder as u64 & mask)
        } else {
            let by = u128::from(divisor & mask);
            let quotient = whole / by;
            if quotient > u128::from(mask) {
                self.faulted = true;
                return;
            }
            (quotient as u64, (whole % by) as u64)
        };
        if width == Width::Byte {
            self.set(0, Width::Byte, false, quotient);
            self.set(0, Width::Byte, true, remainder);
        } else {
            self.set(0, width, false, quotient);
            self.set(2, width, false, remainder);
        }
    }

    fn push(&mut self, value: u64) {
        let top = self.regs[4].wrapping_sub(8);
        if self.write_memory(top, Width::Qword, value).is_err() {
            self.faulted = true;
            return;
        }
        self.regs[4] = top;
    }

    fn pop(&mut self) -> Option<u64> {
        let Ok(value) = self.read_memory(self.regs[4], Width::Qword) else {
            self.faulted = true;
            return None;
        };
        self.regs[4] = self.regs[4].wrapping_add(8);
        Some(value)
    }

    /// **Les instructions de chaîne : `movs` et `stos`.**
    ///
    /// C'est le `memcpy` et le `memset` d'un noyau, et c'est ce que la mesure
    /// désignait sans ambiguïté : 949 des 1 092 régions encore refusées depuis
    /// un vrai point d'entrée commençaient par `f3 48 a5` ou `f3 48 ab`.
    ///
    /// Quatre choses les distinguent de tout le reste :
    ///
    /// 1. **Le sens vient du drapeau de direction**, pas de l'instruction.
    ///    `std` fait reculer les deux pointeurs — c'est ce qui permet à un
    ///    `memmove` de copier vers l'arrière quand les zones se recouvrent.
    /// 2. **Le pas est la largeur**, pas un octet : `movsq` avance de huit.
    /// 3. **Avec `rep`, un compte nul ne fait rien du tout** — pas même une
    ///    itération. Tester après coup copierait un élément de trop, et c'est
    ///    exactement le défaut qu'on ne voit pas sur un compte de quatre.
    /// 4. **Un accès qui sort de la fenêtre arrête la boucle.** Sans ça, un
    ///    compte absurde tournerait jusqu'à ce que RCX s'épuise, ce qui n'est
    ///    pas une durée acceptable pour un cœur.
    fn string(&mut self, instruction: &Decoded) {
        let width = instruction.width;
        let size = width as u64;
        let step = if self.flags.read() & DF != 0 {
            size.wrapping_neg()
        } else {
            size
        };
        let (moves, repeat) = match instruction.op {
            Op::StringMove { repeat } => (true, repeat),
            Op::StringStore { repeat } => (false, repeat),
            _ => unreachable!("seules les deux chaînes arrivent ici"),
        };
        loop {
            if repeat && self.regs[1] == 0 {
                return;
            }
            let value = if moves {
                match self.read_memory(self.regs[6], width).ok() {
                    Some(value) => value,
                    None => {
                        self.faulted = true;
                        return;
                    }
                }
            } else {
                self.get(0, width, false)
            };
            if self.write_memory(self.regs[7], width, value).is_err() {
                self.faulted = true;
                return;
            }
            if moves {
                self.regs[6] = self.regs[6].wrapping_add(step);
            }
            self.regs[7] = self.regs[7].wrapping_add(step);
            if !repeat {
                return;
            }
            self.regs[1] = self.regs[1].wrapping_sub(1);
        }
    }

    /// **Un bit, lu dans la retenue et parfois changé.**
    ///
    /// Trois formes, et la troisième n'est pas une variante des deux autres :
    ///
    /// 1. **Destination registre.** Le numéro est réduit modulo la largeur.
    /// 2. **Destination mémoire, numéro immédiat.** Le numéro tient déjà dans
    ///    la largeur — le manuel le borne à 0..31 ou 0..63 — donc l'opérande
    ///    est celui que l'adresse nomme.
    /// 3. **Destination mémoire, numéro dans un registre : la chaîne de
    ///    bits.** Le numéro est **signé** et n'est pas replié. Le processeur
    ///    va chercher le mot qui contient ce bit-là, aussi loin soit-il, en
    ///    avant comme en arrière.
    ///
    /// La troisième forme n'est pas une curiosité de manuel : le noyau de
    /// Linux tient ses vecteurs d'interruption réservés dans un tableau de
    /// 256 bits qu'il lit comme ça. Un cœur qui replie tous les numéros dans
    /// le premier mot lui fait croire que l'horloge est déjà prise — ce défaut
    /// a coûté un démarrage entier, du côté Swift, et le commentaire y est
    /// encore.
    ///
    /// Seule la retenue est définie ; les cinq autres drapeaux ne sont pas
    /// touchés, ce que le masque du corpus ne compare pas mais qui est ce que
    /// fait le processeur.
    fn bit(&mut self, instruction: &Decoded, action: BitAction) {
        let width = instruction.width;
        let bits = width.bits();
        // **Le mot visé, quand ce n'est pas celui que l'adresse nomme.**
        // La division est arrondie **vers le bas** et non vers zéro : un numéro
        // négatif doit descendre d'un mot, pas remonter au mot zéro.
        // `div_euclid` et `rem_euclid` le disent exactement, et le reste rendu
        // est positif — ce qui est bien le rang du bit dans son mot.
        let (place, number) = match instruction.memory {
            Some(address) if !instruction.immediate => {
                let raw = self.regs[instruction.src as usize] as i64;
                let span = bits as i64;
                let after = self.after(instruction);
                let start = self.effective_address(&address, after);
                let word = raw.div_euclid(span).wrapping_mul(width as i64);
                (
                    Some(start.wrapping_add(word as u64)),
                    raw.rem_euclid(span) as u64,
                )
            }
            _ => {
                let raw = if instruction.immediate {
                    instruction.imm
                } else {
                    self.regs[instruction.src as usize]
                };
                (None, raw % bits)
            }
        };
        let value = match place {
            Some(at) => match self.read_memory(at, width).ok() {
                Some(value) => value,
                None => {
                    self.faulted = true;
                    return;
                }
            },
            None => match self.read_destination(instruction) {
                Some(value) => value,
                None => {
                    self.faulted = true;
                    return;
                }
            },
        };
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
        match place {
            Some(at) => {
                self.faulted |= self.write_memory(at, width, changed).is_err();
            }
            None => {
                self.faulted |= self.write_destination(instruction, changed).is_none();
            }
        }
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
        // **La source peut être un immédiat**, et ce n'était pas vrai jusqu'à
        // ce que `mov $1, %rdx` arrive : toutes les formes précédentes lisaient
        // un registre ou la mémoire. L'oublier lisait le registre zéro, ce qui
        // rend une valeur plausible à chaque fois — celle de RAX.
        let source = if instruction.immediate {
            instruction.imm & instruction.src_width.mask()
        } else {
            // La source se lit à **sa** largeur, qui n'est pas celle de
            // l'écriture, et l'accès mémoire éventuel doit porter la même.
            let Some(value) = self.read_source(instruction, instruction.src_width) else {
                self.faulted = true;
                return;
            };
            value
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
        // **Le drapeau de direction, et les chaînes qu'il oriente.** Ni l'un ni
        // les autres ne passent par la machinerie à une destination : `cld` ne
        // touche qu'un bit, et une chaîne écrit la mémoire, RDI, parfois RSI et
        // RCX — quatre endroits, dont aucun n'est `dst`.
        if let Op::DirectionFlag(set) = instruction.op {
            let now = self.flags.read();
            self.flags.write(if set { now | DF } else { now & !DF });
            return;
        }
        if matches!(
            instruction.op,
            Op::StringMove { .. } | Op::StringStore { .. }
        ) {
            self.string(instruction);
            return;
        }
        // **L'instruction indéfinie, avant tout le reste.** Elle ne calcule
        // rien, n'écrit rien, et n'avance pas : le processeur lève une
        // exception, et ce cœur pose une faute que l'hôte lira.
        if instruction.op == Op::Undefined {
            self.faulted = true;
            self.jumped = true;
            return;
        }
        // **Les registres de contrôle**, exécutés depuis la tranche de
        // pagination. Le champ `dst` porte le registre général : `0F 20` le
        // remplit, `0F 22` s'en remplit. La largeur est toujours de huit
        // octets, sans REX, et le numéro du registre de contrôle est déjà
        // validé par le décodeur — cinq numéros, pas seize.
        if let Op::ReadControlRegister { which } = instruction.op {
            self.regs[instruction.dst as usize] = self.control[which as usize];
            return;
        }
        if let Op::WriteControlRegister { which } = instruction.op {
            let value = self.regs[instruction.dst as usize];
            self.write_control_register(which, value);
            return;
        }
        // **Les entrées-sorties, que ce cœur-ci ne fait pas — et qui le
        // disent.** Le décodeur les lit depuis cette tranche, parce qu'un
        // noyau muet est indiscernable d'un noyau en panne. Les *exécuter*
        // demande des périphériques, et cet interpréteur n'en a pas : il pose
        // donc une faute, comme pour une instruction indéfinie.
        //
        // Ce n'est pas un oubli laissé en silence : sans ce bras, `in` et
        // `out` tomberaient dans le calcul arithmétique plus bas et
        // écriraient n'importe quoi dans l'accumulateur. Un refus nommé vaut
        // mieux qu'un résultat inventé.
        if matches!(
            instruction.op,
            Op::PortIn
                | Op::PortOut
                | Op::ReadTimestamp
                | Op::CpuId
                | Op::ReadModelRegister
                | Op::WriteModelRegister
                | Op::FarReturn
                | Op::InterruptReturn
                | Op::SoftwareInterrupt
                | Op::LoadDescriptorTable { .. }
                | Op::StoreDescriptorTable { .. }
                | Op::SwapGs
                | Op::LoadKernelGs
                | Op::HypervisorCall { .. }
                | Op::InvalidatePcid
                | Op::LoadTaskRegister
                | Op::LoadLocalDescriptorTable
                | Op::ReadDebugRegister { .. }
                | Op::WriteDebugRegister { .. }
                | Op::LoadSegment { .. }
                | Op::StoreSegment { .. }
                | Op::InterruptFlag(_)
                | Op::Halt
                | Op::PushFlags
                | Op::PopFlags
        ) {
            self.faulted = true;
            self.jumped = true;
            return;
        }
        if instruction.op == Op::Lea {
            if let Some(address) = instruction.memory {
                let after = self.after(instruction);
                // **`lea` ignore le préfixe de segment.** L'instruction ne
                // touche pas la mémoire, donc elle ne traverse pas l'unité de
                // segmentation : `leaq %gs:0x10, %rax` rend 0x10, pas
                // `gs_base + 0x10`. L'assembleur le dit à sa façon — il
                // avertit que le préfixe est « ineffectual » — et le corpus le
                // vérifie sur le silicium.
                let address = Address {
                    gs: false,
                    ..address
                };
                let value = self.effective_address(&address, after);
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

        // **Les sauts écrivent le pointeur d'instruction eux-mêmes.** Le
        // déplacement porte sur l'instruction **suivante**, donc la cible est
        // `rip + longueur + déplacement`. Aucun drapeau n'est touché — pas même
        // par `loop`, qui décrémente RCX sans rien poser, ce qui le distingue
        // d'un `dec` suivi d'un `jnz`.
        // **`invlpg` est un pas sans effet ici**, et c'est exact, pas une
        // paresse : cet interpréteur n'a pas de tampon de traduction, il
        // marche les tables à chaque accès. Il sort avant la machinerie des
        // opérandes, parce que son opérande est une adresse à ne pas lire.
        if matches!(instruction.op, Op::Nop | Op::InvalidatePage) {
            return;
        }
        if matches!(
            instruction.op,
            Op::Push | Op::Pop | Op::Call | Op::CallIndirect | Op::Return | Op::Leave
        ) {
            self.stack(instruction);
            return;
        }
        if matches!(
            instruction.op,
            Op::Exchange
                | Op::ExchangeAndAdd
                | Op::CompareAndExchange
                | Op::CompareAndExchangeSixteen
        ) {
            self.exchange(instruction);
            return;
        }
        // **Les six qui n'ont pas une destination mais deux, ou aucune.** La
        // machinerie à deux opérandes range un résultat là où elle a lu ; ces
        // instructions-là rangent RDX **et** RAX, ou ne rangent qu'un drapeau.
        if matches!(
            instruction.op,
            Op::WideMultiply { .. }
                | Op::Multiply
                | Op::Divide { .. }
                | Op::WidenAccumulator
                | Op::SignIntoData
                | Op::CarryFlag(_)
        ) {
            self.arithmetic_in_two_registers(instruction);
            return;
        }

        let after = self.rip.wrapping_add(instruction.length as u64);
        match instruction.op {
            Op::Jump(condition) => {
                let taken = condition.is_none_or(|c| c.holds(self.flags.read()));
                self.rip = if taken {
                    after.wrapping_add(instruction.imm)
                } else {
                    after
                };
                self.jumped = true;
                return;
            }
            Op::LoopWhile => {
                let count = self.regs[1].wrapping_sub(1);
                self.regs[1] = count;
                self.rip = if count != 0 {
                    after.wrapping_add(instruction.imm)
                } else {
                    after
                };
                self.jumped = true;
                return;
            }
            Op::JumpIndirect => {
                // La cible se lit là où l'opérande se trouve : un registre, ou
                // huit octets de mémoire. `read_destination` fait les deux, et
                // rend `None` quand l'accès sort de la fenêtre — auquel cas le
                // saut n'a pas lieu, plutôt que d'aller à zéro.
                let Some(target) = self.read_destination(instruction) else {
                    self.faulted = true;
                    return;
                };
                self.rip = target;
                self.jumped = true;
                return;
            }
            _ => {}
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
        if matches!(
            instruction.op,
            Op::Rol | Op::Ror | Op::RotateThroughCarry { .. }
        ) {
            self.rotate(instruction, left);
            return;
        }
        if let Op::DoubleShift { left: to_the_left } = instruction.op {
            self.double_shift(instruction, left, to_the_left);
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
            Op::Jump(_) | Op::LoopWhile | Op::JumpIndirect => {
                unreachable!("les sauts sortent avant")
            }
            Op::Nop | Op::InvalidatePage => unreachable!("ne rien faire sort avant"),
            Op::Undefined => unreachable!("l'instruction indéfinie sort avant"),
            Op::PortIn
            | Op::PortOut
            | Op::ReadTimestamp
            | Op::CpuId
            | Op::ReadModelRegister
            | Op::WriteModelRegister
            | Op::FarReturn
            | Op::InterruptReturn
            | Op::SoftwareInterrupt
            | Op::LoadDescriptorTable { .. }
            | Op::StoreDescriptorTable { .. }
            | Op::SwapGs
            | Op::LoadKernelGs
            | Op::HypervisorCall { .. }
            | Op::InvalidatePcid
            | Op::LoadTaskRegister
            | Op::LoadLocalDescriptorTable
            | Op::ReadDebugRegister { .. }
            | Op::WriteDebugRegister { .. }
            | Op::LoadSegment { .. }
            | Op::StoreSegment { .. }
            | Op::InterruptFlag(_)
            | Op::Halt
            | Op::PushFlags
            | Op::PopFlags => {
                unreachable!("les entrées-sorties et les instructions privilégiées sortent avant, avec une faute")
            }
            Op::ReadControlRegister { .. } | Op::WriteControlRegister { .. } => {
                unreachable!("les registres de contrôle sortent avant, exécutés")
            }
            Op::DirectionFlag(_) | Op::StringMove { .. } | Op::StringStore { .. } => {
                unreachable!("la direction et les chaînes sortent avant")
            }
            Op::Push | Op::Pop | Op::Call | Op::CallIndirect | Op::Return | Op::Leave => {
                unreachable!("la pile sort avant")
            }
            Op::WideMultiply { .. }
            | Op::Multiply
            | Op::Divide { .. }
            | Op::WidenAccumulator
            | Op::SignIntoData
            | Op::CarryFlag(_) => {
                unreachable!("les deux registres sortent avant")
            }
            Op::Exchange
            | Op::ExchangeAndAdd
            | Op::CompareAndExchange
            | Op::CompareAndExchangeSixteen => {
                unreachable!("les échanges sortent avant")
            }
            Op::RotateThroughCarry { .. } | Op::DoubleShift { .. } => {
                unreachable!("les rotations et décalages doubles sortent avant")
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
    /// Le préfixe 0x65 a été lu. Il ne concerne que l'opérande mémoire, s'il y
    /// en a un : sur une instruction sans accès mémoire il est légal et sans
    /// effet, et le processeur ne s'en plaint pas.
    segment_gs: bool,
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
/// **La largeur d'une entrée-sortie, qui ne suit pas tout à fait la règle
/// générale.** L'opcode pair porte un octet, l'impair la largeur des préfixes
/// — mais il n'existe pas d'entrée-sortie de soixante-quatre bits, et un
/// `REX.W` posé devant n'en crée pas une. Sans ce plafond, `48 ef` écrirait
/// huit octets sur un périphérique qui en attend quatre.
fn port_width(opcode: u8, prefixes: Prefixes) -> Width {
    if opcode % 2 == 0 {
        return Width::Byte;
    }
    match prefixes.width(false) {
        Width::Word => Width::Word,
        _ => Width::Dword,
    }
}

pub fn decode(bytes: &[u8]) -> Option<Decoded> {
    // **`f2` n'est pas un préfixe que ce décodeur lit — sauf devant `lkgs`.**
    // Le lire en général et l'oublier ensuite rendrait `movsd` (`f2 0f 10`)
    // comme un `movups` : une instruction plausible et fausse. Une seule forme
    // le porte ici, exactement, et tout autre `f2` reste refusé comme avant.
    if bytes.first() == Some(&0xf2) {
        return decode_load_kernel_gs(bytes);
    }
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
            // **Les quatre préfixes de segment que le mode 64 bits a vidés.**
            // CS, SS, DS et ES ont une base forcée à zéro : le processeur les
            // lit, les compte dans la longueur de l'instruction, et n'en fait
            // rien d'autre. Les refuser rejetait le NOP d'alignement du noyau
            // — `66 2e 0f 1f 84 00 …`, dix-huit mille occurrences dans un
            // noyau Alpine — et chaque branche marquée « pas prise ».
            //
            // Ils ne posent donc **pas** de segment sur l'adresse, à la
            // différence de 0x65 : porter « segment CS » jusqu'à l'exécution
            // demanderait une base que rien n'a, et zéro s'ajoute déjà tout
            // seul. La différence est vérifiée sur le silicium — les quatre
            // rendent exactement ce que l'instruction nue rend.
            0x2e | 0x36 | 0x3e | 0x26 => {
                prefixes.rex = None;
                at += 1;
            }
            // **Le préfixe de segment GS.** Comme les autres préfixes hérités,
            // il annule un REX déjà lu : le processeur veut REX collé à
            // l'opcode, et `65 48 8b …` est la seule forme qu'un assembleur
            // produit. Le sens du préfixe est porté par l'adresse, pas ici.
            0x65 => {
                prefixes.segment_gs = true;
                prefixes.rex = None;
                at += 1;
            }
            // **Le préfixe de verrouillage.** Il rend l'accès mémoire atomique
            // vis-à-vis des autres cœurs. Il n'y en a qu'un ici, donc il ne
            // change rien à ce que l'instruction calcule — mais le refuser
            // rejetait tout compteur atomique d'un noyau, et un noyau en est
            // plein. Le jour où wisq aura plusieurs fils d'exécution invités,
            // ce bras devra porter une vraie sémantique.
            0xf0 => {
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
            // **Les quatre instructions privilégiées d'un noyau, sans
            // opérande.** Deux octets, et c'est tout : aucun ModRM, aucun
            // immédiat. Les décoder ne les exécute pas — l'interpréteur faute
            // et l'émetteur refuse — mais un refus nommé se suit, là où un
            // `None` ne dit rien de ce qui manque.
            0x30 | 0x31 | 0x32 | 0xa2 => Some(Decoded {
                op: match second {
                    0x30 => Op::WriteModelRegister,
                    0x31 => Op::ReadTimestamp,
                    0x32 => Op::ReadModelRegister,
                    _ => Op::CpuId,
                },
                length: at,
                ..Decoded::nothing(Width::Dword)
            }),
            // **Le groupe des tables de descripteurs**, où le sens n'est pas
            // dans l'opcode mais dans les trois bits `reg` du ModRM. Quatre
            // formes à mémoire — `sgdt`, `sidt`, `lgdt`, `lidt` — et une
            // forme à registre, `swapgs`, qui est l'encodage `F8` **et lui
            // seul** : son voisin `F9` est `rdtscp` et n'a rien à voir.
            //
            // `invlpg` est `/7` en forme **mémoire**, lu depuis la tranche
            // qui a fait oublier une page au tampon ; `vmcall` et `vmmcall`
            // sont deux paires exactes de la forme à registre, lues depuis la
            // sonde d'hyperviseur du noyau. Le reste du groupe — `monitor`,
            // `vmlaunch`… — reste illisible exprès. Rendre `Some` pour un
            // opcode qu'on ne sait pas nommer transformerait un « je ne lis
            // pas » en « je lis, et je me trompe ».
            // **Les registres de débogage**, lus et écrits par leur numéro,
            // entre les deux opcodes des registres de contrôle. Le noyau
            // Alpine les efface dans `cpu_init`. Six numéros existent — 0 à
            // 3, 6, 7 — ; 4 et 5 sont des alias ou `#UD` selon CR4.DE, et
            // REX.R n'y désigne rien : rendre `Some` inventerait un registre.
            0x21 | 0x23 => {
                let field = read_modrm(bytes, &mut at, prefixes)?;
                field.memory.is_none().then_some(())?;
                let which = field.reg;
                matches!(which, 0..=3 | 6 | 7).then_some(())?;
                Some(Decoded {
                    op: if second == 0x21 {
                        Op::ReadDebugRegister { which }
                    } else {
                        Op::WriteDebugRegister { which }
                    },
                    dst: field.register,
                    length: at,
                    ..Decoded::nothing(Width::Qword)
                })
            }
            // **Les registres de contrôle**, lus et écrits par leur numéro.
            //
            // Cinq numéros existent ; les onze autres ne désignent rien, et
            // rendre `Some` pour eux inventerait un registre.
            0x20 | 0x22 => {
                let field = read_modrm(bytes, &mut at, prefixes)?;
                // Aucune forme mémoire : l'opérande est un registre général,
                // toujours. Un `mod` autre que 11 n'est pas quelque chose
                // qu'un compilateur écrit.
                field.memory.is_none().then_some(())?;
                // **REX.R compte ici**, à la différence des segments : c'est
                // lui qui distingue CR8 de CR0.
                let which = field.reg;
                matches!(which, 0 | 2 | 3 | 4 | 8).then_some(())?;
                Some(Decoded {
                    op: if second == 0x20 {
                        Op::ReadControlRegister { which }
                    } else {
                        Op::WriteControlRegister { which }
                    },
                    dst: field.register,
                    length: at,
                    ..Decoded::nothing(Width::Qword)
                })
            }
            0x01 => {
                let field = read_modrm(bytes, &mut at, prefixes)?;
                // `swapgs` se reconnaît à ses trois conditions ensemble : le
                // `reg` à sept, l'opérande **en registre** (donc pas de
                // mémoire), et le `rm` à zéro. En manquer une avale un
                // voisin.
                if field.memory.is_none() {
                    // **Trois paires exactes, et rien entre elles.** `swapgs`
                    // est `F8`, `vmcall` `C1`, `vmmcall` `D9` ; `C2` est
                    // `vmlaunch`, `D8` est `vmrun`, et les lire pour « reg=7 »
                    // ou « reg=0 » avalerait des voisins qui n'ont rien à voir.
                    let op = match (field.reg & 0b111, field.register) {
                        (7, 0) => Op::SwapGs,
                        (0, 1) => Op::HypervisorCall { amd: false },
                        (3, 1) => Op::HypervisorCall { amd: true },
                        _ => return None,
                    };
                    return Some(Decoded {
                        op,
                        length: at,
                        ..Decoded::nothing(Width::Qword)
                    });
                }
                let op = match field.reg & 0b111 {
                    0 => Op::StoreDescriptorTable { interrupts: false },
                    1 => Op::StoreDescriptorTable { interrupts: true },
                    2 => Op::LoadDescriptorTable { interrupts: false },
                    3 => Op::LoadDescriptorTable { interrupts: true },
                    7 => Op::InvalidatePage,
                    _ => return None,
                };
                Some(Decoded {
                    op,
                    length: at,
                    memory: field.memory,
                    ..Decoded::nothing(Width::Qword)
                })
            }
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
                    memory: field.memory,
                    memory_is_source: false,
                })
            }
            // Le même groupe, numéro en immédiat. Le champ `reg` porte alors
            // l'opération, pas un registre.
            0xba => {
                let width = prefixes.width(false);
                let field = read_modrm(bytes, &mut at, prefixes)?;
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
                    memory: field.memory,
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
            // **`ud2`.** Deux octets, aucun opérande. Refuser de la décoder
            // coupait une région à chaque `BUG()` d'un noyau — 4 077 dans
            // l'image Alpine mesurée, le plus gros refus restant.
            0x0b => Some(Decoded {
                op: Op::Undefined,
                length: at,
                ..Decoded::nothing(Width::Byte)
            }),
            // `nop` à plusieurs octets. L'assembleur s'en sert pour aligner
            // sans perdre de cycles : un seul `nop` long coûte moins que huit
            // courts. Il porte un ModRM entier, qu'il faut consommer.
            0x1f => {
                read_modrm(bytes, &mut at, prefixes)?;
                Some(Decoded {
                    op: Op::Nop,
                    length: at,
                    ..Decoded::nothing(Width::Qword)
                })
            }
            // **Les conseils au cache, et les `nop` réservés qui les
            // entourent.** `prefetchnta`, `prefetcht0`, `t1` et `t2`
            // désignent une adresse et n'en font rien : le manuel leur
            // interdit tout effet architectural, y compris la faute. Le
            // ModRM entier — SIB, déplacement, forme relative à RIP — se
            // consomme quand même, sinon RIP avancerait de trop peu et
            // l'instruction suivante se lirait au milieu d'une adresse.
            //
            // Le corpus matériel n'en juge que quatre formes, celles que
            // l'architecture nomme. Le reste de la plage — `0f 0d`, et
            // `0f 19` à `0f 1d` — est le `nop` réservé, que le manuel
            // décrit comme sans effet et dont les assembleurs se servent
            // pour aligner. Les accepter n'est pas une extrapolation
            // gratuite : **le cœur Swift les accepte déjà**, et un décodeur
            // plus sévère que son jumeau est une divergence entre les trois
            // cœurs, exactement le genre que la CI a déjà fait payer.
            0x0d | 0x18..=0x1d => {
                read_modrm(bytes, &mut at, prefixes)?;
                Some(Decoded {
                    op: Op::Nop,
                    length: at,
                    ..Decoded::nothing(Width::Qword)
                })
            }
            // **Les barrières mémoire**, trois formes d'un groupe qui en
            // compte huit. `lfence` (5), `mfence` (6) et `sfence` (7)
            // ordonnent des accès entre cœurs ; sur un cœur unique elles
            // n'ont rien à ordonner et se réduisent à trois octets qui ne
            // font rien.
            //
            // La distinction tient au mode, pas au numéro : `0f ae` avec un
            // opérande mémoire est `fxsave`, `fxrstor`, `ldmxcsr`,
            // `stmxcsr`, `clflush`, `xsave` ou `xrstor` selon `reg` — sept
            // instructions qui touchent l'état vectoriel, que ce cœur-ci ne
            // porte pas (il n'a ni XMM ni MXCSR ; c'est le cœur Swift qui
            // les tient). Avec un opérande registre, le même numéro de
            // `reg` veut dire une barrière. C'est `mod` qui tranche, et
            // tout ce qui n'est pas une des trois barrières se refuse.
            // **Le groupe 6, ouvert pour `ltr` et `lldt`, en forme à
            // registre.** Le noyau les écrit ainsi — `0f 00 d8`, `0f 00 d6` —
            // et pas autrement. `sldt`, `str`, `verr`, `verw` et la forme
            // mémoire restent illisibles : les lire pour « le groupe »
            // rendrait un nom faux pour quatre voisines. `lkgs`, `/6` derrière
            // `f2`, a sa propre entrée avant le décodage des préfixes.
            0x00 => {
                let field = read_modrm(bytes, &mut at, prefixes)?;
                field.memory.is_none().then_some(())?;
                let op = match field.reg & 0b111 {
                    2 => Op::LoadLocalDescriptorTable,
                    3 => Op::LoadTaskRegister,
                    _ => return None,
                };
                Some(Decoded {
                    op,
                    dst: field.register,
                    length: at,
                    ..Decoded::nothing(Width::Word)
                })
            }
            // **La troisième page, `0F 38`, ouverte pour une seule
            // instruction.** `invpcid` est `66 0F 38 82 /r`, et le `66` n'y
            // est pas un préfixe de largeur : c'est un octet de l'opcode, qui
            // la distingue de ses voisines. Sans lui, `0F 38 82` n'est rien.
            // Le type de purge est dans `reg`, le descripteur en mémoire —
            // il n'existe pas de forme à registre, et `mod` à 11 se refuse.
            // `80` (`invept`) et `81` (`invvpid`) restent illisibles : ce
            // sont des instructions d'hyperviseur, que ce noyau n'atteint pas.
            0x38 => {
                if !prefixes.operand_size || prefixes.repeat || *bytes.get(at)? != 0x82 {
                    return None;
                }
                at += 1;
                let field = read_modrm(bytes, &mut at, prefixes)?;
                field.memory.is_some().then_some(())?;
                Some(Decoded {
                    op: Op::InvalidatePcid,
                    dst: field.reg,
                    length: at,
                    memory: field.memory,
                    ..Decoded::nothing(Width::Qword)
                })
            }
            // **`0f ae` porte deux jeux d'instructions sous les mêmes numéros,
            // et c'est `mod` qui tranche.** En registre, `/5`, `/6` et `/7`
            // sont les trois barrières. En mémoire, `/7` est `clflush` — et
            // `clflushopt` avec `66` — : vider une ligne de cache ne fait
            // rien sur cette machine, qui n'en a pas. Les autres formes
            // mémoire (`fxsave`, `ldmxcsr`, `xsave`…) écrivent ou lisent des
            // centaines d'octets et restent refusées. Aucune ne porte son
            // adresse : un conseil ne désigne rien à lire.
            0xae => {
                let field = read_modrm(bytes, &mut at, prefixes)?;
                let reg = field.reg & 0b111;
                let inert = match field.memory {
                    None => (5..=7).contains(&reg),
                    Some(_) => reg == 7 && !prefixes.repeat,
                };
                if !inert {
                    return None;
                }
                Some(Decoded {
                    op: Op::Nop,
                    length: at,
                    ..Decoded::nothing(Width::Qword)
                })
            }
            // Les sauts conditionnels à déplacement long, dont le noyau se
            // sert dès qu'une fonction dépasse cent vingt-sept octets.
            0x80..=0x8f => {
                let displacement = i64::from(read_i32(bytes, &mut at)?);
                Some(Decoded {
                    op: Op::Jump(Some(Condition(second & 0x0f))),
                    imm: displacement as u64,
                    length: at,
                    ..Decoded::nothing(prefixes.width(false))
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
            // **`endbr64`.** La cible de branchement indirect que le
            // processeur exige quand la protection de flot est armée. Elle ne
            // fait rien d'autre que marquer l'endroit — et un noyau moderne en
            // pose une **en tête de chaque fonction**. Vingt mille dans le
            // noyau Alpine mesuré : la refuser fermait une région sur deux.
            0x1e => {
                read_modrm(bytes, &mut at, prefixes)?;
                Some(Decoded {
                    op: Op::Nop,
                    length: at,
                    ..Decoded::nothing(Width::Qword)
                })
            }
            // **`shld` et `shrd`** : le décalage dont les bits entrants
            // viennent d'un second registre. Le compte est un immédiat (A4,
            // AC) ou `%cl` (A5, AD) — et contrairement au groupe 2, la
            // largeur n'a pas de forme d'octet : un décalage double d'un octet
            // n'existe pas.
            0xa4 | 0xa5 | 0xac | 0xad => {
                let width = prefixes.width(false);
                let field = read_modrm(bytes, &mut at, prefixes)?;
                let (reg, rm) = (field.reg, field.register);
                let count_is_cl = second == 0xa5 || second == 0xad;
                let imm = if count_is_cl {
                    0
                } else {
                    let byte = *bytes.get(at)?;
                    at += 1;
                    u64::from(byte)
                };
                Some(Decoded {
                    op: Op::DoubleShift {
                        left: second < 0xac,
                    },
                    width,
                    dst: rm,
                    src: reg,
                    imm,
                    immediate: !count_is_cl,
                    length: at,
                    count_is_cl,
                    src_width: width,
                    memory: field.memory,
                    ..Decoded::nothing(width)
                })
            }
            // **Les deux échanges qui font les verrous.** `cmpxchg` compare
            // l'accumulateur à la destination et n'écrit que si l'égalité
            // tient ; `xadd` additionne et rend l'ancienne valeur. Ce sont les
            // deux briques de tout compteur atomique d'un noyau.
            0xb0 | 0xb1 | 0xc0 | 0xc1 => {
                let width = prefixes.width(second == 0xb0 || second == 0xc0);
                let field = read_modrm(bytes, &mut at, prefixes)?;
                let (reg, rm) = (field.reg, field.register);
                Some(Decoded {
                    op: if second < 0xc0 {
                        Op::CompareAndExchange
                    } else {
                        Op::ExchangeAndAdd
                    },
                    width,
                    dst: prefixes.normalise_high(rm, width),
                    src: prefixes.normalise_high(reg, width),
                    length: at,
                    dst_high: field.memory.is_none() && prefixes.high_byte(rm, width),
                    src_high: prefixes.high_byte(reg, width),
                    src_width: width,
                    memory: field.memory,
                    ..Decoded::nothing(width)
                })
            }
            // **`cmpxchg16b`, le verrou à seize octets.** C'est `/1` du
            // groupe 9, en mémoire seulement, et avec REX.W seulement : sans
            // lui c'est `cmpxchg8b`, que rien n'exécute ici et qui reste
            // illisible plutôt que devinée. Le reste du groupe — `rdrand`,
            // `rdseed`, `xsaves` et les siens — n'est pas lu.
            0xc7 => {
                if prefixes.width(false) != Width::Qword {
                    return None;
                }
                let field = read_modrm(bytes, &mut at, prefixes)?;
                if field.reg & 7 != 1 || field.memory.is_none() {
                    return None;
                }
                Some(Decoded {
                    op: Op::CompareAndExchangeSixteen,
                    length: at,
                    memory: field.memory,
                    ..Decoded::nothing(Width::Qword)
                })
            }
            // **`imul` à deux opérandes** : `reg` fois `rm`, tronqué, rangé
            // dans `reg`. Contrairement à la forme à un opérande, elle n'écrit
            // qu'un registre — c'est celle que tout code émet quand il sait que
            // le produit tient.
            0xaf => {
                let width = prefixes.width(false);
                let field = read_modrm(bytes, &mut at, prefixes)?;
                Some(Decoded {
                    op: Op::Multiply,
                    width,
                    dst: field.reg,
                    src: field.register,
                    length: at,
                    src_width: width,
                    memory: field.memory,
                    memory_is_source: true,
                    ..Decoded::nothing(width)
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
        // **La pile.** En mode long, `push` et `pop` d'un registre font
        // toujours huit octets : il n'y a pas de forme de quatre, et le
        // préfixe 0x66 en ferait deux — que le corpus n'exerce pas et que le
        // décodeur refuse donc.
        0x50..=0x57 if !prefixes.operand_size => Some(Decoded {
            op: Op::Push,
            dst: (opcode & 0b111) | prefixes.rm_extension(),
            length: at,
            ..Decoded::nothing(Width::Qword)
        }),
        0x58..=0x5f if !prefixes.operand_size => Some(Decoded {
            op: Op::Pop,
            dst: (opcode & 0b111) | prefixes.rm_extension(),
            length: at,
            ..Decoded::nothing(Width::Qword)
        }),
        // `push` d'un immédiat, étendu en signe sur huit octets.
        0x68 | 0x6a => {
            let value = if opcode == 0x6a {
                let byte = *bytes.get(at)?;
                at += 1;
                i64::from(byte as i8)
            } else {
                i64::from(read_i32(bytes, &mut at)?)
            };
            Some(Decoded {
                op: Op::Push,
                imm: value as u64,
                immediate: true,
                length: at,
                ..Decoded::nothing(Width::Qword)
            })
        }
        0xe8 => {
            let displacement = i64::from(read_i32(bytes, &mut at)?);
            Some(Decoded {
                op: Op::Call,
                imm: displacement as u64,
                length: at,
                ..Decoded::nothing(Width::Qword)
            })
        }
        0xc3 => Some(Decoded {
            op: Op::Return,
            length: at,
            ..Decoded::nothing(Width::Qword)
        }),
        // **Le retour lointain**, avec ou sans `REX.W`. Le noyau écrit
        // `48 cb` ; `cb` seul existe aussi, et le décoder coûte cette ligne.
        0xcb => Some(Decoded {
            op: Op::FarReturn,
            length: at,
            ..Decoded::nothing(Width::Qword)
        }),
        // **Le retour d'interruption**, dont la largeur vient de REX.W : `48 cf`
        // est la forme du mode long, `cf` seul un `iretd` que l'émetteur
        // refuse en le nommant. Le décodeur lit les deux : un `cf` qui
        // passerait pour un octet inconnu poserait une autre question que
        // celle qu'il pose.
        0xcf => Some(Decoded {
            op: Op::InterruptReturn,
            length: at,
            ..Decoded::nothing(prefixes.width(false))
        }),
        // **Les deux extensions de signe, et la moitié qu'elles lisent.**
        // `0x98` étend l'accumulateur dans lui-même — AL dans AX, AX dans EAX,
        // EAX dans RAX — donc la source fait la **demi-largeur**. `0x99` étend
        // le signe de l'accumulateur dans RDX, et là les deux largeurs sont la
        // même. Sans la seconde, `idivq` n'a pas de moitié haute : tout
        // compilateur émet `cqto` juste avant.
        0x98 | 0x99 => {
            let width = prefixes.width(false);
            let half = match width {
                Width::Qword => Width::Dword,
                Width::Dword => Width::Word,
                _ => Width::Byte,
            };
            Some(Decoded {
                op: if opcode == 0x98 {
                    Op::WidenAccumulator
                } else {
                    Op::SignIntoData
                },
                length: at,
                src_width: if opcode == 0x98 { half } else { width },
                ..Decoded::nothing(width)
            })
        }
        // **Le drapeau de direction.** Deux opcodes d'un octet, et le seul
        // moyen de changer le sens des instructions de chaîne — donc le seul
        // moyen de le vérifier contre le silicium.
        0xfc | 0xfd => Some(Decoded {
            op: Op::DirectionFlag(opcode == 0xfd),
            length: at,
            ..Decoded::nothing(Width::Qword)
        }),
        // **Le drapeau d'interruption et l'arrêt**, trois opcodes d'un octet.
        // Ils vont ensemble parce qu'un noyau les écrit ensemble : `cli`,
        // `hlt`, et un saut qui revient sur le `cli`.
        0xfa | 0xfb => Some(Decoded {
            op: Op::InterruptFlag(opcode == 0xfb),
            length: at,
            ..Decoded::nothing(Width::Qword)
        }),
        0xf4 => Some(Decoded {
            op: Op::Halt,
            length: at,
            ..Decoded::nothing(Width::Qword)
        }),
        // **`int3` et `int n`.** Le vecteur va dans `imm` ; un `cd` dont
        // l'octet manque ne se décode pas, plutôt que de lui inventer un
        // vecteur.
        0xcc => Some(Decoded {
            op: Op::SoftwareInterrupt,
            imm: 3,
            immediate: true,
            length: at,
            ..Decoded::nothing(Width::Qword)
        }),
        0xcd => {
            let vector = *bytes.get(at)?;
            at += 1;
            Some(Decoded {
                op: Op::SoftwareInterrupt,
                imm: u64::from(vector),
                immediate: true,
                length: at,
                ..Decoded::nothing(Width::Qword)
            })
        }
        // **Les drapeaux par la pile.** La largeur ne vient pas de REX mais du
        // seul préfixe 0x66 : en mode 64 bits ces deux-là déplacent huit
        // octets par défaut, et `prefixes.width(false)` rendrait Dword sans
        // REX.W. La demander explicitement évite une taille de pile fausse de
        // moitié — le genre d'erreur qui ne se voit qu'au `popf` d'après.
        0x9c | 0x9d => Some(Decoded {
            op: if opcode == 0x9c {
                Op::PushFlags
            } else {
                Op::PopFlags
            },
            length: at,
            ..Decoded::nothing(if prefixes.operand_size {
                Width::Word
            } else {
                Width::Qword
            })
        }),
        // **Les chaînes.** `a4`/`a5` déplacent, `aa`/`ab` remplissent ; le bit
        // bas de l'opcode dit l'octet contre la largeur des préfixes. Le
        // préfixe 0xF3 en fait la forme répétée, et c'est celle-là que le
        // noyau met partout.
        0xa4 | 0xa5 | 0xaa | 0xab => {
            let width = prefixes.width(opcode & 1 == 0);
            let repeat = prefixes.repeat;
            Some(Decoded {
                op: if opcode < 0xaa {
                    Op::StringMove { repeat }
                } else {
                    Op::StringStore { repeat }
                },
                length: at,
                ..Decoded::nothing(width)
            })
        }
        // La retenue, posée à la main. Les cinq autres drapeaux ne bougent pas,
        // et c'est vérifiable : les états d'entrée du corpus en portent.
        0xf5 | 0xf8 | 0xf9 => Some(Decoded {
            op: Op::CarryFlag(match opcode {
                0xf5 => CarryAction::Complement,
                0xf8 => CarryAction::Clear,
                _ => CarryAction::Set,
            }),
            length: at,
            ..Decoded::nothing(Width::Qword)
        }),
        // **`imul` à trois opérandes** : le produit de `rm` par un immédiat,
        // rangé dans `reg`. C'est la seule multiplication dont les deux
        // facteurs sont ailleurs que dans la destination — `0x6b` porte
        // l'immédiat sur un octet étendu au signe, `0x69` sur quatre.
        0x69 | 0x6b => {
            let width = prefixes.width(false);
            let field = read_modrm(bytes, &mut at, prefixes)?;
            // `0x6b` porte un octet, `0x69` la forme longue — quatre octets,
            // deux seulement en seize bits. Les deux sont étendus au signe.
            let imm = read_immediate(bytes, &mut at, width, opcode == 0x6b)?;
            Some(Decoded {
                op: Op::Multiply,
                width,
                dst: field.reg,
                src: field.register,
                imm,
                immediate: true,
                length: at,
                src_width: width,
                memory: field.memory,
                memory_is_source: true,
                ..Decoded::nothing(width)
            })
        }
        0xc9 => Some(Decoded {
            op: Op::Leave,
            length: at,
            ..Decoded::nothing(Width::Qword)
        }),
        // `nop`, la forme courte. Avec un bit B de REX ce n'est plus un `nop`
        // mais `xchg %r8, %rax` — le même octet, deux instructions, et les
        // confondre échangerait deux registres au lieu de ne rien faire.
        0x90 if prefixes.rm_extension() == 0 => Some(Decoded {
            op: Op::Nop,
            length: at,
            ..Decoded::nothing(Width::Qword)
        }),
        // **`xchg rAX, r` — l'échange dont le registre tient dans l'opcode.**
        // Il vaut la peine d'être distingué de `0x87` : c'est un octet contre
        // deux, et un compilateur le choisit chaque fois qu'il le peut.
        //
        // Et il n'est **pas** un `nop` déguisé quand il désigne RAX : `0x90`
        // sans REX.B ne remet pas les trente-deux bits hauts à zéro, là où
        // `xchg %eax, %eax` écrit et les efface. C'est pourquoi la garde
        // ci-dessus le sort d'ici.
        0x90..=0x97 => {
            let width = prefixes.width(false);
            let register = (opcode - 0x90) | prefixes.rm_extension();
            Some(Decoded {
                op: Op::Exchange,
                width,
                dst: register,
                src: 0,
                length: at,
                src_width: width,
                ..Decoded::nothing(width)
            })
        }
        // `xchg r/m, r` sous sa forme longue.
        0x86 | 0x87 => {
            let width = prefixes.width(opcode == 0x86);
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let (reg, rm) = (field.reg, field.register);
            Some(Decoded {
                op: Op::Exchange,
                width,
                dst: prefixes.normalise_high(rm, width),
                src: prefixes.normalise_high(reg, width),
                length: at,
                dst_high: field.memory.is_none() && prefixes.high_byte(rm, width),
                src_high: prefixes.high_byte(reg, width),
                src_width: width,
                memory: field.memory,
                ..Decoded::nothing(width)
            })
        }
        // **Les sauts relatifs.** Le déplacement porte sur l'instruction
        // **suivante** : c'est `rip + longueur + déplacement`, et oublier la
        // longueur décale toutes les cibles de deux à six octets — un saut qui
        // atterrit dans le milieu d'une instruction.
        // **Les huit formes par lesquelles un invité parle au monde.**
        //
        // La largeur suit une règle simple et vaut d'être écrite plutôt que
        // relue huit fois : l'opcode **pair** transporte un octet, l'impair la
        // largeur des préfixes — mais bornée à quatre, parce qu'il n'existe pas
        // d'entrée-sortie de soixante-quatre bits. Un `REX.W` devant `out` ne
        // fait pas huit octets ; l'ignorer écrirait quatre octets de trop.
        0xe4..=0xe7 => {
            let port = u64::from(*bytes.get(at)?);
            at += 1;
            Some(Decoded {
                op: if opcode < 0xe6 {
                    Op::PortIn
                } else {
                    Op::PortOut
                },
                imm: port,
                // **`immediate` dit d'où vient le numéro de port.** Sans lui,
                // `out $0, %al` et `out %al, %dx` sont le même `Decoded` : tous
                // deux `imm: 0`. Un émetteur qui lit `imm` écrirait alors dans
                // le port zéro à chaque forme DX — la console d'un noyau est en
                // `0x3f8`, et l'invité se tairait sans rien signaler.
                immediate: true,
                length: at,
                ..Decoded::nothing(port_width(opcode, prefixes))
            })
        }
        0xec..=0xef => Some(Decoded {
            op: if opcode < 0xee {
                Op::PortIn
            } else {
                Op::PortOut
            },
            // Le port est dans DX : il n'y a pas d'immédiat, et c'est
            // `immediate` — laissé faux par `nothing` — qui le dit. Ce zéro
            // n'est pas un numéro de port, et rien ne doit le lire comme tel.
            imm: 0,
            length: at,
            ..Decoded::nothing(port_width(opcode, prefixes))
        }),
        0xeb => {
            let displacement = i64::from(*bytes.get(at)? as i8);
            at += 1;
            Some(Decoded {
                op: Op::Jump(None),
                imm: displacement as u64,
                length: at,
                ..Decoded::nothing(prefixes.width(false))
            })
        }
        0xe9 => {
            let displacement = i64::from(read_i32(bytes, &mut at)?);
            Some(Decoded {
                op: Op::Jump(None),
                imm: displacement as u64,
                length: at,
                ..Decoded::nothing(prefixes.width(false))
            })
        }
        0x70..=0x7f => {
            let displacement = i64::from(*bytes.get(at)? as i8);
            at += 1;
            Some(Decoded {
                op: Op::Jump(Some(Condition(opcode & 0x0f))),
                imm: displacement as u64,
                length: at,
                ..Decoded::nothing(prefixes.width(false))
            })
        }
        // `loop` : le compte est **toujours** RCX entier, quelle que soit la
        // largeur des préfixes, et il ne pose aucun drapeau.
        0xe2 => {
            let displacement = i64::from(*bytes.get(at)? as i8);
            at += 1;
            Some(Decoded {
                op: Op::LoopWhile,
                imm: displacement as u64,
                length: at,
                ..Decoded::nothing(prefixes.width(false))
            })
        }
        // `lea` : le seul opérande mémoire de cette tranche, et le seul qui ne
        // lise rien. Le mode registre est **invalide** pour cette instruction —
        // il n'y a pas d'adresse d'un registre — et l'assembleur ne le produit
        // pas ; le décodeur le refuse plutôt que d'inventer.
        // **Les sélecteurs de segment.** `8C` range, `8E` charge, et le champ
        // `reg` du ModRM dit lequel des six — masqué à trois bits, parce que
        // le processeur ignore REX.R pour un segment.
        0x8c | 0x8e => {
            let load = opcode == 0x8e;
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let segment = match field.reg & 0b111 {
                0 => Segment::Es,
                // Charger CS lève `#UD` : c'est le retour lointain qui change
                // de segment de code, pas un `mov`.
                1 if load => return None,
                1 => Segment::Cs,
                2 => Segment::Ss,
                3 => Segment::Ds,
                4 => Segment::Fs,
                5 => Segment::Gs,
                // Il n'y a que six segments.
                _ => return None,
            };
            // **La largeur a été mesurée sur un vrai processeur.** Elle n'est
            // pas la même dans les deux formes, et le décodeur enregistrait la
            // même pour les deux :
            //
            // | forme | RBX après, parti de `deadbeef11112222`, CS valant 0x33 |
            // | --- | --- |
            // | `8c cb` | `0000000000000033` — zéro-étendu |
            // | `66 8c cb` | `deadbeef11110033` — seize bits, le reste intact |
            //
            // Personne ne s'en plaignait parce que rien ne produisait
            // l'instruction. Le sélecteur lui-même fait toujours seize bits :
            // ce qui change est ce qu'il advient du reste du registre.
            let width = if prefixes.operand_size {
                Width::Word
            } else {
                Width::Qword
            };
            Some(Decoded {
                op: if load {
                    Op::LoadSegment { segment }
                } else {
                    Op::StoreSegment { segment }
                },
                dst: field.register,
                length: at,
                memory: field.memory,
                ..Decoded::nothing(width)
            })
        }
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
        // **`mov` avec un immédiat**, sous ses trois formes. C'est l'une des
        // instructions les plus fréquentes d'un noyau, et elle manquait.
        //
        // La forme longue vers un registre est la seule de tout le jeu à porter
        // un immédiat de **huit** octets, et seulement avec REX.W : c'est
        // `movabs`. Les autres immédiats font au plus quatre octets étendus en
        // signe, et traiter celui-ci comme eux tronquerait toute adresse au
        // delà de quatre gigaoctets — c'est-à-dire toutes celles d'un noyau.
        0xb0..=0xbf => {
            let byte_form = opcode < 0xb8;
            let width = prefixes.width(byte_form);
            let register = (opcode & 0b111) | prefixes.rm_extension();
            let imm = if width == Width::Qword {
                let slice = bytes.get(at..at + 8)?;
                at += 8;
                u64::from_le_bytes(slice.try_into().ok()?)
            } else {
                // Ici l'immédiat n'est **pas** étendu en signe : il remplit
                // exactement la largeur, et le reste vient de la règle
                // d'écriture.
                let size = width as usize;
                let slice = bytes.get(at..at + size)?;
                at += size;
                let mut value = 0u64;
                for (rank, byte) in slice.iter().enumerate() {
                    value |= u64::from(*byte) << (rank * 8);
                }
                value
            };
            Some(Decoded {
                op: Op::Mov,
                width,
                dst: prefixes.normalise_high(register, width),
                imm,
                immediate: true,
                length: at,
                dst_high: prefixes.high_byte(register, width),
                ..Decoded::nothing(width)
            })
        }
        // Groupe 11 : `mov` d'un immédiat vers un registre **ou la mémoire**.
        // Le champ `reg` du ModRM doit valoir zéro ; les autres valeurs sont
        // des encodages que cette tranche ne connaît pas.
        0xc6 | 0xc7 => {
            let width = prefixes.width(opcode == 0xc6);
            let field = read_modrm(bytes, &mut at, prefixes)?;
            if field.reg & 0b111 != 0 {
                return None;
            }
            let imm = read_immediate(bytes, &mut at, width, false)?;
            Some(Decoded {
                op: Op::Mov,
                width,
                dst: prefixes.normalise_high(field.register, width),
                imm,
                immediate: true,
                length: at,
                dst_high: field.memory.is_none() && prefixes.high_byte(field.register, width),
                memory: field.memory,
                ..Decoded::nothing(width)
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
        // Groupe 3 : `test`, `not`, `neg`, et les multiplications et divisions
        // à un opérande — les quatre seules instructions du jeu qui écrivent
        // **deux** registres.
        0xf6 | 0xf7 => {
            let width = prefixes.width(opcode == 0xf6);
            let field = read_modrm(bytes, &mut at, prefixes)?;
            let (reg, rm) = (field.reg, field.register);
            let op = match reg & 0b111 {
                0 | 1 => Op::Test,
                2 => Op::Not,
                3 => Op::Neg,
                4 => Op::WideMultiply { signed: false },
                5 => Op::WideMultiply { signed: true },
                6 => Op::Divide { signed: false },
                7 => Op::Divide { signed: true },
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
                // pour un quadruple mot. Ça ne tient pas dans un registre de la
                // machine hôte, et les traduire comme une rotation simple
                // serait faux en silence — donc elles ont leur propre bras.
                2 => Op::RotateThroughCarry { left: true },
                _ => Op::RotateThroughCarry { left: false },
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
                // **Le groupe 5 par une valeur, et non par un déplacement.**
                // `/2` appelle, `/4` saute, `/6` empile — et la valeur vient
                // d'un registre ou de la mémoire, indifféremment. C'est ainsi
                // qu'un noyau appelle par pointeur de fonction et saute par
                // table, ce qui en fait la forme dominante et non l'exception.
                //
                // **Huit octets, toujours, et sans REX.** En mode 64 bits ces
                // trois formes ont une taille d'opérande forcée : les traiter
                // en trente-deux bits tronquerait chaque pointeur à sa moitié
                // basse, ce qui donne une adresse dans la page zéro plutôt
                // qu'une faute franche.
                2 | 4 | 6 if opcode == 0xff => {
                    return Some(Decoded {
                        op: match reg & 0b111 {
                            2 => Op::CallIndirect,
                            4 => Op::JumpIndirect,
                            _ => Op::Push,
                        },
                        dst: rm,
                        length: at,
                        memory: field.memory,
                        ..Decoded::nothing(Width::Qword)
                    })
                }
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
        gs: prefixes.segment_gs,
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
        // **Relatif au pointeur d'instruction.** Le décodeur ne peut pas
        // résoudre l'adresse ici : la longueur de l'instruction n'est pas
        // encore connue — un immédiat peut suivre le déplacement — et c'est
        // depuis sa **fin** que le déplacement se compte. Le mode est donc
        // porté jusqu'à l'exécution, où RIP et la longueur sont là.
        address.relative = true;
        address.displacement = i64::from(read_i32(bytes, at)?);
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
/// **`f2 0f 00 /6`, forme à registre, et rien d'autre.** Le sélecteur vient
/// du registre `rm` ; la forme mémoire et un REX intercalé ne sont pas lus —
/// le noyau n'écrit ni l'une ni l'autre, et les lire serait deviner.
fn decode_load_kernel_gs(bytes: &[u8]) -> Option<Decoded> {
    if bytes.get(1..3)? != [0x0f, 0x00] {
        return None;
    }
    let modrm = *bytes.get(3)?;
    if modrm >> 6 != 0b11 || (modrm >> 3) & 0b111 != 6 {
        return None;
    }
    Some(Decoded {
        op: Op::LoadKernelGs,
        dst: modrm & 0b111,
        length: 4,
        ..Decoded::nothing(Width::Dword)
    })
}

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
                self.jumped = false;
                self.execute(&instruction);
                // **Ne pas avancer par-dessus un saut qu'on vient de prendre.**
                // Sans ce témoin, le cœur exécuterait l'instruction d'après la
                // cible au lieu de la cible.
                if !self.jumped {
                    self.rip = self.rip.wrapping_add(instruction.length as u64);
                }
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

    /// **La division qui lève, et ce que le corpus ne peut pas en dire.**
    ///
    /// `division_state`, dans le constructeur du corpus, écarte d'avance tout
    /// état où le processeur lèverait `#DE` — il le doit, sinon le binaire
    /// oracle mourrait au lieu de rendre un verdict. Les deux fautes de la
    /// division ne sont donc éprouvées par aucun des 10 524 cas, et un sabotage
    /// l'a montré : retirer la garde du diviseur nul faisait paniquer
    /// l'interpréteur en débogage et rendre n'importe quoi en production, sans
    /// qu'aucun cas ne tombe.
    ///
    /// Ce que le processeur fait d'un `#DE` : il n'écrit **rien**. Ni quotient,
    /// ni reste, ni drapeau.
    #[test]
    fn a_division_that_would_raise_writes_nothing() {
        // `divq %rcx`
        let divide = decode(&[0x48, 0xf7, 0xf1]).expect("divq %rcx se décode");
        for (name, rax, rdx, rcx) in [
            ("un diviseur nul", 100u64, 0u64, 0u64),
            // 2^64 divisé par un : le quotient ne tient pas dans la largeur.
            ("un quotient qui déborde", 0, 1, 1),
        ] {
            let mut cpu = Cpu::default();
            cpu.regs[0] = rax;
            cpu.regs[1] = rcx;
            cpu.regs[2] = rdx;
            cpu.execute(&divide);
            assert!(cpu.faulted, "{name} devait lever");
            assert_eq!(cpu.regs[0], rax, "{name} : RAX ne devait pas bouger");
            assert_eq!(cpu.regs[2], rdx, "{name} : RDX ne devait pas bouger");
        }
        // **Et le débordement signé, qui n'est pas le même que le non signé.**
        // Un sabotage l'a montré : ne garder que la garde non signée laissait
        // passer `idivw` sur un quotient de 32 768 — un de trop pour seize bits
        // signés, et pourtant très en dessous du plafond non signé.
        let narrow = decode(&[0x66, 0xf7, 0xf9]).expect("idivw %cx se décode");
        for (name, ax, dx, cx) in [
            ("un quotient signé d'un de trop", 0u64, 1u64, 2u64),
            // Et le minimum divisé par -1, le seul débordement que la division
            // elle-même refuserait de calculer.
            ("le minimum divisé par -1", 0, 0xffff, 0xffff),
        ] {
            let mut cpu = Cpu::default();
            cpu.regs[0] = ax;
            cpu.regs[1] = cx;
            cpu.regs[2] = dx;
            cpu.execute(&narrow);
            assert!(cpu.faulted, "{name} devait lever");
            assert_eq!(cpu.regs[0], ax, "{name} : RAX ne devait pas bouger");
            assert_eq!(cpu.regs[2], dx, "{name} : RDX ne devait pas bouger");
        }

        // Et le témoin : une division ordinaire écrit, elle.
        let mut cpu = Cpu::default();
        cpu.regs[0] = 100;
        cpu.regs[1] = 7;
        cpu.execute(&divide);
        assert!(!cpu.faulted, "100 / 7 ne lève pas");
        assert_eq!((cpu.regs[0], cpu.regs[2]), (14, 2));
    }

    /// **Un vrai dividende de deux registres**, que le corpus ne produit jamais.
    ///
    /// `division_state` met toujours la moitié haute à la banale — zéro, ou le
    /// signe du bas — pour que le quotient tienne à coup sûr. Le dividende y
    /// vaut donc toujours ce que la moitié basse dit toute seule, et un
    /// sabotage l'a montré : étendre le signe depuis la largeur simple au lieu
    /// de la double ne faisait tomber aucun cas, parce que les deux calculs
    /// tombent d'accord sur ces états-là.
    ///
    /// C'est pourtant la forme qu'un noyau emploie le plus : `do_div` divise
    /// soixante-quatre bits par trente-deux, et la moitié haute y porte de
    /// l'information.
    #[test]
    fn a_dividend_that_really_spans_two_registers() {
        let unsigned = decode(&[0xf7, 0xf1]).expect("divl %ecx se décode");
        let signed = decode(&[0xf7, 0xf9]).expect("idivl %ecx se décode");
        // 2^32 divisé par trois. La moitié basse seule dirait « zéro ».
        let mut cpu = Cpu::default();
        cpu.regs[2] = 1;
        cpu.regs[0] = 0;
        cpu.regs[1] = 3;
        cpu.execute(&unsigned);
        assert!(!cpu.faulted);
        assert_eq!((cpu.regs[0], cpu.regs[2]), (0x5555_5555, 1));
        // Et le même, signé et négatif : -2^32 divisé par trois fait
        // -1 431 655 765, reste -1. Le quotient tronque **vers zéro**.
        let mut cpu = Cpu::default();
        cpu.regs[2] = 0xffff_ffff;
        cpu.regs[0] = 0;
        cpu.regs[1] = 3;
        cpu.execute(&signed);
        assert!(!cpu.faulted);
        assert_eq!(
            (cpu.regs[0] as u32 as i32, cpu.regs[2] as u32 as i32),
            (-1_431_655_765, -1)
        );
    }

    /// **Les huit opcodes par lesquels un noyau parle, et que rien ne décodait.**
    ///
    /// Un noyau Linux écrit sur sa console dans ses premières centaines
    /// d'instructions, et il le fait par `out` sur le port 0x3F8. Le décodeur
    /// ne connaissait aucune des huit formes : `decode` rendait `None`, donc
    /// l'émetteur refusait la région, donc un vrai noyau lancé par le bureau
    /// s'arrêtait **avant d'avoir rien dit** — et le silence est indiscernable
    /// d'une panne. C'est la leçon que l'arbre de périphériques mal aligné a
    /// déjà donnée à ce dépôt : le seul symptôme était l'absence de symptôme.
    ///
    /// Les huit, avec ce qui les distingue : le port vient d'un octet immédiat
    /// ou de DX, la largeur vient de l'opcode pair ou impair — un octet pour
    /// le pair, la largeur des préfixes pour l'impair — et le sens vient de
    /// `E4/E5/EC/ED` contre `E6/E7/EE/EF`.
    #[test]
    fn the_eight_shapes_a_kernel_speaks_through_are_decoded() {
        for (bytes, op, width, port, length) in [
            (
                &[0xe4, 0x60][..],
                Op::PortIn,
                Width::Byte,
                Some(0x60u16),
                2usize,
            ),
            (&[0xe5, 0x60][..], Op::PortIn, Width::Dword, Some(0x60), 2),
            (&[0xe6, 0x80][..], Op::PortOut, Width::Byte, Some(0x80), 2),
            (&[0xe7, 0x80][..], Op::PortOut, Width::Dword, Some(0x80), 2),
            (&[0xec][..], Op::PortIn, Width::Byte, None, 1),
            (&[0xed][..], Op::PortIn, Width::Dword, None, 1),
            (&[0xee][..], Op::PortOut, Width::Byte, None, 1),
            (&[0xef][..], Op::PortOut, Width::Dword, None, 1),
        ] {
            let step = decode(bytes).unwrap_or_else(|| {
                panic!("{bytes:02x?} doit se décoder : sans lui un noyau est muet")
            });
            assert_eq!(step.op, op, "{bytes:02x?} : le sens");
            assert_eq!(step.width, width, "{bytes:02x?} : la largeur");
            assert_eq!(step.length, length, "{bytes:02x?} : la longueur lue");
            match port {
                // Le port immédiat voyage dans `imm`, comme tout immédiat.
                Some(number) => assert_eq!(step.imm, u64::from(number), "{bytes:02x?} : le port"),
                // Et sans immédiat, c'est DX — que le décodeur ne nomme pas
                // ici : l'exécutant le sait de l'opcode.
                None => assert_eq!(step.imm, 0, "{bytes:02x?} : pas d'immédiat"),
            }
        }
    }

    /// **La largeur de seize bits, qui n'est pas un détail.** `out %ax, %dx`
    /// s'écrit avec le préfixe 0x66, et un noyau s'en sert pour les registres
    /// de seize bits des contrôleurs. La confondre avec quatre octets écrirait
    /// deux octets de trop sur un périphérique.
    #[test]
    fn the_sixteen_bit_port_width_comes_from_the_prefix() {
        let step = decode(&[0x66, 0xef]).expect("out %ax, %dx se décode");
        assert_eq!(step.op, Op::PortOut);
        assert_eq!(
            step.width,
            Width::Word,
            "le préfixe 0x66 fait seize bits, pas trente-deux"
        );
        assert_eq!(step.length, 2);
    }

    /// **Port zéro et « le port est dans DX » ne doivent pas se ressembler.**
    ///
    /// `out $0, %al` et `out %al, %dx` rendaient tous deux `imm: 0`, et le
    /// commentaire du décodeur affirmait que « l'exécutant le sait de
    /// l'opcode » — sauf que `Decoded` ne porte pas l'opcode. Un émetteur qui
    /// lit `imm` écrirait donc dans le port zéro à chaque `out %al, %dx`, ce
    /// qui est le comportement *presque* juste que ce fichier refuse partout
    /// ailleurs : la console d'un noyau est en `0x3f8`, jamais en zéro, et
    /// l'invité se tairait sans rien signaler.
    ///
    /// `immediate` porte déjà exactement cette question pour tout le reste du
    /// jeu d'instructions ; il la porte maintenant pour les entrées-sorties.
    #[test]
    fn port_zero_is_not_the_same_shape_as_the_port_in_dx() {
        let immediate = decode(&[0xe6, 0x00]).expect("out $0, %al se décode");
        assert_eq!(immediate.op, Op::PortOut);
        assert_eq!(immediate.imm, 0);
        assert!(immediate.immediate, "le numéro de port est l'immédiat");

        let from_dx = decode(&[0xee]).expect("out %al, %dx se décode");
        assert_eq!(from_dx.op, Op::PortOut);
        assert!(
            !from_dx.immediate,
            "le numéro de port est dans DX, pas dans l'immédiat"
        );

        // Et la même distinction du côté lecture.
        let read_immediate = decode(&[0xe4, 0x00]).expect("in $0, %al se décode");
        assert!(read_immediate.immediate);
        let read_from_dx = decode(&[0xec]).expect("in %al, %dx se décode");
        assert!(!read_from_dx.immediate);
    }

    /// **Les quatre instructions privilégiées sur lesquelles un noyau bute.**
    ///
    /// Mesuré sur un vrai noyau Linux 6.6 x86-64, extrait de son bzImage : le
    /// point d'entrée en exécute sept, et la huitième est `wrmsr`. Le décodeur
    /// rendait `None`, donc l'émetteur rendait `CannotDecode` — un refus qui ne
    /// nomme rien et qu'on ne peut pas suivre.
    ///
    /// Aucune des quatre ne porte d'opérande : deux octets, et c'est tout. Ce
    /// que le test tient est donc la longueur autant que le nom — une forme
    /// décodée à trois octets décalerait tout ce qui suit.
    #[test]
    fn the_four_privileged_instructions_a_kernel_reaches_first_are_decoded() {
        for (bytes, op) in [
            (&[0x0f, 0x31][..], Op::ReadTimestamp),
            (&[0x0f, 0xa2][..], Op::CpuId),
            (&[0x0f, 0x32][..], Op::ReadModelRegister),
            (&[0x0f, 0x30][..], Op::WriteModelRegister),
        ] {
            let step = decode(bytes).unwrap_or_else(|| panic!("{bytes:02x?} se décode"));
            assert_eq!(step.op, op, "pour {bytes:02x?}");
            assert_eq!(
                step.length, 2,
                "deux octets, pas d'opérande, pour {bytes:02x?}"
            );
        }
    }

    /// **Le groupe `0f 01`, démêlé par le champ `reg` de son ModRM.**
    ///
    /// Cinq formes que le noyau écrit, et un même opcode. `lgdt` et `lidt`
    /// chargent les tables de descripteurs — global et d'interruptions — depuis
    /// la mémoire ; `sgdt` et `sidt` les y rangent ; `swapgs` échange la base de
    /// GS avec celle du noyau, et c'est la première chose que fait un
    /// gestionnaire d'interruption.
    ///
    /// **Le sens vient du ModRM, pas de l'opcode.** `0f 01 15` est un `lgdt` et
    /// `0f 01 1d` un `lidt` : trois bits d'écart. Avaler tout le groupe sous un
    /// seul nom rendrait « je sais lire » là où on ne saurait pas quoi faire.
    #[test]
    fn the_descriptor_table_group_is_untangled_by_its_modrm() {
        // mod=00, rm=101 : un déplacement relatif à RIP, la forme qu'un noyau
        // écrit. Seuls les trois bits du milieu changent.
        for (reg, op) in [
            (0u8, Op::StoreDescriptorTable { interrupts: false }),
            (1, Op::StoreDescriptorTable { interrupts: true }),
            (2, Op::LoadDescriptorTable { interrupts: false }),
            (3, Op::LoadDescriptorTable { interrupts: true }),
        ] {
            let modrm = (reg << 3) | 0b101;
            let bytes = [0x0f, 0x01, modrm, 0x00, 0x00, 0x00, 0x00];
            let step = decode(&bytes).unwrap_or_else(|| panic!("reg={reg} se décode"));
            assert_eq!(step.op, op, "pour reg={reg}");
            assert_eq!(
                step.length, 7,
                "deux d'opcode, un de ModRM, quatre de déplacement"
            );
            assert!(step.memory.is_some(), "ces quatre-là portent une adresse");
        }
    }

    /// **`swapgs` est une forme, pas le groupe entier.**
    ///
    /// `0f 01 f8` seul est `swapgs` : `reg=7` **et** `rm=0` **et** un opérande
    /// registre. `0f 01 f9` est `rdtscp`, une instruction sans rapport, et
    /// `0f 01 c1` est `vmcall` — lu depuis la tranche de la sonde
    /// d'hyperviseur, et comme une autre instruction. Décoder « tout ce qui a
    /// reg=7 » les confondrait — un noyau qui appelle `rdtscp` verrait GS
    /// échangé.
    #[test]
    fn swapgs_is_one_encoding_and_not_a_whole_corner_of_the_group() {
        let step = decode(&[0x0f, 0x01, 0xf8]).expect("swapgs se décode");
        assert_eq!(step.op, Op::SwapGs);
        assert_eq!(step.length, 3);
        assert!(step.memory.is_none(), "swapgs ne touche pas la mémoire");

        for voisin in [0xf9u8, 0xc2, 0xd0] {
            assert!(
                decode(&[0x0f, 0x01, voisin]).is_none(),
                "0f 01 {voisin:02x} n'est pas swapgs et ne doit pas se décoder comme tel"
            );
        }
        // `c1` est `vmcall` depuis la tranche de la sonde d'hyperviseur : il
        // se décode, et surtout pas en `swapgs`.
        assert_eq!(
            decode(&[0x0f, 0x01, 0xc1]).map(|step| step.op),
            Some(Op::HypervisorCall { amd: false }),
            "0f 01 c1 est vmcall, pas swapgs"
        );
    }

    /// **`lkgs` se lit, et le reste de la page `f2` reste refusé.**
    ///
    /// `f2 0f 00 /6` charge la base GS du noyau depuis un sélecteur — l'arrivée
    /// de FRED. Le noyau Alpine la porte dans `native_lkgs`, à 1572 octets de
    /// `init_scattered_cpuid_features`, et ne l'exécute que si CPUID annonce
    /// `LKGS` ; mais elle est atteinte statiquement, et un décodeur qui ne la
    /// lit pas refusait la région entière. C'est l'`int3` de la retpoline, à
    /// l'identique.
    ///
    /// **Le préfixe `f2` n'est pas lu en général**, exprès : `f2 0f 10` est
    /// `movsd`, et un `f2` avalé sans être compris rendrait `movups` — une
    /// instruction plausible et fausse. Seule cette forme le lit, et les
    /// voisins qui étaient refusés le restent.
    #[test]
    fn lkgs_is_read_and_the_rest_of_the_f2_page_stays_refused() {
        let step = decode(&[0xf2, 0x0f, 0x00, 0xf7]).expect("lkgs %edi se décode");
        assert_eq!(step.op, Op::LoadKernelGs);
        assert_eq!(step.length, 4, "préfixe, deux d'opcode, un de ModRM");
        assert_eq!(step.dst, 7, "le sélecteur vient d'EDI");
        assert!(
            step.memory.is_none(),
            "la forme à registre ne touche pas la mémoire"
        );
        let eax = decode(&[0xf2, 0x0f, 0x00, 0xf0]).expect("lkgs %eax se décode");
        assert_eq!((eax.op, eax.dst), (Op::LoadKernelGs, 0));

        for (bytes, why) in [
            (
                &[0x0f, 0x00, 0xf7][..],
                "sans f2, /6 du groupe 6 n'est rien",
            ),
            (&[0xf2, 0x0f, 0x00, 0xff][..], "reg=7 n'est pas lkgs"),
            (
                &[0xf2, 0x0f, 0x00, 0x37][..],
                "la forme mémoire n'est pas lue",
            ),
            (
                &[0xf2, 0x0f, 0x01, 0xf8][..],
                "f2 n'ouvre pas le reste de la page",
            ),
            (
                &[0xf2, 0x0f, 0x10, 0xc1][..],
                "movsd reste refusé, pas avalé en movups",
            ),
            (
                &[0xf2, 0x48, 0x0f, 0x00, 0xf7][..],
                "un REX entre les deux n'est pas lu",
            ),
        ] {
            assert!(decode(bytes).is_none(), "{why} : {bytes:02x?}");
        }

        // **Refusée par nom dans l'interpréteur**, RIP dessus : il n'a pas de
        // table de descripteurs pour en lire une base, et le dire vaut mieux
        // que poser une base inventée.
        let mut cpu = Cpu {
            rip: 0x3000_0000,
            ..Default::default()
        };
        cpu.step(&[0xf2, 0x0f, 0x00, 0xf7]);
        assert!(cpu.faulted, "lkgs est une faute nommée pour l'interpréteur");
        assert_eq!(
            cpu.rip, 0x3000_0000,
            "et le pointeur d'instruction reste dessus"
        );
    }

    /// **`invlpg` se lit dans sa forme mémoire, et dans elle seule.**
    ///
    /// `0f 01 /7` avec un opérande en mémoire est `invlpg` : oublier la
    /// traduction d'une page. Le noyau Alpine l'exécute dans
    /// `native_flush_tlb_one_user` — `0f 01 3f`, `invlpg (%rdi)` — et un
    /// décodeur qui ne la lit pas refusait la région entière. La forme à
    /// registre du même `/7` est `swapgs` quand `rm` vaut zéro, et rien
    /// d'autre : `0f 01 ff` ne se décode pas.
    ///
    /// **Pour l'interpréteur, c'est un pas sans effet** : il n'a pas de tampon,
    /// il marche les tables à chaque accès. L'opérande est une adresse, pas
    /// une lecture — un `invlpg` sur une page absente ne faute pas.
    #[test]
    fn invlpg_is_read_in_its_memory_form_and_nothing_else() {
        let step = decode(&[0x0f, 0x01, 0x3f]).expect("invlpg (%rdi) se décode");
        assert_eq!(step.op, Op::InvalidatePage);
        assert_eq!(step.length, 3, "deux d'opcode, un de ModRM");
        let address = step.memory.expect("un opérande en mémoire");
        assert_eq!(address.base, Some(7), "la page vient de RDI");
        let rsi = decode(&[0x0f, 0x01, 0x3e]).expect("invlpg (%rsi) se décode");
        assert_eq!(rsi.op, Op::InvalidatePage);

        assert_eq!(
            decode(&[0x0f, 0x01, 0xf8]).map(|step| step.op),
            Some(Op::SwapGs),
            "swapgs reste swapgs"
        );
        assert!(
            decode(&[0x0f, 0x01, 0xff]).is_none(),
            "/7 à registre, rm=7 : ni swapgs ni invlpg"
        );

        let mut cpu = Cpu {
            rip: 0x3000_0000,
            ..Default::default()
        };
        cpu.regs[7] = 0xFFFF_8000_0000_0000;
        cpu.step(&[0x0f, 0x01, 0x3f]);
        assert!(
            !cpu.faulted,
            "invlpg ne faute pas, même sur une page qui n'existe pas"
        );
        assert_eq!(
            cpu.rip, 0x3000_0003,
            "et l'exécution passe à l'instruction suivante"
        );
    }

    /// **`vmcall` et `vmmcall` se lisent, et rien d'autre de leur coin du
    /// groupe.**
    ///
    /// `0f 01 c1` est l'appel à l'hyperviseur d'Intel, `0f 01 d9` celui
    /// d'AMD. Le noyau Alpine les porte dans `vmware_platform`, sa sonde
    /// d'hyperviseur, et ne les exécute que si CPUID annonce la signature
    /// VMware — ce que `cpuid` n'annonce pas. Ils sont atteints statiquement,
    /// et un décodeur qui ne les lit pas refusait la région entière : la même
    /// famille que l'`int3` de la retpoline et `lkgs`.
    ///
    /// Comme `swapgs`, ce sont des **paires exactes** `(reg, rm)` de la forme
    /// à registre : `c2` (`vmlaunch`) et `d8` (`vmrun`) restent illisibles,
    /// et `ff` aussi. L'interpréteur les refuse par nom, RIP dessus.
    #[test]
    fn vmcall_and_vmmcall_are_read_as_two_exact_encodings() {
        let intel = decode(&[0x0f, 0x01, 0xc1]).expect("vmcall se décode");
        assert_eq!(intel.op, Op::HypervisorCall { amd: false });
        assert_eq!(intel.length, 3);
        let amd = decode(&[0x0f, 0x01, 0xd9]).expect("vmmcall se décode");
        assert_eq!(amd.op, Op::HypervisorCall { amd: true });
        assert_eq!(amd.length, 3);
        assert_eq!(
            decode(&[0x0f, 0x01, 0xf8]).map(|step| step.op),
            Some(Op::SwapGs),
            "swapgs reste swapgs"
        );
        for (voisin, nom) in [(0xc2u8, "vmlaunch"), (0xd8, "vmrun"), (0xff, "rien")] {
            assert!(
                decode(&[0x0f, 0x01, voisin]).is_none(),
                "0f 01 {voisin:02x} ({nom}) n'est pas lu"
            );
        }

        let mut cpu = Cpu {
            rip: 0x3000_0000,
            ..Default::default()
        };
        cpu.step(&[0x0f, 0x01, 0xc1]);
        assert!(
            cpu.faulted,
            "vmcall est une faute nommée pour l'interpréteur"
        );
        assert_eq!(
            cpu.rip, 0x3000_0000,
            "et le pointeur d'instruction reste dessus"
        );
    }

    /// **`invpcid` se lit avec son préfixe, dans sa forme mémoire, et rien
    /// d'autre.**
    ///
    /// `66 0f 38 82 /r` : oublier des traductions par identifiant de contexte
    /// (PCID), le type dans le registre `reg` et un descripteur de seize
    /// octets en mémoire. Le noyau Alpine l'écrit à 103 octets de
    /// `native_flush_tlb_one_user` — `66 0f 38 82 04 24`, `invpcid
    /// (%rsp),%rax` —, atteinte statiquement depuis le trampoline des
    /// alternatives, et ne l'exécute que si CPUID annonce `INVPCID`, ce que
    /// `cpuid` n'annonce pas. Un décodeur qui ne la lit pas refusait la
    /// région entière : la même famille que l'`int3`, `lkgs` et `vmcall`.
    ///
    /// **La page `0f 38` n'est pas ouverte pour autant.** Sans `66`, `0f 38
    /// 82` n'est rien ; la forme à registre n'existe pas — le descripteur est
    /// en mémoire, toujours ; `invept` et `invvpid`, ses deux voisines de
    /// gauche, restent illisibles, et `pshufb` aussi. L'interpréteur la
    /// refuse par nom, RIP dessus : il n'a pas de tampon à purger, mais il
    /// n'a pas de PCID non plus, et la dire « sans effet » serait affirmer
    /// quelque chose sur un contexte qu'il ne sait pas nommer.
    #[test]
    fn invpcid_is_read_with_its_prefix_in_its_memory_form_and_nothing_else() {
        let step =
            decode(&[0x66, 0x0f, 0x38, 0x82, 0x04, 0x24]).expect("invpcid (%rsp),%rax se décode");
        assert_eq!(step.op, Op::InvalidatePcid);
        assert_eq!(step.length, 6, "préfixe, trois d'opcode, ModRM et SIB");
        assert_eq!(step.dst, 0, "le type vient de RAX");
        let address = step.memory.expect("le descripteur est en mémoire");
        assert_eq!(address.base, Some(4), "et il est sur la pile");
        let rcx = decode(&[0x66, 0x0f, 0x38, 0x82, 0x0f]).expect("invpcid (%rdi),%rcx se décode");
        assert_eq!((rcx.op, rcx.dst), (Op::InvalidatePcid, 1));
        assert_eq!(rcx.length, 5);

        for (bytes, why) in [
            (
                &[0x0f, 0x38, 0x82, 0x04, 0x24][..],
                "sans 66, ce n'est rien",
            ),
            (
                &[0x66, 0x0f, 0x38, 0x82, 0xc0][..],
                "la forme à registre n'existe pas",
            ),
            (
                &[0x66, 0x0f, 0x38, 0x80, 0x04, 0x24][..],
                "invept (80) n'est pas lue",
            ),
            (
                &[0x66, 0x0f, 0x38, 0x81, 0x04, 0x24][..],
                "invvpid (81) n'est pas lue",
            ),
            (
                &[0x66, 0x0f, 0x38, 0x00, 0xc1][..],
                "pshufb reste illisible",
            ),
            (&[0xf3, 0x0f, 0x38, 0x82, 0x04, 0x24][..], "f3 n'est pas 66"),
            (&[0x66, 0x0f, 0x38, 0x82][..], "coupée avant son ModRM"),
        ] {
            assert!(decode(bytes).is_none(), "{why} : {bytes:02x?}");
        }

        let mut cpu = Cpu {
            rip: 0x3000_0000,
            ..Default::default()
        };
        cpu.step(&[0x66, 0x0f, 0x38, 0x82, 0x04, 0x24]);
        assert!(
            cpu.faulted,
            "invpcid est une faute nommée pour l'interpréteur"
        );
        assert_eq!(
            cpu.rip, 0x3000_0000,
            "et le pointeur d'instruction reste dessus"
        );
    }

    /// **`ltr` se lit dans sa forme à registre, et le reste du groupe 6 reste
    /// illisible.**
    ///
    /// `0f 00 /3`, opérande en registre : charger le registre de tâche depuis
    /// un sélecteur. Le noyau Alpine l'écrit à 72 octets de
    /// `native_load_tr_desc` — `0f 00 d8`, `ltr %eax`, avec `0x40` dedans —
    /// depuis `cpu_init_exception_handling`, et **l'exécute** : ce n'est pas
    /// la famille de l'`int3`. C'est le TSS du processeur, sans lequel aucune
    /// entrée d'exception ne connaît sa pile de secours.
    ///
    /// **Le groupe n'est pas ouvert pour autant.** `sldt`, `str`, `verr`,
    /// `verw` restent illisibles (`lldt` a sa propre tranche) ; la forme
    /// mémoire de `ltr` aussi,
    /// parce que le noyau ne l'écrit pas et que la lire serait deviner. `/6`
    /// sans `f2` n'est toujours rien. L'interpréteur la refuse par nom, RIP
    /// dessus : il n'a pas de table de descripteurs où trouver le TSS.
    #[test]
    fn ltr_is_read_in_its_register_form_and_the_rest_of_group_six_stays_refused() {
        let step = decode(&[0x0f, 0x00, 0xd8]).expect("ltr %eax se décode");
        assert_eq!(step.op, Op::LoadTaskRegister);
        assert_eq!(step.length, 3, "deux d'opcode, un de ModRM");
        assert_eq!(step.dst, 0, "le sélecteur vient d'EAX");
        assert!(
            step.memory.is_none(),
            "la forme à registre ne touche pas la mémoire"
        );
        let rcx = decode(&[0x0f, 0x00, 0xd9]).expect("ltr %ecx se décode");
        assert_eq!((rcx.op, rcx.dst), (Op::LoadTaskRegister, 1));
        let r8 = decode(&[0x41, 0x0f, 0x00, 0xd8]).expect("ltr %r8w se décode");
        assert_eq!((r8.op, r8.dst, r8.length), (Op::LoadTaskRegister, 8, 4));

        for (bytes, why) in [
            (&[0x0f, 0x00, 0x18][..], "la forme mémoire n'est pas lue"),
            (&[0x0f, 0x00, 0xc0][..], "sldt (/0) n'est pas lu"),
            (&[0x0f, 0x00, 0xc8][..], "str (/1) n'est pas lu"),
            (&[0x0f, 0x00, 0xe0][..], "verr (/4) n'est pas lu"),
            (&[0x0f, 0x00, 0xe8][..], "verw (/5) n'est pas lu"),
            (&[0x0f, 0x00, 0xf0][..], "/6 sans f2 n'est rien"),
            (&[0x0f, 0x00, 0xf8][..], "/7 ne désigne rien"),
            (&[0x0f, 0x00][..], "coupée avant son ModRM"),
        ] {
            assert!(decode(bytes).is_none(), "{why} : {bytes:02x?}");
        }

        let mut cpu = Cpu {
            rip: 0x3000_0000,
            ..Default::default()
        };
        cpu.step(&[0x0f, 0x00, 0xd8]);
        assert!(cpu.faulted, "ltr est une faute nommée pour l'interpréteur");
        assert_eq!(
            cpu.rip, 0x3000_0000,
            "et le pointeur d'instruction reste dessus"
        );
    }

    /// **`lldt` se lit dans sa forme à registre, et le sélecteur nul est
    /// celui du noyau.**
    ///
    /// `0f 00 /2`, opérande en registre : charger la table de descripteurs
    /// locale depuis un sélecteur. Le noyau Alpine l'écrit à 28 octets de
    /// `native_set_ldt` — `0f 00 d6`, `lldt %esi` — depuis `load_mm_ldt`
    /// dans `cpu_init`, avec **zéro** dans ESI : il n'a pas de LDT, et charge
    /// le sélecteur nul pour le dire. Exécutée pour de vrai, comme `ltr`.
    ///
    /// La forme mémoire, `sldt`, `str`, `verr` et `verw` restent illisibles.
    /// L'interpréteur la refuse par nom, RIP dessus : il n'a pas de table
    /// globale où trouver une LDT, nulle ou non.
    #[test]
    fn lldt_is_read_in_its_register_form_and_nothing_else() {
        let step = decode(&[0x0f, 0x00, 0xd6]).expect("lldt %esi se décode");
        assert_eq!(step.op, Op::LoadLocalDescriptorTable);
        assert_eq!(step.length, 3, "deux d'opcode, un de ModRM");
        assert_eq!(step.dst, 6, "le sélecteur vient d'ESI");
        assert!(
            step.memory.is_none(),
            "la forme à registre ne touche pas la mémoire"
        );
        let rax = decode(&[0x0f, 0x00, 0xd0]).expect("lldt %eax se décode");
        assert_eq!((rax.op, rax.dst), (Op::LoadLocalDescriptorTable, 0));
        assert_eq!(
            decode(&[0x0f, 0x00, 0xd8]).map(|step| step.op),
            Some(Op::LoadTaskRegister),
            "ltr reste ltr"
        );
        for (bytes, why) in [
            (&[0x0f, 0x00, 0x16][..], "la forme mémoire n'est pas lue"),
            (&[0x0f, 0x00, 0xc0][..], "sldt (/0) n'est pas lu"),
            (&[0x0f, 0x00, 0xc8][..], "str (/1) n'est pas lu"),
            (&[0x0f, 0x00, 0xe0][..], "verr (/4) n'est pas lu"),
            (&[0x0f, 0x00, 0xe8][..], "verw (/5) n'est pas lu"),
        ] {
            assert!(decode(bytes).is_none(), "{why} : {bytes:02x?}");
        }

        let mut cpu = Cpu {
            rip: 0x3000_0000,
            ..Default::default()
        };
        cpu.step(&[0x0f, 0x00, 0xd6]);
        assert!(cpu.faulted, "lldt est une faute nommée pour l'interpréteur");
        assert_eq!(
            cpu.rip, 0x3000_0000,
            "et le pointeur d'instruction reste dessus"
        );
    }

    /// **Le `lgdt` que le noyau écrit vraiment**, tel qu'il apparaît à l'octet
    /// 1512 du point d'entrée d'Alpine 6.6.134 — l'endroit exact où
    /// l'exploration de la région s'arrêtait.
    #[test]
    fn the_lgdt_the_kernel_actually_writes_is_read() {
        let step = decode(&[0x0f, 0x01, 0x15, 0xb1, 0xc9, 0x43, 0x01]).expect("le lgdt du noyau");
        assert_eq!(step.op, Op::LoadDescriptorTable { interrupts: false });
        assert_eq!(step.length, 7);
    }

    /// **Les six sélecteurs de segment, nommés un par un.**
    ///
    /// `8C` range un sélecteur, `8E` en charge un, et lequel des six vient du
    /// champ `reg` du ModRM — exactement comme pour le groupe `0F 01`. Charger
    /// DS et charger SS ne se ressemblent pas : SS change la pile, et le
    /// processeur inhibe les interruptions jusqu'à l'instruction suivante.
    /// Un seul nom pour les six perdrait cette différence-là.
    #[test]
    fn the_segment_registers_are_named_one_by_one() {
        use Segment::*;
        for (reg, segment) in [(0u8, Es), (2, Ss), (3, Ds), (4, Fs), (5, Gs)] {
            // mod=11, rm=000 : l'opérande est EAX, la forme qu'un noyau écrit.
            let modrm = 0b1100_0000 | (reg << 3);
            let store = decode(&[0x8c, modrm]).unwrap_or_else(|| panic!("8c reg={reg}"));
            assert_eq!(store.op, Op::StoreSegment { segment }, "8c reg={reg}");
            assert_eq!(store.length, 2);
            let load = decode(&[0x8e, modrm]).unwrap_or_else(|| panic!("8e reg={reg}"));
            assert_eq!(load.op, Op::LoadSegment { segment }, "8e reg={reg}");
            assert_eq!(load.length, 2);
        }
        // CS se **range** — c'est ainsi qu'un programme lit son propre anneau.
        assert_eq!(
            decode(&[0x8c, 0b1100_1000]).expect("8c vers CS").op,
            Op::StoreSegment { segment: Cs }
        );
    }

    /// **Charger CS n'est pas une instruction, et `reg=6` ou `7` non plus.**
    ///
    /// `8E /1` lèverait `#UD` sur le processeur : on ne change pas de segment
    /// de code par un `mov`, c'est le rôle du retour lointain. Et il n'y a que
    /// six segments : `reg=6` et `reg=7` ne désignent rien. Les décoder
    /// rendrait un nom là où le processeur refuse.
    #[test]
    fn loading_the_code_selector_is_not_an_instruction() {
        assert!(
            decode(&[0x8e, 0b1100_1000]).is_none(),
            "8e /1 charge CS : le processeur lève #UD"
        );
        for reg in [6u8, 7] {
            let modrm = 0b1100_0000 | (reg << 3);
            assert!(
                decode(&[0x8c, modrm]).is_none(),
                "8c reg={reg} ne désigne rien"
            );
            assert!(
                decode(&[0x8e, modrm]).is_none(),
                "8e reg={reg} ne désigne rien"
            );
        }
    }

    /// **Les trois chargements de segment que le noyau écrit vraiment**, à
    /// l'octet 1524 de son point d'entrée — l'endroit où la traduction
    /// s'arrêtait une fois le groupe `0F 01` lu.
    #[test]
    fn the_three_segment_loads_the_kernel_writes_are_read() {
        use Segment::*;
        let bytes: &[u8] = &[0x8e, 0xd8, 0x8e, 0xd0, 0x8e, 0xc0];
        let mut at = 0usize;
        let mut seen = Vec::new();
        while at < bytes.len() {
            let step = decode(&bytes[at..]).unwrap_or_else(|| panic!("l'octet {at}"));
            seen.push(step.op);
            at += step.length;
        }
        assert_eq!(
            seen,
            vec![
                Op::LoadSegment { segment: Ds },
                Op::LoadSegment { segment: Ss },
                Op::LoadSegment { segment: Es },
            ]
        );
    }

    /// **Les registres de contrôle, par leur numéro.**
    ///
    /// `0F 20` lit un registre de contrôle dans un registre général, `0F 22`
    /// fait l'inverse, et le numéro vient du champ `reg`. CR0 porte la
    /// pagination, CR3 la racine de la table de pages, CR4 les extensions :
    /// trois registres qui n'ont rien de commun, et qu'un seul nom
    /// confondrait.
    ///
    /// **L'opérande fait toujours huit octets**, sans REX.W : `mov %cr4,%rcx`
    /// s'écrit `0F 20 E1`, trois octets, et rend les soixante-quatre bits.
    #[test]
    fn the_control_registers_are_read_by_their_number() {
        for which in [0u8, 2, 3, 4] {
            let modrm = 0b1100_0000 | (which << 3) | 0b001; // rm=001 : RCX
            let read = decode(&[0x0f, 0x20, modrm]).unwrap_or_else(|| panic!("0f 20 cr{which}"));
            assert_eq!(read.op, Op::ReadControlRegister { which }, "cr{which}");
            assert_eq!(read.length, 3, "aucun REX, aucun immédiat");
            assert_eq!(read.width, Width::Qword, "huit octets, toujours");
            let write = decode(&[0x0f, 0x22, modrm]).unwrap_or_else(|| panic!("0f 22 cr{which}"));
            assert_eq!(write.op, Op::WriteControlRegister { which }, "cr{which}");
            assert_eq!(write.length, 3);
        }

        // **CR8 n'est atteignable que par REX.R**, et c'est le seul endroit du
        // décodeur où ce bit désigne autre chose qu'un registre général :
        // `44 0F 20 C1` est `mov %cr8,%rcx`. Le masquer à trois bits — comme il
        // le faut pour un segment — rendrait CR0 sans que rien ne le signale.
        let eight = decode(&[0x44, 0x0f, 0x20, 0xc1]).expect("mov %cr8,%rcx");
        assert_eq!(eight.op, Op::ReadControlRegister { which: 8 });
        assert_eq!(eight.length, 4, "un octet de REX en plus");

        // **Les quatre numéros qui ne désignent aucun registre.** Le
        // processeur lève `#UD` dessus ; les décoder inventerait un registre
        // de contrôle, et le refus nommé qui suit porterait un nom faux.
        for absent in [1u8, 5, 6, 7] {
            let modrm = 0b1100_0000 | (absent << 3) | 0b001;
            assert!(
                decode(&[0x0f, 0x20, modrm]).is_none(),
                "cr{absent} n'existe pas"
            );
            assert!(
                decode(&[0x0f, 0x22, modrm]).is_none(),
                "cr{absent} n'existe pas non plus en écriture"
            );
        }
    }

    /// **Un registre de contrôle n'a pas de forme mémoire, et le refuser est
    /// une question de longueur, pas de goût.**
    ///
    /// Le processeur *ignore* les deux bits de `mod` pour `0F 20` : `0F 20 05`
    /// est `mov %cr0,%rbp`, trois octets. Un décodeur qui laisse `read_modrm`
    /// interpréter ce ModRM y voit un déplacement relatif à RIP, avale quatre
    /// octets de plus et rend une longueur de sept. Ces quatre octets-là sont
    /// l'instruction suivante : tout ce qui vient après se décale, et le flux
    /// se met à produire des instructions plausibles et fausses.
    ///
    /// Aucun compilateur n'écrit cette forme. Le décodeur la refuse donc, et
    /// c'est ce refus-ci que ce test tient — pas la sémantique.
    #[test]
    fn a_control_register_has_no_memory_form_and_a_wrong_length_would_desynchronise() {
        for opcode in [0x20u8, 0x22] {
            assert!(
                decode(&[0x0f, opcode, 0x05, 0x78, 0x56, 0x34, 0x12]).is_none(),
                "0f {opcode:02x} 05 : le processeur y lit trois octets, pas sept"
            );
        }
    }

    /// **Les deux instructions du drapeau d'interruption, et l'arrêt.**
    ///
    /// `FA` éteint, `FB` allume, `F4` arrête le processeur jusqu'à la
    /// prochaine interruption. Un octet chacune, aucun opérande — et c'est
    /// exactement sur elles que la lecture en ligne droite du point d'entrée
    /// d'Alpine s'arrêtait, à l'octet 291 : `fa f4 eb fc`, autrement dit
    /// « coupe les interruptions, arrête-toi, et recommence » — la boucle
    /// d'arrêt d'un noyau qui n'a plus rien à faire.
    ///
    /// **Décoder n'est pas exécuter, et ici l'écart est entier** : rien ne
    /// délivre d'interruption, donc un `hlt` produit serait un arrêt
    /// définitif déguisé en attente. Les trois sont refusées par l'émetteur,
    /// nommément.
    #[test]
    fn the_interrupt_flag_and_the_halt_are_read() {
        for (byte, op) in [
            (0xfau8, Op::InterruptFlag(false)),
            (0xfb, Op::InterruptFlag(true)),
            (0xf4, Op::Halt),
        ] {
            let step = decode(&[byte]).unwrap_or_else(|| panic!("{byte:02x} se décode"));
            assert_eq!(step.op, op, "pour {byte:02x}");
            assert_eq!(step.length, 1, "un octet, sans opérande");
        }
    }

    /// **`pushf` et `popf`, les deux moitiés d'une section critique.**
    ///
    /// L'idiome qu'un noyau écrit partout est `pushfq ; cli ; … ; popfq` :
    /// sauver l'état des interruptions, les couper, faire ce qu'il y a à
    /// faire, et **rendre l'état d'avant** plutôt que de rallumer aveuglément.
    /// C'est pour ça qu'ils sont dans la même tranche que `cli` et `sti`, et
    /// pas dans celle de la pile.
    ///
    /// En mode 64 bits ils déplacent **huit** octets, sans REX.W ; le préfixe
    /// 0x66 les ramène à deux, et c'est la seule chose qui change leur taille.
    #[test]
    fn the_two_halves_of_a_critical_section_are_read() {
        let push = decode(&[0x9c]).expect("pushfq");
        assert_eq!(push.op, Op::PushFlags);
        assert_eq!(push.length, 1);
        assert_eq!(push.width, Width::Qword, "huit octets, sans REX.W");

        let pop = decode(&[0x9d]).expect("popfq");
        assert_eq!(pop.op, Op::PopFlags);
        assert_eq!(pop.length, 1);
        assert_eq!(pop.width, Width::Qword);

        // Le préfixe de taille d'opérande est le seul à les rétrécir.
        let court = decode(&[0x66, 0x9c]).expect("pushfw");
        assert_eq!(court.op, Op::PushFlags);
        assert_eq!(court.length, 2);
        assert_eq!(court.width, Width::Word, "0x66 ramène à deux octets");
    }

    /// **Les quatre octets sur lesquels la lecture s'arrêtait**, tels qu'ils
    /// sont à l'octet 291 du point d'entrée : `cli`, `hlt`, puis un saut court
    /// de -4 qui revient sur le `cli`. Les trois se lisent d'affilée, et le
    /// saut porte bien -4 — un déplacement relatif à l'instruction
    /// **suivante**, pas à lui-même.
    #[test]
    fn the_kernels_halt_loop_reads_whole() {
        let bytes: &[u8] = &[0xfa, 0xf4, 0xeb, 0xfc];
        let mut at = 0usize;
        let mut seen = Vec::new();
        while at < bytes.len() {
            let step = decode(&bytes[at..]).unwrap_or_else(|| panic!("l'octet {at}"));
            seen.push((step.op, step.imm as i64));
            at += step.length;
        }
        assert_eq!(at, bytes.len(), "et pas un octet de reste");
        assert_eq!(
            seen,
            vec![
                (Op::InterruptFlag(false), 0),
                (Op::Halt, 0),
                (Op::Jump(None), -4),
            ]
        );
    }

    /// **Le `mov %cr4,%rcx` du noyau**, à l'octet 113 de son point d'entrée —
    /// l'endroit exact où la **lecture** en ligne droite s'arrêtait.
    ///
    /// Et son voisin qui n'en est pas un : `0F 21` lit un registre de
    /// **débogage**, pas de contrôle. Deux opcodes consécutifs, deux fichiers
    /// de registres — et le même numéro n'y désigne pas la même chose : CR4
    /// existe, DR4 n'existe pas.
    #[test]
    fn the_control_register_read_the_kernel_actually_writes_is_read() {
        let step = decode(&[0x0f, 0x20, 0xe1]).expect("mov %cr4,%rcx");
        assert_eq!(step.op, Op::ReadControlRegister { which: 4 });
        assert_eq!(step.length, 3);
        assert!(
            decode(&[0x0f, 0x21, 0xe1]).is_none(),
            "0f 21 /4 est DR4, qui n'existe pas : ce n'est pas CR4"
        );
        assert!(decode(&[0x0f, 0x23, 0xe1]).is_none(), "0f 23 /4 non plus");
    }

    /// **Les registres de débogage se lisent et s'écrivent par leur numéro,
    /// et quatre et cinq n'existent pas.**
    ///
    /// `0F 21 /r` lit, `0F 23 /r` écrit ; le numéro est dans `reg`, le
    /// registre général dans `rm`, toujours en forme à registre. Le noyau
    /// Alpine les écrit dans `cpu_init` — `pv_native_set_debugreg`, `0f 23`
    /// — pour effacer DR0 à DR3, DR6 et DR7 au démarrage, et le décodeur les
    /// laissait illisibles exprès : « un autre fichier de registres, que le
    /// noyau n'écrit pas ici ». Il les écrit.
    ///
    /// DR4 et DR5 sont des alias de DR6 et DR7 quand CR4.DE est éteint, et
    /// `#UD` sinon : les décoder inventerait un registre. L'interpréteur les
    /// refuse par nom, RIP dessus.
    #[test]
    fn debug_registers_are_read_and_written_by_number_and_four_and_five_do_not_exist() {
        let write = decode(&[0x0f, 0x23, 0xfe]).expect("mov %rsi,%dr7 se décode");
        assert_eq!(write.op, Op::WriteDebugRegister { which: 7 });
        assert_eq!((write.dst, write.length), (6, 3));
        assert!(write.memory.is_none());
        let read = decode(&[0x0f, 0x21, 0xf1]).expect("mov %dr6,%rcx se décode");
        assert_eq!(read.op, Op::ReadDebugRegister { which: 6 });
        assert_eq!(read.dst, 1);
        for which in [0u8, 1, 2, 3] {
            let modrm = 0xc0 | (which << 3);
            let step = decode(&[0x0f, 0x23, modrm]).unwrap_or_else(|| panic!("dr{which}"));
            assert_eq!(step.op, Op::WriteDebugRegister { which });
        }
        for (bytes, why) in [
            (&[0x0f, 0x23, 0xe0][..], "DR4 n'existe pas"),
            (&[0x0f, 0x23, 0xe8][..], "DR5 n'existe pas"),
            (&[0x0f, 0x21, 0xe8][..], "DR5 ne se lit pas non plus"),
            (&[0x44, 0x0f, 0x23, 0xc0][..], "REX.R : DR8 n'existe pas"),
            (&[0x0f, 0x23, 0x38][..], "la forme mémoire n'est pas lue"),
        ] {
            assert!(decode(bytes).is_none(), "{why} : {bytes:02x?}");
        }

        let mut cpu = Cpu {
            rip: 0x3000_0000,
            ..Default::default()
        };
        cpu.step(&[0x0f, 0x23, 0xfe]);
        assert!(
            cpu.faulted,
            "écrire DR7 est une faute nommée pour l'interpréteur"
        );
        assert_eq!(
            cpu.rip, 0x3000_0000,
            "et le pointeur d'instruction reste dessus"
        );
        let mut cpu = Cpu {
            rip: 0x3000_0000,
            ..Default::default()
        };
        cpu.step(&[0x0f, 0x21, 0xf1]);
        assert!(cpu.faulted, "lire DR6 aussi");
    }

    /// **Le retour lointain, par lequel un noyau charge son sélecteur de code.**
    ///
    /// `lretq` dépile RIP **et** CS. Un `ret` proche ne dépile que RIP, et les
    /// confondre laisserait huit octets sur la pile — une pile décalée est un
    /// défaut qui ne se voit que bien plus tard, dans une fonction sans rapport.
    ///
    /// Les deux formes existent : `cb` seul, et `48 cb` avec le préfixe REX.W.
    /// Le noyau écrit la seconde ; les décoder toutes deux coûte une ligne et
    /// évite qu'un `cb` isolé passe pour un octet inconnu.
    #[test]
    fn a_far_return_is_not_a_near_one() {
        for bytes in [&[0xcb][..], &[0x48, 0xcb][..]] {
            let step = decode(bytes).unwrap_or_else(|| panic!("{bytes:02x?} se décode"));
            assert_eq!(step.op, Op::FarReturn, "pour {bytes:02x?}");
            assert_eq!(step.length, bytes.len(), "pour {bytes:02x?}");
            assert_ne!(
                step.op,
                Op::Return,
                "un retour lointain n'est pas un proche"
            );
        }
    }

    /// **`iretq` n'est ni un `ret` ni un `lretq`.** Il dépile **cinq** mots
    /// — RIP, CS, RFLAGS, RSP, SS — là où le lointain en dépile deux et le
    /// proche un seul. C'est l'instruction par laquelle un gestionnaire de
    /// faute rend la main à ce qu'il a interrompu, et sans elle une faute
    /// délivrée n'a pas de retour.
    ///
    /// `cf` seul est un `iretd` — trente-deux bits, que le mode long ne sert à
    /// rien : le décodeur le lit quand même, et c'est l'émetteur qui refuse
    /// cette largeur-là en la nommant. Ne pas le décoder le ferait passer pour
    /// un octet inconnu, ce qui est une autre question.
    #[test]
    fn a_return_from_interrupt_is_neither_near_nor_far() {
        let step = decode(&[0x48, 0xcf]).expect("48 cf se décode");
        assert_eq!(step.op, Op::InterruptReturn);
        assert_eq!(
            step.width,
            Width::Qword,
            "REX.W fait la forme de soixante-quatre bits"
        );
        assert_eq!(step.length, 2);
        let narrow = decode(&[0xcf]).expect("cf seul se décode aussi");
        assert_eq!(narrow.op, Op::InterruptReturn);
        assert_ne!(
            narrow.width,
            Width::Qword,
            "sans REX.W, ce n'est pas la forme longue"
        );
        for other in [Op::Return, Op::FarReturn] {
            assert_ne!(
                step.op, other,
                "un retour d'interruption n'est ni proche ni lointain"
            );
        }
    }

    /// **`int3` et `int n` portent leur vecteur.** `cc` est le trois, sans
    /// octet de plus ; `cd nn` lit son vecteur dans l'octet suivant. Un `cd`
    /// coupé au bord de la fenêtre ne se décode pas — il ne faut pas lui
    /// inventer un vecteur.
    ///
    /// Ce qui a rendu ce test nécessaire : `__x86_indirect_thunk_rax` commence
    /// par `e8 01 00 00 00 cc` — un `call +1` puis un `int3` que le saut
    /// enjambe. L'`int3` n'est jamais exécuté ; il doit quand même se lire,
    /// sans quoi la région entière est refusée.
    #[test]
    fn a_software_interrupt_carries_its_vector() {
        let three = decode(&[0xcc]).expect("cc se décode");
        assert_eq!(three.op, Op::SoftwareInterrupt);
        assert_eq!(three.imm, 3, "int3 est le vecteur trois");
        assert_eq!(three.length, 1);
        let syscall = decode(&[0xcd, 0x80]).expect("cd 80 se décode");
        assert_eq!(syscall.op, Op::SoftwareInterrupt);
        assert_eq!(syscall.imm, 0x80, "int $0x80 porte son vecteur");
        assert_eq!(syscall.length, 2);
        assert!(
            decode(&[0xcd]).is_none(),
            "un cd sans son octet n'a pas de vecteur"
        );
    }

    /// **La huitième instruction du noyau, à sa vraie place.**
    ///
    /// Les sept premières du point d'entrée d'Alpine 6.6.134, puis `wrmsr`.
    /// Sans ce test, « le décodeur connaît `wrmsr` » resterait une phrase :
    /// celui-ci décode la suite réelle et vérifie qu'on arrive bien dessus, au
    /// bon décalage.
    #[test]
    fn the_kernels_entry_reaches_wrmsr_at_its_eighth_instruction() {
        // mov %rsi,%r15 ; lea …(%rip),%rsp ; lea …(%rip),%rdi ;
        // mov $0xc0000101,%ecx ; lea …(%rip),%rdx ; mov %edx,%eax ;
        // shr $0x20,%rdx ; wrmsr
        let entry: &[u8] = &[
            0x49, 0x89, 0xf7, //
            0x48, 0x8d, 0x25, 0xbe, 0x3e, 0x40, 0x01, //
            0x48, 0x8d, 0x3d, 0x5f, 0xff, 0xff, 0xff, //
            0xb9, 0x01, 0x01, 0x00, 0xc0, //
            0x48, 0x8d, 0x15, 0x53, 0x9f, 0x9e, 0x01, //
            0x89, 0xd0, //
            0x48, 0xc1, 0xea, 0x20, //
            0x0f, 0x30, //
        ];
        let mut at = 0usize;
        let mut seen = Vec::new();
        while at < entry.len() {
            let step = decode(&entry[at..])
                .unwrap_or_else(|| panic!("l'octet {at} ne se décode pas : {:02x?}", &entry[at..]));
            seen.push(step.op);
            at += step.length;
        }
        assert_eq!(seen.len(), 8, "huit instructions : {seen:?}");
        assert_eq!(
            seen[7],
            Op::WriteModelRegister,
            "la huitième est `wrmsr` : {seen:?}"
        );
    }

    /// **Le produit signé de deux nombres de soixante-quatre bits**, dont la
    /// moitié haute demande une reconstruction que WebAssembly n'offre pas.
    /// Le corpus l'éprouve, mais seulement sur les valeurs qu'il porte ; ce
    /// test-ci fixe les deux bords que l'algorithme des quatre produits de
    /// trente-deux bits rate le plus facilement.
    #[test]
    fn the_high_half_of_a_wide_product_is_the_one_the_manual_describes() {
        // `imulq %rcx` — un opérande, produit dans RDX:RAX.
        let multiply = decode(&[0x48, 0xf7, 0xe9]).expect("imulq %rcx se décode");
        for (left, right, high, low) in [
            // -1 × -1 : le produit tient, et le haut est **zéro**, pas -1.
            (u64::MAX, u64::MAX, 0u64, 1u64),
            // -1 × 2 : le produit tient, et le haut est plein de uns.
            (u64::MAX, 2, u64::MAX, 2u64.wrapping_neg()),
            // Le carré du minimum : 2^126, qui ne tient pas.
            (1 << 63, 1 << 63, 1 << 62, 0),
        ] {
            let mut cpu = Cpu::default();
            cpu.regs[0] = left;
            cpu.regs[1] = right;
            cpu.execute(&multiply);
            assert_eq!(
                (cpu.regs[0], cpu.regs[2]),
                (low, high),
                "{left:x} × {right:x}"
            );
        }
    }

    /// **Le déplacement relatif au pointeur d'instruction se compte depuis la
    /// fin de l'instruction, pas depuis son début.**
    ///
    /// Ce test remplace celui qui tenait le **refus** de ce mode, et qui
    /// disait de lui-même : « le jour où les sauts arriveront, RIP sera connu
    /// et ce test devra changer de sens ». Ce jour est venu — l'émetteur
    /// connaît l'adresse de chaque instruction, donc il peut figer l'adresse à
    /// la compilation.
    ///
    /// Le corpus juge ce mode sur un programme entier ; ce test-ci fixe les
    /// deux confusions qu'un cas de programme ne distinguerait pas : l'erreur
    /// d'un octet, et le codage `mod=00, rm=101` pris pour une base RBP.
    #[test]
    fn a_displacement_relative_to_the_instruction_pointer_counts_from_the_end() {
        // 48 8d 05 <disp32> — `leaq disp(%rip), %rax`, sept octets.
        let step = decode(&[0x48, 0x8d, 0x05, 0x10, 0x00, 0x00, 0x00]).expect("8d 05 se lit");
        let address = step.memory.expect("un opérande mémoire");
        assert!(address.relative, "le mode doit être reconnu comme relatif");
        assert_eq!(address.base, None, "aucune base : ce n'est pas RBP");
        assert_eq!(address.displacement, 0x10);
        assert_eq!(step.length, 7);

        // Et le calcul, sur une machine dont RIP est posé.
        let mut cpu = Cpu {
            rip: 0x3000_0000,
            ..Default::default()
        };
        cpu.execute(&step);
        assert_eq!(
            cpu.regs[0],
            0x3000_0000 + 7 + 0x10,
            "l'adresse se compte depuis l'octet qui suit l'instruction"
        );

        // **Et la preuve que c'est bien le `mod` qui décide** : avec un
        // déplacement d'un octet, 101 redevient RBP et l'adresse n'a plus rien
        // de relatif.
        let step = decode(&[0x48, 0x8d, 0x45, 0x10]).expect("8d 45 est lisible");
        let address = step.memory.expect("un opérande mémoire");
        assert!(!address.relative);
        assert_eq!(address.base, Some(5));
    }

    /// **`%gs:` n'est pas une adresse absolue.**
    ///
    /// C'est un déplacement compté depuis une base que le noyau a posée
    /// lui-même, et c'est comme ça qu'il atteint ses variables par cœur. La
    /// confusion à écarter est exactement celle-là : lire `%gs:0x10` comme
    /// l'adresse 0x10 rend un pointeur plausible, tombe dans la page zéro, et
    /// ne ressemble à rien de ce que le processeur a fait.
    #[test]
    fn the_gs_prefix_adds_a_base_the_encoding_does_not_carry() {
        // 65 48 8b 04 25 10 00 00 00 — `movq %gs:0x10, %rax`.
        let step = decode(&[0x65, 0x48, 0x8b, 0x04, 0x25, 0x10, 0x00, 0x00, 0x00])
            .expect("le préfixe GS se lit");
        let address = step.memory.expect("un opérande mémoire");
        assert!(address.gs, "le segment doit être porté jusqu'à l'exécution");
        assert_eq!(address.base, None);
        assert_eq!(address.index, None);
        assert_eq!(address.displacement, 0x10);
        assert_eq!(step.length, 9);

        let mut cpu = Cpu {
            gs_base: 0x3000_1000,
            memory: GuestMemory {
                base: 0x3000_1000,
                bytes: (0..64u8).map(|byte| 0x10 + byte).collect(),
            },
            ..Default::default()
        };
        cpu.execute(&step);
        assert!(!cpu.faulted, "l'accès tombe dans la fenêtre");
        assert_eq!(
            cpu.regs[0], 0x2726_2524_2322_2120,
            "l'octet lu est celui de gs_base + 0x10, pas celui de 0x10"
        );

        // **Le même encodage sans le préfixe ne doit rien ajouter.** Sinon la
        // base s'appliquerait partout, ce qu'aucun cas mémoire du corpus ne
        // verrait tant que la base vaut la fenêtre.
        let plain =
            decode(&[0x48, 0x8b, 0x04, 0x25, 0x10, 0x00, 0x00, 0x00]).expect("sans préfixe");
        assert!(!plain.memory.expect("mémoire").gs);
    }

    /// **Les quatre segments que le mode 64 bits a vidés.**
    ///
    /// CS, SS, DS et ES ont une base forcée à zéro : les préfixes qui les
    /// désignent n'ont plus d'effet sur une adresse. Les refuser rejetait le
    /// NOP d'alignement du noyau — `66 2e 0f 1f 84 00 …`, dix-huit mille fois
    /// dans un noyau Alpine — et chaque branche dont le compilateur veut dire
    /// qu'elle n'est pas prise.
    ///
    /// Ce qu'un test doit tenir ici est la **longueur** : le préfixe compte
    /// dans l'instruction, et l'oublier décalerait tout ce qui suit.
    #[test]
    fn the_four_segments_the_long_mode_emptied_are_prefixes_and_nothing_more() {
        for (prefix, name) in [(0x2eu8, "cs"), (0x36, "ss"), (0x3e, "ds"), (0x26, "es")] {
            // <préfixe> 48 8b 46 08 — `movq 8(%rsi), %rax`, cinq octets.
            let step =
                decode(&[prefix, 0x48, 0x8b, 0x46, 0x08]).unwrap_or_else(|| panic!("{name}"));
            let address = step.memory.unwrap_or_else(|| panic!("{name}"));
            assert_eq!(
                step.length, 5,
                "{name} : le préfixe compte dans la longueur"
            );
            assert_eq!(address.base, Some(6), "{name}");
            assert_eq!(address.displacement, 8, "{name}");
            assert!(!address.gs, "{name} : ce n'est pas GS");
        }

        // **Et le NOP d'alignement que le noyau sème par milliers**, avec son
        // préfixe CS et son ModRM entier : `66 2e 0f 1f 84 00 00 00 00 00`.
        let step = decode(&[0x66, 0x2e, 0x0f, 0x1f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00])
            .expect("le NOP long du noyau se lit");
        assert_eq!(step.op, Op::Nop);
        assert_eq!(step.length, 10, "dix octets, tous consommés");
    }

    /// **Les conseils au cache et les barrières : ce qui passe, et ce que
    /// `0f ae` ne doit surtout pas laisser passer.**
    ///
    /// Le corpus matériel juge déjà les quatre `prefetch` nommés et les trois
    /// barrières — il les fait tourner et compare les registres au silicium.
    /// Ce qu'il ne peut pas juger, c'est un **refus** : une instruction que le
    /// décodeur accepte à tort ne figure dans aucun programme, donc rien ne
    /// tombe. C'est exactement le trou qu'une mutation a traversé : accepter
    /// la forme mémoire de `0f ae` fait lire `fxsave` comme un `nop`, et le
    /// corpus reste vert parce qu'il n'en contient pas.
    ///
    /// `0f ae` porte deux instructions différentes sous le même numéro de
    /// `reg` ; c'est `mod` qui tranche. Se tromper de côté ne perd pas un
    /// octet : ça exécute silencieusement le contraire de ce que le noyau a
    /// écrit.
    #[test]
    fn the_hints_are_read_and_the_state_savers_are_refused() {
        // Les quatre formes nommées, avec leurs adressages : registre de
        // base, base plus déplacement, base plus index mis à l'échelle.
        for (bytes, length, name) in [
            (&[0x0f, 0x18, 0x0e][..], 3, "prefetcht0 (%rsi)"),
            (&[0x0f, 0x18, 0x46, 0x08][..], 4, "prefetchnta 8(%rsi)"),
            (&[0x0f, 0x18, 0x56, 0x10][..], 4, "prefetcht1 16(%rsi)"),
            (&[0x0f, 0x18, 0x1c, 0xce][..], 4, "prefetcht2 (%rsi,%rcx,8)"),
            (&[0x0f, 0xae, 0xe8][..], 3, "lfence"),
            (&[0x0f, 0xae, 0xf0][..], 3, "mfence"),
            (&[0x0f, 0xae, 0xf8][..], 3, "sfence"),
        ] {
            let step = decode(bytes).unwrap_or_else(|| panic!("{name} se lit"));
            assert_eq!(step.op, Op::Nop, "{name}");
            assert_eq!(step.length, length, "{name} : la longueur consommée");
            // **Un conseil ne désigne rien à lire.** S'il portait son adresse,
            // un cœur qui traite `memory` comme une source la lirait — et le
            // manuel interdit à `prefetch` la moindre faute d'accès.
            assert!(step.memory.is_none(), "{name} : rien à lire");
        }

        // Et les sept que la forme mémoire cache derrière les mêmes numéros.
        // Aucune n'est un `nop` : `fxsave` écrit 512 octets, `ldmxcsr` change
        // l'arrondi de toute la virgule flottante vectorielle. Ce cœur-ci ne
        // porte ni XMM ni MXCSR, donc il refuse — et ce refus est ce que le
        // test tient.
        for (modrm, name) in [
            (0x00u8, "fxsave (%rax)"),
            (0x08, "fxrstor (%rax)"),
            (0x10, "ldmxcsr (%rax)"),
            (0x18, "stmxcsr (%rax)"),
            (0x20, "xsave (%rax)"),
            (0x28, "xrstor (%rax)"),
            // `/7` en mémoire est `clflush`, lue depuis la tranche qui l'a
            // rencontrée dans `cpa_flush` : voir le test suivant.
        ] {
            assert!(
                decode(&[0x0f, 0xae, modrm]).is_none(),
                "{name} n'est pas une barrière : la lire comme un nop \
                 exécuterait le contraire de ce que le noyau a écrit"
            );
        }

        // Les deux numéros de registre qui ne nomment aucune barrière.
        for (modrm, name) in [
            (0xc0u8, "0f ae /0 en registre"),
            (0xe0, "0f ae /4 en registre"),
        ] {
            assert!(decode(&[0x0f, 0xae, modrm]).is_none(), "{name}");
        }
    }

    /// **Le groupe 5 par la mémoire : ce qu'un noyau appelle par pointeur.**
    ///
    /// Le décodeur ne connaissait que `jmp *%reg`, et son commentaire le disait
    /// franchement : « une cible en mémoire demanderait une lecture que ce bras
    /// ne fait pas ». Or c'est la forme dominante — un noyau appelle par table
    /// de fonctions, pas par registre chargé à la main.
    ///
    /// Trois choses à tenir, qu'un cas de programme confondrait :
    /// 1. La cible est **lue en mémoire**, pas prise dans un registre.
    /// 2. `call` empile l'adresse de **l'instruction suivante**, longueur
    ///    comprise — la même erreur d'un octet que partout ailleurs.
    /// 3. En mode 64 bits ces trois formes sont **toujours** sur huit octets,
    ///    sans REX. Les traiter en trente-deux bits tronquerait chaque
    ///    pointeur de noyau à sa moitié basse.
    #[test]
    fn group_five_reaches_its_target_through_memory() {
        let window = || GuestMemory {
            base: 0x3000_1000,
            // Un pointeur reconnaissable à l'octet 0, un autre à l'octet 8.
            bytes: (0..64u8)
                .map(|byte| match byte {
                    0..=7 => [0x44, 0x33, 0x22, 0x11, 0, 0, 0, 0][byte as usize],
                    8..=15 => [0x88, 0x77, 0x66, 0x55, 0, 0, 0, 0][byte as usize - 8],
                    _ => 0xEE,
                })
                .collect(),
        };
        let machine = || Cpu {
            rip: 0x3000_0000,
            regs: {
                let mut regs = [0u64; 16];
                regs[4] = 0x3000_3000; // RSP, dans la fenêtre
                regs[6] = 0x3000_1000; // RSI pointe la fenêtre
                regs
            },
            memory: GuestMemory {
                base: 0x3000_0000,
                bytes: vec![0; 0x4000],
            },
            ..Default::default()
        };
        let load = |cpu: &mut Cpu| {
            let window = window();
            for (rank, byte) in window.bytes.iter().enumerate() {
                cpu.memory.bytes[0x1000 + rank] = *byte;
            }
        };

        // `ff 16` — `callq *(%rsi)`. Deux octets, donc l'adresse empilée est
        // celle de l'octet numéro deux.
        let step = decode(&[0xff, 0x16]).expect("ff /2 en mémoire se lit");
        assert_eq!(step.length, 2);
        let mut cpu = machine();
        load(&mut cpu);
        cpu.execute(&step);
        assert!(!cpu.faulted);
        assert_eq!(cpu.rip, 0x1122_3344, "la cible vient de la mémoire");
        assert!(cpu.jumped);
        assert_eq!(cpu.regs[4], 0x3000_3000 - 8, "la pile a descendu de huit");
        assert_eq!(
            cpu.memory.read(cpu.regs[4], Width::Qword),
            Some(0x3000_0002),
            "l'adresse empilée est celle qui suit l'instruction"
        );

        // `ff 66 08` — `jmpq *8(%rsi)`. Aucune écriture, aucune pile.
        let step = decode(&[0xff, 0x66, 0x08]).expect("ff /4 en mémoire se lit");
        assert_eq!(step.length, 3);
        let mut cpu = machine();
        load(&mut cpu);
        cpu.execute(&step);
        assert!(!cpu.faulted);
        assert_eq!(cpu.rip, 0x5566_7788);
        assert_eq!(cpu.regs[4], 0x3000_3000, "un saut ne touche pas la pile");

        // `ff 36` — `pushq (%rsi)`. Huit octets pris en mémoire, posés sur la
        // pile ; le pointeur d'instruction avance normalement.
        let step = decode(&[0xff, 0x36]).expect("ff /6 en mémoire se lit");
        let mut cpu = machine();
        load(&mut cpu);
        cpu.execute(&step);
        assert!(!cpu.faulted);
        assert!(!cpu.jumped);
        assert_eq!(cpu.regs[4], 0x3000_3000 - 8);
        assert_eq!(
            cpu.memory.read(cpu.regs[4], Width::Qword),
            Some(0x1122_3344)
        );

        // `ff d0` — `callq *%rax`, la même chose par un registre.
        let step = decode(&[0xff, 0xd0]).expect("ff /2 en registre se lit");
        let mut cpu = machine();
        cpu.regs[0] = 0x3000_0800;
        cpu.execute(&step);
        assert_eq!(cpu.rip, 0x3000_0800);
        assert_eq!(
            cpu.memory.read(cpu.regs[4], Width::Qword),
            Some(0x3000_0002)
        );
    }

    /// **`ud2` : l'instruction que Linux exécute exprès.**
    ///
    /// `BUG()` et `WARN()` se compilent en `0f 0b`, et le noyau en sème 4 077
    /// dans son image — le plus gros refus restant, tous octets confondus.
    /// Chaque chemin d'erreur en pose un, donc refuser `ud2` coupait une région
    /// de 4 Kio à chaque `if (unlikely(...)) BUG();`.
    ///
    /// **La décoder n'est pas l'exécuter.** Elle lève une exception
    /// d'instruction indéfinie — c'est tout son propos. Le cœur pose donc une
    /// faute et n'avance pas : avancer par-dessus ferait exécuter l'octet
    /// suivant, qui n'est pas du code que quiconque a voulu atteindre.
    #[test]
    fn the_instruction_linux_runs_on_purpose_decodes_but_faults() {
        let step = decode(&[0x0f, 0x0b]).expect("0f 0b se lit");
        assert_eq!(step.op, Op::Undefined);
        assert_eq!(step.length, 2, "deux octets, et rien derrière");

        // **Par `step`, pas par `execute`.** C'est `step` qui avance le
        // pointeur d'instruction, et c'est justement ce qu'il ne doit pas
        // faire ici. Un test qui n'appelle qu'`execute` laisse passer un cœur
        // qui repart à l'octet suivant — un sabotage l'a montré.
        let mut cpu = Cpu {
            rip: 0x3000_0000,
            ..Default::default()
        };
        cpu.step(&[0x0f, 0x0b]);
        assert!(cpu.faulted, "l'instruction indéfinie est une faute");
        assert_eq!(
            cpu.rip, 0x3000_0000,
            "le pointeur d'instruction reste sur elle : ce qui suit n'est pas \
             du code qu'on a voulu atteindre"
        );
    }

    /// **Ce qui suit un `ud2` n'est pas du code.**
    ///
    /// L'exécution n'en revient pas, donc les octets d'après ne sont
    /// atteignables que par ailleurs. Le noyau range volontiers sa table de
    /// bogues juste derrière ; les mettre dans la file du découvreur ferait
    /// refuser la région pour des données que personne n'exécute.
    #[test]
    fn nothing_follows_an_undefined_instruction() {
        // `incq %rdx`, `ud2`, puis deux octets qui ne se décodent pas.
        let bytes = [0x48, 0xff, 0xc2, 0x0f, 0x0b, 0x62, 0xd5];
        assert!(
            crate::x86_wasm::Module::region(&bytes, 0x3000_0000, 0).is_some(),
            "la région doit se compiler : ce qui suit le `ud2` n'est pas atteint"
        );
    }

    /// **FS est refusé, et c'est délibéré.** L'oracle ne peut pas le poser : sa
    /// base est celle des variables de fil de la glibc, et le canari de pile
    /// vit derrière. Un préfixe sans oracle serait une conduite devinée.
    #[test]
    fn the_fs_prefix_is_refused_for_want_of_an_oracle() {
        assert!(decode(&[0x64, 0x48, 0x8b, 0x04, 0x25, 0x10, 0x00, 0x00, 0x00]).is_none());
    }

    /// **`cmpxchg16b` se lit avec REX.W, dans sa forme mémoire, et rien d'autre
    /// du groupe 9.**
    ///
    /// `f0 48 0f c7 4e 20` est le mur de `___slab_alloc + 275` : le chemin
    /// rapide de la liste libre de SLUB. Sans REX.W, `0f c7 /1` est
    /// `cmpxchg8b`, que rien n'exécute ici et qui reste illisible plutôt que
    /// devinée. La forme à registre de `/1` n'existe pas ; `/6` et `/7` en
    /// registre sont `rdrand` et `rdseed`, que cette machine ne produit pas.
    #[test]
    fn cmpxchg16b_is_read_with_rex_w_in_its_memory_form_and_cmpxchg8b_stays_illegible() {
        let step = decode(&[0xf0, 0x48, 0x0f, 0xc7, 0x4e, 0x20])
            .expect("lock cmpxchg16b 0x20(%rsi) se décode");
        assert_eq!(step.op, Op::CompareAndExchangeSixteen);
        assert_eq!(step.length, 6, "lock, REX.W, deux d'opcode, ModRM, disp8");
        assert_eq!(step.width, Width::Qword);
        let address = step.memory.expect("la forme mémoire porte une adresse");
        assert_eq!(address.base, Some(6), "la base est RSI");
        assert_eq!(address.displacement, 0x20);
        assert!(!step.memory_is_source, "la mémoire est la destination");

        let bare = decode(&[0x48, 0x0f, 0xc7, 0x0e]).expect("cmpxchg16b (%rsi) sans lock");
        assert_eq!((bare.op, bare.length), (Op::CompareAndExchangeSixteen, 4));
        let r14 = decode(&[0x49, 0x0f, 0xc7, 0x4e, 0x20]).expect("cmpxchg16b 0x20(%r14)");
        assert_eq!(
            r14.memory.map(|a| a.base),
            Some(Some(14)),
            "REX.B étend la base"
        );

        for (bytes, why) in [
            (
                &[0x0f, 0xc7, 0x4e, 0x20][..],
                "sans REX.W c'est cmpxchg8b, illisible",
            ),
            (
                &[0xf0, 0x0f, 0xc7, 0x4e, 0x20][..],
                "lock cmpxchg8b, illisible aussi",
            ),
            (&[0x48, 0x0f, 0xc7, 0xce][..], "/1 en registre n'existe pas"),
            (
                &[0x48, 0x0f, 0xc7, 0x56, 0x20][..],
                "/2 (xrstors) n'est pas lu",
            ),
            (&[0x48, 0x0f, 0xc7, 0x46, 0x20][..], "/0 ne désigne rien"),
            (&[0x48, 0x0f, 0xc7, 0xf0][..], "rdrand (/6) n'est pas lu"),
            (&[0x48, 0x0f, 0xc7, 0xf8][..], "rdseed (/7) n'est pas lu"),
            (&[0x48, 0x0f, 0xc7][..], "coupée avant son ModRM"),
            (
                &[0x48, 0x0f, 0xc7, 0x4e][..],
                "coupée avant son déplacement",
            ),
        ] {
            assert!(decode(bytes).is_none(), "{why} : {bytes:02x?}");
        }
    }

    /// **`cmpxchg16b` compare seize octets à RDX:RAX, écrit RCX:RBX si les deux
    /// moitiés tiennent, recharge RDX:RAX sinon, et ne pose que ZF.**
    ///
    /// Les deux moitiés comptent : une seule qui diffère suffit à refuser
    /// l'écriture, et c'est ce que le troisième cas tient. Le préfixe `lock`
    /// ne change rien à ce que l'instruction calcule — un seul fil.
    #[test]
    fn cmpxchg16b_writes_the_pair_when_both_halves_match_and_reloads_them_otherwise() {
        const A_LOW: u64 = 0x1111_2222_3333_4444;
        const A_HIGH: u64 = 0x5555_6666_7777_8888;
        const N_LOW: u64 = 0x9999_aaaa_bbbb_cccc;
        const N_HIGH: u64 = 0xdddd_eeee_ffff_0000;
        const SLOT: u64 = 0x3000_1020;
        let machine = |rax: u64, rdx: u64| {
            let mut cpu = Cpu {
                rip: 0x3000_0000,
                memory: GuestMemory {
                    base: 0x3000_0000,
                    bytes: vec![0; 0x4000],
                },
                ..Default::default()
            };
            cpu.regs[0] = rax;
            cpu.regs[2] = rdx;
            cpu.regs[3] = N_LOW;
            cpu.regs[1] = N_HIGH;
            cpu.regs[6] = 0x3000_1000;
            cpu.memory.write(SLOT, Width::Qword, A_LOW).unwrap();
            cpu.memory.write(SLOT + 8, Width::Qword, A_HIGH).unwrap();
            // Des drapeaux reconnaissables autour, que l'instruction doit
            // laisser en place.
            cpu.flags.write(CF | OF | PF | DF);
            cpu
        };
        let pair = |cpu: &Cpu| {
            (
                cpu.memory.read(SLOT, Width::Qword).unwrap(),
                cpu.memory.read(SLOT + 8, Width::Qword).unwrap(),
            )
        };
        let code = [0xf0, 0x48, 0x0f, 0xc7, 0x4e, 0x20];

        // Les deux moitiés tiennent : la mémoire reçoit RCX:RBX, RDX:RAX ne
        // bougent pas, ZF est posé, et `step` avance de six.
        let mut cpu = machine(A_LOW, A_HIGH);
        cpu.step(&code);
        assert!(!cpu.faulted, "rien ne sort de la fenêtre");
        assert_eq!(pair(&cpu), (N_LOW, N_HIGH), "la mémoire reçoit RCX:RBX");
        assert_eq!(
            (cpu.regs[0], cpu.regs[2]),
            (A_LOW, A_HIGH),
            "RDX:RAX restent"
        );
        assert_eq!(cpu.regs[3], N_LOW, "RBX n'est que lu");
        assert_eq!(cpu.regs[1], N_HIGH, "RCX n'est que lu");
        let flags = cpu.flags.read();
        assert_ne!(flags & ZF, 0, "l'égalité pose ZF");
        assert_eq!(
            flags & (CF | OF | PF | DF),
            CF | OF | PF | DF,
            "le reste survit"
        );
        assert_eq!(flags & (SF | AF), 0, "rien d'autre n'apparaît");
        assert_eq!(cpu.rip, 0x3000_0006, "six octets consommés");

        // La moitié basse diffère : la mémoire reste, RDX:RAX la relisent,
        // ZF s'éteint.
        let mut cpu = machine(A_LOW ^ 1, A_HIGH);
        cpu.step(&code);
        assert!(!cpu.faulted);
        assert_eq!(pair(&cpu), (A_LOW, A_HIGH), "rien n'est écrit");
        assert_eq!(
            (cpu.regs[0], cpu.regs[2]),
            (A_LOW, A_HIGH),
            "RDX:RAX relisent"
        );
        let flags = cpu.flags.read();
        assert_eq!(flags & ZF, 0, "l'inégalité éteint ZF");
        assert_eq!(
            flags & (CF | OF | PF | DF),
            CF | OF | PF | DF,
            "le reste survit"
        );

        // La moitié haute seule diffère : même verdict. C'est ce cas qui tient
        // que les seize octets sont comparés, pas huit.
        let mut cpu = machine(A_LOW, A_HIGH ^ 1);
        cpu.step(&code);
        assert!(!cpu.faulted);
        assert_eq!(pair(&cpu), (A_LOW, A_HIGH), "rien n'est écrit");
        assert_eq!(
            (cpu.regs[0], cpu.regs[2]),
            (A_LOW, A_HIGH),
            "RDX:RAX relisent"
        );
        assert_eq!(cpu.flags.read() & ZF, 0);

        // Seize octets qui sortent de la fenêtre par leur fin : faute, rien
        // d'écrit, rien de relu.
        let mut cpu = machine(A_LOW, A_HIGH);
        cpu.regs[6] = 0x3000_3fd8; // 0x20 plus loin : les huit derniers octets manquent
        cpu.step(&code);
        assert!(cpu.faulted, "la seconde moitié sort de la fenêtre");
        assert_eq!(
            (cpu.regs[0], cpu.regs[2]),
            (A_LOW, A_HIGH),
            "RDX:RAX intacts"
        );
        assert_eq!(cpu.rip, 0x3000_0000, "et RIP reste dessus");
    }

    /// **`clflush` se lit dans sa forme mémoire, avec ou sans ses préfixes, et
    /// ne désigne rien à lire.**
    ///
    /// `cpa_flush + 309` est `3e 0f ae 38` : le `3e` est le remplissage des
    /// alternatives du noyau, `66 0f ae /7` est `clflushopt`. Vider une ligne
    /// de cache ne fait rien sur cette machine — pas de cache à vider —, donc
    /// c'est un `nop`, comme les conseils au cache et les barrières. Et comme
    /// eux, elle ne porte pas son adresse : un cœur qui traiterait `memory`
    /// comme une source la lirait, et le manuel ne prévoit pour `clflush`
    /// aucune faute d'accès sur une ligne qui n'est pas cartographiée.
    /// L'interpréteur le tient avec une adresse **hors** de la fenêtre : s'il
    /// la lisait, il fauterait.
    #[test]
    fn clflush_is_read_in_its_memory_form_with_or_without_its_prefixes_and_reads_nothing() {
        for (bytes, length, name) in [
            (
                &[0x3e, 0x0f, 0xae, 0x38][..],
                4,
                "ds clflush (%rax) — ce que le noyau écrit",
            ),
            (&[0x0f, 0xae, 0x38][..], 3, "clflush (%rax)"),
            (&[0x66, 0x0f, 0xae, 0x38][..], 4, "clflushopt (%rax)"),
            (&[0x0f, 0xae, 0x78, 0x20][..], 4, "clflush 0x20(%rax)"),
            (&[0x0f, 0xae, 0x3c, 0xce][..], 4, "clflush (%rsi,%rcx,8)"),
            (&[0x41, 0x0f, 0xae, 0x3f][..], 4, "clflush (%r15)"),
        ] {
            let step = decode(bytes).unwrap_or_else(|| panic!("{name} se lit"));
            assert_eq!(step.op, Op::Nop, "{name}");
            assert_eq!(step.length, length, "{name} : la longueur consommée");
            assert!(step.memory.is_none(), "{name} : rien à lire");
        }
        for (bytes, why) in [
            (
                &[0x66, 0x0f, 0xae, 0x30][..],
                "clwb (/6 avec 66) n'est pas lue",
            ),
            (&[0xf3, 0x0f, 0xae, 0x38][..], "f3 0f ae /7 ne désigne rien"),
            (
                &[0x0f, 0xae, 0x30][..],
                "xsaveopt (/6 en mémoire) reste refusée",
            ),
            (&[0x0f, 0xae][..], "coupée avant son ModRM"),
        ] {
            assert!(decode(bytes).is_none(), "{why} : {bytes:02x?}");
        }

        let mut cpu = Cpu {
            rip: 0x3000_0000,
            memory: GuestMemory {
                base: 0x3000_0000,
                bytes: vec![0; 0x1000],
            },
            ..Default::default()
        };
        cpu.regs[0] = 0x7fff_0000_0000; // hors de la fenêtre : une lecture fauterait
        cpu.flags.write(CF | ZF);
        cpu.step(&[0x3e, 0x0f, 0xae, 0x38]);
        assert!(!cpu.faulted, "rien n'est lu, donc rien ne faute");
        assert_eq!(cpu.rip, 0x3000_0004, "quatre octets consommés");
        assert_eq!(cpu.regs[0], 0x7fff_0000_0000, "aucun registre ne bouge");
        assert_eq!(
            cpu.flags.read() & (CF | ZF),
            CF | ZF,
            "aucun drapeau non plus"
        );
    }
}
