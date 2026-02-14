import Foundation
import Sparkle

/// Manages app updates using Sparkle
/// 
/// Configure the feed URL in Info.plist using:
/// <key>SUFeedURL</key>
/// <string>https://raw.githubusercontent.com/itisrmk/whisper-smart/master/appcast.xml</string>
final class UpdateManager {
    static let shared = UpdateManager()

    private var updater: SPUUpdater?

    private init() {
        // Create standard user driver
        let userDriver = SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil)
        
        // Create the updater
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )
        
        updater?.automaticallyChecksForUpdates = true
        
        // Check for updates in background after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.updater?.checkForUpdatesInBackground()
        }
    }

    /// Check for updates - shows Sparkle's update dialog
    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// Toggle automatic update checking
    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }
}

// MARK: - Startup

extension UpdateManager {
    static func start() {
        _ = shared
    }
}
