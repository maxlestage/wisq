#if os(iOS)
import SwiftUI
import WisqCore

/// The library. Big tap targets, connect in one tap, everything else behind a swipe.
public struct MachineListView: View {
    let library: MachineLibraryModel
    let onConnect: (Machine) -> Void
    let onEdit: (Machine) -> Void
    let onNew: () -> Void
    let onImportFromAgent: () -> Void
    let onLocalVMs: () -> Void

    @State private var search = ""

    public var body: some View {
        List {
            if let error = library.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
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
                }
            }

            // The app says where it comes from. Apache-2.0 is a promise to the
            // person holding the phone, and it is empty if they would have to
            // find a website to learn the source exists.
            Section {
                Link(destination: ProjectLinks.repository) {
                    Label("Code source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: ProjectLinks.issues) {
                    Label("Signaler un problème", systemImage: "ladybug")
                }
                Link(destination: ProjectLinks.license) {
                    Label("Licence Apache-2.0", systemImage: "doc.text")
                }
            } header: {
                Text("À propos")
            } footer: {
                Text("wisq \(ProjectLinks.version) — libre et open source. Sémantique RISC-V portée de mini-rv32ima (Charles Lohr, MIT).")
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
                    Button(action: onLocalVMs) {
                        Label("Linux local (sur ce téléphone)", systemImage: "terminal")
                    }
                } label: {
                    Label("Ajouter", systemImage: "plus")
                }
            }
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
