import Foundation

enum CommandRoutingMode {
    case dictation
    case commandCandidate
}

struct CommandRoutingDecision {
    let mode: CommandRoutingMode
    /// Injection output for current scaffold behavior.
    /// Future phases may leave this empty for executed commands.
    let textForInjection: String
}

protocol CommandModeRouter {
    func route(text: String, isFinal: Bool) -> CommandRoutingDecision
}

final class FeatureFlaggedCommandModeRouter: CommandModeRouter {
    private let isEnabled: () -> Bool

    init(isEnabled: @escaping () -> Bool = { false }) {
        self.isEnabled = isEnabled
    }

    func route(text: String, isFinal: Bool) -> CommandRoutingDecision {
        guard isEnabled(), isFinal else {
            return CommandRoutingDecision(mode: .dictation, textForInjection: text)
        }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isCommandPrefixed = normalized.hasPrefix("command ") || normalized.hasPrefix("visper command ")

        if isCommandPrefixed {
            // Non-invasive scaffold: currently pass through text unchanged.
            return CommandRoutingDecision(mode: .commandCandidate, textForInjection: text)
        }

        return CommandRoutingDecision(mode: .dictation, textForInjection: text)
    }
}
