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
    private var debounceTask: Task<Void, Never>?

    /// Persistent IDs of drives the user explicitly unmounted this session.
    /// When a drive reappears mounted (e.g. USB reconnect), it will be auto-unmounted.
    private var manuallyUnmountedIds: Set<String> = []
    /// Drives currently scheduled for re-unmount (prevents duplicate scheduling).
    private var pendingReUnmounts: Set<String> = []
    /// Timestamp of the last manual mount/unmount operation.
    /// Re-unmount is suppressed for a short window after manual operations
    /// to avoid racing with the unmount still being processed.
    private var lastManualOperationTime: Date = .distantPast

    init() {
        // Start DiskArbitration monitoring via XPC helper — triggers refresh on any disk event
        diskService.startMonitoring { [weak self] in
            Task { @MainActor in
                self?.debouncedRefresh()
            }
        }

        // Initial scan
        Task { await refresh() }

        // Periodic refresh as a safety net
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let store = self
            Task { @MainActor in
                await store.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Debounced Refresh

    /// Cancels any pending debounced refresh and schedules a new one.
    /// Collapses bursts of disk events into a single refresh.
    private func debouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    // MARK: - Refresh

    func refresh() async {
        isRefreshing = true
        drives = await diskService.discoverExternalDrives()
        lastRefresh = .now
        isRefreshing = false
        logger.info("Refreshed: \(self.drives.count) external volume(s)")

        // Re-unmount drives that the user previously unmounted but that macOS
        // auto-mounted after a USB reconnect / hub power cycle.
        // Each drive is handled independently to avoid one stalling the rest.
        guard Date.now.timeIntervalSince(lastManualOperationTime) > 3 else { return }

        for drive in drives where drive.isMounted && manuallyUnmountedIds.contains(drive.persistentId) {
            scheduleReUnmount(persistentId: drive.persistentId)
        }
    }

    /// Schedule a single drive for re-unmount after a delay.
    /// Each drive is handled independently so one slow unmount can't block the rest.
    private func scheduleReUnmount(persistentId: String) {
        guard !pendingReUnmounts.contains(persistentId) else { return }
        pendingReUnmounts.insert(persistentId)

        Task {
            // Wait for macOS to finish setting up this drive after reconnect
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s

            // Check if user changed their mind (e.g. clicked Mount All)
            guard manuallyUnmountedIds.contains(persistentId) else {
                pendingReUnmounts.remove(persistentId)
                return
            }

            // Discover fresh to get current BSD name without modifying self.drives
            // (other re-unmount tasks may be running concurrently)
            let currentDrives = await diskService.discoverExternalDrives()
            if let drive = currentDrives.first(where: { $0.persistentId == persistentId }), drive.isMounted {
                logger.info("Auto re-unmounting \(drive.volumeName)")
                let result = await diskService.forceUnmount(identifier: drive.identifier)
                if !result.success {
                    logger.warning("Re-unmount of \(drive.volumeName) failed: \(result.message)")
                }
            }

            pendingReUnmounts.remove(persistentId)
            await refresh()
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

        await refresh()
        clearStatusAfterDelay()
    }

    // MARK: - Bulk Operations

    func mountAll(excluding excluded: Set<String>) async {
        lastManualOperationTime = .now
        // Clear re-unmount tracking for all managed drives — user wants everything mounted
        let managedIds = Set(managedDrives(excluding: excluded).map(\.persistentId))
        manuallyUnmountedIds.subtract(managedIds)

        let targets = managedDrives(excluding: excluded).filter { !$0.isMounted }
        let messages = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for drive in targets {
                let id = drive.identifier
                let name = drive.volumeName
                group.addTask { [diskService] in
                    let result = await diskService.mount(identifier: id)
                    let icon = result.success ? "✅" : "❌"
                    return "\(icon) \(name)"
                }
            }
            var collected: [String] = []
            for await msg in group { collected.append(msg) }
            return collected
        }
        statusMessage = messages.isEmpty
            ? "All drives already mounted"
            : messages.joined(separator: ", ")
        await refresh()
        clearStatusAfterDelay()
    }

    func unmountAll(excluding excluded: Set<String>, force: Bool = false) async {
        lastManualOperationTime = .now
        let targets = managedDrives(excluding: excluded).filter(\.isMounted)
        let results = await withTaskGroup(of: (String, Bool).self, returning: [(String, Bool)].self) { group in
            for drive in targets {
                let id = drive.identifier
                let name = drive.volumeName
                group.addTask { [diskService] in
                    let result = force
                        ? await diskService.forceUnmount(identifier: id)
                        : await diskService.unmount(identifier: id)
                    let icon = result.success ? "✅" : "❌"
                    return ("\(icon) \(name)", result.success ? true : false)
                }
            }
            var collected: [(String, Bool)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        // Re-check which targets are now unmounted
        let freshDrives = await diskService.discoverExternalDrives()
        for drive in targets {
            if let fresh = freshDrives.first(where: { $0.persistentId == drive.persistentId }), !fresh.isMounted {
                manuallyUnmountedIds.insert(drive.persistentId)
            }
        }
        let messages = results.map(\.0)
        statusMessage = messages.isEmpty
            ? "All drives already unmounted"
            : messages.joined(separator: ", ")
        await refresh()
        clearStatusAfterDelay()
    }

    // MARK: - Group Operations

    func mountGroup(_ group: DriveGroup) async {
        lastManualOperationTime = .now
        // Clear re-unmount tracking for all drives in this group
        manuallyUnmountedIds.subtract(group.driveIdentifiers)

        let targets = group.driveIdentifiers.compactMap { id -> ExternalDrive? in
            guard let d = drive(for: id), !d.isMounted else { return nil }
            return d
        }
        let messages = await withTaskGroup(of: String.self, returning: [String].self) { taskGroup in
            for d in targets {
                let id = d.identifier
                let name = d.volumeName
                taskGroup.addTask { [diskService] in
                    let result = await diskService.mount(identifier: id)
                    let icon = result.success ? "✅" : "❌"
                    return "\(icon) \(name)"
                }
            }
            var collected: [String] = []
            for await msg in taskGroup { collected.append(msg) }
            return collected
        }
        statusMessage = messages.isEmpty
            ? "All drives in \(group.name) already mounted"
            : messages.joined(separator: ", ")
        await refresh()
        clearStatusAfterDelay()
    }

    func unmountGroup(_ group: DriveGroup, force: Bool = false) async {
        lastManualOperationTime = .now
        let targets = group.driveIdentifiers.compactMap { id -> ExternalDrive? in
            guard let d = drive(for: id), d.isMounted else { return nil }
            return d
        }
        let messages = await withTaskGroup(of: String.self, returning: [String].self) { taskGroup in
            for d in targets {
                let id = d.identifier
                let name = d.volumeName
                taskGroup.addTask { [diskService] in
                    let result = force
                        ? await diskService.forceUnmount(identifier: id)
                        : await diskService.unmount(identifier: id)
                    let icon = result.success ? "✅" : "❌"
                    return "\(icon) \(name)"
                }
            }
            var collected: [String] = []
            for await msg in taskGroup { collected.append(msg) }
            return collected
        }
        // Track successfully unmounted drives
        let freshDrives = await diskService.discoverExternalDrives()
        for d in targets {
            if let fresh = freshDrives.first(where: { $0.persistentId == d.persistentId }), !fresh.isMounted {
                manuallyUnmountedIds.insert(d.persistentId)
            }
        }
        statusMessage = messages.isEmpty
            ? "All drives in \(group.name) already unmounted"
            : messages.joined(separator: ", ")
        await refresh()
        clearStatusAfterDelay()
    }

    // MARK: - Launch Actions

    func runLaunchActions(config: AppConfig) async {
        guard !hasRunLaunchActions else { return }
        hasRunLaunchActions = true

        let excluded = Set(config.excludedIdentifiers)

        // Global mount-all on launch (independent of group actions)
        if config.mountAllOnLaunch {
            logger.info("Mounting all drives on launch...")
            for drive in drives.filter({ !$0.isMounted && !excluded.contains($0.persistentId) }) {
                let result = await diskService.mount(identifier: drive.identifier)
                logger.info("Launch mount \(drive.volumeName): \(result.success ? "OK" : result.message)")
            }
            await refresh()
            logger.info("Launch mount-all complete")
            return
        }

        // Global unmount-all on launch (independent of group actions)
        if config.unmountAllOnLaunch {
            // Track ALL managed drives as "should stay unmounted" — including ones
            // already unmounted from a previous session, so USB reconnect re-unmounts them
            let managedIds = Set(drives.filter { !excluded.contains($0.persistentId) }.map(\.persistentId))
            manuallyUnmountedIds.formUnion(managedIds)

            logger.info("Unmounting all drives on launch...")
            for drive in drives.filter({ $0.isMounted && !excluded.contains($0.persistentId) }) {
                let result = config.useForceUnmount
                    ? await diskService.forceUnmount(identifier: drive.identifier)
                    : await diskService.unmount(identifier: drive.identifier)
                logger.info("Launch unmount \(drive.volumeName): \(result.success ? "OK" : result.message)")
            }
            await refresh()
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
                        if result.success {
                            manuallyUnmountedIds.insert(d.persistentId)
                        }
                        logger.info("Launch unmount \(d.volumeName): \(result.success ? "OK" : result.message)")
                    }
                }
            case .none:
                break
            }
        }

        await refresh()
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
            await refresh()
            logger.info("Wake mount-all complete")
            return
        }

        // Global unmount-all on wake (independent of group actions)
        if config.unmountAllOnWake {
            // Track ALL managed drives as "should stay unmounted"
            let managedIds = Set(drives.filter { !excluded.contains($0.persistentId) }.map(\.persistentId))
            manuallyUnmountedIds.formUnion(managedIds)

            logger.info("Unmounting all drives on wake...")
            for drive in drives.filter({ $0.isMounted && !excluded.contains($0.persistentId) }) {
                let result = force
                    ? await diskService.forceUnmount(identifier: drive.identifier)
                    : await diskService.unmount(identifier: drive.identifier)
                logger.info("Wake unmount \(drive.volumeName): \(result.success ? "OK" : result.message)")
            }
            await refresh()
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
                        if result.success {
                            manuallyUnmountedIds.insert(d.persistentId)
                        }
                        logger.info("Wake unmount \(d.volumeName): \(result.success ? "OK" : result.message)")
                    }
                }
            case .none:
                break
            }
        }

        await refresh()
        logger.info("Wake actions complete")
    }
}
