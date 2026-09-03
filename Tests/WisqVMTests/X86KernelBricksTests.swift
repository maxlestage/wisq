import XCTest

@testable import WisqVM

/// Les briques que le vrai noyau a demandées, une par une.
///
/// Aucune n'a été choisie sur une liste : chacune est l'instruction sur
/// laquelle `X86BootAttemptTests` s'est arrêté, écrite parce que le noyau
/// d'Alpine la voulait pour continuer. C'est pour ça qu'elles sont ensemble
/// ici plutôt que rangées par famille.
///
/// L'oracle matériel en tient déjà deux — `CMPXCHG` et `XADD` sont exécutées
/// par le vrai processeur dans `Tests/Fixtures/x86-oracle.tsv`. Ce qui reste
/// ici, c'est ce qu'il ne peut pas atteindre : les bases de segment vivent
/// dans des MSR, et le harnais n'en écrit pas.
final class X86KernelBricksTests: XCTestCase {
    static func core(_ ram: X86Memory, _ code: [UInt8], at rip: UInt64 = 0x100) throws -> X86Core {
        try ram.load(code, at: rip)
        return X86Core(registers: [UInt64](repeating: 0, count: 16), rip: rip, memory: ram)
    }

    // MARK: - Les bases de FS et GS

    /// `%gs:` ajoute la base que le MSR porte. C'est **le** mécanisme des
    /// variables par processeur d'un noyau x86-64 : sans lui, un accès
    /// `%gs:0x1234` lit l'adresse 0x1234, c'est-à-dire le début de la mémoire,
    /// où il n'y a rien de ce qu'on cherchait — et sans jamais rien signaler.
    func testAGSPrefixAddsTheBaseFromItsMSR() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try ram.write(0x3000, 8, 0xDEAD_BEEF_CAFE)
        // `65 48 8b 04 25 00 10 00 00` : mov %gs:0x1000,%rax
        var core = try Self.core(ram, [0x65, 0x48, 0x8B, 0x04, 0x25, 0x00, 0x10, 0x00, 0x00])
        core.system.modelSpecific[X86SystemState.gsBase] = 0x2000
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[0], 0xDEAD_BEEF_CAFE)
    }

    /// Et `%fs:` la sienne, qui n'est pas la même. Les confondre marcherait
    /// tant qu'une seule est posée.
    func testAnFSPrefixReadsItsOwnBase() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try ram.write(0x5000, 8, 0x1234)
        try ram.write(0x3000, 8, 0x5678)
        // `64 48 8b 04 25 00 10 00 00` : mov %fs:0x1000,%rax
        var core = try Self.core(ram, [0x64, 0x48, 0x8B, 0x04, 0x25, 0x00, 0x10, 0x00, 0x00])
        core.system.modelSpecific[X86SystemState.fsBase] = 0x4000
        core.system.modelSpecific[X86SystemState.gsBase] = 0x2000
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[0], 0x1234, "la base de FS, pas celle de GS")
    }

    /// Sans préfixe, rien n'est ajouté — même quand les MSR sont pleins. En
    /// mode long, ES, CS, SS et DS ont une base forcée à zéro.
    func testWithoutAPrefixNoBaseIsAdded() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try ram.write(0x1000, 8, 0x99)
        var core = try Self.core(ram, [0x48, 0x8B, 0x04, 0x25, 0x00, 0x10, 0x00, 0x00])
        core.system.modelSpecific[X86SystemState.gsBase] = 0x2000
        core.system.modelSpecific[X86SystemState.fsBase] = 0x4000
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[0], 0x99)
    }

    /// La forme que le noyau emploie vraiment : relative à RIP, avec `%gs:`.
    /// Les deux calculs se composent, et rien dans le code ne dit lequel vient
    /// en premier tant qu'un test ne le fixe pas.
    func testTheBaseAppliesToARIPRelativeAddressToo() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // `65 48 8b 05 00 10 00 00` : mov %gs:0x1000(%rip),%rax — huit octets,
        // donc l'adresse est base + 0x100 + 8 + 0x1000.
        var core = try Self.core(ram, [0x65, 0x48, 0x8B, 0x05, 0x00, 0x10, 0x00, 0x00])
        core.system.modelSpecific[X86SystemState.gsBase] = 0x2000
        try ram.write(0x2000 + 0x100 + 8 + 0x1000, 8, 0x4242)
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[0], 0x4242)
    }

    /// Et à une adresse prise dans un registre, qui est le troisième des trois
    /// chemins de calcul.
    func testTheBaseAppliesToARegisterAddressToo() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try ram.write(0x2500, 8, 0x7777)
        // `65 48 8b 03` : mov %gs:(%rbx),%rax
        var core = try Self.core(ram, [0x65, 0x48, 0x8B, 0x03])
        core.registers[3] = 0x500
        core.system.modelSpecific[X86SystemState.gsBase] = 0x2000
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[0], 0x7777)
    }

    /// `SWAPGS` échange la base de GS avec celle que le noyau garde de côté.
    /// C'est ce qu'il exécute à chaque entrée et à chaque sortie de l'espace
    /// utilisateur ; deux fois de suite doit rendre l'état de départ.
    func testSWAPGSExchangesTheTwoBases() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0x0F, 0x01, 0xF8, 0x0F, 0x01, 0xF8])
        core.system.modelSpecific[X86SystemState.gsBase] = 0xAAAA
        core.system.modelSpecific[X86SystemState.kernelGSBase] = 0xBBBB
        try core.run(budget: 1)
        XCTAssertEqual(core.system.modelSpecific[X86SystemState.gsBase], 0xBBBB)
        XCTAssertEqual(core.system.modelSpecific[X86SystemState.kernelGSBase], 0xAAAA)
        try core.run(budget: 1)
        XCTAssertEqual(core.system.modelSpecific[X86SystemState.gsBase], 0xAAAA,
                       "deux échanges rendent l'état de départ")
    }

    // MARK: - Ce qui ne fait rien, et doit quand même être là

    /// `ENDBR64` est la balise de CET. Sur un processeur qui n'annonce pas la
    /// technologie — et celui-ci ne l'annonce pas — c'est un NOP. Le noyau en
    /// pose une à l'entrée de **chaque** fonction : la refuser l'arrête à sa
    /// toute première instruction, ce qui est exactement ce qui arrivait.
    func testENDBR64IsANoOpOfFourBytes() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xF3, 0x0F, 0x1E, 0xFA, 0xF4])
        core.registers[0] = 0x1234
        try core.run(budget: 2)
        XCTAssertTrue(core.halted, "le HLT qui suit doit être atteint")
        XCTAssertEqual(core.registers[0], 0x1234, "et rien ne doit avoir bougé")
        XCTAssertEqual(core.retired, 2)
    }

    /// `PREFETCH` et les NOP réservés du groupe 16 : des indices pour un cache
    /// que ce cœur n'a pas.
    func testPrefetchDoesNothingAndDoesNotRefuse() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // `0f 18 0f` : prefetchnta (%rdi), avec RDI hors de la mémoire — ce qui
        // prouve au passage qu'aucun accès n'a lieu.
        var core = try Self.core(ram, [0x0F, 0x18, 0x0F, 0xF4])
        core.registers[7] = 0xFFFF_FFFF_0000
        try core.run(budget: 2)
        XCTAssertTrue(core.halted)
    }

    /// Les registres de débogage font l'aller-retour. Le noyau les remet à
    /// zéro dès son démarrage et n'en attend rien d'autre ; les refuser
    /// l'arrêterait pour un registre dont il ne lit jamais l'effet.
    func testTheDebugRegistersRoundTrip() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // `0f 23 c1` : mov %rcx,%dr0 — puis `0f 21 c2` : mov %dr0,%rdx.
        var core = try Self.core(ram, [0x0F, 0x23, 0xC1, 0x0F, 0x21, 0xC2])
        core.registers[1] = 0xFEED_FACE
        try core.run(budget: 2)
        XCTAssertEqual(core.system.debug[0], 0xFEED_FACE)
        XCTAssertEqual(core.registers[2], 0xFEED_FACE)
    }

    /// `INVLPG` vide le cache de traduction. Ce cache-ci n'est pas assez fin
    /// pour n'oublier qu'une page, donc il oublie tout : plus lent, jamais
    /// faux. L'inverse — n'oublier qu'une page qu'on ne sait pas retrouver —
    /// serait le contraire.
    func testINVLPGForgetsWhatWasCached() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        let virtual: UInt64 = 0x10_0000
        for (depth, table) in [0x2000, 0x3000, 0x4000, 0x5000].enumerated() {
            let shift = UInt64(39 - 9 * depth)
            let index = (virtual >> shift) & 0x1FF
            let target: UInt64 = depth == 3 ? 0x8_0000 : UInt64([0x3000, 0x4000, 0x5000][depth])
            try ram.write(UInt64(table) + index * 8, 8, target | X86Core.present)
        }
        // La page du code, pour que RIP se traduise.
        for (depth, table) in [0x2000, 0x3000, 0x4000, 0x5000].enumerated() {
            let shift = UInt64(39 - 9 * depth)
            let index = (UInt64(0x100) >> shift) & 0x1FF
            let target: UInt64 = depth == 3 ? 0 : UInt64([0x3000, 0x4000, 0x5000][depth])
            try ram.write(UInt64(table) + index * 8, 8, target | X86Core.present)
        }
        // `0f 01 3c 25 00 00 10 00` : invlpg 0x100000
        var core = try Self.core(ram, [0x0F, 0x01, 0x3C, 0x25, 0x00, 0x00, 0x10, 0x00])
        core.system.control[3] = 0x2000
        core.system.control[0] |= X86SystemState.paging
        core.pagingActive = true
        XCTAssertEqual(try core.translate(virtual), 0x8_0000)
        // On déplace la page **sans** le dire, puis on le dit.
        try ram.write(0x5000 + ((virtual >> 12) & 0x1FF) * 8, 8, 0x9_0000 | X86Core.present)
        XCTAssertEqual(try core.translate(virtual), 0x8_0000, "le cache répond encore l'ancienne")
        try core.run(budget: 1)
        XCTAssertEqual(try core.translate(virtual), 0x9_0000)
    }

    // MARK: - L'octet haut, lu par une instruction plus large que lui

    /// `0F B6 C5`, c'est-à-dire `movzbl %ch,%eax` : **sans REX**, l'index 101
    /// de l'opérande r/m désigne CH, pas BPL. Une instruction peut avoir deux
    /// largeurs, et c'est celle de **l'opérande lu** qui décide — pas celle du
    /// destinataire.
    ///
    /// Ce défaut-là a coûté un noyau : le décompresseur de Linux s'en sert
    /// pour construire le motif de seize bits avec lequel il remplit les
    /// suites d'octets identiques, et l'octet faux se retrouvait une fois sur
    /// deux dans le noyau décompressé. L'oracle matériel le tient désormais
    /// aussi, sur les vingt-quatre formes de MOVZX et MOVSX à octet haut.
    func testMOVZXReadsAHighByteWhenThereIsNoREX() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0x0F, 0xB6, 0xC5])
        core.registers[1] = 0x1234  // CH vaut 0x12
        core.registers[5] = 0xAABB  // RBP, que la lecture ne doit pas toucher
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[0], 0x12, "CH, pas BPL")
    }

    /// Et **avec** REX, le même champ désigne BPL. C'est le même octet de
    /// ModRM qui nomme deux registres selon un préfixe qui se trouve ailleurs
    /// dans l'instruction.
    func testTheSameFieldMeansBPLWhenThereIsAREX() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0x40, 0x0F, 0xB6, 0xC5])
        core.registers[1] = 0x1234
        core.registers[5] = 0xAABB  // BPL vaut 0xBB
        try core.run(budget: 1)
        XCTAssertEqual(core.registers[0], 0xBB, "BPL, pas CH")
    }
}
