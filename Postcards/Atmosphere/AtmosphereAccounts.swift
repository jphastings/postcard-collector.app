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
    /// A failed sign-in or sign-out, for an alert.
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

    private func reload() {
        do {
            sessions = try store.all()
        } catch {
            problem = Problem(title: "Couldn't Load Accounts", message: error.localizedDescription)
        }
    }
}
