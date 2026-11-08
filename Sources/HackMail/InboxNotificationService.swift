import UserNotifications

enum InboxNotificationService {
    static func notificationBody(subjects: [String], additionalCount: Int) -> String {
        let subject = subjects.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !subject.isEmpty else { return "New mail has arrived in one of your Inboxes." }
        let trimmedSubject = String(subject.prefix(140)) + (subject.count > 140 ? "…" : "")
        return additionalCount > 0 ? "\(trimmedSubject) (+\(additionalCount) more)" : trimmedSubject
    }

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

    static func postNewMail(subjects: [String], additionalCount: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "New email"
        content.body = notificationBody(subjects: subjects, additionalCount: additionalCount)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "HackMail.Inbox.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
