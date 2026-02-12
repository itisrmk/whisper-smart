import Cocoa
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "TextInjector")

/// Injects transcribed text into the frontmost focused text input.
///
/// Strategy order (Phase 1 reliability core):
///   1. Accessibility insertion (AX) into the focused element.
///   2. Pasteboard + Cmd-V fallback with best-effort full pasteboard snapshot/restore.
final class ClipboardInjector {

    enum Strategy {
        case accessibility
        case pasteboard
    }

    /// Ordered strategies attempted for each injection.
    var strategyOrder: [Strategy] = [.accessibility, .pasteboard]

    /// Delay between pasteboard write and ⌘V synthesis.
    var pasteDelay: TimeInterval = 0.05

    /// Delay before attempting clipboard restore.
    var restoreDelay: TimeInterval = 0.2

    func inject(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let activeStrategyOrder: [Strategy]
        switch DictationWorkflowSettings.insertionMode {
        case .smart:
            activeStrategyOrder = strategyOrder
        case .accessibilityOnly:
            activeStrategyOrder = [.accessibility]
        case .pasteboardOnly:
            activeStrategyOrder = [.pasteboard]
        }

        for strategy in activeStrategyOrder {
            switch strategy {
            case .accessibility:
                if injectViaAccessibility(text: trimmed) {
                    logger.info("Text injection succeeded via accessibility")
                    return
                }
                logger.info("Accessibility insertion unavailable/failed; falling back")

            case .pasteboard:
                injectViaPasteboard(text: trimmed)
                return
            }
        }

        logger.error("No viable text injection strategy configured")
    }

    // MARK: - Accessibility strategy

    private func injectViaAccessibility(text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusedResult == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return false
        }

        let focusedElement = unsafeBitCast(focusedRef, to: AXUIElement.self)

        // We currently support insert/replace only for text controls exposing
        // AXValue + AXSelectedTextRange.
        guard var value = valueString(for: focusedElement),
              let selectedRange = selectedTextRange(for: focusedElement) else {
            return false
        }

        let nsValue = value as NSString
        let safeLocation = max(0, min(selectedRange.location, nsValue.length))
        let safeLength = max(0, min(selectedRange.length, nsValue.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        value = nsValue.replacingCharacters(in: safeRange, with: text)

        guard AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, value as CFTypeRef) == .success else {
            return false
        }

        let insertionLocation = safeLocation + (text as NSString).length
        var updatedRange = CFRange(location: insertionLocation, length: 0)
        guard let updatedRangeValue = AXValueCreate(.cfRange, &updatedRange) else {
            return false
        }

        _ = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            updatedRangeValue
        )

        return true
    }

    private func valueString(for element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard result == .success else { return nil }
        return valueRef as? String
    }

    private func selectedTextRange(for element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard result == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }

        let value = unsafeBitCast(rangeRef, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Pasteboard fallback

    private func injectViaPasteboard(text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let injectionChangeCount = pasteboard.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [weak self] in
            self?.synthesisePaste()

            DispatchQueue.main.asyncAfter(deadline: .now() + (self?.restoreDelay ?? 0.2)) {
                guard let snapshot else { return }
                // If clipboard changed after injection (e.g. user copied
                // something else), do not overwrite user intent.
                guard pasteboard.changeCount == injectionChangeCount else {
                    logger.info("Skipping pasteboard restore; clipboard changed externally")
                    return
                }
                snapshot.restore(to: pasteboard)
            }
        }
    }

    private func synthesisePaste() {
        let vKeyCode: CGKeyCode = 0x09
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

// MARK: - Pasteboard snapshot

private struct PasteboardSnapshot {
    private enum StoredValue {
        case data(Data)
        case propertyList(Any)
    }

    private struct StoredItem {
        let valuesByType: [(NSPasteboard.PasteboardType, StoredValue)]
    }

    private let items: [StoredItem]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        guard let pasteboardItems = pasteboard.pasteboardItems else {
            return PasteboardSnapshot(items: [])
        }

        let storedItems: [StoredItem] = pasteboardItems.map { item in
            var values: [(NSPasteboard.PasteboardType, StoredValue)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    values.append((type, .data(data)))
                } else if let plist = item.propertyList(forType: type) {
                    values.append((type, .propertyList(plist)))
                }
            }
            return StoredItem(valuesByType: values)
        }

        return PasteboardSnapshot(items: storedItems)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !items.isEmpty else { return }

        let restoredItems: [NSPasteboardItem] = items.compactMap { stored in
            let item = NSPasteboardItem()
            var wroteAnyType = false

            for (type, storedValue) in stored.valuesByType {
                switch storedValue {
                case .data(let data):
                    if item.setData(data, forType: type) {
                        wroteAnyType = true
                    }
                case .propertyList(let plist):
                    if item.setPropertyList(plist, forType: type) {
                        wroteAnyType = true
                    }
                }
            }

            return wroteAnyType ? item : nil
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems as [NSPasteboardWriting])
        }
    }
}
