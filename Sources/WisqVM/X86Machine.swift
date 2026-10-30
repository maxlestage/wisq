import Foundation

/// Une machine PC complète, dans le téléphone : de la mémoire, un cœur
/// x86-64, un port série 16550, un couple de 8259 et un 8253.
///
/// C'est le pendant de `LinuxMachine`, qui fait la même chose pour le RISC-V.
/// Les deux ont la même forme — charger, tourner, taper, arrêter — parce que
/// c'est l'application qui choisit laquelle selon le fichier qu'on lui donne,
/// et qu'elle n'a pas à connaître la différence.
///
/// **Ce qu'elle démarre vraiment.** Le vrai noyau d'Alpine 3.20 va jusqu'à
/// `kernel_init` : il se décompresse, entre dans son espace d'adressage,
/// trouve son horloge, initialise VFS, le réseau et PCI, déballe l'initramfs
/// et exécute `/init` en anneau trois. Voir `X86BootAttemptTests`, qui l'exige
/// à chaque exécution.
///
/// **L'instantané, et ce qu'il pèse vraiment.** La RAM d'une machine PC fait
/// deux cent cinquante-six mébioctets là où celle du RISC-V en fait
/// soixante-quatre, et la recopier telle quelle à chaque passage en
/// arrière-plan serait déraisonnable sur un téléphone. **Mesuré plutôt que
/// supposé** : après un démarrage complet d'Alpine — trois milliards et demi
/// d'instructions, jusqu'à `kernel_init` —, **14 471 pages sur 65 536 ne sont
/// pas entièrement nulles**, soit 22 %. Le format d'instantané de ce dépôt
/// code déjà les suites de zéros par leur longueur ; il n'y avait donc rien à
/// inventer, seulement à s'en servir.
public final class X86Machine: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        /// L'invité s'est arrêté lui-même, et plus rien ne peut le réveiller.
        case powerOff
        /// Quelqu'un a demandé l'arrêt, ou le budget s'est épuisé.
        case stopped
        /// Le cœur a refusé quelque chose. Nommé, parce qu'un arrêt sans nom
        /// envoie chercher partout.
        case faulted(String)
    }

    /// La mémoire par défaut.
    ///
    /// **Mesurée, pas choisie.** C'est ce avec quoi le noyau d'Alpine va
    /// jusqu'au bout : il annonce lui-même « Memory: 218360K/261752K
    /// available » et ne se plaint de rien. En dessous de cent vingt-huit
    /// mébioctets il n'a plus la place de se décompresser — le noyau
    /// décompressé fait à lui seul trente-cinq mébioctets.
    public static let defaultRAMSize = 256 << 20
    /// Le plancher, pour la même raison : `init_size` du noyau plus l'image
    /// décompressée plus de quoi travailler.
    public static let minimumRAMSize = 128 << 20

    public let ramSize: Int
    /// Interne plutôt que privée : un test doit pouvoir vérifier qu'une
    /// écriture invitée atteint bien l'écran, et sans ça la garde de routage
    /// ne serait tenue par rien — mesuré, un sabotage passait.
    let memory: X86Memory
    /// L'état du cœur.
    ///
    /// Visible dans le module plutôt que privé, pour que les tests puissent
    /// vérifier **champ par champ** ce qu'un instantané rend — et pas
    /// seulement que deux instantanés se ressemblent. Deux instantanés d'un
    /// champ oublié se ressemblent parfaitement.
    var core: X86Core
    private let onOutput: @Sendable (Data) -> Void

    /// Le disque, quand il y en a un.
    ///
    /// **Il n'était nulle part.** Le périphérique virtio et le bus PCI
    /// existaient et fonctionnaient — mesuré : le noyau d'Alpine énumère
    /// `[1af4:1001]`, charge `virtio_blk`, annonce « [vda] 32768 512-byte
    /// logical blocks », et le `md5sum` de `/dev/vda` dans l'invité est celui
    /// de l'image sur l'hôte. Mais rien de tout ça ne passait par
    /// `X86Machine` : seule la mesure de démarrage les branchait à la main.
    public private(set) var disk: VirtioBlock?

    /// Brancher un disque. Deux portes vers la même image : le transport MMIO
    /// répond aux adresses, le bus PCI aux ports. Le noyau d'Alpine passe par
    /// le second — son `virtio_mmio` est compilé sans les périphériques de la
    /// ligne de commande — mais un noyau qui les a saura passer par le premier.
    public func attach(disk image: [UInt8]) {
        attach(device: VirtioBlock(image: image))
    }

    /// Le même disque, lu depuis un fichier, avec sa couche d'écriture à
    /// côté — voir `FileDiskStore`.
    public func attach(diskFileAt base: URL, writes: URL) throws {
        attach(device: VirtioBlock(store: try FileDiskStore(base: base, writes: writes)))
    }

    private func attach(device: VirtioBlock) {
        disk = device
        memory.storage = device
        let bus = X86PCIHost(storage: device)
        bus.second = memory.bus?.second
        bus.network = memory.bus?.network
        memory.bus = bus
    }

    /// Le second disque, quand il y en a un — `/dev/vdb` pour le noyau.
    public private(set) var secondDisk: VirtioBlock?

    /// Brancher un second disque, lu sur place lui aussi.
    ///
    /// **Par le bus PCI seulement.** La fenêtre MMIO est celle du premier et
    /// n'a jamais été trouvée par le noyau d'Alpine — voir `X86PCIHost` —, et
    /// lui en ouvrir une seconde serait poser une porte que personne ne prend.
    /// L'ordre de branchement est libre : chacun garde l'autre.
    public func attach(secondDiskFileAt base: URL, writes: URL) throws {
        attach(second: VirtioBlock(store: try FileDiskStore(base: base, writes: writes)))
    }

    /// Le même, en mémoire — la forme des tests.
    public func attach(secondDisk image: [UInt8]) {
        attach(second: VirtioBlock(image: image))
    }

    private func attach(second device: VirtioBlock) {
        secondDisk = device
        let bus = memory.bus ?? X86PCIHost(storage: nil)
        bus.second = X86PCIHost(secondStorage: device)
        memory.bus = bus
    }

    /// La carte réseau, quand il y en a une — `eth0` pour le noyau.
    public private(set) var network: VirtioNet?

    /// **Brancher une carte réseau**, sur l'emplacement cinq du bus. Ce qui en
    /// fait un réseau est `backend` ; sans lui, la carte est un câble
    /// débranché. L'ordre de branchement avec les disques est libre.
    public func attach(network nic: VirtioNet) {
        network = nic
        let bus = memory.bus ?? X86PCIHost(storage: nil)
        bus.network = X86PCIHost(network: nic)
        memory.bus = bus
    }

    /// **Relayer un port de l'hôte vers l'invité**, quand la carte est branchée
    /// sur le réseau en mode utilisateur : voir `HostStreams.forward`. Rend le
    /// port qui écoute sur `127.0.0.1`, ou rien sans ce réseau.
    public func forward(hostPort: UInt16 = 0, toGuestPort guestPort: UInt16) throws -> UInt16? {
        guard let streams = (network?.backend as? UserNetwork)?.streams else { return nil }
        return try streams.forward(hostPort: hostPort, toGuestPort: guestPort)
    }

    /// Le retirer. Une machine reprise depuis un instantané sans disque n'en a
    /// pas, même si celle qu'on reprend en avait un.
    public func detachDisk() {
        disk = nil
        secondDisk = nil
        memory.storage = nil
        // La carte réseau n'est pas un disque : elle reste.
        if let host = memory.bus?.network {
            let bus = X86PCIHost(storage: nil)
            bus.network = host
            memory.bus = bus
        } else {
            memory.bus = nil
        }
    }

    private let lock = NSLock()
    private var stopRequested = false
    /// Ce qui réveille un `run()` qui dort : une frappe, ou un arrêt demandé.
    private let nudge = DispatchSemaphore(value: 0)

    /// **Dormir quand l'invité dort**, au rythme de l'horloge murale.
    ///
    /// Une machine endormie saute jusqu'au prochain battement du 8253 (voir
    /// `X86Core.idleStep`) : son temps à elle avance alors bien plus vite
    /// que celui de la personne qui la regarde, et la boucle tourne à plein
    /// régime pour livrer des battements que personne n'attend. Un `sleep 10`
    /// finissait en quelques millisecondes, l'heure de l'invité filait, et un
    /// téléphone chauffait devant une invite immobile.
    ///
    /// Avec ce réglage, quand l'invité est arrêté sur `HLT` et que son temps a
    /// pris de l'avance sur l'horloge murale, le fil d'émulation **dort**
    /// l'écart — par tranches d'au plus un dixième de seconde, et une frappe
    /// ou un arrêt le réveillent tout de suite. Un invité qui travaille n'est
    /// jamais ralenti : son temps est en retard, pas en avance.
    ///
    /// Éteint par défaut : les tests et les bancs veulent aller aussi vite
    /// que l'hôte le permet. L'application l'allume.
    public var pacesIdleToWallClock = false

    /// Combien d'instructions vaut une seconde de l'invité.
    var guestHertz: Double { Double(core.instructionsPerTick) * 1_193_182 }
    private var inputQueue: [UInt8] = []
    /// Les touches et les mouvements envoyés par l'hôte, en attente du
    /// prochain tour — sous le même verrou que `inputQueue`.
    private var pointerQueue: [PS2Event] = []

    enum PS2Event {
        case key(X86ScanCode, down: Bool)
        case mouse(dx: Int, dy: Int, buttons: UInt8)
    }
    private var pendingOutput: [UInt8] = []
    private var published = GuestProgress(retired: 0, rip: 0)

    /// **Où en est la machine, lisible pendant qu'elle tourne.**
    ///
    /// Ce que `retiredInstructions` rend est le compteur lui-même, et il n'est
    /// lisible que quand la machine est à l'arrêt : le fil d'émulation l'écrit
    /// à chaque instruction, et le lire d'ailleurs serait une course. Tous ses
    /// appelants sont d'ailleurs des tests, un banc, et un instantané — jamais
    /// une vue.
    ///
    /// Celui-ci est **publié** par le fil d'émulation, sous le verrou qui
    /// porte déjà l'arrêt et l'entrée clavier, sur la cadence de vidage de la
    /// console. Il est donc en retard d'au plus une poignée de tranches, ce
    /// qui est exactement ce qu'il faut pour une ligne d'état.
    ///
    /// **Jamais `nil` ici** : ce cœur publie. Le type l'autorise pour les cœurs
    /// qui ne le font pas encore, et qui doivent alors faire taire la ligne
    /// d'état plutôt que la remplir d'un zéro qui se lirait « rien n'a tourné ».
    public var liveProgress: GuestProgress? {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    /// **Où l'écran se pose, et pourquoi là.**
    ///
    /// 0xE0000000 : le trou que les PC réservent depuis toujours aux
    /// périphériques, sous les quatre gibioctets. Le choisir évite d'inventer
    /// une carte mémoire qui ne ressemblerait à aucune machine réelle — un
    /// noyau qui voit un cadre là n'est pas surpris.
    public static let displayBase: UInt64 = 0xE000_0000

    /// Ce qu'une machine refuse quand on lui demande un écran impossible.
    public enum DisplayRefusal: Error, Equatable {
        /// La RAM monte jusqu'à la fenêtre du cadre, ou plus haut. Les deux se
        /// recouvriraient, et l'écriture d'un pixel écraserait une page du
        /// noyau. **Refuser plutôt que déplacer en silence** : mettre le cadre
        /// au-dessus des quatre gibioctets demande `ext_lfb_base`, un champ
        /// que le chargeur n'écrit pas encore.
        case wouldOverlapMemory
    }

    /// L'écran de cette machine, quand elle en a un. C'est par là que l'hôte
    /// lit les pixels.
    public private(set) var display: X86Framebuffer?

    /// **Donner un écran à la machine.** À appeler avant `load` : c'est le
    /// chargeur qui l'annonce au noyau, et il ne le fait qu'une fois.
    public func attachDisplay(width: Int, height: Int) throws {
        // Avec le trou, l'écran tombe dedans quelle que soit la RAM.
        guard memory.ramRanges.count == 2 || UInt64(ramSize) <= Self.displayBase else {
            throw DisplayRefusal.wouldOverlapMemory
        }
        let screen = X86Framebuffer(base: Self.displayBase, width: width, height: height)
        memory.screen = screen
        display = screen
    }

    /// La page zéro telle qu'elle a été posée. Pour un test, et pour dire ce
    /// que le noyau va lire.
    public func bootParameters() -> [UInt8] {
        guard let at = bootParametersAddress else { return [] }
        return memory.dump(at, X86BootLoader.bootParametersSize)
    }

    private var bootParametersAddress: UInt64?

    public init(ramSize: Int = X86Machine.defaultRAMSize,
                onOutput: @escaping @Sendable (Data) -> Void) {
        self.ramSize = max(ramSize, Self.minimumRAMSize)
        self.onOutput = onOutput
        memory = X86Memory.pc(ram: self.ramSize)
        core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0, memory: memory)
    }

    /// Où la pagination d'identité est posée : hors du chemin du noyau, qui
    /// commence à seize mébioctets, et hors de la page zéro.
    static let pageTableRoot: UInt64 = 0x5_0000
    /// La pile du démarrage, sous le premier mébioctet et au-dessus de la page
    /// zéro et de la ligne de commande.
    static let bootStack: UInt64 = 0x9_0000

    /// Charge un noyau, et éventuellement un disque en mémoire.
    ///
    /// Le disque n'est pas un luxe : le noyau d'une distribution n'a **aucun**
    /// pilote de disque compilé dedans — ce sont des modules, et ils vivent
    /// justement dans l'initramfs. Sans lui, le noyau démarre entièrement puis
    /// panique faute de racine à monter.
    public func load(kernelImage: Data, commandLine: String? = nil,
                     initialRamdisk: Data? = nil) throws {
        let placement = try X86BootLoader.load(
            kernel: [UInt8](kernelImage), into: memory,
            commandLine: Self.commandLine(commandLine ?? X86BootLoader.defaultCommandLine,
                                          withScreen: display != nil),
            initialRamdisk: initialRamdisk.map { [UInt8]($0) },
            framebuffer: display.map {
                X86BootLoader.Framebuffer(base: $0.base, width: $0.width, height: $0.height)
            })
        bootParametersAddress = placement.bootParametersAddress

        // Quatre entrées de un gibioctet suffisent à couvrir les quatre
        // premiers, là où des pages de quatre kibioctets en demanderaient un
        // million. Le noyau posera les siennes dès qu'il en aura besoin.
        let directory = Self.pageTableRoot + 0x1000
        try memory.write(Self.pageTableRoot, 8, directory | X86Core.present | 0x2)
        for gigabyte in 0..<4 {
            try memory.write(directory + UInt64(gigabyte) * 8, 8,
                             UInt64(gigabyte) << 30 | X86Core.present | X86Core.hugePage | 0x2)
        }

        core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                       rip: placement.entryPoint, memory: memory)
        // Ce que le protocole de démarrage 64 bits exige à l'entrée : le mode
        // long actif, la pagination en place, et RSI sur la page zéro.
        core.system.control[3] = Self.pageTableRoot
        core.system.control[4] = X86SystemState.physicalAddressExtension
        core.system.modelSpecific[X86SystemState.efer] = X86SystemState.longModeEnable
        core.system.control[0] = X86SystemState.paging | X86SystemState.protectedMode
        core.system.refreshLongMode()
        core.pagingActive = true
        core.registers[6] = placement.bootParametersAddress
        core.registers[4] = Self.bootStack
    }

    /// Fait tourner l'invité jusqu'à ce qu'il s'arrête, qu'on le lui demande,
    /// ou que le budget s'épuise.
    @discardableResult
    public func run(instructionBudget: UInt64 = .max) -> Outcome {
        let slice: UInt64 = 200_000
        // **Le budget compte le temps, pas seulement le travail.** Un
        // processeur arrêté sur un `HLT` ne retire aucune instruction : ne
        // compter que celles-là ferait tourner cette boucle sans fin autour
        // d'un invité qui dort, sur un téléphone, sans qu'aucun budget puisse
        // l'arrêter. `idled` est l'autre moitié de l'horloge, et il compte ici.
        let start = core.retired &+ core.idled
        let wallStart = DispatchTime.now().uptimeNanoseconds
        var slicesSinceFlush = 0

        while (core.retired &+ core.idled) &- start < instructionBudget {
            lock.lock()
            let stopped = stopRequested
            if !inputQueue.isEmpty {
                core.serialInput.append(contentsOf: inputQueue)
                inputQueue.removeAll()
            }
            for event in pointerQueue {
                switch event {
                case .key(let code, let down): core.devices.ps2.key(code, down: down)
                case .mouse(let dx, let dy, let buttons): core.devices.ps2.mouse(dx: dx, dy: dy, buttons: buttons)
                }
            }
            pointerQueue.removeAll()
            lock.unlock()
            if stopped { flushOutput(); return .stopped }

            let remaining = instructionBudget &- ((core.retired &+ core.idled) &- start)
            let executed: UInt64
            do {
                executed = try core.run(budget: min(slice, remaining))
            } catch {
                collectOutput()
                flushOutput()
                return .faulted("\(error)")
            }
            collectOutput()

            // Une invite se termine sans retour à la ligne ; sans un vidage
            // régulier elle resterait dans le tampon, et la console aurait
            // l'air figée au moment précis où elle attend une réponse.
            slicesSinceFlush += 1
            if slicesSinceFlush >= 4 {
                slicesSinceFlush = 0
                flushOutput()
            }

            // **Une tranche qui n'exécute rien veut dire que plus rien ne peut
            // arriver.** C'est le cas d'un `HLT` sans horloge armée, ou avec
            // les interruptions masquées : le cœur rend la main tout de suite,
            // et le rappeler ne changera rien.
            //
            // La garde porte sur le **progrès** et non sur `halted`, parce
            // qu'elle doit tenir aussi pour tout ce qui rendrait la main sans
            // avancer. La retirer ne fait pas échouer un test : elle fait
            // **pendre** la boucle, à plein régime, sur un invité qui a fini —
            // mesuré à dix minutes avant d'aller couper le courant.
            if executed == 0 {
                flushOutput()
                return .powerOff
            }
            if pacesIdleToWallClock && core.halted {
                let guest = Double((core.retired &+ core.idled) &- start) / guestHertz
                let wall = Double(DispatchTime.now().uptimeNanoseconds &- wallStart) / 1e9
                let ahead = guest - wall
                if ahead > 0.001 {
                    flushOutput()
                    // Les réveils déjà dus sont pris en compte par la tranche
                    // qui suit : on les vide avant de dormir.
                    while nudge.wait(timeout: .now()) == .success {}
                    _ = nudge.wait(timeout: .now() + min(ahead, 0.1))
                }
            }
        }
        flushOutput()
        return .stopped
    }

    /// Ce que l'invité a vraiment exécuté. Le temps passé dans un `HLT` n'y
    /// est pas : un processeur arrêté ne retire rien, et le compter
    /// flatterait un invité qui dort.
    public var retiredInstructions: UInt64 { core.retired }

    /// Demande à un `run()` en cours de rendre la main. Utilisable depuis
    /// n'importe quel fil.
    public func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
        nudge.signal()
    }

    /// Donne des octets tapés à l'UART de l'invité. Utilisable depuis
    /// n'importe quel fil.
    public func send(_ data: Data) {
        lock.lock()
        inputQueue.append(contentsOf: data)
        lock.unlock()
        nudge.signal()
    }

    /// **Avec un écran, le noyau y écrit aussi** : `console=tty0` en tête, pour
    /// que le dernier `console=` — la console série — reste `/dev/console`,
    /// celle que la console de l'application lit et où l'invité ouvre sa
    /// session. L'écran montre le démarrage et les terminaux virtuels.
    static func commandLine(_ line: String, withScreen: Bool) -> String {
        guard withScreen, !line.split(separator: " ").contains("console=tty0") else { return line }
        return "console=tty0 " + line
    }

    /// Une touche du clavier PS/2 de l'invité, enfoncée ou relâchée.
    /// Utilisable depuis n'importe quel fil.
    public func key(_ code: X86ScanCode, down: Bool) {
        lock.lock()
        pointerQueue.append(.key(code, down: down))
        lock.unlock()
        nudge.signal()
    }

    /// Un mouvement de la souris PS/2 de l'invité, Y vers le bas, et ses
    /// boutons : 1 gauche, 2 droit, 4 milieu. Utilisable depuis n'importe
    /// quel fil.
    public func mouse(dx: Int, dy: Int, buttons: UInt8) {
        lock.lock()
        pointerQueue.append(.mouse(dx: dx, dy: dy, buttons: buttons))
        lock.unlock()
        nudge.signal()
    }

    // MARK: - Sauver et rendre

    /// La machine entière en octets : les registres, l'état système, la pile
    /// x87 et les registres XMM, le contrôleur d'interruptions, l'horloge, ce
    /// qui attend d'être tapé, et la RAM.
    ///
    /// **Pas la sortie console** : elle est déjà partie au rappel et appartient
    /// à qui dessine le terminal, pas à la machine.
    ///
    /// **Pas le cache de traduction** non plus, et c'est délibéré : il se
    /// reconstruit tout seul au premier accès, et le sauver reviendrait à
    /// figer une réponse qu'on peut recalculer — avec le risque qu'elle mente
    /// si les tables ont bougé entre-temps.
    public func snapshot() -> Data {
        var writer = Snapshot.Writer()
        for index in 0..<16 { writer.u64(core.registers[index]) }
        writer.u64(core.flags)
        writer.u64(core.rip)
        writer.u64(core.retired)
        writer.u64(core.idled)
        writer.u64(core.halted ? 1 : 0)
        writer.u64(core.pagingActive ? 1 : 0)
        for index in 0..<16 { writer.u64(core.system.control[index]) }
        for index in 0..<8 { writer.u64(core.system.debug[index]) }
        // Les MSR sont un dictionnaire : leur nombre, puis les paires. Trié,
        // pour que deux instantanés de la même machine soient les mêmes octets.
        let registers = core.system.modelSpecific.sorted { $0.key < $1.key }
        writer.u64(UInt64(registers.count))
        for (number, value) in registers {
            writer.u32(number)
            writer.u64(value)
        }
        for index in 0..<6 { writer.u32(UInt32(core.segments[index])) }
        for index in 0..<2 {
            writer.u64(core.descriptorBases[index])
            writer.u64(core.descriptorLimits[index])
        }
        // Le registre de tâche. Sans lui, une machine reprise depuis un
        // instantané ne saurait plus où est la pile du noyau, et la première
        // interruption prise en anneau trois après la reprise s'arrêterait —
        // très loin de la reprise, et sans rapport visible avec elle.
        writer.u32(UInt32(core.taskSelector))
        writer.u64(core.taskBase)
        writer.u64(core.taskLimit)
        writer.u32(UInt32(core.x87Control))
        writer.u32(UInt32(core.x87Status))
        writer.u32(core.mxcsr)
        // Les seize registres XMM, deux mots chacun. Un programme qui tourne
        // en anneau trois en a le milieu d'une comparaison de chaîne à
        // l'instant où l'on passe en arrière-plan ; les perdre le ferait
        // repartir sur des octets qu'il croyait avoir lus.
        for word in core.vectors { writer.u64(word) }
        write(&writer, core.devices)
        lock.lock()
        let queued = core.serialInput + inputQueue
        lock.unlock()
        writer.blob(queued)
        writer.ram(UnsafeRawBufferPointer(start: memory.bytes, count: memory.size))
        // **La pile x87, derrière sa marque.** Le mot de contrôle, le mot
        // d'état et MXCSR sont écrits plus haut depuis toujours ; les huit
        // registres qu'ils décrivent et le mot d'étiquettes ne l'étaient pas.
        // Une machine reprise au milieu d'un calcul flottant revenait donc
        // avec un état qui annonce une pile, des étiquettes qui la disent
        // vide, et des registres à zéro — trois descriptions de la même pile,
        // toutes les trois en désaccord.
        //
        // Elle arrive **en queue et derrière une marque** plutôt qu'à sa place
        // naturelle, pour la raison qui a mis le disque là : des machines sont
        // déjà sauvées sur des téléphones, et déplacer un octet les perdrait.
        writer.u64(Snapshot.x87Section)
        for register in core.x87 {
            writer.u64(register.significand)
            writer.u32(UInt32(register.signExponent))
        }
        writer.u32(UInt32(core.x87Tags))
        // XCR0 et le haut des YMM, derrière leur marque : un noyau qui a
        // activé l'état étendu le retrouve activé, et un programme au milieu
        // d'un calcul sur 256 bits retrouve ses registres entiers.
        writer.u64(Snapshot.extendedStateSection)
        writer.u64(core.xcr0)
        for word in core.upperVectors { writer.u64(word) }
        // Le rapport de l'horloge, derrière sa marque : le 8253 et le noyau
        // comptent en battements, et un battement doit garder sa longueur.
        writer.u64(Snapshot.clockSection)
        writer.u64(core.instructionsPerTick)
        // **La carte réseau, derrière sa marque et avant les disques** : la
        // section du disque n'a pas de marque, elle se lit « s'il reste des
        // octets », et une carte écrite après elle serait prise pour un disque.
        if let network, let host = memory.bus?.network {
            writer.u64(Snapshot.networkSection)
            network.save(into: &writer)
            host.save(into: &writer)
        }
        // **Le disque en dernier, et seulement s'il y en a un.** Son absence
        // est ce qui distingue un instantané d'avant le disque, et la reprise
        // la lit comme « pas de disque » plutôt que comme un dégât — sinon les
        // machines déjà sauvées sur les téléphones seraient perdues.
        if let disk {
            disk.save(into: &writer)
            memory.bus?.save(into: &writer)
        }
        // **Le second disque, derrière sa marque et après le premier.** Les
        // instantanés d'avant s'arrêtent là où celui-ci commence, et la
        // reprise lit son absence comme « pas de second disque ». Il n'est
        // écrit qu'avec un premier : l'application branche toujours l'image
        // avant le disque d'installation, et un second sans premier n'aurait
        // aucune section derrière laquelle se ranger.
        if disk != nil, let second = secondDisk, let host = memory.bus?.second {
            writer.u64(Snapshot.secondDiskSection)
            second.save(into: &writer)
            host.save(into: &writer)
        }
        return Data(writer.bytes)
    }

    /// Reprend une machine sauvée. Tout ou rien : une lecture qui échoue
    /// laisse la machine telle qu'elle était plutôt qu'à moitié restaurée,
    /// parce qu'une machine à moitié restaurée est pire qu'une machine perdue.
    public func restore(_ data: Data) throws {
        var reader = try Snapshot.Reader([UInt8](data))
        var restored = try Self.readCore(&reader, memory: memory)
        // **La mémoire en dernier.** Elle s'écrivait ici, directement dans
        // celle de la machine, et une section abîmée plus loin faisait
        // refuser la reprise avec la mémoire déjà remplacée : une machine à
        // moitié reprise, exactement ce que la règle du « tout ou rien »
        // interdit. Une copie à part doublerait jusqu'à seize gibioctets ; on
        // lit donc la suite d'abord, sur un second lecteur qui passe la
        // mémoire en vérifiant les mêmes bornes, et on n'écrit qu'ensuite.
        var tail = reader
        try tail.skipRAM(count: memory.size)
        // La pile x87, si la marque est là. Son absence veut dire « un
        // instantané d'avant cette section », pas « un instantané abîmé » :
        // la machine garde alors la pile vide d'un départ, ce qu'elle faisait
        // déjà. Si la marque est là, ce qui suit doit tenir en entier — un
        // lecteur qui manque d'octets refuse plutôt que de rendre la moitié
        // d'une pile.
        if tail.peeks(Snapshot.x87Section) {
            _ = try tail.u64()
            for index in 0..<8 {
                let significand = try tail.u64()
                let signExponent = UInt16(truncatingIfNeeded: try tail.u32())
                restored.x87[index] = X86Extended(significand: significand,
                                                  signExponent: signExponent)
            }
            restored.x87Tags = UInt16(truncatingIfNeeded: try tail.u32())
        }
        // Absente : un instantané d'avant, où XCR0 valait x87 seul et le haut
        // des YMM n'existait pas — ce qu'une machine neuve a déjà.
        if tail.peeks(Snapshot.extendedStateSection) {
            _ = try tail.u64()
            let xcr0 = try tail.u64()
            guard xcr0 & 1 != 0, xcr0 & ~X86Core.supportedExtendedState == 0 else {
                throw Snapshot.Failure.corrupt
            }
            restored.xcr0 = xcr0
            for index in 0..<32 { restored.upperVectors[index] = try tail.u64() }
        }
        // Absente : un instantané d'avant, écrit quand le rapport valait
        // trente-six pour toutes les machines.
        if tail.peeks(Snapshot.clockSection) {
            _ = try tail.u64()
            let ratio = try tail.u64()
            guard (1...4096).contains(ratio) else { throw Snapshot.Failure.corrupt }
            restored.instructionsPerTick = ratio
        } else {
            restored.instructionsPerTick = X86LegacyDevices.legacyInstructionsPerTick
        }
        // La carte réseau, si sa marque est là, branchée sur l'autre bout
        // qu'a la machine qu'on reprend : le réseau n'est pas dans
        // l'instantané, il est autour.
        var restoredNetwork: VirtioNet?
        var restoredNetworkHost: X86PCIHost?
        if tail.peeks(Snapshot.networkSection) {
            _ = try tail.u64()
            let nic = try VirtioNet.restored(from: &tail, backend: network?.backend)
            let host = X86PCIHost(network: nic)
            try host.restore(from: &tail)
            restoredNetwork = nic
            restoredNetworkHost = host
        }
        // Le disque, s'il reste des octets. Construit à part et posé tout à la
        // fin : une lecture qui échoue ici laisse à la machine le disque
        // qu'elle avait, plutôt qu'un disque à moitié repris.
        var restoredDisk: VirtioBlock?
        var restoredBus: X86PCIHost?
        var restoredSecond: VirtioBlock?
        if !tail.isAtEnd {
            let device = try VirtioBlock.restored(from: &tail, keeping: disk?.store)
            let bus = X86PCIHost(storage: device)
            try bus.restore(from: &tail)
            restoredDisk = device
            restoredBus = bus
            // Le second, si sa marque est là — et alors en entier, ou rien.
            if tail.peeks(Snapshot.secondDiskSection) {
                _ = try tail.u64()
                let second = try VirtioBlock.restored(from: &tail, keeping: secondDisk?.store)
                let host = X86PCIHost(secondStorage: second)
                try host.restore(from: &tail)
                bus.second = host
                restoredSecond = second
            }
        }
        // Tout ce qui suit la mémoire a été lu et accepté : `skipRAM` a vu les
        // mêmes bornes, plus rien ne peut échouer.
        try reader.ram(UnsafeMutableRawBufferPointer(start: memory.bytes, count: memory.size))

        // **Pas de recalcul du mode long ici**, et c'est vérifié plutôt que
        // supposé. `pagingOn` et `longMode` se lisent dans CR0 et dans EFER,
        // qui viennent tous deux d'être restaurés tels quels : LMA est donc
        // déjà juste. L'appel qui était là au premier jet ne faisait rien —
        // aucun sabotage ne le faisait tomber, ce qui est la définition d'une
        // ligne que rien ne tient.

        lock.lock()
        inputQueue.removeAll()
        // `stopRequested` n'est **pas** remis à zéro : ce n'est pas l'état de
        // l'invité, c'est celui qui possède la machine qui lui demande de
        // rendre la main — et il a pu le demander pendant la reprise, que
        // l'application mène sur un autre fil. L'effacer faisait tourner la
        // machine tout son budget après l'ordre ; la suspension dépassait son
        // délai et effaçait la session qu'on venait de reprendre. C'est la
        // règle de `LinuxMachine.restore`.
        lock.unlock()
        disk = restoredDisk
        secondDisk = restoredSecond
        memory.storage = restoredDisk
        network = restoredNetwork
        if let restoredNetworkHost {
            let bus = restoredBus ?? X86PCIHost(storage: nil)
            bus.network = restoredNetworkHost
            memory.bus = bus
        } else {
            memory.bus = restoredBus
        }
        core = restored
    }

    /// **Ce qui précède la mémoire dans un instantané** : les registres, l'état
    /// du système et les périphériques. À part de `restore` pour que
    /// `savedRAMSize(in:)` lise exactement le même chemin jusqu'à la taille de
    /// la mémoire, plutôt qu'une copie qui finirait par en diverger.
    static func readCore(_ reader: inout Snapshot.Reader, memory: X86Memory) throws -> X86Core {
        var restored = X86Core(registers: [UInt64](repeating: 0, count: 16),
                               rip: 0, memory: memory)
        for index in 0..<16 { restored.registers[index] = try reader.u64() }
        restored.flags = try reader.u64()
        restored.rip = try reader.u64()
        restored.retired = try reader.u64()
        restored.idled = try reader.u64()
        restored.halted = try reader.u64() != 0
        restored.pagingActive = try reader.u64() != 0
        for index in 0..<16 { restored.system.control[index] = try reader.u64() }
        for index in 0..<8 { restored.system.debug[index] = try reader.u64() }
        let count = try reader.u64()
        guard count <= 4096 else { throw Snapshot.Failure.corrupt }
        for _ in 0..<count {
            let number = try reader.u32()
            restored.system.modelSpecific[number] = try reader.u64()
        }
        for index in 0..<6 {
            restored.segments[index] = UInt16(truncatingIfNeeded: try reader.u32())
        }
        for index in 0..<2 {
            restored.descriptorBases[index] = try reader.u64()
            restored.descriptorLimits[index] = try reader.u64()
        }
        restored.taskSelector = UInt16(truncatingIfNeeded: try reader.u32())
        restored.taskBase = try reader.u64()
        restored.taskLimit = try reader.u64()
        restored.x87Control = UInt16(truncatingIfNeeded: try reader.u32())
        restored.x87Status = UInt16(truncatingIfNeeded: try reader.u32())
        restored.mxcsr = try reader.u32()
        for index in 0..<32 { restored.vectors[index] = try reader.u64() }
        restored.devices = try read(&reader)
        restored.serialInput = try reader.blob()
        return restored
    }

    /// **La mémoire avec laquelle un instantané a été pris**, sans le
    /// reprendre. Une machine se construit avant de lire son instantané, et
    /// une machine d'une autre taille le refuse (`ramSizeMismatch`) : il faut
    /// donc le savoir avant, pour construire la bonne. `nil` quand ce n'est
    /// pas un instantané lisible.
    public static func savedRAMSize(in data: Data) -> Int? {
        guard var reader = try? Snapshot.Reader([UInt8](data)),
              (try? readCore(&reader, memory: X86Memory(size: 0x1000, base: 0))) != nil,
              let size = try? reader.u64() else { return nil }
        return Int(exactly: size)
    }

    private func write(_ writer: inout Snapshot.Writer, _ devices: X86LegacyDevices) {
        for controller in [devices.primary, devices.secondary] {
            writer.u32(UInt32(controller.mask))
            writer.u32(UInt32(controller.request))
            writer.u32(UInt32(controller.service))
            writer.u32(UInt32(controller.vectorBase))
            writer.u32(UInt32(controller.initialisationStep))
            writer.u32(controller.readsService ? 1 : 0)
        }
        // Le mode tient dans les bits libres au-dessus des seize du compte :
        // un instantané d'avant ce bit se relit en mode périodique, comme il
        // tournait.
        writer.u32(UInt32(devices.reload) | (devices.oneShot ? 1 << 16 : 0))
        writer.u32(devices.writeHighNext ? 1 : 0)
        writer.u32(devices.readHighNext ? 1 : 0)
        writer.u32(UInt32(devices.latched ?? 0))
        writer.u32(devices.latched == nil ? 0 : 1)
        writer.u64(devices.reloadedAt)
        writer.u64(devices.raised)
        writer.u32(UInt32(devices.speakerReload))
        writer.u32(devices.speakerWriteHighNext ? 1 : 0)
        writer.u32(devices.speakerReadHighNext ? 1 : 0)
        writer.u64(devices.speakerStartedAt)
        writer.u32(devices.speakerGate ? 1 : 0)
        // Le port série, tel que le pilote l'a programmé : sans lui, une
        // machine reprise aurait un terminal que le noyau croit configuré et
        // qui ne l'est plus — et l'émission n'interromprait plus jamais.
        writer.u32(UInt32(devices.serial.interruptEnable))
        writer.u32(UInt32(devices.serial.fifoControl))
        writer.u32(UInt32(devices.serial.lineControl))
        writer.u32(UInt32(devices.serial.modemControl))
        writer.u32(UInt32(devices.serial.scratch))
        writer.u32(UInt32(devices.serial.divisor))
        writer.u32(devices.serial.transmitPending ? 1 : 0)
    }

    private static func read(_ reader: inout Snapshot.Reader) throws -> X86LegacyDevices {
        var devices = X86LegacyDevices()
        for which in 0..<2 {
            var controller = X86LegacyDevices.Controller()
            controller.mask = UInt8(truncatingIfNeeded: try reader.u32())
            controller.request = UInt8(truncatingIfNeeded: try reader.u32())
            controller.service = UInt8(truncatingIfNeeded: try reader.u32())
            controller.vectorBase = UInt8(truncatingIfNeeded: try reader.u32())
            controller.initialisationStep = Int(try reader.u32())
            controller.readsService = try reader.u32() != 0
            if which == 0 { devices.primary = controller } else { devices.secondary = controller }
        }
        let reload = try reader.u32()
        devices.reload = UInt16(truncatingIfNeeded: reload)
        devices.oneShot = reload & (1 << 16) != 0
        devices.writeHighNext = try reader.u32() != 0
        devices.readHighNext = try reader.u32() != 0
        let latched = UInt16(truncatingIfNeeded: try reader.u32())
        devices.latched = try reader.u32() != 0 ? latched : nil
        devices.reloadedAt = try reader.u64()
        devices.raised = try reader.u64()
        devices.speakerReload = UInt16(truncatingIfNeeded: try reader.u32())
        devices.speakerWriteHighNext = try reader.u32() != 0
        devices.speakerReadHighNext = try reader.u32() != 0
        devices.speakerStartedAt = try reader.u64()
        devices.speakerGate = try reader.u32() != 0
        devices.serial.interruptEnable = UInt8(truncatingIfNeeded: try reader.u32())
        devices.serial.fifoControl = UInt8(truncatingIfNeeded: try reader.u32())
        devices.serial.lineControl = UInt8(truncatingIfNeeded: try reader.u32())
        devices.serial.modemControl = UInt8(truncatingIfNeeded: try reader.u32())
        devices.serial.scratch = UInt8(truncatingIfNeeded: try reader.u32())
        devices.serial.divisor = UInt16(truncatingIfNeeded: try reader.u32())
        devices.serial.transmitPending = try reader.u32() != 0
        return devices
    }

    private func collectOutput() {
        guard !core.serialOutput.isEmpty else { return }
        pendingOutput.append(contentsOf: core.serialOutput)
        core.serialOutput.removeAll(keepingCapacity: true)
    }

    private func flushOutput() {
        // **Avant la garde, et c'est tout l'enjeu.** Ce vidage rend la main
        // tout de suite quand il n'y a rien à écrire ; publier après la garde
        // ne dirait jamais rien de l'invité qui en a le plus besoin — celui
        // qui n'écrit plus. C'est précisément le cas qu'une capture a montré.
        lock.lock()
        published = GuestProgress(retired: core.retired, rip: core.rip)
        lock.unlock()
        collectOutput()
        guard !pendingOutput.isEmpty else { return }
        let data = Data(pendingOutput)
        pendingOutput.removeAll(keepingCapacity: true)
        onOutput(data)
    }
}
