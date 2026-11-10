import AppKit
import WebKit

/// Builds the HTML used to print a single received message.
///
/// The body always goes through `EmailHTMLSanitizer`, so printing follows the same rules as the reader:
/// no scripts, our CSP, and remote images only if the user already allowed them for this message.
enum MessagePrintDocument {
    static func html(for message: MailMessage, mailboxName: String?) -> String {
        let bodyHTML = message.bodyIsHTML
            ? message.body
            : "<pre style=\"white-space: pre-wrap; font: inherit; margin: 0;\">\(EmailHTMLSanitizer.escapeText(message.body))</pre>"
        var document = EmailHTMLSanitizer.forWebView(bodyHTML, allowRemoteImages: message.allowsRemoteImages)
        let header = headerHTML(for: message, mailboxName: mailboxName)

        // The header goes first inside <body>; the print stylesheet goes last in <head> so it wins.
        if let body = document.range(of: #"<body[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            document.insert(contentsOf: header, at: body.upperBound)
        }
        if let headEnd = document.range(of: "</head>", options: [.caseInsensitive]) {
            document.insert(contentsOf: printStyle, at: headEnd.lowerBound)
        }
        return document
    }

    private static let printStyle = """
    <style>
    @media print { body { padding: 0 !important; } }
    html, body { background: #fff !important; color: #000 !important; }
    .hackmail-print-header { border-bottom: 1px solid #999; margin: 0 0 16px; padding: 0 0 10px; font: 12px/1.5 -apple-system, sans-serif; color: #000; }
    .hackmail-print-header h1 { font-size: 18px; line-height: 1.3; margin: 0 0 8px; }
    .hackmail-print-header table { border-collapse: collapse; max-width: none; }
    .hackmail-print-header th { text-align: left; font-weight: 600; padding: 0 12px 0 0; vertical-align: top; white-space: nowrap; }
    .hackmail-print-header td { padding: 0; }
    img { max-width: 100% !important; }
    </style>
    """

    private static func headerHTML(for message: MailMessage, mailboxName: String?) -> String {
        func row(_ label: String, _ value: String) -> String {
            "<tr><th>\(label)</th><td>\(EmailHTMLSanitizer.escapeText(value))</td></tr>"
        }
        let from = message.senderEmail.isEmpty ? message.sender : "\(message.sender) <\(message.senderEmail)>"
        var rows = [row("From:", from)]
        if !message.toRecipients.isEmpty { rows.append(row("To:", message.toRecipients.map(\.display).joined(separator: ", "))) }
        if !message.ccRecipients.isEmpty { rows.append(row("Cc:", message.ccRecipients.map(\.display).joined(separator: ", "))) }
        if !message.bccRecipients.isEmpty { rows.append(row("Bcc:", message.bccRecipients.map(\.display).joined(separator: ", "))) }
        rows.append(row("Date:", dateText(for: message)))
        if let mailboxName, !mailboxName.isEmpty { rows.append(row("Folder:", mailboxName)) }
        if !message.attachments.isEmpty {
            let names = message.attachments.map {
                "\($0.fileName) (\(ByteCountFormatter.string(fromByteCount: Int64($0.encodedSize), countStyle: .file)))"
            }
            rows.append(row("Attachments:", names.joined(separator: ", ")))
        }
        let subject = message.subject.isEmpty ? "(no subject)" : message.subject
        return "<div class=\"hackmail-print-header\"><h1>\(EmailHTMLSanitizer.escapeText(subject))</h1><table>\(rows.joined())</table></div>"
    }

    private static func dateText(for message: MailMessage) -> String {
        guard let date = message.sortDate else { return message.time }
        return date.formatted(date: .complete, time: .shortened)
    }
}

/// Prints a message through the standard macOS print panel using an off-screen, JavaScript-disabled,
/// non-persistent web view.
@MainActor
final class MessagePrinter: NSObject, WKNavigationDelegate {
    static let shared = MessagePrinter()

    private var webView: WKWebView?
    private var isPrinting = false

    func print(_ message: MailMessage, mailboxName: String?) {
        guard !isPrinting else { return }
        isPrinting = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        view.loadHTMLString(MessagePrintDocument.html(for: message, mailboxName: mailboxName), baseURL: nil)
    }

    private func finish() {
        webView?.navigationDelegate = nil
        webView = nil
        isPrinting = false
    }

    private func presentPrintPanel(for webView: WKWebView) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // WebKit prints blank pages unless the print view has an explicit size.
        let printableWidth = info.paperSize.width - info.leftMargin - info.rightMargin
        let printableHeight = info.paperSize.height - info.topMargin - info.bottomMargin
        operation.view?.frame = NSRect(x: 0, y: 0, width: printableWidth, height: printableHeight)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(
                for: window,
                delegate: self,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        } else {
            operation.run()
            finish()
        }
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        finish()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        presentPrintPanel(for: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.allowsContentJavaScript = false
        // Only the in-memory document may load; nothing in a message may navigate the print view.
        if navigationAction.request.url?.scheme == "about" || navigationAction.request.url == nil {
            return (.allow, preferences)
        }
        return (.cancel, preferences)
    }
}
