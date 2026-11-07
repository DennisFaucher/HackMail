import SwiftUI
import AppKit
import UserNotifications

@main
struct HackMailApp: App {
    @NSApplicationDelegateAdaptor(HackMailAppDelegate.self) private var appDelegate
    @StateObject private var mailStore = MailStore()

    var body: some Scene {
        WindowGroup {
            MailWindow()
                .environmentObject(mailStore)
                .frame(minWidth: 940, minHeight: 620)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { mailStore.beginNewMessage() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button("Mail Accounts…") { mailStore.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class HackMailAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        let bundledIconURL = Bundle.main.url(forResource: "PirateMail", withExtension: "icns")
        let developmentIconURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Icons/PirateMail.icns")
        if let iconURL = bundledIconURL ?? (FileManager.default.fileExists(atPath: developmentIconURL.path) ? developmentIconURL : nil),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
