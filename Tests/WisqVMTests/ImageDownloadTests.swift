import XCTest
@testable import WisqVM

/// Télécharger une image : la somme, l'index d'Alpine, la reprise, et la
/// règle qu'un fichier n'entre que vérifié.
final class ImageDownloadTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-telechargement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - SHA-256

    /// Les vecteurs de FIPS 180-4 et du NIST : vide, « abc », le message de
    /// 448 bits qui force un bloc de bourrage entier, et un million de « a ».
    func testSHA256MatchesTheStandardVectors() {
        XCTAssertEqual(SHA256.hex([UInt8]()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Array("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256.hex([UInt8](repeating: 0x61, count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    /// Par morceaux de toutes les tailles, à cheval sur les blocs de 64
    /// octets : la même somme qu'en une fois. C'est ainsi qu'un fichier est
    /// haché, par mégaoctets.
    func testSHA256ByPiecesIsTheSameAsAtOnce() {
        let bytes = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 7) }
        let whole = SHA256.hex(bytes)
        for piece in [1, 3, 55, 56, 63, 64, 65, 127, 1000] {
            var hash = SHA256()
            var start = 0
            while start < bytes.count {
                hash.update(bytes[start..<min(start + piece, bytes.count)])
                start += piece
            }
            XCTAssertEqual(SHA256.hexString(hash.finalize()), whole, "morceaux de \(piece)")
        }
        let url = folder.appendingPathComponent("f")
        XCTAssertNoThrow(try Data(bytes).write(to: url))
        XCTAssertEqual(try SHA256.hex(ofFileAt: url), whole)
    }

    // MARK: - L'index d'Alpine

    /// L'index tel que le miroir d'Alpine le servait le 18 octobre 2026 — à
    /// une ligne d'espaces près, vidée pour la garde de mise en forme : les
    /// descriptions sur plusieurs lignes ne cassent rien, et les saveurs qui
    /// démarrent ici sortent dans l'ordre voulu.
    static let index = """
        ---
        -
          title: "Mini root filesystem"
          desc: |
            Minimal root filesystem.
            For use in containers
            and minimal chroots.
          branch: v3.24
          arch: x86_64
          version: 3.24.2
          flavor: alpine-minirootfs
          file: alpine-minirootfs-3.24.2-x86_64.tar.gz
          iso: alpine-minirootfs-3.24.2-x86_64.tar.gz
          date: 2026-09-17
          time: 17:32:03
          size: 3701382
          sha256: c5ca053cfe1d85c5b96dff8b9bc57045f7f184a30ffb6b65776409ca90388677
          sha512: bb1cbdc0395826774d8843736624c8ddc225a76de7d70e04444f5390c54986e14b2fa3ad0ca367dfa36dddfc8ebe1d2b4cbcf5cc9993e85badaf96104518f1fc
        -
          title: "Netboot"
          desc: |
            Kernel, initramfs and modloop for
            netboot.

          branch: v3.24
          arch: x86_64
          version: 3.24.2
          flavor: alpine-netboot
          file: alpine-netboot-3.24.2-x86_64.tar.gz
          iso: alpine-netboot-3.24.2-x86_64.tar.gz
          date: 2026-09-17
          time: 17:33:57
          size: 392497909
          sha256: bbdd643360fac384a7933d8bebc7132eb720002e58d1321edcde4a5a3c3b83c6
          sha512: 4fd25160e376b4350222005899bcf18b1a1bdedf1f7fa4703b5df335ae5ef11244ef5bf5fbce3ec8ca9f5ab5fd3b702bd41b3534c7e7b376a309e9b567676493
        -
          title: "Standard"
          desc: |
            Alpine as it was intended.
            Just enough to get you started.
            Network connection is required.
          branch: v3.24
          arch: x86_64
          version: 3.24.2
          flavor: alpine-standard
          file: alpine-standard-3.24.2-x86_64.iso
          iso: alpine-standard-3.24.2-x86_64.iso
          date: 2026-09-17
          time: 17:35:44
          size: 370147328
          sha256: 20c026e3a788bfb75fc8b50a54bcc12aee85e3c75909740bba6a6f4563d63296
          sha512: 013ab9e0780d2fb73975d6dae0cf6ddcbe7eb1531e535c1c6c78bb2cadefd2d8a8aca3fffe2aae5853f6d0ea5f23de2dadbc18559724317a1d6a74be8d452354
        -
          title: "Extended"
          desc: |
            Most common used packages included.
            Suitable for routers and servers.
            Runs from RAM.
            Includes AMD and Intel microcode updates.
          branch: v3.24
          arch: x86_64
          version: 3.24.2
          flavor: alpine-extended
          file: alpine-extended-3.24.2-x86_64.iso
          iso: alpine-extended-3.24.2-x86_64.iso
          date: 2026-09-17
          time: 17:37:56
          size: 1456766976
          sha256: a22115a46a1bcd876234a6cd43797fe19f4acfc4512fb41ea64e16cc2ffb4d90
          sha512: dd44546b7797f68ffb940ea44352568cc9a1c419074b5eda661b8d12af81b7056665b9855e6ac2ebe8c2914a1b549b16f3d666be43799d86bee9183cd9b1ffca
        -
          title: "Virtual"
          desc: |
            Similar to standard.
            Slimmed down kernel.
            Optimized for virtual systems.
          branch: v3.24
          arch: x86_64
          version: 3.24.2
          flavor: alpine-virt
          file: alpine-virt-3.24.2-x86_64.iso
          iso: alpine-virt-3.24.2-x86_64.iso
          date: 2026-09-17
          time: 17:38:33
          size: 69206016
          sha256: 3ab424762af704b2c2a9e57df1dc37f982af260071504d977f2fb96822e7130b
          sha512: 7563011cefca3f84c77ddab032d47448216e1fc9b730b7d09be9cc26c8d5a69c1b75c9a404f5168654c76128fa231d83b248e24466d6c5dd2655696f44220aba
        -
          title: "Xen"
          desc: |
            Built-in support for Xen Hypervisor.
            Includes packages targetted at Xen usage.
            Use for Xen Dom0.
          branch: v3.24
          arch: x86_64
          version: 3.24.2
          flavor: alpine-xen
          file: alpine-xen-3.24.2-x86_64.iso
          iso: alpine-xen-3.24.2-x86_64.iso
          date: 2026-09-17
          time: 17:40:51
          size: 1528430592
          sha256: f3c8afed17e50017e2919e3995a8ef42dcead5c7bad6889f0a4ef41bd6251dba
          sha512: 4da399b383a2f2656366d1b90222584369d386b7aeed8c91880bd91eabb80e8b1560cf10c2a980fe0971513afd5d74e9223a3be0133bbc131c1a60b2b0a16bda
        """

    func testTheAlpineIndexGivesTheBootableImagesWithTheirSums() throws {
        let releases = ImageDownload.alpineReleases(Self.index)
        XCTAssertEqual(releases.map(\.flavor), [
            "alpine-minirootfs", "alpine-netboot", "alpine-standard",
            "alpine-extended", "alpine-virt", "alpine-xen",
        ])
        let bootable = ImageDownload.bootable(releases)
        XCTAssertEqual(bootable.map(\.flavor), ["alpine-virt", "alpine-standard"])
        let virt = try XCTUnwrap(bootable.first)
        XCTAssertEqual(virt, ImageDownload.Release(
            flavor: "alpine-virt", title: "Virtual", version: "3.24.2", arch: "x86_64",
            file: "alpine-virt-3.24.2-x86_64.iso", size: 69_206_016,
            sha256: "3ab424762af704b2c2a9e57df1dc37f982af260071504d977f2fb96822e7130b"))
        XCTAssertEqual(ImageDownload.url(of: virt).absoluteString,
                       "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
                        + "alpine-virt-3.24.2-x86_64.iso")
    }

    /// Une entrée dont le nom de fichier serait un chemin, ou dont la somme
    /// n'en est pas une, n'est pas rendue : l'index vient du réseau.
    func testAnIndexEntryThatCouldMisleadIsDropped() {
        func entry(file: String, sha: String, size: String = "10") -> String {
            "-\n  flavor: alpine-virt\n  file: \(file)\n  size: \(size)\n  sha256: \(sha)\n"
        }
        let sha = String(repeating: "ab", count: 32)
        XCTAssertEqual(ImageDownload.alpineReleases(entry(file: "a.iso", sha: sha)).count, 1)
        XCTAssertEqual(ImageDownload.alpineReleases(entry(file: "../../a.iso", sha: sha)).count, 0)
        XCTAssertEqual(ImageDownload.alpineReleases(entry(file: "dossier/a.iso", sha: sha)).count, 0)
        XCTAssertEqual(ImageDownload.alpineReleases(entry(file: ".a.iso", sha: sha)).count, 0)
        XCTAssertEqual(ImageDownload.alpineReleases(entry(file: "a.iso", sha: "abc")).count, 0)
        XCTAssertEqual(ImageDownload.alpineReleases(entry(file: "a.iso", sha: sha, size: "0")).count, 0)
        XCTAssertEqual(ImageDownload.alpineReleases("pas un index").count, 0)
    }

    // MARK: - Reprendre

    /// Les réponses du vrai miroir, relevées avec `curl -r` : la reprise
    /// demandée à l'octet 100 revient en `206 bytes 100-199/69206016` ; la
    /// demande au-delà de la fin, en `416 bytes */69206016`.
    func testTheServerAnswerSaysWhatToDoWithTheBytes() {
        typealias C = ImageDownload.Continuation
        XCTAssertNil(ImageDownload.rangeHeader(resumingAt: 0))
        XCTAssertEqual(ImageDownload.rangeHeader(resumingAt: 100), "bytes=100-")
        XCTAssertEqual(ImageDownload.continuation(status: 200, contentRange: nil, resumingAt: 0), C.append)
        XCTAssertEqual(ImageDownload.continuation(
            status: 206, contentRange: "bytes 100-199/69206016", resumingAt: 100), C.append)
        XCTAssertEqual(ImageDownload.continuation(
            status: 206, contentRange: "bytes 100-199/*", resumingAt: 100), C.append)
        // Un serveur qui ignore la reprise renvoie tout depuis le début.
        XCTAssertEqual(ImageDownload.continuation(status: 200, contentRange: nil, resumingAt: 100), C.restart)
        // Le `.part` a déjà tout : rien à recevoir, la somme dira le reste.
        XCTAssertEqual(ImageDownload.continuation(
            status: 416, contentRange: "bytes */69206016", resumingAt: 69_206_016), C.complete)
        // Plus long que le fichier : il vient d'une autre version.
        XCTAssertEqual(ImageDownload.continuation(
            status: 416, contentRange: "bytes */69206016", resumingAt: 70_000_000), C.restart)
        // Une reprise ailleurs qu'à l'octet demandé recoudrait de travers.
        if case .refuse = ImageDownload.continuation(
            status: 206, contentRange: "bytes 0-99/69206016", resumingAt: 100) {} else {
            XCTFail("une reprise au mauvais octet doit être refusée")
        }
        if case .refuse = ImageDownload.continuation(status: 206, contentRange: nil, resumingAt: 100) {} else {
            XCTFail("une reprise sans Content-Range doit être refusée")
        }
        XCTAssertEqual(ImageDownload.continuation(status: 404, contentRange: nil, resumingAt: 0),
                       C.refuse("le fichier n'existe plus sur le serveur (404)."))
        XCTAssertEqual(ImageDownload.continuation(status: 503, contentRange: nil, resumingAt: 0),
                       C.refuse("le serveur a répondu 503."))
        XCTAssertEqual(ImageDownload.partURL(for: folder.appendingPathComponent("a.iso")).lastPathComponent,
                       "a.iso.part")
    }

    // MARK: - Finir

    /// Un fichier entier et juste prend le nom de l'image ; un fichier faux
    /// est effacé, pour que le prochain essai ne reprenne pas sur lui.
    func testOnlyAVerifiedFileEntersTheLibrary() throws {
        let bytes = Array("une image, pas une vraie".utf8)
        let sum = SHA256.hex(bytes)
        let destination = folder.appendingPathComponent("image.iso")
        let part = ImageDownload.partURL(for: destination)

        try Data(bytes).write(to: part)
        try ImageDownload.finish(part: part, as: destination, size: bytes.count, sha256: sum.uppercased())
        XCTAssertEqual(try Data(contentsOf: destination), Data(bytes))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))

        try Data(bytes.dropLast()).write(to: part)
        XCTAssertThrowsError(try ImageDownload.finish(
            part: part, as: destination, size: bytes.count, sha256: sum)) {
            XCTAssertEqual($0 as? ImageDownload.Failure,
                           .wrongSize(expected: bytes.count, got: bytes.count - 1))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), "effacé")

        var altered = bytes
        altered[3] ^= 1
        try Data(altered).write(to: part)
        XCTAssertThrowsError(try ImageDownload.finish(part: part, as: destination, size: nil, sha256: sum)) {
            XCTAssertEqual($0 as? ImageDownload.Failure,
                           .checksumMismatch(expected: sum, got: SHA256.hex(altered)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), "effacé")
        XCTAssertEqual(try Data(contentsOf: destination), Data(bytes), "l'image juste n'a pas été touchée")
    }
}
