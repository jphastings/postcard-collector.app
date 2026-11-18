import XCTest

final class AtmosphereFollowingTests: XCTestCase {
    private let unsent = "at://did:web:unsent.byjp.me/org.dotpostcard.collection/unsent"
    private let summer = "at://did:plc:alice/org.dotpostcard.collection/3lbq2xxbkzk2c"
    private let byjp = "did:plc:byjp"
    private let unsentAccount = "did:web:unsent.byjp.me"
    private let handles = ["did:plc:byjp": "byjp.me", "did:web:unsent.byjp.me": "unsent.byjp.me"]

    private func follow(_ subject: String, by did: String, rkey: String = "3lfollow") -> AtprotoFollow {
        AtprotoFollow(uri: "at://\(did)/org.dotpostcard.follow/\(rkey)", subject: subject, createdAt: "2026-11-17T00:00:00Z")
    }

    func testACollectionFollowedByTwoAccountsIsListedOnce() {
        let subjects = AtmosphereFollowing.subjects(followedBy: [
            [follow(unsent, by: byjp), follow(summer, by: byjp, rkey: "2")],
            [follow(unsent, by: unsentAccount)],
        ])
        XCTAssertEqual(subjects, [unsent, summer])
    }

    func testCacheIsKeptWhileAnyAccountOwnsOrFollowsIt() {
        XCTAssertTrue(AtmosphereCache.keepsCache(of: unsent, accounts: [unsentAccount, byjp], followed: []), "owned")
        XCTAssertTrue(AtmosphereCache.keepsCache(of: unsent, accounts: [byjp], followed: [unsent]), "owner signed out, still followed")
        XCTAssertFalse(AtmosphereCache.keepsCache(of: unsent, accounts: [byjp], followed: [summer]), "neither")
    }

    func testFollowRecord() throws {
        let record = AtprotoFollowRecord(subject: unsent, createdAt: Date(timeIntervalSince1970: 1_800_000_000.25))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: String]
        XCTAssertEqual(json, [
            "$type": "org.dotpostcard.follow",
            "subject": unsent,
            "createdAt": "2027-01-15T08:00:00.250Z",
        ])
    }

    func testFollowAddresses() {
        XCTAssertEqual(AtmosphereFollowing.collectionURI(from: " \(unsent)\n"), unsent)
        XCTAssertEqual(AtmosphereFollowing.collectionURI(from: "at://unsent.byjp.me/org.dotpostcard.collection/unsent"), "at://unsent.byjp.me/org.dotpostcard.collection/unsent")
        XCTAssertNil(AtmosphereFollowing.collectionURI(from: "at://did:web:unsent.byjp.me/org.dotpostcard.postcard/unsent"), "not a collection")
        XCTAssertNil(AtmosphereFollowing.collectionURI(from: "https://unsent.byjp.me/org.dotpostcard.collection/unsent"))
        XCTAssertNil(AtmosphereFollowing.collectionURI(from: "at://did:web:unsent.byjp.me/org.dotpostcard.collection/"))
        XCTAssertNil(AtmosphereFollowing.collectionURI(from: "at://did:web:unsent.byjp.me/org.dotpostcard.collection/unsent/extra"))
        XCTAssertNil(AtmosphereFollowing.collectionURI(from: "at://not a handle/org.dotpostcard.collection/unsent"))
    }

    func testOneAccountIsOfferedPlainFollowAndUnfollow() {
        let accounts = [byjp]
        XCTAssertEqual(AtmosphereFollowing.followActions(for: unsent, accounts: accounts, handles: handles, follows: [:]).map(\.title), ["Follow"])

        let following = [byjp: [follow(unsent, by: byjp)]]
        XCTAssertEqual(AtmosphereFollowing.followActions(for: unsent, accounts: accounts, handles: handles, follows: following), [])
        XCTAssertEqual(
            AtmosphereFollowing.unfollowActions(for: unsent, accounts: accounts, handles: handles, follows: following),
            [AtmosphereFollowAction(title: "Unfollow", did: byjp, followURIs: ["at://did:plc:byjp/org.dotpostcard.follow/3lfollow"])]
        )
    }

    func testSeveralAccountsAreNamedAndTheOwnerIsntOfferedItsOwn() {
        let accounts = [unsentAccount, byjp]
        XCTAssertEqual(AtmosphereFollowing.followActions(for: unsent, accounts: accounts, handles: handles, follows: [:]).map(\.title), ["Follow as @byjp.me"])
        XCTAssertEqual(AtmosphereFollowing.followActions(for: summer, accounts: accounts, handles: handles, follows: [:]).map(\.title), ["Follow as @unsent.byjp.me", "Follow as @byjp.me"])

        let onlyByjp = [byjp: [follow(unsent, by: byjp)]]
        XCTAssertEqual(AtmosphereFollowing.unfollowActions(for: unsent, accounts: accounts, handles: handles, follows: onlyByjp).map(\.title), ["Unfollow"], "one follower needs no name")

        let both = [byjp: [follow(summer, by: byjp)], unsentAccount: [follow(summer, by: unsentAccount)]]
        XCTAssertEqual(AtmosphereFollowing.followActions(for: summer, accounts: accounts, handles: handles, follows: both), [])
        XCTAssertEqual(AtmosphereFollowing.unfollowActions(for: summer, accounts: accounts, handles: handles, follows: both).map(\.title), ["Unfollow as @unsent.byjp.me", "Unfollow as @byjp.me"])
    }
}
