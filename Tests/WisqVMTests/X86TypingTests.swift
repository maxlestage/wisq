import XCTest

@testable import WisqVM

/// **Un collage ne laisse jamais de touche enfoncée, et ne perd rien sans
/// le dire.**
///
/// Le défaut, le même que la carte Rust avait hérité de ce cœur et que
/// `crates/wisq-page/src/carte/i8042.rs` a corrigé : l'application versait
/// un texte frappe par frappe dans une file bornée frappe par frappe. Un
/// collage qui la remplissait au milieu d'une majuscule y laissait Maj et la
/// lettre enfoncées — l'invité les tenait pour de bon, Xorg répétait la
/// lettre sans fin — et la suite du texte disparaissait sans un mot.
///
/// Ces tests tiennent la règle à chaque étage : la file d'`X86Machine`
/// (entre les fils), celle du contrôleur, et `ScreenTypist`, qui garde ce qui
/// n'a pas tenu et le reprend dans l'ordre. Et, pour la console série, que
/// rien n'y est coupé.
final class X86TypingTests: XCTestCase {
    private let limit = X86PS2Controller.typingLimit

    private func machine() -> X86Machine {
        X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
    }

    /// Remplit la file de la machine de `a` jusqu'à ce qu'il n'y reste que
    /// `room` places.
    private func fill(_ pc: X86Machine, leaving room: Int) {
        let report = pc.type(String(repeating: "a", count: (limit - room) / 2))
        XCTAssertTrue(report.untyped.isEmpty)
        XCTAssertEqual(pc.pendingKeystrokes, limit - room)
    }

    // MARK: - La file d'X86Machine

    /// **Un long collage avec des majuscules s'arrête sur un caractère
    /// entier**, et rend ce qui reste à taper : rien n'est perdu, rien n'est
    /// coupé, aucune touche ne reste enfoncée.
    func testALongPasteWithCapitalsStopsOnAWholeCharacter() {
        let pc = machine()
        let text = String(repeating: "Hello, World! Ça VA ? ", count: 1_000)
        let report = pc.type(text)
        XCTAssertGreaterThan(report.typed, 1_000)
        XCTAssertFalse(report.untyped.isEmpty, "le collage ne tient pas entier")
        XCTAssertEqual(report.skipped, text.prefix(report.typed + report.skipped).filter { $0 == "Ç" }.count,
                       "le Ç de chaque phrase entrée, et rien d'autre")
        XCTAssertEqual(report.typed + report.skipped + report.untyped.count, text.count, "rien de perdu")
        XCTAssertEqual(report.untyped, text.dropFirst(report.typed + report.skipped), "la suite exacte")
        let strokes = pc.typingHandoff.strokes
        XCTAssertLessThanOrEqual(strokes.count, limit)
        XCTAssertGreaterThan(strokes.count, limit - 4, "plein, à un caractère près")
        XCTAssertEqual(X86KeystrokesTests.held(after: strokes), [], "aucune touche ne reste enfoncée")
        XCTAssertEqual(pc.type(report.untyped).typed, 0, "la file pleine n'en prend pas plus")
    }

    /// **Le texte s'arrête au premier caractère qui ne tient plus**, même si
    /// un suivant, plus court, tiendrait : sinon l'invité recevrait « b » à
    /// la place de « Ab », et le reste dans le désordre.
    func testTheTextStopsAtTheFirstCharacterThatDoesNotFit() {
        let pc = machine()
        fill(pc, leaving: 2)
        let report = pc.type("Ab")
        XCTAssertEqual(report.typed, 0, "A et Maj demandent quatre places")
        XCTAssertEqual(report.untyped, "Ab", "b attend derrière A")
        XCTAssertEqual(pc.pendingKeystrokes, limit - 2, "rien n'est entré, pas même Maj")
        XCTAssertEqual(pc.type("b").typed, 1, "deux places, deux frappes")
        XCTAssertEqual(pc.pendingKeystrokes, limit)
    }

    /// **La file pleine au milieu d'un caractère n'en prend rien** — trois
    /// places, quatre frappes —, et une touche de la barre (Ctrl, la lettre)
    /// est refusée entière elle aussi.
    func testAFullQueueInTheMiddleOfACharacterTakesNoneOfIt() {
        let pc = machine()
        fill(pc, leaving: 4)
        XCTAssertEqual(pc.type("a").typed, 1)
        XCTAssertEqual(pc.pendingKeystrokes, limit - 2)
        XCTAssertFalse(pc.press(X86Keystrokes.key(.control("c"))), "quatre frappes, deux places")
        XCTAssertFalse(pc.typingHandoff.held.contains(.leftControl), "Ctrl n'est pas restée")
        XCTAssertEqual(pc.type("Q").untyped, "Q")
        XCTAssertEqual(pc.pendingKeystrokes, limit - 2)
        XCTAssertTrue(pc.press(X86Keystrokes.key(.up)), "deux frappes, deux places")
    }

    /// **Le relâchement d'une touche que la file laisse enfoncée passe
    /// toujours**, même file pleine ; un autre ne passe pas.
    func testTheReleaseOfAKeyTheQueueHoldsAlwaysPasses() {
        let pc = machine()
        XCTAssertTrue(pc.key(.leftControl, down: true))
        XCTAssertFalse(pc.type(String(repeating: "x", count: limit)).untyped.isEmpty)
        XCTAssertEqual(pc.pendingKeystrokes, limit - 1)
        XCTAssertTrue(pc.key(.space, down: true), "la dernière place")
        XCTAssertFalse(pc.key(.leftAlt, down: true), "plus de place pour un enfoncement")
        XCTAssertFalse(pc.key(.leftAlt, down: false), "ni pour relâcher une touche relevée")
        XCTAssertTrue(pc.key(.leftControl, down: false), "Ctrl était tenue : son relâchement passe")
        XCTAssertTrue(pc.key(.space, down: false), "l'espace aussi")
        XCTAssertFalse(pc.key(.leftControl, down: false), "une seule fois")
        XCTAssertEqual(pc.pendingKeystrokes, limit + 2)
        XCTAssertEqual(X86KeystrokesTests.held(after: pc.typingHandoff.strokes), [])
    }

    /// **Ce que la machine admet, le contrôleur le prend entier**, compté
    /// avec ce que sa file tenait déjà : rien n'attend une deuxième tranche,
    /// rien n'est jeté entre les deux files.
    func testWhatTheMachineTakesTheControllerTakesWhole() {
        let pc = machine()
        for _ in 0..<1_000 { pc.core.devices.ps2.type(X86Keystrokes.keystrokes(X86Keystrokes.character("q"))) }
        pc.handTypingToTheController()
        XCTAssertEqual(pc.pendingKeystrokes, 2_000, "ce que le contrôleur tient est publié")
        let report = pc.type(String(repeating: "Wisq ", count: 2_000))
        XCTAssertFalse(report.untyped.isEmpty)
        XCTAssertLessThanOrEqual(pc.pendingKeystrokes, limit)
        let admitted = pc.typingHandoff.count
        pc.handTypingToTheController()
        XCTAssertEqual(pc.typingHandoff.count, 0, "tout est passé")
        XCTAssertEqual(pc.core.devices.ps2.typing.count, 2_000 + admitted)
        XCTAssertEqual(pc.pendingKeystrokes, 2_000 + admitted)
        XCTAssertTrue(pc.core.devices.ps2.heldInQueue.isEmpty)

        // Une touche de la barre se compte de même contre la file du
        // contrôleur : deux places, Ctrl-C n'entre pas, une flèche si.
        let bar = machine()
        for _ in 0..<(limit / 2 - 1) { bar.core.devices.ps2.type(X86Keystrokes.keystrokes(X86Keystrokes.character("q"))) }
        bar.handTypingToTheController()
        XCTAssertFalse(bar.press(X86Keystrokes.key(.control("c"))))
        XCTAssertTrue(bar.press(X86Keystrokes.key(.up)))
        XCTAssertFalse(bar.key(.space, down: true))
    }

    // MARK: - De bout en bout, par ScreenTypist

    /// **Un collage de dix mille caractères arrive entier sur le clavier de
    /// l'invité**, dans l'ordre, une touche de la barre comprise, en
    /// plusieurs passes — la file se vide au rythme d'une main et
    /// `ScreenTypist` reprend ce qui attend. Ce que le noyau lit au port 0x60
    /// est décodé ici, comme `atkbd` le ferait.
    func testALongPasteArrivesWholeThroughTheTypist() {
        let pc = machine()
        var typist = ScreenTypist()
        let paste = (0..<400).map { "Ligne \($0) : ECHO {ok} | grep -v \"é\"\r\n" }.joined()
        typist.type(paste, on: pc)
        XCTAssertFalse(typist.waiting.isEmpty, "trop long pour une seule passe")
        typist.press(X86Keystrokes.key(.control("c")), on: pc)
        typist.type("ls\n", on: pc)

        var bytes: [UInt8] = []
        var now: UInt64 = 0
        var rounds = 0
        repeat {
            rounds += 1
            pc.handTypingToTheController()
            while !pc.core.devices.ps2.typing.isEmpty {
                now += X86PS2Controller.holdTicks
                pc.core.devices.ps2.pace(now: now)
                while pc.core.devices.ps2.status() & 0x01 != 0 { bytes.append(pc.core.devices.ps2.readData()) }
            }
            pc.handTypingToTheController()
            typist.resume(on: pc)
        } while (!typist.waiting.isEmpty || pc.pendingKeystrokes > 0) && rounds < 100
        XCTAssertGreaterThan(rounds, 1)
        XCTAssertFalse(typist.note?.contains("Frappe en cours") ?? false)
        XCTAssertEqual(typist.skipped, 400, "les é, et eux seuls")

        let (typed, held) = Self.decode(bytes)
        let expected = paste.replacingOccurrences(of: "é", with: "").replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(typed.count, expected.count + 5)
        XCTAssertEqual(typed, expected + "^Cls\n", "tout, dans l'ordre")
        XCTAssertEqual(held, [], "le clavier de l'invité finit au repos")
    }

    /// **Annuler un collage l'arrête pour de bon, sans touche enfoncée**, et
    /// ce qu'on frappe ensuite part aussitôt. Le collage commence par une
    /// majuscule : l'invité tient Maj quand la personne annule.
    func testCancellingAPasteStopsItWithoutLeavingAKeyDown() {
        let pc = machine()
        var typist = ScreenTypist()
        typist.type(String(repeating: "Wisq ", count: 10_000), on: pc)
        XCTAssertTrue(typist.inProgress)
        pc.handTypingToTheController()

        var bytes: [UInt8] = []
        var now: UInt64 = 0
        func play() {
            now += X86PS2Controller.holdTicks
            pc.core.devices.ps2.pace(now: now)
            while pc.core.devices.ps2.status() & 0x01 != 0 { bytes.append(pc.core.devices.ps2.readData()) }
        }
        play()
        XCTAssertTrue(pc.core.devices.ps2.heldByGuest.contains(.leftShift), "Maj est partie, W pas encore")

        typist.cancel(on: pc)
        XCTAssertTrue(typist.waiting.isEmpty)
        XCTAssertEqual(pc.pendingKeystrokes, 0, "plus rien à jouer")
        XCTAssertFalse(typist.inProgress)
        typist.press(X86Keystrokes.key(.control("c")), on: pc)
        XCTAssertTrue(typist.waiting.isEmpty, "Ctrl-C entre aussitôt, sans attendre la tranche")

        pc.handTypingToTheController()
        XCTAssertEqual(pc.core.devices.ps2.typing.count, 1 + 4, "Maj relâchée, puis Ctrl-C")
        XCTAssertTrue(pc.core.devices.ps2.heldInQueue.isEmpty)
        while !pc.core.devices.ps2.typing.isEmpty { play() }
        let (typed, held) = Self.decode(bytes)
        XCTAssertEqual(typed, "^C", "rien du collage après l'annulation")
        XCTAssertEqual(held, [], "le clavier de l'invité finit au repos")
    }

    /// Ce qu'un noyau lit au port 0x60, en jeu 1 traduit, redevenu texte :
    /// Maj et Ctrl suivis, `^C` pour Ctrl-C. Rend aussi les touches restées
    /// enfoncées.
    static func decode(_ bytes: [UInt8]) -> (String, Set<UInt8>) {
        var reverse: [UInt16: Character] = [:]
        for (character, entry) in X86ScanCode.layout where character != "\r" && character != "\r\n" {
            reverse[UInt16(entry.0) | (entry.1 ? 0x100 : 0)] = character
        }
        var held: Set<UInt8> = []
        var text = ""
        var extended = false
        for byte in bytes {
            if byte == 0xE0 { extended = true; continue }
            defer { extended = false }
            let code = byte & 0x7F
            guard byte & 0x80 == 0 else { held.remove(code); continue }
            held.insert(code)
            if extended || code == X86ScanCode.leftShift.set1 || code == X86ScanCode.leftControl.set1 { continue }
            let shifted = held.contains(X86ScanCode.leftShift.set1)
            guard let character = reverse[UInt16(code) | (shifted ? 0x100 : 0)] else { continue }
            if held.contains(X86ScanCode.leftControl.set1) {
                text += "^" + character.uppercased()
            } else {
                text.append(character)
            }
        }
        return (text, held)
    }

    // MARK: - ScreenTypist, contre un faux clavier

    /// Un clavier qui prend `room` frappes, puis plus rien jusqu'à ce qu'on
    /// lui en redonne.
    private final class FakeKeyboard: ScreenKeyboard {
        var room = 0
        var log = ""
        /// Les frappes prises et pas encore jouées ; `abandonTyping` les jette.
        var queued = 0
        var abandons = 0

        var pendingKeystrokes: Int { queued }

        func abandonTyping() {
            abandons += 1
            queued = 0
        }

        func type(_ text: Substring) -> X86TypingReport {
            var report = X86TypingReport()
            var index = text.startIndex
            while index < text.endIndex {
                let strokes = X86Keystrokes.character(text[index]).count
                if strokes == 0 {
                    report.skipped += 1
                } else if strokes <= room {
                    room -= strokes
                    queued += strokes
                    log.append(text[index])
                    report.typed += 1
                } else {
                    break
                }
                index = text.index(after: index)
            }
            report.untyped = text[index...]
            return report
        }

        func press(_ events: [X86Keystrokes.Event]) -> Bool {
            guard events.count <= room else { return false }
            room -= events.count
            queued += events.count
            log += "<\(events.count)>"
            return true
        }
    }

    /// **Ce qui attend passe avant ce qui vient après** : un texte tapé ou
    /// une touche frappée pendant qu'un collage s'écrit encore vont derrière
    /// lui, jamais devant.
    func testWhatWaitsIsTypedInTheOrderItWasGiven() {
        let keyboard = FakeKeyboard()
        keyboard.room = 6
        var typist = ScreenTypist()
        typist.type("abcdef", on: keyboard)
        XCTAssertEqual(keyboard.log, "abc")
        XCTAssertEqual(typist.waitingCount, 3)
        typist.press(X86Keystrokes.key(.control("c")), on: keyboard)
        keyboard.room = 2
        typist.type("g", on: keyboard)
        XCTAssertEqual(keyboard.log, "abcd", "d d'abord, pas g")
        XCTAssertEqual(typist.note, "Frappe en cours : encore 4 caractères à taper sur l'écran.")
        keyboard.room = 100
        typist.resume(on: keyboard)
        XCTAssertEqual(keyboard.log, "abcdef<4>g")
        XCTAssertTrue(typist.waiting.isEmpty)
        XCTAssertEqual(typist.waitingCount, 0)
        XCTAssertNil(typist.note)
    }

    /// **Ce qui attend s'annule**, et ce qui vient ensuite part aussitôt :
    /// sans cela, une touche frappée après un gros collage attendrait derrière
    /// lui des heures. L'avis dit ce qui n'a pas été tapé.
    func testCancellingDropsWhatWaitsAndWhatComesNextGoesAtOnce() {
        let keyboard = FakeKeyboard()
        keyboard.room = 6
        var typist = ScreenTypist()
        typist.type("abcdef", on: keyboard)
        typist.press(X86Keystrokes.key(.control("c")), on: keyboard)
        XCTAssertEqual(keyboard.log, "abc")
        XCTAssertTrue(typist.inProgress)

        typist.cancel(on: keyboard)
        XCTAssertEqual(keyboard.abandons, 1, "la machine jette ce qu'elle n'a pas joué")
        XCTAssertTrue(typist.waiting.isEmpty)
        XCTAssertEqual(typist.waitingCount, 0)
        XCTAssertFalse(typist.inProgress)
        XCTAssertEqual(typist.note, "Frappe annulée : 4 caractères n'ont pas été tapés.")

        keyboard.room = 100
        typist.press(X86Keystrokes.key(.control("c")), on: keyboard)
        XCTAssertEqual(keyboard.log, "abc<4>", "Ctrl-C part aussitôt, rien du collage avant lui")
        XCTAssertNil(typist.note, "l'avis s'efface à l'action suivante")
    }

    /// **La frappe se dit en cours, et s'annule, tant que la machine a des
    /// secondes de frappe à jouer**, même quand plus rien n'attend ici : un
    /// collage de deux mille caractères tient entier dans sa file.
    func testTheMachinesQueueKeepsTheTypingInProgress() {
        let keyboard = FakeKeyboard()
        var typist = ScreenTypist()
        keyboard.queued = ScreenTypist.busyStrokes
        typist.resume(on: keyboard)
        XCTAssertTrue(typist.inProgress)
        XCTAssertEqual(typist.note, "Frappe en cours sur l'écran.")
        keyboard.queued = ScreenTypist.busyStrokes - 1
        typist.resume(on: keyboard)
        XCTAssertFalse(typist.inProgress, "quelques touches tapées ne font pas clignoter l'avis")
        XCTAssertNil(typist.note)
    }

    /// **Ce qui n'a pas pu être tapé est dit** : ce qu'un clavier américain
    /// n'a pas, et ce qui dépasse la borne de ce qui peut attendre.
    func testTheTypistSaysWhatItCouldNotType() {
        let keyboard = FakeKeyboard()
        keyboard.room = 100
        var typist = ScreenTypist()
        typist.type("café", on: keyboard)
        XCTAssertEqual(keyboard.log, "caf")
        XCTAssertEqual(typist.note, "1 caractère n'a pas été tapé : un clavier américain ne l'a pas "
                       + "(lettres accentuées, émojis, guillemets typographiques).")
        typist.type("ok", on: keyboard)
        XCTAssertNil(typist.note, "l'avis s'efface à l'action suivante")

        keyboard.room = 0
        typist.type(String(repeating: "z", count: ScreenTypist.limit + 3), on: keyboard)
        XCTAssertEqual(typist.waitingCount, ScreenTypist.limit, "gardé jusqu'à la borne")
        XCTAssertEqual(typist.refused, 3)
        typist.press(X86Keystrokes.key(.escape), on: keyboard)
        XCTAssertEqual(typist.refused, 4, "une touche de plus, refusée aussi")
        XCTAssertEqual(typist.note, "Frappe en cours : encore \(ScreenTypist.limit) caractères à taper sur l'écran. "
                       + "4 caractères n'ont pas été tapés : le texte est trop long pour le clavier de l'écran ; "
                       + "la console le prend d'un coup.")
    }

    // MARK: - La console série

    /// **Un long collage dans la console série arrive entier** : la machine
    /// le garde tant que l'invité ne l'a pas lu, l'instantané l'emporte, et
    /// le port le rend octet pour octet. Seuls les caractères de contrôle
    /// sont retirés, exprès (`TerminalPaste`) ; rien d'autre ne manque.
    func testALongPasteReachesTheSerialPortWhole() throws {
        let text = (0..<2_000).map { "ligne \($0)\tÉté « ok » 🙂\r\n" }.joined() + "\u{1B}[201~fin"
        let bytes = TerminalPaste.sending(text, afterTyped: "cat > f <<'X'\r", bracketed: true)
        let cleaned = TerminalPaste.cleaned(text)
        XCTAssertEqual(cleaned.unicodeScalars.count, text.unicodeScalars.count - 2_000 - 1,
                       "un \\n par ligne (\\r\\n en fait un \\r) et l'échappement, rien d'autre")
        XCTAssertGreaterThan(bytes.count, 50_000)

        let pc = machine()
        pc.send(bytes)
        let resumed = machine()
        try resumed.restore(pc.snapshot())
        XCTAssertEqual(resumed.core.serialInput, Array(bytes), "l'instantané emporte tout ce qui n'a pas été lu")

        var read: [UInt8] = []
        read.reserveCapacity(bytes.count)
        while resumed.core.portRead(0x3FD, 1) & 0x01 != 0 {
            read.append(UInt8(truncatingIfNeeded: resumed.core.portRead(0x3F8, 1)))
        }
        XCTAssertEqual(read, Array(bytes), "le port rend chaque octet, dans l'ordre")
    }
}
