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

    /// **Le jour est venu, et le refus est devenu une règle.**
    ///
    /// Cette place tenait l'inverse : `MOVSS` et `MOVSD` partagent leurs octets
    /// avec `MOVUPS` — seul le préfixe les sépare — et le cœur les refusait
    /// plutôt que de les confondre avec leur voisine large. Le refus disait
    /// quelle brique poser le jour où la machine la demanderait. Elle l'a
    /// demandée : une fois `/init` vivant et le SSE2 entier en place, la course
    /// s'arrête sur `0F 11` préfixé, dans le binaire d'Alpine.
    ///
    /// Ce que le test exige maintenant est **ce que le processeur fait**, et
    /// c'est une règle qui n'appartient qu'à ces deux instructions : la source
    /// décide. Depuis un **registre**, seuls les bits utiles bougent et le
    /// reste de la destination est laissé tel quel. Depuis la **mémoire**, tout
    /// le reste est mis à zéro. L'oracle le tient sur 928 cas ; ici on fixe le
    /// cas de registre, parce que c'est le seul où une lecture rapide se
    /// tromperait.
    func testAScalarMoveFromARegisterLeavesTheRestAlone() throws {
        for (prefix, kept) in [(UInt8(0xF3), UInt64(0x1111_0000_3333)),
                               (UInt8(0xF2), UInt64(0x3333_0000_3333))] {
            let ram = try Self.memory([prefix, 0x0F, 0x10, 0xC1])  // movss/movsd %xmm1,%xmm0
            var core = Self.core(ram)
            core.setVector(0, 0x1111_0000_1111, 0x2222)
            core.setVector(1, 0x3333_0000_3333, 0x4444)
            _ = try core.run(budget: 1)
            XCTAssertEqual(core.vectors[0], kept, "préfixe \(prefix)")
            XCTAssertEqual(core.vectors[1], 0x2222, "le haut ne bouge pas depuis un registre")
        }
    }

    /// Et depuis la mémoire, la même instruction efface tout le reste. Les
    /// deux moitiés de la règle sont dans le même fichier parce que c'est leur
    /// écart qui est la règle.
    func testAScalarMoveFromMemoryClearsEverythingElse() throws {
        // movss (%rsi),%xmm0
        let ram = try Self.memory([0xF3, 0x0F, 0x10, 0x06])
        try ram.write(0x2000, 8, 0x0123_4567_89AB_CDEF)
        var core = Self.core(ram)
        core.registers[6] = 0x2000
        core.setVector(0, 0x1111_1111_1111_1111, 0x2222_2222_2222_2222)
        _ = try core.run(budget: 1)
        XCTAssertEqual(core.vectors[0], 0x89AB_CDEF, "trente-deux bits lus")
        XCTAssertEqual(core.vectors[1], 0, "et tout le reste effacé")
    }

    /// L'arithmétique **empaquetée** est refusée de la même façon, et le
    /// scalaire ne l'est plus.
    ///
    /// Cette place tenait le refus de `mulsd` ; la machine l'a réclamée, et le
    /// septième corpus la tient maintenant contre le vrai processeur. Ce qui
    /// reste refusé est la forme qui traite les deux valeurs du registre à la
    /// fois : elle apparaît une poignée de fois dans l'espace utilisateur de
    /// l'invité, dans du code que ce démarrage n'atteint pas.
    ///
    /// C'est un état, pas un manque caché — et la démonstration que la règle
    /// du dépôt tient dans les deux sens : ce qui est demandé est écrit et
    /// mesuré, ce qui ne l'est pas s'arrête en le disant.
    func testPackedArithmeticIsStillRefusedByName() throws {
        // `66 0f 59 c1` : mulpd %xmm1,%xmm0
        let ram = try Self.memory([0x66, 0x0F, 0x59, 0xC1])
        var core = Self.core(ram)
        core.setVector(0, 0x3FF0_0000_0000_0000, 0x4000_0000_0000_0000)
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            guard case .unsupported(let name)? = error as? X86Core.Fault else {
                return XCTFail("attendu un refus nommé, reçu \(error)")
            }
            XCTAssertTrue(name.contains("59"), "il faut nommer l'opcode : \(name)")
        }
        XCTAssertEqual(core.vectors[0], 0x3FF0_0000_0000_0000,
                       "et rien n'a été écrit avant de refuser")
    }

    /// **`UCOMISS` et `UCOMISD` n'existent qu'à deux préfixes près**, et le
    /// bras qui les portait n'en gardait qu'un.
    ///
    /// `case 0x2E, 0x2F where !single && !doubleWide` se lit comme si la
    /// condition tenait pour les deux ; en Swift elle ne s'applique qu'au
    /// **second** motif — le compilateur le dit d'ailleurs. `f3 0f 2e`, qui
    /// n'est pas une instruction, était donc exécuté comme une comparaison au
    /// lieu d'être refusé par son nom. Ce sont les encodages valides qui
    /// comptent ici, et un cœur qui exécute ce qui n'existe pas ment sur ce
    /// qu'il sait faire.
    func testAComparisonWithAScalarPrefixIsNotAnInstruction() throws {
        // `f3 0f 2e c1` : rien du tout. UCOMISS n'a pas de forme scalaire.
        let ram = try Self.memory([0xF3, 0x0F, 0x2E, 0xC1])
        var core = Self.core(ram)
        let before = core.flags
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            guard case .unsupported(let name)? = error as? X86Core.Fault else {
                return XCTFail("attendu un refus nommé, reçu \(error)")
            }
            XCTAssertTrue(name.contains("2E"), "il faut nommer l'opcode : \(name)")
        }
        XCTAssertEqual(core.flags, before, "et aucun drapeau posé avant de refuser")
    }

    /// Les deux formes qui existent, elles, comparent : sans préfixe sur des
    /// flottants simples, et avec `66` sur des doubles.
    func testBothRealComparisonsStillLand() throws {
        for (code, bits) in [([0x0F, 0x2E, 0xC1] as [UInt8], (2.0 as Float).bitPattern == 0),
                             ([0x66, 0x0F, 0x2E, 0xC1], true)] {
            _ = bits
            let ram = try Self.memory(code)
            var core = Self.core(ram)
            core.setVector(0, (1.0 as Double).bitPattern, 0)
            core.setVector(1, (1.0 as Double).bitPattern, 0)
            _ = try core.run(budget: 1)
            XCTAssertNotEqual(core.flags & X86Core.Flag.zero, 0,
                              "deux valeurs égales posent le zéro")
        }
    }

    /// **`CLFLUSH` ne fait rien, mais ne doit pas refuser.** Il n'y a pas de
    /// cache à vider ici ; refuser l'instruction arrêterait net un noyau qui
    /// repose les permissions d'une page — `cpa_flush` l'appelle. `CPUID` ne
    /// l'annonce pas, et ce n'est pas une raison : un noyau qui la trouve s'en
    /// sert sans prévenir, et une machine qui s'arrête sur une instruction
    /// sans effet est pire qu'une machine qui l'ignore.
    func testCacheFlushIsAcceptedAndDoesNothing() throws {
        // `0f ae 38` : clflush (%rax) — l'adresse est cartographiée.
        let ram = try Self.memory([0x0F, 0xAE, 0x38])
        var core = Self.core(ram)
        core.registers[0] = 0x200
        try ram.write(0x200, 8, 0xC0FFEE)
        try core.run(budget: 1)
        XCTAssertEqual(try ram.read(0x200, 8), 0xC0FFEE, "la mémoire est intacte")
        XCTAssertEqual(core.rip, 0x103, "et l'instruction est passée")
    }

    /// Et le scalaire, lui, aboutit : la même multiplication sur une seule
    /// valeur rend deux fois un, et laisse la moitié haute intacte.
    func testScalarArithmeticNowLands() throws {
        let ram = try Self.memory([0xF2, 0x0F, 0x59, 0xC1])  // mulsd %xmm1,%xmm0
        var core = Self.core(ram)
        core.setVector(0, (2.0 as Double).bitPattern, 0xAAAA)
        core.setVector(1, (3.0 as Double).bitPattern, 0xBBBB)
        _ = try core.run(budget: 1)
        XCTAssertEqual(Double(bitPattern: core.vectors[0]), 6.0)
        XCTAssertEqual(core.vectors[1], 0xAAAA, "la moitié haute est laissée telle quelle")
    }
}
