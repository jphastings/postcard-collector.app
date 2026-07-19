# Releasing

CI (`.github/workflows/ci.yaml`) builds the Go XCFramework, generates the Xcode project, builds
both platforms, and runs `PostcardsTests` on every push to `main` and every PR.

Tagged releases (`.github/workflows/release.yaml`) additionally archive, sign, notarize, and
publish macOS + iOS artifacts to a GitHub Release — but only once you've added the secrets below.
**Without the secrets, the release workflow still runs and still publishes a release**, just with
unsigned artifacts (an unsigned `.app.zip` on macOS, an unsigned iOS Simulator `.app.zip`
instead of a TestFlight upload).

## One-time prerequisite: iCloud on the App IDs

The app uses iCloud, a *capability* that must be enabled on each App ID in the developer
portal before any provisioning profile can carry the entitlement. Under
[Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list),
edit all three App IDs — `org.dotpostcard.collector` (iOS), `org.dotpostcard.collector.mac`
(macOS), and `org.dotpostcard.collector.watchkitapp` (the watchOS companion, which reads the
shared container directly) — and enable **iCloud** (CloudKit/CloudDocuments) with the
`iCloud.org.dotpostcard.collector` container. Any profile generated *before* this was enabled
is invalid for this app: regenerate and re-download profiles after changing a capability.

> The watch App ID (`…watchkitapp`) is new — create it under Identifiers if it doesn't exist,
> enable iCloud on it, and only *then* mint its App Store profile (below). This is the same
> "capability-before-profile" ordering as the other two App IDs.

The bundled macOS **QuickLook extensions** (`…mac.preview`, `…mac.thumbnail`) are sandboxed
but carry no restricted capability, so they need **no** provisioning profile — they sign with
the Developer ID identity alone. The release workflow scopes each profile to a specific target
(via per-target `PROVISIONING_PROFILE_SPECIFIER=$(…_PROFILE_SPECIFIER)` build settings in
`project.yml`) rather than one global specifier, precisely so the app's profile isn't forced
onto the profile-less appexes or onto the watch app (which needs its own).

## Repo secrets

Add these under **Settings → Secrets and variables → Actions**.

### macOS signing (Developer ID)

| Secret | What it is |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Your **Developer ID Application** certificate + private key, exported as a `.p12`, base64-encoded. |
| `P12_PASSWORD` | The password you set when exporting the `.p12`. |
| `MACOS_PROVISIONING_PROFILE_BASE64` | A **Developer ID** provisioning profile for `org.dotpostcard.collector.mac`, base64-encoded. |
| `KEYCHAIN_PASSWORD` | Any password — used only to lock/unlock the throwaway CI keychain. Reused by the iOS job too. |

**Exporting the certificate:**

1. Open **Keychain Access** → `My Certificates`, find "Developer ID Application: ...".
2. Right-click → **Export...** → save as `cert.p12`, set a password (this is `P12_PASSWORD`).
3. `base64 -i cert.p12 | pbcopy` → paste into the `BUILD_CERTIFICATE_BASE64` secret.

If you don't have a Developer ID Application certificate yet, create one at
[developer.apple.com → Certificates](https://developer.apple.com/account/resources/certificates/list)
(type: "Developer ID Application"), download it, double-click to install it into your login
keychain, then export as above.

**Provisioning profile:** [developer.apple.com → Profiles](https://developer.apple.com/account/resources/profiles/list) →
create a profile of type **Developer ID** (under "Distribution") for the
`org.dotpostcard.collector.mac` App ID — this must be done *after* enabling iCloud on the App
ID (see prerequisite above) or the profile won't carry the entitlement. Download the
`.provisionprofile`, then:

```sh
base64 -i Postcards_Developer_ID.provisionprofile | pbcopy
```

### Notarization (App Store Connect API key)

| Secret | What it is |
| --- | --- |
| `NOTARY_KEY_ID` | The Key ID shown next to the API key. |
| `NOTARY_ISSUER_ID` | The Issuer ID shown at the top of the Keys page. |
| `NOTARY_KEY_BASE64` | The `.p8` private key file, base64-encoded. |

**Creating the key:** [App Store Connect → Users and Access → Integrations → Team Keys](https://appstoreconnect.apple.com/access/integrations/api),
create a key with the **Developer** role, download the `.p8` (Apple only lets you download it
once), then:

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

### iOS signing

| Secret | What it is |
| --- | --- |
| `IOS_DIST_CERTIFICATE_BASE64` | Your **Apple Distribution** certificate + private key, exported as a `.p12`, base64-encoded (same export process as the macOS cert above, different certificate type). |
| `IOS_P12_PASSWORD` | The password for that `.p12`. |
| `IOS_PROVISIONING_PROFILE_BASE64` | An **App Store** provisioning profile for `org.dotpostcard.collector`, base64-encoded. |
| `WATCH_PROVISIONING_PROFILE_BASE64` | An **App Store** provisioning profile for the watch App ID `org.dotpostcard.collector.watchkitapp`, base64-encoded. Required — the signed iOS archive embeds (and must sign) the watch app, so it can't be built without this. |

**Provisioning profiles:** [developer.apple.com → Profiles](https://developer.apple.com/account/resources/profiles/list) →
create an "App Store" distribution profile for **both** the `org.dotpostcard.collector` App ID
*and* the `org.dotpostcard.collector.watchkitapp` App ID (the same Apple Distribution
certificate signs both). As with the macOS profile, each must be (re)generated *after*
enabling iCloud on its App ID — a profile created before that won't match the iCloud
entitlements and the archive will fail. Download each `.mobileprovision`, then:

```sh
base64 -i Postcards_App_Store.mobileprovision | pbcopy          # → IOS_PROVISIONING_PROFILE_BASE64
base64 -i Postcards_Watch_App_Store.mobileprovision | pbcopy    # → WATCH_PROVISIONING_PROFILE_BASE64
```

If `WATCH_PROVISIONING_PROFILE_BASE64` is absent, the release falls back to the unsigned iOS
Simulator build (same as when any other iOS signing secret is missing), so a partial secret
set never fails the release — it just skips the TestFlight upload.

### TestFlight upload (App Store Connect API key)

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` | The Key ID shown next to the API key. |
| `ASC_ISSUER_ID` | The Issuer ID shown at the top of the Keys page. |
| `ASC_KEY_BASE64` | The `.p8` private key file, base64-encoded. |

This is the same App Store Connect API key mechanism as the `NOTARY_*` secrets — same
[Team Keys page](https://appstoreconnect.apple.com/access/integrations/api), same
`base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy` export. You can reuse one key for both `NOTARY_*` and
`ASC_*` if its role allows: notarization only needs the **Developer** role, while uploading
builds may need **App Manager** depending on your team's setup — if uploads are rejected as
unauthorized, mint a second key with the App Manager role for `ASC_*`.

Signing itself is fully manual (certificates + the installed profiles above); this key is only
the **upload transport** for TestFlight. The signed iOS path exports with
`method: app-store-connect` + `destination: upload`, which sends the build straight to
TestFlight instead of writing an `.ipa` — so no iOS file is attached to the GitHub Release on
the signed path; the upload is noted in the workflow's step summary.

Before the first upload can succeed, the app must exist in App Store Connect: go to
[App Store Connect → My Apps → +](https://appstoreconnect.apple.com/apps) and register
`org.dotpostcard.collector` if you haven't already (the bundle ID must already exist under
[Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list)).

### Sparkle auto-updates (macOS)

| Secret | What it is |
| --- | --- |
| `SPARKLE_ED_PRIVATE_KEY` | The private half of the EdDSA (ed25519) keypair Sparkle uses to sign update archives. |

The macOS app embeds the matching **public** key (`SUPublicEDKey`) directly in its Info.plist
via `project.yml`, so the private key is the only piece that needs to reach CI. Generate it with
Sparkle's own `generate_keys` tool (ships in the
[Sparkle release archive](https://github.com/sparkle-project/Sparkle/releases), under `bin/`):

```sh
./generate_keys
```

This stores the private key in the maintainer's **login Keychain**, under the item Sparkle's own
tooling creates and expects (`generate_keys`'s default account, `ed25519` — don't rename it, or
future `generate_keys`/`sign_update` runs on this machine won't find it), and prints the public
key to paste into `SUPublicEDKey` if it ever needs rotating. Export the private key for the
`SPARKLE_ED_PRIVATE_KEY` secret with:

```sh
./generate_keys -x /tmp/sparkle_private_key
cat /tmp/sparkle_private_key | pbcopy
rm /tmp/sparkle_private_key
```

Without this secret, the release workflow skips appcast generation entirely — macOS artifacts
still build and publish as before, they just won't be discoverable as updates by Sparkle. Once
the secret is present, every tagged release additionally gets an `appcast.xml` asset generated
from that release's `Postcards-macOS.zip` and uploaded to the same GitHub Release (this doesn't
require the Developer ID/notarization secrets above — Sparkle's own signature check only needs
the archived app's embedded `SUPublicEDKey` to match, independent of Apple code signing — though
in practice you'll want both, since Gatekeeper blocks launching an unsigned auto-downloaded
update regardless of Sparkle's own checks). **This is a hard invariant going forward: every
release from now on must carry an `appcast.xml`**, because the app's `SUFeedURL` points at
`releases/latest/download/appcast.xml` — a release that skips it (secret missing, or the appcast
step failing) leaves existing installs unable to see any update past it, including ones published
later, until a subsequent release restores the file at `/latest/`.

The first version able to check for and apply updates via Sparkle is the one built from the
release immediately after this Sparkle integration lands — earlier installs have no updater and
must be reinstalled manually.

## Cutting a release

```sh
git tag v1.2.3
git push --tags
```

This triggers `release.yaml`, which produces a GitHub Release on the pushed tag with generated
release notes and whatever artifacts the available secrets allow:

| Secrets present | macOS artifact | iOS artifact |
| --- | --- | --- |
| None | `Postcards-macOS.zip` (unsigned `.app`) | `Postcards-iOS-simulator.zip` (unsigned Simulator build) |
| macOS cert + macOS profile | `Postcards-macOS.zip` (Developer ID signed, not notarized) | `Postcards-iOS-simulator.zip` |
| + notary key | `Postcards-macOS.zip` (signed, notarized, stapled) | `Postcards-iOS-simulator.zip` |
| + iOS cert + iOS profile + ASC key | (as above) | Uploaded to TestFlight — no iOS file on the release (see step summary) |

## Bumping the pinned dotpostcard ref

Both workflows pin `DOTPOSTCARD_REF` (near the top of each file) to a
[jphastings/dotpostcard](https://github.com/jphastings/dotpostcard) release tag (or, if the
code this app needs isn't in a release yet, a full commit SHA). To pick up new dotpostcard
changes, update `DOTPOSTCARD_REF` in both `ci.yaml` and `release.yaml` to the new tag/SHA —
the XCFramework build cache is keyed on this value, so the first run after a bump rebuilds
(~10 min) and later runs reuse it.
