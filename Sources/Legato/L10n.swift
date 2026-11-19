import Foundation

/// Two languages, chosen from the system. Strings live next to the code that shows them.
enum L {
    static let portuguese = Locale.preferredLanguages.first?.hasPrefix("pt") ?? false

    static func t(_ english: String, _ portuguese: String) -> String {
        Self.portuguese ? portuguese : english
    }
}
