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
        // Register the privileged helper daemon so launchd can start it on demand.
        // In debug builds this bootouts the old helper and bootstraps a fresh one,
        // which invalidates any existing monitoring XPC connection.
        registerHelperDaemon()

        // Restart monitoring so the persistent push connection targets the NEW helper
        driveStore?.restartMonitoring()

        // Check for updates silently on launch if enabled
        if configStore?.config.checkForUpdatesAutomatically == true {
            UpdateService.shared.checkForUpdates(silent: true)
        }

        // Wait for the helper to actually respond before reading drives.
        // On warm launch this returns in <1s; on cold boot it may take 5–15s
        // for launchd + DiskArbitration to settle.
        Task { @MainActor [weak self] in
            guard let self, let driveStore = self.driveStore, let configStore = self.configStore else { return }

            await driveStore.waitForReady(timeout: 30)

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

        // Suppress DA callbacks before sleep so auto re-unmount doesn't race with wake actions
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        // Re-run group actions when Mac wakes from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func registerHelperDaemon() {
        #if USE_SMAPPSERVICE
        // App Store path: register via SMAppService so launchd manages the
        // helper as a system daemon. Requires sandbox + BTM approval.
        let daemon = SMAppService.daemon(plistName: "com.seanmandable.saddle.helper.plist")
        let status = daemon.status
        logger.info("Helper daemon status: \(String(describing: status), privacy: .public)")

        try? daemon.unregister()

        do {
            try daemon.register()
            logger.info("Helper daemon registered successfully")
        } catch {
            logger.error("Failed to register helper daemon: \(error.localizedDescription, privacy: .public)")
        }
        #else
        // Developer ID path: load helper as a user agent via launchctl.
        // No SMAppService/BTM involvement — works without sandbox.
        loadHelperAgent()
        #endif
    }

    private func loadHelperAgent() {
        let uid = getuid()
        let domain = "gui/\(uid)"
        let serviceTarget = "\(domain)/com.seanmandable.saddle.helper"

        let helperPath = Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent("SaddleHelper")
            .path

        // Skip bootout when the binary hasn't changed — preserves the running
        // helper across launches, avoiding XPC invalidation on cold boot.
        // Debug builds always bootout to pick up freshly built helper binaries.
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let lastVersionKey = "lastBootstrappedHelperVersion"
        let lastVersion = UserDefaults.standard.string(forKey: lastVersionKey)

        #if DEBUG
        let needsBootout = true
        #else
        let needsBootout = (lastVersion != currentVersion)
        #endif

        if needsBootout {
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", serviceTarget]
            bootout.standardOutput = FileHandle.nullDevice
            bootout.standardError = FileHandle.nullDevice
            try? bootout.run()
            bootout.waitUntilExit()
            logger.info("Helper bootout (version \(lastVersion ?? "none", privacy: .public) → \(currentVersion, privacy: .public))")
        }

        let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
              "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.seanmandable.saddle.helper</string>
                <key>Program</key>
                <string>\(helperPath)</string>
                <key>KeepAlive</key>
                <true/>
                <key>MachServices</key>
                <dict>
                    <key>com.seanmandable.saddle.helper</key>
                    <true/>
                </dict>
            </dict>
            </plist>
            """

        let plistPath = "/tmp/com.seanmandable.saddle.helper.plist"
        try? plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)

        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", domain, plistPath]
        bootstrap.standardOutput = FileHandle.nullDevice
        bootstrap.standardError = FileHandle.nullDevice
        try? bootstrap.run()
        bootstrap.waitUntilExit()

        // bootstrap returns non-zero if the service is already loaded — desired
        // no-op path in release. Only treat as failure when we expected a fresh load.
        if bootstrap.terminationStatus == 0 {
            UserDefaults.standard.set(currentVersion, forKey: lastVersionKey)
            logger.info("Helper agent loaded: \(helperPath, privacy: .public)")
        } else if needsBootout {
            logger.error("Failed to load helper agent (exit \(bootstrap.terminationStatus, privacy: .public))")
        } else {
            logger.info("Helper already loaded (version \(currentVersion, privacy: .public))")
        }
    }

    @objc private func handleSleep(_ notification: Notification) {
        Task { @MainActor in
            driveStore?.prepareForSleep()
        }
    }

    @objc private func handleWake(_ notification: Notification) {
        guard let driveStore = self.driveStore, let configStore = self.configStore else { return }
        Task { @MainActor in
            driveStore.handleWake(config: configStore.config, force: configStore.config.useForceUnmount)
        }
    }
}


// MARK: - Notification Names

extension Notification.Name {
    static let runLaunchActions = Notification.Name("runLaunchActions")
    static let drivesChanged = Notification.Name("drivesChanged")
}
