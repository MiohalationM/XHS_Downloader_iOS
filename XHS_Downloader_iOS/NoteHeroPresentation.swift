import SwiftUI
import UIKit
import Combine

@MainActor
private func recordNoteHeroDiagnostic(_ text: String) {
    #if DEBUG
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
        if enabled { content.navigationTransition(.zoom(sourceID: id, in: namespace)) }
        else { content }
    }
}

/// Geometry is read directly from the live views when a transition starts,
/// including after paging, scrolling, rotation, and Dynamic Type changes.
@MainActor
final class NoteHeroGeometry: ObservableObject {
    private final class Entry {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }
    private var entries: [String: Entry] = [:]
    private var frames: [String: CGRect] = [:]
    private var hiddenViews: [String: CGFloat] = [:]
    @Published var concealedCardID: String?
    @Published var concealedContentID: String?
    @Published var concealingHeader = false
    var selectedID = ""
    var title = ""
    var image: UIImage?

    func register(_ view: UIView, role: String, id: String) {
        let key = role + id
        entries[key] = Entry(view)
        if hiddenViews[key] != nil { view.alpha = 0 }
    }
    func conceal(_ role: String, _ id: String, _ concealed: Bool) {
        let key = role + id
        if concealed {
            if hiddenViews[key] == nil { hiddenViews[key] = view(role, id)?.alpha ?? 1 }
            view(role, id)?.alpha = 0
        } else if let alpha = hiddenViews.removeValue(forKey: key) { view(role, id)?.alpha = alpha }
    }
    func register(_ frame: CGRect, role: String, id: String) { frames[role + id] = frame }
    func view(_ role: String, _ id: String) -> UIView? { entries[role + id]?.view }
    func frame(_ role: String, _ id: String, in container: UIView) -> CGRect? {
        if let view = view(role, id), view.window != nil, !view.bounds.isEmpty {
            return view.convert(view.bounds, to: container)
        }
        guard let frame = frames[role + id], !frame.isEmpty else { return nil }
        return container.convert(frame, from: container.window)
    }
    func still(_ id: String) -> UIImage? {
        MediaPreviewImages.shared.image(for: id) ?? (view("image", id) as? UIImageView)?.image ?? image
    }

    func visibleCardFrame(_ id: String, in container: UIView) -> CGRect? {
        guard let card = frame("card", id, in: container) else { return nil }
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

enum NoteHeroDragGeometry {
    /// Resume from the live presentation frame, rather than the animator's
    /// already-set endpoint.
    static func resumedTranslation(frame: CGRect, expanded: CGRect, bounds: CGRect,
                                   anchor: CGPoint, horizontal: Bool) -> CGPoint {
        let scale = frame.width / max(expanded.width, 1)
        let verticalTravel = frame.midY - bounds.midY - (expanded.midY - bounds.midY) * scale
            - (anchor.y - bounds.midY) * (1 - scale)
        let dx = frame.midX - bounds.midX - (expanded.midX - bounds.midX) * scale
            - (anchor.x - bounds.midX) * (1 - scale)
        return CGPoint(x: horizontal ? max(0, (1 - scale) * bounds.width / 0.22) : dx,
                       y: horizontal ? verticalTravel : max(0, (1 - scale) * bounds.height / 0.65))
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
    private let host: UIView
    private let chrome: UIView
    private let header: UIView?
    private let originalAlpha: CGFloat

    init?(presenting controller: UIViewController?, in container: UIView, header: UIView? = nil) {
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
        host = root
        chrome = branch
        self.header = header
        originalAlpha = branch.alpha
    }

    func insert(_ stage: UIView, convertingFrom container: UIView) {
        // Leave the system bar, its constraints and its material hierarchy
        // untouched. Only the app-owned transition stage changes parent.
        stage.frame = container.convert(container.bounds, to: host)
        stage.bounds = container.bounds
        host.insertSubview(stage, belowSubview: chrome)
        if let header {
            header.frame = host.bounds
            header.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.insertSubview(header, belowSubview: chrome)
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
        header?.removeFromSuperview()
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

/// Measure SwiftUI cards directly: a transparent representable in a background
/// can receive an empty proposal, even while the card itself is fully visible.
struct NoteHeroFrame: ViewModifier {
    let geometry: NoteHeroGeometry
    let role: String
    let id: String
    @State private var latestFrame = CGRect.zero
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            latestFrame = $0
            geometry.register($0, role: role, id: id)
        }
        .onChange(of: id) { _, id in geometry.register(latestFrame, role: role, id: id) }
    }
}

struct NoteHeroTitle: UIViewRepresentable {
    let text: String
    let size: CGFloat
    let lines: Int
    let geometry: NoteHeroGeometry
    let id: String
    var accessibilityID = ""

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    func updateUIView(_ label: UILabel, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lines == 2 ? 3 : 4
        paragraph.lineBreakMode = lines == 2 ? .byTruncatingTail : .byWordWrapping
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold), .paragraphStyle: paragraph, .foregroundColor: UIColor.label
        ])
        label.font = .systemFont(ofSize: size, weight: .semibold)
        label.numberOfLines = lines
        label.accessibilityIdentifier = accessibilityID
        geometry.register(label, role: "title", id: id)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        uiView.sizeThatFits(CGSize(width: proposal.width ?? 320, height: .greatestFiniteMagnitude))
    }
}

enum NoteHeroTitleVisibility {
    static func canTransfer(source: CGRect?, destination: CGRect?, text: String) -> Bool {
        guard !text.isEmpty, let source, let destination else { return false }
        return !source.isEmpty && !source.isNull && !destination.isEmpty && !destination.isNull
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
        private var displayedRevision: AnyHashable?
        private var scrollLock: NoteHeroScrollLock?

        init(_ parent: NoteHeroPresentation) { self.parent = parent }

        func update() {
            guard let presenter, presenter.view.window != nil else { return }
            if let item = parent.item, host == nil {
                parent.destination.image = parent.preview(item)
                let controller = NoteHeroHost(rootView: parent.content(item, { [weak self] in self?.close() }))
                controller.view.backgroundColor = .clear
                controller.view.traitOverrides.imageDynamicRange = .high
                controller.modalPresentationStyle = .custom
                controller.transitioningDelegate = self
                host = controller
                displayedRevision = parent.contentRevision
                if parent.card, parent.foregroundHeader != nil {
                    parent.source.concealingHeader = true
                }
                let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
                pan.maximumNumberOfTouches = 1
                pan.delegate = self
                controller.view.addGestureRecognizer(pan)
                presenter.present(controller, animated: true) { [weak self] in self?.update() }
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
            closing = true
            scrollLock = scrollLock ?? NoteHeroScrollLock(in: host.view)
            host.dismiss(animated: true) { [weak self] in self?.didClose() }
        }

        private func didClose() {
            scrollLock?.restore()
            scrollLock = nil
            host = nil
            closing = false
            parent.item = nil
            parent.onDismiss()
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            recordNoteHeroDiagnostic("gesture \(type(of: gesture)) closing=\(closing) presenting=\(host?.isBeingPresented ?? false) nested=\(host?.presentedViewController != nil) touches=\(gesture.numberOfTouches)")
            guard let pan = gesture as? UIPanGestureRecognizer, let host, !closing,
                  !host.isBeingPresented, host.presentedViewController == nil else { return false }
            if let interactive { return interactive.isReturning && !UIAccessibility.isReduceMotionEnabled }
            let velocity = pan.velocity(in: host.view)
            let horizontal = NoteHeroReturnDirection.isHorizontal(velocity)
            guard horizontal || velocity.y > abs(velocity.x) else { return false }
            // Rightward return belongs to the whole reader, including its
            // header, scrolled body and action bar. Leftward media paging stays
            // with the pager; vertical drags still respect the reading offset.
            var touched = host.view.hitTest(pan.location(in: host.view), with: nil)
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
                    if !horizontal, parent.card, scroll.contentSize.height > scroll.bounds.height + 1,
                       scroll.contentOffset.y > -scroll.adjustedContentInset.top + 1 {
                        recordNoteHeroDiagnostic("drag blocked by reader scroll \(type(of: scroll))")
                        return false
                    }
                }
                touched = view.superview
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
                    interactive.retake()
                } else {
                    scrollLock = NoteHeroScrollLock(in: host.view)
                    let interaction = NoteHeroInteraction(card: parent.card, source: parent.source, destination: parent.destination,
                                                          viewport: host.view.window?.bounds.size ?? host.view.bounds.size,
                                                          edge: NoteHeroReturnDirection.isHorizontal(velocity),
                                                          foregroundHeader: parent.foregroundHeader)
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
                             destination: parent.destination, foregroundHeader: parent.foregroundHeader)
        }
        func presentationController(forPresented presented: UIViewController, presenting: UIViewController?,
                                    source: UIViewController) -> UIPresentationController? {
            NoteHeroPresentationController(presentedViewController: presented, presenting: presenting)
        }
        func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
            NoteHeroAnimator(opening: false, card: parent.card, source: parent.source,
                             destination: parent.destination, foregroundHeader: parent.foregroundHeader)
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
    init(rootView: Content) { hosting = UIHostingController(rootView: rootView); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
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
private final class NoteHeroScene {
    let context: any UIViewControllerContextTransitioning
    let opening: Bool
    let card: Bool
    let page: UIView
    let container: UIView
    let stage: UIView
    private let mediaWindow = UIView()
    private let mediaMask = UIView()
    private let titleWindow = UIView()
    private let titleMask = UIView()
    let movingImage: UIImageView
    private let returningCover: UIImageView?
    let movingTitle = UILabel()
    let background: UIView
    let cardMask = UIView()
    let from: CGRect
    let to: CGRect
    let cardFrame: CGRect
    private let visibleCardFrame: CGRect
    private let sourceViewport: CGRect
    private let destinationViewport: CGRect
    private let titleViewport: CGRect
    private let source: NoteHeroGeometry
    private let destination: NoteHeroGeometry
    private let id: String
    private let screenRadius: CGFloat
    private let sourceTitle: CGRect?
    private let destinationTitle: CGRect?
    private let titleScale: CGFloat
    private let smallTitleBounds: CGRect
    private let transfersTitle: Bool
    private let feedForeground: NoteHeroFeedForeground?
    private let headerController: UIHostingController<AnyView>?
    private var inputSurface: NoteHeroTransitionInput?
    private var settlement: UIViewPropertyAnimator?
    private var revealWorkItem: DispatchWorkItem?
    private var settlementID = 0

    init?(context: any UIViewControllerContextTransitioning, opening: Bool, card: Bool,
          source: NoteHeroGeometry, destination: NoteHeroGeometry,
          foregroundHeader: (() -> AnyView)? = nil) {
        self.context = context; self.opening = opening; self.card = card
        self.source = source; self.destination = destination
        container = context.containerView
        stage = UIView(frame: container.bounds)
        let key: UITransitionContextViewControllerKey = opening ? .to : .from
        guard let controller = context.viewController(forKey: key),
              let page = context.view(forKey: opening ? .to : .from) else { return nil }
        self.page = page
        if opening {
            page.frame = context.finalFrame(for: controller)
            container.addSubview(page)
        }
        page.setNeedsLayout()
        page.layoutIfNeeded()
        controller.children.forEach { $0.view.layoutIfNeeded() }
        if card, let foregroundHeader {
            let overlay = UIHostingController(rootView: AnyView(VStack(spacing: 0) {
                foregroundHeader()
                Spacer(minLength: 0)
            }))
            overlay.view.backgroundColor = .clear
            overlay.view.isUserInteractionEnabled = false
            headerController = overlay
        } else {
            headerController = nil
        }
        feedForeground = card ? NoteHeroFeedForeground(
            presenting: context.viewController(forKey: opening ? .from : .to),
            in: container, header: headerController?.view) : nil
        id = card ? source.selectedID : destination.selectedID
        let image = destination.still(id) ?? source.still(id)
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
        from = source.frame("image", id, in: container) ?? fallback
        to = destination.frame("image", id, in: container) ?? fallback
        cardFrame = source.frame("card", id, in: container) ?? from
        visibleCardFrame = source.visibleCardFrame(id, in: container) ?? cardFrame.intersection(bounds)
        func viewport(_ geometry: NoteHeroGeometry, id: String, in coordinateView: UIView, fallback: CGRect) -> CGRect {
            let media = geometry.frame("viewport", id, in: coordinateView) ?? fallback
            let scroll = geometry.frame("scroll", id, in: coordinateView) ??
                geometry.frame("scroll", "feed", in: coordinateView) ?? bounds
            let visible = media.intersection(scroll).intersection(bounds)
            return visible.isNull ? CGRect(x: media.minX, y: scroll.minY, width: media.width, height: 0) : visible
        }
        sourceViewport = viewport(source, id: id, in: container, fallback: from)
        destinationViewport = viewport(destination, id: id, in: container, fallback: to)
        titleViewport = destination.frame("scroll", id, in: container) ?? bounds
        movingImage = UIImageView(image: image)
        movingImage.preferredImageDynamicRange = .high
        movingImage.contentMode = .scaleAspectFill
        movingImage.clipsToBounds = true
        if card, !opening, let cover = destination.image, cover !== image {
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
        sourceTitle = source.frame("title", id, in: container)
        destinationTitle = destination.frame("title", id, in: container)
        transfersTitle = card && NoteHeroTitleVisibility.canTransfer(
            source: sourceTitle, destination: destinationTitle, text: source.title)
        let sourceLabel = source.view("title", id) as? UILabel
        let destinationLabel = destination.view("title", id) as? UILabel
        titleScale = (sourceLabel?.font.pointSize ?? 15) / max(destinationLabel?.font.pointSize ?? 20, 1)
        smallTitleBounds = CGRect(origin: .zero, size: CGSize(
            width: (sourceTitle?.width ?? 0) / titleScale, height: (sourceTitle?.height ?? 0) / titleScale))
        source.conceal("image", id, true); destination.conceal("image", id, true)
        if card {
            source.concealedCardID = id
            source.concealedContentID = id
            if headerController != nil { source.concealingHeader = true }
            // Lazy cards and newly mounted reader labels may not have geometry
            // yet. Only hide their real title after a replacement can be drawn.
            if transfersTitle {
                source.conceal("title", id, true); destination.conceal("title", id, true)
            }
        }
        page.backgroundColor = .clear
        if let feedForeground {
            feedForeground.insert(stage, convertingFrom: container)
            headerController?.view.layoutIfNeeded()
        } else { container.addSubview(stage) }
        stage.addSubview(background)
        stage.addSubview(page)
        mediaWindow.frame = bounds
        mediaMask.backgroundColor = .white
        mediaWindow.mask = mediaMask
        stage.addSubview(mediaWindow)
        mediaWindow.addSubview(movingImage)
        if transfersTitle {
            movingTitle.attributedText = destinationLabel?.attributedText ?? NSAttributedString(string: source.title)
            movingTitle.numberOfLines = 0
            movingTitle.clipsToBounds = true
            titleWindow.frame = bounds
            titleMask.backgroundColor = .white
            titleWindow.mask = titleMask
            stage.addSubview(titleWindow)
            titleWindow.addSubview(movingTitle)
        }
        cardMask.backgroundColor = .white
        cardMask.layer.cornerCurve = .continuous
        cardMask.clipsToBounds = true
        // Resolve the device's public concentric corner geometry at full size,
        // before scaling it with the held page. All content shares this mask.
        let cornerProbe = UIView(frame: bounds)
        cornerProbe.cornerConfiguration = .uniformCorners(radius: .containerConcentric())
        container.addSubview(cornerProbe)
        cornerProbe.layoutIfNeeded()
        screenRadius = cornerProbe.effectiveRadius(corner: .allCorners)
        cornerProbe.removeFromSuperview()
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

    func setEndpoint(expanded: Bool) {
        stage.transform = .identity
        movingImage.frame = expanded ? to : from
        mediaMask.frame = expanded ? destinationViewport : sourceViewport
        titleMask.frame = expanded ? titleViewport : visibleCardFrame
        returningCover?.alpha = expanded ? 0 : 1
        background.frame = card ? expanded ? container.bounds : cardFrame : container.bounds
        background.alpha = card || expanded ? 1 : 0
        cardMask.frame = expanded ? background.frame : visibleCardFrame
        cardMask.layer.cornerRadius = expanded ? screenRadius : 14
        if let rect = expanded ? destinationTitle : sourceTitle {
            movingTitle.bounds = expanded ? CGRect(origin: .zero, size: rect.size) : smallTitleBounds
            movingTitle.center = CGPoint(x: rect.midX, y: rect.midY)
            movingTitle.transform = expanded ? .identity : CGAffineTransform(scaleX: titleScale, y: titleScale)
        }
        page.alpha = expanded ? 1 : 0
        feedForeground?.alpha = expanded ? 0 : 1
    }

    /// Geometry follows both axes in screen points; no easing while a finger is
    /// down. Scaling is anchored to the actual touch, so the image stays held.
    func follow(translation: CGPoint, anchor: CGPoint, edge: Bool) {
        let bounds = container.bounds
        let progress = max(0, edge ? translation.x / max(bounds.width, 1) : translation.y / max(bounds.height, 1))
        let scale = UIAccessibility.isReduceMotionEnabled ? 1 :
            max(edge ? 0.78 : 0.52, 1 - progress * (edge ? 0.22 : 0.65))
        let tx = translation.x + (anchor.x - bounds.midX) * (1 - scale)
        let ty = translation.y + (anchor.y - bounds.midY) * (1 - scale)
        let transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
        func rect(_ original: CGRect) -> CGRect {
            CGRect(x: bounds.midX + (original.minX - bounds.midX) * scale + tx,
                   y: bounds.midY + (original.minY - bounds.midY) * scale + ty,
                   width: original.width * scale, height: original.height * scale)
        }
        if card {
            stage.transform = transform
            movingImage.frame = to
            mediaMask.frame = destinationViewport
            titleMask.frame = titleViewport
            background.frame = bounds
            cardMask.frame = bounds
            cardMask.layer.cornerRadius = screenRadius
            if let destinationTitle {
                movingTitle.bounds = CGRect(origin: .zero, size: destinationTitle.size)
                movingTitle.center = CGPoint(x: destinationTitle.midX, y: destinationTitle.midY)
                movingTitle.transform = .identity
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
        revealWorkItem?.cancel()
        revealWorkItem = nil
        settlementID += 1
        let token = settlementID
        if UIAccessibility.isReduceMotionEnabled {
            // Crossfade the settled geometry. Shortening a spatial spring still
            // performs the motion the user asked to reduce.
            let snapshot = stage.snapshotView(afterScreenUpdates: false)
            if let snapshot {
                snapshot.frame = stage.frame
                stage.superview?.insertSubview(snapshot, aboveSubview: stage)
            }
            UIView.performWithoutAnimation {
                self.setEndpoint(expanded: expanded)
                self.stage.alpha = 0
            }
            let animator = UIViewPropertyAnimator(duration: 0.2, curve: .easeOut) {
                self.stage.alpha = 1
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
        let target = expanded ? to : from
        let current = stage.convert(movingImage.center, to: container)
        let delta = CGPoint(x: target.midX - current.x, y: target.midY - current.y)
        func relative(_ speed: CGFloat, _ distance: CGFloat) -> CGFloat {
            abs(distance) > 1 ? max(-12, min(12, speed / distance)) : 0
        }
        let timing = UISpringTimingParameters(dampingRatio: expanded ? 0.86 : 0.94,
            initialVelocity: CGVector(dx: relative(velocity.x, delta.x), dy: relative(velocity.y, delta.y)))
        let animator = UIViewPropertyAnimator(duration: 0.48, timingParameters: timing)
        animator.addAnimations { self.setEndpoint(expanded: expanded) }
        animator.addCompletion { [weak self] _ in
            guard let self, self.settlementID == token else { return }
            self.settlement = nil
            completion()
        }
        settlement = animator
        animator.startAnimation()
        if card, !expanded {
            // Body/chrome must leave before the title arrives at the small
            // card's text rectangle; they are not part of that title handoff.
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) { self.page.alpha = 0 }
            let reveal = DispatchWorkItem { [weak self] in
                guard let self, self.settlementID == token else { return }
                // Uncover only the card frame and author footer underneath while
                // keeping cover/title hidden, then dissolve background smoothly.
                UIView.performWithoutAnimation {
                    self.source.concealedContentID = self.id
                    self.source.concealedCardID = nil
                }
                UIView.animate(withDuration: 0.18, delay: 0.02, options: [.beginFromCurrentState, .curveEaseOut]) {
                    self.background.alpha = 0
                }
            }
            revealWorkItem = reveal
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: reveal)
        }
    }

    /// A returning image can be caught again before the spring has stopped.
    func interruptReturn(anchor: CGPoint, edge: Bool) -> CGPoint {
        revealWorkItem?.cancel()
        revealWorkItem = nil
        background.layer.removeAllAnimations()
        background.alpha = 1
        if card {
            source.concealedCardID = id
            source.concealedContentID = id
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
        revealWorkItem?.cancel()
        revealWorkItem = nil
        let returnsToFeed = card && opening != completed
        let finish = {
            UIView.performWithoutAnimation {
                self.source.conceal("image", self.id, false); self.destination.conceal("image", self.id, false)
                if self.card {
                    self.source.conceal("title", self.id, false); self.destination.conceal("title", self.id, false)
                    self.source.concealedContentID = nil
                    self.source.concealedCardID = nil
                    self.source.concealingHeader = false
                }
                self.page.transform = .identity; self.page.alpha = 1; self.page.mask = nil
                self.page.backgroundColor = !self.card && (self.opening == completed) ? .black : .clear
                self.container.addSubview(self.page)
                self.stage.removeFromSuperview()
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
                source.concealedContentID = nil
                source.concealedCardID = nil
                source.concealingHeader = false
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
    private var pendingRelease: (velocity: CGPoint, completed: Bool)?
    private var feedback = NoteDismissalFeedback()
    var anchor = CGPoint.zero
    private(set) var isReturning = false
    var wantsInteractiveStart: Bool { true }

    init(card: Bool, source: NoteHeroGeometry, destination: NoteHeroGeometry,
         viewport: CGSize, edge: Bool, foregroundHeader: (() -> AnyView)? = nil) {
        self.card = card; self.source = source; self.destination = destination
        self.viewport = viewport; self.edge = edge; self.foregroundHeader = foregroundHeader
    }
    func startInteractiveTransition(_ transitionContext: any UIViewControllerContextTransitioning) {
        recordNoteHeroDiagnostic("free drag start transition")
        guard let scene = NoteHeroScene(context: transitionContext, opening: false, card: card,
                                        source: source, destination: destination,
                                        foregroundHeader: foregroundHeader) else {
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
    func retake() {
        isReturning = false
        pendingRelease = nil
        offset = scene?.interruptReturn(anchor: anchor, edge: edge) ?? translation
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
    init(opening: Bool, card: Bool, source: NoteHeroGeometry, destination: NoteHeroGeometry,
         foregroundHeader: (() -> AnyView)? = nil) {
        self.opening = opening; self.card = card; self.source = source
        self.destination = destination; self.foregroundHeader = foregroundHeader
    }
    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.48
    }
    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        guard let scene = NoteHeroScene(context: context, opening: opening, card: card,
                                        source: source, destination: destination,
                                        foregroundHeader: foregroundHeader) else {
            context.completeTransition(false); return
        }
        scene.settle(expanded: opening) { scene.complete(!context.transitionWasCancelled) }
    }
}
