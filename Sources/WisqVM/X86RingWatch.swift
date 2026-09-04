import Foundation

// La pile d'un programme traverse-t-elle un passage d'anneau sans bouger ?
//
// **Pourquoi ce fichier existe.** La pile d'ombre a rendu un chiffre, et il
// est systématique : le `ret` qui envoie `/init` dans des données dépile un
// mot situé **exactement huit octets** sous celui que l'appel avait posé —
// quatre fois sur quatre, dans trois processus différents.
//
// Le `ret` fautif est le dernier de `_Fork`, et la fonction est équilibrée :
// `push %rbp ; push %rbx ; sub $0x88` à l'entrée, `add $0x88 ; pop %rbx ;
// pop %rbp` à la sortie. Entre les deux il y a deux appels, un `syscall`, et
// rien qui puisse laisser un mot de trop.
//
// Reste un seul endroit où la pile d'un programme peut bouger sans que le
// programme y soit pour quelque chose : **le passage en anneau zéro et le
// retour**. Une interruption sauve RSP dans son cadre et l'`IRETQ` le rend ;
// un `SYSCALL` ne touche pas à la pile du tout, et c'est le noyau qui range
// puis restaure. Si l'un des deux rend une pile décalée, le programme reprend
// huit octets plus bas sans rien pouvoir y faire — et c'est exactement la
// forme du défaut.
//
// Ce témoin note RSP au moment où l'on quitte l'anneau trois, et le compare à
// celui du retour. **Il ne juge pas** : un noyau a parfaitement le droit de
// rendre une pile différente — il le fait à chaque `execve`, à chaque livraison
// de signal, à chaque changement de tâche. Le rapport dit ce qui a changé ; à
// l'œil de dire si le changement était dû.
extension X86Core {
    /// Un aller-retour en anneau zéro, et ce que la pile en a retenu.
    public struct RingTrip: Sendable, Equatable {
        /// L'instruction d'anneau trois qui a provoqué le passage, et pourquoi.
        public let at: UInt64
        public let cause: Cause
        /// RSP en partant, et RSP en revenant.
        public let leaving: UInt64
        public let returning: UInt64
        /// Où le programme reprend.
        public let resumed: UInt64
        public let retired: UInt64

        public enum Cause: String, Sendable {
            case systemCall = "syscall"
            case fault = "faute"
            case interrupt = "interruption"
        }

        /// De combien la pile a bougé. Négatif veut dire « plus bas », donc
        /// plus profond — le sens qui fait qu'un `ret` dépile un mot de trop.
        public var shift: Int64 { Int64(bitPattern: returning &- leaving) }

        public var description: String {
            String(format: "%@ à %llx : rsp %llx → %llx (%+lld), reprise à %llx"
                   + ", après %llu instructions",
                   cause.rawValue, at, leaving, returning, shift, resumed, retired)
        }
    }

    /// Combien d'aller-retours **décalés** on retient. Ceux qui rendent la
    /// pile intacte ne sont pas gardés : il y en a des millions, et ils
    /// n'apprennent rien.
    public static let ringTripLimit = 16

    /// À appeler au moment de quitter l'anneau trois.
    mutating func leavingRingThree(at: UInt64, cause: RingTrip.Cause) {
        ringDeparture = (at, cause, registers[4], retired)
    }

    /// À appeler au moment d'y revenir. Rien n'est retenu quand la pile est
    /// rendue telle quelle, ce qui est le cas courant.
    mutating func returningToRingThree() {
        guard let departure = ringDeparture else { return }
        ringDeparture = nil
        guard departure.stack != registers[4] else { return }
        guard ringTrips.count < Self.ringTripLimit else { return }
        ringTrips.append(RingTrip(
            at: departure.at, cause: departure.cause, leaving: departure.stack,
            returning: registers[4], resumed: rip, retired: departure.retired))
    }
}
