import XCTest

@testable import WisqVM

/// **Un bloc n'exécute rien autrement que la boucle d'une instruction à la
/// fois.**
///
/// Les blocs (`X86BlockCache`) sont un second chemin dans `run` : les mêmes
/// instructions, trouvées et vérifiées une fois pour plusieurs. Tout ce que
/// la tête de boucle garantit à chaque instruction — le budget, le service du
/// matériel tous les 256, l'arrêt, la page gardée, le mode, le code qui se
/// réécrit — doit tenir au milieu d'un bloc. Ces tests comparent les deux
/// chemins (`usesBlocks`) sur des programmes tirés au hasard et sur chaque
/// garde, une par une.
final class X86BlockTests: XCTestCase {
    typealias Draw = X86FastFormsTests.Draw
    typealias Pages = X86PagePermissionTests

    static let size = 0x40000
    static let code: UInt64 = 0x10000
    static let data: UInt64 = 0x20000
    static let stack: UInt64 = 0x38000
    static let open = Pages.present | Pages.writable | Pages.user

    /// Une machine en mode 64 bits, paginée, où chaque page est à sa propre
    /// adresse : les blocs ne vivent que sous une page gardée.
    static func machine(_ program: [UInt8], at address: UInt64 = code) throws -> (X86Core, X86Memory) {
        let memory = X86Memory(size: size, base: 0)
        try memory.load(program, at: address)
        try memory.write(Pages.pml4, 8, Pages.pdpt | open)
        try memory.write(Pages.pdpt, 8, Pages.directory | open)
        try memory.write(Pages.directory, 8, Pages.table | open)
        for page in stride(from: UInt64(0), to: UInt64(size), by: 0x1000) {
            try memory.write(Pages.table &+ (page >> 12) * 8, 8, page | open)
        }
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: address, memory: memory)
        core.system.control[3] = Pages.pml4
        core.system.control[0] = X86Core.writeProtect
        core.pagingActive = true
        core.segments[1] = 0x10
        core.registers[4] = stack
        return (core, memory)
    }

    struct Outcome: Equatable {
        var registers: [UInt64]
        var rip: UInt64
        var flags: UInt64
        var retired: UInt64
        var executed: UInt64
        var halted: Bool
        var memory: [UInt8]
        var fault: Bool
    }

    /// Fait tourner `core` par tranches de budget, jusqu'à `total`
    /// instructions, l'arrêt ou une faute.
    static func outcome(_ start: X86Core, _ memory: X86Memory, image: [UInt8], blocks: Bool,
                        budget: (total: UInt64, slices: [UInt64])) throws -> Outcome {
        let (total, slices) = budget
        try memory.load(image, at: 0)
        var core = start
        core.usesBlocks = blocks
        var executed: UInt64 = 0
        var fault = false
        var index = 0
        while executed < total, !core.halted, !fault {
            let slice = min(slices.isEmpty ? total : slices[index % slices.count], total - executed)
            index += 1
            let before = core.retired
            do {
                executed += try core.run(budget: slice)
            } catch {
                // Une faute sans porte sort de `run` : les instructions
                // finies avant elle se lisent dans `retired`.
                executed += core.retired - before
                fault = true
            }
        }
        return Outcome(registers: Array(core.registers), rip: core.rip, flags: core.flags,
                       retired: core.retired, executed: executed, halted: core.halted,
                       memory: Array(UnsafeBufferPointer(start: memory.bytes, count: memory.size)),
                       fault: fault)
    }

    // MARK: - Des programmes tirés au hasard

    /// Une instruction à poser : sa longueur, et ses octets une fois que
    /// toutes les adresses sont connues.
    struct Piece {
        let length: Int
        let bytes: (_ at: UInt64, _ starts: [UInt64], _ index: Int) -> [UInt8]
        init(_ fixed: [UInt8]) {
            length = fixed.count
            bytes = { _, _, _ in fixed }
        }
        init(length: Int, _ bytes: @escaping (UInt64, [UInt64], Int) -> [UInt8]) {
            self.length = length
            self.bytes = bytes
        }
    }

    /// Un registre qui n'est pas le sommet de la pile : le programme doit
    /// pouvoir empiler jusqu'au bout.
    static func register(_ draw: inout Draw) -> UInt8 { [0, 1, 2, 3, 6, 7][draw.below(6)] }

    static func bothRegisters(_ draw: inout Draw) -> UInt8 {
        0xC0 | register(&draw) << 3 | register(&draw)
    }

    /// Un opérande relatif à RIP, qui tombe dans les données.
    static func relative(_ head: [UInt8], reg: UInt8, tail: [UInt8] = [], _ draw: inout Draw) -> Piece {
        let target = data + UInt64(draw.below(0x200)) * 8
        let length = head.count + 5 + tail.count
        return Piece(length: length) { at, _, _ in
            let displacement = Int32(truncatingIfNeeded: Int64(target) - Int64(at) - Int64(length))
            return head + [reg << 3 | 0x05] + withUnsafeBytes(of: displacement.littleEndian) { Array($0) } + tail
        }
    }

    /// Un saut vers le début d'une instruction voisine, devant ou derrière.
    static func jump(_ opcode: UInt8, _ draw: inout Draw) -> Piece {
        let hop = draw.below(14) - 5
        return Piece(length: 2) { at, starts, index in
            let target = starts[max(0, min(starts.count - 1, index + 1 + hop))]
            return [opcode, UInt8(truncatingIfNeeded: Int64(target) - Int64(at) - 2)]
        }
    }

    static func piece(_ draw: inout Draw) -> Piece {
        let wide: [UInt8] = draw.chance(2) ? [0x48] : []
        let reg = register(&draw)
        let toRM: [UInt8] = [0x01, 0x09, 0x11, 0x19, 0x21, 0x29, 0x31, 0x39]
        let toRegister: [UInt8] = [0x03, 0x0B, 0x13, 0x1B, 0x23, 0x2B, 0x33, 0x3B]
        switch draw.below(40) {
        // Les formes courtes entre registres.
        case 0...2: return Piece(wide + [0x89, bothRegisters(&draw)])
        case 3...4: return Piece(wide + [0x8B, bothRegisters(&draw)])
        case 5...8: return Piece(wide + [toRM[draw.below(8)], bothRegisters(&draw)])
        case 9...10: return Piece(wide + [toRegister[draw.below(8)], bothRegisters(&draw)])
        case 11...13: return Piece(wide + [0x83, 0xC0 | draw.byte() & 0x38 | reg, draw.byte()])
        case 14: return Piece(wide + [0x85, bothRegisters(&draw)])
        case 15: return Piece(wide + [0x0F, 0xB6, bothRegisters(&draw)])
        case 16: return Piece(wide + [0x0F, 0xB7, bothRegisters(&draw)])
        // Les formes courtes avec la mémoire.
        case 17...18: return relative(wide + [0x8B], reg: reg, &draw)
        case 19...20: return relative(wide + [0x89], reg: reg, &draw)
        case 21: return relative(wide + [toRegister[draw.below(8)]], reg: reg, &draw)
        case 22: return relative(wide + [0x39], reg: reg, &draw)
        case 23: return relative(wide + [0x0F, draw.chance(2) ? 0xB6 : 0xB7], reg: reg, &draw)
        case 24: return relative([0x48, 0x8D], reg: reg, &draw)
        // La pile.
        case 25...26: return Piece([0x50 | reg])
        case 27: return Piece([0x58 | reg])
        case 28: return Piece([0xE8, 0, 0, 0, 0])  // call : empile et continue
        // Les sauts.
        case 29...32: return jump(0x70 | draw.byte() & 0x0F, &draw)
        case 33: return jump(0xEB, &draw)
        // Des instructions générales.
        case 34: return Piece([0x48, 0xFF, (draw.chance(2) ? 0xC0 : 0xC8) | reg])  // inc, dec
        case 35: return Piece([0x48, 0xC1, 0xE0 | reg, draw.byte() & 0x3F])  // shl
        case 36: return Piece([0x48, 0x0F, 0xAF, bothRegisters(&draw)])  // imul
        case 37: return Piece([0xB8 | reg] + X86FastFormsTests.immediate32(&draw))  // mov imm32
        case 38: return Piece([0x48, 0x0F, 0x40 | draw.byte() & 0x0F, bothRegisters(&draw)])  // cmovcc
        default:
            return draw.chance(2)
                ? relative([0x88], reg: reg, &draw)  // mov d'un octet vers la mémoire
                : relative([0xC7], reg: 0, tail: X86FastFormsTests.immediate32(&draw), &draw)
        }
    }

    static func program(_ draw: inout Draw, at address: UInt64) -> [UInt8] {
        let pieces = (0..<48).map { _ in piece(&draw) }
        var starts: [UInt64] = []
        var cursor = address
        for piece in pieces {
            starts.append(cursor)
            cursor += UInt64(piece.length)
        }
        // La fin : là où un saut vers l'avant retombe, et où l'on s'arrête.
        starts.append(cursor)
        var bytes: [UInt8] = []
        for (index, piece) in pieces.enumerated() {
            bytes += piece.bytes(starts[index], starts, index)
        }
        return bytes + [UInt8](repeating: 0xF4, count: 32)
    }

    /// Trois cents programmes, chacun exécuté sans blocs, avec, et avec des
    /// budgets hachés : le même état au bout, la même mémoire, le même compte.
    func testRandomProgramsRunTheSameWithAndWithoutBlocks() throws {
        var draw = Draw(state: 0xB10C_5EED_2026_1120)
        var built: UInt64 = 0
        var retired: UInt64 = 0
        for round in 0..<300 {
            // Près de la fin de page une fois sur quatre : des instructions à
            // cheval, et des blocs que la page coupe.
            let address = Self.code + (round % 4 == 0 ? UInt64(0xF80 + draw.below(0x70)) : UInt64(draw.below(0x400)))
            let code = Self.program(&draw, at: address)
            var (core, memory) = try Self.machine(code, at: address)
            // Le cache des blocs se range à la première course : demandé ici,
            // les copies du cœur le partagent et le compte se lit au bout.
            _ = core.blockCache
            for index in 0..<16 where index != 4 { core.registers[index] = draw.next() }
            core.flags = X86Core.Flag.reserved | (draw.next() & X86FastFormsTests.flagBits)
            let image = Array(UnsafeBufferPointer(start: memory.bytes, count: memory.size))
            let slices = (0..<7).map { _ in UInt64(1 + draw.below(37)) }

            let plain = try Self.outcome(core, memory, image: image, blocks: false, budget: (400, []))
            let whole = try Self.outcome(core, memory, image: image, blocks: true, budget: (400, []))
            let sliced = try Self.outcome(core, memory, image: image, blocks: true, budget: (400, slices))
            let hex = code.prefix(96).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(plain, whole, "programme \(round) en \(String(address, radix: 16)) : \(hex)…")
            XCTAssertEqual(plain, sliced, "programme \(round), budgets \(slices) : \(hex)…")
            if plain != whole || plain != sliced { break }
            built += core.storedBlockCache?.builds ?? 0
            retired += plain.retired
        }
        // Le test ne vaut que si les blocs ont servi et que les programmes
        // ont tourné : mesuré, pas souhaité (67 instructions en moyenne).
        XCTAssertGreaterThan(built, 1_000)
        XCTAssertGreaterThan(retired, 300 * 30)
    }

    // MARK: - Chaque garde

    func both(_ code: [UInt8], budget: UInt64, at address: UInt64 = code,
              prepare: (inout X86Core, X86Memory) throws -> Void = { _, _ in }) throws -> (Outcome, Outcome) {
        var (core, memory) = try Self.machine(code, at: address)
        try prepare(&core, memory)
        let image = Array(UnsafeBufferPointer(start: memory.bytes, count: memory.size))
        return (try Self.outcome(core, memory, image: image, blocks: false, budget: (budget, [])),
                try Self.outcome(core, memory, image: image, blocks: true, budget: (budget, [])))
    }

    /// **Un bloc qui se réécrit exécute les octets neufs.** À chaque tour,
    /// une écriture en mémoire — par une forme courte, puis par une
    /// instruction générale — pose un immédiat **différent** dans une
    /// instruction du même bloc, plus loin : c'est celui du tour qui s'ajoute,
    /// pas celui du tour d'avant.
    func testABlockThatRewritesItselfRunsTheNewBytes() throws {
        let fast: [UInt8] = [0x83, 0xC3, 0x01,                          // add $1, %ebx
                             0x89, 0x1D, 0x03, 0x00, 0x00, 0x00,        // mov %ebx, 3(%rip)
                             0x48, 0x81, 0xC0, 0x00, 0x00, 0x00, 0x00,  // add $…, %rax
                             0xEB, 0xEE]                                // jmp au début
        let general: [UInt8] = [0x83, 0xC3, 0x01,                       // add $1, %ebx
                                0x88, 0x1D, 0x03, 0x00, 0x00, 0x00,     // mov %bl, 3(%rip)
                                0x48, 0x83, 0xC0, 0x00,                 // add $…, %rax
                                0xEB, 0xF1]                             // jmp au début
        for code in [fast, general] {
            let (plain, blocks) = try both(code, budget: 40)
            XCTAssertEqual(plain, blocks)
            XCTAssertEqual(blocks.registers[0], (1...10).reduce(0, +), "dix tours : 1, puis 2, puis 3…")
        }
    }

    /// Fait tourner `code` deux fois depuis son début — la seconde range les
    /// blocs, la page étant gardée dès la première instruction — puis laisse
    /// `change` réécrire la mémoire, et rend RAX après une troisième course.
    func thirdRun(_ code: [UInt8], change: (X86Memory) throws -> Void) throws -> UInt64 {
        var (core, memory) = try Self.machine(code)
        for round in 0..<3 {
            if round == 2 { try change(memory) }
            core.rip = Self.code
            core.halted = false
            core.registers[0] = 0
            _ = try core.run(budget: 100)
        }
        XCTAssertGreaterThan(core.storedBlockCache?.builds ?? 0, 0)
        return core.registers[0]
    }

    /// **Un code réécrit du dehors ne retrouve pas son bloc**, où que tombe
    /// l'octet changé parmi les trente-deux que le bloc couvre.
    func testCodeRewrittenFromOutsideIsReadAgain() throws {
        // Huit `add $1, %rax` : un bloc entier, trente-deux octets.
        let code: [UInt8] = (0..<8).flatMap { _ -> [UInt8] in [0x48, 0x83, 0xC0, 0x01] } + [0xF4]
        XCTAssertEqual(try thirdRun(code) { _ in }, 8)
        for changed in 0..<8 {
            let result = try thirdRun(code) { memory in
                try memory.load([0x40], at: Self.code + UInt64(changed * 4 + 3))
            }
            XCTAssertEqual(result, 7 + 0x40, "l'immédiat de l'instruction \(changed) est le neuf")
        }
    }

    /// **Tout ce qu'un bloc couvre est comparé.** Huit `add` de sept octets :
    /// un bloc n'en tient que quatre, parce que trente-deux octets sont
    /// comparés à l'entrée et pas un de plus. Le sixième, réécrit du dehors,
    /// doit se relire.
    func testABlockCoversNoMoreThanItCompares() throws {
        let add: (UInt8) -> [UInt8] = { [0x48, 0x81, 0xC0, $0, 0x00, 0x00, 0x00] }
        let code: [UInt8] = (0..<8).flatMap { _ -> [UInt8] in add(1) } + [0xF4]
        let result = try thirdRun(code) { memory in try memory.load(add(0x20), at: Self.code + 5 * 7) }
        XCTAssertEqual(result, 7 + 0x20, "le sixième `add` est le neuf")
    }

    /// **Une instruction à cheval sur deux pages ne se lit pas dans la trame
    /// voisine.** La page d'après, pour l'invité, est ailleurs en mémoire :
    /// la suite de l'instruction vient de là, et un bloc qui lirait tout droit
    /// prendrait les octets d'une trame qui n'a rien à voir.
    func testAnInstructionAcrossTwoPagesIsNotReadFromTheNextFrame() throws {
        // add $1, %rax ; puis add $imm32, %rax dont l'immédiat passe la page.
        let head: [UInt8] = [0x48, 0x83, 0xC0, 0x01, 0x48, 0x81, 0xC0, 0x10]
        let at = Self.code + 0x1000 - UInt64(head.count)
        let elsewhere: UInt64 = 0x30000
        var results: [UInt64] = []
        for blocks in [false, true, true] {
            var (core, memory) = try Self.machine(head, at: at)
            // La trame voisine dit « 0x77… » ; la page voisine, « 0 0 0 hlt ».
            try memory.load([0x77, 0x77, 0x77, 0xF4], at: Self.code + 0x1000)
            try memory.load([0x00, 0x00, 0x00, 0xF4], at: elsewhere)
            try memory.write(Pages.table &+ ((Self.code + 0x1000) >> 12) * 8, 8, elsewhere | Self.open)
            core.usesBlocks = blocks
            // Deux passages : le second trouve ce que le premier a rangé.
            for _ in 0..<2 {
                core.rip = at
                core.halted = false
                core.registers[0] = 0
                XCTAssertEqual(try core.run(budget: 10), 3)
                results.append(core.registers[0])
            }
        }
        XCTAssertEqual(results, [UInt64](repeating: 0x11, count: 6))
    }

    /// Deux `add $1, %rcx` devant : la première instruction d'une course
    /// passe par la boucle ordinaire, qui garde la page ; le bloc commence à
    /// la seconde, et ce qui suit est **au milieu** d'un bloc.
    static let lead: [UInt8] = [0x48, 0x83, 0xC1, 0x01, 0x48, 0x83, 0xC1, 0x01]

    /// **`hlt` au milieu d'un bloc arrête là** : ce qui le suit ne s'exécute
    /// pas, comme en tête de boucle.
    func testAHaltInsideABlockStopsThere() throws {
        let code: [UInt8] = Self.lead + [0x48, 0x83, 0xC0, 0x01, 0xF4, 0x48, 0x83, 0xC0, 0x40, 0xF4]
        let (plain, blocks) = try both(code, budget: 10)
        XCTAssertEqual(plain, blocks)
        XCTAssertEqual(blocks.registers[0], 1)
        XCTAssertEqual(blocks.retired, 4)
    }

    /// **Le budget se tient au milieu d'un bloc**, à l'instruction près.
    func testTheBudgetStopsInsideABlock() throws {
        let code = [UInt8](repeating: 0, count: 0).appending(count: 12, of: [0x48, 0x83, 0xC0, 0x01]) + [0xF4]
        for budget in UInt64(1)...12 {
            var (core, _) = try Self.machine(code)
            XCTAssertEqual(try core.run(budget: budget), budget)
            XCTAssertEqual(core.registers[0], budget, "budget \(budget)")
            XCTAssertEqual(core.rip, Self.code + budget * 4)
        }
    }

    /// **Une table de pages rechargée au milieu d'un bloc** : l'instruction
    /// d'après vient de la trame neuve, pas du bloc.
    func testAReloadedPageTableInsideABlockIsFollowed() throws {
        // mov %rax, %cr3 ; add $1, %rbx — et dans l'autre trame : add $2, %rbx.
        let code: [UInt8] = Self.lead + [0x0F, 0x22, 0xD8, 0x48, 0x83, 0xC3, 0x01, 0xF4]
        let other: UInt64 = 0x30000
        let (plain, blocks) = try both(code, budget: 6) { core, memory in
            try memory.load(Self.lead + [0x0F, 0x22, 0xD8, 0x48, 0x83, 0xC3, 0x02, 0xF4], at: other)
            // Une seconde racine, où la page du code désigne l'autre trame.
            for (table, at) in [(UInt64(0x3A000), Pages.pml4), (0x3B000, Pages.pdpt),
                                (0x3C000, Pages.directory), (0x3D000, Pages.table)] {
                let bytes = Array(UnsafeBufferPointer(start: memory.bytes + Int(at), count: 0x1000))
                try memory.load(bytes, at: table)
            }
            try memory.write(0x3A000, 8, 0x3B000 | Self.open)
            try memory.write(0x3B000, 8, 0x3C000 | Self.open)
            try memory.write(0x3C000, 8, 0x3D000 | Self.open)
            try memory.write(0x3D000 &+ (Self.code >> 12) * 8, 8, other | Self.open)
            core.registers[0] = 0x3A000
        }
        XCTAssertEqual(plain, blocks)
        XCTAssertEqual(blocks.registers[3], 2, "lu dans la trame que la table neuve désigne")
    }

    /// **Un bloc de 64 bits ne sert pas en mode compatibilité** : les mêmes
    /// octets s'y lisent autrement (`48` y est `dec %eax`, pas REX.W).
    func testA64BitBlockIsNotUsedInCompatibilityMode() throws {
        let code: [UInt8] = [0x48, 0x01, 0xD8, 0x48, 0x01, 0xD8, 0xF4]  // add %rbx, %rax, deux fois
        var (core, _) = try Self.machine(code)
        core.registers[0] = 10
        core.registers[3] = 3
        XCTAssertEqual(try core.run(budget: 2), 2)
        XCTAssertEqual(core.registers[0], 16)
        XCTAssertGreaterThan(core.storedBlockCache?.builds ?? 0, 0, "le bloc de 64 bits est rangé")
        // Le même endroit, en mode compatibilité : dec %eax ; add %ebx, %eax.
        core.setCompatibilityMode(true)
        core.rip = Self.code
        core.registers[0] = 10
        XCTAssertEqual(try core.run(budget: 4), 4)
        XCTAssertEqual(core.registers[0], 14, "deux fois « moins un, plus trois »")
    }

    /// **L'horloge interrompt à la même instruction**, avec ou sans blocs :
    /// le matériel se sert tous les 256, en tête de boucle.
    func testTheTimerInterruptsAtTheSameInstruction() throws {
        // Une boucle de formes courtes sans fin : add $1, %rax ; … ; jmp.
        let loop = [UInt8]().appending(count: 6, of: [0x48, 0x83, 0xC0, 0x01]) + [0xEB, 0xE6]
        let (plain, blocks) = try both(loop, budget: 400_000) { core, memory in
            // Une porte pour le vecteur 0x30, vers un `hlt`.
            let handler: UInt64 = 0x8000
            try memory.load([0xF4], at: handler)
            let low = (handler & 0xFFFF) | (UInt64(0x10) << 16) | (UInt64(0x8E) << 40)
                | ((handler & 0xFFFF_0000) << 32)
            try memory.write(0x9000 &+ 0x30 * 16, 8, low)
            try memory.write(0x9000 &+ 0x30 * 16 &+ 8, 8, 0)
            core.descriptorBases[1] = 0x9000
            core.descriptorLimits[1] = 0xFFF
            X86LegacyDevicesTests.armed(&core)
        }
        XCTAssertEqual(plain, blocks)
        XCTAssertTrue(blocks.halted, "le gestionnaire a été atteint")
        XCTAssertGreaterThan(blocks.retired, 256)
        XCTAssertLessThan(blocks.retired, 400_000)
    }

    /// Ce que les blocs occupent au plus, et la forme d'une case.
    func testTheBlockCacheFootprintIsWhatItSays() {
        XCTAssertEqual(X86BlockCache.footprint, 32_768 * 384)
        XCTAssertLessThanOrEqual(X86BlockCache.footprint, 13 << 20, "treize Mio d'adresses au plus")
        XCTAssertEqual(X86BlockCache.span, 32)
    }
}

private extension Array where Element == UInt8 {
    func appending(count: Int, of bytes: [UInt8]) -> [UInt8] {
        self + (0..<count).flatMap { _ in bytes }
    }
}
