import SwiftUI

/// The watch companion app: Go-free, reading `.postcards` collections directly with
/// `CollectionReader` over files synced through the same iCloud ubiquity container the
/// iOS/macOS app uses. Unlike the phone/Mac, the watch doesn't auto-download everything it
/// sees — only collections the user has explicitly pinned (see `PinStore`) — so
/// `shouldAutoDownload` is wired to the pin set instead of left at its always-download
/// default.
@main
struct WatchPostcardsApp: App {
    @State private var cloudLibrary = CloudLibrary()
    @State private var pinStore = PinStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchCollectionListView(cloudLibrary: cloudLibrary, pinStore: pinStore)
            }
            .task {
                cloudLibrary.shouldAutoDownload = { [pinStore] item in pinStore.isPinned(item.displayName) }
                await cloudLibrary.start()
            }
        }
    }
}
