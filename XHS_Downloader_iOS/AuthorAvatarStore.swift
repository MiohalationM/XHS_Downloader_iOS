import Foundation
import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Avatars are retained with the app's saved notes, including offline launches.
/// A 192px image covers the largest 64pt avatar at 3x without storing a full photo.
actor AuthorAvatarStore {
    static let shared = AuthorAvatarStore()
    nonisolated(unsafe) private static let decodedImageCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 200
        return cache
    }()
    private let directory: URL
    private let memoryCache = NSCache<NSURL, NSData>()
    private var requests: [URL: Task<Data?, Never>] = [:]

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AuthorAvatars", isDirectory: true)) {
        self.directory = directory
        memoryCache.totalCostLimit = 8 * 1024 * 1024
        memoryCache.countLimit = 200
    }

    nonisolated func cachedImage(for url: URL) -> UIImage? {
        Self.decodedImageCache.object(forKey: url as NSURL)
    }

    private func cacheDecodedImage(from data: Data, for url: URL, overwrite: Bool = false) {
        let key = url as NSURL
        if !overwrite, Self.decodedImageCache.object(forKey: key) != nil { return }
        if let image = UIImage(data: data) {
            Self.decodedImageCache.setObject(image, forKey: key)
        }
    }

    private func fileURL(for url: URL) -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    func cachedData(for url: URL) -> Data? {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            let data = cached as Data
            cacheDecodedImage(from: data, for: url)
            return data
        }
        guard let data = try? Data(contentsOf: fileURL(for: url)) else { return nil }
        memoryCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        cacheDecodedImage(from: data, for: url)
        return data
    }

    func imageData(for url: URL) async -> Data? {
        if let data = cachedData(for: url) { return data }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        if let request = requests[url] {
            let data = await request.value
            if let data { cacheDecodedImage(from: data, for: url) }
            return data
        }
        let request = Task<Data?, Never> {
            do {
                var request = URLRequest(url: url, timeoutInterval: 15)
                if let host = url.host?.lowercased(),
                   WebSession.trusted(host) || host.hasSuffix(".xhscdn.com") || host == "xhscdn.com" {
                    request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return nil }
                return try store(data: data, for: url)
            } catch { return nil }
        }
        requests[url] = request
        let data = await request.value
        requests[url] = nil
        if let data { cacheDecodedImage(from: data, for: url) }
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
        var targetDirectory = directory
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? targetDirectory.setResourceValues(values)
        let bytes = output as Data
        try bytes.write(to: fileURL(for: url), options: .atomic)
        memoryCache.setObject(bytes as NSData, forKey: url as NSURL, cost: bytes.count)
        cacheDecodedImage(from: bytes, for: url, overwrite: true)
        return bytes
    }
}
