import Foundation
import CryptoKit
import UIKit

/// Delegate state is confined to `events`, including cancellation and reconnect.
final class BackgroundTransfers: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundTransfers()
    static let sessionIdentifier = "com.neoruaa.xhsdn.media-transfers"
    struct Progress: Sendable { let received: Int64; let expected: Int64; let bytesPerSecond: Double }
    private struct Response: Codable {
        let url: URL
        let status: Int
        let headers: [String: String]
        var value: HTTPURLResponse? { HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) }
    }
    private struct Waiting {
        let token: UUID
        let continuation: CheckedContinuation<(URL, URLResponse), Error>
        let progress: @Sendable (Progress) -> Void
    }

    private let events = DispatchQueue(label: "xhs.background-transfers")
    private let root: URL
    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var waiting: [String: Waiting] = [:]
    private var cancelled = Set<UUID>()
    private var ready = false
    private var deferred: [() -> Void] = []
    private var lastProgress: [String: (Date, Int64)] = [:]
    private var handoffCompletion: (() -> Void)?
    private var backgroundEventsFinished = false
    private var fileErrors: [String: Error] = [:]

    private override init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackgroundTransfers", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ImportInbox.groupIdentifier) != nil {
            configuration.sharedContainerIdentifier = ImportInbox.groupIdentifier
        }
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = events
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        session.getAllTasks { tasks in
            self.events.async {
                for case let task as URLSessionDownloadTask in tasks {
                    if let key = task.taskDescription { self.tasks[key] = task }
                }
                self.ready = true
                let work = self.deferred
                self.deferred.removeAll()
                work.forEach { $0() }
            }
        }
    }

    /// The background session is created once per process, so a per-task proxy
    /// cannot be applied by rebuilding it. Instead the caller marks whether the
    /// app proxy should be used for media; when it is off the task is routed
    /// through the foreground session, which honours the same configuration.
    func supportsProxy(_ enabled: Bool) -> Bool {
        // A background session cannot carry a proxy configuration. Requests that
        // must use the proxy therefore go through the regular session instead.
        !enabled
    }

    func download(_ request: URLRequest, identity: String,
                  progress: @escaping @Sendable (Progress) -> Void) async throws -> (URL, URLResponse) {
        let key = SHA256.hash(data: Data((identity + "|" + (request.url?.absoluteString ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                events.async {
                    let begin = {
                        if self.cancelled.remove(token) != nil {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        let file = self.path(key, "download")
                        if FileManager.default.fileExists(atPath: file.path),
                           let data = try? Data(contentsOf: self.path(key, "response")),
                           let response = try? JSONDecoder().decode(Response.self, from: data),
                           let value = response.value {
                            continuation.resume(returning: (file, value))
                            return
                        }
                        guard self.waiting[key] == nil else {
                            continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
                            return
                        }
                        self.waiting[key] = Waiting(token: token, continuation: continuation, progress: progress)
                        if let existing = self.tasks[key] {
                            existing.resume()
                            return
                        }
                        let task: URLSessionDownloadTask
                        if let resumeData = try? Data(contentsOf: self.path(key, "resume")) {
                            task = self.session.downloadTask(withResumeData: resumeData)
                            try? FileManager.default.removeItem(at: self.path(key, "resume"))
                        } else { task = self.session.downloadTask(with: request) }
                        task.taskDescription = key
                        self.tasks[key] = task
                        task.resume()
                    }
                    if self.ready { begin() } else { self.deferred.append(begin) }
                }
            }
        } onCancel: {
            self.events.async {
                guard let item = self.waiting[key], item.token == token else {
                    self.cancelled.insert(token)
                    return
                }
                // Keep the URLSession task until didComplete. A new retry cannot
                // attach to an old task that has not finished cancelling.
                self.tasks[key]?.cancel { data in
                    guard let data else { return }
                    self.events.async { try? data.write(to: self.path(key, "resume"), options: .atomic) }
                }
            }
        }
    }

    func handleBackgroundEvents(completion: @escaping () -> Void) {
        events.async {
            if self.backgroundEventsFinished {
                self.backgroundEventsFinished = false
                DispatchQueue.main.async { completion() }
            } else { self.handoffCompletion = completion }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, let url = response.url else {
                throw MediaValidationError.invalidResponse
            }
            let file = path(key, "download")
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: location, to: file)
            let headers = Dictionary(uniqueKeysWithValues: response.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) })
            let record = Response(url: url, status: response.statusCode, headers: headers)
            try JSONEncoder().encode(record).write(to: path(key, "response"), options: .atomic)
        } catch { fileErrors[key] = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        let item = waiting.removeValue(forKey: key)
        tasks[key] = nil
        lastProgress[key] = nil
        if let error {
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: path(key, "resume"), options: .atomic)
            }
            fileErrors[key] = nil
            item?.continuation.resume(throwing: (error as NSError).code == NSURLErrorCancelled ? CancellationError() : error)
        } else if let error = fileErrors.removeValue(forKey: key) {
            item?.continuation.resume(throwing: error)
        } else if let response = task.response {
            item?.continuation.resume(returning: (path(key, "download"), response))
        } else {
            item?.continuation.resume(throwing: MediaValidationError.invalidResponse)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        let now = Date()
        let last = lastProgress[key] ?? (now, 0)
        let interval = now.timeIntervalSince(last.0)
        guard interval >= 0.25 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastProgress[key] = (now, totalBytesWritten)
        waiting[key]?.progress(Progress(received: totalBytesWritten, expected: totalBytesExpectedToWrite,
                                        bytesPerSecond: interval > 0 ? Double(totalBytesWritten - last.1) / interval : 0))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = handoffCompletion
        handoffCompletion = nil
        backgroundEventsFinished = completion == nil
        DispatchQueue.main.async { completion?() }
    }

    private func path(_ key: String, _ extensionName: String) -> URL {
        root.appendingPathComponent(key).appendingPathExtension(extensionName)
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTransfers.sessionIdentifier else { completionHandler(); return }
        BackgroundTransfers.shared.handleBackgroundEvents(completion: completionHandler)
    }
}
