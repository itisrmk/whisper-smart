import Cocoa
import Carbon.HIToolbox

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
    private var isRunning = false

    // MARK: - Init

    /// - Parameter binding: The hotkey binding to monitor (defaults to `.defaultBinding`).
    init(binding: HotkeyBinding = .defaultBinding) {
        self.binding = binding
        self.matchingKeyCodes = Self.pairedKeyCodes(for: binding.keyCode)
    }

    /// Returns a set containing both left and right variants for modifier keys,
    /// or a singleton set for non-modifier keys.
    private static func pairedKeyCodes(for code: Int) -> Set<Int> {
        switch code {
        case kVK_Command, kVK_RightCommand:
            return [kVK_Command, kVK_RightCommand]
        case kVK_Shift, kVK_RightShift:
            return [kVK_Shift, kVK_RightShift]
        case kVK_Option, kVK_RightOption:
            return [kVK_Option, kVK_RightOption]
        case kVK_Control, kVK_RightControl:
            return [kVK_Control, kVK_RightControl]
        default:
            return [code]
        }
    }

    deinit {
        stop()
    }

    // MARK: - Dynamic binding update

    /// Replaces the active binding. Tears down and reinstalls the event tap
    /// so the new key/modifier combination takes effect immediately.
    func updateBinding(_ newBinding: HotkeyBinding) {
        guard newBinding != binding else { return }

        let wasRunning = isRunning
        if wasRunning { stop() }

        binding = newBinding
        matchingKeyCodes = Self.pairedKeyCodes(for: newBinding.keyCode)

        if wasRunning { start() }
    }

    // MARK: - Lifecycle

    /// Installs the global event tap. Requires Accessibility permission.
    func start() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        // TODO: Handle the case where CGEvent.tapCreate returns nil
        //       (Accessibility permission not granted). Surface an error
        //       via a delegate/callback so the UI layer can prompt the user.
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
            print("[HotkeyMonitor] Failed to create event tap – check Accessibility permissions.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
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
            guard matchingKeyCodes.contains(code) else { return }
            let flags = event.flags
            let isPressed = isModifierPressed(flags: flags, keyCode: code)
            if isPressed { onKeyDown() } else { onKeyUp() }
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
            onHoldEnded?()
        }
        resetState()
    }

    private func checkHoldThreshold() {
        guard let downTime = keyDownTimestamp, !holdFired else { return }
        let elapsed = Date().timeIntervalSince(downTime)
        if elapsed >= minimumHoldDuration {
            holdFired = true
            onHoldStarted?()
        }
    }

    private func resetState() {
        keyDownTimestamp = nil
        holdFired = false
    }

    // MARK: - Helpers

    /// Returns `true` when the modifier flag corresponding to `keyCode` is set.
    private func isModifierPressed(flags: CGEventFlags, keyCode: Int) -> Bool {
        switch keyCode {
        case kVK_RightCommand, kVK_Command:
            return flags.contains(.maskCommand)
        case kVK_Shift, kVK_RightShift:
            return flags.contains(.maskShift)
        case kVK_Option, kVK_RightOption:
            return flags.contains(.maskAlternate)
        case kVK_Control, kVK_RightControl:
            return flags.contains(.maskControl)
        case kVK_Function:
            return flags.contains(.maskSecondaryFn)
        default:
            return false
        }
    }
}
