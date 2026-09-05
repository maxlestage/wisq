import XCTest

@testable import WisqVM

/// L'arbre construit, jugé contre celui qui fait démarrer un vrai noyau.
///
/// **Le blob de mini-rv32ima est le témoin.** Il n'est plus ce qu'on donne à
/// l'invité, mais c'est encore lui qui a la réponse : un noyau Linux démarre
/// dessus depuis des années, et le nôtre doit dire la même chose. Se comparer
/// à sa propre sortie ne prouverait rien.
///
/// **On compare ce que les deux disent, pas leurs octets.** L'ordre du bloc de
/// chaînes suffit à séparer deux arbres identiques pour tout noyau ; exiger
/// l'égalité binaire mesurerait l'ordre d'apparition des noms de propriétés,
/// c'est-à-dire rien.
final class DeviceTreeAgainstTheReferenceTests: XCTestCase {
    private func reference() throws -> DeviceTree {
        try DeviceTree.read(DefaultDTB.bytes)
    }

    private func built(ramSize: Int = 64 << 20) throws -> DeviceTree {
        try DeviceTree.read(RV32DeviceTree.tree(ramSize: ramSize).flatten())
    }

    /// **Le même arbre, nœud pour nœud et propriété pour propriété.**
    ///
    /// C'est le test qui autorise le remplacement. Une seule propriété
    /// oubliée, une seule valeur recopiée de travers, et il tombe.
    func testTheBuiltTreeSaysWhatTheReferenceSays() throws {
        XCTAssertEqual(try built().root, try reference().root)
    }

    /// Et il se relit lui-même : aplatir puis relire ne perd rien.
    ///
    /// Sans ça, le test ci-dessus pourrait passer sur un lecteur qui rate la
    /// même chose des deux côtés — deux silences ne font pas un accord.
    func testFlatteningAndReadingBackIsALosslessRoundTrip() throws {
        let tree = RV32DeviceTree.tree(ramSize: 64 << 20)
        XCTAssertEqual(try DeviceTree.read(tree.flatten()).root, tree.root)
    }

    /// L'en-tête que le noyau lit avant tout le reste.
    func testTheHeaderIsTheOneTheKernelExpects() throws {
        let blob = RV32DeviceTree.tree(ramSize: 64 << 20).flatten()
        func word(_ at: Int) -> UInt32 {
            UInt32(blob[at]) << 24 | UInt32(blob[at + 1]) << 16
                | UInt32(blob[at + 2]) << 8 | UInt32(blob[at + 3])
        }
        XCTAssertEqual(word(0), 0xD00D_FEED, "le nombre magique")
        XCTAssertEqual(Int(word(4)), blob.count, "la taille annoncée est la vraie")
        XCTAssertEqual(word(20), 17, "version 17")
        XCTAssertEqual(word(24), 16, "compatible depuis la 16")
        // Le bloc de structure est fait de mots : un décalage impair y ferait
        // lire des jetons à cheval, et le noyau abandonnerait sans un mot.
        XCTAssertEqual(word(8) % 4, 0, "le bloc de structure est aligné")
        XCTAssertEqual(Int(word(8) + word(36)), Int(word(12)),
                       "les chaînes commencent où la structure finit")
        // **Et la taille totale tombe sur huit.** Le chargeur pose l'arbre à
        // « fin de la RAM moins sa taille moins la réserve » : c'est donc
        // celle-ci qui décide de l'alignement de l'adresse, et l'analyseur du
        // noyau exige huit. Un arbre de 1507 octets a déjà donné un démarrage
        // parfaitement silencieux — pas de bannière, pas de panique, rien.
        XCTAssertEqual(blob.count % 8, 0, "la taille totale doit tomber sur huit")
    }

    /// Et la règle vaut à toutes les tailles, pas seulement à celle qui
    /// arrange : un remplissage juste par hasard n'est pas un remplissage.
    func testTheTotalSizeLandsOnEightWhateverTheTreeSays() {
        for line in ["", "a", "ab", "abc", "abcd", "abcde", "abcdef", "abcdefg"] {
            let blob = RV32DeviceTree.tree(ramSize: 64 << 20, commandLine: line).flatten()
            XCTAssertEqual(blob.count % 8, 0, "ligne de \(line.count) caractères")
        }
    }

    /// **La taille de la mémoire suit la machine**, et garde le même écart en
    /// haut que la disposition de référence.
    ///
    /// C'était une écriture à l'octet 316 ; c'est maintenant une propriété. Le
    /// test compte en cellules parce que c'est ce que le noyau lit : deux pour
    /// la base, deux pour la taille.
    func testTheMemoryNodeStatesThisMachinesSize() throws {
        for size in [64 << 20, 256 << 20, 1024 << 20] {
            let memory = try XCTUnwrap(built(ramSize: size).root.child("memory@80000000"))
            XCTAssertEqual(
                memory.property("reg"),
                .cells([0, 0x8000_0000, 0, UInt32(size - RV32DeviceTree.memoryTopReserve)]),
                "\(size >> 20) Mo")
        }
    }

    /// **La ligne de commande n'a plus de plafond.**
    ///
    /// Le blob en offrait cinquante-quatre caractères — la place qu'il se
    /// trouvait avoir entre deux propriétés — et `load` refusait au-delà. Une
    /// propriété n'a pas de place à trouver : l'arbre grandit.
    func testTheCommandLineIsAPropertyAndNoLongerCapped() throws {
        let long = String(repeating: "console=ttyS0 ", count: 40)
        let tree = try DeviceTree.read(
            RV32DeviceTree.tree(ramSize: 64 << 20, commandLine: long).flatten())
        XCTAssertEqual(tree.root.child("chosen")?.property("bootargs"), .string(long))
        XCTAssertGreaterThan(long.count, 54, "plus long que ce que le blob permettait")
    }

    /// Le contrôleur d'interruptions du hart porte le phandle que les
    /// périphériques désigneront — faute de PLIC, c'est lui la destination.
    func testTheHartInterruptControllerCarriesThePhandleDevicesWillPointAt() throws {
        let controller = try XCTUnwrap(
            built().root.child("cpus")?.child("cpu@0")?.child("interrupt-controller"))
        XCTAssertEqual(controller.property("phandle"),
                       .cells([RV32DeviceTree.hartInterruptController]))
        XCTAssertEqual(controller.property("interrupt-controller"), .empty,
                       "présente et vide : c'est sa présence qui compte")
        // Et le CLINT le désigne déjà par ce numéro-là, ce qui est la preuve
        // que le chemin existe avant qu'on s'en serve.
        XCTAssertEqual(
            try built().root.child("soc")?.child("clint@11000000")?
                .property("interrupts-extended"),
            .cells([RV32DeviceTree.hartInterruptController, 3,
                    RV32DeviceTree.hartInterruptController, 7]))
    }

    /// Un blob qui n'en est pas un est refusé, nommément, plutôt que lu de
    /// travers.
    func testSomethingThatIsNotATreeIsRefused() {
        XCTAssertThrowsError(try DeviceTree.read([0, 1, 2, 3])) {
            XCTAssertEqual($0 as? DeviceTree.ReadError, .notATree)
        }
        var truncated = RV32DeviceTree.tree(ramSize: 64 << 20).flatten()
        truncated.removeLast(200)
        XCTAssertThrowsError(try DeviceTree.read(truncated))
    }
}
