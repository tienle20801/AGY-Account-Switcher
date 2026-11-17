import AppKit
import Foundation

// MARK: - Lightweight Antigravity Launch Watcher

private struct WatcherSettings: Decodable {
    var agyAppBundlePath: String = "/Applications/Antigravity.app"
    var syncIDESession: Bool = false
    var bindLifecycleWithAGY: Bool = true

    enum CodingKeys: String, CodingKey {
        case agyAppBundlePath
        case syncIDESession
        case bindLifecycleWithAGY
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agyAppBundlePath = try container.decodeIfPresent(String.self, forKey: .agyAppBundlePath) ?? "/Applications/Antigravity.app"
        syncIDESession = try container.decodeIfPresent(Bool.self, forKey: .syncIDESession) ?? false
        bindLifecycleWithAGY = try container.decodeIfPresent(Bool.self, forKey: .bindLifecycleWithAGY) ?? true
    }
}

private final class AGYLaunchWatcher {
    private let configuredAppBundlePath: String?
    private let autoChangerBundleID = "com.agy.autochanger"
    private let settingsURL: URL
    private var launchObserver: NSObjectProtocol?

    init(configuredAppBundlePath: String?) {
        self.configuredAppBundlePath = configuredAppBundlePath
        self.settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agy-switcher", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    func start() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let launchedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let settings = self.loadSettings()
            guard settings.bindLifecycleWithAGY,
                  self.isAntigravityApp(launchedApp, settings: settings) else {
                return
            }
            self.launchAutoChangerIfNeeded()
        }

        // Handle case where Antigravity was already running before the watcher started.
        let settings = loadSettings()
        if settings.bindLifecycleWithAGY,
           NSWorkspace.shared.runningApplications.contains(where: { isAntigravityApp($0, settings: settings) }) {
            launchAutoChangerIfNeeded()
        }
    }

    private func loadSettings() -> WatcherSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? JSONDecoder().decode(WatcherSettings.self, from: data) else {
            return WatcherSettings()
        }
        return decoded
    }

    private func isAntigravityApp(_ app: NSRunningApplication, settings: WatcherSettings) -> Bool {
        let targetPath = URL(fileURLWithPath: settings.agyAppBundlePath).standardizedFileURL.path
        if let bundlePath = app.bundleURL?.standardizedFileURL.path, bundlePath == targetPath {
            return true
        }
        if settings.syncIDESession,
           let name = app.localizedName,
           name.caseInsensitiveCompare("Antigravity IDE") == .orderedSame {
            return true
        }
        if let name = app.localizedName,
           name.caseInsensitiveCompare("Antigravity") == .orderedSame {
            return true
        }
        return false
    }

    private func isAutoChangerRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == autoChangerBundleID
        }
    }

    private func resolveAutoChangerAppURL() -> URL? {
        var candidates: [String] = []
        if let configuredAppBundlePath {
            candidates.append(configuredAppBundlePath)
        }
        candidates.append("/Applications/AGY Account Switcher.app")

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func launchAutoChangerIfNeeded() {
        guard !isAutoChangerRunning(), let appURL = resolveAutoChangerAppURL() else {
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
    }
}

private func parseAppBundleArg() -> String? {
    let args = CommandLine.arguments
    guard let flagIndex = args.firstIndex(of: "--app-bundle"),
          args.index(after: flagIndex) < args.endIndex else {
        return nil
    }
    return args[args.index(after: flagIndex)]
}

private let watcher = AGYLaunchWatcher(configuredAppBundlePath: parseAppBundleArg())
watcher.start()
RunLoop.main.run()
