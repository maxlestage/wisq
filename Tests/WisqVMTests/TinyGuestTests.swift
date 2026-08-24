import XCTest
@testable import WisqVM

/// Six instructions that write one line to the UART and then spin.
///
/// The app-layer tests need a guest that is *not* Linux: booting a real kernel
/// there would test the kernel, take seconds, and depend on a downloaded image.
/// But a guest that only executes `nop` produces no console, which turns "the
/// console survives a suspension" into a comparison of two empty strings — a
/// test that passes on any implementation, including a broken one.
///
/// So the app tests use this program instead, and this file is what says it
/// works: hand-assembled machine code is exactly the kind of thing that is
/// silently wrong, and a fixture nothing checks is a fixture that rots.
enum TinyGuest {
    /// ```
    /// lui  x1, 0x10000   # x1 = 0x1000_0000, the UART
    /// addi x2, x0, 65    # 'A'
    /// sb   x2, 0(x1)     # write it
    /// addi x2, x0, 10    # newline, which is what makes the console flush
    /// sb   x2, 0(x1)
    /// beq  x0, x0, 0     # and spin here, quietly, forever
    /// ```
    ///
    /// The spin is the point of the last instruction. A first version branched
    /// back to the store and printed for as long as it ran — half of every
    /// retired instruction was a console byte, which at interpreter speed is
    /// tens of millions of characters through the terminal grid in a fraction
    /// of a second. The guest has to keep running without keeping talking.
    static let printsOnceThenSpins: [UInt32] = [
        0x1000_00B7, 0x0410_0113, 0x0020_8023, 0x00A0_0113, 0x0020_8023, 0x0000_0063,
    ]

    static var image: Data {
        var data = Data()
        for word in printsOnceThenSpins {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

final class TinyGuestTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ chunk: Data) { lock.lock(); bytes.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    }

    func testTheTinyGuestReallyReachesTheConsole() throws {
        let sink = Sink()
        let machine = LinuxMachine { sink.append($0) }
        try machine.load(kernelImage: TinyGuest.image)
        machine.run(instructionBudget: 200_000)

        let text = sink.text
        XCTAssertEqual(text, "A\n", "le programme doit écrire une ligne, et une seule")
        XCTAssertGreaterThan(
            machine.retiredInstructions, 1000,
            "il doit continuer à tourner après avoir écrit"
        )
    }

    /// And it must still be running when the budget runs out — the app tests
    /// rely on a guest the model has to stop, the way a real one behaves.
    func testTheTinyGuestNeverStopsOnItsOwn() throws {
        let machine = LinuxMachine { _ in }
        try machine.load(kernelImage: TinyGuest.image)
        XCTAssertEqual(machine.run(instructionBudget: 50_000), .stopped)
        XCTAssertEqual(machine.run(instructionBudget: 50_000), .stopped)
    }
}
