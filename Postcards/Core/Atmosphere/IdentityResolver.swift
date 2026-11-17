import Foundation

/// Where an atproto account lives: its permanent identifier, its handle and the PDS that hosts
/// its repository.
struct ResolvedIdentity: Equatable, Sendable {
    let did: String
    let handle: String?
    let pdsURL: URL
}

enum IdentityError: LocalizedError, Equatable {
    case emptyAccount
    case invalidHandle(String)
    case handleNotFound(String)
    case unsupportedDID(String)
    case didDocumentUnavailable(String)
    case invalidDIDDocument(String)
    case noPDS(String)
    /// The handle resolved to a DID whose document doesn't claim the handle back: either it was
    /// just moved, or someone is passing another account off as theirs. Both are refused.
    case handleMismatch(handle: String, did: String)

    var errorDescription: String? {
        switch self {
        case .emptyAccount:
            return "Enter your handle (like alice.bsky.social) to sign in."
        case let .invalidHandle(handle):
            return "“\(handle)” doesn't look like a handle. Handles look like alice.bsky.social."
        case let .handleNotFound(handle):
            return "Couldn't find an account for \(handle). Check the spelling and try again."
        case let .unsupportedDID(did):
            return "\(did) isn't a kind of account this app can sign in to."
        case let .didDocumentUnavailable(did):
            return "Couldn't look up the account \(did). Check your connection and try again."
        case let .invalidDIDDocument(did):
            return "The account record for \(did) couldn't be read."
        case let .noPDS(did):
            return "The account \(did) doesn't say where its data is stored, so it can't be used."
        case let .handleMismatch(handle, did):
            return "\(handle) points at \(did), but that account doesn't point back at \(handle). Try again in a moment; if this keeps happening the handle may have moved."
        }
    }
}

/// Turns a typed handle (or DID) into a DID, handle and PDS.
///
/// Handles resolve through Bluesky's public AppView (which does the DNS TXT lookup Apple
/// platforms have no convenient API for), falling back to the HTTPS well-known method. The
/// identity is only accepted when the DID document claims the handle back, so whoever answers
/// the first lookup can't spoof it.
enum IdentityResolver {
    static let resolveHandleURL = URL(string: "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle")!
    static let plcDirectory = URL(string: "https://plc.directory")!

    static func resolve(_ account: String, session: URLSession = .shared) async throws -> ResolvedIdentity {
        let account = normalize(account)
        guard !account.isEmpty else { throw IdentityError.emptyAccount }

        let did: String
        let typedHandle: String?
        if account.hasPrefix("did:") {
            did = account
            typedHandle = nil
        } else {
            guard looksLikeHandle(account) else { throw IdentityError.invalidHandle(account) }
            did = try await resolveHandle(account, session: session)
            typedHandle = account
        }

        let url = try documentURL(for: did)
        guard case let (document, response)? = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw IdentityError.didDocumentUnavailable(did)
        }
        return try identity(did: did, typedHandle: typedHandle, document: document)
    }

    /// Checks a fetched DID document against what was asked for and pulls out the PDS.
    static func identity(did: String, typedHandle: String?, document: Data) throws -> ResolvedIdentity {
        guard let document = try? JSONDecoder().decode(DIDDocument.self, from: document), document.id == did else {
            throw IdentityError.invalidDIDDocument(did)
        }
        let handles = document.alsoKnownAs
            .filter { $0.hasPrefix("at://") }
            .map { String($0.dropFirst("at://".count)).lowercased() }

        if let typedHandle, !handles.contains(typedHandle) {
            throw IdentityError.handleMismatch(handle: typedHandle, did: did)
        }

        guard let pds = document.service.first(where: {
            $0.id.hasSuffix("#atproto_pds") && $0.type == "AtprotoPersonalDataServer"
        }), let endpoint = pds.serviceEndpoint, let pdsURL = URL(string: endpoint), pdsURL.scheme == "https" else {
            throw IdentityError.noPDS(did)
        }
        return ResolvedIdentity(did: did, handle: typedHandle ?? handles.first, pdsURL: pdsURL)
    }

    /// Trims whitespace and a leading `@`; lower-cases handles (DIDs are case-sensitive).
    static func normalize(_ account: String) -> String {
        var trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@") { trimmed.removeFirst() }
        return trimmed.hasPrefix("did:") ? trimmed : trimmed.lowercased()
    }

    /// A handle is a hostname: at least one dot, no slashes or spaces.
    static func looksLikeHandle(_ handle: String) -> Bool {
        guard handle.contains("."), !handle.hasPrefix("."), !handle.hasSuffix(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return handle.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// `did:plc` documents live in the PLC directory, `did:web:host` ones at
    /// `https://host/.well-known/did.json` (atproto only allows the bare-host form).
    static func documentURL(for did: String) throws -> URL {
        if did.hasPrefix("did:plc:"), did.count > "did:plc:".count,
           let url = URL(string: "\(plcDirectory.absoluteString)/\(did)") {
            return url
        }
        if did.hasPrefix("did:web:") {
            let host = String(did.dropFirst("did:web:".count))
            if !host.isEmpty, !host.contains(":"), !host.contains("/"),
               let url = URL(string: "https://\(host)/.well-known/did.json") {
                return url
            }
        }
        throw IdentityError.unsupportedDID(did)
    }

    private static func resolveHandle(_ handle: String, session: URLSession) async throws -> String {
        var components = URLComponents(url: resolveHandleURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "handle", value: handle)]
        if case let (data, response)? = try? await session.data(from: components.url!),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let did = try? JSONDecoder().decode(ResolveHandleResponse.self, from: data).did,
           did.hasPrefix("did:") {
            return did
        }
        if let url = URL(string: "https://\(handle)/.well-known/atproto-did"),
           case let (data, response)? = try? await session.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            let did = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if did.hasPrefix("did:"), !did.contains("\n") { return did }
        }
        throw IdentityError.handleNotFound(handle)
    }
}

private struct ResolveHandleResponse: Decodable {
    let did: String
}

/// The parts of a DID document atproto cares about. Lenient about the rest: real documents carry
/// services this doesn't understand, whose `serviceEndpoint` may be an object.
private struct DIDDocument: Decodable {
    let id: String
    let alsoKnownAs: [String]
    let service: [Service]

    struct Service: Decodable {
        let id: String
        let type: String
        let serviceEndpoint: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(String.self, forKey: .id)) ?? ""
            type = (try? container.decode(String.self, forKey: .type)) ?? ""
            serviceEndpoint = try? container.decode(String.self, forKey: .serviceEndpoint)
        }

        enum CodingKeys: String, CodingKey { case id, type, serviceEndpoint }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        alsoKnownAs = try container.decodeIfPresent([String].self, forKey: .alsoKnownAs) ?? []
        service = try container.decodeIfPresent([Service].self, forKey: .service) ?? []
    }

    enum CodingKeys: String, CodingKey { case id, alsoKnownAs, service }
}
