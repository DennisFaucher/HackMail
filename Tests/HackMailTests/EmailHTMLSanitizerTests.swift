import XCTest
@testable import HackMail

final class EmailHTMLSanitizerTests: XCTestCase {
    private func web(_ html: String, remote: Bool = false) -> String {
        EmailHTMLSanitizer.forWebView(html, allowRemoteImages: remote)
    }

    private func outgoing(_ html: String, remote: Bool = false) -> String {
        EmailHTMLSanitizer.forOutgoingMessage(html, allowRemoteImages: remote)
    }

    private func assertAbsent(_ needles: [String], in output: String, file: StaticString = #filePath, line: UInt = #line) {
        let lowered = output.lowercased()
        for needle in needles {
            XCTAssertFalse(lowered.contains(needle.lowercased()), "Found \(needle) in: \(output)", file: file, line: line)
        }
    }

    // MARK: Active content

    func testRemovesScriptsAndEventHandlers() {
        let out = web(#"<p onclick="x()" ONMOUSEOVER=y()>Hi</p><script>alert(1)</script><img src="cid:a" onerror="z()">"#)
        assertAbsent(["<script", "alert(1)", "onclick", "onmouseover", "onerror"], in: out)
        XCTAssertTrue(out.contains("Hi"))
    }

    func testRemovesEmbeddedAndFormElements() {
        let out = web("<iframe src=x></iframe><object data=x></object><embed src=x><svg><script>1</script></svg><math></math><input name=a><button>b</button><textarea>t</textarea><base href=//evil><link rel=stylesheet href=//evil><video src=x></video>")
        assertAbsent(["<iframe", "<object", "<embed", "<svg", "<math", "<input", "<button", "<textarea", "<base", "<link", "<video"], in: out)
    }

    func testFormIsUnwrappedButContentKept() {
        let out = web(#"<form action="https://evil/post"><p>Keep me</p><input name=x></form>"#)
        assertAbsent(["<form", "action", "<input", "evil"], in: out)
        XCTAssertTrue(out.contains("Keep me"))
    }

    func testEntityEncodedJavaScriptSchemeIsRemoved() {
        for href in ["java&#115;cript:alert(1)", "JaVa&#x73;cript:alert(1)", " \tjava\nscript:alert(1)", "vbscript:x", "data:text/html,<script>1</script>"] {
            let out = web(#"<a href="\#(href)">x</a>"#)
            assertAbsent(["javascript", "vbscript", "data:text/html", "alert(1)"], in: out)
        }
    }

    func testSafeLinksSurvive() {
        let out = web(##"<a href="https://example.com/a?b=1&amp;c=2">a</a><a href="mailto:a@b.co">m</a><a href="#top">t</a>"##)
        XCTAssertTrue(out.contains("https://example.com/a?b=1&amp;c=2") || out.contains("https://example.com/a?b=1&c=2"))
        XCTAssertTrue(out.contains("mailto:a@b.co"))
        XCTAssertTrue(out.contains("#top"))
    }

    func testCommentsAndConditionalCommentsAreRemoved() {
        let out = web("<p>a</p><!-- secret --><!--[if mso]><script>alert(1)</script><![endif]-->")
        assertAbsent(["secret", "<!--", "alert(1)"], in: out)
    }

    func testNoscriptMutationVectorIsNeutralized() {
        let out = web(#"<noscript><p title="</noscript><img src=x onerror=alert(1)>"></p></noscript>"#)
        assertAbsent(["onerror", "<noscript"], in: out)
        XCTAssertFalse(out.contains("<img"))
    }

    // MARK: CSP and document shape

    func testMessageCannotReplaceOrPrecedeOurCSP() {
        let hostile = #"<html><head><meta http-equiv="Content-Security-Policy" content="default-src *"><base href="https://evil/"></head><body>x</body></html>"#
        let out = web(hostile)
        XCTAssertFalse(out.contains("default-src *"))
        XCTAssertFalse(out.lowercased().contains("<base"))
        let cspRange = out.range(of: "Content-Security-Policy")
        let headRange = out.range(of: "<head>")
        XCTAssertNotNil(cspRange)
        XCTAssertNotNil(headRange)
        if let cspRange, let headRange {
            XCTAssertLessThan(headRange.upperBound, cspRange.lowerBound)
        }
        XCTAssertEqual(out.components(separatedBy: "Content-Security-Policy").count, 2, "Exactly one CSP expected")
    }

    func testCSPRestrictsImagesUnlessRemoteAllowed() {
        XCTAssertTrue(web("<p>x</p>").contains("img-src data:;"))
        XCTAssertTrue(web("<p>x</p>", remote: true).contains("img-src data: http: https:;"))
        XCTAssertTrue(web("<p>x</p>").contains("default-src 'none'"))
    }

    func testFragmentsAndEmptyInputProduceAWellFormedDocument() {
        let out = web("just text & <b>bold")
        XCTAssertTrue(out.hasPrefix("<!doctype html>"))
        XCTAssertTrue(out.contains("just text &amp; <b>bold</b>"))
        let empty = web("")
        XCTAssertTrue(empty.contains("Content-Security-Policy"))
    }

    func testVoidElementsAreNotDoubled() {
        let out = web("<p>a<br>b</p><img src=\"cid:x\">")
        XCTAssertFalse(out.contains("</br>"))
        XCTAssertFalse(out.contains("</img>"))
    }

    func testUnicodeSurvives() {
        let out = web("<p>é 😀 日本</p>")
        XCTAssertTrue(out.contains("é 😀 日本"))
    }

    func testOversizedInputFallsBackToEscapedText() {
        let big = "<script>alert(1)</script>" + String(repeating: "a", count: 9 * 1024 * 1024)
        let out = web(big)
        XCTAssertFalse(out.contains("<script"))
        XCTAssertTrue(out.contains("&lt;script&gt;"))
    }

    // MARK: Images and CSS

    func testRemoteImageSourcesRemovedUnlessAllowed() {
        let html = #"<img src="https://t.example/p.gif"><img src="//t.example/q.gif"><img src="http://t.example/r.gif" srcset="https://t.example/s.gif 2x"><table background="https://t.example/b.png"></table>"#
        assertAbsent(["t.example"], in: web(html))
        assertAbsent(["t.example"], in: outgoing(html))
        let allowed = web(html, remote: true)
        XCTAssertTrue(allowed.contains("https://t.example/p.gif"))
        XCTAssertFalse(allowed.contains("srcset"))
    }

    func testInlineAndCIDImagesAlwaysSurvive() {
        let html = #"<img src="cid:logo"><img src="data:image/png;base64,AAAA">"#
        let out = outgoing(html)
        XCTAssertTrue(out.contains("cid:logo"))
        XCTAssertTrue(out.contains("data:image/png;base64,AAAA"))
        XCTAssertFalse(outgoing(#"<img src="data:text/html;base64,AAAA">"#).contains("data:text/html"))
    }

    func testCSSUrlsAndImportsAreNeutralized() {
        let html = #"<style>@import url(https://t.example/x.css); .a{background:url('https://t.example/a.png') no-repeat;color:red}.b{background:url(data:image/png;base64,AAAA)}.c{width:expression(alert(1))}</style><div style="background-image:url(//t.example/b.png);color:blue">x</div>"#
        let out = outgoing(html)
        assertAbsent(["t.example", "@import", "expression"], in: out)
        XCTAssertTrue(out.contains("color:red"))
        XCTAssertTrue(out.contains("color:blue"))
        XCTAssertTrue(out.contains("data:image/png;base64,AAAA"))
    }

    func testEscapedCSSUrlIsDroppedWhenRemoteDisallowed() {
        let out = outgoing(#"<div style="background:u\72l(https://t.example/a.png)">x</div>"#)
        assertAbsent(["t.example"], in: out)
    }

    func testStyleElementChildSelectorsAreNotEscaped() {
        let out = web("<style>td > p { color: red }</style><td><p>x</p></td>")
        XCTAssertTrue(out.contains("td > p"), out)
    }

    // MARK: Integration with body extraction

    func testOutgoingFragmentDropsActiveContent() {
        let html = #"<html><head><style>p{color:red}</style></head><body><p onclick="x()">Hello</p><script>1</script></body></html>"#
        let fragment = EmailHTMLSanitizer.bodyFragment(outgoing(html))
        XCTAssertTrue(fragment.contains("Hello"))
        assertAbsent(["<script", "onclick", "<body", "<html"], in: fragment)
    }
}
