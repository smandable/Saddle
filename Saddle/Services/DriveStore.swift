import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "com.saddle.app", category: "DriveStore")

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

    /// Persistent IDs of drives the user explicitly unmounted this session.
    /// When a drive reappears mounted (e.g. USB reconnect), it will be auto-unmounted.
    private var manuallyUnmountedIds: Set<String> = []
    /// Guard against recursive re-unmount during refresh.
    private var isReUnmounting = false
    /// Timestamp of the last manual mount/unmount operation.
    /// Re-unmount is suppressed for a short window after manual operations
    /// to avoid racing with the unmount still being processed.
    private var lastManualOperationTime: Date = .distantPast

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

        // Re-unmount drives that the user previously unmounted but that macOS
        // auto-mounted after a USB reconnect / hub power cycle.
        // Skip if already re-unmounting, or if a manual operation just happened
        // (the drives may still be mid-unmount from that operation).
        guard !isReUnmounting else { return }
        guard Date.now.timeIntervalSince(lastManualOperationTime) > 3 else { return }

        let toReUnmount = drives.filter { $0.isMounted && manuallyUnmountedIds.contains($0.persistentId) }
        if !toReUnmount.isEmpty {
            isReUnmounting = true
            Task {
                // Wait for macOS to finish its auto-mount process after USB reconnect
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s

                for drive in toReUnmount {
                    // Re-check that the drive is still mounted (it may have been
                    // handled by another path while we waited)
                    guard self.drive(for: drive.persistentId)?.isMounted == true else { continue }
                    logger.info("Auto re-unmounting \(drive.volumeName) (was manually unmounted)")
                    let result = await diskService.unmount(identifier: drive.identifier)
                    if !result.success {
                        logger.warning("Re-unmount of \(drive.volumeName) failed: \(result.message)")
                    }
                }
                isReUnmounting = false
                refresh()
            }
        }
    }

    private func clearStatusAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4s
            if statusMessage != nil { statusMessage = nil }
        }
    }

    // MARK: - Computed Properties

    /// Drives not in the excluded list.
    func managedDrives(excluding excluded: Set<String>) -> [ExternalDrive] {
        drives.filter { !excluded.contains($0.persistentId) }
    }

    /// Count of mounted managed drives.
    func mountedCount(excluding excluded: Set<String>) -> Int {
        managedDrives(excluding: excluded).filter(\.isMounted).count
    }

    /// Look up a drive by its persistent ID (volume UUID or BSD name fallback).
    func drive(for persistentId: String) -> ExternalDrive? {
        drives.first { $0.persistentId == persistentId }
    }

    // MARK: - Single Drive Operations

    func toggleMount(persistentId: String, force: Bool = false, isExcluded: Bool = false) async {
        lastManualOperationTime = .now
        guard let d = drive(for: persistentId) else { return }
        let result: DiskOperationResult

        if d.isMounted {
            result = force
                ? await diskService.forceUnmount(identifier: d.identifier)
                : await diskService.unmount(identifier: d.identifier)
            if result.success && !isExcluded {
                manuallyUnmountedIds.insert(persistentId)
            }
            statusMessage = result.success
                ? "Unmounted \(d.volumeName)"
                : "Failed to unmount \(d.volumeName): \(result.message)"
        } else {
            result = await diskService.mount(identifier: d.identifier)
            if result.success {
                manuallyUnmountedIds.remove(persistentId)
            }
            statusMessage = result.success
                ? "Mounted \(d.volumeName)"
                : "Failed to mount \(d.volumeName): \(result.message)"
        }

        refresh()
        clearStatusAfterDelay()
    }

    // MARK: - Bulk Operations

    func mountAll(excluding excluded: Set<String>) async {
        lastManualOperationTime = .now
        // Clear re-unmount tracking for all managed drives — user wants everything mounted
        let managedIds = Set(managedDrives(excluding: excluded).map(\.persistentId))
        manuallyUnmountedIds.subtract(managedIds)

        let targets = managedDrives(excluding: excluded).filter { !$0.isMounted }
        var messages: [String] = []
        for drive in targets {
            let result = await diskService.mount(identifier: drive.identifier)
            let icon = result.success ? "✅" : "❌"
            messages.append("\(icon) \(drive.volumeName)")
        }
        statusMessage = messages.isEmpty
            ? "All drives already mounted"
            : messages.joined(separator: ", ")
        refresh()
        clearStatusAfterDelay()
    }

    func unmountAll(excluding excluded: Set<String>, force: Bool = false) async {
        lastManualOperationTime = .now
        let targets = managedDrives(excluding: excluded).filter(\.isMounted)
        var messages: [String] = []
        for drive in targets {
            let result = force
                ? await diskService.forceUnmount(identifier: drive.identifier)
                : await diskService.unmount(identifier: drive.identifier)
            if result.success {
                manuallyUnmountedIds.insert(drive.persistentId)
            }
            let icon = result.success ? "✅" : "❌"
            messages.append("\(icon) \(drive.volumeName)")
        }
        statusMessage = messages.isEmpty
            ? "All drives already unmounted"
            : messages.joined(separator: ", ")
        refresh()
        clearStatusAfterDelay()
    }

    // MARK: - Group Operations

    func mountGroup(_ group: DriveGroup) async {
        lastManualOperationTime = .now
        // Clear re-unmount tracking for all drives in this group
        manuallyUnmountedIds.subtract(group.driveIdentifiers)

        var messages: [String] = []
        for id in group.driveIdentifiers {
            guard let d = drive(for: id), !d.isMounted else { continue }
            let result = await diskService.mount(identifier: d.identifier)
            let icon = result.success ? "✅" : "❌"
            messages.append("\(icon) \(d.volumeName)")
        }
        statusMessage = messages.isEmpty
            ? "All drives in \(group.name) already mounted"
            : messages.joined(separator: ", ")
        refresh()
        clearStatusAfterDelay()
    }

    func unmountGroup(_ group: DriveGroup, force: Bool = false) async {
        lastManualOperationTime = .now
        var messages: [String] = []
        for id in group.driveIdentifiers {
            guard let d = drive(for: id), d.isMounted else { continue }
            let result = force
                ? await diskService.forceUnmount(identifier: d.identifier)
                : await diskService.unmount(identifier: d.identifier)
            if result.success {
                manuallyUnmountedIds.insert(d.persistentId)
            }
            let icon = result.success ? "✅" : "❌"
            messages.append("\(icon) \(d.volumeName)")
        }
        statusMessage = messages.isEmpty
            ? "All drives in \(group.name) already unmounted"
            : messages.joined(separator: ", ")
        refresh()
        clearStatusAfterDelay()
    }

    // MARK: - Launch Actions

    func runLaunchActions(config: AppConfig) async {
        guard !hasRunLaunchActions else { return }
        hasRunLaunchActions = true

        // Global mount-all on launch (independent of group actions)
        if config.mountAllOnLaunch {
            logger.info("Mounting all drives on launch...")
            for drive in drives.filter({ !$0.isMounted }) {
                let result = await diskService.mount(identifier: drive.identifier)
                logger.info("Launch mount \(drive.volumeName): \(result.success ? "OK" : result.message)")
            }
            refresh()
            logger.info("Launch mount-all complete")
            return
        }

        // Global unmount-all on launch (independent of group actions)
        if config.unmountAllOnLaunch {
            logger.info("Unmounting all drives on launch...")
            for drive in drives.filter(\.isMounted) {
                let result = config.useForceUnmount
                    ? await diskService.forceUnmount(identifier: drive.identifier)
                    : await diskService.unmount(identifier: drive.identifier)
                logger.info("Launch unmount \(drive.volumeName): \(result.success ? "OK" : result.message)")
            }
            refresh()
            logger.info("Launch unmount-all complete")
            return
        }

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
                        let result = await diskService.mount(identifier: d.identifier)
                        logger.info("Launch mount \(d.volumeName): \(result.success ? "OK" : result.message)")
                    }
                }
            case .unmount:
                for id in group.driveIdentifiers {
                    if let d = drive(for: id), d.isMounted {
                        let result = await diskService.unmount(identifier: d.identifier)
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

    // MARK: - Wake Actions

    func runWakeActions(config: AppConfig, force: Bool = false) async {
        let excluded = Set(config.excludedIdentifiers)

        // Global mount-all on wake (independent of group actions)
        if config.mountAllOnWake {
            logger.info("Mounting all drives on wake...")
            for drive in drives.filter({ !$0.isMounted && !excluded.contains($0.persistentId) }) {
                let result = await diskService.mount(identifier: drive.identifier)
                logger.info("Wake mount \(drive.volumeName): \(result.success ? "OK" : result.message)")
            }
            refresh()
            logger.info("Wake mount-all complete")
            return
        }

        // Global unmount-all on wake (independent of group actions)
        if config.unmountAllOnWake {
            logger.info("Unmounting all drives on wake...")
            for drive in drives.filter({ $0.isMounted && !excluded.contains($0.persistentId) }) {
                let result = force
                    ? await diskService.forceUnmount(identifier: drive.identifier)
                    : await diskService.unmount(identifier: drive.identifier)
                logger.info("Wake unmount \(drive.volumeName): \(result.success ? "OK" : result.message)")
            }
            refresh()
            logger.info("Wake unmount-all complete")
            return
        }

        guard config.autoActionsOnWake else {
            logger.info("Auto-actions on wake disabled, skipping")
            return
        }

        logger.info("Running wake actions...")

        for group in config.groups {
            switch group.action {
            case .mount:
                for id in group.driveIdentifiers {
                    if let d = drive(for: id), !d.isMounted {
                        let result = await diskService.mount(identifier: d.identifier)
                        logger.info("Wake mount \(d.volumeName): \(result.success ? "OK" : result.message)")
                    }
                }
            case .unmount:
                for id in group.driveIdentifiers {
                    if let d = drive(for: id), d.isMounted {
                        let result = force
                            ? await diskService.forceUnmount(identifier: d.identifier)
                            : await diskService.unmount(identifier: d.identifier)
                        logger.info("Wake unmount \(d.volumeName): \(result.success ? "OK" : result.message)")
                    }
                }
            case .none:
                break
            }
        }

        refresh()
        logger.info("Wake actions complete")
    }
}
