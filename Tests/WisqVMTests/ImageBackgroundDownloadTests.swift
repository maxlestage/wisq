import XCTest
@testable import WisqVM

/// **Le téléchargement qui continue en arrière-plan.** Une session
/// d'arrière-plan ne rend pas ses octets au fil de l'eau : elle écrit son
/// propre fichier et le donne entier, avec la réponse du serveur, quand le
/// transfert est fini — parfois longtemps après, l'application endormie entre
/// les deux. `backgroundRequest` dit ce qu'il faut lui demander, `adopt`
/// recoud ce qu'elle rend sur le `.part` et vérifie l'image.
///
/// Les mêmes règles que le téléchargement à l'écran, et c'est ce qu'on tient
/// ici : la reprise à l'octet près, le refus d'un `206` décalé, le `.part`
/// gardé quand le transfert s'est arrêté trop tôt, effacé seulement quand la
/// somme est fausse.
final class ImageBackgroundDownloadTests: XCTestCase {
    private var folder: URL!
    private var library: URL { folder.appendingPathComponent("bibliotheque") }
    private var parts: URL { folder.appendingPathComponent("telechargements") }
    private var part: URL { parts.appendingPathComponent("alpine-virt.iso.part") }
    private var installed: URL { library.appendingPathComponent("alpine-virt.iso") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-arriere-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Le fetcher n'est jamais appelé : en arrière-plan, c'est la session qui
    /// parle au serveur.
    struct Silent: RangeFetcher {
        func fetch(_ url: URL, range: String?) async throws -> FetchedResponse {
            XCTFail("aucune requête ne doit passer par le fetcher")
            return FetchedResponse(status: 500, contentRange: nil, body: AsyncThrowingStream { $0.finish() })
        }
    }

    private let image: [UInt8] = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ $0 >> 7) }

    private var release: ImageDownload.Release {
        ImageDownload.Release(distribution: "Alpine", flavor: "alpine-virt", title: "Virtual", version: "3.24.2",
                              arch: "x86_64", file: "alpine-virt.iso", size: image.count,
                              checksum: .sha256(SHA256Stream.hex(image)), index: ImageDownload.alpineIndex)
    }

    private var downloader: ImageDownloader { ImageDownloader(fetcher: Silent(), partsFolder: parts) }

    /// Le fichier qu'une session aurait écrit : des octets, à un endroit à
    /// elle.
    private func received(_ bytes: some Sequence<UInt8>) throws -> URL {
        let url = folder.appendingPathComponent("session-\(UUID().uuidString).tmp")
        try Data(bytes).write(to: url)
        return url
    }

    private func havePart(_ count: Int) throws {
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        try Data(image[0..<count]).write(to: part)
    }

    private func size(_ url: URL) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    }

    /// **Le premier transfert** : pas de `Range`, un `200` et tout le fichier,
    /// rangé vérifié dans la bibliothèque.
    func testAFirstBackgroundTransferIsAdoptedVerified() throws {
        let request = try XCTUnwrap(try downloader.backgroundRequest(for: release))
        XCTAssertEqual(request.url, ImageDownload.url(of: release))
        XCTAssertNil(request.range, "rien à reprendre")
        let url = try downloader.adopt(try received(image), status: 200, contentRange: nil,
                                       for: release, into: library)
        XCTAssertEqual(url, installed)
        XCTAssertEqual(try Data(contentsOf: url), Data(image))
        XCTAssertNil(size(part), "le .part a pris le nom de l'image")
    }

    /// **La reprise.** Le `.part` a 40 000 octets d'un essai à l'écran ; la
    /// session demande la suite, et ce qu'elle rend se recoud après eux.
    func testABackgroundTransferResumesWhereThePartStops() throws {
        try havePart(40000)
        let request = try XCTUnwrap(try downloader.backgroundRequest(for: release))
        XCTAssertEqual(request.range, "bytes=40000-")
        let url = try downloader.adopt(try received(image[40000...]), status: 206,
                                       contentRange: "bytes 40000-99999/100000",
                                       for: release, into: library)
        XCTAssertEqual(try Data(contentsOf: url), Data(image))
    }

    /// **Le `.part` a bougé pendant que la session travaillait** : repris à
    /// l'écran jusqu'à 60 000 octets. La réponse commence à 40 000 ; la
    /// recoudre doublerait vingt mille octets. Elle est refusée, et le
    /// `.part` reste tel qu'il est.
    func testAResponseForAnOlderPartIsRefusedAndKeepsThePart() throws {
        try havePart(40000)
        _ = try downloader.backgroundRequest(for: release)
        try havePart(60000)
        // Un morceau qui tiendrait dans la taille annoncée : c'est l'octet
        // de départ qui doit le faire refuser, pas la place qui manque.
        XCTAssertThrowsError(try downloader.adopt(try received(image[40000..<50000]), status: 206,
                                                  contentRange: "bytes 40000-99999/100000",
                                                  for: release, into: library)) { error in
            XCTAssertEqual(error as? ImageDownloader.Failure,
                           .refused("le serveur a repris le fichier ailleurs qu'à l'octet 60000."))
        }
        XCTAssertEqual(size(part), 60000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
    }

    /// **Le serveur a ignoré la reprise** et renvoie tout le fichier, en
    /// `200` : le `.part` repart de zéro au lieu d'être allongé.
    func testAServerThatIgnoredTheRangeStartsThePartOver() throws {
        try havePart(40000)
        let url = try downloader.adopt(try received(image), status: 200, contentRange: nil,
                                       for: release, into: library)
        XCTAssertEqual(try Data(contentsOf: url), Data(image))
    }

    /// **La session a fini trop tôt** : trente mille octets au lieu de
    /// soixante mille. Ce n'est pas un fichier faux, c'est un transfert
    /// coupé : le `.part` les garde, et la requête suivante reprend après.
    func testAShortTransferKeepsWhatItBroughtAndTheNextRequestResumes() throws {
        try havePart(40000)
        XCTAssertThrowsError(try downloader.adopt(try received(image[40000..<70000]), status: 206,
                                                  contentRange: "bytes 40000-99999/100000",
                                                  for: release, into: library)) { error in
            XCTAssertEqual(error as? ImageDownloader.Failure, .interrupted(have: 70000, of: 100_000))
        }
        XCTAssertEqual(size(part), 70000)
        XCTAssertEqual(try downloader.backgroundRequest(for: release)?.range, "bytes=70000-")
    }

    /// **Plus rien à recevoir** : le `.part` est déjà entier. Il n'y a pas de
    /// requête à faire, et un `416` qui dit la même taille ne fait que
    /// vérifier.
    func testAWholePartNeedsNoRequestAndA416OnlyVerifies() throws {
        try havePart(image.count)
        XCTAssertNil(try downloader.backgroundRequest(for: release))
        let url = try downloader.adopt(try received([UInt8]()), status: 416,
                                       contentRange: "bytes */100000", for: release, into: library)
        XCTAssertEqual(try Data(contentsOf: url), Data(image))
    }

    /// **Une somme fausse efface le `.part`** : les octets ne valent rien, et
    /// les garder ferait reprendre un fichier faux.
    func testACorruptedTransferIsDiscarded() throws {
        var bytes = image
        bytes[77777] ^= 0xFF
        XCTAssertThrowsError(try downloader.adopt(try received(bytes), status: 200, contentRange: nil,
                                                  for: release, into: library))
        XCTAssertNil(size(part))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
    }

    /// **Plus que la taille annoncée** : refusé avant d'avoir été écrit en
    /// entier, et la session ne fait pas grossir le `.part` au-delà.
    func testMoreThanTheAnnouncedSizeIsRefused() throws {
        let tooMuch = image + [UInt8](repeating: 7, count: 3 << 20)
        XCTAssertThrowsError(try downloader.adopt(try received(tooMuch), status: 200, contentRange: nil,
                                                  for: release, into: library)) { error in
            XCTAssertEqual(error as? ImageDownloader.Failure,
                           .refused("le serveur envoie plus que la taille annoncée."))
        }
        XCTAssertLessThanOrEqual(size(part) ?? 0, image.count)
    }

    /// **Le fichier de la session n'est pas effacé** : il est à elle, et
    /// c'est elle qui le reprend une fois la main rendue.
    func testTheSessionFileIsLeftToTheSession() throws {
        let file = try received(image)
        _ = try downloader.adopt(file, status: 200, contentRange: nil, for: release, into: library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - L'étiquette de la tâche

    /// **L'image revient telle qu'elle est partie**, quelle que soit sa somme
    /// et qu'elle ait ou non sa propre adresse : c'est ce que la session rend
    /// au réveil, et c'est contre elle que `adopt` vérifie.
    func testTheBackgroundTagGivesBackTheSameRelease() throws {
        let fedora = ImageDownload.Release(
            distribution: "Fedora", flavor: "cloud", title: "Cloud", version: "43", arch: "x86_64",
            file: "Fedora-Cloud.qcow2", size: 512 << 20, checksum: .sha512(String(repeating: "ab", count: 64)),
            index: URL(string: "https://fedoraproject.org/releases.json")!,
            link: URL(string: "https://download.fedoraproject.org/pub/fedora/Fedora-Cloud.qcow2")!)
        for release in [release, fedora] {
            XCTAssertEqual(ImageDownload.Release(backgroundTag: release.backgroundTag), release)
        }
    }

    /// **Une étiquette qui n'en est pas une** — vide, d'un autre format,
    /// d'une version de wisq où il manquait un champ — ne donne pas d'image :
    /// la tâche est ignorée plutôt que recousue sur la mauvaise.
    func testATagThatIsNotOursGivesNothing() {
        XCTAssertNil(ImageDownload.Release(backgroundTag: ""))
        XCTAssertNil(ImageDownload.Release(backgroundTag: "alpine-virt.iso"))
        XCTAssertNil(ImageDownload.Release(backgroundTag: #"{"file":"alpine-virt.iso","size":3}"#))
    }

    /// **La somme est dans l'étiquette, et elle compte** : une image dont la
    /// somme a changé n'est pas la même image.
    func testTheChecksumIsPartOfTheTag() {
        let other = ImageDownload.Release(
            distribution: release.distribution, flavor: release.flavor, title: release.title,
            version: release.version, arch: release.arch, file: release.file, size: release.size,
            checksum: .sha256(String(repeating: "0", count: 64)), index: release.index)
        XCTAssertNotEqual(ImageDownload.Release(backgroundTag: other.backgroundTag), release)
    }
}
