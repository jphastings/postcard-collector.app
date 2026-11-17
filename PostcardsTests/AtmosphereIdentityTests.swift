import XCTest

final class AtmosphereIdentityTests: XCTestCase {
    private func document(id: String = "did:plc:alice", aka: [String], services: String? = nil) -> Data {
        let aliases = aka.map { "\"\($0)\"" }.joined(separator: ",")
        let service = services ?? """
            {"id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": "https://pds.example.com"}
            """
        return Data("""
            {"id": "\(id)", "alsoKnownAs": [\(aliases)], "verificationMethod": [], "service": [
                {"id": "#bsky_notif", "type": "BskyNotificationService", "serviceEndpoint": {"uri": "https://x"}},
                \(service)
            ]}
            """.utf8)
    }

    func testDIDDocumentYieldsThePDSAndTheTypedHandle() throws {
        let identity = try IdentityResolver.identity(
            did: "did:plc:alice", typedHandle: "alice.example.com",
            document: document(aka: ["at://Alice.Example.com"])
        )
        XCTAssertEqual(identity, ResolvedIdentity(
            did: "did:plc:alice", handle: "alice.example.com", pdsURL: URL(string: "https://pds.example.com")!
        ))
    }

    func testHandleTheDocumentDoesNotClaimBackIsRejected() {
        XCTAssertThrowsError(try IdentityResolver.identity(
            did: "did:plc:alice", typedHandle: "mallory.example.com",
            document: document(aka: ["at://alice.example.com"])
        )) { error in
            XCTAssertEqual(error as? IdentityError, .handleMismatch(handle: "mallory.example.com", did: "did:plc:alice"))
        }
    }

    func testDocumentForAnotherDIDOrWithoutAPDSIsRejected() {
        XCTAssertThrowsError(try IdentityResolver.identity(
            did: "did:plc:alice", typedHandle: nil, document: document(id: "did:plc:bob", aka: [])
        ))
        XCTAssertThrowsError(try IdentityResolver.identity(
            did: "did:plc:alice", typedHandle: nil,
            document: document(aka: [], services: ##"{"id": "#other", "type": "Other", "serviceEndpoint": "https://x"}"##)
        )) { XCTAssertEqual($0 as? IdentityError, .noPDS("did:plc:alice")) }
    }

    func testTypedAccountsAreNormalised() {
        XCTAssertEqual(IdentityResolver.normalize("  @Alice.Bsky.Social "), "alice.bsky.social")
        XCTAssertEqual(IdentityResolver.normalize("did:plc:AbC"), "did:plc:AbC")
        XCTAssertFalse(IdentityResolver.looksLikeHandle("alice"))
        XCTAssertFalse(IdentityResolver.looksLikeHandle("alice.example.com/x"))
    }
}
