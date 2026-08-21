import CoreGraphics
import XCTest
@testable import Soma

final class GlobalVoiceModeTests: XCTestCase {
    func testMainKeyboardAndKeypadNumbersSelectTheSameModes() {
        XCTAssertEqual(VoiceOutputMode.mode(forKeyCode: 18), .original)
        XCTAssertEqual(VoiceOutputMode.mode(forKeyCode: 19), .english)
        XCTAssertEqual(VoiceOutputMode.mode(forKeyCode: 20), .prompt)
        XCTAssertEqual(VoiceOutputMode.mode(forKeyCode: 83), .original)
        XCTAssertEqual(VoiceOutputMode.mode(forKeyCode: 84), .english)
        XCTAssertEqual(VoiceOutputMode.mode(forKeyCode: 85), .prompt)
        XCTAssertNil(VoiceOutputMode.mode(forKeyCode: 21))
    }

    func testModeKeysAreOnlyConsumedWhileRightCommandIsHeld() {
        let capture = RightCommandModeKeyCapture()
        XCTAssertFalse(capture.shouldConsume(type: .keyDown, keyCode: 18))

        capture.setRightCommandDown(true)
        XCTAssertTrue(capture.shouldConsume(type: .keyDown, keyCode: 18))
        XCTAssertTrue(capture.shouldConsume(type: .keyUp, keyCode: 84))
        XCTAssertFalse(capture.shouldConsume(type: .keyDown, keyCode: 0))

        capture.setRightCommandDown(false)
        XCTAssertFalse(capture.shouldConsume(type: .keyUp, keyCode: 20))
    }

    func testPersistedSelectionIsTheCurrentDefault() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: VoiceOutputMode.storageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: VoiceOutputMode.storageKey)
            } else {
                defaults.removeObject(forKey: VoiceOutputMode.storageKey)
            }
        }

        VoiceOutputMode.persist(.english)
        XCTAssertEqual(VoiceOutputMode.current, .english)
    }
}
