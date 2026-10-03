import Foundation
import CWisqVM

/// **Ce qu'un noyau ELF64 dit de lui-même, lu par le cœur Rust.**
///
/// Sans ça l'application ne peut pas démarrer un vrai noyau : elle n'a aucun
/// moyen d'apprendre où poser l'image ni par où l'exécution commence, et les
/// deux — l'`entry` que `LocalDesktop` prend et les adresses auxquelles elle
/// pose — viennent d'ici. `kernel_image::loads` lit des ELF depuis #304 et le
/// montage de mesure s'en sert ; le bureau ne pouvait pas, parce que rien ne
/// l'exposait au-delà de la frontière C.
///
/// **Le lecteur n'est pas réécrit de ce côté-ci**, et c'est délibéré : il y en
/// aurait alors deux, et celui qui mentirait serait celui que personne ne lit.
/// `Sources/WisqVM/KernelImageKind.swift` *reconnaît* un ELF — son magique, sa
/// classe, sa machine — mais ne lit pas ses segments, et n'a pas à le faire.
public enum RustKernelImage {
    /// **Un segment `PT_LOAD` : où il vit, et ce qu'il porte.**
    ///
    /// **Les deux tailles ne sont pas la même chose**, et les confondre coûte
    /// cher. `fileSize` est ce que le fichier porte ; `memorySize` est ce que
    /// le segment occupe une fois chargé. L'écart est le BSS — des zéros que le
    /// noyau attend et qu'aucun octet du fichier ne décrit. Le vmlinux
    /// d'Alpine en traîne cinq mébioctets.
    ///
    /// **Et les deux adresses non plus.** `physicalAddress` est celle à
    /// laquelle un chargeur pose le segment ; `virtualAddress` est celle à
    /// laquelle il a été lié. Pour le texte d'un noyau x86-64 les deux
    /// diffèrent de `__START_KERNEL_map`, et le code de démarrage passe de
    /// l'une à l'autre en cours de route. Poser à la seconde ne produirait pas
    /// « un peu faux » : rien ne démarrerait.
    public struct Load: Equatable, Sendable {
        public let offset: UInt64
        public let virtualAddress: UInt64
        public let physicalAddress: UInt64
        public let fileSize: UInt64
        public let memorySize: UInt64
    }

    /// Le point d'entrée et tous les segments, ensemble — parce qu'aucun des
    /// deux ne sert seul.
    public struct Loadable: Equatable, Sendable {
        public let entry: UInt64
        public let segments: [Load]
    }

    /// **Lit l'ELF, ou rend `nil` s'il n'en est pas un.**
    ///
    /// Deux appels, et c'est le contrat de l'ABI : le premier, avec une
    /// capacité nulle, apprend le compte sans rien écrire ; le second alloue
    /// juste ce qu'il faut. Le premier n'est pas perdu — il pose déjà l'entrée
    /// et le compte.
    ///
    /// **Un compte de zéro n'est pas un noyau.** Un ELF sans segment
    /// chargeable se lirait sans erreur et ne porterait rien à poser ; le
    /// rendre comme un succès ferait démarrer une machine sur de la mémoire
    /// vide, et le symptôme serait un arrêt loin de sa cause.
    public static func loads(_ image: Data) -> Loadable? {
        image.withUnsafeBytes { raw -> Loadable? in
            guard let base = raw.baseAddress else { return nil }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var entry: UInt64 = 0
            var count = 0
            let asked = wisq_kernel_loads(bytes, raw.count, &entry, nil, 0, &count)
            // `2` est la réponse attendue d'une capacité nulle : lu, mais rien
            // écrit. `0` voudrait dire qu'il n'y a aucun segment, et `1` que ce
            // n'est pas un ELF.
            guard asked == 2, count > 0 else { return nil }
            var segments = [wisq_kernel_load](
                repeating: wisq_kernel_load(
                    offset: 0, virtual_address: 0, physical_address: 0,
                    file_size: 0, memory_size: 0
                ),
                count: count
            )
            let read = segments.withUnsafeMutableBufferPointer { buffer -> Int32 in
                wisq_kernel_loads(bytes, raw.count, &entry, buffer.baseAddress, count, &count)
            }
            guard read == 0 else { return nil }
            return Loadable(
                entry: entry,
                segments: segments.prefix(count).map {
                    Load(
                        offset: $0.offset,
                        virtualAddress: $0.virtual_address,
                        physicalAddress: $0.physical_address,
                        fileSize: $0.file_size,
                        memorySize: $0.memory_size
                    )
                }
            )
        }
    }
}
