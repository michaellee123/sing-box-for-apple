import Foundation
import Security

public enum AppConfiguration {
    public static let packageName: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BasePackageIdentifier") as? String else {
            fatalError("Missing BasePackageIdentifier in Info.plist")
        }
        return value
    }()

    public static let appGroupID: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else {
            fatalError("Missing AppGroupIdentifier in Info.plist")
        }
        return value
    }()

    /// The app group name no longer carries the team prefix, so the team identifier has to come
    /// from the code signature. Every bundle that reads this is signed.
    public static let teamID: String = {
        let executable = Bundle.main.executableURL ?? Bundle.main.bundleURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            fatalError("Cannot inspect the code signature of \(executable.path)")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        else {
            fatalError("Missing team identifier in the code signature of \(executable.path)")
        }
        return team
    }()

    public static var extensionBundleID: String {
        "\(packageName).extension"
    }

    public static var systemExtensionBundleID: String {
        "\(packageName).system"
    }

    #if os(macOS)
        /// After a system-extension replace, launchd keeps the previous version's per-version provider job
        /// registered and still owning the NEMachServiceName endpoint; it refuses to let the new version
        /// reclaim a fixed endpoint name, so the app reaches the dead old listener. The version suffix gives
        /// each build its own endpoint. Must equal NEMachServiceName in SystemExtension/Info.plist, which is
        /// baked from $(APP_GROUP_IDENTIFIER).system.$(MARKETING_VERSION); Bundle.version is that same value.
        public static var systemExtensionMachServiceName: String {
            "\(appGroupID).system.\(Bundle.main.version)"
        }
    #endif

    public static var packetTunnelBundleIDs: [String] {
        if extensionBundleID == systemExtensionBundleID {
            return [extensionBundleID]
        }
        return [extensionBundleID, systemExtensionBundleID]
    }

    public static var fileProviderDomainID: String {
        "\(packageName).workingdir"
    }

    public static var widgetControlKind: String {
        "\(packageName).widget.ServiceToggle"
    }

    public static var profileUTType: String {
        "\(packageName).profile"
    }

    public static var backgroundTaskID: String {
        "\(packageName).update_profiles"
    }

    public static var iCloudContainerID: String {
        "iCloud.\(packageName)"
    }

    #if os(macOS) || JAILBREAK
        public static var rootHelperBundleID: String {
            "\(packageName).helper"
        }

        public static var rootHelperMachService: String {
            "\(appGroupID).helper"
        }
    #endif
}
