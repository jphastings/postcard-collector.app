import XCTest

/// All JSON fixtures below were captured verbatim from the real Go core (`pkg/appcore`,
/// via `Collection.ListJSON`/`SearchJSON`/`CardMetaJSON` and `CardFile.SummaryJSON`)
/// against the app's bundled fixture collection — not hand-written — so these tests catch
/// any drift between the Swift mirrors and the Go JSON tags.
final class ModelsTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testCardSummaryDecodesRealListJSON() throws {
        let json = """
        [{"name":"righthand-card","filename":"righthand-card.postcard.jpeg","mimetype":"image/jpeg","flip":"right-hand","sent_on":"2001-09-15","sender_name":"Yuki Tanaka","recipient_name":"Kenji Sato","location_name":"Kyoto, Japan","country_code":"JPN","latitude":35.0116,"longitude":135.7681,"front_px_w":672,"front_px_h":947,"has_back":true},{"name":"calendar-card","filename":"calendar-card.postcard.jpeg","mimetype":"image/jpeg","flip":"calendar","sent_on":"1972-11-03","sender_name":"Marie Dubois","recipient_name":"Jean Lefevre","location_name":"Paris, France","country_code":"FRA","latitude":48.8566,"longitude":2.3522,"front_px_w":672,"front_px_h":947,"has_back":true}]
        """
        let cards = try decoder.decode([CardSummary].self, from: Data(json.utf8))

        XCTAssertEqual(cards.map(\.name), ["righthand-card", "calendar-card"])
        XCTAssertEqual(cards[0].flip, .rightHand)
        XCTAssertEqual(cards[0].locationName, "Kyoto, Japan")
        XCTAssertEqual(cards[0].countryCode, "JPN")
        XCTAssertEqual(cards[0].frontPxW, 672)
        XCTAssertEqual(cards[0].frontPxH, 947)
        XCTAssertTrue(cards[0].hasBack)
        XCTAssertEqual(dateComponents(cards[0].sentOn), DateComponents(year: 2001, month: 9, day: 15))
    }

    func testCardSummaryDecodesBareCardFileSummaryJSON() throws {
        let json = """
        {"name":"righthand-card","filename":"righthand-card.postcard.jpeg","mimetype":"image/jpeg","flip":"right-hand","sent_on":"2001-09-15","sender_name":"Yuki Tanaka","recipient_name":"Kenji Sato","location_name":"Kyoto, Japan","country_code":"JPN","latitude":35.0116,"longitude":135.7681,"front_px_w":672,"front_px_h":947,"has_back":true}
        """
        let card = try decoder.decode(CardSummary.self, from: Data(json.utf8))
        XCTAssertEqual(card.name, "righthand-card")
        XCTAssertEqual(card.senderName, "Yuki Tanaka")
        XCTAssertEqual(card.recipientName, "Kenji Sato")
    }

    func testSearchResultDecodesTheEmbeddedCardSummaryFlattened() throws {
        let json = """
        [{"name":"book-card","filename":"book-card.postcard.jpeg","mimetype":"image/jpeg","flip":"book","sent_on":"1985-06-12","sender_name":"Alice Fenwick","recipient_name":"Bob Harrington","location_name":"Rome, Italy","country_code":"ITA","latitude":41.9028,"longitude":12.4964,"front_px_w":947,"front_px_h":672,"has_back":true,"snippet":"Sent from a family holiday to \\u003cb\\u003eRome\\u003c/b\\u003e, book-flip postcard (landscape front…","rank":-1.3393966177299903}]
        """
        let results = try decoder.decode([SearchResult].self, from: Data(json.utf8))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].card.name, "book-card")
        XCTAssertEqual(results[0].card.locationName, "Rome, Italy")
        XCTAssertEqual(results[0].snippet, "Sent from a family holiday to <b>Rome</b>, book-flip postcard (landscape front…")
        XCTAssertEqual(results[0].rank, -1.3393966177299903)
    }

    func testLibraryHitDecodesTheNestedCardSummary() throws {
        let json = """
        [{"source":"/tmp/fixture.postcards","card":{"name":"lefthand-card","filename":"lefthand-card.postcard.jpeg","mimetype":"image/jpeg","flip":"left-hand","sent_on":"1990-02-20","sender_name":"Hans Zimmermann","recipient_name":"Greta Vogel","location_name":"Berlin, Germany","country_code":"DEU","latitude":52.52,"longitude":13.405,"front_px_w":947,"front_px_h":672,"has_back":true},"snippet":"\\u003cb\\u003eBerlin\\u003c/b\\u003e, Germany"}]
        """
        let hits = try decoder.decode([LibraryHit].self, from: Data(json.utf8))

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].source, "/tmp/fixture.postcards")
        XCTAssertEqual(hits[0].card.name, "lefthand-card")
        XCTAssertEqual(hits[0].snippet, "<b>Berlin</b>, Germany")
    }

    func testPostcardMetadataDecodesRealCardMetaJSON() throws {
        let json = """
        {"locale":"de-DE","location":{"name":"Berlin, Germany","latitude":52.52,"longitude":13.405,"countrycode":"DEU"},"flip":"left-hand","sentOn":"1990-02-20","sender":{"name":"Hans Zimmermann","uri":"https://hans.example.com"},"recipient":{"name":"Greta Vogel","uri":"https://greta.example.org"},"front":{"description":"The word 'Front' in large blue letters, landscape orientation","transcription":{"text":"Front"}},"back":{"description":"The word 'Back' in large red letters, portrait orientation","transcription":{"text":"Grüße aus Berlin!","annotations":[{"type":"locale","value":"de-DE","start":0,"end":19},{"type":"em","start":12,"end":18}]}},"context":{"author":{"name":"Otto Braun","uri":"https://otto.example.net"},"description":"Sent just after the wall came down, left-hand-flip postcard (landscape front, portrait back)."},"physical":{"frontSize":{"cmW":"74/5","cmH":"21/2","pxW":947,"pxH":672},"thicknessMM":0.4,"cardColor":"#E6E6D9"}}
        """
        let metadata = try decoder.decode(PostcardMetadata.self, from: Data(json.utf8))

        XCTAssertEqual(metadata.locale, "de-DE")
        XCTAssertEqual(metadata.location.name, "Berlin, Germany")
        XCTAssertEqual(metadata.location.countryCode, "DEU")
        XCTAssertEqual(metadata.flip, .leftHand)
        XCTAssertEqual(dateComponents(metadata.sentOn), DateComponents(year: 1990, month: 2, day: 20))
        XCTAssertEqual(metadata.sender.name, "Hans Zimmermann")
        XCTAssertEqual(metadata.recipient.uri, "https://greta.example.org")
        XCTAssertEqual(metadata.front.transcription.text, "Front")
        XCTAssertEqual(metadata.back.transcription.text, "Grüße aus Berlin!")
        XCTAssertEqual(metadata.back.transcription.annotations.count, 2)
        XCTAssertEqual(metadata.back.transcription.annotations[1].type, .emphasis)
        XCTAssertEqual(metadata.context.author.name, "Otto Braun")
        // "physical" is deliberately not mirrored (unused by the viewer); decoding must
        // still succeed and simply ignore that key.
    }

    func testPostcardMetadataFillsInDefaultsForAbsentOptionalObjects() throws {
        let metadata = try decoder.decode(PostcardMetadata.self, from: Data("{}".utf8))

        XCTAssertNil(metadata.locale)
        XCTAssertEqual(metadata.flip, .none)
        XCTAssertNil(metadata.sentOn)
        XCTAssertEqual(metadata.front.transcription.text, "")
    }

    private func dateComponents(_ date: PostcardDate?) -> DateComponents? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date.date)
        return DateComponents(year: components.year, month: components.month, day: components.day)
    }
}
