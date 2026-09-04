import XCTest

@testable import WisqVM

/// Ce que l'oracle matériel ne peut pas dire des registres XMM.
///
/// `X86VectorOracleTests` tient 832 cas contre le vrai processeur, et c'est la
/// preuve la plus forte qui existe pour ce qui **aboutit**. Restent deux
/// choses qu'un harnais qui exécute ne peut pas produire : un accès qui sort
/// de la mémoire — il tuerait le harnais au lieu de répondre — et le refus
/// d'une forme que ce cœur n'écrit pas encore. Les deux sont ici.
final class X86VectorTests: XCTestCase {
    /// Une mémoire dont la fin est exactement à la fin d'une instruction.
    static func memory(_ code: [UInt8], size: Int = 1 << 16) throws -> X86Memory {
        let ram = X86Memory(size: size, base: 0)
        try ram.load(code, at: 0x100)
        return ram
    }

    static func core(_ ram: X86Memory) -> X86Core {
        X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x100, memory: ram)
    }

    /// **Une lecture de huit octets ne lit pas seize.** La distinction est
    /// invisible dans un registre — la forme qui lit huit octets efface le
    /// haut de sa destination elle-même — et parfaitement visible au bord de
    /// la mémoire : huit octets tiennent, seize non.
    ///
    /// Sans cette garde, un `MOVQ` sur les huit derniers octets d'une
    /// cartographie ferait une faute que la vraie machine ne fait pas.
    func testAnEightByteReadDoesNotReachPastItsOperand() throws {
        let size = 1 << 16
        let ram = try Self.memory([0xF3, 0x0F, 0x7E, 0x06])  // movq (%rsi),%xmm0
        try ram.write(UInt64(size - 8), 8, 0x0123_4567_89AB_CDEF)
        var core = Self.core(ram)
        core.registers[6] = UInt64(size - 8)
        core.setVector(0, 0xDEAD, 0xBEEF)
        try core.run(budget: 1)
        XCTAssertEqual(core.vectors[0], 0x0123_4567_89AB_CDEF)
        XCTAssertEqual(core.vectors[1], 0, "le haut est effacé, pas conservé")
    }

    /// Et la même lecture sur seize octets, elle, sort — ce qui est la moitié
    /// du test au-dessus : sans elle, une lecture qui déborderait toujours
    /// passerait pour prudente.
    func testASixteenByteReadAtTheSamePlaceRunsOut() throws {
        let size = 1 << 16
        let ram = try Self.memory([0x66, 0x0F, 0x6F, 0x06])  // movdqa (%rsi),%xmm0
        var core = Self.core(ram)
        core.registers[6] = UInt64(size - 8)
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .outsideMemory(UInt64(size)))
        }
    }

    /// **Une forme scalaire est refusée, et nommée.** `MOVSS` et `MOVSD`
    /// partagent leurs octets avec `MOVUPS` — seul le préfixe les sépare — et
    /// elles n'écrivent qu'une partie du registre. Les confondre écraserait ce
    /// que le programme voulait garder, sans rien signaler ; le refus, lui,
    /// dira quelle brique poser le jour où le noyau la demandera.
    func testAScalarMoveIsRefusedRatherThanTakenForItsWideNeighbour() throws {
        for prefix in [UInt8(0xF3), UInt8(0xF2)] {
            let ram = try Self.memory([prefix, 0x0F, 0x10, 0xC1])  // movss/movsd %xmm1,%xmm0
            var core = Self.core(ram)
            core.setVector(0, 0x1111, 0x2222)
            core.setVector(1, 0x3333, 0x4444)
            XCTAssertThrowsError(try core.run(budget: 1), "préfixe \(prefix)")
            XCTAssertEqual(core.vectors[0], 0x1111, "et rien n'a été écrit avant de refuser")
            XCTAssertEqual(core.vectors[1], 0x2222)
        }
    }

    /// L'arithmétique en virgule flottante est refusée de la même façon.
    /// C'est un état, pas un manque caché : la machine ne l'a pas encore
    /// demandée, et le jour où elle le fera, elle s'arrêtera dessus en le
    /// disant.
    func testFloatingPointArithmeticIsRefusedByName() throws {
        // `f2 0f 59 c1` : mulsd %xmm1,%xmm0
        let ram = try Self.memory([0xF2, 0x0F, 0x59, 0xC1])
        var core = Self.core(ram)
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            guard case .unsupported(let name)? = error as? X86Core.Fault else {
                return XCTFail("attendu un refus nommé, reçu \(error)")
            }
            XCTAssertFalse(name.isEmpty)
        }
    }

    /// **Un registre XMM ne se confond pas avec un registre MMX.** `0F 6E`
    /// sans préfixe est l'instruction MMX du même nom, qui écrit dans un autre
    /// fichier de registres. L'exécuter comme si c'était la forme SSE
    /// écrirait dans xmm0 ce que le programme destinait à mm0.
    func testTheMMXFormIsNotTakenForTheSSEOne() throws {
        let ram = try Self.memory([0x0F, 0x6E, 0xC0])  // movd %eax,%mm0
        var core = Self.core(ram)
        core.registers[0] = 0xDEAD_BEEF
        XCTAssertThrowsError(try core.run(budget: 1))
        XCTAssertEqual(core.vectors[0], 0, "xmm0 ne doit pas avoir bougé")
    }
}
