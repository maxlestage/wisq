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
        XCTAssertEqual(SHA256Stream.hex([UInt8]()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Stream.hex(Array("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Stream.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256Stream.hex([UInt8](repeating: 0x61, count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    /// Par morceaux de toutes les tailles, à cheval sur les blocs de 64
    /// octets : la même somme qu'en une fois. C'est ainsi qu'un fichier est
    /// haché, par mégaoctets.
    func testSHA256ByPiecesIsTheSameAsAtOnce() {
        let bytes = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 7) }
        let whole = SHA256Stream.hex(bytes)
        for piece in [1, 3, 55, 56, 63, 64, 65, 127, 1000] {
            var hash = SHA256Stream()
            var start = 0
            while start < bytes.count {
                hash.update(bytes[start..<min(start + piece, bytes.count)])
                start += piece
            }
            XCTAssertEqual(SHA256Stream.hexString(hash.finalize()), whole, "morceaux de \(piece)")
        }
        let url = folder.appendingPathComponent("f")
        XCTAssertNoThrow(try Data(bytes).write(to: url))
        XCTAssertEqual(try SHA256Stream.hex(ofFileAt: url), whole)
    }

    // MARK: - SHA-512

    /// Les vecteurs de FIPS 180-4 : vide, « abc », le message de deux blocs,
    /// et un million de « a » ; par morceaux à cheval sur les blocs de 128
    /// octets, la même somme qu'en une fois, et la même que `SHA512Crypt`.
    func testSHA512ByPiecesMatchesTheStandardVectors() throws {
        XCTAssertEqual(SHA512Stream.hex([UInt8]()),
                       "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"
                           + "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
        XCTAssertEqual(SHA512Stream.hex(Array("abc".utf8)),
                       "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                           + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        XCTAssertEqual(SHA512Stream.hex([UInt8](repeating: 0x61, count: 1_000_000)),
                       "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973eb"
                           + "de0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b")
        let bytes = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 7) }
        let whole = SHA512Stream.hex(bytes)
        XCTAssertEqual(whole, SHA256Stream.hexString(SHA512Crypt.sha512(bytes)))
        for piece in [1, 7, 111, 112, 127, 128, 129, 255, 1000] {
            var hash = SHA512Stream()
            var start = 0
            while start < bytes.count {
                hash.update(bytes[start..<min(start + piece, bytes.count)])
                start += piece
            }
            XCTAssertEqual(SHA256Stream.hexString(hash.finalize()), whole, "morceaux de \(piece)")
        }
        let url = folder.appendingPathComponent("f")
        try Data(bytes).write(to: url)
        XCTAssertEqual(try SHA512Stream.hex(ofFileAt: url), whole)
    }

    // MARK: - L'index de Debian

    /// Des lignes du vrai `SHA512SUMS` de Debian 13 (relevé le 18 octobre
    /// 2026), plus des lignes qui ne doivent rien donner : seule l'image
    /// `nocloud` pour PC, en qcow2, sort, avec sa version et sa somme.
    static let debianSums = """
        9819cd8290a212160ab7f88d18b993399ccf05d3f4f790f3318f82a88e03b3c60d2405688cb99490ea98ec4204e55bf0f8c3b8ee627a8065759b0b1a39b11a7b  debian-13-generic-amd64.json
        62aa92aeff32cbf3fe6c01f410fef4035b1603a512f073c9f8889072168de9e49fa361ba48621359fc7608ad91225e823ea233feb33f612eb39e50aaf21957fe  debian-13-generic-amd64.qcow2
        ec584ccabfef7120b4c4f7482adf0e615894d9292cedec446b64194b951ebe5dd97c336b5dcbae458333764b0edd516334506017f33c4f2020ef8d38b569ffe3  debian-13-genericcloud-amd64.qcow2
        401ffd04907291b3af4fd9832b38fa16ac92e83cdb21a954f76a72d2b2d0daa6f6fc98a596f52a2616c0a3f11fd8f47138da8f5667b7f15f0a4bbc5f5bd0df26  debian-13-nocloud-amd64.qcow2
        b91d3ea53e5d31eb13d721fd8b650990ff43cdbf4f2c57b215e077999161c8a4cff1984c882085092a91ccbe8c1c13faee146b5146aa308d44c95e60c46d82f0  debian-13-nocloud-amd64.raw
        866b11bfa9c2dfb9a15569b9e1407c01cf9daa3e1e75afe576af58a8737f2a7436f585d45ce8bfb620976c8459f5347badab9c4c83552010c33ade0ab3eac37f  debian-13-nocloud-arm64.qcow2
        401ffd04  debian-14-nocloud-amd64.qcow2
        401ffd04907291b3af4fd9832b38fa16ac92e83cdb21a954f76a72d2b2d0daa6f6fc98a596f52a2616c0a3f11fd8f47138da8f5667b7f15f0a4bbc5f5bd0df26  ../debian-13-nocloud-amd64.qcow2
        401ffd04907291b3af4fd9832b38fa16ac92e83cdb21a954f76a72d2b2d0daa6f6fc98a596f52a2616c0a3f11fd8f47138da8f5667b7f15f0a4bbc5f5bd0df26  debian-x-nocloud-amd64.qcow2
        """

    func testTheDebianIndexGivesTheNocloudImageOnly() {
        let found = ImageDownload.debianCandidates(Self.debianSums)
        XCTAssertEqual(found.map(\.file), ["debian-13-nocloud-amd64.qcow2"])
        XCTAssertEqual(found.first?.version, "13")
        XCTAssertEqual(found.first?.sha512.prefix(8), "401ffd04")
        // L'étoile du mode binaire de `sha512sum` ne fait pas partie du nom.
        let starred = ImageDownload.debianCandidates(String(repeating: "ab", count: 64)
                                                         + " *debian-14-nocloud-amd64.qcow2")
        XCTAssertEqual(starred.map(\.file), ["debian-14-nocloud-amd64.qcow2"])
        let release = ImageDownload.debianRelease(file: "debian-13-nocloud-amd64.qcow2", version: "13",
                                                  sha512: String(repeating: "ab", count: 64), size: 10)
        XCTAssertEqual(ImageDownload.url(of: release).absoluteString,
                       "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-nocloud-amd64.qcow2")
        XCTAssertEqual(release.checksum.algorithm, "SHA-512")
    }

    /// **Le vrai fichier**, si on le donne (`WISQ_DEBIAN_QCOW2`) : sa somme
    /// SHA-512 est celle de `SHA512SUMS`, et le temps qu'elle prend se lit.
    func testTheRealDebianImageMatchesItsPublishedSum() throws {
        guard let path = ProcessInfo.processInfo.environment["WISQ_DEBIAN_QCOW2"] else {
            throw XCTSkip("image absente : définir WISQ_DEBIAN_QCOW2 pour ce test")
        }
        let started = Date()
        let digest = try SHA512Stream.hex(ofFileAt: URL(fileURLWithPath: path))
        print("SHA-512 de \(path) en \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        XCTAssertEqual(digest, ImageDownload.debianCandidates(Self.debianSums).first?.sha512)
    }

    /// La taille demandée au serveur : le total d'un `206`, rien d'autre.
    func testTheSizeProbeReadsOnlyAPartialAnswer() {
        XCTAssertEqual(ImageDownload.size(fromProbe: 206, contentRange: "bytes 0-0/437452288"), 437_452_288)
        XCTAssertNil(ImageDownload.size(fromProbe: 206, contentRange: "bytes 0-0/*"))
        XCTAssertNil(ImageDownload.size(fromProbe: 200, contentRange: nil))
        XCTAssertNil(ImageDownload.size(fromProbe: 206, contentRange: nil))
        // Un `200` envoie le fichier entier, pas l'octet demandé : un
        // `Content-Range` qui l'accompagnerait ne décrit rien de ce qui vient.
        XCTAssertNil(ImageDownload.size(fromProbe: 200, contentRange: "bytes 0-0/10"))
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
            distribution: "Alpine", flavor: "alpine-virt", title: "Virtual", version: "3.24.2", arch: "x86_64",
            file: "alpine-virt-3.24.2-x86_64.iso", size: 69_206_016,
            checksum: .sha256("3ab424762af704b2c2a9e57df1dc37f982af260071504d977f2fb96822e7130b"),
            index: ImageDownload.alpineIndex))
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
        typealias Answer = ImageDownload.Continuation
        XCTAssertNil(ImageDownload.rangeHeader(resumingAt: 0))
        XCTAssertEqual(ImageDownload.rangeHeader(resumingAt: 100), "bytes=100-")
        XCTAssertEqual(ImageDownload.continuation(status: 200, contentRange: nil, resumingAt: 0), Answer.append)
        XCTAssertEqual(ImageDownload.continuation(
            status: 206, contentRange: "bytes 100-199/69206016", resumingAt: 100), Answer.append)
        XCTAssertEqual(ImageDownload.continuation(
            status: 206, contentRange: "bytes 100-199/*", resumingAt: 100), Answer.append)
        // Un serveur qui ignore la reprise renvoie tout depuis le début.
        XCTAssertEqual(ImageDownload.continuation(status: 200, contentRange: nil, resumingAt: 100), Answer.restart)
        // Le `.part` a déjà tout : rien à recevoir, la somme dira le reste.
        XCTAssertEqual(ImageDownload.continuation(
            status: 416, contentRange: "bytes */69206016", resumingAt: 69_206_016), Answer.complete)
        // Plus long que le fichier : il vient d'une autre version.
        XCTAssertEqual(ImageDownload.continuation(
            status: 416, contentRange: "bytes */69206016", resumingAt: 70_000_000), Answer.restart)
        // Une reprise ailleurs qu'à l'octet demandé recoudrait de travers.
        if case .refuse = ImageDownload.continuation(
            status: 206, contentRange: "bytes 0-99/69206016", resumingAt: 100) {} else {
            XCTFail("une reprise au mauvais octet doit être refusée")
        }
        if case .refuse = ImageDownload.continuation(status: 206, contentRange: nil, resumingAt: 100) {} else {
            XCTFail("une reprise sans Content-Range doit être refusée")
        }
        XCTAssertEqual(ImageDownload.continuation(status: 404, contentRange: nil, resumingAt: 0),
                       Answer.refuse("le fichier n'existe plus sur le serveur (404)."))
        XCTAssertEqual(ImageDownload.continuation(status: 503, contentRange: nil, resumingAt: 0),
                       Answer.refuse("le serveur a répondu 503."))
        XCTAssertEqual(ImageDownload.partURL(for: folder.appendingPathComponent("a.iso")).lastPathComponent,
                       "a.iso.part")
    }

    // MARK: - Finir

    /// Un fichier entier et juste prend le nom de l'image ; un fichier faux
    /// est effacé, pour que le prochain essai ne reprenne pas sur lui.
    func testOnlyAVerifiedFileEntersTheLibrary() throws {
        let bytes = Array("une image, pas une vraie".utf8)
        let sum = SHA256Stream.hex(bytes)
        let destination = folder.appendingPathComponent("image.iso")
        let part = ImageDownload.partURL(for: destination)

        try Data(bytes).write(to: part)
        try ImageDownload.finish(part: part, as: destination, size: bytes.count, checksum: .sha256(sum.uppercased()))
        XCTAssertEqual(try Data(contentsOf: destination), Data(bytes))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))

        try Data(bytes.dropLast()).write(to: part)
        XCTAssertThrowsError(try ImageDownload.finish(
            part: part, as: destination, size: bytes.count, checksum: .sha256(sum))) {
            XCTAssertEqual($0 as? ImageDownload.Failure,
                           .wrongSize(expected: bytes.count, got: bytes.count - 1))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), "effacé")

        var altered = bytes
        altered[3] ^= 1
        try Data(altered).write(to: part)
        XCTAssertThrowsError(try ImageDownload.finish(part: part, as: destination, size: nil, checksum: .sha256(sum))) {
            XCTAssertEqual($0 as? ImageDownload.Failure,
                           .checksumMismatch(expected: sum, got: SHA256Stream.hex(altered)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), "effacé")
        XCTAssertEqual(try Data(contentsOf: destination), Data(bytes), "l'image juste n'a pas été touchée")
    }
}
