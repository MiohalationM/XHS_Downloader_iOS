import UIKit
import UniformTypeIdentifiers

/// The share sheet is a lightweight action picker, not a second copy of the app.
/// It reads the shared text once, then asks what to do with it, writes the
/// request into the App Group inbox, and only then tries to open the app. The
/// main app acknowledges the request after it has persisted the task, so a
/// failed handoff never loses the share and never double-submits it.
final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let previewLabel = UILabel()
    private let actionStack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var didFinish = false
    private var sharedText = ""
    private var submittedRequest: ImportRequest?
    private let confirmationFeedback = UIImpactFeedbackGenerator(style: .light)
    private let resultFeedback = UINotificationFeedbackGenerator()

    private var feedbackEnabled: Bool {
        viewIfLoaded?.window != nil &&
            FeedbackPreference.isEnabled(in: UserDefaults(suiteName: ImportInbox.groupIdentifier))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureViews()
        Task { await receive() }
    }

    // MARK: - Layout

    private func configureViews() {
        titleLabel.text = text("保存到小红书下载器", "Save to XHS Downloader")
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        previewLabel.font = .preferredFont(forTextStyle: .footnote)
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.textColor = .secondaryLabel
        previewLabel.textAlignment = .center
        previewLabel.numberOfLines = 3

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = text("正在接收分享…", "Receiving share…")

        actionStack.axis = .vertical
        actionStack.spacing = 12
        actionStack.distribution = .fillEqually

        let cancel = UIButton(type: .system)
        cancel.setTitle(text("取消", "Cancel"), for: .normal)
        cancel.addTarget(self, action: #selector(finish), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, previewLabel, statusLabel, actionStack, spinner, cancel])
        stack.axis = .vertical
        stack.spacing = 18
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28)
        ])
    }

    private func addActions() {
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let actions: [(String, String, ImportRequest.Behavior, String)] = [
            (text("直接下载", "Download now"), "arrow.down.circle.fill", .direct, "share-action-direct"),
            (text("选择内容", "Choose content"), "checklist", .select, "share-action-select"),
            (text("仅保存笔记", "Save note only"), "text.book.closed", .informationOnly, "share-action-information")
        ]
        for (title, symbol, behavior, identifier) in actions {
            var configuration = UIButton.Configuration.filled()
            configuration.title = title
            configuration.image = UIImage(systemName: symbol)
            configuration.imagePadding = 8
            configuration.cornerStyle = .medium
            configuration.baseBackgroundColor = behavior == .direct ? .systemPink : .secondarySystemBackground
            configuration.baseForegroundColor = behavior == .direct ? .white : .label
            let button = UIButton(configuration: configuration)
            button.addAction(UIAction { [weak self] _ in self?.submit(behavior) }, for: .touchUpInside)
            button.accessibilityIdentifier = identifier
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            actionStack.addArrangedSubview(button)
        }
    }

    // MARK: - Receive

    private func receive() async {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        var values = items.compactMap { $0.attributedContentText?.string }
        // Read both representations in a stable order: URL-only representations
        // can discard the share caption and security parameters.
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            for type in [UTType.plainText.identifier, UTType.url.identifier]
            where provider.hasItemConformingToTypeIdentifier(type) {
                let value: String? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                        if let url = item as? URL { continuation.resume(returning: url.absoluteString) }
                        else if let data = item as? Data { continuation.resume(returning: String(data: data, encoding: .utf8)) }
                        else { continuation.resume(returning: item as? String) }
                    }
                }
                if let value, !value.isEmpty, !values.contains(value) { values.append(value) }
            }
        }
        guard !values.isEmpty else {
            statusLabel.text = text("没有收到可用的链接或文字。", "No link or text was received.")
            return
        }
        sharedText = values.joined(separator: "\n")
        let count = ImportText.linkCount(in: sharedText)
        previewLabel.text = count == 0
            ? String(sharedText.prefix(120))
            : text("识别到 \(count) 个笔记链接", "Found \(count) note link(s)")
        statusLabel.text = text("选择要执行的动作", "Choose what to do")
        addActions()
    }

    // MARK: - Submit

    private func submit(_ behavior: ImportRequest.Behavior) {
        guard !didFinish else { return }
        guard submittedRequest == nil else {
            // A second tap must not enqueue a duplicate request.
            showRetainedRequest()
            return
        }
        actionStack.isUserInteractionEnabled = false
        spinner.startAnimating()
        let request = ImportRequest(text: sharedText, source: .share, behavior: behavior)
        do {
            try ImportInbox.shared().append(request)
        } catch {
            spinner.stopAnimating()
            actionStack.isUserInteractionEnabled = true
            statusLabel.text = text("无法保存分享，请重试：", "Could not save share. Please retry: ") + error.localizedDescription
            if feedbackEnabled { resultFeedback.notificationOccurred(.error) }
            return
        }
        submittedRequest = request
        if feedbackEnabled { confirmationFeedback.impactOccurred(intensity: 0.8) }
        statusLabel.text = text("已加入，正在打开下载器…", "Added. Opening the downloader…")
        ExperimentalAppHandoff.open(request.handoffURL, from: self) { [weak self] success in
            guard let self, !self.didFinish else { return }
            if success { self.finish() }
            else { self.showRetainedRequest() }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !self.didFinish else { return }
            self.showRetainedRequest()
        }
    }

    private func showRetainedRequest() {
        spinner.stopAnimating()
        statusLabel.text = text(
            "已加入，打开应用继续。若未自动跳转，请打开小红书下载器，任务会自动加入。",
            "Added. Open the app to continue. If it did not open, open XHS Downloader and the task will be added."
        )
    }

    @objc private func finish() {
        guard !didFinish else { return }
        didFinish = true
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func text(_ chinese: String, _ english: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
    }
}

/// Isolated experiment for the self-signed distribution. The inbox is persisted
/// before this is called; iOS may reject opening from a share extension.
private enum ExperimentalAppHandoff {
    static func open(_ url: URL, from controller: UIViewController, completion: @escaping (Bool) -> Void) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = controller
        while let current = responder {
            if current.responds(to: selector), let implementation = current.method(for: selector) {
                typealias Completion = @convention(block) (Bool) -> Void
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, Completion) -> Void
                let call = unsafeBitCast(implementation, to: Open.self)
                let callback: Completion = { success in DispatchQueue.main.async { completion(success) } }
                call(current, selector, url as NSURL, [:] as NSDictionary, callback)
                return
            }
            responder = current.next
        }
        controller.extensionContext?.open(url, completionHandler: { success in
            DispatchQueue.main.async { completion(success) }
        })
    }
}
