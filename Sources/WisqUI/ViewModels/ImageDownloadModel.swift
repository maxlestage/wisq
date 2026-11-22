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
    /// Pourquoi l'index des bureaux prêts n'a pas été lu, sauf un 404
    /// (`ImageDownloader.readyCatalog`) : dit dans la feuille, avec
    /// « Réessayer », au lieu d'une section qui disparaît sans un mot.
    private(set) var desktopsFailure: String?
    /// Les fichiers que la session d'arrière-plan a encore en cours, lus à
    /// l'ouverture : un bureau prêt lancé avant que wisq ne soit fermé.
    /// Relus quand « Installer » est touché, avant `fetch` ; ceux du bureau
    /// suivi en sortent quand son `fetch` rend la main, sauf sur le refus de
    /// la place, qui ne suit rien (`ReadyDesktop.followed(running:after:)`).
    private(set) var runningFiles: Set<String> = []
    /// Le téléchargement du bureau prêt en cours, pour « Annuler ».
    private var desktopTask: Task<InstalledMachine?, Never>?

    private let downloader: ImageDownloader?

    init() {
        downloader = (try? KernelLibrary.downloadsDirectory()).map {
            ImageDownloader(fetcher: URLSessionRangeFetcher(), partsFolder: $0)
        }
    }

    /// **Un état posé, sans réseau** : ce que les aperçus de l'interface
    /// (`Tests/WisqApercus`) montrent de la feuille — des bureaux, des images,
    /// un téléchargement en cours. Sans téléchargeur : rien ne part. Interne
    /// au module, et rien dans l'application ne l'appelle.
    init(posing desktops: [ReadyDesktop], releases: [ImageDownload.Release], phase: Phase,
         progress: (have: Int, total: Int) = (0, 0), desktopProgress: ReadyDesktop.Progress? = nil) {
        downloader = nil
        self.desktops = desktops
        self.releases = releases
        self.phase = phase
        self.progress = progress
        self.desktopProgress = desktopProgress
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
        // **Le bureau du cœur qui tournera** : celui de la machine PC en Rust
        // quand elle est là et son réglage allumé, celui du cœur Swift sinon
        // (`ReadyDesktop.parse`). Une session reprend sur le cœur qui l'a
        // écrite : un bureau du cœur Swift tournerait sur le plus lent.
        #if WISQ_RUST_CORE
        let rustCore = RustPCSetting.isEnabled(in: .standard)
        #else
        let rustCore = false
        #endif
        let catalog = await downloader.catalog(rustCore: rustCore)
        desktops = catalog.desktops
        releases = catalog.releases
        desktopsFailure = catalog.desktopsFailure
        runningFiles = await BackgroundImageDownloads.shared.runningFiles()
        phase = catalog.failure.map(Phase.failed) ?? .ready
    }

    /// La place libre du téléphone, lue à chaque affichage : elle change
    /// quand la personne en libère, la feuille ouverte.
    var available: Int? {
        (try? KernelLibrary.directory()).flatMap(LocalStorage.availableBytes(at:))
    }

    /// La phrase de la place qui manque pour `desktop`, ou `nil`.
    func spaceShortfall(_ desktop: ReadyDesktop) -> String? {
        guard let library = try? KernelLibrary.directory(),
              let downloads = try? KernelLibrary.downloadsDirectory() else { return nil }
        // Un fichier de ce bureau en cours en arrière-plan est mis à part du
        // compte, et lui seul : le reste et l'installation se comptent.
        return desktop.spaceShortfall(available: available, library: library, downloads: downloads,
                                      running: runningFiles)
    }

    /// Ce qu'installer de nouveau laisserait tel quel, dit avant (`ReadyDesktop.alreadyInstalledPhrase`).
    func alreadyInstalled(_ desktop: ReadyDesktop) -> String? {
        desktop.alreadyInstalledPhrase(desktop.installedCopies(among: InstalledMachines.list()))
    }

    /// Un téléchargement de ce bureau qui continue en arrière-plan, dit.
    func inBackground(_ desktop: ReadyDesktop) -> String? {
        guard phase != .fetchingDesktop(title: desktop.title) else { return nil }
        // Ce qui se dit est décidé dans `WisqVM`, où il se teste : un fichier
        // rangé depuis l'ouverture ne « continue » plus, et la place qui
        // manque au reste le dit à sa place.
        return desktop.backgroundPhrase(running: runningFiles, library: try? KernelLibrary.directory(),
                                        downloads: try? KernelLibrary.downloadsDirectory(),
                                        available: available)
    }

    /// **« Annuler »** : la tâche du bureau prêt est annulée, ce qui arrête
    /// le transfert de la session d'arrière-plan (`BackgroundImageDownloads.download`)
    /// et empêche l'archive de partir après l'image (`ReadyDesktop.fetch`).
    /// Les fichiers de ce bureau qui couraient déjà en arrière-plan à
    /// l'ouverture sont arrêtés aussi : `fetch` ne les a peut-être pas encore
    /// rejoints (annulé avant, ou encore à l'image quand c'est le bureau qui
    /// court), et la ligne, qui les retire des fichiers en cours, ne doit
    /// pas laisser un transfert courir sans le dire.
    func cancelDesktop(_ desktop: ReadyDesktop) {
        desktopTask?.cancel()
        for file in desktop.backgroundFiles(running: runningFiles) {
            BackgroundImageDownloads.shared.cancel(file)
        }
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
        let task = Task { await fetchAndInstall(desktop) }
        desktopTask = task
        defer { desktopTask = nil }
        return await task.value
    }

    private func fetchAndInstall(_ desktop: ReadyDesktop) async -> InstalledMachine? {
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
        // **Relus au toucher, pas repris de l'ouverture** : `fetch` ne
        // refuse pas un téléchargement de ce bureau qui court déjà en
        // arrière-plan, il le suit sans garde de place. Le relevé de
        // l'ouverture a pu vieillir, la feuille ouverte : une tâche de fond
        // tombée depuis y figurait encore, et toute l'image repartait sans
        // que la place soit comptée. Un fichier fini depuis, lui, est écarté
        // par `ReadyDesktop.followable`.
        let running = await BackgroundImageDownloads.shared.runningFiles()
        runningFiles = running
        var failure: Error?
        defer {
            // Suivi jusqu'au bout — fini, en panne ou annulé : plus rien de
            // ce bureau ne court en arrière-plan, et la ligne ne le dit plus.
            // Sauf après le refus de la place : rien n'a été suivi, et le
            // transfert de fond qui courait continue (`ReadyDesktop.followed`).
            runningFiles = desktop.followed(running: runningFiles, after: failure)
            desktopProgress = nil
            phase = .ready
        }
        do {
            // **La place, avant le premier octet** : sans elle, le téléphone
            // plein faisait tomber l'écriture au milieu de 1,4 Gio.
            let files = try await desktop.fetch(
                library: library, downloads: downloads, available: available, running: running,
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
        } catch is CancellationError {
            failure = CancellationError()
            // Ce qui reste, dit tel qu'il est sur le disque.
            desktopFailure = (desktop.title, desktop.keptPhrase(library: library, downloads: downloads))
            return nil
        } catch {
            failure = error
            desktopFailure = (desktop.title, error.localizedDescription)
            return nil
        }
    }
}
#endif
