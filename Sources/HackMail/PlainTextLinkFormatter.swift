import AppKit
import Foundation
import SwiftUI

enum PlainTextLinkFormatter {
    private struct Candidate {
        let labelRange: NSRange
        let suffixRange: NSRange
        let url: URL
    }

    static func format(_ source: String) -> AttributedString {
        let output = NSMutableAttributedString(string: source)
        let candidates = labeledLinkCandidates(in: source).sorted {
            $0.suffixRange.location > $1.suffixRange.location
        }

        for candidate in candidates {
            guard NSMaxRange(candidate.labelRange) <= output.length,
                  NSMaxRange(candidate.suffixRange) <= output.length else { continue }
            output.addAttribute(.link, value: candidate.url, range: candidate.labelRange)
            output.addAttribute(.foregroundColor, value: NSColor(Paper.accent), range: candidate.labelRange)
            output.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: candidate.labelRange)
            output.deleteCharacters(in: candidate.suffixRange)
        }

        linkUnlabeledURLs(in: output)
        return AttributedString(output)
    }

    private static func labeledLinkCandidates(in source: String) -> [Candidate] {
        let patterns = [
            #"(?<label>[^\r\n]+?)(?<suffix>[\t ]*\([\t ]*(?<url>https?://[^()\s]+)[\t ]*\))"#,
            #"(?<label>[^\r\n]+)(?<suffix>\r?\n[\t ]*\([\t ]*(?<url>https?://[^()\s]+)[\t ]*\))"#
        ]
        let sourceString = source as NSString
        var candidates: [Candidate] = []

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in expression.matches(in: source, range: NSRange(location: 0, length: sourceString.length)) {
                let labelRange = semanticLabelRange(sourceString, range: match.range(at: 1))
                let suffixRange = match.range(at: 2)
                let urlString = sourceString.substring(with: match.range(at: 3))
                guard labelRange.length > 0, suffixRange.location != NSNotFound,
                      let url = URL(string: urlString),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                candidates.append(Candidate(labelRange: labelRange, suffixRange: suffixRange, url: url))
            }
        }
        return candidates
    }

    private static func semanticLabelRange(_ source: NSString, range: NSRange) -> NSRange {
        var selected = range
        let label = source.substring(with: range) as NSString
        let separators = [" at ", " on ", " to ", ": "]
        var latestSeparator = NSRange(location: NSNotFound, length: 0)
        for separator in separators {
            let found = label.range(of: separator, options: [.caseInsensitive, .backwards])
            if found.location != NSNotFound && (latestSeparator.location == NSNotFound || found.location > latestSeparator.location) {
                latestSeparator = found
            }
        }
        if latestSeparator.location != NSNotFound {
            selected.location += NSMaxRange(latestSeparator)
            selected.length -= NSMaxRange(latestSeparator)
        }

        let selectedText = source.substring(with: selected) as NSString
        var start = 0
        var end = selectedText.length
        while start < end, selectedText.substring(with: NSRange(location: start, length: 1)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { start += 1 }
        while end > start, selectedText.substring(with: NSRange(location: end - 1, length: 1)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { end -= 1 }
        return NSRange(location: selected.location + start, length: end - start)
    }

    private static func linkUnlabeledURLs(in text: NSMutableAttributedString) {
        let source = text.string
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let matches = detector.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
        for match in matches.reversed() {
            guard let url = match.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  match.range.location != NSNotFound,
                  text.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            text.addAttribute(.link, value: url, range: match.range)
            text.addAttribute(.foregroundColor, value: NSColor(Paper.accent), range: match.range)
            text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
        }
    }
}
