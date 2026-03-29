import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import RemoraCore

@MainActor
struct ContentView: View {
    enum SidebarFocusedField: Hashable {
        case hostSearch
    }

    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) var openURL
    @StateObject var workspace = WorkspaceViewModel()
    @StateObject var hostCatalog = HostCatalogStore()
    @StateObject var fileTransfer = FileTransferViewModel()
    @StateObject var directorySyncBridge = TerminalDirectorySyncBridge()
    @StateObject var serverMetricsCenter = ServerMetricsCenter()
    @StateObject var serverStatusWindowManager = ServerStatusWindowManager()

    @State var hostSearchQuery = ""
    @FocusState var sidebarFocusedField: SidebarFocusedField?
    @State var hasClearedInitialSidebarSearchFocus = false
    @State var selectedHostID: UUID?
    @State var selectedTemplateID: UUID?
    @State var splitVisibility: NavigationSplitViewVisibility = .all
    @State var bottomPanelVisibility = BottomPanelVisibilityState(terminal: true, fileManager: false)
    @State var collapsedGroupNames: Set<String> = []
    @State var isGroupEditorSheetPresented = false
    @State var groupEditorMode: SidebarGroupEditorMode = .create
    @State var groupEditorSourceName = ""
    @State var groupEditorDraft = ""
    @State var isHostEditorSheetPresented = false
    @State var hostEditorMode: SidebarHostEditorMode = .create
    @State var hostEditorDraft = SidebarHostEditorDraft()
    @State var hostEditorTestState: HostConnectionTestState = .idle
    @State var isExportSheetPresented = false
    @State var exportDraft = HostExportDraft()
    @State var isPasswordExportWarningPresented = false
    @State var isConnectionInfoPasswordWarningPresented = false
    @State var pendingConnectionInfoPasswordCopyHost: RemoraCore.Host?
    @State var pendingHostDeletion: PendingHostDeletion?
    @State var pendingGroupDeletion: PendingGroupDeletion?
    @State var isExportingHosts = false
    @State var isImportingHosts = false
    @State var isImportSourceSheetPresented = false
    @State var isExportResultAlertPresented = false
    @State var exportAlertTitle = ""
    @State var exportAlertMessage = ""
    @State var isImportProgressSheetPresented = false
    @State var importSource = HostConnectionImportSource.remoraJSONCSV
    @State var importSourceFilename = ""
    @State var importProgress = HostConnectionImportProgress(phase: tr("Preparing"), completed: 0, total: 1)
    @State var importResultMessage: String?
    @State var importErrorMessage: String?
    @State var isRenameSessionSheetPresented = false
    @State var renameSessionID: UUID?
    @State var renameSessionDraft = ""
    @State var quickCommandEditorHostID: UUID?
    @State var quickCommandEditingID: UUID?
    @State var quickCommandNameDraft = ""
    @State var quickCommandBodyDraft = ""
    @State var quickCommandValidationMessage: String?
    @State var quickPathEditorHostID: UUID?
    @State var quickPathEditingID: UUID?
    @State var quickPathNameDraft = ""
    @State var quickPathValueDraft = ""
    @State var quickPathValidationMessage: String?
    @State var fileManagerSFTPBindingKey = "disconnected"
    @State var fileManagerSFTPBootstrapTask: Task<Void, Never>?
    @State var hoveredSessionMetricsTooltip: HoveredSessionMetricsTooltip?
    @State var hoveredSessionMetricsTooltipSize: CGSize = .zero
    @RemoraStored(\.connectionInfoPasswordCopyMutedUntilEpoch)
    var connectionInfoPasswordCopyMutedUntilEpoch: Double
    @RemoraStored(\.connectionInfoPasswordCopyMuteForever)
    var connectionInfoPasswordCopyMuteForever: Bool
    @RemoraStored(\.serverMetricsActiveRefreshSeconds)
    var serverMetricsActiveRefreshSeconds: Int
    @RemoraStored(\.serverMetricsInactiveRefreshSeconds)
    var serverMetricsInactiveRefreshSeconds: Int
    @RemoraStored(\.serverMetricsMaxConcurrentFetches)
    var serverMetricsMaxConcurrentFetches: Int
    let serverMetricsTrackingTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var selectedHost: RemoraCore.Host? {
        hostCatalog.host(id: selectedHostID)
    }

    var connectionInfoPasswordCopyMutedUntil: Date? {
        guard connectionInfoPasswordCopyMutedUntilEpoch > 0 else { return nil }
        return Date(timeIntervalSince1970: connectionInfoPasswordCopyMutedUntilEpoch)
    }

    var quickCommandEditorHost: RemoraCore.Host? {
        hostCatalog.host(id: quickCommandEditorHostID)
    }

    var quickPathEditorHost: RemoraCore.Host? {
        hostCatalog.host(id: quickPathEditorHostID)
    }

    var quickCommandEditorBinding: Binding<Bool> {
        Binding(
            get: { quickCommandEditorHostID != nil },
            set: { isPresented in
                if !isPresented {
                    dismissQuickCommandEditor()
                }
            }
        )
    }

    var quickPathEditorBinding: Binding<Bool> {
        Binding(
            get: { quickPathEditorHostID != nil },
            set: { isPresented in
                if !isPresented {
                    dismissQuickPathEditor()
                }
            }
        )
    }

    var availableTemplates: [HostSessionTemplate] {
        hostCatalog.templates(for: selectedHostID)
    }

    var selectedTemplate: HostSessionTemplate? {
        guard let selectedTemplateID else { return nil }
        return availableTemplates.first(where: { $0.id == selectedTemplateID })
    }

    var isHostDeletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingHostDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingHostDeletion = nil
                }
            }
        )
    }

    var visibleGroupSections: [HostGroupSection] {
        hostCatalog.groupSections(matching: hostSearchQuery)
    }

    var visibleUngroupedHosts: [RemoraCore.Host] {
        hostCatalog.ungroupedHosts(matching: hostSearchQuery)
    }

    var groupDeletionSheetBinding: Binding<Bool> {
        Binding(
            get: { pendingGroupDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingGroupDeletion = nil
                }
            }
        )
    }

    var activeRuntimeConnectionStatePublisher: AnyPublisher<ActiveRuntimeConnectionState, Never> {
        guard let runtime = workspace.activePane?.runtime else {
            return Just(
                ActiveRuntimeConnectionState(
                    runtimeID: nil,
                    connectionMode: nil,
                    connectionState: "Disconnected",
                    hostSignature: nil
                )
            )
            .eraseToAnyPublisher()
        }

        return Publishers.CombineLatest3(
            runtime.$connectionMode,
            runtime.$connectionState,
            runtime.$connectedSSHHost
        )
        .map { mode, state, host in
            ActiveRuntimeConnectionState(
                runtimeID: ObjectIdentifier(runtime),
                connectionMode: mode,
                connectionState: state,
                hostSignature: host.map(Self.sftpHostSignature(for:))
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    var body: some View {
        let rootContent = ZStack {
            backgroundGradient

            NavigationSplitView(columnVisibility: $splitVisibility) {
                sidebar
            } detail: {
                detailWorkspace
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(minWidth: 1200, minHeight: 760)

        let lifecycleContent = rootContent
            .onAppear {
                if selectedHostID == nil {
                    selectedHostID = hostCatalog.hosts.first?.id
                }
                if !hasClearedInitialSidebarSearchFocus {
                    hasClearedInitialSidebarSearchFocus = true
                    sidebarFocusedField = nil
                    DispatchQueue.main.async {
                        sidebarFocusedField = nil
                    }
                }
                if let firstPane = workspace.activePane {
                    firstPane.runtime.connectLocalShell()
                }
                syncServerMetricsConfiguration()
                RuntimeConnectionSyncCoordinator.bindRuntimeDrivenServices(
                    fileTransfer: fileTransfer,
                    directorySyncBridge: directorySyncBridge,
                    activeRuntime: workspace.activePane?.runtime,
                    syncFileManagerBinding: syncFileManagerSFTPBinding,
                    syncServerMetricsTracking: syncServerMetricsTracking
                )
            }
            .onChange(of: selectedHostID) {
                selectedTemplateID = availableTemplates.first?.id
            }
            .onChange(of: workspace.activeTabID) {
                RuntimeConnectionSyncCoordinator.attachActiveRuntime(
                    workspace.activePane?.runtime,
                    directorySyncBridge: directorySyncBridge,
                    syncFileManagerBinding: syncFileManagerSFTPBinding,
                    syncServerMetricsTracking: syncServerMetricsTracking
                )
            }
            .onChange(of: workspace.activePaneByTab) {
                RuntimeConnectionSyncCoordinator.attachActiveRuntime(
                    workspace.activePane?.runtime,
                    directorySyncBridge: directorySyncBridge,
                    syncFileManagerBinding: syncFileManagerSFTPBinding,
                    syncServerMetricsTracking: syncServerMetricsTracking
                )
            }

        let commandContent = lifecycleContent
            .onReceive(NotificationCenter.default.publisher(for: .remoraOpenSettingsCommand)) { _ in
                openWindow(id: "settings")
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoraToggleSidebarCommand)) { _ in
                toggleSSHSidebarVisibility()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoraNewSSHConnectionCommand)) { _ in
                beginCreateHostInPreferredGroup()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoraImportConnectionsCommand)) { _ in
                guard !isExportingHosts, !isImportingHosts, !hostCatalog.isLoading else { return }
                beginImportHosts()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoraExportConnectionsCommand)) { _ in
                guard !isExportingHosts, !isImportingHosts, !hostCatalog.isLoading else { return }
                beginExportAllHosts()
            }

        let syncedContent = commandContent
            .onReceive(activeRuntimeConnectionStatePublisher) { _ in
                RuntimeConnectionSyncCoordinator.syncRuntimeDrivenServices(
                    syncFileManagerBinding: syncFileManagerSFTPBinding,
                    syncServerMetricsTracking: syncServerMetricsTracking
                )
            }
            .onReceive(serverMetricsTrackingTimer) { _ in
                RuntimeConnectionSyncCoordinator.syncMetricsTracking(syncServerMetricsTracking)
            }
            .onChange(of: hostCatalog.hosts) {
                if let selectedHostID, hostCatalog.host(id: selectedHostID) != nil {
                    return
                }
                selectedHostID = hostCatalog.hosts.first?.id
                selectedTemplateID = availableTemplates.first?.id
            }
            .onChange(of: hostCatalog.groups) {
                collapsedGroupNames = collapsedGroupNames.intersection(Set(hostCatalog.groups))
            }
            .onChange(of: serverMetricsActiveRefreshSeconds) {
                syncServerMetricsConfiguration()
            }
            .onChange(of: serverMetricsInactiveRefreshSeconds) {
                syncServerMetricsConfiguration()
            }
            .onChange(of: serverMetricsMaxConcurrentFetches) {
                syncServerMetricsConfiguration()
            }

        return syncedContent
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: workspace.activeTabID)
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: bottomPanelVisibility)
            .task {
                await UpdateChecker.shared.performAutomaticCheckIfNeeded()
            }
    }


}
