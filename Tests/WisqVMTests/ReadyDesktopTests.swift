import Foundation
import XCTest
@testable import WisqVM

/// **L'entrée « Bureaux prêts »** (`ReadyDesktop`) : l'index lu comme ce qu'il
/// est — un fichier du réseau —, les deux téléchargements contre le serveur
/// scripté d'`ImageDownloaderTests`, et l'installation, qui refuse ce qui
/// s'importerait sans erreur mais démarrerait à froid sans le dire.
final class ReadyDesktopTests: XCTestCase {
    private typealias Server = ImageDownloaderTests.Server
    private typealias Router = ImageDownloaderTests.Router

    private var folder: URL!
    private var library: URL { folder.appendingPathComponent("bibliotheque") }
    private var downloads: URL { folder.appendingPathComponent("telechargements") }
    private var storage: URL { folder.appendingPathComponent("stockage") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-bureaux-\(UUID().uuidString)")
        for place in [library, downloads, storage] {
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    static let moment = Date(timeIntervalSince1970: 1_794_614_400)  // 2026-11-14T00:00:00Z
    static let isoName = "void-live-x86_64-20250202-xfce.iso"
    static let archiveName = "void-live-x86_64-20250202-xfce-pret-niveau1.wisqmachine"
    static let isoURL = "https://repo-default.voidlinux.org/live/20250202/\(isoName)"
    static let archiveURL = "https://github.com/maxlestage/wisq/releases/download/bureaux-1/\(archiveName)"

    private let iso: [UInt8] = (0..<60_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ $0 >> 7) }
    private let archiveBytes: [UInt8] = (0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 3) }

    /// Une entrée d'index propre : celle que `wisq-fabrique index` écrirait.
    private func entry(level: UInt64 = 1, digest: String = "d63775f2e341116a",
                       archive: [UInt8]? = nil, archiveSize: Int? = nil) -> ReadyDesktop.Index.Entry {
        let archive = archive ?? archiveBytes
        return ReadyDesktop.Index.Entry(
            title: "Void Xfce (prêt)", level: level, ramBytes: 1 << 30, kernelDigest: digest,
            madeAt: Self.moment,
            image: .init(name: Self.isoName, bytes: iso.count, sha256: SHA256Stream.hex(iso), url: Self.isoURL),
            archive: .init(name: Self.archiveName, bytes: archiveSize ?? archive.count,
                           sha256: SHA256Stream.hex(archive), url: Self.archiveURL))
    }

    private func json(_ entries: [ReadyDesktop.Index.Entry]) throws -> String {
        String(decoding: try ReadyDesktop.Index(desktops: entries).encoded(), as: UTF8.self)
    }

    private func desktop(_ entry: ReadyDesktop.Index.Entry) throws -> ReadyDesktop {
        try XCTUnwrap(ReadyDesktop.parse(try json([entry])).first)
    }

    // MARK: - L'index

    /// **Une entrée devient deux téléchargements vérifiés** : l'image à son
    /// adresse datée, l'archive à celle de la release, chacune à sa taille et
    /// à sa somme.
    func testAnEntryBecomesTwoVerifiedDownloads() throws {
        let desktops = ReadyDesktop.parse(try json([entry()]))
        XCTAssertEqual(desktops.count, 1)
        let desktop = try XCTUnwrap(desktops.first)
        XCTAssertEqual(desktop.title, "Void Xfce (prêt)")
        XCTAssertEqual(desktop.level, 1)
        XCTAssertEqual(desktop.ramBytes, 1 << 30)
        XCTAssertEqual(desktop.kernelDigest, "d63775f2e341116a")
        XCTAssertEqual(desktop.madeAt, Self.moment)
        XCTAssertEqual(ImageDownload.url(of: desktop.image).absoluteString, Self.isoURL)
        XCTAssertEqual(desktop.image.file, Self.isoName)
        XCTAssertEqual(desktop.image.size, iso.count)
        XCTAssertEqual(desktop.image.checksum, .sha256(SHA256Stream.hex(iso)))
        XCTAssertEqual(ImageDownload.url(of: desktop.archive).absoluteString, Self.archiveURL)
        XCTAssertEqual(desktop.archive.file, Self.archiveName)
        XCTAssertEqual(desktop.archive.checksum, .sha256(SHA256Stream.hex(archiveBytes)))
        XCTAssertEqual(desktop.image.version, "2026.11.14")
    }

    /// **L'entrée d'une fiche** : ce que `wisq-fabrique index` écrit à partir
    /// de la fiche de la fabrication se relit, et se propose.
    func testTheSheetOfABuildBecomesAnEntryThatIsOffered() throws {
        let sheet = ReadyDesktopBuild.Sheet(
            title: "Void Xfce (prêt)", level: X86Machine.snapshotLevel,
            image: .init(name: Self.isoName, bytes: 1_446_789_120, sha256: String(repeating: "4", count: 64)),
            archive: .init(name: Self.archiveName, bytes: 163_919_297, sha256: String(repeating: "a", count: 64)),
            kernelDigest: "d63775f2e341116a", ramBytes: 1 << 30, screen: [1024, 768],
            commandLine: "init_on_free=1", madeAt: Self.moment, guestClock: Self.moment,
            instructions: 3, snapshotBytes: 4, packedBytes: 5, commit: nil)
        let built = ReadyDesktop.Index.Entry(
            sheet: sheet, image: URL(string: Self.isoURL)!, archive: URL(string: Self.archiveURL)!)
        let data = try ReadyDesktop.Index(desktops: [built]).encoded()
        XCTAssertEqual(try ReadyDesktop.Index.decode(data).desktops, [built])
        let desktop = try XCTUnwrap(ReadyDesktop.parse(String(decoding: data, as: UTF8.self)).first)
        XCTAssertEqual(desktop.archive.size, 163_919_297)
        XCTAssertEqual(desktop.image.size, 1_446_789_120)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"madeAt\" : \"2026-11-14T00:00:00Z\""))
    }

    /// **Les entrées hostiles ne sont pas proposées**, chacune seule : un
    /// hôte inattendu, une image servie par GitHub, une archive d'un autre
    /// dépôt, du HTTP, un `../` dans un nom ou dans le chemin, un nom qui
    /// n'est pas celui de l'adresse, une somme mal formée, une archive qui
    /// n'est pas une machine, un niveau trop haut, une empreinte de noyau
    /// qui n'en est pas une, une mémoire que l'application ne règle pas.
    func testHostileEntriesAreNotOffered() throws {
        XCTAssertEqual(ReadyDesktop.parse(try json([entry()])).count, 1, "l'entrée propre passe")
        let base = entry()
        var cases: [(String, ReadyDesktop.Index.Entry)] = []
        func change(_ why: String, _ edit: (inout ReadyDesktop.Index.Entry) -> Void) {
            var mutated = base
            edit(&mutated)
            cases.append((why, mutated))
        }
        change("hôte inattendu") {
            $0.archive.url = "https://evil.example.com/maxlestage/wisq/releases/download/bureaux-1/\(Self.archiveName)"
        }
        change("l'image sur GitHub") { $0.image.url = Self.archiveURL.replacingOccurrences(
            of: Self.archiveName, with: Self.isoName) }
        change("un autre dépôt") {
            $0.archive.url = "https://github.com/quelquun/wisq/releases/download/bureaux-1/\(Self.archiveName)"
        }
        change("hors des releases") {
            $0.archive.url = "https://github.com/maxlestage/wisq/raw/master/\(Self.archiveName)"
        }
        change("HTTP") { $0.image.url = Self.isoURL.replacingOccurrences(of: "https:", with: "http:") }
        change("un port") {
            $0.image.url = Self.isoURL.replacingOccurrences(of: ".org/", with: ".org:8443/")
        }
        change("une requête") { $0.image.url = Self.isoURL + "?x=1" }
        change("../ dans le nom") {
            $0.archive.name = "../\(Self.archiveName)"
            $0.archive.url = "https://github.com/maxlestage/wisq/releases/download/bureaux-1/../\(Self.archiveName)"
        }
        change("../ dans le chemin") {
            $0.archive.url = "https://github.com/maxlestage/wisq/releases/download/../../x/\(Self.archiveName)"
        }
        change("../ dans le chemin de l'image") {
            $0.image.url = "https://repo-default.voidlinux.org/live/../../\(Self.isoName)"
        }
        change("nom caché") {
            $0.archive.name = ".wisqmachine"
            $0.archive.url = "https://github.com/maxlestage/wisq/releases/download/bureaux-1/.wisqmachine"
        }
        change("nom qui n'est pas celui de l'adresse") { $0.image.name = "void-live-x86_64-20990101-xfce.iso" }
        change("somme courte") { $0.archive.sha256 = "abc" }
        change("somme pas hexadécimale") { $0.image.sha256 = String(repeating: "z", count: 64) }
        change("taille nulle") { $0.archive.bytes = 0 }
        change("archive qui n'est pas une machine") {
            $0.archive.name = "bureau.tar"
            $0.archive.url = "https://github.com/maxlestage/wisq/releases/download/bureaux-1/bureau.tar"
        }
        change("image qui est une machine") {
            $0.image.name = "x.wisqmachine"
            $0.image.url = "https://repo-default.voidlinux.org/live/20250202/x.wisqmachine"
        }
        change("niveau trop haut") { $0.level = X86Machine.snapshotLevel + 1 }
        change("niveau nul") { $0.level = 0 }
        change("empreinte vide") { $0.kernelDigest = "" }
        change("empreinte trop longue") { $0.kernelDigest = String(repeating: "a", count: 17) }
        change("empreinte pas hexadécimale") { $0.kernelDigest = "d63775f2e341116g" }
        change("mémoire que l'application ne règle pas") { $0.ramBytes = (1 << 30) + 1 }
        change("titre vide") { $0.title = "  " }
        change("titre sur deux lignes") { $0.title = "Void\nXfce" }
        change("titre de 81 caractères") { $0.title = String(repeating: "x", count: 81) }
        change("identifiants dans l'adresse de l'archive") {
            $0.archive.url = Self.archiveURL.replacingOccurrences(of: "https://", with: "https://moi:secret@")
        }
        change("un nom d'utilisateur dans l'adresse de l'image") {
            $0.image.url = Self.isoURL.replacingOccurrences(of: "https://", with: "https://moi@")
        }
        change("un fragment") { $0.image.url = Self.isoURL + "#x" }
        change("un fragment vide") { $0.archive.url = Self.archiveURL + "#" }
        change("taille énorme de l'image") { $0.image.bytes = Int.max / 2 + 1 }
        change("taille énorme de l'archive") { $0.archive.bytes = Int.max }
        change("taille au-delà du plafond") { $0.archive.bytes = ReadyDesktop.largestFile + 1 }
        change("empreinte en chiffres pleine chasse") { $0.kernelDigest = "\u{FF44}63775f2e341116a" }
        change("somme en chiffres pleine chasse") {
            $0.image.sha256 = "\u{FF10}" + String(SHA256Stream.hex(self.iso).dropFirst())
        }
        XCTAssertEqual(cases.count, 35)
        for (why, mutated) in cases {
            XCTAssertEqual(ReadyDesktop.parse(try json([mutated])), [], why)
            // Et une entrée fautive n'emporte pas l'entrée propre d'à côté.
            var other = base
            other.title = "Autre bureau"
            XCTAssertEqual(ReadyDesktop.parse(try json([mutated, other])).map(\.title), ["Autre bureau"], why)
        }
    }

    /// **Les bords qui passent** : un titre de 80 caractères, des tailles au
    /// plafond. Et la feuille dit ce qu'il reste à télécharger sans tomber :
    /// la somme des deux tailles débordait à `Int.max / 2 + 1` chacune.
    func testTheEdgesThatPassAndTheSheetDoesNotOverflow() throws {
        var edge = entry()
        edge.title = String(repeating: "x", count: 80)
        edge.image.bytes = ReadyDesktop.largestFile
        edge.archive.bytes = ReadyDesktop.largestFile
        let desktop = try desktop(edge)
        XCTAssertEqual(desktop.title.count, 80)
        XCTAssertEqual(desktop.sizePhrase(imagePresent: false),
                       "À télécharger : 128,0 Gio, soit l'image (64,0 Gio) et le bureau (64,0 Gio).")
        XCTAssertEqual(ReadyDesktop.largestFile, 64 << 30)
    }

    /// **Les chiffres pleine chasse ne sont pas des chiffres** : `isHexDigit`
    /// les accepte, une somme ou une empreinte écrite ainsi passait, et
    /// n'était refusée qu'après le téléchargement entier. La garde vaut pour
    /// toutes les listes (`ImageDownload.isHexDigest`).
    func testFullWidthDigitsAreNotDigits() {
        let ascii = String(repeating: "a", count: 63) + "0"
        XCTAssertTrue(ImageDownload.isHexDigest(ascii))
        XCTAssertFalse(ImageDownload.isHexDigest(String(repeating: "a", count: 63) + "\u{FF10}"))
        XCTAssertFalse(ImageDownload.isHexDigest(String(repeating: "\u{FF41}", count: 64)))
        XCTAssertEqual(ImageDownload.bsdChecksum("SHA256 (x.iso) = \(ascii)", for: "x.iso"), ascii)
        XCTAssertNil(ImageDownload.bsdChecksum("SHA256 (x.iso) = \(String(ascii.dropLast()))\u{FF10}", for: "x.iso"))
        XCTAssertFalse(ImageDownload.isASCIIHexDigit("\u{FF44}"))
        XCTAssertTrue(ImageDownload.isASCIIHexDigit("D"))
    }

    /// **Une adresse, un fichier.** L'archive du niveau 2 attachée à la même
    /// release sous le même nom remplaçait celle du niveau 1, et l'entrée du
    /// niveau 1, gardée, promettait l'ancienne somme : l'application d'avant
    /// téléchargeait l'archive neuve, la trouvait fausse, l'effaçait, à
    /// chaque essai. La fabrique refuse d'écrire un tel index ; l'application
    /// qui en lirait un ne propose aucune des deux ; et le niveau dans le nom
    /// des fichiers (`outputStem`) évite le cas avec les réglages par défaut.
    func testTwoFilesAtOneAddressAreRefused() throws {
        let old = ReadyDesktop.Index(desktops: [entry(level: 1)])
        var other = archiveBytes
        other[0] ^= 0xFF
        var second = entry(level: 2, archive: other)
        second.kernelDigest = "abc"
        XCTAssertEqual(second.archive.url, old.desktops[0].archive.url)
        let fresh = ReadyDesktop.Index(desktops: [second])
        XCTAssertThrowsError(try ReadyDesktop.Index.publishable(fresh, keeping: old)) {
            XCTAssertEqual($0 as? ReadyDesktop.Index.Fault, .clash(url: Self.archiveURL))
        }
        let both = fresh.merged(keeping: old)
        XCTAssertEqual(both.clashes, [Self.archiveURL])
        let text = String(decoding: try both.encoded(), as: UTF8.self)
        XCTAssertEqual(ReadyDesktop.parse(text, supportedLevel: 1), [], "le niveau 1 ne télécharge pas en boucle")
        XCTAssertEqual(ReadyDesktop.parse(text, supportedLevel: 2), [])
        // Une autre taille à la même adresse, la même somme : deux fichiers
        // aussi.
        var longer = entry(level: 2)
        longer.archive.bytes += 1
        XCTAssertEqual(ReadyDesktop.Index(desktops: [longer]).merged(keeping: old).clashes, [Self.archiveURL])

        // Le niveau dans le nom : deux archives, deux adresses ; la même ISO,
        // à la même somme, sert les deux niveaux.
        let stem2 = ReadyDesktopBuild.outputStem(image: Self.isoName, level: 2)
        XCTAssertEqual(ReadyDesktopBuild.outputStem(image: Self.isoName, level: 1) + ".wisqmachine", Self.archiveName)
        XCTAssertEqual(stem2, "void-live-x86_64-20250202-xfce-pret-niveau2")
        second.archive.name = stem2 + ".wisqmachine"
        second.archive.url = "https://github.com/maxlestage/wisq/releases/download/bureaux-1/\(second.archive.name)"
        let published = try ReadyDesktop.Index.publishable(ReadyDesktop.Index(desktops: [second]), keeping: old)
        XCTAssertEqual(published.desktops.map(\.level), [2, 1])
        XCTAssertEqual(published.clashes, [])
        let written = String(decoding: try published.encoded(), as: UTF8.self)
        XCTAssertEqual(ReadyDesktop.parse(written, supportedLevel: 1).map(\.archive.file), [Self.archiveName])
        XCTAssertEqual(ReadyDesktop.parse(written, supportedLevel: 2).map(\.archive.file), [second.archive.name])

        // Et une entrée que l'application écarterait arrête tout, avant.
        var hostile = entry()
        hostile.archive.url = "https://evil.example.com/\(Self.archiveName)"
        XCTAssertThrowsError(try ReadyDesktop.Index.publishable(ReadyDesktop.Index(desktops: [hostile]))) {
            XCTAssertEqual($0 as? ReadyDesktop.Index.Fault,
                           .refused(title: "Void Xfce (prêt)", url: hostile.archive.url))
        }
    }

    /// **Un index que l'application écarterait n'est pas écrit** : la
    /// fabrique demande à l'index les entrées refusées, jugées chacune à son
    /// niveau — un bureau d'un niveau neuf n'est pas une faute.
    func testTheIndexNamesTheEntriesTheApplicationWouldRefuse() throws {
        var hostile = entry()
        hostile.title = "Ailleurs"
        hostile.archive.url = "https://evil.example.com/\(Self.archiveName)"
        var newer = entry(level: X86Machine.snapshotLevel + 1)
        newer.title = "Plus neuf"
        var nothing = entry(level: 0)
        nothing.title = "Niveau nul"
        let index = ReadyDesktop.Index(desktops: [entry(), hostile, newer, nothing])
        XCTAssertEqual(index.refused.map(\.title), ["Ailleurs", "Niveau nul"])
    }

    /// Un index illisible, d'un autre format, ou dont une entrée n'a pas la
    /// forme d'une entrée, ne propose rien de faux.
    func testAnIndexThatIsNotOneOffersNothing() throws {
        XCTAssertEqual(ReadyDesktop.parse(""), [])
        XCTAssertEqual(ReadyDesktop.parse("<html>Not Found</html>"), [])
        XCTAssertEqual(ReadyDesktop.parse("[]"), [])
        let good = try json([entry()])
        XCTAssertEqual(ReadyDesktop.parse(good.replacingOccurrences(of: "\"format\" : 1", with: "\"format\" : 2")), [])
        XCTAssertEqual(ReadyDesktop.parse("{\"format\": 1, \"desktops\": [1, \"x\", {\"title\": \"t\"}]}"), [])
    }

    /// **Un bureau par titre, du plus haut niveau que cette version sait
    /// reprendre.** Un index qui porte le bureau du niveau 2 à côté de celui
    /// du niveau 1 donne le 1 à une application du niveau 1, le 2 à une du
    /// niveau 2 ; et l'index neuf garde l'ancien (`merged`).
    func testOneDesktopPerTitleTheHighestLevelItCanResume() throws {
        let old = ReadyDesktop.Index(desktops: [entry(level: 1)])
        var second = entry(level: 2)
        second.kernelDigest = "abc"
        let index = ReadyDesktop.Index(desktops: [second]).merged(keeping: old)
        XCTAssertEqual(index.desktops.map(\.level), [2, 1])
        let text = String(decoding: try index.encoded(), as: UTF8.self)
        XCTAssertEqual(ReadyDesktop.parse(text, supportedLevel: 1).map(\.level), [1])
        XCTAssertEqual(ReadyDesktop.parse(text, supportedLevel: 2).map(\.level), [2])
        XCTAssertEqual(ReadyDesktop.parse(text, supportedLevel: 2).map(\.kernelDigest), ["abc"])
        // Le même titre et le même niveau : le neuf remplace l'ancien.
        var redone = entry(level: 1)
        redone.madeAt = Self.moment.addingTimeInterval(86_400)
        XCTAssertEqual(ReadyDesktop.Index(desktops: [redone]).merged(keeping: old).desktops, [redone])
        // Deux entrées du même niveau dans un index : la plus récente.
        let both = try json([entry(level: 1), redone])
        XCTAssertEqual(ReadyDesktop.parse(both).map(\.madeAt), [redone.madeAt])
    }

    // MARK: - L'index, sur le réseau

    /// **L'index des bureaux absent ne cache rien et ne dit rien** : la
    /// release n'existe pas encore, GitHub répond 404 ; les images des
    /// distributions sont là, sans échec à montrer. Et dans l'autre sens :
    /// aucune distribution ne répond, les bureaux restent proposés.
    func testAnAbsentIndexHidesNothingAndSaysNothing() async throws {
        let onlyAlpine = Router([ImageDownload.alpineIndex: Server(Array(ImageDownloadTests.index.utf8))])
        let downloader = ImageDownloader(fetcher: onlyAlpine, partsFolder: downloads)
        let desktops = await downloader.readyDesktops()
        XCTAssertEqual(desktops, [])
        let catalog = await downloader.catalog()
        XCTAssertEqual(catalog.desktops, [])
        XCTAssertEqual(catalog.releases.map(\.flavor), ["alpine-virt", "alpine-standard"])
        XCTAssertNil(catalog.failure, "un index des bureaux absent n'est pas une panne à dire")

        let index = Server(Array(try json([entry()]).utf8))
        let onlyDesktops = Router([ReadyDesktop.index: index])
        let alone = await ImageDownloader(fetcher: onlyDesktops, partsFolder: downloads).catalog()
        XCTAssertEqual(alone.desktops.map(\.title), ["Void Xfce (prêt)"])
        XCTAssertEqual(alone.releases, [])
        XCTAssertNotNil(alone.failure, "aucune distribution n'a répondu : cela, on le dit")
        XCTAssertEqual(index.ranges, [nil], "l'index est lu par le même lecteur, sans Range")
    }

    // MARK: - Les deux téléchargements

    /// Le téléchargement vérifié de la feuille, sur le serveur scripté : la
    /// destination dit le dossier.
    private func download(with downloader: ImageDownloader)
        -> @Sendable (ImageDownload.Release, ImageDownload.Destination, @escaping @Sendable (Int, Int) -> Void)
        async throws -> URL {
        let library = self.library, downloads = self.downloads
        return { release, destination, progress in
            try await downloader.download(release, into: destination == .library ? library : downloads,
                                          progress: progress)
        }
    }

    private func router(image: Server, archive: Server) -> Router {
        Router([URL(string: Self.isoURL)!: image, URL(string: Self.archiveURL)!: archive])
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// **L'image dans la bibliothèque, l'archive hors d'elle**, chacune
    /// vérifiée ; un seul progrès sur les deux, qui ne revient jamais en
    /// arrière ; et un second essai ne redemande rien.
    func testBothFilesArriveAndTheArchiveStaysOutOfTheLibrary() async throws {
        let desktop = try desktop(entry())
        let image = Server(iso), archive = Server(archiveBytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        let seen = Steps()
        let got = try await desktop.fetch(library: library, downloads: downloads,
                                          download: download(with: downloader)) { seen.add($0) }
        XCTAssertEqual(got.image, library.appendingPathComponent(Self.isoName))
        XCTAssertEqual(got.archive, downloads.appendingPathComponent(Self.archiveName))
        XCTAssertEqual(try Data(contentsOf: got.image), Data(iso))
        XCTAssertEqual(try Data(contentsOf: got.archive), Data(archiveBytes))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), [Self.isoName],
                       "la bibliothèque ne voit que l'image")
        let all = seen.all
        XCTAssertEqual(all.first?.step, .image)
        XCTAssertEqual(all.last, .init(step: .archive, number: 2, steps: 2,
                                       have: iso.count + archiveBytes.count, total: iso.count + archiveBytes.count))
        XCTAssertEqual(all.map(\.have), all.map(\.have).sorted(), "le progrès ne revient pas en arrière")
        XCTAssertTrue(all.allSatisfy { $0.total == iso.count + archiveBytes.count })

        _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader))
        XCTAssertEqual(image.ranges, [nil], "l'image déjà là n'est pas redemandée")
        XCTAssertEqual(archive.ranges, [nil], "l'archive déjà là, à sa somme, non plus")
    }

    /// **L'image déjà là** (téléchargée avant, par la liste des
    /// distributions) : une seule étape, l'archive.
    func testAnImageAlreadyThereIsNotFetchedAgain() async throws {
        try Data(iso).write(to: library.appendingPathComponent(Self.isoName))
        let desktop = try desktop(entry())
        XCTAssertTrue(desktop.imagePresent(in: library))
        let image = Server(iso), archive = Server(archiveBytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        let seen = Steps()
        _ = try await desktop.fetch(library: library, downloads: downloads,
                                    download: download(with: downloader)) { seen.add($0) }
        XCTAssertEqual(image.ranges, [])
        XCTAssertEqual(seen.all.last, .init(step: .archive, number: 1, steps: 1,
                                            have: archiveBytes.count, total: archiveBytes.count))
    }

    /// **Coupée au milieu de l'archive** : l'image reste, le `.part` de
    /// l'archive aussi ; le second essai ne redemande pas l'image, et reprend
    /// l'archive à son dernier octet.
    func testACutArchiveResumesWithoutFetchingTheImageAgain() async throws {
        let desktop = try desktop(entry())
        let image = Server(iso), archive = Server(archiveBytes)
        archive.cutAfter = 20_000
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        do {
            _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader))
            XCTFail("la coupure doit remonter")
        } catch is Server.Cut {}
        XCTAssertTrue(exists(library.appendingPathComponent(Self.isoName)), "l'image vérifiée est gardée")
        XCTAssertFalse(exists(downloads.appendingPathComponent(Self.archiveName)))
        let part = ImageDownload.partURL(for: downloads.appendingPathComponent(Self.archiveName))
        XCTAssertEqual(ReadyDesktop.size(of: part), 20_000)

        let seen = Steps()
        let got = try await desktop.fetch(library: library, downloads: downloads,
                                          download: download(with: downloader)) { seen.add($0) }
        XCTAssertEqual(image.ranges, [nil], "l'image n'est demandée qu'une fois")
        XCTAssertEqual(archive.ranges, [nil, "bytes=20000-"])
        XCTAssertEqual(seen.all.first, .init(step: .archive, number: 1, steps: 1, have: 20_000,
                                             total: archiveBytes.count), "le progrès part de ce qui est là")
        XCTAssertEqual(try Data(contentsOf: got.archive), Data(archiveBytes))
    }

    /// **Une archive à la somme fausse est effacée**, et l'image reste : le
    /// prochain essai ne retélécharge que l'archive, depuis le début.
    func testAnArchiveWithAWrongSumIsDiscarded() async throws {
        let desktop = try desktop(entry())
        let image = Server(iso), archive = Server(archiveBytes)
        archive.corruptAt = 33_333
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        do {
            _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader))
            XCTFail("la somme fausse doit remonter")
        } catch let failure as ImageDownload.Failure {
            guard case .checksumMismatch = failure else { return XCTFail("\(failure)") }
        }
        XCTAssertFalse(exists(downloads.appendingPathComponent(Self.archiveName)))
        XCTAssertFalse(exists(ImageDownload.partURL(for: downloads.appendingPathComponent(Self.archiveName))))
        XCTAssertTrue(exists(library.appendingPathComponent(Self.isoName)))

        archive.corruptAt = nil
        _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader))
        XCTAssertEqual(archive.ranges, [nil, nil], "reparti de zéro")
        XCTAssertEqual(image.ranges, [nil])
    }

    /// **Une archive de la bonne taille mais pas de la bonne somme**, laissée
    /// dans les téléchargements, n'est pas prise pour elle : elle est
    /// redemandée, et vérifiée.
    func testAnArchiveOfTheRightSizeButNotTheRightSumIsFetchedAgain() async throws {
        try Data(iso).write(to: library.appendingPathComponent(Self.isoName))
        var wrong = archiveBytes
        wrong[0] ^= 0xFF
        try Data(wrong).write(to: downloads.appendingPathComponent(Self.archiveName))
        let desktop = try desktop(entry())
        XCTAssertFalse(desktop.archivePresent(in: downloads))
        let image = Server(iso), archive = Server(archiveBytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        let got = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader))
        XCTAssertEqual(archive.ranges, [nil])
        XCTAssertEqual(try Data(contentsOf: got.archive), Data(archiveBytes))
    }

    /// **Un `416`** : l'index annonce une archive plus grande que celle que
    /// le serveur a (republiée sans que l'index suive). Le premier essai
    /// s'arrête court et garde ce qu'il a ; le second demande la suite, le
    /// serveur répond `416` avec sa vraie taille — rien de plus à recevoir —,
    /// et la taille fausse est refusée, le `.part` effacé, rien de rangé.
    func testA416OnAnArchiveTheIndexMisdescribesIsRefused() async throws {
        let announced = archiveBytes.count + 10
        let desktop = try desktop(entry(archiveSize: announced))
        let image = Server(iso), archive = Server(archiveBytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        do {
            _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader))
            XCTFail("l'archive courte doit remonter")
        } catch {
            XCTAssertEqual(error as? ImageDownloader.Failure,
                           .interrupted(have: archiveBytes.count, of: announced))
        }
        do {
            _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader))
            XCTFail("le 416 doit remonter")
        } catch {
            XCTAssertEqual(error as? ImageDownload.Failure, .wrongSize(expected: announced, got: archiveBytes.count))
        }
        XCTAssertEqual(archive.ranges, [nil, "bytes=\(archiveBytes.count)-"])
        XCTAssertFalse(exists(ImageDownload.partURL(for: downloads.appendingPathComponent(Self.archiveName))))
        XCTAssertFalse(exists(downloads.appendingPathComponent(Self.archiveName)))
    }

    /// **L'image qui remplace un fichier du même nom le dit tout de suite**,
    /// avant l'archive. Le dire après les deux le perdait quand l'archive
    /// tombait : l'essai suivant trouvait l'image à sa taille, et les couches
    /// et sessions posées sur l'ancien fichier restaient sur le nouveau
    /// (`KernelLibrary.replaced`).
    func testAReplacedImageIsSaidBeforeTheArchiveCanFail() async throws {
        try Data("une autre image".utf8).write(to: library.appendingPathComponent(Self.isoName))
        let desktop = try desktop(entry())
        let image = Server(iso), archive = Server(archiveBytes)
        archive.cutAfter = 20_000
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        let replaced = Names()
        do {
            _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader),
                                        replacedImage: { replaced.add($0) })
            XCTFail("la coupure doit remonter")
        } catch is Server.Cut {}
        XCTAssertEqual(replaced.all, [Self.isoName], "dit avant que l'archive ne tombe")
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent(Self.isoName)), Data(iso))

        _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader),
                                    replacedImage: { replaced.add($0) })
        XCTAssertEqual(replaced.all, [Self.isoName], "une fois, pas à chaque essai")

        // Rien à remplacer : une bibliothèque sans ce fichier ne dit rien.
        try FileManager.default.removeItem(at: library.appendingPathComponent(Self.isoName))
        try FileManager.default.removeItem(at: downloads.appendingPathComponent(Self.archiveName))
        let fresh = Names()
        _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader),
                                    replacedImage: { fresh.add($0) })
        XCTAssertEqual(fresh.all, [])
    }

    /// Les noms reçus, dans l'ordre.
    final class Names: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ name: String) { lock.withLock { values.append(name) } }
        var all: [String] { lock.withLock { values } }
    }

    /// Les étapes reçues, dans l'ordre.
    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ReadyDesktop.Progress] = []
        func add(_ step: ReadyDesktop.Progress) { lock.withLock { values.append(step) } }
        var all: [ReadyDesktop.Progress] { lock.withLock { values } }
    }

    // MARK: - L'installation

    /// Une vraie archive de bureau prêt, assemblée comme le fait
    /// `wisq-fabrique` : la machine de l'application, la session nommée par
    /// l'empreinte de `kernel`, pour l'image `image`.
    private func makeArchive(kernel: Data, image: String = isoName) throws -> URL {
        let work = folder.appendingPathComponent("atelier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let (installed, writes) = try ReadyDesktopBuild.install(image: image, name: "Void Xfce (prêt)", in: work)
        let machine = try ReadyDesktopBuild.machine(
            ramSize: ReadyDesktopBuildTests.ram, frozenAt: Self.moment) { _ in }
        // Le disque branché, comme à la fabrique : l'archive porte alors sa
        // couche et sa carte à côté de la session, nommées par le disque.
        let disk = work.appendingPathComponent(image)
        try Data(repeating: 0x5A, count: 64 << 10).write(to: disk)
        try machine.attach(diskFileAt: disk, writes: writes)
        machine.flushDisk()
        let snapshot = try ReadyDesktopBuildTests.snapshot(of: machine)
        let archive = downloads.appendingPathComponent(Self.archiveName)
        try ReadyDesktopBuild.assemble(installed, snapshot: snapshot, kernel: kernel, in: work, to: archive)
        return archive
    }

    private let kernel = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 29) })

    private func desktop(forKernel kernel: Data) throws -> ReadyDesktop {
        try desktop(entry(digest: ReadyDesktopBuild.kernelDigest(kernel)))
    }

    private func install(_ desktop: ReadyDesktop, archive: URL, digest: String?,
                         library: [String] = [isoName]) throws -> InstalledMachine {
        try desktop.install(archive: archive, imageKernelDigest: digest, library: library, in: storage,
                            createOwnDisk: { _, _ in throw MachineArchive.Refusal.damaged })
    }

    /// **Le bureau s'installe sous son noyau** : la machine importée trouve
    /// sa session sous l'empreinte du noyau de l'image, et l'archive, lue,
    /// est effacée.
    func testTheDesktopInstallsAndFindsItsSession() throws {
        let archive = try makeArchive(kernel: kernel)
        let desktop = try desktop(forKernel: kernel)
        let machine = try install(desktop, archive: archive, digest: ReadyDesktopBuild.kernelDigest(kernel))
        XCTAssertEqual(machine.name, "Void Xfce (prêt)")
        XCTAssertEqual(machine.image, Self.isoName)
        XCTAssertEqual(InstalledMachines.list(in: storage).map(\.id), [machine.id])
        let found = SavedSession.find(
            kernel: SuspendedMachine.identity(of: kernel, named: machine.keys.settings), in: storage, core: .x86_64)
        XCTAssertNotNil(found.snapshot, "la session n'est pas sous l'empreinte du noyau de l'image")
        XCTAssertFalse(exists(archive), "l'archive lue ne garde pas sa place")
    }

    /// **Une image au noyau différent est refusée avant l'import** : la
    /// session ne serait jamais trouvée, et la machine démarrerait à froid
    /// sans le dire. Rien n'est installé ; une image illisible (`nil`) non
    /// plus.
    func testAnImageWithAnotherKernelIsRefused() throws {
        let desktop = try desktop(forKernel: kernel)
        for found in ["0123456789abcdef", nil] as [String?] {
            let archive = try makeArchive(kernel: kernel)
            XCTAssertThrowsError(try install(desktop, archive: archive, digest: found)) {
                XCTAssertEqual($0 as? ReadyDesktop.Refusal,
                               .wrongKernel(expected: ReadyDesktopBuild.kernelDigest(kernel), found: found))
            }
            XCTAssertEqual(InstalledMachines.list(in: storage), [])
            XCTAssertFalse(exists(archive))
        }
    }

    /// **Une archive faite pour une autre image est refusée**, même quand
    /// cette autre image est aussi dans la bibliothèque : l'import la
    /// brancherait sur elle, pas sur l'image dont le noyau a été vérifié.
    func testAnArchiveForAnotherImageIsRefused() throws {
        let other = "void-live-x86_64-20240314-xfce.iso"
        let archive = try makeArchive(kernel: kernel, image: other)
        let desktop = try desktop(forKernel: kernel)
        XCTAssertThrowsError(try install(desktop, archive: archive, digest: ReadyDesktopBuild.kernelDigest(kernel),
                                         library: [Self.isoName, other])) {
            XCTAssertEqual($0 as? ReadyDesktop.Refusal, .archiveForAnotherImage(other))
        }
        XCTAssertEqual(InstalledMachines.list(in: storage), [])
    }

    /// **Une archive sans session pour ce noyau est refusée** : l'index et
    /// l'image s'accordent, mais l'archive porte le bureau d'un autre noyau.
    func testAnArchiveWithoutASessionForTheKernelIsRefused() throws {
        var otherKernel = kernel
        otherKernel[0] ^= 1
        let archive = try makeArchive(kernel: otherKernel)
        let desktop = try desktop(forKernel: kernel)
        XCTAssertThrowsError(try install(desktop, archive: archive, digest: ReadyDesktopBuild.kernelDigest(kernel))) {
            XCTAssertEqual($0 as? ReadyDesktop.Refusal, .noSession(ReadyDesktopBuild.kernelDigest(kernel)))
        }
        XCTAssertEqual(InstalledMachines.list(in: storage), [])
    }

    /// L'image retirée de la bibliothèque entre le téléchargement et
    /// l'installation : refusée en la nommant.
    func testAMissingImageIsNamed() throws {
        let archive = try makeArchive(kernel: kernel)
        let desktop = try desktop(forKernel: kernel)
        XCTAssertThrowsError(try install(desktop, archive: archive, digest: ReadyDesktopBuild.kernelDigest(kernel),
                                         library: [])) {
            XCTAssertEqual($0 as? ReadyDesktop.Refusal, .missingImage(Self.isoName))
        }
        XCTAssertEqual(InstalledMachines.list(in: storage), [])
    }

    /// Ce que l'archive porte se lit sans rien installer.
    func testTheContentsOfAnArchiveAreReadWithoutInstalling() throws {
        let archive = try makeArchive(kernel: kernel)
        let contents = try MachineArchive.contents(of: archive)
        XCTAssertEqual(contents.image, Self.isoName)
        XCTAssertEqual(contents.sessions, [ReadyDesktopBuild.kernelDigest(kernel)])
        XCTAssertEqual(InstalledMachines.list(in: storage), [])
        let notOne = folder.appendingPathComponent("rien")
        try Data("rien".utf8).write(to: notOne)
        XCTAssertThrowsError(try MachineArchive.contents(of: notOne)) {
            XCTAssertEqual($0 as? MachineArchive.Refusal, .notAnArchive)
        }
    }

    // MARK: - Ce que la feuille en dit

    /// Les phrases de la feuille : la date en français, ce qu'il reste à
    /// télécharger, la mémoire, le progrès.
    func testWhatTheSheetSays() throws {
        let desktop = try desktop(entry())
        XCTAssertEqual(desktop.madePhrase, "Démarré par wisq le 14 novembre 2026, puis mis en pause : "
                        + "prêt en moins d'une minute, au lieu d'une demi-heure de démarrage.")
        XCTAssertEqual(ReadyDesktop.frenchDate(Date(timeIntervalSince1970: 1_767_225_600)), "1er janvier 2026")
        XCTAssertEqual(desktop.sizePhrase(imagePresent: false),
                       "À télécharger : 107 Kio, soit l'image (59 Kio) et le bureau (49 Kio).")
        XCTAssertEqual(desktop.sizePhrase(imagePresent: true),
                       "À télécharger : 49 Kio (le bureau). L'image est déjà dans la bibliothèque.")
        XCTAssertTrue(desktop.fits(ceiling: 1 << 30))
        XCTAssertFalse(desktop.fits(ceiling: (1 << 30) - 1))
        XCTAssertEqual(desktop.memoryPhrase(ceiling: 2 << 30), "Il lui faut 1 Gio de mémoire.")
        XCTAssertEqual(desktop.memoryPhrase(ceiling: 768 << 20),
                       "Il lui faut 1 Gio de mémoire ; ce téléphone peut en donner 768 Mo.")
        XCTAssertEqual(ReadyDesktop.Progress(step: .image, number: 1, steps: 2, have: 300 << 20,
                                             total: 1536 << 20).phrase,
                       "Étape 1 sur 2 : l'image — 300,0 Mio sur 1,5 Gio")
    }

    // MARK: - En arrière-plan

    /// **La destination voyage avec la tâche** : une archive finie pendant
    /// que l'application dormait doit atterrir dans les téléchargements, pas
    /// dans la bibliothèque. Vers la bibliothèque, l'étiquette reste celle
    /// d'avant : une tâche d'une version précédente est reconnue.
    func testABackgroundJobCarriesItsDestination() throws {
        let desktop = try desktop(entry())
        let toLibrary = ImageDownload.BackgroundJob(release: desktop.image, destination: .library)
        XCTAssertEqual(toLibrary.tag, desktop.image.backgroundTag)
        XCTAssertEqual(ImageDownload.BackgroundJob(tag: toLibrary.tag), toLibrary)
        let toDownloads = ImageDownload.BackgroundJob(release: desktop.archive, destination: .downloads)
        XCTAssertNotEqual(toDownloads.tag, desktop.archive.backgroundTag)
        XCTAssertEqual(ImageDownload.BackgroundJob(tag: toDownloads.tag), toDownloads)
        XCTAssertNil(ImageDownload.Release(backgroundTag: toDownloads.tag),
                     "une version d'avant ne prend pas une archive pour une image")
        XCTAssertNil(ImageDownload.BackgroundJob(tag: "une tâche d'ailleurs"))
    }

    /// **Deux tâches sur le même `.part` se reconnaissent** : l'ISO de Void
    /// lancée depuis la liste des distributions, puis demandée par « Bureaux
    /// prêts », se décrit autrement (distribution, saveur, index, adresse) ;
    /// c'est le même fichier à la même somme, et on attend celle qui court.
    /// Le même nom pour un autre fichier attendu est un conflit ; un autre
    /// nom, une autre affaire.
    func testTwoBackgroundJobsForOnePartRecogniseEachOther() throws {
        let desktop = try desktop(entry())
        let fromList = ImageDownload.voidRelease(file: Self.isoName, version: "2025.02.02",
                                                 sha256: SHA256Stream.hex(iso).uppercased(), size: iso.count)
        XCTAssertNotEqual(fromList, desktop.image, "deux descriptions du même fichier")
        let listJob = ImageDownload.BackgroundJob(release: fromList, destination: .library)
        let readyJob = ImageDownload.BackgroundJob(release: desktop.image, destination: .library)
        XCTAssertEqual(readyJob.overlap(with: listJob), .same)
        XCTAssertEqual(listJob.overlap(with: readyJob), .same)
        XCTAssertEqual(readyJob.overlap(with: readyJob), .same)

        let otherSum = ImageDownload.voidRelease(file: Self.isoName, version: "2025.02.02",
                                                 sha256: String(repeating: "0", count: 64), size: iso.count)
        XCTAssertEqual(readyJob.overlap(with: .init(release: otherSum, destination: .library)), .conflicting)
        let otherSize = ImageDownload.voidRelease(file: Self.isoName, version: "2025.02.02",
                                                  sha256: SHA256Stream.hex(iso), size: iso.count + 1)
        XCTAssertEqual(readyJob.overlap(with: .init(release: otherSize, destination: .library)), .conflicting)
        XCTAssertEqual(readyJob.overlap(with: .init(release: fromList, destination: .downloads)), .conflicting)
        let archiveJob = ImageDownload.BackgroundJob(release: desktop.archive, destination: .downloads)
        XCTAssertEqual(readyJob.overlap(with: archiveJob), .unrelated)
        XCTAssertEqual(archiveJob.overlap(with: readyJob), .unrelated)
    }

    /// **La même tâche a toujours la même étiquette.** Les clés du JSON
    /// sortaient dans un ordre tiré au sort d'un encodage à l'autre : la
    /// tâche déjà en cours pour un fichier, cherchée par son étiquette, ne se
    /// retrouvait pas, et un second appui en lançait une autre.
    func testABackgroundTagIsTheSameEveryTime() throws {
        let desktop = try desktop(entry())
        let tags = Set((0..<20).map { _ in desktop.image.backgroundTag })
        XCTAssertEqual(tags.count, 1, "\(tags)")
        let jobs = Set((0..<20).map { _ in
            ImageDownload.BackgroundJob(release: desktop.archive, destination: .downloads).tag
        })
        XCTAssertEqual(jobs.count, 1, "\(jobs)")
    }

    /// **Recousue vers les téléchargements** : ce qu'une session
    /// d'arrière-plan rend pour l'archive — ici un `416`, le `.part` déjà
    /// entier — finit dans le dossier de sa destination, vérifié.
    func testAnArchiveAdoptedFromTheBackgroundLandsInDownloads() throws {
        let desktop = try desktop(entry())
        let downloader = ImageDownloader(fetcher: Router([:]), partsFolder: downloads)
        try Data(archiveBytes).write(to: ImageDownload.partURL(for: downloads.appendingPathComponent(Self.archiveName)))
        XCTAssertNil(try downloader.backgroundRequest(for: desktop.archive), "plus rien à recevoir")
        let url = try downloader.adopt(URL(fileURLWithPath: "/dev/null"), status: 416,
                                       contentRange: "bytes */\(archiveBytes.count)",
                                       for: desktop.archive, into: downloads)
        XCTAssertEqual(url, downloads.appendingPathComponent(Self.archiveName))
        XCTAssertEqual(try Data(contentsOf: url), Data(archiveBytes))
        XCTAssertTrue(desktop.archivePresent(in: downloads))
    }
}
