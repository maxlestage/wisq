import Foundation
import WisqVM
import WisqVMRust
import XCTest

/// Les deux cœurs, sur une machine qui n'a pas la taille de la référence.
///
/// Le redimensionnement touche le même endroit dans les deux : la cellule
/// mémoire du device tree, à l'offset 316, avec seize kibioctets réservés en
/// haut comme le blob de référence. Deux implémentations de la même règle est
/// exactement la situation où l'une dérive sans que personne le voie — c'est
/// ce que le test différentiel existe pour empêcher, et il n'avait jusqu'ici
/// jamais posé la question ailleurs qu'à 64 Mo.
///
/// La preuve est la même que pour le démarrage : après le même budget, les deux
/// doivent avoir retiré le même nombre d'instructions et écrit les mêmes
/// octets. Pas « à peu près la même sortie » : les mêmes octets. Et un noyau
/// qui annonce sa mémoire dedans, sinon les deux pourraient s'accorder sur
/// 64 Mo tout en ignorant le réglage.
final class DifferentialResizedTests: XCTestCase {
    private static func imageURL() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["WISQ_LINUX_IMAGE"],
            "/tmp/wisq-test-linux-image/Image",
        ]
        for case let path? in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private final class Console: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        func append(_ chunk: Data) {
            lock.lock()
            bytes.append(chunk)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: bytes, as: UTF8.self)
        }

        var snapshot: Data {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }
    }

    /// La ligne « Memory: … » du noyau, prise dans le texte de la console.
    ///
    /// Le séparateur est mesuré : la console termine ses lignes par CRLF, et en
    /// Swift la paire « \r\n » est *un seul* Character — un `split` sur « \n »
    /// ne coupe rien et rend tout le journal en une tranche.
    private static func memoryLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .first { $0.contains("Memory:") && $0.contains("available") }
            .map(String.init)
    }

    func testBothCoresResizeTheSameWay() throws {
        guard let url = Self.imageURL() else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: url)
        let large: UInt32 = 128 << 20

        let swiftConsole = Console()
        let rustConsole = Console()
        let swiftMachine = LinuxMachine(ramSize: large) { swiftConsole.append($0) }
        let rustMachine = RustLinuxMachine(ramSize: large) { rustConsole.append($0) }
        try swiftMachine.load(kernelImage: image, commandLine: "console=ttyS0")
        try rustMachine.loadOnTheSameBoard(kernelImage: image, commandLine: "console=ttyS0")

        let budget: UInt64 = 40_000_000
        XCTAssertEqual(swiftMachine.run(instructionBudget: budget), .stopped)
        XCTAssertEqual(rustMachine.run(instructionBudget: budget), .stopped)

        XCTAssertEqual(
            swiftMachine.retiredInstructions, rustMachine.retiredInstructions,
            "instructions retirées divergentes dans une machine de \(large >> 20) Mo")
        XCTAssertEqual(
            swiftConsole.snapshot, rustConsole.snapshot,
            "les deux consoles doivent être identiques dans une machine redimensionnée")

        // Et le noyau doit avoir vu la grande taille dans les deux : sans ça
        // les deux cœurs pourraient être d'accord en ignorant tous les deux le
        // réglage, ce qui satisferait les deux assertions au-dessus.
        guard let swiftLine = Self.memoryLine(swiftConsole.text),
              let rustLine = Self.memoryLine(rustConsole.text) else {
            return XCTFail(
                "ligne « Memory: » absente; Swift: \(swiftConsole.text.prefix(400))")
        }
        XCTAssertEqual(swiftLine, rustLine)
        // 128 Mio moins la réserve du haut, en kibioctets : 131 056.
        XCTAssertTrue(
            swiftLine.contains("131056K"),
            "le noyau doit annoncer 128 Mio moins la réserve; ligne : \(swiftLine)")
    }
}
