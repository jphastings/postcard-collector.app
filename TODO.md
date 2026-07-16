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
- [ ] macOS: open local files in place — no copy into Application Support. Singleton window.
      Persist opened local files across restarts, tracking each via filesystem metadata:
      update the reference if a file has moved and can still be found, drop it if it can't be
      found on boot. iPad/iOS stays iCloud-only (no Local section).
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
