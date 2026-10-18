#if os(iOS)
import SwiftUI
import WisqVM

/// La feuille « Télécharger » : les images qu'Alpine publie et qui démarrent
/// ici, lues dans son index au moment d'ouvrir la feuille, et le progrès de
/// celle qu'on télécharge.
///
/// Rien n'est promis avant la fin : l'image n'entre dans la bibliothèque
/// qu'entière et à la somme que publie la distribution. Une coupure garde ce
/// qui est arrivé ; le bouton, rappuyé, reprend là.
struct ImageDownloadSheet: View {
    let onDownloaded: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model = ImageDownloadModel()

    var body: some View {
        NavigationStack {
            List {
                switch model.phase {
                case .loadingIndex:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Lecture de l'index d'Alpine…")
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
                if !model.releases.isEmpty {
                    Section {
                        ForEach(model.releases, id: \.file) { release in
                            row(release)
                        }
                    } footer: {
                        Text("L'image n'entre dans la bibliothèque qu'entière et à la somme SHA-256 que publie Alpine. Un téléchargement interrompu reprend où il s'était arrêté.")
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
                    Text("Alpine \(release.version) — \(release.title)")
                        .font(.body.weight(.semibold))
                    Text("\(release.file) · \(LocalStorage.describe(bytes: release.size))")
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

    private var isDownloading: Bool {
        if case .downloading = model.phase { return true }
        return false
    }
}
#endif
