import Foundation

// Cross-layer notification names. Defined in Core (not UI) so that Core
// components — e.g. WhisperModelInstaller — can post them and the smoke-test
// target (which compiles app/Core only) can reference them.

extension Notification.Name {
    /// Hotkey recorder saved a new binding (userInfo["binding"]).
    static let hotkeyBindingDidChange = Notification.Name("hotkeyBindingDidChange")

    /// Onboarding window requested from the settings window.
    static let productOnboardingRequested = Notification.Name("productOnboardingRequested")

    /// STT provider selection or configuration changed; AppDelegate re-resolves
    /// and hot-swaps the active provider.
    static let sttProviderDidChange = Notification.Name("sttProviderDidChange")
}
