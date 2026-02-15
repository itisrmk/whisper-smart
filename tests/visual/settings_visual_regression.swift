import AppKit
import Foundation
import SwiftUI

private struct SnapshotCase {
    let id: String
    let tabRawValue: String
}

private enum Paths {
    static let baselineDirectory = "tests/visual/baselines"
    static let snapshotOutputDirectory = ".build/visual-snapshots"
}

@main
struct SettingsVisualRegressionMain {
    static func main() {
        let updateMode = ProcessInfo.processInfo.environment["VISUAL_BASELINE_UPDATE"] == "1"
        let maxDiff = ProcessInfo.processInfo.environment["VISUAL_MAX_DIFF"]
            .flatMap(Double.init) ?? 0.020
        let snapshotCases = [
            SnapshotCase(id: "settings-general", tabRawValue: "general"),
            SnapshotCase(id: "settings-hotkey", tabRawValue: "hotkey"),
            SnapshotCase(id: "settings-provider", tabRawValue: "provider"),
            SnapshotCase(id: "settings-history", tabRawValue: "history"),
        ]

        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let baselineDirectoryURL = currentDirectory.appendingPathComponent(Paths.baselineDirectory, isDirectory: true)
        let snapshotDirectoryURL = currentDirectory.appendingPathComponent(Paths.snapshotOutputDirectory, isDirectory: true)

        do {
            try fileManager.createDirectory(at: baselineDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: snapshotDirectoryURL, withIntermediateDirectories: true)
        } catch {
            fputs("Visual regression failure: could not create output directories: \(error)\n", stderr)
            exit(1)
        }

        var actualImages: [String: Data] = [:]
        for testCase in snapshotCases {
            guard let imageData = renderSettingsSnapshot(tabRawValue: testCase.tabRawValue) else {
                fputs("Visual regression failure: could not render snapshot \(testCase.id)\n", stderr)
                exit(1)
            }

            actualImages[testCase.id] = imageData

            let fileURL = snapshotDirectoryURL.appendingPathComponent("\(testCase.id).png")
            do {
                try imageData.write(to: fileURL, options: .atomic)
            } catch {
                fputs("Visual regression failure: could not write snapshot \(testCase.id): \(error)\n", stderr)
                exit(1)
            }
        }

        if updateMode {
            writeBaselineImages(actualImages, to: baselineDirectoryURL)
            print("✓ Visual baseline updated at \(baselineDirectoryURL.path)")
            return
        }

        var failures: [String] = []
        for key in snapshotCases.map(\.id) {
            guard let actualData = actualImages[key] else {
                failures.append("\(key): missing actual snapshot")
                continue
            }

            let baselineURL = baselineDirectoryURL.appendingPathComponent("\(key).png")
            guard fileManager.fileExists(atPath: baselineURL.path) else {
                failures.append("\(key): baseline image missing (\(baselineURL.path))")
                continue
            }
            guard let baselineData = try? Data(contentsOf: baselineURL) else {
                failures.append("\(key): could not read baseline image")
                continue
            }

            guard let diff = normalizedImageDifference(actualPNG: actualData, baselinePNG: baselineData) else {
                failures.append("\(key): could not compare image data")
                continue
            }

            if diff > maxDiff {
                failures.append("\(key): diff=\(String(format: "%.4f", diff)) threshold=\(String(format: "%.4f", maxDiff))")
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

    private static func writeBaselineImages(_ images: [String: Data], to baselineDirectoryURL: URL) {
        for key in images.keys.sorted() {
            guard let data = images[key] else { continue }
            let fileURL = baselineDirectoryURL.appendingPathComponent("\(key).png")
            do {
                try data.write(to: fileURL, options: .atomic)
                print("  \(key): \(fileURL.path)")
            } catch {
                fputs("Visual regression failure: could not write baseline image \(key): \(error)\n", stderr)
                exit(1)
            }
        }
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

    private static func normalizedImageDifference(actualPNG: Data, baselinePNG: Data) -> Double? {
        let compareWidth = 320
        let compareHeight = 240

        guard let actual = normalizedRGBA(fromPNG: actualPNG, width: compareWidth, height: compareHeight),
              let baseline = normalizedRGBA(fromPNG: baselinePNG, width: compareWidth, height: compareHeight),
              actual.count == baseline.count else {
            return nil
        }

        var totalDiff: Double = 0
        var channelCount = 0
        var index = 0
        while index + 2 < actual.count {
            // Compare RGB only, ignore alpha.
            totalDiff += abs(Double(actual[index]) - Double(baseline[index])) / 255.0
            totalDiff += abs(Double(actual[index + 1]) - Double(baseline[index + 1])) / 255.0
            totalDiff += abs(Double(actual[index + 2]) - Double(baseline[index + 2])) / 255.0
            channelCount += 3
            index += 4
        }

        guard channelCount > 0 else { return nil }
        return totalDiff / Double(channelCount)
    }

    private static func normalizedRGBA(fromPNG pngData: Data, width: Int, height: Int) -> [UInt8]? {
        guard let bitmap = NSBitmapImageRep(data: pngData),
              let cgImage = bitmap.cgImage else {
            return nil
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        let success = buffer.withUnsafeMutableBytes { ptr -> Bool in
            guard let baseAddress = ptr.baseAddress else { return false }
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return success ? buffer : nil
    }
}
