import Foundation
import DiskArbitration
import IOKit
import IOKit.storage
import os.log

private let logger = Logger(subsystem: "com.saddle.app", category: "DiskService")

// MARK: - Disk Service

/// Provides disk discovery, mounting, unmounting, and real-time monitoring
/// using the macOS DiskArbitration framework exclusively.
///
/// No subprocess calls (`diskutil`, `Process()`) are used — all operations
/// go through DiskArbitration's C API, making this fully sandbox-compatible.
final class DiskService {
    static let shared = DiskService()

    /// A long-lived DA session scheduled on the main run loop for callbacks.
    private var monitoringSession: DASession?

    /// BSD identifiers of drives we've previously seen as external.
    /// Used to re-discover unmounted APFS volumes that may vanish from the IOKit registry.
    private var knownExternalIdentifiers: Set<String> = []

    private init() {}


    // MARK: - Session Lifecycle

    /// Start the DiskArbitration session to receive real-time disk events.
    func startMonitoring(onChange: @escaping () -> Void) {
        guard monitoringSession == nil else { return }

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            logger.error("Failed to create DiskArbitration session")
            return
        }
        monitoringSession = session

        let context = Unmanaged.passRetained(CallbackContext(onChange: onChange))
        let contextPtr = context.toOpaque()

        DARegisterDiskAppearedCallback(
            session, nil, { disk, ctx in
                guard let ctx = ctx else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()
                let name = DADiskGetBSDName(disk).map(String.init(cString:)) ?? "unknown"
                context.log.info("Disk appeared: \(name)")
                DispatchQueue.main.async { context.onChange() }
            }, contextPtr
        )

        DARegisterDiskDisappearedCallback(
            session, nil, { disk, ctx in
                guard let ctx = ctx else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()
                let name = DADiskGetBSDName(disk).map(String.init(cString:)) ?? "unknown"
                context.log.info("Disk disappeared: \(name)")
                DispatchQueue.main.async { context.onChange() }
            }, contextPtr
        )

        DARegisterDiskDescriptionChangedCallback(
            session, nil, nil, { disk, _, ctx in
                guard let ctx = ctx else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()
                let name = DADiskGetBSDName(disk).map(String.init(cString:)) ?? "unknown"
                context.log.info("Disk description changed: \(name)")
                DispatchQueue.main.async { context.onChange() }
            }, contextPtr
        )

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        logger.info("DiskArbitration monitoring started")
    }

    func stopMonitoring() {
        if let session = monitoringSession {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        monitoringSession = nil
        logger.info("DiskArbitration monitoring stopped")
    }


    // MARK: - Drive Discovery (Pure DiskArbitration + IOKit)

    /// Discover all external, user-visible volumes.
    ///
    /// Uses IOKit to iterate all IOMedia nodes, queries DiskArbitration
    /// for each, and filters to external, user-visible volumes. Also
    /// re-checks previously known drives that may have been unmounted
    /// (APFS volumes can disappear from IOKit when unmounted).
    func discoverExternalDrives() -> [ExternalDrive] {
        guard let session = createSession() else { return [] }

        var drives: [ExternalDrive] = []
        var foundIdentifiers: Set<String> = []

        // ── Pass 1: Iterate IOMedia nodes in the I/O Registry ────────
        let matching = IOServiceMatching("IOMedia")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortCompat, matching, &iterator)

        if kr == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }

            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }

                guard let daDisk = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, service) else {
                    continue
                }

                if let drive = extractDriveInfo(from: daDisk, session: session) {
                    drives.append(drive)
                    foundIdentifiers.insert(drive.identifier)
                }
            }
        } else {
            logger.error("IOServiceGetMatchingServices failed: \(kr)")
        }

        // ── Pass 2: Re-check previously known external drives ────────
        // APFS volumes may disappear from IOKit when unmounted but are
        // still accessible by BSD name via DiskArbitration.
        for knownId in knownExternalIdentifiers {
            if foundIdentifiers.contains(knownId) { continue }

            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, knownId) else {
                // Drive has been physically disconnected — remove from known set
                knownExternalIdentifiers.remove(knownId)
                continue
            }

            if let drive = extractDriveInfo(from: disk, session: session) {
                drives.append(drive)
                foundIdentifiers.insert(drive.identifier)
            } else {
                // Disk exists but doesn't pass filters anymore — probably disconnected
                knownExternalIdentifiers.remove(knownId)
            }
        }

        // Update known set with all currently found external drives
        knownExternalIdentifiers.formUnion(foundIdentifiers)

        return drives.sorted { $0.volumeName.lowercased() < $1.volumeName.lowercased() }
    }


    // MARK: - Drive Info Extraction & Filtering

    /// Extract drive information from a DADisk reference, applying all filters.
    /// Returns nil if the disk should not be shown (internal, system, etc.).
    private func extractDriveInfo(from daDisk: DADisk, session: DASession) -> ExternalDrive? {
        guard let descRef = DADiskCopyDescription(daDisk) else {
            return nil
        }
        let desc = descRef as NSDictionary as! [String: Any]

        // ── Filter: external only ────────────────────────────────────
        // Check the device internal flag
        let isInternal = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true
        if isInternal { return nil }

        // ── Filter: check device protocol for extra safety ───────────
        // Internal NVMe/SATA drives sometimes report incorrectly.
        // External drives use USB, Thunderbolt, FireWire, etc.
        let protocol_ = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
        let internalProtocols: Set<String> = ["Apple Fabric", "PCI Express", "PCI", "SATA", "NVMe", "NVM Express"]
        if internalProtocols.contains(protocol_) { return nil }

        // ── Filter: skip network volumes ─────────────────────────────
        let isNetwork = desc[kDADiskDescriptionVolumeNetworkKey as String] as? Bool ?? false
        if isNetwork { return nil }

        // ── Filter: must be a leaf media (actual partition, not whole disk)
        let isLeaf = desc[kDADiskDescriptionMediaLeafKey as String] as? Bool ?? false
        let isWhole = desc[kDADiskDescriptionMediaWholeKey as String] as? Bool ?? false
        if isWhole && !isLeaf { return nil }

        // ── Filter: skip system/infrastructure volumes ───────────────
        let volumeName = desc[kDADiskDescriptionVolumeNameKey as String] as? String ?? ""
        let systemVolumeNames: Set<String> = [
            "EFI", "Recovery", "Preboot", "VM", "Update",
            "Macintosh HD", "Macintosh HD - Data",
            "KernelCoreDump"
        ]
        if systemVolumeNames.contains(volumeName) { return nil }

        // ── Filter: skip system mount points ─────────────────────────
        let mountPointURL = desc[kDADiskDescriptionVolumePathKey as String] as? URL
        if let mountPath = mountPointURL?.path {
            if mountPath == "/" { return nil }
            if mountPath.hasPrefix("/System/Volumes") { return nil }
        }

        // ── Filter: must be mountable (or was mountable — unmounted volumes
        // still qualify if they have a volume name or volume kind) ─────
        let isMountable = desc[kDADiskDescriptionVolumeMountableKey as String] as? Bool ?? false
        let volumeKind = desc[kDADiskDescriptionVolumeKindKey as String] as? String ?? ""
        let hasVolumeInfo = !volumeName.isEmpty || !volumeKind.isEmpty

        if !isMountable && !hasVolumeInfo { return nil }

        // ── Extract volume information ───────────────────────────────
        guard let bsdName = DADiskGetBSDName(daDisk).map(String.init(cString:)) else {
            return nil
        }

        // Extract volume UUID for stable identification across reboots
        var volumeUUID: String?
        if let uuidRef = desc[kDADiskDescriptionVolumeUUIDKey as String] {
            let cfUUID = uuidRef as! CFUUID
            volumeUUID = CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String?
        }
        if volumeUUID == nil {
            logger.warning("No volume UUID for \(bsdName) — config references will use unstable BSD name")
        }

        let isMounted = mountPointURL != nil
        let mountPoint = mountPointURL?.path

        let mediaName = desc[kDADiskDescriptionMediaNameKey as String] as? String ?? ""
        let displayName = volumeName.isEmpty
            ? (mediaName.isEmpty ? bsdName : mediaName)
            : volumeName

        let sizeBytes = desc[kDADiskDescriptionMediaSizeKey as String] as? Int64 ?? 0

        return ExternalDrive(
            identifier: bsdName,
            volumeUUID: volumeUUID,
            volumeName: displayName,
            sizeDescription: formatBytes(sizeBytes),
            sizeBytes: sizeBytes,
            isMounted: isMounted,
            mountPoint: mountPoint,
            deviceNode: "/dev/\(bsdName)"
        )
    }


    // MARK: - Mount (Pure DiskArbitration)

    /// Mount a drive by its BSD identifier using DADiskMount.
    func mount(identifier: String) async -> DiskOperationResult {
        await withCheckedContinuation { continuation in
            guard let session = createSession(),
                  let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, identifier)
            else {
                logger.error("Mount failed: could not create DADisk for \(identifier)")
                continuation.resume(returning: DiskOperationResult(
                    success: false,
                    message: "Could not access disk \(identifier)"
                ))
                return
            }

            // Schedule session on main run loop so the callback fires
            DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

            let ctx = Unmanaged.passRetained(
                OperationContext(continuation: continuation, identifier: identifier, session: session)
            )

            DADiskMount(
                disk,
                nil,    // mount path — nil = default (/Volumes)
                DADiskMountOptions(kDADiskMountOptionDefault),
                { _, dissenter, context in
                    guard let context = context else { return }
                    let opCtx = Unmanaged<OperationContext>.fromOpaque(context).takeRetainedValue()

                    DASessionUnscheduleFromRunLoop(
                        opCtx.session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
                    )

                    if let dissenter = dissenter {
                        let reason = dissenterMessage(dissenter)
                        opCtx.log.warning("Mount \(opCtx.identifier) failed: \(reason)")
                        opCtx.continuation.resume(returning: DiskOperationResult(
                            success: false,
                            message: "Mount failed: \(reason)"
                        ))
                    } else {
                        opCtx.log.info("Mounted \(opCtx.identifier)")
                        opCtx.continuation.resume(returning: DiskOperationResult(
                            success: true,
                            message: "Volume mounted successfully"
                        ))
                    }
                },
                ctx.toOpaque()
            )
        }
    }


    // MARK: - Unmount (Pure DiskArbitration)

    /// Unmount a drive by its BSD identifier using DADiskUnmount.
    func unmount(identifier: String) async -> DiskOperationResult {
        await performUnmount(identifier: identifier, force: false)
    }

    /// Force-unmount a drive (use with caution — can cause data loss if files are open).
    func forceUnmount(identifier: String) async -> DiskOperationResult {
        await performUnmount(identifier: identifier, force: true)
    }

    private func performUnmount(identifier: String, force: Bool) async -> DiskOperationResult {
        await withCheckedContinuation { continuation in
            guard let session = createSession(),
                  let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, identifier)
            else {
                logger.error("Unmount failed: could not create DADisk for \(identifier)")
                continuation.resume(returning: DiskOperationResult(
                    success: false,
                    message: "Could not access disk \(identifier)"
                ))
                return
            }

            DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

            let ctx = Unmanaged.passRetained(
                OperationContext(continuation: continuation, identifier: identifier, session: session, force: force)
            )

            let options = force
                ? DADiskUnmountOptions(kDADiskUnmountOptionForce)
                : DADiskUnmountOptions(kDADiskUnmountOptionDefault)

            DADiskUnmount(
                disk,
                options,
                { _, dissenter, context in
                    guard let context = context else { return }
                    let opCtx = Unmanaged<OperationContext>.fromOpaque(context).takeRetainedValue()

                    DASessionUnscheduleFromRunLoop(
                        opCtx.session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
                    )

                    let verb = opCtx.force ? "Force unmount" : "Unmount"

                    if let dissenter = dissenter {
                        let reason = dissenterMessage(dissenter)
                        opCtx.log.warning("\(verb) \(opCtx.identifier) failed: \(reason)")
                        opCtx.continuation.resume(returning: DiskOperationResult(
                            success: false,
                            message: "\(verb) failed: \(reason)"
                        ))
                    } else {
                        opCtx.log.info("\(verb) succeeded for \(opCtx.identifier)")
                        opCtx.continuation.resume(returning: DiskOperationResult(
                            success: true,
                            message: "Volume \(opCtx.force ? "force " : "")unmounted successfully"
                        ))
                    }
                },
                ctx.toOpaque()
            )
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


    // MARK: - Private Helpers

    private func createSession() -> DASession? {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            logger.error("Failed to create DiskArbitration session")
            return nil
        }
        return session
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}


// MARK: - IOKit Compatibility

#if swift(>=5.9)
private let kIOMainPortCompat: mach_port_t = kIOMainPortDefault
#else
private let kIOMainPortCompat: mach_port_t = kIOMasterPortDefault
#endif


// MARK: - Dissenter Helpers

private func dissenterMessage(_ dissenter: DADissenter) -> String {
    if let statusString = DADissenterGetStatusString(dissenter) {
        return String(describing: statusString)
    }
    return describeDissenterStatus(DADissenterGetStatus(dissenter))
}

private func describeDissenterStatus(_ status: DAReturn) -> String {
    let unsigned = UInt32(bitPattern: status)
    switch unsigned {
    case 0:          return "No error"
    case 0xF8DA0001: return "General error"
    case 0xF8DA0002: return "Volume is busy"
    case 0xF8DA0003: return "Bad argument"
    case 0xF8DA0004: return "Exclusive access denied"
    case 0xF8DA0005: return "Insufficient resources"
    case 0xF8DA0006: return "Volume not found"
    case 0xF8DA0007: return "Volume not mounted"
    case 0xF8DA0008: return "Operation not permitted — check Full Disk Access in System Settings"
    case 0xF8DA0009: return "Insufficient privileges — disable App Sandbox or run with elevated permissions"
    case 0xF8DA000A: return "Disk not ready"
    case 0xF8DA000B: return "Disk is not writable"
    case 0xF8DA000C: return "Unsupported operation"
    default:
        let posixErr = unsigned & 0xFF
        if posixErr == 16 { return "Volume is in use — close open files and try again" }
        if posixErr == 1  { return "Operation not permitted — check Full Disk Access" }
        if posixErr == 13 { return "Permission denied — check Full Disk Access" }
        return "Disk Arbitration error (code \(String(format: "0x%08X", unsigned)))"
    }
}


// MARK: - Supporting Types

struct DiskOperationResult {
    let success: Bool
    let message: String
}

private class CallbackContext {
    let onChange: () -> Void
    let log: Logger
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.log = Logger(subsystem: "com.saddle.app", category: "DiskService")
    }
}

private class OperationContext {
    let continuation: CheckedContinuation<DiskOperationResult, Never>
    let identifier: String
    let session: DASession
    let log: Logger
    let force: Bool

    init(continuation: CheckedContinuation<DiskOperationResult, Never>,
         identifier: String,
         session: DASession,
         force: Bool = false) {
        self.continuation = continuation
        self.identifier = identifier
        self.session = session
        self.log = Logger(subsystem: "com.saddle.app", category: "DiskService")
        self.force = force
    }
}
