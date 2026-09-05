import Foundation

@testable import WisqVM
@testable import WisqVMRust

/// Charger le cœur Rust **sur la carte que l'application lui donne**.
///
/// Les tests différentiels comparent deux interprètes ; ils ne valent que si
/// les deux tournent sur la même carte. Ça n'était pas garanti par grand-chose
/// avant : chaque cœur bâtissait son arbre de périphériques depuis sa propre
/// copie du blob de référence, et il aurait suffi qu'une des deux copies bouge
/// pour que la comparaison mesure deux machines au lieu de deux processeurs.
///
/// Depuis, `RV32DeviceTree` est le seul producteur et `RustLinuxMachine`
/// n'accepte plus que des octets. Ce raccourci-ci fait exactement ce que
/// `WisqUI` fait en vrai, et c'est pour ça qu'il est écrit une seule fois.
extension RustLinuxMachine {
    func loadOnTheSameBoard(kernelImage: Data, commandLine: String? = nil) throws {
        try load(kernelImage: kernelImage,
                 deviceTree: RV32DeviceTree.tree(
                    ramSize: Int(ramSize), commandLine: commandLine).flatten())
    }
}
