# Postcards app — working notes

SwiftUI multiplatform viewer (iOS/macOS) over a Go core vendored as
`Frameworks/Postcards.xcframework`, built from github.com/jphastings/dotpostcard
(`make xcframework` there, then copy here). `project.yml` is the source of truth —
regenerate with `xcodegen generate`; the `.xcodeproj` is gitignored.

## Build & test

- Unsigned builds/tests **must** use `CODE_SIGNING_ALLOWED=NO`. The older
  `CODE_SIGN_IDENTITY=-` override stopped working when the app gained iCloud
  entitlements (nested-framework signing fails).
- Unit tests: `xcodebuild -scheme PostcardsTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`.
  Do **not** run the `PostcardsUITests` target from automation — it stalls headless harnesses.
- iCloud is a *restricted* entitlement: release provisioning profiles must be generated
  **after** the App IDs gained the iCloud capability, or archives fail. Cloud-managed
  automatic signing cannot mint these profiles from CI — release signing is manual;
  see `docs/RELEASING.md`.
- Testable logic lives in `Postcards/Core` and `Postcards/Motion` as pure functions with
  no SwiftUI imports; views stay thin. Follow that split — it's why the test suite runs
  in milliseconds.

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
  over `CardSummary` — it lacks descriptions and transcriptions.
- Writes are transient package functions (open → one operation → close). After any
  write to a path, call `GoCore.invalidateSource(at:)` so read handles reopen. iCloud
  paths get coordinated reads/writes (`CloudLibrary`); only hand fully-downloaded
  files to Go.

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
- **Keep annotation view structure constant across states** (badge and popover slot
  always mounted; visibility via opacity + `allowsHitTesting`). Structural changes
  recreate the view and silently kill in-flight animations.
- **Camera events**: `.onEnd` settles are echoed to `.continuous` handlers with
  floating-point drift — classify motion with tolerances (`MapCameraMotion`), never
  exact camera equality. The drift only exists on real hardware; bit-exact test
  harnesses will not catch equality bugs.
- **Pins must be geo-anchored at all times**: an annotation's `coordinate` is its
  display position (own lat/long or cluster centroid). Screen-point offsets drift
  geographically during zoom. Position changes animate as FLIP glides only at camera
  settle, ending offset-free.
- `.animation(_, value:)` animates *every* animatable property in its subtree when the
  value changes — including frame position from unrelated layout settling. An innocent
  badge fade once rendered as the badge plunging in from 200px above.
- Cluster transitions are choreographed via **two membership layers** (positional
  drives coordinates/glides; visual drives badges/popovers/visibility) so chrome never
  leads motion. Preserve that separation.

## UI conventions

- Grids are masonry (`MasonryLayout`), laid out from `CardSummary.frontPxW/H` — never
  decode an image for layout.
- Postcards can be non-rectangular with fibrous, ragged edges — that is a *feature* of
  the format. Never clip, round, or put background plates behind card thumbnails or the
  flip view; transparency shows the true silhouette.
- The flip is physically accurate: axis semantics come from dotpostcard's
  `formats/web/postcards.css`; visibility is a hard cut at edge-on driven by the live
  animated angle (`FlipGeometry.showsFront`), never a crossfade.
- NavigationSplitView merges column toolbars on macOS: the detail column must
  contribute a structurally identical toolbar in *all* selection states (placeholder
  slots when empty) or content-column items drift.
- The sidebar picks the scope; the content pane lists matching cards (grid or map, both
  filtered by any active search); the detail pane shows the card; the inspector shows
  its info. New features should fit that model rather than adding parallel navigation.
