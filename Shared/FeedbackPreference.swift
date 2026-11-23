import Foundation

/// The app and its share extension use the same opt-out preference.
enum FeedbackPreference {
    static let key = "feedback.enabled"

    static func isEnabled(in defaults: UserDefaults?) -> Bool {
        defaults?.object(forKey: key) as? Bool ?? true
    }

    static func synchronizeExtension(_ enabled: Bool) {
        UserDefaults(suiteName: ImportInbox.groupIdentifier)?.set(enabled, forKey: key)
    }
}
