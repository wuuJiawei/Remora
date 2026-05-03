import AppKit
import Combine
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false

    private let session: URLSession
    private let bundle: Bundle
    private let openURL: @MainActor (URL) -> Void
    private var hasPerformedAutomaticCheck = false

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

        return GitHubRelease(
            version: version,
            releaseURL: payload.htmlURL ?? AppLinks.releasesURL,
            releaseNotes: Self.normalizedReleaseNotes(payload.body),
            downloadAsset: Self.preferredDownloadAsset(from: payload.assets)
        )
    }

    private func presentAlertIfNeeded(for status: UpdateCheckStatus, trigger: UpdateTrigger) {
        switch (status, trigger) {
        case let (.updateAvailable(release, currentVersion), _):
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = tr("Update available")
            alert.informativeText = updateAvailableMessage(for: release, currentVersion: currentVersion)
            alert.accessoryView = makeReleaseNotesView(for: release)

            if release.downloadAsset != nil {
                alert.addButton(withTitle: tr("Download Update"))
                alert.addButton(withTitle: tr("View Release"))
                alert.addButton(withTitle: tr("Later"))
            } else {
                alert.addButton(withTitle: tr("View Release"))
                alert.addButton(withTitle: tr("Later"))
            }

            let response = alert.runModal()
            if let asset = release.downloadAsset {
                switch response {
                case .alertFirstButtonReturn:
                    Task { await downloadReleaseAsset(asset, release: release) }
                case .alertSecondButtonReturn:
                    openURL(release.releaseURL)
                default:
                    break
                }
            } else if response == .alertFirstButtonReturn {
                openURL(release.releaseURL)
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
            format: tr("Remora %@ is available on GitHub Releases. You are currently using %@."),
            release.version,
            currentVersion
        )

        if let asset = release.downloadAsset {
            message += "\n\n"
            message += String(
                format: tr("Remora can download %@ directly to your download directory."),
                asset.name
            )
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

        do {
            let destinationURL = try await download(asset: asset)
            presentDownloadCompleteAlert(destinationURL: destinationURL, release: release)
        } catch {
            presentDownloadFailedAlert(error: error, release: release)
        }
    }

    private func download(asset: GitHubReleaseAsset) async throws -> URL {
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Remora/\(Self.currentVersion(from: bundle))", forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
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

    private func presentDownloadCompleteAlert(destinationURL: URL, release: GitHubRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = tr("Update downloaded")
        alert.informativeText = String(
            format: tr("Remora %@ was downloaded to:\n%@"),
            release.version,
            destinationURL.path
        )
        alert.addButton(withTitle: tr("Reveal in Finder"))
        alert.addButton(withTitle: tr("OK"))

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        }
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

    private func makeReleaseNotesView(for release: GitHubRelease) -> NSView {
        let titleLabel = NSTextField(labelWithString: tr("Release Notes"))
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.string = release.releaseNotes ?? tr("No release notes were provided for this release.")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        let stackView = NSStackView(views: [titleLabel, scrollView])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        return stackView
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
        L10n.tr(key, fallback: key)
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
    let downloadAsset: GitHubReleaseAsset?
}

struct GitHubReleaseAsset: Equatable {
    let name: String
    let downloadURL: URL
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
            return L10n.tr("The update service returned an unexpected response.", fallback: "The update service returned an unexpected response.")
        case .invalidPayload:
            return L10n.tr("The latest release metadata was incomplete.", fallback: "The latest release metadata was incomplete.")
        case let .httpStatus(statusCode):
            return String(
                format: L10n.tr("GitHub returned HTTP %d.", fallback: "GitHub returned HTTP %d."),
                statusCode
            )
        }
    }
}
