import XCTest

@testable import WisqVM

/// Ce que l'oracle matériel ne peut pas dire.
///
/// `X86OracleTests` compare le cœur au vrai processeur sur près de neuf mille
/// cas, et c'est la preuve principale. Mais un oracle qui **exécute** ne peut
/// pas être interrogé sur ce qui fait tomber le programme : une division par
/// zéro ne rend pas une réponse, elle tue le harnais. Et il ne dit rien non
/// plus de ce que ce cœur **refuse**, puisque tout ce qu'il exécute, il
/// l'exécute.
///
/// Ce fichier tient exactement ces deux bords-là, et rien d'autre : dupliquer
/// ici ce que l'oracle prouve déjà mieux ne ferait qu'ajouter un endroit où se
/// tromper.
final class X86CoreTests: XCTestCase {
    func core(rax: UInt64 = 0, rcx: UInt64 = 0, rdx: UInt64 = 0, flags: UInt64 = 2) -> X86Core {
        var registers = [UInt64](repeating: 0, count: 16)
        registers[0] = rax
        registers[1] = rcx
        registers[2] = rdx
        return X86Core(registers: registers, flags: flags)
    }

    func run(_ bytes: [UInt8], on core: inout X86Core) throws {
        try core.execute(try X86Decoder.decode(bytes))
    }

    /// `48 f7 f1` — `divq %rcx`. Diviser par zéro ne rend pas un nombre faux :
    /// le processeur lève, et ce cœur aussi.
    func testDividingByZeroIsRefusedRatherThanAnswered() throws {
        var machine = core(rax: 42, rcx: 0)
        XCTAssertThrowsError(try run([0x48, 0xF7, 0xF1], on: &machine)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .divideError)
        }
        // Le refus a lieu **avant** d'écrire quoi que ce soit.
        XCTAssertEqual(machine.registers[0], 42, "un refus ne doit rien laisser derrière lui")
    }

    /// La même chose en signé, et pour les quatre largeurs : c'est un chemin
    /// par largeur, donc quatre occasions de l'oublier.
    func testDividingByZeroIsRefusedAtEveryWidth() {
        let cases: [(String, [UInt8])] = [
            ("divb %cl", [0xF6, 0xF1]), ("divw %cx", [0x66, 0xF7, 0xF1]),
            ("divl %ecx", [0xF7, 0xF1]), ("divq %rcx", [0x48, 0xF7, 0xF1]),
            ("idivb %cl", [0xF6, 0xF9]), ("idivw %cx", [0x66, 0xF7, 0xF9]),
            ("idivl %ecx", [0xF7, 0xF9]), ("idivq %rcx", [0x48, 0xF7, 0xF9]),
        ]
        for (name, bytes) in cases {
            var machine = core(rax: 0x1234, rcx: 0)
            XCTAssertThrowsError(try run(bytes, on: &machine), name) { error in
                XCTAssertEqual(error as? X86Core.Fault, .divideError, name)
            }
        }
    }

    /// Un quotient qui ne tient pas dans son registre est refusé, et c'est un
    /// refus **différent** de la division par zéro dans la vie, même s'il porte
    /// le même nom : le diviseur est parfaitement valide.
    func testAQuotientThatDoesNotFitIsRefused() {
        // divl %ecx : le dividende est EDX:EAX. Avec EDX ≥ ECX, le quotient
        // dépasse trente-deux bits.
        var wide = core(rax: 0, rcx: 1, rdx: 1)
        XCTAssertThrowsError(try run([0xF7, 0xF1], on: &wide)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .divideError)
        }
        // divq %rcx : la même chose sur soixante-quatre bits.
        var full = core(rax: 0, rcx: 2, rdx: 3)
        XCTAssertThrowsError(try run([0x48, 0xF7, 0xF1], on: &full)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .divideError)
        }
        // Et le seul débordement de la division signée : le plus petit nombre
        // divisé par moins un, dont le résultat n'existe pas.
        var extreme = core(rax: 0x8000_0000_0000_0000, rcx: UInt64.max,
                           rdx: UInt64.max)
        XCTAssertThrowsError(try run([0x48, 0xF7, 0xF9], on: &extreme)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .divideError)
        }
    }

    /// La borne est **exacte** : le plus grand quotient qui tient passe.
    func testTheLargestQuotientThatFitsIsAccepted() throws {
        // divl : EDX:EAX = 0xFFFFFFFE, ECX = 1 → quotient 0xFFFFFFFE, qui tient.
        var machine = core(rax: 0xFFFF_FFFE, rcx: 1, rdx: 0)
        try run([0xF7, 0xF1], on: &machine)
        XCTAssertEqual(machine.registers[0], 0xFFFF_FFFE)
        XCTAssertEqual(machine.registers[2], 0)
    }

    /// Un opérande en mémoire est **refusé**, pas approximé. Ce cœur ne lit
    /// pas encore la mémoire ; répondre quand même serait pire que de ne pas
    /// répondre.
    func testAMemoryOperandIsRefusedAndNamed() {
        // 48 01 08 : add %rcx,(%rax) — mod vaut 00, donc la mémoire.
        var machine = core(rax: 0x1000, rcx: 1)
        XCTAssertThrowsError(try run([0x48, 0x01, 0x08], on: &machine)) { error in
            guard case .unsupported(let what) = error as? X86Core.Fault else {
                return XCTFail("attendu un refus nommé, obtenu \(error)")
            }
            XCTAssertTrue(what.contains("mémoire"), what)
        }
    }

    /// Une instruction vectorielle est refusée de même. Le décodeur sait où
    /// elle finit depuis la tranche 2 ; ce cœur ne sait pas ce qu'elle fait, et
    /// il le dit.
    func testAVectorInstructionIsRefusedAndNamed() {
        var machine = core()
        // c5 f8 57 c0 : vxorps %xmm0,%xmm0,%xmm0
        XCTAssertThrowsError(try run([0xC5, 0xF8, 0x57, 0xC0], on: &machine)) { error in
            guard case .unsupported(let what) = error as? X86Core.Fault else {
                return XCTFail("attendu un refus nommé, obtenu \(error)")
            }
            XCTAssertTrue(what.contains("vectorielle"), what)
        }
    }

    /// Un opcode que ce cœur n'exécute pas encore est **nommé**. « Non
    /// supporté » sans dire lequel obligerait à relire les octets à la main.
    func testAnOpcodeTheCoreDoesNotRunYetIsNamed() {
        var machine = core()
        // e8 00 00 00 00 : call — le décodeur le lit, le cœur ne saute pas encore.
        XCTAssertThrowsError(try run([0xE8, 0x00, 0x00, 0x00, 0x00], on: &machine)) { error in
            guard case .unsupported(let what) = error as? X86Core.Fault else {
                return XCTFail("attendu un refus nommé, obtenu \(error)")
            }
            XCTAssertTrue(what.contains("E8"), "il faut nommer l'opcode : \(what)")
        }
    }

    /// RIP avance de la longueur lue, pas d'une constante. C'est ce qui
    /// permettra à la tranche suivante d'enchaîner les instructions.
    func testTheInstructionPointerAdvancesByWhatWasRead() throws {
        var machine = core(rax: 1, rcx: 2)
        machine.rip = 0x1000
        try run([0x48, 0x01, 0xC8], on: &machine)  // add %rcx,%rax — trois octets
        XCTAssertEqual(machine.rip, 0x1003)
        try run([0x48, 0x05, 0x78, 0x56, 0x34, 0x12], on: &machine)  // six octets
        XCTAssertEqual(machine.rip, 0x1009)
    }

    /// RIP avance **même quand l'instruction refuse**… non : elle ne doit pas.
    /// Un refus laisse la machine où elle était, pour qu'on puisse regarder ce
    /// qui n'a pas marché.
    func testARefusalLeavesTheInstructionPointerWhereItWas() {
        var machine = core(rax: 1, rcx: 0)
        machine.rip = 0x2000
        XCTAssertThrowsError(try run([0x48, 0xF7, 0xF1], on: &machine))
        XCTAssertEqual(machine.rip, 0x2000, "un refus ne fait pas avancer la machine")
    }
}
