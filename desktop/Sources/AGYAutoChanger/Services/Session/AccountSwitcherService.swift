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
    @Published public var todayOverview: DailyUsageOverview = DailyUsageOverview()
    @Published public var isRefreshingUsage: Bool = false
    @Published public var autoSwitchBanner: AutoSwitchBannerState?
    @Published public var isCLISessionInitialized: Bool = false
    @Published public var isRunningWarmup: Bool = false
    @Published public var warmupStatusMessage: String?
    @Published public var isWarmupPausedByStorageError: Bool = false

    // MARK: - Dependencies

    private let vaultSecurity: VaultSecurityService
    private let keychainFallback: KeychainFallbackService
    private let stateInspector: AGYStateInspectorService
    private let usageTracker: UsageTrackerService
    private let cloudQuotaService: CloudCodeQuotaService
    private let quotaNotifier: QuotaThresholdNotifier
    private let runtimeCoordinator: AGYRuntimeCoordinator
    private let smartAutoSwitch: SmartAutoSwitchService
    private let weeklyWarmup: WeeklyWarmupService

    private var loginWatcherTask: Task<Void, Never>?
    private var statusResetTask: Task<Void, Never>?
    private var postSwitchSyncTask: Task<Void, Never>?
    private var backgroundPollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var idleRecheckTask: Task<Void, Never>?
    private var warmupTask: Task<Void, Never>?
    private var warmupStatusDismissTask: Task<Void, Never>?
    private var autoSwitchState: AutoSwitchRuntimeState = AutoSwitchRuntimeState()
    private var warmupState: WeeklyWarmupRuntimeState = WeeklyWarmupRuntimeState()
    private var warmupFailureCooldowns: [String: Date] = [:]
    private var hasBootstrapped = false
    private var isManagedAGYRestartInProgress = false
    private var isSyncingCLIUsage = false
    private var isEvaluatingAutoSwitch = false

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
        quotaNotifier: QuotaThresholdNotifier? = nil,
        runtimeCoordinator: AGYRuntimeCoordinator = AGYRuntimeCoordinator(),
        smartAutoSwitch: SmartAutoSwitchService = SmartAutoSwitchService(),
        weeklyWarmup: WeeklyWarmupService = WeeklyWarmupService()
    ) {
        self.vaultSecurity = vaultSecurity
        self.keychainFallback = keychainFallback
        self.stateInspector = stateInspector
        self.usageTracker = usageTracker
        self.cloudQuotaService = cloudQuotaService
        self.quotaNotifier = quotaNotifier ?? QuotaThresholdNotifier()
        self.runtimeCoordinator = runtimeCoordinator
        self.smartAutoSwitch = smartAutoSwitch
        self.weeklyWarmup = weeklyWarmup
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
            loadAutoSwitchState()
            loadWeeklyWarmupState()
            isCLISessionInitialized = runtimeCoordinator.isCLIDirectoryInitialized()
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
        refreshTask?.cancel()
        isRefreshingUsage = true

        let activeSnapshot = accounts.first(where: { $0.isActive })
        let activeAccountID = activeSnapshot?.id
        let activeCutoff = activeSnapshot?.lastUsageScanAt ?? activeSnapshot?.lastSwitchedAt
        let rollingWindowHours = settings.rollingWindowHours
        let keychainFallback = self.keychainFallback
        let stateInspector = self.stateInspector
        let usageTracker = self.usageTracker

        refreshTask = Task { [weak self] in
            let scanNow = Date()
            let collected = await Task.detached(priority: .utility) { () -> (
                live: AGYLiveStateSnapshot,
                today: DailyUsageOverview,
                delta: ModelUsageSummary?
            ) in
                let kcMeta = keychainFallback.inspectAuthMetadata(readKeychainSecret: readKeychainSecret)
                let live = stateInspector.inspectLiveState(keychainAuthMetadata: kcMeta)
                let today = usageTracker.scanTodayOverview(referenceDate: scanNow)
                let delta: ModelUsageSummary?
                if activeAccountID != nil {
                    delta = usageTracker.scanUsage(
                        rollingWindowHours: rollingWindowHours,
                        sinceAccountSwitch: activeCutoff,
                        referenceDate: scanNow
                    )
                } else {
                    delta = nil
                }
                return (live, today, delta)
            }.value

            guard !Task.isCancelled, let self else { return }

            self.liveState = collected.live
            self.todayOverview = collected.today

            if let activeIndex = self.accounts.firstIndex(where: { $0.isActive }) {
                // Update email automatically if previously unknown or switched externally
                if let detectedEmail = collected.live.detectedEmail,
                   self.accounts[activeIndex].email.isEmpty
                    || self.accounts[activeIndex].email.contains("Chưa")
                    || self.accounts[activeIndex].email.contains("Đang đăng nhập")
                    || self.accounts[activeIndex].email.contains("Chờ đăng nhập") {
                    self.accounts[activeIndex].email = detectedEmail
                    if self.accounts[activeIndex].displayName.hasPrefix("Tài khoản") || self.accounts[activeIndex].displayName.hasPrefix("Account") {
                        self.accounts[activeIndex].displayName = collected.live.detectedDisplayName ?? detectedEmail
                    }
                }

                if let detectedTier = collected.live.detectedTier,
                   self.accounts[activeIndex].tier != detectedTier {
                    self.accounts[activeIndex].applyTier(detectedTier)
                }

                if let delta = collected.delta,
                   self.accounts[activeIndex].id == activeAccountID {
                    self.accounts[activeIndex].modelUsages = self.usageTracker.mergeIncremental(
                        summary: delta,
                        into: self.accounts[activeIndex].modelUsages,
                        tier: self.accounts[activeIndex].tier
                    )
                    self.accounts[activeIndex].lastUsageScanAt = scanNow
                }

                self.persistAccountsSilently()
                self.evaluateQuotaNotifications()
            }

            await self.syncDashboardQuotasForAllAccounts(useLiveKeychainForActive: readKeychainSecret)
            if !Task.isCancelled {
                self.isRefreshingUsage = false
            }
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
        idleRecheckTask?.cancel()
        warmupTask?.cancel()
        isRunningWarmup = false
        autoSwitchBanner = nil

        isManagedAGYRestartInProgress = true
        defer { isManagedAGYRestartInProgress = false }

        do {
            let targetProfileDir = try vaultSecurity.profileDirectory(for: target.id)
            guard vaultSecurity.hasSnapshot(in: targetProfileDir) else {
                throw VaultSecurityError.snapshotMissing(target.displayName)
            }

            let ideInfo = runtimeCoordinator.detectIDEInstallation()
            let ideUsesSharedCredentials = ideInfo?.usesSharedAppCredentials ?? false
            let shouldManageIDEProcesses = settings.syncIDESession || ideUsesSharedCredentials
            let shouldSnapshotLegacyIDEDB = settings.syncIDESession && !ideUsesSharedCredentials
            let runningIDEBundleURL = shouldManageIDEProcesses ? matchingRunningIDEBundleURL() : nil

            let runtime = self.runtimeCoordinator
            let runningHubs = await Task.detached(priority: .utility) {
                let psTable = runtime.captureRunningProcessTable()
                return runtime.parseStandaloneHubProcesses(from: psTable)
            }.value

            // 1. Flush usage delta and backup outgoing active account before closing Antigravity
            if let activeIdx = accounts.firstIndex(where: { $0.isActive }) {
                switchPhase = .backingUpCurrent(accounts[activeIdx].displayName)
                flushActiveAccountTelemetryBeforeSwitch(at: activeIdx)
                try snapshotActiveAccount(account: accounts[activeIdx], includeLegacyIDE: shouldSnapshotLegacyIDEDB)
            }

            // 2. Gracefully terminate Antigravity (+ IDE 2.6+ if running) + language_server + standalone `agy --hub`
            switchPhase = .terminatingAGY
            await terminateAntigravityProcesses(includeIDE: shouldManageIDEProcesses)
            await ensureLanguageServerStopped()
            await runtimeCoordinator.stopStandaloneHubProcesses(runningHubs)

            // 3. Restore target snapshot atomically (with automatic rollback on failure)
            switchPhase = .restoringSnapshot(target.displayName)
            let fallbackCLIJSON = keychainFallback.extractUnwrappedOAuthJSON(fromProfileDir: targetProfileDir)
            try vaultSecurity.restoreSessionSnapshot(
                from: targetProfileDir,
                accountDisplayName: target.displayName,
                includeIDE: shouldSnapshotLegacyIDEDB,
                includeCLI: settings.syncCLISession,
                fallbackCLIOAuthJSON: fallbackCLIJSON
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

            // 5. Restart standalone `agy --hub` first, then relaunch Antigravity (+ IDE if it was running)
            runtimeCoordinator.relaunchStandaloneHubProcesses(runningHubs)
            if settings.autoRelaunchAGY {
                switchPhase = .relaunchingAGY
                try await relaunchAntigravity()
                if let runningIDEBundleURL {
                    try? await relaunchApplication(at: runningIDEBundleURL, activate: false)
                }
            }

            refreshLiveStateAndUsage(readKeychainSecret: false)
            schedulePostSwitchDashboardSync(for: target.id)
            setTemporaryCompletedState(target.displayName)
        } catch {
            switchPhase = .failed(error.localizedDescription)
        }
    }

    /// Switches only the `agy` CLI session (Keychain + `~/.gemini/antigravity-cli/antigravity-oauth-token` + standalone `agy --hub`)
    /// without closing or relaunching Antigravity.app or Antigravity IDE.
    public func switchCLISessionOnly(to target: AccountProfile) async {
        guard !switchPhase.isInProgress else { return }
        statusResetTask?.cancel()

        do {
            let targetProfileDir = try vaultSecurity.profileDirectory(for: target.id)
            guard vaultSecurity.hasSnapshot(in: targetProfileDir) else {
                throw VaultSecurityError.snapshotMissing(target.displayName)
            }

            let runtime = self.runtimeCoordinator
            let runningHubs = await Task.detached(priority: .utility) {
                let psTable = runtime.captureRunningProcessTable()
                return runtime.parseStandaloneHubProcesses(from: psTable)
            }.value

            switchPhase = .restoringSnapshot("CLI: \(target.displayName)")
            await runtimeCoordinator.stopStandaloneHubProcesses(runningHubs)

            let fallbackCLIJSON = keychainFallback.extractUnwrappedOAuthJSON(fromProfileDir: targetProfileDir)
            _ = try vaultSecurity.restoreCLITokenOnly(
                from: targetProfileDir,
                fallbackOAuthJSON: fallbackCLIJSON
            )
            try keychainFallback.restoreScopedKeychain(
                from: targetProfileDir,
                includeSecondaryServices: false,
                clearPrimaryIfMissing: false
            )

            runtimeCoordinator.relaunchStandaloneHubProcesses(runningHubs)
            setTemporaryCompletedState("CLI → \(target.displayName)")
        } catch {
            switchPhase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Account Capture & Clean Login Flow

    public func captureCurrentSessionAsNewAccount(
        displayName: String,
        email: String,
        tier: AccountTier,
        remark: String = ""
    ) throws {
        // Flush delta & save outgoing active session before reassigning active status
        if let activeIdx = accounts.firstIndex(where: { $0.isActive }) {
            flushActiveAccountTelemetryBeforeSwitch(at: activeIdx)
            try? snapshotActiveAccount(account: accounts[activeIdx])
        }

        liveState = inspectCurrentLiveState(readKeychainSecret: true)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRemark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = trimmedEmail.isEmpty ? (liveState.detectedEmail ?? "Chưa xác định email") : trimmedEmail
        let resolvedName = trimmedName.isEmpty ? (liveState.detectedDisplayName ?? resolvedEmail) : trimmedName
        let resolvedTier = liveState.detectedTier ?? tier

        let captureNow = Date()
        let colorHex = AppConfig.avatarPaletteHex[accounts.count % AppConfig.avatarPaletteHex.count]
        var newAccount = AccountProfile(
            email: resolvedEmail,
            displayName: resolvedName,
            remark: trimmedRemark,
            avatarHex: colorHex,
            tier: resolvedTier,
            isActive: true,
            createdAt: captureNow,
            lastSwitchedAt: nil,
            lastSnapshotAt: captureNow,
            lastUsageScanAt: captureNow
        )

        let profileDir = try vaultSecurity.profileDirectory(for: newAccount.id)
        let ideUsesShared = runtimeCoordinator.detectIDEInstallation()?.usesSharedAppCredentials ?? false
        try vaultSecurity.snapshotCurrentSession(
            to: profileDir,
            includeIDE: settings.syncIDESession && !ideUsesShared,
            includeCLI: settings.syncCLISession
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
        tier: AccountTier,
        remark: String = ""
    ) async {
        guard !switchPhase.isInProgress else { return }
        statusResetTask?.cancel()
        loginWatcherTask?.cancel()

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRemark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Tài khoản \(accounts.count + 1)" : trimmedName
        let resolvedEmail = trimmedEmail.isEmpty ? "Chờ đăng nhập..." : trimmedEmail

        postSwitchSyncTask?.cancel()
        warmupTask?.cancel()
        isRunningWarmup = false

        isManagedAGYRestartInProgress = true
        defer { isManagedAGYRestartInProgress = false }

        do {
            if let activeIdx = accounts.firstIndex(where: { $0.isActive }) {
                switchPhase = .backingUpCurrent(accounts[activeIdx].displayName)
                flushActiveAccountTelemetryBeforeSwitch(at: activeIdx)
                try snapshotActiveAccount(account: accounts[activeIdx])
            }

            let preCleanState = inspectCurrentLiveState(readKeychainSecret: true)

            let runtime = self.runtimeCoordinator
            let runningHubs = await Task.detached(priority: .utility) {
                let psTable = runtime.captureRunningProcessTable()
                return runtime.parseStandaloneHubProcesses(from: psTable)
            }.value

            switchPhase = .terminatingAGY
            await terminateAntigravityProcesses()
            await ensureLanguageServerStopped()
            await runtimeCoordinator.stopStandaloneHubProcesses(runningHubs)

            try vaultSecurity.clearLiveSessionForNewLogin()
            keychainFallback.clearPrimaryAuthKeychain()

            let cleanStartNow = Date()
            let colorHex = AppConfig.avatarPaletteHex[accounts.count % AppConfig.avatarPaletteHex.count]
            let newAccount = AccountProfile(
                email: resolvedEmail,
                displayName: resolvedName,
                remark: trimmedRemark,
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

            let originalCount = warmupState.records.count
            warmupState.records = warmupState.records.filter { $0.value.accountID != account.id }
            if warmupState.records.count != originalCount && !warmupState.pausedDueToStorageError {
                try? vaultSecurity.writeJSON(warmupState, to: AppConfig.weeklyWarmupStateURL)
            }
        } catch {
            switchPhase = .failed(error.localizedDescription)
        }
    }

    public func updateTier(for accountID: UUID, tier: AccountTier) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[idx].applyTier(tier)
        persistAccountsSilently()
    }

    public func updateRemark(for accountID: UUID, remark: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[idx].remark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        persistAccountsSilently()
    }

    public func toggleAccountDisabled(for accountID: UUID) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[idx].isDisabled.toggle()
        persistAccountsSilently()
    }

    public func moveAccount(from sourceID: UUID, to targetID: UUID) {
        guard sourceID != targetID,
              let fromIndex = accounts.firstIndex(where: { $0.id == sourceID }),
              let toIndex = accounts.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        let item = accounts.remove(at: fromIndex)
        accounts.insert(item, at: toIndex)
        persistAccountsSilently()
    }

    public func moveAccount(at index: Int, direction: Int) {
        let targetIndex = index + direction
        guard accounts.indices.contains(index),
              accounts.indices.contains(targetIndex),
              index != targetIndex else {
            return
        }
        let item = accounts.remove(at: index)
        accounts.insert(item, at: targetIndex)
        persistAccountsSilently()
    }

    // MARK: - Portable JSON Export / Import & Token Seeding

    public func exportAccountsJSONData(onlyAccountID: UUID? = nil) throws -> Data {
        let targetAccounts = onlyAccountID.map { id in accounts.filter { $0.id == id } } ?? accounts
        let records: [PortableAccountRecord] = targetAccounts.map { account in
            let profileDir = try? vaultSecurity.profileDirectory(for: account.id)
            let refreshToken = profileDir.flatMap { keychainFallback.extractRefreshToken(fromProfileDir: $0) }
            let rawSecret = profileDir.flatMap { keychainFallback.extractPrimaryKeyringSecretBase64(fromProfileDir: $0) }
            return PortableAccountRecord(
                id: account.id,
                email: account.email,
                displayName: account.displayName,
                remark: account.remark,
                tier: account.tier,
                isDisabled: account.isDisabled,
                refreshToken: refreshToken,
                rawKeyringSecretBase64: rawSecret
            )
        }
        let bundle = PortableAccountExportBundle(schemaVersion: 2, exportedAt: Date(), accounts: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    public func saveProtectedExportData(_ data: Data, to url: URL) throws {
        try vaultSecurity.writeProtectedData(data, to: url)
    }

    @discardableResult
    public func importAccounts(fromJSONData data: Data, triggerQuotaSync: Bool = true) throws -> Int {
        struct LegacySwitchEntry: Decodable {
            let id: UUID?
            let email: String?
            let name: String?
            let displayName: String?
            let remark: String?
            let tier: String?
            let refresh_token: String?
            let refreshToken: String?
            let rawKeyringSecretBase64: String?
            let isDisabled: Bool?
            let is_disabled: Bool?
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let records: [PortableAccountRecord]
        if let bundle = try? decoder.decode(PortableAccountExportBundle.self, from: data) {
            records = bundle.accounts
        } else if let legacyList = try? decoder.decode([LegacySwitchEntry].self, from: data) {
            records = legacyList.compactMap { entry in
                let email = (entry.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let token = (entry.refreshToken ?? entry.refresh_token)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !email.isEmpty || (token?.isEmpty == false) else { return nil }
                let resolvedTier = AccountTier.from(serverTier: entry.tier) ?? .pro
                let resolvedName = (entry.displayName ?? entry.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return PortableAccountRecord(
                    id: entry.id ?? UUID(),
                    email: email,
                    displayName: resolvedName.isEmpty ? (email.split(separator: "@").first.map(String.init) ?? "Tài khoản") : resolvedName,
                    remark: (entry.remark ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    tier: resolvedTier,
                    isDisabled: entry.isDisabled ?? entry.is_disabled ?? false,
                    refreshToken: token,
                    rawKeyringSecretBase64: entry.rawKeyringSecretBase64
                )
            }
        } else if let single = try? decoder.decode(LegacySwitchEntry.self, from: data) {
            let email = (single.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let token = (single.refreshToken ?? single.refresh_token)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty || (token?.isEmpty == false) {
                let resolvedTier = AccountTier.from(serverTier: single.tier) ?? .pro
                let resolvedName = (single.displayName ?? single.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                records = [
                    PortableAccountRecord(
                        id: single.id ?? UUID(),
                        email: email,
                        displayName: resolvedName.isEmpty ? (email.split(separator: "@").first.map(String.init) ?? "Tài khoản") : resolvedName,
                        remark: (single.remark ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        tier: resolvedTier,
                        isDisabled: single.isDisabled ?? single.is_disabled ?? false,
                        refreshToken: token,
                        rawKeyringSecretBase64: single.rawKeyringSecretBase64
                    )
                ]
            } else {
                records = []
            }
        } else {
            records = []
        }

        var importedCount = 0
        for record in records {
            let normalizedEmail = record.email.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedToken = record.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedRaw = record.rawKeyringSecretBase64?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedEmail.isEmpty || (trimmedToken?.isEmpty == false) || (trimmedRaw?.isEmpty == false) else {
                continue
            }

            if !normalizedEmail.isEmpty,
               let existingIdx = accounts.firstIndex(where: { $0.email.caseInsensitiveCompare(normalizedEmail) == .orderedSame }) {
                if !record.remark.isEmpty {
                    accounts[existingIdx].remark = record.remark
                }
                if (trimmedToken?.isEmpty == false) || (trimmedRaw?.isEmpty == false) {
                    let profileDir = try vaultSecurity.profileDirectory(for: accounts[existingIdx].id)
                    let seeded = try keychainFallback.seedProfileCredentials(
                        to: profileDir,
                        email: accounts[existingIdx].email,
                        tier: accounts[existingIdx].tier,
                        refreshToken: trimmedToken,
                        rawKeyringSecretBase64: trimmedRaw
                    )
                    if seeded {
                        accounts[existingIdx].hasKeychainBackup = true
                        accounts[existingIdx].lastSnapshotAt = Date()
                    }
                }
                importedCount += 1
            } else {
                let accountID = accounts.contains(where: { $0.id == record.id }) ? UUID() : record.id
                let resolvedEmail = normalizedEmail.isEmpty ? "Chờ xác thực email..." : normalizedEmail
                let trimmedDisplay = record.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedName = trimmedDisplay.isEmpty
                    ? (resolvedEmail.split(separator: "@").first.map(String.init) ?? "Tài khoản \(accounts.count + 1)")
                    : trimmedDisplay
                let colorHex = AppConfig.avatarPaletteHex[accounts.count % AppConfig.avatarPaletteHex.count]

                let profileDir = try vaultSecurity.profileDirectory(for: accountID)
                let seeded = try keychainFallback.seedProfileCredentials(
                    to: profileDir,
                    email: resolvedEmail,
                    tier: record.tier,
                    refreshToken: trimmedToken,
                    rawKeyringSecretBase64: trimmedRaw
                )

                let newAccount = AccountProfile(
                    id: accountID,
                    email: resolvedEmail,
                    displayName: resolvedName,
                    remark: record.remark,
                    avatarHex: colorHex,
                    tier: record.tier,
                    isActive: false,
                    isDisabled: record.isDisabled,
                    createdAt: Date(),
                    lastSnapshotAt: seeded ? Date() : nil,
                    hasKeychainBackup: seeded
                )
                accounts.append(newAccount)
                importedCount += 1
            }
        }

        guard importedCount > 0 else {
            throw NSError(
                domain: "AGYAutoChanger",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy tài khoản hợp lệ trong dữ liệu JSON."]
            )
        }

        try vaultSecurity.writeJSON(accounts, to: AppConfig.accountsMetadataURL)
        setTemporaryCompletedState("Đã nhập \(importedCount) tài khoản")
        if triggerQuotaSync {
            Task { [weak self] in
                await self?.syncDashboardQuotasForAllAccounts(useLiveKeychainForActive: false)
            }
        }
        return importedCount
    }

    @discardableResult
    public func addAccountWithTokenOrJSON(
        displayName: String,
        email: String,
        tier: AccountTier,
        remark: String,
        rawInput: String,
        triggerQuotaSync: Bool = true
    ) throws -> Int {
        let trimmedInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            throw NSError(
                domain: "AGYAutoChanger",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Vui lòng dán Refresh Token hoặc nội dung JSON."]
            )
        }

        if trimmedInput.hasPrefix("{") || trimmedInput.hasPrefix("[") {
            return try importAccounts(fromJSONData: Data(trimmedInput.utf8), triggerQuotaSync: triggerQuotaSync)
        }

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRemark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = trimmedEmail.isEmpty ? "Chờ xác thực email..." : trimmedEmail
        let resolvedName = trimmedName.isEmpty
            ? (trimmedEmail.isEmpty ? "Acc Token \(accounts.count + 1)" : (trimmedEmail.split(separator: "@").first.map(String.init) ?? trimmedEmail))
            : trimmedName

        let newID = UUID()
        let colorHex = AppConfig.avatarPaletteHex[accounts.count % AppConfig.avatarPaletteHex.count]
        let profileDir = try vaultSecurity.profileDirectory(for: newID)
        let seeded = try keychainFallback.seedProfileCredentials(
            to: profileDir,
            email: resolvedEmail,
            tier: tier,
            refreshToken: trimmedInput,
            rawKeyringSecretBase64: nil
        )

        let newAccount = AccountProfile(
            id: newID,
            email: resolvedEmail,
            displayName: resolvedName,
            remark: trimmedRemark,
            avatarHex: colorHex,
            tier: tier,
            isActive: false,
            isDisabled: false,
            createdAt: Date(),
            lastSnapshotAt: seeded ? Date() : nil,
            hasKeychainBackup: seeded
        )
        accounts.append(newAccount)
        try vaultSecurity.writeJSON(accounts, to: AppConfig.accountsMetadataURL)
        setTemporaryCompletedState("Đã nạp \(resolvedName)")

        if triggerQuotaSync {
            Task { [weak self] in
                await self?.syncDashboardQuotasForAllAccounts(useLiveKeychainForActive: false)
            }
        }
        return 1
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
        sanitized.autoSwitchPolicy.triggerThresholdPercent = min(50, max(5, sanitized.autoSwitchPolicy.triggerThresholdPercent))
        sanitized.autoSwitchPolicy.minBackupQuotaPercent = min(
            95,
            max(max(15, sanitized.autoSwitchPolicy.triggerThresholdPercent + 5), sanitized.autoSwitchPolicy.minBackupQuotaPercent)
        )
        if sanitized.autoSwitchPolicy.isEnabled && sanitized.autoSwitchPolicy.monitoredBucketIDs.isEmpty {
            sanitized.autoSwitchPolicy.monitoredBucketIDs = AutoSwitchPolicy.defaultBucketIDs(for: sanitized.autoSwitchPolicy.modelScope)
        }
        sanitized.weeklyWarmupPolicy.fiveHourStartHour = min(23, max(0, sanitized.weeklyWarmupPolicy.fiveHourStartHour))
        sanitized.weeklyWarmupPolicy.fiveHourEndHour = min(23, max(0, sanitized.weeklyWarmupPolicy.fiveHourEndHour))
        let warmupPolicyChanged = (sanitized.weeklyWarmupPolicy != settings.weeklyWarmupPolicy)
        settings = sanitized
        try? vaultSecurity.writeJSON(settings, to: AppConfig.settingsMetadataURL)
        lifecycleService.syncWatcherRegistration(enabled: settings.bindLifecycleWithAGY)

        // Saving settings resets prior auto-switch cancellations and failure pauses.
        autoSwitchState.cancelledSourceAccountIDs.removeAll()
        autoSwitchState.pausedDueToFailure = false
        autoSwitchState.lastFailureReason = nil
        autoSwitchState.inProgressTargetAccountID = nil
        persistAutoSwitchStateSilently()
        autoSwitchBanner = nil
        idleRecheckTask?.cancel()

        if warmupPolicyChanged {
            warmupTask?.cancel()
            isRunningWarmup = false
        }

        if settings.enableLowQuotaNotification {
            quotaNotifier.requestAuthorizationIfNeeded()
            evaluateQuotaNotifications()
        }
        refreshLiveStateAndUsage()
    }

    // MARK: - Weekly Quota Warmup User Controls

    public func runManualWeeklyWarmup(onlyAccountID: UUID? = nil) {
        warmupStatusDismissTask?.cancel()
        guard !switchPhase.isInProgress else {
            warmupStatusMessage = "Đang chuyển tài khoản, vui lòng chờ hoàn tất rồi chạy Warmup."
            scheduleWarmupStatusAutoDismiss(seconds: 5)
            return
        }
        guard !isRunningWarmup else { return }
        if warmupState.pausedDueToStorageError {
            isWarmupPausedByStorageError = true
            warmupStatusMessage = warmupState.lastError ?? "Weekly Warmup đang tạm dừng do lỗi lưu lịch sử."
            return
        }
        guard !settings.weeklyWarmupPolicy.enabledGroups.isEmpty else {
            warmupStatusMessage = "Hãy bật ít nhất 1 nhóm (Gemini hoặc Claude/GPT) trong Cài đặt Weekly Warmup."
            scheduleWarmupStatusAutoDismiss(seconds: 5)
            return
        }
        startWeeklyWarmupRun(manual: true, onlyAccountID: onlyAccountID)
    }

    public func cancelWeeklyWarmup() {
        warmupTask?.cancel()
        warmupTask = nil
        isRunningWarmup = false
        warmupStatusMessage = "Đã hủy tiến trình Weekly Warmup."
        scheduleWarmupStatusAutoDismiss(seconds: 4)
    }

    public func dismissWarmupStatus() {
        warmupStatusDismissTask?.cancel()
        warmupStatusMessage = nil
    }

    public func resetWarmupStorageError() {
        warmupState.pausedDueToStorageError = false
        warmupState.lastError = nil
        do {
            try vaultSecurity.writeJSON(warmupState, to: AppConfig.weeklyWarmupStateURL)
            isWarmupPausedByStorageError = false
            warmupStatusMessage = "Đã khôi phục lưu lịch sử Weekly Warmup."
            scheduleWarmupStatusAutoDismiss(seconds: 4)
        } catch {
            warmupState.pausedDueToStorageError = true
            warmupState.lastError = "Vẫn lỗi khi ghi ~/.agy-switcher/weekly_warmup_state.json: \(error.localizedDescription)"
            isWarmupPausedByStorageError = true
            warmupStatusMessage = warmupState.lastError
        }
    }

    // MARK: - Smart Auto-Switch User Controls

    public func cancelPendingAutoSwitch() {
        idleRecheckTask?.cancel()
        if let activeID = accounts.first(where: { $0.isActive })?.id {
            autoSwitchState.cancelledSourceAccountIDs.insert(activeID)
            persistAutoSwitchStateSilently()
        }
        autoSwitchBanner = nil
    }

    public func resumeAutoSwitchAfterFailure() {
        autoSwitchState.pausedDueToFailure = false
        autoSwitchState.lastFailureReason = nil
        autoSwitchState.inProgressTargetAccountID = nil
        persistAutoSwitchStateSilently()
        autoSwitchBanner = nil
        Task { [weak self] in
            await self?.evaluateSmartAutoSwitch()
        }
    }

    public func dismissAutoSwitchBanner() {
        autoSwitchBanner = nil
    }

    public func switchNowFromAutoSwitchBanner(_ target: AccountProfile) {
        idleRecheckTask?.cancel()
        autoSwitchBanner = nil
        Task { [weak self] in
            await self?.switchToAccount(target)
        }
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

    private func snapshotActiveAccount(account: AccountProfile, includeLegacyIDE: Bool? = nil) throws {
        let profileDir = try vaultSecurity.profileDirectory(for: account.id)
        let shouldSnapshotIDE: Bool
        if let includeLegacyIDE {
            shouldSnapshotIDE = includeLegacyIDE
        } else {
            let ideUsesShared = runtimeCoordinator.detectIDEInstallation()?.usesSharedAppCredentials ?? false
            shouldSnapshotIDE = settings.syncIDESession && !ideUsesShared
        }
        try vaultSecurity.snapshotCurrentSession(
            to: profileDir,
            includeIDE: shouldSnapshotIDE,
            includeCLI: settings.syncCLISession
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

    private func flushActiveAccountTelemetryBeforeSwitch(at index: Int) {
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
        let syncResult = await syncDashboardQuotas(
            forAccountIDs: nil,
            useLiveKeychainForActive: useLiveKeychainForActive
        )

        if syncResult.didUpdateAny {
            persistAccountsSilently()
            evaluateQuotaNotifications()
            await evaluateSmartAutoSwitch()
            if settings.weeklyWarmupPolicy.isEnabled,
               !isRunningWarmup,
               !switchPhase.isInProgress,
               !warmupState.pausedDueToStorageError {
                startWeeklyWarmupRun(manual: false, onlyAccountID: nil)
            }
            // Only query `agy -p /usage` for dedicated Argon quota when the active account's REST sync
            // just succeeded (proving network & OAuth are healthy, preventing offline OAuth browser popups).
            if syncResult.activeAccountUpdated && CloudCodeQuotaService.isAgyCLIAvailable && !isSyncingCLIUsage {
                Task { [weak self] in
                    await self?.syncActiveAccountCLIUsageIfAvailable()
                }
            }
        }
    }

    private func syncDashboardQuotas(
        forAccountIDs targetIDs: Set<UUID>?,
        useLiveKeychainForActive: Bool
    ) async -> (didUpdateAny: Bool, activeAccountUpdated: Bool) {
        var didUpdateAny = false
        var activeAccountUpdated = false
        let orderedAccountIDs = accounts.map(\.id).filter { targetIDs?.contains($0) ?? true }

        for accountID in orderedAccountIDs {
            if Task.isCancelled { break }
            guard let account = accounts.first(where: { $0.id == accountID }) else { continue }
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
            ), let currentIdx = accounts.firstIndex(where: { $0.id == accountID }) {
                let applied = cloudQuotaService.applyDashboardSnapshot(
                    snapshot,
                    into: accounts[currentIdx].modelUsages,
                    currentTier: accounts[currentIdx].tier
                )
                accounts[currentIdx].tier = applied.tier
                accounts[currentIdx].modelUsages = applied.usages
                accounts[currentIdx].lastDashboardSyncAt = snapshot.syncedAt
                didUpdateAny = true
                if accounts[currentIdx].isActive {
                    activeAccountUpdated = true
                }
            }
        }

        return (didUpdateAny, activeAccountUpdated)
    }

    private func startWeeklyWarmupRun(manual: Bool, onlyAccountID: UUID?) {
        warmupStatusDismissTask?.cancel()
        let now = Date()
        let prunedState = weeklyWarmup.pruneExpiredHistory(in: warmupState, referenceDate: now)
        if prunedState != warmupState && !prunedState.pausedDueToStorageError {
            warmupState = prunedState
            try? vaultSecurity.writeJSON(warmupState, to: AppConfig.weeklyWarmupStateURL)
        }

        let candidates = weeklyWarmup.findEligibleCandidates(
            accounts: accounts,
            policy: settings.weeklyWarmupPolicy,
            state: warmupState,
            onlyAccountID: onlyAccountID,
            ignoreAutoEnabledFlag: manual,
            ignoreBackupOnlyFilter: onlyAccountID != nil,
            hasSnapshot: { [weak self] account in
                self?.hasValidSnapshot(for: account) ?? false
            },
            failureCooldowns: manual ? [:] : warmupFailureCooldowns,
            referenceDate: now
        )

        guard !candidates.isEmpty else {
            if manual {
                warmupStatusMessage = weeklyWarmup.explainNoEligibleCandidates(
                    accounts: accounts,
                    policy: settings.weeklyWarmupPolicy,
                    onlyAccountID: onlyAccountID,
                    hasSnapshot: { [weak self] account in
                        self?.hasValidSnapshot(for: account) ?? false
                    },
                    referenceDate: now
                )
                scheduleWarmupStatusAutoDismiss(seconds: 6)
            }
            return
        }

        isRunningWarmup = true
        warmupTask?.cancel()
        warmupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRunningWarmup = false
                self.warmupTask = nil
            }

            var tokenCache: [UUID: String] = [:]
            var catalogCache: [UUID: (projectID: String, models: [AdvertisedModelEntry])] = [:]
            var warmedAccountIDs: Set<UUID> = []
            var needsPostSyncAccountIDs: Set<UUID> = []
            var succeededCount = 0
            var failedCount = 0
            var skippedCount = 0
            var lastFailureDetail: String?
            var haltedByStorageError = false

            for (index, candidate) in candidates.enumerated() {
                if Task.isCancelled || self.switchPhase.isInProgress {
                    return
                }

                self.warmupStatusMessage = "Warmup (\(index + 1)/\(candidates.count)): \(candidate.accountName) · \(candidate.displayTitle)..."

                let token: String
                if let cachedToken = tokenCache[candidate.accountID] {
                    token = cachedToken
                } else {
                    let profileDir = try? self.vaultSecurity.profileDirectory(for: candidate.accountID)
                    guard let resolvedToken = await self.keychainFallback.resolveOrRefreshBearerToken(
                        fromProfileDir: profileDir,
                        useLiveKeychain: false
                    ) else {
                        failedCount += 1
                        lastFailureDetail = "Không lấy được OAuth token hợp lệ cho \(candidate.accountName)."
                        self.warmupFailureCooldowns[candidate.cycleKey] = Date().addingTimeInterval(
                            AppConfig.weeklyWarmupFailureRetryCooldownSeconds
                        )
                        continue
                    }
                    tokenCache[candidate.accountID] = resolvedToken
                    token = resolvedToken
                }

                if Task.isCancelled || self.switchPhase.isInProgress {
                    return
                }

                let catalog: (projectID: String, models: [AdvertisedModelEntry])
                if let cachedCatalog = catalogCache[candidate.accountID] {
                    catalog = cachedCatalog
                } else {
                    guard let fetchedCatalog = await self.cloudQuotaService.fetchAdvertisedModelsAndProject(
                        bearerToken: token
                    ) else {
                        failedCount += 1
                        lastFailureDetail = "Không thể tải danh sách model được mở cho \(candidate.accountName)."
                        self.warmupFailureCooldowns[candidate.cycleKey] = Date().addingTimeInterval(
                            AppConfig.weeklyWarmupFailureRetryCooldownSeconds
                        )
                        continue
                    }
                    catalogCache[candidate.accountID] = fetchedCatalog
                    catalog = fetchedCatalog
                }

                let modelCandidates = CloudCodeQuotaService.selectWarmupModelCandidates(
                    for: candidate.group,
                    groupMembersHint: candidate.groupMembersHint,
                    from: catalog.models
                )
                guard !modelCandidates.isEmpty else {
                    skippedCount += 1
                    continue
                }

                var didStartCycle = false
                var succeededModelID: String?
                var lastTriedModelID: String?
                var attemptFailed = false

                for modelID in modelCandidates.prefix(2) {
                    if Task.isCancelled || self.switchPhase.isInProgress {
                        return
                    }
                    lastTriedModelID = modelID

                    do {
                        try await self.cloudQuotaService.sendMinimalWarmupRequest(
                            bearerToken: token,
                            projectID: catalog.projectID,
                            modelID: modelID
                        )

                        try await Task.sleep(nanoseconds: 1_200_000_000)
                        if Task.isCancelled || self.switchPhase.isInProgress {
                            return
                        }

                        if let verifiedSnapshot = await self.cloudQuotaService.fetchDashboardSnapshot(
                            bearerToken: token,
                            allowCLIUsage: false
                        ), let accIdx = self.accounts.firstIndex(where: { $0.id == candidate.accountID }) {
                            let applied = self.cloudQuotaService.applyDashboardSnapshot(
                                verifiedSnapshot,
                                into: self.accounts[accIdx].modelUsages,
                                currentTier: self.accounts[accIdx].tier
                            )
                            self.accounts[accIdx].tier = applied.tier
                            self.accounts[accIdx].modelUsages = applied.usages
                            self.accounts[accIdx].lastDashboardSyncAt = verifiedSnapshot.syncedAt

                            let updatedBucket = applied.usages.first(where: { $0.id == candidate.bucketID })
                            let started = updatedBucket.map {
                                !$0.hasUnstartedResetPlaceholder() || ($0.quotaRemainingFraction ?? 1.0) < 0.9999999
                            } ?? false

                            if started {
                                didStartCycle = true
                                succeededModelID = modelID
                                break
                            }
                        } else {
                            // Server accepted and returned valid candidates; transient quota check failure -> accept and retry quota sync after loop.
                            didStartCycle = true
                            succeededModelID = modelID
                            needsPostSyncAccountIDs.insert(candidate.accountID)
                            break
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        attemptFailed = true
                        failedCount += 1
                        lastFailureDetail = error.localizedDescription
                        self.warmupFailureCooldowns[candidate.cycleKey] = Date().addingTimeInterval(
                            AppConfig.weeklyWarmupFailureRetryCooldownSeconds
                        )
                        break
                    }
                }

                if didStartCycle, let confirmedModelID = succeededModelID {
                    let updatedState = self.weeklyWarmup.recordSuccess(
                        for: candidate,
                        modelID: confirmedModelID,
                        into: self.warmupState
                    )
                    self.warmupState = updatedState
                    self.warmupFailureCooldowns.removeValue(forKey: candidate.cycleKey)
                    warmedAccountIDs.insert(candidate.accountID)
                    succeededCount += 1

                    do {
                        try self.vaultSecurity.writeJSON(updatedState, to: AppConfig.weeklyWarmupStateURL)
                    } catch {
                        // Safety guard: provider already accepted the warmup; halt queue so we never repeat it.
                        self.warmupState.pausedDueToStorageError = true
                        self.warmupState.lastError = "Đã gửi warmup cho \(candidate.accountName) nhưng lỗi lưu lịch sử (\(error.localizedDescription)). Đã tạm dừng để tránh gửi trùng."
                        self.isWarmupPausedByStorageError = true
                        self.warmupStatusMessage = self.warmupState.lastError
                        haltedByStorageError = true
                        break
                    }
                } else if !attemptFailed {
                    // None of the tried models started the 7-day clock; clear any stale idle record so it is not locked out.
                    if self.warmupState.records.removeValue(forKey: candidate.cycleKey) != nil,
                       !self.warmupState.pausedDueToStorageError {
                        try? self.vaultSecurity.writeJSON(self.warmupState, to: AppConfig.weeklyWarmupStateURL)
                    }
                    failedCount += 1
                    let triedLabel = lastTriedModelID ?? candidate.displayTitle
                    lastFailureDetail = "Model \(triedLabel) không kích hoạt được đồng hồ chu kỳ"
                    self.warmupFailureCooldowns[candidate.cycleKey] = Date().addingTimeInterval(
                        AppConfig.weeklyWarmupFailureRetryCooldownSeconds
                    )
                }

                if index < candidates.count - 1 {
                    do {
                        try await Task.sleep(nanoseconds: AppConfig.weeklyWarmupPacingNanoseconds)
                    } catch {
                        return
                    }
                }
            }

            if Task.isCancelled {
                return
            }

            if !warmedAccountIDs.isEmpty {
                if !needsPostSyncAccountIDs.isEmpty {
                    if !haltedByStorageError {
                        self.warmupStatusMessage = "Đang đồng bộ lại chu kỳ reset sau Warmup..."
                    }
                    _ = await self.syncDashboardQuotas(
                        forAccountIDs: needsPostSyncAccountIDs,
                        useLiveKeychainForActive: false
                    )
                }
                self.persistAccountsSilently()
                self.evaluateQuotaNotifications()
            }

            if haltedByStorageError {
                return
            }

            if succeededCount > 0 && failedCount == 0 {
                self.warmupStatusMessage = "Đã kích hoạt chu kỳ cho \(succeededCount) bucket (\(warmedAccountIDs.count) tài khoản)."
                self.scheduleWarmupStatusAutoDismiss(seconds: 6)
            } else if succeededCount > 0 && failedCount > 0 {
                self.warmupStatusMessage = "Warmup xong: \(succeededCount) thành công, \(failedCount) lỗi (\(lastFailureDetail ?? ""))."
            } else if failedCount > 0 {
                self.warmupStatusMessage = "Warmup thất bại (\(failedCount) lỗi): \(lastFailureDetail ?? "Không rõ nguyên nhân")"
            } else if skippedCount > 0 && manual {
                self.warmupStatusMessage = "Không có model phù hợp được mở cho các bucket đã chọn."
                self.scheduleWarmupStatusAutoDismiss(seconds: 5)
            } else {
                self.warmupStatusMessage = nil
            }
        }
    }

    private func loadWeeklyWarmupState() {
        guard FileManager.default.fileExists(atPath: AppConfig.weeklyWarmupStateURL.path) else {
            warmupState = WeeklyWarmupRuntimeState()
            isWarmupPausedByStorageError = false
            return
        }
        do {
            let loaded = try vaultSecurity.readJSON(
                WeeklyWarmupRuntimeState.self,
                from: AppConfig.weeklyWarmupStateURL
            )
            let pruned = weeklyWarmup.pruneExpiredHistory(in: loaded)
            warmupState = pruned
            isWarmupPausedByStorageError = pruned.pausedDueToStorageError
            if pruned.pausedDueToStorageError && settings.weeklyWarmupPolicy.isEnabled {
                warmupStatusMessage = pruned.lastError ?? "Weekly Warmup đang tạm dừng do lỗi lưu lịch sử."
            }
            if pruned.records.count != loaded.records.count && !pruned.pausedDueToStorageError {
                try? vaultSecurity.writeJSON(pruned, to: AppConfig.weeklyWarmupStateURL)
            }
        } catch {
            warmupState = WeeklyWarmupRuntimeState(
                records: [:],
                pausedDueToStorageError: true,
                lastError: "Không thể đọc ~/.agy-switcher/weekly_warmup_state.json. Weekly Warmup đã tạm dừng để tránh gửi trùng request."
            )
            isWarmupPausedByStorageError = true
            if settings.weeklyWarmupPolicy.isEnabled {
                warmupStatusMessage = warmupState.lastError
            }
        }
    }

    private func scheduleWarmupStatusAutoDismiss(seconds: UInt64) {
        warmupStatusDismissTask?.cancel()
        warmupStatusDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.isRunningWarmup, !self.isWarmupPausedByStorageError else {
                return
            }
            self.warmupStatusMessage = nil
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
            currentTier: accounts[activeIdx].tier,
            pruneUnreportedExtraBuckets: cliQuotas.count >= 2
        )
        accounts[activeIdx].tier = applied.tier
        accounts[activeIdx].modelUsages = applied.usages
        accounts[activeIdx].lastDashboardSyncAt = cliSnapshot.syncedAt
        persistAccountsSilently()
        evaluateQuotaNotifications()
        await evaluateSmartAutoSwitch()
    }

    private func evaluateQuotaNotifications() {
        quotaNotifier.evaluateAndNotify(
            for: accounts,
            isEnabled: settings.enableLowQuotaNotification,
            thresholdPercent: settings.lowQuotaThresholdPercent
        )
    }

    private func evaluateSmartAutoSwitch() async {
        guard !isEvaluatingAutoSwitch, !switchPhase.isInProgress else { return }
        guard settings.autoSwitchPolicy.isEnabled else {
            autoSwitchBanner = nil
            idleRecheckTask?.cancel()
            return
        }

        isEvaluatingAutoSwitch = true
        defer { isEvaluatingAutoSwitch = false }

        let runtime = self.runtimeCoordinator
        let activityState: AGYActivityState
        if settings.autoSwitchPolicy.timingMode == .waitForIdle {
            activityState = await Task.detached(priority: .utility) {
                runtime.inspectActivityState()
            }.value
        } else {
            activityState = .idle
        }

        guard !switchPhase.isInProgress else { return }

        let result = smartAutoSwitch.evaluate(
            accounts: accounts,
            policy: settings.autoSwitchPolicy,
            state: autoSwitchState,
            activityState: activityState,
            hasSnapshot: { [weak self] account in
                self?.hasValidSnapshot(for: account) ?? false
            }
        )

        if result.updatedState != autoSwitchState {
            autoSwitchState = result.updatedState
            persistAutoSwitchStateSilently()
        }

        switch result.decision {
        case .none, .suppressedByCancellation:
            autoSwitchBanner = nil
            idleRecheckTask?.cancel()
        case .pausedByFailure(let reason):
            autoSwitchBanner = .pausedByFailure(reason: reason)
            idleRecheckTask?.cancel()
        case .noEligibleBackup(let source, let label, let remaining):
            autoSwitchBanner = .noEligibleBackup(
                sourceID: source.id,
                triggeredModelLabel: label,
                remainingPercent: remaining,
                minBackupPercent: settings.autoSwitchPolicy.minBackupQuotaPercent
            )
            idleRecheckTask?.cancel()
        case .waitingForIdle(let source, let target, let label, let remaining, let busyReason):
            autoSwitchBanner = .waitingForIdle(
                sourceID: source.id,
                target: target,
                triggeredModelLabel: label,
                remainingPercent: remaining,
                busyReason: busyReason
            )
            scheduleIdleRecheck()
        case .readyToSwitch(_, let target, _, _):
            idleRecheckTask?.cancel()
            autoSwitchBanner = nil
            autoSwitchState.inProgressTargetAccountID = target.id
            persistAutoSwitchStateSilently()

            await switchToAccount(target)

            if case .failed(let reason) = switchPhase {
                autoSwitchState.inProgressTargetAccountID = nil
                autoSwitchState.pausedDueToFailure = true
                autoSwitchState.lastFailureReason = reason
                persistAutoSwitchStateSilently()
                autoSwitchBanner = .pausedByFailure(reason: reason)
            } else {
                autoSwitchState.inProgressTargetAccountID = nil
                autoSwitchState.lastAutoSwitchedAccountID = target.id
                persistAutoSwitchStateSilently()
            }
        }
    }

    private func scheduleIdleRecheck() {
        idleRecheckTask?.cancel()
        idleRecheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppConfig.autoSwitchIdleRecheckIntervalNanoseconds)
            guard !Task.isCancelled, let self else { return }
            await self.evaluateSmartAutoSwitch()
        }
    }

    private func loadAutoSwitchState() {
        guard FileManager.default.fileExists(atPath: AppConfig.autoSwitchStateURL.path),
              var loaded = try? vaultSecurity.readJSON(AutoSwitchRuntimeState.self, from: AppConfig.autoSwitchStateURL) else {
            autoSwitchState = AutoSwitchRuntimeState()
            return
        }
        // Journal crash guard: if a previous auto-switch crashed mid-commit, pause rather than loop unattended.
        if loaded.inProgressTargetAccountID != nil {
            loaded.inProgressTargetAccountID = nil
            loaded.pausedDueToFailure = true
            loaded.lastFailureReason = "Lần tự động chuyển trước bị gián đoạn giữa chừng. Hãy kiểm tra tài khoản rồi bật lại."
            try? vaultSecurity.writeJSON(loaded, to: AppConfig.autoSwitchStateURL)
            if settings.autoSwitchPolicy.isEnabled {
                autoSwitchBanner = .pausedByFailure(reason: loaded.lastFailureReason ?? "")
            }
        } else if loaded.pausedDueToFailure && settings.autoSwitchPolicy.isEnabled {
            autoSwitchBanner = .pausedByFailure(reason: loaded.lastFailureReason ?? "Tự động chuyển đang tạm dừng do lỗi.")
        }
        autoSwitchState = loaded
    }

    private func persistAutoSwitchStateSilently() {
        try? vaultSecurity.writeJSON(autoSwitchState, to: AppConfig.autoSwitchStateURL)
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
        let coreIDSet = Set(canonicalIDs)
        var didMigrate = false
        for idx in loaded.indices {
            let existingBaseIDs = loaded[idx].modelUsages.filter { coreIDSet.contains($0.id) }.map(\.id)
            let extraObserved = loaded[idx].modelUsages.filter { !coreIDSet.contains($0.id) && $0.hasDashboardQuota }
            if existingBaseIDs != canonicalIDs || loaded[idx].modelUsages.contains(where: { !coreIDSet.contains($0.id) && !$0.hasDashboardQuota }) {
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
                        migrated[mIdx].groupMembersHint = existingMatch.groupMembersHint
                    }
                }
                for extra in extraObserved where !migrated.contains(where: { $0.id == extra.id }) {
                    migrated.append(extra)
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

    private func terminateAntigravityProcesses(includeIDE: Bool? = nil) async {
        let shouldIncludeIDE = includeIDE ?? settings.syncIDESession
        let targets = matchingRunningAntigravityApps(includeIDE: shouldIncludeIDE)
        guard !targets.isEmpty else { return }

        for app in targets {
            _ = app.terminate()
        }

        let deadline = Date().addingTimeInterval(AppConfig.gracefulTerminateTimeoutSeconds)
        while Date().timeIntervalSinceReferenceDate < deadline.timeIntervalSinceReferenceDate {
            if matchingRunningAntigravityApps(includeIDE: shouldIncludeIDE).allSatisfy({ $0.isTerminated }) {
                try? await Task.sleep(nanoseconds: AppConfig.postTerminateFlushNanoseconds)
                return
            }
            try? await Task.sleep(nanoseconds: AppConfig.terminatePollIntervalNanoseconds)
        }

        // Fallback to forceTerminate if Electron hung on an unsaved dialog
        for app in matchingRunningAntigravityApps(includeIDE: shouldIncludeIDE) where !app.isTerminated {
            _ = app.forceTerminate()
        }
        try? await Task.sleep(nanoseconds: AppConfig.postTerminateFlushNanoseconds)
    }

    private func matchingRunningAntigravityApps(includeIDE: Bool? = nil) -> [NSRunningApplication] {
        AntigravityProcessMatcher.matchingRunningApps(
            bundlePath: settings.agyAppBundlePath,
            syncIDESession: includeIDE ?? settings.syncIDESession
        )
    }

    private func matchingRunningIDEBundleURL() -> URL? {
        NSWorkspace.shared.runningApplications.first { app in
            app.localizedName?.caseInsensitiveCompare("Antigravity IDE") == .orderedSame
                || app.bundleURL?.lastPathComponent.caseInsensitiveCompare("Antigravity IDE.app") == .orderedSame
        }?.bundleURL
    }

    private func relaunchAntigravity() async throws {
        let appURL = URL(fileURLWithPath: settings.agyAppBundlePath)
        try await relaunchApplication(at: appURL, activate: true)
    }

    private func relaunchApplication(at appURL: URL, activate: Bool) async throws {
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw NSError(
                domain: "AGYAutoChanger",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy ứng dụng tại \(appURL.path)"]
            )
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
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
