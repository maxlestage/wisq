import Foundation

/// **Un bureau prêt** : une image publiée par sa distribution, et une archive
/// `.wisqmachine` qui porte ce bureau déjà démarré par wisq, puis mis en
/// pause (`ReadyDesktopBuild`, `wisq-fabrique`). Téléchargés tous les deux,
/// le bureau s'ouvre en moins d'une minute, au lieu de la demi-heure que le
/// bureau Xfce met à démarrer sous l'interprète.
///
/// Rien ici n'est écrit en dur sauf l'adresse de l'index (`index`) et les
/// hôtes qu'on en accepte : la liste vient d'un fichier `bureaux.json`
/// publié comme asset d'une release du dépôt, lu à l'ouverture de la feuille
/// « Télécharger », comme les index des distributions.
///
/// **L'index vient du réseau**, et il est lu comme tel : une entrée dont une
/// adresse sort des hôtes attendus, dont un nom contient un chemin, dont une
/// somme n'a pas la forme d'une somme, ou qui demande une machine plus
/// récente que celle de cette version (`X86Machine.snapshotLevel`), n'est pas
/// proposée. **Un index absent n'est pas une panne** : tant que la release
/// n'existe pas, la section ne se montre pas, et rien d'autre ne change.
public struct ReadyDesktop: Equatable, Sendable {
    /// « Void Xfce (prêt) » : ce que la liste écrit.
    public let title: String
    /// Le niveau de machine de la fabrication : une application plus ancienne
    /// ne saurait pas reprendre l'instantané (`SavedSession`).
    public let level: UInt64
    /// La mémoire de la session : refusée avant de télécharger quand le
    /// téléphone ne peut pas la donner.
    public let ramBytes: UInt64
    /// L'empreinte du noyau que l'image donne (`ReadyDesktopBuild.kernelDigest`) :
    /// c'est elle qui nomme la session dans l'archive.
    public let kernelDigest: String
    public let madeAt: Date
    /// L'image, à l'adresse **datée** de sa distribution : l'instantané ne
    /// vaut que pour cette image-là.
    public let image: ImageDownload.Release
    /// L'archive, asset d'une release du dépôt.
    public let archive: ImageDownload.Release

    /// **L'adresse de l'index.** Une release de données à part, qui ne suit
    /// pas les versions de l'application (et n'est pas « latest » : voir
    /// `.github/workflows/bureaux.yml`).
    public static let index = URL(
        string: "https://github.com/maxlestage/wisq/releases/download/bureaux-1/bureaux.json")!

    /// Les hôtes d'où une image peut venir : le miroir de Void, celui que
    /// la feuille lit déjà (`ImageDownload.voidIndex`).
    public static let imageHosts: Set<String> = ["repo-default.voidlinux.org"]
    /// Les hôtes d'où une archive peut venir : les releases de GitHub, et
    /// l'hôte vers lequel GitHub renvoie ses assets.
    public static let archiveHosts: Set<String> = ["github.com", "objects.githubusercontent.com"]
    /// Sur `github.com`, les releases **de ce dépôt** seulement.
    static let releasePath = ["/", "maxlestage", "wisq", "releases", "download"]
    /// **La plus grande taille qu'une entrée peut annoncer**, image ou
    /// archive : 64 Gio, bien au-delà de l'ISO de 1,4 Gio et de ce qu'un
    /// téléphone range. Sans plafond, deux tailles proches d'`Int.max / 2`
    /// passaient, et leur somme (`sizePhrase`, `fetch`) faisait tomber
    /// l'application dès l'ouverture de la feuille.
    public static let largestFile = 64 << 30

    // MARK: - L'index

    /// **Le format de `bureaux.json`**, écrit par `wisq-fabrique index` et
    /// lu ici : une seule définition pour les deux côtés.
    public struct Index: Codable, Equatable, Sendable {
        public var format: Int
        public var desktops: [Entry]

        public init(format: Int = 1, desktops: [Entry]) {
            self.format = format
            self.desktops = desktops
        }

        public struct Entry: Codable, Equatable, Sendable {
            public var title: String
            public var level: UInt64
            public var ramBytes: UInt64
            public var kernelDigest: String
            public var madeAt: Date
            public var image: Link
            public var archive: Link

            public init(title: String, level: UInt64, ramBytes: UInt64, kernelDigest: String,
                        madeAt: Date, image: Link, archive: Link) {
                self.title = title
                self.level = level
                self.ramBytes = ramBytes
                self.kernelDigest = kernelDigest
                self.madeAt = madeAt
                self.image = image
                self.archive = archive
            }

            /// L'entrée d'un bureau fabriqué, d'après sa fiche, aux adresses
            /// où l'image et l'archive sont publiées.
            public init(sheet: ReadyDesktopBuild.Sheet, image: URL, archive: URL) {
                self.init(title: sheet.title, level: sheet.level, ramBytes: sheet.ramBytes,
                          kernelDigest: sheet.kernelDigest, madeAt: sheet.madeAt,
                          image: Link(sheet.image, url: image), archive: Link(sheet.archive, url: archive))
            }
        }

        /// Un fichier publié : son nom, sa taille, sa somme, son adresse.
        /// L'adresse est une chaîne, pas une `URL` : son encodage JSON n'est
        /// pas le même partout.
        public struct Link: Codable, Equatable, Sendable {
            public var name: String
            public var bytes: Int
            public var sha256: String
            public var url: String

            public init(name: String, bytes: Int, sha256: String, url: String) {
                self.name = name
                self.bytes = bytes
                self.sha256 = sha256
                self.url = url
            }

            init(_ file: ReadyDesktopBuild.Sheet.File, url: URL) {
                self.init(name: file.name, bytes: Int(clamping: file.bytes), sha256: file.sha256,
                          url: url.absoluteString)
            }
        }

        /// **Le nouvel index, et ce qu'il garde de l'ancien** : une entrée
        /// neuve remplace celle du même titre et du même niveau ; les autres
        /// restent. Un bureau d'un niveau neuf ne retire donc pas celui que les
        /// applications d'avant savent encore reprendre — à condition qu'il
        /// ne prenne pas son adresse (`clashes`).
        public func merged(keeping old: Index) -> Index {
            let kept = old.desktops.filter { previous in
                !desktops.contains { $0.title == previous.title && $0.level == previous.level }
            }
            return Index(format: format, desktops: desktops + kept)
        }

        /// **Une adresse, un fichier** : les adresses où l'index annonce deux
        /// fichiers différents (une autre taille, ou une autre somme), dans
        /// l'ordre où elles paraissent. Une même ISO pour deux niveaux est
        /// permise ; une même archive, non : l'asset republié sous le même nom
        /// a remplacé l'ancien, et l'entrée gardée promet une somme qu'il n'a
        /// plus. L'application d'avant téléchargeait alors l'archive neuve, la
        /// trouvait fausse, l'effaçait, et recommençait à chaque essai.
        public var clashes: [String] {
            var seen: [String: (bytes: Int, sha256: String)] = [:]
            var clashing: [String] = []
            for link in desktops.flatMap({ [$0.image, $0.archive] }) {
                let file = (bytes: link.bytes, sha256: link.sha256.lowercased())
                if let previous = seen[link.url] {
                    if previous != file, !clashing.contains(link.url) { clashing.append(link.url) }
                } else {
                    seen[link.url] = file
                }
            }
            return clashing
        }

        /// Pourquoi un index n'est pas écrit.
        public enum Fault: Error, Equatable, CustomStringConvertible {
            /// L'application écarterait cette entrée (`refused`).
            case refused(title: String, url: String)
            /// Deux fichiers différents à cette adresse (`clashes`).
            case clash(url: String)

            public var description: String {
                switch self {
                case .refused(let title, let url):
                    return "l'application écarterait « \(title) » (\(url)) : index non écrit"
                case .clash(let url):
                    return "deux fichiers différents annoncés à la même adresse (\(url)) : l'un a remplacé "
                        + "l'autre dans la release ; index non écrit"
                }
            }
        }

        /// **L'index que la fabrique publie** : les entrées neuves, jugées
        /// comme l'application les jugera, puis l'ancien gardé (`merged`),
        /// puis l'adresse de chaque fichier vérifiée unique (`clashes`). Une
        /// faute arrête tout avant que rien ne parte dans une release.
        public static func publishable(_ fresh: Index, keeping old: Index? = nil) throws -> Index {
            if let refused = fresh.refused.first {
                throw Fault.refused(title: refused.title, url: refused.archive.url)
            }
            let index = old.map(fresh.merged(keeping:)) ?? fresh
            if let url = index.clashes.first { throw Fault.clash(url: url) }
            return index
        }

        /// **Les entrées que l'application écarterait** (`parse`), chacune
        /// jugée à son propre niveau : de quoi refuser d'écrire un index dont
        /// une entrée ne serait jamais proposée.
        public var refused: [Entry] {
            desktops.filter { entry in
                ReadyDesktop.desktop(from: entry, index: ReadyDesktop.index,
                                     supportedLevel: max(entry.level, 1)) == nil
            }
        }

        /// En JSON lisible, clés triées, dates ISO 8601.
        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(self)
        }

        /// L'index tel qu'il est écrit, sans rien juger : c'est `parse` qui
        /// trie ce qui se propose.
        public static func decode(_ data: Data) throws -> Index {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Index.self, from: data)
        }
    }

    /// **Les bureaux que cette application peut proposer**, lus dans
    /// l'index. Une entrée fautive est écartée seule, pas tout l'index ; un
    /// index illisible, ou d'un autre format, ne propose rien.
    ///
    /// **Un par titre** : le plus haut niveau que cette version sait
    /// reprendre, puis le plus récent. Un index peut porter le bureau d'un
    /// niveau neuf à côté de celui d'avant (`Index.merged`).
    ///
    /// **Une adresse où deux entrées valables annoncent deux fichiers**
    /// (`Index.clashes`) n'en propose aucun : l'un des deux est forcément
    /// faux, et c'est celui qu'on téléchargerait en boucle.
    public static func parse(_ json: String, index: URL = ReadyDesktop.index,
                             supportedLevel: UInt64 = X86Machine.snapshotLevel) -> [ReadyDesktop] {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              (root["format"] as? NSNumber)?.intValue == 1,
              let list = root["desktops"] as? [Any]
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = list.compactMap { item -> Index.Entry? in
            guard item is [String: Any], let data = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? decoder.decode(Index.Entry.self, from: data)
        }
        // Les adresses en conflit, entre entrées valables seulement — chacune
        // jugée à son propre niveau, comme `Index.refused` : une entrée
        // fautive ne se télécharge jamais, et n'emporte pas la propre d'à côté.
        let valid = entries.filter {
            desktop(from: $0, index: index, supportedLevel: max($0.level, 1)) != nil
        }
        let clashing = Set(Index(desktops: valid).clashes)
        var chosen: [ReadyDesktop] = []
        for entry in entries {
            guard !clashing.contains(entry.image.url), !clashing.contains(entry.archive.url),
                  let desktop = desktop(from: entry, index: index, supportedLevel: supportedLevel)
            else { continue }
            if let same = chosen.firstIndex(where: { $0.title == desktop.title }) {
                let other = chosen[same]
                if (desktop.level, desktop.madeAt) > (other.level, other.madeAt) { chosen[same] = desktop }
            } else {
                chosen.append(desktop)
            }
        }
        return chosen
    }

    /// Une entrée, jugée.
    static func desktop(from entry: Index.Entry, index: URL, supportedLevel: UInt64) -> ReadyDesktop? {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = entry.kernelDigest.lowercased()
        guard !title.isEmpty, title.count <= 80, !title.contains(where: \.isNewline),
              (1...supportedLevel).contains(entry.level),
              ReadyDesktopBuild.isRecordable(Int(clamping: entry.ramBytes)),
              (1...16).contains(digest.count), digest.allSatisfy(ImageDownload.isASCIIHexDigit),
              // L'archive est une machine, l'image n'en est pas une : la
              // bibliothèque ne doit jamais recevoir l'archive.
              entry.archive.name.hasSuffix("." + MachineArchive.fileExtension),
              !entry.image.name.hasSuffix("." + MachineArchive.fileExtension),
              let image = link(entry.image, hosts: imageHosts),
              let archive = link(entry.archive, hosts: archiveHosts)
        else { return nil }
        let day = dayStamp(entry.madeAt)
        return ReadyDesktop(
            title: title, level: entry.level, ramBytes: entry.ramBytes, kernelDigest: digest,
            madeAt: entry.madeAt,
            image: ImageDownload.Release(
                distribution: title, flavor: "ready-image", title: "image", version: day, arch: "x86_64",
                file: entry.image.name, size: entry.image.bytes, checksum: .sha256(image.sha256),
                index: index, link: image.url),
            archive: ImageDownload.Release(
                distribution: title, flavor: "ready-archive", title: "bureau prêt", version: day,
                arch: "x86_64", file: entry.archive.name, size: entry.archive.bytes,
                checksum: .sha256(archive.sha256), index: index, link: archive.url))
    }

    /// **Une adresse qu'on accepte** : HTTPS, sur un hôte attendu, sans
    /// port, ni identifiants, ni requête, ni `..` ; son dernier segment est
    /// le nom du fichier, et ce nom n'est qu'un nom (`ImageDownload.isPlainName`).
    /// Sur `github.com`, une release de ce dépôt, et rien d'autre. Une taille
    /// entre un octet et `largestFile`.
    static func link(_ link: Index.Link, hosts: Set<String>) -> (url: URL, sha256: String)? {
        let sha256 = link.sha256.lowercased()
        guard let url = URL(string: link.url), url.scheme == "https",
              let host = url.host?.lowercased(), hosts.contains(host),
              url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !url.pathComponents.contains(where: { $0 == ".." || $0 == "." }),
              url.lastPathComponent == link.name, ImageDownload.isPlainName(link.name),
              ImageDownload.isHexDigest(sha256), (1...largestFile).contains(link.bytes)
        else { return nil }
        if host == "github.com" {
            guard url.pathComponents.count == releasePath.count + 2,
                  Array(url.pathComponents.prefix(releasePath.count)) == releasePath
            else { return nil }
        }
        return (url, sha256)
    }

    // MARK: - Ce que la feuille en dit

    /// Le téléphone peut-il lui donner sa mémoire ? `ceiling` est le plafond
    /// du moment (`KernelMemory.ceiling`).
    public func fits(ceiling: UInt64) -> Bool { ramBytes <= ceiling }

    /// « Démarré par wisq le 14 novembre 2026, puis mis en pause : prêt en
    /// moins d'une minute. »
    public var madePhrase: String {
        "Démarré par wisq le \(Self.frenchDate(madeAt)), puis mis en pause : prêt en moins d'une minute, "
            + "au lieu d'une demi-heure de démarrage."
    }

    /// Ce qu'il reste à télécharger, l'image comptée seulement si elle
    /// manque.
    public func sizePhrase(imagePresent: Bool) -> String {
        let archiveSize = LocalStorage.describe(bytes: archive.size)
        if imagePresent {
            return "À télécharger : \(archiveSize) (le bureau). L'image est déjà dans la bibliothèque."
        }
        return "À télécharger : \(LocalStorage.describe(bytes: image.size + archive.size)), "
            + "soit l'image (\(LocalStorage.describe(bytes: image.size))) et le bureau (\(archiveSize))."
    }

    /// La mémoire qu'il lui faut, ou pourquoi ce téléphone ne peut pas la
    /// donner.
    public func memoryPhrase(ceiling: UInt64) -> String {
        let needed = KernelMemory.describe(ramBytes)
        guard fits(ceiling: ceiling) else {
            return "Il lui faut \(needed) de mémoire ; ce téléphone peut en donner \(KernelMemory.describe(ceiling))."
        }
        return "Il lui faut \(needed) de mémoire."
    }

    /// Ce qu'il faut savoir d'un bureau prêt, dit une fois sous la section.
    public static let sharedNote = """
        Un bureau prêt est le même pour tous ceux qui le téléchargent, mots de passe compris \
        (voidlinux) : changez-les si vous ouvrez un service. Ses clés SSH sont refaites sur chaque \
        téléphone. Fermer l'écran le met en pause ; l'arrêter le fait repartir de zéro, et le \
        démarrage prend alors une demi-heure.
        """

    static let months = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août",
                         "septembre", "octobre", "novembre", "décembre"]

    /// La date en français, en UTC : la fiche date la fabrication en UTC, et
    /// les noms de mois ne dépendent pas des réglages du téléphone.
    static func frenchDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = parts.day ?? 1
        return "\(day == 1 ? "1er" : String(day)) \(months[(parts.month ?? 1) - 1]) \(parts.year ?? 0)"
    }

    /// `AAAA.MM.JJ`, comme les versions des autres images.
    static func dayStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d.%02d.%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Les deux téléchargements

    /// Où en sont les deux téléchargements : l'étape, puis les octets reçus
    /// sur le total des deux — un seul progrès, qui ne revient pas à zéro
    /// entre l'image et l'archive.
    public struct Progress: Equatable, Sendable {
        public enum Step: Equatable, Sendable { case image, archive }
        public let step: Step
        /// Le numéro de l'étape, et combien il y en a : deux, ou une seule
        /// quand l'image est déjà là.
        public let number: Int
        public let steps: Int
        public let have: Int
        public let total: Int

        public init(step: Step, number: Int, steps: Int, have: Int, total: Int) {
            self.step = step
            self.number = number
            self.steps = steps
            self.have = have
            self.total = total
        }

        /// « Étape 1 sur 2 : l'image — 300,0 Mio sur 1,5 Gio »
        public var phrase: String {
            let what = step == .image ? "l'image" : "le bureau"
            return "Étape \(number) sur \(steps) : \(what) — "
                + "\(LocalStorage.describe(bytes: have)) sur \(LocalStorage.describe(bytes: total))"
        }
    }

    /// L'image est-elle déjà dans `library`, à sa taille ? Sa somme n'est
    /// pas refaite (1,4 Gio sur un téléphone) : c'est l'empreinte de son
    /// noyau, vérifiée à l'installation, qui dit si c'est la bonne.
    public func imagePresent(in library: URL) -> Bool {
        Self.size(of: library.appendingPathComponent(image.file)) == image.size
    }

    /// L'archive est-elle déjà là, entière et à sa somme ? Une tâche
    /// d'arrière-plan a pu la finir pendant que l'application dormait.
    func archivePresent(in downloads: URL) -> Bool {
        let url = downloads.appendingPathComponent(archive.file)
        guard Self.size(of: url) == archive.size else { return false }
        return (try? archive.checksum.hex(ofFileAt: url)) == archive.checksum.expected
    }

    static func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    /// **L'image, puis l'archive**, chacune par `download` — le
    /// téléchargement vérifié de la feuille (`ImageDownloader`, ou la
    /// session d'arrière-plan), qui reprend un transfert coupé et efface un
    /// fichier à la somme fausse. L'image va dans la bibliothèque, l'archive
    /// dans les téléchargements (`ImageDownload.Destination`). Ce qui est déjà
    /// là n'est pas redemandé.
    ///
    /// Une coupure de l'archive garde l'image : le prochain essai ne reprend
    /// que l'archive, là où elle s'était arrêtée.
    ///
    /// **`replacedImage` est appelé dès que l'image a remplacé un fichier du
    /// même nom**, d'une autre taille (`KernelLibrary.replaced` : ce qui
    /// avait été écrit sur l'ancien ne vaut plus rien), avant l'archive. Le
    /// dire après les deux le perdait quand l'archive tombait : l'essai
    /// suivant trouvait l'image à sa taille, et ne le disait plus jamais.
    public func fetch(
        library: URL, downloads: URL,
        download: @Sendable (ImageDownload.Release, ImageDownload.Destination,
                             @escaping @Sendable (Int, Int) -> Void) async throws -> URL,
        progress: @escaping @Sendable (Progress) -> Void = { _ in },
        replacedImage: @Sendable (String) -> Void = { _ in }
    ) async throws -> (image: URL, archive: URL) {
        let needImage = !imagePresent(in: library)
        let replacing = needImage
            && FileManager.default.fileExists(atPath: library.appendingPathComponent(image.file).path)
        let needArchive = !archivePresent(in: downloads)
        let steps = (needImage ? 1 : 0) + (needArchive ? 1 : 0)
        let total = (needImage ? image.size : 0) + (needArchive ? archive.size : 0)
        let imageSize = image.size, archiveSize = archive.size
        if needImage {
            _ = try await download(image, .library) { have, _ in
                progress(Progress(step: .image, number: 1, steps: steps, have: min(have, imageSize), total: total))
            }
            if replacing { replacedImage(image.file) }
        }
        if needArchive {
            let offset = needImage ? imageSize : 0
            let number = needImage ? 2 : 1
            _ = try await download(archive, .downloads) { have, _ in
                progress(Progress(step: .archive, number: number, steps: steps,
                                  have: offset + min(have, archiveSize), total: total))
            }
        }
        return (library.appendingPathComponent(image.file), downloads.appendingPathComponent(archive.file))
    }

    // MARK: - L'installation

    /// Pourquoi un bureau prêt téléchargé n'a pas été installé.
    public enum Refusal: Error, Equatable, LocalizedError {
        /// L'image n'est plus dans la bibliothèque.
        case missingImage(String)
        /// Le noyau de l'image présente n'est pas celui de la fabrication :
        /// la session ne serait jamais trouvée.
        case wrongKernel(expected: String, found: String?)
        /// L'archive démarre une autre image que celle de l'index.
        case archiveForAnotherImage(String)
        /// L'archive ne porte pas de session sous l'empreinte du noyau.
        case noSession(String)

        public var errorDescription: String? {
            switch self {
            case .missingImage(let image):
                return "L'image \(image) n'est plus dans la bibliothèque ; le bureau prêt n'a pas été installé."
            case .wrongKernel(_, nil):
                return "Le noyau de l'image ne s'est pas laissé lire : le bureau ne pourrait pas "
                    + "reprendre. Rien n'a été installé."
            case .wrongKernel:
                return "L'image présente n'a pas le noyau avec lequel ce bureau a été démarré : "
                    + "il ne pourrait pas reprendre. Rien n'a été installé."
            case .archiveForAnotherImage(let image):
                return "Ce bureau prêt a été fait pour une autre image (\(image)) ; rien n'a été installé."
            case .noSession:
                return "Ce bureau prêt ne porte pas de bureau démarré pour cette image ; rien n'a été installé."
            }
        }
    }

    /// **Installer le bureau téléchargé** : vérifier, puis importer
    /// l'archive (`MachineArchive.import`), sous une clé neuve.
    ///
    /// Deux gardes avant l'import, parce qu'un import qui réussit ne prouve
    /// rien ici : une archive faite pour une autre image, ou dont la session
    /// ne porte pas l'empreinte du noyau de l'image présente, s'importerait
    /// sans erreur, et la machine démarrerait **à froid**, une demi-heure,
    /// sans dire pourquoi. `imageKernelDigest` est l'empreinte du noyau que
    /// l'image présente donne, sortie par le code du démarrage
    /// (`IsoBoot.kernelDigest`, que `WisqVM` ne voit pas) ; `nil` quand
    /// l'image ne s'est pas laissé lire.
    ///
    /// **L'archive est effacée ensuite**, installée ou refusée : quelques
    /// centaines de mégaoctets qui ne servent plus — la machine installée
    /// porte ce qu'elle contenait.
    @discardableResult
    public func install(
        archive file: URL, imageKernelDigest: String?, library: [String], in directory: URL? = nil,
        now: Date = Date(), id: String = InstalledMachines.newIdentifier(),
        createOwnDisk: (String, UInt64) throws -> String
    ) throws -> InstalledMachine {
        defer { try? FileManager.default.removeItem(at: file) }
        guard library.contains(image.file) else { throw Refusal.missingImage(image.file) }
        guard imageKernelDigest?.lowercased() == kernelDigest else {
            throw Refusal.wrongKernel(expected: kernelDigest, found: imageKernelDigest)
        }
        let contents = try MachineArchive.contents(of: file)
        guard contents.image == image.file else { throw Refusal.archiveForAnotherImage(contents.image) }
        guard contents.sessions.contains(kernelDigest) else { throw Refusal.noSession(kernelDigest) }
        return try MachineArchive.import(
            from: file, library: library, in: directory, now: now, id: id, createOwnDisk: createOwnDisk)
    }
}
