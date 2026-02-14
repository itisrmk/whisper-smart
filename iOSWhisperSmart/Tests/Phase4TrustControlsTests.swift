import XCTest
@testable import iOSWhisperSmart

@MainActor
final class Phase4TrustControlsTests: XCTestCase {
    func testPrivacyModesMapToExistingEnginePolicies() {
        XCTAssertEqual(PrivacyMode.privateOffline.mappedEngine, .localApple)
        XCTAssertEqual(PrivacyMode.balanced.mappedEngine, .balanced)
        XCTAssertEqual(PrivacyMode.cloudFast.mappedEngine, .cloudOpenAI)
    }

    func testManualOnlyRetentionDoesNotPersistHistory() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")

        let store = TranscriptHistoryStore(retentionPolicy: .manualOnly, storageURL: tempURL)
        store.add(transcript: "hello", engine: .localApple, usedCloud: false)

        XCTAssertEqual(store.entries.count, 0)
    }

    func testRetentionCleanupRemovesEntriesOutsideWindow() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")

        let old = TranscriptEntry(
            id: UUID(),
            createdAt: Date().addingTimeInterval(-(10 * 24 * 60 * 60)),
            transcript: "old",
            engine: .localApple,
            usedCloud: false
        )
        let recent = TranscriptEntry(
            id: UUID(),
            createdAt: Date().addingTimeInterval(-(2 * 24 * 60 * 60)),
            transcript: "recent",
            engine: .balanced,
            usedCloud: true
        )

        try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = try JSONEncoder().encode([recent, old])
        try payload.write(to: tempURL)

        let store = TranscriptHistoryStore(retentionPolicy: .days7, storageURL: tempURL)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.transcript, "recent")
    }
}
