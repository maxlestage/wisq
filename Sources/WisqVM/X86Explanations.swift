import Foundation

/// **Ce que l'application affiche quand une machine PC ne démarre pas.**
///
/// Sans description, iOS rend « L'opération n'a pas pu s'achever.
/// (WisqVM.X86Core.Fault erreur 2.) » : le numéro d'un cas d'énumération,
/// qui ne dit ni ce qui manque ni quoi faire. C'est ce qu'une capture a
/// montré, pour un initramfs qui ne tenait pas dans la machine.
extension X86Core.Fault: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupported(let what):
            return "le processeur de wisq ne sait pas encore exécuter \(what)."
        case .divideError:
            return "une division par zéro hors de toute gestion d'erreur de l'invité."
        case .pageFault(let address):
            return String(format: "une adresse que les tables de pages ne traduisent pas (0x%llx).", address)
        case .outsideMemory(let address):
            return String(format: "un accès hors de la mémoire de la machine (0x%llx).", address)
        }
    }
}

extension X86BootLoader.LoadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAKernel:
            return "ce fichier n'est pas un noyau Linux pour PC."
        case .noSixtyFourBitEntry:
            return "ce noyau n'a pas de point d'entrée 64 bits."
        case .protocolTooOld(let version):
            return String(format: "ce noyau parle une version trop ancienne du protocole de démarrage (%d.%02d).",
                          version >> 8, version & 0xFF)
        case .notEnoughMemory(let needed, let available):
            return """
                le noyau et son initramfs demandent \(KernelMemory.describe(UInt64(needed))), \
                et la machine n'a que \(KernelMemory.describe(UInt64(available))). \
                Montez le curseur de mémoire de cette machine.
                """
        case .truncated:
            return "ce noyau est plus court que ce que son en-tête annonce : le fichier est incomplet."
        }
    }
}
