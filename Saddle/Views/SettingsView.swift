import SwiftUI

// MARK: - Settings View

/// The main settings window with tabs for Groups, Drives, and General settings.
struct SettingsView: View {
    @ObservedObject var driveStore: DriveStore
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        TabView {
            GeneralTab(configStore: configStore)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            DrivesTab(driveStore: driveStore, configStore: configStore)
                .tabItem {
                    Label("Drives", systemImage: "externaldrive.fill")
                }

            GroupsTab(driveStore: driveStore, configStore: configStore)
                .tabItem {
                    Label("Groups", systemImage: "folder.fill")
                }
        }
        .padding()
    }
}


// MARK: - Groups Tab

struct GroupsTab: View {
    @ObservedObject var driveStore: DriveStore
    @ObservedObject var configStore: ConfigStore
    @State private var selectedGroup: String?
    @State private var showNewGroupSheet = false
    @State private var newGroupName = ""

    var body: some View {
        HSplitView {
            // ── Group List (left panel)
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedGroup) {
                    ForEach(configStore.config.groups) { group in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(
                                    group.action == .mount ? .green :
                                    group.action == .unmount ? .red : .secondary
                                )
                            Text(group.name)
                            Spacer()
                            Text("\(group.driveIdentifiers.count)")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .tag(group.name)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack {
                    Button {
                        showNewGroupSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        if let name = selectedGroup {
                            configStore.removeGroup(named: name)
                            selectedGroup = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedGroup == nil)

                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 180, maxWidth: 220)

            // ── Group Detail (right panel)
            if let groupName = selectedGroup,
               let group = configStore.config.groups.first(where: { $0.name == groupName }) {
                GroupDetailView(
                    group: group,
                    driveStore: driveStore,
                    configStore: configStore
                )
            } else {
                VStack {
                    Spacer()
                    Text("Select a group or create a new one")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showNewGroupSheet) {
            NewGroupSheet(
                groupName: $newGroupName,
                isPresented: $showNewGroupSheet,
                onCreate: { name in
                    let group = DriveGroup(name: name, action: .none, driveIdentifiers: [])
                    configStore.addGroup(group)
                    selectedGroup = name
                    newGroupName = ""
                }
            )
        }
    }
}


// MARK: - Group Detail

struct GroupDetailView: View {
    let group: DriveGroup
    @ObservedObject var driveStore: DriveStore
    @ObservedObject var configStore: ConfigStore

    private var managed: [ExternalDrive] {
        driveStore.managedDrives(excluding: configStore.excludedSet)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ── Group Name & Action
            HStack {
                Text(group.name)
                    .font(.title2.bold())
                Spacer()
            }

            // Launch action picker
            Picker("Launch action:", selection: Binding(
                get: { group.action },
                set: { newAction in
                    var updated = group
                    updated.action = newAction
                    configStore.updateGroup(updated)
                }
            )) {
                ForEach(DriveGroup.LaunchAction.allCases) { action in
                    Text(action.label).tag(action)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)

            Divider()

            // ── Drives in Group
            Text("Drives in this group:")
                .font(.headline)

            if group.driveIdentifiers.isEmpty {
                Text("No drives assigned. Use the checkboxes below to add drives.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            // ── All managed drives with checkboxes
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(managed) { drive in
                        let isInGroup = group.driveIdentifiers.contains(drive.persistentId)
                        let displayName = drive.displayName(aliases: configStore.config.driveAliases)
                        let otherGroup = configStore.config.groups.first {
                            $0.name != group.name && $0.driveIdentifiers.contains(drive.persistentId)
                        }

                        HStack {
                            Toggle(isOn: Binding(
                                get: { isInGroup },
                                set: { checked in
                                    if checked {
                                        configStore.addDriveToGroup(drive.persistentId, groupName: group.name)
                                    } else {
                                        configStore.removeDriveFromGroup(drive.persistentId, groupName: group.name)
                                    }
                                }
                            )) {
                                HStack {
                                    Image(systemName: drive.isMounted ? "externaldrive.fill" : "externaldrive")
                                        .foregroundStyle(drive.isMounted ? .green : .secondary)
                                    Text(displayName)
                                    Text("(\(drive.sizeDescription))")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                            .toggleStyle(.checkbox)

                            Spacer()

                            if let otherGroup, !isInGroup {
                                Text("in \(otherGroup.name)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }

                            Text(drive.identifier)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()
        }
        .padding()
    }
}


// MARK: - New Group Sheet

struct NewGroupSheet: View {
    @Binding var groupName: String
    @Binding var isPresented: Bool
    let onCreate: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Group")
                .font(.headline)

            TextField("Group name", text: $groupName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            HStack {
                Button("Cancel") {
                    groupName = ""
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    let trimmed = groupName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onCreate(trimmed)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }
}


// MARK: - Drives Tab

struct DrivesTab: View {
    @ObservedObject var driveStore: DriveStore
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("All External Drives")
                    .font(.title2.bold())
                Spacer()
                Button {
                    driveStore.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            Text("Set friendly aliases and exclude drives you don't want managed.")
                .foregroundStyle(.secondary)
                .font(.callout)

            Divider()

            if driveStore.drives.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No external drives connected")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                Table(driveStore.drives) {
                    TableColumn("Status") { drive in
                        Image(systemName: drive.isMounted ? "circle.fill" : "circle")
                            .foregroundStyle(drive.isMounted ? .green : .secondary)
                            .font(.caption)
                    }
                    .width(40)

                    TableColumn("Volume") { drive in
                        Text(drive.volumeName)
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("Alias") { drive in
                        let alias = configStore.config.driveAliases[drive.persistentId] ?? ""
                        TextField("alias", text: Binding(
                            get: { alias },
                            set: { configStore.setAlias($0, for: drive.persistentId) }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("ID") { drive in
                        Text(drive.identifier)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .width(70)

                    TableColumn("Size") { drive in
                        Text(drive.sizeDescription)
                            .foregroundStyle(.secondary)
                    }
                    .width(80)

                    TableColumn("Excluded") { drive in
                        let isExcluded = configStore.isExcluded(drive.persistentId)
                        Toggle("", isOn: Binding(
                            get: { isExcluded },
                            set: { excluded in
                                if excluded {
                                    configStore.exclude(drive.persistentId)
                                } else {
                                    configStore.include(drive.persistentId)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                    .width(60)
                }
            }
        }
        .padding()
    }
}


// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        Form {
            Section {
                Toggle("Start Saddle at login",
                       isOn: Binding(
                        get: { configStore.config.launchAtLogin },
                        set: { configStore.setLaunchAtLogin($0) }
                       ))

                Toggle("Run group actions automatically at launch",
                       isOn: $configStore.config.autoActionsOnLaunch)

                Toggle("Mount all drives automatically at launch",
                       isOn: Binding(
                        get: { configStore.config.mountAllOnLaunch },
                        set: { newValue in
                            configStore.config.mountAllOnLaunch = newValue
                            if newValue { configStore.config.unmountAllOnLaunch = false }
                        }
                       ))

                Toggle("Unmount all drives automatically at launch",
                       isOn: Binding(
                        get: { configStore.config.unmountAllOnLaunch },
                        set: { newValue in
                            configStore.config.unmountAllOnLaunch = newValue
                            if newValue { configStore.config.mountAllOnLaunch = false }
                        }
                       ))
            } header: {
                Text("Startup")
            }

            Section {
                Toggle("Run group actions automatically on wake",
                       isOn: $configStore.config.autoActionsOnWake)

                Toggle("Mount all drives on wake",
                       isOn: Binding(
                        get: { configStore.config.mountAllOnWake },
                        set: { newValue in
                            configStore.config.mountAllOnWake = newValue
                            if newValue { configStore.config.unmountAllOnWake = false }
                        }
                       ))

                Toggle("Unmount all drives on wake",
                       isOn: Binding(
                        get: { configStore.config.unmountAllOnWake },
                        set: { newValue in
                            configStore.config.unmountAllOnWake = newValue
                            if newValue { configStore.config.mountAllOnWake = false }
                        }
                       ))
            } header: {
                Text("Sleep / Wake")
            }

            Section {
                HStack {
                    Text("Config file location:")
                    Spacer()
                    Button("Reveal in Finder") {
                        configStore.revealConfigInFinder()
                    }
                }

                HStack {
                    Text("Managed groups:")
                    Spacer()
                    Text("\(configStore.config.groups.count)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Excluded drives:")
                    Spacer()
                    Text("\(configStore.config.excludedIdentifiers.count)")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Info")
            }

            Section {
                Toggle("Force unmount (eject even if files are in use)",
                       isOn: $configStore.config.useForceUnmount)

                Text("Warning: Force unmounting can cause data loss if applications have unsaved changes on the drive.")
                    .font(.caption)
                    .foregroundStyle(.red)

                Button("Reset All Configuration", role: .destructive) {
                    configStore.config = AppConfig.default
                }
            } header: {
                Text("Danger Zone")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
