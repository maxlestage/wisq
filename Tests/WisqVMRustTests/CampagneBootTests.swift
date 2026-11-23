// **Le banc de campagne : une distribution, démarrée comme l'application la
// démarre**, jusqu'à un texte du port série. Il ne tourne pas en CI : sans
// `WISQ_CAMPAGNE_IMAGE`, ses deux tests sont sautés. Il sert à démarrer tout
// le catalogue, une image à la fois, et à garder le port série de chacune.
//
//   swift build --build-tests
//   WISQ_CAMPAGNE_IMAGE=/chemin/void-xfce.iso WISQ_CAMPAGNE_JUSQUA='login: ' \
//   WISQ_CAMPAGNE_SERIE=/tmp/void.log PATH=/root/.bun/bin:$PATH \
//   swift test --skip-build --filter CampagneBootTests/testLEmetteurDemarreLImage
//
// Variables :
//   WISQ_CAMPAGNE_IMAGE     l'image (ISO pour l'émetteur ; ISO ou qcow2 pour le cœur Rust)
//   WISQ_CAMPAGNE_JUSQUA    le texte du port série qui arrête la course (défaut « login: »)
//   WISQ_CAMPAGNE_PATIENCE  secondes de l'hôte au plus (défaut 1800)
//   WISQ_CAMPAGNE_BUDGET    instructions au plus, cœur Rust (défaut 200 milliards)
//   WISQ_CAMPAGNE_RAM_MIB   RAM du cœur Rust (défaut : max(1024, minimumRAM d'IsoBoot))
//   WISQ_CAMPAGNE_ECRAN     « 1 » : l'écran de l'application branché sur le cœur Rust
//   WISQ_CAMPAGNE_SERIE     où écrire tout le port série à la fin

import Foundation
import WisqVM
@testable import WisqVMRust
import XCTest

final class CampagneBootTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func image() throws -> URL {
        guard let path = environment["WISQ_CAMPAGNE_IMAGE"] else {
            throw XCTSkip("WISQ_CAMPAGNE_IMAGE absent")
        }
        return URL(fileURLWithPath: path)
    }

    private func keep(_ serial: Data) {
        if let out = environment["WISQ_CAMPAGNE_SERIE"] {
            try? serial.write(to: URL(fileURLWithPath: out))
        }
    }

    /// **Le chemin de l'application pour une ISO** (`EmitterSetting.opens` vrai
    /// pour un `.discImage` non installé) : `EmitterMachine.open` — qui appelle
    /// `IsoBoot.decide`, choisit la RAM (`chooseRAM`, 1 Gio au plus 2 Gio) et
    /// pose `emitterLine` — puis la page sous Bun, l'ISO lue par le magasin.
    func testLEmetteurDemarreLImage() throws {
        let iso = try image()
        let page = try BunPage.open(name: "campagne")
        defer { page.close() }
        let start = Date()
        let prepared = try EmitterMachine.open(
            iso, unpackingInto: page.folder.appendingPathComponent("iso"), ceiling: 4 << 30)
        print("CAMPAGNE ligne=\(prepared.commandLine)")
        try page.start(prepared)
        let until = environment["WISQ_CAMPAGNE_JUSQUA"] ?? "login: "
        let patience = Double(environment["WISQ_CAMPAGNE_PATIENCE"] ?? "") ?? 1800
        var serial = Data()
        var seen: TimeInterval?
        var last = ""
        do {
            let message = try page.wait(for: until, patience: patience) { message in
                if case .console(let octets, _) = message { serial.append(octets) }
                if String(decoding: serial, as: UTF8.self).contains(until) {
                    seen = Date().timeIntervalSince(start)
                    return true
                }
                if case .stopped = message { return true }
                if case .failure = message { return true }
                return false
            }
            last = "\(message)"
        } catch {
            last = "\(error)"
        }
        keep(serial)
        print("CAMPAGNE émetteur \(iso.lastPathComponent) : « \(until) » à "
              + "\(seen.map { String(format: "%.1f s", $0) } ?? "jamais"), dernier message \(last), "
              + "\(page.store?.reads ?? 0) lectures de l'image, \(serial.count) octets de console")
        XCTAssertNotNil(seen, String(decoding: serial.suffix(3000), as: UTF8.self))
    }

    /// Une console recueillie de n'importe quel fil.
    private final class Console: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    /// **Le chemin de l'application pour une image de cloud** (qcow2 : `opens`
    /// faux, `LocalVMTerminalView`, `RustPCSetting.runs` vrai) — et pour une ISO
    /// quand le JIT est éteint : `IsoBoot.decide` (CloudBoot pour un qcow2),
    /// `RustPCMachine`, le disque branché avec une couche jetable.
    func testLeCoeurRustDemarreLImage() throws {
        let disk = try image()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-campagne-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let boot = try IsoBoot.decide(disk, into: folder.appendingPathComponent("iso"), ceiling: 4 << 30).get()
        let mebibytes = Int(environment["WISQ_CAMPAGNE_RAM_MIB"] ?? "") ?? max(1024, boot.minimumRAM >> 20)
        let console = Console()
        let machine = try XCTUnwrap(RustPCMachine(ramSize: max(mebibytes << 20, boot.minimumRAM)) {
            console.append($0)
        })
        if environment["WISQ_CAMPAGNE_ECRAN"] == "1" { try machine.attachApplicationScreen() }
        try machine.attachDisk(fileAt: boot.disk ?? disk, writes: folder.appendingPathComponent("couche"))
        try machine.load(kernelImage: try Data(contentsOf: boot.kernel), commandLine: boot.commandLine,
                         initialRamdisk: try boot.initrd.map { try Data(contentsOf: $0) })
        print("CAMPAGNE ligne=\(boot.commandLine ?? "")")
        let until = environment["WISQ_CAMPAGNE_JUSQUA"] ?? "login: "
        let patience = Double(environment["WISQ_CAMPAGNE_PATIENCE"] ?? "") ?? 1800
        let budget = UInt64(environment["WISQ_CAMPAGNE_BUDGET"] ?? "") ?? 200_000_000_000
        let start = Date()
        var outcome = GuestOutcome.stopped
        var found = false
        while outcome == .stopped, machine.retiredInstructions < budget,
              Date().timeIntervalSince(start) < patience {
            if String(decoding: console.data, as: UTF8.self).contains(until) { found = true; break }
            outcome = machine.runGuest(instructionBudget: 50_000_000)
        }
        found = found || String(decoding: console.data, as: UTF8.self).contains(until)
        keep(console.data)
        print("CAMPAGNE cœur Rust \(disk.lastPathComponent) : « \(until) » "
              + (found ? "vu" : "pas vu") + String(format: " en %.1f s, ", Date().timeIntervalSince(start))
              + "\(machine.retiredInstructions) instructions, issue \(outcome)")
        XCTAssertTrue(found, String(decoding: console.data.suffix(3000), as: UTF8.self))
    }
}
