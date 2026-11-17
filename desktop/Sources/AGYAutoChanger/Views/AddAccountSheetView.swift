import SwiftUI

// MARK: - Add Account Mode

enum AddAccountMode: String, CaseIterable, Identifiable {
    case captureCurrent = "Lưu phiên hiện tại"
    case loginNewAccount = "Đăng nhập acc mới"

    var id: String { rawValue }
}

// MARK: - Add Account Sheet View

/// Inline panel for saving the live Antigravity session or launching a clean login flow for another account.
struct AddAccountSheetView: View {
    let detectedEmail: String?
    let detectedTier: AccountTier?
    let onCaptureCurrent: (String, String, AccountTier) -> Void
    let onStartNewLogin: (String, String, AccountTier) -> Void
    let onCancel: () -> Void

    @State private var mode: AddAccountMode = .loginNewAccount
    @State private var displayName: String = ""
    @State private var email: String = ""
    @State private var tier: AccountTier = .pro

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Text(modeDescription)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
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
                        detectedTier != nil
                            ? "Mục này dùng để tính hạn mức Quota theo gói. Đã tự nhận từ acc: \(detectedTier?.badgeTitle ?? "")."
                            : "Mục này dùng để ước lượng hạn mức Quota 5h của acc (tự cập nhật nếu AGY lưu userTier)."
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
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
                        Image(systemName: mode == .captureCurrent ? "camera.fill" : "arrow.right.circle.fill")
                        Text(mode == .captureCurrent ? "Lưu phiên đang mở" : "Mở AGY để đăng nhập")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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
    }

    private var modeDescription: String {
        switch mode {
        case .captureCurrent:
            return "Đóng gói phiên Antigravity hiện đang mở thành 1 hồ sơ để chuyển đổi lại chỉ với 1 click."
        case .loginNewAccount:
            return "App sẽ tự lưu phiên hiện tại, dọn trạng thái đăng nhập cũ và mở lại Antigravity để bạn đăng nhập tài khoản mới 1 lần duy nhất."
        }
    }

    private func submit() {
        let resolvedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .captureCurrent:
            onCaptureCurrent(displayName, resolvedEmail.isEmpty ? (detectedEmail ?? "") : resolvedEmail, tier)
        case .loginNewAccount:
            onStartNewLogin(displayName, resolvedEmail, tier)
        }
    }
}
