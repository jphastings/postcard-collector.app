import SwiftUI

/// One search-bar pill inside `BottomSearchBar`: `token.pillLabel` plus a small ✕ to remove
/// it. iOS renders its own native pills via `.searchable`'s `token:` builder (see the panes'
/// `.searchable` call sites) — this is the macOS-only stand-in.
struct SearchTokenChip: View {
    let token: SearchToken
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(token.pillLabel)
                .font(.callout)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.quaternary))
    }
}

/// The macOS suggestions list `BottomSearchBar` floats above the field while it's focused
/// and `SearchSuggestions.suggestions(...)` has candidates — tapping a row hands its token
/// back to `onPick`, which appends it as a pill and trims the typed fragment it came from.
struct SearchSuggestionsList: View {
    let suggestions: [SearchToken]
    let onPick: (SearchToken) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { token in
                if token.id != suggestions.first?.id {
                    Divider()
                }
                Button {
                    onPick(token)
                } label: {
                    Text(token.pillLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .floatingGlassBackground(in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
        .frame(maxWidth: 360)
        .shadow(radius: 4, y: 2)
    }
}

#if os(iOS)
/// `.searchFocused` needs iOS 18, one release past this app's iOS 17 floor — on 17 a search
/// preset still lands its pill, it just doesn't auto-focus the field. Gating here beats
/// raising the deployment target for one nicety.
struct SearchFocusedIfAvailable: ViewModifier {
    let binding: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.searchFocused(binding)
        } else {
            content
        }
    }
}
#endif
