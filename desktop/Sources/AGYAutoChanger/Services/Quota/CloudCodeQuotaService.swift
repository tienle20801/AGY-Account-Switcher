import Foundation

// MARK: - Cloud Code Dashboard Snapshot

public struct ModelDashboardQuota: Sendable, Equatable {
    public let canonicalModelID: String
    public let remainingFraction: Double
    public let resetAt: Date?

    public init(canonicalModelID: String, remainingFraction: Double, resetAt: Date? = nil) {
        self.canonicalModelID = canonicalModelID
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

            // Fast path: summary already includes all primary groups including dedicated Argon.
            if let summarySnapshot,
               !summarySnapshot.quotasByModel.isEmpty,
               summarySnapshot.quotasByModel["argon-weekly"] != nil {
                return summarySnapshot
            }

            // Summary lacked dedicated Argon (or failed): query fetchAvailableModels + retrieveUserQuota in parallel.
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
                let finalQuotas = (!Self.isAgyCLIAvailable && allowCLIUsage)
                    ? projectSharedGeminiWeeklyOntoArgonIfNeeded(combinedQuotas)
                    : combinedQuotas
                return CloudCodeDashboardSnapshot(
                    detectedTier: resolvedTier,
                    projectID: resolvedProjectID,
                    quotasByModel: finalQuotas,
                    syncedAt: summarySnapshot?.syncedAt ?? Date()
                )
            }
        }
        return nil
    }

    /// Parses `/v1internal:retrieveUserQuotaSummary` response buckets (`gemini-5h`, `gemini-weekly`, `3p-5h`, `3p-weekly`, `argon-weekly`).
    public func parseDashboardSnapshot(
        fromQuotaSummaryData quotaSummaryData: Data,
        loadCodeAssistData: Data? = nil,
        syncedAt: Date = Date(),
        projectSharedGeminiFallback: Bool = true
    ) -> CloudCodeDashboardSnapshot? {
        let assist = loadCodeAssistData.flatMap { parseLoadCodeAssist(from: $0) }

        guard let decoded = try? JSONDecoder().decode(RetrieveUserQuotaSummaryPayload.self, from: quotaSummaryData) else {
            return nil
        }

        var allBuckets: [(groupContext: String?, bucket: RetrieveUserQuotaSummaryPayload.QuotaBucket)] =
            (decoded.buckets ?? []).map { (nil, $0) }
        if let groups = decoded.groups {
            for group in groups {
                let groupContext = [group.displayName, group.description]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                for bucket in group.buckets ?? [] {
                    allBuckets.append((groupContext.isEmpty ? nil : groupContext, bucket))
                }
            }
        }

        var aggregated: [String: ModelDashboardQuota] = [:]
        for (groupContext, bucket) in allBuckets {
            if bucket.disabled == true {
                continue
            }
            let combinedDisplay = [groupContext, bucket.displayName, bucket.description, bucket.window]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let rawBucketID = bucket.bucketId ?? bucket.window ?? bucket.displayName ?? ""
            guard let canonicalID = ModelUsage.canonicalModelID(
                modelID: rawBucketID.isEmpty ? nil : rawBucketID,
                displayName: combinedDisplay.isEmpty ? nil : combinedDisplay
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

        guard !aggregated.isEmpty || assist?.tier != nil else {
            return nil
        }

        let finalQuotas = projectSharedGeminiFallback
            ? projectSharedGeminiWeeklyOntoArgonIfNeeded(aggregated)
            : aggregated

        return CloudCodeDashboardSnapshot(
            detectedTier: assist?.tier,
            projectID: assist?.projectID,
            quotasByModel: finalQuotas,
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
    public func applyDashboardSnapshot(
        _ snapshot: CloudCodeDashboardSnapshot,
        into existing: [ModelUsage],
        currentTier: AccountTier
    ) -> (tier: AccountTier, usages: [ModelUsage]) {
        let resolvedTier = snapshot.detectedTier ?? currentTier
        var updated = ModelUsage.defaultSet(for: resolvedTier)

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
            } else if modelID == "argon-weekly",
                      prior?.quotaRemainingFraction == nil,
                      !Self.isAgyCLIAvailable,
                      let geminiWeekly = snapshot.quotasByModel["gemini-weekly"] {
                updated[idx].quotaRemainingFraction = geminiWeekly.remainingFraction
                updated[idx].quotaResetAt = geminiWeekly.resetAt
                updated[idx].quotaSyncedAt = snapshot.syncedAt
            } else {
                updated[idx].quotaRemainingFraction = prior?.quotaRemainingFraction
                updated[idx].quotaResetAt = prior?.quotaResetAt
                updated[idx].quotaSyncedAt = prior?.quotaSyncedAt
            }
        }

        return (resolvedTier, updated)
    }

    // MARK: - Antigravity CLI (`/usage`) & Shared Gemini Fallback

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
                let groupContext = [groupName, groupDesc]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
                for bucket in buckets {
                    let bucketID = (bucket["id"] as? String) ?? ""
                    let bucketName = bucket["name"] as? String
                    let window = bucket["window"] as? String
                    let displayContext = [groupContext, bucketName, window]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")

                    guard let canonicalID = ModelUsage.canonicalModelID(
                        modelID: bucketID.isEmpty ? nil : bucketID,
                        displayName: displayContext.isEmpty ? nil : displayContext
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
                    parsed[canonicalID] = ModelDashboardQuota(
                        canonicalModelID: canonicalID,
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
            let combined = "\(groupName) \(windowLabel)"
            guard let canonicalID = ModelUsage.canonicalModelID(modelID: nil, displayName: combined) else {
                continue
            }
            parsed[canonicalID] = ModelDashboardQuota(
                canonicalModelID: canonicalID,
                remainingFraction: min(1.0, max(0.0, pct / 100.0)),
                resetAt: resetDate
            )
        }

        return parsed
    }

    public func fetchAgyCLIUsageQuotas(timeoutSeconds: TimeInterval = 35.0) async -> [String: ModelDashboardQuota]? {
        guard let agyBinaryPath = Self.resolveAgyBinaryPath() else {
            return nil
        }

        return await Task.detached(priority: .utility) { [self] () -> [String: ModelDashboardQuota]? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: agyBinaryPath)
            process.arguments = ["-p", "/usage", "--output-format", "stream-json"]

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

    private func projectSharedGeminiWeeklyOntoArgonIfNeeded(
        _ quotas: [String: ModelDashboardQuota]
    ) -> [String: ModelDashboardQuota] {
        guard quotas["argon-weekly"] == nil,
              let geminiWeekly = quotas["gemini-weekly"] else {
            return quotas
        }
        var projected = quotas
        projected["argon-weekly"] = ModelDashboardQuota(
            canonicalModelID: "argon-weekly",
            remainingFraction: geminiWeekly.remainingFraction,
            resetAt: geminiWeekly.resetAt
        )
        return projected
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
