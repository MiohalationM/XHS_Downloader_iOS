import Foundation
import Testing
@testable import XHS_Downloader_iOS

struct SelectionQueueTests {
    @MainActor
    @Test func waitingSelectionDoesNotDownloadOriginalsOrBlockNextNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: AppSettings.Key.selectiveDownload)
        let settings = AppSettings(defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SelectionFixtureProtocol.self]
        let store = DownloadTaskStore(fileURL: root.appendingPathComponent("tasks.json"))
        SelectionFixtureProtocol.reset()
        let coordinator = DownloadCoordinator(settings: settings, store: store,
                                              downloader: XHSDownloader(session: URLSession(configuration: configuration)))
        await coordinator.waitUntilLoaded()
        _ = await coordinator.enqueue("https://www.xiaohongshu.com/explore/first https://www.xiaohongshu.com/explore/second").value
        let deadline = Date().addingTimeInterval(5)
        while coordinator.waitingCount != 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(coordinator.waitingCount == 2)
        #expect(SelectionFixtureProtocol.paths().sorted() == ["/explore/first", "/explore/second"])
        let state = try #require(coordinator.selectionState)
        coordinator.updateSelection(id: try #require(state.items.first?.id), selected: false)
        await coordinator.flushPersistence()
        let restored = DownloadCoordinator(settings: settings, store: store)
        await restored.waitUntilLoaded()
        #expect(restored.waitingCount == 2)
        restored.showSelection(taskID: state.taskID)
        #expect(restored.selectionState?.items.first?.isSelected == false)
        coordinator.cancelSelection()
        #expect(coordinator.tasks.first(where: { $0.id == state.taskID })?.status == .cancelled)
    }
}

private final class SelectionFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [String] = []
    static func reset() { lock.lock(); defer { lock.unlock() }; requests = [] }
    static func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.requests.append(url.path)
        Self.lock.unlock()
        let id = url.lastPathComponent
        let html = """
        <script>window.__INITIAL_STATE__ = {"note":{"noteDetailMap":{"\(id)":{"note":{
        "noteId":"\(id)","title":"Fixture","imageList":[{"urlDefault":"https://media.example/\(id).jpg","urlPre":"https://media.example/\(id)-preview.jpg"}]
        }}}}};</script>
        """
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
