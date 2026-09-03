import XCTest

@testable import WisqVM

/// Ce que le DTB annonce au noyau, et pourquoi ce n'est pas ce que la machine
/// alloue.
///
/// Le blob vient verbatim de mini-rv32ima : il décrivait 64 Mo et rien ne le
/// touchait sauf la ligne de commande. Une machine dotée de plus de mémoire
/// aurait donc fait tourner un noyau qui n'en sait rien — la mémoire existe,
/// personne ne la lui annonce, elle ne sert à rien.
final class DeviceTreeMemoryTests: XCTestCase {
    /// Les nombres du blob, relus plutôt que réaffirmés.
    func testTheUntouchedTreeDeclaresTheReferenceSize() {
        XCTAssertEqual(DefaultDTB.declaredMemory(in: DefaultDTB.bytes), 0x03ff_c000)
        XCTAssertEqual(
            Int(DefaultDTB.declaredMemory(in: DefaultDTB.bytes)),
            Int(LinuxMachine.defaultRAMSize) - DefaultDTB.memoryTopReserve,
            "l'écart entre ce qui est alloué et ce qui est annoncé est la réserve du haut")
    }

    /// Le patch annonce la nouvelle taille et ne touche rien d'autre. La
    /// seconde moitié est celle qui compte : un octet écrit au mauvais offset
    /// tomberait dans une autre propriété et le noyau refuserait l'arbre.
    func testPatchingStatesTheNewSizeAndChangesNothingElse() {
        for ram in [16 << 20, 64 << 20, 256 << 20, 512 << 20] {
            let tree = DefaultDTB.bytes(forRAMSize: ram)
            XCTAssertEqual(
                Int(DefaultDTB.declaredMemory(in: tree)), ram - DefaultDTB.memoryTopReserve,
                "\(ram >> 20) Mo")
            XCTAssertEqual(tree.count, DefaultDTB.bytes.count)
            for index in tree.indices
            where !(DefaultDTB.memorySizeOffset..<(DefaultDTB.memorySizeOffset + 4))
                .contains(index) {
                XCTAssertEqual(
                    tree[index], DefaultDTB.bytes[index],
                    "octet \(index) modifié hors de la cellule mémoire")
            }
        }
    }

    /// La ligne de commande et la cellule mémoire vivent dans le même tampon :
    /// une erreur d'offset dans l'une écraserait l'autre.
    func testTheCommandLineAndTheMemoryCellDoNotOverlap() {
        XCTAssertLessThan(
            DefaultDTB.commandLineOffset + DefaultDTB.commandLineCapacity,
            DefaultDTB.memorySizeOffset)
    }

    /// Et les deux cœurs doivent dire le même nombre au même endroit, sinon le
    /// réglage marcherait sur l'un et pas sur l'autre — le cœur Rust est celui
    /// qui tourne sur le téléphone.
    func testBothCoresAgreeOnWhereTheMemoryCellIs() throws {
        let rust = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("crates/wisq-vm/src/dtb.rs"),
            encoding: .utf8)
        XCTAssertTrue(
            rust.contains("MEMORY_SIZE_OFFSET: usize = \(DefaultDTB.memorySizeOffset)"),
            "l'offset de la cellule mémoire doit être le même dans les deux cœurs")
        XCTAssertTrue(
            rust.contains("MEMORY_TOP_RESERVE: usize = 16 * 1024"),
            "et la réserve du haut aussi")
    }
}

/// Une machine qui n'a pas la taille de la référence.
///
/// C'est le point de tout ce qui précède : la mémoire ne sert à rien si le
/// noyau n'en est pas informé, et le seul endroit qui l'informe est le DTB.
final class ResizedMachineTests: XCTestCase {
    /// La machine annonce ce qu'elle a, à chaque taille, et son plafond de
    /// noyau suit. Une machine plus grande accepte une image plus grande —
    /// ce que la version précédente ne pouvait pas faire, puisque le plafond
    /// était une constante de type.
    func testAMachineStatesItsOwnMemoryAndItsOwnKernelBudget() throws {
        for megabytes in [16, 32, 64, 128, 256] {
            let ram = UInt32(megabytes) << 20
            let machine = LinuxMachine(ramSize: ram) { _ in }
            XCTAssertEqual(machine.ramSize, ram, "\(megabytes) Mo")
            XCTAssertEqual(
                machine.maximumKernelImageBytes,
                LinuxMachine.maximumKernelImageBytes(forRAMSize: ram))
            // Le plafond grandit avec la machine, strictement.
            XCTAssertGreaterThan(
                machine.maximumKernelImageBytes,
                LinuxMachine.maximumKernelImageBytes(forRAMSize: ram / 2))
        }
    }

    /// Et une image qui tient dans la grande machine sans tenir dans la petite
    /// est acceptée par l'une et refusée par l'autre. Le bord qui prouve que
    /// le réglage change quelque chose, plutôt qu'un nombre rangé quelque part.
    func testAnImageTooBigForTheDefaultMachineFitsInALargerOne() throws {
        let small = LinuxMachine(ramSize: LinuxMachine.defaultRAMSize) { _ in }
        let large = LinuxMachine(ramSize: 128 << 20) { _ in }
        let image = Data(repeating: 0x13, count: small.maximumKernelImageBytes + 1)

        XCTAssertThrowsError(try small.load(kernelImage: image)) { error in
            XCTAssertEqual(error as? LinuxMachineError, .imageTooLarge)
        }
        XCTAssertNoThrow(try large.load(kernelImage: image))
    }

    /// Le noyau de la grande machine lit bien la grande taille : la garde de
    /// tout l'exercice. Sans le patch du DTB, les deux machines annonceraient
    /// 63,98 Mo et la mémoire ajoutée resterait invisible.
    func testTheGuestIsToldTheLargerSize() {
        let tree = DefaultDTB.bytes(forRAMSize: 256 << 20)
        XCTAssertEqual(
            Int(DefaultDTB.declaredMemory(in: tree)),
            (256 << 20) - DefaultDTB.memoryTopReserve)
        XCTAssertNotEqual(
            DefaultDTB.declaredMemory(in: tree),
            DefaultDTB.declaredMemory(in: DefaultDTB.bytes),
            "sinon rien n'a changé pour l'invité")
    }

    /// La même question posée là où le noyau la lit : dans la RAM de l'invité,
    /// à l'adresse que `load` a mise dans a1.
    ///
    /// Les tests au-dessus interrogeaient tous `bytes(forRAMSize:)`. Un
    /// sabotage a remis `DefaultDTB.bytes` verbatim dans `load` — le
    /// redimensionnement entièrement défait — et seul le test qui démarre un
    /// vrai noyau est tombé. Ce dernier saute quand l'image n'est pas là,
    /// donc la garde ne tenait rien sans elle. Celle-ci tient sans noyau.
    func testTheTreeInGuestMemoryIsTheResizedOne() throws {
        let image = Data([0x13, 0x00, 0x00, 0x00])   // un NOP

        for megabytes in [16, 64, 128, 256] {
            let machine = LinuxMachine(ramSize: UInt32(megabytes) << 20) { _ in }
            try machine.load(kernelImage: image)
            XCTAssertEqual(
                Int(DefaultDTB.declaredMemory(in: machine.deviceTreeHandedToTheGuest)),
                (megabytes << 20) - DefaultDTB.memoryTopReserve,
                "\(megabytes) Mo : l'invité doit lire la taille de sa machine")
        }
    }

    /// Une ligne de commande et un redimensionnement sont écrits dans le même
    /// blob et ne s'effacent pas l'un l'autre : le noyau a besoin des deux.
    func testACommandLineAndAResizeSurviveEachOther() throws {
        let machine = LinuxMachine(ramSize: 128 << 20) { _ in }
        try machine.load(
            kernelImage: Data([0x13, 0x00, 0x00, 0x00]), commandLine: "console=ttyS0 quiet")
        let tree = machine.deviceTreeHandedToTheGuest
        XCTAssertEqual(
            Int(DefaultDTB.declaredMemory(in: tree)),
            (128 << 20) - DefaultDTB.memoryTopReserve)
        let line = tree[
            DefaultDTB.commandLineOffset..<(DefaultDTB.commandLineOffset + 19)]
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "console=ttyS0 quiet")
    }
}
