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
//       [--coeur swift|rust] \
//       [--nom void-live-x86_64-20250202-xfce.iso] [--titre "Void Xfce (prêt)"] \
//       [--ram 1024] [--budget 2000000000000] [--heure 2026-11-14T00:00:00Z] \
//       [--commit <sha>] [--brut] [--sans-zero]
//
// `--coeur rust` fabrique sur la machine PC en Rust (`RustReadyDesktopBuild`) :
// une session `WISQPC\r\n` que l'application reprend sur ce cœur, sous un nom
// à part (`…-pret-rust-niveau2`). Sans l'option, le cœur Swift, comme avant.
//
// Et l'index que l'application lit (`ReadyDesktop.index`), à partir des
// fiches, aux adresses où l'image et l'archive sont publiées :
//
//   .build/release/wisq-fabrique index <bureaux.json> <fiche.json>... \
//       --images https://repo-default.voidlinux.org/live/20250202 \
//       --archives https://github.com/maxlestage/wisq/releases/download/bureaux-1 \
//       [--garder <ancien bureaux.json>]
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
    let machine: ScriptableMachine & GuestMachine
    let journal: Journal
    let every: Int
    private var slices = 0

    init(_ machine: ScriptableMachine & GuestMachine, journal: Journal, every: Int = 200) {
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
        throw Stop("usage : wisq-fabrique <image.iso> <dossier-de-sortie> [--coeur swift|rust] [--nom N] "
            + "[--titre T] [--ram Mio] [--budget N] [--heure AAAA-MM-JJTHH:MM:SSZ] [--commit SHA] [--brut] "
            + "[--sans-zero]")
    }
    let iso = URL(fileURLWithPath: positional[0])
    let out = URL(fileURLWithPath: positional[1], isDirectory: true)
    let imageName = argument("--nom") ?? iso.lastPathComponent
    let title = argument("--titre") ?? "Void Xfce (prêt)"
    let budget = try ReadyDesktopBuild.budget(argument("--budget"))
    // Le cœur, puis son niveau : celui d'`X86Machine`, ou la version de
    // l'instantané du cœur Rust.
    let core = try ReadyDesktopBuild.core(argument("--coeur"))
    let level = core == .rust ? RustReadyDesktopBuild.level : X86Machine.snapshotLevel
    // Le niveau, et le cœur, dans le nom : voir `ReadyDesktopBuild.outputStem`.
    let stem = ReadyDesktopBuild.outputStem(image: imageName, level: level, core: core)
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
    // Jugée ici, avant la demi-heure de démarrage : une taille que
    // l'application ne règle pas n'était refusée qu'à l'assemblage.
    let ram = try ReadyDesktopBuild.memory(requestedMiB: argument("--ram"), minimum: boot.minimumRAM)
    let line = ReadyDesktopBuild.commandLine(recipeLine, zeroingFreedPages: !flag("--sans-zero"))
    journal.say("noyau \(kernel.count) octets, empreinte \(ReadyDesktopBuild.kernelDigest(kernel)) ; "
        + "initramfs \(initrd?.count ?? 0) octets ; mémoire \(ram >> 20) Mio")
    journal.say("ligne : \(line)")
    journal.say("heure figée : \(ISO8601DateFormatter().string(from: frozen))")
    journal.say("cœur : \(core.rawValue), niveau \(level)")

    let (installed, writes) = try ReadyDesktopBuild.install(image: imageName, name: title, in: work)
    let console = GuestConsole()
    let consolePath = out.appendingPathComponent(stem + ".console")
    let snapshot: Data
    let instructions: UInt64
    do {
        // **La machine de l'application**, du cœur choisi : la même carte,
        // le même écran, le réseau isolé et l'heure figée.
        let machine: ScriptableMachine & GuestMachine
        let screenFile: () -> Data?
        switch core {
        case .swift:
            let pc = try ReadyDesktopBuild.machine(ramSize: ram, frozenAt: frozen) { console.append($0) }
            try pc.attach(diskFileAt: iso, writes: writes)
            machine = pc
            screenFile = { pc.display.map { GuestScript.ppm($0) } }
        case .rust:
            let pc = try RustReadyDesktopBuild.machine(ramSize: ram, frozenAt: frozen) { console.append($0) }
            try pc.attachDisk(fileAt: iso, writes: writes)
            machine = pc
            screenFile = {
                pc.display.map { screen in
                    let (mode, data) = screen.frame()
                    return GuestScript.ppm(pixels: [UInt8](data), width: mode.width, height: mode.height)
                }
            }
        }
        try machine.load(kernelImage: kernel, commandLine: line, initialRamdisk: initrd)
        let script = GuestScript(machine: Watched(machine, journal: journal), console: console)
        script.log = { journal.say($0) }
        defer { _ = files.createFile(atPath: consolePath.path, contents: Data(console.text.utf8)) }
        try script.run(ReadyDesktopBuild.voidXfce, budget: budget)
        machine.flushDisk()
        if let ppm = screenFile() {
            _ = files.createFile(atPath: out.appendingPathComponent(stem + ".ppm").path, contents: ppm)
        }
        snapshot = machine.snapshot()
        instructions = machine.retiredInstructions
    }
    journal.say("instantané : \(snapshot.count) octets à \(instructions) instructions")
    if flag("--brut") {
        try snapshot.write(to: out.appendingPathComponent(stem + ".snap"))
    }

    // **Repris dans une machine de l'application neuve**, avant d'emporter
    // quoi que ce soit : réseau, écran dessiné, tablette, mémoire, niveau.
    // Le cœur Rust reprend sur les disques de l'instantané : l'image, et la
    // couche que l'archive va emporter.
    let checkStart = Date()
    let lit: Double
    switch core {
    case .swift: lit = try ReadyDesktopBuild.check(snapshot, ramSize: ram)
    case .rust: lit = try RustReadyDesktopBuild.check(snapshot, ramSize: ram, disk: iso, writes: writes)
    }
    journal.say("vérifié : repris dans une machine neuve en \(String(format: "%.2f", Date().timeIntervalSince(checkStart))) s, "
        + "écran allumé à \(Int(lit * 100)) %")

    let archive = out.appendingPathComponent(stem + "." + MachineArchive.fileExtension)
    let identity = try ReadyDesktopBuild.assemble(
        installed, snapshot: snapshot, kernel: kernel, in: work, to: archive)
    let packed = (try files.attributesOfItem(atPath: work.appendingPathComponent(
        SuspendedMachine.fileName(kernel: identity)).path)[.size] as? NSNumber)?.uint64Value ?? 0
    journal.say("archive : \(archive.path), session \(identity)")

    journal.say("sommes de l'image et de l'archive…")
    let sheet = ReadyDesktopBuild.Sheet(
        title: title, level: level,
        image: try .measure(iso, name: imageName), archive: try .measure(archive),
        kernelDigest: ReadyDesktopBuild.kernelDigest(kernel), ramBytes: UInt64(ram),
        screen: [GuestMachineFactory.screenSize.width, GuestMachineFactory.screenSize.height],
        commandLine: line, madeAt: Date(), guestClock: frozen, instructions: instructions,
        snapshotBytes: UInt64(snapshot.count), packedBytes: packed,
        snapshotSHA256: SHA256Stream.hex(snapshot), commit: argument("--commit"), core: core)
    let sheetURL = out.appendingPathComponent(stem + ".json")
    try sheet.encoded().write(to: sheetURL)
    journal.say("fiche : \(sheetURL.path)")
    FileHandle.standardOutput.write(try sheet.encoded() + Data("\n".utf8))
}

/// **L'index des bureaux prêts**, écrit par le même type que celui que
/// l'application lit (`ReadyDesktop.Index`), et relu comme elle le lira : une
/// entrée qu'elle écarterait — un hôte, un nom, une somme — arrête tout, au
/// lieu de partir dans une release où personne ne la verrait jamais ; deux
/// fichiers à la même adresse aussi (`Index.publishable`).
func makeIndex() throws {
    var positional: [String] = []
    var rest = CommandLine.arguments.dropFirst(2)[...]
    while let word = rest.popFirst() {
        if word.hasPrefix("--") { _ = rest.popFirst(); continue }
        positional.append(word)
    }
    guard positional.count >= 2,
          let images = argument("--images").flatMap(URL.init(string:)),
          let archives = argument("--archives").flatMap(URL.init(string:))
    else {
        throw Stop("usage : wisq-fabrique index <bureaux.json> <fiche.json>... --images URL --archives URL "
            + "[--garder ancien.json]")
    }
    let entries = try positional.dropFirst().map { path in
        let sheet = try ReadyDesktopBuild.Sheet.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        return ReadyDesktop.Index.Entry(
            sheet: sheet, image: images.appendingPathComponent(sheet.image.name),
            archive: archives.appendingPathComponent(sheet.archive.name))
    }
    let old = try argument("--garder").map { try ReadyDesktop.Index.decode(Data(contentsOf: URL(fileURLWithPath: $0))) }
    let index: ReadyDesktop.Index
    do {
        index = try ReadyDesktop.Index.publishable(ReadyDesktop.Index(desktops: entries), keeping: old)
    } catch let fault as ReadyDesktop.Index.Fault {
        throw Stop(fault.description)
    }
    try index.encoded().write(to: URL(fileURLWithPath: positional[0]))
    FileHandle.standardOutput.write(Data("index : \(positional[0]), \(index.desktops.count) bureau(x)\n".utf8))
}

do {
    if CommandLine.arguments.dropFirst().first == "index" {
        try makeIndex()
    } else {
        try fabricate()
    }
} catch {
    FileHandle.standardError.write(Data("wisq-fabrique : \(error)\n".utf8))
    exit(1)
}
