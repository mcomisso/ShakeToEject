# ShakeToEject — Phase 0: Scaffolding & Hardware Verification

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stock Xcode SwiftData template with an XcodeGen-managed project containing two targets — a menu bar application and a privileged command-line helper embedded in the app bundle — and verify the target hardware has the BMI286 IMU sensor.

**Architecture:** XcodeGen `project.yml` is the source of truth. The main app builds as a `LSUIElement` SwiftUI app using `MenuBarExtra`. The helper builds as a `tool` target, and a post-build script on the app copies the helper binary to `Contents/MacOS/` and its launchd plist to `Contents/Library/LaunchDaemons/` inside the built `.app`. No code in this phase touches IOKit, XPC, or DiskArbitration — those come in later phases.

**Tech Stack:** XcodeGen, Swift 6, SwiftUI `MenuBarExtra`, macOS 14 deployment target, Xcode 26.

**Prerequisites before starting this phase:**
- `xcodegen` installed (`brew install xcodegen`) — confirmed present at `/opt/homebrew/bin/xcodegen`.
- Apple Developer account configured in Xcode (free personal team is fine). You will need the Team ID for signing the helper. If you do not yet have one: Xcode → Settings → Accounts → "+" → Apple ID.
- Working on a MacBook Pro with an M1 Pro, M2, M2 Pro/Max, M3, M3 Pro/Max, or M4 chip. Other Apple Silicon chips will fail Task 10.

---

### Task 1: Remove the Stock Xcode Template

**Files:**
- Delete: `ShakeToEject.xcodeproj/`
- Delete: `ShakeToEject/` (the inner directory containing `ShakeToEjectApp.swift`, `ContentView.swift`, `Item.swift`, `Assets.xcassets/`)
- Delete: `ShakeToEjectTests/`
- Delete: `ShakeToEjectUITests/`

- [ ] **Step 1: Delete the stock project and source directories**

Run from the repo root:

```bash
rm -rf ShakeToEject.xcodeproj
rm -rf ShakeToEject
rm -rf ShakeToEjectTests
rm -rf ShakeToEjectUITests
```

- [ ] **Step 2: Verify the deletion**

```bash
ls
```

Expected output: only `docs/` and `.git/` remain (plus any hidden files).

---

### Task 2: Create Directory Skeleton

**Files:**
- Create: `App/`, `App/MenuBar/`, `App/Windows/`, `App/Views/`, `App/Services/`, `App/Resources/Sounds/`
- Create: `Helper/`, `Helper/Launchd/`
- Create: `Shared/`
- Create: `Tests/`

- [ ] **Step 1: Create the directory tree**

```bash
mkdir -p App/MenuBar App/Windows App/Views App/Services App/Resources/Sounds
mkdir -p Helper/Launchd
mkdir -p Shared
mkdir -p Tests
```

- [ ] **Step 2: Add a placeholder in empty directories**

XcodeGen skips empty directories by default. Add a `.gitkeep` to each leaf directory that will not have source files yet:

```bash
touch App/MenuBar/.gitkeep
touch App/Windows/.gitkeep
touch App/Views/.gitkeep
touch App/Services/.gitkeep
touch App/Resources/Sounds/.gitkeep
touch Tests/.gitkeep
```

- [ ] **Step 3: Verify the tree**

```bash
find App Helper Shared Tests -type d
```

Expected: the tree above, all directories present.

---

### Task 3: Create `.gitignore`

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Write the gitignore**

Create `.gitignore` at the repo root with this exact content:

```gitignore
# Xcode build artifacts
build/
DerivedData/
*.xcuserstate
*.xcuserdatad/

# XcodeGen generates this — treat as derived
ShakeToEject.xcodeproj/

# Swift Package Manager
.swiftpm/
.build/
Package.resolved

# macOS
.DS_Store

# User-local
*.swp
*.swo
*~

# Local overrides
project.local.yml
```

Note: `ShakeToEject.xcodeproj/` is in `.gitignore` because `project.yml` is the source of truth per user preference. We regenerate it on every checkout.

---

### Task 4: Write `Shared/Constants.swift`

**Files:**
- Create: `Shared/Constants.swift`

- [ ] **Step 1: Create the constants file**

Exact content for `Shared/Constants.swift`:

```swift
import Foundation

public enum Constants {
    public static let appBundleID = "com.mcsoftware.ShakeToEject"
    public static let helperBundleID = "com.mcsoftware.ShakeToEject.Helper"
    public static let helperMachServiceName = "com.mcsoftware.ShakeToEject.Helper"
    public static let helperPlistName = "com.mcsoftware.ShakeToEject.Helper.plist"
    public static let helperExecutableName = "com.mcsoftware.ShakeToEject.Helper"
}
```

These constants are referenced by both the app and the helper targets in later phases. Centralising them here prevents string drift between targets.

---

### Task 5: Write the App Stub

**Files:**
- Create: `App/ShakeToEjectApp.swift`
- Create: `App/MenuBar/MenuBarContent.swift`
- Create: `App/ShakeToEject.entitlements`

- [ ] **Step 1: Create `App/ShakeToEjectApp.swift`**

```swift
import SwiftUI

@main
struct ShakeToEjectApp: App {
    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: "eject.circle")
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 2: Create `App/MenuBar/MenuBarContent.swift`**

Delete the placeholder `App/MenuBar/.gitkeep` first:

```bash
rm App/MenuBar/.gitkeep
```

Then create `App/MenuBar/MenuBarContent.swift`:

```swift
import SwiftUI

struct MenuBarContent: View {
    var body: some View {
        Text("ShakeToEject \(Bundle.main.shortVersion)")
            .font(.headline)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
```

- [ ] **Step 3: Create `App/ShakeToEject.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
```

v1 keeps App Sandbox off to simplify SMAppService + XPC integration. We may revisit this in a later iteration.

---

### Task 6: Write the Helper Stub

**Files:**
- Create: `Helper/main.swift`
- Create: `Helper/Helper.entitlements`
- Create: `Helper/Launchd/com.mcsoftware.ShakeToEject.Helper.plist`

- [ ] **Step 1: Create `Helper/main.swift`**

```swift
import Foundation

// Phase 0: the helper only proves it exists and is embedded correctly.
// Phase 1 adds the IOKit HID reader. Phase 3 adds the XPC listener.

let version = "0.1.0"
let args = CommandLine.arguments.dropFirst()

if args.contains("--version") {
    print(version)
    exit(0)
}

FileHandle.standardError.write(Data("ShakeToEject helper \(version) — not yet implemented\n".utf8))
exit(0)
```

- [ ] **Step 2: Create `Helper/Helper.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
```

Empty for Phase 0. IOKit HID access does not require a dedicated entitlement — it requires running as root, which is what the launchd daemon registration gives us.

- [ ] **Step 3: Create `Helper/Launchd/com.mcsoftware.ShakeToEject.Helper.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mcsoftware.ShakeToEject.Helper</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/com.mcsoftware.ShakeToEject.Helper</string>
    <key>MachServices</key>
    <dict>
        <key>com.mcsoftware.ShakeToEject.Helper</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.mcsoftware.ShakeToEject</string>
    </array>
    <key>KeepAlive</key>
    <false/>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
```

Key points:
- `BundleProgram` (not `Program`) — required by SMAppService-registered daemons because the path is relative to the main app bundle.
- `MachServices` declares the XPC endpoint the helper will listen on in Phase 3.
- `AssociatedBundleIdentifiers` links the daemon to the main app so macOS shows them together in System Settings → Login Items.
- `KeepAlive=false` and `RunAtLoad=false` mean launchd starts the helper on-demand when the app connects to the Mach service (Phase 4).

---

### Task 7: Write `project.yml`

**Files:**
- Create: `project.yml`

- [ ] **Step 1: Create `project.yml` at the repo root**

```yaml
name: ShakeToEject
options:
  bundleIdPrefix: com.mcsoftware
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
  generateEmptyDirectories: false
  indentWidth: 4
  tabWidth: 4
  xcodeVersion: "26.0"

settings:
  base:
    SWIFT_VERSION: "6.0"
    ENABLE_HARDENED_RUNTIME: YES
    CODE_SIGN_STYLE: Automatic
    CODE_SIGN_IDENTITY: "Apple Development"
    DEAD_CODE_STRIPPING: YES
    CLANG_ENABLE_MODULES: YES
    SWIFT_STRICT_CONCURRENCY: complete

targets:
  ShakeToEject:
    type: application
    platform: macOS
    sources:
      - path: App
      - path: Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.mcsoftware.ShakeToEject
        PRODUCT_NAME: ShakeToEject
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_LSUIElement: YES
        INFOPLIST_KEY_CFBundleDisplayName: ShakeToEject
        INFOPLIST_KEY_NSHumanReadableCopyright: "© 2026 Matteo Comisso. MIT licensed."
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        COMBINE_HIDPI_IMAGES: YES
        CODE_SIGN_ENTITLEMENTS: App/ShakeToEject.entitlements
    dependencies:
      - target: ShakeToEjectHelper
        embed: false
        link: false
    postBuildScripts:
      - name: "Embed Privileged Helper"
        runOnlyWhenInstalling: false
        inputFiles:
          - $(BUILT_PRODUCTS_DIR)/com.mcsoftware.ShakeToEject.Helper
          - $(SRCROOT)/Helper/Launchd/com.mcsoftware.ShakeToEject.Helper.plist
        outputFiles:
          - $(BUILT_PRODUCTS_DIR)/$(FULL_PRODUCT_NAME)/Contents/MacOS/com.mcsoftware.ShakeToEject.Helper
          - $(BUILT_PRODUCTS_DIR)/$(FULL_PRODUCT_NAME)/Contents/Library/LaunchDaemons/com.mcsoftware.ShakeToEject.Helper.plist
        script: |
          set -euo pipefail
          HELPER_SRC="${BUILT_PRODUCTS_DIR}/com.mcsoftware.ShakeToEject.Helper"
          APP_BUNDLE="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"
          HELPER_DEST_DIR="${APP_BUNDLE}/Contents/MacOS"
          LAUNCHD_DEST_DIR="${APP_BUNDLE}/Contents/Library/LaunchDaemons"
          LAUNCHD_SRC="${SRCROOT}/Helper/Launchd/com.mcsoftware.ShakeToEject.Helper.plist"

          mkdir -p "${HELPER_DEST_DIR}"
          mkdir -p "${LAUNCHD_DEST_DIR}"

          cp -f "${HELPER_SRC}" "${HELPER_DEST_DIR}/com.mcsoftware.ShakeToEject.Helper"
          cp -f "${LAUNCHD_SRC}"  "${LAUNCHD_DEST_DIR}/com.mcsoftware.ShakeToEject.Helper.plist"

          # Re-sign the helper in place so the embedded binary matches the app's signature.
          if [ "${CODE_SIGNING_REQUIRED:-YES}" = "YES" ]; then
              SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
              if [ -z "${SIGN_ID}" ]; then
                  echo "error: no code signing identity resolved for helper embed step." >&2
                  echo "       set DEVELOPMENT_TEAM in project.yml or select a team in Xcode." >&2
                  exit 1
              fi

              # Debug builds skip the secure timestamp so the script works offline
              # and on machines without access to Apple's timestamp server. Release
              # builds use the default secure timestamp so the bundle can be notarised.
              if [ "${CONFIGURATION}" = "Debug" ]; then
                  codesign --force --sign "${SIGN_ID}" \
                      --entitlements "${SRCROOT}/Helper/Helper.entitlements" \
                      --options runtime \
                      --timestamp=none \
                      "${HELPER_DEST_DIR}/com.mcsoftware.ShakeToEject.Helper"
              else
                  codesign --force --sign "${SIGN_ID}" \
                      --entitlements "${SRCROOT}/Helper/Helper.entitlements" \
                      --options runtime \
                      "${HELPER_DEST_DIR}/com.mcsoftware.ShakeToEject.Helper"
              fi
          fi

  ShakeToEjectHelper:
    type: tool
    platform: macOS
    sources:
      - path: Helper
        excludes:
          - "Launchd/**"
          - "Helper.entitlements"
      - path: Shared
    settings:
      base:
        PRODUCT_NAME: com.mcsoftware.ShakeToEject.Helper
        PRODUCT_BUNDLE_IDENTIFIER: com.mcsoftware.ShakeToEject.Helper
        SKIP_INSTALL: YES
        CODE_SIGN_ENTITLEMENTS: Helper/Helper.entitlements
        ENABLE_HARDENED_RUNTIME: YES
```

Notes:
- The `dependencies` entry with `embed: false, link: false` tells Xcode "build the helper first, but do not link or auto-embed it." The `postBuildScripts` does the actual copying into the app bundle.
- `PRODUCT_NAME` on the helper is the full reverse-DNS string. The built binary lives at `build/.../com.mcsoftware.ShakeToEject.Helper` with that exact name, which matches `BundleProgram` in the launchd plist.
- Re-signing inside the post-build script is required because once we copy the helper into the app bundle, its enclosing signature is no longer valid. The outer app bundle will be resigned by Xcode's normal codesign step after our script runs.
- `SWIFT_STRICT_CONCURRENCY: complete` turns on Swift 6 strict concurrency. We embrace it from day one rather than retrofitting.

---

### Task 8: Generate and Open the Xcode Project

**Files:**
- Generated: `ShakeToEject.xcodeproj/`

- [ ] **Step 1: Generate the project**

```bash
xcodegen generate
```

Expected output: `Generated project successfully` (or similar). A
`ShakeToEject.xcodeproj` directory is created.

- [ ] **Step 2: Open in Xcode and select a signing team**

```bash
open ShakeToEject.xcodeproj
```

In Xcode:
1. Select the `ShakeToEject` project in the navigator.
2. Select the `ShakeToEject` target → Signing & Capabilities tab.
3. Under "Team", select your personal team (or paid Developer ID if you have one).
4. Repeat for the `ShakeToEjectHelper` target — **use the same team**.

Record your Team ID. You will need it in later phases. Retrieve it any time with:

```bash
security find-identity -v -p codesigning
```

- [ ] **Step 3: Commit the team selection back into `project.yml`**

Once you know the Team ID (e.g. `ABCDE12345`), add it to `project.yml` under both targets so regeneration does not wipe the setting:

Edit `project.yml`, adding under each target's `settings.base`:

```yaml
        DEVELOPMENT_TEAM: ABCDE12345
```

Then regenerate to verify idempotency:

```bash
xcodegen generate
```

Expected: no prompts, project regenerates cleanly.

---

### Task 9: Build and Run

- [ ] **Step 1: Build the app from the command line**

```bash
xcodebuild -project ShakeToEject.xcodeproj \
  -scheme ShakeToEject \
  -configuration Debug \
  -derivedDataPath build \
  build
```

Expected final line: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Verify the helper is embedded in the built app bundle**

```bash
find build/Build/Products/Debug/ShakeToEject.app -type f -name "*Helper*"
```

Expected output (two lines):

```
build/Build/Products/Debug/ShakeToEject.app/Contents/MacOS/com.mcsoftware.ShakeToEject.Helper
build/Build/Products/Debug/ShakeToEject.app/Contents/Library/LaunchDaemons/com.mcsoftware.ShakeToEject.Helper.plist
```

- [ ] **Step 3: Run the helper directly to prove it is a valid binary**

```bash
build/Build/Products/Debug/ShakeToEject.app/Contents/MacOS/com.mcsoftware.ShakeToEject.Helper --version
```

Expected output: `0.1.0`

- [ ] **Step 4: Launch the app and verify the menu bar icon appears**

```bash
open build/Build/Products/Debug/ShakeToEject.app
```

Expected:
- An eject-circle icon appears in the menu bar (top right of screen).
- Clicking it shows "ShakeToEject 0.1.0" followed by a Quit menu item.
- No icon appears in the Dock (because `LSUIElement=true`).
- Clicking Quit terminates the app and removes the menu bar icon.

- [ ] **Step 5: Verify the app bundle codesignature**

```bash
codesign -dv --verbose=4 build/Build/Products/Debug/ShakeToEject.app 2>&1 | head -10
codesign -dv --verbose=4 build/Build/Products/Debug/ShakeToEject.app/Contents/MacOS/com.mcsoftware.ShakeToEject.Helper 2>&1 | head -10
```

Expected: both output blocks show the same `TeamIdentifier=<your team ID>`. If the team identifiers differ, the helper was not correctly re-signed and Phase 4's SMAppService registration will fail — fix the postBuildScripts before proceeding.

---

### Task 10: Hardware Smoke Test

- [ ] **Step 1: Confirm the BMI286 IMU is present on this Mac**

```bash
ioreg -l -w0 | grep -A5 AppleSPUHIDDevice
```

Expected: one or more entries mentioning `AppleSPUHIDDevice` with `CFBundleIdentifier` referring to `AppleSPUHIDDriver`. The block will also show `VendorID`, `ProductID`, and a `LocationID`.

If the output is empty, the IMU is not accessible on this Mac and the project cannot proceed. Stop and report.

- [ ] **Step 2: Record the sensor metadata**

Save the output of step 1 to a file for reference in Phase 1 (the HID matching criteria verification):

```bash
ioreg -l -w0 | grep -A10 AppleSPUHIDDevice > docs/hardware-probe-m1pro.txt
```

Expected: `docs/hardware-probe-m1pro.txt` exists and contains the block. We will commit this so future contributors on other Apple Silicon models can compare.

---

### Task 11: Commit Phase 0

- [ ] **Step 1: Stage the expected files**

```bash
git add .gitignore project.yml App Helper Shared Tests docs
git status
```

Expected: the following files are staged (exact set):

```
.gitignore
App/MenuBar/MenuBarContent.swift
App/ShakeToEject.entitlements
App/ShakeToEjectApp.swift
Helper/Helper.entitlements
Helper/Launchd/com.mcsoftware.ShakeToEject.Helper.plist
Helper/main.swift
Shared/Constants.swift
docs/hardware-probe-m1pro.txt
docs/superpowers/plans/2026-04-10-shaketoeject-overview.md
docs/superpowers/plans/2026-04-10-shaketoeject-phase-0-scaffolding.md
project.yml
```

Plus any `.gitkeep` files in `App/Windows/`, `App/Views/`, `App/Services/`, `App/Resources/Sounds/`, `Tests/`.

`ShakeToEject.xcodeproj/` should **not** be staged (it is in `.gitignore`).

- [ ] **Step 2: Commit**

```bash
git commit -m "Phase 0: XcodeGen scaffolding + helper embed + hardware probe

- Replace stock SwiftData template with XcodeGen project.yml
- Add ShakeToEject menu bar app target (LSUIElement, MenuBarExtra)
- Add ShakeToEjectHelper command line tool target
- Embed helper in app bundle via post-build script
  (Contents/MacOS + Contents/Library/LaunchDaemons)
- Re-sign helper in place during build
- Record M1 Pro AppleSPUHIDDevice probe output
- Add Shared/Constants.swift for cross-target identifiers

Phase 0 of docs/superpowers/plans/2026-04-10-shaketoeject-overview.md"
```

- [ ] **Step 3: Verify the commit is clean**

```bash
git status
```

Expected: `nothing to commit, working tree clean`.

---

## Phase 0 Exit Criteria Checklist

Before marking Phase 0 done, all of these must be true:

- [ ] `xcodegen generate` runs cleanly with no warnings.
- [ ] `xcodebuild -scheme ShakeToEject build` succeeds.
- [ ] `build/.../ShakeToEject.app/Contents/MacOS/com.mcsoftware.ShakeToEject.Helper` exists and runs `--version`.
- [ ] `build/.../ShakeToEject.app/Contents/Library/LaunchDaemons/com.mcsoftware.ShakeToEject.Helper.plist` exists.
- [ ] Launching `ShakeToEject.app` shows a menu bar icon and no Dock icon.
- [ ] The menu bar popover shows the version string and a working Quit item.
- [ ] App and helper share the same `TeamIdentifier` in their signatures.
- [ ] `ioreg -l -w0 | grep -A5 AppleSPUHIDDevice` returns non-empty output on the dev machine.
- [ ] Phase 0 is committed on `main`.

---

## What Phase 0 Does Not Do

Keep this phase pure scaffolding. Explicitly **not** in scope:

- No IOKit HID code (Phase 1).
- No shake detection logic (Phase 2).
- No XPC listener or protocol (Phase 3).
- No SMAppService registration (Phase 4).
- No DiskArbitration code (Phase 5).
- No warning overlay, sound player, or countdown (Phase 6).
- No settings UI beyond the version label (Phase 7).
- No tests yet — the first unit tests arrive in Phase 1/2 where there is
  non-trivial logic to cover.
