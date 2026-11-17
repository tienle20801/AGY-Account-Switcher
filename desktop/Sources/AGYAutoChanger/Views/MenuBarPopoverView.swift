import AppKit
import SwiftUI

// MARK: - Height Preference Key

private struct PopoverContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let candidate = nextValue()
        if candidate > 0 {
            value = candidate
        }
    }
}

// MARK: - Menu Bar Popover View

/// Main MenuBarExtra window presenting all saved accounts, model usages, and 1-click switching controls.
public struct MenuBarPopoverView: View {
    @ObservedObject var service: AccountSwitcherService

    @State private var isShowingAddPanel = false
    @State private var isShowingSettings = false
    @State private var measuredScrollContentHeight: CGFloat = 0

    private let maxScrollViewportHeight: CGFloat = AppConfig.uiPopoverMaxHeight - 92

    public init(service: AccountSwitcherService) {
        self.service = service
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerSection
                .fixedSize(horizontal: false, vertical: true)
            Divider()

            ScrollView(.vertical, showsIndicators: isScrollableOverflow) {
                VStack(spacing: 8) {
                    if service.switchPhase != .idle {
                        statusBanner
                    }

                    if isShowingSettings {
                        SettingsInlineView(
                            settings: service.settings,
                            onSave: { service.saveSettings($0) },
                            onOpenVault: { service.openVaultInFinder() },
                            onClose: { isShowingSettings = false }
                        )
                    }

                    if isShowingAddPanel {
                        AddAccountSheetView(
                            detectedEmail: service.liveState.detectedEmail,
                            detectedTier: service.liveState.detectedTier,
                            onCaptureCurrent: { name, email, tier in
                                do {
                                    try service.captureCurrentSessionAsNewAccount(
                                        displayName: name,
                                        email: email,
                                        tier: tier
                                    )
                                    isShowingAddPanel = false
                                } catch {
                                    service.switchPhase = .failed(error.localizedDescription)
                                }
                            },
                            onStartNewLogin: { name, email, tier in
                                isShowingAddPanel = false
                                Task {
                                    await service.prepareCleanLoginForNewAccount(
                                        displayName: name,
                                        email: email,
                                        tier: tier
                                    )
                                }
                            },
                            onCancel: { isShowingAddPanel = false }
                        )
                    }

                    accountsScrollSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PopoverContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
            }
            .frame(height: resolvedScrollViewportHeight)
            .scrollDisabled(!isScrollableOverflow)
            .onPreferenceChange(PopoverContentHeightKey.self) { newHeight in
                let rounded = ceil(newHeight)
                if rounded > 0, abs(rounded - measuredScrollContentHeight) > 0.5 {
                    measuredScrollContentHeight = rounded
                }
            }

            Divider()
            footerSection
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: AppConfig.uiPopoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(shortcutOverlayButtons)
    }

    private var resolvedScrollViewportHeight: CGFloat {
        let target = measuredScrollContentHeight > 0 ? measuredScrollContentHeight : estimatedScrollContentHeight
        return min(max(target, 110), maxScrollViewportHeight)
    }

    private var isScrollableOverflow: Bool {
        let target = measuredScrollContentHeight > 0 ? measuredScrollContentHeight : estimatedScrollContentHeight
        return target > maxScrollViewportHeight
    }

    private var estimatedScrollContentHeight: CGFloat {
        let cardsHeight: CGFloat = service.accounts.isEmpty
            ? 120
            : CGFloat(service.accounts.count) * 154 + CGFloat(max(0, service.accounts.count - 1)) * 8
        let extras: CGFloat =
            (isShowingSettings ? 365 : 0) +
            (isShowingAddPanel ? 270 : 0) +
            (service.switchPhase != .idle ? 52 : 0)
        return cardsHeight + extras + 20
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
                withAnimation(.easeInOut(duration: 0.16)) {
                    isShowingSettings.toggle()
                    if isShowingSettings { isShowingAddPanel = false }
                }
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

    // MARK: - Accounts List

    @ViewBuilder
    private var accountsScrollSection: some View {
        if service.accounts.isEmpty {
            emptyStateView
        } else {
            VStack(spacing: 8) {
                ForEach(Array(service.accounts.enumerated()), id: \.element.id) { index, account in
                    AccountCardView(
                        account: account,
                        shortcutIndex: index < 9 ? (index + 1) : nil,
                        hasSnapshot: service.hasValidSnapshot(for: account),
                        isSwitchingDisabled: service.switchPhase.isInProgress,
                        onSelect: {
                            Task {
                                await service.switchToAccount(account)
                            }
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
                        onDelete: {
                            service.deleteAccount(account)
                        }
                    )
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
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isShowingAddPanel.toggle()
                    if isShowingAddPanel { isShowingSettings = false }
                }
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
                    Label("Lưu Snapshot", systemImage: "camera.aperture")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Lưu lại phiên hiện tại cho \(active.displayName)")
                .disabled(service.switchPhase.isInProgress)
            }

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
            ForEach(Array(service.accounts.prefix(9).enumerated()), id: \.element.id) { idx, account in
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
}
