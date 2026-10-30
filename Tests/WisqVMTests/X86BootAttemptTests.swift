import XCTest

@testable import WisqVM

/// Jusqu'où va-t-on ?
///
/// Ce test ne prétend pas démarrer Linux. Il **essaie**, et rapporte où ça
/// s'arrête — ce qui vaut mieux que de deviner ce qui manque. Le premier arrêt
/// nomme la première chose à écrire ensuite ; c'est la façon la plus courte de
/// choisir la tranche suivante.
///
/// Il n'échoue donc que si la préparation elle-même casse, jamais parce que le
/// noyau ne va pas assez loin.
///
/// **Où on en est, mesuré le 4 septembre 2026 : Linux démarre jusqu'au bout.**
/// Le vrai noyau d'Alpine 3.20 — Linux 6.6.134-0-lts — se décompresse, entre
/// dans son propre espace d'adressage, trouve son horloge, initialise ses
/// sous-systèmes, et arrive à `kernel_init`, où il s'arrête pour la seule
/// raison qui reste :
///
/// ```
/// [    0.000000] Linux version 6.6.134-0-lts (buildozer@build-3-20-x86_64) …
/// [    8.929917] printk: console [ttyS0] enabled
/// [   21.480833] smpboot: Total of 1 processors activated (28.82 BogoMIPS)
/// [   21.546634] devtmpfs: initialized
/// [   32.137346] TCP: Hash tables configured (established 2048 bind 2048)
/// [   44.818378] ---[ end Kernel panic - not syncing: VFS: Unable to mount
///                    root fs on unknown-block(0,0) ]---
/// ```
///
/// **C'est la bonne fin.** Un noyau sans disque et sans initrd dit exactement
/// ça, sur une vraie machine comme ici. 262 lignes de journal, une trace
/// d'appels avec les noms des fonctions — donc `printk`, la table des
/// symboles, le dérouleur de pile, les exceptions et l'horloge marchent tous.
///
/// **Avec un initrd, ça va plus loin.** `WISQ_PC_INITRD` désigne un
/// initramfs ; le noyau le déballe dans un tmpfs et exécute son `/init`. Avec
/// l'`initramfs-lts` d'Alpine, mesuré le 4 septembre 2026 après le TSS :
///
/// ```
/// [  156.951571] modprobe[405]: segfault at 27d7eb9f76ac0 …
/// [  158.985105] Run /init as init process
/// [  159.045459] init[1]: segfault at 37cde165f730c ip 00007f89e84be249
///                sp 00007ffd96773770 error 5 in ld-musl-x86_64.so.1
/// [  159.051870] Kernel panic — Attempted to kill init! exitcode=0x0000000b
/// ```
///
/// **Plus aucun opcode refusé** : le budget entier de 3,5 milliards
/// d'instructions passe, le journal grandit de 12 685 à 17 225 octets, le
/// noyau finit son initialisation et lance `/init`, qui fait de vrais appels
/// système — `modprobe` tourne deux fois avant lui.
///
/// **Et l'arrêt suivant est nommé, précisément.** Le programme meurt d'un
/// SIGSEGV dans le chargeur de musl. Les octets que le noyau imprime —
/// `<8b> 87 8c 00 00 00`, c'est-à-dire `mov 0x8c(%rdi),%eax` — se retrouvent à
/// l'offset 0x4f209 de `ld-musl-x86_64.so.1`, au début de **`feof`**. Le
/// `FILE *` qu'on lui passe vaut `0x00037cde165f7280` là où un pointeur de
/// cette bibliothèque ressemble à `0x00007f89e85118a0`. Ce n'est donc plus une
/// instruction qui manque : c'est une valeur qui se corrompt quelque part, et
/// c'est la tranche suivante.
///
/// **L'ordre des trois dernières briques n'était pas celui du plan.** Il
/// disait « le TSS, puis SYSCALL » ; la machine a dit que `MOVD` venait
/// d'abord, parce que la bibliothèque C se sert de SSE dans ses fonctions de
/// chaîne **avant** son premier appel système. Le plan avait raison sur le
/// quoi et tort sur l'ordre, deux fois de suite.
///
/// **Comment on y est arrivé** : chaque arrêt a nommé la brique suivante, et
/// jamais l'inverse. Voir `X86InterruptTests` pour la livraison d'exception,
/// `X86KernelBricksTests` pour les instructions, `X86LegacyDevicesTests` pour
/// le contrôleur d'interruptions et l'horloge.
///
/// **Le budget par défaut est de 3,5 milliards d'instructions**, ce qui prend
/// environ quatre minutes et demie en release et bien plus en debug ;
/// `WISQ_PC_BUDGET` le change, et les assertions ne tiennent que si on ne l'a
/// pas baissé.
final class X86BootAttemptTests: XCTestCase {
    /// L'invite du shell de secours d'Alpine. C'est elle qui dit qu'il y a
    /// quelqu'un pour lire ce qu'on tape.
    static let prompt = "~ # "
    /// Ce qui dit aussi qu'on peut taper, sur un système **installé** et pas
    /// seulement en secours : l'invite de connexion de `getty`, et celle du
    /// shell de `root` une fois connecté (`localhost:~# `). Sans elles, une
    /// ISO qui démarre jusqu'au bout — « Welcome to Alpine Linux » — laissait
    /// le banc muet devant `login:`, et la course finissait sans qu'on ait
    /// rien demandé à la machine.
    ///
    /// Et `Password: ` : l'image de cloud de Debian demande le mot de passe de
    /// `root`, vide, après le nom. Sans cette invite, le banc attendait, la
    /// saisie expirait sur « Login incorrect », et la ligne suivante tombait
    /// sur un nouveau `login:`. Une entrée `\n` y répond.
    /// `~]# ` est l'invite de `root` chez Fedora et RHEL, `[root@hôte ~]# `.
    /// La dernière : `sulogin`, en mode de secours, attend une touche avant
    /// d'ouvrir le shell (AlmaLinux 9, voir `CloudBoot.legacyConsoleOptions`).
    static let prompts = [prompt, "login: ", "~# ", "~]# ", "Password: ", "(or press Control-D to continue): "]

    /// Le texte sans ses séquences d'échappement : l'invite d'openSUSE
    /// (`localhost:~ #`) remet les couleurs à zéro **entre** le `#` et
    /// l'espace, et `~ # ` ne s'y lisait pas — le banc attendait devant un
    /// shell prêt.
    static func withoutEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}(\\[[0-9;?]*[ -/]*[@-~]|[()][0-9A-Za-z]|\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|[0-9=>A-Za-z])",
                                  with: "", options: .regularExpression)
    }

    /// **L'invite d'openSUSE se voit à travers ses couleurs**, et ce que
    /// systemd envoie avant — la remise à zéro, la question sur la taille, la
    /// marque OSC 3008 de la session — n'en laisse rien.
    func testTheOpenSUSEPromptIsSeenThroughItsColours() {
        let tail = "\u{1B}[!p\u{1B}]104\u{07}\u{1B}[0m\u{1B}[?7h\u{1B}[1G\u{1B}[0J\u{1B}7\u{1B}[32766;32766H\u{1B}[6n"
            + "\u{1B}8\u{1B}]3008;start=63bb;user=root;type=service\u{1B}\\\u{1B}[1mlocalhost:~ #\u{1B}[m\u{1B}(B "
        XCTAssertFalse(Self.prompts.contains { tail.contains($0) }, "tel quel, l'invite ne se lit pas")
        XCTAssertEqual(Self.withoutEscapes(tail), "localhost:~ # ")
    }

    /// Ce qu'on dit à l'invité quand personne n'a rien demandé d'autre, et
    /// dont la réponse est exigée : `echo` est dans le shell lui-même, donc
    /// la réponse ne dépend d'aucun programme à charger.
    static let greeting = "echo wisq-parle"

    /// Une pagination d'identité sur les quatre premiers gibioctets, en pages
    /// de un gibioctet : quatre entrées suffisent, là où des pages de quatre
    /// kibioctets en demanderaient un million.
    static func identityMap(_ memory: X86Memory, pml4: UInt64) throws {
        let pdpt = pml4 + 0x1000
        try memory.write(pml4, 8, pdpt | X86Core.present | 0x2)
        for gigabyte in 0..<4 {
            let entry = UInt64(gigabyte) << 30
            try memory.write(pdpt + UInt64(gigabyte) * 8, 8,
                             entry | X86Core.present | X86Core.hugePage | 0x2)
        }
    }

    /// **Ce qu'on a gardé, et ce qu'on a vu.** Quand un témoin ne retient que
    /// les derniers cas, dire leur nombre revient à réciter son propre plafond
    /// — « retours rompus : 8 » quand la limite est huit ne compte rien. Le
    /// total le sépare de « huit et quelques ».
    static func kept(_ kept: Int, of seen: UInt64) -> String {
        UInt64(kept) == seen ? "\(seen)" : "\(kept) gardés sur \(seen)"
    }

    func testHowFarARealKernelGets() throws {
        let environment = ProcessInfo.processInfo.environment
        // **Une image de cloud, telle quelle** (`WISQ_PC_CLOUD_IMAGE`) : le
        // noyau, l'initramfs et la ligne de commande sont ceux que `CloudBoot`
        // y trouve, comme dans l'application, et l'image est le disque.
        // `WISQ_PC_ROOT_PASSWORD` donne le mot de passe de `root`.
        let cloudPath = environment["WISQ_PC_CLOUD_IMAGE"]
        // **Le système qu'un installateur a écrit** (`WISQ_PC_INSTALLED_DISK`,
        // avec sa couche `WISQ_PC_WRITES`) : trouvé à travers la couche, comme
        // l'application le fait pour une machine installée, et démarré depuis
        // ce disque. Voir `InstalledSystem`.
        let installedPath = environment["WISQ_PC_INSTALLED_DISK"]
        let installed: CloudBoot? = try installedPath.map { path in
            guard let writes = environment["WISQ_PC_WRITES"],
                  let found = InstalledSystem.find(disk: URL(fileURLWithPath: path),
                                                   writes: URL(fileURLWithPath: writes))
            else { throw XCTSkip("aucun système installé sur \(path)") }
            return found
        }
        let cloud: CloudBoot? = try installed ?? cloudPath.map { path in
            let fd = open(path, O_RDONLY)
            guard fd >= 0, let image = try VirtualDiskImages.image(takingOwnershipOf: fd) else {
                throw XCTSkip("image de cloud illisible : \(path)")
            }
            return try CloudBoot.find(in: image, rootPassword: environment["WISQ_PC_ROOT_PASSWORD"])
        }
        guard let data = cloud.map({ Data($0.kernel) })
                ?? environment["WISQ_PC_KERNEL"].flatMap({ FileManager.default.contents(atPath: $0) })
        else {
            throw XCTSkip("noyau PC absent : définir WISQ_PC_KERNEL ou WISQ_PC_CLOUD_IMAGE pour ce test")
        }

        // Un disque en mémoire, quand on en désigne un : c'est ce qui donne un
        // espace utilisateur, puisque le noyau d'Alpine n'a aucun pilote de
        // disque compilé dedans — ce sont des modules, et ils sont là-dedans.
        let ramdisk = cloud?.initrd ?? environment["WISQ_PC_INITRD"]
            .flatMap { FileManager.default.contents(atPath: $0) }
            .map { [UInt8]($0) }
        // `WISQ_PC_RAM_MIB` règle la mémoire : l'initramfs d'Ubuntu 26.04
        // pèse 72 Mio compressé, et se déballe en mémoire.
        let mebibytes = environment["WISQ_PC_RAM_MIB"].flatMap(Int.init) ?? (ramdisk == nil ? 256 : 512)
        let memory = X86Memory(size: mebibytes << 20, base: 0)
        // Un disque, quand on en donne un. Le noyau ne le trouvera que si la
        // ligne de commande le lui dit — voir `WISQ_PC_CMDLINE`.
        if let path = ProcessInfo.processInfo.environment["WISQ_PC_DISK"],
           let image = FileManager.default.contents(atPath: path) {
            let disk = VirtioBlock(image: [UInt8](image))
            // **Deux portes vers le même disque.** Le transport MMIO répond
            // aux adresses, le bus PCI aux ports ; ce noyau-ci ne sait passer
            // que par le second — son `virtio_mmio` est compilé sans les
            // périphériques de la ligne de commande —, mais un noyau qui les
            // a saura passer par le premier.
            memory.storage = disk
            memory.bus = X86PCIHost(storage: disk)
        }
        // Le même disque, mais **sur fichier**, par `FileDiskStore` : le chemin
        // de l'application, et celui qui lit un qcow2 à travers ses tables. La
        // couche d'écriture part dans un dossier temporaire, et le fichier
        // donné n'est jamais modifié.
        //
        // `WISQ_PC_WRITES` nomme la couche d'écriture au lieu d'un fichier
        // temporaire : deux courses qui la partagent sont deux démarrages de la
        // **même** machine. C'est ainsi qu'on mesure un second démarrage, celui
        // qui relit ce que le premier a laissé (le cache des profils AppArmor
        // d'Ubuntu, par exemple).
        if let path = cloudPath ?? installedPath ?? environment["WISQ_PC_DISK_FILE"] {
            let writes = environment["WISQ_PC_WRITES"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("wisq-banc-\(UUID().uuidString).writes")
            let disk = VirtioBlock(store: try FileDiskStore(
                base: URL(fileURLWithPath: path), writes: writes))
            memory.storage = disk
            memory.bus = X86PCIHost(storage: disk)
        }
        // Un second disque, sur l'emplacement quatre : `vdb` pour le noyau.
        // C'est le disque sur lequel on installe quand le premier est l'image.
        //
        // `WISQ_PC_SECOND_WRITES` lui donne une couche d'écriture, comme
        // l'application le fait : ce qu'un installateur y écrit survit à la
        // course, et une course suivante peut démarrer le système installé.
        if let path = ProcessInfo.processInfo.environment["WISQ_PC_SECOND_DISK"] {
            let second: VirtioBlock?
            if let writes = environment["WISQ_PC_SECOND_WRITES"] {
                second = VirtioBlock(store: try FileDiskStore(
                    base: URL(fileURLWithPath: path), writes: URL(fileURLWithPath: writes)))
            } else {
                second = FileManager.default.contents(atPath: path).map { VirtioBlock(image: [UInt8]($0)) }
            }
            if let second {
                let bus = memory.bus ?? X86PCIHost(storage: nil)
                bus.second = X86PCIHost(secondStorage: second)
                memory.bus = bus
            }
        }
        // **Une carte réseau** (`WISQ_PC_NET=1`), sur l'emplacement cinq. Son
        // autre bout ne fait que compter : de quoi voir le pilote la trouver,
        // lever le lien et envoyer ses premières trames.
        let cable = environment["WISQ_PC_NET"] == nil ? nil : CountingCable()
        if let cable {
            let bus = memory.bus ?? X86PCIHost(storage: nil)
            bus.network = X86PCIHost(network: VirtioNet(backend: cable))
            memory.bus = bus
        }
        // **Ce que le témoin a rendu, le 6 septembre 2026**, avec un vrai
        // noyau Alpine LTS et `WISQ_PC_DISPLAY=1024x768` :
        //
        //     [drm] Initialized simpledrm 1.0.0 for simple-framebuffer.0
        //     simple-framebuffer.0: [drm] fb0: simpledrmdrmfb frame buffer device
        //
        // Et, deux lignes plus haut, une confirmation qu'on n'avait pas
        // demandée : « Cannot satisfy [mem 0xe0000000-0xe0200000] with a
        // huge-page mapping » — le noyau mappe exactement l'adresse que la
        // machine a choisie. Les trois tranches de l'écran disent donc vrai,
        // et c'est le noyau qui le dit, pas une assertion sur la page zéro.
        //
        // **Un écran, quand on en demande un.** `WISQ_PC_DISPLAY=1024x768`
        // arme le cadre linéaire. C'est le témoin de la tranche : on ne
        // vérifie pas des pixels, on lit ce que le noyau **dit** de l'écran
        // dans son propre journal. Un cadre correctement déclaré fait parler
        // `sysfb` ou `simpledrm` ; un cadre mal déclaré est ignoré en silence,
        // et le silence est justement ce qu'aucune assertion sur la page zéro
        // ne peut distinguer d'un succès.
        var screen: X86BootLoader.Framebuffer?
        if let asked = ProcessInfo.processInfo.environment["WISQ_PC_DISPLAY"] {
            let parts = asked.lowercased().split(separator: "x")
            let width = parts.count == 2 ? Int(parts[0]) ?? 1024 : 1024
            let height = parts.count == 2 ? Int(parts[1]) ?? 768 : 768
            let frame = X86Framebuffer(base: X86Machine.displayBase, width: width, height: height)
            memory.screen = frame
            screen = X86BootLoader.Framebuffer(
                base: frame.base, width: frame.width, height: frame.height)
        }

        // Ce qu'on dit au noyau. `WISQ_PC_CMDLINE` **ajoute** à la ligne par
        // défaut plutôt que de la remplacer : la console série en fait partie,
        // et une mesure qui la perdrait ne dirait plus rien du tout.
        // Avec une image de cloud, `WISQ_PC_CMDLINE` s'ajoute à la ligne de
        // l'image : de quoi demander à udev ses journaux sans rien perdre.
        let extra = [cloud?.commandLine, environment["WISQ_PC_CMDLINE"]]
            .compactMap { $0 }.joined(separator: " ")
        if let cloud { print("ligne de commande (\(cloud.origin)) : \(cloud.commandLine)") }
        let commandLine = [X86BootLoader.defaultCommandLine, extra]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let placement = try X86BootLoader.load(
            kernel: [UInt8](data), into: memory, commandLine: commandLine,
            initialRamdisk: ramdisk, framebuffer: screen)

        // Les tables, hors du chemin du noyau et de la page zéro.
        let pml4: UInt64 = 0x5_0000
        try Self.identityMap(memory, pml4: pml4)

        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: placement.entryPoint, memory: memory)
        // Ce que le protocole exige à l'entrée 64 bits : le mode long actif,
        // la pagination en place, et RSI sur la page zéro.
        core.system.control[3] = pml4
        core.system.control[4] = X86SystemState.physicalAddressExtension
        core.system.modelSpecific[X86SystemState.efer] = X86SystemState.longModeEnable
        core.system.control[0] = X86SystemState.paging | X86SystemState.protectedMode
        core.system.refreshLongMode()
        core.pagingActive = true
        core.registers[6] = placement.bootParametersAddress
        core.registers[4] = 0x9_0000  // une pile quelque part sous le noyau

        XCTAssertTrue(core.system.longMode, "le mode long doit être actif avant le saut")

        // Le témoin des adresses non canoniques, quand on le demande. Il coûte
        // une recopie des seize registres par instruction d'anneau trois, donc
        // il n'est pas armé pour le démarrage ordinaire.
        core.canonicalWatchArmed =
            ProcessInfo.processInfo.environment["WISQ_PC_WATCH"] != nil
        // Le témoin d'adresse ne s'arme que si on lui en donne une : elle n'est
        // connue qu'après une première mesure. Voir `X86AddressWatch.swift`.
        // La forme est `adresse` ou `adresse+longueur`, en hexadécimal.
        // Le témoin d'adresse suit un programme par défaut ; pour suivre le
        // chargeur de modules, il faut lui dire de regarder aussi le noyau.
        core.watchesKernel = ProcessInfo.processInfo.environment["WISQ_PC_WATCH_KERNEL"] != nil
        if let asked = ProcessInfo.processInfo.environment["WISQ_PC_WATCH_ADDRESS"] {
            let halves = asked.split(separator: "+", maxSplits: 1)
            core.watchedAddress = halves.first.flatMap { UInt64($0, radix: 16) }
            if halves.count == 2, let length = UInt64(halves[1], radix: 16), length > 0 {
                core.watchedLength = length
            }
            // Et la profondeur, parce que soixante-quatre passages sur une
            // structure ne couvrent que quelques milliers d'instructions.
            if let depth = ProcessInfo.processInfo.environment["WISQ_PC_WATCH_DEPTH"]
                .flatMap({ Int($0) }), depth > 0 {
                core.addressTouches = [X86Core.AddressTouch](repeating: .none,
                                                             count: depth)
            }
        }

        var stopped: Error?
        // Ce qu'on tape, quand l'invité se tait. Par défaut une seule ligne,
        // dont la réponse est exigée plus bas : c'est la preuve que la machine
        // **écoute**. `WISQ_PC_INPUT` les remplace, séparées par `;;`.
        var toType = (ProcessInfo.processInfo.environment["WISQ_PC_INPUT"]
            .map { $0.components(separatedBy: ";;") } ?? [Self.greeting])
            .filter { !$0.isEmpty }
        var typed: [String] = []
        do {
            let budget = ProcessInfo.processInfo.environment["WISQ_PC_BUDGET"]
            // **L'attente a sa propre allocation.** Sans elle, l'invité qui
            // patiente devant un média de démarrage absent brûle son budget
            // d'instructions à ne rien faire, et ses temporisations ne peuvent
            // jamais expirer — on lui coupe le courant avant.
            let patience = ProcessInfo.processInfo.environment["WISQ_PC_WAIT"]
                .flatMap { UInt64($0) }
            // **Les valeurs par défaut vont jusqu'au shell de secours.** Alpine
            // y arrive après quatre milliards d'instructions retirées, et il
            // lui faut patienter devant un média de démarrage absent — douze
            // secondes de temps invité ; on en donne le double, compté en
            // battements pour qu'il suive `instructionsPerTick`.
            let allowance = budget.flatMap { UInt64($0) } ?? 4_500_000_000
            let patient = patience ?? 24 * 1_193_182 * X86LegacyDevices.instructionsPerTick

            // **La conversation.** Une course s'arrête quand la machine a
            // épuisé sa patience, c'est-à-dire quand elle n'a plus rien à
            // faire : c'est le moment de parler. Tant que l'invite n'est pas
            // là, on la laisse continuer — taper avant qu'un shell existe
            // n'écrirait que dans le tampon d'un pilote qui n'est pas encore
            // ouvert.
            //
            // **Par tranches, et pas seulement au repos.** Sur un système
            // installé, des services tournent encore pendant que `login`
            // attend : la machine n'est jamais au repos, et `login` abandonnait
            // au bout de ses soixante secondes avant qu'on ait tapé le mot de
            // passe. On avance donc de cinquante millions d'instructions à la
            // fois, et l'on tape **à la tranche qui suit** celle où une
            // invite est apparue depuis la dernière frappe ; au repos sans
            // invite nouvelle, c'est fini.
            //
            // L'attente d'une tranche compte : `login` vide l'entrée juste
            // après avoir écrit `Password: `, et un mot de passe tapé dans le
            // même souffle que l'invite était jeté. Attendre que la console se
            // taise ne marche pas non plus : tant que des tâches de démarrage
            // tournent, systemd réécrit son état chaque seconde, et le silence
            // ne venait qu'après l'expiration de `login`.
            var remaining = allowance
            var answeredUpTo = 0
            var promptSeen = false
            // **Où passe le temps de l'invité.** Avec `WISQ_PC_SAMPLE`, on
            // avance par tranches d'un million d'instructions et l'on note le
            // RIP où chacune s'arrête, une ligne hexadécimale par tranche, dans
            // le fichier nommé. Avec `nokaslr` et le `System.map` de l'image,
            // les adresses du noyau se lisent en noms de fonctions.
            //
            // **Écrits au fil de la course**, par paquets de mille. Écrits à
            // la fin seulement, ils ont été perdus : un profil d'Ubuntu de deux
            // heures a été arrêté avant la fin, et il n'en restait rien.
            let sampleFile = environment["WISQ_PC_SAMPLE"].flatMap { path -> FileHandle? in
                FileManager.default.createFile(atPath: path, contents: nil)
                return FileHandle(forWritingAtPath: path)
            }
            var samples: [String] = []
            func flushSamples() {
                guard let sampleFile, !samples.isEmpty else { return }
                sampleFile.write(Data((samples.joined(separator: "\n") + "\n").utf8))
                samples.removeAll(keepingCapacity: true)
            }
            defer { flushSamples(); try? sampleFile?.close() }
            // **La console aussi, au fil de la course**, avec
            // `WISQ_PC_CONSOLE` : ce que le port série a écrit depuis la
            // tranche précédente, ajouté au fichier nommé. Le démarrage de
            // Fedora en journal de débogage a passé ses deux heures, et la
            // console, qui ne s'imprime qu'à la fin, a été perdue entière.
            let consoleFile = environment["WISQ_PC_CONSOLE"].flatMap { path -> FileHandle? in
                FileManager.default.createFile(atPath: path, contents: nil)
                return FileHandle(forWritingAtPath: path)
            }
            var consoleWritten = 0
            func flushConsole() {
                guard let consoleFile, core.serialOutput.count > consoleWritten else { return }
                consoleFile.write(Data(core.serialOutput.dropFirst(consoleWritten)))
                consoleWritten = core.serialOutput.count
            }
            defer { flushConsole(); try? consoleFile?.close() }
            let slice: UInt64 = sampleFile == nil ? 50_000_000 : 1_000_000
            while remaining > 0 {
                let executed = try core.run(budget: min(remaining, slice), waiting: patient)
                if sampleFile != nil {
                    samples.append(String(core.rip, radix: 16))
                    if samples.count >= 1000 { flushSamples() }
                }
                remaining -= min(remaining, max(executed, 1))
                flushConsole()
                let fresh = Self.withoutEscapes(String(decoding: core.serialOutput.dropFirst(answeredUpTo),
                                                       as: UTF8.self))
                let prompted = Self.prompts.contains(where: { fresh.contains($0) })
                if prompted, !toType.isEmpty, promptSeen || core.outOfPatience {
                    let line = toType.removeFirst()
                    typed.append(line)
                    core.serialInput.append(contentsOf: Array((line + "\n").utf8))
                    answeredUpTo = core.serialOutput.count
                    promptSeen = false
                    continue
                }
                promptSeen = prompted
                if core.outOfPatience { break }
            }
        } catch {
            stopped = error
        }

        let serial = String(decoding: core.serialOutput, as: UTF8.self)

        // Ce qu'on a gardé, et ce qu'on a vu : les trois témoins ne retiennent
        // que les derniers cas, et leur nombre vaudrait sinon leur plafond.
        let unmatched = Self.kept(core.unmatchedReturns.count,
                                  of: core.unmatchedReturnTally)
        let brokenSaid = Self.kept(core.brokenReturns.count,
                                   of: core.brokenReturnTally)
        let started = Self.kept(core.processStarts.count, of: core.processStartsSeen)
        // **Un `hlt` a deux fins, et elles ne se lisent pas pareil.** Le
        // programme qui attend une interruption qui viendra, et celui qui en
        // attend une qui ne viendra jamais — horloge non armée, ou
        // interruptions masquées. Sans ces deux faits, « arrêt : hlt » se lit
        // comme « la machine dort », alors que c'est peut-être « la machine
        // est morte et personne ne le dit ».
        let clock = core.devices.reload != 0
            ? "horloge armée (rechargement \(core.devices.reload))"
            : "horloge NON armée"
        let masked = core.flags & X86Core.Flag.interrupt != 0
            ? "interruptions permises" : "interruptions MASQUÉES"
        // **Et « hlt » n'est pas une raison d'arrêt.** Le champ disait « hlt »
        // dès que le cœur était au repos, quelle que soit la vraie cause — et
        // il a menti dans la mesure d'après : la machine attendait, horloge
        // armée et interruptions permises, et c'est le **budget** qui s'est
        // épuisé pendant l'attente. « La machine dort » et « la course s'est
        // arrêtée » ne sont pas la même phrase.
        let ending: String
        if let stopped {
            ending = "\(stopped)"
        } else if core.outOfPatience {
            ending = "attente épuisée (la machine patientait encore)"
        } else if core.halted && core.idled > 0 {
            ending = "budget épuisé pendant l'attente"
        } else if core.halted {
            ending = "hlt sans réveil possible"
        } else {
            ending = "budget épuisé en exécutant"
        }
        // **Quatre conditions séparent un battement d'une interruption
        // livrée**, et « la machine attend encore » ne dit pas laquelle a
        // manqué. Il faut un battement dû, le drapeau d'interruption levé, la
        // ligne non masquée, et une porte que l'IDT porte. Le rapport les
        // donne toutes les quatre plutôt que de laisser deviner.
        let pic = core.devices.primary
        let due = core.devices.expirations(at: core.ticks)
        let pending = pic.request & ~pic.mask
        let controller = "battements dus \(due), levés \(core.devices.raised)"
            + String(format: ", demande %02x, masque %02x, service %02x,"
                     + " base de vecteur %02x", pic.request, pic.mask,
                     pic.service, pic.vectorBase)
            // Le suffixe ne vaut que si une ligne demande : sans demande, il
            // n'y a rien à masquer, et le dire ferait accuser le masque quand
            // c'est l'horloge qui n'a pas encore battu.
            + (pic.request != 0 && pending == 0 ? " — RIEN NE PASSE LE MASQUE" : "")
        let halt = core.halted
            ? clock + ", " + masked + ", \(core.idled) tours d'attente"
            : "non"
        let lost = Self.kept(core.lostJumps.count, of: core.lostJumpsUnresolved)
            + " non résolus, sur \(core.lostJumpTally) sauts vers une page absente"

        // Le rapport sort **section par section**, et pas d'un seul `print`.
        //
        // Il l'a été, et il se faisait couper à seize kilo-octets pile : la
        // liste des appels indirects s'arrêtait au milieu d'une ligne et tout
        // ce qui la suivait — les passages d'anneau, les retours, les
        // programmes démarrés, les adresses non canoniques — disparaissait
        // sans un mot. Un rapport tronqué se lit exactement comme un rapport
        // vide, et c'est la sixième fois aujourd'hui qu'un instrument dit
        // « rien » quand il veut dire « je n'ai pas pu parler ».
        //
        // Le résumé passe donc en tête : quoi qu'il arrive aux listes, les
        // nombres, eux, sortent.
        func say(_ text: String) { print(text) }

        say("""

            === tentative de démarrage x86-64 ===
            instructions retirées : \(core.retired)
            arrêt                 : \(ending)
            rip                   : 0x\(String(core.rip, radix: 16))
            au repos              : \(halt)
            contrôleur            : \(controller)
            octets à RIP          : \(core.memory.map {
                (try? $0.read(core.rip, 8)).map { String($0, radix: 16) } ?? "?"
            } ?? "?")
            port série            : \(core.serialOutput.count) octets
            appels par la mémoire : \(core.indirectCalls.count) distincts
            passages d'anneau     : \(core.ringPassages.description)
            retours sans promesse : \(unmatched)
            retours rompus        : \(brokenSaid)
            programmes démarrés   : \(started)
            sauts dans le vide    : \(lost)
            adresses non canoniques : \(core.nonCanonicalSeen.count)
            fils vus              : \(core.threadActivity.count)
            dialogue              : \(typed.isEmpty ? "rien tapé" : typed.joined(separator: " | "))
            cache de décodage     : \(core.decodeCacheHits) trouvées, \(core.decodeCache.misses) décodées
            bus PCI               : \(core.memory?.bus.map {
                String(format: "fenêtre %04x, commande %04x, ligne %d",
                       $0.window, $0.command, $0.interruptLine)
            } ?? "aucun")
            disque                : \(core.memory?.storage.map {
                "\($0.sectors) secteurs, \($0.served) requêtes servies,"
                    + " \($0.refused) refusées, état \($0.status)"
            } ?? "aucun")
            second disque         : \(core.memory?.bus?.second.map { host in
                host.storage.map {
                    "\($0.sectors) secteurs, \($0.served) requêtes servies,"
                        + " \($0.refused) refusées, état \($0.status), ligne \(host.interruptLine)"
                } ?? "vide"
            } ?? "aucun")
            réseau                : \(core.memory?.bus?.network?.nic.map { nic in
                "\(nic.transmitted) trames envoyées (\(cable?.sent ?? 0) au câble), état \(nic.status)"
            } ?? "aucun")
            """)

        func list(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            say("\n\(title) :")
            // Par paquets : un seul écrit trop gros se fait couper.
            for start in stride(from: 0, to: lines.count, by: 32) {
                say(lines[start..<min(start + 32, lines.count)]
                    .map { "  " + $0 }.joined(separator: "\n"))
            }
        }

        list("appels par la mémoire", core.indirectCalls.map { $0.description })
        list("passages d'anneau qui décalent la pile",
             core.tripsShifted.map { $0.description })
        list("retours sans promesse", core.returnsUnmatched.map { $0.description })
        list("passages sur l'adresse surveillée",
             core.addressTouched.filter { $0.retired != 0 }.map { $0.description })
        say("mouvements de pile gardés : \(core.stackMoves.count)")
        list("retours rompus", core.returnsBroken.map { $0.description })
        list("sauts dans le vide", core.jumpsLost.map { $0.description })
        list("programmes démarrés", core.processesStarted.map { $0.description })
        // Qui tourne et qui attend quoi : le plus récemment actif en premier.
        list("fils, du plus récent au plus ancien",
             core.threadsByLastActivity.map { $0.description })
        list("adresses non canoniques", core.nonCanonicalSeen.map { $0.description })
        if !serial.isEmpty { say("\n" + serial) }
        say("\n=====================================\n")

        XCTAssertGreaterThan(core.retired, 0, "au moins une instruction doit s'exécuter")
        // Avec le budget entier, la bannière est un **contrat** : c'est la
        // preuve que le noyau s'est décompressé, qu'il est entré dans son
        // espace d'adressage et qu'il parle. Avec un budget réduit à la main,
        // ce n'en est plus un, et l'exiger serait un test qui ment.
        guard ProcessInfo.processInfo.environment["WISQ_PC_BUDGET"] == nil else { return }
        XCTAssertTrue(serial.contains("Linux version"),
                      "le noyau doit écrire sa bannière sur le port série")
        XCTAssertTrue(serial.contains("console [ttyS0] enabled"),
                      "et aller jusqu'à ouvrir sa console")
        XCTAssertTrue(serial.contains("processors activated"),
                      "et activer son processeur, ce qui demande une horloge")

        // **Deux fins différentes, parce que ce sont deux machines
        // différentes.** Sans disque en mémoire, un noyau panique faute de
        // racine, et c'est la bonne fin. Avec, il en a une : exiger la même
        // phrase serait exiger qu'un mécanisme qui marche échoue quand même —
        // et cette assertion-là était bel et bien écrite ainsi, donc ce test
        // ne pouvait pas passer dans la configuration où il va le plus loin.
        guard ramdisk != nil else {
            XCTAssertTrue(serial.contains("Unable to mount root fs"),
                          "sans disque, c'est la seule chose qui manque")
            return
        }
        XCTAssertTrue(serial.contains("Freeing initrd memory"),
                      "avec un disque en mémoire, le noyau doit le déballer et le rendre")
        // **Jusqu'au bout, comme la référence.** Sur les mêmes images, QEMU
        // imprime « Mounting boot media: failed. » douze secondes après avoir
        // commencé à chercher, puis lance le shell de secours de l'initramfs.
        // C'est ce que cette machine doit faire aussi, et c'est la phrase qui
        // dit qu'elle se comporte comme la référence jusqu'au bout — avant
        // d'investir dans un disque. Trois défauts l'en empêchaient : RDTSC
        // figé pendant le sommeil, un port série que le pilote 8250 ne
        // trouvait pas, et un XADD qui doublait sa destination quand son
        // écriture fautait sur une page copiée par fork().
        XCTAssertTrue(serial.contains("Mounting boot media: failed."),
                      "l'init doit renoncer au média de démarrage, comme QEMU")
        XCTAssertTrue(serial.contains("initramfs emergency recovery shell launched"),
                      "et lancer son shell de secours, comme QEMU")

        // **Et le shell écoute.** Une console qui écrit sans lire n'est qu'un
        // journal ; celle-ci prend les frappes qu'on lui donne et répond. La
        // réponse est exigée seulement quand personne n'a demandé autre chose :
        // avec `WISQ_PC_INPUT`, ce qui revient n'est pas connu d'avance.
        guard ProcessInfo.processInfo.environment["WISQ_PC_INPUT"] == nil else { return }
        XCTAssertEqual(typed, [Self.greeting], "la ligne doit avoir été tapée")
        // Deux fois plutôt qu'une : l'écho du terminal, puis la réponse du
        // shell. Une seule voudrait dire que la frappe est arrivée sans être
        // comprise — ou l'inverse.
        let answers = serial.components(separatedBy: "wisq-parle").count - 1
        XCTAssertGreaterThanOrEqual(answers, 2,
                                    "le shell doit renvoyer la frappe, puis y répondre")
        // **Ce qui remplace « on s'arrête en anneau trois ».** Cette
        // assertion-là tenait tant que le cœur s'arrêtait *pendant* que le
        // programme tournait ; depuis que plus aucun opcode ne manque, la
        // course va plus loin et finit dans le noyau — donc en anneau zéro.
        // Ce qu'il faut exiger n'est pas où l'on s'arrête, c'est que l'espace
        // utilisateur ait bien été atteint, et le noyau le dit lui-même.
        XCTAssertTrue(serial.contains("Run /init as init process"),
                      "et passer la main à un programme")
    }
}

/// L'autre bout d'une carte réseau de banc : il compte ce qu'on lui envoie et
/// ne répond jamais.
final class CountingCable: NetworkBackend {
    var sent = 0
    func send(_ frame: [UInt8]) { sent += 1 }
    func receive() -> [[UInt8]] { [] }
}

