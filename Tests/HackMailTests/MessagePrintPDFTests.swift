import XCTest
import WebKit
import PDFKit
@testable import HackMail

@MainActor
/// Renders a message through the same WebKit print path to a PDF, guarding against blank printed pages.
final class MessagePrintPDFTests: XCTestCase {
    final class Loader: NSObject, WKNavigationDelegate {
        var done: (() -> Void)?
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done?() }
    }
    func testMessagePrintsToNonBlankPDF() async throws {
        let m = MailMessage(id:1,sender:"Alice",senderEmail:"a@b.co",time:"Nov 6",subject:"Quarterly report",preview:"",body:"<p>Hello printed world</p>",bodyIsHTML:true)
        let html = MessagePrintDocument.html(for: m, mailboxName: "INBOX")
        let view = WKWebView(frame: NSRect(x:0,y:0,width:612,height:792))
        let loader = Loader(); view.navigationDelegate = loader
        await withCheckedContinuation { (c: CheckedContinuation<Void,Never>) in
            loader.done = { c.resume() }
            view.loadHTMLString(html, baseURL: nil)
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hackmail-print-test.pdf")
        try? FileManager.default.removeItem(at: url)
        let info = NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let op = view.printOperation(with: info)
        op.showsPrintPanel = false; op.showsProgressPanel = false
        op.view?.frame = NSRect(x:0,y:0,width:504,height:684)
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool,Never>) in
            final class D: NSObject { var c: CheckedContinuation<Bool,Never>?; @objc func d(_ o: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) { c?.resume(returning: success) } }
            let d = D(); d.c = c
            objc_setAssociatedObject(op, "d", d, .OBJC_ASSOCIATION_RETAIN)
            op.runModal(for: NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true), delegate: d, didRun: #selector(D.d(_:success:contextInfo:)), contextInfo: nil)
        }
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(pdf.string?.contains("Hello printed world") == true)
        XCTAssertTrue(pdf.string?.contains("Quarterly report") == true); XCTAssertTrue(pdf.string?.contains("Alice") == true, pdf.string ?? "")
    }
}
