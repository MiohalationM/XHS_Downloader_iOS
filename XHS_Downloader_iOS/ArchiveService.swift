import Foundation
import CryptoKit
import UIKit

enum ArchiveError: LocalizedError {
    case noDirectory
    case directoryUnavailable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDirectory: return L10n.text("archive.error.nodirectory")
        case .directoryUnavailable: return L10n.text("archive.error.unavailable")
        case .writeFailed(let reason): return L10n.format("archive.error.write", reason)
        }
    }
}

/// Holds the security-scoped bookmark chosen in the system directory picker.
/// The bookmark lives in the task policy snapshot, so an archived task keeps
/// writing to the folder it was created with even after the setting changes.
enum ArchiveDirectory {
    static func makeBookmark(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              !stale else { return nil }
        return url
    }

    static func displayPath(_ data: Data?) -> String? {
        guard let url = resolve(data) else { return nil }
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// A bookmark that no longer resolves is reported as unavailable so the
    /// settings screen can offer a re-authorization action instead of silently
    /// writing nowhere.
    static func isUsable(_ data: Data?) -> Bool {
        guard data != nil else { return false }
        return resolve(data) != nil
    }
}

struct ArchiveResult: Sendable {
    var files: [String] = []
    var captions: [String] = []
    var skipped: [String] = []
    /// Keys whose copy failed. A single failure must not abort the batch: the
    /// remaining resources still belong in the archive.
    var failed: [String: String] = [:]

    /// Existing files that were accepted by the skip check, keyed by resource so
    /// the task can associate them even when nothing was written this time.
    var reused: [String: String] = [:]

    /// Actual destination path per resource key, whether it was written now or
    /// reused. This is the only reliable way to associate the result: a
    /// de-duplicated name ("a_2.heic") never matches a name derived from the
    /// source file.
    var paths: [String: String] = [:]
}

/// Writes originals and captions into the user-selected Files directory.
/// Archive work never mutates the staged file: Photos import still owns it.
actor FileArchiver {
    static let shared = FileArchiver()

    /// Hold the user's folder grant until unchanged originals have been copied
    /// into the existing share-sheet staging area.
    func shareFiles(paths: [String], bookmark: Data?) async throws -> MediaShareFiles {
        if let grant = ArchiveGrant(bookmark: bookmark) {
            ArchiveAccess.shared.register([grant], replacingExisting: false)
        }
        var seen = Set<String>()
        let paths = paths.filter { seen.insert($0).inserted }
        guard !paths.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        return try await MediaExporter.shared.export(identifiers: paths.map { "file:" + $0 })
    }

    struct Entry: Sendable {
        let file: URL
        let baseName: String
        let key: String
    }

    struct ResolvedDirectory: Sendable {
        let url: URL
        let scoped: Bool
        var scopeURL: URL? = nil
    }

    /// Resolves the bookmark and prepares `作者/笔记` subdirectories. The caller
    /// must keep the returned directory for the whole batch so a slow download
    /// does not repeatedly re-acquire the security scope.
    func prepare(note: ResolvedNote, policy: DownloadPolicy) throws -> ResolvedDirectory {
        guard policy.filesBookmark != nil else { throw ArchiveError.noDirectory }
        guard let root = ArchiveDirectory.resolve(policy.filesBookmark) else { throw ArchiveError.directoryUnavailable }
        let scoped = root.startAccessingSecurityScopedResource()

        var directory = root
        if policy.authorDirectories {
            let name = Self.directoryComponent(
                [note.metadata.userName, note.metadata.userId].compactMap { $0 }.joined(separator: "_"),
                fallback: "unknown-author")
            directory = directory.appendingPathComponent(name, isDirectory: true)
        }
        if policy.noteDirectories {
            let name = Self.directoryComponent(Self.noteComponent(note), fallback: note.noteID)
            directory = directory.appendingPathComponent(name, isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            if scoped { root.stopAccessingSecurityScopedResource() }
            throw ArchiveError.writeFailed(error.localizedDescription)
        }
        return ResolvedDirectory(url: directory, scoped: scoped, scopeURL: root)
    }

    func release(_ directory: ResolvedDirectory) {
        if directory.scoped { (directory.scopeURL ?? directory.url).stopAccessingSecurityScopedResource() }
    }

    /// Copies the staged originals into the archive directory. `skipExisting`
    /// reports the existing file instead of writing a second copy.
    func archive(entries: [Entry], in directory: ResolvedDirectory, policy: DownloadPolicy) throws -> ArchiveResult {
        var result = ArchiveResult()
        for entry in entries {
            // A staged original that vanished means this resource is not in the
            // archive. Report it instead of dropping it silently, otherwise the
            // task would look complete with no file behind it.
            guard FileManager.default.fileExists(atPath: entry.file.path) else {
                result.failed[entry.key] = L10n.text("archive.error.unavailable")
                continue
            }
            let ext = entry.file.pathExtension
            let expected = (try? entry.file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            // Only pay for a digest when a skip decision is actually possible.
            let expectedDigest = policy.skipExisting ? Self.digest(ofFile: entry.file) : nil
            let resolved = uniqueName(base: entry.baseName, ext: ext, in: directory.url,
                                      policy: policy, expectedByteCount: expected,
                                      expectedDigest: expectedDigest)
            let target = directory.url.appendingPathComponent(resolved.name)
            if resolved.skipped {
                result.skipped.append(entry.key)
                result.reused[entry.key] = target.path
                result.paths[entry.key] = target.path
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: entry.file, to: target)
                result.files.append(target.path)
                result.paths[entry.key] = target.path
            } catch {
                // Record per entry and keep going: one unwritable file should not
                // silently drop the rest of the batch.
                result.failed[entry.key] = error.localizedDescription
            }
        }
        return result
    }

    /// Caption files always land next to the media so a batch export stays a
    /// single self-contained folder.
    func writeCaptions(note: ResolvedNote, in directory: ResolvedDirectory, policy: DownloadPolicy) throws -> [String] {
        guard policy.captionFormat != .none else { return [] }
        var written: [String] = []
        let base = uniqueName(base: Self.noteComponent(note), ext: "", in: directory.url, policy: policy).name
        do {
            if policy.captionFormat == .txt || policy.captionFormat == .both {
                let url = directory.url.appendingPathComponent(base + ".txt")
                try captionText(note, markdown: false).write(to: url, atomically: true, encoding: .utf8)
                written.append(url.path)
            }
            if policy.captionFormat == .markdown || policy.captionFormat == .both {
                let url = directory.url.appendingPathComponent(base + ".md")
                try captionText(note, markdown: true).write(to: url, atomically: true, encoding: .utf8)
                written.append(url.path)
            }
        } catch {
            throw ArchiveError.writeFailed(error.localizedDescription)
        }
        return written
    }

    func captionText(_ note: ResolvedNote, markdown: Bool) -> String {
        var lines: [String] = []
        if markdown {
            lines.append("# " + note.title)
            lines.append("")
            if let author = note.metadata.userName { lines.append("- " + L10n.text("caption.author") + ": " + author) }
            if let redId = note.metadata.redId { lines.append("- " + L10n.text("caption.red_id") + ": " + redId) }
            if let published = note.metadata.publishTime { lines.append("- " + L10n.text("caption.published") + ": " + published) }
            lines.append("- " + L10n.text("caption.source") + ": " + note.canonicalURL.absoluteString)
            lines.append("")
            lines.append(note.body)
        } else {
            lines.append(note.title)
            if let author = note.metadata.userName { lines.append(L10n.text("caption.author") + ": " + author) }
            if let redId = note.metadata.redId { lines.append(L10n.text("caption.red_id") + ": " + redId) }
            if let published = note.metadata.publishTime { lines.append(L10n.text("caption.published") + ": " + published) }
            lines.append(L10n.text("caption.source") + ": " + note.canonicalURL.absoluteString)
            lines.append("")
            lines.append(note.body)
        }
        return lines.joined(separator: "\n")
    }

    /// `skipExisting` reports an existing file instead of writing a second copy.
    /// A name alone is not proof: the existing file must also be a readable,
    /// non-empty media file with the expected size, otherwise it is overwritten.
    /// Only the Files destination is skipped; Photos is decided separately by the
    /// caller because a file on disk says nothing about the photo library.
    private func uniqueName(base: String, ext: String, in directory: URL,
                            policy: DownloadPolicy,
                            expectedByteCount: Int64? = nil,
                            expectedDigest: String? = nil) -> (name: String, skipped: Bool) {
        let sanitized = Self.directoryComponent(base, fallback: "xhs")
        let suffix = ext.isEmpty ? "" : "." + ext
        var candidate = sanitized + suffix
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            let url = directory.appendingPathComponent(candidate)
            if policy.skipExisting,
               Self.isUsableExistingFile(url, expectedByteCount: expectedByteCount,
                                         expectedDigest: expectedDigest) {
                return (candidate, true)
            }
            candidate = sanitized + "_" + String(counter) + suffix
            counter += 1
        }
        return (candidate, false)
    }

    /// Verification for an existing archive entry. Name and size are not identity:
    /// two different resources can share both. The file must be non-empty, match
    /// the expected size, and match the expected bytes' digest.
    static func isUsableExistingFile(_ url: URL, expectedByteCount: Int64?,
                                     expectedDigest: String? = nil) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0 else { return false }
        if let expectedByteCount, expectedByteCount > 0, Int64(size) != expectedByteCount { return false }
        if let expectedDigest, let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            return digest(of: data) == expectedDigest
        }
        return expectedDigest == nil
    }

    /// Streaming SHA-256 of the staged original, used as the identity check.
    static func digest(ofFile url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return digest(of: data)
    }

    private static func digest(of data: Data) -> String {
        var hash = SHA256()
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The note folder must stay stable between runs, so it is derived from the
    /// note identity instead of the (mutable) title alone.
    static func noteComponent(_ note: ResolvedNote) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? note.noteID : title + "_" + note.noteID
    }

    /// Path components must stay inside the archive root, so separators and
    /// control characters are collapsed and the length is bounded.
    static func directoryComponent(_ raw: String, fallback: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if value.count > 80 { value = String(value.prefix(80)) }
        return value.isEmpty ? fallback : value
    }
}
