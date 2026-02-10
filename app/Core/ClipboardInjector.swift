import Cocoa

/// Injects transcribed text into the frontmost application.
///
/// The injector supports two strategies:
///   1. **Pasteboard + Cmd-V** – copies text to the system pasteboard and
///      synthesises a ⌘V keystroke. Works everywhere but overwrites the
///      user's clipboard (we save & restore it).
///   2. **CGEvent key-by-key** – synthesises individual key-down/up events.
///      Avoids touching the pasteboard but is slower and limited to ASCII.
///
/// Strategy 1 is the default and recommended approach.
final class ClipboardInjector {

    enum Strategy {
        /// Copy to pasteboard then synthesise ⌘V. Fast, supports Unicode.
        case pasteboard
        /// Synthesise individual key events. Slow, ASCII-only fallback.
        case keyEvents
    }

    /// Which injection strategy to use.
    var strategy: Strategy = .pasteboard

    /// Small delay (seconds) between setting the pasteboard and sending ⌘V.
    /// Some apps need a moment to notice the pasteboard change.
    var pasteDelay: TimeInterval = 0.05

    // MARK: - Public API

    /// Injects `text` into the currently focused text field.
    ///
    /// - Parameter text: The transcription string to inject.
    func inject(text: String) {
        switch strategy {
        case .pasteboard:
            injectViaPasteboard(text: text)
        case .keyEvents:
            injectViaKeyEvents(text: text)
        }
    }

    // MARK: - Pasteboard strategy

    private func injectViaPasteboard(text: String) {
        let pasteboard = NSPasteboard.general

        // Save current pasteboard contents so we can restore them.
        let previousContents = pasteboard.string(forType: .string)

        // Write our text.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Synthesise ⌘V after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [weak self] in
            self?.synthesisePaste()

            // Restore previous pasteboard contents after a generous delay
            // to allow the target app to read the paste.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let prev = previousContents {
                    pasteboard.clearContents()
                    pasteboard.setString(prev, forType: .string)
                }
            }
        }
    }

    /// Posts a ⌘V key event pair.
    private func synthesisePaste() {
        // Virtual key code for 'V'.
        let vKeyCode: CGKeyCode = 0x09

        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Key-events strategy

    private func injectViaKeyEvents(text: String) {
        // TODO: Implement character-by-character key event synthesis.
        //       This requires mapping each Character to a CGKeyCode +
        //       modifier set, which is non-trivial for non-ASCII. Consider
        //       using CGEvent(keyboardEventSource:…) with
        //       kCGEventKeyboardEventKeyboardType and UniChar posting.
        //
        //       For now, fall back to the pasteboard strategy.
        injectViaPasteboard(text: text)
    }
}
