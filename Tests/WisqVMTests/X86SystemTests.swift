import XCTest

@testable import WisqVM

/// Ce que le processeur porte en dehors de ses registres généraux.
///
/// **L'oracle matériel ne peut rien pour ça, et c'est voulu.** Il dirait ce que
/// *cette* machine-ci répond à `CPUID`, or c'est précisément ce qu'il ne faut
/// pas : un invité qui croirait tourner sur le processeur de l'hôte
/// utiliserait des instructions que ce cœur n'exécute pas. Ce que wisq annonce
/// est une **décision**, et chaque bit annoncé est une promesse que le reste du
/// cœur doit tenir. Ces tests relisent les promesses.
final class X86SystemTests: XCTestCase {
    func machine(_ program: [UInt8], memory size: Int = 1 << 20) throws -> X86Core {
        let ram = X86Memory(size: size, base: 0)
        try ram.load(program, at: 0)
        var registers = [UInt64](repeating: 0, count: 16)
        registers[4] = UInt64(size) - 0x100
        return X86Core(registers: registers, rip: 0, memory: ram)
    }

    /// Chaque bit annoncé par `CPUID` doit correspondre à quelque chose que ce
    /// cœur fait vraiment. Le test est écrit dans ce sens : il part de
    /// l'annonce et remonte à l'instruction.
    func testEveryFeatureAnnouncedIsOneTheCoreActuallyHas() {
        let (_, _, _, features) = X86CPUID.answer(leaf: 1, subleaf: 0)
        XCTAssertNotEqual(features & (1 << 4), 0, "TSC annoncé : RDTSC répond")
        XCTAssertNotEqual(features & (1 << 5), 0, "MSR annoncé : RDMSR et WRMSR répondent")
        XCTAssertNotEqual(features & (1 << 6), 0, "PAE annoncé : la traduction est à quatre niveaux")
        XCTAssertNotEqual(features & (1 << 15), 0, "CMOV annoncé : les seize CMOVcc sont là")
        // Le FPU est annoncé, mais au sens strict : les trois instructions par
        // lesquelles Linux le détecte répondent juste, et rien de plus.
        // L'arithmétique x87, elle, est refusée par son nom.
        XCTAssertNotEqual(features & 1, 0, "sans FPU annoncé, un noyau 64 bits s'arrête")
    }

    /// Sans le bit « mode long » dans la feuille étendue, un noyau 64 bits
    /// refuse de démarrer — et il le dit, ce qui est déjà mieux que de planter.
    func testLongModeIsAnnouncedOrNoKernelWillEvenTry() {
        let (_, _, _, extended) = X86CPUID.answer(leaf: 0x8000_0001, subleaf: 0)
        XCTAssertNotEqual(extended & (1 << 29), 0)
    }

    /// **Un sélecteur nul dans FS efface sa base, et le cœur la gardait.**
    ///
    /// **Mesuré sur le vrai processeur**, par un programme à syscalls bruts —
    /// passer par la libc entre les deux relevés toucherait `errno`, qui vit
    /// dans le TLS pointé par FS, donc l'instrument aurait cassé ce qu'il
    /// mesure :
    ///
    /// ```text
    /// FS.base avant = 0x7f7da625f740
    /// xorl %eax,%eax ; movl %eax,%fs
    /// FS.base apres = 0x0
    /// ```
    ///
    /// `case 0x8E` rangeait le sélecteur dans `segments[reg]` et ne touchait
    /// **aucune** base. Après un chargement nul, ce cœur gardait donc
    /// l'ancienne là où le silicium l'efface — et `segmentBase()` la relit à
    /// chaque accès préfixé.
    ///
    /// **Latent, pas faux.** Linux met ses segments à zéro dans `head_64.S`
    /// quand les bases valent déjà zéro, puis pose les vraies par `wrmsr` :
    /// rien ne mord aujourd'hui. Mais c'est deux choses qui devraient
    /// s'accorder et qui ne s'accordent pas, et le taire parce que ça ne mord
    /// pas encore serait le garder.
    ///
    /// **Le test mesure la conséquence, pas la case.** Ce qui casse n'est pas
    /// qu'un emplacement porte un nombre : c'est qu'un accès `%fs:` atterrisse
    /// ailleurs. Deux valeurs sont donc plantées — une à la base, une à zéro —
    /// et c'est l'adresse lue qui dit laquelle des deux le cœur a choisie.
    func testANullSelectorClearsTheSegmentBaseAsTheSiliconDoes() throws {
        let base: UInt64 = 0x4_0000
        let program: [UInt8] = [
            0x31, 0xC0, // xor  %eax,%eax
            0x8E, 0xE0, // mov  %eax,%fs   — le sélecteur nul
            0x64, 0x48, 0x8B, 0x04, 0x25, 0x10, 0x00, 0x00, 0x00, // mov %fs:0x10,%rax
            0xF4, // hlt
        ]
        var core = try machine(program)
        core.system.modelSpecific[X86SystemState.fsBase] = base
        // Deux témoins, pour que l'adresse lue se lise dans le résultat.
        try core.memory?.write(0x10, 8, 0x1111_1111_1111_1111)
        try core.memory?.write(base + 0x10, 8, 0x2222_2222_2222_2222)
        try core.run(budget: 20)
        XCTAssertEqual(
            core.registers[0], 0x1111_1111_1111_1111,
            "après un `mov %eax,%fs` nul, `%fs:0x10` doit lire à 0x10 — la base est effacée")
        XCTAssertEqual(
            core.system.modelSpecific[X86SystemState.fsBase], 0,
            "et la case elle-même porte zéro")
    }

    /// **Et un nul dans ES, SS ou DS ne touche aucune base non plus.**
    ///
    /// Ce test manquait, et un sabotage l'a montré en survivant : retirer la
    /// garde de segment ne cassait rien. Sans elle, `which == 4 ? fs : gs`
    /// prend la branche `gs` pour **tout** segment qui n'est pas FS — donc un
    /// `mov $0,%ds` effacerait la base de GS.
    ///
    /// **Ce n'est pas théorique.** `head_64.S` met DS, SS et ES à zéro juste
    /// avant FS et GS, dans cet ordre-là. Le défaut serait tombé au démarrage
    /// du premier noyau, sur une base que rien n'avait demandé d'effacer.
    ///
    /// En mode 64 bits, la base d'ES, SS et DS est **forcée à zéro** de toute
    /// façon : il n'y a rien à effacer pour eux, et rien à toucher chez les
    /// autres.
    func testANullSelectorInTheOtherSegmentsTouchesNoBase() throws {
        let fs: UInt64 = 0x4_0000
        let gs: UInt64 = 0x5_0000
        let program: [UInt8] = [
            0x31, 0xC0, // xor %eax,%eax
            0x8E, 0xD8, // mov %eax,%ds
            0x8E, 0xD0, // mov %eax,%ss
            0x8E, 0xC0, // mov %eax,%es
            0xF4, // hlt
        ]
        var core = try machine(program)
        core.system.modelSpecific[X86SystemState.fsBase] = fs
        core.system.modelSpecific[X86SystemState.gsBase] = gs
        try core.run(budget: 20)
        XCTAssertEqual(
            core.system.modelSpecific[X86SystemState.fsBase], fs,
            "un nul dans DS, SS ou ES ne concerne pas la base de FS")
        XCTAssertEqual(
            core.system.modelSpecific[X86SystemState.gsBase], gs,
            "ni celle de GS — et c'est celle-là qu'une garde manquante effacerait")
    }

    /// **Et un sélecteur non nul ne touche pas la base.** Le silicium irait la
    /// chercher dans un descripteur ; ce cœur n'a pas de table globale, et
    /// inventer une base serait pire que garder celle qu'on a. Ce que la
    /// tranche corrige est le cas **nul**, qui ne lit aucun descripteur — pas
    /// la segmentation entière.
    func testARealSelectorLeavesTheBaseAlone() throws {
        let base: UInt64 = 0x4_0000
        // b8 23 00 00 00 : mov $0x23,%eax ; 8e e0 : mov %eax,%fs ; f4 : hlt
        var core = try machine([0xB8, 0x23, 0x00, 0x00, 0x00, 0x8E, 0xE0, 0xF4])
        core.system.modelSpecific[X86SystemState.fsBase] = base
        try core.run(budget: 20)
        XCTAssertEqual(
            core.system.modelSpecific[X86SystemState.fsBase], base,
            "aucune base n'est inventée quand le descripteur manque")
    }

    /// Une feuille inconnue rend des **zéros**, pas les registres inchangés :
    /// laisser ce qui traînait ferait lire n'importe quoi à l'invité.
    func testAnUnknownLeafAnswersZeroRatherThanLeavingWhatWasThere() throws {
        // b8 ff 00 00 00 : mov $0xff,%eax ; 0f a2 : cpuid ; f4 : hlt
        var core = try machine([0xB8, 0xFF, 0x00, 0x00, 0x00, 0x0F, 0xA2, 0xF4])
        core.registers[3] = 0xDEAD_BEEF
        try core.run(budget: 10)
        XCTAssertEqual(core.registers[0], 0)
        XCTAssertEqual(core.registers[3], 0, "EBX aussi, et il portait autre chose")
    }

    /// `CPUID` feuille 0 rend le nom du constructeur dans EBX, EDX, ECX — dans
    /// cet ordre-là, qui n'est pas celui qu'on devinerait.
    func testTheVendorNameComesBackInTheOrderTheManualAsks() throws {
        var core = try machine([0x31, 0xC0, 0x0F, 0xA2, 0xF4])  // xor %eax,%eax ; cpuid ; hlt
        try core.run(budget: 10)
        var name: [UInt8] = []
        for register in [3, 2, 1] {  // EBX, EDX, ECX
            let value = core.registers[register]
            for byte in 0..<4 { name.append(UInt8((value >> (8 * UInt64(byte))) & 0xFF)) }
        }
        XCTAssertEqual(String(decoding: name, as: UTF8.self), "wisq  x86-64")
        XCTAssertEqual(X86CPUID.vendor.utf8.count, 12, "douze octets, ni plus ni moins")
    }

    /// Écrire `EFER` ne suffit pas à être en mode long : le processeur pose
    /// **lui-même** LMA quand la pagination s'allume alors que LME est demandé.
    /// Un noyau lit LMA pour savoir où il en est.
    func testLongModeBecomesActiveOnlyWhenPagingComesOn() {
        var state = X86SystemState()
        state.modelSpecific[X86SystemState.efer] = X86SystemState.longModeEnable
        state.refreshLongMode()
        XCTAssertFalse(state.longMode, "demandé, mais la pagination n'est pas là")

        state.control[0] |= X86SystemState.paging
        state.refreshLongMode()
        XCTAssertTrue(state.longMode, "la pagination allumée, il devient actif")

        state.control[0] &= ~X86SystemState.paging
        state.refreshLongMode()
        XCTAssertFalse(state.longMode, "et il redevient inactif quand elle s'éteint")
    }

    /// Une table de pages minimale, à quatre niveaux, qui envoie une page
    /// virtuelle sur un cadre physique choisi.
    ///
    /// `levels` porte les quatre tables. Deux correspondances qui partagent le
    /// même dernier niveau s'écrasent l'une l'autre — c'est arrivé en écrivant
    /// ces tests, et le symptôme était une écriture qui atterrissait à zéro.
    /// La racine reste commune, comme dans un vrai espace d'adressage.
    func buildTables(
        _ memory: X86Memory, virtual: UInt64, physical: UInt64,
        levels: [UInt64] = [0x2000, 0x3000, 0x4000, 0x5000]
    ) throws {
        for (depth, table) in levels.enumerated() {
            let shift = UInt64(39 - 9 * depth)
            let index = (virtual >> shift) & 0x1FF
            let target = depth == 3 ? physical : levels[depth + 1]
            try memory.write(table + index * 8, 8, target | X86Core.present)
        }
    }

    /// La traduction : quatre niveaux, et la page virtuelle atterrit là où les
    /// tables le disent.
    func testAVirtualAddressGoesWhereTheTablesSay() throws {
        // mov %rax,(%rcx) ; hlt — rcx portera l'adresse virtuelle.
        var core = try machine([0x48, 0x89, 0x01, 0xF4], memory: 1 << 20)
        let ram = try XCTUnwrap(core.memory)
        let virtual: UInt64 = 0x4000_0000_0000
        let physical: UInt64 = 0x8_0000
        try buildTables(ram, virtual: virtual, physical: physical)
        // Le code aussi doit être atteignable : avec la pagination allumée, la
        // lecture de l'instruction passe par les mêmes tables que ses données.
        // Ses trois niveaux inférieurs sont ailleurs, sans quoi les deux
        // correspondances se partageraient la dernière table.
        try buildTables(ram, virtual: 0, physical: 0,
                        levels: [0x2000, 0x6000, 0x7000, 0x8000])

        core.registers[0] = 0x1122_3344_5566_7788
        core.registers[1] = virtual + 0x18
        core.system.control[3] = 0x2000
        core.system.control[0] |= X86SystemState.paging
        core.pagingActive = true
        try core.run(budget: 10)

        XCTAssertEqual(try ram.read(physical + 0x18, 8), 0x1122_3344_5566_7788,
                       "l'écriture est allée à l'adresse physique, pas à la virtuelle")
    }

    /// Une entrée absente est une faute de page **nommée**, avec l'adresse.
    func testAnAbsentEntryIsAPageFaultThatNamesTheAddress() throws {
        var core = try machine([0x48, 0x8B, 0x01, 0xF4])  // mov (%rcx),%rax
        core.registers[1] = 0x7F00_0000_0000
        core.system.control[3] = 0x2000
        core.system.control[0] |= X86SystemState.paging
        core.pagingActive = true
        // Le code lui-même n'est pas mappé non plus : la faute tombe dès la
        // lecture de la première instruction, et c'est **son** adresse qui est
        // nommée.
        XCTAssertThrowsError(try core.run(budget: 10)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .pageFault(0))
        }
    }

    /// Une grande page de deux mébioctets arrête le parcours au troisième
    /// niveau : le bit qui le dit est à la même place que celui d'une page
    /// ordinaire, et l'oublier ferait lire une table là où il y a des données.
    func testAHugePageStopsTheWalkEarly() throws {
        let ram = X86Memory(size: 8 << 20, base: 0)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0, memory: ram)
        let virtual: UInt64 = 0x20_0000
        // PML4 → PDPT → PD, et la PD porte directement une page de 2 Mio.
        try ram.write(0x2000 + ((virtual >> 39) & 0x1FF) * 8, 8, 0x3000 | X86Core.present)
        try ram.write(0x3000 + ((virtual >> 30) & 0x1FF) * 8, 8, 0x4000 | X86Core.present)
        try ram.write(0x4000 + ((virtual >> 21) & 0x1FF) * 8, 8,
                      0x40_0000 | X86Core.present | X86Core.hugePage)
        core.system.control[3] = 0x2000
        core.system.control[0] |= X86SystemState.paging
        core.pagingActive = true

        let translated = try core.translate(virtual + 0x1234)
        XCTAssertEqual(translated, 0x40_0000 + 0x1234)
    }

    /// Changer `CR3` vide le cache de traduction. Sans ça, un noyau qui change
    /// d'espace d'adressage continuerait de lire l'ancien — en silence, ce qui
    /// est la pire des façons de se tromper.
    func testWritingCR3ForgetsWhatWasCached() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0, memory: ram)
        let virtual: UInt64 = 0x10_0000
        try buildTables(ram, virtual: virtual, physical: 0x8_0000)
        core.system.control[3] = 0x2000
        core.system.control[0] |= X86SystemState.paging
        core.pagingActive = true
        XCTAssertEqual(try core.translate(virtual), 0x8_0000)

        // Une seconde racine, qui envoie la même page ailleurs.
        let second: [UInt64] = [0x6000, 0x7000, 0x8000, 0x9000]
        for (depth, table) in second.enumerated() {
            let shift = UInt64(39 - 9 * depth)
            let index = (virtual >> shift) & 0x1FF
            let target = depth == 3 ? UInt64(0x9_0000) : second[depth + 1]
            try ram.write(table + index * 8, 8, target | X86Core.present)
        }
        // Et le vidage doit venir de l'**écriture de CR3**, pas d'un appel à
        // la main : c'est le chemin qu'un noyau emprunte. `0f 22 d8` est
        // « mov %rax,%cr3 ».
        try ram.load([0x0F, 0x22, 0xD8, 0xF4], at: 0x1000)
        try buildTables(ram, virtual: 0x1000, physical: 0x1000)
        // La page du code doit être mappée dans les **deux** espaces : après
        // l'écriture de CR3, l'instruction suivante se lit déjà par les
        // nouvelles tables. Un vrai noyau ne bascule jamais sans ça, et la
        // première version de ce test l'avait oublié — la faute de page qui en
        // résultait était juste.
        try buildTables(ram, virtual: 0x1000, physical: 0x1000, levels: second)
        core.registers[0] = 0x6000
        core.rip = 0x1000
        try core.run(budget: 10)
        XCTAssertEqual(core.system.control[3], 0x6000)
        XCTAssertEqual(try core.translate(virtual), 0x9_0000,
                       "sans le vidage, l'ancienne traduction serait rendue")
    }

    /// Le cache de traduction ne doit pas prendre la **page zéro** pour une
    /// entrée déjà remplie. C'est le piège d'un cache dont l'étiquette vide est
    /// zéro : la page zéro est justement celle dont le numéro est zéro.
    func testPageZeroIsNotMistakenForAnEmptyCacheSlot() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0, memory: ram)
        // La page virtuelle zéro va sur un cadre qui n'est **pas** zéro.
        try buildTables(ram, virtual: 0, physical: 0xA_0000)
        core.system.control[3] = 0x2000
        core.system.control[0] |= X86SystemState.paging
        core.pagingActive = true
        XCTAssertEqual(try core.translate(0x40), 0xA_0040,
                       "une étiquette vide à zéro ferait rendre le cadre zéro")
        // Et une seconde fois, cette fois par le cache.
        XCTAssertEqual(try core.translate(0x40), 0xA_0040)
    }

    /// `RDMSR` et `WRMSR` font l'aller-retour, et la valeur passe bien par les
    /// **deux** moitiés EDX:EAX — n'en écrire qu'une est l'erreur classique.
    ///
    /// Un registre quelconque, **pas** `EFER` : celui-là, le processeur le
    /// modifie derrière l'écriture, puisqu'il pose LMA lui-même. La première
    /// version de ce test s'en servait et échouait d'un bit — le cœur avait
    /// raison et le test avait tort.
    func testAModelSpecificRegisterSurvivesTheRoundTrip() throws {
        // wrmsr ; xor eax,eax ; xor edx,edx ; rdmsr ; hlt
        var core = try machine([0x0F, 0x30, 0x31, 0xC0, 0x31, 0xD2, 0x0F, 0x32, 0xF4])
        core.registers[1] = 0x174  // SYSENTER_CS, que rien ici ne relit
        core.registers[0] = 0x1234_5678
        core.registers[2] = 0x9ABC_DEF0
        try core.run(budget: 10)
        XCTAssertEqual(core.registers[0], 0x1234_5678, "la moitié basse")
        XCTAssertEqual(core.registers[2], 0x9ABC_DEF0, "et la haute")
    }
}
