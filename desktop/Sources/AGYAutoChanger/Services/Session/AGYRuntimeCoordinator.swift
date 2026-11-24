import AppKit
import Darwin
import Foundation

// MARK: - IDE Version & Shared Credential Detection

public struct IDEInstallationInfo: Sendable, Equatable {
    public let bundlePath: String
    public let ideVersion: String?
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Antigravity IDE 2.6.0+ shares credentials with Antigravity.app and `agy` CLI.
    public var usesSharedAppCredentials: Bool {
        guard ideVersion != nil else { return false }
        return (major > 2) || (major == 2 && minor >= 6)
    }

    public init(bundlePath: String, ideVersion: String?, major: Int = 0, minor: Int = 0, patch: Int = 0) {
        self.bundlePath = bundlePath
        self.ideVersion = ideVersion
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

// MARK: - Standalone `agy --hub` Process Snapshot

public struct StandaloneHubProcess: Sendable, Equatable {
    public let pid: Int32
    public let executablePath: String
    public let arguments: [String]

    public init(pid: Int32, executablePath: String, arguments: [String]) {
        self.pid = pid
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

// MARK: - Live Agent Activity State

public enum AGYActivityState: Sendable, Equatable {
    case idle
    case busy(reason: String)

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

// MARK: - AGY Runtime Coordinator

/// Handles Antigravity IDE 2.6+ version detection, standalone `agy --hub` shutdown/relaunch,
/// CLI directory discovery, and strictly read-only live task/idle inspection on macOS.
public final class AGYRuntimeCoordinator: Sendable {

    private struct IDEProductManifest: Decodable {
        let ideVersion: String?
        let version: String?
    }

    private struct TranscriptTailStep: Decodable {
        let type: String?
        let status: String?
        let tool_calls: [AnyCodableStub]?
    }

    private struct AnyCodableStub: Decodable {}

    public init() {}

    // MARK: - CLI Initialization Check

    public func isCLIDirectoryInitialized(cliDir: URL = AppConfig.agyCLIDir) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: cliDir.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - IDE 2.6+ Version Detection

    public func detectIDEInstallation(
        bundlePath: String = AppConfig.defaultIDEAppBundlePath
    ) -> IDEInstallationInfo? {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return nil
        }

        let productURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("product.json", isDirectory: false)

        guard let data = try? Data(contentsOf: productURL),
              let manifest = try? JSONDecoder().decode(IDEProductManifest.self, from: data) else {
            return IDEInstallationInfo(bundlePath: bundlePath, ideVersion: nil)
        }

        let rawVersion = manifest.ideVersion ?? manifest.version
        let parsed = Self.parseSemver(rawVersion)
        return IDEInstallationInfo(
            bundlePath: bundlePath,
            ideVersion: rawVersion,
            major: parsed.major,
            minor: parsed.minor,
            patch: parsed.patch
        )
    }

    public static func parseSemver(_ raw: String?) -> (major: Int, minor: Int, patch: Int) {
        guard let raw else { return (0, 0, 0) }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-").first.map(String.init) ?? ""
        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        let major = parts.indices.contains(0) ? parts[0] : 0
        let minor = parts.indices.contains(1) ? parts[1] : 0
        let patch = parts.indices.contains(2) ? parts[2] : 0
        return (major, minor, patch)
    }

    // MARK: - Standalone `agy --hub` Process Discovery & Lifecycle

    public func captureRunningProcessTable() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-eo", "pid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// Parses `ps -ww -eo pid=,args=` output for standalone `agy --hub` processes targeting `--app_data_dir antigravity`.
    public func parseStandaloneHubProcesses(from psOutput: String) -> [StandaloneHubProcess] {
        var results: [StandaloneHubProcess] = []
        let selfPID = ProcessInfo.processInfo.processIdentifier

        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2,
                  let pid = Int32(parts[0]),
                  pid != selfPID else {
                continue
            }

            let commandLine = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let tokens = Self.splitCommandLineTokens(commandLine)
            guard let executable = tokens.first else { continue }
            let exeName = URL(fileURLWithPath: executable).lastPathComponent.lowercased()

            // Exclude Antigravity.app's bundled language_server (managed by the App itself)
            guard exeName == "agy" else { continue }

            let args = Array(tokens.dropFirst())
            let hasHubFlag = args.contains("--hub") || args.contains("--subclient_type=hub")
                || (args.firstIndex(of: "--subclient_type").map { args.indices.contains($0 + 1) && args[$0 + 1] == "hub" } ?? false)
            guard hasHubFlag else { continue }

            let targetsAntigravityDataDir: Bool
            if let dirFlagIdx = args.firstIndex(of: "--app_data_dir"), args.indices.contains(dirFlagIdx + 1) {
                targetsAntigravityDataDir = (args[dirFlagIdx + 1].lowercased() == "antigravity")
            } else if let eqFlag = args.first(where: { $0.hasPrefix("--app_data_dir=") }) {
                targetsAntigravityDataDir = eqFlag.dropFirst("--app_data_dir=".count).lowercased() == "antigravity"
            } else {
                // Default app_data_dir for `agy --hub` is antigravity
                targetsAntigravityDataDir = true
            }

            if targetsAntigravityDataDir {
                results.append(StandaloneHubProcess(pid: pid, executablePath: executable, arguments: args))
            }
        }
        return results
    }

    public func stopStandaloneHubProcesses(_ hubs: [StandaloneHubProcess]) async {
        guard !hubs.isEmpty else { return }

        for hub in hubs {
            _ = Darwin.kill(hub.pid, SIGTERM)
        }

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            let anyAlive = hubs.contains { Darwin.kill($0.pid, 0) == 0 }
            if !anyAlive {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        for hub in hubs where Darwin.kill(hub.pid, 0) == 0 {
            _ = Darwin.kill(hub.pid, SIGKILL)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    public func relaunchStandaloneHubProcesses(_ hubs: [StandaloneHubProcess]) {
        for hub in hubs {
            guard FileManager.default.isExecutableFile(atPath: hub.executablePath) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: hub.executablePath)
            process.arguments = hub.arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }

    // MARK: - Strictly Read-Only Activity / Idle Detection

    public func inspectActivityState(
        conversationsDir: URL = AppConfig.agyConversationsDir,
        brainDir: URL = AppConfig.agyBrainDir,
        psOutput: String? = nil,
        idleQuietWindowSeconds: TimeInterval = AppConfig.autoSwitchIdleQuietWindowSeconds,
        referenceDate: Date = Date()
    ) -> AGYActivityState {
        let processTable = psOutput ?? captureRunningProcessTable()
        if let activeCLITask = detectActiveCLITask(in: processTable) {
            return .busy(reason: activeCLITask)
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: conversationsDir.path),
           let files = try? fm.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
           ) {
            for fileURL in files where fileURL.lastPathComponent.hasSuffix(".db-wal") {
                if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                   let modDate = attrs[.modificationDate] as? Date,
                   let size = (attrs[.size] as? NSNumber)?.int64Value,
                   size > 0,
                   referenceDate.timeIntervalSince(modDate) >= 0,
                   referenceDate.timeIntervalSince(modDate) < idleQuietWindowSeconds {
                    return .busy(reason: "Đang ghi hội thoại Antigravity")
                }
            }
        }

        if fm.fileExists(atPath: brainDir.path),
           let convDirs = try? fm.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
           ) {
            for dir in convDirs {
                let logURL = dir
                    .appendingPathComponent(".system_generated", isDirectory: true)
                    .appendingPathComponent("logs", isDirectory: true)
                    .appendingPathComponent("transcript.jsonl", isDirectory: false)
                guard fm.fileExists(atPath: logURL.path),
                      let attrs = try? fm.attributesOfItem(atPath: logURL.path),
                      let modDate = attrs[.modificationDate] as? Date else {
                    continue
                }
                let age = referenceDate.timeIntervalSince(modDate)
                guard age >= 0, age < 120 else { continue }

                if age < idleQuietWindowSeconds {
                    return .busy(reason: "Agent đang phản hồi trong hội thoại")
                }
                if isTranscriptTailInFlight(at: logURL) {
                    return .busy(reason: "Tác vụ Agent chưa hoàn tất lượt hiện tại")
                }
            }
        }

        return .idle
    }

    // MARK: - Private Helpers

    private func detectActiveCLITask(in psOutput: String) -> String? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2,
                  let pid = Int32(parts[0]),
                  pid != selfPID else {
                continue
            }
            let commandLine = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let tokens = Self.splitCommandLineTokens(commandLine)
            guard let executable = tokens.first else { continue }
            let exeName = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
            guard exeName == "agy" else { continue }

            let args = Array(tokens.dropFirst())
            if args.contains("--hub") || args.contains("/usage") || args.contains("--version") || args.contains("--help") {
                continue
            }
            return "Đang có lệnh `agy` CLI đang chạy"
        }
        return nil
    }

    private func isTranscriptTailInFlight(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 0 else { return false }

        let readLen: UInt64 = min(fileSize, 16_384)
        try? handle.seek(toOffset: fileSize - readLen)
        let tailData = (try? handle.readToEnd()) ?? Data()
        guard let text = String(data: tailData, encoding: .utf8) else { return false }

        let lastLine = text
            .split(whereSeparator: \.isNewline)
            .last
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let lastLine, lastLine.hasPrefix("{"),
              let lineData = lastLine.data(using: .utf8),
              let step = try? JSONDecoder().decode(TranscriptTailStep.self, from: lineData) else {
            return false
        }

        if step.status?.uppercased() == "RUNNING" || step.status?.uppercased() == "IN_PROGRESS" {
            return true
        }
        if step.type == "USER_INPUT" {
            return true
        }
        if step.type == "PLANNER_RESPONSE", let calls = step.tool_calls, !calls.isEmpty {
            return true
        }
        return false
    }

    static func splitCommandLineTokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character? = nil

        for ch in line {
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
