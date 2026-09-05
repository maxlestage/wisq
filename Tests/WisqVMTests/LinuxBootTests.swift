import XCTest
@testable import WisqVM

/// Boots a real Linux kernel — the same rv32 nommu image the reference emulator
/// runs — and reads its console. There is no better test of an emulator than
/// the guest it was built for.
///
/// The image is not committed (3.4 MB of GPL binary does not belong in the
/// repo); the test looks for it at `WISQ_LINUX_IMAGE` or a well-known local
/// path and skips, loudly, when absent. CI downloads it in a dedicated step.
final class LinuxBootTests: XCTestCase {
    private static func imageURL() -> URL? {
        // The environment names where CI *tried* to put the image; when the
        // download failed the file is simply absent, and that must be a skip,
        // not a failure blaming the emulator.
        let candidates = [
            ProcessInfo.processInfo.environment["WISQ_LINUX_IMAGE"],
            "/tmp/wisq-test-linux-image/Image",
        ]
        for case let path? in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func testBootsARealKernelToItsBanner() throws {
        guard let url = Self.imageURL() else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: url)

        let console = ConsoleCapture()
        let machine = LinuxMachine { console.append($0) }
        try machine.load(kernelImage: image)

        // The banner prints within the first few million instructions; the
        // budget is generous so a slow debug build still gets there, and small
        // enough that a broken emulator fails in seconds instead of hanging.
        let outcome = machine.run(instructionBudget: 60_000_000)

        let output = console.text()
        XCTAssertTrue(
            output.contains("Linux version"),
            "la bannière du noyau doit apparaître; sortie: \(output.prefix(400))"
        )
        XCTAssertTrue(
            output.contains("rv32ima") || output.contains("riscv"),
            "le noyau doit se reconnaître sur du RISC-V; sortie: \(output.prefix(400))"
        )
        XCTAssertEqual(outcome, .stopped, "le budget doit expirer, pas la machine planter")
    }

    /// The banner is the second millisecond of the boot. This is the rest of it.
    ///
    /// A sweep of the interpreter's decoder — every arm turned into a no-op, one
    /// at a time — found sixty-six of a hundred and six held by no test at all,
    /// and the cause was shared: the assertion above stops at the first line the
    /// kernel prints. Break the write to `mtvec` and the machine derails so
    /// badly the run takes fifty-one seconds instead of six — and passes,
    /// because the banner had already gone out. Everything after it — the trap
    /// vector, `MRET`, the CSRs, the atomics, the drop to user mode — happened
    /// inside a test that had stopped looking.
    ///
    /// Reaching `buildroot login:` is not a longer version of the same claim.
    /// It is init running as a user-mode process on a console the kernel handed
    /// over, which cannot happen unless the machinery above works. It is also
    /// what the guide promises the reader — *jusqu'à l'invite de connexion* —
    /// and until now nothing checked the half of that sentence that matters.
    ///
    /// The budget is the one the banner test already spent: the prompt arrives
    /// around forty-six million instructions, well inside sixty. The reach was
    /// there the whole time and only the assertion was missing.
    func testBootsAllTheWayToItsLoginPrompt() throws {
        guard let url = Self.imageURL() else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: url)

        let console = ConsoleCapture()
        let machine = LinuxMachine { console.append($0) }
        try machine.load(kernelImage: image)
        let outcome = machine.run(instructionBudget: 60_000_000)

        let output = console.text()
        XCTAssertTrue(
            output.contains("Run /init as init process"),
            "le noyau doit passer la main à l'espace utilisateur; fin de sortie: \(output.suffix(400))"
        )
        XCTAssertTrue(
            output.contains("buildroot login:"),
            "l'invite de connexion doit apparaître; fin de sortie: \(output.suffix(400))"
        )
        XCTAssertEqual(outcome, .stopped, "le budget doit expirer, pas la machine planter")
    }

    /// **La ligne de commande n'est plus plafonnée, et l'invité la lit.**
    ///
    /// Elle l'était à cinquante-quatre caractères, et ce n'était pas une règle
    /// de la machine : c'était la place que le blob de référence se trouvait
    /// avoir entre deux propriétés. L'arbre est construit depuis, la ligne est
    /// une propriété comme une autre, et le refus n'avait plus rien à défendre.
    ///
    /// Le test **relit l'arbre posé en mémoire** plutôt que de se contenter du
    /// silence de `load` : « ça n'a pas levé d'erreur » ne dit pas que le noyau
    /// verra quoi que ce soit.
    func testALongCommandLineIsAcceptedAndReachesTheGuest() throws {
        let machine = LinuxMachine { _ in }
        let long = String(repeating: "console=ttyS0 ", count: 40)
        XCTAssertGreaterThan(long.count, 54, "plus long que ce que le blob permettait")
        try machine.load(kernelImage: Data([0x13, 0x00, 0x00, 0x00]), commandLine: long)

        let tree = try DeviceTree.read(machine.deviceTreeHandedToTheGuest)
        XCTAssertEqual(tree.root.child("chosen")?.property("bootargs"), .string(long))
    }

    /// Et l'arbre remis tombe sur huit octets, à toutes les longueurs.
    ///
    /// C'est le défaut que ce remplacement a fait vivre : un arbre de 1507
    /// octets a donné une adresse impaire, et le noyau n'a rien dit du tout —
    /// pas de bannière, pas de panique, une sortie vide. Le seul symptôme d'un
    /// DTB mal aligné est le silence, donc c'est l'alignement qu'on mesure.
    func testTheTreeHandedToTheGuestIsEightByteAligned() throws {
        for line in ["console=ttyS0", "a", "ab", "abc", "abcd", "abcde"] {
            let machine = LinuxMachine { _ in }
            try machine.load(kernelImage: Data([0x13, 0x00, 0x00, 0x00]), commandLine: line)
            XCTAssertEqual(machine.deviceTreeAddress % 8, 0, "ligne « \(line) »")
        }
    }

    func testStopInterruptsARunningMachine() throws {
        let machine = LinuxMachine { _ in }
        // An infinite loop: jal x0, 0 — jumps to itself forever.
        try machine.load(kernelImage: Data([0x6F, 0x00, 0x00, 0x00]))

        let expectation = expectation(description: "run returns")
        Thread {
            let outcome = machine.run()
            XCTAssertEqual(outcome, .stopped)
            expectation.fulfill()
        }.start()

        machine.stop()
        wait(for: [expectation], timeout: 10)
    }

    final class ConsoleCapture: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk); lock.unlock()
        }

        func text() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Le même vrai noyau, dans une machine qui n'a pas la taille de la référence.
///
/// C'est la seule preuve qui compte pour un réglage de mémoire : le DTB peut
/// annoncer ce qu'on veut, seul le noyau dit s'il l'a cru. Il imprime la
/// quantité qu'il a trouvée dans son propre journal — « Memory: … » — donc on
/// n'a pas à le deviner.
final class ResizedBootTests: XCTestCase {
    private static func imageURL() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["WISQ_LINUX_IMAGE"],
            "/tmp/wisq-test-linux-image/Image",
        ]
        for case let path? in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Une machine de 128 Mo démarre, et le noyau annonce plus de mémoire que
    /// dans une machine de 64 Mo. Les deux moitiés comptent : sans la première
    /// le réglage casse le démarrage, sans la seconde il ne fait rien.
    func testALargerMachineBootsAndTheKernelSeesTheExtraMemory() throws {
        guard let url = Self.imageURL() else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: url)

        func totalMemoryLine(ramSize: UInt32) throws -> String {
            let console = LinuxBootTests.ConsoleCapture()
            let machine = LinuxMachine(ramSize: ramSize) { console.append($0) }
            try machine.load(kernelImage: image)
            _ = machine.run(instructionBudget: 60_000_000)
            let output = console.text()
            XCTAssertTrue(
                output.contains("Linux version"),
                "\(ramSize >> 20) Mo : le noyau doit démarrer; sortie: \(output.prefix(400))")
            // « Memory: 126348K/131056K available » — on garde la ligne
            // entière, c'est elle qui porte le nombre que le noyau a cru.
            //
            // Le séparateur est mesuré, pas supposé : la console du noyau
            // termine ses lignes par CRLF, et en Swift la paire « \r\n » est
            // *un seul* Character. Un `split(separator: "\n")` rendait donc
            // une seule tranche contenant tout le journal, et le premier
            // `contains("Memory:")` tombait dessus — le test passait en lisant
            // la bannière de version au lieu de la ligne cherchée. Compté sur
            // ce noyau : 47 sauts de ligne, 0 « \n » au sens des Characters.
            guard let line = output.split(whereSeparator: \.isNewline).first(where: {
                $0.contains("Memory:") && $0.contains("available")
            }) else {
                XCTFail("\(ramSize >> 20) Mo : ligne « Memory: » absente; sortie: \(output.prefix(800))")
                return ""
            }
            return String(line)
        }

        let small = try totalMemoryLine(ramSize: LinuxMachine.defaultRAMSize)
        let large = try totalMemoryLine(ramSize: 128 << 20)
        XCTAssertNotEqual(
            small, large,
            "le noyau doit voir deux quantités différentes : sinon le DTB n'a rien annoncé")

        // Et dans le bon sens. Le premier nombre de la ligne est le total en
        // kibioctets, suivi de « K/ ».
        func totalKilobytes(_ line: String) -> Int? {
            guard let range = line.range(of: #"(\d+)K/"#, options: .regularExpression) else {
                return nil
            }
            return Int(line[range].dropLast(2))
        }
        guard let smallTotal = totalKilobytes(small), let largeTotal = totalKilobytes(large) else {
            return XCTFail("total illisible dans « \(small) » ou « \(large) »")
        }
        XCTAssertGreaterThan(
            largeTotal, smallTotal,
            "128 Mo doit donner plus de mémoire disponible que 64 Mo")
    }
}

/// La plus grande machine que l'architecture permet, démarrée pour de vrai.
///
/// Deux gibioctets est le dernier octet qu'un processeur 32 bits peut adresser
/// quand la RAM commence à 0x8000_0000. Ce n'est pas une taille théorique : le
/// noyau y arrive jusqu'à son invite de connexion.
///
/// Le budget est la mesure qui compte ici. À 64 Mo l'invite arrive vers
/// 46 millions d'instructions ; à 2 Gio il en faut environ 120, parce que
/// Linux passe la différence à initialiser ses pages. Un test qui aurait gardé
/// le budget de 60 millions aurait conclu « 2 Gio ne démarre pas », ce qui est
/// faux — et c'est exactement ce que la première mesure a d'abord semblé dire.
final class LargestMachineBootTests: XCTestCase {
    func testTheLargestMachineTheArchitectureAllowsReachesItsLoginPrompt() throws {
        let candidates = [
            ProcessInfo.processInfo.environment["WISQ_LINUX_IMAGE"],
            "/tmp/wisq-test-linux-image/Image",
        ]
        guard let path = candidates.compactMap({ $0 })
            .first(where: { FileManager.default.fileExists(atPath: $0) })
        else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: URL(fileURLWithPath: path))

        let console = LinuxBootTests.ConsoleCapture()
        let machine = LinuxMachine(ramSize: LinuxMachine.maximumRAMSize) { console.append($0) }
        try machine.load(kernelImage: image)

        var reached = false
        for _ in 1...4 where !reached {
            _ = machine.run(instructionBudget: 60_000_000)
            reached = console.text().contains("buildroot login:")
        }
        let output = console.text()
        XCTAssertTrue(reached, "2 Gio doit arriver à l'invite; fin: \(output.suffix(300))")
        XCTAssertTrue(
            output.contains("2075628K/2097136K"),
            "le noyau doit annoncer 2 Gio moins la réserve; sortie: \(output.prefix(600))")
    }
}
