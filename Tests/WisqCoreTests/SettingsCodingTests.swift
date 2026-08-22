import XCTest
@testable import WisqCore

final class SettingsCodingTests: XCTestCase {
    /// Machines saved before a setting existed must still load, with the new
    /// setting at its default rather than the whole library failing to decode.
    func testInputSettingsDecodeWithMissingKeys() throws {
        let json = Data(#"{"pointerMode":"directTouch"}"#.utf8)
        let settings = try JSONDecoder().decode(InputSettings.self, from: json)

        XCTAssertEqual(settings.pointerMode, .directTouch)
        XCTAssertEqual(settings.longPressAction, .rightClick)
        XCTAssertEqual(settings.twoFingerPanAction, .scrollWheel)
        XCTAssertTrue(settings.inertia)
    }

    func testDisplaySettingsDecodeWithMissingKeys() throws {
        let settings = try JSONDecoder().decode(DisplaySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.scaling, .fit)
        XCTAssertTrue(settings.followDeviceResolution)
    }

    func testRoundTripPreservesEverything() throws {
        var settings = InputSettings()
        settings.twoFingerTapAction = .middleClick
        settings.threeFingerPanAction = .scrollWheel
        settings.pointerSpeed = 2.5

        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(InputSettings.self, from: data), settings)
    }

    func testMachineWithoutSettingsBlocksStillDecodes() throws {
        let json = Data("""
        [{"id":"6E1D4E52-0000-4000-8000-000000000001","name":"Vieux","host":"10.0.0.2",
          "port":5900,"proto":"vnc","security":"none","guestOS":"linux","tags":[],
          "createdAt":"2026-01-01T00:00:00Z","display":{},"input":{}}]
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let machines = try decoder.decode([Machine].self, from: json)

        XCTAssertEqual(machines.count, 1)
        XCTAssertEqual(machines[0].input.pointerMode, .trackpad)
    }
}
