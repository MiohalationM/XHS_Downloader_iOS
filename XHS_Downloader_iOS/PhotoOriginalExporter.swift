import Foundation
import Photos

/// Reads the real original bytes out of the photo library. A default
/// "Photos" download has no file path on disk, so an export that only reads
/// `filesPaths` produces an archive with no media. This exporter asks Photos for
/// the underlying resources instead, which also keeps Live Photo's two
/// components intact instead of flattening them.
actor PhotoOriginalExporter {
    static let shared = PhotoOriginalExporter()

    struct Original {
        let fileURL: URL
        let isVideo: Bool
        let isPairedVideo: Bool
    }

    /// Writes every resource of an asset into `directory` and returns them in a
    /// stable order: still first, then motion.
    func export(localIdentifier: String, into directory: URL) async throws -> [Original] {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { throw PhotoLibraryError.permissionDenied }
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { throw PhotoLibraryError.saveFailed }

        // A Live Photo is exported as its unchanged still plus its motion
        // component; neither is re-encoded here.
        let wanted: [PHAssetResourceType] = asset.mediaType == .video
            ? [.video, .fullSizeVideo]
            : (asset.mediaSubtypes.contains(.photoLive) ? [.photo, .fullSizePhoto, .pairedVideo] : [.photo, .fullSizePhoto])

        var ordered: [PHAssetResource] = []
        for type in wanted {
            if let resource = resources.first(where: { $0.type == type }), !ordered.contains(where: { $0 === resource }) {
                ordered.append(resource)
            }
        }
        // Fall back to whatever exists so an unusual asset still exports.
        if ordered.isEmpty {
            ordered = resources.filter { [.photo, .fullSizePhoto, .video, .fullSizeVideo, .pairedVideo].contains($0.type) }
        }
        guard !ordered.isEmpty else { throw PhotoLibraryError.saveFailed }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var result: [Original] = []
        for (index, resource) in ordered.enumerated() {
            let name = String(format: "%02d-%@", index + 1, (resource.originalFilename as NSString).lastPathComponent)
            let url = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            // Skip zero-byte results rather than archiving an empty file.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else { continue }
            result.append(Original(fileURL: url,
                                   isVideo: resource.type == .video || resource.type == .fullSizeVideo,
                                   isPairedVideo: resource.type == .pairedVideo))
        }
        guard !result.isEmpty else { throw PhotoLibraryError.saveFailed }
        return result
    }
}
