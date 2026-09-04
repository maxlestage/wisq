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
/// **Où on en est, mesuré le 4 septembre 2026 : Linux démarre jusqu'au bout.**
/// Le vrai noyau d'Alpine 3.20 — Linux 6.6.134-0-lts — se décompresse, entre
/// dans son propre espace d'adressage, trouve son horloge, initialise ses
/// sous-systèmes, et arrive à `kernel_init`, où il s'arrête pour la seule
/// raison qui reste :
///
/// ```
/// [    0.000000] Linux version 6.6.134-0-lts (buildozer@build-3-20-x86_64) …
/// [    8.929917] printk: console [ttyS0] enabled
/// [   21.480833] smpboot: Total of 1 processors activated (28.82 BogoMIPS)
/// [   21.546634] devtmpfs: initialized
/// [   32.137346] TCP: Hash tables configured (established 2048 bind 2048)
/// [   44.818378] ---[ end Kernel panic - not syncing: VFS: Unable to mount
///                    root fs on unknown-block(0,0) ]---
/// ```
///
/// **C'est la bonne fin.** Un noyau sans disque et sans initrd dit exactement
/// ça, sur une vraie machine comme ici. 262 lignes de journal, une trace
/// d'appels avec les noms des fonctions — donc `printk`, la table des
/// symboles, le dérouleur de pile, les exceptions et l'horloge marchent tous.
/// Ce qui manque n'est plus dans le processeur : c'est un disque, et c'est la
/// tranche suivante de la feuille de route.
///
/// **Comment on y est arrivé** : chaque arrêt a nommé la brique suivante, et
/// jamais l'inverse. Voir `X86InterruptTests` pour la livraison d'exception,
/// `X86KernelBricksTests` pour les instructions, `X86LegacyDevicesTests` pour
/// le contrôleur d'interruptions et l'horloge.
///
/// **Le budget par défaut est de 3,5 milliards d'instructions**, ce qui prend
/// environ quatre minutes et demie en release et bien plus en debug ;
/// `WISQ_PC_BUDGET` le change, et les assertions ne tiennent que si on ne l'a
/// pas baissé.
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

        // Un disque en mémoire, quand on en désigne un : c'est ce qui donne un
        // espace utilisateur, puisque le noyau d'Alpine n'a aucun pilote de
        // disque compilé dedans — ce sont des modules, et ils sont là-dedans.
        let ramdisk = ProcessInfo.processInfo.environment["WISQ_PC_INITRD"]
            .flatMap { FileManager.default.contents(atPath: $0) }
            .map { [UInt8]($0) }
        let memory = X86Memory(size: (ramdisk == nil ? 256 : 512) << 20, base: 0)
        let placement = try X86BootLoader.load(
            kernel: [UInt8](data), into: memory, initialRamdisk: ramdisk)

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
            try core.run(budget: budget.flatMap { UInt64($0) } ?? 3_500_000_000)
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
        XCTAssertTrue(serial.contains("processors activated"),
                      "et activer son processeur, ce qui demande une horloge")
        XCTAssertTrue(serial.contains("Unable to mount root fs"),
                      "et arriver à la seule chose qui manque encore : un disque")
    }
}
