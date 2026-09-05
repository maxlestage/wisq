#if os(iOS)
import XCTest

@testable import WisqUI
@testable import WisqVM

/// Le disque vu depuis la bibliothèque de l'application.
///
/// **Ce que la tranche précédente laissait dehors.** `X86Machine` savait
/// prendre un disque depuis le lot 7 ; rien dans l'application ne l'appelait,
/// et l'import refusait net le seul genre de fichier qu'on aurait pu lui
/// donner : une image ext4 ne démarre pas et n'est pas un initramfs, donc les
/// deux gardes la rejetaient ensemble.
final class DiskLibraryTests: XCTestCase {
    private var source: URL!

    override func setUpWithError() throws {
        source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: source)
        for file in KernelLibrary.list() where file.lastPathComponent.hasPrefix("essai-") {
            KernelLibrary.delete(file)
        }
    }

    /// Une image ext4, écrite avec la marque de son superbloc à sa place.
    private func ext4(_ name: String) throws -> URL {
        var image = [UInt8](repeating: 0, count: 0x1000)
        image[0x438] = 0x53
        image[0x439] = 0xEF
        let url = source.appendingPathComponent(name)
        try Data(image).write(to: url)
        return url
    }

    /// **L'import garde une image de disque.** C'est la correction elle-même :
    /// avant, elle repartait avec « wisq ne démarre pas une image de disque ».
    func testImportKeepsAFilesystemImage() throws {
        let kept = try KernelLibrary.importKernel(from: try ext4("essai-racine.img"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertEqual(
            KernelImageKind.identify(fileAt: kept), .filesystemImage("ext2/3/4"),
            "le fichier copié est bien celui qu'on a reconnu")
    }

    /// **Et il n'est plus refusé pour sa taille.** Le disque est lu sur
    /// place ; une image plus grosse que toute la mémoire du téléphone entre
    /// dans la bibliothèque comme les autres. Creusée après coup : les octets
    /// reconnaissables sont au début, la taille est réelle, et aucun
    /// gigaoctet n'est écrit.
    func testAHugeDiskImageIsKeptSinceNothingCopiesItIntoMemory() throws {
        let url = source.appendingPathComponent("essai-gros.img")
        var image = [UInt8](repeating: 0, count: 0x1000)
        image[0x438] = 0x53
        image[0x439] = 0xEF
        try Data(image).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(KernelMemory.ceiling) + 1)
        try handle.close()

        let kept = try KernelLibrary.importKernel(from: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertEqual(KernelImageKind.identify(fileAt: kept), .filesystemImage("ext2/3/4"))
    }

    // **Et le plancher n'est pas atteignable par ici**, ce qui vaut d'être
    // écrit plutôt que testé de travers. Un fichier de moins d'un secteur ne
    // peut pas porter la marque d'un système de fichiers — elle vit à l'octet
    // 1080 — donc il n'est jamais reconnu comme un disque, et c'est le chemin
    // des fichiers inconnus qui le prend. Le refus du secteur unique est tenu
    // là où il vit, dans `LocalDiskTests`, avec son nombre.

    /// **Supprimer un noyau oublie le disque qu'on lui avait donné**, et
    /// supprimer un disque l'oublie chez les noyaux qui l'avaient.
    ///
    /// Sans le second, une image supprimée laisserait des noyaux réglés sur un
    /// fichier absent : ils démarreraient sans disque, et rien à l'écran ne
    /// dirait pourquoi.
    func testDeletingForgetsTheDiskFromBothSides() throws {
        let kernel = try KernelLibrary.importKernel(from: try ext4("essai-noyau"))
        let disk = try KernelLibrary.importKernel(from: try ext4("essai-disque.img"))
        LocalDisk.attach(disk.lastPathComponent, forKernel: kernel.lastPathComponent)
        XCTAssertEqual(
            LocalDisk.recordedName(forKernel: kernel.lastPathComponent),
            disk.lastPathComponent)

        KernelLibrary.delete(disk)
        XCTAssertNil(
            LocalDisk.recordedName(forKernel: kernel.lastPathComponent),
            "le disque a disparu : son nom n'a plus à traîner sous le noyau")

        LocalDisk.attach("revenu.img", forKernel: kernel.lastPathComponent)
        KernelLibrary.delete(kernel)
        XCTAssertNil(LocalDisk.recordedName(forKernel: kernel.lastPathComponent))
    }
}
#endif
