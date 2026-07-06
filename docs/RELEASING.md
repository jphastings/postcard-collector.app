# Releasing

CI (`.github/workflows/ci.yaml`) builds the Go XCFramework, generates the Xcode project, builds
both platforms, and runs `PostcardsTests` on every push to `main` and every PR.

Tagged releases (`.github/workflows/release.yaml`) additionally archive, sign, notarize, and
publish macOS + iOS artifacts to a GitHub Release — but only once you've added the secrets below.
**Without the secrets, the release workflow still runs and still publishes a release**, just with
unsigned artifacts (an unsigned `.app.zip` on macOS, an unsigned iOS Simulator `.app.zip`
instead of a TestFlight upload).

Because the app uses iCloud — a *restricted* entitlement that manually installed provisioning
profiles can't carry — signing uses Xcode's cloud-managed automatic signing
(`-allowProvisioningUpdates` plus an App Store Connect API key), which creates/fetches profiles
with the iCloud capability on the fly. This means the `ASC_*` secrets are required for signed
builds of **both** platforms, not just the TestFlight upload.

## Repo secrets

Add these under **Settings → Secrets and variables → Actions**.

### macOS signing (Developer ID)

| Secret | What it is |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Your **Developer ID Application** certificate + private key, exported as a `.p12`, base64-encoded. |
| `P12_PASSWORD` | The password you set when exporting the `.p12`. |
| `KEYCHAIN_PASSWORD` | Any password — used only to lock/unlock the throwaway CI keychain. Reused by the iOS job too. |

**Exporting the certificate:**

1. Open **Keychain Access** → `My Certificates`, find "Developer ID Application: ...".
2. Right-click → **Export...** → save as `cert.p12`, set a password (this is `P12_PASSWORD`).
3. `base64 -i cert.p12 | pbcopy` → paste into the `BUILD_CERTIFICATE_BASE64` secret.

If you don't have a Developer ID Application certificate yet, create one at
[developer.apple.com → Certificates](https://developer.apple.com/account/resources/certificates/list)
(type: "Developer ID Application"), download it, double-click to install it into your login
keychain, then export as above.

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

No provisioning profile secret is needed: cloud signing fetches/creates the profile itself.
If you previously added `IOS_PROVISIONING_PROFILE_BASE64`, it's now unused and can be deleted.

### Cloud signing & TestFlight upload (App Store Connect API key)

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

These secrets do double duty:

- **Both platforms** archive with cloud-managed automatic signing
  (`-allowProvisioningUpdates` + this key), so Xcode can provision the restricted iCloud
  entitlement. Without `ASC_*`, both platforms fall back to unsigned artifacts, even if the
  certificates are present.
- **iOS** additionally exports with `method: app-store-connect` + `destination: upload`, which
  sends the build straight to TestFlight instead of writing an `.ipa` — so no iOS file is
  attached to the GitHub Release on the signed path; the upload is noted in the workflow's
  step summary.

Before the first upload can succeed, the app must exist in App Store Connect: go to
[App Store Connect → My Apps → +](https://appstoreconnect.apple.com/apps) and register
`org.dotpostcard.collector` if you haven't already (the bundle ID must already exist under
[Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list)).

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
| ASC key + macOS cert | `Postcards-macOS.zip` (Developer ID signed, not notarized) | `Postcards-iOS-simulator.zip` |
| ASC key + macOS cert + notary key | `Postcards-macOS.zip` (signed, notarized, stapled) | `Postcards-iOS-simulator.zip` |
| ASC key + both certs + notary key | (as above) | Uploaded to TestFlight — no iOS file on the release (see step summary) |

## Bumping the pinned dotpostcard ref

Both workflows pin `DOTPOSTCARD_REF` (near the top of each file) to a
[jphastings/dotpostcard](https://github.com/jphastings/dotpostcard) release tag (or, if the
code this app needs isn't in a release yet, a full commit SHA). To pick up new dotpostcard
changes, update `DOTPOSTCARD_REF` in both `ci.yaml` and `release.yaml` to the new tag/SHA —
the XCFramework build cache is keyed on this value, so the first run after a bump rebuilds
(~10 min) and later runs reuse it.
