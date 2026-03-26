import Foundation
import os.log

private let logger = Logger(subsystem: "com.saddle.app", category: "DiskService")

// MARK: - Disk Service (XPC Client)

/// Provides disk discovery, mounting, unmounting, and real-time monitoring
/// by communicating with the privileged SaddleHelper daemon over XPC.
///
/// Uses a single persistent XPC connection for all operations. In debug builds
/// the helper runs as a user agent, and new Mach service connections don't
/// reliably work — reusing one connection avoids that issue entirely.
final class DiskService {
    static let shared = DiskService()

    /// Single persistent XPC connection used for all operations.
    private var connection: NSXPCConnection?

    /// Callback invoked when the helper reports a disk event.
    private var onChange: (() -> Void)?

    /// Handler that receives push notifications from the helper.
    private var clientHandler: ClientCallbackHandler?

    /// Tracks consecutive XPC failures so callers can show connection state.
    private(set) var consecutiveFailures: Int = 0

    /// The last XPC error message, if any.
    private(set) var lastError: String?

    private init() {}


    // MARK: - Connection Management

    /// Ensure the persistent XPC connection is alive. Creates and resumes
    /// a new connection if the current one is nil (first call or after invalidation).
    /// Returns the proxy, or nil if no connection could be established.
    private func getProxy() -> SaddleXPCProtocol? {
        if connection == nil {
            let conn = createXPCConnection()

            // Export the client callback interface so the helper can push notifications
            if let handler = clientHandler {
                conn.exportedInterface = NSXPCInterface(with: SaddleXPCClientProtocol.self)
                conn.exportedObject = handler
            }

            conn.invalidationHandler = { [weak self] in
                logger.warning("XPC connection invalidated")
                self?.connection = nil
            }

            conn.interruptionHandler = { [weak self] in
                logger.warning("XPC connection interrupted")
                self?.connection = nil
            }

            conn.resume()
            connection = conn

            // If monitoring was active, re-start it on the new connection
            if onChange != nil {
                let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                    logger.error("Monitoring XPC error: \(error.localizedDescription)")
                } as? SaddleXPCProtocol
                proxy?.startMonitoring()
                logger.info("XPC monitoring started (reconnect)")
            }
        }

        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            let msg = error.localizedDescription
            logger.error("XPC error: \(msg)")
            self?.consecutiveFailures += 1
            self?.lastError = msg
            // Don't invalidate connection here — a stale proxy's error handler
            // could fire late and kill a newer, working connection.
            // The connection's own invalidationHandler handles cleanup.
        } as? SaddleXPCProtocol
    }


    // MARK: - Monitoring

    /// Start real-time disk monitoring via the helper daemon.
    /// The helper registers DA callbacks and pushes `drivesDidChange()`
    /// notifications back over the XPC connection.
    func startMonitoring(onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.clientHandler = ClientCallbackHandler(onChange: onChange)

        // Ensure connection exists (getProxy creates it if needed,
        // and auto-starts monitoring when onChange is set)
        let _ = getProxy()
        logger.info("XPC monitoring started")
    }

    func stopMonitoring() {
        if let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? SaddleXPCProtocol {
            proxy.stopMonitoring()
        }
        connection?.invalidate()
        connection = nil
        onChange = nil
        clientHandler = nil
        logger.info("XPC monitoring stopped")
    }


    // MARK: - Drive Discovery

    /// Discover all external, user-visible volumes via the helper daemon.
    /// Returns `nil` when the XPC connection fails (as opposed to an empty
    /// array which means the helper responded but found no drives).
    func discoverExternalDrives() async -> [ExternalDrive]? {
        await withCheckedContinuation { continuation in
            var hasResumed = false
            let lock = NSLock()

            func safeResume(_ value: [ExternalDrive]?) {
                lock.lock()
                guard !hasResumed else { lock.unlock(); return }
                hasResumed = true
                lock.unlock()
                continuation.resume(returning: value)
            }

            guard let proxy = getProxy() else {
                consecutiveFailures += 1
                lastError = "No XPC connection"
                logger.warning("Discovery failed: no XPC connection")
                safeResume(nil)
                return
            }

            proxy.discoverExternalDrives { [weak self] dicts in
                let drives = dicts.compactMap { ExternalDrive(fromXPCDictionary: $0) }
                self?.consecutiveFailures = 0
                self?.lastError = nil
                safeResume(drives)
            }

            // Safety timeout — only fires if reply never arrives
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                lock.lock()
                let alreadyDone = hasResumed
                lock.unlock()
                guard !alreadyDone else { return }
                self?.consecutiveFailures += 1
                self?.lastError = "Discovery timeout"
                logger.warning("Discovery XPC timeout")
                safeResume(nil)
            }
        }
    }


    // MARK: - Mount

    /// Mount a drive by its BSD identifier using the helper daemon.
    func mount(identifier: String) async -> DiskOperationResult {
        await withCheckedContinuation { continuation in
            var hasResumed = false
            let lock = NSLock()

            func safeResume(_ result: DiskOperationResult) {
                lock.lock()
                guard !hasResumed else { lock.unlock(); return }
                hasResumed = true
                lock.unlock()
                continuation.resume(returning: result)
            }

            guard let proxy = getProxy() else {
                safeResume(DiskOperationResult(success: false, message: "No XPC connection"))
                return
            }

            proxy.mount(bsdName: identifier) { success, message in
                safeResume(DiskOperationResult(success: success, message: message))
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                lock.lock()
                let alreadyDone = hasResumed
                lock.unlock()
                guard !alreadyDone else { return }
                safeResume(DiskOperationResult(success: false, message: "Timeout (helper unresponsive)"))
            }
        }
    }


    // MARK: - Unmount

    /// Unmount a drive by its BSD identifier.
    func unmount(identifier: String) async -> DiskOperationResult {
        await performUnmount(identifier: identifier, force: false)
    }

    /// Force-unmount a drive (use with caution — can cause data loss if files are open).
    func forceUnmount(identifier: String) async -> DiskOperationResult {
        await performUnmount(identifier: identifier, force: true)
    }

    private func performUnmount(identifier: String, force: Bool) async -> DiskOperationResult {
        await withCheckedContinuation { continuation in
            var hasResumed = false
            let lock = NSLock()

            func safeResume(_ result: DiskOperationResult) {
                lock.lock()
                guard !hasResumed else { lock.unlock(); return }
                hasResumed = true
                lock.unlock()
                continuation.resume(returning: result)
            }

            guard let proxy = getProxy() else {
                safeResume(DiskOperationResult(success: false, message: "No XPC connection"))
                return
            }

            proxy.unmount(bsdName: identifier, force: force) { success, message in
                safeResume(DiskOperationResult(success: success, message: message))
            }

            // GCD timeout — fires on background queue, immune to actor blocking
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                lock.lock()
                let alreadyDone = hasResumed
                lock.unlock()
                guard !alreadyDone else { return }
                safeResume(DiskOperationResult(success: false, message: "Timeout (helper unresponsive)"))
            }
        }
    }


    // MARK: - Batch Operations

    func mountAll(identifiers: [String]) async -> [String: DiskOperationResult] {
        var results: [String: DiskOperationResult] = [:]
        for id in identifiers {
            results[id] = await mount(identifier: id)
        }
        return results
    }

    func unmountAll(identifiers: [String]) async -> [String: DiskOperationResult] {
        var results: [String: DiskOperationResult] = [:]
        for id in identifiers {
            results[id] = await unmount(identifier: id)
        }
        return results
    }


    // MARK: - XPC Connection

    private func createXPCConnection() -> NSXPCConnection {
        #if USE_SMAPPSERVICE
        // App Store path: connect to system daemon (requires .privileged).
        let connection = NSXPCConnection(machServiceName: "com.seanmandable.saddle.helper", options: .privileged)
        #else
        // Developer ID path: connect to user agent (no .privileged needed).
        let connection = NSXPCConnection(machServiceName: "com.seanmandable.saddle.helper", options: [])
        #endif
        connection.remoteObjectInterface = NSXPCInterface(with: SaddleXPCProtocol.self)
        return connection
    }
}


// MARK: - Supporting Types

struct DiskOperationResult: Sendable {
    let success: Bool
    let message: String
}

/// Receives push notifications from the helper daemon when disks change.
private class ClientCallbackHandler: NSObject, SaddleXPCClientProtocol {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func drivesDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange()
        }
    }
}


// MARK: - ExternalDrive XPC Deserialization

extension ExternalDrive {
    /// Reconstruct an ExternalDrive from the dictionary sent over XPC.
    init?(fromXPCDictionary dict: [String: String]) {
        guard let identifier = dict["identifier"],
              let volumeName = dict["volumeName"],
              let sizeDescription = dict["sizeDescription"],
              let sizeBytesStr = dict["sizeBytes"],
              let sizeBytes = Int64(sizeBytesStr),
              let isMountedStr = dict["isMounted"],
              let deviceNode = dict["deviceNode"]
        else {
            return nil
        }

        let volumeUUID = dict["volumeUUID"]?.isEmpty == false ? dict["volumeUUID"] : nil
        let mountPoint = dict["mountPoint"]?.isEmpty == false ? dict["mountPoint"] : nil

        self.init(
            identifier: identifier,
            volumeUUID: volumeUUID,
            volumeName: volumeName,
            sizeDescription: sizeDescription,
            sizeBytes: sizeBytes,
            isMounted: isMountedStr == "true",
            mountPoint: mountPoint,
            deviceNode: deviceNode
        )
    }
}
