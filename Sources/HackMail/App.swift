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
            CommandGroup(replacing: .printItem) {
                Button("Print Message…") { mailStore.printSelectedMessage() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(!mailStore.canPrintSelectedMessage)
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
    private static var baseApplicationIcon: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        let bundledIconURL = Bundle.main.url(forResource: "PirateMail", withExtension: "icns")
        let developmentIconURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Icons/PirateMail.icns")
        if let iconURL = bundledIconURL ?? (FileManager.default.fileExists(atPath: developmentIconURL.path) ? developmentIconURL : nil),
           let icon = NSImage(contentsOf: iconURL) {
            Self.baseApplicationIcon = icon
            NSApp.applicationIconImage = icon
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        OpenedAttachmentFiles.cleanup()
    }

    static func updateDockBadge(unreadCount: Int) {
        guard let baseIcon = baseApplicationIcon ?? NSApp.applicationIconImage else { return }
        if baseApplicationIcon == nil {
            baseApplicationIcon = baseIcon
        }
        NSApp.dockTile.badgeLabel = nil
        NSApp.applicationIconImage = DockBadgeIconRenderer.image(baseIcon: baseIcon, unreadCount: unreadCount)
        NSApp.dockTile.display()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

private enum DockBadgeIconRenderer {
    static func image(baseIcon: NSImage, unreadCount: Int) -> NSImage {
        guard unreadCount > 0 else { return baseIcon }

        let iconSize = baseIcon.size
        let image = NSImage(size: iconSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        let iconBounds = CGRect(origin: .zero, size: iconSize)
        baseIcon.draw(in: iconBounds, from: .zero, operation: .copy, fraction: 1)

        let diameter = min(iconSize.width, iconSize.height) * 0.39
        let label = unreadCount > 99 ? "99+" : String(unreadCount)
        let badgeWidth = label.count > 2 ? diameter * 1.4 : diameter
        let badgeRect = CGRect(
            x: iconSize.width - badgeWidth - diameter * 0.02,
            y: iconSize.height - diameter - diameter * 0.02,
            width: badgeWidth,
            height: diameter
        )
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: diameter / 2, yRadius: diameter / 2)
        NSColor.systemRed.setFill()
        badgePath.fill()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        badgePath.lineWidth = max(1, diameter * 0.045)
        badgePath.stroke()

        let fontSize = diameter * (label.count > 2 ? 0.43 : 0.52)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let text = label as NSString
        let textSize = text.size(withAttributes: attributes)
        let textRect = CGRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)
        return image
    }
}
