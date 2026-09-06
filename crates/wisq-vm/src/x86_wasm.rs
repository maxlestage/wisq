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

use crate::x86::{
    decode, Address, BitAction, CarryAction, Condition, Decoded, Op, Width, AF, CF, DF, OF, PF, SF,
    ZF,
};

/// Seize registres, puis RFLAGS, puis les emplacements de travail. L'indice est
/// celui de la globale exportée.
pub const RFLAGS_SLOT: usize = 16;
/// Les emplacements de travail : la traduction s'en sert au lieu de variables
/// locales. Il y en a six — le sixième porte le compte d'une rotation ramené
/// dans la largeur.
/// **Où l'exécution s'est arrêtée.** Une région ne va pas jusqu'au bout du
/// programme : elle rend la main quand un saut sort de ce qu'elle connaît, ou
/// quand le budget est épuisé. Sans cette globale, l'hôte saurait qu'elle s'est
/// arrêtée mais pas où reprendre.
pub const RIP_SLOT: usize = RFLAGS_SLOT + 1;
/// **La base du segment GS**, que l'hôte pose et que le module lit.
///
/// Elle est une globale importée comme les registres, et pour la même raison :
/// le module ne peut pas la connaître à la compilation. Un noyau l'installe une
/// fois par cœur, très tôt, puis n'y touche plus — mais « très tôt » est déjà
/// après que la première région a été traduite, et une constante figée dans le
/// code rendrait cette région fausse dès l'installation suivante.
pub const GS_SLOT: usize = RIP_SLOT + 1;
pub const SCRATCH_SLOT: usize = GS_SLOT + 1;
pub const SCRATCH_COUNT: usize = 10;
/// Le nombre de globales que le module déclare et exporte.
pub const GLOBAL_COUNT: usize = SCRATCH_SLOT + SCRATCH_COUNT;

/// Le nombre de pages de RAM invitée que le module déclare. Assez pour couvrir
/// la fenêtre de données du corpus matériel, qui vit à 0x30001000.
pub const GUEST_PAGES: u32 = 0x3001;

/// **La boucle que les bancs mesurent, écrite une seule fois.**
///
/// ```text
/// 1: addq %rax, %rdx
///    xorq %rcx, %rbx
///    addq %rdx, %rax
///    subq $1, %rsi
///    jnz 1b
/// ```
///
/// Cinq instructions, parce que c'est la taille moyenne d'un bloc de base
/// relevée en désassemblant le noyau Alpine : une boucle d'une seule
/// instruction mesurerait le coût du saut, pas celui du calcul. Les quatre
/// premières posent des drapeaux que personne ne lit, sauf la dernière — le cas
/// où les drapeaux paresseux de l'interpréteur rapportent, et où le module doit
/// les calculer.
///
/// **Elle vit ici, et pas dans le banc, parce que trois programmes la
/// mesurent** : l'exemple `speed`, la sonde WebKit de l'application, et le test
/// qui épingle l'une sur l'autre. Trois copies dériveraient, et l'iPhone
/// rendrait alors un chiffre qu'on croirait comparable à celui de la CI.
pub const BENCH_LOOP: [u8; 15] = [
    0x48, 0x01, 0xc2, // addq %rax, %rdx
    0x48, 0x31, 0xcb, // xorq %rcx, %rbx
    0x48, 0x01, 0xd0, // addq %rdx, %rax
    0x48, 0x83, 0xee, 0x01, // subq $1, %rsi
    0x75, 0xf1, // jnz 1b
];

/// L'adresse invitée où le banc charge la boucle. Elle n'est pas décorative :
/// l'émetteur y fige les adresses de retour et les sauts.
pub const BENCH_BASE: u64 = 0x3000_0000;

/// Combien d'instructions un tour de la boucle exécute.
pub const BENCH_PER_TURN: u64 = 5;

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
    /// Les accès à la mémoire linéaire — **la RAM de l'invité, adresse pour
    /// adresse**. Les variantes courtes étendent par zéro ; l'extension de
    /// signe, quand une instruction la demande, se fait après coup, parce que
    /// x86 la demande depuis la largeur de la source et pas depuis huit octets.
    pub const I32_CONST: u8 = 0x41;
    pub const I64_LOAD: u8 = 0x29;
    pub const I64_LOAD8_U: u8 = 0x31;
    pub const I64_LOAD16_U: u8 = 0x33;
    pub const I64_LOAD32_U: u8 = 0x35;
    pub const I64_STORE: u8 = 0x37;
    pub const I64_STORE8: u8 = 0x3c;
    pub const I64_STORE16: u8 = 0x3d;
    pub const I64_STORE32: u8 = 0x3e;
    /// Une adresse WebAssembly est un `i32`. L'adresse x86 est calculée sur
    /// soixante-quatre bits, donc elle se tronque — ce qui est juste tant que
    /// la RAM invitée tient sous quatre gigaoctets, et faux au-delà. La
    /// tranche qui dépassera cette limite devra passer en mémoire 64 bits.
    pub const I32_WRAP_I64: u8 = 0xa7;
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
    pub const I64_CLZ: u8 = 0x79;
    pub const I64_CTZ: u8 = 0x7a;
    pub const I64_EXTEND_I32_U: u8 = 0xad;
    pub const I64_SHR_S: u8 = 0x87;
    pub const I64_NE: u8 = 0x52;
    pub const I64_LE_U: u8 = 0x58;
    /// Le reste d'une division non signée. C'est ce qui ramène un compte de
    /// rotation à l'intérieur de la largeur — tourner un octet de neuf crans
    /// revient à le tourner d'un.
    pub const I64_REM_U: u8 = 0x82;
    pub const I64_EQ: u8 = 0x51;
    pub const I64_LT_S: u8 = 0x53;
    pub const I64_GT_S: u8 = 0x55;
    pub const I64_GT_U: u8 = 0x56;
    pub const I64_MUL: u8 = 0x7e;
    pub const I64_DIV_S: u8 = 0x7f;
    pub const I64_DIV_U: u8 = 0x80;
    pub const I64_REM_S: u8 = 0x81;
    /// `if` sans résultat, et `return`. Ce sont les deux qui permettent à un
    /// bloc de **rendre la main au milieu** — ce dont la division a besoin
    /// quand elle refuse de diviser.
    pub const IF: u8 = 0x04;
    pub const VOID: u8 = 0x40;
    pub const RETURN: u8 = 0x0f;
    /// `select` prend deux valeurs et une condition, et rend la première quand
    /// la condition est vraie. C'est ce qui permet de traduire « un compte nul
    /// ne change rien » **sans branchement** : on calcule tout, puis on choisit.
    pub const SELECT: u8 = 0x1b;
}

/// Un `cmpxchg` vu comme la comparaison qu'il porte : c'est sous cette forme
/// que la routine des drapeaux sait le lire.
fn as_compare(step: &Decoded) -> Decoded {
    Decoded {
        op: Op::Cmp,
        ..*step
    }
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

    /// Pousser l'adresse effective, en `i32`, prête pour un accès mémoire.
    fn address(&mut self, address: &Address) -> &mut Self {
        self.wide_address(address);
        self.op(code::I32_WRAP_I64)
    }

    /// **La même adresse, laissée en `i64`.** La chaîne de bits en a besoin
    /// entière : elle lui ajoute un déplacement de mot **signé**, calculé à
    /// l'exécution, et tronquer avant cette addition la ferait déborder dans
    /// les trente-deux bits bas.
    fn wide_address(&mut self, address: &Address) -> &mut Self {
        self.constant(address.displacement as u64);
        // **La base du segment, lue à l'exécution.** Elle ne peut pas être
        // repliée dans le déplacement : la région est compilée une fois, et
        // l'hôte peut poser une autre base entre deux entrées.
        if address.gs {
            self.load(GS_SLOT).op(code::I64_ADD);
        }
        if let Some(base) = address.base {
            self.load(base as usize).op(code::I64_ADD);
        }
        if let Some(index) = address.index {
            self.load(index as usize);
            self.constant(u64::from(address.scale.trailing_zeros()))
                .op(code::I64_SHL);
            self.op(code::I64_ADD);
        }
        self
    }

    /// **Lire la mémoire à une adresse déjà calculée**, gardée dans une
    /// globale de travail. La chaîne de bits ne peut pas passer par `Address` :
    /// son adresse dépend d'un registre lu à l'exécution.
    fn load_at(&mut self, slot: usize, width: Width) -> &mut Self {
        self.load(slot).op(code::I32_WRAP_I64);
        self.op(match width {
            Width::Byte => code::I64_LOAD8_U,
            Width::Word => code::I64_LOAD16_U,
            Width::Dword => code::I64_LOAD32_U,
            Width::Qword => code::I64_LOAD,
        });
        self.bytes.push(0);
        self.bytes.push(0);
        self
    }

    /// Et l'écriture qui lui répond.
    fn store_at(&mut self, slot: usize, width: Width, value: impl FnOnce(&mut Body)) -> &mut Self {
        self.load(slot).op(code::I32_WRAP_I64);
        value(self);
        self.op(match width {
            Width::Byte => code::I64_STORE8,
            Width::Word => code::I64_STORE16,
            Width::Dword => code::I64_STORE32,
            Width::Qword => code::I64_STORE,
        });
        self.bytes.push(0);
        self.bytes.push(0);
        self
    }

    /// Lire la mémoire invitée à cette adresse, à cette largeur, **étendue par
    /// zéro**. L'extension de signe, quand `movsx` la demande, se fait après.
    fn load_memory(&mut self, address: &Address, width: Width) -> &mut Self {
        self.address(address);
        self.op(match width {
            Width::Byte => code::I64_LOAD8_U,
            Width::Word => code::I64_LOAD16_U,
            Width::Dword => code::I64_LOAD32_U,
            Width::Qword => code::I64_LOAD,
        });
        // Alignement zéro : le module n'exige rien, et un invité aligne ce
        // qu'il veut. Prétendre un alignement que l'invité ne tient pas ferait
        // refuser le module par le moteur.
        self.bytes.push(0);
        self.bytes.push(0);
        self
    }

    /// Écrire la mémoire invitée. **L'adresse d'abord, la valeur ensuite** —
    /// l'ordre de WebAssembly, et l'inverser produit un module que le moteur
    /// refuse.
    fn store_memory(
        &mut self,
        address: &Address,
        width: Width,
        value: impl FnOnce(&mut Body),
    ) -> &mut Self {
        self.address(address);
        value(self);
        self.op(match width {
            Width::Byte => code::I64_STORE8,
            Width::Word => code::I64_STORE16,
            Width::Dword => code::I64_STORE32,
            Width::Qword => code::I64_STORE,
        });
        self.bytes.push(0);
        self.bytes.push(0);
        self
    }
}

/// Le module émis pour un bloc.
pub struct Module;

impl Module {
    /// Émettre un module qui exécute ce bloc, ou `None` si une instruction
    /// n'est pas traduisible. **Refuser plutôt que produire du code faux** :
    /// un bloc à moitié traduit rendrait un état que rien ne distingue d'un
    /// état juste.
    /// **Compiler une région : tous les blocs atteignables depuis le début.**
    ///
    /// Un module WebAssembly n'a pas de saut arbitraire. Deux conceptions s'y
    /// prêtent, et le choix a été **mesuré** plutôt que débattu :
    ///
    /// - un module par bloc de base, l'hôte enchaînant : 62,6 ns par bloc sous
    ///   JavaScriptCore, dans sa meilleure forme (globale `i32`, tableau
    ///   dense). À 5,3 instructions par bloc — la moyenne relevée en
    ///   désassemblant le vrai noyau Alpine — c'est **85 MIPS de plafond**,
    ///   avant d'exécuter la moindre instruction. Moins que l'interpréteur
    ///   Rust. Tout l'intérêt de passer par WebKit s'évapore.
    /// - une fonction par bloc **dans le même module**, et la boucle de
    ///   répartition à l'intérieur : **2,05 ns par bloc**. Trente fois moins.
    ///
    /// C'est donc la seconde. Chaque bloc est une fonction qui rend l'indice du
    /// bloc suivant, ou -1 pour rendre la main ; `run` les enchaîne par un
    /// `call_indirect` dans une table, sous un budget de pas.
    ///
    /// `base` est l'adresse **de l'invité** où cette région est chargée. Elle
    /// n'est pas décorative : `call` empile une adresse de retour, et `ret` la
    /// relit. Compiler la région comme si elle vivait à zéro empilerait un
    /// nombre que rien, dans la mémoire de l'invité, ne désigne.
    pub fn region(bytes: &[u8], base: u64, entry: usize) -> Option<Vec<u8>> {
        let blocks = Self::discover(bytes, entry)?;
        let index = |offset: usize| blocks.iter().position(|(start, _)| *start == offset);
        let starts: Vec<u64> = blocks
            .iter()
            .map(|(start, _)| base.wrapping_add(*start as u64))
            .collect();

        let mut bodies: Vec<Vec<u8>> = Vec::new();
        for (start, steps) in &blocks {
            let mut body = Body::default();
            let mut at = *start;
            for step in steps {
                // **L'adresse de l'instruction elle-même**, pas celle de la
                // suivante : une division qui refuse doit y renvoyer l'hôte.
                let here = base.wrapping_add(at as u64);
                at += step.length;
                // **Le saut final n'est pas traduit comme les autres.** Il ne
                // change pas l'état de la machine mais le bloc courant, et
                // c'est `terminate` qui sait le dire — lui seul connaît les
                // autres blocs.
                if matches!(
                    step.op,
                    Op::Jump(_)
                        | Op::LoopWhile
                        | Op::JumpIndirect
                        | Op::Call
                        | Op::CallIndirect
                        | Op::Return
                        | Op::Undefined
                ) {
                    continue;
                }
                Self::translate(&Self::pin(step, here), here, &mut body)?;
            }
            Self::terminate(steps.last(), base, at, &index, &starts, &mut body);
            body.op(code::END);
            bodies.push(body.bytes);
        }
        Some(Self::assemble(bodies))
    }

    /// **Une adresse relative au pointeur d'instruction est une constante** —
    /// dès qu'on sait où l'instruction est posée, et l'émetteur le sait.
    ///
    /// C'est ce que fait un vrai compilateur à la volée : le déplacement se
    /// compte depuis l'octet qui **suit** l'instruction, cette adresse est
    /// connue à la compilation, donc le calcul disparaît. C'est le seul mode
    /// d'adressage qui ne coûte rien à l'exécution — et le seul dont l'erreur
    /// d'un octet ne se voit nulle part ailleurs qu'en la comparant au
    /// silicium.
    fn pin(step: &Decoded, here: u64) -> Decoded {
        match step.memory {
            Some(address) if address.relative => {
                let after = here.wrapping_add(step.length as u64);
                Decoded {
                    memory: Some(Address {
                        base: None,
                        index: None,
                        scale: 1,
                        displacement: after.wrapping_add(address.displacement as u64) as i64,
                        relative: false,
                        // **Le segment survit au figeage.** Figer résout le
                        // déplacement, pas la base : `%gs:x(%rip)` reste une
                        // adresse à laquelle la base du segment s'ajoutera.
                        gs: address.gs,
                    }),
                    ..*step
                }
            }
            _ => *step,
        }
    }

    /// **Le parcours du graphe**, et pourquoi ce n'est pas une boucle sur les
    /// octets. Un `jmp` en arrière repasse sur du code déjà lu, un `jcc` ouvre
    /// deux suites, et l'octet qui suit un saut inconditionnel peut n'être
    /// atteint par personne — le décoder comme du code refuserait une région
    /// parfaitement exécutable.
    #[allow(clippy::type_complexity)]
    fn discover(bytes: &[u8], entry: usize) -> Option<Vec<(usize, Vec<Decoded>)>> {
        let mut starts = std::collections::BTreeSet::new();
        let mut queue = vec![entry];
        let mut blocks: std::collections::BTreeMap<usize, Vec<Decoded>> =
            std::collections::BTreeMap::new();
        while let Some(start) = queue.pop() {
            if start >= bytes.len() || !starts.insert(start) {
                continue;
            }
            let mut steps = Vec::new();
            let mut at = start;
            loop {
                if at >= bytes.len() {
                    break;
                }
                let step = decode(&bytes[at..])?;
                at += step.length;
                let ends = matches!(
                    step.op,
                    Op::Jump(_)
                        | Op::LoopWhile
                        | Op::JumpIndirect
                        | Op::Call
                        | Op::CallIndirect
                        | Op::Return
                        | Op::Undefined
                );
                let displacement = step.imm as i64;
                // **Ce qui suit un `call` est atteignable, et par une seule
                // route : le `ret` qui lui répond.** Ne pas le mettre dans la
                // file laissait l'appelé sans retour possible — le module
                // rendait la main au lieu de continuer. `jmp` est le seul à
                // n'avoir pas de suite ; `ret`, lui, n'a pas de cible connue
                // d'avance, et sa suite n'est atteignable que par ailleurs.
                // **Rien ne suit un `ud2`.** L'exécution n'en revient pas, donc
                // les octets d'après ne sont pas atteignables par cette route ;
                // les mettre dans la file ferait décoder, et refuser, ce qu'un
                // noyau range là — souvent des données de sa table de bogues.
                let falls = !matches!(step.op, Op::Jump(None) | Op::Return | Op::Undefined);
                let jumps = !matches!(step.op, Op::Return | Op::Undefined);
                steps.push(step);
                if !ends {
                    continue;
                }
                let target = at as i64 + displacement;
                if jumps && (0..bytes.len() as i64).contains(&target) {
                    queue.push(target as usize);
                }
                if falls && at < bytes.len() {
                    queue.push(at);
                }
                break;
            }
            if steps.is_empty() {
                continue;
            }
            blocks.insert(start, steps);
        }
        if blocks.is_empty() {
            return None;
        }
        Some(blocks.into_iter().collect())
    }

    /// **Ce qu'un bloc fait à la fin : dire où aller.**
    ///
    /// Il pose l'indice du bloc suivant — ou -1 pour rendre la main — et, dans
    /// tous les cas, l'endroit où l'exécution en est. Rendre la main sans dire
    /// où reprendre laisserait l'hôte avec une machine dont il ne sait plus
    /// quoi faire.
    fn terminate(
        last: Option<&Decoded>,
        base: u64,
        after: usize,
        index: &impl Fn(usize) -> Option<usize>,
        starts: &[u64],
        body: &mut Body,
    ) {
        // Deux valeurs à poser : l'adresse d'arrivée et l'indice du bloc.
        // `sortie` vaut -1 quand la cible n'est pas dans la région.
        let place = |body: &mut Body, offset: i64| {
            body.store(RIP_SLOT, |b| {
                b.constant(base.wrapping_add(offset as u64));
            });
            let next = match usize::try_from(offset).ok().and_then(&index) {
                Some(block) => block as i64,
                None => -1,
            };
            body.bytes.push(code::I32_CONST);
            signed(next, &mut body.bytes);
        };

        let Some(step) = last else {
            place(body, after as i64);
            return;
        };
        let target = after as i64 + step.imm as i64;
        // **L'opérande d'une forme indirecte, poussé sur la pile WebAssembly.**
        // Un registre, ou huit octets de mémoire — et cette mémoire peut être
        // relative au pointeur d'instruction, ce dont un noyau est fait : une
        // table de sauts s'atteint comme ça. `pin` résout ce déplacement depuis
        // l'adresse de **cette** instruction, qui est celle d'après moins sa
        // longueur.
        let here = base.wrapping_add(after.wrapping_sub(step.length) as u64);
        let pinned = Self::pin(step, here);
        let reach = move |b: &mut Body| match pinned.memory {
            Some(address) => {
                b.load_memory(&address, Width::Qword);
            }
            None => {
                b.load(Self::slot(pinned.dst));
            }
        };
        match step.op {
            Op::Jump(None) => place(body, target),
            Op::Jump(Some(condition)) => {
                // Les deux issues sont calculées, puis choisies. L'adresse
                // aussi : elle diffère selon la branche prise.
                body.store(RIP_SLOT, |b| {
                    b.constant(base.wrapping_add(target as u64));
                    b.constant(base.wrapping_add(after as u64));
                    Self::condition(condition, b);
                    b.op(code::I32_WRAP_I64).op(code::SELECT);
                });
                Self::choose(body, target, after as i64, index, |b| {
                    Self::condition(condition, b);
                });
            }
            Op::LoopWhile => {
                // `loop` décrémente RCX **sans poser de drapeau**, et saute
                // tant qu'il n'est pas nul. Le confondre avec `dec` puis `jnz`
                // écraserait cinq drapeaux que le processeur préserve.
                body.store(Self::slot(1), |b| {
                    b.load(Self::slot(1)).constant(1).op(code::I64_SUB);
                });
                body.store(RIP_SLOT, |b| {
                    b.constant(base.wrapping_add(target as u64));
                    b.constant(base.wrapping_add(after as u64));
                    b.load(Self::slot(1)).constant(0).op(code::I64_NE);
                    b.op(code::SELECT);
                });
                Self::choose(body, target, after as i64, index, |b| {
                    b.load(Self::slot(1)).constant(0).op(code::I64_NE);
                    b.op(code::I64_EXTEND_I32_U);
                });
            }
            Op::Undefined => {
                // **Rendre la main sur elle, pas après.** Le processeur laisse
                // le pointeur d'instruction sur le `ud2` en levant son
                // exception ; l'hôte doit voir la même chose, sans quoi il
                // reprendrait à l'octet suivant, qui n'est pas du code.
                body.store(RIP_SLOT, |b| {
                    b.constant(here);
                });
                body.bytes.push(code::I32_CONST);
                signed(-1, &mut body.bytes);
            }
            Op::JumpIndirect => {
                body.store(RIP_SLOT, reach);
                Self::resolve(starts, body);
            }
            Op::CallIndirect => {
                // **La cible est lue avant que la pile ne bouge.** L'ordre
                // inverse marcherait tant que la cible n'est pas prise sur la
                // pile elle-même — et `call *-8(%rsp)` est écrivable.
                body.store(Body::scratch(0), reach);
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_SUB);
                });
                Self::at_top(body, |b| {
                    b.constant(base.wrapping_add(after as u64));
                });
                // La cible n'est pas connue à la compilation : si elle tombe
                // sur un bloc de la région, la boucle de répartition y va ;
                // sinon le module rend la main, et l'interpréteur reprend là.
                body.store(RIP_SLOT, |b| {
                    b.load(Body::scratch(0));
                });
                Self::resolve(starts, body);
            }
            Op::Call => {
                // L'adresse de retour est empilée ici — c'est la seule partie
                // de `call` qui touche l'état — puis le bloc change.
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_SUB);
                });
                Self::at_top(body, |b| {
                    b.constant(base.wrapping_add(after as u64));
                });
                place(body, target);
            }
            Op::Return => {
                // La cible sort de la pile : elle n'est connue qu'à
                // l'exécution. Le module la cherche parmi ses propres blocs, et
                // rend la main si elle n'en est pas un.
                body.store(RIP_SLOT, |b| {
                    b.load(Self::slot(4));
                    b.op(code::I32_WRAP_I64);
                    b.op(code::I64_LOAD);
                    b.bytes.push(0);
                    b.bytes.push(0);
                });
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_ADD);
                });
                Self::resolve(starts, body);
            }
            _ => place(body, after as i64),
        }
    }

    /// **Retrouver un bloc depuis une adresse connue seulement à l'exécution.**
    ///
    /// C'est ce dont `ret` et `jmp *%reg` ont besoin. Les adresses des blocs
    /// sont connues à la compilation, donc la recherche est une suite de
    /// comparaisons : la cible est-elle le bloc zéro, sinon le bloc un… et -1
    /// si elle n'est aucun d'eux, auquel cas le module rend la main et l'hôte
    /// compilera la région qui commence là.
    ///
    /// Linéaire, et c'est assez : une région a quelques blocs, pas mille. Le
    /// jour où elle en aura mille, ce sera une table de hachage — mais le dire
    /// avant de l'avoir mesuré serait deviner.
    fn resolve(starts: &[u64], body: &mut Body) {
        body.bytes.push(code::I32_CONST);
        signed(-1, &mut body.bytes);
        for (block, start) in starts.iter().enumerate() {
            body.bytes.push(code::I32_CONST);
            signed(block as i64, &mut body.bytes);
            // Échanger les deux : `select` rend la première quand la condition
            // tient, donc l'indice trouvé doit être poussé en dernier.
            body.load(RIP_SLOT).constant(*start).op(code::I64_NE);
            body.op(code::SELECT);
        }
    }

    /// Choisir entre deux indices de bloc selon un prédicat `i64`.
    fn choose(
        body: &mut Body,
        taken: i64,
        fallen: i64,
        index: &impl Fn(usize) -> Option<usize>,
        condition: impl FnOnce(&mut Body),
    ) {
        let resolve = |offset: i64| match usize::try_from(offset).ok().and_then(index) {
            Some(block) => block as i64,
            None => -1,
        };
        body.bytes.push(code::I32_CONST);
        signed(resolve(taken), &mut body.bytes);
        body.bytes.push(code::I32_CONST);
        signed(resolve(fallen), &mut body.bytes);
        condition(body);
        body.op(code::I32_WRAP_I64).op(code::SELECT);
    }

    /// **Le module : une fonction par bloc, plus la boucle qui les enchaîne.**
    fn assemble(bodies: Vec<Vec<u8>>) -> Vec<u8> {
        let count = bodies.len();
        let mut module = vec![0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];

        // Types : un bloc rend l'indice du suivant ; `run` prend un budget.
        section(
            1,
            vec![0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7e, 0x00],
            &mut module,
        );

        // **La mémoire et les registres viennent de l'hôte.**
        //
        // Un module qui les définit lui-même est une machine à lui tout seul :
        // deux régions compilées séparément ne partagent alors rien, et la
        // seule façon de passer de l'une à l'autre serait de recopier tout
        // l'état — huit cent mégaoctets de RAM invitée comprise. En les
        // **important**, l'hôte n'a plus qu'une RAM et qu'un fichier de
        // registres, et autant de régions qu'il en faut : quand un module rend
        // la main, la région suivante reprend exactement où il s'est arrêté.
        //
        // C'est ce qui rend l'interpréteur utilisable comme filet plutôt que
        // comme abandon, et c'est l'architecture de l'application.
        let mut imports = Vec::new();
        unsigned(1 + GLOBAL_COUNT as u64, &mut imports);
        let module_name = |bytes: &mut Vec<u8>| {
            unsigned(3, bytes);
            bytes.extend_from_slice(b"env");
        };
        module_name(&mut imports);
        unsigned(3, &mut imports);
        imports.extend_from_slice(b"mem");
        imports.push(0x02);
        imports.push(0x00);
        unsigned(u64::from(GUEST_PAGES), &mut imports);
        for slot in 0..GLOBAL_COUNT {
            module_name(&mut imports);
            let name = format!("g{slot}");
            unsigned(name.len() as u64, &mut imports);
            imports.extend_from_slice(name.as_bytes());
            // Une globale `i64`, **mutable** : le module y écrit.
            imports.extend_from_slice(&[0x03, 0x7e, 0x01]);
        }
        section(2, imports, &mut module);

        let mut functions = Vec::new();
        unsigned(count as u64 + 1, &mut functions);
        // Les `count` premières fonctions sont les blocs, du type zéro ; la
        // dernière est la boucle de répartition, du type un.
        functions.resize(functions.len() + count, 0x00);
        functions.push(0x01);
        section(3, functions, &mut module);

        // Table : les blocs, pour le `call_indirect` de la boucle.
        let mut table = vec![0x01, 0x70, 0x00];
        unsigned(count as u64, &mut table);
        section(4, table, &mut module);

        let mut exports = Vec::new();
        unsigned(1, &mut exports);
        exports.extend_from_slice(&[0x03, b'r', b'u', b'n', 0x00]);
        unsigned(count as u64, &mut exports);
        section(7, exports, &mut module);

        // Éléments : la table pointe les blocs dans l'ordre.
        let mut elements = vec![0x01, 0x00, code::I32_CONST, 0x00, code::END];
        unsigned(count as u64, &mut elements);
        for block in 0..count {
            unsigned(block as u64, &mut elements);
        }
        section(9, elements, &mut module);

        let mut code_section = Vec::new();
        unsigned(count as u64 + 1, &mut code_section);
        for body in &bodies {
            let mut entry = vec![0x00];
            entry.extend_from_slice(body);
            unsigned(entry.len() as u64, &mut code_section);
            code_section.extend_from_slice(&entry);
        }
        // La boucle : tant qu'il reste du budget, appeler le bloc courant et
        // prendre l'indice qu'il rend. Un indice négatif rend la main.
        let dispatch: Vec<u8> = vec![
            0x01,
            0x01,
            0x7f, // une locale i32 : le bloc courant
            0x02,
            0x40, // block
            0x03,
            0x40, //   loop
            0x20,
            0x00,
            code::I64_EQZ,
            0x0d,
            0x01, //     budget nul : sortir
            0x20,
            0x00,
            code::I64_CONST,
            0x01,
            code::I64_SUB,
            0x21,
            0x00,
            0x20,
            0x01,
            0x11,
            0x00,
            0x00,
            0x21,
            0x01, //   bloc = call_indirect(bloc)
            0x20,
            0x01,
            0x41,
            0x00,
            0x48,
            0x0d,
            0x01, //   négatif : rendre la main
            0x0c,
            0x00,      //     recommencer
            code::END, //   fin de la boucle
            code::END, // fin du bloc
            code::END, // fin de la fonction
        ];
        unsigned(dispatch.len() as u64, &mut code_section);
        code_section.extend_from_slice(&dispatch);
        section(10, code_section, &mut module);

        module
    }

    fn slot(register: u8) -> usize {
        register as usize
    }

    /// Pousser l'opérande de gauche, masqué à la largeur.
    fn left(step: &Decoded, body: &mut Body) {
        match step.memory {
            Some(address) if !step.memory_is_source => {
                body.load_memory(&address, step.width);
                return;
            }
            _ => {}
        }
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
        match step.memory {
            Some(address) if step.memory_is_source => {
                body.load_memory(&address, step.width);
                return;
            }
            _ => {}
        }
        body.load(Self::slot(step.src));
        if step.src_high {
            body.constant(8).op(code::I64_SHR_U);
        }
        body.constant(step.width.mask()).op(code::I64_AND);
    }

    fn translate(step: &Decoded, address: u64, body: &mut Body) -> Option<()> {
        // **Un saut n'est pas une instruction comme une autre** : il change le
        // bloc, pas l'état. Il est traité par le compilateur de région, qui
        // seul connaît les autres blocs ; en ligne droite, il n'a aucun sens.
        if matches!(
            step.op,
            Op::Jump(_) | Op::LoopWhile | Op::JumpIndirect | Op::CallIndirect | Op::Undefined
        ) {
            return None;
        }
        // Ne rien faire n'émet rien.
        if step.op == Op::Nop {
            return Some(());
        }
        // **Le drapeau de direction : un bit, posé en clair.**
        if let Op::DirectionFlag(set) = step.op {
            body.store(RFLAGS_SLOT, |b| {
                if set {
                    b.load(RFLAGS_SLOT).constant(DF).op(code::I64_OR);
                } else {
                    b.load(RFLAGS_SLOT).constant(!DF).op(code::I64_AND);
                }
            });
            return Some(());
        }
        if matches!(step.op, Op::StringMove { .. } | Op::StringStore { .. }) {
            return Self::string(step, address, body);
        }
        // La pile écrit **deux** choses — RSP et la mémoire, ou RSP et un
        // registre — et sort donc de la machinerie à une destination.
        if matches!(step.op, Op::Push | Op::Pop | Op::Leave) {
            Self::stack(step, body);
            return Some(());
        }
        // `call` et `ret` ne passent jamais par ici : `region` les laisse à
        // `terminate`, qui seul connaît les autres blocs. Les refuser garde ce
        // contrat vérifiable — si un jour l'un d'eux arrive ici, la région est
        // refusée plutôt que traduite à moitié.
        if step.op == Op::Call || step.op == Op::Return {
            return None;
        }
        if let Op::RotateThroughCarry { left } = step.op {
            Self::rotate_through_carry(step, left, body);
            return Some(());
        }
        if let Op::DoubleShift { left } = step.op {
            Self::double_shift(step, left, body);
            return Some(());
        }
        if matches!(
            step.op,
            Op::Exchange | Op::ExchangeAndAdd | Op::CompareAndExchange
        ) {
            Self::exchange(step, body);
            return Some(());
        }
        if matches!(
            step.op,
            Op::WideMultiply { .. }
                | Op::Multiply
                | Op::Divide { .. }
                | Op::WidenAccumulator
                | Op::SignIntoData
                | Op::CarryFlag(_)
        ) {
            Self::two_registers(step, address, body);
            return Some(());
        }
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
        // Les bits : chacun ses drapeaux, de la seule retenue à aucun.
        if let Op::Bit(action) = step.op {
            Self::bit(step, action, body);
            return Some(());
        }
        if let Op::BitScan { from_the_top } = step.op {
            Self::scan(step, from_the_top, body);
            return Some(());
        }
        if step.op == Op::Popcount {
            Self::popcount(step, body);
            return Some(());
        }
        if step.op == Op::ByteSwap {
            Self::byte_swap(step, body);
            return Some(());
        }
        // Les conditions : elles lisent les drapeaux et n'en écrivent aucun.
        if let Op::Set(condition) = step.op {
            body.store(Body::scratch(2), |b| Self::condition(condition, b));
            Self::write_back(step, step.width.mask(), body);
            return Some(());
        }
        if let Op::CondMove(condition) = step.op {
            body.store(Body::scratch(2), |b| {
                Self::right(step, b);
                Self::left(step, b);
                Self::condition(condition, b);
                // `select` prend la première valeur quand la condition tient :
                // la source si elle tient, la destination sinon. Et l'écriture
                // a lieu **dans les deux cas** — c'est ce qui fait qu'un
                // `cmov` de 32 bits efface la moitié haute même quand il ne
                // déplace rien.
                b.op(code::I32_WRAP_I64).op(code::SELECT);
            });
            Self::write_back(step, step.width.mask(), body);
            return Some(());
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
                Op::Set(_) | Op::CondMove(_) => unreachable!("les conditions sortent avant"),
                Op::Bit(_) | Op::BitScan { .. } | Op::Popcount | Op::ByteSwap => {
                    unreachable!("les bits sortent avant")
                }
                Op::Jump(_) | Op::LoopWhile | Op::JumpIndirect => {
                    unreachable!("les sauts sortent avant")
                }
                Op::Nop => unreachable!("ne rien faire sort avant"),
                Op::Undefined => unreachable!("l'instruction indéfinie sort avant"),
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
                Op::Exchange | Op::ExchangeAndAdd | Op::CompareAndExchange => {
                    unreachable!("les échanges sortent avant")
                }
                Op::RotateThroughCarry { .. } | Op::DoubleShift { .. } => {
                    unreachable!("les rotations à travers la retenue sortent avant")
                }
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
        // La même écriture que partout ailleurs — registre ou mémoire, règle de
        // largeur comprise. Elle était recopiée ici ; la recopie a survécu au
        // jour où la destination a pu être en mémoire, et elle aurait écrit
        // dans un registre ce que l'invité attendait dans sa RAM.
        if !step.discards {
            Self::write_back(step, mask, body);
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
            Op::Shl
            | Op::Shr
            | Op::Sar
            | Op::Mov
            | Op::Movsx
            | Op::Rol
            | Op::Ror
            | Op::Lea
            | Op::Set(_)
            | Op::CondMove(_)
            | Op::Bit(_)
            | Op::BitScan { .. }
            | Op::Popcount
            | Op::ByteSwap
            | Op::Jump(_)
            | Op::LoopWhile
            | Op::JumpIndirect
            | Op::Nop
            | Op::Undefined
            | Op::DirectionFlag(_)
            | Op::StringMove { .. }
            | Op::StringStore { .. }
            | Op::Push
            | Op::Pop
            | Op::Call
            | Op::CallIndirect
            | Op::Return
            | Op::Leave
            | Op::WideMultiply { .. }
            | Op::Multiply
            | Op::Divide { .. }
            | Op::WidenAccumulator
            | Op::SignIntoData
            | Op::CarryFlag(_)
            | Op::Exchange
            | Op::ExchangeAndAdd
            | Op::CompareAndExchange
            | Op::RotateThroughCarry { .. }
            | Op::DoubleShift { .. } => {}
        }
    }

    /// **Une condition, poussée en zéro ou un.**
    ///
    /// Les seize conditions de x86 sont huit prédicats et leur négation, et le
    /// bit de poids faible de l'opcode dit lequel des deux. On traduit donc
    /// huit fois, plus un ou exclusif — pas seize fois.
    fn condition(condition: Condition, b: &mut Body) {
        let bit = |b: &mut Body, flag: u64| {
            b.load(RFLAGS_SLOT).constant(flag).op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
        };
        match condition.base() {
            0 => bit(b, OF),
            1 => bit(b, CF),
            2 => bit(b, ZF),
            3 => {
                bit(b, CF);
                bit(b, ZF);
                b.op(code::I64_OR);
            }
            4 => bit(b, SF),
            5 => bit(b, PF),
            6 => {
                bit(b, SF);
                bit(b, OF);
                b.op(code::I64_XOR);
            }
            _ => {
                bit(b, ZF);
                bit(b, SF);
                bit(b, OF);
                b.op(code::I64_XOR).op(code::I64_OR);
            }
        }
        if condition.negated() {
            b.constant(1).op(code::I64_XOR);
        }
    }

    /// **Rendre la main au milieu d'un bloc.**
    ///
    /// C'est ce que fait le module quand il refuse une instruction : il pose
    /// RIP sur **cette** instruction — pas sur la suivante — et rend -1. L'hôte
    /// reprend là, avec l'interpréteur, qui sait exécuter depuis n'importe
    /// quelle adresse et sait lever une faute. Les instructions d'avant dans le
    /// même bloc ont déjà tourné, et c'est exact : elles ont vraiment eu lieu.
    fn hand_back(address: u64, body: &mut Body) {
        body.store(RIP_SLOT, |b| {
            b.constant(address);
        });
        body.bytes.push(code::I32_CONST);
        signed(-1, &mut body.bytes);
        body.op(code::RETURN);
    }

    /// Rendre la main **si** la condition tient. La condition laisse un `i32`.
    fn refuse_when(address: u64, body: &mut Body, condition: impl FnOnce(&mut Body)) {
        condition(body);
        body.op(code::IF).op(code::VOID);
        Self::hand_back(address, body);
        body.op(code::END);
    }

    /// Écrire un registre **nommé**, avec la règle de largeur. `mul` en écrit
    /// deux et aucun des deux n'est la destination de l'instruction, donc
    /// `write_back` — qui passe par `step.dst` — ne peut pas servir.
    fn put(register: u8, width: Width, body: &mut Body, value: impl FnOnce(&mut Body)) {
        let slot = Self::slot(register);
        body.store(slot, |b| Self::merged(slot, width, false, b, value));
    }

    /// **La valeur entière du registre après une écriture de cette largeur,
    /// sans l'écrire.** C'est ce qu'il faut pour choisir entre écrire et ne pas
    /// écrire *sans branchement* : les deux moitiés du choix doivent être des
    /// valeurs de soixante-quatre bits, pas deux chemins d'exécution.
    fn merged(
        slot: usize,
        width: Width,
        high: bool,
        body: &mut Body,
        value: impl FnOnce(&mut Body),
    ) {
        if high {
            body.load(slot).constant(!0xff00).op(code::I64_AND);
            value(body);
            body.constant(0xff)
                .op(code::I64_AND)
                .constant(8)
                .op(code::I64_SHL);
            body.op(code::I64_OR);
            return;
        }
        match width {
            Width::Qword => value(body),
            // Une écriture de 32 bits efface la moitié haute.
            Width::Dword => {
                value(body);
                body.constant(0xffff_ffff).op(code::I64_AND);
            }
            _ => {
                let mask = width.mask();
                body.load(slot).constant(!mask).op(code::I64_AND);
                value(body);
                body.constant(mask).op(code::I64_AND);
                body.op(code::I64_OR);
            }
        }
    }

    /// Écrire `%ah` — l'octet **haut** de RAX, où `mulb` range son produit et
    /// `divb` son reste. C'est le seul endroit du jeu où une moitié de résultat
    /// atterrit ailleurs que dans un registre entier.
    fn put_high_byte(body: &mut Body, value: impl FnOnce(&mut Body)) {
        let slot = Self::slot(0);
        body.store(slot, |b| Self::merged(slot, Width::Byte, true, b, value));
    }

    /// Étendre au signe depuis une largeur, sur la valeur au sommet de la pile.
    fn widen(width: Width, body: &mut Body) {
        let spare = 64 - width.bits();
        if spare != 0 {
            body.constant(spare).op(code::I64_SHL);
            body.constant(spare).op(code::I64_SHR_S);
        }
    }

    /// **Les soixante-quatre bits de poids fort d'un produit de soixante-quatre
    /// bits.** WebAssembly n'a pas d'instruction pour ça — `i64.mul` rend la
    /// moitié basse et jette l'autre — donc il faut la reconstruire à partir de
    /// quatre produits de trente-deux bits, qui eux tiennent.
    ///
    /// Les largeurs plus étroites n'en ont pas besoin : deux facteurs de
    /// trente-deux bits font un produit de soixante-quatre, et `i64.mul` le
    /// rend entier. L'émetteur connaît la largeur à la compilation, donc il
    /// n'émet ce calcul que là où il sert.
    fn high_product(signed_product: bool, body: &mut Body) {
        // scratch 0 et 1 portent les deux facteurs à l'entrée.
        let (a, b) = (Body::scratch(0), Body::scratch(1));
        let (t, w1, w2, high) = (
            Body::scratch(4),
            Body::scratch(5),
            Body::scratch(6),
            Body::scratch(7),
        );
        let low32 = |b: &mut Body, slot: usize| {
            b.load(slot).constant(0xffff_ffff).op(code::I64_AND);
        };
        let high32 = |b: &mut Body, slot: usize| {
            b.load(slot).constant(32).op(code::I64_SHR_U);
        };
        // t = a0 × b0 ; seule sa moitié haute compte pour la suite.
        body.store(t, |x| {
            low32(x, a);
            low32(x, b);
            x.op(code::I64_MUL).constant(32).op(code::I64_SHR_U);
        });
        // t = a1 × b0 + retenue
        body.store(t, |x| {
            high32(x, a);
            low32(x, b);
            x.op(code::I64_MUL).load(t).op(code::I64_ADD);
        });
        body.store(w1, |x| {
            x.load(t).constant(0xffff_ffff).op(code::I64_AND);
        });
        body.store(w2, |x| {
            x.load(t).constant(32).op(code::I64_SHR_U);
        });
        // t = a0 × b1 + w1
        body.store(t, |x| {
            low32(x, a);
            high32(x, b);
            x.op(code::I64_MUL).load(w1).op(code::I64_ADD);
        });
        body.store(high, |x| {
            high32(x, a);
            high32(x, b);
            x.op(code::I64_MUL)
                .load(w2)
                .op(code::I64_ADD)
                .load(t)
                .constant(32)
                .op(code::I64_SHR_U)
                .op(code::I64_ADD);
        });
        // **Du produit non signé au produit signé.** La correction est exacte :
        // retrancher l'autre facteur une fois par facteur négatif.
        if signed_product {
            body.store(high, |x| {
                x.load(high);
                x.load(a).constant(63).op(code::I64_SHR_S).load(b);
                x.op(code::I64_AND).op(code::I64_SUB);
                x.load(b).constant(63).op(code::I64_SHR_S).load(a);
                x.op(code::I64_AND).op(code::I64_SUB);
            });
        }
        body.load(high);
    }

    /// **La rotation à travers la retenue**, et pourquoi elle n'est pas une
    /// variante de `rol`.
    ///
    /// Le registre tourné fait la largeur **plus un bit** : la retenue en est
    /// le bit de tête. Pour huit, seize et trente-deux bits ça tient encore
    /// dans un `i64` et la formule ordinaire s'applique à la largeur élargie.
    /// Pour soixante-quatre, le registre tourné en fait **soixante-cinq** —
    /// WebAssembly n'a rien de tel, et le bit qui dépasse se traite à la main.
    ///
    /// Ce qui sauve ce cas : le compte est masqué à six bits, donc il ne
    /// dépasse jamais soixante-trois, donc le tour n'est jamais complet. Un
    /// tour de soixante-cinq crans, qu'il faudrait traiter à part, est
    /// inatteignable.
    fn rotate_through_carry(step: &Decoded, to_the_left: bool, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let sign = width.sign();
        let bits = width.bits();
        let span = bits + 1;
        let count_mask: u64 = if width == Width::Qword { 63 } else { 31 };
        let (value, count, turn) = (Body::scratch(0), Body::scratch(1), Body::scratch(5));
        let (carry_in, wide) = (Body::scratch(6), Body::scratch(7));

        body.store(value, |b| {
            Self::left(step, b);
        });
        body.store(count, |b| {
            if step.count_is_cl {
                b.load(Self::slot(1));
            } else {
                b.constant(step.imm);
            }
            b.constant(count_mask).op(code::I64_AND);
        });
        body.store(turn, |b| {
            b.load(count).constant(span).op(code::I64_REM_U);
        });
        body.store(carry_in, |b| {
            b.load(RFLAGS_SLOT).constant(CF).op(code::I64_AND);
        });

        if bits < 64 {
            body.store(wide, |b| {
                b.load(carry_in).constant(bits).op(code::I64_SHL);
                b.load(value).op(code::I64_OR);
            });
            body.store(Body::scratch(8), |b| {
                let (first, second) = if to_the_left {
                    (code::I64_SHL, code::I64_SHR_U)
                } else {
                    (code::I64_SHR_U, code::I64_SHL)
                };
                b.load(wide).load(turn).op(first);
                b.load(wide);
                b.constant(span).load(turn).op(code::I64_SUB);
                b.op(second);
                b.op(code::I64_OR);
                b.constant((1u64 << span) - 1).op(code::I64_AND);
            });
            body.store(Body::scratch(2), |b| {
                b.load(Body::scratch(8)).constant(mask).op(code::I64_AND);
            });
            body.store(Body::scratch(3), |b| {
                b.load(Body::scratch(8))
                    .constant(bits)
                    .op(code::I64_SHR_U)
                    .constant(1)
                    .op(code::I64_AND);
            });
        } else {
            // **Le bit qui dépasse.** Les termes sont écrits pour que le compte
            // de décalage reste sous soixante-quatre : un décalage de
            // soixante-quatre est ramené à zéro par WebAssembly, ce qui rendrait
            // l'opérande là où il faut zéro.
            body.store(Body::scratch(8), |b| {
                if to_the_left {
                    b.load(value).load(turn).op(code::I64_SHL);
                    b.load(carry_in)
                        .load(turn)
                        .constant(1)
                        .op(code::I64_SUB)
                        .op(code::I64_SHL);
                    b.op(code::I64_OR);
                    b.load(value);
                    b.constant(64).load(turn).op(code::I64_SUB);
                    b.op(code::I64_SHR_U).constant(1).op(code::I64_SHR_U);
                    b.op(code::I64_OR);
                } else {
                    b.load(value).load(turn).op(code::I64_SHR_U);
                    b.load(carry_in);
                    b.constant(64).load(turn).op(code::I64_SUB);
                    b.op(code::I64_SHL);
                    b.op(code::I64_OR);
                    b.load(value);
                    b.constant(64).load(turn).op(code::I64_SUB);
                    b.op(code::I64_SHL).constant(1).op(code::I64_SHL);
                    b.op(code::I64_OR);
                }
                // Un tour nul ne tourne rien, et les termes ci-dessus n'ont
                // alors aucun sens : c'est ici qu'on les écarte.
                b.load(value);
                b.load(turn).constant(0).op(code::I64_NE);
                b.op(code::SELECT);
            });
            body.store(Body::scratch(2), |b| {
                b.load(Body::scratch(8));
            });
            body.store(Body::scratch(3), |b| {
                if to_the_left {
                    b.load(value);
                    b.constant(64).load(turn).op(code::I64_SUB);
                    b.op(code::I64_SHR_U);
                } else {
                    b.load(value)
                        .load(turn)
                        .constant(1)
                        .op(code::I64_SUB)
                        .op(code::I64_SHR_U);
                }
                b.constant(1).op(code::I64_AND);
                b.load(carry_in);
                b.load(turn).constant(0).op(code::I64_NE);
                b.op(code::SELECT);
            });
        }

        // Le débordement, défini pour un cran seulement — même lecture que
        // pour `rol` et `ror`.
        body.store(Body::scratch(4), |b| {
            b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
            if to_the_left {
                b.load(Body::scratch(3));
            } else {
                b.load(Body::scratch(2))
                    .constant(bits - 2)
                    .op(code::I64_SHR_U);
                b.constant(1).op(code::I64_AND);
            }
            b.op(code::I64_XOR);
        });

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
            b.load(count).constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });

        if !step.discards {
            Self::write_back(step, mask, body);
        }
    }

    /// **Le décalage double** : les bits qui entrent viennent d'un second
    /// registre au lieu d'être des zéros ou des copies du signe.
    fn double_shift(step: &Decoded, to_the_left: bool, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let sign = width.sign();
        let bits = width.bits();
        let count_mask: u64 = if width == Width::Qword { 63 } else { 31 };
        let (value, count, from) = (Body::scratch(0), Body::scratch(1), Body::scratch(5));

        body.store(value, |b| {
            Self::left(step, b);
        });
        body.store(count, |b| {
            if step.count_is_cl {
                b.load(Self::slot(1));
            } else {
                b.constant(step.imm);
            }
            b.constant(count_mask).op(code::I64_AND);
        });
        body.store(from, |b| {
            b.load(Self::slot(step.src))
                .constant(mask)
                .op(code::I64_AND);
        });

        body.store(Body::scratch(2), |b| {
            if to_the_left {
                b.load(value).load(count).op(code::I64_SHL);
                b.load(from);
                b.constant(bits).load(count).op(code::I64_SUB);
                b.op(code::I64_SHR_U);
            } else {
                b.load(value).load(count).op(code::I64_SHR_U);
                b.load(from);
                b.constant(bits).load(count).op(code::I64_SUB);
                b.op(code::I64_SHL);
            }
            b.op(code::I64_OR).constant(mask).op(code::I64_AND);
            // Un compte nul ne décale rien, et le terme complémentaire vaudrait
            // un décalage de la largeur entière — que WebAssembly ramène à zéro.
            b.load(value);
            b.load(count).constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });

        // La retenue : le **dernier bit sorti** de la destination.
        body.store(Body::scratch(3), |b| {
            if to_the_left {
                b.load(value);
                b.constant(bits).load(count).op(code::I64_SUB);
                b.op(code::I64_SHR_U);
            } else {
                b.load(value)
                    .load(count)
                    .constant(1)
                    .op(code::I64_SUB)
                    .op(code::I64_SHR_U);
            }
            b.constant(1).op(code::I64_AND);
        });

        // Le débordement : le changement de signe, défini pour un cran.
        body.store(Body::scratch(4), |b| {
            b.load(value)
                .load(Body::scratch(2))
                .op(code::I64_XOR)
                .constant(sign)
                .op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
        });

        body.store(RFLAGS_SLOT, |b| {
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

            b.load(RFLAGS_SLOT);
            b.load(count).constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });

        Self::write_back(step, mask, body);
    }

    /// **Les trois échanges.** Ce qui les réunit : elles écrivent **deux**
    /// endroits, et il faut avoir lu les deux avant d'écrire le premier.
    fn exchange(step: &Decoded, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let sign = width.sign();
        let (old, from) = (Body::scratch(5), Body::scratch(6));
        body.store(old, |b| Self::left(step, b));
        body.store(from, |b| Self::right(step, b));
        // La source est toujours un registre : c'est le champ `reg` du ModRM,
        // ou l'accumulateur pour la forme courte. Seule la destination peut
        // être en mémoire.
        let into_source = |body: &mut Body, value: usize| {
            let slot = Self::slot(step.src);
            body.store(slot, |b| {
                Self::merged(slot, width, step.src_high, b, |x| {
                    x.load(value);
                });
            });
        };
        match step.op {
            Op::Exchange => {
                body.store(Body::scratch(2), |b| {
                    b.load(from);
                });
                Self::write_back(step, mask, body);
                into_source(body, old);
            }
            Op::ExchangeAndAdd => {
                // Les drapeaux sont ceux d'un `add`, et la routine qui les pose
                // lit l'opérande gauche, le droit et le résultat dans les trois
                // premiers emplacements de travail.
                body.store(Body::scratch(0), |b| {
                    b.load(old);
                });
                body.store(Body::scratch(1), |b| {
                    b.load(from);
                });
                body.store(Body::scratch(2), |b| {
                    b.load(old)
                        .load(from)
                        .op(code::I64_ADD)
                        .constant(mask)
                        .op(code::I64_AND);
                });
                let as_add = Decoded {
                    op: Op::Add,
                    ..*step
                };
                Self::flags(&as_add, mask, sign, body);
                Self::write_back(step, mask, body);
                into_source(body, old);
            }
            _ => {
                // **`cmpxchg` compare l'accumulateur à la destination**, pas la
                // source à la destination.
                let accumulator = Body::scratch(7);
                body.store(accumulator, |b| {
                    b.load(Self::slot(0)).constant(mask).op(code::I64_AND);
                });
                body.store(Body::scratch(0), |b| {
                    b.load(accumulator);
                });
                body.store(Body::scratch(1), |b| {
                    b.load(old);
                });
                body.store(Body::scratch(2), |b| {
                    b.load(accumulator)
                        .load(old)
                        .op(code::I64_SUB)
                        .constant(mask)
                        .op(code::I64_AND);
                });
                Self::flags(&as_compare(step), mask, sign, body);
                // Le verdict, gardé à part : les trois emplacements que la
                // routine des drapeaux vient d'employer vont resservir.
                let equal = Body::scratch(8);
                body.store(equal, |b| {
                    b.load(accumulator)
                        .load(old)
                        .op(code::I64_EQ)
                        .op(code::I64_EXTEND_I32_U);
                });
                // **Quand l'égalité ne tient pas, la destination n'est pas
                // écrite du tout.** Pas même réécrite avec sa propre valeur :
                // une écriture de trente-deux bits, même de la même valeur,
                // effacerait la moitié haute du registre. Le silicium a
                // tranché — sept cas sur vingt-quatre pour `cmpxchgl`.
                match step.memory {
                    // En mémoire la distinction ne s'observe pas : réécrire les
                    // mêmes octets ne se voit pas, et c'est ce que fait la forme
                    // verrouillée.
                    Some(_) => {
                        body.store(Body::scratch(2), |b| {
                            b.load(from).load(old).load(equal).op(code::I32_WRAP_I64);
                            b.op(code::SELECT);
                        });
                        Self::write_back(step, mask, body);
                    }
                    None => {
                        let slot = Self::slot(step.dst);
                        body.store(slot, |b| {
                            Self::merged(slot, width, step.dst_high, b, |x| {
                                x.load(from);
                            });
                            b.load(slot);
                            b.load(equal).op(code::I32_WRAP_I64);
                            b.op(code::SELECT);
                        });
                    }
                }
                // Et l'accumulateur, à l'inverse : écrit **seulement** quand
                // l'égalité ne tient pas.
                let slot = Self::slot(0);
                body.store(slot, |b| {
                    b.load(slot);
                    Self::merged(slot, width, false, b, |x| {
                        x.load(old);
                    });
                    b.load(equal).op(code::I32_WRAP_I64);
                    b.op(code::SELECT);
                });
            }
        }
    }

    /// **Les multiplications, les divisions, les extensions de signe, et la
    /// retenue posée à la main.**
    ///
    /// Elles partagent ce qui les sort de la machinerie ordinaire : leur
    /// destination n'est pas l'opérande qu'elles lisent. `mul` et `div`
    /// écrivent RDX **et** RAX ; `cqto` écrit RDX en lisant RAX ; `clc` n'écrit
    /// qu'un bit de RFLAGS.
    fn two_registers(step: &Decoded, address: u64, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let bits = width.bits();
        match step.op {
            Op::CarryFlag(action) => {
                body.store(RFLAGS_SLOT, |b| {
                    b.load(RFLAGS_SLOT);
                    match action {
                        CarryAction::Clear => b.constant(!1u64).op(code::I64_AND),
                        CarryAction::Set => b.constant(1).op(code::I64_OR),
                        CarryAction::Complement => b.constant(1).op(code::I64_XOR),
                    };
                });
            }
            // La source fait la **demi**-largeur : c'est tout ce qui distingue
            // `cbtw` de `cltq`.
            Op::WidenAccumulator => {
                let half = step.src_width;
                Self::put(0, width, body, |b| {
                    b.load(Self::slot(0))
                        .constant(half.mask())
                        .op(code::I64_AND);
                    Self::widen(half, b);
                });
            }
            // RDX ne reçoit pas *le* signe mais **tous les bits** du signe :
            // un décalage arithmétique de soixante-trois crans.
            Op::SignIntoData => {
                Self::put(2, width, body, |b| {
                    b.load(Self::slot(0)).constant(mask).op(code::I64_AND);
                    Self::widen(width, b);
                    b.constant(63).op(code::I64_SHR_S);
                });
            }
            Op::WideMultiply { signed: is_signed } => {
                // scratch 0 : l'accumulateur. scratch 1 : l'opérande.
                body.store(Body::scratch(0), |b| {
                    b.load(Self::slot(0)).constant(mask).op(code::I64_AND);
                    if is_signed {
                        Self::widen(width, b);
                    }
                });
                body.store(Body::scratch(1), |b| {
                    Self::operand(step, b);
                    b.constant(mask).op(code::I64_AND);
                    if is_signed {
                        Self::widen(width, b);
                    }
                });
                // scratch 2 : la moitié basse. scratch 3 : la moitié haute.
                body.store(Body::scratch(2), |b| {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_MUL);
                });
                body.store(Body::scratch(3), |b| {
                    if bits == 64 {
                        Self::high_product(is_signed, b);
                    } else {
                        b.load(Body::scratch(2));
                        b.constant(bits)
                            .op(if is_signed {
                                code::I64_SHR_S
                            } else {
                                code::I64_SHR_U
                            })
                            .constant(mask)
                            .op(code::I64_AND);
                    }
                });
                // **Le débordement d'un produit signé n'est pas « le haut est
                // non nul ».** Un produit négatif a un haut plein de uns et
                // tient pourtant : ce qui compte est que le haut ne soit que la
                // recopie du signe du bas.
                body.store(Body::scratch(4), |b| {
                    if is_signed {
                        b.load(Body::scratch(3));
                        b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                        Self::widen(width, b);
                        b.constant(63)
                            .op(code::I64_SHR_S)
                            .constant(mask)
                            .op(code::I64_AND);
                        b.op(code::I64_NE).op(code::I64_EXTEND_I32_U);
                    } else {
                        b.load(Body::scratch(3))
                            .op(code::I64_EQZ)
                            .op(code::I64_EXTEND_I32_U);
                        b.constant(1).op(code::I64_XOR);
                    }
                });
                if width == Width::Byte {
                    Self::put(0, Width::Byte, body, |b| {
                        b.load(Body::scratch(2));
                    });
                    Self::put_high_byte(body, |b| {
                        b.load(Body::scratch(3));
                    });
                } else {
                    Self::put(0, width, body, |b| {
                        b.load(Body::scratch(2));
                    });
                    Self::put(2, width, body, |b| {
                        b.load(Body::scratch(3));
                    });
                }
                Self::carry_and_overflow_together(body);
            }
            Op::Multiply => {
                // À trois opérandes les deux facteurs sont `rm` et l'immédiat ;
                // à deux, c'est la destination et `rm`.
                body.store(Body::scratch(0), |b| {
                    if step.immediate {
                        Self::operand(step, b);
                    } else {
                        b.load(Self::slot(step.dst));
                    }
                    b.constant(mask).op(code::I64_AND);
                    Self::widen(width, b);
                });
                body.store(Body::scratch(1), |b| {
                    if step.immediate {
                        b.constant(step.imm);
                    } else {
                        Self::operand(step, b);
                    }
                    b.constant(mask).op(code::I64_AND);
                    Self::widen(width, b);
                });
                body.store(Body::scratch(2), |b| {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_MUL);
                });
                body.store(Body::scratch(3), |b| {
                    if bits == 64 {
                        Self::high_product(true, b);
                    } else {
                        b.load(Body::scratch(2)).constant(bits).op(code::I64_SHR_S);
                    }
                });
                body.store(Body::scratch(4), |b| {
                    b.load(Body::scratch(3))
                        .constant(if bits == 64 { u64::MAX } else { mask })
                        .op(code::I64_AND);
                    b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                    Self::widen(width, b);
                    b.constant(63).op(code::I64_SHR_S);
                    b.constant(if bits == 64 { u64::MAX } else { mask })
                        .op(code::I64_AND);
                    b.op(code::I64_NE).op(code::I64_EXTEND_I32_U);
                });
                Self::put(step.dst, width, body, |b| {
                    b.load(Body::scratch(2));
                });
                Self::carry_and_overflow_together(body);
            }
            _ => Self::divide(step, address, body),
        }
    }

    /// CF et OF disent la même chose pour une multiplication — « le résultat
    /// ne tenait pas » — et scratch 4 la porte. Les quatre autres drapeaux sont
    /// indéfinis : le manuel les abandonne, donc on les laisse tels quels
    /// plutôt que de les écraser avec des valeurs plausibles et fausses.
    fn carry_and_overflow_together(body: &mut Body) {
        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT).constant(!(CF | OF)).op(code::I64_AND);
            b.load(Body::scratch(4))
                .op(code::I64_EQZ)
                .op(code::I64_EXTEND_I32_U)
                .constant(1)
                .op(code::I64_XOR);
            b.constant(CF | OF).op(code::I64_MUL);
            b.op(code::I64_OR);
        });
    }

    /// L'opérande que le ModRM désigne — registre, octet haut, ou mémoire.
    fn operand(step: &Decoded, body: &mut Body) {
        match step.memory {
            Some(address) => {
                body.load_memory(
                    &address,
                    if step.memory_is_source {
                        step.src_width
                    } else {
                        step.width
                    },
                );
            }
            None => {
                let register = if step.op == Op::Multiply {
                    step.src
                } else {
                    step.dst
                };
                let high = if step.op == Op::Multiply {
                    step.src_high
                } else {
                    step.dst_high
                };
                body.load(Self::slot(register));
                if high {
                    body.constant(8).op(code::I64_SHR_U);
                }
            }
        }
    }

    /// **La seule instruction qui peut refuser de s'exécuter.**
    ///
    /// Trois raisons de refuser, et le module les traite de la même façon :
    /// il rend la main sans rien écrire, RIP sur la division elle-même.
    ///
    /// 1. **Un diviseur nul.** Le processeur lève `#DE` ; le module ne peut pas
    ///    lever, et une division par zéro en WebAssembly est une *trappe* qui
    ///    tue le module entier. Rendre la main laisse l'interpréteur lever.
    /// 2. **Un quotient qui ne tient pas** dans la largeur — `0x8000 / -1` en
    ///    seize bits. Même chose : c'est un `#DE`.
    /// 3. **Un dividende de cent vingt-huit bits véritable**, en soixante-quatre
    ///    bits de large, dont la moitié haute n'est pas la banale. WebAssembly
    ///    ne divise pas sur cent vingt-huit bits, et écrire la division longue
    ///    ici serait beaucoup de code pour un cas qu'aucun cas du corpus
    ///    n'exerce. L'interpréteur, lui, sait le faire — et il est vérifié
    ///    contre le silicium. C'est le filet, et c'est son emploi.
    fn divide(step: &Decoded, address: u64, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let bits = width.bits();
        let signed = matches!(step.op, Op::Divide { signed: true });
        let (divisor, low, high, quotient) = (
            Body::scratch(0),
            Body::scratch(1),
            Body::scratch(2),
            Body::scratch(3),
        );
        body.store(divisor, |b| {
            Self::operand(step, b);
            b.constant(mask).op(code::I64_AND);
        });
        Self::refuse_when(address, body, |b| {
            b.load(divisor).op(code::I64_EQZ);
        });
        // En octet le dividende est AX tout entier : sa moitié haute est AH,
        // elle vit dans RAX et pas dans RDX.
        body.store(low, |b| {
            b.load(Self::slot(0)).constant(mask).op(code::I64_AND);
        });
        body.store(high, |b| {
            if width == Width::Byte {
                b.load(Self::slot(0)).constant(8).op(code::I64_SHR_U);
            } else {
                b.load(Self::slot(2));
            }
            b.constant(mask).op(code::I64_AND);
        });
        if signed {
            body.store(divisor, |b| {
                b.load(divisor);
                Self::widen(width, b);
            });
        }
        if bits == 64 {
            // La moitié haute doit être la banale — zéro, ou le signe du bas.
            Self::refuse_when(address, body, |b| {
                b.load(high);
                if signed {
                    b.load(low).constant(63).op(code::I64_SHR_S);
                } else {
                    b.constant(0);
                }
                b.op(code::I64_NE);
            });
            // Et le seul quotient qui déborde encore : le minimum divisé par -1.
            if signed {
                Self::refuse_when(address, body, |b| {
                    b.load(low).constant(1u64 << 63).op(code::I64_EQ);
                    b.load(divisor).constant(u64::MAX).op(code::I64_EQ);
                    b.op(0x71); // i32.and
                });
            }
            body.store(quotient, |b| {
                b.load(low);
                if signed {
                    Self::widen(width, b);
                }
                b.load(divisor).op(if signed {
                    code::I64_DIV_S
                } else {
                    code::I64_DIV_U
                });
            });
            let remainder = Body::scratch(4);
            body.store(remainder, |b| {
                b.load(low);
                if signed {
                    Self::widen(width, b);
                }
                b.load(divisor).op(if signed {
                    code::I64_REM_S
                } else {
                    code::I64_REM_U
                });
            });
            Self::put(0, width, body, |b| {
                b.load(quotient);
            });
            Self::put(2, width, body, |b| {
                b.load(remainder);
            });
            return;
        }
        // Largeurs étroites : le dividende double tient dans soixante-quatre
        // bits, donc la division ordinaire suffit.
        let dividend = Body::scratch(5);
        body.store(dividend, |b| {
            b.load(high).constant(bits).op(code::I64_SHL);
            b.load(low).op(code::I64_OR);
            if signed {
                let spare = 64 - bits * 2;
                if spare != 0 {
                    b.constant(spare).op(code::I64_SHL);
                    b.constant(spare).op(code::I64_SHR_S);
                }
            }
        });
        body.store(quotient, |b| {
            b.load(dividend).load(divisor).op(if signed {
                code::I64_DIV_S
            } else {
                code::I64_DIV_U
            });
        });
        Self::refuse_when(address, body, |b| {
            if signed {
                let limit = 1u64 << (bits - 1);
                b.load(quotient)
                    .constant(limit.wrapping_neg())
                    .op(code::I64_LT_S);
                b.load(quotient)
                    .constant(limit.wrapping_sub(1))
                    .op(code::I64_GT_S);
                b.op(0x72); // i32.or
            } else {
                b.load(quotient).constant(mask).op(code::I64_GT_U);
            }
        });
        let remainder = Body::scratch(6);
        body.store(remainder, |b| {
            b.load(dividend).load(divisor).op(if signed {
                code::I64_REM_S
            } else {
                code::I64_REM_U
            });
        });
        if width == Width::Byte {
            Self::put(0, Width::Byte, body, |b| {
                b.load(quotient);
            });
            Self::put_high_byte(body, |b| {
                b.load(remainder);
            });
        } else {
            Self::put(0, width, body, |b| {
                b.load(quotient);
            });
            Self::put(2, width, body, |b| {
                b.load(remainder);
            });
        }
    }

    /// **Les instructions de chaîne, et pourquoi la forme répétée rend la
    /// main.**
    ///
    /// La forme simple est de la ligne droite : lire, écrire, avancer les deux
    /// pointeurs du pas que le drapeau de direction choisit. Elle est traduite
    /// ici.
    ///
    /// **La forme répétée, non — et c'est un choix, pas un oubli.** Un
    /// `rep movsq` est une boucle, et WebAssembly sait en écrire une. Mais
    /// rendre la main coûte **une** rentrée dans l'hôte par `memcpy`, pas une
    /// par octet : l'interpréteur exécute la répétition entière en un seul
    /// pas, en Rust natif, et le module reprend après. Le coût d'une boucle
    /// émise se paierait à chaque octet copié, en globales lues et réécrites,
    /// contre une seule rentrée. Le jour où une mesure montrera que cette
    /// rentrée pèse, la boucle s'écrira — et pas avant.
    ///
    /// Ce que ça change pour le compte de couverture : la région **compile**,
    /// et c'est ce que la mesure relève. Elle ne dit pas que tout y court
    /// compilé, et c'est vrai aussi des appels indirects.
    fn string(step: &Decoded, address: u64, body: &mut Body) -> Option<()> {
        let repeat = matches!(
            step.op,
            Op::StringMove { repeat: true } | Op::StringStore { repeat: true }
        );
        if repeat {
            Self::hand_back(address, body);
            return Some(());
        }
        let width = step.width;
        let size = width as u64;
        // scratch 0 : le pas, négatif quand le drapeau de direction est posé.
        body.store(Body::scratch(0), |b| {
            b.constant(size.wrapping_neg());
            b.constant(size);
            b.load(RFLAGS_SLOT).constant(DF).op(code::I64_AND);
            b.constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });
        // scratch 1 : la valeur — lue en mémoire pour `movs`, prise dans
        // l'accumulateur pour `stos`.
        let moves = matches!(step.op, Op::StringMove { .. });
        body.store(Body::scratch(1), |b| {
            if moves {
                b.load(Self::slot(6)).op(code::I32_WRAP_I64);
                b.op(match width {
                    Width::Byte => code::I64_LOAD8_U,
                    Width::Word => code::I64_LOAD16_U,
                    Width::Dword => code::I64_LOAD32_U,
                    Width::Qword => code::I64_LOAD,
                });
                b.bytes.push(0);
                b.bytes.push(0);
            } else {
                b.load(Self::slot(0))
                    .constant(width.mask())
                    .op(code::I64_AND);
            }
        });
        body.store_at(Self::slot(7), width, |b| {
            b.load(Body::scratch(1));
        });
        if moves {
            body.store(Self::slot(6), |b| {
                b.load(Self::slot(6))
                    .load(Body::scratch(0))
                    .op(code::I64_ADD);
            });
        }
        body.store(Self::slot(7), |b| {
            b.load(Self::slot(7))
                .load(Body::scratch(0))
                .op(code::I64_ADD);
        });
        Some(())
    }

    /// **La pile.** L'ordre est le sujet : `push` descend RSP **puis** écrit,
    /// `pop` lit **puis** remonte. L'inverser écrirait huit octets au-dessus
    /// du sommet, là où une interruption a le droit de passer.
    fn stack(step: &Decoded, body: &mut Body) {
        match step.op {
            Op::Push => {
                // scratch 0 : la valeur, lue **avant** que RSP ne bouge —
                // `push %rsp` empile la valeur d'avant la descente.
                body.store(Body::scratch(0), |b| {
                    if step.immediate {
                        b.constant(step.imm);
                    } else if let Some(address) = step.memory {
                        // `pushq (%rsi)` : huit octets pris en mémoire. Toujours
                        // huit — en mode 64 bits le groupe 5 n'a pas d'autre
                        // largeur, et en prendre quatre empilerait la moitié
                        // basse d'un pointeur.
                        b.load_memory(&address, Width::Qword);
                    } else {
                        b.load(Self::slot(step.dst));
                    }
                });
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_SUB);
                });
                Self::at_top(body, |b| {
                    b.load(Body::scratch(0));
                });
            }
            Op::Pop => {
                body.store(Self::slot(step.dst), |b| {
                    b.load(Self::slot(4));
                    b.op(code::I32_WRAP_I64);
                    b.op(code::I64_LOAD);
                    b.bytes.push(0);
                    b.bytes.push(0);
                });
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_ADD);
                });
            }
            _ => {
                // `leave` : RSP reprend RBP, puis RBP se dépile.
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(5));
                });
                body.store(Self::slot(5), |b| {
                    b.load(Self::slot(4));
                    b.op(code::I32_WRAP_I64);
                    b.op(code::I64_LOAD);
                    b.bytes.push(0);
                    b.bytes.push(0);
                });
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_ADD);
                });
            }
        }
    }

    /// Écrire huit octets au sommet de la pile, RSP étant déjà à sa place.
    fn at_top(body: &mut Body, value: impl FnOnce(&mut Body)) {
        body.load(Self::slot(4)).op(code::I32_WRAP_I64);
        value(body);
        body.op(code::I64_STORE);
        body.bytes.push(0);
        body.bytes.push(0);
    }

    /// **Un bit, lu dans la retenue et parfois changé.**
    fn bit(step: &Decoded, action: BitAction, body: &mut Body) {
        let width = step.width;
        let bits = width.bits();
        // **La chaîne de bits : une adresse que seule l'exécution connaît.**
        //
        // Quand la destination est en mémoire et que le numéro vient d'un
        // registre, ce numéro est **signé** et n'est pas replié : le processeur
        // va chercher le mot qui le contient, en avant comme en arrière. Le
        // mot visé est donc `adresse + (numéro ÷ bits) × octets`, la division
        // arrondie **vers le bas**.
        //
        // Les deux opérations sont des décalages, et c'est exact plutôt que
        // commode : la largeur est une puissance de deux, donc `>>` arithmétique
        // **est** la division arrondie vers le bas — y compris pour les
        // négatifs, là où `i64.div_s`, qui tronque vers zéro, remonterait d'un
        // mot. Et le reste positif est simplement les bits bas.
        //
        // **Deux sabotages y ont survécu, et ils avaient tort.** Mettre un
        // décalage logique à la place de l'arithmétique, ou tronquer l'adresse
        // à trente-deux bits avant d'y ajouter le mot, rend ici *exactement* le
        // même résultat. Ce n'est pas un trou dans les tests : la mémoire
        // WebAssembly s'adresse sur trente-deux bits, et l'écart entre les deux
        // décalages vaut 2⁶¹ quelle que soit la largeur — donc zéro une fois
        // tronqué. Aucun test ne peut les distinguer, et il ne faut pas en
        // tordre un pour essayer. Ce qui est écrit ici est ce qu'on veut dire,
        // et ce qui resterait juste si la mémoire s'adressait un jour plus
        // loin.
        let string = step.memory.is_some() && !step.immediate;
        if let (true, Some(address)) = (string, step.memory) {
            body.store(Body::scratch(3), |b| {
                b.wide_address(&address);
                b.load(Self::slot(step.src))
                    .constant(u64::from(bits.trailing_zeros()))
                    .op(code::I64_SHR_S)
                    .constant(u64::from((width as u64).trailing_zeros()))
                    .op(code::I64_SHL)
                    .op(code::I64_ADD);
            });
        }
        // scratch 0 : l'opérande. scratch 1 : le numéro, réduit dans la largeur.
        body.store(Body::scratch(0), |b| {
            if string {
                b.load_at(Body::scratch(3), width);
            } else if let Some(address) = step.memory {
                b.load_memory(&address, width);
            } else {
                b.load(Self::slot(step.dst))
                    .constant(width.mask())
                    .op(code::I64_AND);
            }
        });
        body.store(Body::scratch(1), |b| {
            if step.immediate {
                b.constant(step.imm % bits);
            } else if string {
                b.load(Self::slot(step.src))
                    .constant(bits - 1)
                    .op(code::I64_AND);
            } else {
                b.load(Self::slot(step.src))
                    .constant(bits)
                    .op(code::I64_REM_U);
            }
        });
        // La retenue, et elle seule.
        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT).constant(!CF).op(code::I64_AND);
            b.load(Body::scratch(0))
                .load(Body::scratch(1))
                .op(code::I64_SHR_U);
            b.constant(1).op(code::I64_AND);
            b.constant(CF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);
        });
        if action == BitAction::Test {
            return;
        }
        // scratch 2 : l'opérande avec son bit changé, puis l'écriture commune.
        body.store(Body::scratch(2), |b| {
            b.load(Body::scratch(0));
            b.constant(1).load(Body::scratch(1)).op(code::I64_SHL);
            match action {
                BitAction::Set => {
                    b.op(code::I64_OR);
                }
                BitAction::Reset => {
                    // Pas de « et non » en WebAssembly : on inverse le masque.
                    b.constant(u64::MAX).op(code::I64_XOR).op(code::I64_AND);
                }
                _ => {
                    b.op(code::I64_XOR);
                }
            }
            b.constant(width.mask()).op(code::I64_AND);
        });
        if string {
            body.store_at(Body::scratch(3), width, |b| {
                b.load(Body::scratch(2));
            });
            return;
        }
        Self::write_back(step, width.mask(), body);
    }

    /// **Chercher le premier bit à un.** Quand la source est nulle, la
    /// destination ne bouge pas — le manuel la dit indéfinie, et le corpus a
    /// relevé ce que fait la machine qui l'a produit.
    fn scan(step: &Decoded, from_the_top: bool, body: &mut Body) {
        let width = step.width;
        body.store(Body::scratch(0), |b| {
            Self::right(step, b);
        });
        // Le zéro parle de la **source**.
        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT).constant(!ZF).op(code::I64_AND);
            b.load(Body::scratch(0)).op(code::I64_EQZ);
            b.op(code::I64_EXTEND_I32_U)
                .constant(ZF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);
        });
        body.store(Body::scratch(2), |b| {
            if from_the_top {
                // L'opérande est déjà masqué, donc les zéros de tête comptent
                // depuis soixante-quatre : l'indice est leur complément.
                b.constant(63);
                b.load(Body::scratch(0)).op(code::I64_CLZ);
                b.op(code::I64_SUB);
            } else {
                b.load(Body::scratch(0)).op(code::I64_CTZ);
            }
        });
        // **Source nulle : rien n'est écrit du tout.** Pas « l'ancienne valeur
        // réécrite » — *rien*. La nuance se voit en trente-deux bits, où toute
        // écriture efface la moitié haute : le silicium a rendu `%rax` entier
        // là où j'écrivais un `%eax` étendu par zéro. Un seul cas sur 8 928,
        // et il énonce une vraie règle.
        //
        // Le choix porte donc sur le **registre entier**, après la règle de
        // largeur, et pas sur la valeur avant.
        let slot = Self::slot(step.dst);
        let mask = width.mask();
        body.store(slot, |b| {
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
            b.load(slot);
            // `i64.ne` rend **déjà** un `i32` : c'est ce que `select` attend,
            // et le tronquer une seconde fois donne un module que le moteur
            // refuse. Ailleurs — dans `cmov` — le prédicat est un `i64` et la
            // troncature est nécessaire ; les deux ne se ressemblent qu'en
            // surface.
            b.load(Body::scratch(0)).constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });
    }

    /// **Compter les bits à un.** Les six drapeaux sont définis, cinq à zéro.
    fn popcount(step: &Decoded, body: &mut Body) {
        body.store(Body::scratch(0), |b| {
            Self::right(step, b);
        });
        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT)
                .constant(!(CF | PF | AF | ZF | SF | OF))
                .op(code::I64_AND);
            b.load(Body::scratch(0)).op(code::I64_EQZ);
            b.op(code::I64_EXTEND_I32_U)
                .constant(ZF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);
        });
        body.store(Body::scratch(2), |b| {
            b.load(Body::scratch(0)).op(code::I64_POPCNT);
        });
        Self::write_back(step, step.width.mask(), body);
    }

    /// **Renverser les octets.** WebAssembly n'a pas d'opérateur pour ça : on
    /// l'écrit octet par octet, ce qui reste du code droit sans branchement.
    fn byte_swap(step: &Decoded, body: &mut Body) {
        let count = step.width as u64;
        body.store(Body::scratch(2), |b| {
            for rank in 0..count {
                b.load(Self::slot(step.dst));
                if rank != 0 {
                    b.constant(rank * 8).op(code::I64_SHR_U);
                }
                b.constant(0xff).op(code::I64_AND);
                let to = (count - 1 - rank) * 8;
                if to != 0 {
                    b.constant(to).op(code::I64_SHL);
                }
                if rank != 0 {
                    b.op(code::I64_OR);
                }
            }
        });
        Self::write_back(step, step.width.mask(), body);
    }

    /// **`lea`, c'est-à-dire une addition qui a l'air d'un accès mémoire.**
    ///
    /// Rien n'est lu ni écrit en mémoire invitée : l'adresse elle-même est le
    /// résultat. L'échelle est une puissance de deux, donc un décalage, et la
    /// somme boucle sur soixante-quatre bits — c'est ainsi que se codent les
    /// index négatifs.
    /// **Le préfixe de segment n'est pas lu ici, et c'est la conduite du
    /// silicium** : `lea` ne touche pas la mémoire, donc ne traverse pas
    /// l'unité de segmentation. Le corpus juge cette absence sur un vrai
    /// processeur.
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
            match step.memory {
                _ if step.immediate => {
                    b.constant(step.imm & step.src_width.mask());
                }
                Some(address) if step.memory_is_source => {
                    b.load_memory(&address, step.src_width);
                }
                _ => {
                    b.load(Self::slot(step.src));
                    if step.src_high {
                        b.constant(8).op(code::I64_SHR_U);
                    }
                    b.constant(step.src_width.mask()).op(code::I64_AND);
                }
            }
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
        // **Quand la destination est en mémoire, la règle de largeur ne
        // s'applique pas.** Elle décrit ce qu'une écriture de registre fait au
        // reste du registre ; en mémoire, on écrit exactement les octets de la
        // largeur, et l'octet d'à côté n'est pas concerné.
        if let Some(address) = step.memory {
            // **`lea` est l'exception.** Elle porte une adresse et n'écrit pas
            // dedans : l'adresse **est** son résultat, et sa destination est un
            // registre. La faire passer par ici l'écrivait à l'adresse — le
            // moteur l'a dit tout de suite, « Out of bounds memory access »,
            // parce que la première adresse venue sortait de la RAM déclarée.
            if !step.memory_is_source && step.op != Op::Lea {
                body.store_memory(&address, step.width, |b| {
                    b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                });
                return;
            }
        }
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
