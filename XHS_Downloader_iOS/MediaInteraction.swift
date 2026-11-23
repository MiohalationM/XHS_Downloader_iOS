import UIKit
import SwiftUI
import Photos
import AVFoundation
import Combine

struct MediaViewerSelection: Identifiable {
    let id: String
    let identifiers: [String]
    let image: UIImage
}

/// Only full-quality stills belong here, never grid thumbnails.
@MainActor
final class MediaPreviewImages: ObservableObject {
    static let shared = MediaPreviewImages()
    private let images = NSCache<NSString, UIImage>()

    init() {
        images.totalCostLimit = 72 * 1024 * 1024
        images.countLimit = 6
    }

    func image(for id: String) -> UIImage? { images.object(forKey: id as NSString) }
    func remove(identifiers: [String]) {
        identifiers.forEach { images.removeObject(forKey: $0 as NSString) }
        objectWillChange.send()
    }
    func insert(_ image: UIImage, for id: String) {
        if let existing = self.image(for: id),
           existing.size.width * existing.scale >= image.size.width * image.scale,
           existing.size.height * existing.scale >= image.size.height * image.scale { return }
        let pixels = image.cgImage
        let cost = (pixels?.bytesPerRow ?? Int(image.size.width * image.scale) * 4) *
            (pixels?.height ?? Int(image.size.height * image.scale))
        images.setObject(image, forKey: id as NSString, cost: cost)
        objectWillChange.send()
    }
}

@MainActor
final class MediaPresentation: ObservableObject {
    @Published var selection: MediaViewerSelection?
    @Published private(set) var loadingIdentifier: String?
    @Published var errorMessage: String?
    private var request: PHImageRequestID?
    private var generation = UUID()
    private var fileLoad: Task<Void, Never>?

    func open(_ id: String, identifiers: [String]) {
        cancel()
        AppFeedback.play(.navigation)
        if let image = MediaPreviewImages.shared.image(for: id) {
            selection = MediaViewerSelection(id: id, identifiers: identifiers, image: image)
            return
        }
        if id.hasPrefix("file:") {
            loadingIdentifier = id
            let token = generation
            fileLoad = Task { [weak self] in
                do {
                    let image = try await ArchiveMediaLoader.shared.image(identifier: id, thumbnail: false)
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.loadingIdentifier = nil
                    MediaPreviewImages.shared.insert(image, for: id)
                    self.selection = MediaViewerSelection(id: id, identifiers: identifiers, image: image)
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.loadingIdentifier = nil
                    self.errorMessage = error.localizedDescription
                    AppFeedback.play(.error)
                }
            }
            return
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            errorMessage = L10n.text("viewer.unavailable")
            AppFeedback.play(.error)
            return
        }
        loadingIdentifier = id
        let token = generation
        let options = PHImageRequestOptions()
        options.preferHDR = true
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        request = PHImageManager.default().requestImage(
            for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options
        ) { [weak self] image, info in
            let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
            let cancelled = info?[PHImageCancelledKey] as? Bool == true
            Task { @MainActor in
                guard let self, self.generation == token, !degraded, !cancelled else { return }
                self.request = nil
                self.loadingIdentifier = nil
                guard let image else {
                    self.errorMessage = L10n.text("viewer.unavailable")
                    AppFeedback.play(.error)
                    return
                }
                MediaPreviewImages.shared.insert(image, for: id)
                // The destination must have a sharp first frame before zooming in.
                self.selection = MediaViewerSelection(id: id, identifiers: identifiers, image: image)
            }
        }
    }

    func cancel() {
        generation = UUID()
        fileLoad?.cancel()
        fileLoad = nil
        if let request { PHImageManager.default().cancelImageRequest(request) }
        request = nil
        loadingIdentifier = nil
    }
}

func isPhotosCancellation(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.Code.userCancelled.rawValue
}

struct MediaShareFiles: Identifiable, Sendable {
    let id = UUID()
    let directory: URL
    let urls: [URL]
}

actor MediaExporter {
    static let shared = MediaExporter()

    func export(notes: [LibraryNote]) async throws -> MediaShareFiles {
        var seen = Set<String>()
        let identifiers = notes.flatMap(\.identifiers).filter { seen.insert($0).inserted }
        let files = try await export(identifiers: identifiers)
        do {
            var urls = files.urls
            for (index, note) in notes.enumerated() {
                let text = [note.title, note.body, note.sourceURL?.absoluteString ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
                guard !text.isEmpty else { continue }
                let url = files.directory.appendingPathComponent("note-\(index + 1).txt")
                try text.write(to: url, atomically: true, encoding: .utf8)
                urls.append(url)
            }
            return MediaShareFiles(directory: files.directory, urls: urls)
        } catch {
            try? FileManager.default.removeItem(at: files.directory)
            throw error
        }
    }

    func export(identifiers: [String]) async throws -> MediaShareFiles {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Share-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var urls: [URL] = []
            for (index, id) in identifiers.enumerated() {
                try Task.checkCancellation()
                // Files-only media is shared by copying the archived files; asking
                // Photos for it would fail and would needlessly request access.
                if id.hasPrefix("file:") {
                    // Share every component: a Live Photo's still and motion.
                    let paths = ArchiveAccess.paths(in: id)
                    let lease = try ArchiveAccess.shared.lease(paths: paths)
                    defer { withExtendedLifetime(lease) {} }
                    var copied = 0
                    for source in lease.urls {
                        let target = directory.appendingPathComponent("\(index + 1)-\(copied)-\(source.lastPathComponent)")
                        try FileManager.default.copyItem(at: source, to: target)
                        urls.append(target)
                        copied += 1
                    }
                    guard copied > 0 else { throw PhotoLibraryError.saveFailed }
                    continue
                }
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                    throw PhotoLibraryError.permissionDenied
                }
                let resources = PHAssetResource.assetResources(for: asset)
                // A Live Photo is exported as its unchanged still and motion
                // components. Never flatten it to a JPEG for the share sheet.
                let types: [PHAssetResourceType] = asset.mediaType == .video ? [.video] :
                    asset.mediaSubtypes.contains(.photoLive) ? [.photo, .pairedVideo] : [.photo]
                for type in types {
                    guard let resource = resources.first(where: { $0.type == type }) else {
                        throw PhotoLibraryError.saveFailed
                    }
                    let filename = (resource.originalFilename as NSString).lastPathComponent
                    let url = directory.appendingPathComponent("\(index + 1)-\(filename)")
                    let options = PHAssetResourceRequestOptions()
                    options.isNetworkAccessAllowed = true
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume() }
                        }
                    }
                    urls.append(url)
                }
            }
            return MediaShareFiles(directory: directory, urls: urls)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

struct MediaShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
