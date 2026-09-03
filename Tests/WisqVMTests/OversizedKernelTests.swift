import XCTest

@testable import WisqVM

/// Ce qui arrive quand on donne à la machine une image qu'elle ne peut pas
/// contenir — le cas qui a fait disparaître l'application sur un vrai
/// téléphone, quand quelqu'un a essayé d'y démarrer une distribution.
final class OversizedKernelTests: XCTestCase {
    /// Le plafond n'est pas une politique : c'est ce qui reste de la RAM
    /// invitée une fois le DTB et l'état réservé placés en haut. Le test le
    /// recalcule autrement que la propriété, pour que les deux ne puissent pas
    /// se tromper ensemble.
    func testTheLimitIsWhatFitsUnderTheDeviceTree() {
        let limit = LinuxMachine.maximumKernelImageBytes
        XCTAssertGreaterThan(limit, 0)
        XCTAssertLessThan(limit, Int(LinuxMachine.ramSize))
        XCTAssertEqual(
            limit, Int(LinuxMachine.ramSize) - DefaultDTB.bytes.count - 192,
            "le plafond doit rester ce que la disposition mémoire laisse")
    }

    /// Une image d'un octet de trop est refusée, une image à la limite passe.
    /// Les deux bords, sinon un plafond faux passerait l'un des deux.
    func testAnImageOneByteTooBigIsRefusedAndTheLimitItselfIsAccepted() throws {
        let machine = LinuxMachine { _ in }
        let limit = LinuxMachine.maximumKernelImageBytes

        XCTAssertThrowsError(
            try machine.load(kernelImage: Data(repeating: 0, count: limit + 1))
        ) { error in
            XCTAssertEqual(error as? LinuxMachineError, .imageTooLarge)
        }
        XCTAssertNoThrow(try machine.load(kernelImage: Data(repeating: 0, count: limit)))
    }

    /// Ce que la personne lit. La phrase dit les deux nombres, parce qu'un
    /// seul n'explique rien, et dit où est la vraie voie.
    func testTheRefusalNamesBothTheFileAndTheMachine() {
        let twoGigabytes = 2 * 1024 * 1024 * 1024
        let message = LinuxMachine.tooLargeExplanation(size: twoGigabytes, name: "omarchy.iso")

        XCTAssertTrue(message.contains("omarchy.iso"), "le fichier doit être nommé")
        XCTAssertTrue(message.contains("2048.0 Mo"), "sa taille doit être dite")
        // La taille de la machine, dans une phrase qui la nomme comme telle.
        // Chercher « 64.0 Mo » seul ne suffisait pas : la part du noyau
        // s'affiche au même arrondi, et le test passait en trouvant l'une
        // pour l'autre — c'est un sabordage qui l'a dit.
        XCTAssertTrue(
            message.contains("64.0 Mo de mémoire en tout"),
            "la mémoire de la machine doit être dite, et dite comme le total")
        XCTAssertTrue(message.contains("rv32ima"), "et ce que cette machine est")
        XCTAssertTrue(message.contains("hôte"), "et où faire tourner une distribution")
    }

    /// Le vide aussi est refusé : il n'y a pas de noyau de zéro octet.
    func testAnEmptyImageIsRefused() {
        let machine = LinuxMachine { _ in }
        XCTAssertThrowsError(try machine.load(kernelImage: Data())) { error in
            XCTAssertEqual(error as? LinuxMachineError, .imageTooLarge)
        }
    }
}
