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

        // 2. Also verify fetchAvailableModels fallback parsing
        let fetchModelsJSON = """
        {
          "models": {
            "MODEL_ARGON": {
              "displayName": "Gemini 4 Argon (High)",
              "model": "gemini-4-argon",
              "quotaInfo": { "remainingFraction": 0.82, "resetTime": "\(futureReset)" }
            },
            "MODEL_FLASH": {
              "displayName": "Gemini 3 Flash",
              "model": "gemini-3-flash",
              "quotaInfo": { "remainingFraction": 0.95, "resetTime": "\(futureReset)" }
            }
          }
        }
        """
        let fallbackSnapshot = service.parseDashboardSnapshot(
            fromModelsData: Data(fetchModelsJSON.utf8),
            loadCodeAssistData: Data(loadAssistJSON.utf8),
            syncedAt: refNow
        )
        XCTAssertEqual(fallbackSnapshot?.quotasByModel["argon-weekly"]?.remainingFraction ?? -1, 0.82, accuracy: 0.0001)
        XCTAssertEqual(fallbackSnapshot?.quotasByModel["gemini-5h"]?.remainingFraction ?? -1, 0.95, accuracy: 0.0001)
    }

    func testRetrieveUserQuotaMergesArgonWhenFetchAvailableModelsOmitsQuotaInfo() {
        let service = CloudCodeQuotaService()
        let refNow = Date(timeIntervalSince1970: 1_750_000_000)

        let modelsJSON = """
        {
          "models": {
            "MODEL_ARGON": {
              "displayName": "Gemini 4 Argon",
              "model": "gemini-4-argon"
            }
          }
        }
        """
        let userQuotaJSON = """
        {
          "buckets": [
            {
              "modelId": "gemini-4-argon",
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
        XCTAssertEqual(snapshot?.quotasByModel["argon-weekly"]?.remainingFraction ?? -1, 0.28, accuracy: 0.0001)
        XCTAssertEqual(snapshot?.quotasByModel["gemini-5h"]?.remainingFraction ?? -1, 0.91, accuracy: 0.0001)
    }

    @MainActor
    func testQuotaThresholdNotifierAlertsOncePerWindowForArgonAndGeminiAt30Percent() {
        var sentAlerts: [(title: String, body: String, id: String)] = []
        let notifier = QuotaThresholdNotifier(thresholdPercent: 30) { title, body, id in
            sentAlerts.append((title, body, id))
        }

        let futureReset = Date().addingTimeInterval(3600 * 24)
        var usages = ModelUsage.defaultSet(for: .pro)
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

    func testParseAgyCLIStreamJSONAndFallbackToSharedGeminiWeeklyForArgon() {
        let service = CloudCodeQuotaService()

        // 1. CLI `agy -p /usage --output-format stream-json` NDJSON parser
        let cliOutput = """
        {"event":"log","message":"starting"}
        {"event":"command_result","command":{"name":"usage","data":{"groups":[{"name":"Gemini 4 Argon","buckets":[{"id":"argon-weekly","window":"weekly","remaining_fraction":0.02,"reset_time":"2026-11-22T12:00:00Z"}]}]}}}
        """
        let cliQuotas = service.parseAgyCLIUsageOutput(cliOutput)
        XCTAssertEqual(cliQuotas["argon-weekly"]?.remainingFraction ?? -1, 0.02, accuracy: 0.0001)
        XCTAssertNotNil(cliQuotas["argon-weekly"]?.resetAt)

        // 2. Shared Gemini Weekly fallback onto Argon when server omits separate Argon group
        let summaryWithoutArgonJSON = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-5h",
                  "remainingFraction": 0.31,
                  "resetTime": "2026-11-17T18:00:00Z"
                },
                {
                  "bucketId": "gemini-weekly",
                  "remainingFraction": 0.72,
                  "resetTime": "2026-11-22T12:00:00Z"
                }
              ]
            }
          ]
        }
        """
        let projectedSnapshot = service.parseDashboardSnapshot(
            fromQuotaSummaryData: Data(summaryWithoutArgonJSON.utf8)
        )
        XCTAssertNotNil(projectedSnapshot?.quotasByModel["argon-weekly"])
        XCTAssertEqual(projectedSnapshot?.quotasByModel["argon-weekly"]?.remainingFraction ?? -1, 0.72, accuracy: 0.0001)
        XCTAssertEqual(projectedSnapshot?.quotasByModel["argon-weekly"]?.resetAt, projectedSnapshot?.quotasByModel["gemini-weekly"]?.resetAt)

        let existing = ModelUsage.defaultSet(for: .pro)
        let applied = service.applyDashboardSnapshot(projectedSnapshot!, into: existing, currentTier: .pro)
        let argonRow = applied.usages.first(where: { $0.id == "argon-weekly" })
        XCTAssertTrue(argonRow?.hasDashboardQuota ?? false)
        XCTAssertEqual(argonRow?.remainingPercentageInt, 72)
    }
}
