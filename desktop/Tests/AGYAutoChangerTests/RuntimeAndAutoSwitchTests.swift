import Foundation
import XCTest
@testable import AGYAutoChanger

final class RuntimeAndAutoSwitchTests: TempDirectoryTestCase {

    // MARK: - CLI Token Sync (`~/.gemini/antigravity-cli/antigravity-oauth-token`)

    func testCLITokenSyncOnlyWritesWhenCLIDirAlreadyExistsAndApplies0600() throws {
        let vault = VaultSecurityService()
        let profileDir = tempRoot.appendingPathComponent("profile_cli", isDirectory: true)
        let uninitializedCLIDir = tempRoot.appendingPathComponent("missing-antigravity-cli", isDirectory: true)
        let uninitializedCLIToken = uninitializedCLIDir.appendingPathComponent("antigravity-oauth-token", isDirectory: false)

        try vault.createSecureDirectoryIfNeeded(at: profileDir)
        let jetskiBackup = profileDir.appendingPathComponent("jetski_oauth_token", isDirectory: false)
        try vault.writeProtectedData(Data(#"{"token":{"refresh_token":"1//cli-rt"}}"#.utf8), to: jetskiBackup)

        // Must NOT create ~/.gemini/antigravity-cli if it does not exist yet
        let wroteUninitialized = try vault.restoreCLITokenOnly(from: profileDir, cliTokenURL: uninitializedCLIToken)
        XCTAssertFalse(wroteUninitialized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: uninitializedCLIDir.path))

        // Once ~/.gemini/antigravity-cli exists, it mirrors token with 0600 permissions
        let cliDir = tempRoot.appendingPathComponent("antigravity-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: cliDir, withIntermediateDirectories: true)
        let cliTokenURL = cliDir.appendingPathComponent("antigravity-oauth-token", isDirectory: false)

        let wroteInitialized = try vault.restoreCLITokenOnly(from: profileDir, cliTokenURL: cliTokenURL)
        XCTAssertTrue(wroteInitialized)
        XCTAssertEqual(try String(contentsOf: cliTokenURL, encoding: .utf8), #"{"token":{"refresh_token":"1//cli-rt"}}"#)

        let attrs = try FileManager.default.attributesOfItem(atPath: cliTokenURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - IDE 2.6+ Version Detection

    func testIDEVersionDetectionIdentifies26PlusSharedCredentials() throws {
        let coordinator = AGYRuntimeCoordinator()

        func makeFakeIDE(name: String, ideVersion: String?) throws -> String {
            let bundleURL = tempRoot.appendingPathComponent(name, isDirectory: true)
            let appDir = bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("app", isDirectory: true)
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            if let ideVersion {
                let json = #"{"ideVersion":"\#(ideVersion)","version":"1.107.0"}"#
                try json.write(to: appDir.appendingPathComponent("product.json"), atomically: true, encoding: .utf8)
            }
            return bundleURL.path
        }

        let ide27Path = try makeFakeIDE(name: "Antigravity IDE 27.app", ideVersion: "2.7.0")
        let info27 = try XCTUnwrap(coordinator.detectIDEInstallation(bundlePath: ide27Path))
        XCTAssertEqual(info27.ideVersion, "2.7.0")
        XCTAssertTrue(info27.usesSharedAppCredentials)

        let ide25Path = try makeFakeIDE(name: "Antigravity IDE 25.app", ideVersion: "2.5.4")
        let info25 = try XCTUnwrap(coordinator.detectIDEInstallation(bundlePath: ide25Path))
        XCTAssertEqual(info25.ideVersion, "2.5.4")
        XCTAssertFalse(info25.usesSharedAppCredentials)

        let ideNoManifest = try makeFakeIDE(name: "Antigravity IDE Unknown.app", ideVersion: nil)
        let infoUnknown = try XCTUnwrap(coordinator.detectIDEInstallation(bundlePath: ideNoManifest))
        XCTAssertFalse(infoUnknown.usesSharedAppCredentials)
    }

    // MARK: - Standalone `agy --hub` Process Discovery

    func testStandaloneHubParserDetectsAgyHubAndExcludesBundledLanguageServer() {
        let coordinator = AGYRuntimeCoordinator()
        let fakePS = """
        72013 /Applications/Antigravity.app/Contents/MacOS/Antigravity
        72351 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --subclient_type hub --app_data_dir antigravity
        81001 /Users/tester/.local/bin/agy --hub --app_data_dir antigravity --port 9999
        81002 /Users/tester/.local/bin/agy --hub --app_data_dir custom-other
        81003 /Users/tester/.local/bin/agy -p /usage --output-format stream-json
        """

        let hubs = coordinator.parseStandaloneHubProcesses(from: fakePS)
        XCTAssertEqual(hubs.count, 1)
        XCTAssertEqual(hubs.first?.pid, 81001)
        XCTAssertEqual(hubs.first?.executablePath, "/Users/tester/.local/bin/agy")
        XCTAssertEqual(hubs.first?.arguments, ["--hub", "--app_data_dir", "antigravity", "--port", "9999"])
    }

    // MARK: - Live Activity / Idle Detection

    func testActivityDetectorRecognizesBusyCLIWalAndInFlightTranscript() throws {
        let coordinator = AGYRuntimeCoordinator()
        let convDir = tempRoot.appendingPathComponent("conversations", isDirectory: true)
        let brainDir = tempRoot.appendingPathComponent("brain", isDirectory: true)
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brainDir, withIntermediateDirectories: true)

        let now = Date()

        // 1. Clean idle state (only hub + /usage in process table)
        let idlePS = """
        81001 /Users/tester/.local/bin/agy --hub --app_data_dir antigravity
        81003 /Users/tester/.local/bin/agy -p /usage --output-format stream-json
        """
        let idleState = coordinator.inspectActivityState(
            conversationsDir: convDir,
            brainDir: brainDir,
            psOutput: idlePS,
            idleQuietWindowSeconds: 25,
            referenceDate: now
        )
        XCTAssertEqual(idleState, .idle)

        // 2. Active CLI prompt -> busy
        let busyPS = "82000 /Users/tester/.local/bin/agy -p \"implement feature\"\n"
        let busyCLI = coordinator.inspectActivityState(
            conversationsDir: convDir,
            brainDir: brainDir,
            psOutput: busyPS,
            idleQuietWindowSeconds: 25,
            referenceDate: now
        )
        XCTAssertFalse(busyCLI.isIdle)

        // 3. Fresh WAL file write -> busy
        let walFile = convDir.appendingPathComponent("conv-live.db-wal")
        try Data("wal-bytes".utf8).write(to: walFile)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)], ofItemAtPath: walFile.path)
        let busyWAL = coordinator.inspectActivityState(
            conversationsDir: convDir,
            brainDir: brainDir,
            psOutput: idlePS,
            idleQuietWindowSeconds: 25,
            referenceDate: now
        )
        XCTAssertFalse(busyWAL.isIdle)

        // Age WAL past quiet window -> idle again
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: walFile.path)

        // 4. Transcript tail with in-flight USER_INPUT -> busy; DONE PLANNER_RESPONSE -> idle
        let logDir = brainDir
            .appendingPathComponent("conv-1", isDirectory: true)
            .appendingPathComponent(".system_generated", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let transcriptURL = logDir.appendingPathComponent("transcript.jsonl")

        try #"{"type":"USER_INPUT","status":"DONE"}"#.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40)], ofItemAtPath: transcriptURL.path)
        let busyTail = coordinator.inspectActivityState(
            conversationsDir: convDir,
            brainDir: brainDir,
            psOutput: idlePS,
            idleQuietWindowSeconds: 25,
            referenceDate: now
        )
        XCTAssertFalse(busyTail.isIdle)

        try #"{"type":"PLANNER_RESPONSE","status":"DONE"}"#.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40)], ofItemAtPath: transcriptURL.path)
        let doneTail = coordinator.inspectActivityState(
            conversationsDir: convDir,
            brainDir: brainDir,
            psOutput: idlePS,
            idleQuietWindowSeconds: 25,
            referenceDate: now
        )
        XCTAssertEqual(doneTail, .idle)
    }

    // MARK: - Smart Auto-Switch Decision Engine

    func testSmartAutoSwitchWaitForIdlePriorityRoundRobinCancellationAndFreshness() {
        let engine = SmartAutoSwitchService()
        let now = Date()
        let freshSync = now.addingTimeInterval(-30)
        let staleSync = now.addingTimeInterval(-300) // > 180s stale
        let futureReset = now.addingTimeInterval(3600 * 4)

        func makeAccount(
            email: String,
            name: String,
            isActive: Bool = false,
            isDisabled: Bool = false,
            gemini5h: Double,
            geminiWeekly: Double,
            syncedAt: Date = freshSync
        ) -> AccountProfile {
            var usages = ModelUsage.defaultSet(for: .pro)
            usages[0].quotaRemainingFraction = gemini5h
            usages[0].quotaResetAt = futureReset
            usages[0].quotaSyncedAt = syncedAt
            usages[1].quotaRemainingFraction = geminiWeekly
            usages[1].quotaResetAt = futureReset
            usages[1].quotaSyncedAt = syncedAt
            return AccountProfile(
                email: email,
                displayName: name,
                tier: .pro,
                isActive: isActive,
                isDisabled: isDisabled,
                lastDashboardSyncAt: syncedAt,
                modelUsages: usages
            )
        }

        let accA = makeAccount(email: "a@dev.com", name: "Acc A", gemini5h: 0.85, geminiWeekly: 0.70)
        let accBActive = makeAccount(email: "b@dev.com", name: "Acc B", isActive: true, gemini5h: 0.08, geminiWeekly: 0.40)
        let accCDisabled = makeAccount(email: "c@dev.com", name: "Acc C", isDisabled: true, gemini5h: 0.95, geminiWeekly: 0.95)
        let accDStale = makeAccount(email: "d@dev.com", name: "Acc D", gemini5h: 0.95, geminiWeekly: 0.95, syncedAt: staleSync)
        let accEWeeklyDepleted = makeAccount(email: "e@dev.com", name: "Acc E", gemini5h: 0.95, geminiWeekly: 0.12)
        let accFHealthy = makeAccount(email: "f@dev.com", name: "Acc F", gemini5h: 0.65, geminiWeekly: 0.55)

        let accounts = [accA, accBActive, accCDisabled, accDStale, accEWeeklyDepleted, accFHealthy]

        // 1. Wait-for-idle with busy activity -> .waitingForIdle choosing Acc A in priorityOrder
        let priorityPolicy = AutoSwitchPolicy(
            isEnabled: true,
            timingMode: .waitForIdle,
            selectionStrategy: .priorityOrder,
            modelScope: .geminiOnly,
            triggerThresholdPercent: 10,
            minBackupQuotaPercent: 30
        )
        let busyRes = engine.evaluate(
            accounts: accounts,
            policy: priorityPolicy,
            state: AutoSwitchRuntimeState(),
            activityState: .busy(reason: "Streaming reply"),
            hasSnapshot: { _ in true },
            referenceDate: now
        )
        if case .waitingForIdle(let source, let target, _, let pct, _) = busyRes.decision {
            XCTAssertEqual(source.id, accBActive.id)
            XCTAssertEqual(target.id, accA.id)
            XCTAssertEqual(pct, 8)
        } else {
            XCTFail("Expected waitingForIdle, got \(busyRes.decision)")
        }

        // 2. Round-robin starting after Acc B skips C (disabled), D (stale), E (weekly 12% < 30%) -> picks Acc F!
        var rrPolicy = priorityPolicy
        rrPolicy.selectionStrategy = .roundRobin
        let rrRes = engine.evaluate(
            accounts: accounts,
            policy: rrPolicy,
            state: AutoSwitchRuntimeState(),
            activityState: .idle,
            hasSnapshot: { _ in true },
            referenceDate: now
        )
        if case .readyToSwitch(_, let target, _, _) = rrRes.decision {
            XCTAssertEqual(target.id, accFHealthy.id)
        } else {
            XCTFail("Expected readyToSwitch to Acc F, got \(rrRes.decision)")
        }

        // 3. Cancellation suppresses switching while low, then auto-clears once source recovers >= minBackupQuotaPercent
        let cancelledState = AutoSwitchRuntimeState(cancelledSourceAccountIDs: [accBActive.id])
        let suppressedRes = engine.evaluate(
            accounts: accounts,
            policy: priorityPolicy,
            state: cancelledState,
            activityState: .idle,
            hasSnapshot: { _ in true },
            referenceDate: now
        )
        XCTAssertEqual(suppressedRes.decision, .suppressedByCancellation(sourceID: accBActive.id))

        var recoveredAccB = accBActive
        recoveredAccB.modelUsages[0].quotaRemainingFraction = 0.45
        recoveredAccB.modelUsages[1].quotaRemainingFraction = 0.40
        let recoveredRes = engine.evaluate(
            accounts: [accA, recoveredAccB],
            policy: priorityPolicy,
            state: cancelledState,
            activityState: .idle,
            hasSnapshot: { _ in true },
            referenceDate: now
        )
        XCTAssertEqual(recoveredRes.decision, .none)
        XCTAssertFalse(recoveredRes.updatedState.cancelledSourceAccountIDs.contains(accBActive.id))

        // 4. Failure pause blocks automatic switches
        let failedState = AutoSwitchRuntimeState(pausedDueToFailure: true, lastFailureReason: "Snapshot missing")
        let pausedRes = engine.evaluate(
            accounts: accounts,
            policy: priorityPolicy,
            state: failedState,
            activityState: .idle,
            hasSnapshot: { _ in true },
            referenceDate: now
        )
        XCTAssertEqual(pausedRes.decision, .pausedByFailure("Snapshot missing"))
    }

    func testSmartAutoSwitchPerBucketSelectionAndAllSelectedMatchMode() throws {
        let engine = SmartAutoSwitchService()
        let now = Date()
        let freshSync = now.addingTimeInterval(-30)
        let futureReset = now.addingTimeInterval(3600 * 4)

        func makeAccount(
            name: String,
            isActive: Bool = false,
            g5: Double,
            gw: Double,
            c5: Double,
            cw: Double,
            argonWeekly: Double? = nil
        ) -> AccountProfile {
            var usages = ModelUsage.defaultSet(for: .pro)
            for idx in usages.indices {
                usages[idx].quotaResetAt = futureReset
                usages[idx].quotaSyncedAt = freshSync
                switch usages[idx].id {
                case "gemini-5h": usages[idx].quotaRemainingFraction = g5
                case "gemini-weekly": usages[idx].quotaRemainingFraction = gw
                case "3p-5h": usages[idx].quotaRemainingFraction = c5
                case "3p-weekly": usages[idx].quotaRemainingFraction = cw
                default: break
                }
            }
            if let argonWeekly {
                usages.append(
                    ModelUsage(
                        id: "argon-weekly",
                        displayName: "Gemini 4 Argon (Tuần)",
                        turnLimit: 200,
                        quotaRemainingFraction: argonWeekly,
                        quotaResetAt: futureReset,
                        quotaSyncedAt: freshSync
                    )
                )
            }
            return AccountProfile(
                email: "\(name.lowercased())@dev.com",
                displayName: name,
                tier: .pro,
                isActive: isActive,
                lastDashboardSyncAt: freshSync,
                modelUsages: usages
            )
        }

        // 1. Reproduces user scenario: active `tienngocle` has argon=6% & claude-weekly=8%, while gemini5h=86% & geminiWeekly=95%.
        // Selecting ONLY ["gemini-5h", "gemini-weekly"] must NOT switch!
        let activeAcc = makeAccount(name: "Active", isActive: true, g5: 0.86, gw: 0.95, c5: 1.0, cw: 0.08, argonWeekly: 0.06)
        let backupWeeklyDead = makeAccount(name: "WeeklyDead", g5: 0.90, gw: 0.0, c5: 0.90, cw: 0.90)
        let backupHealthy = makeAccount(name: "Healthy", g5: 0.80, gw: 0.70, c5: 0.80, cw: 0.70)

        let geminiOnlyBucketsPolicy = AutoSwitchPolicy(
            isEnabled: true,
            timingMode: .immediateAtThreshold,
            selectionStrategy: .priorityOrder,
            modelScope: .geminiOnly,
            monitoredBucketIDs: ["gemini-5h", "gemini-weekly"],
            triggerMatchMode: .anySelected,
            triggerThresholdPercent: 10,
            minBackupQuotaPercent: 30
        )
        let noSwitchResult = engine.evaluate(
            accounts: [activeAcc, backupHealthy],
            policy: geminiOnlyBucketsPolicy,
            state: AutoSwitchRuntimeState(),
            activityState: .idle,
            hasSnapshot: { _ in true },
            referenceDate: now
        )
        XCTAssertEqual(noSwitchResult.decision, .none)

        // 2. Monitoring ONLY ["gemini-5h"] triggers when gemini-5h <= 10%, and safety guard still skips backup whose gemini-weekly == 0%
        var lowG5Active = activeAcc
        lowG5Active.modelUsages[0].quotaRemainingFraction = 0.05
        var g5OnlyPolicy = geminiOnlyBucketsPolicy
        g5OnlyPolicy.monitoredBucketIDs = ["gemini-5h"]

        let g5SwitchRes = engine.evaluate(
            accounts: [lowG5Active, backupWeeklyDead, backupHealthy],
            policy: g5OnlyPolicy,
            state: AutoSwitchRuntimeState(),
            activityState: .idle,
            hasSnapshot: { _ in true },
            referenceDate: now
        )
        if case .readyToSwitch(_, let target, _, _) = g5SwitchRes.decision {
            XCTAssertEqual(target.id, backupHealthy.id)
        } else {
            XCTFail("Expected switch to backupHealthy skipping weekly-dead backup, got \(g5SwitchRes.decision)")
        }

        // 3. `.allSelected` with ["gemini-5h", "3p-5h"]: does NOT switch if only gemini-5h <= 10% (3p-5h is 80%)
        let partialAllAcc = makeAccount(name: "Partial", isActive: true, g5: 0.05, gw: 0.90, c5: 0.80, cw: 0.90)
        let allSelectedPolicy = AutoSwitchPolicy(
            isEnabled: true,
            timingMode: .immediateAtThreshold,
            selectionStrategy: .priorityOrder,
            modelScope: .all,
            monitoredBucketIDs: ["gemini-5h", "3p-5h"],
            triggerMatchMode: .allSelected,
            triggerThresholdPercent: 10,
            minBackupQuotaPercent: 30
        )
        let partialAllRes = engine.evaluate(
            accounts: [partialAllAcc, backupHealthy],
            policy: allSelectedPolicy,
            state: AutoSwitchRuntimeState(),
            activityState: .idle,
            hasSnapshot: { _ in true },
            referenceDate: now
        )
        XCTAssertEqual(partialAllRes.decision, .none)

        // When BOTH monitored buckets drop <= 10%, `.allSelected` triggers switch!
        let bothLowAcc = makeAccount(name: "BothLow", isActive: true, g5: 0.05, gw: 0.90, c5: 0.09, cw: 0.90)
        let bothLowRes = engine.evaluate(
            accounts: [bothLowAcc, backupHealthy],
            policy: allSelectedPolicy,
            state: AutoSwitchRuntimeState(),
            activityState: .idle,
            hasSnapshot: { _ in true },
            referenceDate: now
        )
        if case .readyToSwitch(_, let target, _, _) = bothLowRes.decision {
            XCTAssertEqual(target.id, backupHealthy.id)
        } else {
            XCTFail("Expected readyToSwitch under .allSelected when both buckets are low, got \(bothLowRes.decision)")
        }

        // 4. Legacy AutoSwitchPolicy without `monitoredBucketIDs` migrates automatically from `modelScope`
        let legacyJSON = """
        {
          "isEnabled": true,
          "timingMode": "immediateAtThreshold",
          "selectionStrategy": "priorityOrder",
          "modelScope": "geminiOnly",
          "triggerThresholdPercent": 15,
          "minBackupQuotaPercent": 35
        }
        """
        let decodedLegacy = try JSONDecoder().decode(AutoSwitchPolicy.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decodedLegacy.monitoredBucketIDs, ["gemini-5h", "gemini-weekly"])
        XCTAssertEqual(decodedLegacy.triggerMatchMode, .anySelected)
    }
}
