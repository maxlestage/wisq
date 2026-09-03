import XCTest

@testable import WisqUI
@testable import WisqVM

/// Le refus vu par la personne qui a essayé, et l'endroit où il tombe.
///
/// Maxime a voulu démarrer Omarchy — une distribution complète — sur son
/// iPhone, dans la machine locale. L'application a disparu sans un mot. La
/// cause n'était pas le refus : `LinuxMachine.load` refuse depuis toujours une
/// image trop grande. C'était l'**ordre** : le fichier entier était lu en
/// mémoire par `Data(contentsOf:)` avant que la garde ne soit atteinte, et sur
/// une image de deux gigaoctets le système tue l'application bien avant.
final class OversizedKernelRefusalTests: XCTestCase {
    /// L'import refuse avant de copier. Le fichier n'a pas à voyager dans le
    /// stockage de l'application pour être jugé sur sa taille.
    func testImportRefusesAnOversizedFileWithoutCopyingIt() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-kernel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Un fichier creux : la taille annoncée est réelle, les octets ne sont
        // jamais écrits — c'est ce qui permet de tester un refus de taille sans
        // fabriquer deux gigaoctets.
        let source = directory.appendingPathComponent("omarchy.iso")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(LocalMachineMemory.maximumKernelImageBytes) + 1)
        try handle.close()

        XCTAssertThrowsError(try KernelLibrary.importKernel(from: source)) { error in
            guard case KernelImportError.tooLarge(let explanation) = error else {
                return XCTFail("refus attendu sur la taille, obtenu : \(error)")
            }
            XCTAssertTrue(explanation.contains("omarchy.iso"))
        }
        // Et rien n'a été copié dans la bibliothèque.
        XCTAssertFalse(
            KernelLibrary.list().contains { $0.lastPathComponent == "omarchy.iso" },
            "un fichier refusé ne doit pas rester dans le stockage de l'application")
    }
}
