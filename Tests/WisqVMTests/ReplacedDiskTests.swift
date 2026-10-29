import XCTest
@testable import WisqVM

/// **Un disque remplacé sous le même nom n'est plus le même disque.**
///
/// Réimporter `rootfs.img`, retélécharger `debian-13-nocloud-amd64.qcow2` —
/// Debian publie sans version — ne remplaçait que le fichier. La couche
/// d'écriture du fichier, celles des machines installées dessus et les
/// sessions qui le croyaient là restaient : posée sur une autre base, une
/// couche en fait un mélange des deux disques, et une session reprend avec
/// le cache de pages de l'ancien. Supprimer le fichier, de son côté, laissait
/// les couches des machines installées.
final class ReplacedDiskTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-disque-remplace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func overlay(_ name: String) throws {
        let writes = try LocalDisk.writesURL(for: name, in: folder)
        try Data([1]).write(to: writes)
        try Data([2]).write(to: URL(fileURLWithPath: writes.path + ".map"))
    }

    private func hasOverlay(_ name: String) -> Bool {
        guard let writes = try? LocalDisk.writesURL(for: name, in: folder) else { return false }
        return FileManager.default.fileExists(atPath: writes.path)
            || FileManager.default.fileExists(atPath: writes.path + ".map")
    }

    private func session(_ name: String) throws {
        let file = "machine-\(SuspendedMachine.safeName(name))-abc123.wisqvm"
        try Data([3]).write(to: folder.appendingPathComponent(file))
    }

    private func hasSession(_ name: String) -> Bool {
        !SuspendedMachine.savedMachineFiles(named: name, in: folder).isEmpty
    }

    /// Ce qui a été écrit **sur ce disque** part — par le fichier démarré tel
    /// quel, par deux machines installées, par un noyau qui l'avait pour
    /// disque — avec les sessions de chacun. Le reste ne bouge pas : un autre
    /// disque, la couche d'une machine sur un autre disque, un disque dont le
    /// nom finit pareil, et les réglages.
    func testEverythingWrittenOnTheDiskGoesAndNothingElse() throws {
        let disk = "debian.qcow2"
        let first = "installee-0123456789ab", second = "installee-ba9876543210"
        try overlay(disk)
        try overlay("\(first)~\(disk)")
        try overlay("\(second)~\(disk)")
        try overlay("\(first)~autre.img")
        try overlay("autre.img")
        try overlay("\(second)~a~\(disk)")
        LocalDisk.attach(disk, forKernel: "bzImage", in: folder)
        LocalDisk.attach("autre.img", forKernel: "vmlinuz", in: folder)
        for name in [disk, first, second, "bzImage", "vmlinuz", "autre.img"] { try session(name) }

        let cleared = LocalDisk.discardEverythingWritten(onDisk: disk, in: folder)

        XCTAssertEqual(cleared, [disk, first, second, "bzImage"])
        for gone in [disk, "\(first)~\(disk)", "\(second)~\(disk)"] {
            XCTAssertFalse(hasOverlay(gone), gone)
        }
        for kept in ["\(first)~autre.img", "autre.img", "\(second)~a~\(disk)"] {
            XCTAssertTrue(hasOverlay(kept), kept)
        }
        for gone in [disk, first, second, "bzImage"] { XCTAssertFalse(hasSession(gone), gone) }
        for kept in ["vmlinuz", "autre.img"] { XCTAssertTrue(hasSession(kept), kept) }
        XCTAssertEqual(LocalDisk.recordedName(forKernel: "bzImage", in: folder), disk,
                       "le choix du disque vaut pour le nouveau fichier")
    }

    /// Un disque sur lequel rien n'a été écrit : rien ne casse, et seule sa
    /// propre clé est rendue.
    func testADiskNobodyWroteOnIsANoOp() {
        XCTAssertEqual(LocalDisk.discardEverythingWritten(onDisk: "neuf.img", in: folder), ["neuf.img"])
    }
}
