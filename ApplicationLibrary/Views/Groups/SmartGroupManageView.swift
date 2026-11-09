import Library
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct SmartGroupManageView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    private let requestedProfileID: Int64?
    private let requestedProfileName: String?

    @State private var profileID: Int64?
    @State private var profileName = ""
    @State private var policy = ProfileSmartPolicy(profileID: -1)
    @State private var nodes: [String] = []
    @State private var resolved: [ProfileConfigPatcher.ResolvedSmartGroup] = []
    @State private var runtimeGroups: [OutboundGroup] = []
    @State private var isLoading = true
    @State private var alert: AlertState?
    @State private var editor: SmartGroupDraft?
    @State private var trafficEditor: TrafficDraft?
    @State private var showLiveGroups = false
    @State private var nodeQuery = ""
    @State private var expandedGroups: Set<String> = []
    @State private var pendingDelete: SmartGroup?
    @State private var pendingImport: ProfileSmartPolicy?
    @State private var isTesting = false
    @State private var draggingGroupID: String?
    @State private var dropTargetID: String?
    @StateObject private var transfer = PolicyTransferModel<ProfileSmartPolicy>(name: "智能分组")

    public init(profileID: Int64? = nil, profileName: String? = nil) {
        requestedProfileID = profileID
        requestedProfileName = profileName
    }

    public var body: some View {
        Group {
            if isLoading {
                FormView {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在读取配置和分组…")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 12)
                    }
                }
            } else if profileID == nil {
                FormView {
                    Section {
                        Text("先在仪表里选择一个配置，再管理它下面的智能分组。")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                form
            }
        }
        .navigationTitle(profileName.isEmpty ? "智能分组" : "\(profileName) 的分组")
        .policyTransferPanels(transfer)
        .alert($alert)
        .alert(
            "删除分组",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { group in
            Button("删除", role: .destructive) {
                deleteGroup(group.id)
            }
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
        } message: { group in
            Text("「\(group.name)」以及指向它的域名、应用规则会一起删除，无法撤销。")
        }
        .alert(
            "导入智能分组",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            ),
            presenting: pendingImport
        ) { imported in
            Button("替换", role: .destructive) {
                applyImport(imported)
            }
            Button("取消", role: .cancel) {
                pendingImport = nil
            }
        } message: { imported in
            Text("将用文件里的 \(imported.groups.count) 个分组替换「\(profileName)」当前的全部分组和域名、应用规则。")
        }
        .task {
            transfer.onImport = { pendingImport = $0 }
            transfer.onError = { alert = AlertState(errorMessage: $0) }
            await reload()
        }
        .onReceive(environments.commandClient.$groups) { groups in
            runtimeGroups = groups ?? []
        }
        .sheet(item: $editor) { draft in
            NavigationSheet(title: draft.isNew ? "新建分组" : "编辑分组") {
                SmartGroupEditor(
                    draft: draft.group,
                    nodes: nodes,
                    delays: nodeDelays,
                    groups: groupsReplacing(draft.group),
                    onDelete: draft.isNew ? nil : {
                        deleteGroup(draft.group.id)
                    }
                ) { updated in
                    saveGroup(updated, isNew: draft.isNew)
                }
            }
        }
        .sheet(item: $trafficEditor) { draft in
            NavigationSheet(title: draft.kind == .domain ? "指定域名" : "指定应用") {
                TrafficRuleEditor(draft: draft, groups: policy.groups) { rule in
                    saveTraffic(rule, kind: draft.kind, isNew: draft.isNew)
                }
            }
        }
        #if !os(tvOS)
        .sheet(isPresented: $showLiveGroups) {
            NavigationSheet(title: "节点延迟") {
                GroupListView()
                    .environmentObject(environments)
            }
        }
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var form: some View {
        FormView {
            Section {
                HStack(spacing: 8) {
                    Text("\(policy.groups.count) 个分组 · \(nodes.count) 个节点")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    PolicyTransferButtons(transfer, current: { policy })
                    HelpButton(Self.helpTopics)
                }
            }

            Section {
                if policy.groups.isEmpty {
                    Text("还没有智能分组")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(policy.groups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            groupRow(group)
                            if expandedGroups.contains(group.id) {
                                groupDetail(group)
                            }
                        }
                        .overlay(alignment: .top) {
                            if dropTargetID == group.id, draggingGroupID != group.id {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                            }
                        }
                        .onDrop(of: [.text], isTargeted: dropTargetBinding(group.id)) { _ in
                            moveGroup(draggingGroupID, before: group.id)
                            return true
                        }
                    }
                }
                Button {
                    editor = SmartGroupDraft(
                        group: SmartGroup(name: "新分组", isDefault: policy.groups.isEmpty),
                        isNew: true
                    )
                } label: {
                    Label("添加分组", systemImage: "plus")
                }
            } header: {
                Text("智能分组")
            } footer: {
                Text("拖动左侧把手调整顺序，点整行展开节点。一个节点只进入第一个命中的分组。")
            }

            Section {
                if policy.domainRoutes.isEmpty {
                    Text("未指定")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(policy.domainRoutes) { rule in
                        trafficRow(rule, showsIcons: false) {
                            trafficEditor = TrafficDraft(rule: rule, kind: .domain, isNew: false)
                        } onDelete: {
                            policy.domainRoutes.removeAll { $0.id == rule.id }
                            persist()
                        }
                    }
                }
                Button {
                    guard let groupID = policy.groups.first?.id else {
                        alert = AlertState(errorMessage: "请先添加智能分组")
                        return
                    }
                    trafficEditor = TrafficDraft(rule: GroupTrafficRule(groupID: groupID), kind: .domain, isNew: true)
                } label: {
                    Label("添加域名规则", systemImage: "plus")
                }
            } header: {
                Text("指定域名使用指定分组")
            } footer: {
                Text("每行一个域名，写法和高级路由相同。优先级低于「强制放行」和「强制接管」，但高于订阅自带的分流规则。")
            }

            #if os(macOS)
                Section {
                    if policy.appRoutes.isEmpty {
                        Text("未指定")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(policy.appRoutes) { rule in
                            trafficRow(rule, showsIcons: true) {
                                trafficEditor = TrafficDraft(rule: rule, kind: .app, isNew: false)
                            } onDelete: {
                                policy.appRoutes.removeAll { $0.id == rule.id }
                                persist()
                            }
                        }
                    }
                    Button {
                        guard let groupID = policy.groups.first?.id else {
                            alert = AlertState(errorMessage: "请先添加智能分组")
                            return
                        }
                        trafficEditor = TrafficDraft(rule: GroupTrafficRule(groupID: groupID), kind: .app, isNew: true)
                    } label: {
                        Label("添加应用规则", systemImage: "plus")
                    }
                } header: {
                    Text("指定应用使用指定分组")
                } footer: {
                    Text("从正在运行的应用里选择。选中后，这个应用和它的辅助进程都会走对应分组。")
                }
            #endif

            nodeListSection

            #if !os(tvOS)
                if !runtimeGroups.isEmpty {
                    Section {
                        Button {
                            showLiveGroups = true
                        } label: {
                            Label("查看节点延迟", systemImage: "bolt.fill")
                        }
                    }
                }
            #endif
        }
    }

    private var nodeListSection: some View {
        Section {
            if nodes.isEmpty {
                Text("这个配置里还没有可分组的代理节点。")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    TextField("筛选节点", text: $nodeQuery)
                        .visibleTextField()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
                    Button {
                        runURLTest()
                    } label: {
                        HStack(spacing: 4) {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "bolt.fill")
                            }
                            Text(isTesting ? "测速中" : "测速")
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(isTesting || runtimeGroups.isEmpty || !environments.commandClient.isConnected)
                    .help("刷新全部节点的延迟")
                }
                ForEach(Array(visibleNodes.enumerated()), id: \.offset) { _, node in
                    HStack {
                        Text(node)
                        #if !os(tvOS)
                            .textSelection(.enabled)
                        #endif
                        Spacer()
                        Text(nodeGroupNames[node] ?? "未分组")
                            .foregroundStyle(.secondary)
                        NodeDelayLabel(delay: nodeDelays[node] ?? 0)
                    }
                }
            }
        } header: {
            Text("全部节点")
        } footer: {
            if nodes.isEmpty {
                Text("节点来自当前配置里的代理出站。")
            } else if nodeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("共 \(nodes.count) 个。延迟在连接后由测速结果更新，未分组的节点不会进入默认路径。")
            } else {
                Text("显示 \(visibleNodes.count) / \(nodes.count) 个。延迟在连接后由测速结果更新，未分组的节点不会进入默认路径。")
            }
        }
    }

    private var nodeDelays: [String: UInt16] {
        NodeDelayIndex.delays(in: runtimeGroups)
    }

    private var visibleNodes: [String] {
        let query = nodeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nodes }
        return nodes.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var nodeGroupNames: [String: String] {
        let claimed = SmartGroupMatching.claimedNodes(nodes: nodes, groups: policy.groups)
        var names: [String: String] = [:]
        for group in policy.groups {
            for node in claimed[group.id] ?? [] {
                names[node] = group.name
            }
        }
        return names
    }

    private func groupRow(_ group: SmartGroup) -> some View {
        let expanded = expandedGroups.contains(group.id)
        let members = members(of: group)
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 26)
                .contentShape(Rectangle())
                .help("拖动调整顺序")
                .onDrag {
                    draggingGroupID = group.id
                    return NSItemProvider(object: group.id as NSString)
                }
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if expanded {
                        expandedGroups.remove(group.id)
                    } else {
                        expandedGroups.insert(group.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(group.name)
                            if group.isDefault {
                                Text("默认")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text(groupSubtitle(group))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let best = bestDelay(members) {
                        NodeDelayLabel(delay: best)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起节点" : "展开节点")
            Button {
                toggleDefault(group.id)
            } label: {
                Image(systemName: group.isDefault ? "star.fill" : "star")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .foregroundStyle(group.isDefault ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("设为默认分组")
            Button {
                editor = SmartGroupDraft(group: group, isNew: false)
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("编辑分组")
            Button {
                pendingDelete = group
            } label: {
                Image(systemName: "trash")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除分组")
        }
    }

    private func dropTargetBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { dropTargetID == id },
            set: { targeted in
                if targeted {
                    dropTargetID = id
                } else if dropTargetID == id {
                    dropTargetID = nil
                }
            }
        )
    }

    private func moveGroup(_ id: String?, before targetID: String) {
        dropTargetID = nil
        draggingGroupID = nil
        guard let id, id != targetID,
              let from = policy.groups.firstIndex(where: { $0.id == id }),
              let to = policy.groups.firstIndex(where: { $0.id == targetID })
        else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            let group = policy.groups.remove(at: from)
            policy.groups.insert(group, at: to > from ? to - 1 : to)
        }
        persist()
    }

    private func groupDetail(_ group: SmartGroup) -> some View {
        let members = members(of: group)
        return VStack(alignment: .leading, spacing: 6) {
            if !group.rules.isEmpty {
                Text("匹配：" + group.rules.map(ruleDescription).joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if members.isEmpty {
                Text("还没有命中节点。点铅笔添加名称匹配规则。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(members, id: \.self) { node in
                    memberRow(group, node: node)
                }
                if group.mode == .manual {
                    Text("点节点即可切换手动选择。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 28)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func memberRow(_ group: SmartGroup, node: String) -> some View {
        let selected = group.mode == .manual && group.selectedNode == node
        let label = HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
            Text(node)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            NodeDelayLabel(delay: nodeDelays[node] ?? 0)
        }
        .contentShape(Rectangle())
        if group.mode == .manual {
            Button {
                selectNode(group.id, node: node)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help("设为手动选择的节点")
        } else {
            label
        }
    }

    private func members(of group: SmartGroup) -> [String] {
        if let item = resolved.first(where: { $0.id == group.id }) {
            return item.members
        }
        return SmartGroupMatching.claimedNodes(nodes: nodes, groups: policy.groups)[group.id] ?? []
    }

    private func bestDelay(_ members: [String]) -> UInt16? {
        NodeDelayIndex.best(members, delays: nodeDelays)
    }

    private func selectNode(_ groupID: String, node: String) {
        guard let index = policy.groups.firstIndex(where: { $0.id == groupID }) else { return }
        policy.groups[index].selectedNode = node
        persist()
    }

    private func runURLTest() {
        let tags = Set(runtimeGroups.map(\.tag)).sorted()
        guard !tags.isEmpty, !isTesting else { return }
        isTesting = true
        Task {
            var failure: Error?
            for tag in tags {
                do {
                    try await CommandTarget.standaloneClient().urlTest(tag)
                } catch {
                    failure = error
                }
            }
            isTesting = false
            if let failure {
                alert = AlertState(action: "节点测速", error: failure)
            }
        }
    }

    private func applyImport(_ imported: ProfileSmartPolicy) {
        guard let profileID else { return }
        var next = imported
        next.profileID = profileID
        let ids = Set(next.groups.map(\.id))
        next.domainRoutes.removeAll { !ids.contains($0.groupID) }
        next.appRoutes.removeAll { !ids.contains($0.groupID) }
        policy = next
        expandedGroups = []
        persist()
    }

    private static let helpTopics: [HelpTopic] = [
        HelpTopic("分组怎么工作", "分组挂在当前配置下面。一个节点只进入第一个命中的分组，所以顺序很重要：拖动行左侧的把手调整顺序。"),
        HelpTopic("自动与手动", "自动分组按延迟挑节点，手动分组由你指定一个节点。点整行展开它命中的全部节点；手动模式下点节点即可切换。"),
        HelpTopic("默认分组", "点星标设为默认，默认分组只会有一个。设置后，原来走主代理的连接会改走这个分组。"),
        HelpTopic("域名与应用", "下面的规则把指定域名或应用送进指定分组。它们优先于「强制接管」，但让位于「强制放行」。"),
        HelpTopic("测速", "「全部节点」里的测速按钮会让核心重新测试所有分组，延迟结果随后刷新到每个节点上。需要隧道已连接。"),
        HelpTopic("导出与导入", "导出把当前配置下的分组和域名、应用规则存成 JSON。导入会替换当前配置下的这些内容，替换前会再确认一次。"),
    ]

    private func toggleDefault(_ id: String) {
        let turningOn = policy.groups.first { $0.id == id }?.isDefault != true
        for index in policy.groups.indices {
            policy.groups[index].isDefault = turningOn && policy.groups[index].id == id
        }
        persist()
    }

    private func ruleDescription(_ rule: NodeMatchRule) -> String {
        let kind: String
        switch rule.kind {
        case .contains: kind = "包含"
        case .prefix: kind = "前缀"
        case .suffix: kind = "后缀"
        case .exact: kind = "等于"
        case .regex: kind = "正则"
        }
        return "\(kind)「\(rule.pattern)」"
    }

    private func deleteGroup(_ id: String) {
        policy.groups.removeAll { $0.id == id }
        policy.domainRoutes.removeAll { $0.groupID == id }
        policy.appRoutes.removeAll { $0.groupID == id }
        expandedGroups.remove(id)
        editor = nil
        persist()
    }

    private func groupSubtitle(_ group: SmartGroup) -> String {
        let mode = group.mode == .auto ? "自动选择" : "手动指定"
        var text = "\(mode) · \(members(of: group).count) 个节点"
        if group.mode == .manual {
            text += group.selectedNode.isEmpty ? " · 未指定节点" : " · \(group.selectedNode)"
        }
        return text
    }

    private func trafficRow(
        _ rule: GroupTrafficRule,
        showsIcons: Bool,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onEdit) {
                trafficLabel(rule, showsIcons: showsIcons)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("编辑这条规则")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("删除")
        }
    }

    private func trafficLabel(_ rule: GroupTrafficRule, showsIcons: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
                if showsIcons {
                    ProcessIconGrid(patterns: rule.patterns)
                }
            #endif
            HStack {
                if !showsIcons {
                    Text(rule.patterns.joined(separator: ", "))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                Spacer()
                Text(policy.groups.first { $0.id == rule.groupID }?.name ?? "未选择")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func groupsReplacing(_ group: SmartGroup) -> [SmartGroup] {
        var groups = policy.groups
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        return groups
    }

    private func saveGroup(_ group: SmartGroup, isNew: Bool) {
        if isNew {
            policy.groups.append(group)
        } else if let index = policy.groups.firstIndex(where: { $0.id == group.id }) {
            policy.groups[index] = group
        }
        if group.isDefault {
            for index in policy.groups.indices {
                policy.groups[index].isDefault = policy.groups[index].id == group.id
            }
        }
        editor = nil
        persist()
    }

    private func saveTraffic(_ rule: GroupTrafficRule, kind: TrafficKind, isNew: Bool) {
        switch kind {
        case .domain:
            upsert(&policy.domainRoutes, rule, isNew: isNew)
        case .app:
            upsert(&policy.appRoutes, rule, isNew: isNew)
        }
        trafficEditor = nil
        persist()
    }

    private func upsert(_ rules: inout [GroupTrafficRule], _ rule: GroupTrafficRule, isNew: Bool) {
        let cleaned = GroupTrafficRule(id: rule.id, groupID: rule.groupID, patterns: rule.patterns.filter { !$0.isEmpty })
        guard !cleaned.patterns.isEmpty else {
            if !isNew {
                rules.removeAll { $0.id == rule.id }
            }
            return
        }
        if isNew {
            rules.append(cleaned)
        } else if let index = rules.firstIndex(where: { $0.id == cleaned.id }) {
            rules[index] = cleaned
        } else {
            rules.append(cleaned)
        }
    }

    private func persist() {
        guard let profileID else { return }
        policy.profileID = profileID
        let snapshot = policy
        let configNodes = nodes
        Task {
            await SmartGroupStore.save(snapshot)
            if let profile = try? await ProfileManager.get(profileID) {
                let config = (try? await profile.readAsync()) ?? ""
                let nextNodes = ProfileConfigPatcher.proxyNodeNames(in: config)
                let nextResolved = ProfileConfigPatcher.resolve(config: config, policy: snapshot)
                await MainActor.run {
                    if !nextNodes.isEmpty {
                        nodes = nextNodes
                    } else {
                        nodes = configNodes
                    }
                    resolved = nextResolved
                }
            }
            await TunnelPolicyReloader.reloadIfConnected(environments)
        }
    }

    private func reload() async {
        let selectedID = await SharedPreferences.selectedProfileID.get()
        let id = requestedProfileID ?? selectedID
        guard id > 0, let profile = try? await ProfileManager.get(id) else {
            profileID = nil
            isLoading = false
            return
        }
        profileID = profile.mustID
        profileName = requestedProfileName ?? profile.name
        policy = await SmartGroupStore.policy(for: profile.mustID)
        let config = (try? await profile.readAsync()) ?? ""
        nodes = ProfileConfigPatcher.proxyNodeNames(in: config)
        resolved = ProfileConfigPatcher.resolve(config: config, policy: policy)
        runtimeGroups = environments.commandClient.groups ?? []
        isLoading = false
    }
}

@MainActor
public struct ProfileSmartGroupSection: View {
    let profileID: Int64
    let profileName: String
    @State private var policy = ProfileSmartPolicy(profileID: -1)
    @State private var resolved: [ProfileConfigPatcher.ResolvedSmartGroup] = []
    @State private var nodeCount = 0
    @State private var runtimeGroups: [OutboundGroup] = []
    @State private var showManage = false
    @EnvironmentObject private var environments: ExtensionEnvironments

    public init(profileID: Int64, profileName: String) {
        self.profileID = profileID
        self.profileName = profileName
    }

    private var delays: [String: UInt16] {
        NodeDelayIndex.delays(in: runtimeGroups)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("智能分组", systemImage: "rectangle.3.group")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if nodeCount > 0 {
                    Text("\(policy.groups.count) 组 / \(nodeCount) 节点")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("管理") {
                    showManage = true
                }
                .font(.subheadline)
            }
            if policy.groups.isEmpty {
                Text("还没有分组。添加名称匹配规则后节点会自动归组，还能指定默认分组、域名和应用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(policy.groups) { group in
                        groupRow(group)
                    }
                }
            }
        }
        .task(id: profileID) {
            await reload()
        }
        .onReceive(environments.commandClient.$groups) { groups in
            runtimeGroups = groups ?? []
        }
        .sheet(isPresented: $showManage, onDismiss: {
            Task { await reload() }
        }) {
            NavigationSheet(title: "智能分组", showsCloseButton: true) {
                SmartGroupManageView(profileID: profileID, profileName: profileName)
                    .environmentObject(environments)
            }
            .environmentObject(environments)
        }
    }

    private func groupRow(_ group: SmartGroup) -> some View {
        let item = resolved.first { $0.id == group.id }
        let members = item?.members ?? []
        let live = item.flatMap { item in runtimeGroups.first { $0.tag == item.tag } }
        let current = live?.selected ?? (group.mode == .manual ? group.selectedNode : "")
        let domainCount = policy.domainRoutes.filter { $0.groupID == group.id }.reduce(0) { $0 + $1.patterns.count }
        let appCount = policy.appRoutes.filter { $0.groupID == group.id }.reduce(0) { $0 + $1.patterns.count }
        return Button {
            showManage = true
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: group.isDefault ? "star.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(group.isDefault ? Color.accentColor : Color.secondary.opacity(0.45))
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if group.isDefault {
                            badge("默认", tint: Color.accentColor)
                        }
                        badge(group.mode == .auto ? "自动" : "手动", tint: .secondary)
                    }
                    Text(summary(members: members, domainCount: domainCount, appCount: appCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: current.isEmpty ? "minus.circle" : "arrow.turn.down.right")
                            .font(.caption2)
                        Text(current.isEmpty ? "未指定节点" : current)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(current.isEmpty ? Color.secondary : Color.primary)
                }
                Spacer(minLength: 8)
                NodeDelayLabel(delay: NodeDelayIndex.best(members, delays: delays) ?? 0)
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开智能分组管理")
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    private func summary(members: [String], domainCount: Int, appCount: Int) -> String {
        var parts = [members.isEmpty ? "未命中节点" : "\(members.count) 个节点"]
        if domainCount > 0 {
            parts.append("域名 \(domainCount)")
        }
        if appCount > 0 {
            parts.append("应用 \(appCount)")
        }
        return parts.joined(separator: " · ")
    }

    private func reload() async {
        policy = await SmartGroupStore.policy(for: profileID)
        if let profile = try? await ProfileManager.get(profileID) {
            let config = (try? await profile.readAsync()) ?? ""
            nodeCount = ProfileConfigPatcher.proxyNodeNames(in: config).count
            resolved = ProfileConfigPatcher.resolve(config: config, policy: policy)
        }
        runtimeGroups = environments.commandClient.groups ?? []
    }
}

private struct SmartGroupDraft: Identifiable {
    var id: String { group.id }
    var group: SmartGroup
    var isNew: Bool
}

enum TrafficKind {
    case domain
    case app
}

private struct TrafficDraft: Identifiable {
    var id: String { rule.id }
    var rule: GroupTrafficRule
    var kind: TrafficKind
    var isNew: Bool
}

private struct SmartGroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: SmartGroup
    let nodes: [String]
    let delays: [String: UInt16]
    let groups: [SmartGroup]
    let onDelete: (() -> Void)?
    let onSave: (SmartGroup) -> Void
    @State private var nodeQuery = ""
    @State private var confirmsDelete = false
    @FocusState private var nameFocused: Bool

    init(
        draft: SmartGroup,
        nodes: [String],
        delays: [String: UInt16],
        groups: [SmartGroup],
        onDelete: (() -> Void)? = nil,
        onSave: @escaping (SmartGroup) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.nodes = nodes
        self.delays = delays
        self.groups = groups
        self.onDelete = onDelete
        self.onSave = onSave
    }

    private var previewGroups: [SmartGroup] {
        var items = groups
        if let index = items.firstIndex(where: { $0.id == draft.id }) {
            items[index] = draft
        } else {
            items.append(draft)
        }
        return items
    }

    private var matchedNodes: [String] {
        SmartGroupMatching.claimedNodes(nodes: nodes, groups: previewGroups)[draft.id] ?? []
    }

    private var matchedSet: Set<String> {
        Set(matchedNodes)
    }

    private var visibleNodes: [String] {
        let query = nodeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nodes }
        return nodes.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        FormView {
            Section {
                TextField("名称", text: $draft.name)
                    .visibleTextField()
                    .focused($nameFocused)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
                Picker("节点选择", selection: $draft.mode) {
                    Text("自动选择").tag(SmartGroupMode.auto)
                    Text("手动指定").tag(SmartGroupMode.manual)
                }
                Toggle("作为默认分组", isOn: $draft.isDefault)
            } footer: {
                Text("默认分组只会有一个。勾选后，原来走主代理的流量改走这里。")
            }

            Section {
                if draft.rules.isEmpty {
                    Text("还没有匹配规则")
                        .foregroundStyle(.secondary)
                }
                ForEach($draft.rules) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("匹配方式", selection: $rule.kind) {
                            Text("包含").tag(NodeMatchKind.contains)
                            Text("前缀").tag(NodeMatchKind.prefix)
                            Text("后缀").tag(NodeMatchKind.suffix)
                            Text("完全相等").tag(NodeMatchKind.exact)
                            Text("正则").tag(NodeMatchKind.regex)
                        }
                        TextField("节点名称", text: $rule.pattern)
                            .visibleTextField()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        #endif
                        Button("删除这条规则", role: .destructive) {
                            draft.rules.removeAll { $0.id == rule.id }
                        }
                    }
                }
                Button {
                    draft.rules.append(NodeMatchRule())
                } label: {
                    Label("添加匹配规则", systemImage: "plus")
                }
            } header: {
                Text("名称匹配")
            } footer: {
                Text("同一分组里的规则是「或」关系。例如包含「香港」或前缀「HK」。")
            }

            Section {
                if nodes.isEmpty {
                    Text("这个配置里还没有可分组的代理节点。")
                        .foregroundStyle(.secondary)
                } else {
                    TextField("筛选节点", text: $nodeQuery)
                        .visibleTextField()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
                    ForEach(Array(visibleNodes.enumerated()), id: \.offset) { _, node in
                        nodeRow(node)
                    }
                }
            } header: {
                Text("全部节点")
            } footer: {
                if nodes.isEmpty {
                    Text("节点来自当前配置里的代理出站。")
                } else if nodeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("共 \(nodes.count) 个，当前规则命中 \(matchedNodes.count) 个。手动指定只能选已命中的节点。")
                } else {
                    Text("显示 \(visibleNodes.count) / \(nodes.count) 个，当前规则命中 \(matchedNodes.count) 个。手动指定只能选已命中的节点。")
                }
            }

            Section {
                Button("保存") {
                    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    draft.name = name
                    onSave(draft)
                    dismiss()
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let onDelete {
                    Button("删除分组", role: .destructive) {
                        confirmsDelete = true
                    }
                    .confirmationDialog("删除这个分组？", isPresented: $confirmsDelete, titleVisibility: .visible) {
                        Button("删除", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("「\(draft.name)」以及指向它的域名、应用规则会一起删除，无法撤销。")
                    }
                }
            }
        }
        .onAppear {
            if onDelete == nil {
                nameFocused = true
            }
        }
    }

    @ViewBuilder
    private func nodeRow(_ node: String) -> some View {
        let matched = matchedSet.contains(node)
        if draft.mode == .manual, matched {
            Button {
                draft.selectedNode = node
            } label: {
                nodeLabel(node, matched: true)
            }
            .buttonStyle(.plain)
            .help("选为手动指定的节点")
        } else {
            nodeLabel(node, matched: matched)
        }
    }

    private func nodeLabel(_ node: String, matched: Bool) -> some View {
        HStack {
            Text(node)
                .foregroundStyle(.primary)
            #if !os(tvOS)
                .textSelection(.enabled)
            #endif
            Spacer()
            if draft.mode == .manual, matched, draft.selectedNode == node {
                Image(systemName: "checkmark")
            } else {
                Text(matched ? "已命中" : "未命中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            NodeDelayLabel(delay: delays[node] ?? 0)
        }
        .contentShape(Rectangle())
    }
}

private struct NodeDelayLabel: View {
    let delay: UInt16

    var body: some View {
        if delay > 0 {
            Text("\(delay)ms")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.urlTestDelay(delay))
        } else {
            Text("—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct TrafficRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: TrafficDraft
    let groups: [SmartGroup]
    let onSave: (GroupTrafficRule) -> Void
    @State private var text: String
    @State private var manualName = ""
    @State private var showsRunningApps = false

    init(draft: TrafficDraft, groups: [SmartGroup], onSave: @escaping (GroupTrafficRule) -> Void) {
        _draft = State(initialValue: draft)
        self.groups = groups
        self.onSave = onSave
        _text = State(initialValue: draft.rule.patterns.joined(separator: "\n"))
    }

    private var patterns: [String] {
        RoutePatternParser.split(text)
    }

    private func replacePatterns(_ patterns: [String]) {
        text = patterns.joined(separator: "\n")
    }

    private var patternBinding: Binding<[String]> {
        Binding(get: { patterns }, set: { replacePatterns($0) })
    }

    var body: some View {
        FormView {
            Section {
                Picker("智能分组", selection: $draft.rule.groupID) {
                    ForEach(groups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                if draft.kind == .domain {
                    #if os(tvOS)
                        TextField("每行一个域名", text: $text)
                    #else
                        TextEditor(text: $text)
                            .frame(minHeight: 88)
                            .visibleTextEditor()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        #endif
                    #endif
                } else {
                    #if os(macOS)
                        if patterns.isEmpty {
                            Text("还没有选择应用")
                                .foregroundStyle(.secondary)
                        } else {
                            ProcessIconGrid(patterns: patterns) { pattern in
                                replacePatterns(patterns.filter { $0 != pattern })
                            }
                        }
                        HStack {
                            TextField("手工添加进程名", text: $manualName)
                                .visibleTextField()
                            Button("添加") {
                                var next = patterns
                                for item in RoutePatternParser.split(manualName) where !next.contains(item) {
                                    next.append(item)
                                }
                                replacePatterns(next)
                                manualName = ""
                            }
                            .disabled(RoutePatternParser.split(manualName).isEmpty)
                        }
                        Button {
                            showsRunningApps = true
                        } label: {
                            Label("从正在运行的应用添加", systemImage: "macwindow")
                        }
                        .sheet(isPresented: $showsRunningApps) {
                            NavigationSheet(title: "正在运行的应用", showsCloseButton: true) {
                                RunningAppPicker(values: patternBinding, onCommit: {})
                            }
                        }
                    #else
                        TextField("每行一个进程名", text: $text)
                    #endif
                }
            } footer: {
                if draft.kind == .domain {
                    Text("example.com 匹配该域名和全部子域名。也可以使用 full:、keyword:、regex: 和 *.example.com。")
                } else {
                    Text("点选正在运行的应用。选中后，这个应用和它的辅助进程都会走这个分组。")
                }
            }
            Section {
                Button("保存") {
                    var rule = draft.rule
                    rule.patterns = RoutePatternParser.split(text)
                    onSave(rule)
                    dismiss()
                }
                .disabled(groups.isEmpty || (draft.isNew && patterns.isEmpty))
                if !draft.isNew {
                    Button("删除", role: .destructive) {
                        var rule = draft.rule
                        rule.patterns = []
                        onSave(rule)
                        dismiss()
                    }
                }
            }
        }
    }
}
