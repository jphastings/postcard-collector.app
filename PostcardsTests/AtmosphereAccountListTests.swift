import XCTest

final class AtmosphereAccountListTests: XCTestCase {
    private let alice = "did:plc:alice"
    private let bob = "did:plc:bob"
    private let carol = "did:plc:carol"
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    func testDisplaysTheUnionOfSyncedAndLocalAccountsOncePerDID() {
        var list = AtmosphereAccountList()
        list.signIn(did: alice, handle: "alice.test", at: t0)
        list.signIn(did: bob, handle: "bob.test", at: t0)

        let shown = list.displayed(sessions: [(bob, "bob.test", false), (carol, "carol.test", false), (carol, "carol.test", false)])

        XCTAssertEqual(shown.map(\.did), [alice, bob, carol])
    }

    func testOnlyAnUnrejectedLocalSessionCountsAsSignedIn() {
        var list = AtmosphereAccountList()
        list.signIn(did: alice, handle: "alice.test", at: t0)
        list.signIn(did: bob, handle: "bob.test", at: t0)
        list.signIn(did: carol, handle: "carol.test", at: t0)

        let shown = list.displayed(sessions: [(alice, "alice.test", false), (carol, "carol.test", true)])

        XCTAssertEqual(shown.map(\.isSignedIn), [true, false, false], "signed in, known only, needs sign-in")
    }

    func testSigningOutTakesTheAccountOffEveryCopy() {
        var here = AtmosphereAccountList()
        here.signIn(did: alice, handle: "alice.test", at: t0)
        let elsewhere = here
        here.signOut(did: alice, at: t1)

        for merged in [here.merged(with: elsewhere), elsewhere.merged(with: here)] {
            XCTAssertEqual(merged.displayed(sessions: []), [])
            XCTAssertEqual(merged.signedOutElsewhere([alice]), [alice], "a device still signed in signs out too")
        }
    }

    func testSigningInAgainAfterASignOutListsTheAccountAgain() {
        var list = AtmosphereAccountList()
        list.signIn(did: alice, handle: "alice.test", at: t0)
        list.signOut(did: alice, at: t0)
        list.signIn(did: alice, handle: "alice.test", at: t1)

        XCTAssertEqual(list.displayed(sessions: []).map(\.did), [alice])
        XCTAssertEqual(list.signedOutElsewhere([alice]), [])
    }

    func testAHandleChangeUpdatesTheSameAccount() {
        var old = AtmosphereAccountList()
        old.signIn(did: alice, handle: "alice.test", at: t0)
        var new = old
        new.signIn(did: alice, handle: "alice.example", at: t1)

        for merged in [old.merged(with: new), new.merged(with: old)] {
            XCTAssertEqual(merged.displayed(sessions: [(alice, "alice.test", false)]).map(\.handle), ["alice.example"])
        }
    }

    func testAdoptsOnlySessionsTheListHasNeverSeen() {
        var list = AtmosphereAccountList()
        list.signIn(did: alice, handle: "alice.test", at: t0)
        list.signOut(did: alice, at: t0)

        list.adopt([(alice, "alice.test"), (bob, "bob.test")], at: t1)

        XCTAssertEqual(list.displayed(sessions: []).map(\.did), [bob], "a signed-out account isn't brought back")
    }

    func testDecodesAFileFromAFutureVersion() throws {
        let json = """
        {"version": 7, "accounts": [{"did": "\(alice)", "handle": "alice.test", "signedOut": false,
          "changed": 0, "avatar": "https://example.com/a.png"}], "pinned": ["\(alice)"]}
        """
        let list = try JSONDecoder().decode(AtmosphereAccountList.self, from: Data(json.utf8))

        XCTAssertEqual(list.displayed(sessions: []), [AtmosphereAccount(did: alice, handle: "alice.test", isSignedIn: false)])
    }
}
