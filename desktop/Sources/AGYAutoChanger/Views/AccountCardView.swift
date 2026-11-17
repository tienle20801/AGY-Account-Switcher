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

/// 1-click interactive account card showing identity, status badge, and per-model usage bars.
struct AccountCardView: View {
    let account: AccountProfile
    let shortcutIndex: Int?
    let hasSnapshot: Bool
    let isSwitchingDisabled: Bool
    let onSelect: () -> Void
    let onSnapshotNow: () -> Void
    let onMarkRateLimit: (String, Int) -> Void
    let onClearCooldowns: () -> Void
    let onChangeTier: (AccountTier) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            usageGrid
            if !hasSnapshot {
                missingSnapshotBanner
            }
        }
        .padding(10)
        .background(cardBackground)
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            guard !isSwitchingDisabled else { return }
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

                    tierPill

                    if let shortcutIndex, shortcutIndex <= 9 {
                        Text("⌘\(shortcutIndex)")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }

                Text(account.email)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            statusPill

            contextMenuButton
        }
    }

    private var avatarBadge: some View {
        ZStack {
            Circle()
                .fill(Color(hex: account.avatarHex).gradient)
                .frame(width: 30, height: 30)
            Text(account.initials)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(.white)
        }
        .overlay(alignment: .bottomTrailing) {
            if account.isActive {
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
        if account.isActive {
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
            Button(action: onSelect) {
                Label(
                    account.isActive ? "Làm mới phiên hiện tại" : "Chuyển sang tài khoản này (1-Click)",
                    systemImage: "bolt.horizontal.circle"
                )
            }
            Button(action: onSnapshotNow) {
                Label("Cập nhật Snapshot từ phiên AGY đang mở", systemImage: "camera.aperture")
            }

            Divider()

            Menu("Đánh dấu chạm Quota (Cooldown)") {
                ForEach(AppConfig.supportedModels, id: \.id) { model in
                    Button("Chạm giới hạn \(model.shortLabel) (1 giờ)") {
                        onMarkRateLimit(model.id, 60)
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
        let pairedCount = account.modelUsages.count - (account.modelUsages.count % 2)
        let pairedUsages = Array(account.modelUsages.prefix(pairedCount))
        let trailingUsage = account.modelUsages.count % 2 == 1 ? account.modelUsages.last : nil

        return VStack(spacing: 5) {
            if !pairedUsages.isEmpty {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6)
                ], spacing: 5) {
                    ForEach(pairedUsages) { usage in
                        ModelUsageBarCell(usage: usage)
                    }
                }
            }
            if let trailingUsage {
                ModelUsageBarCell(usage: trailingUsage)
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
        if account.isActive {
            return AnyShapeStyle(Color.green.opacity(isHovered ? 0.11 : 0.08))
        }
        return AnyShapeStyle(Color.primary.opacity(isHovered ? 0.08 : 0.04))
    }

    private var cardBorder: some View {
        let strokeColor: Color = account.isActive
            ? Color.green.opacity(0.45)
            : (isHovered ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08))
        return RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(strokeColor, lineWidth: account.isActive ? 1.25 : 1.0)
    }
}

// MARK: - Model Usage Bar Cell

private struct ModelUsageBarCell: View {
    let usage: ModelUsage

    var body: some View {
        let remainingFraction = usage.remainingFractionValue()
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(usage.shortLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                Text(statusLabel)
                    .font(.system(size: 9.5, weight: usage.isRateLimited() ? .semibold : .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(statusColor)
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(usage.isRateLimited() ? Color.red.opacity(0.18) : Color.primary.opacity(0.10))
                    if remainingFraction > 0.001 {
                        Capsule()
                            .fill(statusColor)
                            .frame(width: max(4, proxy.size.width * remainingFraction))
                    }
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4.5)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(tooltipText)
    }

    private var statusLabel: String {
        if usage.isRateLimited() {
            if let reset = usage.remainingResetLabel() {
                return "Hết · \(reset)"
            }
            return "Hết · 0%"
        }
        if usage.hasDashboardQuota {
            if usage.remainingPercentageInt < 100, let reset = usage.remainingResetLabel() {
                return "Còn \(usage.remainingPercentageInt)% · \(reset)"
            }
            return "Còn \(usage.remainingPercentageInt)%"
        }
        return "Còn \(usage.remainingPercentageInt)% · \(usage.turnsUsed)/\(usage.turnLimit)"
    }

    private var tooltipText: String {
        var parts: [String] = ["\(usage.displayName): Còn \(usage.remainingPercentageInt)%"]
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

    private func formatTokenCount(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000.0)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000.0)
        }
        return "\(tokens)"
    }

    private var statusColor: Color {
        switch usage.statusLevel() {
        case .healthy: return .green
        case .moderate: return .blue
        case .warning: return .orange
        case .rateLimited: return .red
        }
    }
}
