import Foundation
import Libbox

public enum SmartGroupMode: String, Codable, Hashable, CaseIterable, Identifiable {
    case auto
    case manual

    public var id: String {
        rawValue
    }
}

public enum NodeMatchKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case contains
    case prefix
    case suffix
    case exact
    case regex

    public var id: String {
        rawValue
    }
}

public struct NodeMatchRule: Codable, Hashable, Identifiable {
    public var id: String
    public var kind: NodeMatchKind
    public var pattern: String

    public init(id: String = UUID().uuidString, kind: NodeMatchKind = .contains, pattern: String = "") {
        self.id = id
        self.kind = kind
        self.pattern = pattern
    }
}

public struct SmartGroup: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var mode: SmartGroupMode
    public var isDefault: Bool
    public var selectedNode: String
    public var rules: [NodeMatchRule]

    public init(
        id: String = UUID().uuidString,
        name: String,
        mode: SmartGroupMode = .auto,
        isDefault: Bool = false,
        selectedNode: String = "",
        rules: [NodeMatchRule] = []
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.isDefault = isDefault
        self.selectedNode = selectedNode
        self.rules = rules
    }
}

public struct GroupTrafficRule: Codable, Hashable, Identifiable {
    public var id: String
    public var groupID: String
    public var patterns: [String]

    public init(id: String = UUID().uuidString, groupID: String, patterns: [String] = []) {
        self.id = id
        self.groupID = groupID
        self.patterns = patterns
    }
}

public struct ProfileSmartPolicy: Codable, Hashable {
    public var profileID: Int64
    public var groups: [SmartGroup]
    public var domainRoutes: [GroupTrafficRule]
    public var appRoutes: [GroupTrafficRule]

    public init(
        profileID: Int64,
        groups: [SmartGroup] = [],
        domainRoutes: [GroupTrafficRule] = [],
        appRoutes: [GroupTrafficRule] = []
    ) {
        self.profileID = profileID
        self.groups = groups
        self.domainRoutes = domainRoutes
        self.appRoutes = appRoutes
    }

    public var hasRoutingEffect: Bool {
        groups.contains { group in
            group.rules.contains { !$0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        } || !domainRoutes.isEmpty || !appRoutes.isEmpty
    }
}

public enum SmartGroupStore {
    public static func policy(for profileID: Int64) async -> ProfileSmartPolicy {
        let all = await SharedPreferences.smartGroupPolicies.get()
        return all.first { $0.profileID == profileID } ?? ProfileSmartPolicy(profileID: profileID)
    }

    public static func save(_ policy: ProfileSmartPolicy) async {
        var all = await SharedPreferences.smartGroupPolicies.get()
        if let index = all.firstIndex(where: { $0.profileID == policy.profileID }) {
            all[index] = policy
        } else {
            all.append(policy)
        }
        await SharedPreferences.smartGroupPolicies.set(all)
    }
}

public enum SmartGroupMatching {
    public static func claimedNodes(nodes: [String], groups: [SmartGroup]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var taken = Set<String>()
        for group in groups {
            var mine: [String] = []
            for node in nodes where !taken.contains(node) {
                if group.rules.contains(where: { matches(node, rule: $0) }) {
                    mine.append(node)
                    taken.insert(node)
                }
            }
            result[group.id] = mine
        }
        return result
    }

    public static func unmatchedNodes(nodes: [String], groups: [SmartGroup]) -> [String] {
        let claimed = Set(claimedNodes(nodes: nodes, groups: groups).values.flatMap { $0 })
        return nodes.filter { !claimed.contains($0) }
    }

    public static func matches(_ name: String, rule: NodeMatchRule) -> Bool {
        let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return false }
        switch rule.kind {
        case .contains:
            return name.range(of: pattern, options: .caseInsensitive) != nil
        case .prefix:
            return name.range(of: pattern, options: [.caseInsensitive, .anchored]) != nil
        case .suffix:
            guard name.count >= pattern.count else { return false }
            return name.range(
                of: pattern,
                options: [.caseInsensitive, .anchored, .backwards]
            ) != nil
        case .exact:
            return name.compare(pattern, options: .caseInsensitive) == .orderedSame
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(name.startIndex ..< name.endIndex, in: name)
            return regex.firstMatch(in: name, options: [], range: range) != nil
        }
    }
}

public struct AdvancedRoutePolicy: Codable, Hashable {
    public var domainTakeover: [String]
    public var domainBypass: [String]
    public var appTakeover: [String]
    public var appBypass: [String]
    public var ipBypass: [String]

    public init(
        domainTakeover: [String] = [],
        domainBypass: [String] = [],
        appTakeover: [String] = [],
        appBypass: [String] = [],
        ipBypass: [String] = []
    ) {
        self.domainTakeover = domainTakeover
        self.domainBypass = domainBypass
        self.appTakeover = appTakeover
        self.appBypass = appBypass
        self.ipBypass = ipBypass
    }

    private enum CodingKeys: String, CodingKey {
        case domainTakeover, domainBypass, appTakeover, appBypass, ipBypass
    }

    // Policies stored before ipBypass existed must keep decoding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domainTakeover = try container.decodeIfPresent([String].self, forKey: .domainTakeover) ?? []
        domainBypass = try container.decodeIfPresent([String].self, forKey: .domainBypass) ?? []
        appTakeover = try container.decodeIfPresent([String].self, forKey: .appTakeover) ?? []
        appBypass = try container.decodeIfPresent([String].self, forKey: .appBypass) ?? []
        ipBypass = try container.decodeIfPresent([String].self, forKey: .ipBypass) ?? []
    }

    public static let empty = AdvancedRoutePolicy()

    public var hasRules: Bool {
        !domainTakeover.isEmpty || !domainBypass.isEmpty || !appTakeover.isEmpty || !appBypass.isEmpty || !ipBypass.isEmpty
    }
}

public enum AdvancedRouteStore {
    public static func current() async -> AdvancedRoutePolicy {
        await SharedPreferences.advancedRoutePolicy.get()
    }

    public static func save(_ policy: AdvancedRoutePolicy) async {
        await SharedPreferences.advancedRoutePolicy.set(policy)
    }
}

public enum RoutePatternParser {
    public static func split(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Reduces a pasted URL or host:port down to the bare domain, preserving any rule prefix.
    public static func normalizeDomain(_ item: String) -> String {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        for prefix in ["regex:", "keyword:", "full:", "*."] {
            guard trimmed.hasPrefix(prefix) else { continue }
            if prefix == "regex:" { return trimmed }
            let value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return prefix + host(of: value)
        }
        return host(of: trimmed)
    }

    public static func host(of value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        for separator in ["/", "?", "#", ":"] {
            if let index = text.firstIndex(of: Character(separator)) {
                text = String(text[..<index])
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? value.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    /// Validates a bare IP or CIDR block and returns it with an explicit prefix length.
    public static func normalizeIPCIDR(_ item: String) -> String? {
        let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts[0].isEmpty else { return nil }
        let address = String(parts[0])
        var prefix: Int?
        if parts.count == 2 {
            guard let value = Int(parts[1]), value >= 0 else { return nil }
            prefix = value
        }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            let bits = prefix ?? 32
            guard bits <= 32 else { return nil }
            return "\(address)/\(bits)"
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            let bits = prefix ?? 128
            guard bits <= 128 else { return nil }
            return "\(address)/\(bits)"
        }
        return nil
    }
}

public enum NodeDelayIndex {
    /// Lowest reported URL-test delay per node tag across all live groups.
    public static func delays(in groups: [OutboundGroup]) -> [String: UInt16] {
        var result: [String: UInt16] = [:]
        for group in groups {
            for item in group.items {
                let delay = item.urlTestDelay
                guard delay > 0 else { continue }
                if let existing = result[item.tag] {
                    result[item.tag] = min(existing, delay)
                } else {
                    result[item.tag] = delay
                }
            }
        }
        return result
    }

    public static func best(_ members: [String], delays: [String: UInt16]) -> UInt16? {
        members.compactMap { delays[$0] }.filter { $0 > 0 }.min()
    }
}
