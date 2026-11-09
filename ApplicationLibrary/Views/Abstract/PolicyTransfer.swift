import SwiftUI
import UniformTypeIdentifiers

public struct PolicyJSONDocument: FileDocument {
    public static var readableContentTypes: [UTType] {
        [.json]
    }

    public var data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    public func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Drives the export/import file panels. The panels must live on the page body, not on
/// the toolbar item, because macOS hosts toolbar content outside the presenting hierarchy.
@MainActor
public final class PolicyTransferModel<Policy: Codable>: ObservableObject {
    @Published public var document: PolicyJSONDocument?
    @Published public var isExporting = false
    @Published public var isImporting = false

    private let name: String
    public var onImport: (Policy) -> Void = { _ in }
    public var onError: (String) -> Void = { _ in }

    public init(name: String) {
        self.name = name
    }

    public var filename: String {
        name
    }

    public func export(_ policy: Policy) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            document = PolicyJSONDocument(data: try encoder.encode(policy))
            isExporting = true
        } catch {
            onError(error.localizedDescription)
        }
    }

    public func handleExport(_ result: Result<URL, Error>) {
        document = nil
        if case let .failure(error) = result {
            onError(error.localizedDescription)
        }
    }

    public func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            read(url)
        case let .failure(error):
            onError(error.localizedDescription)
        }
    }

    private func read(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            onImport(try JSONDecoder().decode(Policy.self, from: data))
        } catch {
            onError("导入失败：\(error.localizedDescription)")
        }
    }
}

public struct PolicyTransferButtons<Policy: Codable>: View {
    @ObservedObject private var model: PolicyTransferModel<Policy>
    private let current: () -> Policy

    public init(_ model: PolicyTransferModel<Policy>, current: @escaping () -> Policy) {
        self.model = model
        self.current = current
    }

    public var body: some View {
        HStack(spacing: 2) {
            Button {
                model.export(current())
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .toolbarIconStyle()
            .help("导出为 JSON")
            Button {
                model.isImporting = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .toolbarIconStyle()
            .help("从 JSON 导入")
        }
    }
}

public extension View {
    func policyTransferPanels<Policy: Codable>(_ model: PolicyTransferModel<Policy>) -> some View {
        fileExporter(
            isPresented: Binding(get: { model.isExporting }, set: { model.isExporting = $0 }),
            document: model.document,
            contentType: .json,
            defaultFilename: model.filename,
            onCompletion: model.handleExport
        )
        .fileImporter(
            isPresented: Binding(get: { model.isImporting }, set: { model.isImporting = $0 }),
            allowedContentTypes: [.json],
            onCompletion: model.handleImport
        )
    }
}