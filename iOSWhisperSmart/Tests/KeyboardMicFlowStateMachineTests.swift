import XCTest
@testable import iOSWhisperSmart

final class KeyboardMicFlowStateMachineTests: XCTestCase {
    func testMicTappedMovesToWaiting() {
        let now = Date()
        let state = KeyboardMicFlowStateMachine.reduce(state: .typing, event: .micTapped(now: now))

        XCTAssertEqual(state, .dictationWaiting(startedAt: now))
    }

    func testTranscriptAvailableMovesWaitingToReady() {
        let startedAt = Date()
        let updatedAt = startedAt.addingTimeInterval(2)

        let state = KeyboardMicFlowStateMachine.reduce(
            state: .dictationWaiting(startedAt: startedAt),
            event: .transcriptAvailable(text: "hello world", updatedAt: updatedAt)
        )

        XCTAssertEqual(state, .dictationReady(transcript: "hello world", updatedAt: updatedAt))
    }

    func testCancelReturnsToTyping() {
        let state = KeyboardMicFlowStateMachine.reduce(
            state: .dictationReady(transcript: "done", updatedAt: Date()),
            event: .cancel
        )

        XCTAssertEqual(state, .typing)
    }

    func testConfirmReturnsToTyping() {
        let state = KeyboardMicFlowStateMachine.reduce(
            state: .dictationReady(transcript: "done", updatedAt: Date()),
            event: .confirm
        )

        XCTAssertEqual(state, .typing)
    }
}
