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
/// **Ce qu'elle n'a pas encore.** Pas d'instantané : la RAM d'une machine PC
/// se compte en centaines de mébioctets là où celle du RISC-V en fait
/// soixante-quatre, et recopier ça à chaque passage en arrière-plan
/// demanderait une stratégie — pas une boucle. C'est écrit ici plutôt que
/// laissé à découvrir.
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
    private var core: X86Core
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
