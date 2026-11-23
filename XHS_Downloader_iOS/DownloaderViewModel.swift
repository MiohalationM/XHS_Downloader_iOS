import Foundation
import Combine
import Photos
import UIKit
import UserNotifications
import AVFoundation
import ImageIO

private final class IdentifierBox: @unchecked Sendable {
    var value: String?
}

enum PhotoLibraryError: LocalizedError {
    case permissionDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return L10n.text("error.photo_permission")
        case .saveFailed: return L10n.text("error.photo_save")
        }
    }
}

protocol PhotoLibraryServing: Sendable {
    func saveMedia(at fileURL: URL, isVideo: Bool, originalFilename: String?, creationDate: Date?) async throws -> String
    func saveLivePhoto(photoURL: URL, pairedVideoURL: URL, originalFilename: String?, creationDate: Date?) async throws -> String
    func deleteAssets(localIdentifiers: [String]) async throws
}

actor PhotoLibraryService: PhotoLibraryServing {
    static let shared = PhotoLibraryService()
    static let albumName = "小红书下载器"
    private var albumCreation: Task<String, Error>?

    func requestWriteAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    func albumIdentifier() async throws -> String {
        if let id = UserDefaults.standard.string(forKey: "photos.albumIdentifier"),
           PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject != nil { return id }
        if let task = albumCreation { return try await task.value }
        let task = Task<String, Error> {
            let box = IdentifierBox()
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Self.albumName)
                box.value = request.placeholderForCreatedAssetCollection.localIdentifier
            }
            guard let id = box.value else { throw PhotoLibraryError.saveFailed }
            UserDefaults.standard.set(id, forKey: "photos.albumIdentifier")
            return id
        }
        albumCreation = task
        defer { albumCreation = nil }
        return try await task.value
    }

    func saveMedia(at fileURL: URL, isVideo: Bool, originalFilename: String? = nil,
                   creationDate: Date? = nil) async throws -> String {
        try await save(resources: [(isVideo ? .video : .photo, fileURL)], originalFilename: originalFilename,
                       creationDate: creationDate)
    }

    func saveLivePhoto(photoURL: URL, pairedVideoURL: URL, originalFilename: String? = nil,
                       creationDate: Date? = nil) async throws -> String {
        try await save(resources: [(.photo, photoURL), (.pairedVideo, pairedVideoURL)], originalFilename: originalFilename,
                       creationDate: creationDate)
    }

    private func save(resources: [(PHAssetResourceType, URL)], originalFilename: String?,
                      creationDate: Date? = nil) async throws -> String {
        guard await requestWriteAuthorization() else { throw PhotoLibraryError.permissionDenied }
        let albumID = try await albumIdentifier()
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else {
            throw PhotoLibraryError.saveFailed
        }
        var importResources: [(PHAssetResourceType, URL)] = []
        var temporaryPhotos: [URL] = []
        defer { for url in temporaryPhotos { try? FileManager.default.removeItem(at: url) } }
        for (type, url) in resources {
            let prepared = type == .photo ? try PhotoImportMetadata.prepare(url) : url
            if prepared != url { temporaryPhotos.append(prepared) }
            importResources.append((type, prepared))
        }
        let preparedResources = importResources
        let identifier = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            guard let albumRequest = PHAssetCollectionChangeRequest(for: album) else { return }
            let request = PHAssetCreationRequest.forAsset()
            for (type, url) in preparedResources {
                let options = PHAssetResourceCreationOptions()
                if let originalFilename {
                    options.originalFilename = type == .pairedVideo
                        ? (originalFilename as NSString).deletingPathExtension + "." + url.pathExtension : originalFilename
                }
                request.addResource(with: type, fileURL: url, options: options)
            }
            // A note's publish date is the meaningful date in the library; only
            // applied when the user asked for it.
            if let creationDate { request.creationDate = creationDate }
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            identifier.value = placeholder.localIdentifier
            albumRequest.addAssets([placeholder] as NSArray)
        }
        guard let value = identifier.value else { throw PhotoLibraryError.saveFailed }
        return value
    }

    func deleteAssets(localIdentifiers: [String]) async throws {
        guard await requestWriteAuthorization() else { throw PhotoLibraryError.permissionDenied }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        // Limited access may hide assets; don't silently erase their records.
        guard assets.count == Set(localIdentifiers).count else { throw PhotoLibraryError.permissionDenied }
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
    }
}

@MainActor
final class DownloadCoordinator: ObservableObject {
    @Published private(set) var tasks: [DownloadTaskRecord]
    /// The note library is the durable output. It is stored separately from the
    /// task list so removing history never removes note text, authors or links.
    @Published private(set) var notes: [StoredNote]
    /// Library preferences live beside notes so a backup can carry them and a
    /// history cleanup cannot reset them.
    @Published private(set) var collections: [NoteCollection]
    @Published private(set) var likedNotes: Set<String>
    @Published private(set) var bookmarkedNotes: Set<String>
    @Published private(set) var authorRemarks: [String: String]
    @Published var selectionState: SelectiveDownloadState?
    @Published var alertMessage: String?
    @Published private(set) var lastLogMessage: String = ""
    /// Set when the user taps a completion notification, so the task opens
    /// instead of dropping the user on an unfiltered list.
    @Published var focusedTask: TaskFocus?

    let settings: AppSettings

    private let store: any DownloadTaskStoring
    private let noteStore: NoteStore
    /// Used only when a task carries no snapshot (very old records) and by
    /// callers that need an ad-hoc resolver. Per-task work builds its own
    /// downloader from the snapshot so network settings apply immediately.
    private let downloader: XHSDownloader
    /// Preserved so per-task downloaders keep an injected session (tests and
    /// previews) instead of silently falling back to the network stack.
    private let injectedSession: URLSession?
    /// One pacer per coordinator: the request interval must hold between
    /// consecutive tasks, not restart for every task.
    private let pacer = RequestPacer()
    private let photoLibrary: any PhotoLibraryServing
    /// Kept so the settings screen can explain a failed migration instead of
    /// showing an empty library with no reason.
    @Published private(set) var loadError: String?
    @Published private(set) var isLoaded = false
    @Published private(set) var archiveRevision = 0
    private var startup: Task<Void, Never>?
    private var writes: Task<Bool, Never>?
    private var noteRevision = 0
    private var savedNoteRevision = 0
    private var admissions: Task<Bool, Never>?
    private var consumingInbox = false
    private var pendingAdmissions = Set<UUID>()
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var isWritingClipboard = false
    private var authorRefreshes = Set<UUID>()
    /// Note-keyed repairs are tracked separately from task-keyed ones.
    private var noteAuthorRefreshes = Set<String>()
    /// Progress ticks land in memory only; a single coalesced write follows.
    private var persistTask: Task<Void, Never>?
    private var backgroundSaveToken: UIBackgroundTaskIdentifier = .invalid

    init(
        settings: AppSettings,
        store: (any DownloadTaskStoring)? = nil,
        noteStore: NoteStore? = nil,
        downloader: XHSDownloader? = nil,
        photoLibrary: (any PhotoLibraryServing)? = nil,
        initialTasks: [DownloadTaskRecord]? = nil
    ) {
        self.settings = settings
        self.store = store ?? DownloadTaskStore()
        let resolvedNoteStore = noteStore ?? NoteStore(fileURL: store.map { $0.fileURL.deletingLastPathComponent().appendingPathComponent("notes-v1.json") })
        self.noteStore = resolvedNoteStore
        self.downloader = downloader ?? XHSDownloader()
        self.injectedSession = downloader?.exposedSession
        self.photoLibrary = photoLibrary ?? PhotoLibraryService.shared
        self.tasks = []
        self.notes = []
        let library = Self.loadLibraryPreferences(defaults: settings.defaults)
        self.collections = library.collections
        self.likedNotes = library.likes
        self.bookmarkedNotes = library.bookmarks
        self.authorRemarks = library.remarks
        startup = Task { [weak self] in
            guard let self else { return }
            if let initialTasks {
                do {
                    try await self.store.save(initialTasks)
                    try await self.noteStore.save([])
                } catch { self.alertMessage = error.localizedDescription }
            }
            self.tasks = await self.store.load().sorted { $0.createdAt > $1.createdAt }
            self.notes = await self.noteStore.load()
            let taskError = await self.store.loadError
            let noteError = await self.noteStore.loadError
            self.loadError = taskError ?? noteError
            self.migrateNotesFromTasksIfNeeded(loaded: self.notes)
            self.migrateLibraryIdentifiers()
            self.recoverInterruptedTasks()
            self.restoreArchiveGrants()
            await self.flushPersistence()
            self.isLoaded = true
            if let error = self.loadError { self.alertMessage = L10n.format("library.load.failed", error) }
        }
    }

    func waitUntilLoaded() async { await startup?.value }

    func flushForBackground() {
        guard backgroundSaveToken == .invalid else { return }
        backgroundSaveToken = UIApplication.shared.beginBackgroundTask(withName: "Save download state") { [weak self] in
            Task { @MainActor [weak self] in self?.endBackgroundSave() }
        }
        let token = backgroundSaveToken
        Task {
            await waitUntilLoaded()
            await flushPersistence()
            if backgroundSaveToken == token { endBackgroundSave() }
        }
    }

    private func endBackgroundSave() {
        guard backgroundSaveToken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundSaveToken)
        backgroundSaveToken = .invalid
    }

    /// The caller can await the exact durable boundary without blocking UIKit.
    func flushPersistence() async {
        persistTask?.cancel()
        if persistTask != nil { persistTask = nil; persist() }
        _ = await writes?.value
    }

    deinit {
        jobs.values.forEach { $0.cancel() }
    }

    // MARK: - Library preferences

    struct LibraryPreferences: Sendable {
        var collections: [NoteCollection] = []
        var likes: Set<String> = []
        var bookmarks: Set<String> = []
        var remarks: [String: String] = [:]
    }

    private static func loadLibraryPreferences(defaults: UserDefaults) -> LibraryPreferences {
        var result = LibraryPreferences()
        if let data = defaults.data(forKey: "library.collections"),
           let decoded = try? JSONDecoder().decode([NoteCollection].self, from: data) {
            result.collections = decoded
        }
        result.likes = Set(defaults.stringArray(forKey: "library.likedNotes") ?? [])
        result.bookmarks = Set(defaults.stringArray(forKey: "library.bookmarkedNotes") ?? [])
        if let data = defaults.data(forKey: "library.authorRemarks"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            result.remarks = decoded
        }
        return result
    }

    private func persistLibraryPreferences() {
        let defaults = settings.defaults
        defaults.set(try? JSONEncoder().encode(collections), forKey: "library.collections")
        defaults.set(likedNotes.sorted(), forKey: "library.likedNotes")
        defaults.set(bookmarkedNotes.sorted(), forKey: "library.bookmarkedNotes")
        defaults.set(try? JSONEncoder().encode(authorRemarks), forKey: "library.authorRemarks")
    }

    func toggleLike(noteID: String) {
        if !likedNotes.insert(noteID).inserted { likedNotes.remove(noteID) }
        persistLibraryPreferences()
        AppFeedback.play(likedNotes.contains(noteID) ? .activation : .deactivation)
    }

    func toggleBookmark(noteID: String) {
        if !bookmarkedNotes.insert(noteID).inserted { bookmarkedNotes.remove(noteID) }
        persistLibraryPreferences()
        AppFeedback.play(bookmarkedNotes.contains(noteID) ? .activation : .deactivation)
    }

    @discardableResult
    func createCollection(named name: String) -> NoteCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let collection = NoteCollection(name: trimmed)
        collections.append(collection)
        persistLibraryPreferences()
        AppFeedback.play(.success)
        return collection
    }

    func renameCollection(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = collections.firstIndex(where: { $0.id == id }),
              collections[index].name != trimmed else { return }
        collections[index].name = trimmed
        persistLibraryPreferences()
        AppFeedback.play(.confirmation)
    }

    func deleteCollection(_ id: UUID) {
        guard collections.contains(where: { $0.id == id }) else { return }
        collections.removeAll { $0.id == id }
        persistLibraryPreferences()
        AppFeedback.play(.success)
    }

    func setMembership(_ noteIDs: Set<String>, in collectionID: UUID, included: Bool) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        let previous = collections[index].noteIDs
        if included { collections[index].noteIDs.formUnion(noteIDs) }
        else { collections[index].noteIDs.subtract(noteIDs) }
        guard previous != collections[index].noteIDs else { return }
        persistLibraryPreferences()
        AppFeedback.play(.selection)
    }

    func collection(_ id: UUID) -> NoteCollection? {
        collections.first { $0.id == id }
    }

    /// Snapshot of portable preferences for a backup. Credentials and the folder
    /// capability are intentionally excluded.
    func exportSettingsSnapshot() -> BackupSettings {
        var policy = settings.policy
        policy.filesBookmark = nil
        policy.proxy = ""
        let naming = NamingPreferences.load()
        return BackupSettings(policy: policy,
                              livePhotoMode: settings.livePhotoMode,
                              selectiveDownload: settings.selectiveDownload,
                              notifications: settings.notifications,
                              debugNotifications: settings.debugNotifications,
                              haptics: settings.haptics,
                              appearance: settings.appearance,
                              keepScreenAwake: settings.keepScreenAwake,
                              clipboardSuggestions: settings.clipboardSuggestions,
                              namingEnabled: naming.enabled,
                              namingTemplate: naming.template,
                              namingTimeZone: naming.timeZone.identifier)
    }

    func setRemark(_ remark: String, for authorKey: String) {
        let trimmed = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (authorRemarks[authorKey] ?? "") != trimmed else { return }
        if trimmed.isEmpty { authorRemarks.removeValue(forKey: authorKey) }
        else { authorRemarks[authorKey] = trimmed }
        persistLibraryPreferences()
        AppFeedback.play(.confirmation)
    }

    func remark(for authorKey: String?) -> String? {
        guard let authorKey else { return nil }
        return authorRemarks[authorKey]
    }

    // MARK: - Note library

    /// Also fills notes missing after an interrupted write. Existing note text
    /// remains authoritative, and explicit note deletion removes its tasks too.
    private func migrateNotesFromTasksIfNeeded(loaded: [StoredNote]) {
        let existingIDs = Set(loaded.map(\.id))
        var merged: [String: StoredNote] = [:]
        for task in tasks {
            guard let note = storedNote(from: task), !existingIDs.contains(note.id) else { continue }
            if let existing = merged[note.id] {
                var combined = existing
                combined.mediaAssets = Self.mergeAssets(existing.mediaAssets, note.mediaAssets)
                combined.archiveGrants = ArchiveGrant.merging(existing.archiveGrants ?? [], fallback: note.archiveGrants ?? [])
                combined.archiveTextPaths = Array(Set(existing.archiveTextPaths + note.archiveTextPaths)).sorted()
                combined.createdAt = min(existing.createdAt, note.createdAt)
                combined.updatedAt = max(existing.updatedAt, note.updatedAt)
                merged[note.id] = combined
            } else {
                merged[note.id] = note
            }
        }
        guard !merged.isEmpty else { return }
        notes = (loaded + Array(merged.values)).sorted { $0.createdAt > $1.createdAt }
        // Backfill the join key, otherwise deleting a migrated note cannot find
        // its task and the next empty-library launch migrates it back.
        for index in tasks.indices where tasks[index].noteKey == nil {
            if let note = storedNote(from: tasks[index]) {
                tasks[index].noteKey = note.id
            }
        }
        persistNotes()
        migrateLibraryIdentifiers()
    }

    /// Older builds keyed likes, bookmarks and collections by task UUID; the note
    /// store keys them by note identity. Without remapping, a user's saved
    /// preferences would silently stop matching after the upgrade.
    private func migrateLibraryIdentifiers() {
        // One-shot, so a later intentional change is never rewritten.
        let marker = "library.identifierMigration.v2"
        guard !settings.defaults.bool(forKey: marker) else { return }
        settings.defaults.set(true, forKey: marker)
        var mapping: [String: String] = [:]
        for task in tasks {
            guard let key = task.noteKey ?? storedNote(from: task)?.id else { continue }
            mapping[task.id.uuidString] = key
        }
        guard !mapping.isEmpty else { return }

        likedNotes = Set(likedNotes.map { mapping[$0] ?? $0 })
        bookmarkedNotes = Set(bookmarkedNotes.map { mapping[$0] ?? $0 })
        for index in collections.indices {
            collections[index].noteIDs = Set(collections[index].noteIDs.map { mapping[$0] ?? $0 })
        }
        persistLibraryPreferences()
    }

    /// Merges by identifier but refreshes the fields a later pass can fill in:
    /// keeping the old record verbatim lost newly attached archive paths.
    private static func mergeAssets(_ lhs: [MediaAssetRecord], _ rhs: [MediaAssetRecord]) -> [MediaAssetRecord] {
        var result = lhs
        for asset in rhs {
            if let index = result.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) {
                var merged = result[index]
                if let paths = asset.filesPaths, !paths.isEmpty {
                    merged.filesPaths = Array(Set((merged.filesPaths ?? []) + paths)).sorted()
                }
                if let contentType = asset.contentType { merged.contentType = contentType }
                if let isLive = asset.isLive { merged.isLive = isLive }
                if let byteCount = asset.byteCount { merged.byteCount = byteCount }
                if let width = asset.pixelWidth { merged.pixelWidth = width }
                if let height = asset.pixelHeight { merged.pixelHeight = height }
                result[index] = merged
            } else {
                result.append(asset)
            }
        }
        return result
    }

    /// Projects a task into the durable note shape. Called after every save so
    /// the library never depends on the task row surviving.
    private func storedNote(from task: DownloadTaskRecord) -> StoredNote? {
        guard let resolved = task.resolvedNote else {
            // A text-only note still has enough to be kept.
            let body = task.noteText
            let title = task.title
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let note = StoredNote(id: task.noteKey ?? StoredNote.key(noteID: nil, url: task.normalizedURL),
                                  noteID: nil, canonicalURL: task.normalizedURL, title: title, body: body,
                                  metadata: NoteMetadata(), createdAt: task.createdAt,
                                  mediaAssets: task.mediaAssets, archiveTextPaths: task.archiveTextPaths ?? [],
                                  informationOnly: task.informationOnly ?? false)
            return addingArchiveGrant(to: note, task: task)
        }
        let note = StoredNote(id: task.noteKey ?? StoredNote.key(noteID: resolved.noteID, url: task.normalizedURL),
                              noteID: resolved.noteID,
                              canonicalURL: resolved.canonicalURL.absoluteString,
                              title: task.title.isEmpty ? resolved.title : task.title,
                              body: task.noteText.isEmpty ? resolved.body : task.noteText,
                              metadata: resolved.metadata,
                              createdAt: task.createdAt,
                              mediaAssets: task.mediaAssets,
                              archiveTextPaths: task.archiveTextPaths ?? [],
                              informationOnly: task.informationOnly ?? false)
        return addingArchiveGrant(to: note, task: task)
    }

    private func addingArchiveGrant(to note: StoredNote, task: DownloadTaskRecord) -> StoredNote? {
        guard note.isMeaningful else { return nil }
        var note = note
        if let grant = ArchiveGrant(bookmark: task.policy?.filesBookmark) { note.archiveGrants = [grant] }
        return note
    }

    private func restoreArchiveGrants() {
        let available = ArchiveGrant.merging([ArchiveGrant(bookmark: settings.policy.filesBookmark)].compactMap { $0 },
            fallback: tasks.compactMap { ArchiveGrant(bookmark: $0.policy?.filesBookmark) })
        var changed = false
        for index in notes.indices {
            let paths = notes[index].archivePaths
            let grants = available.filter { grant in paths.contains { grant.relativePath(for: $0) != nil } }
            let merged = ArchiveGrant.merging(notes[index].archiveGrants ?? [], fallback: grants)
            if merged != notes[index].archiveGrants && !merged.isEmpty {
                notes[index].archiveGrants = merged
                changed = true
            }
        }
        ArchiveAccess.shared.register(available + notes.flatMap { $0.archiveGrants ?? [] })
        if changed { persistNotes() }
    }

    /// Upserts the task's note. Media, captions and metadata are merged rather
    /// than replaced, so a partial retry cannot drop an earlier success.
    private func syncNote(for taskID: UUID, refreshContent: Bool = true) {
        guard let task = task(for: taskID), let note = storedNote(from: task) else { return }
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            var updated = notes[index]
            if refreshContent {
                if !note.title.isEmpty { updated.title = note.title }
                if !note.body.isEmpty { updated.body = note.body }
                updated.metadata = Self.mergeMetadata(updated.metadata, note.metadata)
                updated.canonicalURL = note.canonicalURL
            }
            updated.archiveGrants = ArchiveGrant.merging(updated.archiveGrants ?? [], fallback: note.archiveGrants ?? [])
            updated.mediaAssets = Self.mergeAssets(notes[index].mediaAssets, note.mediaAssets)
            updated.archiveTextPaths = Array(Set(notes[index].archiveTextPaths + note.archiveTextPaths)).sorted()
            updated.updatedAt = Date()
            notes[index] = updated
        } else {
            notes.insert(note, at: 0)
        }
        persistNotes()
    }

    @discardableResult
    private func persistNotes() -> Task<Bool, Never> {
        ArchiveAccess.shared.register(notes.flatMap { $0.archiveGrants ?? [] })
        return persist(includeNotes: true)
    }

    /// After the user re-authorizes a folder, tasks still holding the old (now
    /// invalid) bookmark are repointed so their retry can actually write.
    /// Successful archives keep their recorded paths.
    func reauthorizeArchiveDirectory(_ bookmark: Data) {
        settings.policy.filesBookmark = bookmark
        if let grant = ArchiveGrant(bookmark: bookmark) { ArchiveAccess.shared.register([grant]) }
        for index in tasks.indices {
            guard tasks[index].policy != nil, tasks[index].status != .completed else { continue }
            guard tasks[index].policy?.filesBookmark != bookmark else { continue }
            tasks[index].policy?.filesBookmark = bookmark
        }
        persist()
    }

    func note(forKey key: String) -> StoredNote? {
        notes.first { $0.id == key }
    }

    func reauthorizeNoteArchive(_ id: String, directory: URL) async throws {
        guard let note = note(forKey: id) else { return }
        let paths = note.archivePaths
        let grants = try await ArchiveMediaLoader.shared.reauthorize(grants: note.archiveGrants ?? [],
                                                                    paths: paths, directory: directory)
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].archiveGrants = grants
        for index in notes.indices {
            notes[index].archiveGrants = notes[index].archiveGrants?.map { old in
                grants.first(where: { $0.rootPath == old.rootPath }) ?? old
            }
        }
        guard await persistNotes().value else { throw CocoaError(.fileWriteUnknown) }
        await ArchiveMediaLoader.shared.clearThumbnails()
        let affected = notes.filter { note in
            note.archiveGrants?.contains { candidate in grants.contains { $0.rootPath == candidate.rootPath } } == true
        }.flatMap(\.mediaAssets).map { "file:" + $0.archivePaths.joined(separator: "\n") }
        MediaPreviewImages.shared.remove(identifiers: affected)
        archiveRevision += 1
        AppFeedback.play(.success)
    }

    /// Deleting a note is explicit and separate from deleting its task history.
    func deleteNote(_ id: String, deletePhotos: Bool) async {
        do { try await deleteNotes([id], deleteMedia: deletePhotos) }
        catch { if !isPhotosCancellation(error) { alertMessage = error.localizedDescription } }
    }

    func deleteNotes(_ ids: Set<String>, deleteMedia: Bool, additionalMedia: Set<String> = []) async throws {
        let selected = notes.filter { ids.contains($0.id) }
        guard !selected.isEmpty || (deleteMedia && !additionalMedia.isEmpty) else { return }
        let related = Set(tasks.filter { task in
            ids.contains(task.noteKey ?? storedNote(from: task)?.id ?? "")
        }.map(\.id))
        for id in related { stop(taskID: id, feedback: false) }
        for id in related { await jobs[id]?.value }
        let current = notes.filter { ids.contains($0.id) }
        if deleteMedia {
            var media = Set(current.flatMap(\.mediaAssets).map(\.localIdentifier)).union(additionalMedia)
            for note in current {
                for asset in note.mediaAssets where asset.localIdentifier.hasPrefix("file:") == false {
                    if let paths = asset.filesPaths, !paths.isEmpty { media.insert("file:" + paths.joined(separator: "\n")) }
                }
                for path in note.archiveTextPaths { media.insert("file:" + path) }
            }
            do {
                try await MediaDeletionService.shared.delete(media, photos: photoLibrary)
                removeMediaReferences(media)
            }
            catch let failure as MediaDeletionFailure {
                removeMediaReferences(failure.deleted)
                await flushPersistence()
                throw failure
            }
        }
        tasks.removeAll { related.contains($0.id) }
        notes.removeAll { ids.contains($0.id) }
        likedNotes.subtract(ids)
        bookmarkedNotes.subtract(ids)
        for index in collections.indices { collections[index].noteIDs.subtract(ids) }
        persistLibraryPreferences()
        guard await persistNotes().value else { throw CocoaError(.fileWriteUnknown) }
        AppFeedback.play(.success)
    }

    var waitingCount: Int { tasks.filter { $0.status == .waitingForUser }.count }
    var failedCount: Int { tasks.filter { $0.status == .failed || $0.status == .partial }.count }

    /// A duplicate share must land on the existing task instead of silently
    /// doing nothing: the UI focuses the running task so the user sees why.
    @discardableResult
    func focusExistingTask(for link: String) -> Bool {
        guard let task = tasks.first(where: {
            matches($0, link: link) && [.queued, .downloading, .waitingForUser, .paused].contains($0.status)
        }) else { return false }
        focusedTask = TaskFocus(id: task.id)
        return true
    }

    private func hasExistingTaskOrNote(for link: String) -> Bool {
        if tasks.contains(where: {
            ![.failed, .cancelled].contains($0.status) && matches($0, link: link)
        }) { return true }
        let candidateNoteID = URL(string: link).flatMap(XHSURLDetector.noteID(from:))
        return notes.contains { note in
            XHSURLDetector.linksMatch(note.canonicalURL, link)
                || (candidateNoteID != nil && note.noteID == candidateNoteID)
        }
    }

    private func matches(_ task: DownloadTaskRecord, link: String) -> Bool {
        if XHSURLDetector.linksMatch(task.normalizedURL, link) { return true }
        guard let resolved = task.resolvedNote else { return false }
        if XHSURLDetector.linksMatch(resolved.canonicalURL.absoluteString, link) { return true }
        if let candidateID = URL(string: link).flatMap(XHSURLDetector.noteID(from:)) {
            return resolved.noteID == candidateID
        }
        return false
    }

    /// Repair a note that is missing its author, keyed by note identity. The feed
    /// no longer knows task UUIDs, so this is the entry point it uses.
    func restoreMissingAuthor(noteKey: String) async {
        guard let note = notes.first(where: { $0.id == noteKey }),
              note.metadata.userName?.isEmpty != false,
              let url = URL(string: note.canonicalURL),
              !noteAuthorRefreshes.contains(noteKey) else { return }
        noteAuthorRefreshes.insert(noteKey)
        let active = downloader
        let naming = XHSDownloader.NamingContext(
            preferences: NamingPreferences(enabled: false, template: NamingFormatter.defaultTemplate,
                                           timeZone: .current),
            downloadInstant: note.createdAt)
        do {
            let refreshed = try await active.resolveNote(from: url.absoluteString, naming: naming)
            guard refreshed.metadata.userName?.isEmpty == false else { return }
            updateNote(id: noteKey) { stored in
                stored.metadata = refreshed.metadata
                stored.title = stored.title.isEmpty ? refreshed.title : stored.title
            }
            // Keep any task that produced this note in step so a later sync does
            // not write the old author back.
            for task in tasks where task.noteKey == noteKey {
                update(task.id) { record in
                    if let current = record.resolvedNote {
                        record.resolvedNote = ResolvedNote(noteID: current.noteID, canonicalURL: current.canonicalURL,
                            title: current.title, body: current.body, metadata: refreshed.metadata, media: current.media)
                    }
                }
            }
            if let avatarURL = refreshed.metadata.avatarURL { _ = await AuthorAvatarStore.shared.imageData(for: avatarURL) }
        } catch {
            // Keep the offline record. A future app launch can retry.
        }
    }

    private func updateNote(id: String, mutation: (inout StoredNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        mutation(&notes[index])
        notes[index].updatedAt = Date()
        persistNotes()
    }

    /// Repair records created before mobile `nickName` was supported, without
    /// downloading media again or substituting a recommended/signed-in author.
    func restoreMissingAuthor(_ id: UUID) async {
        guard let old = task(for: id)?.resolvedNote, old.metadata.userName?.isEmpty != false,
              old.noteID.count == 24, old.noteID.allSatisfy({ $0.isHexDigit }),
              authorRefreshes.insert(id).inserted else { return }
        do {
            let source = task(for: id)
            let active = source.map { downloader(for: $0) } ?? downloader
            let naming = source.map { namingContext(for: $0, policy: $0.policy ?? settings.policy) }
            let refreshed = try await active.resolveNote(from: old.canonicalURL.absoluteString, naming: naming)
            guard refreshed.noteID == old.noteID, refreshed.metadata.userName?.isEmpty == false else { return }
            update(id) { record in
                guard let current = record.resolvedNote, current.noteID == old.noteID else { return }
                record.resolvedNote = ResolvedNote(noteID: current.noteID, canonicalURL: current.canonicalURL,
                    title: current.title, body: current.body, metadata: refreshed.metadata, media: current.media)
            }
            if let avatarURL = refreshed.metadata.avatarURL { _ = await AuthorAvatarStore.shared.imageData(for: avatarURL) }
        } catch {
            // Keep the offline record. A future app launch can retry.
        }
    }

    func filteredTasks(for filter: TaskFilter) -> [DownloadTaskRecord] {
        switch filter {
        case .all: return tasks.sorted { lhs, rhs in
            let active: Set<TaskStatus> = [.downloading, .queued, .waitingForUser]
            if active.contains(lhs.status) != active.contains(rhs.status) { return active.contains(lhs.status) }
            return lhs.createdAt > rhs.createdAt
        }
        case .waiting: return tasks.filter { $0.status == .waitingForUser }
        case .failed: return tasks.filter { $0.status == .failed || $0.status == .partial }
        }
    }

    @discardableResult
    func enqueue(_ input: String) -> Task<Bool, Never> {
        enqueue(input, behavior: .useSettings)
    }

    /// Entry actions from the manual sheet and the built-in browser all funnel
    /// into the same request pipeline, so behaviour is decided exactly once.
    @discardableResult
    func enqueue(_ input: String, behavior: ImportRequest.Behavior) -> Task<Bool, Never> {
        submit { await self.accept(ImportRequest(text: input, source: .manual, behavior: behavior)) }
    }

    @discardableResult
    func enqueueClipboard(_ input: String) -> Task<Bool, Never> {
        submit { await self.accept(ImportRequest(text: input, source: .clipboard, behavior: .useSettings)) }
    }

    private func submit(_ operation: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        let previous = admissions
        let task = Task { @MainActor in
            _ = await previous?.value
            await self.waitUntilLoaded()
            return await operation()
        }
        admissions = task
        return task
    }

    /// A note already parsed from the live page. It is turned into a real task
    /// with the page's own structured data, so no second request is made and the
    /// original access parameters stay with the record.
    @discardableResult
    func enqueue(_ payload: BrowserNotePayload, behavior: ImportRequest.Behavior) -> Task<Bool, Never> {
        submit { await self.accept(payload, behavior: behavior) }
    }

    private func accept(_ payload: BrowserNotePayload, behavior: ImportRequest.Behavior) async -> Bool {
        let link = payload.pageURL.absoluteString
        let naming = XHSDownloader.NamingContext(
            preferences: NamingPreferences(enabled: settings.policy.namingEnabled,
                                           template: settings.policy.namingTemplate,
                                           timeZone: TimeZone(identifier: settings.policy.namingTimezone) ?? .current),
            downloadInstant: Date())
        guard let note = try? downloader.resolveNote(data: payload.note, noteID: payload.noteID,
                                                     canonicalURL: payload.pageURL,
                                                     comments: payload.comments,
                                                     naming: naming) else {
            alertMessage = L10n.text("error.parsing")
            return false
        }
        if focusExistingTask(for: link) { return true }
        var task = DownloadTaskRecord(sourceText: payload.pageURL.absoluteString, normalizedURL: link)
        applyEntryBehavior(behavior, to: &task)
        task.resolvedNote = note
        task.title = note.title
        task.noteText = note.body
        task.noteType = inferNoteType(note.media)
        task.mediaCount = note.media.count
        task.noteKey = StoredNote.key(noteID: note.noteID, url: link)
        tasks.insert(task, at: 0)
        pendingAdmissions.insert(task.id)
        defer { pendingAdmissions.remove(task.id); schedule() }
        guard await persist().value else {
            tasks.removeAll { $0.id == task.id }
            _ = await persist().value
            return false
        }
        syncNote(for: task.id)
        AppFeedback.play(.confirmation)
        schedule()
        return true
    }

    @discardableResult
    private func accept(_ request: ImportRequest) async -> Bool {
        let links = XHSURLDetector.extract(from: request.text)
        guard !links.isEmpty else {
            alertMessage = L10n.text("error.no_link")
            return true
        }
        var added = false
        for link in links {
            // Request IDs make durable share replay idempotent. A manual repeat
            // after completion remains a deliberate new download, while passive
            // clipboard detection skips links already queued, active, or saved.
            if tasks.contains(where: { $0.importRequestID == request.id && $0.normalizedURL == link }) { continue }
            if request.source == .clipboard {
                if hasExistingTaskOrNote(for: link) { continue }
            } else if focusExistingTask(for: link) {
                continue
            }
            var task = DownloadTaskRecord(sourceText: request.text, normalizedURL: link)
            task.importRequestID = request.id
            applyEntryBehavior(request.behavior, to: &task)
            tasks.insert(task, at: 0)
            pendingAdmissions.insert(task.id)
            let saved = await persist().value
            pendingAdmissions.remove(task.id)
            guard saved else {
                tasks.removeAll { $0.id == task.id }
                _ = await persist().value
                return false
            }
            added = true
            schedule()
        }
        if added { AppFeedback.play(.confirmation) }
        return true
    }

    /// The entry action wins over the global default: "download now" must not be
    /// turned into a selection prompt by a setting. The policy, download instant
    /// and note key are snapshotted here, at submission time.
    private func applyEntryBehavior(_ behavior: ImportRequest.Behavior, to task: inout DownloadTaskRecord) {
        switch behavior {
        case .select: task.selectionRequired = true
        case .direct, .informationOnly: task.selectionRequired = false
        case .useSettings: task.selectionRequired = settings.selectiveDownload
        }
        task.informationOnly = behavior == .informationOnly
        task.livePhotoEnabled = settings.createLivePhotos
        task.livePhotoMode = settings.livePhotoMode
        task.policy = settings.policy
        task.downloadInstant = Date()
        task.noteKey = StoredNote.key(noteID: nil, url: task.normalizedURL)
    }

    func consumeSharedInbox() {
        guard let inbox = try? ImportInbox.shared() else { return }
        Task { await consume(inbox: inbox) }
    }

    func consume(inbox: ImportInbox) async {
        guard !consumingInbox else { return }
        consumingInbox = true
        defer { consumingInbox = false }
        do {
            try inbox.migrateLegacyDefaults()
            for request in try inbox.pending() {
                guard await submit({ await self.accept(request) }).value else { break }
                try inbox.acknowledge(request.id)
            }
        } catch { alertMessage = error.localizedDescription }
    }

    func checkClipboard() {
        guard settings.clipboardSuggestions, !isWritingClipboard,
              !ProcessInfo.processInfo.arguments.contains("-disable-automatic-clipboard"),
              // A background launch must not read the pasteboard: iOS would show
              // the paste banner while the user never asked for a download.
              UIApplication.shared.applicationState == .active else { return }
        let pasteboard = UIPasteboard.general
        let key = "clipboard.lastHandledChange"
        let linksKey = "clipboard.lastHandledLinks"
        let change = pasteboard.changeCount
        guard UserDefaults.standard.object(forKey: key) as? Int != change else { return }
        // Record the attempt before reading so a denied paste doesn't repeatedly
        // request access for an unchanged clipboard.
        UserDefaults.standard.set(change, forKey: key)
        guard pasteboard.hasStrings || pasteboard.hasURLs,
              let text = pasteboard.string else { return }
        let links = XHSURLDetector.extract(from: text)
        guard !links.isEmpty else {
            UserDefaults.standard.removeObject(forKey: linksKey)
            return
        }
        // Universal Clipboard, app switches, or device reboot can bump or reset
        // changeCount while the pasteboard still holds the exact same handled links.
        guard UserDefaults.standard.stringArray(forKey: linksKey) != links else { return }
        UserDefaults.standard.set(links, forKey: linksKey)
        // The clipboard has no action picker, so it follows the user's default:
        // direct download unless "choose content" is enabled in settings.
        _ = submit { await self.accept(ImportRequest(text: text, source: .clipboard, behavior: .useSettings)) }
    }

    func copyToClipboard(_ text: String) {
        isWritingClipboard = true
        defer { isWritingClipboard = false }
        UIPasteboard.general.string = text
        UserDefaults.standard.set(UIPasteboard.general.changeCount, forKey: "clipboard.lastHandledChange")
        let links = XHSURLDetector.extract(from: text)
        if links.isEmpty {
            UserDefaults.standard.removeObject(forKey: "clipboard.lastHandledLinks")
        } else {
            UserDefaults.standard.set(links, forKey: "clipboard.lastHandledLinks")
        }
        AppFeedback.play(.copy)
    }

    @discardableResult
    func copySelectedNoteLinks(in notes: [LibraryNote], mediaIDs: Set<String>) -> Int {
        let links = NoteLibrary.selectedLinks(in: notes, mediaIDs: mediaIDs)
        guard !links.isEmpty else { return 0 }
        copyToClipboard(links.joined(separator: "\n"))
        return links.count
    }

    func stop(taskID: UUID, feedback: Bool = true) {
        guard let task = task(for: taskID),
              [.queued, .downloading, .waitingForUser].contains(task.status) else { return }
        jobs[taskID]?.cancel()
        update(taskID) { task in task.status = .paused; task.errorMessage = nil }
        if selectionState?.taskID == taskID { selectionState = nil }
        schedule()
        if feedback { AppFeedback.play(.deactivation) }
    }

    func retry(taskID: UUID, feedback: Bool = true) {
        guard jobs[taskID] == nil, let task = task(for: taskID),
              [.paused, .cancelled, .failed, .partial].contains(task.status) else { return }
        update(taskID) { task in
            if task.status == .failed || task.status == .partial
                || (task.mediaCount > 0 && task.resolvedNote?.media.isEmpty == true) { task.resolvedNote = nil }
            task.status = .queued
            task.failedCount = 0
            task.errorMessage = nil
        }
        schedule()
        if feedback { AppFeedback.play(.confirmation) }
    }

    func deleteTask(taskID: UUID, deletePhotos: Bool) async {
        stop(taskID: taskID, feedback: false)
        await jobs[taskID]?.value
        guard let task = task(for: taskID) else { return }
        if deletePhotos {
            let identifiers = task.mediaAssets.map(\.localIdentifier).filter { !$0.hasPrefix("file:") }
            if !identifiers.isEmpty {
                do { try await photoLibrary.deleteAssets(localIdentifiers: identifiers) }
                catch {
                    if !isPhotosCancellation(error) { alertMessage = error.localizedDescription }
                    return
                }
                removeMediaReferences(Set(identifiers))
            }
        }
        // The note survives deleting a task: only the work record is removed.
        syncNote(for: taskID, refreshContent: false)
        for path in (task.stagedFiles ?? [:]).values {
            try? FileManager.default.removeItem(atPath: path)
        }
        tasks.removeAll { $0.id == taskID }
        if await persistNotes().value { AppFeedback.play(.success) }
    }

    func clearHistory() {
        let ids = Set(tasks.map(\.id))
        guard !ids.isEmpty else { return }
        for id in ids { stop(taskID: id, feedback: false) }
        for id in ids { syncNote(for: id, refreshContent: false) }
        Task {
            for id in ids { await jobs[id]?.value }
            for task in tasks where ids.contains(task.id) {
                for path in task.stagedFiles?.values ?? Dictionary<String, String>().values {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            tasks.removeAll { ids.contains($0.id) }
            let saved = persist()
            if await saved.value { AppFeedback.play(.success) }
        }
    }

    /// Called after Photos deletion. Both task rows and stored notes must forget
    /// the asset, otherwise the feed would render a dead identifier.
    func removeMediaReferences(_ identifiers: Set<String>) {
        func remaining(_ assets: [MediaAssetRecord]) -> [MediaAssetRecord] {
            assets.compactMap { asset in
                var asset = asset
                let paths = asset.filesPaths ?? []
                let fileID = "file:" + paths.joined(separator: "\n")
                if identifiers.contains(asset.localIdentifier) {
                    guard !asset.localIdentifier.hasPrefix("file:"), !paths.isEmpty,
                          !identifiers.contains(fileID) else { return nil }
                    // The Photos copy is gone, but its archived original survives.
                    asset.localIdentifier = fileID
                } else if !paths.isEmpty, identifiers.contains(fileID) { asset.filesPaths = nil }
                return asset
            }
        }
        for index in tasks.indices { tasks[index].mediaAssets = remaining(tasks[index].mediaAssets) }
        for index in notes.indices {
            notes[index].mediaAssets = remaining(notes[index].mediaAssets)
            notes[index].archiveTextPaths.removeAll { identifiers.contains("file:" + $0) }
        }
        persistNotes()
    }

    func updateSelection(id: UUID, selected: Bool) {
        guard var state = selectionState, let index = state.items.firstIndex(where: { $0.id == id }),
              state.items[index].isSelected != selected else { return }
        state.items[index].isSelected = selected
        selectionState = state
        update(state.taskID) { $0.draftSelectionIDs = state.items.filter(\.isSelected).map { $0.remote.stableID } }
        AppFeedback.play(.selection)
    }

    func selectAll(_ selected: Bool) {
        guard var state = selectionState, state.items.contains(where: { $0.isSelected != selected }) else { return }
        for index in state.items.indices { state.items[index].isSelected = selected }
        selectionState = state
        update(state.taskID) { $0.draftSelectionIDs = state.items.filter(\.isSelected).map { $0.remote.stableID } }
        AppFeedback.play(.selection)
    }

    func showSelection(taskID: UUID) {
        guard let task = task(for: taskID), let media = task.resolvedNote?.media else { return }
        selectionState = SelectiveDownloadState(taskID: taskID, phase: .ready, items: media.map {
            SelectiveMediaItem(id: $0.id, remote: $0, cachedURL: $0.previewURL ?? $0.url, isSelected: task.draftSelectionIDs?.contains($0.stableID) ?? true)
        })
    }

    func cancelSelection() {
        guard let state = selectionState else { return }
        selectionState = nil
        update(state.taskID) { $0.status = .cancelled }
        schedule()
        AppFeedback.play(.deactivation)
    }

    func saveSelection() {
        guard let state = selectionState, state.phase == .ready else { return }
        let ids = state.items.filter(\.isSelected).map { $0.remote.stableID }
        guard !ids.isEmpty else { alertMessage = L10n.text("error.selection_empty"); return }
        update(state.taskID) { task in
            task.selectedMediaIDs = ids
            // Freeze the chosen slot set: a later re-parse must not widen it.
            task.submittedMediaIDs = ids
            task.status = .queued
        }
        selectionState = nil
        schedule()
        AppFeedback.play(.confirmation)
    }

    // MARK: - Batch actions

    /// Batch operations act on a whole group at once. They reuse the single-task
    /// paths so pause/cancel/retry keep their distinct meanings.
    func pauseAll() {
        let items = tasks.filter { $0.status == .downloading || $0.status == .queued }
        for task in items { stop(taskID: task.id, feedback: false) }
        if !items.isEmpty { AppFeedback.play(.deactivation) }
    }

    func resumeAll() {
        let items = tasks.filter { [.paused, .cancelled, .failed, .partial].contains($0.status) && jobs[$0.id] == nil }
        for task in items { retry(taskID: task.id, feedback: false) }
        if !items.isEmpty { AppFeedback.play(.confirmation) }
    }

    func retryAllFailed() {
        let items = tasks.filter { ($0.status == .failed || $0.status == .partial) && jobs[$0.id] == nil }
        for task in items { retry(taskID: task.id, feedback: false) }
        if !items.isEmpty { AppFeedback.play(.confirmation) }
    }

    /// Removing history removes only the work records. Notes, their media and
    /// their archive paths live in the note store and stay in the library.
    func removeFinished() {
        let finished = tasks.filter { $0.status == .completed || $0.status == .cancelled }
        guard !finished.isEmpty else { return }
        for task in finished { syncNote(for: task.id, refreshContent: false) }
        let ids = Set(finished.map(\.id))
        for task in finished {
            for path in task.stagedFiles?.values ?? Dictionary<String, String>().values {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        tasks.removeAll { ids.contains($0.id) }
        let saved = persist()
        Task { if await saved.value { AppFeedback.play(.success) } }
    }

    /// Retrying only the failed slots keeps already saved media untouched: the
    /// completed identity set survives and every failed slot returns to queued.
    /// The resolved note is dropped so expired media addresses are refreshed;
    /// successful slots are matched by their stable identity, not by URL.
    func retryFailedResources(taskID: UUID) {
        guard jobs[taskID] == nil, let task = task(for: taskID) else { return }
        let failedKeys = (task.resourceResults ?? [:]).filter { $0.value.state == .failed }.map(\.key)
        guard !failedKeys.isEmpty else { retry(taskID: taskID); return }
        update(taskID) { record in
            var results = record.resourceResults ?? [:]
            for key in failedKeys {
                var entry = results[key] ?? ResourceResult()
                entry.state = .queued
                entry.error = nil
                entry.received = 0
                entry.expected = 0
                entry.speed = 0
                // Keep the Photos half when only the Files half failed: the
                // destination states decide what the next pass must do.
                if entry.photos?.state == .failed { entry.photos = DestinationResult() }
                if entry.files?.state == .failed { entry.files = DestinationResult() }
                results[key] = entry
            }
            record.resourceResults = results
            // Expired URLs are the usual cause of a failed slot, so the note is
            // re-resolved. Successful assets and their keys are preserved.
            record.resolvedNote = nil
            record.status = .queued
            record.failedCount = 0
            record.errorMessage = nil
        }
        schedule()
        AppFeedback.play(.confirmation)
    }

    // MARK: - Backup

    /// Restore shares the ordered writer with downloads. Each store publishes
    /// only after its save succeeds; preferences apply after both stores. If the
    /// second store fails, the caller gets an explicit, retryable partial result.
    func applyBackup(_ document: BackupDocument) async throws -> BackupImportSummary {
        await waitUntilLoaded()
        flushPendingPersist()
        let previous = writes
        let restore = Task { @MainActor in
            _ = await previous?.value
            return try await self.restoreBackup(document)
        }
        writes = Task { (try? await restore.value) != nil }
        let summary = try await restore.value
        // A download or author repair may have advanced while either save was
        // suspended. Flush the reconciled state before declaring completion.
        guard await persist().value else {
            throw BackupError.partialImport(alertMessage ?? L10n.text("backup.error.finalize"))
        }
        applyLibraryBackupPreferences(document)
        await BackupService.shared.restoreAvatars(document.avatars)
        return summary
    }

    private func restoreBackup(_ document: BackupDocument) async throws -> BackupImportSummary {
        guard document.version <= BackupDocument.currentVersion else {
            throw BackupError.unsupportedVersion(document.version)
        }
        var summary = BackupImportSummary()
        let originalTasks = tasks
        let originalNotes = notes
        var restoredTasks = tasks
        var restoredNotes = notes
        let activeNoteIDs = Set(tasks.filter {
            jobs[$0.id] != nil || pendingAdmissions.contains($0.id) || [.queued, .downloading, .waitingForUser].contains($0.status)
        }.compactMap { $0.noteKey ?? storedNote(from: $0)?.id }.map(BackupEntry.portableNoteKey))

        for value in document.notes {
            guard !activeNoteIDs.contains(BackupEntry.portableNoteKey(value.id)) else { summary.skipped += 1; continue }
            // A portable file cannot grant access to local paths. Existing local
            // grants and archive paths survive the merge independently.
            let incoming = BackupEntry.redactedNote(value)
            if let index = restoredNotes.firstIndex(where: { BackupEntry.portableNoteKey($0.id) == incoming.id }) {
                var merged = restoredNotes[index]
                if !incoming.title.isEmpty { merged.title = incoming.title }
                if !incoming.body.isEmpty { merged.body = incoming.body }
                merged.metadata = Self.mergeMetadata(merged.metadata, incoming.metadata)
                merged.mediaAssets = Self.mergeAssets(merged.mediaAssets, incoming.mediaAssets.filter { $0.localIdentifier != "file:" })
                merged.updatedAt = Date()
                restoredNotes[index] = merged
                summary.merged += 1
            } else {
                restoredNotes.insert(incoming, at: 0)
                summary.added += 1
            }
        }

        for value in document.tasks {
            let entry = BackupEntry.make(from: value.record)
            let identity = BackupEntry.identity(of: entry.record)
            if let index = restoredTasks.firstIndex(where: { BackupEntry.identity(of: $0) == identity }) {
                let local = restoredTasks[index]
                if jobs[local.id] != nil || pendingAdmissions.contains(local.id) || [.downloading, .queued, .waitingForUser].contains(local.status) {
                    summary.skipped += 1
                    continue
                }
                // Keep local progress, originals, destination grants and retry
                // state; the backup refreshes the durable text and metadata.
                var merged = local
                if !entry.record.title.isEmpty { merged.title = entry.record.title }
                if !entry.record.noteText.isEmpty { merged.noteText = entry.record.noteText }
                if let incoming = entry.record.resolvedNote {
                    let current = merged.resolvedNote ?? incoming
                    merged.resolvedNote = ResolvedNote(noteID: current.noteID, canonicalURL: current.canonicalURL,
                        title: merged.title, body: merged.noteText,
                        metadata: Self.mergeMetadata(current.metadata, incoming.metadata), media: current.media)
                }
                merged.updatedAt = Date()
                merged.historyHidden = nil
                merged.libraryHidden = nil
                restoredTasks[index] = merged
                summary.merged += 1
            } else {
                var record = entry.record
                record.id = UUID()
                record.updatedAt = Date()
                record.historyHidden = nil
                record.libraryHidden = nil
                restoredTasks.insert(record, at: 0)
                summary.added += 1
            }
        }

        let importedNoteIDs = Set(document.notes.map { BackupEntry.portableNoteKey($0.id) })
        let importedTaskIDs = Set(document.tasks.map { BackupEntry.identity(of: $0.record) })
        for index in restoredTasks.indices {
            let task = restoredTasks[index]
            guard let projected = storedNote(from: task), !activeNoteIDs.contains(BackupEntry.portableNoteKey(projected.id)) else { continue }
            if importedNoteIDs.contains(BackupEntry.portableNoteKey(projected.id)), let note = restoredNotes.first(where: {
                BackupEntry.portableNoteKey($0.id) == BackupEntry.portableNoteKey(projected.id)
            }) {
                // Later history cleanup must not project an older task body back
                // over a note that was just restored.
                restoredTasks[index].title = note.title
                restoredTasks[index].noteText = note.body
                if let resolved = task.resolvedNote {
                    restoredTasks[index].resolvedNote = ResolvedNote(noteID: resolved.noteID, canonicalURL: resolved.canonicalURL,
                        title: note.title, body: note.body, metadata: note.metadata, media: resolved.media)
                }
            } else if importedTaskIDs.contains(BackupEntry.identity(of: task)) {
                // Version 1 backups carry their note inside the task record.
                if let noteIndex = restoredNotes.firstIndex(where: { $0.id == projected.id }) {
                    var note = restoredNotes[noteIndex]
                    if !projected.title.isEmpty { note.title = projected.title }
                    if !projected.body.isEmpty { note.body = projected.body }
                    note.metadata = Self.mergeMetadata(note.metadata, projected.metadata)
                    note.mediaAssets = Self.mergeAssets(note.mediaAssets, projected.mediaAssets)
                    restoredNotes[noteIndex] = note
                } else { restoredNotes.insert(projected, at: 0) }
            }
        }

        let savedNotes = restoredNotes != originalNotes
        if savedNotes {
            try await noteStore.save(restoredNotes)
            notes = Self.reconcileRestore(original: originalNotes, restored: restoredNotes, current: notes)
            noteRevision += 1
            if notes == restoredNotes { savedNoteRevision = noteRevision }
            ArchiveAccess.shared.register(notes.flatMap { $0.archiveGrants ?? [] })
        }
        do {
            if restoredTasks != originalTasks { try await store.save(restoredTasks) }
        } catch {
            if savedNotes { throw BackupError.partialImport(error.localizedDescription) }
            throw error
        }
        tasks = Self.reconcileRestore(original: originalTasks, restored: restoredTasks, current: tasks)
        return summary
    }

    // Apply preferences only after both durable stores accepted the restore.
    private func applyLibraryBackupPreferences(_ document: BackupDocument) {
        let localIDs = Dictionary(notes.map { (BackupEntry.portableNoteKey($0.id), $0.id) }, uniquingKeysWith: { first, _ in first })
        func localID(_ id: String) -> String { localIDs[BackupEntry.portableNoteKey(id)] ?? BackupEntry.portableNoteKey(id) }
        for collection in document.collections {
            let members = Set(collection.noteIDs.map(localID))
            if let index = collections.firstIndex(where: { $0.id == collection.id }) {
                collections[index].noteIDs.formUnion(members)
            } else {
                var mapped = collection
                mapped.noteIDs = members
                collections.append(mapped)
            }
        }
        likedNotes.formUnion(document.likedNotes.map(localID))
        bookmarkedNotes.formUnion(document.bookmarkedNotes.map(localID))
        for (key, value) in document.authorRemarks { authorRemarks[key] = value }

        if let settings = document.settings {
            applyBackupSettings(settings)
        }
        persistLibraryPreferences()
    }

    /// Changes made while disk I/O suspends win over the older restore snapshot.
    /// Newly created and deleted items also keep their current state.
    private static func reconcileRestore<Item: Identifiable & Equatable>(original: [Item], restored: [Item], current: [Item]) -> [Item] {
        let before = Dictionary(original.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(restored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let present = Set(current.map(\.id))
        let additions = restored.filter { before[$0.id] == nil && !present.contains($0.id) }
        return additions + current.map { item in before[item.id] == item ? (after[item.id] ?? item) : item }
    }

    private static func mergeMetadata(_ local: NoteMetadata, _ incoming: NoteMetadata) -> NoteMetadata {
        var result = local
        result.userName = incoming.userName?.isEmpty == false ? incoming.userName : local.userName
        result.userId = incoming.userId ?? local.userId
        result.title = incoming.title ?? local.title
        result.publishTime = incoming.publishTime ?? local.publishTime
        result.redId = incoming.redId ?? local.redId
        result.avatarURL = incoming.avatarURL ?? local.avatarURL
        result.topics = (incoming.topics?.isEmpty == false ? incoming.topics : local.topics)
        result.publishedAt = incoming.publishedAt ?? local.publishedAt
        result.profileURL = incoming.profileURL ?? local.profileURL
        return result
    }

    private func applyBackupSettings(_ backup: BackupSettings) {
        var policy = backup.policy
        // Capabilities and credentials never come from a file.
        policy.filesBookmark = settings.policy.filesBookmark
        policy.proxy = settings.policy.proxy
        settings.policy = policy
        settings.livePhotoMode = backup.livePhotoMode
        settings.selectiveDownload = backup.selectiveDownload
        settings.notifications = backup.notifications
        settings.debugNotifications = backup.debugNotifications
        settings.haptics = backup.haptics
        settings.appearance = backup.appearance
        settings.keepScreenAwake = backup.keepScreenAwake
        settings.clipboardSuggestions = backup.clipboardSuggestions
        settings.defaults.set(backup.namingEnabled, forKey: NamingPreferences.enableKey)
        settings.defaults.set(backup.namingTemplate, forKey: NamingPreferences.templateKey)
        settings.defaults.set(backup.namingTimeZone, forKey: NamingPreferences.timezoneKey)
    }

    private func schedule() {
        guard isLoaded, jobs.isEmpty, let task = tasks.reversed().first(where: { $0.status == .queued && !pendingAdmissions.contains($0.id) }) else { return }
        let id = task.id
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            await self.run(taskID: id)
            await self.flushPersistence()
            self.jobs[id] = nil
            self.schedule()
        }
    }

    /// A downloader bound to one task's snapshot. Editing timeout, retries,
    /// proxy or session reuse takes effect for the next task instead of waiting
    /// for an app restart.
    /// Naming snapshot: the policy the task was submitted with, plus the instant
    /// it was submitted. A retry therefore reproduces the same file names.
    private func namingContext(for task: DownloadTaskRecord, policy: DownloadPolicy) -> XHSDownloader.NamingContext {
        let preferences = NamingPreferences(
            enabled: policy.namingEnabled,
            template: policy.namingTemplate,
            timeZone: TimeZone(identifier: policy.namingTimezone) ?? .current)
        return XHSDownloader.NamingContext(preferences: preferences,
                                           downloadInstant: task.downloadInstant ?? task.createdAt)
    }

    private func downloader(for task: DownloadTaskRecord) -> XHSDownloader {
        guard let policy = task.policy else { return downloader }
        // Reuse the injected session when there is one: a per-task policy change
        // must not replace the transport a test or preview supplied.
        return XHSDownloader(session: injectedSession, policy: policy, pacer: pacer)
    }

    private func run(taskID: UUID) async {
        guard let task = task(for: taskID) else { return }
        let taskDownloader = downloader(for: task)
        update(taskID) { record in
            record.status = .downloading
            record.errorMessage = nil
            record.phase = TaskPhase.resolving.rawValue
        }
        do {
            let note: ResolvedNote
            if let resolved = task.resolvedNote { note = resolved }
            else { note = try await taskDownloader.resolveNote(from: task.normalizedURL,
                                                              naming: namingContext(for: task, policy: task.policy ?? settings.policy)) }
            try Task.checkCancellation()
            update(taskID) { record in
                record.resolvedNote = note
                record.mediaCount = note.media.count
                record.noteType = inferNoteType(note.media)
                record.noteText = note.body
                record.title = note.title
                record.noteKey = StoredNote.key(noteID: note.noteID, url: record.normalizedURL)
            }
            syncNote(for: taskID)
            if let avatarURL = note.metadata.avatarURL {
                Task { _ = await AuthorAvatarStore.shared.imageData(for: avatarURL) }
            }
            // The snapshot was written at submit time; older records fall back
            // once and then keep it, so a resumed task never picks up new settings.
            let policy = task.policy ?? settings.policy
            if task.policy == nil { update(taskID) { $0.policy = policy } }

            // "Note only" never touches media, so it must not request photo
            // library access or open a media transfer at all.
            if task.informationOnly == true {
                try await saveNoteOnly(note: note, taskID: taskID, policy: policy)
                return
            }

            if (task.selectionRequired ?? settings.selectiveDownload) && task.selectedMediaIDs == nil {
                update(taskID) {
                    $0.status = .waitingForUser
                    $0.phase = TaskPhase.waitingSelection.rawValue
                }
                if selectionState == nil { showSelection(taskID: taskID) }
                return
            }
            let selected = note.media.filter { media in
                guard policy.includes(media) else { return false }
                return task.selectedMediaIDs == nil || task.selectedMediaIDs!.contains(media.stableID)
            }
            let media = selected.map { $0.applying(policy, variantID: task.selectedVariants?[$0.stableID]) }
            update(taskID) { record in
                record.submittedMediaIDs = media.map(\.stableID)
                record.mediaCount = media.count
                var results = record.resourceResults ?? [:]
                for item in media where results[item.stableID] == nil {
                    results[item.stableID] = ResourceResult(state: .queued)
                }
                record.resourceResults = results
            }
            if media.isEmpty {
                update(taskID) { record in
                    record.status = .completed
                    record.progress = 1
                    record.errorMessage = L10n.text("error.no_media_selected")
                }
                await postNotification(taskID: taskID, success: true)
                return
            }
            update(taskID) { $0.phase = TaskPhase.transferring.rawValue }
            try await downloadAndSave(media, taskID: taskID)
        } catch is CancellationError {
            // Pause/delete set the final state before cancellation. The old job
            // must exit before the scheduler or retry may launch another one.
        } catch {
            guard self.task(for: taskID)?.status == .downloading else { return }
            update(taskID) { record in
                record.status = record.savedCount > 0 ? .partial : .failed
                record.errorMessage = error.localizedDescription
                record.failedCount = max(1, record.mediaCount - record.savedCount)
            }
            // Parsing already succeeded, so the text and author are worth keeping
            // even when the folder or the transfer failed. Without this a
            // Files-only task with an unusable folder left no note at all.
            syncNote(for: taskID)
            await postNotification(taskID: taskID, success: false)
        }
    }

    /// "Save note only" keeps the text, metadata and topics in the local
    /// library. It never downloads media, so it must not ask for photo
    /// permission; the optional caption file is the only thing written out.
    private func saveNoteOnly(note: ResolvedNote, taskID: UUID, policy: DownloadPolicy) async throws {
        update(taskID) { record in
            record.noteText = note.body
            record.title = note.title
            record.mediaCount = 0
            record.resourceResults = [:]
        }
        let wantsFiles = policy.destination == .files || policy.destination == .both
        if wantsFiles, policy.captionFormat != .none, policy.filesBookmark != nil {
            do {
                let directory = try await FileArchiver.shared.prepare(note: note, policy: policy)
                do {
                    let written = try await FileArchiver.shared.writeCaptions(note: note, in: directory, policy: policy)
                    await FileArchiver.shared.release(directory)
                    if !written.isEmpty { update(taskID) { $0.archiveTextPaths = written } }
                } catch {
                    await FileArchiver.shared.release(directory)
                    throw error
                }
            } catch {
                // The note itself is already durable; a caption write failure is
                // surfaced without discarding the saved text.
                update(taskID) { $0.errorMessage = error.localizedDescription }
            }
        }
        update(taskID) { record in
            record.status = .completed
            record.progress = 1
            record.savedCount = 0
            record.failedCount = 0
            record.phase = nil
        }
        // "Save note only" must reach the library through the same path as any
        // other download; without this the task completes but no note appears.
        syncNote(for: taskID)
        await postNotification(taskID: taskID, success: true)
    }

    private func stagedFile(_ media: RemoteMedia, taskID: UUID, key: String) async throws -> URL {
        if let path = task(for: taskID)?.stagedFiles?[key], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        updateResource(taskID: taskID, key: key) { $0.state = .downloading }
        let activeDownloader = task(for: taskID).map { downloader(for: $0) } ?? downloader
        let file = try await activeDownloader.download(media: media, sessionTimestamp: activeDownloader.makeSessionTimestamp(),
            transferIdentity: taskID.uuidString + ":" + key) { [weak self] progress in
                guard let owner = self else { return }
                Task { @MainActor in
                    owner.updateResource(taskID: taskID, key: key, persist: .deferred) {
                        $0.received = progress.received
                        $0.expected = progress.expected
                        $0.speed = progress.bytesPerSecond
                    }
                    // Sum across resources. Writing the last callback directly
                    // made the task total jump between concurrent files.
                    owner.update(taskID, persist: .deferred) { task in
                        guard task.status == .downloading else { return }
                        let values = (task.resourceResults ?? [:]).values
                        task.transferredBytes = values.reduce(Int64(0)) { $0 + $1.received }
                        let expected = values.reduce(Int64(0)) { $0 + $1.expected }
                        task.expectedBytes = expected > 0 ? expected : nil
                        task.bytesPerSecond = values.reduce(0) { $0 + $1.speed }
                    }
                }
            }
        update(taskID) { task in
            if task.stagedFiles == nil { task.stagedFiles = [:] }
            task.stagedFiles?[key] = file.path
        }
        return file
    }

    /// Per-resource bookkeeping lives in the task record so the detail view can
    /// show every stable slot, including the ones that failed.
    private func updateResource(
        taskID: UUID,
        key: String,
        persist mode: PersistMode = .immediate,
        mutation: (inout ResourceResult) -> Void
    ) {
        update(taskID, persist: mode) { task in
            var results = task.resourceResults ?? [:]
            var entry = results[key] ?? ResourceResult()
            mutation(&entry)
            results[key] = entry
            task.resourceResults = results
        }
    }

    /// "Write publish time" is only meaningful with a real publish date. It sets
    /// the Photos creation date and the archived file's modification date, so a
    /// library sorted by date matches the note rather than the download.
    private func publishDate(for taskID: UUID) -> Date? {
        guard let policy = task(for: taskID)?.policy, policy.writePublishTime else { return nil }
        return task(for: taskID)?.resolvedNote?.metadata.publishedAt
    }

    private func recordAsset(file: URL, isVideo: Bool, key: String, taskID: UUID, paired: URL? = nil,
                             originalName: String? = nil, files: [String] = []) async throws {
        if task(for: taskID)?.mediaAssets.contains(where: { $0.sourceMediaID == key }) == true { return }
        let metadata = await MediaFileMetadata.read(url: file, isVideo: isVideo)
        let stagedName = file.lastPathComponent
        let fileName = originalName ?? (UUID(uuidString: String(stagedName.prefix(36))) != nil && stagedName.dropFirst(36).first == "_"
            ? String(stagedName.dropFirst(37)) : stagedName)
        let identifier: String
        let creationDate = publishDate(for: taskID)
        if let paired {
            identifier = try await photoLibrary.saveLivePhoto(photoURL: file, pairedVideoURL: paired,
                                                              originalFilename: fileName, creationDate: creationDate)
        } else {
            identifier = try await photoLibrary.saveMedia(at: file, isVideo: isVideo,
                                                          originalFilename: fileName, creationDate: creationDate)
        }
        update(taskID) { task in
            var record = MediaAssetRecord(localIdentifier: identifier, fileName: fileName, isVideo: isVideo,
                pixelWidth: metadata.pixelWidth, pixelHeight: metadata.pixelHeight, byteCount: metadata.byteCount)
            record.sourceMediaID = key
            if !files.isEmpty { record.filesPaths = files }
            task.mediaAssets.append(record)
        }
    }

    /// Files-only saves have no Photos asset. The record keeps the archived
    /// path so the note feed, the detail view and deletion can still find it.
    private func recordArchivedAsset(paths: [String], isVideo: Bool, isLive: Bool, key: String,
                                     taskID: UUID, fileName: String?) async throws {
        guard let first = paths.first else { return }
        if task(for: taskID)?.mediaAssets.contains(where: { $0.sourceMediaID == key }) == true { return }
        let metadata = await MediaFileMetadata.read(url: URL(fileURLWithPath: first), isVideo: isVideo)
        let name = fileName ?? URL(fileURLWithPath: first).lastPathComponent
        // The identifier carries every component path so a Live Photo can play its
        // motion file instead of showing only the still.
        let identifier = "file:" + paths.joined(separator: "\n")
        update(taskID) { task in
            var record = MediaAssetRecord(localIdentifier: identifier, fileName: name, isVideo: isVideo,
                pixelWidth: metadata.pixelWidth, pixelHeight: metadata.pixelHeight, byteCount: metadata.byteCount)
            record.sourceMediaID = key
            record.filesPaths = paths
            record.isLive = isLive
            task.mediaAssets.append(record)
        }
    }

    /// Writes archive paths onto an existing media record. Used when the Files
    /// destination is filled in after the Photos half already succeeded.
    private func attachArchivedPaths(_ paths: [String], key: String, taskID: UUID) {
        guard !paths.isEmpty else { return }
        update(taskID) { task in
            guard let index = task.mediaAssets.firstIndex(where: {
                $0.sourceMediaID == key || $0.sourceMediaID == key + ":still"
            }) else { return }
            var merged = Set(task.mediaAssets[index].filesPaths ?? [])
            merged.formUnion(paths)
            task.mediaAssets[index].filesPaths = Array(merged).sorted()
        }
    }

    private func downloadAndSave(_ media: [RemoteMedia], taskID: UUID) async throws {
        let record = task(for: taskID)
        let policy = record?.policy ?? settings.policy
        let mode = record?.livePhotoMode ?? ((record?.livePhotoEnabled ?? settings.createLivePhotos) ? .merged : .separate)
        let wantsPhotos = policy.destination == .photos || policy.destination == .both
        let wantsFiles = policy.destination == .files || policy.destination == .both

        // The archive folder is resolved once per task so a long batch keeps one
        // security scope instead of re-acquiring it for every resource.
        var archiveDirectory: FileArchiver.ResolvedDirectory?
        var archiveError: Error?
        if wantsFiles, let note = record?.resolvedNote {
            do {
                archiveDirectory = try await FileArchiver.shared.prepare(note: note, policy: policy)
            } catch {
                // A Photos-only task still completes when the folder is missing.
                // With "Photos and Files" the Files half is recorded as failed per
                // resource, so the task cannot be reported as fully complete and a
                // retry can fill in the archive later.
                archiveError = error
                if !wantsPhotos { throw error }
                alertMessage = error.localizedDescription
            }
        }

        var counts: (saved: Int, failed: Int)
        do {
            counts = try await transfer(media, taskID: taskID, policy: policy, mode: mode,
                                        wantsPhotos: wantsPhotos, wantsFiles: wantsFiles,
                                        archive: archiveDirectory, archiveError: archiveError)
            if wantsFiles, let archiveDirectory, let note = record?.resolvedNote,
               policy.captionFormat != .none {
                do {
                    let written = try await FileArchiver.shared.writeCaptions(note: note, in: archiveDirectory, policy: policy)
                    if !written.isEmpty { update(taskID) { $0.archiveTextPaths = written } }
                } catch {
                    // Captions are a side artifact: media already landed, so the
                    // failure is reported without demoting the whole task.
                    update(taskID) { $0.errorMessage = error.localizedDescription }
                }
            }
        } catch {
            if let archiveDirectory { await FileArchiver.shared.release(archiveDirectory) }
            throw error
        }
        if let archiveDirectory { await FileArchiver.shared.release(archiveDirectory) }
        try Task.checkCancellation()
        finish(taskID: taskID, expected: media.count, saved: counts.saved, failed: counts.failed)
    }

    private func transfer(
        _ media: [RemoteMedia],
        taskID: UUID,
        policy: DownloadPolicy,
        mode: LivePhotoMode,
        wantsPhotos: Bool,
        wantsFiles: Bool,
        archive: FileArchiver.ResolvedDirectory?,
        archiveError: Error?
    ) async throws -> (saved: Int, failed: Int) {
        var completed = Set(task(for: taskID)?.completedMediaIDs ?? [])
        var failed = 0
        var saved = media.filter { completed.contains($0.stableID) }.count
        for start in stride(from: 0, to: media.count, by: 4) {
            let batch = Array(media.enumerated()).dropFirst(start).prefix(4)
            let errors = await withTaskGroup(of: (String, Error?).self, returning: [String: Error].self) { group in
                for (_, item) in batch where !completed.contains(item.stableID) {
                    group.addTask { [self] in
                        do {
                            _ = try await stagedFile(item, taskID: taskID, key: item.stableID)
                            if item.type == .livePhoto, mode != .still, let url = item.pairedVideoURLs.first {
                                let motion = RemoteMedia(stableID: item.stableID + ":motion", url: url, type: .video,
                                    fileBaseName: item.fileBaseName + "_motion", originalURLString: url.absoluteString,
                                    candidates: item.pairedVideoURLs)
                                _ = try await stagedFile(motion, taskID: taskID, key: motion.stableID)
                            }
                            return (item.stableID, nil)
                        } catch { return (item.stableID, error) }
                    }
                }
                var failures: [String: Error] = [:]
                for await (id, error) in group { failures[id] = error }
                return failures
            }
            try Task.checkCancellation()
            for (index, item) in batch {
                try Task.checkCancellation()
                if completed.contains(item.stableID) { continue }
                do {
                    if let error = errors[item.stableID] { throw error }
                    let photo = try await stagedFile(item, taskID: taskID, key: item.stableID)
                    try Task.checkCancellation()
                    // A Live Photo keeps its motion component under one stable
                    // key so a resumed task can reuse the staged file.
                    let motionKey = item.stableID + ":motion"
                    var motion: URL?
                    if item.type == .livePhoto, mode != .still, let videoURL = item.pairedVideoURLs.first {
                        let video = RemoteMedia(stableID: motionKey, url: videoURL, type: .video,
                            fileBaseName: item.fileBaseName + "_motion", originalURLString: videoURL.absoluteString,
                            candidates: item.pairedVideoURLs)
                        motion = try await stagedFile(video, taskID: taskID, key: motionKey)
                    }

                    // Files and Photos are independent destinations. Each one is
                    // recorded on its own so a missing folder cannot masquerade as
                    // a completed save, and a retry can fill in only the missing
                    // half without re-downloading what already landed.
                    // A destination that already succeeded must not be redone:
                    // re-archiving would create "_2" duplicates when smart skip
                    // is off.
                    let previous = task(for: taskID)?.resourceResults?[item.stableID]
                    // A merge can only be produced when Photos is a destination.
                    // Files-only Live Photos keep both components by design.
                    let mergeRequired = item.type == .livePhoto && mode == .merged && wantsPhotos
                    let mergeAlreadyDone = previous?.livePhotoOutcome == .merged
                    // "The photo is saved" is not the same as "the Live Photo is
                    // saved": when a merge was requested and did not happen, the
                    // Photos half must run again instead of being skipped.
                    let photosAlreadySaved = previous?.photos?.state == .saved
                        && (!mergeRequired || mergeAlreadyDone)
                    let filesAlreadySaved = previous?.files?.isSettled == true
                    let previousArchive = previous?.files?.reference

                    var archived: [String] = filesAlreadySaved ? [previousArchive].compactMap { $0 } : []
                    var filesResult = DestinationResult()
                    var skippedFile = false
                    if filesAlreadySaved {
                        filesResult = previous?.files ?? DestinationResult(state: .saved)
                    } else if let archive {
                        var entries = [FileArchiver.Entry(file: photo, baseName: item.fileBaseName, key: item.stableID)]
                        if let motion {
                            entries.append(FileArchiver.Entry(file: motion, baseName: item.fileBaseName + "_motion",
                                                              key: motionKey))
                        }
                        let result = try await FileArchiver.shared.archive(entries: entries, in: archive, policy: policy)
                        // One path per requested component, taken from the result
                        // by resource key. Matching by file name lost the real
                        // path whenever de-duplication produced "name_2.heic".
                        archived = entries.compactMap { result.paths[$0.key] }
                        skippedFile = result.skipped.contains(item.stableID)
                        let failure = result.failed[item.stableID] ?? result.failed[motionKey]
                        // "Write publish time" also applies to the archived copy.
                        if policy.writePublishTime, let published = task(for: taskID)?.resolvedNote?.metadata.publishedAt {
                            for path in archived {
                                try? FileManager.default.setAttributes([.modificationDate: published],
                                                                       ofItemAtPath: path)
                            }
                        }
                        if let failure {
                            filesResult.state = .failed
                            filesResult.error = failure
                        } else if archived.isEmpty {
                            filesResult.state = .failed
                            filesResult.error = L10n.text("archive.error.nodirectory")
                        } else {
                            filesResult.state = skippedFile ? .skipped : .saved
                        }
                        filesResult.reference = archived.first
                    } else if archiveError != nil {
                        filesResult.state = .failed
                        filesResult.error = archiveError?.localizedDescription
                    } else if wantsFiles {
                        filesResult.state = .failed
                        filesResult.error = L10n.text("archive.error.nodirectory")
                    }

                    var photosResult = DestinationResult()
                    if wantsPhotos, photosAlreadySaved {
                        photosResult = previous?.photos ?? DestinationResult(state: .saved)
                    } else if wantsPhotos {
                        do {
                            let outcome = try await saveToPhotos(
                                item, photo: photo, motion: motion, motionKey: motionKey, mode: mode,
                                archived: archived, taskID: taskID)
                            photosResult.state = .saved
                            photosResult.reference = task(for: taskID)?.mediaAssets
                                .last { $0.sourceMediaID == item.stableID || $0.sourceMediaID == item.stableID + ":still" }?
                                .localIdentifier
                            if let outcome {
                                updateResource(taskID: taskID, key: item.stableID) { $0.livePhotoOutcome = outcome }
                            }
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            photosResult.state = .failed
                            photosResult.error = error.localizedDescription
                        }
                    }

                    // A retry that only filled in the Files half must attach those
                    // paths to the media record the Photos half created earlier.
                    if wantsPhotos, photosAlreadySaved, !archived.isEmpty,
                       filesResult.state == .saved || filesResult.state == .skipped {
                        attachArchivedPaths(archived, key: item.stableID, taskID: taskID)
                    }

                    // Files-only saves still need a media record, otherwise the
                    // note has no media to browse and the archive looks empty.
                    if !wantsPhotos, filesResult.state == .saved || filesResult.state == .skipped,
                       !archived.isEmpty {
                        try await recordArchivedAsset(paths: archived, isVideo: item.isVideo,
                                                      isLive: item.type == .livePhoto && mode != .still,
                                                      key: item.stableID, taskID: taskID,
                                                      fileName: item.fileBaseName + "." + photo.pathExtension)
                        filesResult.reference = archived.first
                    }

                    let outcome = mergeRequired
                        ? (task(for: taskID)?.resourceResults?[item.stableID]?.livePhotoOutcome)
                        : nil
                    let settled = ResourceResult(
                        state: .saved,
                        photos: wantsPhotos ? photosResult : nil,
                        files: archive != nil || archiveError != nil ? filesResult : nil,
                        livePhotoOutcome: outcome)
                    // Completion is decided by what the user asked for, never by
                    // whether the folder happened to be available: a failed Files
                    // destination must keep the task incomplete.
                    let satisfied = settled.isSatisfied(
                        photosRequired: wantsPhotos,
                        filesRequired: wantsFiles,
                        mergeRequired: mergeRequired)

                    if satisfied {
                        completed.insert(item.stableID)
                        saved += 1
                    } else {
                        failed += 1
                    }
                    update(taskID) { task in
                        task.completedMediaIDs = Array(completed)
                        task.savedCount = saved
                        task.failedCount = failed
                        task.progress = Double(index + 1) / Double(media.count)
                        // Keep staged originals when a destination is still
                        // missing, so a retry does not download them again.
                        if satisfied {
                            task.stagedFiles?[item.stableID] = nil
                            task.stagedFiles?[motionKey] = nil
                        }
                        if !satisfied {
                            task.errorMessage = settled.files?.error ?? settled.photos?.error
                                ?? L10n.text("error.live_pair")
                        }
                    }
                    updateResource(taskID: taskID, key: item.stableID) { entry in
                        entry.state = satisfied ? .saved : .failed
                        entry.photos = wantsPhotos ? photosResult : nil
                        entry.files = archive != nil || archiveError != nil ? filesResult : nil
                        entry.error = satisfied ? nil : (settled.files?.error ?? settled.photos?.error
                            ?? L10n.text("error.live_pair"))
                        if mergeRequired, outcome != .merged {
                            entry.livePhotoOutcome = outcome ?? .componentsOnly
                        }
                    }
                    if satisfied {
                        try? FileManager.default.removeItem(at: photo)
                        if let motion { try? FileManager.default.removeItem(at: motion) }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if Task.isCancelled { throw CancellationError() }
                    failed += 1
                    update(taskID) { task in
                        task.failedCount = failed
                        task.progress = Double(index + 1) / Double(media.count)
                        task.errorMessage = error.localizedDescription
                    }
                    let message = error.localizedDescription
                    updateResource(taskID: taskID, key: item.stableID) {
                        $0.state = .failed
                        $0.error = message
                    }
                }
            }
        }
        return (saved, failed)
    }

    /// Photos import keeps the Live Photo pairing contract. It reports what
    /// actually happened: `.merged` when a native Live Photo was created, and
    /// `.componentsOnly` when the still and motion were stored separately. The
    /// caller decides completion from that outcome, so a failed merge stays
    /// retryable instead of being counted as saved twice.
    @discardableResult
    private func saveToPhotos(_ item: RemoteMedia, photo: URL, motion: URL?, motionKey: String,
                              mode: LivePhotoMode, archived: [String],
                              taskID: UUID) async throws -> LivePhotoOutcome? {
        guard item.type == .livePhoto, mode != .still, let motion else {
            try await recordAsset(file: photo, isVideo: item.isVideo, key: item.stableID, taskID: taskID,
                                  files: archived)
            return item.type == .livePhoto ? .componentsOnly : nil
        }
        if mode == .merged {
            do {
                let pair = try await LivePhotoPairer.pair(photo: photo, video: motion)
                defer {
                    if pair.photo != photo { try? FileManager.default.removeItem(at: pair.photo) }
                    try? FileManager.default.removeItem(at: pair.video)
                }
                try Task.checkCancellation()
                try await recordAsset(file: pair.photo, isVideo: false, key: item.stableID, taskID: taskID,
                                      paired: pair.video,
                                      originalName: item.fileBaseName + "." + pair.photo.pathExtension,
                                      files: archived)
                return .merged
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Preserve both originals and say so. The resource stays failed
                // so "retry failed items" can attempt the merge again.
                try Task.checkCancellation()
                try await recordAsset(file: photo, isVideo: false, key: item.stableID + ":still", taskID: taskID,
                                      files: archived)
                try await recordAsset(file: motion, isVideo: true, key: motionKey, taskID: taskID)
                return .componentsOnly
            }
        }
        try await recordAsset(file: photo, isVideo: false, key: item.stableID + ":still", taskID: taskID,
                              files: archived)
        try await recordAsset(file: motion, isVideo: true, key: motionKey, taskID: taskID)
        return .componentsOnly
    }

    private func finish(taskID: UUID, expected: Int, saved: Int, failed: Int) {
        syncNote(for: taskID)
        update(taskID) { task in
            task.phase = TaskPhase.finished.rawValue
            task.savedCount = saved
            task.failedCount = failed
            task.progress = 1
            if saved == expected && failed == 0 {
                task.status = .completed
            } else {
                task.status = saved > 0 ? .partial : .failed
                task.errorMessage = task.errorMessage ?? L10n.format("error.partial_failure", saved, expected)
            }
        }
        Task { await postNotification(taskID: taskID, success: failed == 0 && saved == expected) }
    }

    /// Completion alerts and diagnostic alerts are separate opt-ins: the normal
    /// switch asks for authorization, the diagnostic switch only records while
    /// the user already granted it.
    private func postNotification(taskID: UUID, success: Bool) async {
        guard settings.notifications || settings.debugNotifications,
              let task = task(for: taskID) else { return }
        let center = UNUserNotificationCenter.current()
        if settings.notifications {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
        } else {
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
        }
        let content = UNMutableNotificationContent()
        content.title = success ? L10n.text("notification.completed") : L10n.text("notification.failed")
        content.body = task.title.isEmpty ? task.normalizedURL : task.title
        content.sound = .default
        content.userInfo = ["task": task.id.uuidString]
        try? await center.add(UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil))
    }

    /// Called by the notification delegate when the user taps an alert.
    func focus(taskID: UUID) {
        if !isLoaded {
            Task { await waitUntilLoaded(); focus(taskID: taskID) }
            return
        }
        guard task(for: taskID) != nil else { return }
        focusedTask = TaskFocus(id: taskID)
    }

    private func inferNoteType(_ media: [RemoteMedia]) -> NoteType {
        let types = Set(media.map(\.type))
        if types == [.image] { return .image }
        if types == [.video] { return .video }
        if types == [.livePhoto] { return .livePhoto }
        return .mixed
    }

    private func task(for id: UUID) -> DownloadTaskRecord? {
        tasks.first { $0.id == id }
    }

    /// Status changes, selection confirmations and save results must reach disk
    /// immediately. Byte counters arrive several times per second, so they only
    /// mutate memory and request one coalesced write.
    private enum PersistMode { case immediate, deferred }

    private func update(_ id: UUID, persist mode: PersistMode = .immediate, mutation: (inout DownloadTaskRecord) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let previousStatus = tasks[index].status
        mutation(&tasks[index])
        tasks[index].updatedAt = Date()
        var persisted: Task<Bool, Never>?
        switch mode {
        case .immediate:
            persistTask?.cancel()
            persistTask = nil
            persisted = persist()
        case .deferred:
            schedulePersist()
        }
        if previousStatus != tasks[index].status,
           let feedback = FeedbackEvent.result(for: tasks[index].status), AppFeedback.canPlay {
            let event = tasks[index].status == .completed && tasks[index].errorMessage != nil
                ? FeedbackEvent.taskResult(.partial) : feedback
            let status = tasks[index].status
            let generation = AppFeedback.deferredGeneration
            Task { [weak self] in
                guard await persisted?.value == true, self?.task(for: id)?.status == status else { return }
                AppFeedback.play(event, generation: generation)
            }
        }
    }

    private func schedulePersist() {
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistTask = nil
            self.persist()
        }
    }

    /// Flush any coalesced progress write before the record leaves memory.
    private func flushPendingPersist() {
        guard persistTask != nil else { return }
        persistTask?.cancel()
        persistTask = nil
        persist()
    }

    @discardableResult
    private func persist(includeNotes: Bool = false) -> Task<Bool, Never> {
        if includeNotes { noteRevision += 1 }
        let previous = writes
        let store = store
        let noteStore = noteStore
        let write = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return false }
            // Snapshot when this writer gets its turn. A restore or later user
            // action may have superseded a write that was waiting in the queue.
            let taskSnapshot = self.tasks
            let revision = self.noteRevision
            let noteSnapshot = revision > self.savedNoteRevision ? self.notes : nil
            do {
                if let noteSnapshot {
                    try await noteStore.save(noteSnapshot)
                    self.savedNoteRevision = revision
                }
                // A task may be the last recoverable copy of a note. Persist the
                // note before committing task removal or its final status.
                try await store.save(taskSnapshot)
                return true
            } catch {
                self.alertMessage = L10n.format("error.persistence", error.localizedDescription)
                return false
            }
        }
        writes = write
        return write
    }

    private func recoverInterruptedTasks() {
        var changed = false
        for index in tasks.indices where tasks[index].status == .queued || tasks[index].status == .downloading || tasks[index].status == .waitingForUser {
            if tasks[index].status == .waitingForUser, tasks[index].resolvedNote != nil { continue }
            tasks[index].status = .paused
            tasks[index].errorMessage = L10n.text("error.interrupted")
            changed = true
        }
        if changed { persist() }
    }

    private func cleanupSelectionFiles(_ state: SelectiveDownloadState?) {
        state?.items.filter { $0.cachedURL.isFileURL }.forEach { try? FileManager.default.removeItem(at: $0.cachedURL) }
    }

    private func stopSilently(taskID: UUID) {
        jobs[taskID]?.cancel()
        if selectionState?.taskID == taskID {
            cleanupSelectionFiles(selectionState)
            selectionState = nil
        }
    }
}

private extension String {
    var firstNonemptyLine: String? {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}


private struct MediaFileMetadata: Sendable {
    let pixelWidth: Int?
    let pixelHeight: Int?
    let byteCount: Int64?

    static func read(url: URL, isVideo: Bool) async -> MediaFileMetadata {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        if isVideo {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let dimensions = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let transformed = dimensions.applying(transform)
                return MediaFileMetadata(pixelWidth: Int(abs(transformed.width)), pixelHeight: Int(abs(transformed.height)), byteCount: size)
            }
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            return MediaFileMetadata(pixelWidth: properties[kCGImagePropertyPixelWidth] as? Int,
                pixelHeight: properties[kCGImagePropertyPixelHeight] as? Int, byteCount: size)
        }
        return MediaFileMetadata(pixelWidth: nil, pixelHeight: nil, byteCount: size)
    }
}
