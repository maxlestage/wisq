#if os(iOS)
import SwiftUI
import WisqCore

/// App entry point view. iPhone-first: a single navigation stack, no split view.
public struct RootView: View {
    @State private var library = MachineLibraryModel.makeDefault()
    @State private var editing: MachineDraft?
    @State private var connecting: Machine?
    @State private var importingFromAgent = false
    @State private var showingLocalVMs = false
    @State private var pairingPrefill: AgentPairing.Payload?

    public init() {}

    public var body: some View {
        NavigationStack {
            MachineListView(
                library: library,
                onConnect: { connecting = $0 },
                onEdit: { editing = MachineDraft(machine: $0) },
                onNew: { editing = MachineDraft() },
                onImportFromAgent: { importingFromAgent = true },
                onLocalVMs: { showingLocalVMs = true }
            )
        }
        .sheet(isPresented: $showingLocalVMs) {
            NavigationStack {
                LocalVMListView { showingLocalVMs = false }
            }
        }
        .sheet(isPresented: $importingFromAgent) {
            NavigationStack {
                AgentImportView(library: library, prefill: pairingPrefill) {
                    importingFromAgent = false
                    pairingPrefill = nil
                }
            }
        }
        .onOpenURL { url in
            // A wisq:// pairing link — from the daemon's QR code or pasted —
            // lands straight in the import screen, credentials filled in.
            guard let payload = try? AgentPairing.parse(url) else { return }
            pairingPrefill = payload
            editing = nil
            connecting = nil
            importingFromAgent = true
        }
        .sheet(item: $editing) { draft in
            NavigationStack {
                MachineEditorView(draft: draft, library: library) { editing = nil }
            }
        }
        .fullScreenCover(item: $connecting) { machine in
            SessionView(machine: machine, library: library)
        }
    }
}
#endif
