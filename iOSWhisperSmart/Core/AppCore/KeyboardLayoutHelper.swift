import Foundation

enum KeyboardLayoutMode: Equatable {
    case letters
    case numbersAndSymbols
}

struct KeyboardLayoutHelper {
    static let lowerRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"]
    ]

    static let symbolRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'", "#", "%", "*"]
    ]

    static func rows(for mode: KeyboardLayoutMode, isShiftEnabled: Bool) -> [[String]] {
        switch mode {
        case .letters:
            return letterRows(isShiftEnabled: isShiftEnabled)
        case .numbersAndSymbols:
            return symbolRows
        }
    }

    static func letterRows(isShiftEnabled: Bool) -> [[String]] {
        guard isShiftEnabled else { return lowerRows }
        return lowerRows.map { row in
            row.map { $0.uppercased() }
        }
    }

    static func compactSnippets(from snippets: [KeyboardSnippet], limit: Int = 3) -> [KeyboardSnippet] {
        Array(snippets.prefix(max(0, limit)))
    }
}
