# DriveManager — macOS Menu Bar Drive Manager (Swift)

A native SwiftUI menu bar app for managing external drives on macOS. Mount, unmount, organize into groups, and auto-manage drives at login.

---

## Features

- **Menu bar icon** with real-time mount status for all external drives
- **Click to mount/unmount** individual drives
- **Drive groups** — organize drives and batch mount/unmount
- **Launch actions** — auto-mount or auto-unmount groups on app startup
- **Exclude drives** — hide drives you don't want managed
- **Friendly aliases** — rename drives for clarity
- **Login item** — start at login via macOS ServiceManagement (no LaunchAgent needed)
- **Real-time monitoring** — DiskArbitration callbacks detect drive connect/disconnect instantly
- **Settings window** — full GUI for managing groups, aliases, and preferences
- **Native macOS** — SwiftUI, no dependencies, App Store-ready architecture

---

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode 15+
- An Apple Developer account (for signing and distribution)

---

## Xcode Project Setup

Since the source files are provided without an `.xcodeproj`, follow these steps to create the project:

### 1. Create a New Xcode Project

1. Open Xcode → **File → New → Project**
2. Choose **macOS → App**
3. Configure:
   - **Product Name:** `DriveManager`
   - **Team:** your Apple Developer team
   - **Organization Identifier:** `com.yourname` (or your domain)
   - **Interface:** SwiftUI
   - **Language:** Swift
   - **Storage:** None
4. Choose a location and click **Create**

### 2. Replace the Generated Files

Xcode creates some default files. Replace them with the project files:

1. **Delete** the auto-generated `ContentView.swift` and `DriveManagerApp.swift`
2. **Create the folder structure** in Xcode (right-click the DriveManager group):
   ```
   DriveManager/
   ├── DriveManagerApp.swift          ← App entry point
   ├── Info.plist
   ├── DriveManager.entitlements
   ├── Models/
   │   └── Models.swift               ← ExternalDrive, DriveGroup, AppConfig
   ├── Services/
   │   ├── DiskService.swift           ← DiskArbitration + diskutil wrapper
   │   ├── DriveStore.swift            ← Observable drive state manager
   │   └── ConfigStore.swift           ← Persistent configuration
   └── Views/
       ├── MenuBarView.swift           ← Menu bar dropdown
       └── SettingsView.swift          ← Settings window (Groups, Drives, General tabs)
   ```
3. **Drag all the `.swift` files** into the appropriate Xcode groups

### 3. Configure the Target

1. Select the **DriveManager** target in the project navigator
2. **General tab:**
   - Deployment Target: **macOS 13.0**
   - Uncheck "Supports Mac Catalyst" if present
3. **Signing & Capabilities tab:**
   - Team: select your developer team
   - Signing Certificate: "Development" (for testing), "Distribution" (for release)
   - Click **+ Capability** and add **App Sandbox** if not already present
4. **Info tab:**
   - Make sure `LSUIElement` is set to `YES` (this hides the Dock icon — menu bar only)
5. **Build Settings:**
   - Search for "Info.plist File" and verify it points to `DriveManager/Info.plist`

### 4. Add Required Frameworks

1. Select the target → **General → Frameworks, Libraries, and Embedded Content**
2. Click **+** and add these system frameworks (set both to "Do Not Embed"):
   - `DiskArbitration.framework`
   - `IOKit.framework`

### 5. Build and Run

1. **⌘R** to build and run
2. A 💾-style drive icon should appear in your menu bar
3. Click it to see your drives
4. Open **Settings** (⌘,) to configure groups, aliases, and startup behavior

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  DriveManagerApp                     │
│  @main entry point, MenuBarExtra + Settings scene   │
├──────────────┬──────────────────┬───────────────────┤
│  MenuBarView │  SettingsView    │  AppDelegate      │
│  (dropdown)  │  (window w/tabs) │  (launch actions) │
├──────────────┴──────────────────┴───────────────────┤
│                    DriveStore                        │
│  @Published drives, mount/unmount/group operations   │
├─────────────────────┬───────────────────────────────┤
│    ConfigStore      │       DiskService              │
│  JSON persistence   │  DiskArbitration monitoring    │
│  groups, aliases,   │  diskutil subprocess calls     │
│  exclusions         │  drive discovery & control     │
└─────────────────────┴───────────────────────────────┘
```

**DiskService** is fully native with zero subprocess calls:
- **DiskArbitration framework** for real-time callbacks, mounting (`DADiskMount`), and unmounting (`DADiskUnmount`)
- **IOKit** (`IOServiceGetMatchingServices` on `IOMedia`) for drive discovery — iterates the I/O Registry and queries DA for each disk's description dictionary
- No `Process()` / `diskutil` calls — fully sandbox-compatible

**DriveStore** is the central `ObservableObject`. It owns the list of discovered drives, handles all mount/unmount operations, and triggers refreshes on DA events.

**ConfigStore** persists configuration as JSON in `~/Library/Application Support/DriveManager/config.json`.

---

## App Store Distribution Notes

### Sandboxing

This app uses DiskArbitration's native C API (`DADiskMount`, `DADiskUnmount`, `DADiskCopyDescription`) and IOKit for all disk operations. There are **no subprocess calls** (`Process()`, `diskutil`, etc.), which makes sandboxing straightforward.

The one entitlement beyond the base sandbox is a Mach lookup exception for `com.apple.DiskArbitration.diskarbitrationd` — this allows the app to communicate with the disk arbitration daemon. This is already configured in the included `.entitlements` file.

**Option A: Mac App Store (sandboxed)**
- The included entitlements should work for App Store review
- If Apple flags the Mach lookup exception, you can explain that the app's core function requires DiskArbitration IPC — this is a well-known, legitimate use case

**Option B: Direct Distribution (notarized, non-sandboxed)**
- Remove the App Sandbox entitlement entirely
- Sign with a Developer ID certificate
- Notarize via `xcrun notarytool`
- Distribute as a `.dmg` or `.zip` from your website

### Login Item

The app uses `SMAppService.mainApp.register()` (macOS 13+) for login item registration. This is the modern, App Store-approved approach — no LaunchAgent plist needed.

---

## Configuration File

Stored at: `~/Library/Application Support/DriveManager/config.json`

```json
{
  "version": 2,
  "autoActionsOnLaunch": true,
  "refreshIntervalSeconds": 15,
  "launchAtLogin": false,
  "groups": [
    {
      "name": "Keep Mounted",
      "action": "mount",
      "driveIdentifiers": ["disk4s1"]
    },
    {
      "name": "Auto Unmount",
      "action": "unmount",
      "driveIdentifiers": ["disk5s2", "disk6s1", "disk7s2", "disk8s1"]
    }
  ],
  "excludedIdentifiers": [],
  "driveAliases": {
    "disk4s1": "Main Work Drive",
    "disk5s2": "Time Machine"
  }
}
```

---

## Troubleshooting

**"Operation not permitted" when mounting/unmounting:**
Grant Full Disk Access to DriveManager in System Settings → Privacy & Security → Full Disk Access. During development, you may also need to grant it to Xcode or Terminal.

**Drives not appearing:**
Check that drives show in `diskutil list external` in Terminal. Some drives take a moment to register. The app auto-refreshes every 15 seconds and also responds to DiskArbitration events.

**Menu bar icon not appearing:**
Make sure `LSUIElement` is `YES` in Info.plist and that you're running on macOS 13+. Check the Xcode console for errors.

**Login item not working:**
`SMAppService` requires the app to be in `/Applications` (or at least code-signed). It won't work when running from Xcode's DerivedData build folder.
