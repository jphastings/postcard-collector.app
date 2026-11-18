# Changelog

Every release of Postcard Collector for iPhone, iPad, Apple Watch, and Mac, newest first.
[Knope](https://knope.tech) writes each entry from the conventional commits merged since the
release before it — see `knope.toml` and `docs/RELEASING.md`.

## 0.7.7 (2026-11-18)

### Features

- sync the Atmosphere account list through iCloud, flagging accounts not signed in here

### Fixes

- show "Your collections" as the iOS large navigation title
- an iOS-native Atmosphere sign-in prompt, and a followed icon that scales on iOS
- place masonry grid cards at precomputed frames so scrolling up doesn't shift them

## 0.7.6 (2026-11-18)

### Features

- keep a collection's title and Back pinned while its postcards scroll
- sign in to atproto accounts in a new Atmosphere sidebar section
- browse your atproto accounts' collections from a progressive local cache
- copy an Atmosphere collection's at-uri, and dim sidebar rows consistently
- follow and unfollow Atmosphere collections
- mark followed Atmosphere collections that have new postcards
- give the watch's zoomed-card pan the same limit as iPhone and Mac
- relay downloaded Atmosphere collections to the watch

## 0.7.5 (2026-11-17)

### Features

- outline the selected grid card along its own silhouette
- export a postcard's stored file with File ▸ Export… (⇧⌘S)
- open individual postcards in their own window
- keep a zoomed postcard from being panned off screen
- open component bundles into Create a Postcard
- put Back beside the collection name, freeing the sidebar to narrow
- keep the sidebar on screen in narrow windows
- update dotpostcard to v0.50.0 and offer to upgrade old collections

## 0.7.4 (2026-10-02)

### Features

- show a tapped iCloud collection downloading at once, with a progress ring

## 0.7.3 (2026-10-02)

### Features

- start a portrait-fronted hand-flip postcard zoomed to its front
- swipe from the top of the watch screen to hide or bring back the controls

## 0.7.2 (2026-09-30)

### Features

- swipe up or down to move between watch postcards; a single tap does nothing

### Fixes

- pinch-zoom a postcard smoothly from its resting size and back

## 0.7.1 (2026-09-30)

### Features

- watch app polish — faster streaming, sharper zoom, new gestures, info page

### Fixes

- harden the watch relay's message path after review
