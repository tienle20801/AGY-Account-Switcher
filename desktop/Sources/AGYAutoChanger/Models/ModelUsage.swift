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

        case (.pro, "gemini-5h"): return 150
        case (.pro, "gemini-weekly"): return 1000
        case (.pro, "3p-5h"): return 60
        case (.pro, "3p-weekly"): return 400
        case (.pro, "argon-weekly"): return 200

        case (.ultra, "gemini-5h"): return 450
        case (.ultra, "gemini-weekly"): return 3000
        case (.ultra, "3p-5h"): return 200
        case (.ultra, "3p-weekly"): return 1200
        case (.ultra, "argon-weekly"): return 600

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
        tokensUsed: Int? = nil
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
    }

    public var shortLabel: String {
        AppConfig.supportedModels.first(where: { $0.id == id })?.shortLabel ?? displayName
    }

    public var hasDashboardQuota: Bool {
        quotaRemainingFraction != nil
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
        guard let quotaResetAt else { return nil }
        return Self.formatCountdown(until: quotaResetAt, from: referenceDate)
    }

    public func remainingCooldownLabel(at referenceDate: Date = Date()) -> String? {
        guard let cooldownUntil else { return nil }
        return Self.formatCountdown(until: cooldownUntil, from: referenceDate)
    }

    /// Maps backend bucket IDs, model IDs, or display names into the primary canonical quota bucket (`gemini-5h`, `gemini-weekly`, `3p-5h`, `3p-weekly`).
    public static func canonicalModelID(modelID: String?, displayName: String? = nil) -> String? {
        let rawID = (modelID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch rawID {
        case "gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly", "argon-weekly":
            return rawID
        default:
            break
        }

        let combined = "\(rawID) \(displayName ?? "")".lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            return nil
        }
        if combined.contains("argon") {
            return "argon-weekly"
        }
        if combined.contains("claude") || combined.contains("sonnet") || combined.contains("opus") || combined.contains("gpt") || combined.contains("openai") || combined.contains("3p") {
            return combined.contains("week") ? "3p-weekly" : "3p-5h"
        }
        if combined.contains("gemini") || combined.contains("orchestrator") || combined.contains("hydrogen") || combined.contains("flash") || combined.contains("pro") {
            return combined.contains("week") ? "gemini-weekly" : "gemini-5h"
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
