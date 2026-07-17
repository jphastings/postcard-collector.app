import SwiftUI

/// The one shared "this needs attention" treatment for "Create a Postcard"'s blocking-issue
/// fields: a small `exclamationmark.circle.fill` badge plus a subtle rounded red outline. Every
/// field a `CreatePostcardModel.CreateIssue` points at (see `CreatePostcardForm.blockingIssueToast`)
/// uses this same modifier, and the toast naming that issue uses the same icon/tint (`icon`/
/// `tint` below), so the two read as visually linked — defined once here rather than duplicated
/// per call site.
struct AttentionHighlight: ViewModifier {
    let active: Bool

    static let icon = "exclamationmark.circle.fill"
    static let tint = Color.red

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                if active {
                    Image(systemName: Self.icon)
                        .foregroundStyle(Self.tint)
                        .padding(.trailing, 4)
                        .transition(.opacity)
                }
            }
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Self.tint.opacity(0.6), lineWidth: 1.5)
                        .padding(.horizontal, -6)
                        .padding(.vertical, -4)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: active)
    }
}

extension View {
    /// Marks this view as the thing a blocking `CreatePostcardModel.CreateIssue` currently
    /// names — inert (no chrome at all) when `active` is false, so the highlight disappears the
    /// instant `model.blockingIssues` no longer contains that issue.
    func attentionHighlight(active: Bool) -> some View {
        modifier(AttentionHighlight(active: active))
    }
}
