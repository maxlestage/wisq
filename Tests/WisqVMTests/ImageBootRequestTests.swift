import XCTest
@testable import WisqVM

/// Démarrer l'image d'installation une fois : voir `ImageBootRequest`.
final class ImageBootRequestTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-demande-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// **Une fois, pas davantage** : le démarrage qui la prend la consomme,
    /// et le suivant revient au disque.
    func testARequestServesOneBootOnly() {
        XCTAssertFalse(ImageBootRequest.take(forKernel: "m1", in: folder))
        ImageBootRequest.request(forKernel: "m1", in: folder)
        XCTAssertTrue(ImageBootRequest.isRequested(forKernel: "m1", in: folder))
        XCTAssertTrue(ImageBootRequest.isRequested(forKernel: "m1", in: folder), "regarder ne consomme pas")
        XCTAssertTrue(ImageBootRequest.take(forKernel: "m1", in: folder))
        XCTAssertFalse(ImageBootRequest.take(forKernel: "m1", in: folder))
        XCTAssertFalse(ImageBootRequest.isRequested(forKernel: "m1", in: folder))
    }

    /// Chaque machine a la sienne ; et quand plus aucune n'en a, le fichier
    /// disparaît.
    func testRequestsBelongToTheirMachine() {
        ImageBootRequest.request(forKernel: "m1", in: folder)
        ImageBootRequest.request(forKernel: "m2", in: folder)
        XCTAssertTrue(ImageBootRequest.take(forKernel: "m2", in: folder))
        XCTAssertTrue(ImageBootRequest.isRequested(forKernel: "m1", in: folder))
        ImageBootRequest.forget(kernel: "m1", in: folder)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(ImageBootRequest.fileName).path))
    }

    /// Un fichier abîmé se lit comme aucune demande : la machine démarre son
    /// disque, ce qu'elle fait sans demande.
    func testAnUnreadableFileMeansNoRequest() throws {
        try Data("pas du json".utf8).write(to: folder.appendingPathComponent(ImageBootRequest.fileName))
        XCTAssertFalse(ImageBootRequest.take(forKernel: "m1", in: folder))
    }
}
