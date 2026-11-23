//
//  XHSDownloader.swift
//  XHS_Downloader_iOS
//
//  Created by Codex on behalf of user.
//

import Foundation
import JavaScriptCore

struct RemoteMedia: Identifiable, Hashable, Codable, Sendable {
    enum MediaType: String, Codable, Sendable { case image, video, livePhoto }
    let id: UUID
    let stableID: String
    var url: URL
    let type: MediaType
    var fileBaseName: String
    let originalURLString: String
    var candidates: [URL]
    let previewURL: URL?
    let pairedVideoURLs: [URL]
    let width: Int?
    let height: Int?
    var role: MediaRole?
    var variants: [MediaVariant]?
    var fileKey: String?

    init(id: UUID = UUID(), stableID: String? = nil, url: URL, type: MediaType,
         fileBaseName: String, originalURLString: String, candidates: [URL] = [],
         previewURL: URL? = nil, pairedVideoURLs: [URL] = [], width: Int? = nil, height: Int? = nil) {
        self.id = id
        self.stableID = stableID ?? fileBaseName
        self.url = url
        self.type = type
        self.fileBaseName = fileBaseName
        self.originalURLString = originalURLString
        self.candidates = candidates.isEmpty ? [url] : candidates
        self.previewURL = previewURL
        self.pairedVideoURLs = pairedVideoURLs
        self.width = width
        self.height = height
    }
    var isVideo: Bool { type == .video }
}

struct MediaDescriptor {
    let url: String
    let metadata: NoteMetadata
}

enum XHSDownloaderError: LocalizedError {
    case invalidURL
    case requestFailed
    case permissionDenied
    case missingLinks
    case parsingFailed
    case emptyMedia

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L10n.text("error.invalid_url")
        case .requestFailed:
            return L10n.text("error.request_failed")
        case .permissionDenied:
            return L10n.text("error.permission")
        case .missingLinks:
            return L10n.text("error.no_link")
        case .parsingFailed:
            return L10n.text("error.parsing")
        case .emptyMedia:
            return L10n.text("error.empty_media")
        }
    }
}

final class XHSDownloader {
    typealias LogHandler = @Sendable (String) async -> Void

    private let session: URLSession
    private let mediaSession: URLSession
    /// Background transfers only apply to the app's own session. An injected
    /// session (tests, previews) must never be bypassed by the shared background
    /// queue, which would ignore it entirely.
    private let allowsBackgroundTransfers: Bool
    /// Exposed so a coordinator can rebuild a downloader for another policy
    /// snapshot without discarding an injected transport.
    var exposedSession: URLSession { session }
    let policy: DownloadPolicy
    /// Pacing is shared by every downloader that a coordinator creates, so the
    /// configured interval also applies between consecutive tasks rather than
    /// resetting to zero for each new task.
    let pacer: RequestPacer
    // App-share short links can redirect desktop clients to the home page,
    // losing both the note ID and its access token before parsing even begins.
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private let xhsLinkRegex = try! NSRegularExpression(pattern: "(?:https?://)?www\\.xiaohongshu\\.com/explore/\\S+", options: .caseInsensitive)
    private let xhsUserRegex = try! NSRegularExpression(pattern: "(?:https?://)?www\\.xiaohongshu\\.com/user/profile/[a-z0-9]+/\\S+", options: .caseInsensitive)
    private let xhsShareRegex = try! NSRegularExpression(pattern: "(?:https?://)?www\\.xiaohongshu\\.com/discovery/item/\\S+", options: .caseInsensitive)
    private let xhsShortRegex = try! NSRegularExpression(pattern: "(?:https?://)?xhslink\\.(?:com|cn)/[^\\s\\\"<>\\\\^`{|}，。；！？、【】《》]+", options: .caseInsensitive)
    private let idRegex = try! NSRegularExpression(pattern: "(?:explore|item)/([a-zA-Z0-9_\\-]+)/?(?:\\?|$)", options: .caseInsensitive)
    private let idUserRegex = try! NSRegularExpression(pattern: "user/profile/[a-z0-9]+/([a-zA-Z0-9_\\-]+)/?(?:\\?|$)", options: .caseInsensitive)
    private let htmlImgRegex = try! NSRegularExpression(pattern: "<img[^>]+src\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"][^>]*>", options: .caseInsensitive)
    private let htmlUrlRegex = try! NSRegularExpression(pattern: "https?://[\\w\\-._~:/?#\\[\\]@!$&'()*+,;=%]+\\.(?:jpg|jpeg|png|gif|mp4|avi|mov|webm|wmv|flv|f4v|swf|mpg|mpeg|asf|3gp|3g2|mkv|webp|heic|heif)", options: .caseInsensitive)

    private static let publishFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yy-MM-dd"
        return formatter
    }()

    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let compactDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    init(session: URLSession? = nil, policy: DownloadPolicy = .load(), pacer: RequestPacer = RequestPacer()) {
        self.policy = policy
        self.pacer = pacer
        self.allowsBackgroundTransfers = session == nil
        if let session {
            self.session = session
            self.mediaSession = session
        } else {
            let configuration = (try? NetworkPolicy.configuration(policy)) ?? URLSessionConfiguration.default
            self.session = URLSession(configuration: configuration)
            self.mediaSession = URLSession(configuration:
                (try? NetworkPolicy.configuration(policy, media: true)) ?? URLSessionConfiguration.default)
        }
    }

    func collectMedia(from input: String, logger: @escaping LogHandler) async throws -> [RemoteMedia] {
        var result: [RemoteMedia] = []
        for link in XHSURLDetector.extract(from: input) {
            result += try await resolveNote(from: link).media
        }
        return result
    }

    func makeSessionTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        return formatter.string(from: Date())
    }

    func download(media: RemoteMedia, sessionTimestamp _: String, transferIdentity: String? = nil, progress: @escaping @Sendable (BackgroundTransfers.Progress) -> Void = { _ in }) async throws -> URL {
        // Invalid settings must surface before any request; a fallback session
        // must never silently send a user-configured proxy request directly.
        if policy.proxyMedia { _ = try NetworkPolicy.proxy(policy.proxy) }
        var lastError: Error = XHSDownloaderError.requestFailed
        for candidate in media.candidates {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: candidate)
                request.timeoutInterval = min(180, max(5, policy.timeout))
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                let temporary: URL
                let response: URLResponse
                // Background transfers cannot carry a proxy configuration, so a
                // proxied media request is deliberately sent through the regular
                // session rather than silently bypassing the user's proxy.
                let useBackground = allowsBackgroundTransfers && transferIdentity != nil
                    && BackgroundTransfers.shared.supportsProxy(policy.proxyMedia && !policy.proxy.isEmpty)
                if useBackground, let transferIdentity {
                    (temporary, response) = try await BackgroundTransfers.shared.download(request, identity: transferIdentity, progress: progress)
                } else { (temporary, response) = try await mediaSession.download(for: request) }
                defer {
                    try? FileManager.default.removeItem(at: temporary)
                    if transferIdentity != nil {
                        try? FileManager.default.removeItem(at: temporary.deletingPathExtension().appendingPathExtension("response"))
                    }
                }
                try Task.checkCancellation()
                let ext = try await MediaFileValidator.validate(temporary, response: response, isVideo: media.isVideo)
                let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Transfers", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("\(UUID().uuidString)_\(media.fileBaseName).\(ext)")
                try FileManager.default.moveItem(at: temporary, to: destination)
                return destination
            } catch is CancellationError { throw CancellationError() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }

}

// MARK: - Private helpers

extension XHSDownloader {
    struct LinkContext {
        let sourceURL: URL
        let resolvedURL: URL
        let postId: String?
    }

    func extractLinkStrings(from input: String) -> [String] { XHSURLDetector.extract(from: input) }

    func match(in text: String, regex: NSRegularExpression) -> String? {
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let result = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        return (text as NSString).substring(with: result.range)
    }

    func prepareContext(for raw: String, logger: LogHandler) async throws -> LinkContext? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if !cleaned.lowercased().hasPrefix("http") {
            cleaned = "https://" + cleaned
        }
        guard let originalURL = URL(string: cleaned) else { return nil }

        var resolvedURL = originalURL
        if cleaned.contains("xhslink.com") || cleaned.contains("xhslink.cn") {
            if let redirect = await resolveShortLink(originalURL) {
                resolvedURL = redirect
                await logger("短链接已解析为：\(redirect.absoluteString)")
            } else {
                await logger("短链接解析失败，尝试直接使用原链接")
            }
        }

        if let host = resolvedURL.host?.lowercased(),
           ["xiaohongshu.com", "rednote.com"].contains(host) {
            var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false)
            components?.host = "www." + host
            resolvedURL = components?.url ?? resolvedURL
        }
        let postId = extractPostId(from: resolvedURL.absoluteString)
        return LinkContext(sourceURL: originalURL, resolvedURL: resolvedURL, postId: postId)
    }

    func resolveShortLink(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent + " xiaohongshu", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        applySessionCookies(to: &request)
        do {
            _ = try NetworkPolicy.proxy(policy.proxy)
            try await pacer.wait(interval: policy.requestInterval)
            let (_, response) = try await session.data(for: request)
            return response.url
        } catch {
            return nil
        }
    }

    private func applySessionCookies(to request: inout URLRequest) {
        request.httpShouldHandleCookies = policy.useWebSession
        guard policy.useWebSession, let url = request.url else { return }
        if let host = url.host, WebSession.trusted(host) {
            let base = host.contains("rednote") ? "www.rednote.com" : "www.xiaohongshu.com"
            let manual = SessionVault.cookie(base)
            if !manual.isEmpty {
                request.setValue(manual, forHTTPHeaderField: "Cookie")
                return
            }
        }
        // The cookie store selects by domain, path and secure flag. In
        // particular, never transplant a RedNote cookie onto a short-link host.
        if let cookies = session.configuration.httpCookieStorage?.cookies(for: url), !cookies.isEmpty {
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
    }

    func fetchPostDetails(for url: URL) async throws -> String? {
        _ = try NetworkPolicy.proxy(policy.proxy)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=1.0,image/avif,image/webp,image/apng,*/*;q=1.0", forHTTPHeaderField: "Accept")
        request.timeoutInterval = policy.timeout
        applySessionCookies(to: &request)
        try await pacer.wait(interval: policy.requestInterval)
        var result: (Data, URLResponse)?
        for attempt in 0...max(0, min(10, policy.retries)) {
            do {
                let value = try await session.data(for: request)
                if let http = value.1 as? HTTPURLResponse, [429, 500, 502, 503, 504].contains(http.statusCode), attempt < policy.retries {
                    let delay = min(120, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(attempt + 1) * 2))
                    try await Task.sleep(for: .seconds(delay)); continue
                }
                result = value; break
            } catch {
                if Task.isCancelled || attempt >= policy.retries { throw error }
                try await Task.sleep(for: .seconds(Double(attempt + 1)))
            }
        }
        guard let (data, response) = result else { throw XHSDownloaderError.requestFailed }
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            return nil
        }

        if let html = String(data: data, encoding: .utf8) {
            return html
        }
        if let html = String(data: data, encoding: .ascii) {
            return html
        }
        return nil
    }

    func parsePostDetails(html: String) -> [MediaDescriptor] {
        if let script = extractInitialStateScript(from: html),
           let root = evaluateInitialStateScript(script) {
            let descriptors = parseMediaFromRoot(root)
            if !descriptors.isEmpty {
                return uniqueDescriptors(descriptors)
            }
        }

        return extractUrlsFromHtml(html).map { MediaDescriptor(url: $0, metadata: NoteMetadata()) }
    }

    func uniqueDescriptors(_ descriptors: [MediaDescriptor]) -> [MediaDescriptor] {
        var seen = Set<String>()
        return descriptors.filter { seen.insert($0.url).inserted }
    }

    func parseMediaFromRoot(_ root: [String: Any]) -> [MediaDescriptor] {
        var mediaDescriptors: [MediaDescriptor] = []

        if let noteRoot = root["note"] as? [String: Any] {
            mediaDescriptors.append(contentsOf: parseNoteRoot(noteRoot))
        }

        if mediaDescriptors.isEmpty, let detailMap = root["noteDetailMap"] as? [String: Any] {
            for value in detailMap.values {
                if let dict = value as? [String: Any] {
                    mediaDescriptors.append(contentsOf: parseNoteRoot(dict))
                }
            }
        }

        if mediaDescriptors.isEmpty, let feed = root["feed"] as? [String: Any] {
            mediaDescriptors.append(contentsOf: parseFeed(feed))
        }

        if mediaDescriptors.isEmpty {
            mediaDescriptors.append(contentsOf: parseNoteRoot(root))
        }
        return mediaDescriptors
    }

    func extractInitialStateScript(from html: String) -> String? {
        guard let startRange = html.range(of: #"window\s*\.\s*__INITIAL_STATE__\s*="#, options: .regularExpression),
              let endRange = html[startRange.lowerBound...].range(of: "</script>") else {
            return nil
        }

        let scriptContent = String(html[startRange.lowerBound..<endRange.lowerBound])
        guard let equalIndex = scriptContent.firstIndex(of: "=") else {
            return nil
        }

        let expression = scriptContent[scriptContent.index(after: equalIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return "var window = window || {}; window.__INITIAL_STATE__=\(expression);"
    }

    func evaluateInitialStateScript(_ script: String) -> [String: Any]? {
        guard let context = JSContext() else { return nil }
        context.exceptionHandler = { _, exception in
            if let message = exception?.toString() {
                NSLog("JSContext exception: \(message)")
            }
        }

        context.evaluateScript("var window = {}; var document = {}; var navigator = {};")
        context.evaluateScript(script)

        guard let windowObject = context.objectForKeyedSubscript("window"),
              let state = windowObject.objectForKeyedSubscript("__INITIAL_STATE__"),
              let dictionary = state.toDictionary() as? [String: Any] else {
            return nil
        }

        return dictionary
    }

    func parseNoteRoot(_ noteRoot: [String: Any]) -> [MediaDescriptor] {
        var descriptors: [MediaDescriptor] = []

        if let detailMap = noteRoot["noteDetailMap"] as? [String: Any] {
            for value in detailMap.values {
                if let dict = value as? [String: Any] {
                    if let note = dict["note"] as? [String: Any] {
                        descriptors.append(contentsOf: collectMedia(from: note))
                    } else {
                        descriptors.append(contentsOf: collectMedia(from: dict))
                    }
                }
            }
        } else if let note = noteRoot["note"] as? [String: Any] {
            descriptors.append(contentsOf: collectMedia(from: note))
        } else {
            descriptors.append(contentsOf: collectMedia(from: noteRoot))
        }
        return descriptors
    }

    func parseFeed(_ feed: [String: Any]) -> [MediaDescriptor] {
        var descriptors: [MediaDescriptor] = []
        if let items = feed["items"] as? [[String: Any]] {
            for item in items {
                descriptors.append(contentsOf: collectMedia(from: item))
            }
        }
        return descriptors
    }

    func collectMedia(from note: [String: Any]) -> [MediaDescriptor] {
        var descriptors: [MediaDescriptor] = []
        let metadata = extractMetadata(from: note)

        if let video = note["video"] as? [String: Any] {
            descriptors.append(contentsOf: extractVideoUrls(from: video).map { MediaDescriptor(url: $0, metadata: metadata) })
        }

        if let media = note["media"] as? [String: Any] {
            descriptors.append(contentsOf: extractVideoUrls(from: media).map { MediaDescriptor(url: $0, metadata: metadata) })
        }

        var imageArrays: [[String: Any]] = []
        if let imageList = note["imageList"] as? [[String: Any]] {
            imageArrays.append(contentsOf: imageList)
        } else if let images = note["images"] as? [[String: Any]] {
            imageArrays.append(contentsOf: images)
        } else if let imageObject = note["image"] as? [String: Any] {
            imageArrays.append(imageObject)
        }

        for image in imageArrays {
            if let url = preferredImageURL(from: image) {
                descriptors.append(MediaDescriptor(url: url, metadata: metadata))
            }
            if let stream = image["stream"] as? [String: Any] {
                descriptors.append(contentsOf: extractStreamUrls(from: stream).map { MediaDescriptor(url: $0, metadata: metadata) })
            }
        }

        if let cover = note["cover"] as? [String: Any], let url = preferredImageURL(from: cover) {
            descriptors.append(MediaDescriptor(url: url, metadata: metadata))
        }

        return descriptors
    }

    func extractVideoUrls(from videoDict: [String: Any]) -> [String] {
        var urls: [String] = []
        if let consumer = videoDict["consumer"] as? [String: Any],
           let origin = consumer["originVideoKey"] as? String {
            urls.append("https://sns-video-bd.xhscdn.com/\(origin)")
        }

        if let media = videoDict["media"] as? [String: Any],
           let stream = media["stream"] as? [String: Any] {
            urls.append(contentsOf: extractStreamUrls(from: stream))
        }

        if let videoUrl = videoDict["url"] as? String {
            urls.append(videoUrl)
        }

        return urls
    }

    func extractMetadata(from note: [String: Any]) -> NoteMetadata {
        var metadata = NoteMetadata()
        if let user = note["user"] as? [String: Any] ?? note["user_info"] as? [String: Any] {
            metadata.userName = firstNonEmptyString(user["nickname"], user["nickName"], user["name"], user["userName"], user["user_name"])
            metadata.userId = firstNonEmptyString(user["userId"], user["userid"], user["user_id"], user["id"])
            metadata.redId = firstNonEmptyString(user["redId"], user["red_id"])
            if let avatar = firstNonEmptyString(user["avatar"], user["image"], user["imageb"], user["avatarUrl"]) {
                let absolute = avatar.hasPrefix("//") ? "https:" + avatar : avatar
                if let url = URL(string: absolute), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    metadata.avatarURL = url
                }
            }
        }
        if metadata.userId == nil {
            metadata.userId = firstNonEmptyString(note["userId"], note["uid"])
        }
        metadata.title = firstNonEmptyString(note["title"], note["desc"], note["description"], note["noteId"])
        metadata.publishTime = extractPublishTime(from: note)
        let tags = note["tagList"] as? [[String: Any]] ?? note["tags"] as? [[String: Any]] ?? []
        let topics = tags.compactMap { firstNonEmptyString($0["name"], $0["title"]) }
        if !topics.isEmpty { metadata.topics = topics }
        return metadata
    }

    func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    func extractPublishTime(from note: [String: Any]) -> String? {
        let textualKeys = ["publishTime", "publish_time", "timeText", "time", "displayTime", "createTime"]
        for key in textualKeys {
            if let value = note[key] as? String,
               let normalized = normalizeExplicitDate(value) {
                return normalized
            }
        }

        let epochKeys = ["time", "publishTime", "publish_time", "createTime", "timestamp", "timeStamp"]
        for key in epochKeys {
            if let number = note[key] as? NSNumber,
               let formatted = formatEpoch(number.doubleValue) {
                return formatted
            }
            if let string = note[key] as? String,
               let digits = digitsOnly(from: string),
               let numeric = Double(digits),
               let formatted = formatEpoch(numeric) {
                return formatted
            }
        }

        return nil
    }

    func normalizeExplicitDate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let match = trimmed.range(of: #"\d{2}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(trimmed[match])
        }

        if let match = trimmed.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            let substring = String(trimmed[match])
            if let date = Self.isoDateFormatter.date(from: substring) {
                return Self.publishFormatter.string(from: date)
            }
        }

        if let digits = digitsOnly(from: trimmed), digits.count >= 8 {
            let firstEight = String(digits.prefix(8))
            if let date = Self.compactDateFormatter.date(from: firstEight) {
                return Self.publishFormatter.string(from: date)
            }
        }

        return nil
    }

    func digitsOnly(from string: String) -> String? {
        let cleaned = string.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        return cleaned.isEmpty ? nil : cleaned
    }

    func formatEpoch(_ rawValue: Double) -> String? {
        var value = rawValue
        if value < 1_000_000_000 { return nil }
        if value < 1_000_000_000_000 { value *= 1000 }
        if value < 946_684_800_000 { return nil }
        let date = Date(timeIntervalSince1970: value / 1000)
        return Self.publishFormatter.string(from: date)
    }

    func extractStreamUrls(from stream: [String: Any]) -> [String] {
        var urls: [String] = []
        if let h264 = stream["h264"] as? [Any] {
            for entry in h264 {
                if let string = entry as? String, string.starts(with: "http") {
                    urls.append(string)
                } else if let dict = entry as? [String: Any] {
                    if let url = dict["masterUrl"] as? String {
                        urls.append(url)
                    } else if let url = dict["url"] as? String {
                        urls.append(url)
                    }
                }
            }
        }
        return urls
    }

    func preferredImageURL(from dict: [String: Any]) -> String? {
        if let origin = dict["originUrl"] as? String {
            return transformXhsCdnUrl(origin)
        }
        if let defaultUrl = dict["urlDefault"] as? String {
            return transformXhsCdnUrl(defaultUrl)
        }
        if let url = dict["url"] as? String {
            return transformXhsCdnUrl(url)
        }
        if let traceId = dict["traceId"] as? String {
            return transformXhsCdnUrl("https://sns-img-qc.xhscdn.com/\(traceId)")
        }
        if let infoList = dict["infoList"] as? [[String: Any]] {
            for info in infoList {
                if let url = info["url"] as? String {
                    return transformXhsCdnUrl(url)
                }
            }
        }
        return nil
    }

    func extractUrlsFromHtml(_ html: String) -> [String] {
        var urls: [String] = []
        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)

        htmlImgRegex.enumerateMatches(in: html, options: [], range: fullRange) { result, _, _ in
            guard let range = result?.range(at: 1) else { return }
            let url = nsHTML.substring(with: range)
            if isValidMediaUrl(url) {
                urls.append(url)
            }
        }

        htmlUrlRegex.enumerateMatches(in: html, options: [], range: fullRange) { result, _, _ in
            guard let range = result?.range else { return }
            let url = nsHTML.substring(with: range)
            if isValidMediaUrl(url) {
                urls.append(url)
            }
        }

        return urls
    }

    func buildRemoteMedia(from descriptors: [MediaDescriptor],
                          postId: String?,
                          downloadEpochSeconds: TimeInterval,
                          preferences: NamingPreferences) -> [RemoteMedia] {
        var results: [RemoteMedia] = []
        let fallbackBase = postId ?? UUID().uuidString.prefix(8).description

        for (index, descriptor) in descriptors.enumerated() {
            let raw = descriptor.url
            guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
                  let originalURL = URL(string: encoded) ?? URL(string: raw) else { continue }
            let type: RemoteMedia.MediaType = isVideoUrl(raw) ? .video : .image
            let normalizedURL: URL
            if type == .image {
                let transformedString = transformXhsCdnUrl(raw)
                normalizedURL = URL(string: transformedString) ?? originalURL
            } else {
                normalizedURL = originalURL
            }

            let baseName = NamingFormatter.makeBaseName(
                metadata: descriptor.metadata,
                fallbackPostId: postId ?? fallbackBase,
                index: index + 1,
                downloadEpochSeconds: downloadEpochSeconds,
                preferences: preferences
            )

            results.append(RemoteMedia(url: normalizedURL,
                                       type: type,
                                       fileBaseName: baseName,
                                       originalURLString: raw))
        }
        return results
    }

    func extractPostId(from url: String) -> String? {
        if let match = idRegex.firstMatch(in: url, options: [], range: NSRange(location: 0, length: (url as NSString).length)) {
            return (url as NSString).substring(with: match.range(at: 1))
        }
        if let match = idUserRegex.firstMatch(in: url, options: [], range: NSRange(location: 0, length: (url as NSString).length)) {
            return (url as NSString).substring(with: match.range(at: 1))
        }

        return nil
    }

    func isValidMediaUrl(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains("xhscdn.com") {
            return true
        }
        return lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".png") ||
            lower.contains(".gif") || lower.contains(".webp") || lower.contains(".mp4") ||
            lower.contains(".mov")
    }

    func isVideoUrl(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains(".mp4") || lower.contains(".mov") || lower.contains(".avi") ||
            lower.contains(".webm") || lower.contains("video") || lower.contains("stream") ||
            lower.contains("sns-video")
    }

    func transformXhsCdnUrl(_ originalUrl: String) -> String {
        // Preserve the source container and HDR/gain-map representation.
        originalUrl.replacingOccurrences(of: "\\/", with: "/")
    }

    func extractImageToken(from url: String) -> String? {
        var sanitized = url
        sanitized = sanitized.replacingOccurrences(of: "\\/", with: "/")
        sanitized = sanitized.replacingOccurrences(of: "\\u002F", with: "/")
        sanitized = sanitized.replacingOccurrences(of: "\\", with: "")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)

        if let httpRange = sanitized.range(of: "http", options: .caseInsensitive) {
            sanitized = String(sanitized[httpRange.lowerBound...])
        }

        let parts = sanitized.components(separatedBy: "/")
        guard parts.count > 5 else { return nil }

        let tokenSection = parts[5...].joined(separator: "/")
        let strippedBang = tokenSection.split(separator: "!").first ?? Substring(tokenSection)
        let strippedQuery = strippedBang.split(separator: "?").first ?? strippedBang
        let token = String(strippedQuery)
        return token.isEmpty ? nil : token
    }

    func determineFileExtension(from response: URLResponse?, fallbackURL: URL, mediaType: RemoteMedia.MediaType) -> String {
        if let http = response as? HTTPURLResponse,
           let mimeType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if mimeType.contains("heic") { return "heic" }
            if mimeType.contains("heif") { return "heif" }
            if mimeType.contains("avif") { return "avif" }
            if mimeType.contains("png") { return "png" }
            if mimeType.contains("webp") { return "webp" }
            if mimeType.contains("gif") { return "gif" }
            if mimeType.contains("jpeg") || mimeType.contains("jpg") { return "jpg" }
            if mimeType.contains("mp4") { return "mp4" }
            if mimeType.contains("quicktime") { return "mov" }
        }

        let ext = fallbackURL.pathExtension.lowercased()
        if !ext.isEmpty {
            return ext
        }

        return mediaType == .video ? "mp4" : "jpg"
    }

    public func extractDescription(from input: String, logger: @escaping LogHandler) async throws -> String {
        try await resolveNote(from: input).body
    }

    func parseDescriptionFromHtml(html: String) -> String? {
        // 查找笔记描述
        if let script = extractInitialStateScript(from: html),
           let root = evaluateInitialStateScript(script) {
            if let noteRoot = root["note"] as? [String: Any] {
                if let description = extractDescriptionFromNoteRoot(noteRoot) {
                    return description
                }
            }

            if let detailMap = root["noteDetailMap"] as? [String: Any] {
                for value in detailMap.values {
                    if let dict = value as? [String: Any],
                       let note = dict["note"] as? [String: Any],
                       let description = extractDescriptionFromNoteRoot(note) {
                        return description
                    }
                }
            }
        }

        // 如果从初始状态脚本中找不到，尝试从HTML中查找
        let descPattern = "(?<=<meta property=\"og:description\" content=\")[^\"]*(?=\")"
        let regex = try? NSRegularExpression(pattern: descPattern, options: [])
        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)

        if let match = regex?.firstMatch(in: html, options: [], range: fullRange) {
            let description = nsHTML.substring(with: match.range)
            if !description.isEmpty {
                return description
            }
        }

        // 尝试从其他可能的位置提取描述
        let titlePattern = "(?<=<title>)[^<]*(?=</title>)"
        let titleRegex = try? NSRegularExpression(pattern: titlePattern, options: .caseInsensitive)

        if let match = titleRegex?.firstMatch(in: html, options: [], range: fullRange) {
            let title = nsHTML.substring(with: match.range)
            if !title.isEmpty {
                // 移除可能的网站名称后缀
                let cleanedTitle = title.replacingOccurrences(of: "-小红书", with: "").replacingOccurrences(of: "- XIAOHONGSHU", with: "")
                return cleanedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    func extractDescriptionFromNoteRoot(_ noteRoot: [String: Any]) -> String? {
        if let detailMap = noteRoot["noteDetailMap"] as? [String: Any] {
            for value in detailMap.values {
                if let dict = value as? [String: Any] {
                    if let note = dict["note"] as? [String: Any] {
                        if let description = extractDescriptionFromNote(note) {
                            return description
                        }
                    } else {
                        if let description = extractDescriptionFromNote(dict) {
                            return description
                        }
                    }
                }
            }
        } else if let note = noteRoot["note"] as? [String: Any] {
            return extractDescriptionFromNote(note)
        } else {
            return extractDescriptionFromNote(noteRoot)
        }
        return nil
    }

    func extractDescriptionFromNote(_ note: [String: Any]) -> String? {
        // 尝试不同的键名来获取描述
        let possibleKeys = ["desc", "description", "title", "content", "note_title", "note_desc"]

        for key in possibleKeys {
            if let description = note[key] as? String {
                if !description.isEmpty {
                    return description.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return nil
    }
}
