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
        let clean = removeActiveContent(from: source)
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
        if let range = clean.range(of: #"(?i)<head[^>]*>"#, options: .regularExpression) {
            var document = clean
            document.insert(contentsOf: head, at: range.upperBound)
            return document
        }
        return "<!doctype html><html><head>\(head)</head><body>\(clean)</body></html>"
    }

    static func forOutgoingMessage(_ source: String, allowRemoteImages: Bool) -> String {
        var html = removeActiveContent(from: source)
        guard !allowRemoteImages else { return html }
        let remoteAttributePatterns = [
            #"(?i)\s+src\s*=\s*("(?:https?:)?//[^\"]*"|'(?:https?:)?//[^']*'|(?:https?:)?//[^\s>]+)"#,
            #"(?i)\s+srcset\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
            #"(?i)\s+background\s*=\s*("(?:https?:)?//[^\"]*"|'(?:https?:)?//[^']*'|(?:https?:)?//[^\s>]+)"#
        ]
        for pattern in remoteAttributePatterns {
            html = html.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        html = html.replacingOccurrences(of: #"(?i)url\(\s*["']?(?:https?:)?//[^)]+\)"#, with: "none", options: .regularExpression)
        return html
    }

    private static func removeActiveContent(from source: String) -> String {
        var html = source
        let patterns = [
            #"(?is)<(script|iframe|object|embed|form|base|meta|link)\b[^>]*>.*?</\1\s*>"#,
            #"(?is)<(script|iframe|object|embed|form|base|meta|link)\b[^>]*/?>"#,
            #"(?i)\s+on[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
            #"(?i)\s+(href|src)\s*=\s*("\s*javascript:[^"]*"|'\s*javascript:[^']*'|javascript:[^\s>]*)"#
        ]
        for pattern in patterns {
            html = html.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return html
    }
}
