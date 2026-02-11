import AVFoundation
import Speech
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "Permissions")

/// Centralised permission diagnostics for the four macOS entitlements
/// that VisperflowClone requires: Accessibility, Input Monitoring,
/// Microphone, and Speech Recognition.
///
/// Designed for unsigned `swiftc` binaries where permission state
/// is often stale or missing.
enum PermissionDiagnostics {

    // MARK: - Per-permission status

    enum Status: String {
        case granted    = "Granted"
        case denied     = "Denied"
        case notAsked   = "Not Asked"
        case restricted = "Restricted"
        case unknown    = "Unknown"

        var isUsable: Bool { self == .granted }

        /// Short user-facing action hint.
        var actionHint: String {
            switch self {
            case .granted:    return "Ready"
            case .denied:     return "Open System Settings to grant access"
            case .notAsked:   return "Will be requested on first use"
            case .restricted: return "Restricted by policy — contact your admin"
            case .unknown:    return "Unable to determine status"
            }
        }
    }

    /// Snapshot of all permission states at a point in time.
    struct Snapshot {
        let accessibility: Status
        let microphone: Status
        let speechRecognition: Status

        /// Accessibility and Input Monitoring are the same entitlement
        /// for CGEvent taps, but users see them as separate items.
        var inputMonitoring: Status { accessibility }

        var allGranted: Bool {
            accessibility.isUsable
            && microphone.isUsable
            && speechRecognition.isUsable
        }

        /// Returns the first missing permission name, or nil.
        var firstMissing: String? {
            if !accessibility.isUsable      { return "Accessibility" }
            if !microphone.isUsable         { return "Microphone" }
            if !speechRecognition.isUsable  { return "Speech Recognition" }
            return nil
        }

        /// Human-readable summary of every missing permission.
        var missingPermissionsSummary: String {
            var parts: [String] = []
            if !accessibility.isUsable {
                parts.append("Accessibility / Input Monitoring: \(accessibility.actionHint)")
            }
            if !microphone.isUsable {
                parts.append("Microphone: \(microphone.actionHint)")
            }
            if !speechRecognition.isUsable {
                parts.append("Speech Recognition: \(speechRecognition.actionHint)")
            }
            return parts.isEmpty ? "All permissions granted" : parts.joined(separator: "\n")
        }
    }

    // MARK: - Queries

    static func accessibilityStatus() -> Status {
        let trusted = AXIsProcessTrustedWithOptions(nil)
        return trusted ? .granted : .denied
    }

    static func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .notDetermined: return .notAsked
        case .restricted:    return .restricted
        @unknown default:    return .unknown
        }
    }

    static func speechRecognitionStatus() -> Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .notDetermined: return .notAsked
        case .restricted:    return .restricted
        @unknown default:    return .unknown
        }
    }

    /// Take a full snapshot of every required permission.
    static func snapshot() -> Snapshot {
        Snapshot(
            accessibility: accessibilityStatus(),
            microphone: microphoneStatus(),
            speechRecognition: speechRecognitionStatus()
        )
    }

    /// Log all permission states to the unified log.
    static func logAll() {
        let snap = snapshot()
        logger.info("""
        Permission diagnostics:
          Accessibility:       \(snap.accessibility.rawValue, privacy: .public)
          Microphone:          \(snap.microphone.rawValue, privacy: .public)
          Speech Recognition:  \(snap.speechRecognition.rawValue, privacy: .public)
          All granted:         \(snap.allGranted ? "YES" : "NO", privacy: .public)
        """)
    }

    // MARK: - Ordered prompting

    /// Requests permissions in the correct order for unsigned binaries:
    /// 1. Accessibility (triggers system dialog)
    /// 2. Microphone
    /// 3. Speech Recognition
    ///
    /// Calls `completion` on the main queue when all prompts have been
    /// presented (not necessarily granted).
    static func requestAllInOrder(completion: @escaping (Snapshot) -> Void) {
        // Step 1: Accessibility — prompt via AX API (synchronous dialog)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // Step 2: Microphone
        let micDone = { (micGranted: Bool) in
            logger.info("Microphone prompt result: \(micGranted ? "granted" : "denied")")

            // Step 3: Speech Recognition
            SFSpeechRecognizer.requestAuthorization { srStatus in
                logger.info("Speech recognition prompt result: \(srStatus.rawValue)")
                DispatchQueue.main.async {
                    completion(snapshot())
                }
            }
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { micDone(granted) }
            }
        } else {
            let srStatus = SFSpeechRecognizer.authorizationStatus()
            if srStatus == .notDetermined {
                micDone(micStatus == .authorized)
            } else {
                DispatchQueue.main.async { completion(snapshot()) }
            }
        }
    }
}
