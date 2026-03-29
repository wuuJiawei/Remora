import AppKit
import Combine
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var isChecking = false

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
            releaseNotes: Self.normalizedReleaseNotes(payload.body)
        )
    }

    private func presentAlertIfNeeded(for status: UpdateCheckStatus, trigger: UpdateTrigger) {
        switch (status, trigger) {
        case let (.updateAvailable(release, currentVersion), _):
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = tr("Update available")
            alert.informativeText = String(
                format: tr("Remora %@ is available on GitHub Releases. You are currently using %@."),
                release.version,
                currentVersion
            )
            alert.accessoryView = makeReleaseNotesView(for: release)
            alert.addButton(withTitle: tr("View Release"))
            alert.addButton(withTitle: tr("Later"))

            if alert.runModal() == .alertFirstButtonReturn {
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
}

private struct GitHubLatestReleasePayload: Decodable {
    let tagName: String
    let htmlURL: URL?
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
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
