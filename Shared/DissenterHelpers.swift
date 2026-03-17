import Foundation
import DiskArbitration

// MARK: - Dissenter Helpers

/// Extract a human-readable message from a DiskArbitration dissenter.
func dissenterMessage(_ dissenter: DADissenter) -> String {
    if let statusString = DADissenterGetStatusString(dissenter) {
        return String(describing: statusString)
    }
    return describeDissenterStatus(DADissenterGetStatus(dissenter))
}

/// Map a DAReturn status code to a descriptive string.
func describeDissenterStatus(_ status: DAReturn) -> String {
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
    case 0xF8DA0009: return "Insufficient privileges"
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
