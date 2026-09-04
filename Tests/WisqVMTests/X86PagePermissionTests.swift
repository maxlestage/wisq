import XCTest

@testable import WisqVM

/// Les permissions d'une page : le bit d'écriture, le bit utilisateur, et
/// CR0.WP.
///
/// **Pourquoi ils existent maintenant et pas avant.** Le parcours des tables ne
/// regardait que le bit de présence, et un commentaire l'annonçait comme un
/// choix : « ce cœur ne faute que sur une entrée absente, jamais sur une
/// protection ». C'était le défaut qui a coûté trois jours.
///
/// Ces deux bits **sont** la copie sur écriture. Quand un programme se
/// dédouble, le noyau ne recopie pas sa mémoire : il donne les mêmes pages aux
/// deux et retire le bit d'écriture des deux côtés. La première écriture
/// faute, le noyau fait la copie à ce moment-là. Un cœur qui laisse
/// l'écriture passer sans fauter empêche la copie d'avoir lieu — et **tous les
/// programmes se retrouvent à écrire dans la même page**.
///
/// C'est exactement ce que le témoin a mesuré sur le vrai noyau : cinq
/// processus successifs dont les relocations s'additionnaient, l'écart entre
/// deux valeurs corrompues valant à l'octet près la base de chargement du
/// processus suivant.
final class X86PagePermissionTests: XCTestCase {
    static let pml4: UInt64 = 0x2000
    static let pdpt: UInt64 = 0x3000
    static let directory: UInt64 = 0x4000
    static let table: UInt64 = 0x5000
    static let program: UInt64 = 0x1000
    /// La page à l'essai, cartographiée à part du code.
    static let subject: UInt64 = 0x8000

    static let present = X86Core.present
    static let writable = X86Core.writable
    static let user = X86Core.userAccessible

    /// Une pagination à quatre niveaux où seule la page à l'essai porte les
    /// permissions qu'on lui donne ; tout le reste est grand ouvert.
    static func core(_ instructions: [UInt8], subjectFlags: UInt64,
                     tableFlags: UInt64 = present | writable | user,
                     ring: UInt16 = 3, writeProtect: Bool = true) throws -> X86Core {
        let memory = X86Memory(size: 0x10000, base: 0)
        try memory.load(instructions, at: program)
        let open = present | writable | user
        try memory.write(pml4, 8, pdpt | open)
        try memory.write(pdpt, 8, directory | open)
        try memory.write(directory, 8, table | tableFlags)
        // Les pages du code et des tables, ouvertes ; celle à l'essai, non.
        for page in stride(from: UInt64(0), to: UInt64(0x8000), by: 0x1000) {
            try memory.write(table &+ (page >> 12) * 8, 8, page | open)
        }
        try memory.write(table &+ (subject >> 12) * 8, 8, subject | subjectFlags)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: program, memory: memory)
        core.system.control[3] = pml4
        core.system.control[0] = writeProtect ? X86Core.writeProtect : 0
        core.pagingActive = true
        core.segments[1] = ring == 3 ? 0x33 : 0x10
        core.registers[6] = subject  // RSI pointe la page à l'essai
        return core
    }

    /// `mov %rax, (%rsi)` — l'écriture qui doit fauter.
    static let write: [UInt8] = [0x48, 0x89, 0x06]
    /// `mov (%rsi), %rax` — la lecture qui doit passer.
    static let read: [UInt8] = [0x48, 0x8B, 0x06]

    /// Le code d'erreur qu'un gestionnaire lira : présence, écriture, anneau.
    static let presentBit: UInt64 = 1
    static let writeBit: UInt64 = 1 << 1
    static let userBit: UInt64 = 1 << 2
    static let fetchBit: UInt64 = 1 << 4

    func testAProgramMayNotWriteAReadOnlyPage() throws {
        var core = try Self.core(Self.write, subjectFlags: Self.present | Self.user)
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .pageFault(Self.subject))
        }
        XCTAssertEqual(core.pageFaultErrorCode,
                       Self.presentBit | Self.writeBit | Self.userBit,
                       "présente, en écriture, depuis un programme — « fais la copie »")
    }

    func testTheSamePageStaysReadable() throws {
        var core = try Self.core(Self.read, subjectFlags: Self.present | Self.user)
        try memoryHolds(&core, 0x1122334455667788)
        XCTAssertEqual(try core.run(budget: 1), 1)
        XCTAssertEqual(core.registers[0], 0x1122334455667788)
    }

    /// **Le cache ne blanchit pas une permission.** Une lecture met la page en
    /// cache ; l'écriture qui suit doit fauter quand même. Sans ce contrôle
    /// sur le chemin rapide, il aurait suffi de lire une page avant de
    /// l'écrire pour passer au travers.
    func testAReadDoesNotOpenTheWayForAWrite() throws {
        var core = try Self.core(Self.read + Self.write,
                                 subjectFlags: Self.present | Self.user)
        XCTAssertEqual(try? core.run(budget: 1), 1, "la lecture passe et met en cache")
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .pageFault(Self.subject))
        }
    }

    func testAProgramMayNotReachASupervisorPage() throws {
        var core = try Self.core(Self.read, subjectFlags: Self.present | Self.writable)
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .pageFault(Self.subject))
        }
        XCTAssertEqual(core.pageFaultErrorCode, Self.presentBit | Self.userBit,
                       "une lecture ne porte pas le bit d'écriture")
    }

    func testTheKernelReachesASupervisorPage() throws {
        var core = try Self.core(Self.read, subjectFlags: Self.present | Self.writable,
                                 ring: 0)
        try memoryHolds(&core, 7)
        XCTAssertEqual(try core.run(budget: 1), 1)
        XCTAssertEqual(core.registers[0], 7)
    }

    /// CR0.WP : sans lui le noyau écrit à travers une page en lecture seule,
    /// avec lui il faute comme un programme. Linux l'allume, et c'est ce qui
    /// rend la copie sur écriture sûre même quand c'est le noyau qui écrit
    /// dans la mémoire d'un programme.
    func testWithoutWriteProtectTheKernelWritesThrough() throws {
        var core = try Self.core(Self.write, subjectFlags: Self.present,
                                 ring: 0, writeProtect: false)
        core.registers[0] = 0x42
        XCTAssertEqual(try core.run(budget: 1), 1)
        XCTAssertEqual(try core.memory?.read(Self.subject, 8), 0x42)
    }

    func testWithWriteProtectTheKernelFaultsToo() throws {
        var core = try Self.core(Self.write, subjectFlags: Self.present,
                                 ring: 0, writeProtect: true)
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .pageFault(Self.subject))
        }
        XCTAssertEqual(core.pageFaultErrorCode, Self.presentBit | Self.writeBit,
                       "le noyau n'est pas un programme : pas de bit d'anneau")
    }

    /// **Les permissions sont le ET des quatre niveaux.** Une table qui n'est
    /// pas inscriptible interdit d'écrire dans tout ce qu'elle couvre, même si
    /// la feuille au bout dit le contraire ; c'est ainsi qu'un noyau ferme un
    /// espace entier d'un seul bit.
    func testATableClosesEverythingBelowIt() throws {
        var core = try Self.core(Self.write,
                                 subjectFlags: Self.present | Self.writable | Self.user,
                                 tableFlags: Self.present | Self.user)
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .pageFault(Self.subject))
        }
    }

    /// Et fermer la table aux programmes ferme aussi **leur code**, qui vit
    /// sous la même table : c'est la lecture de l'instruction qui faute, avant
    /// même qu'elle ait un opérande. Le test visait d'abord la donnée ; la
    /// machine a répondu par le code, et elle a raison.
    func testATableClosedToProgramsAlsoClosesTheirCode() throws {
        var core = try Self.core(Self.read,
                                 subjectFlags: Self.present | Self.writable | Self.user,
                                 tableFlags: Self.present | Self.writable)
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .pageFault(Self.program))
        }
        XCTAssertEqual(core.pageFaultErrorCode,
                       Self.presentBit | Self.userBit | Self.fetchBit,
                       "présente, depuis un programme, et c'est une lecture d'instruction")
    }

    private func memoryHolds(_ core: inout X86Core, _ value: UInt64) throws {
        try core.memory?.write(Self.subject, 8, value)
    }
}
