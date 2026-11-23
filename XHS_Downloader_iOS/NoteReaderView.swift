import SwiftUI
import Photos

struct NoteAuthorAvatar: View {
    let name: String
    let url: URL?
    let size: CGFloat
    @State private var savedImage: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: .tertiarySystemFill))
            if let savedImage {
                Image(uiImage: savedImage).resizable().scaledToFill()
            } else {
                Text(String(name.prefix(1))).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
        .task(id: url) {
            savedImage = nil
            if let url, let data = await AuthorAvatarStore.shared.imageData(for: url), !Task.isCancelled {
                savedImage = UIImage(data: data)
            }
        }
    }
}

struct NoteFeedCard: View {
    let note: LibraryNote
    let width: CGFloat
    let selected: Bool
    let isSelecting: Bool
    let liked: Bool
    let loading: Bool
    let previewRevision: Int
    let namespace: Namespace.ID
    @ObservedObject var heroGeometry: NoteHeroGeometry
    let onOpen: () -> Void
    let onLike: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) private var authorSize: CGFloat = 11
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardIdentifier: String { note.cover?.id ?? note.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    if let cover = note.cover {
                        PhotoAssetThumbnail(localIdentifier: cover.id)
                            .id(previewRevision)
                            .allowsHitTesting(false)
                            .frame(width: width, height: width / note.coverRatio)
                            .clipped()
                            .modifier(NoteHeroFrame(geometry: heroGeometry, role: "image", id: note.id))
                            .overlay(alignment: .topTrailing) {
                                if isSelecting {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 24)).symbolRenderingMode(.palette)
                                        .foregroundStyle(selected ? Color.coral : .white, .white)
                                        .shadow(radius: 2).padding(8)
                                } else if cover.isVideo {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 26, height: 26)
                                        .background(.black.opacity(0.45), in: Circle())
                                        .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
                                        .padding(8)
                                }
                            }
                            .overlay(alignment: .bottomLeading) {
                                if cover.isLive {
                                    Label("LIVE", systemImage: "livephoto")
                                        .font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 4)
                                        .foregroundStyle(.white)
                                        .background(.black.opacity(0.45), in: Capsule())
                                        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                                        .padding(8)
                                }
                            }
                            .overlay {
                                if loading { ProgressView().tint(.white).padding(12).background(.black.opacity(0.45), in: Circle()) }
                            }
                    } else {
                        // A note saved without media still needs a card: the body
                        // summary replaces the cover instead of leaving a hole.
                        TextSummaryCover(note: note, width: width, height: width / note.coverRatio)
                            .modifier(NoteHeroFrame(geometry: heroGeometry, role: "image", id: note.id))
                            .overlay(alignment: .topTrailing) {
                                if isSelecting {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 24)).symbolRenderingMode(.palette)
                                        .foregroundStyle(selected ? Color.coral : .white, .white)
                                        .shadow(radius: 2).padding(8)
                                }
                            }
                    }
                    if !note.title.isEmpty {
                        NoteHeroTitle(text: note.title, size: titleSize, lines: 2, geometry: heroGeometry, id: note.id)
                            .modifier(NoteHeroFrame(geometry: heroGeometry, role: "title", id: note.id))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.top, 9)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.975))
            .opacity(heroGeometry.concealedContentID == note.id ? 0 : 1)
            .animation(nil, value: heroGeometry.concealedContentID)
            .accessibilityIdentifier("library-item-\(cardIdentifier)")
            .accessibilityLabel(note.title.isEmpty ? note.author : note.title)
            .accessibilityValue(isSelecting && selected ? L10n.text("library.selected") : "")
            .accessibilityAddTraits(isSelecting && selected ? .isSelected : [])
            HStack(spacing: 0) {
                Button {
                    if isSelecting { onOpen() }
                    else if let profileURL = note.authorProfileURL { AppFeedback.play(.navigation); openURL(profileURL) }
                } label: {
                    HStack(spacing: 6) {
                        NoteAuthorAvatar(name: note.author, url: note.avatarURL, size: 20)
                        Text(note.author).font(.system(size: authorSize)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isSelecting && note.authorProfileURL == nil)
                .accessibilityIdentifier("feed-author-\(note.id)")
                .accessibilityValue(note.authorProfileURL?.absoluteString ?? "")
                if !isSelecting {
                    Button(action: onLike) {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 18)).foregroundStyle(liked ? Color.coral : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: liked)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text(liked ? "feed.bookmark.remove" : "feed.bookmark"))
                    .accessibilityIdentifier("feed-like-\(note.id)")
                }
            }
            .padding(.leading, 10).padding(.trailing, 5)
        }
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelecting && selected ? Color.coral : Color.primary.opacity(0.06),
                              lineWidth: isSelecting && selected ? 2.5 : 0.5)
        }
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        .scaleEffect(isSelecting && selected && !reduceMotion ? 0.97 : 1)
        .animation(XHSDesign.animation(reduceMotion, XHSDesign.snappy), value: selected)
        .modifier(NoteHeroFrame(geometry: heroGeometry, role: "card", id: note.id))
        .opacity(heroGeometry.concealedCardID == note.id ? 0 : 1)
        .animation(nil, value: heroGeometry.concealedCardID)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed-note-\(note.id)")
    }
}

/// Text-only notes get a paper-like summary card so the feed stays readable
/// without inventing a thumbnail.
private struct TextSummaryCover: View {
    let note: LibraryNote
    let width: CGFloat
    let height: CGFloat
    @ScaledMetric(relativeTo: .footnote) private var bodySize: CGFloat = 13

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(uiColor: .secondarySystemBackground),
                                    Color(uiColor: .tertiarySystemBackground)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.text("note.type.text"), systemImage: "text.alignleft")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(note.body)
                    .font(.system(size: bodySize))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .lineLimit(max(3, Int(height / (bodySize * 1.6))))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .frame(width: width, height: height)
        .clipped()
    }
}

enum NoteCaption {
    private static let expression = try! NSRegularExpression(pattern: #"#[^\s#\[\]，。！？、,!?]+(?:\[话题\]#)?"#)

    static func attributed(_ body: String) -> AttributedString {
        // The web description can contain the XHS topic marker. Render its
        // visible topic text, retaining every ordinary paragraph and emoji.
        let body = body.replacingOccurrences(of: "[话题]#", with: "")
        var result = AttributedString(body)
        for match in expression.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let range = Range(match.range, in: body),
                  let attributedRange = Range(range, in: result) else { continue }
            let topic = String(body[range].dropFirst())
            var url = URLComponents()
            url.scheme = "xhsdn"; url.host = "topic"
            url.queryItems = [URLQueryItem(name: "name", value: topic)]
            result[attributedRange].link = url.url
            result[attributedRange].foregroundColor = Color(red: 0.12, green: 0.31, blue: 0.46)
        }
        return result
    }
}

struct NoteReaderView: View {
    let note: LibraryNote
    let initialImage: UIImage
    /// The coordinator is the single source of truth for likes and bookmarks, so
    /// the detail view and the feed can never disagree.
    @ObservedObject var coordinator: DownloadCoordinator
    let namespace: Namespace.ID
    let heroGeometry: NoteHeroGeometry
    let onClose: () -> Void
    let onDelete: (Set<String>) async throws -> Void
    let onCopy: (String) -> Void
    let onTopic: (String) -> Void
    @State private var media: [LibraryMedia]
    @State private var selected: String
    @StateObject private var presentation = MediaPresentation()
    @StateObject private var imageGeometry = NoteHeroGeometry()
    @StateObject private var viewerGeometry = NoteHeroGeometry()
    @Namespace private var imageTransition
    @State private var deletion = Set<String>()
    @State private var showsDeletion = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var share: MediaShareFiles?
    @State private var shareDirectory: URL?
    @State private var copied = false
    @ScaledMetric(relativeTo: .title3) private var titleSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 16
    @Environment(\.openURL) private var openURL

    init(note: LibraryNote, initialImage: UIImage, coordinator: DownloadCoordinator,
         namespace: Namespace.ID, heroGeometry: NoteHeroGeometry, onClose: @escaping () -> Void,
         onDelete: @escaping (Set<String>) async throws -> Void, onCopy: @escaping (String) -> Void,
         onTopic: @escaping (String) -> Void) {
        self.note = note; self.initialImage = initialImage; self.coordinator = coordinator
        self.namespace = namespace; self.onDelete = onDelete; self.onCopy = onCopy; self.onTopic = onTopic
        self.heroGeometry = heroGeometry; self.onClose = onClose
        _media = State(initialValue: note.media)
        _selected = State(initialValue: note.cover?.id ?? "")
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if media.isEmpty {
                        TextOnlyHero(note: note, width: geometry.size.width)
                            .modifier(NoteHeroFrame(geometry: heroGeometry, role: "viewport", id: note.id))
                    } else {
                        let height = min(geometry.size.width / note.coverRatio, geometry.size.height * 0.78)
                        TabView(selection: $selected) {
                            ForEach(media) { item in
                                PhotosMediaView(identifier: item.id, initialImage: item.id == note.cover?.id ? initialImage : nil,
                                                active: selected == item.id, zoomTrigger: 0, backgroundColor: .systemBackground,
                                                onOpen: { openImage(item.id) },
                                                canvasIdentifier: "note-media-canvas-\(item.id)", heroGeometry: imageGeometry,
                                                cardGeometry: heroGeometry, cardID: note.id)
                                    .tag(item.id)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: max(180, height))
                        .modifier(NoteHeroFrame(geometry: heroGeometry, role: "viewport", id: note.id))
                        .modifier(NoteHeroFrame(geometry: imageGeometry, role: "viewport", id: selected))
                        .overlay(alignment: .topTrailing) {
                            if media.count > 1 {
                                Text("\((media.firstIndex { $0.id == selected } ?? 0) + 1)/\(media.count)")
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .contentTransition(.numericText())
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .foregroundStyle(.white)
                                    .glassEffect(.regular.tint(.black.opacity(0.28)), in: Capsule())
                                    .padding(12)
                                    .animation(.snappy, value: selected)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Button { openImage(selected) } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 44, height: 44).contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.tint(.black.opacity(0.22)).interactive(), in: Circle())
                            .accessibilityLabel(L10n.text("library.open"))
                            .accessibilityIdentifier("note-expand-media").padding(12)
                        }

                        if media.count > 1 {
                            HStack(spacing: 5) {
                                ForEach(media) { item in
                                    Capsule().fill(selected == item.id ? Color.coral : Color(uiColor: .systemGray4))
                                        .frame(width: selected == item.id ? 14 : 5, height: 5)
                                }
                            }
                            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: selected)
                            .frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, 2).accessibilityHidden(true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        if !note.title.isEmpty {
                            NoteHeroTitle(text: note.title, size: titleSize, lines: 0, geometry: heroGeometry,
                                          id: note.id, accessibilityID: "note-title")
                                .modifier(NoteHeroFrame(geometry: heroGeometry, role: "title", id: note.id))
                        }
                        if !note.body.isEmpty {
                            Text(NoteCaption.attributed(note.body))
                                .font(.system(size: bodySize)).lineSpacing(6).textSelection(.enabled)
                                .accessibilityIdentifier("note-caption")
                                .environment(\.openURL, OpenURLAction { url in
                                    if let topic = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "name" })?.value,
                                       url.scheme == "xhsdn", url.host == "topic" {
                                        onTopic(topic); onClose(); return .handled
                                    }
                                    return .systemAction
                                })
                        }
                        let extraTopics = note.topics.filter { !note.body.contains("#" + $0) }
                        if !extraTopics.isEmpty {
                            Text(NoteCaption.attributed(extraTopics.map { "#" + $0 }.joined(separator: " ")))
                                .font(.system(size: bodySize)).textSelection(.enabled)
                                .environment(\.openURL, OpenURLAction { url in
                                    if let topic = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "name" })?.value {
                                        onTopic(topic); onClose(); return .handled
                                    }
                                    return .systemAction
                                })
                        }
                        Text(note.publishTime.map { L10n.format("feed.published", $0) } ??
                             L10n.format("feed.saved.date", note.date.formatted(date: .abbreviated, time: .omitted)))
                            .font(.system(size: 12)).foregroundStyle(.tertiary).padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 18)
                }
                .padding(.bottom, 20)
            }
            .accessibilityIdentifier("note-reader-scroll")
            .modifier(NoteHeroFrame(geometry: heroGeometry, role: "scroll", id: note.id))
            .modifier(NoteHeroFrame(geometry: imageGeometry, role: "scroll", id: selected))
            .background(Color(uiColor: .systemBackground))
        }
        .safeAreaBar(edge: .top, spacing: 0) { authorBar }
        .safeAreaBar(edge: .bottom, spacing: 0) { actionBar }
        .background(Color(uiColor: .systemBackground))
        .onChange(of: selected) { _, _ in if presentation.selection == nil { AppFeedback.play(.selection) } }
        .background {
            NoteHeroPresentation(item: $presentation.selection, card: false, source: imageGeometry, destination: viewerGeometry,
                                 preview: { $0.image }, onDismiss: { if media.isEmpty { onClose() } }) { selection, close in
                MediaViewer(identifiers: selection.identifiers, initialIdentifier: selection.id,
                            initialImage: selection.image, transition: imageTransition, onDelete: delete, onSelect: { id in
                                var transaction = Transaction(animation: nil)
                                transaction.disablesAnimations = true
                                withTransaction(transaction) { selected = id }
                            }, heroGeometry: viewerGeometry, onClose: close)
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
                    let ids = deletion; busy = true
                    Task {
                        defer { busy = false }
                        do { try await delete(ids); AppFeedback.play(.success) }
                        catch { if !isPhotosCancellation(error) { errorMessage = error.localizedDescription; AppFeedback.play(.error) } }
                    }
                }
                Button(L10n.text("common.cancel"), role: .cancel) {}
            } else { Button(L10n.text("common.ok"), role: .cancel) {} }
        } message: { Text(showsDeletion ? L10n.text("library.delete.message") : errorMessage ?? "") }
        .sheet(item: $share, onDismiss: {
            if let shareDirectory { try? FileManager.default.removeItem(at: shareDirectory) }
            shareDirectory = nil
        }) { MediaShareSheet(urls: $0.urls) }
        .disabled(busy)
        .tint(.coral)
    }

    private var authorBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button { AppFeedback.play(.navigation); onClose() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel(L10n.text("common.done")).accessibilityIdentifier("note-close")
                Button {
                    if let profileURL = note.authorProfileURL { AppFeedback.play(.navigation); openURL(profileURL) }
                } label: {
                    HStack(spacing: 8) {
                        NoteAuthorAvatar(name: note.author, url: note.avatarURL, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(note.author).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            if let redID = note.authorRedID, !redID.isEmpty {
                                Text(L10n.format("feed.author.id", redID)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .padding(.leading, 6).padding(.trailing, 14)
                    .frame(minHeight: 44).contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(note.authorProfileURL == nil)
                .glassEffect(.regular.interactive(), in: Capsule())
                .accessibilityIdentifier("note-author-profile")
                .accessibilityValue(note.authorProfileURL?.absoluteString ?? "")
                Spacer(minLength: 4)
                if let sourceURL = note.sourceURL {
                    Button { AppFeedback.play(.navigation); openURL(sourceURL) } label: {
                        Text(L10n.text("feed.source")).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white).padding(.horizontal, 14)
                            .frame(minHeight: 44).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.coral).interactive(), in: Capsule())
                    .accessibilityIdentifier("note-source")
                }
                Menu {
                    Button { copyCaption() } label: { Label(L10n.text("action.copy_caption"), systemImage: "doc.on.doc") }
                        .disabled(note.body.isEmpty)
                    Button { export() } label: { Label(L10n.text("library.share"), systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { confirmDelete([selected]) } label: {
                        Label(L10n.text("feed.delete.current"), systemImage: "trash")
                    }
                    if media.count > 1 {
                        Button(role: .destructive) { confirmDelete(Set(media.map(\.id))) } label: {
                            Label(L10n.text("feed.delete.note"), systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel(L10n.text("common.more")).accessibilityIdentifier("note-more")
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 6)
    }

    private var actionBar: some View {
        let favorited = coordinator.likedNotes.contains(note.id)
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { copyCaption() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: copied ? "checkmark" : "square.and.pencil")
                            .contentTransition(.symbolEffect(.replace))
                        Text(L10n.text(copied ? "feed.copied" : "action.copy_caption"))
                            .font(.system(size: 14, weight: .medium)).lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    .foregroundStyle(copied ? Color.coral : .secondary)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .disabled(note.body.isEmpty).accessibilityIdentifier("note-copy-caption")
                HStack(spacing: 0) {
                    Button { coordinator.toggleLike(noteID: note.id) } label: {
                        Image(systemName: favorited ? "heart.fill" : "heart")
                            .foregroundStyle(favorited ? Color.coral : .primary)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: favorited)
                            .font(.system(size: 21)).frame(width: 48, height: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text(favorited ? "feed.bookmark.remove" : "feed.bookmark"))
                    .accessibilityIdentifier("note-like")
                    Button { export() } label: {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 19))
                            .frame(width: 48, height: 48).foregroundStyle(.primary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("library.notes.share")).accessibilityIdentifier("note-share")
                }
                .padding(.horizontal, 4)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 4)
        .animation(.snappy, value: copied)
    }

    private struct TextOnlyHero: View {
        let note: LibraryNote
        let width: CGFloat
        @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16

        var body: some View {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(uiColor: .secondarySystemBackground),
                                        Color(uiColor: .tertiarySystemBackground)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: 10) {
                    Label(L10n.text("note.type.text"), systemImage: "text.alignleft")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(note.body.isEmpty ? note.title : String(note.body.prefix(220)))
                        .font(.system(size: size))
                        .lineSpacing(5)
                        .lineLimit(9)
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .frame(width: width, height: max(180, width * 0.62))
            .clipped()
        }
    }

    private func copyCaption() {
        onCopy(note.body)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            copied = false
        }
    }
    private func openImage(_ id: String) {
        imageGeometry.selectedID = id
        viewerGeometry.selectedID = id
        presentation.open(id, identifiers: media.map(\.id))
    }
    private func confirmDelete(_ ids: Set<String>) { deletion = ids; showsDeletion = true; AppFeedback.play(.warning) }
    private func delete(_ ids: Set<String>) async throws {
        try await onDelete(ids)
        media.removeAll { ids.contains($0.id) }
        if media.isEmpty {
            if presentation.selection == nil { onClose() }
        }
        else if !media.contains(where: { $0.id == selected }) { selected = media[0].id }
    }
    private func export() {
        busy = true; AppFeedback.play(.navigation)
        Task {
            defer { busy = false }
            do {
                let files = try await MediaExporter.shared.export(notes: [note])
                shareDirectory = files.directory; share = files
            } catch { if !isPhotosCancellation(error) { errorMessage = error.localizedDescription; AppFeedback.play(.error) } }
        }
    }
}
