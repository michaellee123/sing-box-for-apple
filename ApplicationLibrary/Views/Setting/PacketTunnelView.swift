import Library
import SwiftUI

struct PacketTunnelView: View {
    var body: some View {
        FormView {
            Section {
                Text("隧道参数已固定，无法调整。")
                    .foregroundStyle(.secondary)
            }

            #if !os(tvOS)
                FormToggle("接管全部网络", """
                开启后，除了维持设备正常工作所必需的系统服务，其余网络流量都会进入隧道。可以同时用「排除 Apple 推送」「排除本地网络」「排除蜂窝服务」把一部分流量留在隧道外。

                开启后，TUN 会改用 go 协议栈。system、mixed 和 gvisor 在这个模式下不能用。
                """, .constant(FixedPacketTunnelSettings.includeAllNetworks)) { _ in }
                    .disabled(true)

                if #available(iOS 16.4, macOS 13.3, *) {
                    FormToggle("排除 Apple 推送", """
                    仅在「接管全部网络」开启时生效。开启后，系统会把 Apple 推送通知（APNs）流量排除在隧道之外。
                    """, .constant(FixedPacketTunnelSettings.excludeAPNs)) { _ in }
                        .disabled(true)

                    FormToggle("排除蜂窝服务", """
                    仅在「接管全部网络」开启时生效。开启后，系统会排除 Wi-Fi 通话、彩信、短信和可视化语音留言等蜂窝服务。只走蜂窝网络的服务（例如 VoLTE）由系统自动排除，不受这项影响。
                    """, .constant(FixedPacketTunnelSettings.excludeCellularServices)) { _ in }
                        .disabled(true)
                }

                FormToggle("排除本地网络", """
                仅在「接管全部网络」或「强制执行路由」开启时生效。开启后，系统会排除通往本地网络设备的连接，例如隔空播放、隔空投送和车载。
                """, .constant(FixedPacketTunnelSettings.excludeLocalNetworks)) { _ in }
                    .disabled(true)

                FormToggle("强制执行路由", """
                在「接管全部网络」关闭时，开启这项会把需要进入 VPN 的路由限定在隧道内，把排除的路由留给当前主网络接口。它优先于系统路由表和应用自己的路由设置。

                如果同时开启「排除本地网络」，通往本地网络设备的连接也会被排除。
                """, .constant(FixedPacketTunnelSettings.enforceRoutes)) { _ in }
                    .disabled(true)

                if #available(iOS 17.4, macOS 14.4, *) {
                    FormToggle("排除设备通信", """
                    开启后，系统会排除设备之间的通信流量，例如同一 Apple 账户设备之间的直接通信。这项没有更详细的系统说明。
                    """, .constant(FixedPacketTunnelSettings.excludeDeviceCommunication)) { _ in }
                        .disabled(true)
                }
            #endif
        }
        .navigationTitle("隧道")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
