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
    @Published var helperConnected: Bool = true

    private let diskService = DiskService.shared
    private var refreshTimer: Timer?
    private var hasRunLaunchActions = false
    private var hasCompletedFirstRefresh = false
    private var debounceTask: Task<Void, Never>?

    /// Persistent IDs of drives the user explicitly unmounted this session.
    /// When a drive reappears mounted (e.g. USB reconnect), it will be auto-unmounted.
    private var manuallyUnmountedIds: Set<String> = []
    /// Drives currently scheduled for re-unmount (prevents duplicate scheduling).
    private var pendingReUnmounts: Set<String> = []
    /// Consecutive re-unmount failures per drive (for cooldown/max retry logic).
    private var reUnmountFailures: [String: Int] = [:]
    /// Cooldown expiry per drive — skip re-unmount attempts before this time.
    private var reUnmountCooldownUntil: [String: Date] = [:]
    private static let maxReUnmountAttempts = 3
    /// Timestamp of the last manual mount/unmount operation.
    /// Re-unmount is suppressed for a short window after manual operations
    /// to avoid racing with the unmount still being processed.
    private var lastManualOperationTime: Date = .distantPast
    /// Tracks last known state to avoid logging routine refreshes with no changes.
    private var lastRefreshSignature = ""

    /// When true, DA-triggered refreshes are suppressed (wake settling in progress).
    private var isWakeSettling: Bool = false
    private var wakeSettlingTask: Task<Void, Never>?

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
                guard !store.isWakeSettling else { return }
                await store.refresh()
            }
        }
    }

    /// Stop and restart DA monitoring — called after the helper daemon is
    /// rebooted (debug builds) so the push connection targets the new process.
    func restartMonitoring() {
        diskService.stopMonitoring()
        diskService.startMonitoring { [weak self] in
            Task { @MainActor in
                self?.debouncedRefresh()
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
        // During wake settling, the polling loop handles refreshes
        guard !isWakeSettling else { return }

        // Skip if a refresh just completed — avoids cascade after bulk ops
        guard Date.now.timeIntervalSince(lastRefresh) > 2.0 || drives.isEmpty else {
            return
        }
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    // MARK: - Refresh

    func refresh(force: Bool = false) async {
        // Rate-limit: skip if last refresh was recent (unless forced by user action or wake polling)
        if !force && !drives.isEmpty && Date.now.timeIntervalSince(lastRefresh) < 5.0 {
            return
        }
        isRefreshing = true
        if let discovered = await diskService.discoverExternalDrives() {
            drives = discovered
            helperConnected = true
            hasCompletedFirstRefresh = true
        } else {
            // XPC failed — keep existing drive list but mark disconnected
            helperConnected = false
            logger.warning("Helper not responding (failures: \(self.diskService.consecutiveFailures))")
        }
        lastRefresh = .now
        isRefreshing = false
        let signature = "\(drives.count)-\(drives.filter(\.isMounted).count)-\(helperConnected)"
        if signature != lastRefreshSignature {
            logger.info("Refreshed: \(self.drives.count) external volume(s), \(self.drives.filter(\.isMounted).count) mounted, helper connected: \(self.helperConnected)")
            lastRefreshSignature = signature
        }

        // Re-unmount drives that the user previously unmounted but that macOS
        // auto-mounted after a USB reconnect / hub power cycle.
        // Each drive is handled independently to avoid one stalling the rest.
        // During wake settling, skip — wake actions handle unmounting.
        guard !isWakeSettling else { return }
        guard Date.now.timeIntervalSince(lastManualOperationTime) > 3 else { return }

        for drive in drives where drive.isMounted && manuallyUnmountedIds.contains(drive.persistentId) {
            scheduleReUnmount(persistentId: drive.persistentId)
        }
    }

    /// Schedule a single drive for re-unmount after a delay.
    /// Each drive is handled independently so one slow unmount can't block the rest.
    private func scheduleReUnmount(persistentId: String) {
        guard !pendingReUnmounts.contains(persistentId) else { return }
        let failures = reUnmountFailures[persistentId] ?? 0
        guard failures < Self.maxReUnmountAttempts else { return }
        if let cooldownUntil = reUnmountCooldownUntil[persistentId], Date.now < cooldownUntil { return }
        pendingReUnmounts.insert(persistentId)

        Task {
            // Wait for macOS to finish setting up this drive after reconnect
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s

            // If wake settling started during the delay, bail out — wake actions handle unmounts
            guard !isWakeSettling else {
                pendingReUnmounts.remove(persistentId)
                return
            }

            // Check if user changed their mind (e.g. clicked Mount All)
            guard manuallyUnmountedIds.contains(persistentId) else {
                pendingReUnmounts.remove(persistentId)
                return
            }

            // Discover fresh to get current BSD name without modifying self.drives
            // (other re-unmount tasks may be running concurrently)
            let currentDrives = await diskService.discoverExternalDrives() ?? []

            // Re-check after XPC call — user may have clicked mount during the await
            guard manuallyUnmountedIds.contains(persistentId),
                  Date.now.timeIntervalSince(lastManualOperationTime) > 3 else {
                pendingReUnmounts.remove(persistentId)
                return
            }

            if let drive = currentDrives.first(where: { $0.persistentId == persistentId }), drive.isMounted {
                logger.info("Auto re-unmounting \(drive.volumeName)")
                let result = await diskService.forceUnmount(identifier: drive.identifier)
                if !result.success {
                    let count = (reUnmountFailures[persistentId] ?? 0) + 1
                    reUnmountFailures[persistentId] = count
                    let cooldown = TimeInterval(30 * (1 << min(count - 1, 2))) // 30s, 60s, 120s
                    reUnmountCooldownUntil[persistentId] = Date.now.addingTimeInterval(cooldown)
                    logger.warning("Re-unmount of \(drive.volumeName) failed (\(count)/\(Self.maxReUnmountAttempts)): \(result.message)")
                } else {
                    reUnmountFailures.removeValue(forKey: persistentId)
                    reUnmountCooldownUntil.removeValue(forKey: persistentId)
                }
            }

            pendingReUnmounts.remove(persistentId)
            // No refresh() here — the unmount triggers a DA callback
            // which fires debouncedRefresh() automatically.
        }
    }

    /// Re-register the helper daemon and retry the XPC connection.
    /// Called from the UI when the helper is unreachable.
    func retryHelperConnection() async {
        logger.info("Retrying helper connection...")
        statusMessage = "Re-registering helper daemon..."

        // Ask AppDelegate to re-register the daemon
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.registerHelperDaemon()
        }

        // Give launchd a moment to spawn the helper
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Restart monitoring (old connection was likely invalidated)
        diskService.stopMonitoring()
        diskService.startMonitoring { [weak self] in
            Task { @MainActor in
                self?.debouncedRefresh()
            }
        }

        await refresh(force: true)

        if helperConnected {
            statusMessage = "Helper reconnected"
        } else {
            statusMessage = "Helper still unreachable — check System Settings > Login Items"
        }
        clearStatusAfterDelay()
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
            // User explicitly wants this mounted — clear re-unmount tracking
            // immediately, before the XPC call (which may time out)
            manuallyUnmountedIds.remove(persistentId)
            reUnmountFailures.removeValue(forKey: persistentId)
            reUnmountCooldownUntil.removeValue(forKey: persistentId)
            result = await diskService.mount(identifier: d.identifier)
            statusMessage = result.success
                ? "Mounted \(d.volumeName)"
                : "Failed to mount \(d.volumeName): \(result.message)"
        }

        await refresh(force: true)
        clearStatusAfterDelay()
    }

    // MARK: - Bulk Operations

    func mountAll(excluding excluded: Set<String>) async {
        lastManualOperationTime = .now
        // Clear re-unmount tracking for all managed drives — user wants everything mounted
        let managedIds = Set(managedDrives(excluding: excluded).map(\.persistentId))
        manuallyUnmountedIds.subtract(managedIds)
        for id in managedIds { reUnmountFailures.removeValue(forKey: id); reUnmountCooldownUntil.removeValue(forKey: id) }

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
        await refresh(force: true)
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
        let freshDrives = await diskService.discoverExternalDrives() ?? []
        for drive in targets {
            if let fresh = freshDrives.first(where: { $0.persistentId == drive.persistentId }), !fresh.isMounted {
                manuallyUnmountedIds.insert(drive.persistentId)
            }
        }
        let messages = results.map(\.0)
        statusMessage = messages.isEmpty
            ? "All drives already unmounted"
            : messages.joined(separator: ", ")
        await refresh(force: true)
        clearStatusAfterDelay()
    }

    // MARK: - Group Operations

    func mountGroup(_ group: DriveGroup) async {
        lastManualOperationTime = .now
        // Clear re-unmount tracking for all drives in this group
        manuallyUnmountedIds.subtract(group.driveIdentifiers)
        for id in group.driveIdentifiers { reUnmountFailures.removeValue(forKey: id); reUnmountCooldownUntil.removeValue(forKey: id) }

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
        await refresh(force: true)
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
        let freshDrives = await diskService.discoverExternalDrives() ?? []
        for d in targets {
            if let fresh = freshDrives.first(where: { $0.persistentId == d.persistentId }), !fresh.isMounted {
                manuallyUnmountedIds.insert(d.persistentId)
            }
        }
        statusMessage = messages.isEmpty
            ? "All drives in \(group.name) already unmounted"
            : messages.joined(separator: ", ")
        await refresh(force: true)
        clearStatusAfterDelay()
    }

    // MARK: - Launch Actions

    /// Wait until the helper has responded to at least one discoverExternalDrives
    /// call, OR the timeout elapses. Polls every 250ms.
    @discardableResult
    func waitForReady(timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if hasCompletedFirstRefresh && helperConnected { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        logger.warning("waitForReady timed out after \(Int(timeout))s — running launch actions with current state")
        return false
    }

    func runLaunchActions(config: AppConfig) async {
        guard !hasRunLaunchActions else { return }

        // If the helper never came up and we have no drives to act on, don't latch
        // the guard — leave it so a later trigger can still run launch actions.
        if !helperConnected && drives.isEmpty {
            logger.warning("Skipping launch actions: helper unreachable and no drives discovered")
            return
        }

        hasRunLaunchActions = true

        let excluded = Set(config.excludedIdentifiers)

        // Global mount-all on launch (independent of group actions)
        if config.mountAllOnLaunch {
            logger.info("Mounting all drives on launch...")
            for drive in drives.filter({ !$0.isMounted && !excluded.contains($0.persistentId) }) {
                let result = await diskService.mount(identifier: drive.identifier)
                logger.info("Launch mount \(drive.volumeName, privacy: .public): \(result.success ? "OK" : result.message, privacy: .public)")
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

            let targets = drives.filter { $0.isMounted && !excluded.contains($0.persistentId) }
            logger.info("Unmounting all drives on launch (\(targets.count, privacy: .public) targets)...")

            // Unmount all targets — DiskService has built-in 10s timeout per call
            for drive in targets {
                let result = config.useForceUnmount
                    ? await diskService.forceUnmount(identifier: drive.identifier)
                    : await diskService.unmount(identifier: drive.identifier)
                logger.info("Launch unmount \(drive.volumeName, privacy: .public): \(result.success ? "OK" : result.message, privacy: .public)")
            }

            await refresh(force: true)
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
                        logger.info("Launch mount \(d.volumeName, privacy: .public): \(result.success ? "OK" : result.message, privacy: .public)")
                    }
                }
            case .unmount:
                for id in group.driveIdentifiers {
                    if let d = drive(for: id), d.isMounted {
                        let result = await diskService.unmount(identifier: d.identifier)
                        if result.success {
                            manuallyUnmountedIds.insert(d.persistentId)
                        }
                        logger.info("Launch unmount \(d.volumeName, privacy: .public): \(result.success ? "OK" : result.message, privacy: .public)")
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

            let targets = drives.filter { $0.isMounted && !excluded.contains($0.persistentId) }
            logger.info("Unmounting all drives on wake (\(targets.count) targets)...")

            // Unmount all targets — DiskService has built-in 10s timeout per call
            for drive in targets {
                let result = force
                    ? await diskService.forceUnmount(identifier: drive.identifier)
                    : await diskService.unmount(identifier: drive.identifier)
                logger.info("Wake unmount \(drive.volumeName): \(result.success ? "OK" : result.message)")
                if result.success { await refresh(force: true) }
            }

            // Retry pass — macOS may remount drives during wake
            let retryStart = Date.now
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            // Skip retry if user manually mounted something during the wait
            guard Date.now.timeIntervalSince(lastManualOperationTime) > Date.now.timeIntervalSince(retryStart) else {
                logger.info("Wake retry skipped — manual operation detected")
                await refresh(force: true)
                logger.info("Wake unmount-all complete")
                return
            }

            await refresh(force: true)
            let stillMounted = drives.filter { $0.isMounted && !excluded.contains($0.persistentId) }
            if !stillMounted.isEmpty {
                logger.info("Retrying \(stillMounted.count) drives that remounted...")
                for drive in stillMounted {
                    let result = await diskService.forceUnmount(identifier: drive.identifier)
                    logger.info("Retry unmount \(drive.volumeName): \(result.success ? "OK" : result.message)")
                    if result.success { await refresh(force: true) }
                }
            }

            await refresh(force: true)
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
                        if result.success { await refresh(force: true) }
                    }
                }
            case .none:
                break
            }
        }

        await refresh()
        logger.info("Wake actions complete")
    }

    // MARK: - Wake Settling

    /// Call from willSleepNotification to suppress DA callbacks before the system
    /// sleeps. This prevents auto re-unmount from racing with wake actions.
    func prepareForSleep() {
        isWakeSettling = true
        logger.info("Preparing for sleep: DA callbacks suppressed")
    }

    /// Suppress DA-triggered refreshes and poll until drives stabilize,
    /// then run wake actions. Solves both refresh spam and premature wake actions.
    func handleWake(config: AppConfig, force: Bool) {
        wakeSettlingTask?.cancel()
        isWakeSettling = true
        reUnmountFailures.removeAll()
        reUnmountCooldownUntil.removeAll()

        wakeSettlingTask = Task {
            // Guarantee DA callbacks resume even if this task is cancelled or errors
            defer { isWakeSettling = false }

            logger.info("Wake settling: suppressing DA callbacks")

            // Phase 1: Let macOS start re-enumerating USB drives
            try? await Task.sleep(nanoseconds: 8_000_000_000) // 8s — USB hubs need time to spin up
            guard !Task.isCancelled else { return }

            // Phase 2: Poll until drive state stabilizes
            // Require at least 5 polls before declaring stable — prevents false
            // stability when macOS hasn't started remounting drives yet.
            var previousSignature = ""
            var stablePolls = 0
            let minPolls = 5
            let maxAttempts = 20 // 20 × 2s = 40s max polling

            for attempt in 0..<maxAttempts {
                await refresh(force: true)
                guard !Task.isCancelled else { return }

                let signature = "\(drives.count)-\(drives.filter(\.isMounted).count)"
                logger.info("Wake settling poll \(attempt + 1): \(signature)")

                if attempt >= minPolls && signature == previousSignature && !drives.isEmpty {
                    stablePolls += 1
                    if stablePolls >= 2 {
                        logger.info("Wake settling: drives stabilized (\(signature))")
                        break
                    }
                } else {
                    stablePolls = 0
                }
                previousSignature = signature

                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s between polls
                guard !Task.isCancelled else { return }
            }

            // Phase 3: Run wake actions now that drives have settled
            await refresh(force: true)
            await runWakeActions(config: config, force: force)

            // Follow-up: catch drives that finished unmounting after our timeout
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                await self?.refresh(force: true)
            }

            logger.info("Wake settling complete, DA callbacks resumed")
        }
    }
}
