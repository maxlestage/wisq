import XCTest

@testable import WisqVM

/// La machine PC, telle que l'application s'en servirait.
///
/// `X86BootAttemptTests` prouve que le cœur démarre un vrai noyau ; ces
/// tests-ci prouvent que **la machine autour** fait ce qu'on attend d'elle :
/// charger, sortir, prendre ce qu'on tape, s'arrêter quand on le demande, et
/// ne pas tourner dans le vide quand plus rien ne peut arriver.
final class X86LocalMachineTests: XCTestCase {
    /// Un noyau minuscule qui écrit sur le port série puis s'arrête, dans la
    /// forme qu'un vrai `bzImage` a — sinon le chargeur le refuse, et à juste
    /// titre.
    static func kernel(_ code: [UInt8]) -> Data {
        var image = LinuxBootProtocolTests.header()
        image += [UInt8](repeating: 0, count: 0x1000 - image.count)
        // Le protocole veut `setup_sects` secteurs de setup puis le noyau en
        // mode protégé ; on met le code juste après, à 0x200 du début comme le
        // point d'entrée 64 bits l'exige.
        let setup = Int(image[0x1F1] == 0 ? 4 : image[0x1F1]) * 512 + 512
        var body = [UInt8](repeating: 0, count: 0x200)
        body += code
        body += [UInt8](repeating: 0, count: max(0, 0x1000 - body.count))
        image = Array(image[0..<min(image.count, setup)])
        image += [UInt8](repeating: 0, count: max(0, setup - image.count))
        image += body
        // `syssize`, en paragraphes de seize octets, doit décrire le corps.
        let paragraphs = UInt32(body.count / 16)
        for byte in 0..<4 {
            image[0x1F4 + byte] = UInt8(truncatingIfNeeded: paragraphs >> (8 * byte))
        }
        return Data(image)
    }

    /// `mov $c,%al ; mov $0x3f8,%dx ; out %al,(%dx)` pour chaque caractère,
    /// puis `hlt`.
    static func printing(_ text: String) -> [UInt8] {
        var code: [UInt8] = [0x66, 0xBA, 0xF8, 0x03]  // mov $0x3f8,%dx
        for byte in Array(text.utf8) { code += [0xB0, byte, 0xEE] }
        code.append(0xF4)
        return code
    }

    func machine(_ code: [UInt8], out: @escaping @Sendable (Data) -> Void) throws -> X86Machine {
        let machine = X86Machine(onOutput: out)
        try machine.load(kernelImage: Self.kernel(code))
        return machine
    }

    /// Ce que l'invité écrit sur le port série arrive à qui regarde la
    /// console.
    func testWhatTheGuestWritesReachesTheConsole() throws {
        let collected = Collector()
        let machine = try machine(Self.printing("wisq"), out: { collected.append($0) })
        XCTAssertEqual(machine.run(instructionBudget: 1000), .powerOff)
        XCTAssertEqual(collected.text, "wisq")
    }

    /// Un invité arrêté ne brûle pas le budget à attendre ce qui ne viendra
    /// pas. Sans horloge armée, `HLT` est un arrêt et non une attente — et le
    /// dire tout de suite évite qu'un téléphone tourne à plein régime pour un
    /// invité qui a fini.
    func testAGuestThatStopsDoesNotBurnTheBudget() throws {
        let machine = try machine([0xF4], out: { _ in })
        XCTAssertEqual(machine.run(instructionBudget: 100_000_000), .powerOff)
        XCTAssertLessThan(machine.retiredInstructions, 100, "il ne doit pas tourner dans le vide")
    }

    /// Ce qu'on tape arrive à l'invité, et le registre d'état de la ligne le
    /// lui annonce. Sans ce bit, un invité qui attend une touche ne saurait
    /// jamais qu'il y en a une.
    func testWhatIsTypedReachesTheGuest() throws {
        // Lire l'état de la ligne jusqu'à ce qu'un octet soit prêt, le lire,
        // le renvoyer, puis s'arrêter :
        //   66 ba fd 03   mov $0x3fd,%dx
        //   ec            in  (%dx),%al
        //   a8 01         test $1,%al
        //   74 fa         je -6
        //   66 ba f8 03   mov $0x3f8,%dx
        //   ec            in  (%dx),%al
        //   ee            out %al,(%dx)
        //   f4            hlt
        let code: [UInt8] = [
            0x66, 0xBA, 0xFD, 0x03, 0xEC, 0xA8, 0x01, 0x74, 0xFA,
            0x66, 0xBA, 0xF8, 0x03, 0xEC, 0xEE, 0xF4,
        ]
        let collected = Collector()
        let machine = try machine(code, out: { collected.append($0) })
        machine.send(Data("A".utf8))
        XCTAssertEqual(machine.run(instructionBudget: 100_000), .powerOff)
        XCTAssertEqual(collected.text, "A")
    }

    /// `stop()` rend la main, depuis n'importe où.
    func testStopEndsTheRun() throws {
        // `eb fe` : une boucle infinie, qui ne s'arrêterait jamais seule.
        let machine = try machine([0xEB, 0xFE], out: { _ in })
        machine.stop()
        // Un budget, pour que le test **finisse** même si l'arrêt est ignoré :
        // sans lui, le sabotage qui le supprime ferait tourner la boucle
        // indéfiniment au lieu de faire tomber le test, et on ne saurait pas
        // si le test tient quoi que ce soit. Mesuré : il a tourné dix minutes.
        XCTAssertEqual(machine.run(instructionBudget: 20_000_000), .stopped)
        XCTAssertLessThan(machine.retiredInstructions, 1000,
                          "l'arrêt doit rendre la main tout de suite")
    }

    /// Le budget borne un invité qui ne s'arrête pas.
    func testTheBudgetBoundsAnEndlessGuest() throws {
        let machine = try machine([0xEB, 0xFE], out: { _ in })
        XCTAssertEqual(machine.run(instructionBudget: 50_000), .stopped)
        // **Exactement**, et pas « à une tranche près ». La première version
        // tolérait un dépassement de la taille d'une tranche, et le sabotage
        // qui supprimait le calcul du reste passait donc sans être vu : deux
        // cent mille instructions au lieu de cinquante mille, sur un
        // téléphone, pour un budget qu'on croyait tenu.
        XCTAssertEqual(machine.retiredInstructions, 50_000)
    }

    /// Un refus du cœur est **nommé**. Un arrêt sans nom envoie chercher
    /// partout ; celui-ci dit quelle instruction.
    func testARefusalIsNamedRatherThanSilent() throws {
        // `0f 6f c1` : une instruction MMX, que ce cœur ne connaît pas.
        let machine = try machine([0x0F, 0x6F, 0xC1], out: { _ in })
        guard case .faulted(let reason) = machine.run(instructionBudget: 10) else {
            return XCTFail("attendu un refus nommé")
        }
        XCTAssertTrue(reason.contains("6F"), reason)
    }

    /// La mémoire ne descend pas sous le plancher, même si on le demande : le
    /// noyau décompressé fait à lui seul trente-cinq mébioctets, et une
    /// machine trop petite échouerait sans dire pourquoi.
    func testTheMemoryNeverGoesUnderTheFloor() {
        let machine = X86Machine(ramSize: 1 << 20) { _ in }
        XCTAssertEqual(machine.ramSize, X86Machine.minimumRAMSize)
    }

    /// Un ramasseur sûr entre les fils, pour que le rappel de sortie puisse
    /// venir de n'importe où.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) {
            lock.lock()
            bytes.append(data)
            lock.unlock()
        }
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// « L'instantané rend la machine telle quelle » — champ par champ.
///
/// Le piège, mesuré une première fois sur le RISC-V : comparer deux
/// instantanés ne prouve rien. Un champ qu'on oublie d'écrire est absent des
/// deux, et ils se ressemblent parfaitement. Il faut poser une valeur
/// distinctive dans **chaque** champ, faire l'aller-retour, et la redemander.
final class X86SnapshotTests: XCTestCase {
    /// Une machine dont chaque champ porte une valeur qu'on reconnaîtra.
    static func marked() throws -> X86Machine {
        let machine = X86Machine(onOutput: { _ in })
        try machine.load(kernelImage: X86LocalMachineTests.kernel([0xF4]))
        for index in 0..<16 { machine.core.registers[index] = 0xA000 + UInt64(index) }
        machine.core.flags = X86Core.Flag.carry | X86Core.Flag.reserved | X86Core.Flag.direction
        machine.core.rip = 0xDEAD_BEEF
        machine.core.retired = 123_456
        machine.core.idled = 7890
        machine.core.halted = true
        machine.core.pagingActive = true
        for index in 0..<16 { machine.core.system.control[index] = 0xB000 + UInt64(index) }
        for index in 0..<8 { machine.core.system.debug[index] = 0xC000 + UInt64(index) }
        machine.core.system.modelSpecific = [
            X86SystemState.efer: 0x501, X86SystemState.gsBase: 0xFEED,
            X86SystemState.fsBase: 0xF00D,
        ]
        for index in 0..<6 { machine.core.segments[index] = UInt16(0x10 + index * 8) }
        for index in 0..<2 {
            machine.core.descriptorBases[index] = 0xD000 + UInt64(index)
            machine.core.descriptorLimits[index] = 0xE000 + UInt64(index)
        }
        machine.core.taskSelector = 0x0040
        machine.core.taskBase = 0xFFFF_8000_0001_2340
        machine.core.taskLimit = 0x0000_206F
        machine.core.x87Control = 0x0300
        machine.core.x87Status = 0x1234
        machine.core.mxcsr = 0x1DC0
        for index in 0..<16 {
            machine.core.setVector(index,
                                   0x7000_0000_0000_0000 + UInt64(index),
                                   0x8000_0000_0000_0000 + UInt64(index))
        }
        machine.core.devices.primary.mask = 0xFE
        machine.core.devices.primary.request = 0x03
        machine.core.devices.primary.service = 0x01
        machine.core.devices.primary.vectorBase = 0x30
        machine.core.devices.primary.initialisationStep = 2
        machine.core.devices.primary.readsService = true
        machine.core.devices.secondary.mask = 0xAB
        machine.core.devices.secondary.vectorBase = 0x38
        machine.core.devices.reload = 0x1234
        machine.core.devices.writeHighNext = true
        machine.core.devices.readHighNext = true
        machine.core.devices.latched = 0x4321
        machine.core.devices.reloadedAt = 55555
        machine.core.devices.raised = 4242
        machine.core.devices.speakerReload = 0x2468
        machine.core.devices.speakerWriteHighNext = true
        machine.core.devices.speakerStartedAt = 99999
        machine.core.devices.speakerGate = true
        machine.core.devices.serial.interruptEnable = 0x03
        machine.core.devices.serial.fifoControl = 0xC7
        machine.core.devices.serial.lineControl = 0x03
        machine.core.devices.serial.modemControl = 0x0B
        machine.core.devices.serial.scratch = 0x5A
        machine.core.devices.serial.divisor = 0x000C
        machine.core.devices.serial.transmitPending = true
        machine.core.serialInput = [0x41, 0x42]
        try machine.core.memory?.write(0x30_0000, 8, 0xCAFE_F00D)
        return machine
    }

    /// Chaque champ, redemandé après l'aller-retour.
    func testEveryFieldComesBack() throws {
        let saved = try Self.marked().snapshot()
        let machine = X86Machine(onOutput: { _ in })
        try machine.restore(saved)
        let core = machine.core

        for index in 0..<16 {
            XCTAssertEqual(core.registers[index], 0xA000 + UInt64(index), "registre \(index)")
        }
        XCTAssertEqual(core.flags,
                       X86Core.Flag.carry | X86Core.Flag.reserved | X86Core.Flag.direction)
        XCTAssertEqual(core.rip, 0xDEAD_BEEF)
        XCTAssertEqual(core.retired, 123_456)
        XCTAssertEqual(core.idled, 7890)
        XCTAssertTrue(core.halted)
        XCTAssertTrue(core.pagingActive)
        for index in 0..<16 {
            XCTAssertEqual(core.system.control[index], 0xB000 + UInt64(index), "CR\(index)")
        }
        for index in 0..<8 {
            XCTAssertEqual(core.system.debug[index], 0xC000 + UInt64(index), "DR\(index)")
        }
        XCTAssertEqual(core.system.modelSpecific[X86SystemState.gsBase], 0xFEED)
        XCTAssertEqual(core.system.modelSpecific[X86SystemState.fsBase], 0xF00D)
        for index in 0..<6 {
            XCTAssertEqual(core.segments[index], UInt16(0x10 + index * 8), "segment \(index)")
        }
        for index in 0..<2 {
            XCTAssertEqual(core.descriptorBases[index], 0xD000 + UInt64(index))
            XCTAssertEqual(core.descriptorLimits[index], 0xE000 + UInt64(index))
        }
        XCTAssertEqual(core.taskSelector, 0x0040)
        XCTAssertEqual(core.taskBase, 0xFFFF_8000_0001_2340)
        XCTAssertEqual(core.taskLimit, 0x0000_206F)
        XCTAssertEqual(core.x87Control, 0x0300)
        XCTAssertEqual(core.x87Status, 0x1234)
        XCTAssertEqual(core.mxcsr, 0x1DC0)
        for index in 0..<16 {
            XCTAssertEqual(core.vector(index).low,
                           0x7000_0000_0000_0000 + UInt64(index), "xmm\(index) bas")
            XCTAssertEqual(core.vector(index).high,
                           0x8000_0000_0000_0000 + UInt64(index), "xmm\(index) haut")
        }
        XCTAssertEqual(core.devices.primary.mask, 0xFE)
        XCTAssertEqual(core.devices.primary.request, 0x03)
        XCTAssertEqual(core.devices.primary.service, 0x01)
        XCTAssertEqual(core.devices.primary.vectorBase, 0x30)
        XCTAssertEqual(core.devices.primary.initialisationStep, 2)
        XCTAssertTrue(core.devices.primary.readsService)
        XCTAssertEqual(core.devices.secondary.mask, 0xAB)
        XCTAssertEqual(core.devices.secondary.vectorBase, 0x38)
        XCTAssertEqual(core.devices.reload, 0x1234)
        XCTAssertTrue(core.devices.writeHighNext)
        XCTAssertTrue(core.devices.readHighNext)
        XCTAssertEqual(core.devices.latched, 0x4321)
        XCTAssertEqual(core.devices.reloadedAt, 55555)
        XCTAssertEqual(core.devices.raised, 4242)
        XCTAssertEqual(core.devices.speakerReload, 0x2468)
        XCTAssertTrue(core.devices.speakerWriteHighNext)
        XCTAssertEqual(core.devices.speakerStartedAt, 99999)
        XCTAssertTrue(core.devices.speakerGate)
        XCTAssertEqual(core.devices.serial.interruptEnable, 0x03)
        XCTAssertEqual(core.devices.serial.fifoControl, 0xC7)
        XCTAssertEqual(core.devices.serial.lineControl, 0x03)
        XCTAssertEqual(core.devices.serial.modemControl, 0x0B)
        XCTAssertEqual(core.devices.serial.scratch, 0x5A)
        XCTAssertEqual(core.devices.serial.divisor, 0x000C)
        XCTAssertTrue(core.devices.serial.transmitPending)
        XCTAssertEqual(core.serialInput, [0x41, 0x42])
        XCTAssertEqual(try core.memory?.read(0x30_0000, 8), 0xCAFE_F00D, "la RAM")
    }

    /// **Le verrou de l'horloge figée.** `latched` vaut `nil` quand aucune
    /// commande de verrouillage n'est en cours, et 0 est une valeur
    /// parfaitement légitime — les confondre ferait rendre au noyau un compte
    /// figé qu'il n'a pas demandé.
    func testTheLatchTellsNoneFromZero() throws {
        for latched in [nil, UInt16(0), UInt16(7)] {
            let machine = try Self.marked()
            machine.core.devices.latched = latched
            let restored = X86Machine(onOutput: { _ in })
            try restored.restore(machine.snapshot())
            XCTAssertEqual(restored.core.devices.latched, latched, "\(String(describing: latched))")
        }
    }

    /// Le vrai contrat : une machine reprise **continue** comme l'originale.
    /// Pas « se ressemble » — produit les mêmes octets et s'arrête au même
    /// endroit.
    func testARestoredMachineContinuesIdentically() throws {
        let first = X86LocalMachineTests.Collector()
        let original = X86Machine(onOutput: { first.append($0) })
        try original.load(kernelImage: X86LocalMachineTests.kernel(
            X86LocalMachineTests.printing("bonjour")))
        // Quelques instructions, puis on sauve à mi-chemin.
        original.run(instructionBudget: 5)
        let saved = original.snapshot()
        original.run(instructionBudget: 1000)

        let second = X86LocalMachineTests.Collector()
        let resumed = X86Machine(onOutput: { second.append($0) })
        try resumed.restore(saved)
        resumed.run(instructionBudget: 1000)

        XCTAssertEqual(resumed.retiredInstructions, original.retiredInstructions)
        XCTAssertEqual(resumed.core.rip, original.core.rip)
        // La première machine a écrit le début avant d'être sauvée ; les deux
        // moitiés recollées doivent faire le texte entier.
        XCTAssertEqual(first.text, "bonjour")
        XCTAssertTrue("bonjour".hasSuffix(second.text), "\(second.text)")
        XCTAssertFalse(second.text.isEmpty, "la reprise doit continuer à écrire")
    }

    /// Des octets qui ne sont pas un instantané sont **refusés**, pas
    /// interprétés. Une machine à moitié restaurée est pire qu'une machine
    /// perdue : elle a l'air de marcher.
    func testRubbishIsRefused() throws {
        let machine = X86Machine(onOutput: { _ in })
        XCTAssertThrowsError(try machine.restore(Data([0x00, 0x01, 0x02]))) {
            XCTAssertEqual($0 as? Snapshot.Failure, .notASnapshot)
        }
    }
}
