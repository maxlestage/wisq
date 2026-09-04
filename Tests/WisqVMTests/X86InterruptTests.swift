import XCTest

@testable import WisqVM

/// La livraison d'exception, et ce dont elle dépend.
///
/// **Pourquoi elle existe.** Le décompresseur 64 bits de Linux ne cartographie
/// pas la mémoire d'avance : il pose une IDT dont un seul vecteur est rempli —
/// le quatorze, la faute de page — et étend l'identité à la demande depuis ce
/// gestionnaire, à mesure qu'il écrit le noyau décompressé. Un cœur sans
/// livraison d'exception s'arrête donc sur la première page manquante, et
/// l'arrêt ressemble à une divergence alors que c'est le fonctionnement prévu.
///
/// Ces tests ne sont pas contre le processeur : l'oracle matériel de
/// `X86OracleTests` ne peut pas produire une faute sans tuer son harnais. Ils
/// sont écrits à la main, contre le manuel, et chacun nomme ce qu'il tient.
final class X86InterruptTests: XCTestCase {
    /// Les quatre tables, et une identité page par page sur ce qu'on demande.
    /// Tout tient dans les deux premiers mébioctets, donc une seule table de
    /// dernier niveau suffit — et c'est elle que le gestionnaire du test de
    /// bout en bout ira compléter.
    static func map(_ ram: X86Memory, _ pages: [UInt64]) throws {
        try ram.write(0x2000, 8, 0x3000 | X86Core.present | 2)
        try ram.write(0x3000, 8, 0x4000 | X86Core.present | 2)
        try ram.write(0x4000, 8, 0x5000 | X86Core.present | 2)
        for page in pages {
            try ram.write(0x5000 &+ ((page >> 12) & 0x1FF) * 8, 8, page | X86Core.present | 2)
        }
    }

    /// Les pages que tous ces tests cartographient. **0xB000 n'y est pas** :
    /// c'est celle sur laquelle on faute.
    static let mapped: [UInt64] = [
        0x1000, 0x2000, 0x3000, 0x4000, 0x5000, 0x6000, 0x8000, 0x9000, 0xA000,
    ]
    static let idt: UInt64 = 0x9000
    static let handler: UInt64 = 0x8000
    static let stackTop: UInt64 = 0x7000
    /// L'adresse fautive, **volontairement pas alignée** : CR2 doit porter
    /// l'octet visé, pas sa page.
    static let missing: UInt64 = 0xB123

    /// Une porte d'interruption : le décalage en trois morceaux, comme sur la
    /// machine.
    static func installGate(
        _ ram: X86Memory, vector: Int, target: UInt64,
        selector: UInt16 = 0x10, kind: UInt8 = 0x8E
    ) throws {
        let low = (target & 0xFFFF) | (UInt64(selector) << 16)
            | (UInt64(kind) << 40) | ((target & 0xFFFF_0000) << 32)
        try ram.write(idt &+ UInt64(vector) * 16, 8, low)
        try ram.write(idt &+ UInt64(vector) * 16 &+ 8, 8, (target >> 32) & 0xFFFF_FFFF)
    }

    /// Un cœur en mode long, pagination allumée, prêt à exécuter le code posé
    /// à 0x1000.
    static func core(_ ram: X86Memory, code: [UInt8], limit: UInt64 = 0x1FF) throws -> X86Core {
        try ram.load(code, at: 0x1000)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x1000, memory: ram)
        core.system.control[3] = 0x2000
        core.system.control[4] = X86SystemState.physicalAddressExtension
        core.system.modelSpecific[X86SystemState.efer] = X86SystemState.longModeEnable
        core.system.control[0] = X86SystemState.paging | X86SystemState.protectedMode
        core.system.refreshLongMode()
        core.pagingActive = true
        core.registers[4] = stackTop
        core.descriptorBases[1] = idt
        core.descriptorLimits[1] = limit
        return core
    }

    static func prepared(code: [UInt8]) throws -> (X86Memory, X86Core) {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try map(ram, mapped)
        try installGate(ram, vector: 14, target: handler)
        try ram.load([0xF4], at: handler)
        return (ram, try core(ram, code: code))
    }

    // MARK: - Le cadre

    /// Le cadre du mode long, case par case. En haut SS, puis RSP, RFLAGS, CS,
    /// l'adresse de reprise, et tout en bas le code d'erreur — c'est cet ordre
    /// que le gestionnaire de Linux défait, et une case de travers le fait
    /// repartir n'importe où.
    func testTheStackFrameIsTheOneAHandlerExpects() throws {
        // `88 03` : mov %al,(%rbx) — une écriture, sur une page absente.
        let (ram, base) = try Self.prepared(code: [0x88, 0x03])
        var core = base
        core.registers[3] = Self.missing
        core.segments[1] = 0x08
        core.segments[2] = 0x18
        let before = core.flags
        try core.run(budget: 1)

        XCTAssertEqual(core.rip, Self.handler, "la reprise doit être dans le gestionnaire")
        XCTAssertEqual(core.segments[1], 0x10, "CS vient du sélecteur de la porte")
        // Six cases de huit octets, depuis une pile alignée sur seize.
        let pointer = Self.stackTop - 48
        XCTAssertEqual(core.registers[4], pointer)
        XCTAssertEqual(try ram.read(pointer, 8), 2, "code d'erreur : absente, en écriture")
        XCTAssertEqual(try ram.read(pointer + 8, 8), 0x1000,
                       "l'adresse empilée est celle de l'instruction **fautive**")
        XCTAssertEqual(try ram.read(pointer + 16, 8), 0x08, "l'ancien CS")
        XCTAssertEqual(try ram.read(pointer + 24, 8), before | X86Core.Flag.reserved)
        XCTAssertEqual(try ram.read(pointer + 32, 8), Self.stackTop, "l'ancien RSP")
        XCTAssertEqual(try ram.read(pointer + 40, 8), 0x18, "l'ancien SS")
    }

    /// CR2 porte l'adresse **entière**. L'arrondir à la page passerait presque
    /// partout — un gestionnaire qui cartographie arrondit lui-même — et
    /// cacherait l'octet visé à tous les autres.
    func testCR2CarriesTheWholeAddress() throws {
        let (_, base) = try Self.prepared(code: [0x88, 0x03])
        var core = base
        core.registers[3] = Self.missing
        try core.run(budget: 1)
        XCTAssertEqual(core.system.control[2], Self.missing)
    }

    /// Le code d'erreur dit ce que l'accès venait faire. Le décompresseur de
    /// Linux **refuse** ceux qu'il ne reconnaît pas — un bit de présence ou
    /// d'utilisateur posé à tort l'arrête net — donc ces trois valeurs ne sont
    /// pas décoratives.
    func testTheErrorCodeSaysWhatTheAccessWas() throws {
        // Lecture : `8a 03` mov (%rbx),%al.
        let (readRAM, readBase) = try Self.prepared(code: [0x8A, 0x03])
        var reading = readBase
        reading.registers[3] = Self.missing
        try reading.run(budget: 1)
        XCTAssertEqual(try readRAM.read(reading.registers[4], 8), 0, "une lecture : aucun bit")

        // Écriture.
        let (writeRAM, writeBase) = try Self.prepared(code: [0x88, 0x03])
        var writing = writeBase
        writing.registers[3] = Self.missing
        try writing.run(budget: 1)
        XCTAssertEqual(try writeRAM.read(writing.registers[4], 8), 1 << 1, "une écriture")

        // Lecture d'instruction : RIP lui-même sur la page absente.
        let (fetchRAM, fetchBase) = try Self.prepared(code: [0x90])
        var fetching = fetchBase
        fetching.rip = 0xB000
        try fetching.run(budget: 1)
        XCTAssertEqual(try fetchRAM.read(fetching.registers[4], 8), 1 << 4,
                       "une lecture d'instruction")
        XCTAssertEqual(fetching.system.control[2], 0xB000)
    }

    /// La pile du cadre est alignée sur seize octets, et l'ancien RSP est
    /// quand même rendu tel quel. C'est le mode long qui l'exige ; le 32 bits
    /// ne le faisait pas, et un cœur qui l'oublie décale le cadre de tout
    /// gestionnaire qui s'aligne.
    func testTheFrameIsAlignedButTheOldPointerIsNot() throws {
        let (ram, base) = try Self.prepared(code: [0x88, 0x03])
        var core = base
        core.registers[3] = Self.missing
        core.registers[4] = Self.stackTop - 4
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[4] % 16, 0, "le cadre part d'une pile alignée")
        XCTAssertEqual(core.registers[4], Self.stackTop - 16 - 48)
        XCTAssertEqual(try ram.read(core.registers[4] + 32, 8), Self.stackTop - 4,
                       "et l'ancien RSP est rendu sans arrondi")
    }

    /// Une porte d'interruption masque les interruptions en entrant ; une porte
    /// de trappe les laisse. Les deux existent, et Linux se sert de la
    /// première.
    func testAnInterruptGateMasksAndATrapGateDoesNot() throws {
        for (kind, masked) in [(UInt8(0x8E), true), (UInt8(0x8F), false)] {
            let ram = X86Memory(size: 1 << 20, base: 0)
            try Self.map(ram, Self.mapped)
            try Self.installGate(ram, vector: 14, target: Self.handler, kind: kind)
            try ram.load([0xF4], at: Self.handler)
            var core = try Self.core(ram, code: [0x88, 0x03])
            core.registers[3] = Self.missing
            core.flags |= X86Core.Flag.interrupt
            try core.run(budget: 1)
            XCTAssertEqual(core.flags & X86Core.Flag.interrupt == 0, masked,
                           "porte 0x\(String(kind, radix: 16))")
        }
    }

    // MARK: - Ce qui n'est pas livré

    /// Sans IDT, la faute **sort**. Un cœur qui avalerait une faute qu'il ne
    /// sait pas livrer mentirait sur ce qu'il fait, et la tentative de
    /// démarrage ne dirait plus où elle s'arrête.
    func testWithoutAnIDTTheFaultComesOut() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try Self.map(ram, Self.mapped)
        var core = try Self.core(ram, code: [0x88, 0x03], limit: 0)
        core.descriptorBases[1] = 0
        core.registers[3] = Self.missing
        XCTAssertThrowsError(try core.run(budget: 1)) {
            XCTAssertEqual($0 as? X86Core.Fault, .pageFault(Self.missing))
        }
    }

    /// Une porte dont le bit de présence est à zéro n'en est pas une. C'est
    /// l'état d'une IDT que le noyau a réservée sans encore la remplir — et
    /// c'est exactement le cas des trente et un autres vecteurs du
    /// décompresseur.
    func testAnAbsentGateIsNotDelivered() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try Self.map(ram, Self.mapped)
        try Self.installGate(ram, vector: 14, target: Self.handler, kind: 0x0E)
        var core = try Self.core(ram, code: [0x88, 0x03])
        core.registers[3] = Self.missing
        XCTAssertThrowsError(try core.run(budget: 1))
    }

    /// La limite est le dernier octet valide, et une porte doit y tenir
    /// **entièrement**. Une IDT qui s'arrête avant le vecteur quatorze ne le
    /// livre pas, même si les octets qui suivent ressemblent à une porte.
    func testAShortLimitStopsAtTheVectorItCovers() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try Self.map(ram, Self.mapped)
        try Self.installGate(ram, vector: 0, target: Self.handler)
        try Self.installGate(ram, vector: 14, target: Self.handler)
        try ram.load([0xF4], at: Self.handler)

        // Une limite de quinze : le vecteur zéro tient, le quatorze non.
        // `f7 f1` : div %ecx, avec ECX à zéro.
        var dividing = try Self.core(ram, code: [0xF7, 0xF1], limit: 15)
        try dividing.run(budget: 1)
        XCTAssertEqual(dividing.rip, Self.handler, "le vecteur zéro est couvert")

        var faulting = try Self.core(ram, code: [0x88, 0x03], limit: 15)
        faulting.registers[3] = Self.missing
        XCTAssertThrowsError(try faulting.run(budget: 1), "le vecteur quatorze ne l'est pas")
    }

    /// Une forme que ce cœur ne sait pas exécuter n'a **pas** de vecteur. La
    /// livrer comme #UD ferait croire au noyau que son propre code est
    /// invalide : il afficherait un « invalid opcode » à l'endroit d'un trou
    /// de l'émulateur, ce qui coûte plus cher que l'arrêt.
    func testAnUnimplementedFormIsNotDeliveredAsAnException() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try Self.map(ram, Self.mapped)
        for vector in 0..<32 { try Self.installGate(ram, vector: vector, target: Self.handler) }
        try ram.load([0xF4], at: Self.handler)
        // `0f 6f` : MMX, que ce cœur ne connaît pas.
        var core = try Self.core(ram, code: [0x0F, 0x6F, 0xC1])
        XCTAssertThrowsError(try core.run(budget: 1)) {
            guard case .some(X86Core.Fault.unsupported) = $0 as? X86Core.Fault else {
                return XCTFail("attendu : un refus nommé, pas une exception livrée")
            }
        }
    }

    // MARK: - Le retour

    /// Une division par zéro part au vecteur zéro, et **sans** code d'erreur :
    /// les dix vecteurs qui en portent un sont nommés par l'architecture, et
    /// en ajouter un décale le cadre du gestionnaire.
    func testADivideErrorCarriesNoErrorCode() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try Self.map(ram, Self.mapped)
        try Self.installGate(ram, vector: 0, target: Self.handler)
        try ram.load([0xF4], at: Self.handler)
        var core = try Self.core(ram, code: [0xF7, 0xF1])
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[4], Self.stackTop - 40, "cinq cases, pas six")
        XCTAssertEqual(try ram.read(core.registers[4], 8), 0x1000,
                       "en haut de la pile : l'adresse de reprise, pas un code d'erreur")
    }

    /// Le tour complet, et c'est celui dont Linux dépend : la faute part au
    /// gestionnaire, le gestionnaire complète la table, `IRETQ` revient, et
    /// **l'instruction fautive s'exécute enfin**.
    ///
    /// Sans le rejeu, le noyau écrirait dans le vide et continuerait ; c'est la
    /// forme de panne la plus difficile à voir, parce que rien ne s'arrête.
    func testTheHandlerMapsThePageAndTheInstructionRunsAgain() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try Self.map(ram, Self.mapped)
        try Self.installGate(ram, vector: 14, target: Self.handler)
        // Le gestionnaire, dans la forme de celui de Linux : compter son
        // entrée, empiler, poser l'entrée manquante dans la table de dernier
        // niveau, dépiler, retirer le code d'erreur, revenir.
        //
        // **Le compteur en premier n'est pas décoratif.** C'est lui qui tient
        // le défaut qui a existé ici : la livraison posait le drapeau qu'un
        // branchement utilise pour dire « RIP est déjà où il faut », et la
        // première instruction du gestionnaire le trouvait encore posé — donc
        // elle s'exécutait **deux fois**. Chez Linux c'est un `push`, et les
        // huit octets de trop faisaient repartir l'`IRETQ` sur le code
        // d'erreur : le noyau sautait à 0x2. Une première instruction
        // idempotente ne l'aurait pas vu.
        //   ff 04 25 00 a0 00 00                  incl 0xa000
        //   50                                    push %rax
        //   48 c7 04 25 58 50 00 00 01 b0 00 00   movq $0xb001,0x5058
        //   58                                    pop  %rax
        //   48 83 c4 08                           add  $8,%rsp
        //   48 cf                                 iretq
        try ram.load([0xFF, 0x04, 0x25, 0x00, 0xA0, 0x00, 0x00,
                      0x50,
                      0x48, 0xC7, 0x04, 0x25, 0x58, 0x50, 0x00, 0x00, 0x01, 0xB0, 0x00, 0x00,
                      0x58,
                      0x48, 0x83, 0xC4, 0x08,
                      0x48, 0xCF], at: Self.handler)
        // `88 03` puis `f4` : écrire, puis s'arrêter.
        var core = try Self.core(ram, code: [0x88, 0x03, 0xF4])
        core.registers[0] = 0x5A
        core.registers[3] = Self.missing
        core.segments[1] = 0x08
        core.segments[2] = 0x18
        let flags = core.flags

        try core.run(budget: 100)

        XCTAssertTrue(core.halted, "le HLT qui suit l'écriture doit être atteint")
        XCTAssertEqual(try ram.read(0xA000, 4), 1,
                       "la première instruction du gestionnaire s'exécute une fois, pas deux")
        XCTAssertEqual(try ram.read(Self.missing, 1), 0x5A,
                       "l'instruction fautive doit s'être exécutée pour de bon")
        XCTAssertEqual(core.registers[4], Self.stackTop, "la pile est revenue où elle était")
        XCTAssertEqual(core.segments[1], 0x08, "IRETQ rend l'ancien CS")
        XCTAssertEqual(core.segments[2], 0x18, "et l'ancien SS")
        XCTAssertEqual(core.flags, flags | X86Core.Flag.reserved, "et les anciens drapeaux")
        XCTAssertEqual(core.system.control[2], Self.missing, "CR2 garde la dernière faute")
    }

    /// `IRETQ` dépile cinq cases, et le code d'erreur n'en fait **pas** partie
    /// — c'est au gestionnaire de l'enlever, et Linux le fait. Le dépiler ici
    /// sauterait deux fois la même case.
    func testIRETQLeavesTheErrorCodeToTheHandler() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try Self.map(ram, Self.mapped)
        // Un cadre posé à la main, code d'erreur compris.
        let pointer = Self.stackTop - 48
        for (index, value) in [UInt64(7), 0x1234, 0x08, X86Core.Flag.carry | X86Core.Flag.reserved,
                               Self.stackTop, 0x18].enumerated() {
            try ram.write(pointer + UInt64(index) * 8, 8, value)
        }
        // `48 cf` : iretq, exécuté avec RSP sur l'adresse de reprise — donc
        // huit octets au-dessus du code d'erreur, comme après le `add $8,%rsp`
        // du gestionnaire.
        var core = try Self.core(ram, code: [0x48, 0xCF])
        core.registers[4] = pointer + 8
        try core.run(budget: 1)
        XCTAssertEqual(core.rip, 0x1234)
        XCTAssertEqual(core.segments[1], 0x08)
        XCTAssertEqual(core.flags, X86Core.Flag.carry | X86Core.Flag.reserved)
        XCTAssertEqual(core.registers[4], Self.stackTop)
        XCTAssertEqual(core.segments[2], 0x18)
    }

    // MARK: - Les tables de descripteurs

    /// `LIDT` **recopie** le pseudo-descripteur, il ne retient pas son adresse.
    /// La première version notait l'adresse de l'opérande, ce qui suffisait
    /// tant que rien ne s'en servait ; la livraison s'en sert, et un noyau qui
    /// réutilise ces dix octets ensuite ferait alors livrer n'importe quoi.
    func testLIDTCopiesTheDescriptorRatherThanRememberingWhereItWas() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try Self.map(ram, Self.mapped)
        try ram.write(0xA000, 2, 0x1FF)
        try ram.write(0xA002, 8, Self.idt)
        // `0f 01 1c 25 00 a0 00 00` : lidt 0xa000 — puis on écrase les dix
        // octets, et `0f 01 0c 25 20 a0 00 00` : sidt 0xa020.
        var core = try Self.core(ram, code: [
            0x0F, 0x01, 0x1C, 0x25, 0x00, 0xA0, 0x00, 0x00,
            0x0F, 0x01, 0x0C, 0x25, 0x20, 0xA0, 0x00, 0x00,
        ], limit: 0)
        core.descriptorBases[1] = 0
        try core.run(budget: 1)
        try ram.write(0xA000, 2, 0)
        try ram.write(0xA002, 8, 0xDEAD)
        try core.run(budget: 1)

        XCTAssertEqual(core.descriptorLimits[1], 0x1FF)
        XCTAssertEqual(core.descriptorBases[1], Self.idt)
        XCTAssertEqual(try ram.read(0xA020, 2), 0x1FF, "SIDT rend la limite")
        XCTAssertEqual(try ram.read(0xA022, 8), Self.idt, "et la base, dans la même forme")
    }

    /// **Le bit qui dit que la faute vient d'un programme.** Linux s'en sert
    /// pour trancher entre « une page manque à un programme, je la lui pose »
    /// et « le noyau est parti dans le décor, j'affiche un oops ».
    ///
    /// Sans lui, la toute première page manquante de `/init` a été prise pour
    /// un défaut du noyau lui-même : `Oops: 0010`, un vidage de registres, et
    /// `Attempted to kill init!`. Le programme n'avait rien fait de mal ; on
    /// avait juste oublié de dire qu'il était le programme. Le niveau vient
    /// des deux bits du bas de CS, et de rien d'autre.
    func testTheErrorCodeSaysWhenTheFaultCameFromAProgram() throws {
        for (selector, user) in [(UInt16(0x10), false), (UInt16(0x33), true)] {
            let (ram, base) = try Self.prepared(code: [0x8A, 0x03])  // une lecture
            var core = base
            core.registers[3] = Self.missing
            core.segments[1] = selector
            try core.run(budget: 1)
            let code = try ram.read(core.registers[4], 8)
            XCTAssertEqual(code & (1 << 2) != 0, user,
                           "sélecteur 0x\(String(selector, radix: 16))")
        }
    }
}
