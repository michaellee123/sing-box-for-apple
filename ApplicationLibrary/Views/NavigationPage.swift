import Foundation
import Library
import SwiftUI

public enum NavigationPage: Int, CaseIterable, Identifiable {
    public var id: Self {
        self
    }

    case dashboard
    #if !os(tvOS)
        case groups
        case connections
    #endif
        case logs
        case tools
        case settings
        case advancedRouting
}

public extension NavigationPage {
    init?(snapshotValue: String) {
        switch snapshotValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dashboard":
            self = .dashboard
        case "logs":
            self = .logs
        case "tools":
            self = .tools
        case "settings":
            self = .settings
        case "routing", "advanced", "advancedrouting":
            self = .advancedRouting
        #if !os(tvOS)
            case "groups":
                self = .groups
            case "connections":
                self = .connections
        #endif
        default:
            return nil
        }
    }

    #if !os(tvOS)
        static var sidebarDefaultPages: [NavigationPage] {
            [.advancedRouting, .logs, .tools, .settings]
        }
    #endif

    static var tabPages: [NavigationPage] {
        [.dashboard, .advancedRouting, .logs, .tools, .settings]
    }

    var label: some View {
        Label(title, systemImage: iconImage)
            .tint(.textColor)
    }

    var title: String {
        switch self {
        case .dashboard:
            return String(localized: "Dashboard")
        #if !os(tvOS)
            case .groups:
                return String(localized: "Groups")
            case .connections:
                return String(localized: "Connections")
        #endif
        case .logs:
            return String(localized: "Logs")
        case .tools:
            return String(localized: "Tools")
        case .settings:
            return String(localized: "Settings")
        case .advancedRouting:
            return String(localized: "高级路由")
        }
    }

    private var iconImage: String {
        switch self {
        case .dashboard:
            return "text.and.command.macwindow"
        #if !os(tvOS)
            case .groups:
                return "rectangle.3.group.fill"
            case .connections:
                return "list.bullet.rectangle.portrait.fill"
        #endif
        case .logs:
            return "list.bullet.rectangle"
        case .tools:
            return "terminal.fill"
        case .settings:
            return "gear.circle.fill"
        case .advancedRouting:
            return "signpost.right.fill"
        }
    }

    @MainActor
    var contentView: some View {
        Group {
            switch self {
            case .dashboard:
                DashboardView()
            #if !os(tvOS)
                case .groups:
                    GroupListView()
                case .connections:
                    ConnectionListView()
            #endif
            case .logs:
                LogView()
            case .tools:
                ToolsView()
            case .settings:
                SettingView()
            case .advancedRouting:
                AdvancedRouteView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        #if os(iOS)
            .background(Color(uiColor: .systemGroupedBackground))
        #endif
    }

    #if !os(tvOS)
        @MainActor
        func visible(_ profile: ExtensionProfile?) -> Bool {
            switch self {
            case .groups:
                return false
            case .connections:
                return profile?.status.isConnectedStrict == true
            default:
                return true
            }
        }
    #endif
}
