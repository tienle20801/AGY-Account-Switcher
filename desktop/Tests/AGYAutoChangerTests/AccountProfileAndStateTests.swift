import Foundation
import XCTest
@testable import AGYAutoChanger

final class AccountProfileAndStateTests: TempDirectoryTestCase {

    func testStateInspectorExtractsEmailAndDetectsFingerprintChange() throws {
        let inspector = AGYStateInspectorService()
        let appSupportDir = tempRoot.appendingPathComponent("app_support", isDirectory: true)
        let geminiDir = tempRoot.appendingPathComponent("gemini", isDirectory: true)
        let ideDir = tempRoot.appendingPathComponent("ide", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)

        let pbtxtURL = geminiDir.appendingPathComponent("antigravity_state.pbtxt")
        try "account_info {\n  email: \"dev.team@company.dev\"\n}\n".write(to: pbtxtURL, atomically: true, encoding: .utf8)

        let snap1 = inspector.inspectLiveState(appSupportDir: appSupportDir, geminiDir: geminiDir, ideAppSupportDir: ideDir)
        XCTAssertEqual(snap1.detectedEmail, "dev.team@company.dev")
        XCTAssertEqual(snap1.detectedDisplayName, "dev.team")
        XCTAssertNotNil(snap1.stateFingerprint)
        XCTAssertTrue(snap1.hasSessionFiles)

        try "account_info {\n  email: \"other.acc@company.dev\"\n}\n".write(to: pbtxtURL, atomically: true, encoding: .utf8)
        let snap2 = inspector.inspectLiveState(appSupportDir: appSupportDir, geminiDir: geminiDir, ideAppSupportDir: ideDir)
        XCTAssertEqual(snap2.detectedEmail, "other.acc@company.dev")
        XCTAssertNotEqual(snap1.stateFingerprint, snap2.stateFingerprint)
    }

    func testAccountProfileTierChangeAndInitials() {
        var profile = AccountProfile(email: "work.user@company.dev", displayName: "Work Account", tier: .free)
        XCTAssertEqual(profile.initials, "WA")
        XCTAssertEqual(profile.modelUsages.first(where: { $0.id == "gemini-5h" })?.turnLimit, 30)

        profile.modelUsages[0].turnsUsed = 7
        profile.applyTier(.ultra)

        XCTAssertEqual(profile.tier, .ultra)
        XCTAssertEqual(profile.modelUsages.first(where: { $0.id == "gemini-5h" })?.turnLimit, 450)
        XCTAssertEqual(profile.modelUsages.first(where: { $0.id == "gemini-5h" })?.turnsUsed, 7)
    }

    func testAccountProfileAndSettingsBackwardCompatibleDecoding() throws {
        let profileID = UUID()
        let legacyProfileJSON = """
        {
            "id": "\(profileID.uuidString)",
            "email": "legacy@company.dev",
            "displayName": "Legacy Acc",
            "avatarHex": "#3B82F6",
            "tier": "pro",
            "isActive": true,
            "createdAt": "2026-11-15T10:00:00Z",
            "hasKeychainBackup": true
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedProfile = try decoder.decode(AccountProfile.self, from: legacyProfileJSON)
        XCTAssertEqual(decodedProfile.id, profileID)
        XCTAssertEqual(decodedProfile.remark, "")
        XCTAssertFalse(decodedProfile.isDisabled)
        XCTAssertFalse(decodedProfile.hasDedicatedArgonPool)
        XCTAssertEqual(decodedProfile.modelUsages.count, AppConfig.supportedModels.count)

        let legacySettingsJSON = """
        {
            "agyAppBundlePath": "/Applications/Antigravity.app",
            "autoRelaunchAGY": true
        }
        """.data(using: .utf8)!
        let decodedSettings = try JSONDecoder().decode(SwitcherSettings.self, from: legacySettingsJSON)
        XCTAssertTrue(decodedSettings.showQuickSummaryHeader)
        XCTAssertEqual(decodedSettings.accountDisplayMode, .card)
        XCTAssertEqual(decodedSettings.resetCountdownMode, .onHover)
        XCTAssertEqual(decodedSettings.modelFilterScope, .all)
    }

    func testDedicatedArgonPoolAndUnknownObservationIndicators() {
        var profile = AccountProfile(email: "argon@company.dev", displayName: "Argon User", tier: .pro)
        XCTAssertFalse(profile.hasDedicatedArgonPool)
        XCTAssertTrue(profile.extraDedicatedPoolLabels.isEmpty)
        XCTAssertTrue(profile.modelUsages.allSatisfy(\.isUnknownObservation))

        profile.modelUsages.append(
            ModelUsage(
                id: "carbon-weekly",
                displayName: "Gemini 4 Carbon (Tuần)",
                turnLimit: 300,
                quotaRemainingFraction: 0.75
            )
        )
        if let geminiIdx = profile.modelUsages.firstIndex(where: { $0.id == "gemini-5h" }) {
            profile.modelUsages[geminiIdx].turnsUsed = 1
        }

        XCTAssertTrue(profile.hasDedicatedCarbonPool)
        XCTAssertEqual(profile.extraDedicatedPoolLabels, ["Carbon"])
        XCTAssertFalse(profile.modelUsages.first(where: { $0.id == "carbon-weekly" })?.isUnknownObservation ?? true)
        XCTAssertFalse(profile.modelUsages.first(where: { $0.id == "gemini-5h" })?.isUnknownObservation ?? true)
        XCTAssertTrue(profile.modelUsages.first(where: { $0.id == "3p-5h" })?.isUnknownObservation ?? false)
    }
}
