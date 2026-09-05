import Foundation

/// Ce qu'un fichier de la bibliothèque **est**, dit en trois mots et une
/// icône.
///
/// **Pourquoi ce type existe.** La bibliothèque a longtemps contenu une seule
/// sorte de fichier, et la liste les dessinait tous avec la même icône de
/// terminal. Elle en contient trois depuis que la machine PC existe — un
/// noyau, son initramfs, et maintenant son disque — et rien à l'écran ne les
/// distinguait : trois lignes identiques, dont une seule démarre. Quelqu'un
/// qui touche la mauvaise reçoit un refus parfaitement juste à un endroit où
/// la question n'aurait pas dû se poser.
///
/// **La vue ne décide rien**, ici comme pour la mémoire : le mot, l'icône et
/// « est-ce que ça démarre » viennent de ce fichier-ci, qui se construit sur
/// Linux et se tient donc par des tests.
public enum LibraryEntry {
    /// À quoi ce fichier sert dans cette bibliothèque.
    public enum Role: Equatable, Sendable {
        /// Un noyau que wisq sait démarrer, avec le nom de son architecture.
        case kernel(String)
        /// Un fichier qui peut être l'initramfs d'un noyau, avec le nom de son
        /// enveloppe.
        case bootMedia(String)
        /// Une image de disque, avec le nom de son format.
        case disk(String)
        /// Quelque chose que wisq reconnaît et ne peut pas employer ici — un
        /// noyau pour une autre architecture, un exécutable. Nommé quand même.
        case foreign(String)
        /// Rien de reconnu. **Ce n'est pas un refus** : `unknown` est une
        /// permission partout ailleurs dans ce module, et cette ligne reste
        /// donc offerte au démarrage comme au disque.
        case unrecognised
    }

    /// Le rôle de ce fichier, d'après ses premiers octets.
    public static func role(of url: URL) -> Role {
        role(of: KernelImageKind.identify(fileAt: url))
    }

    /// La même décision, sur une identification déjà faite — ce que les tests
    /// atteignent, et ce qui évite de relire le fichier deux fois.
    public static func role(of kind: KernelImageKind) -> Role {
        switch kind {
        case .linuxKernel(let image) where image.architecture.core != nil:
            return .kernel(image.architecture.name)
        case .linuxKernel(let image):
            return .foreign("noyau pour \(image.architecture.name)")
        case .executable(let architecture):
            return .foreign("exécutable \(architecture.name)")
        // **Une enveloppe compressée est appelée initramfs, pas « noyau
        // compressé ».** Les deux sont indiscernables — `BootMedia` explique
        // pourquoi, et ce n'est pas une paresse mais un fait sur les octets —
        // alors on nomme celui des deux qui a un emploi ici : un noyau
        // compressé ne démarre pas, un initramfs sert à chaque démarrage de
        // PC.
        case .compressedKernel(let format):
            return .bootMedia(format)
        case .filesystemImage(let format), .discImage(let format):
            return .disk(format)
        case .unknown:
            return .unrecognised
        }
    }

    /// Ce que la ligne dit sous le nom du fichier.
    public static func word(_ role: Role) -> String {
        switch role {
        case .kernel(let architecture): return "noyau \(architecture)"
        case .bootMedia(let format): return "initramfs (\(format))"
        case .disk(let format): return "disque (\(format))"
        case .foreign(let what): return what
        case .unrecognised: return "type inconnu"
        }
    }

    /// L'icône de la ligne.
    ///
    /// Des symboles du système, nommés ici plutôt que dans la vue pour que le
    /// choix soit au même endroit que le mot : les deux disent la même chose,
    /// et les séparer serait la façon dont ils finissent par se contredire.
    public static func symbol(_ role: Role) -> String {
        switch role {
        case .kernel: return "terminal"
        case .bootMedia: return "shippingbox"
        case .disk: return "externaldrive"
        case .foreign: return "xmark.octagon"
        case .unrecognised: return "questionmark.circle"
        }
    }
}
