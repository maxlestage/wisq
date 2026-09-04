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
    private let memory: X86Memory
    /// L'état du cœur.
    ///
    /// Visible dans le module plutôt que privé, pour que les tests puissent
    /// vérifier **champ par champ** ce qu'un instantané rend — et pas
    /// seulement que deux instantanés se ressemblent. Deux instantanés d'un
    /// champ oublié se ressemblent parfaitement.
    var core: X86Core
    private let onOutput: @Sendable (Data) -> Void

    private let lock = NSLock()
    private var stopRequested = false
    private var inputQueue: [UInt8] = []
    private var pendingOutput: [UInt8] = []

    public init(ramSize: Int = X86Machine.defaultRAMSize,
                onOutput: @escaping @Sendable (Data) -> Void) {
        self.ramSize = max(ramSize, Self.minimumRAMSize)
        self.onOutput = onOutput
        memory = X86Memory(size: self.ramSize, base: 0)
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
            commandLine: commandLine ?? X86BootLoader.defaultCommandLine,
            initialRamdisk: initialRamdisk.map { [UInt8]($0) })

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
        var slicesSinceFlush = 0

        while (core.retired &+ core.idled) &- start < instructionBudget {
            lock.lock()
            let stopped = stopRequested
            if !inputQueue.isEmpty {
                core.serialInput.append(contentsOf: inputQueue)
                inputQueue.removeAll()
            }
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
    }

    /// Donne des octets tapés à l'UART de l'invité. Utilisable depuis
    /// n'importe quel fil.
    public func send(_ data: Data) {
        lock.lock()
        inputQueue.append(contentsOf: data)
        lock.unlock()
    }

    // MARK: - Sauver et rendre

    /// La machine entière en octets : les registres, l'état système, le
    /// contrôleur d'interruptions, l'horloge, ce qui attend d'être tapé, et la
    /// RAM.
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
        writer.ram(UnsafeRawBufferPointer(start: memory.bytes, count: ramSize))
        return Data(writer.bytes)
    }

    /// Reprend une machine sauvée. Tout ou rien : une lecture qui échoue
    /// laisse la machine telle qu'elle était plutôt qu'à moitié restaurée,
    /// parce qu'une machine à moitié restaurée est pire qu'une machine perdue.
    public func restore(_ data: Data) throws {
        var reader = try Snapshot.Reader([UInt8](data))
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
        try reader.ram(UnsafeMutableRawBufferPointer(start: memory.bytes, count: ramSize))
        // **Pas de recalcul du mode long ici**, et c'est vérifié plutôt que
        // supposé. `pagingOn` et `longMode` se lisent dans CR0 et dans EFER,
        // qui viennent tous deux d'être restaurés tels quels : LMA est donc
        // déjà juste. L'appel qui était là au premier jet ne faisait rien —
        // aucun sabotage ne le faisait tomber, ce qui est la définition d'une
        // ligne que rien ne tient.

        lock.lock()
        inputQueue.removeAll()
        stopRequested = false
        lock.unlock()
        core = restored
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
        writer.u32(UInt32(devices.reload))
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
    }

    private func read(_ reader: inout Snapshot.Reader) throws -> X86LegacyDevices {
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
        devices.reload = UInt16(truncatingIfNeeded: try reader.u32())
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
        return devices
    }

    private func collectOutput() {
        guard !core.serialOutput.isEmpty else { return }
        pendingOutput.append(contentsOf: core.serialOutput)
        core.serialOutput.removeAll(keepingCapacity: true)
    }

    private func flushOutput() {
        collectOutput()
        guard !pendingOutput.isEmpty else { return }
        let data = Data(pendingOutput)
        pendingOutput.removeAll(keepingCapacity: true)
        onOutput(data)
    }
}
