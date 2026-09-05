import XCTest

@testable import WisqVM

/// **Le vidage global du TLB, celui qui ne passe pas par `INVLPG`.**
///
/// Un noyau Linux qui n'a pas `INVPCID` vide *tout* le cache de traductions en
/// éteignant puis rallumant un bit de CR4 :
///
///     native_write_cr4(cr4 ^ X86_CR4_PGE);   /* PGE tombe : tout est vidé */
///     native_write_cr4(cr4);                 /* et on le remet */
///
/// C'est ce que fait `__flush_tlb_global()`, et c'est ce que `vfree` appelle
/// quand il rend une plage assez large — celle d'un module, par exemple. Notre
/// cache ne l'écoutait pas : il ne se vidait que sur CR3 et sur l'allumage de
/// la pagination. Une adresse noyau réutilisée après un `vfree` gardait donc
/// **l'ancienne trame**, et le noyau lisait les octets du module précédent à
/// la place du sien.
///
/// **Ce que ça a produit, mesuré sur le vrai noyau.** `modprobe drm` :
/// « Invalid relocation target, existing value is nonzero », puis
/// « mm/pgtable-generic.c:42: bad pud », puis un segfault de modprobe et deux
/// « BUG: Bad rss-counter state ». `modprobe virtio_blk` : « Key was rejected
/// by service » — la signature ne correspondait pas, parce que les octets
/// vérifiés n'étaient pas ceux du fichier. Les 328 modules de l'initramfs ont
/// pourtant la même somme md5 dans l'invité que sur l'hôte : le fichier était
/// bon, c'est la lecture qui mentait.
///
/// Ces tests-ci ne demandent pas au noyau de le prouver : ils remplacent une
/// entrée de table sous les pieds du cache, vident comme lui, et regardent.
final class X86GlobalFlushTests: XCTestCase {
    static let pml4: UInt64 = 0x2000
    static let pdpt: UInt64 = 0x3000
    static let directory: UInt64 = 0x4000
    static let table: UInt64 = 0x5000
    /// L'adresse qu'on remappe, et les deux trames entre lesquelles elle danse.
    static let subject: UInt64 = 0x9000
    static let first: UInt64 = 0xA000
    static let second: UInt64 = 0xB000

    static func core() throws -> X86Core {
        let memory = X86Memory(size: 0x20000, base: 0)
        let open = X86Core.present | X86Core.writable | X86Core.userAccessible
        try memory.write(pml4, 8, pdpt | open)
        try memory.write(pdpt, 8, directory | open)
        try memory.write(directory, 8, table | open)
        for page in stride(from: UInt64(0), to: UInt64(0x20000), by: 0x1000) {
            try memory.write(table &+ (page >> 12) * 8, 8, page | open)
        }
        // L'adresse à l'essai pointe d'abord la première trame.
        try memory.write(table &+ (subject >> 12) * 8, 8, first | open)
        try memory.write(first, 8, 0x1111)
        try memory.write(second, 8, 0x2222)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: 0, memory: memory)
        core.system.control[3] = pml4
        core.system.control[4] = X86SystemState.physicalAddressExtension
            | X86SystemState.pageGlobalEnable
        core.pagingActive = true
        return core
    }

    /// Rebrancher l'adresse sur l'autre trame, comme le noyau le fait en
    /// rendant puis reprenant une plage de `vmalloc`.
    static func remap(_ core: X86Core) throws {
        try core.memory?.write(table &+ (subject >> 12) * 8, 8,
                               second | X86Core.present | X86Core.writable
                                   | X86Core.userAccessible)
    }

    /// Le cache existe, et c'est bien lui qu'on met à l'épreuve : sans vidage,
    /// l'ancienne trame répond encore.
    func testWithoutAnyFlushTheOldFrameIsStillThere() throws {
        var core = try Self.core()
        XCTAssertEqual(try core.memory?.read(try core.translate(Self.subject), 8), 0x1111)
        try Self.remap(core)
        XCTAssertEqual(try core.memory?.read(try core.translate(Self.subject), 8), 0x1111,
                       "le cache garde ce qu'il a vu — c'est son rôle")
    }

    /// **Éteindre puis rallumer PGE vide tout**, et c'est la seule chose que le
    /// noyau fait quand il rend une plage de `vmalloc`.
    func testTogglingPageGlobalEnableFlushesEverything() throws {
        var core = try Self.core()
        _ = try core.translate(Self.subject)
        try Self.remap(core)

        let saved = core.system.control[4]
        core.writeControlRegister(4, saved ^ X86SystemState.pageGlobalEnable)
        core.writeControlRegister(4, saved)

        XCTAssertEqual(try core.memory?.read(try core.translate(Self.subject), 8), 0x2222,
                       "après un vidage global, la nouvelle trame")
    }

    /// Et n'importe quelle écriture de CR4 vide, pas seulement celle qui
    /// touche PGE : c'est plus large que ce que le manuel exige, jamais faux,
    /// et un cœur qui essaierait d'être fin ici se tromperait un jour sur un
    /// bit qu'il n'avait pas prévu — SMEP, PCIDE, PAE.
    func testAnyWriteToCR4Flushes() throws {
        var core = try Self.core()
        _ = try core.translate(Self.subject)
        try Self.remap(core)
        core.writeControlRegister(4, core.system.control[4])
        XCTAssertEqual(try core.memory?.read(try core.translate(Self.subject), 8), 0x2222)
    }

    /// Les deux vidages qui marchaient déjà, pour que la correction ne les
    /// perde pas : écrire CR3, et `INVLPG`.
    func testWritingCR3StillFlushes() throws {
        var core = try Self.core()
        _ = try core.translate(Self.subject)
        try Self.remap(core)
        core.writeControlRegister(3, core.system.control[3])
        XCTAssertEqual(try core.memory?.read(try core.translate(Self.subject), 8), 0x2222)
    }

    func testINVLPGStillFlushes() throws {
        var core = try Self.core()
        _ = try core.translate(Self.subject)
        try Self.remap(core)
        core.flushTranslations()
        XCTAssertEqual(try core.memory?.read(try core.translate(Self.subject), 8), 0x2222)
    }
}
