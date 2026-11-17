import AppKit
import Foundation

// MARK: - Account Switcher Service

/// Coordinates vault persistence, live AGY inspection, per-model usage updates,
/// and 1-click atomic account switching with automatic Antigravity restart.
@MainActor
public final class AccountSwitcherService: ObservableObject {

    // MARK: - Published State

    @Published public var accounts: [AccountProfile] = []
    @Published public var settings: SwitcherSettings = SwitcherSettings()
    @Published public var switchPhase: SwitchPhase = .idle
    @Published public var liveState: AGYLiveStateSnapshot = AGYLiveStateSnapshot()
    @Published public var isRefreshingUsage: Bool = false

    // MARK: - Dependencies

    private let vaultSecurity: VaultSecurityService
    private let keychainFallback: KeychainFallbackService
    private let stateInspector: AGYStateInspectorService
    private let usageTracker: UsageTrackerService
    private let cloudQuotaService: CloudCodeQuotaService
    private let quotaNotifier: QuotaThresholdNotifier

    private var loginWatcherTask: Task<Void, Never>?
    private var statusResetTask: Task<Void, Never>?
    private var postSwitchSyncTask: Task<Void, Never>?
    private var backgroundPollingTask: Task<Void, Never>?
    private var hasBootstrapped = false
    private var isManagedAGYRestartInProgress = false
    private var isSyncingCLIUsage = false

    private lazy var lifecycleService = AGYCompanionLifecycleService(
        settingsProvider: { [weak self] in
            self?.settings ?? SwitcherSettings()
        },
        isManagedRestartInProgress: { [weak self] in
            guard let self else { return false }
            return self.switchPhase.isInProgress || self.isManagedAGYRestartInProgress
        }
    )

    public init(
        vaultSecurity: VaultSecurityService = VaultSecurityService(),
        keychainFallback: KeychainFallbackService = KeychainFallbackService(),
        stateInspector: AGYStateInspectorService = AGYStateInspectorService(),
        usageTracker: UsageTrackerService = UsageTrackerService(),
        cloudQuotaService: CloudCodeQuotaService = CloudCodeQuotaService(),
        quotaNotifier: QuotaThresholdNotifier? = nil
    ) {
        self.vaultSecurity = vaultSecurity
        self.keychainFallback = keychainFallback
        self.stateInspector = stateInspector
        self.usageTracker = usageTracker
        self.cloudQuotaService = cloudQuotaService
        self.quotaNotifier = quotaNotifier ?? QuotaThresholdNotifier()
    }

    // MARK: - Bootstrap & Refresh

    public func bootstrapOnLaunch() {
        guard !hasBootstrapped else {
            refreshLiveStateAndUsage(readKeychainSecret: false)
            return
        }
        hasBootstrapped = true

        do {
            try vaultSecurity.ensureVaultDirectories()
            loadSettings()
            lifecycleService.startObserving()
            lifecycleService.syncWatcherRegistration(enabled: settings.bindLifecycleWithAGY)
            if settings.enableLowQuotaNotification {
                quotaNotifier.requestAuthorizationIfNeeded()
            }
            startBackgroundQuotaPolling()
            loadAccounts()
            liveState = inspectCurrentLiveState(readKeychainSecret: false)

            // First-run convenience: auto-register the currently signed-in AGY account if vault is empty.
            if accounts.isEmpty && liveState.hasSessionFiles {
                try captureCurrentSessionAsNewAccount(
                    displayName: liveState.detectedDisplayName ?? "Tài khoản chính",
                    email: liveState.detectedEmail ?? "Đang đăng nhập trên AGY",
                    tier: liveState.detectedTier ?? .pro
                )
            } else {
                refreshLiveStateAndUsage(readKeychainSecret: false)
            }
        } catch {
            switchPhase = .failed(error.localizedDescription)
        }
    }

    public func refreshLiveStateAndUsage(readKeychainSecret: Bool = false) {
        isRefreshingUsage = true

        liveState = inspectCurrentLiveState(readKeychainSecret: readKeychainSecret)

        if let activeIndex = accounts.firstIndex(where: { $0.isActive }) {
            // Update email automatically if previously unknown or switched externally
            if let detectedEmail = liveState.detectedEmail,
               accounts[activeIndex].email.isEmpty
                || accounts[activeIndex].email.contains("Chưa")
                || accounts[activeIndex].email.contains("Đang đăng nhập")
                || accounts[activeIndex].email.contains("Chờ đăng nhập") {
                accounts[activeIndex].email = detectedEmail
                if accounts[activeIndex].displayName.hasPrefix("Tài khoản") || accounts[activeIndex].displayName.hasPrefix("Account") {
                    accounts[activeIndex].displayName = liveState.detectedDisplayName ?? detectedEmail
                }
            }

            if let detectedTier = liveState.detectedTier, accounts[activeIndex].tier != detectedTier {
                accounts[activeIndex].applyTier(detectedTier)
            }

            accumulateLocalTelemetry(forAccountAt: activeIndex)
            persistAccountsSilently()
            evaluateQuotaNotifications()
        }

        Task { [weak self] in
            await self?.syncDashboardQuotasForAllAccounts(useLiveKeychainForActive: readKeychainSecret)
            self?.isRefreshingUsage = false
        }
    }

    // MARK: - 1-Click Account Switching

    /// Atomically snapshots the outgoing account, restarts Antigravity cleanly, restores the target account, and relaunches.
    public func switchToAccount(_ target: AccountProfile) async {
        guard !switchPhase.isInProgress else { return }

        // Clicking an already-active card simply refreshes its snapshot and usage.
        if target.isActive {
            do {
                try snapshotActiveAccount(account: target)
                refreshLiveStateAndUsage()
                setTemporaryCompletedState("Đã làm mới phiên \(target.displayName)")
            } catch {
                switchPhase = .failed(error.localizedDescription)
            }
            return
        }

        statusResetTask?.cancel()
        loginWatcherTask?.cancel()
        postSwitchSyncTask?.cancel()

        isManagedAGYRestartInProgress = true
        defer { isManagedAGYRestartInProgress = false }

        do {
            let targetProfileDir = try vaultSecurity.profileDirectory(for: target.id)
            guard vaultSecurity.hasSnapshot(in: targetProfileDir) else {
                throw VaultSecurityError.snapshotMissing(target.displayName)
            }

            // 1. Flush usage delta and backup outgoing active account before closing Antigravity
            if let activeIdx = accounts.firstIndex(where: { $0.isActive }) {
                switchPhase = .backingUpCurrent(accounts[activeIdx].displayName)
                accumulateLocalTelemetry(forAccountAt: activeIdx)
                try snapshotActiveAccount(account: accounts[activeIdx])
            }

            // 2. Gracefully terminate Antigravity + language_server so OAuth caches & SQLite flush cleanly
            switchPhase = .terminatingAGY
            await terminateAntigravityProcesses()
            await ensureLanguageServerStopped()

            // 3. Restore target snapshot atomically (with automatic rollback on failure)
            switchPhase = .restoringSnapshot(target.displayName)
            try vaultSecurity.restoreSessionSnapshot(
                from: targetProfileDir,
                accountDisplayName: target.displayName,
                includeIDE: settings.syncIDESession
            )

            // Sync scoped OAuth Keychain item (`gemini`/`antigravity`) and optional secondary entries
            try keychainFallback.restoreScopedKeychain(
                from: targetProfileDir,
                includeSecondaryServices: settings.useKeychainFallback,
                clearPrimaryIfMissing: true
            )

            // 4. Mark target active without wiping its stored Dashboard quotas or accumulated telemetry
            let switchNow = Date()
            for idx in accounts.indices {
                accounts[idx].isActive = (accounts[idx].id == target.id)
                if accounts[idx].id == target.id {
                    accounts[idx].lastSwitchedAt = switchNow
                    accounts[idx].lastUsageScanAt = switchNow
                }
            }
            persistAccountsSilently()

            // 5. Relaunch Antigravity immediately if auto-relaunch is enabled
            if settings.autoRelaunchAGY {
                switchPhase = .relaunchingAGY
                try await relaunchAntigravity()
            }

            refreshLiveStateAndUsage(readKeychainSecret: false)
            schedulePostSwitchDashboardSync(for: target.id)
            setTemporaryCompletedState(target.displayName)
        } catch {
            switchPhase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Account Capture & Clean Login Flow

    public func captureCurrentSessionAsNewAccount(
        displayName: String,
        email: String,
        tier: AccountTier
    ) throws {
        // Flush delta & save outgoing active session before reassigning active status
        if let activeIdx = accounts.firstIndex(where: { $0.isActive }) {
            accumulateLocalTelemetry(forAccountAt: activeIdx)
            try? snapshotActiveAccount(account: accounts[activeIdx])
        }

        liveState = inspectCurrentLiveState(readKeychainSecret: true)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = trimmedEmail.isEmpty ? (liveState.detectedEmail ?? "Chưa xác định email") : trimmedEmail
        let resolvedName = trimmedName.isEmpty ? (liveState.detectedDisplayName ?? resolvedEmail) : trimmedName
        let resolvedTier = liveState.detectedTier ?? tier

        let captureNow = Date()
        let colorHex = AppConfig.avatarPaletteHex[accounts.count % AppConfig.avatarPaletteHex.count]
        var newAccount = AccountProfile(
            email: resolvedEmail,
            displayName: resolvedName,
            avatarHex: colorHex,
            tier: resolvedTier,
            isActive: true,
            createdAt: captureNow,
            lastSwitchedAt: nil,
            lastSnapshotAt: captureNow,
            lastUsageScanAt: captureNow
        )

        let profileDir = try vaultSecurity.profileDirectory(for: newAccount.id)
        try vaultSecurity.snapshotCurrentSession(
            to: profileDir,
            includeIDE: settings.syncIDESession
        )

        newAccount.hasKeychainBackup = (try? keychainFallback.snapshotScopedKeychain(
            to: profileDir,
            includeSecondaryServices: settings.useKeychainFallback
        )) ?? false

        for idx in accounts.indices {
            accounts[idx].isActive = false
        }
        accounts.append(newAccount)
        try vaultSecurity.writeJSON(accounts, to: AppConfig.accountsMetadataURL)

        refreshLiveStateAndUsage(readKeychainSecret: true)
        setTemporaryCompletedState("Đã lưu \(resolvedName)")
    }

    /// Snapshots the current account, resets live session + OAuth Keychain credential, and opens Antigravity so the user can sign into another account.
    public func prepareCleanLoginForNewAccount(
        displayName: String,
        email: String,
        tier: AccountTier
    ) async {
        guard !switchPhase.isInProgress else { return }
        statusResetTask?.cancel()
        loginWatcherTask?.cancel()

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Tài khoản \(accounts.count + 1)" : trimmedName
        let resolvedEmail = trimmedEmail.isEmpty ? "Chờ đăng nhập..." : trimmedEmail

        postSwitchSyncTask?.cancel()

        isManagedAGYRestartInProgress = true
        defer { isManagedAGYRestartInProgress = false }

        do {
            if let activeIdx = accounts.firstIndex(where: { $0.isActive }) {
                switchPhase = .backingUpCurrent(accounts[activeIdx].displayName)
                accumulateLocalTelemetry(forAccountAt: activeIdx)
                try snapshotActiveAccount(account: accounts[activeIdx])
            }

            let preCleanState = inspectCurrentLiveState(readKeychainSecret: true)

            switchPhase = .terminatingAGY
            await terminateAntigravityProcesses()
            await ensureLanguageServerStopped()

            try vaultSecurity.clearLiveSessionForNewLogin()
            keychainFallback.clearPrimaryAuthKeychain()

            let cleanStartNow = Date()
            let colorHex = AppConfig.avatarPaletteHex[accounts.count % AppConfig.avatarPaletteHex.count]
            let newAccount = AccountProfile(
                email: resolvedEmail,
                displayName: resolvedName,
                avatarHex: colorHex,
                tier: tier,
                isActive: true,
                createdAt: cleanStartNow,
                lastSwitchedAt: cleanStartNow,
                lastSnapshotAt: nil,
                lastUsageScanAt: cleanStartNow
            )

            for idx in accounts.indices {
                accounts[idx].isActive = false
            }
            accounts.append(newAccount)
            persistAccountsSilently()

            switchPhase = .relaunchingAGY
            try await relaunchAntigravity()

            switchPhase = .awaitingNewLogin(resolvedName)
            startWatchingForCompletedLogin(
                accountID: newAccount.id,
                previousEmail: preCleanState.detectedEmail,
                previousAuthFingerprint: preCleanState.authFingerprint
            )
        } catch {
            switchPhase = .failed(error.localizedDescription)
        }
    }

    public func updateSnapshotForAccount(_ account: AccountProfile) {
        do {
            try snapshotActiveAccount(account: account)
            refreshLiveStateAndUsage()
            setTemporaryCompletedState("Đã cập nhật snapshot \(account.displayName)")
        } catch {
            switchPhase = .failed(error.localizedDescription)
        }
    }

    public func deleteAccount(_ account: AccountProfile) {
        do {
            try vaultSecurity.deleteProfileDirectory(for: account.id)
            accounts.removeAll { $0.id == account.id }
            persistAccountsSilently()
        } catch {
            switchPhase = .failed(error.localizedDescription)
        }
    }

    public func updateTier(for accountID: UUID, tier: AccountTier) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[idx].applyTier(tier)
        persistAccountsSilently()
    }

    // MARK: - Cooldown & Settings Controls

    public func markModelRateLimited(
        accountID: UUID,
        modelID: String,
        durationMinutes: Int = AppConfig.defaultCooldownMinutes
    ) {
        guard let accIndex = accounts.firstIndex(where: { $0.id == accountID }),
              let modelIndex = accounts[accIndex].modelUsages.firstIndex(where: { $0.id == modelID }) else {
            return
        }
        accounts[accIndex].modelUsages[modelIndex].cooldownUntil = Date().addingTimeInterval(TimeInterval(durationMinutes * 60))
        persistAccountsSilently()
    }

    public func clearCooldowns(for accountID: UUID) {
        guard let accIndex = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        for mIdx in accounts[accIndex].modelUsages.indices {
            accounts[accIndex].modelUsages[mIdx].cooldownUntil = nil
        }
        persistAccountsSilently()
    }

    public func saveSettings(_ updated: SwitcherSettings) {
        var sanitized = updated
        sanitized.lowQuotaThresholdPercent = min(95, max(5, sanitized.lowQuotaThresholdPercent))
        settings = sanitized
        try? vaultSecurity.writeJSON(settings, to: AppConfig.settingsMetadataURL)
        lifecycleService.syncWatcherRegistration(enabled: settings.bindLifecycleWithAGY)
        if settings.enableLowQuotaNotification {
            quotaNotifier.requestAuthorizationIfNeeded()
            evaluateQuotaNotifications()
        }
        refreshLiveStateAndUsage()
    }

    public func hasValidSnapshot(for account: AccountProfile) -> Bool {
        guard let dir = try? vaultSecurity.profileDirectory(for: account.id) else { return false }
        return vaultSecurity.hasSnapshot(in: dir)
    }

    public func openVaultInFinder() {
        try? vaultSecurity.ensureVaultDirectories()
        NSWorkspace.shared.open(AppConfig.vaultRootDir)
    }

    // MARK: - Private Helpers

    private func snapshotActiveAccount(account: AccountProfile) throws {
        let profileDir = try vaultSecurity.profileDirectory(for: account.id)
        try vaultSecurity.snapshotCurrentSession(
            to: profileDir,
            includeIDE: settings.syncIDESession
        )

        let fallbackFile = profileDir.appendingPathComponent("keychain_fallback.json", isDirectory: false)
        let hasExistingBackup = account.hasKeychainBackup && FileManager.default.fileExists(atPath: fallbackFile.path)
        let capturedKeychain: Bool
        if hasExistingBackup && !settings.useKeychainFallback {
            // Avoid prompting macOS Keychain ACL when switching between already-backed-up accounts.
            capturedKeychain = true
        } else {
            capturedKeychain = (try? keychainFallback.snapshotScopedKeychain(
                to: profileDir,
                includeSecondaryServices: settings.useKeychainFallback
            )) ?? account.hasKeychainBackup
        }

        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx].lastSnapshotAt = Date()
            accounts[idx].hasKeychainBackup = capturedKeychain
        }
        persistAccountsSilently()
    }

    private func inspectCurrentLiveState(readKeychainSecret: Bool) -> AGYLiveStateSnapshot {
        let kcMeta = keychainFallback.inspectAuthMetadata(readKeychainSecret: readKeychainSecret)
        return stateInspector.inspectLiveState(keychainAuthMetadata: kcMeta)
    }

    private func accumulateLocalTelemetry(forAccountAt index: Int) {
        guard accounts.indices.contains(index) else { return }
        let now = Date()
        let cutoff = accounts[index].lastUsageScanAt ?? accounts[index].lastSwitchedAt
        let summary = usageTracker.scanUsage(
            rollingWindowHours: settings.rollingWindowHours,
            sinceAccountSwitch: cutoff,
            referenceDate: now
        )
        accounts[index].modelUsages = usageTracker.mergeIncremental(
            summary: summary,
            into: accounts[index].modelUsages,
            tier: accounts[index].tier
        )
        accounts[index].lastUsageScanAt = now
    }

    private func syncDashboardQuotasForAllAccounts(useLiveKeychainForActive: Bool) async {
        var didUpdateAny = false

        for idx in accounts.indices {
            let account = accounts[idx]
            let profileDir = try? vaultSecurity.profileDirectory(for: account.id)
            guard let token = await keychainFallback.resolveOrRefreshBearerToken(
                fromProfileDir: profileDir,
                useLiveKeychain: account.isActive && useLiveKeychainForActive
            ) else {
                continue
            }

            if let snapshot = await cloudQuotaService.fetchDashboardSnapshot(
                bearerToken: token,
                allowCLIUsage: false
            ) {
                let applied = cloudQuotaService.applyDashboardSnapshot(
                    snapshot,
                    into: accounts[idx].modelUsages,
                    currentTier: accounts[idx].tier
                )
                accounts[idx].tier = applied.tier
                accounts[idx].modelUsages = applied.usages
                accounts[idx].lastDashboardSyncAt = snapshot.syncedAt
                didUpdateAny = true
            }
        }

        if didUpdateAny {
            persistAccountsSilently()
            evaluateQuotaNotifications()
        }

        if CloudCodeQuotaService.isAgyCLIAvailable && !isSyncingCLIUsage {
            Task { [weak self] in
                await self?.syncActiveAccountCLIUsageIfAvailable()
            }
        }
    }

    private func syncActiveAccountCLIUsageIfAvailable() async {
        guard CloudCodeQuotaService.isAgyCLIAvailable,
              !isSyncingCLIUsage,
              !switchPhase.isInProgress,
              let targetAccountID = accounts.first(where: { $0.isActive })?.id else {
            return
        }

        isSyncingCLIUsage = true
        defer { isSyncingCLIUsage = false }

        guard let cliQuotas = await cloudQuotaService.fetchAgyCLIUsageQuotas(),
              !switchPhase.isInProgress,
              let activeIdx = accounts.firstIndex(where: { $0.id == targetAccountID && $0.isActive }) else {
            return
        }

        let cliSnapshot = CloudCodeDashboardSnapshot(quotasByModel: cliQuotas, syncedAt: Date())
        let applied = cloudQuotaService.applyDashboardSnapshot(
            cliSnapshot,
            into: accounts[activeIdx].modelUsages,
            currentTier: accounts[activeIdx].tier
        )
        accounts[activeIdx].tier = applied.tier
        accounts[activeIdx].modelUsages = applied.usages
        accounts[activeIdx].lastDashboardSyncAt = cliSnapshot.syncedAt
        persistAccountsSilently()
        evaluateQuotaNotifications()
    }

    private func evaluateQuotaNotifications() {
        quotaNotifier.evaluateAndNotify(
            for: accounts,
            isEnabled: settings.enableLowQuotaNotification,
            thresholdPercent: settings.lowQuotaThresholdPercent
        )
    }

    private func startBackgroundQuotaPolling() {
        guard backgroundPollingTask == nil else { return }
        backgroundPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: AppConfig.backgroundQuotaPollIntervalNanoseconds)
                guard !Task.isCancelled, let self else { return }
                if !self.switchPhase.isInProgress && !self.isRefreshingUsage {
                    self.refreshLiveStateAndUsage(readKeychainSecret: false)
                }
            }
        }
    }

    private func schedulePostSwitchDashboardSync(for accountID: UUID) {
        postSwitchSyncTask?.cancel()
        postSwitchSyncTask = Task { [weak self] in
            // Antigravity's language_server typically refreshes expired OAuth access tokens 2-8s after relaunch.
            for delaySec in [3, 4, 7] {
                try? await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard let idx = self.accounts.firstIndex(where: { $0.id == accountID }),
                      self.accounts[idx].isActive else {
                    return
                }

                let profileDir = try? self.vaultSecurity.profileDirectory(for: accountID)
                guard let token = await self.keychainFallback.resolveOrRefreshBearerToken(
                    fromProfileDir: profileDir,
                    useLiveKeychain: false
                ) else {
                    continue
                }

                if let snapshot = await self.cloudQuotaService.fetchDashboardSnapshot(
                    bearerToken: token,
                    allowCLIUsage: false
                ) {
                    let applied = self.cloudQuotaService.applyDashboardSnapshot(
                        snapshot,
                        into: self.accounts[idx].modelUsages,
                        currentTier: self.accounts[idx].tier
                    )
                    self.accounts[idx].tier = applied.tier
                    self.accounts[idx].modelUsages = applied.usages
                    self.accounts[idx].lastDashboardSyncAt = snapshot.syncedAt

                    // Persist the refreshed access_token & updated metadata cleanly to Vault
                    try? self.snapshotActiveAccount(account: self.accounts[idx])
                    self.persistAccountsSilently()
                    self.evaluateQuotaNotifications()
                    if CloudCodeQuotaService.isAgyCLIAvailable && !self.isSyncingCLIUsage {
                        Task { [weak self] in
                            await self?.syncActiveAccountCLIUsageIfAvailable()
                        }
                    }
                    return
                }
            }
        }
    }

    private func loadAccounts() {
        guard FileManager.default.fileExists(atPath: AppConfig.accountsMetadataURL.path),
              var loaded = try? vaultSecurity.readJSON([AccountProfile].self, from: AppConfig.accountsMetadataURL) else {
            accounts = []
            return
        }

        let canonicalIDs = AppConfig.supportedModels.map(\.id)
        var didMigrate = false
        for idx in loaded.indices {
            if loaded[idx].modelUsages.map(\.id) != canonicalIDs {
                var migrated = ModelUsage.defaultSet(for: loaded[idx].tier)
                for mIdx in migrated.indices {
                    if let existingMatch = loaded[idx].modelUsages.first(where: { $0.id == migrated[mIdx].id }) {
                        migrated[mIdx].turnsUsed = existingMatch.turnsUsed
                        migrated[mIdx].tokensUsed = existingMatch.tokensUsed
                        migrated[mIdx].lastUsedAt = existingMatch.lastUsedAt
                        migrated[mIdx].cooldownUntil = existingMatch.cooldownUntil
                        migrated[mIdx].quotaRemainingFraction = existingMatch.quotaRemainingFraction
                        migrated[mIdx].quotaResetAt = existingMatch.quotaResetAt
                        migrated[mIdx].quotaSyncedAt = existingMatch.quotaSyncedAt
                    }
                }
                loaded[idx].modelUsages = migrated
                loaded[idx].lastUsageScanAt = nil
                didMigrate = true
            }
        }

        accounts = loaded
        if didMigrate {
            persistAccountsSilently()
        }
    }

    private func loadSettings() {
        guard FileManager.default.fileExists(atPath: AppConfig.settingsMetadataURL.path),
              let loaded = try? vaultSecurity.readJSON(SwitcherSettings.self, from: AppConfig.settingsMetadataURL) else {
            settings = SwitcherSettings()
            return
        }
        settings = loaded
    }

    private func persistAccountsSilently() {
        try? vaultSecurity.writeJSON(accounts, to: AppConfig.accountsMetadataURL)
    }

    private func setTemporaryCompletedState(_ name: String) {
        statusResetTask?.cancel()
        switchPhase = .completed(name)
        statusResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.switchPhase = .idle
        }
    }

    private func startWatchingForCompletedLogin(
        accountID: UUID,
        previousEmail: String?,
        previousAuthFingerprint: String?
    ) {
        loginWatcherTask?.cancel()
        loginWatcherTask = Task { [weak self] in
            // Poll for up to 3 minutes (90 checks * 2s)
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }

                let snapshot = self.inspectCurrentLiveState(readKeychainSecret: true)
                let hasNewEmail = snapshot.detectedEmail != nil && snapshot.detectedEmail != previousEmail
                let hasNewCredential = snapshot.authFingerprint != nil && snapshot.authFingerprint != previousAuthFingerprint
                let emailJustAppeared = snapshot.detectedEmail != nil

                if (hasNewCredential && emailJustAppeared) || hasNewEmail {
                    if let idx = self.accounts.firstIndex(where: { $0.id == accountID }) {
                        if let detectedEmail = snapshot.detectedEmail {
                            self.accounts[idx].email = detectedEmail
                            if self.accounts[idx].displayName.hasPrefix("Tài khoản") {
                                self.accounts[idx].displayName = snapshot.detectedDisplayName ?? detectedEmail
                            }
                        }
                        if let detectedTier = snapshot.detectedTier {
                            self.accounts[idx].applyTier(detectedTier)
                        }
                        try? self.snapshotActiveAccount(account: self.accounts[idx])
                        self.refreshLiveStateAndUsage(readKeychainSecret: true)
                        self.schedulePostSwitchDashboardSync(for: accountID)
                        self.setTemporaryCompletedState(self.accounts[idx].displayName)
                    }
                    return
                }
            }
        }
    }

    // MARK: - Process Lifecycle Management

    private func terminateAntigravityProcesses() async {
        let targets = matchingRunningAntigravityApps()
        guard !targets.isEmpty else { return }

        for app in targets {
            _ = app.terminate()
        }

        let deadline = Date().addingTimeInterval(AppConfig.gracefulTerminateTimeoutSeconds)
        while Date().timeIntervalSinceReferenceDate < deadline.timeIntervalSinceReferenceDate {
            if matchingRunningAntigravityApps().allSatisfy({ $0.isTerminated }) {
                try? await Task.sleep(nanoseconds: AppConfig.postTerminateFlushNanoseconds)
                return
            }
            try? await Task.sleep(nanoseconds: AppConfig.terminatePollIntervalNanoseconds)
        }

        // Fallback to forceTerminate if Electron hung on an unsaved dialog
        for app in matchingRunningAntigravityApps() where !app.isTerminated {
            _ = app.forceTerminate()
        }
        try? await Task.sleep(nanoseconds: AppConfig.postTerminateFlushNanoseconds)
    }

    private func matchingRunningAntigravityApps() -> [NSRunningApplication] {
        AntigravityProcessMatcher.matchingRunningApps(
            bundlePath: settings.agyAppBundlePath,
            syncIDESession: settings.syncIDESession
        )
    }

    private func relaunchAntigravity() async throws {
        let appURL = URL(fileURLWithPath: settings.agyAppBundlePath)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw NSError(
                domain: "AGYAutoChanger",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy ứng dụng tại \(settings.agyAppBundlePath)"]
            )
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false

        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    /// Terminates any lingering `language_server` helper inside the Antigravity bundle so in-memory OAuth state resets cleanly.
    private func ensureLanguageServerStopped() async {
        let serverBinary = URL(fileURLWithPath: settings.agyAppBundlePath)
            .appendingPathComponent("Contents/Resources/bin/language_server")
            .path

        await Task.detached(priority: .utility) {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-TERM", "-f", serverBinary]
            try? pkill.run()
            pkill.waitUntilExit()
        }.value

        try? await Task.sleep(nanoseconds: AppConfig.postTerminateFlushNanoseconds)
    }
}
