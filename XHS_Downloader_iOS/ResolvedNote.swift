import Foundation

struct ResolvedNote: Codable, Hashable, Sendable {
    let noteID: String
    let canonicalURL: URL
    let title: String
    let body: String
    let metadata: NoteMetadata
    let media: [RemoteMedia]
}

extension XHSDownloader {
    /// Naming context for a task: the submitted policy's naming settings and the
    /// download instant recorded at submission. This keeps a retry producing the
    /// same file names as the original run.
    struct NamingContext: Sendable {
        var preferences: NamingPreferences
        var downloadInstant: Date
    }

    func resolveNote(from input: String, naming namingContext: NamingContext? = nil) async throws -> ResolvedNote {
        _ = try NetworkPolicy.proxy(policy.proxy)
        guard let link = XHSURLDetector.first(from: input),
              let context = try await prepareContext(for: link, logger: { _ in }),
              let id = context.postId else { throw XHSDownloaderError.invalidURL }
        guard let html = try await fetchPostDetails(for: context.resolvedURL) else {
            throw XHSDownloaderError.requestFailed
        }
        return try resolveNote(html: html, noteID: id, canonicalURL: context.resolvedURL, naming: namingContext)
    }

    /// Does not fall back to arbitrary images from the page: those can belong to
    /// recommendations, avatars or a different note.
    func resolveNote(html: String, noteID: String, canonicalURL: URL,
                     naming: NamingContext? = nil) throws -> ResolvedNote {
        guard let script = extractInitialStateScript(from: html),
              let state = evaluateInitialStateScript(script),
              let target = targetNote(in: state, id: noteID) else { throw XHSDownloaderError.parsingFailed }
        return try resolveNote(data: target.note, noteID: noteID, canonicalURL: canonicalURL,
                               comments: target.comments, naming: naming)
    }

    func resolveNote(data note: [String: Any], noteID: String, canonicalURL: URL, comments: Any? = nil,
                     naming: NamingContext? = nil) throws -> ResolvedNote {
        let actual = firstNonEmptyString(note["noteId"], note["note_id"], note["id"])
        if let actual, actual != noteID {
            throw XHSDownloaderError.parsingFailed
        }
        var metadata = extractMetadata(from: note)
        for key in ["time", "publishTime", "createTime", "timestamp"] {
            if let raw = (note[key] as? NSNumber)?.doubleValue ?? (note[key] as? String).flatMap(Double.init), raw > 946684800 {
                metadata.publishedAt = Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
                break
            }
        }
        if let uid = metadata.userId, var components = URLComponents(url: canonicalURL, resolvingAgainstBaseURL: false) {
            components.path = "/user/profile/" + uid
            components.queryItems = components.queryItems?.filter { ["xsec_token", "xsec_source"].contains($0.name) }
            components.fragment = nil
            metadata.profileURL = components.url
        }
        let body = firstNonEmptyString(note["desc"], note["description"], note["body"]) ?? ""
        let title = firstNonEmptyString(note["title"]) ?? String(body.prefix(80))
        // A task-level snapshot wins; only an ad-hoc resolve falls back to the
        // current settings and clock.
        let epoch = (naming?.downloadInstant ?? Date()).timeIntervalSince1970
        let namingPreferences = naming?.preferences ?? NamingPreferences.load()
        var media: [RemoteMedia] = []
        var identityCounts: [String: Int] = [:]

        func make(_ urls: [String], type: RemoteMedia.MediaType, identity: String,
                  preview: String? = nil, paired: [String] = [], dimensions: [String: Any] = [:]) -> RemoteMedia? {
            var seen = Set<String>()
            let candidates = urls.compactMap(normalizedMediaURL).filter { seen.insert($0.absoluteString).inserted }
            guard let first = candidates.first else { return nil }
            let count = (identityCounts[identity] ?? 0) + 1
            identityCounts[identity] = count
            let uniqueIdentity = count == 1 ? identity : "\(identity)#\(count)"
            let validPaired = paired.compactMap(normalizedMediaURL)
            let resolvedType: RemoteMedia.MediaType = type == .livePhoto && validPaired.isEmpty ? .image : type
            return RemoteMedia(
                stableID: "\(noteID):\(uniqueIdentity)", url: first, type: resolvedType,
                fileBaseName: NamingFormatter.makeBaseName(metadata: metadata, fallbackPostId: noteID,
                    index: media.count + 1, downloadEpochSeconds: epoch, preferences: namingPreferences),
                originalURLString: first.absoluteString, candidates: candidates,
                previewURL: preview.flatMap(normalizedMediaURL),
                pairedVideoURLs: validPaired,
                width: dimensions["width"] as? Int, height: dimensions["height"] as? Int
            )
        }

        if let video = note["video"] as? [String: Any] ?? note["media"] as? [String: Any],
           var item = make(videoURLs(video), type: .video, identity: "video:0",
                           preview: (note["cover"] as? [String: Any]).flatMap { preferredImageURL(from: $0) }) {
            item.variants = videoVariants(video)
            media.append(item)
            if let cover = note["cover"] as? [String: Any], var poster = make(imageURLs(cover), type: .image,
                    identity: "cover", preview: preferredImageURL(from: cover), dimensions: cover) {
                poster.role = .cover
                poster.fileKey = imageFileKey(cover)
                media.append(poster)
            }
        }
        let isVideoNote = note["type"] as? String == "video"
        let images = note["imageList"] as? [[String: Any]] ?? note["images"] as? [[String: Any]] ?? []
        for (index, image) in images.enumerated() {
            let urls = imageURLs(image)
            let stream = image["stream"] as? [String: Any]
            let paired = (stream.map(streamURLs) ?? [])
                + ((image["video"] as? [String: Any]).map(videoURLs) ?? [])
                + ((image["livePhoto"] as? [String: Any]).map(videoURLs) ?? [])
            let validPaired = paired.compactMap(normalizedMediaURL)
            // A stream inside this image is the explicit pairing signal. A note
            // with one image plus an unrelated video is never guessed to be live.
            let identity = firstNonEmptyString(image["traceId"], image["fileId"]) ?? String(index)
            if var item = make(urls, type: validPaired.isEmpty ? .image : .livePhoto, identity: "image:\(identity)",
                               preview: firstNonEmptyString(image["urlPre"], image["urlDefault"]) ?? urls.first,
                               paired: paired, dimensions: image) {
                item.fileKey = imageFileKey(image)
                // Video notes also expose their cover through imageList. An
                // explicitly paired Live Photo remains body media.
                if isVideoNote, validPaired.isEmpty { item.role = .cover }
                media.append(item)
            }
        }
        func commentImages(_ value: Any, parent: String = "comment") {
            if let array = value as? [Any] {
                for (index, child) in array.enumerated() { commentImages(child, parent: parent + ":\(index)") }
            } else if let object = value as? [String: Any] {
                let identity = firstNonEmptyString(object["id"], object["commentId"]) ?? parent
                for key in ["pictures", "imageList", "images"] {
                    guard let images = object[key] as? [[String: Any]] else { continue }
                    for (index, image) in images.enumerated() {
                        if var item = make(imageURLs(image), type: .image, identity: "comment:\(identity):\(index)",
                                           preview: preferredImageURL(from: image), dimensions: image) {
                            item.role = .comment; item.fileKey = imageFileKey(image); media.append(item)
                        }
                    }
                }
                for key in ["comments", "list", "data", "subComments", "replies", "commentList"] {
                    if let child = object[key] { commentImages(child, parent: identity) }
                }
            }
        }
        if let comments = comments ?? note["comments"] ?? note["commentData"] { commentImages(comments) }
        // Reject completely empty shell payloads returned for deleted/login-walled notes.
        if media.isEmpty, title.isEmpty, body.isEmpty, actual == nil {
            throw XHSDownloaderError.parsingFailed
        }
        return ResolvedNote(noteID: noteID, canonicalURL: canonicalURL, title: title, body: body, metadata: metadata, media: media)
    }

    private func targetNote(in root: [String: Any], id: String) -> (note: [String: Any], comments: Any?)? {
        func unwrap(_ value: [String: Any]) -> (note: [String: Any], comments: Any?) {
            (value["note"] as? [String: Any] ?? value, value["comments"] ?? value["commentData"])
        }
        func matches(_ note: [String: Any]) -> Bool {
            firstNonEmptyString(note["noteId"], note["note_id"], note["id"]) == id
        }
        let noteRoot = root["note"] as? [String: Any] ?? root
        if let map = noteRoot["noteDetailMap"] as? [String: Any] {
            if let exact = map[id] as? [String: Any] {
                let unwrapped = unwrap(exact)
                if !unwrapped.note.isEmpty { return unwrapped }
            }
            if let found = map.values.compactMap({ $0 as? [String: Any] }).map(unwrap).first(where: { matches($0.note) }) {
                return found
            }
        }
        if let mobile = root["noteData"] as? [String: Any],
           let data = mobile["data"] as? [String: Any],
           let note = data["noteData"] as? [String: Any] {
            let noteID = firstNonEmptyString(note["noteId"], note["note_id"], note["id"])
            return noteID == nil || noteID == id ? (note, nil) : nil
        }
        if matches(noteRoot) { return (noteRoot, nil) }
        if let note = noteRoot["note"] as? [String: Any], matches(note) { return unwrap(noteRoot) }
        return nil
    }

    private func normalizedMediaURL(_ value: String) -> URL? {
        let string = value.replacingOccurrences(of: "\\/", with: "/")
        let absolute = string.hasPrefix("//") ? "https:" + string : string
        guard let url = URL(string: absolute),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        if scheme == "http", let host = url.host?.lowercased(),
           ["xhscdn.com", "xiaohongshu.com", "rednote.com", "xhslink.com", "xhslink.cn"]
            .contains(where: { host == $0 || host.hasSuffix("." + $0) }),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            return components.url ?? url
        }
        return url
    }

    private func imageURLs(_ image: [String: Any]) -> [String] {
        var result = [image["originUrl"], image["originalUrl"]].compactMap { $0 as? String }
        // H5 URLs end in transforms such as !h5_1080jpg. Those discard the
        // original container/resolution and can discard HDR auxiliary data.
        // Use the upstream's original CDN endpoint with the supplied file key;
        // retain the page candidates for notes whose original is unavailable.
        if let key = imageFileKey(image) {
            result.append("https://sns-img-bd.xhscdn.com/\(key)")
        }
        let info = image["infoList"] as? [[String: Any]] ?? []
        result += info.sorted {
            ($0["imageScene"] as? String == "WB_DFT" ? 0 : 1) < ($1["imageScene"] as? String == "WB_DFT" ? 0 : 1)
        }.compactMap { $0["url"] as? String }
        // Keep URL-derived originals as fallbacks even when fileId was present.
        // A stale primary key must not force a transformed web thumbnail.
        for field in ["urlDefault", "urlPre", "url"] {
            if let value = image[field], let key = imageFileKey([field: value]) {
                result.append("https://sns-img-bd.xhscdn.com/" + key)
            }
        }
        result += [image["urlDefault"], image["urlPre"], image["url"]].compactMap { $0 as? String }
        return result
    }

    private func imageFileKey(_ image: [String: Any]) -> String? {
        func valid(_ key: String) -> Bool {
            !key.split(separator: "/").isEmpty && key.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
                && key.unicodeScalars.allSatisfy {
                    CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.").contains($0)
                }
        }
        if let key = image["fileId"] as? String, valid(key) { return key }
        let info = image["infoList"] as? [[String: Any]] ?? []
        let values = [image["urlDefault"], image["urlPre"], image["url"]] + info.map { $0["url"] }
        for value in values {
            guard let value = value as? String, let url = normalizedMediaURL(value),
                  let host = url.host?.lowercased(),
                  host.hasSuffix(".xhscdn.com") || host == "ci.xiaohongshu.com" else { continue }
            let path = url.path.components(separatedBy: "!")[0].split(separator: "/")
            // Web preview URLs prepend an expiry and signature to the resource
            // key. Those segments do not belong in an original/format URL.
            let key: String
            if host.hasPrefix("sns-webpic-") {
                key = path.count >= 3 ? path.dropFirst(2).joined(separator: "/") : String(path.last ?? "")
            } else { key = path.joined(separator: "/") }
            if valid(key) { return key }
        }
        return nil
    }

    private func videoVariants(_ video: [String: Any]) -> [MediaVariant] {
        var result: [MediaVariant] = []
        if let consumer = video["consumer"] as? [String: Any],
           let key = consumer["originVideoKey"] as? String, !key.isEmpty,
           let url = normalizedMediaURL(key.hasPrefix("http") ? key : "https://sns-video-bd.xhscdn.com/" + key) {
            result.append(MediaVariant(url: url, isOriginal: true))
        }
        if let stream = (video["media"] as? [String: Any])?["stream"] as? [String: Any] { result += streamVariants(stream) }
        if let stream = video["stream"] as? [String: Any] { result += streamVariants(stream) }
        var seen = Set<URL>()
        result = result.filter { seen.insert($0.url).inserted }
        return result
    }

    private func videoURLs(_ video: [String: Any]) -> [String] {
        var result: [String] = []
        if let consumer = video["consumer"] as? [String: Any],
           let key = consumer["originVideoKey"] as? String, !key.isEmpty {
            result.append(key.hasPrefix("http") ? key : "https://sns-video-bd.xhscdn.com/\(key)")
        }
        if let media = video["media"] as? [String: Any], let stream = media["stream"] as? [String: Any] {
            result += streamURLs(stream)
        }
        if let stream = video["stream"] as? [String: Any] { result += streamURLs(stream) }
        if let url = firstNonEmptyString(video["url"], video["masterUrl"]) { result.append(url) }
        return result
    }

    private func streamURLs(_ stream: [String: Any]) -> [String] {
        streamVariants(stream).flatMap { [$0.url.absoluteString] + $0.backups.map(\.absoluteString) }
    }

    private func streamVariants(_ stream: [String: Any]) -> [MediaVariant] {
        var result: [MediaVariant] = []
        let preferred = ["h265", "h264", "av1", "h266"]
        let codecs = preferred + stream.keys.filter { !preferred.contains($0) }.sorted()
        for codec in codecs {
            let entries = stream[codec] as? [Any] ?? []
            let sorted = entries.sorted {
                (($0 as? [String: Any])?["videoBitrate"] as? Int ?? 0) >
                (($1 as? [String: Any])?["videoBitrate"] as? Int ?? 0)
            }
            for entry in sorted {
                if let value = entry as? String, let url = normalizedMediaURL(value) {
                    result.append(MediaVariant(url: url, codec: codec)); continue
                }
                guard let entry = entry as? [String: Any] else { continue }
                let urls = ([entry["masterUrl"], entry["url"]].compactMap { $0 as? String }
                    + (entry["backupUrls"] as? [String] ?? [])).compactMap(normalizedMediaURL)
                guard let url = urls.first else { continue }
                let marked = [259, 309].contains(entry["streamType"] as? Int ?? -1)
                    || (entry["streamDesc"] as? String)?.uppercased() == "WEB_LIVEPHOTO_19"
                result.append(MediaVariant(url: url, backups: Array(urls.dropFirst()),
                    codec: codec, width: entry["width"] as? Int, height: entry["height"] as? Int,
                    bitrate: entry["videoBitrate"] as? Int, byteCount: (entry["size"] as? NSNumber)?.int64Value,
                    isKnownWatermarked: marked))
            }
        }
        // Keep fallback candidates, including a marked stream when it is the
        // only available one. An unmarked stream is not a guarantee about pixels.
        return result.filter { $0.isKnownWatermarked != true } + result.filter { $0.isKnownWatermarked == true }
    }
}
