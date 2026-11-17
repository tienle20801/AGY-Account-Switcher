import Foundation
import UserNotifications

// MARK: - Quota Threshold Notifier

/// Sends a deduplicated macOS notification when Argon or Gemini remaining quota hits `<= 30%`.
@MainActor
public final class QuotaThresholdNotifier: NSObject, UNUserNotificationCenterDelegate {

    public typealias NotificationSender = @MainActor (_ title: String, _ body: String, _ identifier: String) -> Void

    private static let monitoredModelIDs: Set<String> = [
        "argon-weekly",
        "gemini-5h",
        "gemini-weekly"
    ]

    private let thresholdPercent: Int
    private let sendNotification: NotificationSender
    private var sentAlertKeys: [String: String] = [:] // "\(accountID)|\(modelID)" -> resetWindowKey
    private var didConfigureAuthorization = false

    public init(
        thresholdPercent: Int = AppConfig.lowQuotaAlertThresholdPercent,
        sendNotification: NotificationSender? = nil
    ) {
        self.thresholdPercent = thresholdPercent
        if let sendNotification {
            self.sendNotification = sendNotification
        } else {
            self.sendNotification = { title, body, identifier in
                Self.postSystemNotification(title: title, body: body, identifier: identifier)
            }
        }
        super.init()
    }

    public func requestAuthorizationIfNeeded() {
        guard Self.isPackagedAppBundle, !didConfigureAuthorization else { return }
        didConfigureAuthorization = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Checks active account's Argon & Gemini buckets and fires once per reset window when `<= thresholdPercent`.
    public func evaluateAndNotify(for accounts: [AccountProfile]) {
        guard let activeAccount = accounts.first(where: { $0.isActive }) else { return }

        for usage in activeAccount.modelUsages where Self.monitoredModelIDs.contains(usage.id) {
            let scopeKey = "\(activeAccount.id.uuidString)|\(usage.id)"
            let remaining = usage.remainingPercentageInt

            if remaining > thresholdPercent {
                sentAlertKeys.removeValue(forKey: scopeKey)
                continue
            }

            let windowKey = Self.resetWindowKey(for: usage.quotaResetAt)
            if sentAlertKeys[scopeKey] == windowKey {
                continue
            }

            sentAlertKeys[scopeKey] = windowKey

            let resetDetail = usage.remainingResetLabel().map { " · Làm mới sau \($0)" } ?? ""
            let title = "Cảnh báo Quota \(usage.shortLabel) còn \(remaining)%"
            let body = "\(activeAccount.displayName): \(usage.displayName) đã chạm ngưỡng ≤ \(thresholdPercent)%\(resetDetail)."
            let identifier = "agy-quota-low-\(activeAccount.id.uuidString)-\(usage.id)-\(windowKey)"
            sendNotification(title, body, identifier)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Helpers

    private static var isPackagedAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private static func resetWindowKey(for resetDate: Date?) -> String {
        guard let resetDate else { return "no-reset" }
        // Bucket by minute so minor server jitter does not re-trigger the same window.
        let minuteBucket = Int(resetDate.timeIntervalSince1970 / 60.0)
        return String(minuteBucket)
    }

    private static func postSystemNotification(title: String, body: String, identifier: String) {
        guard isPackagedAppBundle else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
