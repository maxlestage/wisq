import Foundation
import XCTest
@testable import WisqVM

/// **Un bureau qui revient après une sauvegarde.** L'application sauve la
/// machine quand on quitte l'écran et la reprend au retour ; pour un bureau
/// graphique, revenir veut dire retrouver l'écran tel qu'il était, puis un
/// clavier, une tablette et une console qui répondent encore.
///
/// En deux temps, chacun relançable seul (une course entière dure plus
/// longtemps que certains conteneurs) :
///
/// 1. `WISQ_PC_DESKTOP_SAVE` : démarrer l'ISO jusqu'au bureau Xfce, puis
///    écrire l'instantané à ce nom et la couche d'écriture du disque à côté.
/// 2. `WISQ_PC_DESKTOP_RESUME` : reprendre cet instantané dans une machine
///    **neuve**, et demander à l'invité de prouver qu'il est encore là.
///
/// La machine se décrit comme dans `X86CloudResumeTests.profiledMachine` :
/// `WISQ_PC_KERNEL`, `WISQ_PC_INITRD`, `WISQ_PC_DISK_FILE`,
/// `WISQ_PC_RAM_MIB`, `WISQ_PC_CMDLINE`, et l'écran toujours branché.
final class X86DesktopResumeTests: XCTestCase {
    /// Ce que la console série a écrit, lu depuis le fil de la machine.
    final class Console: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) { lock.lock(); bytes += data; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    }

    static func machine(_ environment: [String: String], writes: URL, console: Console) throws -> (X86Machine, () throws -> Void) {
        let kernel = try XCTUnwrap(environment["WISQ_PC_KERNEL"])
        let machine = X86Machine(ramSize: (environment["WISQ_PC_RAM_MIB"].flatMap(Int.init) ?? 1024) << 20) {
            console.append($0)
        }
        if let disk = environment["WISQ_PC_DISK_FILE"] {
            try machine.attach(diskFileAt: URL(fileURLWithPath: disk), writes: writes)
        }
        try machine.attachDisplay(width: 1024, height: 768)
        let line = [X86BootLoader.defaultCommandLine, environment["WISQ_PC_CMDLINE"] ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return (machine, {
            try machine.load(kernelImage: try Data(contentsOf: URL(fileURLWithPath: kernel)), commandLine: line,
                             initialRamdisk: try environment["WISQ_PC_INITRD"].map {
                                 try Data(contentsOf: URL(fileURLWithPath: $0))
                             })
        })
    }

    /// Faire tourner jusqu'à ce que la console montre `marker` après
    /// `from`, ou que le budget soit épuisé. Faux dans ce cas. Le budget
    /// compte l'attente comme `X86Machine.run` : un invité qui dort l'use
    /// aussi, et une marque qui ne vient jamais finit par rendre la main.
    static func run(_ machine: X86Machine, until marker: String, after from: Int = 0, console: Console,
                    budget: UInt64) -> Bool {
        let slice: UInt64 = 50_000_000
        for turn in 0..<(budget / slice) {
            _ = machine.run(instructionBudget: slice)
            if console.text.dropFirst(from).contains(marker) { return true }
            // **Un doigt qui bouge de temps en temps**, toutes les cinq
            // secondes de l'invité : sans rien en entrée, Xorg éteint
            // l'écran au bout de dix minutes, et le bureau ne se voit plus.
            if turn % 34 == 0 { _ = machine.touch(x: turn % 68 == 0 ? 0.25 : 0.5, y: 0.75, buttons: 0) }
        }
        return false
    }

    /// La console, à côté de l'instantané : ce qui s'est passé, même quand un
    /// test échoue.
    static func keep(_ console: Console, at path: String) {
        FileManager.default.createFile(atPath: path, contents: Data(console.text.utf8))
    }

    /// La part de l'écran qui n'est pas noire, de 0 à 1.
    static func litFraction(_ display: X86Framebuffer) -> Double {
        let pixels = display.snapshot()
        var lit = 0
        for index in stride(from: 0, to: pixels.count, by: 4)
        where pixels[index] | pixels[index + 1] | pixels[index + 2] != 0 { lit += 1 }
        return Double(lit) / Double(max(1, pixels.count / 4))
    }

    static func dump(_ display: X86Framebuffer, to path: String) {
        let pixels = display.snapshot()
        var ppm = Data("P6\n\(display.width) \(display.height)\n255\n".utf8)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            ppm += [pixels[index + 2], pixels[index + 1], pixels[index]]
        }
        FileManager.default.createFile(atPath: path, contents: ppm)
    }

    /// **Premier temps** : jusqu'au bureau, puis l'instantané.
    func testTheDesktopIsSaved() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WISQ_PC_KERNEL"] != nil, let out = environment["WISQ_PC_DESKTOP_SAVE"] else {
            throw XCTSkip("définir WISQ_PC_KERNEL (et l'ISO) et WISQ_PC_DESKTOP_SAVE")
        }
        let writes = URL(fileURLWithPath: out + ".writes")
        for suffix in ["", ".map"] { try? FileManager.default.removeItem(atPath: writes.path + suffix) }
        let console = Console()
        let (machine, boot) = try Self.machine(environment, writes: writes, console: console)
        defer { Self.keep(console, at: out + ".console") }
        try boot()
        let budget: UInt64 = 2_000_000_000_000
        XCTAssertTrue(Self.run(machine, until: "login:", console: console, budget: budget), "pas d'invite")
        machine.send(Data("root\n".utf8))
        XCTAssertTrue(Self.run(machine, until: "Password:", console: console, budget: budget))
        var mark = console.text.count
        machine.send(Data("voidlinux\n".utf8))
        // **L'invite d'abord** : ce qui est tapé pendant que `login` vérifie
        // le mot de passe est jeté, et la commande suivante se perdait.
        XCTAssertTrue(Self.run(machine, until: "# ", after: mark, console: console, budget: budget), "pas de shell")
        // Le bureau et son panneau, puis le temps qu'ils se posent. Les
        // marques s'écrivent par calcul : la ligne de commande, que la
        // console répète, ne les contient pas telles quelles.
        mark = console.text.count
        machine.send(Data("until pgrep -x xfce4-panel >/dev/null; do sleep 5; done; sleep 30; echo BUREAU_$((1+1))\n".utf8))
        XCTAssertTrue(Self.run(machine, until: "BUREAU_2", after: mark, console: console, budget: budget),
                      "le bureau n'est pas venu")
        let display = try XCTUnwrap(machine.display)
        Self.dump(display, to: out + "-avant.ppm")
        XCTAssertGreaterThan(Self.litFraction(display), 0.5, "le bureau est à l'écran avant la sauvegarde")
        machine.flushDisk()
        try machine.snapshot().write(to: URL(fileURLWithPath: out))
        print("bureau sauvé à \(machine.retiredInstructions) instructions : \(out)")
    }

    /// **Second temps** : une machine neuve reprend l'instantané. L'écran
    /// revient tel quel, puis l'invité prouve qu'il écoute encore, par la
    /// console série, par le clavier et par la tablette.
    func testTheDesktopComesBackAfterASave() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WISQ_PC_KERNEL"] != nil, let from = environment["WISQ_PC_DESKTOP_RESUME"] else {
            throw XCTSkip("définir WISQ_PC_KERNEL (et l'ISO) et WISQ_PC_DESKTOP_RESUME")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wisq-bureau-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writes = folder.appendingPathComponent("disque.writes")
        for suffix in ["", ".map"] where FileManager.default.fileExists(atPath: from + ".writes" + suffix) {
            try FileManager.default.copyItem(atPath: from + ".writes" + suffix, toPath: writes.path + suffix)
        }
        let console = Console()
        let (machine, _) = try Self.machine(environment, writes: writes, console: console)
        defer { Self.keep(console, at: from + "-repris.console") }
        try machine.restore(try Data(contentsOf: URL(fileURLWithPath: from)))
        let display = try XCTUnwrap(machine.display)
        // **L'écran d'abord, avant la moindre instruction** : c'est ce que
        // l'utilisateur voit en revenant.
        Self.dump(display, to: from + "-repris.ppm")
        XCTAssertGreaterThan(Self.litFraction(display), 0.5, "l'écran repris est noir")
        let budget: UInt64 = 400_000_000_000

        // La console série.
        var mark = console.text.count
        machine.send(Data("echo REPRIS_$((6*7))\n".utf8))
        XCTAssertTrue(Self.run(machine, until: "REPRIS_42", after: mark, console: console, budget: budget),
                      "la console série ne répond plus")

        // Le clavier : Ctrl+Alt+T ouvre un terminal.
        mark = console.text.count
        machine.send(Data("pkill -x xfce4-terminal; sleep 5; echo CLAVIER_$((1+1))\n".utf8))
        XCTAssertTrue(Self.run(machine, until: "CLAVIER_2", after: mark, console: console, budget: budget))
        machine.key(.leftControl, down: true)
        machine.key(.leftAlt, down: true)
        for event in X86Keystrokes.typing("t") { machine.key(event.code, down: event.down) }
        machine.key(.leftAlt, down: false)
        machine.key(.leftControl, down: false)
        mark = console.text.count
        machine.send(Data("sleep 20; pgrep -x xfce4-terminal >/dev/null && echo TERMINAL_$((1+1))\n".utf8))
        XCTAssertTrue(Self.run(machine, until: "TERMINAL_2", after: mark, console: console, budget: budget),
                      "le raccourci du clavier n'a pas ouvert de terminal")

        // La tablette : deux touchers à deux endroits, et `dd` lit dans
        // evdev les quatre premiers événements qui en sortent (96 octets).
        let tablet = try XCTUnwrap(machine.tablet)
        XCTAssertTrue(tablet.isReady, "le pilote de la tablette a disparu")
        mark = console.text.count
        machine.send(Data("D=$(grep -A6 'wisq tablet' /proc/bus/input/devices | grep -o 'event[0-9]*'); (dd if=/dev/input/$D bs=24 count=4 status=none | wc -c | sed 's/^/LU_/' &); sleep 3; echo PRET_$((1+1))\n".utf8))
        XCTAssertTrue(Self.run(machine, until: "PRET_2", after: mark, console: console, budget: budget))
        mark = console.text.count
        XCTAssertTrue(machine.touch(x: 0.3, y: 0.4, buttons: 0))
        XCTAssertTrue(machine.touch(x: 0.6, y: 0.5, buttons: 0))
        XCTAssertTrue(Self.run(machine, until: "LU_96", after: mark, console: console, budget: budget),
                      "la tablette ne parle plus à l'invité")
        Self.dump(display, to: from + "-apres.ppm")
        XCTAssertGreaterThan(Self.litFraction(display), 0.5, "l'écran s'est éteint après la reprise")
        print(console.text.suffix(600))
    }
}
