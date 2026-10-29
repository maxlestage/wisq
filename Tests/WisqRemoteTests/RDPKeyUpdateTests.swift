import Foundation
import XCTest

@testable import WisqRemote

/// **Une clé RC4 sert à 4 096 paquets dans son sens, puis se renouvelle**
/// (MS-RDPBCGR 5.3.7). Rien ne la renouvelait : la session mourait au
/// 4 097ᵉ message, dans un sens ou dans l'autre.
final class RDPKeyUpdateTests: XCTestCase {
    static func hex(_ text: String) -> [UInt8] {
        stride(from: 0, to: text.count, by: 2).map {
            let start = text.index(text.startIndex, offsetBy: $0)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    /// La formule, calculée à part — `hashlib` pour SHA-1 et MD5, un RC4
    /// écrit à côté — sur des clés choisies : deux renouvellements de suite
    /// en 128 bits, un en 40 et un en 56.
    func testTheNextKeyIsTheOneTheFormulaGives() {
        let initial = [UInt8](0..<16), current = [UInt8](16..<32)
        let once = RDPStandardSecurity.updatedKey(initial: initial, current: current, method: 2)
        XCTAssertEqual(once, Self.hex("0c15dc15b1c7c9cbb033a0fd8e136710"))
        XCTAssertEqual(RDPStandardSecurity.updatedKey(initial: initial, current: once, method: 2),
                       Self.hex("7deb8c84e6fd5cfa837aa30a89b9fc44"), "le deuxième repart de la clé de départ")
        let short = [UInt8](0..<8), now = [UInt8](8..<16)
        XCTAssertEqual(RDPStandardSecurity.updatedKey(initial: short, current: now, method: 1),
                       Self.hex("d1269e99a450041b"), "quarante bits : trois octets imposés")
        XCTAssertEqual(RDPStandardSecurity.updatedKey(initial: short, current: now, method: 8),
                       Self.hex("d1655599a450041b"), "cinquante-six bits : un")
    }

    /// **Les deux bouts renouvellent au même paquet.** Un serveur imité —
    /// les clés du client, vues de l'autre côté — ouvre dix mille messages de
    /// suite, deux renouvellements compris.
    func testBothEndsRenewAtTheSamePacket() throws {
        let keys = try RDPStandardSecurity.deriveKeys(
            clientRandom: [UInt8](repeating: 0x11, count: 32), serverRandom: [UInt8](repeating: 0x22, count: 32),
            method: 2)
        var client = RDPStandardSecurity(keys: keys)
        var server = RDPStandardSecurity(keys: RDPStandardSecurity.Keys(
            macKey: keys.macKey, clientToServer: keys.serverToClient, serverToClient: keys.clientToServer,
            initialClientToServer: keys.initialServerToClient, initialServerToClient: keys.initialClientToServer,
            method: keys.method))
        for index in 0..<10_000 {
            let message = Data("message \(index)".utf8)
            let sealed = client.seal(message)
            XCTAssertEqual(try server.open(sealed), message, "message \(index)")
        }
    }
}
