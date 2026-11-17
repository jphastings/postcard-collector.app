import Foundation
import OAuthenticator

/// Authenticated XRPC calls to an account's own PDS, adapted from semble's `PDSClient`.
///
/// OAuthenticator adds the DPoP proof and `Authorization` header, retries when the PDS asks for a
/// fresh nonce, and refreshes an expired access token first. It never opens a browser: once the
/// refresh token itself is dead, calls throw `AtmospherePDSError.needsSignIn` and the stored
/// session is marked as needing sign-in again (see `LoginVault`).
struct AtmospherePDS {
    private let did: String
    private let pdsURL: URL
    private let vault: LoginVault
    private let authenticator: Authenticator

    init(session: AtmosphereSession, store: KeychainAccountStore<AtmosphereSession>) {
        did = session.did
        pdsURL = session.pdsURL
        let vault = LoginVault(session: session, store: store)
        self.vault = vault
        let expectedDID = session.did
        // OAuthenticator clears its storage whenever a refresh fails, even for want of a connection,
        // which would sign the user out for being offline. So clearing does nothing, and `post` marks
        // the session only when the server has rejected the refresh token.
        let storage = LoginStorage(
            retrieveLogin: { vault.retrieveLogin() },
            storeLogin: { try vault.update(login: $0) },
            clearLogin: {}
        )
        authenticator = Authenticator(
            config: Authenticator.Configuration(
                appCredentials: AtmosphereOAuthConfig.appCredentials,
                loginStorage: storage,
                tokenHandling: Bluesky.tokenHandling(
                    account: nil,
                    server: session.authorizationServer,
                    jwtGenerator: DPoPProofs.generator(for: session.dpopKey),
                    validator: { response, _ in response.sub == expectedDID }
                ),
                mode: .manualOnly,
                userAuthenticator: Authenticator.failingUserAuthenticator
            ),
            urlLoader: URLSession.defaultProvider
        )
    }

    /// `com.atproto.repo.createRecord`, letting the PDS assign the record key.
    func createRecord(collection: String, record: some Encodable) async throws {
        try await post("com.atproto.repo.createRecord", body: CreateRecordInput(repo: did, collection: collection, record: record))
    }

    /// `com.atproto.repo.deleteRecord` for the record at `uri`, which must be in this account's repo.
    func deleteRecord(uri: String) async throws {
        let parts = uri.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "at:", parts[2] == did else { throw AtmospherePDSError.notInRepo(uri) }
        try await post("com.atproto.repo.deleteRecord", body: DeleteRecordInput(repo: did, collection: parts[3], rkey: parts[4]))
    }

    private func post(_ nsid: String, body: some Encodable) async throws {
        var request = URLRequest(url: pdsURL.appending(path: "xrpc/\(nsid)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await authenticator.response(for: request)
        } catch let error as AuthenticatorError {
            switch error {
            case .invalidGrant, .manualAuthenticationRequired:
                vault.markNeedsSignInIfStillRejected()
                throw AtmospherePDSError.needsSignIn
            default:
                throw OAuthError.fromAuthenticator(error)
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(XRPCErrorBody.self, from: data)
            throw AtmospherePDSError.refused(body?.message ?? body?.error ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }
}

enum AtmospherePDSError: LocalizedError {
    case needsSignIn
    case notInRepo(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .needsSignIn:
            return "This account's sign-in has expired. Sign in to it again with Add Account."
        case let .notInRepo(uri):
            return "\(uri) isn't this account's record."
        case let .refused(reason):
            return "The server refused: \(reason)"
        }
    }
}

/// The live session shared with OAuthenticator's storage callbacks: the stored login is re-read
/// before each use (another request may have rotated it), and rotated tokens are written back.
private final class LoginVault: @unchecked Sendable {
    private let lock = NSLock()
    private var session: AtmosphereSession
    private let store: KeychainAccountStore<AtmosphereSession>
    /// The refresh token last handed to OAuthenticator, so a rejection can tell whether the
    /// Keychain has moved on to a newer one since.
    private var offeredRefreshToken: String?

    init(session: AtmosphereSession, store: KeychainAccountStore<AtmosphereSession>) {
        self.session = session
        self.store = store
    }

    func retrieveLogin() -> Login {
        lock.withLock {
            if let stored = try? store.value(for: session.did) { session = stored }
            offeredRefreshToken = session.login.refreshToken?.value
            return session.login
        }
    }

    func update(login: Login) throws {
        let updated = lock.withLock {
            // Kept even if saving fails: the old refresh token is already spent.
            session.login = login
            return session
        }
        try store.save(updated, for: updated.did)
    }

    /// Only when the Keychain still holds the rejected token; a newer one saved meanwhile is fine.
    func markNeedsSignInIfStillRejected() {
        lock.withLock {
            guard var stored = try? store.value(for: session.did),
                  stored.login.refreshToken?.value == offeredRefreshToken
            else { return }
            stored.needsSignIn = true
            try? store.save(stored, for: stored.did)
        }
    }
}

private struct CreateRecordInput<Record: Encodable>: Encodable {
    let repo: String
    let collection: String
    let record: Record
}

private struct DeleteRecordInput: Encodable {
    let repo: String
    let collection: String
    let rkey: String
}

private struct XRPCErrorBody: Decodable {
    let error: String?
    let message: String?
}
