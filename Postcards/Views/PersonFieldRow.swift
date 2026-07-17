import SwiftUI

/// One compact person line for "Create a Postcard" — `From:  [Name]  (link)` — a name field with
/// people autocomplete and a trailing link button. The button opens a popover to view/edit the
/// URL (tinted/filled once one is set, plain otherwise) rather than showing a second text field
/// inline, so the row stays a single field visually. Suggestions come from `directory.people`
/// (`PeopleDirectory`, merged from the local library and every downloaded iCloud collection);
/// picking one fills BOTH the name and the link. Purely an autofill — both stay freely editable
/// afterward — and knows nothing about `CreatePostcardModel` (mirrors `LocationSearchField`'s
/// bindings-only contract, including its inline suggestions-below-the-field pattern and
/// arrow-key/return handling).
struct PersonFieldRow: View {
    let label: String
    @Binding var name: String
    @Binding var uri: String
    let directory: PeopleDirectory
    /// Orders matches, never filters them: "from" for a From row, "to" for To, "collector"
    /// for Catalogued by — see `PeopleSuggestions.matches(for:in:preferringRole:)`.
    let preferredRole: String

    @State private var suggestions: [PersonRef] = []
    @State private var highlightedIndex = 0
    // Selecting a suggestion writes into `name`, which would immediately re-trigger the
    // onChange search over the freshly-filled value — this one-shot flag swallows exactly
    // that echo (set only when the selection actually changes `name`, so it can't linger).
    @State private var suppressNextSearch = false
    @State private var isPresentingLinkPopover = false
    @FocusState private var nameFieldIsFocused: Bool

    private var hasLink: Bool { !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(label):")
                    .foregroundStyle(.secondary)
                TextField("\(label) name", text: $name, prompt: Text("Name"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($nameFieldIsFocused)
                    .onChange(of: name) { _, newValue in
                        if suppressNextSearch {
                            suppressNextSearch = false
                            return
                        }
                        guard nameFieldIsFocused else { return }
                        highlightedIndex = 0
                        suggestions = PeopleSuggestions.matches(for: newValue, in: directory.people, preferringRole: preferredRole)
                    }
                    .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                    .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                    .onKeyPress(.return) { selectHighlighted() }
                linkButton
            }
            if nameFieldIsFocused, !suggestions.isEmpty {
                suggestionsList
            }
        }
        .animation(.easeInOut(duration: 0.15), value: suggestions.isEmpty)
    }

    // MARK: - Link button + popover

    private var linkButton: some View {
        Button {
            isPresentingLinkPopover = true
        } label: {
            Image(systemName: hasLink ? "link.circle.fill" : "link")
                .foregroundStyle(hasLink ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasLink ? "\(label) link set" : "Add \(label) link")
        .popover(isPresented: $isPresentingLinkPopover) {
            linkPopover
        }
    }

    private var linkPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(label) link")
                .font(.headline)
            TextField("https://…", text: $uri)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            Button("Remove Link", role: .destructive) {
                uri = ""
            }
            .disabled(!hasLink)
        }
        .padding()
        .frame(width: 260)
    }

    // MARK: - Suggestions

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, person in
                Button {
                    select(person)
                } label: {
                    suggestionRow(person, isHighlighted: index == highlightedIndex)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private func suggestionRow(_ person: PersonRef, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(person.name ?? "")
            if let uri = person.uri, !uri.isEmpty {
                Text(uri)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        highlightedIndex = max(0, min(suggestions.count - 1, highlightedIndex + delta))
        return .handled
    }

    private func selectHighlighted() -> KeyPress.Result {
        guard suggestions.indices.contains(highlightedIndex) else { return .ignored }
        select(suggestions[highlightedIndex])
        return .handled
    }

    /// Fills BOTH fields — a person suggestion is an identity, so accepting it replaces the
    /// link too (matching how `LocationSearchField` overwrites all its fields at once).
    private func select(_ person: PersonRef) {
        let newName = person.name ?? ""
        suppressNextSearch = name != newName
        name = newName
        uri = person.uri ?? ""
        suggestions = []
    }
}

#if DEBUG
/// `@Previewable @State` needs a macOS 15 floor, so this tiny host holds the bindings instead.
private struct PersonFieldRowPreviewHost: View {
    @State private var name = ""
    @State private var uri = ""
    private let directory = PeopleDirectory(
        cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("PersonFieldRowPreview-\(UUID().uuidString)"),
        fetchLibraryPeople: {
            [
                PersonRef(name: "Claire Smith", uri: "https://claire.example", roles: ["from"]),
                PersonRef(name: "Clara Jones", uri: nil, roles: ["to"]),
            ]
        }
    )

    var body: some View {
        Form {
            Section {
                PersonFieldRow(label: "From", name: $name, uri: $uri, directory: directory, preferredRole: "from")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 220)
        .task { await directory.refresh() }
    }
}

#Preview {
    PersonFieldRowPreviewHost()
}
#endif
