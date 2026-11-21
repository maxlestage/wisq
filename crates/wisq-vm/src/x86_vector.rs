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
