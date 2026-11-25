import SwiftUI
import Combine
import Photos
import PhotosUI
import AVKit
import UniformTypeIdentifiers

extension Color {
    static let coral = Color(red: 0.94, green: 0.28, blue: 0.36)
}

/// Ambient page backdrop. Soft coloured light pools near the top give the
/// floating glass something to refract, then fade into the grouped background
/// so cards and text keep their normal contrast.
struct GlassBackdrop: View {
    let color: Color
    var intensity: Double = 1
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            if !reduceTransparency {
                let strength = (colorScheme == .dark ? 0.55 : 1) * intensity
                ZStack {
                    RadialGradient(colors: [color.opacity(0.26 * strength), .clear],
                                   center: UnitPoint(x: 0.08, y: 0.0),
                                   startRadius: 0, endRadius: 380)
                    RadialGradient(colors: [Color.coralWarm.opacity(0.18 * strength), .clear],
                                   center: UnitPoint(x: 0.95, y: 0.06),
                                   startRadius: 0, endRadius: 320)
                    RadialGradient(colors: [color.opacity(0.08 * strength), .clear],
                                   center: UnitPoint(x: 0.7, y: 1.0),
                                   startRadius: 0, endRadius: 420)
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

@MainActor
final class MediaLibraryModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var assets: [PHAsset] = []
    @Published var authorized = false
    private var legacyIdentifiers: [String] = []
    private var isObserving = false

    deinit {
        if isObserving { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.reload() }
    }

    func load(legacyIdentifiers: [String], requestPermission: Bool = false) async {
        self.legacyIdentifiers = legacyIdentifiers
        if requestPermission { _ = await PhotoLibraryService.shared.requestWriteAuthorization() }
        reload()
    }

    private func reload() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorized = status == .authorized || status == .limited
        guard authorized else { assets = []; return }
        // Registering a Photos observer can request access. Do it only after
        // authorization, never while constructing an inactive Library tab.
        if !isObserving {
            PHPhotoLibrary.shared().register(self)
            isObserving = true
        }
        var result: [PHAsset] = []
        #if DEBUG
        let fixture = ProcessInfo.processInfo.arguments.contains { ["-ui-test-task-center", "-ui-test-note-feed", "-ui-test-text-notes"].contains($0) }
        #else
        let fixture = false
        #endif
        if !fixture, let id = UserDefaults.standard.string(forKey: "photos.albumIdentifier"),
           let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in result.append(asset) }
        }
        // Old versions saved without an album. Keep those Photos references visible.
        PHAsset.fetchAssets(withLocalIdentifiers: legacyIdentifiers, options: nil)
            .enumerateObjects { asset, _, _ in result.append(asset) }
        var seen = Set<String>()
        assets = result.filter { seen.insert($0.localIdentifier).inserted }
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }
}

struct MediaLibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var coordinator: DownloadCoordinator
    @StateObject private var model = MediaLibraryModel()
    @StateObject private var preferences = NoteLibraryPreferences()
    @StateObject private var presentation = MediaPresentation()
    @Namespace private var previewTransition
    @StateObject private var feedGeometry = NoteHeroGeometry()
    @StateObject private var readerGeometry = NoteHeroGeometry()
    @State private var filter = 0
    @State private var scope = 0
    @State private var search = ""
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool
    @State private var openedNote: LibraryNote?
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var deletion = Set<String>()
    @State private var showsDeletion = false
    @State private var notesToDelete = Set<String>()
    @State private var showsNoteDeletion = false
    @State private var reauthorizeNote: String?
    @State private var showsArchivePicker = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var share: MediaShareFiles?
    @State private var shareDirectory: URL?
    @State private var authorFilter: String?
    @State private var collectionFilter: UUID?
    @State private var showsNewCollection = false
    @State private var newCollectionName = ""
    @State private var collectionToRename: NoteCollection?
    @State private var renameText = ""
    @State private var collectionToDelete: NoteCollection?
    @State private var authorToRemark: AuthorTarget?
    @State private var remarkText = ""
    @State private var scrollBucket: Int = 0
    @State private var lastViewportHeight: CGFloat = 0

    struct AuthorTarget: Identifiable {
        let id: String
        let name: String
    }

    private struct LibrarySnapshot {
        let sortedNotes: [LibraryNote]
        let visible: [LibraryNote]
        let visibleIDs: Set<String>
        let authors: [(key: String, name: String, count: Int)]
        let selectedNotes: [LibraryNote]
        let selectedLinks: [String]
    }

    private var identifiers: [String] { coordinator.notes.flatMap(\.mediaAssets).map(\.localIdentifier) }

    /// Computes note merging, sorting, filtering and author grouping once per
    /// render pass instead of repeating O(N log N) passes across body subviews.
    private func makeSnapshot() -> LibrarySnapshot {
        let all = NoteLibrary.notes(stored: coordinator.notes,
                                    media: model.assets.map(LibraryMedia.init),
                                    hiddenMediaIDs: coordinator.hiddenMediaIDs)
        let sorted = NoteLibrary.sorted(all, by: preferences.sortOrder)
        let activeCollection = collectionFilter.flatMap { coordinator.collection($0) }
        let visible = sorted.filter { note in
            guard note.matches(query: search, filter: filter,
                               remark: coordinator.remark(for: note.authorKey)) else { return false }
            if scope == 1, !coordinator.likedNotes.contains(note.id) { return false }
            if let authorFilter, note.authorKey != authorFilter { return false }
            if collectionFilter != nil, !(activeCollection?.noteIDs.contains(note.id) ?? false) { return false }
            return true
        }
        var authorMap: [String: (name: String, count: Int)] = [:]
        for note in all {
            guard let key = note.authorKey else { continue }
            var entry = authorMap[key] ?? (note.author, 0)
            entry.count += 1
            entry.name = coordinator.remark(for: key) ?? note.author
            authorMap[key] = entry
        }
        let authors = authorMap.map { (key: $0.key, name: $0.value.name, count: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let visibleIDs = Set(visible.map(\.id))
        let selectedNotes = selection.isEmpty ? [] : visible.filter { selection.contains($0.id) }
        let selectedLinks = selection.isEmpty ? [] : NoteLibrary.selectedLinks(in: sorted, noteIDs: selection)
        return LibrarySnapshot(
            sortedNotes: sorted,
            visible: visible,
            visibleIDs: visibleIDs,
            authors: authors,
            selectedNotes: selectedNotes,
            selectedLinks: selectedLinks
        )
    }

    var body: some View {
        let snapshot = makeSnapshot()
        NavigationStack {
            GeometryReader { geometry in
                let count = dynamicTypeSize.isAccessibilitySize && geometry.size.width < 520
                    ? 1
                    : max(2, Int(geometry.size.width / 260))
                let width = (geometry.size.width - 16 - CGFloat(count - 1) * 8) / CGFloat(count)
                let currentViewportHeight = geometry.size.height
                let viewportH = max(currentViewportHeight > 0 ? currentViewportHeight : lastViewportHeight, 600)
                let step = max(120, viewportH * 0.4)
                let approxScrollY = CGFloat(scrollBucket) * step
                let activeRange = (approxScrollY - viewportH * 1.25)...(approxScrollY + viewportH * 2.25)
                let ranges = snapshot.visible.count > 24
                    ? Self.estimatedVerticalRanges(for: snapshot.visible, width: width, columns: count,
                                                   horizontalSpacing: 8, verticalSpacing: 10)
                    : [:]
                let masonryAnimation = XHSDesign.animation(reduceMotion, .spring(response: 0.42, dampingFraction: 0.84))
                let visibleOrderKey = snapshot.visible.map(\.id)
                ScrollView {
                    // Without photo access the feed still shows text notes and
                    // Files-saved media, with a compact prompt above them.
                    if !model.authorized {
                        permissionBanner
                    }
                    ZStack(alignment: .top) {
                        MasonryLayout(columns: count, horizontalSpacing: 8, verticalSpacing: 10) {
                            ForEach(snapshot.visible) { note in
                                let isNearViewport = snapshot.visible.count <= 24 || (ranges[note.id]?.overlaps(activeRange) ?? true)
                                NoteFeedCard(note: note, width: width,
                                             selected: selection.contains(note.id),
                                             isSelecting: isSelecting, liked: coordinator.likedNotes.contains(note.id),
                                             loading: presentation.loadingIdentifier == note.cover?.id,
                                             previewRevision: coordinator.archiveRevision,
                                             isNearViewport: isNearViewport,
                                             namespace: previewTransition,
                                             heroGeometry: feedGeometry,
                                             onOpen: { if isSelecting { toggle(note) } else { open(note) } },
                                             onLike: {
                                                 withAnimation(masonryAnimation) {
                                                     coordinator.toggleLike(noteID: note.id)
                                                 }
                                             })
                                    .task(id: isNearViewport ? note.id : "") {
                                        guard isNearViewport else { return }
                                        await repairAuthor(note)
                                    }
                                    .contextMenu {
                                        Button { open(note) } label: { Label(L10n.text("library.open"), systemImage: "arrow.up.left.and.arrow.down.right") }
                                        Button {
                                            withAnimation(XHSDesign.animation(reduceMotion)) {
                                                isSelecting = true
                                                selection.insert(note.id)
                                            }
                                            AppFeedback.play(.selection)
                                        } label: {
                                            Label(L10n.text("library.select"), systemImage: "checkmark.circle")
                                        }
                                        let liked = coordinator.likedNotes.contains(note.id)
                                        Button {
                                            withAnimation(masonryAnimation) {
                                                coordinator.toggleLike(noteID: note.id)
                                            }
                                        } label: {
                                            Label(L10n.text(liked ? "feed.bookmark.remove" : "feed.bookmark"),
                                                  systemImage: liked ? "heart.slash" : "heart")
                                        }
                                        Button { exportNotes([note]) } label: { Label(L10n.text("library.notes.share"), systemImage: "square.and.arrow.up") }
                                        if let authorKey = note.authorKey {
                                            Button {
                                                remarkText = coordinator.remark(for: authorKey) ?? ""
                                                authorToRemark = AuthorTarget(id: authorKey, name: note.author)
                                            } label: {
                                                Label(L10n.text("library.author.remark"), systemImage: "pencil")
                                            }
                                        }
                                        Menu {
                                            ForEach(coordinator.collections) { collection in
                                                Button {
                                                    let ids: Set<String> = [note.id]
                                                    let inside = coordinator.collection(collection.id)?.noteIDs.contains(note.id) ?? false
                                                    withAnimation(masonryAnimation) {
                                                        coordinator.setMembership(ids, in: collection.id, included: !inside)
                                                    }
                                                } label: {
                                                    Label("\((coordinator.collection(collection.id)?.noteIDs.contains(note.id) ?? false) ? "✓ " : "")  \(collection.name)",
                                                          systemImage: "folder")
                                                }
                                            }
                                            Button { newCollectionName = ""; showsNewCollection = true } label: {
                                                Label(L10n.text("library.collection.new"), systemImage: "plus")
                                            }
                                        } label: {
                                            Label(L10n.text("library.collection.add"), systemImage: "folder.badge.plus")
                                        }
                                        if let collectionFilter,
                                           let collection = coordinator.collection(collectionFilter) {
                                            Button(role: .destructive) {
                                                withAnimation(masonryAnimation) {
                                                    coordinator.setMembership([note.id], in: collection.id, included: false)
                                                }
                                            } label: {
                                                Label(L10n.text("library.collection.delete"), systemImage: "folder.badge.minus")
                                            }
                                        }
                                        if coordinator.note(forKey: note.id)?.archivePaths.isEmpty == false {
                                            Button {
                                                reauthorizeNote = note.id
                                                showsArchivePicker = true
                                            } label: {
                                                Label(L10n.text("library.archive.reauthorize"), systemImage: "folder.badge.gearshape")
                                            }
                                        }
                                        Button(role: .destructive) { confirmNoteDeletion([note.id]) } label: {
                                            Label(L10n.text("library.notes.delete"), systemImage: "trash")
                                        }
                                    }
                                    .transition(MasonryCardTransition(reduceMotion: reduceMotion))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                        .onGeometryChange(for: Int.self) { proxy in
                            let minY = proxy.frame(in: .named("feed-scroll")).minY
                            let scrollOffset = max(0, -minY)
                            return Int((scrollOffset / step).rounded(.down))
                        } action: { newBucket in
                            if scrollBucket != newBucket { scrollBucket = newBucket }
                            if currentViewportHeight > 0, abs(lastViewportHeight - currentViewportHeight) > 1 {
                                lastViewportHeight = currentViewportHeight
                            }
                        }

                        if snapshot.visible.isEmpty {
                            GlassEmptyState(
                                title: search.isEmpty ? L10n.text(scope == 1 ? "feed.bookmarks.empty" : "library.empty")
                                                      : L10n.text("feed.search.empty"),
                                systemImage: !search.isEmpty ? "magnifyingglass" : (scope == 1 ? "heart" : "photo.on.rectangle.angled")
                            )
                            .padding(.top, model.authorized ? 64 : 24)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                    .animation(masonryAnimation, value: visibleOrderKey)
                }
                .coordinateSpace(name: "feed-scroll")
                .accessibilityIdentifier("library-note-feed")
                .xhsScrollEdgeEffectHiddenTop()
                .background {
                    ZStack {
                        GlassBackdrop(color: .coral, intensity: 0.75)
                        Color.clear
                            .modifier(NoteHeroFrame(geometry: feedGeometry, role: "scroll", id: "feed"))
                    }
                    .ignoresSafeArea(edges: [.top, .bottom])
                }
            }
            .navigationTitle(L10n.text("tab.library"))
            .toolbar(.hidden, for: .navigationBar)
            .xhsSafeAreaBar(edge: .top, spacing: 0) {
                feedHeaderBar(snapshot: snapshot, bindFocus: true)
                    .opacity(feedGeometry.concealingHeader ? 0 : 1)
                    .animation(nil, value: feedGeometry.concealingHeader)
            }
            .xhsSafeAreaBar(edge: .bottom, spacing: 0) {
                if isSelecting {
                    selectionBar(snapshot: snapshot)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .task(id: identifiers) { await model.load(legacyIdentifiers: identifiers) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await model.load(legacyIdentifiers: identifiers) }
            }
            .onChange(of: snapshot.visibleIDs) { _, ids in
                selection.formIntersection(ids)
                feedGeometry.pruneCards(keeping: ids)
            }
            .background {
                let currentOpened = snapshot.sortedNotes.first(where: { $0.id == openedNote?.id }) ?? openedNote
                NoteHeroPresentation(item: $presentation.selection, card: true, source: feedGeometry, destination: readerGeometry,
                                     preview: { $0.id.hasPrefix("text:") ? nil : $0.image },
                                     foregroundHeader: { AnyView(feedHeaderBar(snapshot: snapshot, bindFocus: false)) },
                                     cardFooter: currentOpened.map { note in
                                         {
                                             AnyView(
                                                 NoteFeedCardFooter(
                                                     author: note.author,
                                                     avatarURL: note.avatarURL,
                                                     liked: coordinator.likedNotes.contains(note.id),
                                                     isSelecting: isSelecting
                                                 )
                                             )
                                         }
                                     },
                                     contentRevision: AnyHashable(currentOpened)) { selected, close in
                    if let note = currentOpened {
                        NoteReaderView(note: note, initialImage: selected.image, coordinator: coordinator,
                                       namespace: previewTransition, heroGeometry: readerGeometry, onClose: close,
                                       onDelete: { ids in try await delete(ids, fromNoteID: note.id) },
                                       onCopy: coordinator.copyToClipboard,
                                       onTopic: { topic in
                                           withAnimation(XHSDesign.animation(reduceMotion)) {
                                               search = topic; showsSearch = true; scope = 0; filter = 0
                                           }
                                       })
                    }
                }
            }
            .onChange(of: presentation.errorMessage) { _, message in
                if let message { errorMessage = message; presentation.errorMessage = nil }
            }
            .onDisappear { presentation.cancel() }
            .alert(showsDeletion ? L10n.format("library.delete.title", deletion.count) : L10n.text("common.notice"),
                   isPresented: Binding(get: { showsDeletion || errorMessage != nil }, set: {
                       if !$0 { showsDeletion = false; errorMessage = nil }
                   })) {
                if showsDeletion {
                    Button(L10n.text("library.delete.confirm"), role: .destructive) {
                        let ids = deletion
                        busy = true
                        Task {
                            defer { busy = false }
                            do { try await delete(ids); AppFeedback.play(.success) }
                            catch { if !isPhotosCancellation(error) { errorMessage = error.localizedDescription; AppFeedback.play(.error) } }
                        }
                    }
                    Button(L10n.text("common.cancel"), role: .cancel) {}
                } else { Button(L10n.text("common.ok"), role: .cancel) {} }
            } message: { Text(showsDeletion ? L10n.text("library.delete.message") : errorMessage ?? "") }
            .fileImporter(isPresented: $showsArchivePicker, allowedContentTypes: [.folder]) { result in
                guard let noteID = reauthorizeNote else { return }
                reauthorizeNote = nil
                Task {
                    do {
                        let url = try result.get()
                        try await coordinator.reauthorizeNoteArchive(noteID, directory: url)
                    } catch let error as CocoaError where error.code == .userCancelled {
                        // Cancelling the directory picker leaves the grant intact.
                    } catch { errorMessage = error.localizedDescription; AppFeedback.play(.error) }
                }
            }
            .confirmationDialog(L10n.format("library.notes.delete_count", notesToDelete.count),
                                isPresented: $showsNoteDeletion, titleVisibility: .visible) {
                Button(L10n.text("library.notes.delete_keep_media"), role: .destructive) {
                    deleteSelectedNotes(deleteMedia: false)
                }
                Button(L10n.text("library.notes.delete_with_media"), role: .destructive) {
                    deleteSelectedNotes(deleteMedia: true)
                }
                Button(L10n.text("common.cancel"), role: .cancel) { notesToDelete.removeAll() }
            } message: { Text(L10n.text("library.notes.delete_message")) }
            .sheet(item: $share, onDismiss: {
                if let shareDirectory { try? FileManager.default.removeItem(at: shareDirectory) }
                shareDirectory = nil
            }) { MediaShareSheet(urls: $0.urls) }
            .alert(L10n.text("library.collection.new"), isPresented: $showsNewCollection) {
                TextField(L10n.text("library.collection.name"), text: $newCollectionName)
                Button(L10n.text("common.cancel"), role: .cancel) {}
                Button(L10n.text("common.done")) {
                    if let collection = coordinator.createCollection(named: newCollectionName) {
                        collectionFilter = collection.id
                    }
                }
            }
            .alert(L10n.text("library.collection.rename"), isPresented: Binding(
                get: { collectionToRename != nil },
                set: { if !$0 { collectionToRename = nil } }
            )) {
                TextField(L10n.text("library.collection.name"), text: $renameText)
                Button(L10n.text("common.cancel"), role: .cancel) { collectionToRename = nil }
                Button(L10n.text("common.done")) {
                    if let collection = collectionToRename {
                        coordinator.renameCollection(collection.id, to: renameText)
                    }
                    collectionToRename = nil
                }
            }
            .confirmationDialog(L10n.text("library.collection.delete"), isPresented: Binding(
                get: { collectionToDelete != nil },
                set: { if !$0 { collectionToDelete = nil } }
            ), titleVisibility: .visible) {
                Button(L10n.text("library.collection.delete"), role: .destructive) {
                    if let collection = collectionToDelete {
                        coordinator.deleteCollection(collection.id)
                        if collectionFilter == collection.id { collectionFilter = nil }
                    }
                    collectionToDelete = nil
                }
                Button(L10n.text("common.cancel"), role: .cancel) { collectionToDelete = nil }
            } message: {
                Text(L10n.text("library.collection.delete.message"))
            }
            .alert(L10n.text("library.author.remark"), isPresented: Binding(
                get: { authorToRemark != nil },
                set: { if !$0 { authorToRemark = nil } }
            )) {
                TextField(L10n.text("library.author.remark"), text: $remarkText)
                Button(L10n.text("common.cancel"), role: .cancel) { authorToRemark = nil }
                Button(L10n.text("common.done")) {
                    if let target = authorToRemark {
                        coordinator.setRemark(remarkText, for: target.id)
                    }
                    authorToRemark = nil
                }
            } message: {
                Text(L10n.text("library.author.remark.hint"))
            }
            .disabled(busy)
            .tint(.coral)
        }
    }

    private func feedHeaderBar(snapshot: LibrarySnapshot, bindFocus: Bool) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                    if isSelecting {
                        Button {
                            if snapshot.visibleIDs.isSubset(of: selection) { selection.subtract(snapshot.visibleIDs) } else { selection.formUnion(snapshot.visibleIDs) }
                            AppFeedback.play(.selection)
                        } label: {
                            Text(L10n.text(snapshot.visibleIDs.isSubset(of: selection) ? "library.deselect_all" : "library.select_all"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 44)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .xhsGlass(interactive: true, in: Capsule())
                        .accessibilityIdentifier("library-select-all")
                        .disabled(snapshot.visibleIDs.isEmpty)
                    } else {
                        feedMenu(authors: snapshot.authors)
                    }
                    Spacer(minLength: 0)
                    if !isSelecting {
                        GlassSegmentedScope(items: [
                            GlassChipItem(value: 0, title: L10n.text("feed.discover"), accessibilityID: "feed-discover"),
                            GlassChipItem(value: 1, title: L10n.text("feed.bookmarks"), accessibilityID: "feed-bookmarks")
                        ], selection: $scope)
                        Spacer(minLength: 0)
                    }
                    if isSelecting {
                        Button {
                            withAnimation(XHSDesign.animation(reduceMotion)) { isSelecting = false; selection.removeAll() }
                            AppFeedback.play(.selection)
                        } label: {
                            Text(L10n.text("common.done"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 44)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .xhsGlass(tint: .coral, prominent: true, interactive: true, in: Capsule())
                        .accessibilityIdentifier("library-select-done")
                    } else {
                        Button {
                            AppFeedback.play(.navigation)
                            let next = !showsSearch
                            withAnimation(XHSDesign.animation(reduceMotion)) { showsSearch = next }
                            if !next {
                                search = ""
                                searchFocused = false
                            } else {
                                Task { @MainActor in searchFocused = true }
                            }
                        } label: {
                            Image(systemName: showsSearch ? "xmark" : "magnifyingglass")
                                .font(.system(size: 18, weight: .medium))
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .xhsGlass(interactive: true, in: Circle())
                        .accessibilityLabel(L10n.text("library.search"))
                        .accessibilityIdentifier("feed-search")
                    }
                }
                .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.top, 4)

            if showsSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    if bindFocus {
                        TextField(L10n.text("library.search"), text: $search)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($searchFocused)
                            .submitLabel(.search).accessibilityIdentifier("feed-search-field")
                    } else {
                        TextField(L10n.text("library.search"), text: $search)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.search)
                    }
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.text("feed.search.clear"))
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .xhsGlass(interactive: true, in: Capsule())
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .clipped()
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }

            GlassChipBar(items: (0..<4).map { index in
                GlassChipItem(value: index,
                              title: index == 3 ? L10n.text("note.type.live_photo")
                                                : L10n.text(["filter.all", "note.type.image", "note.type.video"][index]),
                              accessibilityID: "feed-filter-\(index)")
            }, selection: $filter, horizontalPadding: 12)

            if authorFilter != nil || collectionFilter != nil {
                activeFilterTokens(authors: snapshot.authors)
                    .clipped()
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            if busy { ProgressView().padding(4) }
        }
        .padding(.bottom, 8)
        .modifier(OptionalNoteHeroFrame(enabled: bindFocus, geometry: feedGeometry, role: "header", id: "feed"))
        .background {
            Group {
                if reduceTransparency {
                    Color(uiColor: .systemBackground)
                } else {
                    GlassBackdrop(color: .coral, intensity: 0.75)
                        .mask {
                            LinearGradient(stops: [
                                .init(color: .white.opacity(0.95), location: 0.0),
                                .init(color: .white.opacity(0.76), location: 0.44),
                                .init(color: .white.opacity(0.28), location: 0.78),
                                .init(color: .clear, location: 1.0)
                            ], startPoint: .top, endPoint: .bottom)
                        }
                }
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
        .animation(XHSDesign.animation(reduceMotion), value: authorFilter)
        .animation(XHSDesign.animation(reduceMotion), value: collectionFilter)
        .animation(XHSDesign.animation(reduceMotion), value: isSelecting)
        .selectionFeedback(scope)
        .selectionFeedback(filter)
        .selectionFeedback(preferences.sortOrder)
    }

    /// Author and collection filters live in the menu; once chosen they show
    /// here as removable tokens, so a narrowed feed never looks mysteriously
    /// empty.
    private func activeFilterTokens(authors: [(key: String, name: String, count: Int)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let authorFilter {
                    filterToken(authors.first { $0.key == authorFilter }?.name ?? L10n.text("library.authors"),
                                systemImage: "person.fill") { self.authorFilter = nil }
                        .accessibilityIdentifier("feed-author-filter-token")
                }
                if let collectionFilter {
                    filterToken(coordinator.collection(collectionFilter)?.name ?? L10n.text("library.collections"),
                                systemImage: "folder.fill") { self.collectionFilter = nil }
                        .accessibilityIdentifier("feed-collection-filter-token")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func filterToken(_ title: String, systemImage: String, clear: @escaping () -> Void) -> some View {
        Button {
            withAnimation(XHSDesign.animation(reduceMotion)) { clear() }
            AppFeedback.play(.selection)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.caption)
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(.caption2.weight(.bold)).opacity(0.7)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.coral)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .xhsGlass(tint: .coral.opacity(0.14), prominent: false, interactive: true, in: Capsule())
        .accessibilityHint(L10n.text("feed.filter.clear"))
    }

    private func feedMenu(authors: [(key: String, name: String, count: Int)]) -> some View {
        Menu {
            Button {
                withAnimation(XHSDesign.animation(reduceMotion)) { isSelecting = true }
                AppFeedback.play(.selection)
            } label: {
                Label(L10n.text("library.select"), systemImage: "checkmark.circle")
            }
            .accessibilityIdentifier("library-enter-selection")
            Divider()
            Picker(L10n.text("library.sort"), selection: $preferences.sortOrder.animation(XHSDesign.animation(reduceMotion, .spring(response: 0.42, dampingFraction: 0.84)))) {
                ForEach(NoteSortOrder.allCases) { order in
                    Text(L10n.text(order.localizationKey)).tag(order)
                }
            }
            Menu {
                Button {
                    guard authorFilter != nil else { return }
                    withAnimation(XHSDesign.animation(reduceMotion, .spring(response: 0.42, dampingFraction: 0.84))) {
                        authorFilter = nil
                    }
                    AppFeedback.play(.selection)
                } label: {
                    Label(L10n.text("library.filter.all"), systemImage: authorFilter == nil ? "checkmark" : "")
                }
                ForEach(authors, id: \.key) { author in
                    Button {
                        guard authorFilter != author.key else { return }
                        withAnimation(XHSDesign.animation(reduceMotion, .spring(response: 0.42, dampingFraction: 0.84))) {
                            authorFilter = author.key
                        }
                        AppFeedback.play(.selection)
                    } label: {
                        Label("\(author.name) (\(author.count))",
                              systemImage: authorFilter == author.key ? "checkmark" : "person")
                    }
                }
            } label: {
                Label(L10n.text("library.authors"), systemImage: "person.2")
            }
            Menu {
                Button {
                    guard collectionFilter != nil else { return }
                    withAnimation(XHSDesign.animation(reduceMotion, .spring(response: 0.42, dampingFraction: 0.84))) {
                        collectionFilter = nil
                    }
                    AppFeedback.play(.selection)
                } label: {
                    Label(L10n.text("library.filter.all"), systemImage: collectionFilter == nil ? "checkmark" : "")
                }
                ForEach(coordinator.collections) { collection in
                    Button {
                        guard collectionFilter != collection.id else { return }
                        withAnimation(XHSDesign.animation(reduceMotion, .spring(response: 0.42, dampingFraction: 0.84))) {
                            collectionFilter = collection.id
                        }
                        AppFeedback.play(.selection)
                    } label: {
                        Label("\(collection.name) (\(collection.noteIDs.count))",
                              systemImage: collectionFilter == collection.id ? "checkmark" : "folder")
                    }
                }
                Divider()
                Button { newCollectionName = ""; showsNewCollection = true } label: {
                    Label(L10n.text("library.collection.new"), systemImage: "plus")
                }
            } label: {
                Label(L10n.text("library.collections"), systemImage: "folder")
            }
        } label: {
            Image(systemName: authorFilter != nil || collectionFilter != nil
                  ? "line.3.horizontal.decrease" : "line.3.horizontal")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(authorFilter != nil || collectionFilter != nil ? Color.coral : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .xhsGlass(in: Circle())
        .accessibilityLabel(L10n.text("library.select"))
        .accessibilityIdentifier("library-select")
    }

    /// Floating glass selection toolbar: the count on the left, actions grouped
    /// in one capsule on the right, both above the system tab bar.
    private func selectionBar(snapshot: LibrarySnapshot) -> some View {
        HStack(spacing: 10) {
                Text(L10n.format("library.notes.selection_count", selection.count))
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText(value: Double(selection.count)))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 50)
                    .xhsGlass(in: Capsule())
                    .accessibilityIdentifier("library-selection-count")
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    Menu {
                        Button {
                            coordinator.copyToClipboard(snapshot.selectedLinks.joined(separator: "\n"))
                            errorMessage = L10n.format("library.links.copied", snapshot.selectedLinks.count)
                        } label: {
                            Label(L10n.format("library.links.copy_selected", snapshot.selectedLinks.count),
                                  systemImage: "link")
                        }
                        .disabled(snapshot.selectedLinks.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.primary)
                            .frame(width: 46, height: 46)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("library.more"))
                    .accessibilityIdentifier("library-selection-more")
                    Button { exportNotes(snapshot.selectedNotes) } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.primary)
                            .frame(width: 46, height: 46)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("library.notes.share"))
                    .accessibilityIdentifier("library-share")
                    Button(role: .destructive) { confirmNoteDeletion(selection) } label: {
                        Image(systemName: "trash").frame(width: 46, height: 46).contentShape(Circle())
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("common.delete"))
                    .accessibilityIdentifier("library-delete")
                }
                .font(.system(size: 18, weight: .medium))
                .padding(.horizontal, 4)
                .xhsGlass(in: Capsule())
            }
        .disabled(selection.isEmpty || busy)
        .opacity(selection.isEmpty ? 0.85 : 1)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .xhsBarBackdrop(edge: .bottom)
    }

    /// A compact banner instead of a full-screen block: text-only and Files notes
    /// stay usable without photo permission.
    private var permissionBanner: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "photo.badge.exclamationmark", color: .orange, size: 34)
            Text(L10n.text("library.permission.body"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status == .denied || status == .restricted {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                } else { Task { await model.load(legacyIdentifiers: identifiers, requestPermission: true) } }
            } label: {
                Text(L10n.text("library.permission.action"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .xhsGlass(tint: .coral, prominent: true, interactive: true, in: Capsule())
        }
        .padding(12)
        .xhsGlass(tint: .orange.opacity(0.08), prominent: false, interactive: false, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var permissionCard: some View {
        ContentUnavailableView {
            Label(L10n.text("library.permission.title"), systemImage: "photo.badge.checkmark")
        } description: { Text(L10n.text("library.permission.body")) } actions: {
            Button(L10n.text("library.permission.action")) {
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status == .denied || status == .restricted {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                } else { Task { await model.load(legacyIdentifiers: identifiers, requestPermission: true) } }
            }.buttonStyle(.borderedProminent)
        }
    }

    /// Opening must work for every note, including text-only ones. A note with a
    /// cover goes through the media presentation so the hero transition runs; a
    /// note without one opens the reader directly with a stand-in first frame.
    /// Notes are keyed by identity now, so the repair entry point takes a note
    /// key instead of a task UUID. The guard must use the real author state:
    /// `authorKey` falls back to the "author unknown" placeholder and would
    /// always look populated.
    private func repairAuthor(_ note: LibraryNote) async {
        guard !note.hasKnownAuthor else { return }
        await coordinator.restoreMissingAuthor(noteKey: note.id)
    }

    private func open(_ note: LibraryNote) {
        openedNote = note
        feedGeometry.selectedID = note.id
        feedGeometry.title = note.title
        feedGeometry.coverRatio = note.coverRatio
        readerGeometry.selectedID = note.id
        guard let cover = note.cover else {
            openTextOnly(note)
            return
        }
        presentation.open(cover.id, identifiers: note.identifiers)
    }

    private func openTextOnly(_ note: LibraryNote) {
        AppFeedback.play(.navigation)
        presentation.selection = MediaViewerSelection(id: "text:" + note.id, identifiers: [], image: UIImage())
    }
    private func toggle(_ note: LibraryNote) {
        if !selection.insert(note.id).inserted { selection.remove(note.id) }
        AppFeedback.play(.selection)
    }

    private func confirmNoteDeletion(_ ids: Set<String>) {
        notesToDelete = ids
        showsNoteDeletion = true
        AppFeedback.play(.warning)
    }

    private func deleteSelectedNotes(deleteMedia: Bool) {
        let ids = notesToDelete
        let all = NoteLibrary.notes(stored: coordinator.notes,
                                    media: model.assets.map(LibraryMedia.init),
                                    hiddenMediaIDs: coordinator.hiddenMediaIDs)
        let standalone = all.filter { ids.contains($0.id) && coordinator.note(forKey: $0.id) == nil }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await coordinator.deleteNotes(ids, deleteMedia: deleteMedia,
                                                  additionalMedia: Set(standalone.flatMap(\.identifiers)))
                selection.subtract(ids)
                await model.load(legacyIdentifiers: identifiers)
            } catch { if !isPhotosCancellation(error) { errorMessage = error.localizedDescription; AppFeedback.play(.error) } }
        }
    }

    private func exportNotes(_ notes: [LibraryNote]) {
        guard !notes.isEmpty else { return }
        busy = true
        AppFeedback.play(.navigation)
        Task {
            defer { busy = false }
            do {
                let files = try await MediaExporter.shared.export(notes: notes)
                shareDirectory = files.directory
                share = files
            } catch { errorMessage = error.localizedDescription; AppFeedback.play(.error) }
        }
    }
    private func confirmDelete(_ ids: Set<String>) { deletion = ids; showsDeletion = true; AppFeedback.play(.warning) }
    private func delete(_ ids: Set<String>, fromNoteID: String? = nil) async throws {
        do {
            try await coordinator.deleteMedia(ids, fromNoteID: fromNoteID)
        } catch {
            await model.load(legacyIdentifiers: identifiers)
            throw error
        }
        await model.load(legacyIdentifiers: identifiers)
    }

    private static func estimatedVerticalRanges(
        for notes: [LibraryNote],
        width: CGFloat,
        columns: Int,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat
    ) -> [String: ClosedRange<CGFloat>] {
        let count = max(1, columns)
        var columnHeights = Array(repeating: CGFloat.zero, count: count)
        var ranges: [String: ClosedRange<CGFloat>] = [:]
        ranges.reserveCapacity(notes.count)
        let safeWidth = max(1, width)
        for note in notes {
            let column = columnHeights.indices.min(by: { columnHeights[$0] < columnHeights[$1] }) ?? 0
            let top = columnHeights[column]
            let estimatedHeight = safeWidth / note.coverRatio + (note.title.isEmpty ? 48 : 92)
            let bottom = top + estimatedHeight
            ranges[note.id] = top...bottom
            columnHeights[column] = bottom + verticalSpacing
        }
        return ranges
    }
    private func export(_ ids: [String]) {
        busy = true; AppFeedback.play(.navigation)
        Task {
            defer { busy = false }
            do {
                let files = try await MediaExporter.shared.export(identifiers: ids)
                shareDirectory = files.directory; share = files
            } catch { if !isPhotosCancellation(error) { errorMessage = error.localizedDescription; AppFeedback.play(.error) } }
        }
    }
}

/// Single-container shortest-column-first masonry layout. Keeping every visible
/// card in one `ForEach` lets SwiftUI preserve view identity (`note.id`) and
/// smoothly spring-interpolate cross-column moves across Discover/Bookmarks,
/// filters, and sort changes.
private struct MasonryLayout: Layout {
    var columns: Int
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 10

    struct Cache {
        var width: CGFloat = -1
        var columnCount: Int = 0
        var frames: [CGRect] = []
        var totalHeight: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.width = -1
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = max(0, proposal.width ?? 320)
        computeLayout(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: cache.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        computeLayout(width: bounds.width, subviews: subviews, cache: &cache)
        for (index, subview) in subviews.enumerated() where index < cache.frames.count {
            let frame = cache.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func computeLayout(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        let count = max(1, columns)
        if cache.width == width, cache.columnCount == count, cache.frames.count == subviews.count {
            return
        }
        cache.width = width
        cache.columnCount = count
        cache.frames.removeAll(keepingCapacity: true)
        guard !subviews.isEmpty, width > 0 else {
            cache.totalHeight = 0
            return
        }
        let columnWidth = max(1, (width - CGFloat(count - 1) * horizontalSpacing) / CGFloat(count))
        var columnHeights = Array(repeating: CGFloat.zero, count: count)
        let itemProposal = ProposedViewSize(width: columnWidth, height: nil)
        for subview in subviews {
            let measured = subview.sizeThatFits(itemProposal)
            let column = columnHeights.indices.min(by: { columnHeights[$0] < columnHeights[$1] }) ?? 0
            let x = CGFloat(column) * (columnWidth + horizontalSpacing)
            let y = columnHeights[column]
            cache.frames.append(CGRect(x: x, y: y, width: columnWidth, height: measured.height))
            columnHeights[column] = y + measured.height + verticalSpacing
        }
        cache.totalHeight = max(0, (columnHeights.max() ?? 0) - verticalSpacing)
    }
}

/// Asymmetric masonry card transition:
/// - Entering cards glide smoothly upward from below with subtle scale & fade.
/// - Surviving/repositioning cards stay on top (`zIndex(2)`) so cross-column
///   moves never pass underneath departing cards.
/// - Exiting cards scale down gently (`0.92`) and fade out behind (`zIndex(0)`).
private struct MasonryCardTransition: Transition {
    let reduceMotion: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let scale: CGFloat = reduceMotion ? 1 : (phase == .willAppear ? 0.93 : (phase == .didDisappear ? 0.92 : 1))
        let yOffset: CGFloat = (!reduceMotion && phase == .willAppear) ? 84 : 0
        let zOrder: Double = phase == .identity ? 2 : (phase == .willAppear ? 1 : 0)
        return content
            .opacity(phase.isIdentity ? 1 : 0)
            .scaleEffect(scale)
            .offset(y: yOffset)
            .zIndex(zOrder)
    }
}

private struct OptionalNoteHeroFrame: ViewModifier {
    let enabled: Bool
    let geometry: NoteHeroGeometry
    let role: String
    let id: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.modifier(NoteHeroFrame(geometry: geometry, role: role, id: id))
        } else {
            content
        }
    }
}

private extension View {
    func mediaBadge() -> some View {
        font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
    }

    @ViewBuilder
    func xhsScrollEdgeEffectHiddenTop() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }

    @ViewBuilder
    func xhsViewerGlassControl(tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass).tint(tint)
        } else {
            self.buttonStyle(.plain)
                .foregroundStyle(tint)
                .contentShape(Circle())
                .xhsGlass(interactive: true, darkOverlay: true, in: Circle())
        }
    }
}

struct HDRImage: UIViewRepresentable {
    let image: UIImage
    var range: UIImage.DynamicRange = .high

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        view.preferredImageDynamicRange = range
        if view.image !== image { view.image = image }
    }
}

struct MediaViewer: View {
    @State private var identifiers: [String]
    @State private var selected: String
    @State private var zoomTrigger = 0
    @State private var showsDeletion = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var share: MediaShareFiles?
    @State private var shareDirectory: URL?
    private let onDelete: ((Set<String>) async throws -> Void)?
    private let onSelect: ((String) -> Void)?
    private let heroGeometry: NoteHeroGeometry?
    private let onClose: (() -> Void)?
    private let initialIdentifier: String
    private let initialImage: UIImage
    private let transition: Namespace.ID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(identifiers: [String], initialIdentifier: String, initialImage: UIImage,
         transition: Namespace.ID, onDelete: ((Set<String>) async throws -> Void)? = nil,
         onSelect: ((String) -> Void)? = nil, heroGeometry: NoteHeroGeometry? = nil, onClose: (() -> Void)? = nil) {
        _identifiers = State(initialValue: identifiers)
        _selected = State(initialValue: initialIdentifier)
        self.onDelete = onDelete
        self.onSelect = onSelect
        self.heroGeometry = heroGeometry
        self.onClose = onClose
        self.initialIdentifier = initialIdentifier
        self.initialImage = initialImage
        self.transition = transition
    }

    private var asset: PHAsset? {
        guard !selected.hasPrefix("file:") else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [selected], options: nil).firstObject
    }

    private var isCurrentVideo: Bool {
        if let asset { return asset.mediaType == .video }
        guard selected.hasPrefix("file:") else { return false }
        let paths = selected.dropFirst("file:".count).split(separator: "\n").map(String.init)
        return !paths.isEmpty && paths.allSatisfy { MediaFileValidator.isVideoFile(URL(fileURLWithPath: $0)) }
    }

    private var pageTitle: String { "\((identifiers.firstIndex(of: selected) ?? 0) + 1) / \(identifiers.count)" }

    private var pages: some View {
        TabView(selection: $selected) {
            ForEach(identifiers, id: \.self) { id in
                PhotosMediaView(identifier: id, initialImage: id == initialIdentifier ? initialImage : nil,
                                active: selected == id, zoomTrigger: selected == id ? zoomTrigger : 0,
                                backgroundColor: heroGeometry == nil ? .black : .clear,
                                heroGeometry: heroGeometry).tag(id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    var body: some View {
        Group {
            if heroGeometry != nil { floatingViewer }
            else { systemViewer }
        }
        .disabled(busy)
        .onChange(of: selected) { _, id in zoomTrigger = 0; heroGeometry?.selectedID = id; onSelect?(id); AppFeedback.play(.selection) }
        .alert(showsDeletion ? L10n.format("library.delete.title", 1) : L10n.text("common.notice"),
               isPresented: Binding(get: { showsDeletion || errorMessage != nil }, set: {
                   if !$0 { showsDeletion = false; errorMessage = nil }
               })) {
            if showsDeletion {
                Button(L10n.text("library.delete.confirm"), role: .destructive) { deleteCurrent() }
                Button(L10n.text("common.cancel"), role: .cancel) {}
            } else { Button(L10n.text("common.ok"), role: .cancel) {} }
        } message: { Text(showsDeletion ? L10n.text("library.delete.message") : errorMessage ?? "") }
        .sheet(item: $share, onDismiss: {
            if let shareDirectory { try? FileManager.default.removeItem(at: shareDirectory) }
            shareDirectory = nil
        }) { MediaShareSheet(urls: $0.urls) }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .modifier(OptionalSystemMediaZoom(enabled: heroGeometry == nil, id: selected, namespace: transition))
    }

    private var floatingViewer: some View {
        let video = isCurrentVideo
        return pages
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                XHSGlassContainer(spacing: 12) {
                    HStack(spacing: 8) {
                        closeControl
                        Spacer(minLength: 8)
                        Text(pageTitle)
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .xhsGlass(tint: .black.opacity(0.28), prominent: false, interactive: false, darkOverlay: true, in: Capsule())
                            .accessibilityIdentifier("viewer-page-count")
                        Spacer(minLength: 8)
                        if video {
                            HStack(spacing: 8) {
                                if busy { ProgressView().tint(.white) }
                                shareControl
                                if onDelete != nil { deleteControl }
                            }
                        } else {
                            Color.clear.frame(width: 48, height: 48)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12)
                .animation(XHSDesign.animation(reduceMotion, XHSDesign.snappy), value: selected)
            }
            .overlay(alignment: .bottom) {
                if !video {
                    XHSGlassContainer(spacing: 12) {
                        HStack {
                            shareControl
                            Spacer()
                            zoomControl
                            Spacer()
                            if busy { ProgressView().tint(.white) }
                            if onDelete != nil { deleteControl }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
            .background(.clear)
    }

    private var closeControl: some View {
        Button { AppFeedback.play(.navigation); close() } label: {
            Image(systemName: "xmark").font(.system(size: 19)).frame(width: 48, height: 48)
        }.xhsViewerGlassControl(tint: .white).accessibilityLabel(L10n.text("common.done")).accessibilityIdentifier("viewer-close")
    }
    private var shareControl: some View {
        Button { export() } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 21)).frame(width: 48, height: 48)
        }.xhsViewerGlassControl(tint: .white).accessibilityLabel(L10n.text("library.share")).accessibilityIdentifier("viewer-share")
    }
    private var zoomControl: some View {
        Button { zoomTrigger += 1 } label: {
            Image(systemName: "plus.magnifyingglass").font(.system(size: 21)).frame(width: 48, height: 48)
        }.xhsViewerGlassControl(tint: .white).accessibilityLabel(L10n.text("viewer.zoom")).accessibilityIdentifier("viewer-zoom")
    }
    private var deleteControl: some View {
        Button(role: .destructive) { AppFeedback.play(.warning); showsDeletion = true } label: {
            Image(systemName: "trash").font(.system(size: 21)).frame(width: 48, height: 48)
        }.xhsViewerGlassControl(tint: .red).accessibilityLabel(L10n.text("common.delete")).accessibilityIdentifier("viewer-delete")
    }

    @ViewBuilder
    private var systemViewerBottomItems: some View {
        shareControl
        Spacer()
        if !isCurrentVideo { zoomControl; Spacer() }
        if busy { ProgressView().tint(.white) }
        if onDelete != nil { deleteControl }
    }

    @ViewBuilder
    private func systemViewerToolbar<Content: View>(for content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) { closeControl }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .bottomBar) {
                    systemViewerBottomItems
                }
                .sharedBackgroundVisibility(.hidden)
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { AppFeedback.play(.navigation); close() } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(.white)
                    .accessibilityLabel(L10n.text("common.done"))
                    .accessibilityIdentifier("viewer-close")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { export() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(.white)
                    .accessibilityLabel(L10n.text("library.share"))
                    .accessibilityIdentifier("viewer-share")
                    Spacer()
                    if !isCurrentVideo {
                        Button { zoomTrigger += 1 } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .tint(.white)
                        .accessibilityLabel(L10n.text("viewer.zoom"))
                        .accessibilityIdentifier("viewer-zoom")
                        Spacer()
                    }
                    if busy { ProgressView().tint(.white) }
                    if onDelete != nil {
                        Button(role: .destructive) { AppFeedback.play(.warning); showsDeletion = true } label: {
                            Image(systemName: "trash")
                        }
                        .tint(.red)
                        .accessibilityLabel(L10n.text("common.delete"))
                        .accessibilityIdentifier("viewer-delete")
                    }
                }
            }
        }
    }

    private var systemViewer: some View {
        NavigationStack {
            systemViewerToolbar(for:
                pages.background(.black).ignoresSafeArea(edges: .bottom)
                    .navigationTitle(pageTitle).navigationBarTitleDisplayMode(.inline)
            )
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .toolbarBackground(.black, for: .navigationBar, .bottomBar)
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
        }.background(.black)
    }

    private func close() { if let onClose { onClose() } else { dismiss() } }
    private func deleteCurrent() {
        guard let onDelete else { return }
        let id = selected
        let index = identifiers.firstIndex(of: id) ?? 0
        busy = true
        Task {
            defer { busy = false }
            do {
                try await onDelete([id])
                identifiers.removeAll { $0 == id }
                AppFeedback.play(.success)
                if identifiers.isEmpty { close() }
                else { selected = identifiers[min(index, identifiers.count - 1)] }
            } catch {
                if !isPhotosCancellation(error) { errorMessage = error.localizedDescription; AppFeedback.play(.error) }
            }
        }
    }

    private func export() {
        busy = true
        AppFeedback.play(.navigation)
        Task {
            defer { busy = false }
            do {
                let files = try await MediaExporter.shared.export(identifiers: [selected])
                shareDirectory = files.directory
                share = files
            } catch { errorMessage = error.localizedDescription; AppFeedback.play(.error) }
        }
    }
}

struct PhotosMediaView: UIViewControllerRepresentable {
    let identifier: String
    let initialImage: UIImage?
    let active: Bool
    let zoomTrigger: Int
    var backgroundColor: UIColor = .black
    var onOpen: (() -> Void)? = nil
    var canvasIdentifier: String = "viewer-zoom-canvas"
    var heroGeometry: NoteHeroGeometry? = nil
    var cardGeometry: NoteHeroGeometry? = nil
    var cardID: String? = nil
    func makeUIViewController(context: Context) -> PhotosMediaController {
        PhotosMediaController(identifier: identifier, initialImage: initialImage, backgroundColor: backgroundColor,
                              onOpen: onOpen, canvasIdentifier: canvasIdentifier, heroGeometry: heroGeometry,
                              cardGeometry: cardGeometry, cardID: cardID)
    }
    func updateUIViewController(_ controller: PhotosMediaController, context: Context) {
        controller.setActive(active)
        controller.updateZoomTrigger(zoomTrigger)
    }
    static func dismantleUIViewController(_ controller: PhotosMediaController, coordinator: ()) { controller.stop() }
}

private final class PhotoZoomScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // At fit size there is nothing to pan. Let the enclosing media pager
        // and the presentation's pull-to-dismiss gesture own one-finger drags.
        if gestureRecognizer === panGestureRecognizer, zoomScale <= minimumZoomScale + 0.01 { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

final class PhotosMediaController: UIViewController, UIScrollViewDelegate, PHLivePhotoViewDelegate {
    private let identifier: String
    private let imageView = UIImageView()
    private let scroll = PhotoZoomScrollView()
    private let canvas = UIView()
    private let liveView = PHLivePhotoView()
    private let playerController = AVPlayerViewController()
    private let message = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var request: PHImageRequestID?
    private var active = false
    private var pixelSize = CGSize(width: 1, height: 1)
    private var lastZoomTrigger = 0
    private var pinchStartScale: CGFloat?
    private let initialImage: UIImage?
    private let backgroundColor: UIColor
    private var controlColor: UIColor { backgroundColor == .black ? .white : .label }
    private var stillRequest: PHImageRequestID?
    private var videoReady: NSKeyValueObservation?
    private var stopped = false
    private var fileLoad: Task<Void, Never>?
    private var fileLease: ArchiveLease?
    private var fileLivePlayer: AVPlayer?
    private var fileLiveLayer: AVPlayerLayer?
    private var fileLiveEnd: NSObjectProtocol?
    private var viewportSize = CGSize.zero
    private var onOpen: (() -> Void)?
    private let canvasIdentifier: String
    private let heroGeometry: NoteHeroGeometry?
    private let cardGeometry: NoteHeroGeometry?
    private let cardID: String?

    init(identifier: String, initialImage: UIImage?, backgroundColor: UIColor, onOpen: (() -> Void)?, canvasIdentifier: String,
         heroGeometry: NoteHeroGeometry?, cardGeometry: NoteHeroGeometry?, cardID: String?) {
        self.identifier = identifier
        self.initialImage = initialImage
        self.backgroundColor = backgroundColor
        self.onOpen = onOpen
        self.canvasIdentifier = canvasIdentifier
        self.heroGeometry = heroGeometry
        self.cardGeometry = cardGeometry
        self.cardID = cardID
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    deinit {
        if let fileLiveEnd { NotificationCenter.default.removeObserver(fileLiveEnd) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = backgroundColor
        view.traitOverrides.imageDynamicRange = .high
        message.textColor = controlColor
        message.numberOfLines = 0
        message.textAlignment = .center
        spinner.color = controlColor
        spinner.startAnimating()
        view.addSubview(message)
        view.addSubview(spinner)
        // A Files-only save has no PHAsset; render the archived file directly so
        // the note's media stays browsable. Video and Live Photo still need their
        // own player, so they are not treated as a plain image.
        if identifier.hasPrefix("file:") {
            configureFileMedia(identifier)
            return
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            fail(); return
        }
        pixelSize = CGSize(width: max(1, asset.pixelWidth), height: max(1, asset.pixelHeight))
        imageView.contentMode = .scaleAspectFit
        imageView.preferredImageDynamicRange = .high
        imageView.image = MediaPreviewImages.shared.image(for: identifier) ?? initialImage
        heroGeometry?.register(imageView, role: "image", id: identifier)
        if active, let cardID { cardGeometry?.register(imageView, role: "image", id: cardID) }
        if imageView.image != nil { spinner.stopAnimating() }
        if asset.mediaType == .image {
            configureZoom()
            canvas.addSubview(imageView)
        } else {
            view.insertSubview(imageView, at: 0)
        }
        if let image = imageView.image,
           image.size.width * image.scale >= pixelSize.width,
           image.size.height * image.scale >= pixelSize.height {
            // Already prepared at the asset's full resolution.
        } else { loadImage(asset) }
        if asset.mediaSubtypes.contains(.photoLive) { loadLivePhoto(asset) }
        else if asset.mediaType == .video { loadVideo(asset) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.superview != nil, viewportSize != view.bounds.size {
            viewportSize = view.bounds.size
            scroll.setZoomScale(1, animated: false)
            scroll.frame = view.bounds
            let w = max(1, pixelSize.width), h = max(1, pixelSize.height)
            let scale = min(scroll.bounds.width / w, scroll.bounds.height / h)
            canvas.frame = CGRect(origin: .zero, size: CGSize(width: w * scale, height: h * scale))
            imageView.frame = canvas.bounds
            liveView.frame = canvas.bounds
            fileLiveLayer?.frame = canvas.bounds
            scroll.contentSize = canvas.bounds.size
            centerCanvas()
        }
        playerController.view.frame = view.bounds
        if scroll.superview == nil {
            let w = max(1, pixelSize.width), h = max(1, pixelSize.height)
            let scale = min(view.bounds.width / w, view.bounds.height / h)
            let fitted = CGSize(width: w * scale, height: h * scale)
            imageView.frame = CGRect(
                x: (view.bounds.width - fitted.width) / 2,
                y: (view.bounds.height - fitted.height) / 2,
                width: fitted.width, height: fitted.height
            )
        }
        message.frame = view.bounds.insetBy(dx: 30, dy: 50)
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if scroll.superview != nil, !view.bounds.isEmpty { centerCanvas() }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if scroll.superview != nil, !view.bounds.isEmpty { centerCanvas() }
    }

    private func registerHeroViews() {
        heroGeometry?.register(imageView, role: "image", id: identifier)
        if playerController.viewIfLoaded?.superview != nil {
            heroGeometry?.register(playerController.view, role: "player", id: identifier)
        }
        if liveView.superview != nil {
            heroGeometry?.register(liveView, role: "live", id: identifier)
        }
        if active, let cardID {
            cardGeometry?.register(imageView, role: "image", id: cardID)
            if playerController.viewIfLoaded?.superview != nil {
                cardGeometry?.register(playerController.view, role: "player", id: cardID)
            }
            if liveView.superview != nil {
                cardGeometry?.register(liveView, role: "live", id: cardID)
            }
        }
    }

    func setActive(_ value: Bool) {
        active = value
        if value { registerHeroViews() }
        if !value { playerController.player?.pause(); stopLivePlayback() }
    }

    func updateZoomTrigger(_ value: Int) {
        guard value != lastZoomTrigger else { return }
        lastZoomTrigger = value
        if value == 0 { scroll.setZoomScale(1, animated: false) }
        else if active { toggleZoom(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)) }
    }

    func stop() {
        stopped = true
        fileLoad?.cancel()
        fileLoad = nil
        stopLivePlayback()
        fileLiveLayer?.player = nil
        fileLivePlayer = nil
        if let fileLiveEnd { NotificationCenter.default.removeObserver(fileLiveEnd) }
        fileLiveEnd = nil
        playerController.player = nil
        fileLease = nil
        onOpen = nil
        if let request { PHImageManager.default().cancelImageRequest(request) }
        if let stillRequest { PHImageManager.default().cancelImageRequest(stillRequest) }
        videoReady = nil
        playerController.player?.pause()
        liveView.stopPlayback()
    }

    private func configureZoom() {
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.delaysContentTouches = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = canvasIdentifier
        scroll.accessibilityValue = "100%"
        scroll.addSubview(canvas)
        view.insertSubview(scroll, at: 0)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        if onOpen != nil {
            let tap = UITapGestureRecognizer(target: self, action: #selector(openMedia))
            tap.require(toFail: doubleTap)
            scroll.addGestureRecognizer(tap)
        }
    }

    private func loadImage(_ asset: PHAsset) {
        let options = PHImageRequestOptions()
        options.preferHDR = true
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        stillRequest = PHImageManager.default().requestImage(
            for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options
        ) { [weak self] image, info in
            Task { @MainActor in
                guard let self, !self.stopped,
                      info?[PHImageResultIsDegradedKey] as? Bool != true,
                      info?[PHImageCancelledKey] as? Bool != true else { return }
                if let image {
                    MediaPreviewImages.shared.insert(image, for: self.identifier)
                    self.imageView.image = image
                    self.spinner.stopAnimating()
                }
                else if info?[PHImageCancelledKey] as? Bool != true { self.fail() }
            }
        }
    }

    /// Files images share the Photos zoom canvas. Paired files stay still until
    /// held; a standalone video uses the standard player controls.
    private func configureFileMedia(_ identifier: String) {
        let prepared = MediaPreviewImages.shared.image(for: identifier) ?? initialImage
        if let prepared, prepared.size.width > 0, prepared.size.height > 0 {
            // Mount the prepared still synchronously so the hero transition
            // reads the exact destination frame on frame 0 instead of falling
            // back to a centered screen box.
            pixelSize = CGSize(width: max(1, prepared.size.width), height: max(1, prepared.size.height))
            imageView.contentMode = .scaleAspectFit
            imageView.preferredImageDynamicRange = .high
            imageView.image = prepared
            configureZoom()
            canvas.addSubview(imageView)
            registerHeroViews()
            spinner.stopAnimating()
            view.setNeedsLayout()
        }
        fileLoad = Task { [weak self] in
            do {
                let lease = try await ArchiveMediaLoader.shared.lease(identifier: identifier)
                let image: UIImage
                if let prepared { image = prepared }
                else { image = try await ArchiveMediaLoader.shared.image(identifier: identifier, thumbnail: false) }
                guard let self, !self.stopped, !Task.isCancelled else { return }
                self.fileLease = lease
                guard !lease.urls.isEmpty else { self.fail(); return }
                self.pixelSize = CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
                if lease.urls.allSatisfy({ MediaFileValidator.isVideoFile($0) }), let video = lease.urls.first {
                    if self.scroll.superview != nil {
                        self.imageView.removeFromSuperview()
                        self.scroll.removeFromSuperview()
                    }
                    self.imageView.image = image
                    self.imageView.contentMode = .scaleAspectFit
                    self.view.insertSubview(self.imageView, at: 0)
                    self.playFileVideo(video)
                    self.registerHeroViews()
                    self.view.setNeedsLayout()
                    return
                }
                self.imageView.contentMode = .scaleAspectFit
                self.imageView.preferredImageDynamicRange = .high
                self.imageView.image = image
                MediaPreviewImages.shared.insert(image, for: identifier)
                if self.scroll.superview == nil {
                    self.configureZoom()
                    self.canvas.addSubview(self.imageView)
                }
                self.viewportSize = .zero
                self.registerHeroViews()
                if let motion = lease.urls.first(where: { MediaFileValidator.isVideoFile($0) }) {
                    self.liveView.isMuted = true
                    let player = AVPlayer(url: motion)
                    player.isMuted = true
                    let layer = AVPlayerLayer(player: player)
                    layer.videoGravity = .resizeAspect
                    layer.isHidden = true
                    self.canvas.layer.addSublayer(layer)
                    self.fileLivePlayer = player
                    self.fileLiveLayer = layer
                    self.fileLiveEnd = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                        object: player.currentItem, queue: .main) { [weak self] _ in
                            Task { @MainActor [weak self] in self?.stopLivePlayback() }
                        }
                    self.configureLiveControls()
                }
                self.spinner.stopAnimating()
                self.view.setNeedsLayout()
            } catch {
                guard let self, !self.stopped, !Task.isCancelled else { return }
                self.spinner.stopAnimating()
                self.message.text = error.localizedDescription
            }
        }
    }

    private func playFileVideo(_ url: URL) {
        addChild(playerController)
        view.insertSubview(playerController.view, at: 0)
        playerController.didMove(toParent: self)
        registerHeroViews()
        view.bringSubviewToFront(imageView)
        view.bringSubviewToFront(spinner)
        videoReady = playerController.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] controller, _ in
            let ready = controller.isReadyForDisplay
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.imageView.isHidden = ready
            }
        }
        playerController.player = AVPlayer(url: url)
        spinner.stopAnimating()
    }

    private func loadVideo(_ asset: PHAsset) {
        addChild(playerController)
        view.insertSubview(playerController.view, at: 0)
        playerController.didMove(toParent: self)
        registerHeroViews()
        // Keep the poster above the player until its first video frame exists.
        view.bringSubviewToFront(imageView)
        view.bringSubviewToFront(spinner)
        videoReady = playerController.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] controller, _ in
            let ready = controller.isReadyForDisplay
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.imageView.isHidden = ready
            }
        }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        request = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                guard let item else { self.fail(); return }
                self.playerController.player = AVPlayer(playerItem: item)
                self.spinner.stopAnimating()
            }
        }
    }

    private func loadLivePhoto(_ asset: PHAsset) {
        liveView.contentMode = .scaleAspectFit
        liveView.isMuted = true
        liveView.backgroundColor = .clear
        liveView.delegate = self
        liveView.isHidden = true
        canvas.addSubview(liveView)
        registerHeroViews()
        // Keep the prepared full-resolution still visible until playback starts.
        // The hidden Live Photo view cannot receive touches, so the zoom canvas
        // owns the long press and reveals it through its playback delegate.
        canvas.bringSubviewToFront(imageView)
        let options = PHLivePhotoRequestOptions()
        options.preferHDR = true
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        request = PHImageManager.default().requestLivePhoto(
            for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options
        ) { [weak self] photo, info in
            Task { @MainActor in
                guard let self, !self.stopped,
                      info?[PHLivePhotoInfoIsDegradedKey] as? Bool != true,
                      info?[PHLivePhotoInfoCancelledKey] as? Bool != true else { return }
                if let photo {
                    self.liveView.livePhoto = photo
                    self.spinner.stopAnimating()
                } else { self.fail() }
            }
        }
        configureLiveControls()
    }

    private final class LiveHintPillLabel: UILabel {
        private let insets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)

        override func drawText(in rect: CGRect) {
            super.drawText(in: rect.inset(by: insets))
        }

        override var intrinsicContentSize: CGSize {
            let size = super.intrinsicContentSize
            return CGSize(width: size.width + insets.left + insets.right,
                          height: size.height + insets.top + insets.bottom)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = bounds.height / 2
        }
    }

    private func configureLiveControls() {
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(playLivePhoto(_:)))
        hold.minimumPressDuration = 0.35
        scroll.addGestureRecognizer(hold)
        let isFloatingViewer = heroGeometry != nil && backgroundColor == .clear
        let isReaderCarousel = !isFloatingViewer && backgroundColor != .black
        let hint = LiveHintPillLabel()
        hint.text = L10n.text("viewer.live.hint")
        hint.accessibilityIdentifier = "media-live-hint"
        hint.textColor = .white
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.56)
        hint.clipsToBounds = true
        hint.layer.cornerCurve = .continuous
        hint.layer.borderWidth = 0.5
        hint.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.adjustsFontForContentSizeCategory = true
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        if isReaderCarousel {
            NSLayoutConstraint.activate([
                hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                hint.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                hint.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -68)
            ])
        } else {
            NSLayoutConstraint.activate([
                hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                          constant: isFloatingViewer ? 68 : 12),
                hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                hint.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                hint.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
            ])
        }
        let sound = UIButton(type: .system)
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        sound.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)
        sound.setImage(UIImage(systemName: "speaker.slash.fill"), for: .normal)
        sound.tintColor = .white
        sound.backgroundColor = UIColor.black.withAlphaComponent(0.56)
        sound.layer.cornerRadius = 18
        sound.layer.cornerCurve = .continuous
        sound.layer.borderWidth = 0.5
        sound.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        sound.accessibilityLabel = L10n.text("viewer.live.sound")
        sound.accessibilityIdentifier = "media-live-sound"
        sound.accessibilityValue = L10n.text("viewer.live.muted")
        sound.addAction(UIAction { [weak self, weak sound] _ in
            guard let self else { return }
            self.liveView.isMuted.toggle()
            self.fileLivePlayer?.isMuted = self.liveView.isMuted
            AppFeedback.play(.selection)
            sound?.accessibilityValue = L10n.text(self.liveView.isMuted ? "viewer.live.muted" : "viewer.live.audible")
            sound?.setImage(UIImage(systemName: self.liveView.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"), for: .normal)
        }, for: .touchUpInside)
        sound.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sound)
        let soundTrailing: CGFloat = isFloatingViewer ? -22 : -16
        let soundBottom: CGFloat = isFloatingViewer ? -76 : (isReaderCarousel ? -64 : -68)
        NSLayoutConstraint.activate([
            sound.widthAnchor.constraint(equalToConstant: 36), sound.heightAnchor.constraint(equalToConstant: 36),
            sound.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: soundTrailing),
            sound.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: soundBottom)
        ])
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func livePhotoView(_ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        liveView.isHidden = false
        imageView.isHidden = true
    }
    func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        imageView.isHidden = false
        liveView.isHidden = true
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerCanvas()
        scroll.accessibilityValue = "\(Int(scroll.zoomScale * 100))%"
    }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        stopLivePlayback()
        if scrollView.pinchGestureRecognizer?.state == .began {
            pinchStartScale = scrollView.zoomScale
            AppFeedback.prepareForGesture()
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        defer { pinchStartScale = nil }
        guard let start = pinchStartScale else { return }
        if (start > scrollView.minimumZoomScale + 0.01 && scale <= scrollView.minimumZoomScale + 0.01)
            || (start < scrollView.maximumZoomScale - 0.01 && scale >= scrollView.maximumZoomScale - 0.01) {
            AppFeedback.play(.boundary)
        }
    }

    private func centerCanvas() {
        // bounds.origin changes while panning and during zoom rubber-banding.
        // Feeding it into contentInset moves the origin again and produces a
        // jump at minimum zoom. Center the canvas in a stable viewport instead.
        var center = CGPoint(x: scroll.bounds.width / 2, y: scroll.bounds.height / 2)
        if heroGeometry != nil, backgroundColor == .clear, let window = view.window {
            // The pager may include an extra bottom safe-area region. Center
            // floating media in the actual screen rather than that region.
            center = view.convert(CGPoint(x: window.bounds.midX, y: window.bounds.midY), from: window)
        }
        canvas.center = CGPoint(x: max(center.x, scroll.contentSize.width / 2),
                                y: max(center.y, scroll.contentSize.height / 2))
    }

    @objc private func zoom(_ gesture: UITapGestureRecognizer) { toggleZoom(at: gesture.location(in: canvas)) }
    @objc private func openMedia() { onOpen?() }

    @objc private func playLivePhoto(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard active, liveView.livePhoto != nil || fileLivePlayer != nil, scroll.zoomScale <= 1.01 else { return }
            AppFeedback.play(.activation)
            if let player = fileLivePlayer {
                player.seek(to: .zero)
                fileLiveLayer?.isHidden = false
                // Keep the still underneath until the first movie frame arrives.
                player.play()
            } else { liveView.startPlayback(with: .full) }
        case .ended, .cancelled, .failed:
            stopLivePlayback()
        default: break
        }
    }

    private func stopLivePlayback() {
        liveView.stopPlayback()
        fileLivePlayer?.pause()
        fileLiveLayer?.isHidden = true
        imageView.isHidden = false
    }

    private func toggleZoom(at point: CGPoint) {
        guard scroll.superview != nil else { return }
        AppFeedback.play(scroll.zoomScale > 1.01 ? .deactivation : .activation)
        stopLivePlayback()
        let animated = !UIAccessibility.isReduceMotionEnabled
        if scroll.zoomScale > 1.01 { scroll.setZoomScale(1, animated: animated) }
        else {
            let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                  width: size.width, height: size.height), animated: animated)
        }
    }
    private func fail() { spinner.stopAnimating(); message.text = L10n.text("viewer.unavailable") }
}
