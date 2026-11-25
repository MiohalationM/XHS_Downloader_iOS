import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import Combine

@MainActor
private func recordNoteHeroDiagnostic(_ text: String) {
    #if DEBUG
    guard ProcessInfo.processInfo.arguments.contains("-xhs-hero-diagnostics") else { return }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-hero-geometry.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((text + "\n").utf8))
    } else { try? Data((text + "\n").utf8).write(to: url) }
    #endif
}

struct OptionalSystemMediaZoom: ViewModifier {
    let enabled: Bool
    let id: String
    let namespace: Namespace.ID
    @ViewBuilder func body(content: Content) -> some View {
        if enabled, #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

/// Geometry is read directly from the live views when a transition starts,
/// including after paging, scrolling, rotation, and Dynamic Type changes.
@MainActor
final class NoteHeroGeometry: ObservableObject {
    private final class Entry {
        weak var view: UIView?
        let generation: UInt64
        init(_ view: UIView, generation: UInt64) {
            self.view = view
            self.generation = generation
        }
    }
    private struct FrameEntry {
        let rect: CGRect
        let generation: UInt64
    }
    private static var nextGenerationCounter: UInt64 = 0
    static func allocateGeneration() -> UInt64 {
        nextGenerationCounter &+= 1
        return nextGenerationCounter
    }

    private var entries: [String: Entry] = [:]
    private var entryGenerations: [String: UInt64] = [:]
    private var anchors: [String: Entry] = [:]
    private var anchorGenerations: [String: UInt64] = [:]
    private var frames: [String: FrameEntry] = [:]
    private var frameGenerations: [String: UInt64] = [:]
    private var hiddenViews: [String: CGFloat] = [:]
    private var visibleCardIDs: Set<String>?
    @Published var concealedCardID: String?
    @Published var concealedContentID: String?
    @Published var concealingHeader = false
    var selectedID = ""
    var title = ""
    var image: UIImage?
    var coverRatio: CGFloat = 1
    var canPageBackward = false

    func register(_ view: UIView, role: String, id: String, generation: UInt64 = 0) {
        let key = role + id
        let effectiveGen: UInt64
        if generation > 0 {
            if let current = entryGenerations[key], generation < current { return }
            effectiveGen = generation
        } else {
            effectiveGen = Self.allocateGeneration()
        }
        entryGenerations[key] = effectiveGen
        entries[key] = Entry(view, generation: effectiveGen)
        if hiddenViews[key] != nil { view.alpha = 0 }
    }

    func unregisterView(role: String, id: String, generation: UInt64) {
        let key = role + id
        guard entryGenerations[key] == generation else { return }
        entries.removeValue(forKey: key)
        entryGenerations.removeValue(forKey: key)
    }

    func registerAnchor(_ view: UIView, role: String, id: String, generation: UInt64) {
        let key = role + id
        if let current = anchorGenerations[key], generation < current { return }
        anchorGenerations[key] = generation
        anchors[key] = Entry(view, generation: generation)
    }

    func unregisterAnchor(role: String, id: String, generation: UInt64) {
        let key = role + id
        guard anchorGenerations[key] == generation else { return }
        anchors.removeValue(forKey: key)
        anchorGenerations.removeValue(forKey: key)
        if frameGenerations[key] == generation {
            frames.removeValue(forKey: key)
            frameGenerations.removeValue(forKey: key)
        }
    }

    func conceal(_ role: String, _ id: String, _ concealed: Bool) {
        let key = role + id
        if concealed {
            if hiddenViews[key] == nil { hiddenViews[key] = view(role, id)?.alpha ?? 1 }
            view(role, id)?.alpha = 0
        } else if let alpha = hiddenViews.removeValue(forKey: key) { view(role, id)?.alpha = alpha }
        if role == "image" {
            conceal("player", id, concealed)
            conceal("live", id, concealed)
        }
    }
    func resetFrames() {
        frames.removeAll()
        frameGenerations.removeAll()
        anchors.removeAll()
        anchorGenerations.removeAll()
        canPageBackward = false
    }

    func pruneCards(keeping visibleIDs: Set<String>) {
        visibleCardIDs = visibleIDs
        let cardRoles = ["card", "image", "title", "viewport", "footer"]
        func cardKeyInfo(_ key: String) -> (isCard: Bool, keepByID: Bool) {
            for role in cardRoles where key.hasPrefix(role) {
                let id = String(key.dropFirst(role.count))
                if id == "feed" { return (true, true) }
                return (true, visibleIDs.contains(id))
            }
            return (false, true)
        }
        func shouldKeepLive(_ key: String, entry: Entry) -> Bool {
            let info = cardKeyInfo(key)
            guard info.isCard else { return true }
            if info.keepByID { return true }
            // Keep live window-attached views (e.g. cards mid-MasonryCardTransition
            // that may reverse back into view); `isCardPresent(_:)` still gates
            // visibility via `visibleCardIDs`, and `dismantleUIView` cleans up on unmount.
            return entry.view?.window != nil
        }
        entries = entries.filter { shouldKeepLive($0.key, entry: $0.value) }
        entryGenerations = entryGenerations.filter { entries[$0.key] != nil }
        anchors = anchors.filter { shouldKeepLive($0.key, entry: $0.value) }
        anchorGenerations = anchorGenerations.filter { anchors[$0.key] != nil }
        frames = frames.filter { cardKeyInfo($0.key).keepByID }
        frameGenerations = frameGenerations.filter { frames[$0.key] != nil }
    }

    func isCardPresent(_ id: String) -> Bool {
        if let visibleCardIDs, !visibleCardIDs.contains(id) { return false }
        return true
    }

    func setConcealed(card: String?, content: String?, header: Bool? = nil) {
        if concealedCardID != card { concealedCardID = card }
        if concealedContentID != content { concealedContentID = content }
        if let header, concealingHeader != header { concealingHeader = header }
    }
    func register(_ frame: CGRect, role: String, id: String, generation: UInt64 = 0) {
        let key = role + id
        let effectiveGen: UInt64
        if generation > 0 {
            if let current = frameGenerations[key], generation < current { return }
            effectiveGen = generation
        } else {
            effectiveGen = Self.allocateGeneration()
        }
        frameGenerations[key] = effectiveGen
        frames[key] = FrameEntry(rect: frame, generation: effectiveGen)
    }

    func unregisterFrame(role: String, id: String, generation: UInt64) {
        let key = role + id
        guard frameGenerations[key] == generation else { return }
        frames.removeValue(forKey: key)
        frameGenerations.removeValue(forKey: key)
    }

    func view(_ role: String, _ id: String) -> UIView? { entries[role + id]?.view }
    func frame(_ role: String, _ id: String, in container: UIView) -> CGRect? {
        let key = role + id
        if let view = entries[key]?.view, view.window != nil, !view.bounds.isEmpty {
            return view.convert(view.bounds, to: container)
        }
        if let anchor = anchors[key]?.view, anchor.window != nil, !anchor.bounds.isEmpty {
            return anchor.convert(anchor.bounds, to: container)
        }
        guard let frame = frames[key]?.rect, !frame.isEmpty else { return nil }
        return container.convert(frame, from: container.window)
    }
    func still(_ id: String) -> UIImage? {
        MediaPreviewImages.shared.image(for: id) ?? (view("image", id) as? UIImageView)?.image ?? image
    }

    func visibleCardFrame(_ id: String, in container: UIView) -> CGRect? {
        guard isCardPresent(id), let card = frame("card", id, in: container) else { return nil }
        let viewport = frame("scroll", "feed", in: container) ?? container.bounds
        return card.intersection(viewport).intersection(container.bounds)
    }

    func adoptStill(_ image: UIImage, for id: String) {
        guard let imageView = view("image", id) as? UIImageView else { return }
        imageView.image = image
    }
}

enum NoteHeroReturnDirection {
    static func isHorizontal(_ velocity: CGPoint) -> Bool {
        velocity.x > 0 && velocity.x > abs(velocity.y)
    }
}

enum NoteHeroReturnPolicy {
    static let leadingEdgeThreshold: CGFloat = 36

    static func shouldYieldHorizontalDrag(
        leadingDistance: CGFloat,
        inMediaPager: Bool,
        canPageBackward: Bool
    ) -> Bool {
        inMediaPager && canPageBackward && leadingDistance > leadingEdgeThreshold
    }
}

/// Captures the true touch-down position in window coordinates before UIKit's
/// pan slop moves the finger past the leading-edge threshold.
final class NoteHeroPanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var initialLocationInWindow: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if initialLocationInWindow == nil, let touch = touches.first {
            initialLocationInWindow = touch.location(in: view?.window)
        }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        initialLocationInWindow = nil
    }

    func initialLocation(in targetView: UIView) -> CGPoint {
        guard let point = initialLocationInWindow else { return location(in: targetView) }
        return targetView.convert(point, from: targetView.window)
    }
}

enum NoteHeroDragGeometry {
    /// Resume from the live presentation frame, rather than the animator's
    /// already-set endpoint. Preserves exact position even when scale was
    /// clamped, under Reduce Motion, or when catching a mid-flight spring.
    static func resumedTranslation(frame: CGRect, expanded: CGRect, bounds: CGRect,
                                   anchor: CGPoint, horizontal: Bool) -> CGPoint {
        let scale = frame.width / max(expanded.width, 1)
        let verticalTravel = frame.midY - bounds.midY - (expanded.midY - bounds.midY) * scale
            - (anchor.y - bounds.midY) * (1 - scale)
        let dx = frame.midX - bounds.midX - (expanded.midX - bounds.midX) * scale
            - (anchor.x - bounds.midX) * (1 - scale)
        return CGPoint(x: dx, y: verticalTravel)
    }

    static func rubberBand(_ value: CGFloat, limit: CGFloat = 48) -> CGFloat {
        guard value < 0 else { return value }
        let distance = -value
        return -(distance * limit) / (distance + limit)
    }
}

/// A threshold ticks once per held gesture. Retreating and crossing it again
/// cannot buzz repeatedly; a fast committed flick still receives one response.
struct NoteDismissalFeedback {
    private(set) var crossedThreshold = false

    mutating func moved(distance: CGFloat, threshold: CGFloat) -> FeedbackEvent? {
        guard !crossedThreshold, distance >= threshold else { return nil }
        crossedThreshold = true
        return .boundary
    }

    func released(completed: Bool) -> FeedbackEvent? {
        completed && !crossedThreshold ? .navigation : nil
    }
}

/// Put the moving page underneath the complete, live tab-bar branch. The
/// system's selected material and its ordinary items need the same z-order;
/// a snapshot of UITabBar does not reliably include both.
@MainActor
final class NoteHeroFeedForeground {
    private weak var tabsController: UITabBarController?
    private let host: UIView
    private let chrome: UIView
    private let header: UIView?
    private let headerController: UIViewController?
    private let originalAlpha: CGFloat

    static func resolvedHeaderTopInset(measuredHeaderMinY: CGFloat?, safeAreaTop: CGFloat) -> CGFloat {
        let fallback = max(0, safeAreaTop)
        if let measured = measuredHeaderMinY, measured.isFinite, measured >= max(0, fallback - 16) {
            return measured
        }
        return fallback
    }

    static func makeHeaderOverlay(
        topInset: CGFloat,
        leadingInset: CGFloat = 0,
        trailingInset: CGFloat = 0,
        content: () -> AnyView
    ) -> UIHostingController<AnyView> {
        let top = max(0, topInset)
        let leading = max(0, leadingInset)
        let trailing = max(0, trailingInset)
        let overlay = UIHostingController(rootView: AnyView(
            VStack(spacing: 0) {
                content()
                Spacer(minLength: 0)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: top)
            }
            .safeAreaInset(edge: .leading, spacing: 0) {
                Color.clear.frame(width: leading)
            }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                Color.clear.frame(width: trailing)
            }
        ))
        overlay.safeAreaRegions = []
        overlay.view.backgroundColor = .clear
        overlay.view.isUserInteractionEnabled = false
        return overlay
    }

    init?(presenting controller: UIViewController?, in container: UIView,
          header: UIView? = nil, headerController: UIViewController? = nil) {
        func findTabs(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            if let tabs = controller.tabBarController { return tabs }
            return controller.children.lazy.compactMap { findTabs(in: $0) }.first
        }
        guard let controller,
              let tabs = findTabs(in: controller) ??
                container.window?.rootViewController.flatMap({ findTabs(in: $0) }),
              let root = tabs.viewIfLoaded,
              let window = container.window, root.window === window else { return nil }
        let bar = tabs.tabBar
        guard
              bar.window === container.window, !bar.isHidden, bar.alpha > 0,
              !bar.bounds.isEmpty else { return nil }
        var branch: UIView = bar
        while let parent = branch.superview, parent !== root { branch = parent }
        guard branch.superview === root, !branch.isHidden, branch.alpha > 0 else { return nil }
        if let selectedView = tabs.selectedViewController?.viewIfLoaded,
           selectedView.isDescendant(of: branch) {
            return nil
        }
        tabsController = tabs
        host = root
        chrome = branch
        self.header = header
        self.headerController = headerController
        originalAlpha = branch.alpha
    }

    func insert(_ stage: UIView, convertingFrom container: UIView) {
        // Leave the system bar, its constraints and its material hierarchy
        // untouched. Only the app-owned transition stage changes parent.
        stage.frame = container.convert(container.bounds, to: host)
        stage.bounds = container.bounds
        host.insertSubview(stage, belowSubview: chrome)
        if let header {
            if let headerController, let tabsController, headerController.parent == nil {
                tabsController.addChild(headerController)
            }
            header.frame = host.bounds
            header.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.insertSubview(header, belowSubview: chrome)
            headerController?.didMove(toParent: tabsController)
            header.setNeedsLayout()
            header.layoutIfNeeded()
        }
    }

    var alpha: CGFloat {
        get { chrome.alpha / originalAlpha }
        set {
            chrome.alpha = originalAlpha * newValue
            header?.alpha = newValue
        }
    }

    func restore() {
        chrome.alpha = originalAlpha
        if let headerController, headerController.parent != nil {
            headerController.willMove(toParent: nil)
            header?.removeFromSuperview()
            headerController.removeFromParent()
        } else {
            header?.removeFromSuperview()
        }
    }
}

/// UIKit's modal container remains above the presenting controller. Forward
/// its touches to the live page while that page is drawn below the tab bar,
/// preserving the ability to catch a cancelled return during its spring.
final class NoteHeroTransitionInput: UIView {
    weak var target: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01,
              self.point(inside: point, with: event) else { return nil }
        if let target, let hit = target.hitTest(convert(point, to: target), with: event) { return hit }
        // Do not let a gesture that misses the moving page switch feed tabs
        // or open another card in the middle of the return.
        return self
    }
}

enum NoteHeroFrameResolver {
    static func resolveSourceImageFrame(
        measuredImage: CGRect?,
        cardFrame: CGRect?,
        coverRatio: CGFloat,
        fallback: CGRect
    ) -> CGRect {
        if let img = measuredImage, !img.isEmpty, !img.isNull {
            if let card = cardFrame, !card.isEmpty, !card.isNull {
                let expandedCard = card.insetBy(dx: -4, dy: -4)
                if expandedCard.contains(img) || (img.width <= card.width + 4 && img.intersects(card)) {
                    return img
                }
            } else {
                return img
            }
        }
        if let card = cardFrame, !card.isEmpty, !card.isNull {
            let ratio = max(0.5, coverRatio)
            return CGRect(
                x: card.minX,
                y: card.minY,
                width: card.width,
                height: min(card.height, card.width / ratio)
            )
        }
        return fallback
    }

    static func resolveDestinationImageFrame(
        measuredImage: CGRect?,
        viewport: CGRect?,
        imageSize: CGSize?,
        fallback: CGRect
    ) -> CGRect {
        if let img = measuredImage, !img.isEmpty, !img.isNull {
            if let vp = viewport, !vp.isEmpty, !vp.isNull {
                if img.intersects(vp) { return img }
            } else {
                return img
            }
        }
        if let vp = viewport, !vp.isEmpty, !vp.isNull {
            if let size = imageSize, size.width > 0, size.height > 0 {
                let scale = min(vp.width / size.width, vp.height / size.height)
                let fitted = CGSize(width: size.width * scale, height: size.height * scale)
                return CGRect(
                    x: vp.midX - fitted.width / 2,
                    y: vp.midY - fitted.height / 2,
                    width: fitted.width,
                    height: fitted.height
                )
            }
            return vp
        }
        return fallback
    }

    static func resolveSourceFooterFrame(
        measuredFooter: CGRect?,
        cardFrame: CGRect
    ) -> CGRect {
        if let footer = measuredFooter, !footer.isEmpty, !footer.isNull,
           cardFrame.insetBy(dx: -4, dy: -4).intersects(footer) {
            return footer
        }
        let height = min(44, cardFrame.height)
        return CGRect(
            x: cardFrame.minX,
            y: max(cardFrame.minY, cardFrame.maxY - height),
            width: cardFrame.width,
            height: height
        )
    }
}

private final class NoteHeroAnchorView: UIView {
    weak var geometry: NoteHeroGeometry?
    var role = ""
    var heroID = ""
    var generation: UInt64 = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !heroID.isEmpty, generation > 0 else { return }
        geometry?.registerAnchor(self, role: role, id: heroID, generation: generation)
    }
}

/// Live transparent UIKit anchor placed behind a SwiftUI hero target so
/// `NoteHeroGeometry.frame(_:_:in:)` always reads live window coordinates at
/// transition time, never a stale cached CGRect from an earlier layout/column.
private struct NoteHeroAnchor: UIViewRepresentable {
    let geometry: NoteHeroGeometry
    let role: String
    let id: String
    let generation: UInt64

    final class Coordinator {
        weak var geometry: NoteHeroGeometry?
        var lastRole = ""
        var lastID = ""
        var lastGeneration: UInt64 = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> NoteHeroAnchorView {
        let view = NoteHeroAnchorView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.geometry = geometry
        view.role = role
        view.heroID = id
        view.generation = generation
        let coord = context.coordinator
        coord.geometry = geometry
        coord.lastRole = role
        coord.lastID = id
        coord.lastGeneration = generation
        geometry.registerAnchor(view, role: role, id: id, generation: generation)
        return view
    }

    func updateUIView(_ uiView: NoteHeroAnchorView, context: Context) {
        let coord = context.coordinator
        coord.geometry = geometry
        if coord.lastRole != role || coord.lastID != id || coord.lastGeneration != generation {
            if !coord.lastID.isEmpty {
                geometry.unregisterAnchor(role: coord.lastRole, id: coord.lastID, generation: coord.lastGeneration)
            }
            coord.lastRole = role
            coord.lastID = id
            coord.lastGeneration = generation
        }
        uiView.geometry = geometry
        uiView.role = role
        uiView.heroID = id
        uiView.generation = generation
        geometry.registerAnchor(uiView, role: role, id: id, generation: generation)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NoteHeroAnchorView, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions(by: .zero)
        return size.width > 0 && size.height > 0 ? size : nil
    }

    static func dismantleUIView(_ uiView: NoteHeroAnchorView, coordinator: Coordinator) {
        guard !coordinator.lastID.isEmpty else { return }
        coordinator.geometry?.unregisterAnchor(
            role: coordinator.lastRole,
            id: coordinator.lastID,
            generation: coordinator.lastGeneration
        )
    }
}

/// Measure SwiftUI cards directly using a live UIKit anchor plus generation-
/// guarded `onGeometryChange` fallback, preventing exiting column copies or
/// stale cached frames from poisoning another card's coordinates.
struct NoteHeroFrame: ViewModifier {
    let geometry: NoteHeroGeometry
    let role: String
    let id: String
    @State private var latestFrame = CGRect.zero
    @State private var generation = NoteHeroGeometry.allocateGeneration()

    func body(content: Content) -> some View {
        content
            .background {
                NoteHeroAnchor(geometry: geometry, role: role, id: id, generation: generation)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                latestFrame = $0
                geometry.register($0, role: role, id: id, generation: generation)
            }
            .onChange(of: id) { oldID, newID in
                geometry.unregisterFrame(role: role, id: oldID, generation: generation)
                let next = NoteHeroGeometry.allocateGeneration()
                generation = next
                if !latestFrame.isEmpty {
                    geometry.register(latestFrame, role: role, id: newID, generation: next)
                }
            }
    }
}

struct NoteHeroTitle: UIViewRepresentable {
    let text: String
    let size: CGFloat
    let lines: Int
    let geometry: NoteHeroGeometry
    let id: String
    var accessibilityID = ""

    @MainActor
    final class Coordinator {
        weak var geometry: NoteHeroGeometry?
        var lastID = ""
        var generation: UInt64 = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.geometry = geometry
        context.coordinator.lastID = id
        context.coordinator.generation = NoteHeroGeometry.allocateGeneration()
        return label
    }
    func updateUIView(_ label: UILabel, context: Context) {
        let coord = context.coordinator
        coord.geometry = geometry
        if coord.lastID != id {
            if !coord.lastID.isEmpty {
                geometry.unregisterView(role: "title", id: coord.lastID, generation: coord.generation)
            }
            coord.lastID = id
            coord.generation = NoteHeroGeometry.allocateGeneration()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lines == 2 ? 3 : 4
        paragraph.lineBreakMode = lines == 2 ? .byTruncatingTail : .byWordWrapping
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold), .paragraphStyle: paragraph, .foregroundColor: UIColor.label
        ])
        label.font = .systemFont(ofSize: size, weight: .semibold)
        label.numberOfLines = lines
        label.accessibilityIdentifier = accessibilityID
        geometry.register(label, role: "title", id: id, generation: coord.generation)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        uiView.sizeThatFits(CGSize(width: proposal.width ?? 320, height: .greatestFiniteMagnitude))
    }
    static func dismantleUIView(_ uiView: UILabel, coordinator: Coordinator) {
        guard !coordinator.lastID.isEmpty else { return }
        coordinator.geometry?.unregisterView(role: "title", id: coordinator.lastID, generation: coordinator.generation)
    }
}

enum NoteHeroTitleVisibility {
    static func canTransfer(source: CGRect?, destination: CGRect?, text: String, viewport: CGRect? = nil) -> Bool {
        guard !text.isEmpty, let source, let destination else { return false }
        guard !source.isEmpty, !source.isNull, !destination.isEmpty, !destination.isNull else { return false }
        if let viewport, !viewport.isEmpty,
           source.intersection(viewport).isEmpty || destination.intersection(viewport).isEmpty { return false }
        return true
    }
}

/// Once a return gesture wins, neither the body nor a nested media pager may
/// consume the same drag. Keep their offsets stable until the handoff finishes.
@MainActor
final class NoteHeroScrollLock {
    @MainActor
    private final class State {
        weak var scroll: UIScrollView?
        let enabled: Bool
        let verticalIndicator: Bool
        let horizontalIndicator: Bool
        let offset: CGPoint
        init(_ scroll: UIScrollView) {
            self.scroll = scroll
            enabled = scroll.isScrollEnabled
            verticalIndicator = scroll.showsVerticalScrollIndicator
            horizontalIndicator = scroll.showsHorizontalScrollIndicator
            offset = scroll.contentOffset
        }
    }
    private var states: [State] = []

    init(in root: UIView) {
        func collect(_ view: UIView) {
            if let scroll = view as? UIScrollView { states.append(State(scroll)) }
            view.subviews.forEach(collect)
        }
        collect(root)
        for state in states {
            guard let scroll = state.scroll else { continue }
            scroll.isScrollEnabled = false
            scroll.setContentOffset(state.offset, animated: false)
            scroll.showsVerticalScrollIndicator = false
            scroll.showsHorizontalScrollIndicator = false
        }
        recordNoteHeroDiagnostic("scroll lock acquired offsets=\(states.map(\.offset))")
    }

    func restore() {
        recordNoteHeroDiagnostic("scroll lock released offsets=\(states.compactMap { $0.scroll?.contentOffset })")
        UIView.performWithoutAnimation {
            for state in states {
                guard let scroll = state.scroll else { continue }
                scroll.setContentOffset(state.offset, animated: false)
                scroll.isScrollEnabled = state.enabled
                scroll.showsVerticalScrollIndicator = state.verticalIndicator
                scroll.showsHorizontalScrollIndicator = state.horizontalIndicator
            }
        }
        states.removeAll()
    }
}

/// Both levels retain the presenting page underneath. No opaque system modal
/// surface or scaled black navigation controller participates in the animation.
struct NoteHeroPresentation<Item: Identifiable, Content: View>: UIViewControllerRepresentable {
    @Binding var item: Item?
    let card: Bool
    let source: NoteHeroGeometry
    let destination: NoteHeroGeometry
    var preview: (Item) -> UIImage? = { _ in nil }
    var foregroundHeader: (() -> AnyView)? = nil
    var cardFooter: (() -> AnyView)? = nil
    var contentRevision: AnyHashable = 0
    var onDismiss: () -> Void = {}
    @ViewBuilder let content: (Item, @escaping () -> Void) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> NoteHeroPresenter {
        let controller = NoteHeroPresenter()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.onAppear = { [weak coordinator = context.coordinator] in coordinator?.update() }
        context.coordinator.presenter = controller
        return controller
    }
    func updateUIViewController(_ controller: NoteHeroPresenter, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    final class Coordinator: NSObject, UIViewControllerTransitioningDelegate, UIGestureRecognizerDelegate {
        var parent: NoteHeroPresentation
        weak var presenter: NoteHeroPresenter?
        private var host: NoteHeroHost<Content>?
        private var interactive: NoteHeroInteraction?
        private var closing = false
        private var pendingClose = false
        private var retryPresentWorkItem: DispatchWorkItem?
        private var displayedRevision: AnyHashable?
        private var scrollLock: NoteHeroScrollLock?

        init(_ parent: NoteHeroPresentation) { self.parent = parent }

        func update() {
            guard let presenter, presenter.view.window != nil else { return }
            if let item = parent.item, host == nil {
                guard presenter.presentedViewController == nil,
                      !presenter.isBeingPresented,
                      !presenter.isBeingDismissed else {
                    // Wait for a dismissing context menu or sibling sheet
                    // instead of letting UIKit drop the presentation and leave
                    // stale host/header state behind.
                    if retryPresentWorkItem == nil {
                        let retry = DispatchWorkItem { [weak self] in
                            self?.retryPresentWorkItem = nil
                            self?.update()
                        }
                        retryPresentWorkItem = retry
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: retry)
                    }
                    return
                }
                retryPresentWorkItem?.cancel()
                retryPresentWorkItem = nil
                pendingClose = false
                let isTextItem = (item.id as? String)?.hasPrefix("text:") == true
                parent.destination.image = isTextItem ? nil : parent.preview(item)
                let controller = NoteHeroHost(
                    rootView: parent.content(item, { [weak self] in self?.close() }),
                    darkStatusBar: !parent.card
                )
                controller.view.backgroundColor = .clear
                controller.view.traitOverrides.imageDynamicRange = .high
                controller.modalPresentationStyle = .custom
                controller.transitioningDelegate = self
                host = controller
                displayedRevision = parent.contentRevision
                let pan = NoteHeroPanGestureRecognizer(target: self, action: #selector(drag(_:)))
                pan.maximumNumberOfTouches = 1
                pan.delegate = self
                controller.view.addGestureRecognizer(pan)
                presenter.present(controller, animated: true) { [weak self] in
                    guard let self else { return }
                    if self.pendingClose {
                        self.pendingClose = false
                        self.close()
                    } else {
                        self.update()
                    }
                }
            } else if parent.item == nil, host != nil, !closing {
                close()
            } else if let item = parent.item, let host, !closing, parent.card,
                      !host.isBeingPresented, interactive == nil, displayedRevision != parent.contentRevision {
                // Refresh author metadata on the reader. The image viewer owns
                // its paging state for the duration of its presentation.
                host.hosting.rootView = parent.content(item, { [weak self] in self?.close() })
                displayedRevision = parent.contentRevision
            }
        }

        private func close() {
            guard let host, !closing else { return }
            if host.isBeingPresented {
                pendingClose = true
                return
            }
            guard host.presentingViewController != nil else {
                didClose()
                return
            }
            closing = true
            scrollLock = scrollLock ?? NoteHeroScrollLock(in: host.view)
            host.dismiss(animated: true) { [weak self] in self?.didClose() }
        }

        private func didClose() {
            retryPresentWorkItem?.cancel()
            retryPresentWorkItem = nil
            pendingClose = false
            scrollLock?.restore()
            scrollLock = nil
            host = nil
            closing = false
            parent.destination.resetFrames()
            parent.source.setConcealed(card: nil, content: nil, header: false)
            parent.item = nil
            parent.onDismiss()
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            recordNoteHeroDiagnostic("gesture \(type(of: gesture)) closing=\(closing) presenting=\(host?.isBeingPresented ?? false) nested=\(host?.presentedViewController != nil) touches=\(gesture.numberOfTouches)")
            guard let pan = gesture as? UIPanGestureRecognizer, let host, !closing,
                  !host.isBeingPresented, host.presentedViewController == nil else { return false }
            if let interactive { return interactive.isReturning && !UIAccessibility.isReduceMotionEnabled }
            let velocity = pan.velocity(in: host.view)
            // Full-screen media viewers reserve horizontal swipes for paging
            // between photos/videos; note detail pages allow global rightward
            // return across the whole reader.
            let horizontal = parent.card && NoteHeroReturnDirection.isHorizontal(velocity)
            guard horizontal || velocity.y > abs(velocity.x) else { return false }
            let startLocation = (pan as? NoteHeroPanGestureRecognizer)?.initialLocation(in: host.view)
                ?? pan.location(in: host.view)
            let leadingDistance = host.view.effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? (host.view.bounds.width - startLocation.x)
                : startLocation.x
            let mediaViewportID = parent.destination.selectedID.isEmpty
                ? parent.source.selectedID
                : parent.destination.selectedID
            let mediaViewport = parent.card && !mediaViewportID.isEmpty
                ? parent.destination.frame("viewport", mediaViewportID, in: host.view)
                : nil
            let inMediaViewport = mediaViewport?.contains(startLocation) ?? false
            var touched = host.view.hitTest(startLocation, with: nil)
            var touchedHorizontalScroll: UIScrollView?
            while let view = touched {
                if !horizontal, view is UIControl {
                    recordNoteHeroDiagnostic("drag blocked by control \(type(of: view))")
                    return false
                }
                if let scroll = view as? UIScrollView {
                    if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
                        recordNoteHeroDiagnostic("drag blocked by zoom \(scroll.zoomScale) min \(scroll.minimumZoomScale) \(type(of: scroll))")
                        return false
                    }
                    if horizontal, parent.card,
                       touchedHorizontalScroll == nil,
                       scroll.contentSize.width > scroll.bounds.width + 1 {
                        touchedHorizontalScroll = scroll
                    }
                    if !horizontal, parent.card, scroll.contentSize.height > scroll.bounds.height + 1,
                       scroll.contentOffset.y > -scroll.adjustedContentInset.top + 1 {
                        recordNoteHeroDiagnostic("drag blocked by reader scroll \(type(of: scroll))")
                        return false
                    }
                }
                touched = view.superview
            }
            if horizontal, parent.card {
                // Inside a multi-page media carousel, let right swipes flip
                // back to earlier photos unless the user is already on the
                // first page or starts from the leading screen edge.
                let inMediaPager = inMediaViewport || touchedHorizontalScroll != nil
                let canPageBackward: Bool
                if inMediaViewport || (mediaViewport == nil && touchedHorizontalScroll != nil) {
                    canPageBackward = parent.destination.canPageBackward
                } else if let scroll = touchedHorizontalScroll {
                    canPageBackward = scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1
                } else {
                    canPageBackward = false
                }
                if NoteHeroReturnPolicy.shouldYieldHorizontalDrag(
                    leadingDistance: leadingDistance,
                    inMediaPager: inMediaPager,
                    canPageBackward: canPageBackward
                ) {
                    recordNoteHeroDiagnostic("drag yielded to horizontal pager leading=\(leadingDistance) canPageBackward=\(canPageBackward)")
                    return false
                }
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Decide at the start of each touch, including lazily created
            // pages. An ineligible return fails in shouldBegin, allowing
            // normal body scrolling, media paging, or zoomed-image panning.
            guard let host, let scroll = otherGestureRecognizer.view as? UIScrollView,
                  otherGestureRecognizer === scroll.panGestureRecognizer else { return false }
            return scroll.isDescendant(of: host.view)
        }
        @objc private func drag(_ pan: UIPanGestureRecognizer) {
            guard let host else { return }
            let translation = pan.translation(in: host.view.window)
            let velocity = pan.velocity(in: host.view.window)
            switch pan.state {
            case .began:
                AppFeedback.prepareForGesture()
                recordNoteHeroDiagnostic("free drag began card=\(parent.card)")
                if let interactive {
                    interactive.retake(anchor: pan.location(in: host.view.window))
                } else {
                    scrollLock = NoteHeroScrollLock(in: host.view)
                    let isEdge = parent.card && NoteHeroReturnDirection.isHorizontal(velocity)
                    let interaction = NoteHeroInteraction(card: parent.card, source: parent.source, destination: parent.destination,
                                                          viewport: host.view.window?.bounds.size ?? host.view.bounds.size,
                                                          edge: isEdge,
                                                          foregroundHeader: parent.foregroundHeader,
                                                          cardFooter: parent.cardFooter)
                    interaction.anchor = pan.location(in: host.view.window)
                    interaction.onComplete = { [weak self] completed in
                        guard let self else { return }
                        self.interactive = nil
                        if completed { self.didClose() }
                        else {
                            self.scrollLock?.restore()
                            self.scrollLock = nil
                            self.update()
                        }
                    }
                    interactive = interaction
                    host.dismiss(animated: true)
                }
                interactive?.move(translation)
            case .changed: interactive?.move(translation)
            case .ended, .cancelled, .failed:
                closing = interactive?.release(velocity: velocity, cancelled: pan.state != .ended) ?? false
            default: break
            }
        }

        func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                                 source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
            NoteHeroAnimator(opening: true, card: parent.card, source: parent.source,
                             destination: parent.destination, foregroundHeader: parent.foregroundHeader,
                             cardFooter: parent.cardFooter)
        }
        func presentationController(forPresented presented: UIViewController, presenting: UIViewController?,
                                    source: UIViewController) -> UIPresentationController? {
            NoteHeroPresentationController(presentedViewController: presented, presenting: presenting)
        }
        func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
            NoteHeroAnimator(opening: false, card: parent.card, source: parent.source,
                             destination: parent.destination, foregroundHeader: parent.foregroundHeader,
                             cardFooter: parent.cardFooter)
        }
        func interactionControllerForDismissal(using animator: any UIViewControllerAnimatedTransitioning)
            -> (any UIViewControllerInteractiveTransitioning)? {
                recordNoteHeroDiagnostic("dismiss interaction available=\(interactive != nil)")
                return interactive
            }
    }
}

private final class NoteHeroPresentationController: UIPresentationController {
    override var shouldRemovePresentersView: Bool { false }
    override var frameOfPresentedViewInContainerView: CGRect { containerView?.bounds ?? .zero }
    override func containerViewWillLayoutSubviews() { presentedView?.frame = frameOfPresentedViewInContainerView }
}

final class NoteHeroPresenter: UIViewController {
    var onAppear: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); onAppear?() }
}

private final class NoteHeroHost<Content: View>: UIViewController {
    let hosting: UIHostingController<Content>
    private let darkStatusBar: Bool

    init(rootView: Content, darkStatusBar: Bool = false) {
        hosting = UIHostingController(rootView: rootView)
        self.darkStatusBar = darkStatusBar
        super.init(nibName: nil, bundle: nil)
        if darkStatusBar {
            modalPresentationCapturesStatusBarAppearance = true
            overrideUserInterfaceStyle = .dark
        }
    }
    required init?(coder: NSCoder) { nil }
    override var preferredStatusBarStyle: UIStatusBarStyle {
        darkStatusBar ? .lightContent : super.preferredStatusBarStyle
    }
    override var childForStatusBarStyle: UIViewController? {
        darkStatusBar ? nil : hosting
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }
}

/// Shares the same image/title handoff between automatic and finger-driven
/// transitions. An interactive drag never scrubs the opening animation curve.
@MainActor
final class NoteHeroScene {
    let context: any UIViewControllerContextTransitioning
    let opening: Bool
    let card: Bool
    let page: UIView
    let container: UIView
    let transitionRoot: UIView
    let dimmingView: UIView
    let cardShadowView: UIView
    let stage: UIView
    private let mediaWindow = UIView()
    private let mediaMask = UIView()
    private let titleWindow = UIView()
    private let titleMask = UIView()
    let movingImage: UIImageView
    private let returningCover: UIImageView?
    let movingTitle = UILabel()
    private let sourceTitleView = UILabel()
    let background: UIView
    let cardMask = UIView()
    let from: CGRect
    let to: CGRect
    let cardFrame: CGRect
    let sourceFooter: CGRect
    private let visibleCardFrame: CGRect
    private let sourceViewport: CGRect
    private let destinationViewport: CGRect
    private let titleViewport: CGRect
    private let source: NoteHeroGeometry
    private let destination: NoteHeroGeometry
    private let id: String
    private let screenRadius: CGFloat
    private let dragRadius: CGFloat
    private let dragShadowOpacity: Float
    private let restingShadowOpacity: Float
    private let maxDimAlpha: CGFloat
    private let cardBorderColor: CGColor
    private let sourceTitle: CGRect?
    private let destinationTitle: CGRect?
    private let titleScale: CGFloat
    private let transfersTitle: Bool
    private let transfersImage: Bool
    private let hasSourceCard: Bool
    private let coverScrolledOffscreen: Bool
    private var shouldConcealSourceCard: Bool { hasSourceCard && !coverScrolledOffscreen }
    private let feedForeground: NoteHeroFeedForeground?
    let headerController: UIHostingController<AnyView>?
    let footerController: UIHostingController<AnyView>?
    private var inputSurface: NoteHeroTransitionInput?
    private var settlement: UIViewPropertyAnimator?
    private var settlementID = 0

    init?(context: any UIViewControllerContextTransitioning, opening: Bool, card: Bool,
          source: NoteHeroGeometry, destination: NoteHeroGeometry,
          foregroundHeader: (() -> AnyView)? = nil,
          cardFooter: (() -> AnyView)? = nil) {
        self.context = context; self.opening = opening; self.card = card
        self.source = source; self.destination = destination
        container = context.containerView
        transitionRoot = UIView(frame: container.bounds)
        transitionRoot.backgroundColor = .clear
        transitionRoot.clipsToBounds = false
        dimmingView = UIView(frame: container.bounds)
        dimmingView.backgroundColor = .black
        dimmingView.isUserInteractionEnabled = false
        dimmingView.isHidden = !card
        cardShadowView = UIView(frame: container.bounds)
        cardShadowView.clipsToBounds = false
        cardShadowView.layer.masksToBounds = false
        cardShadowView.layer.cornerCurve = .continuous
        cardShadowView.layer.shadowColor = UIColor.black.cgColor
        cardShadowView.isUserInteractionEnabled = false
        cardShadowView.isHidden = !card
        let isDark = container.traitCollection.userInterfaceStyle == .dark
        dragShadowOpacity = isDark ? 0.45 : 0.22
        restingShadowOpacity = isDark ? 0.16 : 0.06
        maxDimAlpha = isDark ? 0.24 : 0.12
        cardBorderColor = isDark
            ? UIColor.white.withAlphaComponent(0.10).cgColor
            : UIColor.label.withAlphaComponent(0.06).cgColor
        cardShadowView.layer.borderColor = cardBorderColor
        stage = UIView(frame: container.bounds)
        let key: UITransitionContextViewControllerKey = opening ? .to : .from
        guard let controller = context.viewController(forKey: key),
              let page = context.view(forKey: opening ? .to : .from) else { return nil }
        self.page = page
        if opening {
            page.frame = context.finalFrame(for: controller)
            container.addSubview(page)
        }
        func layoutHierarchy(_ vc: UIViewController) {
            vc.viewIfLoaded?.setNeedsLayout()
            vc.viewIfLoaded?.layoutIfNeeded()
            for child in vc.children { layoutHierarchy(child) }
        }
        page.setNeedsLayout()
        page.layoutIfNeeded()
        layoutHierarchy(controller)
        if card, let foregroundHeader {
            let windowInsets = container.window?.safeAreaInsets ?? container.safeAreaInsets
            let isRTL = container.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let topInset = NoteHeroFeedForeground.resolvedHeaderTopInset(
                measuredHeaderMinY: source.frame("header", "feed", in: container)?.minY,
                safeAreaTop: windowInsets.top
            )
            headerController = NoteHeroFeedForeground.makeHeaderOverlay(
                topInset: topInset,
                leadingInset: isRTL ? windowInsets.right : windowInsets.left,
                trailingInset: isRTL ? windowInsets.left : windowInsets.right,
                content: foregroundHeader
            )
        } else {
            headerController = nil
        }
        feedForeground = card ? NoteHeroFeedForeground(
            presenting: context.viewController(forKey: opening ? .from : .to),
            in: container, header: headerController?.view, headerController: headerController) : nil
        id = card ? source.selectedID : destination.selectedID
        let image = destination.still(id) ?? source.still(id)
        transfersImage = !card || image != nil
        // The reader must keep the same sharp still after the full-screen
        // overlay leaves, including a page that was created before it loaded.
        if !card, !opening, let image { source.adoptStill(image, for: id) }
        let bounds = container.bounds
        let fallback: CGRect
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            fallback = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height)
        } else { fallback = bounds }
        let measuredCardFrame = source.isCardPresent(id) ? source.frame("card", id, in: container) : nil
        let measuredImageFrame = source.isCardPresent(id) ? source.frame("image", id, in: container) : nil
        let rawDestinationViewport = destination.frame("viewport", id, in: container)
        let rawDestinationImage = destination.frame("image", id, in: container)
        from = card
            ? NoteHeroFrameResolver.resolveSourceImageFrame(
                measuredImage: measuredImageFrame,
                cardFrame: measuredCardFrame,
                coverRatio: source.coverRatio,
                fallback: fallback
            )
            : (measuredImageFrame ?? fallback)
        to = NoteHeroFrameResolver.resolveDestinationImageFrame(
            measuredImage: rawDestinationImage,
            viewport: rawDestinationViewport,
            imageSize: image?.size,
            fallback: fallback
        )
        cardFrame = measuredCardFrame ?? from
        sourceFooter = card
            ? NoteHeroFrameResolver.resolveSourceFooterFrame(
                measuredFooter: source.isCardPresent(id) ? source.frame("footer", id, in: container) : nil,
                cardFrame: cardFrame
            )
            : .zero
        let resolvedVisibleCard = source.visibleCardFrame(id, in: container) ?? cardFrame.intersection(bounds)
        visibleCardFrame = resolvedVisibleCard.isNull
            ? CGRect(x: cardFrame.minX, y: min(max(cardFrame.minY, bounds.minY), bounds.maxY),
                     width: cardFrame.width, height: 0)
            : resolvedVisibleCard
        hasSourceCard = !card || (measuredCardFrame != nil && !visibleCardFrame.isEmpty)
        func scrollBand(_ geometry: NoteHeroGeometry, id: String, in coordinateView: UIView) -> CGRect {
            var clip = (geometry.frame("scroll", id, in: coordinateView) ??
                geometry.frame("scroll", "feed", in: coordinateView) ?? bounds).intersection(bounds)
            if clip.isNull { clip = bounds }
            if let topBar = geometry.frame("topBar", id, in: coordinateView), !topBar.isEmpty {
                let minY = max(clip.minY, topBar.maxY)
                clip = CGRect(x: clip.minX, y: minY, width: clip.width, height: max(0, clip.maxY - minY))
            }
            if let bottomBar = geometry.frame("bottomBar", id, in: coordinateView), !bottomBar.isEmpty {
                let maxY = min(clip.maxY, bottomBar.minY)
                clip = CGRect(x: clip.minX, y: clip.minY, width: clip.width, height: max(0, maxY - clip.minY))
            }
            return clip
        }
        func viewport(_ geometry: NoteHeroGeometry, id: String, in coordinateView: UIView, fallback: CGRect) -> CGRect {
            let media = geometry.frame("viewport", id, in: coordinateView) ?? fallback
            let scroll = scrollBand(geometry, id: id, in: coordinateView)
            let visible = media.intersection(scroll).intersection(bounds)
            return visible.isNull ? CGRect(x: media.minX, y: scroll.minY, width: media.width, height: 0) : visible
        }
        let rawSourceViewport = viewport(source, id: id, in: container, fallback: from)
        if card, !visibleCardFrame.isEmpty {
            let clipped = rawSourceViewport.intersection(visibleCardFrame)
            sourceViewport = clipped.isNull ? visibleCardFrame : clipped
        } else {
            sourceViewport = rawSourceViewport
        }
        destinationViewport = viewport(destination, id: id, in: container, fallback: to)
        titleViewport = scrollBand(destination, id: id, in: container)
        coverScrolledOffscreen = card && !opening && transfersImage && destinationViewport.height <= 1
        if card, hasSourceCard, !coverScrolledOffscreen, let cardFooter, !sourceFooter.isEmpty {
            let controller = UIHostingController(rootView: cardFooter())
            controller.safeAreaRegions = []
            controller.view.backgroundColor = .clear
            controller.view.isUserInteractionEnabled = false
            controller.view.bounds = CGRect(origin: .zero, size: sourceFooter.size)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            footerController = controller
        } else {
            footerController = nil
        }
        movingImage = UIImageView(image: image)
        movingImage.preferredImageDynamicRange = .high
        movingImage.contentMode = .scaleAspectFill
        movingImage.clipsToBounds = true
        if card, !opening, transfersImage, let cover = destination.image, cover !== image {
            // A reader can close from its second image, while the feed card
            // still has the first cover. Blend back before the real card is
            // revealed, rather than swapping photographs at the final frame.
            let coverView = UIImageView(image: cover)
            coverView.contentMode = .scaleAspectFill
            coverView.preferredImageDynamicRange = .high
            coverView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            coverView.frame = movingImage.bounds
            movingImage.addSubview(coverView)
            returningCover = coverView
        } else { returningCover = nil }
        background = UIView(frame: bounds)
        background.backgroundColor = card ? .systemBackground : .black
        background.clipsToBounds = true
        sourceTitle = hasSourceCard ? source.frame("title", id, in: container) : nil
        destinationTitle = destination.frame("title", id, in: container)
        transfersTitle = card && hasSourceCard && !coverScrolledOffscreen && NoteHeroTitleVisibility.canTransfer(
            source: sourceTitle, destination: destinationTitle, text: source.title, viewport: titleViewport)
        let sourceLabel = source.view("title", id) as? UILabel
        let destinationLabel = destination.view("title", id) as? UILabel
        titleScale = max(0.3, (sourceLabel?.font.pointSize ?? 15) / max(destinationLabel?.font.pointSize ?? 20, 1))
        if transfersImage && !coverScrolledOffscreen {
            source.conceal("image", id, true); destination.conceal("image", id, true)
        }
        page.backgroundColor = .clear
        transitionRoot.addSubview(dimmingView)
        transitionRoot.addSubview(cardShadowView)
        transitionRoot.addSubview(stage)
        if let feedForeground {
            feedForeground.insert(transitionRoot, convertingFrom: container)
            headerController?.view.layoutIfNeeded()
        } else { container.addSubview(transitionRoot) }
        if card {
            // Only hide the real feed header when the foreground overlay is
            // actually mounted above stage; on iPad/non-tabbar hosts leave the
            // real header untouched so it never blinks out.
            let concealCard = hasSourceCard && !coverScrolledOffscreen
            source.setConcealed(
                card: concealCard ? id : nil,
                content: concealCard ? id : nil,
                header: feedForeground != nil && headerController != nil
            )
            if transfersTitle {
                source.conceal("title", id, true); destination.conceal("title", id, true)
            }
        }
        stage.addSubview(background)
        stage.addSubview(page)
        if let footerView = footerController?.view {
            stage.addSubview(footerView)
        }
        mediaWindow.frame = bounds
        mediaMask.backgroundColor = .white
        mediaWindow.mask = mediaMask
        mediaWindow.isHidden = !transfersImage || coverScrolledOffscreen
        stage.addSubview(mediaWindow)
        mediaWindow.addSubview(movingImage)
        if transfersTitle, let sourceTitle, let destinationTitle {
            sourceTitleView.attributedText = sourceLabel?.attributedText ?? NSAttributedString(string: source.title)
            sourceTitleView.font = sourceLabel?.font ?? .systemFont(ofSize: 15, weight: .semibold)
            sourceTitleView.numberOfLines = sourceLabel?.numberOfLines ?? 2
            sourceTitleView.bounds = CGRect(origin: .zero, size: sourceTitle.size)
            movingTitle.attributedText = destinationLabel?.attributedText ?? NSAttributedString(string: source.title)
            movingTitle.font = destinationLabel?.font ?? .systemFont(ofSize: 20, weight: .semibold)
            movingTitle.numberOfLines = 0
            movingTitle.bounds = CGRect(origin: .zero, size: destinationTitle.size)
            titleWindow.frame = bounds
            titleMask.backgroundColor = .white
            titleWindow.mask = titleMask
            stage.addSubview(titleWindow)
            titleWindow.addSubview(sourceTitleView)
            titleWindow.addSubview(movingTitle)
        }
        cardMask.backgroundColor = .white
        cardMask.layer.cornerCurve = .continuous
        cardMask.clipsToBounds = true
        if #available(iOS 26.0, *) {
            // Resolve the device's public concentric corner geometry at full size,
            // before scaling it with the held page. All content shares this mask.
            let cornerProbe = UIView(frame: bounds)
            cornerProbe.cornerConfiguration = .uniformCorners(radius: .containerConcentric())
            container.addSubview(cornerProbe)
            cornerProbe.layoutIfNeeded()
            screenRadius = cornerProbe.effectiveRadius(corner: .allCorners)
            cornerProbe.removeFromSuperview()
        } else {
            let bottomInset = container.window?.safeAreaInsets.bottom ?? container.safeAreaInsets.bottom
            screenRadius = bottomInset > 0 ? 44 : 0
        }
        dragRadius = max(screenRadius, 22)
        recordNoteHeroDiagnostic("scene card=\(card) screenRadius=\(screenRadius) source=\(cardFrame) destination=\(to)")
        if card { stage.mask = cardMask }
        if feedForeground != nil {
            let input = NoteHeroTransitionInput(frame: bounds)
            input.target = page
            input.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(input)
            inputSurface = input
        }
        setEndpoint(expanded: !opening)
    }

    private func collapsedPageTransform() -> CGAffineTransform {
        let bounds = container.bounds
        let scale = max(0.2, visibleCardFrame.width / max(bounds.width, 1))
        let tx = visibleCardFrame.midX - bounds.midX
        let ty = visibleCardFrame.minY - bounds.midY * (1 - scale)
        return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
    }

    static func clampedInitialVelocity(velocity: CGPoint, delta: CGPoint, expanded: Bool) -> CGVector {
        let distance = hypot(delta.x, delta.y)
        let minVelocity: CGFloat = expanded ? -2.5 : -0.8
        let maxVelocity: CGFloat = expanded ? 4.5 : 3.5
        let projected: CGFloat = distance > 16
            ? max(minVelocity, min(maxVelocity, (velocity.x * delta.x + velocity.y * delta.y) / (distance * distance)))
            : 0
        let vx: CGFloat = abs(delta.x) > 24 ? max(minVelocity, min(maxVelocity, velocity.x / delta.x)) : projected
        let vy: CGFloat = abs(delta.y) > 24 ? max(minVelocity, min(maxVelocity, velocity.y / delta.y)) : projected
        return CGVector(dx: vx, dy: vy)
    }

    func setEndpoint(expanded: Bool, animatePageAlpha: Bool = true, animateFooterAlpha: Bool = true) {
        transitionRoot.alpha = 1
        stage.transform = .identity
        stage.alpha = 1
        if expanded {
            page.transform = .identity
        } else if card && hasSourceCard {
            page.transform = collapsedPageTransform()
        }
        movingImage.frame = expanded ? to : from
        mediaMask.frame = expanded ? destinationViewport : sourceViewport
        titleMask.frame = expanded ? titleViewport : visibleCardFrame
        returningCover?.alpha = expanded ? 0 : 1
        let cardSurfaceFrame = expanded ? container.bounds : visibleCardFrame
        background.frame = card ? cardSurfaceFrame : container.bounds
        background.backgroundColor = card
            ? (expanded ? .systemBackground : .secondarySystemGroupedBackground)
            : .black
        background.alpha = card || expanded ? 1 : 0
        cardMask.frame = cardSurfaceFrame
        cardMask.layer.cornerRadius = expanded ? screenRadius : 14
        if card {
            cardShadowView.transform = .identity
            cardShadowView.frame = cardSurfaceFrame
            cardShadowView.backgroundColor = expanded ? .systemBackground : .secondarySystemGroupedBackground
            cardShadowView.layer.cornerRadius = expanded ? screenRadius : 14
            cardShadowView.layer.shadowOpacity = expanded ? 0 : restingShadowOpacity
            cardShadowView.layer.shadowRadius = expanded ? 24 : 8
            cardShadowView.layer.shadowOffset = expanded ? CGSize(width: 0, height: 8) : CGSize(width: 0, height: 3)
            cardShadowView.layer.borderWidth = expanded ? 0 : 0.5
            cardShadowView.alpha = 1
            dimmingView.alpha = expanded ? maxDimAlpha : 0
        }
        if let footerView = footerController?.view {
            if expanded {
                let expandScale = max(0.2, container.bounds.width / max(cardFrame.width, 1))
                let bottomMargin = max(0, cardFrame.maxY - sourceFooter.midY)
                footerView.center = CGPoint(
                    x: container.bounds.midX,
                    y: container.bounds.maxY - bottomMargin * expandScale
                )
                footerView.transform = CGAffineTransform(scaleX: expandScale, y: expandScale)
            } else {
                footerView.center = CGPoint(x: sourceFooter.midX, y: sourceFooter.midY)
                footerView.transform = .identity
            }
            if animateFooterAlpha {
                footerView.alpha = expanded ? 0 : 1
            }
        }
        if transfersTitle, let sourceTitle, let destinationTitle {
            let targetCenter = expanded
                ? CGPoint(x: destinationTitle.midX, y: destinationTitle.midY)
                : CGPoint(x: sourceTitle.midX, y: sourceTitle.midY)
            sourceTitleView.center = targetCenter
            sourceTitleView.transform = expanded
                ? CGAffineTransform(scaleX: 1 / titleScale, y: 1 / titleScale)
                : .identity
            sourceTitleView.alpha = expanded ? 0 : 1
            movingTitle.center = targetCenter
            movingTitle.transform = expanded
                ? .identity
                : CGAffineTransform(scaleX: titleScale, y: titleScale)
            movingTitle.alpha = expanded ? 1 : 0
        }
        if animatePageAlpha {
            page.alpha = expanded ? 1 : 0
        }
        feedForeground?.alpha = expanded ? 0 : 1
    }

    /// Bake any interactive stage transform into child frames in container
    /// coordinates before animating back to the card, so the dismiss spring
    /// travels in a single straight coordinate space instead of multiplying
    /// parent and child spring curves into a curved swoop.
    private func bakeStageTransformForDismiss() {
        guard card, stage.transform != .identity else { return }
        let savedTransform = stage.transform
        let currentScale = max(0.2, hypot(savedTransform.a, savedTransform.b))
        let stageRect = stage.convert(container.bounds, to: container)
        let mappedImage = stage.convert(to, to: container)
        let clippedMediaMask = stage.convert(destinationViewport, to: container).intersection(stageRect)
        let mappedMediaMask = clippedMediaMask.isNull ? stageRect : clippedMediaMask
        let clippedTitleMask = stage.convert(titleViewport, to: container).intersection(stageRect)
        let mappedTitleMask = clippedTitleMask.isNull ? stageRect : clippedTitleMask
        let mappedTitle = destinationTitle.map { stage.convert($0, to: container) }
        UIView.performWithoutAnimation {
            stage.transform = .identity
            page.transform = savedTransform
            cardShadowView.transform = .identity
            cardShadowView.frame = stageRect
            cardShadowView.layer.cornerRadius = dragRadius * currentScale
            cardMask.frame = stageRect
            cardMask.layer.cornerRadius = dragRadius * currentScale
            background.frame = stageRect
            background.backgroundColor = .systemBackground
            movingImage.frame = mappedImage
            mediaMask.frame = mappedMediaMask
            titleMask.frame = mappedTitleMask
            if let footerView = footerController?.view {
                let footerScale = max(0.2, stageRect.width / max(sourceFooter.width, 1))
                let bottomMargin = max(0, cardFrame.maxY - sourceFooter.midY)
                footerView.center = CGPoint(
                    x: stageRect.midX,
                    y: stageRect.maxY - bottomMargin * footerScale
                )
                footerView.transform = CGAffineTransform(scaleX: footerScale, y: footerScale)
                footerView.alpha = 0
            }
            if transfersTitle, let mappedTitle {
                let center = CGPoint(x: mappedTitle.midX, y: mappedTitle.midY)
                movingTitle.center = center
                movingTitle.transform = CGAffineTransform(scaleX: currentScale, y: currentScale)
                movingTitle.alpha = 1
                sourceTitleView.center = center
                sourceTitleView.transform = CGAffineTransform(scaleX: currentScale / titleScale,
                                                              y: currentScale / titleScale)
                sourceTitleView.alpha = 0
            }
        }
    }

    /// Geometry follows both axes in screen points; no easing while a finger is
    /// down. Scaling is anchored to the actual touch, so the image stays held.
    func follow(translation: CGPoint, anchor: CGPoint, edge: Bool) {
        let bounds = container.bounds
        let damped = CGPoint(
            x: edge ? NoteHeroDragGeometry.rubberBand(translation.x) : translation.x,
            y: edge ? translation.y : NoteHeroDragGeometry.rubberBand(translation.y)
        )
        let progress = max(0, edge ? damped.x / max(bounds.width, 1) : damped.y / max(bounds.height, 1))
        let scale = UIAccessibility.isReduceMotionEnabled ? 1 :
            max(edge ? 0.78 : 0.52, 1 - progress * (edge ? 0.22 : 0.65))
        let tx = damped.x + (anchor.x - bounds.midX) * (1 - scale)
        let ty = damped.y + (anchor.y - bounds.midY) * (1 - scale)
        let transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
        func rect(_ original: CGRect) -> CGRect {
            CGRect(x: bounds.midX + (original.minX - bounds.midX) * scale + tx,
                   y: bounds.midY + (original.minY - bounds.midY) * scale + ty,
                   width: original.width * scale, height: original.height * scale)
        }
        if card {
            stage.transform = transform
            stage.alpha = 1
            cardShadowView.transform = .identity
            cardShadowView.bounds = bounds
            cardShadowView.center = CGPoint(x: bounds.midX, y: bounds.midY)
            cardShadowView.transform = transform
            cardShadowView.backgroundColor = .systemBackground
            cardShadowView.alpha = 1
            cardShadowView.layer.cornerRadius = progress > 0.001 ? dragRadius : screenRadius
            cardShadowView.layer.shadowOpacity = dragShadowOpacity * Float(min(1, progress / 0.08))
            cardShadowView.layer.shadowRadius = 26
            cardShadowView.layer.shadowOffset = CGSize(width: 0, height: 10)
            cardShadowView.layer.borderWidth = progress > 0.001 ? 0.5 : 0
            dimmingView.alpha = maxDimAlpha * max(0, 1 - progress / 0.55)
            footerController?.view.alpha = 0
            page.transform = .identity
            movingImage.frame = to
            mediaMask.frame = destinationViewport
            titleMask.frame = titleViewport
            returningCover?.alpha = 0
            background.frame = bounds
            background.backgroundColor = .systemBackground
            cardMask.frame = bounds
            cardMask.layer.cornerRadius = progress > 0.001 ? dragRadius : screenRadius
            if transfersTitle, let destinationTitle {
                let center = CGPoint(x: destinationTitle.midX, y: destinationTitle.midY)
                movingTitle.center = center
                movingTitle.transform = .identity
                movingTitle.alpha = 1
                sourceTitleView.center = center
                sourceTitleView.transform = CGAffineTransform(scaleX: 1 / titleScale, y: 1 / titleScale)
                sourceTitleView.alpha = 0
            }
            page.alpha = 1
            // Reveal the stationary bar early in the drag. This is driven by
            // the finger's distance, including when a cancellation is caught.
            feedForeground?.alpha = min(1, progress / 0.12)
        } else {
            movingImage.frame = rect(to)
            mediaMask.frame = rect(destinationViewport)
            background.alpha = max(0, 1 - progress / 0.65)
            page.alpha = max(0, 1 - progress * bounds.height / 130)
        }
        context.updateInteractiveTransition(min(0.99, progress))
    }

    func settle(expanded: Bool, velocity: CGPoint = .zero, completion: @escaping () -> Void) {
        settlementID += 1
        let token = settlementID
        if card, !expanded, (!hasSourceCard || coverScrolledOffscreen) {
            // Card was removed from the feed (e.g. unliked in Bookmarks or
            // filtered via #topic) or its cover is scrolled completely offscreen
            // in the reader: dismiss with a crisp scale-fade instead of flying
            // to a neighbor slot or swooping in from y < 0.
            footerController?.view.alpha = 0
            let animator = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0.18 : 0.24, curve: .easeOut) {
                if !UIAccessibility.isReduceMotionEnabled {
                    self.stage.transform = self.stage.transform.scaledBy(x: 0.92, y: 0.92)
                    self.cardShadowView.transform = self.cardShadowView.transform.scaledBy(x: 0.92, y: 0.92)
                }
                self.stage.alpha = 0
                self.cardShadowView.alpha = 0
                self.dimmingView.alpha = 0
                self.feedForeground?.alpha = 1
            }
            animator.addCompletion { [weak self] _ in
                guard let self, self.settlementID == token else { return }
                self.settlement = nil
                completion()
            }
            settlement = animator
            animator.startAnimation()
            return
        }
        if UIAccessibility.isReduceMotionEnabled {
            // Crossfade the settled geometry. Shortening a spatial spring still
            // performs the motion the user asked to reduce.
            let snapshot = transitionRoot.snapshotView(afterScreenUpdates: false)
            if let snapshot {
                snapshot.frame = transitionRoot.frame
                transitionRoot.superview?.insertSubview(snapshot, aboveSubview: transitionRoot)
            }
            UIView.performWithoutAnimation {
                self.setEndpoint(expanded: expanded)
                self.transitionRoot.alpha = 0
            }
            let animator = UIViewPropertyAnimator(duration: 0.2, curve: .easeOut) {
                self.transitionRoot.alpha = 1
                snapshot?.alpha = 0
            }
            animator.addCompletion { [weak self] _ in
                snapshot?.removeFromSuperview()
                guard let self, self.settlementID == token else { return }
                self.settlement = nil
                completion()
            }
            settlement = animator
            animator.startAnimation()
            return
        }
        if card, !expanded {
            if stage.transform != .identity {
                bakeStageTransformForDismiss()
            } else {
                // Non-interactive tap-Back dismiss: prime floating shadow immediately
                // so the sheet lifts cleanly off the feed while shrinking into the card.
                UIView.performWithoutAnimation {
                    self.cardShadowView.transform = .identity
                    self.cardShadowView.frame = self.container.bounds
                    self.cardShadowView.layer.cornerRadius = self.screenRadius
                    self.cardShadowView.layer.shadowOpacity = self.dragShadowOpacity * 0.9
                    self.cardShadowView.layer.shadowRadius = 22
                    self.cardShadowView.layer.shadowOffset = CGSize(width: 0, height: 8)
                    self.cardShadowView.layer.borderWidth = 0.5
                }
            }
        }
        let useStageCenter = card && (!transfersImage || coverScrolledOffscreen)
        let targetCenter: CGPoint = if useStageCenter {
            expanded
                ? CGPoint(x: container.bounds.midX, y: container.bounds.midY)
                : CGPoint(x: visibleCardFrame.midX, y: visibleCardFrame.midY)
        } else {
            expanded ? CGPoint(x: to.midX, y: to.midY) : CGPoint(x: from.midX, y: from.midY)
        }
        let currentCenter = useStageCenter
            ? stage.convert(CGPoint(x: container.bounds.midX, y: container.bounds.midY), to: container)
            : stage.convert(movingImage.center, to: container)
        let delta = CGPoint(x: targetCenter.x - currentCenter.x, y: targetCenter.y - currentCenter.y)
        let initialVelocity = Self.clampedInitialVelocity(velocity: velocity, delta: delta, expanded: expanded)
        let timing = UISpringTimingParameters(dampingRatio: expanded ? 0.86 : 1.0,
            initialVelocity: initialVelocity)
        let animator = UIViewPropertyAnimator(duration: expanded ? 0.44 : 0.40, timingParameters: timing)
        let separateFade = card && !expanded
        let separateFooterFade = card && footerController != nil
        animator.addAnimations {
            self.setEndpoint(
                expanded: expanded,
                animatePageAlpha: !separateFade,
                animateFooterAlpha: !separateFooterFade
            )
        }
        animator.addCompletion { [weak self] _ in
            guard let self, self.settlementID == token else { return }
            self.settlement = nil
            completion()
        }
        settlement = animator
        animator.startAnimation()
        if separateFade {
            // Body/chrome must leave before the title arrives at the small
            // card's text rectangle; they are not part of that title handoff.
            // Keep the real feed card concealed until `complete(_:)` so an empty
            // white card shell never flashes behind the returning stage.
            UIView.animate(withDuration: transfersImage ? 0.12 : 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.page.alpha = 0
            }
            if let footerView = footerController?.view {
                UIView.animate(withDuration: 0.17, delay: 0.05, options: [.beginFromCurrentState, .curveEaseOut]) {
                    footerView.alpha = 1
                }
            }
        } else if card, expanded, let footerView = footerController?.view {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                footerView.alpha = 0
            }
        }
    }

    /// A returning image can be caught again before the spring has stopped.
    func interruptReturn(anchor: CGPoint, edge: Bool) -> CGPoint {
        transitionRoot.layer.removeAllAnimations()
        dimmingView.layer.removeAllAnimations()
        cardShadowView.layer.removeAllAnimations()
        stage.layer.removeAllAnimations()
        background.layer.removeAllAnimations()
        page.layer.removeAllAnimations()
        returningCover?.layer.removeAllAnimations()
        footerController?.view.layer.removeAllAnimations()
        transitionRoot.alpha = 1
        stage.alpha = 1
        cardShadowView.alpha = 1
        background.alpha = 1
        background.backgroundColor = card ? .systemBackground : .black
        page.alpha = 1
        page.transform = .identity
        returningCover?.alpha = 0
        footerController?.view.alpha = 0
        if card && shouldConcealSourceCard {
            source.setConcealed(card: id, content: id)
        }
        let imageFrame = movingImage.layer.presentation()?.frame ?? movingImage.frame
        let stageLayer = stage.layer.presentation() ?? stage.layer
        let frame = stageLayer.convert(imageFrame, to: container.layer)
        settlementID += 1
        settlement?.stopAnimation(true)
        settlement = nil
        let translation = NoteHeroDragGeometry.resumedTranslation(
            frame: frame, expanded: to, bounds: container.bounds, anchor: anchor, horizontal: edge)
        follow(translation: translation, anchor: anchor, edge: edge)
        return translation
    }

    func complete(_ completed: Bool, completion: @escaping () -> Void = {}) {
        let returnsToFeed = card && opening != completed
        let finish = {
            UIView.performWithoutAnimation {
                self.source.conceal("image", self.id, false); self.destination.conceal("image", self.id, false)
                if self.card {
                    self.source.conceal("title", self.id, false); self.destination.conceal("title", self.id, false)
                    self.source.setConcealed(card: nil, content: nil, header: false)
                }
                self.page.transform = .identity; self.page.alpha = 1; self.page.mask = nil
                self.page.backgroundColor = !self.card && (self.opening == completed) ? .black : .clear
                self.container.addSubview(self.page)
                self.transitionRoot.removeFromSuperview()
                self.inputSurface?.removeFromSuperview()
                self.feedForeground?.restore()
                self.context.completeTransition(completed)
            }
            completion()
        }
        if returnsToFeed {
            // The declarative card visibility updates on SwiftUI's next
            // transaction. Keep the landed card and foreground above it until
            // that update is laid out; never expose an empty source for a frame.
            UIView.performWithoutAnimation {
                source.conceal("image", id, false)
                source.conceal("title", id, false)
                source.setConcealed(card: nil, content: nil, header: false)
            }
            DispatchQueue.main.async {
                UIView.performWithoutAnimation { self.container.window?.layoutIfNeeded() }
                finish()
            }
        } else {
            finish()
        }
    }
}

@MainActor
private final class NoteHeroInteraction: NSObject, UIViewControllerInteractiveTransitioning {
    let card: Bool
    let source: NoteHeroGeometry
    let destination: NoteHeroGeometry
    var onComplete: ((Bool) -> Void)?
    private var scene: NoteHeroScene?
    private var offset = CGPoint.zero
    private var translation = CGPoint.zero
    private let viewport: CGSize
    private let edge: Bool
    private let foregroundHeader: (() -> AnyView)?
    private let cardFooter: (() -> AnyView)?
    private var pendingRelease: (velocity: CGPoint, completed: Bool)?
    private var feedback = NoteDismissalFeedback()
    var anchor = CGPoint.zero
    private(set) var isReturning = false
    var wantsInteractiveStart: Bool { true }

    init(card: Bool, source: NoteHeroGeometry, destination: NoteHeroGeometry,
         viewport: CGSize, edge: Bool, foregroundHeader: (() -> AnyView)? = nil,
         cardFooter: (() -> AnyView)? = nil) {
        self.card = card; self.source = source; self.destination = destination
        self.viewport = viewport; self.edge = edge
        self.foregroundHeader = foregroundHeader; self.cardFooter = cardFooter
    }
    func startInteractiveTransition(_ transitionContext: any UIViewControllerContextTransitioning) {
        recordNoteHeroDiagnostic("free drag start transition")
        guard let scene = NoteHeroScene(context: transitionContext, opening: false, card: card,
                                        source: source, destination: destination,
                                        foregroundHeader: foregroundHeader,
                                        cardFooter: cardFooter) else {
            transitionContext.completeTransition(false); onComplete?(false); return
        }
        self.scene = scene
        scene.follow(translation: translation, anchor: anchor, edge: edge)
        if let release = pendingRelease {
            pendingRelease = nil
            settle(scene, velocity: release.velocity, completed: release.completed)
        }
    }
    func move(_ value: CGPoint) {
        translation = CGPoint(x: offset.x + value.x, y: offset.y + value.y)
        scene?.follow(translation: translation, anchor: anchor, edge: edge)
        let extent = edge ? viewport.width : viewport.height
        if let event = feedback.moved(distance: edge ? translation.x : translation.y,
                                      threshold: extent * (edge ? 0.32 : 0.18)) {
            AppFeedback.play(event)
        }
    }
    func retake(anchor newAnchor: CGPoint) {
        isReturning = false
        pendingRelease = nil
        anchor = newAnchor
        offset = scene?.interruptReturn(anchor: newAnchor, edge: edge) ?? translation
        feedback = NoteDismissalFeedback()
    }
    @discardableResult
    func release(velocity: CGPoint, cancelled: Bool) -> Bool {
        // Project the release a short distance, honouring a last-second upward
        // flick as a cancellation rather than blindly using accumulated travel.
        let distance = edge ? translation.x : translation.y
        let speed = edge ? velocity.x : velocity.y
        let projected = distance + speed * 0.16
        let extent = edge ? viewport.width : viewport.height
        let completed = !cancelled && (speed > 700 || projected > extent * (edge ? 0.32 : 0.18))
        if let event = feedback.released(completed: completed) { AppFeedback.play(event) }
        isReturning = !completed
        recordNoteHeroDiagnostic("free drag card=\(card) translation=\(translation) velocity=\(velocity) completed=\(completed)")
        if let scene { settle(scene, velocity: velocity, completed: completed) }
        else {
            // UIKit may begin the presentation transaction on the next run-loop
            // turn, after a quick flick has already ended. Keep that release.
            pendingRelease = (velocity, completed)
        }
        return completed
    }

    private func settle(_ scene: NoteHeroScene, velocity: CGPoint, completed: Bool) {
        scene.settle(expanded: !completed, velocity: velocity) { [weak self] in
            if completed { scene.context.finishInteractiveTransition() }
            else { scene.context.cancelInteractiveTransition() }
            scene.complete(completed) { self?.onComplete?(completed) }
        }
    }
}

private final class NoteHeroAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let opening: Bool
    let card: Bool
    let source: NoteHeroGeometry
    let destination: NoteHeroGeometry
    let foregroundHeader: (() -> AnyView)?
    let cardFooter: (() -> AnyView)?
    init(opening: Bool, card: Bool, source: NoteHeroGeometry, destination: NoteHeroGeometry,
         foregroundHeader: (() -> AnyView)? = nil, cardFooter: (() -> AnyView)? = nil) {
        self.opening = opening; self.card = card; self.source = source
        self.destination = destination; self.foregroundHeader = foregroundHeader
        self.cardFooter = cardFooter
    }
    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.48
    }
    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        guard let scene = NoteHeroScene(context: context, opening: opening, card: card,
                                        source: source, destination: destination,
                                        foregroundHeader: foregroundHeader,
                                        cardFooter: cardFooter) else {
            context.completeTransition(false); return
        }
        scene.settle(expanded: opening) { scene.complete(!context.transitionWasCancelled) }
    }
}
