import Foundation

/// Records whether the user has explicitly started Parakeet setup from
/// Settings -> Provider. Nothing may download the Parakeet model or install
/// the Python runtime unless this is true — selecting the provider alone is
/// not consent to a 650 MB download plus pip installs.
enum ParakeetSetupPolicy {
    private static let consentKey = "parakeet.setupConsentGranted"

    static var setupConsentGranted: Bool {
        get { UserDefaults.standard.bool(forKey: consentKey) }
        set { UserDefaults.standard.set(newValue, forKey: consentKey) }
    }
}
