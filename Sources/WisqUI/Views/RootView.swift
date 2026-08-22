#if os(iOS)
import SwiftUI
import WisqCore

/// App entry point view. iPhone-first: a single navigation stack, no split view.
public struct RootView: View {
    @State private var library = MachineLibraryModel.makeDefault()
    @State private var editing: MachineDraft?
    @State private var connecting: Machine?

    public init() {}

    public var body: some View {
        NavigationStack {
            MachineListView(
                library: library,
                onConnect: { connecting = $0 },
                onEdit: { editing = MachineDraft(machine: $0) },
                onNew: { editing = MachineDraft() }
            )
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
