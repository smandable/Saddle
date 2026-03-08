# Saddle — macOS Menu Bar Drive Manager (Swift)

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
