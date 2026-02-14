import XCTest
@testable import iOSWhisperSmart

final class KeyboardCompanionStoreTests: XCTestCase {
    func testSaveAndLoadLatestTranscript() {
        let defaults = UserDefaults(suiteName: "KeyboardCompanionStoreTests.latest")!
        defaults.removePersistentDomain(forName: "KeyboardCompanionStoreTests.latest")
        let store = KeyboardCompanionStore(userDefaults: defaults)

        store.saveFinalTranscript("  hello world  ")

        XCTAssertEqual(store.latestTranscript, "hello world")
        XCTAssertNotNil(store.lastUpdatedAt)
    }

    func testRecentSnippetsAreDedupedAndCapped() {
        let defaults = UserDefaults(suiteName: "KeyboardCompanionStoreTests.snippets")!
        defaults.removePersistentDomain(forName: "KeyboardCompanionStoreTests.snippets")
        let store = KeyboardCompanionStore(userDefaults: defaults)

        for index in 0..<12 {
            store.saveFinalTranscript("snippet \(index)")
        }
        store.saveFinalTranscript("snippet 11")

        XCTAssertEqual(store.recentSnippets.count, 8)
        XCTAssertEqual(store.recentSnippets.first?.text, "snippet 11")
    }

    func testClearCacheRemovesSharedValues() {
        let defaults = UserDefaults(suiteName: "KeyboardCompanionStoreTests.clear")!
        defaults.removePersistentDomain(forName: "KeyboardCompanionStoreTests.clear")
        let store = KeyboardCompanionStore(userDefaults: defaults)

        store.saveFinalTranscript("hello")
        XCTAssertEqual(store.latestTranscript, "hello")

        store.clearCache()

        XCTAssertNil(store.latestTranscript)
        XCTAssertTrue(store.recentSnippets.isEmpty)
        XCTAssertNil(store.lastUpdatedAt)
    }
}
