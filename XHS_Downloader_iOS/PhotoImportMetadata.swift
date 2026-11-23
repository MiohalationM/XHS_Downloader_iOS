import Foundation
import ImageIO

enum PhotoImportMetadata {
    /// Remove XHS processing telemetry that Photos otherwise displays as a caption.
    /// Return the input unchanged when it has no such caption.
    static func prepare(_ photo: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(photo as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let edited = CGImageMetadataCreateMutableCopy(metadata) else { return photo }
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        let captions = [
            tiff?[kCGImagePropertyTIFFImageDescription as String] as? String,
            iptc?[kCGImagePropertyIPTCCaptionAbstract as String] as? String
        ].compactMap { $0 }.filter { !$0.isEmpty }
        guard !captions.isEmpty, captions.allSatisfy(isProcessingTelemetry),
              CGImageMetadataRemoveTagWithPath(edited, nil, "dc:description" as CFString),
              let type = CGImageSourceGetType(source) else { return photo }

        let output = photo.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(photo.pathExtension)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw MediaValidationError.invalidResponse
        }
        // Copy compressed image data; never decode/re-encode or convert to JPEG.
        var error: Unmanaged<CFError>?
        let copied = CGImageDestinationCopyImageSource(destination, source, [
            kCGImageDestinationMetadata: edited,
            kCGImageDestinationMergeMetadata: false,
            kCGImageDestinationPreserveGainMap: true
        ] as CFDictionary, &error)
        if let error { throw error.takeRetainedValue() as Error }
        guard copied,
              let result = CGImageSourceCreateWithURL(output as CFURL, nil),
              let after = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [String: Any] else {
            throw MediaValidationError.invalidResponse
        }
        for key in [
            kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
            kCGImagePropertyColorModel, kCGImagePropertyProfileName, kCGImagePropertyOrientation,
            kCGImagePropertyMakerAppleDictionary, "ContentLightLevelInfo" as CFString
        ] {
            if let value = properties[key as String] as? NSObject,
               !value.isEqual(after[key as String]) { throw MediaValidationError.invalidResponse }
        }
        for type in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] {
            if let before = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [String: Any] {
                guard let after = CGImageSourceCopyAuxiliaryDataInfoAtIndex(result, 0, type) as? [String: Any],
                      let data = before[kCGImageAuxiliaryDataInfoData as String] as? Data,
                      data == after[kCGImageAuxiliaryDataInfoData as String] as? Data,
                      let description = before[kCGImageAuxiliaryDataInfoDataDescription as String] as? NSDictionary,
                      description.isEqual(after[kCGImageAuxiliaryDataInfoDataDescription as String]) else {
                    throw MediaValidationError.invalidResponse
                }
            }
        }
        let resultTIFF = after[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let resultIPTC = after[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        guard (resultTIFF?[kCGImagePropertyTIFFImageDescription as String] as? String ?? "").isEmpty,
              (resultIPTC?[kCGImagePropertyIPTCCaptionAbstract as String] as? String ?? "").isEmpty else {
            throw MediaValidationError.invalidResponse
        }
        completed = true
        return output
    }

    static func isProcessingTelemetry(_ text: String) -> Bool {
        // Upstream stores either JSON or JSON with escaped quotes. Require the
        // known processing keys so an author's normal caption is left intact.
        let json = text.replacingOccurrences(of: "\\\"", with: "\"")
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.contains(where: { $0.hasPrefix("capa_image_quality_") }) else { return false }
        return object.keys.allSatisfy { $0.hasPrefix("capa_image_quality_") || $0 == "DeviceModel" }
    }
}
