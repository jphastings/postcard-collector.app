import SwiftUI

/// One compact person line for "Create a Postcard" — `From:  [Name] | [https://…]` — a name
/// field with people autocomplete and a quieter, monospaced link field sharing the row.
/// Suggestions come from `PeopleSuggestions.matches` over whatever people the form loaded
/// (`GoCore.libraryPeople()`); picking one fills BOTH fields. Purely an autofill — both
/// fields stay freely editable afterward — and knows nothing about `CreatePostcardModel`
/// (mirrors `LocationSearchField`'s bindings-only contract, including its inline
/// suggestions-below-the-field pattern and arrow-key/return handling).
struct PersonFieldRow: View {
    let label: String
    @Binding var name: String
    @Binding var uri: String
    let people: [PersonRef]
    /// Orders matches, never filters them: "from" for a From row, "to" for To, "collector"
    /// for Catalogued by — see `PeopleSuggestions.matches(for:in:preferringRole:)`.
    let preferredRole: String

    @State private var suggestions: [PersonRef] = []
    @State private var highlightedIndex = 0
    // Selecting a suggestion writes into `name`, which would immediately re-trigger the
    // onChange search over the freshly-filled value — this one-shot flag swallows exactly
    // that echo (set only when the selection actually changes `name`, so it can't linger).
    @State private var suppressNextSearch = false
    @FocusState private var nameFieldIsFocused: Bool

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
                        suggestions = PeopleSuggestions.matches(for: newValue, in: people, preferringRole: preferredRole)
                    }
                    .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                    .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                    .onKeyPress(.return) { selectHighlighted() }
                Divider()
                    .frame(height: 14)
                TextField("\(label) link", text: $uri, prompt: Text("https://…"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            }
            if nameFieldIsFocused, !suggestions.isEmpty {
                suggestionsList
            }
        }
        .animation(.easeInOut(duration: 0.15), value: suggestions.isEmpty)
    }

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

    var body: some View {
        Form {
            Section {
                PersonFieldRow(
                    label: "From",
                    name: $name,
                    uri: $uri,
                    people: [
                        PersonRef(name: "Claire Smith", uri: "https://claire.example", roles: ["from"]),
                        PersonRef(name: "Clara Jones", uri: nil, roles: ["to"]),
                    ],
                    preferredRole: "from"
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 220)
    }
}

#Preview {
    PersonFieldRowPreviewHost()
}
#endif
