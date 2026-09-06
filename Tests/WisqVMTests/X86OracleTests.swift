import XCTest

@testable import WisqVM

/// Le cœur contre le **vrai processeur**.
///
/// Pour un décodeur, la référence est un désassembleur. Pour un cœur qui
/// calcule, il n'y en a qu'une : la machine. Ce conteneur est un x86-64, donc
/// `scripts/build-x86-oracle.py` fait exécuter chaque instruction par le
/// processeur lui-même, avec des états d'entrée choisis, et fige sa réponse
/// dans `Tests/Fixtures/x86-oracle.tsv`. Ce test rejoue chaque cas dans
/// `X86Core` et exige le même résultat, registre par registre et drapeau par
/// drapeau.
///
/// **Ce que le fichier ne fige pas.** Là où le manuel dit « indéfini » — les
/// drapeaux d'état après un `MUL`, le débordement après un décalage de
/// plusieurs bits, tout sauf le zéro après un `BSF` — le processeur pose bien
/// une valeur, mais un autre processeur aurait le droit d'en poser une autre.
/// Chaque instruction porte donc un masque des drapeaux que l'architecture lui
/// garantit, et seuls ceux-là sont comparés. « Non affecté » reste dedans : un
/// drapeau qu'une instruction laisse tranquille a une valeur prévisible, et
/// c'est ainsi qu'on vérifie que `ROL` ne touche pas au zéro.
///
/// **Ce que l'oracle ne dit pas.** Une division par zéro, ou dont le quotient
/// déborde, lève une exception : la demander au processeur tuerait le harnais.
/// Ces deux cas-là sont tenus par des tests écrits à la main, dans
/// `X86CoreTests`, et c'est le seul endroit du cœur qui ne soit pas prouvé
/// contre la machine.
final class X86OracleTests: XCTestCase {
    struct State: Equatable {
        var rax: UInt64
        var rcx: UInt64
        var rdx: UInt64
        var flags: UInt64
    }

    struct Case {
        let instruction: Int
        let state: Int
        let after: State
        /// La fenêtre de mémoire après coup, ou nil quand elle n'a pas bougé.
        let memory: [UInt8]?
        /// **RSP, RBP, RSI et RDI.** Les quatre seuls registres que le corpus
        /// autorise à bouger — le générateur vérifie que les autres ne bougent
        /// pas — et donc les quatre seuls qu'il relève.
        ///
        /// Ce harnais ne les comparait pas, alors que les deux harnais Rust le
        /// font depuis longtemps. C'était une asymétrie réelle : un `leave` qui
        /// dépile avant de reprendre RBP, ou une chaîne qui n'avance pas RDI,
        /// laisse RAX, RCX, RDX, les drapeaux et la fenêtre de données
        /// exactement justes. Le cœur Swift était donc jugé moins sévèrement
        /// que les deux autres sur les registres qu'il est le plus facile de
        /// bouger de travers.
        let pointers: (UInt64, UInt64, UInt64, UInt64)
    }

    /// Les adresses du harnais, fixes pour que le fichier se reproduise.
    static let dataAddress: UInt64 = 0x3000_1000
    static let stackTop: UInt64 = 0x3000_3000
    static let windowSize = 64
    /// Le motif dont la fenêtre part.
    static var pristine: [UInt8] { (0..<windowSize).map { UInt8(0x10 + $0) } }
    /// **La fenêtre de pile, et son motif à deux moitiés.** Soixante-quatre
    /// octets sous RSP — ce qu'un `push` écrit — puis soixante-quatre au-dessus
    /// — ce qu'un `pop` relit. Les deux moitiés portent des motifs différents
    /// pour qu'on voie du premier coup de quel côté d'une pile un octet vient.
    ///
    /// Ce harnais ne la posait pas : la pile partait de zéros là où le
    /// processeur, lui, voyait ce motif. Aucun cas ne s'en plaignait parce
    /// qu'aucun ne lit la pile sans l'avoir écrite d'abord — mais c'est une
    /// coïncidence, pas une garantie, et la première instruction qui lirait
    /// au-dessus de RSP comparerait son résultat à celui d'un processeur parti
    /// d'ailleurs.
    static var stackPristine: [UInt8] {
        (0..<windowSize).map { UInt8(0xB0 + $0) } + (0..<windowSize).map { UInt8(0x40 + $0) }
    }

    struct Fixture {
        var states: [Int: State] = [:]
        var instructions: [Int: (bytes: [UInt8], mask: UInt64, text: String)] = [:]
        var cases: [Case] = []
        /// **La base du segment GS**, que le pilote de l'oracle pose par
        /// `arch_prctl` et qu'aucun registre ne montre. Optionnelle ici pour
        /// que son absence soit une faute nommée plus bas, et non un zéro
        /// silencieux : un cœur qui part de zéro lit la page zéro là où le
        /// silicium lisait la fenêtre de données, et tombe juste tant qu'aucun
        /// cas ne porte le préfixe.
        var gsBase: UInt64?
    }

    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-oracle.tsv")
            .path
    }

    static func read(_ path: String) throws -> Fixture {
        var fixture = Fixture()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for line in text.split(whereSeparator: \.isNewline) {
            let field = line.split(separator: "\t")
            guard let kind = field.first else { continue }
            func number(_ index: Int) -> UInt64 { UInt64(field[index], radix: 16) ?? 0 }
            switch kind {
            case "état" where field.count >= 6:
                fixture.states[Int(field[1]) ?? -1] = State(
                    rax: number(2), rcx: number(3), rdx: number(4), flags: number(5))
            case "instr" where field.count >= 5:
                var bytes: [UInt8] = []
                let hex = field[2]
                var index = hex.startIndex
                while index < hex.endIndex {
                    let next = hex.index(index, offsetBy: 2)
                    bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
                    index = next
                }
                fixture.instructions[Int(field[1]) ?? -1] = (
                    bytes, number(3), String(field[4]))
            case "segment" where field.count >= 3 && field[1] == "gs":
                fixture.gsBase = number(2)
            case "cas" where field.count >= 13:
                var window: [UInt8]?
                if field[7] != "-" {
                    let hex = field[7]
                    var bytes: [UInt8] = []
                    var index = hex.startIndex
                    while index < hex.endIndex {
                        let next = hex.index(index, offsetBy: 2)
                        bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
                        index = next
                    }
                    window = bytes
                }
                fixture.cases.append(Case(
                    instruction: Int(field[1]) ?? -1, state: Int(field[2]) ?? -1,
                    after: State(rax: number(3), rcx: number(4),
                                 rdx: number(5), flags: number(6)),
                    memory: window,
                    pointers: (number(9), number(10), number(11), number(12))))
            default:
                continue
            }
        }
        return fixture
    }

    /// Le témoin des douze registres qu'aucun cas ne doit toucher. Le
    /// générateur vérifie déjà que le processeur ne les change pas ; c'est ici
    /// qu'on exige la même chose du cœur.
    static func witness() -> [UInt64] {
        (0..<16).map { 0xAAAA_AAAA_AAAA_AAAA &+ UInt64($0) }
    }

    func testTheCoreAnswersWhatTheProcessorAnswers() throws {
        let fixture = try Self.read(Self.path)
        XCTAssertGreaterThan(fixture.cases.count, 5000, "l'oracle doit couvrir, pas illustrer")
        XCTAssertGreaterThan(fixture.instructions.count, 200)
        // Un enregistrement que ce lecteur ne connaît pas est ignoré en
        // silence, exprès ; celui-ci ne doit pas l'être.
        let gsBase = try XCTUnwrap(
            fixture.gsBase, "l'oracle doit déclarer la base du segment GS")

        var disagreements: [String] = []
        var byInstruction: [String: Int] = [:]
        var agreed = 0
        for item in fixture.cases {
            guard let before = fixture.states[item.state],
                  let program = fixture.instructions[item.instruction]
            else {
                XCTFail("cas orphelin : instruction \(item.instruction), état \(item.state)")
                continue
            }
            var registers = Self.witness()
            registers[0] = before.rax
            registers[1] = before.rcx
            registers[2] = before.rdx
            registers[4] = Self.stackTop
            registers[6] = Self.dataAddress
            // La même mémoire que le harnais : le code là où il l'a mis, la
            // fenêtre au même motif, et la pile qui descend depuis le haut.
            let memory = X86Memory(size: 0x4000, base: 0x3000_0000)
            try? memory.load(program.bytes, at: 0x3000_0000)
            try? memory.load(Self.pristine, at: Self.dataAddress)
            try? memory.load(Self.stackPristine, at: Self.stackTop - UInt64(Self.windowSize))
            var core = X86Core(
                registers: registers, flags: before.flags | X86Core.Flag.reserved,
                rip: 0x3000_0000, memory: memory)
            // La base du segment appartient à la machine, pas à l'instruction :
            // le pilote la pose une fois pour toutes avant le premier cas, et
            // ici elle se pose de même, sur le MSR que le noyau écrirait.
            core.system.modelSpecific[X86SystemState.gsBase] = gsBase
            do {
                // Le harnais exécute tout ce qu'on lui a donné : un programme
                // entier, pas seulement sa première instruction. Le budget est
                // large, la boucle s'arrête d'elle-même en sortant du code.
                // Le budget compte les **instructions**, pas les octets : une
                // boucle en exécute bien plus qu'elle n'en pèse, et la première
                // version s'arrêtait au milieu.
                var remaining = 10_000
                while core.rip < 0x3000_0000 &+ UInt64(program.bytes.count) && remaining > 0 {
                    let instruction = try X86Decoder.decode(
                        memory.dump(core.rip, min(15, 0x4000 - Int(core.rip - 0x3000_0000))))
                    try core.execute(instruction)
                    remaining -= 1
                }
            } catch {
                byInstruction[program.text, default: 0] += 1
                if disagreements.count < 15 {
                    disagreements.append("  \(program.text) : refusé — \(error)")
                }
                continue
            }
            let after = State(
                rax: core.registers[0], rcx: core.registers[1], rdx: core.registers[2],
                flags: core.flags & X86Core.Flag.arithmetic)
            // RSP, RBP, RSI et RDI sont exclus de ce témoin-là : les
            // programmes qui posent un cadre de pile ou parcourent la mémoire
            // s'en servent, et c'est justement ce qu'ils prouvent. Ils sont
            // comparés juste en dessous, à ce que le processeur a rendu.
            let untouched = ([3] + Array(8...15)).allSatisfy {
                core.registers[$0] == Self.witness()[$0]
            }
            let pointers = (
                core.registers[4], core.registers[5], core.registers[6], core.registers[7])
            let samePointers = pointers == item.pointers
            // Seuls les drapeaux que l'architecture définit pour cette
            // instruction sont comparés ; le reste, le manuel le dit indéfini,
            // et un autre processeur aurait le droit d'y répondre autrement.
            let mask = program.mask
            let sameFlags = after.flags & mask == item.after.flags & mask
            let sameRegisters = after.rax == item.after.rax && after.rcx == item.after.rcx
                && after.rdx == item.after.rdx
            let window = memory.dump(Self.dataAddress, Self.windowSize)
            let sameMemory = window == (item.memory ?? Self.pristine)
            if sameFlags && sameRegisters && sameMemory && untouched && samePointers {
                agreed += 1
            } else {
                byInstruction[program.text, default: 0] += 1
                guard disagreements.count < 12 else { continue }
                disagreements.append(
                    "  \(program.text) [état \(item.state)] "
                        + "rax \(hex(before.rax)) rcx \(hex(before.rcx)) "
                        + "drapeaux \(hex(before.flags))\n"
                        + "      processeur : rax \(hex(item.after.rax)) "
                        + "rcx \(hex(item.after.rcx)) rdx \(hex(item.after.rdx)) "
                        + "drapeaux \(hex(item.after.flags))\n"
                        + "      wisq       : rax \(hex(after.rax)) rcx \(hex(after.rcx)) "
                        + "rdx \(hex(after.rdx)) drapeaux \(hex(after.flags))"
                        + (untouched ? "" : "\n      et il a écrit dans un registre témoin")
                        + (sameMemory ? "" : "\n      et la mémoire diffère")
                        + (samePointers
                            ? ""
                            : "\n      processeur : rsp \(hex(item.pointers.0)) "
                                + "rbp \(hex(item.pointers.1)) rsi \(hex(item.pointers.2)) "
                                + "rdi \(hex(item.pointers.3))\n"
                                + "      wisq       : rsp \(hex(pointers.0)) "
                                + "rbp \(hex(pointers.1)) rsi \(hex(pointers.2)) "
                                + "rdi \(hex(pointers.3))"))
            }
        }
        let summary = byInstruction.sorted { $0.value > $1.value }
            .map { "  \($0.key) × \($0.value)" }.joined(separator: "\n")
        XCTAssertEqual(
            agreed, fixture.cases.count,
            "\(fixture.cases.count - agreed) désaccords sur \(fixture.cases.count).\n"
                + "PAR INSTRUCTION :\n\(summary)\nDÉTAIL :\n"
                + disagreements.joined(separator: "\n"))
    }

    func hex(_ value: UInt64) -> String { String(value, radix: 16) }
}
