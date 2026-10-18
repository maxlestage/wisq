import XCTest
@testable import WisqVM
import WisqVMTestKit

/// Le mot de passe de `root` d'une image de cloud : gardé en empreinte, sous
/// la clé de la machine, et jamais en clair.
final class RootPasswordTests: XCTestCase {
    private var folder = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-root-\(getpid())-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var file: URL { folder.appendingPathComponent(RootPassword.fileName) }

    /// **Ce qui est écrit est l'empreinte**, sur un sel tiré pour elle, et
    /// elle vérifie le mot de passe donné. Le texte du mot de passe n'est nulle
    /// part dans le fichier.
    func testOnlyTheHashIsKept() throws {
        let sample = UUID().uuidString
        XCTAssertNil(RootPassword.hash(forKernel: "debian.qcow2", in: folder))
        XCTAssertTrue(RootPassword.set(sample, forKernel: "debian.qcow2", in: folder))
        let hash = try XCTUnwrap(RootPassword.hash(forKernel: "debian.qcow2", in: folder))
        let parts = hash.split(separator: "$")
        XCTAssertEqual(parts.first, "6")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(SHA512Crypt.hash(sample, salt: String(parts[1])), hash)
        let written = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(written.contains(sample), "jamais en clair")
        XCTAssertNil(RootPassword.hash(forKernel: "autre.qcow2", in: folder))

        // Un second mot de passe remplace le premier, sur un sel neuf.
        XCTAssertTrue(RootPassword.set(sample, forKernel: "debian.qcow2", in: folder))
        XCTAssertNotEqual(RootPassword.hash(forKernel: "debian.qcow2", in: folder), hash)
    }

    /// Un mot de passe que `login` ne peut pas recevoir n'écrit rien.
    func testAnUnusablePasswordWritesNothing() {
        for bad in ["", "a\tb", "\n"] {
            XCTAssertFalse(RootPassword.set(bad, forKernel: "debian.qcow2", in: folder))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// Oublier retire l'entrée, et le fichier avec la dernière.
    func testForgettingRemovesTheEntryAndTheLastOneTheFile() {
        RootPassword.set(UUID().uuidString, forKernel: "a", in: folder)
        RootPassword.set(UUID().uuidString, forKernel: "b", in: folder)
        RootPassword.forget(kernel: "a", in: folder)
        XCTAssertNil(RootPassword.hash(forKernel: "a", in: folder))
        XCTAssertNotNil(RootPassword.hash(forKernel: "b", in: folder))
        RootPassword.forget(kernel: "b", in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// **Ce qui passerait mal sur la ligne de commande se lit comme absent** :
    /// un fichier abîmé, ou une entrée qui n'est pas une empreinte `$6$` —
    /// une espace la couperait en deux options du noyau.
    func testWhatCannotGoOnTheCommandLineReadsAsAbsent() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"a":"$6$sel$deux mots","b":"$1$md5$abc","c":"$6$"}"#.utf8).write(to: file)
        for key in ["a", "b", "c"] { XCTAssertNil(RootPassword.hash(forKernel: key, in: folder), key) }
        try Data("pas du json".utf8).write(to: file)
        XCTAssertNil(RootPassword.hash(forKernel: "a", in: folder))
        XCTAssertTrue(RootPassword.isHash("$6$rounds=10000$sel$abc./XYZ"))
    }

    /// **L'empreinte gardée va jusqu'à la ligne de commande**, telle quelle.
    func testTheKeptHashIsWhatTheCommandLineCarries() throws {
        RootPassword.set(UUID().uuidString, forKernel: "debian.qcow2", in: folder)
        let hash = try XCTUnwrap(RootPassword.hash(forKernel: "debian.qcow2", in: folder))
        XCTAssertTrue(CloudBoot.commandLine(["root=/dev/vda1"], rootHash: hash)
            .hasSuffix("passwd.hashed-password.root:" + hash))
    }
}

/// Quand demander le mot de passe : une image de cloud, une seule fois.
final class RootPasswordQuestionTests: XCTestCase {
    private var made: [URL] = []

    override func tearDown() {
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
    }

    private func temporary(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-question-\(getpid())-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        made.append(url)
        return url
    }

    private func cloudImage(type: UInt8 = 0x83) throws -> URL {
        // Une table seule suffit à la question : aucun système de fichiers
        // n'est lu.
        try temporary(CloudDisk.raw(around: [UInt8](repeating: 0, count: 4096), type: type))
    }

    /// Une image de cloud jamais démarrée demande ; une réponse, mot de passe
    /// ou « sans », fait taire la question. Un noyau ou une table sans
    /// partition Linux ne demande jamais.
    func testOnlyACloudImageAsksAndOnlyOnce() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-question-dossier-\(getpid())-\(UUID().uuidString)")
        made.append(folder)
        let image = try cloudImage()
        XCTAssertTrue(RootPassword.shouldAsk(fileAt: image, forKernel: "a", in: folder))
        RootPassword.decline(forKernel: "a", in: folder)
        XCTAssertFalse(RootPassword.shouldAsk(fileAt: image, forKernel: "a", in: folder))
        XCTAssertNil(RootPassword.hash(forKernel: "a", in: folder), "« sans » n'est pas une empreinte")
        RootPassword.set(UUID().uuidString, forKernel: "b", in: folder)
        XCTAssertFalse(RootPassword.shouldAsk(fileAt: image, forKernel: "b", in: folder))

        var kernel = [UInt8](repeating: 0, count: 4096)
        kernel.replaceSubrange(0x202..<0x206, with: Array("HdrS".utf8))
        XCTAssertFalse(RootPassword.shouldAsk(fileAt: try temporary(kernel), forKernel: "c", in: folder))
        XCTAssertFalse(RootPassword.shouldAsk(fileAt: try cloudImage(type: 0x07), forKernel: "c", in: folder))
    }
}
