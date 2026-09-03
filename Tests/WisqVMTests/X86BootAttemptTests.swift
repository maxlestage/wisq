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
/// **Où on en est, mesuré le 3 septembre 2026 : Linux démarre.** Le vrai
/// noyau d'Alpine 3.20 — Linux 6.6.134-0-lts — se décompresse, entre dans son
/// propre espace d'adressage, et **écrit sur le port série de wisq**. Sa
/// bannière, la carte E820 qu'on lui a donnée, ses zones mémoire, son RCU, sa
/// console :
///
/// ```
/// [    0.000000] Linux version 6.6.134-0-lts (buildozer@build-3-20-x86_64) …
/// [    0.000000] CPU: vendor_id 'wisq  x86-64' unknown, using generic init.
/// [    0.000000] Memory: 218360K/261752K available (14336K kernel code, …)
/// [    0.000000] printk: console [ttyS0] enabled
/// [    0.000000] Failed to register legacy timer interrupt
/// ```
///
/// **Où ça s'arrête, et c'est nommé par le noyau lui-même** : il n'y a ni PIT
/// ni APIC, donc aucune horloge ne bat, et il tourne en rond dans une boucle
/// d'attente. Presque cinq mille octets de journal en sortent avant. La
/// tranche suivante est écrite dans ce message d'erreur.
///
/// **Comment on y est arrivé** : chaque arrêt a nommé la brique suivante. La
/// livraison d'exception (`X86InterruptTests`), puis l'octet haut lu par une
/// instruction plus large que lui, puis `ENDBR64`, les bases de FS et GS,
/// `CMPXCHG`, les registres de débogage, `PREFETCH` — voir
/// `X86KernelBricksTests`, où chacune est tenue par un test.
///
/// **Le budget par défaut est de neuf cents millions d'instructions**, ce qui
/// prend environ 75 s en release et bien plus en debug ; `WISQ_PC_BUDGET` le
/// change, et l'assertion sur la bannière ne tient que si on ne l'a pas
/// baissé.
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
            let budget = ProcessInfo.processInfo.environment["WISQ_PC_BUDGET"]
            try core.run(budget: budget.flatMap { UInt64($0) } ?? 900_000_000)
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

        XCTAssertGreaterThan(core.retired, 0, "au moins une instruction doit s'exécuter")
        // Avec le budget entier, la bannière est un **contrat** : c'est la
        // preuve que le noyau s'est décompressé, qu'il est entré dans son
        // espace d'adressage et qu'il parle. Avec un budget réduit à la main,
        // ce n'en est plus un, et l'exiger serait un test qui ment.
        guard ProcessInfo.processInfo.environment["WISQ_PC_BUDGET"] == nil else { return }
        XCTAssertTrue(serial.contains("Linux version"),
                      "le noyau doit écrire sa bannière sur le port série")
        XCTAssertTrue(serial.contains("console [ttyS0] enabled"),
                      "et aller jusqu'à ouvrir sa console")
    }
}
