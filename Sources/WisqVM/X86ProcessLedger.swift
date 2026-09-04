import Foundation

// **Qui tourne, et qui attend quoi.**
//
// Alpine s'arrête sur « Mounting boot media: » et n'en sort plus. On sait
// maintenant que ce n'est pas une instruction (neuf corpus), pas la pile
// (0 passage d'anneau qui la corrompe), pas l'horloge (RDTSC avance), pas
// la console (ttyS0 est enregistrée), et pas un enfant de `fork()` qui
// meurt (0 saut non résolu sur 946). nlplug-findfs attend sans limite tant
// qu'un de ses enfants n'est pas terminé, ou que son fil de parcours de
// `/sys` n'a pas fini. La question est donc celle qu'un `ps -T` poserait :
// **quels fils existent, lequel a la main, et sur quel appel système les
// autres sont-ils partis — avec quels arguments ?**
//
// Ce registre tient, par fil — un espace d'adressage et un pointeur de
// fil, la base de FS —, le nombre d'instructions d'anneau trois exécutées,
// le nombre d'appels système, le dernier avec ses trois premiers arguments
// (c'est lui qui dit sur quoi un fil bloque : `futex(adresse, WAIT, …)` ne
// se lit pas comme `futex(adresse, WAKE, …)`), la dernière faute livrée au
// noyau depuis ce fil, et l'instant de sa dernière activité.
//
// **Le noyau recycle les CR3.** Un processus parti par `exit_group` ou
// remplacé par `execve` et dont l'espace d'adressage réapparaît est un
// autre processus : le registre repart de zéro pour lui plutôt que
// d'additionner deux vies. L'instruction de sortie elle-même appartient à
// la vie qui se termine — la première version la comptait dans la
// suivante, et le rapport montrait quatre processus « d'une instruction »
// qui n'étaient que les fantômes de sorties ordinaires.
extension X86Core {
    public struct ThreadKey: Hashable, Sendable {
        public let addressSpace: UInt64
        public let threadPointer: UInt64
    }

    public struct ThreadActivity: Sendable, Equatable {
        public let key: ThreadKey
        public var instructions: UInt64 = 0
        public var systemCalls: UInt64 = 0
        public var lastSystemCall: UInt64?
        public var lastArguments: [UInt64] = []
        public var lastRip: UInt64 = 0
        public let firstSeen: UInt64
        public var lastSeen: UInt64 = 0
        /// La sortie est demandée par l'instruction en cours ; elle sera
        /// effective à l'instruction suivante.
        var exiting = false
        public var exited = false
        /// La dernière faute livrée au noyau depuis ce fil, et d'où.
        public var lastFault: String?

        /// Les numéros de l'ABI x86-64 qui disent sur quoi on attend, et ceux
        /// qui font naître ou mourir. Les autres sortent en chiffres.
        public static let systemCallNames: [UInt64: String] = [
            0: "read", 1: "write", 2: "open", 3: "close", 7: "poll", 9: "mmap",
            13: "rt_sigaction", 14: "rt_sigprocmask", 15: "rt_sigreturn",
            22: "pipe", 34: "pause", 35: "nanosleep", 39: "getpid", 56: "clone",
            57: "fork", 58: "vfork", 59: "execve", 60: "exit", 61: "wait4",
            62: "kill", 72: "fcntl", 96: "gettimeofday", 186: "gettid",
            202: "futex", 228: "clock_gettime", 230: "clock_nanosleep",
            231: "exit_group", 232: "epoll_wait", 247: "waitid", 257: "openat",
            270: "pselect6", 271: "ppoll", 281: "epoll_pwait", 282: "signalfd",
            289: "signalfd4", 290: "eventfd2", 313: "finit_module", 435: "clone3",
        ]

        public var description: String {
            let last = lastSystemCall.map {
                (Self.systemCallNames[$0] ?? "appel") + "(\($0))"
                    + "(" + lastArguments.map { String($0, radix: 16) }.joined(separator: ", ") + ")"
            } ?? "aucun"
            return String(format: "cr3=%llx fs=%llx : %llu instructions, %llu appels, dernier %@,"
                          + " rip %llx, vu de %llu à %llu%@%@",
                          key.addressSpace, key.threadPointer, instructions, systemCalls,
                          last, lastRip, firstSeen, lastSeen,
                          exited ? " — sorti" : "",
                          lastFault.map { " — dernière faute : " + $0 } ?? "")
        }
    }

    var currentThreadKey: ThreadKey {
        ThreadKey(addressSpace: system.control[3],
                  threadPointer: system.modelSpecific[X86SystemState.fsBase] ?? 0)
    }

    private mutating func threadEntry(_ key: ThreadKey) -> ThreadActivity {
        guard let entry = threadActivity[key] else {
            return ThreadActivity(key: key, firstSeen: retired)
        }
        // Un fil qui revit après sa sortie est un autre fil qui a hérité de
        // ses pages de tables.
        return entry.exited ? ThreadActivity(key: key, firstSeen: retired) : entry
    }

    /// À appeler quand une instruction d'anneau trois aboutit, témoin armé.
    mutating func noteProcessActivity(at rip: UInt64) {
        let key = currentThreadKey
        var entry = threadEntry(key)
        entry.instructions &+= 1
        entry.lastRip = rip
        entry.lastSeen = retired
        if entry.exiting { entry.exiting = false; entry.exited = true }
        threadActivity[key] = entry
    }

    /// À appeler à chaque `SYSCALL` d'anneau trois, témoin armé.
    mutating func noteSystemCall(_ number: UInt64) {
        let key = currentThreadKey
        var entry = threadEntry(key)
        entry.systemCalls &+= 1
        entry.lastSystemCall = number
        entry.lastArguments = [registers[7], registers[6], registers[2]]
        entry.lastSeen = retired
        // `exit`, `exit_group`, et `execve` qui remplace l'espace
        // d'adressage : la vie s'arrête à cette instruction.
        if number == 60 || number == 231 || number == 59 { entry.exiting = true }
        threadActivity[key] = entry
    }

    /// À appeler quand une faute d'anneau trois est livrée au noyau.
    mutating func noteFault(_ fault: Fault, at rip: UInt64) {
        let key = currentThreadKey
        var entry = threadEntry(key)
        let what: String
        switch fault {
        case .pageFault(let address):
            what = String(format: "#PF à %llx (code %llx)", address, pageFaultErrorCode)
        case .divideError: what = "#DE"
        case .outsideMemory(let address): what = String(format: "hors mémoire %llx", address)
        case .unsupported(let name): what = name
        }
        entry.lastFault = what + String(format: " depuis %llx, après %llu instructions", rip, retired)
        threadActivity[key] = entry
    }

    /// Les fils, le plus récemment actif en premier.
    public var threadsByLastActivity: [ThreadActivity] {
        threadActivity.values.sorted { $0.lastSeen > $1.lastSeen }
    }
}
