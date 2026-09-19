import Foundation
import XCTest

@testable import WisqVM

/// Chaque champ que l'instantané x86 porte, mis dedans puis ressorti.
///
/// `SnapshotFieldWitnessTests` pose cette question depuis #96 — mais pour la
/// machine rv32, et pour elle seule : il n'y nomme pas l'x86 une seule fois.
/// L'instantané x86 a grandi depuis (le registre de tâche, les seize XMM, le
/// port série, le disque) sans jamais subir la même mesure, et c'est par là
/// qu'un champ a manqué.
///
/// **Ce que ce fichier mesure, et ce qu'il ne mesure pas.** Il met dans chaque
/// champ sauvé une valeur **distincte et non nulle**, prend l'instantané, le
/// rend à une machine neuve, et exige chaque valeur. Un champ qu'on oublie
/// d'écrire ou de relire revient à sa valeur de départ, et l'assertion qui le
/// nomme tombe. Ce qu'il ne prétend pas : recompter, comme #96 l'avait fait
/// pour la rv32, combien de champs les tests d'avant laissaient passer. Cette
/// mesure-là n'a pas été refaite ici, et ce fichier ne l'annonce pas.
///
/// **Hors champ, exprès** : `X86LegacyDevices`, que `X86LegacyDevicesTests`
/// juge déjà pièce par pièce, et la RAM, que `X86DiskSnapshotTests` et
/// `SuspendedMachineTests` portent. Ce fichier tient le cœur.
final class X86SnapshotFieldWitnessTests: XCTestCase {
    /// Une machine dont tous les champs sauvés sont distincts et non nuls.
    ///
    /// Les valeurs n'ont pas de sens architectural — ce n'est pas une machine
    /// qui pourrait tourner, c'est une machine qui peut se **distinguer**.
    /// Deux champs de même valeur laisseraient passer une restauration qui les
    /// échange, et c'est un vrai défaut d'instantané.
    private func machineWithEveryFieldDistinct(withDisk: Bool = false) -> X86Machine {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        if withDisk { machine.attach(disk: X86DiskSnapshotTests.image()) }
        for index in 0..<16 { machine.core.registers[index] = 0x1000_0000_0000_0001 + UInt64(index) }
        machine.core.flags = 0x2000_0000_0000_0002
        machine.core.rip = 0x3000_0000_0000_0003
        machine.core.retired = 0x4000_0000_0000_0004
        machine.core.idled = 0x5000_0000_0000_0005
        machine.core.halted = true
        machine.core.pagingActive = true
        for index in 0..<16 { machine.core.system.control[index] = 0x6000_0000_0000_0001 + UInt64(index) }
        for index in 0..<8 { machine.core.system.debug[index] = 0x7000_0000_0000_0001 + UInt64(index) }
        machine.core.system.modelSpecific[0xC000_0100] = 0x8000_0000_0000_0008
        machine.core.system.modelSpecific[0xC000_0101] = 0x9000_0000_0000_0009
        for index in 0..<6 { machine.core.segments[index] = UInt16(0x0110 + index) }
        for index in 0..<2 {
            machine.core.descriptorBases[index] = 0xA000_0000_0000_0001 + UInt64(index)
            machine.core.descriptorLimits[index] = 0xB000_0000_0000_0001 + UInt64(index)
        }
        machine.core.taskSelector = 0x0128
        machine.core.taskBase = 0xC000_0000_0000_000C
        machine.core.taskLimit = 0xD000_0000_0000_000D
        machine.core.x87Control = 0x0E7F
        machine.core.x87Status = 0x3800
        machine.core.mxcsr = 0x0000_9F80
        // La pile x87 : huit registres de quatre-vingts bits, chacun distinct.
        for index in 0..<8 {
            machine.core.x87[index] = X86Extended(significand: 0xF000_0000_0000_0001 + UInt64(index),
                                                  signExponent: UInt16(0x4000 + index))
        }
        // Et le mot d'étiquettes, qui dit lesquels de ces huit sont vivants.
        // 0xFFFF est « tous vides », c'est-à-dire la valeur de départ : une
        // autre valeur est ce qui distingue « restauré » de « jamais écrit ».
        machine.core.x87Tags = 0x1B4E
        for index in 0..<32 { machine.core.vectors[index] = 0xE000_0000_0000_0001 + UInt64(index) }
        machine.core.serialInput = [0x71, 0x72, 0x73]
        return machine
    }

    /// Le témoin. Chaque assertion nomme son champ, parce qu'un rouge qui dit
    /// « l'instantané a changé » n'apprend rien à qui le lit six mois plus
    /// tard.
    func testEverySavedCoreFieldSurvivesTheRoundTrip() throws {
        let saved = machineWithEveryFieldDistinct().snapshot()
        let brought = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try brought.restore(saved)
        let core = brought.core

        for index in 0..<16 {
            XCTAssertEqual(core.registers[index], 0x1000_0000_0000_0001 + UInt64(index),
                           "le registre \(index) n'est pas revenu")
        }
        XCTAssertEqual(core.flags, 0x2000_0000_0000_0002, "les drapeaux ne sont pas revenus")
        XCTAssertEqual(core.rip, 0x3000_0000_0000_0003, "RIP n'est pas revenu")
        XCTAssertEqual(core.retired, 0x4000_0000_0000_0004, "le compte d'instructions n'est pas revenu")
        XCTAssertEqual(core.idled, 0x5000_0000_0000_0005, "le compte d'attente n'est pas revenu")
        XCTAssertTrue(core.halted, "l'arrêt sur hlt n'est pas revenu")
        XCTAssertTrue(core.pagingActive, "la pagination active n'est pas revenue")
        for index in 0..<16 {
            XCTAssertEqual(core.system.control[index], 0x6000_0000_0000_0001 + UInt64(index),
                           "le registre de contrôle \(index) n'est pas revenu")
        }
        for index in 0..<8 {
            XCTAssertEqual(core.system.debug[index], 0x7000_0000_0000_0001 + UInt64(index),
                           "le registre de débogage \(index) n'est pas revenu")
        }
        XCTAssertEqual(core.system.modelSpecific[0xC000_0100], 0x8000_0000_0000_0008,
                       "FS_BASE n'est pas revenu")
        XCTAssertEqual(core.system.modelSpecific[0xC000_0101], 0x9000_0000_0000_0009,
                       "GS_BASE n'est pas revenu")
        for index in 0..<6 {
            XCTAssertEqual(core.segments[index], UInt16(0x0110 + index),
                           "le sélecteur de segment \(index) n'est pas revenu")
        }
        for index in 0..<2 {
            XCTAssertEqual(core.descriptorBases[index], 0xA000_0000_0000_0001 + UInt64(index),
                           "la base de table \(index) n'est pas revenue")
            XCTAssertEqual(core.descriptorLimits[index], 0xB000_0000_0000_0001 + UInt64(index),
                           "la limite de table \(index) n'est pas revenue")
        }
        XCTAssertEqual(core.taskSelector, 0x0128, "le sélecteur de tâche n'est pas revenu")
        XCTAssertEqual(core.taskBase, 0xC000_0000_0000_000C, "la base du TSS n'est pas revenue")
        XCTAssertEqual(core.taskLimit, 0xD000_0000_0000_000D, "la limite du TSS n'est pas revenue")
        XCTAssertEqual(core.x87Control, 0x0E7F, "le mot de contrôle x87 n'est pas revenu")
        XCTAssertEqual(core.x87Status, 0x3800, "le mot d'état x87 n'est pas revenu")
        XCTAssertEqual(core.mxcsr, 0x0000_9F80, "MXCSR n'est pas revenu")
        for index in 0..<8 {
            XCTAssertEqual(core.x87[index].significand, 0xF000_0000_0000_0001 + UInt64(index),
                           "la mantisse du registre x87 \(index) n'est pas revenue")
            XCTAssertEqual(core.x87[index].signExponent, UInt16(0x4000 + index),
                           "le signe et l'exposant du registre x87 \(index) ne sont pas revenus")
        }
        XCTAssertEqual(core.x87Tags, 0x1B4E, "le mot d'étiquettes x87 n'est pas revenu")
        for index in 0..<32 {
            XCTAssertEqual(core.vectors[index], 0xE000_0000_0000_0001 + UInt64(index),
                           "le mot \(index) des registres XMM n'est pas revenu")
        }
        XCTAssertEqual(core.serialInput, [0x71, 0x72, 0x73], "la file d'entrée n'est pas revenue")
    }

    /// **Le mot d'état x87 décrit une pile ; la pile doit venir avec.**
    ///
    /// C'est le défaut qui a fait écrire ce fichier, et il se dit mieux seul :
    /// l'instantané portait le mot de contrôle, le mot d'état — qui contient
    /// TOP — et MXCSR, sans les huit registres ni les étiquettes. Une machine
    /// reprise au milieu d'un calcul flottant revenait avec un état qui
    /// annonce une pile pleine, des étiquettes qui la disent vide, et des
    /// registres à zéro : trois descriptions de la même pile, toutes les trois
    /// en désaccord.
    func testTheX87StackComesBackWithTheWordsThatDescribeIt() throws {
        let saved = machineWithEveryFieldDistinct().snapshot()
        let brought = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try brought.restore(saved)
        XCTAssertNotEqual(brought.core.x87Tags, 0xFFFF,
                          "les étiquettes sont revenues à « pile vide » : elles n'ont pas été relues")
        XCTAssertNotEqual(brought.core.x87[0], X86Extended.zero,
                          "le sommet de la pile x87 est revenu à zéro")
    }

    /// **Un instantané écrit avant cette tranche doit encore se reprendre.**
    ///
    /// Des machines sont déjà sauvées sur des téléphones. La pile x87 s'ajoute
    /// donc en queue, derrière une marque, et son absence se lit comme « un
    /// instantané d'avant » plutôt que comme un dégât — exactement ce que le
    /// disque fait depuis #144. Le témoin est construit en coupant la marque
    /// et tout ce qui la suit.
    func testASnapshotWrittenBeforeTheX87StackStillRestores() throws {
        let complete = [UInt8](machineWithEveryFieldDistinct().snapshot())
        guard let mark = Self.firstIndex(of: Snapshot.x87Section, in: complete) else {
            return XCTFail("l'instantané ne porte pas la marque de la pile x87")
        }
        let older = Data(complete[0..<mark])
        let brought = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try brought.restore(older)
        XCTAssertEqual(brought.core.rip, 0x3000_0000_0000_0003,
                       "un instantané d'avant la pile x87 doit encore rendre le reste")
        XCTAssertEqual(brought.core.x87Tags, 0xFFFF,
                       "sans la section, la pile doit rester celle d'une machine neuve")
    }

    /// **Le cas où la marque gagne son pain, et qu'un sabotage a révélé.**
    ///
    /// Le premier jet vérifiait la marque avant de lire la pile. Remplacer
    /// cette vérification par « il reste des octets » — ce que faisait le
    /// disque avant — laissait les trois tests d'au-dessus **verts** : la
    /// machine témoin n'a pas de disque, donc « il reste des octets » et « la
    /// marque est là » disent la même chose. Une garde qu'un sabotage
    /// traverse n'en est pas une.
    ///
    /// La marque ne sert que dans le seul cas où les deux divergent : un
    /// instantané **d'avant**, **avec un disque**. Là, il reste des octets et
    /// ce ne sont pas ceux de la pile x87 — les lire comme tels décalerait la
    /// section disque de cent huit octets et rendrait un disque faux, ou un
    /// refus, très loin de la cause.
    func testAnOlderSnapshotWithADiskIsNotReadAsAnX87Stack() throws {
        let complete = [UInt8](machineWithEveryFieldDistinct(withDisk: true).snapshot())
        guard let mark = Self.firstIndex(of: Snapshot.x87Section, in: complete) else {
            return XCTFail("l'instantané ne porte pas la marque de la pile x87")
        }
        // La marque, huit registres de quatre-vingts bits écrits en douze
        // octets chacun, et le mot d'étiquettes.
        let sectionLength = 8 + 8 * (8 + 4) + 4
        XCTAssertLessThanOrEqual(mark + sectionLength, complete.count,
                                 "la section x87 déborde de l'instantané")
        var older = Array(complete[0..<mark])
        older += complete[(mark + sectionLength)...]
        XCTAssertTrue(older.count < complete.count, "le témoin n'a rien retiré")

        let brought = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        do {
            try brought.restore(Data(older))
        } catch {
            return XCTFail("un instantané d'avant, avec un disque, a été refusé : \(error)")
        }
        XCTAssertNotNil(brought.disk,
                        "le disque d'un instantané d'avant a été lu comme une pile x87")
        XCTAssertEqual(brought.core.rip, 0x3000_0000_0000_0003,
                       "le reste de la machine doit revenir intact")
        XCTAssertEqual(brought.core.x87Tags, 0xFFFF,
                       "sans la section, la pile doit rester celle d'une machine neuve")
    }

    /// Où la marque commence, en octets, dans un instantané.
    private static func firstIndex(of mark: UInt64, in bytes: [UInt8]) -> Int? {
        let needle = withUnsafeBytes(of: mark.littleEndian) { [UInt8]($0) }
        guard bytes.count >= needle.count else { return nil }
        for start in 0...(bytes.count - needle.count)
        where Array(bytes[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }
}
