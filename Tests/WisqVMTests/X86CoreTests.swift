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

    /// Un `CALL` sans mémoire est refusé plutôt que d'écrire dans le vide :
    /// une pile est de la mémoire, et ce cœur n'en invente pas.
    func testCallWithoutMemoryIsRefused() {
        var machine = core()
        XCTAssertThrowsError(try run([0xE8, 0x00, 0x00, 0x00, 0x00], on: &machine)) { error in
            guard case .unsupported(let what) = error as? X86Core.Fault else {
                return XCTFail("attendu un refus nommé, obtenu \(error)")
            }
            XCTAssertTrue(what.contains("pile"), what)
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
        // 0f 05 : syscall — le décodeur le lit depuis la tranche 2, le cœur
        // n'a pas encore d'appel système à lui donner.
        XCTAssertThrowsError(try run([0x0F, 0x05], on: &machine)) { error in
            guard case .unsupported(let what) = error as? X86Core.Fault else {
                return XCTFail("attendu un refus nommé, obtenu \(error)")
            }
            XCTAssertTrue(what.contains("05"), "il faut nommer l'opcode : \(what)")
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

/// La machine autour du cœur : la mémoire, la boucle, le port série.
///
/// L'oracle matériel prouve déjà les branchements, la pile et les accès
/// mémoire — il exécute des programmes entiers et compare la fenêtre de
/// données. Ce qu'il ne peut pas prouver, c'est ce qui n'existe pas sur la
/// machine hôte : un port série émulé, et un `HLT` qui arrête la boucle au lieu
/// d'arrêter le processeur.
final class X86MachineTests: XCTestCase {
    func machine(_ program: [UInt8], memory size: Int = 0x4000) throws -> X86Core {
        let memory = X86Memory(size: size, base: 0x1000)
        try memory.load(program, at: 0x1000)
        var registers = [UInt64](repeating: 0, count: 16)
        registers[4] = 0x1000 + UInt64(size) - 0x100  // la pile, en haut
        return X86Core(registers: registers, rip: 0x1000, memory: memory)
    }

    /// `HLT` arrête la boucle et le **dit**. Sans ça, un budget épuisé et une
    /// machine arrêtée se ressembleraient.
    func testHaltStopsTheLoopAndSaysSo() throws {
        var core = try machine([0x48, 0xFF, 0xC0, 0xF4])  // incq %rax ; hlt
        let executed = try core.run(budget: 1000)
        XCTAssertEqual(executed, 2)
        XCTAssertTrue(core.halted)
        XCTAssertEqual(core.registers[0], 1)
    }

    /// Le budget est une borne, pas un vœu : une boucle infinie s'arrête.
    func testTheBudgetStopsAnEndlessLoop() throws {
        var core = try machine([0xEB, 0xFE])  // jmp .  — le saut sur soi-même
        let executed = try core.run(budget: 5000)
        XCTAssertEqual(executed, 5000)
        XCTAssertFalse(core.halted, "elle n'est pas arrêtée : elle a épuisé son budget")
        XCTAssertEqual(core.rip, 0x1000, "et elle est toujours au même endroit")
    }

    /// Le port série : ce par quoi un noyau Linux dit ses premiers mots avant
    /// d'avoir quoi que ce soit d'autre. `out %al, $0x3f8` — sauf que le port
    /// 0x3F8 ne tient pas dans l'immédiat d'un octet, donc il passe par DX.
    func testWhatGoesOutOfTheSerialPortIsKept() throws {
        // movw $0x3f8,%dx ; movb $0x77,%al ; outb %al,(%dx) ; hlt
        var core = try machine([0x66, 0xBA, 0xF8, 0x03, 0xB0, 0x77, 0xEE, 0xF4])
        try core.run(budget: 100)
        XCTAssertEqual(core.serialOutput, [0x77], "« w » est sorti par le port série")
    }

    /// Le registre d'état de la ligne dit « le transmetteur est vide ». Un
    /// noyau qui ne le lirait jamais vrai attendrait indéfiniment de pouvoir
    /// écrire — c'est un blocage silencieux, pas une erreur.
    func testTheLineStatusSaysTheTransmitterIsReady() throws {
        // movw $0x3fd,%dx ; inb (%dx),%al ; hlt
        var core = try machine([0x66, 0xBA, 0xFD, 0x03, 0xEC, 0xF4])
        try core.run(budget: 100)
        XCTAssertNotEqual(core.registers[0] & 0x20, 0, "le bit « prêt à émettre »")
    }

    /// Une adresse hors de la mémoire est une faute **nommée**, avec l'adresse
    /// qui l'a causée. Sans elle, on relit le programme à la main.
    func testAnAddressOutsideMemoryIsAFaultThatNamesIt() throws {
        // movq (%rax),%rcx avec rax à zéro, alors que la mémoire commence à
        // 0x1000.
        var core = try machine([0x48, 0x8B, 0x08])
        XCTAssertThrowsError(try core.run(budget: 10)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .pageFault(0))
        }
    }

    /// Le compteur d'instructions est ce qui donnera le chiffre de vitesse :
    /// il compte les instructions **retirées**, pas les tours de boucle.
    func testRetiredCountsInstructionsAndNotIterations() throws {
        // movl $3,%ecx ; 1: decl %ecx ; jnz 1b ; hlt
        //
        // Le déplacement vaut -4 et non -5 : il se compte depuis la **fin** du
        // saut. Je l'ai écrit -5 la première fois, et ce test l'a attrapé —
        // c'est exactement l'erreur d'un octet que le cœur, lui, ne fait pas.
        var core = try machine([0xB9, 0x03, 0x00, 0x00, 0x00, 0xFF, 0xC9, 0x75, 0xFC, 0xF4])
        try core.run(budget: 1000)
        // un mov, puis trois fois (dec + jnz), puis le hlt
        XCTAssertEqual(core.retired, 1 + 3 * 2 + 1)
        XCTAssertEqual(core.registers[1], 0)
    }
}
