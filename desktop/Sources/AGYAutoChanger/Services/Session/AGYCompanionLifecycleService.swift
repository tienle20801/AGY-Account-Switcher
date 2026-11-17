import AppKit
import Foundation

// MARK: - Companion Lifecycle Service

/// Binds `AGY Account Switcher` lifecycle to Antigravity:
/// 1) Registers a lightweight `AGYWatcher` LaunchAgent so launching Antigravity opens `AGY Account Switcher`.
/// 2) Terminates `AGY Account Switcher` when Antigravity exits externally (ignoring managed account switches).
@MainActor
public final class AGYCompanionLifecycleService {

    public typealias SettingsProvider = () -> SwitcherSettings
    public typealias ManagedRestartChecker = () -> Bool
    public typealias AGYRunningChecker = (_ bundlePath: String, _ syncIDESession: Bool) -> Bool
    public typealias TerminateHandler = @MainActor () -> Void

    private let settingsProvider: SettingsProvider
    private let isManagedRestartInProgress: ManagedRestartChecker
    private let isAGYRunning: AGYRunningChecker
    private let graceDelayNanoseconds: UInt64
    private let onShouldTerminate: TerminateHandler

    private var terminateObserver: NSObjectProtocol?
    private var pendingTerminateTask: Task<Void, Never>?

    public init(
        settingsProvider: @escaping SettingsProvider,
        isManagedRestartInProgress: @escaping ManagedRestartChecker,
        isAGYRunning: @escaping AGYRunningChecker = { bundlePath, syncIDESession in
            AntigravityProcessMatcher.isAnyAntigravityRunning(bundlePath: bundlePath, syncIDESession: syncIDESession)
        },
        graceDelayNanoseconds: UInt64 = AppConfig.agyTerminateGraceDelayNanoseconds,
        onShouldTerminate: @escaping TerminateHandler = {
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    ) {
        self.settingsProvider = settingsProvider
        self.isManagedRestartInProgress = isManagedRestartInProgress
        self.isAGYRunning = isAGYRunning
        self.graceDelayNanoseconds = graceDelayNanoseconds
        self.onShouldTerminate = onShouldTerminate
    }

    deinit {
        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
        }
    }

    // MARK: - Workspace Observation

    public func startObserving() {
        guard terminateObserver == nil else { return }

        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let bundlePath = app.bundleURL?.standardizedFileURL.path
            let localizedName = app.localizedName
            Task { @MainActor [weak self] in
                self?.handleDidTerminateApplication(bundlePath: bundlePath, localizedName: localizedName)
            }
        }
    }

    public func stopObserving() {
        pendingTerminateTask?.cancel()
        pendingTerminateTask = nil
        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
    }

    public func handleDidTerminateApplication(bundlePath: String?, localizedName: String?) {
        let settings = settingsProvider()
        guard settings.bindLifecycleWithAGY else { return }
        guard !isManagedRestartInProgress() else { return }

        let targetPath = URL(fileURLWithPath: settings.agyAppBundlePath).standardizedFileURL.path
        let matchesBundle = (bundlePath == targetPath)
        let matchesMainName = localizedName?.caseInsensitiveCompare("Antigravity") == .orderedSame
        let matchesIDEName = settings.syncIDESession
            && localizedName?.caseInsensitiveCompare("Antigravity IDE") == .orderedSame

        guard matchesBundle || matchesMainName || matchesIDEName else { return }

        scheduleGracefulTerminationCheck()
    }

    /// Exposed for deterministic unit testing of the grace-period and managed-restart guard.
    public func scheduleGracefulTerminationCheck() {
        pendingTerminateTask?.cancel()
        pendingTerminateTask = Task { [weak self] in
            guard let self else { return }
            if self.graceDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: self.graceDelayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            let latestSettings = self.settingsProvider()
            guard latestSettings.bindLifecycleWithAGY else { return }
            guard !self.isManagedRestartInProgress() else { return }
            guard !self.isAGYRunning(latestSettings.agyAppBundlePath, latestSettings.syncIDESession) else { return }

            self.onShouldTerminate()
        }
    }

    // MARK: - LaunchAgent Watcher Registration

    /// Installs or removes `~/Library/LaunchAgents/com.agy.autochanger.watcher.plist`
    /// when running from a packaged `.app` bundle that embeds `Contents/Helpers/AGYWatcher`.
    public func syncWatcherRegistration(
        enabled: Bool,
        appBundleURL: URL = Bundle.main.bundleURL
    ) {
        let standardizedAppURL = appBundleURL.standardizedFileURL
        guard standardizedAppURL.pathExtension == "app" else { return }

        let watcherURL = standardizedAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(AppConfig.watcherExecutableName, isDirectory: false)

        guard FileManager.default.isExecutableFile(atPath: watcherURL.path) else { return }

        let plistURL = AppConfig.watcherLaunchAgentPlistURL
        let guiDomain = "gui/\(getuid())"
        let serviceTarget = "\(guiDomain)/\(AppConfig.watcherLaunchAgentLabel)"

        if !enabled {
            _ = runLaunchctl(["bootout", serviceTarget])
            try? FileManager.default.removeItem(at: plistURL)
            return
        }

        let desiredArguments = [
            watcherURL.path,
            "--app-bundle",
            standardizedAppURL.path
        ]

        let plistObject: [String: Any] = [
            "Label": AppConfig.watcherLaunchAgentLabel,
            "ProgramArguments": desiredArguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background"
        ]

        let existingMatches = existingPlist(at: plistURL, matchesArguments: desiredArguments)
        if existingMatches {
            // Ensure it is actually loaded in the current GUI launchd domain.
            if runLaunchctl(["print", serviceTarget]) != 0 {
                _ = runLaunchctl(["bootstrap", guiDomain, plistURL.path])
            }
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: plistObject,
                format: .xml,
                options: 0
            )
            _ = runLaunchctl(["bootout", serviceTarget])
            try data.write(to: plistURL, options: .atomic)
            _ = runLaunchctl(["bootstrap", guiDomain, plistURL.path])
        } catch {
            // Non-fatal: app still functions even if LaunchAgent registration is blocked by policy.
        }
    }

    private func existingPlist(at url: URL, matchesArguments expected: [String]) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else {
            return false
        }
        return args == expected
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
