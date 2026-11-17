import SwiftUI

/// Asks before upgrading an outdated collection's format (see `GoCore.migrateCollection`).
/// When other collections are outdated too, an "All collections" checkbox above Upgrade
/// covers them in one go.
struct UpgradeCollectionDialog: View {
    let offersAll: Bool
    let onUpgrade: (_ all: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var all = false

    var body: some View {
        MessageAboveButtons(minWidth: 260, spacing: 20) {
            Text("This collection is in an old format. Do you want to upgrade the collection, without losing any data?")
            HStack(alignment: .bottom) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 24)
                VStack(alignment: .leading, spacing: 10) {
                    if offersAll {
                        Toggle("All collections", isOn: $all)
                            #if os(macOS)
                            .toggleStyle(.checkbox)
                            #endif
                            // Text flush with the button's edge reads as overhanging it.
                            .padding(.trailing, 6)
                    }
                    Button {
                        onUpgrade(all)
                        dismiss()
                    } label: {
                        // Stretches to the checkbox's width; the stack itself takes only the
                        // widest of the two at their natural sizes.
                        Text("Upgrade").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .fixedSize()
            }
        }
        .padding(20)
    }
}

/// Lays out a message above a row of buttons: the dialog is as wide as the buttons need (at
/// least `minWidth`), and the message wraps to that width rather than setting it.
private struct MessageAboveButtons: Layout {
    let minWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (message, buttons) = sizes(of: subviews)
        return CGSize(width: max(message.width, buttons.width), height: message.height + spacing + buttons.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (message, buttons) = sizes(of: subviews)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(message))
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + message.height + spacing),
            proposal: ProposedViewSize(width: bounds.width, height: buttons.height)
        )
    }

    private func sizes(of subviews: Subviews) -> (message: CGSize, buttons: CGSize) {
        let buttons = subviews[1].sizeThatFits(.unspecified)
        let width = max(minWidth, buttons.width)
        let message = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return (CGSize(width: width, height: message.height), CGSize(width: width, height: buttons.height))
    }
}
