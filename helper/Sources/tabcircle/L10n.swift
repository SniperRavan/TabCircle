import Foundation

/// Localization strings and helpers.
enum L10n {

    enum Language: String, CaseIterable, Identifiable {
        case system
        case en

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "Follow System"
            case .en:     return "English"
            }
        }
    }

    private static let key = "language"

    /// Rebuild rendered interfaces on language change
    nonisolated(unsafe) static var onChange: (() -> Void)?

    static var language: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set {
            guard newValue != language else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            onChange?()
        }
    }

    /// Backwards compatibility stub for language check
    static var isChinese: Bool { false }

    /// Returns localized text (defaults to English). Overload for (String, String) ensures compatibility.
    static func t(_ zhOrEn: String, _ en: String) -> String {
        en
    }

    static func t(_ text: String) -> String {
        text
    }
}

/// Relative time representation (e.g. "5m ago"). Returns nil if timestamp is missing or future.
func relativeTime(msEpoch: Double?) -> String? {
    guard let msEpoch, msEpoch > 0 else { return nil }
    let seconds = Date().timeIntervalSince1970 - msEpoch / 1000
    guard seconds >= 0 else { return nil }
    if seconds < 60 { return "just now" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = Int(seconds / 3600)
    if hours < 24 { return "\(hours)h ago" }
    return "\(Int(seconds / 86400))d ago"
}
