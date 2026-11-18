import AuthenticationServices
import Foundation
import Observation
import OAuthenticator
import os

private let logger = Logger(subsystem: "org.dotpostcard.collector", category: "Atmosphere")

/// The Atmosphere (atproto) accounts: the sessions signed in on this device, keyed by DID and kept
/// in the order they were added, and the list of accounts signed in on any of the user's devices,
/// synced through iCloud (`AtmosphereAccountList`). Signing in to an account that's already here
/// refreshes its session and handle.
@MainActor
@Observable
final class AtmosphereAccounts {
    private(set) var sessions: [AtmosphereSession] = []
    private(set) var isSigningIn = false
    /// A failed sign-in, sign-out, follow or unfollow, for an alert.
    var problem: Problem?

    struct Problem {
        let title: String
        let message: String
    }

    /// Every account the sidebar lists, signed in here or not.
    var accounts: [AtmosphereAccount] {
        known.displayed(sessions: sessions.map { ($0.did, $0.handle, $0.needsSignIn == true) })
    }

    private var known: AtmosphereAccountList
    private let store = KeychainAccountStore<AtmosphereSession>(service: "org.dotpostcard.collector.atproto")

    // MARK: iCloud
    private let localListURL: URL
    private var cloudListURL: URL?
    private var query: NSMetadataQuery?
    /// Whether iCloud's copy of the list is downloaded, or absent, so it can be merged with.
    private var isCloudListReady = false
    private var cloudSync: Task<Void, Never>?

    init(localListURL: URL = AtmosphereAccounts.defaultLocalListURL) {
        self.localListURL = localListURL
        known = (try? Data(contentsOf: localListURL)).flatMap { try? JSONDecoder().decode(AtmosphereAccountList.self, from: $0) }
            ?? AtmosphereAccountList()
        reload()
    }

    func signIn(handle: String, openBrowser: @escaping Authenticator.UserAuthenticator) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }

        do {
            let session = try await AtmosphereOAuth.signIn(handle: handle, openBrowser: openBrowser)
            try store.save(session, for: session.did)
            known.signIn(did: session.did, handle: session.handle)
            reload()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The user closed the browser sheet.
        } catch {
            problem = Problem(title: "Couldn't Sign In", message: error.localizedDescription)
        }
    }

    /// Revokes this device's session server-side (best effort), forgets it here, and takes the
    /// account off the synced list, which signs it out on the user's other devices too.
    func signOut(did: String) async {
        if let session = sessions.first(where: { $0.did == did }) {
            await AtmosphereOAuth.revoke(session)
        }
        do {
            try store.remove(did)
            known.signOut(did: did)
            reload()
        } catch {
            problem = Problem(title: "Couldn't Sign Out", message: error.localizedDescription)
        }
    }

    /// Follows the collection at `address` (a typed or pasted at-uri) as the account `did`, once its
    /// record is found.
    func follow(_ address: String, as did: String) async {
        guard let session = sessions.first(where: { $0.did == did }) else { return }
        guard let uri = AtmosphereFollowing.collectionURI(from: address) else {
            problem = Problem(title: "Couldn't Follow", message: "That isn't a collection's address. They look like at://alice.example.com/org.dotpostcard.collection/…")
            return
        }
        let collection: AtprotoCollection
        do {
            collection = try await GoCore.shared.atprotoCollection(uri: uri)
        } catch {
            problem = Problem(title: "Couldn't Find That Collection", message: error.localizedDescription)
            return
        }
        await write("Couldn't Follow", as: session) {
            try await $0.createRecord(collection: AtprotoFollowRecord.type, record: AtprotoFollowRecord(subject: collection.uri))
        }
    }

    /// Deletes the follow records at `followURIs`, all in the account `did`'s repo.
    func unfollow(_ followURIs: [String], as did: String) async {
        guard let session = sessions.first(where: { $0.did == did }) else { return }
        await write("Couldn't Unfollow", as: session) { pds in
            for uri in followURIs { try await pds.deleteRecord(uri: uri) }
        }
    }

    private func write(_ failureTitle: String, as session: AtmosphereSession, _ body: (AtmospherePDS) async throws -> Void) async {
        do {
            try await body(AtmospherePDS(session: session, store: store))
        } catch {
            if case AtmospherePDSError.needsSignIn = error { reload() }
            let message = error.localizedDescription
            problem = Problem(title: failureTitle, message: session.handle.map { "@\($0): \(message)" } ?? message)
        }
    }

    /// Re-reads this device's sessions and brings them and the account list into line: sessions
    /// another device has signed out are signed out here, and ones the list has never seen join it.
    private func reload() {
        do {
            sessions = try store.all()
        } catch {
            problem = Problem(title: "Couldn't Load Accounts", message: error.localizedDescription)
            return
        }
        for did in known.signedOutElsewhere(sessions.map(\.did)) {
            guard let session = sessions.first(where: { $0.did == did }), (try? store.remove(did)) != nil else { continue }
            sessions.removeAll { $0.did == did }
            Task { await AtmosphereOAuth.revoke(session) }
        }
        known.adopt(sessions.map { ($0.did, $0.handle) })
        saveList()
    }

    // MARK: - The synced account list

    nonisolated static var defaultLocalListURL: URL {
        #if os(macOS)
        // Unsandboxed, so Application Support is shared with every other app.
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "org.dotpostcard.collector").appending(path: "atmosphere-accounts.json")
        #else
        URL.applicationSupportDirectory.appending(path: "atmosphere-accounts.json")
        #endif
    }

    private static let cloudListName = "AtmosphereAccounts.json"

    /// Starts syncing the account list through the iCloud ubiquity container at `container` (its
    /// root, which unlike its Documents folder isn't shown in iCloud Drive). Without one, the list
    /// stays on this device. Safe to call more than once.
    func startSyncing(container: URL?) {
        guard let container, query == nil else { return }
        cloudListURL = container.appending(path: Self.cloudListName)

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, Self.cloudListName)
        for name: Notification.Name in [.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cloudListChanged() }
            }
        }
        self.query = query
        query.start()
    }

    private func cloudListChanged() {
        guard let query, !query.isGathering, let cloudListURL else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        let item = query.results.first as? NSMetadataItem
        let status = item?.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
        isCloudListReady = item == nil || status == NSMetadataUbiquitousItemDownloadingStatusCurrent
        if isCloudListReady {
            syncWithCloud()
        } else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: cloudListURL)
        }
    }

    /// Keeps this device's copy (so an offline launch still knows the accounts) and merges it into
    /// iCloud's.
    private func saveList() {
        do {
            try FileManager.default.createDirectory(at: localListURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(known).write(to: localListURL, options: .atomic)
        } catch {
            logger.error("Saving the account list failed: \(error.localizedDescription, privacy: .public)")
        }
        syncWithCloud()
    }

    /// Merges this device's list and iCloud's both ways, one merge at a time. Each lands where it
    /// started, so a merge that changes nothing ends the round trip its own write sets off.
    private func syncWithCloud() {
        guard isCloudListReady, let cloudListURL else { return }
        cloudSync = Task { [previous = cloudSync] in
            await previous?.value
            let ours = known
            do {
                let merged = try await Task.detached(priority: .utility) {
                    try Self.mergeIntoCloudList(ours, at: cloudListURL)
                }.value
                let updated = merged.merged(with: known)
                guard updated != known else { return }
                known = updated
                reload()
            } catch {
                logger.error("Syncing the account list failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Merges `list` and any conflicting versions iCloud kept into the file at `url`, writing only
    /// if that changes it, and returns the result. Coordinated, as every iCloud file access must be.
    private nonisolated static func mergeIntoCloudList(_ list: AtmosphereAccountList, at url: URL) throws -> AtmosphereAccountList {
        var merged = AtmosphereAccountList()
        var failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { url in
            do {
                let decoder = JSONDecoder()
                // A file this version can't read is left alone rather than overwritten.
                let current = FileManager.default.fileExists(atPath: url.path)
                    ? try decoder.decode(AtmosphereAccountList.self, from: Data(contentsOf: url))
                    : AtmosphereAccountList()
                let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
                merged = current
                for version in conflicts {
                    if let data = try? Data(contentsOf: version.url),
                       let copy = try? decoder.decode(AtmosphereAccountList.self, from: data) {
                        merged = merged.merged(with: copy)
                    }
                }
                merged = merged.merged(with: list)
                if merged != current {
                    try JSONEncoder().encode(merged).write(to: url, options: .atomic)
                }
                for version in conflicts { version.isResolved = true }
                if !conflicts.isEmpty { try NSFileVersion.removeOtherVersionsOfItem(at: url) }
            } catch {
                failure = error
            }
        }
        if let error = coordinationError ?? failure { throw error }
        return merged
    }
}
