import SwiftUI
import UniformTypeIdentifiers

/// A card's raw stored bytes (image + embedded XMP), handed to `.fileExporter` untouched —
/// exports must be byte-faithful, never a re-encode.
struct PostcardFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.image]

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Starts exporting a card to a file the user picks. Provided by `postcardExporting(openCard:)`.
struct ExportPostcardAction {
    fileprivate let export: (CardReference) -> Void

    func callAsFunction(_ reference: CardReference) { export(reference) }
}

extension EnvironmentValues {
    @Entry var exportPostcard: ExportPostcardAction?
}

extension FocusedValues {
    /// Exports the card open in the focused window; `nil` when no card is open.
    @Entry var exportOpenPostcard: (() -> Void)?
}

private struct PendingExport {
    var document: PostcardFileDocument
    var filename: String
    var contentType: UTType
}

private struct PostcardExporting: ViewModifier {
    let openCard: CardReference?

    @State private var pending: PendingExport?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .environment(\.exportPostcard, ExportPostcardAction(export: begin))
            .focusedSceneValue(\.exportOpenPostcard, openCard.map { card in { begin(card) } })
            .fileExporter(
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                document: pending?.document,
                contentType: pending?.contentType ?? .image,
                defaultFilename: pending?.filename
            ) { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
            }
            .alert(
                "Couldn't export postcard",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func begin(_ reference: CardReference) {
        Task {
            do {
                let data = try await GoCore.shared.image(for: reference)
                let summary = reference.summary
                pending = PendingExport(
                    document: PostcardFileDocument(data: data),
                    filename: PostcardExportNaming.exportFilename(
                        name: summary.name, filename: summary.filename, mimetype: summary.mimetype
                    ),
                    contentType: UTType(mimeType: summary.mimetype) ?? .image
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension View {
    /// Hosts card export for everything inside: the `exportPostcard` environment action (for
    /// context menus) and, for the File menu's Export…, `openCard` as the focused window's card.
    func postcardExporting(openCard: CardReference?) -> some View {
        modifier(PostcardExporting(openCard: openCard))
    }
}

/// File ▸ Export… (⇧⌘S) for the card open in the focused window.
struct ExportPostcardCommand: View {
    @FocusedValue(\.exportOpenPostcard) private var exportOpenPostcard

    var body: some View {
        Button("Export…") { exportOpenPostcard?() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(exportOpenPostcard == nil)
    }
}
