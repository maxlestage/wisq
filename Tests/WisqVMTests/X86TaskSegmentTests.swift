import XCTest

@testable import WisqVM

/// **Le segment d'état de tâche, et la pile qu'il porte.**
///
/// La brique que le noyau a nommée en s'arrêtant : une faute de page sur la
/// pile *utilisateur*, levée depuis le code d'entrée du noyau. Le programme
/// n'avait rien fait de mal — c'est le processeur qui aurait dû changer de
/// pile avant d'empiler le cadre, et qui empilait sur celle qu'il trouvait.
///
/// Une pile d'anneau trois n'a aucune raison d'être là où le noyau écrit, ni
/// d'être encore valide au moment où l'interruption tombe. C'est justement
/// pour ça que le mécanisme existe.
final class X86TaskSegmentTests: XCTestCase {
    static let gdt: UInt64 = 0x8000
    static let idt: UInt64 = 0x9000
    static let tss: UInt64 = 0xA000

    /// Une machine avec une GDT, une IDT et un TSS en place.
    static func machine() -> X86Memory { X86Memory(size: 1 << 20, base: 0) }

    /// Le descripteur d'un TSS : seize octets, et une base en quatre morceaux.
    /// C'est cette dispersion qui rend la lecture facile à écrire de travers,
    /// et impossible à voir de travers sans une base dont chaque octet diffère.
    static func installTaskDescriptor(
        _ ram: X86Memory, at selector: UInt16, base: UInt64, limit: UInt64,
        granular: Bool = false
    ) throws {
        var low = (limit & 0xFFFF) | ((base & 0xFF_FFFF) << 16)
        low |= UInt64(0x89) << 40  // présent, type 9 : TSS 64 bits disponible
        low |= ((limit >> 16) & 0x0F) << 48
        if granular { low |= 1 << 55 }
        low |= ((base >> 24) & 0xFF) << 56
        try ram.write(gdt &+ UInt64(selector & ~UInt16(7)), 8, low)
        try ram.write(gdt &+ UInt64(selector & ~UInt16(7)) &+ 8, 8, (base >> 32) & 0xFFFF_FFFF)
    }

    /// Une porte, avec son sélecteur de code et son éventuelle pile
    /// d'interruption.
    static func installGate(
        _ ram: X86Memory, vector: Int, target: UInt64, selector: UInt16 = 0x10,
        interruptStack: Int = 0
    ) throws {
        let low = (target & 0xFFFF) | (UInt64(selector) << 16)
            | (UInt64(interruptStack & 0x07) << 32)
            | (UInt64(0x8E) << 40) | ((target & 0xFFFF_0000) << 32)
        try ram.write(idt &+ UInt64(vector) * 16, 8, low)
        try ram.write(idt &+ UInt64(vector) * 16 &+ 8, 8, (target >> 32) & 0xFFFF_FFFF)
    }

    /// Un cœur dont les tables sont chargées et le TSS rempli.
    static func core(_ ram: X86Memory, privilege: UInt16 = 0) throws -> X86Core {
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x100, memory: ram)
        core.descriptorBases[0] = gdt
        core.descriptorLimits[0] = 0x7F
        core.descriptorBases[1] = idt
        core.descriptorLimits[1] = 0xFFF
        // Le sélecteur de code porte le niveau de privilège : c'est là que le
        // processeur le lit, et nulle part ailleurs.
        core.segments[1] = 0x10 | privilege
        core.segments[2] = 0x18 | privilege
        core.registers[4] = 0x7_0000
        try installTaskDescriptor(ram, at: 0x40, base: tss, limit: 0x206F)
        try core.loadTaskRegister(0x40)
        try ram.write(tss &+ 4, 8, 0x2_0000)  // RSP0
        return core
    }

    // MARK: - Charger le registre de tâche

    /// `LTR` recompose la base depuis ses quatre morceaux. Chaque octet de
    /// l'adresse d'essai est différent : un morceau posé au mauvais endroit se
    /// voit, là où une base ronde le cacherait.
    func testLTRRebuildsTheBaseFromItsFourPieces() throws {
        let ram = Self.machine()
        // Posé **après** `core`, qui installe le sien : l'inverse se ferait
        // écraser en silence et le test passerait sur la mauvaise base.
        var core = try Self.core(ram)
        try Self.installTaskDescriptor(
            ram, at: 0x40, base: 0xFEDC_BA98_7654_3210, limit: 0x1234)
        try core.loadTaskRegister(0x40)
        XCTAssertEqual(core.taskBase, 0xFEDC_BA98_7654_3210)
        XCTAssertEqual(core.taskLimit, 0x1234)
        XCTAssertEqual(core.taskSelector, 0x40)
    }

    /// Le bit de granularité multiplie la limite par la taille d'une page, et
    /// le dernier octet valide est celui du haut de la dernière page.
    func testTheGranularityBitCountsPagesRatherThanBytes() throws {
        let ram = Self.machine()
        var core = try Self.core(ram)
        try Self.installTaskDescriptor(ram, at: 0x40, base: 0x1000, limit: 2, granular: true)
        try core.loadTaskRegister(0x40)
        XCTAssertEqual(core.taskLimit, 0x2FFF)
    }

    /// Un sélecteur nul est **refusé**, et non lu comme l'entrée zéro. Cette
    /// entrée-là est obligatoirement nulle, donc la lire donnerait un TSS à
    /// l'adresse zéro : une pile de noyau au début de la mémoire, ce qui
    /// écrirait sur la table des pages avant que rien ne le signale.
    func testANullSelectorIsRefusedRatherThanRead() throws {
        let ram = Self.machine()
        var core = try Self.core(ram)
        XCTAssertThrowsError(try core.loadTaskRegister(0)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .unsupported("un LTR sur le sélecteur nul"))
        }
    }

    /// Et un sélecteur qui déborde de la GDT aussi.
    func testASelectorPastTheEndOfTheGDTIsRefused() throws {
        let ram = Self.machine()
        var core = try Self.core(ram)
        core.descriptorLimits[0] = 0x3F
        XCTAssertThrowsError(try core.loadTaskRegister(0x40)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .unsupported("un LTR hors de la GDT"))
        }
    }

    /// `STR` rend ce que `LTR` a mis. Sans lui, l'écrire ne serait tenu par
    /// rien du côté de l'invité.
    func testSTRGivesBackWhatLTRTook() throws {
        let ram = Self.machine()
        var core = try Self.core(ram)
        // `0f 00 c8` : str %ax — le r/m désigne RAX, pas le reg.
        try ram.load([0x0F, 0x00, 0xC8], at: 0x100)
        core.registers[0] = 0xFFFF_FFFF_FFFF_0000
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[0] & 0xFFFF, 0x40)
    }

    /// `LTR` par l'instruction, pas seulement par la méthode. Le piège est le
    /// champ lu : dans un groupe, `reg` porte le numéro de l'instruction — ici
    /// trois — et l'opérande est le **r/m**. Les confondre lirait RBX.
    func testLTRReadsItsOperandFromTheRMFieldNotTheReg() throws {
        let ram = Self.machine()
        var core = try Self.core(ram)
        try Self.installTaskDescriptor(ram, at: 0x50, base: 0xBEEF_0000, limit: 0x67)
        // `0f 00 d8` : ltr %ax. Le r/m est RAX ; le reg vaut 3, l'extension.
        try ram.load([0x0F, 0x00, 0xD8], at: 0x100)
        core.registers[0] = 0x50
        core.registers[3] = 0x40  // RBX : ce qu'on lirait en se trompant
        try core.run(budget: 1)
        XCTAssertEqual(core.taskBase, 0xBEEF_0000, "c'est RAX qu'il faut lire")
    }

    // MARK: - Le changement de pile

    /// **Le défaut, nommé.** Une interruption prise en anneau trois empile sur
    /// `RSP0`, pas sur la pile du programme.
    func testAnInterruptFromRingThreeSwitchesToTheKernelStack() throws {
        let ram = Self.machine()
        var core = try Self.core(ram, privilege: 3)
        try Self.installGate(ram, vector: 14, target: 0x5000)
        core.registers[4] = 0x6_0000  // la pile du programme
        XCTAssertTrue(try core.enter(14, errorCode: 0))
        // Six mots empilés — SS, RSP, RFLAGS, CS, RIP, code d'erreur — depuis
        // RSP0 aligné sur seize.
        XCTAssertEqual(core.registers[4], 0x2_0000 - 48)
        XCTAssertEqual(core.rip, 0x5000)
    }

    /// Et c'est bien la pile **d'avant** qui part dans le cadre : c'est elle
    /// que l'`IRETQ` rendra au programme. L'empiler après le changement
    /// rendrait la pile du noyau à un programme d'anneau trois.
    func testTheFrameCarriesTheStackTheProgramWasOn() throws {
        let ram = Self.machine()
        var core = try Self.core(ram, privilege: 3)
        try Self.installGate(ram, vector: 14, target: 0x5000)
        core.registers[4] = 0x6_0000
        core.segments[2] = 0x1B  // le sélecteur de pile de l'anneau trois
        XCTAssertTrue(try core.enter(14, errorCode: 0))
        // Le cadre, du haut vers le bas depuis RSP0 : SS, puis RSP.
        XCTAssertEqual(try ram.read(0x2_0000 - 8, 8), 0x1B)
        XCTAssertEqual(try ram.read(0x2_0000 - 16, 8), 0x6_0000)
    }

    /// Le sélecteur de pile devient nul en entrant, comme le fait le
    /// processeur. Le garder ferait croire au noyau qu'il est encore sur la
    /// pile de l'anneau d'où il vient.
    func testTheStackSelectorBecomesNullOnEntry() throws {
        let ram = Self.machine()
        var core = try Self.core(ram, privilege: 3)
        try Self.installGate(ram, vector: 14, target: 0x5000)
        core.segments[2] = 0x1B
        XCTAssertTrue(try core.enter(14, errorCode: 0))
        XCTAssertEqual(core.segments[2], 0)
    }

    /// **Sans changement de niveau, aucun changement de pile.** Une faute
    /// prise dans le noyau reste sur la pile du noyau : passer par `RSP0`
    /// écraserait le cadre de l'interruption en cours dès la seconde.
    func testAnInterruptTakenInRingZeroKeepsItsStack() throws {
        let ram = Self.machine()
        var core = try Self.core(ram, privilege: 0)
        try Self.installGate(ram, vector: 14, target: 0x5000)
        core.registers[4] = 0x3_0000
        XCTAssertTrue(try core.enter(14, errorCode: 0))
        XCTAssertEqual(core.registers[4], 0x3_0000 - 48)
    }

    /// Une porte qui nomme une pile d'interruption l'impose **même** sans
    /// changement de niveau. C'est ce qui distingue le mode long du 32 bits, et
    /// c'est fait pour les fautes où la pile du noyau est justement le
    /// problème — la double faute, la NMI.
    func testAGateWithAnInterruptStackImposesItEvenInRingZero() throws {
        let ram = Self.machine()
        var core = try Self.core(ram, privilege: 0)
        try ram.write(Self.tss &+ 0x24, 8, 0x4_0000)  // IST1
        try Self.installGate(ram, vector: 8, target: 0x5000, interruptStack: 1)
        core.registers[4] = 0x3_0000
        XCTAssertTrue(try core.enter(8, errorCode: 0))
        XCTAssertEqual(core.registers[4], 0x4_0000 - 48)
    }

    /// Et chaque pile d'interruption est à sa place : la septième est la
    /// dernière, à 0x54. Un décalage d'une seule case rendrait une pile
    /// voisine, ce qui marche jusqu'au jour où les deux servent en même temps.
    func testEachInterruptStackIsAtItsOwnOffset() throws {
        for index in 1...7 {
            let ram = Self.machine()
            var core = try Self.core(ram, privilege: 0)
            let wanted = 0x4_0000 + UInt64(index) * 0x1000
            try ram.write(Self.tss &+ 0x24 &+ UInt64(index - 1) * 8, 8, wanted)
            try Self.installGate(ram, vector: 8, target: 0x5000, interruptStack: index)
            core.registers[4] = 0x3_0000
            XCTAssertTrue(try core.enter(8, errorCode: 0))
            XCTAssertEqual(core.registers[4], wanted - 48, "IST\(index)")
        }
    }

    /// **Un changement de pile sans TSS chargé est refusé**, pas deviné. Sans
    /// registre de tâche il n'y a pas de pile de noyau ; empiler sur zéro
    /// écraserait la table des pages et le noyau partirait dans le décor bien
    /// plus tard, sans rapport visible avec la cause.
    func testWithoutATaskRegisterTheSwitchIsRefusedRatherThanGuessed() throws {
        let ram = Self.machine()
        var core = try Self.core(ram, privilege: 3)
        core.taskSelector = 0
        core.taskBase = 0
        core.taskLimit = 0
        try Self.installGate(ram, vector: 14, target: 0x5000)
        // **La faute exacte, pas « une faute ».** Le sabotage a montré que ce
        // test passait sans la garde : sans elle, le cœur lit une pile à
        // l'adresse quatre, y trouve zéro, et l'empilement sort de la mémoire
        // — donc il lève quand même, mais un `outsideMemory` qui envoie
        // chercher du côté de la RAM au lieu du registre de tâche.
        XCTAssertThrowsError(try core.enter(14, errorCode: 0)) { error in
            XCTAssertEqual(error as? X86Core.Fault,
                           .unsupported("un changement de pile sans TSS chargé"))
        }
    }

    /// Un TSS trop court pour porter ses piles est refusé de même : lire
    /// au-delà de sa limite rendrait des octets qui ne sont pas des piles.
    func testATaskSegmentTooShortToHoldItsStacksIsRefused() throws {
        let ram = Self.machine()
        var core = try Self.core(ram, privilege: 3)
        core.taskLimit = 0x20
        try Self.installGate(ram, vector: 14, target: 0x5000)
        XCTAssertThrowsError(try core.enter(14, errorCode: 0)) { error in
            XCTAssertEqual(error as? X86Core.Fault,
                           .unsupported("un changement de pile sans TSS chargé"))
        }
    }

    // MARK: - L'aller-retour complet

    /// **Anneau trois, interruption, retour.** Le vrai contrat : le programme
    /// repart exactement où il en était, sur sa propre pile, à son propre
    /// niveau — et le noyau a travaillé sur la sienne entre-temps.
    func testAProgramComesBackToItsOwnStackAndItsOwnRing() throws {
        let ram = Self.machine()
        var core = try Self.core(ram, privilege: 3)
        // Le gestionnaire : `48 83 c4 08` (add $8,%rsp, pour le code d'erreur)
        // puis `48 cf` (iretq).
        try ram.load([0x48, 0x83, 0xC4, 0x08, 0x48, 0xCF], at: 0x5000)
        try Self.installGate(ram, vector: 14, target: 0x5000)
        core.registers[4] = 0x6_0000
        core.segments[2] = 0x1B
        core.rip = 0x1234
        XCTAssertTrue(try core.enter(14, errorCode: 0))

        try core.run(budget: 2)
        XCTAssertEqual(core.rip, 0x1234, "l'adresse de reprise")
        XCTAssertEqual(core.registers[4], 0x6_0000, "sa propre pile")
        XCTAssertEqual(core.segments[2], 0x1B, "son propre sélecteur de pile")
        XCTAssertEqual(core.privilege, 3, "son propre anneau")
    }
}
