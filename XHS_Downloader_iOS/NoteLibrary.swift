import Foundation
import Photos
import Combine

struct LibraryMedia: Identifiable, Hashable {
    let id: String
    let width: Int
    let height: Int
    let isVideo: Bool
    let isLive: Bool
    let duration: TimeInterval
    let date: Date

    init(asset: PHAsset) {
        id = asset.localIdentifier
        width = asset.pixelWidth
        height = asset.pixelHeight
        isVideo = asset.mediaType == .video
        isLive = asset.mediaSubtypes.contains(.photoLive)
        duration = asset.duration
        date = asset.creationDate ?? .distantPast
    }

    init(id: String, width: Int = 1200, height: Int = 1600,
         isVideo: Bool = false, isLive: Bool = false, duration: TimeInterval = 0, date: Date = .distantPast) {
        self.id = id; self.width = width; self.height = height
        self.isVideo = isVideo; self.isLive = isLive; self.duration = duration; self.date = date
    }

    /// Files-only saves never produced a PHAsset, so the note keeps the archived
    /// path and renders from the file instead of disappearing from the feed.
    init?(record: MediaAssetRecord, lookup: [String: LibraryMedia]) {
        if let asset = lookup[record.localIdentifier] {
            self = asset
            return
        }
        let candidates = record.archivePaths
        // Keep an unavailable external archive visible, so it can be reauthorized.
        guard !candidates.isEmpty else { return nil }
        self.id = "file:" + candidates.joined(separator: "\n")
        width = record.pixelWidth ?? 1200
        height = record.pixelHeight ?? 1600
        isVideo = record.isVideo
        isLive = record.isLive ?? false
        duration = 0
        date = record.createdAt
    }

    var aspectRatio: CGFloat { width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : 0.75 }
}

struct LibraryNote: Identifiable, Hashable {
    let id: String
    let title: String
    let body: String
    let author: String
    let avatarURL: URL?
    let publishTime: String?
    let topics: [String]
    let sourceURL: URL?
    let date: Date
    let media: [LibraryMedia]
    var authorID: String? = nil
    var authorRedID: String? = nil
    var noteID: String? = nil
    var publishedAt: Date? = nil

    /// A note saved without media is still a note. It keeps its text, author and
    /// source, and the feed renders it as a summary card instead of a cover.
    var isTextOnly: Bool { media.isEmpty }

    /// Whether the stored author is a real identity or just the placeholder the
    /// feed shows. `authorKey` cannot answer this: the placeholder text is a
    /// non-empty author name, so it would look like a valid author.
    var hasKnownAuthor: Bool {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // These two strings are the feed's placeholders, not real names.
        return trimmed != L10n.text("feed.author.unknown") && trimmed != L10n.text("feed.author.saved")
    }

    var authorProfileURL: URL? {
        guard let authorID, !authorID.isEmpty else { return nil }
        return URL(string: "https://www.xiaohongshu.com/user/profile")?.appendingPathComponent(authorID)
    }

    /// The stable key used for author grouping, remarks and collection filters.
    var authorKey: String? {
        if let authorID, !authorID.isEmpty { return authorID }
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var cover: LibraryMedia? { media.first }
    var identifiers: [String] { media.map(\.id) }
    var coverRatio: CGFloat {
        guard let cover else { return 1.2 }
        return min(1.5, max(0.65, cover.aspectRatio))
    }

    func matches(query: String, filter: Int, remark: String? = nil) -> Bool {
        let matchesType = filter == 0 ||
            (filter == 1 && (media.isEmpty || media.contains { !$0.isVideo })) ||
            (filter == 2 && media.contains { $0.isVideo }) ||
            (filter == 3 && media.contains { $0.isLive })
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matchesType else { return false }
        guard !query.isEmpty else { return true }
        var fields = [title, body, author, topics.joined(separator: " ")]
        if let authorRedID { fields.append(authorRedID) }
        if let remark { fields.append(remark) }
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

extension NoteLibrary {
    static func selectedLinks(in notes: [LibraryNote], noteIDs: Set<String>) -> [String] {
        var seen = Set<String>()
        return notes.filter { noteIDs.contains($0.id) }.compactMap { note in
            guard let link = note.sourceURL?.absoluteString, seen.insert(link).inserted else { return nil }
            return link
        }
    }
}

enum NoteLibrary {
    /// Copy one link per selected note, in feed order. Album-only items do not
    /// invent a source URL, and a partially selected note is included once.
    static func selectedLinks(in notes: [LibraryNote], mediaIDs: Set<String>) -> [String] {
        var seen = Set<String>()
        return notes.compactMap { note in
            guard note.identifiers.contains(where: mediaIDs.contains),
                  let url = note.sourceURL, XHSURLDetector.containsSupportedLink(url.absoluteString),
                  seen.insert(url.absoluteString).inserted else { return nil }
            return url.absoluteString
        }
    }

    /// Keep one card per saved task, in original media order. Photos that no
    /// longer have a history record remain available as standalone cards, and a
    /// task saved as text only still produces a readable note.
    static func notes(tasks: [DownloadTaskRecord], media: [LibraryMedia]) -> [LibraryNote] {
        let lookup = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<String>()
        var notes: [LibraryNote] = []
        for task in tasks.sorted(by: { $0.createdAt > $1.createdAt }) {
            var seen = Set<String>()
            let available = task.mediaAssets.compactMap { record -> LibraryMedia? in
                guard seen.insert(record.localIdentifier).inserted else { return nil }
                return lookup[record.localIdentifier]
            }
            let metadata = task.resolvedNote?.metadata
            let body = task.noteText.isEmpty ? task.resolvedNote?.body ?? "" : task.noteText
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !available.isEmpty || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            used.formUnion(available.map(\.id))
            let author = metadata?.userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            notes.append(LibraryNote(
                id: task.id.uuidString, title: title.isEmpty ? String(body.prefix(80)) : title,
                body: body, author: author.isEmpty ? L10n.text("feed.author.unknown") : author,
                avatarURL: metadata?.avatarURL, publishTime: metadata?.publishTime,
                topics: metadata?.topics ?? [], sourceURL: task.resolvedNote?.canonicalURL ?? URL(string: task.normalizedURL),
                date: task.createdAt, media: available, authorID: metadata?.userId, authorRedID: metadata?.redId,
                noteID: task.resolvedNote?.noteID,
                publishedAt: metadata?.publishedAt
            ))
        }
        for asset in media where !used.contains(asset.id) {
            notes.append(LibraryNote(id: "asset:" + asset.id,
                                     title: L10n.text(asset.isVideo ? "note.type.video" : asset.isLive ? "note.type.live_photo" : "note.type.image"),
                                     body: "", author: L10n.text("feed.author.saved"), avatarURL: nil,
                                     publishTime: nil, topics: [], sourceURL: nil, date: asset.date, media: [asset]))
        }
        return notes.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    /// Sorting is a display choice: saved time is the local truth, published time
    /// only wins when the note actually carries one.
    static func sorted(_ notes: [LibraryNote], by order: NoteSortOrder) -> [LibraryNote] {
        switch order {
        case .savedNewest:
            return notes.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        case .savedOldest:
            return notes.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        case .publishedNewest:
            // Old notes only have the displayed day; new notes retain the exact
            // instant. Resolve each key once, outside the sorting comparator.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return notes.map { note in
                var day = note.publishTime ?? ""
                if day.count == 8 { day = "20" + day }
                let legacy = formatter.date(from: day)
                return (note: note, published: note.publishedAt ?? legacy ?? note.date)
            }.sorted { lhs, rhs in
                if lhs.published != rhs.published { return lhs.published > rhs.published }
                if lhs.note.date != rhs.note.date { return lhs.note.date > rhs.note.date }
                return lhs.note.id < rhs.note.id
            }.map(\.note)
        }
    }

    static func columns(_ notes: [LibraryNote], count: Int) -> [[LibraryNote]] {
        let count = max(1, count)
        var columns = Array(repeating: [LibraryNote](), count: count)
        var heights = Array(repeating: CGFloat.zero, count: count)
        for note in notes {
            let index = heights.indices.min(by: { heights[$0] < heights[$1] }) ?? 0
            columns[index].append(note)
            heights[index] += 1 / note.coverRatio + 0.48
        }
        return columns
    }
}

enum NoteSortOrder: String, CaseIterable, Identifiable {
    case savedNewest, savedOldest, publishedNewest
    var id: String { rawValue }
    var localizationKey: String {
        switch self {
        case .savedNewest: return "library.sort.saved_newest"
        case .savedOldest: return "library.sort.saved_oldest"
        case .publishedNewest: return "library.sort.published_newest"
        }
    }
}

struct NoteCollection: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var noteIDs: Set<String>

    init(id: UUID = UUID(), name: String, noteIDs: Set<String> = []) {
        self.id = id
        self.name = name
        self.noteIDs = noteIDs
    }
}

@MainActor
final class NoteLibraryPreferences: ObservableObject {
    @Published private(set) var likes: Set<String>
    @Published private(set) var bookmarks: Set<String>
    @Published private(set) var collections: [NoteCollection]
    @Published private(set) var authorRemarks: [String: String]
    @Published var sortOrder: NoteSortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: "library.sortOrder") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        likes = Set(defaults.stringArray(forKey: "library.likedNotes") ?? [])
        bookmarks = Set(defaults.stringArray(forKey: "library.bookmarkedNotes") ?? [])
        collections = (defaults.data(forKey: "library.collections").flatMap {
            try? JSONDecoder().decode([NoteCollection].self, from: $0)
        }) ?? []
        authorRemarks = (defaults.data(forKey: "library.authorRemarks").flatMap {
            try? JSONDecoder().decode([String: String].self, from: $0)
        }) ?? [:]
        sortOrder = defaults.string(forKey: "library.sortOrder")
            .flatMap(NoteSortOrder.init(rawValue:)) ?? .savedNewest
    }

    func toggleLike(_ id: String) {
        if !likes.insert(id).inserted { likes.remove(id) }
        defaults.set(likes.sorted(), forKey: "library.likedNotes")
        AppFeedback.play(.selection)
    }

    func toggleBookmark(_ id: String) {
        if !bookmarks.insert(id).inserted { bookmarks.remove(id) }
        defaults.set(bookmarks.sorted(), forKey: "library.bookmarkedNotes")
        AppFeedback.play(.selection)
    }

    // MARK: - Collections

    @discardableResult
    func createCollection(named name: String) -> NoteCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let collection = NoteCollection(name: trimmed)
        collections.append(collection)
        saveCollections()
        AppFeedback.play(.selection)
        return collection
    }

    func renameCollection(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].name = trimmed
        saveCollections()
    }

    /// Deleting a collection never deletes notes: the local library is the
    /// source of truth and collections are only a view over it.
    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        saveCollections()
    }

    func setMembership(_ noteIDs: Set<String>, in collectionID: UUID, included: Bool) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if included { collections[index].noteIDs.formUnion(noteIDs) }
        else { collections[index].noteIDs.subtract(noteIDs) }
        saveCollections()
    }

    func contains(_ noteID: String, in collectionID: UUID) -> Bool {
        collections.first { $0.id == collectionID }?.noteIDs.contains(noteID) ?? false
    }

    // MARK: - Author remarks

    func remark(for authorKey: String?) -> String? {
        guard let authorKey else { return nil }
        return authorRemarks[authorKey]
    }

    func setRemark(_ remark: String, for authorKey: String) {
        let trimmed = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { authorRemarks.removeValue(forKey: authorKey) }
        else { authorRemarks[authorKey] = trimmed }
        defaults.set(try? JSONEncoder().encode(authorRemarks), forKey: "library.authorRemarks")
    }

    private func saveCollections() {
        defaults.set(try? JSONEncoder().encode(collections), forKey: "library.collections")
    }
}
