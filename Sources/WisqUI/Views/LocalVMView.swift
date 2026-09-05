#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import WisqVM

/// Local Linux: pick a kernel image, boot it on the phone, get a shell.
struct LocalVMListView: View {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        // Les genres sont lus **avant la première image**, et pas dans
        // `onAppear` : celui-ci ne se déclenche qu'après un premier rendu, et
        // ce rendu-là afficherait la bibliothèque entière sous l'icône du
        // « type inconnu » le temps d'une trame.
        let files = KernelLibrary.list()
        _kernels = State(initialValue: files)
        _kinds = State(initialValue: Self.read(files))
        _disks = State(initialValue: LocalDisk.allRecorded())
    }

    @State private var kernels: [URL]
    /// Ce que chaque fichier est, lu **une fois** par changement de
    /// bibliothèque.
    ///
    /// Pas dans la ligne : `KernelImageKind.identify` ouvre le fichier et en
    /// lit quarante kibioctets, et une liste SwiftUI redessine ses lignes bien
    /// plus souvent qu'elle ne change. Le faire dans le corps de la vue
    /// reviendrait à lire la bibliothèque entière à chaque défilement, sur le
    /// fil principal.
    @State private var kinds: [URL: KernelImageKind]
    /// Le disque de chaque noyau, sous le nom du fichier du noyau. Relu avec
    /// la bibliothèque, pour la raison que `KernelDiskMenu` explique.
    @State private var disks: [String: String] = [:]
    @State private var showImporter = false
    @State private var importError: String?
    @State private var booting: BootTarget?
    /// Ce que le dernier réglage a coûté, à dire une fois — et sous quelle
    /// icône, parce que « mémoire changée » sous une puce mémoire et « disque
    /// changé » sous la même puce enverraient chercher au mauvais endroit.
    @State private var note: Note?
    /// Ce que Linux local occupe. Relu après chaque geste qui peut le changer.
    @State private var storage = LocalStorage.Report.empty

    var body: some View {
        List {
            Section {
                ForEach(kernels, id: \.self) { kernel in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button {
                                booting = BootTarget(url: kernel)
                            } label: {
                                LibraryRow(
                                    kernel: kernel,
                                    role: LibraryEntry.role(of: kinds[kernel] ?? .unknown),
                                    storageLine: Self.storageLine(
                                        storage.entry(forKernel: kernel.lastPathComponent)))
                            }
                            .buttonStyle(.plain)
                            Spacer(minLength: 12)
                            KernelMemoryMenu(kernel: kernel) { forgotten in
                                note = Self.note(forgotten: forgotten)
                                    .map { Note(text: $0, symbol: "memorychip") }
                                storage = KernelLibrary.storageReport()
                            }
                        }
                        // Le disque se propose à tout ce qui démarre ici.
                        // Il n'était offert qu'aux noyaux de PC, parce que la
                        // machine RISC-V refusait le sien ; elle ne le refuse
                        // plus. Ce qu'elle ne peut toujours pas, c'est mettre
                        // le pilote bloc dans le noyau de quelqu'un — et ça,
                        // seul un démarrage peut le dire, pas cette liste.
                        if kinds[kernel]?.couldBootHere == true {
                            KernelDiskMenu(
                                kernel: kernel, library: kernels,
                                chosen: disks[kernel.lastPathComponent]
                            ) { chosen in
                                attach(chosen, to: kernel)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            KernelLibrary.delete(kernel)
                            reloadLibrary()
                            note = nil
                            storage = KernelLibrary.storageReport()
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Un noyau Linux rv32ima « nommu » démarre en une à deux secondes, entièrement sur l'iPhone — sans réseau, sans serveur. Des images prêtes à l'emploi existent dans le projet mini-rv32ima.")
                    Text("Le curseur à droite de chaque noyau règle la mémoire de sa machine. La machine de référence en a \(KernelMemory.describe(LinuxMachine.defaultRAMSize)) ; ce téléphone en autorise jusqu'à \(KernelMemory.describe(KernelMemory.ceiling)), et l'émulateur ne peut pas dépasser \(KernelMemory.describe(LinuxMachine.maximumRAMSize)) — la mémoire de l'invité commence à 0x80000000 et son processeur adresse en 32 bits. Changer ce réglage repart du noyau : un instantané pris à une autre taille ne peut pas être repris.")
                    Text("Chaque noyau peut recevoir un **disque** : une image de système de fichiers importée ici, que l'invité voit sur `/dev/vda`. Les deux machines en ont un — la RISC-V le refusait, faute de pouvoir déclarer le périphérique ; elle sait maintenant. wisq ne monte rien tout seul, et il ne peut pas ajouter le pilote bloc à votre noyau : s'il n'en a pas, le disque restera là sans que personne ne vienne, et wisq vous le dira à la fin. Le disque est lu sur place, quelle que soit sa taille ; ce que l'invité y écrit va dans une couche à part, gardée d'une session à l'autre, et le fichier importé ne change jamais.")
                }
            }

            if let note {
                Section {
                    Label(note.text, systemImage: note.symbol)
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
                            note = Note(
                                text: "\(LocalStorage.describe(bytes: freed)) repris.",
                                symbol: "arrow.counterclockwise")
                        } label: {
                            Label(
                                "Reprendre \(LocalStorage.describe(bytes: storage.orphanedBytes)) laissés par des noyaux supprimés",
                                systemImage: "arrow.counterclockwise")
                        }
                    }
                } header: {
                    Text("Stockage")
                } footer: {
                    Text("Une machine sauvegardée pèse ce que l'invité a touché, pas ce qu'on lui a donné : mesuré sur un vrai noyau arrivé à l'invite de connexion, environ 17 Mio — et quadrupler la mémoire de la machine n'y ajoute que deux mégaoctets. Une machine à qui on a donné un disque pèse ce disque **en plus**, quelle que soit son architecture, parce que l'instantané emporte les octets que l'invité y a écrits — c'est ce qui les fait survivre à une suspension.")
                }
            }

            if let importError {
                Section {
                    RefusalLabel(text: importError)
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
                    reloadLibrary()
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
        .onAppear {
            reloadLibrary()
            storage = KernelLibrary.storageReport()
        }
        .onChange(of: booting == nil) { storage = KernelLibrary.storageReport() }
    }

    /// Relit la bibliothèque **et** ce que chaque fichier est. Les deux vont
    /// ensemble : une liste sans ses genres dessinerait des icônes d'un
    /// fichier qui n'est plus là.
    private func reloadLibrary() {
        kernels = KernelLibrary.list()
        kinds = Self.read(kernels)
        disks = LocalDisk.allRecorded()
    }

    /// Retient le disque choisi, et oublie ce que ce choix invalide.
    ///
    /// Les machines sauvegardées de ce noyau partent, comme au changement de
    /// mémoire et pour une raison plus dure : leur instantané porte les octets
    /// du disque tels que l'invité les a laissés. Les reprendre après un
    /// changement rendrait le réglage muet.
    private func attach(_ disk: String?, to kernel: URL) {
        let name = kernel.lastPathComponent
        guard disk != disks[name] else { return }
        LocalDisk.attach(disk, forKernel: name)
        disks = LocalDisk.allRecorded()
        note = Self.diskNote(forgotten: SuspendedMachine.clearAll(named: name))
            .map { Note(text: $0, symbol: "externaldrive") }
        storage = KernelLibrary.storageReport()
    }

    /// Ce que chacun de ces fichiers est. Les doublons de clé sont impossibles
    /// — un répertoire ne contient pas deux fois le même nom — mais
    /// `uniqueKeysWithValues` s'arrêterait net s'ils l'étaient, et une
    /// bibliothèque n'est pas un endroit où planter.
    private static func read(_ files: [URL]) -> [URL: KernelImageKind] {
        Dictionary(files.map { ($0, KernelImageKind.identify(fileAt: $0)) },
                   uniquingKeysWith: { first, _ in first })
    }
}

/// Une ligne de la bibliothèque : son nom, ce qu'elle **est**, et ce qu'elle
/// occupe.
///
/// Les trois sortes de fichiers vivaient dans la même liste sous la même icône
/// de terminal, et rien ne disait laquelle démarre. Le rôle vient de
/// `LibraryEntry`, qui se tient par des tests ; cette vue-ci le dessine.
///
/// **Aucune ligne n'est éteinte**, y compris celles qui ne démarreront pas.
/// C'est la même permission que `KernelImageKind.unknown` : le refus d'un
/// initramfs touché par erreur explique quoi faire, et une ligne grisée
/// n'expliquerait rien du tout.
private struct LibraryRow: View {
    let kernel: URL
    let role: LibraryEntry.Role
    let storageLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(kernel.lastPathComponent, systemImage: LibraryEntry.symbol(role))
            Text(LibraryEntry.word(role))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let storageLine {
                Text(storageLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Quel disque ce noyau reçoit.
///
/// Un menu et non un curseur, parce que la question n'est pas « combien » mais
/// « lequel » : une liste de fichiers, plus « aucun ». Ce qui est offert vient
/// de `LocalDisk.candidates`, qui écarte les noyaux et les enveloppes
/// compressées — on ne branche pas un initramfs sur `/dev/vda`.
///
/// **Le choix n'est pas un `@State` d'ici**, à la différence du curseur de
/// mémoire, et c'est une correction : l'identité d'une ligne est l'URL de son
/// noyau, donc supprimer le fichier du disque ne reconstruit pas ce menu. Un
/// état local aurait continué d'afficher, en rouge, le nom d'un fichier que
/// l'application venait elle-même d'oublier.
private struct KernelDiskMenu: View {
    let kernel: URL
    let library: [URL]
    let chosen: String?
    let choose: (String?) -> Void

    var body: some View {
        let candidates = LocalDisk.candidates(
            among: library, kernel: kernel.lastPathComponent)
        Menu {
            Button("Aucun") { choose(nil) }
            ForEach(candidates, id: \.self) { disk in
                Button(disk.lastPathComponent) { choose(disk.lastPathComponent) }
            }
        } label: {
            Label(chosen.map { "Disque : \($0)" } ?? "Disque : aucun",
                  systemImage: "externaldrive")
                .font(.footnote)
        }
        // Un fichier choisi puis disparu autrement que par la corbeille de
        // cette liste — remplacé, sorti du dossier — laisse un nom qui ne
        // désigne plus rien. Le dire est plus utile que de l'effacer en
        // silence : le démarrage, lui, se fera sans disque.
        .foregroundStyle(missing(candidates) ? Color.red : Color.secondary)
        .accessibilityLabel("Disque de \(kernel.lastPathComponent)")
        .accessibilityValue(chosen ?? "aucun")
    }

    private func missing(_ candidates: [URL]) -> Bool {
        guard let chosen else { return false }
        return !candidates.contains { $0.lastPathComponent == chosen }
    }
}

/// Combien de mémoire ce noyau reçoit.
///
/// Le geste est à côté du nom, pas dans un écran de réglages, parce que c'est
/// un réglage **de cette machine-là** : deux noyaux dans la même liste n'ont
/// aucune raison de tourner à la même taille.
///
/// Un curseur, pas un menu : la question « combien de mémoire » se répond en
/// glissant sur une échelle, pas en dépliant une liste. Il glisse sur les
/// *indices* des paliers offerts, donc il saute de puissance de deux en
/// puissance de deux au lieu de proposer des tailles qu'aucune machine n'a.
///
/// La vue ne décide rien. Ce qui est offert vient de `KernelMemory.offered`,
/// borné par ce que l'appareil dit de lui-même, le nom des tailles vient de
/// `KernelMemory.describe`, et l'oubli des machines sauvegardées vient de
/// `SuspendedMachine.clearAll` — tous tenus par des tests qui tournent sur
/// Linux, ce que ce fichier ne peut pas être.
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

    /// Les paliers que cet appareil autorise. Calculés une fois : le curseur
    /// glisse sur leurs *indices*, pas sur des octets, ce qui lui fait sauter
    /// de puissance de deux en puissance de deux plutôt que de proposer des
    /// tailles intermédiaires qu'aucune machine n'a jamais.
    private var steps: [UInt32] { KernelMemory.offered(ceiling: KernelMemory.ceiling) }

    var body: some View {
        let steps = self.steps
        let index = Binding<Double>(
            get: { Double(steps.firstIndex(of: size) ?? steps.count - 1) },
            set: { newValue in
                let clamped = min(max(Int(newValue.rounded()), 0), steps.count - 1)
                size = steps[clamped]
            })

        VStack(alignment: .trailing, spacing: 2) {
            Text(KernelMemory.describe(size))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            if steps.count > 1 {
                Slider(value: index, in: 0...Double(steps.count - 1), step: 1)
                    .frame(width: 130)
                    // Le curseur nomme ses deux bouts : sans ça, un glissement
                    // à mi-course ne dit pas sur quelle échelle il porte.
                    .accessibilityLabel("Mémoire de \(kernel.lastPathComponent)")
                    .accessibilityValue(KernelMemory.describe(size))
            }
        }
        .onChange(of: size) { previous, chosen in
            guard previous != chosen else { return }
            KernelMemory.setSize(chosen, forKernel: kernel.lastPathComponent)
            onChange(SuspendedMachine.clearAll(named: kernel.lastPathComponent))
        }
    }
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

    /// Ce qu'un changement de disque a coûté, dit une fois et au passé.
    ///
    /// Séparé du message de mémoire, parce que la cause n'est pas la même et
    /// que « mémoire changée » après avoir touché au disque enverrait chercher
    /// au mauvais endroit.
    static func diskNote(forgotten: Int) -> String? {
        switch forgotten {
        case 0: return nil
        case 1:
            return """
                Disque changé : la machine sauvegardée pour ce noyau a été \
                oubliée. Elle portait l'ancien disque dans son instantané.
                """
        default:
            return """
                Disque changé : \(forgotten) machines sauvegardées pour ce \
                noyau ont été oubliées. Elles portaient l'ancien disque dans \
                leur instantané.
                """
        }
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

/// Ce que le dernier geste a coûté, et sous quelle icône le dire.
private struct Note {
    let text: String
    let symbol: String
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
