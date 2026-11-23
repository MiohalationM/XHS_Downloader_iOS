import Foundation
import JavaScriptCore
import Photos
import Testing
@testable import XHS_Downloader_iOS

@MainActor
struct ReviewRegressionTests {
    private func note(_ title: String) -> StoredNote {
        StoredNote(id: "note:review", noteID: "review", canonicalURL: "https://www.xiaohongshu.com/explore/review",
                   title: title, body: "正文", metadata: NoteMetadata(userName: "作者"))
    }

    @Test func rollingBackupRestoresThePreviousSaveInsteadOfTheFirstSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url)
        try await store.save([note("first")])
        try await store.save([note("second")])
        try await store.save([note("third")])
        try Data("broken".utf8).write(to: url)
        let recovered = NoteStore(fileURL: url)
        #expect(await recovered.load().first?.title == "second")
        #expect(await recovered.loadError != nil)
        try await recovered.save([note("recovered")])
        #expect(await NoteStore(fileURL: url).load().first?.title == "recovered")
    }

    @Test func corruptLibraryWithoutBackupCannotBeOverwrittenByAnEmptySave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.json")
        let original = Data("unreadable but potentially recoverable".utf8)
        try original.write(to: url)
        let store = NoteStore(fileURL: url)
        #expect(await store.load().isEmpty)
        await #expect(throws: CocoaError.self) { try await store.save([]) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test(arguments: [true, false])
    func cancellingPhotosDeletionKeepsTheTaskNotePreferencesAndArchivedFile(deleteNote: Bool) async throws {
        let fixture = try await DeletionFixture(cancels: true)
        defer { fixture.cleanUp() }
        fixture.coordinator.toggleLike(noteID: fixture.noteID)
        let collection = try #require(fixture.coordinator.createCollection(named: "收藏夹"))
        fixture.coordinator.setMembership([fixture.noteID], in: collection.id, included: true)
        if deleteNote {
            await fixture.coordinator.deleteNote(fixture.noteID, deletePhotos: true)
        } else {
            await fixture.coordinator.deleteTask(taskID: fixture.taskID, deletePhotos: true)
        }
        #expect(fixture.coordinator.tasks.count == 1)
        #expect(fixture.coordinator.tasks.first?.status == .completed)
        #expect(fixture.coordinator.notes.first?.mediaAssets.count == 1)
        #expect(fixture.coordinator.likedNotes.contains(fixture.noteID))
        #expect(fixture.coordinator.collections.first?.noteIDs.contains(fixture.noteID) == true)
        #expect(fixture.coordinator.alertMessage == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test func deletingTaskPhotosKeepsTheArchivedOriginalInTheDurableNote() async throws {
        let fixture = try await DeletionFixture(cancels: false)
        defer { fixture.cleanUp() }
        await fixture.coordinator.deleteTask(taskID: fixture.taskID, deletePhotos: true)
        #expect(fixture.coordinator.tasks.isEmpty)
        #expect(fixture.coordinator.notes.count == 1)
        #expect(fixture.coordinator.notes.first?.mediaAssets.first?.localIdentifier == "file:" + fixture.file.path)
        #expect(fixture.coordinator.notes.first?.body == "正文")
    }

    @Test func deletingNoteCleansUpLikesBookmarksAndCollectionMembership() async throws {
        let fixture = try await DeletionFixture(cancels: false)
        defer { fixture.cleanUp() }
        fixture.coordinator.toggleLike(noteID: fixture.noteID)
        fixture.coordinator.toggleBookmark(noteID: fixture.noteID)
        let collection = try #require(fixture.coordinator.createCollection(named: "收藏夹"))
        fixture.coordinator.setMembership([fixture.noteID], in: collection.id, included: true)
        await fixture.coordinator.deleteNote(fixture.noteID, deletePhotos: false)
        #expect(fixture.coordinator.tasks.isEmpty && fixture.coordinator.notes.isEmpty)
        #expect(fixture.coordinator.likedNotes.isEmpty && fixture.coordinator.bookmarkedNotes.isEmpty)
        #expect(fixture.coordinator.collections.first?.noteIDs.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test func restoredNoteTextWinsOverAnOlderLocalTaskSnapshot() async throws {
        let fixture = try await DeletionFixture(cancels: false)
        defer { fixture.cleanUp() }
        var restored = note("备份标题")
        restored.body = "备份正文"
        _ = try await fixture.coordinator.applyBackup(BackupDocument(notes: [restored]))
        #expect(fixture.coordinator.notes.first?.body == "备份正文")
        #expect(fixture.coordinator.notes.first?.title == "备份标题")
        #expect(fixture.coordinator.notes.first?.mediaAssets.count == 1)
        fixture.coordinator.removeFinished()
        await fixture.coordinator.flushPersistence()
        #expect(fixture.coordinator.notes.first?.body == "备份正文")
    }

    @Test func importReportsPersistenceFailureInsteadOfSuccess() async throws {
        let fixture = try await DeletionFixture(cancels: false)
        defer { fixture.cleanUp() }
        let notePath = fixture.root.appendingPathComponent("notes.json")
        try Data("broken".utf8).write(to: notePath)
        let backupPath = fixture.root.appendingPathComponent("notes.backup.json")
        if FileManager.default.fileExists(atPath: backupPath.path) { try FileManager.default.removeItem(at: backupPath) }
        let originalNotes = fixture.coordinator.notes
        let originalTasks = fixture.coordinator.tasks
        let originalAppearance = fixture.coordinator.settings.appearance
        var settings = fixture.coordinator.exportSettingsSnapshot()
        settings.appearance = "dark"
        await #expect(throws: CocoaError.self) {
            _ = try await fixture.coordinator.applyBackup(BackupDocument(notes: [note("新标题")], likedNotes: ["restored"], settings: settings))
        }
        #expect(try Data(contentsOf: notePath) == Data("broken".utf8))
        #expect(fixture.coordinator.notes == originalNotes)
        #expect(fixture.coordinator.tasks == originalTasks)
        #expect(fixture.coordinator.likedNotes.isEmpty)
        #expect(fixture.coordinator.settings.appearance == originalAppearance)
    }

    @Test func browserDoesNotTreatExternalURLsQueryStringsOrIDPrefixesAsNotes() async throws {
        let id = "0123456789abcdef01234567"
        for text in [
            "https://example.com/explore/\(id)",
            "https://www.xiaohongshu.com/?redirect=/explore/\(id)",
            "https://www.xiaohongshu.com/explore/\(id)extra",
            "https://www.xiaohongshu.com/explore/\(id)/another"
        ] {
            #expect(BrowserModel.noteID(from: try #require(URL(string: text))) == nil)
        }
        #expect(BrowserModel.noteID(from: try #require(URL(string: "https://www.rednote.com/explore/\(id)?xsec_token=t"))) == id)
        #expect(BrowserModel.normalizedURL("httpx://example.com") == nil)
        #expect(BrowserModel.normalizedURL("file:///tmp/note") == nil)
    }

    @Test func invalidProxyFailsBeforeMakingANetworkRequest() async throws {
        var policy = DownloadPolicy()
        policy.proxy = "http://user:pass@example.com:8080"
        let downloader = XHSDownloader(policy: policy)
        await #expect(throws: ProxyConfigurationError.self) {
            _ = try await downloader.resolveNote(from: "https://www.xiaohongshu.com/explore/review")
        }
        let directMedia = try NetworkPolicy.configuration(policy, media: true)
        #expect(directMedia.proxyConfigurations.isEmpty)
        policy.proxyMedia = true
        #expect(throws: ProxyConfigurationError.self) { _ = try NetworkPolicy.configuration(policy, media: true) }
    }

    @Test func browserCapturesOnlyTheRequestedNoteWhenRecommendationsArePresent() async throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var window = {__INITIAL_STATE__: {note: {noteDetailMap: {
          recommended: {note: {noteId: "other", desc: "wrong"}}
        }}}};
        """)
        let script = BrowserModel.noteCaptureScript(noteID: "target")
        #expect(try #require(context.evaluateScript(script)).isNull)
        context.evaluateScript("""
        window.__INITIAL_STATE__.note.noteDetailMap.target = {note: {noteId:"other",desc:"wrong"}};
        """)
        #expect(try #require(context.evaluateScript(script)).isNull)
        context.evaluateScript("""
        window.__INITIAL_STATE__.note.noteDetailMap.alias = {note:{noteId:"target",desc:"correct"}};
        """)
        let captured = try #require(context.evaluateScript(script)?.toString())
        let data = try #require(captured.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["note"] as? [String: Any])?["desc"] as? String == "correct")
        #expect(context.exception == nil)
    }
}

private struct ReviewPhotos: PhotoLibraryServing {
    let cancels: Bool
    func deleteAssets(localIdentifiers: [String]) async throws {
        if cancels { throw NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue) }
    }
    func saveMedia(at fileURL: URL, isVideo: Bool, originalFilename: String?, creationDate: Date?) async throws -> String {
        throw PhotoLibraryError.saveFailed
    }
    func saveLivePhoto(photoURL: URL, pairedVideoURL: URL, originalFilename: String?, creationDate: Date?) async throws -> String {
        throw PhotoLibraryError.saveFailed
    }
}

@MainActor
private struct DeletionFixture {
    let root: URL
    let file: URL
    let defaultsName = UUID().uuidString
    let coordinator: DownloadCoordinator
    let taskID: UUID
    let noteID = "note:review"

    init(cancels: Bool) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("original.heic")
        try Data("original".utf8).write(to: file)
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        var task = DownloadTaskRecord(sourceText: "share", normalizedURL: "https://www.xiaohongshu.com/explore/review",
                                      title: "标题", noteText: "正文", status: .completed)
        taskID = task.id
        task.noteKey = noteID
        task.mediaAssets = [MediaAssetRecord(localIdentifier: "review-photo", fileName: "original.heic", isVideo: false)]
        task.mediaAssets[0].filesPaths = [file.path]
        try await store.save([task])
        coordinator = DownloadCoordinator(settings: AppSettings(defaults: defaults), store: store,
            noteStore: NoteStore(fileURL: root.appendingPathComponent("notes.json")), photoLibrary: ReviewPhotos(cancels: cancels))
        await coordinator.waitUntilLoaded()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
}
