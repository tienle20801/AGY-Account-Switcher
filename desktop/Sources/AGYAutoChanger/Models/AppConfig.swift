import Foundation

// MARK: - Centralized Configuration

/// Centralized configuration for filesystem paths, session snapshots, model definitions, and timing constants.
public enum AppConfig {

    // MARK: - Application & Data Paths

    public static let defaultAppBundlePath = "/Applications/Antigravity.app"
    public static let defaultIDEAppBundlePath = "/Applications/Antigravity IDE.app"

    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    public static var agyAppSupportDir: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Antigravity", isDirectory: true)
    }

    public static var agyGeminiDir: URL {
        homeDirectory
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
    }

    public static var geminiRootDir: URL {
        homeDirectory.appendingPathComponent(".gemini", isDirectory: true)
    }

    public static let jetskiOAuthTokenFileName = "jetski-standalone-oauth-token"

    public static var jetskiOAuthTokenURL: URL {
        geminiRootDir.appendingPathComponent(jetskiOAuthTokenFileName, isDirectory: false)
    }

    public static var agyCLIDir: URL {
        geminiRootDir.appendingPathComponent("antigravity-cli", isDirectory: true)
    }

    public static let agyCLIOAuthTokenFileName = "antigravity-oauth-token"

    public static var agyCLIOAuthTokenURL: URL {
        agyCLIDir.appendingPathComponent(agyCLIOAuthTokenFileName, isDirectory: false)
    }

    public static var agyAppStorageURL: URL {
        agyAppSupportDir.appendingPathComponent("app_storage.json", isDirectory: false)
    }

    public static var agyStatePbtxtURL: URL {
        agyGeminiDir.appendingPathComponent("antigravity_state.pbtxt", isDirectory: false)
    }

    public static var agyBrainDir: URL {
        agyGeminiDir.appendingPathComponent("brain", isDirectory: true)
    }

    public static var agyConversationsDir: URL {
        agyGeminiDir.appendingPathComponent("conversations", isDirectory: true)
    }

    public static let cloudCodeBaseURLs: [String] = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.sandbox.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
    ]

    public static let antigravityUserAgent = "antigravity/2.32.1 (darwin/arm64)"
    public static let googleOAuthTokenEndpoint = "https://oauth2.googleapis.com/token"
    public static let defaultCloudCodeProject = "aicode-consumers"

    public static var oauthClientConfigURL: URL {
        vaultRootDir.appendingPathComponent("oauth_client.json", isDirectory: false)
    }

    public static func resolveOAuthClientCredentials() -> (clientID: String, clientSecret: String)? {
        let env = ProcessInfo.processInfo.environment
        if let envID = env["AGY_OAUTH_CLIENT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envID.isEmpty,
           let envSecret = env["AGY_OAUTH_CLIENT_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envSecret.isEmpty {
            return (envID, envSecret)
        }

        struct LocalOAuthClientConfig: Decodable {
            let client_id: String?
            let client_secret: String?
        }

        guard let data = try? Data(contentsOf: oauthClientConfigURL),
              let decoded = try? JSONDecoder().decode(LocalOAuthClientConfig.self, from: data),
              let clientID = decoded.client_id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientID.isEmpty,
              let clientSecret = decoded.client_secret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientSecret.isEmpty else {
            return nil
        }
        return (clientID, clientSecret)
    }

    public static var agyIDEAppSupportDir: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Antigravity IDE", isDirectory: true)
    }

    public static var agyIDEGeminiDir: URL {
        homeDirectory
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-ide", isDirectory: true)
    }

    // MARK: - Vault Paths

    public static var vaultRootDir: URL {
        homeDirectory.appendingPathComponent(".agy-switcher", isDirectory: true)
    }

    public static var profilesDir: URL {
        vaultRootDir.appendingPathComponent("profiles", isDirectory: true)
    }

    public static var accountsMetadataURL: URL {
        vaultRootDir.appendingPathComponent("accounts.json", isDirectory: false)
    }

    public static var settingsMetadataURL: URL {
        vaultRootDir.appendingPathComponent("settings.json", isDirectory: false)
    }

    public static var autoSwitchStateURL: URL {
        vaultRootDir.appendingPathComponent("auto_switch_state.json", isDirectory: false)
    }

    public static var weeklyWarmupStateURL: URL {
        vaultRootDir.appendingPathComponent("weekly_warmup_state.json", isDirectory: false)
    }

    // MARK: - Tracked Session Artifacts (Priority 1)

    /// Relative files and folders inside `~/Library/Application Support/Antigravity` that hold session/auth state.
    public static let appSupportSessionItems: [String] = [
        "Cookies",
        "Cookies-journal",
        "Local Storage",
        "Session Storage",
        "Local State",
        "Preferences",
        "Network Persistent State",
        "DIPS",
        "Trust Tokens",
        "app_storage.json",
        "credential-user-scope"
    ]

    /// Keys stripped from `app_storage.json` when preparing a clean sign-in while keeping user workspace layout/projects.
    public static let appStorageOnboardingKeysToClear: [String] = [
        "agy.onboarding.lastLoginUsername",
        "agy.onboarding.lastLoginIsGcpTos"
    ]

    /// Relative files inside `~/.gemini/antigravity` that store agent/auth identity state.
    public static let geminiSessionItems: [String] = [
        "antigravity_state.pbtxt"
    ]

    /// Optional relative items inside `~/Library/Application Support/Antigravity IDE` when IDE sync is enabled.
    public static let ideAppSupportSessionItems: [String] = [
        "Cookies",
        "Cookies-journal",
        "Local Storage",
        "Session Storage",
        "User/globalStorage/state.vscdb",
        "User/globalStorage/storage.json"
    ]

    /// Volatile lock/WAL files cleared before restoring a clean snapshot.
    public static let staleRuntimeArtifacts: [String] = [
        "Cookies-journal",
        "DIPS-wal",
        "DIPS-shm",
        "SingletonLock",
        "SingletonCookie",
        "SingletonSocket"
    ]

    // MARK: - Keychain Scoped Credentials (Priority 2)

    public struct KeychainTarget: Sendable, Hashable {
        public let service: String
        public let account: String?
    }

    /// Primary OAuth + tier credential item managed by Antigravity 2.0 `language_server` (`zalando/go-keyring`).
    public static let primaryAuthKeychainTarget = KeychainTarget(service: "gemini", account: "antigravity")

    public static let keychainFallbackServices: [String] = [
        "gemini",
        "Antigravity Safe Storage",
        "com.google.antigravity"
    ]

    public static let keychainScopedTargets: [KeychainTarget] = [
        primaryAuthKeychainTarget,
        KeychainTarget(service: "Antigravity Safe Storage", account: nil),
        KeychainTarget(service: "com.google.antigravity", account: nil)
    ]

    // MARK: - Security Permissions & Process Timing

    public static let directoryPermissions: Int = 0o700
    public static let filePermissions: Int = 0o600
    public static let gracefulTerminateTimeoutSeconds: TimeInterval = 4.0
    public static let terminatePollIntervalNanoseconds: UInt64 = 150_000_000
    public static let postTerminateFlushNanoseconds: UInt64 = 300_000_000
    public static let agyTerminateGraceDelayNanoseconds: UInt64 = 1_500_000_000
    public static let backgroundQuotaPollIntervalNanoseconds: UInt64 = 120_000_000_000
    public static let lowQuotaAlertThresholdPercent: Int = 30
    public static let defaultRollingWindowHours: Double = 5.0
    public static let defaultCooldownMinutes: Int = 60
    public static let autoSwitchDefaultTriggerPercent: Int = 10
    public static let autoSwitchDefaultMinBackupPercent: Int = 30
    public static let autoSwitchMaxQuotaAgeSeconds: TimeInterval = 180
    public static let autoSwitchIdleQuietWindowSeconds: TimeInterval = 25
    public static let autoSwitchIdleRecheckIntervalNanoseconds: UInt64 = 15_000_000_000
    public static let weeklyWarmupPacingNanoseconds: UInt64 = 2_000_000_000
    public static let weeklyWarmupMinRemainingFraction: Double = 0.999
    public static let weeklyWarmupMaxElapsedResetSeconds: TimeInterval = 6 * 86_400
    public static let weeklyWarmupHistoryRetentionSeconds: TimeInterval = 30 * 86_400
    public static let weeklyWarmupFailureRetryCooldownSeconds: TimeInterval = 600
    public static let fiveHourWarmupMaxElapsedResetSeconds: TimeInterval = 4 * 3_600
    public static let fiveHourWarmupMinWeeklySiblingFraction: Double = 0.05

    // MARK: - Companion Lifecycle Binding

    public static let appBundleIdentifier = "com.agy.autochanger"
    public static let watcherLaunchAgentLabel = "com.agy.autochanger.watcher"
    public static let watcherExecutableName = "AGYWatcher"

    public static var watcherLaunchAgentPlistURL: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(watcherLaunchAgentLabel).plist", isDirectory: false)
    }

    // MARK: - Model Catalog & Appearance

    public struct ModelDefinition: Sendable {
        public let id: String
        public let displayName: String
        public let shortLabel: String
    }

    public static let supportedModels: [ModelDefinition] = [
        ModelDefinition(id: "gemini-5h", displayName: "Gemini Models (5 giờ)", shortLabel: "Gemini 5h"),
        ModelDefinition(id: "gemini-weekly", displayName: "Gemini Models (Tuần)", shortLabel: "Gemini Tuần"),
        ModelDefinition(id: "3p-5h", displayName: "Claude & GPT (5 giờ)", shortLabel: "Claude 5h"),
        ModelDefinition(id: "3p-weekly", displayName: "Claude & GPT (Tuần)", shortLabel: "Claude Tuần")
    ]

    /// Optional dedicated quota pools shown dynamically on an account only when reported by the backend.
    public static let optionalDedicatedModels: [ModelDefinition] = [
        ModelDefinition(id: "argon-weekly", displayName: "Gemini 4 Argon (Tuần)", shortLabel: "Argon Tuần"),
        ModelDefinition(id: "carbon-5h", displayName: "Gemini 4 Carbon (5 giờ)", shortLabel: "Carbon 5h"),
        ModelDefinition(id: "carbon-weekly", displayName: "Gemini 4 Carbon (Tuần)", shortLabel: "Carbon Tuần")
    ]

    public static func modelDefinition(for modelID: String) -> ModelDefinition? {
        supportedModels.first(where: { $0.id == modelID })
            ?? optionalDedicatedModels.first(where: { $0.id == modelID })
    }

    public static let avatarPaletteHex: [String] = [
        "#3B82F6", // Electric Blue
        "#10B981", // Emerald
        "#8B5CF6", // Violet
        "#F59E0B", // Amber
        "#EC4899", // Pink
        "#06B6D4"  // Cyan
    ]

    public static let uiPopoverMinWidth: CGFloat = 400
    public static let uiPopoverIdealWidth: CGFloat = 436
    public static let uiPopoverMaxWidth: CGFloat = 480
    public static let uiPopoverMaxScreenFraction: CGFloat = 0.78
}
