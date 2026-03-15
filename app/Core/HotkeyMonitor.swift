import Cocoa
import Carbon.HIToolbox
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "HotkeyMonitor")

/// Monitors a global hotkey for press-and-hold dictation activation.
///
/// Usage:
///   let monitor = HotkeyMonitor()
///   monitor.onHoldStarted = { … }
///   monitor.onHoldEnded  = { … }
///   monitor.start()
///
/// The monitor installs a CGEvent tap so the app must have Accessibility
/// permissions (or run as a trusted process).
final class HotkeyMonitor {

    // MARK: - Public callbacks

    /// Fired once when the monitored key transitions to held state.
    var onHoldStarted: (() -> Void)?

    /// Fired once when the monitored key is released.
    var onHoldEnded: (() -> Void)?

    /// Fired when the event tap cannot be created (Accessibility permission missing).
    var onStartFailed: ((HotkeyMonitorError) -> Void)?

    // MARK: - Configuration

    /// The active binding describing which key/modifiers to watch.
    private(set) var binding: HotkeyBinding

    /// All key codes that should be treated as equivalent to the binding's key code.
    /// Populated automatically to include both left and right modifier variants.
    private var matchingKeyCodes: Set<Int>

    /// Minimum hold duration (seconds) before `onHoldStarted` fires.
    /// Prevents accidental taps from triggering dictation.
    var minimumHoldDuration: TimeInterval = 0.3

    // MARK: - Private state

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyDownTimestamp: Date?
    private var holdFired = false
    private(set) var isRunning = false

    // MARK: - Init

    /// - Parameter binding: The hotkey binding to monitor (defaults to `.defaultBinding`).
    init(binding: HotkeyBinding = .defaultBinding) {
        self.binding = binding
        self.matchingKeyCodes = Self.pairedKeyCodes(for: binding.keyCode)
    }

    /// Returns the exact key code to monitor. Each side of a modifier key
    /// (left vs right) is treated as distinct so users can bind specifically
    /// to Right ⌘ without Left ⌘ triggering it.
    private static func pairedKeyCodes(for code: Int) -> Set<Int> {
        return [code]
    }

    deinit {
        stop()
    }

    // MARK: - Dynamic binding update

    /// Replaces the active binding. Tears down and reinstalls the event tap
    /// so the new key/modifier combination takes effect immediately.
    /// If the event tap cannot be recreated, `onStartFailed` fires.
    func updateBinding(_ newBinding: HotkeyBinding) {
        guard newBinding != binding else { return }

        logger.info("Updating binding: \(self.binding.displayString) → \(newBinding.displayString)")
        let wasRunning = isRunning
        if wasRunning { stop() }

        binding = newBinding
        matchingKeyCodes = Self.pairedKeyCodes(for: newBinding.keyCode)

        if wasRunning {
            start()
            if !isRunning {
                logger.error("Event tap failed to restart after binding change to: \(newBinding.displayString)")
            }
        }
        logger.info("Binding active: \(newBinding.displayString), running: \(self.isRunning)")
    }

    // MARK: - Lifecycle

    /// Returns `true` when the app is a trusted accessibility client.
    /// Pass `promptIfNeeded: true` to show the system permission dialog.
    static func checkAccessibilityTrust(promptIfNeeded: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Installs the global event tap. Requires Accessibility permission.
    func start() {
        guard eventTap == nil else { return }

        if !Self.checkAccessibilityTrust(promptIfNeeded: false) {
            logger.error("Accessibility trust not granted — event tap will likely fail")
        }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handleCGEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            let err = HotkeyMonitorError.eventTapCreationFailed
            logger.error("Failed to create event tap — Accessibility permission likely missing")
            onStartFailed?(err)
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        logger.info("Event tap installed, monitoring: \(self.binding.displayString)")
    }

    /// Removes the event tap.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
        resetState()
    }

    // MARK: - Event handling

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            handleFlagsChanged(event: event)
        case .keyDown:
            handleKeyDown(event: event)
        case .keyUp:
            handleKeyUp(event: event)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        default:
            break
        }
    }

    private func handleFlagsChanged(event: CGEvent) {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if binding.isModifierOnly {
            // Modifier-only binding: watch for the modifier key itself.
            let flags = event.flags
            let isPressed = isModifierPressed(flags: flags, keyCode: binding.keyCode)

            if matchingKeyCodes.contains(code) {
                if isPressed { onKeyDown() } else { onKeyUp() }
            } else if !isPressed && (keyDownTimestamp != nil || holdFired) {
                // Safety: another flagsChanged arrived (e.g. a different modifier was
                // tapped) while our modifier is no longer held. Force release to
                // prevent stuck-key states.
                onKeyUp()
            }
        }
        // For modifier+key combos, flagsChanged is irrelevant — we track keyDown/keyUp.
    }

    private func handleKeyDown(event: CGEvent) {
        guard !binding.isModifierOnly else { return }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard matchingKeyCodes.contains(code) else { return }
        // Check that the required modifiers are held.
        let flags = event.flags
        guard flags.contains(binding.modifierFlags) else { return }
        onKeyDown()
    }

    private func handleKeyUp(event: CGEvent) {
        guard !binding.isModifierOnly else { return }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard matchingKeyCodes.contains(code) else { return }
        onKeyUp()
    }

    // MARK: - Key state transitions

    private func onKeyDown() {
        guard keyDownTimestamp == nil else { return } // already tracking
        keyDownTimestamp = Date()
        holdFired = false

        DispatchQueue.main.asyncAfter(deadline: .now() + minimumHoldDuration) { [weak self] in
            self?.checkHoldThreshold()
        }
    }

    private func onKeyUp() {
        if holdFired {
            logger.info("Hold ended (\(self.binding.displayString))")
            onHoldEnded?()
        }
        resetState()
    }

    private func checkHoldThreshold() {
        guard let downTime = keyDownTimestamp, !holdFired else { return }
        let elapsed = Date().timeIntervalSince(downTime)
        if elapsed >= minimumHoldDuration {
            holdFired = true
            logger.info("Hold started (\(self.binding.displayString))")
            onHoldStarted?()
        }
    }

    private func resetState() {
        keyDownTimestamp = nil
        holdFired = false
    }

    // MARK: - Helpers

    // Device-dependent modifier masks from IOLLEvent.h.
    // These distinguish left vs right physical keys, unlike the generic
    // .maskCommand/.maskShift which fire for either side.
    private static let deviceLCmdMask:   UInt64 = 0x00000008
    private static let deviceRCmdMask:   UInt64 = 0x00000010
    private static let deviceLShiftMask: UInt64 = 0x00000002
    private static let deviceRShiftMask: UInt64 = 0x00000004
    private static let deviceLAltMask:   UInt64 = 0x00000020
    private static let deviceRAltMask:   UInt64 = 0x00000040
    private static let deviceLCtlMask:   UInt64 = 0x00000001
    private static let deviceRCtlMask:   UInt64 = 0x00002000

    /// Returns `true` when the specific physical modifier key is pressed.
    /// Uses device-dependent flags to distinguish left from right.
    private func isModifierPressed(flags: CGEventFlags, keyCode: Int) -> Bool {
        let raw = flags.rawValue
        switch keyCode {
        case kVK_Command:      return raw & Self.deviceLCmdMask != 0
        case kVK_RightCommand: return raw & Self.deviceRCmdMask != 0
        case kVK_Shift:        return raw & Self.deviceLShiftMask != 0
        case kVK_RightShift:   return raw & Self.deviceRShiftMask != 0
        case kVK_Option:       return raw & Self.deviceLAltMask != 0
        case kVK_RightOption:  return raw & Self.deviceRAltMask != 0
        case kVK_Control:      return raw & Self.deviceLCtlMask != 0
        case kVK_RightControl: return raw & Self.deviceRCtlMask != 0
        case kVK_Function:     return flags.contains(.maskSecondaryFn)
        default:               return false
        }
    }
}

// MARK: - Errors

enum HotkeyMonitorError: Error, LocalizedError {
    case eventTapCreationFailed

    var errorDescription: String? {
        switch self {
        case .eventTapCreationFailed:
            return "Cannot monitor hotkeys — grant Accessibility permission in System Settings → Privacy & Security → Accessibility."
        }
    }
}
