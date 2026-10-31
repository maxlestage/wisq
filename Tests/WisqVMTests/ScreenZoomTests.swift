import XCTest
@testable import WisqVM

/// Zoomer sur l'écran de la machine locale : voir `ScreenZoom` et
/// `ScreenPointer`.
final class ScreenZoomTests: XCTestCase {
    /// **L'ajustement** : l'écran entier tient dans la vue, par le côté le
    /// plus serré. Un iPhone en portrait devant un écran de 1024 sur 768,
    /// c'est la largeur qui décide.
    func testTheFitIsTheTighterSide() throws {
        let portrait = try XCTUnwrap(ScreenZoom.fit(guestWidth: 1024, guestHeight: 768, viewWidth: 390, viewHeight: 600))
        XCTAssertEqual(portrait, 390.0 / 1024, accuracy: 1e-12)
        let landscape = try XCTUnwrap(ScreenZoom.fit(guestWidth: 1024, guestHeight: 768, viewWidth: 844, viewHeight: 300))
        XCTAssertEqual(landscape, 300.0 / 768, accuracy: 1e-12)
    }

    /// Sans écran ni vue, pas d'ajustement plutôt qu'une division par zéro.
    func testNoFitWithoutAScreenOrAView() {
        XCTAssertNil(ScreenZoom.fit(guestWidth: 0, guestHeight: 768, viewWidth: 390, viewHeight: 600))
        XCTAssertNil(ScreenZoom.fit(guestWidth: 1024, guestHeight: -1, viewWidth: 390, viewHeight: 600))
        XCTAssertNil(ScreenZoom.fit(guestWidth: 1024, guestHeight: 768, viewWidth: 0, viewHeight: 600))
        XCTAssertNil(ScreenZoom.fit(guestWidth: 1024, guestHeight: 768, viewWidth: 390, viewHeight: .nan))
        XCTAssertNil(ScreenZoom.fit(guestWidth: 1024, guestHeight: 768, viewWidth: .infinity, viewHeight: 600))
    }

    /// **Le zoom le plus fort rend la console lisible** : un caractère de
    /// huit pixels sur seize fait au moins quinze points de large sur un
    /// iPhone en portrait.
    func testTheStrongestZoomMakesTheConsoleReadable() throws {
        let fit = try XCTUnwrap(ScreenZoom.fit(guestWidth: 1024, guestHeight: 768, viewWidth: 390, viewHeight: 600))
        XCTAssertGreaterThan(8 * fit * ScreenZoom.maximum, 15)
        XCTAssertLessThan(8 * fit, 4, "ajusté, il ne l'est pas : c'est la capture du téléphone")
    }

    /// **Un glissement lent avance** : à deux points par pixel, dix pas
    /// d'un demi-point font deux pixels et demi, rendus au fil de l'eau.
    func testASlowDragStillMoves() {
        var pointer = ScreenPointer()
        var total = 0
        for _ in 0..<10 {
            if let step = pointer.move(dx: 0.5, dy: 0, pointsPerPixel: 2) { total += step.dx }
        }
        XCTAssertEqual(total, 2)
        XCTAssertEqual(pointer.remainderX, 0.5, accuracy: 1e-12)
    }

    /// **Le doigt suit le zoom** : le même glissement, zoomé quatre fois,
    /// déplace le pointeur de l'invité quatre fois moins.
    func testTheFingerFollowsTheZoom() throws {
        var fitted = ScreenPointer()
        var zoomed = ScreenPointer()
        let fit = 390.0 / 1024
        let wide = try XCTUnwrap(fitted.move(dx: 40, dy: -20, pointsPerPixel: fit))
        let fine = try XCTUnwrap(zoomed.move(dx: 40, dy: -20, pointsPerPixel: fit * 4))
        XCTAssertEqual(wide.dx, 105)
        XCTAssertEqual(wide.dy, -52)
        XCTAssertEqual(fine.dx, 26)
        XCTAssertEqual(fine.dy, -13)
    }

    /// Une échelle nulle ou absurde ne déplace rien et ne touche pas au reste.
    func testABrokenScaleMovesNothing() {
        var pointer = ScreenPointer()
        _ = pointer.move(dx: 0.75, dy: 0.25, pointsPerPixel: 1)
        let before = pointer
        XCTAssertNil(pointer.move(dx: 10, dy: 10, pointsPerPixel: 0))
        XCTAssertNil(pointer.move(dx: 10, dy: 10, pointsPerPixel: -2))
        XCTAssertNil(pointer.move(dx: 10, dy: 10, pointsPerPixel: .nan))
        XCTAssertNil(pointer.move(dx: .infinity, dy: 0, pointsPerPixel: 1))
        XCTAssertEqual(pointer, before)
    }

    /// Un zoom absurdement fin ne fait pas un pas qui arrêterait l'app en
    /// devenant un `Int`.
    func testAHugeStepIsBounded() throws {
        var pointer = ScreenPointer()
        let step = try XCTUnwrap(pointer.move(dx: 1, dy: -1, pointsPerPixel: 1e-300))
        XCTAssertEqual(step.dx, ScreenPointer.longestStep)
        XCTAssertEqual(step.dy, -ScreenPointer.longestStep)
    }

    /// **Le doigt levé oublie le reste** : sans ça, un glissement commencé
    /// plus tard partirait d'une fraction de l'ancien.
    func testLiftingTheFingerForgetsTheRemainder() {
        var pointer = ScreenPointer()
        XCTAssertNil(pointer.move(dx: 0.9, dy: -0.9, pointsPerPixel: 1))
        pointer.lift()
        XCTAssertEqual(pointer, ScreenPointer())
        XCTAssertNil(pointer.move(dx: 0.2, dy: -0.2, pointsPerPixel: 1), "0,9 ne revient pas")
    }
}
