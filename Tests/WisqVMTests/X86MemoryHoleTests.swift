import XCTest

@testable import WisqVM

/// **Une machine PC de plus de trois gibioctets, et le trou sous quatre.**
///
/// La mémoire du téléphone moins deux gibioctets met le curseur à neuf ou
/// dix gibioctets. Une RAM d'un seul tenant jusque-là recouvrait le disque
/// (0xD000_0000) et l'écran (0xE000_0000), et Chimera, à six gibioctets, ne
/// trouvait plus où poser ses périphériques puis bloquait son processeur. La
/// RAM s'arrête maintenant à trois gibioctets et reprend à quatre, comme sur
/// un vrai PC.
final class X86MemoryHoleTests: XCTestCase {
    private let sixGibibytes = 6 << 30

    /// Jusqu'à trois gibioctets, rien ne change : un bloc plat, une plage.
    func testUpToThreeGibibytesTheMemoryIsOneBlock() {
        let small = X86Memory.pc(ram: 2 << 30)
        XCTAssertEqual(small.size, 2 << 30)
        XCTAssertEqual(small.ram, 2 << 30)
        XCTAssertEqual(small.ramRanges, [0..<(2 << 30)])
        let edge = X86Memory.pc(ram: Int(X86Memory.holeBase))
        XCTAssertEqual(edge.ramRanges.count, 1, "trois gibioctets tiennent sous le trou")
    }

    /// Au-delà, la RAM reprend à quatre gibioctets, et il y en a autant.
    func testAboveThreeGibibytesTheRAMResumesAtFour() {
        let memory = X86Memory.pc(ram: sixGibibytes)
        XCTAssertEqual(memory.ram, sixGibibytes, "le trou ne prend rien à l'invité")
        XCTAssertEqual(memory.ramRanges, [
            0..<X86Memory.holeBase,
            X86Memory.holeEnd..<(X86Memory.holeEnd + UInt64(sixGibibytes) - X86Memory.holeBase),
        ])
    }

    /// **Le trou n'est pas de la RAM** : ses adresses vont aux périphériques.
    /// Lire le disque ou l'écran en mémoire hôte rendrait des zéros, et
    /// écrire l'écran ne le repeindrait pas.
    func testTheHoleIsNotRAM() throws {
        let memory = X86Memory.pc(ram: sixGibibytes)
        XCTAssertNil(memory.offset(0xD000_0000, 4), "le disque")
        XCTAssertNil(memory.offset(0xE000_0000, 4), "l'écran")
        XCTAssertNil(memory.offset(X86Memory.holeBase, 1))
        XCTAssertNil(memory.offset(X86Memory.holeEnd - 1, 1))
        // Un accès à cheval sur le bord n'entre pas dans le trou non plus.
        XCTAssertNil(memory.offset(X86Memory.holeBase - 4, 8))
        XCTAssertThrowsError(try memory.read(0xE000_0000, 4))
        // Et les deux côtés restent de la RAM.
        XCTAssertNotNil(memory.offset(X86Memory.holeBase - 8, 8))
        XCTAssertNotNil(memory.offset(X86Memory.holeEnd, 8))
    }

    /// La RAM au-dessus de quatre gibioctets se lit et s'écrit, jusqu'à son
    /// dernier octet, et pas au-delà.
    func testTheRAMAboveFourIsUsableToItsLastByte() throws {
        let memory = X86Memory.pc(ram: sixGibibytes)
        let last = memory.ramRanges[1].upperBound
        try memory.write(X86Memory.holeEnd, 8, 0x0123_4567_89AB_CDEF)
        XCTAssertEqual(try memory.read(X86Memory.holeEnd, 8), 0x0123_4567_89AB_CDEF)
        try memory.write(last - 8, 8, 42)
        XCTAssertEqual(try memory.read(last - 8, 8), 42)
        XCTAssertThrowsError(try memory.read(last, 1))
    }

    /// **Le noyau l'apprend par la carte e820** : deux plages utilisables au
    /// lieu d'une, et rien dans le trou.
    func testTheMemoryMapHasTwoUsableRangesAndNothingInTheHole() throws {
        let memory = X86Memory.pc(ram: sixGibibytes)
        let placement = try X86BootLoader.load(
            kernel: X86BootLoaderTests.syntheticKernel(), into: memory)
        let usable = Self.entries(memory, placement).filter { $0.kind == X86BootLoader.e820Usable }
        XCTAssertTrue(usable.contains { $0.start == 0x10_0000 && $0.end == X86Memory.holeBase })
        XCTAssertTrue(usable.contains {
            $0.start == X86Memory.holeEnd && $0.end == memory.ramRanges[1].upperBound
        })
        for entry in usable {
            XCTAssertFalse(entry.start < X86Memory.holeEnd && entry.end > X86Memory.holeBase,
                           "une plage utilisable déborde dans le trou : \(entry)")
        }
        let total = usable.reduce(UInt64(0)) { $0 + ($1.end - $1.start) }
        XCTAssertGreaterThan(total, UInt64(sixGibibytes) - (1 << 20),
                             "toute la RAM est annoncée, au premier mébioctet près")
    }

    /// L'initramfs est posé **sous le trou** : son adresse s'écrit sur
    /// trente-deux bits, et une adresse au-dessus de quatre gibioctets y
    /// serait tronquée.
    func testTheRamdiskStaysUnderTheHole() throws {
        let memory = X86Memory.pc(ram: sixGibibytes)
        let disk = [UInt8](repeating: 0x5A, count: 1 << 20)
        let placement = try X86BootLoader.load(
            kernel: X86BootLoaderTests.syntheticKernel(), into: memory, initialRamdisk: disk)
        XCTAssertLessThanOrEqual(placement.ramdiskAddress + UInt64(disk.count), X86Memory.holeBase)
        XCTAssertEqual(try memory.read(placement.bootParametersAddress &+ 0x218, 4),
                       placement.ramdiskAddress)
        XCTAssertEqual(memory.dump(placement.ramdiskAddress, 2), [0x5A, 0x5A])
    }

    /// **Un initramfs plus grand que la mémoire est un refus de place**, et
    /// pas un accès hors mémoire à 0xffff… — ce que l'application affichait
    /// en « Démarrage impossible… erreur 2 », pour Chimera (195 Mo
    /// d'initramfs) sur une machine de 128 Mio.
    func testARamdiskLargerThanTheMemoryIsARefusalOfRoom() {
        let memory = X86Memory(size: 64 << 20)
        let disk = [UInt8](repeating: 0, count: 80 << 20)
        XCTAssertThrowsError(try X86BootLoader.load(
            kernel: X86BootLoaderTests.syntheticKernel(), into: memory, initialRamdisk: disk)) {
            guard case .notEnoughMemory = $0 as? X86BootLoader.LoadError else {
                return XCTFail("attendu un refus de place, obtenu \($0)")
            }
        }
    }

    /// La machine elle-même : sa RAM est celle qu'on lui a réglée, et son
    /// écran tombe dans le trou plutôt que d'être refusé.
    func testAMachineAboveThreeGibibytesGetsTheHoleAndItsScreen() throws {
        let machine = X86Machine(ramSize: sixGibibytes) { _ in }
        XCTAssertEqual(machine.memory.ram, sixGibibytes)
        XCTAssertEqual(machine.memory.ramRanges.count, 2)
        XCTAssertNoThrow(try machine.attachDisplay(width: 640, height: 480))
    }

    static func entries(_ memory: X86Memory, _ placement: X86BootLoader.Placement)
        -> [(start: UInt64, end: UInt64, kind: UInt32)] {
        let page = memory.dump(placement.bootParametersAddress, X86BootLoader.bootParametersSize)
        func field(_ at: Int, _ bytes: Int) -> UInt64 {
            (0..<bytes).reduce(UInt64(0)) { $0 | (UInt64(page[at + $1]) << (8 * UInt64($1))) }
        }
        return (0..<Int(page[X86BootLoader.e820CountOffset])).map { index in
            let at = X86BootLoader.e820TableOffset + index * 20
            let start = field(at, 8)
            return (start, start + field(at + 8, 8), UInt32(field(at + 16, 4)))
        }
    }
}

/// **Un refus se lit.** L'application affiche `localizedDescription` ; sans
/// description, iOS rendait « …X86Core.Fault erreur 2 ».
final class X86RefusalTextTests: XCTestCase {
    func testARamdiskThatDoesNotFitSaysBothSizesAndWhatToDo() {
        let said = X86BootLoader.LoadError.notEnoughMemory(needed: 246 << 20, available: 192 << 20)
            .localizedDescription
        XCTAssertTrue(said.contains("246 Mo"), said)
        XCTAssertTrue(said.contains("192 Mo"), said)
        XCTAssertTrue(said.contains("curseur"), said)
        XCTAssertFalse(said.contains("erreur 0"), said)
    }

    func testAFaultNamesWhatHappened() {
        XCTAssertTrue(X86Core.Fault.outsideMemory(0xFFFF_FFFF_FC56_0000).localizedDescription
            .contains("hors de la mémoire"))
        XCTAssertTrue(X86Core.Fault.unsupported("vblendps").localizedDescription.contains("vblendps"))
        XCTAssertFalse(X86Core.Fault.divideError.localizedDescription.contains("erreur 1"))
    }
}
