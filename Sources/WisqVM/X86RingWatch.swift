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
// celui du retour.
//
// **« Attendu » n'est pas « vérifié ».** La première version disait « 918
// décalent la pile » et s'arrêtait là, avec un commentaire expliquant qu'un
// noyau a le droit de rendre une pile différente — à chaque `execve`, à chaque
// signal, à chaque changement de tâche. C'est vrai, et c'est précisément ce
// qui rendait le nombre inutilisable : il mélange trois choses, dont deux sont
// légitimes, et il ne dit pas dans quelles proportions. Neuf cent dix-huit
// décalages « probablement tous normaux » et neuf cent seize normaux plus deux
// défauts se lisent exactement pareil.
//
// **Deux faits certains suffisent à les séparer**, et aucun des deux ne
// demande d'interpréter quoi que ce soit :
//
//   * **L'espace d'adressage a-t-il changé ?** Si CR3 diffère entre le départ
//     et le retour, ce n'est plus le même programme : comparer sa pile à celle
//     d'un autre ne veut rien dire.
//   * **Le programme reprend-il là où il en était ?** Une instruction fautive
//     redémarre à son adresse ; un appel système continue juste après. Comme
//     aucune instruction x86 ne dépasse quinze octets, toute reprise au-delà
//     est un **détournement** du flot par le noyau — la livraison d'un signal
//     — et déplacer la pile est alors son droit.
//
// Reste le seul cas qui accuse : **même programme, reprise là où l'on était,
// et pourtant la pile a bougé.** C'est exactement la forme du défaut que la
// pile d'ombre avait fait apparaître, et c'est ce nombre-là qu'il faut lire.
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
        /// L'espace d'adressage au départ et au retour. S'ils diffèrent, ce
        /// n'est plus le même programme.
        public let leavingSpace: UInt64
        public let returningSpace: UInt64
        public let retired: UInt64

        /// Ce qui explique le décalage — ou rien, et c'est le cas qui compte.
        public enum Explanation: String, Sendable {
            case otherProgram = "autre programme"
            case redirected = "flot détourné"
            case unexplained = "inexpliqué"
        }

        public var explanation: Explanation {
            guard leavingSpace == returningSpace else { return .otherProgram }
            // Redémarrage à l'adresse fautive, ou continuation juste après :
            // aucune instruction x86 ne fait plus de quinze octets, donc au
            // delà c'est le noyau qui a détourné le flot.
            let ahead = resumed &- at
            return ahead <= UInt64(X86Instruction.maximumLength)
                ? .unexplained : .redirected
        }

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
                + " — " + explanation.rawValue
                + (explanation == .otherProgram
                    ? String(format: " (cr3 %llx → %llx)", leavingSpace, returningSpace)
                    : "")
        }
    }

    /// Ce que le témoin a vu passer, et non pas seulement ce qu'il a retenu.
    ///
    /// Un témoin qui ne garde que les cas remarquables rend un rapport où
    /// « aucun » a deux sens : *j'ai regardé des millions de fois et tout
    /// allait bien*, et *je n'ai jamais été appelé*. Ces deux-là ne se
    /// distinguent pas à l'œil, et le second est un défaut d'instrument qui
    /// se lit comme un résultat. Le compte les sépare.
    public struct RingTally: Sendable, Equatable {
        /// Les passages achevés — partis de l'anneau trois et revenus —
        /// rangés par ce qui les a provoqués.
        public var systemCalls: UInt64 = 0
        public var faults: UInt64 = 0
        public var interrupts: UInt64 = 0
        /// Ceux qui ont rendu une pile décalée, y compris au-delà de ce que
        /// `ringTripLimit` permet de garder.
        public var shifted: UInt64 = 0
        /// Et la répartition de ces décalages. Les deux premiers sont dus ;
        /// seul le troisième accuse.
        public var otherProgram: UInt64 = 0
        public var redirected: UInt64 = 0
        public var unexplained: UInt64 = 0
        /// Les départs recouverts par un autre avant d'être revenus : une
        /// faute pendant un appel système, par exemple. Le témoin ne suit
        /// qu'un départ à la fois et le dit plutôt que de le taire.
        public var abandoned: UInt64 = 0

        public var total: UInt64 { systemCalls + faults + interrupts }

        mutating func count(_ cause: RingTrip.Cause) {
            switch cause {
            case .systemCall: systemCalls += 1
            case .fault: faults += 1
            case .interrupt: interrupts += 1
            }
        }

        public var description: String {
            guard total > 0 || abandoned > 0 else {
                return "aucun — le témoin n'a jamais été appelé"
            }
            var said = "\(total) achevés (syscall \(systemCalls),"
                + " faute \(faults), interruption \(interrupts))"
            if abandoned > 0 { said += ", \(abandoned) recouverts" }
            guard shifted > 0 else { return said + ", aucun ne décale la pile" }
            said += ", dont \(shifted) décalent la pile"
                + " (\(otherProgram) autre programme, \(redirected) flot détourné,"
                + " \(unexplained) inexpliqué\(unexplained > 1 ? "s" : ""))"
            return said
        }
    }

    /// Combien d'aller-retours **inexpliqués** on retient. Ceux qui rendent
    /// la pile intacte ne sont pas gardés — il y en a des millions — et ceux
    /// dont le décalage s'explique non plus : les garder noierait les seuls
    /// qui accusent. Le compte, lui, les voit tous, rangés par explication.
    public static let ringTripLimit = 16

    /// À appeler au moment de quitter l'anneau trois.
    mutating func leavingRingThree(at: UInt64, cause: RingTrip.Cause) {
        if ringDeparture != nil { ringPassages.abandoned += 1 }
        ringDeparture = (at, cause, registers[4], system.control[3], retired)
    }

    /// À appeler au moment d'y revenir. Rien n'est retenu quand la pile est
    /// rendue telle quelle, ce qui est le cas courant.
    mutating func returningToRingThree() {
        guard let departure = ringDeparture else { return }
        ringDeparture = nil
        ringPassages.count(departure.cause)
        guard departure.stack != registers[4] else { return }
        ringPassages.shifted += 1
        let trip = RingTrip(
            at: departure.at, cause: departure.cause, leaving: departure.stack,
            returning: registers[4], resumed: rip,
            leavingSpace: departure.space, returningSpace: system.control[3],
            retired: departure.retired)
        switch trip.explanation {
        case .otherProgram: ringPassages.otherProgram += 1
        case .redirected: ringPassages.redirected += 1
        case .unexplained: ringPassages.unexplained += 1
        }
        // Seuls les inexpliqués sont gardés : les autres sont dus, et les
        // retenir noierait ceux-là.
        guard trip.explanation == .unexplained else { return }
        guard ringTrips.count < Self.ringTripLimit else { return }
        ringTrips.append(trip)
    }
}
