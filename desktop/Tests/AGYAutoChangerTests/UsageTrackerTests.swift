import Foundation
import SQLite3
import XCTest
@testable import AGYAutoChanger

final class UsageTrackerTests: TempDirectoryTestCase {

    func testUsageTrackerCountsRollingWindowTurnsPerModelAndPreservesCooldown() throws {
        let tracker = UsageTrackerService()
        let brainDir = tempRoot.appendingPathComponent("brain", isDirectory: true)
        let logsDir = brainDir
            .appendingPathComponent("conv-123", isDirectory: true)
            .appendingPathComponent(".system_generated", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let now = Date()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let oldTime = fmt.string(from: now.addingTimeInterval(-8 * 3600)) // Outside 5h window
        let recent1 = fmt.string(from: now.addingTimeInterval(-3600))
        let recent2 = fmt.string(from: now.addingTimeInterval(-1800))
        let recent3 = fmt.string(from: now.addingTimeInterval(-600))

        let lines = [
            #"{"type":"PLANNER_RESPONSE","created_at":"\#(oldTime)","content":"stale turn"}"#,
            #"{"type":"USER_INPUT","created_at":"\#(recent1)","content":"<USER_SETTINGS_CHANGE>Model Selection from None to Orchestrator (Argon)</USER_SETTINGS_CHANGE>"}"#,
            #"{"type":"PLANNER_RESPONSE","created_at":"\#(recent1)","content":"turn 1"}"#,
            #"{"type":"PLANNER_RESPONSE","created_at":"\#(recent1)","content":"turn 2"}"#,
            #"{"type":"USER_INPUT","created_at":"\#(recent2)","content":"Model Selection changed to Gemini 4 Pro"}"#,
            #"{"type":"PLANNER_RESPONSE","created_at":"\#(recent2)","content":"turn 3"}"#,
            #"{"type":"USER_INPUT","created_at":"\#(recent3)","content":"Model Selection changed to Gemini 4 Hydrogen"}"#,
            #"{"type":"PLANNER_RESPONSE","created_at":"\#(recent3)","content":"turn 4"}"#
        ].joined(separator: "\n")

        try lines.write(
            to: logsDir.appendingPathComponent("transcript.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let emptyConversationsDir = tempRoot.appendingPathComponent("empty_convos", isDirectory: true)
        let summary = tracker.scanUsage(
            brainDir: brainDir,
            conversationsDir: emptyConversationsDir,
            rollingWindowHours: 5.0,
            referenceDate: now
        )
        XCTAssertEqual(summary.turnsByModel["gemini-5h"], 4)
        XCTAssertEqual(summary.turnsByModel["gemini-weekly"], 4)
        XCTAssertNil(summary.turnsByModel["argon-weekly"])
        XCTAssertNil(summary.turnsByModel["3p-5h"])

        var existing = ModelUsage.defaultSet(for: .pro)
        let cooldownTarget = now.addingTimeInterval(1800)
        existing[0].cooldownUntil = cooldownTarget

        let merged = tracker.merge(summary: summary, into: existing, tier: .pro)
        XCTAssertEqual(merged.first(where: { $0.id == "gemini-5h" })?.turnsUsed, 4)
        XCTAssertEqual(merged.first(where: { $0.id == "gemini-5h" })?.cooldownUntil, cooldownTarget)
        XCTAssertTrue(merged.first(where: { $0.id == "gemini-5h" })?.isRateLimited(at: now) ?? false)
    }

    func testIncrementalUsageMergePreservesDashboardQuotaAndTurnsAcrossSwitches() {
        let tracker = UsageTrackerService()
        let syncDate = Date()
        let resetDate = syncDate.addingTimeInterval(3600 * 3)
        let cooldownDate = syncDate.addingTimeInterval(1800)

        var existing = ModelUsage.defaultSet(for: .pro)
        existing[0].turnsUsed = 12
        existing[0].tokensUsed = 14_500
        existing[0].quotaRemainingFraction = 0.65
        existing[0].quotaResetAt = resetDate
        existing[0].quotaSyncedAt = syncDate
        existing[1].turnsUsed = 4
        existing[1].cooldownUntil = cooldownDate

        // Simulate immediate post-switch scan with empty delta (sinceAccountSwitch = Date())
        let emptyDelta = ModelUsageSummary()
        let afterSwitch = tracker.mergeIncremental(summary: emptyDelta, into: existing, tier: .pro)

        let gemini5hAfterSwitch = afterSwitch.first(where: { $0.id == "gemini-5h" })
        XCTAssertEqual(gemini5hAfterSwitch?.turnsUsed, 12)
        XCTAssertEqual(gemini5hAfterSwitch?.tokensUsed, 14_500)
        XCTAssertEqual(gemini5hAfterSwitch?.quotaRemainingFraction, 0.65)
        XCTAssertEqual(gemini5hAfterSwitch?.quotaResetAt, resetDate)
        XCTAssertEqual(gemini5hAfterSwitch?.remainingPercentageInt, 65)
        XCTAssertEqual(afterSwitch.first(where: { $0.id == "gemini-weekly" })?.cooldownUntil, cooldownDate)

        // Simulate subsequent incremental telemetry (+3 turns, +2000 tokens)
        let newDelta = ModelUsageSummary(
            turnsByModel: ["gemini-5h": 3],
            tokensByModel: ["gemini-5h": 2_000],
            lastUsedByModel: ["gemini-5h": syncDate.addingTimeInterval(120)]
        )
        let incremented = tracker.mergeIncremental(summary: newDelta, into: afterSwitch, tier: .pro)
        let gemini5hIncremented = incremented.first(where: { $0.id == "gemini-5h" })
        XCTAssertEqual(gemini5hIncremented?.turnsUsed, 15)
        XCTAssertEqual(gemini5hIncremented?.tokensUsed, 16_500)
        XCTAssertEqual(gemini5hIncremented?.quotaRemainingFraction, 0.65)
    }

    func testSQLiteProtobufScannerExtractsAgyHudGenMetadata() throws {
        let tracker = UsageTrackerService()
        let brainDir = tempRoot.appendingPathComponent("empty_brain", isDirectory: true)
        let conversationsDir = tempRoot.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: brainDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)

        let now = Date()
        let staleTsSeconds = UInt64(now.addingTimeInterval(-8 * 3600).timeIntervalSince1970)
        let freshTsSeconds = UInt64(now.addingTimeInterval(-300).timeIntervalSince1970)

        var usageInner = Data()
        usageInner.append(contentsOf: protoVarintField(2, 120))
        usageInner.append(contentsOf: protoVarintField(3, 90))

        var kvLastStep = Data()
        kvLastStep.append(contentsOf: protoLengthField(1, Data("last_step_index".utf8)))
        kvLastStep.append(contentsOf: protoLengthField(2, Data("42".utf8)))

        var genInner = Data()
        genInner.append(contentsOf: protoLengthField(4, usageInner))
        genInner.append(contentsOf: protoLengthField(19, Data("gemini-4-hydrogen".utf8)))
        genInner.append(contentsOf: protoLengthField(20, kvLastStep))
        genInner.append(contentsOf: protoLengthField(21, Data("Gemini 4 Hydrogen".utf8)))

        let genBlob = protoLengthField(1, genInner)
        let staleMetaBlob = protoLengthField(1, protoVarintField(1, staleTsSeconds))
        let freshMetaBlob = protoLengthField(6, protoVarintField(1, freshTsSeconds))

        let dbURL = conversationsDir.appendingPathComponent("conv-1234.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let createSQL = """
        CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);
        CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB);
        """
        XCTAssertEqual(sqlite3_exec(db, createSQL, nil, nil, nil), SQLITE_OK)

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        var genStmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data) VALUES (0, ?);", -1, &genStmt, nil), SQLITE_OK)
        _ = genBlob.withUnsafeBytes { ptr in
            sqlite3_bind_blob(genStmt, 1, ptr.baseAddress, Int32(genBlob.count), sqliteTransient)
        }
        XCTAssertEqual(sqlite3_step(genStmt), SQLITE_DONE)
        sqlite3_finalize(genStmt)

        var staleStepStmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO steps (idx, metadata) VALUES (0, ?);", -1, &staleStepStmt, nil), SQLITE_OK)
        _ = staleMetaBlob.withUnsafeBytes { ptr in
            sqlite3_bind_blob(staleStepStmt, 1, ptr.baseAddress, Int32(staleMetaBlob.count), sqliteTransient)
        }
        XCTAssertEqual(sqlite3_step(staleStepStmt), SQLITE_DONE)
        sqlite3_finalize(staleStepStmt)

        var freshStepStmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO steps (idx, metadata) VALUES (42, ?);", -1, &freshStepStmt, nil), SQLITE_OK)
        _ = freshMetaBlob.withUnsafeBytes { ptr in
            sqlite3_bind_blob(freshStepStmt, 1, ptr.baseAddress, Int32(freshMetaBlob.count), sqliteTransient)
        }
        XCTAssertEqual(sqlite3_step(freshStepStmt), SQLITE_DONE)
        sqlite3_finalize(freshStepStmt)

        let summary = tracker.scanUsage(
            brainDir: brainDir,
            conversationsDir: conversationsDir,
            rollingWindowHours: 5.0,
            referenceDate: now
        )
        XCTAssertEqual(summary.turnsByModel["gemini-5h"], 1)
        XCTAssertEqual(summary.turnsByModel["gemini-weekly"], 1)
        XCTAssertEqual(summary.tokensByModel["gemini-5h"], 210)
        XCTAssertEqual(summary.latestModelDisplayName, "Gemini 4 Hydrogen")
    }

    func testScanTodayOverviewExtractsTokensCacheHitAndEstimatedCost() throws {
        let tracker = UsageTrackerService()
        let brainDir = tempRoot.appendingPathComponent("brain_today", isDirectory: true)
        let conversationsDir = tempRoot.appendingPathComponent("convos_today", isDirectory: true)
        try FileManager.default.createDirectory(at: brainDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)

        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 14
        components.minute = 0
        components.second = 0
        let refNoon = Calendar.current.date(from: components) ?? Date()
        let todayTs = UInt64(refNoon.addingTimeInterval(-600).timeIntervalSince1970)
        let yesterdayTs = UInt64(refNoon.addingTimeInterval(-36 * 3600).timeIntervalSince1970)

        var todayUsage = Data()
        todayUsage.append(contentsOf: protoVarintField(2, 1000))
        todayUsage.append(contentsOf: protoVarintField(3, 500))
        todayUsage.append(contentsOf: protoVarintField(5, 3000))

        var kvToday = Data()
        kvToday.append(contentsOf: protoLengthField(1, Data("last_step_index".utf8)))
        kvToday.append(contentsOf: protoLengthField(2, Data("1".utf8)))

        var genToday = Data()
        genToday.append(contentsOf: protoLengthField(4, todayUsage))
        genToday.append(contentsOf: protoLengthField(19, Data("claude-sonnet-4-5".utf8)))
        genToday.append(contentsOf: protoLengthField(20, kvToday))

        var kvYesterday = Data()
        kvYesterday.append(contentsOf: protoLengthField(1, Data("last_step_index".utf8)))
        kvYesterday.append(contentsOf: protoLengthField(2, Data("0".utf8)))

        var genYesterday = Data()
        genYesterday.append(contentsOf: protoLengthField(4, todayUsage))
        genYesterday.append(contentsOf: protoLengthField(19, Data("claude-sonnet-4-5".utf8)))
        genYesterday.append(contentsOf: protoLengthField(20, kvYesterday))

        let dbURL = conversationsDir.appendingPathComponent("conv-today.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let createSQL = """
        CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);
        CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB);
        """
        XCTAssertEqual(sqlite3_exec(db, createSQL, nil, nil, nil), SQLITE_OK)
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        func insertBlob(_ sql: String, _ idx: Int, _ blob: Data) {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(idx))
            _ = blob.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(blob.count), sqliteTransient)
            }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }

        insertBlob("INSERT INTO steps (idx, metadata) VALUES (?, ?);", 0, protoLengthField(6, protoVarintField(1, yesterdayTs)))
        insertBlob("INSERT INTO steps (idx, metadata) VALUES (?, ?);", 1, protoLengthField(6, protoVarintField(1, todayTs)))
        insertBlob("INSERT INTO gen_metadata (idx, data) VALUES (?, ?);", 0, protoLengthField(1, genYesterday))
        insertBlob("INSERT INTO gen_metadata (idx, data) VALUES (?, ?);", 1, protoLengthField(1, genToday))

        let transcriptLogsDir = brainDir
            .appendingPathComponent("conv-transcript", isDirectory: true)
            .appendingPathComponent(".system_generated", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptLogsDir, withIntermediateDirectories: true)

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let todayISO = fmt.string(from: refNoon.addingTimeInterval(-120))
        let transcriptLine = #"{"type":"PLANNER_RESPONSE","created_at":"\#(todayISO)","model":"gemini-2.5-pro","input_tokens":200,"output_tokens":100,"cache_read_tokens":200}"#
        try transcriptLine.write(
            to: transcriptLogsDir.appendingPathComponent("transcript.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let overview = tracker.scanTodayOverview(
            brainDir: brainDir,
            conversationsDir: conversationsDir,
            referenceDate: refNoon
        )
        XCTAssertEqual(overview.totalTurns, 2)
        XCTAssertEqual(overview.inputTokens, 1200)
        XCTAssertEqual(overview.outputTokens, 600)
        XCTAssertEqual(overview.cachedTokens, 3200)
        XCTAssertEqual(overview.totalTokens, 5000)
        XCTAssertEqual(overview.cacheHitPercentage, 73)
        XCTAssertEqual(overview.estimatedCostUSD, 0.011725, accuracy: 0.000001)
    }

    func testComputeAggregateQuotaIgnoresDisabledAccountsAndUnknownBuckets() {
        let now = Date()
        let futureReset = now.addingTimeInterval(3600)

        var usages1 = ModelUsage.defaultSet(for: .pro)
        usages1[0].quotaRemainingFraction = 0.80 // gemini-5h
        usages1[0].quotaResetAt = futureReset
        usages1[1].quotaRemainingFraction = 0.60 // gemini-weekly
        usages1[1].quotaResetAt = futureReset
        usages1[2].quotaRemainingFraction = 0.40 // 3p-5h
        usages1[2].quotaResetAt = futureReset
        let acc1 = AccountProfile(email: "a1@dev.com", displayName: "A1", tier: .pro, modelUsages: usages1)

        var usages2 = ModelUsage.defaultSet(for: .pro)
        usages2[0].quotaRemainingFraction = 1.0
        usages2[0].quotaResetAt = futureReset
        usages2[1].quotaRemainingFraction = 1.0
        usages2[1].quotaResetAt = futureReset
        let acc2Disabled = AccountProfile(email: "a2@dev.com", displayName: "A2", tier: .pro, isDisabled: true, modelUsages: usages2)

        let acc3Unknown = AccountProfile(email: "a3@dev.com", displayName: "A3", tier: .pro)

        var usages4 = ModelUsage.defaultSet(for: .pro)
        usages4[0].quotaRemainingFraction = 0.0 // rate-limited
        usages4[0].quotaResetAt = futureReset
        usages4[1].quotaRemainingFraction = 0.05 // below 10% reserve
        usages4[1].quotaResetAt = futureReset
        let acc4Low = AccountProfile(email: "a4@dev.com", displayName: "A4", tier: .pro, modelUsages: usages4)

        let aggAll = UsageTrackerService.computeAggregateQuota(
            for: [acc1, acc2Disabled, acc3Unknown, acc4Low],
            reserveThresholdPercent: 10,
            modelScope: .all,
            referenceDate: now
        )
        XCTAssertEqual(aggAll.totalEnabledAccountsCount, 3)
        XCTAssertEqual(aggAll.availableAccountsCount, 1)
        XCTAssertEqual(aggAll.average5hRemainingPercent, 40)
        XCTAssertEqual(aggAll.averageWeeklyRemainingPercent, 33)

        let aggGemini = UsageTrackerService.computeAggregateQuota(
            for: [acc1, acc2Disabled, acc3Unknown, acc4Low],
            reserveThresholdPercent: 10,
            modelScope: .geminiOnly,
            referenceDate: now
        )
        XCTAssertEqual(aggGemini.totalEnabledAccountsCount, 3)
        XCTAssertEqual(aggGemini.availableAccountsCount, 1)
        XCTAssertEqual(aggGemini.average5hRemainingPercent, 40)
        XCTAssertEqual(aggGemini.averageWeeklyRemainingPercent, 33)
    }
}
