import Foundation

/// A backup never carries credentials (cookies, proxy passwords) or
/// device-specific capabilities (security-scoped bookmarks) or volatile state
/// (staged transfer paths, draft selections). Only durable note data travels.
struct BackupDocument: Codable {
    static let currentVersion = 2
    static let fileExtension = "xhsbackup"

    var version: Int
    var exportedAt: Date
    var tasks: [BackupEntry]
    /// Notes are exported independently of tasks so a history cleanup cannot
    /// shrink a backup.
    var notes: [StoredNote]
    var collections: [NoteCollection]
    var likedNotes: [String]
    var bookmarkedNotes: [String]
    var authorRemarks: [String: String]
    var settings: BackupSettings?
    var avatars: [BackupAvatar]

    init(version: Int = BackupDocument.currentVersion,
         exportedAt: Date = Date(),
         tasks: [BackupEntry] = [],
         notes: [StoredNote] = [],
         collections: [NoteCollection] = [],
         likedNotes: [String] = [],
         bookmarkedNotes: [String] = [],
         authorRemarks: [String: String] = [:],
         settings: BackupSettings? = nil,
         avatars: [BackupAvatar] = []) {
        self.version = version
        self.exportedAt = exportedAt
        self.tasks = tasks
        self.notes = notes
        self.collections = collections
        self.likedNotes = likedNotes
        self.bookmarkedNotes = bookmarkedNotes
        self.authorRemarks = authorRemarks
        self.settings = settings
        self.avatars = avatars
    }

    /// Version 1 documents only had tasks. Decoding tolerates that so an older
    /// backup still imports.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        tasks = try container.decodeIfPresent([BackupEntry].self, forKey: .tasks) ?? []
        notes = try container.decodeIfPresent([StoredNote].self, forKey: .notes) ?? []
        collections = try container.decodeIfPresent([NoteCollection].self, forKey: .collections) ?? []
        likedNotes = try container.decodeIfPresent([String].self, forKey: .likedNotes) ?? []
        bookmarkedNotes = try container.decodeIfPresent([String].self, forKey: .bookmarkedNotes) ?? []
        authorRemarks = try container.decodeIfPresent([String: String].self, forKey: .authorRemarks) ?? [:]
        settings = try container.decodeIfPresent(BackupSettings.self, forKey: .settings)
        avatars = try container.decodeIfPresent([BackupAvatar].self, forKey: .avatars) ?? []
    }
}

/// Portable preferences. Credentials (cookies, proxy, folder bookmark) are
/// deliberately absent.
struct BackupSettings: Codable, Hashable {
    var policy: DownloadPolicy
    var livePhotoMode: LivePhotoMode
    var selectiveDownload: Bool
    var notifications: Bool
    var debugNotifications: Bool
    var haptics: Bool
    var appearance: String
    var keepScreenAwake: Bool
    var clipboardSuggestions: Bool
    var namingEnabled: Bool
    var namingTemplate: String
    var namingTimeZone: String

    init(policy: DownloadPolicy = DownloadPolicy(),
         livePhotoMode: LivePhotoMode = .merged,
         selectiveDownload: Bool = false,
         notifications: Bool = false,
         debugNotifications: Bool = false,
         haptics: Bool = true,
         appearance: String = "system",
         keepScreenAwake: Bool = false,
         clipboardSuggestions: Bool = false,
         namingEnabled: Bool = false,
         namingTemplate: String = NamingFormatter.defaultTemplate,
         namingTimeZone: String = TimeZone.current.identifier) {
        self.policy = policy
        self.livePhotoMode = livePhotoMode
        self.selectiveDownload = selectiveDownload
        self.notifications = notifications
        self.debugNotifications = debugNotifications
        self.haptics = haptics
        self.appearance = appearance
        self.keepScreenAwake = keepScreenAwake
        self.clipboardSuggestions = clipboardSuggestions
        self.namingEnabled = namingEnabled
        self.namingTemplate = namingTemplate
        self.namingTimeZone = namingTimeZone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policy = try c.decodeIfPresent(DownloadPolicy.self, forKey: .policy) ?? DownloadPolicy()
        livePhotoMode = try c.decodeIfPresent(LivePhotoMode.self, forKey: .livePhotoMode) ?? .merged
        selectiveDownload = try c.decodeIfPresent(Bool.self, forKey: .selectiveDownload) ?? false
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? false
        debugNotifications = try c.decodeIfPresent(Bool.self, forKey: .debugNotifications) ?? false
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? true
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        keepScreenAwake = try c.decodeIfPresent(Bool.self, forKey: .keepScreenAwake) ?? false
        clipboardSuggestions = try c.decodeIfPresent(Bool.self, forKey: .clipboardSuggestions) ?? false
        namingEnabled = try c.decodeIfPresent(Bool.self, forKey: .namingEnabled) ?? policy.namingEnabled
        namingTemplate = try c.decodeIfPresent(String.self, forKey: .namingTemplate) ?? policy.namingTemplate
        namingTimeZone = try c.decodeIfPresent(String.self, forKey: .namingTimeZone) ?? policy.namingTimezone
    }
}

/// Avatar bytes travel with the backup so a restored library still has author
/// images without hitting the network.
struct BackupAvatar: Codable, Hashable {
    var url: String
    var data: Data
}

struct BackupEntry: Codable {
    var identity: String
    var record: DownloadTaskRecord

    /// Notes are merged by their stable identity so importing the same backup
    /// twice cannot duplicate a note, and a renamed title still matches.
    static func identity(of record: DownloadTaskRecord) -> String {
        if let noteID = record.resolvedNote?.noteID, !noteID.isEmpty { return "note:" + noteID }
        return "url:" + redactedURL(record.normalizedURL)
    }

    static func make(from record: DownloadTaskRecord) -> BackupEntry {
        var copy = record
        copy.stagedFiles = nil
        copy.draftSelectionIDs = nil
        copy.importRequestID = nil
        copy.selectedMediaIDs = nil
        copy.resourceResults = nil
        copy.phase = nil
        copy.historyHidden = nil
        copy.libraryHidden = nil
        // Keep the media policy choices but drop the folder capability.
        if var policy = copy.policy {
            policy.filesBookmark = nil
            policy.proxy = ""
            copy.policy = policy
        }
        // Redaction: the raw share text, access tokens in URLs and archived
        // absolute paths are device-private. Only the canonical note identity and
        // user-visible text are exported.
        copy.sourceText = ""
        copy.normalizedURL = Self.redactedURL(copy.normalizedURL)
        copy.noteKey = copy.noteKey.map(Self.portableNoteKey)
        copy.archiveTextPaths = nil
        copy.reusedArchiveTextPaths = nil
        if let note = copy.resolvedNote {
            copy.resolvedNote = ResolvedNote(
                noteID: note.noteID,
                canonicalURL: URL(string: Self.redactedURL(note.canonicalURL.absoluteString)) ?? note.canonicalURL,
                title: note.title, body: note.body,
                metadata: Self.redactedMetadata(note.metadata), media: [])
        }
        copy.mediaAssets = copy.mediaAssets.map(Self.redactedAsset)
        if [.downloading, .queued, .waitingForUser].contains(copy.status) { copy.status = .paused }
        return BackupEntry(identity: identity(of: copy), record: copy)
    }

    /// Strips device-private detail from a stored note while keeping everything a
    /// restored library needs: identity, text, author and media descriptors.
    static func redactedNote(_ note: StoredNote) -> StoredNote {
        var copy = note
        copy.id = portableNoteKey(note.id)
        copy.canonicalURL = redactedURL(note.canonicalURL)
        copy.archiveTextPaths = []
        copy.reusedArchiveTextPaths = nil
        copy.archiveGrants = nil
        copy.metadata = redactedMetadata(note.metadata)
        copy.mediaAssets = note.mediaAssets.map(redactedAsset)
        return copy
    }

    /// The author profile URL carries the same access token as the note URL, so it
    /// must be stripped too; otherwise a redacted note still leaks `xsec_token`.
    static func redactedMetadata(_ metadata: NoteMetadata) -> NoteMetadata {
        var clean = metadata
        if let profile = metadata.profileURL {
            clean.profileURL = URL(string: redactedURL(profile.absoluteString))
        }
        if let avatar = metadata.avatarURL, avatar.absoluteString.contains("?") {
            clean.avatarURL = URL(string: redactedURL(avatar.absoluteString))
        }
        return clean
    }

    /// A `file:` identifier embeds the absolute archive path; blank it to the
    /// scheme so the descriptor survives without revealing the location.
    static func redactedAsset(_ asset: MediaAssetRecord) -> MediaAssetRecord {
        var clean = asset
        clean.filesPaths = nil
        clean.reusedFilesPaths = nil
        if clean.localIdentifier.hasPrefix("file:") { clean.localIdentifier = "file:" }
        return clean
    }

    /// Drops query and fragment, which is where `xsec_token`, `xsec_source` and
    /// tracking parameters live.
    static func redactedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url?.absoluteString ?? value
    }

    static func portableNoteKey(_ value: String) -> String {
        guard value.hasPrefix("url:") else { return value }
        return "url:" + redactedURL(String(value.dropFirst(4)))
    }
}

enum BackupError: LocalizedError {
    case unsupportedVersion(Int)
    case emptySelection
    case zipTooLarge(String)
    case partialImport(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return L10n.format("backup.error.version", version)
        case .emptySelection: return L10n.text("backup.error.empty")
        case .zipTooLarge(let name): return L10n.format("backup.error.zip", name)
        case .partialImport(let reason): return L10n.format("backup.error.partial_import", reason)
        }
    }
}

struct BackupImportSummary: Sendable {
    var added = 0
    var merged = 0
    var skipped = 0
}

struct StorageUsage: Sendable {
    var previews: Int64 = 0
    var avatars: Int64 = 0
    var pending: Int64 = 0

    var total: Int64 { previews + avatars + pending }
}

actor BackupService {
    static let shared = BackupService()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    private func makeExportDirectory() throws -> URL {
        let directory = exportDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Records

    func exportJSON(tasks: [DownloadTaskRecord], library: BackupLibraryPayload) async throws -> URL {
        let directory = try makeExportDirectory()
        var document = BackupDocument(tasks: tasks.map(BackupEntry.make(from:)))
        // Notes go through the same redaction as task records: canonical URLs
        // lose their access tokens and archived absolute paths are dropped.
        document.notes = library.notes.map(BackupEntry.redactedNote)
        document.collections = library.collections.map { collection in
            var copy = collection
            copy.noteIDs = Set(collection.noteIDs.map(BackupEntry.portableNoteKey))
            return copy
        }
        document.likedNotes = library.likedNotes.map(BackupEntry.portableNoteKey).sorted()
        document.bookmarkedNotes = library.bookmarkedNotes.map(BackupEntry.portableNoteKey).sorted()
        document.authorRemarks = library.authorRemarks
        if var sanitizedSettings = library.settings {
            // Defense in depth: never write proxy credentials or device bookmarks.
            sanitizedSettings.policy.proxy = ""
            sanitizedSettings.policy.filesBookmark = nil
            document.settings = sanitizedSettings
        }
        document.avatars = await Self.collectAvatars(library.notes)
        let data = try encoder.encode(document)
        let url = directory.appendingPathComponent("xhs-notes-\(Self.stamp()).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func collectAvatars(_ notes: [StoredNote]) async -> [BackupAvatar] {
        var seen = Set<String>()
        var result: [BackupAvatar] = []
        for note in notes {
            guard let url = note.metadata.avatarURL, seen.insert(url.absoluteString).inserted else { continue }
            if let data = await AuthorAvatarStore.shared.cachedData(for: url) {
                result.append(BackupAvatar(url: BackupEntry.redactedURL(url.absoluteString), data: data))
            }
        }
        return result
    }

    struct BackupLibraryPayload: Sendable {
        var notes: [StoredNote] = []
        var collections: [NoteCollection] = []
        var likedNotes: Set<String> = []
        var bookmarkedNotes: Set<String> = []
        var authorRemarks: [String: String] = [:]
        var settings: BackupSettings?
    }

    func exportCSV(_ tasks: [DownloadTaskRecord]) throws -> URL {
        let directory = try makeExportDirectory()
        let formatter = ISO8601DateFormatter()
        var rows = ["id,title,note_id,url,author,red_id,status,type,media,saved,failed,created_at,updated_at"]
        for task in tasks {
            let fields = [
                task.id.uuidString,
                task.title,
                task.resolvedNote?.noteID ?? "",
                BackupEntry.redactedURL(task.normalizedURL),
                task.resolvedNote?.metadata.userName ?? "",
                task.resolvedNote?.metadata.redId ?? "",
                task.status.rawValue,
                task.noteType.rawValue,
                String(task.mediaCount),
                String(task.savedCount),
                String(task.failedCount),
                formatter.string(from: task.createdAt),
                formatter.string(from: task.updatedAt)
            ]
            rows.append(fields.map(Self.escapeCSV).joined(separator: ","))
        }
        let url = directory.appendingPathComponent("xhs-notes-\(Self.stamp()).csv")
        // A BOM keeps Excel from mangling Chinese titles.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(rows.joined(separator: "\n").utf8))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Originals, captions and a manifest in one archive. Media that only exists
    /// in Photos is read back through `PhotoOriginalExporter`, so a default
    /// "Photos" library exports real originals rather than an empty archive.
    /// Live Photos keep both components and their pairing in the manifest.
    private struct ExportedComponent {
        let url: URL
        let isVideo: Bool
        let isPairedVideo: Bool
        let byteCount: Int64
    }

    /// The manifest must describe each file, not reuse the asset's byte count.
    private static func byteCount(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    struct ArchiveExport: Sendable {
        let url: URL
        /// Resources that could not be read. An archive with failures is still
        /// produced, but the caller must tell the user it is incomplete.
        let failures: [String]
    }

    func exportArchive(_ notes: [StoredNote]) async throws -> ArchiveExport {
        let directory = try makeExportDirectory()
        let zipURL = directory.appendingPathComponent("xhs-notes-\(Self.stamp()).zip")
        let writer = try ZipWriter(url: zipURL)
        var manifest: [String] = ["file,note_id,source_media_id,is_video,is_live,component,bytes"]
        var used = Set<String>()
        var failures: [String] = []
        var scratch: [URL] = []
        defer { for url in scratch { try? FileManager.default.removeItem(at: url) } }

        for note in notes {
            let folder = Self.folderName(for: note)
            for asset in note.mediaAssets {
                var exported: [ExportedComponent] = []
                // Every recorded path is checked individually: a Live Photo with
                // only its still present used to pass as complete.
                let recorded = asset.archivePaths
                var missingPath = false
                let lease = try? ArchiveAccess.shared.lease(paths: recorded, grants: note.archiveGrants ?? [])
                defer { withExtendedLifetime(lease) {} }
                if lease == nil && !recorded.isEmpty { missingPath = true }
                for url in lease?.urls ?? [] {
                    guard FileManager.default.fileExists(atPath: url.path) else { missingPath = true; continue }
                    // The motion component is a video even though the asset is a photo.
                    let isVideo = asset.isVideo || MediaFileValidator.isVideoFile(url)
                    exported.append(ExportedComponent(url: url, isVideo: isVideo,
                                                      isPairedVideo: asset.isVideo == false && isVideo,
                                                      byteCount: Self.byteCount(of: url)))
                }

                // Photos is the remaining source. It is also consulted when a
                // recorded component is missing or a Live Photo only archived
                // one component, so a half-archived Live Photo can still be
                // completed from the library.
                let needsPhotos = exported.isEmpty || missingPath || ((asset.isLive ?? false) && exported.count < 2)
                if needsPhotos, !asset.localIdentifier.hasPrefix("file:"), !asset.localIdentifier.isEmpty {
                    let scratchDirectory = directory.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
                    scratch.append(scratchDirectory)
                    do {
                        let originals = try await PhotoOriginalExporter.shared.export(
                            localIdentifier: asset.localIdentifier, into: scratchDirectory)
                        // Replace rather than append: the library copy is complete.
                        exported = originals.map {
                            ExportedComponent(url: $0.fileURL, isVideo: $0.isVideo,
                                              isPairedVideo: $0.isPairedVideo,
                                              byteCount: Self.byteCount(of: $0.fileURL))
                        }
                    } catch {
                        if exported.isEmpty {
                            failures.append(asset.fileName.isEmpty ? asset.localIdentifier : asset.fileName)
                        }
                    }
                } else if exported.isEmpty {
                    failures.append(asset.fileName.isEmpty ? asset.localIdentifier : asset.fileName)
                }

                // A Live Photo that ended up with only one component is incomplete.
                if (asset.isLive ?? false), !exported.isEmpty, exported.count < 2 {
                    failures.append(asset.fileName.isEmpty ? asset.localIdentifier : asset.fileName)
                }

                for item in exported {
                    let base = folder + "/" + (asset.fileName.isEmpty ? item.url.lastPathComponent : asset.fileName)
                    let name = Self.unique(base, in: &used, keepingExtensionOf: item.url)
                    try writer.add(file: item.url, name: name)
                    manifest.append([
                        Self.escapeCSV(name),
                        Self.escapeCSV(note.noteID ?? ""),
                        Self.escapeCSV(asset.sourceMediaID ?? ""),
                        item.isVideo ? "true" : "false",
                        (asset.isLive ?? false) ? "true" : "false",
                        item.isPairedVideo ? "pairedVideo" : (item.isVideo ? "video" : "photo"),
                        String(item.byteCount)
                    ].joined(separator: ","))
                }
            }
            for path in note.archiveTextPaths {
                do {
                    let lease = try ArchiveAccess.shared.lease(paths: [path], grants: note.archiveGrants ?? [])
                    defer { withExtendedLifetime(lease) {} }
                    guard let fileURL = lease.urls.first else { throw CocoaError(.fileNoSuchFile) }
                    let base = folder + "/" + fileURL.lastPathComponent
                    let name = Self.unique(base, in: &used, keepingExtensionOf: fileURL)
                    try writer.add(file: fileURL, name: name)
                } catch { failures.append(URL(fileURLWithPath: path).lastPathComponent) }
            }
            if let text = note.body.nilIfEmpty {
                let name = folder + "/caption.txt"
                if used.insert(name).inserted {
                    try writer.add(data: Data(text.utf8), name: name)
                }
            }
        }

        // The manifest records what is actually inside, including omissions.
        if !failures.isEmpty {
            manifest.append("# missing," + failures.map(Self.escapeCSV).joined(separator: ","))
        }
        try writer.add(data: Data(manifest.joined(separator: "\n").utf8), name: "manifest.csv")
        try writer.close()
        return ArchiveExport(url: zipURL, failures: failures)
    }

    func importBackup(from url: URL) throws -> BackupDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let rawObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              !Set(rawObject.keys).isDisjoint(with: ["version", "tasks", "notes", "collections", "likedNotes", "settings"]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let document = try decoder.decode(BackupDocument.self, from: data)
        guard (1...BackupDocument.currentVersion).contains(document.version) else {
            throw BackupError.unsupportedVersion(document.version)
        }
        return document
    }

    /// Re-writes avatar bytes into the local cache after an import, so restored
    /// notes show author images offline.
    func restoreAvatars(_ avatars: [BackupAvatar]) async {
        for avatar in avatars {
            guard let url = URL(string: avatar.url) else { continue }
            _ = try? await AuthorAvatarStore.shared.store(data: avatar.data, for: url)
        }
    }

    // MARK: - Storage

    func usage(previewCacheBytes: Int64) -> StorageUsage {
        var usage = StorageUsage()
        usage.previews = previewCacheBytes
        usage.avatars = Self.size(of: Self.supportDirectory("AuthorAvatars"))
        usage.pending = Self.size(of: Self.supportDirectory("Transfers"))
        return usage
    }

    func clearPreviews() async {
        await ArchiveMediaLoader.shared.clearThumbnails()
        URLCache.shared.removeAllCachedResponses()
    }

    // MARK: - Helpers

    private static func supportDirectory(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    static func size(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    static func folderName(for note: StoredNote) -> String {
        let author = FileArchiver.directoryComponent(
            [note.metadata.userName, note.metadata.userId].compactMap { $0 }.joined(separator: "_"),
            fallback: "unknown-author")
        let title = note.noteID.map { note.title.isEmpty ? $0 : note.title + "_" + $0 } ?? note.title
        let folder = FileArchiver.directoryComponent(title.nilIfEmpty ?? note.canonicalURL, fallback: note.id)
        return author + "/" + folder
    }

    private static func unique(_ base: String, in used: inout Set<String>, keepingExtensionOf url: URL) -> String {
        let ext = url.pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        let stem = base.hasSuffix(suffix) && !suffix.isEmpty ? String(base.dropLast(suffix.count)) : base
        var candidate = base.hasSuffix(suffix) && !suffix.isEmpty ? base : stem + suffix
        var counter = 2
        while used.contains(candidate) {
            candidate = stem + "_" + String(counter) + suffix
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func escapeCSV(_ value: String) -> String {
        var safe = value
        if let first = safe.first, "=+-@\t\r".contains(first) {
            safe = "'" + safe
        }
        guard safe.contains(",") || safe.contains("\"") || safe.contains("\n") || safe.contains("\r") else { return safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - ZIP

/// A stored (uncompressed) ZIP writer. Media files are already compressed, so
/// storing them avoids a second pass over hundreds of megabytes.
final class ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var closed = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle.close() }

    func add(file: URL, name: String) throws {
        let timestamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let fileSize = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard entries.count < Int(UInt16.max) else { throw BackupError.zipTooLarge(name) }
        guard fileSize < UInt64(UInt32.max) else { throw BackupError.zipTooLarge(name) }
        let nameData = Data(name.utf8)
        guard nameData.count < Int(UInt16.max) else { throw BackupError.zipTooLarge(name) }
        let currentOffset = handle.offsetInFile
        let localHeaderSize = UInt64(30 + nameData.count)
        guard currentOffset < UInt64(UInt32.max),
              currentOffset + localHeaderSize + fileSize < UInt64(UInt32.max) else {
            throw BackupError.zipTooLarge(name)
        }

        // Stream CRC32 first in 1MB chunks so multi-hundred-MB videos never OOM.
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var crcState: UInt32 = 0xFFFF_FFFF
        var actualSize: UInt64 = 0
        let chunkSize = 1024 * 1024
        while true {
            let chunk: Data? = try autoreleasepool { try reader.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            crcState = CRC32.update(crcState, with: chunk)
            actualSize += UInt64(chunk.count)
            guard actualSize < UInt64(UInt32.max) else { throw BackupError.zipTooLarge(name) }
        }
        let crc = crcState ^ 0xFFFF_FFFF
        let size = UInt32(actualSize)
        let offset = UInt32(currentOffset)
        let (time, date) = Self.dosTimestamp(timestamp)

        var header = Data()
        header.appendLE(UInt32(0x0403_4B50))
        header.appendLE(UInt16(20))
        header.appendLE(UInt16(0x0800))
        header.appendLE(UInt16(0))
        header.appendLE(time)
        header.appendLE(date)
        header.appendLE(crc)
        header.appendLE(size)
        header.appendLE(size)
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(0))
        header.append(nameData)
        try handle.write(contentsOf: header)

        try reader.seek(toOffset: 0)
        while true {
            let chunk: Data? = try autoreleasepool { try reader.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            try handle.write(contentsOf: chunk)
        }
        entries.append(Entry(name: nameData, crc: crc, size: size, offset: offset, dosTime: time, dosDate: date))
    }

    func add(data: Data, name: String) throws {
        try add(data: data, name: name, timestamp: Date())
    }

    private func add(data: Data, name: String, timestamp: Date) throws {
        guard entries.count < Int(UInt16.max) else { throw BackupError.zipTooLarge(name) }
        guard UInt64(data.count) < UInt64(UInt32.max) else { throw BackupError.zipTooLarge(name) }
        let nameData = Data(name.utf8)
        guard nameData.count < Int(UInt16.max) else { throw BackupError.zipTooLarge(name) }
        let currentOffset = handle.offsetInFile
        guard currentOffset < UInt64(UInt32.max),
              currentOffset + UInt64(30 + nameData.count + data.count) < UInt64(UInt32.max) else {
            throw BackupError.zipTooLarge(name)
        }
        let crc = CRC32.checksum(data)
        let size = UInt32(data.count)
        let offset = UInt32(currentOffset)
        let (time, date) = Self.dosTimestamp(timestamp)

        var header = Data()
        header.appendLE(UInt32(0x0403_4B50))
        header.appendLE(UInt16(20))
        header.appendLE(UInt16(0x0800))
        header.appendLE(UInt16(0))
        header.appendLE(time)
        header.appendLE(date)
        header.appendLE(crc)
        header.appendLE(size)
        header.appendLE(size)
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(0))
        header.append(nameData)
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: data)
        entries.append(Entry(name: nameData, crc: crc, size: size, offset: offset, dosTime: time, dosDate: date))
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        let rawOffset = handle.offsetInFile
        guard rawOffset < UInt64(UInt32.max), entries.count <= Int(UInt16.max) else {
            throw BackupError.zipTooLarge("archive")
        }
        let directoryOffset = UInt32(rawOffset)
        var directory = Data()
        for entry in entries {
            directory.appendLE(UInt32(0x0201_4B50))
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(0x0800))
            directory.appendLE(UInt16(0))
            directory.appendLE(entry.dosTime)
            directory.appendLE(entry.dosDate)
            directory.appendLE(entry.crc)
            directory.appendLE(entry.size)
            directory.appendLE(entry.size)
            directory.appendLE(UInt16(entry.name.count))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt32(0))
            directory.appendLE(entry.offset)
            directory.append(entry.name)
        }
        guard UInt64(directory.count) < UInt64(UInt32.max) else {
            throw BackupError.zipTooLarge("archive")
        }
        try handle.write(contentsOf: directory)
        let directorySize = UInt32(directory.count)

        var end = Data()
        end.appendLE(UInt32(0x0605_4B50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt16(entries.count))
        end.appendLE(directorySize)
        end.appendLE(directoryOffset)
        end.appendLE(UInt16(0))
        try handle.write(contentsOf: end)
        try handle.close()
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, components.year ?? 1980) - 1980
        let time = UInt16((components.hour ?? 0) << 11 | (components.minute ?? 0) << 5 | ((components.second ?? 0) / 2))
        let day = UInt16(year << 9 | (components.month ?? 1) << 5 | (components.day ?? 1))
        return (time, day)
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func update(_ initial: UInt32, with data: Data) -> UInt32 {
        var crc = initial
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        update(0xFFFF_FFFF, with: data) ^ 0xFFFF_FFFF
    }
}
