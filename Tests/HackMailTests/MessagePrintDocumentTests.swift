import XCTest
@testable import HackMail

final class MessagePrintDocumentTests: XCTestCase {
    private func message(
        subject: String = "Hello",
        body: String = "Body text",
        html: Bool = false,
        remote: Bool = false,
        attachments: [MailAttachmentInfo] = []
    ) -> MailMessage {
        MailMessage(
            id: 1, sender: "Alice", senderEmail: "alice@example.com", time: "Nov 6", subject: subject,
            preview: "", body: body, bodyIsHTML: html, allowsRemoteImages: remote, attachments: attachments
        )
    }

    func testHeaderShowsSubjectSenderAndFolder() {
        let out = MessagePrintDocument.html(for: message(), mailboxName: "INBOX")
        XCTAssertTrue(out.contains("<h1>Hello</h1>"))
        XCTAssertTrue(out.contains("Alice &lt;alice@example.com&gt;"))
        XCTAssertTrue(out.contains("INBOX"))
        XCTAssertTrue(out.contains("Nov 6"))
    }

    func testHeaderValuesAreEscaped() {
        let hostile = message(subject: "<script>alert(1)</script> & <img src=x onerror=1>")
        let out = MessagePrintDocument.html(for: hostile, mailboxName: "<b>Folder</b>")
        XCTAssertFalse(out.contains("<script"))
        XCTAssertFalse(out.contains("<img src=x"))
        XCTAssertFalse(out.contains("<b>Folder</b>"))
        XCTAssertTrue(out.contains("&lt;script&gt;"))
    }

    func testPlainTextBodyIsEscapedAndWrapped() {
        let out = MessagePrintDocument.html(for: message(body: "a <b>not bold</b> & more\nsecond line"), mailboxName: nil)
        XCTAssertTrue(out.contains("a &lt;b&gt;not bold&lt;/b&gt; &amp; more"))
        XCTAssertFalse(out.contains("<b>not bold</b>"))
        XCTAssertTrue(out.contains("white-space: pre-wrap"))
    }

    func testHTMLBodyIsSanitized() {
        let html = #"<html><head><style>p{color:red}</style></head><body><p onclick="x()">Hi</p><script>alert(1)</script></body></html>"#
        let out = MessagePrintDocument.html(for: message(body: html, html: true), mailboxName: nil)
        XCTAssertTrue(out.contains("Hi"))
        XCTAssertFalse(out.contains("<script"))
        XCTAssertFalse(out.contains("onclick"))
    }

    func testRemoteImagesFollowTheMessageOptIn() {
        let html = #"<img src="https://t.example/p.gif">"#
        XCTAssertFalse(MessagePrintDocument.html(for: message(body: html, html: true, remote: false), mailboxName: nil).contains("t.example"))
        XCTAssertTrue(MessagePrintDocument.html(for: message(body: html, html: true, remote: true), mailboxName: nil).contains("https://t.example/p.gif"))
    }

    func testHeaderPrecedesBodyAndPrintStyleIsLastInHead() throws {
        let out = MessagePrintDocument.html(for: message(body: "<p>Content</p>", html: true), mailboxName: nil)
        let header = try XCTUnwrap(out.range(of: "hackmail-print-header\""))
        let content = try XCTUnwrap(out.range(of: "<p>Content"))
        XCTAssertLessThan(header.lowerBound, content.lowerBound)
        let style = try XCTUnwrap(out.range(of: ".hackmail-print-header {"))
        let headEnd = try XCTUnwrap(out.range(of: "</head>"))
        XCTAssertLessThan(style.lowerBound, headEnd.lowerBound)
        XCTAssertEqual(out.components(separatedBy: "Content-Security-Policy").count, 2, "Exactly one CSP expected")
    }

    func testAttachmentsAreListedByNameAndSizeOnly() {
        let attachment = MailAttachmentInfo(section: "2", fileName: "report.pdf", mimeType: "application/pdf", encodedSize: 2048, transferEncoding: "base64")
        let out = MessagePrintDocument.html(for: message(attachments: [attachment]), mailboxName: nil)
        XCTAssertTrue(out.contains("report.pdf"))
        XCTAssertTrue(out.contains("Attachments:"))
    }

    func testEmptySubjectGetsPlaceholder() {
        XCTAssertTrue(MessagePrintDocument.html(for: message(subject: ""), mailboxName: nil).contains("(no subject)"))
    }
}
