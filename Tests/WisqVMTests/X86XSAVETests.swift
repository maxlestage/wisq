import Foundation
import XCTest

@testable import WisqVM

/// **XCR0, `XSAVE`, `XRSTOR`, et le haut des registres YMM.**
///
/// Pas d'oracle matériel ici, et c'est délibéré : `XSAVE` dans l'espace
/// utilisateur de l'hôte écrit un XSTATE_BV qui dépend de ce que le processeur
/// croit « en usage », un état que le harnais ne contrôle pas, et la taille de
/// la zone dépend de ce que le noyau de l'hôte a activé. Les règles sont donc
/// tenues à la main, une par test, d'après le manuel (volume 1, chapitre 13).
final class X86XSAVETests: XCTestCase {
    static let base: UInt64 = 0x3000_0000
    static let area: UInt64 = 0x3000_1000

    /// Un cœur sans pagination, CR4.OSXSAVE levé, et le programme posé.
    static func core(_ program: [UInt8], osxsave: Bool = true) throws -> X86Core {
        let memory = X86Memory(size: 0x4000, base: base)
        try memory.load(program, at: base)
        var registers = X86SIMDOracleTests.witness()
        registers[6] = area  // RSI
        var core = X86Core(registers: registers, flags: X86Core.Flag.reserved, rip: base, memory: memory)
        if osxsave { core.system.control[4] |= X86Core.osxsave }
        return core
    }

    static func step(_ core: inout X86Core) throws {
        try core.execute(X86Decoder.decode(core.memory!.dump(core.rip, 15)))
    }

    /// EDX:EAX = `value`, l'opérande de `XSETBV` comme le masque de `XSAVE`.
    static func request(_ core: inout X86Core, _ value: UInt64) {
        core.registers[0] = value & 0xFFFF_FFFF
        core.registers[2] = value >> 32
    }

    static let xgetbv: [UInt8] = [0x0F, 0x01, 0xD0]
    static let xsetbv: [UInt8] = [0x0F, 0x01, 0xD1]
    static let xsave: [UInt8] = [0x0F, 0xAE, 0x26]          // xsave (%rsi)
    static let xrstor: [UInt8] = [0x0F, 0xAE, 0x2E]         // xrstor (%rsi)
    static let xsave64: [UInt8] = [0x48, 0x0F, 0xAE, 0x26]  // xsave64 (%rsi)

    // MARK: - XCR0

    /// **`XSETBV` puis `XGETBV`** : XCR0 part à x87 seul, prend x87|SSE|AVX.
    func testXCR0IsWrittenAndRead() throws {
        var core = try Self.core(Self.xgetbv + Self.xsetbv + Self.xgetbv)
        core.registers[1] = 0  // ECX : XCR0
        try Self.step(&core)
        XCTAssertEqual(core.registers[0], 1, "XCR0 part à x87 seul")
        XCTAssertEqual(core.registers[2], 0)
        Self.request(&core, 0b111)
        try Self.step(&core)
        core.registers[0] = 0xDEAD
        try Self.step(&core)
        XCTAssertEqual(core.registers[0], 0b111)
        XCTAssertEqual(core.xcr0, 0b111)
    }

    /// **Ce que le processeur refuserait d'un #GP** : x87 absent, AVX sans
    /// SSE, un composant inconnu, un autre XCR que le premier, l'anneau
    /// trois ; et tout, sans CR4.OSXSAVE.
    func testImpossibleXCR0ValuesAreRefused() throws {
        for value: UInt64 in [0, 0b110, 0b101, 0b1111, 1 << 32 | 1] {
            var core = try Self.core(Self.xsetbv)
            core.registers[1] = 0
            Self.request(&core, value)
            XCTAssertThrowsError(try Self.step(&core), "XCR0 = \(String(value, radix: 2))")
            XCTAssertEqual(core.xcr0, 1, "un refus laisse XCR0")
        }
        var other = try Self.core(Self.xgetbv)
        other.registers[1] = 1
        XCTAssertThrowsError(try Self.step(&other), "XCR1")
        var off = try Self.core(Self.xgetbv, osxsave: false)
        off.registers[1] = 0
        XCTAssertThrowsError(try Self.step(&off), "sans OSXSAVE")
        var user = try Self.core(Self.xsetbv)
        user.registers[1] = 0
        Self.request(&user, 0b11)
        user.segments[1] = 0x33
        XCTAssertThrowsError(try Self.step(&user), "en anneau trois")
    }

    // MARK: - XSAVE et XRSTOR

    /// Un état reconnaissable partout : pile x87, MXCSR, XMM, haut des YMM.
    static func fill(_ core: inout X86Core) {
        core.x87Control = 0x027F
        core.x87Status = 0x3800  // TOP = 7
        core.x87Tags = 0x3FFF    // un registre plein
        core.x87[7] = X86Extended(significand: 0xC000_0000_0000_0000, signExponent: 0x3FFF)
        core.mxcsr = 0x1F00
        for index in 0..<16 {
            core.setVector(index, 0x1100_0000_0000_0000 + UInt64(index), 0x2200_0000_0000_0000 + UInt64(index))
        }
        for index in 0..<32 { core.upperVectors[index] = 0x3300_0000_0000_0000 + UInt64(index) }
    }

    /// **L'aller-retour entier** : tout ce que la zone porte revient, et
    /// XSTATE_BV dit les trois composants en usage.
    func testEverythingComesBackThroughXSAVEAndXRSTOR() throws {
        var core = try Self.core(Self.xsave + Self.xrstor)
        core.xcr0 = 0b111
        Self.fill(&core)
        Self.request(&core, ~0)
        try Self.step(&core)
        let memory = core.memory!
        XCTAssertEqual(try memory.read(Self.area + 512, 8), 0b111, "XSTATE_BV")
        XCTAssertEqual(try memory.read(Self.area + 576, 8), 0x3300_0000_0000_0000, "le haut de ymm0")
        XCTAssertEqual(try memory.read(Self.area + 576 + 31 * 8, 8), 0x3300_0000_0000_001F, "le haut de ymm15")
        XCTAssertEqual(try memory.read(Self.area + 160, 8), 0x1100_0000_0000_0000, "xmm0, à sa place FXSAVE")
        XCTAssertEqual(try memory.read(Self.area + 24, 4), 0x1F00, "MXCSR")

        let saved = core
        core.x87Control = 0x037F
        core.x87Tags = 0xFFFF
        core.mxcsr = 0x1F80
        for index in 0..<32 {
            core.vectors[index] = 0
            core.upperVectors[index] = 0
        }
        try Self.step(&core)
        XCTAssertEqual(core.x87Control, saved.x87Control | 0x40)
        XCTAssertEqual(core.x87Tags, saved.x87Tags)
        XCTAssertEqual(core.x87[7], saved.x87[7])
        XCTAssertEqual(core.mxcsr, saved.mxcsr)
        XCTAssertEqual(core.vectors, saved.vectors)
        XCTAssertEqual(core.upperVectors, saved.upperVectors)
    }

    /// **Le masque choisit**, et XCR0 le borne : SSE seul demandé, la part x87
    /// et le haut des YMM ne sont pas écrits, XSTATE_BV ne gagne que le
    /// bit 1 — ses autres bits restent ce qu'ils étaient. MXCSR, lui, suit
    /// SSE. Et un AVX demandé qu'XCR0 n'active pas n'est pas rangé.
    func testOnlyTheRequestedComponentsAreWritten() throws {
        var core = try Self.core(Self.xsave64)
        core.xcr0 = 0b011
        Self.fill(&core)
        let memory = core.memory!
        for offset in stride(from: 0, to: 832, by: 8) { try memory.write(Self.area + UInt64(offset), 8, 0xCCCC_CCCC_CCCC_CCCC) }
        try memory.write(Self.area + 512, 8, 1 << 9)  // un bit d'en-tête qui n'est pas demandé
        Self.request(&core, 0b110)
        try Self.step(&core)
        XCTAssertEqual(try memory.read(Self.area + 512, 8), 1 << 9 | 0b010, "XSTATE_BV")
        XCTAssertEqual(try memory.read(Self.area, 8), 0xCCCC_CCCC_CCCC_CCCC, "la part x87 n'est pas écrite")
        XCTAssertEqual(try memory.read(Self.area + 24, 4), 0x1F00, "MXCSR suit SSE")
        XCTAssertEqual(try memory.read(Self.area + 160, 8), 0x1100_0000_0000_0000, "xmm0")
        XCTAssertEqual(try memory.read(Self.area + 576, 8), 0xCCCC_CCCC_CCCC_CCCC,
                       "AVX demandé mais absent d'XCR0 : rien d'écrit")
    }

    /// **Un composant que XSTATE_BV ne dit pas en usage revient à son état
    /// initial** : registres à zéro, pile x87 vide, mot de contrôle 0x37F.
    /// MXCSR se lit quand même, dès que SSE ou AVX est demandé.
    func testWhatIsNotInUseIsInitialised() throws {
        var core = try Self.core(Self.xrstor)
        core.xcr0 = 0b111
        Self.fill(&core)
        // Une zone pleine d'octets reconnaissables : ce qui serait relu au lieu
        // d'être remis à zéro se verrait. Seuls l'en-tête (rien en usage) et
        // MXCSR sont ceux d'une zone valide.
        let memory = core.memory!
        for offset in stride(from: 0, to: 832, by: 8) { try memory.write(Self.area + UInt64(offset), 8, 0x0101_0101_0101_0101) }
        for offset in stride(from: 512, to: 576, by: 8) { try memory.write(Self.area + UInt64(offset), 8, 0) }
        try memory.write(Self.area + 24, 4, 0x1F80 | 0x40)  // MXCSR, DAZ levé
        Self.request(&core, 0b111)
        try Self.step(&core)
        XCTAssertEqual(core.x87Control, 0x037F)
        XCTAssertEqual(core.x87Tags, 0xFFFF)
        XCTAssertEqual(core.x87[7], .zero)
        XCTAssertEqual(core.vectors, [UInt64](repeating: 0, count: 32))
        XCTAssertEqual(core.upperVectors, [UInt64](repeating: 0, count: 32))
        XCTAssertEqual(core.mxcsr, 0x1FC0, "MXCSR relu de la zone")
    }

    /// **Les zones qu'un processeur refuse** : mal alignée, compactée, un
    /// en-tête aux octets réservés levés, un composant en usage qu'XCR0
    /// n'active pas, un MXCSR impossible ; et `XSAVE` sans OSXSAVE.
    func testImpossibleAreasAreRefused() throws {
        func refused(_ program: [UInt8], _ why: String, osxsave: Bool = true,
                     _ prepare: (X86Memory, inout X86Core) throws -> Void) throws {
            var core = try Self.core(program, osxsave: osxsave)
            core.xcr0 = 0b011
            Self.request(&core, ~0)
            try prepare(core.memory!, &core)
            let before = core.vectors
            XCTAssertThrowsError(try Self.step(&core), why)
            XCTAssertEqual(core.vectors, before, "\(why) : un refus ne charge rien")
        }
        try refused(Self.xsave, "mal alignée") { _, core in core.registers[6] = Self.area + 16 }
        try refused(Self.xrstor, "compactée") { memory, _ in try memory.write(Self.area + 520, 8, 1 << 63 | 3) }
        try refused(Self.xrstor, "en-tête réservé") { memory, _ in try memory.write(Self.area + 560, 8, 1) }
        try refused(Self.xrstor, "AVX en usage, absent d'XCR0") { memory, _ in
            try memory.write(Self.area + 512, 8, 0b111)
        }
        try refused(Self.xrstor, "MXCSR impossible") { memory, _ in
            try memory.write(Self.area + 512, 8, 0b011)
            try memory.write(Self.area + 24, 4, 1 << 16)
        }
        try refused(Self.xsave, "sans OSXSAVE", osxsave: false) { _, _ in }
    }

    // MARK: - Le haut des YMM sous VEX.128

    /// **Une forme VEX.128 remet à zéro le haut du registre qu'elle écrit, et
    /// de celui-là seul** ; celles qui écrivent la mémoire, un registre
    /// général ou les drapeaux ne touchent à aucun. `vzeroupper` efface tous
    /// les hauts et garde les XMM.
    func testVEX128ClearsTheUpperHalfOfItsDestination() throws {
        let cases: [(bytes: [UInt8], text: String, cleared: Int?)] = [
            ([0xC5, 0xE9, 0xFE, 0xC1], "vpaddd %xmm1, %xmm2, %xmm0", 0),
            ([0xC4, 0x41, 0x29, 0xFE, 0xC9], "vpaddd %xmm9, %xmm10, %xmm9", 9),
            ([0xC5, 0xF9, 0x6F, 0xD9], "vmovdqa %xmm1, %xmm3", 3),
            ([0xC5, 0xF9, 0x7F, 0xCB], "vmovdqa %xmm1, %xmm3 (forme 7F)", 3),
            ([0xC5, 0xF9, 0x72, 0xF1, 0x04], "vpslld $4, %xmm1, %xmm0", 0),
            ([0xC5, 0xF9, 0x7F, 0x0E], "vmovdqa %xmm1, (%rsi)", nil),
            ([0xC5, 0xF9, 0x7E, 0xC8], "vmovd %xmm1, %eax", nil),
            ([0xC4, 0xE2, 0x79, 0x17, 0xC1], "vptest %xmm1, %xmm0", nil),
            ([0xC4, 0xE3, 0x79, 0x62, 0xC1, 0x00], "vpcmpistrm $0, %xmm1, %xmm0", 0),
            ([0xC4, 0xE3, 0x79, 0x63, 0xC1, 0x00], "vpcmpistri $0, %xmm1, %xmm0", nil),
        ]
        for item in cases {
            var core = try Self.core(item.bytes)
            Self.fill(&core)
            try Self.step(&core)
            for index in 0..<16 {
                let expected: [UInt64] = index == item.cleared
                    ? [0, 0] : [0x3300_0000_0000_0000 + UInt64(2 * index), 0x3300_0000_0000_0000 + UInt64(2 * index + 1)]
                XCTAssertEqual(Array(core.upperVectors[2 * index...2 * index + 1]), expected,
                               "\(item.text) : le haut de ymm\(index)")
            }
        }
        var core = try Self.core([0xC5, 0xF8, 0x77])  // vzeroupper
        Self.fill(&core)
        let vectors = core.vectors
        try Self.step(&core)
        XCTAssertEqual(core.upperVectors, [UInt64](repeating: 0, count: 32))
        XCTAssertEqual(core.vectors, vectors, "vzeroupper garde les XMM")
    }

    // MARK: - CPUID

    /// **CPUID dit ce qui est là** : XSAVE toujours, OSXSAVE selon CR4, et la
    /// feuille 0xD la taille de la zone pour ce qu'XCR0 active.
    func testCPUIDDescribesTheExtendedState() {
        XCTAssertEqual(X86CPUID.answer(leaf: 0, subleaf: 0).0, 0xD)
        let plain = X86CPUID.answer(leaf: 1, subleaf: 0).2
        XCTAssertNotEqual(plain & (1 << 26), 0, "XSAVE")
        XCTAssertEqual(plain & (1 << 27), 0, "OSXSAVE sans CR4.OSXSAVE")
        XCTAssertNotEqual(X86CPUID.answer(leaf: 1, subleaf: 0, osxsave: true).2 & (1 << 27), 0, "OSXSAVE")
        let sse = X86CPUID.answer(leaf: 0xD, subleaf: 0, xcr0: 0b011)
        XCTAssertEqual(sse.0, 0b111, "les composants possibles")
        XCTAssertEqual(sse.1, 576, "la zone pour x87 et SSE")
        XCTAssertEqual(sse.2, 832, "la plus grande zone")
        XCTAssertEqual(X86CPUID.answer(leaf: 0xD, subleaf: 0, xcr0: 0b111).1, 832)
        XCTAssertEqual(X86CPUID.answer(leaf: 0xD, subleaf: 1).0, 0, "ni XSAVEOPT, ni XSAVEC, ni XSAVES")
        let upper = X86CPUID.answer(leaf: 0xD, subleaf: 2)
        XCTAssertEqual(upper.0, 256)
        XCTAssertEqual(upper.1, 576)
    }

    /// **Le cœur répond avec CR4 et XCR0 tels qu'ils sont**, pas avec les
    /// valeurs par défaut de `answer`.
    func testTheCoreAnswersCPUIDWithItsOwnState() throws {
        var core = try Self.core([0x0F, 0xA2, 0x0F, 0xA2])
        core.xcr0 = 0b111
        core.registers[0] = 1
        try Self.step(&core)
        XCTAssertNotEqual(core.registers[1] & (1 << 27), 0, "OSXSAVE")
        core.registers[0] = 0xD
        core.registers[1] = 0
        try Self.step(&core)
        XCTAssertEqual(core.registers[3], 832, "EBX : la zone pour x87, SSE et AVX")
    }
}
