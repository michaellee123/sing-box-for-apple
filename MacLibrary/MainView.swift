import AppKit
import ApplicationLibrary
import Foundation
import Library
import SwiftUI

private extension View {
    @ViewBuilder
    func hideSidebarToggle() -> some View {
        if #available(macOS 14.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

@MainActor
public struct MainView: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var viewModel: MainViewModel
    @State private var showCardManagement = false
    @State private var cardConfigurationVersion = 0
    @State private var remoteServers: [RemoteServer] = []
    @State private var settingsNavigationPath = NavigationPath()
    @State private var pendingSettingsPage: SettingsPage?
    @State private var didConfigureScreenshotWindow = false
    @State private var pendingScreenshotSelection: NavigationPage?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private let profileEditor: (Binding<String>, Bool) -> AnyView = { text, isEditable in
        AnyView(ProfileEditorWrapperView(text: text, isEditable: isEditable))
    }

    private let ghosttyConfigEditor: (Binding<String>) -> AnyView = { text in
        AnyView(GhosttyConfigEditorWrapperView(text: text))
    }

    private let screenshotDefaultPixelHeight: CGFloat = 1000

    public init() {
        let initialSelection: NavigationPage = .dashboard
        if Variant.screenshotMode,
           let pageValue = ProcessInfo.processInfo.environment["SCREENSHOT_PAGE"],
           let page = NavigationPage(snapshotValue: pageValue)
        {
            _pendingScreenshotSelection = State(initialValue: page)
        } else {
            _pendingScreenshotSelection = State(initialValue: nil)
        }
        _viewModel = StateObject(wrappedValue: MainViewModel(selection: initialSelection))
    }

    private func hideSidebarToggleItem(in window: NSWindow?) {
        guard let toolbar = window?.toolbar else { return }
        for index in stride(from: toolbar.items.count - 1, through: 0, by: -1)
            where toolbar.items[index].itemIdentifier.rawValue.lowercased().contains("sidebar") {
            toolbar.removeItem(at: index)
        }
    }

    private func normalizeSidebarWidth(in window: NSWindow?) {
        guard let contentView = window?.contentView else { return }
        for splitView in findSplitViews(in: contentView) {
            guard let controller = splitView.delegate as? NSSplitViewController,
                  let sidebarItem = controller.splitViewItems.first,
                  sidebarItem.viewController.view.frame.width < 200 else { continue }
            // Restored NSSplitViewItem thickness limits can override navigationSplitViewColumnWidth.
            splitView.autosaveName = nil
            sidebarItem.maximumThickness = 280
            sidebarItem.minimumThickness = 200
            splitView.setPosition(200, ofDividerAt: 0)
        }
    }

    private func findSplitViews(in view: NSView) -> [NSSplitView] {
        let current = (view as? NSSplitView).map { [$0] } ?? []
        return current + view.subviews.flatMap(findSplitViews)
    }

    private func screenshotTargetHeight(baseHeight _: CGFloat, window: NSWindow) -> CGFloat {
        let scale = max(window.backingScaleFactor, 1)
        if let pixelOverride = ProcessInfo.processInfo.environment["SCREENSHOT_WINDOW_PIXEL_HEIGHT"] {
            let trimmed = pixelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if let height = Double(trimmed), height > 0 {
                return CGFloat(height) / scale
            }
        }
        if let override = ProcessInfo.processInfo.environment["SCREENSHOT_WINDOW_HEIGHT"] {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if let height = Double(trimmed), height > 0 {
                return CGFloat(height)
            }
        }
        return screenshotDefaultPixelHeight / scale
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $viewModel.selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                .hideSidebarToggle()
        } detail: {
            NavigationStack(path: $settingsNavigationPath) {
                viewModel.selection.contentView
                    .navigationTitle(viewModel.selection.title)
            }
            .background(.regularMaterial)
            .environment(\.cardConfigurationVersion, cardConfigurationVersion)
            .environment(\.settingsNavigationPath, $settingsNavigationPath)
            .navigationSplitViewColumnWidth(650)
        }
        .hideSidebarToggle()
        .frame(
            minWidth: Variant.screenshotMode ? 0 : 850,
            maxWidth: .infinity,
            minHeight: Variant.screenshotMode ? 0 : 500,
            maxHeight: .infinity
        )
        .onChangeCompat(of: columnVisibility) { newValue in
            if newValue != .all {
                columnVisibility = .all
            }
        }
        .background(WindowAccessor { window in
            window?.isOpaque = false
            window?.backgroundColor = .clear
            Task { @MainActor in
                normalizeSidebarWidth(in: window)
                hideSidebarToggleItem(in: window)
                try? await Task.sleep(nanoseconds: 300_000_000)
                normalizeSidebarWidth(in: window)
                hideSidebarToggleItem(in: window)
            }
            guard Variant.screenshotMode, !didConfigureScreenshotWindow, let window else { return }
            didConfigureScreenshotWindow = true
            DispatchQueue.main.async {
                window.hasShadow = true
                let baseSize = window.contentLayoutRect.size
                let targetHeight = screenshotTargetHeight(baseHeight: baseSize.height, window: window)
                let targetSize = NSSize(width: baseSize.width, height: targetHeight)
                guard targetSize.width > 0, targetSize.height > 0 else { return }
                window.contentMinSize = targetSize
                window.contentMaxSize = targetSize
                window.minSize = targetSize
                window.maxSize = targetSize
                window.setContentSize(targetSize)
                if let pending = pendingScreenshotSelection, pending != viewModel.selection {
                    viewModel.selection = pending
                    pendingScreenshotSelection = nil
                }
            }
        })
        .onAppear {
            viewModel.onAppear(environments: environments)
            Task { await reloadRemoteServers() }
        }
        .alert($viewModel.alert)
        .globalChecks()
        .toolbar {
            if environments.remoteServer != nil || !remoteServers.isEmpty {
                ToolbarItem(placement: .navigation) {
                    remoteControlPicker
                }
            }
            if environments.remoteServer != nil {
                ToolbarItem(placement: .navigation) {
                    disconnectButton
                }
            }
            if viewModel.selection == .dashboard {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showCardManagement = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .toolbarIconStyle()
                    .help("管理仪表卡片")
                }
            }
        }
        .onChangeCompat(of: controlActiveState) { newValue in
            Task { @MainActor in
                viewModel.onControlActiveStateChange(newValue, environments: environments)
            }
        }
        .onChangeCompat(of: viewModel.selection) { value in
            Task { @MainActor in
                viewModel.onSelectionChange(value, environments: environments)
                if value != .settings {
                    settingsNavigationPath = NavigationPath()
                    pendingSettingsPage = nil
                    return
                }
                if let page = pendingSettingsPage {
                    settingsNavigationPath = NavigationPath()
                    settingsNavigationPath.append(page)
                    pendingSettingsPage = nil
                }
            }
        }
        .onReceive(environments.openSettings) {
            Task { @MainActor in viewModel.openSettings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSettingsPage)) { notification in
            guard let page = notification.object as? SettingsPage else { return }
            Task { @MainActor in
                pendingSettingsPage = page
                if viewModel.selection == .settings {
                    settingsNavigationPath = NavigationPath()
                    settingsNavigationPath.append(page)
                    pendingSettingsPage = nil
                } else {
                    viewModel.selection = .settings
                }
            }
        }
        .environment(\.selection, $viewModel.selection)
        .environment(\.importProfile, $viewModel.importProfile)
        .environment(\.importRemoteProfile, $viewModel.importRemoteProfile)
        .environment(\.profileEditor, profileEditor)
        .environment(\.ghosttyConfigEditor, ghosttyConfigEditor)
        .handlesExternalEvents(preferring: [], allowing: ["*"])
        .onOpenURL { url in
            viewModel.openURL(url, environments: environments)
        }
        .sheet(isPresented: $showCardManagement, onDismiss: {
            cardConfigurationVersion += 1
        }, content: {
            CardManagementSheet()
                .frame(minWidth: 400, minHeight: 400)
        })
        .onReceive(NotificationCenter.default.publisher(for: .remoteServersUpdated)) { _ in
            Task { @MainActor in
                await reloadRemoteServers()
            }
        }
    }

    private var remoteControlPicker: some View {
        // macOS 27 hides Text-only toolbar menu labels in apps linked against older SDKs
        Menu {
            RemoteControlMenuItems(servers: remoteServers)
                .labelStyle(.automatic)
        } label: {
            Text(environments.remoteServer?.displayName ?? String(localized: "Local Device"))
        }
        .labelStyle(.titleOnly)
    }

    private var disconnectButton: some View {
        Button {
            environments.exitRemoteControl()
        } label: {
            HStack(spacing: 8) {
                RemoteUptimeText(commandClient: environments.commandClient)
                Label("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash")
            }
        }
        .labelStyle(.iconOnly)
    }

    private func reloadRemoteServers() async {
        remoteServers = await (try? RemoteServerManager.list()) ?? []
    }
}
