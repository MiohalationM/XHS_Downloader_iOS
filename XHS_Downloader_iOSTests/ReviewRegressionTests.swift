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

    @Test func pureSwiftInitialStateParserHandlesUndefinedStringsAndTrailingStatements() throws {
        let html = """
        <script>
        window.__INITIAL_STATE__={"note":{"noteDetailMap":{"abc123":{"note":{
          "noteId":"abc123",
          "title":"Hello } \\"world\\" : undefined",
          "desc":"body",
          "time":undefined,
          "tags":[undefined,"ok"]
        }}}}};window.__OTHER__={"ignored":true};
        </script>
        """
        let downloader = XHSDownloader()
        let script = try #require(downloader.extractInitialStateScript(from: html))
        let parsed = try #require(downloader.evaluateInitialStateScript(script))
        let noteMap = ((parsed["note"] as? [String: Any])?["noteDetailMap"] as? [String: Any])
        let entry = (noteMap?["abc123"] as? [String: Any])?["note"] as? [String: Any]
        #expect(entry?["noteId"] as? String == "abc123")
        #expect(entry?["title"] as? String == #"Hello } "world" : undefined"#)
        #expect(entry?["time"] is NSNull)
        #expect((entry?["tags"] as? [Any])?.count == 2)
    }

    @Test func importInboxSurvivesCorruptPoisonPillFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inbox = ImportInbox(directory: root)
        let corruptURL = root.appendingPathComponent("corrupt.json")
        try Data("{not-valid-json".utf8).write(to: corruptURL)
        let valid = ImportRequest(text: "https://www.xiaohongshu.com/explore/0123456789abcdef01234567", source: .share)
        try inbox.append(valid)

        let pending = try inbox.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.id == valid.id)
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))
    }

    @Test func importLinkPatternDoesNotSwallowAdjacentChineseOrEmoji() {
        let text = "快来看这篇笔记 http://xhslink.com/a/abc123复制本条信息打开小红书🔥"
        #expect(ImportText.linkCount(in: text) == 1)
        let links = XHSURLDetector.extract(from: text)
        #expect(links == ["http://xhslink.com/a/abc123"])
    }

    @Test func namingFormatterBoundsUTF8BytesForLongCJKTitles() {
        let longTitle = String(repeating: "红", count: 120)
        let metadata = NoteMetadata(userName: String(repeating: "作", count: 60), userId: "uid1", title: longTitle)
        let preferences = NamingPreferences(enabled: true, template: "{username}_{title}_{postId}", timeZone: .current)
        let baseName = NamingFormatter.makeBaseName(
            metadata: metadata,
            fallbackPostId: "65f0000000000000000000aa",
            index: 1,
            downloadEpochSeconds: 1_762_560_000,
            preferences: preferences
        )
        #expect(baseName.utf8.count <= 180)
        #expect(!baseName.hasPrefix("."))
    }

    @Test func deletingNoteKeepingMediaHidesAssetsFromReappearingAsOrphanCards() async throws {
        let photos = RecordingPhotos()
        let fixture = try await DeletionFixture(cancels: false, photoLibrary: photos)
        defer { fixture.cleanUp() }
        await fixture.coordinator.deleteNote(fixture.noteID, deletePhotos: false)
        #expect(fixture.coordinator.notes.isEmpty)
        #expect(fixture.coordinator.hiddenMediaIDs.contains("review-photo"))
        #expect(photos.removedFromAlbum.contains("review-photo"))
        let feed = NoteLibrary.notes(
            stored: fixture.coordinator.notes,
            media: [LibraryMedia(id: "review-photo"), LibraryMedia(id: "other-photo")],
            hiddenMediaIDs: fixture.coordinator.hiddenMediaIDs
        )
        #expect(feed.map(\.identifiers) == [["other-photo"]])
    }

    @Test func heroTransitionsSupportRubberBandClampedResumeAndViewportVisibility() {
        let damped = NoteHeroDragGeometry.rubberBand(-120, limit: 80)
        #expect(damped < 0 && damped > -80)
        // Clamped scale (0.65) and Reduce Motion still resume with exact pointer delta.
        let resumed = NoteHeroDragGeometry.resumedTranslation(
            frame: CGRect(x: 240, y: 260, width: 260, height: 260),
            expanded: CGRect(x: 0, y: 200, width: 400, height: 400),
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800),
            anchor: CGPoint(x: 200, y: 400),
            horizontal: true
        )
        #expect(abs(resumed.x - 170) < 0.001)
        #expect(abs(resumed.y - (-10)) < 0.001)
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        let offscreen = CGRect(x: 16, y: 920, width: 180, height: 40)
        let onscreen = CGRect(x: 16, y: 240, width: 180, height: 40)
        #expect(!NoteHeroTitleVisibility.canTransfer(source: offscreen, destination: onscreen, text: "标题", viewport: viewport))
        #expect(!NoteHeroTitleVisibility.canTransfer(source: onscreen, destination: offscreen, text: "标题", viewport: viewport))
        #expect(NoteHeroTitleVisibility.canTransfer(source: onscreen, destination: onscreen, text: "标题", viewport: viewport))
    }

    @Test func zipArchiveWritesNonZeroDOSTimestampsInCentralDirectory() async throws {
        let note = StoredNote(id: "note:zip", noteID: "zip", canonicalURL: "https://www.xiaohongshu.com/explore/zip",
                              title: "测试", body: "正文内容", metadata: NoteMetadata(userName: "作者"))
        let archive = try await BackupService.shared.exportArchive([note])
        defer { try? FileManager.default.removeItem(at: archive.url.deletingLastPathComponent()) }
        let bytes = try Data(contentsOf: archive.url)
        let cdSig = Data([0x50, 0x4B, 0x01, 0x02])
        let range = try #require(bytes.range(of: cdSig))
        let start = range.lowerBound
        let dosTime = UInt16(bytes[start + 12]) | (UInt16(bytes[start + 13]) << 8)
        let dosDate = UInt16(bytes[start + 14]) | (UInt16(bytes[start + 15]) << 8)
        #expect(dosDate != 0)
        #expect(dosTime != 0 || dosDate != 0)
    }

    @Test func versionComparisonHandlesPrereleaseSuffixes() {
        #expect(SettingsView.isVersion("1.10.0", newerThan: "1.9.0"))
        #expect(SettingsView.isVersion("1.0.0", newerThan: "1.0.0-beta.1"))
        #expect(!SettingsView.isVersion("1.0.0-beta.1", newerThan: "1.0.0"))
        #expect(SettingsView.isVersion("1.0.0-beta.2", newerThan: "1.0.0-beta.1"))
        #expect(!SettingsView.isVersion("1.0", newerThan: "1.0.0"))
    }

    @Test func deletingNoteProtectsSharedAndReusedArchiveFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedFile = root.appendingPathComponent("shared.heic")
        let reusedFile = root.appendingPathComponent("user-original.heic")
        let ownedFile = root.appendingPathComponent("owned.heic")
        try Data("shared".utf8).write(to: sharedFile)
        try Data("reused".utf8).write(to: reusedFile)
        try Data("owned".utf8).write(to: ownedFile)
        let grant = try #require(ArchiveGrant(bookmark: try ArchiveDirectory.makeBookmark(for: root)))

        var sharedAsset = MediaAssetRecord(localIdentifier: "file:" + sharedFile.path, fileName: "shared.heic", isVideo: false)
        sharedAsset.filesPaths = [sharedFile.path]
        var reusedAsset = MediaAssetRecord(localIdentifier: "file:" + reusedFile.path, fileName: "user-original.heic", isVideo: false)
        reusedAsset.filesPaths = [reusedFile.path]
        reusedAsset.reusedFilesPaths = [reusedFile.path]
        var ownedAsset = MediaAssetRecord(localIdentifier: "file:" + ownedFile.path, fileName: "owned.heic", isVideo: false)
        ownedAsset.filesPaths = [ownedFile.path]

        let noteA = StoredNote(id: "note:a", noteID: "a", canonicalURL: "https://www.xiaohongshu.com/explore/a",
                               title: "A", body: "A", metadata: NoteMetadata(),
                               mediaAssets: [sharedAsset], archiveGrants: [grant])
        let noteB = StoredNote(id: "note:b", noteID: "b", canonicalURL: "https://www.xiaohongshu.com/explore/b",
                               title: "B", body: "B", metadata: NoteMetadata(),
                               mediaAssets: [sharedAsset, reusedAsset, ownedAsset], archiveGrants: [grant])

        let defaultsName = UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        try await noteStore.save([noteA, noteB])
        let coordinator = DownloadCoordinator(
            settings: AppSettings(defaults: defaults),
            store: DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json")),
            noteStore: noteStore,
            photoLibrary: ReviewPhotos(cancels: false)
        )
        await coordinator.waitUntilLoaded()

        await coordinator.deleteNote("note:b", deletePhotos: true)
        #expect(coordinator.notes.map(\.id) == ["note:a"])
        #expect(FileManager.default.fileExists(atPath: sharedFile.path), "shared file still referenced by note A must survive")
        #expect(FileManager.default.fileExists(atPath: reusedFile.path), "reused pre-existing file must never be unlinked")
        #expect(!FileManager.default.fileExists(atPath: ownedFile.path), "solely-owned created file should be removed")
    }

    @Test func livePhotoDualDestinationRetryPreservesMotionFileAndZipExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archiveRoot = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultsName = UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        var policy = DownloadPolicy()
        policy.destination = .both
        policy.requestInterval = 0
        policy.filesBookmark = try ArchiveDirectory.makeBookmark(for: archiveRoot)
        policy.save(defaults: defaults)
        let settings = AppSettings(defaults: defaults)
        settings.livePhotoMode = .merged

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DualRetryLiveProtocol.self]
        let flakyPhotos = FlakyLivePhotos()
        let coordinator = DownloadCoordinator(
            settings: settings,
            store: DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json")),
            noteStore: NoteStore(fileURL: root.appendingPathComponent("notes.json")),
            downloader: XHSDownloader(session: URLSession(configuration: config), policy: policy),
            photoLibrary: flakyPhotos
        )
        await coordinator.waitUntilLoaded()

        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/dualretry", behavior: .direct).value
        let deadline1 = Date().addingTimeInterval(10)
        while Date() < deadline1, coordinator.tasks.contains(where: { [.queued, .downloading].contains($0.status) }) {
            try await Task.sleep(for: .milliseconds(30))
        }
        let firstPass = try #require(coordinator.tasks.first)
        #expect(firstPass.status == .partial)
        #expect(firstPass.errorMessage == L10n.text("error.partial_files_saved_photos_failed"))
        let filesResult = try #require(firstPass.resourceResults?.values.first?.files)
        #expect(filesResult.isSettled)
        #expect(filesResult.allReferences.count == 2, "both still and motion archive paths must be persisted before retry")

        // Now allow Photos save to succeed and retry the failed Photos half.
        flakyPhotos.shouldFail = false
        coordinator.retryFailedResources(taskID: firstPass.id)
        let deadline2 = Date().addingTimeInterval(10)
        while Date() < deadline2, coordinator.tasks.contains(where: { [.queued, .downloading].contains($0.status) }) {
            try await Task.sleep(for: .milliseconds(30))
        }
        let finished = try #require(coordinator.tasks.first)
        #expect(finished.status == .completed, "retry error: \(finished.errorMessage ?? "none")")
        let asset = try #require(finished.mediaAssets.first)
        #expect(asset.isLive == true)
        #expect(asset.filesPaths?.count == 2, "retried Live Photo must retain both still and motion paths")
        for path in asset.filesPaths ?? [] {
            #expect(FileManager.default.fileExists(atPath: path))
        }
        let exported = try await BackupService.shared.exportArchive(coordinator.notes)
        defer { try? FileManager.default.removeItem(at: exported.url.deletingLastPathComponent()) }
        #expect(exported.failures.isEmpty, "ZIP export must include both Live Photo components without failure")
    }

    @Test func coldLaunchResumesTasksWithLiveBackgroundTransfersInsteadOfPausing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultsName = UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let url = URL(string: "https://media.example/live-bg.png")!
        let media = RemoteMedia(stableID: "bg:image:0", url: url, type: .image, fileBaseName: "bg_01", originalURLString: url.absoluteString)
        let note = ResolvedNote(noteID: "bg", canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/bg")!,
                                title: "BG", body: "Body", metadata: NoteMetadata(), media: [media])

        var resumable = DownloadTaskRecord(sourceText: "", normalizedURL: note.canonicalURL.absoluteString, status: .downloading, progress: 0.5)
        resumable.resolvedNote = note
        var policy = DownloadPolicy()
        policy.destination = .files
        policy.filesBookmark = try ArchiveDirectory.makeBookmark(for: root)
        policy.requestInterval = 0
        resumable.policy = policy

        let orphan = DownloadTaskRecord(sourceText: "", normalizedURL: "https://www.xiaohongshu.com/explore/orphan", status: .downloading, progress: 0.3)

        let expectedKey = BackgroundTransfers.transferKey(identity: resumable.id.uuidString + ":" + media.stableID, url: url)
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        try await store.save([resumable, orphan])

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DualRetryLiveProtocol.self]
        let coordinator = DownloadCoordinator(
            settings: AppSettings(defaults: defaults),
            store: store,
            noteStore: NoteStore(fileURL: root.appendingPathComponent("notes.json")),
            downloader: XHSDownloader(session: URLSession(configuration: config), policy: policy),
            photoLibrary: ReviewPhotos(cancels: false),
            activeBackgroundKeys: { [expectedKey] }
        )
        await coordinator.waitUntilLoaded()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, coordinator.tasks.contains(where: { $0.id == resumable.id && [.queued, .downloading].contains($0.status) }) {
            try await Task.sleep(for: .milliseconds(30))
        }

        let resumedState = try #require(coordinator.tasks.first { $0.id == resumable.id })
        let orphanState = try #require(coordinator.tasks.first { $0.id == orphan.id })
        #expect(resumedState.status == .completed, "task matching live background transfer must auto-resume, not pause")
        #expect(orphanState.status == .paused)
        #expect(orphanState.errorMessage == L10n.text("error.interrupted"))
    }

    @Test func shareExtensionAndAppAgreeOnCaseSensitiveLinksAndPunctuation() {
        let caseSample = "https://xhslink.com/a/AbC https://xhslink.com/a/abc"
        #expect(ImportText.linkCount(in: caseSample) == 2)
        #expect(XHSURLDetector.extract(from: caseSample).count == 2)
        #expect(ImportText.extractLinks(from: caseSample) == XHSURLDetector.extract(from: caseSample))

        let punctuationSample = "https://xhslink.com/a/abc (https://xhslink.com/a/abc) [https://xhslink.com/a/abc]."
        #expect(ImportText.linkCount(in: punctuationSample) == 1)
        #expect(XHSURLDetector.extract(from: punctuationSample) == ["https://xhslink.com/a/abc"])
    }

    @Test func clipboardDefaultsOffAndCDNsUpgradeToHTTPS() throws {
        let suite = UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(settings.clipboardSuggestions == false)

        let note = try XHSDownloader().resolveNote(
            data: ["noteId": "https1", "title": "T", "desc": "D",
                   "imageList": [["urlDefault": "http://sns-img-bd.xhscdn.com/sample-key"]]],
            noteID: "https1",
            canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/https1")!
        )
        let first = try #require(note.media.first)
        #expect(first.url.scheme == "https")
        #expect(first.candidates.allSatisfy { $0.scheme == "https" })
    }

    @Test func policyFilteringAllMediaReportsFilteredWithoutDroppingNoteText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        var policy = DownloadPolicy()
        policy.images = false
        policy.videos = false
        policy.requestInterval = 0
        policy.save(defaults: defaults)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DualRetryLiveProtocol.self]
        let coordinator = DownloadCoordinator(
            settings: AppSettings(defaults: defaults),
            store: DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json")),
            noteStore: NoteStore(fileURL: root.appendingPathComponent("notes.json")),
            downloader: XHSDownloader(session: URLSession(configuration: config), policy: policy),
            photoLibrary: ReviewPhotos(cancels: false)
        )
        await coordinator.waitUntilLoaded()
        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/dualretry", behavior: .direct).value
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, coordinator.tasks.contains(where: { [.queued, .downloading].contains($0.status) }) {
            try await Task.sleep(for: .milliseconds(30))
        }
        let finished = try #require(coordinator.tasks.first)
        #expect(finished.savedCount == 0)
        #expect(finished.errorMessage == L10n.text("error.no_media_filtered"))
        #expect(coordinator.notes.first?.body == "Dual retry body")
    }

    @Test func viewerDeleteProtectsSharedAndReusedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedFile = root.appendingPathComponent("shared.heic")
        let reusedFile = root.appendingPathComponent("reused.heic")
        let ownedFile = root.appendingPathComponent("owned.heic")
        let dualFile = root.appendingPathComponent("dual.heic")
        for (file, content) in [(sharedFile, "shared"), (reusedFile, "reused"), (ownedFile, "owned"), (dualFile, "dual")] {
            try Data(content.utf8).write(to: file)
        }
        let grant = try #require(ArchiveGrant(bookmark: try ArchiveDirectory.makeBookmark(for: root)))

        var sharedAsset = MediaAssetRecord(localIdentifier: "file:" + sharedFile.path, fileName: "shared.heic", isVideo: false)
        sharedAsset.filesPaths = [sharedFile.path]
        var reusedAsset = MediaAssetRecord(localIdentifier: "file:" + reusedFile.path, fileName: "reused.heic", isVideo: false)
        reusedAsset.filesPaths = [reusedFile.path]
        reusedAsset.reusedFilesPaths = [reusedFile.path]
        var ownedAsset = MediaAssetRecord(localIdentifier: "file:" + ownedFile.path, fileName: "owned.heic", isVideo: false)
        ownedAsset.filesPaths = [ownedFile.path]
        var sharedDualAsset = MediaAssetRecord(localIdentifier: "shared-photo-id", fileName: "dual.heic", isVideo: false)
        sharedDualAsset.filesPaths = [dualFile.path]
        let solePhotoAsset = MediaAssetRecord(localIdentifier: "sole-photo-id", fileName: "sole.heic", isVideo: false)

        let noteA = StoredNote(id: "note:a", noteID: "a", canonicalURL: "https://www.xiaohongshu.com/explore/a",
                               title: "A", body: "A", metadata: NoteMetadata(),
                               mediaAssets: [sharedAsset, sharedDualAsset], archiveGrants: [grant])
        let noteB = StoredNote(id: "note:b", noteID: "b", canonicalURL: "https://www.xiaohongshu.com/explore/b",
                               title: "B", body: "B", metadata: NoteMetadata(),
                               mediaAssets: [sharedAsset, reusedAsset, ownedAsset, sharedDualAsset, solePhotoAsset],
                               archiveGrants: [grant])
        var taskB = DownloadTaskRecord(sourceText: "", normalizedURL: noteB.canonicalURL, title: "B", noteText: "B", status: .completed)
        taskB.noteKey = noteB.id
        taskB.mediaAssets = noteB.mediaAssets

        let suite = UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let taskStore = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        try await taskStore.save([taskB])
        try await noteStore.save([noteA, noteB])
        let photos = RecordingPhotos()
        let coordinator = DownloadCoordinator(
            settings: AppSettings(defaults: defaults),
            store: taskStore,
            noteStore: noteStore,
            photoLibrary: photos
        )
        await coordinator.waitUntilLoaded()

        try await coordinator.deleteMedia(
            [sharedAsset.localIdentifier, reusedAsset.localIdentifier, ownedAsset.localIdentifier,
             sharedDualAsset.localIdentifier, solePhotoAsset.localIdentifier],
            fromNoteID: "note:b"
        )

        #expect(FileManager.default.fileExists(atPath: sharedFile.path), "shared file still referenced by note A must survive")
        #expect(FileManager.default.fileExists(atPath: reusedFile.path), "reused pre-existing file must survive")
        #expect(FileManager.default.fileExists(atPath: dualFile.path), "shared dual-destination file must survive")
        #expect(!FileManager.default.fileExists(atPath: ownedFile.path), "solely-owned file must be deleted")
        #expect(photos.deletedLocalIdentifiers == ["sole-photo-id"], "shared Photos asset must not be deleted while solely-owned one is")

        let updatedA = try #require(coordinator.note(forKey: "note:a"))
        let updatedB = try #require(coordinator.note(forKey: "note:b"))
        #expect(updatedA.mediaAssets.count == 2, "note A must stay untouched")
        #expect(updatedB.mediaAssets.isEmpty, "requested media must be detached from note B")
        #expect(coordinator.tasks.first(where: { $0.id == taskB.id })?.mediaAssets.isEmpty == true)
    }

    @Test func reusedCaptionFilesSurviveNoteDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archiveRoot = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bookmark = try ArchiveDirectory.makeBookmark(for: archiveRoot)
        let grant = try #require(ArchiveGrant(bookmark: bookmark))
        var policy = DownloadPolicy()
        policy.destination = .files
        policy.captionFormat = .both
        policy.skipExisting = true
        policy.authorDirectories = false
        policy.noteDirectories = false
        policy.filesBookmark = bookmark

        let resolved = ResolvedNote(
            noteID: "cap001",
            canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/cap001")!,
            title: "Caption Reuse",
            body: "Existing caption body",
            metadata: NoteMetadata(userName: "Author"),
            media: []
        )

        let stem = FileArchiver.directoryComponent(FileArchiver.noteComponent(resolved), fallback: resolved.noteID)
        let existingTXT = archiveRoot.appendingPathComponent(stem + ".txt")
        let expectedTXTContent = await FileArchiver.shared.captionText(resolved, markdown: false)
        try expectedTXTContent.write(to: existingTXT, atomically: true, encoding: .utf8)

        let directory = try await FileArchiver.shared.prepare(note: resolved, policy: policy)
        let captionResult = try await FileArchiver.shared.archiveCaptions(note: resolved, in: directory, policy: policy)
        await FileArchiver.shared.release(directory)

        #expect(captionResult.written.count == 2)
        #expect(captionResult.reused == [existingTXT.path])
        let createdMD = try #require(captionResult.written.first { $0.hasSuffix(".md") })
        #expect(FileManager.default.fileExists(atPath: createdMD))

        let stored = StoredNote(
            id: "note:cap001",
            noteID: "cap001",
            canonicalURL: resolved.canonicalURL.absoluteString,
            title: resolved.title,
            body: resolved.body,
            metadata: resolved.metadata,
            archiveTextPaths: captionResult.written,
            archiveGrants: [grant],
            reusedArchiveTextPaths: captionResult.reused
        )
        #expect(BackupEntry.redactedNote(stored).reusedArchiveTextPaths == nil)

        let suite = UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        try await noteStore.save([stored])
        let coordinator = DownloadCoordinator(
            settings: AppSettings(defaults: defaults),
            store: DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json")),
            noteStore: noteStore,
            photoLibrary: ReviewPhotos(cancels: false)
        )
        await coordinator.waitUntilLoaded()

        await coordinator.deleteNote("note:cap001", deletePhotos: true)
        #expect(coordinator.notes.isEmpty)
        #expect(FileManager.default.fileExists(atPath: existingTXT.path), "reused pre-existing .txt caption must survive deletion")
        #expect(!FileManager.default.fileExists(atPath: createdMD), "newly written .md caption should be removed")
    }

    @Test func coldLaunchWithoutDownloadingTasksDoesNotWaitForBackgroundSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))

        let completed = DownloadTaskRecord(
            sourceText: "", normalizedURL: "https://www.xiaohongshu.com/explore/done1",
            title: "Done", noteText: "Body", status: .completed, progress: 1
        )
        let residualQueued = DownloadTaskRecord(
            sourceText: "", normalizedURL: "https://www.xiaohongshu.com/explore/queued1",
            title: "Queued", noteText: "Body", status: .queued, progress: 0
        )
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        try await store.save([completed, residualQueued])

        final class CallTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var _called = false
            var called: Bool { lock.withLock { _called } }
            func mark() { lock.withLock { _called = true } }
        }
        let tracker = CallTracker()

        let start = ContinuousClock.now
        let coordinator = DownloadCoordinator(
            settings: AppSettings(defaults: defaults),
            store: store,
            noteStore: NoteStore(fileURL: root.appendingPathComponent("notes.json")),
            photoLibrary: ReviewPhotos(cancels: false),
            activeBackgroundKeys: {
                tracker.mark()
                try? await Task.sleep(for: .seconds(60))
                return []
            }
        )
        await coordinator.waitUntilLoaded()
        let elapsed = ContinuousClock.now - start

        #expect(coordinator.isLoaded)
        #expect(elapsed < .seconds(1), "cold launch without .downloading tasks must not stall on background session")
        #expect(!tracker.called, "activeBackgroundKeys must not be queried when no task is .downloading")
        let pausedTask = try #require(coordinator.tasks.first { $0.id == residualQueued.id })
        #expect(pausedTask.status == .paused)
        #expect(pausedTask.errorMessage == L10n.text("error.interrupted"))
        #expect(coordinator.tasks.first { $0.id == completed.id }?.status == .completed)
    }

    @Test func legacySinglePathLivePhotoRetryArchivesMissingMotionWithoutDuplicatingStill() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archiveRoot = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        var policy = DownloadPolicy()
        policy.destination = .both
        policy.skipExisting = false
        policy.requestInterval = 0
        policy.filesBookmark = try ArchiveDirectory.makeBookmark(for: archiveRoot)
        policy.save(defaults: defaults)
        let settings = AppSettings(defaults: defaults)
        settings.livePhotoMode = .merged

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DualRetryLiveProtocol.self]
        let flakyPhotos = FlakyLivePhotos()
        let taskStore = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        let firstCoordinator = DownloadCoordinator(
            settings: settings,
            store: taskStore,
            noteStore: noteStore,
            downloader: XHSDownloader(session: URLSession(configuration: config), policy: policy),
            photoLibrary: flakyPhotos
        )
        await firstCoordinator.waitUntilLoaded()

        _ = await firstCoordinator.enqueue("https://www.xiaohongshu.com/explore/legacyheal", behavior: .direct).value
        let deadline1 = Date().addingTimeInterval(10)
        while Date() < deadline1, firstCoordinator.tasks.contains(where: { [.queued, .downloading].contains($0.status) }) {
            try await Task.sleep(for: .milliseconds(30))
        }
        var legacyTask = try #require(firstCoordinator.tasks.first)
        #expect(legacyTask.status == .partial)
        let resourceKey = try #require(legacyTask.resourceResults?.keys.first)
        let initialPaths = try #require(legacyTask.resourceResults?[resourceKey]?.files?.allReferences)
        #expect(initialPaths.count == 2)
        let stillPath = try #require(initialPaths.first { $0.hasSuffix(".heic") })
        let motionPath = try #require(initialPaths.first { !$0.hasSuffix(".heic") })

        // Simulate a legacy build where only the single still path was saved on
        // disk and `references` was nil.
        try FileManager.default.removeItem(atPath: motionPath)
        legacyTask.resourceResults?[resourceKey]?.files = DestinationResult(
            state: .saved, reference: stillPath, references: nil, reusedReferences: nil
        )
        try await taskStore.save([legacyTask])

        flakyPhotos.shouldFail = false
        let coordinator = DownloadCoordinator(
            settings: settings,
            store: taskStore,
            noteStore: noteStore,
            downloader: XHSDownloader(session: URLSession(configuration: config), policy: policy),
            photoLibrary: flakyPhotos
        )
        await coordinator.waitUntilLoaded()
        coordinator.retryFailedResources(taskID: legacyTask.id)
        let deadline2 = Date().addingTimeInterval(10)
        while Date() < deadline2, coordinator.tasks.contains(where: { [.queued, .downloading].contains($0.status) }) {
            try await Task.sleep(for: .milliseconds(30))
        }

        let finished = try #require(coordinator.tasks.first)
        #expect(finished.status == .completed, "retry error: \(finished.errorMessage ?? "none")")
        let asset = try #require(finished.mediaAssets.first)
        #expect(asset.isLive == true)
        #expect(asset.filesPaths?.count == 2, "healed Live Photo must carry both still and motion paths")
        #expect(asset.filesPaths?.contains(stillPath) == true, "original still path must be preserved")
        for path in asset.filesPaths ?? [] {
            #expect(FileManager.default.fileExists(atPath: path))
        }

        let noteDir = URL(fileURLWithPath: stillPath).deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(at: noteDir, includingPropertiesForKeys: nil)
        let heicFiles = contents.filter { $0.pathExtension.lowercased() == "heic" }
        let motionFiles = contents.filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
        #expect(heicFiles.count == 1, "still image must not be duplicated into _2.heic when skipExisting is false")
        #expect(motionFiles.count == 1, "missing motion component must be archived")

        let exported = try await BackupService.shared.exportArchive(coordinator.notes)
        defer { try? FileManager.default.removeItem(at: exported.url.deletingLastPathComponent()) }
        #expect(exported.failures.isEmpty, "ZIP export must succeed with 0 failures after legacy healing")
    }
}

private final class FlakyLivePhotos: PhotoLibraryServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _shouldFail = true
    var shouldFail: Bool {
        get { lock.withLock { _shouldFail } }
        set { lock.withLock { _shouldFail = newValue } }
    }
    func deleteAssets(localIdentifiers: [String]) async throws {}
    func removeAssetsFromAppAlbum(localIdentifiers: [String]) async {}
    func saveMedia(at fileURL: URL, isVideo: Bool, originalFilename: String?, creationDate: Date?) async throws -> String {
        if shouldFail { throw PhotoLibraryError.saveFailed }
        return "flaky-photo-\(UUID().uuidString)"
    }
    func saveLivePhoto(photoURL: URL, pairedVideoURL: URL, originalFilename: String?, creationDate: Date?) async throws -> String {
        if shouldFail { throw PhotoLibraryError.saveFailed }
        return "flaky-live-\(UUID().uuidString)"
    }
}

private final class DualRetryBundleMarker: NSObject {}

private final class DualRetryLiveProtocol: URLProtocol, @unchecked Sendable {
    static let heicBytes: Data = {
        guard let url = Bundle(for: DualRetryBundleMarker.self)
            .url(forResource: "livephoto-original", withExtension: "heic"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }()
    static let mp4Bytes: Data = {
        guard let url = Bundle(for: DualRetryBundleMarker.self)
            .url(forResource: "livephoto-motion", withExtension: "mp4"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.host == "media.example" {
            let isVideo = url.path.hasSuffix(".mp4")
            let data = isVideo ? Self.mp4Bytes : Self.heicBytes
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                                 headerFields: ["Content-Type": isVideo ? "video/mp4" : "image/heic",
                                                                                "Content-Length": "\(data.count)"])!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let id = url.lastPathComponent
        let html = """
        <script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"\(id)":{"note":{
          "noteId":"\(id)","title":"Dual Retry","desc":"Dual retry body",
          "imageList":[{"urlDefault":"https://media.example/\(id).heic","stream":{"h264":[{"masterUrl":"https://media.example/\(id)-motion.mp4","videoBitrate":1000}]}}]
        }}}}};</script>
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                             headerFields: ["Content-Type": "text/html"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RecordingPhotos: PhotoLibraryServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _removedFromAlbum: [String] = []
    private var _deletedLocalIdentifiers: [String] = []
    var removedFromAlbum: [String] { lock.withLock { _removedFromAlbum } }
    var deletedLocalIdentifiers: [String] { lock.withLock { _deletedLocalIdentifiers } }
    func deleteAssets(localIdentifiers: [String]) async throws {
        lock.withLock { _deletedLocalIdentifiers.append(contentsOf: localIdentifiers) }
    }
    func removeAssetsFromAppAlbum(localIdentifiers: [String]) async {
        lock.withLock { _removedFromAlbum.append(contentsOf: localIdentifiers) }
    }
    func saveMedia(at fileURL: URL, isVideo: Bool, originalFilename: String?, creationDate: Date?) async throws -> String {
        throw PhotoLibraryError.saveFailed
    }
    func saveLivePhoto(photoURL: URL, pairedVideoURL: URL, originalFilename: String?, creationDate: Date?) async throws -> String {
        throw PhotoLibraryError.saveFailed
    }
}

private struct ReviewPhotos: PhotoLibraryServing {
    let cancels: Bool
    func deleteAssets(localIdentifiers: [String]) async throws {
        if cancels { throw NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue) }
    }
    func removeAssetsFromAppAlbum(localIdentifiers: [String]) async {}
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

    init(cancels: Bool, photoLibrary: (any PhotoLibraryServing)? = nil) async throws {
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
            noteStore: NoteStore(fileURL: root.appendingPathComponent("notes.json")),
            photoLibrary: photoLibrary ?? ReviewPhotos(cancels: cancels))
        await coordinator.waitUntilLoaded()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
}
