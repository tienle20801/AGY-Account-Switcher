import CryptoKit
import Foundation
import SQLite3

// MARK: - Live State Inspection Result

/// Non-sensitive summary extracted from local Antigravity configuration/state files.
public struct AGYLiveStateSnapshot: Sendable, Equatable {
    public let detectedEmail: String?
    public let detectedDisplayName: String?
    public let detectedTier: AccountTier?
    public let stateFingerprint: String?
    public let authFingerprint: String?
    public let hasSessionFiles: Bool
    public let hasAuthCredential: Bool

    public init(
        detectedEmail: String? = nil,
        detectedDisplayName: String? = nil,
        detectedTier: AccountTier? = nil,
        stateFingerprint: String? = nil,
        authFingerprint: String? = nil,
        hasSessionFiles: Bool = false,
        hasAuthCredential: Bool = false
    ) {
        self.detectedEmail = detectedEmail
        self.detectedDisplayName = detectedDisplayName
        self.detectedTier = detectedTier
        self.stateFingerprint = stateFingerprint
        self.authFingerprint = authFingerprint
        self.hasSessionFiles = hasSessionFiles
        self.hasAuthCredential = hasAuthCredential
    }
}

// MARK: - State Inspector Service

/// Inspects Antigravity state files (`app_storage.json`, `antigravity_state.pbtxt`, `Preferences`, optional IDE `state.vscdb`)
/// and non-secret token metadata (`userTier`) without logging sensitive credentials.
public final class AGYStateInspectorService: Sendable {

    private static let emailPattern = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"

    public init() {}

    public func inspectLiveState(
        appSupportDir: URL = AppConfig.agyAppSupportDir,
        geminiDir: URL = AppConfig.agyGeminiDir,
        ideAppSupportDir: URL = AppConfig.agyIDEAppSupportDir,
        jetskiTokenURL: URL = AppConfig.jetskiOAuthTokenURL,
        keychainAuthMetadata: KeychainAuthMetadata? = nil
    ) -> AGYLiveStateSnapshot {
        let pbtxtURL = geminiDir.appendingPathComponent("antigravity_state.pbtxt", isDirectory: false)
        let appStorageURL = appSupportDir.appendingPathComponent("app_storage.json", isDirectory: false)
        let credentialScopeURL = appSupportDir.appendingPathComponent("credential-user-scope", isDirectory: false)
        let cookiesURL = appSupportDir.appendingPathComponent("Cookies", isDirectory: false)
        let localStorageURL = appSupportDir.appendingPathComponent("Local Storage", isDirectory: true)

        let fm = FileManager.default
        let onboardingEmail = extractLastLoginUsername(fromAppStorageAt: appStorageURL)
        let hasCredential = (keychainAuthMetadata?.hasCredential ?? false)
            || fm.fileExists(atPath: jetskiTokenURL.path)
            || (onboardingEmail != nil)
        let hasSession = fm.fileExists(atPath: pbtxtURL.path)
            || fm.fileExists(atPath: cookiesURL.path)
            || fm.fileExists(atPath: localStorageURL.path)
            || fm.fileExists(atPath: credentialScopeURL.path)
            || hasCredential

        let fingerprintParts = [
            computeFileFingerprint(at: pbtxtURL),
            computeFileFingerprint(at: credentialScopeURL),
            onboardingEmail,
            keychainAuthMetadata?.fingerprint
        ].compactMap { $0 }
        let fingerprint = fingerprintParts.isEmpty ? nil : fingerprintParts.joined(separator: "|")

        var email = onboardingEmail ?? keychainAuthMetadata?.detectedEmail
        if email == nil {
            email = extractEmailFromTextFile(at: pbtxtURL)
        }
        if email == nil {
            email = extractEmailFromTextFile(at: appSupportDir.appendingPathComponent("Preferences", isDirectory: false))
        }
        if email == nil {
            email = extractEmailFromTextFile(at: appSupportDir.appendingPathComponent("Local State", isDirectory: false))
        }
        if email == nil {
            let ideStateDB = ideAppSupportDir
                .appendingPathComponent("User", isDirectory: true)
                .appendingPathComponent("globalStorage", isDirectory: true)
                .appendingPathComponent("state.vscdb", isDirectory: false)
            email = extractEmailFromIDEStateDB(at: ideStateDB)
        }

        let displayName = email.flatMap { address in
            address.split(separator: "@").first.map(String.init)
        }

        return AGYLiveStateSnapshot(
            detectedEmail: email,
            detectedDisplayName: displayName,
            detectedTier: keychainAuthMetadata?.detectedTier,
            stateFingerprint: fingerprint,
            authFingerprint: keychainAuthMetadata?.fingerprint,
            hasSessionFiles: hasSession,
            hasAuthCredential: hasCredential
        )
    }

    public func extractLastLoginUsername(fromAppStorageAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["agy.onboarding.lastLoginUsername"] as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Computes a short SHA-256 fingerprint for change detection without exposing file contents.
    public func computeFileFingerprint(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func extractEmailFromTextFile(at url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return firstEmailMatch(in: content)
    }

    public func extractEmailFromIDEStateDB(at dbURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return nil
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT value FROM ItemTable
        WHERE lower(key) LIKE '%auth%'
           OR lower(key) LIKE '%account%'
           OR lower(key) LIKE '%user%'
           OR lower(key) LIKE '%antigravity%'
        LIMIT 25;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                let value = String(cString: cString)
                if let match = firstEmailMatch(in: value) {
                    return match
                }
            }
        }
        return nil
    }

    public func firstEmailMatch(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: Self.emailPattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        for match in matches {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let candidate = String(text[swiftRange])
            // Filter out internal placeholder/example addresses
            let lower = candidate.lowercased()
            if lower.hasSuffix(".local") || lower.hasSuffix("example.com") {
                continue
            }
            return candidate
        }
        return nil
    }
}
