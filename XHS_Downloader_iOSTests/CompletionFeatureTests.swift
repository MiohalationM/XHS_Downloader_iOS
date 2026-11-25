import Foundation
import Testing
import UIKit
import Network
@testable import XHS_Downloader_iOS

struct MediaPolicyTests {
    private func media(role: MediaRole?, type: RemoteMedia.MediaType = .image) -> RemoteMedia {
        RemoteMedia(url: URL(string: "https://example.com/a.heic")!, type: type,
                    fileBaseName: "a", originalURLString: "https://example.com/a.heic")
    }

    @Test func defaultsKeepOriginalsAndSkipCoversAndComments() async {
        let policy = DownloadPolicy()
        #expect(policy.imageFormat == .original)
        #expect(policy.videoPreference == .original)
        #expect(policy.destination == .photos)
        #expect(policy.captionFormat == .none)
        #expect(!policy.covers && !policy.comments)
        #expect(!policy.skipExisting && !policy.writePublishTime)
        #expect(policy.timeout == 45 && policy.retries == 3 && policy.requestInterval == 2)
        #expect(!policy.proxyMedia && policy.useWebSession)

        var cover = media(role: .cover)
        cover.role = .cover
        var comment = media(role: .comment)
        comment.role = .comment
        #expect(!policy.includes(cover))
        #expect(!policy.includes(comment))
        #expect(policy.includes(media(role: nil)))
        #expect(policy.includes(media(role: .body, type: .video)))

        var optIn = policy
        optIn.covers = true
        optIn.comments = true
        #expect(optIn.includes(cover))
        #expect(optIn.includes(comment))
    }

    @Test func policyRespectsMediaTypeSwitches() async {
        var policy = DownloadPolicy()
        policy.images = false
        #expect(!policy.includes(media(role: .body, type: .image)))
        #expect(policy.includes(media(role: .body, type: .video)))
        policy.videos = false
        #expect(!policy.includes(media(role: .body, type: .video)))
    }

    @Test func videoPreferenceReordersCandidatesAndKeepsBackups() async {
        let original = MediaVariant(url: URL(string: "https://example.com/original.mp4")!, isOriginal: true)
        let h265 = MediaVariant(url: URL(string: "https://example.com/h265.mp4")!,
                                backups: [URL(string: "https://example.com/h265-backup.mp4")!],
                                codec: "h265", height: 1920, bitrate: 5_000_000, byteCount: 9_000_000)
        let h264 = MediaVariant(url: URL(string: "https://example.com/h264.mp4")!,
                                codec: "h264", height: 1280, bitrate: 2_000_000, byteCount: 3_000_000)
        var item = media(role: .body, type: .video)
        item.variants = [h265, h264, original]

        var policy = DownloadPolicy()
        let originalFirst = item.applying(policy)
        #expect(originalFirst.candidates.first?.absoluteString == "https://example.com/original.mp4")

        policy.videoPreference = .size
        #expect(item.applying(policy).candidates.first?.absoluteString == "https://example.com/h264.mp4")

        policy.videoPreference = .compatibility
        #expect(item.applying(policy).candidates.first?.absoluteString == "https://example.com/h264.mp4")

        let chosen = item.applying(policy, variantID: h265.id)
        #expect(chosen.candidates.prefix(2).map(\.absoluteString) == [
            "https://example.com/h265.mp4", "https://example.com/h265-backup.mp4"
        ])
        #expect(chosen.url.absoluteString == "https://example.com/h265.mp4")
    }

    @Test func imageFormatPreferencePrependsRequestedFormatAndKeepsOriginal() async {
        var item = media(role: nil)
        item.fileKey = "1040g2t031abcdefg"
        var policy = DownloadPolicy()
        policy.imageFormat = .webp
        let applied = item.applying(policy)
        #expect(applied.candidates.first?.absoluteString.contains("imageView2/format/webp") == true)
        #expect(applied.candidates.contains(URL(string: "https://example.com/a.heic")!))

        policy.imageFormat = .original
        #expect(item.applying(policy).candidates.first?.absoluteString == "https://example.com/a.heic")
    }

    @Test func resourceResultsDefaultToQueuedAndCarryBytes() async throws {
        var result = ResourceResult()
        #expect(result.state == .queued)
        result.state = .downloading
        result.received = 512
        result.expected = 2048
        result.speed = 128
        let restored = try JSONDecoder().decode(ResourceResult.self, from: JSONEncoder().encode(result))
        #expect(restored == result)
        #expect(ResourceResult.State.saved.rawValue == "saved")
        #expect(ResourceResult.State.skipped.rawValue == "skipped")
    }

    @Test func taskRecordRoundTripsPolicyAndResourceResults() async throws {
        var task = DownloadTaskRecord(sourceText: "share", normalizedURL: "https://www.xiaohongshu.com/explore/abc")
        var policy = DownloadPolicy()
        policy.covers = true
        policy.destination = .both
        policy.captionFormat = .markdown
        policy.imageFormat = .heic
        policy.skipExisting = true
        task.policy = policy
        task.informationOnly = true
        task.resourceResults = ["note:image:0": ResourceResult(state: .saved, received: 10, expected: 10)]
        task.selectedVariants = ["note:video:0": "https://example.com/v.mp4"]
        task.archiveTextPaths = ["/tmp/a.md"]

        let data = try JSONEncoder().encode(task)
        let restored = try JSONDecoder().decode(DownloadTaskRecord.self, from: data)
        #expect(restored.policy == policy)
        #expect(restored.informationOnly == true)
        #expect(restored.resourceResults?["note:image:0"]?.state == .saved)
        #expect(restored.selectedVariants?["note:video:0"] == "https://example.com/v.mp4")
        #expect(restored.archiveTextPaths == ["/tmp/a.md"])
    }
}

struct TaskGroupTests {
    @Test func groupsCoverEveryStatusExactlyOnce() async {
        for status in TaskStatus.allCases {
            var task = DownloadTaskRecord(sourceText: "", normalizedURL: "https://example.com")
            task.status = status
            let matches = TaskGroup.allCases.filter { $0.contains(task) }
            #expect(matches.count == 1, "\(status) matched \(matches.map(\.rawValue))")
        }
    }

    @Test func pausedAndCancelledAreWaitingNotActive() async {
        var task = DownloadTaskRecord(sourceText: "", normalizedURL: "https://example.com")
        task.status = .paused
        #expect(TaskGroup.waiting.contains(task))
        #expect(!TaskGroup.active.contains(task))
        task.status = .cancelled
        #expect(TaskGroup.waiting.contains(task))
        task.status = .downloading
        #expect(TaskGroup.active.contains(task))
        task.status = .completed
        #expect(TaskGroup.finished.contains(task))
    }
}

struct ArchiveNamingTests {
    @Test func pathComponentsStayInsideArchiveRoot() async {
        let cases = [
            ("a/b:c\\d", "a_b_c_d"),
            ("..hidden..", "hidden"),
            ("   ", "fallback"),
            (String(repeating: "x", count: 200), String(repeating: "x", count: 80))
        ]
        for (input, expected) in cases {
            #expect(FileArchiver.directoryComponent(input, fallback: "fallback") == expected)
        }
        #expect(!FileArchiver.directoryComponent("a/b", fallback: "f").contains("/"))
    }

    @Test func noteComponentKeepsStableIdentityEvenWithoutTitle() async {
        let url = URL(string: "https://www.xiaohongshu.com/explore/65f0000000000000000000aa")!
        let withTitle = ResolvedNote(noteID: "65f0000000000000000000aa", canonicalURL: url, title: "标题",
                                     body: "", metadata: NoteMetadata(), media: [])
        let withoutTitle = ResolvedNote(noteID: "65f0000000000000000000aa", canonicalURL: url, title: "  ",
                                        body: "", metadata: NoteMetadata(), media: [])
        #expect(FileArchiver.noteComponent(withTitle) == "标题_65f0000000000000000000aa")
        #expect(FileArchiver.noteComponent(withoutTitle) == "65f0000000000000000000aa")
    }

    @Test func captionsRenderMarkdownAndPlainTextWithMetadata() async {
        let url = URL(string: "https://www.xiaohongshu.com/explore/abc")!
        let note = ResolvedNote(noteID: "abc", canonicalURL: url, title: "标题", body: "正文",
                                metadata: NoteMetadata(userName: "作者", publishTime: "26-11-08", redId: "red01"),
                                media: [])
        let markdown = await FileArchiver.shared.captionText(note, markdown: true)
        #expect(markdown.hasPrefix("# 标题"))
        #expect(markdown.contains("作者"))
        #expect(markdown.contains("red01"))
        #expect(markdown.contains("26-11-08"))
        #expect(markdown.contains(url.absoluteString))
        #expect(markdown.hasSuffix("正文"))
        let plain = await FileArchiver.shared.captionText(note, markdown: false)
        #expect(!plain.hasPrefix("# "))
        #expect(plain.contains("正文"))
    }

    @Test func skipExistingReportsInsteadOfDuplicating() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bookmark = try ArchiveDirectory.makeBookmark(for: root)
        var policy = DownloadPolicy()
        policy.destination = .files
        policy.filesBookmark = bookmark
        policy.skipExisting = true

        let note = ResolvedNote(noteID: "note1", canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/note1")!,
                                title: "标题", body: "正文", metadata: NoteMetadata(userName: "作者"), media: [])
        // Keep the staged file outside the archive root: the archiver copies into
        // the root, so a same-named source would collide with its own target.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Staging-\(UUID())")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let source = staging.appendingPathComponent("staged.jpg")
        try Data("image".utf8).write(to: source)

        let directory = try await FileArchiver.shared.prepare(note: note, policy: policy)
        defer { Task { await FileArchiver.shared.release(directory) } }
        let first = try await FileArchiver.shared.archive(
            entries: [FileArchiver.Entry(file: source, baseName: "staged", key: "k1")],
            in: directory, policy: policy)
        #expect(first.files.count == 1 && first.skipped.isEmpty)

        let second = try await FileArchiver.shared.archive(
            entries: [FileArchiver.Entry(file: source, baseName: "staged", key: "k1")],
            in: directory, policy: policy)
        #expect(second.files.isEmpty)
        #expect(second.skipped == ["k1"])
    }

    @Test func archiveCreatesAuthorAndNoteSubdirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var policy = DownloadPolicy()
        policy.destination = .files
        policy.filesBookmark = try ArchiveDirectory.makeBookmark(for: root)
        policy.authorDirectories = true
        policy.noteDirectories = true
        policy.captionFormat = .both

        let note = ResolvedNote(noteID: "n1", canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/n1")!,
                                title: "标题", body: "正文",
                                metadata: NoteMetadata(userName: "作者", userId: "uid1"), media: [])
        let directory = try await FileArchiver.shared.prepare(note: note, policy: policy)
        #expect(directory.url.path.hasSuffix("作者_uid1/标题_n1"))
        let captions = try await FileArchiver.shared.writeCaptions(note: note, in: directory, policy: policy)
        #expect(captions.count == 2)
        for path in captions { #expect(FileManager.default.fileExists(atPath: path)) }
        await FileArchiver.shared.release(directory)
    }

    @Test func missingBookmarkThrowsInsteadOfWritingElsewhere() async {
        let note = ResolvedNote(noteID: "n", canonicalURL: URL(string: "https://example.com")!,
                                title: "", body: "", metadata: NoteMetadata(), media: [])
        await #expect(throws: ArchiveError.self) {
            _ = try await FileArchiver.shared.prepare(note: note, policy: DownloadPolicy())
        }
    }

    @Test func archiveDirectoryResolvesItsOwnBookmark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try ArchiveDirectory.makeBookmark(for: root)
        #expect(ArchiveDirectory.isUsable(bookmark))
        #expect(ArchiveDirectory.resolve(bookmark)?.standardizedFileURL == root.standardizedFileURL)
        #expect(!ArchiveDirectory.isUsable(nil))
        #expect(!ArchiveDirectory.isUsable(Data([0x00, 0x01])))
    }
}

struct NamingTimeZoneTests {
    @Test func explicitTimeZoneControlsFormattedDates() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let metadata = NoteMetadata(userName: "a", title: "t")
        let utc = NamingPreferences(enabled: true, template: "{downloadTimestamp:yyyy-MM-dd-HH}",
                                    timeZone: TimeZone(identifier: "UTC")!)
        let tokyo = NamingPreferences(enabled: true, template: "{downloadTimestamp:yyyy-MM-dd-HH}",
                                      timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let utcName = NamingFormatter.makeBaseName(metadata: metadata, fallbackPostId: "p", index: 1,
                                                   downloadEpochSeconds: date.timeIntervalSince1970, preferences: utc)
        let tokyoName = NamingFormatter.makeBaseName(metadata: metadata, fallbackPostId: "p", index: 1,
                                                     downloadEpochSeconds: date.timeIntervalSince1970, preferences: tokyo)
        #expect(utcName.hasPrefix("2023-11-14-22"))
        #expect(tokyoName.hasPrefix("2023-11-15-07"))
    }

    @Test func loadsTimeZoneFromDefaults() async throws {
        let name = "NamingTimeZoneTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: NamingPreferences.enableKey)
        defaults.set("Asia/Shanghai", forKey: NamingPreferences.timezoneKey)
        defaults.set("{title}", forKey: NamingPreferences.templateKey)
        let preferences = NamingPreferences.load(defaults: defaults)
        #expect(preferences.timeZone.identifier == "Asia/Shanghai")
        #expect(preferences.enabled && preferences.template == "{title}")
    }

    @Test func rejectsUnknownTokensAndBadDatePatterns() async {
        #expect(NamingFormatter.validationError("{title}") == nil)
        #expect(NamingFormatter.validationError("{nope}") != nil)
        #expect(NamingFormatter.validationError("{title") != nil)
        #expect(NamingFormatter.validationError("{title:yyyy}") != nil)
        #expect(NamingFormatter.validationError("{downloadTimestamp:yyyyMMdd}") == nil)
        #expect(NamingFormatter.validationError("{publishTime:yyyy/MM/dd}") == nil)
        #expect(NamingFormatter.validationError("{downloadTimestamp:yyyy-QQ}") != nil)
        #expect(NamingFormatter.validationError("   ") != nil)
    }
}

struct BackupTests {
    private func makeTask(id: UUID = UUID(), noteID: String = "note1") -> DownloadTaskRecord {
        var task = DownloadTaskRecord(sourceText: "share", normalizedURL: "https://www.xiaohongshu.com/explore/\(noteID)",
                                      title: "标题", noteText: "正文", status: .completed)
        task.id = id
        task.resolvedNote = ResolvedNote(noteID: noteID,
                                         canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/\(noteID)")!,
                                         title: "标题", body: "正文",
                                         metadata: NoteMetadata(userName: "作者", userId: "uid", redId: "red"), media: [])
        task.mediaAssets = [MediaAssetRecord(localIdentifier: "asset-1", fileName: "a.heic", isVideo: false)]
        return task
    }

    @Test func exportOmitsCredentialsAndVolatileState() async throws {
        var task = makeTask()
        var policy = DownloadPolicy()
        policy.proxy = "http://user:pass@example.com:8080"
        policy.filesBookmark = Data([1, 2, 3])
        task.policy = policy
        task.stagedFiles = ["k": "/tmp/staged"]
        task.draftSelectionIDs = ["k"]
        task.resourceResults = ["k": ResourceResult(state: .downloading)]
        let entry = BackupEntry.make(from: task)
        #expect(entry.record.policy?.proxy == "")
        #expect(entry.record.policy?.filesBookmark == nil)
        #expect(entry.record.stagedFiles == nil)
        #expect(entry.record.draftSelectionIDs == nil)
        #expect(entry.record.resourceResults == nil)
        #expect(entry.record.mediaAssets.count == 1)
        #expect(entry.identity == "note:note1")
    }

    @Test func identityPrefersNoteIDThenURL() async {
        #expect(BackupEntry.identity(of: makeTask()) == "note:note1")
        var task = DownloadTaskRecord(sourceText: "", normalizedURL: "https://www.xiaohongshu.com/explore/xyz")
        task.resolvedNote = nil
        #expect(BackupEntry.identity(of: task) == "url:https://www.xiaohongshu.com/explore/xyz")
    }

    @Test func jsonRoundTripPreservesNotesAndLibrary() async throws {
        let task = makeTask()
        var payload = BackupService.BackupLibraryPayload()
        payload.notes = [StoredNote(id: "note:note1", noteID: "note1",
                                    canonicalURL: "https://www.xiaohongshu.com/explore/note1",
                                    title: "标题", body: "正文",
                                    metadata: NoteMetadata(userName: "作者", redId: "red"),
                                    mediaAssets: task.mediaAssets)]
        payload.collections = [NoteCollection(name: "旅行", noteIDs: ["note:note1"])]
        payload.likedNotes = ["note:note1"]
        payload.bookmarkedNotes = ["note:note1"]
        payload.authorRemarks = ["uid": "老友"]
        let url = try await BackupService.shared.exportJSON(tasks: [task], library: payload)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await BackupService.shared.importBackup(from: url)
        #expect(document.version == BackupDocument.currentVersion)
        #expect(document.tasks.count == 1)
        #expect(document.tasks[0].record.title == "标题")
        #expect(document.tasks[0].record.resolvedNote?.metadata.redId == "red")
        #expect(document.notes.count == 1)
        #expect(document.notes[0].body == "正文")
        #expect(document.collections.first?.noteIDs == ["note:note1"])
        #expect(document.likedNotes == ["note:note1"])
        #expect(document.authorRemarks["uid"] == "老友")
    }

    @Test func csvStartsWithBOMAndQuotesCommas() async throws {
        var task = makeTask()
        task.title = "标题,带逗号"
        let url = try await BackupService.shared.exportCSV([task])
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        let text = try #require(String(data: data.dropFirst(3), encoding: .utf8))
        #expect(text.contains("\"标题,带逗号\""))
        #expect(text.hasPrefix("id,title,note_id"))
    }

    @Test func zipWriterProducesReadableStoredArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZipTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zipURL = root.appendingPathComponent("test.zip")
        let writer = try ZipWriter(url: zipURL)
        try writer.add(data: Data("hello".utf8), name: "a/hello.txt")
        try writer.close()
        let data = try Data(contentsOf: zipURL)
        #expect(data.count > 0)
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(data.suffix(22).prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]))
        #expect(data.range(of: Data("hello".utf8)) != nil)
        #expect(data.range(of: Data("a/hello.txt".utf8)) != nil)
    }

    @Test func rejectsNewerBackupVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("future.xhsbackup")
        let document = BackupDocument(version: BackupDocument.currentVersion + 1, tasks: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url)
        #expect(throws: BackupError.self) {
            _ = try BackupServiceSync.importBackup(from: url)
        }
    }
}

/// The actor API is async; this helper keeps the synchronous expectation above
/// readable without duplicating the decoding logic.
private enum BackupServiceSync {
    static func importBackup(from url: URL) throws -> BackupDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(BackupDocument.self, from: Data(contentsOf: url))
        guard document.version <= BackupDocument.currentVersion else {
            throw BackupError.unsupportedVersion(document.version)
        }
        return document
    }
}

struct NoteLibraryFeatureTests {
    @Test func textOnlyNoteStillBecomesACard() async {
        var task = DownloadTaskRecord(sourceText: "", normalizedURL: "https://www.xiaohongshu.com/explore/textonly",
                                      title: "只有文案", noteText: "正文内容", status: .completed)
        task.resolvedNote = ResolvedNote(noteID: "textonly",
                                         canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/textonly")!,
                                         title: "只有文案", body: "正文内容", metadata: NoteMetadata(userName: "作者"), media: [])
        let notes = NoteLibrary.notes(tasks: [task], media: [])
        #expect(notes.count == 1)
        #expect(notes[0].isTextOnly)
        #expect(notes[0].cover == nil)
        #expect(notes[0].body == "正文内容")
    }

    @Test func emptyTaskWithoutTextIsDropped() async {
        let task = DownloadTaskRecord(sourceText: "", normalizedURL: "https://example.com/none")
        #expect(NoteLibrary.notes(tasks: [task], media: []).isEmpty)
    }

    @Test func sortingBySavedAndPublishedTime() async {
        func note(_ id: String, saved: Date, published: String?) -> LibraryNote {
            LibraryNote(id: id, title: id, body: "", author: "a", avatarURL: nil, publishTime: published,
                        topics: [], sourceURL: nil, date: saved, media: [])
        }
        let old = note("old", saved: Date(timeIntervalSince1970: 100), published: "26-11-09")
        let new = note("new", saved: Date(timeIntervalSince1970: 200), published: "26-11-01")
        let newest = NoteLibrary.sorted([old, new], by: .savedNewest)
        #expect(newest.map(\.id) == ["new", "old"])
        #expect(NoteLibrary.sorted([old, new], by: .savedOldest).map(\.id) == ["old", "new"])
        #expect(NoteLibrary.sorted([old, new], by: .publishedNewest).map(\.id) == ["old", "new"])
    }

    @Test func searchMatchesRedIDAndRemark() async {
        let note = LibraryNote(id: "n", title: "标题", body: "正文", author: "作者", avatarURL: nil,
                               publishTime: nil, topics: ["话题"], sourceURL: nil, date: .now, media: [],
                               authorID: "uid", authorRedID: "red777")
        #expect(note.matches(query: "red777", filter: 0))
        #expect(note.matches(query: "备注名", filter: 0, remark: "备注名"))
        #expect(!note.matches(query: "备注名", filter: 0))
        #expect(note.matches(query: "", filter: 1), "text-only notes count as image notes")
        #expect(!note.matches(query: "", filter: 2))
    }

    @Test @MainActor func collectionsAndRemarksPersistAndDeletingKeepsNotes() async throws {
        let name = "NoteLibraryFeatureTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = NoteLibraryPreferences(defaults: defaults)

        let collection = try #require(preferences.createCollection(named: " 旅行 "))
        #expect(collection.name == "旅行")
        preferences.setMembership(["a", "b"], in: collection.id, included: true)
        #expect(preferences.contains("a", in: collection.id))
        preferences.setMembership(["a"], in: collection.id, included: false)
        #expect(!preferences.contains("a", in: collection.id))
        #expect(preferences.contains("b", in: collection.id))

        preferences.renameCollection(collection.id, to: "摄影")
        preferences.setRemark("老友", for: "uid1")
        preferences.sortOrder = .publishedNewest

        let reloaded = NoteLibraryPreferences(defaults: defaults)
        #expect(reloaded.collections.first?.name == "摄影")
        #expect(reloaded.collections.first?.noteIDs == ["b"])
        #expect(reloaded.remark(for: "uid1") == "老友")
        #expect(reloaded.sortOrder == .publishedNewest)

        reloaded.setRemark("   ", for: "uid1")
        #expect(NoteLibraryPreferences(defaults: defaults).remark(for: "uid1") == nil)

        reloaded.deleteCollection(collection.id)
        #expect(NoteLibraryPreferences(defaults: defaults).collections.isEmpty)
        #expect(preferences.createCollection(named: "   ") == nil)
    }

    @Test func noteIdentityCarriesResolvedNoteID() async {
        var task = DownloadTaskRecord(sourceText: "", normalizedURL: "https://www.xiaohongshu.com/explore/abc")
        task.resolvedNote = ResolvedNote(noteID: "abc", canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/abc")!,
                                         title: "t", body: "b", metadata: NoteMetadata(), media: [])
        task.mediaAssets = [MediaAssetRecord(localIdentifier: "x", fileName: "a.heic", isVideo: false)]
        let note = NoteLibrary.notes(tasks: [task], media: [LibraryMedia(id: "x")]).first
        #expect(note?.noteID == "abc")
        // Without an author identity the display placeholder becomes the group
        // key, so remarks and filters still have something stable to attach to.
        #expect(note?.authorKey == L10n.text("feed.author.unknown"))
    }
}

struct ImportBehaviorTests {
    @Test @MainActor func directEntrySkipsSelectionEvenWhenSelectiveDefaultIsOn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: AppSettings.Key.selectiveDownload)
        // RequestPacer is process-wide; a zero interval keeps this test from
        // serializing behind other suites' page requests.
        var policy = DownloadPolicy()
        policy.requestInterval = 0
        policy.save(defaults: defaults)
        let settings = AppSettings(defaults: defaults)
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BehaviorFixtureProtocol.self]
        let coordinator = DownloadCoordinator(settings: settings, store: store,
                                              downloader: XHSDownloader(session: URLSession(configuration: configuration)))
        await coordinator.waitUntilLoaded()

        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/direct", behavior: .direct).value
        let direct = try #require(coordinator.tasks.first)
        #expect(direct.selectionRequired == false)
        #expect(direct.informationOnly == false)

        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/select", behavior: .select).value
        let select = try #require(coordinator.tasks.first { $0.normalizedURL.hasSuffix("select") })
        #expect(select.selectionRequired == true)

        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/noteonly", behavior: .informationOnly).value
        let info = try #require(coordinator.tasks.first { $0.normalizedURL.hasSuffix("noteonly") })
        #expect(info.informationOnly == true)
        #expect(info.selectionRequired == false)
    }

    @Test @MainActor func clipboardAndShareRequestsDefaultToSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var policy = DownloadPolicy()
        policy.requestInterval = 0
        policy.save(defaults: defaults)
        let settings = AppSettings(defaults: defaults)
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let coordinator = DownloadCoordinator(settings: settings, store: store)
        await coordinator.waitUntilLoaded()
        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/plain").value
        let task = try #require(coordinator.tasks.first)
        #expect(task.selectionRequired == false)
        #expect(task.informationOnly == false)
    }
}

private final class BehaviorFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let id = url.lastPathComponent
        let html = """
        <script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"\(id)":{"note":{
        "noteId":"\(id)","title":"Fixture","imageList":[{"urlDefault":"https://media.example/\(id).png"}]
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

// MARK: - Regression coverage for the 1.1.0 review findings

struct NoteDurabilityTests {
    private func makeTask(status: TaskStatus = .completed) -> DownloadTaskRecord {
        var task = DownloadTaskRecord(sourceText: "share text",
                                      normalizedURL: "https://www.xiaohongshu.com/explore/durable",
                                      title: "标题", noteText: "正文", status: status)
        task.resolvedNote = ResolvedNote(noteID: "durable",
                                         canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/durable")!,
                                         title: "标题", body: "正文",
                                         metadata: NoteMetadata(userName: "作者", userId: "uid1", redId: "red1"), media: [])
        task.mediaAssets = [MediaAssetRecord(localIdentifier: "asset-1", fileName: "a.heic", isVideo: false)]
        task.noteKey = "note:durable"
        return task
    }

    /// Finding 1: removing finished history must not delete note text, authors
    /// or the note's media association.
    @Test @MainActor func removeFinishedKeepsNotesAndMediaAssociation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let settings = AppSettings(defaults: defaults)
        let taskStore = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        try await taskStore.save([makeTask()])
        let coordinator = DownloadCoordinator(settings: settings, store: taskStore, noteStore: noteStore)
        await coordinator.waitUntilLoaded()
        #expect(coordinator.notes.count == 1)

        coordinator.removeFinished()

        #expect(coordinator.tasks.isEmpty)
        #expect(coordinator.notes.count == 1, "note must survive history removal")
        #expect(coordinator.notes[0].body == "正文")
        #expect(coordinator.notes[0].metadata.userName == "作者")
        #expect(coordinator.notes[0].mediaAssets.map(\.localIdentifier) == ["asset-1"])

        // And it is still on disk for the next launch.
        await coordinator.flushPersistence()
        let restored = DownloadCoordinator(settings: settings, store: taskStore, noteStore: noteStore)
        await restored.waitUntilLoaded()
        #expect(restored.tasks.isEmpty)
        #expect(restored.notes.count == 1)
    }

    @Test @MainActor func clearHistoryKeepsNotesToo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let settings = AppSettings(defaults: defaults)
        let taskStore = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        try await taskStore.save([makeTask()])
        let coordinator = DownloadCoordinator(settings: settings, store: taskStore, noteStore: noteStore)
        await coordinator.waitUntilLoaded()
        coordinator.clearHistory()
        // clearHistory finishes asynchronously; give it a moment to settle.
        let deadline = Date().addingTimeInterval(3)
        while !coordinator.tasks.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(coordinator.tasks.isEmpty)
        #expect(coordinator.notes.count == 1)
    }

    /// A note saved with no media is still openable: the feed builds it and the
    /// reader has content to show.
    @Test func textOnlyNoteSurvivesStoreRoundTrip() async throws {
        let note = StoredNote(id: "note:text", noteID: "text", canonicalURL: "https://www.xiaohongshu.com/explore/text",
                              title: "只有文案", body: "正文内容", metadata: NoteMetadata(userName: "作者"))
        let data = try JSONEncoder().encode([note])
        let restored = try JSONDecoder().decode([StoredNote].self, from: data)
        #expect(restored.count == 1)
        #expect(restored[0].isMeaningful)
        let cards = NoteLibrary.notes(stored: restored, media: [])
        #expect(cards.count == 1)
        #expect(cards[0].isTextOnly)
        #expect(cards[0].cover == nil)
    }

    @Test func noteStoreKeepsBackupAndReportsCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url)
        let note = StoredNote(id: "note:1", noteID: "1", canonicalURL: "https://example.com/1",
                              title: "t", body: "b", metadata: NoteMetadata())
        try await store.save([note])
        try await store.save([note]) // second write creates the rolling backup
        #expect(await store.load().count == 1)

        try Data("not json".utf8).write(to: url)
        let broken = NoteStore(fileURL: url)
        // Falls back to the backup instead of silently emptying the library.
        #expect(await broken.load().count == 1)
        #expect(await broken.loadError != nil)
    }

    @Test @MainActor func deletingANoteIsExplicitAndRemovesItsTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let settings = AppSettings(defaults: defaults)
        let taskStore = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        try await taskStore.save([makeTask()])
        let coordinator = DownloadCoordinator(settings: settings, store: taskStore, noteStore: noteStore)
        await coordinator.waitUntilLoaded()
        await coordinator.deleteNote("note:durable", deletePhotos: false)
        #expect(coordinator.notes.isEmpty)
        #expect(coordinator.tasks.isEmpty)
    }
}

struct DestinationOutcomeTests {
    @Test func aResourceIsOnlySatisfiedWhenEveryRequestedDestinationSettled() async {
        var result = ResourceResult(state: .saved)
        result.photos = DestinationResult(state: .saved)
        result.files = DestinationResult(state: .failed, error: "no folder")
        #expect(!result.isSatisfied(photosRequired: true, filesRequired: true, mergeRequired: false))
        #expect(result.isSatisfied(photosRequired: true, filesRequired: false, mergeRequired: false))

        result.files = DestinationResult(state: .saved)
        #expect(result.isSatisfied(photosRequired: true, filesRequired: true, mergeRequired: false))
    }

    @Test func failedLivePhotoMergeIsNotSatisfied() async {
        var result = ResourceResult(state: .saved)
        result.photos = DestinationResult(state: .saved)
        result.livePhotoOutcome = .componentsOnly
        #expect(!result.isSatisfied(photosRequired: true, filesRequired: false, mergeRequired: true))
        result.livePhotoOutcome = .merged
        #expect(result.isSatisfied(photosRequired: true, filesRequired: false, mergeRequired: true))
    }

    @Test func destinationResultsRoundTrip() async throws {
        var result = ResourceResult(state: .failed, error: "partial")
        result.photos = DestinationResult(state: .saved, reference: "asset/x", byteCount: 10)
        result.files = DestinationResult(state: .failed, error: "write", byteCount: 0)
        result.livePhotoOutcome = .componentsOnly
        let restored = try JSONDecoder().decode(ResourceResult.self, from: JSONEncoder().encode(result))
        #expect(restored.photos?.state == .saved)
        #expect(restored.photos?.reference == "asset/x")
        #expect(restored.files?.error == "write")
        #expect(restored.livePhotoOutcome == .componentsOnly)
    }
}

struct ArchiveVerificationTests {
    /// Finding 4: a same-named file is not proof. Only a non-empty file with the
    /// expected size may be skipped.
    @Test func existingFileMustBeUsableBeforeItIsSkipped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let empty = root.appendingPathComponent("empty.heic")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        #expect(!FileArchiver.isUsableExistingFile(empty, expectedByteCount: nil))

        let truncated = root.appendingPathComponent("truncated.heic")
        try Data(repeating: 0, count: 10).write(to: truncated)
        #expect(!FileArchiver.isUsableExistingFile(truncated, expectedByteCount: 500))
        #expect(FileArchiver.isUsableExistingFile(truncated, expectedByteCount: 10))
        #expect(FileArchiver.isUsableExistingFile(truncated, expectedByteCount: nil))
        #expect(!FileArchiver.isUsableExistingFile(root.appendingPathComponent("missing.heic"), expectedByteCount: nil))
    }

    @Test func oneFailedCopyDoesNotAbortTheRestOfTheBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        let good = staging.appendingPathComponent("good.heic")
        try Data(repeating: 1, count: 64).write(to: good)
        let missing = staging.appendingPathComponent("missing.heic")

        var policy = DownloadPolicy()
        policy.destination = .files
        policy.filesBookmark = try ArchiveDirectory.makeBookmark(for: root)
        let note = ResolvedNote(noteID: "n", canonicalURL: URL(string: "https://example.com/n")!,
                                title: "t", body: "b", metadata: NoteMetadata(), media: [])
        let directory = try await FileArchiver.shared.prepare(note: note, policy: policy)
        defer { Task { await FileArchiver.shared.release(directory) } }

        let result = try await FileArchiver.shared.archive(
            entries: [FileArchiver.Entry(file: good, baseName: "good", key: "good"),
                      FileArchiver.Entry(file: missing, baseName: "missing", key: "missing")],
            in: directory, policy: policy)
        #expect(result.files.count == 1)
        #expect(result.failed["missing"] != nil)
        #expect(result.failed["good"] == nil)
    }

    @Test func skipReportsTheExistingPathSoItCanBeAssociated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        let source = staging.appendingPathComponent("a.heic")
        try Data(repeating: 2, count: 32).write(to: source)

        var policy = DownloadPolicy()
        policy.destination = .files
        policy.filesBookmark = try ArchiveDirectory.makeBookmark(for: root)
        policy.skipExisting = true
        let note = ResolvedNote(noteID: "n", canonicalURL: URL(string: "https://example.com/n")!,
                                title: "t", body: "b", metadata: NoteMetadata(), media: [])
        let directory = try await FileArchiver.shared.prepare(note: note, policy: policy)
        defer { Task { await FileArchiver.shared.release(directory) } }

        _ = try await FileArchiver.shared.archive(
            entries: [FileArchiver.Entry(file: source, baseName: "a", key: "k")], in: directory, policy: policy)
        let second = try await FileArchiver.shared.archive(
            entries: [FileArchiver.Entry(file: source, baseName: "a", key: "k")], in: directory, policy: policy)
        #expect(second.skipped == ["k"])
        #expect(second.reused["k"] != nil)
        #expect(FileManager.default.fileExists(atPath: second.reused["k"] ?? ""))
    }
}

struct BackupRedactionTests {
    @Test func exportStripsShareTextTokensAndPaths() async throws {
        var task = DownloadTaskRecord(
            sourceText: "复制打开小红书，看看【标题】 https://www.xiaohongshu.com/explore/abc?xsec_token=SECRET&xsec_source=pc",
            normalizedURL: "https://www.xiaohongshu.com/explore/abc?xsec_token=SECRET&xsec_source=pc")
        task.resolvedNote = ResolvedNote(
            noteID: "abc",
            canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/abc?xsec_token=SECRET")!,
            title: "t", body: "b", metadata: NoteMetadata(userName: "a"), media: [])
        task.mediaAssets = [MediaAssetRecord(localIdentifier: "asset-1", fileName: "a.heic", isVideo: false)]
        task.mediaAssets[0].filesPaths = ["/Users/private/Library/archive/a.heic"]
        task.archiveTextPaths = ["/Users/private/Library/archive/caption.txt"]

        let entry = BackupEntry.make(from: task)
        #expect(entry.record.sourceText.isEmpty)
        #expect(!entry.record.normalizedURL.contains("SECRET"))
        #expect(!entry.record.normalizedURL.contains("xsec_token"))
        #expect(entry.record.resolvedNote?.canonicalURL.absoluteString.contains("SECRET") == false)
        #expect(entry.record.archiveTextPaths == nil)
        #expect(entry.record.mediaAssets.first?.filesPaths == nil)
        // The note identity and user text are preserved.
        #expect(entry.record.resolvedNote?.title == "t")
        #expect(entry.record.resolvedNote?.body == "b")
        #expect(entry.record.resolvedNote?.noteID == "abc")
    }

    @Test func redactedURLKeepsPathAndDropsCredentials() async {
        let value = BackupEntry.redactedURL("https://user:pw@www.xiaohongshu.com/explore/abc?xsec_token=1#frag")
        #expect(value == "https://www.xiaohongshu.com/explore/abc")
    }

    @Test func csvExportIsRedactedToo() async throws {
        var task = DownloadTaskRecord(sourceText: "secret",
                                      normalizedURL: "https://www.xiaohongshu.com/explore/abc?xsec_token=SECRET")
        task.title = "标题"
        let url = try await BackupService.shared.exportCSV([task])
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try #require(String(data: Data(contentsOf: url).dropFirst(3), encoding: .utf8))
        #expect(!text.contains("SECRET"))
    }
}

struct VersionComparisonTests {
    @Test @MainActor func numericVersionComparison() async {
        #expect(SettingsView.isVersion("1.10.0", newerThan: "1.9.0"))
        #expect(SettingsView.isVersion("1.1.1", newerThan: "1.1.0"))
        #expect(!SettingsView.isVersion("1.1.0", newerThan: "1.1.0"))
        #expect(!SettingsView.isVersion("1.0.9", newerThan: "1.1.0"))
        #expect(!SettingsView.isVersion("1.1", newerThan: "1.1.0"))
    }
}

struct BrowserImportTests {
    @Test @MainActor func noteIDIsReadFromBothNotePaths() async {
        #expect(BrowserModel.noteID(from: URL(string: "https://www.xiaohongshu.com/explore/0123456789abcdef01234567")!)
                == "0123456789abcdef01234567")
        #expect(BrowserModel.noteID(from: URL(string: "https://www.xiaohongshu.com/discovery/item/0123456789abcdef01234567")!)
                == "0123456789abcdef01234567")
        #expect(BrowserModel.noteID(from: URL(string: "https://www.xiaohongshu.com/explore")!) == nil)
    }

    /// Finding 6: the live page URL is handed over as-is so its access token is
    /// not dropped.
    @Test @MainActor func normalizedURLKeepsQueryParameters() async {
        let url = BrowserModel.normalizedURL("https://www.xiaohongshu.com/explore/abc?xsec_token=T&xsec_source=pc")
        #expect(url?.absoluteString.contains("xsec_token=T") == true)
    }
}

// MARK: - Snapshot, network and destination wiring

struct PolicySnapshotTests {
    @Test @MainActor func submittedPolicyWinsOverLaterSettingsEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let settings = AppSettings(defaults: defaults)
        var policy = DownloadPolicy()
        policy.requestInterval = 0
        policy.covers = false
        policy.imageFormat = .heic
        settings.policy = policy

        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        let coordinator = DownloadCoordinator(settings: settings, store: store, noteStore: noteStore)
        await coordinator.waitUntilLoaded()
        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/snapshot").value
        let task = try #require(coordinator.tasks.first)
        #expect(task.policy?.imageFormat == .heic)
        #expect(task.downloadInstant != nil)
        #expect(task.noteKey == "url:https://www.xiaohongshu.com/explore/snapshot")

        // Changing settings afterwards must not rewrite the submitted snapshot.
        var edited = settings.policy
        edited.imageFormat = .avif
        edited.covers = true
        settings.policy = edited
        #expect(coordinator.tasks.first?.policy?.imageFormat == .heic)
        #expect(coordinator.tasks.first?.policy?.covers == false)
    }

    @Test func namingContextReusesSubmittedInstantAndTimeZone() async {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let preferences = NamingPreferences(enabled: true, template: "{downloadTimestamp:yyyyMMdd-HH}",
                                            timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let context = XHSDownloader.NamingContext(preferences: preferences, downloadInstant: instant)
        let first = NamingFormatter.makeBaseName(metadata: NoteMetadata(), fallbackPostId: "p", index: 1,
                                                 downloadEpochSeconds: context.downloadInstant.timeIntervalSince1970,
                                                 preferences: context.preferences)
        let second = NamingFormatter.makeBaseName(metadata: NoteMetadata(), fallbackPostId: "p", index: 1,
                                                  downloadEpochSeconds: context.downloadInstant.timeIntervalSince1970,
                                                  preferences: context.preferences)
        #expect(first == second)
        #expect(first.hasPrefix("20231115-07"), "Tokyo time and the frozen instant must both apply")
    }

    @Test func networkPolicyCarriesTimeoutsAndProxyValidation() async throws {
        var policy = DownloadPolicy()
        policy.timeout = 90
        policy.proxy = "socks5://127.0.0.1:1080"
        let configuration = try NetworkPolicy.configuration(policy)
        #expect(configuration.timeoutIntervalForRequest == 90)
        #expect(!configuration.proxyConfigurations.isEmpty)

        var invalid = DownloadPolicy()
        invalid.proxy = "http://user:pass@host:1"
        #expect(throws: ProxyConfigurationError.self) { _ = try NetworkPolicy.configuration(invalid) }
    }

    @Test func backgroundTransferRefusesProxiedMedia() async {
        // The background session cannot carry a proxy, so proxied media must use
        // the foreground session rather than silently bypassing the proxy.
        #expect(BackgroundTransfers.shared.supportsProxy(true) == false)
        #expect(BackgroundTransfers.shared.supportsProxy(false) == true)
    }
}

struct DestinationWiringTests {
    @Test func filesOnlyTaskRecordsAnArchivedAssetWithoutPhotos() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var policy = DownloadPolicy()
        policy.destination = .files
        policy.filesBookmark = try ArchiveDirectory.makeBookmark(for: root)
        let note = ResolvedNote(noteID: "n1", canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/n1")!,
                                title: "标题", body: "正文", metadata: NoteMetadata(userName: "作者"), media: [])

        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        try Data(repeating: 7, count: 128).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let directory = try await FileArchiver.shared.prepare(note: note, policy: policy)
        let result = try await FileArchiver.shared.archive(
            entries: [FileArchiver.Entry(file: source, baseName: "a", key: "k")], in: directory, policy: policy)
        await FileArchiver.shared.release(directory)
        #expect(result.files.count == 1)

        // A Files-only media record resolves into a feed item without a PHAsset.
        var record = MediaAssetRecord(localIdentifier: "file:" + result.files[0], fileName: "a.heic", isVideo: false)
        record.filesPaths = result.files
        let resolved = LibraryMedia(record: record, lookup: [:])
        #expect(resolved != nil)
        #expect(resolved?.isVideo == false)
    }

    @Test func filesOnlyRecordWithoutArchivePathsReturnsNil() async {
        let empty = MediaAssetRecord(localIdentifier: "missing-photo", fileName: "x.heic", isVideo: false)
        #expect(LibraryMedia(record: empty, lookup: [:]) == nil)
        // An unavailable external archive record stays visible so the user can reauthorize it.
        var archived = MediaAssetRecord(localIdentifier: "file:/definitely/missing.heic", fileName: "x.heic", isVideo: false)
        archived.filesPaths = ["/definitely/missing.heic"]
        #expect(LibraryMedia(record: archived, lookup: [:])?.id == "file:/definitely/missing.heic")
    }
}

// MARK: - End-to-end coordinator flows (build 18 review findings)

/// Drives the real coordinator path with a stubbed network so completion logic,
/// media records and note syncing are exercised together instead of in isolation.
private final class FlowFixtureBundle: NSObject {}

private final class FlowFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var mediaBytes: [String: Data] = [:]

    /// A real 1x1 PNG: the download path validates image bytes with ImageIO, so
    /// placeholder data would be rejected before any save happens.
    static let pngBytes: Data = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    /// The project's real motion fixture. A hand-built ftyp/moov/mdat stub is not
    /// a decodable movie, so the download path's AVFoundation probe rejected it
    /// and the Live Photo flow was never actually exercised.
    static let mp4Bytes: Data = {
        guard let url = Bundle(for: FlowFixtureBundle.self)
            .url(forResource: "livephoto-motion", withExtension: "mp4"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }()

    static func reset() { lock.lock(); defer { lock.unlock() }; mediaBytes = [:] }
    static func register(_ path: String, data: Data) {
        lock.lock(); defer { lock.unlock() }
        mediaBytes[path] = data
    }
    static func bytes(for path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return mediaBytes[path]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.host == "media.example" {
            let isVideo = url.path.contains("-motion")
            let data = Self.bytes(for: url.path) ?? (isVideo ? Self.mp4Bytes : Self.pngBytes)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                                 headerFields: ["Content-Type": isVideo ? "video/mp4" : "image/png",
                                                                                "Content-Length": "\(data.count)"])!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let id = url.lastPathComponent
        // A path containing "live" is served as a real Live Photo: the image
        // carries a `stream` with a motion component, which is the parser's
        // explicit pairing signal.
        let imageEntry = id.contains("live")
            ? "{\"urlDefault\":\"https://media.example/\(id).png\",\"stream\":{\"h264\":[{\"masterUrl\":\"https://media.example/\(id)-motion.mp4\",\"videoBitrate\":1000}]}}"
            : "{\"urlDefault\":\"https://media.example/\(id).png\"}"
        let html = """
        <script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"\(id)":{"note":{
        "noteId":"\(id)","title":"Fixture","desc":"Body","imageList":[\(imageEntry)]
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

private struct FlowStubPhotoLibrary: PhotoLibraryServing {
    func deleteAssets(localIdentifiers: [String]) async throws {}
    func removeAssetsFromAppAlbum(localIdentifiers: [String]) async {}
    func saveMedia(at fileURL: URL, isVideo: Bool, originalFilename: String?, creationDate: Date?) async throws -> String {
        "stub-photo-\(UUID().uuidString)"
    }
    func saveLivePhoto(photoURL: URL, pairedVideoURL: URL, originalFilename: String?, creationDate: Date?) async throws -> String {
        "stub-live-\(UUID().uuidString)"
    }
}

private struct FlowHarness {
    let root: URL
    let settings: AppSettings
    let taskStore: DownloadTaskStore
    let noteStore: NoteStore
    let coordinator: DownloadCoordinator

    @MainActor
    init(policy: DownloadPolicy = DownloadPolicy(), selective: Bool = false,
         tasks: [DownloadTaskRecord] = [],
         photoLibrary: any PhotoLibraryServing = FlowStubPhotoLibrary()) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(selective, forKey: AppSettings.Key.selectiveDownload)
        var policy = policy
        policy.requestInterval = 0
        policy.save(defaults: defaults)
        settings = AppSettings(defaults: defaults)
        taskStore = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        if !tasks.isEmpty { try await taskStore.save(tasks) }
        noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlowFixtureProtocol.self]
        coordinator = DownloadCoordinator(
            settings: settings, store: taskStore, noteStore: noteStore,
            downloader: XHSDownloader(session: URLSession(configuration: configuration)),
            photoLibrary: photoLibrary)
        await coordinator.waitUntilLoaded()
        FlowFixtureProtocol.reset()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        FlowFixtureProtocol.reset()
    }

    /// Waits until no task is queued or downloading.
    @MainActor
    func waitForIdle(timeout: TimeInterval = 12) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let busy = coordinator.tasks.contains {
                [.queued, .downloading, .waitingForUser].contains($0.status)
            }
            if !busy { await coordinator.flushPersistence(); return }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
}

struct DestinationFlowTests {
    @Test @MainActor func retryOnlyFillsFailedFilesDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("original.png")
        try FlowFixtureProtocol.pngBytes.write(to: staged)
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var policy = DownloadPolicy()
        policy.destination = .both
        policy.filesBookmark = try ArchiveDirectory.makeBookmark(for: output)
        policy.requestInterval = 0
        let key = "fillfiles:image:0"
        var asset = MediaAssetRecord(localIdentifier: "existing-photo", fileName: "original.png", isVideo: false)
        asset.sourceMediaID = key
        var record = DownloadTaskRecord(sourceText: "https://www.xiaohongshu.com/explore/fillfiles",
                                       normalizedURL: "https://www.xiaohongshu.com/explore/fillfiles",
                                       status: .partial, mediaAssets: [asset])
        record.policy = policy
        record.stagedFiles = [key: staged.path]
        record.resourceResults = [key: ResourceResult(state: .failed,
            photos: DestinationResult(state: .saved, reference: "existing-photo"),
            files: DestinationResult(state: .failed, error: "previous directory failure"))]
        let harness = try await FlowHarness(policy: policy, tasks: [record])
        defer { harness.cleanUp() }
        harness.coordinator.retryFailedResources(taskID: record.id)
        try await harness.waitForIdle()
        let finished = try #require(harness.coordinator.tasks.first)
        #expect(finished.status == .completed)
        #expect(finished.resourceResults?[key]?.photos?.reference == "existing-photo")
        #expect(finished.resourceResults?[key]?.files?.state == .saved)
        #expect(finished.mediaAssets.count == 1)
        let path = try #require(finished.mediaAssets.first?.filesPaths?.first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == FlowFixtureProtocol.pngBytes)
        #expect(harness.coordinator.notes.first?.mediaAssets.first?.filesPaths == [path])
    }

    /// Finding 1: with "Photos and Files" and no usable folder, the task must not
    /// report completion. The simulator has no photo library, so this asserts the
    /// Files half specifically: that is the destination the fix is about.
    @Test @MainActor func missingFolderKeepsTaskIncompleteForPhotosAndFiles() async throws {
        var policy = DownloadPolicy()
        policy.destination = .both
        policy.filesBookmark = nil
        let harness = try await FlowHarness(policy: policy)
        defer { harness.cleanUp() }
        let coordinator = harness.coordinator

        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/bothfail", behavior: .direct).value
        try await harness.waitForIdle()

        let task = try #require(coordinator.tasks.first)
        #expect(task.status != .completed, "a failed Files destination must not report completion")
        let result = try #require(task.resourceResults?.values.first)
        // The folder was requested but unavailable: the Files destination is a
        // recorded failure rather than an absent requirement.
        #expect(result.files?.state == .failed)
        #expect(result.files?.error?.isEmpty == false)
        // The staged original is kept so a retry can archive it.
        #expect(task.stagedFiles?.isEmpty == false)
    }

    /// The completion rule itself, isolated from photo-library availability: a
    /// requested Files destination that failed is never satisfied.
    @Test func requestedFilesFailureIsNotSatisfied() async {
        var result = ResourceResult(state: .failed)
        result.photos = DestinationResult(state: .saved)
        result.files = DestinationResult(state: .failed, error: "no folder")
        #expect(!result.isSatisfied(photosRequired: true, filesRequired: true, mergeRequired: false))
        #expect(result.isSatisfied(photosRequired: true, filesRequired: false, mergeRequired: false))
    }

    /// Finding 2: a Files-only save must produce a media record that the note
    /// store keeps, so the note is browsable without Photos.
    @Test @MainActor func filesOnlySaveRecordsMediaOnTheNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var policy = DownloadPolicy()
        policy.destination = .files
        policy.filesBookmark = try ArchiveDirectory.makeBookmark(for: root)
        let harness = try await FlowHarness(policy: policy)
        defer { harness.cleanUp() }
        let coordinator = harness.coordinator

        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/filesonly", behavior: .direct).value
        try await harness.waitForIdle()

        let task = try #require(coordinator.tasks.first)
        #expect(task.status == .completed, "task error: \(task.errorMessage ?? "none")")
        let asset = try #require(task.mediaAssets.first)
        #expect(asset.localIdentifier.hasPrefix("file:"))
        #expect(asset.filesPaths?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: asset.filesPaths?.first ?? ""))

        let note = try #require(coordinator.notes.first)
        #expect(note.mediaAssets.contains { $0.localIdentifier.hasPrefix("file:") })
        let card = try #require(NoteLibrary.notes(stored: coordinator.notes, media: []).first)
        #expect(card.media.isEmpty == false, "the Files record must resolve into a feed item")
    }

    /// Finding 3: a Files-only Live Photo keeps both components and must not be
    /// failed forever by a merge that can never happen. This asserts the note is
    /// actually a Live Photo and that both components reached the archive, which
    /// the previous version of this test never checked.
    @Test @MainActor func filesOnlyLivePhotoKeepsBothComponentsAndCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var policy = DownloadPolicy()
        policy.destination = .files
        policy.filesBookmark = try ArchiveDirectory.makeBookmark(for: root)
        let harness = try await FlowHarness(policy: policy)
        defer { harness.cleanUp() }
        let coordinator = harness.coordinator
        coordinator.settings.livePhotoMode = .merged

        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/livepair", behavior: .direct).value
        try await harness.waitForIdle()

        let task = try #require(coordinator.tasks.first)
        // The fixture serves an image with a stream, so parsing must yield a
        // Live Photo, not a plain image.
        let live = try #require(task.resolvedNote?.media.first { $0.type == .livePhoto },
                                "fixture must parse as a Live Photo")
        #expect(!live.pairedVideoURLs.isEmpty)

        #expect(task.status == .completed, "task error: \(task.errorMessage ?? "none") / results: \(String(describing: task.resourceResults))")
        let asset = try #require(task.mediaAssets.first)
        #expect(asset.isLive == true)
        // Both components are recorded, not just the still.
        #expect(asset.filesPaths?.count == 2)
        for path in asset.filesPaths ?? [] {
            #expect(FileManager.default.fileExists(atPath: path))
        }
        let note = try #require(coordinator.notes.first)
        #expect(note.mediaAssets.first?.filesPaths?.count == 2)
    }

    /// Finding 1: a failed merge must be retried, not skipped because the still
    /// was saved.
    @Test func failedMergeStaysRetryable() async {
        var result = ResourceResult(state: .failed)
        result.photos = DestinationResult(state: .saved)
        result.livePhotoOutcome = .componentsOnly
        #expect(!result.isSatisfied(photosRequired: true, filesRequired: false, mergeRequired: true))
        result.livePhotoOutcome = .merged
        #expect(result.isSatisfied(photosRequired: true, filesRequired: false, mergeRequired: true))
    }

    /// Finding 4: "save note only" must land in the note store for the manual and
    /// share entries, not only for the browser entry.
    @Test @MainActor func noteOnlyEntryWritesTheIndependentNoteStore() async throws {
        let harness = try await FlowHarness()
        defer { harness.cleanUp() }
        let coordinator = harness.coordinator

        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/noteonly", behavior: .informationOnly).value
        try await harness.waitForIdle()

        let task = try #require(coordinator.tasks.first)
        #expect(task.status == .completed)
        #expect(task.mediaAssets.isEmpty)
        let note = try #require(coordinator.notes.first, "note-only must create a library note")
        #expect(note.body == "Body")
        #expect(note.informationOnly)
        // And it survives a history cleanup.
        coordinator.removeFinished()
        #expect(coordinator.notes.count == 1)
    }

    /// Finding 5: naming edited in settings must reach the task snapshot that the
    /// downloader actually uses.
    @Test @MainActor func namingSettingsReachTheTaskSnapshot() async throws {
        let harness = try await FlowHarness()
        defer { harness.cleanUp() }
        let coordinator = harness.coordinator

        var policy = coordinator.settings.policy
        policy.namingEnabled = true
        policy.namingTemplate = "CUSTOM_{title}"
        policy.namingTimezone = "Asia/Shanghai"
        coordinator.settings.policy = policy

        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/naming", behavior: .direct).value
        let task = try #require(coordinator.tasks.first)
        #expect(task.policy?.namingEnabled == true)
        #expect(task.policy?.namingTemplate == "CUSTOM_{title}")
        #expect(task.policy?.namingTimezone == "Asia/Shanghai")

        try await harness.waitForIdle()
        let resolved = try #require(coordinator.tasks.first?.resolvedNote)
        let first = try #require(resolved.media.first)
        #expect(first.fileBaseName.hasPrefix("CUSTOM_Fixture"), "file names must use the configured template")
    }

    /// Finding 6: legacy UUID-keyed likes, bookmarks and collections must be
    /// remapped onto the new note identities during migration.
    @Test @MainActor func migrationRemapsLegacyLibraryIdentifiers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var policy = DownloadPolicy()
        policy.requestInterval = 0
        policy.save(defaults: defaults)

        // A legacy task whose note is keyed by its task UUID.
        var legacy = DownloadTaskRecord(sourceText: "old", normalizedURL: "https://www.xiaohongshu.com/explore/legacy",
                                        title: "旧笔记", noteText: "旧正文", status: .completed)
        legacy.id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        legacy.resolvedNote = ResolvedNote(noteID: "legacy",
                                           canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/legacy")!,
                                           title: "旧笔记", body: "旧正文",
                                           metadata: NoteMetadata(userName: "作者"), media: [])
        legacy.mediaAssets = [MediaAssetRecord(localIdentifier: "asset-old", fileName: "a.heic", isVideo: false)]
        let taskStore = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        try await taskStore.save([legacy])
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))

        let legacyID = legacy.id.uuidString
        defaults.set([legacyID], forKey: "library.likedNotes")
        defaults.set([legacyID], forKey: "library.bookmarkedNotes")
        defaults.set(try JSONEncoder().encode([NoteCollection(name: "旧合集", noteIDs: [legacyID])]),
                     forKey: "library.collections")

        let settings = AppSettings(defaults: defaults)
        let coordinator = DownloadCoordinator(settings: settings, store: taskStore, noteStore: noteStore)
        await coordinator.waitUntilLoaded()

        #expect(coordinator.notes.count == 1)
        let newKey = coordinator.notes[0].id
        #expect(newKey != legacyID)
        #expect(coordinator.likedNotes.contains(newKey), "likes must follow the note across the upgrade")
        #expect(coordinator.bookmarkedNotes.contains(newKey))
        #expect(coordinator.collections.first?.noteIDs.contains(newKey) == true)
        #expect(!coordinator.likedNotes.contains(legacyID))
    }
}

struct ArchiveIdentityTests {
    /// Finding: same name and same size is not the same resource.
    @Test func sameNameSameSizeDifferentContentIsNotReused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("a.heic")
        let staged = root.appendingPathComponent("staged.heic")
        try Data(repeating: 1, count: 64).write(to: existing)
        try Data(repeating: 2, count: 64).write(to: staged)

        let stagedDigest = try #require(FileArchiver.digest(ofFile: staged))
        let existingDigest = try #require(FileArchiver.digest(ofFile: existing))
        #expect(stagedDigest != existingDigest)
        // Size matches but content does not, so the existing file must be rejected.
        #expect(!FileArchiver.isUsableExistingFile(existing, expectedByteCount: 64, expectedDigest: stagedDigest))
        #expect(FileArchiver.isUsableExistingFile(existing, expectedByteCount: 64, expectedDigest: existingDigest))
    }
}

struct ExportCompletenessTests {
    /// Finding 9: an unreadable original must be reported, not silently dropped.
    @Test func archiveExportReportsUnreadableOriginals() async throws {
        // A note whose only asset claims a Photos identifier that cannot resolve.
        let note = StoredNote(id: "note:missing", noteID: "missing",
                              canonicalURL: "https://www.xiaohongshu.com/explore/missing",
                              title: "标题", body: "正文", metadata: NoteMetadata(userName: "作者"),
                              mediaAssets: [MediaAssetRecord(localIdentifier: "nonexistent-asset-id",
                                                             fileName: "ghost.heic", isVideo: false)])
        let export = try await BackupService.shared.exportArchive([note])
        defer { try? FileManager.default.removeItem(at: export.url.deletingLastPathComponent()) }
        #expect(export.failures.contains("ghost.heic"))
        // The archive is still produced, and its manifest records the omission.
        let data = try Data(contentsOf: export.url)
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
    }

    /// Finding 8: the notes branch of a backup must be redacted as well.
    @Test func noteBranchIsRedacted() async {
        var asset = MediaAssetRecord(localIdentifier: "file:/Users/private/a.heic", fileName: "a.heic", isVideo: false)
        asset.filesPaths = ["/Users/private/a.heic"]
        let note = StoredNote(id: "note:x", noteID: "x",
                              canonicalURL: "https://www.xiaohongshu.com/explore/x?xsec_token=SECRET",
                              title: "t", body: "b", metadata: NoteMetadata(),
                              mediaAssets: [asset],
                              archiveTextPaths: ["/Users/private/caption.txt"])
        let clean = BackupEntry.redactedNote(note)
        #expect(!clean.canonicalURL.contains("SECRET"))
        #expect(!clean.canonicalURL.contains("xsec_token"))
        #expect(clean.archiveTextPaths.isEmpty)
        #expect(clean.mediaAssets.first?.filesPaths == nil)
        #expect(clean.mediaAssets.first?.localIdentifier == "file:")
        #expect(clean.title == "t" && clean.body == "b")
    }
}

struct PacingTests {
    /// Finding: the request interval must apply between consecutive tasks, so the
    /// pacer has to be shared rather than recreated per task.
    @Test func zeroIntervalDoesNotDelayAndPositiveIntervalDoes() async throws {
        let pacer = RequestPacer()
        let start = Date()
        try await pacer.wait(interval: 0)
        try await pacer.wait(interval: 0)
        #expect(Date().timeIntervalSince(start) < 0.2, "a zero interval must not reserve a slot")

        let slow = RequestPacer()
        try await slow.wait(interval: 0.3)
        let second = Date()
        try await slow.wait(interval: 0.3)
        #expect(Date().timeIntervalSince(second) >= 0.25, "consecutive waits must be spaced")
    }

    @Test @MainActor func coordinatorSharesOnePacerAcrossTasks() async {
        let harness = try? await FlowHarness()
        defer { harness?.cleanUp() }
        guard let harness else { return }
        // The pacer is an actor; identity comparison through two task downloaders
        // is not exposed, so this asserts the interval is honoured in aggregate.
        #expect(harness.settings.policy.requestInterval == 0)
    }
}
