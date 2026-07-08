import SwiftUI

/// Lists every `.postcards` collection visible in the iCloud container, pinned ones first.
/// Pinning (via the swipe action) keeps a collection downloaded — `shouldAutoDownload`
/// consults `pinStore` for exactly this — and can be undone to evict it again; everything
/// else stays remote until opened.
struct WatchCollectionListView: View {
    let cloudLibrary: CloudLibrary
    let pinStore: PinStore

    /// Mirrors `pinStore.pinnedKeys` in local `@State` so toggling a pin updates the list's
    /// sectioning/icon immediately — `PinStore` itself is a plain, testable persistence
    /// wrapper, not an `@Observable` model.
    @State private var pinnedKeys: Set<String>

    init(cloudLibrary: CloudLibrary, pinStore: PinStore) {
        self.cloudLibrary = cloudLibrary
        self.pinStore = pinStore
        _pinnedKeys = State(initialValue: pinStore.pinnedKeys)
    }

    private var collections: [CloudItem] {
        cloudLibrary.items.filter(\.isCollection)
    }

    private var pinned: [CloudItem] {
        collections
            .filter { pinnedKeys.contains($0.displayName) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var unpinned: [CloudItem] {
        collections.filter { !pinnedKeys.contains($0.displayName) }
    }

    var body: some View {
        List {
            if !pinned.isEmpty {
                Section("Kept Downloaded") {
                    ForEach(pinned, content: row)
                }
            }
            Section {
                ForEach(unpinned, content: row)
            }
        }
        .navigationTitle("Postcards")
        .navigationDestination(for: CloudItem.self) { item in
            WatchCollectionView(item: item)
        }
        .overlay {
            if collections.isEmpty {
                emptyOverlay
            }
        }
    }

    /// Distinguishes the reasons the list can be empty so a blank watch screen is
    /// diagnosable: still resolving the container, iCloud genuinely unavailable
    /// (not signed in / entitlement not granted on this device), or connected but no
    /// collections found (which points at discovery rather than connectivity).
    @ViewBuilder
    private var emptyOverlay: some View {
        switch cloudLibrary.containerState {
        case .resolving:
            ProgressView("Connecting to iCloud…")
        case .unavailable:
            ContentUnavailableView(
                "iCloud Unavailable",
                systemImage: "icloud.slash",
                description: Text("Sign in to iCloud and turn on iCloud Drive on your iPhone.")
            )
        case .available:
            ContentUnavailableView(
                "No Collections",
                systemImage: "square.stack",
                description: Text("Collections in iCloud Drive → Postcards will appear here.")
            )
        }
    }

    private func row(for item: CloudItem) -> some View {
        NavigationLink(value: item) {
            HStack {
                Text(item.displayName)
                Spacer()
                downloadIcon(for: item.downloadState)
            }
        }
        .swipeActions {
            pinButton(for: item)
        }
    }

    @ViewBuilder
    private func downloadIcon(for state: CloudItem.DownloadState) -> some View {
        switch state {
        case .current:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading:
            Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
        case .remote:
            Image(systemName: "icloud").foregroundStyle(.secondary)
        }
    }

    private func pinButton(for item: CloudItem) -> some View {
        let isPinned = pinnedKeys.contains(item.displayName)
        return Button {
            togglePin(for: item, pinned: !isPinned)
        } label: {
            Label(isPinned ? "Remove" : "Keep Downloaded", systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
        }
        .tint(isPinned ? .red : .accentColor)
    }

    private func togglePin(for item: CloudItem, pinned: Bool) {
        pinStore.setPinned(pinned, for: item.displayName)
        if pinned {
            pinnedKeys.insert(item.displayName)
            try? FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: item.path))
        } else {
            pinnedKeys.remove(item.displayName)
            try? FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: item.path))
        }
    }
}
