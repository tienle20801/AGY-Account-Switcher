import Foundation

// MARK: - Weekly Quota Warmup Persistent Runtime State (No Secrets / No Emails)

/// Single deduplicated warmup record persisted in `~/.agy-switcher/weekly_warmup_state.json`.
public struct WeeklyWarmupHistoryRecord: Codable, Sendable, Equatable {
    public let accountID: UUID
    public let group: WeeklyWarmupGroup
    public let bucketID: String
    public let cycleKey: String
    public let modelID: String
    public let warmedAt: Date

    public init(
        accountID: UUID,
        group: WeeklyWarmupGroup,
        bucketID: String,
        cycleKey: String,
        modelID: String,
        warmedAt: Date
    ) {
        self.accountID = accountID
        self.group = group
        self.bucketID = bucketID
        self.cycleKey = cycleKey
        self.modelID = modelID
        self.warmedAt = warmedAt
    }
}

/// Persisted in `~/.agy-switcher/weekly_warmup_state.json` (`0600`). Contains only UUIDs, bucket keys, model IDs, and timestamps.
public struct WeeklyWarmupRuntimeState: Codable, Sendable, Equatable {
    public var records: [String: WeeklyWarmupHistoryRecord]
    public var pausedDueToStorageError: Bool
    public var lastError: String?

    enum CodingKeys: String, CodingKey {
        case records
        case pausedDueToStorageError
        case lastError
    }

    public init(
        records: [String: WeeklyWarmupHistoryRecord] = [:],
        pausedDueToStorageError: Bool = false,
        lastError: String? = nil
    ) {
        self.records = records
        self.pausedDueToStorageError = pausedDueToStorageError
        self.lastError = lastError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.records = try container.decodeIfPresent([String: WeeklyWarmupHistoryRecord].self, forKey: .records) ?? [:]
        self.pausedDueToStorageError = try container.decodeIfPresent(Bool.self, forKey: .pausedDueToStorageError) ?? false
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

// MARK: - Warmup Candidate

public struct WeeklyWarmupCandidate: Sendable, Equatable {
    public let accountID: UUID
    public let accountName: String
    public let group: WeeklyWarmupGroup
    public let bucketID: String
    public let cycleKey: String
    public let resetAt: Date?
    public let groupMembersHint: String?

    public var displayTitle: String {
        bucketID.hasSuffix("-5h") ? group.fiveHourTitle : group.title
    }

    public init(
        accountID: UUID,
        accountName: String,
        group: WeeklyWarmupGroup,
        bucketID: String,
        cycleKey: String,
        resetAt: Date?,
        groupMembersHint: String? = nil
    ) {
        self.accountID = accountID
        self.accountName = accountName
        self.group = group
        self.bucketID = bucketID
        self.cycleKey = cycleKey
        self.resetAt = resetAt
        self.groupMembersHint = groupMembersHint
    }
}

// MARK: - Weekly Quota Warmup Service

/// Pure, deterministic eligibility & history deduplication evaluator for Quota Warmup (7-day weekly & optional 5h rolling cycle).
/// Strictly warms ONLY shared `gemini-*` and `3p-*` buckets; never touches `argon-weekly` or `carbon-*`.
public struct WeeklyWarmupService: Sendable {

    private static let allowedBucketIDs: Set<String> = Set(
        WeeklyWarmupGroup.allCases.flatMap { [$0.bucketID, $0.fiveHourBucketID] }
    )

    public init() {}

    /// Builds a stable, minute-bucketed UTC deduplication key per `(accountID, bucketID, cycle)`.
    /// When `resetAt` is `nil`, buckets 5h pools by 5-hour UTC slot and weekly pools by ISO 8601 week.
    public func normalizedCycleKey(
        accountID: UUID,
        bucketID: String,
        resetAt: Date?,
        referenceDate: Date = Date()
    ) -> String {
        let prefix = "\(accountID.uuidString.lowercased()):\(bucketID)"
        guard let utc = TimeZone(secondsFromGMT: 0) else {
            return "\(prefix):idle"
        }

        if let resetAt {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = utc
            let comps = gregorian.dateComponents([.year, .month, .day, .hour, .minute], from: resetAt)
            let formatted = String(
                format: "%04d-%02d-%02dT%02d:%02dZ",
                comps.year ?? 1970,
                comps.month ?? 1,
                comps.day ?? 1,
                comps.hour ?? 0,
                comps.minute ?? 0
            )
            return "\(prefix):reset-\(formatted)"
        }

        if bucketID.hasSuffix("-5h") {
            let slot = Int(floor(referenceDate.timeIntervalSince1970 / (5 * 3_600)))
            return "\(prefix):idle-5h-\(slot)"
        }

        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = utc
        let comps = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: referenceDate)
        let weekStamp = String(
            format: "idle-%04d-W%02d",
            comps.yearForWeekOfYear ?? 1970,
            comps.weekOfYear ?? 1
        )
        return "\(prefix):\(weekStamp)"
    }

    /// Removes warmup history entries older than `retentionSeconds` (default 30 days).
    public func pruneExpiredHistory(
        in state: WeeklyWarmupRuntimeState,
        retentionSeconds: TimeInterval = AppConfig.weeklyWarmupHistoryRetentionSeconds,
        referenceDate: Date = Date()
    ) -> WeeklyWarmupRuntimeState {
        var next = state
        next.records = state.records.filter { _, record in
            referenceDate.timeIntervalSince(record.warmedAt) <= retentionSeconds
        }
        return next
    }

    /// Checks whether a single weekly or 5h bucket is strictly eligible for warmup.
    public func isBucketEligibleForWarmup(
        _ usage: ModelUsage,
        referenceDate: Date = Date()
    ) -> Bool {
        guard Self.allowedBucketIDs.contains(usage.id) else {
            return false
        }
        guard let rawFraction = usage.quotaRemainingFraction,
              rawFraction >= AppConfig.weeklyWarmupMinRemainingFraction else {
            return false
        }
        guard !usage.isRateLimited(at: referenceDate) else {
            return false
        }

        if let resetAt = usage.quotaResetAt, !usage.hasUnstartedResetPlaceholder() {
            let elapsed = referenceDate.timeIntervalSince(resetAt)
            let maxElapsed = usage.id.hasSuffix("-5h")
                ? AppConfig.fiveHourWarmupMaxElapsedResetSeconds
                : AppConfig.weeklyWarmupMaxElapsedResetSeconds
            // Future reset timer is already ticking -> skip; elapsed >= maxElapsed -> ambiguous/stale -> skip.
            guard elapsed >= 0 && elapsed < maxElapsed else {
                return false
            }
        }
        return true
    }

    /// Finds all eligible `(account, bucket)` warmup candidates in user list order.
    /// When both weekly and 5h buckets are unstarted for the same `(account, group)`, only weekly is emitted since one request starts both timers.
    public func findEligibleCandidates(
        accounts: [AccountProfile],
        policy: WeeklyWarmupPolicy,
        state: WeeklyWarmupRuntimeState,
        onlyAccountID: UUID? = nil,
        ignoreAutoEnabledFlag: Bool = false,
        ignoreBackupOnlyFilter: Bool = false,
        hasSnapshot: (AccountProfile) -> Bool,
        failureCooldowns: [String: Date] = [:],
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> [WeeklyWarmupCandidate] {
        guard !state.pausedDueToStorageError else {
            return []
        }
        guard policy.isEnabled || ignoreAutoEnabledFlag else {
            return []
        }

        let targetGroups = policy.enabledGroups
        guard !targetGroups.isEmpty else {
            return []
        }

        let withinFiveHourWindow = ignoreAutoEnabledFlag
            || policy.isWithinFiveHourActiveWindow(at: referenceDate, calendar: calendar)

        var candidates: [WeeklyWarmupCandidate] = []
        for account in accounts {
            if let onlyAccountID, account.id != onlyAccountID {
                continue
            }
            guard !account.isDisabled else {
                continue
            }
            guard hasSnapshot(account) else {
                continue
            }
            if policy.backupAccountsOnly && !ignoreBackupOnlyFilter && account.isActive {
                continue
            }

            for group in targetGroups {
                // 1. Try 7-day weekly bucket first; if warmed/eligible, do not emit duplicate 5h candidate for this group.
                if let weeklyUsage = account.modelUsages.first(where: { $0.id == group.bucketID }),
                   let weeklyCandidate = makeCandidateIfEligible(
                       account: account,
                       group: group,
                       usage: weeklyUsage,
                       state: state,
                       ignoreAutoEnabledFlag: ignoreAutoEnabledFlag,
                       failureCooldowns: failureCooldowns,
                       referenceDate: referenceDate
                   ) {
                    candidates.append(weeklyCandidate)
                    continue
                }

                // 2. Also warm 5h cycle when inside active hours (or manual) and sibling weekly quota isn't nearly empty.
                guard withinFiveHourWindow else {
                    continue
                }
                if let weeklyUsage = account.modelUsages.first(where: { $0.id == group.bucketID }),
                   weeklyUsage.hasDashboardQuota {
                    let weeklyDepleted = weeklyUsage.isRateLimited(at: referenceDate)
                        || weeklyUsage.remainingFractionValue(at: referenceDate) <= AppConfig.fiveHourWarmupMinWeeklySiblingFraction
                    if weeklyDepleted {
                        continue
                    }
                }
                if let fiveHourUsage = account.modelUsages.first(where: { $0.id == group.fiveHourBucketID }),
                   let fiveHourCandidate = makeCandidateIfEligible(
                       account: account,
                       group: group,
                       usage: fiveHourUsage,
                       state: state,
                       ignoreAutoEnabledFlag: ignoreAutoEnabledFlag,
                       failureCooldowns: failureCooldowns,
                       referenceDate: referenceDate
                   ) {
                    candidates.append(fiveHourCandidate)
                }
            }
        }

        return candidates
    }

    private func makeCandidateIfEligible(
        account: AccountProfile,
        group: WeeklyWarmupGroup,
        usage: ModelUsage,
        state: WeeklyWarmupRuntimeState,
        ignoreAutoEnabledFlag: Bool,
        failureCooldowns: [String: Date],
        referenceDate: Date
    ) -> WeeklyWarmupCandidate? {
        guard isBucketEligibleForWarmup(usage, referenceDate: referenceDate) else {
            return nil
        }

        let effectiveResetAt = usage.hasUnstartedResetPlaceholder() ? nil : usage.quotaResetAt
        let cycleKey = normalizedCycleKey(
            accountID: account.id,
            bucketID: usage.id,
            resetAt: effectiveResetAt,
            referenceDate: referenceDate
        )

        if let existingRecord = state.records[cycleKey] {
            // Self-heal stale unverified `idle-*` records if the server later confirms the timer is still unstarted.
            let syncedAfterRecord = (usage.quotaSyncedAt ?? referenceDate).timeIntervalSince(existingRecord.warmedAt) > 60
            let stillUnstarted = usage.hasUnstartedResetPlaceholder() && (ignoreAutoEnabledFlag || syncedAfterRecord)
            if !stillUnstarted {
                return nil
            }
        }
        if let retryAfter = failureCooldowns[cycleKey],
           retryAfter.timeIntervalSinceReferenceDate > referenceDate.timeIntervalSinceReferenceDate {
            return nil
        }

        return WeeklyWarmupCandidate(
            accountID: account.id,
            accountName: account.displayName,
            group: group,
            bucketID: usage.id,
            cycleKey: cycleKey,
            resetAt: usage.quotaResetAt,
            groupMembersHint: usage.groupMembersHint
        )
    }

    /// Returns a helpful Vietnamese explanation when no candidates matched a manual Warmup trigger.
    public func explainNoEligibleCandidates(
        accounts: [AccountProfile],
        policy: WeeklyWarmupPolicy,
        onlyAccountID: UUID?,
        hasSnapshot: (AccountProfile) -> Bool,
        referenceDate: Date = Date()
    ) -> String {
        let targetGroups = policy.enabledGroups
        var hasFullButAlreadyRunningTimer = false
        for account in accounts {
            if let onlyAccountID, account.id != onlyAccountID { continue }
            guard !account.isDisabled, hasSnapshot(account) else { continue }
            if policy.backupAccountsOnly && onlyAccountID == nil && account.isActive { continue }
            for group in targetGroups {
                for bucketID in [group.bucketID, group.fiveHourBucketID] {
                    guard let usage = account.modelUsages.first(where: { $0.id == bucketID }) else { continue }
                    if usage.remainingPercentageInt == 100,
                       !usage.hasUnstartedResetPlaceholder(),
                       let resetAt = usage.quotaResetAt,
                       resetAt > referenceDate {
                        hasFullButAlreadyRunningTimer = true
                    }
                }
            }
        }
        if hasFullButAlreadyRunningTimer {
            return "Các bucket hiển thị 100% đều đã bắt đầu đếm ngược từ trước (không cần Warmup lại)."
        }
        return "Không có bucket nào đang ở mức 100% chờ kích hoạt chu kỳ mới."
    }

    /// Records a successfully warmed candidate into state and prunes expired records.
    public func recordSuccess(
        for candidate: WeeklyWarmupCandidate,
        modelID: String,
        into state: WeeklyWarmupRuntimeState,
        at date: Date = Date()
    ) -> WeeklyWarmupRuntimeState {
        var next = pruneExpiredHistory(in: state, referenceDate: date)
        next.records[candidate.cycleKey] = WeeklyWarmupHistoryRecord(
            accountID: candidate.accountID,
            group: candidate.group,
            bucketID: candidate.bucketID,
            cycleKey: candidate.cycleKey,
            modelID: modelID,
            warmedAt: date
        )
        next.lastError = nil
        return next
    }
}
