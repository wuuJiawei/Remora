import AppKit
import SwiftUI

struct DockerPanelView: View {
    @ObservedObject var viewModel: DockerPanelViewModel
    var onOpenContainerShell: (DockerContainer) -> Void

    @State private var selectedResource: DockerInspectorSelection?
    @State private var expandedComposeProjects: Set<String> = []

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)

            verticalSeparator

            if viewModel.selectedTab == .activityMonitor {
                activityMonitorView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resourceList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            if let toastMessage = viewModel.toastMessage {
                toastView(toastMessage)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $viewModel.liveLogSession) { session in
            DockerLiveLogSheet(session: session)
        }
        .alert(pendingConfirmationTitle, isPresented: pendingConfirmationBinding) {
            Button(tr("Cancel"), role: .cancel) {
                viewModel.cancelPendingAction()
            }
            Button(tr("Continue")) {
                viewModel.confirmPendingAction()
            }
        }
        .onChange(of: viewModel.selectedTab) { _, _ in
            selectedResource = viewModel.selectedTab == .activityMonitor ? .monitor : nil
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                sidebarHeader

                sidebarSection(title: tr("Docker")) {
                    sidebarButton(.containers, title: tr("Containers"), systemImage: "shippingbox")
                    sidebarButton(.volumes, title: tr("Volumes"), systemImage: "externaldrive")
                    sidebarButton(.images, title: tr("Images"), systemImage: "doc.on.clipboard")
                    sidebarButton(.networks, title: tr("Networks"), systemImage: "network")
                }

                sidebarSection(title: tr("Kubernetes")) {
                    sidebarButton(.kubernetesPods, title: tr("Pods"), systemImage: "atom")
                    sidebarButton(.kubernetesServices, title: tr("Services"), systemImage: "globe")
                }

                sidebarSection(title: tr("Linux")) {
                    sidebarButton(.machines, title: tr("Machines"), systemImage: "desktopcomputer")
                }

                sidebarSection(title: tr("General")) {
                    sidebarButton(.activityMonitor, title: tr("Activity Monitor"), systemImage: "chart.xyaxis.line")
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Divider()
                .opacity(0.55)

            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 32, height: 32)
                    Circle()
                        .fill(viewModel.runtimeBinding.connectionState.hasPrefix("Connected") ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(hostTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(viewModel.runtimeBinding.connectionState.hasPrefix("Connected") ? tr("Connected") : tr("Disconnected"))
                        .font(.system(size: 11))
                        .foregroundStyle(VisualStyle.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
        .background(.thinMaterial)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 30, height: 30)
                Image(systemName: "shippingbox")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Docker"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VisualStyle.textPrimary)
                Text(hostTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private func sidebarSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VisualStyle.textTertiary)
                .padding(.horizontal, 4)
            content()
        }
    }

    private func sidebarButton(
        _ selection: DockerPanelSelection,
        title: String,
        systemImage: String
    ) -> some View {
        let isSelected = viewModel.selectedTab == selection
        return Button {
            withAnimation(.easeOut(duration: 0.12)) {
                viewModel.selectedTab = selection
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? VisualStyle.textPrimary : VisualStyle.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? VisualStyle.leftSelectedBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? VisualStyle.borderSoft : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var resourceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch viewModel.selectedTab {
            case .containers:
                containersList
            case .volumes:
                volumesList
            case .images:
                imagesList
            case .networks:
                networksList
            case .kubernetesPods, .kubernetesServices, .machines, .commands:
                placeholderList
            case .activityMonitor:
                EmptyView()
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.82))
    }

    private var resourceToolbar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentTitle)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                Text(currentSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            toolbarIcon("arrow.up.arrow.down") {}
            toolbarIcon("magnifyingglass") {}
            toolbarIcon("plus") {}
                .disabled(true)
            toolbarIcon("arrow.clockwise") {
                viewModel.refresh()
            }
            .disabled(viewModel.isLoadingEnvironment || viewModel.isPerformingAction)
        }
    }

    private var containersList: some View {
        VStack(spacing: 0) {
            dockerTableHeader([
                DockerTableColumn(title: tr("Name"), width: nil, alignment: .leading),
                DockerTableColumn(title: tr("Status"), width: 90, alignment: .leading),
                DockerTableColumn(title: tr("Ports"), width: 260, alignment: .leading),
                DockerTableColumn(title: tr("Compose"), width: 170, alignment: .leading),
                DockerTableColumn(title: "", width: 76, alignment: .trailing),
            ])

            listScroll {
                if viewModel.isLoadingContainers && viewModel.filteredContainers.isEmpty {
                    skeletonRows(count: 8)
                } else if viewModel.filteredContainers.isEmpty {
                    listEmptyState(title: tr("No containers"), systemImage: "shippingbox")
                } else {
                    containerSection(title: tr("Running"), groups: runningContainerGroups)
                    containerSection(title: tr("Stopped"), groups: stoppedContainerGroups)
                }
            }
        }
    }

    private var volumesList: some View {
        VStack(spacing: 0) {
            dockerTableHeader([
                DockerTableColumn(title: tr("Name"), width: nil, alignment: .leading),
                DockerTableColumn(title: tr("Driver"), width: 120, alignment: .leading),
                DockerTableColumn(title: tr("Scope"), width: 110, alignment: .leading),
                DockerTableColumn(title: tr("Mountpoint"), width: 360, alignment: .leading),
                DockerTableColumn(title: "", width: 44, alignment: .trailing),
            ])

            listScroll {
                if viewModel.isLoadingVolumes && viewModel.filteredVolumes.isEmpty {
                    skeletonRows(count: 8)
                } else if viewModel.filteredVolumes.isEmpty {
                    listEmptyState(title: tr("No volumes"), systemImage: "externaldrive")
                } else {
                    ForEach(viewModel.filteredVolumes) { volume in
                        volumeRow(volume)
                    }
                }
            }
        }
    }

    private var imagesList: some View {
        VStack(spacing: 0) {
            dockerTableHeader([
                DockerTableColumn(title: tr("Repository"), width: nil, alignment: .leading),
                DockerTableColumn(title: tr("Tag"), width: 150, alignment: .leading),
                DockerTableColumn(title: tr("Size"), width: 110, alignment: .trailing),
                DockerTableColumn(title: tr("Created"), width: 160, alignment: .leading),
                DockerTableColumn(title: "", width: 44, alignment: .trailing),
            ])

            listScroll {
                if viewModel.isLoadingImages && viewModel.filteredImages.isEmpty {
                    skeletonRows(count: 10)
                } else if viewModel.filteredImages.isEmpty {
                    listEmptyState(title: tr("No images"), systemImage: "doc.on.clipboard")
                } else {
                    ForEach(viewModel.filteredImages) { image in
                        imageRow(image)
                    }
                }
            }
        }
    }

    private var networksList: some View {
        VStack(spacing: 0) {
            dockerTableHeader([
                DockerTableColumn(title: tr("Name"), width: nil, alignment: .leading),
                DockerTableColumn(title: tr("Driver"), width: 120, alignment: .leading),
                DockerTableColumn(title: tr("Scope"), width: 110, alignment: .leading),
                DockerTableColumn(title: tr("Subnet"), width: 180, alignment: .leading),
                DockerTableColumn(title: tr("Gateway"), width: 180, alignment: .leading),
                DockerTableColumn(title: "", width: 44, alignment: .trailing),
            ])

            listScroll {
                if viewModel.isLoadingNetworks && viewModel.filteredNetworks.isEmpty {
                    skeletonRows(count: 8)
                } else if viewModel.filteredNetworks.isEmpty {
                    listEmptyState(title: tr("No networks"), systemImage: "network")
                } else {
                    ForEach(viewModel.filteredNetworks) { network in
                        networkRow(network)
                    }
                }
            }
        }
    }

    private var placeholderList: some View {
        VStack {
            Spacer()
            ContentUnavailableView(
                viewModel.selectedTab.isKubernetesPendingFeature ? tr("Stay Tuned") : currentTitle,
                systemImage: currentSystemImage,
                description: Text(viewModel.selectedTab.isKubernetesPendingFeature ? tr("Kubernetes features are in development") : tr("This section is not available yet."))
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func dockerTableHeader(_ columns: [DockerTableColumn]) -> some View {
        HStack(spacing: 10) {
            ForEach(columns) { column in
                Text(column.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)
                    .frame(
                        minWidth: column.width ?? 0,
                        maxWidth: column.width == nil ? .infinity : column.width,
                        alignment: column.alignment
                    )
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 32)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(VisualStyle.borderSoft.opacity(0.8))
                .frame(height: 1)
        }
    }

    private func containerSection(title: String, groups: [DockerContainerGroup]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !groups.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ForEach(groups) { group in
                    if let projectName = group.projectName {
                        composeGroupRow(projectName: projectName, containers: group.containers)
                        if expandedComposeProjects.contains(projectName) {
                            ForEach(group.containers) { container in
                                containerRow(container, indent: 28)
                            }
                        }
                    } else {
                        ForEach(group.containers) { container in
                            containerRow(container, indent: 0)
                        }
                    }
                }
            }
        }
    }

    private func composeGroupRow(projectName: String, containers: [DockerContainer]) -> some View {
        let project = viewModel.composeProjects.first(where: { $0.name == projectName })
        let isExpanded = expandedComposeProjects.contains(projectName)
        let isSelected = selectedResource == .compose(projectName)

        return Button {
            selectedResource = .compose(projectName)
            withAnimation(.easeOut(duration: 0.12)) {
                if isExpanded {
                    expandedComposeProjects.remove(projectName)
                } else {
                    expandedComposeProjects.insert(projectName)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .frame(width: 12)

                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.purple.opacity(0.72))
                    .frame(width: 20)

                Text(projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(project?.status ?? String(format: tr("%d containers"), containers.count))
                    .font(.system(size: 12))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)
                    .frame(width: 90, alignment: .leading)

                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .frame(width: 260, alignment: .leading)

                Text(projectName)
                    .font(.system(size: 12))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)
                    .frame(width: 170, alignment: .leading)

                Spacer(minLength: 0)

                if let project {
                    rowIconButton(project.status?.lowercased().contains("running") == true ? "stop.fill" : "play.fill") {
                        if project.status?.lowercased().contains("running") == true {
                            viewModel.requestAction(.composeDown(project))
                        } else {
                            viewModel.requestAction(.composeUp(project))
                        }
                    }
                    .disabled(!project.canRunCommands)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(selectionBackground(isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let project {
                composeContextMenu(project)
            }
        }
    }

    private func containerRow(_ container: DockerContainer, indent: CGFloat) -> some View {
        let isSelected = selectedResource == .container(container.id)
        return Button {
            selectedResource = .container(container.id)
            viewModel.ensureContainerDetails(container)
        } label: {
            HStack(spacing: 10) {
                Color.clear.frame(width: indent)

                Image(systemName: "cube.box.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(container.isRunning ? Color.red.opacity(0.82) : Color.gray.opacity(0.5))
                    .frame(width: 20)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(container.isRunning ? Color.green : Color.gray)
                            .frame(width: 7, height: 7)
                    }

                Text(container.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(container.stateBadgeLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(container.isRunning ? Color.green : VisualStyle.textSecondary)
                    .lineLimit(1)
                    .frame(width: 90, alignment: .leading)

                Text(container.ports?.isEmpty == false ? container.ports! : "—")
                    .font(.system(size: 12))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)
                    .frame(width: 260, alignment: .leading)

                Text(composeSummary(for: container))
                    .font(.system(size: 12))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)
                    .frame(width: 170, alignment: .leading)

                Spacer(minLength: 0)

                rowIconButton(container.isRunning ? "stop.fill" : "play.fill") {
                    viewModel.requestAction(container.isRunning ? .stopContainer(container) : .startContainer(container))
                }
                rowIconButton("trash") {
                    viewModel.requestAction(.deleteContainer(container))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(selectionBackground(isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            containerContextMenu(container)
        }
    }

    private func volumeRow(_ volume: DockerVolume) -> some View {
        let isSelected = selectedResource == .volume(volume.id)
        return Button {
            selectedResource = .volume(volume.id)
        } label: {
            simpleResourceRow(
                title: volume.name,
                subtitle: volume.mountpoint ?? volume.driver ?? "—",
                systemImage: "externaldrive",
                tint: .teal,
                isSelected: isSelected,
                deleteAction: { viewModel.requestAction(.deleteVolume(volume)) }
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(tr("Delete"), role: .destructive) { viewModel.requestAction(.deleteVolume(volume)) }
            Divider()
            Button(tr("Copy Name")) { copyToPasteboard(volume.name) }
            if let mountpoint = volume.mountpoint {
                Button(tr("Copy Path")) { copyToPasteboard(mountpoint) }
            }
        }
    }

    private func imageRow(_ image: DockerImage) -> some View {
        let isSelected = selectedResource == .image(image.id)
        return Button {
            selectedResource = .image(image.id)
        } label: {
            simpleResourceRow(
                title: image.displayName,
                subtitle: [image.size, image.createdSince].compactMap { $0 }.joined(separator: ", "),
                systemImage: "cube.transparent.fill",
                tint: image.isDangling ? .orange : .blue,
                isSelected: isSelected,
                badge: image.isDangling ? tr("dangling") : nil,
                deleteAction: { viewModel.requestAction(.deleteImage(image)) }
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(tr("Delete"), role: .destructive) { viewModel.requestAction(.deleteImage(image)) }
            Divider()
            Button(tr("Copy ID")) { copyToPasteboard(image.imageID) }
            Button(tr("Copy Name")) { copyToPasteboard(image.displayName) }
        }
    }

    private func networkRow(_ network: DockerNetwork) -> some View {
        let isSelected = selectedResource == .network(network.id)
        return Button {
            selectedResource = .network(network.id)
        } label: {
            simpleResourceRow(
                title: network.name,
                subtitle: network.subnet ?? network.driver ?? "—",
                systemImage: "network",
                tint: .purple,
                isSelected: isSelected,
                deleteAction: { viewModel.requestAction(.deleteNetwork(network)) }
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(tr("Delete"), role: .destructive) { viewModel.requestAction(.deleteNetwork(network)) }
            Divider()
            Button(tr("Copy ID")) { copyToPasteboard(network.id) }
            Button(tr("Copy Name")) { copyToPasteboard(network.name) }
        }
    }

    private func simpleResourceRow(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        isSelected: Bool,
        badge: String? = nil,
        deleteAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint.opacity(0.78))
                .frame(width: 20)

            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.yellow.opacity(0.26), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(subtitle.isEmpty ? "—" : subtitle)
                .font(.system(size: 12))
                .foregroundStyle(VisualStyle.textSecondary)
                .lineLimit(1)
                .frame(width: 360, alignment: .leading)

            Spacer(minLength: 0)

            rowIconButton("trash", action: deleteAction)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(selectionBackground(isSelected))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var inspector: some View {
        VStack(spacing: 0) {
            inspectorToolbar
            Divider()

            switch selectedResource {
            case .container(let id):
                if let container = viewModel.containers.first(where: { $0.id == id }) {
                    containerInspector(container)
                } else {
                    noSelectionView
                }
            case .compose(let name):
                composeInspector(name)
            case .volume(let id):
                if let volume = viewModel.volumes.first(where: { $0.id == id }) {
                    volumeInspector(volume)
                } else {
                    noSelectionView
                }
            case .image(let id):
                if let image = viewModel.images.first(where: { $0.id == id }) {
                    imageInspector(image)
                } else {
                    noSelectionView
                }
            case .network(let id):
                if let network = viewModel.networks.first(where: { $0.id == id }) {
                    networkInspector(network)
                } else {
                    noSelectionView
                }
            case .monitor, .none:
                noSelectionView
            }
        }
        .background(.regularMaterial)
    }

    private var inspectorToolbar: some View {
        HStack(spacing: 10) {
            toolbarIcon("plus") {}
                .disabled(true)
            Spacer()
            Picker("", selection: .constant("info")) {
                Text(tr("Info")).tag("info")
            }
            .pickerStyle(.menu)
            .frame(width: 98)
            Spacer()
            Button(tr("Sign in again")) {}
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.bar)
    }

    private var noSelectionView: some View {
        VStack {
            Spacer()
            Text(tr("No Selection"))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(VisualStyle.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func containerInspector(_ container: DockerContainer) -> some View {
        ScrollView {
            inspectorContentHeader(
                title: container.name,
                subtitle: container.image,
                systemImage: "cube.box.fill",
                tint: container.isRunning ? .red : .gray
            )

            VStack(alignment: .leading, spacing: 14) {
                inspectorSection(title: tr("Info")) {
                    detailLine(tr("Status"), container.status)
                    detailLine(tr("ID"), container.id, monospaced: true)
                    detailLine(tr("Image"), container.image)
                    detailLine(tr("Ports"), container.ports ?? "—", monospaced: true)
                    detailLine(tr("Compose"), container.composeProject ?? "—")
                }

                if let details = viewModel.details(for: container.id) {
                    inspectorSection(title: tr("Details")) {
                        detailLine(tr("Command"), details.command ?? "—", monospaced: true)
                        detailLine(tr("Working Dir"), details.workingDir ?? "—", monospaced: true)
                        detailLine(tr("Entrypoint"), details.entrypoint ?? "—", monospaced: true)
                        detailLine(tr("Restart Count"), details.restartCount.map(String.init) ?? "—")
                        detailMultiline(tr("Mounts"), details.mounts)
                        detailMultiline(tr("Networks"), details.networks)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(tr("Loading container details..."))
                            .font(.system(size: 12))
                            .foregroundStyle(VisualStyle.textSecondary)
                    }
                    .padding(.horizontal, 18)
                }
            }
            .padding(.bottom, 18)
        }
        .onAppear {
            viewModel.ensureContainerDetails(container)
        }
    }

    private func composeInspector(_ name: String) -> some View {
        let project = viewModel.composeProjects.first(where: { $0.name == name })
        let containers = viewModel.containers.filter { $0.composeProject == name }

        return ScrollView {
            inspectorContentHeader(
                title: name,
                subtitle: String(format: tr("%d containers"), containers.count),
                systemImage: "square.stack.3d.up.fill",
                tint: .purple
            )

            VStack(alignment: .leading, spacing: 14) {
                inspectorSection(title: tr("Info")) {
                    detailLine(tr("Status"), project?.status ?? "—")
                    detailLine(tr("Services"), project?.serviceCount.map(String.init) ?? "\(containers.count)")
                    detailLine(tr("Working Dir"), project?.workingDir ?? "—", monospaced: true)
                    detailMultiline(tr("Compose Files"), project?.configFiles ?? [])
                }

                inspectorSection(title: tr("Containers")) {
                    ForEach(containers) { container in
                        detailLine(container.name, container.stateBadgeLabel)
                    }
                }
            }
            .padding(.bottom, 18)
        }
    }

    private func volumeInspector(_ volume: DockerVolume) -> some View {
        ScrollView {
            inspectorContentHeader(title: volume.name, subtitle: volume.driver ?? "—", systemImage: "externaldrive", tint: .teal)
            VStack(alignment: .leading, spacing: 14) {
                inspectorSection(title: tr("Info")) {
                    detailLine(tr("Name"), volume.name)
                    detailLine(tr("Driver"), volume.driver ?? "—")
                    detailLine(tr("Scope"), volume.scope ?? "—")
                    detailLine(tr("Mountpoint"), volume.mountpoint ?? "—", monospaced: true)
                }
            }
            .padding(.bottom, 18)
        }
    }

    private func imageInspector(_ image: DockerImage) -> some View {
        ScrollView {
            inspectorContentHeader(title: image.displayName, subtitle: image.size ?? "—", systemImage: "cube.transparent.fill", tint: .blue)
            VStack(alignment: .leading, spacing: 14) {
                inspectorSection(title: tr("Info")) {
                    detailLine(tr("Repository"), image.repository)
                    detailLine(tr("Tag"), image.tag)
                    detailLine(tr("ID"), image.imageID, monospaced: true)
                    detailLine(tr("Digest"), image.digest ?? "—", monospaced: true)
                    detailLine(tr("Created"), image.createdSince ?? image.createdAt ?? "—")
                    detailLine(tr("Size"), image.size ?? "—")
                }
            }
            .padding(.bottom, 18)
        }
    }

    private func networkInspector(_ network: DockerNetwork) -> some View {
        ScrollView {
            inspectorContentHeader(title: network.name, subtitle: network.subnet ?? network.driver ?? "—", systemImage: "network", tint: .purple)
            VStack(alignment: .leading, spacing: 14) {
                inspectorSection(title: tr("Info")) {
                    detailLine(tr("ID"), network.id, monospaced: true)
                    detailLine(tr("Driver"), network.driver ?? "—")
                    detailLine(tr("Scope"), network.scope ?? "—")
                    detailLine(tr("Subnet"), network.subnet ?? "—", monospaced: true)
                    detailLine(tr("Gateway"), network.gateway ?? "—", monospaced: true)
                }
            }
            .padding(.bottom, 18)
        }
    }

    private var activityMonitorView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Activity Monitor"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(String(format: tr("%d running"), viewModel.containers.filter(\.isRunning).count))
                        .font(.system(size: 12))
                        .foregroundStyle(VisualStyle.textSecondary)
                }
                Spacer()
                toolbarIcon("clock.arrow.circlepath") {
                    viewModel.refresh()
                }
                Button(tr("Sign in again")) {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
            }
            .padding(.horizontal, 22)
            .frame(height: 64)

            Divider()

            activityTable

            Divider()

            HStack(spacing: 10) {
                monitorMetric(title: tr("Total CPU:"), value: String(format: "%.1f%%", viewModel.activitySnapshot.totalCPUPercent), tint: .red)
                monitorMetric(title: tr("Memory:"), value: viewModel.activitySnapshot.totalMemoryUsage, tint: .blue)
                monitorMetric(title: tr("Network:"), value: aggregateIO(\.networkIO), tint: .green)
                monitorMetric(title: tr("Disk:"), value: aggregateIO(\.blockIO), tint: .purple)
            }
            .padding(18)
        }
        .background(.regularMaterial)
    }

    private var activityTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("Name")).frame(maxWidth: .infinity, alignment: .leading)
                Text(tr("CPU %")).frame(width: 90, alignment: .trailing)
                Text(tr("Memory")).frame(width: 130, alignment: .trailing)
                Text(tr("Network")).frame(width: 120, alignment: .trailing)
                Text(tr("Disk")).frame(width: 120, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(VisualStyle.textSecondary)
            .padding(.horizontal, 22)
            .frame(height: 34)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    activityRow(
                        name: tr("Containers"),
                        icon: "shippingbox.fill",
                        cpu: String(format: "%.1f", viewModel.activitySnapshot.totalCPUPercent),
                        memory: viewModel.activitySnapshot.totalMemoryUsage,
                        network: aggregateIO(\.networkIO),
                        disk: aggregateIO(\.blockIO),
                        depth: 0,
                        tint: .primary
                    )

                    ForEach(viewModel.activitySnapshot.stats) { stat in
                        activityRow(
                            name: stat.name,
                            icon: "cube.box.fill",
                            cpu: String(format: "%.1f", stat.cpuPercent),
                            memory: stat.memoryUsage,
                            network: stat.networkIO,
                            disk: stat.blockIO,
                            depth: 1,
                            tint: .red
                        )
                    }

                    ForEach(0..<8, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(VisualStyle.mutedSurfaceBackground)
                            .frame(height: 28)
                            .padding(.horizontal, 22)
                            .padding(.top, 20)
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    private func activityRow(
        name: String,
        icon: String,
        cpu: String,
        memory: String,
        network: String,
        disk: String,
        depth: CGFloat,
        tint: Color
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Color.clear.frame(width: depth * 24)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint.opacity(0.78))
                Text(name)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(cpu).frame(width: 90, alignment: .trailing)
            Text(memory).frame(width: 130, alignment: .trailing)
            Text(network).frame(width: 120, alignment: .trailing)
            Text(disk).frame(width: 120, alignment: .trailing)
        }
        .font(.system(size: 13, weight: depth == 0 ? .semibold : .regular))
        .padding(.horizontal, 22)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(depth == 1 ? VisualStyle.leftHoverBackground.opacity(0.45) : Color.clear)
                .padding(.horizontal, 18)
        )
    }

    private func inspectorContentHeader(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tint.opacity(0.84))
                .frame(width: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private func inspectorSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)
            content()
        }
        .padding(.horizontal, 18)
    }

    private func detailLine(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VisualStyle.textSecondary)
                .frame(width: 104, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(VisualStyle.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailMultiline(_ title: String, _ values: [String]) -> some View {
        detailLine(title, values.isEmpty ? "—" : values.joined(separator: "\n"), monospaced: true)
    }

    private func monitorMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack {
                Spacer()
                Circle()
                    .fill(tint)
                    .frame(width: 3, height: 3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
    }

    private func filterField(text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VisualStyle.textTertiary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(VisualStyle.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
    }

    private func skeletonRows(count: Int) -> some View {
        ForEach(0..<count, id: \.self) { _ in
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(VisualStyle.mutedSurfaceBackground)
                .frame(height: 46)
                .padding(.vertical, 3)
        }
    }

    private func listEmptyState(title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func selectionBackground(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isSelected ? VisualStyle.leftSelectedBackground : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? VisualStyle.borderSoft : Color.clear, lineWidth: 1)
            )
    }

    private func rowIconButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VisualStyle.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toolbarIcon(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .stroke(VisualStyle.borderSoft.opacity(0.55), lineWidth: 1)
                )
        }
        .buttonStyle(.borderless)
    }

    private var verticalSeparator: some View {
        Rectangle()
            .fill(VisualStyle.borderSoft.opacity(0.7))
            .frame(width: 1)
    }

    @ViewBuilder
    private func containerContextMenu(_ container: DockerContainer) -> some View {
        if container.isRunning {
            Button(tr("Stop")) { viewModel.requestAction(.stopContainer(container)) }
            Button(tr("Restart")) { viewModel.requestAction(.restartContainer(container)) }
            Button(tr("Kill")) { viewModel.requestAction(.killContainer(container)) }
            Button(tr("Pause")) { viewModel.requestAction(.pauseContainer(container)) }
        } else {
            Button(tr("Start")) { viewModel.requestAction(.startContainer(container)) }
        }
        Button(tr("Delete"), role: .destructive) { viewModel.requestAction(.deleteContainer(container)) }
        Divider()
        Button(tr("Logs")) { viewModel.loadContainerLogs(container) }
        Button(tr("Terminal")) { onOpenContainerShell(container) }
            .disabled(!container.isRunning)
        Divider()
        Button(tr("Copy ID")) { copyToPasteboard(container.id) }
        Button(tr("Copy Name")) { copyToPasteboard(container.name) }
        Button(tr("Copy Image")) { copyToPasteboard(container.image) }
    }

    @ViewBuilder
    private func composeContextMenu(_ project: DockerComposeProject) -> some View {
        Button(tr("Start")) { viewModel.requestAction(.composeUp(project)) }
            .disabled(!project.canRunCommands)
        Button(tr("Stop")) { viewModel.requestAction(.composeDown(project)) }
            .disabled(!project.canRunCommands)
        Button(tr("Restart")) { viewModel.requestAction(.composeRestart(project)) }
            .disabled(!project.canRunCommands)
        Button(tr("Pause")) { viewModel.requestAction(.composePause(project)) }
            .disabled(!project.canRunCommands)
        Button(tr("Kill")) { viewModel.requestAction(.composeKill(project)) }
            .disabled(!project.canRunCommands)
        Button(tr("Delete"), role: .destructive) { viewModel.requestAction(.composeDown(project)) }
            .disabled(!project.canRunCommands)
        Divider()
        Button(tr("Logs")) { viewModel.loadComposeLogs(project) }
            .disabled(!project.canRunCommands)
        Divider()
        Button(tr("Copy Name")) { copyToPasteboard(project.name) }
        if let workingDir = project.workingDir {
            Button(tr("Copy Path")) { copyToPasteboard(workingDir) }
        }
    }

    private var runningContainerGroups: [DockerContainerGroup] {
        groupedContainers(viewModel.filteredContainers.filter(\.isRunning))
    }

    private var stoppedContainerGroups: [DockerContainerGroup] {
        groupedContainers(viewModel.filteredContainers.filter { !$0.isRunning })
    }

    private func groupedContainers(_ containers: [DockerContainer]) -> [DockerContainerGroup] {
        let grouped = Dictionary(grouping: containers) { $0.composeProject ?? "" }
        let composeGroups = grouped
            .filter { !$0.key.isEmpty }
            .map { DockerContainerGroup(projectName: $0.key, containers: $0.value.sorted(by: containerSort)) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        let standalone = (grouped[""] ?? []).sorted(by: containerSort)
        if standalone.isEmpty {
            return composeGroups
        }
        return composeGroups + [DockerContainerGroup(projectName: nil, containers: standalone)]
    }

    private func containerSort(_ lhs: DockerContainer, _ rhs: DockerContainer) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func composeSummary(for container: DockerContainer) -> String {
        if let project = container.composeProject, let service = container.composeService {
            return "\(project)/\(service)"
        }
        if let project = container.composeProject {
            return project
        }
        return "—"
    }

    private func aggregateIO(_ keyPath: KeyPath<DockerContainerStats, String>) -> String {
        let values = viewModel.activitySnapshot.stats.map { $0[keyPath: keyPath] }
        return values.isEmpty ? "0 B/s" : values.joined(separator: " + ")
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        viewModel.presentToast(tr("Copied"))
    }

    private var currentTitle: String {
        switch viewModel.selectedTab {
        case .containers: return tr("Containers")
        case .volumes: return tr("Volumes")
        case .images: return tr("Images")
        case .networks: return tr("Networks")
        case .kubernetesPods: return tr("Pods")
        case .kubernetesServices: return tr("Services")
        case .machines: return tr("Machines")
        case .activityMonitor: return tr("Activity Monitor")
        case .commands: return tr("Commands")
        }
    }

    private var currentSubtitle: String {
        switch viewModel.selectedTab {
        case .containers:
            return String(format: tr("%d running"), viewModel.containers.filter(\.isRunning).count)
        case .volumes:
            return String(format: tr("%d total"), viewModel.volumes.count)
        case .images:
            return String(format: tr("%d total"), viewModel.images.count)
        case .networks:
            return String(format: tr("%d total"), viewModel.networks.count)
        case .kubernetesPods, .kubernetesServices:
            return tr("Kubernetes features are in development")
        case .machines, .commands:
            return tr("Unavailable")
        case .activityMonitor:
            return String(format: tr("%d running"), viewModel.containers.filter(\.isRunning).count)
        }
    }

    private var currentSystemImage: String {
        switch viewModel.selectedTab {
        case .containers: return "shippingbox"
        case .volumes: return "externaldrive"
        case .images: return "doc.on.clipboard"
        case .networks: return "network"
        case .kubernetesPods: return "atom"
        case .kubernetesServices: return "globe"
        case .machines: return "desktopcomputer"
        case .activityMonitor: return "chart.xyaxis.line"
        case .commands: return "terminal"
        }
    }

    private var hostTitle: String {
        if let name = viewModel.runtimeBinding.host?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return viewModel.runtimeBinding.host?.address ?? tr("Docker")
    }

    private func toastView(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule(style: .continuous).fill(Color.black.opacity(0.8)))
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

private enum DockerInspectorSelection: Hashable {
    case container(String)
    case compose(String)
    case volume(String)
    case image(String)
    case network(String)
    case monitor
}

private struct DockerContainerGroup: Identifiable {
    let projectName: String?
    let containers: [DockerContainer]

    var id: String {
        projectName ?? "standalone"
    }
}

private struct DockerTableColumn: Identifiable {
    let id = UUID()
    let title: String
    let width: CGFloat?
    let alignment: Alignment
}
