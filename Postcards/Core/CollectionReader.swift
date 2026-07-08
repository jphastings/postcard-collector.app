import Foundation
import SQLite3

/// Errors surfaced by `CollectionReader`.
enum CollectionReaderError: LocalizedError {
    /// The file's `PRAGMA user_version` doesn't match `CollectionReader.supportedSchemaVersion`.
    case unsupportedSchema(found: Int, supported: Int)
    case notFound(name: String)
    case sqlite(String)
    case corruptMetadata

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let found, let supported) where found > supported:
            return "This collection was created by a newer version of Postcards (schema \(found)); update the app to open it."
        case .unsupportedSchema(let found, let supported):
            return "This collection uses an outdated format (schema \(found), current is \(supported)); open it in the app (or upgrade it with the postcards CLI) first."
        case .notFound(let name):
            return "No card named \"\(name)\" was found."
        case .sqlite(let message):
            return message
        case .corruptMetadata:
            return "The stored metadata for this card couldn't be read."
        }
    }
}

/// A native, read-only SQLite reader for `.postcards` collection files — the Go-free
/// equivalent of `AppcoreCollection`, for use where the Go core can't be linked (app
/// extensions, watchOS). It never migrates an out-of-date collection; that remains the Go
/// core's job.
///
/// Not `Sendable`: a single instance owns one SQLite connection and isn't safe to call
/// concurrently. Callers that need to share one across tasks should wrap it in an actor,
/// the way `GoCore` wraps `AppcoreCollection`.
final class CollectionReader {
    /// The `PRAGMA user_version`/`meta.schema_version` this reader understands. Kept in
    /// sync with `pkg/collection.schemaVersion()` in the Go core.
    static let supportedSchemaVersion = 2

    private var db: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Couldn't open \(path)."
            if let handle { sqlite3_close(handle) }
            throw CollectionReaderError.sqlite(message)
        }
        db = handle

        let version = try Self.queryUserVersion(handle)
        guard version == Self.supportedSchemaVersion else {
            sqlite3_close(handle)
            db = nil
            throw CollectionReaderError.unsupportedSchema(found: version, supported: Self.supportedSchemaVersion)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Reads

    /// The collection's user-set title, or `nil` if none has been set.
    func title() throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT title FROM meta LIMIT 1", into: &statement)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0)
    }

    /// Every card in the collection, most recently sent first (undated cards last), then
    /// alphabetically by name — matching the Go core's `collection.CardSummaries` order.
    func cardSummaries() throws -> [CardSummary] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            """
            SELECT name, filename, mimetype, flip, sent_on, sender_name, recipient_name,
                   location_name, country_code, latitude, longitude, front_px_w, front_px_h
            FROM cards
            ORDER BY sent_on DESC NULLS LAST, name ASC
            """,
            into: &statement
        )

        var summaries: [CardSummary] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw CollectionReaderError.sqlite(lastErrorMessage())
            }

            let flip = Flip(rawValue: columnText(statement, 3) ?? "") ?? .none
            let latitude = columnDouble(statement, 9)
            let longitude = columnDouble(statement, 10)

            summaries.append(
                CardSummary(
                    name: columnText(statement, 0) ?? "",
                    filename: columnText(statement, 1) ?? "",
                    mimetype: columnText(statement, 2) ?? "",
                    flip: flip,
                    sentOn: Self.parseDate(columnText(statement, 4)),
                    senderName: columnText(statement, 5),
                    recipientName: columnText(statement, 6),
                    locationName: columnText(statement, 7),
                    countryCode: columnText(statement, 8),
                    latitude: (latitude != nil && longitude != nil) ? latitude : nil,
                    longitude: (latitude != nil && longitude != nil) ? longitude : nil,
                    frontPxW: Int(sqlite3_column_int(statement, 11)),
                    frontPxH: Int(sqlite3_column_int(statement, 12)),
                    hasBack: flip != .none
                )
            )
        }
        return summaries
    }

    /// The pre-generated thumbnail of a card's front image (JPEG or PNG bytes, as stored).
    func thumbnail(name: String) throws -> Data {
        try blob(column: "thumb", name: name)
    }

    /// The raw, untouched bytes of a card's stored (combined front+back) web-format file.
    func imageData(name: String) throws -> Data {
        try blob(column: "data", name: name)
    }

    /// The full metadata record for a card.
    func metadata(name: String) throws -> PostcardMetadata {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT metadata_json FROM cards WHERE name = ?", into: &statement)
        bindText(name, at: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CollectionReaderError.notFound(name: name)
        }
        guard let json = columnText(statement, 0), let data = json.data(using: .utf8) else {
            throw CollectionReaderError.corruptMetadata
        }
        do {
            return try JSONDecoder().decode(PostcardMetadata.self, from: data)
        } catch {
            throw CollectionReaderError.corruptMetadata
        }
    }

    // MARK: - SQLite helpers

    private func blob(column: String, name: String) throws -> Data {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT \(column) FROM cards WHERE name = ?", into: &statement)
        bindText(name, at: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CollectionReaderError.notFound(name: name)
        }
        guard let bytes = sqlite3_column_blob(statement, 0) else {
            return Data()
        }
        let length = Int(sqlite3_column_bytes(statement, 0))
        return Data(bytes: bytes, count: length)
    }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CollectionReaderError.sqlite(lastErrorMessage())
        }
    }

    /// Binds `text` with the "transient" destructor, telling SQLite to copy the bytes
    /// immediately — required because Swift's bridged C string pointer isn't guaranteed to
    /// outlive the `sqlite3_bind_text` call the way a truly static/long-lived buffer would.
    private func bindText(_ text: String, at index: Int32, in statement: OpaquePointer?) {
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func columnDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private static func queryUserVersion(_ db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw CollectionReaderError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CollectionReaderError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Parses a `"yyyy-MM-dd"` string via `PostcardDate`'s own `Decodable` implementation
    /// (rather than a second, possibly-diverging date formatter), by round-tripping it
    /// through a one-value JSON string.
    private static func parseDate(_ string: String?) -> PostcardDate? {
        guard let string, let data = "\"\(string)\"".data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PostcardDate.self, from: data)
    }
}
