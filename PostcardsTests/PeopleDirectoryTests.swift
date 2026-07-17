import Foundation
import XCTest

/// Covers `PeopleDirectory`'s pure merge logic and its refresh/cache lifecycle, entirely
/// through the three injected closures (library/cloud fetches never touch `GoCore` or
/// `CloudLibrary` themselves) and fixed in-memory `[PersonRef]`/`[CloudItem]` fixtures.
@MainActor
final class PeopleDirectoryTests: XCTestCase {
    private struct StubError: Error {}

    /// A fresh temp directory per test, cleaned up afterwards — same pattern as
    /// `CreatePostcardIntegrationTests.makeTempDirectory()`.
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PeopleDirectoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    // MARK: - Merge/dedup semantics

    func testMergeCombinesRolesForTheSameNameAndURI() {
        let people = [
            PersonRef(name: "Ada Lovelace", uri: "https://example.com/ada", roles: ["from"]),
            PersonRef(name: "Ada Lovelace", uri: "https://example.com/ada", roles: ["to"]),
        ]
        let merged = PeopleDirectory.merge(people)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.roles, ["from", "to"])
    }

    func testMergeKeepsDifferentNamesOrURIsDistinct() {
        let people = [
            PersonRef(name: "Ada Lovelace", uri: "https://example.com/ada", roles: ["from"]),
            PersonRef(name: "Ada Lovelace", uri: "https://example.com/ada-2", roles: ["from"]),
            PersonRef(name: "Charles Babbage", uri: "https://example.com/ada", roles: ["to"]),
        ]
        let merged = PeopleDirectory.merge(people)
        XCTAssertEqual(merged.count, 3, "same name with a different uri, and same uri with a different name, both stay distinct")
    }

    func testMergeRoleUnionHasNoDuplicates() {
        let people = [
            PersonRef(name: "Ada Lovelace", uri: nil, roles: ["from", "collector"]),
            PersonRef(name: "Ada Lovelace", uri: nil, roles: ["collector"]),
        ]
        let merged = PeopleDirectory.merge(people)
        XCTAssertEqual(merged.first?.roles, ["collector", "from"])
    }

    // MARK: - Cache write -> fresh-instance read round trip

    func testRefreshPersistsToDiskForAFreshInstanceToRead() async throws {
        let cacheDirectory = try makeTempDirectory()
        let seed = [PersonRef(name: "Ada Lovelace", uri: nil, roles: ["from"])]

        let writer = PeopleDirectory(
            cacheDirectory: cacheDirectory,
            fetchLibraryPeople: { seed },
            primeCloudPath: { _ in },
            fetchPeopleInCollection: { _ in [] }
        )
        await writer.refresh()

        // fetchLibraryPeople throws here, proving this instance's `people` (set at init,
        // before refresh() is ever called) can only have come from the on-disk cache.
        let reader = PeopleDirectory(
            cacheDirectory: cacheDirectory,
            fetchLibraryPeople: { throw StubError() },
            primeCloudPath: { _ in throw StubError() },
            fetchPeopleInCollection: { _ in throw StubError() }
        )

        XCTAssertEqual(reader.people, PeopleDirectory.merge(seed))
    }

    // MARK: - Refresh replaces stale entries

    func testRefreshReplacesPriorCacheContentsEntirely() async throws {
        let cacheDirectory = try makeTempDirectory()
        let setA = [PersonRef(name: "Ada Lovelace", uri: nil, roles: ["from"])]
        let setB = [PersonRef(name: "Grace Hopper", uri: nil, roles: ["to"])]

        let first = PeopleDirectory(cacheDirectory: cacheDirectory, fetchLibraryPeople: { setA })
        await first.refresh()
        XCTAssertEqual(first.people, PeopleDirectory.merge(setA))

        let second = PeopleDirectory(cacheDirectory: cacheDirectory, fetchLibraryPeople: { setB })
        await second.refresh()
        XCTAssertEqual(second.people, PeopleDirectory.merge(setB), "B must wholesale replace A, not merge with it")

        let third = PeopleDirectory(cacheDirectory: cacheDirectory, fetchLibraryPeople: { throw StubError() })
        XCTAssertEqual(third.people, PeopleDirectory.merge(setB), "a later reader of the same cache dir must see B, never a survivor of A")
    }

    // MARK: - Quiet failure serves the cache

    func testRefreshFailureLeavesAnEmptyCacheEmpty() async throws {
        let cacheDirectory = try makeTempDirectory()
        let directory = PeopleDirectory(cacheDirectory: cacheDirectory, fetchLibraryPeople: { throw StubError() })

        await directory.refresh()

        XCTAssertEqual(directory.people, [])
    }

    func testRefreshFailurePreservesAPreSeededCache() async throws {
        let cacheDirectory = try makeTempDirectory()
        let seed = [PersonRef(name: "Ada Lovelace", uri: nil, roles: ["from"])]
        let seeder = PeopleDirectory(cacheDirectory: cacheDirectory, fetchLibraryPeople: { seed })
        await seeder.refresh()

        let failing = PeopleDirectory(cacheDirectory: cacheDirectory, fetchLibraryPeople: { throw StubError() })
        await failing.refresh()

        XCTAssertEqual(failing.people, PeopleDirectory.merge(seed), "a failed refresh must not crash, hang, or clear existing data")
    }

    // MARK: - Cloud collection contribution

    func testDownloadedCollectionContributesItsPeople() async throws {
        let cacheDirectory = try makeTempDirectory()
        let libraryPeople = [PersonRef(name: "Ada Lovelace", uri: nil, roles: ["from"])]
        let collectionPeople = [PersonRef(name: "Grace Hopper", uri: nil, roles: ["to"])]
        let collectionPath = "/cloud/trip.postcards"

        let directory = PeopleDirectory(
            cacheDirectory: cacheDirectory,
            fetchLibraryPeople: { libraryPeople },
            primeCloudPath: { _ in },
            fetchPeopleInCollection: { path in path == collectionPath ? collectionPeople : [] }
        )

        let item = CloudItem(path: collectionPath, displayName: "trip", isCollection: true, downloadState: .current)
        await directory.refresh(cloudItems: [item])

        XCTAssertEqual(directory.people, PeopleDirectory.merge(libraryPeople + collectionPeople))
    }

    func testNonCurrentCollectionsAreNeverPrimedOrFetched() async throws {
        let cacheDirectory = try makeTempDirectory()
        let libraryPeople = [PersonRef(name: "Ada Lovelace", uri: nil, roles: ["from"])]

        let directory = PeopleDirectory(
            cacheDirectory: cacheDirectory,
            fetchLibraryPeople: { libraryPeople },
            primeCloudPath: { _ in XCTFail("a non-.current item must never be primed") },
            fetchPeopleInCollection: { _ in
                XCTFail("a non-.current item must never be fetched")
                return []
            }
        )

        let downloading = CloudItem(path: "/cloud/downloading.postcards", displayName: "downloading", isCollection: true, downloadState: .downloading(percent: 40))
        let remote = CloudItem(path: "/cloud/remote.postcards", displayName: "remote", isCollection: true, downloadState: .remote)
        await directory.refresh(cloudItems: [downloading, remote])

        XCTAssertEqual(directory.people, PeopleDirectory.merge(libraryPeople))
    }
}
