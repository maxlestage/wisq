#if os(iOS)
import Foundation
import WisqVM

/// **Les téléchargements qui continuent quand wisq n'est plus à l'écran.**
///
/// Une session `URLSession` d'arrière-plan : le système mène le transfert
/// lui-même, l'application endormie ou même tuée, et la réveille pour lui
/// rendre le fichier. Elle ne rend pas les octets au fil de l'eau, mais un
/// fichier entier à la fin : `ImageDownloader.adopt` le recoud sur le `.part`
/// et vérifie l'image, avec les règles du téléchargement à l'écran. La
/// reprise reste la nôtre — l'en-tête `Range` que dit `backgroundRequest` —,
/// et une coupure garde ce que le `.part` avait déjà.
///
/// Chaque tâche porte l'image qu'elle télécharge dans sa description
/// (`Release.backgroundTag`) : c'est la seule chose qu'une session garde
/// d'une vie de l'application à la suivante.
final class BackgroundImageDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundImageDownloads()
    static let identifier = "fr.wisq.telechargements"

    /// Ce qu'une tâche a rendu : l'image rangée, ou la raison de l'échec.
    typealias Outcome = Result<URL, Error>

    private let lock = NSLock()
    /// Ceux qui attendent la fin d'un téléchargement, par fichier : la
    /// feuille « Télécharger », quand elle est ouverte.
    private var waiting: [String: CheckedContinuation<URL, Error>] = [:]
    /// Le progrès, par fichier : octets reçus et taille attendue.
    private var observers: [String: @Sendable (Int, Int) -> Void] = [:]
    /// Ce que le `.part` avait quand la tâche est partie : le progrès de la
    /// session compte à partir de là.
    private var startedAt: [String: Int] = [:]
    /// Le bloc que le système a confié au réveil, à appeler une fois tous
    /// les événements de la session rendus (`urlSessionDidFinishEvents`).
    private var wakeCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        // Une image demandée tout de suite : pas d'attente d'une prise de
        // courant ou du Wi-Fi, que le système choisirait sinon.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// La session est créée tout de suite, et une seule fois : `lazy` n'est
    /// pas protégé contre deux fils, et le délégué en appelle d'autres.
    override private init() {
        super.init()
        _ = session
    }

    private func downloader() throws -> ImageDownloader {
        ImageDownloader(fetcher: URLSessionRangeFetcher(), partsFolder: try KernelLibrary.downloadsDirectory())
    }

    /// Télécharge `release` par la session d'arrière-plan, et rend l'image
    /// rangée. `progress` reçoit les octets reçus — ceux du `.part` compris —
    /// et la taille attendue.
    func download(_ release: ImageDownload.Release,
                  progress: @escaping @Sendable (Int, Int) -> Void) async throws -> URL {
        let downloader = try downloader()
        let library = try KernelLibrary.directory()
        // Plus rien à recevoir : il ne reste qu'à vérifier ce qui est là.
        guard let request = try downloader.backgroundRequest(for: release) else {
            return try downloader.adopt(URL(fileURLWithPath: "/dev/null"), status: 416,
                                        contentRange: "bytes */\(release.size)",
                                        for: release, into: library)
        }
        let have = release.size - (try partRemaining(release))
        progress(have, release.size)
        var urlRequest = URLRequest(url: request.url)
        if let range = request.range { urlRequest.setValue(range, forHTTPHeaderField: "Range") }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                // Un second appui pendant un téléchargement : le premier est
                // remplacé, et c'est la dernière feuille qui l'apprend.
                waiting[release.file]?.resume(throwing: CancellationError())
                waiting[release.file] = continuation
                observers[release.file] = progress
                startedAt[release.file] = have
            }
            session.getAllTasks { tasks in
                // Une tâche déjà en cours pour ce fichier — lancée avant que
                // l'application ne s'endorme — continue : on l'attend.
                if tasks.contains(where: { $0.taskDescription == release.backgroundTag && $0.state == .running }) {
                    return
                }
                let task = self.session.downloadTask(with: urlRequest)
                task.taskDescription = release.backgroundTag
                task.resume()
            }
        }
    }

    /// Ce qu'il reste à recevoir, d'après le `.part`.
    private func partRemaining(_ release: ImageDownload.Release) throws -> Int {
        let part = ImageDownload.partURL(for: try KernelLibrary.downloadsDirectory()
            .appendingPathComponent(release.file))
        let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
        return max(0, release.size - min(have, release.size))
    }

    /// Le réveil par le système : la session est recréée sous le même nom,
    /// et ses événements arrivent au délégué.
    func wake(completion: @escaping () -> Void) {
        lock.withLock { wakeCompletion = completion }
    }

    // MARK: - URLSessionDownloadDelegate

    /// **Le fichier doit être recousu ici, avant de rendre la main** : la
    /// session l'efface dès que cette méthode revient.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let tag = downloadTask.taskDescription,
              let release = ImageDownload.Release(backgroundTag: tag) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let outcome: Outcome = Result {
            try downloader().adopt(location, status: http?.statusCode ?? 0,
                                   contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                                   for: release, into: try KernelLibrary.directory())
        }
        finish(release.file, outcome)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let tag = downloadTask.taskDescription,
              let release = ImageDownload.Release(backgroundTag: tag) else { return }
        let (observer, start) = lock.withLock { (observers[release.file], startedAt[release.file] ?? 0) }
        observer?(min(start + Int(totalBytesWritten), release.size), release.size)
    }

    /// Une tâche qui finit en erreur — réseau coupé, annulée — n'a rien
    /// recousu : le `.part` garde ce qu'il avait, et le prochain essai
    /// reprend là.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let tag = task.taskDescription,
              let release = ImageDownload.Release(backgroundTag: tag) else { return }
        finish(release.file, .failure(error))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            defer { wakeCompletion = nil }
            return wakeCompletion
        }
        DispatchQueue.main.async { completion?() }
    }

    private func finish(_ file: String, _ outcome: Outcome) {
        let continuation = lock.withLock {
            defer {
                waiting[file] = nil
                observers[file] = nil
                startedAt[file] = nil
            }
            return waiting[file]
        }
        continuation?.resume(with: outcome)
    }
}
/// **Le réveil, pour l'application.** Le système relance wisq quand une
/// session d'arrière-plan a des événements à rendre, et lui confie un bloc à
/// appeler une fois qu'ils sont traités : `UIApplicationDelegate` le passe
/// ici. Une session d'un autre nom n'est pas la nôtre, et son bloc est
/// appelé tout de suite.
public enum BackgroundDownloads {
    public static func handleEvents(forSession identifier: String, completion: @escaping () -> Void) {
        guard identifier == BackgroundImageDownloads.identifier else {
            completion()
            return
        }
        BackgroundImageDownloads.shared.wake(completion: completion)
    }
}
#endif
