import XCTest

@testable import WisqCore
@testable import WisqRemote

/// La traduction des entrées : ce que l'application envoie, et ce qui part sur
/// le fil.
///
/// **Les deux modèles ne disent pas la même chose.** `InputEvent.pointer`
/// porte les boutons *tenus* ; RDP veut des transitions. Et une touche X11
/// n'est pas un code PC AT. Ces deux traductions sont exactement les endroits
/// où un clavier se met à mentir sans que rien ne le signale.
final class RDPSessionInputTests: XCTestCase {
    // MARK: - Le clavier

    /// **Le préfixe étendu passe dans un drapeau, pas dans la valeur.** SPICE
    /// le met dans la valeur ; les mélanger fait taper une touche du pavé
    /// numérique à la place d'une flèche.
    func testAnExtendedKeyMovesItsPrefixIntoTheFlag() throws {
        let up = try XCTUnwrap(RDPSession.scancode(forKeysym: Keysym.up))
        XCTAssertTrue(up.extended, "les flèches portent le préfixe E0")
        XCTAssertEqual(up.code, 0x48)
        XCTAssertLessThan(up.code, 0x100, "le préfixe ne doit plus être dans la valeur")
    }

    /// Une touche ordinaire n'a pas de préfixe.
    func testAnOrdinaryKeyHasNoPrefix() throws {
        let letter = try XCTUnwrap(RDPSession.scancode(forKeysym: Keysym.character("a")))
        XCTAssertFalse(letter.extended)
        XCTAssertEqual(letter.code, 0x1E)
    }

    /// **Une touche inconnue ne devient pas une autre touche.** Un code deviné
    /// tape le mauvais caractère, ce qui est pire que de ne rien taper : on voit
    /// un clavier qui ment plutôt qu'un clavier incomplet.
    func testAnUnknownKeyIsRefusedRatherThanGuessed() {
        XCTAssertNil(RDPSession.scancode(forKeysym: 0x0100_4E00))
    }

    // MARK: - La souris

    /// Sans changement de boutons, il ne part qu'un déplacement.
    func testAMoveAloneIsJustAMove() {
        let events = RDPSession.pointerEvents(from: [], to: [], x: 40, y: 50)
        XCTAssertEqual(events, [.pointer([.move], 40, 50)])
    }

    /// Un bouton pris s'enfonce.
    func testAButtonTakenGoesDown() {
        let events = RDPSession.pointerEvents(from: [], to: [.left], x: 1, y: 2)
        XCTAssertEqual(events, [.pointer([.move], 1, 2), .pointer([.left, .down], 1, 2)])
    }

    /// **Et un bouton lâché se relâche — sans quoi il resterait enfoncé.**
    /// C'est le défaut qui accroche une fenêtre au curseur : le serveur croit
    /// que le bouton n'a jamais été relâché.
    func testAButtonLetGoIsReleased() {
        let events = RDPSession.pointerEvents(from: [.left], to: [], x: 1, y: 2)
        XCTAssertEqual(events, [.pointer([.move], 1, 2), .pointer([.left], 1, 2)])
    }

    /// Un bouton tenu d'un événement à l'autre ne se renfonce pas.
    func testAButtonHeldIsNotPressedTwice() {
        let events = RDPSession.pointerEvents(from: [.left], to: [.left], x: 3, y: 4)
        XCTAssertEqual(events, [.pointer([.move], 3, 4)])
    }

    /// Les trois boutons ont chacun leur drapeau, et deux à la fois marchent.
    func testEachButtonHasItsOwnFlag() {
        let events = RDPSession.pointerEvents(from: [], to: [.left, .right], x: 0, y: 0)
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.contains(.pointer([.left, .down], 0, 0)))
        XCTAssertTrue(events.contains(.pointer([.right, .down], 0, 0)))
        let middle = RDPSession.pointerEvents(from: [], to: [.middle], x: 0, y: 0)
        XCTAssertTrue(middle.contains(.pointer([.middle, .down], 0, 0)))
    }

    /// **La molette n'a pas d'état.** Chaque cran est un événement à lui seul ;
    /// la traiter comme un bouton tenu ferait défiler une fois puis plus jamais.
    func testTheWheelIsAnEventNotAState() {
        let up = RDPSession.pointerEvents(from: [.scrollUp], to: [.scrollUp], x: 0, y: 0)
        XCTAssertEqual(up.count, 2, "un cran à chaque fois, même si le « bouton » ne change pas")
        XCTAssertTrue(RDPSession.wheelButtons.contains(.scrollUp))
        let down = RDPSession.pointerEvents(from: [], to: [.scrollDown], x: 0, y: 0)
        XCTAssertEqual(down.last, RDPInput.wheel(-1, at: (0, 0)))
        let sideways = RDPSession.pointerEvents(from: [], to: [.scrollRight], x: 0, y: 0)
        XCTAssertEqual(sideways.last, RDPInput.wheel(1, at: (0, 0), horizontal: true))
    }

    /// Et la position accompagne chaque événement, molette comprise : un cran
    /// de défilement s'applique sous le curseur.
    func testEveryEventCarriesThePosition() {
        let events = RDPSession.pointerEvents(from: [], to: [.left, .scrollUp], x: 700, y: 300)
        for event in events {
            guard case .pointer(_, let x, let y) = event else { return XCTFail("\(event)") }
            XCTAssertEqual(x, 700)
            XCTAssertEqual(y, 300)
        }
    }
}

/// Ce que la session promet à l'application avant même d'avoir parlé.
final class RDPSessionContractTests: XCTestCase {
    /// **Une session refusée doit finir**, sinon la vue attend pour toujours un
    /// événement qui ne viendra pas.
    func testASessionThatCannotConnectFinishesWithAnError() async throws {
        let configuration = SessionConfiguration(host: "203.0.113.1", port: 1,
                                                 security: .none)
        let session = RDPSession(configuration: configuration) { _ in
            throw WisqError.connectionFailed("pas de route")
        }
        await session.start()
        var last: WisqError?
        for await event in session.events {
            if case .disconnected(let error) = event { last = error }
        }
        guard case .connectionFailed? = last else {
            return XCTFail("attendu un échec de connexion, obtenu \(String(describing: last))")
        }
    }

    /// **Les entrées d'avant l'activation sont jetées, pas mises en file.**
    /// Une touche tapée pendant la poignée de main arriverait après, dans un
    /// contexte où elle ne veut plus rien dire.
    func testInputBeforeTheDesktopIsReadyIsDropped() async throws {
        let configuration = SessionConfiguration(host: "203.0.113.1", port: 1,
                                                 security: .none)
        let session = RDPSession(configuration: configuration) { _ in
            throw WisqError.connectionFailed("pas de route")
        }
        // Rien ne doit planter, et rien ne doit partir : il n'y a pas de socket.
        await session.send(.key(keysym: Keysym.character("a"), down: true))
        await session.send(.pointer(x: 1, y: 1, buttons: [.left]))
        await session.send(.clipboard("bonjour"))
        await session.stop()
    }
}
