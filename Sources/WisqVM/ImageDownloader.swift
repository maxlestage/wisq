import Foundation

/// Ce que l'application fournit pour télécharger : une requête `GET`,
/// éventuellement avec un en-tête `Range`, et ce qui revient.
///
/// C'est toute la place du réseau dans le téléchargement. Le reste — où
/// reprendre, quoi faire de la réponse, quand garder le fichier — est dans
/// `ImageDownloader`, qui ne connaît que ce protocole : les tests lui donnent
/// un serveur scripté, l'application `URLSession`.
public protocol RangeFetcher: Sendable {
    func fetch(_ url: URL, range: String?) async throws -> FetchedResponse
}

/// Le statut, l'en-tête `Content-Range` s'il y en a un, et le corps, par
/// morceaux.
public struct FetchedResponse: Sendable {
    public let status: Int
    public let contentRange: String?
    public let body: AsyncThrowingStream<Data, Error>

    public init(status: Int, contentRange: String?, body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.contentRange = contentRange
        self.body = body
    }
}

/// Télécharge une image dans la bibliothèque, en reprenant un transfert
/// coupé, et ne l'y range que vérifiée.
public struct ImageDownloader: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        /// Le serveur a répondu quelque chose dont on ne peut rien faire.
        case refused(String)
        /// L'index n'a donné aucune image qui démarre ici.
        case nothingToDownload
        /// La réponse s'est arrêtée avant la fin ; le `.part` est gardé, et
        /// le prochain essai reprend à son dernier octet.
        case interrupted(have: Int, of: Int)

        public var errorDescription: String? {
            switch self {
            case .refused(let why): return why
            case .nothingToDownload:
                return "l'index de la distribution ne propose aucune image qui démarre ici."
            case .interrupted(let have, let total):
                return "le transfert s'est arrêté à \(have) octets sur \(total) ; "
                    + "le prochain essai reprendra là."
            }
        }
    }

    public let fetcher: any RangeFetcher
    /// Là où les `.part` attendent : pas la bibliothèque, qui ne doit lister
    /// que des fichiers entiers.
    public let partsFolder: URL

    public init(fetcher: any RangeFetcher, partsFolder: URL) {
        self.fetcher = fetcher
        self.partsFolder = partsFolder
    }

    /// Les images qui démarrent ici, de tous les index : Alpine, Debian,
    /// Fedora, Ubuntu, puis Arch Linux, openSUSE Tumbleweed, AlmaLinux et
    /// Rocky Linux.
    ///
    /// **Un index qui ne répond pas ne cache pas les autres** : la liste
    /// garde ce qui a pu être lu. Seul un échec de tous est un échec, et il
    /// dit la raison du premier, dans cet ordre.
    ///
    /// **Les huit en même temps.** Ils étaient lus l'un après l'autre, et la
    /// feuille « Télécharger » attendait la somme des huit allers-retours —
    /// plus ceux des sondes de taille de Debian et d'Ubuntu — avant de
    /// montrer quoi que ce soit. Elle attend maintenant le plus lent. L'ordre
    /// de la liste, lui, ne change pas.
    public func bootableReleases(alpine: URL = ImageDownload.alpineIndex,
                                 debian: URL = ImageDownload.debianIndex,
                                 fedora: URL = ImageDownload.fedoraIndex,
                                 ubuntu: URL = ImageDownload.ubuntuIndex,
                                 arch: URL = ImageDownload.archIndex,
                                 openSUSE: URL = ImageDownload.openSUSEIndex,
                                 alma: URL = ImageDownload.almaIndex,
                                 rocky: URL = ImageDownload.rockyIndex) async throws
        -> [ImageDownload.Release] {
        async let alpineList = attempt { try await alpineReleases(alpine) }
        async let debianList = attempt { try await debianReleases(debian) }
        async let fedoraList = attempt { try await fedoraReleases(fedora) }
        async let ubuntuList = attempt { try await ubuntuReleases(ubuntu) }
        async let archList = attempt { try await archReleases(arch) }
        async let openSUSEList = attempt { try await openSUSEReleases(openSUSE) }
        async let almaList = attempt { try await almaReleases(alma) }
        async let rockyList = attempt { try await rockyReleases(rocky) }
        let lists = await [alpineList, debianList, fedoraList, ubuntuList,
                           archList, openSUSEList, almaList, rockyList]
        var releases: [ImageDownload.Release] = []
        var firstFailure: Error?
        for list in lists {
            switch list {
            case .success(let found): releases += found
            case .failure(let error): firstFailure = firstFailure ?? error
            }
        }
        if releases.isEmpty { throw firstFailure ?? Failure.nothingToDownload }
        return releases
    }

    private func attempt(_ body: () async throws -> [ImageDownload.Release]) async
        -> Result<[ImageDownload.Release], Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private func alpineReleases(_ alpine: URL) async throws -> [ImageDownload.Release] {
        ImageDownload.bootable(ImageDownload.alpineReleases(try await read(alpine), index: alpine))
    }

    private func debianReleases(_ debian: URL) async throws -> [ImageDownload.Release] {
        var releases: [ImageDownload.Release] = []
        for candidate in ImageDownload.debianCandidates(try await read(debian)) {
            let file = debian.deletingLastPathComponent().appendingPathComponent(candidate.file)
            guard let size = try await size(of: file) else { continue }
            releases.append(ImageDownload.debianRelease(
                file: candidate.file, version: candidate.version, sha512: candidate.sha512,
                size: size, index: debian))
        }
        return releases
    }

    /// Fedora donne la taille dans son index : rien à demander au serveur.
    private func fedoraReleases(_ fedora: URL) async throws -> [ImageDownload.Release] {
        ImageDownload.fedoraReleases(try await read(fedora), index: fedora)
    }

    private func ubuntuReleases(_ ubuntu: URL) async throws -> [ImageDownload.Release] {
        var releases: [ImageDownload.Release] = []
        for candidate in ImageDownload.ubuntuCandidates(try await read(ubuntu)) {
            let file = ubuntu.deletingLastPathComponent().appendingPathComponent(candidate.file)
            guard let size = try await size(of: file) else { continue }
            releases.append(ImageDownload.ubuntuRelease(
                file: candidate.file, version: candidate.version, sha256: candidate.sha256,
                size: size, index: ubuntu))
        }
        return releases
    }

    /// Arch : la page du dossier nomme l'image datée, son `.SHA256` à côté
    /// en donne la somme. Seule la plus récente est proposée.
    private func archReleases(_ arch: URL) async throws -> [ImageDownload.Release] {
        guard let newest = ImageDownload.archCandidates(try await read(arch)).first else { return [] }
        let sums = try await read(arch.appendingPathComponent(newest.file + ".SHA256"))
        guard let sha256 = ImageDownload.sumFileChecksum(sums, for: newest.file),
              let size = try await size(of: arch.appendingPathComponent(newest.file)) else { return [] }
        return [ImageDownload.archRelease(
            file: newest.file, version: newest.version, sha256: sha256, size: size, index: arch)]
    }

    /// openSUSE : la même forme qu'Arch, le `.sha256` à côté de l'image.
    private func openSUSEReleases(_ openSUSE: URL) async throws -> [ImageDownload.Release] {
        guard let newest = ImageDownload.openSUSECandidates(try await read(openSUSE)).first else { return [] }
        let sums = try await read(openSUSE.appendingPathComponent(newest.file + ".sha256"))
        guard let sha256 = ImageDownload.sumFileChecksum(sums, for: newest.file),
              let size = try await size(of: openSUSE.appendingPathComponent(newest.file)) else { return [] }
        return [ImageDownload.openSUSERelease(
            file: newest.file, version: newest.version, sha256: sha256, size: size, index: openSUSE)]
    }

    /// AlmaLinux : un seul fichier `CHECKSUM` pour tout le dossier, au
    /// format de `sha256sum`.
    private func almaReleases(_ alma: URL) async throws -> [ImageDownload.Release] {
        guard let newest = ImageDownload.datedCandidates(try await read(alma), ImageDownload.isBootableAlma).first
        else { return [] }
        let sums = try await read(alma.appendingPathComponent("CHECKSUM"))
        guard let sha256 = ImageDownload.sumFileChecksum(sums, for: newest.file),
              let size = try await size(of: alma.appendingPathComponent(newest.file)) else { return [] }
        return [ImageDownload.almaRelease(
            file: newest.file, version: newest.version, sha256: sha256, size: size, index: alma)]
    }

    /// Rocky : un `.CHECKSUM` par image, au format de BSD.
    private func rockyReleases(_ rocky: URL) async throws -> [ImageDownload.Release] {
        guard let newest = ImageDownload.datedCandidates(try await read(rocky), ImageDownload.isBootableRocky).first
        else { return [] }
        let sums = try await read(rocky.appendingPathComponent(newest.file + ".CHECKSUM"))
        guard let sha256 = ImageDownload.bsdChecksum(sums, for: newest.file),
              let size = try await size(of: rocky.appendingPathComponent(newest.file)) else { return [] }
        return [ImageDownload.rockyRelease(
            file: newest.file, version: newest.version, sha256: sha256, size: size, index: rocky)]
    }

    /// Un index, en texte.
    func read(_ index: URL) async throws -> String {
        let response = try await fetcher.fetch(index, range: nil)
        guard response.status == 200 else {
            throw Failure.refused("l'index de la distribution n'a pas pu être lu (\(response.status)).")
        }
        var text = Data()
        for try await chunk in response.body {
            text.append(chunk)
            // Un index fait quelques kilo-octets ; au-delà, ce n'en est pas un.
            guard text.count <= 1 << 20 else { throw Failure.refused("l'index est démesuré.") }
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// La taille d'un fichier, demandée au serveur (`ImageDownload.sizeProbe`).
    /// Le corps de la réponse, un octet, n'est pas lu.
    func size(of file: URL) async throws -> Int? {
        let response = try await fetcher.fetch(file, range: ImageDownload.sizeProbe)
        return ImageDownload.size(fromProbe: response.status, contentRange: response.contentRange)
    }

    /// Télécharge `release` et le range sous `folder`, à son nom ; rend
    /// l'adresse du fichier. `progress` reçoit les octets déjà là et la
    /// taille attendue, au départ — une reprise ne repart pas de zéro — puis
    /// à chaque morceau.
    ///
    /// Une coupure en route laisse le `.part` tel qu'il est : l'appel suivant
    /// reprend à son dernier octet.
    public func download(
        _ release: ImageDownload.Release, into folder: URL,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> URL {
        let destination = folder.appendingPathComponent(release.file)
        let prepared = try preparePart(for: release)
        let part = prepared.url
        var have = prepared.have
        progress(have, release.size)

        if have < release.size {
            let response = try await fetcher.fetch(
                ImageDownload.url(of: release),
                range: ImageDownload.rangeHeader(resumingAt: have))
            switch ImageDownload.continuation(
                status: response.status, contentRange: response.contentRange, resumingAt: have) {
            case .refuse(let why):
                throw Failure.refused(why)
            case .complete:
                break
            case .restart:
                try Data().write(to: part)
                have = 0
                fallthrough
            case .append:
                let handle = try FileHandle(forWritingTo: part)
                defer { try? handle.close() }
                try handle.seekToEnd()
                for try await chunk in response.body {
                    // Le serveur qui envoie plus que la taille annoncée ne
                    // fait pas grossir le fichier au-delà : la somme le
                    // refuserait de toute façon, mais pas avant de l'avoir
                    // écrit en entier.
                    guard have + chunk.count <= release.size else {
                        throw Failure.refused("le serveur envoie plus que la taille annoncée.")
                    }
                    try handle.write(contentsOf: chunk)
                    have += chunk.count
                    progress(have, release.size)
                }
                // Une réponse qui finit proprement mais trop tôt n'est pas un
                // fichier faux : c'est un transfert coupé. Le passer à
                // `finish` effacerait ce qui est déjà là.
                if have < release.size { throw Failure.interrupted(have: have, of: release.size) }
            }
        }
        try ImageDownload.finish(part: part, as: destination, size: release.size, checksum: release.checksum)
        return destination
    }

    // MARK: - En arrière-plan

    /// Le `.part` de `release` et ce qu'il contient déjà, prêt à recevoir la
    /// suite. Le même ménage que `download` : un `.part` plus long que le
    /// fichier annoncé vient d'une autre version de l'index, et repart de
    /// zéro.
    func preparePart(for release: ImageDownload.Release) throws -> (url: URL, have: Int) {
        let manager = FileManager.default
        try manager.createDirectory(at: partsFolder, withIntermediateDirectories: true)
        let part = ImageDownload.partURL(for: partsFolder.appendingPathComponent(release.file))
        if !manager.fileExists(atPath: part.path) { _ = manager.createFile(atPath: part.path, contents: nil) }
        var have = (try? manager.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
        if have > release.size {
            try Data().write(to: part)
            have = 0
        }
        return (part, have)
    }

    /// **La requête à confier à une session d'arrière-plan**, qui continue
    /// quand l'application n'est plus à l'écran : l'adresse, et l'en-tête
    /// `Range` qui reprend après ce que le `.part` a déjà. `nil` quand il
    /// n'y a plus rien à recevoir — `adopt` n'a alors qu'à vérifier.
    ///
    /// Une session d'arrière-plan ne rend pas ses octets au fil de l'eau :
    /// elle écrit **son** fichier, et le donne entier à la fin. C'est donc la
    /// requête qui porte la reprise, et `adopt` qui recoud.
    public func backgroundRequest(for release: ImageDownload.Release) throws -> (url: URL, range: String?)? {
        let (_, have) = try preparePart(for: release)
        guard have < release.size else { return nil }
        return (ImageDownload.url(of: release), ImageDownload.rangeHeader(resumingAt: have))
    }

    /// **Recoudre ce qu'une session d'arrière-plan a rendu** sur le `.part`,
    /// puis vérifier et ranger l'image, comme `download` le fait de ses
    /// morceaux : `received` est le fichier de la session, `status` et
    /// `contentRange` la réponse qui l'accompagnait.
    ///
    /// La réponse se lit contre ce que le `.part` a **maintenant**, et pas
    /// contre ce qu'il avait quand la requête est partie : si l'utilisateur a
    /// repris le téléchargement à l'écran entre-temps, un `206` qui commence
    /// à l'ancien octet recoudrait au mauvais endroit, et il est refusé comme
    /// tout `206` décalé. Un refus garde le `.part` ; seule la somme fausse
    /// l'efface, dans `finish`.
    ///
    /// `received` n'est pas effacé : il appartient à la session, qui le
    /// reprend elle-même.
    public func adopt(_ received: URL, status: Int, contentRange: String?,
                      for release: ImageDownload.Release, into folder: URL) throws -> URL {
        let prepared = try preparePart(for: release)
        let part = prepared.url
        var have = prepared.have
        let destination = folder.appendingPathComponent(release.file)
        if have < release.size {
            switch ImageDownload.continuation(status: status, contentRange: contentRange, resumingAt: have) {
            case .refuse(let why):
                throw Failure.refused(why)
            case .complete:
                break
            case .restart:
                try Data().write(to: part)
                have = 0
                fallthrough
            case .append:
                let source = try FileHandle(forReadingFrom: received)
                defer { try? source.close() }
                let handle = try FileHandle(forWritingTo: part)
                defer { try? handle.close() }
                try handle.seekToEnd()
                // Par mégaoctet : une image de cloud fait des centaines de
                // mégaoctets, et le fichier de la session ne se lit pas d'un
                // bloc.
                while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
                    guard have + chunk.count <= release.size else {
                        throw Failure.refused("le serveur envoie plus que la taille annoncée.")
                    }
                    try handle.write(contentsOf: chunk)
                    have += chunk.count
                }
                if have < release.size { throw Failure.interrupted(have: have, of: release.size) }
            }
        }
        try ImageDownload.finish(part: part, as: destination, size: release.size, checksum: release.checksum)
        return destination
    }
}
