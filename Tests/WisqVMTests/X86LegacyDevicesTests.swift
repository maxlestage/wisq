import XCTest

@testable import WisqVM

/// Le 8259 et le 8253, et le battement qui en sort.
///
/// Comme les briques du cœur, ils n'ont pas été choisis sur une liste : le
/// noyau d'Alpine s'arrêtait sur `Failed to register legacy timer interrupt`,
/// après avoir écrit `Using NULL legacy PIC`. Sa sonde du contrôleur avait
/// échoué, donc il n'avait personne à qui demander l'interruption zéro.
final class X86LegacyDevicesTests: XCTestCase {
    static let handler: UInt64 = 0x8000
    static let idt: UInt64 = 0x9000

    static func core(_ ram: X86Memory, _ code: [UInt8]) throws -> X86Core {
        try ram.load(code, at: 0x100)
        try ram.load([0xF4], at: handler)
        // Une porte pour le vecteur 0x30, celui de la ligne zéro chez Linux.
        let target = handler
        let low = (target & 0xFFFF) | (UInt64(0x10) << 16)
            | (UInt64(0x8E) << 40) | ((target & 0xFFFF_0000) << 32)
        try ram.write(idt &+ 0x30 * 16, 8, low)
        try ram.write(idt &+ 0x30 * 16 &+ 8, 8, 0)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x100, memory: ram)
        core.descriptorBases[1] = idt
        core.descriptorLimits[1] = 0xFFF
        core.registers[4] = 0x7000
        return core
    }

    /// Une horloge armée : la ligne zéro n'est pas masquée, le vecteur est
    /// celui de Linux, et le canal zéro déborde souvent.
    static func armed(_ core: inout X86Core) {
        core.devices.primary.mask = 0xFE
        core.devices.primary.vectorBase = 0x30
        core.devices.reload = 2
        core.flags |= X86Core.Flag.interrupt
    }

    // MARK: - Le 8259

    /// **Toute la sonde de Linux tient en deux lignes** : écrire une valeur
    /// dans le port 0x21 et la relire. Si elle ne revient pas, il conclut qu'il
    /// n'y a pas de contrôleur — c'est le message `Using NULL legacy PIC` — et
    /// n'a plus personne à qui demander l'interruption zéro.
    func testTheMaskComesBackFromThePortItWasWrittenTo() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // `b0 ff` mov $0xff,%al ; `e6 21` out %al,$0x21 ; `e4 21` in $0x21,%al
        // puis la même chose avec 0xfb, la valeur que la sonde essaie ensuite.
        var core = try Self.core(ram, [
            0xB0, 0xFF, 0xE6, 0x21, 0xE4, 0x21, 0x88, 0xC3,
            0xB0, 0xFB, 0xE6, 0x21, 0xE4, 0x21,
        ])
        try core.run(budget: 8)
        XCTAssertEqual(core.registers[3] & 0xFF, 0xFF, "le premier masque doit revenir")
        XCTAssertEqual(core.registers[0] & 0xFF, 0xFB, "et le second aussi")
    }

    /// Les trois octets qui suivent ICW1 arrivent par le **port de données**,
    /// exactement là où un masque arriverait. Sans compter les étapes, le
    /// premier — le vecteur de base — serait pris pour un masque, et le
    /// contrôleur livrerait au mauvais numéro.
    func testTheInitialisationWordsAreNotMistakenForAMask() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // `b0 11` `e6 20` : ICW1 ; puis 0x30, 0x04, 0x01 par le port 0x21 ;
        // puis 0xfe, le vrai masque.
        var core = try Self.core(ram, [
            0xB0, 0x11, 0xE6, 0x20,
            0xB0, 0x30, 0xE6, 0x21,
            0xB0, 0x04, 0xE6, 0x21,
            0xB0, 0x01, 0xE6, 0x21,
            0xB0, 0xFE, 0xE6, 0x21,
        ])
        core.devices.primary.mask = 0xAA
        try core.run(budget: 10)
        XCTAssertEqual(core.devices.primary.vectorBase, 0x30)
        XCTAssertEqual(core.devices.primary.mask, 0xFE, "le masque n'arrive qu'à la fin")
        XCTAssertEqual(core.devices.primary.initialisationStep, 0)
    }

    // MARK: - Le battement

    /// Le canal zéro déborde, la ligne zéro demande, et le gestionnaire du
    /// noyau est appelé au vecteur que le contrôleur porte.
    func testTheTimerReachesTheHandler() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xEB, 0xFE])  // une boucle infinie
        Self.armed(&core)
        try core.run(budget: 500)
        XCTAssertTrue(core.halted, "le gestionnaire s'arrête sur un HLT")
        XCTAssertEqual(core.rip, Self.handler &+ 1)
        XCTAssertEqual(core.devices.primary.service, 1, "la ligne zéro est en service")
        XCTAssertEqual(core.devices.primary.request, 0, "et n'est plus en demande")
        XCTAssertEqual(core.flags & X86Core.Flag.interrupt, 0, "une porte d'interruption masque")
    }

    /// **Une ligne en service bloque les moins prioritaires.** C'est la règle
    /// du 8259, et elle n'est pas décorative : le gestionnaire d'une ligne
    /// rouvre les interruptions avant d'avoir fini — Linux traite ses
    /// « softirq » ainsi —, et sans cette règle la même ligne le
    /// réinterromprait aussitôt, sur sa propre pile, aussi longtemps que la
    /// condition dure. Une pile de noyau fait seize kilo-octets ; ce qui est
    /// dessous ne lui appartient pas.
    func testALineInServiceBlocksItsEqualsAndItsInferiors() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xEB, 0xFE])
        Self.armed(&core)
        try core.run(budget: 500)
        XCTAssertEqual(core.devices.primary.service, 1, "la ligne zéro est en service")

        // Le gestionnaire rouvre les interruptions, et l'horloge rebat.
        core.flags |= X86Core.Flag.interrupt
        core.halted = false
        let entered = core.rip
        core.devices.primary.request |= 1
        try core.serviceInterrupts()
        XCTAssertEqual(core.rip, entered, "rien n'est entré une seconde fois")
        XCTAssertNotEqual(core.devices.primary.request & 1, 0, "et la demande attend")
    }

    /// Une ligne **plus prioritaire**, elle, passe : c'est l'autre moitié de
    /// la règle, et l'oublier ferait attendre l'horloge derrière un clavier.
    func testAMorePriorityLinePreemptsWhatIsInService() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xEB, 0xFE])
        Self.armed(&core)
        core.devices.primary.mask = 0xEE      // les lignes zéro et quatre
        core.devices.primary.service = 1 << 4  // la quatre est en service
        core.devices.primary.request |= 1      // la zéro demande
        try core.serviceInterrupts()
        XCTAssertEqual(core.rip, Self.handler, "la plus prioritaire est entrée")
        XCTAssertEqual(core.devices.primary.service, 0x11, "les deux sont en service")
    }

    /// Et la fin d'interruption rouvre la porte.
    func testAnEndOfInterruptLetsTheNextOneIn() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xEB, 0xFE])
        Self.armed(&core)
        core.devices.primary.service = 1
        core.devices.primary.request |= 1
        core.flags |= X86Core.Flag.interrupt
        try core.serviceInterrupts()
        XCTAssertNotEqual(core.devices.primary.request & 1, 0, "bloquée tant qu'elle sert")

        core.portWrite(0x20, 1, 0x20)  // fin d'interruption non spécifique
        XCTAssertEqual(core.devices.primary.service, 0)
        try core.serviceInterrupts()
        XCTAssertEqual(core.rip, Self.handler, "et elle entre")
    }

    /// **La fin d'interruption « spécifique », celle que Linux envoie.**
    /// `mask_and_ack_8259A` écrit `0x60 + irq`, et non le 0x20 générique : elle
    /// nomme la ligne à retirer du service. Prendre la plus prioritaire à la
    /// place se voit dès que deux lignes sont en service — la ligne nommée
    /// resterait en service pour toujours, et tout ce qui est moins
    /// prioritaire qu'elle n'entrerait plus jamais. Sur un PC, « moins
    /// prioritaire que le port série » comprend le disque.
    func testASpecificEndOfInterruptClearsTheLineItNames() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xEB, 0xFE])
        core.devices.primary.service = 0x11  // les lignes zéro et quatre
        core.portWrite(0x20, 1, 0x64)        // fin d'interruption pour la quatre
        XCTAssertEqual(core.devices.primary.service, 0x01,
                       "la quatre part, la zéro reste")
        core.portWrite(0x20, 1, 0x60)        // et pour la zéro
        XCTAssertEqual(core.devices.primary.service, 0)
    }

    /// La forme générique, elle, retire la plus prioritaire — c'est sa
    /// définition, et les deux formes ne doivent pas être confondues.
    func testANonSpecificEndOfInterruptClearsTheMostUrgentOne() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xEB, 0xFE])
        core.devices.primary.service = 0x11
        core.portWrite(0x20, 1, 0x20)
        XCTAssertEqual(core.devices.primary.service, 0x10, "la zéro part la première")
    }

    /// Une ligne masquée n'est **pas** livrée, et sa demande **reste**. C'est
    /// ce qui permet au noyau de la trouver quand il démasque : la perdre
    /// ferait rater un battement à chaque fois qu'il ferme la porte.
    func testAMaskedLineStaysPending() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xEB, 0xFE])
        Self.armed(&core)
        core.devices.primary.mask = 0xFF
        try core.run(budget: 500)
        XCTAssertFalse(core.halted)
        XCTAssertEqual(core.devices.primary.request, 1, "la demande attend le démasquage")
    }

    /// Les interruptions masquées dans les drapeaux : même chose. Le noyau
    /// passe son temps à fermer et rouvrir cette porte-là.
    func testInterruptsDisabledInTheFlagsHoldTheLineToo() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xEB, 0xFE])
        Self.armed(&core)
        core.flags &= ~X86Core.Flag.interrupt
        try core.run(budget: 500)
        XCTAssertFalse(core.halted)
        XCTAssertEqual(core.devices.primary.request, 1)
    }

    /// Et une ligne dont le vecteur n'a **pas encore de porte** reste en
    /// demande elle aussi. C'est le cas réel : un noyau arme son horloge avant
    /// d'avoir posé le gestionnaire, et la retirer là ferait perdre le
    /// battement pour de bon. C'est exactement ce qui s'est passé pendant le
    /// démarrage d'Alpine — la ligne zéro est restée en demande onze mille
    /// fois de suite, faute de porte, et c'est ce qui a permis de trouver le
    /// vrai défaut.
    func testALineWithNoGateYetStaysPending() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xEB, 0xFE])
        Self.armed(&core)
        core.devices.primary.vectorBase = 0x40  // aucun gestionnaire à ce numéro
        try core.run(budget: 500)
        XCTAssertFalse(core.halted)
        XCTAssertEqual(core.devices.primary.request, 1, "la demande attend sa porte")
        XCTAssertEqual(core.devices.primary.service, 0, "et n'est jamais entrée en service")
    }

    /// La fin d'interruption libère la ligne. Sans elle, un vrai 8259 ne
    /// livrerait plus jamais rien.
    func testAnEndOfInterruptClearsTheServiceBit() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xEB, 0xFE])
        Self.armed(&core)
        try core.run(budget: 500)
        XCTAssertEqual(core.devices.primary.service, 1)
        // `b0 20` `e6 20` : out $0x20 dans le port de commande.
        try ram.load([0xB0, 0x20, 0xE6, 0x20], at: 0x200)
        core.rip = 0x200
        core.halted = false
        try core.run(budget: 2)
        XCTAssertEqual(core.devices.primary.service, 0)
    }

    /// `HLT` **attend** une interruption, il ne s'arrête pas. Le temps de
    /// l'invité vient du compteur d'instructions ; un processeur arrêté n'en
    /// retire aucune, donc sans un second compteur son horloge s'arrêterait
    /// avec lui et le réveil n'arriverait jamais.
    func testHLTWaitsForTheTimerRatherThanStopping() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xF4])
        Self.armed(&core)
        try core.run(budget: 500)
        XCTAssertEqual(core.rip, Self.handler &+ 1, "le battement doit l'avoir réveillé")
        XCTAssertGreaterThan(core.idled, 0, "et du temps doit avoir passé pendant l'attente")
    }

    /// Mais sans horloge armée, `HLT` est un arrêt et pas une attente. Le dire
    /// tout de suite vaut mieux que de brûler le budget à ne rien faire — et
    /// c'est ce qu'un invité qui a fini son travail attend d'un émulateur.
    func testHLTWithoutAClockStopsInsteadOfBurningTheBudget() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xF4])
        core.flags |= X86Core.Flag.interrupt
        let executed = try core.run(budget: 1_000_000)
        XCTAssertLessThan(executed, 10, "rien ne peut plus arriver : inutile d'attendre")
        XCTAssertTrue(core.halted)
    }

    // MARK: - Le 8253

    /// Le compte descend et se recharge. C'est ce que le noyau lit pour
    /// étalonner ce qu'il ne peut pas mesurer autrement.
    func testTheCounterCountsDownAndReloads() throws {
        var devices = X86LegacyDevices()
        devices.reload = 100
        XCTAssertEqual(devices.count(at: 0), 100)
        XCTAssertEqual(devices.count(at: 30), 70)
        XCTAssertEqual(devices.count(at: 100), 100, "au débordement, il repart d'en haut")
        XCTAssertEqual(devices.expirations(at: 250), 2)
    }

    /// Le 8253 se lit un octet à la fois. La commande de verrouillage fige le
    /// compte pour que les deux moitiés d'une même lecture viennent du **même**
    /// instant : sans elle, le compte descend entre les deux et la valeur
    /// reconstruite n'a jamais existé.
    func testTheLatchFreezesTheCountForBothHalvesOfAReading() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // `b0 40` `e6 43` : commande de verrouillage du canal zéro.
        // Puis deux `e4 40` séparés par de quoi faire passer le temps.
        var core = try Self.core(ram, [
            0xB0, 0x00, 0xE6, 0x43,
            0xE4, 0x40, 0x88, 0xC3,
            0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
            0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
            0xE4, 0x40,
        ])
        core.devices.reload = 0x3000
        try core.run(budget: 40)
        let low = core.registers[3] & 0xFF
        let high = core.registers[0] & 0xFF
        XCTAssertEqual(high << 8 | low, 0x3000,
                       "les deux moitiés doivent venir du même instant")
    }

    /// Le port 0x61 dit quand le canal deux est arrivé à zéro. C'est par là
    /// que Linux étalonne son compteur de cycles : il lance le canal, puis
    /// attend ce bit.
    func testPortSixtyOneReportsTheSecondChannelFinishing() throws {
        var devices = X86LegacyDevices()
        devices.speakerReload = 50
        XCTAssertFalse(devices.speakerFinished(at: 100), "la porte est fermée")
        devices.speakerGate = true
        devices.speakerStartedAt = 100
        XCTAssertFalse(devices.speakerFinished(at: 120))
        XCTAssertTrue(devices.speakerFinished(at: 150))
        XCTAssertEqual(devices.speakerCount(at: 120), 30)
        XCTAssertEqual(devices.speakerCount(at: 200), 0)
    }

    // MARK: - La chaîne de bits

    /// **Le numéro de bit n'est pas borné quand la destination est en
    /// mémoire.** C'est la forme que le manuel appelle « bit string » : le
    /// numéro est signé, il désigne un bit n'importe où autour de l'adresse, et
    /// le processeur va chercher le mot qui le contient.
    ///
    /// Le réduire au modulo, comme pour un registre, replie tout un tableau de
    /// bits dans son premier mot. Linux tient ses vecteurs d'interruption
    /// réservés dans un tableau de 256 bits et posait ceux de 0xEC à 0xFF avec
    /// cette instruction : ils atterrissaient aux numéros 44 et 48 à 63,
    /// c'est-à-dire pile sur les vecteurs des interruptions ISA. Le noyau les
    /// croyait pris, ne posait plus de porte pour l'horloge, et attendait un
    /// battement qui ne pouvait plus arriver.
    func testABitNumberBeyondOneWordReachesTheRightWord() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // `48 0f ab 0e` : btsq %rcx,(%rsi)
        var core = try Self.core(ram, [0x48, 0x0F, 0xAB, 0x0E])
        core.registers[6] = 0x1000
        core.registers[1] = 100  // mot 1, bit 36
        try core.run(budget: 1)
        XCTAssertEqual(try ram.read(0x1008, 8), 1 << 36)
        XCTAssertEqual(try ram.read(0x1000, 8), 0, "le premier mot ne doit pas bouger")
    }

    /// Et un numéro **négatif** descend d'un mot au lieu de remonter. La
    /// division doit être arrondie vers le bas, ce que celle des entiers ne
    /// fait pas.
    func testANegativeBitNumberGoesDownAWord() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0x48, 0x0F, 0xAB, 0x0E])
        core.registers[6] = 0x1000
        core.registers[1] = UInt64(bitPattern: -1)  // mot -1, bit 63
        try core.run(budget: 1)
        XCTAssertEqual(try ram.read(0x0FF8, 8), 1 << 63)
    }

    /// Mais quand la destination est un **registre**, le numéro est bien
    /// réduit au modulo : il n'y a pas de mot voisin où aller.
    func testABitNumberOnARegisterIsTakenModuloItsWidth() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // `48 0f ab c8` : btsq %rcx,%rax
        var core = try Self.core(ram, [0x48, 0x0F, 0xAB, 0xC8])
        core.registers[1] = 100  // 100 modulo 64 vaut 36
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[0], 1 << 36)
    }
}
