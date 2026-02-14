import XCTest

final class KeyboardTapInteractionUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments.append("-KeyboardTapHost")
        app.launch()
    }

    func testKeyboardControlsRespondToTap() throws {
        let textView = app.textViews["keyboard-host-text-view"]
        XCTAssertTrue(textView.waitForExistence(timeout: 8), "Keyboard host text view did not appear")
        textView.tap()

        let keyboardActivated = activateWhisperSmartKeyboard()
        if !keyboardActivated && !hasNextKeyboardControl() {
            throw XCTSkip("WhisperSmart keyboard cannot be activated because iOS is not exposing a next-keyboard control in this simulator configuration")
        }
        XCTAssertTrue(keyboardActivated, "Could not activate WhisperSmart keyboard")

        let clearButton = app.buttons["keyboard-host-clear"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 2))
        clearButton.tap()

        assertTapInserts("q", into: textView, expectedSuffix: "q")
        assertTapInserts("space", into: textView, expectedSuffix: "q ")
        assertTapInserts("return", into: textView, expectedSuffix: "q \n")

        assertTapInserts("123", into: textView, expectedSuffix: "q \n")
        assertTapInserts("1", into: textView, expectedSuffix: "q \n1")
        assertTapInserts("ABC", into: textView, expectedSuffix: "q \n1")
        assertTapInserts("a", into: textView, expectedSuffix: "q \n1a")

        tapKey(named: "⌫")
        XCTAssertEqual(normalizedTextValue(textView), "q \n1", "Backspace did not delete latest character")

        tapKey(named: "Insert Latest")
        XCTAssertEqual(normalizedTextValue(textView), "q \n1LATEST_SNIPPET", "Insert Latest did not append seeded transcript")

        if hasNextKeyboardControl() {
            tapNextKeyboard()
            XCTAssertTrue(waitForDisappearance(of: app.buttons["Insert Latest"], timeout: 3), "Globe key did not switch away from WhisperSmart")
            XCTAssertTrue(activateWhisperSmartKeyboard(), "Could not switch back to WhisperSmart keyboard")
        } else {
            XCTContext.runActivity(named: "Skipping keyboard-switch assertion: no next-keyboard control is exposed on this simulator") { _ in }
        }

        tapKey(named: "Mic")
        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 3), "Mic tap did not open dictation panel")

        if app.buttons["Cancel Dictation"].waitForExistence(timeout: 2) {
            app.buttons["Cancel Dictation"].tap()
            XCTAssertTrue(app.buttons["Insert Latest"].waitForExistence(timeout: 3), "Cancel dictation did not return to typing controls")
        }
    }

    @discardableResult
    private func activateWhisperSmartKeyboard() -> Bool {
        if app.buttons["Insert Latest"].waitForExistence(timeout: 1.5) {
            return true
        }

        guard hasNextKeyboardControl() else {
            return false
        }

        for _ in 0..<8 {
            tapNextKeyboard()
            if app.buttons["Insert Latest"].waitForExistence(timeout: 1.5) {
                return true
            }
        }

        return false
    }

    private func tapNextKeyboard() {
        let candidates = nextKeyboardCandidates()

        if let key = candidates.first(where: { $0.exists && $0.isHittable }) {
            key.tap()
            return
        }

        if let fallback = candidates.first(where: { $0.exists }) {
            fallback.tap()
            return
        }

        XCTFail("No globe/next keyboard control was found")
    }

    private func hasNextKeyboardControl() -> Bool {
        nextKeyboardCandidates().contains(where: { $0.exists })
    }

    private func nextKeyboardCandidates() -> [XCUIElement] {
        [
            app.buttons["Next Keyboard"],
            app.buttons["Next keyboard"],
            app.keys["🌐"],
            app.buttons["🌐"]
        ]
    }

    private func assertTapInserts(_ keyName: String, into textView: XCUIElement, expectedSuffix: String) {
        tapKey(named: keyName)
        XCTAssertTrue(
            normalizedTextValue(textView).hasSuffix(expectedSuffix),
            "Key \(keyName) tap did not update text as expected. Current value: \(normalizedTextValue(textView))"
        )
    }

    private func tapKey(named keyName: String) {
        let candidates: [XCUIElement] = [
            app.buttons[keyName],
            app.keys[keyName],
            app.otherElements[keyName]
        ]

        for candidate in candidates where candidate.exists {
            candidate.tap()
            return
        }

        XCTFail("Could not find key/button named \(keyName)")
    }

    private func normalizedTextValue(_ textView: XCUIElement) -> String {
        let raw = (textView.value as? String) ?? ""
        return raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return !element.exists
    }
}
