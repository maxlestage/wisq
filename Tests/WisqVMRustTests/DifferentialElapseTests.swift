import Foundation
import WisqVM
import WisqVMRust
import XCTest

/// **Un vrai invité RISC-V, repris une demi-heure plus tard**, sur les deux
/// cœurs : voir `LinuxMachine.elapse(seconds:)` et `wisq_vm_elapse`.
///
/// Le noyau de référence et son busybox. `date` avant l'instantané, puis
/// après la reprise et un rattrapage en six pas (`GuestClock.stepSeconds`),
/// doit sauter d'une demi-heure. Les deux cœurs doivent finir sur les mêmes
/// octets.
///
/// Une demi-heure et pas trois jours : ce noyau paie environ cent mille
/// instructions par seconde rattrapée, et trois jours en vaudraient
/// vingt-sept milliards — vingt minutes de ce test au lieu de quelques
/// secondes.
final class DifferentialElapseTests: XCTestCase {
    /// Le temps passé dehors.
    static let away: TimeInterval = 1800
    /// La console, depuis le fil de la machine.
    private final class Console: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ chunk: Data) { lock.lock(); bytes.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    }

    /// Ce que le test demande à l'un ou l'autre cœur.
    private struct Core {
        let load: (Data) throws -> Void
        let run: (UInt64) -> Void
        let send: (Data) -> Void
        let snapshot: () -> Data
    }

    private static func swiftCore(_ console: Console, away: TimeInterval) -> (Core, (Data) throws -> Core) {
        func wrap(_ machine: LinuxMachine) -> Core {
            Core(load: { try machine.load(kernelImage: $0, commandLine: "console=ttyS0") },
                 run: { machine.run(instructionBudget: $0) }, send: machine.send, snapshot: machine.snapshot)
        }
        return (wrap(LinuxMachine { console.append($0) }), { saved in
            let machine = LinuxMachine { console.append($0) }
            try machine.restore(saved)
            machine.elapse(seconds: away)
            return wrap(machine)
        })
    }

    private static func rustCore(_ console: Console, away: TimeInterval) -> (Core, (Data) throws -> Core) {
        func wrap(_ machine: RustLinuxMachine) -> Core {
            Core(load: { try machine.loadOnTheSameBoard(kernelImage: $0, commandLine: "console=ttyS0") },
                 run: { machine.run(instructionBudget: $0) }, send: machine.send, snapshot: machine.snapshot)
        }
        return (wrap(RustLinuxMachine { console.append($0) }), { saved in
            let machine = RustLinuxMachine { console.append($0) }
            try machine.restore(saved)
            machine.elapse(microseconds: UInt64(away) * 1_000_000)
            return wrap(machine)
        })
    }

    /// Tourne par tranches jusqu'à ce que la console vérifie `done`.
    private func run(_ core: Core, _ console: Console, budget: UInt64, until done: (String) -> Bool) {
        var spent: UInt64 = 0
        while spent < budget, !done(console.text) {
            core.run(10_000_000)
            spent += 10_000_000
        }
    }

    /// Le dernier nombre écrit seul sur sa ligne.
    private func lastNumber(in text: String) -> Int? {
        text.split(whereSeparator: \.isNewline)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.last
    }

    /// `mtime` d'un instantané, en secondes : relu par une machine Swift,
    /// qui sait lire celui des deux cœurs.
    private func mtimeSeconds(of snapshot: Data) throws -> Int {
        let reader = LinuxMachine(onOutput: { _ in })
        try reader.restore(snapshot)
        return Int((UInt64(reader.mmioLoad(0x1100_BFFC)) << 32 | UInt64(reader.mmioLoad(0x1100_BFF8))) / 1_000_000)
    }

    /// Ce qu'une reprise montre : l'écart entre les deux `date`, l'écart
    /// entre `date` et `mtime` avant et après, et l'instantané final.
    private struct Resumed {
        let gap: Int
        let offsetBefore: Int
        let offsetAfter: Int
        let end: Data
    }

    private func resumedLater(_ make: (Console) -> (Core, (Data) throws -> Core),
                              image: Data) throws -> Resumed {
        let console = Console()
        let (machine, resume) = make(console)
        try machine.load(image)
        run(machine, console, budget: 3_000_000_000) { $0.hasSuffix("login: ") }
        machine.send(Data("root\n".utf8))
        run(machine, console, budget: 1_000_000_000) { $0.hasSuffix("# ") }
        XCTAssertTrue(console.text.hasSuffix("# "), "le shell doit être là : …\(console.text.suffix(200))")
        machine.send(Data("date +%s\n".utf8))
        run(machine, console, budget: 500_000_000) { $0.hasSuffix("# ") && $0.contains("date +%s") }
        let before = try XCTUnwrap(lastNumber(in: console.text), "date avant")
        let saved = machine.snapshot()
        _ = resume

        let resumedConsole = Console()
        let resumed = try make(resumedConsole).1(saved)
        // Le temps de taper : l'invité dort, et chaque sommeil paie un pas.
        // Une commande tapée à l'instant même de la reprise lirait encore
        // l'heure d'avant.
        resumed.run(400_000_000)
        resumed.send(Data("date +%s\n".utf8))
        run(resumed, resumedConsole, budget: 2_000_000_000) { $0.hasSuffix("# ") }
        let after = try XCTUnwrap(lastNumber(in: resumedConsole.text), "date après : «\(resumedConsole.text)»")
        let end = resumed.snapshot()
        return Resumed(gap: after - before, offsetBefore: before - (try mtimeSeconds(of: saved)),
                       offsetAfter: after - (try mtimeSeconds(of: end)), end: end)
    }

    func testARealGuestResumedLaterKnowsTheTimeOnBothCores() throws {
        let path = ProcessInfo.processInfo.environment["WISQ_LINUX_IMAGE"] ?? "/tmp/wisq-test-linux-image/Image"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))
        let rust = try resumedLater({ Self.rustCore($0, away: Self.away) }, image: image)
        XCTAssertGreaterThanOrEqual(rust.gap, Int(Self.away), "le cœur du téléphone a rattrapé la demi-heure")
        // **L'invité suit `mtime` à travers les six pas** : l'écart entre son
        // heure et le compteur est le même avant et après. Une conversion de
        // travers, ou un pas qu'il n'aurait pas compté, le déplacerait.
        XCTAssertEqual(rust.offsetAfter, rust.offsetBefore, accuracy: 2)
        let swift = try resumedLater({ Self.swiftCore($0, away: Self.away) }, image: image)
        XCTAssertEqual(swift.gap, rust.gap, "les deux cœurs, au même écart")
        XCTAssertEqual(swift.end, rust.end, "et aux mêmes octets")
    }
}
