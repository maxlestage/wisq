import XCTest

@testable import WisqVM

/// Le port série tel que le pilote 8250 de Linux le **sonde**, et pas
/// seulement tel que `printk` l'écrit.
///
/// **Ce que la mesure a montré.** Sous QEMU, le noyau d'Alpine écrit
/// « ttyS0 at I/O 0x3f8 (irq = 4, base_baud = 115200) is a 16550A », puis
/// l'init imprime « * Mounting boot media: » sur sa console. Sous wisq, la
/// première ligne manque et aucune des lignes de l'init n'apparaît : le
/// `printk` du noyau passe — il écrit le port directement — mais le pilote
/// n'a jamais **enregistré** le port comme terminal, donc `/dev/console`
/// n'existe pour personne en espace utilisateur.
///
/// Le pilote ne demande pas grand-chose pour croire à un port, mais il le
/// demande dans l'ordre, et chaque test ci-dessous est une étape de sa sonde
/// (`autoconfig` dans `8250_port.c`) : le registre d'autorisation doit se
/// relire, la boucle de test du modem doit renvoyer les deux bits attendus,
/// le registre de brouillon doit garder ce qu'on y met, et le registre
/// d'identification doit dire s'il y a une FIFO. Puis, pour que l'espace
/// utilisateur écrive, l'interruption d'émission doit **arriver** : sans
/// elle, le pilote pose les octets dans un tampon et attend qu'on vienne
/// les chercher.
final class X86SerialPortTests: XCTestCase {
    static let base: UInt16 = 0x3F8

    static func core() -> X86Core {
        let memory = X86Memory(size: 0x1000, base: 0)
        return X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0, memory: memory)
    }

    // MARK: - La sonde d'existence

    /// **Le premier test du pilote, et celui que wisq échouait.** Il écrit 0
    /// puis 0x0F dans le registre d'autorisation et relit chaque fois ; si
    /// l'un des deux ne revient pas, « there's nothing here ».
    func testTheInterruptEnableRegisterReadsBackWhatWasWritten() {
        var core = Self.core()
        core.portWrite(Self.base &+ 1, 0)
        XCTAssertEqual(core.portRead(Self.base &+ 1) & 0x0F, 0)
        core.portWrite(Self.base &+ 1, 0x0F)
        XCTAssertEqual(core.portRead(Self.base &+ 1) & 0x0F, 0x0F)
    }

    /// Le second : en mode boucle, les sorties du registre de commande du
    /// modem reviennent sur les entrées du registre d'état. Le pilote écrit
    /// `LOOP | OUT2 | RTS` et attend `DCD | CTS`, exactement 0x90 sur les
    /// quatre bits hauts.
    func testLoopbackReflectsModemControlIntoModemStatus() {
        var core = Self.core()
        core.portWrite(Self.base &+ 4, 0x1A)
        XCTAssertEqual(core.portRead(Self.base &+ 6) & 0xF0, 0x90)
        // Et chaque ligne trouve la sienne : DTR → DSR, OUT1 → RI.
        core.portWrite(Self.base &+ 4, 0x15)
        XCTAssertEqual(core.portRead(Self.base &+ 6) & 0xF0, 0x60)
    }

    /// Hors boucle, un câble branché : porteuse, prêt, libre d'émettre. Un
    /// terminal ouvert sans `CLOCAL` attendrait la porteuse indéfiniment.
    func testOutsideLoopbackTheModemLinesReadAsAConnectedCable() {
        var core = Self.core()
        core.portWrite(Self.base &+ 4, 0x0B)
        XCTAssertEqual(core.portRead(Self.base &+ 6) & 0xF0, 0xB0)
    }

    /// Le registre de brouillon distingue un 16450 d'un 8250 : il n'a pas
    /// d'autre rôle que de garder ce qu'on y met.
    func testTheScratchRegisterHolds() {
        var core = Self.core()
        core.portWrite(Self.base &+ 7, 0xA5)
        XCTAssertEqual(core.portRead(Self.base &+ 7), 0xA5)
        core.portWrite(Self.base &+ 7, 0x5A)
        XCTAssertEqual(core.portRead(Self.base &+ 7), 0x5A)
    }

    /// FIFO activée, les deux bits hauts du registre d'identification disent
    /// « 16550A » ; c'est ce que QEMU annonce, et ce que le pilote prend sans
    /// autre question quand les variantes ne sont pas compilées.
    func testAnEnabledFIFOReadsAsA16550A() {
        var core = Self.core()
        XCTAssertEqual(core.portRead(Self.base &+ 2) >> 6, 0, "sans FIFO : un 8250")
        core.portWrite(Self.base &+ 2, 0x01)
        XCTAssertEqual(core.portRead(Self.base &+ 2) >> 6, 3)
    }

    /// Le diviseur se lit et s'écrit derrière `DLAB`, et **ne touche pas** au
    /// registre d'autorisation ni au tampon de sortie qui partagent ses
    /// adresses.
    func testTheDivisorLatchHidesBehindDLAB() {
        var core = Self.core()
        core.portWrite(Self.base &+ 1, 0x05)  // IER
        core.portWrite(Self.base &+ 3, 0x80)  // DLAB
        core.portWrite(Self.base, 0x0C)
        core.portWrite(Self.base &+ 1, 0x00)
        XCTAssertEqual(core.portRead(Self.base), 0x0C)
        XCTAssertEqual(core.portRead(Self.base &+ 1), 0x00)
        XCTAssertEqual(core.devices.serial.divisor, 0x000C, "115 200 bauds")
        core.portWrite(Self.base &+ 3, 0x03)  // DLAB retombé
        XCTAssertEqual(core.portRead(Self.base &+ 1) & 0x0F, 0x05, "l'IER est intact")
        XCTAssertTrue(core.serialOutput.isEmpty, "rien n'est sorti sur la ligne")
    }

    // MARK: - L'interruption d'émission

    /// Autoriser l'interruption d'émission quand le transmetteur est vide la
    /// **lève** — c'est le test que `serial8250_do_startup` fait deux fois de
    /// suite, et si elle ne revient pas la seconde fois il installe un
    /// minuteur de secours au lieu de compter sur elle.
    func testEnablingTheTransmitInterruptRaisesItAndReadingIIRClearsIt() {
        var core = Self.core()
        core.portWrite(Self.base &+ 1, 0x02)
        XCTAssertTrue(core.serialInterrupting)
        XCTAssertEqual(core.portRead(Self.base &+ 2) & 0x0F, 0x02, "émetteur vide")
        XCTAssertFalse(core.serialInterrupting, "lire l'identification l'acquitte")
        XCTAssertEqual(core.portRead(Self.base &+ 2) & 0x0F, 0x01, "plus rien en attente")

        core.portWrite(Self.base &+ 1, 0x00)
        core.portWrite(Self.base &+ 1, 0x02)
        XCTAssertEqual(core.portRead(Self.base &+ 2) & 0x0F, 0x02, "et la réautoriser la relève")
    }

    /// Chaque octet écrit vide de nouveau le transmetteur, donc relève
    /// l'interruption : c'est ainsi que le pilote enchaîne ses seize octets
    /// par seize sans jamais interroger le port.
    func testWritingAByteRaisesTheTransmitInterruptAgain() {
        var core = Self.core()
        core.portWrite(Self.base &+ 1, 0x02)
        _ = core.portRead(Self.base &+ 2)
        XCTAssertFalse(core.serialInterrupting)
        core.portWrite(Self.base, 0x41)
        XCTAssertEqual(core.serialOutput, [0x41])
        XCTAssertTrue(core.serialInterrupting)
    }

    /// Interruption non autorisée : rien ne demande, quoi qu'on écrive.
    func testNothingInterruptsWhenNothingIsEnabled() {
        var core = Self.core()
        core.portWrite(Self.base, 0x41)
        core.serialInput = [0x42]
        XCTAssertFalse(core.serialInterrupting)
        XCTAssertEqual(core.portRead(Self.base &+ 2) & 0x0F, 0x01)
    }

    /// Un octet reçu, interruption de réception autorisée : elle passe
    /// **avant** l'émission dans l'identification, comme sur la puce.
    func testReceivedDataInterruptsAndOutranksTransmit() {
        var core = Self.core()
        core.portWrite(Self.base &+ 1, 0x03)
        core.serialInput = [0x42]
        XCTAssertEqual(core.portRead(Self.base &+ 2) & 0x0F, 0x04)
        XCTAssertEqual(core.portRead(Self.base), 0x42, "l'octet est lu")
        XCTAssertEqual(core.portRead(Self.base &+ 2) & 0x0F, 0x02, "reste l'émission")
    }

    // MARK: - Jusqu'au processeur

    /// La ligne quatre du 8259, au vecteur que Linux lui donne : 0x34. Le
    /// programme autorise l'émission puis boucle ; le gestionnaire est un
    /// `hlt`.
    func testTheTransmitInterruptReachesTheHandlerOnLineFour() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // `b0 02` mov $2,%al ; `66 ba f9 03` mov $0x3f9,%dx ; `ee` out ;
        // `eb fe` jmp .
        try ram.load([0xB0, 0x02, 0x66, 0xBA, 0xF9, 0x03, 0xEE, 0xEB, 0xFE], at: 0x100)
        try ram.load([0xF4], at: 0x8000)
        let low = (UInt64(0x8000) & 0xFFFF) | (UInt64(0x10) << 16) | (UInt64(0x8E) << 40)
        try ram.write(0x9000 &+ 0x34 * 16, 8, low)
        try ram.write(0x9000 &+ 0x34 * 16 &+ 8, 8, 0)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x100, memory: ram)
        core.descriptorBases[1] = 0x9000
        core.descriptorLimits[1] = 0xFFF
        core.registers[4] = 0x7000
        core.devices.primary.mask = 0xEF
        core.devices.primary.vectorBase = 0x30
        core.flags |= X86Core.Flag.interrupt
        try core.run(budget: 500)
        XCTAssertTrue(core.halted, "le gestionnaire s'arrête sur un HLT")
        XCTAssertEqual(core.rip, 0x8001)
        XCTAssertEqual(core.devices.primary.service, 0x10, "la ligne quatre est en service")
    }

    /// Et une machine endormie sur `hlt`, horloge **non** armée, est réveillée
    /// par le port : c'est un second réveil possible, et le dire évite de
    /// déclarer morte une machine qui attend une frappe.
    func testTheSerialPortAloneCanWakeAHaltedMachine() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try ram.load([0xF4], at: 0x100)
        try ram.load([0xF4], at: 0x8000)
        let low = (UInt64(0x8000) & 0xFFFF) | (UInt64(0x10) << 16) | (UInt64(0x8E) << 40)
        try ram.write(0x9000 &+ 0x34 * 16, 8, low)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x100, memory: ram)
        core.descriptorBases[1] = 0x9000
        core.descriptorLimits[1] = 0xFFF
        core.registers[4] = 0x7000
        core.devices.primary.mask = 0xEF
        core.devices.primary.vectorBase = 0x30
        core.flags |= X86Core.Flag.interrupt
        core.devices.serial.interruptEnable = 0x01  // réception autorisée
        XCTAssertEqual(core.devices.reload, 0, "pas d'horloge")
        try core.run(budget: 3)
        XCTAssertTrue(core.halted)
        XCTAssertEqual(core.rip, 0x101, "endormie, rien n'est arrivé")

        core.serialInput = [0x0A]
        core.halted = false
        core.rip = 0x100
        try core.run(budget: 10, waiting: 100)
        XCTAssertEqual(core.rip, 0x8001, "la frappe l'a réveillée")
    }
}
