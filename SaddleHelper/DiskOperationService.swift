import Foundation
import DiskArbitration
import IOKit
import IOKit.storage
import os.log

private let logger = Logger(subsystem: "com.saddle.helper", category: "DiskOperationService")

// MARK: - IOKit Compatibility

#if swift(>=5.9)
private let kIOMainPortCompat: mach_port_t = kIOMainPortDefault
#else
private let kIOMainPortCompat: mach_port_t = kIOMasterPortDefault
#endif


// MARK: - Disk Operation Service

/// Implements the XPC protocol. Performs all DiskArbitration and IOKit
/// operations on behalf of the sandboxed main app.
final class DiskOperationService: NSObject, SaddleXPCProtocol {

    /// The XPC connection back to the main app, used for push notifications.
    weak var clientConnection: NSXPCConnection?

    /// A long-lived DA session for monitoring callbacks.
    private var monitoringSession: DASession?

    /// BSD identifiers of drives we've previously seen as external.
    /// Used to re-discover unmounted APFS volumes that may vanish from IOKit.
    private var knownExternalIdentifiers: Set<String> = []


    // MARK: - Discovery

    func discoverExternalDrives(withReply reply: @escaping ([[String: String]]) -> Void) {
        guard let session = createSession() else {
            reply([])
            return
        }

        var drives: [[String: String]] = []
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

                if let info = extractDriveInfo(from: daDisk, session: session) {
                    drives.append(info.dictionary)
                    foundIdentifiers.insert(info.identifier)
                }
            }
        } else {
            logger.error("IOServiceGetMatchingServices failed: \(kr)")
        }

        // ── Pass 2: Re-check previously known external drives ────────
        for knownId in knownExternalIdentifiers {
            if foundIdentifiers.contains(knownId) { continue }

            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, knownId) else {
                knownExternalIdentifiers.remove(knownId)
                continue
            }

            if let info = extractDriveInfo(from: disk, session: session) {
                drives.append(info.dictionary)
                foundIdentifiers.insert(info.identifier)
            } else {
                knownExternalIdentifiers.remove(knownId)
            }
        }

        knownExternalIdentifiers.formUnion(foundIdentifiers)

        // Sort by volume name
        let sorted = drives.sorted {
            ($0["volumeName"] ?? "").lowercased() < ($1["volumeName"] ?? "").lowercased()
        }

        reply(sorted)
    }


    // MARK: - Mount

    func mount(bsdName: String, withReply reply: @escaping (Bool, String) -> Void) {
        guard let session = createSession(),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName)
        else {
            logger.error("Mount failed: could not create DADisk for \(bsdName)")
            reply(false, "Could not access disk \(bsdName)")
            return
        }

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let ctx = Unmanaged.passRetained(
            OperationContext(identifier: bsdName, session: session, reply: reply)
        )

        DADiskMount(
            disk,
            nil,
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
                    opCtx.reply(false, "Mount failed: \(reason)")
                } else {
                    opCtx.log.info("Mounted \(opCtx.identifier)")
                    opCtx.reply(true, "Volume mounted successfully")
                }
            },
            ctx.toOpaque()
        )
    }


    // MARK: - Unmount

    func unmount(bsdName: String, force: Bool, withReply reply: @escaping (Bool, String) -> Void) {
        guard let session = createSession(),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName)
        else {
            logger.error("Unmount failed: could not create DADisk for \(bsdName)")
            reply(false, "Could not access disk \(bsdName)")
            return
        }

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let ctx = Unmanaged.passRetained(
            OperationContext(identifier: bsdName, session: session, reply: reply, force: force)
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
                    opCtx.reply(false, "\(verb) failed: \(reason)")
                } else {
                    opCtx.log.info("\(verb) succeeded for \(opCtx.identifier)")
                    opCtx.reply(true, "Volume \(opCtx.force ? "force " : "")unmounted successfully")
                }
            },
            ctx.toOpaque()
        )
    }


    // MARK: - Monitoring

    func startMonitoring() {
        guard monitoringSession == nil else { return }

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            logger.error("Failed to create DA monitoring session")
            return
        }
        monitoringSession = session

        let context = Unmanaged.passRetained(MonitoringContext(service: self))
        let contextPtr = context.toOpaque()

        DARegisterDiskAppearedCallback(
            session, nil, { disk, ctx in
                guard let ctx = ctx else { return }
                let mc = Unmanaged<MonitoringContext>.fromOpaque(ctx).takeUnretainedValue()
                let name = DADiskGetBSDName(disk).map(String.init(cString:)) ?? "unknown"
                mc.log.info("Disk appeared: \(name)")
                mc.notifyClient()
            }, contextPtr
        )

        DARegisterDiskDisappearedCallback(
            session, nil, { disk, ctx in
                guard let ctx = ctx else { return }
                let mc = Unmanaged<MonitoringContext>.fromOpaque(ctx).takeUnretainedValue()
                let name = DADiskGetBSDName(disk).map(String.init(cString:)) ?? "unknown"
                mc.log.info("Disk disappeared: \(name)")
                mc.notifyClient()
            }, contextPtr
        )

        DARegisterDiskDescriptionChangedCallback(
            session, nil, nil, { disk, _, ctx in
                guard let ctx = ctx else { return }
                let mc = Unmanaged<MonitoringContext>.fromOpaque(ctx).takeUnretainedValue()
                let name = DADiskGetBSDName(disk).map(String.init(cString:)) ?? "unknown"
                mc.log.info("Disk description changed: \(name)")
                mc.notifyClient()
            }, contextPtr
        )

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        logger.info("DA monitoring started")
    }

    func stopMonitoring() {
        if let session = monitoringSession {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        monitoringSession = nil
        logger.info("DA monitoring stopped")
    }

    /// Push a drivesDidChange notification to the connected app.
    fileprivate func notifyClient() {
        guard let connection = clientConnection else { return }
        let client = connection.remoteObjectProxyWithErrorHandler { error in
            logger.warning("Failed to notify client: \(error.localizedDescription)")
        } as? SaddleXPCClientProtocol

        client?.drivesDidChange()
    }


    // MARK: - Drive Info Extraction & Filtering

    private struct DriveInfo {
        let identifier: String
        let dictionary: [String: String]
    }

    private func extractDriveInfo(from daDisk: DADisk, session: DASession) -> DriveInfo? {
        guard let descRef = DADiskCopyDescription(daDisk) else {
            return nil
        }
        let desc = descRef as NSDictionary as! [String: Any]

        // ── Filter: external only ────────────────────────────────────
        let isInternal = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true
        if isInternal { return nil }

        // ── Filter: device protocol ──────────────────────────────────
        let protocol_ = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
        let internalProtocols: Set<String> = ["Apple Fabric", "PCI Express", "PCI", "SATA", "NVMe", "NVM Express"]
        if internalProtocols.contains(protocol_) { return nil }

        // ── Filter: skip network volumes ─────────────────────────────
        let isNetwork = desc[kDADiskDescriptionVolumeNetworkKey as String] as? Bool ?? false
        if isNetwork { return nil }

        // ── Filter: must be a leaf media ─────────────────────────────
        let isLeaf = desc[kDADiskDescriptionMediaLeafKey as String] as? Bool ?? false
        let isWhole = desc[kDADiskDescriptionMediaWholeKey as String] as? Bool ?? false
        if isWhole && !isLeaf { return nil }

        // ── Filter: skip system volumes ──────────────────────────────
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

        // ── Filter: must be mountable ────────────────────────────────
        let isMountable = desc[kDADiskDescriptionVolumeMountableKey as String] as? Bool ?? false
        let volumeKind = desc[kDADiskDescriptionVolumeKindKey as String] as? String ?? ""
        let hasVolumeInfo = !volumeName.isEmpty || !volumeKind.isEmpty
        if !isMountable && !hasVolumeInfo { return nil }

        // ── Extract volume information ───────────────────────────────
        guard let bsdName = DADiskGetBSDName(daDisk).map(String.init(cString:)) else {
            return nil
        }

        var volumeUUID: String?
        if let uuidRef = desc[kDADiskDescriptionVolumeUUIDKey as String] {
            let cfUUID = uuidRef as! CFUUID
            volumeUUID = CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String?
        }

        let isMounted = mountPointURL != nil
        let mountPoint = mountPointURL?.path

        let mediaName = desc[kDADiskDescriptionMediaNameKey as String] as? String ?? ""
        let displayName = volumeName.isEmpty
            ? (mediaName.isEmpty ? bsdName : mediaName)
            : volumeName

        let sizeBytes = desc[kDADiskDescriptionMediaSizeKey as String] as? Int64 ?? 0

        let dict: [String: String] = [
            "identifier": bsdName,
            "volumeUUID": volumeUUID ?? "",
            "volumeName": displayName,
            "sizeDescription": formatBytes(sizeBytes),
            "sizeBytes": String(sizeBytes),
            "isMounted": isMounted ? "true" : "false",
            "mountPoint": mountPoint ?? "",
            "deviceNode": "/dev/\(bsdName)"
        ]

        return DriveInfo(identifier: bsdName, dictionary: dict)
    }


    // MARK: - Helpers

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


// MARK: - Supporting Types

private class OperationContext {
    let identifier: String
    let session: DASession
    let reply: (Bool, String) -> Void
    let log: Logger
    let force: Bool

    init(identifier: String, session: DASession, reply: @escaping (Bool, String) -> Void, force: Bool = false) {
        self.identifier = identifier
        self.session = session
        self.reply = reply
        self.log = Logger(subsystem: "com.saddle.helper", category: "DiskOperationService")
        self.force = force
    }
}

private class MonitoringContext {
    weak var service: DiskOperationService?
    let log: Logger

    init(service: DiskOperationService) {
        self.service = service
        self.log = Logger(subsystem: "com.saddle.helper", category: "DiskOperationService")
    }

    func notifyClient() {
        DispatchQueue.main.async { [weak self] in
            self?.service?.notifyClient()
        }
    }
}
