import Foundation

/// One thing the library can show: either an opened `.postcards` collection, or a bare
/// `.postcard.*` file opened outside of any collection.
enum LibrarySource: Identifiable, Hashable {
    case collection(path: String, displayName: String)
    case cardFile(path: String, displayName: String)

    var id: String { path }

    var path: String {
        switch self {
        case .collection(let path, _): return path
        case .cardFile(let path, _): return path
        }
    }

    var displayName: String {
        switch self {
        case .collection(_, let name): return name
        case .cardFile(_, let name): return name
        }
    }

    var isCollection: Bool {
        if case .collection = self { return true }
        return false
    }
}

/// A single card, addressable back to the source it came from — either one card among
/// many in a collection, or the sole card in a bare file.
enum CardReference: Identifiable, Hashable {
    case inCollection(path: String, summary: CardSummary)
    case bareFile(path: String, summary: CardSummary)

    var id: String {
        switch self {
        case .inCollection(let path, let summary): return "\(path)#\(summary.name)"
        case .bareFile(let path, _): return path
        }
    }

    var summary: CardSummary {
        switch self {
        case .inCollection(_, let summary): return summary
        case .bareFile(_, let summary): return summary
        }
    }
}
