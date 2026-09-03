import XCTest

@testable import WisqVM

/// Jusqu'où va-t-on ?
///
/// Ce test ne prétend pas démarrer Linux. Il **essaie**, et rapporte où ça
/// s'arrête — ce qui vaut mieux que de deviner ce qui manque. Le premier arrêt
/// nomme la première chose à écrire ensuite ; c'est la façon la plus courte de
/// choisir la tranche suivante.
///
/// Il n'échoue donc que si la préparation elle-même casse, jamais parce que le
/// noyau ne va pas assez loin.
///
/// **Où on en est, mesuré le 3 septembre 2026** : **535 845 instructions** du
/// vrai noyau d'Alpine 3.20 s'exécutent, puis le cœur s'arrête sur une faute de
/// page à 0x1000000 — l'adresse où le noyau a été chargé. Le chemin parcouru
/// est réel : le décompresseur tourne, et la séquence qui a arrêté le cœur
/// juste avant (`fninit ; fnstsw ; fnstcw`) est exactement celle par laquelle
/// Linux détecte un coprocesseur, désassemblée pour en être sûr plutôt que
/// devinée.
///
/// **Ce qui n'est pas établi** : si cette faute vient du noyau ou d'une
/// divergence de ce cœur. Le dire demanderait un émulateur de référence contre
/// lequel avancer pas à pas — `qemu-system-x86_64` est là pour ça, et c'est la
/// tranche suivante. Écrire « le noyau démarre » aujourd'hui serait faux, et
/// écrire « ça ne marche pas » cacherait un demi-million d'instructions justes.
final class X86BootAttemptTests: XCTestCase {
    /// Une pagination d'identité sur les quatre premiers gibioctets, en pages
    /// de un gibioctet : quatre entrées suffisent, là où des pages de quatre
    /// kibioctets en demanderaient un million.
    static func identityMap(_ memory: X86Memory, pml4: UInt64) throws {
        let pdpt = pml4 + 0x1000
        try memory.write(pml4, 8, pdpt | X86Core.present | 0x2)
        for gigabyte in 0..<4 {
            let entry = UInt64(gigabyte) << 30
            try memory.write(pdpt + UInt64(gigabyte) * 8, 8,
                             entry | X86Core.present | X86Core.hugePage | 0x2)
        }
    }

    func testHowFarARealKernelGets() throws {
        guard let path = ProcessInfo.processInfo.environment["WISQ_PC_KERNEL"],
              let data = FileManager.default.contents(atPath: path)
        else {
            throw XCTSkip("noyau PC absent : définir WISQ_PC_KERNEL pour ce test")
        }

        let memory = X86Memory(size: 256 << 20, base: 0)
        let placement = try X86BootLoader.load(kernel: [UInt8](data), into: memory)

        // Les tables, hors du chemin du noyau et de la page zéro.
        let pml4: UInt64 = 0x5_0000
        try Self.identityMap(memory, pml4: pml4)

        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: placement.entryPoint, memory: memory)
        // Ce que le protocole exige à l'entrée 64 bits : le mode long actif,
        // la pagination en place, et RSI sur la page zéro.
        core.system.control[3] = pml4
        core.system.control[4] = X86SystemState.physicalAddressExtension
        core.system.modelSpecific[X86SystemState.efer] = X86SystemState.longModeEnable
        core.system.control[0] = X86SystemState.paging | X86SystemState.protectedMode
        core.system.refreshLongMode()
        core.pagingActive = true
        core.registers[6] = placement.bootParametersAddress
        core.registers[4] = 0x9_0000  // une pile quelque part sous le noyau

        XCTAssertTrue(core.system.longMode, "le mode long doit être actif avant le saut")

        var stopped: Error?
        do {
            try core.run(budget: 50_000_000)
        } catch {
            stopped = error
        }

        let serial = String(decoding: core.serialOutput, as: UTF8.self)
        print("""

            === tentative de démarrage x86-64 ===
            instructions retirées : \(core.retired)
            arrêt                 : \(stopped.map { "\($0)" } ?? (core.halted ? "hlt" : "budget"))
            rip                   : 0x\(String(core.rip, radix: 16))
            octets à RIP          : \(core.memory.map {
                (try? $0.read(core.rip, 8)).map { String($0, radix: 16) } ?? "?"
            } ?? "?")
            port série            : \(core.serialOutput.count) octets
            \(serial.isEmpty ? "" : serial)
            =====================================

            """)

        // La seule chose exigée ici : la préparation tient debout. Ce que le
        // noyau fait ensuite est un renseignement, pas un contrat.
        XCTAssertGreaterThan(core.retired, 0, "au moins une instruction doit s'exécuter")
    }
}
