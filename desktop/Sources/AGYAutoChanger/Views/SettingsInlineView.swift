import ServiceManagement
import SwiftUI

// MARK: - Inline Settings View

/// Settings panel embedded inside the Menu Bar popover for bundle path, Keychain fallback, and Launch at Login.
struct SettingsInlineView: View {
    let settings: SwitcherSettings
    let onSave: (SwitcherSettings) -> Void
    let onOpenVault: () -> Void
    let onClose: () -> Void

    @State private var draft: SwitcherSettings
    @State private var launchAtLogin: Bool = false
    @State private var launchAtLoginStatus: String?

    init(
        settings: SwitcherSettings,
        onSave: @escaping (SwitcherSettings) -> Void,
        onOpenVault: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.settings = settings
        self.onSave = onSave
        self.onOpenVault = onOpenVault
        self.onClose = onClose
        _draft = State(initialValue: settings)
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

                Toggle("Đồng bộ thêm Antigravity IDE (nếu có dùng)", isOn: $draft.syncIDESession)
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

    private func saveAndClose() {
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
