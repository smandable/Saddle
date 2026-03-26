import Foundation

// MARK: - External Drive

/// Represents a single mountable volume on an external disk.
struct ExternalDrive: Identifiable, Hashable, Codable {
    /// BSD identifier, e.g. "disk4s1" — used for DiskArbitration operations
    let identifier: String
    /// Volume UUID from DiskArbitration, stable across reboots/reconnections
    let volumeUUID: String?
    /// Volume name from the filesystem
    let volumeName: String
    /// Human-readable size string
    let sizeDescription: String
    /// Size in bytes (for sorting)
    let sizeBytes: Int64
    /// Whether the volume is currently mounted
    var isMounted: Bool
    /// Current mount point, if mounted
    var mountPoint: String?
    /// The BSD device node, e.g. "/dev/disk4s1"
    let deviceNode: String

    /// Stable identifier for config persistence. Uses volumeUUID when available,
    /// falls back to BSD identifier for drives without a UUID.
    var persistentId: String { volumeUUID ?? identifier }

    var id: String { persistentId }

    /// Display name: alias if configured, otherwise volume name, otherwise identifier.
    func displayName(aliases: [String: String]) -> String {
        if let alias = aliases[persistentId], !alias.isEmpty {
            return alias
        }
        return volumeName.isEmpty ? identifier : volumeName
    }
}


// MARK: - Drive Group

/// A named collection of drives with a launch action.
struct DriveGroup: Identifiable, Codable, Hashable {
    var id: String { name }
    var name: String
    var action: LaunchAction
    var driveIdentifiers: [String]

    enum LaunchAction: String, Codable, CaseIterable, Identifiable {
        case mount
        case unmount
        case none

        var id: String { rawValue }

        var label: String {
            switch self {
            case .mount:   return "Auto-mount at launch"
            case .unmount: return "Auto-unmount at launch"
            case .none:    return "No launch action"
            }
        }

        var icon: String {
            switch self {
            case .mount:   return "circle.fill"       // green
            case .unmount: return "circle.fill"       // red
            case .none:    return "circle"             // gray
            }
        }

        var iconColor: String {
            switch self {
            case .mount:   return "green"
            case .unmount: return "red"
            case .none:    return "gray"
            }
        }
    }
}


// MARK: - App Configuration

/// The complete persisted configuration for Saddle.
/// Uses a custom Decodable init so that new fields with defaults
/// can be added without breaking existing config files.
struct AppConfig: Codable {
    var version: Int = 2
    var autoActionsOnLaunch: Bool = true
    var autoActionsOnWake: Bool = false
    var mountAllOnLaunch: Bool = false
    var unmountAllOnLaunch: Bool = false
    var mountAllOnWake: Bool = false
    var unmountAllOnWake: Bool = false
    var refreshIntervalSeconds: Int = 15
    var groups: [DriveGroup] = []
    var excludedIdentifiers: [String] = []
    var driveAliases: [String: String] = [:]
    var launchAtLogin: Bool = false
    var useForceUnmount: Bool = false
    var checkForUpdatesAutomatically: Bool = false

    static let `default` = AppConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        autoActionsOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoActionsOnLaunch) ?? true
        autoActionsOnWake = try c.decodeIfPresent(Bool.self, forKey: .autoActionsOnWake) ?? false
        mountAllOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .mountAllOnLaunch) ?? false
        unmountAllOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .unmountAllOnLaunch) ?? false
        mountAllOnWake = try c.decodeIfPresent(Bool.self, forKey: .mountAllOnWake) ?? false
        unmountAllOnWake = try c.decodeIfPresent(Bool.self, forKey: .unmountAllOnWake) ?? false
        refreshIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? 15
        groups = try c.decodeIfPresent([DriveGroup].self, forKey: .groups) ?? []
        excludedIdentifiers = try c.decodeIfPresent([String].self, forKey: .excludedIdentifiers) ?? []
        driveAliases = try c.decodeIfPresent([String: String].self, forKey: .driveAliases) ?? [:]
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        useForceUnmount = try c.decodeIfPresent(Bool.self, forKey: .useForceUnmount) ?? false
        checkForUpdatesAutomatically = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdatesAutomatically) ?? false
    }
}
