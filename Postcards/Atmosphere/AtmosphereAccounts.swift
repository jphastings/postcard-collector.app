import AuthenticationServices
import Foundation
import Observation
import OAuthenticator

/// The signed-in Atmosphere (atproto) accounts, keyed by DID and kept in the order they were
/// added. Signing in to an account that's already here refreshes its session and handle.
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

    private let store = KeychainAccountStore<AtmosphereSession>(service: "org.dotpostcard.collector.atproto")

    init() {
        reload()
    }

    func signIn(handle: String, openBrowser: @escaping Authenticator.UserAuthenticator) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }

        do {
            let session = try await AtmosphereOAuth.signIn(handle: handle, openBrowser: openBrowser)
            try store.save(session, for: session.did)
            reload()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The user closed the browser sheet.
        } catch {
            problem = Problem(title: "Couldn't Sign In", message: error.localizedDescription)
        }
    }

    /// Revokes server-side (best effort) and then forgets the account here.
    func signOut(_ session: AtmosphereSession) async {
        await AtmosphereOAuth.revoke(session)
        do {
            try store.remove(session.did)
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

    private func reload() {
        do {
            sessions = try store.all()
        } catch {
            problem = Problem(title: "Couldn't Load Accounts", message: error.localizedDescription)
        }
    }
}
