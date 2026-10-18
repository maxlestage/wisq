import Foundation

/// Télécharger une image depuis l'application : ce qui se décide, sans le
/// réseau.
///
/// **Le réseau est ailleurs.** `URLSession` vit sous Linux dans
/// `FoundationNetworking`, que `WisqVM` ne tire pas ; le transfert lui-même
/// est fait par l'application. Ce type porte tout le reste, qui est ce qui se
/// trompe : quel fichier demander, où reprendre un transfert coupé, que
/// faire de la réponse du serveur, et quand un fichier mérite d'entrer dans
/// la bibliothèque.
///
/// **La règle qui commande tout** : un fichier n'entre dans la bibliothèque
/// que si sa somme SHA-256 est celle que la distribution publie. Jusque-là,
/// il vit sous un nom en `.part`, que la bibliothèque ne liste pas, et qu'un
/// transfert repris complète au lieu de recommencer — sur un téléphone, une
/// image de 70 Mio coupée à 60 par un tunnel ne se retélécharge pas
/// entière.
public enum ImageDownload {
    /// La somme qu'une distribution publie pour une image : SHA-256 chez
    /// Alpine, SHA-512 chez Debian. En hexadécimal minuscule.
    public enum Checksum: Equatable, Sendable {
        case sha256(String)
        case sha512(String)

        /// La somme attendue.
        public var expected: String {
            switch self {
            case .sha256(let hex), .sha512(let hex): return hex.lowercased()
            }
        }

        /// Le nom de l'algorithme, pour le dire.
        public var algorithm: String {
            switch self {
            case .sha256: return "SHA-256"
            case .sha512: return "SHA-512"
            }
        }

        /// La même somme, calculée sur un fichier.
        func hex(ofFileAt url: URL) throws -> String {
            switch self {
            case .sha256: return try SHA256Stream.hex(ofFileAt: url)
            case .sha512: return try SHA512Stream.hex(ofFileAt: url)
            }
        }
    }

    /// Une image qu'une distribution publie, telle que la décrit son index.
    public struct Release: Equatable, Sendable {
        /// « Alpine », « Debian » : ce que la liste écrit devant la version.
        public let distribution: String
        public let flavor: String
        public let title: String
        public let version: String
        public let arch: String
        public let file: String
        public let size: Int
        public let checksum: Checksum
        /// L'index d'où elle vient : l'image est à côté.
        public let index: URL

        public init(distribution: String, flavor: String, title: String, version: String, arch: String,
                    file: String, size: Int, checksum: Checksum, index: URL) {
            self.distribution = distribution
            self.flavor = flavor
            self.title = title
            self.version = version
            self.arch = arch
            self.file = file
            self.size = size
            self.checksum = checksum
            self.index = index
        }
    }

    /// L'index des versions stables d'Alpine pour PC : un fichier YAML,
    /// tenu à jour par la distribution, qui donne pour chaque image son nom,
    /// sa taille et sa somme. Le lire au moment de télécharger évite d'écrire
    /// ici une version qui vieillirait.
    public static let alpineIndex = URL(
        string: "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml")!

    /// Les saveurs qui démarrent ici : des ISO dont le noyau et l'initramfs
    /// sont sous `/boot`. `virt`, la plus petite, d'abord — c'est celle
    /// qu'Alpine recommande pour une machine virtuelle.
    public static let bootableFlavors = ["alpine-virt", "alpine-standard"]

    /// Les entrées de l'index. Le YAML d'Alpine est une liste de
    /// dictionnaires plats, indentés de deux espaces ; les lignes des
    /// descriptions (`desc: |`) sont plus indentées, et ne donnent aucune clé
    /// connue même quand elles contiennent un deux-points. Une
    /// entrée à laquelle il manque un champ, ou dont la somme n'a pas la
    /// forme d'une somme, n'est pas rendue.
    public static func alpineReleases(_ yaml: String, index: URL = alpineIndex) -> [Release] {
        var entries: [[String: String]] = []
        var current: [String: String]?
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("-") {
                if let current { entries.append(current) }
                current = [:]
                continue
            }
            guard current != nil, line.hasPrefix("  "),
                  let colon = line.firstIndex(of: ":")
            else { continue }
            let key = line[line.index(line.startIndex, offsetBy: 2)..<colon]
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            current?[String(key)] = value
        }
        if let current { entries.append(current) }
        return entries.compactMap { fields in
            guard let flavor = fields["flavor"], let file = fields["file"],
                  let size = fields["size"].flatMap(Int.init), size > 0,
                  let sha256 = fields["sha256"]?.lowercased(), isHexDigest(sha256),
                  isPlainName(file)
            else { return nil }
            return Release(distribution: "Alpine", flavor: flavor,
                           title: fields["title"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? flavor,
                           version: fields["version"] ?? "", arch: fields["arch"] ?? "",
                           file: file, size: size, checksum: .sha256(sha256), index: index)
        }
    }

    /// Les images de l'index qui démarrent ici, dans l'ordre de
    /// `bootableFlavors`.
    public static func bootable(_ releases: [Release]) -> [Release] {
        bootableFlavors.compactMap { flavor in releases.first { $0.flavor == flavor } }
    }

    /// L'adresse d'une image : à côté de son index. Le nom vient de l'index,
    /// et a été refusé plus haut s'il contenait un chemin.
    public static func url(of release: Release) -> URL {
        release.index.deletingLastPathComponent().appendingPathComponent(release.file)
    }

    static func isHexDigest(_ text: String, length: Int = 64) -> Bool {
        text.count == length && text.allSatisfy { $0.isHexDigit }
    }

    /// Un nom de fichier, et rien d'autre : l'index vient du réseau, et un
    /// `../` y écrirait ailleurs que dans la bibliothèque.
    static func isPlainName(_ file: String) -> Bool {
        !file.isEmpty && !file.contains("/") && !file.hasPrefix(".")
    }

    // MARK: - L'index de Debian

    /// Les sommes des images de cloud de Debian 13, telles que l'équipe cloud
    /// de Debian les publie à chaque construction : `latest` suit la
    /// dernière.
    public static let debianIndex = URL(
        string: "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS")!

    /// **L'image `nocloud`, et elle seule.** C'est celle qui démarre ici de
    /// bout en bout (voir `CloudBoot`) : sans cloud-init, elle n'attend aucune
    /// source de données qu'une machine sans réseau ne trouverait jamais. Le
    /// qcow2 plutôt que le `.raw`, cinq fois plus petit à télécharger, et lu
    /// sur place par `Qcow2Image`.
    static func isBootableDebian(_ file: String) -> String? {
        let prefix = "debian-", suffix = "-nocloud-amd64.qcow2"
        guard file.hasPrefix(prefix), file.hasSuffix(suffix) else { return nil }
        let version = file.dropFirst(prefix.count).dropLast(suffix.count)
        return !version.isEmpty && version.allSatisfy(\.isNumber) ? String(version) : nil
    }

    /// Les images de `SHA512SUMS` qui démarrent ici, avec leur somme : une
    /// ligne par fichier, la somme, deux espaces (ou une espace et une
    /// étoile, en mode binaire), le nom. La taille n'y est pas :
    /// `ImageDownloader` la demande au serveur.
    public static func debianCandidates(_ sums: String) -> [(file: String, version: String, sha512: String)] {
        sums.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ", maxSplits: 1)
            guard words.count == 2 else { return nil }
            let sha512 = words[0].lowercased()
            var file = words[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            guard isHexDigest(sha512, length: 128), isPlainName(file),
                  let version = isBootableDebian(file)
            else { return nil }
            return (file, version, sha512)
        }
    }

    /// Une image de Debian, une fois sa taille connue.
    public static func debianRelease(file: String, version: String, sha512: String, size: Int,
                                     index: URL = debianIndex) -> Release {
        Release(distribution: "Debian", flavor: "debian-nocloud", title: "nocloud (qcow2)",
                version: version, arch: "x86_64", file: file, size: size,
                checksum: .sha512(sha512), index: index)
    }

    // MARK: - Reprendre

    /// Où vit le fichier tant qu'il n'est pas vérifié.
    public static func partURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".part")
    }

    /// L'en-tête `Range` qui reprend après `existing` octets déjà reçus ;
    /// `nil` pour un premier transfert.
    public static func rangeHeader(resumingAt existing: Int) -> String? {
        existing > 0 ? "bytes=\(existing)-" : nil
    }

    /// Ce qu'il faut faire des octets qui arrivent.
    public enum Continuation: Equatable, Sendable {
        /// Les ajouter au `.part` : le serveur reprend là où il s'était
        /// arrêté.
        case append
        /// Vider le `.part` et écrire depuis le début : le serveur a ignoré
        /// la reprise et renvoie tout.
        case restart
        /// Il n'y a plus rien à recevoir : le `.part` a déjà la taille du
        /// fichier.
        case complete
        /// Rien à garder ; la raison est dans le texte.
        case refuse(String)
    }

    /// La réponse du serveur, lue contre ce qui a été demandé.
    ///
    /// Les cas sont ceux que rend le vrai miroir d'Alpine : `206` avec
    /// `Content-Range: bytes 100-199/69206016` pour une reprise, `416` avec
    /// `bytes */69206016` quand on demande au-delà de la fin. Un `206` qui
    /// commence ailleurs qu'à l'octet demandé recoudrait le fichier à la
    /// mauvaise place : il est refusé, pas ajouté.
    public static func continuation(status: Int, contentRange: String?, resumingAt existing: Int)
        -> Continuation {
        switch status {
        case 200:
            return existing == 0 ? .append : .restart
        case 206:
            guard let range = contentRange.flatMap(parseContentRange), range.start == existing else {
                return .refuse("le serveur a repris le fichier ailleurs qu'à l'octet \(existing).")
            }
            return .append
        case 416:
            if let range = contentRange.flatMap(parseContentRange), range.total == existing, existing > 0 {
                return .complete
            }
            return .restart
        case 404, 410:
            return .refuse("le fichier n'existe plus sur le serveur (\(status)).")
        default:
            return .refuse("le serveur a répondu \(status).")
        }
    }

    /// `bytes 100-199/69206016` → (100, 69206016) ; `bytes */69206016` →
    /// (nil, 69206016). La taille totale peut être `*`, inconnue.
    /// **La taille d'un fichier que l'index ne donne pas**, demandée au
    /// serveur : un seul octet (`Range: bytes=0-0`), et le `206` qui revient
    /// dit le total après la barre — `bytes 0-0/437452288`. Un serveur qui
    /// répond autre chose ne dit pas la taille, et l'image n'est pas
    /// proposée : sans elle, ni la reprise ni le progrès ne tiennent.
    public static let sizeProbe = "bytes=0-0"

    public static func size(fromProbe status: Int, contentRange: String?) -> Int? {
        guard status == 206, let total = contentRange.flatMap(parseContentRange)?.total, total > 0 else {
            return nil
        }
        return total
    }

    static func parseContentRange(_ header: String) -> (start: Int?, total: Int?)? {
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes "), let slash = text.lastIndex(of: "/") else { return nil }
        let span = text[text.index(text.startIndex, offsetBy: 6)..<slash].trimmingCharacters(in: .whitespaces)
        let totalText = text[text.index(after: slash)...]
        let total = totalText == "*" ? nil : Int(totalText)
        if totalText != "*", total == nil { return nil }
        if span == "*" { return (nil, total) }
        guard let dash = span.firstIndex(of: "-"), let start = Int(span[..<dash]),
              Int(span[span.index(after: dash)...]) != nil
        else { return nil }
        return (start, total)
    }

    // MARK: - Finir

    public enum Failure: Error, Equatable, LocalizedError {
        /// La somme ne correspond pas : le fichier a été effacé.
        case checksumMismatch(expected: String, got: String)
        /// La taille ne correspond pas à celle que l'index annonce.
        case wrongSize(expected: Int, got: Int)

        public var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                return "le fichier téléchargé n'a pas la somme que publie la distribution ; "
                    + "il a été effacé, et le prochain essai repartira de zéro."
            case .wrongSize(let expected, let got):
                return "le fichier téléchargé fait \(got) octets au lieu de \(expected) ; "
                    + "il a été effacé, et le prochain essai repartira de zéro."
            }
        }
    }

    /// Le `.part` est-il entier ? Vérifie sa taille puis sa somme — celle que
    /// la distribution publie, dans son algorithme ; s'il est
    /// bon, il prend le nom de l'image, et remplace un fichier qui le portait
    /// déjà. S'il est faux, il est **effacé** : le garder ferait reprendre le
    /// prochain essai sur des octets dont on sait qu'ils sont mauvais.
    public static func finish(part: URL, as destination: URL, size: Int?, checksum: Checksum) throws {
        let manager = FileManager.default
        let got = (try? manager.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
        if let size, got != size {
            try? manager.removeItem(at: part)
            throw Failure.wrongSize(expected: size, got: got)
        }
        let digest = try checksum.hex(ofFileAt: part)
        guard digest == checksum.expected else {
            try? manager.removeItem(at: part)
            throw Failure.checksumMismatch(expected: checksum.expected, got: digest)
        }
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: part, to: destination)
    }
}
