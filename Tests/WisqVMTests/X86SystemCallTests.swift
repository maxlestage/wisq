import XCTest

@testable import WisqVM

/// `SYSCALL` et `SYSRET`, écrits à la main contre le manuel.
///
/// **C'est le second endroit du cœur qui ne soit pas prouvé contre la
/// machine**, après la division par zéro, et il faut le dire plutôt que le
/// laisser croire : un `SYSCALL` dans le harnais de l'oracle entrerait dans le
/// noyau de l'hôte au lieu de répondre, et un `SYSRET` partirait en anneau
/// trois avec des sélecteurs qui n'existent pas. Aucun état ne reviendrait ;
/// le harnais mourrait.
///
/// Chaque test nomme donc ce qu'il tient, et le sabotage vérifie qu'il le
/// tient vraiment.
final class X86SystemCallTests: XCTestCase {
    /// Les valeurs que Linux met dans `STAR` : le code du noyau à 0x10, celui
    /// de l'espace utilisateur à 0x23 — parce que le processeur y ajoutera
    /// seize pour le code 64 bits, ce qui donne 0x33, et huit pour la pile,
    /// 0x2B. Ce sont les sélecteurs qu'on voit dans un `Oops`.
    static let kernelCode: UInt16 = 0x10
    static let userBase: UInt16 = 0x23
    static let handler: UInt64 = 0xFFFF_8000_0010_0000

    static func core(_ code: [UInt8], enabled: Bool = true) throws -> X86Core {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try ram.load(code, at: 0x100)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x100, memory: ram)
        core.system.modelSpecific[X86SystemState.star] =
            UInt64(kernelCode) << 32 | UInt64(userBase) << 48
        core.system.modelSpecific[X86SystemState.longSystemCallTarget] = handler
        core.system.modelSpecific[X86SystemState.systemCallFlagMask] =
            X86Core.Flag.interrupt | X86Core.Flag.direction
        if enabled {
            core.system.modelSpecific[X86SystemState.efer] = X86SystemState.systemCallEnable
        }
        core.segments[1] = 0x33  // le programme tourne en anneau trois
        core.segments[2] = 0x2B
        return core
    }

    // MARK: - L'entrée

    /// **L'adresse de retour est celle de la suite, pas celle de l'appel.**
    /// Les confondre ferait boucler le programme sur son propre `SYSCALL`, à
    /// l'infini et sans rien signaler.
    func testTheReturnAddressIsTheNextInstruction() throws {
        var core = try Self.core([0x0F, 0x05])
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[1], 0x102, "RCX : 0x100 plus les deux octets")
        XCTAssertEqual(core.rip, Self.handler)
    }

    /// Les drapeaux partent dans R11 **avant** d'être masqués : c'est cette
    /// copie-là que `SYSRET` rendra, et la masquer aussi rendrait au programme
    /// un état qui n'était pas le sien.
    func testTheFlagsAreSavedBeforeTheyAreMasked() throws {
        var core = try Self.core([0x0F, 0x05])
        core.flags = X86Core.Flag.interrupt | X86Core.Flag.direction
            | X86Core.Flag.carry | X86Core.Flag.reserved
        try core.run(budget: 1)
        XCTAssertNotEqual(core.registers[11] & X86Core.Flag.interrupt, 0,
                          "R11 garde le bit d'interruption")
        XCTAssertNotEqual(core.registers[11] & X86Core.Flag.direction, 0)
        XCTAssertEqual(core.flags & X86Core.Flag.interrupt, 0,
                       "mais le noyau entre les interruptions fermées")
        XCTAssertEqual(core.flags & X86Core.Flag.direction, 0)
        XCTAssertNotEqual(core.flags & X86Core.Flag.carry, 0,
                          "et ce que le masque ne nomme pas ne bouge pas")
    }

    /// Les sélecteurs viennent de `STAR`, **forcés à l'anneau zéro**. Recopier
    /// sans masquer laisserait le privilège d'un MSR décider du privilège du
    /// noyau.
    func testTheSelectorsComeFromStarAndAreForcedToRingZero() throws {
        var core = try Self.core([0x0F, 0x05])
        // Un noyau distrait qui aurait laissé traîner un anneau dans STAR.
        core.system.modelSpecific[X86SystemState.star] =
            UInt64(Self.kernelCode | 3) << 32 | UInt64(Self.userBase) << 48
        try core.run(budget: 1)
        XCTAssertEqual(core.segments[1], 0x10, "CS : le sélecteur d'entrée, anneau zéro")
        XCTAssertEqual(core.segments[2], 0x18, "SS : celui-là plus huit")
        XCTAssertEqual(core.privilege, 0)
    }

    /// **La pile ne change pas.** C'est ce qui distingue `SYSCALL` d'une
    /// interruption : RSP reste celui du programme, et c'est au noyau d'aller
    /// chercher la sienne — d'où le `SWAPGS` en tête de son gestionnaire. Un
    /// cœur qui changerait la pile ici le ferait travailler sur une pile qu'il
    /// croit encore devoir remplacer.
    func testTheStackIsNotSwitched() throws {
        var core = try Self.core([0x0F, 0x05])
        core.registers[4] = 0x7_F000
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[4], 0x7_F000, "RSP est toujours celui du programme")
    }

    /// Et rien n'est empilé non plus : le programme ne doit rien trouver de
    /// changé sous sa pile en revenant.
    func testNothingIsPushed() throws {
        var core = try Self.core([0x0F, 0x05])
        core.registers[4] = 0x7_F000
        let memory = try XCTUnwrap(core.memory)
        try memory.write(0x7_EFF8, 8, 0xFEED_FACE)
        try core.run(budget: 1)
        XCTAssertEqual(try memory.read(0x7_EFF8, 8), 0xFEED_FACE)
    }

    /// **Sans EFER.SCE, c'est refusé.** Ce n'est pas une limite de ce cœur
    /// mais une vraie règle : un programme qui appelle avant que le noyau ait
    /// ouvert la porte doit être arrêté, pas servi.
    func testWithoutTheEnableBitTheCallIsRefused() throws {
        var core = try Self.core([0x0F, 0x05], enabled: false)
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .unsupported("un SYSCALL sans EFER.SCE"))
        }
        XCTAssertEqual(core.rip, 0x100, "et rien n'a bougé avant de refuser")
    }

    // MARK: - Le retour

    /// `SYSRET` rend l'adresse de RCX et les drapeaux de R11, en anneau trois.
    func testTheReturnRestoresTheProgramWhereItWas() throws {
        // `48 0f 07` : sysretq — REX.W, sinon c'est le retour 32 bits.
        var core = try Self.core([0x48, 0x0F, 0x07])
        core.segments[1] = 0x10
        core.segments[2] = 0x18
        core.registers[1] = 0x4000
        core.registers[11] = X86Core.Flag.interrupt | X86Core.Flag.carry | X86Core.Flag.reserved
        try core.run(budget: 1)
        XCTAssertEqual(core.rip, 0x4000)
        XCTAssertNotEqual(core.flags & X86Core.Flag.interrupt, 0)
        XCTAssertNotEqual(core.flags & X86Core.Flag.carry, 0)
        XCTAssertEqual(core.privilege, 3, "le programme retrouve son anneau")
    }

    /// **Les décalages du retour ne sont pas ceux de l'entrée.** Le processeur
    /// ajoute seize au sélecteur de sortie pour le code et huit pour la pile,
    /// parce qu'un noyau range dans cet ordre le code 32 bits puis le 64 bits
    /// de l'espace utilisateur. Se tromper rendrait la main sous un segment
    /// 32 bits, et le programme lirait ses propres octets de travers.
    func testTheReturnSelectorsAreSixteenAndEightPastTheExitBase() throws {
        var core = try Self.core([0x48, 0x0F, 0x07])
        core.segments[1] = 0x10
        core.segments[2] = 0x18
        try core.run(budget: 1)
        XCTAssertEqual(core.segments[1], 0x33, "CS : 0x23 + 16, anneau trois")
        XCTAssertEqual(core.segments[2], 0x2B, "SS : 0x23 + 8, anneau trois")
    }

    /// Un `SYSRET` sans REX.W vise le mode compatibilité, que ce cœur ne fait
    /// pas tourner. Il est **refusé et nommé** plutôt que traité comme son
    /// voisin 64 bits : rendre la main sous un segment 32 bits à un programme
    /// qui en attend un de 64 le ferait partir dans le décor.
    func testTheCompatibilityReturnIsRefusedRatherThanTakenForTheWideOne() throws {
        var core = try Self.core([0x0F, 0x07])
        core.segments[1] = 0x10
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            XCTAssertEqual(error as? X86Core.Fault,
                           .unsupported("un SYSRET vers le mode compatibilité"))
        }
        XCTAssertEqual(core.segments[1], 0x10, "et rien n'a bougé avant de refuser")
    }

    // MARK: - L'aller-retour

    /// **Le vrai contrat** : un programme appelle, le noyau lui rend la main,
    /// et il repart exactement où il en était, dans son anneau, avec ses
    /// drapeaux et sa pile.
    func testAProgramComesBackWhereItWas() throws {
        var core = try Self.core([0x0F, 0x05])
        // Le gestionnaire vit ici plutôt qu'à l'adresse haute des autres
        // tests : ceux-là ne font que poser RIP, celui-ci l'**exécute**, et il
        // faut donc qu'elle tienne dans la mémoire de l'essai.
        core.system.modelSpecific[X86SystemState.longSystemCallTarget] = 0x2000
        let memory = try XCTUnwrap(core.memory)
        try memory.load([0x48, 0x0F, 0x07], at: 0x2000)  // sysretq, et rien d'autre
        core.registers[4] = 0x7_F000
        core.flags = X86Core.Flag.interrupt | X86Core.Flag.carry | X86Core.Flag.reserved

        try core.run(budget: 2)
        XCTAssertEqual(core.rip, 0x102, "l'instruction qui suivait l'appel")
        XCTAssertEqual(core.privilege, 3)
        XCTAssertEqual(core.registers[4], 0x7_F000)
        XCTAssertNotEqual(core.flags & X86Core.Flag.interrupt, 0,
                          "les interruptions rouvertes en sortant")
        XCTAssertNotEqual(core.flags & X86Core.Flag.carry, 0)
    }
}
