import ServiceManagement
import SwiftUI

// MARK: - Inline Settings View

/// Settings panel embedded inside the Menu Bar popover for bundle path, Keychain fallback, and Launch at Login.
struct SettingsInlineView: View {
    let settings: SwitcherSettings
    let availableAutoSwitchBuckets: [(id: String, label: String)]
    let isRunningWarmup: Bool
    let onSave: (SwitcherSettings) -> Void
    let onRunManualWarmup: () -> Void
    let onOpenVault: () -> Void
    let onClose: () -> Void

    @State private var draft: SwitcherSettings
    @State private var launchAtLogin: Bool = false
    @State private var launchAtLoginStatus: String?

    init(
        settings: SwitcherSettings,
        availableAutoSwitchBuckets: [(id: String, label: String)] = AppConfig.supportedModels.map { ($0.id, $0.shortLabel) },
        isRunningWarmup: Bool = false,
        onSave: @escaping (SwitcherSettings) -> Void,
        onRunManualWarmup: @escaping () -> Void = {},
        onOpenVault: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.settings = settings
        self.availableAutoSwitchBuckets = availableAutoSwitchBuckets
        self.isRunningWarmup = isRunningWarmup
        self.onSave = onSave
        self.onRunManualWarmup = onRunManualWarmup
        self.onOpenVault = onOpenVault
        self.onClose = onClose
        var seeded = settings
        if seeded.autoSwitchPolicy.monitoredBucketIDs.isEmpty {
            seeded.autoSwitchPolicy.monitoredBucketIDs = AutoSwitchPolicy.defaultBucketIDs(
                for: seeded.autoSwitchPolicy.modelScope
            )
        }
        _draft = State(initialValue: seeded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Cài đặt chuyển đổi")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button("Xong", action: saveAndClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Tự động mở lại Antigravity sau khi đổi acc", isOn: $draft.autoRelaunchAGY)
                    .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Mở / đóng cùng Antigravity (AGY)", isOn: $draft.bindLifecycleWithAGY)
                        .font(.system(size: 12))
                    Text("Tự động mở app khi Antigravity khởi chạy và tự đóng theo khi Antigravity thoát (không đóng lúc đang đổi acc).")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Đồng bộ thêm Antigravity IDE (nếu có dùng)", isOn: $draft.syncIDESession)
                        .font(.system(size: 12))
                    Text("Tự nhận diện Antigravity IDE 2.6+ (dùng chung credential với App) và tự đóng/mở lại khi đang chạy.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Đồng bộ phiên agy CLI (~/.gemini/antigravity-cli)", isOn: $draft.syncCLISession)
                    .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Đồng bộ Keychain phụ (Safe Storage)", isOn: $draft.useKeychainFallback)
                        .font(.system(size: 12))
                    Text("Token OAuth chính (gemini/antigravity) luôn được đồng bộ tự động. Tùy chọn này sao lưu thêm Safe Storage qua SecItemCopyMatching.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Khởi động cùng macOS (Launch at Login)", isOn: $launchAtLogin)
                    .font(.system(size: 12))
                    .onChange(of: launchAtLogin) { enabled in
                        updateLaunchAtLogin(enabled)
                    }

                if let launchAtLoginStatus {
                    Text(launchAtLoginStatus)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }

                Divider()

                HStack {
                    Text("Cửa sổ tính Quota:")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("Cửa sổ", selection: $draft.rollingWindowHours) {
                        Text("5 giờ").tag(5.0)
                        Text("12 giờ").tag(12.0)
                        Text("24 giờ").tag(24.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 175)
                }

                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    Text("Giao diện & Hiển thị Quota")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.secondary)

                    Toggle("Hiện bảng tóm tắt Hôm nay & Tổng quan Dàn Acc", isOn: $draft.showQuickSummaryHeader)
                        .font(.system(size: 12))

                    HStack {
                        Text("Kiểu danh sách:")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("Kiểu danh sách", selection: $draft.accountDisplayMode) {
                            ForEach(AccountDisplayMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 175)
                    }

                    HStack {
                        Text("Đếm ngược Reset:")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("Đếm ngược Reset", selection: $draft.resetCountdownMode) {
                            ForEach(ResetCountdownDisplayMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                    }

                    HStack {
                        Text("Nhóm Model:")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("Nhóm Model", selection: $draft.modelFilterScope) {
                            ForEach(QuotaModelFilterScope.allCases) { scope in
                                Text(scope.title).tag(scope)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Bật cảnh báo macOS khi sắp hết Quota (Argon, Carbon & Gemini)", isOn: $draft.enableLowQuotaNotification)
                        .font(.system(size: 12))

                    if draft.enableLowQuotaNotification {
                        HStack(spacing: 6) {
                            Text("Mức cảnh báo còn lại (5%–95%):")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            TextField("30", value: $draft.lowQuotaThresholdPercent, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 46)
                            Text("%")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Stepper("", value: $draft.lowQuotaThresholdPercent, in: 5...95, step: 5)
                                .labelsHidden()
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    Text("Tự động chuyển tài khoản (Smart Auto-Switch)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.secondary)

                    Toggle("Bật tự động chuyển khi sắp hết Quota", isOn: $draft.autoSwitchPolicy.isEnabled)
                        .font(.system(size: 12))

                    if draft.autoSwitchPolicy.isEnabled {
                        HStack {
                            Text("Thời điểm:")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                            Spacer()
                            Picker("Thời điểm", selection: $draft.autoSwitchPolicy.timingMode) {
                                ForEach(AutoSwitchTimingMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 175)
                        }

                        HStack {
                            Text("Chọn acc đích:")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                            Spacer()
                            Picker("Chiến lược", selection: $draft.autoSwitchPolicy.selectionStrategy) {
                                ForEach(AutoSwitchSelectionStrategy.allCases) { strategy in
                                    Text(strategy.title).tag(strategy)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 175)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text("Mô hình kích hoạt:")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Tất cả") {
                                    applyAutoSwitchBucketPreset(scope: .all)
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10, weight: .medium))
                                Text("·")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Button("Gemini") {
                                    applyAutoSwitchBucketPreset(scope: .geminiOnly)
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10, weight: .medium))
                                Text("·")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Button("Claude") {
                                    applyAutoSwitchBucketPreset(scope: .claudeOnly)
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10, weight: .medium))
                            }

                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 6),
                                    GridItem(.flexible(), spacing: 6)
                                ],
                                spacing: 5
                            ) {
                                ForEach(availableAutoSwitchBuckets, id: \.id) { bucket in
                                    let isSelected = draft.autoSwitchPolicy.monitoredBucketIDs.contains(bucket.id)
                                    Button {
                                        toggleMonitoredBucket(bucket.id)
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 10.5))
                                                .foregroundColor(isSelected ? .accentColor : .secondary)
                                            Text(bucket.label)
                                                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                                                .foregroundColor(isSelected ? .primary : .secondary)
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4.5)
                                        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 0.75)
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if AutoSwitchPolicy.distinctFamilyCount(for: draft.autoSwitchPolicy.monitoredBucketIDs) >= 2 {
                            HStack {
                                Text("Điều kiện chuyển:")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Picker("Điều kiện chuyển", selection: $draft.autoSwitchPolicy.triggerMatchMode) {
                                    ForEach(AutoSwitchTriggerMatchMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 210)
                            }
                        }

                        HStack(spacing: 6) {
                            Text("Kích hoạt khi còn ≤")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(draft.autoSwitchPolicy.triggerThresholdPercent)%")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .frame(width: 34, alignment: .trailing)
                            Stepper("", value: $draft.autoSwitchPolicy.triggerThresholdPercent, in: 5...50, step: 5)
                                .labelsHidden()
                        }

                        HStack(spacing: 6) {
                            Text("Acc dự phòng tối thiểu ≥")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(draft.autoSwitchPolicy.minBackupQuotaPercent)%")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .frame(width: 34, alignment: .trailing)
                            Stepper("", value: $draft.autoSwitchPolicy.minBackupQuotaPercent, in: 15...95, step: 5)
                                .labelsHidden()
                        }

                        Text(autoSwitchTriggerCaption)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    Text("Kích hoạt sớm Chu kỳ (Quota Warmup)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.secondary)

                    Toggle("Bật Warmup tự động (cả chu kỳ 5h & Tuần)", isOn: $draft.weeklyWarmupPolicy.isEnabled)
                        .font(.system(size: 12))

                    Toggle("Chỉ tài khoản dự phòng (bỏ qua acc đang dùng)", isOn: $draft.weeklyWarmupPolicy.backupAccountsOnly)
                        .font(.system(size: 11.5))

                    Toggle("Chỉ tự chạy chu kỳ 5h theo khung giờ hoạt động", isOn: $draft.weeklyWarmupPolicy.fiveHourActiveHoursOnly)
                        .font(.system(size: 11))

                    if draft.weeklyWarmupPolicy.fiveHourActiveHoursOnly {
                        HStack(spacing: 6) {
                            Text("Khung giờ 5h:")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                            Picker("Từ", selection: $draft.weeklyWarmupPolicy.fiveHourStartHour) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text(String(format: "%02d:00", hour)).tag(hour)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 72)

                            Text("đến")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)

                            Picker("Đến", selection: $draft.weeklyWarmupPolicy.fiveHourEndHour) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text(String(format: "%02d:00", hour)).tag(hour)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 72)
                            Spacer()
                        }
                    }

                    HStack(spacing: 12) {
                        Toggle("Gemini", isOn: $draft.weeklyWarmupPolicy.warmGemini)
                            .font(.system(size: 11.5))
                        Toggle("Claude/GPT", isOn: $draft.weeklyWarmupPolicy.warmClaude)
                            .font(.system(size: 11.5))
                    }

                    Text("1 lần Warmup tự động kích hoạt cả chu kỳ Tuần & 5h (request nhẹ maxOutputTokens=8; 5h tự bỏ qua khi quota Tuần ≤ 5%).")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button {
                            onSave(draft)
                            onRunManualWarmup()
                        } label: {
                            Label(
                                isRunningWarmup ? "Đang chạy Warmup..." : "Chạy Warmup ngay",
                                systemImage: "flame"
                            )
                            .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRunningWarmup || draft.weeklyWarmupPolicy.enabledGroups.isEmpty)

                        Spacer()
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Đường dẫn Antigravity.app")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("/Applications/Antigravity.app", text: $draft.agyAppBundlePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            HStack {
                Button(action: onOpenVault) {
                    Label("Mở Vault (~/.agy-switcher)", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Đóng", action: onClose)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(11)
        .background(Color.primary.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onAppear {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private var autoSwitchTriggerCaption: String {
        if AutoSwitchPolicy.distinctFamilyCount(for: draft.autoSwitchPolicy.monitoredBucketIDs) >= 2
            && draft.autoSwitchPolicy.triggerMatchMode == .allSelected {
            return "Chỉ tự động chuyển khi TẤT CẢ các nhóm model đã chọn đều cạn (mỗi nhóm cạn nếu 5h hoặc Tuần còn ≤ \(draft.autoSwitchPolicy.triggerThresholdPercent)%). Quét nền mỗi 20–45s."
        }
        return "Tự động chuyển khi 1 trong các mục đã chọn còn ≤ \(draft.autoSwitchPolicy.triggerThresholdPercent)% (hết 5h hay Tuần đều tự chuyển; quét nền mỗi 20–45s, bỏ qua acc Tạm tắt và cache cũ > 3 phút)."
    }

    private func toggleMonitoredBucket(_ bucketID: String) {
        var selected = draft.autoSwitchPolicy.monitoredBucketIDs
        if let existingIdx = selected.firstIndex(of: bucketID) {
            // Keep at least one monitored bucket selected.
            guard selected.count > 1 else { return }
            selected.remove(at: existingIdx)
        } else {
            selected.append(bucketID)
        }
        draft.autoSwitchPolicy.monitoredBucketIDs = selected
        if AutoSwitchPolicy.distinctFamilyCount(for: selected) < 2 {
            draft.autoSwitchPolicy.triggerMatchMode = .anySelected
        }
        syncModelScopeFromSelectedBuckets(selected)
    }

    private func applyAutoSwitchBucketPreset(scope: QuotaModelFilterScope) {
        let preset = availableAutoSwitchBuckets
            .map(\.id)
            .filter { scope.includes(modelID: $0) }
        draft.autoSwitchPolicy.monitoredBucketIDs = preset.isEmpty
            ? AutoSwitchPolicy.defaultBucketIDs(for: scope)
            : preset
        if AutoSwitchPolicy.distinctFamilyCount(for: draft.autoSwitchPolicy.monitoredBucketIDs) < 2 {
            draft.autoSwitchPolicy.triggerMatchMode = .anySelected
        }
        draft.autoSwitchPolicy.modelScope = scope
    }

    private func syncModelScopeFromSelectedBuckets(_ selected: [String]) {
        let hasThirdParty = selected.contains { QuotaModelFilterScope.isThirdPartyBucket($0) }
        let hasGoogle = selected.contains { !QuotaModelFilterScope.isThirdPartyBucket($0) }
        if hasThirdParty && hasGoogle {
            draft.autoSwitchPolicy.modelScope = .all
        } else if hasThirdParty {
            draft.autoSwitchPolicy.modelScope = .claudeOnly
        } else {
            draft.autoSwitchPolicy.modelScope = .geminiOnly
        }
    }

    private func saveAndClose() {
        draft.lowQuotaThresholdPercent = min(95, max(5, draft.lowQuotaThresholdPercent))
        onSave(draft)
        onClose()
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginStatus = nil
        } catch {
            launchAtLoginStatus = "Cần chạy từ file .app trong /Applications để bật Launch at Login."
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}
