import Foundation
import Libbox

public enum ProfileConfigPatcher {
    public struct ResolvedSmartGroup: Hashable, Identifiable {
        public var group: SmartGroup
        public var tag: String
        public var members: [String]

        public var id: String {
            group.id
        }
    }

    public static func normalizeTunStack(_ config: String, includeAllNetworks: Bool) -> String {
        guard includeAllNetworks, var root = parse(config), var inbounds = root["inbounds"] as? [[String: Any]] else {
            return config
        }
        var changed = false
        for index in inbounds.indices {
            guard (inbounds[index]["type"] as? String) == "tun" else { continue }
            let stack = (inbounds[index]["stack"] as? String)?.lowercased() ?? ""
            guard stack == "system" || stack == "mixed" || stack == "gvisor" else { continue }
            inbounds[index].removeValue(forKey: "stack")
            changed = true
        }
        guard changed else { return config }
        root["inbounds"] = inbounds
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return config
        }
        return text
    }

    public static func rebindOccupiedListeners(_ config: String) -> String {
        guard var root = parse(config), var inbounds = root["inbounds"] as? [[String: Any]] else {
            return config
        }
        var changed = false
        var nextPort = 17901
        for index in inbounds.indices {
            let type = (inbounds[index]["type"] as? String)?.lowercased() ?? ""
            guard type == "mixed" || type == "http" || type == "socks" else { continue }
            guard let port = (inbounds[index]["listen_port"] as? NSNumber)?.intValue, port > 0 else { continue }
            guard !isPortFree(UInt16(port)) else { continue }
            guard let free = nextFreePort(from: &nextPort) else { continue }
            inbounds[index]["listen_port"] = free
            changed = true
        }
        if moveTunToEnd(&inbounds) {
            changed = true
        }
        guard changed else { return config }
        root["inbounds"] = inbounds
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return config
        }
        return text
    }

    private static func nextFreePort(from start: inout Int) -> Int? {
        while start < 18000 {
            let candidate = start
            start += 1
            if candidate > 0, candidate <= Int(UInt16.max), isPortFree(UInt16(candidate)) {
                return candidate
            }
        }
        return nil
    }

    private static func moveTunToEnd(_ inbounds: inout [[String: Any]]) -> Bool {
        guard let firstTun = inbounds.firstIndex(where: { ($0["type"] as? String)?.lowercased() == "tun" }) else {
            return false
        }
        let listenerFollowsTun = inbounds[firstTun...].contains { inbound in
            let type = (inbound["type"] as? String)?.lowercased() ?? ""
            return type == "mixed" || type == "http" || type == "socks"
        }
        guard listenerFollowsTun else { return false }
        let tuns = inbounds.filter { ($0["type"] as? String)?.lowercased() == "tun" }
        let others = inbounds.filter { ($0["type"] as? String)?.lowercased() != "tun" }
        inbounds = others + tuns
        return true
    }

    private static func isPortFree(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 {
            return false
        }
        return errno == ECONNREFUSED
    }

    public static let preferredClashMode = "智能首选"

    public static func clashModes(in config: String) -> [String] {
        guard let root = parse(config) else { return [] }
        return clashModes(in: root)
    }

    public static func resolveClashMode(_ stored: String, modes _: [String]) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? preferredClashMode : trimmed
    }

    public static func applyClashMode(_ config: String, preferred: String) -> String {
        guard var root = parse(config) else { return config }
        let resolved = resolveClashMode(preferred, modes: clashModes(in: root))
        guard !resolved.isEmpty else { return config }
        var experimental = root["experimental"] as? [String: Any] ?? [:]
        var clashAPI = experimental["clash_api"] as? [String: Any] ?? [:]
        if (clashAPI["default_mode"] as? String) == resolved {
            return config
        }
        clashAPI["default_mode"] = resolved
        experimental["clash_api"] = clashAPI
        root["experimental"] = experimental
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return config
        }
        return text
    }

    private static func clashModes(in root: [String: Any]) -> [String] {
        var modes: [String] = []
        if let route = root["route"] as? [String: Any] {
            collectClashModes(route["rules"], into: &modes)
        }
        if let dns = root["dns"] as? [String: Any] {
            collectClashModes(dns["rules"], into: &modes)
        }
        return modes
    }

    private static func collectClashModes(_ value: Any?, into modes: inout [String]) {
        if let rules = value as? [Any] {
            for rule in rules {
                collectClashModes(rule, into: &modes)
            }
            return
        }
        guard let rule = value as? [String: Any] else { return }
        if let mode = rule["clash_mode"] as? String {
            let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !modes.contains(trimmed) {
                modes.append(trimmed)
            }
        }
        collectClashModes(rule["rules"], into: &modes)
    }

    public static func proxyNodeNames(in config: String) -> [String] {
        guard let root = parse(config) else { return [] }
        return proxyNodes(in: root).map(\.tag)
    }

    public static func resolve(config: String, policy: ProfileSmartPolicy) -> [ResolvedSmartGroup] {
        guard let root = parse(config), let outbounds = outboundObjects(in: root) else { return [] }
        let nodeTags = proxyNodes(in: root).map(\.tag)
        let groupsByTag = groupMembers(in: outbounds)
        let mainTag = mainProxyTag(in: root, groupMembers: groupsByTag)
        let mainClosure = mainTag.map { closure(of: $0, groupMembers: groupsByTag, proxyTags: Set(nodeTags)) }
        let claimed = SmartGroupMatching.claimedNodes(nodes: nodeTags, groups: policy.groups)
        let defaultGroupID = policy.groups.first(where: \.isDefault)?.id
        let defaultHasMembers = defaultGroupID.flatMap { claimed[$0] }?.isEmpty == false
        var removedTags = Set<String>()
        if defaultHasMembers, let mainClosure {
            removedTags = mainClosure.groupTags
        }
        var usedTags = Set(outbounds.compactMap { $0["tag"] as? String })
        usedTags.subtract(removedTags)
        var resolved: [ResolvedSmartGroup] = []
        for group in policy.groups {
            let members = claimed[group.id] ?? []
            guard !members.isEmpty else { continue }
            let tag = uniqueTag(group.name, existing: &usedTags)
            resolved.append(ResolvedSmartGroup(group: group, tag: tag, members: members))
        }
        return resolved
    }

    public static func apply(config: String, policy: ProfileSmartPolicy?, advanced: AdvancedRoutePolicy) -> String {
        let advancedActive = advanced.hasRules
        let smartActive = policy?.hasRoutingEffect == true
        guard advancedActive || smartActive else { return config }
        guard var root = parse(config) else { return config }
        guard var outbounds = outboundObjects(in: root) else { return config }
        let nodes = proxyNodes(in: root)
        let nodeTags = nodes.map(\.tag)
        let groupsByTag = groupMembers(in: outbounds)
        let mainTag = mainProxyTag(in: root, groupMembers: groupsByTag)
        let mainClosure = mainTag.map { closure(of: $0, groupMembers: groupsByTag, proxyTags: Set(nodeTags)) }

        let claimed = SmartGroupMatching.claimedNodes(nodes: nodeTags, groups: policy?.groups ?? [])
        let defaultGroupID = policy?.groups.first { $0.isDefault }?.id
        let defaultHasMembers = defaultGroupID.flatMap { claimed[$0] }?.isEmpty == false
        var removedTags = Set<String>()
        if defaultHasMembers, let mainClosure {
            removedTags = mainClosure.groupTags
        }
        let urlTestTemplate = mainClosure.flatMap { template in
            outbounds.first { outbound in
                (outbound["type"] as? String) == "urltest" && template.groupTags.contains(outbound["tag"] as? String ?? "")
            }
        } ?? outbounds.first { ($0["type"] as? String) == "urltest" }

        let builtGroups = policy.map { resolve(config: config, policy: $0) } ?? []
        let tagByGroupID = Dictionary(uniqueKeysWithValues: builtGroups.map { ($0.group.id, $0.tag) })
        let defaultTag = builtGroups.first { $0.group.isDefault }?.tag
        let takeoverTag = defaultTag ?? mainTag

        if !removedTags.isEmpty {
            outbounds.removeAll { outbound in
                guard let tag = outbound["tag"] as? String else { return false }
                return removedTags.contains(tag)
            }
        }

        for built in builtGroups {
            outbounds.append(smartOutbound(built.group, tag: built.tag, members: built.members, urlTestTemplate: urlTestTemplate))
        }

        let directTag = ensureDirectOutbound(&outbounds)

        var route = root["route"] as? [String: Any] ?? [:]
        guard var rules = ruleArray(from: route) else { return config }

        // 优先级：强制放行（绝对直连）> 强制接管（强制代理）> 配置自带的模式规则 > 智能分组（最后的分流）
        var forced: [[String: Any]] = []
        appendIPRules(advanced.ipBypass, outbound: directTag, into: &forced)
        appendDomainRules(advanced.domainBypass, outbound: directTag, into: &forced)
        if let takeoverTag {
            appendDomainRules(advanced.domainTakeover, outbound: takeoverTag, into: &forced)
        }
        #if os(macOS)
            appendProcessRules(advanced.appBypass, outbound: directTag, into: &forced)
            if let takeoverTag {
                appendProcessRules(advanced.appTakeover, outbound: takeoverTag, into: &forced)
            }
        #endif

        var groupRules: [[String: Any]] = []
        if let policy {
            for item in policy.domainRoutes {
                guard let tag = tagByGroupID[item.groupID] else { continue }
                appendDomainRules(item.patterns, outbound: tag, into: &groupRules)
            }
            #if os(macOS)
                for item in policy.appRoutes {
                    guard let tag = tagByGroupID[item.groupID] else { continue }
                    appendProcessRules(item.patterns, outbound: tag, into: &groupRules)
                }
            #endif
        }

        let insertionIndex = routeInsertionIndex(in: rules)
        var top = forced
        if (forced + groupRules).contains(where: isDomainRule), !prefixHasSniff(rules, length: insertionIndex) {
            top.insert(["action": "sniff"], at: 0)
        }
        if !top.isEmpty {
            rules.insert(contentsOf: top, at: insertionIndex)
        }
        // 分组规则必须排在订阅自带的分流规则之前：像 geosite-geolocation-!cn 这样的兜底
        // rule_set 几乎命中所有海外流量，放到末尾就永远轮不到分组规则。clash_mode（模式）仍优先。
        let groupStart = insertionIndex + top.count
        let groupIndex = groupStart + clashModePrefixLength(in: rules, from: groupStart)
        if !groupRules.isEmpty {
            rules.insert(contentsOf: groupRules, at: groupIndex)
        }
        if let defaultTag {
            let final = route["final"] as? String
            if final == nil || final == mainTag || removedTags.contains(final ?? "") {
                route["final"] = defaultTag
            }
            var replaced = removedTags
            if let mainTag {
                replaced.insert(mainTag)
            }
            rules = rules.map { retarget($0, from: replaced, to: defaultTag) }
        }
        if !rules.isEmpty || route["final"] != nil {
            route["rules"] = rules
            root["route"] = route
        }
        root["outbounds"] = outbounds
        if let defaultTag, !removedTags.isEmpty {
            root = retarget(root, from: removedTags, to: defaultTag) as? [String: Any] ?? root
        }

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return config
        }
        return text
    }

    private static func parse(_ config: String) -> [String: Any]? {
        if let object = jsonObject(config) {
            return object
        }
        var error: NSError?
        guard let formatted = LibboxFormatConfig(config, &error)?.value else {
            return nil
        }
        return jsonObject(formatted)
    }

    private static func jsonObject(_ config: String) -> [String: Any]? {
        guard let data = config.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func routeInsertionIndex(in rules: [Any]) -> Int {
        var index = 0
        for rule in rules {
            guard let dictionary = rule as? [String: Any], isRoutePrelude(dictionary) else {
                break
            }
            index += 1
        }
        return index
    }

    private static func clashModePrefixLength(in rules: [Any], from start: Int) -> Int {
        var count = 0
        for rule in rules.dropFirst(start) {
            guard let dictionary = rule as? [String: Any], dictionary["clash_mode"] != nil else {
                break
            }
            count += 1
        }
        return count
    }

    private static func prefixHasSniff(_ rules: [Any], length: Int) -> Bool {
        rules.prefix(length).contains { rule in
            guard let dictionary = rule as? [String: Any] else { return false }
            return (dictionary["action"] as? String)?.lowercased() == "sniff"
        }
    }

    private static func isDomainRule(_ rule: [String: Any]) -> Bool {
        rule["domain_suffix"] != nil || rule["domain"] != nil || rule["domain_keyword"] != nil || rule["domain_regex"] != nil
    }

    private static func isRoutePrelude(_ rule: [String: Any]) -> Bool {
        let action = (rule["action"] as? String)?.lowercased() ?? ""
        if action == "sniff" || action == "hijack-dns" || action == "resolve" || action == "route-options" {
            return true
        }
        guard action.isEmpty || action == "route" else { return false }
        return stringList(rule["protocol"]).contains { $0.lowercased() == "dns" }
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let text = value as? String {
            return [text]
        }
        if let values = value as? [String] {
            return values
        }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return []
    }

    private static func outboundObjects(in root: [String: Any]) -> [[String: Any]]? {
        guard let existing = root["outbounds"] else { return [] }
        return existing as? [[String: Any]]
    }

    private static func ruleArray(from route: [String: Any]) -> [Any]? {
        guard let existing = route["rules"] else { return [] }
        if let rules = existing as? [Any] {
            return rules
        }
        if let rules = existing as? [[String: Any]] {
            return rules.map { $0 as Any }
        }
        return nil
    }

    private struct ProxyNode {
        let tag: String
    }

    private static func proxyNodes(in root: [String: Any]) -> [ProxyNode] {
        (outboundObjects(in: root) ?? []).compactMap { outbound in
            guard let tag = outbound["tag"] as? String, !tag.isEmpty else { return nil }
            guard kind(of: outbound["type"] as? String) == .proxy else { return nil }
            return ProxyNode(tag: tag)
        }
    }

    private enum OutboundKind {
        case proxy
        case group
        case utility
    }

    private static func kind(of type: String?) -> OutboundKind {
        switch type {
        case "selector", "urltest":
            return .group
        case "direct", "block", "dns":
            return .utility
        default:
            return .proxy
        }
    }

    private static func groupMembers(in outbounds: [[String: Any]]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for outbound in outbounds {
            guard kind(of: outbound["type"] as? String) == .group,
                  let tag = outbound["tag"] as? String
            else { continue }
            let members = outbound["outbounds"] as? [String] ?? []
            result[tag] = members
        }
        return result
    }

    private struct GroupClosure {
        var groupTags: Set<String>
        var leaves: [String]
    }

    private static func closure(of rootTag: String, groupMembers: [String: [String]], proxyTags: Set<String>) -> GroupClosure {
        var groupTags = Set<String>()
        var leaves: [String] = []
        var seenLeaves = Set<String>()

        func walk(_ tag: String) {
            if let members = groupMembers[tag] {
                guard groupTags.insert(tag).inserted else { return }
                for member in members {
                    walk(member)
                }
            } else if proxyTags.contains(tag), seenLeaves.insert(tag).inserted {
                leaves.append(tag)
            }
        }

        walk(rootTag)
        return GroupClosure(groupTags: groupTags, leaves: leaves)
    }

    private static func mainProxyTag(in root: [String: Any], groupMembers: [String: [String]]) -> String? {
        let route = root["route"] as? [String: Any]
        if let final = route?["final"] as? String, groupMembers[final] != nil {
            return final
        }
        let proxyTags = Set(proxyNodes(in: root).map(\.tag))
        return groupMembers.keys.max { lhs, rhs in
            closure(of: lhs, groupMembers: groupMembers, proxyTags: proxyTags).leaves.count
                < closure(of: rhs, groupMembers: groupMembers, proxyTags: proxyTags).leaves.count
        }
    }

    private static func uniqueTag(_ name: String, existing: inout Set<String>) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "智能分组" : trimmed
        if existing.insert(base).inserted {
            return base
        }
        var index = 2
        while !existing.insert("\(base) \(index)").inserted {
            index += 1
        }
        return "\(base) \(index)"
    }

    private static func smartOutbound(
        _ group: SmartGroup,
        tag: String,
        members: [String],
        urlTestTemplate: [String: Any]?
    ) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": group.mode == .auto ? "urltest" : "selector",
            "tag": tag,
            "outbounds": members,
        ]
        if group.mode == .auto {
            outbound["url"] = urlTestTemplate?["url"] as? String ?? "https://www.gstatic.com/generate_204"
            outbound["interval"] = urlTestTemplate?["interval"] as? String ?? "3m"
            if let tolerance = urlTestTemplate?["tolerance"] {
                outbound["tolerance"] = tolerance
            } else {
                outbound["tolerance"] = 50
            }
        } else if members.contains(group.selectedNode) {
            outbound["default"] = group.selectedNode
            outbound["interrupt_exist_connections"] = true
        }
        return outbound
    }

    private static func ensureDirectOutbound(_ outbounds: inout [[String: Any]]) -> String {
        if let existing = outbounds.first(where: { ($0["type"] as? String) == "direct" }),
           let tag = existing["tag"] as? String,
           !tag.isEmpty
        {
            return tag
        }
        outbounds.append(["type": "direct", "tag": "direct"])
        return "direct"
    }

    private static func appendIPRules(_ patterns: [String], outbound: String, into rules: inout [[String: Any]]) {
        let cidrs = patterns.compactMap { RoutePatternParser.normalizeIPCIDR($0) }
        guard !cidrs.isEmpty else { return }
        rules.append(["ip_cidr": cidrs, "outbound": outbound])
    }

    private static func appendDomainRules(_ patterns: [String], outbound: String, into rules: inout [[String: Any]]) {
        var suffix: [String] = []
        var exact: [String] = []
        var keyword: [String] = []
        var regex: [String] = []
        for pattern in patterns {
            let item = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { continue }
            if let value = item.droppingPrefix("keyword:") {
                keyword.append(RoutePatternParser.host(of: value))
            } else if let value = item.droppingPrefix("regex:") {
                regex.append(value)
            } else if let value = item.droppingPrefix("full:") {
                exact.append(RoutePatternParser.host(of: value))
            } else if let value = item.droppingPrefix("*.") {
                suffix.append(RoutePatternParser.host(of: value))
            } else {
                suffix.append(RoutePatternParser.host(of: item))
            }
        }
        if !suffix.isEmpty {
            rules.append(["domain_suffix": suffix, "outbound": outbound])
        }
        if !exact.isEmpty {
            rules.append(["domain": exact, "outbound": outbound])
        }
        if !keyword.isEmpty {
            rules.append(["domain_keyword": keyword, "outbound": outbound])
        }
        if !regex.isEmpty {
            rules.append(["domain_regex": regex, "outbound": outbound])
        }
    }

    private static func appendProcessRules(_ patterns: [String], outbound: String, into rules: inout [[String: Any]]) {
        var names: [String] = []
        var paths: [String] = []
        var regexes: [String] = []
        for pattern in patterns {
            let item = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { continue }
            if item.hasPrefix("bundle:") {
                let path = String(item.dropFirst("bundle:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let regex = bundlePathRegex(path) {
                    regexes.append(regex)
                }
            } else if item.contains("/") {
                paths.append(item)
            } else {
                names.append(item)
                #if os(macOS)
                    if let path = InstalledAppIndex.bundlePath(forExecutable: item), let regex = bundlePathRegex(path) {
                        regexes.append(regex)
                    }
                #endif
            }
        }
        if !names.isEmpty {
            rules.append(["process_name": names, "outbound": outbound])
        }
        if !paths.isEmpty {
            rules.append(["process_path": paths, "outbound": outbound])
        }
        if !regexes.isEmpty {
            rules.append(["process_path_regex": regexes, "outbound": outbound])
        }
    }

    private static func bundlePathRegex(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: path)
        return "^\(escaped)(/|$)"
    }

    private static func retarget(_ value: Any, from tags: Set<String>, to replacement: String) -> Any {
        if var dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if key == "outbounds", let members = nested as? [String] {
                    var seen = Set<String>()
                    dictionary[key] = members.compactMap { member -> String? in
                        let resolved = tags.contains(member) ? replacement : member
                        return seen.insert(resolved).inserted ? resolved : nil
                    }
                } else if (key == "outbound" || key == "detour" || key == "default"),
                          let name = nested as? String,
                          tags.contains(name)
                {
                    dictionary[key] = replacement
                } else {
                    dictionary[key] = retarget(nested, from: tags, to: replacement)
                }
            }
            return dictionary
        }
        if let array = value as? [Any] {
            return array.map { retarget($0, from: tags, to: replacement) }
        }
        return value
    }
}

private extension String {
    func droppingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        let value = String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
