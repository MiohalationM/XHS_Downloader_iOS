import Foundation

struct NamingPreferences {
    static let enableKey = "use_custom_naming_format"
    static let templateKey = "custom_naming_template"
    static let timezoneKey = "naming.activeTimezone"

    let enabled: Bool
    let template: String
    let timeZone: TimeZone

    init(enabled: Bool, template: String, timeZone: TimeZone = .current) {
        self.enabled = enabled
        self.template = template
        self.timeZone = timeZone
    }

    /// Resolves the time zone once, so a background resume and a foreground
    /// edit of the setting can never render two different names for one task.
    static func load(defaults: UserDefaults = .standard) -> NamingPreferences {
        let enabled = defaults.bool(forKey: enableKey)
        let template = defaults.string(forKey: templateKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTemplate = template?.isEmpty == false ? template! : NamingFormatter.defaultTemplate
        let zone = defaults.string(forKey: timezoneKey).flatMap(TimeZone.init(identifier:)) ?? .current
        return NamingPreferences(enabled: enabled, template: finalTemplate, timeZone: zone)
    }
}

struct NoteMetadata: Codable, Hashable, Sendable {
    var userName: String?
    var userId: String?
    var title: String?
    var publishTime: String?
    var redId: String? = nil
    var avatarURL: URL? = nil
    var topics: [String]? = nil
    var publishedAt: Date? = nil
    var profileURL: URL? = nil
}

enum NamingFormatter {
    static let defaultTemplate = "{title}_{publishTime}_{downloadTimestamp}"

    private static let placeholderRegex = try! NSRegularExpression(pattern: "\\{([^}]+)\\}")

    static func makeBaseName(metadata: NoteMetadata,
                             fallbackPostId: String?,
                             index: Int,
                             downloadEpochSeconds: TimeInterval,
                             preferences: NamingPreferences) -> String {
        let indexPart = String(format: "%02d", max(index, 1))

        if preferences.enabled {
            let rendered = render(template: preferences.template,
                                  metadata: metadata,
                                  fallbackPostId: fallbackPostId,
                                  downloadEpochSeconds: downloadEpochSeconds,
                                  index: index,
                                  indexPart: indexPart,
                                  timeZone: preferences.timeZone)
            if let sanitized = sanitize(rendered), !sanitized.isEmpty {
                return sanitized + "_" + indexPart
            }
        }

        let fallback = fallbackPostId ?? metadata.title ?? metadata.userName ?? "xhs"
        let sanitizedFallback = sanitize(fallback) ?? "xhs"
        return sanitizedFallback + "_" + indexPart
    }

    static func validationError(_ template: String) -> String? {
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        let matches = placeholderRegex.matches(in: template, range: range)
        let known: Set<String> = ["username", "userId", "redId", "title", "postId", "publishTime", "index", "index_padded", "downloadTimestamp"]
        for match in matches {
            let body = (template as NSString).substring(with: match.range(at: 1))
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard known.contains(parts[0]) else { return L10n.text("naming.invalid.token") }
            if parts.count > 1 {
                guard ["publishTime", "downloadTimestamp"].contains(parts[0]), validDatePattern(parts[1]) else {
                    return L10n.text("naming.invalid.date")
                }
            }
        }
        let remaining = placeholderRegex.stringByReplacingMatches(in: template, range: range, withTemplate: "")
        return remaining.contains("{") || remaining.contains("}") || template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.text("naming.invalid.token") : nil
    }

    static func validDatePattern(_ pattern: String) -> Bool {
        guard !pattern.isEmpty, pattern.count <= 80, !pattern.contains("{"), !pattern.contains("}"),
              !pattern.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        var quoted = false
        var field = false
        let supported = Set("yMdHhmsSaEZ")
        for c in pattern {
            if c == "'" { quoted.toggle() }
            else if !quoted && c.isASCII && c.isLetter {
                guard supported.contains(c) else { return false }
                field = true
            }
        }
        return !quoted && field
    }

    private static func render(template: String,
                               metadata: NoteMetadata,
                               fallbackPostId: String?,
                               downloadEpochSeconds: TimeInterval,
                               index: Int,
                               indexPart: String,
                               timeZone: TimeZone) -> String {
        guard validationError(template) == nil else { return fallbackPostId ?? "xhs" }
        let range = NSRange(location: 0, length: (template as NSString).length)
        var result = template
        let matches = placeholderRegex.matches(in: template, options: [], range: range).reversed()
        for match in matches {
            guard match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: template) else { continue }
            let token = String(template[tokenRange])
            let replacement = replacementValue(for: token,
                                               metadata: metadata,
                                               fallbackPostId: fallbackPostId,
                                               downloadEpochSeconds: downloadEpochSeconds,
                                               index: index,
                                               indexPart: indexPart,
                                               timeZone: timeZone)
            if let rangeToReplace = Range(match.range, in: result) {
                result.replaceSubrange(rangeToReplace, with: replacement)
            }
        }
        return result
    }

    private static func replacementValue(for token: String,
                                         metadata: NoteMetadata,
                                         fallbackPostId: String?,
                                         downloadEpochSeconds: TimeInterval,
                                         index: Int,
                                         indexPart: String,
                                         timeZone: TimeZone) -> String {
        switch token {
        case "username":
            return sanitize(metadata.userName) ?? ""
        case "userId":
            return sanitize(metadata.userId) ?? ""
        case "redId":
            return sanitize(metadata.redId) ?? ""
        case "title":
            return sanitize(metadata.title) ?? ""
        case "postId":
            return sanitize(fallbackPostId) ?? ""
        case "publishTime":
            return sanitize(metadata.publishTime, allowHyphen: true) ?? ""
        case "index":
            return String(max(index, 1))
        case "index_padded":
            return indexPart
        case "downloadTimestamp":
            return String(Int(downloadEpochSeconds))
        default:
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, validDatePattern(parts[1]), ["publishTime", "downloadTimestamp"].contains(parts[0]) {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = timeZone
                let date: Date?
                if parts[0] == "downloadTimestamp" { date = Date(timeIntervalSince1970: downloadEpochSeconds) }
                else if let published = metadata.publishedAt { date = published }
                else {
                    formatter.dateFormat = "yy-MM-dd"
                    date = metadata.publishTime.flatMap { formatter.date(from: $0) }
                }
                if let date { formatter.dateFormat = parts[1]; return formatter.string(from: date) }
            }
            return ""
        }
    }

    private static func sanitize(_ value: String?, allowHyphen: Bool = false) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let invalidCharacters: CharacterSet = {
            var set = CharacterSet(charactersIn: "\\/:*?\"<>|")
            if allowHyphen {
                set.remove(charactersIn: "-")
            }
            return set
        }()
        value = value.components(separatedBy: invalidCharacters).joined(separator: "_")
        value = value.replacingOccurrences(of: "[\\p{Cntrl}]", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
        value = value.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if value.count > 120 {
            value = String(value.prefix(120))
        }
        return value.isEmpty ? nil : value
    }
}
