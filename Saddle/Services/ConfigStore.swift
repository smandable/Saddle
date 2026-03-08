import SwiftUI
import Combine
import ServiceManagement
import os.log

private let logger = Logger(subsystem: "com.saddle.app", category: "ConfigStore")

// MARK: - Config Store

/// Manages persistent configuration for Saddle.
/// Stores data as JSON in the app's Application Support directory.
@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: AppConfig {
        didSet { save() }
    }

    private let configURL: URL

    init() {
        // Resolve config file path
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configDir = appSupport.appendingPathComponent("Saddle", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        self.configURL = configDir.appendingPathComponent("config.json")
        self.config = AppConfig.default

        // Load saved config
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            logger.info("No config file found, using defaults")
            return
        }

        do {
            let data = try Data(contentsOf: configURL)
            config = try JSONDecoder().decode(AppConfig.self, from: data)
            logger.info("Config loaded: \(self.config.groups.count) group(s)")
        } catch {
            logger.error("Failed to load config: \(error.localizedDescription)")
            config = AppConfig.default
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(config)
            // Pretty-print for human readability
            if let json = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
                try pretty.write(to: configURL, options: .atomic)
            } else {
                try data.write(to: configURL, options: .atomic)
            }
            logger.info("Config saved")
        } catch {
            logger.error("Failed to save config: \(error.localizedDescription)")
        }
    }

    // MARK: - Convenience Mutators

    var excludedSet: Set<String> {
        Set(config.excludedIdentifiers)
    }

    func isExcluded(_ identifier: String) -> Bool {
        config.excludedIdentifiers.contains(identifier)
    }

    func exclude(_ identifier: String) {
        if !config.excludedIdentifiers.contains(identifier) {
            config.excludedIdentifiers.append(identifier)
        }
    }

    func include(_ identifier: String) {
        config.excludedIdentifiers.removeAll { $0 == identifier }
    }

    func alias(for identifier: String) -> String? {
        config.driveAliases[identifier]
    }

    func setAlias(_ alias: String, for identifier: String) {
        config.driveAliases[identifier] = alias.isEmpty ? nil : alias
    }

    func groupForDrive(_ identifier: String) -> DriveGroup? {
        config.groups.first { $0.driveIdentifiers.contains(identifier) }
    }

    func addGroup(_ group: DriveGroup) {
        config.groups.append(group)
    }

    func removeGroup(named name: String) {
        config.groups.removeAll { $0.name == name }
    }

    func updateGroup(_ group: DriveGroup) {
        if let idx = config.groups.firstIndex(where: { $0.name == group.name }) {
            config.groups[idx] = group
        }
    }

    func addDriveToGroup(_ driveId: String, groupName: String) {
        // Remove from any existing group first
        for i in config.groups.indices {
            config.groups[i].driveIdentifiers.removeAll { $0 == driveId }
        }
        // Add to target group
        if let idx = config.groups.firstIndex(where: { $0.name == groupName }) {
            config.groups[idx].driveIdentifiers.append(driveId)
        }
    }

    func removeDriveFromGroup(_ driveId: String, groupName: String) {
        if let idx = config.groups.firstIndex(where: { $0.name == groupName }) {
            config.groups[idx].driveIdentifiers.removeAll { $0 == driveId }
        }
    }

    // MARK: - Login Item

    func setLaunchAtLogin(_ enabled: Bool) {
        config.launchAtLogin = enabled
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.info("Registered as login item")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Unregistered as login item")
            }
        } catch {
            logger.error("Failed to update login item: \(error.localizedDescription)")
        }
    }

    // MARK: - Config File Access

    /// Open the config directory in Finder.
    func revealConfigInFinder() {
        NSWorkspace.shared.selectFile(configURL.path, inFileViewerRootedAtPath: configURL.deletingLastPathComponent().path)
    }
}
