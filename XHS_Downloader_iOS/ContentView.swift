import SwiftUI
import AVFoundation
import Photos
import PhotosUI
import WebKit
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var coordinator: DownloadCoordinator
    @ObservedObject var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var actionHeight: CGFloat = 56

    @State private var filter: TaskFilter = .all
    @State private var search = ""
    @State private var selectedTab = 0
    @State private var showsManualInput = false
    @State private var showsWebCapture = false
    @State private var pendingManualImport: (String, ImportRequest.Behavior)?
    @State private var pendingBrowserImport: (BrowserImport, ImportRequest.Behavior)?
    @State private var taskToDelete: DownloadTaskRecord?
    @State private var confirmsClearHistory = false

    var body: some View {
        rootTabView
            .disabled(!coordinator.isLoaded)
            .overlay { if !coordinator.isLoaded { ProgressView().accessibilityLabel(L10n.text("library.loading")) } }
            .tint(.coral)
            .selectionFeedback(filter)
        .onChange(of: showsManualInput) { _, shown in
            if shown { AppFeedback.play(.navigation) }
        }
        .onChange(of: showsWebCapture) { _, shown in
            if shown { AppFeedback.play(.navigation) }
        }
        .onChange(of: coordinator.alertMessage) { _, message in
            if message != nil { AppFeedback.play(.error) }
        }
        .onChange(of: coordinator.focusedTask) { _, focus in
            if focus != nil { selectedTab = 0 }
        }
        .onChange(of: shouldKeepAwake, initial: true) { _, keepAwake in
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        .sheet(isPresented: $showsManualInput, onDismiss: flushPendingManualImport) {
            ManualInputView(coordinator: coordinator) { text, behavior in
                pendingManualImport = (text, behavior)
                showsManualInput = false
            }
        }
        .sheet(isPresented: $showsWebCapture, onDismiss: flushPendingBrowserImport) {
            BrowserView(settings: settings) { importValue, behavior in
                pendingBrowserImport = (importValue, behavior)
                showsWebCapture = false
            }
        }
        .sheet(item: presentedSelectionState) { _ in
            SelectiveDownloadView(coordinator: coordinator)
                .interactiveDismissDisabled()
        }
        .alert(
            L10n.text("common.notice"),
            isPresented: Binding(
                get: { coordinator.alertMessage != nil },
                set: { if !$0 { coordinator.alertMessage = nil } }
            ),
            actions: { Button(L10n.text("common.ok"), role: .cancel) { coordinator.alertMessage = nil } },
            message: { Text(coordinator.alertMessage ?? "") }
        )
        .onAppear {
            coordinator.consumeSharedInbox()
            coordinator.checkClipboard()
            // A failed migration must be visible immediately, not only when the
            // next write happens to fail as well.
            if let loadError = coordinator.loadError, !loadError.isEmpty,
               coordinator.alertMessage == nil {
                coordinator.alertMessage = L10n.format("library.load.failed", loadError)
            }
        }
        .onOpenURL { url in
            guard ImportRequest.requestID(from: url) != nil else { return }
            selectedTab = 0
            coordinator.consumeSharedInbox()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            coordinator.consumeSharedInbox()
            coordinator.checkClipboard()
        }
        .onChange(of: settings.clipboardSuggestions) { _, enabled in
            if enabled { coordinator.checkClipboard() }
        }
        .onChange(of: scenePhase) { _, phase in
            AppFeedback.invalidatePendingFeedback()
            if phase == .background { coordinator.flushForBackground() }
            if phase == .active {
                coordinator.consumeSharedInbox()
                coordinator.checkClipboard()
            }
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(get: { selectedTab }, set: {
            guard selectedTab != $0 else { return }
            selectedTab = $0
            AppFeedback.play(.selection)
        })
    }

    private var downloadTab: some View {
        NavigationStack {
            taskCenter
                .navigationDestination(item: focusedTask) { focus in
                    TaskDetailView(taskID: focus.id, coordinator: coordinator)
                }
        }
        .tint(.coral)
    }

    private var libraryTab: some View {
        MediaLibraryView(coordinator: coordinator)
            .tint(.coral)
    }

    private var settingsTab: some View {
        SettingsView(settings: settings, coordinator: coordinator)
            .tint(.coral)
    }

    @ViewBuilder
    private var rootTabView: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: tabSelection) {
                Tab(L10n.text("tab.download"), systemImage: "arrow.down.circle", value: 0) {
                    downloadTab
                }
                Tab(L10n.text("tab.library"), systemImage: "photo.on.rectangle.angled", value: 1) {
                    libraryTab
                }
                Tab(L10n.text("settings.title"), systemImage: "gearshape", value: 2) {
                    settingsTab
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        } else {
            TabView(selection: tabSelection) {
                downloadTab
                    .tabItem { Label(L10n.text("tab.download"), systemImage: "arrow.down.circle") }
                    .tag(0)
                libraryTab
                    .tabItem { Label(L10n.text("tab.library"), systemImage: "photo.on.rectangle.angled") }
                    .tag(1)
                settingsTab
                    .tabItem { Label(L10n.text("settings.title"), systemImage: "gearshape") }
                    .tag(2)
            }
        }
    }

    private var bottomControlHeight: CGFloat {
        min(max(actionHeight, 48), 68)
    }

    private var showsDownloadBanner: Bool {
        coordinator.tasks.contains { TaskGroup.active.contains($0) || TaskGroup.waiting.contains($0) }
    }

    private var hasActiveWork: Bool {
        coordinator.tasks.contains { $0.status == .downloading }
    }

    private var shouldKeepAwake: Bool {
        scenePhase == .active && settings.keepScreenAwake && hasActiveWork
    }

    private var focusedTask: Binding<TaskFocus?> {
        Binding(get: { coordinator.focusedTask },
                set: { coordinator.focusedTask = $0 })
    }

    private var presentedSelectionState: Binding<SelectiveDownloadState?> {
        Binding(
            get: { (showsManualInput || showsWebCapture) ? nil : coordinator.selectionState },
            set: { if $0 == nil { coordinator.selectionState = nil } }
        )
    }

    private func flushPendingManualImport() {
        guard let pending = pendingManualImport else { return }
        pendingManualImport = nil
        coordinator.enqueue(pending.0, behavior: pending.1)
    }

    private func flushPendingBrowserImport() {
        guard let pending = pendingBrowserImport else { return }
        pendingBrowserImport = nil
        switch pending.0 {
        case .page(let payload): coordinator.enqueue(payload, behavior: pending.1)
        case .link(let text): coordinator.enqueue(text, behavior: pending.1)
        }
    }

    private var taskCenter: some View {
        List {
            if showsDownloadBanner {
                Section {
                    DownloadDashboard(coordinator: coordinator)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
            }
            if !coordinator.tasks.isEmpty {
                Section {
                    filterPicker
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            let visibleTasks = coordinator.filteredTasks(for: filter).filter {
                search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
                $0.noteText.localizedCaseInsensitiveContains(search) || $0.normalizedURL.localizedCaseInsensitiveContains(search)
            }
            if visibleTasks.isEmpty {
                Section {
                    Group {
                        if coordinator.tasks.isEmpty {
                            EmptyDownloadsGuide(onManualInput: { showsManualInput = true },
                                                onWebCapture: { showsWebCapture = true })
                        } else {
                            ContentUnavailableCard(filter: filter, searching: !search.isEmpty)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
            } else if filter == .all {
                // Grouping keeps the running work at the top even when the list
                // is long: the three buckets match the three things a user asks
                // ("what is running", "what needs me", "what is done").
                ForEach(TaskGroup.allCases) { group in
                    let items = visibleTasks.filter(group.contains)
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { task in
                                taskRow(task)
                            }
                        } header: {
                            TaskGroupHeader(group: group, count: items.count)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(visibleTasks) { task in
                        taskRow(task)
                    }
                }
            }
        }
        .accessibilityIdentifier("task-center-list")
        .listStyle(.insetGrouped)
        .listRowSpacing(10)
        .scrollContentBackground(.hidden)
        .background { GlassBackdrop(color: .coral) }
        .searchable(text: $search, prompt: L10n.text("library.search"))
        .xhsCompactSectionSpacing()
        .xhsSafeAreaBar(edge: .bottom, spacing: 0) {
            floatingBottomActions
        }
        .navigationTitle(L10n.text("app.title"))
        .alert(
            L10n.text("task.delete.title"),
            isPresented: Binding(
                get: { taskToDelete != nil },
                set: { if !$0 { taskToDelete = nil } }
            ),
            presenting: taskToDelete
        ) { task in
            Button(L10n.text("task.delete.history"), role: .destructive) {
                Task { await coordinator.deleteTask(taskID: task.id, deletePhotos: false) }
            }
            if !task.mediaAssets.isEmpty {
                Button(L10n.text("task.delete.photos"), role: .destructive) {
                    Task { await coordinator.deleteTask(taskID: task.id, deletePhotos: true) }
                }
            }
            Button(L10n.text("common.cancel"), role: .cancel) { taskToDelete = nil }
        } message: { task in
            Text(L10n.text(task.mediaAssets.isEmpty ? "task.delete.message.history" : "task.delete.message.photos"))
        }
    }

    private func taskRow(_ task: DownloadTaskRecord) -> some View {
        // Navigate via `focusedTask` rather than a hidden `NavigationLink` so
        // `List` never flashes UIKit's default 10pt selection highlight behind
        // the 26pt rounded card while keeping `.swipeActions` intact.
        TaskCardView(task: task, coordinator: coordinator)
            .onTapGesture {
                coordinator.focusedTask = TaskFocus(id: task.id)
                AppFeedback.play(.navigation)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .accessibilityElement(children: .contain)
            .accessibilityAction {
                coordinator.focusedTask = TaskFocus(id: task.id)
                AppFeedback.play(.navigation)
            }
            .accessibilityIdentifier("task-row-\(task.id.uuidString)")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { taskToDelete = task; AppFeedback.play(.warning) } label: {
                    Label(L10n.text("common.delete"), systemImage: "trash")
                }
                .accessibilityIdentifier("task-delete-\(task.id.uuidString)")
            }
    }

    private var filterPicker: some View {
        GlassChipBar(items: [
            GlassChipItem(value: TaskFilter.all, title: L10n.text("filter.all"),
                          count: coordinator.tasks.count, accessibilityID: "task-filter-all"),
            GlassChipItem(value: TaskFilter.waiting, title: L10n.text("filter.choose"),
                          count: coordinator.waitingCount, accessibilityID: "task-filter-waiting"),
            GlassChipItem(value: TaskFilter.failed, title: L10n.text("filter.failed"),
                          count: coordinator.failedCount, accessibilityID: "task-filter-failed")
        ], selection: $filter, horizontalPadding: 4)
        .accessibilityElement(children: .contain)
    }

    private var floatingBottomActions: some View {
        XHSGlassContainer(spacing: 12) {
            HStack(spacing: 12) {
                primaryAction
                    .frame(maxWidth: .infinity, minHeight: bottomControlHeight)
                    .xhsFloatingControlShadow(color: .coral.opacity(0.25))

                Menu {
                    Button { showsManualInput = true } label: {
                        Label(L10n.text("action.manual_input"), systemImage: "keyboard")
                    }
                    Button { showsWebCapture = true } label: {
                        Label(L10n.text("action.web_capture"), systemImage: "safari")
                    }
                    if !coordinator.tasks.isEmpty {
                        Menu {
                            Button { coordinator.pauseAll() } label: {
                                Label(L10n.text("task.batch.pause_all"), systemImage: "pause.fill")
                            }
                            Button { coordinator.resumeAll() } label: {
                                Label(L10n.text("task.batch.resume_all"), systemImage: "play.fill")
                            }
                            Button { coordinator.retryAllFailed() } label: {
                                Label(L10n.text("task.batch.retry_failed"), systemImage: "arrow.clockwise")
                            }
                            Button { coordinator.removeFinished() } label: {
                                Label(L10n.text("task.batch.remove_finished"), systemImage: "checkmark.circle")
                            }
                        } label: {
                            Label(L10n.text("task.batch.title"), systemImage: "square.stack.3d.down.right")
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmsClearHistory = true
                            AppFeedback.play(.warning)
                        } label: {
                            Label(L10n.text("action.clear_history"), systemImage: "trash.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: bottomControlHeight, height: bottomControlHeight)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(width: bottomControlHeight, height: bottomControlHeight)
                .xhsCircularGlass()
                .xhsFloatingControlShadow(color: .black.opacity(0.10))
                .accessibilityLabel(L10n.text("common.more"))
                .accessibilityIdentifier("more-actions-button")
            }
        }
        .confirmationDialog(
            L10n.text("action.clear_history"),
            isPresented: $confirmsClearHistory,
            titleVisibility: .visible
        ) {
            Button(L10n.text("action.clear_history"), role: .destructive) {
                coordinator.clearHistory()
            }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .xhsFloatingBarBottomPadding()
        .frame(maxWidth: .infinity)
        .xhsBarBackdrop(edge: .bottom)
    }

    private var primaryAction: some View {
        FullWidthPasteControl(minHeight: bottomControlHeight) { values in
            coordinator.enqueue(values.joined(separator: "\n"))
        }
        .frame(maxWidth: .infinity, minHeight: bottomControlHeight)
        .xhsPrimaryGlass()
    }
}

private struct FullWidthPasteControl: UIViewRepresentable {
    let minHeight: CGFloat
    let onPaste: ([String]) -> Void

    func makeUIView(context: Context) -> PasteControlContainerView {
        PasteControlContainerView(minHeight: minHeight, onPaste: onPaste)
    }

    func updateUIView(_ uiView: PasteControlContainerView, context: Context) {
        if uiView.minHeight != minHeight {
            uiView.minHeight = minHeight
        }
        uiView.onPaste = onPaste
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteControlContainerView, context: Context) -> CGSize? {
        let targetWidth = proposal.width ?? 280
        let fittingHeight = uiView.preferredHeight(for: targetWidth)
        return CGSize(width: targetWidth, height: max(minHeight, fittingHeight))
    }
}

private final class PasteControlContainerView: UIView {
    var minHeight: CGFloat
    var onPaste: ([String]) -> Void

    private let pasteControl: UIPasteControl
    private let titleLabel = UILabel()

    init(minHeight: CGFloat, onPaste: @escaping ([String]) -> Void) {
        self.minHeight = minHeight
        self.onPaste = onPaste

        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .labelOnly
        configuration.cornerStyle = .fixed
        configuration.cornerRadius = 28
        configuration.baseForegroundColor = .clear
        configuration.baseBackgroundColor = .clear
        pasteControl = UIPasteControl(configuration: configuration)

        super.init(frame: .zero)
        backgroundColor = .clear

        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [UTType.plainText.identifier, UTType.url.identifier]
        )
        pasteControl.target = self
        pasteControl.translatesAutoresizingMaskIntoConstraints = false
        pasteControl.backgroundColor = .clear
        // Keep the system paste control in the hit-test chain while letting the
        // app's accent-tinted glass surface provide the visible appearance.
        pasteControl.layer.opacity = 0.011
        pasteControl.accessibilityIdentifier = "primary-paste-button"
        pasteControl.accessibilityLabel = L10n.text("action.paste_download")
        addSubview(pasteControl)

        let iconView = UIImageView(image: UIImage(systemName: "arrow.down.circle.fill"))
        iconView.tintColor = .white
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.text = L10n.text("action.paste_download")
        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.minimumScaleFactor = 0.8
        titleLabel.adjustsFontSizeToFitWidth = true

        let contentStack = UIStackView(arrangedSubviews: [iconView, titleLabel])
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let contentOverlay = UIView()
        contentOverlay.backgroundColor = .clear
        contentOverlay.clipsToBounds = true
        contentOverlay.isUserInteractionEnabled = false
        contentOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentOverlay.addSubview(contentStack)
        addSubview(contentOverlay)

        // UIPasteControl on iOS 26 reports an inner AX capsule ~2.5pt shorter than its bounds;
        // extending the invisible hit control aligns its reported height only on iOS 26+.
        let pasteVerticalPadding: CGFloat
        if #available(iOS 26.0, *) {
            pasteVerticalPadding = 1.5
        } else {
            pasteVerticalPadding = 0
        }
        let topPaste = pasteControl.topAnchor.constraint(equalTo: topAnchor, constant: -pasteVerticalPadding)
        topPaste.priority = .defaultHigh
        let bottomPaste = pasteControl.bottomAnchor.constraint(equalTo: bottomAnchor, constant: pasteVerticalPadding)
        bottomPaste.priority = .defaultHigh

        NSLayoutConstraint.activate([
            pasteControl.leadingAnchor.constraint(equalTo: leadingAnchor),
            pasteControl.trailingAnchor.constraint(equalTo: trailingAnchor),
            pasteControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            topPaste,
            bottomPaste,
            contentOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentOverlay.topAnchor.constraint(equalTo: topAnchor),
            contentOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.centerXAnchor.constraint(equalTo: contentOverlay.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: contentOverlay.centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentOverlay.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: contentOverlay.trailingAnchor, constant: -18),
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: contentOverlay.topAnchor, constant: 10),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentOverlay.bottomAnchor, constant: -10)
        ])
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(40, width - 62)
        let titleHeight = titleLabel.sizeThatFits(
            CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        ).height
        return max(minHeight, ceil(titleHeight) + 24)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func paste(itemProviders: [NSItemProvider]) {
        // UIPasteControl is an explicit user paste action. Prefer the pasteboard's
        // original string because an item provider may expose only a detected URL
        // representation and discard the surrounding XHS share text.
        if let clipboardText = UIPasteboard.general.string,
           !clipboardText.isEmpty {
            onPaste([clipboardText])
            return
        }

        let acceptableProviders = itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        guard !acceptableProviders.isEmpty else {
            onPaste([])
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var values: [String] = []

        for provider in acceptableProviders {
            // Share text can advertise both URL and plain-text representations.
            // Prefer the complete text so surrounding XHS share copy is preserved.
            let typeIdentifier = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                ? UTType.plainText.identifier
                : UTType.url.identifier
            group.enter()
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                let value: String?
                switch item {
                case let string as String:
                    value = string
                case let string as NSString:
                    value = string as String
                case let url as URL:
                    value = url.absoluteString
                case let url as NSURL:
                    value = url.absoluteString
                case let data as Data:
                    value = String(data: data, encoding: .utf8)
                default:
                    value = nil
                }
                if let value, !value.isEmpty {
                    lock.lock()
                    values.append(value)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.onPaste(values)
        }
    }
}

private extension TaskStatus {
    var tint: Color {
        switch self {
        case .queued, .paused, .cancelled: return .secondary
        case .downloading: return .coral
        case .completed: return .green
        case .failed: return .red
        case .waitingForUser, .partial: return .orange
        }
    }

    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .downloading: return "arrow.down.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .waitingForUser: return "hand.tap.fill"
        case .paused: return "pause.circle.fill"
        case .cancelled: return "xmark.circle"
        case .partial: return "exclamationmark.circle.fill"
        }
    }
}

/// Small tinted capsule describing a task or resource state.
private struct StatusBadge: View {
    let title: String
    let systemImage: String
    let tint: Color
    var animated = false

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if animated {
                Image(systemName: systemImage)
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                Image(systemName: systemImage)
            }
        }
        .font(.caption.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
        .fixedSize()
    }
}

/// Compact live status banner for the top of the Downloads tab.
/// Only shown while downloads are active or when tasks need attention;
/// hidden when empty or idle with completed history so task cards stay front and center.
private struct DownloadDashboard: View {
    @ObservedObject var coordinator: DownloadCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var active: [DownloadTaskRecord] { coordinator.tasks.filter(TaskGroup.active.contains) }
    private var attentionCount: Int { coordinator.tasks.filter(TaskGroup.waiting.contains).count }
    private var overallProgress: Double {
        guard !active.isEmpty else { return 0 }
        return active.map { min(max($0.progress, 0), 1) }.reduce(0, +) / Double(active.count)
    }
    private var totalSpeed: Double { active.compactMap(\.bytesPerSecond).reduce(0) { $0 + max(0, $1) } }

    var body: some View {
        Group {
            if !active.isEmpty {
                activeBanner
            } else if attentionCount > 0 {
                attentionBanner
            }
        }
        .animation(XHSDesign.animation(reduceMotion), value: active.count)
        .animation(XHSDesign.animation(reduceMotion), value: attentionCount)
    }

    private var activeBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                activeBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.format("download.active.title", active.count))
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.numericText())
                    Text(activeSubtitle)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            CapsuleProgressBar(value: overallProgress, tint: .coral, height: 5)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .xhsBannerCardSurface(accent: .coral)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("download-active-banner")
    }

    private var attentionBanner: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "exclamationmark.circle.fill", color: .orange, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("download.attention.title", attentionCount))
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())
                Text(L10n.text("download.attention.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .xhsBannerCardSurface(accent: .orange)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("download-attention-banner")
    }

    private var activeBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.coralGradient)
                .shadow(color: .coral.opacity(0.24), radius: 8, y: 3)
            activeSymbol
        }
        .frame(width: 42, height: 42)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var activeSymbol: some View {
        let icon = Image(systemName: "arrow.down.to.line")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
        if !reduceMotion {
            if #available(iOS 18.0, *) {
                icon.symbolEffect(.bounce.down, options: .repeat(.periodic(delay: 1.2)))
            } else {
                icon.symbolEffect(.pulse, options: .repeating)
            }
        } else {
            icon
        }
    }

    private var activeSubtitle: String {
        let saved = active.map(\.savedCount).reduce(0, +)
        let total = active.map(\.mediaCount).reduce(0, +)
        var parts: [String] = []
        if totalSpeed > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(totalSpeed), countStyle: .file) + "/s")
        }
        if total > 0 { parts.append(L10n.format("task.media_count", saved, total)) }
        parts.append(overallProgress.formatted(.percent.precision(.fractionLength(0))))
        return parts.joined(separator: " · ")
    }
}

private struct TaskGroupHeader: View {
    let group: TaskGroup
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(L10n.text(group.titleKey))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("\(count)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .contentTransition(.numericText(value: Double(count)))
        }
        .textCase(nil)
        .padding(.leading, 4)
    }
}

/// First-run guidance: three short steps and the two manual entry points, so
/// an empty tab teaches the flow instead of only saying "nothing here".
private struct EmptyDownloadsGuide: View {
    let onManualInput: () -> Void
    let onWebCapture: () -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(L10n.text("empty.title"))
                    .font(.headline)
                Text(L10n.text("empty.subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 0) {
                step(1, "square.and.arrow.up", L10n.text("download.guide.share"), color: .coral)
                Divider().padding(.leading, 52)
                step(2, "arrow.down.circle", L10n.text("download.guide.auto"), color: .orange)
                Divider().padding(.leading, 52)
                step(3, "photo.on.rectangle.angled", L10n.text("download.guide.browse"), color: .pink)
            }
            .padding(.vertical, 4)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: XHSDesign.cardRadius, style: .continuous))

            XHSGlassContainer(spacing: 10) {
                HStack(spacing: 10) {
                    GlassPillButton(title: L10n.text("action.manual_input"), systemImage: "keyboard", action: onManualInput)
                        .accessibilityIdentifier("empty-manual-input")
                    GlassPillButton(title: L10n.text("action.web_capture"), systemImage: "safari", action: onWebCapture)
                        .accessibilityIdentifier("empty-web-capture")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 12)
        .onAppear { withAnimation(XHSDesign.animation(reduceMotion)?.delay(0.05)) { appeared = true } }
    }

    private func step(_ number: Int, _ symbol: String, _ text: String, color: Color) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: symbol, color: color, size: 30)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Cancellation-safe, single-resume wrapper around `PHImageManager.requestImage`.
private final class TaskCoverPhotoRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID: PHImageRequestID = PHInvalidImageRequestID
    private var cancelled = false

    func attach(_ continuation: CheckedContinuation<UIImage?, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.continuation = continuation
        return true
    }

    func setRequestID(_ id: PHImageRequestID) {
        lock.lock()
        let shouldCancel = cancelled
        requestID = id
        lock.unlock()
        if shouldCancel, id != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(id)
        }
    }

    func finish(with image: UIImage?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: image)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        let id = requestID
        requestID = PHInvalidImageRequestID
        lock.unlock()
        if id != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(id)
        }
        continuation?.resume(returning: nil)
    }
}

/// Task list cover. Shows the first saved media as soon as it lands in Photos
/// or Files, otherwise a tinted symbol for the note type.
private struct TaskCoverThumbnail: View {
    let identifier: String?
    var fallbackURL: URL? = nil
    let symbol: String
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
            if identifier == nil, let fallbackURL {
                AsyncImage(url: fallbackURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    }
                }
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .clipped()
        .task(id: identifier) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard let identifier else { image = nil; return }
        if let cached = MediaPreviewImages.shared.image(for: identifier) { image = cached; return }
        image = nil
        let loaded: UIImage?
        if identifier.hasPrefix("file:") {
            loaded = try? await ArchiveMediaLoader.shared.image(identifier: identifier, thumbnail: true)
        } else {
            // Never trigger the Photos prompt from a list cell.
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return }
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let box = TaskCoverPhotoRequestBox()
            loaded = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard box.attach(continuation) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let id = PHImageManager.default().requestImage(
                        for: asset,
                        targetSize: CGSize(width: 200, height: 200),
                        contentMode: .aspectFill,
                        options: options
                    ) { image, info in
                        let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                        let isCancelled = (info?[PHImageCancelledKey] as? Bool) == true
                        let hasError = info?[PHImageErrorKey] != nil
                        if isDegraded && !isCancelled && !hasError { return }
                        box.finish(with: isCancelled ? nil : image)
                    }
                    box.setRequestID(id)
                }
            } onCancel: {
                box.cancel()
            }
        }
        guard !Task.isCancelled else { return }
        withAnimation(XHSDesign.animation(reduceMotion, .easeOut(duration: 0.25))) { image = loaded }
    }
}

private struct TaskCardView: View {
    let task: DownloadTaskRecord
    @ObservedObject var coordinator: DownloadCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if showsProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(phaseLabel ?? L10n.format("task.media_count", task.savedCount, task.mediaCount))
                        Spacer()
                        Text(task.progress, format: .percent.precision(.fractionLength(0)))
                            .contentTransition(.numericText(value: task.progress))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    CapsuleProgressBar(value: task.progress, tint: task.status == .downloading ? .coral : task.status.tint)

                    if task.status == .downloading, let received = task.transferredBytes {
                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                                 + (task.expectedBytes.map { $0 > 0 ? " / " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : "" } ?? ""))
                            Spacer()
                            if let speed = task.bytesPerSecond {
                                Label(ByteCountFormatter.string(fromByteCount: Int64(max(0, speed)), countStyle: .file) + "/s",
                                      systemImage: "speedometer")
                            }
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    }
                }
            }

            if let error = task.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.bubble")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if hasActions {
                HStack(spacing: 8) {
                    if task.status == .downloading || task.status == .queued {
                        GlassPillButton(title: L10n.text("action.stop"), systemImage: "stop.fill", tint: .red) {
                            coordinator.stop(taskID: task.id)
                        }
                    }
                    if [.failed, .partial, .paused, .cancelled].contains(task.status) {
                        GlassPillButton(title: L10n.text("action.retry"), systemImage: "arrow.clockwise",
                                        tint: .coral, prominent: task.status == .failed) {
                            coordinator.retry(taskID: task.id)
                        }
                    }
                    if task.status == .waitingForUser {
                        GlassPillButton(title: L10n.text("action.choose_media"), systemImage: "checklist",
                                        tint: .orange, prominent: true) {
                            coordinator.showSelection(taskID: task.id)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: XHSDesign.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: XHSDesign.cardRadius, style: .continuous))
    }

    @ViewBuilder
    private var header: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            TaskCoverThumbnail(identifier: task.mediaAssets.first?.localIdentifier,
                               fallbackURL: task.resolvedNote?.media.first?.previewURL,
                               symbol: kindSymbol, tint: task.status.tint == .secondary ? .coral : task.status.tint)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text(task.title.isEmpty ? L10n.text("task.resolving") : task.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { metaItems }
                    VStack(alignment: .leading, spacing: 4) { metaItems }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var metaItems: some View {
        StatusBadge(title: L10n.text(task.status.localizationKey), systemImage: task.status.symbol,
                    tint: task.status.tint, animated: task.status == .downloading)
        Group {
            Text(noteKind)
            if !showsProgress, task.mediaCount > 0 {
                Text(L10n.format("task.media_count", task.savedCount, task.mediaCount))
            }
            Text(task.updatedAt, style: .time)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private var showsProgress: Bool {
        task.status != .completed && task.informationOnly != true
    }

    private var hasActions: Bool {
        [.downloading, .queued, .failed, .partial, .paused, .cancelled, .waitingForUser].contains(task.status)
    }

    private var kindSymbol: String {
        if task.informationOnly == true { return "text.alignleft" }
        switch task.noteType {
        case .video: return "play.rectangle.fill"
        case .livePhoto: return "livephoto"
        default: return "photo.fill"
        }
    }

    /// "Save note only" tasks have no media, so reporting them as an image note
    /// would be misleading.
    private var noteKind: String {
        if task.informationOnly == true { return L10n.text("note.type.text") }
        return L10n.text(task.noteType.localizationKey)
    }

    private var phaseLabel: String? {
        guard let raw = task.phase, let phase = TaskPhase(rawValue: raw) else { return nil }
        guard task.status == .downloading || task.status == .waitingForUser else { return nil }
        return L10n.text(phase.localizationKey)
    }
}

private struct ContentUnavailableCard: View {
    let filter: TaskFilter
    var searching = false

    var body: some View {
        GlassEmptyState(
            title: L10n.text(searching ? "feed.search.empty" : (filter == .all ? "empty.title" : "empty.filtered.title")),
            subtitle: searching ? nil : L10n.text(filter == .all ? "empty.subtitle" : "empty.filtered.subtitle"),
            systemImage: searching ? "magnifyingglass" : (filter == .all ? "arrow.down.doc" : "line.3.horizontal.decrease.circle")
        )
    }
}

private struct TaskDetailView: View {
    let taskID: UUID
    @ObservedObject var coordinator: DownloadCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section = 0
    @StateObject private var presentation = MediaPresentation()
    @Namespace private var previewTransition
    @State private var confirmsPhotoDeletion = false
    @State private var archiveShare: MediaShareFiles?
    @State private var archiveShareDirectory: URL?
    @State private var archiveShareTask: Task<Void, Never>?
    @State private var exportingArchive = false
    @State private var showsShare = false
    @State private var copiedCaption = false
    @State private var copyResetTask: Task<Void, Never>?

    private var task: DownloadTaskRecord? {
        coordinator.tasks.first { $0.id == taskID }
    }

    var body: some View {
        Group {
            if let task {
                ScrollView {
                    VStack(spacing: 16) {
                        saveSummary(task)
                        GlassSegmentedScope(items: [
                            GlassChipItem(value: 0, title: L10n.text("detail.files")),
                            GlassChipItem(value: 1, title: L10n.text("detail.caption")),
                            GlassChipItem(value: 2, title: L10n.text("detail.resources"))
                        ], selection: $section)
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .contain)

                        Group {
                            switch section {
                            case 0: mediaSection(task)
                            case 1: captionSection(task)
                            default: resourcesSection(task)
                            }
                        }
                        .animation(XHSDesign.animation(reduceMotion, XHSDesign.snappy), value: section)
                    }
                    .padding()
                }
                .background { GlassBackdrop(color: .coral, intensity: 0.7) }
                .selectionFeedback(section)
                .navigationTitle(task.title.isEmpty ? L10n.text("detail.title") : task.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            if let url = URL(string: task.normalizedURL) {
                                Link(destination: url) {
                                    Label(L10n.text("detail.open_note"), systemImage: "safari")
                                }
                                Button {
                                    coordinator.copyToClipboard(task.normalizedURL)
                                } label: {
                                    Label(L10n.text("detail.copy_link"), systemImage: "link")
                                }
                                Link(destination: task.resolvedNote?.metadata.profileURL ?? url) {
                                    Label(L10n.text("detail.open_web"), systemImage: "globe")
                                }
                            }
                            if hasFailedResources(task) {
                                Button {
                                    coordinator.retryFailedResources(taskID: task.id)
                                } label: {
                                    Label(L10n.text("detail.retry_failed"), systemImage: "arrow.clockwise")
                                }
                            }
                            Button {
                                showsShare = true
                                AppFeedback.play(.navigation)
                            } label: {
                                Label(L10n.text("common.share"), systemImage: "square.and.arrow.up")
                            }
                            .disabled(shareItems(task).isEmpty)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $showsShare) {
                    ActivityView(items: shareItems(task))
                }
                .fullScreenCover(item: $presentation.selection) { selection in
                    MediaViewer(identifiers: selection.identifiers, initialIdentifier: selection.id,
                                initialImage: selection.image, transition: previewTransition)
                        .presentationBackground(.black)
                }
                .onDisappear {
                    presentation.cancel()
                    copyResetTask?.cancel()
                    copyResetTask = nil
                    archiveShareTask?.cancel()
                    archiveShareTask = nil
                    if archiveShare == nil, let directory = archiveShareDirectory {
                        try? FileManager.default.removeItem(at: directory)
                        archiveShareDirectory = nil
                    }
                }
                .sheet(item: $archiveShare, onDismiss: {
                    if let directory = archiveShareDirectory { try? FileManager.default.removeItem(at: directory) }
                    archiveShareDirectory = nil
                }) { MediaShareSheet(urls: $0.urls) }
                .alert(L10n.text("common.notice"), isPresented: Binding(
                    get: { presentation.errorMessage != nil },
                    set: { if !$0 { presentation.errorMessage = nil } }
                )) {
                    Button(L10n.text("common.ok"), role: .cancel) {}
                } message: { Text(presentation.errorMessage ?? "") }
            } else {
                Text(L10n.text("error.task_missing"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func masonryColumns(for assets: [MediaAssetRecord]) -> [[MediaAssetRecord]] {
        var columns: [[MediaAssetRecord]] = [[], []]
        var estimatedHeights: [CGFloat] = [0, 0]

        for asset in assets {
            let targetColumn = estimatedHeights[0] <= estimatedHeights[1] ? 0 : 1
            columns[targetColumn].append(asset)
            estimatedHeights[targetColumn] += (1 / thumbnailAspectRatio(for: asset)) + 0.18
        }
        return columns
    }

    private func thumbnailAspectRatio(for asset: MediaAssetRecord) -> CGFloat {
        var width = asset.pixelWidth
        var height = asset.pixelHeight

        if (width == nil || height == nil), !asset.localIdentifier.hasPrefix("file:") {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if (status == .authorized || status == .limited),
               let photoAsset = PHAsset.fetchAssets(
                   withLocalIdentifiers: [asset.localIdentifier],
                   options: nil
               ).firstObject {
                width = photoAsset.pixelWidth
                height = photoAsset.pixelHeight
            }
        }

        guard let width, let height, width > 0, height > 0 else {
            return asset.isVideo ? 9 / 16 : 1
        }
        return min(max(CGFloat(width) / CGFloat(height), 0.5), 1.8)
    }

    private func mediaTile(_ asset: MediaAssetRecord) -> some View {
        Button {
            presentation.open(asset.localIdentifier, identifiers: task?.mediaAssets.map(\.localIdentifier) ?? [asset.localIdentifier])
        } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    PhotoAssetThumbnail(localIdentifier: asset.localIdentifier)
                        .allowsHitTesting(false)
                        .aspectRatio(thumbnailAspectRatio(for: asset), contentMode: .fit)
                        .xhsMatchedTransitionSource(id: asset.localIdentifier, in: previewTransition)
                        .overlay {
                            if presentation.loadingIdentifier == asset.localIdentifier {
                                ProgressView().tint(.white).padding(12)
                                    .background(.black.opacity(0.45), in: Circle())
                            }
                        }
                    if asset.isVideo {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.45), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
                            .padding(8)
                    }
                }
                MediaAssetMetadataFooter(asset: asset)
            }
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.975))
        .accessibilityIdentifier("detail-media-\(asset.localIdentifier)")
    }

    @ViewBuilder
    private func mediaSection(_ task: DownloadTaskRecord) -> some View {
        if task.mediaAssets.isEmpty {
            GlassEmptyState(
                title: L10n.text(task.informationOnly == true ? "note.type.text" : "detail.no_media"),
                systemImage: task.informationOnly == true ? "text.alignleft" : "photo.on.rectangle.angled"
            )
        } else {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(masonryColumns(for: task.mediaAssets).enumerated()), id: \.offset) { _, column in
                    LazyVStack(spacing: 10) {
                        ForEach(column) { asset in
                            mediaTile(asset)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }

            Button(role: .destructive) { confirmsPhotoDeletion = true; AppFeedback.play(.warning) } label: {
                Label(L10n.text("task.delete.photos"), systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .contentShape(Capsule())
                    .xhsGlass(tint: .red.opacity(0.10), prominent: false, interactive: true, in: Capsule())
            }
            .buttonStyle(.xhsGlass)
            .padding(.top, 4)
            .confirmationDialog(
                L10n.text("task.delete.photos.confirm"),
                isPresented: $confirmsPhotoDeletion,
                titleVisibility: .visible
            ) {
                Button(L10n.text("task.delete.photos"), role: .destructive) {
                    Task { await coordinator.deleteTask(taskID: task.id, deletePhotos: true) }
                }
                Button(L10n.text("common.cancel"), role: .cancel) {}
            }
        }
    }

    private func captionSection(_ task: DownloadTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(task.noteText.isEmpty ? L10n.text("detail.no_caption") : task.noteText)
                .font(.body)
                .lineSpacing(5)
                .foregroundStyle(task.noteText.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button {
                coordinator.copyToClipboard(task.noteText)
                copiedCaption = true
                copyResetTask?.cancel()
                copyResetTask = Task {
                    try? await Task.sleep(for: .seconds(2.2))
                    guard !Task.isCancelled else { return }
                    copiedCaption = false
                }
            } label: {
                Label {
                    Text(L10n.text(copiedCaption ? "feed.copied" : "action.copy_caption"))
                } icon: {
                    Image(systemName: copiedCaption ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 46)
                .contentShape(Capsule())
                .xhsGlass(tint: .coral, prominent: true, interactive: true, in: Capsule())
            }
            .buttonStyle(.xhsGlass)
            .disabled(task.noteText.isEmpty)
            .opacity(task.noteText.isEmpty ? 0.45 : 1)
            .animation(XHSDesign.animation(reduceMotion, XHSDesign.snappy), value: copiedCaption)
        }
        .padding(16)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: XHSDesign.cardRadius, style: .continuous))
    }

    // MARK: - Resources

    @ViewBuilder
    private func saveSummary(_ task: DownloadTaskRecord) -> some View {
        let slots = resourceSlots(task)
        if task.informationOnly != true, !slots.isEmpty {
            let policy = task.policy ?? DownloadPolicy.load()
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.format("detail.saved_history", task.savedCount, task.mediaAssets.count))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    if policy.destination != .files {
                        Label(L10n.format("detail.save.summary", L10n.text("destination.photos"),
                                          slots.filter { $0.result?.photos?.isSettled == true }.count, slots.count),
                              systemImage: "photo")
                    }
                    if policy.destination != .photos {
                        Label(L10n.format("detail.save.summary", L10n.text("destination.files"),
                                          slots.filter { $0.result?.files?.isSettled == true }.count, slots.count),
                              systemImage: "folder")
                    }
                }
                .font(.caption.weight(.medium))
                if [.failed, .partial].contains(task.status), hasFailedResources(task) {
                    GlassPillButton(title: L10n.text("detail.save.retry"), systemImage: "arrow.clockwise",
                                    tint: .coral, prominent: true) {
                        coordinator.retryFailedResources(taskID: task.id)
                    }
                    .accessibilityIdentifier("task-retry-unsaved")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.cardBackground,
                        in: RoundedRectangle(cornerRadius: XHSDesign.cardRadius, style: .continuous))
            .accessibilityIdentifier("task-save-summary")
        }
    }

    private func hasFailedResources(_ task: DownloadTaskRecord) -> Bool {
        (task.resourceResults ?? [:]).values.contains { $0.state == .failed }
    }

    /// Each row is one stable media slot. The identity comes from the resolved
    /// note, so a re-parse after an expired address still updates the same row
    /// instead of appending a duplicate.
    private struct ResourceSlot: Identifiable {
        let id: String
        let media: RemoteMedia
        let result: ResourceResult?
        let asset: MediaAssetRecord?
    }

    private func resourceSlots(_ task: DownloadTaskRecord) -> [ResourceSlot] {
        guard let note = task.resolvedNote else { return [] }
        let policy = task.policy ?? DownloadPolicy.load()
        let results = task.resourceResults ?? [:]
        return note.media
            .filter { policy.includes($0) && (task.selectedMediaIDs == nil || task.selectedMediaIDs!.contains($0.stableID)) }
            .map { media in
                ResourceSlot(id: media.stableID,
                             media: media,
                             result: results[media.stableID],
                             asset: task.mediaAssets.first { $0.sourceMediaID == media.stableID })
            }
    }

    @ViewBuilder
    private func resourcesSection(_ task: DownloadTaskRecord) -> some View {
        let slots = resourceSlots(task)
        VStack(alignment: .leading, spacing: 12) {
            if slots.isEmpty {
                GlassEmptyState(
                    title: L10n.text("detail.no_media"),
                    systemImage: "tray"
                )
            } else {
                ForEach(slots) { slot in
                    resourceRow(slot)
                }
            }

            if !(task.archiveTextPaths ?? []).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.text("detail.archive"), systemImage: "folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(task.archiveTextPaths ?? [], id: \.self) { path in
                        Text(path)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    Button { shareArchivedFiles(task.archiveTextPaths ?? [], task: task) } label: {
                        Label(L10n.text("detail.archive.share"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(exportingArchive)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let reason = blockingReason(task) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func blockingReason(_ task: DownloadTaskRecord) -> String? {
        switch task.status {
        case .waitingForUser:
            return L10n.text("detail.blocked.selection")
        case .failed, .partial:
            let results = (task.resourceResults ?? [:]).values
            if results.contains(where: { $0.files?.state == .unavailable }) {
                return L10n.text("detail.blocked.directory")
            }
            let message = task.errorMessage ?? ""
            if !message.isEmpty, message == L10n.text("error.photos_permission") {
                return L10n.text("detail.blocked.permission")
            }
            if !message.isEmpty,
               (message == L10n.text("error.archive_directory_missing") || message == L10n.text("error.archive_directory_unavailable")) {
                return L10n.text("detail.blocked.directory")
            }
            return nil
        default:
            return nil
        }
    }

    private func resourceRow(_ slot: ResourceSlot) -> some View {
        let result = slot.result
        let state = result?.state
        return HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: symbol(for: state, isVideo: slot.media.isVideo), color: color(for: state), size: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(roleLabel(slot.media))
                        .font(.subheadline.weight(.semibold))
                    StatusBadge(title: stateLabel(state),
                                systemImage: symbol(for: state, isVideo: slot.media.isVideo),
                                tint: color(for: state),
                                animated: state == .downloading || state == .saving)
                }
                if let detail = byteDetail(result) {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let asset = slot.asset {
                    Text(asset.fileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let paths = asset.filesPaths, !paths.isEmpty {
                        Text(paths[0])
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                // Each destination reports independently: a photo can be in the
                // library while the archive copy is still missing.
                if let photos = result?.photos {
                    destinationRow(L10n.text("destination.photos"), photos)
                }
                if let files = result?.files {
                    destinationRow(L10n.text("destination.files"), files)
                    if files.isSettled {
                        let paths = slot.asset?.filesPaths ?? files.allReferences
                        if !paths.isEmpty, let task {
                            GlassPillButton(title: L10n.text("detail.archive.share"),
                                            systemImage: "square.and.arrow.up",
                                            tint: .coral) {
                                shareArchivedFiles(paths, task: task)
                            }
                            .disabled(exportingArchive)
                            .padding(.top, 2)
                            .accessibilityIdentifier("resource-share-files-\(slot.id)")
                        }
                    }
                }
                if let outcome = result?.livePhotoOutcome {
                    Label(L10n.text(outcome == .merged ? "detail.live.merged" : "detail.live.components"),
                          systemImage: outcome == .merged ? "livephoto" : "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(outcome == .merged ? Color.secondary : Color.orange)
                }
                if let error = result?.error, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground,
                    in: RoundedRectangle(cornerRadius: XHSDesign.tileRadius, style: .continuous))
        .accessibilityIdentifier("resource-row-\(slot.id)")
    }

    private func destinationRow(_ title: String, _ result: DestinationResult) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(destinationStateLabel(result.state))
                .font(.caption2)
                .foregroundStyle(destinationColor(result.state))
            if let error = result.error, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private func destinationStateLabel(_ state: DestinationResult.State) -> String {
        switch state {
        case .pending: return L10n.text("status.queued")
        case .saved: return L10n.text("detail.destination.saved")
        case .failed: return L10n.text("status.failed")
        case .skipped: return L10n.text("status.skipped")
        case .unavailable: return L10n.text("detail.destination.unavailable")
        }
    }

    private func destinationColor(_ state: DestinationResult.State) -> Color {
        switch state {
        case .saved: return .green
        case .failed: return .red
        case .skipped: return .secondary
        case .unavailable: return .orange
        case .pending: return .secondary
        }
    }

    private func shareArchivedFiles(_ paths: [String], task: DownloadTaskRecord) {
        guard !exportingArchive else { return }
        exportingArchive = true
        archiveShareTask?.cancel()
        archiveShareTask = Task {
            defer { exportingArchive = false }
            do {
                let files = try await FileArchiver.shared.shareFiles(paths: paths, bookmark: task.policy?.filesBookmark)
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: files.directory)
                    return
                }
                if let previous = archiveShareDirectory, previous != files.directory {
                    try? FileManager.default.removeItem(at: previous)
                }
                archiveShareDirectory = files.directory
                archiveShare = files
                AppFeedback.play(.success)
            } catch {
                guard !Task.isCancelled else { return }
                presentation.errorMessage = error.localizedDescription
                AppFeedback.play(.error)
            }
        }
    }

    private func roleLabel(_ media: RemoteMedia) -> String {
        switch media.role {
        case .cover: return L10n.text("settings.covers")
        case .comment: return L10n.text("settings.comments")
        default: return media.isVideo ? L10n.text("note.type.video") : L10n.text("note.type.image")
        }
    }

    private func stateLabel(_ state: ResourceResult.State?) -> String {
        switch state {
        case .queued: return L10n.text("status.queued")
        case .downloading: return L10n.text("status.downloading")
        case .saving: return L10n.text("status.saving")
        case .saved: return L10n.text("status.completed")
        case .failed: return L10n.text("status.failed")
        case .skipped: return L10n.text("status.skipped")
        case nil: return L10n.text("status.waiting")
        }
    }

    private func symbol(for state: ResourceResult.State?, isVideo: Bool) -> String {
        switch state {
        case .saved: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .saving: return "square.and.arrow.down"
        case .skipped: return "arrow.uturn.right.circle"
        default: return isVideo ? "video" : "photo"
        }
    }

    private func color(for state: ResourceResult.State?) -> Color {
        switch state {
        case .saved: return .green
        case .failed: return .red
        case .downloading, .saving: return .coral
        case .skipped: return .secondary
        default: return .secondary
        }
    }

    private func byteDetail(_ result: ResourceResult?) -> String? {
        guard let result else { return nil }
        if result.expected > 0 {
            let done = ByteCountFormatter.string(fromByteCount: result.received, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: result.expected, countStyle: .file)
            if result.speed > 0, result.state == .downloading {
                let speed = ByteCountFormatter.string(fromByteCount: Int64(result.speed), countStyle: .file)
                return "\(done) / \(total) · \(speed)/s"
            }
            return "\(done) / \(total)"
        }
        return nil
    }

    private func shareItems(_ task: DownloadTaskRecord) -> [Any] {
        var items: [Any] = []
        if !task.noteText.isEmpty { items.append(task.noteText) }
        if let url = URL(string: task.normalizedURL) { items.append(url) }
        return items
    }
}

struct PhotoAssetThumbnail: View {
    let localIdentifier: String
    var isActive: Bool = true
    var targetPixelSize: CGFloat = 720

    private struct LoadKey: Equatable {
        let id: String
        let active: Bool
    }

    @ObservedObject private var previews = MediaPreviewImages.shared
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?
    @State private var generation = UUID()
    /// Set when the cover can never load (missing/unauthorized asset or a video
    /// with no extractable frame), so the card shows a placeholder instead of
    /// spinning forever.
    @State private var loadFailed = false
    @State private var isVideoFallback = false

    init(localIdentifier: String, isActive: Bool = true, targetPixelSize: CGFloat = 720) {
        self.localIdentifier = localIdentifier
        self.isActive = isActive
        self.targetPixelSize = targetPixelSize
    }

    var body: some View {
        Group {
            if let image = previews.image(for: localIdentifier) ?? image {
                HDRImage(image: image, range: .constrainedHigh)
            } else if loadFailed {
                Rectangle()
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .overlay {
                        Image(systemName: isVideoFallback ? "video.fill" : "photo")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
            } else {
                Rectangle()
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .overlay {
                        if isActive { ProgressView() }
                    }
            }
        }
        .clipped()
        .task(id: LoadKey(id: localIdentifier, active: isActive)) { await load() }
        .onDisappear { cancel() }
    }

    private func load() async {
        cancel()
        guard isActive else {
            image = nil
            loadFailed = false
            return
        }
        let token = generation
        loadFailed = false
        isVideoFallback = false
        if let prepared = previews.image(for: localIdentifier) {
            image = prepared
            return
        }
        image = nil
        if localIdentifier.hasPrefix("file:") {
            do {
                let thumbnail = try await ArchiveMediaLoader.shared.image(identifier: localIdentifier, thumbnail: true)
                guard token == generation, !Task.isCancelled else { return }
                image = thumbnail
            } catch {
                if token == generation, !Task.isCancelled {
                    isVideoFallback = ArchiveAccess.paths(in: localIdentifier)
                        .contains { MediaFileValidator.isVideoFile(URL(fileURLWithPath: $0)) }
                    loadFailed = true
                }
            }
            return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            loadFailed = true
            return
        }
        let isVideo = asset.mediaType == .video
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact
        options.preferHDR = true
        options.isNetworkAccessAllowed = true
        request = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: targetPixelSize, height: targetPixelSize),
            // Keep the complete image. The UIImageView applies the card's
            // aspect-fill crop once, matching the full-resolution hero image.
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
            let cancelled = info?[PHImageCancelledKey] as? Bool == true
            Task { @MainActor in
                guard generation == token, !cancelled else { return }
                if let image {
                    self.image = image
                    self.loadFailed = false
                }
                if !degraded {
                    request = nil
                    if image == nil && self.image == nil {
                        self.isVideoFallback = isVideo
                        self.loadFailed = true
                    }
                }
            }
        }
    }

    private func cancel() {
        generation = UUID()
        if let request { PHImageManager.default().cancelImageRequest(request) }
        request = nil
    }
}


private struct MediaAssetMetadataFooter: View {
    let asset: MediaAssetRecord

    @State private var fallbackPixelWidth: Int?
    @State private var fallbackPixelHeight: Int?
    @State private var fallbackByteCount: Int64?

    private var pixelWidth: Int? { asset.pixelWidth ?? fallbackPixelWidth }
    private var pixelHeight: Int? { asset.pixelHeight ?? fallbackPixelHeight }
    private var byteCount: Int64? { asset.byteCount ?? fallbackByteCount }

    var body: some View {
        HStack(spacing: 6) {
            Text(resolutionText)
            Spacer(minLength: 4)
            Text(fileSizeText)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .task(id: asset.localIdentifier) { loadFallbackMetadata() }
    }

    private var resolutionText: String {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return "—" }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    private var fileSizeText: String {
        guard let byteCount, byteCount > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private func loadFallbackMetadata() {
        fallbackPixelWidth = nil
        fallbackPixelHeight = nil
        fallbackByteCount = nil
        guard !asset.localIdentifier.hasPrefix("file:") else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let photoAsset = PHAsset.fetchAssets(
                  withLocalIdentifiers: [asset.localIdentifier],
                  options: nil
              ).firstObject else { return }

        if asset.pixelWidth == nil || asset.pixelHeight == nil {
            fallbackPixelWidth = photoAsset.pixelWidth
            fallbackPixelHeight = photoAsset.pixelHeight
        }

        guard asset.byteCount == nil else { return }
        let resources = PHAssetResource.assetResources(for: photoAsset)
        let preferredType: PHAssetResourceType = asset.isVideo ? .video : .photo
        guard let resource = resources.first(where: { $0.type == preferredType }) ?? resources.first else { return }
        if let size = resource.value(forKey: "fileSize") as? Int64, size > 0 {
            fallbackByteCount = size
        } else if let size = resource.value(forKey: "fileSize") as? NSNumber, size.int64Value > 0 {
            fallbackByteCount = size.int64Value
        }
    }
}

private struct SelectiveDownloadView: View {
    @ObservedObject var coordinator: DownloadCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: SelectiveDownloadState? { coordinator.selectionState }

    private func masonryColumns(for items: [SelectiveMediaItem]) -> [[SelectiveMediaItem]] {
        var columns: [[SelectiveMediaItem]] = [[], []]
        var estimatedHeights: [CGFloat] = [0, 0]

        for item in items {
            let targetColumn = estimatedHeights[0] <= estimatedHeights[1] ? 0 : 1
            columns[targetColumn].append(item)
            estimatedHeights[targetColumn] += (1 / thumbnailAspectRatio(for: item)) + 0.08
        }
        return columns
    }

    private func thumbnailAspectRatio(for item: SelectiveMediaItem) -> CGFloat {
        guard let width = item.remote.width, let height = item.remote.height, height > 0 else { return item.remote.isVideo ? 9 / 16 : 3 / 4 }
        return min(max(CGFloat(width) / CGFloat(height), 0.5), 1.8)
    }

    private func selectiveMediaTile(_ item: SelectiveMediaItem) -> some View {
        Button {
            withAnimation(XHSDesign.animation(reduceMotion, XHSDesign.snappy)) {
                coordinator.updateSelection(id: item.id, selected: !item.isSelected)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                CachedMediaThumbnail(item: item)
                    .aspectRatio(thumbnailAspectRatio(for: item), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(item.isSelected ? Color.coral : Color.primary.opacity(0.08),
                                          lineWidth: item.isSelected ? 2.5 : 0.5)
                    }
                ZStack {
                    if item.isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.coral)
                    } else {
                        Circle()
                            .fill(Color.black.opacity(0.38))
                            .frame(width: 24, height: 24)
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: 1.75)
                            }
                    }
                }
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .padding(8)
            }
            .scaleEffect(item.isSelected && !reduceMotion ? 0.97 : 1)
            .shadow(color: item.isSelected ? .coral.opacity(0.18) : .black.opacity(0.04), radius: 8, y: 3)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let state {
                    ScrollView {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(masonryColumns(for: state.items).enumerated()), id: \.offset) { _, column in
                                LazyVStack(spacing: 12) {
                                    ForEach(column) { item in
                                        selectiveMediaTile(item)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                            }
                        }
                        .padding()
                    }
                    .overlay {
                        if state.phase == .caching || state.phase == .saving {
                            ZStack {
                                Color.black.opacity(0.15).ignoresSafeArea()
                                ProgressView(state.phase == .caching ? L10n.text("selection.caching") : L10n.text("selection.saving"))
                                    .padding(24)
                                    .xhsGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .background { GlassBackdrop(color: .coral, intensity: 0.75) }
            .xhsSafeAreaBar(edge: .bottom, spacing: 0) {
                if let state {
                    let selectedCount = state.items.filter(\.isSelected).count
                    let canSave = state.phase == .ready && selectedCount > 0
                    XHSGlassContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            Button {
                                withAnimation(XHSDesign.animation(reduceMotion, XHSDesign.snappy)) {
                                    coordinator.selectAll(state.items.contains(where: { !$0.isSelected }))
                                }
                            } label: {
                                Text(L10n.text("selection.all"))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 46)
                                    .contentShape(Capsule())
                                    .xhsGlass(interactive: true, in: Capsule())
                            }
                            .buttonStyle(.xhsGlass)
                            .disabled(state.phase != .ready)
                            .opacity(state.phase == .ready ? 1 : 0.45)

                            Spacer(minLength: 0)

                            Text(L10n.format("selection.count", selectedCount, state.items.count))
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .contentTransition(.numericText(value: Double(selectedCount)))
                                .padding(.horizontal, 14)
                                .frame(minHeight: 46)
                                .xhsGlass(in: Capsule())

                            Button {
                                coordinator.saveSelection()
                            } label: {
                                Text(L10n.text("selection.save"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 18)
                                    .frame(minHeight: 46)
                                    .contentShape(Capsule())
                                    .xhsGlass(tint: .coral, prominent: true, interactive: true, in: Capsule())
                            }
                            .buttonStyle(.xhsGlass)
                            .disabled(!canSave)
                            .opacity(canSave ? 1 : 0.45)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                    .xhsBarBackdrop(edge: .bottom)
                }
            }
            .xhsSoftBottomEdgeEffect()
            .navigationTitle(L10n.text("selection.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel")) { coordinator.cancelSelection() }
                }
            }
        }
        .tint(.coral)
    }
}

private struct CachedMediaThumbnail: View {
    let item: SelectiveMediaItem
    var body: some View {
        Color(uiColor: .tertiarySystemFill)
            .overlay {
                if let preview = item.remote.previewURL ?? (item.remote.isVideo ? nil : item.remote.url) {
                    AsyncImage(url: preview) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: item.remote.isVideo ? "video" : "photo")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        case .empty:
                            ProgressView()
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
            .overlay {
                if item.remote.isVideo {
                    Image(systemName: "play.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.45), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.remote.type == .livePhoto {
                    Label("LIVE", systemImage: "livephoto").font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 5).foregroundStyle(.white)
                        .background(.black.opacity(0.45), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .padding(8)
                }
            }
            .clipped()
    }
}

private struct ManualInputView: View {
    @ObservedObject var coordinator: DownloadCoordinator
    let onSubmit: (String, ImportRequest.Behavior) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var input = ""
    @State private var isExtracting = false
    @State private var extractedCaption = ""
    @State private var errorMessage: String?
    @State private var extractTask: Task<Void, Never>?

    private var hasLink: Bool { XHSURLDetector.containsSupportedLink(input) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $input)
                        .frame(minHeight: 150)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("manual-input-field")

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            manualLinkStatusBadge
                            Spacer(minLength: 0)
                            manualPasteClipboardButton
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            manualLinkStatusBadge
                            manualPasteClipboardButton
                        }
                    }
                    .animation(XHSDesign.animation(reduceMotion, XHSDesign.snappy), value: hasLink)
                } header: {
                    Text(L10n.text("manual.section.input"))
                } footer: {
                    Text(L10n.text("download.subtitle"))
                        .font(.caption)
                }

                if !extractedCaption.isEmpty {
                    Section {
                        Text(extractedCaption).textSelection(.enabled)
                        Button {
                            coordinator.copyToClipboard(extractedCaption)
                        } label: {
                            Label(L10n.text("action.copy_caption"), systemImage: "doc.on.doc")
                        }
                    } header: {
                        Text(L10n.text("manual.section.extracted"))
                    }
                }

                // The three entry actions are spelled out instead of hiding
                // behind a menu: they produce different tasks and users need to
                // see the choice before committing.
                Section {
                    Button {
                        submit(.direct)
                    } label: {
                        Label {
                            Text(L10n.text("manual.action.download"))
                                .fontWeight(.semibold)
                        } icon: {
                            IconTile(systemImage: "arrow.down", color: .coral, size: 28)
                                .opacity(hasLink ? 1 : 0.45)
                        }
                    }
                    .disabled(!hasLink)
                    .accessibilityIdentifier("manual-download-button")

                    Button {
                        submit(.select)
                    } label: {
                        Label {
                            Text(L10n.text("manual.action.select"))
                        } icon: {
                            IconTile(systemImage: "checklist", color: .orange, size: 28)
                                .opacity(hasLink ? 1 : 0.45)
                        }
                    }
                    .disabled(!hasLink)
                    .accessibilityIdentifier("manual-select-button")

                    Button {
                        submit(.informationOnly)
                    } label: {
                        Label {
                            Text(L10n.text("manual.action.information"))
                        } icon: {
                            IconTile(systemImage: "text.book.closed", color: .blue, size: 28)
                                .opacity(hasLink ? 1 : 0.45)
                        }
                    }
                    .disabled(!hasLink)
                    .accessibilityIdentifier("manual-information-button")

                    Button {
                        extractCaption()
                    } label: {
                        HStack {
                            Label {
                                Text(L10n.text("action.copy_caption"))
                            } icon: {
                                IconTile(systemImage: "text.quote", color: .purple, size: 28)
                                    .opacity(isExtracting || !hasLink ? 0.45 : 1)
                            }
                            Spacer()
                            if isExtracting { ProgressView() }
                        }
                    }
                    .disabled(isExtracting || !hasLink)
                }
            }
            .scrollContentBackground(.hidden)
            .background { GlassBackdrop(color: .coral, intensity: 0.7) }
            .navigationTitle(L10n.text("action.manual_input"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel")) { dismiss() }
                }
            }
        }
        .tint(.coral)
        .onDisappear {
            extractTask?.cancel()
            extractTask = nil
        }
        .alert(
            L10n.text("common.notice"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: { Button(L10n.text("common.ok"), role: .cancel) { errorMessage = nil } },
            message: { Text(errorMessage ?? "") }
        )
    }

    private var manualLinkStatusBadge: some View {
        StatusBadge(
            title: L10n.text(hasLink ? "manual.link_detected" : "manual.link_waiting"),
            systemImage: hasLink ? "checkmark.circle.fill" : "link",
            tint: hasLink ? .green : .secondary
        )
    }

    private var manualPasteClipboardButton: some View {
        Button {
            if let text = UIPasteboard.general.string, !text.isEmpty {
                input = text
                AppFeedback.play(.confirmation)
            }
        } label: {
            Label(L10n.text("manual.paste_clipboard"), systemImage: "doc.on.clipboard")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(.coral)
    }

    private func submit(_ behavior: ImportRequest.Behavior) {
        onSubmit(input, behavior)
    }

    private func extractCaption() {
        guard !isExtracting else { return }
        isExtracting = true
        let text = input
        let policy = coordinator.settings.policy
        extractTask?.cancel()
        extractTask = Task {
            defer { isExtracting = false }
            do {
                let caption = try await XHSDownloader(policy: policy).extractDescription(from: text) { _ in }
                guard !Task.isCancelled else { return }
                extractedCaption = caption
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                AppFeedback.play(.error)
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension View {
    func xhsCompactSectionSpacing() -> some View {
        self.listSectionSpacing(12)
    }

    func xhsPrimaryGlass() -> some View {
        self.xhsGlass(tint: .coral, prominent: true, interactive: true, in: Capsule())
    }

    func xhsCircularGlass() -> some View {
        self.xhsGlass(interactive: true, in: Circle())
    }

    @ViewBuilder
    func xhsFloatingControlShadow(color: Color) -> some View {
        if #available(iOS 26.0, *) {
            self.shadow(color: color, radius: 12, y: 6)
        } else {
            self.shadow(color: color, radius: 7, y: 3)
        }
    }

    @ViewBuilder
    func xhsFloatingBarBottomPadding() -> some View {
        if #available(iOS 26.0, *) {
            self.padding(.bottom, 8)
        } else {
            self.padding(.bottom, 12)
        }
    }

    @ViewBuilder
    func xhsBannerCardSurface(accent: Color) -> some View {
        if #available(iOS 26.0, *) {
            let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(XHSDesign.cardRadius)), isUniform: true)
            self
                .background {
                    shape.fill(Color.cardBackground)
                    shape.fill(LinearGradient(colors: [accent.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    shape.stroke(accent.opacity(0.16), lineWidth: 2)
                        .allowsHitTesting(false)
                }
                .clipShape(shape)
                .contentShape(shape)
        } else {
            let shape = RoundedRectangle(cornerRadius: XHSDesign.cardRadius, style: .continuous)
            self
                .background {
                    shape.fill(Color.cardBackground)
                    shape.fill(LinearGradient(colors: [accent.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    shape.strokeBorder(accent.opacity(0.16), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .clipShape(shape)
                .contentShape(shape)
        }
    }
}

#Preview {
    let settings = AppSettings()
    ContentView(coordinator: DownloadCoordinator(settings: settings), settings: settings)
}
