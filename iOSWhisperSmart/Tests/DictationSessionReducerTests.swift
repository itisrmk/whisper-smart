import XCTest
@testable import iOSWhisperSmart

final class DictationSessionReducerTests: XCTestCase {
    func testStartMovesToListening() {
        let state = DictationSessionReducer.reduce(state: .idle, event: .start)
        XCTAssertEqual(state, .listening)
    }

    func testPartialTranscriptState() {
        let state = DictationSessionReducer.reduce(state: .listening, event: .partial("hello"))
        XCTAssertEqual(state, .partial("hello"))
    }

    func testFinalTranscriptState() {
        let state = DictationSessionReducer.reduce(state: .partial("hel"), event: .final("hello"))
        XCTAssertEqual(state, .final("hello"))
    }

    func testErrorState() {
        let state = DictationSessionReducer.reduce(state: .listening, event: .fail("Mic denied"))
        XCTAssertEqual(state, .error("Mic denied"))
    }

    func testResetReturnsIdle() {
        let state = DictationSessionReducer.reduce(state: .error("Any"), event: .reset)
        XCTAssertEqual(state, .idle)
    }

    func testReplacementRulesApplyCaseInsensitiveWordBoundary() {
        let rules = [ReplacementRule(find: "cloo ai", replaceWith: "ClooAI")]
        let output = DictationTextPostProcessor.applyReplacementRules("please ping cloo ai about roadmap", rules: rules)
        XCTAssertEqual(output, "please ping ClooAI about roadmap")
    }

    func testMessageStyleAppliesSentenceCaseAndPunctuation() {
        let output = DictationTextPostProcessor.applyStyle("hello there team", style: .message)
        XCTAssertEqual(output, "Hello there team.")
    }

    func testEmailStyleWrapsBody() {
        let output = DictationTextPostProcessor.applyStyle("quick update we shipped phase 3", style: .email)
        XCTAssertTrue(output.hasPrefix("Hi,"))
        XCTAssertTrue(output.contains("Quick update we shipped phase 3."))
        XCTAssertTrue(output.hasSuffix("Best regards,"))
    }

    func testNotesStyleBuildsBullets() {
        let output = DictationTextPostProcessor.applyStyle("capture ideas. send recap", style: .notes)
        XCTAssertEqual(output, "• Capture ideas.\n• Send recap.")
    }
}
