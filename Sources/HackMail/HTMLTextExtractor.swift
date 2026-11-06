import Foundation

struct ExtractedPlainText: Sendable {
    let text: String
    let wasTruncated: Bool
}

enum HTMLTextExtractor {
    static let maximumCharacters = 12_000
    private static let maximumLines = 300
    private static let maximumSourceScalars = 250_000

    static func extract(_ html: String) -> ExtractedPlainText {
        let limitedSource = Array(html.unicodeScalars.prefix(maximumSourceScalars + 1))
        let sourceWasTruncated = limitedSource.count > maximumSourceScalars
        let scalars = Array(limitedSource.prefix(maximumSourceScalars))
        var output: [UnicodeScalar] = []
        var index = 0
        var hiddenTag: String?

        while index < scalars.count, output.count < maximumCharacters {
            if let activeHiddenTag = hiddenTag {
                if scalars[index] == "<", let tag = parseTag(scalars, at: index), tag.isClosing, tag.name == activeHiddenTag {
                    hiddenTag = nil
                    index = tag.endIndex
                    appendNewline(to: &output)
                } else {
                    index += 1
                }
                continue
            }

            let scalar = scalars[index]
            if scalar == "<", let tag = parseTag(scalars, at: index) {
                index = tag.endIndex
                if !tag.isClosing, ["script", "style", "head"].contains(tag.name) {
                    hiddenTag = tag.name
                    continue
                }
                if !tag.isClosing, tag.name == "li" { append("• ", to: &output) }
                if ["br", "p", "div", "li", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article"].contains(tag.name) {
                    appendNewline(to: &output)
                }
                continue
            }
            if scalar == "&", let entity = parseEntity(scalars, at: index) {
                append(entity.value, to: &output)
                index = entity.endIndex
                continue
            }
            output.append(scalar)
            index += 1
        }

        let hitOutputLimit = output.count >= maximumCharacters && index < scalars.count
        return finalize(String(String.UnicodeScalarView(output)), wasTruncated: sourceWasTruncated || hitOutputLimit)
    }

    static func limitPlainText(_ source: String) -> ExtractedPlainText {
        let prefix = String(source.prefix(maximumCharacters + 1))
        let wasTruncated = prefix.count > maximumCharacters
        let text = wasTruncated ? String(prefix.prefix(maximumCharacters)) : prefix
        return finalize(text, wasTruncated: wasTruncated)
    }

    private static func finalize(_ source: String, wasTruncated initiallyTruncated: Bool) -> ExtractedPlainText {
        var lines = source.components(separatedBy: .newlines)
        let linesWereTruncated = lines.count > maximumLines
        if linesWereTruncated { lines = Array(lines.prefix(maximumLines)) }
        var compactLines: [String] = []
        var consecutiveBlankLines = 0
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                consecutiveBlankLines += 1
                if consecutiveBlankLines <= 1 { compactLines.append("") }
            } else {
                consecutiveBlankLines = 0
                compactLines.append(line)
            }
        }
        var text = compactLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let wasTruncated = initiallyTruncated || linesWereTruncated
        if wasTruncated { text += "\n\n[Original message text shortened for responsiveness.]" }
        return ExtractedPlainText(text: text, wasTruncated: wasTruncated)
    }

    private static func parseTag(_ input: [UnicodeScalar], at index: Int) -> (name: String, isClosing: Bool, endIndex: Int)? {
        guard let end = input[(index + 1)...].firstIndex(of: ">") else {
            // An unterminated tag (often a very long inline data image) consumes the
            // rest of the bounded source; don't rescan each following character.
            return ("", false, input.count)
        }
        let cursor = end
        let tagContents = String(String.UnicodeScalarView(input[(index + 1)..<cursor]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isClosing = tagContents.hasPrefix("/")
        let nameContents = isClosing ? String(tagContents.dropFirst()) : tagContents
        let name = nameContents.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init)?.lowercased() ?? ""
        guard !name.isEmpty else { return nil }
        return (name, isClosing, cursor + 1)
    }

    private static func parseEntity(_ input: [UnicodeScalar], at index: Int) -> (value: String, endIndex: Int)? {
        var cursor = index + 1
        let limit = min(input.count, index + 16)
        while cursor < limit, input[cursor] != ";", !CharacterSet.whitespacesAndNewlines.contains(input[cursor]) { cursor += 1 }
        guard cursor < input.count, input[cursor] == ";" else { return nil }
        let name = String(String.UnicodeScalarView(input[(index + 1)..<cursor]))
        let value: String?
        switch name.lowercased() {
        case "amp": value = "&"
        case "lt": value = "<"
        case "gt": value = ">"
        case "quot": value = "\""
        case "apos", "#39": value = "'"
        case "nbsp": value = " "
        default:
            if name.lowercased().hasPrefix("#x"), let number = UInt32(name.dropFirst(2), radix: 16), let scalar = UnicodeScalar(number) {
                value = String(scalar)
            } else if name.hasPrefix("#"), let number = UInt32(name.dropFirst()), let scalar = UnicodeScalar(number) {
                value = String(scalar)
            } else {
                value = nil
            }
        }
        return (value ?? "&\(name);", cursor + 1)
    }

    private static func append(_ value: String, to output: inout [UnicodeScalar]) {
        for scalar in value.unicodeScalars {
            guard output.count < maximumCharacters else { break }
            output.append(scalar)
        }
    }

    private static func appendNewline(to output: inout [UnicodeScalar]) {
        if output.last != "\n" { output.append("\n") }
    }
}
