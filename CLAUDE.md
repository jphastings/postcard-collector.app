# Postcards app — working notes

SwiftUI multiplatform viewer (iOS/macOS/watchOS) over a Go core vendored as
`Frameworks/Postcards.xcframework`, built from github.com/jphastings/dotpostcard
(`make xcframework` there, then copy here). `project.yml` is the source of truth —
regenerate with `xcodegen generate`; the `.xcodeproj` is gitignored. **Run xcodegen after
adding any file**: a stale generated project produces "no member" errors for code that
plainly exists. The iOS/macOS app targets and `PostcardsTests` glob whole directories, but
the watchOS and QuickLook targets list sources **explicitly** — a new `Postcards/Core` file
they need must be added to their lists by hand (and one they can't compile must not be).

## The Go core boundary

- Go never decodes image pixels at app runtime (its codecs would be interpreter-slow on
  iOS). It serves raw file bytes, pre-generated thumbnails, and JSON; Swift decodes via
  ImageIO and splits/rotates per `ImageSplitter` (mirrors dotpostcard's
  `formats/web/decode.go`).
- All Appcore calls are blocking — only call through the `GoCore` actor, never on main.
- JSON contract: list/search results are always arrays, never `null` (enforced Go-side;
  a `null` here once broke search with "data couldn't be read because it is missing").
- **Every search path routes through the Go core** (collection FTS or the Library
  fan-out) so "searchable text" has exactly one definition. Don't filter client-side
  over `CardSummary` — it lacks descriptions and transcriptions. Field-scoped search
  (`from:`/`to:`/`with:`/`collector:`/`country:`/dates) goes through `SearchQuery` →
  `SearchFilteredJSON`; person URIs match exactly, names match as FTS prefixes.
- Writes are transient package functions (open → one operation → close). After any
  write to a path, call `GoCore.invalidateSource(at:)` so read handles reopen. iCloud
  paths get coordinated reads/writes (`CloudLibrary`); only hand fully-downloaded
  files to Go.
- **The Go toolchain version is load-bearing.** go 1.25.0 miscompiled the gomobile
  library: heap corruption whose crashes surfaced in *random Apple frameworks*
  (AttributeGraph, CoreAnimation, UIKit pointer interactions), only in CI/archived
  builds, never locally — because local Xcode used a newer Go. The build toolchain is
  pinned in dotpostcard's Makefile (GOTOOLCHAIN on the gomobile recipe; kept off go.mod
  so TinyGo's WASM build stays on its supported version). If CI crashes diverge from
  local behaviour, diff the actual toolchains/binaries before debugging the code.
- Corollary that cost weeks: **when crashes appear in a different subsystem every time,
  suspect memory corruption and distrust the crash site.** Workarounds added where the
  crashes appeared (scroll-edge effects, hover effects) were treating symptoms; they were
  reverted once the real cause was fixed. Related non-negotiables: never strip the app
  binary (`STRIP_INSTALLED_PRODUCT: NO` — Go's runtime needs its symbols for GC/stack
  growth; archive stripping corrupted the heap), and the xcframework is a **static**
  library that must be *linked* (`embed: false`), never embedded/code-signed as if
  dynamic.

## Navigation architecture (two-level sidebar)

Two-column `NavigationSplitView`: a sidebar hosting a `NavigationStack` (collections list
→ the chosen collection's postcard browser, grid or map) and the postcard detail pane
(with its info inspector/sheet). The sidebar column widens in map mode (`SidebarWidths`).
On iPhone the same stack collapses to collections → postcards → postcard.

This replaced a 3-column layout after its middle column's toolbar items drifted **four
times**. The lessons, which the architecture now encodes:

- On macOS, a NavigationSplitView merges per-column toolbars, and a column's items only
  stay anchored over that column while *every* column contributes structurally identical
  items across all states. Don't fight that merge — put pane-associated controls in the
  sidebar column's stable toolbar section, or in content owned by a single pane.
- **The titlebar band belongs to AppKit.** SwiftUI content overlaid into it renders but
  does not reliably receive clicks (the titlebar's hit-testing wins; double-clicks
  trigger the titlebar's own actions), and the window title can migrate over it. The only
  clickable things in the titlebar are real toolbar items.
- `NSToolbar` is one shared bar per window: `toolbarBackgroundVisibility(.hidden)` is
  necessarily window-wide, and it's applied permanently (LibraryView) — macOS only makes
  the bar glass by itself above scroll views, and both the full-height detail card and
  the sidebar toolbar rely on the transparent band.
- Buttons whose AppKit tracking loop competes with another hit-test participant (stacked
  map annotations; anything near the titlebar) lose the first click — a `.onTapGesture`
  doesn't. See the map pins.

## MapKit annotation hosting — hard-won rules

SwiftUI `Map` hosts `Annotation` content behind a bridging boundary with sharp edges.
`CollectionMapView.swift`'s doc comments are the detailed record; the headlines:

- **Outer `withAnimation` transactions do not reach annotation content.** Animate with
  value-scoped `.animation(_, value:)` or `Animatable` modifiers *inside* the
  annotation. Corollary: `withAnimation(completionCriteria:)` completions fire
  immediately (the outer transaction animates nothing) — anchor completion to the
  animatable value itself reporting arrival (see `GlideOffsetEffect`).
- **Never conditionally mount content that changes an annotation's frame** — the
  anchor shifts off the coordinate. Reserve geometry with a permanently-mounted
  `.hidden()` measuring twin and overlay the real content on it. Opacity-hidden *live*
  content can also be mis-composited by the bridge; prefer conditional-mount-over-twin.
- **Keep annotation view structure constant across states** (badge slot always mounted;
  visibility via opacity + `allowsHitTesting`). Structural changes recreate the view and
  silently kill in-flight animations.
- **Camera events**: `.onEnd` settles are echoed to `.continuous` handlers with
  floating-point drift — classify motion with tolerances (`MapCameraMotion`), never
  exact camera equality. The drift only exists on real hardware. Also: the *initial*
  programmatic camera never fires `.onEnd` on macOS — anything seeded "at first settle"
  must also be seeded from the first `.continuous` callback, or the map is inert until
  the user pans (this shipped as "pins don't work until you touch the map").
- **Pins must be geo-anchored at all times**: an annotation's `coordinate` is its
  display position (own lat/long or cluster centroid). Screen-point offsets drift
  geographically during zoom. Position changes animate as FLIP glides only at camera
  settle, ending offset-free.
- Cluster tap behaviour (zoom-to-disaggregate vs cycle) and the badge colour both read
  the same cached `MapClusterZoom` decision so UI and behaviour can't disagree. A zoom
  region must guarantee the *closest* pair separates past the recluster threshold on
  screen — containing all members is not enough (tight sub-groups instantly re-merge).

## SwiftUI gotchas this codebase has paid for

- **Attach gestures to an untransformed container.** A drag gesture on a view inside its
  own `.scaleEffect`/`.offset` feeds back into its own coordinate space → violent jitter.
  The detail view's stable-outer-container structure is deliberate.
- **`@FocusState` dies when structural identity changes.** A pane branch-swapping between
  grid and "no results" (or through a momentary nil-results `ProgressView`) tears down a
  `safeAreaInset`-hosted text field mid-keystroke. Keep the host mounted; layer empty
  states in a ZStack; never let async state pass through nil between keystrokes.
- Single-tap actions must not wait out double-tap disambiguation windows — a flip that
  waits feels broken. If two tap counts are needed on one surface, accept discrete
  semantics; on iOS/macOS we removed double-tap zoom instead.
- iOS ignores `.searchable`'s `suggestedTokens:` binding in this configuration; use
  `.searchSuggestions {}` rows with `.searchCompletion(token)` (the Mail pattern).
  `searchFocused` needs iOS 18 — gate it, don't raise the floor for a nicety.
- macOS UI tests must launch with `-ApplePersistenceIgnoreState YES` (window restoration
  resurrects prior split-view/sidebar state and breaks fixtures) and anchor assertions on
  accessibility identifiers (`CollectionModeSwitcher`, `DetailPane`, `CollectionMap`) —
  never on window-width fractions, which lie at minimum window size.

## The watch relay (`WatchRelay` is the wire contract)

- watchOS cannot open iCloud Drive documents at all — the phone relays over
  WatchConnectivity. Its channels have sharp constraints: `updateApplicationContext` is
  capped ~256KB (the catalog is names-only for this reason — a single embedded thumbnail
  once made the watch silently show nothing), `transferUserInfo` is delivered exactly
  once (never silently drop an unserviceable request — queue and retry when the library
  populates), and `transferFile` is a slow FIFO (dedupe re-requests against
  `outstandingFileTransfers` or retries double the backlog).
- The WCSession delegate must exist from **process launch** (`App.init`), not a view
  task — background launches deliver queued messages to whoever is listening, or no one.
- Collections stream progressively: manifest first, then each card *face* as its own
  ready-to-display image (screen tier for every card, zoom tier trailing). The phone does
  all pixel work; the watch only decodes small files through an LRU. Keep it that way —
  per-card decode/rotation on the watch is what made scrolling jerky.
- Threading discipline is strict everywhere WCSession appears: `@MainActor @Observable`
  state, `nonisolated` delegate methods hopping via `Task { @MainActor in }`, and file
  moves done synchronously before the delegate returns (WCSession reclaims the temp
  file). This app's history makes off-main state mutation a hard no.

## UI conventions

- Grids are masonry (`MasonryLayout`), laid out from `CardSummary.frontPxW/H` — never
  decode an image for layout.
- Postcards can be non-rectangular with fibrous, ragged edges — that is a *feature* of
  the format. Never clip, round, smooth, or put background plates behind card thumbnails
  or the flip view; alpha is only ever *read* (e.g. the selection glow masks by it).
- The flip is physically accurate: axis semantics come from dotpostcard's
  `formats/web/postcards.css`; visibility is a hard cut at edge-on driven by the live
  animated angle (`FlipGeometry.showsFront`), never a crossfade.
- The at-rest postcard sizing is a fit-regime model (`CardFitGeometry`): centred, always
  a margin on all four sides, between-the-toolbar-buttons for tall cards vs below-the-band
  for wide ones, inset-aware (the macOS inspector arrives as a trailing safe-area inset).
- Exports must be byte-faithful: dragging a card out writes the Go core's raw stored
  bytes (image + embedded XMP), never a re-encode.
- Country codes are ISO 3166-1 alpha-3 (Spain = ESP); `CountryFlags` holds the only
  alpha-3↔alpha-2 table — reuse it, don't add country data elsewhere.

## Build, test & release

- Unsigned builds/tests **must** use `CODE_SIGNING_ALLOWED=NO`. The older
  `CODE_SIGN_IDENTITY=-` override stopped working when the app gained iCloud
  entitlements (nested-framework signing fails).
- Unit tests: `xcodebuild -scheme PostcardsTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`.
  Testable logic lives in `Postcards/Core` and `Postcards/Motion` as pure functions with
  no SwiftUI imports; views stay thin. Follow that split — it's why the suite runs in
  milliseconds, and it's the repo convention for anything worth asserting (fit regimes,
  cluster decisions, search parsing, cache layouts).
- The macOS UI tests (`PostcardsUITests-macOS`) run in CI and locally; don't run the iOS
  `PostcardsUITests` target from headless automation — it stalls.
- CI's app job must run on a macOS image whose SDK contains the Liquid Glass APIs the
  code uses — runtime `#available` guards don't help the *compiler* against an old SDK.
- Release flow spans two repos, in order: dotpostcard main push auto-releases via
  commitizen (`feat:`/`fix:` prefixes drive the version); then bump `DOTPOSTCARD_REF`
  in **both** workflow files here, bump `MARKETING_VERSION`, push main and tag `v*`.
  Tagging without those bumps ships a stale framework or collides on version — both have
  happened. A new `DOTPOSTCARD_REF` means a cold xcframework cache (~10 min extra).
- iCloud is a *restricted* entitlement: release provisioning profiles must be generated
  **after** the App IDs gained the iCloud capability, or archives fail. Release signing
  is manual; see `docs/RELEASING.md`. The watch app carries no iCloud entitlement (the
  relay needs none) but still needs its own App Store profile.
- The macOS product is "Postcard Collector.app" (`PRODUCT_NAME`); scheme/target/archive
  names remain `Postcards-macOS`, and release.yaml's paths track the product name.
