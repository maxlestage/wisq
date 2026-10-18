import XCTest
@testable import WisqVM

/// Le téléchargement de bout en bout, contre un serveur scripté qui se
/// conduit comme le miroir d'Alpine — ou comme un serveur qui ne s'y conduit
/// pas.
final class ImageDownloaderTests: XCTestCase {
    private var folder: URL!
    private var library: URL { folder.appendingPathComponent("bibliotheque") }
    private var parts: URL { folder.appendingPathComponent("telechargements") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-telechargeur-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Un serveur de fichier unique : il honore `Range` comme le miroir, et
    /// sait mal se conduire sur commande.
    final class Server: RangeFetcher, @unchecked Sendable {
        enum Behaviour { case honest, ignoresRange, wrongOffset }
        let file: [UInt8]
        var behaviour = Behaviour.honest
        /// Coupe la connexion après tant d'octets envoyés, en levant une
        /// erreur, puis se tait pour les requêtes suivantes.
        var cutAfter: Int?
        /// Finit la réponse proprement après tant d'octets.
        var endAfter: Int?
        var corruptAt: Int?
        var extra = 0
        private(set) var ranges: [String?] = []
        private let lock = NSLock()

        struct Cut: Error {}

        init(_ file: [UInt8]) { self.file = file }

        func fetch(_ url: URL, range: String?) async throws -> FetchedResponse {
            let (cut, end) = lock.withLock {
                ranges.append(range)
                defer { cutAfter = nil; endAfter = nil }
                return (cutAfter, endAfter)
            }
            var start = 0
            var last = file.count - 1
            var status = 200
            var contentRange: String?
            if let range, behaviour != .ignoresRange {
                // `bytes=100-` pour une reprise, `bytes=0-0` pour la taille.
                let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
                start = Int(bounds[0])!
                if let end = Int(bounds[1]) { last = min(end, last) }
                if start >= file.count {
                    return FetchedResponse(status: 416, contentRange: "bytes */\(file.count)",
                                           body: AsyncThrowingStream { $0.finish() })
                }
                status = 206
                let shown = behaviour == .wrongOffset ? 0 : start
                contentRange = "bytes \(shown)-\(last)/\(file.count)"
            }
            var bytes = Array(file[start...last]) + [UInt8](repeating: 7, count: extra)
            if let corruptAt, corruptAt >= start { bytes[corruptAt - start] ^= 0xFF }
            let send = bytes
            let body = AsyncThrowingStream<Data, Error> { continuation in
                var sent = 0
                while sent < send.count {
                    let piece = min(4096, send.count - sent)
                    if let cut, sent + piece > cut {
                        continuation.yield(Data(send[sent..<cut]))
                        continuation.finish(throwing: Cut())
                        return
                    }
                    if let end, sent + piece > end {
                        continuation.yield(Data(send[sent..<end]))
                        continuation.finish()
                        return
                    }
                    continuation.yield(Data(send[sent..<(sent + piece)]))
                    sent += piece
                }
                continuation.finish()
            }
            return FetchedResponse(status: status, contentRange: contentRange, body: body)
        }
    }

    private let image: [UInt8] = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) }

    private var release: ImageDownload.Release {
        ImageDownload.Release(distribution: "Alpine", flavor: "alpine-virt", title: "Virtual", version: "3.24.2",
                              arch: "x86_64", file: "alpine-virt.iso", size: image.count,
                              checksum: .sha256(SHA256Stream.hex(image)), index: ImageDownload.alpineIndex)
    }

    private var part: URL { parts.appendingPathComponent("alpine-virt.iso.part") }

    private func size(_ url: URL) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    }

    /// Le cas ordinaire : une requête sans `Range`, le fichier dans la
    /// bibliothèque à son nom, et plus de `.part`.
    func testAFreshDownloadLandsInTheLibraryVerified() async throws {
        let server = Server(image)
        let downloader = ImageDownloader(fetcher: server, partsFolder: parts)
        let url = try await downloader.download(release, into: library)
        XCTAssertEqual(url, library.appendingPathComponent("alpine-virt.iso"))
        XCTAssertEqual(try Data(contentsOf: url), Data(image))
        XCTAssertEqual(server.ranges, [nil])
        XCTAssertNil(size(part), "le .part a pris le nom de l'image")
    }

    /// **La reprise.** Coupé à 40 000 octets, le transfert garde ce qu'il a ;
    /// l'essai suivant demande `bytes=40000-`, part de là, et finit juste.
    func testACutTransferResumesWhereItStopped() async throws {
        let server = Server(image)
        server.cutAfter = 40000
        let downloader = ImageDownloader(fetcher: server, partsFolder: parts)
        do {
            _ = try await downloader.download(release, into: library)
            XCTFail("la coupure doit remonter")
        } catch is Server.Cut {}
        XCTAssertEqual(size(part), 40000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("alpine-virt.iso").path))

        let seen = Seen()
        let url = try await downloader.download(release, into: library) { have, total in
            seen.add(have, total)
        }
        XCTAssertEqual(server.ranges, [nil, "bytes=40000-"])
        XCTAssertEqual(seen.first?.0, 40000, "le progrès part de ce qui est déjà là")
        XCTAssertEqual(seen.last?.0, image.count)
        XCTAssertEqual(try Data(contentsOf: url), Data(image))
    }

    /// Une réponse qui finit proprement mais trop tôt n'efface rien : c'est
    /// un transfert coupé, pas un fichier faux.
    func testAResponseThatEndsEarlyKeepsWhatItBrought() async throws {
        let server = Server(image)
        server.endAfter = 30000
        let downloader = ImageDownloader(fetcher: server, partsFolder: parts)
        do {
            _ = try await downloader.download(release, into: library)
            XCTFail("un transfert court doit le dire")
        } catch {
            XCTAssertEqual(error as? ImageDownloader.Failure, .interrupted(have: 30000, of: image.count))
        }
        XCTAssertEqual(size(part), 30000)
        _ = try await downloader.download(release, into: library)
        XCTAssertEqual(server.ranges, [nil, "bytes=30000-"])
    }

    /// Un serveur qui ignore la reprise renvoie tout depuis le début : le
    /// `.part` est vidé avant d'écrire, sinon le fichier aurait le début deux
    /// fois.
    func testAServerThatIgnoresTheRangeStartsTheFileOver() async throws {
        let server = Server(image)
        server.cutAfter = 25000
        let downloader = ImageDownloader(fetcher: server, partsFolder: parts)
        _ = try? await downloader.download(release, into: library)
        server.behaviour = .ignoresRange
        let url = try await downloader.download(release, into: library)
        XCTAssertEqual(try Data(contentsOf: url), Data(image))
    }

    /// Une reprise annoncée à un autre octet que celui demandé est refusée,
    /// et ce qui était déjà là reste là.
    func testAResumeAtTheWrongOffsetIsRefusedAndKeepsThePart() async throws {
        let server = Server(image)
        server.cutAfter = 25000
        let downloader = ImageDownloader(fetcher: server, partsFolder: parts)
        _ = try? await downloader.download(release, into: library)
        server.behaviour = .wrongOffset
        do {
            _ = try await downloader.download(release, into: library)
            XCTFail("une reprise au mauvais octet doit être refusée")
        } catch {
            guard case .refused = error as? ImageDownloader.Failure else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(size(part), 25000)
    }

    /// Un octet changé en route : la somme le voit, le `.part` est effacé, et
    /// rien n'entre dans la bibliothèque.
    func testACorruptedTransferIsDiscarded() async throws {
        let server = Server(image)
        server.corruptAt = 50000
        let downloader = ImageDownloader(fetcher: server, partsFolder: parts)
        do {
            _ = try await downloader.download(release, into: library)
            XCTFail("un fichier altéré ne doit pas entrer")
        } catch {
            guard case .checksumMismatch = error as? ImageDownload.Failure else { return XCTFail("\(error)") }
        }
        XCTAssertNil(size(part))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
    }

    /// Un `.part` déjà complet n'est pas redemandé ; un `.part` plus long que
    /// le fichier vient d'une autre version, et est repris de zéro.
    func testAPartAlreadyWholeIsFinishedAndOneTooLongIsDropped() async throws {
        let server = Server(image)
        let downloader = ImageDownloader(fetcher: server, partsFolder: parts)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        try Data(image).write(to: part)
        _ = try await downloader.download(release, into: library)
        XCTAssertEqual(server.ranges, [], "rien à demander")

        try Data(image + [1, 2, 3]).write(to: part)
        _ = try await downloader.download(release, into: library)
        XCTAssertEqual(server.ranges, [nil], "repris de zéro, sans Range")
    }

    /// Un serveur qui envoie plus que la taille annoncée est arrêté avant
    /// d'avoir rempli le téléphone.
    func testAServerSendingMoreThanAnnouncedIsStopped() async throws {
        let server = Server(image)
        server.extra = 10
        let downloader = ImageDownloader(fetcher: server, partsFolder: parts)
        do {
            _ = try await downloader.download(release, into: library)
            XCTFail("un envoi trop long doit être arrêté")
        } catch {
            XCTAssertEqual(error as? ImageDownloader.Failure,
                           .refused("le serveur envoie plus que la taille annoncée."))
        }
        XCTAssertLessThanOrEqual(size(part) ?? 0, image.count)
    }

    /// L'index passe par le même chemin : lu, il donne les images qui
    /// démarrent ; un index introuvable ou vide le dit.
    func testTheIndexIsReadThroughTheSameFetcher() async throws {
        let index = Server(Array(ImageDownloadTests.index.utf8))
        let releases = try await ImageDownloader(fetcher: index, partsFolder: parts).bootableReleases()
        XCTAssertEqual(releases.map(\.flavor), ["alpine-virt", "alpine-standard"])

        let empty = Server(Array("---\n".utf8))
        do {
            _ = try await ImageDownloader(fetcher: empty, partsFolder: parts).bootableReleases()
            XCTFail("un index vide doit le dire")
        } catch {
            XCTAssertEqual(error as? ImageDownloader.Failure, .nothingToDownload)
        }
    }

    /// Plusieurs serveurs, un par adresse : ce qu'un téléphone voit quand il
    /// lit l'index d'Alpine et celui de Debian.
    final class Router: RangeFetcher, @unchecked Sendable {
        let routes: [URL: Server]
        init(_ routes: [URL: Server]) { self.routes = routes }
        func fetch(_ url: URL, range: String?) async throws -> FetchedResponse {
            guard let server = routes[url] else {
                return FetchedResponse(status: 404, contentRange: nil, body: AsyncThrowingStream { $0.finish() })
            }
            return try await server.fetch(url, range: range)
        }
    }

    private var debianImage: URL {
        ImageDownload.debianIndex.deletingLastPathComponent()
            .appendingPathComponent("debian-13-nocloud-amd64.qcow2")
    }

    /// **Debian à côté d'Alpine** : sa taille demandée au serveur (un octet),
    /// puis le fichier téléchargé et vérifié contre sa somme SHA-512.
    func testDebianIsListedWithItsSizeAndVerifiedBySHA512() async throws {
        let sums = SHA256Stream.hexString(SHA512Crypt.sha512(image)) + "  debian-13-nocloud-amd64.qcow2\n"
        let file = Server(image)
        let router = Router([
            ImageDownload.alpineIndex: Server(Array(ImageDownloadTests.index.utf8)),
            ImageDownload.debianIndex: Server(Array(sums.utf8)),
            debianImage: file,
        ])
        let downloader = ImageDownloader(fetcher: router, partsFolder: parts)
        let releases = try await downloader.bootableReleases()
        XCTAssertEqual(releases.map(\.flavor), ["alpine-virt", "alpine-standard", "debian-nocloud"])
        let debian = try XCTUnwrap(releases.last)
        XCTAssertEqual(debian.size, image.count, "la taille vient du 206")
        XCTAssertEqual(file.ranges, [ImageDownload.sizeProbe])

        let url = try await downloader.download(debian, into: library)
        XCTAssertEqual(url, library.appendingPathComponent("debian-13-nocloud-amd64.qcow2"))
        XCTAssertEqual(try Data(contentsOf: url), Data(image))
    }

    /// **Un index muet ne cache pas l'autre**, et une image dont le serveur
    /// ne dit pas la taille n'est pas proposée. Seul un échec de tous est un
    /// échec, et il dit le premier.
    func testOneSilentIndexDoesNotHideTheOther() async throws {
        let onlyDebian = Router([
            ImageDownload.debianIndex: Server(Array((String(repeating: "ab", count: 64)
                                                     + "  debian-13-nocloud-amd64.qcow2\n").utf8)),
            debianImage: Server(image),
        ])
        let releases = try await ImageDownloader(fetcher: onlyDebian, partsFolder: parts).bootableReleases()
        XCTAssertEqual(releases.map(\.flavor), ["debian-nocloud"])
        let onlyAlpine = Router([ImageDownload.alpineIndex: Server(Array(ImageDownloadTests.index.utf8))])
        let alpine = try await ImageDownloader(fetcher: onlyAlpine, partsFolder: parts).bootableReleases()
        XCTAssertEqual(alpine.map(\.flavor), ["alpine-virt", "alpine-standard"], "Debian muet, Alpine reste")

        let sizeless = Server(image)
        sizeless.behaviour = .ignoresRange
        let noSize = Router([
            ImageDownload.alpineIndex: Server(Array(ImageDownloadTests.index.utf8)),
            ImageDownload.debianIndex: Server(Array((String(repeating: "ab", count: 64)
                                                     + "  debian-13-nocloud-amd64.qcow2\n").utf8)),
            debianImage: sizeless,
        ])
        let alpineOnly = try await ImageDownloader(fetcher: noSize, partsFolder: parts).bootableReleases()
        XCTAssertEqual(alpineOnly.map(\.flavor), ["alpine-virt", "alpine-standard"])

        do {
            _ = try await ImageDownloader(fetcher: Router([:]), partsFolder: parts).bootableReleases()
            XCTFail("aucun index lisible doit le dire")
        } catch {
            XCTAssertEqual(error as? ImageDownloader.Failure,
                           .refused("l'index de la distribution n'a pas pu être lu (404)."))
        }
    }

    /// Les progrès reçus, dans l'ordre.
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(Int, Int)] = []
        func add(_ have: Int, _ total: Int) { lock.lock(); values.append((have, total)); lock.unlock() }
        var first: (Int, Int)? { lock.lock(); defer { lock.unlock() }; return values.first }
        var last: (Int, Int)? { lock.lock(); defer { lock.unlock() }; return values.last }
    }
}
