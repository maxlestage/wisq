import Foundation
import XCTest

@testable import WisqVM

/// **Une longueur énorme dans un instantané est un refus, pas un plantage.**
///
/// Un instantané arrive aussi d'ailleurs : `MachineArchive.import`, ou un
/// fichier abîmé sur le téléphone — `SnapshotFile` n'a pas de somme. Une
/// longueur proche de `Int.max` faisait déborder `at + length` : l'application
/// tombait à chaque ouverture de la machine, et le `try?` qui devait rattraper
/// un instantané illisible ne voit pas un piège.
final class SnapshotHostileLengthTests: XCTestCase {
    func testAHugeBlobLengthIsRefused() throws {
        var writer = Snapshot.Writer()
        writer.u64(UInt64(Int.max))
        var reader = try Snapshot.Reader(writer.bytes)
        XCTAssertThrowsError(try reader.blob())
    }

    /// La mémoire : une suite de zéros, puis un morceau littéral, chacun
    /// d'une longueur qui déborderait.
    func testHugeRunsInTheMemoryAreRefused() throws {
        for (zeros, literal) in [(UInt64(Int.max), UInt64(0)), (UInt64(16), UInt64(Int.max))] {
            var writer = Snapshot.Writer()
            writer.u64(64)  // la taille de la mémoire
            writer.u64(1)   // une paire
            writer.u64(zeros)
            writer.u64(literal)
            var reader = try Snapshot.Reader(writer.bytes)
            let ram = UnsafeMutableRawBufferPointer.allocate(byteCount: 64, alignment: 8)
            defer { ram.deallocate() }
            XCTAssertThrowsError(try reader.ram(ram), "zéros \(zeros), littéral \(literal)")
        }
    }
}
