import XCTest

/// The "Create a Postcard" flow's default destination when no collection is chosen: a freshly
/// compiled card written to an app-owned location and registered as a source, same as any
/// other opened file (see `LibraryModelImportTests` for that side of `LibraryModel`).
@MainActor
final class LibraryModelBareCardTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "LibraryModelBareCardTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel() -> LibraryModel {
        LibraryModel(
            defaults: UserDefaults(suiteName: "LibraryModelBareCardTests-\(UUID().uuidString)")!,
            bareCardsDirectory: directory
        )
    }

    func testAddBareCardWritesTheFileAndRegistersItAsASource() throws {
        let model = makeModel()
        let data = Data("fake postcard bytes".utf8)

        let path = try model.addBareCard(filename: "holiday.postcard.jpg", data: data)

        XCTAssertEqual(path, directory.appending(path: "holiday.postcard.jpg").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
        XCTAssertEqual(model.sources.map(\.path), [path])
        XCTAssertFalse(model.sources.first?.isCollection ?? true)
    }

    func testAddBareCardSuffixesACollidingFilenameBeforeItsExtension() throws {
        let model = makeModel()
        let first = try model.addBareCard(filename: "holiday.postcard.jpg", data: Data("one".utf8))
        let second = try model.addBareCard(filename: "holiday.postcard.jpg", data: Data("two".utf8))
        let third = try model.addBareCard(filename: "holiday.postcard.jpg", data: Data("three".utf8))

        XCTAssertEqual(first, directory.appending(path: "holiday.postcard.jpg").path)
        XCTAssertEqual(second, directory.appending(path: "holiday 2.postcard.jpg").path)
        XCTAssertEqual(third, directory.appending(path: "holiday 3.postcard.jpg").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first)), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: second)), Data("two".utf8))
        XCTAssertEqual(Set(model.sources.map(\.path)), [first, second, third])
    }
}
