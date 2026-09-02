#if os(iOS)
import SwiftUI
import WisqCore
import WisqRemote

/// The library. Big tap targets, connect in one tap, everything else behind a swipe.
public struct MachineListView: View {
    let library: MachineLibraryModel
    let onConnect: (Machine) -> Void
    let onEdit: (Machine) -> Void
    let onNew: () -> Void
    let onImportFromAgent: () -> Void
    let onOpenConnectionFile: () -> Void
    let onLocalVMs: () -> Void

    @State private var search = ""
    @State private var power: PowerFlow?

    public var body: some View {
        List {
            if let error = library.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
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
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Rechercher une machine")
        .navigationTitle("Machines")
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
                    Button(action: onLocalVMs) {
                        Label("Linux local (sur ce téléphone)", systemImage: "terminal")
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
                    Label("Aucune machine", systemImage: "server.rack")
                } description: {
                    Text("Ajoutez un serveur VNC — une VM QEMU, un Raspberry Pi, un poste de travail — pour l'atteindre depuis votre iPhone.")
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
        HStack(spacing: 14) {
            Image(systemName: machine.guestOS.symbolName)
                .font(.title2)
                .frame(width: 34)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(machine.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text("\(machine.host):\(machine.port)")
                    Text("·")
                    Text(machine.proto.displayName)
                    if machine.security != .none {
                        Image(systemName: "lock.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let last = machine.lastConnectedAt {
                Text(last, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
#endif
