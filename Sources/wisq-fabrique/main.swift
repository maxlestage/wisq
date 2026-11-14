import Foundation
import WisqVM
import WisqVMRust

// **Fabriquer un bureau prêt** : une image vérifiée en entrée, une archive
// `.wisqmachine` et sa fiche en sortie. L'application l'importe à côté de
// l'image et reprend le bureau en quelques secondes, au lieu de la demi-heure
// que le bureau Xfce met à démarrer sous l'interprète.
//
//   swift build -c release --product wisq-fabrique
//   .build/release/wisq-fabrique <image.iso> <dossier-de-sortie> \
//       [--nom void-live-x86_64-20250202-xfce.iso] [--titre "Void Xfce (prêt)"] \
//       [--ram 1024] [--budget 2000000000000] [--heure 2026-11-14T00:00:00Z] \
//       [--commit <sha>] [--brut] [--sans-zero]
//
// Tout ce qui décide vit dans `WisqVM` (`ReadyDesktopBuild`, `GuestScript`),
// jugé par les tests sous Linux ; ce fichier ne fait que l'enchaîner, avec le
// noyau sorti de l'image par `IsoBoot`, comme sur le téléphone.

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

/// Ce que la fabrication dit en route, daté, sur la sortie standard : une
/// course dure une demi-heure, et un journal muet ne se distingue pas d'une
/// machine bloquée.
final class Journal: @unchecked Sendable {
    let start = Date()
    func say(_ line: String) {
        let seconds = Int(Date().timeIntervalSince(start))
        // Écrit sans tampon : `print` garde la ligne tant que la sortie est
        // un fichier, et le journal d'une course en arrière-plan restait vide.
        FileHandle.standardOutput.write(Data((String(format: "[%5d s] ", seconds) + line + "\n").utf8))
    }
}

/// La machine, plus une ligne de journal toutes les `every` tranches.
final class Watched: ScriptableMachine {
    let machine: X86Machine
    let journal: Journal
    let every: Int
    private var slices = 0

    init(_ machine: X86Machine, journal: Journal, every: Int = 200) {
        self.machine = machine
        self.journal = journal
        self.every = every
    }

    func advance(_ instructions: UInt64) -> String? {
        let ended = machine.advance(instructions)
        slices += 1
        if slices % every == 0 {
            let elapsed = Date().timeIntervalSince(journal.start)
            let retired = machine.retiredInstructions
            journal.say("\(retired / 1_000_000) M instructions, \(Int(Double(retired) / max(elapsed, 1) / 1e6)) MIPS")
        }
        return ended
    }

    func send(_ data: Data) { machine.send(data) }
    func nudge(x: Double, y: Double) { machine.nudge(x: x, y: y) }
    var screenPixels: [UInt8]? { machine.screenPixels }
}

struct Stop: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func fabricate() throws {
    // Les arguments de position : tout ce qui n'est ni une option, ni la
    // valeur d'une option qui en prend une.
    var positional: [String] = []
    var rest = CommandLine.arguments.dropFirst()[...]
    while let word = rest.popFirst() {
        if ["--brut", "--sans-zero"].contains(word) { continue }
        if word.hasPrefix("--") { _ = rest.popFirst(); continue }
        positional.append(word)
    }
    guard positional.count == 2 else {
        throw Stop("usage : wisq-fabrique <image.iso> <dossier-de-sortie> [--nom N] [--titre T] "
            + "[--ram Mio] [--budget N] [--heure AAAA-MM-JJTHH:MM:SSZ] [--commit SHA] [--brut] [--sans-zero]")
    }
    let iso = URL(fileURLWithPath: positional[0])
    let out = URL(fileURLWithPath: positional[1], isDirectory: true)
    let imageName = argument("--nom") ?? iso.lastPathComponent
    let title = argument("--titre") ?? "Void Xfce (prêt)"
    let budget = UInt64(argument("--budget") ?? "") ?? 2_000_000_000_000
    let base = imageName.hasSuffix(".iso") ? String(imageName.dropLast(4)) : imageName
    let frozen: Date
    if let text = argument("--heure") {
        guard let date = ISO8601DateFormatter().date(from: text) else { throw Stop("--heure illisible : \(text)") }
        frozen = date
    } else {
        frozen = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }
    let journal = Journal()
    let files = FileManager.default
    try files.createDirectory(at: out, withIntermediateDirectories: true)
    let work = out.appendingPathComponent("atelier-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: work) }

    // **Le noyau, sorti par le code du téléphone.** Son empreinte nomme la
    // session : un noyau extrait autrement serait une session introuvable.
    journal.say("image : \(iso.path) (sous le nom \(imageName))")
    let boot: IsoBoot.Boot
    switch IsoBoot.decide(iso, into: work.appendingPathComponent("iso"), ceiling: 2 << 30) {
    case .success(let found): boot = found
    case .failure(let refusal): throw Stop(IsoBoot.explanation(refusal, name: iso.lastPathComponent))
    }
    guard boot.disk == iso, let recipeLine = boot.commandLine else {
        throw Stop("\(iso.lastPathComponent) n'est pas une image d'installation que wisq démarre")
    }
    let kernel = try Data(contentsOf: boot.kernel)
    let initrd = try boot.initrd.map { try Data(contentsOf: $0) }
    let ram = max(X86Machine.minimumRAMSize, boot.minimumRAM, (Int(argument("--ram") ?? "") ?? 0) << 20)
    let line = ReadyDesktopBuild.commandLine(recipeLine, zeroingFreedPages: !flag("--sans-zero"))
    journal.say("noyau \(kernel.count) octets, empreinte \(ReadyDesktopBuild.kernelDigest(kernel)) ; "
        + "initramfs \(initrd?.count ?? 0) octets ; mémoire \(ram >> 20) Mio")
    journal.say("ligne : \(line)")
    journal.say("heure figée : \(ISO8601DateFormatter().string(from: frozen))")

    let (installed, writes) = try ReadyDesktopBuild.install(image: imageName, name: title, in: work)
    let console = GuestConsole()
    let consolePath = out.appendingPathComponent(base + "-pret.console")
    let snapshot: Data
    let instructions: UInt64
    do {
        let machine = try ReadyDesktopBuild.machine(ramSize: ram, frozenAt: frozen) { console.append($0) }
        try machine.attach(diskFileAt: iso, writes: writes)
        try machine.load(kernelImage: kernel, commandLine: line, initialRamdisk: initrd)
        let script = GuestScript(machine: Watched(machine, journal: journal), console: console)
        script.log = { journal.say($0) }
        defer { _ = files.createFile(atPath: consolePath.path, contents: Data(console.text.utf8)) }
        try script.run(ReadyDesktopBuild.voidXfce, budget: budget)
        machine.flushDisk()
        if let display = machine.display {
            _ = files.createFile(atPath: out.appendingPathComponent(base + "-pret.ppm").path,
                             contents: GuestScript.ppm(display))
        }
        snapshot = machine.snapshot()
        instructions = machine.retiredInstructions
    }
    journal.say("instantané : \(snapshot.count) octets à \(instructions) instructions")
    if flag("--brut") {
        try snapshot.write(to: out.appendingPathComponent(base + "-pret.snap"))
    }

    // **Repris dans une machine de l'application neuve**, avant d'emporter
    // quoi que ce soit : réseau, écran dessiné, tablette, mémoire, niveau.
    let lit = try ReadyDesktopBuild.check(snapshot, ramSize: ram)
    journal.say("vérifié : repris dans une machine neuve, écran allumé à \(Int(lit * 100)) %")

    let archive = out.appendingPathComponent(base + "-pret." + MachineArchive.fileExtension)
    let identity = try ReadyDesktopBuild.assemble(
        installed, snapshot: snapshot, kernel: kernel, in: work, to: archive)
    let packed = (try files.attributesOfItem(atPath: work.appendingPathComponent(
        SuspendedMachine.fileName(kernel: identity)).path)[.size] as? NSNumber)?.uint64Value ?? 0
    journal.say("archive : \(archive.path), session \(identity)")

    journal.say("sommes de l'image et de l'archive…")
    let sheet = ReadyDesktopBuild.Sheet(
        title: title, level: X86Machine.snapshotLevel,
        image: try .measure(iso, name: imageName), archive: try .measure(archive),
        kernelDigest: ReadyDesktopBuild.kernelDigest(kernel), ramBytes: UInt64(ram),
        screen: [GuestMachineFactory.screenSize.width, GuestMachineFactory.screenSize.height],
        commandLine: line, madeAt: Date(), guestClock: frozen, instructions: instructions,
        snapshotBytes: UInt64(snapshot.count), packedBytes: packed, commit: argument("--commit"))
    let sheetURL = out.appendingPathComponent(base + "-pret.json")
    try sheet.encoded().write(to: sheetURL)
    journal.say("fiche : \(sheetURL.path)")
    FileHandle.standardOutput.write(try sheet.encoded() + Data("\n".utf8))
}

do {
    try fabricate()
} catch {
    FileHandle.standardError.write(Data("wisq-fabrique : \(error)\n".utf8))
    exit(1)
}
