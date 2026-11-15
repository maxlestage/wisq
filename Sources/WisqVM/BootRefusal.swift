import Foundation

/// **Un démarrage refusé avant la première instruction**, et la phrase qui le
/// dit.
///
/// **Pourquoi ce type.** Ces refus passaient par
/// `MachineLifecycle.guestFinished`, comme la fin d'un invité qui a tourné :
/// l'état valait `ended`, et « Arrêter », resté dans la barre, effaçait la
/// session rangée sous le nom de la course. Ce nom n'est connu qu'une fois
/// l'image lue ; un refus tombé avant (mémoire libre trop basse, image
/// illisible, déballage de l'ISO qui échoue, noyau trop grand pour la machine
/// RISC-V…) laissait celui de la course **précédente**, et c'est la session
/// d'une autre machine qu'« Arrêter » effaçait sans un mot. Un refus tombé
/// après, sur une session lisible dont la reprise n'a pas pu se faire (un
/// disque qui ne se branche plus), effaçait la sienne.
///
/// La règle, maintenant : **un refus de démarrage ne touche jamais à une
/// session sauvée.** Il passe par `MachineLifecycle.refusedToStart`, qui rend
/// toujours `.nothing`, et il se dit à l'écran (`explanation`). Rien n'a
/// tourné, donc rien n'est à arrêter ; « Oublier » reste le geste qui efface.
///
/// Ici plutôt que dans l'application, comme `SavedSession` : la décision et
/// les phrases se jugent sous Linux, la liaison seule est dans `LocalVMModel`.
public enum BootRefusal: Equatable, Sendable {
    /// La mémoire réglée dépasse ce que le téléphone a de libre maintenant.
    case notEnoughRoom(requested: UInt64, ceiling: UInt64)
    /// L'image apportée ne se lit pas, ou son déballage échoue : la phrase
    /// d'`IsoBoot.explanation`, rédigée dans la cible Rust.
    case image(String)
    /// Un initramfs touché à la place de son noyau.
    case bootMedia
    /// Un noyau pour un processeur que wisq n'émule pas : la phrase de
    /// `KernelImageKind.cannotRunHereExplanation`.
    case cannotRunHere(String)
    /// Une image trop grande pour la mémoire de la machine RISC-V.
    case tooLargeForRiscv(size: Int, ramSize: UInt32)
    /// Le noyau ne se lit pas : ce que le système de fichiers en dit.
    case unreadableKernel(String)
    /// Une machine PC qui ne tient pas dans la mémoire libre : `minimumRAM`
    /// est le plancher du système de l'image, quand elle en donne un.
    case pcNeedsMoreRoom(minimumRAM: Int, room: UInt64)
    /// Un noyau de PC sans initramfs, pour un démarrage à froid.
    case pcNeedsInitramfs
    /// La session sauvée ne se relit pas : voir `SavedSession`.
    case session(SavedSession.Unreadable)
    /// **Le démarrage a échoué sur le fil d'émulation**, avant la première
    /// instruction : un disque qui ne se branche pas, un noyau que le
    /// chargeur refuse, un initramfs qui ne se lit plus. `sessionKept` : une
    /// session lisible attendait d'être reprise, et elle reste où elle est.
    case couldNotStart(String, sessionKept: Bool)

    /// **Une session sauvée est en jeu**, et la console promet qu'elle est
    /// gardée : l'état devient `refused` plutôt que `notStarted`. Les deux se
    /// comportent de même ; le nom dit ce que la personne a lu.
    public var keepsASession: Bool {
        switch self {
        case .session: return true
        case .couldNotStart(_, let kept): return kept
        default: return false
        }
    }

    /// **Ce que la personne lit**, dans la console, à la place d'un démarrage.
    /// `name` : le fichier qu'elle a touché.
    public func explanation(name: String) -> String {
        switch self {
        case .notEnoughRoom(let requested, let ceiling):
            return KernelMemory.notEnoughRoomExplanation(requested: requested, ceiling: ceiling, name: name)
        case .image(let text), .cannotRunHere(let text):
            return text
        case .bootMedia:
            return """
                \(name) est un fichier compressé — wisq le garde comme \
                initramfs.

                Un initramfs ne démarre pas tout seul : c'est le noyau qui le \
                déballe. Touchez le noyau — `vmlinuz…`, `bzImage` — et wisq \
                prendra celui-ci avec.
                """
        case .tooLargeForRiscv(let size, let ramSize):
            return LinuxMachine.tooLargeExplanation(size: size, name: name, ramSize: ramSize)
        case .unreadableKernel(let reason):
            return "Démarrage impossible : \(reason)"
        case .pcNeedsMoreRoom(let minimumRAM, let room):
            // Le plancher qui a joué est celui qu'on nomme : celui du système
            // démarré, quand il dépasse celui de la machine.
            let need = minimumRAM > X86Machine.minimumRAMSize
                ? "le système de cette image a besoin d'au moins \(minimumRAM >> 20) Mo pour démarrer."
                : "une machine PC a besoin d'au moins \(X86Machine.minimumRAMSize >> 20) Mo — son noyau "
                    + "décompressé en fait trente-cinq à lui seul."
            return """
                \(name) est un noyau pour PC, et \(need)

                Cet appareil n'a que \(room >> 20) Mo de libre en ce moment. \
                Fermez ce qui tourne à côté et réessayez.
                """
        case .pcNeedsInitramfs:
            return """
                \(name) est un noyau pour PC, et un noyau de PC a besoin d'un \
                initramfs pour démarrer : ses pilotes de disque n'y sont pas \
                compilés, ils vivent dedans.

                Importez celui de votre distribution — il s'appelle \
                `initramfs-…` ou `initrd.img-…`, et il est compressé — et wisq \
                le prendra avec ce noyau.
                """
        case .session(let refusal):
            return SavedSession.explanation(refusal, name: name)
        case .couldNotStart(let reason, let kept):
            guard kept else { return "Démarrage impossible : \(reason)" }
            return """
                Démarrage impossible : \(reason)

                La session sauvée de \(name) est gardée telle quelle : rien \
                ne l'a remplacée. Pour repartir de zéro, touchez « Oublier », \
                puis rouvrez la machine.
                """
        }
    }
}
