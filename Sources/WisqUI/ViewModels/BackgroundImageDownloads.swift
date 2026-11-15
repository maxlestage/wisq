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
/// Chaque tâche porte l'image qu'elle télécharge, et le dossier où la ranger,
/// dans sa description (`ImageDownload.BackgroundJob.tag`) : c'est la seule
/// chose qu'une session garde d'une vie de l'application à la suivante. Une
/// image va dans la bibliothèque ; l'archive d'un bureau prêt, dans les
/// téléchargements, d'où `ReadyDesktop.install` l'importe.
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

    private func makeDownloader() throws -> ImageDownloader {
        ImageDownloader(fetcher: URLSessionRangeFetcher(), partsFolder: try KernelLibrary.downloadsDirectory())
    }

    /// Le dossier d'une destination.
    static func folder(for destination: ImageDownload.Destination) throws -> URL {
        switch destination {
        case .library: return try KernelLibrary.directory()
        case .downloads: return try KernelLibrary.downloadsDirectory()
        }
    }

    /// Télécharge `release` par la session d'arrière-plan, et rend le fichier
    /// rangé sous `destination`. `progress` reçoit les octets reçus — ceux du
    /// `.part` compris — et la taille attendue.
    func download(_ release: ImageDownload.Release, into destination: ImageDownload.Destination = .library,
                  progress: @escaping @Sendable (Int, Int) -> Void) async throws -> URL {
        let downloader = try makeDownloader()
        let folder = try Self.folder(for: destination)
        let job = ImageDownload.BackgroundJob(release: release, destination: destination)
        // Plus rien à recevoir : il ne reste qu'à vérifier ce qui est là.
        guard let request = try downloader.backgroundRequest(for: release) else {
            return try downloader.adopt(URL(fileURLWithPath: "/dev/null"), status: 416,
                                        contentRange: "bytes */\(release.size)",
                                        for: release, into: folder)
        }
        let have = release.size - (try partRemaining(release))
        progress(have, release.size)
        var built = URLRequest(url: request.url)
        if let range = request.range { built.setValue(range, forHTTPHeaderField: "Range") }
        let urlRequest = built
        // **Une annulation arrête le transfert**, et pas seulement l'attente :
        // la continuation ne voit pas l'annulation de la tâche qui l'attend,
        // et « Annuler » laissait 1,4 Gio continuer en arrière-plan.
        return try await withTaskCancellationHandler {
            try await transfer(release, job: job, request: urlRequest, have: have, progress: progress)
        } onCancel: {
            self.cancel(release.file)
        }
    }

    private func transfer(_ release: ImageDownload.Release, job: ImageDownload.BackgroundJob,
                          request urlRequest: URLRequest, have: Int,
                          progress: @escaping @Sendable (Int, Int) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // Annulée avant même d'attendre : rien ne part.
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            lock.withLock {
                // Un second appui pendant un téléchargement : le premier est
                // remplacé, et c'est la dernière feuille qui l'apprend.
                waiting[release.file]?.resume(throwing: CancellationError())
                waiting[release.file] = continuation
                observers[release.file] = progress
                startedAt[release.file] = have
            }
            session.getAllTasks { tasks in
                // Les tâches se comparent par ce qu'elles décrivent, pas par
                // leur texte : celui d'une version d'avant n'avait pas ses
                // clés dans un ordre fixe. Et **par le fichier qu'elles
                // recousent** (`BackgroundJob.overlap`), pas par toute leur
                // description : la même ISO demandée par la liste des
                // distributions puis par « Bureaux prêts » se décrit
                // autrement, et deux transferts partaient sur un seul `.part`.
                let running = tasks.compactMap { task -> (URLSessionTask, ImageDownload.BackgroundJob)? in
                    guard task.state == .running,
                          let other = task.taskDescription.flatMap(ImageDownload.BackgroundJob.init(tag:))
                    else { return nil }
                    return (task, other)
                }
                // Une tâche déjà en cours pour ce fichier, à la même somme —
                // lancée avant que l'application ne s'endorme, ou depuis
                // l'autre liste — continue : on l'attend.
                if running.contains(where: { job.overlap(with: $0.1) == .same }) { return }
                // Le même `.part` pour un autre fichier attendu : l'ancienne
                // cesse. **Muette d'abord** — sans étiquette, sa fin ne
                // recoud rien et ne rend rien à celui qui attend ce fichier,
                // qui est désormais nous (`finish` cherche par nom).
                for (task, other) in running where job.overlap(with: other) == .conflicting {
                    task.taskDescription = nil
                    task.cancel()
                }
                // Annulée pendant qu'on cherchait les tâches : `cancel` a
                // déjà rendu la main à celui qui attendait, rien ne part.
                guard self.lock.withLock({ self.waiting[release.file] != nil }) else { return }
                let task = self.session.downloadTask(with: urlRequest)
                task.taskDescription = job.tag
                task.resume()
            }
        }
    }

    /// **Arrêter le téléchargement de `file`** : celui qui l'attend apprend
    /// l'annulation, et la tâche de la session cesse, muette — sa fin ne
    /// recoud rien. Le `.part` garde ce qu'il avait quand elle est partie ;
    /// ce qu'elle avait reçu depuis est perdu, et la feuille le dit
    /// (`ReadyDesktop.keptPhrase`).
    func cancel(_ file: String) {
        let continuation = lock.withLock {
            defer {
                waiting[file] = nil
                observers[file] = nil
                startedAt[file] = nil
            }
            return waiting[file]
        }
        continuation?.resume(throwing: CancellationError())
        session.getAllTasks { tasks in
            for task in tasks {
                guard let job = task.taskDescription.flatMap(ImageDownload.BackgroundJob.init(tag:)),
                      job.release.file == file else { continue }
                task.taskDescription = nil
                task.cancel()
            }
        }
    }

    /// **Les fichiers que la session a encore en cours**, lancés par cette
    /// vie de l'application ou par une précédente : de quoi dire, à la
    /// feuille rouverte, qu'un bureau prêt continue de se télécharger.
    func runningFiles() async -> Set<String> {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: Set(tasks.compactMap { task -> String? in
                    guard task.state == .running else { return nil }
                    return task.taskDescription.flatMap(ImageDownload.BackgroundJob.init(tag:))?.release.file
                }))
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
              let job = ImageDownload.BackgroundJob(tag: tag) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let outcome: Outcome = Result {
            try makeDownloader().adopt(location, status: http?.statusCode ?? 0,
                                   contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                                   for: job.release, into: try Self.folder(for: job.destination))
        }
        finish(job.release.file, outcome)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let tag = downloadTask.taskDescription,
              let release = ImageDownload.BackgroundJob(tag: tag)?.release else { return }
        // Un `200` à une demande de reprise : le serveur renvoie tout, et
        // `adopt` repartira de zéro — le progrès aussi, au lieu de rester à
        // 100 % pendant tout le transfert.
        let restarted = (downloadTask.response as? HTTPURLResponse)?.statusCode == 200
        let (observer, start) = lock.withLock {
            (observers[release.file], restarted ? 0 : startedAt[release.file] ?? 0)
        }
        observer?(min(start + Int(totalBytesWritten), release.size), release.size)
    }

    /// Une tâche qui finit en erreur — réseau coupé, annulée — n'a rien
    /// recousu : le `.part` garde ce qu'il avait, et le prochain essai
    /// reprend là.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let tag = task.taskDescription,
              let release = ImageDownload.BackgroundJob(tag: tag)?.release else { return }
        finish(release.file, .failure(error))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            defer { wakeCompletion = nil }
            return wakeCompletion
        }
        // Le bloc vient du système, qui demande qu'on l'appelle sur le fil
        // principal ; il n'est pas déclaré `Sendable`, et ne fait que dire au
        // système que la session a fini.
        nonisolated(unsafe) let handler = completion
        DispatchQueue.main.async { handler?() }
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
        // **Personne n'attendait** : l'application relancée par le système
        // pour cette tâche, la feuille fermée. L'image est rangée quand même,
        // et la liste l'apprend.
        if continuation == nil, case .success = outcome {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: BackgroundDownloads.libraryChanged, object: nil)
            }
        }
    }
}
/// **Le réveil, pour l'application.** Le système relance wisq quand une
/// session d'arrière-plan a des événements à rendre, et lui confie un bloc à
/// appeler une fois qu'ils sont traités : `UIApplicationDelegate` le passe
/// ici. Une session d'un autre nom n'est pas la nôtre, et son bloc est
/// appelé tout de suite.
public enum BackgroundDownloads {
    /// Une image est arrivée dans la bibliothèque sans que personne ne
    /// l'attende.
    public static let libraryChanged = Notification.Name("wisq.bibliotheque.changee")

    /// **La session recréée au lancement**, et pas au premier appui sur
    /// « Télécharger » : ses événements — un transfert fini pendant que
    /// l'application était tuée — n'arrivent qu'à une session vivante, et
    /// sans elle l'image attendait que quelqu'un rouvre la feuille.
    public static func reconnect() {
        _ = BackgroundImageDownloads.shared
    }

    public static func handleEvents(forSession identifier: String, completion: @escaping () -> Void) {
        guard identifier == BackgroundImageDownloads.identifier else {
            completion()
            return
        }
        BackgroundImageDownloads.shared.wake(completion: completion)
    }
}
#endif
