import Foundation
import XCTest

@testable import WisqVM

/// La marque qui sépare un instantané d'avant la pile x87 d'un instantané
/// d'après.
///
/// **Ce que ce fichier ne fait pas.** Il ne recompte pas les champs.
/// `X86SnapshotTests.testEveryFieldComesBack` les tient tous — la pile x87 et
/// son mot d'étiquettes compris, depuis #275 — et c'est là qu'ils vivent. Ce
/// qui suit ne parle que du **format** : de ce qui arrive quand les octets
/// qu'on lit n'ont pas été écrits par la version qui les lit.
///
/// **Pourquoi ce fichier s'appelait autrement.** #272 l'avait ouvert sous le
/// nom de témoin des champs, en écrivant que l'instantané x86 « n'a jamais
/// subi cette mesure » — parce que `SnapshotFieldWitnessTests.swift` ne nomme
/// pas l'x86 une seule fois. Vrai de ce fichier-là, faux du dépôt : le témoin
/// existait, sous un autre nom, dans `X86LocalMachineTests.swift`. Chercher
/// une garde par son nom plutôt que par ce qu'elle assertionne, c'est la
/// faute de #261 sous un autre habit, et elle avait coûté cent trente lignes
/// qui en doublaient d'autres — soit exactement ce que `VirtioQueue.swift`
/// appelle « deux descriptions du même protocole, à diverger dès la première
/// correction ».
final class X86SnapshotX87SectionTests: XCTestCase {
    /// **Un instantané écrit avant cette section doit encore se reprendre.**
    ///
    /// Des machines sont déjà sauvées sur des téléphones. La pile x87 s'ajoute
    /// donc en queue, derrière une marque, et son absence se lit comme « un
    /// instantané d'avant » plutôt que comme un dégât — exactement ce que le
    /// disque fait depuis #144. Le témoin est construit en coupant la marque
    /// et tout ce qui la suit.
    func testASnapshotWrittenBeforeTheX87StackStillRestores() throws {
        let complete = [UInt8](try X86SnapshotTests.marked().snapshot())
        let mark = try Self.theOnlyMark(in: complete)
        let brought = X86Machine(onOutput: { _ in })
        try brought.restore(Data(complete[0..<mark]))
        XCTAssertEqual(brought.core.rip, 0xDEAD_BEEF,
                       "un instantané d'avant la pile x87 doit encore rendre le reste")
        XCTAssertEqual(brought.core.x87Tags, 0xFFFF,
                       "sans la section, la pile doit rester celle d'une machine neuve")
    }

    /// **Le cas où la marque gagne son pain, et qu'un sabotage a révélé.**
    ///
    /// Le premier jet vérifiait la marque avant de lire la pile. Remplacer
    /// cette vérification par « il reste des octets » — ce que faisait le
    /// disque avant — laissait vert tout ce qui existait alors : la machine
    /// témoin n'avait pas de disque, donc « il reste des octets » et « la
    /// marque est là » disaient la même chose. Une garde qu'un sabotage
    /// traverse n'en est pas une.
    ///
    /// La marque ne sert que dans le seul cas où les deux divergent : un
    /// instantané **d'avant**, **avec un disque**. Là, il reste des octets et
    /// ce ne sont pas ceux de la pile x87 — les lire comme tels décalerait la
    /// section disque de cent huit octets et rendrait un disque faux, ou un
    /// refus, très loin de la cause.
    func testAnOlderSnapshotWithADiskIsNotReadAsAnX87Stack() throws {
        let machine = try X86SnapshotTests.marked()
        machine.attach(disk: X86DiskSnapshotTests.image())
        let complete = [UInt8](machine.snapshot())
        let mark = try Self.theOnlyMark(in: complete)
        // La marque, huit registres de quatre-vingts bits écrits en douze
        // octets chacun, et le mot d'étiquettes.
        let sectionLength = 8 + 8 * (8 + 4) + 4
        XCTAssertLessThanOrEqual(mark + sectionLength, complete.count,
                                 "la section x87 déborde de l'instantané")
        var older = Array(complete[0..<mark])
        older += complete[(mark + sectionLength)...]
        XCTAssertTrue(older.count < complete.count, "le témoin n'a rien retiré")

        let brought = X86Machine(onOutput: { _ in })
        do {
            try brought.restore(Data(older))
        } catch {
            return XCTFail("un instantané d'avant, avec un disque, a été refusé : \(error)")
        }
        XCTAssertNotNil(brought.disk,
                        "le disque d'un instantané d'avant a été lu comme une pile x87")
        XCTAssertEqual(brought.core.rip, 0xDEAD_BEEF,
                       "le reste de la machine doit revenir intact")
        XCTAssertEqual(brought.core.x87Tags, 0xFFFF,
                       "sans la section, la pile doit rester celle d'une machine neuve")
    }

    /// Où la marque commence, en octets — et **elle seule**.
    ///
    /// Les deux témoins coupent l'instantané à cet endroit. Une seconde
    /// occurrence, tombée par hasard dans la RAM ou dans l'image du disque,
    /// ferait couper au mauvais endroit et rendrait un rouge qui parle du
    /// format alors que le format va bien. Le dire ici, une fois, plutôt que
    /// de découvrir la coïncidence par un test qui ment.
    private static func theOnlyMark(in bytes: [UInt8]) throws -> Int {
        let needle = withUnsafeBytes(of: Snapshot.x87Section.littleEndian) { [UInt8]($0) }
        let found = bytes.count < needle.count ? [] : (0...(bytes.count - needle.count)).filter {
            Array(bytes[$0..<($0 + needle.count)]) == needle
        }
        XCTAssertEqual(found.count, 1,
                       "la marque de la pile x87 doit apparaître une fois et une seule")
        return try XCTUnwrap(found.first, "l'instantané ne porte pas la marque de la pile x87")
    }
}
