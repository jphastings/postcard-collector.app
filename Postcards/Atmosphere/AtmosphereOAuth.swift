import Foundation
import Jot
import OAuthenticator

/// How this app identifies itself to atproto authorization servers. There's no registration
/// step: the client_id *is* the URL of a public metadata document listing the redirect URI and
/// scope, which servers fetch on demand.
enum AtmosphereOAuthConfig {
    static let clientID = URL(string: "https://dotpostcard.org/collector/oauth-client-metadata.json")!
    /// atproto requires a native client's redirect scheme to be the client_id host reversed.
    static let redirectURI = URL(string: "org.dotpostcard:/oauth/callback")!
    static let callbackScheme = "org.dotpostcard"
    static let scope = "atproto repo:org.dotpostcard.follow"

    static var appCredentials: AppCredentials {
        AppCredentials(
            clientId: clientID.absoluteString,
            clientPassword: "",
            scopes: scope.split(separator: " ").map(String.init),
            callbackURL: redirectURI
        )
    }
}

/// Everything needed to keep talking to an account's PDS: who it is, where its data lives,
/// the OAuth tokens, and the DPoP key they're bound to. The authorization server's metadata is
/// kept so a refresh never has to repeat discovery.
struct AtmosphereSession: Codable, Identifiable {
    var did: String
    var handle: String?
    var pdsURL: URL
    var authorizationServer: ServerMetadata
    var login: Login
    var dpopKey: DPoPKey
    /// Set once the authorization server has rejected the refresh token; signing in again replaces
    /// the whole session.
    var needsSignIn: Bool?

    var id: String { did }
}

/// Signs in with atproto OAuth. OAuthenticator's `Bluesky` flow does PAR, PKCE, DPoP and nonce
/// retries; this adds what atproto layers around it: resolving the handle to a DID and PDS,
/// discovering the PDS's authorization server, and checking the token is for that DID.
enum AtmosphereOAuth {
    /// `openBrowser` gets the authorization URL and callback scheme and returns the callback
    /// URL; its errors (the user cancelling) are rethrown untouched.
    static func signIn(handle: String, openBrowser: @escaping Authenticator.UserAuthenticator) async throws -> AtmosphereSession {
        let identity = try await IdentityResolver.resolve(handle)
        let provider = URLSession.defaultProvider
        let server = try await discoverAuthorizationServer(for: identity.pdsURL, provider: provider)

        let key = DPoPKey.P256()
        let expectedDID = identity.did
        let tokenHandling = Bluesky.tokenHandling(
            account: identity.handle ?? identity.did,
            server: server,
            jwtGenerator: DPoPProofs.generator(for: key),
            validator: { response, _ in response.sub == expectedDID }
        )
        let authenticator = Authenticator(
            config: Authenticator.Configuration(
                appCredentials: AtmosphereOAuthConfig.appCredentials,
                loginStorage: nil,
                tokenHandling: tokenHandling,
                mode: .manualOnly,
                userAuthenticator: openBrowser
            ),
            urlLoader: provider
        )

        let login: Login
        do {
            login = try await authenticator.authenticate()
        } catch {
            throw OAuthError.fromAuthenticator(error)
        }
        return AtmosphereSession(
            did: identity.did,
            handle: identity.handle,
            pdsURL: identity.pdsURL,
            authorizationServer: server,
            login: login,
            dpopKey: key
        )
    }

    /// Revokes the session's refresh token (RFC 7009). Best effort and never throws: a missing
    /// endpoint, a network failure or a refusal mustn't stop the user signing out locally.
    static func revoke(_ session: AtmosphereSession) async {
        guard let refreshToken = session.login.refreshToken?.value,
              let issuerHost = URL(string: session.authorizationServer.issuer)?.host(),
              let endpoint = await revocationEndpoint(issuerHost: issuerHost)
        else { return }
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let form = [("token", refreshToken), ("client_id", AtmosphereOAuthConfig.clientID.absoluteString)]
            .map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        var request = URLRequest(url: endpoint, timeoutInterval: revocationTimeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Sign-out waits on revocation, so it mustn't be able to hang.
    private static let revocationTimeout: TimeInterval = 5

    /// OAuthenticator's `ServerMetadata` doesn't decode `revocation_endpoint`.
    private static func revocationEndpoint(issuerHost: String) async -> URL? {
        struct Metadata: Decodable { let revocation_endpoint: String }
        guard let url = URL(string: "https://\(issuerHost)/.well-known/oauth-authorization-server"),
              case let (data, response)? = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: revocationTimeout)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              let endpoint = URL(string: metadata.revocation_endpoint),
              // The refresh token is about to be POSTed here.
              endpoint.scheme == "https"
        else { return nil }
        return endpoint
    }

    /// The PDS's protected-resource document names its authorization server, whose own
    /// metadata must agree it is who it was fetched from.
    static func discoverAuthorizationServer(for pdsURL: URL, provider: @escaping URLResponseProvider) async throws -> ServerMetadata {
        guard let pdsHost = pdsURL.host() else { throw OAuthError.discoveryFailed(pdsURL.absoluteString) }
        guard let resource = try? await ProtectedResourceMetadata.load(for: pdsHost, provider: provider),
              let issuerHost = resource.authorizationServers?.first.flatMap({ URL(string: $0)?.host() })
        else { throw OAuthError.discoveryFailed(pdsHost) }

        guard let server = try? await ServerMetadata.load(for: issuerHost, provider: provider) else {
            throw OAuthError.discoveryFailed(issuerHost)
        }
        guard let issuer = URLComponents(string: server.issuer),
              issuer.scheme == "https",
              issuer.host?.lowercased() == issuerHost.lowercased(),
              issuer.path.isEmpty || issuer.path == "/",
              issuer.query == nil, issuer.fragment == nil
        else { throw OAuthError.issuerMismatch }
        return server
    }
}

/// DPoP proofs (RFC 9449): short-lived ES256 JWTs naming the request they accompany, signed
/// with the session's key, which they embed as a JWK. OAuthenticator works out the values.
enum DPoPProofs {
    struct Claims: JSONWebTokenPayload {
        let jti: String?
        let iat: Date?
        let htm: String?
        let htu: String?
        let nonce: String?
        let ath: String?
    }

    static func generator(for key: DPoPKey) -> DPoPSigner.JWTGenerator {
        { parameters in
            let privateKey = try key.p256PrivateKey
            let token = JSONWebToken(
                header: JSONWebTokenHeader(
                    algorithm: .ES256,
                    type: parameters.keyType,
                    jwk: JSONWebKey(p256Key: privateKey.publicKey)
                ),
                payload: Claims(
                    jti: UUID().uuidString,
                    iat: Date(),
                    htm: parameters.httpMethod,
                    htu: parameters.requestEndpoint,
                    nonce: parameters.nonce,
                    ath: parameters.tokenHash
                )
            )
            return try token.encode(with: privateKey)
        }
    }
}

enum OAuthError: LocalizedError, Equatable {
    case discoveryFailed(String)
    case issuerMismatch
    /// The browser came back with a callback that doesn't belong to this sign-in.
    case callbackRejected
    case subjectMismatch
    case authorizationServerRejected(String)
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case let .discoveryFailed(host):
            return "Couldn't find the sign-in settings for \(host)."
        case .issuerMismatch:
            return "The sign-in server didn't identify itself correctly, so the sign-in was cancelled for safety."
        case .callbackRejected:
            return "This sign-in response doesn't belong to the sign-in you started. Please try again."
        case .subjectMismatch:
            return "You signed in as a different account than the one you entered. Please try again."
        case let .authorizationServerRejected(reason):
            return "The sign-in server refused the request: \(reason)"
        case .sessionExpired:
            return "The sign-in expired before it finished. Please try again."
        }
    }

    /// Anything unrecognised (network failures, the user cancelling the browser) passes through
    /// so callers can inspect it.
    static func fromAuthenticator(_ error: Error) -> Error {
        guard let error = error as? AuthenticatorError else { return error }
        switch error {
        case .tokenInvalid:
            // How OAuthenticator reports our validator rejecting the token's `sub`.
            return OAuthError.subjectMismatch
        case .stateTokenMismatch, .issuingServerMismatch, .missingAuthorizationCode:
            return OAuthError.callbackRejected
        case let .invalidRequest(code, description), let .unrecognizedError(code, description):
            return OAuthError.authorizationServerRejected(description.isEmpty ? code : description)
        case let .dpopTokenExpected(type):
            return OAuthError.authorizationServerRejected("it issued a \(type) token instead of a DPoP one")
        case .invalidGrant, .manualAuthenticationRequired, .unauthorizedRefreshFailed, .refreshNotPossible, .missingRefreshToken:
            return OAuthError.sessionExpired
        default:
            return error
        }
    }
}
