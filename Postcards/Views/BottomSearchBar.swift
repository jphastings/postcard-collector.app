import SwiftUI

/// macOS-only stand-in for `.searchable(text:tokens:suggestedTokens:...)`: docks a search
/// field — with Mail-style token pills and an above-the-bar suggestions list — to the
/// bottom of a content pane instead of the toolbar (see call sites in `CollectionGridView`,
/// `SinglePostcardsGridView`, `AllCollectionsView`), so the toolbar has room to breathe at
/// narrower content-column widths. iOS keeps the native `.searchable` treatment untouched.
///
/// Bind `text`/`tokens` to the pane's existing `searchText`/`searchTokens` — this view only
/// presents the field; the `.task(id:)` search plumbing in each pane is unaffected. The pill
/// chip and suggestions-list rendering live in `SearchTokenPill.swift`, so this file stays
/// focused on the bar's layout, focus, and keyboard handling.
struct BottomSearchBar: View {
    @Binding var text: String
    @Binding var tokens: [SearchToken]
    var suggestions: [SearchToken] = []
    var onPickSuggestion: (SearchToken) -> Void = { _ in }
    var prompt: String
    /// Set to `true` (e.g. right after a search preset lands) to move keyboard focus into
    /// the field; this view flips it back to `false` once it has done so, so it can be
    /// triggered again later.
    @Binding var focusRequest: Bool

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            fieldContent
            if !text.isEmpty || !tokens.isEmpty {
                Button {
                    text = ""
                    tokens = []
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
        // The bar itself is docked to the screen bottom, so suggestions float UPWARD off
        // this field instead of downward: an `.overlay(alignment: .top)` whose content
        // flips its own alignment guide to sit entirely above the anchor, rather than
        // overlapping its top edge.
        .overlay(alignment: .top) {
            if isFocused, !suggestions.isEmpty {
                SearchSuggestionsList(suggestions: suggestions, onPick: onPickSuggestion)
                    .padding(.bottom, 8)
                    .alignmentGuide(.top) { $0[.bottom] }
            }
        }
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
        .onChange(of: focusRequest) { _, requested in
            guard requested else { return }
            isFocused = true
            focusRequest = false
        }
    }

    private var fieldContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tokens) { token in
                    SearchTokenChip(token: token) {
                        tokens.removeAll { $0.id == token.id }
                    }
                }
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .frame(minWidth: 80)
                    // Mail-style: backspace in an already-empty field deletes the last pill,
                    // rather than doing nothing.
                    .onKeyPress(.delete) {
                        guard text.isEmpty, !tokens.isEmpty else { return .ignored }
                        tokens.removeLast()
                        return .handled
                    }
            }
        }
    }

    private var fieldShape: RoundedRectangle { RoundedRectangle(cornerRadius: 8) }
}

extension View {
    /// Applies `BottomSearchBar` as a bottom `safeAreaInset` bound to `text`/`tokens`.
    /// Grid/map content scrolls up to (and, thanks to the material background, visually
    /// under) the bar rather than being obscured by it.
    func bottomSearchBar(
        text: Binding<String>,
        tokens: Binding<[SearchToken]>,
        suggestions: [SearchToken] = [],
        onPickSuggestion: @escaping (SearchToken) -> Void = { _ in },
        prompt: String,
        focusRequest: Binding<Bool> = .constant(false)
    ) -> some View {
        safeAreaInset(edge: .bottom) {
            BottomSearchBar(
                text: text,
                tokens: tokens,
                suggestions: suggestions,
                onPickSuggestion: onPickSuggestion,
                prompt: prompt,
                focusRequest: focusRequest
            )
        }
    }
}
