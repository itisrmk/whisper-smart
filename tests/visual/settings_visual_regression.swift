import AppKit
import CryptoKit
import Foundation
import SwiftUI

private struct SnapshotCase {
    let id: String
    let tabRawValue: String
}

private enum Paths {
    static let baselineHashes = "tests/visual/baselines/settings_snapshot_hashes.json"
    static let snapshotOutputDirectory = ".build/visual-snapshots"
}

@main
struct SettingsVisualRegressionMain {
    static func main() {
        let updateMode = ProcessInfo.processInfo.environment["VISUAL_BASELINE_UPDATE"] == "1"
        let snapshotCases = [
            SnapshotCase(id: "settings-general", tabRawValue: "general"),
            SnapshotCase(id: "settings-hotkey", tabRawValue: "hotkey"),
            SnapshotCase(id: "settings-provider", tabRawValue: "provider"),
            SnapshotCase(id: "settings-history", tabRawValue: "history"),
        ]

        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let baselineURL = currentDirectory.appendingPathComponent(Paths.baselineHashes)
        let snapshotDirectoryURL = currentDirectory.appendingPathComponent(Paths.snapshotOutputDirectory, isDirectory: true)

        do {
            try fileManager.createDirectory(at: snapshotDirectoryURL, withIntermediateDirectories: true)
        } catch {
            fputs("Visual regression failure: could not create snapshot output directory: \(error)\n", stderr)
            exit(1)
        }

        var actualHashes: [String: String] = [:]
        for testCase in snapshotCases {
            guard let imageData = renderSettingsSnapshot(tabRawValue: testCase.tabRawValue) else {
                fputs("Visual regression failure: could not render snapshot \(testCase.id)\n", stderr)
                exit(1)
            }

            let hash = sha256Hex(imageData)
            actualHashes[testCase.id] = hash

            let fileURL = snapshotDirectoryURL.appendingPathComponent("\(testCase.id).png")
            do {
                try imageData.write(to: fileURL, options: .atomic)
            } catch {
                fputs("Visual regression failure: could not write snapshot \(testCase.id): \(error)\n", stderr)
                exit(1)
            }
        }

        if updateMode || !fileManager.fileExists(atPath: baselineURL.path) {
            do {
                try writeBaseline(actualHashes, to: baselineURL)
                print("✓ Visual baseline updated at \(baselineURL.path)")
                for key in actualHashes.keys.sorted() {
                    if let hash = actualHashes[key] {
                        print("  \(key): \(hash)")
                    }
                }
            } catch {
                fputs("Visual regression failure: could not update baseline hashes: \(error)\n", stderr)
                exit(1)
            }
            return
        }

        let expectedHashes: [String: String]
        do {
            let data = try Data(contentsOf: baselineURL)
            expectedHashes = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            fputs("Visual regression failure: could not read baseline hashes: \(error)\n", stderr)
            exit(1)
        }

        var failures: [String] = []
        for key in snapshotCases.map(\.id) {
            guard let actual = actualHashes[key] else {
                failures.append("\(key): missing actual hash")
                continue
            }
            guard let expected = expectedHashes[key] else {
                failures.append("\(key): missing expected baseline hash")
                continue
            }
            if actual != expected {
                failures.append("\(key): expected \(expected), got \(actual)")
            }
        }

        if failures.isEmpty {
            print("✓ Settings visual regression passed (\(snapshotCases.count) snapshots)")
            return
        }

        fputs("Visual regression failure:\n", stderr)
        for failure in failures {
            fputs("  - \(failure)\n", stderr)
        }
        fputs("Update baseline intentionally with VISUAL_BASELINE_UPDATE=1.\n", stderr)
        exit(1)
    }

    private static func writeBaseline(_ hashes: [String: String], to url: URL) throws {
        let sorted = hashes.keys.sorted().reduce(into: [String: String]()) { partialResult, key in
            partialResult[key] = hashes[key]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sorted)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func renderSettingsSnapshot(tabRawValue: String) -> Data? {
        let width = Int(VFSize.settingsWidth)
        let height = Int(VFSize.settingsHeight)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)

        // Enforce deterministic dark appearance while rendering.
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let view = SettingsView(initialTabRawValue: tabRawValue)
            .frame(width: CGFloat(width), height: CGFloat(height))
            .vfForcedDarkTheme()

        let host = NSHostingView(rootView: view)
        host.frame = rect
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        bitmap.size = NSSize(width: width, height: height)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [.compressionFactor: 1.0])
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
