import XCTest

@testable import WisqVM

/// **Les formes courtes ne calculent rien autrement que le chemin général.**
///
/// Une forme courte est un second chemin pour les mêmes instructions : la
/// vitesse qu'elle rapporte ne vaut rien si un seul drapeau en sort autrement.
/// Les corpus matériels la jugent déjà — `execute` y mène par `perform` —,
/// mais ils ne passent pas par `run`, où l'instruction est exécutée depuis sa
/// case du cache de décodage. Ces tests comparent donc, forme par forme et
/// sur des états tirés au hasard, trois exécutions de la même instruction :
///
///   1. le chemin général, par `X86Instruction.generic` ;
///   2. la forme courte arrivée par valeur (`execute`) ;
///   3. la forme courte depuis le cache (`run`, au second passage).
///
/// Tout doit être égal : les seize registres, RIP, les drapeaux, la mémoire
/// entière, l'adresse du dernier opérande, et la faute s'il y en a une.
final class X86FastFormsTests: XCTestCase {
    /// Un tirage reproductible : un échec se rejoue.
    struct Draw {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
        mutating func chance(_ outOf: Int) -> Bool { below(outOf) == 0 }
    }

    static let base: UInt64 = 0x1000
    static let size = 0xA000
    static let codeAt: UInt64 = 0x1800

    /// Ce qu'une exécution laisse derrière elle.
    struct Outcome: Equatable {
        var registers: [UInt64]
        var rip: UInt64
        var flags: UInt64
        var lastAddress: UInt64
        var retired: UInt64
        var memory: [UInt8]
        var fault: String?
    }

    /// Un ModRM en mémoire, avec son SIB et son déplacement : toutes les
    /// formes d'adresse, y compris relative à RIP.
    static func memoryOperand(_ draw: inout Draw, reg: UInt8) -> [UInt8] {
        let mod = UInt8(draw.below(3))
        let rm = UInt8(draw.below(8))
        var bytes = [mod << 6 | reg << 3 | rm]
        if rm == 4 {
            bytes.append(draw.byte())  // SIB : échelle, index, base
        }
        let sibBase = bytes.count == 2 ? bytes[1] & 7 : 0
        if mod == 1 {
            bytes.append(draw.byte())
        } else if mod == 2 || (mod == 0 && (rm == 5 || (rm == 4 && sibBase == 5))) {
            // De petits déplacements : l'adresse reste le plus souvent dans
            // la mémoire, sans jamais y être tenue.
            let displacement = Int32(draw.below(0x800)) - 0x400
            withUnsafeBytes(of: displacement.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    /// Un REX quelconque, ou pas de REX du tout une fois sur trois : AH, CH,
    /// DH et BH n'existent que là.
    static func rex(_ draw: inout Draw) -> [UInt8] {
        draw.chance(3) ? [] : [0x40 | (draw.byte() & 0x0F)]
    }

    /// Un ModRM entre deux registres.
    static func bothRegisters(_ draw: inout Draw) -> UInt8 { 0xC0 | (draw.byte() & 0x3F) }

    static func immediate32(_ draw: inout Draw) -> [UInt8] {
        let value = draw.chance(4) ? UInt32(truncatingIfNeeded: draw.next()) : UInt32(draw.below(0x200))
        return withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    /// Un saut qui retombe dans le code : seule l'adresse compte, rien n'y
    /// est exécuté.
    static func relative32(_ draw: inout Draw) -> [UInt8] {
        let value = Int32(draw.below(0x400)) - 0x200
        return withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    /// Les formes, chacune avec ce qui tire un de ses encodages.
    static let forms: [(name: String, code: UInt8, make: @Sendable (inout Draw) -> [UInt8])] = {
        typealias Form = X86Instruction.FastForm
        let toRM: [UInt8] = [0x01, 0x09, 0x11, 0x19, 0x21, 0x29, 0x31, 0x39]
        let toRegister: [UInt8] = [0x03, 0x0B, 0x13, 0x1B, 0x23, 0x2B, 0x33, 0x3B]
        return [
            ("mov rm ← reg", Form.moveToRM, { rex(&$0) + [0x89, bothRegisters(&$0)] }),
            ("mov reg ← rm", Form.moveToRegister, { rex(&$0) + [0x8B, bothRegisters(&$0)] }),
            ("mov reg ← mémoire", Form.load, {
                rex(&$0) + [0x8B] + memoryOperand(&$0, reg: $0.byte() & 7)
            }),
            ("mov mémoire ← reg", Form.store, {
                rex(&$0) + [0x89] + memoryOperand(&$0, reg: $0.byte() & 7)
            }),
            ("jcc court", Form.jumpIf, { [0x70 | ($0.byte() & 0x0F), $0.byte()] }),
            ("jcc long", Form.jumpIf, { [0x0F, 0x80 | ($0.byte() & 0x0F)] + relative32(&$0) }),
            ("jmp court", Form.jump, { [0xEB, $0.byte()] }),
            ("jmp long", Form.jump, { [0xE9] + relative32(&$0) }),
            ("arithmétique rm ← rm op reg", Form.arithmeticToRM, {
                rex(&$0) + [toRM[$0.below(8)], bothRegisters(&$0)]
            }),
            ("arithmétique reg ← reg op rm", Form.arithmeticToRegister, {
                rex(&$0) + [toRegister[$0.below(8)], bothRegisters(&$0)]
            }),
            ("arithmétique reg ← reg op mémoire", Form.arithmeticFromMemory, {
                rex(&$0) + [toRegister[$0.below(8)]] + memoryOperand(&$0, reg: $0.byte() & 7)
            }),
            ("cmp mémoire, reg", Form.compareMemory, {
                rex(&$0) + [0x39] + memoryOperand(&$0, reg: $0.byte() & 7)
            }),
            ("arithmétique rm, imm8", Form.arithmeticImmediate, {
                rex(&$0) + [0x83, bothRegisters(&$0), $0.byte()]
            }),
            ("arithmétique rm, imm32", Form.arithmeticImmediate, {
                rex(&$0) + [0x81, bothRegisters(&$0)] + immediate32(&$0)
            }),
            ("test rm, reg", Form.test, { rex(&$0) + [0x85, bothRegisters(&$0)] }),
            ("lea", Form.loadAddress, {
                rex(&$0) + [0x8D] + memoryOperand(&$0, reg: $0.byte() & 7)
            }),
            ("movzx reg ← rm8", Form.zeroExtendByte, { rex(&$0) + [0x0F, 0xB6, bothRegisters(&$0)] }),
            ("movzx reg ← rm16", Form.zeroExtendWord, { rex(&$0) + [0x0F, 0xB7, bothRegisters(&$0)] }),
            ("movzx reg ← mémoire8", Form.loadByte, {
                rex(&$0) + [0x0F, 0xB6] + memoryOperand(&$0, reg: $0.byte() & 7)
            }),
            ("movzx reg ← mémoire16", Form.loadWord, {
                rex(&$0) + [0x0F, 0xB7] + memoryOperand(&$0, reg: $0.byte() & 7)
            }),
            ("push", Form.push, { ($0.chance(2) ? [0x41] : []) + [0x50 | ($0.byte() & 7)] }),
            ("pop", Form.pop, { ($0.chance(2) ? [0x41] : []) + [0x58 | ($0.byte() & 7)] }),
            ("call", Form.call, { [0xE8] + relative32(&$0) }),
            ("ret", Form.ret, { _ in [0xC3] }),
        ]
    }()

    /// Un état : des registres qui désignent le plus souvent la mémoire, et
    /// une fois sur huit n'importe quoi — une adresse hors de la mémoire doit
    /// fauter pareil par les deux chemins.
    static func registers(_ draw: inout Draw) -> [UInt64] {
        (0..<16).map { _ in
            if draw.chance(8) { return draw.next() }
            if draw.chance(8) { return draw.next() & 0xFFFF_FFFF }
            return 0x1000 + UInt64(draw.below(0x100)) &* 8
        }
    }

    static let flagBits: UInt64 = X86Core.Flag.carry | X86Core.Flag.parity | X86Core.Flag.auxiliary
        | X86Core.Flag.zero | X86Core.Flag.sign | X86Core.Flag.overflow

    func outcome(_ core: X86Core, _ memory: X86Memory, fault: Error?) -> Outcome {
        Outcome(registers: Array(core.registers), rip: core.rip, flags: core.flags,
                lastAddress: core.lastAddress, retired: core.retired,
                memory: Array(UnsafeBufferPointer(start: memory.bytes, count: memory.size)),
                fault: fault.map { "\($0)" })
    }

    /// Les trois exécutions d'un encodage sur un état, et leur comparaison.
    func compare(_ code: [UInt8], form: (name: String, code: UInt8), template: X86Core,
                 memory: X86Memory, draw: inout Draw) throws -> Bool {
        let name = form.name
        var image = (0..<Self.size).map { _ in draw.byte() }
        let at = Int(Self.codeAt - Self.base)
        image.replaceSubrange(at..<(at + code.count), with: code)
        // Des zéros derrière : le décodeur de `run` lit quinze octets.
        image.replaceSubrange((at + code.count)..<(at + 16), with: [UInt8](repeating: 0x90, count: 16 - code.count))
        let decoded = try X86Decoder.decode(code)
        let hex = code.map { String(format: "%02x", $0) }.joined(separator: " ")
        XCTAssertEqual(decoded.dispatchCode, form.code, "\(name) : \(hex) n'est pas rangé sous sa forme")
        XCTAssertFalse(decoded.generic.isFastForm)

        var start = template
        start.registers = X86Registers(Self.registers(&draw))
        // La pile dans la mémoire, sauf une fois sur seize.
        if !draw.chance(16) { start.registers[4] = 0x9000 + UInt64(draw.below(0x100)) &* 8 }
        start.flags = X86Core.Flag.reserved | (draw.next() & Self.flagBits)
        start.rip = Self.codeAt

        func run(_ body: (inout X86Core) throws -> Void) throws -> Outcome {
            try memory.load(image, at: Self.base)
            var core = start
            var fault: Error?
            do { try body(&core) } catch { fault = error }
            return outcome(core, memory, fault: fault)
        }
        let general = try run { try $0.execute(decoded.generic) }
        let byValue = try run { try $0.execute(decoded) }
        // Un premier passage range l'instruction dans le cache ; le second
        // l'exécute depuis sa case.
        _ = try run { _ = try $0.run(budget: 1) }
        let misses = template.decodeCache.misses
        let cached = try run { _ = try $0.run(budget: 1) }
        XCTAssertEqual(template.decodeCache.misses, misses, "le second passage doit venir du cache")

        let state = "\(name) : \(hex), registres \(Array(start.registers).map { String($0, radix: 16) }), "
            + "drapeaux \(String(start.flags, radix: 16))"
        guard general == byValue else {
            XCTFail("par valeur — \(state)\n\(difference(general, byValue))")
            return false
        }
        // `run` range sa faute autrement (`deliver` la rend telle quelle) : on
        // compare qu'il y en a une, et tout le reste.
        var expected = general
        var obtained = cached
        XCTAssertEqual(expected.fault == nil, obtained.fault == nil, "depuis le cache — \(state)")
        expected.fault = nil
        obtained.fault = nil
        guard expected == obtained else {
            XCTFail("depuis le cache — \(state)\n\(difference(expected, obtained))")
            return false
        }
        return true
    }

    func difference(_ left: Outcome, _ right: Outcome) -> String {
        var notes: [String] = []
        for index in 0..<16 where left.registers[index] != right.registers[index] {
            notes.append("r\(index) \(String(left.registers[index], radix: 16)) ≠ \(String(right.registers[index], radix: 16))")
        }
        if left.rip != right.rip { notes.append("rip \(String(left.rip, radix: 16)) ≠ \(String(right.rip, radix: 16))") }
        if left.flags != right.flags {
            notes.append("drapeaux \(String(left.flags, radix: 16)) ≠ \(String(right.flags, radix: 16))")
        }
        if left.lastAddress != right.lastAddress { notes.append("dernière adresse") }
        if left.retired != right.retired { notes.append("retirées \(left.retired) ≠ \(right.retired)") }
        if left.memory != right.memory { notes.append("mémoire") }
        if left.fault != right.fault { notes.append("faute \(left.fault ?? "aucune") ≠ \(right.fault ?? "aucune")") }
        return notes.joined(separator: " ; ")
    }

    /// Chaque forme, deux cents encodages et états tirés au hasard.
    func testEveryFastFormMatchesTheGeneralPath() throws {
        let memory = X86Memory(size: Self.size, base: Self.base)
        let template = X86Core(rip: Self.codeAt, memory: memory)
        var draw = Draw(state: 0x5EED_F0F0_2026_1119)
        var compared = 0
        for form in Self.forms {
            var failures = 0
            for _ in 0..<200 where failures < 3 {
                let code = form.make(&draw)
                if try !compare(code, form: (form.name, form.code), template: template,
                                memory: memory, draw: &draw) {
                    failures += 1
                }
                compared += 1
            }
        }
        XCTAssertEqual(compared, Self.forms.count * 200)
    }

    /// **Les drapeaux d'un saut conditionnel, tous** : les seize conditions
    /// devant les soixante-quatre combinaisons de CF, PF, ZF, SF et OF (AF ne
    /// décide d'aucune), courts et longs.
    func testEveryConditionJumpsAsTheGeneralPathDoes() throws {
        let memory = X86Memory(size: Self.size, base: Self.base)
        let template = X86Core(rip: Self.codeAt, memory: memory)
        let bits = [X86Core.Flag.carry, X86Core.Flag.parity, X86Core.Flag.zero,
                    X86Core.Flag.sign, X86Core.Flag.overflow]
        var taken = 0
        for condition in UInt8(0)..<16 {
            for combination in 0..<32 {
                var flags = X86Core.Flag.reserved
                for (index, bit) in bits.enumerated() where combination >> index & 1 != 0 { flags |= bit }
                for code in [[0x70 | condition, 0x10], [0x0F, 0x80 | condition, 0x10, 0, 0, 0]] {
                    try memory.load(code + [UInt8](repeating: 0x90, count: 16), at: Self.codeAt)
                    let decoded = try X86Decoder.decode(code)
                    XCTAssertEqual(decoded.dispatchCode, X86Instruction.FastForm.jumpIf)
                    var general = template
                    general.flags = flags
                    try general.execute(decoded.generic)
                    for pass in 0..<2 {
                        var fast = template
                        fast.flags = flags
                        XCTAssertEqual(try fast.run(budget: 1), 1)
                        XCTAssertEqual(fast.rip, general.rip,
                                       "condition \(condition), drapeaux \(String(flags, radix: 16)), passage \(pass)")
                    }
                    if general.rip != Self.codeAt + UInt64(code.count) { taken += 1 }
                }
            }
        }
        // Chaque condition est vraie pour la moitié des combinaisons.
        XCTAssertEqual(taken, 16 * 32)
    }

    /// **Seulement le cas simple.** Un préfixe hérité — taille, adresse,
    /// segment, répétition, verrou — ou le mode compatibilité laissent
    /// l'instruction à sa table : la forme courte ne sait rien d'eux.
    func testAPrefixOrTheCompatibilityModeKeepsTheGeneralPath() throws {
        let plain: [[UInt8]] = [
            [0x89, 0xC3], [0x8B, 0x03], [0x89, 0x03], [0x01, 0xC3], [0x03, 0x03], [0x39, 0x03],
            [0x83, 0xC0, 0x01], [0x85, 0xC0], [0x8D, 0x43, 0x08], [0x0F, 0xB6, 0xC3], [0x0F, 0xB7, 0x03],
            [0x74, 0x02], [0xEB, 0x02], [0x50], [0x58], [0xC3], [0xE8, 0, 0, 0, 0],
        ]
        for code in plain {
            XCTAssertTrue(try X86Decoder.decode(code).isFastForm, "\(code)")
            XCTAssertFalse(try X86Decoder.decode(code, compatibility: true).isFastForm,
                           "\(code) en mode compatibilité")
            for prefix in [0x66, 0x67, 0x64, 0x65, 0x2E, 0xF2, 0xF3, 0xF0] as [UInt8] {
                guard let prefixed = try? X86Decoder.decode([prefix] + code) else { continue }
                XCTAssertFalse(prefixed.isFastForm, "\(code) sous le préfixe \(String(prefix, radix: 16))")
            }
        }
        // `lea` d'un registre n'existe pas, et n'est donc pas une forme.
        XCTAssertFalse(try X86Decoder.decode([0x8D, 0xC3]).isFastForm)
        // Les formes octet et les écritures en mémoire gardent leur table.
        for code in [[0x88, 0xC3], [0x00, 0xC3], [0x01, 0x03], [0x83, 0x03, 0x01], [0x84, 0xC0]] as [[UInt8]] {
            XCTAssertFalse(try X86Decoder.decode(code).isFastForm, "\(code)")
        }
    }
}
