#if os(iOS)
import XCTest

@testable import WisqUI
@testable import WisqVM

/// **Supprimer une image d'installation emporte ce qu'elle avait déballé.**
///
/// Une ISO ne démarre pas telle quelle : `IsoBoot` en sort un noyau et un
/// initramfs dans un dossier à part, et c'est de là que la machine part. Ce
/// dossier n'est sous aucune entrée de la bibliothèque — il est partagé, et
/// rien dedans ne dit de quelle image il vient — donc rien ne l'effaçait.
/// Supprimer l'image laissait derrière elle des dizaines de mébioctets que le
/// relevé ne montrait pas et qu'aucun geste ne pouvait reprendre.
///
/// Jugé ici plutôt qu'en Linux parce que `KernelLibrary` est derrière
/// `#if os(iOS)` : seul ce lot-ci l'exécute. Ce qu'il fait au dossier, lui,
/// est tenu par `LocalStorageTests` et `IsoBootTests`, que la CI Linux passe
/// à chaque commit.
final class IsoDeletionTests: XCTestCase {
    private var source: URL!

    override func setUpWithError() throws {
        source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: source)
        for file in KernelLibrary.list() where file.lastPathComponent.hasPrefix("essai-") {
            KernelLibrary.delete(file)
        }
        LocalStorage.discardUnpackedIso(LocalStorage.unpackedIsoFolder(in: nil))
    }

    /// Une ISO reconnaissable : le descripteur de volume vit au secteur 16, et
    /// son identifiant est « CD001 ».
    private func iso(_ name: String) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: 0x8800)
        bytes.replaceSubrange(0x8001...0x8005, with: Array("CD001".utf8))
        let url = source.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// Ce que `IsoBoot` aurait laissé, sans avoir à graver une image : deux
    /// fichiers de tailles connues, à l'endroit qu'il emploie.
    @discardableResult
    private func leaveAnUnpacking(bytes: Int) throws -> URL {
        let folder = try XCTUnwrap(LocalStorage.unpackedIsoFolder(in: nil))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x7F, count: bytes)
            .write(to: folder.appendingPathComponent("vmlinuz"))
        return folder
    }

    /// **La correction elle-même.** L'image part, son déballage aussi.
    func testDeletingAnImageAlsoDiscardsWhatItUnpacked() throws {
        let image = try KernelLibrary.importKernel(from: try iso("essai-installation.iso"))
        if case .discImage = KernelImageKind.identify(fileAt: image) {} else {
            XCTFail("le fichier importé doit être reconnu comme une image, sinon ce test ne mesure rien")
            return
        }
        let folder = try leaveAnUnpacking(bytes: 5000)
        XCTAssertEqual(KernelLibrary.storageReport().unpackedIsoBytes, 5000)

        KernelLibrary.delete(image)

        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.path),
            "le noyau et l'initramfs sortis de l'image partent avec elle")
        XCTAssertEqual(KernelLibrary.storageReport().unpackedIsoBytes, 0)
    }

    /// **Et supprimer autre chose n'y touche pas.** Jeter le déballage à
    /// chaque suppression ne coûterait rien — le démarrage suivant le refait —
    /// mais ce serait dire quelque chose de faux sur ce qui vient de partir,
    /// et une garde qui ne peut pas se tromper ne garde rien.
    func testDeletingAnOrdinaryKernelLeavesTheUnpackingAlone() throws {
        let plain = source.appendingPathComponent("essai-noyau")
        try Data(repeating: 0x42, count: 4096).write(to: plain)
        let kernel = try KernelLibrary.importKernel(from: plain)
        let folder = try leaveAnUnpacking(bytes: 5000)

        KernelLibrary.delete(kernel)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.path),
            "ce noyau-ci n'a rien déballé, donc il n'a rien à emporter")
        XCTAssertEqual(KernelLibrary.storageReport().unpackedIsoBytes, 5000)
    }

    /// Le relevé de l'application regarde bien le dossier où l'on déballe, et
    /// pas un autre : sans cela les deux tests ci-dessus passeraient sur un
    /// chiffre qui vaut zéro pour une raison qui n'a rien à voir.
    func testTheAppReportLooksAtTheFolderTheUnpackingUses() throws {
        let folder = try leaveAnUnpacking(bytes: 1234)
        XCTAssertEqual(KernelLibrary.storageReport().unpackedIsoBytes, 1234)
        XCTAssertEqual(folder.lastPathComponent, "iso")
    }
}
#endif
