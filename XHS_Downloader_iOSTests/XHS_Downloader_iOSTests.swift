import Foundation
import Testing
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import XHS_Downloader_iOS

struct XHS_Downloader_iOSTests {
    @Test func extractsSupportedDomainsAndShareText() async {
        let input = "看看这篇 https://www.xiaohongshu.com/explore/abc123?x=1 还有 https://xhslink.cn/AbCdE。重复 https://xhslink.cn/AbCdE"
        let links = XHSURLDetector.extract(from: input)
        #expect(links == [
            "https://www.xiaohongshu.com/explore/abc123?x=1",
            "https://xhslink.cn/AbCdE"
        ])
    }

    @Test func extractsExactXHSShareTextFromClipboard() async {
        let first = "DeepSeek V4.1 Flash：更强、更快、更普惠 今天，我们... https://xhslink.cn/o/8aTjW8TdKAF 先复制一下，然后去【小红书】搜索查看笔记。"
        let second = "DeepSeek 寻找闪亮发光的你 DeepSeek 的用人原则是，... https://xhslink.cn/o/6gWL8xC4pDm 复制这段文字，打开【小红书】一键直达笔记。"
        #expect(XHSURLDetector.extract(from: first) == [
            "https://xhslink.cn/o/8aTjW8TdKAF"
        ])
        #expect(XHSURLDetector.extract(from: second) == [
            "https://xhslink.cn/o/6gWL8xC4pDm"
        ])
        #expect(XHSURLDetector.extract(from: first + "\n" + second) == [
            "https://xhslink.cn/o/8aTjW8TdKAF",
            "https://xhslink.cn/o/6gWL8xC4pDm"
        ])
        #expect(ImportText.extractLinks(from: first + "\n" + second) == [
            "https://xhslink.cn/o/8aTjW8TdKAF",
            "https://xhslink.cn/o/6gWL8xC4pDm"
        ])
    }

    @Test func persistsTasksAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadTaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        let task = DownloadTaskRecord(
            sourceText: "share text",
            normalizedURL: "https://xhslink.com/example",
            title: "Example",
            status: .completed,
            progress: 1,
            mediaCount: 3,
            savedCount: 3
        )

        try await store.save([task])
        let loaded = try #require(await store.load().first)
        #expect(loaded.id == task.id)
        #expect(loaded.normalizedURL == task.normalizedURL)
        #expect(loaded.status == .completed)
        #expect(loaded.mediaCount == 3)
        #expect(abs(loaded.createdAt.timeIntervalSince(task.createdAt)) < 1)
    }

    @Test func namingTemplateSupportsAndroidPlaceholders() async {
        let preferences = NamingPreferences(enabled: true, template: "{username}_{postId}_{index_padded}")
        let name = NamingFormatter.makeBaseName(
            metadata: NoteMetadata(userName: "A/B", userId: nil, title: nil, publishTime: nil),
            fallbackPostId: "post-1",
            index: 2,
            downloadEpochSeconds: 123,
            preferences: preferences
        )
        #expect(name == "A_B_post-1_02_02")
    }

    @Test func interruptedTasksBecomeResumablePauses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadTaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        let task = DownloadTaskRecord(
            sourceText: "share text",
            normalizedURL: "https://xhslink.com/example",
            status: .downloading,
            progress: 0.4
        )
        try await store.save([task])

        let settings = await MainActor.run { AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!) }
        let coordinator = await MainActor.run { DownloadCoordinator(settings: settings, store: store) }
        await coordinator.waitUntilLoaded()
        let recovered = await MainActor.run { coordinator.tasks.first }
        #expect(recovered?.status == .paused)
        #expect(recovered?.progress == 0.4)
    }

    @Test func extractsBareRedNoteAndPunctuationSeparatedLinks() async {
        #expect(XHSURLDetector.extract(from: "xhslink.cn/o/abc，rednote.com/explore/123；https://xiaohongshu.com/explore/456") == [
            "https://xhslink.cn/o/abc", "https://rednote.com/explore/123", "https://xiaohongshu.com/explore/456"
        ])
        #expect(XHSURLDetector.extract(from: "https://evil.rednote.com/explore/123").isEmpty)
        #expect(XHSDownloader().extractPostId(from: "https://xhslink.cn/o/abc") == nil)
    }

    @Test func shareInboxDoesNotDeleteRequestsUntilAcknowledged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ImportInbox(directory: root)
        let first = ImportRequest(text: "share1", source: .share)
        let second = ImportRequest(text: "share2", source: .share)
        try inbox.append(first)
        try inbox.append(second)
        try inbox.append(first)
        #expect(try inbox.pending().count == 2)
        #expect(ImportRequest.requestID(from: first.handoffURL) == first.id)
        #expect(ImportRequest.requestID(from: URL(string: "https://example.com/import?request=\(first.id)")!) == nil)
        try inbox.acknowledge(first.id)
        #expect(try inbox.pending().map(\.id) == [second.id])
    }

    @Test func resolvesOnlyTargetWithOneVideoAndOrderedLivePair() async throws {
        let note: [String: Any] = [
            "noteId": "target", "title": "Title", "desc": "Line1\nLine2",
            "user": ["userId": "internal", "redId": "public", "nickname": "Author"],
            "video": ["consumer": ["originVideoKey": "original.mp4"],
                      "media": ["stream": ["h265": [["masterUrl": "https://example.com/h265.mp4"]],
                                           "h264": [["masterUrl": "https://example.com/h264.mp4"]]]]],
            "imageList": [
                ["traceId": "first", "originUrl": "https://example.com/original.heic",
                 "urlDefault": "https://example.com/preview.jpg", "width": 100, "height": 200],
                ["traceId": "second", "urlDefault": "https://example.com/live.jpg",
                 "stream": ["h264": [["masterUrl": "https://example.com/live.mp4"]]]]
            ]
        ]
        let root: [String: Any] = ["note": ["noteDetailMap": [
            "target": ["note": note],
            "other": ["note": ["noteId": "other", "imageList": [["urlDefault": "https://example.com/wrong.jpg"]]]]
        ]]]
        let html = "<script>window.__INITIAL_STATE__ = \(String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self));</script>"
        let resolver = XHSDownloader()
        let resolved = try resolver.resolveNote(html: html, noteID: "target", canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/target")!)
        #expect(resolved.media.count == 3)
        #expect(resolved.media.map(\.type) == [.video, .image, .livePhoto])
        #expect(resolved.media[0].candidates.count == 3)
        #expect(resolved.media[1].url.pathExtension == "heic")
        #expect(resolved.media[2].pairedVideoURLs.count == 1)
        #expect(resolved.body == "Line1\nLine2")
        #expect(resolved.metadata.userId == "internal")
        #expect(resolved.metadata.redId == "public")
        #expect(throws: XHSDownloaderError.self) {
            try resolver.resolveNote(html: html, noteID: "missing", canonicalURL: resolved.canonicalURL)
        }
    }

    @Test func resolvesMobileNoteShape() async throws {
        let html = #"<script>window.__INITIAL_STATE__ = {"noteData":{"data":{"noteData":{"noteId":"mobile","imageList":[{"urlDefault":"https://example.com/a.jpg"}]}}}};</script>"#
        let note = try XHSDownloader().resolveNote(html: html, noteID: "mobile", canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/mobile")!)
        #expect(note.media.count == 1)
    }

    @Test func jpegPairingPreservesScanDataAndExistingExif() async throws {
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:08 10:00:00"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let original = data as Data
        let id = UUID().uuidString
        let edited = try JPEGPairingMetadata.addIdentifier(id, to: original)
        let source = try #require(CGImageSourceCreateWithData(edited as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let maker = try #require(properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])
        #expect((maker["17"] as? String)?.hasPrefix(id) == true)
        #expect(properties[kCGImagePropertyOrientation as String] as? Int == 6)
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:11:08 10:00:00")
        let scan = try #require(original.range(of: Data([0xFF, 0xDA])))
        let newScan = try #require(edited.range(of: Data([0xFF, 0xDA])))
        #expect(original[scan.lowerBound...] == edited[newScan.lowerBound...])
        #expect(throws: LivePhotoPairingError.self) { try JPEGPairingMetadata.addIdentifier(id, to: Data("not a jpeg".utf8)) }
    }
}
