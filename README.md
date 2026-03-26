# Saddle — macOS Menu Bar Drive Manager (Swift)

A native SwiftUI menu bar app for managing external drives on macOS. Mount, unmount, organize into groups, and auto-manage drives at login.

## Download

**[Download Saddle 1.1.1](https://github.com/smandable/Saddle/releases/latest)**

Open the `.dmg`, drag Saddle to Applications, and launch. On first launch, macOS will ask you to allow the background helper in System Settings > Login Items.

---

## Screenshots

![Menu Bar](screenshots/Saddle%20-%20Menu%20bar.png)

![Settings — General](screenshots/Saddle%20Settings%20-%20General.png)

![Settings — Drives](screenshots/Saddle%20Settings%20-%20Drives.png)

![Settings — Groups](screenshots/Saddle%20Settings%20-%20Groups.png)

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
- **Native macOS** — SwiftUI, no dependencies, notarized by Apple

---

## Requirements

- macOS 13.0 (Ventura) or later
