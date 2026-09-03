import XCTest

@testable import WisqVM

/// La forme d'une instruction x86-64, pièce par pièce.
///
/// Le différentiel d'à côté prouve la **longueur** sur des centaines de
/// milliers d'instructions ; il ne dit rien de ce que le décodeur en a compris.
/// Ces tests-là regardent les pièces : quel préfixe, quelle table, quel ModRM,
/// quel déplacement, quel immédiat. Un décodeur peut tomber sur la bonne
/// longueur pour de mauvaises raisons — deux erreurs qui s'annulent — et c'est
/// exactement ce que le différentiel seul laisserait passer.
///
/// Les octets viennent tous du corpus ou de l'assembleur GNU, jamais d'une
/// invention : chaque suite est une instruction que quelque chose a vraiment
/// produite.
final class X86DecoderTests: XCTestCase {
    func decode(_ bytes: [UInt8]) throws -> X86Instruction {
        try X86Decoder.decode(bytes)
    }

    /// `endbr64` : `f3 0f 1e fa`. Un préfixe, la table `0F`, un ModRM, rien
    /// derrière. C'est la première instruction de presque toute fonction
    /// compilée aujourd'hui.
    func testAPrefixedTwoByteOpcodeIsTakenApart() throws {
        let instruction = try decode([0xF3, 0x0F, 0x1E, 0xFA])
        XCTAssertEqual(instruction.legacyPrefixes, [0xF3])
        XCTAssertNil(instruction.rex)
        XCTAssertEqual(instruction.map, .twoByte)
        XCTAssertEqual(instruction.opcode, 0x1E)
        XCTAssertEqual(instruction.modrm, 0xFA)
        XCTAssertNil(instruction.sib)
        XCTAssertEqual(instruction.displacementBytes, 0)
        XCTAssertEqual(instruction.immediateBytes, 0)
        XCTAssertEqual(instruction.length, 4)
    }

    /// `sub $0x8,%rsp` : `48 83 ec 08`. REX.W, l'opcode `83` du groupe
    /// arithmétique, et son immédiat d'**un** octet étendu au signe — pas
    /// quatre, bien que l'opérande fasse soixante-quatre bits. C'est le piège
    /// que `81` et `83` posent en se ressemblant.
    func testTheSignExtendedByteImmediateIsNotWidenedByRexW() throws {
        let instruction = try decode([0x48, 0x83, 0xEC, 0x08])
        XCTAssertEqual(instruction.rex, 0x48)
        XCTAssertEqual(instruction.map, .oneByte)
        XCTAssertEqual(instruction.opcode, 0x83)
        XCTAssertEqual(instruction.immediateBytes, 1)
        XCTAssertEqual(instruction.length, 4)

        // Le voisin immédiat, lui, en porte quatre.
        let wide = try decode([0x48, 0x81, 0xEC, 0x08, 0x00, 0x00, 0x00])
        XCTAssertEqual(wide.opcode, 0x81)
        XCTAssertEqual(wide.immediateBytes, 4)
        XCTAssertEqual(wide.length, 7)
    }

    /// `mov 0x1efb9(%rip),%rax` : `48 8b 05 b9 ef 01 00`. `mod` vaut 00 et
    /// `rm` vaut 101, ce qui en mode 64 bits ne veut **pas** dire « pas de
    /// déplacement » mais « relatif à RIP, sur quatre octets ». C'est le
    /// désaccord le plus fréquent quand on transpose un décodeur 32 bits.
    func testRipRelativeIsFourBytesAndNotNone() throws {
        let instruction = try decode([0x48, 0x8B, 0x05, 0xB9, 0xEF, 0x01, 0x00])
        XCTAssertEqual(instruction.modrm, 0x05)
        XCTAssertNil(instruction.sib, "rm vaut 101, pas 100 : il n'y a pas de SIB")
        XCTAssertEqual(instruction.displacementBytes, 4)
        XCTAssertEqual(instruction.length, 7)
    }

    /// Un SIB dont la base vaut 101 avec `mod` à 00 : la base n'existe pas et
    /// un déplacement de quatre octets la remplace. `8b 04 25 00 00 00 00`,
    /// qu'objdump rend « mov 0x0,%eax » — une adresse absolue et aucun
    /// registre, ce qui est exactement ce que la base absente veut dire.
    func testASibBaseOfFiveWithoutModMeansAFourByteDisplacement() throws {
        let instruction = try decode([0x8B, 0x04, 0x25, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(instruction.modrm, 0x04)
        XCTAssertEqual(instruction.sib, 0x25)
        XCTAssertEqual(instruction.displacementBytes, 4)
        XCTAssertEqual(instruction.length, 7)

        // Le même SIB avec mod à 01 : un octet de déplacement, pas quatre.
        let byteDisplacement = try decode([0x8B, 0x44, 0x25, 0x10])
        XCTAssertEqual(byteDisplacement.sib, 0x25)
        XCTAssertEqual(byteDisplacement.displacementBytes, 1)
        XCTAssertEqual(byteDisplacement.length, 4)
    }

    /// `F7` porte sept opérations dans le champ `reg` de son ModRM, et une
    /// seule d'entre elles — `TEST` — traîne un immédiat. Un décodeur qui
    /// lirait l'immédiat pour les sept avancerait de quatre octets de trop six
    /// fois sur sept.
    func testTheImmediateOfTheF7GroupDependsOnItsRegField() throws {
        // test $0x11223344,(%rax) : reg = 0, immédiat de quatre octets.
        let test = try decode([0xF7, 0x00, 0x44, 0x33, 0x22, 0x11])
        XCTAssertEqual(test.immediateBytes, 4)
        XCTAssertEqual(test.length, 6)

        // notq (%rax) : reg = 2, aucun immédiat.
        let not = try decode([0x48, 0xF7, 0x10])
        XCTAssertEqual(not.immediateBytes, 0)
        XCTAssertEqual(not.length, 3)

        // idivq (%rax) : reg = 7, aucun immédiat non plus.
        let divide = try decode([0x48, 0xF7, 0x38])
        XCTAssertEqual(divide.immediateBytes, 0)
        XCTAssertEqual(divide.length, 3)
    }

    /// La même règle sur `F6`, dont l'immédiat fait un octet quand il existe.
    func testTheImmediateOfTheF6GroupFollowsTheSameRule() throws {
        let test = try decode([0xF6, 0x00, 0x42])
        XCTAssertEqual(test.immediateBytes, 1)
        XCTAssertEqual(test.length, 3)

        let negate = try decode([0xF6, 0x18])
        XCTAssertEqual(negate.immediateBytes, 0)
        XCTAssertEqual(negate.length, 2)
    }

    /// `0x66` raccourcit l'immédiat « taille d'opérande » de quatre octets à
    /// deux ; `REX.W` ne l'allonge pas à huit. Les deux moitiés de la règle
    /// comptent.
    func testTheOperandSizePrefixShortensTheImmediateAndRexWDoesNotLengthenIt() throws {
        let wide = try decode([0xC7, 0x00, 0x44, 0x33, 0x22, 0x11])
        XCTAssertEqual(wide.immediateBytes, 4)

        let narrow = try decode([0x66, 0xC7, 0x00, 0x22, 0x11])
        XCTAssertEqual(narrow.legacyPrefixes, [0x66])
        XCTAssertEqual(narrow.immediateBytes, 2)
        XCTAssertEqual(narrow.length, 5)

        // REX.W sur le même opcode : toujours quatre octets, étendus au signe.
        let sixtyFour = try decode([0x48, 0xC7, 0x00, 0x44, 0x33, 0x22, 0x11])
        XCTAssertEqual(sixtyFour.immediateBytes, 4)
        XCTAssertEqual(sixtyFour.length, 7)
    }

    /// `movabs` est le seul immédiat de huit octets, et il n'existe qu'avec
    /// `REX.W`. Sans lui, le même opcode en porte quatre.
    func testMovabsIsTheOnlyEightByteImmediate() throws {
        let sixtyFour = try decode(
            [0x48, 0xB8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
        XCTAssertEqual(sixtyFour.immediateBytes, 8)
        XCTAssertEqual(sixtyFour.length, 10)

        let thirtyTwo = try decode([0xB8, 0x44, 0x33, 0x22, 0x11])
        XCTAssertEqual(thirtyTwo.immediateBytes, 4)
        XCTAssertEqual(thirtyTwo.length, 5)

        let sixteen = try decode([0x66, 0xB8, 0x22, 0x11])
        XCTAssertEqual(sixteen.immediateBytes, 2)
        XCTAssertEqual(sixteen.length, 4)
    }

    /// Une adresse absolue (`moffs`) fait huit octets en mode 64 bits, et
    /// c'est le seul endroit où le préfixe de taille d'**adresse** change une
    /// longueur.
    func testAnAbsoluteAddressIsEightBytesAndFollowsTheAddressSizePrefix() throws {
        let absolute = try decode(
            [0x48, 0xA1, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
        XCTAssertEqual(absolute.opcode, 0xA1)
        XCTAssertNil(absolute.modrm, "moffs n'a pas de ModRM : l'adresse suit l'opcode")
        XCTAssertEqual(absolute.immediateBytes, 8)
        XCTAssertEqual(absolute.length, 10)

        let narrowed = try decode([0x67, 0x48, 0xA1, 0x44, 0x33, 0x22, 0x11])
        XCTAssertEqual(narrowed.immediateBytes, 4)
        XCTAssertEqual(narrowed.length, 7)
    }

    /// `ENTER` porte deux immédiats à la suite : un mot puis un octet. C'est la
    /// seule instruction dans ce cas, et un décodeur qui n'en lit qu'un se
    /// décale de deux octets.
    func testEnterCarriesAWordThenAByte() throws {
        let instruction = try decode([0xC8, 0x34, 0x12, 0x05])
        XCTAssertEqual(instruction.opcode, 0xC8)
        XCTAssertEqual(instruction.immediateBytes, 3)
        XCTAssertEqual(instruction.length, 4)
    }

    /// Un saut proche fait quatre octets de déplacement, et `0x66` ne le
    /// raccourcit pas en mode 64 bits — contrairement à ce que la règle
    /// générale des immédiats laisserait croire.
    func testANearJumpKeepsItsFourBytesEvenWithTheOperandSizePrefix() throws {
        let call = try decode([0xE8, 0xE2, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(call.immediateBytes, 4)
        XCTAssertEqual(call.length, 5)

        let conditional = try decode([0x0F, 0x84, 0x00, 0x01, 0x00, 0x00])
        XCTAssertEqual(conditional.map, .twoByte)
        XCTAssertEqual(conditional.immediateBytes, 4)
        XCTAssertEqual(conditional.length, 6)

        // Le saut court, lui, tient sur un octet.
        let short = try decode([0xEB, 0x10])
        XCTAssertEqual(short.immediateBytes, 1)
        XCTAssertEqual(short.length, 2)
    }

    /// Les trois tables d'échappement, reconnues pour ce qu'elles sont. Celle
    /// de `0F 3A` traîne toujours un octet immédiat ; celle de `0F 38`, jamais.
    func testTheThreeEscapeMapsAreToldApart() throws {
        let two = try decode([0x0F, 0xAF, 0xC1])  // imul %ecx,%eax
        XCTAssertEqual(two.map, .twoByte)
        XCTAssertEqual(two.length, 3)

        let three38 = try decode([0x66, 0x0F, 0x38, 0x17, 0xC1])  // ptest
        XCTAssertEqual(three38.map, .threeByte38)
        XCTAssertEqual(three38.immediateBytes, 0)
        XCTAssertEqual(three38.length, 5)

        let three3A = try decode([0x66, 0x0F, 0x3A, 0x63, 0xC1, 0x00])  // pcmpistri
        XCTAssertEqual(three3A.map, .threeByte3A)
        XCTAssertEqual(three3A.immediateBytes, 1)
        XCTAssertEqual(three3A.length, 6)
    }

    /// Un préfixe vectoriel désigne lui-même la table à lire, ce qui évite de
    /// tenir une seconde série de tables. Les trois formes existent : deux,
    /// trois et quatre octets.
    func testAVectorPrefixNamesItsOwnMap() throws {
        // c5 f8 57 c0 : vxorps %xmm0,%xmm0,%xmm0 — VEX à deux octets.
        let short = try decode([0xC5, 0xF8, 0x57, 0xC0])
        XCTAssertEqual(short.vex, [0xC5, 0xF8])
        XCTAssertEqual(short.map, .twoByte, "un VEX à deux octets vise toujours la table 0F")
        XCTAssertEqual(short.length, 4)

        // c4 e2 7d 18 c0 : vbroadcastss — VEX à trois octets, table 0F 38.
        let long = try decode([0xC4, 0xE2, 0x7D, 0x18, 0xC0])
        XCTAssertEqual(long.vex.count, 3)
        XCTAssertEqual(long.map, .threeByte38)
        XCTAssertEqual(long.immediateBytes, 0)
        XCTAssertEqual(long.length, 5)

        // 62 ... : EVEX, quatre octets avant l'opcode.
        let evex = try decode([0x62, 0xF1, 0x7C, 0x48, 0x28, 0xC1])
        XCTAssertEqual(evex.vex.count, 4)
        XCTAssertEqual(evex.map, .twoByte)
        XCTAssertEqual(evex.length, 6)
    }

    /// Des octets qui s'arrêtent au milieu ne produisent pas une longueur
    /// approximative : ils produisent un refus.
    func testTruncatedBytesAreRefusedRatherThanGuessed() {
        XCTAssertThrowsError(try decode([0x48])) { error in
            XCTAssertEqual(error as? X86DecodeError, .truncated)
        }
        // L'immédiat manque.
        XCTAssertThrowsError(try decode([0xC7, 0x00, 0x44, 0x33])) { error in
            XCTAssertEqual(error as? X86DecodeError, .truncated)
        }
        // Le déplacement relatif à RIP manque.
        XCTAssertThrowsError(try decode([0x48, 0x8B, 0x05, 0xB9])) { error in
            XCTAssertEqual(error as? X86DecodeError, .truncated)
        }
    }

    /// Un octet que le mode 64 bits ne décode pas est nommé, pas décodé en
    /// silence. `0x06` était `PUSH ES` ; il n'existe plus, et objdump le rend
    /// « (bad) » — les deux refusent le même octet.
    func testAnOpcodeThatDoesNotExistInSixtyFourBitModeIsNamed() {
        XCTAssertThrowsError(try decode([0x06])) { error in
            XCTAssertEqual(
                error as? X86DecodeError, .unsupportedOpcode(map: .oneByte, opcode: 0x06))
        }
    }

    /// Quinze octets, pas plus. Une file de préfixes ne peut pas faire tourner
    /// la boucle : le processeur refuserait aussi.
    func testAnInstructionLongerThanFifteenBytesIsRefused() {
        let prefixes = [UInt8](repeating: 0x66, count: 20) + [0x90]
        XCTAssertThrowsError(try decode(prefixes)) { error in
            XCTAssertEqual(error as? X86DecodeError, .tooLong)
        }
        XCTAssertEqual(X86Instruction.maximumLength, 15)
    }

    /// Décoder à partir d'un décalage, parce qu'un flux d'instructions ne
    /// commence pas à zéro après la première.
    func testDecodingContinuesFromAnOffset() throws {
        let stream: [UInt8] = [0xF3, 0x0F, 0x1E, 0xFA, 0x48, 0x83, 0xEC, 0x08, 0xC3]
        var offset = 0
        var lengths: [Int] = []
        while offset < stream.count {
            let instruction = try X86Decoder.decode(stream, at: offset)
            lengths.append(instruction.length)
            offset += instruction.length
        }
        XCTAssertEqual(lengths, [4, 4, 1], "endbr64, sub, ret — et rien qui déborde")
        XCTAssertEqual(offset, stream.count)
    }
}
