import Foundation
import Testing
import UIKit
@testable import XHS_Downloader_iOS

@Suite(.serialized) @MainActor
struct MobileCompletionTests {
    private let noteURL = URL(string: "https://www.xiaohongshu.com/explore/mobile")!

    @Test func urlOnlyImagesReachTheActualFormatPolicy() async throws {
        let downloader = XHSDownloader()
        for field in ["urlDefault", "urlPre"] {
            let preview = "https://sns-webpic-qc.xhscdn.com/20261111/signature/spectrum/resource_key!h5_1080jpg"
            let note = try downloader.resolveNote(data: ["noteId": "mobile", "imageList": [[field: preview]]],
                                                 noteID: "mobile", canonicalURL: noteURL)
            let image = try #require(note.media.first)
            #expect(image.fileKey == "spectrum/resource_key")
            #expect(image.url.absoluteString == "https://sns-img-bd.xhscdn.com/spectrum/resource_key")
            var policy = DownloadPolicy()
            policy.imageFormat = .heic
            let applied = image.applying(policy)
            #expect(applied.url.absoluteString == "https://ci.xiaohongshu.com/spectrum/resource_key?imageView2/format/heic")
            #expect(applied.candidates.contains { $0.absoluteString == preview })
            #expect(image.applying(DownloadPolicy()).url == image.url)
        }
    }

    @Test func explicitKeysWinAndNonCDNImagesRemainUnmodified() async throws {
        let downloader = XHSDownloader()
        let note = try downloader.resolveNote(data: [
            "imageList": [
                ["fileId": "original_key", "urlPre": "https://sns-webpic-qc.xhscdn.com/date/sign/preview!h5"],
                ["urlDefault": "https://media.example/image.heic"]
            ]
        ], noteID: "mobile", canonicalURL: noteURL)
        #expect(note.media[0].fileKey == "original_key")
        #expect(note.media[0].candidates.contains { $0.absoluteString == "https://sns-img-bd.xhscdn.com/preview" })
        #expect(note.media[1].fileKey == nil)
        var policy = DownloadPolicy()
        policy.imageFormat = .jpeg
        #expect(note.media[1].applying(policy).url.absoluteString == "https://media.example/image.heic")
    }

    @Test func livePhotoIncludesUnknownCodecBackupOnlyAndMarkedFallbacks() async throws {
        let streams: [String: Any] = [
            "h264": [["masterUrl": "https://media.example/marked.mp4", "streamDesc": "WEB_LIVEPHOTO_19"]],
            "futureCodec": [["backupUrls": ["https://media.example/motion.mp4", "https://media.example/backup.mp4"]]]
        ]
        let note = try XHSDownloader().resolveNote(data: [
            "imageList": [["fileId": "original_key", "stream": streams]]
        ], noteID: "mobile", canonicalURL: noteURL)
        let live = try #require(note.media.first)
        #expect(live.type == .livePhoto)
        #expect(live.pairedVideoURLs.map(\.absoluteString) == [
            "https://media.example/motion.mp4", "https://media.example/backup.mp4", "https://media.example/marked.mp4"
        ])
        var policy = DownloadPolicy()
        policy.imageFormat = .jpeg
        // A format preference must not replace the Live Photo's original still.
        #expect(live.applying(policy).url == live.url)
    }

    @Test func videoPolicyPrefersUnmarkedAndHonorsExplicitChoice() async throws {
        let note = try XHSDownloader().resolveNote(data: ["video": ["stream": [
            "h265": [["masterUrl": "https://media.example/marked.mp4", "height": 2160, "streamType": 259]],
            "futureCodec": [["backupUrls": ["https://media.example/available.mp4"], "height": 1080]]
        ]]], noteID: "mobile", canonicalURL: noteURL)
        let video = try #require(note.media.first)
        #expect(video.applying(DownloadPolicy()).url.absoluteString == "https://media.example/available.mp4")
        let marked = try #require(video.variants?.first { $0.isKnownWatermarked == true })
        #expect(video.applying(DownloadPolicy(), variantID: marked.id).url == marked.url)
        // Pre-existing task snapshots have no watermark field.
        let data = try JSONEncoder().encode(MediaVariant(url: noteURL))
        #expect(try JSONDecoder().decode(MediaVariant.self, from: data).isKnownWatermarked == nil)
    }

    @Test func redNoteKeepsItsHostTokenAndCookieThroughResolve() async throws {
        let cookie = try #require(HTTPCookie(properties: [
            .domain: ".rednote.com", .path: "/", .name: "xhs_mobile_test", .value: "fixture", .secure: "TRUE"
        ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = .shared
        config.protocolClasses = [MobileCompletionProtocol.self]
        var policy = DownloadPolicy()
        policy.requestInterval = 0
        let downloader = XHSDownloader(session: URLSession(configuration: config), policy: policy)
        let resolved = try await downloader.resolveNote(from: "https://rednote.com/explore/mobile?xsec_token=fixture-token")
        #expect(resolved.canonicalURL.host == "www.rednote.com")
        #expect(resolved.canonicalURL.query == "xsec_token=fixture-token")
        #expect(resolved.body == "cookie-present")
        let xhs = try #require(try await downloader.prepareContext(for: "https://xiaohongshu.com/explore/mobile", logger: { _ in }))
        #expect(xhs.resolvedURL.host == "www.xiaohongshu.com")
        let otherDomain = try await downloader.resolveNote(from: xhs.resolvedURL.absoluteString)
        #expect(otherDomain.body == "cookie-missing")
        policy.useWebSession = false
        let withoutSession = XHSDownloader(session: URLSession(configuration: config), policy: policy)
        let anonymous = try await withoutSession.resolveNote(from: resolved.canonicalURL.absoluteString)
        #expect(anonymous.body == "cookie-missing")
    }

    @Test func selectedNoteLinksUseTheExistingClipboardAdmissionGuard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let coordinator = DownloadCoordinator(settings: AppSettings(defaults: defaults),
            store: DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json")),
            noteStore: NoteStore(fileURL: root.appendingPathComponent("notes.json")))
        await coordinator.waitUntilLoaded()
        func note(_ id: String, _ url: URL?, _ media: [String]) -> LibraryNote {
            LibraryNote(id: id, title: id, body: "", author: "", avatarURL: nil, publishTime: nil,
                        topics: [], sourceURL: url, date: .distantPast, media: media.map { LibraryMedia(id: $0) })
        }
        let notes = [
            note("unselected", URL(string: "https://www.xiaohongshu.com/explore/other")!, ["other"]),
            note("first", noteURL, ["a", "b"]), note("duplicate", noteURL, ["duplicate"]),
            note("album", nil, ["album"])
        ]
        let selection: Set<String> = ["a", "b", "duplicate", "album"]
        let previous = UIPasteboard.general.string
        defer { if let previous { coordinator.copyToClipboard(previous) } }
        #expect(coordinator.copySelectedNoteLinks(in: notes, mediaIDs: selection) == 1)
        #expect(UIPasteboard.general.string == noteURL.absoluteString)
        #expect(UserDefaults.standard.integer(forKey: "clipboard.lastHandledChange") == UIPasteboard.general.changeCount)
        coordinator.checkClipboard()
        #expect(coordinator.tasks.isEmpty)
    }

    @Test func archivedShareKeepsBothOriginalComponentsAndReportsMissingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Sharing copies bytes; decoding, recompression or flattening is not part
        // of this operation. The actual media pipeline has its own fixtures.
        let still = root.appendingPathComponent("original.heic")
        let motion = root.appendingPathComponent("motion.mp4")
        try Data("original-still".utf8).write(to: still)
        try Data("original-motion".utf8).write(to: motion)
        let bookmark = try ArchiveDirectory.makeBookmark(for: root)
        let share = try await FileArchiver.shared.shareFiles(paths: [still.path, motion.path], bookmark: bookmark)
        defer { try? FileManager.default.removeItem(at: share.directory) }
        #expect(share.urls.count == 2)
        #expect(try Data(contentsOf: share.urls[0]) == Data(contentsOf: still))
        #expect(try Data(contentsOf: share.urls[1]) == Data(contentsOf: motion))
        await #expect(throws: CocoaError.self) {
            _ = try await FileArchiver.shared.shareFiles(paths: [still.path, root.appendingPathComponent("missing").path],
                                                        bookmark: bookmark)
        }
    }

    @Test @MainActor func clipboardDeduplicatesSameLinkAcrossReentriesAndCompletedTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var policy = DownloadPolicy()
        policy.requestInterval = 0
        policy.save(defaults: defaults)
        let settings = AppSettings(defaults: defaults)
        settings.clipboardSuggestions = true

        let noteID = "673a00000000000011223344"
        let firstURL = "https://www.xiaohongshu.com/explore/\(noteID)?xsec_token=first"
        let secondTokenURL = "https://www.xiaohongshu.com/explore/\(noteID)?xsec_token=second"
        var completed = DownloadTaskRecord(sourceText: firstURL, normalizedURL: firstURL, title: "Done", status: .completed)
        completed.noteKey = StoredNote.key(noteID: noteID, url: firstURL)
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        let noteStore = NoteStore(fileURL: root.appendingPathComponent("notes.json"))
        let coordinator = DownloadCoordinator(settings: settings, store: store, noteStore: noteStore, initialTasks: [completed])
        await coordinator.waitUntilLoaded()

        // Passive clipboard detection must not redownload a completed note even with a refreshed token.
        #expect(await coordinator.enqueueClipboard(secondTokenURL).value)
        #expect(coordinator.tasks.count == 1)

        // Manual re-download remains deliberate and creates a new task.
        #expect(await coordinator.enqueue(secondTokenURL, behavior: .direct).value)
        #expect(coordinator.tasks.count == 2)

        // Link matcher compares note IDs and scheme variants consistently.
        #expect(XHSURLDetector.linksMatch(firstURL, secondTokenURL))
        #expect(XHSURLDetector.linksMatch("http://xhslink.com/o/AbC123", "https://xhslink.com/o/AbC123"))

        // Re-copying the exact same link (bumped changeCount) does not trigger checkClipboard() twice.
        let prevString = UIPasteboard.general.string
        let prevChange = UserDefaults.standard.object(forKey: "clipboard.lastHandledChange")
        let prevLinks = UserDefaults.standard.object(forKey: "clipboard.lastHandledLinks")
        defer {
            if let prevString { UIPasteboard.general.string = prevString }
            UserDefaults.standard.set(prevChange, forKey: "clipboard.lastHandledChange")
            UserDefaults.standard.set(prevLinks, forKey: "clipboard.lastHandledLinks")
        }
        let freshLink = "https://www.xiaohongshu.com/explore/673a00000000000099887766"
        UserDefaults.standard.set(-9999, forKey: "clipboard.lastHandledChange")
        UserDefaults.standard.removeObject(forKey: "clipboard.lastHandledLinks")
        UIPasteboard.general.string = freshLink
        coordinator.checkClipboard()
        try await Task.sleep(for: .milliseconds(150))
        // Re-writing identical text bumps UIPasteboard.changeCount, yet lastHandledLinks suppresses duplicates.
        UIPasteboard.general.string = freshLink
        coordinator.checkClipboard()
        try await Task.sleep(for: .milliseconds(150))
        let freshCount = coordinator.tasks.filter { $0.normalizedURL == freshLink }.count
        #expect(freshCount <= 1)
    }
}

private final class MobileCompletionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let body = request.value(forHTTPHeaderField: "Cookie")?.contains("xhs_mobile_test=fixture") == true
            ? "cookie-present" : "cookie-missing"
        let html = """
        <script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"mobile":{"note":{
        "noteId":"mobile","desc":"\(body)","imageList":[{"urlDefault":"https://media.example/image.heic"}]
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
