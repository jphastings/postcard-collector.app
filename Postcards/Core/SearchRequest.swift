import Foundation

/// A search preset submitted from elsewhere in the UI (e.g. a person's "More from…" context
/// menu in `CardInfoPanel`) for whichever grid pane is currently on screen to pick up.
/// `token` increments on every `submit`, even if `query` repeats verbatim, so a pane's
/// `.onChange(of: token)` always fires — a `.onChange(of: query)` alone would miss a second,
/// identical preset in a row.
@MainActor
@Observable
final class SearchRequest {
    private(set) var query = ""
    private(set) var token = 0

    func submit(_ query: String) {
        self.query = query
        token += 1
    }
}
