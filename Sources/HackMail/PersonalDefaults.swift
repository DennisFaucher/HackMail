import Foundation

/// Values specific to one person's setup. Everything else in the project is generic; this is the neutral
/// public copy (no suggested accounts, a blank LanguageTool server, and its own Keychain service name).
/// Keep personal data here and nowhere else.
enum PersonalDefaults {
    /// Addresses offered as initial account suggestions. Empty means the app starts with no accounts.
    static let suggestedAddresses: [String] = []

    /// Display names to pre-fill for suggested addresses (keys are lowercase).
    static let suggestedFullNames: [String: String] = [:]

    static func suggestedFullName(for email: String) -> String {
        suggestedFullNames[email.lowercased()] ?? ""
    }

    /// Placeholder shown in the account name field.
    static let fullNamePlaceholder = "Your name"

    /// Default LanguageTool server; blank means the user must enter one before enabling checks.
    static let languageToolBaseURL = ""

    /// Keychain service name. Keep it stable across command-line and app-bundle launches, and never change it
    /// for an installed copy or its saved app passwords become unreachable.
    static let keychainService = "com.hackmail.desktop"
}
