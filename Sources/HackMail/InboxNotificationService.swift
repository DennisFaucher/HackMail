import UserNotifications

enum InboxNotificationService {
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    static func postNewMessages(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "New email"
        content.body = count == 1
            ? "A new message arrived in one of your Inboxes."
            : "\(count) new messages arrived in one of your Inboxes."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "HackMail.Inbox.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
