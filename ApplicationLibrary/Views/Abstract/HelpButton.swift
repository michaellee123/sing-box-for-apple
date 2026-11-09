import SwiftUI

public struct HelpTopic: Identifiable {
    public var id: String {
        title
    }

    public let title: String
    public let text: String

    public init(_ title: String, _ text: String) {
        self.title = title
        self.text = text
    }
}

public struct HelpButton: View {
    private let topics: [HelpTopic]
    @State private var isPresented = false

    public init(_ topics: [HelpTopic]) {
        self.topics = topics
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
        }
        .toolbarIconStyle()
        .help("查看说明")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            HelpPopover(topics: topics)
        }
    }
}

private struct HelpPopover: View {
    let topics: [HelpTopic]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(topics) { topic in
                    VStack(alignment: .leading, spacing: 6) {
                        if !topic.title.isEmpty {
                            Text(topic.title)
                                .font(.headline)
                        }
                        Text(topic.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        #if !os(tvOS)
                            .textSelection(.enabled)
                        #endif
                    }
                }
            }
            .padding(20)
        }
        .frame(maxHeight: 420)
        #if os(macOS)
            .frame(width: 380)
        #endif
    }
}

public extension View {
    /// Keeps the title bar height identical across pages that would otherwise have no trailing item.
    func helpToolbarButton(_ topics: [HelpTopic]) -> some View {
        toolbar {
            ToolbarItem(placement: .automatic) {
                HelpButton(topics)
            }
        }
    }
}