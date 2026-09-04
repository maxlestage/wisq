import XCTest

@testable import WisqVM

/// Ce que le noyau pose sur la pile d'un processus neuf.
///
/// **Pourquoi ce témoin existe.** Cinq corpus matériels ont épuisé le jeu
/// d'instructions : en comptant les mnémoniques du vrai chargeur de l'invité
/// contre eux, il ne reste plus une seule instruction entière non couverte en
/// dehors de `syscall`, `hlt`, `nop`, `pause` et trois préfixes — dont aucun
/// ne calcule. Une instruction mal exécutée n'explique donc plus le fait que
/// `/init` appelle une fonction et atterrisse dans `fork()`.
///
/// Restait ce que la machine **fournit**. Quand `execve` réussit, le noyau
/// construit une pile dont la forme est fixée par l'ABI, et sa dernière partie
/// est le **vecteur auxiliaire** : c'est par lui que le chargeur apprend où
/// sont ses propres tables. Un chargeur qui lit là de mauvaises tables résout
/// contre les mauvais symboles.
///
/// **Le témoin a répondu du premier coup, et la réponse est que ce n'est pas
/// ça.** Sur le vrai noyau, `AT_BASE` vaut `0x7f89e846f000` — exactement la
/// base retrouvée par ailleurs en désassemblant `ld-musl` extrait de
/// l'initramfs. Deux mesures indépendantes, le même nombre. `AT_PHENT` vaut
/// 0x38, la taille d'un en-tête de programme ELF64 ; `AT_PAGESZ` vaut 4096 ;
/// `AT_PHDR` pointe à l'offset 0x40 de l'exécutable, là où sont les en-têtes.
/// La pile initiale est juste.
final class X86ProcessStartTests: XCTestCase {
    static let pml4: UInt64 = 0x2000
    static let pdpt: UInt64 = 0x3000
    static let program: UInt64 = 0x1000
    static let stack: UInt64 = 0x8000

    /// Un cœur en anneau trois avec une pagination d'identité, et une pile
    /// posée comme le noyau la pose.
    static func core(_ words: [UInt64], stack: UInt64 = stack) throws -> X86Core {
        let memory = X86Memory(size: 0x10000, base: 0)
        try memory.load([0x90], at: program)  // nop
        let open = X86Core.present | X86Core.writable | X86Core.userAccessible
        try memory.write(pml4, 8, pdpt | open)
        try memory.write(pdpt, 8, X86Core.present | X86Core.hugePage | open)
        for (index, word) in words.enumerated() {
            let at = stack &+ UInt64(index) * 8
            if at < UInt64(memory.size) { try memory.write(at, 8, word) }
        }
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: program, memory: memory)
        core.system.control[3] = pml4
        core.pagingActive = true
        core.segments[1] = 0x33
        core.canonicalWatchArmed = true
        core.registers[4] = stack
        return core
    }

    /// Une pile initiale telle que l'ABI la décrit : argc, les arguments et
    /// leur NULL, l'environnement et le sien, puis les paires du vecteur.
    static func initialStack(arguments: Int, environment: Int,
                             auxiliary: [(UInt64, UInt64)]) -> [UInt64] {
        var words: [UInt64] = [UInt64(arguments)]
        words += (0..<arguments).map { 0x7000 &+ UInt64($0) }
        words.append(0)
        words += (0..<environment).map { 0x7100 &+ UInt64($0) }
        words.append(0)
        for (type, value) in auxiliary { words += [type, value] }
        return words
    }

    /// Les entrées qu'un vrai noyau pose, dans son ordre, avec les valeurs
    /// mesurées sur le démarrage d'Alpine.
    static let measured: [(UInt64, UInt64)] = [
        (33, 0x7FFD967EB000),  // AT_SYSINFO_EHDR
        (6, 0x1000),           // AT_PAGESZ
        (3, 0x560A008E3040),   // AT_PHDR
        (4, 0x38),             // AT_PHENT
        (5, 0x0C),             // AT_PHNUM
        (7, 0x7F89E846F000),   // AT_BASE
        (9, 0x560A008E9ED1),   // AT_ENTRY
        (0, 0),                // AT_NULL
    ]

    func testTheAuxiliaryVectorIsReadWhereTheAbiPutsIt() throws {
        var core = try Self.core(Self.initialStack(
            arguments: 2, environment: 3, auxiliary: Self.measured))
        _ = try core.run(budget: 1)
        XCTAssertEqual(core.processStarts.count, 1)
        let start = try XCTUnwrap(core.processStarts.first)
        XCTAssertEqual(start.argumentCount, 2)
        XCTAssertEqual(start.stack, Self.stack)
        XCTAssertEqual(start.entry, Self.program)
        XCTAssertEqual(start.addressSpace, Self.pml4)
        XCTAssertEqual(start.auxiliary.count, Self.measured.count)
        for (read, expected) in zip(start.auxiliary, Self.measured) {
            XCTAssertEqual(read.type, expected.0)
            XCTAssertEqual(read.value, expected.1)
        }
    }

    /// **Le compte des arguments et celui de l'environnement décalent tout.**
    /// Un témoin qui les compterait mal lirait le vecteur au mauvais endroit
    /// et rendrait des chiffres plausibles mais faux — le pire des cas pour un
    /// instrument de mesure.
    func testTheCountsShiftTheWholeVector() throws {
        for arguments in [0, 1, 7] {
            for environment in [0, 1, 5] {
                var core = try Self.core(Self.initialStack(
                    arguments: arguments, environment: environment,
                    auxiliary: Self.measured))
                _ = try core.run(budget: 1)
                let start = try XCTUnwrap(core.processStarts.first)
                XCTAssertEqual(start.argumentCount, UInt64(arguments))
                XCTAssertEqual(start.auxiliary.first?.type, 33,
                               "\(arguments) arguments, \(environment) variables")
                XCTAssertEqual(start.auxiliary.last?.type, 0)
            }
        }
    }

    func testAnEntryTheAbiDoesNotNameComesOutAsANumber() throws {
        var core = try Self.core(Self.initialStack(
            arguments: 1, environment: 1, auxiliary: [(27, 0x1C), (0, 0)]))
        _ = try core.run(budget: 1)
        let start = try XCTUnwrap(core.processStarts.first)
        XCTAssertEqual(start.auxiliary.first?.description, "AT_27=1c",
                       "nommer au hasard serait pire que de ne pas nommer")
        XCTAssertEqual(start.auxiliary.last?.description, "AT_NULL=0")
    }

    /// Le même espace d'adressage ne compte qu'une fois : c'est le même
    /// programme, et le relire à chaque instruction n'apprendrait rien.
    func testTheSameAddressSpaceIsNoticedOnlyOnce() throws {
        var core = try Self.core(Self.initialStack(
            arguments: 1, environment: 1, auxiliary: Self.measured))
        try core.memory?.load([0x90, 0x90, 0x90], at: Self.program)
        _ = try core.run(budget: 3)
        XCTAssertEqual(core.processStarts.count, 1)
    }

    func testANewAddressSpaceIsANewProgram() throws {
        var core = try Self.core(Self.initialStack(
            arguments: 1, environment: 1, auxiliary: Self.measured))
        try core.memory?.load([0x90, 0x90], at: Self.program)
        _ = try core.run(budget: 1)
        // Un autre espace d'adressage, avec les mêmes tables : c'est ce qui
        // distingue un processus d'un autre.
        try core.memory?.write(0x4000, 8, Self.pdpt | X86Core.present
            | X86Core.writable | X86Core.userAccessible)
        core.system.control[3] = 0x4000
        core.flushTranslations()
        _ = try core.run(budget: 1)
        XCTAssertEqual(core.processStarts.count, 2)
        XCTAssertEqual(core.processStarts.last?.addressSpace, 0x4000)
    }

    /// Une pile qu'on ne peut pas lire rend un démarrage sans vecteur plutôt
    /// qu'une erreur : un témoin qui lèverait en rendant compte serait pire
    /// que pas de témoin.
    func testAnUnreadableStackIsNotAnError() throws {
        var core = try Self.core([], stack: 0xF_F000)
        XCTAssertNoThrow(try core.run(budget: 1))
        let start = try XCTUnwrap(core.processStarts.first)
        XCTAssertTrue(start.auxiliary.isEmpty)
    }

    func testTheKernelItselfIsNotAProgramStart() throws {
        var core = try Self.core(Self.initialStack(
            arguments: 1, environment: 1, auxiliary: Self.measured))
        core.segments[1] = 0x10  // anneau zéro
        _ = try core.run(budget: 1)
        XCTAssertTrue(core.processStarts.isEmpty)
    }
}
