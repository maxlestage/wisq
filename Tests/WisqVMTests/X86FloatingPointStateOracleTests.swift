import XCTest

@testable import WisqVM

/// La zone de 512 octets de `FXSAVE`, contre le **vrai processeur**.
///
/// Neuvième corpus, même méthode que les huit précédents : la référence n'est
/// ni un document ni un autre émulateur, c'est la machine.
/// `scripts/build-x86-fxsave-oracle.py` fait charger 280 images par le
/// processeur de ce conteneur avec `FXRSTOR`, les fait réécrire avec `FXSAVE`,
/// et fige sa réponse dans `Tests/Fixtures/x86-fxsave-oracle.tsv`.
///
/// **Pourquoi ce corpus existe, et pourquoi maintenant.** Ces deux
/// instructions étaient là depuis le début, et elles écrivaient les trois mots
/// de contrôle en mettant le reste à zéro — les huit registres x87 et les
/// seize XMM. Le commentaire qui l'expliquait donnait sa raison : « rien ici ne
/// calcule en virgule flottante ». C'était vrai. Ça a cessé de l'être quand le
/// SSE2 entier, le flottant scalaire et la pile x87 sont entrés dans ce cœur,
/// et **personne n'est revenu relire la prémisse**.
///
/// Le prix : `/init` mourait. Le noyau partage le banc de registres avec le
/// programme ; il sauve l'état avant de s'en servir et le rend après. Ne rien
/// sauver et ne rien rendre laisse au programme les registres du noyau. Dans
/// `__towrite` de musl, `xmm1` portait `f->buf` et revenait à zéro, ce zéro
/// devenait `f->wpos`, et `__fwritex` le passait en destination à `memcpy`.
///
/// **Trois faits que seul le processeur pouvait donner**, et qu'aucune lecture
/// de manuel n'aurait fixés avec la même autorité :
///
///   * les huit registres x87 sont rangés dans l'ordre de la **pile** —
///     `ST(0)` d'abord, quel que soit le sommet ;
///   * le mot d'étiquettes abrégé, lui, est dans l'ordre **physique** : avec
///     le sommet à trois et le seul bit zéro levé, `FXAM` rend « vide » sur
///     `ST(0)` ;
///   * `FXSAVE` n'écrit que **416** octets sur 512. Une zone remplie de `0xCC`
///     retrouve ses quatre-vingt-seize derniers intacts.
///
/// **Ce que ce corpus ne tient pas, et le dit.** Les octets 5 à 23 — l'octet
/// réservé, `FOP`, `FIP` et `FDP` — sont mis à zéro dans l'entrée. Ce cœur ne
/// tient pas le pointeur d'instruction de la virgule flottante, et un corpus
/// qui l'exigerait ne mesurerait qu'un manque déjà connu au lieu de tenir ce
/// qui est là.
final class X86FloatingPointStateOracleTests: XCTestCase {
    static let area: UInt64 = 0x2000

    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-fxsave-oracle.tsv")
            .path
    }

    static func bytes(_ hex: Substring) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    func testTheCoreSavesAndRestoresWhatTheProcessorDoes() throws {
        let text = try String(contentsOfFile: Self.path, encoding: .utf8)
        var checked = 0
        var disagreements: [String] = []

        for line in text.split(separator: "\n") where line.hasPrefix("cas\t") {
            let columns = line.split(separator: "\t")
            guard columns.count == 4 else { continue }
            let index = columns[1]
            let before = Self.bytes(columns[2])
            let expected = Self.bytes(columns[3])

            let memory = X86Memory(size: 0x10000, base: 0)
            try memory.load(before, at: Self.area)
            var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                               rip: 0x1000, memory: memory)
            core.lastAddress = Self.area
            // On charge, puis on réécrit : le même aller-retour que le
            // processeur a fait. Ce qui se perd en route est ce que le format
            // abrège, et c'est justement ce qu'on veut voir se perdre pareil.
            try core.restoreFloatingPointState()
            // La zone est remplie d'un motif reconnaissable avant l'écriture :
            // sans ça, « FXSAVE n'a pas touché ces octets » serait
            // indiscernable de « FXSAVE y a écrit des zéros ».
            try memory.load([UInt8](repeating: 0xCC, count: 512), at: Self.area)
            try core.saveFloatingPointState()

            var produced: [UInt8] = []
            for offset in 0..<512 {
                produced.append(UInt8(truncatingIfNeeded:
                    try memory.read(Self.area &+ UInt64(offset), 1)))
            }
            checked += 1
            if Array(produced[0..<416]) != expected {
                let at = (0..<416).first { produced[$0] != expected[$0] } ?? 0
                disagreements.append(
                    "cas \(index) : octet \(at) rendu "
                    + String(format: "%02x", produced[at])
                    + " au lieu de " + String(format: "%02x", expected[at]))
            }
            if produced[416...].contains(where: { $0 != 0xCC }) {
                disagreements.append("cas \(index) : FXSAVE a écrit au-delà de 416")
            }
        }

        XCTAssertEqual(checked, 280, "le corpus doit être lu en entier")
        XCTAssertEqual(disagreements.count, 0,
                       "\(disagreements.count) désaccords\n"
                       + disagreements.prefix(10).joined(separator: "\n"))
    }
}
