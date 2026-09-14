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
    static let idt: UInt64 = 0x9000

    /// Une porte d'interruption, dans la forme dispersée du 386.
    static func installGate(_ ram: X86Memory, vector: Int, target: UInt64) throws {
        let low = (target & 0xFFFF) | (UInt64(0x10) << 16)
            | (UInt64(0x8E) << 40) | ((target & 0xFFFF_0000) << 32)
        try ram.write(idt &+ UInt64(vector) * 16, 8, low)
        try ram.write(idt &+ UInt64(vector) * 16 &+ 8, 8, 0)
    }

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

    // MARK: - L'état de la virgule flottante, que le noyau range sans demander

    /// `FXSAVE` écrit une zone de 512 octets — **dont les seize registres
    /// XMM**, et c'est le sens de cette réécriture.
    ///
    /// Ces deux tests disaient, dans leur propre documentation, que ce cœur
    /// n'avait « ni registres x87 ni XMM » et que « rien ici ne calcule en
    /// virgule flottante ». C'était vrai le jour où ils ont été écrits. Le
    /// SSE2 entier, le flottant scalaire et la pile x87 sont entrés dans ce
    /// cœur depuis, et **personne n'est revenu relire la prémisse** — les
    /// tests, eux, continuaient à exiger que la zone soit remplie de zéros,
    /// c'est-à-dire à **tenir le défaut en place**.
    ///
    /// Le prix a été mesuré : `/init` mourait. Le noyau sauve l'état de la
    /// virgule flottante avant de s'en servir et le rend après ; ne rien
    /// sauver et ne rien rendre laisse au programme les registres du noyau.
    ///
    /// Le format vient maintenant du vrai processeur — voir
    /// `X86FloatingPointStateOracleTests`. Ici on tient les trois faits qu'un
    /// test lisible doit porter : les mots de contrôle, les XMM, et le fait
    /// que l'instruction s'arrête à 416 octets.
    func testFXSAVEWritesTheVectorRegistersAndStopsAt416() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // De la garniture, pour voir où l'instruction s'arrête vraiment.
        try ram.load([UInt8](repeating: 0xEE, count: 512), at: 0x2000)
        // `0f ae 06` : fxsave (%rsi)
        var core = try Self.core(ram, [0x0F, 0xAE, 0x06])
        core.registers[6] = 0x2000
        core.x87Control = 0x027F
        core.x87Status = 0x1234
        core.mxcsr = 0x1F80
        core.vectors[2] = 0x7FFC_E0EF_1C90   // xmm1, le registre qui mourait
        core.vectors[3] = 0xFEED_FACE
        try core.run(budget: 1)
        XCTAssertEqual(try ram.read(0x2000, 2), 0x027F, "le mot de contrôle x87")
        XCTAssertEqual(try ram.read(0x2002, 2), 0x1234, "le mot d'état x87")
        XCTAssertEqual(try ram.read(0x2018, 4), 0x1F80, "MXCSR")
        XCTAssertEqual(try ram.read(0x201C, 4), 0xFFFF,
                       "le masque des bits acceptés — zéro voudrait dire aucun")
        XCTAssertEqual(try ram.read(0x2000 + 160 + 16, 8), 0x7FFC_E0EF_1C90,
                       "xmm1, à 160 + 16 — sans lui, `/init` meurt")
        XCTAssertEqual(try ram.read(0x2000 + 160 + 24, 8), 0xFEED_FACE,
                       "et sa moitié haute")
        XCTAssertEqual(try ram.read(0x21A0, 8), 0xEEEE_EEEE_EEEE_EEEE,
                       "l'instruction s'arrête à 416 octets, et c'est mesuré")
    }

    /// Et `FXRSTOR` les relit — **les XMM compris**. L'aller-retour est ce que
    /// le noyau fait à chaque fois qu'il emprunte ces registres.
    ///
    /// Le mot de contrôle revient avec son bit 6 levé : le manuel le dit
    /// « réservé » et n'en promet rien, le processeur le force, et le corpus
    /// l'a montré sur 208 cas d'un coup.
    func testFXRSTORReadsThemBack() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // `0f ae 06` fxsave, puis `0f ae 0e` fxrstor, au même endroit.
        var core = try Self.core(ram, [0x0F, 0xAE, 0x06, 0x0F, 0xAE, 0x0E])
        core.registers[6] = 0x2000
        core.x87Control = 0x0300
        core.mxcsr = 0x1DC0
        core.vectors[2] = 0x7FFC_E0EF_1C90
        try core.run(budget: 1)
        core.x87Control = 0
        core.mxcsr = 0
        core.vectors[2] = 0   // le noyau s'est servi du registre
        try core.run(budget: 1)
        XCTAssertEqual(core.x87Control, 0x0340, "0x0300, et le bit 6 que le processeur force")
        XCTAssertEqual(core.mxcsr, 0x1DC0)
        XCTAssertEqual(core.vectors[2], 0x7FFC_E0EF_1C90, "et xmm1 est rendu")
    }

    /// `STMXCSR` et `LDMXCSR` seuls, sans la zone entière.
    func testMXCSRGoesOutAndComesBack() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // `0f ae 1e` stmxcsr (%rsi) ; `0f ae 16` ldmxcsr (%rsi)
        var core = try Self.core(ram, [0x0F, 0xAE, 0x1E, 0x0F, 0xAE, 0x16])
        core.registers[6] = 0x2000
        core.mxcsr = 0x1F80
        try core.run(budget: 1)
        XCTAssertEqual(try ram.read(0x2000, 4), 0x1F80)
        try ram.write(0x2000, 4, 0x1DC0)
        try core.run(budget: 1)
        XCTAssertEqual(core.mxcsr, 0x1DC0)
    }

    /// **`RDTSCP` ne doit pas échanger la base de GS.**
    ///
    /// Le groupe 7 de `0f 01` range `SWAPGS` sous « reg vaut sept et mod vaut
    /// trois » — sans regarder `rm`. Or `rm` est ce qui sépare `f8` de `f9` :
    /// `SWAPGS` est `rm = 0`, `RDTSCP` est `rm = 1`. Toute la famille en `mod =
    /// 3` tombait donc dans le bras de `SWAPGS`.
    ///
    /// **Ce n'est pas un refus, c'est une réponse fausse.** Le noyau demande
    /// l'heure et repart avec ses deux bases de GS interverties — sa zone par
    /// processeur pointe sur celle de l'espace utilisateur, et le prochain
    /// accès `%gs:` lit ailleurs. Un refus franc aurait nommé le problème ;
    /// répondre pour le voisin le cache.
    ///
    /// Le test tient les deux côtés : `RDTSCP` laisse les bases où elles sont,
    /// et `SWAPGS` les échange toujours.
    func testRDTSCPDoesNotSwapTheGSBasesTheWayItsNeighbourDoes() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        // 0f 01 f9 = RDTSCP, puis F4 = HLT pour arrêter proprement.
        var core = try Self.core(ram, [0x0F, 0x01, 0xF9, 0xF4])
        core.system.modelSpecific[X86SystemState.gsBase] = 0xAAAA
        core.system.modelSpecific[X86SystemState.kernelGSBase] = 0xBBBB
        try core.run(budget: 1)
        XCTAssertEqual(
            core.system.modelSpecific[X86SystemState.gsBase], 0xAAAA,
            "RDTSCP n'échange rien : la base de GS reste où le noyau l'a mise")
        XCTAssertEqual(
            core.system.modelSpecific[X86SystemState.kernelGSBase], 0xBBBB,
            "et celle que le noyau garde de côté ne bouge pas non plus")
    }

    /// **`RDTSCP` rend une heure, et il écrase ECX pour la rendre.**
    ///
    /// Trois écritures, pas deux : `EDX:EAX` reçoivent le compteur, et `ECX`
    /// reçoit `IA32_TSC_AUX`. Aucun `wrmsr` de cette machine n'écrit ce
    /// registre, donc zéro — et zéro est la réponse juste, pas un bouchon :
    /// un processeur dont personne n'a posé le TSC_AUX rend zéro lui aussi.
    ///
    /// Ce qui serait faux, c'est de **ne pas écrire** : ECX garderait ce qui
    /// traînait, et le noyau le lirait comme un numéro de processeur. C'est
    /// ainsi que `vgetcpu` répond, et ainsi que le noyau choisit la zone par
    /// processeur où il range la suite. Le test met donc une valeur bien
    /// visible dans RCX d'abord, pour que la laisser en place se voie.
    ///
    /// Et l'heure rendue est **celle de `RDTSC`**, à la même seconde : la
    /// même égalité que tient `X86GuestClockTests`, `retired + idled - 1`,
    /// l'instruction lisant l'heure avant de se retirer elle-même. Deux
    /// horloges qui divergeraient feraient reculer le temps d'une lecture à
    /// l'autre.
    func testRDTSCPReadsTheSameClockAsRDTSCAndClearsTheProcessorNumber() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0x0F, 0x01, 0xF9, 0xF4])
        // De quoi voir si ECX est laissé tel quel — et si les trente-deux bits
        // hauts de RCX survivent, ce qu'une écriture 32 bits ne permet pas.
        core.registers[1] = 0x1234_5678_9ABC_DEF0
        try core.run(budget: 1)

        XCTAssertEqual(
            core.registers[1], 0,
            "RDTSCP pose IA32_TSC_AUX dans ECX ; personne ne l'a écrit, donc zéro")

        let read = (core.registers[2] << 32) | (core.registers[0] & 0xFFFF_FFFF)
        XCTAssertEqual(
            read, core.retired &+ core.idled &- 1,
            "la même horloge que RDTSC, lue avant que l'instruction ne se retire")
    }

    /// Et le voisin, lui, échange toujours — sans quoi la correction aurait
    /// éteint le passage d'anneau au lieu de le préciser.
    func testSWAPGSStillSwapsAfterItsNeighbourWasSeparated() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0x0F, 0x01, 0xF8, 0xF4])
        core.system.modelSpecific[X86SystemState.gsBase] = 0xAAAA
        core.system.modelSpecific[X86SystemState.kernelGSBase] = 0xBBBB
        try core.run(budget: 1)
        XCTAssertEqual(core.system.modelSpecific[X86SystemState.gsBase], 0xBBBB)
        XCTAssertEqual(core.system.modelSpecific[X86SystemState.kernelGSBase], 0xAAAA)
    }

    /// `FWAIT` attend que le coprocesseur ait fini. Il n'y en a pas qui
    /// calcule, donc il n'y a jamais rien à attendre — mais le noyau en sème
    /// autour de ses instructions x87.
    func testFWAITIsANoOp() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0x9B, 0xF4])
        try core.run(budget: 2)
        XCTAssertTrue(core.halted)
    }

    // MARK: - Les interruptions que le code demande lui-même

    /// **`INT3` reprend *après* l'instruction, pas dessus.** C'est un appel,
    /// pas une faute : une faute dépose l'adresse de l'instruction fautive
    /// pour qu'on puisse la rejouer, une interruption logicielle dépose la
    /// suivante pour qu'on puisse continuer. Confondre les deux fait boucler
    /// le gestionnaire sur son propre point d'arrêt.
    func testINT3PushesTheAddressAfterItself() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try Self.installGate(ram, vector: 3, target: 0x8000)
        try ram.load([0xF4], at: 0x8000)
        // `cc` puis `90` : le retour doit pointer sur le NOP.
        var core = try Self.core(ram, [0xCC, 0x90])
        core.descriptorBases[1] = Self.idt
        core.descriptorLimits[1] = 0x1FF
        core.registers[4] = 0x7000
        try core.run(budget: 1)
        XCTAssertEqual(core.rip, 0x8000)
        // Le cadre : cinq cases, l'adresse de reprise en bas.
        XCTAssertEqual(try ram.read(core.registers[4], 8), 0x101,
                       "l'adresse **après** l'INT3")
    }

    /// `INT n` fait la même chose, avec le vecteur qu'on lui donne.
    func testINTWithANumberEntersThatVector() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try Self.installGate(ram, vector: 0x80, target: 0x8000)
        try ram.load([0xF4], at: 0x8000)
        var core = try Self.core(ram, [0xCD, 0x80, 0x90])
        core.descriptorBases[1] = Self.idt
        core.descriptorLimits[1] = 0xFFF
        core.registers[4] = 0x7000
        try core.run(budget: 1)
        XCTAssertEqual(core.rip, 0x8000)
        XCTAssertEqual(try ram.read(core.registers[4], 8), 0x102)
    }

    /// Sans porte pour ce vecteur, l'instruction est **refusée** plutôt
    /// qu'ignorée — et RIP ne bouge pas, pour que l'arrêt nomme la bonne
    /// instruction.
    func testAnINTWithoutAGateIsRefusedWithoutMovingRIP() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = try Self.core(ram, [0xCC])
        XCTAssertThrowsError(try core.run(budget: 1))
        XCTAssertEqual(core.rip, 0x100)
    }
}
