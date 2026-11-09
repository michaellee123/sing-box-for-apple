import Library
import SwiftUI

struct PacketTunnelView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var isLoading = true
    @State private var alert: AlertState?

    @State private var includeAllNetworks = false
    @State private var excludeAPNs = false
    @State private var excludeCellularServices = false
    @State private var excludeLocalNetworks = false
    @State private var enforceRoutes = false
    @State private var excludeDeviceCommunication = false

    init() {}
    var body: some View {
        Group {
            if isLoading {
                ProgressView().onAppear {
                    Task {
                        await loadSettings()
                    }
                }
            } else {
                FormView {
                    #if !os(tvOS)
                        FormToggle("接管全部网络", """
                        开启后，除了维持设备正常工作所必需的系统服务，其余网络流量都会进入隧道。可以同时用「排除 Apple 推送」「排除本地网络」「排除蜂窝服务」把一部分流量留在隧道外。

                        开启后，TUN 会改用 go 协议栈。system、mixed 和 gvisor 在这个模式下不能用。
                        """, $includeAllNetworks) { newValue in
                            await SharedPreferences.includeAllNetworks.set(newValue)
                            await applySettings()
                        }

                        if #available(iOS 16.4, macOS 13.3, *) {
                            FormToggle("排除 Apple 推送", """
                            仅在「接管全部网络」开启时生效。开启后，系统会把 Apple 推送通知（APNs）流量排除在隧道之外。
                            """, $excludeAPNs) { newValue in
                                await SharedPreferences.excludeAPNs.set(newValue)
                                await applySettings()
                            }

                            FormToggle("排除蜂窝服务", """
                            仅在「接管全部网络」开启时生效。开启后，系统会排除 Wi-Fi 通话、彩信、短信和可视化语音留言等蜂窝服务。只走蜂窝网络的服务（例如 VoLTE）由系统自动排除，不受这项影响。
                            """, $excludeCellularServices) { newValue in
                                await SharedPreferences.excludeCellularServices.set(newValue)
                                await applySettings()
                            }
                        }

                        FormToggle("排除本地网络", """
                        仅在「接管全部网络」或「强制执行路由」开启时生效。开启后，系统会排除通往本地网络设备的连接，例如隔空播放、隔空投送和车载。
                        """, $excludeLocalNetworks) { newValue in
                            await SharedPreferences.excludeLocalNetworks.set(newValue)
                            await applySettings()
                        }

                        FormToggle("强制执行路由", """
                        在「接管全部网络」关闭时，开启这项会把需要进入 VPN 的路由限定在隧道内，把排除的路由留给当前主网络接口。它优先于系统路由表和应用自己的路由设置。

                        如果同时开启「排除本地网络」，通往本地网络设备的连接也会被排除。
                        """, $enforceRoutes) { newValue in
                            await SharedPreferences.enforceRoutes.set(newValue)
                            await applySettings()
                        }

                        if #available(iOS 17.4, macOS 14.4, *) {
                            FormToggle("排除设备通信", """
                            开启后，系统会排除设备之间的通信流量，例如同一 Apple 账户设备之间的直接通信。这项没有更详细的系统说明。
                            """, $excludeDeviceCommunication) { newValue in
                                await SharedPreferences.excludeDeviceCommunication.set(newValue)
                                await applySettings()
                            }
                        }

                    #endif

                    FormButton {
                        Task {
                            await SharedPreferences.resetPacketTunnel()
                            await applySettings()
                            isLoading = true
                        }
                    } label: {
                        Label("Reset", systemImage: "eraser.fill")
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Packet Tunnel")
        .alert($alert)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func applySettings() async {
        guard let profile = environments.extensionProfile else {
            return
        }
        if !profile.status.isConnected {
            do {
                try await profile.updateProtocolConfiguration()
            } catch {
                alert = AlertState(action: "update packet tunnel settings", error: error)
            }
            return
        }
        do {
            try await profile.restart()
        } catch {
            alert = AlertState(action: "restart service", error: error)
        }
    }

    @MainActor
    private func loadSettings() async {
        #if !os(tvOS)
            includeAllNetworks = await SharedPreferences.includeAllNetworks.get()
            excludeLocalNetworks = await SharedPreferences.excludeLocalNetworks.get()
            enforceRoutes = await SharedPreferences.enforceRoutes.get()
            if #available(iOS 16.4, macOS 13.3, *) {
                excludeAPNs = await SharedPreferences.excludeAPNs.get()
                excludeCellularServices = await SharedPreferences.excludeCellularServices.get()
            }
            if #available(iOS 17.4, macOS 14.4, *) {
                excludeDeviceCommunication = await SharedPreferences.excludeDeviceCommunication.get()
            }
        #endif
        isLoading = false
    }
}
