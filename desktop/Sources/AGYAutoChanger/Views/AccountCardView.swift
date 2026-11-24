import SwiftUI

// MARK: - Color Hex Helper

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Account Card View

/// 1-click interactive account card showing identity, status badge, remark, and per-model usage bars.
struct AccountCardView: View {
    let account: AccountProfile
    let shortcutIndex: Int?
    let hasSnapshot: Bool
    let isSwitchingDisabled: Bool
    let displayMode: AccountDisplayMode
    let resetCountdownMode: ResetCountdownDisplayMode
    let modelFilterScope: QuotaModelFilterScope
    let canMoveUp: Bool
    let canMoveDown: Bool
    let isCLISessionInitialized: Bool
    let isRunningWarmup: Bool
    let onSelect: () -> Void
    let onSwitchCLIOnly: () -> Void
    let onWarmupAccount: () -> Void
    let onSnapshotNow: () -> Void
    let onMarkRateLimit: (String, Int) -> Void
    let onClearCooldowns: () -> Void
    let onChangeTier: (AccountTier) -> Void
    let onUpdateRemark: (String) -> Void
    let onToggleDisabled: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onExportAccount: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isEditingRemark = false
    @State private var draftRemark = ""

    private var filteredUsages: [ModelUsage] {
        account.modelUsages.filter { modelFilterScope.includes(modelID: $0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: displayMode == .compact ? 6 : 8) {
            headerRow

            if isEditingRemark {
                remarkEditorRow
            }

            if !filteredUsages.isEmpty {
                if displayMode == .compact {
                    compactUsageStrip
                } else {
                    usageGrid
                }
            }

            if !hasSnapshot {
                missingSnapshotBanner
            }
        }
        .padding(displayMode == .compact ? 8.5 : 10)
        .background(cardBackground)
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .opacity(account.isDisabled ? 0.68 : 1.0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            guard !isSwitchingDisabled, !isEditingRemark, !account.isDisabled else { return }
            onSelect()
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(spacing: 8) {
            avatarBadge

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    Text(account.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if !account.extraDedicatedPoolLabels.isEmpty {
                        let poolNames = account.extraDedicatedPoolLabels.joined(separator: " & ")
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Color.green.opacity(0.35), lineWidth: 2))
                            .help("Tài khoản có pool riêng: \(poolNames)")
                    }

                    tierPill

                    if let shortcutIndex, shortcutIndex <= 9, !account.isDisabled {
                        Text("⌘\(shortcutIndex)")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }

                HStack(spacing: 4) {
                    Text(account.email)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if !account.remark.isEmpty {
                        Text("· \(account.remark)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.accentColor.opacity(0.9))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            statusPill

            contextMenuButton
        }
    }

    private var remarkEditorRow: some View {
        HStack(spacing: 6) {
            TextField("Nhập ghi chú (vd: Acc Work)...", text: $draftRemark)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit {
                    saveRemark()
                }
            Button("Lưu", action: saveRemark)
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            Button("Hủy") {
                isEditingRemark = false
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10.5))
            .foregroundColor(.secondary)
        }
    }

    private func saveRemark() {
        onUpdateRemark(draftRemark)
        isEditingRemark = false
    }

    private var avatarBadge: some View {
        ZStack {
            Circle()
                .fill(Color(hex: account.avatarHex).gradient)
                .frame(width: displayMode == .compact ? 26 : 30, height: displayMode == .compact ? 26 : 30)
                .saturation(account.isDisabled ? 0.25 : 1.0)
            Text(account.initials)
                .font(.system(size: displayMode == .compact ? 10.5 : 11.5, weight: .bold))
                .foregroundColor(.white)
        }
        .overlay(alignment: .bottomTrailing) {
            if account.isActive && !account.isDisabled {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
        }
    }

    private var tierPill: some View {
        Text(account.tier.badgeTitle)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .foregroundColor(tierAccentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tierAccentColor.opacity(0.14))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var statusPill: some View {
        if account.isDisabled {
            HStack(spacing: 3) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 9.5))
                Text("Tạm tắt")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.14))
            .clipShape(Capsule())
        } else if account.isActive {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Đang dùng")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.14))
            .clipShape(Capsule())
        } else {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(isHovered ? "Đổi ngay" : "Chuyển")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundColor(isHovered ? .white : .accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isHovered ? Color.accentColor : Color.accentColor.opacity(0.12))
            .clipShape(Capsule())
        }
    }

    private var contextMenuButton: some View {
        Menu {
            if !account.isDisabled {
                Button(action: onSelect) {
                    Label(
                        account.isActive ? "Làm mới phiên hiện tại" : "Chuyển sang tài khoản này (1-Click)",
                        systemImage: "bolt.horizontal.circle"
                    )
                }
                if isCLISessionInitialized {
                    Button(action: onSwitchCLIOnly) {
                        Label("Đổi riêng agy CLI (không tắt App)", systemImage: "terminal")
                    }
                }
                if hasSnapshot {
                    Button(action: onWarmupAccount) {
                        Label("Warmup chu kỳ ngay", systemImage: "flame")
                    }
                    .disabled(isRunningWarmup || isSwitchingDisabled)
                }
            }
            Button(action: onSnapshotNow) {
                Label("Cập nhật Snapshot từ phiên AGY đang mở", systemImage: "camera.aperture")
            }

            Divider()

            Button {
                draftRemark = account.remark
                isEditingRemark = true
            } label: {
                Label("Sửa ghi chú (Remark)...", systemImage: "pencil")
            }

            Button(action: onToggleDisabled) {
                Label(
                    account.isDisabled ? "Kích hoạt lại tài khoản" : "Tạm tắt tài khoản (Disable)",
                    systemImage: account.isDisabled ? "play.circle" : "pause.circle"
                )
            }

            Menu("Sắp xếp thứ tự") {
                Button(action: onMoveUp) {
                    Label("Đẩy lên trên", systemImage: "arrow.up")
                }
                .disabled(!canMoveUp)

                Button(action: onMoveDown) {
                    Label("Đẩy xuống dưới", systemImage: "arrow.down")
                }
                .disabled(!canMoveDown)
            }

            Button(action: onExportAccount) {
                Label("Xuất tài khoản ra JSON...", systemImage: "square.and.arrow.up")
            }

            Divider()

            Menu("Đánh dấu chạm Quota (Cooldown)") {
                ForEach(account.modelUsages) { usage in
                    Button("Chạm giới hạn \(usage.shortLabel) (1 giờ)") {
                        onMarkRateLimit(usage.id, 60)
                    }
                }
                Divider()
                Button("Xóa tất cả Cooldown", action: onClearCooldowns)
            }

            Menu("Bậc gói tài khoản") {
                ForEach(AccountTier.allCases) { tier in
                    Button {
                        onChangeTier(tier)
                    } label: {
                        HStack {
                            Text(tier.badgeTitle)
                            if account.tier == tier {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("Xóa khỏi danh sách", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var usageGrid: some View {
        let usages = filteredUsages
        let pairedCount = usages.count - (usages.count % 2)
        let pairedUsages = Array(usages.prefix(pairedCount))
        let trailingUsage = usages.count % 2 == 1 ? usages.last : nil

        return VStack(spacing: 5) {
            if !pairedUsages.isEmpty {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6)
                ], spacing: 5) {
                    ForEach(pairedUsages) { usage in
                        ModelUsageBarCell(usage: usage, resetCountdownMode: resetCountdownMode)
                    }
                }
            }
            if let trailingUsage {
                ModelUsageBarCell(usage: trailingUsage, resetCountdownMode: resetCountdownMode)
            }
        }
    }

    private var compactUsageStrip: some View {
        HStack(spacing: 4) {
            ForEach(filteredUsages) { usage in
                CompactUsageMicroCell(usage: usage, resetCountdownMode: resetCountdownMode)
            }
        }
    }

    private var missingSnapshotBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
            Text("Chưa có snapshot. Đăng nhập acc này trên AGY rồi bấm 'Cập nhật Snapshot'.")
                .font(.system(size: 10))
                .foregroundColor(.orange)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: - Styling Helpers

    private var tierAccentColor: Color {
        switch account.tier {
        case .free: return .secondary
        case .pro: return .blue
        case .ultra: return .purple
        }
    }

    private var cardBackground: some ShapeStyle {
        if account.isActive && !account.isDisabled {
            return AnyShapeStyle(Color.green.opacity(isHovered ? 0.11 : 0.08))
        }
        return AnyShapeStyle(Color.primary.opacity(isHovered ? 0.08 : 0.04))
    }

    private var cardBorder: some View {
        let strokeColor: Color = (account.isActive && !account.isDisabled)
            ? Color.green.opacity(0.45)
            : (isHovered ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08))
        return RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(strokeColor, lineWidth: (account.isActive && !account.isDisabled) ? 1.25 : 1.0)
    }
}

// MARK: - Shared Usage Cell Presenter

private enum UsageCellPresenter {
    static func statusColor(for usage: ModelUsage) -> Color {
        if usage.isUnknownObservation {
            return .secondary
        }
        switch usage.statusLevel() {
        case .healthy: return .green
        case .moderate: return .blue
        case .warning: return .orange
        case .rateLimited: return .red
        }
    }

    static func statusLabel(
        for usage: ModelUsage,
        mode: ResetCountdownDisplayMode,
        isHovered: Bool,
        compact: Bool
    ) -> String {
        if usage.isUnknownObservation {
            return "—"
        }
        if usage.isRateLimited() {
            switch mode {
            case .always:
                return usage.remainingResetLabel().map { compact ? "0% · \($0)" : "Hết · \($0)" } ?? (compact ? "0%" : "Hết · 0%")
            case .onHover:
                if isHovered, let reset = usage.remainingResetLabel() {
                    return "0% · ⏱ \(reset)"
                }
                return compact ? "0%" : "Hết · 0%"
            case .hidden:
                return compact ? "0%" : "Hết · 0%"
            }
        }

        let pct = usage.remainingPercentageInt
        let prefix = compact ? "" : "Còn "
        switch mode {
        case .always:
            if usage.hasDashboardQuota {
                if let reset = usage.remainingResetLabel() {
                    return "\(prefix)\(pct)% · \(reset)"
                }
                return "\(prefix)\(pct)%"
            }
            return "\(prefix)\(pct)% · \(usage.turnsUsed)/\(usage.turnLimit)"
        case .onHover:
            if isHovered {
                if let reset = usage.remainingResetLabel() {
                    return "\(pct)% · ⏱ \(reset)"
                }
                if !usage.hasDashboardQuota {
                    return "\(pct)% · \(usage.turnsUsed)/\(usage.turnLimit)"
                }
            }
            return "\(prefix)\(pct)%"
        case .hidden:
            return "\(prefix)\(pct)%"
        }
    }

    static func compactShortCode(for usage: ModelUsage) -> String {
        switch usage.id {
        case "gemini-5h": return "G5h"
        case "gemini-weekly": return "GWk"
        case "3p-5h": return "C5h"
        case "3p-weekly": return "CWk"
        case "argon-weekly": return "Arg"
        case "carbon-5h": return "Cb5"
        case "carbon-weekly": return "CbW"
        default:
            let base = usage.shortLabel
                .replacingOccurrences(of: " Tuần", with: "")
                .replacingOccurrences(of: " 5h", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = String(base.prefix(3))
            if usage.id.hasSuffix("-weekly") {
                return "\(prefix)W"
            }
            if usage.id.hasSuffix("-5h") {
                return "\(prefix)5"
            }
            return String(usage.shortLabel.prefix(4))
        }
    }

    static func tooltipText(for usage: ModelUsage) -> String {
        if usage.isUnknownObservation {
            return "\(usage.displayName): Chưa có dữ liệu quota (—)"
        }
        var parts: [String] = ["\(usage.displayName): Còn \(usage.remainingPercentageInt)%"]
        if let hint = usage.groupMembersHint, !hint.isEmpty {
            parts.append("Bao gồm: \(hint)")
        }
        if usage.hasDashboardQuota {
            parts.append("Nguồn: Antigravity Dashboard")
        } else {
            parts.append("Nguồn: Telemetry nội bộ (\(usage.turnsUsed)/\(usage.turnLimit) lượt)")
        }
        if let reset = usage.remainingResetLabel() {
            parts.append("Làm mới sau: \(reset)")
        }
        if let tokens = usage.tokensUsed, tokens > 0 {
            parts.append("Đã ghi nhận: \(usage.turnsUsed) lượt · \(formatTokenCount(tokens)) tokens")
        } else if usage.hasDashboardQuota && usage.turnsUsed > 0 {
            parts.append("Phiên cục bộ: \(usage.turnsUsed) lượt")
        }
        return parts.joined(separator: "\n")
    }

    static func formatTokenCount(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000.0)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000.0)
        }
        return "\(tokens)"
    }
}

private struct UsageProgressBarTrack: View {
    let usage: ModelUsage
    let color: Color
    let height: CGFloat

    var body: some View {
        let remainingFraction = usage.remainingFractionValue()
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if usage.isUnknownObservation {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Path { path in
                        let midY = proxy.size.height / 2
                        path.move(to: CGPoint(x: 2, y: midY))
                        path.addLine(to: CGPoint(x: max(2, proxy.size.width - 2), y: midY))
                    }
                    .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: max(1.5, height * 0.5), dash: [3, 3]))
                } else {
                    Capsule()
                        .fill(usage.isRateLimited() ? Color.red.opacity(0.18) : Color.primary.opacity(0.10))
                    if remainingFraction > 0.001 {
                        Capsule()
                            .fill(color)
                            .frame(width: max(4, proxy.size.width * remainingFraction))
                    }
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Model Usage Bar Cell

private struct ModelUsageBarCell: View {
    let usage: ModelUsage
    let resetCountdownMode: ResetCountdownDisplayMode

    @State private var isCellHovered = false

    var body: some View {
        let color = UsageCellPresenter.statusColor(for: usage)
        let label = UsageCellPresenter.statusLabel(
            for: usage,
            mode: resetCountdownMode,
            isHovered: isCellHovered,
            compact: false
        )

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(usage.shortLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                Text(label)
                    .font(.system(size: 9.5, weight: usage.isRateLimited() ? .semibold : .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(color)
                    .lineLimit(1)
            }

            UsageProgressBarTrack(usage: usage, color: color, height: 4)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4.5)
        .background(Color.primary.opacity(isCellHovered ? 0.055 : 0.03))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isCellHovered = hovering
            }
        }
        .help(UsageCellPresenter.tooltipText(for: usage))
    }
}

// MARK: - Compact Usage Micro Cell

private struct CompactUsageMicroCell: View {
    let usage: ModelUsage
    let resetCountdownMode: ResetCountdownDisplayMode

    @State private var isCellHovered = false

    var body: some View {
        let color = UsageCellPresenter.statusColor(for: usage)
        let shortCode = UsageCellPresenter.compactShortCode(for: usage)
        let label = UsageCellPresenter.statusLabel(
            for: usage,
            mode: resetCountdownMode,
            isHovered: isCellHovered,
            compact: true
        )

        VStack(alignment: .leading, spacing: 2.5) {
            HStack(spacing: 2) {
                Text(shortCode)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 1)
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(color)
                    .lineLimit(1)
            }

            UsageProgressBarTrack(usage: usage, color: color, height: 3)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3.5)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(isCellHovered ? 0.055 : 0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isCellHovered = hovering
            }
        }
        .help(UsageCellPresenter.tooltipText(for: usage))
    }
}
