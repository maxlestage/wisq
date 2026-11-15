#if os(iOS)
import SwiftUI
import WisqVM

/// La feuille « Télécharger » : les images qu'Alpine, Debian, Fedora et
/// Ubuntu publient et qui démarrent ici, lues dans leurs index au moment
/// d'ouvrir la feuille, et le progrès de celle qu'on télécharge.
///
/// Rien n'est promis avant la fin : l'image n'entre dans la bibliothèque
/// qu'entière et à la somme que publie la distribution. Une coupure garde ce
/// qui est arrivé ; le bouton, rappuyé, reprend là.
///
/// **En tête, les bureaux prêts** (`ReadyDesktop`) : un bureau déjà démarré
/// par wisq, prêt en moins d'une minute. La section ne se montre que si leur
/// index a répondu ; tant que la release des bureaux n'existe pas, la feuille
/// est celle d'avant.
struct ImageDownloadSheet: View {
    let onDownloaded: (URL) -> Void
    let onInstalled: (InstalledMachine) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model = ImageDownloadModel()

    var body: some View {
        NavigationStack {
            List {
                switch model.phase {
                case .loadingIndex:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Lecture des index d'Alpine, de Debian, de Fedora et d'Ubuntu…")
                            .foregroundStyle(.secondary)
                    }
                case .failed(let why):
                    Section {
                        RefusalLabel(text: why)
                            .foregroundStyle(.red)
                        Button("Réessayer") { Task { await model.loadIndex() } }
                    }
                default:
                    EmptyView()
                }
                if !model.desktops.isEmpty {
                    Section {
                        ForEach(model.desktops, id: \.title) { desktop in
                            desktopRow(desktop)
                        }
                    } header: {
                        Text("Bureaux prêts")
                    } footer: {
                        Text(ReadyDesktop.sharedNote)
                    }
                }
                if !model.releases.isEmpty {
                    Section {
                        ForEach(model.releases, id: \.file) { release in
                            row(release)
                        }
                    } footer: {
                        Text("L'image n'entre dans la bibliothèque qu'entière et à la somme que publie sa distribution. Un téléchargement interrompu reprend où il s'était arrêté. L'image de Debian démarre telle quelle : wisq demandera le mot de passe de root au premier démarrage.")
                    }
                }
            }
            .navigationTitle("Télécharger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .task { await model.loadIndex() }
        }
    }

    @ViewBuilder
    private func row(_ release: ImageDownload.Release) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(release.distribution) \(release.version) — \(release.title)")
                        .font(.body.weight(.semibold))
                    Text("\(release.file) · \(LocalStorage.describe(bytes: release.size)) · \(release.checksum.algorithm)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if model.phase == .downloading(file: release.file) {
                    ProgressView()
                } else {
                    Button {
                        Task {
                            if let url = await model.download(release) {
                                onDownloaded(url)
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Télécharger", systemImage: "arrow.down.circle")
                            .labelStyle(.iconOnly)
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isDownloading)
                    .accessibilityLabel("Télécharger \(release.file)")
                }
            }
            if model.phase == .downloading(file: release.file), model.progress.total > 0 {
                ProgressView(value: Double(model.progress.have), total: Double(model.progress.total))
                Text("\(LocalStorage.describe(bytes: model.progress.have)) sur \(LocalStorage.describe(bytes: model.progress.total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// **Une ligne de bureau prêt** : ce que c'est, ce que ça coûte, ce que
    /// ça donne ; puis, pendant le téléchargement, l'étape et un seul progrès
    /// sur les deux fichiers.
    @ViewBuilder
    private func desktopRow(_ desktop: ReadyDesktop) -> some View {
        let busy = model.phase == .fetchingDesktop(title: desktop.title)
            || model.phase == .installingDesktop(title: desktop.title)
        let fits = desktop.fits(ceiling: model.ceiling)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(desktop.title)
                        .font(.body.weight(.semibold))
                    Text(desktop.madePhrase)
                        .font(.caption)
                    Text(desktop.sizePhrase(imagePresent: model.imagePresent(desktop)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(desktop.memoryPhrase(ceiling: model.ceiling))
                        .font(.caption)
                        .foregroundStyle(fits ? Color.secondary : Color.orange)
                }
                Spacer(minLength: 12)
                if busy {
                    ProgressView()
                } else {
                    Button {
                        Task {
                            if let machine = await model.install(desktop) {
                                onInstalled(machine)
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Installer", systemImage: "arrow.down.circle")
                            .labelStyle(.iconOnly)
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isDownloading || !fits)
                    .accessibilityLabel("Installer \(desktop.title)")
                }
            }
            if model.phase == .fetchingDesktop(title: desktop.title), let step = model.desktopProgress,
               step.total > 0 {
                ProgressView(value: Double(step.have), total: Double(step.total))
                Text(step.phrase)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.phase == .installingDesktop(title: desktop.title) {
                Text("Vérification de l'image et installation du bureau…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failure = model.desktopFailure, failure.title == desktop.title {
                RefusalLabel(text: failure.why)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    /// Un téléchargement en cours, d'une image ou d'un bureau prêt : un seul
    /// à la fois.
    private var isDownloading: Bool {
        switch model.phase {
        case .downloading, .fetchingDesktop, .installingDesktop: return true
        default: return false
        }
    }
}
#endif
