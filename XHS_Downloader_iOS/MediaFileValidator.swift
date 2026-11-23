import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

enum MediaValidationError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { L10n.text("error.invalid_media") }
}

enum MediaFileValidator {
    static func validate(_ file: URL, response: URLResponse?, isVideo: Bool) async throws -> String {
        guard let response = response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else {
            throw MediaValidationError.invalidResponse
        }
        // A resumed file may have grown since URL cached its resource values.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw MediaValidationError.invalidResponse }
        if response.statusCode == 206 {
            // URLSession reconstructs a full file when using resume data. Its
            // response still describes the final range, not the whole file.
            guard let range = response.value(forHTTPHeaderField: "Content-Range"),
                  let slash = range.lastIndex(of: "/"),
                  let total = Int64(range[range.index(after: slash)...]), total == size,
                  let end = range[..<slash].split(separator: "-").last.flatMap({ Int64($0) }),
                  end == total - 1 else { throw MediaValidationError.invalidResponse }
        } else if response.expectedContentLength > 0, response.expectedContentLength != size {
            throw MediaValidationError.invalidResponse
        }
        return try await fileExtension(for: file, isVideo: isVideo)
    }

    /// Decides whether a local file is a movie. A raw `ftyp` check is wrong here:
    /// HEIC/AVIF are ISO-BMFF containers too, so a HEIC still starts with
    /// "ftypheic" and would be played as video. ImageIO is the same decoder the
    /// download path already trusts, so it decides first and only an
    /// undecodable file is treated as a movie.
    static func isVideoFile(_ url: URL) -> Bool {
        // A file that is not there cannot be played; guessing from the extension
        // would send a missing path into the player.
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            return false
        }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent)
    }

    static func fileExtension(for file: URL, isVideo: Bool) async throws -> String {
        if isVideo {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 32) ?? Data()
            let text = String(decoding: header, as: UTF8.self)
            let ext = text.contains("qt  ") ? "mov" : "mp4"
            // AVFoundation rejects valid MP4 bytes at URLSession's .tmp or
            // .download paths (-11828 / -12847). Give it a typed hard link
            // before probing tracks; the original bytes stay untouched.
            let probe = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.linkItem(at: file, to: probe)
            defer { try? FileManager.default.removeItem(at: probe) }
            let asset = AVURLAsset(url: probe)
            guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
                throw MediaValidationError.invalidResponse
            }
            return ext
        }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source),
              let ext = UTType(type as String)?.preferredFilenameExtension else {
            throw MediaValidationError.invalidResponse
        }
        return ext
    }
}
