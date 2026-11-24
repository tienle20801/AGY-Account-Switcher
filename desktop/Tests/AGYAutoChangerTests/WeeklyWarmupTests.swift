import Foundation
import XCTest
@testable import AGYAutoChanger

private final class MockWarmupURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var recordedRequests: [URLRequest] = []

    static func reset(handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        self.recordedRequests = []
        lock.unlock()
    }

    static func snapshotRecordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let currentHandler = Self.handler
        Self.lock.unlock()

        guard let currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try currentHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class WeeklyWarmupTests: TempDirectoryTestCase {

    private func makeAccount(
        id: UUID = UUID(),
        name: String = "Backup Acc",
        isActive: Bool = false,
        isDisabled: Bool = false,
        gemini5hFraction: Double? = nil,
        gemini5hResetAt: Date? = nil,
        geminiWeeklyFraction: Double? = 1.0,
        geminiWeeklyResetAt: Date? = nil,
        claude5hFraction: Double? = nil,
        claude5hResetAt: Date? = nil,
        claudeWeeklyFraction: Double? = 1.0,
        claudeWeeklyResetAt: Date? = nil,
        argonWeeklyFraction: Double? = 1.0,
        argonWeeklyResetAt: Date? = nil,
        carbonWeeklyFraction: Double? = nil,
        carbonWeeklyResetAt: Date? = nil,
        syncedAt: Date = Date()
    ) -> AccountProfile {
        var usages = ModelUsage.defaultSet(for: .pro)
        for idx in usages.indices {
            switch usages[idx].id {
            case "gemini-5h":
                usages[idx].quotaRemainingFraction = gemini5hFraction
                usages[idx].quotaResetAt = gemini5hResetAt
                usages[idx].quotaSyncedAt = gemini5hFraction != nil ? syncedAt : nil
            case "gemini-weekly":
                usages[idx].quotaRemainingFraction = geminiWeeklyFraction
                usages[idx].quotaResetAt = geminiWeeklyResetAt
                usages[idx].quotaSyncedAt = geminiWeeklyFraction != nil ? syncedAt : nil
            case "3p-5h":
                usages[idx].quotaRemainingFraction = claude5hFraction
                usages[idx].quotaResetAt = claude5hResetAt
                usages[idx].quotaSyncedAt = claude5hFraction != nil ? syncedAt : nil
            case "3p-weekly":
                usages[idx].quotaRemainingFraction = claudeWeeklyFraction
                usages[idx].quotaResetAt = claudeWeeklyResetAt
                usages[idx].quotaSyncedAt = claudeWeeklyFraction != nil ? syncedAt : nil
            default:
                break
            }
        }
        if let argonWeeklyFraction {
            usages.append(
                ModelUsage(
                    id: "argon-weekly",
                    displayName: "Gemini 4 Argon (Tuần)",
                    turnLimit: 200,
                    quotaRemainingFraction: argonWeeklyFraction,
                    quotaResetAt: argonWeeklyResetAt,
                    quotaSyncedAt: syncedAt
                )
            )
        }
        if let carbonWeeklyFraction {
            usages.append(
                ModelUsage(
                    id: "carbon-weekly",
                    displayName: "Gemini 4 Carbon (Tuần)",
                    turnLimit: 300,
                    quotaRemainingFraction: carbonWeeklyFraction,
                    quotaResetAt: carbonWeeklyResetAt,
                    quotaSyncedAt: syncedAt
                )
            )
        }
        return AccountProfile(
            id: id,
            email: "\(name.lowercased().replacingOccurrences(of: " ", with: ""))@example.com",
            displayName: name,
            tier: .pro,
            isActive: isActive,
            isDisabled: isDisabled,
            lastDashboardSyncAt: syncedAt,
            hasKeychainBackup: true,
            modelUsages: usages
        )
    }

    func testWeeklyWarmupEligibilityStrictRulesAndArgonCarbonExclusion() {
        let service = WeeklyWarmupService()
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        let activeAcc = makeAccount(
            name: "Active",
            isActive: true,
            geminiWeeklyFraction: 1.0,
            geminiWeeklyResetAt: nil,
            claudeWeeklyFraction: 1.0,
            claudeWeeklyResetAt: nil
        )
        let eligibleBackup = makeAccount(
            name: "Backup Ready",
            isActive: false,
            geminiWeeklyFraction: 1.0,
            geminiWeeklyResetAt: nil, // No timer started yet -> eligible
            claudeWeeklyFraction: 0.9995,
            claudeWeeklyResetAt: now.addingTimeInterval(-3600), // Elapsed 1h (< 6d) -> eligible
            argonWeeklyFraction: 1.0,
            argonWeeklyResetAt: nil,
            carbonWeeklyFraction: 1.0,
            carbonWeeklyResetAt: nil
        )
        let alreadyRunningTimer = makeAccount(
            name: "Timer Running",
            isActive: false,
            geminiWeeklyFraction: 1.0,
            geminiWeeklyResetAt: now.addingTimeInterval(3 * 86_400), // Future reset -> SKIP
            claudeWeeklyFraction: 1.0,
            claudeWeeklyResetAt: now.addingTimeInterval(-7 * 86_400) // Elapsed >= 6d -> SKIP
        )
        let partiallyUsedStale = makeAccount(
            name: "Partially Used",
            isActive: false,
            geminiWeeklyFraction: 0.95,
            geminiWeeklyResetAt: now.addingTimeInterval(-120), // < 0.999 raw -> SKIP even though resetAt elapsed
            claudeWeeklyFraction: nil, // Unknown -> SKIP
            claudeWeeklyResetAt: nil
        )
        let disabledAcc = makeAccount(
            name: "Disabled",
            isActive: false,
            isDisabled: true,
            geminiWeeklyFraction: 1.0,
            geminiWeeklyResetAt: nil,
            claudeWeeklyFraction: 1.0,
            claudeWeeklyResetAt: nil
        )

        let allAccounts = [activeAcc, eligibleBackup, alreadyRunningTimer, partiallyUsedStale, disabledAcc]

        // 1. Default policy is opt-in (disabled)
        let defaultPolicy = WeeklyWarmupPolicy()
        XCTAssertFalse(defaultPolicy.isEnabled)
        XCTAssertTrue(defaultPolicy.backupAccountsOnly)
        XCTAssertEqual(
            service.findEligibleCandidates(
                accounts: allAccounts,
                policy: defaultPolicy,
                state: WeeklyWarmupRuntimeState(),
                hasSnapshot: { _ in true },
                referenceDate: now
            ),
            []
        )

        // 2. Enabled with backupAccountsOnly = true
        let enabledPolicy = WeeklyWarmupPolicy(isEnabled: true, backupAccountsOnly: true, warmGemini: true, warmClaude: true)
        let candidates = service.findEligibleCandidates(
            accounts: allAccounts,
            policy: enabledPolicy,
            state: WeeklyWarmupRuntimeState(),
            hasSnapshot: { _ in true },
            referenceDate: now
        )

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.map(\.accountID), [eligibleBackup.id, eligibleBackup.id])
        XCTAssertEqual(candidates.map(\.bucketID), ["gemini-weekly", "3p-weekly"])
        XCTAssertFalse(candidates.contains { $0.bucketID == "argon-weekly" || $0.bucketID == "carbon-weekly" })

        // 3. Direct bucket check strictly rejects argon-weekly and carbon-weekly
        let argonUsage = eligibleBackup.modelUsages.first(where: { $0.id == "argon-weekly" })!
        let carbonUsage = eligibleBackup.modelUsages.first(where: { $0.id == "carbon-weekly" })!
        XCTAssertFalse(service.isBucketEligibleForWarmup(argonUsage, referenceDate: now))
        XCTAssertFalse(service.isBucketEligibleForWarmup(carbonUsage, referenceDate: now))

        // 4. Manual single-account trigger can warm active account when ignoreBackupOnlyFilter = true
        let manualActiveCandidates = service.findEligibleCandidates(
            accounts: allAccounts,
            policy: defaultPolicy,
            state: WeeklyWarmupRuntimeState(),
            onlyAccountID: activeAcc.id,
            ignoreAutoEnabledFlag: true,
            ignoreBackupOnlyFilter: true,
            hasSnapshot: { _ in true },
            referenceDate: now
        )
        XCTAssertEqual(manualActiveCandidates.count, 2)
        XCTAssertEqual(Set(manualActiveCandidates.map(\.accountID)), [activeAcc.id])

        // 5. Missing snapshot excludes account
        XCTAssertTrue(
            service.findEligibleCandidates(
                accounts: [eligibleBackup],
                policy: enabledPolicy,
                state: WeeklyWarmupRuntimeState(),
                hasSnapshot: { _ in false },
                referenceDate: now
            ).isEmpty
        )
    }

    func testWeeklyWarmupCycleKeyDeduplicationCooldownPruningAndStoragePause() throws {
        let service = WeeklyWarmupService()
        let accID = UUID()
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        // Minute-bucketed UTC key ignores sub-minute jitter
        let resetA = Date(timeIntervalSince1970: 1_769_996_405)
        let resetB = Date(timeIntervalSince1970: 1_769_996_455)
        let resetNextMin = Date(timeIntervalSince1970: 1_769_996_465)
        XCTAssertEqual(
            service.normalizedCycleKey(accountID: accID, bucketID: "gemini-weekly", resetAt: resetA, referenceDate: now),
            service.normalizedCycleKey(accountID: accID, bucketID: "gemini-weekly", resetAt: resetB, referenceDate: now)
        )
        XCTAssertNotEqual(
            service.normalizedCycleKey(accountID: accID, bucketID: "gemini-weekly", resetAt: resetA, referenceDate: now),
            service.normalizedCycleKey(accountID: accID, bucketID: "gemini-weekly", resetAt: resetNextMin, referenceDate: now)
        )

        // Idle key (resetAt == nil) stays stable within ISO week and rotates next week
        let sameWeekLater = now.addingTimeInterval(3600)
        let nextWeek = now.addingTimeInterval(8 * 86_400)
        let idleKey1 = service.normalizedCycleKey(accountID: accID, bucketID: "3p-weekly", resetAt: nil, referenceDate: now)
        let idleKey2 = service.normalizedCycleKey(accountID: accID, bucketID: "3p-weekly", resetAt: nil, referenceDate: sameWeekLater)
        let idleKeyNext = service.normalizedCycleKey(accountID: accID, bucketID: "3p-weekly", resetAt: nil, referenceDate: nextWeek)
        XCTAssertEqual(idleKey1, idleKey2)
        XCTAssertNotEqual(idleKey1, idleKeyNext)
        XCTAssertTrue(idleKey1.contains(":idle-"))

        let acc = makeAccount(id: accID, name: "Pool 1", isActive: false, geminiWeeklyFraction: 1.0, geminiWeeklyResetAt: resetA, claudeWeeklyFraction: 1.0, claudeWeeklyResetAt: nil)
        let policy = WeeklyWarmupPolicy(isEnabled: true, backupAccountsOnly: true, warmGemini: true, warmClaude: true)

        var state = WeeklyWarmupRuntimeState()
        let initial = service.findEligibleCandidates(accounts: [acc], policy: policy, state: state, hasSnapshot: { _ in true }, referenceDate: now)
        XCTAssertEqual(initial.count, 2)

        // Recording success deduplicates that cycle key
        state = service.recordSuccess(for: initial[0], modelID: "gemini-3-flash", into: state, at: now)
        let afterFirst = service.findEligibleCandidates(accounts: [acc], policy: policy, state: state, hasSnapshot: { _ in true }, referenceDate: now)
        XCTAssertEqual(afterFirst.count, 1)
        XCTAssertEqual(afterFirst[0].bucketID, "3p-weekly")

        // Failure cooldown skips second candidate until retry time passes
        let cooldowns = [afterFirst[0].cycleKey: now.addingTimeInterval(600)]
        XCTAssertTrue(
            service.findEligibleCandidates(
                accounts: [acc],
                policy: policy,
                state: state,
                hasSnapshot: { _ in true },
                failureCooldowns: cooldowns,
                referenceDate: now.addingTimeInterval(300)
            ).isEmpty
        )
        XCTAssertEqual(
            service.findEligibleCandidates(
                accounts: [acc],
                policy: policy,
                state: state,
                hasSnapshot: { _ in true },
                failureCooldowns: cooldowns,
                referenceDate: now.addingTimeInterval(601)
            ).count,
            1
        )

        // Storage error pauses all warmup runs immediately
        var pausedState = state
        pausedState.pausedDueToStorageError = true
        XCTAssertTrue(
            service.findEligibleCandidates(
                accounts: [acc],
                policy: policy,
                state: pausedState,
                ignoreAutoEnabledFlag: true,
                hasSnapshot: { _ in true },
                referenceDate: now
            ).isEmpty
        )

        // 30-day retention prunes old records and keeps recent ones
        let expiredRecord = WeeklyWarmupHistoryRecord(
            accountID: accID,
            group: .claude,
            bucketID: "3p-weekly",
            cycleKey: "old-key",
            modelID: "claude-sonnet-4-6",
            warmedAt: now.addingTimeInterval(-(31 * 86_400))
        )
        state.records["old-key"] = expiredRecord
        let pruned = service.pruneExpiredHistory(in: state, referenceDate: now)
        XCTAssertNil(pruned.records["old-key"])
        XCTAssertNotNil(pruned.records[initial[0].cycleKey])

        // Verify persisted JSON file is 0600 and contains no email/token
        let vault = VaultSecurityService()
        let vaultRoot = tempRoot.appendingPathComponent("vault", isDirectory: true)
        try vault.ensureVaultDirectories(
            vaultRoot: vaultRoot,
            profilesDir: vaultRoot.appendingPathComponent("profiles", isDirectory: true)
        )
        let stateURL = vaultRoot.appendingPathComponent("weekly_warmup_state.json")
        try vault.writeJSON(pruned, to: stateURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)

        let rawJSON = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertFalse(rawJSON.contains("@example.com"))
        XCTAssertFalse(rawJSON.contains("Bearer"))
    }

    func testCloudCodeAdvertisedModelParsingAndWarmupModelSelection() throws {
        let quotaService = CloudCodeQuotaService()
        let json = """
        {
          "models": {
            "gemini-4-argon": { "displayName": "Gemini 4 Argon", "model": "gemini-4-argon", "disabled": false },
            "gemini-4-carbon": { "displayName": "Gemini 4 Carbon", "model": "gemini-4-carbon", "disabled": false },
            "gemini-3-pro-image": { "displayName": "Gemini 3 Pro Image", "model": "gemini-3-pro-image", "disabled": false },
            "gemini-2.5-flash": { "displayName": "Gemini 2.5 Flash", "model": "gemini-2.5-flash", "disabled": false },
            "gemini-3-flash": { "displayName": "Gemini 3 Flash", "model": "gemini-3-flash", "disabled": false },
            "gemini-3-flash-disabled": { "displayName": "Disabled", "model": "gemini-3-flash-disabled", "disabled": true },
            "claude-opus-4-6": { "displayName": "Claude Opus 4.6", "model": "claude-opus-4-6", "disabled": false },
            "claude-sonnet-4-5-thinking": { "displayName": "Claude Sonnet 4.5 Thinking", "model": "claude-sonnet-4-5-thinking", "disabled": false },
            "claude-sonnet-4-6": { "displayName": "Claude Sonnet 4.6", "model": "claude-sonnet-4-6", "disabled": false }
          }
        }
        """
        let entries = quotaService.parseAdvertisedModels(from: Data(json.utf8))
        XCTAssertEqual(entries.count, 9)

        XCTAssertEqual(CloudCodeQuotaService.selectWarmupModelID(for: .gemini, from: entries), "gemini-3-flash")
        XCTAssertEqual(CloudCodeQuotaService.selectWarmupModelID(for: .claude, from: entries), "claude-sonnet-4-6")

        // When only Argon, Carbon, Image, and disabled Flash exist -> returns nil (never picks Argon/Carbon/Media/Disabled!)
        let restrictedOnly: [AdvertisedModelEntry] = [
            AdvertisedModelEntry(modelID: "gemini-4-argon", displayName: "Gemini 4 Argon"),
            AdvertisedModelEntry(modelID: "gemini-4-carbon", displayName: "Gemini 4 Carbon"),
            AdvertisedModelEntry(modelID: "gemini-3-pro-image", displayName: "Gemini Image"),
            AdvertisedModelEntry(modelID: "gemini-2.0-flash-live-001", displayName: "Gemini Live"),
            AdvertisedModelEntry(modelID: "gemini-3-flash", displayName: "Gemini 3 Flash", disabled: true)
        ]
        XCTAssertNil(CloudCodeQuotaService.selectWarmupModelID(for: .gemini, from: restrictedOnly))
        XCTAssertNil(CloudCodeQuotaService.selectWarmupModelID(for: .claude, from: restrictedOnly))

        // Real Cloud Code Assist payload uses wire model ID as dictionary key and `MODEL_PLACEHOLDER_*` in `details.model`
        let placeholderCatalogJSON = """
        {
          "models": {
            "claude-sonnet-5-5-high": { "displayName": "Claude Sonnet 5.5 (High)", "model": "MODEL_PLACEHOLDER_M405" },
            "claude-sonnet-5-5-low": { "displayName": "Claude Sonnet 5.5 (Low)", "model": "MODEL_PLACEHOLDER_M403" },
            "gemini-3-flash": { "displayName": "Gemini 3 Flash", "model": "MODEL_PLACEHOLDER_M18" }
          }
        }
        """
        let placeholderEntries = quotaService.parseAdvertisedModels(from: Data(placeholderCatalogJSON.utf8))
        XCTAssertEqual(CloudCodeQuotaService.selectWarmupModelID(for: .gemini, from: placeholderEntries), "gemini-3-flash")
        XCTAssertEqual(CloudCodeQuotaService.selectWarmupModelID(for: .claude, from: placeholderEntries), "claude-sonnet-5-5-low")

        // When `gemini-3.8-flash-low` and `groupMembersHint = "Gemini 3.8 Flash"` exist, prefer `gemini-3.8-flash-low` ahead of `gemini-3-flash`
        let meteredEntries: [AdvertisedModelEntry] = [
            AdvertisedModelEntry(modelID: "gemini-3-flash", displayName: "Gemini 3 Flash"),
            AdvertisedModelEntry(modelID: "gemini-3.8-flash-low", displayName: "Gemini 3.8 Flash (Low)"),
            AdvertisedModelEntry(modelID: "gemini-4-hydrogen-sonar", displayName: nil)
        ]
        let geminiCandidates = CloudCodeQuotaService.selectWarmupModelCandidates(
            for: .gemini,
            groupMembersHint: "Gemini 3.8 Flash",
            from: meteredEntries
        )
        XCTAssertEqual(geminiCandidates.first, "gemini-3.8-flash-low")
        XCTAssertEqual(geminiCandidates.dropFirst().first, "gemini-3-flash")
    }

    func testWarmupTransportEnvelopeFallbackAndNo4xxRetry() async throws {
        let quotaService = CloudCodeQuotaService()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockWarmupURLProtocol.self]
        let session = URLSession(configuration: config)

        // 1. SSE succeeds on first call -> verify exact envelope & headers, NO x-goog-user-project
        MockWarmupURLProtocol.reset { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"data: {"candidates":[{"content":{}}]}"#.utf8))
        }

        try await quotaService.sendMinimalWarmupRequest(
            bearerToken: "tok-123",
            projectID: "real-proj-99",
            modelID: "gemini-3-flash",
            baseURLs: ["https://primary.test", "https://backup.test"],
            session: session
        )

        let successRequests = MockWarmupURLProtocol.snapshotRecordedRequests()
        XCTAssertEqual(successRequests.count, 1)
        XCTAssertEqual(successRequests[0].url?.absoluteString, "https://primary.test/v1internal:streamGenerateContent?alt=sse")
        XCTAssertEqual(successRequests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertNil(successRequests[0].value(forHTTPHeaderField: "x-goog-user-project"))

        let builtBody = CloudCodeQuotaService.buildWarmupRequestBody(
            projectID: "real-proj-99",
            modelID: "gemini-3-flash",
            requestID: "warmup-fixed"
        )
        XCTAssertEqual(builtBody["project"] as? String, "real-proj-99")
        XCTAssertEqual(builtBody["model"] as? String, "gemini-3-flash")
        XCTAssertEqual(builtBody["userAgent"] as? String, "antigravity")
        let innerReq = builtBody["request"] as? [String: Any]
        let genCfg = innerReq?["generationConfig"] as? [String: Any]
        XCTAssertEqual(genCfg?["maxOutputTokens"] as? Int, 8)
        XCTAssertEqual(genCfg?["temperature"] as? Int, 0)

        // 2. HTTP 200 containing JSON `error` without `candidates` must be rejected (no fake success)
        MockWarmupURLProtocol.reset { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":{"code":400,"message":"Invalid"}}"#.utf8))
        }
        do {
            try await quotaService.sendMinimalWarmupRequest(
                bearerToken: "tok-123",
                projectID: "real-proj-99",
                modelID: "gemini-3.8-flash-low",
                baseURLs: ["https://primary.test"],
                session: session
            )
            XCTFail("Expected in-stream JSON error to throw")
        } catch let error as WarmupTransportError {
            if case .httpRejected(let code, _) = error {
                XCTAssertEqual(code, 400)
            } else {
                XCTFail("Expected httpRejected, got \(error)")
            }
        }

        // 3. HTTP 4xx rejection on SSE -> throws immediately, NEVER retries non-streaming or backup host!
        MockWarmupURLProtocol.reset { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data("Forbidden".utf8))
        }

        do {
            try await quotaService.sendMinimalWarmupRequest(
                bearerToken: "tok-123",
                projectID: "real-proj-99",
                modelID: "claude-sonnet-4-6",
                baseURLs: ["https://primary.test", "https://backup.test"],
                session: session
            )
            XCTFail("Expected HTTP 403 rejection to throw")
        } catch let error as WarmupTransportError {
            if case .httpRejected(let code, _) = error {
                XCTAssertEqual(code, 403)
            } else {
                XCTFail("Expected httpRejected, got \(error)")
            }
        }
        XCTAssertEqual(MockWarmupURLProtocol.snapshotRecordedRequests().count, 1)

        // 4. Transport error on SSE -> falls back ONCE to non-streaming /v1internal:generateContent on same host
        var callCount = 0
        MockWarmupURLProtocol.reset { request in
            callCount += 1
            if callCount == 1 {
                throw URLError(.networkConnectionLost)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"candidates":[{"content":{}}]}"#.utf8))
        }

        try await quotaService.sendMinimalWarmupRequest(
            bearerToken: "tok-123",
            projectID: "real-proj-99",
            modelID: "gemini-3-flash",
            baseURLs: ["https://primary.test", "https://backup.test"],
            session: session
        )

        let fallbackRequests = MockWarmupURLProtocol.snapshotRecordedRequests()
        XCTAssertEqual(fallbackRequests.count, 2)
        XCTAssertEqual(fallbackRequests[0].url?.absoluteString, "https://primary.test/v1internal:streamGenerateContent?alt=sse")
        XCTAssertEqual(fallbackRequests[1].url?.absoluteString, "https://primary.test/v1internal:generateContent")
    }

    func testStaleIdleRecordIsRetriedWhenBucketRemainsUnstarted() {
        let service = WeeklyWarmupService()
        let warmedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let syncedLater = warmedAt.addingTimeInterval(300) // 5 minutes later
        let placeholderReset = syncedLater.addingTimeInterval(7 * 86_400)

        let acc = makeAccount(
            name: "Unstarted Backup",
            isActive: false,
            geminiWeeklyFraction: 1.0,
            geminiWeeklyResetAt: placeholderReset,
            claudeWeeklyFraction: 0.40,
            claudeWeeklyResetAt: syncedLater.addingTimeInterval(4 * 86_400),
            syncedAt: syncedLater
        )
        let cycleKey = service.normalizedCycleKey(
            accountID: acc.id,
            bucketID: "gemini-weekly",
            resetAt: nil,
            referenceDate: syncedLater
        )
        let staleRecord = WeeklyWarmupHistoryRecord(
            accountID: acc.id,
            group: .gemini,
            bucketID: "gemini-weekly",
            cycleKey: cycleKey,
            modelID: "gemini-3-flash",
            warmedAt: warmedAt
        )
        let state = WeeklyWarmupRuntimeState(records: [cycleKey: staleRecord])
        let policy = WeeklyWarmupPolicy(isEnabled: true, backupAccountsOnly: true, warmGemini: true, warmClaude: true)

        let candidates = service.findEligibleCandidates(
            accounts: [acc],
            policy: policy,
            state: state,
            hasSnapshot: { _ in true },
            referenceDate: syncedLater
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].bucketID, "gemini-weekly")
    }

    func testUnstartedPlaceholderResetAtIsEligibleAndHidesFakeCountdown() {
        let service = WeeklyWarmupService()
        let syncTime = Date(timeIntervalSince1970: 1_770_000_000)

        // Google Cloud Code Assist returns resetAt == syncedAt + 7d for 100% unused weekly buckets
        let placeholderWeeklyReset = syncTime.addingTimeInterval(7 * 86_400)
        // Whereas an already-started weekly bucket has resetAt < syncedAt + 7d - tolerance (e.g. 6d 2h)
        let startedWeeklyReset = syncTime.addingTimeInterval(6 * 86_400 + 2 * 3_600)

        let acc = makeAccount(
            name: "Placeholder Test",
            isActive: false,
            geminiWeeklyFraction: 1.0,
            geminiWeeklyResetAt: startedWeeklyReset,
            claudeWeeklyFraction: 1.0,
            claudeWeeklyResetAt: placeholderWeeklyReset,
            syncedAt: syncTime
        )

        let geminiUsage = acc.modelUsages.first(where: { $0.id == "gemini-weekly" })!
        let claudeUsage = acc.modelUsages.first(where: { $0.id == "3p-weekly" })!

        XCTAssertFalse(geminiUsage.hasUnstartedResetPlaceholder())
        XCTAssertNotNil(geminiUsage.remainingResetLabel(at: syncTime))

        XCTAssertTrue(claudeUsage.hasUnstartedResetPlaceholder())
        XCTAssertNil(claudeUsage.remainingResetLabel(at: syncTime))

        // Immediately after a lightweight warmup (1.2s later), Cloud Code returns frac = 0.99999964 and anchored resetAt = syncedAt + 7d - 1.2s.
        // That bucket MUST be recognized as started immediately (showing countdown & stopping warmup re-runs).
        let postWarmupCheck = syncTime.addingTimeInterval(1.2)
        let justStarted = ModelUsage(
            id: "gemini-weekly",
            displayName: "Gemini Models (Tuần)",
            turnLimit: 1000,
            quotaRemainingFraction: 0.99999964,
            quotaResetAt: syncTime.addingTimeInterval(7 * 86_400),
            quotaSyncedAt: postWarmupCheck
        )
        XCTAssertFalse(justStarted.hasUnstartedResetPlaceholder())
        XCTAssertNotNil(justStarted.remainingResetLabel(at: postWarmupCheck))
        XCTAssertFalse(service.isBucketEligibleForWarmup(justStarted, referenceDate: postWarmupCheck))

        let policy = WeeklyWarmupPolicy(isEnabled: true, backupAccountsOnly: true, warmGemini: true, warmClaude: true)
        let candidates = service.findEligibleCandidates(
            accounts: [acc],
            policy: policy,
            state: WeeklyWarmupRuntimeState(),
            hasSnapshot: { _ in true },
            referenceDate: syncTime
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].bucketID, "3p-weekly")
        XCTAssertTrue(candidates[0].cycleKey.contains(":idle-"))
    }

    func testFiveHourWarmupEligibilityActiveHoursWeeklyGuardAndDeduplication() throws {
        let service = WeeklyWarmupService()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!

        let dayComps = DateComponents(year: 2026, month: 11, day: 24, hour: 10, minute: 0)
        let nightComps = DateComponents(year: 2026, month: 11, day: 24, hour: 2, minute: 0)
        let daytime = try XCTUnwrap(cal.date(from: dayComps))
        let nighttime = try XCTUnwrap(cal.date(from: nightComps))

        let activeWeeklyReset = daytime.addingTimeInterval(3 * 86_400)
        let unstarted5hReset = daytime.addingTimeInterval(5 * 3_600)

        // Account A: Gemini has BOTH weekly & 5h unstarted (should emit ONLY gemini-weekly);
        // Claude has weekly active (37%) and 5h unstarted (100% + 5h placeholder) -> should emit 3p-5h!
        let accA = makeAccount(
            name: "Acc A",
            isActive: false,
            gemini5hFraction: 1.0,
            gemini5hResetAt: unstarted5hReset,
            geminiWeeklyFraction: 1.0,
            geminiWeeklyResetAt: daytime.addingTimeInterval(7 * 86_400),
            claude5hFraction: 1.0,
            claude5hResetAt: unstarted5hReset,
            claudeWeeklyFraction: 0.37,
            claudeWeeklyResetAt: activeWeeklyReset,
            syncedAt: daytime
        )

        // Account B: Claude weekly is depleted (<= 5%), so 5h warmup MUST be skipped by safety guard.
        let accB = makeAccount(
            name: "Acc B Low Weekly",
            isActive: false,
            gemini5hFraction: 0.70,
            gemini5hResetAt: daytime.addingTimeInterval(3 * 3_600),
            geminiWeeklyFraction: 0.90,
            geminiWeeklyResetAt: activeWeeklyReset,
            claude5hFraction: 1.0,
            claude5hResetAt: unstarted5hReset,
            claudeWeeklyFraction: 0.04,
            claudeWeeklyResetAt: activeWeeklyReset,
            syncedAt: daytime
        )

        // 1 & 2. Unified policy emits gemini-weekly (NOT duplicate gemini-5h) + 3p-5h on Acc A, skipping Acc B's 3p-5h
        let with5hPolicy = WeeklyWarmupPolicy(
            isEnabled: true,
            backupAccountsOnly: true,
            warmGemini: true,
            warmClaude: true,
            fiveHourActiveHoursOnly: true,
            fiveHourStartHour: 7,
            fiveHourEndHour: 23
        )
        let daytimeCandidates = service.findEligibleCandidates(
            accounts: [accA, accB],
            policy: with5hPolicy,
            state: WeeklyWarmupRuntimeState(),
            hasSnapshot: { _ in true },
            referenceDate: daytime,
            calendar: cal
        )
        XCTAssertEqual(daytimeCandidates.map(\.bucketID), ["gemini-weekly", "3p-5h"])
        XCTAssertEqual(daytimeCandidates.map(\.accountID), [accA.id, accA.id])
        XCTAssertTrue(daytimeCandidates[1].cycleKey.contains(":idle-5h-"))

        // 3. Auto-run at 02:00 quiet hours skips 5h (keeps weekly), whereas manual trigger ignores quiet hours
        let nightAcc = makeAccount(
            name: "Night Acc",
            isActive: false,
            gemini5hFraction: 0.90,
            gemini5hResetAt: nighttime.addingTimeInterval(3 * 3_600),
            geminiWeeklyFraction: 0.90,
            geminiWeeklyResetAt: nighttime.addingTimeInterval(3 * 86_400),
            claude5hFraction: 1.0,
            claude5hResetAt: nighttime.addingTimeInterval(5 * 3_600),
            claudeWeeklyFraction: 0.45,
            claudeWeeklyResetAt: nighttime.addingTimeInterval(3 * 86_400),
            syncedAt: nighttime
        )
        XCTAssertTrue(
            service.findEligibleCandidates(
                accounts: [nightAcc],
                policy: with5hPolicy,
                state: WeeklyWarmupRuntimeState(),
                hasSnapshot: { _ in true },
                referenceDate: nighttime,
                calendar: cal
            ).isEmpty
        )
        let manualNight = service.findEligibleCandidates(
            accounts: [nightAcc],
            policy: with5hPolicy,
            state: WeeklyWarmupRuntimeState(),
            ignoreAutoEnabledFlag: true,
            hasSnapshot: { _ in true },
            referenceDate: nighttime,
            calendar: cal
        )
        XCTAssertEqual(manualNight.map(\.bucketID), ["3p-5h"])

        // 4. 5h slot key stability within 5h window and rotation after 5 hours
        let slotKey1 = service.normalizedCycleKey(accountID: accA.id, bucketID: "3p-5h", resetAt: nil, referenceDate: daytime)
        let slotKeySame = service.normalizedCycleKey(accountID: accA.id, bucketID: "3p-5h", resetAt: nil, referenceDate: daytime.addingTimeInterval(600))
        let slotKeyNext = service.normalizedCycleKey(accountID: accA.id, bucketID: "3p-5h", resetAt: nil, referenceDate: daytime.addingTimeInterval(5 * 3_600 + 60))
        XCTAssertEqual(slotKey1, slotKeySame)
        XCTAssertNotEqual(slotKey1, slotKeyNext)

        // 5. Legacy WeeklyWarmupPolicy JSON missing 5h keys or containing removed warmFiveHourCycle decodes with safe defaults
        let legacyPolicyJSON = """
        {
          "isEnabled": true,
          "backupAccountsOnly": false,
          "warmGemini": true,
          "warmClaude": false,
          "warmFiveHourCycle": false
        }
        """
        let decodedPolicy = try JSONDecoder().decode(WeeklyWarmupPolicy.self, from: Data(legacyPolicyJSON.utf8))
        XCTAssertTrue(decodedPolicy.isEnabled)
        XCTAssertFalse(decodedPolicy.backupAccountsOnly)
        XCTAssertTrue(decodedPolicy.warmGemini)
        XCTAssertFalse(decodedPolicy.warmClaude)
        XCTAssertTrue(decodedPolicy.fiveHourActiveHoursOnly)
        XCTAssertEqual(decodedPolicy.fiveHourStartHour, 7)
        XCTAssertEqual(decodedPolicy.fiveHourEndHour, 23)
    }

    func testLegacySwitcherSettingsDecodesDefaultWeeklyWarmupPolicy() throws {
        let legacyJSON = """
        {
          "agyAppBundlePath": "/Applications/Antigravity.app",
          "autoRelaunchAGY": true,
          "syncIDESession": false
        }
        """
        let decoded = try JSONDecoder().decode(SwitcherSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.weeklyWarmupPolicy, WeeklyWarmupPolicy())
        XCTAssertFalse(decoded.weeklyWarmupPolicy.isEnabled)
        XCTAssertTrue(decoded.weeklyWarmupPolicy.backupAccountsOnly)
        XCTAssertEqual(decoded.weeklyWarmupPolicy.enabledGroups, [.gemini, .claude])
    }
}
