import Foundation

/// Notes are the durable product of the app; tasks are just the work that
/// produced them. Keeping them in one file makes "remove finished history" a
/// task-only operation and lets a note survive failed media, a Files-only save,
/// and a restored backup.
struct StoredNote: Identifiable, Codable, Hashable {
    /// Stable join key. A note ID is preferred because the same note can be
    /// downloaded twice from different share links.
    var id: String
    var noteID: String?
    var canonicalURL: String
    var title: String
    var body: String
    var metadata: NoteMetadata
    var createdAt: Date
    var updatedAt: Date
    var mediaAssets: [MediaAssetRecord]
    var archiveTextPaths: [String]
    /// Caption paths that already existed on disk and were reused via
    /// `skipExisting`. Note deletion must never unlink pre-existing user files.
    var reusedArchiveTextPaths: [String]? = nil
    var informationOnly: Bool
    var archiveGrants: [ArchiveGrant]?

    init(id: String,
         noteID: String?,
         canonicalURL: String,
         title: String,
         body: String,
         metadata: NoteMetadata,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         mediaAssets: [MediaAssetRecord] = [],
         archiveTextPaths: [String] = [],
         informationOnly: Bool = false,
         archiveGrants: [ArchiveGrant]? = nil,
         reusedArchiveTextPaths: [String]? = nil) {
        self.id = id
        self.noteID = noteID
        self.canonicalURL = canonicalURL
        self.title = title
        self.body = body
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.mediaAssets = mediaAssets
        self.archiveTextPaths = archiveTextPaths
        self.reusedArchiveTextPaths = reusedArchiveTextPaths
        self.informationOnly = informationOnly
        self.archiveGrants = archiveGrants
    }

    static func key(noteID: String?, url: String) -> String {
        if let noteID, !noteID.isEmpty { return "note:" + noteID }
        return "url:" + url
    }

    /// A note is worth keeping when it carries text, media, or author identity.
    var isMeaningful: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !mediaAssets.isEmpty
            || metadata.userName?.isEmpty == false
    }

    var archivePaths: [String] {
        Array(Set(archiveTextPaths + mediaAssets.flatMap(\.archivePaths))).sorted()
    }
}

/// A small, explicit store: one JSON document, atomic writes, one rolling
/// backup. It never derives notes from tasks, so deleting a task cannot delete a
/// note, and a note whose media all failed still keeps its text.
actor NoteStore {
    nonisolated let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private(set) var loadError: String?

    init(fileURL: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = support.appendingPathComponent("XHSDownloader", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("notes-v1.json")
        }
    }

    func load() -> [StoredNote] {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: backupURL),
               let notes = try? decoder.decode([StoredNote].self, from: data) {
                return notes
            }
            return []
        }
        do {
            return try decoder.decode([StoredNote].self, from: Data(contentsOf: fileURL))
        } catch {
            loadError = error.localizedDescription
            // Never replace an unreadable note file with an empty one; try the
            // rolling backup so a corrupt write does not lose the library.
            let backup = backupURL
            if let data = try? Data(contentsOf: backup),
               let notes = try? decoder.decode([StoredNote].self, from: data) {
                return notes
            }
            return []
        }
    }

    func save(_ notes: [StoredNote]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sorted = notes.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
        let data = try encoder.encode(sorted)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let previous = try Data(contentsOf: fileURL)
            if (try? decoder.decode([StoredNote].self, from: previous)) != nil {
                if previous == data {
                    // An unchanged second save still establishes the recovery
                    // copy; later repeats keep the previous distinct generation.
                    if !FileManager.default.fileExists(atPath: backupURL.path) {
                        try previous.write(to: backupURL, options: .atomic)
                    }
                    return
                }
                // Keep the last readable generation, not the first-ever save.
                try previous.write(to: backupURL, options: .atomic)
            } else {
                // A recovered backup may replace corrupt primary data. Without
                // a readable backup, refuse to overwrite the only copy.
                guard let backup = try? Data(contentsOf: backupURL),
                      (try? decoder.decode([StoredNote].self, from: backup)) != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    private var backupURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("backup.json")
    }
}

extension NoteLibrary {
    /// Builds feed entries from stored notes instead of from task records, so
    /// removing history only removes work history.
    static func notes(stored: [StoredNote], media: [LibraryMedia], hiddenMediaIDs: Set<String> = []) -> [LibraryNote] {
        let lookup = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<String>()
        var result: [LibraryNote] = []
        for note in stored {
            var seen = Set<String>()
            let available = note.mediaAssets.compactMap { record -> LibraryMedia? in
                guard seen.insert(record.localIdentifier).inserted else { return nil }
                // Files-only saves have no PHAsset: resolve the recorded path so
                // the note still shows its media without photo permission.
                return LibraryMedia(record: record, lookup: lookup)
            }
            used.formUnion(available.map(\.id))
            let trimmedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBody = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAuthor = note.metadata.userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !available.isEmpty || !trimmedBody.isEmpty || !trimmedTitle.isEmpty || !trimmedAuthor.isEmpty else { continue }
            result.append(LibraryNote(
                id: note.id,
                title: trimmedTitle.isEmpty ? String(trimmedBody.prefix(80)) : trimmedTitle,
                body: note.body,
                author: trimmedAuthor.isEmpty ? L10n.text("feed.author.unknown") : trimmedAuthor,
                avatarURL: note.metadata.avatarURL,
                publishTime: note.metadata.publishTime,
                topics: note.metadata.topics ?? [],
                sourceURL: URL(string: note.canonicalURL),
                date: note.createdAt,
                media: available,
                authorID: note.metadata.userId,
                authorRedID: note.metadata.redId,
                noteID: note.noteID,
                publishedAt: note.metadata.publishedAt
            ))
        }
        // Photos that no longer have a note stay visible as standalone cards
        // unless the user explicitly deleted the note while keeping originals.
        for asset in media where !used.contains(asset.id) && !hiddenMediaIDs.contains(asset.id) {
            result.append(LibraryNote(id: "asset:" + asset.id,
                                      title: L10n.text(asset.isVideo ? "note.type.video" : asset.isLive ? "note.type.live_photo" : "note.type.image"),
                                      body: "", author: L10n.text("feed.author.saved"), avatarURL: nil,
                                      publishTime: nil, topics: [], sourceURL: nil, date: asset.date, media: [asset]))
        }
        return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
}
