import Foundation

enum ImagePreference: String, Codable, CaseIterable, Sendable { case original, jpeg, png, webp, heic, avif }
enum VideoPreference: String, Codable, CaseIterable, Sendable { case original, resolution, bitrate, size, compatibility }
enum SaveDestination: String, Codable, CaseIterable, Sendable { case photos, files, both }
enum CaptionFormat: String, Codable, CaseIterable, Sendable { case none, txt, markdown, both }
enum MediaRole: String, Codable, Sendable { case body, cover, comment }

struct MediaVariant: Codable, Hashable, Sendable, Identifiable {
    var url: URL
    var backups: [URL] = []
    var codec: String?
    var width: Int?
    var height: Int?
    var bitrate: Int?
    var byteCount: Int64?
    var isOriginal: Bool = false
    var isKnownWatermarked: Bool?
    var id: String { url.absoluteString }
    var label: String {
        [isOriginal ? L10n.text("policy.original") : nil, height.map { "\($0)p" }, codec?.uppercased(),
         byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct DownloadPolicy: Codable, Hashable, Sendable {
    var imageFormat: ImagePreference = .original
    var videoPreference: VideoPreference = .original
    var images = true
    var videos = true
    var covers = false
    var comments = false
    var destination: SaveDestination = .photos
    var captionFormat: CaptionFormat = .none
    var authorDirectories = false
    var noteDirectories = false
    var skipExisting = false
    var writePublishTime = false
    var timeout: Double = 45
    var retries = 3
    var requestInterval: Double = 2
    var proxy = ""
    var proxyMedia = false
    var useWebSession = true
    var filesBookmark: Data?
    var namingEnabled = false
    var namingTemplate = NamingFormatter.defaultTemplate
    var namingTimezone = TimeZone.current.identifier

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "download.policy"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "download.policy") }
    }
    func includes(_ media: RemoteMedia) -> Bool {
        switch media.role ?? .body {
        case .cover: return covers
        case .comment: return comments
        case .body: return media.isVideo ? videos : images
        }
    }
}

/// One resource can be requested for Photos, for Files, or for both, and those
/// two destinations fail independently. Keeping one result per destination is
/// what makes "the folder was unavailable but the photo is in the library"
/// representable, and what lets a retry fill in only the missing half.
struct DestinationResult: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case pending, saved, failed, skipped, unavailable }
    var state: State = .pending
    /// Photos local identifier, or an absolute path for the Files destination.
    var reference: String?
    var error: String?
    var byteCount: Int64?

    var isSettled: Bool { state == .saved || state == .skipped }
}

/// A Live Photo has two independent truths: whether the original components are
/// safely stored, and whether they were actually paired into a native Live Photo.
/// Collapsing them into one boolean is what let a failed merge look finished.
enum LivePhotoOutcome: String, Codable, Sendable {
    case merged
    case componentsOnly
}

struct ResourceResult: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case queued, downloading, saving, saved, failed, skipped }
    var state: State = .queued
    var received: Int64 = 0
    var expected: Int64 = 0
    var speed: Double = 0
    var error: String?
    var selectedVariant: String?
    var photos: DestinationResult?
    var files: DestinationResult?
    var livePhotoOutcome: LivePhotoOutcome?

    /// A resource is finished only when every destination the policy asked for
    /// is settled, and a requested merge actually produced a Live Photo.
    func isSatisfied(photosRequired: Bool, filesRequired: Bool, mergeRequired: Bool) -> Bool {
        if photosRequired, photos?.isSettled != true { return false }
        if filesRequired, files?.isSettled != true { return false }
        if mergeRequired, livePhotoOutcome != .merged { return false }
        return true
    }
}

extension RemoteMedia {
    func applying(_ policy: DownloadPolicy, variantID: String? = nil) -> RemoteMedia {
        var result = self
        if isVideo, let variants, !variants.isEmpty {
            let ordered: [MediaVariant]
            if let variantID, let chosen = variants.first(where: { $0.id == variantID }) {
                ordered = [chosen] + variants.filter { $0.id != variantID }
            } else {
                ordered = variants.sorted { a, b in
                    if (a.isKnownWatermarked == true) != (b.isKnownWatermarked == true) {
                        return b.isKnownWatermarked == true
                    }
                    switch policy.videoPreference {
                    case .original:
                        if a.isOriginal != b.isOriginal { return a.isOriginal }
                        return (a.height ?? 0) > (b.height ?? 0)
                    case .resolution: return (a.height ?? 0, a.bitrate ?? 0) > (b.height ?? 0, b.bitrate ?? 0)
                    case .bitrate: return (a.bitrate ?? 0) > (b.bitrate ?? 0)
                    case .size: return (a.byteCount ?? .max) < (b.byteCount ?? .max)
                    case .compatibility:
                        let ac = a.codec?.lowercased() == "h264", bc = b.codec?.lowercased() == "h264"
                        return ac != bc ? ac : (a.height ?? 0) > (b.height ?? 0)
                    }
                }
            }
            result.candidates = ordered.flatMap { [$0.url] + $0.backups }
            result.url = result.candidates.first ?? url
        } else if type == .image, policy.imageFormat != .original, let fileKey,
                  var components = URLComponents(string: "https://ci.xiaohongshu.com/\(fileKey)") {
            components.percentEncodedQuery = "imageView2/format/\(policy.imageFormat.rawValue)"
            if let requested = components.url {
                result.candidates = [requested] + candidates
                result.url = requested
            }
        }
        return result
    }
}
