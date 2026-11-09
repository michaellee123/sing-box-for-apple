#if os(macOS)
    import AppKit
    import Foundation

    public struct InstalledApp: Hashable, Identifiable {
        public var bundlePath: String
        public var executableName: String
        public var displayName: String

        public var id: String {
            bundlePath
        }

        public var token: String {
            "bundle:\(bundlePath)"
        }
    }

    public enum InstalledAppIndex {
        private static let lock = NSRecursiveLock()
        private static var bundleByExecutable: [String: String] = [:]
        private static var nameByExecutable: [String: String] = [:]
        private static var loaded = false

        public static func runningApps() -> [InstalledApp] {
            loadIfNeeded()
            var seen = Set<String>()
            var apps: [InstalledApp] = []
            for application in NSWorkspace.shared.runningApplications {
                guard application.activationPolicy == .regular || application.activationPolicy == .accessory else { continue }
                guard let executableName = application.executableURL?.lastPathComponent, !executableName.isEmpty else { continue }
                guard let bundlePath = application.bundleURL?.path, seen.insert(bundlePath).inserted else { continue }
                let localized = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let displayName = localized.isEmpty ? FileManager.default.displayName(atPath: bundlePath) : localized
                apps.append(InstalledApp(bundlePath: bundlePath, executableName: executableName, displayName: displayName))
            }
            return apps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }

        public static func bundlePath(forExecutable name: String) -> String? {
            loadIfNeeded()
            lock.lock()
            defer { lock.unlock() }
            return bundleByExecutable[name]
        }

        public static func bundlePath(for pattern: String) -> String? {
            if pattern.hasPrefix("bundle:") {
                let path = String(pattern.dropFirst("bundle:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }
            if pattern.contains("/") {
                return nil
            }
            return bundlePath(forExecutable: pattern)
        }

        public static func displayName(for pattern: String) -> String {
            if let path = bundlePath(for: pattern) {
                loadIfNeeded()
                lock.lock()
                let executableName = bundleByExecutable.first { $0.value == path }?.key
                let cached = executableName.flatMap { nameByExecutable[$0] }
                lock.unlock()
                if let cached, !cached.isEmpty {
                    return cached
                }
                return FileManager.default.displayName(atPath: path)
            }
            return pattern
        }

        private static func loadIfNeeded() {
            lock.lock()
            defer { lock.unlock() }
            guard !loaded else { return }
            for application in NSWorkspace.shared.runningApplications {
                guard let executableName = application.executableURL?.lastPathComponent, !executableName.isEmpty else { continue }
                guard let bundlePath = application.bundleURL?.path else { continue }
                bundleByExecutable[executableName] = bundlePath
                let localized = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                nameByExecutable[executableName] = localized.isEmpty ? executableName : localized
            }
            let roots = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            ]
            for root in roots {
                scan(root, depth: 0, bundles: &bundleByExecutable, names: &nameByExecutable)
            }
            loaded = true
        }

        private static func scan(_ directory: URL, depth: Int, bundles: inout [String: String], names: inout [String: String]) {
            guard depth < 2, let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return
            }
            for url in children {
                if url.pathExtension == "app" {
                    register(url, bundles: &bundles, names: &names)
                    continue
                }
                var isDirectory = ObjCBool(false)
                guard depth == 0, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                scan(url, depth: 1, bundles: &bundles, names: &names)
            }
        }

        private static func register(_ bundleURL: URL, bundles: inout [String: String], names: inout [String: String]) {
            let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist"))
            let executable = (info?["CFBundleExecutable"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let executableName = (executable?.isEmpty == false ? executable! : bundleURL.deletingPathExtension().lastPathComponent)
            guard !executableName.isEmpty, bundles[executableName] == nil else { return }
            bundles[executableName] = bundleURL.path
            let display = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? executableName
            names[executableName] = display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? executableName : display
        }
    }
#endif
