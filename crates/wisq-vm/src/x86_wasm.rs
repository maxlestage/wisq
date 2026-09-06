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
    decode, Address, BitAction, Condition, Decoded, Op, Width, AF, CF, OF, PF, SF, ZF,
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
pub const SCRATCH_SLOT: usize = RIP_SLOT + 1;
pub const SCRATCH_COUNT: usize = 6;
/// Le nombre de globales que le module déclare et exporte.
pub const GLOBAL_COUNT: usize = SCRATCH_SLOT + SCRATCH_COUNT;

/// Le nombre de pages de RAM invitée que le module déclare. Assez pour couvrir
/// la fenêtre de données du corpus matériel, qui vit à 0x30001000.
pub const GUEST_PAGES: u32 = 0x3001;

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

    /// Pousser l'adresse effective, en `i32`, prête pour un accès mémoire.
    fn address(&mut self, address: &Address) -> &mut Self {
        self.constant(address.displacement as u64);
        if let Some(base) = address.base {
            self.load(base as usize).op(code::I64_ADD);
        }
        if let Some(index) = address.index {
            self.load(index as usize);
            self.constant(u64::from(address.scale.trailing_zeros()))
                .op(code::I64_SHL);
            self.op(code::I64_ADD);
        }
        self.op(code::I32_WRAP_I64)
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
                at += step.length;
                // **Le saut final n'est pas traduit comme les autres.** Il ne
                // change pas l'état de la machine mais le bloc courant, et
                // c'est `terminate` qui sait le dire — lui seul connaît les
                // autres blocs.
                if matches!(
                    step.op,
                    Op::Jump(_) | Op::LoopWhile | Op::JumpIndirect | Op::Call | Op::Return
                ) {
                    continue;
                }
                Self::translate(step, &mut body)?;
            }
            Self::terminate(steps.last(), base, at, &index, &starts, &mut body);
            body.op(code::END);
            bodies.push(body.bytes);
        }
        Some(Self::assemble(bodies))
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
                    Op::Jump(_) | Op::LoopWhile | Op::JumpIndirect | Op::Call | Op::Return
                );
                let displacement = step.imm as i64;
                // **Ce qui suit un `call` est atteignable, et par une seule
                // route : le `ret` qui lui répond.** Ne pas le mettre dans la
                // file laissait l'appelé sans retour possible — le module
                // rendait la main au lieu de continuer. `jmp` est le seul à
                // n'avoir pas de suite ; `ret`, lui, n'a pas de cible connue
                // d'avance, et sa suite n'est atteignable que par ailleurs.
                let falls = !matches!(step.op, Op::Jump(None) | Op::Return);
                let jumps = !matches!(step.op, Op::Return);
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
            Op::JumpIndirect => {
                body.store(RIP_SLOT, |b| {
                    b.load(Self::slot(step.dst));
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

        // Mémoire : **la RAM de l'invité**, adresse pour adresse. Elle vient
        // avant les globales, et pas par goût : les sections d'un module ont
        // un ordre imposé, et le moteur refuse le module s'il est inversé.
        // JavaScriptCore ne la réserve pas vraiment — mesuré : vingt mémoires
        // de 768 Mio en dix millisecondes.
        let mut memory = vec![0x01, 0x00];
        unsigned(u64::from(GUEST_PAGES), &mut memory);
        section(5, memory, &mut module);

        // Globales : le fichier de registres, RFLAGS, le pointeur
        // d'instruction, les emplacements de travail. Toutes `i64`, toutes
        // mutables, toutes à zéro — c'est l'hôte qui pose l'état.
        let mut globals = Vec::new();
        unsigned(GLOBAL_COUNT as u64, &mut globals);
        for _ in 0..GLOBAL_COUNT {
            globals.push(0x7e);
            globals.push(0x01);
            globals.push(code::I64_CONST);
            signed(0, &mut globals);
            globals.push(code::END);
        }
        section(6, globals, &mut module);

        let mut exports = Vec::new();
        unsigned(2 + GLOBAL_COUNT as u64, &mut exports);
        exports.extend_from_slice(&[0x03, b'r', b'u', b'n', 0x00]);
        unsigned(count as u64, &mut exports);
        exports.extend_from_slice(&[0x03, b'm', b'e', b'm', 0x02, 0x00]);
        for slot in 0..GLOBAL_COUNT {
            let name = format!("g{slot}");
            unsigned(name.len() as u64, &mut exports);
            exports.extend_from_slice(name.as_bytes());
            exports.push(0x03);
            unsigned(slot as u64, &mut exports);
        }
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

    fn translate(step: &Decoded, body: &mut Body) -> Option<()> {
        // **Un saut n'est pas une instruction comme une autre** : il change le
        // bloc, pas l'état. Il est traité par le compilateur de région, qui
        // seul connaît les autres blocs ; en ligne droite, il n'a aucun sens.
        if matches!(step.op, Op::Jump(_) | Op::LoopWhile | Op::JumpIndirect) {
            return None;
        }
        // Ne rien faire n'émet rien.
        if step.op == Op::Nop {
            return Some(());
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
                Op::Push | Op::Pop | Op::Call | Op::Return | Op::Leave => {
                    unreachable!("la pile sort avant")
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
            | Op::Push
            | Op::Pop
            | Op::Call
            | Op::Return
            | Op::Leave => {}
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
        // scratch 0 : l'opérande. scratch 1 : le numéro, réduit dans la largeur.
        body.store(Body::scratch(0), |b| {
            b.load(Self::slot(step.dst))
                .constant(width.mask())
                .op(code::I64_AND);
        });
        body.store(Body::scratch(1), |b| {
            if step.immediate {
                b.constant(step.imm % bits);
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
