import AppKit
import SwiftUI

struct DockerPanelView: View {
    @ObservedObject var viewModel: DockerPanelViewModel
    var onOpenContainerShell: (DockerContainer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            environmentSummary
            contentBody
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .textBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.96),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            if let toastMessage = viewModel.toastMessage {
                toastView(toastMessage)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $viewModel.liveLogSession) { session in
            DockerLiveLogSheet(session: session)
        }
        .alert(
            pendingConfirmationTitle,
            isPresented: pendingConfirmationBinding
        ) {
            Button(tr("Cancel"), role: .cancel) {
                viewModel.cancelPendingAction()
            }
            Button(tr("Continue")) {
                viewModel.confirmPendingAction()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: "shippingbox")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Docker"))
                        .panelTitleStyle()
                    Text(viewModel.runtimeBinding.host?.name ?? viewModel.runtimeBinding.host?.address ?? "—")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VisualStyle.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            WrapHStack(spacing: 6, lineSpacing: 6) {
                statusSummaryBadge(title: tr("Containers"), value: "\(viewModel.containers.count)", tint: .blue)
                statusSummaryBadge(title: tr("Images"), value: "\(viewModel.images.count)", tint: .orange)
                statusSummaryBadge(title: tr("Compose"), value: "\(viewModel.composeProjects.count)", tint: .green)
            }

            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.accentColor)
            .disabled(viewModel.isLoadingEnvironment || viewModel.isPerformingAction)
        }
    }

    private var environmentSummary: some View {
        HStack(spacing: 8) {
            environmentMetric(
                title: tr("Docker"),
                value: dockerStatusValue,
                detail: viewModel.environment.dockerVersion
            )
            environmentMetric(
                title: tr("Compose"),
                value: composeStatusValue,
                detail: viewModel.environment.composeIssue?.userMessage
            )
            if let issue = viewModel.environment.dockerIssue?.userMessage,
               !viewModel.environment.dockerAvailable {
                environmentMetric(
                    title: tr("State"),
                    value: tr("Unavailable"),
                    detail: issue
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var contentBody: some View {
        if viewModel.runtimeBinding.connectionMode != .ssh || viewModel.runtimeBinding.host == nil || !viewModel.runtimeBinding.connectionState.hasPrefix("Connected") {
            ContentUnavailableView(
                tr("Please connect to a server first"),
                systemImage: "server.rack",
                description: Text(tr("Docker tools are available after an SSH session is connected."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $viewModel.selectedTab) {
                    Text(tr("Containers")).tag(DockerPanelSelection.containers)
                    Text(tr("Images")).tag(DockerPanelSelection.images)
                    Text(tr("Compose")).tag(DockerPanelSelection.compose)
                }
                .pickerStyle(.segmented)

                switch viewModel.selectedTab {
                case .containers:
                    containersSection
                case .images:
                    imagesSection
                case .compose:
                    composeSection
                }
            }
        }
    }

    private var containersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterRow(
                title: tr("Containers"),
                filterText: $viewModel.containerFilterText,
                prompt: tr("Filter containers, images, ports, compose")
            )

            if viewModel.filteredContainers.isEmpty && !viewModel.isLoadingContainers {
                emptyState(
                    title: tr("No containers"),
                    systemImage: "shippingbox",
                    description: viewModel.containerFilterText.isEmpty
                        ? tr("No Docker containers were returned by the current server.")
                        : tr("No containers match the current filter.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if viewModel.isLoadingContainers && viewModel.filteredContainers.isEmpty {
                            ForEach(0..<5, id: \.self) { _ in
                                DockerSkeletonRow()
                            }
                        } else {
                            ForEach(viewModel.filteredContainers) { container in
                                DockerContainerRowView(
                                    container: container,
                                    details: viewModel.details(for: container.id),
                                    onToggleDetails: { viewModel.ensureContainerDetails(container) },
                                    onStart: { viewModel.requestAction(.startContainer(container)) },
                                    onStop: { viewModel.requestAction(.stopContainer(container)) },
                                    onRestart: { viewModel.requestAction(.restartContainer(container)) },
                                    onLogs: { viewModel.loadContainerLogs(container) },
                                    onShell: { onOpenContainerShell(container) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var imagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterRow(
                title: tr("Images"),
                filterText: $viewModel.imageFilterText,
                prompt: tr("Filter repositories, tags, IDs")
            )

            if viewModel.filteredImages.isEmpty && !viewModel.isLoadingImages {
                emptyState(
                    title: tr("No images"),
                    systemImage: "shippingbox.fill",
                    description: viewModel.imageFilterText.isEmpty
                        ? tr("No Docker images were returned by the current server.")
                        : tr("No images match the current filter.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if viewModel.isLoadingImages && viewModel.filteredImages.isEmpty {
                            ForEach(0..<5, id: \.self) { _ in
                                DockerSkeletonRow()
                            }
                        } else {
                            ForEach(viewModel.filteredImages) { image in
                                DockerImageRowView(image: image)
                            }
                        }
                    }
                }
            }
        }
    }

    private var composeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterRow(
                title: tr("Compose"),
                filterText: $viewModel.composeFilterText,
                prompt: tr("Filter projects, status, paths")
            )

            if viewModel.filteredComposeProjects.isEmpty && !viewModel.isLoadingCompose {
                emptyState(
                    title: tr("No Compose projects"),
                    systemImage: "square.stack.3d.up",
                    description: viewModel.composeFilterText.isEmpty
                        ? tr("No Docker Compose projects were returned by the current server.")
                        : tr("No Compose projects match the current filter.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if viewModel.isLoadingCompose && viewModel.filteredComposeProjects.isEmpty {
                            ForEach(0..<4, id: \.self) { _ in
                                DockerSkeletonRow()
                            }
                        } else {
                            ForEach(viewModel.filteredComposeProjects) { project in
                                DockerComposeProjectRowView(
                                    project: project,
                                    onUp: { viewModel.requestAction(.composeUp(project)) },
                                    onDown: { viewModel.requestAction(.composeDown(project)) },
                                    onRestart: { viewModel.requestAction(.composeRestart(project)) },
                                    onLogs: { viewModel.loadComposeLogs(project) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func filterRow(
        title: String,
        filterText: Binding<String>,
        prompt: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)
                .frame(width: 70, alignment: .leading)

            TextField(prompt, text: filterText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            if !filterText.wrappedValue.isEmpty {
                Button {
                    filterText.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(VisualStyle.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
    }

    private func emptyState(title: String, systemImage: String, description: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 30)
    }

    private func environmentMetric(title: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(VisualStyle.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusSummaryBadge(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(VisualStyle.textSecondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.09), in: Capsule())
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
    }

    private func toastView(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.8))
            )
    }

    private var dockerStatusValue: String {
        if viewModel.environment.dockerAvailable {
            return tr("Available")
        }
        return tr("Unavailable")
    }

    private var composeStatusValue: String {
        if let composeVersion = viewModel.environment.composeVersion, !composeVersion.isEmpty {
            return composeVersion
        }
        if viewModel.environment.composeAvailable {
            return tr("Available")
        }
        return tr("Unavailable")
    }

    private var pendingConfirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingConfirmationAction != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.cancelPendingAction()
                }
            }
        )
    }

    private var pendingConfirmationTitle: String {
        viewModel.pendingConfirmationAction?.confirmationTitle ?? tr("Confirm Action")
    }
}

private struct DockerSkeletonRow: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(skeletonColor)
                .frame(width: 180, height: 13)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(skeletonColor)
                .frame(maxWidth: 360)
                .frame(height: 11)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(skeletonColor)
                        .frame(width: 96, height: 22)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

    private var skeletonColor: Color {
        Color(nsColor: .separatorColor)
            .opacity(isAnimating ? 0.12 : 0.22)
    }
}

private struct DockerContainerRowView: View {
    let container: DockerContainer
    let details: DockerContainerDetails?
    let onToggleDetails: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onLogs: () -> Void
    let onShell: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    isExpanded.toggle()
                    if isExpanded {
                        onToggleDetails()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VisualStyle.textTertiary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(container.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VisualStyle.textPrimary)
                        statusBadge(container.stateBadgeLabel, running: container.isRunning)
                    }

                    Text(container.image)
                        .font(.system(size: 11))
                        .foregroundStyle(VisualStyle.textSecondary)
                        .lineLimit(1)

                    metadataWrap {
                        badge(title: tr("ID"), value: container.shortID, tint: .blue)
                        badge(title: tr("Ports"), value: displayPorts, tint: .green)
                        badge(title: tr("Compose"), value: composeSummary, tint: .orange)
                        badge(title: tr("Age"), value: container.runningFor ?? container.createdAt ?? "—", tint: .purple)
                    }
                }

                Spacer(minLength: 0)
            }

            actionRow

            if isExpanded {
                detailSection
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            if container.isRunning {
                compactActionButton(tr("Shell"), systemImage: "terminal", action: onShell)
                compactActionButton(tr("Logs"), systemImage: "doc.text.magnifyingglass", action: onLogs)
                compactActionButton(tr("Stop"), systemImage: "stop.fill", action: onStop)
                compactActionButton(tr("Restart"), systemImage: "arrow.clockwise", action: onRestart)
            } else {
                compactActionButton(tr("Start"), systemImage: "play.fill", action: onStart)
                compactActionButton(tr("Logs"), systemImage: "doc.text.magnifyingglass", action: onLogs)
            }
        }
    }

    @ViewBuilder
    private var detailSection: some View {
        if let details {
            VStack(alignment: .leading, spacing: 6) {
                if let command = details.command, !command.isEmpty {
                    detailRow(tr("Command"), value: command, monospaced: true)
                }
                if let workingDir = details.workingDir, !workingDir.isEmpty {
                    detailRow(tr("Working Dir"), value: workingDir, monospaced: true)
                }
                if let entrypoint = details.entrypoint, !entrypoint.isEmpty {
                    detailRow(tr("Entrypoint"), value: entrypoint, monospaced: true)
                }
                if !details.ports.isEmpty {
                    detailRow(tr("Port Mappings"), value: details.ports.joined(separator: "\n"), monospaced: true)
                }
                if !details.mounts.isEmpty {
                    detailRow(tr("Mounts"), value: details.mounts.joined(separator: "\n"), monospaced: true)
                }
                if !details.networks.isEmpty {
                    detailRow(tr("Networks"), value: details.networks.joined(separator: ", "), monospaced: false)
                }
            }
            .padding(.leading, 22)
            .padding(.top, 2)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(tr("Loading container details..."))
                    .font(.system(size: 11))
                    .foregroundStyle(VisualStyle.textSecondary)
            }
            .padding(.leading, 22)
        }
    }

    private var displayPorts: String {
        guard let ports = container.ports?.trimmingCharacters(in: .whitespacesAndNewlines), !ports.isEmpty else {
            return "—"
        }
        return ports
    }

    private var composeSummary: String {
        if let project = container.composeProject, let service = container.composeService {
            return "\(project)/\(service)"
        }
        if let project = container.composeProject {
            return project
        }
        return "—"
    }

    private func detailRow(_ title: String, value: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundStyle(VisualStyle.textPrimary)
                .textSelection(.enabled)
        }
    }

    private func compactActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func badge(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(VisualStyle.textSecondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.08), in: Capsule())
    }

    private func metadataWrap(@ViewBuilder _ content: () -> some View) -> some View {
        WrapHStack(spacing: 6, lineSpacing: 6) {
            content()
        }
    }

    private func statusBadge(_ value: String, running: Bool) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(running ? Color.green.opacity(0.16) : Color.secondary.opacity(0.16))
            )
    }
}

private struct DockerImageRowView: View {
    let image: DockerImage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(image.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VisualStyle.textPrimary)
                    if image.isDangling {
                        Text(tr("dangling"))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
                WrapHStack(spacing: 6, lineSpacing: 6) {
                    badge(title: tr("ID"), value: image.shortID, tint: .blue)
                    if let size = image.size {
                        badge(title: tr("Size"), value: size, tint: .green)
                    }
                    if let age = image.createdSince {
                        badge(title: tr("Age"), value: age, tint: .purple)
                    }
                    if let digest = image.digest, !digest.isEmpty {
                        badge(title: tr("Digest"), value: digest, tint: .orange)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
    }

    private func badge(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(VisualStyle.textSecondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.08), in: Capsule())
    }
}

private struct DockerComposeProjectRowView: View {
    let project: DockerComposeProject
    let onUp: () -> Void
    let onDown: () -> Void
    let onRestart: () -> Void
    let onLogs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VisualStyle.textPrimary)

                    WrapHStack(spacing: 6, lineSpacing: 6) {
                        if let status = project.status, !status.isEmpty {
                            badge(title: tr("Status"), value: status, tint: .green)
                        }
                        if let workingDir = project.workingDir, !workingDir.isEmpty {
                            badge(title: tr("Dir"), value: workingDir, tint: .blue)
                        }
                        if let serviceCount = project.serviceCount {
                            badge(title: tr("Services"), value: "\(serviceCount)", tint: .purple)
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    compactActionButton(tr("Up"), systemImage: "play.fill", action: onUp)
                        .disabled(!project.canRunCommands)
                    compactActionButton(tr("Down"), systemImage: "stop.fill", action: onDown)
                        .disabled(!project.canRunCommands)
                    compactActionButton(tr("Restart"), systemImage: "arrow.clockwise", action: onRestart)
                        .disabled(!project.canRunCommands)
                    compactActionButton(tr("Logs"), systemImage: "doc.text.magnifyingglass", action: onLogs)
                        .disabled(!project.canRunCommands)
                }
            }

            if !project.configFiles.isEmpty {
                Text(project.configFiles.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(VisualStyle.textTertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
    }

    private func compactActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func badge(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(VisualStyle.textSecondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualStyle.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.08), in: Capsule())
    }
}

private struct WrapHStack<Content: View>: View {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        _WrapHStackLayout(spacing: spacing, lineSpacing: lineSpacing) {
            content
        }
    }
}

private struct _WrapHStackLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0, currentX + size.width > maxWidth {
                maxLineWidth = max(maxLineWidth, currentX - spacing)
                currentX = 0
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }

            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        maxLineWidth = max(maxLineWidth, max(0, currentX - spacing))
        return CGSize(width: maxLineWidth, height: currentY + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX, currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
