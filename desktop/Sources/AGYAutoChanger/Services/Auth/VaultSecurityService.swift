import Foundation

// MARK: - Vault Errors & Manifest

public enum VaultSecurityError: LocalizedError, Sendable {
    case invalidRelativePath(String)
    case symlinkEscapeDetected(String)
    case snapshotMissing(String)
    case restoreFailedWithRollback(underlying: String, rollbackError: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path):
            return "Đường dẫn không hợp lệ bên ngoài vùng an toàn: \(path)"
        case .symlinkEscapeDetected(let path):
            return "Phát hiện symlink trỏ ra ngoài thư mục cho phép: \(path)"
        case .snapshotMissing(let name):
            return "Chưa có dữ liệu phiên (snapshot) cho tài khoản \(name). Hãy chọn 'Cập nhật Snapshot' khi tài khoản đang đăng nhập."
        case .restoreFailedWithRollback(let underlying, let rollbackError):
            if let rollbackError {
                return "Lỗi khôi phục phiên (\(underlying)); rollback gặp sự cố: \(rollbackError)"
            }
            return "Lỗi khôi phục phiên (\(underlying)). Đã tự động hoàn tác về phiên trước đó."
        }
    }
}

public struct SnapshotManifest: Codable, Sendable, Equatable {
    public let capturedAt: Date
    public let appSupportItems: [String]
    public let geminiItems: [String]
    public let ideAppSupportItems: [String]
    public let ideGeminiItems: [String]
    public let hasJetskiOAuthToken: Bool?
    public let hasCLIOAuthToken: Bool?

    public init(
        capturedAt: Date,
        appSupportItems: [String],
        geminiItems: [String],
        ideAppSupportItems: [String],
        ideGeminiItems: [String],
        hasJetskiOAuthToken: Bool? = nil,
        hasCLIOAuthToken: Bool? = nil
    ) {
        self.capturedAt = capturedAt
        self.appSupportItems = appSupportItems
        self.geminiItems = geminiItems
        self.ideAppSupportItems = ideAppSupportItems
        self.ideGeminiItems = ideGeminiItems
        self.hasJetskiOAuthToken = hasJetskiOAuthToken
        self.hasCLIOAuthToken = hasCLIOAuthToken
    }
}

// MARK: - Vault Security Service

/// Manages encrypted-permission (`0700`/`0600`) profile snapshots and atomic rollback-protected swaps.
public final class VaultSecurityService: Sendable {

    private var fileManager: FileManager { .default }

    public init() {}

    // MARK: - Directory & Permission Hardening

    public func ensureVaultDirectories(vaultRoot: URL = AppConfig.vaultRootDir, profilesDir: URL = AppConfig.profilesDir) throws {
        try createSecureDirectoryIfNeeded(at: vaultRoot)
        try createSecureDirectoryIfNeeded(at: profilesDir)
    }

    public func createSecureDirectoryIfNeeded(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try applyPosixPermissions(AppConfig.directoryPermissions, to: url)
    }

    public func applyPosixPermissions(_ permissions: Int, to url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    public func hardenPermissionsRecursively(at url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            try applyPosixPermissions(AppConfig.directoryPermissions, to: url)
            let children = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey])
            for child in children {
                let resourceValues = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
                if resourceValues.isSymbolicLink == true { continue }
                try hardenPermissionsRecursively(at: child)
            }
        } else {
            try applyPosixPermissions(AppConfig.filePermissions, to: url)
        }
    }

    // MARK: - Path Safety Validation

    /// Resolves a relative path safely within `base` and rejects traversal or escaping symlinks.
    public func safeChildURL(base: URL, relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/").map(String.init)
        if relativePath.hasPrefix("/") || components.contains("..") || components.isEmpty {
            throw VaultSecurityError.invalidRelativePath(relativePath)
        }

        let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL
        var candidate = base
        for part in components {
            candidate.appendPathComponent(part)
        }
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL

        let basePrefix = resolvedBase.path.hasSuffix("/") ? resolvedBase.path : resolvedBase.path + "/"
        guard resolvedCandidate.path == resolvedBase.path || resolvedCandidate.path.hasPrefix(basePrefix) else {
            throw VaultSecurityError.symlinkEscapeDetected(relativePath)
        }
        return candidate
    }

    // MARK: - Snapshot & Restore

    public func profileDirectory(for accountID: UUID, profilesRoot: URL = AppConfig.profilesDir) throws -> URL {
        let dir = profilesRoot.appendingPathComponent(accountID.uuidString, isDirectory: true)
        try createSecureDirectoryIfNeeded(at: dir)
        return dir
    }

    public func hasSnapshot(in profileDir: URL) -> Bool {
        let appSupportBackup = profileDir.appendingPathComponent("app_support", isDirectory: true)
        let geminiBackup = profileDir.appendingPathComponent("gemini", isDirectory: true)
        let jetskiTokenBackup = profileDir.appendingPathComponent("jetski_oauth_token", isDirectory: false)
        let cliTokenBackup = profileDir.appendingPathComponent("cli_oauth_token", isDirectory: false)
        return hasNonEmptyFiles(in: appSupportBackup)
            || hasNonEmptyFiles(in: geminiBackup)
            || fileManager.fileExists(atPath: jetskiTokenBackup.path)
            || fileManager.fileExists(atPath: cliTokenBackup.path)
    }

    @discardableResult
    public func snapshotCurrentSession(
        to profileDir: URL,
        appSupportDir: URL = AppConfig.agyAppSupportDir,
        geminiDir: URL = AppConfig.agyGeminiDir,
        jetskiTokenURL: URL = AppConfig.jetskiOAuthTokenURL,
        includeIDE: Bool = false,
        ideAppSupportDir: URL = AppConfig.agyIDEAppSupportDir,
        ideGeminiDir: URL = AppConfig.agyIDEGeminiDir,
        includeCLI: Bool = true,
        cliTokenURL: URL = AppConfig.agyCLIOAuthTokenURL
    ) throws -> SnapshotManifest {
        try createSecureDirectoryIfNeeded(at: profileDir)

        let appSupportDest = profileDir.appendingPathComponent("app_support", isDirectory: true)
        let geminiDest = profileDir.appendingPathComponent("gemini", isDirectory: true)
        let jetskiDest = profileDir.appendingPathComponent("jetski_oauth_token", isDirectory: false)
        let cliDest = profileDir.appendingPathComponent("cli_oauth_token", isDirectory: false)

        let capturedAppSupport = try copyTrackedItems(
            AppConfig.appSupportSessionItems,
            from: appSupportDir,
            to: appSupportDest,
            skipVolatileSuffixes: true
        )

        let capturedGemini = try copyTrackedItems(
            AppConfig.geminiSessionItems,
            from: geminiDir,
            to: geminiDest,
            skipVolatileSuffixes: false
        )

        var capturedJetskiToken = false
        if fileManager.fileExists(atPath: jetskiTokenURL.path) {
            try replaceItem(from: jetskiTokenURL, to: jetskiDest)
            try applyPosixPermissions(AppConfig.filePermissions, to: jetskiDest)
            capturedJetskiToken = true
        } else if fileManager.fileExists(atPath: jetskiDest.path) {
            try? fileManager.removeItem(at: jetskiDest)
        }

        var capturedCLIToken = false
        if includeCLI && fileManager.fileExists(atPath: cliTokenURL.path) {
            try replaceItem(from: cliTokenURL, to: cliDest)
            try applyPosixPermissions(AppConfig.filePermissions, to: cliDest)
            capturedCLIToken = true
        } else if includeCLI && fileManager.fileExists(atPath: cliDest.path) {
            try? fileManager.removeItem(at: cliDest)
        }

        var capturedIDEAppSupport: [String] = []
        var capturedIDEGemini: [String] = []
        if includeIDE {
            let ideSupportDest = profileDir.appendingPathComponent("ide_support", isDirectory: true)
            let ideGeminiDest = profileDir.appendingPathComponent("ide_gemini", isDirectory: true)
            capturedIDEAppSupport = try copyTrackedItems(
                AppConfig.ideAppSupportSessionItems,
                from: ideAppSupportDir,
                to: ideSupportDest,
                skipVolatileSuffixes: true
            )
            capturedIDEGemini = try copyTrackedItems(
                AppConfig.geminiSessionItems,
                from: ideGeminiDir,
                to: ideGeminiDest,
                skipVolatileSuffixes: false
            )
        }

        let manifest = SnapshotManifest(
            capturedAt: Date(),
            appSupportItems: capturedAppSupport,
            geminiItems: capturedGemini,
            ideAppSupportItems: capturedIDEAppSupport,
            ideGeminiItems: capturedIDEGemini,
            hasJetskiOAuthToken: capturedJetskiToken,
            hasCLIOAuthToken: capturedCLIToken
        )

        let manifestURL = profileDir.appendingPathComponent("snapshot_manifest.json", isDirectory: false)
        try writeJSON(manifest, to: manifestURL)
        return manifest
    }

    /// Synchronizes `~/.gemini/antigravity-cli/antigravity-oauth-token` (`0600`) ONLY when `~/.gemini/antigravity-cli` already exists.
    @discardableResult
    public func restoreCLITokenOnly(
        from profileDir: URL,
        cliTokenURL: URL = AppConfig.agyCLIOAuthTokenURL,
        fallbackOAuthJSON: Data? = nil
    ) throws -> Bool {
        let cliParentDir = cliTokenURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: cliParentDir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let cliSource = profileDir.appendingPathComponent("cli_oauth_token", isDirectory: false)
        let jetskiSource = profileDir.appendingPathComponent("jetski_oauth_token", isDirectory: false)

        if fileManager.fileExists(atPath: cliSource.path) {
            try replaceItem(from: cliSource, to: cliTokenURL)
            try applyPosixPermissions(AppConfig.filePermissions, to: cliTokenURL)
            return true
        } else if fileManager.fileExists(atPath: jetskiSource.path) {
            try replaceItem(from: jetskiSource, to: cliTokenURL)
            try applyPosixPermissions(AppConfig.filePermissions, to: cliTokenURL)
            return true
        } else if let fallbackOAuthJSON, !fallbackOAuthJSON.isEmpty {
            try writeProtectedData(fallbackOAuthJSON, to: cliTokenURL)
            return true
        } else if fileManager.fileExists(atPath: cliTokenURL.path) {
            try fileManager.removeItem(at: cliTokenURL)
        }
        return false
    }

    public func restoreSessionSnapshot(
        from profileDir: URL,
        accountDisplayName: String,
        appSupportDir: URL = AppConfig.agyAppSupportDir,
        geminiDir: URL = AppConfig.agyGeminiDir,
        jetskiTokenURL: URL = AppConfig.jetskiOAuthTokenURL,
        includeIDE: Bool = false,
        ideAppSupportDir: URL = AppConfig.agyIDEAppSupportDir,
        ideGeminiDir: URL = AppConfig.agyIDEGeminiDir,
        includeCLI: Bool = true,
        cliTokenURL: URL = AppConfig.agyCLIOAuthTokenURL,
        fallbackCLIOAuthJSON: Data? = nil
    ) throws {
        guard hasSnapshot(in: profileDir) else {
            throw VaultSecurityError.snapshotMissing(accountDisplayName)
        }

        let rollbackDir = profileDir
            .deletingLastPathComponent()
            .appendingPathComponent(".rollback_\(UUID().uuidString)", isDirectory: true)
        try createSecureDirectoryIfNeeded(at: rollbackDir)
        defer {
            try? fileManager.removeItem(at: rollbackDir)
        }

        // Capture live state for rollback before mutating anything.
        _ = try? snapshotCurrentSession(
            to: rollbackDir,
            appSupportDir: appSupportDir,
            geminiDir: geminiDir,
            jetskiTokenURL: jetskiTokenURL,
            includeIDE: includeIDE,
            ideAppSupportDir: ideAppSupportDir,
            ideGeminiDir: ideGeminiDir,
            includeCLI: includeCLI,
            cliTokenURL: cliTokenURL
        )

        do {
            try removeStaleRuntimeFiles(in: appSupportDir)

            let appSupportSource = profileDir.appendingPathComponent("app_support", isDirectory: true)
            if fileManager.fileExists(atPath: appSupportSource.path) {
                try createSecureDirectoryIfNeeded(at: appSupportDir)
                _ = try restoreTrackedItems(
                    AppConfig.appSupportSessionItems,
                    from: appSupportSource,
                    to: appSupportDir
                )
            }

            let geminiSource = profileDir.appendingPathComponent("gemini", isDirectory: true)
            if fileManager.fileExists(atPath: geminiSource.path) {
                try createSecureDirectoryIfNeeded(at: geminiDir)
                _ = try restoreTrackedItems(
                    AppConfig.geminiSessionItems,
                    from: geminiSource,
                    to: geminiDir
                )
            }

            let jetskiSource = profileDir.appendingPathComponent("jetski_oauth_token", isDirectory: false)
            if fileManager.fileExists(atPath: jetskiSource.path) {
                try createSecureDirectoryIfNeeded(at: jetskiTokenURL.deletingLastPathComponent())
                try replaceItem(from: jetskiSource, to: jetskiTokenURL)
                try applyPosixPermissions(AppConfig.filePermissions, to: jetskiTokenURL)
            } else if fileManager.fileExists(atPath: jetskiTokenURL.path) {
                try fileManager.removeItem(at: jetskiTokenURL)
            }

            if includeCLI {
                _ = try restoreCLITokenOnly(
                    from: profileDir,
                    cliTokenURL: cliTokenURL,
                    fallbackOAuthJSON: fallbackCLIOAuthJSON
                )
            }

            if includeIDE {
                let ideSupportSource = profileDir.appendingPathComponent("ide_support", isDirectory: true)
                if fileManager.fileExists(atPath: ideSupportSource.path) {
                    try createSecureDirectoryIfNeeded(at: ideAppSupportDir)
                    _ = try restoreTrackedItems(
                        AppConfig.ideAppSupportSessionItems,
                        from: ideSupportSource,
                        to: ideAppSupportDir
                    )
                }

                let ideGeminiSource = profileDir.appendingPathComponent("ide_gemini", isDirectory: true)
                if fileManager.fileExists(atPath: ideGeminiSource.path) {
                    try createSecureDirectoryIfNeeded(at: ideGeminiDir)
                    _ = try restoreTrackedItems(
                        AppConfig.geminiSessionItems,
                        from: ideGeminiSource,
                        to: ideGeminiDir
                    )
                }
            }
        } catch {
            var rollbackErrorText: String?
            do {
                try restoreFromRollback(
                    rollbackDir,
                    appSupportDir: appSupportDir,
                    geminiDir: geminiDir,
                    jetskiTokenURL: jetskiTokenURL,
                    includeIDE: includeIDE,
                    ideAppSupportDir: ideAppSupportDir,
                    ideGeminiDir: ideGeminiDir,
                    includeCLI: includeCLI,
                    cliTokenURL: cliTokenURL
                )
            } catch let rollbackError {
                rollbackErrorText = rollbackError.localizedDescription
            }
            throw VaultSecurityError.restoreFailedWithRollback(
                underlying: error.localizedDescription,
                rollbackError: rollbackErrorText
            )
        }
    }

    public func clearLiveSessionForNewLogin(
        appSupportDir: URL = AppConfig.agyAppSupportDir,
        geminiDir: URL = AppConfig.agyGeminiDir,
        jetskiTokenURL: URL = AppConfig.jetskiOAuthTokenURL,
        cliTokenURL: URL = AppConfig.agyCLIOAuthTokenURL
    ) throws {
        try removeStaleRuntimeFiles(in: appSupportDir)

        let itemsToClear = [
            "Cookies",
            "Cookies-journal",
            "Local Storage",
            "Session Storage",
            "Network Persistent State",
            "DIPS",
            "Trust Tokens",
            "credential-user-scope"
        ]

        for rel in itemsToClear {
            let target = try safeChildURL(base: appSupportDir, relativePath: rel)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }

        // Remove onboarding username/ToS flags from app_storage.json while keeping user workspace layouts/projects.
        let appStorageURL = try safeChildURL(base: appSupportDir, relativePath: "app_storage.json")
        if fileManager.fileExists(atPath: appStorageURL.path) {
            try stripJSONKeys(AppConfig.appStorageOnboardingKeysToClear, at: appStorageURL)
        }

        for rel in AppConfig.geminiSessionItems {
            let target = try safeChildURL(base: geminiDir, relativePath: rel)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }

        // Clear any go-keyring availability marker files so language_server re-evaluates cleanly.
        for dir in [geminiDir, jetskiTokenURL.deletingLastPathComponent()] {
            if let children = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for child in children where child.lastPathComponent.hasPrefix("keyring-marker-") {
                    try? fileManager.removeItem(at: child)
                }
            }
        }

        if fileManager.fileExists(atPath: jetskiTokenURL.path) {
            try fileManager.removeItem(at: jetskiTokenURL)
        }
        if fileManager.fileExists(atPath: cliTokenURL.path) {
            try fileManager.removeItem(at: cliTokenURL)
        }
    }

    public func deleteProfileDirectory(for accountID: UUID, profilesRoot: URL = AppConfig.profilesDir) throws {
        let dir = profilesRoot.appendingPathComponent(accountID.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    // MARK: - Secure JSON & File Persistence

    public func writeProtectedData(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try createSecureDirectoryIfNeeded(at: parent)

        let tempURL = parent.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        try applyPosixPermissions(AppConfig.filePermissions, to: tempURL)

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: url)
        }
        try applyPosixPermissions(AppConfig.filePermissions, to: url)
    }

    public func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try writeProtectedData(data, to: url)
    }

    public func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    // MARK: - Private Copy Helpers

    private func copyTrackedItems(
        _ relativePaths: [String],
        from sourceRoot: URL,
        to destRoot: URL,
        skipVolatileSuffixes: Bool
    ) throws -> [String] {
        // Recreate destination container cleanly so deleted auth items don't remain stale.
        if fileManager.fileExists(atPath: destRoot.path) {
            try fileManager.removeItem(at: destRoot)
        }
        try createSecureDirectoryIfNeeded(at: destRoot)

        var captured: [String] = []
        for rel in relativePaths {
            if skipVolatileSuffixes, rel == "Cookies-journal" {
                continue
            }
            let src = try safeChildURL(base: sourceRoot, relativePath: rel)
            guard fileManager.fileExists(atPath: src.path) else { continue }

            let dst = try safeChildURL(base: destRoot, relativePath: rel)
            try createSecureDirectoryIfNeeded(at: dst.deletingLastPathComponent())
            try replaceItem(from: src, to: dst)
            try hardenPermissionsRecursively(at: dst)
            captured.append(rel)
        }
        return captured
    }

    private func restoreTrackedItems(
        _ relativePaths: [String],
        from sourceRoot: URL,
        to destRoot: URL
    ) throws -> [String] {
        var restored: [String] = []
        for rel in relativePaths {
            let src = try safeChildURL(base: sourceRoot, relativePath: rel)
            let dst = try safeChildURL(base: destRoot, relativePath: rel)

            guard fileManager.fileExists(atPath: src.path) else {
                // Remove old live artifact if the snapshot intentionally lacked it (e.g. clean state)
                if (rel == "Cookies-journal" || rel == "credential-user-scope"), fileManager.fileExists(atPath: dst.path) {
                    try? fileManager.removeItem(at: dst)
                }
                continue
            }

            try createSecureDirectoryIfNeeded(at: dst.deletingLastPathComponent())
            try replaceItem(from: src, to: dst)
            try hardenPermissionsRecursively(at: dst)
            restored.append(rel)
        }
        return restored
    }

    private func restoreFromRollback(
        _ rollbackDir: URL,
        appSupportDir: URL,
        geminiDir: URL,
        jetskiTokenURL: URL,
        includeIDE: Bool,
        ideAppSupportDir: URL,
        ideGeminiDir: URL,
        includeCLI: Bool,
        cliTokenURL: URL
    ) throws {
        let appSupportRollback = rollbackDir.appendingPathComponent("app_support", isDirectory: true)
        if fileManager.fileExists(atPath: appSupportRollback.path) {
            _ = try restoreTrackedItems(AppConfig.appSupportSessionItems, from: appSupportRollback, to: appSupportDir)
        }
        let geminiRollback = rollbackDir.appendingPathComponent("gemini", isDirectory: true)
        if fileManager.fileExists(atPath: geminiRollback.path) {
            _ = try restoreTrackedItems(AppConfig.geminiSessionItems, from: geminiRollback, to: geminiDir)
        }
        let jetskiRollback = rollbackDir.appendingPathComponent("jetski_oauth_token", isDirectory: false)
        if fileManager.fileExists(atPath: jetskiRollback.path) {
            try createSecureDirectoryIfNeeded(at: jetskiTokenURL.deletingLastPathComponent())
            try replaceItem(from: jetskiRollback, to: jetskiTokenURL)
        }
        if includeCLI {
            let cliRollback = rollbackDir.appendingPathComponent("cli_oauth_token", isDirectory: false)
            if fileManager.fileExists(atPath: cliRollback.path) {
                let cliParent = cliTokenURL.deletingLastPathComponent()
                if fileManager.fileExists(atPath: cliParent.path) {
                    try replaceItem(from: cliRollback, to: cliTokenURL)
                    try applyPosixPermissions(AppConfig.filePermissions, to: cliTokenURL)
                }
            }
        }
        if includeIDE {
            let ideSupportRollback = rollbackDir.appendingPathComponent("ide_support", isDirectory: true)
            if fileManager.fileExists(atPath: ideSupportRollback.path) {
                _ = try restoreTrackedItems(AppConfig.ideAppSupportSessionItems, from: ideSupportRollback, to: ideAppSupportDir)
            }
            let ideGeminiRollback = rollbackDir.appendingPathComponent("ide_gemini", isDirectory: true)
            if fileManager.fileExists(atPath: ideGeminiRollback.path) {
                _ = try restoreTrackedItems(AppConfig.geminiSessionItems, from: ideGeminiRollback, to: ideGeminiDir)
            }
        }
    }

    private func stripJSONKeys(_ keys: [String], at jsonURL: URL) throws {
        let data = try Data(contentsOf: jsonURL)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        var didMutate = false
        for key in keys where object.removeValue(forKey: key) != nil {
            didMutate = true
        }
        guard didMutate else { return }

        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let tempURL = jsonURL.deletingLastPathComponent()
            .appendingPathComponent(".\(jsonURL.lastPathComponent).clean.\(UUID().uuidString)")
        try updated.write(to: tempURL, options: .atomic)
        _ = try fileManager.replaceItemAt(jsonURL, withItemAt: tempURL)
    }

    private func replaceItem(from src: URL, to dst: URL) throws {
        let staging = dst.deletingLastPathComponent()
            .appendingPathComponent(".\(dst.lastPathComponent).stage.\(UUID().uuidString)")
        try fileManager.copyItem(at: src, to: staging)

        if fileManager.fileExists(atPath: dst.path) {
            try fileManager.removeItem(at: dst)
        }
        try fileManager.moveItem(at: staging, to: dst)
    }

    private func removeStaleRuntimeFiles(in appSupportDir: URL) throws {
        guard fileManager.fileExists(atPath: appSupportDir.path) else { return }
        for artifact in AppConfig.staleRuntimeArtifacts {
            let target = try safeChildURL(base: appSupportDir, relativePath: artifact)
            if fileManager.fileExists(atPath: target.path) {
                try? fileManager.removeItem(at: target)
            }
        }
    }

    private func hasNonEmptyFiles(in directory: URL) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        return !entries.isEmpty
    }
}
