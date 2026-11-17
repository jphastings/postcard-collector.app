import XCTest

final class KeychainAccountStoreTests: XCTestCase {
    private struct Account: Codable, Equatable {
        let did: String
        let handle: String
    }

    private func makeStore() -> KeychainAccountStore<Account> {
        let store = KeychainAccountStore<Account>(service: "org.dotpostcard.collector.tests.\(UUID().uuidString)")
        addTeardownBlock {
            for account in (try? store.all()) ?? [] { try? store.remove(account.did) }
        }
        return store
    }

    func testAccountsRoundTripInTheOrderAdded() throws {
        let store = makeStore()
        let alice = Account(did: "did:plc:zz-alice", handle: "alice.example.com")
        let bob = Account(did: "did:plc:aa-bob", handle: "bob.example.com")

        try store.save(alice, for: alice.did)
        try store.save(bob, for: bob.did)
        XCTAssertEqual(try store.all(), [alice, bob])

        try store.remove(alice.did)
        XCTAssertEqual(try store.all(), [bob])
    }

    func testResavingAnAccountUpdatesItInPlaceRatherThanDuplicating() throws {
        let store = makeStore()
        let alice = Account(did: "did:plc:alice", handle: "alice.example.com")
        let bob = Account(did: "did:plc:bob", handle: "bob.example.com")
        let renamed = Account(did: alice.did, handle: "alice.new.example")

        try store.save(alice, for: alice.did)
        try store.save(bob, for: bob.did)
        try store.save(renamed, for: alice.did)

        XCTAssertEqual(try store.all(), [renamed, bob])
    }

    func testAnEmptyStoreListsNothing() throws {
        XCTAssertEqual(try makeStore().all(), [])
    }
}
