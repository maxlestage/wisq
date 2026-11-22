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
///
/// **Deux cœurs, deux entrées.** Un bureau fabriqué sur la machine PC en Rust
/// (`Core.rust`) est un instantané `WISQPC\r\n` que seul ce cœur reprend ; un
/// bureau du cœur Swift, un instantané d'`X86Machine`. L'index porte les deux
/// sous le même titre, chacune avec son cœur, et l'application prend celle
/// que son cœur sait reprendre (`parse`, `rustLevel`).
public struct ReadyDesktop: Equatable, Sendable {
    /// « Void Xfce (prêt) » : ce que la liste écrit.
    public let title: String
    /// Le cœur qui reprend l'instantané : une session choisit son cœur par
    /// son format (`RustPCSetting.runs`), et c'est ce cœur-là qu'il faut.
    public let core: Core
    /// Le niveau de machine de la fabrication : une application plus ancienne
    /// ne saurait pas reprendre l'instantané (`SavedSession`). Pour le cœur
    /// Swift, `X86Machine.snapshotLevel` ; pour le cœur Rust, la version de
    /// son instantané (`RustPCSnapshot.version`).
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

    // MARK: - Le cœur

    /// **Le cœur qui reprend l'instantané d'une entrée.** Écrit dans l'index
    /// (`"core"`) ; une entrée qui ne le dit pas vient d'avant, et c'est un
    /// instantané du cœur Swift. Un cœur que cette version ne connaît pas
    /// n'est pas décodé : l'entrée est écartée seule (`parse`).
    public enum Core: String, Codable, Equatable, Sendable {
        case swift
        case rust

        /// **Le plus haut niveau que lisent les applications d'avant ce
        /// champ** : elles ignorent `core`, et ne jugent une entrée que par
        /// son niveau, de 1 à `X86Machine.snapshotLevel` — 1 pour toutes
        /// celles qui sont publiées. Une entrée Rust de ce niveau leur serait
        /// proposée, téléchargée, puis reprise par le cœur Swift, qui ne lit
        /// pas un instantané `WISQPC\r\n` : une session abîmée.
        public static let levelSeenByOlderApps: UInt64 = 1

        /// Le plus petit niveau d'une entrée Rust : au-dessus de ce que les
        /// applications d'avant acceptent. C'est aussi la première version de
        /// l'instantané du cœur Rust qui se reprend (la 1 est refusée).
        public static let firstRustLevel: UInt64 = levelSeenByOlderApps + 1
    }

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
            /// Le cœur que l'instantané demande ; absent des entrées d'avant,
            /// qui sont du cœur Swift (`machineCore`).
            public var core: Core?
            public var level: UInt64
            public var ramBytes: UInt64
            public var kernelDigest: String
            public var madeAt: Date
            public var image: Link
            public var archive: Link

            public init(title: String, level: UInt64, ramBytes: UInt64, kernelDigest: String,
                        madeAt: Date, image: Link, archive: Link, core: Core? = nil) {
                self.title = title
                self.core = core
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
                          image: Link(sheet.image, url: image), archive: Link(sheet.archive, url: archive),
                          core: sheet.core)
            }

            /// Le cœur de l'entrée : celui qu'elle dit, le cœur Swift sinon.
            public var machineCore: Core { core ?? .swift }
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
        /// neuve remplace celle du même titre, du même cœur et du même
        /// niveau ; les autres restent. Un bureau d'un niveau neuf ne retire
        /// donc pas celui que les applications d'avant savent encore reprendre
        /// — à condition qu'il ne prenne pas son adresse (`clashes`) —, et le
        /// bureau du cœur Rust ne retire pas celui du cœur Swift.
        public func merged(keeping old: Index) -> Index {
            let kept = old.desktops.filter { previous in
                !desktops.contains {
                    $0.title == previous.title && $0.machineCore == previous.machineCore
                        && $0.level == previous.level
                }
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
        /// une entrée ne serait jamais proposée. **Une entrée Rust d'un niveau
        /// que lisent les applications d'avant** (`Core.levelSeenByOlderApps`)
        /// en est une : elles la prendraient pour un bureau du cœur Swift.
        public var refused: [Entry] {
            desktops.filter { !ReadyDesktop.isValidAtItsOwnLevel($0) }
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
    /// **Un par titre** : celui du cœur Rust quand cette application le fait
    /// tourner (`rustLevel`, la version d'instantané qu'il reprend, ou `nil`
    /// sans cœur Rust ou réglage éteint), sinon celui du cœur Swift ; puis le
    /// plus haut niveau que cette version sait reprendre, puis le plus
    /// récent. Un index peut porter le bureau d'un niveau neuf à côté de
    /// celui d'avant (`Index.merged`), et celui d'un cœur à côté de celui de
    /// l'autre. **Il retombe proprement** : un index qui n'a que l'entrée
    /// Swift la propose au cœur Rust aussi (la session du cœur Swift s'y
    /// reprend, sur le cœur Swift) ; un index qui n'a que l'entrée Rust ne
    /// propose rien sans cœur Rust.
    ///
    /// **Une adresse où deux entrées valables annoncent deux fichiers**
    /// (`Index.clashes`) n'en propose aucun : l'un des deux est forcément
    /// faux, et c'est celui qu'on téléchargerait en boucle.
    public static func parse(_ json: String, index: URL = ReadyDesktop.index,
                             supportedLevel: UInt64 = X86Machine.snapshotLevel,
                             rustLevel: UInt64? = nil) -> [ReadyDesktop] {
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
        let valid = entries.filter { isValidAtItsOwnLevel($0, index: index) }
        let clashing = Set(Index(desktops: valid).clashes)
        var chosen: [ReadyDesktop] = []
        for entry in entries {
            guard !clashing.contains(entry.image.url), !clashing.contains(entry.archive.url),
                  let desktop = desktop(from: entry, index: index, supportedLevel: supportedLevel,
                                        rustLevel: rustLevel)
            else { continue }
            if let same = chosen.firstIndex(where: { $0.title == desktop.title }) {
                if desktop.rank > chosen[same].rank { chosen[same] = desktop }
            } else {
                chosen.append(desktop)
            }
        }
        return chosen
    }

    /// L'ordre entre deux bureaux du même titre : le cœur Rust d'abord (une
    /// entrée Rust n'est valable que pour une application qui le fait
    /// tourner), puis le niveau, puis la date.
    var rank: (Int, UInt64, Date) { (core == .rust ? 1 : 0, level, madeAt) }

    /// **Une entrée jugée à son propre niveau**, comme si l'application
    /// savait le reprendre, et faisait tourner le cœur Rust : ce qui reste à
    /// juger, c'est la forme. Une entrée Rust d'un niveau que lisent les
    /// applications d'avant reste refusée (`Core.firstRustLevel`).
    static func isValidAtItsOwnLevel(_ entry: Index.Entry, index: URL = ReadyDesktop.index) -> Bool {
        desktop(from: entry, index: index, supportedLevel: max(entry.level, 1),
                rustLevel: max(entry.level, Core.firstRustLevel)) != nil
    }

    /// **Ce texte est-il un index des bureaux**, d'un format ou d'un autre ?
    /// Un objet JSON qui porte son numéro de format. Un index d'un format
    /// plus récent ne propose rien à cette version (`parse`), sans que ce
    /// soit une panne ; une page HTML rendue à sa place en est une.
    public static func isIndex(_ json: String) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return false
        }
        return root["format"] is NSNumber
    }

    /// Une entrée, jugée. Son niveau l'est contre le cœur qu'elle demande :
    /// de 1 à `supportedLevel` pour le cœur Swift ; de `Core.firstRustLevel`
    /// à `rustLevel` pour le cœur Rust, et jamais sans lui (`rustLevel` nil).
    static func desktop(from entry: Index.Entry, index: URL, supportedLevel: UInt64,
                        rustLevel: UInt64? = nil) -> ReadyDesktop? {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = entry.kernelDigest.lowercased()
        let levelReadable: Bool
        switch entry.machineCore {
        case .swift: levelReadable = entry.level >= 1 && entry.level <= supportedLevel
        case .rust:
            guard let rustLevel else { return nil }
            levelReadable = entry.level >= Core.firstRustLevel && entry.level <= rustLevel
        }
        guard !title.isEmpty, title.count <= 80, !title.contains(where: \.isNewline),
              levelReadable,
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
            title: title, core: entry.machineCore, level: entry.level, ramBytes: entry.ramBytes,
            kernelDigest: digest,
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
    ///
    /// **`available` est la place libre du téléphone** (`LocalStorage.availableBytes`),
    /// lue juste avant : quand elle ne suffit pas à ce qu'il reste à recevoir,
    /// à recoudre et à installer (`room`), rien n'est demandé, et le refus
    /// dit combien il faut libérer (`Refusal.notEnoughSpace`). Sans cette
    /// garde, 1,4 Gio partaient, et le téléphone plein faisait tomber
    /// l'écriture au milieu de l'image, ou l'import après les deux
    /// téléchargements. `nil` : la place ne s'est pas laissé lire, et rien
    /// n'est refusé sur une supposition.
    ///
    /// **`running` sont les fichiers que la session d'arrière-plan a en
    /// cours** (`backgroundFiles`). Quand l'un d'eux est à ce bureau et
    /// manque encore (`followable`), **lui seul** échappe à la garde : ce
    /// transfert a déjà pris de la place dans le fichier de la session, que
    /// `room` ne voit pas, et `fetch` ne fait que le suivre. Le reste — le
    /// fichier qui n'a pas commencé, et l'installation — se compte encore
    /// (`room(library:downloads:running:)`). Lever la garde pour tout le
    /// bureau laissait partir toute l'ISO, ou l'archive, sur un téléphone à
    /// un octet libre, jusqu'à l'erreur du système. Le refus dit alors que
    /// le transfert en cours continue, au lieu de « Rien n'a été
    /// téléchargé » : la session le range à sa fin, sans la feuille. Un
    /// fichier déjà rangé à sa taille, lui, ne court plus, quoi que dise un
    /// relevé ancien : il ne se met pas à part.
    ///
    /// **Une annulation entre les deux fichiers arrête là** : l'image finie
    /// au moment où « Annuler » est touché ne lance pas l'archive.
    public func fetch(
        library: URL, downloads: URL, available: Int? = nil, running: Set<String> = [],
        download: @Sendable (ImageDownload.Release, ImageDownload.Destination,
                             @escaping @Sendable (Int, Int) -> Void) async throws -> URL,
        progress: @escaping @Sendable (Progress) -> Void = { _ in },
        replacedImage: @Sendable (String) -> Void = { _ in }
    ) async throws -> (image: URL, archive: URL) {
        if let available, let refusal = spaceRefusal(available: available, library: library,
                                                     downloads: downloads, running: running) {
            throw refusal
        }
        // Annulée avant même de commencer : rien n'est demandé. Sans ce
        // relevé, le premier morceau de l'image s'écrivait avant que
        // l'annulation ne se voie, dans le flux de `download`.
        try Task.checkCancellation()
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
            // L'image a pu finir au moment même où « Annuler » était touché :
            // son téléchargement rend alors le fichier sans lever, et
            // l'archive partait quand même.
            try Task.checkCancellation()
            let offset = needImage ? imageSize : 0
            let number = needImage ? 2 : 1
            _ = try await download(archive, .downloads) { have, _ in
                progress(Progress(step: .archive, number: number, steps: steps,
                                  have: offset + min(have, archiveSize), total: total))
            }
        }
        return (library.appendingPathComponent(image.file), downloads.appendingPathComponent(archive.file))
    }

    // MARK: - La place

    /// **La place que le bureau demande au téléphone** : ce qu'il reste à
    /// recevoir de chaque fichier, et ce que l'installation et la première
    /// sauvegarde écrivent ensuite.
    ///
    /// **Le total est celui du moment le plus lourd**, pas une somme. La
    /// session d'arrière-plan rend chaque fichier entier, dans le sien ;
    /// `ImageDownloader.adopt` le recopie alors sur le `.part`, morceau par
    /// morceau, pendant que le fichier de la session existe encore. Ce qui
    /// restait à recevoir d'un fichier occupe donc, un moment, **deux fois**
    /// sa place. Pour l'image de 1,4 Gio, c'est le pic : 2,69 Gio, quand la
    /// somme « à télécharger plus à installer » n'en comptait que 2,06, et
    /// un téléphone qui avait 2,3 Gio libres recevait toute l'image pour
    /// tomber à sa recopie.
    ///
    /// Les trois moments, dans l'ordre où `fetch` et l'installation les
    /// traversent : l'image recopiée (deux fois ce qui en restait) ; le
    /// bureau recopié (l'image rangée, plus deux fois ce qui restait du
    /// bureau) ; l'installation (les deux reçus, plus `install`). Une
    /// reprise que le serveur refuserait (un `200` au lieu d'un `206`)
    /// recevrait tout le fichier au lieu de ce qui manquait : le compte
    /// suppose des serveurs qui reprennent, comme le miroir de Void et
    /// GitHub.
    public struct Room: Equatable, Sendable {
        /// Ce qu'il reste à recevoir de l'image : rien quand elle est dans
        /// la bibliothèque, sinon sa taille moins ce que son `.part` a déjà.
        public let image: Int
        /// Pareil pour le bureau.
        public let archive: Int
        /// L'import, qui recopie l'archive avant de l'effacer ; la première
        /// sauvegarde, écrite à côté de la session avant de la remplacer ;
        /// et le noyau sorti de l'image pour en prendre l'empreinte.
        public let install: Int
        /// Ce qu'il reste à télécharger, les deux fichiers.
        public var download: Int { image + archive }
        /// Le moment le plus lourd des trois.
        public var total: Int { max(2 * image, image + 2 * archive, download + install) }
        /// La recopie de l'image est-elle ce moment-là ? La phrase du refus
        /// le dit alors, au lieu d'une somme qui ne tombe pas juste.
        var copyIsThePeak: Bool { total > download + install }

        public init(image: Int, archive: Int, install: Int) {
            self.image = image
            self.archive = archive
            self.install = install
        }
    }

    /// Ce que le noyau sorti de l'image peut occuper, au plus, le temps d'en
    /// prendre l'empreinte : le plafond que l'application donne à
    /// `IsoBoot.kernelDigest`.
    public static let digestScratch = 256 << 20

    /// Ce que le `.part` d'un fichier a déjà reçu, borné à sa taille.
    func partHave(_ release: ImageDownload.Release, downloads: URL) -> Int {
        let part = ImageDownload.partURL(for: downloads.appendingPathComponent(release.file))
        return min(Self.size(of: part) ?? 0, release.size)
    }

    /// **La place qu'il faut**, d'après ce qui est déjà là. L'archive est
    /// prise à sa taille, sans refaire sa somme : ceci se lit à chaque
    /// affichage de la feuille.
    public func room(library: URL, downloads: URL) -> Room {
        let image = imagePresent(in: library) ? 0 : self.image.size - partHave(self.image, downloads: downloads)
        let archiveThere = Self.size(of: downloads.appendingPathComponent(archive.file)) == archive.size
        let archive = archiveThere ? 0 : self.archive.size - partHave(self.archive, downloads: downloads)
        return Room(image: image, archive: archive, install: 2 * self.archive.size + Self.digestScratch)
    }

    /// **La place qu'il faut, le transfert déjà en cours mis à part** : ce
    /// qui reste à recevoir d'un fichier que la session d'arrière-plan a en
    /// cours et qui manque encore (`followable`) ne compte pas, sa place est
    /// déjà prise dans le fichier de la session. L'autre fichier et
    /// l'installation comptent, eux, comme dans `room(library:downloads:)`.
    public func room(library: URL, downloads: URL, running: Set<String>) -> Room {
        let whole = room(library: library, downloads: downloads)
        let following = followable(running: running, library: library, downloads: downloads)
        return Room(image: following.contains(image.file) ? 0 : whole.image,
                    archive: following.contains(archive.file) ? 0 : whole.archive,
                    install: whole.install)
    }

    /// Le refus de la place, ou `nil` quand elle suffit : la garde de
    /// `fetch`, et la phrase de `spaceShortfall`.
    func spaceRefusal(available: Int, library: URL, downloads: URL, running: Set<String>) -> Refusal? {
        let room = room(library: library, downloads: downloads, running: running)
        guard room.total > available else { return nil }
        let following = followable(running: running, library: library, downloads: downloads)
        return .notEnoughSpace(room, available: available,
                               following: Set(following.map { $0 == image.file ? .image : .archive }))
    }

    /// La phrase de la feuille quand la place manque, ou `nil` quand elle
    /// suffit : la même que le refus de `fetch`, dite avant qu'on touche.
    /// Un fichier de ce bureau en cours dans la session d'arrière-plan
    /// (`running`) et qui manque encore (`followable`) est mis à part, et
    /// lui seul (voir `fetch`) : quand le reste tient, rien n'est dit, et
    /// « Installer » reste là pour le suivre.
    public func spaceShortfall(available: Int?, library: URL, downloads: URL,
                               running: Set<String> = []) -> String? {
        guard let available else { return nil }
        return spaceRefusal(available: available, library: library, downloads: downloads, running: running)?
            .errorDescription
    }

    /// **Ce qui reste après « Annuler »**, dit tel qu'il est sur le disque :
    /// l'image entière, ou ce que son `.part` a reçu, puis pareil pour le
    /// bureau. Les octets qu'une tâche d'arrière-plan avait reçus sans les
    /// avoir encore rendus ne sont pas comptés : ils ne sont nulle part où le
    /// prochain essai les retrouverait.
    public func keptPhrase(library: URL, downloads: URL) -> String {
        func kept(_ release: ImageDownload.Release, what: String, whole: Bool) -> String? {
            if whole { return "\(what) : entier" }
            let have = partHave(release, downloads: downloads)
            guard have > 0 else { return nil }
            return "\(what) : \(LocalStorage.describe(bytes: have)) sur \(LocalStorage.describe(bytes: release.size))"
        }
        let archiveThere = Self.size(of: downloads.appendingPathComponent(archive.file)) == archive.size
        let parts = [kept(image, what: "l'image", whole: imagePresent(in: library)),
                     kept(archive, what: "le bureau", whole: archiveThere)].compactMap { $0 }
        guard !parts.isEmpty else {
            return "Téléchargement arrêté. Rien n'avait encore été rangé : le prochain essai repartira du début."
        }
        return "Téléchargement arrêté. Gardé — " + parts.joined(separator: " ; ")
            + ". Le prochain essai reprendra là."
    }

    /// **Un téléchargement de ce bureau qui continue en arrière-plan**,
    /// d'après les fichiers que la session d'arrière-plan a encore en cours :
    /// lancé avant que wisq ne soit fermé, ou par une feuille fermée depuis.
    /// La feuille rouverte le dit au lieu de proposer le bureau comme si
    /// rien n'avait commencé. `nil` quand rien de lui n'est en cours.
    ///
    /// Le relevé brut, tel quel : la feuille passe par
    /// `backgroundPhrase(running:library:downloads:available:)`.
    func backgroundPhrase(running files: Set<String>) -> String? {
        let mine = backgroundFiles(running: files)
        let what: String
        if mine.contains(image.file) {
            what = "de l'image"
        } else if mine.contains(archive.file) {
            what = "du bureau"
        } else {
            return nil
        }
        return "Le téléchargement \(what) continue en arrière-plan. Touchez « Installer » pour le suivre : "
            + "il reprend là où il en est, rien n'est redemandé."
    }

    /// **La ligne « continue en arrière-plan » de la feuille.** Seuls les
    /// fichiers en cours qui manquent encore (`followable`) continuent : le
    /// relevé est lu à l'ouverture, et une image rangée depuis, la feuille
    /// ouverte, faisait dire « continue » à côté de la phrase de la place,
    /// qui, elle, la comptait rangée. `library` ou `downloads` illisibles :
    /// le relevé tel quel, rien d'autre ne se lit.
    ///
    /// **Rien non plus quand la place manque au reste** (`spaceShortfall`,
    /// qui la lit dans `available`) : sa phrase dit déjà que le transfert
    /// continue, et « Installer » est éteint. « Touchez « Installer » pour
    /// le suivre » aurait montré un bouton qu'on ne peut pas toucher.
    public func backgroundPhrase(running files: Set<String>, library: URL?, downloads: URL?,
                                 available: Int?) -> String? {
        guard let library, let downloads else { return backgroundPhrase(running: files) }
        guard spaceShortfall(available: available, library: library, downloads: downloads,
                             running: files) == nil else { return nil }
        return backgroundPhrase(running: followable(running: files, library: library, downloads: downloads))
    }

    /// Ceux des fichiers en cours (`running`) qui sont à ce bureau : son
    /// image, son archive.
    public func backgroundFiles(running files: Set<String>) -> Set<String> {
        files.intersection([image.file, archive.file])
    }

    /// **Ceux des fichiers de ce bureau en cours qui manquent encore** :
    /// l'image absente de la bibliothèque à sa taille, l'archive absente des
    /// téléchargements à la sienne. Ce sont les seuls que `fetch` suit sans
    /// garde de place.
    ///
    /// `running` est un relevé : la feuille le lit à son ouverture, et un
    /// transfert de fond a pu finir depuis, la feuille ouverte. Le croire
    /// encore coupait toute la garde, alors que le fichier était là : sur un
    /// téléphone plein, le reste partait sans être compté, et l'installation
    /// tombait ensuite sur l'erreur du système au lieu de la phrase de la
    /// place. La taille seule suffit ici, comme dans `room` : un fichier
    /// fini par la session y est rangé entier, et sa somme se vérifie plus
    /// loin (`archivePresent`, l'empreinte du noyau).
    public func followable(running files: Set<String>, library: URL, downloads: URL) -> Set<String> {
        backgroundFiles(running: files).filter { file in
            if file == image.file { return !imagePresent(in: library) }
            return Self.size(of: downloads.appendingPathComponent(archive.file)) != archive.size
        }
    }

    /// **Les fichiers en cours, une fois ce bureau suivi** : quand `fetch`
    /// a rendu la main — fini, refusé, en panne ou annulé —, aucune tâche
    /// de ce bureau ne court plus en arrière-plan. Les fichiers lus à
    /// l'ouverture de la feuille ne sont relus nulle part ailleurs, et la
    /// ligne disait encore « continue en arrière-plan » d'un téléchargement
    /// qu'« Annuler » venait d'arrêter. Les fichiers des autres restent.
    public func followed(running files: Set<String>) -> Set<String> {
        files.subtracting(backgroundFiles(running: files))
    }

    /// **Les fichiers en cours, une fois `fetch` rendu sur `error`** (`nil`
    /// quand il a fini) : `followed`, sauf après le refus de la place. Ce
    /// refus ne suit rien et n'arrête rien : le transfert de fond qui
    /// courait continue (`fetch`), et la ligne doit encore le dire.
    public func followed(running files: Set<String>, after error: Error?) -> Set<String> {
        if let refusal = error as? Refusal, case .notEnoughSpace = refusal { return files }
        return followed(running: files)
    }

    // MARK: - Déjà installé

    /// **Les machines de la liste qui démarrent déjà l'image de ce bureau**,
    /// et si chacune a une session sous le noyau de la fabrication : celle
    /// qu'installer de nouveau ne doit pas laisser croire remplacée.
    public func installedCopies(among machines: [InstalledMachine], in storage: URL? = nil)
        -> [(machine: InstalledMachine, hasSession: Bool)] {
        machines.filter { $0.image == image.file }.map { machine in
            (machine, SuspendedMachine.exists(
                kernel: SuspendedMachine.identity(digest: kernelDigest, named: machine.key), in: storage))
        }
    }

    /// **Ce que la feuille dit avant de réinstaller**, ou `nil` quand aucune
    /// machine ne démarre cette image. Installer ne remplace rien : une
    /// machine neuve s'ajoute, sous une clé neuve (`install`). Encore faut-il
    /// le dire — la même ligne, touchée de nouveau, laissait croire que le
    /// bureau en cours repartait du jour de la fabrication.
    public func alreadyInstalledPhrase(_ copies: [(machine: InstalledMachine, hasSession: Bool)]) -> String? {
        guard !copies.isEmpty else { return nil }
        let names = copies.map { "« \($0.machine.name) »" }.joined(separator: ", ")
        let running = copies.filter(\.hasSession)
        let verb = copies.count > 1 ? "démarrent" : "démarre"
        var line = "\(names) \(verb) déjà cette image"
        if running.count == copies.count {
            line += copies.count > 1 ? ", chacune avec sa session." : ", avec sa session."
        } else if running.isEmpty {
            line += ", sans session : l'ouvrir la fait repartir de zéro (une demi-heure)."
        } else {
            line += " ; " + running.map { "« \($0.machine.name) »" }.joined(separator: ", ")
                + " seulement avec sa session."
        }
        return line + " Installer ajoute une autre machine, prête au jour de la fabrication ; "
            + "celles-ci et leurs sessions restent telles quelles."
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
        /// Le téléphone n'a pas la place (`fetch`) : rien n'a été demandé.
        /// `following` : ce qui se télécharge déjà en arrière-plan, mis à
        /// part du compte, et qui continue.
        case notEnoughSpace(Room, available: Int, following: Set<Progress.Step> = [])

        public var errorDescription: String? {
            switch self {
            case .missingImage(let image):
                return "L'image \(image) n'est plus dans la bibliothèque ; le bureau prêt n'a pas été installé. "
                    + "Le bureau reçu est gardé : touchez de nouveau « Installer », seule l'image sera "
                    + "téléchargée."
            case .wrongKernel(_, nil):
                return "Le noyau de l'image ne s'est pas laissé lire : le bureau ne pourrait pas "
                    + "reprendre. Rien n'a été installé. " + Self.replaceTheImage
            case .wrongKernel:
                return "L'image présente n'a pas le noyau avec lequel ce bureau a été démarré : "
                    + "il ne pourrait pas reprendre. Rien n'a été installé. " + Self.replaceTheImage
            case .notEnoughSpace(let room, let available, let following) where room.copyIsThePeak:
                // L'image reçue est recopiée avant d'être rangée : c'est elle,
                // et non l'installation, qui fixe ce qu'il faut de libre.
                return Self.spaceLead(following) + "ce bureau demande "
                    + "\(LocalStorage.describe(bytes: room.total)) de libre au plus fort "
                    + "(\(LocalStorage.describe(bytes: room.download)) à télécharger ; l'image reçue, "
                    + "\(LocalStorage.describe(bytes: room.image)), est recopiée avant d'être rangée, et prend un "
                    + "moment deux fois sa place), et il en reste \(LocalStorage.describe(bytes: available)). "
                    + "Libérez au moins \(LocalStorage.describe(bytes: room.total - available)) (Réglages, "
                    + "Général, Stockage de l'iPhone), puis réessayez. " + Self.spaceEnd(following)
            case .notEnoughSpace(let room, let available, let following):
                let short = LocalStorage.describe(bytes: room.total - available)
                let download = room.download == 0 ? "rien à télécharger"
                    : "\(LocalStorage.describe(bytes: room.download)) à télécharger"
                return Self.spaceLead(following) + "ce bureau demande "
                    + "\(LocalStorage.describe(bytes: room.total)) de libre (\(download), puis "
                    + "\(LocalStorage.describe(bytes: room.install)) pour l'installer et le sauver une "
                    + "première fois), et il en reste \(LocalStorage.describe(bytes: available)). "
                    + "Libérez au moins \(short) (Réglages, Général, Stockage de l'iPhone), puis réessayez. "
                    + Self.spaceEnd(following)
            case .archiveForAnotherImage(let image):
                return "Ce bureau prêt a été fait pour une autre image (\(image)) ; rien n'a été installé."
            case .noSession:
                return "Ce bureau prêt ne porte pas de bureau démarré pour cette image ; rien n'a été installé."
            }
        }

        /// **L'image est en faute, pas le bureau** : le bureau reçu est gardé
        /// (`install`), et c'est l'image qu'il faut refaire. Sans cette
        /// phrase, et avec le bureau effacé, chaque nouvel essai trouvait
        /// l'image à sa taille, retéléchargeait le bureau, et le refusait de
        /// nouveau.
        static let replaceTheImage = "Le bureau reçu est gardé. Supprimez cette image de la bibliothèque, "
            + "puis touchez de nouveau « Installer » : seule l'image sera retéléchargée."

        /// Ce qui se télécharge déjà en arrière-plan, nommé : « l'image »,
        /// « le bureau », ou les deux ; `nil` quand rien ne court.
        private static func followingName(_ following: Set<Progress.Step>) -> String? {
            switch (following.contains(.image), following.contains(.archive)) {
            case (true, true): return "l'image et le bureau"
            case (true, false): return "l'image"
            case (false, true): return "le bureau"
            case (false, false): return nil
            }
        }

        /// Le début du refus de la place : ce qui court déjà est mis à part
        /// du compte, et la phrase le dit.
        private static func spaceLead(_ following: Set<Progress.Step>) -> String {
            guard let what = followingName(following) else { return "Pas assez de place sur le téléphone : " }
            let verb = following.count > 1 ? "se téléchargent" : "se télécharge"
            return "Pas assez de place sur le téléphone : outre \(what) qui \(verb) en arrière-plan, "
        }

        /// **La fin du refus de la place.** « Rien n'a été téléchargé » est
        /// faux d'un transfert de fond à moitié fait : il continue, et la
        /// session le range à sa fin ; rien d'autre n'a été demandé.
        private static func spaceEnd(_ following: Set<Progress.Step>) -> String {
            guard let what = followingName(following) else { return "Rien n'a été téléchargé." }
            let verb = following.count > 1 ? "continuent" : "continue"
            return "Rien d'autre n'a été demandé : \(what) \(verb) de se télécharger en arrière-plan."
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
    /// **L'archive est effacée ensuite**, installée ou refusée pour une
    /// faute qui est la sienne : quelques centaines de mégaoctets qui ne
    /// servent plus — la machine installée porte ce qu'elle contenait.
    /// **Pas quand c'est l'image qui est en faute** (`missingImage`,
    /// `wrongKernel`) : l'archive, vérifiée à sa somme, est bonne, et
    /// l'effacer faisait retélécharger 156 Mio à chaque essai, refusés de
    /// nouveau tant que l'image restait la même.
    @discardableResult
    public func install(
        archive file: URL, imageKernelDigest: String?, library: [String], in directory: URL? = nil,
        now: Date = Date(), id: String = InstalledMachines.newIdentifier(),
        createOwnDisk: (String, UInt64) throws -> String
    ) throws -> InstalledMachine {
        guard library.contains(image.file) else { throw Refusal.missingImage(image.file) }
        guard imageKernelDigest?.lowercased() == kernelDigest else {
            throw Refusal.wrongKernel(expected: kernelDigest, found: imageKernelDigest)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = try MachineArchive.contents(of: file)
        guard contents.image == image.file else { throw Refusal.archiveForAnotherImage(contents.image) }
        guard contents.sessions.contains(kernelDigest) else { throw Refusal.noSession(kernelDigest) }
        let machine = try MachineArchive.import(
            from: file, library: library, in: directory, now: now, id: id, createOwnDisk: createOwnDisk)
        // **Sa première reprise lui donnera l'heure et de l'aléa** : la
        // session vient d'être écrite par l'import, sa date est celle
        // d'aujourd'hui, et l'invité est encore au jour de la fabrication.
        // Sans la marque, la machine reprendrait à ce jour-là. Une marque qui
        // ne s'écrit pas défait l'installation plutôt que de la laisser à
        // moitié juste. Voir `FirstResume`.
        do {
            try FirstResume.arm(FirstResume(madeAt: madeAt),
                                kernel: SuspendedMachine.identity(digest: kernelDigest, named: machine.key),
                                in: directory)
        } catch {
            _ = try? InstalledMachines.remove(id: machine.id, in: directory)
            throw error
        }
        return machine
    }
}
