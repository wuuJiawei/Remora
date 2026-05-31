import SwiftUI

@MainActor
final class DockerLiveLogViewModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isFollowing = true
    @Published private(set) var lineCount: Int
    @Published var errorMessage: String?

    let title: String
    let subtitle: String?

    private let loadLatestHandler: @Sendable (Int) async throws -> String
    private let streamHandler: @Sendable (Int) async throws -> AsyncThrowingStream<String, Error>
    private var followTask: Task<Void, Never>?

    init(session: DockerLiveLogSession) {
        self.title = session.title
        self.subtitle = session.subtitle
        self.lineCount = session.lineCount
        self.loadLatestHandler = session.loadLatest
        self.streamHandler = session.stream
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
            text = try await loadLatestHandler(lineCount)
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

    func applyLineCount(_ newValue: Int) async {
        let clamped = min(max(newValue, 1), FileTransferViewModel.maxRemoteLogTailLineCount)
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
                let latest = try await loadLatestHandler(lineCount)
                guard !Task.isCancelled else { return }
                text = latest
                errorMessage = nil
                if isLoading {
                    isLoading = false
                }

                let stream = try await streamHandler(lineCount)
                isRefreshing = false

                for try await chunk in stream {
                    guard !Task.isCancelled else { return }
                    text += chunk
                    errorMessage = nil
                    if isLoading {
                        isLoading = false
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isFollowing = false
            }

            isLoading = false
            isRefreshing = false
            followTask = nil
        }
    }
}

struct DockerLiveLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: DockerLiveLogViewModel
    @State private var lineCountDraft: String

    init(session: DockerLiveLogSession) {
        _viewModel = StateObject(wrappedValue: DockerLiveLogViewModel(session: session))
        _lineCountDraft = State(initialValue: "\(session.lineCount)")
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.title)
                        .font(.headline)
                    if let subtitle = viewModel.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(tr("Read-only"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Toggle(tr("Follow"), isOn: Binding(
                    get: { viewModel.isFollowing },
                    set: { viewModel.setFollowing($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()

                HStack(spacing: 6) {
                    Text(tr("Lines"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(tr("Lines"), text: $lineCountDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .font(.caption.monospaced())
                        .onSubmit { applyLineCountDraft() }

                    Stepper("", value: Binding(
                        get: { viewModel.lineCount },
                        set: { newValue in
                            lineCountDraft = "\(newValue)"
                            Task { await viewModel.applyLineCount(newValue) }
                        }
                    ), in: 1 ... FileTransferViewModel.maxRemoteLogTailLineCount)
                    .labelsHidden()

                    Button(tr("Apply")) {
                        applyLineCountDraft()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button(tr("Refresh")) {
                    Task { await viewModel.refresh(showLoading: true) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isRefreshing)
            }

            ZStack(alignment: .topLeading) {
                MirroredRemoraEditorView(
                    text: Binding(
                        get: { viewModel.text },
                        set: { _ in }
                    ),
                    documentID: "docker-live-log:\(viewModel.title)",
                    language: .plain,
                    path: viewModel.subtitle,
                    isEditable: false,
                    autoScrollToBottom: viewModel.isFollowing
                )

                if viewModel.isLoading {
                    ProgressView("Loading...")
                        .padding(8)
                }
            }
            .frame(minHeight: 360)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(tr("Close")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 560)
        .task {
            await viewModel.load()
            lineCountDraft = "\(viewModel.lineCount)"
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private func applyLineCountDraft() {
        let parsed = Int(lineCountDraft) ?? viewModel.lineCount
        let clamped = min(max(parsed, 1), FileTransferViewModel.maxRemoteLogTailLineCount)
        lineCountDraft = "\(clamped)"
        Task { await viewModel.applyLineCount(clamped) }
    }
}
