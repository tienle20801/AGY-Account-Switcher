import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Add Account Mode

enum AddAccountMode: String, CaseIterable, Identifiable {
    case captureCurrent = "Lưu phiên hiện tại"
    case loginNewAccount = "Đăng nhập mới"
    case importTokenOrJSON = "Nạp Token / JSON"

    var id: String { rawValue }
}

// MARK: - Add Account Sheet View

/// Inline panel for saving the live Antigravity session, launching a clean login flow, or importing a token/JSON.
struct AddAccountSheetView: View {
    let detectedEmail: String?
    let detectedTier: AccountTier?
    let onCaptureCurrent: (String, String, AccountTier, String) -> Void
    let onStartNewLogin: (String, String, AccountTier, String) -> Void
    let onImportTokenOrJSON: (String, String, AccountTier, String, String) -> Void
    let onCancel: () -> Void

    @State private var mode: AddAccountMode = .loginNewAccount
    @State private var displayName: String = ""
    @State private var email: String = ""
    @State private var remark: String = ""
    @State private var tier: AccountTier = .pro
    @State private var tokenOrJSONInput: String = ""
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Thêm tài khoản Antigravity")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Picker("Chế độ", selection: $mode) {
                ForEach(AddAccountMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            Text(modeDescription)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                if mode == .importTokenOrJSON {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Refresh Token hoặc JSON")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                pickJSONFile()
                            } label: {
                                Label("Chọn file JSON...", systemImage: "doc.badge.plus")
                                    .font(.system(size: 10.5))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }

                        TextField(
                            "Dán Refresh Token (1//...) hoặc nội dung JSON...",
                            text: $tokenOrJSONInput,
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2...4)
                    }
                }

                TextField("Tên gợi nhớ (vd: Acc Work, Acc Backup)", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                TextField(
                    mode == .captureCurrent && detectedEmail != nil
                        ? "Email (tự nhận: \(detectedEmail ?? ""))"
                        : "Email tài khoản (tùy chọn)",
                    text: $email
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

                TextField("Ghi chú (tùy chọn, vd: Acc Work, Dự phòng)", text: $remark)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gói tài khoản:")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("Gói", selection: $tier) {
                            ForEach(AccountTier.allCases) { item in
                                Text(item.badgeTitle).tag(item)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 175)
                    }

                    Text(
                        detectedTier != nil && mode != .importTokenOrJSON
                            ? "Mục này dùng để tính hạn mức Quota theo gói. Đã tự nhận từ acc: \(detectedTier?.badgeTitle ?? "")."
                            : "Mục này dùng để ước lượng hạn mức Quota theo gói (tự cập nhật khi đồng bộ)."
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let validationError {
                Text(validationError)
                    .font(.system(size: 10.5))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Hủy", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer()

                Button {
                    submit()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: submitIconName)
                        Text(submitButtonTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(mode == .importTokenOrJSON && tokenOrJSONInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(11)
        .background(Color.primary.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onAppear {
            if let detectedTier {
                tier = detectedTier
            }
            if mode == .captureCurrent, email.isEmpty, let detectedEmail {
                email = detectedEmail
            }
        }
        .onChange(of: mode) { _ in
            validationError = nil
        }
    }

    private var modeDescription: String {
        switch mode {
        case .captureCurrent:
            return "Đóng gói phiên Antigravity hiện đang mở thành 1 hồ sơ để chuyển đổi lại chỉ với 1 click."
        case .loginNewAccount:
            return "App sẽ tự lưu phiên hiện tại, dọn trạng thái đăng nhập cũ và mở lại Antigravity để bạn đăng nhập tài khoản mới 1 lần duy nhất."
        case .importTokenOrJSON:
            return "Nạp trực tiếp từ Refresh Token hoặc file JSON backup mà không cần tắt hay đăng xuất Antigravity."
        }
    }

    private var submitIconName: String {
        switch mode {
        case .captureCurrent: return "camera.fill"
        case .loginNewAccount: return "arrow.right.circle.fill"
        case .importTokenOrJSON: return "tray.and.arrow.down.fill"
        }
    }

    private var submitButtonTitle: String {
        switch mode {
        case .captureCurrent: return "Lưu phiên đang mở"
        case .loginNewAccount: return "Mở AGY để đăng nhập"
        case .importTokenOrJSON: return "Nạp tài khoản"
        }
    }

    private func pickJSONFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Chọn file tài khoản JSON"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                tokenOrJSONInput = try String(contentsOf: url, encoding: .utf8)
                validationError = nil
            } catch {
                validationError = "Không thể đọc file: \(error.localizedDescription)"
            }
        }
    }

    private func submit() {
        let resolvedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .captureCurrent:
            onCaptureCurrent(displayName, resolvedEmail.isEmpty ? (detectedEmail ?? "") : resolvedEmail, tier, remark)
        case .loginNewAccount:
            onStartNewLogin(displayName, resolvedEmail, tier, remark)
        case .importTokenOrJSON:
            let raw = tokenOrJSONInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                validationError = "Vui lòng dán Refresh Token hoặc chọn file JSON."
                return
            }
            onImportTokenOrJSON(displayName, resolvedEmail, tier, remark, raw)
        }
    }
}
