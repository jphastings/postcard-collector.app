import Foundation

/// An org.dotpostcard.follow record, as written to the follower's repo.
struct AtprotoFollowRecord: Encodable, Equatable {
    static let type = "org.dotpostcard.follow"

    /// The followed org.dotpostcard.collection's at-uri.
    let subject: String
    let createdAt: String

    init(subject: String, createdAt: Date = .now) {
        self.subject = subject
        self.createdAt = createdAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.type, forKey: .type)
        try container.encode(subject, forKey: .subject)
        try container.encode(createdAt, forKey: .createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "$type"
        case subject, createdAt
    }
}

/// A context-menu item following or unfollowing a collection as one signed-in account.
struct AtmosphereFollowAction: Equatable {
    let title: String
    let did: String
    /// The follow records unfollowing deletes (every one, should an account follow it twice);
    /// empty for a follow.
    let followURIs: [String]
}

/// Who follows what, across the signed-in accounts.
enum AtmosphereFollowing {
    /// Every followed collection's at-uri once, however many accounts follow it, in the order
    /// the accounts (in turn) follow them.
    static func subjects(followedBy follows: [[AtprotoFollow]]) -> [String] {
        var seen: Set<String> = []
        return follows.joined().map(\.subject).filter { seen.insert($0).inserted }
    }

    /// The accounts (DIDs, in order) that could follow the collection at `uri`: those not already
    /// following it, apart from its owner, who may but needn't be offered it. Titled by handle
    /// only when there's more than one account to choose from.
    static func followActions(
        for uri: String, accounts: [String], handles: [String: String], follows: [String: [AtprotoFollow]]
    ) -> [AtmosphereFollowAction] {
        accounts
            .filter { $0 != AtmosphereCache.owner(of: uri) && !(follows[$0] ?? []).contains { $0.subject == uri } }
            .map { AtmosphereFollowAction(title: accounts.count > 1 ? "Follow as @\(handles[$0] ?? $0)" : "Follow", did: $0, followURIs: []) }
    }

    /// The accounts following the collection at `uri`, titled by handle only when several do.
    static func unfollowActions(
        for uri: String, accounts: [String], handles: [String: String], follows: [String: [AtprotoFollow]]
    ) -> [AtmosphereFollowAction] {
        let following = accounts.compactMap { did -> (String, [String])? in
            let uris = (follows[did] ?? []).filter { $0.subject == uri }.map(\.uri)
            return uris.isEmpty ? nil : (did, uris)
        }
        return following.map { did, uris in
            AtmosphereFollowAction(title: following.count > 1 ? "Unfollow as @\(handles[did] ?? did)" : "Unfollow", did: did, followURIs: uris)
        }
    }

    /// A typed or pasted org.dotpostcard.collection at-uri, trimmed, or `nil` when it isn't one.
    /// Its authority may be a DID or a handle.
    static func collectionURI(from typed: String) -> String? {
        let uri = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = uri.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "at:", parts[1].isEmpty, parts[3] == AtmosphereCache.collectionNSID,
              AtmosphereCache.isDID(parts[2]) || IdentityResolver.looksLikeHandle(parts[2]),
              AtmosphereCache.rkey(of: uri) != nil
        else { return nil }
        return uri
    }
}
