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
    /// Alpine, Fedora et Ubuntu, SHA-512 chez Debian. En hexadécimal minuscule.
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
        /// L'index d'où elle vient : l'image est à côté, sauf quand l'index
        /// donne lui-même son adresse.
        public let index: URL
        /// L'adresse que l'index donne, quand il en donne une (Fedora). Elle
        /// vient du réseau et n'est gardée que sur un hôte attendu.
        public let link: URL?

        public init(distribution: String, flavor: String, title: String, version: String, arch: String,
                    file: String, size: Int, checksum: Checksum, index: URL, link: URL? = nil) {
            self.distribution = distribution
            self.flavor = flavor
            self.title = title
            self.version = version
            self.arch = arch
            self.file = file
            self.size = size
            self.checksum = checksum
            self.index = index
            self.link = link
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
        release.link ?? release.index.deletingLastPathComponent().appendingPathComponent(release.file)
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

    // MARK: - L'index de Fedora

    /// La liste de toutes les images que publie Fedora, avec leur adresse,
    /// leur taille et leur somme SHA-256 : un tableau JSON tenu par le projet.
    public static let fedoraIndex = URL(string: "https://fedoraproject.org/releases.json")!

    /// **L'image `Generic` du Cloud, en qcow2, et elle seule.** C'est celle
    /// qui démarre ici de bout en bout : son noyau et son initramfs sont dans
    /// un btrfs (voir `BtrfsVolume`), lus par `CloudBoot`. Les autres sont
    /// faites pour un nuage précis (`AmazonEC2`, `Azure`, `GCE`), pour
    /// Vagrant, ou démarrent par un noyau unifié UEFI (`UEFI-UKI`) que wisq
    /// ne lit pas.
    static func isBootableFedora(_ file: String) -> Bool {
        file.hasPrefix("Fedora-Cloud-Base-Generic-") && file.hasSuffix(".x86_64.qcow2")
    }

    /// **La plus récente des versions publiées, et rien d'autre.** Le JSON
    /// garde toutes les versions encore servies, les bêtas comprises ; la
    /// liste n'en propose qu'une, numérotée comme une version et non comme
    /// une préversion. L'adresse vient du réseau : elle n'est gardée que sur
    /// `download.fedoraproject.org`, en HTTPS, et son dernier segment est le
    /// nom du fichier, refusé s'il contient un chemin.
    public static func fedoraReleases(_ json: String, index: URL = fedoraIndex) -> [Release] {
        guard let entries = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else {
            return []
        }
        let candidates: [(version: Int, release: Release)] = entries.compactMap { entry in
            guard entry["arch"] as? String == "x86_64",
                  entry["subvariant"] as? String == "Cloud_Base",
                  let versionText = entry["version"] as? String, let version = Int(versionText),
                  let linkText = entry["link"] as? String, let link = URL(string: linkText),
                  link.scheme == "https", link.host == "download.fedoraproject.org",
                  let sha256 = (entry["sha256"] as? String)?.lowercased(), isHexDigest(sha256),
                  let size = (entry["size"] as? String).flatMap(Int.init) ?? (entry["size"] as? Int), size > 0
            else { return nil }
            let file = link.lastPathComponent
            guard isPlainName(file), isBootableFedora(file) else { return nil }
            return (version, Release(distribution: "Fedora", flavor: "fedora-cloud", title: "Cloud (qcow2)",
                                     version: versionText, arch: "x86_64", file: file, size: size,
                                     checksum: .sha256(sha256), index: index, link: link))
        }
        guard let newest = candidates.map(\.version).max() else { return [] }
        return candidates.filter { $0.version == newest }.prefix(1).map(\.release)
    }

    // MARK: - L'index d'Ubuntu

    /// Les sommes des images de cloud d'Ubuntu 26.04, par son nom de code :
    /// le chemin numéroté (`26.04`) y renvoie, et `release` suit la dernière
    /// construction publiée.
    public static let ubuntuIndex = URL(
        string: "https://cloud-images.ubuntu.com/releases/resolute/release/SHA256SUMS")!

    /// **L'image disque du serveur, pour x86-64 de base.** Un `.img` qui est
    /// un qcow2, lu sur place par `Qcow2Image`. Pas la variante `amd64v3`,
    /// compilée pour des processeurs plus récents que celui que wisq
    /// annonce ; pas les `.vmdk`, `.ova`, `.squashfs` ni les archives.
    static func isBootableUbuntu(_ file: String) -> String? {
        let prefix = "ubuntu-", suffix = "-server-cloudimg-amd64.img"
        guard file.hasPrefix(prefix), file.hasSuffix(suffix) else { return nil }
        let version = file.dropFirst(prefix.count).dropLast(suffix.count)
        return !version.isEmpty && version.allSatisfy({ $0.isNumber || $0 == "." }) ? String(version) : nil
    }

    /// Les images de `SHA256SUMS` qui démarrent ici : le format de
    /// `sha256sum`, comme celui de Debian, avec l'étoile du mode binaire.
    public static func ubuntuCandidates(_ sums: String) -> [(file: String, version: String, sha256: String)] {
        sums.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ", maxSplits: 1)
            guard words.count == 2 else { return nil }
            let sha256 = words[0].lowercased()
            var file = words[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            guard isHexDigest(sha256), isPlainName(file), let version = isBootableUbuntu(file) else { return nil }
            return (file, version, sha256)
        }
    }

    /// Une image d'Ubuntu, une fois sa taille connue.
    public static func ubuntuRelease(file: String, version: String, sha256: String, size: Int,
                                     index: URL = ubuntuIndex) -> Release {
        Release(distribution: "Ubuntu", flavor: "ubuntu-cloud", title: "serveur cloud (qcow2)",
                version: version, arch: "x86_64", file: file, size: size,
                checksum: .sha256(sha256), index: index)
    }

    // MARK: - Arch Linux

    /// Le dossier des dernières images d'Arch Linux. Il n'y a pas d'index au
    /// sens strict : la page du dossier liste des fichiers **datés**, et c'est
    /// leur nom qui porte la version.
    public static let archIndex = URL(string: "https://geo.mirror.pkgbuild.com/images/latest/")!

    /// **L'image de cloud, datée** : `Arch-Linux-x86_64-cloudimg-AAAAMMJJ.N.qcow2`,
    /// rendue en version `AAAA.MM.JJ`. Pas l'alias non daté — son contenu
    /// change à chaque construction, et une somme lue avant le téléchargement
    /// pourrait ne plus être la bonne après — ni l'image `basic`, ni les
    /// signatures et sommes qui la suivent.
    static func isBootableArch(_ file: String) -> String? {
        let prefix = "Arch-Linux-x86_64-cloudimg-", suffix = ".qcow2"
        guard file.hasPrefix(prefix), file.hasSuffix(suffix) else { return nil }
        let stamp = file.dropFirst(prefix.count).dropLast(suffix.count)
        let parts = stamp.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        let date = parts[0]
        return "\(date.prefix(4)).\(date.dropFirst(4).prefix(2)).\(date.suffix(2))"
    }

    /// Les images de cloud que la page du dossier nomme, **la plus récente
    /// d'abord** : les `href` de la page, rien d'autre de son HTML.
    public static func archCandidates(_ listing: String) -> [(file: String, version: String)] {
        var found: [(file: String, version: String)] = []
        for piece in listing.components(separatedBy: "href=\"").dropFirst() {
            guard let end = piece.firstIndex(of: "\"") else { continue }
            let file = String(piece[..<end])
            guard isPlainName(file), let version = isBootableArch(file),
                  !found.contains(where: { $0.file == file }) else { continue }
            found.append((file, version))
        }
        return found.sorted { $0.file > $1.file }
    }

    /// La somme d'un fichier dans le fichier de sommes qui le suit (le format
    /// de `sha256sum` : le `.SHA256` d'Arch, le `.sha256` d'openSUSE),
    /// seulement si c'est bien de **ce** fichier qu'elle parle.
    public static func sumFileChecksum(_ sums: String, for file: String) -> String? {
        for line in sums.split(separator: "\n") {
            let words = line.split(separator: " ", maxSplits: 1)
            guard words.count == 2 else { continue }
            var name = words[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            let sha256 = words[0].lowercased()
            if name == file, isHexDigest(sha256) { return sha256 }
        }
        return nil
    }

    /// Une image d'Arch Linux, une fois sa taille connue.
    public static func archRelease(file: String, version: String, sha256: String, size: Int,
                                   index: URL = archIndex) -> Release {
        Release(distribution: "Arch Linux", flavor: "arch-cloud", title: "image de cloud (qcow2)",
                version: version, arch: "x86_64", file: file, size: size,
                checksum: .sha256(sha256), index: index,
                // **L'adresse est donnée, pas déduite** : l'index est un
                // dossier (`…/latest/`), et `url(of:)` retirerait son dernier
                // composant pour tomber un dossier trop haut.
                link: index.appendingPathComponent(file))
    }

    // MARK: - openSUSE Tumbleweed

    /// Le dossier des images d'openSUSE Tumbleweed. Comme pour Arch, la page
    /// du dossier nomme des fichiers datés : c'est l'instantané (`Snapshot`)
    /// qui porte la version, la distribution roulant sans numéro.
    public static let openSUSEIndex = URL(string: "https://download.opensuse.org/tumbleweed/appliances/")!

    /// **L'image de cloud « Minimal-VM », datée** :
    /// `openSUSE-Tumbleweed-Minimal-VM.x86_64-V-Cloud-SnapshotAAAAMMJJ.qcow2`,
    /// rendue en version `AAAA.MM.JJ`. Sa racine est un XFS, que lit
    /// `XfsVolume`. Pas l'alias non daté — pour la raison d'Arch —, ni les
    /// autres saveurs (`kvm-and-xen`, `VMware`, `MS-HyperV`), qui ne sont pas
    /// faites pour démarrer seules sous un nuage, ni ce qui suit l'image.
    static func isBootableOpenSUSE(_ file: String) -> String? {
        let prefix = "openSUSE-Tumbleweed-Minimal-VM.x86_64-", suffix = ".qcow2", marker = "-Cloud-Snapshot"
        guard file.hasPrefix(prefix), file.hasSuffix(suffix) else { return nil }
        let middle = file.dropFirst(prefix.count).dropLast(suffix.count)
        guard let cut = middle.range(of: marker) else { return nil }
        let image = middle[..<cut.lowerBound], date = middle[cut.upperBound...]
        guard !image.isEmpty, image.allSatisfy({ $0.isNumber || $0 == "." }),
              date.count == 8, date.allSatisfy(\.isNumber) else { return nil }
        return "\(date.prefix(4)).\(date.dropFirst(4).prefix(2)).\(date.suffix(2))"
    }

    /// Les images de cloud que la page du dossier nomme, **l'instantané le
    /// plus récent d'abord** — trié par date, pas par nom : le numéro d'image
    /// qui le précède peut changer sans que l'instantané soit plus neuf.
    public static func openSUSECandidates(_ listing: String) -> [(file: String, version: String)] {
        var found: [(file: String, version: String)] = []
        for piece in listing.components(separatedBy: "href=\"").dropFirst() {
            guard let end = piece.firstIndex(of: "\"") else { continue }
            var file = String(piece[..<end])
            // La page d'openSUSE écrit ses liens `./nom`.
            if file.hasPrefix("./") { file.removeFirst(2) }
            guard isPlainName(file), let version = isBootableOpenSUSE(file),
                  !found.contains(where: { $0.file == file }) else { continue }
            found.append((file, version))
        }
        return found.sorted { $0.version > $1.version }
    }

    /// Une image d'openSUSE Tumbleweed, une fois sa taille connue.
    /// `download.opensuse.org` renvoie vers un miroir : l'adresse donnée est
    /// la sienne, la redirection est suivie au téléchargement.
    public static func openSUSERelease(file: String, version: String, sha256: String, size: Int,
                                       index: URL = openSUSEIndex) -> Release {
        Release(distribution: "openSUSE Tumbleweed", flavor: "opensuse-cloud", title: "image de cloud (qcow2)",
                version: version, arch: "x86_64", file: file, size: size,
                checksum: .sha256(sha256), index: index, link: index.appendingPathComponent(file))
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
