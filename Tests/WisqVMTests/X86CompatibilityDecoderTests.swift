import XCTest

@testable import WisqVM

/// **Le décodeur en mode compatibilité**, jugé par `objdump -M i386`.
///
/// Un programme 32 bits sous un noyau 64 bits — le busybox statique de
/// l'initramfs de MX Linux en est un — s'exécute avec un segment de code dont
/// le bit L vaut zéro. Les mêmes octets n'y veulent pas dire la même chose :
/// `40`–`4F` sont `INC` et `DEC` et non REX, `C4`/`C5` sont `LES`/`LDS` quand
/// un ModRM mémoire suit, `mod 00 rm 101` est une adresse absolue et non
/// relative à RIP, un `CALL rel` raccourcit avec `0x66`. Décodé en 64 bits,
/// ce busybox lisait `dec ebx` comme un préfixe, et `init` mourait à
/// l'adresse zéro.
final class X86CompatibilityDecoderTests: XCTestCase {
    /// Les formes qui diffèrent du mode 64 bits, une par une.
    func testTheThirtyTwoBitFormsHaveTheirOwnLength() throws {
        let cases: [([UInt8], Int)] = [
            ([0x4B], 1),  // dec ebx — un préfixe REX en 64 bits
            ([0x40, 0x90], 1),  // inc eax, puis nop
            ([0x06], 1),  // push es
            ([0x60], 1),  // pusha
            ([0xC5, 0x06], 2),  // lds eax, [esi] — un VEX en 64 bits
            ([0xC5, 0xF8, 0x77], 3),  // vzeroupper : mod 11, donc VEX
            ([0x9A, 1, 2, 3, 4, 5, 6], 7),  // call ptr16:32
            ([0x66, 0xE8, 1, 2], 4),  // call rel16
            ([0xE8, 1, 2, 3, 4], 5),  // call rel32
            ([0xA1, 1, 2, 3, 4], 5),  // mov eax, [moffs32]
            ([0x67, 0x8B, 0x46, 0x02], 4),  // mov eax, [bp+2], adressage 16 bits
            ([0xB8, 1, 2, 3, 4], 5),  // mov eax, imm32
            ([0x0F, 0x84, 1, 2, 3, 4], 6),  // je rel32
            ([0xD4, 0x0A], 2),  // aam
        ]
        for (bytes, length) in cases {
            let instruction = try X86Decoder.decode(bytes, compatibility: true)
            XCTAssertEqual(instruction.length, length, "\(bytes.map { String($0, radix: 16) })")
            XCTAssertTrue(instruction.isCompatibility)
        }
    }

    /// `mod 00 rm 101` n'a pas de base : c'est une adresse absolue.
    func testTheRipRelativeFormIsAnAbsoluteAddress() throws {
        let compat = try X86Decoder.decode([0x8B, 0x05, 0x78, 0x56, 0x34, 0x12], compatibility: true)
        XCTAssertEqual(compat.baseField, X86Instruction.noRegister)
        let long = try X86Decoder.decode([0x8B, 0x05, 0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(long.baseField, X86Instruction.ripRelative)
        XCTAssertFalse(long.isCompatibility)
    }

    /// **Les longueurs d'un vrai programme 32 bits**, échantillon du busybox
    /// de MX Linux désassemblé par `objdump` : une instruction sur cinquante
    /// de son code, avec ses octets.
    func testEveryInstructionOfARealProgramHasObjdumpsLength() throws {
        // `WISQ_I386_TSV` désigne la liste complète, pour juger tout le
        // programme plutôt que l'échantillon.
        let path = ProcessInfo.processInfo.environment["WISQ_I386_TSV"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/x86-i386-lengths.tsv").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var checked = 0
        var wrong: [String] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count >= 2 else { continue }
            let hex = Array(fields[1].utf8)
            let bytes = stride(from: 0, to: hex.count, by: 2).map {
                UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16)!
            }
            checked += 1
            do {
                let decoded = try X86Decoder.decode(bytes, compatibility: true)
                if decoded.length != bytes.count { wrong.append("\(line) → \(decoded.length)") }
            } catch {
                wrong.append("\(line) → \(error)")
            }
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertEqual(wrong.count, 0, wrong.prefix(20).joined(separator: "\n"))
    }

    /// **Chaque instruction du même programme s'exécute**, en mode
    /// compatibilité : aucune ne doit tomber sur un « pas encore » du cœur.
    ///
    /// Le contenu des registres et de la mémoire n'est pas jugé ici — c'est
    /// le travail des oracles —, seulement que la forme a une exécution. Une
    /// faute de page ou une adresse hors de la mémoire est le sort normal
    /// d'une instruction sortie de son programme ; un `unsupported`, non.
    /// C'est ainsi qu'ont été trouvés, en une passe, les trous que le
    /// démarrage de MX Linux aurait révélés un à un, six minutes chacun.
    func testEveryInstructionOfARealProgramExecutes() throws {
        let path = ProcessInfo.processInfo.environment["WISQ_I386_TSV"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/x86-i386-lengths.tsv").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let memory = X86Memory(size: 0x40_0000, base: 0)
        var core = X86Core(memory: memory)
        core.setCompatibilityMode(true)
        var missing: [String: String] = [:]
        var executed = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count >= 2 else { continue }
            let hex = Array(fields[1].utf8)
            let bytes = stride(from: 0, to: hex.count, by: 2).map {
                UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16)!
            }
            let instruction = try X86Decoder.decode(bytes, compatibility: true)
            for index in 0..<8 { core.registers[index] = 0x20_0000 }
            core.rip = 0x10_0000
            do {
                try core.execute(instruction)
                executed += 1
            } catch X86Core.Fault.unsupported(let what) {
                // Sans table d'interruptions, `int $0x80` n'a nulle part où
                // aller : c'est la machine de test qui manque, pas le cœur.
                if !what.hasPrefix("INT ") { missing[String(fields[2])] = what }
            } catch X86Core.Fault.invalidOpcode where bytes.suffix(2) != [0x0F, 0x0B] {
                // Un #UD hors de `UD2` : une forme que le cœur refuse.
                missing[String(fields[2])] = "#UD"
            } catch {
                executed += 1
            }
        }
        XCTAssertGreaterThan(executed, 100)
        XCTAssertEqual(missing.count, 0, missing.sorted { $0.key < $1.key }
            .prefix(40).map { "\($0.key) → \($0.value)" }.joined(separator: "\n"))
    }

    /// **En 32 bits, base et décalage s'ajoutent modulo quatre gibioctets.**
    /// Le TLS se lit sous la base de GS : `mov %gs:(%esi), %edi` avec ESI =
    /// 0xFFFFFFF8 vise huit octets plus bas. L'`init` de MX Linux en restait
    /// là, à refauter sans fin. Et `mov %gs:0xc, %eax`, l'adresse absolue
    /// (`A1`), qui suivait immédiatement.
    func testThirtyTwoBitAddressesWrapUnderTheSegmentBase() throws {
        let memory = X86Memory(size: 0x10000, base: 0)
        try memory.load([0x44, 0x33, 0x22, 0x11], at: 0x1FF8)
        try memory.load([0x88, 0x77, 0x66, 0x55], at: 0x200C)
        var core = X86Core(memory: memory)
        core.setCompatibilityMode(true)
        core.system.modelSpecific[X86SystemState.gsBase] = 0x2000
        core.registers[6] = 0xFFFF_FFF8
        try core.execute(X86Decoder.decode([0x65, 0x8B, 0x3E], compatibility: true))
        XCTAssertEqual(core.registers[7], 0x1122_3344)
        try core.execute(X86Decoder.decode([0x65, 0xA1, 0x0C, 0, 0, 0], compatibility: true))
        XCTAssertEqual(core.registers[0], 0x5566_7788)
        core.registers[0] = 0xAABB_CCDD
        try core.execute(X86Decoder.decode([0x65, 0xA3, 0x10, 0, 0, 0], compatibility: true))
        XCTAssertEqual(try memory.read(0x2010, 4), 0xAABB_CCDD)
    }
}
