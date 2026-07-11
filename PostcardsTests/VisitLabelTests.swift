import XCTest

final class VisitLabelTests: XCTestCase {
    func testStripsLeadingWWWAndTrailingSlashFromPath() {
        let url = URL(string: "https://www.instagram.com/claire.durrant88/")!
        XCTAssertEqual(VisitLabel.text(for: url), "Visit instagram.com/claire.durrant88")
    }

    func testBareDomainShowsHostOnly() {
        let url = URL(string: "https://byjp.me")!
        XCTAssertEqual(VisitLabel.text(for: url), "Visit byjp.me")
    }

    func testRootPathIsTreatedAsNoPath() {
        let url = URL(string: "https://www.example.com/")!
        XCTAssertEqual(VisitLabel.text(for: url), "Visit example.com")
    }

    func testHostWithoutWWWIsUnchanged() {
        let url = URL(string: "https://example.com/some/path")!
        XCTAssertEqual(VisitLabel.text(for: url), "Visit example.com/some/path")
    }
}
