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

/// One shared link grammar: the app and the share extension must agree on what
/// counts as a note link, otherwise the extension reports a different count from
/// the one the app will actually import.
enum ImportText {
    static let linkPattern = #"(?<![a-zA-Z0-9@.])(?:https?://)?(?:www\.)?(?:xiaohongshu\.com|rednote\.com|xhslink\.(?:com|cn))/[^\s<>\"',;，。；：！？、（）【】《》]+"#

    static func linkCount(in input: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive]) else { return 0 }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var seen = Set<String>()
        for match in expression.matches(in: input, range: range) {
            guard let swiftRange = Range(match.range, in: input) else { continue }
            seen.insert(String(input[swiftRange]).lowercased())
        }
        return seen.count
    }
}

/// Both processes use immutable, individual files. Acknowledgement happens only
/// after the main app has persisted the corresponding tasks.
struct ImportInbox {
    static let groupIdentifier = "group.com.neoruaa.xhsdn"
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
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(ImportRequest.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
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
        for item in try JSONDecoder().decode([LegacyItem].self, from: data) {
            try append(ImportRequest(id: item.id, text: item.text, source: .share, createdAt: item.createdAt))
        }
        defaults?.removeObject(forKey: "shared_inbox_items")
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}
