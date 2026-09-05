import Foundation
import WisqVM
import WisqVMRust
import WisqVMTestKit
import XCTest

/// Les deux cœurs, sur la ligne d'interruption externe.
///
/// **Pourquoi ce fichier existe.** Le cœur Swift a appris la ligne externe le
/// premier ; le cœur Rust ne connaissait que celle du timer. Or c'est le cœur
/// Rust qui tourne sur le téléphone. Sans cette tranche, un disque branché
/// depuis l'application aurait servi ses requêtes sans que personne ne
/// l'apprenne à l'invité — et le seul symptôme aurait été un invité qui attend
/// pour toujours.
///
/// **Et pourquoi l'invité lève sa propre ligne.** Le périphérique virtio
/// n'existe pas encore côté Rust ; on ne peut donc pas la lever depuis
/// l'extérieur des deux côtés à la fois. Mais `mip` est un CSR, et un invité
/// en mode machine a le droit d'y écrire : la ligne se lève de l'intérieur,
/// par la même instruction sur les deux cœurs, et c'est bien la livraison qui
/// est mesurée — pas ce qui l'a demandée.
///
/// La comparaison porte sur ce que l'invité imprime, sur ce que chaque cœur
/// répond, et sur l'instantané complet : deux interprètes d'accord sur la
/// console mais pas sur `mepc` ne sont pas d'accord.
final class DifferentialExternalInterruptTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var swiftConsole = Data()
        var rustConsole = Data()
        var swiftSnapshot = Data()
        var rustSnapshot = Data()
        let lock = NSLock()
        func append(swift chunk: Data) { lock.lock(); swiftConsole.append(chunk); lock.unlock() }
        func append(rust chunk: Data) { lock.lock(); rustConsole.append(chunk); lock.unlock() }
    }

    // MARK: - La carte, et les registres

    private static let uart: UInt32 = 0x1000_0000
    /// Le `mtimecmp` du CLINT, là où `LinuxMachine` le lit.
    private static let timerCompare: UInt32 = 0x1100_4000
    private static let handlerOffset = 0x200

    private static let tty = 2, clint = 3, tmp = 5, line = 6
    private static let out = 7, seen = 8, cause = 9, flag = 10

    /// Là où le gestionnaire pose sa marque, dans la RAM de l'invité.
    ///
    /// **L'invité doit l'attendre.** Le piège n'est pris qu'entre deux
    /// tranches d'instructions, pas entre deux instructions : lever la ligne
    /// puis imprimer tout de suite ferait imprimer avant le gestionnaire, et
    /// le test mesurerait l'ordre du découpage plutôt que la livraison.
    private static let flagAddress: UInt32 = 0x8000_7000

    /// L'invité lève sa propre ligne externe, et l'attend.
    ///
    /// Sortie attendue : `EA\n`. Le `E` vient du gestionnaire — donc la
    /// livraison a eu lieu ; le `A` vient de l'instruction qui suivait celle
    /// qui a levé la ligne — donc `mepc` désignait la bonne, et `mret` y est
    /// revenu. Une console vide veut dire que la ligne n'a rien fait ; un `A`
    /// seul, que le gestionnaire n'a jamais tourné.
    private static func raisesItsOwnLine() -> [UInt32] {
        typealias Asm = RV32Asm
        var code: [UInt32] = [
            Asm.lui(tty, uart >> 12),
            Asm.lui(flag, flagAddress >> 12),
            Asm.sw(0, 0, flag),
            Asm.lui(tmp, 0x80000),
            Asm.addi(tmp, tmp, Int32(handlerOffset)),
            Asm.csrw(Asm.mtvec, tmp),
            Asm.addi(tmp, 0, 1),
            Asm.slli(tmp, tmp, 11),
            Asm.csrw(Asm.mie, tmp),                  // MEIE seul
            Asm.addi(tmp, 0, 8),
            Asm.csrw(Asm.mstatus, tmp),              // MIE
            Asm.addi(line, 0, 1),
            Asm.slli(line, line, 11),
            Asm.csrw(Asm.mip, line),                 // et on la lève
            Asm.lw(seen, 0, flag),                   // puis on attend
            Asm.beq(seen, 0, -4),
            Asm.addi(out, 0, 0x41),                  // 'A' : après le retour
            Asm.sb(out, 0, tty),
            Asm.addi(out, 0, 10),
            Asm.sb(out, 0, tty),
            Asm.beq(0, 0, 0),
        ]
        while code.count * 4 < handlerOffset { code.append(Asm.addi(0, 0, 0)) }
        code += [
            Asm.addi(seen, 0, 0x45),                 // 'E'
            Asm.sb(seen, 0, tty),
            // Sans ce nettoyage la ligne reste levée et le gestionnaire est
            // rappelé sans fin : `mip` n'est pas effacé par la prise du piège.
            Asm.csrw(Asm.mip, 0),
            Asm.addi(seen, 0, 1),
            Asm.sw(seen, 0, flag),
            Asm.mret,
        ]
        return code
    }

    /// Les deux lignes en attente au même instant, et laquelle passe devant.
    ///
    /// Sortie attendue : `EK\n`, où le `E` est `'0' + mcause` décalé — il vaut
    /// `E` pour la cause onze (externe) et `A` pour la sept (timer). C'est
    /// donc la lettre elle-même qui dit qui a gagné.
    ///
    /// L'invité **attend de voir MTIP** avant d'ouvrir la porte : armer le
    /// timer puis lever la ligne externe tout de suite laisserait la course se
    /// jouer sur le hasard du découpage en tranches, et le test passerait sans
    /// avoir rien mesuré.
    private static func bothLinesAtOnce() -> [UInt32] {
        typealias Asm = RV32Asm
        var code: [UInt32] = [
            Asm.lui(tty, uart >> 12),
            Asm.lui(clint, timerCompare >> 12),
            Asm.lui(flag, flagAddress >> 12),
            Asm.sw(0, 0, flag),
            Asm.lui(tmp, 0x80000),
            Asm.addi(tmp, tmp, Int32(handlerOffset)),
            Asm.csrw(Asm.mtvec, tmp),
            // Le timer, armé au plus tôt. Zéro ne l'armerait pas : les deux
            // cœurs traitent « mtimecmp nul » comme « pas de timer ».
            Asm.addi(tmp, 0, 1),
            Asm.sw(tmp, 0, clint),
            Asm.sw(0, 4, clint),
            // Tourner, la porte fermée, jusqu'à ce que MTIP soit là.
            Asm.csrr(seen, Asm.mip),
            Asm.andi(seen, seen, 0x80),
            Asm.beq(seen, 0, -8),
            // Les deux en attente. On lève l'externe…
            Asm.addi(line, 0, 1),
            Asm.slli(line, line, 11),
            Asm.csrw(Asm.mip, line),
            // …on autorise les deux…
            Asm.addi(tmp, 0, 1),
            Asm.slli(tmp, tmp, 11),
            Asm.addi(tmp, tmp, 128),                 // MEIE | MTIE
            Asm.csrw(Asm.mie, tmp),
            // …et seulement là on ouvre la porte.
            Asm.addi(tmp, 0, 8),
            Asm.csrw(Asm.mstatus, tmp),
            Asm.lw(seen, 0, flag),                   // et on attend le verdict
            Asm.beq(seen, 0, -4),
            Asm.addi(out, 0, 0x4B),                  // 'K'
            Asm.sb(out, 0, tty),
            Asm.addi(out, 0, 10),
            Asm.sb(out, 0, tty),
            Asm.beq(0, 0, 0),
        ]
        while code.count * 4 < handlerOffset { code.append(Asm.addi(0, 0, 0)) }
        code += [
            Asm.csrr(cause, Asm.mcause),
            Asm.andi(cause, cause, 0xF),
            Asm.addi(cause, cause, 0x3A),            // 11 → 'E', 7 → 'A'
            Asm.sb(cause, 0, tty),
            Asm.csrw(Asm.mip, 0),
            // Et on désarme le timer, sinon il rappelle le gestionnaire dès
            // le retour et l'invité n'imprime plus jamais autre chose.
            Asm.sw(0, 0, clint),
            Asm.sw(0, 4, clint),
            Asm.addi(cause, 0, 1),
            Asm.sw(cause, 0, flag),
            Asm.mret,
        ]
        return code
    }

    // MARK: - Les deux cœurs, le même programme

    private func compare(_ program: [UInt32], expecting console: String,
                         budget: UInt64 = 2_000_000) throws {
        let bytes = RV32Asm.image(program)
        let box = Box()

        let swiftMachine = LinuxMachine { box.append(swift: $0) }
        try swiftMachine.load(kernelImage: bytes)
        _ = swiftMachine.run(instructionBudget: budget)
        box.swiftSnapshot = swiftMachine.snapshot()

        let rustMachine = RustLinuxMachine { box.append(rust: $0) }
        try rustMachine.loadOnTheSameBoard(kernelImage: bytes)
        _ = rustMachine.run(instructionBudget: budget)
        box.rustSnapshot = rustMachine.snapshot()

        let swiftText = String(decoding: box.swiftConsole, as: UTF8.self)
        let rustText = String(decoding: box.rustConsole, as: UTF8.self)
        XCTAssertEqual(swiftText, console, "le cœur Swift")
        XCTAssertEqual(rustText, console, "le cœur Rust")
        XCTAssertEqual(box.swiftSnapshot, box.rustSnapshot,
                       "même console ne suffit pas : les deux états doivent coïncider")
    }

    func testBothCoresDeliverAnExternalInterruptAndReturnToTheRightInstruction() throws {
        try compare(Self.raisesItsOwnLine(), expecting: "EA\n")
    }

    func testBothCoresLetTheExternalLineOutrankTheTimer() throws {
        try compare(Self.bothLinesAtOnce(), expecting: "EK\n")
    }
}
