import CryptoKit
import Foundation
import Security

// MARK: - Keychain Fallback Payload

private struct KeychainItemRecord: Codable, Sendable {
    let service: String
    let account: String
    let secretBase64: String
}

private struct StoredTokenMetadataPayload: Decodable {
    struct OAuthTokenPart: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expiry: String?
    }

    let userTier: String?
    let user_tier: String?
    let tierDisplayName: String?
    let email: String?
    let token: OAuthTokenPart?

    var resolvedTierString: String? {
        userTier ?? user_tier ?? tierDisplayName
    }
}

public struct KeychainAuthMetadata: Sendable, Equatable {
    public let detectedTier: AccountTier?
    public let detectedEmail: String?
    public let fingerprint: String?
    public let hasCredential: Bool

    public init(
        detectedTier: AccountTier? = nil,
        detectedEmail: String? = nil,
        fingerprint: String? = nil,
        hasCredential: Bool = false
    ) {
        self.detectedTier = detectedTier
        self.detectedEmail = detectedEmail
        self.fingerprint = fingerprint
        self.hasCredential = hasCredential
    }
}

// MARK: - Keychain Fallback Service (Priority 2)

/// Scoped native Keychain snapshot/restore helper using `SecItemCopyMatching`.
/// Manages Antigravity 2.0's `gemini` / `antigravity` OAuth credential item and optional secondary entries.
public final class KeychainFallbackService: Sendable {

    private let vaultSecurity: VaultSecurityService

    public init(vaultSecurity: VaultSecurityService = VaultSecurityService()) {
        self.vaultSecurity = vaultSecurity
    }

    /// Captures Antigravity's primary `gemini`/`antigravity` Keychain item (and optional secondary services)
    /// into `keychain_fallback.json` via `SecItemCopyMatching`. Returns `true` if any item was captured.
    @discardableResult
    public func snapshotScopedKeychain(
        to profileDir: URL,
        includeSecondaryServices: Bool = true
    ) throws -> Bool {
        var captured: [KeychainItemRecord] = []

        for target in AppConfig.keychainScopedTargets {
            let isPrimary = (target == AppConfig.primaryAuthKeychainTarget)
            if !isPrimary && !includeSecondaryServices {
                continue
            }
            if let record = querySingleGenericPassword(service: target.service, account: target.account) {
                captured.append(record)
            }
        }

        let targetURL = profileDir.appendingPathComponent("keychain_fallback.json", isDirectory: false)
        guard !captured.isEmpty else {
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try? FileManager.default.removeItem(at: targetURL)
            }
            return false
        }
        try vaultSecurity.writeJSON(captured, to: targetURL)
        return true
    }

    /// Restores scoped Keychain entries previously saved in `keychain_fallback.json`.
    /// Clears stale primary `gemini`/`antigravity` credential first when `clearPrimaryIfMissing` is true.
    public func restoreScopedKeychain(
        from profileDir: URL,
        includeSecondaryServices: Bool = true,
        clearPrimaryIfMissing: Bool = true
    ) throws {
        let sourceURL = profileDir.appendingPathComponent("keychain_fallback.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            if clearPrimaryIfMissing {
                clearPrimaryAuthKeychain()
            }
            return
        }

        let records = try vaultSecurity.readJSON([KeychainItemRecord].self, from: sourceURL)
        let hasPrimaryInBackup = records.contains {
            $0.service == AppConfig.primaryAuthKeychainTarget.service
                && ($0.account == AppConfig.primaryAuthKeychainTarget.account)
        }
        if clearPrimaryIfMissing && !hasPrimaryInBackup {
            clearPrimaryAuthKeychain()
        }

        for record in records {
            let isPrimary = (record.service == AppConfig.primaryAuthKeychainTarget.service)
            guard AppConfig.keychainFallbackServices.contains(record.service),
                  (isPrimary || includeSecondaryServices),
                  let secretData = Data(base64Encoded: record.secretBase64) else {
                continue
            }
            upsertGenericPassword(service: record.service, account: record.account, data: secretData)
        }
    }

    /// Removes Antigravity's primary `gemini`/`antigravity` Keychain item so Antigravity launches logged out.
    public func clearPrimaryAuthKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.primaryAuthKeychainTarget.service,
            kSecAttrAccount as String: AppConfig.primaryAuthKeychainTarget.account ?? "antigravity"
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Checks whether the primary `gemini`/`antigravity` entry exists using attribute-only lookup (never triggers ACL prompt).
    public func hasPrimaryAuthKeychainEntry() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.primaryAuthKeychainTarget.service,
            kSecAttrAccount as String: AppConfig.primaryAuthKeychainTarget.account ?? "antigravity",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Reads non-secret metadata (`userTier`, `email`, short SHA-256 fingerprint) from Keychain if permitted, or from `~/.gemini/jetski-standalone-oauth-token`.
    public func inspectAuthMetadata(
        readKeychainSecret: Bool = false,
        jetskiTokenURL: URL = AppConfig.jetskiOAuthTokenURL
    ) -> KeychainAuthMetadata {
        if let fileData = try? Data(contentsOf: jetskiTokenURL), !fileData.isEmpty {
            return parseMetadata(from: fileData)
        }

        guard readKeychainSecret else {
            return KeychainAuthMetadata(hasCredential: hasPrimaryAuthKeychainEntry())
        }

        if let record = querySingleGenericPassword(
            service: AppConfig.primaryAuthKeychainTarget.service,
            account: AppConfig.primaryAuthKeychainTarget.account
        ), let rawData = Data(base64Encoded: record.secretBase64) {
            return parseMetadata(from: rawData)
        }

        return KeychainAuthMetadata(hasCredential: false)
    }

    /// Extracts non-secret tier/email/fingerprint metadata from `go-keyring-encoded:` / `go-keyring-base64:` / raw JSON token data.
    public func parseMetadata(from rawData: Data) -> KeychainAuthMetadata {
        guard !rawData.isEmpty else {
            return KeychainAuthMetadata(hasCredential: false)
        }

        let fingerprintDigest = SHA256.hash(data: rawData)
        let fingerprint = fingerprintDigest.prefix(8).map { String(format: "%02x", $0) }.joined()

        let jsonData = unwrapGoKeyringPayload(rawData)
        if let jsonData,
           let payload = try? JSONDecoder().decode(StoredTokenMetadataPayload.self, from: jsonData) {
            return KeychainAuthMetadata(
                detectedTier: AccountTier.from(serverTier: payload.resolvedTierString),
                detectedEmail: payload.email,
                fingerprint: fingerprint,
                hasCredential: true
            )
        }

        return KeychainAuthMetadata(
            detectedTier: nil,
            detectedEmail: nil,
            fingerprint: fingerprint,
            hasCredential: true
        )
    }

    /// Reads an unexpired in-memory OAuth access token from an account's snapshot or the live Antigravity session.
    /// Checks file/Vault sources first to avoid triggering macOS Keychain ACL prompts unless `useLiveKeychain` fallback is required.
    /// Never persists or logs the token. Returns `nil` if absent or expired.
    public func extractValidBearerToken(
        fromProfileDir profileDir: URL? = nil,
        useLiveKeychain: Bool = false,
        jetskiTokenURL: URL = AppConfig.jetskiOAuthTokenURL
    ) -> String? {
        var fileCandidates: [Data] = []

        if let profileDir {
            let profileJetski = profileDir.appendingPathComponent("jetski_oauth_token", isDirectory: false)
            if let fileData = try? Data(contentsOf: profileJetski), !fileData.isEmpty {
                fileCandidates.append(fileData)
            }
            let backupFile = profileDir.appendingPathComponent("keychain_fallback.json", isDirectory: false)
            if let records = try? vaultSecurity.readJSON([KeychainItemRecord].self, from: backupFile),
               let primary = records.first(where: {
                   $0.service == AppConfig.primaryAuthKeychainTarget.service
                       && $0.account == AppConfig.primaryAuthKeychainTarget.account
               }),
               let decoded = Data(base64Encoded: primary.secretBase64) {
                fileCandidates.append(decoded)
            }
        }

        if useLiveKeychain,
           let fileData = try? Data(contentsOf: jetskiTokenURL), !fileData.isEmpty {
            fileCandidates.append(fileData)
        }

        let now = Date()
        if let validFileToken = firstUnexpiredAccessToken(in: fileCandidates, at: now) {
            return validFileToken
        }

        if useLiveKeychain,
           let liveRecord = querySingleGenericPassword(
            service: AppConfig.primaryAuthKeychainTarget.service,
            account: AppConfig.primaryAuthKeychainTarget.account
           ),
           let decoded = Data(base64Encoded: liveRecord.secretBase64) {
            return firstUnexpiredAccessToken(in: [decoded], at: now)
        }

        return nil
    }

    /// Returns a valid bearer token from local/Keychain storage, or exchanges a saved `refresh_token`
    /// with Google OAuth2 when the stored `access_token` has expired.
    public func resolveOrRefreshBearerToken(
        fromProfileDir profileDir: URL? = nil,
        useLiveKeychain: Bool = false,
        jetskiTokenURL: URL = AppConfig.jetskiOAuthTokenURL
    ) async -> String? {
        if let valid = extractValidBearerToken(
            fromProfileDir: profileDir,
            useLiveKeychain: useLiveKeychain,
            jetskiTokenURL: jetskiTokenURL
        ) {
            return valid
        }

        let candidates = collectTokenDataCandidates(
            fromProfileDir: profileDir,
            includeLiveJetskiFile: true,
            jetskiTokenURL: jetskiTokenURL
        )
        guard let refreshToken = firstRefreshToken(in: candidates),
              let refreshed = await exchangeRefreshToken(refreshToken) else {
            return nil
        }

        if let profileDir {
            updateStoredAccessToken(
                inProfileDir: profileDir,
                accessToken: refreshed.accessToken,
                expiresIn: refreshed.expiresIn
            )
        }
        return refreshed.accessToken
    }

    private func collectTokenDataCandidates(
        fromProfileDir profileDir: URL?,
        includeLiveJetskiFile: Bool,
        jetskiTokenURL: URL
    ) -> [Data] {
        var fileCandidates: [Data] = []
        if let profileDir {
            let profileJetski = profileDir.appendingPathComponent("jetski_oauth_token", isDirectory: false)
            if let fileData = try? Data(contentsOf: profileJetski), !fileData.isEmpty {
                fileCandidates.append(fileData)
            }
            let backupFile = profileDir.appendingPathComponent("keychain_fallback.json", isDirectory: false)
            if let records = try? vaultSecurity.readJSON([KeychainItemRecord].self, from: backupFile),
               let primary = records.first(where: {
                   $0.service == AppConfig.primaryAuthKeychainTarget.service
                       && $0.account == AppConfig.primaryAuthKeychainTarget.account
               }),
               let decoded = Data(base64Encoded: primary.secretBase64) {
                fileCandidates.append(decoded)
            }
        }
        if includeLiveJetskiFile,
           let fileData = try? Data(contentsOf: jetskiTokenURL), !fileData.isEmpty {
            fileCandidates.append(fileData)
        }
        return fileCandidates
    }

    private func firstRefreshToken(in candidates: [Data]) -> String? {
        for rawData in candidates {
            guard let jsonData = unwrapGoKeyringPayload(rawData),
                  let payload = try? JSONDecoder().decode(StoredTokenMetadataPayload.self, from: jsonData),
                  let rt = payload.token?.refresh_token?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rt.isEmpty else {
                continue
            }
            return rt
        }
        return nil
    }

    private func exchangeRefreshToken(_ refreshToken: String) async -> (accessToken: String, expiresIn: TimeInterval)? {
        guard let url = URL(string: AppConfig.googleOAuthTokenEndpoint),
              let creds = AppConfig.resolveOAuthClientCredentials() else {
            return nil
        }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: creds.clientID),
            URLQueryItem(name: "client_secret", value: creds.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 8.0)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return nil
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3599
        return (accessToken, expiresIn)
    }

    private func updateStoredAccessToken(inProfileDir profileDir: URL, accessToken: String, expiresIn: TimeInterval) {
        let backupFile = profileDir.appendingPathComponent("keychain_fallback.json", isDirectory: false)
        guard var records = try? vaultSecurity.readJSON([KeychainItemRecord].self, from: backupFile),
              let idx = records.firstIndex(where: {
                  $0.service == AppConfig.primaryAuthKeychainTarget.service
                      && $0.account == AppConfig.primaryAuthKeychainTarget.account
              }),
              let rawData = Data(base64Encoded: records[idx].secretBase64),
              let jsonData = unwrapGoKeyringPayload(rawData),
              var obj = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
              var tokenDict = obj["token"] as? [String: Any] else {
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        tokenDict["access_token"] = accessToken
        tokenDict["expiry"] = formatter.string(from: Date().addingTimeInterval(expiresIn))
        obj["token"] = tokenDict

        guard let updatedJSON = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let rawText = String(data: rawData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rewrappedData: Data
        if rawText.hasPrefix("go-keyring-encoded:") {
            rewrappedData = Data(("go-keyring-encoded:" + updatedJSON.base64EncodedString()).utf8)
        } else if rawText.hasPrefix("go-keyring-base64:") {
            rewrappedData = Data(("go-keyring-base64:" + updatedJSON.base64EncodedString()).utf8)
        } else {
            rewrappedData = updatedJSON
        }

        records[idx] = KeychainItemRecord(
            service: records[idx].service,
            account: records[idx].account,
            secretBase64: rewrappedData.base64EncodedString()
        )
        try? vaultSecurity.writeJSON(records, to: backupFile)
    }

    private func firstUnexpiredAccessToken(in candidates: [Data], at now: Date) -> String? {
        for rawData in candidates {
            guard let jsonData = unwrapGoKeyringPayload(rawData),
                  let payload = try? JSONDecoder().decode(StoredTokenMetadataPayload.self, from: jsonData),
                  let token = payload.token?.access_token?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                continue
            }
            if let expiryRaw = payload.token?.expiry,
               let expiryDate = UsageTrackerService.parseISO8601(expiryRaw),
               expiryDate.timeIntervalSinceReferenceDate <= now.timeIntervalSinceReferenceDate + 30 {
                continue
            }
            return token
        }
        return nil
    }

    /// Decodes `zalando/go-keyring` `go-keyring-encoded:` / `go-keyring-base64:` wrappers to underlying JSON bytes.
    public func unwrapGoKeyringPayload(_ rawData: Data) -> Data? {
        guard let rawText = String(data: rawData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        for prefix in ["go-keyring-encoded:", "go-keyring-base64:"] {
            if rawText.hasPrefix(prefix) {
                let encoded = String(rawText.dropFirst(prefix.count))
                if let decoded = Data(base64Encoded: encoded) {
                    return decoded
                }
            }
        }

        if rawText.hasPrefix("{") {
            return Data(rawText.utf8)
        }
        return nil
    }

    // MARK: - Scoped Security Framework Calls

    private func querySingleGenericPassword(service: String, account: String?) -> KeychainItemRecord? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data else {
            return nil
        }

        let resolvedAccount = (item[kSecAttrAccount as String] as? String) ?? account ?? "Antigravity"
        return KeychainItemRecord(
            service: service,
            account: resolvedAccount,
            secretBase64: data.base64EncodedString()
        )
    }

    private func upsertGenericPassword(service: String, account: String, data: Data) {
        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Delete any existing entry first so stale single-app ACLs are cleared.
        SecItemDelete(lookupQuery as CFDictionary)

        // Write via `/usr/bin/security -i` so `/usr/bin/security` (used by Antigravity's go-keyring)
        // and Antigravity.app/language_server are trusted in the ACL with zero macOS password prompts.
        // (`SecItemAdd` ignores `kSecAttrAccess` on modern macOS and restricts ACL to the caller only.)
        if writeGenericPasswordViaSecurityCLI(service: service, account: account, data: data) {
            return
        }

        var addQuery = lookupQuery
        addQuery[kSecValueData as String] = data
        _ = SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func writeGenericPasswordViaSecurityCLI(service: String, account: String, data: Data) -> Bool {
        let hexString = data.map { String(format: "%02x", $0) }.joined()
        var trustedArgs: [String] = ["-T", "/usr/bin/security"]
        let candidateApps = [
            AppConfig.defaultAppBundlePath,
            "\(AppConfig.defaultAppBundlePath)/Contents/Resources/bin/language_server",
            Bundle.main.bundlePath
        ]
        for path in candidateApps where !path.isEmpty && FileManager.default.fileExists(atPath: path) {
            trustedArgs.append(contentsOf: ["-T", escapedSecurityArg(path)])
        }

        let command = [
            "add-generic-password",
            "-U",
            "-s", escapedSecurityArg(service),
            "-a", escapedSecurityArg(account),
            "-X", hexString
        ] + trustedArgs

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            if let payload = (command.joined(separator: " ") + "\n").data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(payload)
            }
            try? stdinPipe.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func escapedSecurityArg(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
