import XCTest
@testable import WisqCore

final class HIDKeyMapTests: XCTestCase {
    func testLetters() {
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0x04), 0x61)   // a
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0x1D), 0x7A)   // z
    }

    func testDigitsWithZeroAtTheEndOfTheRun() {
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0x1E), 0x31)   // 1
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0x26), 0x39)   // 9
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0x27), 0x30)   // 0
    }

    func testFunctionKeys() {
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0x3A), Keysym.function(1))
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0x45), Keysym.function(12))
    }

    func testNavigationAndEditing() {
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0x28), Keysym.enter)
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0x2A), Keysym.backspace)
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0x2C), 0x20)   // space
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0x4F), Keysym.right)
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0x52), Keysym.up)
    }

    func testModifiers() {
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0xE0), Keysym.controlL)
        XCTAssertEqual(HIDKeyMap.keysym(forHIDUsage: 0xE3), Keysym.superL)   // Command
        XCTAssertTrue(HIDKeyMap.isModifier(hidUsage: 0xE3))
        XCTAssertFalse(HIDKeyMap.isModifier(hidUsage: 0x04))
    }

    func testUnknownUsagesAreRejectedRatherThanGuessed() {
        XCTAssertNil(HIDKeyMap.keysym(forHIDUsage: 0x00))
        XCTAssertNil(HIDKeyMap.keysym(forHIDUsage: 0xFF))
    }

    func testNoTwoDistinctKeysCollideOnTheSameKeysymByAccident() {
        // A duplicate would silently make one key type the other.
        var seen: [UInt32: Int] = [:]
        let expectedDuplicates: Set<UInt32> = [0x5C]   // backslash appears on three layouts
        for usage in 0x04...0xE7 {
            guard let keysym = HIDKeyMap.keysym(forHIDUsage: usage) else { continue }
            if let previous = seen[keysym], !expectedDuplicates.contains(keysym) {
                XCTFail("usages \(String(previous, radix: 16)) et \(String(usage, radix: 16)) partagent le keysym \(String(keysym, radix: 16))")
            }
            seen[keysym] = usage
        }
    }
}
