import AppKit
import Foundation

// MARK: - Antigravity Process Matcher

/// Shared helper to identify running Antigravity / Antigravity IDE processes consistently.
public enum AntigravityProcessMatcher {

    public static func isAntigravityApp(
        _ app: NSRunningApplication,
        bundlePath: String,
        syncIDESession: Bool
    ) -> Bool {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard app.processIdentifier != selfPID else { return false }

        let targetBundlePath = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        if let appBundlePath = app.bundleURL?.standardizedFileURL.path, appBundlePath == targetBundlePath {
            return true
        }
        if syncIDESession,
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

    public static func matchingRunningApps(
        bundlePath: String,
        syncIDESession: Bool
    ) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            isAntigravityApp(app, bundlePath: bundlePath, syncIDESession: syncIDESession)
        }
    }

    public static func isAnyAntigravityRunning(
        bundlePath: String,
        syncIDESession: Bool
    ) -> Bool {
        !matchingRunningApps(bundlePath: bundlePath, syncIDESession: syncIDESession).isEmpty
    }
}
