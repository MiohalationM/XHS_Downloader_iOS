import Foundation
@preconcurrency import AVFoundation
import ImageIO

enum LivePhotoPairingError: LocalizedError {
    case unsupported
    var errorDescription: String? { L10n.text("error.live_pair") }
}

enum LivePhotoPairer {
    struct Pair: Sendable { let photo: URL; let video: URL }

    static func pair(photo: URL, video: URL) async throws -> Pair {
        let directory = photo.deletingLastPathComponent()
        let source = CGImageSourceCreateWithURL(photo as CFURL, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let maker = properties?[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        let existing = (maker?["17"] as? String)?.trimmingCharacters(in: .controlCharacters)
        let identifier = existing?.isEmpty == false ? existing! : UUID().uuidString
        let pairedPhoto: URL
        if existing?.isEmpty == false {
            pairedPhoto = photo
        } else {
            // ImageIO's lossless copy cannot set MakerApple.17. For JPEG, amend
            // EXIF only; all compressed pixels, ICC and auxiliary segments stay
            // byte-for-byte unchanged. Other containers must already carry ID.
            let input = try Data(contentsOf: photo, options: .mappedIfSafe)
            let output = try JPEGPairingMetadata.addIdentifier(identifier, to: input)
            pairedPhoto = directory.appendingPathComponent(UUID().uuidString + ".jpg")
            try output.write(to: pairedPhoto, options: .atomic)
            do { try verifyImage(source: photo, paired: pairedPhoto, identifier: identifier) }
            catch {
                try? FileManager.default.removeItem(at: pairedPhoto)
                throw error
            }
        }
        let movie = directory.appendingPathComponent(UUID().uuidString + ".mov")
        do {
            try await remux(video, to: movie, identifier: identifier)
            return Pair(photo: pairedPhoto, video: movie)
        } catch {
            if pairedPhoto != photo { try? FileManager.default.removeItem(at: pairedPhoto) }
            try? FileManager.default.removeItem(at: movie)
            throw error
        }
    }

    private static func verifyImage(source: URL, paired: URL, identifier: String) throws {
        guard let original = CGImageSourceCreateWithURL(source as CFURL, nil),
              let output = CGImageSourceCreateWithURL(paired as CFURL, nil),
              let originalProperties = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as NSDictionary?,
              let properties = CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as NSDictionary?,
              let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any],
              (maker["17"] as? String)?.trimmingCharacters(in: .controlCharacters) == identifier else {
            throw LivePhotoPairingError.unsupported
        }
        for property in [kCGImagePropertyDepth, kCGImagePropertyColorModel, kCGImagePropertyProfileName, kCGImagePropertyOrientation] {
            if let value = originalProperties[property] as? NSObject,
               !value.isEqual(properties[property]) { throw LivePhotoPairingError.unsupported }
        }
        for type in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] {
            if let originalMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(original, 0, type) as NSDictionary? {
                guard let copiedMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(output, 0, type) as NSDictionary?,
                      let data = originalMap[kCGImageAuxiliaryDataInfoData] as? Data,
                      data == copiedMap[kCGImageAuxiliaryDataInfoData] as? Data,
                      (originalMap[kCGImageAuxiliaryDataInfoDataDescription] as? NSDictionary)?
                        .isEqual(copiedMap[kCGImageAuxiliaryDataInfoDataDescription]) == true else {
                    throw LivePhotoPairingError.unsupported
                }
            }
        }
    }

    private static func remux(_ source: URL, to destination: URL, identifier: String) async throws {
        let asset = AVURLAsset(url: source)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let contentID = AVMutableMetadataItem()
        contentID.identifier = .quickTimeMetadataContentIdentifier
        contentID.value = identifier as NSString
        contentID.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = try await asset.load(.metadata).filter { $0.identifier != .quickTimeMetadataContentIdentifier } + [contentID]

        var streams: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for type in [AVMediaType.video, .audio] {
            for track in try await asset.loadTracks(withMediaType: type) {
                let descriptions = try await track.load(.formatDescriptions)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                let input = AVAssetWriterInput(mediaType: type, outputSettings: nil, sourceFormatHint: descriptions.first)
                input.expectsMediaDataInRealTime = false
                if type == .video { input.transform = try await track.load(.preferredTransform) }
                guard reader.canAdd(output), writer.canAdd(input) else { throw LivePhotoPairingError.unsupported }
                reader.add(output)
                writer.add(input)
                streams.append((output, input))
            }
        }
        guard streams.contains(where: { $0.1.mediaType == .video }) else { throw LivePhotoPairingError.unsupported }
        var description: CMFormatDescription?
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8
        ]
        guard CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description
        ) == noErr else { throw LivePhotoPairingError.unsupported }
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        guard writer.canAdd(metadataInput) else { throw LivePhotoPairingError.unsupported }
        writer.add(metadataInput)
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? LivePhotoPairingError.unsupported }
        writer.startSession(atSourceTime: .zero)
        let time = AVMutableMetadataItem()
        time.keySpace = .quickTimeMetadata
        time.key = "com.apple.quicktime.still-image-time" as NSString
        time.value = NSNumber(value: Int8(0))
        time.dataType = kCMMetadataBaseDataType_SInt8 as String
        guard adaptor.append(AVTimedMetadataGroup(items: [time], timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30)))) else {
            reader.cancelReading(); writer.cancelWriting(); throw LivePhotoPairingError.unsupported
        }
        metadataInput.markAsFinished()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (output, input) in streams {
                    group.addTask {
                        try await copySamples(output: output, input: input, reader: reader, writer: writer)
                    }
                }
                try await group.waitForAll()
            }
            try Task.checkCancellation()
            guard reader.status == .completed else { throw reader.error ?? LivePhotoPairingError.unsupported }
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? LivePhotoPairingError.unsupported }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }

    private static func copySamples(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput,
                                    reader: AVAssetReader, writer: AVAssetWriter) async throws {
        // Each track has one consumer; nil output settings pass compressed
        // samples and their format descriptions through without transcoding.
        defer { input.markAsFinished() }
        while true {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? LivePhotoPairingError.unsupported }
            if !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed { throw reader.error ?? LivePhotoPairingError.unsupported }
                return
            }
            guard input.append(sample) else { throw writer.error ?? LivePhotoPairingError.unsupported }
        }
    }
}

/// APP1/TIFF editing without decoding or re-encoding JPEG image data.
enum JPEGPairingMetadata {
    static func addIdentifier(_ identifier: String, to jpeg: Data) throws -> Data {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0...1] == [0xFF, 0xD8] else { throw LivePhotoPairingError.unsupported }
        var position = 2
        while position + 4 <= bytes.count {
            guard bytes[position] == 0xFF else { throw LivePhotoPairingError.unsupported }
            let marker = bytes[position + 1]
            if marker == 0xDA || marker == 0xD9 { break }
            let length = Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
            guard length >= 2, position + 2 + length <= bytes.count else { throw LivePhotoPairingError.unsupported }
            if marker == 0xE1, length >= 8,
               Array(bytes[(position + 4)..<(position + 10)]) == [69, 120, 105, 102, 0, 0] {
                let tiff = Data(bytes[(position + 10)..<(position + 2 + length)])
                let updated = try amendTIFF(tiff, identifier: identifier)
                let segment = try exifSegment(updated)
                return Data(bytes[..<position]) + segment + Data(bytes[(position + 2 + length)...])
            }
            position += 2 + length
        }
        let tiff = Data([0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0])
        return Data(bytes[..<2]) + (try exifSegment(amendTIFF(tiff, identifier: identifier))) + Data(bytes[2...])
    }

    private static func exifSegment(_ tiff: Data) throws -> Data {
        let length = tiff.count + 8
        guard length <= 65_535 else { throw LivePhotoPairingError.unsupported }
        return Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 255), 69, 120, 105, 102, 0, 0]) + tiff
    }

    private static func amendTIFF(_ data: Data, identifier: String) throws -> Data {
        var bytes = [UInt8](data)
        guard bytes.count >= 8 else { throw LivePhotoPairingError.unsupported }
        let little = bytes[0] == 0x49 && bytes[1] == 0x49
        guard little || (bytes[0] == 0x4D && bytes[1] == 0x4D) else { throw LivePhotoPairingError.unsupported }
        func number(_ at: Int, _ count: Int) throws -> Int {
            guard at >= 0, at <= bytes.count - count else { throw LivePhotoPairingError.unsupported }
            let slice = bytes[at..<(at + count)]
            return (little ? Array(slice.reversed()) : Array(slice)).reduce(0) { ($0 << 8) | Int($1) }
        }
        func encode(_ value: Int, _ count: Int) -> [UInt8] {
            let result = (0..<count).map { UInt8((value >> (($0) * 8)) & 255) }
            return little ? result : result.reversed()
        }
        func entries(_ offset: Int) throws -> ([[UInt8]], [UInt8]) {
            let count = try number(offset, 2)
            guard count <= 4096, offset + 2 + count * 12 + 4 <= bytes.count else { throw LivePhotoPairingError.unsupported }
            let result = (0..<count).map { index -> [UInt8] in
                let start = offset + 2 + index * 12
                return Array(bytes[start..<(start + 12)])
            }
            return (result, Array(bytes[(offset + 2 + count * 12)..<(offset + 6 + count * 12)]))
        }
        func tag(_ entry: [UInt8]) -> Int { little ? Int(entry[0]) | Int(entry[1]) << 8 : Int(entry[0]) << 8 | Int(entry[1]) }
        let rootOffset = try number(4, 4)
        let (root, nextIFD) = try entries(rootOffset)
        var exifEntries: [[UInt8]] = []
        if let pointer = root.first(where: { tag($0) == 0x8769 }) {
            let pointerBytes = little ? Array(pointer[8..<12].reversed()) : Array(pointer[8..<12])
            let offset = pointerBytes.reduce(0) { ($0 << 8) | Int($1) }
            exifEntries = try entries(offset).0
        }
        // Never discard an unknown MakerNote. Apple images with an existing
        // content ID take the unchanged-image path before reaching this code.
        guard !exifEntries.contains(where: { tag($0) == 0x927C }) else { throw LivePhotoPairingError.unsupported }
        // Apple MakerNote has its own big-endian TIFF directory at byte 14.
        var maker = Array("Apple iOS".utf8) + [0, 0, 1, 0x4D, 0x4D, 0, 1]
        let value = Array(identifier.utf8) + [0]
        func big(_ value: Int, _ count: Int) -> [UInt8] {
            (0..<count).reversed().map { UInt8((value >> ($0 * 8)) & 255) }
        }
        maker += [0, 17, 0, 2] + big(value.count, 4) + big(32, 4) + [0, 0, 0, 0] + value
        if bytes.count % 2 != 0 { bytes.append(0) }
        let makerOffset = bytes.count
        bytes += maker
        exifEntries.append(encode(0x927C, 2) + encode(7, 2) + encode(maker.count, 4) + encode(makerOffset, 4))
        exifEntries.sort { tag($0) < tag($1) }
        if bytes.count % 2 != 0 { bytes.append(0) }
        let exifOffset = bytes.count
        bytes += encode(exifEntries.count, 2) + exifEntries.flatMap { $0 } + [0, 0, 0, 0]
        var newRoot = root.filter { tag($0) != 0x8769 }
        newRoot.append(encode(0x8769, 2) + encode(4, 2) + encode(1, 4) + encode(exifOffset, 4))
        newRoot.sort { tag($0) < tag($1) }
        let newRootOffset = bytes.count
        bytes += encode(newRoot.count, 2) + newRoot.flatMap { $0 } + nextIFD
        bytes.replaceSubrange(4..<8, with: encode(newRootOffset, 4))
        return Data(bytes)
    }
}
