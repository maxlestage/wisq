import XCTest

@testable import WisqVM

/// **`VLDMXCSR` et `VSTMXCSR`**, les formes VEX de `LDMXCSR` et `STMXCSR` :
/// voir `X86Core.vexControlStatus`. La `libm` de Void Linux les emploie dans
/// `sincos`, que `libinput` appelle : sans elles, Xorg mourait au démarrage.
final class X86VEXControlStatusTests: XCTestCase {
    static let data: UInt64 = 0x2000

    static func run(_ code: [UInt8], setup: (inout X86Core) -> Void = { _ in }) throws -> X86Core {
        let memory = X86Memory(size: 0x4000, base: 0)
        try memory.load(code, at: 0x1000)
        var registers = [UInt64](repeating: 0, count: 16)
        registers[4] = data
        var core = X86Core(registers: registers, rip: 0x1000, memory: memory)
        setup(&core)
        while core.rip < 0x1000 &+ UInt64(code.count) {
            try core.execute(try X86Decoder.decode(memory.dump(core.rip, 15)))
        }
        return core
    }

    /// `vstmxcsr 0x18(%rsp)` — les octets mêmes de la `libm` de Void — écrit
    /// le registre en mémoire.
    func testTheStoreWritesTheRegister() throws {
        let core = try Self.run([0xC5, 0xF8, 0xAE, 0x5C, 0x24, 0x18]) { $0.mxcsr = 0x7FA0 }
        XCTAssertEqual(try core.memory?.read(Self.data + 0x18, 4), 0x7FA0)
    }

    /// `vldmxcsr 0x18(%rsp)` le recharge, et l'arrondi qu'il porte avec lui.
    func testTheLoadReadsTheRegister() throws {
        let core = try Self.run([0xC5, 0xF8, 0xAE, 0x54, 0x24, 0x18]) { core in
            try? core.memory?.write(Self.data + 0x18, 4, 0x3F80)
        }
        XCTAssertEqual(core.mxcsr, 0x3F80)
    }

    /// **Les formes qui n'existent pas sont refusées** : un registre dans
    /// `vvvv`, ou un opérande registre au lieu de la mémoire.
    func testTheFormsThatDoNotExistAreRefused() {
        XCTAssertThrowsError(try Self.run([0xC5, 0xF0, 0xAE, 0x5C, 0x24, 0x18]), "vvvv ≠ 1111")
        XCTAssertThrowsError(try Self.run([0xC5, 0xF8, 0xAE, 0xD8]), "en registre")
        XCTAssertThrowsError(try Self.run([0xC5, 0xF8, 0xAE, 0x24, 0x24]), "/4 n'existe pas en VEX")
    }
}
