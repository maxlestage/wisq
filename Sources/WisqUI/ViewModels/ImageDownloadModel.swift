#if os(iOS)
import Foundation
import Observation
import WisqVM

// Le lecteur d'image vit du côté Rust : voir `LocalVMModel.swift`.
#if WISQ_RUST_CORE
import WisqVMRust
#endif

/// `RangeFetcher` sur `URLSession` : la seule partie du téléchargement qui
/// touche le réseau, et la seule qui ne tourne pas sous Linux.
///
/// La requête, la réponse et la lecture du corps vivent dans **une** tâche :
/// les octets de `URLSession` ne quittent pas celle qui les lit, et ce qui en
/// sort, ce sont des morceaux de 64 Kio. Quand le lecteur s'arrête — refus,
/// somme, annulation —, `yield` le dit, et la tâche cesse de recevoir.
struct URLSessionRangeFetcher: RangeFetcher {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(_ url: URL, range: String?) async throws -> FetchedResponse {
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let session = self.session
        let sent = request
        return try await withCheckedThrowingContinuation { head in
            Task {
                let (stream, sink) = AsyncThrowingStream<Data, Error>.makeStream()
                var answered = false
                do {
                    let (bytes, response) = try await session.bytes(for: sent)
                    let http = response as? HTTPURLResponse
                    head.resume(returning: FetchedResponse(
                        status: http?.statusCode ?? 0,
                        contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                        body: stream))
                    answered = true
                    let size = 1 << 16
                    var chunk = Data(capacity: size)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count == size {
                            if case .terminated = sink.yield(chunk) { return }
                            chunk = Data(capacity: size)
                        }
                    }
                    if !chunk.isEmpty { sink.yield(chunk) }
                    sink.finish()
                } catch {
                    // Avant la réponse, c'est la requête qui échoue ; après,
                    // c'est le corps — le lecteur l'apprend par le flux, et
                    // garde ce qu'il a déjà écrit.
                    if answered { sink.finish(throwing: error) } else { head.resume(throwing: error) }
                }
            }
        }
    }
}

/// L'état de la feuille « Télécharger » : les bureaux prêts et les images des
/// distributions, puis un téléchargement à la fois, avec son progrès.
@Observable
@MainActor
final class ImageDownloadModel {
    enum Phase: Equatable {
        case loadingIndex
        case ready
        case downloading(file: String)
        /// Les deux fichiers d'un bureau prêt, puis son installation.
        case fetchingDesktop(title: String)
        case installingDesktop(title: String)
        case failed(String)
    }

    private(set) var desktops: [ReadyDesktop] = []
    private(set) var releases: [ImageDownload.Release] = []
    private(set) var phase = Phase.loadingIndex
    /// Octets reçus et taille attendue, pendant un téléchargement.
    private(set) var progress: (have: Int, total: Int) = (0, 0)
    /// Où en est le bureau prêt qu'on télécharge : l'étape, sur les deux.
    private(set) var desktopProgress: ReadyDesktop.Progress?
    /// Pourquoi le dernier bureau prêt n'a pas été installé. À part de
    /// `phase` : la liste reste à l'écran, et la raison sous sa ligne.
    private(set) var desktopFailure: (title: String, why: String)?

    private let downloader: ImageDownloader?

    init() {
        downloader = (try? KernelLibrary.downloadsDirectory()).map {
            ImageDownloader(fetcher: URLSessionRangeFetcher(), partsFolder: $0)
        }
    }

    func loadIndex() async {
        guard let downloader else {
            phase = .failed("le dossier des téléchargements n'a pas pu être créé.")
            return
        }
        phase = .loadingIndex
        // **Les bureaux prêts et les distributions ensemble**, et l'un qui ne
        // répond pas ne cache pas l'autre (`ImageDownloader.catalog`). Tant
        // que la release des bureaux n'existe pas, leur section ne se montre
        // pas, sans un mot.
        let catalog = await downloader.catalog()
        desktops = catalog.desktops
        releases = catalog.releases
        phase = catalog.failure.map(Phase.failed) ?? .ready
    }

    /// La mémoire que ce téléphone peut donner à une machine PC, maintenant.
    var ceiling: UInt64 { KernelMemory.ceiling(for: .x86_64) }

    /// L'image du bureau est-elle déjà dans la bibliothèque ?
    func imagePresent(_ desktop: ReadyDesktop) -> Bool {
        (try? KernelLibrary.directory()).map(desktop.imagePresent(in:)) ?? false
    }

    /// Télécharge `release` dans la bibliothèque ; rend son adresse, ou `nil`
    /// si le téléchargement a échoué — la raison est alors dans `phase`.
    func download(_ release: ImageDownload.Release) async -> URL? {
        guard downloader != nil, (try? KernelLibrary.directory()) != nil else {
            phase = .failed("la bibliothèque n'a pas pu être ouverte.")
            return nil
        }
        phase = .downloading(file: release.file)
        progress = (0, release.size)
        // Un fichier du même nom déjà là — Debian publie le sien sous un nom
        // sans version — sera remplacé : ce qui avait été écrit dessus ne
        // vaudra plus rien (`KernelLibrary.replaced`).
        let replacing = (try? KernelLibrary.directory()).map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(release.file).path)
        } ?? false
        do {
            // **Par la session d'arrière-plan** : le transfert continue
            // quand l'application quitte l'écran, et l'image est recousue
            // et vérifiée au réveil. Voir `BackgroundImageDownloads`.
            let url = try await BackgroundImageDownloads.shared.download(release) { have, total in
                Task { @MainActor [weak self] in self?.progress = (have, total) }
            }
            if replacing { KernelLibrary.replaced(release.file) }
            phase = .ready
            return url
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    /// **Un bureau prêt** : l'image dans la bibliothèque, l'archive dans les
    /// téléchargements — les deux par la session d'arrière-plan, vérifiés à
    /// leur somme —, puis l'installation, qui vérifie le noyau de l'image
    /// avant d'importer (`ReadyDesktop.install`). Rend la machine installée,
    /// ou `nil` ; la raison est alors dans `desktopFailure`.
    func install(_ desktop: ReadyDesktop) async -> InstalledMachine? {
        desktopFailure = nil
        guard desktop.fits(ceiling: ceiling) else {
            desktopFailure = (desktop.title, desktop.memoryPhrase(ceiling: ceiling))
            return nil
        }
        guard let library = try? KernelLibrary.directory(),
              let downloads = try? KernelLibrary.downloadsDirectory()
        else {
            desktopFailure = (desktop.title, "la bibliothèque n'a pas pu être ouverte.")
            return nil
        }
        phase = .fetchingDesktop(title: desktop.title)
        desktopProgress = nil
        defer {
            desktopProgress = nil
            phase = .ready
        }
        do {
            let files = try await desktop.fetch(
                library: library, downloads: downloads,
                download: { release, destination, progress in
                    try await BackgroundImageDownloads.shared.download(
                        release, into: destination, progress: progress)
                },
                progress: { step in
                    Task { @MainActor [weak self] in self?.desktopProgress = step }
                },
                // Une image du même nom, d'une autre taille, vient d'être
                // remplacée : dit **tout de suite**, avant l'archive, qui
                // peut encore tomber (voir `download`, et `ReadyDesktop.fetch`).
                replacedImage: { KernelLibrary.replaced($0) })
            phase = .installingDesktop(title: desktop.title)
            // **Hors du fil principal** : le noyau sort de l'image de 1,4 Gio,
            // et l'archive, de quelques centaines de mégaoctets, est recopiée.
            return try await Task.detached(priority: .userInitiated) {
                #if WISQ_RUST_CORE
                let digest = IsoBoot.kernelDigest(
                    of: files.image, scratch: FileManager.default.temporaryDirectory
                        .appendingPathComponent("wisq-empreinte", isDirectory: true),
                    ceiling: 256 << 20)
                #else
                // Sans le cœur Rust, pas de lecteur d'image : le noyau ne se
                // lit pas, et l'installation le refuse en le disant.
                let digest: String? = nil
                #endif
                return try KernelLibrary.installReadyDesktop(desktop, archive: files.archive, kernelDigest: digest)
            }.value
        } catch {
            desktopFailure = (desktop.title, error.localizedDescription)
            return nil
        }
    }
}
#endif
