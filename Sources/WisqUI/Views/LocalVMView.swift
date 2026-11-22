#if os(iOS)
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WisqCore
import WisqVM
#if WISQ_RUST_CORE
import WisqVMRust
#endif

/// **L'écran d'accueil** : les machines Linux du téléphone. Choisir une
/// image, la démarrer, avoir un shell.
///
/// Il s'appelait « Linux local » et s'ouvrait par le menu + d'une liste de
/// connexions VNC, vide chez qui n'a que des machines locales : chaque
/// lancement commençait par un écran « Aucune machine » et deux gestes pour
/// atteindre les siennes. C'est maintenant par lui que l'app s'ouvre, sous le
/// titre « Machines », et les connexions à distance sont dans son menu +.
struct LocalVMListView: View {
    /// Ouvre la liste des connexions à distance (VNC, SPICE, RDP).
    let onRemote: () -> Void
    /// Change quand tout ce qui couvre l'écran doit se fermer — un lien
    /// d'appairage arrive, et sa feuille ne s'ouvrirait pas par-dessus une
    /// machine en plein écran.
    let dismissal: Int

    init(dismissal: Int = 0, onRemote: @escaping () -> Void) {
        self.dismissal = dismissal
        self.onRemote = onRemote
        // Les genres sont lus **avant la première image**, et pas dans
        // `onAppear` : celui-ci ne se déclenche qu'après un premier rendu, et
        // ce rendu-là afficherait la bibliothèque entière sous l'icône du
        // « type inconnu » le temps d'une trame.
        let files = KernelLibrary.list()
        _kernels = State(initialValue: files)
        _kinds = State(initialValue: Self.read(files))
        _disks = State(initialValue: LocalDisk.allRecorded())
        _installed = State(initialValue: InstalledMachines.list())
    }

    /// Les machines installées, la dernière lancée d'abord. Relues avec la
    /// bibliothèque : supprimer une image emporte celles qui la démarrent.
    @State private var installed: [InstalledMachine]
    /// L'image sur laquelle on est en train d'installer, le temps de la
    /// question du nom.
    @State private var installing: URL?
    /// La machine qu'on est en train de renommer.
    @State private var renaming: InstalledMachine?
    /// Le nom tapé dans l'une ou l'autre de ces deux questions.
    @State private var machineName = ""
    /// Le fichier d'une machine exportée, le temps de le partager.
    @State private var exported: ExportedMachine?

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
    /// Les images de cloud de la bibliothèque, lues au rechargement : voir
    /// `InstalledMachines.cloudImages`.
    @State private var cloudImages: Set<URL> = []
    @State private var showImporter = false
    /// La feuille qui télécharge une image depuis l'index d'une distribution.
    @State private var showDownload = false
    /// La feuille des explications : voir `MachinesAboutView`.
    @State private var showAbout = false
    @State private var importError: String?
    @State private var booting: BootTarget?
    /// L'image de cloud dont on demande le mot de passe de `root`, avant
    /// son premier démarrage.
    @State private var askingPassword: BootTarget?
    @State private var rootPassword = ""
    /// Ce que le dernier réglage a coûté, à dire une fois — et sous quelle
    /// icône, parce que « mémoire changée » sous une puce mémoire et « disque
    /// changé » sous la même puce enverraient chercher au mauvais endroit.
    @State private var note: Note?
    /// Ce que Linux local occupe. Relu après chaque geste qui peut le changer.
    @State private var storage = LocalStorage.Report.empty
    /// **Le réglage de la machine de l'émetteur**, éteint par défaut : voir
    /// `EmitterSetting`. Allumé, une image de PC s'ouvre dans l'émetteur
    /// plutôt que dans le cœur Swift.
    @AppStorage("wisq.machine.emetteur") private var emitterEnabled = false

    var body: some View {
        List {
            // **La liste vide, c'est l'accueil, et il est seul à l'écran.**
            // Il était posé par-dessus la liste (`.overlay`), et la liste
            // gardait sous lui le pied de sa section — quatre paragraphes
            // d'explications : les deux textes se chevauchaient (capture d'un
            // iPhone, le 22 novembre). L'accueil est maintenant une rangée de
            // la liste, et les explications sont dans « À propos ».
            if kernels.isEmpty {
                Section {
                    welcome
                        .cardRow()
                }
            }
            if !installed.isEmpty {
                installedSection
            }
            if !kernels.isEmpty {
                Section {
                    ForEach(kernels, id: \.self) { kernel in
                        let kind = kinds[kernel] ?? .unknown
                        VStack(alignment: .leading, spacing: Design.Space.m) {
                            Button {
                                start(BootTarget(url: kernel))
                            } label: {
                                LibraryRow(
                                    kernel: kernel,
                                    role: LibraryEntry.role(of: kind, cloudImage: cloudImages.contains(kernel)),
                                    storageLine: Self.storageLine(
                                        storage.entry(forKernel: kernel.lastPathComponent)),
                                    bootable: kind.couldBootHere || InstalledMachines.canInstall(kind)
                                        || cloudImages.contains(kernel))
                            }
                            .buttonStyle(.plain)
                            KernelMemoryMenu(
                                kernel: kernel, core: kinds[kernel]?.core
                            ) { forgotten in
                                note = Self.note(forgotten: forgotten)
                                    .map { Note(text: $0, symbol: "memorychip") }
                                storage = KernelLibrary.storageReport()
                            }
                            SettingsChips {
                                // Le disque se propose à tout ce qui démarre ici.
                                // Il n'était offert qu'aux noyaux de PC, parce que la
                                // machine RISC-V refusait le sien ; elle ne le refuse
                                // plus. Ce qu'elle ne peut toujours pas, c'est mettre
                                // le pilote bloc dans le noyau de quelqu'un — et ça,
                                // seul un démarrage peut le dire, pas cette liste.
                                if kind.couldBootHere {
                                    KernelDiskMenu(
                                        kernel: kernel, library: kernels,
                                        chosen: disks[kernel.lastPathComponent]
                                    ) { chosen in
                                        attach(chosen, key: kernel.lastPathComponent)
                                    }
                                }
                                // Le réseau ne concerne que la machine PC : la
                                // carte RISC-V n'en a pas.
                                if kind.couldBootHere, kind.core != .riscv32 {
                                    MachineNetworkToggle(key: kernel.lastPathComponent)
                                }
                                // **Une machine de plus sur ce fichier**, avec son nom,
                                // sa mémoire, son disque et sa session à elle. Un
                                // bouton visible plutôt qu'un appui long : c'est le
                                // geste qui fait exister la section du dessus, et un
                                // geste caché ne se découvre pas.
                                if InstalledMachines.canInstall(kind) || cloudImages.contains(kernel) {
                                    Button {
                                        machineName = InstalledMachines.suggestedName(
                                            forImage: kernel.lastPathComponent)
                                        installing = kernel
                                    } label: {
                                        ChipLabel(text: "Installer une machine", symbol: "plus.square.on.square",
                                                  color: Design.accent)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .card()
                        .cardRow()
                    }
                    // **La suppression était là, et elle ne se trouvait pas.**
                    // C'était un `.swipeActions` sur la ligne ; or la ligne finit
                    // par le curseur de mémoire, qui prend cent trente points à
                    // droite — là même où un balayage vers la gauche commence — et
                    // qui avale les glissements horizontaux. Un `.onDelete` garde
                    // le balayage et ajoute le bouton « Modifier » de la barre :
                    // un chemin visible, qui ne dispute rien au curseur.
                    .onDelete { positions in
                        var removed: [String] = []
                        for kernel in positions.map({ kernels[$0] }) {
                            removed += KernelLibrary.delete(kernel)
                        }
                        reloadLibrary()
                        note = Self.removedMachinesNote(removed)
                            .map { Note(text: $0, symbol: "trash") }
                        storage = KernelLibrary.storageReport()
                    }
                } header: {
                    Text("Bibliothèque")
                } footer: {
                    // Les explications (mémoire, disque, ce que wisq ne lance
                    // pas) sont dans « À propos » : `MachinesAboutView`.
                    Text("Touchez une machine pour la démarrer. Le bouton « i » dit ce que wisq lance, et comment régler la mémoire et le disque.")
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
                    if storage.unpackedIsoBytes > 0 {
                        LabeledContent(
                            "dont image d'installation déballée",
                            value: LocalStorage.describe(bytes: storage.unpackedIsoBytes))
                    }
                    if storage.partialDownloadCount > 0 {
                        // Un téléchargement interrompu reprend où il s'était
                        // arrêté : l'effacer est un choix, pas un ménage, et le
                        // bouton dit ce qu'il coûte.
                        Button(role: .destructive) {
                            let freed = KernelLibrary.discardPartialDownloads()
                            storage = KernelLibrary.storageReport()
                            note = Note(
                                text: "\(LocalStorage.describe(bytes: freed)) repris ; le prochain téléchargement repartira de zéro.",
                                symbol: "trash")
                        } label: {
                            Label(
                                "Effacer \(LocalStorage.describe(bytes: storage.partialDownloadBytes)) de téléchargements interrompus",
                                systemImage: "arrow.down.circle")
                        }
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
                }
            }

            if let importError {
                Section {
                    RefusalLabel(text: importError)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Machines")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showAbout = true
                } label: {
                    Label("À propos des machines", systemImage: "info.circle")
                }
            }
            // Le chemin visible vers la suppression. Il ne s'affiche que
            // lorsqu'il y a quelque chose à supprimer : un « Modifier » sur
            // une liste vide n'ouvre que du vide.
            if !kernels.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Deux portes vers la bibliothèque : un fichier déjà là, ou
                // une image que wisq va chercher et vérifie lui-même. Puis
                // celle des machines qui tournent ailleurs.
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Importer un fichier", systemImage: "folder")
                    }
                    Button {
                        showDownload = true
                    } label: {
                        Label("Télécharger un bureau ou une image", systemImage: "arrow.down.circle")
                    }
                    Divider()
                    Button(action: onRemote) {
                        Label("Connexions à distance (VNC, SPICE, RDP)", systemImage: "network")
                    }
                } label: {
                    Label("Ajouter", systemImage: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            // **Plusieurs à la fois** : un VMDK à descripteur est fait de
            // plusieurs fichiers, et l'application ne voit que ceux qu'on
            // choisit — pas leurs voisins.
            allowsMultipleSelection: true
        ) { result in
            do {
                let sources = try result.get()
                let companions = KernelLibrary.companionNames(importing: sources)
                var imported: [URL] = []
                for source in sources {
                    // **Une machine exportée passe par la même porte** : le
                    // fichier dit lui-même ce qu'il est.
                    let isMachine: Bool = {
                        let opened = source.startAccessingSecurityScopedResource()
                        defer { if opened { source.stopAccessingSecurityScopedResource() } }
                        return MachineArchive.isArchive(source)
                    }()
                    if isMachine {
                        let machine = try KernelLibrary.importMachine(from: source)
                        note = Note(
                            text: "« \(machine.name) » est importée, et reprendra où elle en était.",
                            symbol: "square.and.arrow.down")
                    } else {
                        imported.append(try KernelLibrary.importKernel(
                            from: source, companion: companions.contains(source.lastPathComponent)))
                    }
                }
                reloadLibrary()
                storage = KernelLibrary.storageReport()
                // Les étendues ont pu venir avant ou après leur descripteur :
                // ce qui manque ne se juge qu'une fois tout copié.
                importError = imported.lazy
                    .compactMap { VmdkDescriptorDisk.incompleteImportExplanation(ofDescriptorAt: $0) }
                    .first
            } catch {
                // Ce qui a été copié avant le refus reste, et se voit.
                reloadLibrary()
                importError = error.localizedDescription
            }
        }
        .fullScreenCover(item: $booting) { target in
            NavigationStack {
                #if WISQ_RUST_CORE
                if EmitterSetting.opens(
                    kinds[target.url], enabled: emitterEnabled, installed: target.machine != nil,
                    moduleEmbedded: EmitterMachine.isInThisBuild
                ) {
                    EmitterMachineView(image: target.url)
                } else {
                    LocalVMTerminalView(kernelURL: target.url, installed: target.machine)
                }
                #else
                LocalVMTerminalView(kernelURL: target.url, installed: target.machine)
                #endif
            }
        }
        // Un lien d'appairage arrive : tout ce que cet écran a ouvert se
        // ferme, la machine se suspend comme par « Fermer ».
        .onChange(of: dismissal) {
            booting = nil
            showDownload = false
            showImporter = false
            exported = nil
            askingPassword = nil
            installing = nil
            renaming = nil
        }
        .alert("Nouvelle machine", isPresented: Binding(
            get: { installing != nil }, set: { if !$0 { installing = nil } })
        ) {
            TextField("Nom", text: $machineName)
            Button("Installer") { install() }
            Button("Annuler", role: .cancel) { installing = nil }
        } message: {
            Text("Elle démarre \(installing?.lastPathComponent ?? "cette image") avec sa propre mémoire, son propre disque et sa propre session. Le fichier, lui, reste partagé et n'est jamais modifié.")
        }
        .sheet(isPresented: $showAbout) {
            NavigationStack { MachinesAboutView() }
        }
        .sheet(isPresented: $showDownload) {
            ImageDownloadSheet(onDownloaded: { url in
                reloadLibrary()
                storage = KernelLibrary.storageReport()
                importError = nil
                note = Note(
                    text: "« \(url.lastPathComponent) » est téléchargée et vérifiée : touchez-la pour la démarrer.",
                    symbol: "checkmark.seal")
            }, onInstalled: { machine in
                reloadLibrary()
                storage = KernelLibrary.storageReport()
                importError = nil
                note = Note(
                    text: "« \(machine.name) » est installée : touchez-la, le bureau sera là en moins d'une minute.",
                    symbol: "checkmark.seal")
            })
        }
        .sheet(item: $exported) { file in
            VStack(spacing: 18) {
                Image(systemName: "square.and.arrow.up.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("« \(file.name) » est prête à partir")
                    .font(.headline)
                Text("Le fichier porte ses réglages, ses écritures et sa session. L'image qu'elle démarre n'est pas dedans : le téléphone qui l'importe doit l'avoir dans sa bibliothèque.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: file.url) {
                    Label("Partager", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(28)
            .presentationDetents([.medium])
        }
        // **Le mot de passe de `root`, une fois.** Une image de cloud arrive
        // avec `root` verrouillé ; ce qui est donné ici n'est gardé qu'en
        // empreinte (`RootPassword`), et « Sans mot de passe » est retenu
        // aussi, pour que la question ne revienne pas.
        .alert("Mot de passe de root", isPresented: Binding(
            get: { askingPassword != nil }, set: { if !$0 { askingPassword = nil } })
        ) {
            SecureField("Mot de passe", text: $rootPassword)
            Button("Démarrer") { answerPassword(rootPassword) }
            Button("Sans mot de passe") { answerPassword(nil) }
            Button("Annuler", role: .cancel) { askingPassword = nil }
        } message: {
            Text("Ce sera celui de root dans \(askingPassword?.url.lastPathComponent ?? "cette image"). wisq n'en garde que l'empreinte. Sans mot de passe, root s'ouvre seul sur la console de wisq, et nulle part ailleurs.")
        }
        .alert("Renommer", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField("Nom", text: $machineName)
            Button("Renommer") { rename() }
            Button("Annuler", role: .cancel) { renaming = nil }
        }
        // Relu à l'ouverture, et au retour d'une session : c'est en quittant
        // une machine qu'elle est sauvegardée, donc c'est là que le chiffre
        // change le plus.
        .onAppear {
            reloadLibrary()
            storage = KernelLibrary.storageReport()
        }
        // Un téléchargement d'arrière-plan qui finit sans feuille ouverte —
        // l'application relancée par le système — range quand même son
        // image : la liste doit la montrer sans attendre qu'on la rouvre.
        .onReceive(NotificationCenter.default.publisher(for: BackgroundDownloads.libraryChanged)) { _ in
            reloadLibrary()
            storage = KernelLibrary.storageReport()
        }
        .onChange(of: booting == nil) {
            // Un démarrage range la machine en tête : la liste suit.
            installed = InstalledMachines.list()
            storage = KernelLibrary.storageReport()
        }
    }

    /// Démarre, ou demande d'abord le mot de passe de `root` d'une image de
    /// cloud qui n'a jamais démarré. La décision vit dans `RootPassword`.
    private func start(_ target: BootTarget) {
        let key = target.machine?.key ?? target.url.lastPathComponent
        if RootPassword.shouldAsk(fileAt: target.url, forKernel: key) {
            rootPassword = ""
            askingPassword = target
        } else {
            booting = target
        }
    }

    /// La réponse à la question : un mot de passe gardé en empreinte, ou
    /// « sans », puis le démarrage. Un mot de passe que `login` ne pourrait
    /// pas recevoir laisse la question ouverte, et le dit.
    private func answerPassword(_ password: String?) {
        guard let target = askingPassword else { return }
        let key = target.machine?.key ?? target.url.lastPathComponent
        if let password {
            guard RootPassword.set(password, forKernel: key) else {
                note = Note(text: "Ce mot de passe ne peut pas servir : il ne doit être ni vide, ni contenir de tabulation ou de retour à la ligne.",
                            symbol: "exclamationmark.triangle")
                askingPassword = nil
                return
            }
        } else {
            RootPassword.decline(forKernel: key)
        }
        rootPassword = ""
        askingPassword = nil
        booting = target
    }

    /// **L'accueil d'une bibliothèque vide** : une seule chose à faire en
    /// premier — aller chercher une machine —, et les deux autres portes.
    private var welcome: some View {
        VStack(spacing: Design.Space.l) {
            // Trois badges qui se chevauchent : ce que la bibliothèque
            // contiendra. Décoratifs, comme tous les badges.
            HStack(spacing: -14) {
                DistributionBadge(distribution: .alpine, size: 56)
                    .rotationEffect(.degrees(-8))
                DistributionBadge(distribution: .void, desktop: true, size: 68)
                    .zIndex(1)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                DistributionBadge(distribution: .debian, size: 56)
                    .rotationEffect(.degrees(8))
            }
            .padding(.top, Design.Space.s)
            VStack(spacing: Design.Space.s) {
                Text("Aucune machine")
                    .font(.title2.weight(.bold))
                Text("Téléchargez un bureau prêt ou une image Linux : elle démarre sur ce téléphone, sans serveur.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showDownload = true
            } label: {
                // Un texte qui passe à la ligne plutôt qu'un `Label` coupé :
                // « Télécharger un bureau o… » au premier tour de captures.
                HStack(spacing: Design.Space.s) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Télécharger un bureau ou une image")
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            // Les deux autres portes, l'une sous l'autre et nommées en entier :
            // côte à côte, leurs mots se coupaient (« Impor-ter »).
            VStack(spacing: Design.Space.s) {
                Button { showImporter = true } label: {
                    Label("Importer une image", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                Button(action: onRemote) {
                    Label("Connexions à distance", systemImage: "network")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .card(padding: Design.Space.xl)
    }

    /// Ce qu'on fait d'une machine installée, hors la démarrer : le même menu
    /// sous « Plus » et sous l'appui long.
    @ViewBuilder
    private func machineActions(_ machine: InstalledMachine, image: URL) -> some View {
        Button("Renommer", systemImage: "pencil") {
            machineName = machine.name
            renaming = machine
        }
        // L'emporter sur un autre téléphone : réglages, écritures et
        // session, sans l'image — l'autre bibliothèque doit l'avoir.
        Button("Exporter", systemImage: "square.and.arrow.up") {
            export(machine)
        }
        // Repartir d'où cette machine est — installée, configurée,
        // session comprise — sans toucher à l'original.
        Button("Dupliquer", systemImage: "plus.square.on.square") {
            duplicate(machine)
        }
        // Une machine dont le disque porte un système démarre ce
        // disque ; celle-ci revient à son image pour un démarrage —
        // réparer, réinstaller —, et le suivant revient au disque.
        if Self.isInstallationImage(kinds[image]) {
            Button("Démarrer l'image d'installation", systemImage: "opticaldisc") {
                ImageBootRequest.request(forKernel: machine.key)
                start(BootTarget(url: image, machine: machine))
            }
        }
    }

    /// Les machines installées : chacune démarre son image sous ses propres
    /// clés, et dit si elle reprendra sa session.
    @ViewBuilder
    private var installedSection: some View {
        Section {
            ForEach(installed) { machine in
                let image = imageURL(of: machine)
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    Button {
                        start(BootTarget(url: image, machine: machine))
                    } label: {
                        InstalledMachineRow(
                            machine: machine,
                            role: LibraryEntry.role(of: kinds[image] ?? .unknown,
                                                   cloudImage: cloudImages.contains(image)),
                            entry: storage.entry(forKernel: machine.key))
                    }
                    .buttonStyle(.plain)
                    KernelMemoryMenu(
                        kernel: image, key: machine.key, core: kinds[image]?.core
                    ) { forgotten in
                        note = Self.note(forgotten: forgotten)
                            .map { Note(text: $0, symbol: "memorychip") }
                        storage = KernelLibrary.storageReport()
                    }
                    SettingsChips {
                        // Une image d'installation est déjà `/dev/vda` : le disque
                        // choisi pour une machine qui la démarre arrive en second,
                        // et le menu le dit.
                        if InstalledMachines.canInstall(kinds[image] ?? .unknown)
                            || cloudImages.contains(image) {
                            KernelDiskMenu(
                                kernel: image, library: kernels, chosen: disks[machine.key],
                                title: Self.isInstallationImage(kinds[image]) || cloudImages.contains(image)
                                    ? "Disque d'installation (vdb)" : "Disque",
                                createBlank: { size in createBlankDisk(for: machine, bytes: size) }
                            ) { chosen in
                                attach(chosen, key: machine.key)
                            }
                        }
                        MachineNetworkToggle(key: machine.key)
                        // **Les gestes de l'appui long, visibles** : un menu
                        // caché derrière un appui ne se découvre pas.
                        Menu {
                            machineActions(machine, image: image)
                        } label: {
                            ChipLabel(text: "Plus", symbol: "ellipsis")
                        }
                        .accessibilityLabel("Plus d'actions pour \(machine.name)")
                    }
                }
                .card()
                .cardRow()
                .contextMenu {
                    machineActions(machine, image: image)
                }
            }
            .onDelete { positions in
                for machine in positions.map({ installed[$0] }) {
                    try? KernelLibrary.removeMachine(machine)
                }
                reloadLibrary()
                note = nil
                storage = KernelLibrary.storageReport()
            }
        } header: {
            Text("Mes machines")
        } footer: {
            Text("Touchez une machine pour la reprendre ou la démarrer. « Plus », ou un appui long : renommer, dupliquer, exporter.")
        }
    }

    /// Le fichier qu'une machine démarre. Absent de la bibliothèque, il reste
    /// nommé : le démarrage dira alors qu'il ne se lit pas, ce qui vaut mieux
    /// qu'une ligne qui disparaît sans un mot.
    private func imageURL(of machine: InstalledMachine) -> URL {
        kernels.first { $0.lastPathComponent == machine.image }
            ?? URL(fileURLWithPath: machine.image)
    }

    private func install() {
        guard let image = installing else { return }
        installing = nil
        do {
            let machine = try InstalledMachines.install(
                image: image.lastPathComponent, name: machineName)
            reloadLibrary()
            importError = nil
            note = Note(text: "« \(machine.name) » est installée. Touchez-la pour la démarrer.",
                        symbol: "plus.square.on.square")
        } catch {
            importError = error.localizedDescription
        }
    }

    private func createBlankDisk(for machine: InstalledMachine, bytes size: UInt64) {
        do {
            let name = try KernelLibrary.createBlankDisk(for: machine, bytes: size)
            reloadLibrary()
            importError = nil
            note = Note(
                text: "Disque vierge \(name) (\(KernelMemory.describe(size))) branché sur « \(machine.name) ». Il apparaîtra vide sur /dev/vda.",
                symbol: "externaldrive.badge.plus")
            storage = KernelLibrary.storageReport()
        } catch {
            importError = error.localizedDescription
        }
    }

    private func export(_ machine: InstalledMachine) {
        do {
            exported = ExportedMachine(
                name: machine.name, url: try KernelLibrary.exportMachine(machine))
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }

    private func duplicate(_ machine: InstalledMachine) {
        do {
            let copy = try KernelLibrary.duplicateMachine(machine)
            reloadLibrary()
            importError = nil
            note = Note(
                text: "« \(copy.name) » reprend où « \(machine.name) » en était, et vit sa vie à part.",
                symbol: "plus.square.on.square")
            storage = KernelLibrary.storageReport()
        } catch {
            importError = error.localizedDescription
        }
    }

    private func rename() {
        guard let machine = renaming else { return }
        renaming = nil
        do {
            try InstalledMachines.rename(id: machine.id, to: machineName)
            reloadLibrary()
        } catch {
            importError = error.localizedDescription
        }
    }

    /// Relit la bibliothèque **et** ce que chaque fichier est. Les deux vont
    /// ensemble : une liste sans ses genres dessinerait des icônes d'un
    /// fichier qui n'est plus là.
    private func reloadLibrary() {
        kernels = KernelLibrary.list()
        kinds = Self.read(kernels)
        cloudImages = InstalledMachines.cloudImages(kernels, kinds: kinds)
        disks = LocalDisk.allRecorded()
        installed = InstalledMachines.list()
    }

    /// Retient le disque choisi, et oublie ce que ce choix invalide.
    ///
    /// Les machines sauvegardées de ce noyau partent, comme au changement de
    /// mémoire et pour une raison plus dure : leur instantané porte les octets
    /// du disque tels que l'invité les a laissés. Les reprendre après un
    /// changement rendrait le réglage muet.
    ///
    /// `key` est le nom du fichier pour un fichier démarré tel quel, la clé
    /// de la machine pour une machine installée : c'est le même réglage, rangé
    /// sous la clé de ce qui démarre.
    private func attach(_ disk: String?, key name: String) {
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

/// **Ce que la liste des machines expliquait sous elle**, rangé dans une
/// feuille. Ces paragraphes étaient le pied de la liste : quatre blocs de
/// texte sous les machines, et, liste vide, sous l'accueil — qu'ils
/// traversaient (capture d'un iPhone, le 22 novembre).
struct MachinesAboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Ce que wisq lance") {
                Text("Une image Linux de PC (x86-64) — Alpine, Void, Debian… — démarre sur ce téléphone, sans serveur, avec le réseau. Un noyau RISC-V 32 bits démarre en une à deux secondes.")
                Text("**Windows et macOS ne se lancent pas sur wisq**, et c'est un choix délibéré. Pour l'un ou l'autre, ouvrez une connexion à distance vers l'ordinateur qui le fait tourner.")
            }
            Section("Machines installées") {
                Text("Chaque machine garde sa mémoire, son disque et ce qu'elle y a écrit, et reprend sa session là où vous l'avez laissée. Plusieurs machines peuvent démarrer la même image sans rien partager.")
                Text("Un **disque vierge** se crée depuis le menu du disque : l'invité le voit vide sur `/dev/vda`, à formater (`mkfs.ext4 /dev/vda`) ; il ne coûte que ce que la machine y écrit. Une fois le système installé sur son disque, la machine démarre ce disque, et non plus l'image ; « Plus » propose de redémarrer l'image d'installation une fois, pour réparer ou réinstaller.")
                Text("« Plus », ou un appui long, pour renommer, dupliquer — la copie reprend la session de l'original — ou exporter : une machine exportée s'importe par le bouton « Importer », sur un téléphone qui a son image. La supprimer efface sa session, ses écritures et son disque vierge, pas l'image.")
            }
            Section("Mémoire") {
                Text("Le curseur « Mémoire » de chaque machine règle sa mémoire. La machine de référence en a \(KernelMemory.describe(KernelMemory.defaultSize)) ; ce téléphone en autorise jusqu'à \(KernelMemory.describe(KernelMemory.ceiling)) — sa propre mémoire moins 2 Gio, laissés au système.")
                Text("Le plafond dépend de l'architecture : \(KernelMemory.describe(GuestArchitecture.Core.x86_64.maximumRAMSize)) pour un noyau de PC, \(KernelMemory.describe(GuestArchitecture.Core.riscv32.maximumRAMSize)) pour un noyau RISC-V, dont la mémoire commence à 0x80000000 et dont le processeur adresse en 32 bits.")
                Text("Changer ce réglage repart du noyau : une session prise à une autre taille ne peut pas être reprise.")
            }
            Section("Disque") {
                Text("Chaque noyau peut recevoir un **disque** : une image importée ici, que l'invité voit sur `/dev/vda`. Le disque est lu sur place, quelle que soit sa taille.")
                Text("Ce que l'invité y écrit va dans une couche à part, gardée d'une session à l'autre ; le fichier importé ne change jamais. wisq ne monte rien tout seul, et ne peut pas ajouter le pilote bloc à un noyau qui ne l'a pas.")
            }
            Section("Stockage") {
                Text("Une machine sauvegardée pèse ce que l'invité a touché, pas ce qu'on lui a donné, et un disque **en plus** : l'instantané emporte ce que l'invité y a écrit.")
                Text("Une image d'installation laisse son noyau et son initramfs déballés à côté ; ils repartent avec elle quand vous la supprimez.")
            }
        }
        .navigationTitle("À propos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fermer") { dismiss() }
            }
        }
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
    /// Ce fichier démarre-t-il quand on le touche ? Il ne porte le bouton de
    /// lecture que dans ce cas ; les autres se touchent quand même, et leur
    /// refus explique quoi faire.
    let bootable: Bool

    var body: some View {
        let name = kernel.lastPathComponent
        HStack(spacing: Design.Space.m) {
            DistributionBadge(distribution: MachineBadge.distribution(of: [name]),
                              desktop: MachineBadge.isDesktop([name]), size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Label(LibraryEntry.word(role), systemImage: LibraryEntry.symbol(role))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let storageLine {
                    Text(storageLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if bootable {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Design.accent)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(bootable ? "Démarre cette image" : "")
    }
}

/// Une machine installée : son badge, son nom, ce qu'elle démarre, et son
/// état (`MachineState`) — dont « Session sauvée », ce que la carte a de plus
/// utile à dire : c'est la différence entre retrouver son travail et
/// redémarrer, et rien d'autre à l'écran ne la montre avant de toucher.
private struct InstalledMachineRow: View {
    let machine: InstalledMachine
    let role: LibraryEntry.Role
    let entry: LocalStorage.Entry?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let names = [machine.name, machine.image]
        let state = MachineState.of(savedSessions: entry?.savedMachineCount ?? 0,
                                    lastStartedAt: machine.lastStartedAt)
        let badge = DistributionBadge(distribution: MachineBadge.distribution(of: names),
                                      desktop: MachineBadge.isDesktop(names), size: 52)
        Group {
            // En très grand texte, le badge et le bouton passent au-dessus :
            // côte à côte, le nom n'aurait plus que quelques lettres de large.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    HStack {
                        badge
                        Spacer()
                        playButton(state)
                    }
                    details(state)
                }
            } else {
                HStack(spacing: Design.Space.m) {
                    badge
                    details(state)
                    Spacer(minLength: 0)
                    playButton(state)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(state.action)
    }

    private func details(_ state: MachineState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(machine.name)
                .font(.headline)
            Text("\(machine.image) · \(LibraryEntry.word(role))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            FlowLayout(spacing: Design.Space.s) {
                StatePill(state: state)
                if let entry, entry.savedMachineBytes > 0 {
                    Text(LocalStorage.describe(bytes: entry.savedMachineBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let entry, entry.diskWritesBytes > 0 {
                Text("\(LocalStorage.describe(bytes: entry.diskWritesBytes)) écrits sur son disque")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func playButton(_ state: MachineState) -> some View {
        Image(systemName: state == .sessionSaved ? "play.fill" : "power")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(Circle().fill(Design.accent))
            .accessibilityHidden(true)
    }
}

/// **Les réglages d'une carte, en puces**, qui passent à la ligne quand la
/// place manque (`FlowLayout`) : ni défilement qui disputerait le balayage
/// de la rangée, ni puce coupée.
private struct SettingsChips<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: Design.Space.s) { content }
    }
}

/// **Couper le réseau d'une machine** : un bouton qui dit l'état et le
/// change, rangé par `MachineNetwork` sous la clé de la machine.
///
/// Pris au prochain démarrage ou à la prochaine reprise, sans rien oublier :
/// la carte reste, seul le câble change, et la session se reprend.
private struct MachineNetworkToggle: View {
    let key: String
    @State private var cut: Bool

    init(key: String) {
        self.key = key
        _cut = State(initialValue: MachineNetwork.isCut(forKernel: key))
    }

    var body: some View {
        // Une puce qui dit l'état et le change d'un toucher ; VoiceOver la
        // lit comme un interrupteur.
        Button {
            cut.toggle()
        } label: {
            ChipLabel(text: cut ? "Réseau coupé" : "Réseau", symbol: cut ? "network.slash" : "network",
                      color: cut ? .secondary : .green)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Réseau")
        .accessibilityValue(cut ? "coupé" : "branché")
        .accessibilityAddTraits(.isToggle)
        .accessibilityHint("Pris au prochain démarrage ou à la prochaine reprise")
        .onChange(of: cut) { _, now in
            MachineNetwork.setCut(now, forKernel: key)
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
    /// Le nom du réglage : « Disque », ou « Disque d'installation (vdb) »
    /// pour une machine qui démarre une image.
    var title = "Disque"
    /// Créer un disque vierge et le brancher — offert aux seules machines
    /// installées, parce que c'est à elles que le disque appartient.
    var createBlank: ((UInt64) -> Void)?
    let choose: (String?) -> Void

    var body: some View {
        let candidates = LocalDisk.candidates(
            among: library, kernel: kernel.lastPathComponent)
        Menu {
            if let createBlank {
                Menu("Nouveau disque vierge") {
                    ForEach(BlankDisk.sizes, id: \.self) { size in
                        Button(KernelMemory.describe(size)) { createBlank(size) }
                    }
                }
            }
            Button("Aucun") { choose(nil) }
            ForEach(candidates, id: \.self) { disk in
                Button(disk.lastPathComponent) { choose(disk.lastPathComponent) }
            }
        } label: {
            // Un fichier choisi puis disparu autrement que par la corbeille de
            // cette liste — remplacé, sorti du dossier — laisse un nom qui ne
            // désigne plus rien. Le dire est plus utile que de l'effacer en
            // silence : le démarrage, lui, se fera sans disque.
            ChipLabel(text: "\(title) : \(chosen ?? "aucun")", symbol: "externaldrive",
                      color: missing(candidates) ? .red : .primary)
        }
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
    /// Sous quoi le réglage est rangé : le nom du fichier, ou la clé d'une
    /// machine installée — qui a sa propre mémoire.
    let key: String
    /// **Le cœur de ce noyau, quand le fichier l'a dit.**
    ///
    /// C'est lui qui décide du plafond : deux gibioctets pour le rv32, où
    /// c'est un fait d'adressage, et seize pour la machine PC. Sans ce
    /// paramètre le curseur bornait tout le monde au plafond du rv32 — un
    /// noyau x86-64 tenu à 2 Gio par la contrainte d'une autre architecture.
    ///
    /// `nil` est une permission et non un doute, comme partout ailleurs pour
    /// `KernelImageKind` : un fichier que personne n'a lu reçoit le plus grand
    /// plafond, et c'est le démarrage qui borne pour de vrai, cœur en main.
    ///
    /// **Un ISO arrive ici avec `nil`, et c'est le cas qui a motivé la
    /// tranche.** `KernelImageKind.identify` lit l'image et répond
    /// `.discImage`, qui n'a pas d'architecture ; `IsoBoot.decide` lit le
    /// noyau *dedans* et répond x86-64. Les deux ne disaient pas la même
    /// chose, et c'est la liste qui avait tort.
    let core: GuestArchitecture.Core?
    /// Combien de machines sauvegardées le changement a coûté, pour le dire.
    let onChange: (Int) -> Void

    @State private var size: UInt64
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Le curseur, ou rien quand un seul palier est offert.
    @ViewBuilder
    private func slider(_ index: Binding<Double>, steps: [UInt64]) -> some View {
        if steps.count > 1 {
            Slider(value: index, in: 0...Double(steps.count - 1), step: 1)
                .tint(Design.accent)
                // Le curseur nomme ses deux bouts : sans ça, un glissement
                // à mi-course ne dit pas sur quelle échelle il porte.
                .accessibilityLabel("Mémoire de \(kernel.lastPathComponent)")
                .accessibilityValue(KernelMemory.describe(size))
        } else {
            Spacer(minLength: 0)
        }
    }

    init(kernel: URL, key: String? = nil, core: GuestArchitecture.Core?,
         onChange: @escaping (Int) -> Void) {
        self.kernel = kernel
        self.key = key ?? kernel.lastPathComponent
        self.core = core
        self.onChange = onChange
        _size = State(initialValue: KernelMemory.size(
            forKernel: self.key, ceiling: KernelMemory.ceiling(for: core)))
    }

    /// Les paliers que cet appareil autorise. Calculés une fois : le curseur
    /// glisse sur leurs *indices*, pas sur des octets, ce qui lui fait sauter
    /// de puissance de deux en puissance de deux plutôt que de proposer des
    /// tailles intermédiaires qu'aucune machine n'a jamais.
    private var steps: [UInt64] {
        KernelMemory.offered(ceiling: KernelMemory.ceiling(for: core))
    }

    var body: some View {
        let steps = self.steps
        let index = Binding<Double>(
            get: { Double(steps.firstIndex(of: size) ?? steps.count - 1) },
            set: { newValue in
                let clamped = min(max(Int(newValue.rounded()), 0), steps.count - 1)
                size = steps[clamped]
            })

        // Une pile plutôt qu'un `Label` figé à sa taille idéale : dans une
        // rangée de liste, celui-ci perdait son mot et prenait une hauteur
        // démesurée (premier tour de captures).
        let label = HStack(spacing: 6) {
            Image(systemName: "memorychip")
            Text("Mémoire")
                .lineLimit(1)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .layoutPriority(1)
        let value = Text(KernelMemory.describe(size))
            .font(.footnote.monospacedDigit().weight(.semibold))
        // Une rangée de la carte : le nom du réglage, le curseur, la valeur.
        // En très grand texte, le curseur passe dessous, sur toute la largeur.
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    HStack {
                        label
                        Spacer()
                        value
                    }
                    slider(index, steps: steps)
                }
            } else {
                HStack(spacing: Design.Space.m) {
                    label
                    slider(index, steps: steps)
                    value.frame(minWidth: 56, alignment: .trailing)
                }
            }
        }
        .onChange(of: size) { previous, chosen in
            guard previous != chosen else { return }
            KernelMemory.setSize(chosen, forKernel: key)
            onChange(SuspendedMachine.clearAll(named: key))
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

    /// Une image d'installation : son noyau est dedans, et elle est elle-même
    /// le premier disque de la machine.
    static func isInstallationImage(_ kind: KernelImageKind?) -> Bool {
        if case .discImage? = kind { return true }
        return false
    }

    /// Ce que la suppression d'une image a emporté avec elle.
    static func removedMachinesNote(_ names: [String]) -> String? {
        switch names.count {
        case 0: return nil
        case 1: return "La machine « \(names[0]) » est partie avec son image."
        default:
            return "Les machines " + names.map { "« \($0) »" }.joined(separator: ", ")
                + " sont parties avec leur image."
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

/// Une machine exportée, le temps de la feuille de partage.
private struct ExportedMachine: Identifiable {
    let name: String
    let url: URL
    var id: String { url.path }
}

/// Ce que le dernier geste a coûté, et sous quelle icône le dire.
private struct Note {
    let text: String
    let symbol: String
}

/// Identifiable wrapper so a kernel can drive a cover presentation.
private struct BootTarget: Identifiable {
    let url: URL
    /// La machine installée, ou `nil` pour le fichier démarré tel quel.
    var machine: InstalledMachine?
    var id: String { machine.map { "installee:\($0.id)" } ?? url.absoluteString }
}

/// The console of a running local VM: scrolling output, a command line, and the
/// same key bar philosophy as the remote sessions — v1 is line-oriented, a full
/// cell-grid terminal can come later.
struct LocalVMTerminalView: View {
    let kernelURL: URL
    /// `var` avec sa valeur par défaut, pour que l'initialiseur membre à
    /// membre la garde facultative : un `let` initialisé en est exclu.
    var installed: InstalledMachine?

    @State private var model = LocalVMModel()
    /// Démarrer la machine en arrivant : toujours, sauf pour un modèle déjà
    /// posé (`init(kernelURL:installed:posed:)`).
    private var bootsOnAppear = true
    @State private var commandLine = ""
    /// Le bureau de l'invité, posé par-dessus la console : voir `LocalDesktop`.
    @State private var showingDesktop = false
    /// La taille du texte de la console, retenue d'une session à l'autre ;
    /// toujours lue à travers `ConsoleTextSize.nearest`, qui la ramène sur un
    /// cran quelle que soit la valeur enregistrée.
    @AppStorage("wisq.console.tailleDuTexte") private var textSize = ConsoleTextSize.standard
    @FocusState private var inputFocused: Bool
    /// **Le clavier du système est-il sorti ?** Lu dans ses notifications, et
    /// pas dans `inputFocused` : sur le téléphone, rendre le focus ne
    /// rentrait pas le clavier, et l'icône du bouton mentait avec lui.
    @State private var keyboardShown = false
    /// **Le plein écran** : la console prend tout le téléphone. La barre de
    /// navigation, la barre d'état et le signe de vie s'effacent ; la barre
    /// des touches et la ligne de commande restent, puisqu'on tape. Un
    /// bouton en haut à droite le quitte. Pas retenu d'une session à
    /// l'autre : on rouvre une machine sur l'écran qu'on connaît.
    @State private var fullScreen = false
    /// **L'écran d'abord**, quand la machine en a un : c'est là que le
    /// démarrage se voit, et qu'un bureau s'ouvrira. La console reste à un
    /// geste, pour le shell de la console série.
    @State private var showsConsole = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// Ce que la saisie et la barre visent : le clavier PS/2 quand l'écran
    /// est affiché, le port série sinon.
    private var typesOnScreen: Bool { model.screen != nil && !showsConsole }

    var body: some View {
        VStack(spacing: 0) {
            if model.screen != nil && !fullScreen {
                Picker("Affichage", selection: $showsConsole) {
                    Text("Écran").tag(false)
                    Text("Console").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Design.Space.m)
                .padding(.vertical, Design.Space.s)
                .background(.bar)
            }
            if let screen = model.screen, !showsConsole {
                GuestScreenView(screen: screen, onTouch: { x, y, buttons in
                    model.touch(x: x, y: y, buttons: buttons)
                }, onWheel: { notches in
                    model.scroll(notches: notches)
                }) { dx, dy, buttons in
                    model.pointer(dx: dx, dy: dy, buttons: buttons)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        ConsoleLinesView(lines: model.consoleLines,
                                         size: ConsoleTextSize.nearest(textSize))
                    }
                    // Pincer pour grossir ou réduire, comme partout ailleurs sur
                    // le téléphone ; la taille retombe au cran le plus proche.
                    .simultaneousGesture(
                        MagnifyGesture().onEnded { value in
                            textSize = ConsoleTextSize.scaled(textSize, by: value.magnification)
                        }
                    )
                    // Faire glisser la console vers le bas range le clavier,
                    // comme dans Messages.
                    .scrollDismissesKeyboard(.interactively)
                    .background(Color.black)
                    .foregroundStyle(Color(red: 0.7, green: 0.95, blue: 0.7))
                    .onChange(of: model.consoleLines) {
                        proxy.scrollTo(ConsoleLinesView.end, anchor: .bottom)
                    }
                }
            }

            // **Le signe de vie, sous la console et hors d'elle.**
            //
            // Hors d'elle, parce que la console est un **vrai** terminal :
            // écrire cette phrase dedans la mêlerait à ce que l'invité écrit,
            // et un invité qui repeint son écran l'effacerait.
            //
            // Il existe parce qu'une capture a montré un noyau qui imprime
            // quelques lignes puis se tait dix minutes, sans que rien ne dise
            // s'il tournait encore. « Il tourne en rond » et « il est mort »
            // ne se corrigent pas pareil.
            // **La première reprise d'un bureau prêt, dite pendant qu'elle se
            // fait** : une douzaine de secondes où l'écran montre le bureau
            // sans répondre au doigt. Même en plein écran : c'est là qu'il
            // a l'air figé. Voir `ResumeWait`.
            if let resumeWait = model.resumeWait {
                Label(resumeWait, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .accessibilityLabel(resumeWait)
            }
            if !fullScreen, let heartbeat = model.heartbeat {
                // Un point vert quand la machine tourne, et la phrase.
                HStack(spacing: Design.Space.s) {
                    Circle()
                        .fill(model.status.isRunning ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(heartbeat)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Space.m)
                .padding(.vertical, Design.Space.xs)
                .background(.bar)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Avancement de la machine : \(heartbeat)")
            }

            // **Ce que la frappe sur l'écran a à dire** : un collage long qui
            // s'écrit encore, ou des caractères qu'un clavier américain n'a
            // pas. Sans cette ligne, la fin d'un collage disparaissait sans
            // que rien ne le dise. Voir `ScreenTypist`.
            //
            // **Et un bouton pour l'annuler** : ce qui attend passe avant ce
            // qu'on tape ensuite, Ctrl-C compris, et un gros fichier collé
            // par erreur tiendrait le clavier de la machine des heures.
            if !fullScreen, typesOnScreen, let typingNote = model.typingNote {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(typingNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.typingInProgress {
                        Button("Annuler la frappe", role: .destructive) {
                            model.cancelTyping()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            // **Les touches qu'un shell demande.** Tabulation pour compléter,
            // flèches pour l'historique, Échap et Ctrl pour un éditeur : sans
            // elles on lance des commandes, on ne travaille pas. Ce que chaque
            // touche envoie vient de `TerminalKey`, tenu par des tests.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Design.Space.s) {
                    // **Le clavier se range** : sorti, il couvre la moitié
                    // du téléphone, et on regarde l'écran de la machine bien
                    // plus souvent qu'on n'y tape. Ce bouton le rentre ou le
                    // ressort ; les touches de la barre, elles, marchent
                    // clavier rangé, sans le ressortir.
                    //
                    // **Rentré par UIKit, pas par le focus.** La première
                    // version rendait `inputFocused`, et une capture du
                    // téléphone a montré le clavier resté là : dans un écran
                    // présenté en plein écran, SwiftUI ne le rentrait pas.
                    // `resignFirstResponder` envoyé à la chaîne des
                    // répondeurs le rentre, quel que soit qui le tient.
                    Button {
                        if keyboardShown {
                            inputFocused = false
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        } else {
                            inputFocused = true
                        }
                    } label: {
                        Image(systemName: keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                    }
                    .buttonStyle(KeyCapStyle(held: keyboardShown))
                    .accessibilityLabel(keyboardShown ? "Ranger le clavier" : "Sortir le clavier")
                    // **Coller**, en tête de la barre : le champ de saisie
                    // n'a qu'une ligne, et un script copié depuis une page y
                    // perdait ses retours à la ligne. Ce qui part vient de
                    // `TerminalPaste`, tenu par des tests.
                    Button {
                        if let text = UIPasteboard.general.string {
                            if typesOnScreen {
                                model.typeOnScreen(commandLine + text)
                            } else {
                                model.paste(text, afterTyped: commandLine)
                            }
                            commandLine = ""
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(KeyCapStyle())
                    .accessibilityLabel("Coller le presse-papiers dans la console")
                    ForEach(TerminalKey.bar, id: \.self) { key in
                        Button {
                            if typesOnScreen {
                                model.typeOnScreen(commandLine)
                                model.pressOnScreen(key)
                            } else {
                                model.press(key, afterTyped: commandLine)
                            }
                            commandLine = ""
                        } label: {
                            Text(key.label)
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                        }
                        .buttonStyle(KeyCapStyle())
                        .accessibilityLabel(key.spokenName)
                    }
                }
                .padding(.horizontal, Design.Space.m)
                .padding(.vertical, 2)
            }
            .padding(.top, Design.Space.s)
            .background(.bar)

            HStack(spacing: Design.Space.s) {
                TextField("commande", text: $commandLine)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, Design.Space.m)
                    .padding(.vertical, Design.Space.s)
                    .background(Capsule().fill(Design.chipFill))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    // La touche Retour du clavier rend le champ ; on le
                    // reprend, pour taper la commande suivante.
                    .onSubmit {
                        submit()
                        inputFocused = true
                    }
                // Le bouton, lui, ne touche pas au clavier : rangé, il le
                // reste.
                Button(action: submit) {
                    Image(systemName: "return")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Design.accent))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Entrée")
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.s)
            .background(.bar)
        }
        // **Le bureau se pose par-dessus, il ne se présente pas.** Une
        // feuille ou une `fullScreenCover` ferait disparaître cet écran, et
        // `onDisappear` suspendrait la machine dont on veut justement voir le
        // bureau.
        .overlay {
            if showingDesktop, let port = model.desktopPort {
                SessionView(
                    machine: LocalDesktop.machine(
                        port: port, name: installed?.name ?? kernelURL.lastPathComponent),
                    credentials: EphemeralCredentialStore(),
                    onClose: { showingDesktop = false })
                .ignoresSafeArea()
            }
        }
        .navigationTitle(installed?.name ?? kernelURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        // **L'écran d'une machine est sombre, en mode clair aussi**, comme un
        // lecteur de photos : l'écran de l'invité et la console sont noirs, et
        // le titre noir de la barre s'y effaçait (deux tours de captures, un
        // fond de barre n'y changeait rien sous iOS 26). Barre, touches et
        // champ suivent la console.
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // Une seule visibilité pour la barre : deux modificateurs se
        // disputeraient, et le bureau comme le plein écran la veulent cachée.
        .toolbar(showingDesktop || fullScreen ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(fullScreen)
        .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
        .overlay(alignment: .topTrailing) {
            if fullScreen {
                Button {
                    withAnimation { fullScreen = false }
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .padding(8)
                .accessibilityLabel("Quitter le plein écran")
            }
        }
        .toolbar {
            // **Fermer garde la machine.** L'écran est une `fullScreenCover`,
            // qu'on ne fait pas glisser : sans ce bouton, la seule sortie
            // était « Arrêter », qui efface la session — et une machine qui
            // avait mis vingt minutes à démarrer repartait de zéro. Fermer
            // laisse `onDisappear` la suspendre, et la liste la reprendra.
            ToolbarItem(placement: .cancellationAction) {
                Button("Fermer") { dismiss() }
            }
            // Le bureau, quand la machine a le réseau. Il ne répond qu'une fois
            // un serveur VNC lancé dans l'invité ; d'ici là, la session dit
            // qu'elle ne joint personne, et `LocalDesktop.hint` dit quoi lancer.
            if model.desktopPort != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Bureau", systemImage: "display") {
                        inputFocused = false
                        showingDesktop = true
                    }
                    .accessibilityHint(LocalDesktop.hint)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Plein écran", systemImage: "arrow.up.left.and.arrow.down.right") {
                    withAnimation { fullScreen = true }
                }
            }
            // **Le reste dans un menu** : cinq boutons côte à côte serraient le
            // titre de la machine jusqu'à l'effacer.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // **Copier toute la console** : chaque ligne se sélectionne à
                    // part depuis qu'elles sont mises en page une par une (voir
                    // `ConsoleLinesView`) ; le tout part d'ici.
                    Button("Copier la console", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = model.consoleText
                    }
                    Menu("Taille du texte", systemImage: "textformat.size") {
                        Button("Plus grand", systemImage: "plus.magnifyingglass") {
                            textSize = ConsoleTextSize.larger(than: textSize)
                        }
                        .disabled(!ConsoleTextSize.canGrow(textSize))
                        Button("Plus petit", systemImage: "minus.magnifyingglass") {
                            textSize = ConsoleTextSize.smaller(than: textSize)
                        }
                        .disabled(!ConsoleTextSize.canShrink(textSize))
                        Button("Taille normale") { textSize = ConsoleTextSize.standard }
                            .disabled(ConsoleTextSize.nearest(textSize) == ConsoleTextSize.standard)
                    }
                    // Offered only when there is something to forget. "Arrêter"
                    // also clears the saved machine, but only by ending the
                    // session; this is for the user whose guest is wedged and who
                    // wants to walk away now and come back to a clean boot.
                    if model.hasSavedMachine {
                        Button("Oublier", systemImage: "trash") {
                            model.forgetSavedMachine()
                        }
                    }
                    Divider()
                    Button("Arrêter", systemImage: "stop.fill", role: .destructive) {
                        model.stop()
                        dismiss()
                    }
                } label: {
                    Label("Plus", systemImage: "ellipsis.circle")
                }
            }
        }
        // **La raison d'un arrêt s'écrit dans la console** : écran affiché,
        // on ne la verrait pas. La vue y bascule quand la machine s'arrête.
        .onChange(of: model.status) { _, status in
            if case .finished = status { showsConsole = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
        // **Pas de clavier d'office** : il sort quand on touche le champ ou
        // son bouton. Ouvert à chaque machine, il cachait la moitié de
        // l'écran à qui ne venait que regarder.
        .onAppear {
            if bootsOnAppear { model.boot(kernelURL: kernelURL, installed: installed) }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        // Leaving the screen suspends rather than stops: the machine is put
        // down where it stands and picked up on the next visit — "Fermer"
        // is that. Only the "Arrêter" button ends it, which is what that
        // word has to mean.
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

    init(kernelURL: URL, installed: InstalledMachine? = nil) {
        self.kernelURL = kernelURL
        self.installed = installed
    }

    /// **L'écran d'un modèle déjà posé** (`LocalVMModel.pose`), qu'il ne
    /// démarre pas : ce que les aperçus de l'interface photographient.
    init(kernelURL: URL, installed: InstalledMachine? = nil, posed: LocalVMModel) {
        self.kernelURL = kernelURL
        self.installed = installed
        _model = State(initialValue: posed)
        bootsOnAppear = false
    }

    private func submit() {
        if typesOnScreen {
            model.typeOnScreen(commandLine + "\n")
        } else {
            model.sendLine(commandLine)
        }
        commandLine = ""
    }
}

/// **La console, une ligne par vue, dans une pile paresseuse.**
///
/// C'était un seul `Text` de toute la console — deux mille lignes de
/// défilement plus l'écran — que SwiftUI remettait en page en entier à
/// chaque sortie de l'invité. Pendant un démarrage bavard, le fil principal ne
/// faisait plus que ça, et le clavier comme le défilement attendaient
/// derrière. `LazyVStack` ne met en page que les lignes à l'écran.
///
/// Une ligne vide garde la hauteur d'une ligne : un `Text` vide n'en a pas, et
/// les paragraphes du journal de démarrage se seraient recollés.
struct ConsoleLinesView: View {
    let lines: [String]
    let size: Double

    /// La dernière vue de la pile, où la console se cale quand elle avance.
    static let end = "console-end"

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty || lines == [""] {
                Text("Démarrage…")
            } else {
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index].isEmpty ? " " : lines[index])
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Color.clear.frame(height: 1).id(Self.end)
        }
        .font(.system(size: size, design: .monospaced))
        .textSelection(.enabled)
        .padding(10)
    }
}

#endif
