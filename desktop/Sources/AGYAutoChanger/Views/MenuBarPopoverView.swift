import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Layout & Dynamic Content Height State

@MainActor
public final class PopoverLayoutState: ObservableObject {
    @Published public var screenVisibleHeight: CGFloat

    public init(screenVisibleHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800) {
        self.screenVisibleHeight = screenVisibleHeight
    }

    public func updateScreenVisibleHeight(_ height: CGFloat) {
        guard height > 0, abs(screenVisibleHeight - height) > 1 else { return }
        screenVisibleHeight = height
    }
}

private struct PopoverBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

private struct PopoverHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

private struct PopoverFooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

// MARK: - Menu Bar Popover View

/// Main floating popover view presenting all saved accounts, model usages, and 1-click switching controls.
public struct MenuBarPopoverView: View {
    @ObservedObject var service: AccountSwitcherService
    @ObservedObject var layoutState: PopoverLayoutState

    @State private var isShowingAddPanel = false
    @State private var isShowingSettings = false
    @State private var selectedTierFilter: AccountTier? = nil
    @State private var draggedAccountID: UUID? = nil
    @State private var measuredBodyHeight: CGFloat = 0
    @State private var measuredHeaderHeight: CGFloat = 46
    @State private var measuredFooterHeight: CGFloat = 36

    public init(service: AccountSwitcherService, layoutState: PopoverLayoutState) {
        self.service = service
        self.layoutState = layoutState
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerSection
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PopoverHeaderHeightKey.self, value: proxy.size.height)
                    }
                )
            Divider()

            ScrollView(.vertical, showsIndicators: needsVerticalScroll) {
                popoverScrollBody
                    .frame(maxWidth: .infinity)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: PopoverBodyHeightKey.self, value: proxy.size.height)
                        }
                    )
            }
            .scrollDisabled(!needsVerticalScroll)
            .frame(height: resolvedScrollViewportHeight)

            Divider()
            footerSection
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PopoverFooterHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(
            minWidth: AppConfig.uiPopoverMinWidth,
            idealWidth: AppConfig.uiPopoverIdealWidth,
            maxWidth: AppConfig.uiPopoverMaxWidth
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75)
        )
        .onPreferenceChange(PopoverHeaderHeightKey.self) { newHeight in
            let rounded = ceil(newHeight)
            if rounded > 1, abs(measuredHeaderHeight - rounded) > 0.5 {
                measuredHeaderHeight = rounded
            }
        }
        .onPreferenceChange(PopoverFooterHeightKey.self) { newHeight in
            let rounded = ceil(newHeight)
            if rounded > 1, abs(measuredFooterHeight - rounded) > 0.5 {
                measuredFooterHeight = rounded
            }
        }
        .onPreferenceChange(PopoverBodyHeightKey.self) { newHeight in
            let rounded = ceil(newHeight)
            if rounded > 1, abs(measuredBodyHeight - rounded) > 0.5 {
                measuredBodyHeight = rounded
            }
        }
        .background(shortcutOverlayButtons)
    }

    private var dynamicScreenMaxHeight: CGFloat {
        max(360, floor(layoutState.screenVisibleHeight * AppConfig.uiPopoverMaxScreenFraction))
    }

    private var maxScrollViewportHeight: CGFloat {
        let chromeHeight = measuredHeaderHeight + measuredFooterHeight + 2
        return max(180, dynamicScreenMaxHeight - chromeHeight)
    }

    private var resolvedScrollViewportHeight: CGFloat {
        guard measuredBodyHeight > 0 else {
            return min(maxScrollViewportHeight, 260)
        }
        return min(measuredBodyHeight, maxScrollViewportHeight)
    }

    private var needsVerticalScroll: Bool {
        measuredBodyHeight > maxScrollViewportHeight + 1
    }

    private var popoverScrollBody: some View {
        VStack(spacing: 8) {
            if service.switchPhase != .idle {
                statusBanner
            }

            if let autoSwitchBanner = service.autoSwitchBanner {
                autoSwitchStatusBanner(autoSwitchBanner)
            }

            if service.isRunningWarmup || service.warmupStatusMessage != nil || service.isWarmupPausedByStorageError {
                warmupStatusBanner
            }

            if isShowingSettings {
                SettingsInlineView(
                    settings: service.settings,
                    availableAutoSwitchBuckets: availableAutoSwitchBuckets,
                    isRunningWarmup: service.isRunningWarmup,
                    onSave: { service.saveSettings($0) },
                    onRunManualWarmup: { service.runManualWeeklyWarmup(onlyAccountID: nil) },
                    onOpenVault: { service.openVaultInFinder() },
                    onClose: { isShowingSettings = false }
                )
            }

            if isShowingAddPanel {
                AddAccountSheetView(
                    detectedEmail: service.liveState.detectedEmail,
                    detectedTier: service.liveState.detectedTier,
                    onCaptureCurrent: { name, email, tier, remark in
                        do {
                            try service.captureCurrentSessionAsNewAccount(
                                displayName: name,
                                email: email,
                                tier: tier,
                                remark: remark
                            )
                            isShowingAddPanel = false
                        } catch {
                            service.switchPhase = .failed(error.localizedDescription)
                        }
                    },
                    onStartNewLogin: { name, email, tier, remark in
                        isShowingAddPanel = false
                        Task {
                            await service.prepareCleanLoginForNewAccount(
                                displayName: name,
                                email: email,
                                tier: tier,
                                remark: remark
                            )
                        }
                    },
                    onImportTokenOrJSON: { name, email, tier, remark, rawInput in
                        do {
                            _ = try service.addAccountWithTokenOrJSON(
                                displayName: name,
                                email: email,
                                tier: tier,
                                remark: remark,
                                rawInput: rawInput
                            )
                            isShowingAddPanel = false
                        } catch {
                            service.switchPhase = .failed(error.localizedDescription)
                        }
                    },
                    onCancel: { isShowingAddPanel = false }
                )
            }

            if service.settings.showQuickSummaryHeader && !service.accounts.isEmpty {
                QuickSummaryHeaderView(
                    todayOverview: service.todayOverview,
                    aggregateQuota: UsageTrackerService.computeAggregateQuota(
                        for: service.accounts,
                        modelScope: service.settings.modelFilterScope
                    )
                )
            }

            if service.accounts.count >= 2 {
                filterPillsBar
            }

            accountsScrollSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 26, height: 26)
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("AGY Account Switcher")
                    .font(.system(size: 13, weight: .bold))
                Text(liveSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                var updated = service.settings
                updated.accountDisplayMode = (updated.accountDisplayMode == .compact) ? .card : .compact
                service.saveSettings(updated)
            } label: {
                Image(systemName: service.settings.accountDisplayMode == .compact ? "rectangle.grid.1x2" : "list.bullet")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(service.settings.accountDisplayMode == .compact ? "Chuyển sang dạng Thẻ chi tiết" : "Chuyển sang dạng Thu gọn")

            Button {
                service.refreshLiveStateAndUsage()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .opacity(service.isRefreshingUsage ? 0.45 : 1.0)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Cập nhật Usage & Trạng thái AGY")
            .disabled(service.isRefreshingUsage)

            Button {
                isShowingSettings.toggle()
                if isShowingSettings { isShowingAddPanel = false }
            } label: {
                Image(systemName: isShowingSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Cài đặt")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var liveSubtitle: String {
        if let email = service.liveState.detectedEmail {
            return "Đang mở: \(email)"
        }
        return "\(service.accounts.count) tài khoản · Bấm 1 lần để đổi"
    }

    // MARK: - Status Progress Banner

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusIcon
                Text(service.switchPhase.statusMessage)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(bannerTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if case .failed = service.switchPhase {
                    Button {
                        service.switchPhase = .idle
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                }
            }

            if service.switchPhase.isInProgress {
                ProgressView(value: service.switchPhase.progress)
                    .progressViewStyle(.linear)
            }
        }
        .padding(10)
        .background(bannerBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch service.switchPhase {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundColor(.red)
        case .awaitingNewLogin:
            Image(systemName: "person.badge.key.fill")
                .foregroundColor(.blue)
        default:
            ProgressView()
                .controlSize(.small)
        }
    }

    private var bannerTextColor: Color {
        if case .failed = service.switchPhase { return .red }
        if case .completed = service.switchPhase { return .green }
        return .primary
    }

    private var bannerBackgroundColor: Color {
        switch service.switchPhase {
        case .completed: return Color.green.opacity(0.12)
        case .failed: return Color.red.opacity(0.12)
        default: return Color.accentColor.opacity(0.12)
        }
    }

    @ViewBuilder
    private func autoSwitchStatusBanner(_ banner: AutoSwitchBannerState) -> some View {
        switch banner {
        case .waitingForIdle(_, let target, let label, let remaining, let busyReason):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chờ tác vụ xong để tự chuyển → \(target.displayName)")
                            .font(.system(size: 11, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(label) còn \(remaining)% · \(busyReason)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                }

                HStack(spacing: 6) {
                    Button("Đổi ngay") {
                        service.switchNowFromAutoSwitchBanner(target)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)

                    Button("Hủy lần này") {
                        service.cancelPendingAutoSwitch()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Spacer()
                }
            }
            .padding(9)
            .background(Color.orange.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.orange.opacity(0.32), lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .pausedByFailure(let reason):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundColor(.red)
                Text("Auto-Switch tạm dừng: \(reason)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Bật lại") {
                    service.resumeAutoSwitchAfterFailure()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(9)
            .background(Color.red.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .noEligibleBackup(_, let label, let remaining, let minBackup):
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text("\(label) còn \(remaining)%, chưa có acc dự phòng ≥ \(minBackup)%.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    service.dismissAutoSwitchBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5))
                }
                .buttonStyle(.borderless)
            }
            .padding(8.5)
            .background(Color.orange.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var warmupStatusBanner: some View {
        let isErrorState = service.isWarmupPausedByStorageError
            || (service.warmupStatusMessage?.contains("thất bại") == true)
        let accent: Color = isErrorState ? .red : .orange

        return HStack(spacing: 7) {
            if service.isRunningWarmup {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: isErrorState ? "exclamationmark.triangle.fill" : "flame.fill")
                    .font(.system(size: 11.5))
                    .foregroundColor(accent)
            }

            Text(service.warmupStatusMessage ?? "Đang chạy Weekly Warmup...")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(isErrorState ? .red : .primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if service.isRunningWarmup {
                Button("Hủy") {
                    service.cancelWeeklyWarmup()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else if service.isWarmupPausedByStorageError {
                Button("Thử lưu lại") {
                    service.resetWarmupStorageError()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Button {
                    service.dismissWarmupStatus()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8.5)
        .background(accent.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(0.28), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Filter Pills Bar

    private var filterPillsBar: some View {
        HStack(spacing: 5) {
            filterTierPill(title: "Tất cả", tier: nil)
            ForEach(AccountTier.allCases) { tier in
                if service.accounts.contains(where: { $0.tier == tier }) {
                    filterTierPill(title: tier.badgeTitle, tier: tier)
                }
            }

            Spacer(minLength: 4)

            Menu {
                ForEach(QuotaModelFilterScope.allCases) { scope in
                    Button {
                        var updated = service.settings
                        updated.modelFilterScope = scope
                        service.saveSettings(updated)
                    } label: {
                        HStack {
                            Text(scope.title)
                            if service.settings.modelFilterScope == scope {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 10))
                    Text(service.settings.modelFilterScope.title)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Lọc nhóm model hiển thị")
        }
    }

    private func filterTierPill(title: String, tier: AccountTier?) -> some View {
        let isSelected = (selectedTierFilter == tier)
        return Button {
            selectedTierFilter = tier
        } label: {
            Text(title)
                .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : .secondary)
                .padding(.horizontal, 7.5)
                .padding(.vertical, 3)
                .background(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Accounts List

    private var displayedAccounts: [AccountProfile] {
        guard let selectedTierFilter else { return service.accounts }
        return service.accounts.filter { $0.tier == selectedTierFilter }
    }

    private var shortcutEligibleAccounts: [AccountProfile] {
        Array(service.accounts.filter { !$0.isDisabled }.prefix(9))
    }

    private var availableAutoSwitchBuckets: [(id: String, label: String)] {
        var seen: Set<String> = []
        var items: [(id: String, label: String)] = []
        for core in AppConfig.supportedModels where seen.insert(core.id).inserted {
            items.append((id: core.id, label: core.shortLabel))
        }
        for account in service.accounts {
            for usage in account.modelUsages where !seen.contains(usage.id) && usage.hasDashboardQuota {
                seen.insert(usage.id)
                items.append((id: usage.id, label: usage.shortLabel))
            }
        }
        return items
    }

    @ViewBuilder
    private var accountsScrollSection: some View {
        if service.accounts.isEmpty {
            emptyStateView
        } else if displayedAccounts.isEmpty {
            VStack(spacing: 6) {
                Text("Không có tài khoản thuộc gói \(selectedTierFilter?.badgeTitle ?? "")")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
                Button("Hiện tất cả") {
                    selectedTierFilter = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: service.settings.accountDisplayMode == .compact ? 6 : 8) {
                ForEach(displayedAccounts) { account in
                    let shortcutIndex = shortcutEligibleAccounts.firstIndex(where: { $0.id == account.id }).map { $0 + 1 }
                    let globalIndex = service.accounts.firstIndex(where: { $0.id == account.id }) ?? 0

                    let card = AccountCardView(
                        account: account,
                        shortcutIndex: shortcutIndex,
                        hasSnapshot: service.hasValidSnapshot(for: account),
                        isSwitchingDisabled: service.switchPhase.isInProgress,
                        displayMode: service.settings.accountDisplayMode,
                        resetCountdownMode: service.settings.resetCountdownMode,
                        modelFilterScope: service.settings.modelFilterScope,
                        canMoveUp: globalIndex > 0,
                        canMoveDown: globalIndex < service.accounts.count - 1,
                        isCLISessionInitialized: service.isCLISessionInitialized,
                        isRunningWarmup: service.isRunningWarmup,
                        onSelect: {
                            Task {
                                await service.switchToAccount(account)
                            }
                        },
                        onSwitchCLIOnly: {
                            Task {
                                await service.switchCLISessionOnly(to: account)
                            }
                        },
                        onWarmupAccount: {
                            service.runManualWeeklyWarmup(onlyAccountID: account.id)
                        },
                        onSnapshotNow: {
                            service.updateSnapshotForAccount(account)
                        },
                        onMarkRateLimit: { modelID, minutes in
                            service.markModelRateLimited(
                                accountID: account.id,
                                modelID: modelID,
                                durationMinutes: minutes
                            )
                        },
                        onClearCooldowns: {
                            service.clearCooldowns(for: account.id)
                        },
                        onChangeTier: { newTier in
                            service.updateTier(for: account.id, tier: newTier)
                        },
                        onUpdateRemark: { newRemark in
                            service.updateRemark(for: account.id, remark: newRemark)
                        },
                        onToggleDisabled: {
                            service.toggleAccountDisabled(for: account.id)
                        },
                        onMoveUp: {
                            service.moveAccount(at: globalIndex, direction: -1)
                        },
                        onMoveDown: {
                            service.moveAccount(at: globalIndex, direction: 1)
                        },
                        onExportAccount: {
                            exportAccounts(onlyAccountID: account.id, suggestedPrefix: account.menuBarShortName)
                        },
                        onDelete: {
                            service.deleteAccount(account)
                        }
                    )

                    if selectedTierFilter == nil {
                        card
                            .onDrag {
                                draggedAccountID = account.id
                                return NSItemProvider(object: account.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [UTType.plainText],
                                delegate: AccountCardDropDelegate(
                                    targetID: account.id,
                                    draggedID: $draggedAccountID,
                                    onMove: { fromID, toID in
                                        service.moveAccount(from: fromID, to: toID)
                                    }
                                )
                            )
                    } else {
                        card
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 7) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
            Text("Chưa có tài khoản nào trong Vault")
                .font(.system(size: 12.5, weight: .semibold))
            Text("Bấm nút bên dưới để lưu phiên AGY đang đăng nhập hoặc thêm tài khoản mới.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 7) {
            Button {
                isShowingAddPanel.toggle()
                if isShowingAddPanel { isShowingSettings = false }
            } label: {
                Label("Thêm / Lưu Acc", systemImage: "person.badge.plus")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(service.switchPhase.isInProgress)

            if let active = service.accounts.first(where: { $0.isActive }) {
                Button {
                    service.updateSnapshotForAccount(active)
                } label: {
                    Label("Snapshot", systemImage: "camera.aperture")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Lưu lại phiên hiện tại cho \(active.displayName)")
                .disabled(service.switchPhase.isInProgress)
            }

            Menu {
                Button {
                    exportAccounts(onlyAccountID: nil, suggestedPrefix: "agy-accounts")
                } label: {
                    Label("Xuất toàn bộ Acc ra JSON...", systemImage: "square.and.arrow.up")
                }
                .disabled(service.accounts.isEmpty)

                Button {
                    importAccountsFromFile()
                } label: {
                    Label("Nhập Acc từ file JSON...", systemImage: "square.and.arrow.down")
                }
            } label: {
                Label("JSON", systemImage: "square.and.arrow.up.on.square")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .fixedSize()
            .help("Sao lưu hoặc khôi phục tài khoản qua JSON")

            Spacer()

            Button("Thoát") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Keyboard Shortcuts (⌘1 ... ⌘9)

    private var shortcutOverlayButtons: some View {
        ZStack {
            ForEach(Array(shortcutEligibleAccounts.enumerated()), id: \.element.id) { idx, account in
                if let digit = "\(idx + 1)".first {
                    Button("") {
                        Task {
                            await service.switchToAccount(account)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(digit), modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Export / Import File Panels

    private func exportAccounts(onlyAccountID: UUID?, suggestedPrefix: String) {
        do {
            let data = try service.exportAccountsJSONData(onlyAccountID: onlyAccountID)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dateSuffix = formatter.string(from: Date())
            let sanitizedPrefix = suggestedPrefix
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: " ", with: "-")
                .lowercased()

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.json]
            savePanel.nameFieldStringValue = "\(sanitizedPrefix)-\(dateSuffix).json"
            savePanel.title = "Xuất danh sách tài khoản JSON (0600)"

            NSApp.activate(ignoringOtherApps: true)
            if savePanel.runModal() == .OK, let targetURL = savePanel.url {
                try service.saveProtectedExportData(data, to: targetURL)
                service.switchPhase = .completed("Đã xuất JSON bảo mật (0600)")
            }
        } catch {
            service.switchPhase = .failed(error.localizedDescription)
        }
    }

    private func importAccountsFromFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.title = "Nhập tài khoản từ file JSON"

        NSApp.activate(ignoringOtherApps: true)
        if openPanel.runModal() == .OK, let sourceURL = openPanel.url {
            do {
                let data = try Data(contentsOf: sourceURL)
                _ = try service.importAccounts(fromJSONData: data)
            } catch {
                service.switchPhase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Drag & Drop Delegate

private struct AccountCardDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedID: UUID?
    let onMove: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            onMove(draggedID, targetID)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Quick Summary Header View

private struct QuickSummaryHeaderView: View {
    let todayOverview: DailyUsageOverview
    let aggregateQuota: AggregateQuotaOverview

    var body: some View {
        HStack(spacing: 8) {
            todayUsageCard
            aggregateQuotaCard
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var todayUsageCard: some View {
        HStack(spacing: 9) {
            MiniTokenDonutView(
                inputTokens: todayOverview.inputTokens,
                outputTokens: todayOverview.outputTokens,
                cachedTokens: todayOverview.cachedTokens
            )
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Hôm nay")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 2)
                    Text(String(format: "~$%.2f", todayOverview.estimatedCostUSD))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                        .lineLimit(1)
                }

                Text("\(formatCompactTokens(todayOverview.totalTokens)) tok")
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)

                Text("\(todayOverview.totalTurns) lượt · Cache \(todayOverview.cacheHitPercentage)%")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var aggregateQuotaCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("Dàn Acc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 2)
                Text("\(aggregateQuota.availableAccountsCount)/\(aggregateQuota.totalEnabledAccountsCount) sẵn sàng")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(aggregateQuota.availableAccountsCount > 0 ? .green : .orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background((aggregateQuota.availableAccountsCount > 0 ? Color.green : Color.orange).opacity(0.14))
                    .clipShape(Capsule())
                    .lineLimit(1)
            }

            AggregateQuotaBarRow(title: "TB 5 giờ", percent: aggregateQuota.average5hRemainingPercent)
            AggregateQuotaBarRow(title: "TB Tuần", percent: aggregateQuota.averageWeeklyRemainingPercent)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func formatCompactTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }
}

private struct MiniTokenDonutView: View {
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int

    private var segments: [(from: CGFloat, to: CGFloat, color: Color)] {
        let total = Double(inputTokens + outputTokens + cachedTokens)
        guard total > 0 else { return [] }
        let inputEnd = CGFloat(Double(inputTokens) / total)
        let outputEnd = inputEnd + CGFloat(Double(outputTokens) / total)
        return [
            (0, inputEnd, .blue),
            (inputEnd, outputEnd, .purple),
            (outputEnd, 1.0, .green)
        ].filter { $0.to > $0.from }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 4.5)
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                Circle()
                    .trim(from: seg.from, to: seg.to)
                    .stroke(seg.color, style: StrokeStyle(lineWidth: 4.5, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

private struct AggregateQuotaBarRow: View {
    let title: String
    let percent: Int?

    private var barColor: Color {
        guard let percent else { return .secondary }
        if percent <= 0 { return .red }
        if percent <= 20 { return .orange }
        if percent <= 50 { return .blue }
        return .green
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.09))
                    if let percent, percent > 0 {
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(3, proxy.size.width * CGFloat(min(100, percent)) / 100.0))
                    }
                }
            }
            .frame(height: 4)

            Text(percent.map { "\($0)%" } ?? "—")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(barColor)
                .frame(width: 30, alignment: .trailing)
        }
    }
}
