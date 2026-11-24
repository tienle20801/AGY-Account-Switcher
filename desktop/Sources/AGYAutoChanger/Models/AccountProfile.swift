import Foundation

// MARK: - UI Display & Filtering Preferences

public enum AccountDisplayMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case card
    case compact

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .card: return "Chi tiết"
        case .compact: return "Thu gọn"
        }
    }
}

public enum ResetCountdownDisplayMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case onHover
    case always
    case hidden

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .onHover: return "Khi Hover"
        case .always: return "Luôn hiện"
        case .hidden: return "Ẩn"
        }
    }
}

public enum QuotaModelFilterScope: String, Codable, CaseIterable, Sendable, Identifiable {
    case all
    case geminiOnly
    case claudeOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "Tất cả"
        case .geminiOnly: return "Gemini"
        case .claudeOnly: return "Claude/3P"
        }
    }

    public static func isThirdPartyBucket(_ modelID: String) -> Bool {
        let lower = modelID.lowercased()
        return lower.hasPrefix("3p")
            || lower.contains("claude")
            || lower.contains("gpt")
            || lower.contains("sonnet")
            || lower.contains("opus")
            || lower.contains("openai")
    }

    public func includes(modelID: String) -> Bool {
        switch self {
        case .all:
            return true
        case .geminiOnly:
            return !Self.isThirdPartyBucket(modelID)
        case .claudeOnly:
            return Self.isThirdPartyBucket(modelID)
        }
    }
}

// MARK: - Smart Auto-Switch Policy Models

public enum AutoSwitchTimingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case waitForIdle
    case immediateAtThreshold

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .waitForIdle: return "Chờ Idle"
        case .immediateAtThreshold: return "Đổi ngay"
        }
    }
}

public enum AutoSwitchSelectionStrategy: String, Codable, CaseIterable, Sendable, Identifiable {
    case priorityOrder
    case roundRobin

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .priorityOrder: return "Ưu tiên"
        case .roundRobin: return "Xoay vòng"
        }
    }
}

public enum AutoSwitchTriggerMatchMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case anySelected
    case allSelected

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .anySelected: return "1 nhóm cạn"
        case .allSelected: return "Tất cả nhóm cạn"
        }
    }
}

public struct AutoSwitchPolicy: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var timingMode: AutoSwitchTimingMode
    public var selectionStrategy: AutoSwitchSelectionStrategy
    public var modelScope: QuotaModelFilterScope
    public var monitoredBucketIDs: [String]
    public var triggerMatchMode: AutoSwitchTriggerMatchMode
    public var triggerThresholdPercent: Int
    public var minBackupQuotaPercent: Int
    public var candidateAccountIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case timingMode
        case selectionStrategy
        case modelScope
        case monitoredBucketIDs
        case triggerMatchMode
        case triggerThresholdPercent
        case minBackupQuotaPercent
        case candidateAccountIDs
    }

    public static func defaultBucketIDs(for scope: QuotaModelFilterScope) -> [String] {
        switch scope {
        case .all:
            return ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"]
        case .geminiOnly:
            return ["gemini-5h", "gemini-weekly"]
        case .claudeOnly:
            return ["3p-5h", "3p-weekly"]
        }
    }

    /// Maps rolling windows of the same model pool to a shared family key
    /// (`gemini-5h` & `gemini-weekly` -> `gemini`; `3p-5h` & `3p-weekly` -> `3p`).
    public static func bucketFamilyID(for bucketID: String) -> String {
        let lower = bucketID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasSuffix("-weekly") {
            return String(lower.dropLast("-weekly".count))
        }
        if lower.hasSuffix("-5h") {
            return String(lower.dropLast("-5h".count))
        }
        return lower
    }

    public static func distinctFamilyCount(for bucketIDs: [String]) -> Int {
        Set(bucketIDs.map(bucketFamilyID(for:))).count
    }

    public func includesBucket(_ bucketID: String) -> Bool {
        if !monitoredBucketIDs.isEmpty {
            return monitoredBucketIDs.contains(bucketID)
        }
        return modelScope.includes(modelID: bucketID)
    }

    public init(
        isEnabled: Bool = false,
        timingMode: AutoSwitchTimingMode = .waitForIdle,
        selectionStrategy: AutoSwitchSelectionStrategy = .priorityOrder,
        modelScope: QuotaModelFilterScope = .all,
        monitoredBucketIDs: [String] = [],
        triggerMatchMode: AutoSwitchTriggerMatchMode = .anySelected,
        triggerThresholdPercent: Int = AppConfig.autoSwitchDefaultTriggerPercent,
        minBackupQuotaPercent: Int = AppConfig.autoSwitchDefaultMinBackupPercent,
        candidateAccountIDs: [UUID] = []
    ) {
        self.isEnabled = isEnabled
        self.timingMode = timingMode
        self.selectionStrategy = selectionStrategy
        self.modelScope = modelScope
        self.monitoredBucketIDs = monitoredBucketIDs
        self.triggerMatchMode = triggerMatchMode
        self.triggerThresholdPercent = min(50, max(5, triggerThresholdPercent))
        self.minBackupQuotaPercent = min(95, max(15, minBackupQuotaPercent))
        self.candidateAccountIDs = candidateAccountIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.timingMode = try container.decodeIfPresent(AutoSwitchTimingMode.self, forKey: .timingMode) ?? .waitForIdle
        self.selectionStrategy = try container.decodeIfPresent(AutoSwitchSelectionStrategy.self, forKey: .selectionStrategy) ?? .priorityOrder
        let decodedScope = try container.decodeIfPresent(QuotaModelFilterScope.self, forKey: .modelScope) ?? .all
        self.modelScope = decodedScope
        if let decodedBuckets = try container.decodeIfPresent([String].self, forKey: .monitoredBucketIDs) {
            self.monitoredBucketIDs = decodedBuckets
        } else {
            self.monitoredBucketIDs = Self.defaultBucketIDs(for: decodedScope)
        }
        self.triggerMatchMode = try container.decodeIfPresent(AutoSwitchTriggerMatchMode.self, forKey: .triggerMatchMode) ?? .anySelected
        let rawTrigger = try container.decodeIfPresent(Int.self, forKey: .triggerThresholdPercent) ?? AppConfig.autoSwitchDefaultTriggerPercent
        let rawMinBackup = try container.decodeIfPresent(Int.self, forKey: .minBackupQuotaPercent) ?? AppConfig.autoSwitchDefaultMinBackupPercent
        self.triggerThresholdPercent = min(50, max(5, rawTrigger))
        self.minBackupQuotaPercent = min(95, max(15, rawMinBackup))
        self.candidateAccountIDs = try container.decodeIfPresent([UUID].self, forKey: .candidateAccountIDs) ?? []
    }
}

// MARK: - Weekly Quota Warmup Models

public enum WeeklyWarmupGroup: String, Codable, CaseIterable, Sendable, Identifiable {
    case gemini
    case claude

    public var id: String { rawValue }

    public var bucketID: String {
        switch self {
        case .gemini: return "gemini-weekly"
        case .claude: return "3p-weekly"
        }
    }

    public var fiveHourBucketID: String {
        switch self {
        case .gemini: return "gemini-5h"
        case .claude: return "3p-5h"
        }
    }

    public var title: String {
        switch self {
        case .gemini: return "Gemini (Tuần)"
        case .claude: return "Claude/GPT (Tuần)"
        }
    }

    public var fiveHourTitle: String {
        switch self {
        case .gemini: return "Gemini (5 giờ)"
        case .claude: return "Claude/GPT (5 giờ)"
        }
    }
}

public struct WeeklyWarmupPolicy: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var backupAccountsOnly: Bool
    public var warmGemini: Bool
    public var warmClaude: Bool
    public var fiveHourActiveHoursOnly: Bool
    public var fiveHourStartHour: Int
    public var fiveHourEndHour: Int

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case backupAccountsOnly
        case warmGemini
        case warmClaude
        case fiveHourActiveHoursOnly
        case fiveHourStartHour
        case fiveHourEndHour
    }

    public var enabledGroups: [WeeklyWarmupGroup] {
        var list: [WeeklyWarmupGroup] = []
        if warmGemini { list.append(.gemini) }
        if warmClaude { list.append(.claude) }
        return list
    }

    public func isWithinFiveHourActiveWindow(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard fiveHourActiveHoursOnly, fiveHourStartHour != fiveHourEndHour else {
            return true
        }
        let hour = calendar.component(.hour, from: date)
        if fiveHourStartHour < fiveHourEndHour {
            return hour >= fiveHourStartHour && hour < fiveHourEndHour
        }
        return hour >= fiveHourStartHour || hour < fiveHourEndHour
    }

    public init(
        isEnabled: Bool = false,
        backupAccountsOnly: Bool = true,
        warmGemini: Bool = true,
        warmClaude: Bool = true,
        fiveHourActiveHoursOnly: Bool = true,
        fiveHourStartHour: Int = 7,
        fiveHourEndHour: Int = 23
    ) {
        self.isEnabled = isEnabled
        self.backupAccountsOnly = backupAccountsOnly
        self.warmGemini = warmGemini
        self.warmClaude = warmClaude
        self.fiveHourActiveHoursOnly = fiveHourActiveHoursOnly
        self.fiveHourStartHour = min(23, max(0, fiveHourStartHour))
        self.fiveHourEndHour = min(23, max(0, fiveHourEndHour))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.backupAccountsOnly = try container.decodeIfPresent(Bool.self, forKey: .backupAccountsOnly) ?? true
        self.warmGemini = try container.decodeIfPresent(Bool.self, forKey: .warmGemini) ?? true
        self.warmClaude = try container.decodeIfPresent(Bool.self, forKey: .warmClaude) ?? true
        self.fiveHourActiveHoursOnly = try container.decodeIfPresent(Bool.self, forKey: .fiveHourActiveHoursOnly) ?? true
        let rawStart = try container.decodeIfPresent(Int.self, forKey: .fiveHourStartHour) ?? 7
        let rawEnd = try container.decodeIfPresent(Int.self, forKey: .fiveHourEndHour) ?? 23
        self.fiveHourStartHour = min(23, max(0, rawStart))
        self.fiveHourEndHour = min(23, max(0, rawEnd))
    }
}

// MARK: - Account Profile Model

/// Persisted metadata and per-model usage snapshot for a managed Antigravity account.
public struct AccountProfile: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var email: String
    public var displayName: String
    public var remark: String
    public var avatarHex: String
    public var tier: AccountTier
    public var isActive: Bool
    public var isDisabled: Bool
    public var createdAt: Date
    public var lastSwitchedAt: Date?
    public var lastSnapshotAt: Date?
    public var lastUsageScanAt: Date?
    public var lastDashboardSyncAt: Date?
    public var hasKeychainBackup: Bool
    public var modelUsages: [ModelUsage]

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName
        case remark
        case avatarHex
        case tier
        case isActive
        case isDisabled
        case createdAt
        case lastSwitchedAt
        case lastSnapshotAt
        case lastUsageScanAt
        case lastDashboardSyncAt
        case hasKeychainBackup
        case modelUsages
    }

    public init(
        id: UUID = UUID(),
        email: String,
        displayName: String,
        remark: String = "",
        avatarHex: String = AppConfig.avatarPaletteHex[0],
        tier: AccountTier = .pro,
        isActive: Bool = false,
        isDisabled: Bool = false,
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
        self.remark = remark
        self.avatarHex = avatarHex
        self.tier = tier
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.createdAt = createdAt
        self.lastSwitchedAt = lastSwitchedAt
        self.lastSnapshotAt = lastSnapshotAt
        self.lastUsageScanAt = lastUsageScanAt
        self.lastDashboardSyncAt = lastDashboardSyncAt
        self.hasKeychainBackup = hasKeychainBackup
        self.modelUsages = modelUsages ?? ModelUsage.defaultSet(for: tier)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.email = try container.decode(String.self, forKey: .email)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.remark = try container.decodeIfPresent(String.self, forKey: .remark) ?? ""
        self.avatarHex = try container.decodeIfPresent(String.self, forKey: .avatarHex) ?? AppConfig.avatarPaletteHex[0]
        let decodedTier = try container.decodeIfPresent(AccountTier.self, forKey: .tier) ?? .pro
        self.tier = decodedTier
        self.isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        self.isDisabled = try container.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.lastSwitchedAt = try container.decodeIfPresent(Date.self, forKey: .lastSwitchedAt)
        self.lastSnapshotAt = try container.decodeIfPresent(Date.self, forKey: .lastSnapshotAt)
        self.lastUsageScanAt = try container.decodeIfPresent(Date.self, forKey: .lastUsageScanAt)
        self.lastDashboardSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastDashboardSyncAt)
        self.hasKeychainBackup = try container.decodeIfPresent(Bool.self, forKey: .hasKeychainBackup) ?? false
        self.modelUsages = try container.decodeIfPresent([ModelUsage].self, forKey: .modelUsages) ?? ModelUsage.defaultSet(for: decodedTier)
    }

    public var extraDedicatedPoolLabels: [String] {
        let coreIDs = Set(AppConfig.supportedModels.map(\.id))
        var seen: Set<String> = []
        var labels: [String] = []
        for usage in modelUsages where !coreIDs.contains(usage.id) && usage.hasDashboardQuota {
            let label = usage.shortLabel
                .replacingOccurrences(of: " Tuần", with: "")
                .replacingOccurrences(of: " 5h", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = label.isEmpty ? usage.shortLabel : label
            if seen.insert(resolved).inserted {
                labels.append(resolved)
            }
        }
        return labels
    }

    public var hasDedicatedArgonPool: Bool {
        modelUsages.first(where: { $0.id == "argon-weekly" })?.hasDashboardQuota == true
    }

    public var hasDedicatedCarbonPool: Bool {
        modelUsages.contains { ($0.id == "carbon-5h" || $0.id == "carbon-weekly") && $0.hasDashboardQuota }
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

    /// Updates tier quotas while preserving already-counted turns, cooldown timestamps, and extra dynamic pools.
    public mutating func applyTier(_ newTier: AccountTier) {
        tier = newTier
        var updated = ModelUsage.defaultSet(for: newTier)
        let coreIDs = Set(updated.map(\.id))
        for idx in updated.indices {
            if let existing = modelUsages.first(where: { $0.id == updated[idx].id }) {
                updated[idx].turnsUsed = existing.turnsUsed
                updated[idx].lastUsedAt = existing.lastUsedAt
                updated[idx].cooldownUntil = existing.cooldownUntil
                updated[idx].quotaRemainingFraction = existing.quotaRemainingFraction
                updated[idx].quotaResetAt = existing.quotaResetAt
                updated[idx].quotaSyncedAt = existing.quotaSyncedAt
                updated[idx].tokensUsed = existing.tokensUsed
                updated[idx].groupMembersHint = existing.groupMembersHint
            }
        }
        for var existingExtra in modelUsages where !coreIDs.contains(existingExtra.id) {
            existingExtra.turnLimit = newTier.defaultTurnLimit(for: existingExtra.id)
            updated.append(existingExtra)
        }
        modelUsages = updated
    }
}

// MARK: - Portable Export / Import Models

public struct PortableAccountRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var email: String
    public var displayName: String
    public var remark: String
    public var tier: AccountTier
    public var isDisabled: Bool
    public var refreshToken: String?
    public var rawKeyringSecretBase64: String?

    public init(
        id: UUID = UUID(),
        email: String,
        displayName: String,
        remark: String = "",
        tier: AccountTier = .pro,
        isDisabled: Bool = false,
        refreshToken: String? = nil,
        rawKeyringSecretBase64: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.remark = remark
        self.tier = tier
        self.isDisabled = isDisabled
        self.refreshToken = refreshToken
        self.rawKeyringSecretBase64 = rawKeyringSecretBase64
    }
}

public struct PortableAccountExportBundle: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var accounts: [PortableAccountRecord]

    public init(
        schemaVersion: Int = 2,
        exportedAt: Date = Date(),
        accounts: [PortableAccountRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.accounts = accounts
    }
}

// MARK: - App Preferences Model

/// Non-sensitive user preferences persisted in `~/.agy-switcher/settings.json`.
public struct SwitcherSettings: Codable, Sendable, Equatable {
    public var agyAppBundlePath: String
    public var autoRelaunchAGY: Bool
    public var syncIDESession: Bool
    public var syncCLISession: Bool
    public var useKeychainFallback: Bool
    public var rollingWindowHours: Double
    public var bindLifecycleWithAGY: Bool
    public var enableLowQuotaNotification: Bool
    public var lowQuotaThresholdPercent: Int
    public var showQuickSummaryHeader: Bool
    public var accountDisplayMode: AccountDisplayMode
    public var resetCountdownMode: ResetCountdownDisplayMode
    public var modelFilterScope: QuotaModelFilterScope
    public var autoSwitchPolicy: AutoSwitchPolicy
    public var weeklyWarmupPolicy: WeeklyWarmupPolicy

    enum CodingKeys: String, CodingKey {
        case agyAppBundlePath
        case autoRelaunchAGY
        case syncIDESession
        case syncCLISession
        case useKeychainFallback
        case rollingWindowHours
        case bindLifecycleWithAGY
        case enableLowQuotaNotification
        case lowQuotaThresholdPercent
        case showQuickSummaryHeader
        case accountDisplayMode
        case resetCountdownMode
        case modelFilterScope
        case autoSwitchPolicy
        case weeklyWarmupPolicy
    }

    public init(
        agyAppBundlePath: String = AppConfig.defaultAppBundlePath,
        autoRelaunchAGY: Bool = true,
        syncIDESession: Bool = false,
        syncCLISession: Bool = true,
        useKeychainFallback: Bool = true,
        rollingWindowHours: Double = AppConfig.defaultRollingWindowHours,
        bindLifecycleWithAGY: Bool = true,
        enableLowQuotaNotification: Bool = true,
        lowQuotaThresholdPercent: Int = AppConfig.lowQuotaAlertThresholdPercent,
        showQuickSummaryHeader: Bool = true,
        accountDisplayMode: AccountDisplayMode = .card,
        resetCountdownMode: ResetCountdownDisplayMode = .onHover,
        modelFilterScope: QuotaModelFilterScope = .all,
        autoSwitchPolicy: AutoSwitchPolicy = AutoSwitchPolicy(),
        weeklyWarmupPolicy: WeeklyWarmupPolicy = WeeklyWarmupPolicy()
    ) {
        self.agyAppBundlePath = agyAppBundlePath
        self.autoRelaunchAGY = autoRelaunchAGY
        self.syncIDESession = syncIDESession
        self.syncCLISession = syncCLISession
        self.useKeychainFallback = useKeychainFallback
        self.rollingWindowHours = rollingWindowHours
        self.bindLifecycleWithAGY = bindLifecycleWithAGY
        self.enableLowQuotaNotification = enableLowQuotaNotification
        self.lowQuotaThresholdPercent = min(95, max(5, lowQuotaThresholdPercent))
        self.showQuickSummaryHeader = showQuickSummaryHeader
        self.accountDisplayMode = accountDisplayMode
        self.resetCountdownMode = resetCountdownMode
        self.modelFilterScope = modelFilterScope
        self.autoSwitchPolicy = autoSwitchPolicy
        self.weeklyWarmupPolicy = weeklyWarmupPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.agyAppBundlePath = try container.decodeIfPresent(String.self, forKey: .agyAppBundlePath) ?? AppConfig.defaultAppBundlePath
        self.autoRelaunchAGY = try container.decodeIfPresent(Bool.self, forKey: .autoRelaunchAGY) ?? true
        self.syncIDESession = try container.decodeIfPresent(Bool.self, forKey: .syncIDESession) ?? false
        self.syncCLISession = try container.decodeIfPresent(Bool.self, forKey: .syncCLISession) ?? true
        self.useKeychainFallback = try container.decodeIfPresent(Bool.self, forKey: .useKeychainFallback) ?? true
        self.rollingWindowHours = try container.decodeIfPresent(Double.self, forKey: .rollingWindowHours) ?? AppConfig.defaultRollingWindowHours
        self.bindLifecycleWithAGY = try container.decodeIfPresent(Bool.self, forKey: .bindLifecycleWithAGY) ?? true
        self.enableLowQuotaNotification = try container.decodeIfPresent(Bool.self, forKey: .enableLowQuotaNotification) ?? true
        let decodedThreshold = try container.decodeIfPresent(Int.self, forKey: .lowQuotaThresholdPercent) ?? AppConfig.lowQuotaAlertThresholdPercent
        self.lowQuotaThresholdPercent = min(95, max(5, decodedThreshold))
        self.showQuickSummaryHeader = try container.decodeIfPresent(Bool.self, forKey: .showQuickSummaryHeader) ?? true
        self.accountDisplayMode = try container.decodeIfPresent(AccountDisplayMode.self, forKey: .accountDisplayMode) ?? .card
        self.resetCountdownMode = try container.decodeIfPresent(ResetCountdownDisplayMode.self, forKey: .resetCountdownMode) ?? .onHover
        self.modelFilterScope = try container.decodeIfPresent(QuotaModelFilterScope.self, forKey: .modelFilterScope) ?? .all
        self.autoSwitchPolicy = try container.decodeIfPresent(AutoSwitchPolicy.self, forKey: .autoSwitchPolicy) ?? AutoSwitchPolicy()
        self.weeklyWarmupPolicy = try container.decodeIfPresent(WeeklyWarmupPolicy.self, forKey: .weeklyWarmupPolicy) ?? WeeklyWarmupPolicy()
    }
}
