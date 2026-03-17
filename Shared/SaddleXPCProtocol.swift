import Foundation

// MARK: - XPC Protocol (App → Helper)

/// Interface exposed by the privileged helper daemon.
/// The sandboxed main app calls these methods over XPC to perform
/// DiskArbitration and IOKit operations that require elevated privileges.
@objc protocol SaddleXPCProtocol {
    /// Discover all external, user-visible volumes.
    /// Returns an array of dictionaries with string keys/values (XPC-safe).
    /// Keys: identifier, volumeUUID, volumeName, sizeDescription, sizeBytes,
    ///        isMounted, mountPoint, deviceNode
    func discoverExternalDrives(withReply reply: @escaping ([[String: String]]) -> Void)

    /// Mount a drive by its BSD identifier (e.g. "disk4s1").
    func mount(bsdName: String, withReply reply: @escaping (_ success: Bool, _ message: String) -> Void)

    /// Unmount a drive by its BSD identifier, optionally forcing.
    func unmount(bsdName: String, force: Bool, withReply reply: @escaping (_ success: Bool, _ message: String) -> Void)

    /// Start real-time disk monitoring. The helper will call
    /// `drivesDidChange()` on the client's exported object when disks
    /// appear, disappear, or change description.
    func startMonitoring()

    /// Stop real-time disk monitoring.
    func stopMonitoring()
}


// MARK: - XPC Client Protocol (Helper → App)

/// Callback interface exported by the main app so the helper can
/// push disk-change notifications back over the same XPC connection.
@objc protocol SaddleXPCClientProtocol {
    func drivesDidChange()
}
