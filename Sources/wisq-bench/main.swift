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
