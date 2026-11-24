import Foundation

// MARK: - Account Tier & Quota Definitions

/// Subscription tier controlling estimated 5-hour rolling turn quotas per model.
public enum AccountTier: String, Codable, CaseIterable, Sendable, Identifiable {
    case free
    case pro
    case ultra

    public var id: String { rawValue }

    public var badgeTitle: String {
        rawValue.uppercased()
    }

    /// Maps Antigravity server tier strings (e.g. `free-tier`, `standard-tier`, `gcp-ge-ultra-tier`) to `AccountTier`.
    public static func from(serverTier rawTier: String?) -> AccountTier? {
        guard let normalized = rawTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        if normalized.contains("ultra") {
            return .ultra
        }
        if normalized.contains("pro") || normalized.contains("standard") {
            return .pro
        }
        if normalized.contains("free") || normalized.contains("legacy") {
            return .free
        }
        return nil
    }

    public func defaultTurnLimit(for modelID: String) -> Int {
        switch (self, modelID) {
        case (.free, "gemini-5h"): return 30
        case (.free, "gemini-weekly"): return 150
        case (.free, "3p-5h"): return 15
        case (.free, "3p-weekly"): return 60
        case (.free, "argon-weekly"): return 50
        case (.free, "carbon-5h"): return 15
        case (.free, "carbon-weekly"): return 60

        case (.pro, "gemini-5h"): return 150
        case (.pro, "gemini-weekly"): return 1000
        case (.pro, "3p-5h"): return 60
        case (.pro, "3p-weekly"): return 400
        case (.pro, "argon-weekly"): return 200
        case (.pro, "carbon-5h"): return 60
        case (.pro, "carbon-weekly"): return 300

        case (.ultra, "gemini-5h"): return 450
        case (.ultra, "gemini-weekly"): return 3000
        case (.ultra, "3p-5h"): return 200
        case (.ultra, "3p-weekly"): return 1200
        case (.ultra, "argon-weekly"): return 600
        case (.ultra, "carbon-5h"): return 200
        case (.ultra, "carbon-weekly"): return 1000

        default: return 60
        }
    }
}

// MARK: - Usage Status Level

/// Visual status classification for a model's remaining quota.
public enum UsageStatusLevel: Sendable, Equatable {
    case healthy
    case moderate
    case warning
    case rateLimited
}

public struct QuotaBucketDescriptor: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let shortLabel: String
    public let groupMembersHint: String?

    public init(
        id: String,
        displayName: String,
        shortLabel: String,
        groupMembersHint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.shortLabel = shortLabel
        self.groupMembersHint = groupMembersHint
    }
}

// MARK: - Model Usage

/// Per-model usage metrics, server Dashboard quota sync, and optional cooldown window for an account.
public struct ModelUsage: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var displayName: String
    public var turnsUsed: Int
    public var turnLimit: Int
    public var lastUsedAt: Date?
    public var cooldownUntil: Date?
    public var quotaRemainingFraction: Double?
    public var quotaResetAt: Date?
    public var quotaSyncedAt: Date?
    public var tokensUsed: Int?
    public var groupMembersHint: String?

    public init(
        id: String,
        displayName: String,
        turnsUsed: Int = 0,
        turnLimit: Int,
        lastUsedAt: Date? = nil,
        cooldownUntil: Date? = nil,
        quotaRemainingFraction: Double? = nil,
        quotaResetAt: Date? = nil,
        quotaSyncedAt: Date? = nil,
        tokensUsed: Int? = nil,
        groupMembersHint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.turnsUsed = max(0, turnsUsed)
        self.turnLimit = max(1, turnLimit)
        self.lastUsedAt = lastUsedAt
        self.cooldownUntil = cooldownUntil
        self.quotaRemainingFraction = quotaRemainingFraction.map { min(1.0, max(0.0, $0)) }
        self.quotaResetAt = quotaResetAt
        self.quotaSyncedAt = quotaSyncedAt
        self.tokensUsed = tokensUsed.map { max(0, $0) }
        self.groupMembersHint = groupMembersHint
    }

    public var shortLabel: String {
        AppConfig.modelDefinition(for: id)?.shortLabel ?? Self.deriveShortLabel(id: id, displayName: displayName)
    }

    public static func deriveShortLabel(id: String, displayName: String) -> String {
        var label = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty {
            label = id
        }
        label = label
            .replacingOccurrences(of: "(5 giờ)", with: "5h")
            .replacingOccurrences(of: "(Tuần)", with: "Tuần")
            .replacingOccurrences(of: "Models ", with: "")
            .replacingOccurrences(of: " models", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label.replacingOccurrences(of: "  ", with: " ")
    }

    public var hasDashboardQuota: Bool {
        quotaRemainingFraction != nil
    }

    /// Expected rolling window duration for this bucket (7 days for weekly, 5 hours for 5h).
    public var expectedWindowDurationSeconds: TimeInterval? {
        if id.hasSuffix("-weekly") { return 7 * 86_400 }
        if id.hasSuffix("-5h") { return 5 * 3_600 }
        return nil
    }

    /// True when the backend reports an untouched 100% remaining fraction (`>= 0.9999999`) with a floating placeholder
    /// `resetAt ≈ syncedAt + windowDuration`, indicating the rolling reset timer has not actually started yet.
    public func hasUnstartedResetPlaceholder(toleranceSeconds: TimeInterval = 5) -> Bool {
        guard let rawFraction = quotaRemainingFraction,
              rawFraction >= 0.9999999,
              let resetAt = quotaResetAt,
              let syncedAt = quotaSyncedAt,
              let windowSeconds = expectedWindowDurationSeconds else {
            return false
        }
        return resetAt.timeIntervalSince(syncedAt) >= (windowSeconds - toleranceSeconds)
    }

    /// True when neither Dashboard quota nor local turn/token activity nor cooldown has been recorded yet.
    public var isUnknownObservation: Bool {
        !hasDashboardQuota && turnsUsed == 0 && (tokensUsed ?? 0) == 0 && cooldownUntil == nil
    }

    /// Remaining fraction (`0.0 ... 1.0`): prefers live Antigravity Dashboard quota, falls back to local turn estimate.
    public func remainingFractionValue(at referenceDate: Date = Date()) -> Double {
        if let cooldownUntil,
           cooldownUntil.timeIntervalSinceReferenceDate > referenceDate.timeIntervalSinceReferenceDate {
            return 0.0
        }
        if let quotaRemainingFraction {
            if let quotaResetAt,
               referenceDate.timeIntervalSinceReferenceDate >= quotaResetAt.timeIntervalSinceReferenceDate {
                return 1.0
            }
            return min(1.0, max(0.0, quotaRemainingFraction))
        }
        guard turnLimit > 0 else { return 1.0 }
        let usedRatio = min(1.0, max(0.0, Double(turnsUsed) / Double(turnLimit)))
        return max(0.0, 1.0 - usedRatio)
    }

    public var remainingPercentageInt: Int {
        Int((remainingFractionValue() * 100.0).rounded())
    }

    public func isRateLimited(at referenceDate: Date = Date()) -> Bool {
        if let cooldownUntil,
           cooldownUntil.timeIntervalSinceReferenceDate > referenceDate.timeIntervalSinceReferenceDate {
            return true
        }
        if let quotaRemainingFraction {
            if let quotaResetAt,
               referenceDate.timeIntervalSinceReferenceDate >= quotaResetAt.timeIntervalSinceReferenceDate {
                return false
            }
            return quotaRemainingFraction <= 0.001
        }
        return turnsUsed >= turnLimit
    }

    public var usageFraction: Double {
        if isRateLimited() {
            return 1.0
        }
        if let quotaRemainingFraction {
            return min(1.0, max(0.0, 1.0 - quotaRemainingFraction))
        }
        guard turnLimit > 0 else { return 0 }
        return min(1.0, max(0.0, Double(turnsUsed) / Double(turnLimit)))
    }

    public var percentageInt: Int {
        Int((usageFraction * 100.0).rounded())
    }

    public func statusLevel(at referenceDate: Date = Date()) -> UsageStatusLevel {
        if isRateLimited(at: referenceDate) {
            return .rateLimited
        }
        let remaining = remainingFractionValue(at: referenceDate)
        if remaining <= 0.20 {
            return .warning
        }
        if remaining <= 0.50 {
            return .moderate
        }
        return .healthy
    }

    public func remainingResetLabel(at referenceDate: Date = Date()) -> String? {
        if let label = remainingCooldownLabel(at: referenceDate) {
            return label
        }
        if hasUnstartedResetPlaceholder() {
            return nil
        }
        guard let quotaResetAt else { return nil }
        return Self.formatCountdown(until: quotaResetAt, from: referenceDate)
    }

    public func remainingCooldownLabel(at referenceDate: Date = Date()) -> String? {
        guard let cooldownUntil else { return nil }
        return Self.formatCountdown(until: cooldownUntil, from: referenceDate)
    }

    /// Resolves a server quota bucket (from `retrieveUserQuotaSummary` or `agy /usage`) into a dynamic descriptor,
    /// supporting both core pools and arbitrary new model groups added by Google without code changes.
    public static func resolveQuotaBucketDescriptor(
        bucketID: String?,
        groupName: String?,
        bucketName: String?,
        window: String?,
        groupDescription: String? = nil
    ) -> QuotaBucketDescriptor? {
        let trimmedID = (bucketID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGroup = (groupName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBucketName = (bucketName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWindow = (window ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedID.isEmpty || !trimmedGroup.isEmpty || !trimmedBucketName.isEmpty else {
            return nil
        }

        let hint = extractGroupMembersHint(from: groupDescription)
        let windowSignals = "\(trimmedID) \(trimmedWindow) \(trimmedBucketName)".lowercased()
        let isWeekly = windowSignals.contains("week") || windowSignals.contains("7d") || windowSignals.contains("wtu")
        let isFiveHour = !isWeekly && (
            windowSignals.contains("5h")
                || windowSignals.contains("5-hour")
                || windowSignals.contains("5 hour")
                || windowSignals.contains("five")
        )

        let rawIDLower = trimmedID.lowercased()
        let exactKnownID: String?
        switch rawIDLower {
        case "gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly", "argon-weekly", "carbon-5h", "carbon-weekly":
            exactKnownID = rawIDLower
        case "gemini-argon-wtu-weekly":
            exactKnownID = "argon-weekly"
        case "gemini-carbon-5h":
            exactKnownID = "carbon-5h"
        case "gemini-carbon-wtu-weekly":
            exactKnownID = "carbon-weekly"
        default:
            exactKnownID = nil
        }

        if let knownID = exactKnownID {
            let def = AppConfig.modelDefinition(for: knownID)
            let displayName = def?.displayName ?? deriveDynamicDisplayName(groupName: trimmedGroup, bucketID: knownID, isWeekly: isWeekly, isFiveHour: isFiveHour)
            let shortLabel = def?.shortLabel ?? deriveShortLabel(id: knownID, displayName: displayName)
            return QuotaBucketDescriptor(id: knownID, displayName: displayName, shortLabel: shortLabel, groupMembersHint: hint)
        }

        // Do NOT classify using `groupDescription` because shared groups list all included models there.
        let groupLower = trimmedGroup.lowercased()
        let nonGenericID = (rawIDLower == "weekly-limit" || rawIDLower == "5h-limit" || rawIDLower == "weekly" || rawIDLower == "5h") ? "" : rawIDLower
        let classificationContext = "\(nonGenericID) \(groupLower)".trimmingCharacters(in: .whitespacesAndNewlines)

        let matchedKnownID: String?
        if classificationContext.contains("argon") {
            matchedKnownID = "argon-weekly"
        } else if classificationContext.contains("carbon") {
            matchedKnownID = isWeekly ? "carbon-weekly" : (isFiveHour ? "carbon-5h" : "carbon-weekly")
        } else if classificationContext.contains("claude")
                    || classificationContext.contains("gpt")
                    || classificationContext.contains("openai")
                    || classificationContext.contains("3p") {
            matchedKnownID = isWeekly ? "3p-weekly" : (isFiveHour ? "3p-5h" : "3p-5h")
        } else if groupLower.contains("gemini models") || classificationContext == "gemini" {
            matchedKnownID = isWeekly ? "gemini-weekly" : (isFiveHour ? "gemini-5h" : "gemini-5h")
        } else {
            matchedKnownID = nil
        }

        if let knownID = matchedKnownID, let def = AppConfig.modelDefinition(for: knownID) {
            return QuotaBucketDescriptor(
                id: knownID,
                displayName: def.displayName,
                shortLabel: def.shortLabel,
                groupMembersHint: hint
            )
        }

        // Generic dynamic fallback for any new quota group introduced by Google in the future.
        let slugSource = !nonGenericID.isEmpty ? nonGenericID : (!trimmedGroup.isEmpty ? trimmedGroup : trimmedBucketName)
        var baseSlug = slugifyIdentifier(slugSource)
        for suffix in ["-wtu-weekly", "-weekly", "-5h", "-limit"] where baseSlug.hasSuffix(suffix) {
            baseSlug = String(baseSlug.dropLast(suffix.count))
        }
        if baseSlug.isEmpty {
            baseSlug = slugifyIdentifier(trimmedID.isEmpty ? trimmedGroup : trimmedID)
        }
        guard !baseSlug.isEmpty else { return nil }

        let dynamicID: String
        if isWeekly && !baseSlug.hasSuffix("-weekly") {
            dynamicID = "\(baseSlug)-weekly"
        } else if isFiveHour && !baseSlug.hasSuffix("-5h") {
            dynamicID = "\(baseSlug)-5h"
        } else {
            dynamicID = baseSlug
        }

        let displayName = deriveDynamicDisplayName(
            groupName: trimmedGroup.isEmpty ? trimmedBucketName : trimmedGroup,
            bucketID: dynamicID,
            isWeekly: isWeekly,
            isFiveHour: isFiveHour
        )
        let shortLabel = deriveShortLabel(id: dynamicID, displayName: displayName)
        return QuotaBucketDescriptor(
            id: dynamicID,
            displayName: displayName,
            shortLabel: shortLabel,
            groupMembersHint: hint
        )
    }

    private static func extractGroupMembersHint(from rawDescription: String?) -> String? {
        guard let trimmed = rawDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let prefixes = ["Models within this group:", "models within this group:"]
        for prefix in prefixes {
            if let range = trimmed.range(of: prefix, options: [.anchored, .caseInsensitive]) {
                let tail = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return tail.isEmpty ? nil : tail
            }
        }
        return nil
    }

    private static func deriveDynamicDisplayName(groupName: String, bucketID: String, isWeekly: Bool, isFiveHour: Bool) -> String {
        let baseLabel: String
        if !groupName.isEmpty && !groupName.lowercased().contains("limit") {
            baseLabel = groupName
                .replacingOccurrences(of: " Models", with: "")
                .replacingOccurrences(of: " models", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            baseLabel = bucketID
                .replacingOccurrences(of: "-weekly", with: "")
                .replacingOccurrences(of: "-5h", with: "")
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
        let cleanBase = baseLabel.isEmpty ? bucketID : baseLabel
        if isWeekly || bucketID.hasSuffix("-weekly") {
            return "\(cleanBase) (Tuần)"
        }
        if isFiveHour || bucketID.hasSuffix("-5h") {
            return "\(cleanBase) (5 giờ)"
        }
        return cleanBase
    }

    private static func slugifyIdentifier(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet.alphanumerics
        var parts: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            parts.append(current)
        }
        return parts.joined(separator: "-")
    }

    /// Maps backend bucket IDs, physical model IDs, or display names into a canonical quota bucket.
    public static func canonicalModelID(modelID: String?, displayName: String? = nil) -> String? {
        let rawID = (modelID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawID.hasPrefix("tab_") {
            return nil
        }

        switch rawID {
        case "gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly", "argon-weekly", "carbon-5h", "carbon-weekly":
            return rawID
        case "gemini-argon-wtu-weekly":
            return "argon-weekly"
        case "gemini-carbon-5h":
            return "carbon-5h"
        case "gemini-carbon-wtu-weekly":
            return "carbon-weekly"
        default:
            break
        }

        let combined = "\(rawID) \(displayName ?? "")".lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            return nil
        }
        if combined.contains("claude") || combined.contains("sonnet") || combined.contains("opus") || combined.contains("gpt") || combined.contains("openai") || combined.contains("3p") {
            return (combined.contains("week") || combined.contains("7d")) ? "3p-weekly" : "3p-5h"
        }
        if combined.contains("gemini")
            || combined.contains("orchestrator")
            || combined.contains("hydrogen")
            || combined.contains("neon")
            || combined.contains("carbon")
            || combined.contains("argon")
            || combined.contains("flash")
            || combined.contains("pro") {
            return (combined.contains("week") || combined.contains("7d")) ? "gemini-weekly" : "gemini-5h"
        }
        return nil
    }

    /// Maps a model invocation to all shared Dashboard quota buckets it consumes (both 5h and weekly windows).
    public static func canonicalBucketIDs(modelID: String?, displayName: String? = nil) -> [String] {
        guard let primary = canonicalModelID(modelID: modelID, displayName: displayName) else {
            return []
        }
        switch primary {
        case "3p-5h", "3p-weekly":
            return ["3p-5h", "3p-weekly"]
        case "gemini-5h", "gemini-weekly":
            return ["gemini-5h", "gemini-weekly"]
        case "carbon-5h", "carbon-weekly":
            return ["carbon-5h", "carbon-weekly"]
        default:
            return [primary]
        }
    }

    private static func formatCountdown(until targetDate: Date, from referenceDate: Date) -> String? {
        guard targetDate.timeIntervalSinceReferenceDate > referenceDate.timeIntervalSinceReferenceDate else {
            return nil
        }
        let seconds = max(0, Int(targetDate.timeIntervalSince(referenceDate)))
        let totalMinutes = seconds / 60
        if totalMinutes >= 1440 {
            let days = seconds / 86400
            let hours = (seconds % 86400) / 3600
            return "\(days)d\(hours)h"
        }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))m"
        }
        return "\(max(1, minutes))m"
    }

    /// Generates default usage rows for a given account tier.
    public static func defaultSet(for tier: AccountTier) -> [ModelUsage] {
        AppConfig.supportedModels.map { model in
            ModelUsage(
                id: model.id,
                displayName: model.displayName,
                turnsUsed: 0,
                turnLimit: tier.defaultTurnLimit(for: model.id)
            )
        }
    }
}
