import Foundation

enum EmailHTMLSanitizer {
    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func bodyFragment(_ html: String) -> String {
        let nsHTML = html as NSString
        guard let bodyStartRegex = try? NSRegularExpression(pattern: #"(?i)<body\b[^>]*>"#),
              let bodyEndRegex = try? NSRegularExpression(pattern: #"(?i)</body\s*>"#),
              let bodyStart = bodyStartRegex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)) else {
            return html
        }
        let contentStart = NSMaxRange(bodyStart.range)
        let closingMatches = bodyEndRegex.matches(in: html, range: NSRange(location: contentStart, length: nsHTML.length - contentStart))
        guard let bodyEnd = closingMatches.first else { return html }
        return nsHTML.substring(with: NSRange(location: contentStart, length: bodyEnd.range.location - contentStart))
    }

    static func forWebView(_ source: String, allowRemoteImages: Bool) -> String {
        let clean = sanitizedDocument(source, allowRemoteImages: allowRemoteImages)
        let imageSources = allowRemoteImages ? "data: http: https:" : "data:"
        let head = """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(imageSources); style-src 'unsafe-inline'; font-src data:;">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body { margin: 0; padding: 4px; color: #2b2217; font: 15px/1.6 'Atkinson Hyperlegible', -apple-system, sans-serif; overflow-wrap: anywhere; }
        img { max-width: 100%; height: auto; }
        table { max-width: 100%; }
        </style>
        """
        // The sanitizer always emits a single `<head>` with no attributes, so this is the first element
        // the parser sees and our CSP applies before any message content.
        guard let range = clean.range(of: "<head>") else {
            return "<!doctype html><html><head>\(head)</head><body></body></html>"
        }
        var document = clean
        document.insert(contentsOf: head, at: range.upperBound)
        return document
    }

    static func forOutgoingMessage(_ source: String, allowRemoteImages: Bool) -> String {
        sanitizedDocument(source, allowRemoteImages: allowRemoteImages)
    }

    // MARK: - DOM sanitizer

    /// Largest HTML source we will parse into a DOM; larger messages are shown as escaped text.
    private static let maximumParsedBytes = 8 * 1024 * 1024

    private static let removedElements: Set<String> = [
        "script", "iframe", "frame", "frameset", "object", "embed", "applet", "base", "meta", "link", "title",
        "template", "noscript", "svg", "math", "audio", "video", "source", "track", "canvas", "dialog",
        "input", "button", "select", "textarea", "option", "optgroup", "datalist", "portal", "slot", "image"
    ]
    /// Elements whose tags are dropped while their (sanitized) content is kept.
    private static let unwrappedElements: Set<String> = ["form"]
    /// URL-bearing attributes that email never needs.
    private static let alwaysRemovedAttributes: Set<String> = [
        "srcset", "srcdoc", "action", "formaction", "ping", "poster", "manifest", "codebase", "data", "cite",
        "longdesc", "lowsrc", "dynsrc", "xlink:href", "usemap", "target", "ismap"
    ]
    private static let safeLinkPrefixes = ["http:", "https:", "mailto:", "tel:", "#"]

    /// Parses `source` with the system HTML parser, removes active content, and serializes a complete
    /// `<!doctype html>` document. Fails closed: anything that cannot be parsed is returned as escaped text.
    private static func sanitizedDocument(_ source: String, allowRemoteImages: Bool) -> String {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard source.utf8.count <= maximumParsedBytes,
              let document = try? XMLDocument(
                xmlString: source,
                options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]
              ),
              let root = document.rootElement() else {
            return "<!doctype html><html><head></head><body><pre>\(escapeText(source))</pre></body></html>"
        }
        removeAttributes(of: root, allowRemoteImages: allowRemoteImages)
        sanitizeChildren(of: root, allowRemoteImages: allowRemoteImages)
        // Serialize through the document in HTML mode so void elements stay `<br>`, not `<br></br>`.
        document.documentContentKind = .html
        var html = document.xmlString
        if html.hasPrefix("<!DOCTYPE"), let end = html.firstIndex(of: ">") {
            html = String(html[html.index(after: end)...])
        }
        return "<!doctype html>" + html.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizeChildren(of parent: XMLNode, allowRemoteImages: Bool) {
        for child in Array(parent.children ?? []) {
            switch child.kind {
            case .text:
                continue
            case .element:
                guard let element = child as? XMLElement else { child.detach(); continue }
                let name = (element.name ?? "").lowercased()
                if removedElements.contains(name) { element.detach(); continue }
                removeAttributes(of: element, allowRemoteImages: allowRemoteImages)
                sanitizeChildren(of: element, allowRemoteImages: allowRemoteImages)
                if name == "style" {
                    element.stringValue = sanitizedCSS(element.stringValue ?? "", allowRemoteImages: allowRemoteImages)
                } else if unwrappedElements.contains(name) {
                    unwrap(element)
                }
            default:
                // Comments (including conditional comments), processing instructions, CDATA, DTDs.
                child.detach()
            }
        }
    }

    private static func unwrap(_ element: XMLElement) {
        guard let parent = element.parent as? XMLElement else { element.detach(); return }
        let index = element.index
        let children = Array(element.children ?? [])
        children.forEach { $0.detach() }
        element.detach()
        for (offset, child) in children.enumerated() {
            parent.insertChild(child, at: index + offset)
        }
    }

    private static func removeAttributes(of element: XMLElement, allowRemoteImages: Bool) {
        for attribute in Array(element.attributes ?? []) {
            guard let rawName = attribute.name else { continue }
            let name = rawName.lowercased()
            let value = attribute.stringValue ?? ""
            let keep: Bool
            switch name {
            case _ where name.hasPrefix("on") || alwaysRemovedAttributes.contains(name):
                keep = false
            case "href":
                keep = hasPrefix(value, in: safeLinkPrefixes)
            case "src", "background":
                keep = isAllowedImageSource(value, allowRemoteImages: allowRemoteImages)
            case "style":
                let clean = sanitizedCSS(value, allowRemoteImages: allowRemoteImages)
                element.removeAttribute(forName: rawName)
                if !clean.isEmpty { element.addAttribute(XMLNode.attribute(withName: "style", stringValue: clean) as! XMLNode) }
                continue
            default:
                keep = true
            }
            if !keep { element.removeAttribute(forName: rawName) }
        }
    }

    /// Browsers ignore ASCII whitespace and control characters inside a URL scheme, so compare without them.
    private static func normalizedURL(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F })).lowercased()
    }

    private static func hasPrefix(_ value: String, in prefixes: [String]) -> Bool {
        let normalized = normalizedURL(value)
        return prefixes.contains { normalized.hasPrefix($0) }
    }

    private static func isAllowedImageSource(_ value: String, allowRemoteImages: Bool) -> Bool {
        let normalized = normalizedURL(value)
        if normalized.hasPrefix("cid:") || normalized.hasPrefix("data:image/") { return true }
        guard allowRemoteImages else { return false }
        return normalized.hasPrefix("http:") || normalized.hasPrefix("https:") || normalized.hasPrefix("//")
    }

    /// Removes `@import`, legacy script hooks, and `url(...)` references that are not inline images.
    private static func sanitizedCSS(_ css: String, allowRemoteImages: Bool) -> String {
        // CSS escapes (`u\72l(`) can disguise `url(`; without remote loading enabled, drop such CSS outright.
        if !allowRemoteImages, css.contains("\\") { return "" }
        var result = css
        let blocked = [#"(?i)@import[^;]*;?"#, #"(?i)expression\s*\([^)]*\)"#, #"(?i)behaviou?r\s*:[^;}]*"#, #"(?i)-moz-binding\s*:[^;}]*"#]
        for pattern in blocked {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        guard let regex = try? NSRegularExpression(pattern: #"(?i)url\(\s*(["']?)(.*?)\1\s*\)"#, options: [.dotMatchesLineSeparators]) else { return "" }
        let nsResult = result as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: result, range: NSRange(location: 0, length: nsResult.length)) {
            output += nsResult.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let target = nsResult.substring(with: match.range(at: 2))
            output += isAllowedImageSource(target, allowRemoteImages: allowRemoteImages) ? nsResult.substring(with: match.range) : "none"
            cursor = NSMaxRange(match.range)
        }
        output += nsResult.substring(from: cursor)
        return output
    }
}
