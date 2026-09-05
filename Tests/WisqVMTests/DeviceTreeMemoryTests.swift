import XCTest

@testable import WisqVM

/// Ce que l'arbre annonce au noyau, et pourquoi ce n'est pas ce que la machine
/// alloue.
///
/// Le blob venait verbatim de mini-rv32ima : il décrivait 64 Mo, et une machine
/// dotée de plus de mémoire aurait fait tourner un noyau qui n'en sait rien —
/// la mémoire existe, personne ne la lui annonce, elle ne sert à rien.
///
/// **Ces tests interrogeaient un mécanisme qui n'existe plus.** La taille
/// s'écrivait à l'octet 316 d'un blob recopié, et ils tenaient donc des
/// décalages : « la cellule mémoire et la ligne de commande ne se recouvrent
/// pas », « le patch ne change rien d'autre ». L'arbre est construit depuis, il
/// n'y a plus ni décalage ni patch, et la propriété qui reste — **l'invité lit
/// la taille de sa machine** — se mesure là où le noyau la lit.
final class DeviceTreeMemoryTests: XCTestCase {
    /// Les nombres de la référence, relus plutôt que réaffirmés.
    func testTheReferenceTreeDeclaresTheReferenceSize() throws {
        let reference = try DeviceTree.read(DefaultDTB.bytes)
        XCTAssertEqual(
            reference.root.child("memory@80000000")?.property("reg"),
            .cells([0, 0x8000_0000, 0x0, 0x03ff_c000]))
        XCTAssertEqual(
            0x03ff_c000,
            Int(LinuxMachine.defaultRAMSize) - RV32DeviceTree.memoryTopReserve,
            "l'écart entre ce qui est alloué et ce qui est annoncé est la réserve du haut")
    }

    /// Et les deux cœurs doivent garder la même réserve du haut, sinon le
    /// réglage marcherait sur l'un et pas sur l'autre.
    ///
    /// **Ce test a changé d'objet.** Il liait un décalage d'octet dans les deux
    /// codes ; ce décalage n'existe plus d'un côté. Ce qui reste partagé est le
    /// nombre : la caisse Rust garde son blob pour qui l'emploie sans Swift, et
    /// elle doit réserver le même haut de mémoire.
    func testBothCoresKeepTheSameTopReserve() throws {
        let rust = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("crates/wisq-vm/src/dtb.rs"),
            encoding: .utf8)
        XCTAssertTrue(
            rust.contains("MEMORY_TOP_RESERVE: usize = 16 * 1024"),
            "la réserve du haut doit être la même dans les deux cœurs")
        XCTAssertEqual(RV32DeviceTree.memoryTopReserve, 16 * 1024)
    }
}

/// Une machine qui n'a pas la taille de la référence.
///
/// C'est le point de tout ce qui précède : la mémoire ne sert à rien si le
/// noyau n'en est pas informé, et le seul endroit qui l'informe est l'arbre.
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

    /// **La question posée là où le noyau la lit** : dans la RAM de l'invité, à
    /// l'adresse que `load` a mise dans a1.
    ///
    /// Les tests d'avant interrogeaient tous la fonction qui fabrique l'arbre.
    /// Un sabotage a remis le blob verbatim dans `load` — le redimensionnement
    /// entièrement défait — et seul le test qui démarre un vrai noyau est
    /// tombé. Ce dernier saute quand l'image n'est pas là, donc la garde ne
    /// tenait rien sans elle. Celle-ci tient sans noyau.
    func testTheTreeInGuestMemoryIsTheResizedOne() throws {
        let image = Data([0x13, 0x00, 0x00, 0x00])   // un NOP

        for megabytes in [16, 64, 128, 256] {
            let machine = LinuxMachine(ramSize: UInt32(megabytes) << 20) { _ in }
            try machine.load(kernelImage: image)
            let tree = try DeviceTree.read(machine.deviceTreeHandedToTheGuest)
            XCTAssertEqual(
                tree.root.child("memory@80000000")?.property("reg"),
                .cells([0, 0x8000_0000, 0,
                        UInt32((megabytes << 20) - RV32DeviceTree.memoryTopReserve)]),
                "\(megabytes) Mo : l'invité doit lire la taille de sa machine")
        }
    }

    /// Une ligne de commande et un redimensionnement sont dans le même arbre et
    /// ne s'effacent pas l'un l'autre : le noyau a besoin des deux.
    func testACommandLineAndAResizeSurviveEachOther() throws {
        let machine = LinuxMachine(ramSize: 128 << 20) { _ in }
        try machine.load(
            kernelImage: Data([0x13, 0x00, 0x00, 0x00]), commandLine: "console=ttyS0 quiet")
        let tree = try DeviceTree.read(machine.deviceTreeHandedToTheGuest)
        XCTAssertEqual(
            tree.root.child("memory@80000000")?.property("reg"),
            .cells([0, 0x8000_0000, 0, UInt32((128 << 20) - RV32DeviceTree.memoryTopReserve)]))
        XCTAssertEqual(tree.root.child("chosen")?.property("bootargs"),
                       .string("console=ttyS0 quiet"))
    }
}
