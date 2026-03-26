import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.saddle.app", category: "UpdateService")

/// Checks for new versions by querying the GitHub Releases API.
final class UpdateService {
    static let shared = UpdateService()

    private let repoURL = "https://api.github.com/repos/smandable/Saddle/releases/latest"
    private let downloadURL = "https://github.com/smandable/Saddle/releases/latest"

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Check for updates. If `silent`, only shows an alert when an update is found.
    func checkForUpdates(silent: Bool = false) {
        guard let url = URL(string: repoURL) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                logger.error("Update check failed: \(error.localizedDescription)")
                if !silent {
                    DispatchQueue.main.async { self.showError() }
                }
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                logger.error("Update check: failed to parse response")
                if !silent {
                    DispatchQueue.main.async { self.showError() }
                }
                return
            }

            let latestVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            logger.info("Update check: current=\(self.currentVersion) latest=\(latestVersion)")

            DispatchQueue.main.async {
                if self.isNewer(latestVersion, than: self.currentVersion) {
                    self.showUpdateAvailable(version: latestVersion)
                } else if !silent {
                    self.showUpToDate()
                }
            }
        }.resume()
    }

    // MARK: - Version Comparison

    private func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    // MARK: - Alerts

    private func showUpdateAvailable(version: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Saddle \(version) is available. You're running \(currentVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: downloadURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "Saddle \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError() {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = "Couldn't reach GitHub to check for updates. Try again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
