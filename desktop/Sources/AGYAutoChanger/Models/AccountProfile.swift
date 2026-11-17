import Foundation

// MARK: - Account Profile Model

/// Persisted metadata and per-model usage snapshot for a managed Antigravity account.
public struct AccountProfile: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var email: String
    public var displayName: String
    public var avatarHex: String
    public var tier: AccountTier
    public var isActive: Bool
    public var createdAt: Date
    public var lastSwitchedAt: Date?
    public var lastSnapshotAt: Date?
    public var lastUsageScanAt: Date?
    public var lastDashboardSyncAt: Date?
    public var hasKeychainBackup: Bool
    public var modelUsages: [ModelUsage]

    public init(
        id: UUID = UUID(),
        email: String,
        displayName: String,
        avatarHex: String = AppConfig.avatarPaletteHex[0],
        tier: AccountTier = .pro,
        isActive: Bool = false,
        createdAt: Date = Date(),
        lastSwitchedAt: Date? = nil,
        lastSnapshotAt: Date? = nil,
        lastUsageScanAt: Date? = nil,
        lastDashboardSyncAt: Date? = nil,
        hasKeychainBackup: Bool = false,
        modelUsages: [ModelUsage]? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarHex = avatarHex
        self.tier = tier
        self.isActive = isActive
        self.createdAt = createdAt
        self.lastSwitchedAt = lastSwitchedAt
        self.lastSnapshotAt = lastSnapshotAt
        self.lastUsageScanAt = lastUsageScanAt
        self.lastDashboardSyncAt = lastDashboardSyncAt
        self.hasKeychainBackup = hasKeychainBackup
        self.modelUsages = modelUsages ?? ModelUsage.defaultSet(for: tier)
    }

    /// Short 1-2 character initials for avatar circles and menu bar display.
    public var initials: String {
        let source = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = source.isEmpty ? email : source
        let parts = candidate
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if parts.count >= 2, let first = parts[0].first, let second = parts[1].first {
            return String([first, second]).uppercased()
        }
        return String(candidate.prefix(2)).uppercased()
    }

    /// Concise display label shown alongside the menu bar icon.
    public var menuBarShortName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return String(trimmed.prefix(14))
        }
        if let localPart = email.split(separator: "@").first {
            return String(localPart.prefix(14))
        }
        return "AGY"
    }

    /// Updates tier quotas while preserving already-counted turns and cooldown timestamps.
    public mutating func applyTier(_ newTier: AccountTier) {
        tier = newTier
        var updated = ModelUsage.defaultSet(for: newTier)
        for idx in updated.indices {
            if let existing = modelUsages.first(where: { $0.id == updated[idx].id }) {
                updated[idx].turnsUsed = existing.turnsUsed
                updated[idx].lastUsedAt = existing.lastUsedAt
                updated[idx].cooldownUntil = existing.cooldownUntil
                updated[idx].quotaRemainingFraction = existing.quotaRemainingFraction
                updated[idx].quotaResetAt = existing.quotaResetAt
                updated[idx].quotaSyncedAt = existing.quotaSyncedAt
                updated[idx].tokensUsed = existing.tokensUsed
            }
        }
        modelUsages = updated
    }
}

// MARK: - App Preferences Model

/// Non-sensitive user preferences persisted in `~/.agy-switcher/settings.json`.
public struct SwitcherSettings: Codable, Sendable, Equatable {
    public var agyAppBundlePath: String
    public var autoRelaunchAGY: Bool
    public var syncIDESession: Bool
    public var useKeychainFallback: Bool
    public var rollingWindowHours: Double
    public var bindLifecycleWithAGY: Bool

    enum CodingKeys: String, CodingKey {
        case agyAppBundlePath
        case autoRelaunchAGY
        case syncIDESession
        case useKeychainFallback
        case rollingWindowHours
        case bindLifecycleWithAGY
    }

    public init(
        agyAppBundlePath: String = AppConfig.defaultAppBundlePath,
        autoRelaunchAGY: Bool = true,
        syncIDESession: Bool = false,
        useKeychainFallback: Bool = true,
        rollingWindowHours: Double = AppConfig.defaultRollingWindowHours,
        bindLifecycleWithAGY: Bool = true
    ) {
        self.agyAppBundlePath = agyAppBundlePath
        self.autoRelaunchAGY = autoRelaunchAGY
        self.syncIDESession = syncIDESession
        self.useKeychainFallback = useKeychainFallback
        self.rollingWindowHours = rollingWindowHours
        self.bindLifecycleWithAGY = bindLifecycleWithAGY
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.agyAppBundlePath = try container.decodeIfPresent(String.self, forKey: .agyAppBundlePath) ?? AppConfig.defaultAppBundlePath
        self.autoRelaunchAGY = try container.decodeIfPresent(Bool.self, forKey: .autoRelaunchAGY) ?? true
        self.syncIDESession = try container.decodeIfPresent(Bool.self, forKey: .syncIDESession) ?? false
        self.useKeychainFallback = try container.decodeIfPresent(Bool.self, forKey: .useKeychainFallback) ?? true
        self.rollingWindowHours = try container.decodeIfPresent(Double.self, forKey: .rollingWindowHours) ?? AppConfig.defaultRollingWindowHours
        self.bindLifecycleWithAGY = try container.decodeIfPresent(Bool.self, forKey: .bindLifecycleWithAGY) ?? true
    }
}
