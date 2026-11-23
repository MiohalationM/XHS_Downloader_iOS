import Foundation
import Testing
import SwiftUI
import ImageIO
import UIKit
import WebKit
@testable import XHS_Downloader_iOS

struct NoteLibraryTests {
    @Test(arguments: [-35.0, 45.0])
    func recatchingHorizontalReturnPreservesVerticalTravel(drift: Double) {
        // A 100pt rightward drag at scale 0.945, with both upward and downward drift.
        let translation = NoteHeroDragGeometry.resumedTranslation(
            frame: CGRect(x: 111, y: 211 + drift, width: 378, height: 378),
            expanded: CGRect(x: 0, y: 200, width: 400, height: 400),
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800),
            anchor: CGPoint(x: 200, y: 400), horizontal: true)
        #expect(abs(translation.x - 100) < 0.001)
        #expect(abs(translation.y - drift) < 0.001)
    }

    @Test func recatchingReturnPreservesTheOffCenterTouchAnchor() {
        let translation = NoteHeroDragGeometry.resumedTranslation(
            frame: CGRect(x: 105.5, y: 250.5, width: 378, height: 378),
            expanded: CGRect(x: 0, y: 200, width: 400, height: 400),
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800),
            anchor: CGPoint(x: 100, y: 300), horizontal: true)
        #expect(abs(translation.x - 100) < 0.001)
        #expect(abs(translation.y - 45) < 0.001)
    }

    @Test func recatchingVerticalReturnPreservesHorizontalTravel() {
        let translation = NoteHeroDragGeometry.resumedTranslation(
            frame: CGRect(x: 66, y: 386, width: 348, height: 348),
            expanded: CGRect(x: 0, y: 200, width: 400, height: 400),
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800),
            anchor: CGPoint(x: 200, y: 400), horizontal: false)
        #expect(abs(translation.x - 40) < 0.001)
        #expect(abs(translation.y - 160) < 0.001)
    }

    @Test(arguments: [true, false])
    func publishedSortingUsesTheTimestampRatherThanSaveOrderWithinTheSameDay(useStoredNotes: Bool) {
        let morning = Date(timeIntervalSince1970: 1794358800)
        let evening = morning.addingTimeInterval(3600 * 8)
        func stored(_ id: String, published: Date, saved: Date) -> StoredNote {
            var metadata = NoteMetadata(userName: "author", publishTime: "26-11-11")
            metadata.publishedAt = published
            return StoredNote(id: id, noteID: id, canonicalURL: "https://example.com/\(id)",
                              title: id, body: "body", metadata: metadata, createdAt: saved)
        }
        let earlier = stored("earlier", published: morning, saved: evening)
        let later = stored("later", published: evening, saved: morning)
        let cards: [LibraryNote]
        if useStoredNotes {
            cards = NoteLibrary.notes(stored: [earlier, later], media: [])
        } else {
            let tasks = [earlier, later].map { note in
                var task = DownloadTaskRecord(sourceText: "", normalizedURL: note.canonicalURL,
                                              title: note.title, noteText: note.body, status: .completed)
                task.createdAt = note.createdAt
                task.resolvedNote = ResolvedNote(noteID: note.id, canonicalURL: URL(string: note.canonicalURL)!,
                                                 title: note.title, body: note.body, metadata: note.metadata, media: [])
                return task
            }
            cards = NoteLibrary.notes(tasks: tasks, media: [])
        }
        #expect(NoteLibrary.sorted(cards, by: .publishedNewest).map(\.title) == ["later", "earlier"])
    }

    @Test func publishedSortingSupportsLegacyDaysAndUsesSavedDateWhenMissing() {
        let saved = Date(timeIntervalSince1970: 0)
        func note(_ id: String, _ day: String?) -> LibraryNote {
            LibraryNote(id: id, title: id, body: "", author: "a", avatarURL: nil,
                        publishTime: day, topics: [], sourceURL: nil, date: saved, media: [])
        }
        let notes = [note("b", "26-11-11"), note("missing", nil), note("a", "2026-11-11"), note("old", "26-11-10")]
        #expect(NoteLibrary.sorted(notes, by: .publishedNewest).map(\.id) == ["a", "b", "old", "missing"])
    }

    @Test func titleRemainsVisibleWhenTheReplacementHasNoLayout() async {
        let frame = CGRect(x: 10, y: 100, width: 180, height: 42)
        #expect(!NoteHeroTitleVisibility.canTransfer(source: frame, destination: nil, text: "两行标题"))
        #expect(!NoteHeroTitleVisibility.canTransfer(source: .zero, destination: frame, text: "标题"))
        #expect(NoteHeroTitleVisibility.canTransfer(source: frame, destination: frame, text: "两行标题"))
    }

    @Test @MainActor func cookiesSynchronizeEvenBeforeThePageHasAccountState() async throws {
        let name = "xhs_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let cookie = try #require(HTTPCookie(properties: [
            .domain: ".xiaohongshu.com", .path: "/", .name: name,
            .value: "fixture", .secure: "TRUE"
        ]))
        let store = WebSession.shared.dataStore.httpCookieStore
        await store.setCookie(cookie)
        await WebSession.shared.captureAccount(from: WKWebView())
        let saved = HTTPCookieStorage.shared.cookies?.contains { $0.name == name && $0.value == "fixture" } == true
        await store.deleteCookie(cookie)
        HTTPCookieStorage.shared.deleteCookie(cookie)
        #expect(saved)
    }

    @Test func rightwardReturnDoesNotRequireAnEdgeAndLeavesVerticalScrollingAlone() async {
        #expect(NoteHeroReturnDirection.isHorizontal(CGPoint(x: 260, y: 40)))
        #expect(!NoteHeroReturnDirection.isHorizontal(CGPoint(x: -260, y: 40)))
        #expect(!NoteHeroReturnDirection.isHorizontal(CGPoint(x: 40, y: 260)))
        #expect(!NoteHeroReturnDirection.isHorizontal(.zero))
    }

    @Test @MainActor func landedCardIsClippedBelowTheFeedHeader() async throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 420, height: 912))
        let geometry = NoteHeroGeometry()
        geometry.register(CGRect(x: 220, y: -80, width: 192, height: 480), role: "card", id: "note")
        geometry.register(CGRect(x: 0, y: 160, width: 420, height: 680), role: "scroll", id: "feed")
        let visible = try #require(geometry.visibleCardFrame("note", in: container))
        #expect(visible.minY == 160)
        #expect(visible.maxY == 400)
        #expect(visible.width == 192)
    }

    @Test @MainActor func translucentHeaderStaysAboveReturnStageAndExtendsVisibleCard() async throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 420, height: 912))
        let geometry = NoteHeroGeometry()
        geometry.register(CGRect(x: 12, y: -60, width: 192, height: 440), role: "card", id: "note")
        geometry.register(CGRect(x: 0, y: 0, width: 420, height: 912), role: "scroll", id: "feed")
        let visible = try #require(geometry.visibleCardFrame("note", in: container))
        #expect(visible.minY == 0)
        #expect(visible.maxY == 380)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = container.bounds
        let tabs = UITabBarController()
        let feedVC = UIViewController()
        feedVC.tabBarItem = UITabBarItem(title: "笔记", image: UIImage(systemName: "photo"), tag: 1)
        tabs.viewControllers = [feedVC]
        window.rootViewController = tabs
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        tabs.view.layoutIfNeeded()

        var chrome: UIView = tabs.tabBar
        while let ancestor = chrome.superview, ancestor !== tabs.view { chrome = ancestor }
        let overlay = UIView(frame: window.bounds)
        window.addSubview(overlay)
        let headerOverlay = UIView()
        let foreground = try #require(NoteHeroFeedForeground(presenting: tabs, in: overlay, header: headerOverlay))
        let stage = UIView(frame: overlay.bounds)
        foreground.insert(stage, convertingFrom: overlay)
        defer { foreground.restore(); stage.removeFromSuperview() }

        let stageIndex = try #require(tabs.view.subviews.firstIndex(of: stage))
        let headerIndex = try #require(tabs.view.subviews.firstIndex(of: headerOverlay))
        let barIndex = try #require(tabs.view.subviews.firstIndex(of: chrome))
        #expect(stageIndex < headerIndex)
        #expect(headerIndex < barIndex)
        foreground.alpha = 0.5
        #expect(headerOverlay.alpha == 0.5)
        foreground.restore()
        #expect(headerOverlay.superview == nil)
    }

    @Test @MainActor func preparedStillCannotBeReplacedByASmallerImage() async throws {
        let cache = MediaPreviewImages()
        let sharp = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160)).image { _ in }
        let small = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 16)).image { _ in }
        cache.insert(sharp, for: "asset")
        cache.insert(small, for: "asset")
        #expect(cache.image(for: "asset") === sharp)
        let geometry = NoteHeroGeometry()
        let view = UIImageView(image: small)
        geometry.register(view, role: "image", id: "asset")
        geometry.adoptStill(sharp, for: "asset")
        #expect(view.image === sharp)
    }

    @Test @MainActor func loginBrowserRequestsDesktopContentBeforeLoading() async {
        let model = BrowserModel()
        #expect(model.webView.configuration.defaultWebpagePreferences.preferredContentMode == .desktop)
        #expect(model.webView.customUserAgent?.contains("Macintosh") == true)
        #expect(model.webView.customUserAgent?.contains("Mobile/") == false)
        #expect(model.webView.url == nil)
    }

    @Test @MainActor func returnStageStaysBelowWholeNativeTabBarAndRestoresItsAppearance() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 420, height: 912)
        let tabs = UITabBarController()
        tabs.viewControllers = ["下载", "笔记", "设置"].enumerated().map { index, title in
            let controller = UIViewController()
            controller.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: "circle"), tag: index)
            return controller
        }
        tabs.selectedIndex = 1
        window.rootViewController = tabs
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        tabs.view.layoutIfNeeded()
        let parent = try #require(tabs.tabBar.superview)
        var chrome: UIView = tabs.tabBar
        while let ancestor = chrome.superview, ancestor !== tabs.view { chrome = ancestor }
        let originalAlpha = chrome.alpha
        let originalFrame = tabs.tabBar.frame
        let overlay = UIView(frame: window.bounds)
        window.addSubview(overlay)
        let foreground = try #require(NoteHeroFeedForeground(presenting: tabs, in: overlay))
        let stage = UIView(frame: overlay.bounds)
        foreground.insert(stage, convertingFrom: overlay)
        defer { foreground.restore(); stage.removeFromSuperview() }

        #expect(stage.superview === tabs.view)
        let stageIndex = try #require(tabs.view.subviews.firstIndex(of: stage))
        let barIndex = try #require(tabs.view.subviews.firstIndex(of: chrome))
        #expect(stageIndex < barIndex)
        // The stage must also be above the feed, rather than behind a shared
        // wrapper that would conceal the transition along with its content.
        var content = try #require(tabs.selectedViewController?.view)
        while let ancestor = content.superview, ancestor !== tabs.view { content = ancestor }
        let contentIndex = try #require(tabs.view.subviews.firstIndex(of: content))
        #expect(contentIndex < stageIndex)
        #expect(tabs.tabBar.superview === parent)
        #expect(tabs.tabBar.frame == originalFrame)
        #expect(tabs.tabBar.items?.count == 3 && tabs.selectedIndex == 1)
        #expect(stage.convert(stage.bounds, to: window) == overlay.convert(overlay.bounds, to: window))
        let page = UIView(frame: stage.bounds)
        stage.addSubview(page)
        let receiver = UIView(frame: CGRect(x: 120, y: 300, width: 100, height: 100))
        page.addSubview(receiver)
        let input = NoteHeroTransitionInput(frame: overlay.bounds)
        input.target = page
        overlay.addSubview(input)
        stage.transform = CGAffineTransform(translationX: 30, y: 80).scaledBy(x: 0.8, y: 0.8)
        let heldPoint = receiver.convert(CGPoint(x: 50, y: 50), to: window)
        #expect(window.hitTest(heldPoint, with: nil) === receiver)
        // The visible native tab bar must not receive taps during a gesture.
        let emptyPoint = CGPoint(x: 1, y: 1)
        #expect(window.hitTest(emptyPoint, with: nil) === input)
        foreground.alpha = 0
        #expect(chrome.alpha == 0)
        foreground.alpha = 0.5
        #expect(chrome.alpha == originalAlpha * 0.5)
        foreground.restore()
        #expect(chrome.alpha == originalAlpha)
        #expect(tabs.tabBar.superview === parent && tabs.tabBar.frame == originalFrame)
    }

    @Test @MainActor func returnGestureLocksNestedScrollingAndRestoresEachOriginalState() async {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 420, height: 912))
        let body = UIScrollView(frame: root.bounds)
        body.contentSize = CGSize(width: 420, height: 1800)
        body.contentOffset = CGPoint(x: 0, y: 180)
        body.showsHorizontalScrollIndicator = false
        root.addSubview(body)
        let pager = UIScrollView(frame: CGRect(x: 0, y: 180, width: 420, height: 550))
        pager.contentSize = CGSize(width: 840, height: 550)
        pager.contentOffset = CGPoint(x: 420, y: 0)
        pager.showsVerticalScrollIndicator = false
        body.addSubview(pager)
        let disabled = UIScrollView(frame: pager.bounds)
        disabled.isScrollEnabled = false
        pager.addSubview(disabled)

        let lock = NoteHeroScrollLock(in: root)
        #expect(!body.isScrollEnabled && !pager.isScrollEnabled && !disabled.isScrollEnabled)
        #expect(!body.showsVerticalScrollIndicator && !pager.showsHorizontalScrollIndicator)
        #expect(body.contentOffset == CGPoint(x: 0, y: 180))
        #expect(pager.contentOffset == CGPoint(x: 420, y: 0))
        lock.restore()
        #expect(body.isScrollEnabled && pager.isScrollEnabled && !disabled.isScrollEnabled)
        #expect(body.showsVerticalScrollIndicator && !body.showsHorizontalScrollIndicator)
        #expect(!pager.showsVerticalScrollIndicator && pager.showsHorizontalScrollIndicator)
        #expect(body.contentOffset == CGPoint(x: 0, y: 180))
        #expect(pager.contentOffset == CGPoint(x: 420, y: 0))
        // A later normal scroll must not be undone by releasing the old lock twice.
        body.contentOffset.y = 240
        lock.restore()
        #expect(body.contentOffset.y == 240)
    }

    @Test func groupsSavedNoteInOriginalOrderAndRetainsOrphanPhotos() async {
        let media = [LibraryMedia(id: "third", isLive: true), LibraryMedia(id: "first"), LibraryMedia(id: "orphan")]
        var task = DownloadTaskRecord(sourceText: "", normalizedURL: "https://www.xiaohongshu.com/explore/test", title: "日常随拍", noteText: "一段完整的文案")
        task.mediaAssets = ["first", "missing", "third", "first"].map {
            MediaAssetRecord(localIdentifier: $0, fileName: "fixture.heic", isVideo: false)
        }
        let notes = NoteLibrary.notes(tasks: [task], media: media)
        #expect(notes.count == 2)
        let note = notes.first { $0.id == task.id.uuidString }
        #expect(note?.identifiers == ["first", "third"])
        #expect(note?.title == "日常随拍")
        #expect(note?.body == "一段完整的文案")
        #expect(notes.contains { $0.identifiers == ["orphan"] })
        // 1.1.0 keeps text-only notes (the "save note only" action) as summary
        // cards instead of dropping them when no media exists.
        let textOnly = NoteLibrary.notes(tasks: [task], media: [])
        #expect(textOnly.count == 1)
        #expect(textOnly.first?.isTextOnly == true)
        #expect(textOnly.first?.body == "一段完整的文案")
        var empty = DownloadTaskRecord(sourceText: "", normalizedURL: "https://www.xiaohongshu.com/explore/empty")
        empty.noteText = ""
        #expect(NoteLibrary.notes(tasks: [empty], media: []).isEmpty)
    }

    @Test func searchesWholeNoteAndFiltersWithoutDiscardingCompanionMedia() async {
        let note = LibraryNote(id: "note", title: "旅行", body: "完整的笔记\n#晚霞", author: "记录员",
                               avatarURL: nil, publishTime: nil, topics: ["摄影"], sourceURL: nil, date: .now,
                               media: [LibraryMedia(id: "cover"), LibraryMedia(id: "live", isLive: true), LibraryMedia(id: "movie", isVideo: true)])
        #expect(note.matches(query: "记录员", filter: 0))
        #expect(note.matches(query: "摄影", filter: 3))
        #expect(note.matches(query: "晚霞", filter: 2))
        #expect(!note.matches(query: "不存在的标题", filter: 0))
        #expect(note.identifiers == ["cover", "live", "movie"])
        let columns = NoteLibrary.columns([note, note, note], count: 2)
        #expect(columns.map(\.count) == [2, 1])
    }

    @Test func oldMetadataDecodesAndNewAuthorFieldsResolve() async throws {
        let old = try JSONDecoder().decode(NoteMetadata.self, from: Data(#"{"userName":"作者","publishTime":"26-11-08"}"#.utf8))
        #expect(old.avatarURL == nil && old.topics == nil)
        let note = try XHSDownloader().resolveNote(
            html: #"<script>window.__INITIAL_STATE__={"note":{"noteId":"test","title":"随拍","user":{"nickname":"作者","userId":"author123","redId":"myredid","avatar":"//example.com/avatar.jpg"},"tagList":[{"name":"生活"}],"imageList":[{"url":"https://example.com/image.heic"}]}};</script>"#,
            noteID: "test", canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/test")!)
        #expect(note.metadata.avatarURL?.absoluteString == "https://example.com/avatar.jpg")
        #expect(note.metadata.topics == ["生活"])
        var task = DownloadTaskRecord(sourceText: "", normalizedURL: note.canonicalURL.absoluteString)
        task.resolvedNote = note
        task.mediaAssets = [MediaAssetRecord(localIdentifier: "cover", fileName: "image.heic", isVideo: false)]
        let restored = try JSONDecoder().decode(DownloadTaskRecord.self, from: JSONEncoder().encode(task))
        let saved = try #require(NoteLibrary.notes(tasks: [restored], media: [LibraryMedia(id: "cover")]).first)
        #expect(saved.author == "作者" && saved.authorRedID == "myredid")
        #expect(saved.authorProfileURL?.absoluteString == "https://www.xiaohongshu.com/user/profile/author123")
        #expect(saved.avatarURL == note.metadata.avatarURL)
    }

    @Test func avatarSurvivesStoreRecreationWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AvatarTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://example.com/avatar.jpg")!
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }
        let data = try #require(image.pngData())
        _ = try await AuthorAvatarStore(directory: directory).store(data: data, for: url)
        let saved = try #require(await AuthorAvatarStore(directory: directory).imageData(for: url))
        let source = try #require(CGImageSourceCreateWithData(saved as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 192)
        #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 128)
    }

    @Test @MainActor func localLikesAndBookmarksPersistIndependently() async throws {
        let name = "NoteLibraryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = NoteLibraryPreferences(defaults: defaults)
        preferences.toggleLike("a")
        preferences.toggleBookmark("b")
        let loaded = NoteLibraryPreferences(defaults: defaults)
        #expect(loaded.likes == ["a"])
        #expect(loaded.bookmarks == ["b"])
        loaded.toggleBookmark("b")
        #expect(NoteLibraryPreferences(defaults: defaults).bookmarks.isEmpty)
        #expect(NoteLibraryPreferences(defaults: defaults).likes == ["a"])
    }

    @Test func captionRetainsParagraphsAndCreatesTopicLinks() async {
        let text = NoteCaption.attributed("第一段🌸\n\n第二段 #生活记录[话题]# #随手拍")
        #expect(String(text.characters) == "第一段🌸\n\n第二段 #生活记录 #随手拍")
        let links = text.runs.compactMap { $0.link }
        #expect(links.count == 2)
        #expect(links.allSatisfy { $0.scheme == "xhsdn" && $0.host == "topic" })
        #expect(URLComponents(url: links[0], resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "生活记录")
    }

    @Test func mobileNickNameAndSnakeCaseAuthorsPersistWithAvatar() async throws {
        for key in ["user", "user_info"] {
            let note = try XHSDownloader().resolveNote(
                html: """
                <script>window.__INITIAL_STATE__={"noteData":{"data":{"noteData":{"noteId":"test","title":"随拍",
                "\(key)":{"nickName":"你们开心就好呀","userId":"63b9394d0000000026013619","avatar":"https://sns-avatar-qc.xhscdn.com/avatar/sample?imageView2/2/w/120/format/jpg"},
                "imageList":[{"url":"https://example.com/image.heic"}]}}}};</script>
                """, noteID: "test", canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/test")!)
            var task = DownloadTaskRecord(sourceText: "", normalizedURL: note.canonicalURL.absoluteString)
            task.resolvedNote = note
            task.mediaAssets = [MediaAssetRecord(localIdentifier: "photo", fileName: "image.heic", isVideo: false)]
            let restored = try JSONDecoder().decode(DownloadTaskRecord.self, from: JSONEncoder().encode(task))
            let saved = try #require(NoteLibrary.notes(tasks: [restored], media: [LibraryMedia(id: "photo")]).first)
            #expect(saved.author == "你们开心就好呀")
            #expect(saved.avatarURL?.host == "sns-avatar-qc.xhscdn.com")
            #expect(saved.authorID == "63b9394d0000000026013619")
        }
    }

    @Test @MainActor func repairsStoredAuthorWithoutDownloadingOrChangingSavedMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://www.xiaohongshu.com/explore/6a50d3ef0000000008024e7a")!
        let media = RemoteMedia(url: URL(string: "https://example.com/original.heic")!, type: .image,
                                fileBaseName: "original", originalURLString: "https://example.com/original.heic")
        var task = DownloadTaskRecord(sourceText: "", normalizedURL: url.absoluteString, title: "原来的标题", status: .completed)
        task.resolvedNote = ResolvedNote(noteID: url.lastPathComponent, canonicalURL: url, title: task.title,
                                        body: "原来的正文", metadata: NoteMetadata(), media: [media])
        task.mediaAssets = [MediaAssetRecord(localIdentifier: "saved-photo", fileName: "original.heic", isVideo: false)]
        task.savedCount = 1
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        try await store.save([task])
        let before = try #require(await store.load().first)
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [AuthorRepairFixtureProtocol.self]
        let coordinator = DownloadCoordinator(settings: AppSettings(), store: store,
                                              downloader: XHSDownloader(session: URLSession(configuration: session)))
        await coordinator.waitUntilLoaded()
        await coordinator.restoreMissingAuthor(task.id)
        await coordinator.flushPersistence()
        let saved = try #require(await store.load().first)
        #expect(saved.resolvedNote?.metadata.userName == "你们开心就好呀")
        #expect(saved.resolvedNote?.media == [media])
        #expect(saved.mediaAssets == before.mediaAssets)
        #expect(saved.title == task.title && saved.status == .completed && saved.savedCount == 1)
        #expect(saved.resolvedNote?.body == "原来的正文")
    }
}

private final class AuthorRepairFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        guard url.host == "www.xiaohongshu.com" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let html = """
        <script>window.__INITIAL_STATE__={"note":{"noteId":"6a50d3ef0000000008024e7a",
        "title":"网站标题","user":{"nickName":"你们开心就好呀","userId":"63b9394d0000000026013619"},
        "imageList":[{"url":"https://example.com/new-media.jpg"}]}};</script>
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
