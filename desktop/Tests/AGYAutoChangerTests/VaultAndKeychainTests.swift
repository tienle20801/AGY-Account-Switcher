import Foundation
import XCTest
@testable import AGYAutoChanger

final class VaultAndKeychainTests: TempDirectoryTestCase {

    func testSnapshotAndRestoreSwapsSessionsAtomicallyWithSecurePermissions() throws {
        let vault = VaultSecurityService()
        let vaultRoot = tempRoot.appendingPathComponent("vault", isDirectory: true)
        let profilesDir = vaultRoot.appendingPathComponent("profiles", isDirectory: true)
        let appSupportDir = tempRoot.appendingPathComponent("app_support", isDirectory: true)
        let geminiDir = tempRoot.appendingPathComponent("gemini", isDirectory: true)

        try vault.ensureVaultDirectories(vaultRoot: vaultRoot, profilesDir: profilesDir)
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)

        // Seed Account A live session
        let cookiesURL = appSupportDir.appendingPathComponent("Cookies")
        let localStorageDir = appSupportDir.appendingPathComponent("Local Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: localStorageDir, withIntermediateDirectories: true)
        try Data("cookie-account-a".utf8).write(to: cookiesURL)
        try Data("leveldb-a".utf8).write(to: localStorageDir.appendingPathComponent("000001.ldb"))
        try Data("user_email: \"acc_a@example.org\"\n".utf8)
            .write(to: geminiDir.appendingPathComponent("antigravity_state.pbtxt"))

        let accountA = UUID()
        let profileDirA = try vault.profileDirectory(for: accountA, profilesRoot: profilesDir)
        let manifestA = try vault.snapshotCurrentSession(
            to: profileDirA,
            appSupportDir: appSupportDir,
            geminiDir: geminiDir
        )
        XCTAssertTrue(manifestA.appSupportItems.contains("Cookies"))
        XCTAssertTrue(manifestA.appSupportItems.contains("Local Storage"))
        XCTAssertTrue(manifestA.geminiItems.contains("antigravity_state.pbtxt"))

        // Verify 0700 directory & 0600 file permissions
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: profileDirA.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let cookieBackupAttrs = try FileManager.default.attributesOfItem(
            atPath: profileDirA.appendingPathComponent("app_support/Cookies").path
        )
        XCTAssertEqual((cookieBackupAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // Seed Account B live session & snapshot
        try Data("cookie-account-b".utf8).write(to: cookiesURL)
        try Data("leveldb-b".utf8).write(to: localStorageDir.appendingPathComponent("000001.ldb"))
        try Data("user_email: \"acc_b@example.org\"\n".utf8)
            .write(to: geminiDir.appendingPathComponent("antigravity_state.pbtxt"))

        let accountB = UUID()
        let profileDirB = try vault.profileDirectory(for: accountB, profilesRoot: profilesDir)
        _ = try vault.snapshotCurrentSession(
            to: profileDirB,
            appSupportDir: appSupportDir,
            geminiDir: geminiDir
        )

        // Create stale lock file to confirm restore removes it
        let staleLock = appSupportDir.appendingPathComponent("SingletonLock")
        try Data("stale".utf8).write(to: staleLock)

        // Restore Account A over Account B
        try vault.restoreSessionSnapshot(
            from: profileDirA,
            accountDisplayName: "Acc A",
            appSupportDir: appSupportDir,
            geminiDir: geminiDir
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleLock.path))
        XCTAssertEqual(try String(contentsOf: cookiesURL), "cookie-account-a")
        XCTAssertEqual(
            try String(contentsOf: localStorageDir.appendingPathComponent("000001.ldb")),
            "leveldb-a"
        )
        XCTAssertTrue(
            try String(contentsOf: geminiDir.appendingPathComponent("antigravity_state.pbtxt"))
                .contains("acc_a@example.org")
        )
    }

    func testRestoreThrowsWhenSnapshotMissingAndRejectsPathTraversal() throws {
        let vault = VaultSecurityService()
        let emptyProfile = tempRoot.appendingPathComponent("empty_profile", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyProfile, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try vault.restoreSessionSnapshot(
                from: emptyProfile,
                accountDisplayName: "Empty",
                appSupportDir: tempRoot,
                geminiDir: tempRoot
            )
        ) { error in
            guard case VaultSecurityError.snapshotMissing = error else {
                XCTFail("Expected snapshotMissing, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(
            try vault.safeChildURL(base: tempRoot, relativePath: "../outside")
        ) { error in
            guard case VaultSecurityError.invalidRelativePath = error else {
                XCTFail("Expected invalidRelativePath, got \(error)")
                return
            }
        }
    }

    func testClearLiveSessionForNewLoginRemovesSessionArtifacts() throws {
        let vault = VaultSecurityService()
        let appSupportDir = tempRoot.appendingPathComponent("app_support", isDirectory: true)
        let geminiDir = tempRoot.appendingPathComponent("gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)

        let cookies = appSupportDir.appendingPathComponent("Cookies")
        let pbtxt = geminiDir.appendingPathComponent("antigravity_state.pbtxt")
        try Data("abc".utf8).write(to: cookies)
        try Data("def".utf8).write(to: pbtxt)

        try vault.clearLiveSessionForNewLogin(appSupportDir: appSupportDir, geminiDir: geminiDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cookies.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pbtxt.path))
    }

    func testCleanLoginStripsOnboardingUsernameButPreservesWorkspaceLayout() throws {
        let vault = VaultSecurityService()
        let appSupportDir = tempRoot.appendingPathComponent("app_support", isDirectory: true)
        let geminiDir = tempRoot.appendingPathComponent("gemini", isDirectory: true)
        let geminiRoot = tempRoot.appendingPathComponent("gemini_root", isDirectory: true)
        let jetskiToken = geminiRoot.appendingPathComponent(AppConfig.jetskiOAuthTokenFileName, isDirectory: false)
        let marker = geminiDir.appendingPathComponent("keyring-marker-gemini", isDirectory: false)

        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiRoot, withIntermediateDirectories: true)

        let appStorageURL = appSupportDir.appendingPathComponent("app_storage.json")
        let appStoragePayload: [String: Any] = [
            "agy.onboarding.lastLoginUsername": "old-user@example.com",
            "agy.onboarding.lastLoginIsGcpTos": "false",
            "projectsOrder": ["proj-1", "proj-2"]
        ]
        let storageData = try JSONSerialization.data(withJSONObject: appStoragePayload)
        try storageData.write(to: appStorageURL)

        let credScope = appSupportDir.appendingPathComponent("credential-user-scope")
        try Data("scope-bytes".utf8).write(to: credScope)
        try Data("{\"userTier\":\"free-tier\"}".utf8).write(to: jetskiToken)
        try Data("marker".utf8).write(to: marker)

        try vault.clearLiveSessionForNewLogin(
            appSupportDir: appSupportDir,
            geminiDir: geminiDir,
            jetskiTokenURL: jetskiToken
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: credScope.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jetskiToken.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let cleanedData = try Data(contentsOf: appStorageURL)
        let cleanedObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: cleanedData) as? [String: Any])
        XCTAssertNil(cleanedObject["agy.onboarding.lastLoginUsername"])
        XCTAssertNil(cleanedObject["agy.onboarding.lastLoginIsGcpTos"])
        XCTAssertEqual(cleanedObject["projectsOrder"] as? [String], ["proj-1", "proj-2"])
    }

    func testSnapshotAndRestoreIncludesAppStorageAndJetskiOAuthToken() throws {
        let vault = VaultSecurityService()
        let appSupportDir = tempRoot.appendingPathComponent("app_support", isDirectory: true)
        let geminiDir = tempRoot.appendingPathComponent("gemini", isDirectory: true)
        let jetskiToken = tempRoot.appendingPathComponent("jetski-standalone-oauth-token", isDirectory: false)
        let profileDir = tempRoot.appendingPathComponent("profile_a", isDirectory: true)

        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)

        try Data("{\"agy.onboarding.lastLoginUsername\":\"userA@example.com\"}".utf8)
            .write(to: appSupportDir.appendingPathComponent("app_storage.json"))
        try Data("scope-A".utf8).write(to: appSupportDir.appendingPathComponent("credential-user-scope"))
        try Data("token-A".utf8).write(to: jetskiToken)

        let manifest = try vault.snapshotCurrentSession(
            to: profileDir,
            appSupportDir: appSupportDir,
            geminiDir: geminiDir,
            jetskiTokenURL: jetskiToken
        )
        XCTAssertEqual(manifest.hasJetskiOAuthToken, true)
        XCTAssertTrue(manifest.appSupportItems.contains("app_storage.json"))
        XCTAssertTrue(manifest.appSupportItems.contains("credential-user-scope"))

        try Data("{\"agy.onboarding.lastLoginUsername\":\"userB@example.com\"}".utf8)
            .write(to: appSupportDir.appendingPathComponent("app_storage.json"))
        try Data("token-B".utf8).write(to: jetskiToken)

        try vault.restoreSessionSnapshot(
            from: profileDir,
            accountDisplayName: "User A",
            appSupportDir: appSupportDir,
            geminiDir: geminiDir,
            jetskiTokenURL: jetskiToken
        )

        let restoredStorage = try String(contentsOf: appSupportDir.appendingPathComponent("app_storage.json"), encoding: .utf8)
        XCTAssertTrue(restoredStorage.contains("userA@example.com"))
        XCTAssertEqual(try String(contentsOf: jetskiToken, encoding: .utf8), "token-A")
    }

    func testKeyringMetadataParserAndAppStorageInspectorDetectEmailAndTier() throws {
        let keychainService = KeychainFallbackService()
        let innerJSON = "{\"userTier\":\"gcp-ge-ultra-tier\",\"email\":\"ultra@company.dev\"}"
        let encodedPayload = "go-keyring-encoded:" + Data(innerJSON.utf8).base64EncodedString()
        let meta = keychainService.parseMetadata(from: Data(encodedPayload.utf8))

        XCTAssertEqual(meta.detectedTier, .ultra)
        XCTAssertEqual(meta.detectedEmail, "ultra@company.dev")
        XCTAssertTrue(meta.hasCredential)
        XCTAssertNotNil(meta.fingerprint)

        XCTAssertEqual(AccountTier.from(serverTier: "free-tier"), .free)
        XCTAssertEqual(AccountTier.from(serverTier: "standard-tier"), .pro)
        XCTAssertEqual(AccountTier.from(serverTier: "gcp-ge-ultra-tier"), .ultra)

        let appSupportDir = tempRoot.appendingPathComponent("inspect_support", isDirectory: true)
        let geminiDir = tempRoot.appendingPathComponent("inspect_gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        try Data("{\"agy.onboarding.lastLoginUsername\":\"active@example.com\"}".utf8)
            .write(to: appSupportDir.appendingPathComponent("app_storage.json"))

        let live = AGYStateInspectorService().inspectLiveState(
            appSupportDir: appSupportDir,
            geminiDir: geminiDir,
            jetskiTokenURL: tempRoot.appendingPathComponent("missing-jetski"),
            keychainAuthMetadata: meta
        )
        XCTAssertEqual(live.detectedEmail, "active@example.com")
        XCTAssertEqual(live.detectedTier, .ultra)
        XCTAssertTrue(live.hasSessionFiles)
        XCTAssertTrue(live.hasAuthCredential)
    }
}
