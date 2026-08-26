import Foundation
import XCTest

@testable import WisqCore

/// The tolerance `Settings.swift` promises, and the tolerance it must not have.
///
/// The promise was half kept. "Every key is optional and falls back to its
/// default" was true of keys and false of *values*: a `scaling` or a
/// `longPressAction` this build did not recognise made the decoder throw. And
/// because `MachineStore` decodes `[Machine].self` in one go, that did not lose
/// the setting, or the machine — it lost the whole library, with no way back
/// from inside the app.
///
/// The second half of this file is the more important one. A rule has two
/// edges, and the edge here is that tolerance is right for presentation and
/// wrong for security: a `security` value nobody recognises must never quietly
/// become `.none`.
final class SettingsToleranceTests: XCTestCase {
    private func display(_ json: String) throws -> DisplaySettings {
        try JSONDecoder().decode(DisplaySettings.self, from: Data(json.utf8))
    }

    private func input(_ json: String) throws -> InputSettings {
        try JSONDecoder().decode(InputSettings.self, from: Data(json.utf8))
    }

    // MARK: - What a newer wisq may write

    /// A name from a future build falls back rather than throwing.
    func testAScalingThisBuildDoesNotKnowFallsBackToTheDefault() throws {
        XCTAssertEqual(try display(#"{"scaling":"pixelPerfect"}"#).scaling, DisplaySettings().scaling)
    }

    /// The same for all five fields that name a gesture or a pointer mode —
    /// checked one at a time, because a single JSON carrying five unknown names
    /// would go green on one working fallback and four broken ones.
    func testEveryNamedInputSettingFallsBackOnItsOwn() throws {
        let defaults = InputSettings()
        XCTAssertEqual(
            try input(#"{"pointerMode":"stylus"}"#).pointerMode, defaults.pointerMode)
        XCTAssertEqual(
            try input(#"{"longPressAction":"forceTouch"}"#).longPressAction, defaults.longPressAction)
        XCTAssertEqual(
            try input(#"{"twoFingerTapAction":"forceTouch"}"#).twoFingerTapAction,
            defaults.twoFingerTapAction)
        XCTAssertEqual(
            try input(#"{"twoFingerPanAction":"forceTouch"}"#).twoFingerPanAction,
            defaults.twoFingerPanAction)
        XCTAssertEqual(
            try input(#"{"threeFingerPanAction":"forceTouch"}"#).threeFingerPanAction,
            defaults.threeFingerPanAction)
    }

    /// An unknown name in one field leaves its neighbours alone. A fallback that
    /// reset the whole struct would pass every test above.
    func testAnUnknownNameDoesNotDisturbTheFieldsAroundIt() throws {
        let decoded = try input(
            #"{"longPressAction":"forceTouch","twoFingerTapAction":"middleClick","pointerSpeed":3.5}"#)
        XCTAssertEqual(decoded.twoFingerTapAction, .middleClick)
        XCTAssertEqual(decoded.pointerSpeed, 3.5)
        XCTAssertEqual(decoded.longPressAction, InputSettings().longPressAction)
    }

    /// The consequence that made this worth fixing: one machine's unreadable
    /// setting used to take the entire library with it, because the store
    /// decodes the array in one go.
    func testAWholeLibrarySurvivesASettingWrittenByANewerBuild() throws {
        let json = """
            [{"id":"11111111-1111-1111-1111-111111111111","name":"NAS","host":"nas.local",
              "port":5900,"proto":"vnc","security":"none","guestOS":"linux","tags":[],
              "createdAt":"2026-01-01T00:00:00Z",
              "display":{"scaling":"pixelPerfect"},"input":{}},
             {"id":"22222222-2222-2222-2222-222222222222","name":"Bureau","host":"bureau.local",
              "port":5900,"proto":"vnc","security":"none","guestOS":"linux","tags":[],
              "createdAt":"2026-01-01T00:00:00Z","display":{},"input":{}}]
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let machines = try decoder.decode([Machine].self, from: Data(json.utf8))
        XCTAssertEqual(machines.map(\.name), ["NAS", "Bureau"])
    }

    // MARK: - The other edge

    /// Half the work of a rule is what it must **not** do. Every name this build
    /// does know still means itself — a fallback wide enough to swallow the
    /// unknown must not swallow the known.
    func testEveryNameThisBuildKnowsStillMeansItself() throws {
        for scaling in DisplaySettings.Scaling.allCases {
            XCTAssertEqual(try display(#"{"scaling":"\#(scaling.rawValue)"}"#).scaling, scaling)
        }
        for action in GestureAction.allCases {
            XCTAssertEqual(
                try input(#"{"longPressAction":"\#(action.rawValue)"}"#).longPressAction, action)
        }
        for mode in InputSettings.PointerMode.allCases {
            XCTAssertEqual(try input(#"{"pointerMode":"\#(mode.rawValue)"}"#).pointerMode, mode)
        }
    }

    /// A damaged file is not a newer file. A number where a name belongs is not
    /// forward compatibility, and reading it as "use the default" would hide the
    /// damage instead of surviving it.
    func testAValueOfTheWrongShapeStillThrows() {
        XCTAssertThrowsError(try display(#"{"scaling":7}"#))
        XCTAssertThrowsError(try input(#"{"longPressAction":["rightClick"]}"#))
    }

    /// The asymmetry, pinned so nobody generalises the tolerance into it.
    ///
    /// `Machine.security` decides whether the connection is validated at all. An
    /// unrecognised name there must refuse, never fall back: `.none` is a
    /// meaningful value — plain TCP — so "default it" would be a silent
    /// downgrade of exactly the kind `ResolvedTransportSecurity` exists to
    /// prevent. Losing the library is the lesser harm; connecting unprotected to
    /// something the user marked otherwise is the greater one.
    func testAnUnknownSecurityRefusesRatherThanDowngrading() {
        let json = """
            {"id":"11111111-1111-1111-1111-111111111111","name":"NAS","host":"nas.local",
             "port":5900,"proto":"vnc","security":"tlsQuantum","guestOS":"linux","tags":[],
             "createdAt":"2026-01-01T00:00:00Z","display":{},"input":{}}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(Machine.self, from: Data(json.utf8)))
    }

    /// And the same for the protocol: falling back to VNC would open a VNC
    /// session against a port the user recorded for something else.
    func testAnUnknownProtocolRefusesRatherThanGuessing() {
        let json = """
            {"id":"11111111-1111-1111-1111-111111111111","name":"NAS","host":"nas.local",
             "port":5900,"proto":"wayland","security":"none","guestOS":"linux","tags":[],
             "createdAt":"2026-01-01T00:00:00Z","display":{},"input":{}}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(Machine.self, from: Data(json.utf8)))
    }
}
