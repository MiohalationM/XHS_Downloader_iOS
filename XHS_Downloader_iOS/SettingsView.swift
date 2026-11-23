import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings open on an overview: the account, the three switches people touch
/// most, and one row per area with its current state. Each area has its own
/// page, so no single screen carries all seven groups at once.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: DownloadCoordinator
    @ObservedObject private var session = WebSession.shared

    @State private var showsBrowser = false
    @State private var storage = StorageUsage()
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AccountSettingsView(settings: settings, coordinator: coordinator)
                    } label: {
                        accountHeader
                    }
                    .accessibilityIdentifier("settings-row-account")
                }

                if session.account == nil {
                    Section {
                        Button {
                            showsBrowser = true
                        } label: {
                            Label(L10n.text("settings.account.sign_in"), systemImage: "person.crop.circle.badge.checkmark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(.coral).interactive(), in: Capsule())
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .accessibilityIdentifier("settings-sign-in")
                    }
                }

                Section {
                    Toggle(isOn: $settings.clipboardSuggestions.feedbackSelection()) {
                        SettingsRowLabel(title: L10n.text("settings.clipboard"), systemImage: "doc.on.clipboard.fill", color: .orange)
                    }
                    Toggle(isOn: $settings.selectiveDownload.feedbackSelection()) {
                        SettingsRowLabel(title: L10n.text("settings.selective"), systemImage: "checklist", color: .blue)
                    }
                    Picker(selection: $settings.policy.destination.feedbackSelection()) {
                        ForEach(SaveDestination.allCases, id: \.self) { value in
                            Text(L10n.text("destination." + value.rawValue)).tag(value)
                        }
                    } label: {
                        SettingsRowLabel(title: L10n.text("settings.destination"), systemImage: "tray.and.arrow.down.fill", color: .green)
                    }
                } header: {
                    Text(L10n.text("settings.group.quick"))
                }

                Section {
                    row(L10n.text("settings.group.media"), "photo.on.rectangle.angled", .coral,
                        value: L10n.text("image.format." + settings.policy.imageFormat.rawValue), id: "media") {
                        MediaSettingsView(settings: settings)
                    }
                    let destinationTitle = L10n.text("destination." + settings.policy.destination.rawValue)
                    row(L10n.text("settings.group.archive"), "folder.fill", .blue,
                        value: settings.policy.namingEnabled ? "\(destinationTitle) · \(L10n.text("settings.naming.custom"))" : destinationTitle,
                        id: "archive") {
                        ArchiveSettingsView(settings: settings, coordinator: coordinator)
                    }
                    row(L10n.text("settings.group.network"), "network", .teal,
                        value: settings.policy.proxy.trimmingCharacters(in: .whitespaces).isEmpty
                            ? L10n.format("settings.seconds", Int(settings.policy.timeout))
                            : L10n.text("settings.proxy.configured"), id: "network") {
                        NetworkSettingsView(settings: settings)
                    }
                    row(L10n.text("settings.group.interaction"), "hand.tap.fill", .purple,
                        value: L10n.text("appearance." + settings.appearance), id: "interaction") {
                        InteractionSettingsView(settings: settings)
                    }
                    row(L10n.text("settings.group.storage"), "externaldrive.fill", .gray,
                        value: ByteCountFormatter.string(fromByteCount: storage.total, countStyle: .file), id: "storage") {
                        StorageSettingsView(settings: settings, coordinator: coordinator)
                    }
                }

                Section {
                    row(L10n.text("settings.about"), "info.circle.fill", .indigo, value: SettingsView.versionString, id: "about") {
                        AboutSettingsView(settings: settings, coordinator: coordinator)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(14)
            .scrollContentBackground(.hidden)
            .background { GlassBackdrop(color: .coral, intensity: 0.8) }
            .navigationTitle(L10n.text("settings.title"))
            .onChange(of: showsBrowser) { _, shown in if shown { AppFeedback.play(.navigation) } }
            .onAppear {
                Task { storage = await SettingsView.loadStorage() }
            }
            .task {
                storage = await SettingsView.loadStorage()
                if let loadError = coordinator.loadError, !loadError.isEmpty {
                    statusMessage = L10n.format("library.load.failed", loadError)
                }
            }
            .sheet(isPresented: $showsBrowser) {
                BrowserView(settings: settings) { importValue, behavior in
                    switch importValue {
                    case .page(let payload): coordinator.enqueue(payload, behavior: behavior)
                    case .link(let text): coordinator.enqueue(text, behavior: behavior)
                    }
                    showsBrowser = false
                }
            }
            .settingsAlert($statusMessage)
        }
        .tint(.coral)
    }

    private var accountHeader: some View {
        HStack(spacing: 14) {
            Group {
                if let account = session.account {
                    NoteAuthorAvatar(name: account.name, url: account.avatar, size: 56)
                } else {
                    Circle()
                        .fill(Color.coral.opacity(0.12))
                        .frame(width: 56, height: 56)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Color.coral)
                        }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(session.account == nil ? Color(uiColor: .systemGray3) : Color.green)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.cardBackground, lineWidth: 2.5))
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.account?.name ?? L10n.text("settings.account.signed_out"))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(accountDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }

    private var accountDetail: String {
        guard let account = session.account else { return L10n.text("settings.account.hint.short") }
        var parts: [String] = [L10n.text("settings.account.signed_in")]
        if let redID = account.redID, !redID.isEmpty { parts.append(L10n.text("caption.red_id") + " " + redID) }
        else if let uid = account.uid, !uid.isEmpty { parts.append(uid) }
        return parts.joined(separator: " · ")
    }

    private func row<Destination: View>(_ title: String, _ systemImage: String, _ color: Color,
                                        value: String?, id: String,
                                        @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                SettingsRowLabel(title: title, systemImage: systemImage, color: color)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityIdentifier("settings-row-\(id)")
    }

    // MARK: Shared helpers

    static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    static func loadStorage() async -> StorageUsage {
        let previews = Int64(URLCache.shared.currentDiskUsage)
        return await BackupService.shared.usage(previewCacheBytes: previews)
    }

    /// Numeric component comparison: "1.10.0" is newer than "1.9.0".
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

// MARK: - Building blocks

struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            IconTile(systemImage: systemImage, color: color, size: 29)
        }
    }
}

/// A selectable tile used for media types and destinations. It keeps toggle
/// semantics for VoiceOver while reading as a visual choice.
private struct TileToggleStyle: ToggleStyle {
    let systemImage: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(XHSDesign.animation(reduceMotion, XHSDesign.snappy)) { configuration.isOn.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(configuration.isOn ? Color.coral : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            (configuration.isOn ? Color.coral.opacity(0.14) : Color.primary.opacity(0.05)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .symbolEffect(.bounce, value: configuration.isOn)
                    Spacer()
                    Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(configuration.isOn ? Color.coral : Color(uiColor: .systemGray3))
                        .contentTransition(.symbolEffect(.replace))
                }
                configuration.label
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: XHSDesign.tileRadius, style: .continuous)
                    .fill(Color.cardBackground)
                if configuration.isOn {
                    RoundedRectangle(cornerRadius: XHSDesign.tileRadius, style: .continuous)
                        .fill(Color.coral.opacity(0.08))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: XHSDesign.tileRadius, style: .continuous)
                    .strokeBorder(configuration.isOn ? Color.coral.opacity(0.6) : Color.primary.opacity(0.07),
                                  lineWidth: configuration.isOn ? 1.5 : 0.6)
            }
            .contentShape(RoundedRectangle(cornerRadius: XHSDesign.tileRadius, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// Exactly-one choice shown as cards (destination, appearance).
private struct ChoiceCards<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        let systemImage: String
        var id: Value { value }
    }
    let options: [Option]
    @Binding var selection: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button {
                    guard selection != option.value else { return }
                    withAnimation(XHSDesign.animation(reduceMotion, XHSDesign.snappy)) { selection = option.value }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: option.systemImage)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(selected ? Color.white : Color.coral)
                            .frame(width: 44, height: 44)
                            .background(selected ? AnyShapeStyle(.coralGradient) : AnyShapeStyle(Color.coral.opacity(0.12)),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .symbolEffect(.bounce, value: selected)
                        Text(option.title)
                            .font(.footnote.weight(selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background {
                        RoundedRectangle(cornerRadius: XHSDesign.tileRadius, style: .continuous)
                            .fill(Color.cardBackground)
                        if selected {
                            RoundedRectangle(cornerRadius: XHSDesign.tileRadius, style: .continuous)
                                .fill(Color.coral.opacity(0.07))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: XHSDesign.tileRadius, style: .continuous)
                            .strokeBorder(selected ? Color.coral.opacity(0.6) : Color.primary.opacity(0.07),
                                          lineWidth: selected ? 1.5 : 0.6)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: XHSDesign.tileRadius, style: .continuous))
                }
                .buttonStyle(.pressable)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Shared ScrollView canvas and inset-grouped card helpers for subpages with
/// multi-column tile cards, preventing UITableView section corner clipping.
private struct SettingsScrollContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
    }
}

private struct SettingsSectionBlock<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    var grouped = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            if grouped {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: XHSDesign.cardRadius, style: .continuous))
            } else {
                content()
            }
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

private struct SettingsCardRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 48)
    }
}

private struct SettingsRowDivider: View {
    var leading: CGFloat = 16

    var body: some View {
        Divider()
            .padding(.leading, leading)
    }
}

private struct SettingsMenuRow<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder let options: () -> Options

    var body: some View {
        SettingsCardRow {
            HStack(spacing: 12) {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Picker(title, selection: $selection) {
                    options()
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
            }
        }
    }
}

private struct TimeZonePickerView: View {
    @Binding var selection: String
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        List(filtered, id: \.self) { identifier in
            Button {
                selection = identifier
                AppFeedback.play(.selection)
                dismiss()
            } label: {
                HStack {
                    Text(identifier)
                        .foregroundStyle(.primary)
                    Spacer()
                    if identifier == selection {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.coral)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background { GlassBackdrop(color: .coral, intensity: 0.55) }
        .searchable(text: $query)
        .navigationTitle(L10n.text("settings.naming.timezone"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension View {
    func settingsAlert(_ message: Binding<String?>) -> some View {
        alert(L10n.text("common.notice"), isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button(L10n.text("common.ok"), role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }

    func settingsPage(_ title: String) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { GlassBackdrop(color: .coral, intensity: 0.55) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Account

private struct AccountSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: DownloadCoordinator
    @ObservedObject private var session = WebSession.shared
    @State private var showsBrowser = false
    @State private var manualCookies: [String: String] = [:]
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    if let account = session.account {
                        NoteAuthorAvatar(name: account.name, url: account.avatar, size: 76)
                    } else {
                        Circle()
                            .fill(Color.coral.opacity(0.12))
                            .frame(width: 76, height: 76)
                            .overlay {
                                Image(systemName: "person.fill")
                                    .font(.largeTitle.weight(.semibold))
                                    .foregroundStyle(Color.coral)
                            }
                    }
                    Text(session.account?.name ?? L10n.text("settings.account.signed_out"))
                        .font(.title3.weight(.semibold))
                    StatusCapsule(signedIn: session.account != nil)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    showsBrowser = true
                } label: {
                    Label(session.account == nil ? L10n.text("settings.account.sign_in")
                                                 : L10n.text("settings.account.reverify"),
                          systemImage: "person.crop.circle.badge.checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.coral).interactive(), in: Capsule())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                if session.account == nil {
                    Text(L10n.text("settings.account.hint"))
                }
            }

            if session.account != nil {
                Section {
                    Button(role: .destructive) {
                        Task {
                            await session.logout()
                            AppFeedback.play(.success)
                        }
                    } label: {
                        Label(L10n.text("settings.account.sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } footer: {
                    Text(L10n.text("settings.account.hint"))
                }
            }

            Section {
                ForEach(SessionVault.hosts, id: \.self) { host in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(host).font(.caption.monospaced())
                            Spacer()
                            if SessionVault.hasCookie(host) {
                                Label(L10n.text("settings.cookie.present"), systemImage: "checkmark.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.green)
                            }
                        }
                        TextField(L10n.text("settings.cookie.placeholder"), text: Binding(
                            get: { manualCookies[host] ?? "" },
                            set: { manualCookies[host] = $0 }
                        ), axis: .vertical)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                        HStack {
                            Button(L10n.text("settings.cookie.save")) { saveCookie(host) }
                                .buttonStyle(.bordered)
                                .disabled((manualCookies[host] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                            Spacer()
                            Button(L10n.text("settings.cookie.clear"), role: .destructive) {
                                do {
                                    try SessionVault.set("", host: host)
                                    manualCookies[host] = ""
                                    AppFeedback.play(.success)
                                } catch {
                                    statusMessage = error.localizedDescription
                                    AppFeedback.play(.error)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(!SessionVault.hasCookie(host))
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text(L10n.text("settings.cookie.title"))
            }
        }
        .settingsPage(L10n.text("settings.group.account"))
        .onChange(of: showsBrowser) { _, shown in if shown { AppFeedback.play(.navigation) } }
        .sheet(isPresented: $showsBrowser) {
            BrowserView(settings: settings) { importValue, behavior in
                switch importValue {
                case .page(let payload): coordinator.enqueue(payload, behavior: behavior)
                case .link(let text): coordinator.enqueue(text, behavior: behavior)
                }
                showsBrowser = false
            }
        }
        .settingsAlert($statusMessage)
    }

    private func saveCookie(_ host: String) {
        let value = SessionVault.sanitize(manualCookies[host] ?? "")
        guard !value.isEmpty else {
            statusMessage = L10n.text("settings.cookie.invalid")
            AppFeedback.play(.warning)
            return
        }
        do {
            try SessionVault.set(value, host: host)
            manualCookies[host] = ""
            AppFeedback.play(.success)
        } catch {
            statusMessage = error.localizedDescription
            AppFeedback.play(.error)
        }
    }

    private struct StatusCapsule: View {
        let signedIn: Bool
        var body: some View {
            Label(L10n.text(signedIn ? "settings.account.signed_in" : "settings.account.signed_out"),
                  systemImage: signedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(signedIn ? Color.green : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background((signedIn ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
        }
    }
}

// MARK: - Media

private struct MediaSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsScrollContainer {
            SettingsSectionBlock(header: L10n.text("settings.media.content"), grouped: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    Toggle(L10n.text("settings.images"), isOn: $settings.policy.images.feedbackSelection())
                        .toggleStyle(TileToggleStyle(systemImage: "photo"))
                        .accessibilityIdentifier("settings-content-images")
                    Toggle(L10n.text("settings.videos"), isOn: $settings.policy.videos.feedbackSelection())
                        .toggleStyle(TileToggleStyle(systemImage: "video"))
                        .accessibilityIdentifier("settings-content-videos")
                    Toggle(L10n.text("settings.covers"), isOn: $settings.policy.covers.feedbackSelection())
                        .toggleStyle(TileToggleStyle(systemImage: "rectangle.on.rectangle"))
                        .accessibilityIdentifier("settings-content-covers")
                    Toggle(L10n.text("settings.comments"), isOn: $settings.policy.comments.feedbackSelection())
                        .toggleStyle(TileToggleStyle(systemImage: "text.bubble"))
                        .accessibilityIdentifier("settings-content-comments")
                }
            }

            SettingsSectionBlock(header: L10n.text("settings.media.quality")) {
                SettingsMenuRow(title: L10n.text("settings.image_format"), selection: $settings.policy.imageFormat.feedbackSelection()) {
                    ForEach(ImagePreference.allCases, id: \.self) { value in
                        Text(L10n.text("image.format." + value.rawValue)).tag(value)
                    }
                }
                SettingsRowDivider()
                SettingsMenuRow(title: L10n.text("settings.video_preference"), selection: $settings.policy.videoPreference.feedbackSelection()) {
                    ForEach(VideoPreference.allCases, id: \.self) { value in
                        Text(L10n.text("video.pref." + value.rawValue)).tag(value)
                    }
                }
                SettingsRowDivider()
                SettingsMenuRow(title: L10n.text("settings.live_photo"), selection: $settings.livePhotoMode.feedbackSelection()) {
                    ForEach(LivePhotoMode.allCases, id: \.self) { mode in
                        Text(L10n.text(mode.localizationKey)).tag(mode)
                    }
                }
                SettingsRowDivider()
                SettingsMenuRow(title: L10n.text("settings.caption_format"), selection: $settings.policy.captionFormat.feedbackSelection()) {
                    ForEach(CaptionFormat.allCases, id: \.self) { value in
                        Text(L10n.text("caption." + value.rawValue)).tag(value)
                    }
                }
            }
        }
        .settingsPage(L10n.text("settings.group.media"))
    }
}

// MARK: - Archive & naming

private struct ArchiveSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: DownloadCoordinator
    @State private var showsDirectoryPicker = false
    @State private var statusMessage: String?

    private var customNaming: Binding<Bool> { $settings.policy.namingEnabled }
    private var namingTemplate: Binding<String> { $settings.policy.namingTemplate }
    private var namingTimezone: Binding<String> { $settings.policy.namingTimezone }

    var body: some View {
        SettingsScrollContainer {
            SettingsSectionBlock(header: L10n.text("settings.destination"), grouped: false) {
                ChoiceCards(options: [
                    .init(value: SaveDestination.photos, title: L10n.text("destination.photos"), systemImage: "photo.on.rectangle"),
                    .init(value: SaveDestination.files, title: L10n.text("destination.files"), systemImage: "folder"),
                    .init(value: SaveDestination.both, title: L10n.text("destination.both"), systemImage: "square.stack")
                ], selection: $settings.policy.destination.feedbackSelection())
            }

            SettingsSectionBlock(header: L10n.text("destination.files")) {
                Button {
                    showsDirectoryPicker = true
                } label: {
                    SettingsCardRow {
                        HStack(spacing: 10) {
                            SettingsRowLabel(title: L10n.text("settings.directory"), systemImage: "folder.fill", color: .blue)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text(directoryLabel)
                                .font(.caption)
                                .foregroundStyle(directoryNeedsAttention ? Color.orange : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if directoryNeedsAttention, settings.policy.filesBookmark != nil {
                    SettingsRowDivider()
                    SettingsCardRow {
                        Label(L10n.text("settings.directory.unavailable"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                SettingsRowDivider()
                SettingsCardRow {
                    Toggle(L10n.text("settings.author_directories"), isOn: $settings.policy.authorDirectories.feedbackSelection())
                        .tint(.coral)
                }
                SettingsRowDivider()
                SettingsCardRow {
                    Toggle(L10n.text("settings.note_directories"), isOn: $settings.policy.noteDirectories.feedbackSelection())
                        .tint(.coral)
                }
                SettingsRowDivider()
                SettingsCardRow {
                    Toggle(L10n.text("settings.skip_existing"), isOn: $settings.policy.skipExisting.feedbackSelection())
                        .tint(.coral)
                }
                SettingsRowDivider()
                SettingsCardRow {
                    Toggle(L10n.text("settings.write_publish_time"), isOn: $settings.policy.writePublishTime.feedbackSelection())
                        .tint(.coral)
                }
            }

            SettingsSectionBlock(header: L10n.text("settings.naming"),
                                 footer: L10n.text("settings.naming.placeholders")) {
                SettingsCardRow {
                    Toggle(L10n.text("settings.naming.enable"), isOn: customNaming.feedbackSelection())
                        .tint(.coral)
                }
                if customNaming.wrappedValue {
                    SettingsRowDivider()
                    SettingsCardRow {
                        TextField(L10n.text("settings.naming.template"), text: namingTemplate, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                            .accessibilityIdentifier("naming-template-field")
                    }

                    SettingsRowDivider()
                    if let error = NamingFormatter.validationError(namingTemplate.wrappedValue) {
                        SettingsCardRow {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        SettingsCardRow {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.text("settings.naming.preview"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Label {
                                    Text(namingPreview)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                } icon: {
                                    Image(systemName: "doc.richtext").foregroundStyle(Color.coral)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }

                    SettingsRowDivider()
                    SettingsCardRow {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                preset(L10n.text("settings.naming.preset.plain"), "{title}_{index_padded}")
                                preset(L10n.text("settings.naming.preset.dated"), NamingFormatter.defaultTemplate)
                                preset(L10n.text("settings.naming.preset.author"), "{username}_{title}_{publishTime}")
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollClipDisabled()
                    }

                    SettingsRowDivider()
                    Button {
                        namingTemplate.wrappedValue = NamingFormatter.defaultTemplate
                        AppFeedback.play(.confirmation)
                    } label: {
                        SettingsCardRow {
                            Text(L10n.text("settings.naming.reset"))
                                .foregroundStyle(Color.coral)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                SettingsRowDivider()
                NavigationLink {
                    TimeZonePickerView(selection: namingTimezone)
                } label: {
                    SettingsCardRow {
                        HStack(spacing: 10) {
                            Text(L10n.text("settings.naming.timezone"))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text(namingTimezone.wrappedValue)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .settingsPage(L10n.text("settings.group.archive"))
        .animation(.snappy, value: customNaming.wrappedValue)
        .onChange(of: showsDirectoryPicker) { _, shown in if shown { AppFeedback.play(.navigation) } }
        .fileImporter(isPresented: $showsDirectoryPicker, allowedContentTypes: [.folder]) { result in
            handleDirectory(result)
        }
        .settingsAlert($statusMessage)
    }

    private func preset(_ title: String, _ template: String) -> some View {
        let selected = namingTemplate.wrappedValue == template
        return Button {
            namingTemplate.wrappedValue = template
            AppFeedback.play(.confirmation)
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(.coral).interactive() : .regular.interactive(), in: Capsule())
    }

    private var directoryLabel: String {
        guard settings.policy.filesBookmark != nil else { return L10n.text("settings.directory.none") }
        return ArchiveDirectory.displayPath(settings.policy.filesBookmark) ?? L10n.text("settings.directory.unavailable")
    }

    private var directoryNeedsAttention: Bool {
        settings.policy.filesBookmark != nil && !ArchiveDirectory.isUsable(settings.policy.filesBookmark)
    }

    /// The preview uses the same formatter as the download pipeline, so what the
    /// user sees here is exactly the file name a task will produce.
    private var namingPreview: String {
        let preferences = NamingPreferences(
            enabled: true,
            template: namingTemplate.wrappedValue,
            timeZone: TimeZone(identifier: namingTimezone.wrappedValue) ?? .current
        )
        let metadata = NoteMetadata(userName: "示例作者", userId: "5f0000000000000000000001",
                                    title: "周末随手拍", publishTime: "26-11-08", redId: "demo123")
        return NamingFormatter.makeBaseName(
            metadata: metadata,
            fallbackPostId: "65f0000000000000000000aa",
            index: 1,
            downloadEpochSeconds: Date().timeIntervalSince1970,
            preferences: preferences
        ) + ".heic"
    }

    private func handleDirectory(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let bookmark = try ArchiveDirectory.makeBookmark(for: url)
                // Also repoint tasks that still carry a stale bookmark.
                coordinator.reauthorizeArchiveDirectory(bookmark)
                AppFeedback.play(.success)
            } catch {
                statusMessage = error.localizedDescription
                AppFeedback.play(.error)
            }
        case .failure(let error as CocoaError) where error.code == .userCancelled:
            break
        case .failure(let error):
            statusMessage = error.localizedDescription
            AppFeedback.play(.error)
        }
    }
}

// MARK: - Network

private struct NetworkSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var proxyCheck: ProxyCheck = .idle
    @State private var requestIntervalBeforeEditing: Double?

    private enum ProxyCheck: Equatable {
        case idle, checking, ok, failed(String)
    }

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.policy.timeout.feedbackSelection(), in: 5...180, step: 5) {
                    LabeledContent(L10n.text("settings.timeout"),
                                   value: L10n.format("settings.seconds", Int(settings.policy.timeout)))
                }
                Stepper(value: $settings.policy.retries.feedbackSelection(), in: 0...10) {
                    LabeledContent(L10n.text("settings.retries"), value: "\(settings.policy.retries)")
                }
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(L10n.text("settings.request_interval"),
                                   value: L10n.format("settings.interval.value", settings.policy.requestInterval))
                    Slider(value: $settings.policy.requestInterval, in: 0...30, step: 0.5) { editing in
                        if editing { requestIntervalBeforeEditing = settings.policy.requestInterval }
                        else {
                            let changed = requestIntervalBeforeEditing.map { $0 != settings.policy.requestInterval } ?? false
                            requestIntervalBeforeEditing = nil
                            if changed { AppFeedback.play(.selection) }
                        }
                    }
                }
                Toggle(L10n.text("settings.use_web_session"), isOn: $settings.policy.useWebSession.feedbackSelection())
            } header: {
                Text(L10n.text("settings.network.requests"))
            }

            Section {
                TextField(L10n.text("settings.proxy.placeholder"), text: $settings.policy.proxy)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.callout.monospaced())

                Toggle(L10n.text("settings.proxy.media"), isOn: $settings.policy.proxyMedia.feedbackSelection())

                Button {
                    checkProxy()
                } label: {
                    HStack {
                        Label(L10n.text("settings.proxy.check"), systemImage: "network")
                        Spacer()
                        if proxyCheck == .checking { ProgressView() }
                    }
                }
                .disabled(proxyCheck == .checking || settings.policy.proxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                switch proxyCheck {
                case .ok:
                    Label(L10n.text("settings.proxy.ok"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .idle, .checking:
                    EmptyView()
                }
            } header: {
                Text(L10n.text("settings.proxy"))
            }
        }
        .settingsPage(L10n.text("settings.group.network"))
        .animation(.snappy, value: proxyCheck)
    }

    private func checkProxy() {
        proxyCheck = .checking
        Task {
            do {
                _ = try NetworkPolicy.proxy(settings.policy.proxy)
                proxyCheck = .ok
                AppFeedback.play(.success)
            } catch {
                proxyCheck = .failed(error.localizedDescription)
                AppFeedback.play(.error)
            }
        }
    }
}

// MARK: - Interaction

private struct InteractionSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsScrollContainer {
            SettingsSectionBlock(header: L10n.text("settings.appearance"), grouped: false) {
                ChoiceCards(options: [
                    .init(value: "system", title: L10n.text("appearance.system"), systemImage: "circle.lefthalf.filled"),
                    .init(value: "light", title: L10n.text("appearance.light"), systemImage: "sun.max.fill"),
                    .init(value: "dark", title: L10n.text("appearance.dark"), systemImage: "moon.fill")
                ], selection: $settings.appearance.feedbackSelection())
            }

            SettingsSectionBlock(header: L10n.text("settings.group.interaction"),
                                 footer: L10n.text("settings.haptics.hint")) {
                SettingsCardRow {
                    Toggle(L10n.text("settings.keep_awake"), isOn: $settings.keepScreenAwake.feedbackSelection())
                        .tint(.coral)
                }
                SettingsRowDivider()
                SettingsCardRow {
                    Toggle(L10n.text("settings.haptics"), isOn: $settings.haptics.feedbackSelection())
                        .tint(.coral)
                        .accessibilityIdentifier("settings-haptics-toggle")
                }
                SettingsRowDivider()
                Menu {
                    Button(L10n.text("feedback.selection")) { AppFeedback.play(.selection) }
                    Button(L10n.text("feedback.confirmation")) { AppFeedback.play(.confirmation) }
                    Button(L10n.text("feedback.success")) { AppFeedback.play(.success) }
                    Button(L10n.text("feedback.warning")) { AppFeedback.play(.warning) }
                    Button(L10n.text("feedback.error")) { AppFeedback.play(.error) }
                } label: {
                    SettingsCardRow {
                        Label(L10n.text("settings.haptics.preview"), systemImage: "hand.tap")
                            .foregroundStyle(Color.coral)
                            .opacity(settings.haptics ? 1 : 0.4)
                    }
                    .contentShape(Rectangle())
                }
                .disabled(!settings.haptics)
                .accessibilityIdentifier("settings-haptics-preview")
            }

            SettingsSectionBlock(header: L10n.text("settings.system"),
                                 footer: L10n.text("notification.completed") + " · " + L10n.text("notification.failed")) {
                SettingsCardRow {
                    Toggle(L10n.text("settings.notifications"), isOn: $settings.notifications.feedbackSelection())
                        .tint(.coral)
                }
                SettingsRowDivider()
                SettingsCardRow {
                    Toggle(L10n.text("settings.debug_notifications"), isOn: $settings.debugNotifications.feedbackSelection())
                        .tint(.coral)
                }
            }
        }
        .settingsPage(L10n.text("settings.group.interaction"))
    }
}

// MARK: - Storage

private struct StorageSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: DownloadCoordinator
    @State private var storage = StorageUsage()
    @State private var exportFile: ExportFile?
    @State private var showsBackupImporter = false
    @State private var backupSummary: BackupImportSummary?
    @State private var isWorking = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bytes(storage.total))
                            .font(.title2.weight(.bold).monospacedDigit())
                            .contentTransition(.numericText())
                        Spacer()
                        Text(L10n.text("settings.storage.used"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    UsageBar(segments: [(storage.previews, .coral), (storage.avatars, .orange), (storage.pending, .blue)])
                    HStack(spacing: 14) {
                        legend(L10n.text("settings.storage.previews"), storage.previews, .coral)
                        legend(L10n.text("settings.storage.avatars"), storage.avatars, .orange)
                        legend(L10n.text("settings.storage.pending"), storage.pending, .blue)
                    }
                }
                .padding(.vertical, 6)

                Button {
                    Task {
                        await BackupService.shared.clearPreviews()
                        await refreshStorage()
                        statusMessage = L10n.text("settings.storage.cleared")
                        AppFeedback.play(.success)
                    }
                } label: {
                    Label(L10n.text("settings.storage.clear_previews"), systemImage: "trash")
                }
            } header: {
                Text(L10n.text("settings.group.storage"))
            }

            Section {
                Menu {
                    Button(L10n.text("settings.storage.export_json")) { export(.json) }
                    Button(L10n.text("settings.storage.export_csv")) { export(.csv) }
                        .disabled(coordinator.tasks.isEmpty)
                    Button(L10n.text("settings.storage.export_zip")) { export(.zip) }
                } label: {
                    HStack {
                        Label(L10n.text("settings.storage.export"), systemImage: "square.and.arrow.up.on.square")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }
                .disabled((coordinator.tasks.isEmpty && coordinator.notes.isEmpty) || isWorking)

                Button {
                    showsBackupImporter = true
                } label: {
                    Label(L10n.text("settings.storage.import"), systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(isWorking)

                if let backupSummary {
                    Label(L10n.format("settings.storage.imported", backupSummary.added,
                                      backupSummary.merged, backupSummary.skipped),
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } header: {
                Text(L10n.text("settings.storage.backup"))
            }
        }
        .settingsPage(L10n.text("settings.group.storage"))
        .task { await refreshStorage() }
        .onChange(of: showsBackupImporter) { _, shown in if shown { AppFeedback.play(.navigation) } }
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
        .fileImporter(isPresented: $showsBackupImporter, allowedContentTypes: [backupType]) { result in
            handleImport(result)
        }
        .settingsAlert($statusMessage)
    }

    private var backupType: UTType {
        UTType(filenameExtension: BackupDocument.fileExtension) ?? .data
    }

    private func legend(_ title: String, _ value: Int64, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(bytes(value)).font(.caption.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func refreshStorage() async {
        let usage = await SettingsView.loadStorage()
        withAnimation(.smooth) { storage = usage }
    }

    private enum ExportKind { case json, csv, zip }

    private func export(_ kind: ExportKind) {
        isWorking = true
        AppFeedback.play(.confirmation)
        let tasks = coordinator.tasks
        let notes = coordinator.notes
        Task {
            defer { isWorking = false }
            do {
                let url: URL
                switch kind {
                case .json:
                    var payload = BackupService.BackupLibraryPayload()
                    payload.notes = notes
                    payload.collections = coordinator.collections
                    payload.likedNotes = coordinator.likedNotes
                    payload.bookmarkedNotes = coordinator.bookmarkedNotes
                    payload.authorRemarks = coordinator.authorRemarks
                    payload.settings = coordinator.exportSettingsSnapshot()
                    url = try await BackupService.shared.exportJSON(tasks: tasks, library: payload)
                case .csv:
                    url = try await BackupService.shared.exportCSV(tasks)
                case .zip:
                    let archive = try await BackupService.shared.exportArchive(notes)
                    url = archive.url
                    if !archive.failures.isEmpty {
                        // An incomplete archive is still offered, but never
                        // presented as a complete export.
                        statusMessage = L10n.format("backup.error.missing", archive.failures.count)
                        AppFeedback.play(.warning)
                    }
                }
                exportFile = ExportFile(url: url)
            } catch {
                statusMessage = error.localizedDescription
                AppFeedback.play(.error)
            }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            isWorking = true
            backupSummary = nil
            Task {
                defer { isWorking = false }
                do {
                    let document = try await BackupService.shared.importBackup(from: url)
                    let summary = try await coordinator.applyBackup(document)
                    backupSummary = summary
                    AppFeedback.play(.success)
                } catch {
                    statusMessage = error.localizedDescription
                    AppFeedback.play(.error)
                }
            }
        case .failure(let error as CocoaError) where error.code == .userCancelled:
            break
        case .failure(let error):
            statusMessage = error.localizedDescription
            AppFeedback.play(.error)
        }
    }

    private struct UsageBar: View {
        let segments: [(Int64, Color)]
        var body: some View {
            GeometryReader { proxy in
                let total = max(segments.map(\.0).reduce(0, +), 1)
                HStack(spacing: 2) {
                    ForEach(segments.indices, id: \.self) { index in
                        let value = segments[index].0
                        if value > 0 {
                            Capsule()
                                .fill(segments[index].1.gradient)
                                .frame(width: max(4, proxy.size.width * CGFloat(value) / CGFloat(total)))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .frame(height: 10)
            .clipShape(Capsule())
            .accessibilityHidden(true)
        }
    }
}

// MARK: - About

private struct AboutSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: DownloadCoordinator
    @ObservedObject private var session = WebSession.shared
    @State private var isCheckingUpdate = false
    @State private var isWorking = false
    @State private var exportFile: ExportFile?
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 80, height: 80)
                        .background(.coralGradient, in: RoundedRectangle(cornerRadius: 21.6, style: .continuous))
                        .shadow(color: .coral.opacity(0.28), radius: 14, y: 6)
                    Text(L10n.text("app.title"))
                        .font(.title3.weight(.bold))
                    Text(SettingsView.versionString)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Link(destination: URL(string: "https://github.com/MiohalationM/XHS_Downloader_iOS")!) {
                    Label(L10n.text("settings.github"), systemImage: "link")
                }
                Link(destination: URL(string: "https://github.com/MiohalationM/XHS_Downloader_iOS/releases")!) {
                    Label(L10n.text("settings.about.release_notes"), systemImage: "doc.text")
                }
                Button {
                    Task { await checkForUpdates() }
                } label: {
                    HStack {
                        Label {
                            Text(L10n.text("settings.about.check_update"))
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .symbolEffect(.rotate, isActive: isCheckingUpdate)
                        }
                        Spacer()
                        if isCheckingUpdate { ProgressView() }
                    }
                }
                .disabled(isCheckingUpdate)
                Button {
                    Task { await exportDiagnostics() }
                } label: {
                    Label(L10n.text("settings.about.diagnostics"), systemImage: "stethoscope")
                }
                .disabled(isWorking)
            }
        }
        .settingsPage(L10n.text("settings.about"))
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
        .settingsAlert($statusMessage)
    }

    /// Diagnostics must never leak credentials: cookies, proxy credentials and
    /// absolute private paths are stripped before the report is written.
    private func exportDiagnostics() async {
        isWorking = true
        defer { isWorking = false }
        var lines: [String] = []
        lines.append("XHS Downloader \(SettingsView.versionString)")
        lines.append("iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)")
        lines.append("tasks=\(coordinator.tasks.count) waiting=\(coordinator.waitingCount) failed=\(coordinator.failedCount)")
        lines.append("notes=\(coordinator.notes.count) noteMedia=\(coordinator.notes.flatMap(\.mediaAssets).count) loaded=\(coordinator.isLoaded) loadFailed=\(coordinator.loadError != nil)")
        let policy = settings.policy
        lines.append("destination=\(policy.destination.rawValue) image=\(policy.imageFormat.rawValue) video=\(policy.videoPreference.rawValue)")
        lines.append("captions=\(policy.captionFormat.rawValue) naming=\(policy.namingEnabled)")
        lines.append("timeout=\(Int(policy.timeout)) retries=\(policy.retries) interval=\(policy.requestInterval)")
        lines.append("proxy=\(policy.proxy.isEmpty ? "none" : "configured") mediaProxy=\(policy.proxyMedia)")
        lines.append("account=\(session.account == nil ? "signed-out" : "signed-in")")
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xhs-diagnostics-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            exportFile = ExportFile(url: file)
        } catch {
            statusMessage = error.localizedDescription
            AppFeedback.play(.error)
        }
    }

    /// Reads the published release tag instead of claiming the build is current.
    /// A failed or offline check reports that it could not verify.
    private func checkForUpdates() async {
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        guard let url = URL(string: "https://api.github.com/repos/MiohalationM/XHS_Downloader_iOS/releases/latest") else {
            statusMessage = L10n.text("settings.about.update_unknown")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String else {
                statusMessage = L10n.text("settings.about.update_unknown")
                AppFeedback.play(.warning)
                return
            }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            statusMessage = SettingsView.isVersion(latest, newerThan: current)
                ? L10n.format("settings.about.update_available", latest)
                : L10n.text("settings.about.up_to_date")
            AppFeedback.play(.success)
        } catch {
            statusMessage = L10n.text("settings.about.update_unknown")
            AppFeedback.play(.warning)
        }
    }
}

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
