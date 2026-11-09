#if os(macOS)
    import AppKit
    import Library
    import SwiftUI

    struct ProcessIconGrid: View {
        let patterns: [String]
        var onRemove: ((String) -> Void)?

        private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 10)]

        var body: some View {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(patterns, id: \.self) { pattern in
                    cell(pattern)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        private func cell(_ pattern: String) -> some View {
            VStack(spacing: 6) {
                Image(nsImage: ProcessIcon.image(for: pattern))
                    .resizable()
                    .frame(width: 44, height: 44)
                Text(InstalledAppIndex.displayName(for: pattern))
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 96)
            .glassSurface(cornerRadius: 10)
            .overlay(alignment: .topTrailing) {
                if let onRemove {
                    Button {
                        onRemove(pattern)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }
        }
    }

    struct RunningAppPicker: View {
        @Environment(\.dismiss) private var dismiss
        @Binding var values: [String]
        let onCommit: () -> Void
        @State private var apps: [InstalledApp] = []
        @State private var selected: Set<String> = []
        @State private var query = ""

        private var filteredApps: [InstalledApp] {
            let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty else { return apps }
            return apps.filter { app in
                app.displayName.localizedCaseInsensitiveContains(keyword)
                    || app.executableName.localizedCaseInsensitiveContains(keyword)
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("已选 \(selected.count) 个")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("全选") {
                        selected.formUnion(filteredApps.map(\.token))
                    }
                    .disabled(filteredApps.isEmpty)
                    Button("反选") {
                        let tokens = Set(filteredApps.map(\.token))
                        selected = selected.subtracting(tokens).union(tokens.subtracting(selected))
                    }
                    .disabled(filteredApps.isEmpty)
                    Button("完成") {
                        applySelection()
                        onCommit()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(apps.isEmpty && selected.isEmpty)
                }
                .padding(.horizontal, 20)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索应用名或进程名", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .glassInteractive(cornerRadius: 8)
                .padding(.horizontal, 20)

                if apps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "macwindow")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("没有正在运行的应用")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredApps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("没有匹配的应用")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 140), spacing: 12)], spacing: 12) {
                            ForEach(filteredApps) { app in
                                appCell(app)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
            .frame(minWidth: 640, minHeight: 460)
            .onAppear {
                apps = InstalledAppIndex.runningApps()
                selected = Set(apps.filter { app in
                    values.contains(app.token) || values.contains(app.executableName) || values.contains("bundle:\(app.bundlePath)")
                }.map(\.token))
            }
        }

        private func appCell(_ app: InstalledApp) -> some View {
            let isSelected = selected.contains(app.token)
            return Button {
                if isSelected {
                    selected.remove(app.token)
                } else {
                    selected.insert(app.token)
                }
            } label: {
                VStack(spacing: 6) {
                    Image(nsImage: ProcessIcon.image(for: app.token))
                        .resizable()
                        .frame(width: 48, height: 48)
                    Text(app.displayName)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(app.executableName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 120)
                .glassInteractive(cornerRadius: 10, tint: isSelected ? .accentColor : nil)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(6)
                }
            }
            .buttonStyle(.plain)
        }

        private func applySelection() {
            let managed = Set(apps.flatMap { [$0.token, $0.executableName, "bundle:\($0.bundlePath)"] })
            var next = values.filter { !managed.contains($0) }
            for app in apps where selected.contains(app.token) {
                next.append(app.token)
            }
            values = next
        }
    }

    enum ProcessIcon {
        static func image(for pattern: String) -> NSImage {
            if let path = InstalledAppIndex.bundlePath(for: pattern) {
                return NSWorkspace.shared.icon(forFile: path)
            }
            return NSImage(named: NSImage.applicationIconName) ?? NSImage()
        }
    }
#endif
