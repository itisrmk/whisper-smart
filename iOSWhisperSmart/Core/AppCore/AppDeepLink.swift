import Foundation

enum AppDeepLink: Equatable {
    case dictate

    static func parse(_ url: URL) -> AppDeepLink? {
        guard url.scheme?.lowercased() == "whispersmart" else { return nil }

        if let host = url.host?.lowercased(), host == "dictate" {
            return .dictate
        }

        let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if trimmedPath == "dictate" {
            return .dictate
        }

        return nil
    }
}
