import XCTest
@testable import WisqVM

/// SHA-512 et l'empreinte `$6$`, contre les vecteurs que donnent leurs
/// spécifications, et contre `openssl passwd -6`.
final class SHA512CryptTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// FIPS 180-4 : « abc », la chaîne vide, et un message de deux blocs.
    func testSHA512MatchesTheStandardVectors() {
        XCTAssertEqual(hex(SHA512Crypt.sha512(Array("abc".utf8))),
                       "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                           + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        XCTAssertEqual(hex(SHA512Crypt.sha512([])),
                       "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"
                           + "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
        let twoBlocks = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopq"
            + "klmnopqrlmnopqrsmnopqrstnopqrstu"
        XCTAssertEqual(hex(SHA512Crypt.sha512(Array(twoBlocks.utf8))),
                       "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018"
                           + "501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909")
    }

    /// Les vecteurs de la spécification de SHA-crypt : le sel par défaut,
    /// un sel trop long (coupé à seize), des tours explicites, et un texte de
    /// plus de soixante-quatre octets.
    func testTheCryptHashMatchesTheSpecification() {
        XCTAssertEqual(SHA512Crypt.hash("Hello world!", salt: "saltstring"),
                       "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
        XCTAssertEqual(SHA512Crypt.hash("Hello world!", salt: "saltstringsaltstring", rounds: 10000),
                       "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v.")
        XCTAssertEqual(SHA512Crypt.hash("a very much longer text to encrypt.  This one even stretches over morethan one line.",
                                        salt: "anotherlongsaltstring", rounds: 1400),
                       "$6$rounds=1400$anotherlongsalts$POfYwTEok97VWcjxIiSOjiykti.o/pQs.wPvMxQ6Fm7I6IoYN3CmLs66x9t0oSwbtEW7o7UmJEiDwGqd8p4ur1")
    }

    /// Et ce que rend `openssl passwd -6 -salt wisqsalt wisq` sur la machine
    /// où ce test a été écrit.
    func testTheHashMatchesOpenSSL() {
        XCTAssertEqual(SHA512Crypt.hash("wisq", salt: "wisqsalt"),
                       "$6$wisqsalt$MD17UU57EA39WXKflUE5shqAnOtzXwVKihsVuI5Hyl00nkHl/7.cljF5qzTuSEzNO5/m6GsFDDKzxVE8Rvz0Z0")
    }
}
