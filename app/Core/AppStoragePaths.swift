import Foundation
import os.log

private let storagePathsLogger = Logger(subsystem: "com.visperflow", category: "StoragePaths")

/// Shared storage path resolver for App Support artifacts.
enum AppStoragePaths {
    static let canonicalAppSupportDirectoryName = "WhisperSmart"
    private static let legacyAppSupportDirectoryNames = ["VisperflowClone", "Visperflow"]

    static func resolvedModelURL(relativePath: String, fileManager: FileManager = .default) -> URL? {
        guard let canonicalRoot = canonicalRootURL(fileManager: fileManager) else { return nil }
        let canonicalURL = canonicalRoot.appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: canonicalURL.path) {
            return canonicalURL
        }

        // Migrate a legacy model path on first access so all runtime components
        // converge on the same canonical App Support directory.
        for legacyRoot in legacyRootURLs(fileManager: fileManager) {
            let legacyURL = legacyRoot.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: legacyURL.path) else { continue }

            do {
                try fileManager.createDirectory(
                    at: canonicalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: legacyURL, to: canonicalURL)
                storagePathsLogger.info("Migrated model from legacy path \(legacyURL.path, privacy: .public) to \(canonicalURL.path, privacy: .public)")
                return canonicalURL
            } catch {
                storagePathsLogger.warning("Failed to migrate legacy model \(legacyURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return legacyURL
            }
        }

        return canonicalURL
    }

    static func runtimeRootCandidates(fileManager: FileManager = .default) -> [URL] {
        guard let appSupport = appSupportDirectoryURL(fileManager: fileManager) else { return [] }

        var roots = [canonicalAppSupportDirectoryName]
        roots.append(contentsOf: legacyAppSupportDirectoryNames)

        return roots.map { rootName in
            appSupport
                .appendingPathComponent(rootName, isDirectory: true)
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("parakeet", isDirectory: true)
        }
    }

    static func whisperRuntimeRootCandidates(fileManager: FileManager = .default) -> [URL] {
        guard let appSupport = appSupportDirectoryURL(fileManager: fileManager) else { return [] }

        var roots = [canonicalAppSupportDirectoryName]
        roots.append(contentsOf: legacyAppSupportDirectoryNames)

        return roots.map { rootName in
            appSupport
                .appendingPathComponent(rootName, isDirectory: true)
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("whisper", isDirectory: true)
        }
    }
}

private extension AppStoragePaths {
    static func canonicalRootURL(fileManager: FileManager) -> URL? {
        guard let appSupport = appSupportDirectoryURL(fileManager: fileManager) else { return nil }
        return appSupport.appendingPathComponent(canonicalAppSupportDirectoryName, isDirectory: true)
    }

    static func legacyRootURLs(fileManager: FileManager) -> [URL] {
        guard let appSupport = appSupportDirectoryURL(fileManager: fileManager) else { return [] }
        return legacyAppSupportDirectoryNames.map {
            appSupport.appendingPathComponent($0, isDirectory: true)
        }
    }

    static func appSupportDirectoryURL(fileManager: FileManager) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
}
