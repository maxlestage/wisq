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
/// **Où on en est, mesuré le 3 septembre 2026** : **494 661 172 instructions**
/// du vrai noyau d'Alpine 3.20 s'exécutent — 38,8 s en release, soit
/// 12,7 MIPS — puis le cœur s'arrête sur un accès **hors de la mémoire de
/// l'invité**, à l'adresse physique 0x700070D070040, dans un `rep movsq`.
/// L'adresse est absurde, donc quelque chose l'a calculée de travers : c'est
/// la prochaine chose à chercher, et elle est nommée plutôt que devinée.
///
/// Le budget par défaut de ce test est de cinquante millions d'instructions,
/// pour qu'il reste supportable en debug ; `WISQ_PC_BUDGET` le change. Le
/// chiffre ci-dessus vient d'une exécution en release.
///
/// **Ce qui a débloqué ça.** Avant, le cœur s'arrêtait à 538 976 instructions
/// sur une faute de page à 0x0D000000, et on ne savait pas si elle venait du
/// noyau ou d'une divergence. La réponse n'a pas demandé d'émulateur de
/// référence : il a suffi de lire l'IDT que le noyau avait chargée. Limite
/// 0x1FF, un **seul** vecteur présent — le quatorze, la faute de page —
/// ciblant du code qui commence par la séquence d'empilement de
/// `boot_idt_handler`. C'est ainsi que le décompresseur 64 bits de Linux
/// cartographie : à la demande, depuis son propre gestionnaire. Le noyau
/// disait savoir traiter cette faute ; personne ne la lui rendait. Voir
/// `X86InterruptTests`.
///
/// **Ce qui n'est pas établi** : où ça finit. Rien n'est encore sorti du port
/// série, donc écrire « le noyau démarre » serait faux. La suite est nommée
/// par le noyau lui-même : après la décompression vient le vrai noyau, et il
/// voudra un contrôleur d'interruptions, une horloge et une console.
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
            try core.run(budget: budget.flatMap { UInt64($0) } ?? 50_000_000)
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
