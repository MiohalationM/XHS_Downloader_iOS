import Foundation
import Photos
import UniformTypeIdentifiers

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
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.permissionDenied }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { throw PhotoLibraryError.saveFailed }
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { throw PhotoLibraryError.saveFailed }

        // Pick one resource per logical slot (original preferred over rendered)
        // so edited Photos assets are never exported twice.
        var ordered: [PHAssetResource] = []
        if asset.mediaType == .video {
            if let video = resources.first(where: { $0.type == .video }) ?? resources.first(where: { $0.type == .fullSizeVideo }) {
                ordered.append(video)
            }
        } else {
            if let photo = resources.first(where: { $0.type == .photo }) ?? resources.first(where: { $0.type == .fullSizePhoto }) {
                ordered.append(photo)
            }
            if asset.mediaSubtypes.contains(.photoLive),
               let motion = resources.first(where: { $0.type == .pairedVideo }) ?? resources.first(where: { $0.type == .fullSizePairedVideo }) {
                ordered.append(motion)
            }
        }
        if ordered.isEmpty {
            ordered = resources.filter { [.photo, .fullSizePhoto, .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo].contains($0.type) }
        }
        guard !ordered.isEmpty else { throw PhotoLibraryError.saveFailed }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var result: [Original] = []
        for (index, resource) in ordered.enumerated() {
            try Task.checkCancellation()
            var base = (resource.originalFilename as NSString).lastPathComponent
            if base.isEmpty || base == "/" || base == "." {
                let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? "bin"
                base = "asset-\(index + 1).\(ext)"
            }
            let name = String(format: "%02d-%@", index + 1, base)
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
            let paired = resource.type == .pairedVideo || resource.type == .fullSizePairedVideo
            result.append(Original(fileURL: url,
                                   isVideo: resource.type == .video || resource.type == .fullSizeVideo,
                                   isPairedVideo: paired))
        }
        guard !result.isEmpty else { throw PhotoLibraryError.saveFailed }
        return result
    }
}
