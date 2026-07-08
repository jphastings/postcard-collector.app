import Foundation

/// The persisted set of "keep downloaded" collections, keyed by `CloudItem.displayName`
/// (stable and user-meaningful — unlike a container path, which isn't stable across
/// reinstalls). Purely about the persisted set: the actual
/// `startDownloadingUbiquitousItem`/`evictUbiquitousItem` side-effects live in the watch
/// UI layer, not here, so this stays trivially testable with an injected `UserDefaults`.
final class PinStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "pinnedCollections") {
        self.defaults = defaults
        self.key = key
    }

    var pinnedKeys: Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    func isPinned(_ key: String) -> Bool {
        pinnedKeys.contains(key)
    }

    func setPinned(_ pinned: Bool, for key: String) {
        var keys = pinnedKeys
        if pinned {
            keys.insert(key)
        } else {
            keys.remove(key)
        }
        defaults.set(Array(keys), forKey: self.key)
    }
}
