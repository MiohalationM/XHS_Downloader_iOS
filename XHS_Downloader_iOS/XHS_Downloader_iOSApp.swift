import SwiftUI

@main
struct XHS_Downloader_iOSApp: App {
    @UIApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycleDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var coordinator: DownloadCoordinator

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        var store: DownloadTaskStore?
        var noteStore: NoteStore?
        var initialTasks: [DownloadTaskRecord]?
        #if DEBUG
        let textFixture = ProcessInfo.processInfo.arguments.contains("-ui-test-text-notes")
        let textCount = ProcessInfo.processInfo.arguments.contains("-ui-test-six-notes") ? 6 : 2
        if textFixture || ProcessInfo.processInfo.arguments.contains("-ui-test-task-center") || ProcessInfo.processInfo.arguments.contains("-ui-test-note-feed") {
            // Isolate layout tests from real download history and the Photos library.
            let testStore = DownloadTaskStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("task-center-ui-test.json")
            )
            var tasks: [DownloadTaskRecord] = []
            for index in 1...(textFixture ? textCount : 12) {
                var task = DownloadTaskRecord(
                    sourceText: "UI layout fixture",
                    normalizedURL: "https://www.xiaohongshu.com/explore/layout-fixture-\(index)",
                    title: index == 1 ? "DeepSeek V4.1 Flash：更强、更快、更普惠" : (index == 2 ? "DeepSeek 寻找闪亮发光的你" : "布局测试笔记 \(index)"),
                    status: .completed
                )
                task.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
                task.noteType = index == 1 ? .mixed : .image
                task.status = index == 1 ? .paused : .completed
                task.progress = index == 1 ? 2.0 / 3.0 : 1
                task.mediaCount = index == 1 ? 3 : 1
                task.savedCount = index == 1 ? 2 : 1
                task.createdAt = Date(timeIntervalSince1970: Double(1_790_000_000 - index))
                task.mediaAssets = [MediaAssetRecord(localIdentifier: "ui-layout-fixture-\(index)", fileName: "fixture.heic", isVideo: false)]
                if (index == 1 || ProcessInfo.processInfo.arguments.contains("-ui-test-note-feed")),
                   let ids = ProcessInfo.processInfo.environment["XHS_UI_TEST_MEDIA_IDS"] {
                    task.mediaAssets = ids.split(separator: ",").map {
                        MediaAssetRecord(localIdentifier: String($0), fileName: "preview-fixture.heic", isVideo: false)
                    }
                    task.status = .completed
                    task.mediaCount = task.mediaAssets.count
                    task.savedCount = task.mediaAssets.count
                    task.progress = 1
                    if ProcessInfo.processInfo.arguments.contains("-ui-test-note-feed") {
                        let titles = ["DeepSeek V4.1 Flash：更强、更快、更普惠", "DeepSeek 寻找闪亮发光的你", "原生多模态视觉理解能力解析", "离线实况与原件归档示例", "双列瀑布流交互与动效验证", "一些值得收藏的技术笔记"]
                        task.title = titles[(index - 1) % titles.count]
                        task.noteText = "最近最喜欢的一张照片，记录一下这个可爱的瞬间。\n\n光线刚刚好，普通的日子也有值得记住的风景。慢慢生活，认真感受。\n\n#生活记录[话题]# #随手拍[话题]#"
                        if ProcessInfo.processInfo.arguments.contains("-ui-test-long-note-body") {
                            task.noteText += String(repeating: "\n\n这是一段用于验证长文阅读与返回手势的正文。滚动后取消返回，应保留当前阅读位置。", count: 10)
                        }
                        if index > 1, index % 2 == 0 { task.mediaAssets.reverse() }
                        task.resolvedNote = ResolvedNote(noteID: "feed-fixture-\(index)",
                            canonicalURL: URL(string: "https://www.xiaohongshu.com/explore/feed-fixture-\(index)")!,
                            title: task.title, body: task.noteText,
                            metadata: NoteMetadata(userName: index % 2 == 0 ? "日常观察员" : "慢慢记录", userId: "author-fixture-\(index)", publishTime: "26-11-08", redId: "fixture\(index)", topics: ["生活记录", "随手拍"]), media: [])
                    }
                }
                if textFixture {
                    task.title = "Text fixture \(index)"
                    task.noteText = "纯文字笔记也能阅读、复制链接、分享正文与批量删除。\n\n这段正文用于验证笔记操作不依赖照片权限。"
                    task.normalizedURL = "https://www.xiaohongshu.com/explore/text-fixture-\(index)"
                    task.status = .completed
                    task.mediaAssets = []
                    task.mediaCount = 0
                    task.savedCount = 0
                    task.informationOnly = true
                    task.resolvedNote = ResolvedNote(noteID: "text-fixture-\(index)", canonicalURL: URL(string: task.normalizedURL)!,
                        title: task.title, body: task.noteText, metadata: NoteMetadata(userName: "Writer"), media: [])
                }
                tasks.append(task)
            }
            initialTasks = tasks
            store = testStore
            let fixtureNotes = NoteStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("note-feed-ui-test.json"))
            noteStore = fixtureNotes
        }
        #endif
        let coordinator = DownloadCoordinator(settings: settings, store: store, noteStore: noteStore, initialTasks: initialTasks)
        _coordinator = StateObject(wrappedValue: coordinator)
        NotificationRouter.shared.install(coordinator: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator, settings: settings)
                // "Follow system" leaves the value nil so the system choice wins.
                .preferredColorScheme(colorScheme)
                .task {
                    await WebSession.shared.synchronize()
                }
        }
    }

    private var colorScheme: ColorScheme? {
        switch settings.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
