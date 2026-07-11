import Foundation

/// A search preset submitted from elsewhere in the UI (e.g. a person's "More from…" context
/// menu in `CardInfoPanel`) for whichever grid pane is currently on screen to pick up.
/// Presets are always a single `SearchToken` pill now (e.g. `from: Claire`), not a raw
/// query string. `generation` increments on every `submit`, even if `token` repeats
/// verbatim, so a pane's `.onChange(of: generation)` always fires — a `.onChange(of:
/// token)` alone would miss a second, identical preset in a row.
@MainActor
@Observable
final class SearchRequest {
    private(set) var token: SearchToken?
    private(set) var generation = 0

    func submit(token: SearchToken) {
        self.token = token
        generation += 1
    }
}
