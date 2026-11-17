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
}
