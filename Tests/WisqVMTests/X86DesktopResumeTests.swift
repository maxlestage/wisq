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
/// `WISQ_PC_RAM_MIB`, `WISQ_PC_CMDLINE` ; `WISQ_PC_BUDGET` borne chaque
/// attente. **C'est la machine de l'application** (`ReadyDesktopBuild.machine`) :
/// carte réseau, écran de l'application et tablette. Le banc branchait une
/// machine nue, sans carte réseau, et un instantané pris ainsi reprend sans
/// réseau dans l'application.
///
/// Le second temps reprend aussi **une archive** (`WISQ_PC_DESKTOP_ARCHIVE`,
/// fabriquée par `wisq-fabrique`) : importée dans un dossier vierge comme le
/// ferait le bouton « Importer », la session cherchée sous l'empreinte du
/// noyau, comme le ferait l'application. `WISQ_PC_IMAGE_NAME` est le nom de
/// l'image dans la bibliothèque, quand ce n'est pas celui de
/// `WISQ_PC_DISK_FILE`.
///
/// Le pilotage par la console est celui de la fabrique : `GuestScript`.
final class X86DesktopResumeTests: XCTestCase {
    static func machine(_ environment: [String: String], writes: URL, console: GuestConsole,
                        ramSize: Int? = nil) throws -> (X86Machine, () throws -> Void) {
        let kernel = try XCTUnwrap(environment["WISQ_PC_KERNEL"])
        let machine = try ReadyDesktopBuild.machine(
            ramSize: ramSize ?? (environment["WISQ_PC_RAM_MIB"].flatMap(Int.init) ?? 1024) << 20,
            frozenAt: nil) { console.append($0) }
        if let disk = environment["WISQ_PC_DISK_FILE"] {
            try machine.attach(diskFileAt: URL(fileURLWithPath: disk), writes: writes)
        }
        let line = [X86BootLoader.defaultCommandLine, environment["WISQ_PC_CMDLINE"] ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return (machine, {
            try machine.load(kernelImage: try Data(contentsOf: URL(fileURLWithPath: kernel)), commandLine: line,
                             initialRamdisk: try environment["WISQ_PC_INITRD"].map {
                                 try Data(contentsOf: URL(fileURLWithPath: $0))
                             })
        })
    }

    static func budget(_ environment: [String: String], default fallback: UInt64) -> UInt64 {
        environment["WISQ_PC_BUDGET"].flatMap(UInt64.init) ?? fallback
    }

    /// La console, à côté de l'instantané : ce qui s'est passé, même quand un
    /// test échoue.
    static func keep(_ console: GuestConsole, at path: String) {
        FileManager.default.createFile(atPath: path, contents: Data(console.text.utf8))
    }

    static func dump(_ display: X86Framebuffer, to path: String) {
        FileManager.default.createFile(atPath: path, contents: GuestScript.ppm(display))
    }

    /// **Premier temps** : jusqu'au bureau, puis l'instantané.
    func testTheDesktopIsSaved() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WISQ_PC_KERNEL"] != nil, let out = environment["WISQ_PC_DESKTOP_SAVE"] else {
            throw XCTSkip("définir WISQ_PC_KERNEL (et l'ISO) et WISQ_PC_DESKTOP_SAVE")
        }
        let writes = URL(fileURLWithPath: out + ".writes")
        for suffix in ["", ".map"] { try? FileManager.default.removeItem(atPath: writes.path + suffix) }
        let console = GuestConsole()
        let (machine, boot) = try Self.machine(environment, writes: writes, console: console)
        defer { Self.keep(console, at: out + ".console") }
        try boot()
        // **Le déroulé de la fabrique**, pas une copie : connexion, bureau,
        // écran dessiné, préparation (`drop_caches`), écran encore.
        let script = GuestScript(machine: machine, console: console)
        try script.run(ReadyDesktopBuild.voidXfce, budget: Self.budget(environment, default: 2_000_000_000_000))
        let display = try XCTUnwrap(machine.display)
        Self.dump(display, to: out + "-avant.ppm")
        XCTAssertGreaterThan(GuestScript.litFraction(display.snapshot()), 0.5,
                             "le bureau est à l'écran avant la sauvegarde")
        machine.flushDisk()
        try machine.snapshot().write(to: URL(fileURLWithPath: out))
        print("bureau sauvé à \(machine.retiredInstructions) instructions : \(out)")
    }

    /// **Second temps** : une machine neuve reprend l'instantané. L'écran
    /// revient tel quel, puis l'invité prouve qu'il écoute encore, par la
    /// console série, par le clavier, par la tablette et par sa carte réseau.
    func testTheDesktopComesBackAfterASave() throws {
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["WISQ_PC_DESKTOP_RESUME"]
        let archive = environment["WISQ_PC_DESKTOP_ARCHIVE"]
        guard environment["WISQ_PC_KERNEL"] != nil, let from = raw ?? archive else {
            throw XCTSkip("définir WISQ_PC_KERNEL (et l'ISO) et WISQ_PC_DESKTOP_RESUME ou WISQ_PC_DESKTOP_ARCHIVE")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wisq-bureau-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved: Data
        let writes: URL
        var ramSize: Int?
        if raw != nil {
            writes = folder.appendingPathComponent("disque.writes")
            for suffix in ["", ".map"] where FileManager.default.fileExists(atPath: from + ".writes" + suffix) {
                try FileManager.default.copyItem(atPath: from + ".writes" + suffix, toPath: writes.path + suffix)
            }
            saved = try Data(contentsOf: URL(fileURLWithPath: from), options: .mappedIfSafe)
        } else {
            // **Comme le téléphone** : l'archive importée dans un dossier
            // vierge, la session cherchée sous l'empreinte du noyau, la
            // couche et la mémoire là où l'application les lit.
            let disk = try XCTUnwrap(environment["WISQ_PC_DISK_FILE"])
            let image = environment["WISQ_PC_IMAGE_NAME"] ?? URL(fileURLWithPath: disk).lastPathComponent
            let installed = try MachineArchive.import(
                from: URL(fileURLWithPath: from), library: [image], in: folder,
                createOwnDisk: { _, _ in throw MachineArchive.Refusal.damaged })
            let kernel = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(environment["WISQ_PC_KERNEL"])))
            let identity = SuspendedMachine.identity(of: kernel, named: installed.key)
            guard case .readable(let session) = SavedSession.find(kernel: identity, in: folder, core: .x86_64) else {
                return XCTFail("pas de session lisible sous l'empreinte du noyau \(identity)")
            }
            saved = session
            writes = try LocalDisk.writesURL(for: installed.keys.overlay(forDisk: image), in: folder)
            XCTAssertTrue(FileManager.default.fileExists(atPath: writes.path + ".map"), "la couche du disque manque")
            ramSize = Int(KernelMemory.size(forKernel: installed.key, in: folder, ceiling: .max))
            XCTAssertEqual(ramSize, X86Machine.savedRAMSize(in: saved), "la mémoire réglée n'est pas celle de la session")
        }
        let console = GuestConsole()
        let (machine, _) = try Self.machine(environment, writes: writes, console: console, ramSize: ramSize)
        defer { Self.keep(console, at: from + "-repris.console") }
        try machine.restore(saved)
        XCTAssertNotNil(machine.network, "la carte réseau n'est pas revenue")
        let display = try XCTUnwrap(machine.display)
        // **L'écran d'abord, avant la moindre instruction** : c'est ce que
        // l'utilisateur voit en revenant.
        Self.dump(display, to: from + "-repris.ppm")
        XCTAssertGreaterThan(GuestScript.litFraction(display.snapshot()), 0.5, "l'écran repris est noir")
        let script = GuestScript(machine: machine, console: console)
        let budget = Self.budget(environment, default: 400_000_000_000)
        let started = Date()

        // **Le bureau lui-même** : `xfdesktop` dessine le fond et les
        // icônes. Un passage a repris un écran au fond noir : on demande s'il
        // vit encore, et ce que le noyau a dit des plantages.
        // La réponse s'écrit par calcul, elle aussi : la console répète la
        // ligne tapée, et « FOND_VIVANT » écrit en clair y était déjà — la
        // vérification passait que `xfdesktop` vive ou non.
        script.type("pgrep -x xfdesktop >/dev/null && echo FOND_VIVANT_$((2+2)) || echo FOND_MORT; dmesg | grep -i -E 'segfault|trap|killed' | tail -4; echo FOND_$((1+1))\n")
        try script.expect("FOND_2", budget: budget)
        XCTAssertTrue(console.contains("FOND_VIVANT_4", after: script.mark), "xfdesktop ne tourne plus")

        // La console série.
        script.type("echo REPRIS_$((6*7))\n")
        try script.expect("REPRIS_42", budget: budget)
        print("la console répond \(String(format: "%.1f", Date().timeIntervalSince(started))) s après la reprise")

        // La carte réseau, vue de l'invité : son pilote tient un périphérique.
        script.type("echo NET_$(ls /sys/bus/virtio/drivers/virtio_net | grep -c virtio)_FIN$((1+1))\n")
        try script.expect("_FIN2", budget: budget)
        XCTAssertTrue(console.contains("NET_1_FIN2", after: script.mark), "l'invité n'a plus de carte réseau")

        // Le clavier : Ctrl+Alt+T ouvre un terminal.
        script.type("pkill -x xfce4-terminal; sleep 5; echo CLAVIER_$((1+1))\n")
        try script.expect("CLAVIER_2", budget: budget)
        machine.key(.leftControl, down: true)
        machine.key(.leftAlt, down: true)
        for event in X86Keystrokes.typing("t") { machine.key(event.code, down: event.down) }
        machine.key(.leftAlt, down: false)
        machine.key(.leftControl, down: false)
        script.type("sleep 20; pgrep -x xfce4-terminal >/dev/null && echo TERMINAL_$((1+1))\n")
        XCTAssertNoThrow(try script.expect("TERMINAL_2", budget: budget),
                         "le raccourci du clavier n'a pas ouvert de terminal")

        // La tablette : deux touchers à deux endroits, et `dd` lit dans
        // evdev les quatre premiers événements qui en sortent (96 octets).
        let tablet = try XCTUnwrap(machine.tablet)
        XCTAssertTrue(tablet.isReady, "le pilote de la tablette a disparu")
        script.type("D=$(grep -A6 'wisq tablet' /proc/bus/input/devices | grep -o 'event[0-9]*'); (dd if=/dev/input/$D bs=24 count=4 status=none | wc -c | sed 's/^/LU_/' &); sleep 3; echo PRET_$((1+1))\n")
        try script.expect("PRET_2", budget: budget)
        XCTAssertTrue(machine.touch(x: 0.3, y: 0.4, buttons: 0))
        XCTAssertTrue(machine.touch(x: 0.6, y: 0.5, buttons: 0))
        XCTAssertNoThrow(try script.expect("LU_96", budget: budget), "la tablette ne parle plus à l'invité")
        Self.dump(display, to: from + "-apres.ppm")
        XCTAssertGreaterThan(GuestScript.litFraction(display.snapshot()), 0.5, "l'écran s'est éteint après la reprise")
        print(console.text.suffix(600))
    }
}
