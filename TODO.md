# TODO

Work queue for the Postcards / Postcard Collector app (SwiftUI over the Go core). The Go
core / format tooling has its own list in the dotpostcard repo's `TODO.md`.

## Queue

- [ ] Hide the back & grid/map switcher buttons when the sidebar is closed (they're
      confusing when there's no sidebar to act on).
- [ ] iCloud click-to-download: stop auto-downloading collections. An undownloaded iCloud
      collection reads "Click to download" (macOS) / "Tap to download" (iOS) and downloads
      when clicked; while a download is in flight it reads "Downloading…".
- [ ] "Individual postcards": move/duplicate the aggregate row to the bottom of the correct
      section (Local vs iCloud) depending on where its postcards are stored. Rename
      "Single postcards" → "Individual postcards".
- [ ] iOS/iPad: make it iCloud-only — remove the local-import entry points (Add / open / drag &
      drop) and the Local section on iOS (currently iOS still copy-imports into its container).
- [ ] Detail view zoom/pan: show the "Reset zoom" button when the zoom is non-zero OR the
      postcard isn't centred. Clamp panning so a postcard edge can't move past the middle of the
      screen (no more than halfway off-screen).

## Done

- [x] Search box: native single-line height, focusable, click-anywhere-to-focus, constant
      height that holds token pills.
- [x] Sidebar full-bleed under the titlebar via `containerRelativeFrame` — grid/map reach the
      top, toolbar stays clickable, bottom flush; removed the crash-prone height machinery.
- [x] Back arrow in the window toolbar; collection name scrolls with the grid.
- [x] Grid/map switcher as a connected, single-click segmented control (map gated on locations).
- [x] "Your collections" list title + enlarged "Local"/"iCloud" section headers.
- [x] Sidebar minimum width holds wide enough that the toolbar never overflows to ">>".
- [x] Hide the back & grid/map switcher buttons while the sidebar is collapsed.
- [x] iCloud collections are click-to-download ("Click/Tap to download" / "Downloading…").
- [x] "Individual postcards" split into per-section Local/iCloud rows.
- [x] macOS opens local files in place (no copy) — remembered by bookmark, follows a moved file,
      drops a missing one; "Remove from Local" forgets without deleting.
