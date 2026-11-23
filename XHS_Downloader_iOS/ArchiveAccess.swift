import Foundation
import UIKit
import AVFoundation
import ImageIO

/// Device-local capability. Original paths remain stable identifiers; resolving
/// the bookmark can relocate the directory without changing those identifiers.
struct ArchiveGrant: Codable, Hashable, Sendable {
    var rootPath: String
    var bookmark: Data

    init?(bookmark: Data?) {
        guard let bookmark, let root = ArchiveDirectory.resolve(bookmark) else { return nil }
        self.rootPath = root.standardizedFileURL.path
        self.bookmark = bookmark
    }

    func relativePath(for path: String) -> String? {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// A renewed note grant wins over older task snapshots for the same root.
    /// Stable ordering avoids a different Set order triggering a write at launch.
    static func merging(_ preferred: [ArchiveGrant], fallback: [ArchiveGrant]) -> [ArchiveGrant] {
        var roots = Set<String>()
        return (preferred + fallback).filter { roots.insert($0.rootPath).inserted }
            .sorted { $0.rootPath < $1.rootPath }
    }
}

/// A lease lives as long as a file operation or AVPlayer. Every successful
/// startAccessing is balanced on the exact URL, including error/cancel paths.
final class ArchiveLease: @unchecked Sendable {
    let urls: [URL]
    private let scopedRoots: [URL]
    init(urls: [URL], scopedRoots: [URL]) { self.urls = urls; self.scopedRoots = scopedRoots }
    deinit { scopedRoots.forEach { $0.stopAccessingSecurityScopedResource() } }
}

/// Only the capability index is shared across executors. File operations happen
/// on their existing actors, not under this short lock or on the UI thread.
final class ArchiveAccess: @unchecked Sendable {
    static let shared = ArchiveAccess()
    private let lock = NSLock()
    private var grants: [ArchiveGrant] = []

    func register(_ values: [ArchiveGrant], replacingExisting: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        for value in values {
            if !replacingExisting, grants.contains(where: { $0.rootPath == value.rootPath }) { continue }
            grants.removeAll { $0.rootPath == value.rootPath }
            grants.append(value)
        }
    }

    func lease(paths: [String], grants explicit: [ArchiveGrant] = []) throws -> ArchiveLease {
        lock.lock()
        let registered = grants
        lock.unlock()
        let choices = ArchiveGrant.merging(explicit, fallback: registered)
            .sorted { $0.rootPath.count > $1.rootPath.count }
        var roots: [Data: URL] = [:]
        var scoped: [URL] = []
        do {
            let urls = try paths.map { path -> URL in
                guard let grant = choices.first(where: { $0.relativePath(for: path) != nil }),
                      let relative = grant.relativePath(for: path) else {
                    // Older sandbox-local archives need no external grant.
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    guard url.path.hasPrefix(NSHomeDirectory() + "/") ||
                            url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else {
                        throw ArchiveError.directoryUnavailable
                    }
                    return url
                }
                let root: URL
                if let existing = roots[grant.bookmark] { root = existing }
                else {
                    guard let resolved = ArchiveDirectory.resolve(grant.bookmark) else {
                        throw ArchiveError.directoryUnavailable
                    }
                    root = resolved
                    if root.startAccessingSecurityScopedResource() { scoped.append(root) }
                    roots[grant.bookmark] = root
                }
                return root.appendingPathComponent(relative)
            }
            return ArchiveLease(urls: urls, scopedRoots: scoped)
        } catch {
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    static func paths(in identifier: String) -> [String] {
        guard identifier.hasPrefix("file:") else { return [] }
        return identifier.dropFirst(5).split(separator: "\n").map(String.init)
    }
}

actor ArchiveMediaLoader {
    static let shared = ArchiveMediaLoader()
    private let thumbnails = NSCache<NSString, UIImage>()

    init() {
        thumbnails.totalCostLimit = 24 * 1024 * 1024
        thumbnails.countLimit = 100
    }

    func lease(identifier: String) throws -> ArchiveLease {
        let paths = ArchiveAccess.paths(in: identifier)
        guard !paths.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        return try ArchiveAccess.shared.lease(paths: paths)
    }

    func reauthorize(grants: [ArchiveGrant], paths: [String], directory: URL) throws -> [ArchiveGrant] {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let bookmark = try ArchiveDirectory.makeBookmark(for: directory)
        var candidates = grants
        if candidates.isEmpty, let first = paths.first, var inferred = ArchiveGrant(bookmark: bookmark) {
            var root = URL(fileURLWithPath: first).deletingLastPathComponent()
            while !paths.allSatisfy({ URL(fileURLWithPath: $0).path.hasPrefix(root.path + "/") }), root.path != "/" {
                root.deleteLastPathComponent()
            }
            // Legacy notes did not record which ancestor the user selected.
            // Match complete relative paths, including author/note subfolders.
            while root.path != "/" {
                inferred.rootPath = root.path
                let relatives = paths.compactMap { inferred.relativePath(for: $0) }
                if relatives.count == paths.count,
                   relatives.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                    candidates = [inferred]
                    break
                }
                root.deleteLastPathComponent()
            }
        }
        var matched = false
        let updated = candidates.map { grant -> ArchiveGrant in
            let relative = paths.compactMap { grant.relativePath(for: $0) }
            guard !relative.isEmpty,
                  relative.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
                return grant
            }
            matched = true
            var renewed = grant
            renewed.bookmark = bookmark
            return renewed
        }
        guard matched else { throw ArchiveError.directoryUnavailable }
        return updated
    }

    func image(identifier: String, thumbnail: Bool) async throws -> UIImage {
        if thumbnail, let image = thumbnails.object(forKey: identifier as NSString) { return image }
        let paths = ArchiveAccess.paths(in: identifier)
        guard !paths.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let lease = try ArchiveAccess.shared.lease(paths: paths)
        defer { withExtendedLifetime(lease) {} }
        try Task.checkCancellation()
        var image: UIImage?
        for url in lease.urls where !MediaFileValidator.isVideoFile(url) {
            if thumbnail {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600
                   ] as CFDictionary) { image = UIImage(cgImage: cg) }
            } else { image = UIImage(contentsOfFile: url.path) }
            if image != nil { break }
        }
        if image == nil, let video = lease.urls.first(where: { MediaFileValidator.isVideoFile($0) }) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: thumbnail ? 600 : 1600, height: thumbnail ? 600 : 1600)
            if let frame = try? await generator.image(at: .zero) { image = UIImage(cgImage: frame.image) }
            // A valid movie can play even if its first frame cannot be decoded.
            if image == nil { image = UIImage() }
        }
        try Task.checkCancellation()
        guard let image else { throw CocoaError(.fileReadCorruptFile) }
        if thumbnail, let cg = image.cgImage {
            thumbnails.setObject(image, forKey: identifier as NSString, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    func clearThumbnails() { thumbnails.removeAllObjects() }
}

struct MediaDeletionFailure: LocalizedError {
    let deleted: Set<String>
    let failures: [String]
    var errorDescription: String? { L10n.format("library.delete.partial", deleted.count, failures.count) }
}

actor MediaDeletionService {
    static let shared = MediaDeletionService()

    func delete(_ identifiers: Set<String>, photos: any PhotoLibraryServing = PhotoLibraryService.shared) async throws {
        let photoIDs = identifiers.filter { !$0.hasPrefix("file:") }
        // Cancellation at the system confirmation must precede every disk write.
        if !photoIDs.isEmpty { try await photos.deleteAssets(localIdentifiers: Array(photoIDs)) }
        var deleted = Set(photoIDs)
        var failures: [String] = []
        for id in identifiers where id.hasPrefix("file:") {
            do {
                let lease = try ArchiveAccess.shared.lease(paths: ArchiveAccess.paths(in: id))
                defer { withExtendedLifetime(lease) {} }
                for url in lease.urls {
                    do { try FileManager.default.removeItem(at: url) }
                    catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                        // A retry can follow a partially removed pair. Permission
                        // errors still propagate instead of looking like absence.
                        continue
                    }
                }
                deleted.insert(id)
            } catch { failures.append(id) }
        }
        if !failures.isEmpty { throw MediaDeletionFailure(deleted: deleted, failures: failures) }
    }
}
