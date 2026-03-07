import SwiftUI

// MARK: - Menu Bar View

/// The dropdown menu shown when the user clicks the menu bar icon.
struct MenuBarView: View {
    @ObservedObject var driveStore: DriveStore
    @ObservedObject var configStore: ConfigStore
    @Binding var showSettings: Bool
    @Environment(\.openWindow) private var openWindow

    private var excluded: Set<String> { configStore.excludedSet }
    private var managed: [ExternalDrive] { driveStore.managedDrives(excluding: excluded) }

    var body: some View {
        // ── Header
        let total = managed.count
        let mounted = driveStore.mountedCount(excluding: excluded)
        Text("External Drives (\(mounted)/\(total) mounted)")
            .font(.headline)

        Divider()

        // ── Status message (if any)
        if let status = driveStore.statusMessage {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
        }

        // ── Individual Drives
        if managed.isEmpty {
            Text("No external drives detected")
                .foregroundStyle(.secondary)
        } else {
            ForEach(managed) { drive in
                driveMenuItem(drive)
            }
        }

        // ── Mount / Unmount All
        if !managed.isEmpty {
            Button {
                Task { await driveStore.mountAll(excluding: excluded) }
            } label: {
                Label("Mount All", systemImage: "play.fill")
            }

            Button {
                Task { await driveStore.unmountAll(excluding: excluded, force: configStore.config.useForceUnmount) }
            } label: {
                Label("Unmount All", systemImage: "eject.fill")
            }
        }

        Divider()

        // ── Groups
        if !configStore.config.groups.isEmpty {
            ForEach(configStore.config.groups) { group in
                groupMenu(group)
            }
            Divider()
        }

        // ── Excluded drives (if any)
        if !configStore.config.excludedIdentifiers.isEmpty {
            Menu("Excluded Drives") {
                ForEach(configStore.config.excludedIdentifiers, id: \.self) { identifier in
                    let name = driveStore.drive(for: identifier)?.volumeName ?? identifier
                    Button("Re-include \(name)") {
                        configStore.include(identifier)
                    }
                }
            }
            Divider()
        }

        // ── Utility Items
        Button("Refresh") {
            driveStore.refresh()
        }
        .keyboardShortcut("r")

        Divider()

        Button("Settings…") {
            openWindow(id: "settings")
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.title.contains("DriveManager Settings") }?.makeKeyAndOrderFront(nil)
            }
        }
        .keyboardShortcut(",")

        Button("Open Config in Finder") {
            configStore.revealConfigInFinder()
        }

        Divider()

        Button("Quit DriveManager") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }


    // MARK: - Drive Menu Item

    @ViewBuilder
    private func driveMenuItem(_ drive: ExternalDrive) -> some View {
        let displayName = drive.displayName(aliases: configStore.config.driveAliases)
        let groupName = configStore.groupForDrive(drive.identifier)?.name

        Button {
            Task { await driveStore.toggleMount(identifier: drive.identifier, force: configStore.config.useForceUnmount) }
        } label: {
            HStack {
                Image(systemName: drive.isMounted ? "externaldrive.fill" : "externaldrive")
                    .foregroundStyle(drive.isMounted ? .green : .secondary)

                Text(displayName)

                Spacer()

                Text(drive.sizeDescription)
                    .foregroundStyle(.secondary)
                    .font(.caption)

                if let groupName {
                    Text("[\(groupName)]")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                }

                Text(drive.isMounted ? "Mounted" : "Unmounted")
                    .foregroundStyle(drive.isMounted ? .green : .orange)
                    .font(.caption)
            }
        }
    }


    // MARK: - Group Submenu

    @ViewBuilder
    private func groupMenu(_ group: DriveGroup) -> some View {
        Menu {
            // Launch action indicator
            Label(group.action.label, systemImage: group.action.icon)
                .foregroundStyle(group.action.iconColor == "green" ? .green
                                 : group.action.iconColor == "red" ? .red : .secondary)

            Divider()

            // Batch actions
            Button {
                Task { await driveStore.mountGroup(group) }
            } label: {
                Label("Mount All", systemImage: "play.fill")
            }

            Button {
                Task { await driveStore.unmountGroup(group, force: configStore.config.useForceUnmount) }
            } label: {
                Label("Unmount All", systemImage: "eject.fill")
            }

            Divider()

            // List drives in group
            ForEach(group.driveIdentifiers, id: \.self) { identifier in
                if let drive = driveStore.drive(for: identifier) {
                    let name = drive.displayName(aliases: configStore.config.driveAliases)
                    Label(
                        "\(name) — \(drive.isMounted ? "Mounted" : "Unmounted")",
                        systemImage: drive.isMounted ? "externaldrive.fill" : "externaldrive"
                    )
                } else {
                    Label("\(identifier) — not connected", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if group.driveIdentifiers.isEmpty {
                Text("No drives in this group")
                    .foregroundStyle(.secondary)
            }
        } label: {
            let connectedCount = group.driveIdentifiers.filter { driveStore.drive(for: $0) != nil }.count
            let mountedInGroup = group.driveIdentifiers.filter { driveStore.drive(for: $0)?.isMounted == true }.count
            Label("\(group.name) (\(mountedInGroup)/\(connectedCount))",
                  systemImage: "folder.fill")
        }
    }
}
