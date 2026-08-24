import Foundation
import WisqCore
import XCTest
@testable import WisqRemote

/// What the app produces, turned into what SPICE takes.
///
/// The interesting part is not the encoding but the translation: `InputEvent`
/// speaks X11 keysyms and absolute coordinates, SPICE speaks PC scancodes and
/// its own button numbering, and nothing about the types stops one being passed
/// off as the other. `InputEvent.key`'s own comment claimed keysyms were "as
/// used by both RFB and SPICE" — they are not, and a session that forwarded
/// them unchanged would type nothing recognisable.
final class SpiceInputsTests: XCTestCase {
    // MARK: - Scancodes

    /// Spot-checked against the set-1 layout rather than against this table's
    /// own output, which would only prove it agrees with itself.
    func testLettersAndDigitsLandOnTheirRealScancodes() {
        XCTAssertEqual(SpiceScancode.scancode(forKeysym: 0x61), 0x1E, "a")
        XCTAssertEqual(SpiceScancode.scancode(forKeysym: 0x71), 0x10, "q")
        XCTAssertEqual(SpiceScancode.scancode(forKeysym: 0x7A), 0x2C, "z")
        XCTAssertEqual(SpiceScancode.scancode(forKeysym: 0x31), 0x02, "1")
        XCTAssertEqual(SpiceScancode.scancode(forKeysym: 0x30), 0x0B, "0, en fin de rangée")
        XCTAssertEqual(SpiceScancode.scancode(forKeysym: 0x20), 0x39, "espace")
    }

    /// A letter and its capital are one key. The guest applies Shift from the
    /// modifier sent alongside — the rule `HIDKeyMap` already follows.
    func testACapitalIsTheSameKeyAsItsLetter() {
        for scalar in UInt32(0x61)...0x7A {
            XCTAssertEqual(
                SpiceScancode.scancode(forKeysym: scalar),
                SpiceScancode.scancode(forKeysym: scalar - 0x20),
                "minuscule et majuscule doivent partager la touche"
            )
        }
    }

    /// A shifted symbol lives on an unshifted key. `?` is Shift and `/`, so it
    /// is the `/` scancode the guest needs.
    func testAShiftedSymbolSendsTheKeyItLivesOn() {
        XCTAssertEqual(
            SpiceScancode.scancode(forKeysym: 0x3F), SpiceScancode.scancode(forKeysym: 0x2F),
            "? est Maj et /"
        )
        XCTAssertEqual(
            SpiceScancode.scancode(forKeysym: 0x21), SpiceScancode.scancode(forKeysym: 0x31),
            "! est Maj et 1"
        )
        XCTAssertEqual(
            SpiceScancode.scancode(forKeysym: 0x3A), SpiceScancode.scancode(forKeysym: 0x3B),
            ": est Maj et ;"
        )
    }

    /// The extended keys carry `0xE0` in the high byte. Without it the arrows
    /// become the numeric keypad — a bug that reads as a broken keyboard rather
    /// than as a protocol error.
    func testTheExtendedKeysCarryTheirPrefix() {
        let expected: [(UInt32, UInt32)] = [
            (Keysym.up, 0xE048), (Keysym.down, 0xE050),
            (Keysym.left, 0xE04B), (Keysym.right, 0xE04D),
            (Keysym.home, 0xE047), (Keysym.end, 0xE04F),
            (Keysym.pageUp, 0xE049), (Keysym.pageDown, 0xE051),
            (Keysym.insert, 0xE052), (Keysym.delete, 0xE053),
        ]
        for (keysym, scancode) in expected {
            XCTAssertEqual(SpiceScancode.scancode(forKeysym: keysym), scancode)
        }
    }

    /// And the unextended ones do not, which is the other half of the same
    /// mistake: a prefix where none belongs is just as wrong.
    func testTheOrdinaryKeysCarryNoPrefix() {
        for keysym in [Keysym.escape, Keysym.tab, Keysym.enter, Keysym.backspace,
                       Keysym.shiftL, Keysym.controlL, Keysym.altL] {
            let scancode = try? XCTUnwrap(SpiceScancode.scancode(forKeysym: keysym))
            XCTAssertNotNil(scancode)
            XCTAssertLessThan(scancode ?? 0xFFFF, 0x100, "aucun préfixe attendu")
        }
    }

    /// A key with no scancode sends nothing. Guessing types the wrong
    /// character, and a keyboard that lies is worse than one that is
    /// incomplete.
    func testAnUnknownKeyIsRefusedRatherThanGuessed() {
        XCTAssertNil(SpiceScancode.scancode(forKeysym: 0x01FF), "keysym sans correspondance")
        XCTAssertNil(SpiceScancode.scancode(forKeysym: 0xFFAA))
        XCTAssertNil(SpiceScancode.scancode(forKeysym: 0))
        XCTAssertEqual(SpiceInputs.messages(for: .key(keysym: 0x01FF, down: true)).count, 0)
    }

    // MARK: - Pointer

    func testAPointerEventCarriesItsPositionAndTheButtonsHeld() throws {
        let messages = SpiceInputs.messages(for: .pointer(x: 300, y: 200, buttons: [.left]))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].type, SpiceInputs.ClientMessage.mousePosition)

        var reader = SpiceWire.Reader(messages[0].payload)
        XCTAssertEqual(try reader.u32(), 300)
        XCTAssertEqual(try reader.u32(), 200)
        XCTAssertEqual(try reader.u32(), 1, "bouton gauche")
        XCTAssertEqual(try reader.u8(), 0, "écran zéro")
        XCTAssertEqual(reader.remaining, 0)
    }

    /// The wheel is not a held button. A wheel bit in the mask would tell the
    /// guest the user is holding something they are not.
    func testTheWheelDoesNotAppearInTheHeldButtonMask() {
        XCTAssertEqual(SpiceInputs.buttonMask([.left, .right]), 0b101)
        XCTAssertEqual(SpiceInputs.buttonMask([.scrollUp, .scrollDown]), 0)
        XCTAssertEqual(SpiceInputs.buttonMask([.left, .scrollUp]), 0b001)
    }

    /// SPICE has no way to say "scrolled": a notch is a press and a release.
    /// Sending only the press leaves a button down forever.
    func testAWheelNotchIsAPressAndAReleaseNotAHeldButton() throws {
        let messages = SpiceInputs.messages(for: .pointer(x: 5, y: 6, buttons: [.scrollUp]))
        XCTAssertEqual(messages.count, 3, "position, appui, relâchement")
        XCTAssertEqual(messages[1].type, SpiceInputs.ClientMessage.mousePress)
        XCTAssertEqual(messages[2].type, SpiceInputs.ClientMessage.mouseRelease)

        var reader = SpiceWire.Reader(messages[1].payload)
        XCTAssertEqual(try reader.u32(), 4, "la molette vers le haut est le bouton 4")
        XCTAssertEqual(try reader.u32(), 0, "aucun bouton tenu pendant une molette")
    }

    func testScrollingDownIsTheOtherButton() throws {
        let messages = SpiceInputs.messages(for: .pointer(x: 0, y: 0, buttons: [.scrollDown]))
        var reader = SpiceWire.Reader(messages[1].payload)
        XCTAssertEqual(try reader.u32(), 5)
    }

    /// A drag with the wheel turned keeps the drag.
    ///
    /// The held mask travels with the wheel notch too, and that is deliberate:
    /// `buttons_state` says what is held *at that moment*, and during a drag
    /// the left button is. Reporting zero there would tell the guest the drag
    /// had ended and started again around every notch. What the mask must not
    /// contain is the wheel itself, which is pressed and released rather than
    /// held.
    func testAWheelNotchDuringADragKeepsTheDrag() throws {
        let messages = SpiceInputs.messages(
            for: .pointer(x: 1, y: 2, buttons: [.left, .scrollDown])
        )
        var position = SpiceWire.Reader(messages[0].payload)
        _ = try position.u32()
        _ = try position.u32()
        XCTAssertEqual(try position.u32(), 1, "le bouton gauche reste tenu")

        var press = SpiceWire.Reader(messages[1].payload)
        XCTAssertEqual(try press.u32(), 5, "la molette vers le bas")
        XCTAssertEqual(
            try press.u32(), 1,
            "le glisser continue : le bouton gauche est toujours tenu pendant le cran"
        )
    }

    /// The coordinate fields are unsigned. A negative one would wrap to four
    /// billion and put the pointer somewhere no screen reaches.
    func testANegativeCoordinateIsClampedRatherThanWrapped() throws {
        var reader = SpiceWire.Reader(
            SpiceInputs.mousePosition(x: -10, y: -1, buttons: [])
        )
        XCTAssertEqual(try reader.u32(), 0)
        XCTAssertEqual(try reader.u32(), 0)
    }

    // MARK: - Keys

    func testAKeyPressAndReleaseUseTheirOwnMessageTypes() throws {
        let down = SpiceInputs.messages(for: .key(keysym: 0x61, down: true))
        let up = SpiceInputs.messages(for: .key(keysym: 0x61, down: false))
        XCTAssertEqual(down[0].type, SpiceInputs.ClientMessage.keyDown)
        XCTAssertEqual(up[0].type, SpiceInputs.ClientMessage.keyUp)
        XCTAssertEqual(down[0].payload, up[0].payload, "même touche, même code")

        var reader = SpiceWire.Reader(down[0].payload)
        XCTAssertEqual(try reader.u32(), 0x1E)
    }

    /// The clipboard travels through the guest agent on the main channel, not
    /// here. Producing nothing is the correct answer, not a dropped event.
    func testClipboardIsNotThisChannelsBusiness() {
        XCTAssertEqual(SpiceInputs.messages(for: .clipboard("bonjour")).count, 0)
    }
}
