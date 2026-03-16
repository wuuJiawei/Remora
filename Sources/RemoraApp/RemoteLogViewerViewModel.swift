import Foundation

@MainActor
final class RemoteLogViewerViewModel: ObservableObject {
    @Published var text: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isFollowing = true
    @Published private(set) var lineCount = FileTransferViewModel.defaultRemoteLogTailLineCount
    @Published var errorMessage: String?

    let path: String

    private let fileTransfer: FileTransferViewModel
    private var followTask: Task<Void, Never>?

    init(
        path: String,
        fileTransfer: FileTransferViewModel,
        followRefreshInterval: Duration = .seconds(1)
    ) {
        self.path = path
        self.fileTransfer = fileTransfer
        _ = followRefreshInterval
    }

    func load() async {
        if isFollowing {
            startFollowStream(showLoading: true)
        } else {
            await refresh(showLoading: true)
        }
    }

    func refresh(showLoading: Bool = false) async {
        if isFollowing {
            startFollowStream(showLoading: showLoading)
            return
        }

        guard !isRefreshing else { return }
        isRefreshing = true
        if showLoading {
            isLoading = true
        }
        defer {
            isRefreshing = false
            if showLoading {
                isLoading = false
            }
        }

        do {
            let latest = try await fileTransfer.loadRemoteLogTail(path: path, lineCount: lineCount)
            if latest != text {
                text = latest
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setFollowing(_ enabled: Bool) {
        guard isFollowing != enabled else { return }
        isFollowing = enabled
        if enabled {
            startFollowStream(showLoading: text.isEmpty)
        } else {
            stop()
        }
    }

    func applyLineCount(_ value: Int) async {
        let clamped = min(max(value, 1), FileTransferViewModel.maxRemoteLogTailLineCount)
        guard clamped != lineCount else { return }
        lineCount = clamped
        if isFollowing {
            startFollowStream(showLoading: false)
        } else {
            await refresh(showLoading: false)
        }
    }

    func stop() {
        followTask?.cancel()
        followTask = nil
        isLoading = false
        isRefreshing = false
    }

    private func startFollowStream(showLoading: Bool) {
        stop()
        if showLoading {
            isLoading = true
        }
        isRefreshing = true
        errorMessage = nil

        followTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.fileTransfer.streamRemoteLogTail(
                    path: self.path,
                    lineCount: self.lineCount
                )
                var accumulated = ""
                self.text = ""
                self.isRefreshing = false

                for try await chunk in stream {
                    guard !Task.isCancelled else { return }
                    accumulated += chunk
                    self.text = accumulated
                    self.errorMessage = nil
                    if self.isLoading {
                        self.isLoading = false
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isFollowing = false
            }

            self.isLoading = false
            self.isRefreshing = false
            self.followTask = nil
        }
    }
}
