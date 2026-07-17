import XCTest

final class LibrarySourceTests: XCTestCase {
    func testKnownCollectionsCombinesLocalAndDownloadedDedupedByPath() {
        let sources: [LibrarySource] = [
            .collection(path: "/local/a.postcards", displayName: "A"),
            .cardFile(path: "/local/bare.postcard.jpeg", displayName: "Bare"),
        ]
        let downloaded = [
            WritableCollection(path: "/cloud/b.postcards", displayName: "B"),
            // Same path as the local source above (just registered from both places).
            WritableCollection(path: "/local/a.postcards", displayName: "A"),
        ]

        let known = WritableCollection.known(sources: sources, downloaded: downloaded)

        XCTAssertEqual(known.map(\.path), ["/local/a.postcards", "/cloud/b.postcards"])
    }

    func testKnownCollectionsIsEmptyWithNoSources() {
        XCTAssertTrue(WritableCollection.known(sources: [], downloaded: []).isEmpty)
    }
}
