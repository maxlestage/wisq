import Foundation
import WisqVM

// Boots a real kernel and reports interpreter throughput in MIPS.
//
// The point of a benchmark in the repository rather than a one-off script: a
// speed claim nobody can re-run is a speed claim nobody should believe. This
// runs the same code path the phone runs, on the same image CI boots.
//
//   swift run -c release wisq-bench [--image PATH] [--instructions N]
//
// Throughput is measured over the whole boot, so it includes the MMIO and trap
// paths a synthetic loop would flatter away.

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

let imagePath = argument("--image")
    ?? ProcessInfo.processInfo.environment["WISQ_LINUX_IMAGE"]
    ?? "/tmp/wisq-test-linux-image/Image"
let budget = UInt64(argument("--instructions") ?? "") ?? 200_000_000

guard let image = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
    FileHandle.standardError.write(Data("image introuvable : \(imagePath)\n".utf8))
    exit(2)
}

// Boot time is the number that matters on a phone, so the default run stops at
// the login prompt rather than at an arbitrary instruction count: past it the
// guest only idles, and idling is cheap to make look fast.
let marker = argument("--until") ?? "buildroot login:"

// Construction cost is not a footnote on a phone: it is 64 MB of guest RAM
// being obtained, and whether those pages become resident up front decides
// both how long the tap-to-boot delay is and how much memory the app holds.
let allocStart = DispatchTime.now().uptimeNanoseconds

let counter = OutputCounter()
nonisolated(unsafe) var machineBox: LinuxMachine?
let machine = LinuxMachine { data in
    counter.add(data)
    if counter.reached(marker) { machineBox?.stop() }
}
machineBox = machine
let allocMs = Double(DispatchTime.now().uptimeNanoseconds - allocStart) / 1e6
try machine.load(kernelImage: image)

let start = DispatchTime.now().uptimeNanoseconds
let outcome = machine.run(instructionBudget: budget)
let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

let retired = machine.retiredInstructions
let mips = Double(retired) / elapsed / 1e6
let banner = counter.sawBanner ? "oui" : "NON"

print(String(format: "instructions : %.1f M retirées (budget %.0f M)",
             Double(retired) / 1e6, Double(budget) / 1e6))
print(String(format: "construction : %.1f ms (64 Mo de RAM invitée)", allocMs))
print(String(format: "durée        : %.3f s", elapsed))
print(String(format: "débit        : %.1f MIPS", mips))
let reached = counter.reached(marker) ? "atteint" : "PAS ATTEINT"
print("repère « \(marker) » : \(reached)")
print("bannière noyau : \(banner)   sortie : \(counter.bytes) octets   issue : \(outcome)")

if CommandLine.arguments.contains("--console") {
    print("--- console ---")
    print(counter.consoleText)
}

// A benchmark that does not check the guest actually booted measures nothing.
guard counter.sawBanner else {
    FileHandle.standardError.write(Data("le noyau n'a pas démarré : mesure sans valeur\n".utf8))
    exit(1)
}

final class OutputCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var byteCount = 0

    /// Behind the lock like everything else here. It was `private(set)`, which
    /// is written under the lock and read without it — the same shape as the
    /// framebuffer's, and the same reason to close it: `@unchecked Sendable`
    /// is a promise about every path in and out, not only the writing ones.
    var bytes: Int {
        lock.lock(); defer { lock.unlock() }
        return byteCount
    }
    var consoleText: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
    var sawBanner: Bool { reached("Linux version") }
    func reached(_ needle: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return text.contains(needle)
    }
    func add(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        byteCount += data.count
        if text.count < 65_536 { text += String(decoding: data, as: UTF8.self) }
    }
}

// MARK: - Le cœur x86-64 : le premier vrai chiffre

// Tranche 3b du lot 7. La feuille de route disait, en toutes lettres, qu'un
// démarrage complet en x86-64 interprété « se compte en dizaines de milliards
// d'instructions » et que cette phrase était une **extrapolation**, à
// confirmer ou à contredire par une mesure. Voici la mesure.
//
// Le programme mesuré n'est pas un compteur qui tourne à vide : il additionne,
// compare, saute, lit et écrit la mémoire, appelle et revient. C'est le
// mélange qu'un noyau exécute, pas celui qui flatte un interprète.

func measureX86() {
    // Un programme assemblé une fois pour toutes, octet pour octet — les mêmes
    // formes que le corpus de la tranche 2 a validées.
    //
    //   boucle:  addq %rcx, %rax        48 01 c8
    //            xorq (%rsi), %rax      48 33 06
    //            movq %rax, 8(%rsi)     48 89 46 08
    //            cmpq %rdx, %rax        48 39 d0
    //            jne suite              75 03
    //            incq %rdx              48 ff c2
    //   suite:   decq %rcx              48 ff c9
    //            jnz boucle             75 e9
    //
    // Les deux déplacements viennent de `as`, pas de ma tête : la première
    // version les avait comptés à la main, l'un valait 2 au lieu de 3, et le
    // saut atterrissait au milieu de l'instruction suivante. Le cœur a fait
    // exactement ce qu'un vrai processeur aurait fait — il a exécuté le dernier
    // octet d'`incq` comme un `RET` — et s'est arrêté au bout de six
    // instructions. C'est le décodeur qui avait raison.
    let program: [UInt8] = [
        0x48, 0x01, 0xC8,
        0x48, 0x33, 0x06,
        0x48, 0x89, 0x46, 0x08,
        0x48, 0x39, 0xD0,
        0x75, 0x03,
        0x48, 0xFF, 0xC2,
        0x48, 0xFF, 0xC9,
        0x75, 0xE9,
        0xF4,  // hlt : la machine s'arrête d'elle-même plutôt que de sortir du code
    ]
    let base: UInt64 = 0x1000
    let memory = X86Memory(size: 1 << 20, base: base)
    try? memory.load(program, at: base)

    var registers = [UInt64](repeating: 0, count: 16)
    registers[1] = 40_000_000          // le compte de tours
    registers[4] = base &+ 0x8_0000    // la pile
    registers[6] = base &+ 0x4_0000    // là où la boucle écrit
    var core = X86Core(registers: registers, rip: base, memory: memory)

    let start = Date()
    var executed: UInt64 = 0
    do { executed = try core.run(budget: 400_000_000) } catch {
        print("  arrêt : \(error) à rip=\(String(core.rip, radix: 16))")
        executed = core.retired
    }
    let seconds = Date().timeIntervalSince(start)
    let mips = seconds > 0 ? Double(executed) / seconds / 1_000_000 : 0

    print("")
    print("x86-64 (lot 7, tranche 3b)")
    print("  ce cœur-ci est en Swift ; les 161 MIPS ci-dessus sont ceux du cœur")
    print("  rv32 en Rust. Comparer les deux chiffres directement serait comparer")
    print("  deux langages autant que deux architectures.")
    print(String(format: "  instructions : %.1f M retirées", Double(executed) / 1_000_000))
    print(String(format: "  durée        : %.3f s", seconds))
    print(String(format: "  débit        : %.1f MIPS", mips))
    // Ce qu'un démarrage complet coûterait à ce débit, si l'on retient les
    // ordres de grandeur habituels. C'est une division, pas une mesure : le
    // dire autrement serait refaire l'erreur que cette tranche corrige.
    if mips > 0 {
        for (what, count) in [("un noyau seul, ~2 G", 2e9), ("un bureau complet, ~50 G", 5e10)] {
            let secs = count / (mips * 1e6)
            print(String(format: "  %@ instructions : %.0f s (%.1f min) — division, pas mesure",
                         what, secs, secs / 60))
        }
    }
}

measureX86()
