//! **Le compilateur, écrit ici. WebKit n'a que la signature.**
//!
//! iOS interdit à une application de l'App Store d'écrire une page à la fois
//! inscriptible et exécutable. Il n'interdit pas de produire une **donnée**.
//! Un module WebAssembly est une donnée ; c'est WebKit qui a le droit de la
//! compiler. Le contournement ne déplace donc pas le travail : le décodage, la
//! traduction et la génération de code sont dans ce fichier, et le moteur ne
//! fait que la dernière étape.
//!
//! **Ce qui juge ce code.** Un module émis ici tourne sous JavaScriptCore — le
//! moteur exact de `WKWebView`, que Bun embarque — et son résultat est comparé
//! aux cas de `x86-oracle.tsv`, relevés sur un vrai processeur. L'émetteur
//! n'est donc pas jugé par ce que j'en pense, mais par du silicium à travers le
//! moteur qui l'exécutera.
//!
//! **Les drapeaux sont calculés tout de suite**, comme le fait le module
//! « réaliste » du lot 8. C'est le coût honnête : un vrai cœur les paie. Les
//! rendre paresseux dans du WebAssembly demanderait de garder l'opération et
//! ses opérandes en mémoire, et c'est une tranche à part — mesurée avant
//! d'être écrite, comme le reste.

//! **Le fichier de registres est en variables globales, pas en mémoire.**
//!
//! Il vivait au début de la mémoire linéaire, aux octets 0 à 136. Ça marchait
//! tant que le module n'avait pas de mémoire invitée — mais la mémoire linéaire
//! **est** la RAM de l'invité, adresse pour adresse, et un noyau qui écrit à
//! l'adresse 8 écrasait alors RCX. Les registres sont donc sortis de là.
//!
//! Ce n'est pas qu'un déménagement : une globale n'est pas une case mémoire,
//! le moteur peut la garder dans un registre machine, et l'hôte y accède par un
//! nom exporté au lieu d'un décalage que les deux côtés doivent s'accorder à
//! calculer.

use crate::x86::{Decoded, Op, Width, AF, CF, OF, PF, SF, ZF};

/// Seize registres, puis RFLAGS, puis les emplacements de travail. L'indice est
/// celui de la globale exportée.
pub const RFLAGS_SLOT: usize = 16;
/// Les emplacements de travail : la traduction s'en sert au lieu de variables
/// locales. Il y en a six — le sixième porte le compte d'une rotation ramené
/// dans la largeur.
pub const SCRATCH_SLOT: usize = RFLAGS_SLOT + 1;
pub const SCRATCH_COUNT: usize = 6;
/// Le nombre de globales que le module déclare et exporte.
pub const GLOBAL_COUNT: usize = SCRATCH_SLOT + SCRATCH_COUNT;

/// L'entier non signé à longueur variable de WebAssembly.
fn unsigned(value: u64, out: &mut Vec<u8>) {
    let mut rest = value;
    loop {
        let mut byte = (rest & 0x7f) as u8;
        rest >>= 7;
        if rest != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if rest == 0 {
            break;
        }
    }
}

/// L'entier **signé** à longueur variable. Le confondre avec le précédent est
/// la faute classique : `i64.const -1` encodé en non signé devient un nombre
/// énorme, et le module reste valide — donc faux en silence.
fn signed(value: i64, out: &mut Vec<u8>) {
    let mut rest = value;
    loop {
        let byte = (rest & 0x7f) as u8;
        rest >>= 7;
        let done = (rest == 0 && byte & 0x40 == 0) || (rest == -1 && byte & 0x40 != 0);
        out.push(if done { byte } else { byte | 0x80 });
        if done {
            break;
        }
    }
}

fn section(id: u8, body: Vec<u8>, out: &mut Vec<u8>) {
    out.push(id);
    unsigned(body.len() as u64, out);
    out.extend_from_slice(&body);
}

/// Les opcodes dont la traduction a besoin.
mod code {
    pub const END: u8 = 0x0b;
    pub const GLOBAL_GET: u8 = 0x23;
    pub const GLOBAL_SET: u8 = 0x24;
    pub const I64_CONST: u8 = 0x42;
    pub const I64_EQZ: u8 = 0x50;
    pub const I64_LT_U: u8 = 0x54;
    pub const I64_ADD: u8 = 0x7c;
    pub const I64_SUB: u8 = 0x7d;
    pub const I64_AND: u8 = 0x83;
    pub const I64_OR: u8 = 0x84;
    pub const I64_XOR: u8 = 0x85;
    pub const I64_SHL: u8 = 0x86;
    pub const I64_SHR_U: u8 = 0x88;
    pub const I64_POPCNT: u8 = 0x7b;
    pub const I64_EXTEND_I32_U: u8 = 0xad;
    pub const I64_SHR_S: u8 = 0x87;
    pub const I64_NE: u8 = 0x52;
    pub const I64_LE_U: u8 = 0x58;
    /// Le reste d'une division non signée. C'est ce qui ramène un compte de
    /// rotation à l'intérieur de la largeur — tourner un octet de neuf crans
    /// revient à le tourner d'un.
    pub const I64_REM_U: u8 = 0x82;
    /// `select` prend deux valeurs et une condition, et rend la première quand
    /// la condition est vraie. C'est ce qui permet de traduire « un compte nul
    /// ne change rien » **sans branchement** : on calcule tout, puis on choisit.
    pub const SELECT: u8 = 0x1b;
}

/// Un corps de fonction en cours d'écriture.
#[derive(Default)]
struct Body {
    bytes: Vec<u8>,
}

impl Body {
    fn op(&mut self, opcode: u8) -> &mut Self {
        self.bytes.push(opcode);
        self
    }

    fn constant(&mut self, value: u64) -> &mut Self {
        self.bytes.push(code::I64_CONST);
        signed(value as i64, &mut self.bytes);
        self
    }

    /// Lire une globale : un registre invité, RFLAGS, ou un emplacement de
    /// travail.
    fn load(&mut self, slot: usize) -> &mut Self {
        self.bytes.push(code::GLOBAL_GET);
        unsigned(slot as u64, &mut self.bytes);
        self
    }

    /// Écrire une globale. Contrairement à un `i64.store`, il n'y a pas
    /// d'adresse à pousser d'abord : la valeur seule, puis l'indice.
    fn store(&mut self, slot: usize, value: impl FnOnce(&mut Body)) -> &mut Self {
        value(self);
        self.bytes.push(code::GLOBAL_SET);
        unsigned(slot as u64, &mut self.bytes);
        self
    }

    fn scratch(index: usize) -> usize {
        SCRATCH_SLOT + index
    }
}

/// Le module émis pour un bloc.
pub struct Module;

impl Module {
    /// Émettre un module qui exécute ce bloc, ou `None` si une instruction
    /// n'est pas traduisible. **Refuser plutôt que produire du code faux** :
    /// un bloc à moitié traduit rendrait un état que rien ne distingue d'un
    /// état juste.
    pub fn block(steps: &[Decoded]) -> Option<Vec<u8>> {
        let mut body = Body::default();
        for step in steps {
            Self::translate(step, &mut body)?;
        }
        body.op(code::END);

        let mut module = vec![0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];

        // Type : une fonction sans paramètre ni résultat.
        section(1, vec![0x01, 0x60, 0x00, 0x00], &mut module);
        // Fonction : une, du type zéro.
        section(3, vec![0x01, 0x00], &mut module);

        // Globales : le fichier de registres, RFLAGS, les emplacements de
        // travail. Toutes `i64`, toutes **mutables**, toutes à zéro au départ —
        // c'est l'hôte qui pose l'état avant chaque cas.
        let mut globals = Vec::new();
        unsigned(GLOBAL_COUNT as u64, &mut globals);
        for _ in 0..GLOBAL_COUNT {
            globals.push(0x7e); // i64
            globals.push(0x01); // mutable
            globals.push(code::I64_CONST);
            signed(0, &mut globals);
            globals.push(code::END);
        }
        section(6, globals, &mut module);

        // Exports : la fonction, puis chaque globale sous son numéro. L'hôte
        // les lit par leur nom au lieu d'un décalage que les deux côtés
        // devraient calculer pareil.
        let mut exports = Vec::new();
        unsigned(1 + GLOBAL_COUNT as u64, &mut exports);
        exports.extend_from_slice(&[0x03, b'r', b'u', b'n', 0x00, 0x00]);
        for slot in 0..GLOBAL_COUNT {
            let name = format!("g{slot}");
            unsigned(name.len() as u64, &mut exports);
            exports.extend_from_slice(name.as_bytes());
            exports.push(0x03); // une globale
            unsigned(slot as u64, &mut exports);
        }
        section(7, exports, &mut module);

        // Code : un corps, sans variable locale.
        let mut entry = vec![0x00];
        entry.extend_from_slice(&body.bytes);
        let mut code_section = vec![0x01];
        unsigned(entry.len() as u64, &mut code_section);
        code_section.extend_from_slice(&entry);
        section(10, code_section, &mut module);

        Some(module)
    }

    fn slot(register: u8) -> usize {
        register as usize
    }

    /// Pousser l'opérande de gauche, masqué à la largeur.
    fn left(step: &Decoded, body: &mut Body) {
        body.load(Self::slot(step.dst));
        if step.dst_high {
            body.constant(8).op(code::I64_SHR_U);
        }
        body.constant(step.width.mask()).op(code::I64_AND);
    }

    fn right(step: &Decoded, body: &mut Body) {
        if step.immediate {
            body.constant(step.imm & step.width.mask());
            return;
        }
        body.load(Self::slot(step.src));
        if step.src_high {
            body.constant(8).op(code::I64_SHR_U);
        }
        body.constant(step.width.mask()).op(code::I64_AND);
    }

    fn translate(step: &Decoded, body: &mut Body) -> Option<()> {
        // **Les décalages ont leurs propres règles**, et les faire passer par
        // la machinerie à deux opérandes en donnerait quatre fausses. Ils
        // sortent ici, exactement comme dans l'interpréteur — deux cœurs qui
        // divergent de forme finissent par diverger de fond.
        if matches!(step.op, Op::Shl | Op::Shr | Op::Sar) {
            Self::shift(step, body);
            return Some(());
        }
        // Les rotations ont leur propre traduction : elles ne posent que deux
        // drapeaux, et les quatre autres doivent survivre intacts.
        if matches!(step.op, Op::Rol | Op::Ror) {
            Self::rotate(step, body);
            return Some(());
        }
        // `lea` : une somme, un décalage, et aucun drapeau.
        if step.op == Op::Lea {
            return Self::lea(step, body);
        }

        // **Les transferts ont deux largeurs et zéro drapeau.** Les faire
        // passer plus bas lirait la source à la largeur de la destination —
        // `movzbq %cl, %rax` rendrait `rcx` entier — et poserait des drapeaux
        // que le processeur laisse intacts.
        if matches!(step.op, Op::Mov | Op::Movsx) {
            Self::transfer(step, body);
            return Some(());
        }

        let mask = step.width.mask();
        let sign = step.width.sign();

        // Les deux opérandes sont posés en mémoire de travail : la traduction
        // les relit plusieurs fois pour les drapeaux, et les recalculer serait
        // du code en plus pour rien.
        body.store(Body::scratch(0), |b| Self::left(step, b));
        body.store(Body::scratch(1), |b| Self::right(step, b));

        // Le résultat.
        body.store(Body::scratch(2), |b| {
            match step.op {
                Op::Add => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_ADD);
                }
                Op::Sub | Op::Cmp => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_SUB);
                }
                Op::Adc => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_ADD);
                    b.load(RFLAGS_SLOT).constant(CF).op(code::I64_AND);
                    b.op(code::I64_ADD);
                }
                Op::Sbb => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_SUB);
                    b.load(RFLAGS_SLOT).constant(CF).op(code::I64_AND);
                    b.op(code::I64_SUB);
                }
                Op::And | Op::Test => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_AND);
                }
                Op::Or => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_OR);
                }
                Op::Xor => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_XOR);
                }
                Op::Inc => {
                    b.load(Body::scratch(0)).constant(1).op(code::I64_ADD);
                }
                Op::Dec => {
                    b.load(Body::scratch(0)).constant(1).op(code::I64_SUB);
                }
                Op::Neg => {
                    b.constant(0).load(Body::scratch(0)).op(code::I64_SUB);
                }
                Op::Not => {
                    b.load(Body::scratch(0))
                        .constant(u64::MAX)
                        .op(code::I64_XOR);
                }
                Op::Shl | Op::Shr | Op::Sar => unreachable!("les décalages sortent avant"),
                Op::Mov | Op::Movsx => unreachable!("les transferts sortent avant"),
                Op::Rol | Op::Ror => unreachable!("les rotations sortent avant"),
                Op::Lea => unreachable!("lea sort avant"),
            }
            b.constant(mask).op(code::I64_AND);
        });

        // **Les opérandes des drapeaux ne sont pas toujours ceux du décodeur**,
        // et c'est le piège qui a coûté 339 cas au premier passage.
        //
        // `inc` n'a pas d'opérande source : son champ `src` reste à zéro, donc
        // « droite » désignait le registre 0. La demi-retenue, qui vaut
        // `(gauche ^ droite ^ résultat) & 0x10`, lisait alors `rax` au lieu de
        // **1**, et se trompait chaque fois que les deux différaient sur ce
        // bit. Le silicium l'a dit ; rien d'autre ne l'aurait dit.
        //
        // `neg` a le même défaut sous une autre forme : c'est `0 - opérande`,
        // donc ses opérandes de drapeaux sont zéro et l'original, pas ceux que
        // le décodeur a rendus.
        match step.op {
            Op::Inc | Op::Dec => {
                body.store(Body::scratch(1), |b| {
                    b.constant(1);
                });
            }
            Op::Neg => {
                // L'ordre compte : l'original doit être recopié **avant** que
                // sa case ne soit écrasée par zéro.
                body.store(Body::scratch(1), |b| {
                    b.load(Body::scratch(0));
                });
                body.store(Body::scratch(0), |b| {
                    b.constant(0);
                });
            }
            _ => {}
        }

        // **`not` ne touche à aucun drapeau.** C'est la seule du groupe, et
        // l'oublier donnerait un cœur qui écrase des drapeaux que le vrai
        // processeur préserve.
        if step.op != Op::Not {
            Self::flags(step, mask, sign, body);
        }

        if !step.discards {
            Self::write_back(step, mask, body);
        }
        Some(())
    }

    /// **Un décalage, traduit sans un seul branchement.**
    ///
    /// La règle « un compte nul ne touche à rien » demanderait un `if` ; elle
    /// est rendue par `select`, qui choisit entre l'ancien état et le nouveau
    /// après avoir calculé les deux. C'est plus de code émis et moins de code
    /// **exécuté** : un saut mal prédit coûte plus cher que quelques opérations
    /// arithmétiques, et un cœur qui décale en décale beaucoup.
    fn shift(step: &Decoded, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let sign = width.sign();
        let bits: u64 = if width == Width::Qword {
            64
        } else {
            (width as u64) * 8
        };
        let count_mask: u64 = if width == Width::Qword { 63 } else { 31 };
        let slot = Self::slot(step.dst);

        // scratch 0 : l'opérande. scratch 1 : le compte, déjà masqué.
        body.store(Body::scratch(0), |b| {
            Self::left(step, b);
        });
        body.store(Body::scratch(1), |b| {
            if step.count_is_cl {
                // **Le compte vient de `%cl`**, l'octet bas de `rcx`. Le
                // masque à 0xff serait redondant : celui à 31 ou 63 ci-dessous
                // le subsume, puisque 63 tient déjà dans un octet. Un sabotage
                // l'a montré — il ne faisait tomber aucun cas — et du code que
                // rien ne peut tenir n'a pas sa place ici.
                b.load(Self::slot(1));
            } else {
                b.constant(step.imm);
            }
            b.constant(count_mask).op(code::I64_AND);
        });

        // scratch 2 : le résultat, calculé sans se soucier du compte nul.
        body.store(Body::scratch(2), |b| {
            match step.op {
                Op::Shl => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_SHL);
                }
                Op::Shr => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_SHR_U);
                }
                _ => {
                    // Arithmétique : étendre le signe à soixante-quatre bits
                    // avant de décaler, sinon les bits recopiés seraient ceux
                    // du mot entier et pas ceux de l'opérande.
                    b.load(Body::scratch(0))
                        .constant(64 - bits)
                        .op(code::I64_SHL);
                    b.constant(64 - bits).op(code::I64_SHR_S);
                    b.load(Body::scratch(1)).op(code::I64_SHR_S);
                }
            }
            b.constant(mask).op(code::I64_AND);
        });

        // scratch 3 : la retenue, le **dernier bit sorti**.
        body.store(Body::scratch(3), |b| {
            match step.op {
                Op::Shl => {
                    // **L'ordre de la pile compte** : `shr_u` prend la valeur
                    // puis le compte. Les inverser produit un module valide
                    // qui décale le compte par la valeur — faux en silence.
                    b.load(Body::scratch(0));
                    b.constant(bits).load(Body::scratch(1)).op(code::I64_SUB);
                    b.op(code::I64_SHR_U);
                    b.constant(1).op(code::I64_AND);
                    // Au-delà de la largeur il n'y a plus rien à sortir, et
                    // l'architecture ne définit plus la retenue.
                    b.constant(0);
                    b.load(Body::scratch(1)).constant(bits).op(code::I64_LE_U);
                    b.op(code::SELECT);
                }
                Op::Shr => {
                    b.load(Body::scratch(0));
                    b.load(Body::scratch(1)).constant(1).op(code::I64_SUB);
                    b.op(code::I64_SHR_U).constant(1).op(code::I64_AND);
                }
                _ => {
                    // **`sar` sature, et sa retenue avec lui.** Décaler un
                    // octet de trente et un bits ne laisse que des bits de
                    // signe, et le dernier sorti **est** le bit de signe.
                    // Partager la formule de `shr` donnerait zéro — mesuré :
                    // cinquante cas, tous sur `sar`, tous sur ce bit.
                    b.load(Body::scratch(0));
                    b.load(Body::scratch(1)).constant(1).op(code::I64_SUB);
                    b.op(code::I64_SHR_U).constant(1).op(code::I64_AND);
                    b.load(Body::scratch(0))
                        .constant(bits - 1)
                        .op(code::I64_SHR_U);
                    b.constant(1).op(code::I64_AND);
                    b.load(Body::scratch(1)).constant(bits).op(code::I64_LT_U);
                    b.op(code::SELECT);
                }
            }
        });

        // scratch 4 : le débordement. Défini pour un décalage de un seulement ;
        // ailleurs le masque de l'oracle l'ignore, et inventer une valeur
        // serait inventer une règle.
        body.store(Body::scratch(4), |b| match step.op {
            Op::Shl => {
                b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
                b.load(Body::scratch(3)).op(code::I64_XOR);
            }
            Op::Shr => {
                // Le bit de signe **d'origine** : c'est lui qui disparaît.
                b.load(Body::scratch(0)).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
            }
            _ => {
                b.constant(0);
            }
        });

        // Les drapeaux, puis le choix.
        body.store(RFLAGS_SLOT, |b| {
            // Le nouvel état.
            b.load(RFLAGS_SLOT)
                .constant(!(CF | PF | AF | ZF | SF | OF))
                .op(code::I64_AND);

            b.load(Body::scratch(2)).op(code::I64_EQZ);
            b.op(code::I64_EXTEND_I32_U)
                .constant(ZF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);

            b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
            b.constant(SF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            b.load(Body::scratch(2)).constant(0xff).op(code::I64_AND);
            b.op(code::I64_POPCNT).constant(1).op(code::I64_AND);
            b.constant(1).op(code::I64_XOR);
            b.constant(PF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            b.load(Body::scratch(3))
                .constant(CF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);
            b.load(Body::scratch(4)).constant(1).op(code::I64_AND);
            b.constant(OF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            // L'ancien, et le choix : **un compte nul ne touche à rien**.
            b.load(RFLAGS_SLOT);
            b.load(Body::scratch(1)).constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });

        // **Un compte nul ne change aucun drapeau — mais il écrit quand même.**
        // C'est la règle qui manquait aux deux cœurs : `shll %cl, %eax` avec
        // `cl` à zéro laisse `eax` tel quel *et* efface les trente-deux bits
        // de poids fort, parce que toute écriture 32 bits les efface. C'est
        // l'écriture ci-dessous qui la tient : elle a lieu quel que soit le
        // compte, avec la règle de largeur.
        //
        // Il y avait ici un `select` qui reprenait l'opérande quand le compte
        // était nul. Un sabotage l'a retiré sans faire tomber un seul cas, et
        // c'est juste : décaler de zéro un opérande déjà masqué **rend cet
        // opérande**, pour les trois décalages. Le choix ne choisissait rien.
        if !step.discards {
            body.store(slot, |b| {
                // Le nouveau contenu du registre, règle de largeur comprise.
                if step.dst_high {
                    b.load(slot).constant(!0xff00u64).op(code::I64_AND);
                    b.load(Body::scratch(2)).constant(0xff).op(code::I64_AND);
                    b.constant(8).op(code::I64_SHL).op(code::I64_OR);
                } else {
                    match width {
                        Width::Qword | Width::Dword => {
                            b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                        }
                        _ => {
                            b.load(slot).constant(!mask).op(code::I64_AND);
                            b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                            b.op(code::I64_OR);
                        }
                    }
                }
            });
        }
    }

    fn flags(step: &Decoded, mask: u64, sign: u64, body: &mut Body) {
        // Ce qui survit : tout sauf les six bits arithmétiques, plus la retenue
        // quand `inc` ou `dec` doit la préserver.
        let preserved = if matches!(step.op, Op::Inc | Op::Dec) {
            !(PF | AF | ZF | SF | OF)
        } else {
            !(CF | PF | AF | ZF | SF | OF)
        };

        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT).constant(preserved).op(code::I64_AND);

            // ZF
            b.load(Body::scratch(2)).op(code::I64_EQZ);
            b.op(code::I64_EXTEND_I32_U)
                .constant(ZF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);

            // SF
            b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
            b.constant(SF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            // PF : la parité de l'octet de poids faible, un legs du 8080 que le
            // vrai processeur applique toujours.
            b.load(Body::scratch(2)).constant(0xff).op(code::I64_AND);
            b.op(code::I64_POPCNT).constant(1).op(code::I64_AND);
            b.constant(1).op(code::I64_XOR);
            b.constant(PF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            // AF : la même identité pour l'addition et la soustraction, parce
            // que a - b, c'est a + (-b).
            b.load(Body::scratch(0))
                .load(Body::scratch(1))
                .op(code::I64_XOR);
            b.load(Body::scratch(2)).op(code::I64_XOR);
            b.constant(0x10).op(code::I64_AND);
            b.constant(AF.trailing_zeros() as u64 - 4).op(code::I64_SHL);
            b.op(code::I64_OR);

            Self::carry_and_overflow(step, mask, sign, b);
        });
    }

    fn carry_and_overflow(step: &Decoded, _mask: u64, sign: u64, b: &mut Body) {
        let shift_to = |bit: u64| bit.trailing_zeros() as u64;
        match step.op {
            Op::And | Op::Or | Op::Xor | Op::Test => {}
            Op::Add | Op::Adc => {
                // CF : le résultat est passé sous l'opérande de gauche.
                b.load(Body::scratch(2))
                    .load(Body::scratch(0))
                    .op(code::I64_LT_U);
                b.op(code::I64_EXTEND_I32_U);
                // `adc` avec une retenue entrante : l'égalité compte aussi.
                if step.op == Op::Adc {
                    b.load(Body::scratch(2))
                        .load(Body::scratch(0))
                        .op(code::I64_SUB);
                    b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                    b.load(RFLAGS_SLOT).constant(CF).op(code::I64_AND);
                    b.op(code::I64_AND).op(code::I64_OR);
                    b.constant(1).op(code::I64_AND);
                }
                b.constant(shift_to(CF)).op(code::I64_SHL).op(code::I64_OR);
                // OF
                b.load(Body::scratch(0))
                    .load(Body::scratch(2))
                    .op(code::I64_XOR);
                b.load(Body::scratch(1))
                    .load(Body::scratch(2))
                    .op(code::I64_XOR);
                b.op(code::I64_AND).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
                b.constant(shift_to(OF)).op(code::I64_SHL).op(code::I64_OR);
            }
            Op::Sub | Op::Cmp | Op::Sbb | Op::Neg => {
                b.load(Body::scratch(0))
                    .load(Body::scratch(1))
                    .op(code::I64_LT_U);
                b.op(code::I64_EXTEND_I32_U);
                if step.op == Op::Sbb {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_SUB);
                    b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                    b.load(RFLAGS_SLOT).constant(CF).op(code::I64_AND);
                    b.op(code::I64_AND).op(code::I64_OR);
                    b.constant(1).op(code::I64_AND);
                }
                b.constant(shift_to(CF)).op(code::I64_SHL).op(code::I64_OR);
                b.load(Body::scratch(0))
                    .load(Body::scratch(1))
                    .op(code::I64_XOR);
                b.load(Body::scratch(0))
                    .load(Body::scratch(2))
                    .op(code::I64_XOR);
                b.op(code::I64_AND).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
                b.constant(shift_to(OF)).op(code::I64_SHL).op(code::I64_OR);
            }
            Op::Inc => {
                b.load(Body::scratch(0))
                    .load(Body::scratch(2))
                    .op(code::I64_XOR);
                b.constant(1).load(Body::scratch(2)).op(code::I64_XOR);
                b.op(code::I64_AND).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
                b.constant(shift_to(OF)).op(code::I64_SHL).op(code::I64_OR);
            }
            Op::Dec => {
                b.load(Body::scratch(0)).constant(1).op(code::I64_XOR);
                b.load(Body::scratch(0))
                    .load(Body::scratch(2))
                    .op(code::I64_XOR);
                b.op(code::I64_AND).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
                b.constant(shift_to(OF)).op(code::I64_SHL).op(code::I64_OR);
            }
            Op::Not => {}
            // Traités par `shift` et `transfer`, qui sortent avant d'arriver
            // ici. Les transferts, eux, ne posent **aucun** drapeau.
            Op::Shl | Op::Shr | Op::Sar | Op::Mov | Op::Movsx | Op::Rol | Op::Ror | Op::Lea => {}
        }
    }

    /// **`lea`, c'est-à-dire une addition qui a l'air d'un accès mémoire.**
    ///
    /// Rien n'est lu ni écrit en mémoire invitée : l'adresse elle-même est le
    /// résultat. L'échelle est une puissance de deux, donc un décalage, et la
    /// somme boucle sur soixante-quatre bits — c'est ainsi que se codent les
    /// index négatifs.
    fn lea(step: &Decoded, body: &mut Body) -> Option<()> {
        let address = step.memory?;
        body.store(Body::scratch(2), |b| {
            b.constant(address.displacement as u64);
            if let Some(base) = address.base {
                b.load(Self::slot(base)).op(code::I64_ADD);
            }
            if let Some(index) = address.index {
                b.load(Self::slot(index));
                b.constant(u64::from(address.scale.trailing_zeros()))
                    .op(code::I64_SHL);
                b.op(code::I64_ADD);
            }
            b.constant(step.width.mask()).op(code::I64_AND);
        });
        Self::write_back(step, step.width.mask(), body);
        Some(())
    }

    /// **Une rotation, traduite sans branchement.**
    ///
    /// Deux règles la séparent d'un décalage. La première : rien ne se perd,
    /// donc le zéro, le signe et la parité du résultat ne disent rien de plus
    /// que ceux de l'opérande — l'architecture les déclare **non affectés**, et
    /// seuls CF et OF sont réécrits. La seconde : la retenue se lit sur le
    /// **résultat**, pas sur un dernier bit sorti. C'est ce qui rend juste le
    /// cas où le compte n'est pas nul mais le tour est complet : `rolb $8, %al`
    /// laisse l'octet tel quel et pose quand même CF sur son bit bas.
    fn rotate(step: &Decoded, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let sign = width.sign();
        let bits = width.bits();
        let count_mask: u64 = if width == Width::Qword { 63 } else { 31 };

        // scratch 0 : l'opérande. scratch 1 : le compte masqué.
        body.store(Body::scratch(0), |b| {
            Self::left(step, b);
        });
        body.store(Body::scratch(1), |b| {
            if step.count_is_cl {
                b.load(Self::slot(1));
            } else {
                b.constant(step.imm);
            }
            b.constant(count_mask).op(code::I64_AND);
        });
        // scratch 5 : le compte ramené dans la largeur.
        body.store(Body::scratch(5), |b| {
            b.load(Body::scratch(1)).constant(bits).op(code::I64_REM_U);
        });

        // scratch 2 : le résultat. Le décalage complémentaire vaut `bits` quand
        // le tour est complet, et WebAssembly masque tout compte de décalage à
        // six bits : pour une largeur plus courte que soixante-quatre l'opérande
        // masqué rend zéro de ce côté, et pour soixante-quatre le masque ramène
        // à zéro et rend l'opérande. Les deux cas tombent juste sans un test.
        body.store(Body::scratch(2), |b| {
            let (first, second) = match step.op {
                Op::Rol => (code::I64_SHL, code::I64_SHR_U),
                _ => (code::I64_SHR_U, code::I64_SHL),
            };
            b.load(Body::scratch(0)).load(Body::scratch(5)).op(first);
            b.load(Body::scratch(0));
            b.constant(bits).load(Body::scratch(5)).op(code::I64_SUB);
            b.op(second);
            b.op(code::I64_OR).constant(mask).op(code::I64_AND);
        });

        // scratch 3 : la retenue, lue **sur le résultat**.
        body.store(Body::scratch(3), |b| match step.op {
            Op::Rol => {
                b.load(Body::scratch(2)).constant(1).op(code::I64_AND);
            }
            _ => {
                b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
            }
        });

        // scratch 4 : le débordement. Défini pour un cran seulement ; ailleurs
        // le masque de l'oracle l'ignore.
        body.store(Body::scratch(4), |b| {
            // Le bit de tête du résultat, dans les deux cas.
            b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
            match step.op {
                // À gauche : le désaccord entre ce bit et la retenue.
                Op::Rol => {
                    b.load(Body::scratch(3));
                }
                // À droite : le désaccord entre les deux bits de tête.
                _ => {
                    b.load(Body::scratch(2))
                        .constant(bits - 2)
                        .op(code::I64_SHR_U);
                    b.constant(1).op(code::I64_AND);
                }
            }
            b.op(code::I64_XOR);
        });

        // Les drapeaux : **CF et OF seulement**, et rien si le compte est nul.
        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT).constant(!(CF | OF)).op(code::I64_AND);
            b.load(Body::scratch(3))
                .constant(CF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);
            b.load(Body::scratch(4)).constant(1).op(code::I64_AND);
            b.constant(OF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            b.load(RFLAGS_SLOT);
            b.load(Body::scratch(1)).constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });

        // Un compte nul n'écrit aucun drapeau mais écrit bien la destination,
        // et c'est l'écriture ci-dessous qui le tient. Pas de `select` sur la
        // valeur : tourner de zéro rend l'opérande, et tourner d'un tour
        // complet aussi.
        if !step.discards {
            Self::write_back(step, mask, body);
        }
    }

    /// **Un transfert : lire à une largeur, écrire à une autre.**
    ///
    /// L'extension de signe se fait sans branchement, par le tour classique :
    /// décaler à gauche pour amener le bit de signe en position 63, puis
    /// décaler à droite **arithmétiquement**. WebAssembly n'a pas d'opérateur
    /// « étendre en signe depuis n bits » pour une largeur quelconque, mais il
    /// a `i64.shr_s`, et deux décalages font le même travail sans test.
    fn transfer(step: &Decoded, body: &mut Body) {
        body.store(Body::scratch(2), |b| {
            b.load(Self::slot(step.src));
            if step.src_high {
                b.constant(8).op(code::I64_SHR_U);
            }
            b.constant(step.src_width.mask()).op(code::I64_AND);
            if step.op == Op::Movsx {
                let spare = 64 - step.src_width.bits();
                if spare != 0 {
                    b.constant(spare).op(code::I64_SHL);
                    b.constant(spare).op(code::I64_SHR_S);
                }
            }
        });
        // La règle d'écriture est celle de tout le monde : une destination de
        // 32 bits efface la moitié haute, une de 8 ou 16 préserve le reste.
        Self::write_back(step, step.width.mask(), body);
    }

    /// **La règle que tout le monde oublie** : une écriture 32 bits efface les
    /// trente-deux bits de poids fort, alors qu'une écriture 8 ou 16 bits
    /// préserve le reste du registre.
    fn write_back(step: &Decoded, mask: u64, body: &mut Body) {
        let slot = Self::slot(step.dst);
        body.store(slot, |b| {
            if step.dst_high {
                b.load(slot).constant(!0xff00u64).op(code::I64_AND);
                b.load(Body::scratch(2)).constant(0xff).op(code::I64_AND);
                b.constant(8).op(code::I64_SHL).op(code::I64_OR);
                return;
            }
            match step.width {
                Width::Qword | Width::Dword => {
                    b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                }
                _ => {
                    b.load(slot).constant(!mask).op(code::I64_AND);
                    b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                    b.op(code::I64_OR);
                }
            }
        });
    }
}
