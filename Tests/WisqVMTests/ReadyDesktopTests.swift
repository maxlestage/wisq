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

    /// **Une adresse, un fichier, pour l'image aussi.** Deux bureaux de deux
    /// titres, chacun avec sa propre archive, qui annoncent la même ISO à deux
    /// sommes (ou à deux tailles) : l'un des deux promet un fichier que
    /// l'adresse ne sert pas, et c'est celui qu'on téléchargerait en boucle —
    /// 1,4 Gio à chaque essai. L'application n'en propose aucun ; la fabrique
    /// refuse d'écrire l'index. Les deux archives à des adresses distinctes :
    /// seule la garde de l'image peut les écarter.
    func testTwoImagesAtOneAddressAreRefused() throws {
        let first = entry()
        var second = entry()
        second.title = "Void Xfce (autre)"
        second.archive.name = "void-live-x86_64-20250202-xfce-autre-niveau1.wisqmachine"
        second.archive.url = "https://github.com/maxlestage/wisq/releases/download/bureaux-1/\(second.archive.name)"
        XCTAssertEqual(ReadyDesktop.parse(try json([first, second])).count, 2, "deux bureaux sans conflit")

        var otherSum = second
        var otherISO = iso
        otherISO[0] ^= 0xFF
        otherSum.image.sha256 = SHA256Stream.hex(otherISO)
        XCTAssertEqual(otherSum.image.url, first.image.url)
        XCTAssertNotEqual(otherSum.archive.url, first.archive.url)
        let sums = ReadyDesktop.Index(desktops: [first, otherSum])
        XCTAssertEqual(sums.clashes, [Self.isoURL])
        XCTAssertEqual(ReadyDesktop.parse(try json([first, otherSum])), [], "deux sommes, une adresse")
        XCTAssertThrowsError(try ReadyDesktop.Index.publishable(sums)) {
            XCTAssertEqual($0 as? ReadyDesktop.Index.Fault, .clash(url: Self.isoURL))
        }

        var otherSize = second
        otherSize.image.bytes += 1
        XCTAssertEqual(ReadyDesktop.Index(desktops: [first, otherSize]).clashes, [Self.isoURL])
        XCTAssertEqual(ReadyDesktop.parse(try json([otherSize, first])), [], "deux tailles, une adresse")
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

    // MARK: - Les deux cœurs

    static let rustArchiveName = "void-live-x86_64-20250202-xfce-pret-rust-niveau2.wisqmachine"
    static let rustArchiveURL = "https://github.com/maxlestage/wisq/releases/download/bureaux-1/\(rustArchiveName)"

    /// L'entrée du bureau fabriqué sur le cœur Rust : la même image, son
    /// archive à elle, la version de l'instantané pour niveau.
    private func rustEntry(level: UInt64 = 2) -> ReadyDesktop.Index.Entry {
        var rust = entry(level: level)
        rust.core = .rust
        rust.archive.name = Self.rustArchiveName
        rust.archive.url = Self.rustArchiveURL
        rust.archive.sha256 = String(repeating: "b", count: 64)
        rust.kernelDigest = "d63775f2e341116a"
        return rust
    }

    /// **L'entrée du cœur qui tournera** : le cœur Rust là, réglage allumé
    /// (`rustLevel`), l'entrée Rust ; sinon, celle du cœur Swift — même titre,
    /// même image, une autre archive.
    func testTheRustEntryIsTakenWhenTheRustCoreRuns() throws {
        var swift = entry()
        swift.core = .swift
        let text = try json([swift, rustEntry()])
        let withoutRust = ReadyDesktop.parse(text)
        XCTAssertEqual(withoutRust.map(\.core), [.swift])
        XCTAssertEqual(withoutRust.map(\.archive.file), [Self.archiveName])
        let withRust = ReadyDesktop.parse(text, rustLevel: 2)
        XCTAssertEqual(withRust.map(\.core), [.rust])
        XCTAssertEqual(withRust.map(\.level), [2])
        XCTAssertEqual(withRust.map(\.archive.file), [Self.rustArchiveName])
        XCTAssertEqual(withRust.map(\.image.file), [Self.isoName], "la même image")
        // L'ordre de l'index n'y change rien.
        XCTAssertEqual(ReadyDesktop.parse(try json([rustEntry(), swift]), rustLevel: 2).map(\.core), [.rust])
        XCTAssertEqual(ReadyDesktop.parse(try json([rustEntry(), swift])).map(\.core), [.swift])
        // **Le cœur d'abord, le niveau ensuite** : un bureau Swift d'un niveau
        // plus haut ne passe pas devant le bureau Rust.
        var swiftThree = entry(level: 3)
        swiftThree.archive.name = "void-live-x86_64-20250202-xfce-pret-niveau3.wisqmachine"
        swiftThree.archive.url = "https://github.com/maxlestage/wisq/releases/download/bureaux-1/\(swiftThree.archive.name)"
        let three = try json([swiftThree, rustEntry()])
        XCTAssertEqual(ReadyDesktop.parse(three, supportedLevel: 3, rustLevel: 2).map(\.core), [.rust])
        XCTAssertEqual(ReadyDesktop.parse(three, supportedLevel: 3).map(\.level), [3])
        // Une version d'instantané que ce cœur ne reprend pas encore : la
        // Swift, plutôt que rien.
        XCTAssertEqual(ReadyDesktop.parse(try json([swift, rustEntry(level: 3)]), rustLevel: 2).map(\.core), [.swift])
    }

    /// **Il retombe proprement** quand l'index n'a que l'une des deux :
    /// l'entrée Swift seule se propose aux deux (sa session se reprend sur le
    /// cœur Swift) ; l'entrée Rust seule, au cœur Rust seulement.
    func testAnIndexWithOneCoreFallsBackCleanly() throws {
        let swiftOnly = try json([entry()])
        XCTAssertEqual(ReadyDesktop.parse(swiftOnly).map(\.core), [.swift], "une entrée sans cœur est du cœur Swift")
        XCTAssertEqual(ReadyDesktop.parse(swiftOnly, rustLevel: 2).map(\.core), [.swift])
        let rustOnly = try json([rustEntry()])
        XCTAssertEqual(ReadyDesktop.parse(rustOnly), [], "sans cœur Rust, rien : le cœur Swift ne la reprend pas")
        XCTAssertEqual(ReadyDesktop.parse(rustOnly, rustLevel: 2).map(\.core), [.rust])
        XCTAssertEqual(ReadyDesktop.parse(rustOnly, rustLevel: 1), [], "une version d'avant la carte")
    }

    /// **Les applications d'avant ne voient pas l'entrée Rust.** Elles
    /// ignorent `core` : pour elles, c'est un bureau du cœur Swift, jugé par
    /// son niveau seul — 2, au-dessus du leur. Elles gardent l'entrée Swift.
    /// Une entrée Rust de niveau 1 leur serait proposée : la fabrique refuse
    /// de l'écrire.
    func testOlderApplicationsDoNotSeeTheRustEntry() throws {
        let text = try json([entry(), rustEntry()])
        XCTAssertTrue(text.contains("\"core\" : \"rust\""), text)
        // Ce qu'une application d'avant décode : le même index, sans le champ.
        let seenBefore = text.replacingOccurrences(of: "\"core\" : \"rust\",", with: "")
        XCTAssertFalse(seenBefore.contains("rust\""), "le champ est retiré")
        let before = ReadyDesktop.parse(seenBefore, supportedLevel: Core.levelSeenByOlderApps)
        XCTAssertEqual(before.map(\.archive.file), [Self.archiveName])

        let visible = rustEntry(level: Core.levelSeenByOlderApps)
        XCTAssertEqual(ReadyDesktop.Index(desktops: [entry(), visible]).refused, [visible])
        XCTAssertThrowsError(try ReadyDesktop.Index.publishable(ReadyDesktop.Index(desktops: [visible]))) {
            XCTAssertEqual($0 as? ReadyDesktop.Index.Fault,
                           .refused(title: "Void Xfce (prêt)", url: Self.rustArchiveURL))
        }
        XCTAssertEqual(ReadyDesktop.parse(try json([visible]), rustLevel: 2), [], "et l'application ne la prend pas")
        XCTAssertNoThrow(try ReadyDesktop.Index.publishable(ReadyDesktop.Index(desktops: [rustEntry()])))
        XCTAssertEqual(Core.firstRustLevel, 2)
    }

    private typealias Core = ReadyDesktop.Core

    /// **L'index neuf garde l'autre cœur** : le bureau Rust publié seul ne
    /// retire pas le bureau Swift de l'ancien index, ni l'inverse ; le même
    /// titre, le même cœur et le même niveau remplacent.
    func testTheMergedIndexKeepsTheOtherCore() throws {
        let old = ReadyDesktop.Index(desktops: [entry()])
        let withRust = try ReadyDesktop.Index.publishable(ReadyDesktop.Index(desktops: [rustEntry()]), keeping: old)
        XCTAssertEqual(withRust.desktops.map(\.machineCore), [.rust, .swift])
        var redone = entry()
        redone.madeAt = Self.moment.addingTimeInterval(86_400)
        let swiftAgain = try ReadyDesktop.Index.publishable(ReadyDesktop.Index(desktops: [redone]), keeping: withRust)
        XCTAssertEqual(swiftAgain.desktops.map(\.machineCore), [.swift, .rust])
        XCTAssertEqual(swiftAgain.desktops.first?.madeAt, redone.madeAt)
        var rustAgain = rustEntry()
        rustAgain.madeAt = redone.madeAt
        let both = try ReadyDesktop.Index.publishable(ReadyDesktop.Index(desktops: [rustAgain]), keeping: swiftAgain)
        XCTAssertEqual(both.desktops, [rustAgain, redone])
        // **Au même niveau, le cœur départage** : un bureau Swift d'un niveau
        // 2 à venir ne remplace pas le bureau Rust du niveau 2.
        var swiftTwo = entry(level: 2)
        swiftTwo.archive.name = "void-live-x86_64-20250202-xfce-pret-niveau2.wisqmachine"
        swiftTwo.archive.url = "https://github.com/maxlestage/wisq/releases/download/bureaux-1/\(swiftTwo.archive.name)"
        let kept = ReadyDesktop.Index(desktops: [swiftTwo]).merged(keeping: ReadyDesktop.Index(desktops: [rustEntry()]))
        XCTAssertEqual(kept.desktops.map(\.machineCore), [.swift, .rust])
    }

    /// **Un cœur que cette version ne connaît pas** n'est pas proposé, et
    /// n'emporte pas l'entrée d'à côté.
    func testAnUnknownCoreIsNotOffered() throws {
        let text = try json([entry(), rustEntry()])
            .replacingOccurrences(of: "\"core\" : \"rust\"", with: "\"core\" : \"emetteur\"")
        XCTAssertEqual(ReadyDesktop.parse(text, rustLevel: 2).map(\.core), [.swift])
    }

    /// **La fiche du cœur Rust devient son entrée** : le cœur, la version
    /// de son instantané, son archive à elle ; écrite, relue, proposée.
    func testTheSheetOfARustBuildBecomesARustEntry() throws {
        let stem = ReadyDesktopBuild.outputStem(image: Self.isoName, level: 2, core: .rust)
        XCTAssertEqual(stem + ".wisqmachine", Self.rustArchiveName)
        XCTAssertEqual(ReadyDesktopBuild.outputStem(image: Self.isoName, level: 1, core: .swift) + ".wisqmachine",
                       Self.archiveName, "le nom du cœur Swift ne change pas")
        let sheet = ReadyDesktopBuild.Sheet(
            title: "Void Xfce (prêt)", level: 2,
            image: .init(name: Self.isoName, bytes: 1_446_789_120, sha256: String(repeating: "4", count: 64)),
            archive: .init(name: Self.rustArchiveName, bytes: 150_000_000, sha256: String(repeating: "b", count: 64)),
            kernelDigest: "d63775f2e341116a", ramBytes: 1 << 30, screen: [1024, 768],
            commandLine: "init_on_free=1", madeAt: Self.moment, guestClock: Self.moment,
            instructions: 3, snapshotBytes: 4, packedBytes: 5, commit: nil, core: .rust)
        XCTAssertEqual(try ReadyDesktopBuild.Sheet.decode(try sheet.encoded()), sheet)
        let built = ReadyDesktop.Index.Entry(
            sheet: sheet, image: URL(string: Self.isoURL)!, archive: URL(string: Self.rustArchiveURL)!)
        XCTAssertEqual(built.core, .rust)
        let data = try ReadyDesktop.Index.publishable(ReadyDesktop.Index(desktops: [built])).encoded()
        XCTAssertEqual(try ReadyDesktop.Index.decode(data).desktops, [built])
        XCTAssertEqual(ReadyDesktop.parse(String(decoding: data, as: UTF8.self), rustLevel: 2).map(\.core), [.rust])
        // Une fiche d'avant, sans cœur : du cœur Swift.
        let oldSheet = String(decoding: try sheet.encoded(), as: UTF8.self)
            .replacingOccurrences(of: "\"core\" : \"rust\",", with: "")
        XCTAssertNil(try ReadyDesktopBuild.Sheet.decode(Data(oldSheet.utf8)).core)
    }

    // MARK: - L'index, sur le réseau

    /// **L'index des bureaux absent ne cache rien et ne dit rien** : la
    /// release n'existe pas encore, GitHub répond 404 ; les images des
    /// distributions sont là, sans échec à montrer. Et dans l'autre sens :
    /// aucune distribution ne répond, les bureaux restent proposés.
    /// **Le catalogue lu par le réseau choisit le cœur** : `rustCore` y
    /// passe jusqu'au choix de l'entrée.
    func testTheCatalogTakesTheEntryOfTheCoreThatRuns() async throws {
        let index = try json([entry(), rustEntry()])
        let router = Router([ReadyDesktop.index: Server(Array(index.utf8))])
        let downloader = ImageDownloader(fetcher: router, partsFolder: downloads)
        let swift = await downloader.readyCatalog()
        XCTAssertEqual(swift.desktops.map(\.core), [.swift])
        let rust = await downloader.readyCatalog(rustCore: true)
        XCTAssertEqual(rust.desktops.map(\.core), [.rust])
        XCTAssertEqual(rust.desktops.map(\.level), [UInt64(RustPCSnapshot.version)])
        let catalog = await downloader.catalog(rustCore: true)
        XCTAssertEqual(catalog.desktops.map(\.core), [.rust])
    }

    func testAnAbsentIndexHidesNothingAndSaysNothing() async throws {
        let onlyAlpine = Router([ImageDownload.alpineIndex: Server(Array(ImageDownloadTests.index.utf8))])
        let downloader = ImageDownloader(fetcher: onlyAlpine, partsFolder: downloads)
        let desktops = await downloader.readyDesktops()
        XCTAssertEqual(desktops, [])
        let catalog = await downloader.catalog()
        XCTAssertEqual(catalog.desktops, [])
        XCTAssertEqual(catalog.releases.map(\.flavor), ["alpine-virt", "alpine-standard"])
        XCTAssertNil(catalog.failure, "un index des bureaux absent n'est pas une panne à dire")
        XCTAssertNil(catalog.desktopsFailure, "ni pour les bureaux eux-mêmes : la release n'existe pas")

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

    /// **L'image qui tombe ne dit rien.** Dire « remplacée » efface ce qui
    /// avait été écrit sur l'ancien fichier (`KernelLibrary.replaced`) : le
    /// dire avant que l'image neuve ne soit reçue et vérifiée l'effacerait
    /// alors que l'ancien fichier est toujours là, intact. Rien n'est donc dit
    /// tant que l'image n'est pas rangée ; l'essai suivant, qui la reçoit, le
    /// dit une fois.
    func testAnImageThatFailsSaysNothingReplaced() async throws {
        let old = Data("une autre image".utf8)
        try old.write(to: library.appendingPathComponent(Self.isoName))
        let desktop = try desktop(entry())
        let image = Server(iso), archive = Server(archiveBytes)
        image.cutAfter = 20_000
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        let replaced = Names()
        do {
            _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader),
                                        replacedImage: { replaced.add($0) })
            XCTFail("la coupure doit remonter")
        } catch is Server.Cut {}
        XCTAssertEqual(replaced.all, [], "rien n'a remplacé l'ancien fichier")
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent(Self.isoName)), old,
                       "l'ancien fichier est toujours en place")
        XCTAssertEqual(archive.ranges, [], "l'archive n'est pas demandée")

        _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader),
                                    replacedImage: { replaced.add($0) })
        XCTAssertEqual(replaced.all, [Self.isoName], "dit une fois, quand l'image est là")
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent(Self.isoName)), Data(iso))
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

    /// **Le bureau installé attend sa première reprise** : la marque est
    /// posée sous l'identité de sa session, avec le jour de la fabrication. Sans
    /// elle, la reprise rattrapait le temps depuis l'import, et l'invité
    /// restait au jour de la fabrique. Voir `FirstResume`.
    func testAnInstalledDesktopWaitsForItsFirstResume() throws {
        let archive = try makeArchive(kernel: kernel)
        let desktop = try desktop(forKernel: kernel)
        let machine = try install(desktop, archive: archive, digest: ReadyDesktopBuild.kernelDigest(kernel))
        let identity = SuspendedMachine.identity(of: kernel, named: machine.key)
        XCTAssertEqual(FirstResume.pending(kernel: identity, in: storage), FirstResume(madeAt: Self.moment))
        // La première écriture de la session la retire : c'est la reprise
        // suivante qui rattrape, comme pour toute machine.
        try SuspendedMachine.save(Data(repeating: 3, count: 64), kernel: identity, in: storage)
        XCTAssertNil(FirstResume.pending(kernel: identity, in: storage))
    }

    /// **Une marque qui ne s'écrit pas défait l'installation** : sans elle,
    /// la machine reprendrait au jour de la fabrique, sans le dire. Rien ne
    /// reste — ni la machine dans la liste, ni sa session —, l'erreur est
    /// rendue, et l'archive est effacée comme après tout refus.
    ///
    /// Un dossier occupe la place de la marque : son écriture `.atomic` est
    /// refusée au renommage, même sous `root`.
    func testAMarkerThatCannotBeWrittenUndoesTheInstallation() throws {
        let archive = try makeArchive(kernel: kernel)
        let desktop = try desktop(forKernel: kernel)
        let id = "0123456789ab"
        let identity = SuspendedMachine.identity(of: kernel, named: InstalledMachine.keyPrefix + id)
        let marker = storage.appendingPathComponent(SuspendedMachine.fileName(kernel: identity)
                                                    + FirstResume.markerSuffix, isDirectory: true)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        try Data([0]).write(to: marker.appendingPathComponent("occupe"))
        XCTAssertThrowsError(try desktop.install(
            archive: archive, imageKernelDigest: ReadyDesktopBuild.kernelDigest(kernel), library: [Self.isoName],
            in: storage, id: id, createOwnDisk: { _, _ in throw MachineArchive.Refusal.damaged }))
        XCTAssertEqual(InstalledMachines.list(in: storage).map(\.id), [], "l'installation n'a pas été défaite")
        XCTAssertFalse(SuspendedMachine.exists(kernel: identity, in: storage), "la session est restée")
        XCTAssertFalse(exists(archive))
    }

    /// **Une image au noyau différent est refusée avant l'import** : la
    /// session ne serait jamais trouvée, et la machine démarrerait à froid
    /// sans le dire. Rien n'est installé ; une image illisible (`nil`) non
    /// plus. **Le bureau reçu est gardé** : c'est l'image qui est en faute
    /// (`testAnImageAtFaultKeepsTheDownloadedArchive`).
    func testAnImageWithAnotherKernelIsRefused() throws {
        let desktop = try desktop(forKernel: kernel)
        for found in ["0123456789abcdef", nil] as [String?] {
            let archive = try makeArchive(kernel: kernel)
            XCTAssertThrowsError(try install(desktop, archive: archive, digest: found)) {
                XCTAssertEqual($0 as? ReadyDesktop.Refusal,
                               .wrongKernel(expected: ReadyDesktopBuild.kernelDigest(kernel), found: found))
            }
            XCTAssertEqual(InstalledMachines.list(in: storage), [])
            XCTAssertTrue(exists(archive), "le bureau reçu, bon, est gardé")
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

    // MARK: - Le parcours, de bout en bout

    /// **La place manque : rien ne part, et le refus dit combien libérer.**
    /// Sans la garde, les deux fichiers partaient quand même, et le téléphone
    /// plein faisait tomber l'écriture au milieu de l'image.
    func testNotEnoughSpaceRefusesBeforeAnyRequest() async throws {
        let desktop = try desktop(entry())
        let image = Server(iso), archive = Server(archiveBytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        let room = desktop.room(library: library, downloads: downloads)
        XCTAssertEqual(room, .init(image: iso.count, archive: archiveBytes.count,
                                   install: 2 * archiveBytes.count + ReadyDesktop.digestScratch))
        do {
            _ = try await desktop.fetch(library: library, downloads: downloads, available: room.total - 1,
                                        download: download(with: downloader))
            XCTFail("la place manque d'un octet : rien ne doit partir")
        } catch let refusal as ReadyDesktop.Refusal {
            XCTAssertEqual(refusal, .notEnoughSpace(room, available: room.total - 1))
            let text = try XCTUnwrap(refusal.errorDescription)
            XCTAssertTrue(text.hasPrefix("Pas assez de place sur le téléphone : ce bureau demande 256,2 Mio de libre "
                                         + "(107 Kio à télécharger, puis 256,1 Mio pour l'installer"), text)
            XCTAssertTrue(text.contains("il en reste 256,2 Mio. Libérez au moins 1 o"), text)
            XCTAssertTrue(text.hasSuffix("Rien n'a été téléchargé."), text)
        }
        XCTAssertEqual(image.ranges, [], "l'image n'a pas été demandée")
        XCTAssertEqual(archive.ranges, [], "l'archive non plus")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [], "aucun .part")
        XCTAssertEqual(desktop.spaceShortfall(available: room.total - 1, library: library, downloads: downloads),
                       ReadyDesktop.Refusal.notEnoughSpace(room, available: room.total - 1).errorDescription,
                       "la feuille le dit avant qu'on touche")
        XCTAssertNil(desktop.spaceShortfall(available: room.total, library: library, downloads: downloads))
        XCTAssertNil(desktop.spaceShortfall(available: nil, library: library, downloads: downloads),
                     "une place illisible ne refuse rien")
        // Juste assez : les deux arrivent.
        _ = try await desktop.fetch(library: library, downloads: downloads, available: room.total,
                                    download: download(with: downloader))
        XCTAssertEqual(image.ranges, [nil])
        XCTAssertEqual(archive.ranges, [nil])
        XCTAssertEqual(desktop.room(library: library, downloads: downloads).download, 0, "plus rien à recevoir")
    }

    /// **La place se compte d'après ce qui est déjà là** : l'image entière ne
    /// compte plus, un `.part` compte pour ce qu'il lui manque.
    func testTheRoomCountsWhatIsAlreadyThere() throws {
        let desktop = try desktop(entry())
        try Data(iso).write(to: library.appendingPathComponent(Self.isoName))
        try Data(archiveBytes.prefix(20_000))
            .write(to: ImageDownload.partURL(for: downloads.appendingPathComponent(Self.archiveName)))
        XCTAssertEqual(desktop.room(library: library, downloads: downloads).download, archiveBytes.count - 20_000)
    }

    /// Le téléchargement de la feuille, annulé dès que `cancelAt` octets du
    /// fichier `file` sont arrivés : comme « Annuler » touché à ce moment.
    private func download(with downloader: ImageDownloader, cancelling file: String, at cancelAt: Int)
        -> @Sendable (ImageDownload.Release, ImageDownload.Destination, @escaping @Sendable (Int, Int) -> Void)
        async throws -> URL {
        let plain = download(with: downloader)
        return { release, destination, progress in
            try await plain(release, destination) { have, total in
                progress(have, total)
                if release.file == file, have >= cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
    }

    /// **« Annuler » au milieu de l'image** : l'annulation remonte comme
    /// telle, ce qui est écrit reste, l'archive n'est pas demandée ; la
    /// phrase dit ce qui est gardé, et le prochain essai reprend là.
    func testACancelInTheMiddleOfTheImageKeepsWhatWasWritten() async throws {
        let desktop = try desktop(entry())
        let image = Server(iso), archive = Server(archiveBytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        // Dans une tâche à part : c'est elle qu'« Annuler » vise, pas le test.
        let library = self.library, downloads = self.downloads
        let cancelling = download(with: downloader, cancelling: Self.isoName, at: 20_000)
        do {
            _ = try await Task {
                try await desktop.fetch(library: library, downloads: downloads, download: cancelling)
            }.value
            XCTFail("l'annulation doit remonter")
        } catch is CancellationError {}
        XCTAssertEqual(archive.ranges, [], "l'archive ne part pas après une annulation")
        let part = ImageDownload.partURL(for: downloads.appendingPathComponent(Self.isoName))
        let kept = try XCTUnwrap(ReadyDesktop.size(of: part))
        XCTAssertEqual(kept, 20_480, "le morceau qui a passé la borne est écrit, rien après")
        XCTAssertEqual(desktop.keptPhrase(library: library, downloads: downloads),
                       "Téléchargement arrêté. Gardé — l'image : 20 Kio sur 59 Kio. Le prochain essai reprendra là.")
        _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader))
        XCTAssertEqual(image.ranges, [nil, "bytes=20480-"], "repris là, pas du début")
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent(Self.isoName)), Data(iso))
    }

    /// **« Annuler » au milieu du bureau** : l'image reste entière, le
    /// `.part` du bureau aussi, et la phrase dit les deux.
    func testACancelInTheMiddleOfTheArchiveKeepsTheImage() async throws {
        let desktop = try desktop(entry())
        let image = Server(iso), archive = Server(archiveBytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        let library = self.library, downloads = self.downloads
        let cancelling = download(with: downloader, cancelling: Self.archiveName, at: 8_000)
        do {
            _ = try await Task {
                try await desktop.fetch(library: library, downloads: downloads, download: cancelling)
            }.value
            XCTFail("l'annulation doit remonter")
        } catch is CancellationError {}
        XCTAssertEqual(desktop.keptPhrase(library: library, downloads: downloads),
                       "Téléchargement arrêté. Gardé — l'image : entier ; le bureau : 8 Kio sur 49 Kio. "
                        + "Le prochain essai reprendra là.")
        _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader))
        XCTAssertEqual(image.ranges, [nil], "l'image n'est pas redemandée")
        XCTAssertEqual(archive.ranges, [nil, "bytes=8192-"])
    }

    /// **L'image finie au moment même où « Annuler » est touché** : son
    /// téléchargement rend le fichier sans lever, et l'archive partait quand
    /// même. Elle ne part plus.
    func testACancelAsTheImageEndsDoesNotStartTheArchive() async throws {
        let desktop = try desktop(entry())
        let image = Server(iso), archive = Server(archiveBytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        let plain = download(with: downloader)
        let library = self.library, downloads = self.downloads
        typealias Download = @Sendable (ImageDownload.Release, ImageDownload.Destination,
                                        @escaping @Sendable (Int, Int) -> Void) async throws -> URL
        let cancelling: Download = { release, destination, progress in
            let url = try await plain(release, destination, progress)
            if release.file == Self.isoName { withUnsafeCurrentTask { $0?.cancel() } }
            return url
        }
        do {
            _ = try await Task {
                try await desktop.fetch(library: library, downloads: downloads, download: cancelling)
            }.value
            XCTFail("l'annulation doit remonter")
        } catch is CancellationError {}
        XCTAssertEqual(archive.ranges, [], "l'archive est partie après l'annulation")
        XCTAssertTrue(desktop.imagePresent(in: library))
        XCTAssertEqual(desktop.keptPhrase(library: library, downloads: downloads),
                       "Téléchargement arrêté. Gardé — l'image : entier. Le prochain essai reprendra là.")
    }

    /// Rien encore rangé : la phrase ne promet pas de reprise.
    func testACancelBeforeAnythingSaysSo() throws {
        let desktop = try desktop(entry())
        XCTAssertEqual(desktop.keptPhrase(library: library, downloads: downloads),
                       "Téléchargement arrêté. Rien n'avait encore été rangé : le prochain essai repartira du début.")
    }

    /// **L'image en faute garde le bureau reçu** : refusé pour un noyau qui
    /// n'est pas le sien, puis pour une image retirée, le bureau reste là, à
    /// sa somme ; l'essai suivant ne le redemande pas. Il était effacé, et
    /// chaque essai retéléchargeait le bureau pour le refuser de nouveau.
    func testAnImageAtFaultKeepsTheDownloadedArchive() async throws {
        let archiveFile = try makeArchive(kernel: kernel)
        let bytes = Array(try Data(contentsOf: archiveFile))
        let desktop = try desktop(entry(digest: ReadyDesktopBuild.kernelDigest(kernel), archive: bytes))
        try Data(iso).write(to: library.appendingPathComponent(Self.isoName))
        XCTAssertThrowsError(try install(desktop, archive: archiveFile, digest: "0123456789abcdef")) {
            XCTAssertEqual($0 as? ReadyDesktop.Refusal,
                           .wrongKernel(expected: ReadyDesktopBuild.kernelDigest(kernel), found: "0123456789abcdef"))
            XCTAssertTrue(($0 as? ReadyDesktop.Refusal)?.errorDescription?.hasSuffix(
                "Supprimez cette image de la bibliothèque, puis touchez de nouveau « Installer » : "
                    + "seule l'image sera retéléchargée.") ?? false)
        }
        XCTAssertTrue(exists(archiveFile), "le bureau reçu est gardé")
        XCTAssertThrowsError(try install(desktop, archive: archiveFile, digest: ReadyDesktopBuild.kernelDigest(kernel),
                                         library: [])) {
            XCTAssertEqual($0 as? ReadyDesktop.Refusal, .missingImage(Self.isoName))
        }
        XCTAssertTrue(exists(archiveFile), "le bureau reçu est gardé")
        let image = Server(iso), archive = Server(bytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        _ = try await desktop.fetch(library: library, downloads: downloads, download: download(with: downloader))
        XCTAssertEqual(archive.ranges, [], "le bureau gardé n'est pas redemandé")
        let machine = try install(desktop, archive: archiveFile, digest: ReadyDesktopBuild.kernelDigest(kernel))
        XCTAssertEqual(InstalledMachines.list(in: storage).map(\.id), [machine.id])
        XCTAssertFalse(exists(archiveFile), "installé, il ne garde plus sa place")
    }

    /// **Déjà installé, et dit** : une machine qui démarre déjà cette image,
    /// avec sa session ou sans, est nommée avant qu'on réinstalle ; et
    /// réinstaller ajoute une machine, sans toucher à la session de l'autre.
    func testAnInstalledDesktopIsNamedAndNotReplaced() throws {
        let desktop = try desktop(forKernel: kernel)
        XCTAssertNil(desktop.alreadyInstalledPhrase(desktop.installedCopies(among: [], in: storage)))
        let first = try install(desktop, archive: try makeArchive(kernel: kernel),
                                digest: ReadyDesktopBuild.kernelDigest(kernel))
        let session = SuspendedMachine.identity(digest: ReadyDesktopBuild.kernelDigest(kernel), named: first.key)
        let before = try Data(contentsOf: storage.appendingPathComponent(SuspendedMachine.fileName(kernel: session)))
        let copies = desktop.installedCopies(among: InstalledMachines.list(in: storage), in: storage)
        XCTAssertEqual(copies.map(\.machine.id), [first.id])
        XCTAssertEqual(copies.map(\.hasSession), [true])
        XCTAssertEqual(desktop.alreadyInstalledPhrase(copies),
                       "« Void Xfce (prêt) » démarre déjà cette image, avec sa session. Installer ajoute une autre "
                        + "machine, prête au jour de la fabrication ; celles-ci et leurs sessions restent telles quelles.")
        let second = try install(desktop, archive: try makeArchive(kernel: kernel),
                                 digest: ReadyDesktopBuild.kernelDigest(kernel))
        XCTAssertNotEqual(second.id, first.id)
        // Deux machines, chacune avec sa session : le pluriel, et aucune
        // n'est dite sans la sienne.
        let both = desktop.installedCopies(among: InstalledMachines.list(in: storage), in: storage)
        XCTAssertEqual(both.map(\.hasSession), [true, true])
        let names = both.map { "« \($0.machine.name) »" }.joined(separator: ", ")
        XCTAssertEqual(desktop.alreadyInstalledPhrase(both),
                       "\(names) démarrent déjà cette image, chacune avec sa session. Installer ajoute une autre "
                        + "machine, prête au jour de la fabrication ; celles-ci et leurs sessions restent telles quelles.")
        XCTAssertEqual(try Data(contentsOf: storage.appendingPathComponent(SuspendedMachine.fileName(kernel: session))),
                       before, "la session de la première est intacte")
        // Une machine de la même image sans session : dit aussi.
        SuspendedMachine.clear(kernel: session, in: storage)
        let after = desktop.installedCopies(among: InstalledMachines.list(in: storage), in: storage)
        XCTAssertEqual(after.map(\.hasSession).sorted { !$0 && $1 }, [false, true])
        let phrase = try XCTUnwrap(desktop.alreadyInstalledPhrase(after))
        XCTAssertTrue(phrase.contains("démarrent déjà cette image ; « \(second.name) » seulement avec sa session."),
                      phrase)
        XCTAssertEqual(desktop.alreadyInstalledPhrase([(first, false)]),
                       "« \(first.name) » démarre déjà cette image, sans session : l'ouvrir la fait repartir de zéro "
                        + "(une demi-heure). Installer ajoute une autre machine, prête au jour de la fabrication ; "
                        + "celles-ci et leurs sessions restent telles quelles.")
        // Une machine d'une autre image n'est pas nommée.
        let other = try InstalledMachines.install(image: "alpine-virt.iso", in: storage)
        XCTAssertFalse(desktop.installedCopies(among: [other], in: storage).contains { $0.machine.id == other.id })
    }

    /// **Un téléchargement qui continue en arrière-plan se dit**, l'image ou
    /// le bureau, d'après les fichiers que la session a en cours.
    func testABackgroundDownloadIsSaid() throws {
        let desktop = try desktop(entry())
        XCTAssertNil(desktop.backgroundPhrase(running: []))
        XCTAssertNil(desktop.backgroundPhrase(running: ["alpine-virt.iso"]))
        XCTAssertEqual(desktop.backgroundPhrase(running: [Self.isoName]),
                       "Le téléchargement de l'image continue en arrière-plan. Touchez « Installer » pour le "
                        + "suivre : il reprend là où il en est, rien n'est redemandé.")
        XCTAssertEqual(desktop.backgroundPhrase(running: [Self.archiveName]),
                       "Le téléchargement du bureau continue en arrière-plan. Touchez « Installer » pour le "
                        + "suivre : il reprend là où il en est, rien n'est redemandé.")
    }

    // MARK: - Le contrôle de la reprise de la tranche

    /// L'entrée de `bureaux-1`, à ses vraies tailles : l'ISO de 1,4 Gio et
    /// le bureau de 156 Mio. Rien n'est téléchargé de ces tailles-là.
    private func realSizes() throws -> ReadyDesktop {
        var real = entry()
        real.image.bytes = 1_446_789_120
        real.archive.bytes = 163_919_297
        return try desktop(real)
    }

    /// **La recopie de l'image est le moment le plus lourd**, et la garde le
    /// compte. La session d'arrière-plan rend l'image entière dans son
    /// fichier ; `adopt` la recopie sur le `.part` pendant que ce fichier
    /// existe encore : deux fois ce qui restait à recevoir. Pour `bureaux-1`
    /// sans rien de déjà là, 2 893 578 240 octets (2,69 Gio), quand la garde
    /// n'en demandait que 2 206 982 467 (2,06 Gio) : un téléphone à 2,3 Gio
    /// libres recevait toute l'image, et tombait à sa recopie.
    func testTheRoomHoldsTheCopyOfABackgroundDownload() async throws {
        // Ce que la garde suppose, vu sur `adopt` lui-même : après la
        // recopie, le fichier de la session est encore là, et l'image rangée
        // aussi — deux fois ce qui restait à recevoir.
        let small = try desktop(entry())
        let room = small.room(library: library, downloads: downloads)
        XCTAssertEqual(room.image, iso.count)
        let received = folder.appendingPathComponent("recu-par-la-session")
        try Data(iso).write(to: received)
        let downloader = ImageDownloader(fetcher: Router([:]), partsFolder: downloads)
        let url = try downloader.adopt(received, status: 200, contentRange: nil, for: small.image, into: library)
        let footprint = try XCTUnwrap(ReadyDesktop.size(of: received)) + XCTUnwrap(ReadyDesktop.size(of: url))
        XCTAssertEqual(footprint, 2 * room.image, "la session garde son fichier pendant la recopie")
        XCTAssertGreaterThanOrEqual(room.total, footprint)

        // Aux vraies tailles : refusé avant le premier octet.
        let real = try realSizes()
        let needed = real.room(library: folder.appendingPathComponent("vide"), downloads: downloads)
        XCTAssertEqual(needed.download + needed.install, 2_206_982_467, "l'ancien compte")
        XCTAssertEqual(needed.total, 2_893_578_240, "deux fois l'image")
        let available = 2_300 << 20
        let image = Server(iso), archive = Server(archiveBytes)
        let fetching = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        let empty = folder.appendingPathComponent("vide")
        do {
            _ = try await real.fetch(library: empty, downloads: downloads, available: available,
                                     download: download(with: fetching))
            XCTFail("2,3 Gio ne suffisent pas à recopier l'image")
        } catch let refusal as ReadyDesktop.Refusal {
            XCTAssertEqual(refusal, .notEnoughSpace(needed, available: available))
            XCTAssertEqual(refusal.errorDescription,
                           "Pas assez de place sur le téléphone : ce bureau demande 2,7 Gio de libre au plus fort "
                            + "(1,5 Gio à télécharger ; l'image reçue, 1,3 Gio, est recopiée avant d'être rangée, "
                            + "et prend un moment deux fois sa place), et il en reste 2,2 Gio. Libérez au moins "
                            + "459,5 Mio (Réglages, Général, Stockage de l'iPhone), puis réessayez. Rien n'a été "
                            + "téléchargé.")
        }
        XCTAssertEqual(image.ranges, [], "rien n'a été demandé")
        // L'image déjà là : la recopie du bureau ne dépasse pas l'installation,
        // et la phrase reste celle de la somme.
        XCTAssertFalse(ReadyDesktop.Room(image: 0, archive: 163_919_297, install: 596_274_050).copyIsThePeak)
    }

    /// **Le `.part` de l'image compte**, comme celui du bureau : ce qu'il a
    /// déjà reçu n'est plus à recevoir, ni à recopier.
    func testTheRoomCountsThePartOfTheImage() throws {
        let desktop = try desktop(entry())
        try Data(iso.prefix(20_000))
            .write(to: ImageDownload.partURL(for: downloads.appendingPathComponent(Self.isoName)))
        let room = desktop.room(library: library, downloads: downloads)
        XCTAssertEqual(room.image, iso.count - 20_000)
        XCTAssertEqual(room.download, iso.count - 20_000 + archiveBytes.count)
    }

    /// **Un téléchargement en cours en arrière-plan se suit, il ne se refuse
    /// pas** : son fichier a déjà pris de la place que `room` ne voit pas,
    /// et la feuille rouverte disait à la fois « continue en arrière-plan »
    /// et « Rien n'a été téléchargé », le bouton éteint. Le fichier d'un
    /// autre bureau, lui, ne change rien.
    func testABackgroundDownloadIsFollowedNotRefused() async throws {
        let desktop = try desktop(entry())
        let short = desktop.room(library: library, downloads: downloads).total - 1
        XCTAssertNotNil(desktop.spaceShortfall(available: short, library: library, downloads: downloads,
                                               running: ["alpine-virt.iso"]))
        XCTAssertNil(desktop.spaceShortfall(available: short, library: library, downloads: downloads,
                                            running: [Self.isoName]), "l'image en cours : on la suit")
        XCTAssertNil(desktop.spaceShortfall(available: short, library: library, downloads: downloads,
                                            running: [Self.archiveName]), "le bureau en cours : pareil")
        let image = Server(iso), archive = Server(archiveBytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        // L'image d'une distribution en cours ne coupe pas la garde de ce
        // bureau-ci : `fetch` refuse comme sans elle, avant toute requête.
        do {
            _ = try await desktop.fetch(library: library, downloads: downloads, available: short,
                                        running: ["alpine-virt.iso"], download: download(with: downloader))
            XCTFail("le fichier d'un autre ne doit pas couper la garde")
        } catch let refusal as ReadyDesktop.Refusal {
            XCTAssertEqual(refusal, .notEnoughSpace(desktop.room(library: library, downloads: downloads),
                                                    available: short))
        }
        XCTAssertEqual(image.ranges, [], "refusé avant toute requête")
        _ = try await desktop.fetch(library: library, downloads: downloads, available: short,
                                    running: [Self.isoName], download: download(with: downloader))
        XCTAssertEqual(image.ranges, [nil], "suivi, pas refusé")
        XCTAssertTrue(desktop.archivePresent(in: downloads))
    }

    /// **Un fichier rangé depuis le relevé ne coupe plus la garde** : la
    /// feuille lit les fichiers en cours à son ouverture, et l'image a pu
    /// finir depuis, la feuille ouverte. Le relevé disait encore « l'image
    /// court » : `spaceShortfall` se taisait, et `fetch` demandait l'archive
    /// sans rien compter, jusqu'à l'erreur du système sur un téléphone plein.
    /// Pareil pour l'archive rangée pendant que l'image manque. L'image qui
    /// manque encore, elle, reste suivie.
    func testAFileStoredSinceTheReadingNoLongerWaivesTheGuard() async throws {
        let desktop = try desktop(entry())
        let image = Server(iso), archive = Server(archiveBytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data(iso).write(to: library.appendingPathComponent(Self.isoName))
        let room = desktop.room(library: library, downloads: downloads)
        XCTAssertEqual(room.image, 0, "l'image est rangée")
        let short = room.total - 1
        XCTAssertEqual(desktop.followable(running: [Self.isoName], library: library, downloads: downloads), [])
        XCTAssertEqual(desktop.spaceShortfall(available: short, library: library, downloads: downloads,
                                              running: [Self.isoName]),
                       ReadyDesktop.Refusal.notEnoughSpace(room, available: short).errorDescription,
                       "la feuille le dit, malgré le relevé")
        do {
            _ = try await desktop.fetch(library: library, downloads: downloads, available: short,
                                        running: [Self.isoName], download: download(with: downloader))
            XCTFail("l'image rangée ne court plus : la garde joue")
        } catch let refusal as ReadyDesktop.Refusal {
            XCTAssertEqual(refusal, .notEnoughSpace(room, available: short))
        }
        XCTAssertEqual(archive.ranges, [], "l'archive n'a pas été demandée")
        XCTAssertEqual(image.ranges, [])

        // L'archive rangée, l'image qui manque : le relevé « le bureau court »
        // ne coupe pas la garde ; « l'image court », si.
        try FileManager.default.removeItem(at: library.appendingPathComponent(Self.isoName))
        try Data(archiveBytes).write(to: downloads.appendingPathComponent(Self.archiveName))
        let left = desktop.room(library: library, downloads: downloads)
        XCTAssertEqual(left.archive, 0)
        let both: Set<String> = [Self.isoName, Self.archiveName]
        XCTAssertEqual(desktop.followable(running: both, library: library, downloads: downloads), [Self.isoName])
        XCTAssertNotNil(desktop.spaceShortfall(available: left.total - 1, library: library, downloads: downloads,
                                               running: [Self.archiveName]))
        XCTAssertNil(desktop.spaceShortfall(available: left.total - 1, library: library, downloads: downloads,
                                            running: [Self.isoName]), "l'image manque : on la suit")
    }

    /// **Seul le transfert déjà en cours échappe à la garde.** Le relevé
    /// « l'image court » levait la garde pour tout le bureau : avec un octet
    /// libre et rien sur le disque, `spaceShortfall` se taisait et `fetch`
    /// demandait l'archive sans compter ; « le bureau court », l'image absente,
    /// et toute l'ISO partait. Ce qui reste de l'autre fichier, et
    /// l'installation, se comptent encore ; le refus dit que le transfert en
    /// cours continue, au lieu de « Rien n'a été téléchargé ».
    func testOnlyTheFollowedTransferEscapesTheGuard() async throws {
        let desktop = try desktop(entry())
        let image = Server(iso), archive = Server(archiveBytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        let whole = desktop.room(library: library, downloads: downloads)

        // L'image court : le bureau et l'installation se comptent.
        let besideImage = ReadyDesktop.Room(image: 0, archive: archiveBytes.count, install: whole.install)
        XCTAssertEqual(desktop.room(library: library, downloads: downloads, running: [Self.isoName]), besideImage)
        let imageRefusal = ReadyDesktop.Refusal.notEnoughSpace(besideImage, available: 1, following: [.image])
        let said = try XCTUnwrap(desktop.spaceShortfall(available: 1, library: library, downloads: downloads,
                                                        running: [Self.isoName]), "un octet libre : la feuille le dit")
        XCTAssertEqual(said, imageRefusal.errorDescription)
        XCTAssertTrue(said.hasPrefix("Pas assez de place sur le téléphone : outre l'image qui se télécharge en "
                                     + "arrière-plan, ce bureau demande 256,1 Mio de libre (49 Kio à télécharger"),
                      said)
        XCTAssertTrue(said.hasSuffix("Rien d'autre n'a été demandé : l'image continue de se télécharger en "
                                     + "arrière-plan."), said)
        do {
            _ = try await desktop.fetch(library: library, downloads: downloads, available: 1,
                                        running: [Self.isoName], download: download(with: downloader))
            XCTFail("un octet libre : l'archive ne doit pas partir")
        } catch let refusal as ReadyDesktop.Refusal {
            XCTAssertEqual(refusal, imageRefusal)
        }
        XCTAssertEqual(archive.ranges, [], "l'archive n'a pas été demandée")
        XCTAssertEqual(image.ranges, [])
        // Juste assez pour le reste : rien n'est dit, et l'image se suit.
        XCTAssertNotNil(desktop.spaceShortfall(available: besideImage.total - 1, library: library,
                                               downloads: downloads, running: [Self.isoName]))
        XCTAssertNil(desktop.spaceShortfall(available: besideImage.total, library: library, downloads: downloads,
                                            running: [Self.isoName]))

        // Le bureau court, l'image absente : toute l'ISO se compte.
        let besideArchive = ReadyDesktop.Room(image: iso.count, archive: 0, install: whole.install)
        XCTAssertEqual(desktop.room(library: library, downloads: downloads, running: [Self.archiveName]),
                       besideArchive)
        let archiveRefusal = ReadyDesktop.Refusal.notEnoughSpace(besideArchive, available: 1, following: [.archive])
        XCTAssertEqual(desktop.spaceShortfall(available: 1, library: library, downloads: downloads,
                                              running: [Self.archiveName]), archiveRefusal.errorDescription)
        XCTAssertTrue(try XCTUnwrap(archiveRefusal.errorDescription).contains("outre le bureau qui se télécharge"))
        do {
            _ = try await desktop.fetch(library: library, downloads: downloads, available: 1,
                                        running: [Self.archiveName], download: download(with: downloader))
            XCTFail("un octet libre : l'image ne doit pas partir")
        } catch let refusal as ReadyDesktop.Refusal {
            XCTAssertEqual(refusal, archiveRefusal)
        }
        XCTAssertEqual(image.ranges, [], "l'image n'a pas été demandée")
        XCTAssertEqual(archive.ranges, [])

        // Les deux courent : l'installation se compte encore.
        let both: Set<String> = [Self.isoName, Self.archiveName]
        let installOnly = ReadyDesktop.Room(image: 0, archive: 0, install: whole.install)
        XCTAssertEqual(desktop.room(library: library, downloads: downloads, running: both), installOnly)
        let bothRefusal = ReadyDesktop.Refusal.notEnoughSpace(installOnly, available: 1, following: [.image, .archive])
        XCTAssertEqual(desktop.spaceShortfall(available: 1, library: library, downloads: downloads, running: both),
                       bothRefusal.errorDescription)
        XCTAssertTrue(try XCTUnwrap(bothRefusal.errorDescription).hasSuffix(
            "Rien d'autre n'a été demandé : l'image et le bureau continuent de se télécharger en arrière-plan."))
        XCTAssertTrue(try XCTUnwrap(bothRefusal.errorDescription).contains(
            "outre l'image et le bureau qui se téléchargent en arrière-plan, ce bureau demande"))
    }

    /// **La ligne « continue en arrière-plan » se décide sur ce qui manque**,
    /// dans `WisqVM`, où elle se teste : l'image rangée depuis le relevé ne
    /// « continue » plus, celle qui manque, si. La place qui manque au reste
    /// la tait : sa phrase dit déjà que le transfert continue, et « Installer »,
    /// qu'elle aurait dit de toucher, est éteint.
    func testTheBackgroundLineIsDecidedOnWhatIsMissing() throws {
        let desktop = try desktop(entry())
        let following = "Le téléchargement de l'image continue en arrière-plan. Touchez « Installer » pour le "
            + "suivre : il reprend là où il en est, rien n'est redemandé."
        XCTAssertEqual(desktop.backgroundPhrase(running: [Self.isoName], library: library, downloads: downloads,
                                                available: nil), following, "l'image manque : elle continue")
        XCTAssertNil(desktop.backgroundPhrase(running: ["alpine-virt.iso"], library: library, downloads: downloads,
                                              available: nil))
        XCTAssertNil(desktop.backgroundPhrase(running: [Self.isoName], library: library, downloads: downloads,
                                              available: 1), "la place manque : sa phrase le dit")
        XCTAssertEqual(desktop.backgroundPhrase(running: [Self.isoName], library: nil, downloads: nil,
                                                available: 1), following, "dossiers illisibles : le relevé")
        try Data(iso).write(to: library.appendingPathComponent(Self.isoName))
        XCTAssertNil(desktop.backgroundPhrase(running: [Self.isoName], library: library, downloads: downloads,
                                              available: nil), "l'image rangée ne continue plus")
    }

    /// **Un fichier de la mauvaise taille sous le nom final reste suivi** :
    /// c'est la taille qui dit qu'il est rangé, pas le nom. Une image d'un
    /// autre jour sous le même nom, une archive tronquée : la session les
    /// remplacera, et leur transfert court encore.
    func testAFileOfTheWrongSizeUnderItsNameIsStillFollowed() throws {
        let desktop = try desktop(entry())
        try Data(iso.prefix(1_000)).write(to: library.appendingPathComponent(Self.isoName))
        try Data(archiveBytes.prefix(1_000)).write(to: downloads.appendingPathComponent(Self.archiveName))
        XCTAssertEqual(desktop.followable(running: [Self.isoName], library: library, downloads: downloads),
                       [Self.isoName], "l'image de la mauvaise taille court encore")
        XCTAssertEqual(desktop.followable(running: [Self.archiveName], library: library, downloads: downloads),
                       [Self.archiveName], "l'archive de la mauvaise taille aussi")
    }

    /// **Le refus de la place ne suit rien** : le transfert de fond qui
    /// courait continue, et la ligne doit encore le dire. Fini, en panne ou
    /// annulé, ce bureau sort des fichiers en cours ; les autres restent.
    func testARefusalOfSpaceKeepsTheRunningFiles() throws {
        let desktop = try desktop(entry())
        let running: Set<String> = [Self.isoName, "alpine-virt.iso"]
        let room = ReadyDesktop.Room(image: 0, archive: 1, install: 1)
        let refused = ReadyDesktop.Refusal.notEnoughSpace(room, available: 1, following: [.image])
        XCTAssertEqual(desktop.followed(running: running, after: refused), running, "refusé : il court encore")
        XCTAssertEqual(desktop.followed(running: running, after: nil), ["alpine-virt.iso"])
        XCTAssertEqual(desktop.followed(running: running, after: CancellationError()), ["alpine-virt.iso"])
        XCTAssertEqual(desktop.followed(running: running, after: ReadyDesktop.Refusal.missingImage(Self.isoName)),
                       ["alpine-virt.iso"])
    }

    /// **« Installer » relit les fichiers en cours avant de suivre** : le
    /// relevé de l'ouverture a pu vieillir, la feuille ouverte. Une tâche de
    /// fond tombée depuis y figurait encore, et toute l'image repartait sans
    /// garde de place. Ceci se lit dans `ImageDownloadModel` (SwiftUI, qui
    /// ne se construit pas sous Linux), commentaires ôtés.
    func testInstallReadsTheRunningFilesAgain() throws {
        let source = BootRefusalTests.withoutComments(try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WisqUI/ViewModels/ImageDownloadModel.swift"), encoding: .utf8))
        let start = try XCTUnwrap(source.range(of: "private func fetchAndInstall("), "fetchAndInstall introuvable")
        let body = source[start.upperBound...]
        let reread = try XCTUnwrap(body.range(of: "let running = await BackgroundImageDownloads.shared.runningFiles()"),
                                   "les fichiers en cours ne sont pas relus")
        let fetch = try XCTUnwrap(body.range(of: "desktop.fetch("))
        XCTAssertLessThan(reread.lowerBound, fetch.lowerBound, "relus avant de suivre")
        XCTAssertNotNil(body[fetch.upperBound...].range(of: "running: running,"), "et passés à fetch")
    }

    /// **Suivi, il ne se dit plus en arrière-plan** : une fois `fetch`
    /// rendu — annulé, fini, refusé —, la ligne ne dit plus qu'il continue.
    /// Elle le disait encore à côté de « Téléchargement arrêté ».
    func testAFollowedDesktopIsNoLongerSaidInTheBackground() throws {
        let desktop = try desktop(entry())
        let running: Set<String> = [Self.isoName, Self.archiveName, "alpine-virt.iso"]
        XCTAssertEqual(desktop.backgroundFiles(running: running), [Self.isoName, Self.archiveName])
        let after = desktop.followed(running: running)
        XCTAssertEqual(after, ["alpine-virt.iso"], "les fichiers des autres restent")
        XCTAssertNil(desktop.backgroundPhrase(running: after))
    }

    /// **Annulée avant de commencer, rien n'est demandé** : ni requête, ni
    /// `.part`. Sans le relevé du début de `fetch`, le premier morceau de
    /// l'image s'écrivait avant que l'annulation ne se voie.
    func testACancelledTaskAsksForNothing() async throws {
        let desktop = try desktop(entry())
        let image = Server(iso), archive = Server(archiveBytes)
        let downloader = ImageDownloader(fetcher: router(image: image, archive: archive), partsFolder: downloads)
        let library = self.library, downloads = self.downloads, plain = download(with: downloader)
        do {
            _ = try await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await desktop.fetch(library: library, downloads: downloads, download: plain)
            }.value
            XCTFail("l'annulation doit remonter")
        } catch is CancellationError {}
        XCTAssertEqual(image.ranges, [], "rien n'a été demandé")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [], "aucun .part")
    }

    /// **Les deux reçus, et le téléphone plein avant l'installation** : la
    /// phrase dit qu'il n'y a rien à télécharger, pas « 0 o à télécharger ».
    func testNothingLeftToDownloadIsSaid() {
        let room = ReadyDesktop.Room(image: 0, archive: 0, install: 300 << 20)
        let text = ReadyDesktop.Refusal.notEnoughSpace(room, available: 100 << 20).errorDescription ?? ""
        XCTAssertTrue(text.hasPrefix("Pas assez de place sur le téléphone : ce bureau demande 300,0 Mio de libre "
                                     + "(rien à télécharger, puis 300,0 Mio pour l'installer"), text)
    }

    /// **Une page à la place de l'index se dit** : un réseau qui demande de
    /// se connecter d'abord rend sa page en 200. Un index d'un format plus
    /// récent, lui, ne propose rien sans que ce soit une panne.
    func testAPageInsteadOfTheIndexIsSaid() async throws {
        let portal = Server(Array("<html><body>Connectez-vous au Wi-Fi de l'hôtel</body></html>".utf8))
        let caught = await ImageDownloader(fetcher: Router([ReadyDesktop.index: portal]), partsFolder: downloads)
            .readyCatalog()
        XCTAssertEqual(caught.desktops, [])
        XCTAssertEqual(caught.failure,
                       "Les bureaux prêts n'ont pas pu être lus (la réponse n'est pas l'index des bureaux ; un "
                        + "réseau qui demande de se connecter d'abord, comme un Wi-Fi d'hôtel ou de gare ?). Les "
                        + "images des distributions ne dépendent pas de cet index. Touchez « Réessayer » pour le relire.")
        let newer = Server(Array(#"{"format": 2, "bureaux": []}"#.utf8))
        let later = await ImageDownloader(fetcher: Router([ReadyDesktop.index: newer]), partsFolder: downloads)
            .readyCatalog()
        XCTAssertEqual(later.desktops, [])
        XCTAssertNil(later.failure, "un format plus récent n'est pas une panne")
        // Un objet JSON sans `format` n'est pas un index non plus : le corps
        // d'erreur d'un service, rendu en 200, que le seul `[String: Any]`
        // laissait passer pour un index vide.
        let message = Server(Array(#"{"message": "Not Found"}"#.utf8))
        let error = await ImageDownloader(fetcher: Router([ReadyDesktop.index: message]), partsFolder: downloads)
            .readyCatalog()
        XCTAssertEqual(error.desktops, [])
        XCTAssertEqual(error.failure, caught.failure, "un objet sans son format se dit comme la page")
        XCTAssertFalse(ReadyDesktop.isIndex(#"{"desktops": []}"#), "des entrées sans format")
        XCTAssertTrue(ReadyDesktop.isIndex(try json([entry()])))
    }

    /// Un fetcher qui ne joint rien : le réseau coupé.
    final class Offline: RangeFetcher, @unchecked Sendable {
        struct Down: Error, LocalizedError {
            var errorDescription: String? { "La connexion Internet semble interrompue." }
        }
        func fetch(_ url: URL, range: String?) async throws -> FetchedResponse { throw Down() }
    }

    /// Un serveur qui répond toujours le même statut.
    final class Status: RangeFetcher, @unchecked Sendable {
        let status: Int
        init(_ status: Int) { self.status = status }
        func fetch(_ url: URL, range: String?) async throws -> FetchedResponse {
            FetchedResponse(status: status, contentRange: nil, body: AsyncThrowingStream { $0.finish() })
        }
    }

    /// **L'index injoignable se dit**, avec de quoi réessayer ; un 404 reste
    /// muet (la release absente), et un index lu n'a rien à dire. La section
    /// disparaissait sans un mot sur un téléphone hors ligne.
    func testAnUnreachableIndexIsSaid() async throws {
        let offline = await ImageDownloader(fetcher: Offline(), partsFolder: downloads).catalog()
        XCTAssertEqual(offline.desktops, [])
        XCTAssertEqual(offline.desktopsFailure,
                       "Les bureaux prêts n'ont pas pu être lus (La connexion Internet semble interrompue). Les "
                        + "images des distributions ne dépendent pas de cet index. Touchez « Réessayer » pour le relire.")
        let broken = await ImageDownloader(fetcher: Status(503), partsFolder: downloads).readyCatalog()
        XCTAssertEqual(broken.failure.map { $0.contains("(le serveur a répondu 503)") }, true, "\(broken)")
        let absent = await ImageDownloader(fetcher: Status(404), partsFolder: downloads).readyCatalog()
        XCTAssertNil(absent.failure, "la release absente n'est pas une panne")
        let index = Server(Array(try json([entry()]).utf8))
        let read = await ImageDownloader(fetcher: Router([ReadyDesktop.index: index]), partsFolder: downloads)
            .readyCatalog()
        XCTAssertEqual(read.desktops.map(\.title), ["Void Xfce (prêt)"])
        XCTAssertNil(read.failure)
    }
}
