import SwiftUI
import WebKit
import Combine

/// A persistent browsing surface. It shares the app's website data store with
/// the rest of the downloader, so a login performed here immediately supplies
/// cookies to the parser and the media transfers.
struct BrowserView: View {
    @ObservedObject var settings: AppSettings
    var onImport: (BrowserImport, ImportRequest.Behavior) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model = BrowserModel()
    @ObservedObject private var session = WebSession.shared

    @State private var showsLinks = false
    @State private var showsZoom = false
    @State private var isImporting = false
    @State private var zoomBeforeEditing: Double?
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            BrowserWebContainer(model: model)
                .overlay(alignment: .top) {
                    if model.progress > 0, model.progress < 1 {
                        ProgressView(value: model.progress)
                            .progressViewStyle(.linear)
                            .tint(.coral)
                    }
                }
                .xhsSafeAreaBar(edge: .top, spacing: 0) { addressBar }
                .xhsSafeAreaBar(edge: .bottom, spacing: 0) { bottomBar }
            .navigationTitle(session.account?.name ?? L10n.text("browser.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showsLinks) {
                BrowserLinkList(links: model.noteLinks) { link in
                    showsLinks = false
                    model.load(link.href)
                } onImport: { link in
                    showsLinks = false
                    onImport(.link(link.href), .direct)
                }
            }
            .sheet(isPresented: $showsZoom) {
                zoomSheet
                    .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.medium, .large] : [.height(240), .medium])
            }
            .task {
                model.startSessionObservation()
                if model.address.isEmpty { model.load("https://www.xiaohongshu.com/explore") }
            }
            .onDisappear {
                model.stopSessionObservation()
                Task { await model.refreshSession() }
            }
            .onChange(of: showsLinks) { _, shown in if shown { AppFeedback.play(.navigation) } }
            .onChange(of: showsZoom) { _, shown in if shown { AppFeedback.play(.navigation) } }
            .onChange(of: model.alert) { _, message in if message != nil { AppFeedback.play(.error) } }
            .alert(L10n.text("common.notice"), isPresented: Binding(
                get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }
            )) {
                Button(L10n.text("common.ok"), role: .cancel) { model.alert = nil }
            } message: { Text(model.alert ?? "") }
        }
        .tint(.coral)
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            if model.currentURL?.scheme?.lowercased() == "https" {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            TextField(L10n.text("web.address"), text: $model.address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.callout)
                .focused($addressFocused)
                .onChange(of: addressFocused) { _, focused in model.setEditingAddress(focused) }
                .submitLabel(.go)
                .onSubmit {
                    addressFocused = false
                    model.commitAddress()
                    AppFeedback.play(.confirmation)
                }
                .accessibilityIdentifier("browser-address-field")
            if model.isLoading {
                Button {
                    model.stop()
                    AppFeedback.play(.deactivation)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .xhsGlass(interactive: true, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background { browserBarBackdrop(edge: .top) }
    }

    private var bottomBar: some View {
        let canImport = model.currentNoteURL != nil && !isImporting
        return XHSGlassContainer(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    importCurrent(.direct)
                } label: {
                    Label(L10n.text("browser.download_this"), systemImage: "arrow.down.circle.fill")
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .foregroundStyle(.white)
                        .opacity(canImport ? 1 : 0.45)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .xhsGlass(tint: .coral, prominent: true, interactive: canImport, in: Capsule())
                .disabled(!canImport)
                .layoutPriority(1)

                Button {
                    importCurrent(.select)
                } label: {
                    Label(L10n.text("browser.choose"), systemImage: "checklist")
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .foregroundStyle(.primary)
                        .opacity(canImport ? 1 : 0.45)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .xhsGlass(interactive: canImport, in: Capsule())
                .disabled(!canImport)

                Button {
                    importCurrent(.informationOnly)
                } label: {
                    Label(L10n.text("browser.save_caption"), systemImage: "text.alignleft")
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .foregroundStyle(.primary)
                        .opacity(canImport ? 1 : 0.45)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .xhsGlass(interactive: canImport, in: Capsule())
                .disabled(!canImport)

                Button {
                    model.refreshLinks()
                    showsLinks = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .xhsGlass(interactive: true, in: Circle())
                .accessibilityLabel(L10n.text("browser.links"))
                .accessibilityIdentifier("browser-links-button")
            }
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { browserBarBackdrop(edge: .bottom) }
    }

    @ViewBuilder
    private func browserBarBackdrop(edge: VerticalEdge) -> some View {
        if #available(iOS 26.0, *) {
            Color.clear
        } else {
            Rectangle()
                .fill(.bar)
                .overlay(alignment: edge == .top ? .bottom : .top) {
                    Divider()
                }
                .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(L10n.text("common.close")) {
                AppFeedback.play(.navigation)
                dismiss()
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                model.goBack()
                AppFeedback.play(.navigation)
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!model.canGoBack)
            .accessibilityLabel(L10n.text("browser.back"))

            Button {
                model.goForward()
                AppFeedback.play(.navigation)
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!model.canGoForward)
            .accessibilityLabel(L10n.text("browser.forward"))

            Button {
                model.reload()
                AppFeedback.play(.confirmation)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(L10n.text("browser.reload"))

            Menu {
                Button {
                    showsZoom = true
                } label: {
                    Label(L10n.text("browser.zoom"), systemImage: "textformat.size")
                }
                if let url = model.currentURL {
                    Link(destination: url) {
                        Label(L10n.text("browser.open_system"), systemImage: "safari")
                    }
                }
                if session.account == nil {
                    Button {
                        model.load("https://www.xiaohongshu.com/explore")
                    } label: {
                        Label(L10n.text("browser.login"), systemImage: "person.crop.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var zoomSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("browser.zoom")).font(.headline)
                HStack {
                    Text("\(Int(model.zoom * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Slider(value: $model.zoom, in: 0.5...2.0, step: 0.1) { editing in
                        if editing { zoomBeforeEditing = model.zoom }
                        else {
                            let changed = zoomBeforeEditing.map { $0 != model.zoom } ?? false
                            zoomBeforeEditing = nil
                            if changed { AppFeedback.play(.selection) }
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    XHSGlassContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach([0.75, 1.0, 1.25, 1.5], id: \.self) { value in
                                let selected = abs(model.zoom - value) < 0.01
                                Button {
                                    guard model.zoom != value else { return }
                                    model.zoom = value
                                    AppFeedback.play(.selection)
                                } label: {
                                    Text("\(Int(value * 100))%")
                                        .font(.footnote.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(selected ? .white : .primary)
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 36)
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .xhsGlass(tint: selected ? .coral : nil, prominent: selected, interactive: true, in: Capsule())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .scrollClipDisabled()
            }
            .padding(20)
        }
    }

    /// Prefers the note object already in the page; falls back to the URL only
    /// when the page has no structured state yet (for example a just-opened tab).
    private func importCurrent(_ behavior: ImportRequest.Behavior) {
        guard !isImporting else { return }
        guard let url = model.currentNoteURL else {
            model.alert = L10n.text("browser.no_note")
            return
        }
        isImporting = true
        Task {
            defer { isImporting = false }
            if let payload = await model.extractCurrentNote() {
                onImport(.page(payload), behavior)
            } else {
                onImport(.link(url.absoluteString), behavior)
            }
        }
    }
}

private struct BrowserLinkList: View {
    let links: [BrowserLink]
    let onOpen: (BrowserLink) -> Void
    let onImport: (BrowserLink) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if links.isEmpty {
                    Section {
                        Text(L10n.text("browser.links.empty"))
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text(L10n.text("browser.links.hint"))
                    }
                } else {
                    Section {
                        ForEach(links) { link in
                            Button {
                                onOpen(link)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(link.title.isEmpty ? link.id : link.title)
                                        .font(.callout)
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                    Text(link.id)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button {
                                    onImport(link)
                                } label: {
                                    Label(L10n.text("browser.download_this"), systemImage: "arrow.down")
                                }
                                .tint(.coral)
                            }
                        }
                    } header: {
                        Text(L10n.text("browser.links"))
                    } footer: {
                        Text(L10n.text("browser.links.hint"))
                    }
                }
            }
            .navigationTitle(L10n.text("browser.links"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("common.done")) { dismiss() }
                }
            }
        }
    }
}

/// What the browser hands to the import pipeline: either the note data it already
/// has, or a link when the page has no usable state.
enum BrowserImport {
    case page(BrowserNotePayload)
    case link(String)

    var text: String {
        switch self {
        case .page(let payload): return payload.pageURL.absoluteString
        case .link(let value): return value
        }
    }
}

/// Structured note data captured from the live page. Passing it to the download
/// pipeline skips a second network request and keeps the page's own access token.
struct BrowserNotePayload: @unchecked Sendable {
    let note: [String: Any]
    let comments: Any?
    let pageURL: URL
    let noteID: String
}

struct BrowserLink: Identifiable, Hashable {
    let id: String
    let href: String
    let title: String
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    @Published var address = ""
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var noteLinks: [BrowserLink] = []
    @Published var currentURL: URL?
    @Published var alert: String?
    @Published var zoom: Double = 1.0 {
        didSet { webView.pageZoom = zoom }
    }

    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // The shared store is what makes a login persist across launches and
        // what lets the downloader read the same cookies.
        configuration.websiteDataStore = WebSession.shared.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.pageZoom = zoom
        view.isInspectable = false
        return view
    }()

    private var progressObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var backObservation: NSKeyValueObservation?
    private var forwardObservation: NSKeyValueObservation?

    override init() {
        super.init()
        _ = webView
        // Bind the weak reference to a local constant before hopping to the main
        // actor: capturing a mutable weak binding inside Task is a Swift 6 error.
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            let value = view.estimatedProgress
            guard let owner = self else { return }
            Task { @MainActor in owner.progress = value }
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            let url = view.url
            guard let owner = self else { return }
            Task { @MainActor in
                guard let url else { return }
                owner.currentURL = url
                if !owner.isEditingAddress { owner.address = url.absoluteString }
            }
        }
        backObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
            let value = view.canGoBack
            guard let owner = self else { return }
            Task { @MainActor in owner.canGoBack = value }
        }
        forwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
            let value = view.canGoForward
            guard let owner = self else { return }
            Task { @MainActor in owner.canGoForward = value }
        }
    }

    private var isEditingAddress = false
    private var observesSession = false
    private var cookieRefresh: Task<Void, Never>?
    private var sessionNeedsRefresh = false

    func setEditingAddress(_ editing: Bool) {
        isEditingAddress = editing
    }

    func startSessionObservation() {
        guard !observesSession else { return }
        observesSession = true
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
    }

    func stopSessionObservation() {
        guard observesSession else { return }
        observesSession = false
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            guard let self, self.observesSession else { return }
            self.sessionNeedsRefresh = true
            guard self.cookieRefresh == nil else { return }
            self.cookieRefresh = Task { @MainActor [weak self] in
                guard let self else { return }
                repeat {
                    self.sessionNeedsRefresh = false
                    await self.refreshSession()
                } while self.sessionNeedsRefresh && self.observesSession
                self.cookieRefresh = nil
            }
        }
    }

    func refreshSession() async {
        await WebSession.shared.captureAccount(from: webView)
    }

    /// The live page URL, including `xsec_token` and friends. Rebuilding a bare
    /// `/explore/ID` would drop the token the signed-in page actually used.
    var currentNoteURL: URL? {
        guard let url = currentURL, Self.noteID(from: url) != nil else { return nil }
        return url
    }

    static func noteID(from url: URL) -> String? {
        XHSURLDetector.noteID(from: url)
    }

    func load(_ string: String) {
        guard let url = Self.normalizedURL(string) else {
            alert = L10n.text("error.invalid_url")
            return
        }
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func commitAddress() {
        load(address)
    }

    static func normalizedURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    /// Reads the note object that the signed-in page has already loaded, so the
    /// app parses the same data the browser shows instead of fetching the URL
    /// again. Returns nil when the page has no note state yet.
    func extractCurrentNote() async -> BrowserNotePayload? {
        guard let pageURL = currentURL, let noteID = Self.noteID(from: pageURL) else { return nil }
        let script = Self.noteCaptureScript(noteID: noteID)
        guard let text = try? await webView.evaluateJavaScript(script) as? String,
              currentURL == pageURL,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let note = object["note"] as? [String: Any] else { return nil }
        return BrowserNotePayload(note: note,
                                  comments: object["comments"],
                                  pageURL: pageURL,
                                  noteID: noteID)
    }

    static func noteCaptureScript(noteID: String) -> String {
        // JSON encoding keeps this helper safe even outside the validated URL path.
        let encodedID = String(data: try! JSONEncoder().encode(noteID), encoding: .utf8)!
        return """
        (() => {
          const target = \(encodedID);
          const s = window.__INITIAL_STATE__;
          if (!s) return null;
          const unwrap = v => (v && typeof v === 'object' && ('_rawValue' in v)) ? v._rawValue : v;
          const identity = v => v && (v.noteId || v.note_id || v.id);
          const fromEntry = entry => entry && unwrap(unwrap(entry).note || unwrap(entry));
          const map = unwrap(s.note && s.note.noteDetailMap);
          let note = null;
          if (map && typeof map === 'object') {
            note = fromEntry(map[target]);
            if (note && identity(note) && identity(note) !== target) note = null;
            if (!note) note = Object.values(map).map(fromEntry).find(v => identity(v) === target) || null;
          }
          if (!note) {
            const data = unwrap(s.noteData && s.noteData.data);
            const candidate = data ? unwrap(data.noteData) : null;
            if (identity(candidate) === target) note = candidate;
          }
          if (!note) return null;
          const comments = unwrap(s.note && s.note.comments);
          return JSON.stringify({ note: note, comments: comments || null });
        })()
        """
    }

    func refreshLinks() {
        let script = """
        (() => {
          const out = [];
          const seen = new Set();
          document.querySelectorAll('a[href*="/explore/"], a[href*="/discovery/item/"]').forEach(a => {
            const href = a.href || '';
            const m = href.match(/(?:explore|item)\\/([0-9a-zA-Z]{24})/);
            if (!m || seen.has(m[1])) return;
            seen.add(m[1]);
            out.push({id: m[1], href: href, title: (a.innerText || '').trim().replace(/\\s+/g, ' ').slice(0, 80)});
          });
          return JSON.stringify(out.slice(0, 200));
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let text = result as? String, let data = text.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let links = items.compactMap { item -> BrowserLink? in
                guard let id = item["id"] as? String, let href = item["href"] as? String else { return nil }
                return BrowserLink(id: id, href: href, title: item["title"] as? String ?? "")
            }
            Task { @MainActor in self?.noteLinks = links }
        }
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let scheme = navigationAction.request.url?.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data"].contains(scheme) {
            // Silently ignore app deep-link schemes (e.g. xhsdiscover://) so
            // they don't fail provisional navigation with an error alert.
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        progress = 1
        syncNavigationState()
        Task { await refreshSession() }
        refreshLinks()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        syncNavigationState()
        if (error as NSError).code != NSURLErrorCancelled { alert = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        syncNavigationState()
        if (error as NSError).code != NSURLErrorCancelled { alert = error.localizedDescription }
    }

    private func syncNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

private struct BrowserWebContainer: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeUIView(context: Context) -> WKWebView {
        model.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
