import Foundation
import Testing
import UIKit
import AVFoundation
@testable import XHS_Downloader_iOS

@Suite(.serialized) @MainActor
struct ContinuationTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func databaseMigrationRemainsOneShotAndPreservesLegacyBytes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy.json")
        let database = root.appendingPathComponent("Library.store")
        let record = DownloadTaskRecord(sourceText: "original", normalizedURL: "https://example.com/1", title: "旧任务", status: .completed)
        try await DownloadTaskStore(fileURL: legacy).save([record])
        let original = try Data(contentsOf: legacy)
        let store = DownloadTaskStore(fileURL: legacy, databaseURL: database)
        #expect(await store.load().map(\.id) == [record.id])
        #expect(try Data(contentsOf: root.appendingPathComponent("before-swiftdata-v1.json")) == original)
        try await store.save([])
        let restarted = DownloadTaskStore(fileURL: legacy, databaseURL: database)
        #expect(await restarted.load().isEmpty)
        #expect(try Data(contentsOf: legacy) == original)
    }

    @Test func badMigrationCannotOverwriteUnreadableLegacyData() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy.json")
        let bytes = Data("invalid-json".utf8)
        try bytes.write(to: legacy)
        let store = DownloadTaskStore(fileURL: legacy, databaseURL: root.appendingPathComponent("Library.store"))
        #expect(await store.load().isEmpty)
        #expect(await store.loadError != nil)
        await #expect(throws: (any Error).self) { try await store.save([]) }
        #expect(try Data(contentsOf: legacy) == bytes)
    }

    @Test func failedDatabaseEncodingLeavesNoPendingChangesToCommitLater() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("legacy.json"), databaseURL: root.appendingPathComponent("Library.store"))
        #expect(await store.load().isEmpty)
        let original = DownloadTaskRecord(sourceText: "", normalizedURL: "https://example.com/original", title: "Original", status: .completed)
        try await store.save([original])
        var invalid = original
        invalid.title = "Must not commit"
        invalid.progress = .nan
        await #expect(throws: (any Error).self) { try await store.save([invalid]) }
        #expect(await store.load().first?.title == "Original")
        try await store.save([])
        #expect(await store.load().isEmpty)
    }

    @Test func missingNoteRecoveryPreservesExistingTextAndFailedSaveRetainsTaskHistory() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let noteURL = root.appendingPathComponent("notes.json")
        let noteStore = NoteStore(fileURL: noteURL)
        let existing = StoredNote(id: "note:existing", noteID: "existing", canonicalURL: "https://example.com/existing",
            title: "Keep", body: "Independent note text", metadata: NoteMetadata())
        try await noteStore.save([existing])
        var task = DownloadTaskRecord(sourceText: "", normalizedURL: "https://example.com/recover", title: "Recover", noteText: "Recoverable body", status: .completed)
        task.noteKey = "note:recover"
        try await store.save([task])
        let coordinator = DownloadCoordinator(settings: AppSettings(defaults: try #require(UserDefaults(suiteName: UUID().uuidString))),
            store: store, noteStore: noteStore)
        await coordinator.waitUntilLoaded()
        #expect(coordinator.notes.count == 2)
        #expect(coordinator.note(forKey: existing.id)?.body == existing.body)
        #expect(coordinator.note(forKey: "note:recover")?.body == task.noteText)
        try Data("corrupt".utf8).write(to: noteURL)
        try FileManager.default.removeItem(at: root.appendingPathComponent("notes.backup.json"))
        coordinator.removeFinished()
        await coordinator.flushPersistence()
        #expect(await store.load().map(\.id) == [task.id])
        #expect(coordinator.alertMessage != nil)
        #expect(try Data(contentsOf: noteURL) == Data("corrupt".utf8))
    }

    @Test func delayedPersistenceKeepsInboxPendingAndMainActorResponsive() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let backing = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let store = ControlledTaskStore(backing: backing)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let coordinator = DownloadCoordinator(settings: AppSettings(defaults: defaults), store: store,
                                               noteStore: NoteStore(fileURL: root.appendingPathComponent("notes.json")))
        await coordinator.waitUntilLoaded()
        let inbox = ImportInbox(directory: root.appendingPathComponent("inbox"))
        let request = ImportRequest(text: "https://www.xiaohongshu.com/explore/held", source: .share)
        try inbox.append(request)
        let consumption = Task { await coordinator.consume(inbox: inbox) }
        while !(await store.isWaiting) { await Task.yield() }
        // Running this assertion on MainActor while disk is held demonstrates
        // that persistence suspends rather than blocking the UI executor.
        #expect(try inbox.pending().map(\.id) == [request.id])
        #expect(await backing.load().isEmpty)
        let duplicate = coordinator.enqueue(request.text)
        // Pause before releasing the write to avoid any external network work.
        let task = try #require(coordinator.tasks.first)
        coordinator.stop(taskID: task.id)
        await store.release()
        await consumption.value
        #expect(await duplicate.value)
        await coordinator.flushPersistence()
        #expect(try inbox.pending().isEmpty)
        #expect(coordinator.tasks.count == 1)
        #expect(await backing.load().first?.status == .paused)
    }

    @Test func persistenceFailureRetainsTheShareForRetry() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ControlledTaskStore(backing: DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json")), fails: true)
        let coordinator = DownloadCoordinator(settings: AppSettings(defaults: try #require(UserDefaults(suiteName: UUID().uuidString))),
            store: store, noteStore: NoteStore(fileURL: root.appendingPathComponent("notes.json")))
        let inbox = ImportInbox(directory: root.appendingPathComponent("inbox"))
        let request = ImportRequest(text: "https://www.xiaohongshu.com/explore/failure", source: .share)
        try inbox.append(request)
        await coordinator.consume(inbox: inbox)
        #expect(try inbox.pending().map(\.id) == [request.id])
        #expect(coordinator.tasks.isEmpty)
        #expect(coordinator.alertMessage != nil)
    }

    @Test func archiveGrantSurvivesHistoryRemovalAndIsExcludedFromPortableBackup() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try #require(ArchiveGrant(bookmark: ArchiveDirectory.makeBookmark(for: root)))
        let file = root.appendingPathComponent("original.heic")
        try Data("original".utf8).write(to: file)
        var task = DownloadTaskRecord(sourceText: "", normalizedURL: "https://example.com/archive", title: "Archive", status: .completed)
        task.policy = DownloadPolicy()
        task.policy?.filesBookmark = grant.bookmark
        task.mediaAssets = [MediaAssetRecord(localIdentifier: "file:" + file.path, fileName: "original.heic", isVideo: false)]
        task.mediaAssets[0].filesPaths = [file.path]
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let notes = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        try await store.save([task])
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        let coordinator = DownloadCoordinator(settings: settings, store: store, noteStore: notes)
        await coordinator.waitUntilLoaded()
        coordinator.removeFinished()
        await coordinator.flushPersistence()
        let restored = try #require(await notes.load().first)
        #expect(restored.archiveGrants == [grant])
        let independentAccess = ArchiveAccess()
        let lease = try independentAccess.lease(paths: [file.path], grants: restored.archiveGrants ?? [])
        #expect(try Data(contentsOf: lease.urls[0]) == Data("original".utf8))
        #expect(BackupEntry.redactedNote(restored).archiveGrants == nil)
        #expect(coordinator.tasks.isEmpty)
    }

    @Test func reauthorizationResolvesOldIdentifiersInTheNewDirectory() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let new = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let grant = try #require(ArchiveGrant(bookmark: ArchiveDirectory.makeBookmark(for: old)))
        let originalPath = old.appendingPathComponent("still.heic").path
        try Data("unchanged".utf8).write(to: new.appendingPathComponent("still.heic"))
        let updated = try await ArchiveMediaLoader.shared.reauthorize(grants: [grant], paths: [originalPath], directory: new)
        let lease = try ArchiveAccess().lease(paths: [originalPath], grants: updated)
        #expect(lease.urls[0].path == new.appendingPathComponent("still.heic").path)
        #expect(try Data(contentsOf: lease.urls[0]) == Data("unchanged".utf8))
        #expect(grant.relativePath(for: old.path + "-other/still.heic") == nil)
        #expect(grant.relativePath(for: old.path + "/../escape") == nil)
        ArchiveAccess.shared.register(updated)
        let share = try await FileArchiver.shared.shareFiles(paths: [originalPath], bookmark: grant.bookmark)
        defer { try? FileManager.default.removeItem(at: share.directory) }
        #expect(try Data(contentsOf: share.urls[0]) == Data("unchanged".utf8))
    }

    @Test func missingLiveComponentFailsSharingInsteadOfSilentlyFlattening() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let still = root.appendingPathComponent("still.heic")
        try Data("still".utf8).write(to: still)
        let identifier = "file:" + still.path + "\n" + root.appendingPathComponent("missing.mov").path
        await #expect(throws: (any Error).self) { _ = try await MediaExporter.shared.export(identifiers: [identifier]) }
    }

    @Test func legacyReauthorizationFindsTheArchiveRootAboveAuthorAndNoteFolders() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let destination = root.appendingPathComponent("new")
        let relative = "Author/Note/still.heic"
        let file = destination.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: file)
        let paths = [old.appendingPathComponent(relative).path]
        let grants = try await ArchiveMediaLoader.shared.reauthorize(grants: [], paths: paths, directory: destination)
        #expect(grants.first?.rootPath == old.path)
        let lease = try ArchiveAccess().lease(paths: paths, grants: grants)
        #expect(lease.urls.first?.path == file.path)
    }

    @Test func textOnlySelectionSharesContentAndDeletesNotesWithoutPhotos() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = ["a", "b"].map {
            StoredNote(id: "note:" + $0, noteID: $0, canonicalURL: "https://example.com/" + $0,
                       title: "标题 " + $0, body: "正文 " + $0, metadata: NoteMetadata())
        }
        let cards = NoteLibrary.notes(stored: stored, media: [])
        let selection = Set(cards.map(\.id))
        #expect(NoteLibrary.selectedLinks(in: cards, noteIDs: selection).count == 2)
        let share = try await MediaExporter.shared.export(notes: cards)
        defer { try? FileManager.default.removeItem(at: share.directory) }
        #expect(share.urls.count == 2)
        #expect(try share.urls.allSatisfy { try String(contentsOf: $0, encoding: .utf8).contains("正文") })
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        try await noteStore.save(stored)
        let coordinator = DownloadCoordinator(settings: AppSettings(defaults: try #require(UserDefaults(suiteName: UUID().uuidString))),
            store: DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json")), noteStore: noteStore)
        await coordinator.waitUntilLoaded()
        try await coordinator.deleteNotes(selection, deleteMedia: true)
        #expect(coordinator.notes.isEmpty)
        #expect(await noteStore.load().isEmpty)
    }

    @Test func partialRestorePublishesOnlySavedNotesAndLeavesPreferencesForRetry() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let backing = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let store = ControlledTaskStore(backing: backing, fails: true)
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        let coordinator = DownloadCoordinator(settings: settings, store: store, noteStore: noteStore)
        await coordinator.waitUntilLoaded()
        let note = StoredNote(id: "note:restore", noteID: "restore", canonicalURL: "https://example.com/restore",
                              title: "恢复的笔记", body: "已落盘正文", metadata: NoteMetadata())
        var preferences = coordinator.exportSettingsSnapshot()
        preferences.haptics = !settings.haptics
        let task = DownloadTaskRecord(sourceText: "", normalizedURL: note.canonicalURL, title: note.title, status: .completed)
        await #expect(throws: BackupError.self) {
            _ = try await coordinator.applyBackup(BackupDocument(tasks: [BackupEntry.make(from: task)], notes: [note],
                bookmarkedNotes: [note.id], settings: preferences))
        }
        #expect(coordinator.notes.first(where: { $0.id == note.id })?.body == note.body)
        #expect(await noteStore.load().contains(where: { $0.id == note.id }))
        #expect(coordinator.tasks.isEmpty)
        #expect(coordinator.bookmarkedNotes.isEmpty)
        #expect(settings.haptics != preferences.haptics)
    }

    @Test func historyRemovedWhileRestoreIsSavingDoesNotReappearOrOverwriteRestoredText() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let backing = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        var task = DownloadTaskRecord(sourceText: "", normalizedURL: "https://example.com/race", title: "Old", noteText: "Old body", status: .completed)
        task.noteKey = "note:race"
        try await backing.save([task])
        let store = ControlledTaskStore(backing: backing)
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        var note = StoredNote(id: "note:race", noteID: "race", canonicalURL: task.normalizedURL,
            title: task.title, body: task.noteText, metadata: NoteMetadata())
        try await noteStore.save([note])
        let coordinator = DownloadCoordinator(settings: AppSettings(defaults: try #require(UserDefaults(suiteName: UUID().uuidString))),
            store: store, noteStore: noteStore)
        await coordinator.waitUntilLoaded()
        note.body = "Restored body"
        let incoming = note
        let restore = Task { try await coordinator.applyBackup(BackupDocument(notes: [incoming])) }
        while !(await store.isWaiting) { await Task.yield() }
        coordinator.removeFinished()
        await store.release()
        _ = try await restore.value
        await coordinator.flushPersistence()
        #expect(coordinator.tasks.isEmpty)
        #expect(await backing.load().isEmpty)
        #expect(await noteStore.load().first?.body == incoming.body)
    }

    @Test func importedCapabilitiesAreIgnoredAndRenewedLocalGrantWinsAtRestart() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let renewed = root.appendingPathComponent("renewed")
        for directory in [old, renewed] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let original = try #require(ArchiveGrant(bookmark: ArchiveDirectory.makeBookmark(for: old)))
        var current = original
        current.bookmark = try ArchiveDirectory.makeBookmark(for: renewed)
        let path = old.appendingPathComponent("original.heic").path
        try Data("original".utf8).write(to: renewed.appendingPathComponent("original.heic"))
        var task = DownloadTaskRecord(sourceText: "", normalizedURL: "https://example.com/archive", title: "Archive", status: .completed)
        task.noteKey = "note:archive"
        task.policy = DownloadPolicy()
        task.policy?.filesBookmark = original.bookmark
        let asset = MediaAssetRecord(localIdentifier: "file:" + path, fileName: "original.heic", isVideo: false)
        let local = StoredNote(id: "note:archive", noteID: "archive", canonicalURL: task.normalizedURL,
            title: "Archive", body: "Original", metadata: NoteMetadata(), mediaAssets: [asset], archiveGrants: [current])
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        try await store.save([task])
        try await noteStore.save([local])
        let coordinator = DownloadCoordinator(settings: AppSettings(defaults: try #require(UserDefaults(suiteName: UUID().uuidString))),
            store: store, noteStore: noteStore)
        await coordinator.waitUntilLoaded()
        #expect(coordinator.notes.first?.archiveGrants == [current])
        var incoming = local
        incoming.archiveGrants = [original]
        incoming.archiveTextPaths = [root.appendingPathComponent("private.txt").path]
        incoming.mediaAssets.append(MediaAssetRecord(localIdentifier: "file:/external/secret.heic", fileName: "secret", isVideo: false))
        var newNote = incoming
        newNote.id = "note:new"
        _ = try await coordinator.applyBackup(BackupDocument(notes: [incoming, newNote]))
        let restored = try #require(coordinator.notes.first { $0.id == local.id })
        #expect(restored.archiveGrants == [current])
        #expect(restored.archiveTextPaths.isEmpty)
        #expect(restored.mediaAssets.count == 1)
        let portable = try #require(coordinator.notes.first { $0.id == newNote.id })
        #expect(portable.archiveGrants == nil && portable.archivePaths.isEmpty)
        let lease = try ArchiveAccess.shared.lease(paths: [path])
        #expect(try Data(contentsOf: lease.urls[0]) == Data("original".utf8))
    }

    @Test func bothDestinationFallsBackToArchiveWhenPhotosAreUnavailable() throws {
        var record = MediaAssetRecord(localIdentifier: "unavailable-photo", fileName: "still.heic", isVideo: false)
        record.filesPaths = ["/archive/still.heic", "/archive/motion.mov"]
        record.isLive = true
        let media = try #require(LibraryMedia(record: record, lookup: [:]))
        #expect(media.id == "file:/archive/still.heic\n/archive/motion.mov")
        #expect(media.isLive)
    }

    @Test func portableURLKeysDropTokensWithoutDuplicatingNotesOrLosingMembership() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let signed = "https://www.xiaohongshu.com/explore/legacy?xsec_token=SECRET"
        let key = "url:" + signed
        var task = DownloadTaskRecord(sourceText: "", normalizedURL: signed, title: "Legacy", noteText: "Original", status: .completed)
        task.noteKey = key
        let note = StoredNote(id: key, noteID: nil, canonicalURL: signed, title: "Legacy", body: "Original", metadata: NoteMetadata())
        var library = BackupService.BackupLibraryPayload()
        library.notes = [note]
        library.likedNotes = [key]
        library.bookmarkedNotes = [key]
        library.collections = [NoteCollection(name: "Saved", noteIDs: [key])]
        let file = try await BackupService.shared.exportJSON(tasks: [task], library: library)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("SECRET"))
        let document = try await BackupService.shared.importBackup(from: file)
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        try await store.save([task])
        try await noteStore.save([note])
        let coordinator = DownloadCoordinator(settings: AppSettings(defaults: try #require(UserDefaults(suiteName: UUID().uuidString))),
            store: store, noteStore: noteStore)
        await coordinator.waitUntilLoaded()
        _ = try await coordinator.applyBackup(document)
        _ = try await coordinator.applyBackup(document)
        #expect(coordinator.notes.count == 1 && coordinator.tasks.count == 1)
        #expect(coordinator.likedNotes == [key])
        #expect(coordinator.bookmarkedNotes == [key])
        #expect(coordinator.collections.first?.noteIDs == [key])
    }

    @Test func partialDeletionKeepsFailedArchiveAndRemovesOnlySuccessfulReferences() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("removable.heic")
        try Data("original".utf8).write(to: file)
        let goodID = "file:" + file.path
        let badID = "file:/ungranted-archive/keep.heic"
        let note = StoredNote(id: "note:partial", noteID: "partial", canonicalURL: "https://example.com/partial",
            title: "保留笔记", body: "正文", metadata: NoteMetadata(), mediaAssets: [goodID, badID].map {
                MediaAssetRecord(localIdentifier: $0, fileName: "still.heic", isVideo: false)
            })
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        try await noteStore.save([note])
        let coordinator = DownloadCoordinator(settings: AppSettings(defaults: try #require(UserDefaults(suiteName: UUID().uuidString))),
            store: DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json")), noteStore: noteStore)
        await coordinator.waitUntilLoaded()
        await #expect(throws: MediaDeletionFailure.self) { try await coordinator.deleteNotes([note.id], deleteMedia: true) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(coordinator.notes.first?.mediaAssets.map(\.localIdentifier) == [badID])
        #expect(await noteStore.load().first?.mediaAssets.map(\.localIdentifier) == [badID])
    }

    @Test func fileThumbnailIsBoundedAndLiveControllerStartsMuted() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = Bundle(for: ContinuationFixtureBundle.self)
        let still = try #require(bundle.url(forResource: "livephoto-original", withExtension: "heic"))
        let motion = try #require(bundle.url(forResource: "livephoto-motion", withExtension: "mp4"))
        let copiedStill = root.appendingPathComponent("still.heic")
        let copiedMotion = root.appendingPathComponent("motion.mp4")
        try FileManager.default.copyItem(at: still, to: copiedStill)
        try FileManager.default.copyItem(at: motion, to: copiedMotion)
        // Component order must not turn an archived Live Photo into a video.
        let id = "file:" + copiedMotion.path + "\n" + copiedStill.path
        let thumbnail = try await ArchiveMediaLoader.shared.image(identifier: id, thumbnail: true)
        #expect(max(thumbnail.size.width, thumbnail.size.height) <= 600)
        let original = try await ArchiveMediaLoader.shared.image(identifier: id, thumbnail: false)
        #expect(max(original.size.width, original.size.height) > 600)
        let controller = PhotosMediaController(identifier: id, initialImage: original, backgroundColor: .black,
            onOpen: nil, canvasIdentifier: "file-live-canvas", heroGeometry: nil, cardGeometry: nil, cardID: nil)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        controller.setActive(true)
        defer { controller.stop() }
        let deadline = Date().addingTimeInterval(5)
        while !controller.view.subviews.contains(where: { $0.accessibilityIdentifier == "media-live-sound" }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        controller.view.layoutIfNeeded()
        let sound = try #require(controller.view.subviews.first { $0.accessibilityIdentifier == "media-live-sound" } as? UIButton)
        #expect(sound.accessibilityValue == L10n.text("viewer.live.muted"))
        sound.sendActions(for: .touchUpInside)
        #expect(sound.accessibilityValue == L10n.text("viewer.live.audible"))
        let canvas = try #require(controller.view.subviews.first { $0.accessibilityIdentifier == "file-live-canvas" } as? UIScrollView)
        #expect(canvas.contentSize.width > 0 && canvas.contentSize.height > 0)
        let layer = try #require(canvas.subviews.flatMap { $0.layer.sublayers ?? [] }.compactMap { $0 as? AVPlayerLayer }.first)
        #expect(layer.isHidden && layer.player?.rate == 0)
        #expect(layer.player?.isMuted == false)
        controller.stop()
        #expect(layer.player == nil)
    }
}

private final class ContinuationFixtureBundle: NSObject {}

private actor ControlledTaskStore: DownloadTaskStoring {
    nonisolated let fileURL: URL
    let backing: DownloadTaskStore
    let fails: Bool
    var loadError: String? { nil }
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    init(backing: DownloadTaskStore, fails: Bool = false) {
        self.fileURL = backing.fileURL
        self.backing = backing
        self.fails = fails
    }
    func load() async -> [DownloadTaskRecord] { await backing.load() }
    func save(_ tasks: [DownloadTaskRecord]) async throws {
        if fails { throw CocoaError(.fileWriteNoPermission) }
        if !held {
            held = true
            await withCheckedContinuation { continuation = $0 }
        }
        try await backing.save(tasks)
    }
    func release() { continuation?.resume(); continuation = nil }
}
