import Library
import SwiftUI

#if !os(tvOS)
    private extension Binding where Value == NavigationPage {
        var optionalSelection: Binding<NavigationPage?> {
            Binding<NavigationPage?>(
                get: { wrappedValue },
                set: { newValue in
                    if let newValue {
                        wrappedValue = newValue
                    }
                }
            )
        }
    }

    @available(iOS 16.0, macOS 13.0, *)
    private struct SidebarContentView: View {
        @Binding var selection: NavigationPage
        @Binding var localSelection: NavigationPage
        @ObservedObject var profile: ExtensionProfile
        @EnvironmentObject private var sendManager: TaildropSendManager
        var environments: ExtensionEnvironments

        var body: some View {
            List(selection: $localSelection.optionalSelection) {
                if profile.status.isConnectedStrict {
                    NavigationPage.dashboard.label.tag(NavigationPage.dashboard)
                    NavigationPage.connections.label.tag(NavigationPage.connections)
                    ForEach(NavigationPage.sidebarDefaultPages, id: \.self) { it in
                        it.label
                            .badge(it == .tools ? environments.toolsBadgeCount + sendManager.failedSessionCount : 0)
                    }
                } else {
                    NavigationPage.dashboard.label.tag(NavigationPage.dashboard)
                    ForEach(NavigationPage.sidebarDefaultPages, id: \.self) { it in
                        it.label
                            .badge(it == .tools ? environments.toolsBadgeCount + sendManager.failedSessionCount : 0)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .onAppear {
                localSelection = selection
            }
            .onChangeCompat(of: selection) { newValue in
                if localSelection != newValue {
                    localSelection = newValue
                }
            }
            .onChangeCompat(of: localSelection) { newValue in
                if selection != newValue {
                    Task { @MainActor in
                        selection = newValue
                    }
                }
            }
            .onChangeCompat(of: profile.status) {
                if !localSelection.visible(profile) {
                    Task { @MainActor in
                        localSelection = .dashboard
                    }
                }
            }
        }
    }

    @available(iOS 16.0, macOS 13.0, *)
    private struct RemoteSidebarContentView: View {
        @Binding var selection: NavigationPage
        @Binding var localSelection: NavigationPage
        @ObservedObject var environments: ExtensionEnvironments
        @EnvironmentObject private var sendManager: TaildropSendManager
        @State private var hasGroups = false
        @State private var isConnected = false

        var body: some View {
            List(selection: $localSelection.optionalSelection) {
                NavigationPage.dashboard.label.tag(NavigationPage.dashboard)
                if hasGroups {
                    NavigationPage.groups.label.tag(NavigationPage.groups)
                }
                if isConnected {
                    NavigationPage.connections.label.tag(NavigationPage.connections)
                }
                ForEach(NavigationPage.sidebarDefaultPages, id: \.self) { it in
                    it.label
                        .badge(it == .tools ? environments.toolsBadgeCount + sendManager.failedSessionCount : 0)
                }
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .onAppear {
                localSelection = selection
                hasGroups = environments.commandClient.groups?.isEmpty == false
                isConnected = environments.commandClient.isConnected
            }
            .onChangeCompat(of: selection) { newValue in
                if localSelection != newValue {
                    localSelection = newValue
                }
            }
            .onChangeCompat(of: localSelection) { newValue in
                if selection != newValue {
                    Task { @MainActor in
                        selection = newValue
                    }
                }
            }
            .onReceive(environments.commandClient.$groups) { groups in
                hasGroups = groups?.isEmpty == false
                if localSelection == .groups, groups?.isEmpty != false {
                    Task { @MainActor in
                        localSelection = .dashboard
                    }
                }
            }
            .onReceive(environments.commandClient.$isConnected) { newValue in
                isConnected = newValue
                if localSelection == .connections, !newValue {
                    Task { @MainActor in
                        localSelection = .dashboard
                    }
                }
            }
            .onDisappear {
                if localSelection == .groups || localSelection == .connections {
                    Task { @MainActor in
                        localSelection = .dashboard
                    }
                }
            }
        }
    }

    @available(iOS 16.0, macOS 13.0, *)
    public struct SidebarView: View {
        @Binding var selection: NavigationPage
        @EnvironmentObject private var environments: ExtensionEnvironments
        @EnvironmentObject private var sendManager: TaildropSendManager
        @State private var localSelection: NavigationPage = .dashboard
        @State private var alert: AlertState?

        public init(selection: Binding<NavigationPage>) {
            _selection = selection
        }

        public var body: some View {
            VStack(spacing: 0) {
                sidebarTop
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(.regularMaterial)
            .alert($alert)
            .onChangeCompat(of: environments.extensionProfile?.status) { newStatus in
                if newStatus == .disconnected {
                    environments.pendingReconnect = false
                }
            }
        }

        @ViewBuilder
        private var content: some View {
            if environments.remoteServer != nil {
                RemoteSidebarContentView(
                    selection: $selection,
                    localSelection: $localSelection,
                    environments: environments
                )
            } else if environments.extensionProfileLoading {
                ProgressView()
            } else if let profile = environments.extensionProfile {
                SidebarContentView(
                    selection: $selection,
                    localSelection: $localSelection,
                    profile: profile,
                    environments: environments
                )
            } else {
                disconnectedContent
            }
        }

        @ViewBuilder
        private var sidebarTop: some View {
            VStack(spacing: 0) {
                sidebarHeader
                if showsReconnectBanner {
                    reconnectBanner
                }
            }
        }

        @ViewBuilder
        private var sidebarHeader: some View {
            #if os(macOS)
                if environments.remoteServer == nil, let profile = environments.extensionProfile {
                    SidebarConnectButton()
                        .environmentObject(profile)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
            #endif
        }

        private var showsReconnectBanner: Bool {
            environments.remoteServer == nil &&
                environments.pendingReconnect &&
                environments.extensionProfile?.status.isConnected == true
        }

        private var reconnectBanner: some View {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                    Text("配置已更改，需重连后生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("立即重连") {
                    reconnectNow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassBanner()
        }

        private func reconnectNow() {
            guard let profile = environments.extensionProfile else {
                return
            }
            Task {
                do {
                    try await profile.restart()
                    environments.pendingReconnect = false
                } catch {
                    alert = AlertState(action: "restart service", error: error)
                }
            }
        }

        private var disconnectedContent: some View {
            List(selection: $localSelection.optionalSelection) {
                NavigationPage.dashboard.label.tag(NavigationPage.dashboard)
                ForEach(NavigationPage.sidebarDefaultPages, id: \.self) { it in
                    it.label
                        .badge(it == .tools ? environments.toolsBadgeCount + sendManager.failedSessionCount : 0)
                }
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .onAppear {
                localSelection = selection
            }
            .onChangeCompat(of: selection) { newValue in
                if localSelection != newValue {
                    localSelection = newValue
                }
            }
            .onChangeCompat(of: localSelection) { newValue in
                if selection != newValue {
                    Task { @MainActor in
                        selection = newValue
                    }
                }
            }
        }
    }

    #if os(macOS)
        @MainActor
        private struct SidebarConnectButton: View {
            @EnvironmentObject private var environments: ExtensionEnvironments
            @EnvironmentObject private var profile: ExtensionProfile
            @State private var alert: AlertState?
            @State private var isBusy = false

            private var connected: Bool { profile.status.isConnectedStrict }
            private var connecting: Bool {
                !connected && (profile.status == .connecting || profile.status == .reasserting || isBusy)
            }

            var body: some View {
                VStack(spacing: 10) {
                    Button {
                        Task { await toggle() }
                    } label: {
                        Image(systemName: iconName)
                            .font(.system(size: 30, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(tint)
                            .frame(width: 76, height: 76)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassCircle(tint: tint)
                    .disabled(!profile.status.isEnabled || isBusy)
                    .alert($alert)

                    VStack(spacing: 3) {
                        Text(title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                        reminder
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .animation(.easeInOut(duration: 0.2), value: connected)
            }

            @ViewBuilder
            private var reminder: some View {
                if connected {
                    HStack(spacing: 4) {
                        Text("已运行")
                        RuntimeDurationText(profile: profile)
                    }
                } else if connecting {
                    Text("正在建立连接…")
                } else {
                    Text("点击开始连接")
                }
            }

            private var title: String {
                if connected { return "已连接" }
                if connecting { return "正在连接" }
                return "未连接"
            }

            private var iconName: String {
                if connected { return "stop.fill" }
                if connecting { return "ellipsis" }
                return "play.fill"
            }

            private var tint: Color {
                if connected { return .green }
                if connecting { return .orange }
                return .accentColor
            }

            private func toggle() async {
                do {
                    if connected {
                        try await profile.stop()
                    } else {
                        isBusy = true
                        try await profile.start()
                        environments.commandClient.connect()
                    }
                } catch {
                    let action = connected ? "stop service" : "start service"
                    alert = AlertState(action: action, error: error)
                }
                isBusy = false
            }
        }
    #endif
#endif

#if !os(tvOS)
    private struct GlassCircleModifier: ViewModifier {
        let tint: Color

        func body(content: Content) -> some View {
            if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
                content.glassEffect(.regular.tint(tint.opacity(0.20)).interactive(), in: .circle)
            } else {
                content
                    .background(Circle().fill(tint.opacity(0.12)))
                    .overlay(Circle().strokeBorder(tint.opacity(0.30), lineWidth: 1))
            }
        }
    }

    private struct GlassBannerModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
                content.glassEffect(.regular.tint(.yellow.opacity(0.22)), in: .rect(cornerRadius: 10))
            } else {
                content
                    .background(RoundedRectangle(cornerRadius: 10).fill(.yellow.opacity(0.18)))
            }
        }
    }

    private extension View {
        func glassCircle(tint: Color) -> some View {
            modifier(GlassCircleModifier(tint: tint))
        }

        func glassBanner() -> some View {
            modifier(GlassBannerModifier())
        }
    }
#endif
