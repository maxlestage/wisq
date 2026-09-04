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
