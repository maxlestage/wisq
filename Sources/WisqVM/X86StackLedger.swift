import Foundation

// Qui a bougé la pile, et de combien.
//
// **Pourquoi ce fichier existe.** Quatre fois sur quatre, dans trois
// processus différents, le `ret` qui envoie `/init` dans des données dépile
// un mot situé huit octets **sous** celui que l'appel avait posé. La fonction
// est équilibrée, et le témoin d'anneau a mesuré 2 127 passages achevés sans
// qu'aucun ne décale la pile : ce n'est donc ni le programme, ni le noyau.
//
// Reste une seule façon d'avancer, et ce n'est pas de lire du désassemblage
// en pariant — trois récits de ce genre ont déjà été démentis par la mesure
// aujourd'hui. C'est de **regarder RSP changer**, instruction par
// instruction, et de garder les derniers changements pour les montrer au
// moment où le retour tombe à côté.
//
// Le registre est circulaire et de taille fixe : rien ne s'alloue pendant la
// course, et les six milliards d'instructions passent sans que la mémoire
// bouge. Il ne garde que les dernières traces — s'il faut remonter plus loin,
// ce sera au vu de ce qu'elles montrent, pas par précaution.
extension X86Core {
    /// Une instruction qui a changé RSP, et ce qu'elle en a fait.
    public struct StackMove: Sendable, Equatable {
        /// L'instruction : son adresse, son opcode, son ModRM et sa longueur.
        /// Pas ses octets — les relire coûterait un accès mémoire par
        /// mouvement, et l'adresse suffit à la retrouver au désassembleur.
        public let at: UInt64
        public let opcode: UInt8
        public let modrm: UInt8
        public let length: Int
        /// RSP avant et après.
        public let from: UInt64
        public let to: UInt64
        public let retired: UInt64

        /// Combien la pile a bougé. Négatif veut dire « plus bas », donc
        /// empilé ; positif veut dire dépilé.
        public var delta: Int64 { Int64(bitPattern: to &- from) }

        static let none = StackMove(at: 0, opcode: 0, modrm: 0, length: 0,
                                    from: 0, to: 0, retired: 0)

        public var description: String {
            String(format: "%llx [%02x/%02x len %d] : rsp %llx → %llx (%+lld)"
                   + ", après %llu instructions",
                   at, opcode, modrm, length, from, to, delta, retired)
        }
    }

    /// Combien de mouvements on garde. Le `ret` fautif est à dix-sept octets
    /// de l'appel qui le précède : trente-deux couvre largement une épilogue
    /// et ce qui la précède.
    public static let stackLedgerDepth = 32

    /// À appeler après chaque instruction d'anneau trois qui a changé RSP.
    mutating func noteStackMove(at: UInt64, from: UInt64, to: UInt64,
                                _ instruction: X86Instruction) {
        stackLedger[stackLedgerNext] = StackMove(
            at: at, opcode: instruction.opcode, modrm: instruction.modrm ?? 0,
            length: instruction.length, from: from, to: to, retired: retired)
        stackLedgerNext = (stackLedgerNext + 1) % Self.stackLedgerDepth
    }

    /// Les mouvements gardés, du plus ancien au plus récent, sans les cases
    /// jamais écrites.
    public var stackMoves: [StackMove] {
        let ordered = Array(stackLedger[stackLedgerNext...])
            + Array(stackLedger[..<stackLedgerNext])
        return ordered.filter { $0 != StackMove.none }
    }
}
