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
    /// Fedora, Ubuntu, puis Arch Linux.
    ///
    /// **Un index qui ne répond pas ne cache pas les autres** : la liste
    /// garde ce qui a pu être lu. Seul un échec de tous est un échec, et il
    /// dit la raison du premier.
    public func bootableReleases(alpine: URL = ImageDownload.alpineIndex,
                                 debian: URL = ImageDownload.debianIndex,
                                 fedora: URL = ImageDownload.fedoraIndex,
                                 ubuntu: URL = ImageDownload.ubuntuIndex,
                                 arch: URL = ImageDownload.archIndex) async throws
        -> [ImageDownload.Release] {
        var releases: [ImageDownload.Release] = []
        var firstFailure: Error?
        do {
            let text = try await read(alpine)
            releases += ImageDownload.bootable(ImageDownload.alpineReleases(text, index: alpine))
        } catch {
            firstFailure = error
        }
        do {
            let text = try await read(debian)
            for candidate in ImageDownload.debianCandidates(text) {
                let file = debian.deletingLastPathComponent().appendingPathComponent(candidate.file)
                guard let size = try await size(of: file) else { continue }
                releases.append(ImageDownload.debianRelease(
                    file: candidate.file, version: candidate.version, sha512: candidate.sha512,
                    size: size, index: debian))
            }
        } catch {
            firstFailure = firstFailure ?? error
        }
        // Fedora donne la taille dans son index : rien à demander au serveur.
        do {
            releases += ImageDownload.fedoraReleases(try await read(fedora), index: fedora)
        } catch {
            firstFailure = firstFailure ?? error
        }
        do {
            let text = try await read(ubuntu)
            for candidate in ImageDownload.ubuntuCandidates(text) {
                let file = ubuntu.deletingLastPathComponent().appendingPathComponent(candidate.file)
                guard let size = try await size(of: file) else { continue }
                releases.append(ImageDownload.ubuntuRelease(
                    file: candidate.file, version: candidate.version, sha256: candidate.sha256,
                    size: size, index: ubuntu))
            }
        } catch {
            firstFailure = firstFailure ?? error
        }
        // Arch : la page du dossier nomme l'image datée, son `.SHA256` à côté
        // en donne la somme. Seule la plus récente est proposée.
        do {
            if let newest = ImageDownload.archCandidates(try await read(arch)).first {
                let file = arch.appendingPathComponent(newest.file)
                let sums = try await read(arch.appendingPathComponent(newest.file + ".SHA256"))
                if let sha256 = ImageDownload.archChecksum(sums, for: newest.file),
                   let size = try await size(of: file) {
                    releases.append(ImageDownload.archRelease(
                        file: newest.file, version: newest.version, sha256: sha256, size: size, index: arch))
                }
            }
        } catch {
            firstFailure = firstFailure ?? error
        }
        if releases.isEmpty { throw firstFailure ?? Failure.nothingToDownload }
        return releases
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
        let manager = FileManager.default
        try manager.createDirectory(at: partsFolder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(release.file)
        let part = ImageDownload.partURL(for: partsFolder.appendingPathComponent(release.file))
        if !manager.fileExists(atPath: part.path) { _ = manager.createFile(atPath: part.path, contents: nil) }
        var have = (try? manager.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
        // Plus long que le fichier annoncé : il vient d'une autre version de
        // l'index. Rien à en garder.
        if have > release.size {
            try Data().write(to: part)
            have = 0
        }
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
}
