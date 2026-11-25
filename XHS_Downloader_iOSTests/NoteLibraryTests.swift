import Foundation
import Testing
import SwiftUI
import ImageIO
import UIKit
import UIKit.UIGestureRecognizerSubclass
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

    @Test @MainActor func leftEdgeReturnUsesInitialTouchAndModelPagerState() async throws {
        // Boundary cases for NoteHeroReturnPolicy.
        #expect(!NoteHeroReturnPolicy.shouldYieldHorizontalDrag(
            leadingDistance: 24, inMediaPager: true, canPageBackward: true))
        #expect(!NoteHeroReturnPolicy.shouldYieldHorizontalDrag(
            leadingDistance: NoteHeroReturnPolicy.leadingEdgeThreshold, inMediaPager: true, canPageBackward: true))
        #expect(NoteHeroReturnPolicy.shouldYieldHorizontalDrag(
            leadingDistance: NoteHeroReturnPolicy.leadingEdgeThreshold + 0.5, inMediaPager: true, canPageBackward: true))
        #expect(!NoteHeroReturnPolicy.shouldYieldHorizontalDrag(
            leadingDistance: 120, inMediaPager: true, canPageBackward: false))
        #expect(!NoteHeroReturnPolicy.shouldYieldHorizontalDrag(
            leadingDistance: 120, inMediaPager: false, canPageBackward: true))

        // NoteHeroPanGestureRecognizer preserves touch-down location even after
        // the finger moves past 36pt during pan recognition slop.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let hostView = UIView(frame: window.bounds)
        window.addSubview(hostView)
        window.isHidden = false
        defer { window.isHidden = true }

        let pan = NoteHeroPanGestureRecognizer()
        hostView.addGestureRecognizer(pan)
        let touch = HeroMockPanTouch(windowPoint: CGPoint(x: 24, y: 360))
        pan.touchesBegan([touch], with: UIEvent())
        // Simulate slop moving finger past the 36pt edge threshold before shouldBegin fires.
        touch.windowPoint = CGPoint(x: 52, y: 360)

        let initial = pan.initialLocation(in: hostView)
        #expect(initial == CGPoint(x: 24, y: 360))
        #expect(!NoteHeroReturnPolicy.shouldYieldHorizontalDrag(
            leadingDistance: initial.x, inMediaPager: true, canPageBackward: true))

        pan.reset()
        #expect(pan.initialLocationInWindow == nil)
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

    @Test @MainActor func foregroundHeaderOverlayPreservesTopSafeAreaInset() async throws {
        #expect(NoteHeroFeedForeground.resolvedHeaderTopInset(measuredHeaderMinY: 59, safeAreaTop: 59) == 59)
        #expect(NoteHeroFeedForeground.resolvedHeaderTopInset(measuredHeaderMinY: 54, safeAreaTop: 59) == 54)
        #expect(NoteHeroFeedForeground.resolvedHeaderTopInset(measuredHeaderMinY: 0, safeAreaTop: 59) == 59)
        #expect(NoteHeroFeedForeground.resolvedHeaderTopInset(measuredHeaderMinY: nil, safeAreaTop: 59) == 59)
        #expect(NoteHeroFeedForeground.resolvedHeaderTopInset(measuredHeaderMinY: 59, safeAreaTop: 0) == 59)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let tabs = UITabBarController()
        let feedVC = UIViewController()
        feedVC.tabBarItem = UITabBarItem(title: "笔记", image: UIImage(systemName: "photo"), tag: 1)
        tabs.viewControllers = [feedVC]
        window.rootViewController = tabs
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        tabs.view.layoutIfNeeded()

        let probeView = UIView()
        let topInset: CGFloat = 59
        let headerController = NoteHeroFeedForeground.makeHeaderOverlay(topInset: topInset) {
            AnyView(HeroOverlayProbe(view: probeView).frame(height: 92))
        }
        #expect(headerController.safeAreaRegions.isEmpty)

        let overlay = UIView(frame: window.bounds)
        window.addSubview(overlay)
        let foreground = try #require(NoteHeroFeedForeground(
            presenting: tabs, in: overlay, header: headerController.view, headerController: headerController))
        let stage = UIView(frame: overlay.bounds)
        foreground.insert(stage, convertingFrom: overlay)
        defer { foreground.restore(); stage.removeFromSuperview() }
        window.layoutIfNeeded()
        headerController.view.layoutIfNeeded()

        let probeFrame = probeView.convert(probeView.bounds, to: window)
        #expect(probeFrame.minY >= topInset - 1)
        #expect(probeFrame.minY <= topInset + 1)
    }

    @Test @MainActor func dismissSettlementKeepsCardConcealedDuringFlightAndClearsOnCompletion() async throws {
        let oppositeSwipe = NoteHeroScene.clampedInitialVelocity(
            velocity: CGPoint(x: 1200, y: 0),
            delta: CGPoint(x: -180, y: -120),
            expanded: false
        )
        #expect(oppositeSwipe.dx >= -0.8)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let tabs = UITabBarController()
        let feedVC = UIViewController()
        feedVC.tabBarItem = UITabBarItem(title: "笔记", image: UIImage(systemName: "photo"), tag: 1)
        tabs.viewControllers = [feedVC]
        window.rootViewController = tabs
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        tabs.view.layoutIfNeeded()

        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        defer { container.removeFromSuperview() }
        let readerVC = UIViewController()
        readerVC.view.frame = container.bounds
        container.addSubview(readerVC.view)

        let source = NoteHeroGeometry()
        source.selectedID = "note-1"
        source.register(CGRect(x: 8, y: 175, width: 188, height: 220), role: "card", id: "note-1")
        source.register(CGRect(x: 8, y: 175, width: 188, height: 150), role: "image", id: "note-1")
        source.register(CGRect(x: 0, y: 0, width: 402, height: 874), role: "scroll", id: "feed")
        source.register(CGRect(x: 0, y: 59, width: 402, height: 96), role: "header", id: "feed")

        let destination = NoteHeroGeometry()
        destination.selectedID = "note-1"
        destination.image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 160)).image { _ in }
        destination.register(CGRect(x: 0, y: 112, width: 402, height: 320), role: "image", id: "note-1")
        destination.register(CGRect(x: 0, y: 112, width: 402, height: 320), role: "viewport", id: "note-1")
        destination.register(CGRect(x: 0, y: 0, width: 402, height: 874), role: "scroll", id: "note-1")

        let context = HeroMockTransitionContext(containerView: container, fromVC: readerVC, toVC: tabs)
        let heroScene = try #require(NoteHeroScene(
            context: context,
            opening: false,
            card: true,
            source: source,
            destination: destination,
            foregroundHeader: { AnyView(Color.clear.frame(height: 96)) }
        ))
        #expect(source.concealedCardID == "note-1")
        #expect(source.concealedContentID == "note-1")
        #expect(source.concealingHeader == true)

        heroScene.follow(translation: CGPoint(x: 110, y: 30), anchor: CGPoint(x: 200, y: 400), edge: true)

        var settled = false
        heroScene.settle(expanded: false, velocity: CGPoint(x: 1200, y: 60)) {
            settled = true
        }

        // Wait past the old 0.16s mid-flight reveal timer: the empty card shell
        // must remain concealed until the returning stage lands cleanly.
        try await Task.sleep(for: .milliseconds(220))
        #expect(source.concealedCardID == "note-1")
        #expect(source.concealedContentID == "note-1")
        #expect(heroScene.background.alpha == 1)

        for _ in 0..<40 where !settled {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(settled)
        #expect(heroScene.background.frame == heroScene.cardMask.frame)
        #expect(heroScene.cardMask.layer.cornerRadius == 14)

        var finished = false
        heroScene.complete(true) { finished = true }
        for _ in 0..<20 where !finished {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(finished)
        #expect(context.didComplete == true)
        #expect(source.concealedCardID == nil)
        #expect(source.concealedContentID == nil)
        #expect(source.concealingHeader == false)
    }

    @Test @MainActor func secondCardDismissNeverFliesToFirstCardAfterColumnMove() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let tabs = UITabBarController()
        let feedVC = UIViewController()
        feedVC.tabBarItem = UITabBarItem(title: "笔记", image: UIImage(systemName: "photo"), tag: 1)
        tabs.viewControllers = [feedVC]
        window.rootViewController = tabs
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        tabs.view.layoutIfNeeded()

        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        defer { container.removeFromSuperview() }
        let readerVC = UIViewController()
        readerVC.view.frame = container.bounds
        container.addSubview(readerVC.view)

        let card1Slot = CGRect(x: 8, y: 175, width: 188, height: 220)
        let card1ImageSlot = CGRect(x: 8, y: 175, width: 188, height: 150)
        let card2InitialSlot = CGRect(x: 204, y: 175, width: 188, height: 220)
        let card2ImageSlot = CGRect(x: 204, y: 175, width: 188, height: 150)

        let card2LiveAnchor = UIView(frame: card2InitialSlot)
        let card2LiveImageAnchor = UIView(frame: card2ImageSlot)
        feedVC.view.addSubview(card2LiveAnchor)
        feedVC.view.addSubview(card2LiveImageAnchor)

        let source = NoteHeroGeometry()
        source.selectedID = "card-2"
        source.register(CGRect(x: 0, y: 0, width: 402, height: 874), role: "scroll", id: "feed")

        // 1. Old exiting copy of card-2 sat in Position #1 (column 0).
        let oldGen = NoteHeroGeometry.allocateGeneration()
        source.register(card1Slot, role: "card", id: "card-2", generation: oldGen)
        source.register(card1ImageSlot, role: "image", id: "card-2", generation: oldGen)

        // 2. New live copy of card-2 mounts at Position #2 (column 1).
        let newGen = NoteHeroGeometry.allocateGeneration()
        source.registerAnchor(card2LiveAnchor, role: "card", id: "card-2", generation: newGen)
        source.registerAnchor(card2LiveImageAnchor, role: "image", id: "card-2", generation: newGen)
        source.register(card2InitialSlot, role: "card", id: "card-2", generation: newGen)
        source.register(card2ImageSlot, role: "image", id: "card-2", generation: newGen)

        // 3. Exiting copy fires a late onGeometryChange with Position #1 and dismantles.
        source.register(card1Slot, role: "card", id: "card-2", generation: oldGen)
        source.register(card1ImageSlot, role: "image", id: "card-2", generation: oldGen)
        source.unregisterAnchor(role: "card", id: "card-2", generation: oldGen)
        source.unregisterAnchor(role: "image", id: "card-2", generation: oldGen)

        // 4. Even if card-2 moves via scroll/MasonryLayout without a new onGeometryChange,
        //    the live anchor reports its exact updated window coordinates.
        let card2MovedSlot = CGRect(x: 204, y: 240, width: 188, height: 220)
        let card2MovedImageSlot = CGRect(x: 204, y: 240, width: 188, height: 150)
        card2LiveAnchor.frame = card2MovedSlot
        card2LiveImageAnchor.frame = card2MovedImageSlot

        #expect(source.frame("card", "card-2", in: container) == card2MovedSlot)
        #expect(source.frame("image", "card-2", in: container) == card2MovedImageSlot)

        let destination = NoteHeroGeometry()
        destination.selectedID = "card-2"
        destination.image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 160)).image { _ in }
        destination.register(CGRect(x: 0, y: 112, width: 402, height: 320), role: "image", id: "card-2")
        destination.register(CGRect(x: 0, y: 112, width: 402, height: 320), role: "viewport", id: "card-2")
        destination.register(CGRect(x: 0, y: 0, width: 402, height: 874), role: "scroll", id: "card-2")

        let context = HeroMockTransitionContext(containerView: container, fromVC: readerVC, toVC: tabs)
        let heroScene = try #require(NoteHeroScene(
            context: context, opening: false, card: true, source: source, destination: destination
        ))
        #expect(heroScene.cardFrame == card2MovedSlot)
        #expect(heroScene.from == card2MovedImageSlot)
        heroScene.complete(true)
    }

    @Test @MainActor func removedCardAndLandscapeInsetsAndScrolledReaderClipCleanly() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        let tabs = UITabBarController()
        let feedVC = UIViewController()
        feedVC.tabBarItem = UITabBarItem(title: "笔记", image: UIImage(systemName: "photo"), tag: 1)
        tabs.viewControllers = [feedVC]
        window.rootViewController = tabs
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        tabs.view.layoutIfNeeded()

        // Landscape header overlay preserves leading & trailing safe area insets.
        let probeView = UIView()
        let headerController = NoteHeroFeedForeground.makeHeaderOverlay(
            topInset: 24, leadingInset: 59, trailingInset: 59
        ) {
            AnyView(HeroOverlayProbe(view: probeView).frame(height: 52))
        }
        let overlay = UIView(frame: window.bounds)
        window.addSubview(overlay)
        let foreground = try #require(NoteHeroFeedForeground(
            presenting: tabs, in: overlay, header: headerController.view, headerController: headerController
        ))
        let stage = UIView(frame: overlay.bounds)
        foreground.insert(stage, convertingFrom: overlay)
        window.layoutIfNeeded()
        headerController.view.layoutIfNeeded()
        let probeFrame = probeView.convert(probeView.bounds, to: window)
        #expect(probeFrame.minX >= 58)
        #expect(probeFrame.maxX <= window.bounds.width - 58)
        foreground.restore()
        stage.removeFromSuperview()
        overlay.removeFromSuperview()

        // Removing a card via pruneCards (e.g. unliking in Bookmarks) preserves
        // feed scroll/header frames and triggers a clean fade-dismiss without
        // concealing or flying onto a neighbor card.
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.layoutIfNeeded()
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        defer { container.removeFromSuperview() }
        let readerVC = UIViewController()
        readerVC.view.frame = container.bounds
        container.addSubview(readerVC.view)

        let source = NoteHeroGeometry()
        source.selectedID = "unliked-note"
        source.register(CGRect(x: 0, y: 0, width: 402, height: 874), role: "scroll", id: "feed")
        source.register(CGRect(x: 0, y: 59, width: 402, height: 96), role: "header", id: "feed")
        source.register(CGRect(x: 8, y: 175, width: 188, height: 220), role: "card", id: "unliked-note")
        source.register(CGRect(x: 8, y: 175, width: 188, height: 150), role: "image", id: "unliked-note")
        source.pruneCards(keeping: ["other-note"])

        #expect(!source.isCardPresent("unliked-note"))
        #expect(source.frame("scroll", "feed", in: container) != nil)
        #expect(source.frame("header", "feed", in: container) != nil)

        let destination = NoteHeroGeometry()
        destination.selectedID = "unliked-note"
        destination.image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 160)).image { _ in }
        destination.register(CGRect(x: 0, y: 0, width: 402, height: 112), role: "topBar", id: "unliked-note")
        destination.register(CGRect(x: 0, y: 780, width: 402, height: 94), role: "bottomBar", id: "unliked-note")
        destination.register(CGRect(x: 0, y: 40, width: 402, height: 280), role: "image", id: "unliked-note")
        destination.register(CGRect(x: 0, y: 40, width: 402, height: 280), role: "viewport", id: "unliked-note")
        destination.register(CGRect(x: 0, y: 0, width: 402, height: 874), role: "scroll", id: "unliked-note")

        let context = HeroMockTransitionContext(containerView: container, fromVC: readerVC, toVC: tabs)
        let heroScene = try #require(NoteHeroScene(
            context: context, opening: false, card: true, source: source, destination: destination
        ))
        // Because unliked-note is gone from the feed, no neighbor card is concealed.
        #expect(source.concealedCardID == nil)
        // Media mask is clipped strictly below topBar.maxY (112), never overlapping authorBar.
        let mediaWindow = try #require(heroScene.movingImage.superview)
        let mediaMaskFrame = try #require(mediaWindow.mask?.frame)
        #expect(mediaMaskFrame.minY >= 112)

        var settled = false
        heroScene.settle(expanded: false) { settled = true }
        for _ in 0..<30 where !settled {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(settled)
        #expect(heroScene.stage.alpha == 0)
        heroScene.complete(true)
    }

    @Test @MainActor func pruneCardsPreservesLiveWindowAttachedAnchorsWhileMarkingCardAbsent() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        defer { window.isHidden = true }

        let imageRect = CGRect(x: 8, y: 175, width: 188, height: 188)
        let cardRect = CGRect(x: 8, y: 175, width: 188, height: 260)
        let footerRect = CGRect(x: 8, y: 391, width: 188, height: 44)

        let liveImage = UIView(frame: imageRect)
        let liveCard = UIView(frame: cardRect)
        let liveFooter = UIView(frame: footerRect)
        host.addSubview(liveCard)
        host.addSubview(liveImage)
        host.addSubview(liveFooter)

        let detachedImage = UIView(frame: CGRect(x: 204, y: 175, width: 188, height: 188))

        let geometry = NoteHeroGeometry()
        let genA = NoteHeroGeometry.allocateGeneration()
        let genDetached = NoteHeroGeometry.allocateGeneration()
        geometry.registerAnchor(liveCard, role: "card", id: "card-a", generation: genA)
        geometry.registerAnchor(liveImage, role: "image", id: "card-a", generation: genA)
        geometry.registerAnchor(liveFooter, role: "footer", id: "card-a", generation: genA)
        geometry.register(imageRect, role: "image", id: "card-a", generation: genA)
        geometry.registerAnchor(detachedImage, role: "image", id: "card-detached", generation: genDetached)
        geometry.register(detachedImage.frame, role: "image", id: "card-detached", generation: genDetached)

        // Switching Discover -> Bookmarks removes card-a from visibleIDs while
        // its MasonryCardTransition view is still attached to the window.
        geometry.pruneCards(keeping: ["card-b"])
        #expect(!geometry.isCardPresent("card-a"))
        #expect(geometry.frame("image", "card-a", in: host) == imageRect)
        #expect(geometry.frame("footer", "card-a", in: host) == footerRect)
        // Truly detached anchors + cached frames for absent cards are cleaned up.
        #expect(geometry.frame("image", "card-detached", in: host) == nil)

        // Reversing back to Discover restores presence immediately with intact live anchors.
        geometry.pruneCards(keeping: ["card-a", "card-b"])
        #expect(geometry.isCardPresent("card-a"))
        #expect(geometry.frame("card", "card-a", in: host) == cardRect)
        #expect(geometry.frame("image", "card-a", in: host) == imageRect)
        #expect(geometry.frame("footer", "card-a", in: host) == footerRect)
    }

    @Test func frameResolverNeverFallsBackToFullscreenWhenCardOrViewportKnown() {
        let fullscreenFallback = CGRect(x: 0, y: 230, width: 393, height: 393)
        let cardFrame = CGRect(x: 8, y: 175, width: 188, height: 280)
        let validImage = CGRect(x: 8, y: 175, width: 188, height: 188)

        // Valid measured image inside card is returned directly.
        #expect(NoteHeroFrameResolver.resolveSourceImageFrame(
            measuredImage: validImage, cardFrame: cardFrame, coverRatio: 1.0, fallback: fullscreenFallback
        ) == validImage)

        // Missing measured image derives exact top cover rect from cardFrame + coverRatio.
        let derivedFromCard = NoteHeroFrameResolver.resolveSourceImageFrame(
            measuredImage: nil, cardFrame: cardFrame, coverRatio: 1.0, fallback: fullscreenFallback
        )
        #expect(derivedFromCard == CGRect(x: 8, y: 175, width: 188, height: 188))
        #expect(derivedFromCard != fullscreenFallback)

        // Bogus oversized measured image outside card width falls back to derived cover rect, never fullscreen.
        let rejectedOversized = NoteHeroFrameResolver.resolveSourceImageFrame(
            measuredImage: fullscreenFallback, cardFrame: cardFrame, coverRatio: 4.0 / 3.0, fallback: fullscreenFallback
        )
        #expect(rejectedOversized == CGRect(x: 8, y: 175, width: 188, height: 141))

        // Destination resolver: missing measured image aspect-fits inside known TabView viewport.
        let viewport = CGRect(x: 0, y: 112, width: 402, height: 320)
        let fittedPortrait = NoteHeroFrameResolver.resolveDestinationImageFrame(
            measuredImage: nil, viewport: viewport, imageSize: CGSize(width: 1200, height: 1600), fallback: fullscreenFallback
        )
        #expect(abs(fittedPortrait.minX - 81) < 0.01)
        #expect(abs(fittedPortrait.minY - 112) < 0.01)
        #expect(abs(fittedPortrait.width - 240) < 0.01)
        #expect(abs(fittedPortrait.height - 320) < 0.01)

        // Destination resolver: valid measured image intersecting viewport is kept verbatim.
        let measuredDest = CGRect(x: 0, y: 112, width: 402, height: 300)
        #expect(NoteHeroFrameResolver.resolveDestinationImageFrame(
            measuredImage: measuredDest, viewport: viewport, imageSize: CGSize(width: 400, height: 300), fallback: fullscreenFallback
        ) == measuredDest)
    }

    @Test @MainActor func heroShadowAndFooterGeometryStayConsistent() async throws {
        let cardFrame = CGRect(x: 8, y: 175, width: 188, height: 260)
        let measuredFooter = CGRect(x: 8, y: 391, width: 188, height: 44)
        #expect(NoteHeroFrameResolver.resolveSourceFooterFrame(measuredFooter: measuredFooter, cardFrame: cardFrame) == measuredFooter)
        #expect(NoteHeroFrameResolver.resolveSourceFooterFrame(measuredFooter: nil, cardFrame: cardFrame) == measuredFooter)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let tabs = UITabBarController()
        let feedVC = UIViewController()
        feedVC.tabBarItem = UITabBarItem(title: "笔记", image: UIImage(systemName: "photo"), tag: 1)
        tabs.viewControllers = [feedVC]
        window.rootViewController = tabs
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        tabs.view.layoutIfNeeded()

        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        defer { container.removeFromSuperview() }
        let readerVC = UIViewController()
        readerVC.view.frame = container.bounds
        container.addSubview(readerVC.view)

        let source = NoteHeroGeometry()
        source.selectedID = "note-footer"
        source.coverRatio = 1.0
        source.register(CGRect(x: 0, y: 0, width: 402, height: 874), role: "scroll", id: "feed")
        source.register(cardFrame, role: "card", id: "note-footer")
        source.register(CGRect(x: 8, y: 175, width: 188, height: 188), role: "image", id: "note-footer")
        source.register(measuredFooter, role: "footer", id: "note-footer")
        source.pruneCards(keeping: ["note-footer"])
        #expect(source.frame("footer", "note-footer", in: container) == measuredFooter)

        let destination = NoteHeroGeometry()
        destination.selectedID = "note-footer"
        destination.image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { _ in }
        destination.register(CGRect(x: 0, y: 112, width: 402, height: 402), role: "image", id: "note-footer")
        destination.register(CGRect(x: 0, y: 112, width: 402, height: 402), role: "viewport", id: "note-footer")
        destination.register(CGRect(x: 0, y: 0, width: 402, height: 874), role: "scroll", id: "note-footer")

        let context = HeroMockTransitionContext(containerView: container, fromVC: readerVC, toVC: tabs)
        let heroScene = try #require(NoteHeroScene(
            context: context,
            opening: false,
            card: true,
            source: source,
            destination: destination,
            cardFooter: {
                AnyView(NoteFeedCardFooter(author: "测试作者", avatarURL: nil, liked: true, isSelecting: false))
            }
        ))

        let footerView = try #require(heroScene.footerController?.view)
        #expect(footerView.superview === heroScene.stage)
        #expect(heroScene.dimmingView.superview === heroScene.transitionRoot)
        #expect(heroScene.cardShadowView.superview === heroScene.transitionRoot)
        #expect(heroScene.stage.superview === heroScene.transitionRoot)

        heroScene.follow(translation: CGPoint(x: 90, y: 40), anchor: CGPoint(x: 200, y: 400), edge: true)
        #expect(heroScene.cardShadowView.transform == heroScene.stage.transform)
        #expect(heroScene.cardShadowView.layer.shadowOpacity > 0)
        #expect(footerView.alpha == 0)

        var settled = false
        heroScene.settle(expanded: false, velocity: CGPoint(x: 900, y: 40)) { settled = true }
        for _ in 0..<40 where !settled {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(settled)
        #expect(heroScene.cardShadowView.transform == .identity)
        #expect(heroScene.cardShadowView.frame == heroScene.cardMask.frame)
        #expect(heroScene.cardShadowView.layer.cornerRadius == 14)
        #expect(heroScene.dimmingView.alpha == 0)
        #expect(footerView.transform == .identity)
        #expect(footerView.alpha == 1)

        var finished = false
        heroScene.complete(true) { finished = true }
        for _ in 0..<20 where !finished {
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(finished)
        #expect(heroScene.transitionRoot.superview == nil)
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
                <script>window.__INITIAL_STATE__={"noteData":{"data":{"noteData":{"noteId":"6aa2443700000000260303c2","title":"DeepSeek V4.1 Flash：更强、更快、更普惠",
                "\(key)":{"nickName":"DeepSeek","userId":"66821202000000001b01a005","avatar":"https://sns-avatar-qc.xhscdn.com/avatar/sample?imageView2/2/w/120/format/jpg"},
                "imageList":[{"url":"https://example.com/image.heic"}]}}}};</script>
                """, noteID: "6aa2443700000000260303c2", canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/6aa2443700000000260303c2")!)
            var task = DownloadTaskRecord(sourceText: "", normalizedURL: note.canonicalURL.absoluteString)
            task.resolvedNote = note
            task.mediaAssets = [MediaAssetRecord(localIdentifier: "photo", fileName: "image.heic", isVideo: false)]
            let restored = try JSONDecoder().decode(DownloadTaskRecord.self, from: JSONEncoder().encode(task))
            let saved = try #require(NoteLibrary.notes(tasks: [restored], media: [LibraryMedia(id: "photo")]).first)
            #expect(saved.author == "DeepSeek")
            #expect(saved.avatarURL?.host == "sns-avatar-qc.xhscdn.com")
            #expect(saved.authorID == "66821202000000001b01a005")
        }
    }

    @Test @MainActor func repairsStoredAuthorWithoutDownloadingOrChangingSavedMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://www.xiaohongshu.com/explore/6a3d3338000000000603375d")!
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
        #expect(saved.resolvedNote?.metadata.userName == "DeepSeek")
        #expect(saved.resolvedNote?.media == [media])
        #expect(saved.mediaAssets == before.mediaAssets)
        #expect(saved.title == task.title && saved.status == .completed && saved.savedCount == 1)
        #expect(saved.resolvedNote?.body == "原来的正文")
    }
}

private final class HeroMockPanTouch: UITouch {
    var windowPoint: CGPoint
    init(windowPoint: CGPoint) {
        self.windowPoint = windowPoint
        super.init()
    }
    override func location(in view: UIView?) -> CGPoint {
        guard let view else { return windowPoint }
        return view.convert(windowPoint, from: view.window)
    }
}

private struct HeroOverlayProbe: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor
private final class HeroMockTransitionContext: NSObject, UIViewControllerContextTransitioning {
    let containerView: UIView
    private let fromVC: UIViewController
    private let toVC: UIViewController
    private(set) var didComplete: Bool?

    init(containerView: UIView, fromVC: UIViewController, toVC: UIViewController) {
        self.containerView = containerView
        self.fromVC = fromVC
        self.toVC = toVC
    }

    var isAnimated: Bool { true }
    var isInteractive: Bool { true }
    var transitionWasCancelled: Bool { false }
    var presentationStyle: UIModalPresentationStyle { .custom }
    var targetTransform: CGAffineTransform { .identity }

    func updateInteractiveTransition(_ percentComplete: CGFloat) {}
    func finishInteractiveTransition() {}
    func cancelInteractiveTransition() {}
    func pauseInteractiveTransition() {}
    func completeTransition(_ didComplete: Bool) { self.didComplete = didComplete }

    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? {
        switch key {
        case .from: fromVC
        case .to: toVC
        default: nil
        }
    }

    func view(forKey key: UITransitionContextViewKey) -> UIView? {
        switch key {
        case .from: fromVC.view
        case .to: toVC.view
        default: nil
        }
    }

    func initialFrame(for vc: UIViewController) -> CGRect { containerView.bounds }
    func finalFrame(for vc: UIViewController) -> CGRect { containerView.bounds }
}

private final class AuthorRepairFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        guard url.host == "www.xiaohongshu.com" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let html = """
        <script>window.__INITIAL_STATE__={"note":{"noteId":"6a3d3338000000000603375d",
        "title":"DeepSeek 寻找闪亮发光的你","user":{"nickName":"DeepSeek","userId":"66821202000000001b01a005"},
        "imageList":[{"url":"https://example.com/new-media.jpg"}]}};</script>
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
