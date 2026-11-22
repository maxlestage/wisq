import XCTest

@testable import WisqCore

/// L'adresse qu'écrit la liste des connexions à distance.
final class MachineDisplayAddressTests: XCTestCase {
    /// **Le port en chiffres nus.** Passé à `Text` comme un nombre, il était mis
    /// en forme selon la langue : « atelier.local:3,389 » sur une capture.
    func testThePortIsPlainDigits() {
        let machine = Machine(name: "Poste", host: "atelier.local", proto: .rdp)
        XCTAssertEqual(machine.displayAddress, "atelier.local:3389")
        XCTAssertEqual(Machine(name: "VM", host: "192.168.1.20", port: 15_930).displayAddress,
                       "192.168.1.20:15930")
    }

    /// Une adresse IPv6 entre crochets, une fois seulement.
    func testIPv6GoesBetweenBrackets() {
        XCTAssertEqual(Machine(name: "v6", host: "fe80::1", port: 5_900).displayAddress, "[fe80::1]:5900")
        XCTAssertEqual(Machine(name: "v6", host: "[fe80::1]", port: 5_900).displayAddress, "[fe80::1]:5900")
    }
}
