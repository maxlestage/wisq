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
///
/// **Avec un initrd, ça va plus loin.** `WISQ_PC_INITRD` désigne un
/// initramfs ; le noyau le déballe dans un tmpfs et exécute son `/init`. Avec
/// l'`initramfs-lts` d'Alpine, mesuré le 4 septembre 2026 après le TSS :
///
/// ```
/// [  156.951571] modprobe[405]: segfault at 27d7eb9f76ac0 …
/// [  158.985105] Run /init as init process
/// [  159.045459] init[1]: segfault at 37cde165f730c ip 00007f89e84be249
///                sp 00007ffd96773770 error 5 in ld-musl-x86_64.so.1
/// [  159.051870] Kernel panic — Attempted to kill init! exitcode=0x0000000b
/// ```
///
/// **Plus aucun opcode refusé** : le budget entier de 3,5 milliards
/// d'instructions passe, le journal grandit de 12 685 à 17 225 octets, le
/// noyau finit son initialisation et lance `/init`, qui fait de vrais appels
/// système — `modprobe` tourne deux fois avant lui.
///
/// **Et l'arrêt suivant est nommé, précisément.** Le programme meurt d'un
/// SIGSEGV dans le chargeur de musl. Les octets que le noyau imprime —
/// `<8b> 87 8c 00 00 00`, c'est-à-dire `mov 0x8c(%rdi),%eax` — se retrouvent à
/// l'offset 0x4f209 de `ld-musl-x86_64.so.1`, au début de **`feof`**. Le
/// `FILE *` qu'on lui passe vaut `0x00037cde165f7280` là où un pointeur de
/// cette bibliothèque ressemble à `0x00007f89e85118a0`. Ce n'est donc plus une
/// instruction qui manque : c'est une valeur qui se corrompt quelque part, et
/// c'est la tranche suivante.
///
/// **L'ordre des trois dernières briques n'était pas celui du plan.** Il
/// disait « le TSS, puis SYSCALL » ; la machine a dit que `MOVD` venait
/// d'abord, parce que la bibliothèque C se sert de SSE dans ses fonctions de
/// chaîne **avant** son premier appel système. Le plan avait raison sur le
/// quoi et tort sur l'ordre, deux fois de suite.
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

        // Le témoin des adresses non canoniques, quand on le demande. Il coûte
        // une recopie des seize registres par instruction d'anneau trois, donc
        // il n'est pas armé pour le démarrage ordinaire.
        core.canonicalWatchArmed =
            ProcessInfo.processInfo.environment["WISQ_PC_WATCH"] != nil

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
            appels par la mémoire : \(core.indirectCalls.isEmpty ? "aucun"
                : "\(core.indirectCalls.count) distincts\n"
                    + core.indirectCalls.map { "  " + $0.description }
                        .joined(separator: "\n"))
            passages d'anneau : \(core.ringPassages.description)\(core.ringTrips.isEmpty
                ? "" : "\n" + core.ringTrips.map { "  " + $0.description }
                    .joined(separator: "\n"))
            retours sans promesse : \(core.unmatchedReturns.isEmpty ? "aucun"
                : "\n" + core.unmatchedReturns.map { "  " + $0.description }
                    .joined(separator: "\n"))
            retours rompus : \(core.brokenReturns.isEmpty ? "aucun"
                : "\n" + core.brokenReturns.map { "  " + $0.description }
                    .joined(separator: "\n"))
            programmes démarrés : \(core.processStarts.isEmpty ? "aucun"
                : "\n" + core.processStarts.map { "  " + $0.description }
                    .joined(separator: "\n"))
            adresses non canoniques : \(core.nonCanonicalSeen.isEmpty ? "aucune"
                : "\n" + core.nonCanonicalSeen.map { "  " + $0.description }
                    .joined(separator: "\n"))
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

        // **Deux fins différentes, parce que ce sont deux machines
        // différentes.** Sans disque en mémoire, un noyau panique faute de
        // racine, et c'est la bonne fin. Avec, il en a une : exiger la même
        // phrase serait exiger qu'un mécanisme qui marche échoue quand même —
        // et cette assertion-là était bel et bien écrite ainsi, donc ce test
        // ne pouvait pas passer dans la configuration où il va le plus loin.
        guard ramdisk != nil else {
            XCTAssertTrue(serial.contains("Unable to mount root fs"),
                          "sans disque, c'est la seule chose qui manque")
            return
        }
        XCTAssertTrue(serial.contains("Freeing initrd memory"),
                      "avec un disque en mémoire, le noyau doit le déballer et le rendre")
        // **Ce qui remplace « on s'arrête en anneau trois ».** Cette
        // assertion-là tenait tant que le cœur s'arrêtait *pendant* que le
        // programme tournait ; depuis que plus aucun opcode ne manque, la
        // course va plus loin et finit dans le noyau — donc en anneau zéro.
        // Ce qu'il faut exiger n'est pas où l'on s'arrête, c'est que l'espace
        // utilisateur ait bien été atteint, et le noyau le dit lui-même.
        XCTAssertTrue(serial.contains("Run /init as init process"),
                      "et passer la main à un programme")
    }
}
