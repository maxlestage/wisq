import Foundation

// Ce que le noyau pose sur la pile d'un processus neuf.
//
// **Pourquoi ce fichier existe.** Cinq corpus matériels ont épuisé le jeu
// d'instructions : en comptant les mnémoniques du vrai chargeur de l'invité
// contre eux, il ne reste plus une seule instruction entière non couverte en
// dehors de `syscall`, `hlt`, `nop`, `pause` et trois préfixes — dont aucun
// ne calcule. Une instruction mal exécutée n'explique donc plus le fait que
// `/init` appelle une fonction et atterrisse dans `fork()`.
//
// Ce qui reste, c'est ce que la machine **fournit**. Quand `execve` réussit,
// le noyau construit une pile initiale dont la forme est fixée par l'ABI :
//
//     RSP →  argc
//            argv[0] … argv[argc-1]   NULL
//            envp[0] … envp[n-1]      NULL
//            type₀ valeur₀ … AT_NULL 0
//
// La dernière partie est le **vecteur auxiliaire**, et c'est par lui que le
// chargeur apprend où sont ses propres tables : `AT_PHDR` l'adresse des
// en-têtes de programme, `AT_BASE` sa propre base, `AT_ENTRY` le point
// d'entrée du programme. Un chargeur qui lit là de mauvaises tables résout
// contre les mauvais symboles — et tout le reste suit.
//
// Ce témoin lit cette pile telle qu'elle est au moment où le programme prend
// la main, et rend ce qu'il y trouve. Il ne juge pas : il montre.
extension X86Core {
    /// Une entrée du vecteur auxiliaire, avec son nom quand on le connaît.
    public struct Auxiliary: Sendable, Equatable {
        public let type: UInt64
        public let value: UInt64

        /// Les noms de l'ABI. Ceux qui manquent sortent en chiffres : nommer
        /// au hasard serait pire que de ne pas nommer.
        public static let names: [UInt64: String] = [
            0: "AT_NULL", 1: "AT_IGNORE", 2: "AT_EXECFD", 3: "AT_PHDR",
            4: "AT_PHENT", 5: "AT_PHNUM", 6: "AT_PAGESZ", 7: "AT_BASE",
            8: "AT_FLAGS", 9: "AT_ENTRY", 10: "AT_NOTELF", 11: "AT_UID",
            12: "AT_EUID", 13: "AT_GID", 14: "AT_EGID", 15: "AT_PLATFORM",
            16: "AT_HWCAP", 17: "AT_CLKTCK", 23: "AT_SECURE",
            24: "AT_BASE_PLATFORM", 25: "AT_RANDOM", 26: "AT_HWCAP2",
            31: "AT_EXECFN", 33: "AT_SYSINFO_EHDR", 51: "AT_MINSIGSTKSZ",
        ]

        public var description: String {
            let name = Self.names[type] ?? "AT_\(type)"
            return String(format: "%@=%llx", name, value)
        }
    }

    /// Ce qu'on retient du démarrage d'un processus.
    public struct ProcessStart: Sendable, Equatable {
        /// L'espace d'adressage, qui identifie le processus.
        public let addressSpace: UInt64
        /// Où le programme commence, et sur quelle pile.
        public let entry: UInt64
        public let stack: UInt64
        public let argumentCount: UInt64
        /// Le vecteur auxiliaire, dans l'ordre où le noyau l'a posé.
        public let auxiliary: [Auxiliary]
        public let retired: UInt64

        public var description: String {
            String(format: "cr3=%llx entrée=%llx pile=%llx argc=%llu",
                   addressSpace, entry, stack, argumentCount)
                + " — " + auxiliary.map(\.description).joined(separator: " ")
        }
    }

    /// Combien de démarrages on retient, **et ce sont les derniers**.
    ///
    /// La première version gardait les huit premiers, et le rapport disait
    /// « programmes démarrés : 8 » — c'est-à-dire exactement son plafond, un
    /// nombre qui ne comptait rien. Un démarrage d'Alpine en lance bien plus
    /// que huit, et les seuls qui comptaient — ceux de `mdev`, qui saute dans
    /// le vide — arrivaient trop tard pour être vus.
    ///
    /// C'est la même leçon que le registre des mouvements de pile et le témoin
    /// d'adresse ont déjà enseignée, et c'est la troisième fois : **ce qui
    /// compte est ce qui précède l'événement, pas ce qui ouvre la course.**
    public static let processStartLimit = 8

    /// Combien il y en a eu en tout. Sans lui, « huit » et « huit et
    /// quelques » se lisent pareil.
    public var processStartsSeen: UInt64 {
        get { processStartTally }
        set { processStartTally = newValue }
    }

    /// Les démarrages gardés, du plus ancien au plus récent.
    public var processesStarted: [ProcessStart] {
        processStartTally <= UInt64(Self.processStartLimit)
            ? processStarts
            : Array(processStarts[processStartNext...])
                + Array(processStarts[..<processStartNext])
    }

    /// À appeler quand un programme prend la main dans un espace d'adressage
    /// qu'on n'avait pas encore vu.
    ///
    /// **Rien n'est exigé ici, et c'est voulu.** Le témoin lit et rend ; c'est
    /// à un test, ou à un œil, de dire si ce qu'il montre est juste. Une pile
    /// illisible rend un démarrage sans vecteur plutôt qu'une erreur : un
    /// témoin qui lèverait en rendant compte serait pire que pas de témoin.
    mutating func noteProcessStart() {
        processStartTally &+= 1
        canonicalWatchArmed = false
        defer { canonicalWatchArmed = true }
        let stack = registers[4]
        let count = word(stack) ?? 0
        // Sauter argc, les arguments et leur NULL, puis l'environnement et le
        // sien : le vecteur auxiliaire commence après.
        var cursor = stack &+ 8 &+ (count &+ 1) &* 8
        var guardrail = 0
        while let value = word(cursor), value != 0, guardrail < 4096 {
            cursor &+= 8
            guardrail += 1
        }
        cursor &+= 8
        var auxiliary: [Auxiliary] = []
        while auxiliary.count < 40, let type = word(cursor),
              let value = word(cursor &+ 8) {
            auxiliary.append(Auxiliary(type: type, value: value))
            cursor &+= 16
            if type == 0 { break }
        }
        let start = ProcessStart(
            addressSpace: system.control[3], entry: rip, stack: stack,
            argumentCount: count, auxiliary: auxiliary, retired: retired)
        if processStarts.count < Self.processStartLimit {
            processStarts.append(start)
        } else {
            processStarts[processStartNext] = start
        }
        processStartNext = (processStartNext + 1) % Self.processStartLimit
    }

    /// Un mot de la mémoire de l'invité, ou rien si l'adresse ne s'y trouve
    /// pas.
    mutating func word(_ address: UInt64) -> UInt64? {
        guard let memory, let physical = try? translate(address) else { return nil }
        return try? memory.read(physical, 8)
    }
}
