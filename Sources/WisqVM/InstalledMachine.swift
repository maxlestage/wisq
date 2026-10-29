import Foundation

/// Une machine Linux **installée** : un nom, l'image qu'elle démarre, et tout
/// ce qu'elle retient d'une session à l'autre.
///
/// **Pourquoi ce type existe.** Jusqu'ici, une machine locale *était* un
/// fichier de la bibliothèque : la mémoire, le disque, la couche d'écriture et
/// la session suspendue étaient tous rangés sous le nom de l'image. C'était
/// juste tant qu'on ne voulait qu'une machine par image ; ça ne l'est plus dès
/// qu'on veut deux Alpine à côté — une pour essayer, une pour travailler — à
/// partir du même ISO. Les deux auraient partagé leurs écritures sur le
/// disque, leur réglage de mémoire, et surtout **leur session** : reprendre
/// l'une aurait rendu l'autre.
///
/// **La solution ne touche à aucun des magasins existants.** Ils prennent tous
/// une clé — `KernelMemory`, `LocalDisk`, `SuspendedMachine` — et cette clé
/// était le nom de l'image parce qu'il n'y avait rien d'autre à leur donner.
/// Une machine installée leur donne la sienne, `key`, et chacun d'eux range
/// alors ses réglages à part sans savoir qu'il y a des machines. L'image
/// elle-même reste partagée : elle n'est jamais écrite.
///
/// **Ce qui reste nommé par l'image** est ce qui appartient vraiment au
/// fichier : l'appariement d'un noyau avec son initramfs (`BootMedia.pair`),
/// et la base de lecture du disque.
public struct InstalledMachine: Codable, Equatable, Identifiable, Sendable {
    /// Douze chiffres hexadécimaux tirés au hasard à l'installation.
    public let id: String
    /// Ce que la liste affiche, choisi par la personne.
    public var name: String
    /// Le nom du fichier de la bibliothèque que cette machine démarre — un
    /// noyau, ou une image d'installation.
    public let image: String
    public let installedAt: Date
    /// Le dernier démarrage ou la dernière reprise. `nil` pour une machine
    /// jamais lancée.
    public var lastStartedAt: Date?
    /// Le disque vierge créé **pour** cette machine, s'il y en a un — un
    /// fichier de la bibliothèque qui part avec elle.
    ///
    /// Retenu ici, et pas déduit du nom du fichier : un disque importé que la
    /// personne a choisi n'appartient qu'à elle, et le supprimer avec la
    /// machine serait effacer un fichier qu'elle a apporté. Absent des
    /// catalogues écrits avant, donc `nil` au décodage.
    public var ownDisk: String?

    public init(id: String, name: String, image: String, installedAt: Date,
                lastStartedAt: Date? = nil, ownDisk: String? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.installedAt = installedAt
        self.lastStartedAt = lastStartedAt
        self.ownDisk = ownDisk
    }

    /// La clé sous laquelle cette machine range ses réglages, sa session et
    /// ses écritures.
    ///
    /// **Ne contient que des lettres, des chiffres et des tirets**, donc
    /// `SuspendedMachine.safeName` la laisse intacte : une clé que l'assainis-
    /// sement modifierait serait une clé sous laquelle on écrit un fichier
    /// qu'on ne retrouve plus.
    public var key: String { Self.keyPrefix + id }

    static let keyPrefix = "installee-"

    /// Ce que cette machine demande aux magasins.
    public var keys: MachineKeys { MachineKeys(settings: key, overlayPrefix: key + "~") }
}

/// Les noms qu'une machine donne aux magasins de la VM locale.
///
/// Deux formes, et une seule décision : un fichier de la bibliothèque démarré
/// directement garde **exactement** les clés d'avant — son nom, et le nom du
/// disque pour la couche d'écriture — pour que rien de ce qui est déjà sur les
/// téléphones ne change de place. Une machine installée a les siennes.
public struct MachineKeys: Equatable, Sendable {
    /// La clé de la mémoire, du disque choisi et des sessions suspendues.
    public let settings: String
    /// Ce qui précède le nom du disque dans le nom de la couche d'écriture.
    /// Vide pour un fichier démarré directement : sa couche est celle du
    /// disque, partagée par tout ce qui le démarre, comme avant.
    public let overlayPrefix: String

    public init(settings: String, overlayPrefix: String) {
        self.settings = settings
        self.overlayPrefix = overlayPrefix
    }

    /// Les clés d'un fichier de la bibliothèque démarré tel quel.
    public static func image(_ name: String) -> MachineKeys {
        MachineKeys(settings: name, overlayPrefix: "")
    }

    /// Le nom de la couche d'écriture de ce disque pour cette machine.
    ///
    /// **C'est ici que deux machines cessent de partager leurs écritures.**
    /// Deux installations sur le même disque de base écrivent chacune dans sa
    /// couche, et la base, elle, ne change jamais.
    public func overlay(forDisk disk: String) -> String { overlayPrefix + disk }
}

/// Le catalogue des machines installées, et ce que les retirer emporte.
///
/// Dans `WisqVM` et pas dans l'application, pour la raison que
/// `SuspendedMachine` donne : l'application ne se construit que sur les
/// plateformes d'Apple, et « écrire un fichier, le relire, survivre à un
/// fichier abîmé » mérite un test plutôt qu'un raisonnement.
public enum InstalledMachines {
    /// Pourquoi une opération n'a rien changé.
    public enum Refusal: Error, Equatable, LocalizedError {
        /// Le catalogue existe et ne se lit pas. **Rien n'est écrit par-dessus**
        /// : réécrire un fichier qu'on n'a pas su lire effacerait les machines
        /// de quelqu'un pour une raison qu'il ne verrait jamais.
        case unreadable
        /// Aucune machine sous cet identifiant.
        case unknown(String)
        /// Un nom vide une fois les blancs retirés.
        case emptyName

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                return """
                    La liste des machines installées n'a pas pu être lue. wisq \
                    n'y écrit rien tant qu'elle ne se lit pas, pour ne pas \
                    effacer ce qu'elle contient.
                    """
            case .unknown:
                return "Cette machine n'existe plus."
            case .emptyName:
                return "Une machine a besoin d'un nom."
            }
        }
    }

    /// Les machines, la plus récemment lancée d'abord, puis par nom.
    ///
    /// Un catalogue illisible se lit comme vide — c'est ce que la liste peut
    /// montrer — mais, à la différence des réglages, il **refuse** ensuite
    /// d'être réécrit : voir `Refusal.unreadable`.
    public static func list(in directory: URL? = nil) -> [InstalledMachine] {
        guard case .success(let machines) = load(in: directory) else { return [] }
        return sorted(machines)
    }

    /// Une machine, par son identifiant.
    public static func machine(id: String, in directory: URL? = nil) -> InstalledMachine? {
        list(in: directory).first { $0.id == id }
    }

    /// Installe une nouvelle machine sur une image de la bibliothèque.
    ///
    /// `name` vide ou absent prend celui que `suggestedName` propose. Un nom
    /// déjà pris reçoit un numéro : deux lignes du même nom dans une liste
    /// sont deux lignes qu'on ne distingue pas.
    @discardableResult
    public static func install(
        image: String, name: String? = nil, in directory: URL? = nil,
        now: Date = Date(), id: String = newIdentifier()
    ) throws -> InstalledMachine {
        var machines = try loadForWriting(in: directory)
        let wanted = name.map(trimmed) ?? ""
        let base = wanted.isEmpty ? suggestedName(forImage: image) : wanted
        let machine = InstalledMachine(
            id: id, name: uniqueName(base, among: machines.map(\.name)),
            image: image, installedAt: now)
        machines.append(machine)
        try write(machines, in: directory)
        return machine
    }

    /// Renomme une machine. Le nom suit la même règle qu'à l'installation.
    @discardableResult
    public static func rename(
        id: String, to name: String, in directory: URL? = nil
    ) throws -> InstalledMachine {
        var machines = try loadForWriting(in: directory)
        guard let index = machines.firstIndex(where: { $0.id == id }) else {
            throw Refusal.unknown(id)
        }
        let wanted = trimmed(name)
        guard !wanted.isEmpty else { throw Refusal.emptyName }
        let others = machines.enumerated().filter { $0.offset != index }.map(\.element.name)
        machines[index].name = uniqueName(wanted, among: others)
        try write(machines, in: directory)
        return machines[index]
    }

    /// Note un démarrage : c'est ce qui range la machine en tête de liste.
    ///
    /// Silencieux sur un échec. Ne pas réussir à noter l'heure ne doit pas
    /// empêcher la machine de démarrer.
    public static func markStarted(id: String, at date: Date = Date(), in directory: URL? = nil) {
        guard var machines = try? loadForWriting(in: directory),
              let index = machines.firstIndex(where: { $0.id == id })
        else { return }
        machines[index].lastStartedAt = date
        try? write(machines, in: directory)
    }

    /// Retire une machine, et **tout** ce qu'elle retenait.
    ///
    /// Quatre choses, comme pour un noyau supprimé : sa mémoire, son disque
    /// choisi, ses couches d'écriture et ses sessions suspendues. L'image, elle,
    /// reste dans la bibliothèque — d'autres machines peuvent la démarrer, et
    /// c'est à la personne de décider si le fichier part.
    ///
    /// La machine rendue porte `ownDisk` : c'est à l'appelant, qui connaît la
    /// bibliothèque, d'effacer ce fichier-là.
    @discardableResult
    public static func remove(id: String, in directory: URL? = nil) throws -> InstalledMachine {
        var machines = try loadForWriting(in: directory)
        guard let index = machines.firstIndex(where: { $0.id == id }) else {
            throw Refusal.unknown(id)
        }
        let machine = machines.remove(at: index)
        try write(machines, in: directory)
        forgetEverything(of: machine, in: directory)
        return machine
    }

    /// Retient le disque vierge créé pour cette machine.
    public static func setOwnDisk(_ disk: String?, id: String, in directory: URL? = nil) throws {
        var machines = try loadForWriting(in: directory)
        guard let index = machines.firstIndex(where: { $0.id == id }) else {
            throw Refusal.unknown(id)
        }
        machines[index].ownDisk = disk
        try write(machines, in: directory)
    }

    /// Oublie ce fichier comme disque propre d'une machine — pour un fichier
    /// supprimé de la bibliothèque par la personne. La machine reste ; elle
    /// n'a simplement plus de disque à emporter.
    public static func forgetOwnDisk(named disk: String, in directory: URL? = nil) {
        guard var machines = try? loadForWriting(in: directory),
              machines.contains(where: { $0.ownDisk == disk })
        else { return }
        for index in machines.indices where machines[index].ownDisk == disk {
            machines[index].ownDisk = nil
        }
        try? write(machines, in: directory)
    }

    /// Retire toutes les machines qui démarrent cette image — pour une image
    /// supprimée de la bibliothèque. Les rend, pour le dire et pour que
    /// l'appelant emporte leurs disques propres, qui vivent dans la
    /// bibliothèque que ce type ne voit pas.
    ///
    /// Une machine sans son image ne démarre plus, et ses couches d'écriture
    /// sont des secteurs posés sur une base qui n'existe plus : les garder
    /// serait garder des octets que personne ne pourra relire.
    @discardableResult
    public static func removeAll(
        usingImage image: String, in directory: URL? = nil
    ) -> [InstalledMachine] {
        guard var machines = try? loadForWriting(in: directory) else { return [] }
        let leaving = machines.filter { $0.image == image }
        guard !leaving.isEmpty else { return [] }
        machines.removeAll { $0.image == image }
        guard (try? write(machines, in: directory)) != nil else { return [] }
        for machine in leaving { forgetEverything(of: machine, in: directory) }
        return leaving
    }

    /// Les clés de toutes les machines installées — ce que le relevé de
    /// stockage doit compter comme propriétaires, pour ne pas prendre leurs
    /// sessions pour des restes.
    public static func allKeys(in directory: URL? = nil) -> [MachineKeys] {
        list(in: directory).map(\.keys)
    }

    /// Ce fichier peut-il porter une machine installée ?
    ///
    /// Ce qui démarre : un noyau que wisq sait faire tourner, un fichier que
    /// personne n'a reconnu — la même permission qu'ailleurs —, et une image
    /// d'installation, dont `IsoBoot` sort le noyau. Pas un disque, pas un
    /// initramfs : installer une machine sur ce qui ne démarre pas donnerait
    /// une ligne dont le seul geste est un refus.
    public static func canInstall(_ kind: KernelImageKind) -> Bool {
        if case .discImage = kind { return true }
        return kind.couldBootHere
    }

    /// **Les images de cloud parmi `files`** : un disque d'hyperviseur que
    /// wisq lit, ou un fichier que personne n'a reconnu, dont la table de
    /// partitions porte une partition Linux (`CloudBoot.isCloudImage`).
    ///
    /// À part de `canInstall`, qui ne lit que la nature du fichier : un
    /// qcow2 peut être un disque de données vierge, sur lequel installer une
    /// machine n'aurait aucun sens. Seule la table le dit, et la lire demande
    /// d'ouvrir le fichier, une fois par rechargement de la liste plutôt
    /// qu'à chaque dessin.
    public static func cloudImages(_ files: [URL], kinds: [URL: KernelImageKind]) -> Set<URL> {
        Set(files.filter { url in
            switch kinds[url] ?? .unknown {
            case .virtualDisk(let format) where KernelImageKind.isReadableVirtualDisk(format):
                return CloudBoot.isCloudImage(fileAt: url)
            case .unknown:
                return CloudBoot.isCloudImage(fileAt: url)
            default:
                return false
            }
        })
    }

    // MARK: - Les noms

    /// Le nom qu'une machine reçoit quand personne n'en donne.
    ///
    /// Le nom du fichier sans son extension, et sans ce qui ne dit rien à une
    /// personne : `alpine-virt-3.20.3-x86_64.iso` devient
    /// `alpine-virt-3.20.3-x86_64`. Rien de plus malin — deviner « Alpine 3.20 »
    /// serait inventer un nom que le fichier ne porte pas.
    public static func suggestedName(forImage image: String) -> String {
        let url = URL(fileURLWithPath: image)
        let stem = url.pathExtension.isEmpty ? image : url.deletingPathExtension().lastPathComponent
        let name = trimmed(stem)
        return name.isEmpty ? "Machine" : name
    }

    /// Le nom, ou le nom suivi du premier numéro libre.
    ///
    /// Comparé sans tenir compte de la casse : « Alpine » et « alpine » côte à
    /// côte dans une liste sont la même ligne pour qui la lit.
    static func uniqueName(_ name: String, among taken: [String]) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(name.lowercased()) else { return name }
        var number = 2
        while lowered.contains("\(name) (\(number))".lowercased()) { number += 1 }
        return "\(name) (\(number))"
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Douze chiffres hexadécimaux. Quarante-huit bits suffisent largement à
    /// un catalogue de quelques machines sur un téléphone, et restent courts
    /// dans un nom de fichier.
    public static func newIdentifier() -> String {
        String(format: "%012llx", UInt64.random(in: 0...0xFFFF_FFFF_FFFF))
    }

    static func sorted(_ machines: [InstalledMachine]) -> [InstalledMachine] {
        machines.sorted { lhs, rhs in
            switch (lhs.lastStartedAt, rhs.lastStartedAt) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
        }
    }

    // MARK: - Dupliquer

    /// Duplique une machine : son nom suivi de « copie », ses réglages, ses
    /// couches d'écriture **et sa session suspendue**.
    ///
    /// **Pourquoi la session aussi.** Dupliquer sert à repartir d'un point
    /// qu'on a atteint — une distribution installée et configurée, un shell
    /// où l'on était — sans le refaire. Une copie qui redémarrerait de zéro
    /// ne serait qu'une installation de plus.
    ///
    /// **Ce qui est copié, et pourquoi c'est juste.** La session ne porte pas
    /// les octets du disque, seulement « le contenu vit ailleurs » ; ce qui le
    /// porte, ce sont les couches d'écriture. Copier les deux ensemble rend une
    /// machine dont le disque est exactement celui que l'instantané a connu.
    /// Les bases ne sont pas copiées : elles ne changent jamais, et deux
    /// couches posées sur la même base sont deux disques distincts.
    ///
    /// **Le disque propre**, s'il y en a un, est une base de zéros qui
    /// appartient à la machine : la copie en reçoit une à elle, que l'appelant
    /// crée (ce type ne voit pas la bibliothèque) et nomme dans
    /// `renamingOwnDisk`. Sa couche est copiée sous ce nouveau nom.
    ///
    /// Tout ou rien autant que des fichiers le permettent : une copie qui
    /// échoue retire la machine à moitié faite, et ce qu'elle avait reçu.
    @discardableResult
    public static func duplicate(
        id: String, name: String? = nil, renamingOwnDisk newOwnDisk: String? = nil,
        in directory: URL? = nil, now: Date = Date(), newID: String = newIdentifier()
    ) throws -> InstalledMachine {
        var machines = try loadForWriting(in: directory)
        guard let source = machines.first(where: { $0.id == id }) else {
            throw Refusal.unknown(id)
        }
        let wanted = name.map(trimmed) ?? ""
        let base = wanted.isEmpty ? "\(source.name) copie" : wanted
        let copy = InstalledMachine(
            id: newID, name: uniqueName(base, among: machines.map(\.name)),
            image: source.image, installedAt: now,
            ownDisk: source.ownDisk == nil ? nil : newOwnDisk)
        machines.append(copy)
        try write(machines, in: directory)
        do {
            try copySettings(from: source, to: copy, in: directory)
        } catch {
            _ = try? remove(id: copy.id, in: directory)
            throw error
        }
        return copy
    }

    /// Ce qu'une copie reçoit de sa source, fichier par fichier.
    static func copySettings(
        from source: InstalledMachine, to copy: InstalledMachine, in directory: URL?
    ) throws {
        // La mémoire : la valeur réglée, telle quelle — sans plafond, puisque
        // ce n'est pas un démarrage qui la lit ici.
        KernelMemory.setSize(
            KernelMemory.size(forKernel: source.key, in: directory, ceiling: .max),
            forKernel: copy.key, in: directory)

        // Le mot de passe de `root` : la copie démarre le même système, déjà
        // mis en route avec lui.
        RootPassword.copy(from: source.key, to: copy.key, in: directory)

        // Le disque choisi : le même fichier, sauf le disque propre, qui est
        // remplacé par celui de la copie.
        let renamed: (String) -> String = { disk in
            disk == source.ownDisk ? (copy.ownDisk ?? disk) : disk
        }
        if let disk = LocalDisk.recordedName(forKernel: source.key, in: directory) {
            LocalDisk.attach(renamed(disk), forKernel: copy.key, in: directory)
        }

        // Les couches d'écriture, sous la clé de la copie.
        let writes = try LocalDisk.writesDirectory(in: directory)
        let manager = FileManager.default
        let prefix = source.keys.overlayPrefix
        for entry in try manager.contentsOfDirectory(atPath: writes.path)
        where entry.hasPrefix(prefix) && entry.hasSuffix(".writes") {
            let disk = String(entry.dropFirst(prefix.count).dropLast(".writes".count))
            let target = copy.keys.overlay(forDisk: renamed(disk)) + ".writes"
            try manager.copyItem(at: writes.appendingPathComponent(entry),
                                 to: writes.appendingPathComponent(target))
            let map = writes.appendingPathComponent(entry + ".map")
            if manager.fileExists(atPath: map.path) {
                try manager.copyItem(at: map, to: writes.appendingPathComponent(target + ".map"))
            }
        }

        // La session : chaque instantané garde son empreinte de noyau, qui
        // est la même image, et prend la clé de la copie.
        let folder = try directory ?? SuspendedMachine.directory()
        let from = "machine-\(SuspendedMachine.safeName(source.key))-"
        let to = "machine-\(SuspendedMachine.safeName(copy.key))-"
        for file in SuspendedMachine.savedMachineFiles(named: source.key, in: directory) {
            try manager.copyItem(
                at: folder.appendingPathComponent(file),
                to: folder.appendingPathComponent(to + file.dropFirst(from.count)))
        }
    }

    // MARK: - Ce que retirer emporte

    static func forgetEverything(of machine: InstalledMachine, in directory: URL?) {
        KernelMemory.forget(kernel: machine.key, in: directory)
        RootPassword.forget(kernel: machine.key, in: directory)
        LocalDisk.forget(kernel: machine.key, in: directory)
        ImageBootRequest.forget(kernel: machine.key, in: directory)
        SuspendedMachine.clearAll(named: machine.key, in: directory)
        LocalDisk.discardWrites(withPrefix: machine.keys.overlayPrefix, in: directory)
    }

    // MARK: - Où le catalogue vit

    static let fileName = "installed-machines.json"

    /// À côté de tout le reste de ce que la VM locale retient.
    public static func directory() throws -> URL { try SuspendedMachine.directory() }

    private static func url(in directory: URL?) -> URL? {
        (directory ?? (try? Self.directory()))?.appendingPathComponent(fileName)
    }

    private struct File: Codable {
        var version = 1
        var machines: [InstalledMachine]
    }

    /// Absent est vide ; présent et illisible est un échec, que seules les
    /// écritures refusent.
    static func load(in directory: URL?) -> Result<[InstalledMachine], Refusal> {
        guard let url = url(in: directory) else { return .success([]) }
        guard FileManager.default.fileExists(atPath: url.path) else { return .success([]) }
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(File.self, from: data)
        else { return .failure(.unreadable) }
        return .success(file.machines)
    }

    private static func loadForWriting(in directory: URL?) throws -> [InstalledMachine] {
        try load(in: directory).get()
    }

    private static func write(_ machines: [InstalledMachine], in directory: URL?) throws {
        guard let url = url(in: directory) else { throw Refusal.unreadable }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(File(machines: sorted(machines)))
        try data.write(to: url, options: .atomic)
    }

    /// Calculés plutôt que partagés : un codeur n'est pas `Sendable` sur
    /// toutes les versions d'iOS que l'application vise, et une propriété
    /// statique d'un type qui ne l'est pas est refusée en Swift 6.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
