import Foundation

// MARK: - Account Switch Lifecycle State

/// Represents the real-time step during an automated 1-click account switch.
public enum SwitchPhase: Equatable, Sendable {
    case idle
    case backingUpCurrent(String)
    case terminatingAGY
    case restoringSnapshot(String)
    case relaunchingAGY
    case awaitingNewLogin(String)
    case completed(String)
    case failed(String)

    public var isInProgress: Bool {
        switch self {
        case .backingUpCurrent, .terminatingAGY, .restoringSnapshot, .relaunchingAGY:
            return true
        case .idle, .awaitingNewLogin, .completed, .failed:
            return false
        }
    }

    public var progress: Double {
        switch self {
        case .idle: return 0.0
        case .backingUpCurrent: return 0.20
        case .terminatingAGY: return 0.45
        case .restoringSnapshot: return 0.72
        case .relaunchingAGY: return 0.90
        case .awaitingNewLogin: return 0.95
        case .completed: return 1.0
        case .failed: return 0.0
        }
    }

    public var statusMessage: String {
        switch self {
        case .idle:
            return ""
        case .backingUpCurrent(let name):
            return "Đang sao lưu phiên của \(name)..."
        case .terminatingAGY:
            return "Đang đóng Antigravity an toàn..."
        case .restoringSnapshot(let name):
            return "Đang nạp phiên cho \(name)..."
        case .relaunchingAGY:
            return "Đang khởi động lại Antigravity..."
        case .awaitingNewLogin(let name):
            return "Hãy đăng nhập \"\(name)\" trên Antigravity, app sẽ tự động lưu."
        case .completed(let name):
            return "Đã chuyển sang \(name) — sẵn sàng tiếp tục!"
        case .failed(let reason):
            return "Lỗi: \(reason)"
        }
    }
}
