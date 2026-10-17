import XCTest
@testable import WisqVM

/// La taille du texte de la console : des crans, et des bornes qui tiennent.
final class ConsoleTextSizeTests: XCTestCase {

    /// Le défaut est la taille d'avant : rien ne bouge pour qui ne touche à rien.
    func testTheDefaultIsTheOldSizeAndAStep() {
        XCTAssertEqual(ConsoleTextSize.standard, 12)
        XCTAssertTrue(ConsoleTextSize.steps.contains(ConsoleTextSize.standard))
        XCTAssertEqual(ConsoleTextSize.steps, ConsoleTextSize.steps.sorted())
        XCTAssertEqual(Set(ConsoleTextSize.steps).count, ConsoleTextSize.steps.count)
    }

    /// « A+ » puis « A− » ramènent où l'on était, partout sauf aux bornes, où
    /// l'appui de trop ne fait rien.
    func testLargerThenSmallerIsTheIdentityAwayFromTheEnds() {
        for size in ConsoleTextSize.steps.dropLast() {
            XCTAssertEqual(ConsoleTextSize.smaller(than: ConsoleTextSize.larger(than: size)), size)
        }
        XCTAssertEqual(ConsoleTextSize.larger(than: 24), 24)
        XCTAssertEqual(ConsoleTextSize.smaller(than: 8), 8)
        XCTAssertFalse(ConsoleTextSize.canGrow(24))
        XCTAssertFalse(ConsoleTextSize.canShrink(8))
        XCTAssertTrue(ConsoleTextSize.canGrow(12))
        XCTAssertTrue(ConsoleTextSize.canShrink(12))
    }

    /// Une valeur enregistrée qui n'est pas un cran — une autre version, un
    /// fichier abîmé — retombe sur un cran, jamais sur une taille absurde.
    func testAnyStoredValueLandsOnAStep() {
        XCTAssertEqual(ConsoleTextSize.nearest(12.4), 12)
        XCTAssertEqual(ConsoleTextSize.nearest(15), 14, "à égale distance, le plus petit")
        XCTAssertEqual(ConsoleTextSize.nearest(0), 8)
        XCTAssertEqual(ConsoleTextSize.nearest(-3), 8)
        XCTAssertEqual(ConsoleTextSize.nearest(500), 24)
        XCTAssertEqual(ConsoleTextSize.nearest(.nan), 12)
        XCTAssertEqual(ConsoleTextSize.nearest(.infinity), 12)
        XCTAssertEqual(ConsoleTextSize.larger(than: 12.4), 13)
    }

    /// Un pincement donne un facteur ; la taille suit au cran le plus proche,
    /// bornée, et un facteur insensé laisse la taille où elle est.
    func testAPinchLandsOnTheNearestStep() {
        XCTAssertEqual(ConsoleTextSize.scaled(12, by: 1.5), 18)
        XCTAssertEqual(ConsoleTextSize.scaled(12, by: 0.5), 8, "6 points n'existe pas : le plus petit")
        XCTAssertEqual(ConsoleTextSize.scaled(12, by: 10), 24)
        XCTAssertEqual(ConsoleTextSize.scaled(12, by: 1.02), 12, "un frôlement ne change rien")
        XCTAssertEqual(ConsoleTextSize.scaled(12, by: 0), 12)
        XCTAssertEqual(ConsoleTextSize.scaled(12, by: -2), 12)
        XCTAssertEqual(ConsoleTextSize.scaled(12, by: .nan), 12)
    }
}
