import Foundation
import XCTest
@testable import WisqVM

/// **Ce qu'une reprise coûte à l'hôte** : l'instantané une fois, la mémoire
/// de l'invité une fois, et rien de plus — ni pendant la reprise, ni après.
///
/// Pour le bureau Xfce (842 Mio d'instantané, 936 Mio résidents dans
/// l'invité), la reprise en tenait le double : `restore` recopiait
/// l'instantané en `[UInt8]` avant d'en lire un mot, `savedRAMSize` aussi
/// pour n'en lire que huit octets, et l'application gardait l'instantané
/// toute la session dans la fermeture du fil d'émulation.
///
/// Mesuré par le noyau : `/proc/self/statm` pour ce qui est résident, et le
/// pic (`VmHWM` de `/proc/self/status`), remis au niveau du moment en
/// écrivant `5` dans `/proc/self/clear_refs`.
final class X86ResumeMemoryTests: XCTestCase {
    /// La mémoire écrite de la machine sauvée : assez pour qu'une copie se
    /// voie au-dessus du bruit d'un processus de test.
    private static let written = 96 << 20
    private static let ramSize = 256 << 20

    /// Une machine dont `written` octets de mémoire ne sont pas nuls — et
    /// sans suites de zéros, pour que l'instantané en porte autant.
    private static func sourceMachine() -> X86Machine {
        let machine = X86Machine(ramSize: ramSize, onOutput: { _ in })
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        let words = UnsafeMutableRawPointer(machine.memory.bytes)
            .bindMemory(to: UInt64.self, capacity: written / 8)
        for index in 0..<(written / 8) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            words[index] = state | 0x0101_0101_0101_0101
        }
        return machine
    }

    /// **La reprise ne recopie pas l'instantané.** Le pic pendant
    /// `savedRAMSize`, `savedLevel` et `restore` ne monte que de la mémoire
    /// que l'invité retrouve ; une copie de l'instantané y ajoutait 96 Mio
    /// de plus — par appel.
    func testAResumeDoesNotCopyTheSnapshot() throws {
        #if os(Linux)
        let saved = Self.sourceMachine().snapshot()
        XCTAssertGreaterThan(saved.count, Self.written)
        let target = X86Machine(ramSize: Self.ramSize, onOutput: { _ in })

        try Self.resetPeak()
        let before = try Self.residentBytes()
        XCTAssertEqual(X86Machine.savedRAMSize(in: saved), Self.ramSize)
        XCTAssertEqual(X86Machine.savedLevel(in: saved), X86Machine.snapshotLevel)
        try target.restore(saved)
        let peak = try Self.peakBytes() - before

        XCTAssertEqual(target.memory.bytes[Self.written - 1] & 1, 1, "le dernier octet écrit est revenu")
        XCTAssertLessThan(peak, Self.written + (40 << 20),
                          "\(peak >> 20) Mio de pic pour reprendre \(Self.written >> 20) Mio")
        XCTAssertGreaterThan(peak, Self.written - (8 << 20), "la mémoire de l'invité, elle, est là")
        #else
        throw XCTSkip("la mémoire résidente se lit dans /proc")
        #endif
    }

    /// **Une session reprise lâche ses octets** : passée par `PendingSession`,
    /// la reprise laisse l'hôte avec la mémoire de l'invité, et plus
    /// l'instantané à côté.
    func testAResumedSessionLetsItsBytesGo() throws {
        #if os(Linux)
        let source = Self.sourceMachine()
        let pending = PendingSession(source.snapshot())
        let target = X86Machine(ramSize: Self.ramSize, onOutput: { _ in })

        let before = try Self.residentBytes()
        XCTAssertTrue(try pending.resume(into: target))
        let grown = try Self.residentBytes() - before

        // La mémoire de l'invité est arrivée (+96 Mio), l'instantané est
        // parti (−96 Mio) : le compte revient près de zéro. Gardé, il
        // laissait les 96 Mio de la mémoire en plus.
        XCTAssertLessThan(grown, 40 << 20, "\(grown >> 20) Mio de plus après la reprise")
        XCTAssertEqual(target.memory.bytes[0], source.memory.bytes[0])
        #else
        throw XCTSkip("la mémoire résidente se lit dans /proc")
        #endif
    }

    #if os(Linux)
    /// Ce que le processus occupe en mémoire physique, d'après le noyau.
    private static func residentBytes() throws -> Int {
        let statm = try String(contentsOfFile: "/proc/self/statm", encoding: .utf8)
        let fields = statm.split(separator: " ")
        let pages = try XCTUnwrap(Int(fields[1]))
        return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
    }

    /// Le plus haut que la mémoire résidente a atteint depuis `resetPeak`.
    private static func peakBytes() throws -> Int {
        let status = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
        let line = try XCTUnwrap(status.split(separator: "\n").first { $0.hasPrefix("VmHWM:") })
        let kibibytes = try XCTUnwrap(Int(line.split(separator: " ").dropFirst().first ?? ""))
        return kibibytes << 10
    }

    /// Ramène le pic à la mémoire résidente du moment (Linux 4.0 et après).
    private static func resetPeak() throws {
        let file = try XCTUnwrap(FileHandle(forWritingAtPath: "/proc/self/clear_refs"),
                                 "/proc/self/clear_refs ne s'ouvre pas")
        defer { try? file.close() }
        try file.write(contentsOf: Data("5".utf8))
    }
    #endif
}
