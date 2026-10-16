# Publishing to the Mac App Store

The repository already has everything the build needs:

- `Resources/TransferSpeed.entitlements` sandboxes the app (`com.apple.security.app-sandbox`) and lets it read and write only what the user picks (`com.apple.security.files.user-selected.read-write`). Both `./build.sh` (Developer ID / DMG) and `./build.sh mas` sign with it.
- `Resources/Info.plist` declares `ITSAppUsesNonExemptEncryption = false`, which answers the export-compliance question for every upload.
- `./build.sh mas <profile>` signs the app with an **Apple Distribution** certificate, embeds the provisioning profile, adds the application and team identifiers to the signature, records the Xcode/SDK versions in `Info.plist` the way Xcode does, and writes `build/TransferSpeed-<version>.pkg` signed with the **Mac Installer Distribution** certificate. It stops with a list of what is missing when a certificate or the profile isn't there.

What is left happens in your Apple Developer account and App Store Connect. None of it has been done yet.

## 1. Register the bundle ID

[Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list) → **+** → **App IDs** → **App**.

- Description: `Transfer Speed`
- Bundle ID: **Explicit**, `com.hna.TransferSpeed` (the value of `CFBundleIdentifier` in `Resources/Info.plist`)
- Capabilities: none. App Sandbox is an entitlement, not a capability you enable here.

To use a different ID, change `CFBundleIdentifier` in `Resources/Info.plist`, or set `BUNDLE_ID=…` when running `build.sh`.

## 2. Certificates

Two certificates, each with its private key in your login keychain:

| Certificate | Shows up in the keychain as | Status |
| --- | --- | --- |
| Apple Distribution | `Apple Distribution: haluk arazli (5PFNQ99HTM)` | missing |
| Mac Installer Distribution | `3rd Party Mac Developer Installer: haluk arazli (5PFNQ99HTM)` | already installed |

Easiest: Xcode → Settings → Accounts → select the team → **Manage Certificates…** → **+** → **Apple Distribution**. Or create a certificate signing request in Keychain Access (Certificate Assistant → Request a Certificate From a Certificate Authority, saved to disk), upload it at [Certificates](https://developer.apple.com/account/resources/certificates/list) → **+** → **Apple Distribution**, and double-click the downloaded `.cer`.

Check with:

```bash
security find-identity -v
```

## 3. Provisioning profile

[Profiles](https://developer.apple.com/account/resources/profiles/list) → **+** → Distribution → **Mac App Store Connect** → App ID `com.hna.TransferSpeed` → the Apple Distribution certificate → name it `Transfer Speed Mac App Store` → download.

Keep the `.provisionprofile` outside the repository, for example in `~/Developer/Profiles/`. It expires after a year; regenerate it then (and whenever you renew the certificate).

## 4. Build the package

```bash
./build.sh mas ~/Developer/Profiles/Transfer_Speed_Mac_App_Store.provisionprofile
```

The script checks that the profile is a Mac App Store profile for `<team>.com.hna.TransferSpeed`, that it hasn't expired, and that both certificates belong to the same team.

App Store Connect rejects a build number it has already seen, so bump `CFBundleVersion` in `Resources/Info.plist` before every upload (and `CFBundleShortVersionString` for each new public version).

An app signed for the Mac App Store won't launch straight from the package on your Mac. To try the exact build before release, use TestFlight (step 9). To try the sandbox itself, `./build.sh` produces the same sandboxed app signed with Developer ID, which runs locally.

## 5. Create the app record in App Store Connect

[App Store Connect → Apps](https://appstoreconnect.apple.com/apps) → **+** → **New App**:

- Platform: macOS
- Name: `Transfer Speed` (names are unique across the store; if it's taken, try something like `Transfer Speed – Disk Test`)
- Primary language
- Bundle ID: pick `com.hna.TransferSpeed` (appears once step 1 is done)
- SKU: any private identifier, e.g. `TRANSFERSPEED`
- User access: Full Access

## 6. Privacy policy and App Privacy

A privacy policy URL is required even though the app collects nothing. A GitHub Pages page works:

1. Add `docs/privacy.md` with something like:

   > Transfer Speed doesn't collect, store or send any personal data. It has no accounts, analytics, advertising or network access. Files it copies or test files it writes stay on the drives you choose, and benchmark test files are deleted when the test ends.

2. Repository → Settings → Pages → Deploy from branch `main`, folder `/docs`.
3. Use `https://hhabi9.github.io/TransferSpeed/privacy` as the Privacy Policy URL.

Under **App Privacy**, answer **Data Not Collected**.

## 7. Store listing

On the version page:

- **Screenshots**: at least one, 16:10, at 1280×800, 1440×900, 2560×1600 or 2880×1800. A good set is Copy mid-transfer with the graph, a finished Benchmark, and the drive picker. Capture just the window (`⌘⇧4`, then Space, then click it), then place it on a background at one of those sizes.
- **Description**, **Keywords** (e.g. `disk speed, ssd, benchmark, copy, transfer, usb, thunderbolt, nas, smb`), **Support URL** (`https://github.com/hhabi9/TransferSpeed/issues`), optional **Marketing URL**.
- **Category**: Utilities (matches `LSApplicationCategoryType`).
- **Age rating** questionnaire: no objectionable content.
- **Copyright**: e.g. `2026 haluk arazli`.
- **Pricing and Availability**: price tier and countries.

## 8. Upload

With [Transporter](https://apps.apple.com/app/transporter/id1450874784): sign in, drag `build/TransferSpeed-<version>.pkg` in, **Deliver**.

Or from the command line, with an App Store Connect API key (Users and Access → Integrations → App Store Connect API) saved as `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`:

```bash
xcrun altool --validate-app -f build/TransferSpeed-1.0.pkg -t macos --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
xcrun altool --upload-app -f build/TransferSpeed-1.0.pkg -t macos --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

Processing takes a few minutes to an hour; App Store Connect emails you if the build has problems.

## 9. TestFlight (optional)

Once the build has processed, add yourself as an internal tester under TestFlight and install it with the TestFlight app. This is the only way to run the exact Mac App Store–signed binary before release.

## 10. Submit for review

Pick the build on the version page, fill in **App Review Information** (contact details; no sign-in required), and add review notes such as:

> Copy: choose files or folders and a destination (or drop them on the window), then Start Copy.
> Benchmark: pick a drive and click Start Test. The first time a drive is tested, the app asks for permission to write to it through an Open panel; click Allow. A temporary test file is written, read back and deleted. Mac internal disk tests run in the app's own container.

Then **Add for Review** → **Submit**.

## How the sandbox changes the app

- Copy mode works only on what the user picks in an Open panel or drops on the window, plus everything inside picked folders. Access lasts until the app quits.
- Benchmark mode tests the Mac's internal disk in the app container's temporary folder. For any other drive, the first test opens an Open panel already pointed at that drive; the access is saved as a security-scoped bookmark, so later tests (also after relaunch) don't ask again. "Choose Folder…" works as before.
- macOS adds a `com.apple.quarantine` attribute to every file a sandboxed app writes, so copies carry it even when the originals didn't. It makes no difference for documents and media; copied apps and scripts get the usual Gatekeeper check the first time they're opened.
- The Developer ID build from `./build.sh` / `./build.sh dmg` is sandboxed the same way, so the DMG and the App Store version behave identically and share their container and saved drive permissions.
