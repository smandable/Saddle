import SwiftUI
import ServiceManagement
import os.log

private let logger = Logger(subsystem: "com.saddle.app", category: "App")

/// Saddle — macOS Menu Bar App for External Drive Management
///
/// A native SwiftUI menu bar utility that lets you monitor, mount, unmount,
/// and organize external drives into groups with automatic launch actions.

@main
struct SaddleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var driveStore = DriveStore()
    @StateObject private var configStore = ConfigStore()
    @State private var showSettings = false

    var body: some Scene {
        // Pass stores to AppDelegate so it can trigger launch actions
        // directly, bypassing SwiftUI view lifecycle which is unreliable
        // with .menuBarExtraStyle(.menu)
        let _ = {
            appDelegate.driveStore = driveStore
            appDelegate.configStore = configStore
        }()

        // ── Menu Bar ────────────────────────────────────────────────
        MenuBarExtra {
            MenuBarView(driveStore: driveStore, configStore: configStore, showSettings: $showSettings)
        } label: {
            Label {
                Text("Saddle")
            } icon: {
                Image(systemName: "externaldrive.fill")
            }
        }
        .menuBarExtraStyle(.menu)

        // ── Settings Window ─────────────────────────────────────────
        Window("Saddle Settings", id: "settings") {
            SettingsView(driveStore: driveStore, configStore: configStore)
                .frame(minWidth: 680, minHeight: 520)
        }
        .defaultSize(width: 680, height: 520)
    }
}


// MARK: - App Delegate

/// Handles app lifecycle, particularly running launch actions on startup
/// and setting up the DiskArbitration session.
class AppDelegate: NSObject, NSApplicationDelegate {
    var driveStore: DriveStore?
    var configStore: ConfigStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register the privileged helper daemon so launchd can start it on demand
        registerHelperDaemon()

        // Run migration + launch actions after a brief delay to let drives settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, let driveStore = self.driveStore, let configStore = self.configStore else { return }
            Task { @MainActor in
                // Migrate config from BSD names to stable volume UUIDs
                let mapping = Dictionary(
                    uniqueKeysWithValues: driveStore.drives.compactMap { drive in
                        drive.volumeUUID.map { (drive.identifier, $0) }
                    }
                )
                if !mapping.isEmpty {
                    configStore.migrateToVolumeUUIDs(mapping: mapping)
                }

                await driveStore.runLaunchActions(config: configStore.config)
            }
        }

        // Re-run group actions when Mac wakes from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func registerHelperDaemon() {
        #if DEBUG
        // In debug builds the helper runs as a user agent (not a system
        // daemon) to avoid SMAppService/BTM issues during development.
        // Load it via launchctl if not already running.
        loadHelperAgent()
        #else
        let daemon = SMAppService.daemon(plistName: "com.saddle.helper.plist")
        let status = daemon.status
        logger.info("Helper daemon status: \(String(describing: status))")

        if status != .enabled {
            do {
                try daemon.register()
                logger.info("Helper daemon registered successfully")
            } catch {
                logger.error("Failed to register helper daemon: \(error.localizedDescription)")
            }
        } else {
            logger.info("Helper daemon already registered")
        }
        #endif
    }

    #if DEBUG
    private func loadHelperAgent() {
        // Check if the agent is already registered — if so, don't bounce it
        // (the build script may have already loaded it).
        let uid = getuid()
        let domain = "gui/\(uid)"

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        check.arguments = ["print", "\(domain)/com.saddle.helper"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try? check.run()
        check.waitUntilExit()

        if check.terminationStatus == 0 {
            logger.info("Helper agent already loaded, skipping bootstrap")
            return
        }

        let helperPath = Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent("SaddleHelper")
            .path

        let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
              "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.saddle.helper</string>
                <key>Program</key>
                <string>\(helperPath)</string>
                <key>MachServices</key>
                <dict>
                    <key>com.saddle.helper</key>
                    <true/>
                </dict>
            </dict>
            </plist>
            """

        let plistPath = "/tmp/com.saddle.helper.plist"
        try? plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)

        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", domain, plistPath]
        try? bootstrap.run()
        bootstrap.waitUntilExit()

        if bootstrap.terminationStatus == 0 {
            logger.info("Helper agent loaded: \(helperPath)")
        } else {
            logger.error("Failed to load helper agent (exit \(bootstrap.terminationStatus))")
        }
    }
    #endif

    @objc private func handleWake(_ notification: Notification) {
        // Delay to let macOS re-enumerate and mount drives.
        // 5s initial wait — drives on USB hubs can take a few seconds to spin up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, let driveStore = self.driveStore, let configStore = self.configStore else { return }
            Task { @MainActor in
                await driveStore.refresh()
                await driveStore.runWakeActions(config: configStore.config, force: configStore.config.useForceUnmount)
            }
        }
    }
}


// MARK: - Notification Names

extension Notification.Name {
    static let runLaunchActions = Notification.Name("runLaunchActions")
    static let drivesChanged = Notification.Name("drivesChanged")
}
