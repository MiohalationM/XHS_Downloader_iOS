import Foundation

struct ImportRequest: Codable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case share, clipboard, manual }
    enum Behavior: String, Codable, Sendable { case useSettings, select, informationOnly, direct }

    let id: UUID
    let text: String
    let source: Source
    let behavior: Behavior
    let createdAt: Date

    init(id: UUID = UUID(), text: String, source: Source, behavior: Behavior = .useSettings, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.source = source
        self.behavior = behavior
        self.createdAt = createdAt
    }

    var handoffURL: URL {
        URL(string: "xhsdn://import?request=\(id.uuidString)")!
    }

    static func requestID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "xhsdn", url.host == "import",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "request" })?.value else { return nil }
        return UUID(uuidString: value)
    }
}

/// One shared link grammar and canonicalizer: the app and the share extension
/// must agree on both link count and deduplication so they never disagree on
/// case-sensitive short links or trailing punctuation.
enum ImportText {
    static let linkPattern = #"(?<![a-zA-Z0-9@.])(?:https?://)?(?:www\.)?(?:xiaohongshu\.com|rednote\.com|xhslink\.(?:com|cn))/[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+=%]+"#

    private static let expression = try! NSRegularExpression(
        pattern: linkPattern,
        options: [.caseInsensitive]
    )

    static func extractLinks(from input: String) -> [String] {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var seen = Set<String>()
        return expression.matches(in: input, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: input) else { return nil }
            var value = String(input[swiftRange])
            while let last = value.last, ".,;:!?)]}".contains(last) { value.removeLast() }
            if !value.lowercased().hasPrefix("http") { value = "https://" + value }
            guard let url = URL(string: value), let host = url.host?.lowercased() else { return nil }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = host
            value = components?.url?.absoluteString ?? value
            guard seen.insert(value).inserted else { return nil }
            return value
        }
    }

    static func linkCount(in input: String) -> Int {
        extractLinks(from: input).count
    }
}

/// Both processes use immutable, individual files. Acknowledgement happens only
/// after the main app has persisted the corresponding tasks.
struct ImportInbox {
    static let groupIdentifier: String = {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "XHSAppGroupIdentifier") as? String {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("$(") { return trimmed }
        }
        return "group.com.neoruaa.xhsdn"
    }()
    let directory: URL

    static func shared() throws -> ImportInbox {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return ImportInbox(directory: root.appendingPathComponent("ImportInbox", isDirectory: true))
    }

    func append(_ request: ImportRequest) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: fileURL(request.id), options: .atomic)
    }

    func pending() throws -> [ImportRequest] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var requests: [ImportRequest] = []
        let decoder = JSONDecoder()
        for url in files {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            }
            do {
                requests.append(try decoder.decode(ImportRequest.self, from: data))
            } catch is DecodingError {
                // Quarantine/remove corrupt inbox entries so a single bad JSON
                // file cannot permanently poison all subsequent share imports.
                try? FileManager.default.removeItem(at: url)
            }
        }
        return requests.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    func acknowledge(_ id: UUID) throws {
        let url = fileURL(id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func migrateLegacyDefaults() throws {
        struct LegacyItem: Decodable { let id: UUID; let text: String; let createdAt: Date }
        let defaults = UserDefaults(suiteName: Self.groupIdentifier)
        guard let data = defaults?.data(forKey: "shared_inbox_items") else { return }
        let items: [LegacyItem]
        do {
            items = try JSONDecoder().decode([LegacyItem].self, from: data)
        } catch is DecodingError {
            defaults?.removeObject(forKey: "shared_inbox_items")
            return
        }
        for item in items {
            try append(ImportRequest(id: item.id, text: item.text, source: .share, createdAt: item.createdAt))
        }
        defaults?.removeObject(forKey: "shared_inbox_items")
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}
