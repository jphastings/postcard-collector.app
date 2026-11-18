import Foundation

/// An Atmosphere account the sidebar lists: signed in on this device, or only known (signed in on
/// another of the user's devices, or here until its session lapsed).
struct AtmosphereAccount: Identifiable, Equatable {
    let did: String
    let handle: String?
    /// Whether this device holds a session that can follow and unfollow as the account.
    let isSignedIn: Bool

    var id: String { did }
}

/// The accounts signed in on any of the user's devices, synced through iCloud as a small JSON
/// file. Only who they are travels: sessions stay in each device's Keychain, because atproto
/// refresh tokens are single-use and rotate, so devices sharing one would sign each other out.
///
/// A sign-out is kept as a tombstone, and every entry carries when it last changed, so any two
/// copies (this device's, iCloud's, iCloud's conflict versions) merge to the same list, and an
/// older copy that still lists an account can't undo its sign-out.
struct AtmosphereAccountList: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var did: String
        var handle: String?
        var signedOut: Bool
        var changed: Date
    }

    /// In the order the accounts were first added, signed-out ones included.
    // ponytail: tombstones are never pruned; a few dozen bytes per account ever signed out.
    private(set) var accounts: [Entry] = []

    /// Records a sign-in, refreshing the handle of an account already listed.
    mutating func signIn(did: String, handle: String?, at date: Date = .now) {
        upsert(Entry(did: did, handle: handle, signedOut: false, changed: date))
    }

    /// Records a sign-out, which takes the account off every device's list.
    mutating func signOut(did: String, at date: Date = .now) {
        let handle = accounts.first { $0.did == did }?.handle
        upsert(Entry(did: did, handle: handle, signedOut: true, changed: date))
    }

    /// Each account's most recent entry from either list, in this list's order and then `other`'s.
    func merged(with other: Self) -> Self {
        var result = self
        for entry in other.accounts {
            if let index = result.accounts.firstIndex(where: { $0.did == entry.did }) {
                if entry.changed > result.accounts[index].changed { result.accounts[index] = entry }
            } else {
                result.accounts.append(entry)
            }
        }
        return result
    }

    /// The DIDs among `local` (this device's sessions) that the list has signed out: another device
    /// signed them out after they were last signed in anywhere.
    func signedOutElsewhere(_ local: [String]) -> [String] {
        local.filter { did in accounts.contains { $0.did == did && $0.signedOut } }
    }

    /// Records this device's sessions that the list has never seen (those from before syncing) as
    /// signed in. When they were signed in isn't known, so by default they date from the distant
    /// past: any sign-in or sign-out another device has recorded wins over them.
    mutating func adopt(_ sessions: [(did: String, handle: String?)], at date: Date = .distantPast) {
        for session in sessions where !accounts.contains(where: { $0.did == session.did }) {
            signIn(did: session.did, handle: session.handle, at: date)
        }
    }

    /// What the sidebar lists: the list's accounts, then any of this device's sessions it doesn't
    /// know yet, once per DID. An account is signed in only where this device has a session that
    /// hasn't been rejected.
    func displayed(sessions: [(did: String, handle: String?, needsSignIn: Bool)]) -> [AtmosphereAccount] {
        var seen: Set<String> = []
        let listed = accounts.filter { !$0.signedOut }.map { entry in
            let session = sessions.first { $0.did == entry.did }
            return AtmosphereAccount(
                did: entry.did,
                handle: entry.handle ?? session?.handle,
                isSignedIn: session.map { !$0.needsSignIn } ?? false
            )
        }
        let unknown = sessions
            .filter { session in !accounts.contains { $0.did == session.did } }
            .map { AtmosphereAccount(did: $0.did, handle: $0.handle, isSignedIn: !$0.needsSignIn) }
        return (listed + unknown).filter { seen.insert($0.did).inserted }
    }

    private mutating func upsert(_ entry: Entry) {
        if let index = accounts.firstIndex(where: { $0.did == entry.did }) {
            accounts[index] = entry
        } else {
            accounts.append(entry)
        }
    }
}
