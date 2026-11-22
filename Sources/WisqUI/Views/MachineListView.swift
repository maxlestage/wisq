#if os(iOS)
import SwiftUI
import WisqCore
import WisqRemote
import WisqVM

/// The library. Big tap targets, connect in one tap, everything else behind a swipe.
///
/// **Les connexions à distance**, ouvertes depuis le menu + de l'écran
/// d'accueil : celui-ci montre les machines du téléphone (voir
/// `LocalVMListView`).
public struct MachineListView: View {
    let library: MachineLibraryModel
    let onConnect: (Machine) -> Void
    let onEdit: (Machine) -> Void
    let onNew: () -> Void
    let onImportFromAgent: () -> Void
    let onOpenConnectionFile: () -> Void
    /// Ouvre la mesure qui décide du bureau local. Elle n'a pas sa place dans
    /// un réglage : c'est une question ouverte, pas une préférence.
    let onBench: () -> Void

    @State private var search = ""
    @State private var power: PowerFlow?
    @State private var confirmingDiscard = false

    public var body: some View {
        List {
            if let error = library.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                    if library.unreadable > 0 {
                        // The choice is offered, never made: the app cannot
                        // tell a newer build's entry from a damaged one, and
                        // the confirmation says exactly that.
                        Button("Écarter ce qui ne peut pas être lu…", role: .destructive) {
                            confirmingDiscard = true
                        }
                        .font(.footnote)
                    }
                }
            }

            if let power, power.phase == .waiting || power.phase == .forcing {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(power.phase == .forcing
                            ? "Arrêt forcé de « \(power.machine.name) »…"
                            : "Arrêt de « \(power.machine.name) » demandé — l'invité peut y mettre une minute…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(filtered) { machine in
                Button {
                    onConnect(machine)
                } label: {
                    MachineRow(machine: machine)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        library.delete(machine)
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                    Button {
                        onEdit(machine)
                    } label: {
                        Label("Modifier", systemImage: "slider.horizontal.3")
                    }
                    .tint(.indigo)
                    if machine.agent != nil {
                        Button {
                            power = PowerFlow(machine: machine, phase: .confirming)
                        } label: {
                            Label("Éteindre", systemImage: "power")
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        .confirmationDialog(
            library.unreadable == 1
                ? "Écarter l'entrée illisible ?" : "Écarter les \(library.unreadable) entrées illisibles ?",
            isPresented: $confirmingDiscard, titleVisibility: .visible
        ) {
            Button("Écarter définitivement", role: .destructive) { library.discardUnreadable() }
            Button("Garder", role: .cancel) {}
        } message: {
            Text(MachineLibraryModel.discardExplanation(count: library.unreadable))
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Rechercher une connexion")
        .navigationTitle("Connexions à distance")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: onNew) {
                        Label("Nouvelle machine", systemImage: "plus")
                    }
                    Button(action: onImportFromAgent) {
                        Label("Importer depuis un agent", systemImage: "server.rack")
                    }
                    Button(action: onOpenConnectionFile) {
                        Label("Ouvrir un fichier .vv ou .rdp", systemImage: "doc.badge.plus")
                    }
                    Button(action: onBench) {
                        Label("Le bureau est-il possible ?",
                              systemImage: "gauge.with.dots.needle.67percent")
                    }
                } label: {
                    Label("Ajouter", systemImage: "plus")
                }
            }
        }
        .confirmationDialog(
            "Éteindre « \(power?.machine.name ?? "") » ?",
            isPresented: powerPhaseShown(.confirming),
            titleVisibility: .visible
        ) {
            if let machine = power?.machine {
                Button("Demander l'arrêt", role: .destructive) { shutDown(machine, force: false) }
            }
            Button("Annuler", role: .cancel) { power = nil }
        } message: {
            Text("L'invité reçoit une demande d'arrêt et s'éteint proprement. Cela peut prendre une minute.")
        }
        .alert(
            "L'invité n'a pas répondu",
            isPresented: powerPhaseShown(.unanswered)
        ) {
            if let machine = power?.machine {
                Button("Couper l'alimentation", role: .destructive) { shutDown(machine, force: true) }
            }
            Button("Laisser tranquille", role: .cancel) { power = nil }
        } message: {
            Text("La demande d'arrêt est restée sans réponse — certains systèmes l'ignorent. Couper l'alimentation arrête la machine immédiatement ; ce qui n'était pas enregistré sera perdu.")
        }
        .alert(
            "L'arrêt a échoué",
            isPresented: Binding(
                get: { powerFailure != nil },
                set: { if !$0 { power = nil } }
            )
        ) {
            Button("Fermer", role: .cancel) { power = nil }
        } message: {
            Text(powerFailure ?? "")
        }
        .overlay {
            if library.machines.isEmpty {
                ContentUnavailableView {
                    Label("Aucune connexion", systemImage: "server.rack")
                } description: {
                    Text("Ajoutez un serveur VNC, SPICE ou RDP — une VM QEMU, un Raspberry Pi, un poste de travail — pour l'atteindre depuis votre iPhone. Sur le téléphone même, wisq ne lance ni Windows ni macOS, par choix.")
                } actions: {
                    Button("Ajouter une machine", action: onNew)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var filtered: [Machine] {
        guard !search.isEmpty else { return library.machines }
        return library.machines.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.host.localizedCaseInsensitiveContains(search)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    // MARK: - Power

    /// One shutdown at a time, tracked through its phases. The honest part is
    /// `.unanswered`: a guest can ignore the ACPI request forever, so the flow
    /// surfaces the non-answer and offers the cord instead of spinning — the
    /// conduct `VMPower` documents and the tests hold against the real daemon.
    private struct PowerFlow {
        enum Phase: Equatable {
            case confirming
            case waiting
            case unanswered
            case forcing
            case failed(String)
        }
        var machine: Machine
        var phase: Phase
    }

    private var powerFailure: String? {
        if case .failed(let message)? = power?.phase { return message }
        return nil
    }

    /// Presentation binding for one phase. Dismissing a dialog calls
    /// `set(false)` before the chosen button acts, so it only clears the flow
    /// when that phase is still current — a button that moved the flow on
    /// must not have its new phase wiped by the dismissal it caused.
    private func powerPhaseShown(_ phase: PowerFlow.Phase) -> Binding<Bool> {
        Binding(
            get: { power?.phase == phase },
            set: { shown in
                if !shown, power?.phase == phase { power = nil }
            }
        )
    }

    private func shutDown(_ machine: Machine, force: Bool) {
        power = PowerFlow(machine: machine, phase: force ? .forcing : .waiting)
        let credentials = library.credentialStore
        Task {
            do {
                switch try await VMPower.shutDown(machine, credentials: credentials, force: force) {
                case .stopped:
                    power = nil
                case .stillRunning:
                    power?.phase = force
                        ? .failed("l'agent répond, mais la machine tourne toujours après l'arrêt forcé")
                        : .unanswered
                }
            } catch {
                power?.phase = .failed(error.localizedDescription)
            }
        }
    }
}

struct MachineRow: View {
    let machine: Machine

    var body: some View {
        HStack(spacing: Design.Space.m) {
            RemoteBadge(system: machine.guestOS)

            VStack(alignment: .leading, spacing: 3) {
                Text(machine.name)
                    .font(.body.weight(.semibold))
                Text(verbatim: machine.displayAddress)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Design.Space.xs) {
                    Text(machine.proto.displayName)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Design.chipFill))
                    if machine.security != .none {
                        // The shield only when the connection really pins:
                        // `.tlsPinned` without a fingerprint is plain TLS.
                        Image(systemName: machine.pinsCertificate ? "lock.shield.fill" : "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .accessibilityLabel(machine.pinsCertificate ? "chiffrée, certificat épinglé" : "chiffrée")
                    }
                }
            }

            Spacer(minLength: Design.Space.s)

            if let last = machine.lastConnectedAt {
                Text(last, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Design.Space.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

}

/// **Le badge d'une machine distante** : la teinte et le symbole de son
/// système. Décoratif pour VoiceOver, comme celui des machines locales.
struct RemoteBadge: View {
    let system: GuestOS
    var size: CGFloat = 42

    var body: some View {
        let tint = Self.tint(system)
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .topLeading,
                                 endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: system.symbolName)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    /// La teinte du badge, selon le système de la machine distante.
    static func tint(_ system: GuestOS) -> Color {
        switch system {
        case .linux: return Design.tint(.linux)
        case .windows: return Color(red: 0.0, green: 0.42, blue: 0.75)
        case .macos: return Color(white: 0.36)
        case .bsd: return Color(red: 0.62, green: 0.12, blue: 0.12)
        case .unknown, .other: return Color(red: 0.30, green: 0.36, blue: 0.45)
        }
    }
}
#endif
