import SwiftUI

/// The watch companion app: Go-free, receiving `.postcards` collections from the iPhone
/// over WatchConnectivity (see `WatchLibrary`) rather than reading iCloud directly —
/// watchOS can't open iCloud Drive documents, so the phone is the only data source.
@main
struct WatchPostcardsApp: App {
    @State private var library: WatchLibrary

    init() {
        let library = WatchLibrary()
        _library = State(initialValue: library)
        // Activated here, at process launch, rather than from a view's `.task`: watchOS
        // launches the app in the background to hand over queued transfers (a pinned
        // collection streaming in), and a background launch never builds the UI — the
        // session's delegate has to exist from the first instant or those deliveries wait
        // until the app is next opened.
        library.start()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchCollectionListView(library: library)
            }
        }
        .backgroundTask(.watchConnectivity) {
            await library.waitForPendingContent()
        }
    }
}
