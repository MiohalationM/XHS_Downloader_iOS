import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Avatars are retained with the app's saved notes, including offline launches.
/// A 192px image covers the largest 64pt avatar at 3x without storing a full photo.
actor AuthorAvatarStore {
    static let shared = AuthorAvatarStore()
    private let directory: URL
    private var requests: [URL: Task<Data?, Never>] = [:]

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AuthorAvatars", isDirectory: true)) {
        self.directory = directory
    }

    private func fileURL(for url: URL) -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    func cachedData(for url: URL) -> Data? { try? Data(contentsOf: fileURL(for: url)) }

    func imageData(for url: URL) async -> Data? {
        if let data = cachedData(for: url) { return data }
        if let request = requests[url] { return await request.value }
        let request = Task<Data?, Never> {
            do {
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return nil }
                return try store(data: data, for: url)
            } catch { return nil }
        }
        requests[url] = request
        let data = await request.value
        requests[url] = nil
        return data
    }

    func store(data: Data, for url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 192
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (output as Data).write(to: fileURL(for: url), options: .atomic)
        return output as Data
    }
}
