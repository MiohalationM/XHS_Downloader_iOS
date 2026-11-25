import Foundation
import Testing
import Photos
import ImageIO
@preconcurrency import AVFoundation
@testable import XHS_Downloader_iOS

private final class LivePhotoFixtureBundle: NSObject {}

struct LivePhotoNoteRegressionTests {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle(for: LivePhotoFixtureBundle.self).url(forResource: name, withExtension: ext))
    }

    @Test func mobileShareRetainsNoteTokenAndChoosesOriginalBeforeWebThumbnail() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileShareFixtureProtocol.self]
        let downloader = XHSDownloader(session: URLSession(configuration: configuration))
        let resolved = try await downloader.resolveNote(from: "DeepSeek V4.1 Flash：更强、更快、更普惠 https://xhslink.cn/o/8aTjW8TdKAF")
        #expect(resolved.noteID == "6aa2443700000000260303c2")
        #expect(URLComponents(url: resolved.canonicalURL, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(URLQueryItem(name: "xsec_token", value: "fixture-token")) == true)
        #expect(resolved.media.map(\.type) == [.livePhoto, .image, .image])
        let live = try #require(resolved.media.first)
        #expect(live.url.absoluteString == "https://sns-img-bd.xhscdn.com/1040g008322ek5b5j7u005otp756pidgp68d6rc8")
        #expect(live.candidates.dropFirst().contains { $0.absoluteString.contains("!h5_1080jpg") })
        #expect(live.pairedVideoURLs.count == 2)
        #expect(live.width == 2160 && live.height == 2880)
    }

    @Test(.timeLimit(.minutes(1))) func originalHEICAndRealMotionFormNativeLivePhotoWithoutChangingStill() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let still = root.appendingPathComponent("original.heic")
        let motion = root.appendingPathComponent("motion.mp4")
        try FileManager.default.copyItem(at: fixture("livephoto-original", "heic"), to: still)
        try FileManager.default.copyItem(at: fixture("livephoto-motion", "mp4"), to: motion)
        let transfer = root.appendingPathComponent("session.download")
        try FileManager.default.copyItem(at: motion, to: transfer)
        #expect(try await MediaFileValidator.fileExtension(for: transfer, isVideo: true) == "mp4")
        let source = try #require(CGImageSourceCreateWithURL(still as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 2160)
        #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 2880)
        #expect(properties[kCGImagePropertyProfileName as String] as? String == "Display P3")
        let pair = try await LivePhotoPairer.pair(photo: still, video: motion)
        #expect(pair.photo == still)
        #expect(try Data(contentsOf: pair.photo) == Data(contentsOf: fixture("livephoto-original", "heic")))
        let live: PHLivePhoto? = await withCheckedContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [pair.photo, pair.video], placeholderImage: nil,
                                targetSize: CGSize(width: 216, height: 288), contentMode: .aspectFit) { live, info in
                if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
                continuation.resume(returning: live)
            }
        }
        #expect(live != nil)
        let inputTrack = try #require(try await AVURLAsset(url: motion).loadTracks(withMediaType: .video).first)
        let outputTrack = try #require(try await AVURLAsset(url: pair.video).loadTracks(withMediaType: .video).first)
        let inputFormat = try #require(try await inputTrack.load(.formatDescriptions).first)
        let outputFormat = try #require(try await outputTrack.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(inputFormat) == CMFormatDescriptionGetMediaSubType(outputFormat))
        let inputSize = CMVideoFormatDescriptionGetDimensions(inputFormat)
        let outputSize = CMVideoFormatDescriptionGetDimensions(outputFormat)
        #expect(inputSize.width == outputSize.width && inputSize.height == outputSize.height)
        for key in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
                    kCMFormatDescriptionExtension_YCbCrMatrix] {
            let before = CMFormatDescriptionGetExtension(inputFormat, extensionKey: key) as? NSObject
            let after = CMFormatDescriptionGetExtension(outputFormat, extensionKey: key) as? NSObject
            #expect(before == after)
        }
        // MOV and MP4 sample-entry bookkeeping differs. Compare the actual
        // compressed samples, rather than requiring identical container atoms.
        let before = try await compressedVideoSamples(motion)
        let after = try await compressedVideoSamples(pair.video)
        #expect(!before.isEmpty)
        #expect(before == after)
    }

    @Test(.timeLimit(.minutes(1))) func removesProcessingCaptionWithoutChangingPixelsColorOrLivePhotoIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("original.heic")
        try FileManager.default.copyItem(at: fixture("livephoto-original", "heic"), to: photo)
        let originalData = try Data(contentsOf: photo)
        let cleaned = try PhotoImportMetadata.prepare(photo)
        #expect(cleaned != photo)
        #expect(try Data(contentsOf: photo) == originalData)
        let originalSource = try #require(CGImageSourceCreateWithURL(photo as CFURL, nil))
        let cleanedSource = try #require(CGImageSourceCreateWithURL(cleaned as CFURL, nil))
        #expect(CGImageSourceGetType(originalSource) == CGImageSourceGetType(cleanedSource))
        let original = try #require(CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [String: Any])
        let result = try #require(CGImageSourceCopyPropertiesAtIndex(cleanedSource, 0, nil) as? [String: Any])
        let originalTIFF = try #require(original[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(PhotoImportMetadata.isProcessingTelemetry(try #require(originalTIFF[kCGImagePropertyTIFFImageDescription as String] as? String)))
        let resultTIFF = result[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let resultIPTC = result[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        #expect(resultTIFF?[kCGImagePropertyTIFFImageDescription as String] == nil)
        #expect(resultIPTC?[kCGImagePropertyIPTCCaptionAbstract as String] == nil)
        for key in [
            kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
            kCGImagePropertyColorModel, kCGImagePropertyProfileName, kCGImagePropertyOrientation,
            kCGImagePropertyMakerAppleDictionary, "ContentLightLevelInfo" as CFString
        ] {
            #expect((original[key as String] as? NSObject) == (result[key as String] as? NSObject))
        }
        let originalImage = try #require(CGImageSourceCreateImageAtIndex(originalSource, 0, nil))
        let cleanedImage = try #require(CGImageSourceCreateImageAtIndex(cleanedSource, 0, nil))
        #expect(originalImage.bitsPerComponent == cleanedImage.bitsPerComponent)
        #expect(originalImage.colorSpace == cleanedImage.colorSpace)
        let originalPixels = try #require(originalImage.dataProvider?.data) as Data
        let cleanedPixels = try #require(cleanedImage.dataProvider?.data) as Data
        #expect(originalPixels == cleanedPixels)
        #expect(try PhotoImportMetadata.prepare(cleaned) == cleaned)

        let pair = try await LivePhotoPairer.pair(photo: cleaned, video: fixture("livephoto-motion", "mp4"))
        let live: PHLivePhoto? = await withCheckedContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [pair.photo, pair.video], placeholderImage: nil,
                                targetSize: CGSize(width: 216, height: 288), contentMode: .aspectFit) { live, info in
                if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
                continuation.resume(returning: live)
            }
        }
        #expect(live != nil)
    }

    @Test func keepsHumanCaptionsAndUnrelatedJSON() async {
        #expect(PhotoImportMetadata.isProcessingTelemetry(#"{\"capa_image_quality_process_sink_v2\":\"1\",\"DeviceModel\":\"iPhone15,5\"}"#))
        #expect(PhotoImportMetadata.isProcessingTelemetry(#"{"capa_image_quality_process_sink":"1"}"#))
        for caption in [
            "DeepSeek V4.1 Flash：更强、更快、更普惠", "capa_image_quality_process_sink_v2",
            #"{"caption":"旅行随拍","DeviceModel":"iPhone15,5"}"#,
            #"{"caption":"作者自己的说明","capa_image_quality_process_sink":"1"}"#
        ] {
            #expect(!PhotoImportMetadata.isProcessingTelemetry(caption))
        }
    }

    private func compressedVideoSamples(_ url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var result: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let buffer = try #require(CMSampleBufferGetDataBuffer(sample))
            var data = Data(count: CMBlockBufferGetDataLength(buffer))
            let length = data.count
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            #expect(status == noErr)
            result.append(data)
        }
        #expect(reader.status == .completed)
        return result
    }
}

private final class MobileShareFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Reproduce the observed server behavior: desktop requests get the home
        // page, so they cannot resolve this particular app-share link.
        let mobile = request.value(forHTTPHeaderField: "User-Agent")?.contains("iPhone") == true
        let canonical = URL(string: "https://www.xiaohongshu.com/discovery/item/6aa2443700000000260303c2?xsec_token=fixture-token")!
        let home = URL(string: "https://www.xiaohongshu.com/")!
        do {
            let file = try #require(Bundle(for: LivePhotoFixtureBundle.self)
                .url(forResource: "livephoto-note", withExtension: "json"))
            let json = try String(contentsOf: file, encoding: .utf8)
            let html = mobile ? "<script>window.__INITIAL_STATE__ = \(json);</script>" : "<html>Home</html>"
            let response = HTTPURLResponse(url: mobile ? canonical : home, statusCode: 200,
                                          httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(html.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
