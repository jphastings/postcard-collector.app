import SwiftUI

/// The watch companion app: Go-free, receiving `.postcards` collections from the iPhone
/// over WatchConnectivity (see `WatchLibrary`) rather than reading iCloud directly —
/// watchOS can't open iCloud Drive documents, so the phone is the only data source.
@main
struct WatchPostcardsApp: App {
    @State private var library = WatchLibrary()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchCollectionListView(library: library)
            }
            .task { library.start() }
        }
    }
}
