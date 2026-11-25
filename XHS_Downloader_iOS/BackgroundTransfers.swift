import Foundation
import CryptoKit
import UIKit

/// Delegate state is confined to `events`, including cancellation and reconnect.
final class BackgroundTransfers: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundTransfers()
    static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "com.neoruaa.xhsdn") + ".media-transfers"
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
    private var completedTaskIDs = Set<Int>()
    private var waiting: [String: Waiting] = [:]
    private var deferredTokens = Set<UUID>()
    private var cancelled = Set<UUID>()
    private var ready = false
    private var deferred: [() -> Void] = []
    private var lastProgress: [String: (Date, Int64)] = [:]
    private var handoffCompletions: [() -> Void] = []
    private var backgroundEventsFinished = false
    private var fileErrors: [String: Error] = [:]

    private override init() {
        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackgroundTransfers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        root = directory
        super.init()
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
                    guard !self.completedTaskIDs.contains(task.taskIdentifier),
                          task.state == .running || task.state == .suspended,
                          let key = task.taskDescription else { continue }
                    self.tasks[key] = task
                }
                self.ready = true
                let work = self.deferred
                self.deferred.removeAll()
                work.forEach { $0() }
            }
        }
    }

    /// Computes the stable disk/session lookup key for a transfer slot + URL.
    static func transferKey(identity: String, url: URL?) -> String {
        SHA256.hash(data: Data((identity + "|" + (url?.absoluteString ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Returns transfer keys that either have a live system background download
    /// task or already finished downloading to disk awaiting handoff.
    func activeTransferKeys() async -> Set<String> {
        await withCheckedContinuation { continuation in
            events.async {
                let collect = {
                    var keys = Set(self.tasks.keys)
                    let files = (try? FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil)) ?? []
                    for file in files where file.pathExtension == "download" {
                        let key = file.deletingPathExtension().lastPathComponent
                        if let data = try? Data(contentsOf: self.path(key, "response")),
                           let response = try? JSONDecoder().decode(Response.self, from: data),
                           (200...299).contains(response.status) {
                            keys.insert(key)
                        }
                    }
                    continuation.resume(returning: keys)
                }
                if self.ready { collect() } else { self.deferred.append(collect) }
            }
        }
    }

    /// Cancels any lingering background transfers that have no active caller
    /// waiting on them (for example after process termination or history clear),
    /// while leaving transfers in `preservingKeys` untouched so resumed tasks
    /// can reattach to them.
    func cancelUnattachedTransfers(preservingKeys: Set<String> = [], clearCache: Bool = false) {
        events.async {
            let run = {
                for (key, task) in self.tasks where self.waiting[key] == nil && !preservingKeys.contains(key) {
                    task.cancel()
                    self.tasks[key] = nil
                    self.lastProgress[key] = nil
                    if clearCache { self.removeArtifacts(forKey: key) }
                }
                if clearCache {
                    let activeKeys = Set(self.waiting.keys).union(preservingKeys)
                    let files = (try? FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil)) ?? []
                    for file in files {
                        let key = file.deletingPathExtension().lastPathComponent
                        if !activeKeys.contains(key) { try? FileManager.default.removeItem(at: file) }
                    }
                }
            }
            if self.ready { run() } else { self.deferred.append(run) }
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
        let key = Self.transferKey(identity: identity, url: request.url)
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                events.async {
                    let begin = {
                        self.deferredTokens.remove(token)
                        if self.cancelled.remove(token) != nil {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        let file = self.path(key, "download")
                        if FileManager.default.fileExists(atPath: file.path),
                           let data = try? Data(contentsOf: self.path(key, "response")),
                           let response = try? JSONDecoder().decode(Response.self, from: data),
                           (200...299).contains(response.status),
                           let value = response.value {
                            continuation.resume(returning: (file, value))
                            return
                        }
                        guard self.waiting[key] == nil else {
                            continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
                            return
                        }
                        self.waiting[key] = Waiting(token: token, continuation: continuation, progress: progress)
                        if let existing = self.tasks[key],
                           !self.completedTaskIDs.contains(existing.taskIdentifier),
                           existing.state == .running || existing.state == .suspended {
                            existing.resume()
                            return
                        }
                        self.tasks[key] = nil
                        let task: URLSessionDownloadTask
                        if let resumeData = try? Data(contentsOf: self.path(key, "resume")) {
                            task = self.session.downloadTask(withResumeData: resumeData)
                            try? FileManager.default.removeItem(at: self.path(key, "resume"))
                        } else { task = self.session.downloadTask(with: request) }
                        task.taskDescription = key
                        self.tasks[key] = task
                        task.resume()
                    }
                    if self.ready {
                        begin()
                    } else {
                        self.deferredTokens.insert(token)
                        self.deferred.append(begin)
                    }
                }
            }
        } onCancel: {
            self.events.async {
                if self.deferredTokens.contains(token) {
                    self.cancelled.insert(token)
                    return
                }
                guard let item = self.waiting[key], item.token == token else { return }
                guard let task = self.tasks[key],
                      !self.completedTaskIDs.contains(task.taskIdentifier),
                      task.state == .running || task.state == .suspended else {
                    self.waiting.removeValue(forKey: key)
                    self.tasks[key] = nil
                    self.lastProgress[key] = nil
                    item.continuation.resume(throwing: CancellationError())
                    return
                }
                // Keep the URLSession task until didComplete. Resume data is
                // persisted deterministically in didCompleteWithError to avoid
                // overwriting a fresh retry's resume data.
                task.cancel(byProducingResumeData: { _ in })
            }
        }
    }

    func handleBackgroundEvents(completion: @escaping () -> Void) {
        events.async {
            if self.backgroundEventsFinished {
                self.backgroundEventsFinished = false
                DispatchQueue.main.async { completion() }
            } else { self.handoffCompletions.append(completion) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, let url = response.url else {
                throw MediaValidationError.invalidResponse
            }
            guard (200...299).contains(response.statusCode) else {
                removeArtifacts(forKey: key)
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
        completedTaskIDs.insert(task.taskIdentifier)
        guard let key = task.taskDescription else { return }
        let item = waiting.removeValue(forKey: key)
        if tasks[key]?.taskIdentifier == task.taskIdentifier {
            tasks[key] = nil
        }
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
        if let last = lastProgress[key] {
            let interval = now.timeIntervalSince(last.0)
            guard interval >= 0.25 || (totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite) else { return }
            lastProgress[key] = (now, totalBytesWritten)
            let delta = max(0, totalBytesWritten - last.1)
            waiting[key]?.progress(Progress(received: totalBytesWritten, expected: totalBytesExpectedToWrite,
                                            bytesPerSecond: interval > 0 ? Double(delta) / interval : 0))
        } else {
            lastProgress[key] = (now, totalBytesWritten)
            waiting[key]?.progress(Progress(received: totalBytesWritten, expected: totalBytesExpectedToWrite,
                                            bytesPerSecond: 0))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completions = handoffCompletions
        handoffCompletions.removeAll()
        backgroundEventsFinished = completions.isEmpty
        DispatchQueue.main.async { completions.forEach { $0() } }
    }

    private func removeArtifacts(forKey key: String) {
        try? FileManager.default.removeItem(at: path(key, "download"))
        try? FileManager.default.removeItem(at: path(key, "response"))
        try? FileManager.default.removeItem(at: path(key, "resume"))
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
