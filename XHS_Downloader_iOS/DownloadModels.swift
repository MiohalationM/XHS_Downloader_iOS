import Foundation
import Combine
import UIKit
import SwiftData
import UserNotifications

enum TaskStatus: String, Codable, CaseIterable {
    case queued = "QUEUED"
    case downloading = "DOWNLOADING"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case waitingForUser = "WAITING_FOR_USER"
    case paused = "PAUSED"
    case cancelled = "CANCELLED"
    case partial = "PARTIAL"

    var localizationKey: String {
        switch self {
        case .queued: return "status.queued"
        case .downloading: return "status.downloading"
        case .completed: return "status.completed"
        case .failed: return "status.failed"
        case .waitingForUser: return "status.waiting"
        case .paused: return "status.paused"
        case .cancelled: return "status.cancelled"
        case .partial: return "status.partial"
        }
    }
}

enum NoteType: String, Codable {
    case image
    case video
    case livePhoto
    case mixed
    case unknown

    var localizationKey: String {
        switch self {
        case .image: return "note.type.image"
        case .video: return "note.type.video"
        case .livePhoto: return "note.type.live_photo"
        case .mixed: return "note.type.mixed"
        case .unknown: return "note.type.unknown"
        }
    }
}

struct MediaAssetRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var sourceMediaID: String?
    var localIdentifier: String
    var fileName: String
    var isVideo: Bool
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteCount: Int64?
    var createdAt: Date
    var filesPaths: [String]?
    var contentType: String?
    var isLive: Bool?

    var archivePaths: [String] {
        if let filesPaths, !filesPaths.isEmpty { return filesPaths }
        return ArchiveAccess.paths(in: localIdentifier)
    }

    init(
        id: UUID = UUID(),
        localIdentifier: String,
        fileName: String,
        isVideo: Bool,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        byteCount: Int64? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.fileName = fileName
        self.isVideo = isVideo
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}

struct DownloadTaskRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var sourceText: String
    var importRequestID: UUID?
    var resolvedNote: ResolvedNote?
    var stagedFiles: [String: String]?
    var selectedMediaIDs: [String]?
    var draftSelectionIDs: [String]?
    var livePhotoMode: LivePhotoMode?
    var completedMediaIDs: [String]?
    var selectionRequired: Bool?
    var livePhotoEnabled: Bool?
    var normalizedURL: String
    var title: String
    var noteText: String
    var noteType: NoteType
    var status: TaskStatus
    var progress: Double
    var transferredBytes: Int64?
    var expectedBytes: Int64?
    var bytesPerSecond: Double?
    var mediaCount: Int
    var savedCount: Int
    var failedCount: Int
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
    var mediaAssets: [MediaAssetRecord]
    var policy: DownloadPolicy?
    var informationOnly: Bool?
    var historyHidden: Bool?
    var libraryHidden: Bool?
    var phase: String?
    var resourceResults: [String: ResourceResult]?
    var selectedVariants: [String: String]?
    var downloadInstant: Date?
    var archiveTextPaths: [String]?
    /// Media slots that were submitted, captured before parsing. This is what a
    /// resumed task re-renders against, so an expired URL cannot change the
    /// expected resource set.
    var submittedMediaIDs: [String]?
    /// Identity of the note this task belongs to. The library stores notes
    /// independently, and this is the join key that survives removing history.
    var noteKey: String?

    init(
        id: UUID = UUID(),
        sourceText: String,
        normalizedURL: String,
        title: String = "",
        noteText: String = "",
        noteType: NoteType = .unknown,
        status: TaskStatus = .queued,
        progress: Double = 0,
        mediaCount: Int = 0,
        savedCount: Int = 0,
        failedCount: Int = 0,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        mediaAssets: [MediaAssetRecord] = []
    ) {
        self.id = id
        self.sourceText = sourceText
        self.normalizedURL = normalizedURL
        self.title = title
        self.noteText = noteText
        self.noteType = noteType
        self.status = status
        self.progress = progress
        self.mediaCount = mediaCount
        self.savedCount = savedCount
        self.failedCount = failedCount
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.mediaAssets = mediaAssets
    }
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case all
    case waiting
    case failed

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .all: return "filter.all"
        case .waiting: return "filter.waiting"
        case .failed: return "filter.failed"
        }
    }
}

/// A coarse, user-facing phase. `TaskStatus` says whether work is allowed to
/// continue; the phase says what it is doing right now, which is what a card
/// needs to explain "解析中" versus "保存中".
enum TaskPhase: String, Codable, Sendable {
    case resolving, waitingSelection, transferring, saving, archiving, finished

    var localizationKey: String { "phase." + rawValue }
}

struct TaskFocus: Identifiable, Hashable {
    let id: UUID
}

/// Routes a tapped notification into the task centre. iOS delivers the tap to
/// the delegate before the scene is guaranteed to be active, so the coordinator
/// only records the request and the UI presents it when it can.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    weak var coordinator: DownloadCoordinator?

    func install(coordinator: DownloadCoordinator) {
        self.coordinator = coordinator
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["task"] as? String,
              let id = UUID(uuidString: value) else { return }
        await MainActor.run { coordinator?.focus(taskID: id) }
    }
}

/// The task centre reads as three questions, so the list groups by the answer
/// rather than by raw status: what is moving, what needs the user, what is done.
enum TaskGroup: String, CaseIterable, Identifiable {
    case active
    case waiting
    case finished

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .active: return "task.group.active"
        case .waiting: return "task.group.waiting"
        case .finished: return "task.group.finished"
        }
    }

    func contains(_ task: DownloadTaskRecord) -> Bool {
        switch self {
        case .active:
            return [.downloading, .queued].contains(task.status)
        case .waiting:
            return [.waitingForUser, .paused, .failed, .partial, .cancelled].contains(task.status)
        case .finished:
            return task.status == .completed
        }
    }
}

enum SelectiveDownloadPhase: Equatable {
    case caching
    case ready
    case saving
    case error(String)
}

struct SelectiveMediaItem: Identifiable {
    let id: UUID
    let remote: RemoteMedia
    let cachedURL: URL
    var isSelected: Bool
}

struct SelectiveDownloadState: Identifiable {
    let id: UUID
    let taskID: UUID
    var phase: SelectiveDownloadPhase
    var items: [SelectiveMediaItem]

    init(taskID: UUID, phase: SelectiveDownloadPhase, items: [SelectiveMediaItem]) {
        self.id = taskID
        self.taskID = taskID
        self.phase = phase
        self.items = items
    }
}

enum XHSURLDetector {
    private static let expression = try! NSRegularExpression(
        pattern: ImportText.linkPattern,
        options: [.caseInsensitive]
    )

    static func extract(from input: String) -> [String] {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var seen = Set<String>()
        return expression.matches(in: input, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: input) else { return nil }
            var value = String(input[swiftRange])
            while let last = value.last, ".,;:!?)]}".contains(last) { value.removeLast() }
            if !value.lowercased().hasPrefix("http") { value = "https://" + value }
            guard let url = URL(string: value), let host = url.host?.lowercased() else { return nil }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = host
            value = components?.url?.absoluteString ?? value
            guard seen.insert(value).inserted else { return nil }
            return value
        }
    }

    static func first(from input: String) -> String? {
        extract(from: input).first
    }

    static func containsSupportedLink(_ input: String) -> Bool {
        first(from: input) != nil
    }

    static func noteID(from url: URL) -> String? {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["xiaohongshu.com", "www.xiaohongshu.com", "rednote.com", "www.rednote.com"]
                .contains(url.host?.lowercased() ?? "") else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        let isNote = (path.count == 2 && path.first == "explore") ||
            (path.count == 3 && path[0] == "discovery" && path[1] == "item")
        guard isNote, let id = path.last, id.utf8.count == 24,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return id
    }

    static func linksMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard let leftURL = URL(string: lhs), let rightURL = URL(string: rhs) else { return false }
        if let leftID = noteID(from: leftURL), let rightID = noteID(from: rightURL) {
            return leftID == rightID
        }
        return leftURL.host?.lowercased() == rightURL.host?.lowercased()
            && leftURL.path == rightURL.path
            && leftURL.query == rightURL.query
    }
}

enum LivePhotoMode: String, Codable, CaseIterable, Sendable {
    case merged, separate, still
    var localizationKey: String { "live.mode." + rawValue }
}

@MainActor
final class AppSettings: ObservableObject {
    enum Key {
        static let createLivePhotos = "create_live_photos"
        static let selectiveDownload = "selective_download"
        static let debugNotifications = "debug_notifications"
        static let keepScreenAwake = "keep_screen_awake"
        static let clipboardSuggestions = "clipboard_suggestions"
    }

    /// Exposed so the coordinator persists library preferences and migration
    /// markers into the same store this instance reads.
    let defaults: UserDefaults

    @Published var policy: DownloadPolicy {
        didSet {
            policy.save(defaults: defaults)
            // The policy is the single source of truth for naming. Mirror it to
            // the legacy keys so ad-hoc resolves and older builds stay in sync.
            defaults.set(policy.namingEnabled, forKey: NamingPreferences.enableKey)
            defaults.set(policy.namingTemplate, forKey: NamingPreferences.templateKey)
            defaults.set(policy.namingTimezone, forKey: NamingPreferences.timezoneKey)
        }
    }
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: "completion.notifications") } }
    @Published var haptics: Bool {
        didSet {
            defaults.set(haptics, forKey: FeedbackPreference.key)
            if defaults === UserDefaults.standard {
                if oldValue != haptics { AppFeedback.invalidatePendingFeedback() }
                FeedbackPreference.synchronizeExtension(haptics)
            }
        }
    }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }

    @Published var livePhotoMode: LivePhotoMode { didSet { defaults.set(livePhotoMode.rawValue, forKey: "live_photo_mode") } }
    var createLivePhotos: Bool { livePhotoMode == .merged }
    @Published var selectiveDownload: Bool { didSet { defaults.set(selectiveDownload, forKey: Key.selectiveDownload) } }
    @Published var debugNotifications: Bool { didSet { defaults.set(debugNotifications, forKey: Key.debugNotifications) } }
    @Published var keepScreenAwake: Bool {
        didSet {
            defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake)
        }
    }
    @Published var clipboardSuggestions: Bool { didSet { defaults.set(clipboardSuggestions, forKey: Key.clipboardSuggestions) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = DownloadPolicy.load(defaults: defaults)
        // Adopt naming settings saved by the pre-policy UI so an upgrade does not
        // silently lose a custom template.
        if let legacyTemplate = defaults.string(forKey: NamingPreferences.templateKey),
           !legacyTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loaded.namingTemplate = legacyTemplate
        }
        loaded.namingEnabled = defaults.object(forKey: NamingPreferences.enableKey) as? Bool
            ?? loaded.namingEnabled
        if let legacyZone = defaults.string(forKey: NamingPreferences.timezoneKey) {
            loaded.namingTimezone = legacyZone
        }
        policy = loaded
        notifications = defaults.bool(forKey: "completion.notifications")
        haptics = FeedbackPreference.isEnabled(in: defaults)
        appearance = defaults.string(forKey: "appearance") ?? "system"
        let legacyLive = defaults.object(forKey: Key.createLivePhotos) as? Bool ?? true
        livePhotoMode = defaults.string(forKey: "live_photo_mode").flatMap(LivePhotoMode.init(rawValue:)) ?? (legacyLive ? .merged : .separate)
        selectiveDownload = defaults.object(forKey: Key.selectiveDownload) as? Bool ?? false
        debugNotifications = defaults.object(forKey: Key.debugNotifications) as? Bool ?? false
        keepScreenAwake = defaults.object(forKey: Key.keepScreenAwake) as? Bool ?? false
        clipboardSuggestions = defaults.object(forKey: Key.clipboardSuggestions) as? Bool ?? true
        if defaults === UserDefaults.standard { FeedbackPreference.synchronizeExtension(haptics) }
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

protocol DownloadTaskStoring: Sendable {
    var fileURL: URL { get }
    var loadError: String? { get async }
    func load() async -> [DownloadTaskRecord]
    func save(_ tasks: [DownloadTaskRecord]) async throws
}

actor DownloadTaskStore: DownloadTaskStoring {
    nonisolated let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var repository: TaskRepository?
    private let databaseURL: URL?
    private var didOpen = false
    private var repositoryError: Error?
    private(set) var loadError: String?

    init(fileURL: URL? = nil, databaseURL: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        if let fileURL {
            self.fileURL = fileURL
            self.databaseURL = databaseURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = support.appendingPathComponent("XHSDownloader", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("download-tasks.json")
            self.databaseURL = directory.appendingPathComponent("Library-v1.store")
        }
    }

    private func openRepository() throws {
        guard !didOpen else { return }
        didOpen = true
        guard let databaseURL else { return }
        do {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let configuration = ModelConfiguration(url: databaseURL)
            let container = try ModelContainer(for: StoredDownloadTask.self, RepositoryMarker.self, configurations: configuration)
            repository = TaskRepository(modelContainer: container)
        } catch {
            repositoryError = error
            throw error
        }
    }

    func load() async -> [DownloadTaskRecord] {
        do {
            try openRepository()
            if let repository {
                let legacy = fileURL
                return try await repository.load(legacyURL: legacy)
            }
            if let repositoryError { throw repositoryError }
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            return try decoder.decode([DownloadTaskRecord].self, from: Data(contentsOf: fileURL))
        } catch {
            loadError = error.localizedDescription
            repositoryError = error
            // Keep legacy data readable, but refuse writes until migration can
            // succeed; never replace an unreadable database with an empty one.
            return (try? decoder.decode([DownloadTaskRecord].self, from: Data(contentsOf: fileURL))) ?? []
        }
    }

    func save(_ tasks: [DownloadTaskRecord]) async throws {
        try openRepository()
        if let repositoryError { throw repositoryError }
        if let repository {
            try await repository.replace(tasks)
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(tasks)
        let backup = fileURL.deletingPathExtension().appendingPathExtension("legacy-backup.json")
        if FileManager.default.fileExists(atPath: fileURL.path), !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: fileURL, to: backup)
        }
        try data.write(to: fileURL, options: [.atomic])
    }
}
