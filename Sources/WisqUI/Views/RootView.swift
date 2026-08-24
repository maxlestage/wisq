#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import WisqCore

/// App entry point view. iPhone-first: a single navigation stack, no split view.
public struct RootView: View {
    @State private var library = MachineLibraryModel.makeDefault()
    @State private var editing: MachineDraft?
    @State private var connecting: Machine?
    @State private var importingFromAgent = false
    @State private var showingLocalVMs = false
    @State private var pairingPrefill: AgentPairing.Payload?
    @State private var choosingConnectionFile = false
    @State private var importFailure: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            MachineListView(
                library: library,
                onConnect: { connecting = $0 },
                onEdit: { editing = MachineDraft(machine: $0) },
                onNew: { editing = MachineDraft() },
                onImportFromAgent: { importingFromAgent = true },
                onOpenConnectionFile: { choosingConnectionFile = true },
                onLocalVMs: { showingLocalVMs = true }
            )
        }
        // Every content type, rather than `.vv` and `.rdp` declared as types.
        // Those files arrive from Mail and AirDrop with whatever name the
        // sender gave them, and a picker that greys out `connexion.txt` refuses
        // a file wisq can read perfectly well. What the file *is* gets decided
        // by reading it, which is the only thing that can decide it.
        .fileImporter(
            isPresented: $choosingConnectionFile,
            allowedContentTypes: [.data]
        ) { result in
            openConnectionFile(result)
        }
        .alert(
            "Ce fichier n'a pas pu être lu",
            isPresented: Binding(get: { importFailure != nil },
                                 set: { if !$0 { importFailure = nil } })
        ) {
            Button("Fermer", role: .cancel) { importFailure = nil }
        } message: {
            Text(importFailure ?? "")
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

    /// Reads a `.vv` or `.rdp` the user picked, and opens it for editing rather
    /// than saving it outright.
    ///
    /// The editor is deliberate. A connection file is somebody else's
    /// description of a machine — its name is the host, its port came from a
    /// server, and its password is often a ticket good for one connection. The
    /// user should see all of that before it lands in their library, and be
    /// able to name the machine something they will recognise.
    private func openConnectionFile(_ result: Result<URL, Error>) {
        switch result {
        case let .failure(error):
            importFailure = ConnectionImport.message(for: error)
        case let .success(url):
            // The picker hands back a URL into somebody else's container, and
            // reading it without claiming the scope fails with a permission
            // error that reads like the file is missing.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let bytes = try Data(contentsOf: url)
                editing = MachineDraft(
                    imported: try ConnectionImport.machine(fromContentsOf: bytes)
                )
            } catch {
                importFailure = ConnectionImport.message(for: error)
            }
        }
    }
}
#endif
