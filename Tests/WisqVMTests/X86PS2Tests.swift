import XCTest

@testable import WisqVM

/// **Le clavier et la souris PS/2**, tels que Linux les sonde.
///
/// La séquence est celle de `drivers/input/serio/i8042.c` et de `atkbd.c` :
/// relire le CTR, tester le contrôleur, boucler un octet par le port de la
/// souris, identifier le clavier. Le témoin est un vrai noyau — Chimera
/// trouve « AT Translated Set 2 keyboard » et « PS/2 Generic Mouse » sur les
/// lignes 1 et 12 —, et ces tests tiennent chaque réponse.
final class X86PS2Tests: XCTestCase {
    private func drain(_ ps2: inout X86PS2Controller) -> [UInt8] {
        var bytes: [UInt8] = []
        while ps2.status() & 0x01 != 0 { bytes.append(ps2.readData()) }
        return bytes
    }

    /// Le contrôleur répond à la sonde de Linux : CTR, test, bouclage.
    func testTheControllerAnswersLinuxsProbe() {
        var ps2 = X86PS2Controller()
        XCTAssertEqual(ps2.status() & 0x01, 0, "rien à lire au départ")
        XCTAssertNotEqual(ps2.status() & 0x10, 0, "le clavier n'est pas verrouillé")
        ps2.writeCommand(0x20)
        let ctr = drain(&ps2)
        XCTAssertEqual(ctr.count, 1)
        XCTAssertNotEqual(ctr[0] & 0x40, 0, "la traduction, comme un BIOS la laisse")
        ps2.writeCommand(0x60)
        ps2.writeData(0x47)
        ps2.writeCommand(0x20)
        XCTAssertEqual(drain(&ps2), [0x47], "le CTR écrit se relit")
        ps2.writeCommand(0xAA)
        XCTAssertEqual(drain(&ps2), [0x55], "le contrôleur se teste bien")
        // Le bouclage : l'octet revient, marqué comme venant de la souris.
        ps2.writeCommand(0xD3)
        ps2.writeData(0x5A)
        XCTAssertNotEqual(ps2.status() & 0x20, 0, "sortie de la souris")
        XCTAssertEqual(drain(&ps2), [0x5A])
        ps2.writeCommand(0xA9)
        XCTAssertEqual(drain(&ps2), [0x00], "le port de la souris se teste bien")
        // Éteindre et rallumer la souris se lit dans le CTR.
        ps2.writeCommand(0xA7)
        ps2.writeCommand(0x20)
        XCTAssertNotEqual(drain(&ps2)[0] & 0x20, 0)
        ps2.writeCommand(0xA8)
        ps2.writeCommand(0x20)
        XCTAssertEqual(drain(&ps2)[0] & 0x20, 0)
    }

    /// Le clavier se présente en MF2 traduit, et la souris en souris
    /// standard.
    func testTheDevicesIdentifyThemselves() {
        var ps2 = X86PS2Controller()
        ps2.writeData(0xF2)
        XCTAssertEqual(drain(&ps2), [0xFA, 0xAB, 0x41])
        ps2.writeData(0xFF)
        XCTAssertEqual(drain(&ps2), [0xFA, 0xAA])
        ps2.writeCommand(0xD4)
        ps2.writeData(0xF2)
        XCTAssertEqual(drain(&ps2), [0xFA, 0x00])
        ps2.writeCommand(0xD4)
        ps2.writeData(0xF3)
        ps2.writeCommand(0xD4)
        ps2.writeData(100)
        XCTAssertEqual(drain(&ps2), [0xFA, 0xFA], "le paramètre a son accusé")
    }

    /// Une touche : en jeu 1 quand le contrôleur traduit, en jeu 2 sinon,
    /// avec `E0` pour les touches étendues.
    func testAKeyIsSentInTheSetTheControllerExpects() {
        var ps2 = X86PS2Controller()
        ps2.key(X86ScanCode(0x1E), down: true)
        ps2.key(X86ScanCode(0x1E), down: false)
        ps2.key(.up, down: true)
        XCTAssertEqual(drain(&ps2), [0x1E, 0x9E, 0xE0, 0x48], "A, puis la flèche haut, en jeu 1")
        ps2.writeCommand(0x60)
        ps2.writeData(0x07)  // sans traduction
        ps2.key(X86ScanCode(0x1E), down: true)
        ps2.key(X86ScanCode(0x1E), down: false)
        ps2.key(.enter, down: true)
        XCTAssertEqual(drain(&ps2), [0x1C, 0xF0, 0x1C, 0x5A], "A puis Entrée, en jeu 2")
    }

    /// Un caractère se tape sur un clavier américain.
    func testACharacterMapsToItsUSKey() {
        XCTAssertEqual(X86ScanCode.typing("a")?.code, X86ScanCode(0x1E))
        XCTAssertEqual(X86ScanCode.typing("A")?.shift, true)
        XCTAssertEqual(X86ScanCode.typing("1")?.code, X86ScanCode(0x02))
        XCTAssertEqual(X86ScanCode.typing("!")?.shift, true)
        XCTAssertEqual(X86ScanCode.typing("/")?.code, X86ScanCode(0x35))
        XCTAssertNil(X86ScanCode.typing("é"), "rien pour ce qu'un clavier QWERTY n'a pas")
    }

    /// La souris ne parle qu'une fois allumée, et ses paquets disent Y vers
    /// le haut ; un grand mouvement se découpe.
    func testTheMouseSendsPacketsOnceEnabled() {
        var ps2 = X86PS2Controller()
        ps2.writeCommand(0xA8)
        ps2.mouse(dx: 5, dy: 5, buttons: 1)
        XCTAssertTrue(drain(&ps2).isEmpty, "rien avant F4")
        ps2.writeCommand(0xD4)
        ps2.writeData(0xF4)
        _ = drain(&ps2)
        ps2.mouse(dx: 5, dy: 3, buttons: 1)
        XCTAssertEqual(drain(&ps2), [0x08 | 0x01 | 0x20, 5, 0xFD], "Y vers le bas à l'écran, négatif dans le paquet")
        ps2.mouse(dx: -300, dy: 0, buttons: 0)
        let bytes = drain(&ps2)
        XCTAssertEqual(bytes.count, 6, "deux paquets")
        // −300 en deux pas : −255 puis −45, signe de X levé dans les deux.
        XCTAssertNotEqual(bytes[0] & 0x10, 0)
        XCTAssertEqual(bytes[1], UInt8(truncatingIfNeeded: -255))
        XCTAssertNotEqual(bytes[3] & 0x10, 0)
        XCTAssertEqual(bytes[4], UInt8(truncatingIfNeeded: -45))
    }

    /// Les lignes suivent ce qui attend : la 1 pour le clavier, la 12 pour la
    /// souris, et rien quand le noyau a coupé l'interruption.
    func testTheLinesFollowWhatIsWaiting() {
        var ps2 = X86PS2Controller()
        ps2.key(.space, down: true)
        XCTAssertTrue(ps2.keyboardInterrupting)
        XCTAssertFalse(ps2.mouseInterrupting)
        _ = drain(&ps2)
        XCTAssertFalse(ps2.keyboardInterrupting)
        ps2.writeCommand(0xD3)
        ps2.writeData(1)
        XCTAssertTrue(ps2.mouseInterrupting)
        ps2.writeCommand(0x60)
        ps2.writeData(0x44)  // plus d'interruption de la souris
        XCTAssertFalse(ps2.mouseInterrupting)
    }

    /// **La cascade** : une demande de la souris, sur la ligne 12, entre au
    /// vecteur du second contrôleur, et les deux le gardent en service
    /// jusqu'à leur fin d'interruption.
    func testTheMouseLineIsDeliveredThroughTheCascade() throws {
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0,
                           memory: X86Memory(size: 1 << 20))
        core.devices.primary.mask = 0
        core.devices.primary.vectorBase = 0x30
        core.devices.secondary.mask = 0
        core.devices.secondary.vectorBase = 0x38
        core.devices.ps2.writeCommand(0xD3)
        core.devices.ps2.writeData(1)
        try core.serviceInterrupts()
        XCTAssertNotEqual(core.devices.primary.request & 0x04, 0, "le second demande par la ligne 2")
        XCTAssertEqual(X86Core.deliverable(core.devices.secondary), 4, "la ligne 12 est la quatrième du second")
        // Une ligne en service bloque ses égales.
        core.devices.secondary.service = 1 << 4
        XCTAssertNil(X86Core.deliverable(core.devices.secondary))
        // La fin d'interruption du second, telle que Linux l'écrit.
        core.portWrite(0xA0, 1, 0x60 | 4)
        XCTAssertEqual(core.devices.secondary.service, 0)
    }
}

/// **Ce qu'on tape devient des touches**, Maj et Ctrl autour.
final class X86KeystrokesTests: XCTestCase {
    private func codes(_ events: [X86Keystrokes.Event]) -> [String] {
        events.map { String(format: "%@%02X%@", $0.code.extended ? "E0 " : "", $0.code.set1, $0.down ? "↓" : "↑") }
    }

    func testTextIsTypedWithShiftWhereNeeded() {
        XCTAssertEqual(codes(X86Keystrokes.typing("aB")), ["1E↓", "1E↑", "2A↓", "30↓", "30↑", "2A↑"])
        XCTAssertEqual(codes(X86Keystrokes.typing("é")), [], "ce qu'un clavier QWERTY n'a pas")
        XCTAssertEqual(codes(X86Keystrokes.typing("\n")), ["1C↓", "1C↑"])
    }

    func testTheBarKeysBecomePCKeys() {
        XCTAssertEqual(codes(X86Keystrokes.key(.up)), ["E0 48↓", "E0 48↑"])
        XCTAssertEqual(codes(X86Keystrokes.key(.control("c"))), ["1D↓", "2E↓", "2E↑", "1D↑"])
        XCTAssertEqual(codes(X86Keystrokes.key(.escape)), ["01↓", "01↑"])
    }

    /// Avec un écran, le noyau y écrit aussi, et la console série reste la
    /// dernière nommée — `/dev/console`.
    func testAScreenAddsTheVirtualConsoleFirst() {
        let line = X86Machine.commandLine("console=ttyS0 quiet", withScreen: true)
        XCTAssertEqual(line, "console=tty0 console=ttyS0 quiet")
        XCTAssertEqual(X86Machine.commandLine("console=ttyS0", withScreen: false), "console=ttyS0")
        XCTAssertEqual(X86Machine.commandLine("console=tty0 console=ttyS0", withScreen: true),
                       "console=tty0 console=ttyS0", "pas deux fois")
    }
}
