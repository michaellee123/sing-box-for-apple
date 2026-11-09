import Library
import SwiftUI

@MainActor
enum TunnelPolicyReloader {
    static func reloadIfConnected(_ environments: ExtensionEnvironments) async {
        guard let profile = environments.extensionProfile, profile.status.isConnected else { return }
        environments.pendingReconnect = true
    }
}

@MainActor
public struct AdvancedRouteView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var policy = AdvancedRoutePolicy.empty
    @State private var profileModes: [String] = []
    @State private var liveModes: [String] = []
    @State private var selectedMode = ""
    @State private var isLoading = true
    @State private var alert: AlertState?
    @State private var pendingImport: AdvancedRoutePolicy?
    @StateObject private var transfer = PolicyTransferModel<AdvancedRoutePolicy>(name: "高级路由")

    public init() {}

    public var body: some View {
        Group {
            if isLoading {
                FormView {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在读取路由规则…")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 12)
                    }
                }
            } else if environments.remoteServer != nil {
                FormView {
                    Section {
                        Text("高级路由只作用于本机隧道。当前正在查看远程设备，返回本机后再修改。")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                form
            }
        }
        .navigationTitle("高级路由")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if environments.remoteServer == nil {
                    PolicyTransferButtons(transfer, current: { policy })
                }
                HelpButton(Self.helpTopics)
            }
        }
        .policyTransferPanels(transfer)
        .onAppear {
            transfer.onImport = { pendingImport = $0 }
            transfer.onError = { alert = AlertState(errorMessage: $0) }
        }
        .alert($alert)
        .alert(
            "导入高级路由",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            ),
            presenting: pendingImport
        ) { imported in
            Button("替换", role: .destructive) {
                policy = imported
                commit()
            }
            Button("取消", role: .cancel) {
                pendingImport = nil
            }
        } message: { _ in
            Text("将用文件里的规则替换当前全部高级路由规则，无法撤销。")
        }
        .task {
            policy = await AdvancedRouteStore.current()
            await loadClashModes()
            isLoading = false
        }
        .onReceive(environments.commandClient.$clashModeList) { modes in
            liveModes = modes
        }
        .onChangeCompat(of: selectedMode) { newValue in
            Task { await commitMode(newValue) }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var form: some View {
        FormView {
            Section {
                ForEach(displayModes, id: \.self) { mode in
                    Button {
                        selectedMode = mode
                    } label: {
                        HStack {
                            Text(mode)
                                .foregroundStyle(.primary)
                            Spacer()
                            if mode == selectedMode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("模式")
            }

            PatternSection(
                title: "按域名强制接管",
                values: $policy.domainTakeover,
                normalize: { RoutePatternParser.normalizeDomain($0) },
                onCommit: commit
            )
            PatternSection(
                title: "按域名强制放行",
                values: $policy.domainBypass,
                normalize: { RoutePatternParser.normalizeDomain($0) },
                onCommit: commit
            )
            PatternSection(
                title: "按 IP 段强制放行",
                values: $policy.ipBypass,
                placeholder: "添加 IP 或 IP 段，例如 192.168.1.0/24",
                normalize: { RoutePatternParser.normalizeIPCIDR($0) },
                onInvalid: { items in
                    alert = AlertState(errorMessage: "不是有效的 IP 或 IP 段：\(items.joined(separator: "、"))")
                },
                onCommit: commit
            )
            #if os(macOS)
                PatternSection(
                    title: "按应用强制接管",
                    values: $policy.appTakeover,
                    placeholder: "手工添加进程名",
                    offersRunningApps: true,
                    onCommit: commit
                )
                PatternSection(
                    title: "按应用强制放行",
                    values: $policy.appBypass,
                    placeholder: "手工添加进程名",
                    offersRunningApps: true,
                    onCommit: commit
                )
            #endif
        }
    }

    private static let excludedModes = ["全球直连"]

    private var displayModes: [String] {
        var modes = [ProfileConfigPatcher.preferredClashMode, ProfileConfigPatcher.whitelistClashMode]
        for mode in profileModes + liveModes {
            let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !modes.contains(trimmed), !Self.excludedModes.contains(trimmed) else { continue }
            modes.append(trimmed)
        }
        if !selectedMode.isEmpty, !modes.contains(selectedMode), !Self.excludedModes.contains(selectedMode) {
            modes.append(selectedMode)
        }
        return modes
    }

    private func loadClashModes() async {
        let profileID = await SharedPreferences.selectedProfileID.get()
        let config = (try? await ProfileManager.get(profileID)?.readAsync()) ?? ""
        profileModes = ProfileConfigPatcher.clashModes(in: config)
        let stored = await SharedPreferences.clashMode.get()
        var resolved = ProfileConfigPatcher.resolveClashMode(stored, modes: displayModes)
        if Self.excludedModes.contains(resolved) {
            resolved = ProfileConfigPatcher.preferredClashMode
        }
        if selectedMode != resolved {
            selectedMode = resolved
        }
    }

    private func commitMode(_ mode: String) async {
        guard !mode.isEmpty else { return }
        if await SharedPreferences.clashMode.get() != mode {
            await SharedPreferences.clashMode.set(mode)
        }
        guard environments.remoteServer == nil,
              environments.commandClient.isConnected,
              environments.commandClient.clashMode != mode
        else { return }
        do {
            try CommandTarget.standaloneClient().setClashMode(mode)
        } catch {
            alert = AlertState(action: "set clash mode", error: error)
        }
    }

    private func commit() {
        let snapshot = policy
        Task {
            await AdvancedRouteStore.save(snapshot)
            await TunnelPolicyReloader.reloadIfConnected(environments)
        }
    }

    private static let helpTopics: [HelpTopic] = [
        HelpTopic("优先级", "强制放行最高，其次是强制接管，然后是模式（智能首选、全局代理或白名单），最后由智能分组分流。规则改动保存后，重新连接才会生效。"),
        HelpTopic("模式", "默认是智能首选。白名单只代理上方强制接管的应用和域名，其余流量全部直连。点选整行即可切换，下次连接也继续用。"),
        HelpTopic("按域名强制接管", "这些域名一定走代理。可以直接粘贴网址，会自动识别域名。默认按后缀匹配，example.com 包含所有子域名。full: 只匹配完整域名，keyword: 关键字，regex: 正则。"),
        HelpTopic("按域名强制放行", "这些域名一定直连，优先级高于模式和智能分组。可以直接粘贴网址，会自动识别域名。"),
        HelpTopic("按 IP 段强制放行", "填写 IP 或 CIDR，例如 192.168.1.0/24、10.0.0.0/8、2001:db8::/32。不写掩码时按单个地址处理（IPv4 /32，IPv6 /128）。命中后一定直连，优先级最高。"),
        HelpTopic("按应用强制接管", "从正在运行的应用里选择。选中后，这个应用和它的辅助进程都会走代理。也可以手工填写进程名。"),
        HelpTopic("按应用强制放行", "这些应用一定直连，优先级高于模式和智能分组。"),
        HelpTopic("导出与导入", "导出把全部高级路由规则存成 JSON。导入会替换当前规则，替换前会再确认一次。"),
    ]
}

private struct PatternSection: View {
    let title: String
    @Binding var values: [String]
    var placeholder = "添加，多个用逗号或换行分隔"
    var offersRunningApps = false
    var normalize: (String) -> String? = { $0 }
    var onInvalid: (([String]) -> Void)?
    let onCommit: () -> Void
    @State private var draft = ""
    @State private var showsRunningApps = false

    var body: some View {
        Section {
            if values.isEmpty {
                Text("还没有规则")
                    .foregroundStyle(.secondary)
            } else if offersRunningApps {
                #if os(macOS)
                    ProcessIconGrid(patterns: values) { pattern in
                        values.removeAll { $0 == pattern }
                        onCommit()
                    }
                #endif
            } else {
                ForEach(values, id: \.self) { value in
                    HStack {
                        Text(value)
                            .lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            values.removeAll { $0 == value }
                            onCommit()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("删除这条规则")
                    }
                }
            }
            HStack(spacing: 8) {
                TextField(placeholder, text: $draft)
                    .visibleTextField()
                    .onSubmit {
                        add(draft)
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Button("添加") {
                    add(draft)
                }
                .disabled(RoutePatternParser.split(draft).isEmpty)
            }
            #if os(macOS)
                if offersRunningApps {
                    Button {
                        showsRunningApps = true
                    } label: {
                        Label("从正在运行的应用添加", systemImage: "macwindow")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .sheet(isPresented: $showsRunningApps) {
                        NavigationSheet(title: "正在运行的应用", showsCloseButton: true) {
                            RunningAppPicker(values: $values, onCommit: onCommit)
                        }
                    }
                }
            #endif
        } header: {
            Text(title)
        }
    }

    private func add(_ text: String) {
        let items = RoutePatternParser.split(text)
        guard !items.isEmpty else { return }
        var invalid: [String] = []
        var added = false
        for item in items {
            guard let value = normalize(item), !value.isEmpty else {
                invalid.append(item)
                continue
            }
            if !values.contains(value) {
                values.append(value)
                added = true
            }
        }
        if added {
            onCommit()
        }
        if invalid.isEmpty {
            draft = ""
        } else {
            draft = invalid.joined(separator: ", ")
            onInvalid?(invalid)
        }
    }
}

