#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import WisqVM

/// Local Linux: pick a kernel image, boot it on the phone, get a shell.
struct LocalVMListView: View {
    let onClose: () -> Void

    @State private var kernels = KernelLibrary.list()
    @State private var showImporter = false
    @State private var importError: String?
    @State private var booting: BootTarget?

    var body: some View {
        List {
            Section {
                ForEach(kernels, id: \.self) { kernel in
                    Button {
                        booting = BootTarget(url: kernel)
                    } label: {
                        Label(kernel.lastPathComponent, systemImage: "terminal")
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            KernelLibrary.delete(kernel)
                            kernels = KernelLibrary.list()
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("Un noyau Linux rv32ima « nommu » démarre en une à deux secondes, entièrement sur l'iPhone — sans réseau, sans serveur. Des images prêtes à l'emploi existent dans le projet mini-rv32ima.")
            }

            if let importError {
                Section {
                    Label(importError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Linux local")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if kernels.isEmpty {
                ContentUnavailableView {
                    Label("Aucun noyau", systemImage: "terminal")
                } description: {
                    Text("Importez une image de noyau Linux rv32ima pour la faire tourner directement sur ce téléphone.")
                } actions: {
                    Button("Importer une image") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fermer", action: onClose)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    showImporter = true
                } label: {
                    Label("Importer", systemImage: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            do {
                if let source = try result.get().first {
                    _ = try KernelLibrary.importKernel(from: source)
                    kernels = KernelLibrary.list()
                    importError = nil
                }
            } catch {
                importError = error.localizedDescription
            }
        }
        .fullScreenCover(item: $booting) { target in
            NavigationStack {
                LocalVMTerminalView(kernelURL: target.url)
            }
        }
    }
}

/// Identifiable wrapper so a kernel can drive a cover presentation.
private struct BootTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// The console of a running local VM: scrolling output, a command line, and the
/// same key bar philosophy as the remote sessions — v1 is line-oriented, a full
/// cell-grid terminal can come later.
struct LocalVMTerminalView: View {
    let kernelURL: URL

    @State private var model = LocalVMModel()
    @State private var commandLine = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.consoleText.isEmpty ? "Démarrage…" : model.consoleText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("console-end")
                        .textSelection(.enabled)
                }
                .background(Color.black)
                .foregroundStyle(Color(red: 0.7, green: 0.95, blue: 0.7))
                .onChange(of: model.consoleText) {
                    proxy.scrollTo("console-end", anchor: .bottom)
                }
            }

            HStack(spacing: 8) {
                TextField("commande", text: $commandLine)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    .onSubmit(submit)
                Button("Entrée", action: submit)
                    .buttonStyle(.borderedProminent)
                Button {
                    model.send("\u{3}")   // Ctrl-C
                } label: {
                    Text("^C").font(.system(.body, design: .monospaced))
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(.ultraThinMaterial)
        }
        .navigationTitle(kernelURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Arrêter") {
                    model.stop()
                    dismiss()
                }
            }
        }
        .onAppear {
            model.boot(kernelURL: kernelURL)
            inputFocused = true
            UIApplication.shared.isIdleTimerDisabled = true
        }
        // Leaving the screen suspends rather than stops: the machine is put
        // down where it stands and picked up on the next visit. Only the
        // "Arrêter" button ends it, which is what that word has to mean.
        .onDisappear {
            model.suspend()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // And the same when iOS takes the app away, which it can do without
        // the view ever disappearing. Saving here is the whole reason the
        // machine survives being backgrounded and killed.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.suspend() }
        }
    }

    private func submit() {
        model.sendLine(commandLine)
        commandLine = ""
        inputFocused = true
    }
}
#endif
