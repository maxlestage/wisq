#if os(iOS)
import Foundation
import Observation
import WisqVM

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

/// L'état de la feuille « Télécharger » : l'index, puis un téléchargement à
/// la fois, avec son progrès.
@Observable
@MainActor
final class ImageDownloadModel {
    enum Phase: Equatable {
        case loadingIndex
        case ready
        case downloading(file: String)
        case failed(String)
    }

    private(set) var releases: [ImageDownload.Release] = []
    private(set) var phase = Phase.loadingIndex
    /// Octets reçus et taille attendue, pendant un téléchargement.
    private(set) var progress: (have: Int, total: Int) = (0, 0)

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
        do {
            releases = try await downloader.bootableReleases()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
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
}
#endif
