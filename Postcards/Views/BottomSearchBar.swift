import SwiftUI

/// macOS-only stand-in for `.searchable(text:prompt:)`: docks a search field to the
/// bottom of a content pane instead of the toolbar (see call sites in `CollectionGridView`,
/// `SinglePostcardsGridView`, `AllCollectionsView`), so the toolbar has room to breathe at
/// narrower content-column widths. iOS keeps the native `.searchable` treatment untouched.
///
/// Bind `text` to the pane's existing `searchText` — this view only presents the field;
/// the `.task(id: searchText)` search plumbing in each pane is unaffected.
struct BottomSearchBar: View {
    @Binding var text: String
    var prompt: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(fieldShape.fill(.regularMaterial))
        .overlay(fieldShape.strokeBorder(.quaternary, lineWidth: 1))
        .frame(maxWidth: 360)
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        // Hidden ⌘F shortcut focuses the field from anywhere in the pane, standing in for
        // the "Find" affordance `.searchable` gets for free from the toolbar on other platforms.
        .background(
            Button("Find") { isFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .buttonStyle(.plain)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    private var fieldShape: RoundedRectangle { RoundedRectangle(cornerRadius: 8) }
}

extension View {
    /// Applies `BottomSearchBar` as a bottom `safeAreaInset` bound to `text`. Grid/map
    /// content scrolls up to (and, thanks to the material background, visually under) the
    /// bar rather than being obscured by it.
    func bottomSearchBar(text: Binding<String>, prompt: String) -> some View {
        safeAreaInset(edge: .bottom) {
            BottomSearchBar(text: text, prompt: prompt)
        }
    }
}
