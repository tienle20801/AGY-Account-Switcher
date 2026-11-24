import Foundation

// MARK: - Cloud Code Dashboard Snapshot

public struct ModelDashboardQuota: Sendable, Equatable {
    public let canonicalModelID: String
    public let displayName: String?
    public let shortLabel: String?
    public let groupMembersHint: String?
    public let remainingFraction: Double
    public let resetAt: Date?

    public init(
        canonicalModelID: String,
        displayName: String? = nil,
        shortLabel: String? = nil,
        groupMembersHint: String? = nil,
        remainingFraction: Double,
        resetAt: Date? = nil
    ) {
        self.canonicalModelID = canonicalModelID
        self.displayName = displayName
        self.shortLabel = shortLabel
        self.groupMembersHint = groupMembersHint
        self.remainingFraction = min(1.0, max(0.0, remainingFraction))
        self.resetAt = resetAt
    }
}

public struct CloudCodeDashboardSnapshot: Sendable, Equatable {
    public let detectedTier: AccountTier?
    public let projectID: String?
    public let quotasByModel: [String: ModelDashboardQuota]
    public let syncedAt: Date

    public init(
        detectedTier: AccountTier? = nil,
        projectID: String? = nil,
        quotasByModel: [String: ModelDashboardQuota] = [:],
        syncedAt: Date = Date()
    ) {
        self.detectedTier = detectedTier
        self.projectID = projectID
        self.quotasByModel = quotasByModel
        self.syncedAt = syncedAt
    }
}

public struct AdvertisedModelEntry: Sendable, Equatable {
    public let modelID: String
    public let displayName: String?
    public let disabled: Bool

    public init(modelID: String, displayName: String? = nil, disabled: Bool = false) {
        self.modelID = modelID
        self.displayName = displayName
        self.disabled = disabled
    }
}

public enum WarmupTransportError: LocalizedError, Sendable, Equatable {
    case noAdvertisedModel(WeeklyWarmupGroup)
    case httpRejected(statusCode: Int, detail: String)
    case transportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAdvertisedModel(let group):
            return "Tài khoản không có model phù hợp được mở cho nhóm \(group.title)."
        case .httpRejected(let statusCode, let detail):
            return detail.isEmpty ? "Máy chủ từ chối warmup (HTTP \(statusCode))." : "Máy chủ từ chối warmup (HTTP \(statusCode)): \(detail)"
        case .transportFailed(let message):
            return "Lỗi kết nối khi gửi warmup: \(message)"
        }
    }
}

// MARK: - Cloud Code Quota Service

/// Syncs live Antigravity model remaining fractions, reset timestamps, and subscription tier
/// using the user's own OAuth bearer token against `daily-cloudcode-pa` / `cloudcode-pa`.
public final class CloudCodeQuotaService: Sendable {

    private struct LoadCodeAssistPayload: Decodable {
        struct TierInfo: Decodable {
            let id: String?
            let name: String?
        }

        let currentTier: TierInfo?
        let paidTier: TierInfo?
        let g1Tier: String?
        let cloudaicompanionProject: String?
    }

    private struct RetrieveUserQuotaSummaryPayload: Decodable {
        struct QuotaBucket: Decodable {
            let bucketId: String?
            let displayName: String?
            let description: String?
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?
            let disabled: Bool?
        }

        struct QuotaGroup: Decodable {
            let displayName: String?
            let description: String?
            let buckets: [QuotaBucket]?
        }

        let buckets: [QuotaBucket]?
        let groups: [QuotaGroup]?
    }

    private struct FetchAvailableModelsPayload: Decodable {
        struct ServerQuotaInfo: Decodable {
            let remainingFraction: Double?
            let resetTime: String?
        }

        struct ServerModelDetails: Decodable {
            let displayName: String?
            let model: String?
            let disabled: Bool?
            let quotaInfo: ServerQuotaInfo?
        }

        let models: [String: ServerModelDetails]?
    }

    private struct RetrieveUserQuotaPayload: Decodable {
        struct UserQuotaBucket: Decodable {
            let modelId: String?
            let remainingFraction: Double?
            let resetTime: String?
        }

        let buckets: [UserQuotaBucket]?
    }

    public static var isAgyCLIAvailable: Bool {
        resolveAgyBinaryPath() != nil
    }

    public init() {}

    /// Fetches live quota + tier metadata from Google Cloud Code Assist REST endpoints in < 1s.
    /// Dedicated `argon-weekly` is fetched separately via `fetchAgyCLIUsageQuotas()` when `isAgyCLIAvailable` is true.
    public func fetchDashboardSnapshot(bearerToken: String, allowCLIUsage: Bool = false) async -> CloudCodeDashboardSnapshot? {
        for baseURL in AppConfig.cloudCodeBaseURLs {
            let loadAssistData = await postJSON(
                urlString: "\(baseURL)/v1internal:loadCodeAssist",
                body: [
                    "metadata": [
                        "ideType": "ANTIGRAVITY",
                        "platform": "DARWIN_ARM64",
                        "pluginType": "GEMINI",
                        "ideVersion": "2.32.0"
                    ]
                ],
                bearerToken: bearerToken
            )

            let parsedAssist = loadAssistData.flatMap { parseLoadCodeAssist(from: $0) }
            let projectID: String
            if let assistProj = parsedAssist?.projectID, !assistProj.isEmpty {
                projectID = assistProj
            } else {
                projectID = AppConfig.defaultCloudCodeProject
            }
            let projectBody: [String: Any] = ["project": projectID]

            let quotaSummaryData = await postJSON(
                urlString: "\(baseURL)/v1internal:retrieveUserQuotaSummary",
                body: projectBody,
                bearerToken: bearerToken
            )
            let summarySnapshot = quotaSummaryData.flatMap {
                parseDashboardSnapshot(
                    fromQuotaSummaryData: $0,
                    loadCodeAssistData: loadAssistData,
                    syncedAt: Date(),
                    projectSharedGeminiFallback: false
                )
            }

            // Fast path: summary already includes all active server groups.
            if let summarySnapshot, !summarySnapshot.quotasByModel.isEmpty {
                return summarySnapshot
            }

            // Summary unavailable or empty: query fetchAvailableModels + retrieveUserQuota in parallel.
            async let modelsDataTask = postJSON(
                urlString: "\(baseURL)/v1internal:fetchAvailableModels",
                body: projectBody,
                bearerToken: bearerToken
            )
            async let userQuotaDataTask = postJSON(
                urlString: "\(baseURL)/v1internal:retrieveUserQuota",
                body: projectBody,
                bearerToken: bearerToken
            )
            let (modelsData, userQuotaData) = await (modelsDataTask, userQuotaDataTask)

            let modelsSnapshot = parseDashboardSnapshot(
                fromModelsData: modelsData,
                userQuotaData: userQuotaData,
                loadCodeAssistData: loadAssistData,
                syncedAt: Date()
            )

            var combinedQuotas: [String: ModelDashboardQuota] = summarySnapshot?.quotasByModel ?? [:]
            if let modelsSnapshot {
                for (key, value) in modelsSnapshot.quotasByModel where combinedQuotas[key] == nil {
                    combinedQuotas[key] = value
                }
            }

            let resolvedTier = summarySnapshot?.detectedTier ?? modelsSnapshot?.detectedTier
            let resolvedProjectID = summarySnapshot?.projectID ?? modelsSnapshot?.projectID
            if !combinedQuotas.isEmpty || resolvedTier != nil {
                return CloudCodeDashboardSnapshot(
                    detectedTier: resolvedTier,
                    projectID: resolvedProjectID,
                    quotasByModel: combinedQuotas,
                    syncedAt: summarySnapshot?.syncedAt ?? Date()
                )
            }
        }
        return nil
    }

    /// Parses `/v1internal:retrieveUserQuotaSummary` response buckets dynamically (`gemini-*`, `3p-*`, and any dedicated pools).
    public func parseDashboardSnapshot(
        fromQuotaSummaryData quotaSummaryData: Data,
        loadCodeAssistData: Data? = nil,
        syncedAt: Date = Date(),
        projectSharedGeminiFallback: Bool = false
    ) -> CloudCodeDashboardSnapshot? {
        let assist = loadCodeAssistData.flatMap { parseLoadCodeAssist(from: $0) }

        guard let decoded = try? JSONDecoder().decode(RetrieveUserQuotaSummaryPayload.self, from: quotaSummaryData) else {
            return nil
        }

        var allBuckets: [(groupName: String?, groupDescription: String?, bucket: RetrieveUserQuotaSummaryPayload.QuotaBucket)] =
            (decoded.buckets ?? []).map { (nil, nil, $0) }
        if let groups = decoded.groups {
            for group in groups {
                for bucket in group.buckets ?? [] {
                    allBuckets.append((group.displayName, group.description, bucket))
                }
            }
        }

        var aggregated: [String: ModelDashboardQuota] = [:]
        for (groupName, groupDescription, bucket) in allBuckets {
            if bucket.disabled == true {
                continue
            }

            guard let descriptor = ModelUsage.resolveQuotaBucketDescriptor(
                bucketID: bucket.bucketId,
                groupName: groupName,
                bucketName: bucket.displayName,
                window: bucket.window,
                groupDescription: groupDescription
            ) else {
                continue
            }

            let fraction: Double
            if let reported = bucket.remainingFraction {
                fraction = min(1.0, max(0.0, reported))
            } else if bucket.resetTime != nil {
                // Proto3 JSON omits 0.0 float values when resetTime is present.
                fraction = 0.0
            } else {
                continue
            }

            let resetDate = bucket.resetTime.flatMap { UsageTrackerService.parseISO8601($0) }
            if let existing = aggregated[descriptor.id] {
                if fraction < existing.remainingFraction {
                    aggregated[descriptor.id] = ModelDashboardQuota(
                        canonicalModelID: descriptor.id,
                        displayName: descriptor.displayName,
                        shortLabel: descriptor.shortLabel,
                        groupMembersHint: descriptor.groupMembersHint ?? existing.groupMembersHint,
                        remainingFraction: fraction,
                        resetAt: resetDate ?? existing.resetAt
                    )
                }
            } else {
                aggregated[descriptor.id] = ModelDashboardQuota(
                    canonicalModelID: descriptor.id,
                    displayName: descriptor.displayName,
                    shortLabel: descriptor.shortLabel,
                    groupMembersHint: descriptor.groupMembersHint,
                    remainingFraction: fraction,
                    resetAt: resetDate
                )
            }
        }

        guard !aggregated.isEmpty || assist?.tier != nil else {
            return nil
        }

        return CloudCodeDashboardSnapshot(
            detectedTier: assist?.tier,
            projectID: assist?.projectID,
            quotasByModel: aggregated,
            syncedAt: syncedAt
        )
    }

    /// Parses Cloud Code Assist JSON payloads (`fetchAvailableModels` + optional `retrieveUserQuota`)
    /// into normalized per-model remaining quotas and account tier.
    public func parseDashboardSnapshot(
        fromModelsData modelsData: Data?,
        userQuotaData: Data? = nil,
        loadCodeAssistData: Data? = nil,
        syncedAt: Date = Date()
    ) -> CloudCodeDashboardSnapshot? {
        let assist = loadCodeAssistData.flatMap { parseLoadCodeAssist(from: $0) }
        let decodedModels = modelsData.flatMap { try? JSONDecoder().decode(FetchAvailableModelsPayload.self, from: $0) }
        let decodedUserQuota = userQuotaData.flatMap { try? JSONDecoder().decode(RetrieveUserQuotaPayload.self, from: $0) }

        var mergedModels: [String: (displayName: String?, remainingFraction: Double?, resetTime: String?)] = [:]
        if let serverModels = decodedModels?.models {
            for (modelKey, details) in serverModels where details.disabled != true {
                let modelID = details.model ?? modelKey
                mergedModels[modelID] = (
                    displayName: details.displayName,
                    remainingFraction: details.quotaInfo?.remainingFraction,
                    resetTime: details.quotaInfo?.resetTime
                )
            }
        }

        if let quotaBuckets = decodedUserQuota?.buckets {
            for bucket in quotaBuckets {
                guard let modelID = bucket.modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !modelID.isEmpty else {
                    continue
                }
                let existing = mergedModels[modelID]
                mergedModels[modelID] = (
                    displayName: existing?.displayName,
                    remainingFraction: bucket.remainingFraction ?? existing?.remainingFraction,
                    resetTime: bucket.resetTime ?? existing?.resetTime
                )
            }
        }

        if mergedModels.isEmpty {
            if let assist, assist.tier != nil {
                return CloudCodeDashboardSnapshot(
                    detectedTier: assist.tier,
                    projectID: assist.projectID,
                    quotasByModel: [:],
                    syncedAt: syncedAt
                )
            }
            return nil
        }

        var aggregated: [String: ModelDashboardQuota] = [:]
        for (modelID, entry) in mergedModels {
            if modelID.lowercased().hasPrefix("tab_") {
                continue
            }
            guard entry.remainingFraction != nil || entry.resetTime != nil else {
                continue
            }

            // Proto3 JSON omits 0.0 float values; if resetTime is present alongside quotaInfo, remaining is 0.0.
            let fraction: Double
            if let reported = entry.remainingFraction {
                fraction = min(1.0, max(0.0, reported))
            } else {
                fraction = 0.0
            }

            guard let canonicalID = ModelUsage.canonicalModelID(
                modelID: modelID,
                displayName: entry.displayName
            ) else {
                continue
            }

            let resetDate = entry.resetTime.flatMap { UsageTrackerService.parseISO8601($0) }
            if let existing = aggregated[canonicalID] {
                if fraction < existing.remainingFraction {
                    aggregated[canonicalID] = ModelDashboardQuota(
                        canonicalModelID: canonicalID,
                        remainingFraction: fraction,
                        resetAt: resetDate ?? existing.resetAt
                    )
                }
            } else {
                aggregated[canonicalID] = ModelDashboardQuota(
                    canonicalModelID: canonicalID,
                    remainingFraction: fraction,
                    resetAt: resetDate
                )
            }
        }

        return CloudCodeDashboardSnapshot(
            detectedTier: assist?.tier,
            projectID: assist?.projectID,
            quotasByModel: aggregated,
            syncedAt: syncedAt
        )
    }

    /// Applies fetched server Dashboard quotas onto an account's `ModelUsage` array without wiping local turns or cooldowns.
    /// Automatically attaches new server-reported buckets and prunes retired extra buckets when syncing full snapshots.
    public func applyDashboardSnapshot(
        _ snapshot: CloudCodeDashboardSnapshot,
        into existing: [ModelUsage],
        currentTier: AccountTier,
        pruneUnreportedExtraBuckets: Bool = true
    ) -> (tier: AccountTier, usages: [ModelUsage]) {
        let resolvedTier = snapshot.detectedTier ?? currentTier
        var updated = ModelUsage.defaultSet(for: resolvedTier)
        let coreIDs = Set(updated.map(\.id))

        for idx in updated.indices {
            let modelID = updated[idx].id
            let prior = existing.first(where: { $0.id == modelID })
            updated[idx].turnsUsed = prior?.turnsUsed ?? 0
            updated[idx].lastUsedAt = prior?.lastUsedAt
            updated[idx].cooldownUntil = prior?.cooldownUntil
            updated[idx].tokensUsed = prior?.tokensUsed

            if let quota = snapshot.quotasByModel[modelID] {
                updated[idx].quotaRemainingFraction = quota.remainingFraction
                updated[idx].quotaResetAt = quota.resetAt
                updated[idx].quotaSyncedAt = snapshot.syncedAt
                updated[idx].groupMembersHint = quota.groupMembersHint ?? prior?.groupMembersHint
            } else {
                updated[idx].quotaRemainingFraction = prior?.quotaRemainingFraction
                updated[idx].quotaResetAt = prior?.quotaResetAt
                updated[idx].quotaSyncedAt = prior?.quotaSyncedAt
                updated[idx].groupMembersHint = prior?.groupMembersHint
            }
        }

        // Attach dynamic / optional dedicated pools reported by the backend (and drop retired ones on full sync).
        let optionalOrder = AppConfig.optionalDedicatedModels.map(\.id)
        var extraIDs = Set(snapshot.quotasByModel.keys.filter { !coreIDs.contains($0) })
        if !pruneUnreportedExtraBuckets {
            for priorExtra in existing where !coreIDs.contains(priorExtra.id) {
                extraIDs.insert(priorExtra.id)
            }
        }

        let sortedExtraIDs = extraIDs.sorted { lhs, rhs in
            let lhsIdx = optionalOrder.firstIndex(of: lhs)
            let rhsIdx = optionalOrder.firstIndex(of: rhs)
            switch (lhsIdx, rhsIdx) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }

        for extraID in sortedExtraIDs {
            let prior = existing.first(where: { $0.id == extraID })
            let quota = snapshot.quotasByModel[extraID]
            guard quota != nil || (!pruneUnreportedExtraBuckets && prior != nil) else { continue }

            let fallbackDef = AppConfig.modelDefinition(for: extraID)
            let resolvedDisplayName = quota?.displayName ?? prior?.displayName ?? fallbackDef?.displayName ?? extraID
            let usage = ModelUsage(
                id: extraID,
                displayName: resolvedDisplayName,
                turnsUsed: prior?.turnsUsed ?? 0,
                turnLimit: resolvedTier.defaultTurnLimit(for: extraID),
                lastUsedAt: prior?.lastUsedAt,
                cooldownUntil: prior?.cooldownUntil,
                quotaRemainingFraction: quota?.remainingFraction ?? prior?.quotaRemainingFraction,
                quotaResetAt: quota?.resetAt ?? prior?.quotaResetAt,
                quotaSyncedAt: quota != nil ? snapshot.syncedAt : prior?.quotaSyncedAt,
                tokensUsed: prior?.tokensUsed,
                groupMembersHint: quota?.groupMembersHint ?? prior?.groupMembersHint
            )
            updated.append(usage)
        }

        return (resolvedTier, updated)
    }

    // MARK: - Antigravity CLI (`/usage`)

    /// Parses stdout from `agy -p /usage --output-format stream-json` (or plain-text tab table fallback).
    public func parseAgyCLIUsageOutput(_ stdout: String) -> [String: ModelDashboardQuota] {
        var parsed: [String: ModelDashboardQuota] = [:]

        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["event"] as? String) == "command_result",
                  let command = json["command"] as? [String: Any],
                  (command["name"] as? String) == "usage",
                  let cmdData = command["data"] as? [String: Any],
                  let groups = cmdData["groups"] as? [[String: Any]] else {
                continue
            }

            for group in groups {
                let groupName = group["name"] as? String
                let groupDesc = group["description"] as? String

                guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
                for bucket in buckets {
                    let bucketID = (bucket["id"] as? String) ?? ""
                    let bucketName = bucket["name"] as? String
                    let window = bucket["window"] as? String

                    guard let descriptor = ModelUsage.resolveQuotaBucketDescriptor(
                        bucketID: bucketID,
                        groupName: groupName,
                        bucketName: bucketName,
                        window: window,
                        groupDescription: groupDesc
                    ) else {
                        continue
                    }

                    let rawFraction = (bucket["remaining_fraction"] as? Double)
                        ?? (bucket["remainingFraction"] as? Double)
                        ?? (bucket["remaining_fraction"] as? NSNumber)?.doubleValue
                        ?? (bucket["remainingFraction"] as? NSNumber)?.doubleValue
                    let resetString = (bucket["reset_time"] as? String) ?? (bucket["resetTime"] as? String)
                    guard rawFraction != nil || resetString != nil else { continue }

                    let fraction = min(1.0, max(0.0, rawFraction ?? 0.0))
                    let resetDate = resetString.flatMap { UsageTrackerService.parseISO8601($0) }
                    parsed[descriptor.id] = ModelDashboardQuota(
                        canonicalModelID: descriptor.id,
                        displayName: descriptor.displayName,
                        shortLabel: descriptor.shortLabel,
                        groupMembersHint: descriptor.groupMembersHint,
                        remainingFraction: fraction,
                        resetAt: resetDate
                    )
                }
            }
            if !parsed.isEmpty {
                return parsed
            }
        }

        // Plain-text fallback: "<group>\t<window label>\t<pct>%\t<reset ISO>"
        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let cells = rawLine.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard cells.count >= 3 else { continue }
            let groupName = cells[0]
            let windowLabel = cells[1]
            let pctText = cells[2].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pct = Double(pctText) else { continue }
            let resetDate = cells.count >= 4 ? UsageTrackerService.parseISO8601(cells[3]) : nil
            guard let descriptor = ModelUsage.resolveQuotaBucketDescriptor(
                bucketID: nil,
                groupName: groupName,
                bucketName: windowLabel,
                window: windowLabel
            ) else {
                continue
            }
            parsed[descriptor.id] = ModelDashboardQuota(
                canonicalModelID: descriptor.id,
                displayName: descriptor.displayName,
                shortLabel: descriptor.shortLabel,
                remainingFraction: min(1.0, max(0.0, pct / 100.0)),
                resetAt: resetDate
            )
        }

        return parsed
    }

    public func fetchAgyCLIUsageQuotas(timeoutSeconds: TimeInterval = 15.0) async -> [String: ModelDashboardQuota]? {
        guard let agyBinaryPath = Self.resolveAgyBinaryPath() else {
            return nil
        }

        return await Task.detached(priority: .utility) { [self] () -> [String: ModelDashboardQuota]? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: agyBinaryPath)
            process.arguments = ["-p", "/usage", "--output-format", "stream-json"]
            var env = ProcessInfo.processInfo.environment
            env["BROWSER"] = "/usr/bin/true"
            env["NO_BROWSER"] = "1"
            env["TERM"] = "dumb"
            process.environment = env

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return nil
            }

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                process.terminate()
                return nil
            }

            guard process.terminationStatus == 0 else { return nil }
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            guard let stdout = String(data: data, encoding: .utf8), !stdout.isEmpty else {
                return nil
            }
            let parsed = self.parseAgyCLIUsageOutput(stdout)
            return parsed.isEmpty ? nil : parsed
        }.value
    }

    private static func resolveAgyBinaryPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "\(home)/.bun/bin/agy"
        ]

        let nvmNodeRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmNodeRoot) {
            for version in versions.sorted().reversed() {
                candidates.append("\(nvmNodeRoot)/\(version)/bin/agy")
            }
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Weekly Quota Warmup Catalog & Minimal Request Transport

    /// Parses advertised physical model entries from `/v1internal:fetchAvailableModels`.
    public func parseAdvertisedModels(from modelsData: Data) -> [AdvertisedModelEntry] {
        guard let decoded = try? JSONDecoder().decode(FetchAvailableModelsPayload.self, from: modelsData),
              let serverModels = decoded.models else {
            return []
        }

        var entries: [AdvertisedModelEntry] = []
        entries.reserveCapacity(serverModels.count)
        for (modelKey, details) in serverModels {
            let trimmedKey = modelKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedField = details.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedID: String
            if !trimmedKey.isEmpty && !trimmedKey.hasPrefix("MODEL_") {
                resolvedID = trimmedKey
            } else if let trimmedField, !trimmedField.isEmpty {
                resolvedID = trimmedField
            } else {
                resolvedID = trimmedKey
            }
            guard !resolvedID.isEmpty else { continue }
            entries.append(
                AdvertisedModelEntry(
                    modelID: resolvedID,
                    displayName: details.displayName,
                    disabled: details.disabled ?? false
                )
            )
        }
        return entries.sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
    }

    /// Picks the lightest advertised physical model for a shared weekly warmup group (`gemini-weekly` or `3p-weekly`).
    /// Never invents model IDs and never selects dedicated Argon/Carbon/Neon/Orchestrator or non-text media models.
    public static func selectWarmupModelID(
        for group: WeeklyWarmupGroup,
        from advertisedModels: [AdvertisedModelEntry]
    ) -> String? {
        selectWarmupModelCandidates(for: group, groupMembersHint: nil, from: advertisedModels).first
    }

    /// Returns ordered candidate model IDs for warmup, prioritizing lightest models actually listed in `groupMembersHint`.
    public static func selectWarmupModelCandidates(
        for group: WeeklyWarmupGroup,
        groupMembersHint: String? = nil,
        from advertisedModels: [AdvertisedModelEntry]
    ) -> [String] {
        let forbiddenTokens = [
            "argon", "carbon", "neon", "orchestrator", "tab_", "imagen", "image", "audio", "video",
            "veo", "lyria", "tts", "transcribe", "speech", "embed",
            "realtime", "-live", "_live", " live"
        ]

        let sorted = advertisedModels
            .filter { !$0.disabled }
            .filter { entry in
                let combined = "\(entry.modelID) \(entry.displayName ?? "")".lowercased()
                return !forbiddenTokens.contains { combined.contains($0) }
            }
            .sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }

        let hintTokensByMember: [[String]] = (groupMembersHint ?? "")
            .split(separator: ",")
            .map { member in
                member
                    .lowercased()
                    .components(separatedBy: CharacterSet(charactersIn: " ()\t\n"))
                    .filter { !$0.isEmpty }
            }
            .filter { !$0.isEmpty }

        func matchesHint(_ entry: AdvertisedModelEntry) -> Bool {
            guard !hintTokensByMember.isEmpty else { return false }
            let combined = "\(entry.modelID) \(entry.displayName ?? "")".lowercased()
            return hintTokensByMember.contains { tokens in
                tokens.allSatisfy { combined.contains($0) }
            }
        }

        func collect(_ matchers: [(AdvertisedModelEntry) -> Bool], from family: [AdvertisedModelEntry]) -> [String] {
            var ordered: [String] = []
            var seen: Set<String> = []
            for matcher in matchers {
                for entry in family where matcher(entry) {
                    if seen.insert(entry.modelID).inserted {
                        ordered.append(entry.modelID)
                        if ordered.count >= 3 {
                            return ordered
                        }
                    }
                }
            }
            return ordered
        }

        switch group {
        case .gemini:
            let family = sorted.filter { $0.modelID.lowercased().contains("gemini") }
            guard !family.isEmpty else { return [] }
            let matchers: [(AdvertisedModelEntry) -> Bool] = [
                { matchesHint($0) && $0.modelID.lowercased().contains("flash") && $0.modelID.lowercased().contains("low") && !$0.modelID.lowercased().contains("thinking") },
                { matchesHint($0) && $0.modelID.lowercased().contains("flash") && !$0.modelID.lowercased().contains("thinking") },
                { matchesHint($0) && $0.modelID.lowercased().contains("low") && !$0.modelID.lowercased().contains("thinking") },
                { $0.modelID.lowercased().hasPrefix("gemini-3.8-flash-low") },
                { $0.modelID.lowercased().hasPrefix("gemini-3.8-flash") && !$0.modelID.lowercased().contains("thinking") },
                { $0.modelID.lowercased() == "gemini-3-flash" },
                { $0.modelID.lowercased().hasPrefix("gemini-3-flash") && !$0.modelID.lowercased().contains("thinking") },
                { $0.modelID.lowercased() == "gemini-3.5-flash-lite" },
                { $0.modelID.lowercased() == "gemini-2.5-flash" },
                { $0.modelID.lowercased().hasPrefix("gemini-2.5-flash") && !$0.modelID.lowercased().contains("thinking") },
                { $0.modelID.lowercased().contains("flash") && !$0.modelID.lowercased().contains("thinking") },
                { $0.modelID.lowercased().contains("flash") },
                { !$0.modelID.lowercased().contains("thinking") },
                { _ in true }
            ]
            return collect(matchers, from: family)

        case .claude:
            let family = sorted.filter { $0.modelID.lowercased().contains("claude") }
            guard !family.isEmpty else { return [] }
            let matchers: [(AdvertisedModelEntry) -> Bool] = [
                { matchesHint($0) && $0.modelID.lowercased().contains("sonnet") && $0.modelID.lowercased().contains("low") && !$0.modelID.lowercased().contains("thinking") },
                { matchesHint($0) && $0.modelID.lowercased().contains("sonnet") && !$0.modelID.lowercased().contains("thinking") },
                { $0.modelID.lowercased() == "claude-sonnet-4-6" },
                { $0.modelID.lowercased().hasPrefix("claude-sonnet-4-6") && !$0.modelID.lowercased().contains("thinking") },
                { $0.modelID.lowercased() == "claude-sonnet-4-5" },
                { $0.modelID.lowercased().hasPrefix("claude-sonnet-4-5") && !$0.modelID.lowercased().contains("thinking") },
                { $0.modelID.lowercased().contains("sonnet") && $0.modelID.lowercased().contains("low") && !$0.modelID.lowercased().contains("thinking") },
                { $0.modelID.lowercased().contains("sonnet") && !$0.modelID.lowercased().contains("thinking") },
                { $0.modelID.lowercased().contains("sonnet") },
                { $0.modelID.lowercased().contains("low") && !$0.modelID.lowercased().contains("thinking") },
                { !$0.modelID.lowercased().contains("thinking") },
                { _ in true }
            ]
            return collect(matchers, from: family)
        }
    }

    /// Queries `loadCodeAssist` + `fetchAvailableModels` to discover the real `projectID` and advertised models for an account.
    public func fetchAdvertisedModelsAndProject(
        bearerToken: String,
        baseURLs: [String] = AppConfig.cloudCodeBaseURLs
    ) async -> (projectID: String, models: [AdvertisedModelEntry])? {
        for baseURL in baseURLs {
            if Task.isCancelled { return nil }
            let loadAssistData = await postJSON(
                urlString: "\(baseURL)/v1internal:loadCodeAssist",
                body: [
                    "metadata": [
                        "ideType": "ANTIGRAVITY",
                        "platform": "DARWIN_ARM64",
                        "pluginType": "GEMINI",
                        "ideVersion": "2.32.0"
                    ]
                ],
                bearerToken: bearerToken
            )
            let parsedAssist = loadAssistData.flatMap { parseLoadCodeAssist(from: $0) }
            let projectID: String
            if let assistProj = parsedAssist?.projectID, !assistProj.isEmpty {
                projectID = assistProj
            } else {
                projectID = AppConfig.defaultCloudCodeProject
            }

            guard let modelsData = await postJSON(
                urlString: "\(baseURL)/v1internal:fetchAvailableModels",
                body: ["project": projectID],
                bearerToken: bearerToken
            ) else {
                continue
            }

            let models = parseAdvertisedModels(from: modelsData)
            if !models.isEmpty {
                return (projectID, models)
            }
        }
        return nil
    }

    /// Builds the minimal `v1internal` warmup request envelope (`maxOutputTokens: 8`, `temperature: 0`, prompt `"hi"`).
    public static func buildWarmupRequestBody(
        projectID: String,
        modelID: String,
        requestID: String = "warmup-\(UUID().uuidString.lowercased())"
    ) -> [String: Any] {
        [
            "project": projectID,
            "model": modelID,
            "userAgent": "antigravity",
            "requestId": requestID,
            "request": [
                "contents": [
                    [
                        "role": "user",
                        "parts": [
                            ["text": "hi"]
                        ]
                    ]
                ],
                "generationConfig": [
                    "maxOutputTokens": 8,
                    "temperature": 0
                ]
            ]
        ]
    }

    /// Sends a single minimal warmup request via `/v1internal:streamGenerateContent?alt=sse`.
    /// Falls back to `/v1internal:generateContent` ONLY on transport/network error, never on HTTP 4xx rejection.
    public func sendMinimalWarmupRequest(
        bearerToken: String,
        projectID: String,
        modelID: String,
        baseURLs: [String] = AppConfig.cloudCodeBaseURLs,
        session: URLSession = .shared
    ) async throws {
        let payload = Self.buildWarmupRequestBody(projectID: projectID, modelID: modelID)
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw WarmupTransportError.transportFailed("Không thể mã hóa payload warmup.")
        }

        var lastError: Error?
        for baseURL in baseURLs {
            try Task.checkCancellation()

            let sseResult = try await executeWarmupPost(
                urlString: "\(baseURL)/v1internal:streamGenerateContent?alt=sse",
                bodyData: bodyData,
                bearerToken: bearerToken,
                session: session
            )

            switch sseResult {
            case .succeeded:
                return
            case .httpRejected(let statusCode, let detail):
                if (400..<500).contains(statusCode) {
                    throw WarmupTransportError.httpRejected(statusCode: statusCode, detail: detail)
                }
                lastError = WarmupTransportError.httpRejected(statusCode: statusCode, detail: detail)
                continue
            case .transportError(let transportMessage):
                try Task.checkCancellation()
                // Transport failure on SSE: fall back once to non-streaming on the same host.
                let fallbackResult = try await executeWarmupPost(
                    urlString: "\(baseURL)/v1internal:generateContent",
                    bodyData: bodyData,
                    bearerToken: bearerToken,
                    session: session
                )
                switch fallbackResult {
                case .succeeded:
                    return
                case .httpRejected(let statusCode, let detail):
                    if (400..<500).contains(statusCode) {
                        throw WarmupTransportError.httpRejected(statusCode: statusCode, detail: detail)
                    }
                    lastError = WarmupTransportError.httpRejected(statusCode: statusCode, detail: detail)
                case .transportError(let fallbackMessage):
                    lastError = WarmupTransportError.transportFailed(fallbackMessage.isEmpty ? transportMessage : fallbackMessage)
                }
            }
        }

        throw lastError ?? WarmupTransportError.transportFailed("Không thể kết nối Cloud Code Assist.")
    }

    private enum WarmupHTTPOutcome {
        case succeeded
        case httpRejected(statusCode: Int, detail: String)
        case transportError(String)
    }

    private func executeWarmupPost(
        urlString: String,
        bodyData: Data,
        bearerToken: String,
        session: URLSession
    ) async throws -> WarmupHTTPOutcome {
        guard let url = URL(string: urlString) else {
            return .transportError("URL không hợp lệ: \(urlString)")
        }

        var request = URLRequest(url: url, timeoutInterval: 30.0)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.antigravityUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .transportError("Phản hồi không phải HTTP.")
            }
            if (200..<300).contains(http.statusCode) {
                let rawBody = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !rawBody.isEmpty else {
                    return .transportError("Phản hồi rỗng từ máy chủ.")
                }
                if rawBody.contains("\"error\"") && !rawBody.contains("\"candidates\"") {
                    return .httpRejected(statusCode: 400, detail: String(rawBody.prefix(200)))
                }
                return .succeeded
            }
            let rawText = String(data: data.prefix(240), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .httpRejected(statusCode: http.statusCode, detail: rawText)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            return .transportError(error.localizedDescription)
        }
    }

    // MARK: - Private HTTP & Parsing Helpers

    private func parseLoadCodeAssist(from data: Data) -> (tier: AccountTier?, projectID: String?)? {
        guard let payload = try? JSONDecoder().decode(LoadCodeAssistPayload.self, from: data) else {
            return nil
        }
        let resolvedTierString = payload.paidTier?.id
            ?? payload.paidTier?.name
            ?? payload.g1Tier
            ?? payload.currentTier?.id
            ?? payload.currentTier?.name
        let tier = AccountTier.from(serverTier: resolvedTierString)
        return (tier, payload.cloudaicompanionProject)
    }

    private func postJSON(urlString: String, body: [String: Any], bearerToken: String) async -> Data? {
        guard let url = URL(string: urlString),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }

        var request = URLRequest(url: url, timeoutInterval: 8.0)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.antigravityUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}
