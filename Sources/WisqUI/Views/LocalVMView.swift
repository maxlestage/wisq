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
    /// Ce que le dernier changement de mémoire a coûté, à dire une fois.
    @State private var memoryNote: String?
    /// Ce que Linux local occupe. Relu après chaque geste qui peut le changer.
    @State private var storage = LocalStorage.Report.empty

    var body: some View {
        List {
            Section {
                ForEach(kernels, id: \.self) { kernel in
                    HStack {
                        Button {
                            booting = BootTarget(url: kernel)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(kernel.lastPathComponent, systemImage: "terminal")
                                if let line = Self.storageLine(
                                    storage.entry(forKernel: kernel.lastPathComponent)) {
                                    Text(line)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 12)
                        KernelMemoryMenu(kernel: kernel) { forgotten in
                            memoryNote = Self.note(forgotten: forgotten)
                            storage = KernelLibrary.storageReport()
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            KernelLibrary.delete(kernel)
                            kernels = KernelLibrary.list()
                            memoryNote = nil
                            storage = KernelLibrary.storageReport()
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Un noyau Linux rv32ima « nommu » démarre en une à deux secondes, entièrement sur l'iPhone — sans réseau, sans serveur. Des images prêtes à l'emploi existent dans le projet mini-rv32ima.")
                    Text("Le chiffre à droite de chaque noyau est la mémoire de sa machine. La machine de référence en a \(LinuxMachine.defaultRAMSize >> 20) Mo ; ce téléphone en autorise jusqu'à \(KernelMemory.ceiling >> 20) Mo. Changer ce réglage repart du noyau : un instantané pris à une autre taille ne peut pas être repris.")
                }
            }

            if let memoryNote {
                Section {
                    Label(memoryNote, systemImage: "memorychip")
                        .foregroundStyle(.secondary)
                }
            }

            if storage.total > 0 {
                Section {
                    LabeledContent(
                        "Noyaux et machines sauvegardées",
                        value: LocalStorage.describe(bytes: storage.total))
                    if storage.savedMachineBytes > 0 {
                        LabeledContent(
                            "dont machines sauvegardées",
                            value: LocalStorage.describe(bytes: storage.savedMachineBytes))
                    }
                    if storage.orphanedCount > 0 {
                        Button {
                            let freed = KernelLibrary.freeOrphanedMachines()
                            storage = KernelLibrary.storageReport()
                            memoryNote = "\(LocalStorage.describe(bytes: freed)) repris."
                        } label: {
                            Label(
                                "Reprendre \(LocalStorage.describe(bytes: storage.orphanedBytes)) laissés par des noyaux supprimés",
                                systemImage: "arrow.counterclockwise")
                        }
                    }
                } header: {
                    Text("Stockage")
                } footer: {
                    Text("Une machine sauvegardée ne peut pas dépasser la mémoire dont elle a été prise, et les octets à zéro sont repliés — c'est pourquoi elle pèse en général bien moins que la machine. Il n'y a pas de disque à régler ici : ce noyau Linux « nommu » n'a pas de pilote de bloc, et c'est l'instantané de la machine entière qui fait le travail qu'un disque aurait fait.")
                }
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
                    storage = KernelLibrary.storageReport()
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
        // Relu à l'ouverture, et au retour d'une session : c'est en quittant
        // une machine qu'elle est sauvegardée, donc c'est là que le chiffre
        // change le plus.
        .onAppear { storage = KernelLibrary.storageReport() }
        .onChange(of: booting == nil) { storage = KernelLibrary.storageReport() }
    }
}

/// Combien de mémoire ce noyau reçoit.
///
/// Le geste est à côté du nom, pas dans un écran de réglages, parce que c'est
/// un réglage **de cette machine-là** : deux noyaux dans la même liste n'ont
/// aucune raison de tourner à la même taille.
///
/// La vue ne décide rien. Ce qui est offert vient de `KernelMemory.offered`,
/// borné par ce que l'appareil dit de lui-même, et l'oubli des machines
/// sauvegardées vient de `SuspendedMachine.clearAll` — les deux sont tenus par
/// des tests qui tournent sur Linux, ce que ce fichier ne peut pas être.
private struct KernelMemoryMenu: View {
    let kernel: URL
    /// Combien de machines sauvegardées le changement a coûté, pour le dire.
    let onChange: (Int) -> Void

    @State private var size: UInt32

    init(kernel: URL, onChange: @escaping (Int) -> Void) {
        self.kernel = kernel
        self.onChange = onChange
        _size = State(initialValue: KernelMemory.size(forKernel: kernel.lastPathComponent))
    }

    var body: some View {
        Menu {
            Picker("Mémoire", selection: $size) {
                ForEach(KernelMemory.offered(ceiling: KernelMemory.ceiling), id: \.self) { choice in
                    Text(Self.label(choice)).tag(choice)
                }
            }
        } label: {
            Text(Self.label(size))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .onChange(of: size) { previous, chosen in
            guard previous != chosen else { return }
            KernelMemory.setSize(chosen, forKernel: kernel.lastPathComponent)
            onChange(SuspendedMachine.clearAll(named: kernel.lastPathComponent))
        }
    }

    static func label(_ bytes: UInt32) -> String { "\(bytes >> 20) Mo" }
}

extension LocalVMListView {
    /// Ce qu'un changement de mémoire a coûté, dit une fois et au passé.
    ///
    /// Rien à dire quand rien n'a été perdu : une machine qui n'existait pas
    /// n'a pas été oubliée, et annoncer une perte qui n'a pas eu lieu apprend
    /// à ignorer le message.
    /// Ce qu'un noyau occupe, sous son nom, ou rien quand il n'y a rien à dire.
    ///
    /// Le noyau seul ne mérite pas une ligne : sa taille est celle du fichier
    /// que la personne vient d'importer, elle ne la surprendra pas. Ce qui
    /// mérite d'être dit est la machine sauvegardée à côté, qui apparaît sans
    /// qu'on l'ait demandée et peut peser bien plus que le noyau.
    static func storageLine(_ entry: LocalStorage.Entry?) -> String? {
        guard let entry, entry.savedMachineBytes > 0 else { return nil }
        let machines = entry.savedMachineCount == 1
            ? "machine sauvegardée"
            : "\(entry.savedMachineCount) machines sauvegardées"
        return """
            \(LocalStorage.describe(bytes: entry.kernelBytes)) \
            + \(LocalStorage.describe(bytes: entry.savedMachineBytes)) de \(machines)
            """
    }

    static func note(forgotten: Int) -> String? {
        switch forgotten {
        case 0: return nil
        case 1:
            return """
                Mémoire changée : la machine sauvegardée pour ce noyau a été \
                oubliée. Le prochain démarrage repart du noyau.
                """
        default:
            return """
                Mémoire changée : \(forgotten) machines sauvegardées pour ce \
                noyau ont été oubliées. Le prochain démarrage repart du noyau.
                """
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
            // Offered only when there is something to forget. "Arrêter" also
            // clears the saved machine, but only by ending the session; this is
            // for the user whose guest is wedged and who wants to walk away now
            // and come back to a clean boot.
            if model.hasSavedMachine {
                ToolbarItem(placement: .primaryAction) {
                    Button("Oublier", systemImage: "trash") {
                        model.forgetSavedMachine()
                    }
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
        // machine survives being backgrounded and killed — and picking it back
        // up on the way in is what stops the user from returning to a dead
        // terminal they can only escape by leaving the screen.
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: phase, kernelURL: kernelURL)
        }
    }

    private func submit() {
        model.sendLine(commandLine)
        commandLine = ""
        inputFocused = true
    }
}
#endif
