import XCTest

@testable import WisqVM

/// Qui tourne, et qui attend quoi — ce qu'un `ps -T` dirait de l'invité.
///
/// Alpine s'arrête sur « Mounting boot media: » et n'en sort plus, et tout
/// ce que les témoins savaient dire a été éliminé un à un : instruction,
/// pile, horloge, console, enfants de `fork()`. nlplug-findfs attend sans
/// limite qu'un de ses enfants se termine ou que son fil de parcours
/// finisse. Ce registre dit quels fils existent, lequel travaille encore,
/// et sur quel appel système — avec quels arguments — les autres sont partis.
final class X86ProcessLedgerTests: XCTestCase {
    static let pml4: UInt64 = 0x2000
    static let pdpt: UInt64 = 0x3000
    static let program: UInt64 = 0x1000

    /// Un cœur paginé en anneau trois, témoin armé, appels système permis.
    static func core(_ bytes: [UInt8]) throws -> X86Core {
        let memory = X86Memory(size: 0x10000, base: 0)
        try memory.load(bytes, at: program)
        let open = X86Core.present | X86Core.writable | X86Core.userAccessible
        try memory.write(pml4, 8, pdpt | open)
        try memory.write(pdpt, 8, X86Core.present | X86Core.hugePage | open)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: program, memory: memory)
        core.system.control[3] = pml4
        core.pagingActive = true
        core.segments[1] = 0x33
        core.canonicalWatchArmed = true
        core.system.modelSpecific[X86SystemState.efer] = X86SystemState.systemCallEnable
        core.system.modelSpecific[X86SystemState.longSystemCallTarget] = 0x8000
        core.system.modelSpecific[X86SystemState.fsBase] = 0x7000
        return core
    }

    static let main = X86Core.ThreadKey(addressSpace: pml4, threadPointer: 0x7000)

    /// Trois instructions d'anneau trois dans un fil : trois instructions à
    /// son compte, et le RIP de la dernière.
    func testInstructionsAreCountedPerThread() throws {
        var core = try Self.core([0x90, 0x90, 0x90])
        try core.run(budget: 3)
        let entry = try XCTUnwrap(core.threadActivity[Self.main])
        XCTAssertEqual(entry.instructions, 3)
        XCTAssertEqual(entry.lastRip, Self.program &+ 2)
        XCTAssertEqual(entry.systemCalls, 0)
        XCTAssertNil(entry.lastSystemCall)
    }

    /// Un `SYSCALL` est compté au fil qui l'a fait, avec son numéro, son nom
    /// et ses trois premiers arguments : `futex(adresse, WAIT, …)` ne se lit
    /// pas comme `futex(adresse, WAKE, …)`.
    func testTheLastSystemCallIsNamedWithItsArguments() throws {
        // mov $202,%eax ; mov $0x1234,%edi ; mov $0x80,%esi ; mov $1,%edx ; syscall
        var core = try Self.core([
            0xB8, 0xCA, 0x00, 0x00, 0x00, 0xBF, 0x34, 0x12, 0x00, 0x00,
            0xBE, 0x80, 0x00, 0x00, 0x00, 0xBA, 0x01, 0x00, 0x00, 0x00, 0x0F, 0x05,
        ])
        try core.run(budget: 5)
        let entry = try XCTUnwrap(core.threadActivity[Self.main])
        XCTAssertEqual(entry.systemCalls, 1)
        XCTAssertEqual(entry.lastSystemCall, 202)
        XCTAssertEqual(entry.lastArguments, [0x1234, 0x80, 1])
        XCTAssertTrue(entry.description.contains("futex(202)(1234, 80, 1)"), entry.description)
    }

    /// Deux fils d'un même processus — même CR3, deux bases de FS — sont deux
    /// entrées, et le plus récent vient en premier.
    func testThreadsOfOneProcessAreToldApart() throws {
        var core = try Self.core([0x90, 0x90])
        core.noteProcessActivity(at: 0x1000)
        core.retired = 500
        core.system.modelSpecific[X86SystemState.fsBase] = 0x7800
        core.noteProcessActivity(at: 0x2000)
        let order = core.threadsByLastActivity.map(\.key.threadPointer)
        XCTAssertEqual(order, [0x7800, 0x7000])
        XCTAssertEqual(core.threadActivity.count, 2)
    }

    /// **L'instruction de sortie appartient à la vie qui se termine.** La
    /// première version la comptait dans la suivante, et le rapport montrait
    /// quatre processus « d'une instruction » à `_Exit+0x8` qui n'étaient que
    /// les fantômes de sorties ordinaires. Et le CR3 recyclé ensuite est un
    /// autre processus, qui repart de zéro.
    func testTheExitInstructionBelongsToTheLifeThatExits() throws {
        // nop ; mov $231,%eax ; syscall — puis, ressuscité, un nop.
        var core = try Self.core([0x90, 0xB8, 0xE7, 0x00, 0x00, 0x00, 0x0F, 0x05])
        try core.run(budget: 3)
        let dying = try XCTUnwrap(core.threadActivity[Self.main])
        XCTAssertEqual(dying.instructions, 3, "nop, mov, et le syscall lui-même")
        XCTAssertEqual(dying.lastSystemCall, 231)
        XCTAssertTrue(dying.exited)

        core.retired = 999
        core.noteProcessActivity(at: 0x5000)
        let revived = try XCTUnwrap(core.threadActivity[Self.main])
        XCTAssertEqual(revived.instructions, 1, "repart de zéro")
        XCTAssertFalse(revived.exited)
        XCTAssertEqual(revived.firstSeen, 999)
        XCTAssertNil(revived.lastSystemCall)
    }

    /// `execve` remplace l'espace d'adressage : c'est aussi la fin d'une vie.
    func testExecveEndsALifeToo() throws {
        var core = try Self.core([0xB8, 0x3B, 0x00, 0x00, 0x00, 0x0F, 0x05])
        try core.run(budget: 2)
        XCTAssertTrue(try XCTUnwrap(core.threadActivity[Self.main]).exited)
    }

    /// La dernière faute livrée au noyau depuis un fil est gardée, avec
    /// l'adresse, le code et d'où elle partait : « ce fil a exécuté une
    /// instruction puis plus rien » se lit alors « il a fauté ici ».
    func testTheLastFaultIsRemembered() throws {
        // mov %rax,0x40000000 : une écriture au-delà du gigaoctet cartographié.
        var core = try Self.core([0x48, 0x89, 0x04, 0x25, 0x00, 0x00, 0x00, 0x40])
        XCTAssertThrowsError(try core.run(budget: 1), "sans IDT, la faute sort")
        let entry = try XCTUnwrap(core.threadActivity[Self.main])
        let fault = try XCTUnwrap(entry.lastFault)
        XCTAssertTrue(fault.hasPrefix("#PF à 40000000"), fault)
        XCTAssertTrue(fault.contains("depuis 1000"), fault)
    }

    /// Éteint, le registre ne coûte rien et ne sait rien.
    func testTheLedgerIsOffUnlessTheWatchIsArmed() throws {
        var core = try Self.core([0x90, 0x90])
        core.canonicalWatchArmed = false
        try core.run(budget: 2)
        XCTAssertTrue(core.threadActivity.isEmpty)
    }
}
