import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "com.drivemanager.app", category: "DriveStore")

// MARK: - Drive Store

/// Central store for external drive state. Publishes changes so SwiftUI
/// views automatically update when drives mount, unmount, or connect.
@MainActor
final class DriveStore: ObservableObject {
    @Published var drives: [ExternalDrive] = []
    @Published var lastRefresh: Date = .now
    @Published var isRefreshing: Bool = false
    @Published var statusMessage: String?

    private let diskService = DiskService.shared
    private var refreshTimer: Timer?
    private var hasRunLaunchActions = false

    init() {
        // Start DiskArbitration monitoring — triggers refresh on any disk event
        diskService.startMonitoring { [weak self] in
            Task { @MainActor in
                // Small debounce: disk events can fire in bursts
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                self?.refresh()
            }
        }

        // Initial scan
        refresh()

        // Periodic refresh as a safety net
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let store = self
            Task { @MainActor in
                store.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Refresh

    func refresh() {
        isRefreshing = true
        drives = diskService.discoverExternalDrives()
        lastRefresh = .now
        isRefreshing = false
        logger.info("Refreshed: \(self.drives.count) external volume(s)")
    }

    // MARK: - Computed Properties

    /// Drives not in the excluded list.
    func managedDrives(excluding excluded: Set<String>) -> [ExternalDrive] {
        drives.filter { !excluded.contains($0.identifier) }
    }

    /// Count of mounted managed drives.
    func mountedCount(excluding excluded: Set<String>) -> Int {
        managedDrives(excluding: excluded).filter(\.isMounted).count
    }

    /// Look up a drive by identifier.
    func drive(for identifier: String) -> ExternalDrive? {
        drives.first { $0.identifier == identifier }
    }

    // MARK: - Single Drive Operations

    func toggleMount(identifier: String, force: Bool = false) async {
        guard let d = drive(for: identifier) else { return }
        let result: DiskOperationResult

        if d.isMounted {
            result = force
                ? await diskService.forceUnmount(identifier: identifier)
                : await diskService.unmount(identifier: identifier)
            statusMessage = result.success
                ? "Unmounted \(d.volumeName)"
                : "Failed to unmount \(d.volumeName): \(result.message)"
        } else {
            result = await diskService.mount(identifier: identifier)
            statusMessage = result.success
                ? "Mounted \(d.volumeName)"
                : "Failed to mount \(d.volumeName): \(result.message)"
        }

        refresh()

        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if statusMessage != nil { statusMessage = nil }
        }
    }

    // MARK: - Group Operations

    func mountGroup(_ group: DriveGroup) async {
        var messages: [String] = []
        for id in group.driveIdentifiers {
            guard let d = drive(for: id), !d.isMounted else { continue }
            let result = await diskService.mount(identifier: id)
            let icon = result.success ? "✅" : "❌"
            messages.append("\(icon) \(d.volumeName)")
        }
        statusMessage = messages.isEmpty
            ? "All drives in \(group.name) already mounted"
            : messages.joined(separator: ", ")
        refresh()
    }

    func unmountGroup(_ group: DriveGroup, force: Bool = false) async {
        var messages: [String] = []
        for id in group.driveIdentifiers {
            guard let d = drive(for: id), d.isMounted else { continue }
            let result = force
                ? await diskService.forceUnmount(identifier: id)
                : await diskService.unmount(identifier: id)
            let icon = result.success ? "✅" : "❌"
            messages.append("\(icon) \(d.volumeName)")
        }
        statusMessage = messages.isEmpty
            ? "All drives in \(group.name) already unmounted"
            : messages.joined(separator: ", ")
        refresh()
    }

    // MARK: - Launch Actions

    func runLaunchActions(config: AppConfig) async {
        guard !hasRunLaunchActions else { return }
        hasRunLaunchActions = true

        guard config.autoActionsOnLaunch else {
            logger.info("Auto-actions disabled, skipping launch actions")
            return
        }

        logger.info("Running launch actions...")

        for group in config.groups {
            switch group.action {
            case .mount:
                for id in group.driveIdentifiers {
                    if let d = drive(for: id), !d.isMounted {
                        let result = await diskService.mount(identifier: id)
                        logger.info("Launch mount \(d.volumeName): \(result.success ? "OK" : result.message)")
                    }
                }
            case .unmount:
                for id in group.driveIdentifiers {
                    if let d = drive(for: id), d.isMounted {
                        let result = await diskService.unmount(identifier: id)
                        logger.info("Launch unmount \(d.volumeName): \(result.success ? "OK" : result.message)")
                    }
                }
            case .none:
                break
            }
        }

        refresh()
        logger.info("Launch actions complete")
    }
}
