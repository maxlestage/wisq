import XCTest

@testable import WisqVM

/// **FMA, F16C, et les conversions de largeur sur 256 bits**, contre le vrai
/// processeur.
///
/// `scripts/build-x86-fma-oracle.py` écrit les formes — les quatre familles
/// de FMA dans leurs trois ordres, `vcvtph2ps` et `vcvtps2ph` sous leurs huit
/// immédiats, les cinq conversions de largeur —, les fait exécuter par le
/// processeur de ce conteneur sur les états de x86-64-v2 (NaN, infinis, zéros
/// signés, sous-normales) et fige sa réponse dans
/// `Tests/Fixtures/x86-fma-oracle.tsv`. Le juge est celui du corpus VEX.256.
final class X86FMAOracleTests: XCTestCase {
    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/x86-fma-oracle.tsv")
            .path
    }

    func testTheCoreComputesWhatTheProcessorComputes() throws {
        try X86AVX256OracleTests.judge(Self.path, cases: 15000, instructions: 400)
    }

    /// **De ymm8 à ymm15**, que l'oracle ne nomme pas : un FMA fusionné —
    /// `(1 + 2⁻³⁰)² − 1` garde son `2⁻⁶⁰`, qu'un produit arrondi perdrait —,
    /// puis un aller-retour par la demi-précision.
    func testTheHighRegistersAreReached() throws {
        var core = try X86AVX256OracleTests.core([
            0xC4, 0x42, 0xB5, 0xB8, 0xC2,        // vfmadd231pd %ymm10, %ymm9, %ymm8
            0xC4, 0x43, 0x7D, 0x1D, 0xDC, 0x00,  // vcvtps2ph $0, %ymm11, %xmm12
            0xC4, 0x42, 0x7D, 0x13, 0xEC,        // vcvtph2ps %xmm12, %ymm13
        ])
        let near = (1.0 + 0x1p-30).bitPattern
        let minusOne = (-1.0).bitPattern
        X86AVX256OracleTests.setYMM(&core, 9, [near, near, near, 2.0.bitPattern])
        X86AVX256OracleTests.setYMM(&core, 10, [near, near, near, 3.0.bitPattern])
        X86AVX256OracleTests.setYMM(&core, 8, [minusOne, minusOne, minusOne, 1.0.bitPattern])
        let floats: [Float] = [1, -2, 0.5, 65504, 1e-7, -0.0, 3.140625, 100000]
        var packed = [UInt64](repeating: 0, count: 4)
        for (index, value) in floats.enumerated() {
            packed[index / 2] |= UInt64(value.bitPattern) << UInt64(32 * (index % 2))
        }
        X86AVX256OracleTests.setYMM(&core, 11, packed)
        for _ in 0..<3 { try core.execute(X86Decoder.decode(core.memory!.dump(core.rip, 15))) }
        let fused = 0x1p-29 + 0x1p-60
        XCTAssertEqual(X86AVX256OracleTests.ymm(core, 8), [fused.bitPattern, fused.bitPattern, fused.bitPattern,
                                                           7.0.bitPattern], "fusionné : 2⁻⁶⁰ gardé")
        XCTAssertEqual(X86AVX256OracleTests.ymm(core, 12)[2...], [0, 0], "vcvtps2ph efface le haut")
        let back = X86AVX256OracleTests.ymm(core, 13)
        let values = (0..<8).map { Float(bitPattern: UInt32(truncatingIfNeeded: back[$0 / 2] >> UInt64(32 * ($0 % 2)))) }
        // 10⁻⁷ vaut 1,68 fois la plus petite sous-normale, 2⁻²⁴ : il devient
        // 2⁻²³. 100 000 dépasse 65 504 et devient l'infini.
        XCTAssertEqual(values, [1, -2, 0.5, 65504, 0x1p-23, -0.0, 3.140625, .infinity])
    }

    /// **Ce qui n'existe pas reste refusé** : un FMA scalaire sous VEX.L, et
    /// `vcvtps2ph` sous VEX.W.
    func testWhatDoesNotExistIsRefused() throws {
        for bytes: [UInt8] in [[0xC4, 0xE2, 0xED, 0xB9, 0xC1], [0xC4, 0xE3, 0xFD, 0x1D, 0xC8, 0x00]] {
            var core = try X86AVX256OracleTests.core(bytes)
            XCTAssertThrowsError(try core.execute(X86Decoder.decode(core.memory!.dump(core.rip, 15))), "\(bytes)")
        }
    }
}
