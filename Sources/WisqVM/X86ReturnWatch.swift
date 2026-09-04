import Foundation

// La pile d'ombre : est-ce qu'un `ret` rend la main là où le `call` l'avait
// promis ?
//
// **Pourquoi ce fichier existe.** Cinq corpus matériels ont épuisé le jeu
// d'instructions du chargeur de l'invité, le vecteur auxiliaire s'est révélé
// juste, et `/init` meurt quand même. Ce que le témoin des adresses
// impossibles a montré, c'est un `ret` qui rend la main **en dehors** de
// l'objet dont il vient : le retour part de `ld-musl` et atterrit une page en
// dessous de sa base.
//
// Or `ret` lui-même est prouvé : le corpus de branchement le tient sous ses
// trois formes d'appel, avec des appels imbriqués et un `ret` qui jette ses
// arguments. Si l'instruction est juste et que l'adresse est fausse, **c'est
// que la pile a changé entre l'appel et le retour**.
//
// Ce témoin le dit. À chaque `call` d'anneau trois il note ce qui vient d'être
// empilé, et à chaque `ret` il compare. Le premier désaccord porte les deux
// adresses — celle qu'on avait promise et celle qu'on a prise — et l'endroit
// exact où la promesse a été rompue.
//
// **Ce n'est pas une règle du processeur.** Un programme a parfaitement le
// droit de fabriquer son adresse de retour, et certains le font — un
// trampoline de signal, un `setjmp`, une coroutine. Le témoin ne refuse rien :
// il rend compte, et c'est à l'œil de dire si le désaccord est innocent.
extension X86Core {
    /// Ce qu'une instruction fait au flot : appeler, revenir, ou ni l'un ni
    /// l'autre.
    ///
    /// La reconnaissance se fait sur les octets et non sur ce que le cœur a
    /// exécuté, parce qu'elle doit avoir lieu **avant** l'exécution : après,
    /// RIP est déjà ailleurs et on ne sait plus d'où l'on venait.
    enum ControlFlow { case call, ret, other }

    static func callsOrReturns(_ instruction: X86Instruction) -> ControlFlow {
        guard instruction.map == .oneByte else { return .other }
        switch instruction.opcode {
        case 0xE8: return .call            // call rel32
        case 0xC2, 0xC3: return .ret       // ret, ret imm16
        case 0xFF:
            // Le groupe 5 : `/2` appelle, `/3` appelle au loin, et les autres
            // sautent ou empilent. Sans ModRM il n'y a rien à lire.
            guard let modrm = instruction.modrm else { return .other }
            let field = (modrm >> 3) & 0x07
            return field == 2 || field == 3 ? .call : .other
        default: return .other
        }
    }

    /// Un retour qui ne rend pas la main là où l'appel l'avait promis.
    public struct BrokenReturn: Sendable, Equatable {
        /// Le `ret` lui-même, et où il est allé.
        public let at: UInt64
        public let taken: UInt64
        /// Ce que le `call` avait empilé, et où il était.
        public let promised: UInt64
        public let calledAt: UInt64
        /// La pile au moment de l'appel et au moment du retour. Si elles
        /// diffèrent, quelqu'un l'a bougée entre les deux.
        public let stackAtCall: UInt64
        public let stackAtReturn: UInt64
        public let retired: UInt64

        public var description: String {
            String(format:
                "ret à %llx est parti à %llx, mais le call de %llx avait promis %llx"
                + " (pile %llx puis %llx) après %llu instructions",
                at, taken, calledAt, promised, stackAtCall, stackAtReturn, retired)
        }
    }

    /// Ce qu'un appel laisse derrière lui.
    public struct PendingReturn: Sendable, Equatable {
        public let promised: UInt64
        public let calledAt: UInt64
        public let stack: UInt64
    }

    /// Combien de désaccords on retient. Le premier est celui qui compte ; les
    /// suivants ne font que le suivre.
    public static let brokenReturnLimit = 8
    /// La profondeur de la pile d'ombre. Au-delà, on oublie le fond plutôt que
    /// de grandir sans fin : un programme qui récurse profond n'est pas un
    /// défaut.
    public static let shadowStackDepth = 4096

    /// À appeler juste après un `call` d'anneau trois.
    mutating func rememberCall(promised: UInt64, at: UInt64) {
        if shadowStack.count >= Self.shadowStackDepth { shadowStack.removeFirst() }
        shadowStack.append(PendingReturn(
            promised: promised, calledAt: at, stack: registers[4]))
    }

    /// À appeler juste après un `ret` d'anneau trois.
    ///
    /// **Un retour sans appel connu n'est pas un désaccord.** La pile d'ombre
    /// commence vide au milieu d'un programme déjà lancé, et les premiers
    /// retours dépilent des appels qu'on n'a pas vus. Les taire est le seul
    /// choix honnête.
    ///
    /// **Et c'est le cadre qui apparie, pas l'ordre.** La première version se
    /// contentait de dépiler, et le vrai démarrage l'a démolie en une
    /// exécution : elle a rendu quatre désaccords dont les propres chiffres la
    /// contredisaient — la pile y était *identique* à l'appel et au retour,
    /// alors qu'un couple équilibré doit montrer huit octets d'écart. La cause
    /// est légitime et courante : un **saut de queue**. `jmp *GOT` entre
    /// directement dans une fonction qui rendra la main à l'appelant
    /// d'origine, et ce `ret`-là n'a pas de `call` à lui. Chaque saut de queue
    /// décale la pile d'ombre d'un cran, et tout ce qui suit devient faux.
    ///
    /// On jette donc les promesses dont le cadre est déjà abandonné, et on ne
    /// compare que si le sommet correspond exactement à l'endroit d'où ce
    /// `ret` vient de dépiler.
    mutating func rememberReturn(taken: UInt64, at: UInt64) {
        // Le `ret` a déjà dépilé : le cadre dont il vient est huit octets plus
        // bas que la pile d'à présent.
        let frame = registers[4] &- 8
        while let top = shadowStack.last, top.stack < frame { shadowStack.removeLast() }
        guard let pending = shadowStack.last, pending.stack == frame else {
            noteUnmatchedReturn(taken: taken, at: at, frame: frame)
            return
        }
        shadowStack.removeLast()
        guard pending.promised != taken else { return }
        guard brokenReturns.count < Self.brokenReturnLimit else { return }
        brokenReturns.append(BrokenReturn(
            at: at, taken: taken, promised: pending.promised,
            calledAt: pending.calledAt, stackAtCall: pending.stack,
            stackAtReturn: registers[4], retired: retired))
    }

    /// Un retour dont aucune promesse ne porte le cadre.
    ///
    /// **Ces silences sont l'endroit où chercher.** La version d'avant les
    /// taisait, et c'était le bon choix tant qu'on ne savait pas quoi en
    /// faire : la pile d'ombre commence vide au milieu d'un programme déjà
    /// lancé, et les premiers retours dépilent forcément des appels qu'on n'a
    /// pas vus. Mais le `ret` qui envoie `/init` dans des données est passé par
    /// là — il n'a été ni accusé, ni compté. Un instrument qui écarte un cas
    /// doit dire combien de fois il l'a fait.
    public struct UnmatchedReturn: Sendable, Equatable {
        public let at: UInt64
        public let taken: UInt64
        /// Le cadre d'où ce `ret` vient de dépiler.
        public let frame: UInt64
        /// La promesse en attente la plus récente, s'il y en a une, et son
        /// cadre. Zéro quand la pile d'ombre est vide.
        public let pendingPromise: UInt64
        public let pendingFrame: UInt64
        public let retired: UInt64
        /// Ce qui a bougé la pile juste avant, du plus ancien au plus récent.
        /// C'est là que se lit qui a laissé un mot de trop.
        public let moves: [StackMove]

        public var description: String {
            let waiting = pendingFrame == 0
                ? "aucune promesse en attente"
                : String(format: "la plus récente promettait %llx au cadre %llx",
                         pendingPromise, pendingFrame)
            return String(format: "ret à %llx est parti à %llx depuis le cadre %llx",
                          at, taken, frame)
                + " — " + waiting + String(format: ", après %llu instructions", retired)
                + (moves.isEmpty ? "" : "\n" + moves.map { "      " + $0.description }
                    .joined(separator: "\n"))
        }
    }

    public static let unmatchedReturnLimit = 16

    mutating func noteUnmatchedReturn(taken: UInt64, at: UInt64, frame: UInt64) {
        guard unmatchedReturns.count < Self.unmatchedReturnLimit else { return }
        let top = shadowStack.last
        unmatchedReturns.append(UnmatchedReturn(
            at: at, taken: taken, frame: frame,
            pendingPromise: top?.promised ?? 0, pendingFrame: top?.stack ?? 0,
            retired: retired, moves: stackMoves))
    }

    /// Un changement d'anneau ou d'espace d'adressage rend la pile d'ombre
    /// caduque : ce n'est plus le même programme, et comparer ses retours à
    /// ceux d'un autre ne voudrait rien dire.
    mutating func forgetShadowStack() {
        shadowStack.removeAll(keepingCapacity: true)
    }
}
