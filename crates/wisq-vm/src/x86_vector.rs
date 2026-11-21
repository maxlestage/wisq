//! **Les instructions SSE et SSE2 entières que l'émetteur sait faire.**
//!
//! Le premier vrai programme qu'Alpine lance, `ld-musl`, s'arrêtait sur
//! `66 48 0f 6e c3` — `movq %rbx,%xmm0` —, l'entrée du `memset` de musl,
//! suivie d'un `punpcklqdq`. Tout l'espace utilisateur est derrière ce mur :
//! le compilateur déplace les structures de seize octets par `movups`, les
//! remet à zéro par `pxor`, et la bibliothèque C cherche ses octets par
//! `pcmpeqb` et `pmovmskb`.
//!
//! **Ce fichier ne lit que ce que l'émetteur sait produire, et le dit.** Une
//! instruction décodée et non traduite refuserait sa région entière
//! (`Refused::CannotTranslate`) ; une instruction illisible n'arrête que son
//! bloc. Lire ici une forme que `x86_wasm_vector.rs` ne sait pas faire
//! changerait donc un arrêt de bloc en refus de région — c'est la règle qui
//! fixe la liste : **les déplacements, la logique, les entrelacements et
//! l'arithmétique entière**, jugés par les oracles matériels
//! `x86-xmm-oracle.tsv` et `x86-simd-oracle.tsv`, **et le calcul flottant**
//! de SSE et SSE2 (`Vector::Float`, traduit par `x86_wasm_float.rs`, jugé par
//! `x86-float-oracle.tsv`). Les formes de SSE3, que CPUID n'annonce pas,
//! restent illisibles, comme les conversions vers et depuis MMX.
//!
//! **Le préfixe obligatoire fait partie de l'opcode.** `0f 6f` est `movq` MMX,
//! `66 0f 6f` est `movdqa`, `f3 0f 6f` est `movdqu` : trois instructions. Ce
//! cœur n'a pas de MMX, donc les formes sans préfixe des opcodes entiers sont
//! refusées plutôt que confondues avec leur cousine à seize octets. Deux
//! préfixes obligatoires à la fois ne désignent rien de sûr et sont refusés.

use super::{read_modrm, Decoded, Op, Prefixes, Width};

/// Une opération vectorielle, telle que le décodeur la rend.
///
/// **La convention des opérandes est fixe** : `dst` porte toujours le champ
/// `reg` du ModRM, `src` le registre `rm` (quand `memory` est absente). Le
/// sens — qui lit, qui écrit, un registre général ou un XMM — est dans la
/// variante, pas dans les champs.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Vector {
    /// `movd`/`movq` d'un registre général ou de la mémoire **vers** un XMM
    /// (`66 [REX.W] 0f 6e`) : le reste du registre est mis à zéro. `width`
    /// dit quatre ou huit octets.
    MoveIn,
    /// `movd`/`movq` d'un XMM **vers** un registre général ou la mémoire
    /// (`66 [REX.W] 0f 7e`).
    MoveOut,
    /// `movq xmm/m64, xmm` (`f3 0f 7e`) : les huit octets bas, et le haut à
    /// zéro, que la source soit un registre ou la mémoire.
    LoadQuad,
    /// `movq xmm, xmm/m64` (`66 0f d6`) : la forme qui écrit. En registre, le
    /// haut de la destination est mis à zéro, comme `f3 0f 7e`.
    StoreQuad,
    /// Seize octets entrent dans le XMM : `movaps`, `movups`, `movapd`,
    /// `movupd`, `movdqa`, `movdqu` en forme de lecture.
    Load,
    /// Seize octets sortent du XMM : les mêmes en forme d'écriture.
    Store,
    /// `movss`/`movsd` vers le XMM (`f3`/`f2 0f 10`). **La règle dépend de la
    /// source** : depuis la mémoire, le reste du registre est mis à zéro ;
    /// depuis un registre, il est laissé tel quel. `width` dit quatre ou huit.
    LoadScalar,
    /// `movss`/`movsd` depuis le XMM (`f3`/`f2 0f 11`) : en mémoire, la seule
    /// largeur écrite ; en registre, la même fusion que la lecture.
    StoreScalar,
    /// `movlps`/`movlpd` en lecture (`[66] 0f 12` mémoire) et `movhps`/
    /// `movhpd` (`[66] 0f 16` mémoire) : une moitié entre, l'autre reste.
    LoadHalf { high: bool },
    /// Leurs formes d'écriture (`[66] 0f 13`, `[66] 0f 17`).
    StoreHalf { high: bool },
    /// `movhlps` (`0f 12` en registre) : la moitié haute de la source dans la
    /// moitié basse de la destination.
    HighToLow,
    /// `movlhps` (`0f 16` en registre) : la moitié basse de la source dans la
    /// moitié haute de la destination.
    LowToHigh,
    /// Les quatre opérations bit à bit, en entier (`pand`…) comme en flottant
    /// (`andps`…, `andpd`…) : sur des bits, ce sont les mêmes.
    Logic(Logic),
    /// Les entrelacements : `punpckl*`/`punpckh*`, `unpcklps`/`unpckhps`
    /// (des doubles mots), `unpcklpd`/`unpckhpd` (des quadruples mots).
    Unpack { lane: Width, high: bool },
    /// L'arithmétique entière voie par voie, et ce qui s'y range.
    Lanes(Lanes),
    /// Décalage de chaque voie d'un immédiat (`66 0f 71`/`72`/`73`).
    ShiftImmediate { lane: Width, kind: Shift },
    /// Décalage de chaque voie du compte que porte la source, ses
    /// soixante-quatre bits bas (`66 0f d1`… `66 0f f3`).
    ShiftBy { lane: Width, kind: Shift },
    /// `psrldq`/`pslldq` : le registre entier, décalé d'octets.
    ShiftBytes { left: bool },
    /// Les permutations à immédiat.
    Shuffle(Shuffle),
    /// Les bits de signe rassemblés dans un registre général.
    MoveMask(Mask),
    /// `pextrw` (`66 0f c5`, registre seulement).
    ExtractWord,
    /// `pinsrw` (`66 0f c4`).
    InsertWord,
    /// `ldmxcsr m32` (`0f ae /2`).
    LoadControl,
    /// `stmxcsr m32` (`0f ae /3`).
    StoreControl,
    /// Le calcul flottant : voir [`Float`].
    Float(Float),
}

/// **Le calcul flottant de SSE et SSE2.** `double` : des doubles (`f2` en
/// scalaire, `66` en empaqueté), sinon des simples (`f3`, sans préfixe).
/// `width` dit, pour les formes scalaires, la largeur de l'élément lu en
/// mémoire ; pour les conversions avec un registre général, celle de
/// l'entier (`REX.W`).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Float {
    /// `addss`… `sqrtsd` (`f3`/`f2 0f 51 58 59 5c 5d 5e 5f`) : l'élément bas,
    /// le reste de la destination laissé.
    Scalar { operation: FloatOp, double: bool },
    /// Leurs formes empaquetées (sans préfixe, ou `66`).
    Packed { operation: FloatOp, double: bool },
    /// `cmpss`/`cmpsd` (`f3`/`f2 0f c2 ib`) : un masque dans l'élément bas.
    CompareScalar { double: bool },
    /// `cmpps`/`cmppd` (`[66] 0f c2 ib`).
    ComparePacked { double: bool },
    /// `ucomiss`, `comiss`, `ucomisd`, `comisd` (`[66] 0f 2e`/`2f`) : ZF, PF
    /// et CF. Sans exceptions modélisées, les deux formes ne diffèrent pas.
    Order { double: bool },
    /// `cvtss2sd` (`f3 0f 5a`).
    Widen,
    /// `cvtsd2ss` (`f2 0f 5a`).
    Narrow,
    /// `cvtps2pd` (`0f 5a`).
    PackedWiden,
    /// `cvtpd2ps` (`66 0f 5a`).
    PackedNarrow,
    /// `cvtsi2ss`/`cvtsi2sd` (`f3`/`f2 [REX.W] 0f 2a`) : depuis un registre
    /// général ou la mémoire.
    FromInteger { double: bool },
    /// `cvt(t)ss2si`/`cvt(t)sd2si` (`f3`/`f2 [REX.W] 0f 2c`/`2d`) : vers le
    /// registre général `dst`.
    ToInteger { double: bool, truncate: bool },
    /// `cvtdq2pd` (`f3 0f e6`) et `cvtdq2ps` (`0f 5b`).
    FromIntegers { double: bool },
    /// `cvttpd2dq` (`66 0f e6`), `cvtpd2dq` (`f2 0f e6`), `cvtps2dq`
    /// (`66 0f 5b`) et `cvttps2dq` (`f3 0f 5b`).
    ToIntegers { double: bool, truncate: bool },
}

/// L'opération d'un élément.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FloatOp {
    Add,
    Sub,
    Mul,
    Div,
    Min,
    Max,
    Sqrt,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Logic {
    And,
    /// `pandn` : **la destination est niée**, pas la source.
    AndNot,
    Or,
    Xor,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Shift {
    Left,
    Right,
    /// Décalage arithmétique : le signe est recopié.
    RightArithmetic,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Shuffle {
    /// `pshufd` : quatre doubles mots choisis dans la source.
    Dwords,
    /// `pshuflw` : les quatre mots bas choisis, le haut recopié.
    LowWords,
    /// `pshufhw` : les quatre mots hauts choisis, le bas recopié.
    HighWords,
    /// `shufps` : deux doubles mots de la destination, deux de la source.
    Singles,
    /// `shufpd` : un quadruple mot de chaque.
    Doubles,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mask {
    /// `pmovmskb` : seize bits, un par octet.
    Bytes,
    /// `movmskps` : quatre bits.
    Singles,
    /// `movmskpd` : deux bits.
    Doubles,
}

/// L'arithmétique entière, voie par voie : `dst = f(dst, src)`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Lanes {
    Add(Width),
    Sub(Width),
    /// Addition saturée, signée ou non.
    AddSaturate {
        lane: Width,
        signed: bool,
    },
    SubSaturate {
        lane: Width,
        signed: bool,
    },
    /// Tous les bits à un là où les voies sont égales.
    Equal(Width),
    /// Tous les bits à un là où la destination est plus grande, **signée**.
    Greater(Width),
    /// `pminub`/`pmaxub` (octets non signés), `pminsw`/`pmaxsw` (mots signés).
    Minimum {
        lane: Width,
        signed: bool,
    },
    Maximum {
        lane: Width,
        signed: bool,
    },
    /// `pavgb`/`pavgw` : la moyenne arrondie vers le haut, non signée.
    Average(Width),
    /// `pmullw` : les seize bits bas du produit.
    MultiplyLow,
    /// `pmulhw`/`pmulhuw` : les seize bits hauts du produit.
    MultiplyHigh {
        signed: bool,
    },
    /// `pmuludq` : les doubles mots pairs, produit de soixante-quatre bits.
    MultiplyUnsignedDwords,
    /// `pmaddwd` : deux produits de mots signés, additionnés par paire.
    MultiplyAdd,
    /// `psadbw` : la somme des écarts absolus de huit octets, par moitié.
    SumOfDifferences,
    /// `packuswb` : des mots signés saturés en octets non signés.
    PackUnsignedBytes,
    /// `packsswb` : des mots signés saturés en octets signés.
    PackSignedBytes,
    /// `packssdw` : des doubles mots signés saturés en mots signés.
    PackSignedWords,
}

/// Le préfixe obligatoire lu devant `0f`, un seul au plus.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Mandatory {
    Bare,
    P66,
    PF3,
    PF2,
}

/// **Décoder une instruction vectorielle de la page `0f`**, l'octet `second`
/// déjà lu et `at` posé sur ce qui le suit. `None` pour tout ce que
/// l'émetteur ne sait pas faire.
pub(super) fn decode(
    second: u8,
    bytes: &[u8],
    mut at: usize,
    prefixes: Prefixes,
) -> Option<Decoded> {
    let mandatory = match (prefixes.operand_size, prefixes.repeat, prefixes.repeat_not) {
        (false, false, false) => Mandatory::Bare,
        (true, false, false) => Mandatory::P66,
        (false, true, false) => Mandatory::PF3,
        (false, false, true) => Mandatory::PF2,
        _ => return None,
    };
    let wide = prefixes.rex.is_some_and(|rex| rex & 0b1000 != 0);
    use Mandatory::{Bare, P66, PF2, PF3};
    // L'opération, et ce que la forme exige de l'opérande `rm` : `Some(true)`
    // la mémoire seule, `Some(false)` un registre seul, `None` l'un ou
    // l'autre.
    let (vector, rm_kind, width): (Vector, Option<bool>, Width) = match (mandatory, second) {
        (P66, 0x6e) => (
            Vector::MoveIn,
            None,
            if wide { Width::Qword } else { Width::Dword },
        ),
        (P66, 0x7e) => (
            Vector::MoveOut,
            None,
            if wide { Width::Qword } else { Width::Dword },
        ),
        (PF3, 0x7e) => (Vector::LoadQuad, None, Width::Qword),
        (P66, 0xd6) => (Vector::StoreQuad, None, Width::Qword),
        (Bare | P66, 0x28 | 0x10) | (P66 | PF3, 0x6f) => (Vector::Load, None, Width::Qword),
        (Bare | P66, 0x29 | 0x11) | (P66 | PF3, 0x7f) => (Vector::Store, None, Width::Qword),
        // **Les écritures non temporelles** — `movntps`, `movntpd`, `movntdq` —
        // sont des écritures alignées : le conseil de ne pas garder la ligne
        // en cache ne change rien à ce qui est écrit, et cette machine n'a pas
        // de cache à épargner. En mémoire seule : la forme registre n'existe
        // pas. C'est `xor_sse` et le banc du RAID de Linux, dans un module que
        // Void charge au démarrage.
        (Bare | P66, 0x2b) | (P66, 0xe7) => (Vector::Store, Some(true), Width::Qword),
        (PF3, 0x10) => (Vector::LoadScalar, None, Width::Dword),
        (PF2, 0x10) => (Vector::LoadScalar, None, Width::Qword),
        (PF3, 0x11) => (Vector::StoreScalar, None, Width::Dword),
        (PF2, 0x11) => (Vector::StoreScalar, None, Width::Qword),
        (P66, 0x12) => (Vector::LoadHalf { high: false }, Some(true), Width::Qword),
        (P66, 0x16) => (Vector::LoadHalf { high: true }, Some(true), Width::Qword),
        (Bare, 0x12) | (Bare, 0x16) => {
            // **La même paire d'octets, deux instructions** : en mémoire,
            // `movlps`/`movhps` ; en registre, `movhlps`/`movlhps`. C'est le
            // ModRM qui tranche, donc il est lu ici.
            let peek = *bytes.get(at)?;
            let register = peek >> 6 == 0b11;
            let vector = match (second, register) {
                (0x12, false) => Vector::LoadHalf { high: false },
                (0x16, false) => Vector::LoadHalf { high: true },
                (0x12, true) => Vector::HighToLow,
                _ => Vector::LowToHigh,
            };
            (vector, Some(!register), Width::Qword)
        }
        (Bare | P66, 0x13) => (Vector::StoreHalf { high: false }, Some(true), Width::Qword),
        (Bare | P66, 0x17) => (Vector::StoreHalf { high: true }, Some(true), Width::Qword),
        (Bare | P66, 0x54) => (Vector::Logic(Logic::And), None, Width::Qword),
        (Bare | P66, 0x55) => (Vector::Logic(Logic::AndNot), None, Width::Qword),
        (Bare | P66, 0x56) => (Vector::Logic(Logic::Or), None, Width::Qword),
        (Bare | P66, 0x57) => (Vector::Logic(Logic::Xor), None, Width::Qword),
        (P66, 0xdb) => (Vector::Logic(Logic::And), None, Width::Qword),
        (P66, 0xdf) => (Vector::Logic(Logic::AndNot), None, Width::Qword),
        (P66, 0xeb) => (Vector::Logic(Logic::Or), None, Width::Qword),
        (P66, 0xef) => (Vector::Logic(Logic::Xor), None, Width::Qword),
        (Bare, 0x14) => (unpack(Width::Dword, false), None, Width::Qword),
        (Bare, 0x15) => (unpack(Width::Dword, true), None, Width::Qword),
        (P66, 0x14) => (unpack(Width::Qword, false), None, Width::Qword),
        (P66, 0x15) => (unpack(Width::Qword, true), None, Width::Qword),
        (P66, 0x60) => (unpack(Width::Byte, false), None, Width::Qword),
        (P66, 0x61) => (unpack(Width::Word, false), None, Width::Qword),
        (P66, 0x62) => (unpack(Width::Dword, false), None, Width::Qword),
        (P66, 0x68) => (unpack(Width::Byte, true), None, Width::Qword),
        (P66, 0x69) => (unpack(Width::Word, true), None, Width::Qword),
        (P66, 0x6a) => (unpack(Width::Dword, true), None, Width::Qword),
        (P66, 0x6c) => (unpack(Width::Qword, false), None, Width::Qword),
        (P66, 0x6d) => (unpack(Width::Qword, true), None, Width::Qword),
        (P66, 0x63) => (lanes(Lanes::PackSignedBytes), None, Width::Qword),
        (P66, 0x67) => (lanes(Lanes::PackUnsignedBytes), None, Width::Qword),
        (P66, 0x6b) => (lanes(Lanes::PackSignedWords), None, Width::Qword),
        (P66, 0x64) => (lanes(Lanes::Greater(Width::Byte)), None, Width::Qword),
        (P66, 0x65) => (lanes(Lanes::Greater(Width::Word)), None, Width::Qword),
        (P66, 0x66) => (lanes(Lanes::Greater(Width::Dword)), None, Width::Qword),
        (P66, 0x74) => (lanes(Lanes::Equal(Width::Byte)), None, Width::Qword),
        (P66, 0x75) => (lanes(Lanes::Equal(Width::Word)), None, Width::Qword),
        (P66, 0x76) => (lanes(Lanes::Equal(Width::Dword)), None, Width::Qword),
        (P66, 0xfc) => (lanes(Lanes::Add(Width::Byte)), None, Width::Qword),
        (P66, 0xfd) => (lanes(Lanes::Add(Width::Word)), None, Width::Qword),
        (P66, 0xfe) => (lanes(Lanes::Add(Width::Dword)), None, Width::Qword),
        (P66, 0xd4) => (lanes(Lanes::Add(Width::Qword)), None, Width::Qword),
        (P66, 0xf8) => (lanes(Lanes::Sub(Width::Byte)), None, Width::Qword),
        (P66, 0xf9) => (lanes(Lanes::Sub(Width::Word)), None, Width::Qword),
        (P66, 0xfa) => (lanes(Lanes::Sub(Width::Dword)), None, Width::Qword),
        (P66, 0xfb) => (lanes(Lanes::Sub(Width::Qword)), None, Width::Qword),
        (P66, 0xdc) => (saturate(true, Width::Byte, false), None, Width::Qword),
        (P66, 0xdd) => (saturate(true, Width::Word, false), None, Width::Qword),
        (P66, 0xec) => (saturate(true, Width::Byte, true), None, Width::Qword),
        (P66, 0xed) => (saturate(true, Width::Word, true), None, Width::Qword),
        (P66, 0xd8) => (saturate(false, Width::Byte, false), None, Width::Qword),
        (P66, 0xd9) => (saturate(false, Width::Word, false), None, Width::Qword),
        (P66, 0xe8) => (saturate(false, Width::Byte, true), None, Width::Qword),
        (P66, 0xe9) => (saturate(false, Width::Word, true), None, Width::Qword),
        (P66, 0xda) => (
            lanes(Lanes::Minimum {
                lane: Width::Byte,
                signed: false,
            }),
            None,
            Width::Qword,
        ),
        (P66, 0xde) => (
            lanes(Lanes::Maximum {
                lane: Width::Byte,
                signed: false,
            }),
            None,
            Width::Qword,
        ),
        (P66, 0xea) => (
            lanes(Lanes::Minimum {
                lane: Width::Word,
                signed: true,
            }),
            None,
            Width::Qword,
        ),
        (P66, 0xee) => (
            lanes(Lanes::Maximum {
                lane: Width::Word,
                signed: true,
            }),
            None,
            Width::Qword,
        ),
        (P66, 0xe0) => (lanes(Lanes::Average(Width::Byte)), None, Width::Qword),
        (P66, 0xe3) => (lanes(Lanes::Average(Width::Word)), None, Width::Qword),
        (P66, 0xd5) => (lanes(Lanes::MultiplyLow), None, Width::Qword),
        (P66, 0xe5) => (
            lanes(Lanes::MultiplyHigh { signed: true }),
            None,
            Width::Qword,
        ),
        (P66, 0xe4) => (
            lanes(Lanes::MultiplyHigh { signed: false }),
            None,
            Width::Qword,
        ),
        (P66, 0xf4) => (lanes(Lanes::MultiplyUnsignedDwords), None, Width::Qword),
        (P66, 0xf5) => (lanes(Lanes::MultiplyAdd), None, Width::Qword),
        (P66, 0xf6) => (lanes(Lanes::SumOfDifferences), None, Width::Qword),
        (P66, 0xd1) => (shift_by(Width::Word, Shift::Right), None, Width::Qword),
        (P66, 0xd2) => (shift_by(Width::Dword, Shift::Right), None, Width::Qword),
        (P66, 0xd3) => (shift_by(Width::Qword, Shift::Right), None, Width::Qword),
        (P66, 0xe1) => (
            shift_by(Width::Word, Shift::RightArithmetic),
            None,
            Width::Qword,
        ),
        (P66, 0xe2) => (
            shift_by(Width::Dword, Shift::RightArithmetic),
            None,
            Width::Qword,
        ),
        (P66, 0xf1) => (shift_by(Width::Word, Shift::Left), None, Width::Qword),
        (P66, 0xf2) => (shift_by(Width::Dword, Shift::Left), None, Width::Qword),
        (P66, 0xf3) => (shift_by(Width::Qword, Shift::Left), None, Width::Qword),
        (P66, 0x71..=0x73) => {
            // **Le sens est dans `reg`**, l'opérande est toujours un
            // registre : `/2` logique à droite, `/4` arithmétique, `/6` à
            // gauche ; `73 /3` et `73 /7` décalent le registre entier
            // d'octets. `72 /4` existe (`psrad`), `73 /4` non (pas de
            // `psraq` en SSE2).
            let modrm = *bytes.get(at)?;
            if modrm >> 6 != 0b11 {
                return None;
            }
            let lane = match second {
                0x71 => Width::Word,
                0x72 => Width::Dword,
                _ => Width::Qword,
            };
            let vector = match ((modrm >> 3) & 0b111, second) {
                (2, _) => Vector::ShiftImmediate {
                    lane,
                    kind: Shift::Right,
                },
                (4, 0x71 | 0x72) => Vector::ShiftImmediate {
                    lane,
                    kind: Shift::RightArithmetic,
                },
                (6, _) => Vector::ShiftImmediate {
                    lane,
                    kind: Shift::Left,
                },
                (3, 0x73) => Vector::ShiftBytes { left: false },
                (7, 0x73) => Vector::ShiftBytes { left: true },
                _ => return None,
            };
            at += 1;
            let imm = u64::from(*bytes.get(at)?);
            at += 1;
            // Le registre décalé est `rm` : il va dans `dst`, comme pour
            // toutes les formes qui écrivent un XMM.
            return Some(Decoded {
                op: Op::Vector(vector),
                dst: (modrm & 0b111) | prefixes.rm_extension(),
                imm,
                immediate: true,
                length: at,
                ..Decoded::nothing(Width::Qword)
            });
        }
        (P66, 0x70) => (Vector::Shuffle(Shuffle::Dwords), None, Width::Qword),
        (PF2, 0x70) => (Vector::Shuffle(Shuffle::LowWords), None, Width::Qword),
        (PF3, 0x70) => (Vector::Shuffle(Shuffle::HighWords), None, Width::Qword),
        (Bare, 0xc6) => (Vector::Shuffle(Shuffle::Singles), None, Width::Qword),
        (P66, 0xc6) => (Vector::Shuffle(Shuffle::Doubles), None, Width::Qword),
        (P66, 0xd7) => (Vector::MoveMask(Mask::Bytes), Some(false), Width::Qword),
        (Bare, 0x50) => (Vector::MoveMask(Mask::Singles), Some(false), Width::Qword),
        (P66, 0x50) => (Vector::MoveMask(Mask::Doubles), Some(false), Width::Qword),
        (P66, 0xc5) => (Vector::ExtractWord, Some(false), Width::Qword),
        (P66, 0xc4) => (Vector::InsertWord, None, Width::Word),
        // **Le calcul flottant** (`x86_wasm_float.rs`).
        (PF3 | PF2, 0x51 | 0x58 | 0x59 | 0x5c..=0x5f) => (
            Vector::Float(Float::Scalar {
                operation: float_op(second),
                double: mandatory == PF2,
            }),
            None,
            scalar(mandatory == PF2),
        ),
        (Bare | P66, 0x51 | 0x58 | 0x59 | 0x5c..=0x5f) => (
            Vector::Float(Float::Packed {
                operation: float_op(second),
                double: mandatory == P66,
            }),
            None,
            Width::Qword,
        ),
        (PF3 | PF2, 0xc2) => (
            Vector::Float(Float::CompareScalar {
                double: mandatory == PF2,
            }),
            None,
            scalar(mandatory == PF2),
        ),
        (Bare | P66, 0xc2) => (
            Vector::Float(Float::ComparePacked {
                double: mandatory == P66,
            }),
            None,
            Width::Qword,
        ),
        (Bare | P66, 0x2e | 0x2f) => (
            Vector::Float(Float::Order {
                double: mandatory == P66,
            }),
            None,
            scalar(mandatory == P66),
        ),
        (PF3, 0x5a) => (Vector::Float(Float::Widen), None, Width::Dword),
        (PF2, 0x5a) => (Vector::Float(Float::Narrow), None, Width::Qword),
        (Bare, 0x5a) => (Vector::Float(Float::PackedWiden), None, Width::Qword),
        (P66, 0x5a) => (Vector::Float(Float::PackedNarrow), None, Width::Qword),
        (PF3 | PF2, 0x2a) => (
            Vector::Float(Float::FromInteger {
                double: mandatory == PF2,
            }),
            None,
            scalar(wide),
        ),
        (PF3 | PF2, 0x2c | 0x2d) => (
            Vector::Float(Float::ToInteger {
                double: mandatory == PF2,
                truncate: second == 0x2c,
            }),
            None,
            scalar(wide),
        ),
        (PF3, 0xe6) => (
            Vector::Float(Float::FromIntegers { double: true }),
            None,
            Width::Qword,
        ),
        (P66 | PF2, 0xe6) => (
            Vector::Float(Float::ToIntegers {
                double: true,
                truncate: mandatory == P66,
            }),
            None,
            Width::Qword,
        ),
        (Bare, 0x5b) => (
            Vector::Float(Float::FromIntegers { double: false }),
            None,
            Width::Qword,
        ),
        (P66 | PF3, 0x5b) => (
            Vector::Float(Float::ToIntegers {
                double: false,
                truncate: mandatory == PF3,
            }),
            None,
            Width::Qword,
        ),
        _ => return None,
    };
    let field = read_modrm(bytes, &mut at, prefixes)?;
    match rm_kind {
        Some(true) if field.memory.is_none() => return None,
        Some(false) if field.memory.is_some() => return None,
        _ => {}
    }
    // **L'immédiat suit le ModRM et son adresse.** Il compte dans la longueur,
    // donc dans l'adresse d'une forme relative à RIP, que `pin` calcule
    // depuis la fin de l'instruction.
    let immediate = matches!(
        vector,
        Vector::Shuffle(_)
            | Vector::ExtractWord
            | Vector::InsertWord
            | Vector::Float(Float::CompareScalar { .. } | Float::ComparePacked { .. })
    );
    let imm = if immediate {
        let value = u64::from(*bytes.get(at)?);
        at += 1;
        value
    } else {
        0
    };
    // Ce que la forme mémoire fait de son opérande : la lire, sauf pour les
    // formes qui l'écrivent.
    let writes_memory = matches!(
        vector,
        Vector::MoveOut
            | Vector::StoreQuad
            | Vector::Store
            | Vector::StoreScalar
            | Vector::StoreHalf { .. }
    );
    Some(Decoded {
        op: Op::Vector(vector),
        dst: field.reg,
        src: field.register,
        imm,
        immediate,
        length: at,
        memory: field.memory,
        memory_is_source: field.memory.is_some() && !writes_memory,
        ..Decoded::nothing(width)
    })
}

/// **`ldmxcsr` et `stmxcsr`**, lus dans le groupe `0f ae` : `/2` et `/3` en
/// mémoire, sans préfixe.
pub(super) fn control(reg: u8, memory: bool, prefixes: Prefixes) -> Option<Vector> {
    if !memory || prefixes.operand_size || prefixes.repeat || prefixes.repeat_not {
        return None;
    }
    match reg {
        2 => Some(Vector::LoadControl),
        3 => Some(Vector::StoreControl),
        _ => None,
    }
}

/// La largeur d'un élément scalaire : huit octets pour un double (ou un
/// entier en `REX.W`), quatre sinon.
fn scalar(eight: bool) -> Width {
    if eight {
        Width::Qword
    } else {
        Width::Dword
    }
}

/// L'opération d'un octet `51`, `58`, `59`, `5c`… `5f`.
fn float_op(second: u8) -> FloatOp {
    match second {
        0x51 => FloatOp::Sqrt,
        0x58 => FloatOp::Add,
        0x59 => FloatOp::Mul,
        0x5c => FloatOp::Sub,
        0x5d => FloatOp::Min,
        0x5e => FloatOp::Div,
        _ => FloatOp::Max,
    }
}

fn unpack(lane: Width, high: bool) -> Vector {
    Vector::Unpack { lane, high }
}

fn lanes(lanes: Lanes) -> Vector {
    Vector::Lanes(lanes)
}

fn saturate(add: bool, lane: Width, signed: bool) -> Vector {
    if add {
        Vector::Lanes(Lanes::AddSaturate { lane, signed })
    } else {
        Vector::Lanes(Lanes::SubSaturate { lane, signed })
    }
}

fn shift_by(lane: Width, kind: Shift) -> Vector {
    Vector::ShiftBy { lane, kind }
}

/// Pourquoi une instruction vectorielle n'est pas allée au bout.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum VectorFault {
    /// Un opérande en mémoire n'est pas accessible. `Cpu::unmapped` dit
    /// lequel ; la machine en fait une faute de page.
    Memory,
    /// `ldmxcsr` avec un bit réservé levé : le silicium lève `#GP(0)`, rien
    /// de changé.
    ReservedControl,
}

/// Les bits de MXCSR qu'un programme a le droit de poser : les seize du bas.
pub const MXCSR_MASK: u32 = 0xffff;

fn join(value: [u64; 2]) -> u128 {
    u128::from(value[0]) | (u128::from(value[1]) << 64)
}

fn split(value: u128) -> [u64; 2] {
    [value as u64, (value >> 64) as u64]
}

/// Appliquer `f` voie par voie : `lane` octets par voie, les deux opérandes
/// découpés pareil. `f` reçoit et rend des voies déjà masquées.
fn zip_lanes(left: u128, right: u128, lane: Width, f: impl Fn(u64, u64) -> u64) -> u128 {
    let bits = lane.bits() as u32;
    let mask = u128::from(lane.mask());
    let mut out = 0u128;
    for index in 0..(128 / bits) {
        let shift = index * bits;
        let a = ((left >> shift) & mask) as u64;
        let b = ((right >> shift) & mask) as u64;
        out |= (u128::from(f(a, b)) & mask) << shift;
    }
    out
}

fn lane(value: u128, width: Width, index: u32) -> u64 {
    ((value >> (index * width.bits() as u32)) & u128::from(width.mask())) as u64
}

/// Une voie lue comme un entier signé.
fn signed(value: u64, width: Width) -> i64 {
    let shift = 64 - width.bits() as u32;
    ((value << shift) as i64) >> shift
}

/// Borner un entier signé à la plage d'une voie, signée ou non.
fn saturate_to(value: i64, width: Width, as_signed: bool) -> u64 {
    let bits = width.bits() as u32;
    let (low, high) = if as_signed {
        (-(1i64 << (bits - 1)), (1i64 << (bits - 1)) - 1)
    } else {
        (0, (1i64 << bits) - 1)
    };
    value.clamp(low, high) as u64 & width.mask()
}

impl super::Cpu {
    /// **Exécuter une instruction vectorielle** — ce que `execute` refuse.
    ///
    /// Les règles sont celles que les corpus `x86-xmm-oracle.tsv` et
    /// `x86-simd-oracle.tsv` ont relevées sur le silicium, et
    /// `tests/x86_vector_oracle.rs` les rejoue contre cette fonction : aucun
    /// drapeau ne bouge, aucun autre registre XMM n'est touché, et une
    /// instruction qui faute n'a rien écrit dans un registre.
    ///
    /// RIP n'est pas avancé : c'est l'appelant qui le fait, comme pour
    /// `execute`.
    pub fn execute_vector(&mut self, instruction: &Decoded) -> Result<(), VectorFault> {
        let Op::Vector(vector) = instruction.op else {
            unreachable!("execute_vector ne reçoit que des instructions vectorielles")
        };
        let d = instruction.dst as usize;
        let s = instruction.src as usize;
        let width = instruction.width;
        // L'adresse de l'opérande mémoire, quand il y en a un.
        let at = instruction.memory.map(|address| {
            let after = self.after(instruction);
            self.effective_address(&address, after)
        });
        match vector {
            // `decode` lit le flottant de SSE pour l'émetteur, qui le traduit ;
            // la machine native le tient de `decode_extended` (`x86_sse.rs`) et
            // l'écarte de `decode` à la lecture (`pc::machine::decode`).
            Vector::Float(_) => {
                unreachable!("le flottant de SSE passe par decode_extended, pas par execute_vector")
            }
            Vector::MoveIn => {
                let value = match at {
                    Some(at) => self.vector_read(at, width)?,
                    None => self.get(instruction.src, width, false),
                };
                self.xmm[d] = [value, 0];
            }
            Vector::MoveOut => {
                let value = self.xmm[d][0] & width.mask();
                match at {
                    Some(at) => self.vector_write(at, width, value)?,
                    None => self.set(instruction.src, width, false, value),
                }
            }
            Vector::LoadQuad => {
                let value = match at {
                    Some(at) => self.vector_read(at, Width::Qword)?,
                    None => self.xmm[s][0],
                };
                self.xmm[d] = [value, 0];
            }
            Vector::StoreQuad => match at {
                Some(at) => self.vector_write(at, Width::Qword, self.xmm[d][0])?,
                None => self.xmm[s] = [self.xmm[d][0], 0],
            },
            Vector::Load => {
                self.xmm[d] = self.vector_source(at, s)?;
            }
            Vector::Store => match at {
                Some(at) => self.vector_write_whole(at, self.xmm[d])?,
                None => self.xmm[s] = self.xmm[d],
            },
            Vector::LoadScalar => match at {
                // Depuis la mémoire, le reste du registre est mis à zéro.
                Some(at) => self.xmm[d] = [self.vector_read(at, width)?, 0],
                // Depuis un registre, il est laissé tel quel.
                None => {
                    let mask = width.mask();
                    self.xmm[d][0] = (self.xmm[d][0] & !mask) | (self.xmm[s][0] & mask);
                }
            },
            Vector::StoreScalar => match at {
                Some(at) => self.vector_write(at, width, self.xmm[d][0] & width.mask())?,
                None => {
                    let mask = width.mask();
                    self.xmm[s][0] = (self.xmm[s][0] & !mask) | (self.xmm[d][0] & mask);
                }
            },
            Vector::LoadHalf { high } => {
                let at = at.expect("movlps et movhps lisent la mémoire");
                self.xmm[d][usize::from(high)] = self.vector_read(at, Width::Qword)?;
            }
            Vector::StoreHalf { high } => {
                let at = at.expect("movlps et movhps écrivent la mémoire");
                self.vector_write(at, Width::Qword, self.xmm[d][usize::from(high)])?;
            }
            Vector::HighToLow => self.xmm[d][0] = self.xmm[s][1],
            Vector::LowToHigh => self.xmm[d][1] = self.xmm[s][0],
            Vector::Logic(logic) => {
                let source = self.vector_source(at, s)?;
                let target = self.xmm[d];
                let apply = |a: u64, b: u64| match logic {
                    Logic::And => a & b,
                    Logic::AndNot => !a & b,
                    Logic::Or => a | b,
                    Logic::Xor => a ^ b,
                };
                self.xmm[d] = [apply(target[0], source[0]), apply(target[1], source[1])];
            }
            Vector::Unpack { lane: unit, high } => {
                let source = join(self.vector_source(at, s)?);
                let target = join(self.xmm[d]);
                let bits = unit.bits() as u32;
                let count = 64 / bits;
                let first = if high { count } else { 0 };
                let mut out = 0u128;
                for index in 0..count {
                    let a = u128::from(lane(target, unit, first + index));
                    let b = u128::from(lane(source, unit, first + index));
                    out |= a << (2 * index * bits);
                    out |= b << ((2 * index + 1) * bits);
                }
                self.xmm[d] = split(out);
            }
            Vector::Lanes(lanes) => {
                let source = join(self.vector_source(at, s)?);
                let target = join(self.xmm[d]);
                self.xmm[d] = split(Self::lanes(lanes, target, source));
            }
            Vector::ShiftImmediate { lane: unit, kind } => {
                let value = join(self.xmm[d]);
                self.xmm[d] = split(Self::shift_lanes(value, unit, kind, instruction.imm));
            }
            Vector::ShiftBy { lane: unit, kind } => {
                let count = self.vector_source(at, s)?[0];
                let value = join(self.xmm[d]);
                self.xmm[d] = split(Self::shift_lanes(value, unit, kind, count));
            }
            Vector::ShiftBytes { left } => {
                let value = join(self.xmm[d]);
                let count = instruction.imm & 0xff;
                let shifted = if count > 15 {
                    0
                } else if left {
                    value << (8 * count)
                } else {
                    value >> (8 * count)
                };
                self.xmm[d] = split(shifted);
            }
            Vector::Shuffle(shuffle) => {
                let source = join(self.vector_source(at, s)?);
                let target = join(self.xmm[d]);
                let pick = |index: u32| (instruction.imm >> (2 * index)) as u32 & 3;
                let out = match shuffle {
                    Shuffle::Dwords => (0..4).fold(0u128, |out, index| {
                        out | u128::from(lane(source, Width::Dword, pick(index))) << (32 * index)
                    }),
                    Shuffle::LowWords => {
                        (0..4).fold(source & !u128::from(u64::MAX), |out, index| {
                            out | u128::from(lane(source, Width::Word, pick(index))) << (16 * index)
                        })
                    }
                    Shuffle::HighWords => {
                        (0..4).fold(source & u128::from(u64::MAX), |out, index| {
                            out | u128::from(lane(source, Width::Word, 4 + pick(index)))
                                << (64 + 16 * index)
                        })
                    }
                    Shuffle::Singles => (0..4).fold(0u128, |out, index| {
                        let from = if index < 2 { target } else { source };
                        out | u128::from(lane(from, Width::Dword, pick(index))) << (32 * index)
                    }),
                    Shuffle::Doubles => {
                        let low = lane(target, Width::Qword, instruction.imm as u32 & 1);
                        let high = lane(source, Width::Qword, (instruction.imm >> 1) as u32 & 1);
                        u128::from(low) | (u128::from(high) << 64)
                    }
                };
                self.xmm[d] = split(out);
            }
            Vector::MoveMask(mask) => {
                let source = join(self.xmm[s]);
                let unit = match mask {
                    Mask::Bytes => Width::Byte,
                    Mask::Singles => Width::Dword,
                    Mask::Doubles => Width::Qword,
                };
                let count = 128 / unit.bits() as u32;
                let bits = (0..count).fold(0u64, |bits, index| {
                    bits | u64::from(lane(source, unit, index) & unit.sign() != 0) << index
                });
                // Trente-deux bits écrits : le haut du registre s'efface.
                self.set(instruction.dst, Width::Dword, false, bits);
            }
            Vector::ExtractWord => {
                let word = lane(join(self.xmm[s]), Width::Word, instruction.imm as u32 & 7);
                self.set(instruction.dst, Width::Dword, false, word);
            }
            Vector::InsertWord => {
                let word = match at {
                    Some(at) => self.vector_read(at, Width::Word)?,
                    None => self.get(instruction.src, Width::Word, false),
                };
                let shift = 16 * (instruction.imm as u32 & 7);
                let value = join(self.xmm[d]);
                self.xmm[d] =
                    split((value & !(0xffffu128 << shift)) | (u128::from(word & 0xffff) << shift));
            }
            Vector::LoadControl => {
                let at = at.expect("ldmxcsr lit la mémoire");
                let value = self.vector_read(at, Width::Dword)? as u32;
                if value & !MXCSR_MASK != 0 {
                    return Err(VectorFault::ReservedControl);
                }
                self.mxcsr = value;
            }
            Vector::StoreControl => {
                let at = at.expect("stmxcsr écrit la mémoire");
                self.vector_write(at, Width::Dword, u64::from(self.mxcsr))?;
            }
        }
        Ok(())
    }

    fn vector_read(&mut self, at: u64, width: Width) -> Result<u64, VectorFault> {
        self.read_memory(at, width).map_err(|_| VectorFault::Memory)
    }

    fn vector_write(&mut self, at: u64, width: Width, value: u64) -> Result<(), VectorFault> {
        self.write_memory(at, width, value)
            .map_err(|_| VectorFault::Memory)
    }

    /// Les seize octets de la source : la mémoire à `at`, ou le registre.
    fn vector_source(&mut self, at: Option<u64>, register: usize) -> Result<[u64; 2], VectorFault> {
        match at {
            Some(at) => Ok([
                self.vector_read(at, Width::Qword)?,
                self.vector_read(at.wrapping_add(8), Width::Qword)?,
            ]),
            None => Ok(self.xmm[register]),
        }
    }

    /// Seize octets en mémoire. La seconde moitié se traduit **avant** que la
    /// première ne soit posée : une écriture à cheval sur une page absente ne
    /// laisse rien derrière elle.
    fn vector_write_whole(&mut self, at: u64, value: [u64; 2]) -> Result<(), VectorFault> {
        let high = at.wrapping_add(8);
        self.probe_memory(high.wrapping_add(7), crate::x86_paging::Access::Write)
            .map_err(|_| VectorFault::Memory)?;
        self.vector_write(at, Width::Qword, value[0])?;
        self.vector_write(high, Width::Qword, value[1])
    }

    /// L'arithmétique entière, voie par voie : `f(destination, source)`.
    fn lanes(lanes: Lanes, target: u128, source: u128) -> u128 {
        match lanes {
            Lanes::Add(unit) => zip_lanes(target, source, unit, |a, b| a.wrapping_add(b)),
            Lanes::Sub(unit) => zip_lanes(target, source, unit, |a, b| a.wrapping_sub(b)),
            Lanes::AddSaturate {
                lane: unit,
                signed: as_signed,
            } => zip_lanes(target, source, unit, |a, b| {
                let sum = if as_signed {
                    signed(a, unit) + signed(b, unit)
                } else {
                    (a + b) as i64
                };
                saturate_to(sum, unit, as_signed)
            }),
            Lanes::SubSaturate {
                lane: unit,
                signed: as_signed,
            } => zip_lanes(target, source, unit, |a, b| {
                let difference = if as_signed {
                    signed(a, unit) - signed(b, unit)
                } else {
                    a as i64 - b as i64
                };
                saturate_to(difference, unit, as_signed)
            }),
            Lanes::Equal(unit) => {
                zip_lanes(
                    target,
                    source,
                    unit,
                    |a, b| if a == b { u64::MAX } else { 0 },
                )
            }
            Lanes::Greater(unit) => zip_lanes(target, source, unit, |a, b| {
                if signed(a, unit) > signed(b, unit) {
                    u64::MAX
                } else {
                    0
                }
            }),
            Lanes::Minimum {
                lane: unit,
                signed: as_signed,
            } => zip_lanes(target, source, unit, |a, b| {
                let smaller = if as_signed {
                    signed(a, unit) < signed(b, unit)
                } else {
                    a < b
                };
                if smaller {
                    a
                } else {
                    b
                }
            }),
            Lanes::Maximum {
                lane: unit,
                signed: as_signed,
            } => zip_lanes(target, source, unit, |a, b| {
                let larger = if as_signed {
                    signed(a, unit) > signed(b, unit)
                } else {
                    a > b
                };
                if larger {
                    a
                } else {
                    b
                }
            }),
            Lanes::Average(unit) => zip_lanes(target, source, unit, |a, b| (a + b + 1) >> 1),
            Lanes::MultiplyLow => zip_lanes(target, source, Width::Word, |a, b| a.wrapping_mul(b)),
            Lanes::MultiplyHigh { signed: as_signed } => {
                zip_lanes(target, source, Width::Word, |a, b| {
                    if as_signed {
                        ((signed(a, Width::Word) * signed(b, Width::Word)) >> 16) as u64
                    } else {
                        (a * b) >> 16
                    }
                })
            }
            Lanes::MultiplyUnsignedDwords => zip_lanes(target, source, Width::Qword, |a, b| {
                (a & 0xffff_ffff).wrapping_mul(b & 0xffff_ffff)
            }),
            Lanes::MultiplyAdd => zip_lanes(target, source, Width::Dword, |a, b| {
                let low = signed(a & 0xffff, Width::Word) * signed(b & 0xffff, Width::Word);
                let high = signed(a >> 16, Width::Word) * signed(b >> 16, Width::Word);
                low.wrapping_add(high) as u64
            }),
            Lanes::SumOfDifferences => zip_lanes(target, source, Width::Qword, |a, b| {
                (0..8).fold(0u64, |sum, index| {
                    let left = (a >> (8 * index)) & 0xff;
                    let right = (b >> (8 * index)) & 0xff;
                    sum + left.abs_diff(right)
                })
            }),
            Lanes::PackUnsignedBytes | Lanes::PackSignedBytes | Lanes::PackSignedWords => {
                let (from, to, as_signed) = match lanes {
                    Lanes::PackUnsignedBytes => (Width::Word, Width::Byte, false),
                    Lanes::PackSignedBytes => (Width::Word, Width::Byte, true),
                    _ => (Width::Dword, Width::Word, true),
                };
                let count = 128 / from.bits() as u32;
                let narrow = to.bits() as u32;
                let mut out = 0u128;
                for index in 0..count {
                    let a = saturate_to(signed(lane(target, from, index), from), to, as_signed);
                    let b = saturate_to(signed(lane(source, from, index), from), to, as_signed);
                    out |= u128::from(a) << (index * narrow);
                    out |= u128::from(b) << ((count + index) * narrow);
                }
                out
            }
        }
    }

    /// Décaler chaque voie du même compte. Un compte qui dépasse la voie rend
    /// zéro — ou le signe partout, pour le décalage arithmétique.
    fn shift_lanes(value: u128, unit: Width, kind: Shift, count: u64) -> u128 {
        let bits = unit.bits();
        zip_lanes(value, 0, unit, |a, _| match kind {
            Shift::Left if count >= bits => 0,
            Shift::Left => a << count,
            Shift::Right if count >= bits => 0,
            Shift::Right => a >> count,
            Shift::RightArithmetic => (signed(a, unit) >> count.min(bits - 1)) as u64,
        })
    }
}
