# ShakeToEject — Phase 12: Sparkle Auto-Update

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship user-initiated and automatic updates via Sparkle 2 so users running v1.0.0 can receive v1.0.1+ without manually re-downloading. Respect the app's non-sandboxed, hardened-runtime, Developer-ID-signed posture.

**Why Sparkle:** De-facto macOS updater framework, SPM-installable, handles self-replacement + notarization checks, supports EdDSA signatures, works inside the hardened runtime without extra entitlements for non-sandboxed apps. See the research note in the Sparkle conversation thread.

**Tech stack addition:** Sparkle 2.8.x via Swift Package Manager.

---

## Phase 12A — Library integration & core wiring

Goal: App builds with Sparkle, updater initializes at launch, "Check for Updates…" menu item works. No release pipeline yet — the feed URL is a placeholder and updates won't actually install because there's no signed appcast.

### Task 1: Add Sparkle as an SPM dependency via XcodeGen

**Files:** `project.yml`

- [ ] **Step 1:** Add a top-level `packages` block pinning Sparkle to the 2.8.x line:

  ```yaml
  packages:
    Sparkle:
      url: https://github.com/sparkle-project/Sparkle
      from: "2.8.0"
  ```

- [ ] **Step 2:** Add a `dependencies` entry to the `ShakeToEject` target:

  ```yaml
      dependencies:
        - package: Sparkle
  ```

- [ ] **Step 3:** Regenerate the project:

  ```bash
  xcodegen generate
  ```

  Expected: no errors. `Package.resolved` gets written. Xcode will resolve Sparkle on next open/build.

### Task 2: Declare Sparkle Info.plist keys

**Files:** `project.yml`

Sparkle reads its configuration from the app's Info.plist. Since the app uses `GENERATE_INFOPLIST_FILE: YES`, we inject these as `INFOPLIST_KEY_*` build settings.

- [ ] **Step 1:** Add the following under `targets.ShakeToEject.settings.base`:

  ```yaml
        INFOPLIST_KEY_SUFeedURL: "https://raw.githubusercontent.com/mcomisso/ShakeToEject/main/appcast.xml"
        INFOPLIST_KEY_SUPublicEDKey: "REPLACE_WITH_ED25519_PUBLIC_KEY"
        INFOPLIST_KEY_SUEnableAutomaticChecks: "YES"
        INFOPLIST_KEY_SUScheduledCheckInterval: "86400"
  ```

  Notes:
  - `SUFeedURL` — appcast hosted at repo root on `main`. Easy to publish via a normal git push. Can be moved to a github.io Pages path later.
  - `SUPublicEDKey` — placeholder. Phase 12B generates the real key. With a placeholder value Sparkle will refuse to install updates (fail-safe).
  - `SUEnableAutomaticChecks: YES` — default-on, overridable by user via the Dashboard toggle (Task 6).
  - `86400` seconds = 24h check interval.

- [ ] **Step 2:** Regenerate and confirm the keys land in the built `Info.plist`:

  ```bash
  xcodegen generate
  xcodebuild -project ShakeToEject.xcodeproj -scheme ShakeToEject -configuration Debug build 2>&1 | tail -20
  /usr/libexec/PlistBuddy -c "Print :SUFeedURL" $(find ~/Library/Developer/Xcode/DerivedData/ShakeToEject-* -name Info.plist -path "*Debug*" -not -path "*Tests*" | head -1)
  ```

  Expected: the placeholder URL prints.

### Task 3: Create `UpdaterService`

**Files:** `App/Updater/UpdaterService.swift` (new)

A thin `@MainActor @Observable` wrapper over `SPUStandardUpdaterController` so SwiftUI views can bind to a couple of observable properties (can-check, auto-check-enabled) without importing Sparkle into every view.

- [ ] **Step 1:** Create the file with this content:

  ```swift
  import Foundation
  import Observation
  import Sparkle

  /// Thin wrapper around Sparkle's `SPUStandardUpdaterController` so
  /// SwiftUI views can read/bind auto-check state without importing
  /// Sparkle directly. Owns exactly one updater controller for the
  /// app's lifetime; create once in `AppDelegate`.
  @MainActor
  @Observable
  final class UpdaterService {
      private let controller: SPUStandardUpdaterController

      /// Mirrors `updater.automaticallyChecksForUpdates` so the
      /// Dashboard toggle observes it. Writing triggers Sparkle to
      /// persist the preference.
      var automaticallyChecksForUpdates: Bool {
          didSet {
              controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
          }
      }

      /// True when a check can be kicked off right now. Sparkle keeps
      /// this in sync — views bind their menu item's `disabled` state
      /// to this.
      var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

      init() {
          // startingUpdater: true  — begin the scheduled-check loop
          // immediately. delegate/userDriverDelegate: nil — we rely
          // on Sparkle's default UI, which is fine for v1.
          self.controller = SPUStandardUpdaterController(
              startingUpdater: true,
              updaterDelegate: nil,
              userDriverDelegate: nil
          )
          self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
      }

      /// User-initiated check. Sparkle shows its standard UI (progress,
      /// "up to date", "update available") regardless of feed state.
      func checkForUpdates() {
          controller.checkForUpdates(nil)
      }
  }
  ```

- [ ] **Step 2:** Confirm Swift 6 strict concurrency compiles this without warnings. `SPUStandardUpdaterController` is `@MainActor`-friendly via its Obj-C heritage; wrapping it in a `@MainActor` class is sufficient.

### Task 4: Wire UpdaterService into AppDelegate

**Files:** `App/ShakeToEjectApp.swift`

- [ ] **Step 1:** Add `let updater = UpdaterService()` alongside the other services on `AppDelegate`. No launch-time wiring needed — the controller starts itself in `init`.

- [ ] **Step 2:** Pass `updater` into `MenuBarContent` and `DashboardView` via the existing dependency style (explicit constructor args).

### Task 5: Add "Check for Updates…" to the menu bar

**Files:** `App/MenuBar/MenuBarContent.swift`, `App/ShakeToEjectApp.swift` (updated call site)

- [ ] **Step 1:** Add an `updater: UpdaterService` property to `MenuBarContent`.

- [ ] **Step 2:** Insert a new section before the final "Quit" divider:

  ```swift
  Divider()

  Button("Check for Updates…") {
      updater.checkForUpdates()
  }
  .disabled(!updater.canCheckForUpdates)
  ```

- [ ] **Step 3:** Update the `MenuBarExtra` call site in `ShakeToEjectApp.swift` to pass `updater: appDelegate.updater`.

### Task 6: Add an "Updates" section to the Dashboard

**Files:** `App/Views/DashboardView.swift`

- [ ] **Step 1:** Add an `updater: UpdaterService` parameter and route it through `AppDelegate.openDashboard()`.

- [ ] **Step 2:** Add a new `Section("Updates")` block:

  ```swift
  Section("Updates") {
      Toggle("Automatically check for updates", isOn: Binding(
          get: { updater.automaticallyChecksForUpdates },
          set: { updater.automaticallyChecksForUpdates = $0 }
      ))
      Button("Check Now") {
          updater.checkForUpdates()
      }
      .disabled(!updater.canCheckForUpdates)
      Text("Current version: \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
          .font(.caption)
          .foregroundStyle(.secondary)
  }
  ```

- [ ] **Step 2.5:** If `Bundle.buildNumber` doesn't exist in the codebase, add it next to `shortVersion`:

  ```swift
  var buildNumber: String {
      (infoDictionary?["CFBundleVersion"] as? String) ?? "0"
  }
  ```

### Task 7: Build, run, and verify Phase 12A

- [ ] **Step 1:** `xcodegen generate && xcodebuild -scheme ShakeToEject build`. Expect no errors.
- [ ] **Step 2:** Launch the app. Click the menu bar icon → "Check for Updates…". Expect Sparkle's dialog to appear and either show "Unable to check for updates" (no appcast yet, expected) or "Up to date".
- [ ] **Step 3:** Open the Dashboard → Updates section. Toggle auto-check off and on; relaunch; verify state persists.
- [ ] **Step 4:** Commit: `feat: Sparkle SPM integration and menu/dashboard wiring`.

**Exit criteria for 12A:** App ships Sparkle. UI is wired. Feed URL and public key are placeholders; no real updates can install yet. App is still shippable in this state — Sparkle fails closed when it can't verify a signature.

---

## Phase 12B — Release pipeline (keys, appcast, hosting)

Goal: Generate the EdDSA keypair, scaffold the appcast, document the release process so publishing v1.0.1 becomes a repeatable checklist.

### Task 8: Generate the EdDSA signing keypair

**Files:** (none in repo — key handling is out-of-tree)

The Sparkle SPM package includes `generate_keys` and `sign_update` binaries in its `bin/` directory inside the SPM checkout. The private key lives in the macOS Keychain; only the public key ends up in the app.

- [ ] **Step 1:** Locate the Sparkle tools in the SPM build products:

  ```bash
  find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -path "*Sparkle*" 2>/dev/null | head -1
  ```

  Alternatively clone Sparkle directly: `git clone https://github.com/sparkle-project/Sparkle && cd Sparkle && ./bin/generate_keys`.

- [ ] **Step 2:** Run `generate_keys` **once**. It stores the private key in the Keychain (account `ed25519`, service `https://sparkle-project.org`) and prints the public key to stdout.

- [ ] **Step 3:** Copy the public key. Replace the `SUPublicEDKey` placeholder in `project.yml`:

  ```yaml
        INFOPLIST_KEY_SUPublicEDKey: "PASTE_PUBLIC_KEY_HERE"
  ```

- [ ] **Step 4:** Back up the private key by running `generate_keys --export backup.key`. Store that file somewhere safe (password manager, encrypted drive). **Losing the private key means no future update can be signed against this app's installed public key — users would need to re-download manually.**

- [ ] **Step 5:** Commit the `SUPublicEDKey` change. The public key in the binary is safe to commit — that's the whole point.

### Task 9: Scaffold the appcast and release-build script

**Files:** `appcast.xml` (new), `scripts/release.sh` (new)

- [ ] **Step 1:** Create an empty `appcast.xml` at the repo root with no items yet:

  ```xml
  <?xml version="1.0" standalone="yes"?>
  <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
      <channel>
          <title>ShakeToEject</title>
          <link>https://raw.githubusercontent.com/mcomisso/ShakeToEject/main/appcast.xml</link>
          <description>Updates for ShakeToEject</description>
          <language>en</language>
      </channel>
  </rss>
  ```

- [ ] **Step 2:** Create `scripts/release.sh` (chmod +x) that automates the release build, signs it, and regenerates the appcast:

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  # Usage: scripts/release.sh 1.0.1
  VERSION="${1:?usage: $0 <version>}"
  BUILD_DIR="$(mktemp -d)"
  RELEASES_DIR="releases"
  GENERATE_APPCAST="$(find ~/Library/Developer/Xcode/DerivedData -name generate_appcast -path '*Sparkle*' 2>/dev/null | head -1)"

  if [[ -z "$GENERATE_APPCAST" ]]; then
      echo "generate_appcast not found — build the app once in Xcode first so SPM resolves Sparkle's tools."
      exit 1
  fi

  echo "==> Building Release archive for $VERSION"
  xcodebuild -scheme ShakeToEject -configuration Release \
      -derivedDataPath "$BUILD_DIR" \
      MARKETING_VERSION="$VERSION" \
      build

  APP_PATH=$(find "$BUILD_DIR/Build/Products/Release" -name "ShakeToEject.app" -maxdepth 2 | head -1)
  [[ -n "$APP_PATH" ]] || { echo "App not found"; exit 1; }

  echo "==> Creating DMG"
  mkdir -p "$RELEASES_DIR"
  DMG="$RELEASES_DIR/ShakeToEject-$VERSION.dmg"
  rm -f "$DMG"
  hdiutil create -volname "ShakeToEject $VERSION" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG"

  echo "==> Notarizing (requires notarytool profile 'ShakeToEject' set up via Xcode)"
  xcrun notarytool submit "$DMG" --keychain-profile "ShakeToEject" --wait
  xcrun stapler staple "$DMG"

  echo "==> Regenerating appcast"
  "$GENERATE_APPCAST" "$RELEASES_DIR" \
      --download-url-prefix "https://github.com/mcomisso/ShakeToEject/releases/download/v$VERSION/" \
      -o appcast.xml

  echo "==> Done. Next steps:"
  echo "  1. git add appcast.xml && git commit -m 'Release v$VERSION'"
  echo "  2. git tag v$VERSION && git push && git push --tags"
  echo "  3. Create GitHub Release with $DMG attached"
  ```

- [ ] **Step 3:** Add `releases/` to `.gitignore` (DMGs are large; distribute via GitHub Releases, not git):

  ```
  releases/
  ```

### Task 10: Set up notarytool keychain profile

**Files:** (none — one-time local setup)

- [ ] **Step 1:** From the App Store Connect web UI, generate an app-specific password for Apple ID notarization (or create an API key pair).

- [ ] **Step 2:** Register the credentials as a keychain profile named `ShakeToEject`:

  ```bash
  xcrun notarytool store-credentials "ShakeToEject" \
      --apple-id "<your-apple-id>" \
      --team-id "382G4857JD" \
      --password "<app-specific-password>"
  ```

- [ ] **Step 3:** Verify with a dry submission: `xcrun notarytool history --keychain-profile "ShakeToEject"`.

### Task 11: Document the release workflow

**Files:** `docs/RELEASING.md` (new)

- [ ] **Step 1:** Create a short runbook:

  ```markdown
  # Releasing ShakeToEject

  ## One-time setup
  - [ ] `generate_keys` run; public key in `project.yml` as `SUPublicEDKey`; private key in Keychain and backed up
  - [ ] `notarytool` profile `ShakeToEject` configured
  - [ ] Developer ID Application certificate installed

  ## Per release
  1. Bump `MARKETING_VERSION` in `project.yml` and regenerate the project.
  2. Update `CHANGELOG.md` (if/when it exists).
  3. Run `scripts/release.sh X.Y.Z`. The script builds, signs, notarizes, staples, generates the appcast.
  4. Push the commit and tag: `git push && git push --tags`.
  5. Create a GitHub Release at `v<version>`, attach `releases/ShakeToEject-<version>.dmg`.
  6. Smoke-test: install the previous version on a clean Mac, run it, "Check for Updates…" should find the new release.
  ```

**Exit criteria for 12B:** A real release of v1.0.1 can be produced and verified to install on top of v1.0.0 via Sparkle's UI.

---

## Phase 12C — End-to-end verification

Goal: Prove the update flow actually works before the first real release goes out.

### Task 12: Cut a v1.0.1 test release

- [ ] **Step 1:** Make a trivial, visible change (e.g., a new panic line in `WarningCoordinator.panicLines`).
- [ ] **Step 2:** Bump `MARKETING_VERSION` to `1.0.1` in `project.yml`. Regenerate.
- [ ] **Step 3:** Run `scripts/release.sh 1.0.1`. Confirm the script produces a notarized, stapled DMG and appends an item to `appcast.xml`.
- [ ] **Step 4:** Publish the GitHub Release with the DMG attached; push `appcast.xml`.

### Task 13: Verify the upgrade path

- [ ] **Step 1:** On a second Mac (or after archiving the current `/Applications/ShakeToEject.app`), install the v1.0.0 DMG from the prior release.
- [ ] **Step 2:** Launch it. Wait for the scheduled check, or click "Check for Updates…".
- [ ] **Step 3:** Expected: Sparkle's dialog shows v1.0.1 with release notes. Click "Install Update". Sparkle replaces the app and relaunches it.
- [ ] **Step 4:** Confirm the new panic line appears after a simulated shake.

### Task 14: Regression sweep

- [ ] **Step 1:** Toggle "Automatically check for updates" off in the Dashboard. Quit and relaunch; verify Sparkle does not auto-check for 24h.
- [ ] **Step 2:** Turn it back on; relaunch; confirm scheduled-check logs appear (NSLog or Console filter "Sparkle").
- [ ] **Step 3:** Verify shake-to-eject still works end-to-end after an update (sensor running, warning overlay, eject).

**Exit criteria for 12C:** A real previous-version install can update itself to the new version in one click. Auto-check preference persists. No regressions in core shake-to-eject flow.
