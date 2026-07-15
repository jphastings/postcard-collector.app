import SwiftUI

/// How far the sidebar's browsing region is shifted up (by `SidebarDestinationFill`) to bleed
/// under the transparent titlebar. The bottom search bar counter-shifts by the same amount so it
/// stays pinned to the sidebar's true bottom edge rather than floating this far above it.
enum SidebarBleed {
    static let inset: CGFloat = 52
}

/// macOS-only stand-in for `.searchable(text:tokens:suggestedTokens:...)`: docks a search
/// field — with Mail-style token pills — to the bottom of a content pane instead of the
/// toolbar (see call sites in `CollectionGridView`, `SinglePostcardsGridView`,
/// `AllCollectionsView`), so the toolbar has room to breathe at narrower content-column
/// widths. iOS keeps the native `.searchable` treatment untouched.
///
/// Bind `text`/`tokens` to the pane's existing `searchText`/`searchTokens` — this view only
/// presents the field; the `.task(id:)` search plumbing in each pane is unaffected. The
/// above-the-bar suggestions list is NOT rendered by this view — see
/// `BottomSearchBarModifier`'s doc comment for why it has to live outside this view's own
/// tree. The pill chip and suggestions-list rendering live in `SearchTokenPill.swift`, so
/// this file stays focused on the bar's layout, focus, and keyboard handling.
struct BottomSearchBar: View {
    @Binding var text: String
    @Binding var tokens: [SearchToken]
    var prompt: String
    /// Owned by `BottomSearchBarModifier`, which also drives the suggestions overlay from
    /// the same focus state — sharing it is what lets that overlay know when to show.
    var isFocused: FocusState<Bool>.Binding
    /// Set to `true` (e.g. right after a search preset lands) to move keyboard focus into
    /// the field; this view flips it back to `false` once it has done so, so it can be
    /// triggered again later.
    @Binding var focusRequest: Bool

    /// A token pill's height (measured from a hidden reference in `fieldContent`), used as the
    /// field's constant height so adding or removing tags never resizes it.
    @State private var pillHeight: CGFloat = 24

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
        .floatingGlassBackground(in: fieldShape)
        .overlay(fieldShape.strokeBorder(.quaternary, lineWidth: 1))
        .frame(maxWidth: 360)
        // Floats the field as its own glass capsule above the grid rather than a full-width
        // bar: no `.background` on this outer container, so the safeAreaInset it sits in
        // stays transparent and grid content scrolls visibly beneath/around it. Equal side and
        // bottom insets so the capsule sits symmetrically in the sidebar's corner.
        .padding([.horizontal, .bottom])
        .frame(maxWidth: .infinity)
        // Hidden ⌘F shortcut focuses the field from anywhere in the pane, standing in for
        // the "Find" affordance `.searchable` gets for free from the toolbar on other platforms.
        .background(
            Button("Find") { isFocused.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .buttonStyle(.plain)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .onChange(of: focusRequest) { _, requested in
            guard requested else { return }
            isFocused.wrappedValue = true
            focusRequest = false
        }
    }

    private var fieldContent: some View {
        // A plain HStack, not a horizontal ScrollView: the ScrollView was vertically greedy —
        // it filled the bottom safe-area inset (the ~3× height) and, once height-constrained,
        // swallowed the click that should focus the field. Tokens are few and fit the field's
        // width, so a plain row is single-line tall and the TextField stays directly focusable.
        HStack(spacing: 4) {
            ForEach(tokens) { token in
                SearchTokenChip(token: token) {
                    tokens.removeAll { $0.id == token.id }
                }
            }
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .frame(minWidth: 80)
                // Mail-style: backspace in an already-empty field deletes the last pill,
                // rather than doing nothing.
                .onKeyPress(.delete) {
                    guard text.isEmpty, !tokens.isEmpty else { return .ignored }
                    tokens.removeLast()
                    return .handled
                }
        }
        // Hold a constant height equal to a token pill's, so the field doesn't grow when the
        // first tag is added (or shrink when the last is removed). The height comes from a
        // hidden reference matching SearchTokenChip's own metrics rather than a magic number.
        .frame(height: pillHeight)
        .background(alignment: .leading) {
            Text(verbatim: "Ag")
                .font(.callout)
                .padding(.vertical, 4)
                .hidden()
                .accessibilityHidden(true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PillHeightPreferenceKey.self, value: proxy.size.height)
                })
        }
        .onPreferenceChange(PillHeightPreferenceKey.self) { pillHeight = $0 }
    }

    private var fieldShape: Capsule { Capsule() }
}

extension View {
    /// Real Liquid Glass on macOS 26+ (and iOS 26+, matching platforms); `.regularMaterial`
    /// beneath that OS floor, since `.glassEffect` doesn't exist there.
    @ViewBuilder
    func floatingGlassBackground(in shape: some Shape) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    /// Applies `BottomSearchBar` as a bottom `safeAreaInset`, plus its suggestions list as a
    /// separate overlay on the pane's own content — see `BottomSearchBarModifier`.
    func bottomSearchBar(
        text: Binding<String>,
        tokens: Binding<[SearchToken]>,
        suggestions: [SearchToken] = [],
        onPickSuggestion: @escaping (SearchToken) -> Void = { _ in },
        prompt: String,
        focusRequest: Binding<Bool> = .constant(false)
    ) -> some View {
        modifier(BottomSearchBarModifier(
            text: text,
            tokens: tokens,
            suggestions: suggestions,
            onPickSuggestion: onPickSuggestion,
            prompt: prompt,
            focusRequest: focusRequest
        ))
    }
}

/// Hosts `BottomSearchBar` in a bottom `safeAreaInset`, and the suggestions list as a
/// SEPARATE `.overlay` on the pane's own content, offset up by the field's own measured
/// height so its bottom edge always sits just above the field's top edge, growing upward.
///
/// The suggestions list used to live inside `BottomSearchBar`'s own view tree, as an
/// `.overlay(alignment: .top)` whose content flipped its own `.alignmentGuide` to grow
/// upward instead of down. That guide math was right, but `safeAreaInset` content is
/// bounded to its own laid-out frame — unlike a plain `.overlay`, it can't paint outside
/// those bounds — so the list was clipped at the inset's edge instead of floating freely
/// above it, which onscreen read as suggestions rendering below/at the field rather than
/// above it. Moving the list here, to a `.overlay` on the PANE's own content (a sibling of
/// the safeAreaInset, not nested inside it), removes that bound entirely: `safeAreaInset`
/// always renders its inset content flush against the given edge, so this overlay's
/// `alignment: .bottom` anchor is the one fixed point that's unambiguous regardless of how
/// `safeAreaInset` sizes its base content — the field's own bottom edge — and offsetting by
/// the field's measured height (reported via a `GeometryReader`/`PreferenceKey`, since the
/// field's real height can vary slightly by platform/dynamic type) plus a little spacing
/// lands the list's bottom exactly where it needs to be, with no risk of clipping.
private struct BottomSearchBarModifier: ViewModifier {
    @Binding var text: String
    @Binding var tokens: [SearchToken]
    var suggestions: [SearchToken]
    var onPickSuggestion: (SearchToken) -> Void
    var prompt: String
    @Binding var focusRequest: Bool

    @FocusState private var isFocused: Bool
    @State private var fieldHeight: CGFloat = 44

    private static let suggestionsSpacing: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                BottomSearchBar(
                    text: $text,
                    tokens: $tokens,
                    prompt: prompt,
                    isFocused: $isFocused,
                    focusRequest: $focusRequest
                )
                // Counter the browsing region's upward bleed offset (`SidebarDestinationFill`)
                // so the bar sits at the sidebar's true bottom edge, not floating above it.
                .offset(y: SidebarBleed.inset)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: FieldHeightPreferenceKey.self, value: proxy.size.height)
                    }
                )
            }
            .onPreferenceChange(FieldHeightPreferenceKey.self) { fieldHeight = $0 }
            .overlay(alignment: .bottom) {
                if isFocused, !suggestions.isEmpty {
                    SearchSuggestionsList(suggestions: suggestions, onPick: onPickSuggestion)
                        .offset(y: -(fieldHeight + Self.suggestionsSpacing))
                        .transition(.opacity)
                }
            }
    }
}

private struct FieldHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PillHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 24
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
