import Foundation
import Sparkle

/// Manages app updates using Sparkle.
/// Feed URL is supplied via Info.plist (SUFeedURL).
final class UpdateManager {
    static let shared = UpdateManager()

    private let updater: SPUUpdater

    private init() {
        let userDriver = SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil)
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )

        do {
            try updater.start()
            updater.automaticallyChecksForUpdates = true

            // Background check shortly after launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [updater] in
                updater.checkForUpdatesInBackground()
            }
        } catch {
            NSLog("[UpdateManager] Failed to start Sparkle updater: \(error.localizedDescription)")
        }
    }

    /// Manual check (user initiated from menu).
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
}

extension UpdateManager {
    static func start() {
        _ = shared
    }
}
