import Foundation
import Testing
import Photos
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import XHS_Downloader_iOS

struct MediaPipelineTests {
    @Test func rejectsHTMLAndTruncatedMediaResponses() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("<html>403 forbidden</html>".utf8).write(to: file)
        let url = URL(string: "https://example.com/image.jpg")!
        await #expect(throws: MediaValidationError.self) {
            _ = try await MediaFileValidator.validate(file, response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil), isVideo: false)
        }
        await #expect(throws: MediaValidationError.self) {
            _ = try await MediaFileValidator.validate(file, response: HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil), isVideo: false)
        }
        try jpeg().write(to: file)
        let size = try Data(contentsOf: file).count
        let resumed = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                                     headerFields: ["Content-Range": "bytes 10-\(size - 1)/\(size)", "Content-Length": "\(size - 10)"])
        #expect(try await MediaFileValidator.validate(file, response: resumed, isVideo: false) == "jpeg")
        let truncated = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                                       headerFields: ["Content-Range": "bytes 10-\(size)/\(size + 1)"])
        await #expect(throws: MediaValidationError.self) {
            _ = try await MediaFileValidator.validate(file, response: truncated, isVideo: false)
        }
    }

    @Test(.timeLimit(.minutes(1))) func createsNativeLivePhotoFromLosslessPair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("source.jpg")
        let video = root.appendingPathComponent("source.mov")
        try jpeg().write(to: photo)
        try await movie(at: video)
        let pair = try await LivePhotoPairer.pair(photo: photo, video: video)
        let original = try Data(contentsOf: photo)
        let edited = try Data(contentsOf: pair.photo)
        let scan = try #require(original.range(of: Data([0xFF, 0xDA])))
        let newScan = try #require(edited.range(of: Data([0xFF, 0xDA])))
        #expect(original[scan.lowerBound...] == edited[newScan.lowerBound...])
        let live: PHLivePhoto? = await withCheckedContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [pair.photo, pair.video], placeholderImage: nil,
                                targetSize: CGSize(width: 64, height: 64), contentMode: .aspectFit) { live, info in
                if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
                continuation.resume(returning: live)
            }
        }
        #expect(live != nil)
        let output = AVURLAsset(url: pair.video)
        let metadata = try await output.load(.metadata)
        #expect(metadata.contains { $0.identifier == .quickTimeMetadataContentIdentifier })
        #expect(try await output.loadTracks(withMediaType: .metadata).count == 1)
    }

    private func jpeg() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func movie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer) == kCVReturnSuccess)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(frame * 6), CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            #expect(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
