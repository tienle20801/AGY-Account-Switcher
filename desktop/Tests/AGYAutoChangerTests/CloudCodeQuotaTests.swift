import Foundation
import XCTest
@testable import AGYAutoChanger

final class CloudCodeQuotaTests: TempDirectoryTestCase {

    func testCloudCodeDashboardSnapshotHandlesTiersAndProto3ZeroFraction() {
        let service = CloudCodeQuotaService()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let refNow = Date(timeIntervalSince1970: 1_750_000_000)
        let futureReset = fmt.string(from: refNow.addingTimeInterval(3600 * 2))
        let futureWeeklyReset = fmt.string(from: refNow.addingTimeInterval(3600 * 24 * 5))
        let expiredReset = fmt.string(from: refNow.addingTimeInterval(-600))

        // 1. Test Google One AI Pro paidTier precedence + retrieveUserQuotaSummary buckets
        let loadAssistJSON = """
        {
          "currentTier": { "id": "free-tier", "name": "Antigravity" },
          "paidTier": { "id": "g1-pro-tier", "name": "Google AI Pro" },
          "cloudaicompanionProject": "aicode-consumers"
        }
        """
        let quotaSummaryJSON = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-5h",
                  "remainingFraction": 0.6747,
                  "resetTime": "\(futureReset)"
                },
                {
                  "bucketId": "gemini-weekly",
                  "remainingFraction": 0.4124,
                  "resetTime": "\(futureWeeklyReset)"
                }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {
                  "bucketId": "3p-5h",
                  "resetTime": "\(futureReset)"
                },
                {
                  "bucketId": "3p-weekly",
                  "remainingFraction": 0.25,
                  "resetTime": "\(expiredReset)"
                }
              ]
            },
            {
              "displayName": "Gemini 4 Argon",
              "buckets": [
                {
                  "bucketId": "weekly-limit",
                  "displayName": "Weekly limit",
                  "remainingFraction": 0.02,
                  "resetTime": "\(futureWeeklyReset)"
                }
              ]
            }
          ]
        }
        """

        let summarySnapshot = service.parseDashboardSnapshot(
            fromQuotaSummaryData: Data(quotaSummaryJSON.utf8),
            loadCodeAssistData: Data(loadAssistJSON.utf8),
            syncedAt: refNow
        )

        XCTAssertNotNil(summarySnapshot)
        XCTAssertEqual(summarySnapshot?.detectedTier, .pro)
        XCTAssertEqual(summarySnapshot?.quotasByModel["gemini-5h"]?.remainingFraction ?? -1, 0.6747, accuracy: 0.0001)
        XCTAssertEqual(summarySnapshot?.quotasByModel["gemini-weekly"]?.remainingFraction ?? -1, 0.4124, accuracy: 0.0001)
        XCTAssertEqual(summarySnapshot?.quotasByModel["argon-weekly"]?.remainingFraction ?? -1, 0.02, accuracy: 0.0001)
        // Omitted remainingFraction with resetTime means proto3 0.0 -> 0% remaining
        XCTAssertEqual(summarySnapshot?.quotasByModel["3p-5h"]?.remainingFraction, 0.0)

        var existing = ModelUsage.defaultSet(for: .free)
        existing[0].turnsUsed = 5
        existing[0].tokensUsed = 9_900

        let applied = service.applyDashboardSnapshot(summarySnapshot!, into: existing, currentTier: .free)
        XCTAssertEqual(applied.tier, .pro)
        let gemini5h = applied.usages.first(where: { $0.id == "gemini-5h" })
        XCTAssertEqual(gemini5h?.turnsUsed, 5)
        XCTAssertEqual(gemini5h?.tokensUsed, 9_900)
        XCTAssertEqual(gemini5h?.remainingFractionValue(at: refNow) ?? -1, 0.6747, accuracy: 0.0001)
        XCTAssertTrue(applied.usages.first(where: { $0.id == "3p-5h" })?.isRateLimited(at: refNow) ?? false)
        // Expired resetTime should evaluate back to 100% remaining and not rate-limited
        let threePWeekly = applied.usages.first(where: { $0.id == "3p-weekly" })
        XCTAssertEqual(threePWeekly?.remainingFractionValue(at: refNow), 1.0)
        XCTAssertFalse(threePWeekly?.isRateLimited(at: refNow) ?? true)

        // 2. Also verify fetchAvailableModels fallback parsing (with shared Gemini 4 models & ignored tab autocomplete)
        let fetchModelsJSON = """
        {
          "models": {
            "gemini-4-argon": {
              "displayName": "Gemini 4 Argon (Medium)",
              "model": "MODEL_PLACEHOLDER_M99",
              "quotaInfo": { "remainingFraction": 0.82, "resetTime": "\(futureReset)" }
            },
            "gemini-4-carbon": {
              "displayName": "Gemini 4 Carbon (Medium)",
              "model": "MODEL_PLACEHOLDER_M100",
              "quotaInfo": { "remainingFraction": 0.88, "resetTime": "\(futureReset)" }
            },
            "gemini-3-flash": {
              "displayName": "Gemini 3 Flash",
              "model": "MODEL_PLACEHOLDER_M18",
              "quotaInfo": { "remainingFraction": 0.95, "resetTime": "\(futureReset)" }
            },
            "tab_flash_lite_preview": {
              "model": "MODEL_PLACEHOLDER_M19",
              "quotaInfo": { "remainingFraction": 1.0 }
            }
          }
        }
        """
        let fallbackSnapshot = service.parseDashboardSnapshot(
            fromModelsData: Data(fetchModelsJSON.utf8),
            loadCodeAssistData: Data(loadAssistJSON.utf8),
            syncedAt: refNow
        )
        XCTAssertEqual(fallbackSnapshot?.quotasByModel["gemini-5h"]?.remainingFraction ?? -1, 0.82, accuracy: 0.0001)
        XCTAssertNil(fallbackSnapshot?.quotasByModel["argon-weekly"])
        XCTAssertNil(fallbackSnapshot?.quotasByModel["tab_flash_lite_preview"])
    }

    func testRetrieveUserQuotaMergesPhysicalModelsIntoGemini5hWhenFetchAvailableModelsOmitsQuotaInfo() {
        let service = CloudCodeQuotaService()
        let refNow = Date(timeIntervalSince1970: 1_750_000_000)

        let modelsJSON = """
        {
          "models": {
            "gemini-4-carbon": {
              "displayName": "Gemini 4 Carbon",
              "model": "MODEL_PLACEHOLDER_M100"
            }
          }
        }
        """
        let userQuotaJSON = """
        {
          "buckets": [
            {
              "modelId": "gemini-4-carbon",
              "remainingFraction": 0.28,
              "resetTime": "2026-11-22T12:00:00Z"
            },
            {
              "modelId": "gemini-3-flash",
              "remainingFraction": 0.91,
              "resetTime": "2026-11-17T20:00:00Z"
            }
          ]
        }
        """

        let snapshot = service.parseDashboardSnapshot(
            fromModelsData: Data(modelsJSON.utf8),
            userQuotaData: Data(userQuotaJSON.utf8),
            syncedAt: refNow
        )

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.quotasByModel["gemini-5h"]?.remainingFraction ?? -1, 0.28, accuracy: 0.0001)
    }

    @MainActor
    func testQuotaThresholdNotifierAlertsOncePerWindowForArgonAndGeminiAt30Percent() {
        var sentAlerts: [(title: String, body: String, id: String)] = []
        let notifier = QuotaThresholdNotifier(thresholdPercent: 30) { title, body, id in
            sentAlerts.append((title, body, id))
        }

        let futureReset = Date().addingTimeInterval(3600 * 24)
        var usages = ModelUsage.defaultSet(for: .pro)
        usages.append(
            ModelUsage(
                id: "argon-weekly",
                displayName: "Gemini 4 Argon (Tuần)",
                turnLimit: 200,
                quotaRemainingFraction: 0.24,
                quotaResetAt: futureReset
            )
        )
        for idx in usages.indices {
            usages[idx].quotaResetAt = futureReset
            switch usages[idx].id {
            case "gemini-5h":
                usages[idx].quotaRemainingFraction = 0.30 // Hits 30% -> should notify
            case "gemini-weekly":
                usages[idx].quotaRemainingFraction = 0.45 // Above 30% -> no alert
            case "3p-5h":
                usages[idx].quotaRemainingFraction = 0.10 // 3P is not monitored -> no alert
            case "argon-weekly":
                usages[idx].quotaRemainingFraction = 0.24 // Below 30% -> should notify
            default:
                usages[idx].quotaRemainingFraction = 1.0
            }
        }

        var activeAccount = AccountProfile(
            email: "user@example.com",
            displayName: "Acc Pro",
            tier: .pro,
            isActive: true,
            modelUsages: usages
        )

        // First evaluation fires 2 alerts (gemini-5h + argon-weekly)
        notifier.evaluateAndNotify(for: [activeAccount])
        XCTAssertEqual(sentAlerts.count, 2)

        // Repeated evaluation in same reset window does NOT duplicate alerts
        notifier.evaluateAndNotify(for: [activeAccount])
        XCTAssertEqual(sentAlerts.count, 2)

        // After reset recovers above 30%, alert re-arms
        if let argonIdx = activeAccount.modelUsages.firstIndex(where: { $0.id == "argon-weekly" }) {
            activeAccount.modelUsages[argonIdx].quotaRemainingFraction = 1.0
        }
        notifier.evaluateAndNotify(for: [activeAccount])
        XCTAssertEqual(sentAlerts.count, 2)

        // Dropping back to <= 30% in new cycle notifies again
        if let argonIdx = activeAccount.modelUsages.firstIndex(where: { $0.id == "argon-weekly" }) {
            activeAccount.modelUsages[argonIdx].quotaRemainingFraction = 0.29
            activeAccount.modelUsages[argonIdx].quotaResetAt = futureReset.addingTimeInterval(3600)
        }
        notifier.evaluateAndNotify(for: [activeAccount])
        XCTAssertEqual(sentAlerts.count, 3)

        // Disabled notifications suppress all alerts even when below threshold
        if let geminiWeeklyIdx = activeAccount.modelUsages.firstIndex(where: { $0.id == "gemini-weekly" }) {
            activeAccount.modelUsages[geminiWeeklyIdx].quotaRemainingFraction = 0.45
        }
        notifier.evaluateAndNotify(for: [activeAccount], isEnabled: false, thresholdPercent: 50)
        XCTAssertEqual(sentAlerts.count, 3)

        // Custom threshold (50%) alerts for gemini-weekly (45%)
        notifier.evaluateAndNotify(for: [activeAccount], isEnabled: true, thresholdPercent: 50)
        XCTAssertEqual(sentAlerts.count, 4)
        XCTAssertTrue(sentAlerts.last?.body.contains("≤ 50%") ?? false)
    }

    func testDynamicFutureGroupsGroupMembersHintAndPruningRetiredArgon() {
        let service = CloudCodeQuotaService()
        let refNow = Date(timeIntervalSince1970: 1_750_000_000)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let future5h = fmt.string(from: refNow.addingTimeInterval(3600 * 3))
        let futureWeek = fmt.string(from: refNow.addingTimeInterval(3600 * 24 * 6))

        // 1. CLI `agy -p /usage --output-format stream-json` extracts dynamic `groupMembersHint` without leaking Neon/Argon into separate fake buckets
        let cliOutput = """
        {"event":"command_result","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","description":"Models within this group: Gemini 4 Neon, Gemini 4 Carbon, Gemini 4 Argon, Gemini 4 Hydrogen","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.94,"reset_time":"\(futureWeek)"},{"id":"gemini-5h","window":"5h","remaining_fraction":0.79,"reset_time":"\(future5h)"}]}]}}}
        """
        let cliQuotas = service.parseAgyCLIUsageOutput(cliOutput)
        XCTAssertEqual(cliQuotas["gemini-weekly"]?.remainingFraction ?? -1, 0.94, accuracy: 0.0001)
        XCTAssertEqual(cliQuotas["gemini-weekly"]?.groupMembersHint, "Gemini 4 Neon, Gemini 4 Carbon, Gemini 4 Argon, Gemini 4 Hydrogen")
        XCTAssertNil(cliQuotas["argon-weekly"])

        // 2. REST summary with a brand-new unknown future group ("Gemini 5 Ultra") + retired `argon-weekly` missing -> dynamic discovery + prune
        let summaryWithFutureGroupJSON = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "description": "Models within this group: Gemini 4 Neon, Gemini 4 Carbon, Gemini 3.8 Flash",
              "buckets": [
                { "bucketId": "gemini-5h", "remainingFraction": 0.71, "resetTime": "\(future5h)" },
                { "bucketId": "gemini-weekly", "remainingFraction": 0.92, "resetTime": "\(futureWeek)" }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "description": "Models within this group: Claude Opus 5.5, Claude Sonnet 5.5",
              "buckets": [
                { "bucketId": "3p-5h", "remainingFraction": 1.0, "resetTime": "\(future5h)" },
                { "bucketId": "3p-weekly", "remainingFraction": 0.37, "resetTime": "\(futureWeek)" }
              ]
            },
            {
              "displayName": "Gemini 5 Ultra",
              "description": "Models within this group: Gemini 5 Ultra Preview",
              "buckets": [
                { "bucketId": "weekly-limit", "window": "weekly", "remainingFraction": 0.55, "resetTime": "\(futureWeek)" },
                { "bucketId": "5h-limit", "window": "5h", "remainingFraction": 0.80, "resetTime": "\(future5h)" }
              ]
            }
          ]
        }
        """
        let snapshot = service.parseDashboardSnapshot(
            fromQuotaSummaryData: Data(summaryWithFutureGroupJSON.utf8),
            syncedAt: refNow
        )
        XCTAssertNotNil(snapshot?.quotasByModel["gemini-5-ultra-weekly"])
        XCTAssertNotNil(snapshot?.quotasByModel["gemini-5-ultra-5h"])
        XCTAssertEqual(snapshot?.quotasByModel["gemini-5-ultra-weekly"]?.shortLabel, "Gemini 5 Ultra Tuần")
        XCTAssertEqual(snapshot?.quotasByModel["gemini-5h"]?.groupMembersHint, "Gemini 4 Neon, Gemini 4 Carbon, Gemini 3.8 Flash")
        XCTAssertNil(snapshot?.quotasByModel["argon-weekly"])

        // Existing account with stale retired `argon-weekly = 6%` should prune `argon-weekly` and attach `Gemini 5 Ultra`
        var existing = ModelUsage.defaultSet(for: .pro)
        existing.append(
            ModelUsage(
                id: "argon-weekly",
                displayName: "Gemini 4 Argon (Tuần)",
                turnLimit: 200,
                quotaRemainingFraction: 0.06,
                quotaResetAt: futureWeek.isEmpty ? nil : UsageTrackerService.parseISO8601(futureWeek)
            )
        )
        let applied = service.applyDashboardSnapshot(snapshot!, into: existing, currentTier: .pro)
        XCTAssertNil(applied.usages.first(where: { $0.id == "argon-weekly" }))
        let futureUltraFrac = applied.usages.first(where: { $0.id == "gemini-5-ultra-weekly" })?.remainingFractionValue(at: refNow) ?? -1
        XCTAssertEqual(futureUltraFrac, 0.55, accuracy: 0.0001)
        XCTAssertEqual(applied.usages.first(where: { $0.id == "gemini-5h" })?.groupMembersHint, "Gemini 4 Neon, Gemini 4 Carbon, Gemini 3.8 Flash")
    }

    func testDedicatedCarbonPoolStaysSeparateFromSharedGemini() {
        let service = CloudCodeQuotaService()
        let refNow = Date(timeIntervalSince1970: 1_750_000_000)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let future5h = fmt.string(from: refNow.addingTimeInterval(3600 * 3))
        let futureWeek = fmt.string(from: refNow.addingTimeInterval(3600 * 24 * 6))

        let summaryWithCarbonJSON = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                { "bucketId": "gemini-5h", "remainingFraction": 0.90, "resetTime": "\(future5h)" },
                { "bucketId": "gemini-weekly", "remainingFraction": 0.85, "resetTime": "\(futureWeek)" }
              ]
            },
            {
              "displayName": "Gemini 4 Carbon",
              "buckets": [
                { "bucketId": "gemini-carbon-5h", "remainingFraction": 0.35, "resetTime": "\(future5h)" },
                { "bucketId": "gemini-carbon-wtu-weekly", "remainingFraction": 0.15, "resetTime": "\(futureWeek)" }
              ]
            }
          ]
        }
        """

        let snapshot = service.parseDashboardSnapshot(
            fromQuotaSummaryData: Data(summaryWithCarbonJSON.utf8),
            syncedAt: refNow,
            projectSharedGeminiFallback: false
        )
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.quotasByModel["gemini-5h"]?.remainingFraction ?? -1, 0.90, accuracy: 0.0001)
        XCTAssertEqual(snapshot?.quotasByModel["gemini-weekly"]?.remainingFraction ?? -1, 0.85, accuracy: 0.0001)
        XCTAssertEqual(snapshot?.quotasByModel["carbon-5h"]?.remainingFraction ?? -1, 0.35, accuracy: 0.0001)
        XCTAssertEqual(snapshot?.quotasByModel["carbon-weekly"]?.remainingFraction ?? -1, 0.15, accuracy: 0.0001)

        let existing = ModelUsage.defaultSet(for: .ultra)
        let applied = service.applyDashboardSnapshot(snapshot!, into: existing, currentTier: .ultra)
        let profile = AccountProfile(email: "carbon@dev.com", displayName: "Carbon", tier: applied.tier, modelUsages: applied.usages)
        XCTAssertTrue(profile.hasDedicatedCarbonPool)
        XCTAssertEqual(profile.modelUsages.first(where: { $0.id == "carbon-5h" })?.remainingFractionValue(at: refNow) ?? -1, 0.35, accuracy: 0.0001)
        XCTAssertEqual(profile.modelUsages.first(where: { $0.id == "carbon-weekly" })?.remainingFractionValue(at: refNow) ?? -1, 0.15, accuracy: 0.0001)

        // An account without Carbon in server response must NOT receive fabricated Carbon rows.
        let plainSnapshot = CloudCodeDashboardSnapshot(
            quotasByModel: ["gemini-5h": ModelDashboardQuota(canonicalModelID: "gemini-5h", remainingFraction: 0.80)],
            syncedAt: refNow
        )
        let plainApplied = service.applyDashboardSnapshot(plainSnapshot, into: ModelUsage.defaultSet(for: .pro), currentTier: .pro)
        XCTAssertNil(plainApplied.usages.first(where: { $0.id == "carbon-5h" }))
        XCTAssertNil(plainApplied.usages.first(where: { $0.id == "carbon-weekly" }))
    }
}
