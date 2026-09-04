import Foundation

// **Qui a sauté dans le vide ?**
//
// Une fois `FXSAVE` réparé, le démarrage d'Alpine va jusqu'à `mdev`, et c'est
// là qu'il bute : quatre processus meurent d'un saut vers une page absente,
// toujours à une adresse finissant par `8ad`. Le noyau le dit lui-même —
// l'adresse fautive **est** RIP, et le code d'erreur porte le bit de
// récupération d'instruction :
//
//     mdev[650]: segfault at 560592a778ad ip 0000560592a778ad … error 14
//     Code: Unable to access opcode bytes at 0x560592a77883.
//
// **Pourquoi les témoins existants ne suffisent pas.** Le témoin des
// démarrages nomme un processus par son CR3 et ne retient que les espaces
// d'adressage qu'il n'a pas encore vus ; or le noyau **recycle** les pages de
// tables, et les processus de `mdev` réutilisent des valeurs déjà croisées.
// Ils sont donc invisibles, et sans leur base de chargement le déplacement
// `8ad` ne se calcule pas.
//
// Ce témoin-ci n'a pas besoin de la base. Il note **d'où l'on venait** :
// `previousRip` est la dernière instruction d'anneau trois qui a abouti, et
// elle est, elle, dans du code cartographié. Une adresse de départ et les
// octets qui s'y trouvent suffisent à retrouver l'endroit dans le binaire, et
// c'est de là que la question repart.
//
// **Et il ne garde que les sauts dont le programme n'est pas revenu.** La
// première version gardait toutes les récupérations d'instruction sur une page
// absente, et la mesure l'a démolie en une exécution : neuf cent quatre, dont
// la quasi-totalité sont le cas le plus ordinaire du monde — une page de code
// chargée à la demande. Le noyau la pose, l'instruction reprend, et il ne s'est
// rien passé. Les seize gardés étaient tous de ceux-là, et les quatre qui
// tuaient `mdev` étaient parmi les huit cent quatre-vingt-huit jetés.
//
// Le discriminant ne demande pourtant rien de plus que ce qu'on a déjà : **une
// faute que le noyau résout reprend à la même adresse.** Celle qui tue le
// processus, non — la main revient ailleurs, dans un gestionnaire de signal ou
// dans un autre programme. Le témoin retient donc le saut *en attente*, et la
// première instruction d'anneau trois qui aboutit ensuite tranche : au même
// endroit, on oublie ; ailleurs, on garde.
extension X86Core {
    /// Un saut d'anneau trois vers une page qu'aucune table ne porte.
    public struct LostJump: Sendable, Equatable {
        /// L'adresse où l'on a atterri, et qui n'existe pas.
        public let at: UInt64
        /// La dernière instruction qui a abouti, et ses octets. C'est elle qui
        /// a fabriqué la destination.
        public let from: UInt64
        public let fromBytes: [UInt8]
        public let retired: UInt64

        static let none = LostJump(at: 0, from: 0, fromBytes: [], retired: 0)

        public var description: String {
            String(format: "saut vers %llx depuis %llx", at, from)
                + (fromBytes.isEmpty
                    ? ""
                    : " [" + fromBytes.map { String(format: "%02x", $0) }
                        .joined(separator: " ") + "]")
                + String(format: ", après %llu instructions", retired)
        }
    }

    /// Combien on en garde, **et ce sont les derniers**. La leçon est acquise :
    /// ce qui compte est ce qui précède l'événement.
    public static let lostJumpLimit = 16

    /// Les sauts gardés, du plus ancien au plus récent.
    public var jumpsLost: [LostJump] {
        lostJumpsUnresolved <= UInt64(Self.lostJumpLimit)
            ? lostJumps
            : Array(lostJumps[lostJumpNext...]) + Array(lostJumps[..<lostJumpNext])
    }

    /// À appeler quand une récupération d'instruction d'anneau trois tombe sur
    /// une page absente. Le saut est mis **en attente** : c'est la suite qui
    /// dira s'il comptait.
    mutating func noteLostJump(_ at: UInt64) {
        lostJumpTally &+= 1
        // Le témoin s'éteint pendant qu'il lit : relire passe par la
        // traduction, donc par l'endroit d'où l'on vient.
        let armed = canonicalWatchArmed
        canonicalWatchArmed = false
        defer { canonicalWatchArmed = armed }
        pendingLostJump = LostJump(at: at, from: previousRip,
                                   fromBytes: peek(previousRip), retired: retired)
    }

    /// À appeler quand une instruction d'anneau trois aboutit à `entry`. Si un
    /// saut était en attente et que la main revient ailleurs qu'à l'endroit
    /// visé, c'est que le noyau ne l'a pas résolu.
    mutating func settleLostJump(_ entry: UInt64) {
        guard let pending = pendingLostJump else { return }
        pendingLostJump = nil
        guard entry != pending.at else { return }
        lostJumpsUnresolved &+= 1
        if lostJumps.count < Self.lostJumpLimit {
            lostJumps.append(pending)
        } else {
            lostJumps[lostJumpNext] = pending
        }
        lostJumpNext = (lostJumpNext + 1) % Self.lostJumpLimit
    }
}
