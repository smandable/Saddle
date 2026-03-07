import SwiftUI
import ServiceManagement

/// DriveManager — macOS Menu Bar App for External Drive Management
///
/// A native SwiftUI menu bar utility that lets you monitor, mount, unmount,
/// and organize external drives into groups with automatic launch actions.

@main
struct DriveManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var driveStore = DriveStore()
    @StateObject private var configStore = ConfigStore()
    @State private var showSettings = false

    var body: some Scene {
        // ── Menu Bar ────────────────────────────────────────────────
        MenuBarExtra {
            MenuBarView(driveStore: driveStore, configStore: configStore, showSettings: $showSettings)
        } label: {
            Label {
                Text("DriveManager")
            } icon: {
                Image(systemName: "externaldrive.fill")
            }
        }
        .menuBarExtraStyle(.menu)

        // ── Settings Window ─────────────────────────────────────────
        Window("DriveManager Settings", id: "settings") {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run launch actions after a brief delay to let drives settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            NotificationCenter.default.post(name: .runLaunchActions, object: nil)
        }
    }
}


// MARK: - Notification Names

extension Notification.Name {
    static let runLaunchActions = Notification.Name("runLaunchActions")
    static let drivesChanged = Notification.Name("drivesChanged")
}
