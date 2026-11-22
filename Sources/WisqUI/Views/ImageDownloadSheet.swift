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
    @State private var model: ImageDownloadModel
    /// Lire les index en ouvrant la feuille : toujours, sauf pour un modèle
    /// déjà posé (`ImageDownloadModel.init(posing:...)`).
    private let loadsIndex: Bool
    /// Le bureau qu'on s'apprête à réinstaller à côté d'une machine qui
    /// démarre déjà son image : la feuille demande d'abord.
    @State private var confirming: ReadyDesktop?

    init(onDownloaded: @escaping (URL) -> Void, onInstalled: @escaping (InstalledMachine) -> Void) {
        self.onDownloaded = onDownloaded
        self.onInstalled = onInstalled
        _model = State(initialValue: ImageDownloadModel())
        loadsIndex = true
    }

    /// **La feuille d'un modèle déjà posé**, qui ne lit aucun index : ce que
    /// les aperçus de l'interface photographient.
    init(posed: ImageDownloadModel) {
        onDownloaded = { _ in }
        onInstalled = { _ in }
        _model = State(initialValue: posed)
        loadsIndex = false
    }

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
                if let why = model.desktopsFailure {
                    // **L'index des bureaux n'a pas répondu** : dit, et
                    // relisible, au lieu d'une section absente sans un mot.
                    Section {
                        RefusalLabel(text: why)
                            .foregroundStyle(.orange)
                        Button("Réessayer") { Task { await model.loadIndex() } }
                    } header: {
                        Text("Bureaux prêts")
                    }
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
                    } header: {
                        Text("Images des distributions")
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
            .task { if loadsIndex { await model.loadIndex() } }
            .confirmationDialog(
                "Installer une autre machine ?",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { desktop in
                Button("Installer une autre machine") { start(desktop) }
                Button("Annuler", role: .cancel) {}
            } message: { desktop in
                Text(model.alreadyInstalled(desktop) ?? "")
            }
        }
    }

    /// Lance le téléchargement et l'installation d'un bureau prêt.
    private func start(_ desktop: ReadyDesktop) {
        Task {
            if let machine = await model.install(desktop) {
                onInstalled(machine)
                dismiss()
            }
        }
    }

    /// **Une image d'une distribution** : son badge, son nom et sa version,
    /// ce qu'elle pèse ; à droite « Obtenir », ou l'anneau de sa progression.
    @ViewBuilder
    private func row(_ release: ImageDownload.Release) -> some View {
        let downloading = model.phase == .downloading(file: release.file)
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.m) {
                DistributionBadge(distribution: MachineBadge.distribution(of: [release.distribution, release.file]),
                                  size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(release.distribution) \(release.version)")
                        .font(.body.weight(.semibold))
                    Text("\(release.title) · \(LocalStorage.describe(bytes: release.size))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(release.file) · \(release.checksum.algorithm)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Design.Space.s)
                if downloading {
                    ProgressRing(fraction: fraction(model.progress.have, model.progress.total))
                        .accessibilityLabel("Téléchargement de \(release.file)")
                        .accessibilityValue("\(MachineCardText.percent(have: model.progress.have, total: model.progress.total)) %")
                } else {
                    Button {
                        Task {
                            if let url = await model.download(release) {
                                onDownloaded(url)
                                dismiss()
                            }
                        }
                    } label: {
                        Text("Obtenir")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(isDownloading)
                    .accessibilityLabel("Télécharger \(release.file)")
                }
            }
            if downloading, model.progress.total > 0 {
                ProgressView(value: Double(model.progress.have), total: Double(model.progress.total))
                    .tint(Design.accent)
                Text(MachineCardText.progress(have: model.progress.have, total: model.progress.total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Design.Space.xs)
    }

    /// **Un bureau prêt, en carte** : ce que c'est, ce que ça coûte, ce que
    /// ça donne, et un seul bouton évident ; puis, pendant le téléchargement,
    /// l'étape et un seul progrès sur les deux fichiers.
    @ViewBuilder
    private func desktopRow(_ desktop: ReadyDesktop) -> some View {
        let fetching = model.phase == .fetchingDesktop(title: desktop.title)
        let installingNow = model.phase == .installingDesktop(title: desktop.title)
        let fits = desktop.fits(ceiling: model.ceiling)
        let shortfall = fetching || installingNow ? nil : model.spaceShortfall(desktop)
        let installed = model.alreadyInstalled(desktop)
        VStack(alignment: .leading, spacing: Design.Space.m) {
            HStack(alignment: .top, spacing: Design.Space.m) {
                DistributionBadge(distribution: MachineBadge.distribution(of: [desktop.title, desktop.image.file]),
                                  desktop: true, size: 56)
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    Text(desktop.title)
                        .font(.title3.weight(.bold))
                    Text(desktop.madePhrase)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            FlowLayout(spacing: Design.Space.s) {
                ChipLabel(text: LocalStorage.describe(bytes: model.imagePresent(desktop)
                    ? desktop.archive.size : desktop.image.size + desktop.archive.size),
                          symbol: "arrow.down.circle")
                ChipLabel(text: KernelMemory.describe(desktop.ramBytes), symbol: "memorychip",
                          color: fits ? .primary : .orange)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(desktop.sizePhrase(imagePresent: model.imagePresent(desktop))) \(desktop.memoryPhrase(ceiling: model.ceiling))")
            Text(desktop.sizePhrase(imagePresent: model.imagePresent(desktop)))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !fits {
                Text(desktop.memoryPhrase(ceiling: model.ceiling))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let shortfall {
                Text(shortfall)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let installed {
                Text(installed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let background = model.inBackground(desktop) {
                Text(background)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if fetching {
                if let step = model.desktopProgress, step.total > 0 {
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        HStack {
                            Text(step.step == .image ? "L'image" : "Le bureau")
                                .font(.subheadline.weight(.semibold))
                            Text("étape \(step.number) sur \(step.steps)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(MachineCardText.percent(have: step.have, total: step.total)) %")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                        }
                        ProgressView(value: Double(step.have), total: Double(step.total))
                            .tint(Design.accent)
                        Text(step.phrase)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Fermer la feuille ne l'arrête pas : le téléchargement continue en arrière-plan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // **Annuler**, pendant l'un ou l'autre fichier : le transfert
                // s'arrête, et la ligne dit ce qui est gardé.
                Button(role: .destructive) {
                    model.cancelDesktop(desktop)
                } label: {
                    Label("Annuler", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Annuler le téléchargement de \(desktop.title)")
            } else if installingNow {
                HStack(spacing: Design.Space.m) {
                    ProgressView()
                    Text("Vérification de l'image et installation du bureau…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    // Une machine démarre déjà cette image : installer en
                    // ajoute une autre, et la feuille le demande d'abord.
                    if installed != nil { confirming = desktop } else { start(desktop) }
                } label: {
                    Label("Installer", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(isDownloading || !fits || shortfall != nil)
                .accessibilityLabel("Installer \(desktop.title)")
            }
            if let failure = model.desktopFailure, failure.title == desktop.title {
                RefusalLabel(text: failure.why)
                    .foregroundStyle(.red)
            }
        }
        .card()
        .cardRow()
    }

    private func fraction(_ have: Int, _ total: Int) -> Double {
        Double(MachineCardText.percent(have: have, total: total)) / 100
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
/// **L'anneau d'un téléchargement**, à la place du bouton « Obtenir »,
/// comme dans l'App Store.
private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Design.chipFill, lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.02, min(fraction, 1)))
                .stroke(Design.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            RoundedRectangle(cornerRadius: 2).fill(Design.accent).frame(width: 9, height: 9)
        }
        .frame(width: 30, height: 30)
    }
}
#endif
