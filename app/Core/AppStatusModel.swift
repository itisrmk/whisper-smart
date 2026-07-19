import Foundation

/// Severity of a user-facing status condition.
enum AppStatusSeverity {
    case info
    case warning
    case error
}

/// A single canonical, user-facing status: one wording + one severity that
/// every surface (menu bar, overlay error state, settings banners) shares.
struct AppStatus: Equatable {
    let message: String
    let severity: AppStatusSeverity
}

/// The single source of truth for user-facing status wording.
///
/// Every root cause (permission missing, provider fallback, hotkey monitor
/// down, transcription error, model/runtime install failure) maps to exactly
/// one `AppStatus` here. The menu bar, overlay, and settings banners must all
/// pull from this catalog so the same condition never renders with different
/// strings in different places. Onboarding cards and inline field validation
/// keep their own local copy (they need contextual phrasing).
enum AppStatusCatalog {

    // MARK: - Permissions / hotkey monitor

    /// Accessibility permission is missing, so the global hotkey cannot work.
    static let accessibilityPermissionMissing = AppStatus(
        message: "Accessibility permission required. Grant access in System Settings → Privacy & Security → Accessibility. Hotkey setup resumes automatically.",
        severity: .error
    )

    /// The CGEvent tap could not be created (hotkey monitor down).
    static let hotkeyMonitorDown = AppStatus(
        message: "Cannot monitor hotkeys — grant Accessibility permission in System Settings → Privacy & Security → Accessibility.",
        severity: .error
    )

    /// True when an error message describes a hotkey/Accessibility setup
    /// issue, i.e. one of the two conditions above. Used to decide whether
    /// the "Retry Hotkey Monitor" recovery action is relevant.
    static func isHotkeySetupIssue(_ message: String) -> Bool {
        let normalized = message.lowercased()
        if normalized.contains("cannot monitor hotkeys") { return true }
        if normalized.contains("accessibility permission") { return true }
        return false
    }

    // MARK: - Transcription errors

    /// The STT provider never returned a result within its timeout.
    static func transcriptionTimedOut(providerName: String) -> AppStatus {
        AppStatus(
            message: "Transcription timed out while using \(providerName). Please try again.",
            severity: .error
        )
    }

    // MARK: - Provider fallback / degraded

    /// Maps a raw provider fallback reason (from `ProviderRuntimeDiagnostics`)
    /// to the one friendly string + severity shown on every surface.
    static func providerFallback(reason: String) -> AppStatus {
        AppStatus(
            message: friendlyFallbackMessage(reason),
            severity: fallbackSeverity(reason)
        )
    }

    private static func friendlyFallbackMessage(_ reason: String) -> String {
        let normalized = reason.lowercased()
        if normalized.contains("api key") {
            return "Setup needed: add your OpenAI API key to use Cloud mode."
        }
        if normalized.contains("endpoint") {
            return "Setup needed: check Cloud endpoint URL/model in Provider settings."
        }
        if normalized.contains("disabled") {
            return "Setup needed: turn on 'Allow cloud fallback' to use Cloud mode."
        }
        if normalized.contains("model") && normalized.contains("not ready") {
            return "Setup needed: install the Parakeet model/runtime from Provider settings."
        }
        if normalized.contains("runtime") && normalized.contains("not integrated") {
            return "Balanced currently uses Apple Speech fallback in this build."
        }
        if normalized.contains("runtime bootstrap failed") || normalized.contains("runtime setup failed") {
            return "Setup needed: local runtime is not ready. Open Provider and run setup."
        }
        return "Setup needed before this provider can run."
    }

    private static func fallbackSeverity(_ reason: String) -> AppStatusSeverity {
        let normalized = reason.lowercased()
        if normalized.contains("failed") || normalized.contains("error") {
            return .error
        }
        return .warning
    }

    // MARK: - Model / runtime install

    /// A model download/install attempt failed (raw installer output lives in
    /// the Advanced disclosure; user-facing surfaces stay plain-language).
    static let modelInstallFailed = AppStatus(
        message: "Install failed. Open Advanced below for details, then retry.",
        severity: .error
    )

    /// The MLX Python runtime bootstrap failed.
    static let mlxRuntimeSetupFailed = AppStatus(
        message: "MLX runtime setup failed. Retry setup from Settings -> Provider.",
        severity: .error
    )
}
