import XCTest

@testable import WisqVM

/// **Ce qui traverse les moitiés d'un YMM**, contre le vrai processeur.
///
/// `scripts/build-x86-avx2-oracle.py` écrit les formes — diffusions,
/// insertions et extractions de 128 bits, permutations, mélanges par un
/// masque, décalages par élément, élargissements —, les fait exécuter par le
/// processeur de ce conteneur et fige sa réponse dans
/// `Tests/Fixtures/x86-avx2-oracle.tsv`. Les colonnes sont celles du corpus
/// VEX.256, et le juge aussi : `X86AVX256OracleTests.judge`.
final class X86AVX2OracleTests: XCTestCase {
    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-avx2-oracle.tsv")
            .path
    }

    func testTheCoreComputesWhatTheProcessorComputes() throws {
        try X86AVX256OracleTests.judge(Self.path, cases: 9000, instructions: 240)
    }

    /// **De ymm8 à ymm15**, que l'oracle ne nomme pas : `vpermq`,
    /// `vinserti128`, `vextracti128` et `vpbroadcastd`, calculés à la main.
    func testTheHighRegistersAreReached() throws {
        var core = try X86AVX256OracleTests.core([
            0xC4, 0x43, 0xFD, 0x00, 0xE1, 0x1B,  // vpermq $0x1b, %ymm9, %ymm12
            0xC4, 0x43, 0x2D, 0x38, 0xC3, 0x01,  // vinserti128 $1, %xmm11, %ymm10, %ymm8
            0xC4, 0x43, 0x7D, 0x39, 0xC5, 0x01,  // vextracti128 $1, %ymm8, %xmm13
            0xC4, 0x42, 0x7D, 0x58, 0xF1,        // vpbroadcastd %xmm9, %ymm14
        ])
        X86AVX256OracleTests.setYMM(&core, 9, [0x10, 0x11, 0x12, 0x13])
        X86AVX256OracleTests.setYMM(&core, 10, [0x20, 0x21, 0x22, 0x23])
        X86AVX256OracleTests.setYMM(&core, 11, [0x30, 0x31, 0x32, 0x33])
        for _ in 0..<4 { try core.execute(X86Decoder.decode(core.memory!.dump(core.rip, 15))) }
        XCTAssertEqual(X86AVX256OracleTests.ymm(core, 12), [0x13, 0x12, 0x11, 0x10], "vpermq à l'envers")
        XCTAssertEqual(X86AVX256OracleTests.ymm(core, 8), [0x20, 0x21, 0x30, 0x31], "le haut remplacé")
        XCTAssertEqual(X86AVX256OracleTests.ymm(core, 13), [0x30, 0x31, 0, 0], "le haut extrait, le reste effacé")
        XCTAssertEqual(X86AVX256OracleTests.ymm(core, 14), [0x10_0000_0010, 0x10_0000_0010, 0x10_0000_0010, 0x10_0000_0010])
    }

    /// **Ce qui reste refusé** : les ramassages (`vpgatherdd`), les
    /// conversions qui changent de largeur (`vcvtdq2pd` sur 256 bits), et une
    /// forme sans sens — `vpermq` sans VEX.W.
    func testWhatIsStillRefused() throws {
        for bytes: [UInt8] in [
            [0xC4, 0xE2, 0x75, 0x90, 0x04, 0x96], [0xC5, 0xFE, 0xE6, 0xC1], [0xC4, 0xE3, 0x7D, 0x00, 0xC1, 0x1B],
        ] {
            var core = try X86AVX256OracleTests.core(bytes)
            XCTAssertThrowsError(try core.execute(X86Decoder.decode(core.memory!.dump(core.rip, 15))), "\(bytes)")
        }
    }
}
