# Releasing ShakeToEject

This project ships updates via [Sparkle 2](https://sparkle-project.org/). Users
running any prior release receive updates automatically (or via the
"Check for Updates…" menu) as long as the appcast at
`https://raw.githubusercontent.com/mcomisso/ShakeToEject/main/appcast.xml`
advertises a newer signed build.

---

## One-time setup

Do each of these exactly once. They establish the signing material and
credentials the release script depends on.

### 1. Generate the Sparkle EdDSA keypair

Sparkle requires every update to be signed by a private key whose public
half is baked into the *previously-shipped* version of the app. **If the
private key is lost, no future update can be delivered to existing users
without forcing them to re-download manually.** Back it up immediately.

```bash
# Pull a Sparkle checkout just to run its key tool (the SPM copy works too
# if you can find generate_keys under ~/Library/Developer/Xcode/DerivedData).
git clone https://github.com/sparkle-project/Sparkle /tmp/sparkle
cd /tmp/sparkle
./bin/generate_keys
```

- [ ] Copy the public key printed to stdout. Open `project.yml`, replace
  `REPLACE_WITH_ED25519_PUBLIC_KEY` under `info.properties.SUPublicEDKey`
  with the real key. Run `xcodegen generate` and commit.
- [ ] Export and back up the private key:
  ```bash
  ./bin/generate_keys --export backup.key
  ```
  Store `backup.key` somewhere safe (password manager, encrypted drive,
  separate Mac). The Keychain also holds a copy, under account
  `ed25519`, service `https://sparkle-project.org`.

### 2. Set up `notarytool` credentials

```bash
xcrun notarytool store-credentials "ShakeToEject" \
    --apple-id "<your-apple-id>" \
    --team-id "382G4857JD" \
    --password "<app-specific-password>"
```

Generate the app-specific password at
[appleid.apple.com → Sign-In and Security → App-Specific Passwords](https://appleid.apple.com/).

Verify:
```bash
xcrun notarytool history --keychain-profile "ShakeToEject"
```

### 3. Confirm signing identity

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Expected: a single matching identity for team `382G4857JD`.

### 4. Warm the Sparkle build products

Build the app at least once so SPM resolves Sparkle and its bundled
`generate_appcast` binary ends up in DerivedData.

```bash
xcodebuild -scheme ShakeToEject -configuration Release build
```

---

## Per-release checklist

### Bump the version

- [ ] Edit `project.yml` → `targets.ShakeToEject.settings.base.MARKETING_VERSION`.
- [ ] Increment `CURRENT_PROJECT_VERSION` (build number) — must be strictly greater than the previous build.
- [ ] `xcodegen generate`.
- [ ] Build locally once to catch any compile issues before running the release script.

### Build, sign, notarize, publish

- [ ] `scripts/release.sh <version>` — e.g. `scripts/release.sh 1.0.1`.
      The script:
      - Validates `project.yml` MARKETING_VERSION matches `<version>`.
      - Builds Release with a clean DerivedData.
      - Verifies the app is Developer-ID-signed.
      - Produces `releases/ShakeToEject-<version>.zip` (ditto archive, signature-preserving).
      - Submits to Apple notary service and waits for approval.
      - Staples the ticket to the `.app` and re-zips.
      - Appends a signed `<item>` to `appcast.xml` via `generate_appcast`.
- [ ] Inspect the updated `appcast.xml`. The new `<item>` must contain:
      - `sparkle:version` — build number
      - `sparkle:shortVersionString` — marketing version
      - `enclosure url` — pointing at the GitHub Release asset
      - `enclosure sparkle:edSignature` — non-empty
- [ ] Commit + tag + push:
      ```bash
      git add appcast.xml project.yml
      git commit -m "Release v<version>"
      git tag v<version>
      git push && git push --tags
      ```
- [ ] Create the GitHub Release at the new tag. Title: `v<version>`.
      Upload `releases/ShakeToEject-<version>.zip` as the release asset.
      The download URL must be
      `https://github.com/mcomisso/ShakeToEject/releases/download/v<version>/ShakeToEject-<version>.zip`
      — matching the `--download-url-prefix` the script passed to
      `generate_appcast`.

### Verify the upgrade path

- [ ] On a Mac with the previous version installed (or from a saved copy
      of the previous `.app`), launch the old version.
- [ ] Click the menu bar icon → "Check for Updates…". Sparkle should
      offer the new version with release notes.
- [ ] Click "Install Update". Sparkle replaces the app and relaunches it.
- [ ] Confirm the menu bar shows the new version string.
- [ ] Run a manual shake / "Simulate Shake (dev)" to confirm core
      functionality survived the update.

---

## Troubleshooting

**"Unable to check for updates" dialog on a real client**
- Appcast URL returning 404: confirm `appcast.xml` was pushed to `main`.
- DNS/network issue on the client: check Console.app for Sparkle log lines.

**Sparkle reports "signature verification failed"**
- Public key in shipped app doesn't match the private key that signed the update.
  Either the private key was lost/regenerated, or the appcast entry was
  hand-edited. Re-run `scripts/release.sh` with the correct key in the
  Keychain.

**Notary submission rejected**
- Run `xcrun notarytool log <submission-id> --keychain-profile "ShakeToEject"`
  to see the reason. Most common: hardened runtime not enabled (already
  is, globally), or a new framework without a valid signature (Sparkle
  itself ships pre-signed).

**`generate_appcast` not found**
- SPM's build products only include it after at least one successful
  build. Run `xcodebuild build` and retry the release script.
