import Foundation
import os.log

private let logger = Logger(subsystem: "com.saddle.app", category: "DiskService")

// MARK: - Disk Service (XPC Client)

/// Provides disk discovery, mounting, unmounting, and real-time monitoring
/// by communicating with the privileged SaddleHelper daemon over XPC.
///
/// All DiskArbitration and IOKit operations run in the helper process.
/// This class is a thin XPC client safe to use from a sandboxed app.
final class DiskService {
    static let shared = DiskService()

    /// Persistent XPC connection used for monitoring (kept alive so the helper
    /// can push `drivesDidChange()` callbacks back to us).
    private var monitoringConnection: NSXPCConnection?

    /// Callback invoked when the helper reports a disk event.
    private var onChange: (() -> Void)?

    private init() {}


    // MARK: - Monitoring

    /// Start real-time disk monitoring via the helper daemon.
    /// The helper registers DA callbacks and pushes `drivesDidChange()`
    /// notifications back over the XPC connection.
    func startMonitoring(onChange: @escaping () -> Void) {
        guard monitoringConnection == nil else { return }

        self.onChange = onChange

        let connection = createXPCConnection()

        // Export the client callback interface so the helper can notify us
        let clientHandler = ClientCallbackHandler(onChange: onChange)
        connection.exportedInterface = NSXPCInterface(with: SaddleXPCClientProtocol.self)
        connection.exportedObject = clientHandler

        connection.invalidationHandler = { [weak self] in
            logger.warning("Monitoring XPC connection invalidated")
            self?.monitoringConnection = nil
        }

        connection.resume()
        monitoringConnection = connection

        // Tell the helper to start its DA monitoring session
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            logger.error("Monitoring XPC error: \(error.localizedDescription)")
        } as? SaddleXPCProtocol

        proxy?.startMonitoring()
        logger.info("XPC monitoring started")
    }

    func stopMonitoring() {
        if let connection = monitoringConnection {
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? SaddleXPCProtocol
            proxy?.stopMonitoring()
            connection.invalidate()
        }
        monitoringConnection = nil
        onChange = nil
        logger.info("XPC monitoring stopped")
    }


    // MARK: - Drive Discovery

    /// Discover all external, user-visible volumes via the helper daemon.
    func discoverExternalDrives() async -> [ExternalDrive] {
        await withCheckedContinuation { continuation in
            let connection = createXPCConnection()
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                logger.error("Discovery XPC error: \(error.localizedDescription)")
                continuation.resume(returning: [])
                connection.invalidate()
            } as! SaddleXPCProtocol

            proxy.discoverExternalDrives { dicts in
                let drives = dicts.compactMap { ExternalDrive(fromXPCDictionary: $0) }
                continuation.resume(returning: drives)
                connection.invalidate()
            }
        }
    }


    // MARK: - Mount

    /// Mount a drive by its BSD identifier using the helper daemon.
    func mount(identifier: String) async -> DiskOperationResult {
        await withCheckedContinuation { continuation in
            let connection = createXPCConnection()
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(returning: DiskOperationResult(
                    success: false, message: "XPC error: \(error.localizedDescription)"))
                connection.invalidate()
            } as! SaddleXPCProtocol

            proxy.mount(bsdName: identifier) { success, message in
                continuation.resume(returning: DiskOperationResult(success: success, message: message))
                connection.invalidate()
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
            let connection = createXPCConnection()
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(returning: DiskOperationResult(
                    success: false, message: "XPC error: \(error.localizedDescription)"))
                connection.invalidate()
            } as! SaddleXPCProtocol

            proxy.unmount(bsdName: identifier, force: force) { success, message in
                continuation.resume(returning: DiskOperationResult(success: success, message: message))
                connection.invalidate()
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
        let connection = NSXPCConnection(machServiceName: "com.saddle.helper", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SaddleXPCProtocol.self)
        return connection
    }
}


// MARK: - Supporting Types

struct DiskOperationResult {
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
