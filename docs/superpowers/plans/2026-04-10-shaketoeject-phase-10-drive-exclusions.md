# ShakeToEject — Phase 10: Drive Exclusion List

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Let the user mark specific drives as "never auto-eject" so drives they want kept mounted (Time Machine backups, NAS mounts, work drives, a system SSD plugged in permanently) don't participate in the shake-to-eject flow. Excluded drives stay in the menu bar popover but are visually marked with a 🔒 and skipped by both manual "Eject All" and the automatic shake-triggered eject.

**Architecture:** Extend `SettingsStore` with a `Set<String>` of excluded volume names (persisted to UserDefaults), add a `DriveMonitor.eject(_:)` method that takes an explicit list of drives to eject (as opposed to the current all-or-nothing `ejectAll()`), filter `WarningCoordinator.drivesSnapshot` against the exclusion set at `trigger()` time, and add a "Drives" section to the Dashboard listing mounted and persisted-but-not-mounted drives with per-row toggles.

**Identifier choice:** volume name (user-facing string from `DADiskDescriptionVolumeNameKey`). It's simple and immediately recognizable to the user. Downsides: if a user renames a drive, the exclusion no longer applies to it. That's an acceptable trade-off for a v1 — users understand "I renamed it, I need to re-exclude it" intuitively. Volume UUIDs would be more stable but invisible in the UI; deferring that to a later phase if anyone asks.

**Tech Stack:** Same as existing — `UserDefaults`, `@Observable`, SwiftUI `Form` / `Toggle`.

**Prerequisites:**
- Phase 9 committed on main (`d372c5a` or later).
- Settings dashboard opens via ⌘,, shows Detection / Warning / General sections.

**No new tests in Phase 10.** The filtering logic is simple enough that manual verification catches any regressions.

---

## Semantics

- **"Eject All" in menu bar**: only ejects non-excluded drives. Button label reads `"Eject All N Drive(s)"` where `N` = non-excluded count.
- **Shake trigger**: snapshot is filtered to non-excluded drives. If every mounted drive is excluded, `trigger()` treats it as "no drives" and skips the warning.
- **Excluded drives in the menu bar list**: still visible, prefixed with 🔒 instead of ⏏︎, with a muted foreground color.
- **Dashboard "Drives" section**:
  - **Subsection 1 — Currently mounted**: each drive is a row with the volume name and a toggle ("Exclude from auto-eject"). Toggling writes to SettingsStore immediately.
  - **Subsection 2 — Remembered (not mounted)**: any volume names in the exclusion set that aren't currently in `driveMonitor.drives`. Each row has a "Remove" button to purge the remembered exclusion.
  - **Empty state**: if no mounted drives AND no remembered exclusions, show "No drives to configure".

---

### Task 1: Extend `SettingsStore` with `excludedVolumeNames`

**Files:**
- Modify: `App/Services/SettingsStore.swift`

**Step 1:** Add the key constant. Find the `enum Key` block and add:

```swift
static let excludedVolumeNames = "settings.excludedVolumeNames"
```

**Step 2:** Add the observable property. Find the block of `var` observable properties and add after `launchAtLogin`:

```swift
/// Volume names the user has marked as "never auto-eject".
/// Drives matching any of these names are skipped by both the
/// manual Eject All action and the shake-triggered eject flow,
/// and appear with a 🔒 prefix in the menu bar.
var excludedVolumeNames: Set<String> {
    didSet {
        UserDefaults.standard.set(Array(excludedVolumeNames).sorted(), forKey: Key.excludedVolumeNames)
    }
}
```

**Step 3:** Initialize from UserDefaults in `init()`. At the end of the existing init body (after `self.launchAtLogin = defaults.bool(...)`), add:

```swift
let storedExcluded = defaults.array(forKey: Key.excludedVolumeNames) as? [String] ?? []
self.excludedVolumeNames = Set(storedExcluded)
```

---

### Task 2: Add `DriveMonitor.eject(_:)`

**Files:**
- Modify: `App/Services/DriveMonitor.swift`

**Step 1:** Find the existing `func ejectAll()` method and add a new method directly after it:

```swift
/// Unmounts and ejects an explicit subset of drives. Used by
/// the shake-triggered flow so the coordinator can filter out
/// excluded drives before telling the monitor to eject.
func eject(_ drivesToEject: [DriveInfo]) {
    NSLog("[drives] eject(\(drivesToEject.count) drive(s))")
    for drive in drivesToEject {
        guard let disk = disksByBSDName[drive.id] else { continue }
        DriveEjector.unmountAndEject(disk)
    }
}
```

Note: `ejectAll()` stays unchanged so the menu bar's Eject All button can still use it (the button's own label-level filtering handles the exclusion case).

Actually, correction: the manual Eject All button also needs to respect exclusions. Simpler: make `ejectAll()` take the current exclusion set. Or keep `ejectAll()` for "eject literally everything" and make the caller filter.

**Chosen approach:** leave `ejectAll()` alone (it means "everything the monitor is tracking"), and always have callers filter before they decide what to eject. The menu bar button will use `eject(_:)` with a filtered list, not `ejectAll()`.

---

### Task 3: Filter the drive snapshot in `WarningCoordinator.trigger()` and `complete()`

**Files:**
- Modify: `App/Services/WarningCoordinator.swift`

**Step 1:** In `trigger(force:overrideCountdown:)`, find:

```swift
drivesSnapshot = driveMonitor.drives

if drivesSnapshot.isEmpty && !force {
    NSLog("[warning] trigger ignored — no drives to eject")
    return
}
```

Replace with:

```swift
drivesSnapshot = driveMonitor.drives.filter {
    !settings.excludedVolumeNames.contains($0.volumeName)
}

if drivesSnapshot.isEmpty && !force {
    NSLog("[warning] trigger ignored — no eligible drives to eject")
    return
}
```

**Step 2:** In `complete()`, find:

```swift
private func complete() {
    let expectedBSDNames = Set(drivesSnapshot.map(\.id))
    NSLog("[warning] countdown complete — ejecting \(expectedBSDNames.count) drive(s)")
    soundPlayer.playEjected()
    driveMonitor.ejectAll()
    countdownTask = nil
    tearDown()
```

Replace the body through `driveMonitor.ejectAll()`:

```swift
private func complete() {
    let drivesToEject = drivesSnapshot // already filtered at trigger() time
    let expectedBSDNames = Set(drivesToEject.map(\.id))
    NSLog("[warning] countdown complete — ejecting \(expectedBSDNames.count) drive(s)")
    soundPlayer.playEjected()
    driveMonitor.eject(drivesToEject)
    countdownTask = nil
    tearDown()
```

(The rest of the method — the `if !expectedBSDNames.isEmpty { ... startEjectionWatcher ... }` block — stays the same.)

---

### Task 4: Extend `MenuBarContent` with exclusion indicators and filtered Eject All

**Files:**
- Modify: `App/MenuBar/MenuBarContent.swift`

**Step 1:** Replace the drive-list block. Find:

```swift
if drives.drives.isEmpty {
    Text("No external drives")
        .foregroundStyle(.secondary)
} else {
    ForEach(drives.drives) { drive in
        Text("⏏︎ \(drive.volumeName)")
    }
    Button("Eject All \(drives.drives.count) Drive\(drives.drives.count == 1 ? "" : "s")") {
        drives.ejectAll()
    }
}
```

Replace with:

```swift
if drives.drives.isEmpty {
    Text("No external drives")
        .foregroundStyle(.secondary)
} else {
    ForEach(drives.drives) { drive in
        let excluded = settings.excludedVolumeNames.contains(drive.volumeName)
        Text("\(excluded ? "🔒" : "⏏︎") \(drive.volumeName)")
            .foregroundStyle(excluded ? .secondary : .primary)
    }
    let ejectable = drives.drives.filter {
        !settings.excludedVolumeNames.contains($0.volumeName)
    }
    if !ejectable.isEmpty {
        Button("Eject All \(ejectable.count) Drive\(ejectable.count == 1 ? "" : "s")") {
            drives.eject(ejectable)
        }
    }
}
```

---

### Task 5: Extend `DashboardView` with a "Drives" section

**Files:**
- Modify: `App/Views/DashboardView.swift`

**Step 1:** Change the view signature to also take `drives: DriveMonitor`:

```swift
struct DashboardView: View {
    let settings: SettingsStore
    let drives: DriveMonitor
```

**Step 2:** Insert a new `Section("Drives") { ... }` between the existing `Section("Warning")` and `Section("General")` sections. The new section should read:

```swift
Section("Drives") {
    let mounted = drives.drives
    let rememberedNotMounted = settings.excludedVolumeNames
        .subtracting(Set(mounted.map(\.volumeName)))
        .sorted()

    if mounted.isEmpty && rememberedNotMounted.isEmpty {
        Text("No drives to configure")
            .foregroundStyle(.secondary)
    } else {
        if !mounted.isEmpty {
            ForEach(mounted) { drive in
                Toggle(
                    isOn: Binding(
                        get: { !settings.excludedVolumeNames.contains(drive.volumeName) },
                        set: { include in
                            if include {
                                settings.excludedVolumeNames.remove(drive.volumeName)
                            } else {
                                settings.excludedVolumeNames.insert(drive.volumeName)
                            }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(drive.volumeName)
                        Text(drive.mountPoint.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if !rememberedNotMounted.isEmpty {
            Text("Remembered exclusions (not mounted)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            ForEach(rememberedNotMounted, id: \.self) { name in
                HStack {
                    Text("🔒 \(name)")
                    Spacer()
                    Button("Forget") {
                        settings.excludedVolumeNames.remove(name)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }

        Text("Excluded drives are never auto-ejected, even on shake.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }
}
```

**Step 3:** Expand the window frame a little to accommodate the new section. Change the existing `.frame(width: 480, height: 440)` at the bottom of the body to `.frame(width: 520, height: 560)`.

---

### Task 6: Update `AppDelegate.openDashboard` and `MenuBarContent` to pass `drives`

**Files:**
- Modify: `App/ShakeToEjectApp.swift`
- Modify: `App/MenuBar/MenuBarContent.swift` (already modified in Task 4 — this is just adding `settings` if it's not already passed in)

**Step 1:** In `AppDelegate.openDashboard()`, find:

```swift
let view = DashboardView(settings: settings)
```

Replace with:

```swift
let view = DashboardView(settings: settings, drives: drives)
```

(The `settings` parameter already exists in MenuBarContent from Phase 8.)

---

### Task 7: Regenerate, clean build, run tests

```bash
xcodegen generate 2>&1 | tail -3
rm -rf build
xcodebuild -project ShakeToEject.xcodeproj -scheme ShakeToEject -configuration Debug -derivedDataPath build build 2>&1 | tail -15
xcodebuild test -project ShakeToEject.xcodeproj -scheme ShakeToEjectTests -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **` 25/25.

---

### Task 8: Manual smoke test

1. `open .../build/Build/Products/Debug/ShakeToEject.app`
2. Mount a test drive: `hdiutil create -size 20m -fs APFS -volname ExcludeTest /tmp/ex.dmg && hdiutil attach /tmp/ex.dmg`
3. Menu bar → Settings… → new **Drives** section should show `ExcludeTest` with a toggle ON (meaning "included in auto-eject").
4. Toggle it OFF — `ExcludeTest` is now excluded.
5. Menu bar popover should show `🔒 ExcludeTest` in grey instead of `⏏︎ ExcludeTest` in default colour.
6. The "Eject All" button should not appear (only drive is excluded).
7. Simulate Shake (dev) — warning should say "(dev simulation — no eligible drives)" or similar, since the only drive is excluded. Esc to dismiss.
8. Toggle `ExcludeTest` back to ON — menu bar shows `⏏︎ ExcludeTest` again, Eject All appears.
9. Toggle OFF again, unmount the disk image: `hdiutil detach /Volumes/ExcludeTest`
10. In Dashboard → Drives section: `ExcludeTest` should now appear under "Remembered exclusions (not mounted)".
11. Click **Forget** next to it — the name disappears from the remembered list, and re-mounting the drive would not automatically exclude it.
12. Cleanup: `rm -f /tmp/ex.dmg`

---

### Task 9: Commit Phase 10

```bash
git add -A
git commit -m "$(cat <<'EOF'
Phase 10: drive exclusion list

Lets the user mark specific drives as "never auto-eject" so
drives they want kept permanently mounted (Time Machine backups,
NAS mounts, work drives) don't participate in the shake-to-eject
flow.

- Extend SettingsStore with `excludedVolumeNames: Set<String>`,
  persisted to UserDefaults as a sorted array. Volume name is
  the identifier; renaming a drive breaks the exclusion, which
  is an acceptable v1 trade-off.
- Add DriveMonitor.eject(_:) — ejects an explicit list of drives
  instead of everything tracked. ejectAll() stays as "eject
  literally everything" for callers that want the old semantics.
- Filter WarningCoordinator.drivesSnapshot against the exclusion
  set in trigger(), so excluded drives never appear in the
  warning overlay's drive-count subtitle and never participate
  in the ejection on completion. If every mounted drive is
  excluded, trigger() treats it as "no drives" and skips the
  warning entirely.
- Update MenuBarContent to show excluded drives with a 🔒 prefix
  and secondary foreground colour. The Eject All button label
  and action both respect exclusions — a drive marked 🔒 is
  neither counted nor ejected by the button.
- Extend DashboardView with a new "Drives" section showing two
  subsections: currently mounted drives (each with an Exclude
  toggle and mount-point caption) and remembered-but-not-mounted
  exclusions (each with a Forget button). Empty state reads
  "No drives to configure". Bumped window frame from 480×440 to
  520×560 to fit.
- AppDelegate.openDashboard passes the DriveMonitor to
  DashboardView so the section can observe live drive state.

Verified: mount-exclude-shake flow produces "no eligible drives"
log, menu bar Eject All count matches filter, remembered
exclusions persist across drive unmount, Forget button clears
them. 25/25 tests still green.

Phase 10 of docs/superpowers/plans/2026-04-10-shaketoeject-overview.md

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 10 Exit Criteria

- [ ] SettingsStore persists and restores `excludedVolumeNames` across app relaunch.
- [ ] Menu bar shows 🔒 prefix and secondary colour for excluded drives.
- [ ] Eject All respects exclusions in both label count and action.
- [ ] Shake trigger treats exclusion-only-mounted state as "no drives".
- [ ] Dashboard → Drives section toggles and persists the exclusion set live.
- [ ] Remembered exclusions show when their drives are unmounted and can be forgotten.
- [ ] 25/25 tests still green.
- [ ] Phase 10 committed on main.

## What Phase 10 Does Not Do

- No UUID-based exclusions. Volume name is the identifier — renaming breaks the link.
- No "exclude by regex" or "exclude by mount path" patterns. Explicit list only.
- No warning UI indicator that some drives were excluded (the count is just lower).
- No import/export of exclusions.
- No "temporary exclude until next reboot" semantics.
