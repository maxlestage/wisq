import XCTest
@testable import WisqVM

/// Le cache des instructions décodées : il sert, et il ne ment jamais.
final class X86DecodeCacheTests: XCTestCase {
    private func machine(_ program: [UInt8]) throws -> X86Core {
        let memory = X86Memory(size: 0x4000, base: 0x1000)
        try memory.load(program, at: 0x1000)
        var registers = [UInt64](repeating: 0, count: 16)
        registers[4] = 0x1000 + 0x4000 - 0x100
        return X86Core(registers: registers, rip: 0x1000, memory: memory)
    }

    /// **Le code qui se réécrit.** Une boucle exécute `incq %rax`, remplace
    /// ses deux derniers octets pour en faire `decq %rax`, et repasse au même
    /// endroit : c'est la nouvelle instruction qui doit tourner, alors que
    /// l'ancienne est dans le cache, à la même adresse. Un cache qui ne
    /// vérifiait pas ses octets rendrait `rax = 2` au lieu de `0`.
    func testCodeThatRewritesItselfRunsItsNewInstruction() throws {
        var core = try machine([
            0x48, 0xFF, 0xC0,  // 1000 : incq %rax  (devient decq %rax)
            0x48, 0x83, 0xF9, 0x01,  // 1003 : cmpq $1, %rcx
            0x74, 0x0F,  // 1007 : je 1018
            0x48, 0xFF, 0xC1,  // 1009 : incq %rcx
            0x66, 0xC7, 0x04, 0x25, 0x01, 0x10, 0x00, 0x00, 0xFF, 0xC8,  // 100c : movw $0xc8ff, 0x1001
            0xEB, 0xE8,  // 1016 : jmp 1000
            0xF4,  // 1018 : hlt
        ])
        _ = try core.run(budget: 100)
        XCTAssertTrue(core.halted)
        XCTAssertEqual(core.registers[0], 0, "decq après incq : la seconde passe a lu le code réécrit")
        XCTAssertEqual(core.registers[1], 1)
    }

    /// Une boucle repasse sur les mêmes instructions : après le premier tour,
    /// elles viennent du cache. Mille tours de trois instructions, et trois
    /// décodages — le reste trouvé.
    func testALoopIsDecodedOnceAndThenFound() throws {
        var core = try machine([
            0x48, 0xFF, 0xC0,  // 1000 : incq %rax
            0x48, 0xFF, 0xC9,  // 1003 : decq %rcx
            0x75, 0xF8,  // 1006 : jne 1000
            0xF4,  // 1008 : hlt
        ])
        core.registers[1] = 1000
        _ = try core.run(budget: 10_000)
        XCTAssertEqual(core.registers[0], 1000)
        XCTAssertGreaterThanOrEqual(core.decodeCache.hits, 2995)
        XCTAssertLessThanOrEqual(core.decodeCache.misses, 4)
    }

    /// Le cache se paie en mémoire, une fois par machine : il doit rester
    /// petit devant la RAM de l'invité, même sur un téléphone.
    func testTheCacheStaysSmallBesideTheGuestsMemory() {
        XCTAssertLessThanOrEqual(X86DecodeCache.footprint, 10 << 20, "dix Mio au plus")
        XCTAssertGreaterThanOrEqual(X86DecodeCache.slots, 1 << 17,
                                    "le code chaud de Fedora ne tient pas dans moins")
    }

    /// **Le commentaire de `slots` chiffre ce que le cache prend, et ce chiffre
    /// se recompte.**
    ///
    /// Il n'était tenu par rien : `footprint` le calcule, la prose le recopie.
    /// Elle annonçait « 9,4 Mio » là où le cache en prend 9 437 184 octets,
    /// soit 9,0 — le nombre avait été divisé par un million au lieu de
    /// 1 048 576. Le mébioctet est pourtant l'unité du dépôt (« 2 Gio » pour
    /// `2 * 1024 * 1024 * 1024`, « seize kibioctets » pour 16 384), et le
    /// fichier lui-même écrit plus bas que le cache « a grandi à 6 Mio »
    /// quand il avait 65 536 cases — une phrase que la nouvelle contredisait
    /// en annonçant le même 9,4 pour ces mêmes 65 536 cases.
    ///
    /// **Le périmètre est le commentaire de `slots`, et lui seul** : la suite
    /// du fichier contraste le passé et le présent exprès, et une garde qui
    /// interdirait le contraste interdirait l'explication.
    ///
    /// **Ce qu'elle tient, et pas plus** : le bloc porte au moins un chiffre
    /// qui vaut le `footprint` d'aujourd'hui. Elle n'interdit pas qu'il en
    /// porte d'autres — les valeurs d'hier y ont leur place — donc elle
    /// attrape le chiffre absent, pas le chiffre de trop.
    func testTheCommentOnSlotsStatesTheRealFootprint() throws {
        let source = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WisqVM/X86DecodeCache.swift")
                .path,
            encoding: .utf8
        )

        // Le bloc `///` qui précède immédiatement la déclaration : on remonte
        // ligne à ligne depuis elle, et on s'arrête à la première qui n'en est
        // pas. Nommer un numéro de ligne ferait une garde qui vieillit au
        // premier paragraphe ajouté.
        let lines = source.components(separatedBy: "\n")
        guard let at = lines.firstIndex(where: { $0.contains("static let slots") }) else {
            return XCTFail("X86DecodeCache ne déclare plus `slots` là où ce test le lit")
        }
        var first = at
        while first > 0, lines[first - 1].trimmingCharacters(in: .whitespaces).hasPrefix("///") {
            first -= 1
        }
        XCTAssertGreaterThan(at - first, 1, "`slots` n'a plus de commentaire au-dessus")
        let bloc = lines[first..<at].joined(separator: " ")

        let pattern = try NSRegularExpression(pattern: "([0-9]+(?:,[0-9]+)?) Mio")
        let dits = pattern
            .matches(in: bloc, range: NSRange(bloc.startIndex..., in: bloc))
            .map { String(bloc[Range($0.range(at: 1), in: bloc)!]) }
        XCTAssertFalse(dits.isEmpty,
                       "le commentaire de `slots` ne chiffre plus ce que le cache prend")

        let réel = Double(X86DecodeCache.footprint) / 1_048_576
        let accordé = dits.contains { jeton in
            guard let dit = Double(jeton.replacingOccurrences(of: ",", with: ".")) else {
                return false
            }
            return abs(dit - réel) <= 0.1
        }
        XCTAssertTrue(
            accordé,
            "le commentaire de `slots` dit \(dits.map { "« \($0) Mio »" }.joined(separator: ", "))"
                + " et aucun ne vaut ce que le cache prend : \(X86DecodeCache.footprint)"
                + " octets, soit \(String(format: "%.1f", réel)) Mio"
        )
    }

    /// La case elle-même : une entrée ne sert que pour ses octets, et que si
    /// elle tient dans ce que la lecture s'autorise — la borne de page quand
    /// la pagination est active.
    func testAnEntryServesOnlyItsBytesAndOnlyWithinTheAllowedRoom() throws {
        let memory = X86Memory(size: 0x1000)
        let jump: [UInt8] = [0x0F, 0x8E, 0x10, 0x20, 0x30, 0x40]  // jle rel32, six octets
        try memory.load(jump, at: 0x100)
        let cache = X86DecodeCache()
        let decoded = try X86Decoder.decode(jump)
        XCTAssertNil(cache.lookup(memory.bytes, at: 0x100, size: memory.size, available: 15),
                     "rien encore")
        cache.store(decoded, memory.bytes, at: 0x100, size: memory.size)
        XCTAssertEqual(cache.lookup(memory.bytes, at: 0x100, size: memory.size, available: 15),
                       decoded)
        XCTAssertNil(cache.lookup(memory.bytes, at: 0x100, size: memory.size, available: 4),
                     "six octets ne tiennent pas dans les quatre qui restent de la page")
        // L'octet qui suit l'instruction n'en fait pas partie : le changer ne
        // change rien.
        memory.bytes[0x106] = 0xCC
        XCTAssertEqual(cache.lookup(memory.bytes, at: 0x100, size: memory.size, available: 15),
                       decoded)
        // Le dernier octet du déplacement, si.
        memory.bytes[0x105] = 0x41
        XCTAssertNil(cache.lookup(memory.bytes, at: 0x100, size: memory.size, available: 15))
        // Au bord de la mémoire, pas de lecture de seize octets : on décode.
        cache.store(decoded, memory.bytes, at: 0x1000 - 8, size: memory.size)
        XCTAssertNil(cache.lookup(memory.bytes, at: 0x1000 - 8, size: memory.size, available: 8))
    }
}
