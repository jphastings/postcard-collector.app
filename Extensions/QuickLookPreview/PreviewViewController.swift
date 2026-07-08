import AppKit
import QuickLookUI
import SwiftUI

/// The macOS Quick Look preview extension's entry point. Hosts `QuickLookPreviewRoot` — the
/// same Go-free card/grid views the main app uses — in a plain `NSHostingView` pinned to
/// fill the preview panel. No nib: the view is built entirely in code.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var hostingView: NSHostingView<QuickLookPreviewRoot>?

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let hostingView = NSHostingView(rootView: QuickLookPreviewRoot(url: url))
        self.hostingView = hostingView

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
