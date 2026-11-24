import Foundation

// MARK: - Smart Auto-Switch Persistent Runtime State (No Secrets / No Emails)

/// Persisted in `~/.agy-switcher/auto_switch_state.json`. Contains only UUIDs and status flags.
public struct AutoSwitchRuntimeState: Codable, Sendable, Equatable {
    public var cancelledSourceAccountIDs: Set<UUID>
    public var pausedDueToFailure: Bool
    public var lastFailureReason: String?
    public var inProgressTargetAccountID: UUID?
    public var lastAutoSwitchedAccountID: UUID?

    public init(
        cancelledSourceAccountIDs: Set<UUID> = [],
        pausedDueToFailure: Bool = false,
        lastFailureReason: String? = nil,
        inProgressTargetAccountID: UUID? = nil,
        lastAutoSwitchedAccountID: UUID? = nil
    ) {
        self.cancelledSourceAccountIDs = cancelledSourceAccountIDs
        self.pausedDueToFailure = pausedDueToFailure
        self.lastFailureReason = lastFailureReason
        self.inProgressTargetAccountID = inProgressTargetAccountID
        self.lastAutoSwitchedAccountID = lastAutoSwitchedAccountID
    }
}

// MARK: - Auto-Switch Evaluation Result & UI Banner State

public enum AutoSwitchDecision: Sendable, Equatable {
    case none
    case pausedByFailure(String)
    case suppressedByCancellation(sourceID: UUID)
    case waitingForIdle(
        source: AccountProfile,
        target: AccountProfile,
        triggeredModelLabel: String,
        remainingPercent: Int,
        busyReason: String
    )
    case readyToSwitch(
        source: AccountProfile,
        target: AccountProfile,
        triggeredModelLabel: String,
        remainingPercent: Int
    )
    case noEligibleBackup(
        source: AccountProfile,
        triggeredModelLabel: String,
        remainingPercent: Int
    )
}

public enum AutoSwitchBannerState: Sendable, Equatable {
    case waitingForIdle(
        sourceID: UUID,
        target: AccountProfile,
        triggeredModelLabel: String,
        remainingPercent: Int,
        busyReason: String
    )
    case pausedByFailure(reason: String)
    case noEligibleBackup(
        sourceID: UUID,
        triggeredModelLabel: String,
        remainingPercent: Int,
        minBackupPercent: Int
    )
}

// MARK: - Smart Auto-Switch Coordinator

/// Pure, deterministic evaluator for automatic low-quota account switching.
public final class SmartAutoSwitchService: Sendable {

    public init() {}

    /// Evaluates whether the active account should automatically switch to an eligible backup candidate.
    public func evaluate(
        accounts: [AccountProfile],
        policy: AutoSwitchPolicy,
        state: AutoSwitchRuntimeState,
        activityState: AGYActivityState,
        hasSnapshot: (AccountProfile) -> Bool,
        maxQuotaAgeSeconds: TimeInterval = AppConfig.autoSwitchMaxQuotaAgeSeconds,
        referenceDate: Date = Date()
    ) -> (decision: AutoSwitchDecision, updatedState: AutoSwitchRuntimeState) {
        var nextState = state

        guard policy.isEnabled else {
            return (.none, nextState)
        }

        if nextState.pausedDueToFailure {
            return (.pausedByFailure(nextState.lastFailureReason ?? "Lần chuyển tự động trước gặp lỗi."), nextState)
        }

        guard let sourceIndex = accounts.firstIndex(where: { $0.isActive }) else {
            return (.none, nextState)
        }
        let source = accounts[sourceIndex]
        guard !source.isDisabled else {
            return (.none, nextState)
        }

        // Collect fresh, observed buckets matching the user's monitored bucket configuration.
        let observedSourceBuckets = observedFreshBuckets(
            for: source,
            policy: policy,
            maxQuotaAgeSeconds: maxQuotaAgeSeconds,
            referenceDate: referenceDate
        )
        guard !observedSourceBuckets.isEmpty else {
            return (.none, nextState)
        }

        // Auto-clear cancellation once all observed monitored buckets recover to >= minBackupQuotaPercent.
        if nextState.cancelledSourceAccountIDs.contains(source.id) {
            let allRecovered = observedSourceBuckets.allSatisfy { bucket in
                !bucket.isRateLimited(at: referenceDate)
                    && remainingPercent(of: bucket, at: referenceDate) >= policy.minBackupQuotaPercent
            }
            if allRecovered {
                nextState.cancelledSourceAccountIDs.remove(source.id)
            }
        }

        let triggeredBuckets = observedSourceBuckets.filter { bucket in
            remainingPercent(of: bucket, at: referenceDate) <= policy.triggerThresholdPercent
        }
        let shouldTrigger: Bool
        switch policy.triggerMatchMode {
        case .anySelected:
            shouldTrigger = !triggeredBuckets.isEmpty
        case .allSelected:
            shouldTrigger = triggeredBuckets.count == observedSourceBuckets.count
        }

        guard shouldTrigger,
              let lowestBucket = triggeredBuckets.min(by: { lhs, rhs in
                  remainingPercent(of: lhs, at: referenceDate) < remainingPercent(of: rhs, at: referenceDate)
              }) else {
            return (.none, nextState)
        }

        let lowestRemaining = remainingPercent(of: lowestBucket, at: referenceDate)

        if nextState.cancelledSourceAccountIDs.contains(source.id) {
            return (.suppressedByCancellation(sourceID: source.id), nextState)
        }

        guard let backup = selectBackupCandidate(
            accounts: accounts,
            sourceIndex: sourceIndex,
            policy: policy,
            hasSnapshot: hasSnapshot,
            maxQuotaAgeSeconds: maxQuotaAgeSeconds,
            referenceDate: referenceDate
        ) else {
            return (
                .noEligibleBackup(
                    source: source,
                    triggeredModelLabel: lowestBucket.shortLabel,
                    remainingPercent: lowestRemaining
                ),
                nextState
            )
        }

        switch policy.timingMode {
        case .immediateAtThreshold:
            return (
                .readyToSwitch(
                    source: source,
                    target: backup,
                    triggeredModelLabel: lowestBucket.shortLabel,
                    remainingPercent: lowestRemaining
                ),
                nextState
            )
        case .waitForIdle:
            switch activityState {
            case .idle:
                return (
                    .readyToSwitch(
                        source: source,
                        target: backup,
                        triggeredModelLabel: lowestBucket.shortLabel,
                        remainingPercent: lowestRemaining
                    ),
                    nextState
                )
            case .busy(let reason):
                return (
                    .waitingForIdle(
                        source: source,
                        target: backup,
                        triggeredModelLabel: lowestBucket.shortLabel,
                        remainingPercent: lowestRemaining,
                        busyReason: reason
                    ),
                    nextState
                )
            }
        }
    }

    // MARK: - Candidate Eligibility & Ordering

    private func selectBackupCandidate(
        accounts: [AccountProfile],
        sourceIndex: Int,
        policy: AutoSwitchPolicy,
        hasSnapshot: (AccountProfile) -> Bool,
        maxQuotaAgeSeconds: TimeInterval,
        referenceDate: Date
    ) -> AccountProfile? {
        let sourceID = accounts[sourceIndex].id
        let orderedCandidates: [AccountProfile]
        switch policy.selectionStrategy {
        case .priorityOrder:
            orderedCandidates = accounts
        case .roundRobin:
            let tail = accounts.indices.filter { $0 > sourceIndex }.map { accounts[$0] }
            let head = accounts.indices.filter { $0 < sourceIndex }.map { accounts[$0] }
            orderedCandidates = tail + head
        }

        let explicitFilter = Set(policy.candidateAccountIDs)
        for candidate in orderedCandidates {
            guard candidate.id != sourceID,
                  !candidate.isDisabled,
                  hasSnapshot(candidate) else {
                continue
            }
            if !explicitFilter.isEmpty && !explicitFilter.contains(candidate.id) {
                continue
            }

            let observedBuckets = observedFreshBuckets(
                for: candidate,
                policy: policy,
                maxQuotaAgeSeconds: maxQuotaAgeSeconds,
                referenceDate: referenceDate
            )
            // Require at least one valid fresh observation and ALL observed monitored buckets >= minBackupQuotaPercent.
            guard !observedBuckets.isEmpty else { continue }
            let allHealthy = observedBuckets.allSatisfy { bucket in
                guard !bucket.isRateLimited(at: referenceDate),
                      remainingPercent(of: bucket, at: referenceDate) >= policy.minBackupQuotaPercent else {
                    return false
                }
                // Safety guard: if user monitors only a 5h bucket (e.g. `gemini-5h`), still reject candidates
                // whose fresh sibling `-weekly` bucket is completely rate-limited (0%).
                if bucket.id.hasSuffix("-5h") {
                    let weeklyID = String(bucket.id.dropLast(3)) + "-weekly"
                    if let weeklySibling = freshObservedBucket(
                        id: weeklyID,
                        in: candidate,
                        maxQuotaAgeSeconds: maxQuotaAgeSeconds,
                        referenceDate: referenceDate
                    ), weeklySibling.isRateLimited(at: referenceDate) {
                        return false
                    }
                }
                return true
            }
            if allHealthy {
                return candidate
            }
        }

        return nil
    }

    private func observedFreshBuckets(
        for account: AccountProfile,
        policy: AutoSwitchPolicy,
        maxQuotaAgeSeconds: TimeInterval,
        referenceDate: Date
    ) -> [ModelUsage] {
        account.modelUsages.filter { usage in
            guard policy.includesBucket(usage.id),
                  isFreshObservedBucket(usage, account: account, maxQuotaAgeSeconds: maxQuotaAgeSeconds, referenceDate: referenceDate) else {
                return false
            }
            return true
        }
    }

    private func freshObservedBucket(
        id: String,
        in account: AccountProfile,
        maxQuotaAgeSeconds: TimeInterval,
        referenceDate: Date
    ) -> ModelUsage? {
        guard let usage = account.modelUsages.first(where: { $0.id == id }),
              isFreshObservedBucket(usage, account: account, maxQuotaAgeSeconds: maxQuotaAgeSeconds, referenceDate: referenceDate) else {
            return nil
        }
        return usage
    }

    private func isFreshObservedBucket(
        _ usage: ModelUsage,
        account: AccountProfile,
        maxQuotaAgeSeconds: TimeInterval,
        referenceDate: Date
    ) -> Bool {
        guard !usage.isUnknownObservation else {
            return false
        }
        if usage.hasDashboardQuota {
            // Reject stale Dashboard observations older than maxQuotaAgeSeconds.
            if let syncedAt = usage.quotaSyncedAt ?? account.lastDashboardSyncAt {
                let age = referenceDate.timeIntervalSince(syncedAt)
                if age > maxQuotaAgeSeconds {
                    return false
                }
            }
            // Reject expired reset windows that have not been freshly confirmed by the server.
            if let resetAt = usage.quotaResetAt,
               referenceDate.timeIntervalSinceReferenceDate >= resetAt.timeIntervalSinceReferenceDate {
                return false
            }
        }
        return true
    }

    private func remainingPercent(of usage: ModelUsage, at referenceDate: Date) -> Int {
        Int((usage.remainingFractionValue(at: referenceDate) * 100.0).rounded())
    }
}
