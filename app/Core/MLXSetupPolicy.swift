import Foundation

/// Records whether the user has explicitly started MLX setup from
/// Settings -> Provider. Nothing may download models or install the Python
/// runtime unless this is true — selecting a provider alone is not consent
/// to multi-GB downloads plus pip installs.
enum MLXSetupPolicy {
    private static let consentKey = "mlx.setupConsentGranted"
    private static let legacyConsentKey = "parakeet.setupConsentGranted"

    static var setupConsentGranted: Bool {
        get {
            UserDefaults.standard.bool(forKey: consentKey)
                || UserDefaults.standard.bool(forKey: legacyConsentKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: consentKey) }
    }
}
