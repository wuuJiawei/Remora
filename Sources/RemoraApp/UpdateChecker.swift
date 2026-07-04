import AppKit
import Combine
import Foundation
import WebKit

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false

    private let session: URLSession
    private let bundle: Bundle
    private let openURL: @MainActor (URL) -> Void
    private var hasPerformedAutomaticCheck = false
    private var updateWindowController: UpdateAvailableWindowController?

    init(
        session: URLSession = .shared,
        bundle: Bundle = .main,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.session = session
        self.bundle = bundle
        self.openURL = openURL
    }

    func performAutomaticCheckIfNeeded() async {
        guard !hasPerformedAutomaticCheck else { return }
        hasPerformedAutomaticCheck = true

        guard AppPreferences.shared.value(for: \.automaticallyCheckForUpdates) else {
            return
        }

        _ = await checkForUpdates(trigger: .automatic)
    }

    @discardableResult
    func checkForUpdates(trigger: UpdateTrigger) async -> UpdateCheckStatus? {
        guard !isChecking else { return nil }
        isChecking = true
        defer { isChecking = false }

        do {
            let currentVersion = Self.currentVersion(from: bundle)
            let latestRelease = try await fetchLatestRelease()
            let hasUpdate = Self.isVersion(latestRelease.version, newerThan: currentVersion)
            let status: UpdateCheckStatus = hasUpdate ? .updateAvailable(latestRelease, currentVersion: currentVersion) : .upToDate(currentVersion)

            presentAlertIfNeeded(for: status, trigger: trigger)
            return status
        } catch {
            let status = UpdateCheckStatus.failed(error.localizedDescription)
            presentAlertIfNeeded(for: status, trigger: trigger)
            return status
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: AppLinks.latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Remora/\(Self.currentVersion(from: bundle))", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(GitHubLatestReleasePayload.self, from: data)
        let version = Self.normalizedVersion(payload.tagName)

        guard !version.isEmpty else {
            throw UpdateCheckError.invalidPayload
        }

        let releaseNotes = Self.normalizedReleaseNotes(payload.body)
        let renderedReleaseNotesHTML = try await fetchRenderedReleaseNotesHTML(
            markdown: releaseNotes,
            releaseURL: payload.htmlURL ?? AppLinks.releasesURL
        )

        return GitHubRelease(
            version: version,
            releaseURL: payload.htmlURL ?? AppLinks.releasesURL,
            releaseNotes: releaseNotes,
            renderedReleaseNotesHTML: renderedReleaseNotesHTML,
            downloadAsset: Self.preferredDownloadAsset(from: payload.assets)
        )
    }

    private func fetchRenderedReleaseNotesHTML(markdown: String?, releaseURL: URL) async throws -> String? {
        guard let markdown else { return nil }

        struct RequestBody: Encodable {
            let text: String
            let mode: String
            let context: String
        }

        var request = URLRequest(url: AppLinks.markdownRenderAPIURL)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Remora/\(Self.currentVersion(from: bundle))", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(text: markdown, mode: "gfm", context: "wuuJiawei/Remora")
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UpdateCheckError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw UpdateCheckError.httpStatus(httpResponse.statusCode)
            }

            guard let html = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !html.isEmpty else {
                return Self.fallbackReleaseNotesHTML(markdown: markdown, releaseURL: releaseURL)
            }

            return Self.releaseNotesDocumentHTML(
                bodyHTML: html,
                releaseURL: releaseURL,
                languageCode: Self.currentLanguageCode()
            )
        } catch {
            return Self.fallbackReleaseNotesHTML(markdown: markdown, releaseURL: releaseURL)
        }
    }

    private func presentAlertIfNeeded(for status: UpdateCheckStatus, trigger: UpdateTrigger) {
        switch (status, trigger) {
        case let (.updateAvailable(release, currentVersion), _):
            if let controller = updateWindowController {
                controller.update(
                    release: release,
                    currentVersion: currentVersion,
                    messageText: updateAvailableMessage(for: release, currentVersion: currentVersion)
                )
                controller.showAndActivate()
            } else {
                let controller = UpdateAvailableWindowController(
                    release: release,
                    currentVersion: currentVersion,
                    messageText: updateAvailableMessage(for: release, currentVersion: currentVersion),
                    openURL: openURL,
                    downloadHandler: { [weak self] asset, release in
                        guard let self else { return }
                        Task { await self.downloadReleaseAsset(asset, release: release) }
                    },
                    closeHandler: { [weak self] controller in
                        guard self?.updateWindowController === controller else { return }
                        self?.updateWindowController = nil
                    },
                    tr: { [weak self] key in
                        self?.tr(key) ?? key
                    }
                )
                updateWindowController = controller
                controller.showAndActivate()
            }

        case let (.upToDate(currentVersion), .manual):
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = tr("You're up to date")
            alert.informativeText = String(
                format: tr("Remora %@ is the latest version currently published on GitHub Releases."),
                currentVersion
            )
            alert.addButton(withTitle: tr("OK"))
            alert.runModal()

        case let (.failed(description), .manual):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("Update check failed")
            alert.informativeText = String(
                format: tr("Remora could not read the latest GitHub release right now.\n\n%@"),
                description
            )
            alert.addButton(withTitle: tr("OK"))
            alert.runModal()

        case (.upToDate, .automatic), (.failed, .automatic):
            break
        }
    }

    private func updateAvailableMessage(for release: GitHubRelease, currentVersion: String) -> String {
        var message = String(
            format: tr("Remora %@ is available. You are currently using %@."),
            release.version,
            currentVersion
        )

        if let asset = release.downloadAsset {
            message += "\n\n"
            message += Self.downloadAssetMessage(for: asset)
        } else {
            message += "\n\n"
            message += tr("No compatible macOS download asset was found for this Mac. You can still view the release manually.")
        }

        return message
    }

    private func downloadReleaseAsset(_ asset: GitHubReleaseAsset, release: GitHubRelease) async {
        guard !isDownloading else { return }
        isDownloading = true
        defer { isDownloading = false }

        updateWindowController?.beginDownload(asset: asset, release: release)

        do {
            let destinationURL = try await download(asset: asset) { progress in
                self.updateWindowController?.updateDownloadProgress(progress)
            }
            let didOpen = openDownloadedUpdate(destinationURL)
            updateWindowController?.finishDownload(
                destinationURL: destinationURL,
                release: release,
                didOpen: didOpen
            )
            presentDownloadCompleteAlert(destinationURL: destinationURL, release: release, didOpen: didOpen)
        } catch {
            updateWindowController?.failDownload(error: error, release: release)
            presentDownloadFailedAlert(error: error, release: release)
        }
    }

    private func download(
        asset: GitHubReleaseAsset,
        progressHandler: @escaping @MainActor (UpdateDownloadProgress) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Remora/\(Self.currentVersion(from: bundle))", forHTTPHeaderField: "User-Agent")

        progressHandler(.initial)

        let operation = UpdateDownloadOperation(request: request, progressHandler: progressHandler)
        let (temporaryURL, response) = try await operation.start()
        guard let httpResponse = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw UpdateCheckError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }

        let fileManager = FileManager.default
        let downloadDirectory = AppSettings.resolvedDownloadDirectoryURL(
            from: AppPreferences.shared.value(for: \.downloadDirectoryPath),
            fileManager: fileManager
        )

        try fileManager.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let destinationURL = Self.availableDestinationURL(
            forFileNamed: asset.name,
            in: downloadDirectory,
            fileManager: fileManager
        )
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func presentDownloadCompleteAlert(destinationURL: URL, release: GitHubRelease, didOpen: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = tr("Update downloaded")
        if didOpen {
            alert.informativeText = String(
                format: tr("Remora %@ was downloaded and opened. Follow the system prompts to finish updating.\n\n%@"),
                release.version,
                destinationURL.path
            )
        } else {
            alert.informativeText = String(
                format: tr("Remora %@ was downloaded, but macOS could not open it automatically.\n\n%@"),
                release.version,
                destinationURL.path
            )
        }
        alert.addButton(withTitle: tr("Reveal in Finder"))
        alert.addButton(withTitle: tr("OK"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        }
    }

    @discardableResult
    private func openDownloadedUpdate(_ destinationURL: URL) -> Bool {
        if NSWorkspace.shared.open(destinationURL) {
            return true
        }

        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        return false
    }

    private func presentDownloadFailedAlert(error: Error, release: GitHubRelease) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("Update download failed")
        alert.informativeText = String(
            format: tr("Remora could not download version %@.\n\n%@"),
            release.version,
            error.localizedDescription
        )
        alert.addButton(withTitle: tr("View Release"))
        alert.addButton(withTitle: tr("OK"))

        if alert.runModal() == .alertFirstButtonReturn {
            openURL(release.releaseURL)
        }
    }

    nonisolated static func currentVersion(from bundle: Bundle) -> String {
        let info = bundle.infoDictionary
        let shortVersion = (info?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let shortVersion, !shortVersion.isEmpty {
            return shortVersion
        }

        let buildVersion = (info?["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let buildVersion, !buildVersion.isEmpty {
            return buildVersion
        }

        return "dev"
    }

    nonisolated static func normalizedVersion(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
    }

    nonisolated static func normalizedReleaseNotes(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    nonisolated static func currentLanguageCode() -> String {
        let mode = AppLanguageMode.resolved(from: AppPreferences.shared.value(for: \.languageModeRawValue))
        return mode.bundleLocalizationCode ?? "en"
    }

    nonisolated static func fallbackReleaseNotesHTML(markdown: String, releaseURL: URL) -> String {
        let escapedMarkdown = escapeHTML(markdown)
            .replacingOccurrences(of: "\n", with: "<br>")
        let bodyHTML = """
        <div class="fallback-notes">\(escapedMarkdown)</div>
        <p class="release-link"><a href="\(releaseURL.absoluteString)">\(escapeHTML(releaseURL.absoluteString))</a></p>
        """
        return releaseNotesDocumentHTML(
            bodyHTML: bodyHTML,
            releaseURL: releaseURL,
            languageCode: currentLanguageCode()
        )
    }

    nonisolated static func releaseNotesDocumentHTML(
        bodyHTML: String,
        releaseURL: URL,
        languageCode: String
    ) -> String {
        let escapedReleaseURL = escapeHTML(releaseURL.absoluteString)
        return """
        <!DOCTYPE html>
        <html lang="\(languageCode)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
            color-scheme: light dark;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
        }
        html, body {
            margin: 0;
            padding: 0;
            background: transparent;
            color: #1f2328;
            font: 13px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
        }
        body {
            padding: 0 0 12px 0;
        }
        .markdown-body {
            word-wrap: break-word;
            overflow-wrap: anywhere;
        }
        .markdown-body > :first-child {
            margin-top: 0;
        }
        .markdown-body > :last-child {
            margin-bottom: 0;
        }
        .markdown-body h1,
        .markdown-body h2,
        .markdown-body h3,
        .markdown-body h4,
        .markdown-body h5,
        .markdown-body h6 {
            line-height: 1.3;
            margin: 1.1em 0 0.5em;
            font-weight: 600;
        }
        .markdown-body p,
        .markdown-body ul,
        .markdown-body ol,
        .markdown-body pre,
        .markdown-body blockquote,
        .markdown-body table {
            margin: 0 0 0.9em;
        }
        .markdown-body ul,
        .markdown-body ol {
            padding-left: 1.4em;
        }
        .markdown-body code {
            font: 12px/1.45 SFMono-Regular, Menlo, Monaco, Consolas, monospace;
            background: rgba(175, 184, 193, 0.2);
            border-radius: 6px;
            padding: 0.12em 0.32em;
        }
        .markdown-body pre {
            overflow-x: auto;
            background: rgba(175, 184, 193, 0.12);
            border-radius: 10px;
            padding: 12px 14px;
        }
        .markdown-body pre code {
            background: transparent;
            padding: 0;
        }
        .markdown-body blockquote {
            margin-left: 0;
            padding-left: 12px;
            border-left: 3px solid rgba(140, 149, 159, 0.5);
            color: #59636e;
        }
        .markdown-body a,
        .release-link a {
            color: #0969da;
            text-decoration: none;
        }
        .markdown-body a:hover,
        .release-link a:hover {
            text-decoration: underline;
        }
        .fallback-notes {
            white-space: normal;
        }
        .release-link {
            margin-top: 1em;
        }
        @media (prefers-color-scheme: dark) {
            html, body {
                color: #f0f6fc;
            }
            .markdown-body code {
                background: rgba(110, 118, 129, 0.25);
            }
            .markdown-body pre {
                background: rgba(110, 118, 129, 0.18);
            }
            .markdown-body blockquote {
                color: #9ea7b3;
                border-left-color: rgba(110, 118, 129, 0.7);
            }
            .markdown-body a,
            .release-link a {
                color: #58a6ff;
            }
        }
        </style>
        </head>
        <body>
        <div class="markdown-body">\(bodyHTML)</div>
        <script>
        document.addEventListener("click", function(event) {
            const anchor = event.target.closest("a");
            if (!anchor) return;
            const href = anchor.getAttribute("href");
            if (!href) return;
            anchor.setAttribute("href", new URL(href, "\(escapedReleaseURL)").toString());
        }, true);
        </script>
        </body>
        </html>
        """
    }

    nonisolated static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    nonisolated static func isVersion(_ candidate: String, newerThan baseline: String) -> Bool {
        let normalizedCandidate = normalizedVersion(candidate)
        let normalizedBaseline = normalizedVersion(baseline)
        guard !normalizedCandidate.isEmpty, !normalizedBaseline.isEmpty else { return false }
        return normalizedCandidate.compare(normalizedBaseline, options: .numeric) == .orderedDescending
    }

    nonisolated static func preferredDownloadAsset(from assets: [GitHubReleaseAsset]) -> GitHubReleaseAsset? {
        let downloadableAssets = assets.filter { asset in
            let lowercasedName = asset.name.lowercased()
            return lowercasedName.hasSuffix(".zip") || lowercasedName.hasSuffix(".dmg")
        }
        guard !downloadableAssets.isEmpty else { return nil }

        let compatibleAssets = downloadableAssets.filter { asset in
            let lowercasedName = asset.name.lowercased()
            return lowercasedName.contains("mac") || lowercasedName.contains("darwin") || lowercasedName.contains("remora")
        }
        let candidates = compatibleAssets.isEmpty ? downloadableAssets : compatibleAssets

        #if arch(arm64)
        let architectureKeywords = ["arm64", "aarch64", "apple-silicon", "apple_silicon"]
        #else
        let architectureKeywords = ["x86_64", "x64", "amd64", "intel"]
        #endif

        if let architectureMatch = candidates.first(where: { asset in
            let lowercasedName = asset.name.lowercased()
            return architectureKeywords.contains(where: lowercasedName.contains)
        }) {
            return architectureMatch
        }

        if let universalMatch = candidates.first(where: { asset in
            let lowercasedName = asset.name.lowercased()
            return lowercasedName.contains("universal") || lowercasedName.contains("universal2")
        }) {
            return universalMatch
        }

        return candidates.first
    }

    nonisolated static func primaryActionTitle(for asset: GitHubReleaseAsset) -> String {
        if asset.name.lowercased().hasSuffix(".dmg") {
            return L10n.tr("Download and Open", fallback: "Download and Open", table: "UpdateChecker")
        }

        return L10n.tr("Download Update", fallback: "Download Update", table: "UpdateChecker")
    }

    nonisolated static func downloadAssetMessage(for asset: GitHubReleaseAsset) -> String {
        let lowercasedName = asset.name.lowercased()
        if lowercasedName.hasSuffix(".dmg") {
            return String(
                format: L10n.tr(
                    "Remora will download %@ and open the disk image when it finishes.",
                    fallback: "Remora will download %@ and open the disk image when it finishes.",
                    table: "UpdateChecker"
                ),
                asset.name
            )
        }

        return String(
            format: L10n.tr(
                "Remora will download %@ to your download directory and open it when it finishes.",
                fallback: "Remora will download %@ to your download directory and open it when it finishes.",
                table: "UpdateChecker"
            ),
            asset.name
        )
    }

    nonisolated static func availableDestinationURL(
        forFileNamed fileName: String,
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let sanitizedFileName = fileName
            .split(separator: "/")
            .last
            .map(String.init) ?? "Remora-update.zip"
        let baseURL = directoryURL.appendingPathComponent(sanitizedFileName, isDirectory: false)
        guard fileManager.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let fileExtension = baseURL.pathExtension
        let baseName = baseURL.deletingPathExtension().lastPathComponent
        for index in 1..<1000 {
            let candidateName: String
            if fileExtension.isEmpty {
                candidateName = "\(baseName)-\(index)"
            } else {
                candidateName = "\(baseName)-\(index).\(fileExtension)"
            }
            let candidateURL = directoryURL.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return directoryURL.appendingPathComponent(UUID().uuidString + "-" + sanitizedFileName, isDirectory: false)
    }

    private func tr(_ key: String) -> String {
        L10n.tr(key, fallback: key, table: "UpdateChecker")
    }
}

enum UpdateTrigger {
    case manual
    case automatic
}

enum UpdateCheckStatus: Equatable {
    case updateAvailable(GitHubRelease, currentVersion: String)
    case upToDate(String)
    case failed(String)
}

struct GitHubRelease: Equatable {
    let version: String
    let releaseURL: URL
    let releaseNotes: String?
    let renderedReleaseNotesHTML: String?
    let downloadAsset: GitHubReleaseAsset?
}

struct GitHubReleaseAsset: Equatable {
    let name: String
    let downloadURL: URL
}

struct UpdateDownloadProgress: Equatable {
    let bytesWritten: Int64
    let totalBytesExpected: Int64?

    static let initial = UpdateDownloadProgress(bytesWritten: 0, totalBytesExpected: nil)

    var fractionCompleted: Double? {
        guard let totalBytesExpected, totalBytesExpected > 0 else { return nil }
        return min(max(Double(bytesWritten) / Double(totalBytesExpected), 0), 1)
    }
}

private final class UpdateDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let progressHandler: @MainActor (UpdateDownloadProgress) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?

    init(
        request: URLRequest,
        progressHandler: @escaping @MainActor (UpdateDownloadProgress) -> Void
    ) {
        self.request = request
        self.progressHandler = progressHandler
    }

    func start() async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.default
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: request)
                self.task = task
                task.resume()
            }
        } onCancel: {
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let progress = UpdateDownloadProgress(bytesWritten: totalBytesWritten, totalBytesExpected: total)
        Task { @MainActor [progressHandler] in
            progressHandler(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response else {
            finish(.failure(UpdateCheckError.invalidResponse))
            return
        }

        do {
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("remora-update-\(UUID().uuidString)", isDirectory: false)
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            finish(.success((temporaryURL, response)))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil

        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

@MainActor
private final class UpdateAvailableWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    private let release: GitHubRelease
    private let openURL: @MainActor (URL) -> Void
    private let downloadHandler: @MainActor (GitHubReleaseAsset, GitHubRelease) -> Void
    private let closeHandler: @MainActor (UpdateAvailableWindowController) -> Void
    private let tr: (String) -> String

    private let appIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let notesTitleLabel = NSTextField(labelWithString: "")
    private let webView: WKWebView
    private let progressTitleLabel = NSTextField(labelWithString: "")
    private let progressDetailLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let progressContainer = NSStackView()
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let releaseButton = NSButton(title: "", target: nil, action: nil)
    private let laterButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    private var currentRelease: GitHubRelease
    private var currentVersion: String
    private var currentMessageText: String
    private var currentAsset: GitHubReleaseAsset?
    private var isDownloadActive = false

    init(
        release: GitHubRelease,
        currentVersion: String,
        messageText: String,
        openURL: @escaping @MainActor (URL) -> Void,
        downloadHandler: @escaping @MainActor (GitHubReleaseAsset, GitHubRelease) -> Void,
        closeHandler: @escaping @MainActor (UpdateAvailableWindowController) -> Void,
        tr: @escaping (String) -> String
    ) {
        self.release = release
        self.currentRelease = release
        self.currentVersion = currentVersion
        self.currentMessageText = messageText
        self.openURL = openURL
        self.downloadHandler = downloadHandler
        self.closeHandler = closeHandler
        self.tr = tr

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        self.webView = WKWebView(frame: .zero, configuration: configuration)

        let contentSize = NSSize(width: 640, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("Update available")
        window.isReleasedWhenClosed = false
        window.center()
        window.setContentSize(contentSize)
        window.minSize = NSSize(width: 600, height: 640)

        super.init(window: window)
        window.delegate = self

        configureContent(
            currentVersion: currentVersion,
            messageText: messageText
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndActivate() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        closeHandler(self)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            openURL(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    @objc
    private func handlePrimaryAction() {
        if let asset = currentRelease.downloadAsset {
            downloadHandler(asset, currentRelease)
        } else {
            openURL(currentRelease.releaseURL)
        }
    }

    @objc
    private func handleReleaseAction() {
        openURL(currentRelease.releaseURL)
    }

    @objc
    private func handleLaterAction() {
        window?.close()
    }

    @objc
    private func handleRevealInFinder() {
        guard let destinationPath = statusLabel.objectValue as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: destinationPath)])
    }

    func update(release: GitHubRelease, currentVersion: String, messageText: String) {
        self.currentRelease = release
        self.currentVersion = currentVersion
        self.currentMessageText = messageText
        self.currentAsset = nil
        self.isDownloadActive = false
        applyReleaseContent()
    }

    func beginDownload(asset: GitHubReleaseAsset, release: GitHubRelease) {
        currentRelease = release
        currentAsset = asset
        isDownloadActive = true

        progressTitleLabel.stringValue = String(
            format: L10n.tr("Downloading Remora %@", fallback: "Downloading Remora %@", table: "UpdateChecker"),
            release.version
        )
        progressDetailLabel.stringValue = asset.name
        progressIndicator.isIndeterminate = true
        progressIndicator.doubleValue = 0
        progressIndicator.startAnimation(nil)
        progressContainer.isHidden = false
        statusLabel.isHidden = true

        primaryButton.isEnabled = false
        releaseButton.isEnabled = false
        laterButton.title = tr("Close")
        showAndActivate()
    }

    func updateDownloadProgress(_ progress: UpdateDownloadProgress) {
        guard isDownloadActive else { return }

        if let fraction = progress.fractionCompleted {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = fraction
            progressDetailLabel.stringValue = String(
                format: L10n.tr("%@ of %@ downloaded", fallback: "%@ of %@ downloaded", table: "UpdateChecker"),
                ByteCountFormatter.string(fromByteCount: progress.bytesWritten, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: progress.totalBytesExpected ?? progress.bytesWritten, countStyle: .file)
            )
        } else {
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
            progressDetailLabel.stringValue = String(
                format: L10n.tr("%@ downloaded", fallback: "%@ downloaded", table: "UpdateChecker"),
                ByteCountFormatter.string(fromByteCount: progress.bytesWritten, countStyle: .file)
            )
        }
    }

    func finishDownload(destinationURL: URL, release: GitHubRelease, didOpen: Bool) {
        currentRelease = release
        isDownloadActive = false
        progressIndicator.stopAnimation(nil)
        progressContainer.isHidden = true

        statusLabel.objectValue = destinationURL.path
        statusLabel.stringValue = didOpen
            ? String(
                format: tr("Remora %@ was downloaded and opened. Follow the system prompts to finish updating.\n\n%@"),
                release.version,
                destinationURL.path
            )
            : String(
                format: tr("Remora %@ was downloaded, but macOS could not open it automatically.\n\n%@"),
                release.version,
                destinationURL.path
            )
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = false

        primaryButton.title = tr("Reveal in Finder")
        primaryButton.action = #selector(handleRevealInFinder)
        primaryButton.isEnabled = true
        releaseButton.isEnabled = true
        laterButton.title = tr("Close")
    }

    func failDownload(error: Error, release: GitHubRelease) {
        currentRelease = release
        isDownloadActive = false
        progressIndicator.stopAnimation(nil)
        progressContainer.isHidden = true

        statusLabel.objectValue = nil
        statusLabel.stringValue = String(
            format: tr("Remora could not download version %@.\n\n%@"),
            release.version,
            error.localizedDescription
        )
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = false

        primaryButton.title = currentRelease.downloadAsset.map(UpdateChecker.primaryActionTitle(for:)) ?? tr("View Release")
        primaryButton.action = #selector(handlePrimaryAction)
        primaryButton.isEnabled = true
        releaseButton.isEnabled = true
        laterButton.title = tr("Close")
    }

    private func configureContent(currentVersion: String, messageText: String) {
        guard let contentView = window?.contentView else { return }

        applyAppearanceMode(to: window)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(root)

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .top
        topRow.spacing = 16
        topRow.translatesAutoresizingMaskIntoConstraints = false

        if let appIcon = NSApp.applicationIconImage {
            appIconView.image = appIcon
        }
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.wantsLayer = true
        appIconView.layer?.cornerRadius = 20
        appIconView.layer?.masksToBounds = true

        let textColumn = NSStackView()
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 8
        textColumn.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = tr("Update available")
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.stringValue = messageText
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.maximumNumberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        textColumn.addArrangedSubview(titleLabel)
        textColumn.addArrangedSubview(messageLabel)

        topRow.addArrangedSubview(appIconView)
        topRow.addArrangedSubview(textColumn)

        notesTitleLabel.stringValue = tr("Release Notes")
        notesTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        notesTitleLabel.textColor = .secondaryLabelColor
        notesTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let notesContainer = NSView()
        notesContainer.translatesAutoresizingMaskIntoConstraints = false
        notesContainer.wantsLayer = true
        notesContainer.layer?.cornerRadius = 12
        notesContainer.layer?.borderWidth = 1
        notesContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        notesContainer.addSubview(webView)

        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.isInspectable = false

        progressTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        progressTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        progressDetailLabel.font = .systemFont(ofSize: 12)
        progressDetailLabel.textColor = .secondaryLabelColor
        progressDetailLabel.lineBreakMode = .byTruncatingMiddle
        progressDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.usesThreadedAnimation = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        progressContainer.orientation = .vertical
        progressContainer.alignment = .leading
        progressContainer.spacing = 8
        progressContainer.translatesAutoresizingMaskIntoConstraints = false
        progressContainer.addArrangedSubview(progressTitleLabel)
        progressContainer.addArrangedSubview(progressDetailLabel)
        progressContainer.addArrangedSubview(progressIndicator)
        progressContainer.isHidden = true

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        configureButton(
            primaryButton,
            title: release.downloadAsset.map(UpdateChecker.primaryActionTitle(for:)) ?? tr("View Release"),
            bezelStyle: .rounded,
            action: #selector(handlePrimaryAction)
        )
        configureButton(
            releaseButton,
            title: tr("View Release"),
            bezelStyle: .rounded,
            action: #selector(handleReleaseAction)
        )
        configureButton(
            laterButton,
            title: tr("Later"),
            bezelStyle: .rounded,
            action: #selector(handleLaterAction)
        )

        buttonRow.addArrangedSubview(primaryButton)
        buttonRow.addArrangedSubview(releaseButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(laterButton)

        root.addArrangedSubview(topRow)
        root.addArrangedSubview(notesTitleLabel)
        root.addArrangedSubview(notesContainer)
        root.addArrangedSubview(progressContainer)
        root.addArrangedSubview(statusLabel)
        root.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),

            appIconView.widthAnchor.constraint(equalToConstant: 72),
            appIconView.heightAnchor.constraint(equalToConstant: 72),

            notesContainer.widthAnchor.constraint(equalTo: root.widthAnchor),
            notesContainer.heightAnchor.constraint(equalToConstant: 360),

            webView.leadingAnchor.constraint(equalTo: notesContainer.leadingAnchor, constant: 1),
            webView.trailingAnchor.constraint(equalTo: notesContainer.trailingAnchor, constant: -1),
            webView.topAnchor.constraint(equalTo: notesContainer.topAnchor, constant: 1),
            webView.bottomAnchor.constraint(equalTo: notesContainer.bottomAnchor, constant: -1),

            primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            releaseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            laterButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            progressContainer.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.72),
            progressTitleLabel.widthAnchor.constraint(equalTo: progressContainer.widthAnchor),
            progressDetailLabel.widthAnchor.constraint(equalTo: progressContainer.widthAnchor),
            progressIndicator.widthAnchor.constraint(equalTo: progressContainer.widthAnchor),
        ])

        applyReleaseContent()
    }

    private func configureButton(
        _ button: NSButton,
        title: String,
        bezelStyle: NSButton.BezelStyle,
        action: Selector
    ) {
        button.title = title
        button.bezelStyle = bezelStyle
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func applyAppearanceMode(to window: NSWindow?) {
        guard let window else { return }
        let rawValue = AppPreferences.shared.value(for: \.appearanceModeRawValue)
        let mode = AppAppearanceMode.resolved(from: rawValue)
        if let appearanceName = mode.nsAppearanceName {
            window.appearance = NSAppearance(named: appearanceName)
        } else {
            window.appearance = nil
        }
    }

    private func applyReleaseContent() {
        window?.title = tr("Update available")
        titleLabel.stringValue = tr("Update available")
        messageLabel.stringValue = currentMessageText
        statusLabel.objectValue = nil
        statusLabel.stringValue = ""
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true
        progressContainer.isHidden = true

        webView.loadHTMLString(
            currentRelease.renderedReleaseNotesHTML
                ?? UpdateChecker.fallbackReleaseNotesHTML(
                    markdown: currentRelease.releaseNotes ?? tr("No release notes were provided for this release."),
                    releaseURL: currentRelease.releaseURL
                ),
            baseURL: currentRelease.releaseURL
        )

        primaryButton.title = currentRelease.downloadAsset.map(UpdateChecker.primaryActionTitle(for:)) ?? tr("View Release")
        primaryButton.action = #selector(handlePrimaryAction)
        primaryButton.isEnabled = true
        releaseButton.isEnabled = true
        laterButton.title = tr("Later")
    }
}

private struct GitHubLatestReleasePayload: Decodable {
    let tagName: String
    let htmlURL: URL?
    let body: String?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }
}

extension GitHubReleaseAsset: Decodable {
    private enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

private enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case invalidPayload
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L10n.tr(
                "The update service returned an unexpected response.",
                fallback: "The update service returned an unexpected response.",
                table: "UpdateChecker"
            )
        case .invalidPayload:
            return L10n.tr(
                "The latest release metadata was incomplete.",
                fallback: "The latest release metadata was incomplete.",
                table: "UpdateChecker"
            )
        case let .httpStatus(statusCode):
            return String(
                format: L10n.tr("GitHub returned HTTP %d.", fallback: "GitHub returned HTTP %d.", table: "UpdateChecker"),
                statusCode
            )
        }
    }
}
