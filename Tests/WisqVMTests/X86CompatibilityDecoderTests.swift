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
}
