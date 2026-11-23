#if os(iOS)
import SwiftUI
import WisqVM
#if WISQ_RUST_CORE
import WisqVMRust
#endif

/// **La feuille d'avant le démarrage** : la plateforme de l'image, celle du
/// téléphone, ce qui va se passer — puis « Démarrer », ou non.
///
/// Elle s'ouvre à chaque machine touchée, avant la console, parce que la
/// demande était sans exception : « être informé de la plateforme avant de
/// démarrer quoi que ce soit ». Ce qu'elle dit est décidé par
/// `BootAnnouncement`, que la CI Linux tient ; cette vue ne fait que le
/// dessiner, et lire le noyau d'une image d'installation en arrière-plan
/// (`IsoBoot.announcedKernel`) — le fichier ISO, lui, ne dit sa plateforme
/// nulle part.
struct BootAnnouncementView: View {
    let image: URL
    /// Le nom de la machine installée, ou celui du fichier.
    let title: String
    let kind: KernelImageKind
    let cloudImage: Bool
    /// La clé des réglages : mémoire, disque, réseau.
    let settingsKey: String
    /// Une machine installée : elle garde sa session, donc l'interpréteur.
    var installed = false
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var announcement: BootAnnouncement?
    /// **Le moteur** : le JIT de l'émetteur, ou l'interpréteur (`EmitterSetting`).
    @AppStorage("wisq.machine.emetteur") private var jitEnabled = true

    /// Cette image peut-elle s'ouvrir dans le JIT, dans cette construction ?
    private var jitPossible: Bool {
        #if WISQ_RUST_CORE
        EmitterSetting.opens(kind, enabled: true, installed: installed,
                             moduleEmbedded: EmitterMachine.isInThisBuild)
        #else
        false
        #endif
    }

    /// Ce qui va se passer, selon le moteur choisi.
    private func execution(_ announcement: BootAnnouncement) -> String {
        guard announcement.outcome.startsSomething, jitPossible, jitEnabled else {
            return announcement.executionText
        }
        return "Le JIT de wisq la démarre : l'émetteur traduit le code x86-64 en WebAssembly, "
            + "que WebKit compile en code natif \(announcement.host.architecture.name) du téléphone — "
            + "la seule voie de compilation qu'iOS laisse à une application. "
            + "La session ne se sauve pas encore : fermer la machine l'arrête."
    }

    var body: some View {
        List {
            if let announcement {
                Section {
                    HStack(spacing: Design.Space.l) {
                        PlatformBadge(name: announcement.guestName, symbol: "cpu")
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        PlatformBadge(name: announcement.host.architecture.name, symbol: "iphone")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Design.Space.s)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Image \(announcement.guestName), téléphone \(announcement.host.architecture.name)")
                }
                Section("L'image") {
                    LabeledContent("Fichier", value: image.lastPathComponent)
                    LabeledContent("Plateforme", value: announcement.guestName)
                    Text(announcement.evidenceText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Ce téléphone") {
                    LabeledContent("Processeur", value: announcement.host.architecture.name)
                    LabeledContent("Système", value: announcement.host.system)
                    if let model = announcement.host.model {
                        LabeledContent("Modèle", value: model)
                    }
                }
                Section(announcement.outcome.startsSomething ? "Ce qui va se passer" : "Pourquoi elle ne démarrera pas") {
                    Label {
                        // Le markdown des refus, sans formatage : voir `RefusalText`.
                        Text(RefusalText.rendered(execution(announcement)))
                    } icon: {
                        Image(systemName: announcement.outcome.startsSomething
                              ? "play.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(announcement.outcome.startsSomething ? Design.accent : Color.orange)
                    }
                    if announcement.outcome.startsSomething {
                        LabeledContent("Mémoire", value: KernelMemory.describe(
                            KernelMemory.size(forKernel: settingsKey)))
                        LabeledContent("Disque", value: LocalDisk.recordedName(forKernel: settingsKey) ?? "aucun")
                        LabeledContent("Réseau", value: MachineNetwork.isCut(forKernel: settingsKey)
                                       ? "coupé" : "branché")
                    }
                }
                if announcement.outcome.startsSomething, jitPossible {
                    Section {
                        Picker("Moteur", selection: $jitEnabled) {
                            Text("JIT (WebAssembly)").tag(true)
                            Text("Interpréteur Rust").tag(false)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Moteur")
                    } footer: {
                        Text(jitEnabled
                             ? "Si une image bute dans le JIT, l'interpréteur la démarre aussi."
                             : "Plus lent que le JIT, mais la session se sauve et se reprend.")
                    }
                }
            } else {
                Section {
                    HStack(spacing: Design.Space.m) {
                        ProgressView()
                        Text("Lecture de la plateforme de l'image…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(announcement.map(Self.offersStart) == false ? "Fermer" : "Annuler") { dismiss() }
            }
            // **Un refus ne propose pas de démarrer**, sauf quand il ne tient
            // qu'à un mot du nom : un indice peut se tromper, l'en-tête d'un
            // noyau non.
            if announcement.map(Self.offersStart) ?? true {
                ToolbarItem(placement: .confirmationAction) {
                    Button(announcement?.outcome.startsSomething == false ? "Essayer quand même" : "Démarrer") {
                        dismiss()
                        onStart()
                    }
                    .bold()
                    .disabled(announcement == nil)
                }
            }
        }
        .task { await read() }
    }

    private static func offersStart(_ announcement: BootAnnouncement) -> Bool {
        if announcement.outcome.startsSomething { return true }
        if case .nameHint = announcement.evidence { return true }
        return false
    }

    /// L'annonce, lue hors du fil principal : sortir le noyau d'une image
    /// de plusieurs gibioctets prend une seconde, et l'écran ne doit pas se
    /// figer pendant ce temps.
    private func read() async {
        let image = image
        let kind = kind
        let cloudImage = cloudImage
        let made = await Task.detached(priority: .userInitiated) { () -> BootAnnouncement in
            var inner: KernelImageKind?
            var innerPath: String?
            #if WISQ_RUST_CORE
            if case .discImage = kind {
                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent("wisq-annonce", isDirectory: true)
                if let found = IsoBoot.announcedKernel(
                    of: image, scratch: scratch, ceiling: UInt64(ReadyDesktop.digestScratch)) {
                    inner = found.kind
                    innerPath = found.path
                }
            }
            #endif
            return BootAnnouncement.make(
                fileName: image.lastPathComponent, kind: kind, inner: inner, innerPath: innerPath,
                cloudImage: cloudImage)
        }.value
        withAnimation(.snappy) { announcement = made }
    }
}

/// Une plateforme, en grand : une icône et un nom.
private struct PlatformBadge: View {
    let name: String
    let symbol: String

    var body: some View {
        VStack(spacing: Design.Space.xs) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(Design.accent)
                .frame(width: 56, height: 56)
                .background(Design.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Design.Radius.badge))
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: 96)
    }
}
#endif
