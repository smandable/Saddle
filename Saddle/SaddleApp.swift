import SwiftUI
import ServiceManagement

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
        // Run launch actions after a brief delay to let drives settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, let driveStore = self.driveStore, let configStore = self.configStore else { return }
            Task { @MainActor in
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

    @objc private func handleWake(_ notification: Notification) {
        // Delay to let macOS re-enumerate and mount drives
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, let driveStore = self.driveStore, let configStore = self.configStore else { return }
            Task { @MainActor in
                driveStore.refresh()
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
