import Foundation
import CoreFoundation
import Network

struct GmailIMAPClient {
    func fetchMailbox(email: String, password: String, path: String, limit: Int = 30) async throws -> MailboxSnapshot {
        try await withSession(email: email, password: password) { session in
            let mailboxes = try await session.fetchMailboxes()
            let messages = try await session.fetchMailbox(path: path, limit: limit)
            return MailboxSnapshot(mailboxes: mailboxes, messages: messages)
        }
    }

    func searchMailbox(email: String, password: String, path: String, query: String, limit: Int = 30) async throws -> MailboxSearchSnapshot {
        guard !query.isEmpty, query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw IMAPError.invalidSearchQuery
        }
        return try await withSession(email: email, password: password) { session in
            let matchingUIDs = try await session.searchMailbox(path: path, query: query)
            let firstPage = Array(matchingUIDs.prefix(max(1, limit)))
            let messages = try await session.fetchMessages(uids: firstPage, mailboxPath: path)
            return MailboxSearchSnapshot(matchingUIDs: matchingUIDs, messages: messages)
        }
    }

    func fetchMessages(uids: [Int], mailboxPath: String, email: String, password: String) async throws -> [MailMessage] {
        guard !uids.isEmpty else { return [] }
        return try await withSession(email: email, password: password) { session in
            try await session.fetchMessages(uids: uids, mailboxPath: mailboxPath)
        }
    }

    func fetchBody(uid: Int, mailboxPath: String, email: String, password: String, full: Bool = false, preferHTML: Bool = true) async throws -> FetchedMessageBody {
        try await withSession(email: email, password: password) { session in
            try await session.selectMailbox(path: mailboxPath)
            return try await session.fetchBody(uid: uid, full: full, preferHTML: preferHTML)
        }
    }

    func archive(uid: Int, mailboxPath: String, email: String, password: String) async throws {
        try await withSession(email: email, password: password) { session in
            try await session.selectMailbox(path: mailboxPath)
            try await session.archive(uid: uid)
        }
    }

    func setStarred(uid: Int, mailboxPath: String, starred: Bool, email: String, password: String) async throws {
        try await withSession(email: email, password: password, shouldLogout: false) { session in
            try await session.selectMailbox(path: mailboxPath)
            try await session.setStarred(uid: uid, starred: starred)
        }
    }

    func move(uid: Int, from mailboxPath: String, to destination: String, email: String, password: String) async throws {
        try await withSession(email: email, password: password) { session in
            try await session.selectMailbox(path: mailboxPath)
            try await session.move(uid: uid, to: destination)
        }
    }

    func delete(uid: Int, mailboxPath: String, isTrash: Bool, trashPath: String?, email: String, password: String) async throws {
        try await withSession(email: email, password: password) { session in
            try await session.selectMailbox(path: mailboxPath)
            if isTrash {
                try await session.permanentlyDelete(uid: uid)
            } else if let trashPath {
                try await session.move(uid: uid, to: trashPath)
            } else {
                throw IMAPError.protocolError("Gmail did not provide a Trash mailbox.")
            }
        }
    }

    private func withSession<T: Sendable>(
        email: String,
        password: String,
        shouldLogout: Bool = true,
        operation: @Sendable (IMAPSession) async throws -> T
    ) async throws -> T {
        let session = IMAPSession()
        do {
            try await session.open(email: email, password: password)
            let result = try await operation(session)
            if shouldLogout { try await session.logout() }
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }
}

struct MailboxSnapshot: Sendable {
    let mailboxes: [MailMailbox]
    let messages: [MailMessage]
}

struct MailboxSearchSnapshot: Sendable {
    let matchingUIDs: [Int]
    let messages: [MailMessage]
}

struct FetchedMessageBody: Sendable {
    let content: String
    let isHTML: Bool
    let isPartial: Bool
}

private enum IMAPError: LocalizedError {
    case connection(String)
    case protocolError(String)
    case authentication
    case noInbox
    case invalidSearchQuery

    var errorDescription: String? {
        switch self {
        case .connection(let detail): "Could not connect to Gmail: \(detail)"
        case .protocolError(let detail): "Gmail returned an unexpected IMAP response: \(detail)"
        case .authentication: "Gmail rejected the app password. Check the address and app password in Account Settings."
        case .noInbox: "Gmail did not return an Inbox mailbox."
        case .invalidSearchQuery: "Enter a Gmail search query without line breaks or control characters."
        }
    }
}

private actor IMAPSession {
    private enum Segment {
        case line(Data)
        case literal(Data)
    }

    private struct Response {
        let segments: [Segment]

        var lines: [String] {
            segments.compactMap {
                guard case .line(let data) = $0 else { return nil }
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            }
        }
    }

    private let queue = DispatchQueue(label: "HackMail.GmailIMAP")
    private var connection: NWConnection?
    private var buffered = Data()
    private var nextTag = 1
    private var capabilities: Set<String> = []

    func open(email: String, password: String) async throws {
        let endpoint = NWEndpoint.Host("imap.gmail.com")
        guard let port = NWEndpoint.Port(rawValue: 993) else {
            throw IMAPError.connection("Invalid IMAP port.")
        }
        let connection = NWConnection(host: endpoint, port: port, using: .tls)
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: IMAPError.connection(error.localizedDescription))
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: IMAPError.connection("Connection was cancelled."))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        let greeting = try await readLine()
        guard greeting.uppercased().contains("* OK") else {
            throw IMAPError.protocolError(greeting)
        }
        do {
            _ = try await command("LOGIN \(quote(email)) \(quote(password))")
        } catch IMAPError.protocolError(let detail) where detail.localizedCaseInsensitiveContains("NO") || detail.localizedCaseInsensitiveContains("AUTHENTICATIONFAILED") {
            throw IMAPError.authentication
        }
    }

    func fetchMailboxes() async throws -> [MailMailbox] {
        let response = try await command("LIST \"\" \"*\"")
        return response.lines.compactMap(IMAPServerResponseParser.parseMailbox)
            .filter { !$0.attributes.contains(where: { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame }) }
            .sorted { left, right in
                if left.isInbox != right.isInbox { return left.isInbox }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    func fetchMailbox(path: String, limit: Int) async throws -> [MailMessage] {
        try await selectMailbox(path: path)
        let search = try await command("UID SEARCH ALL")
        let uids = IMAPServerResponseParser.parseSearchUIDs(search.lines).suffix(max(1, limit))
        guard !uids.isEmpty else { return [] }

        return try await fetchMessages(uids: Array(uids), mailboxPath: path)
    }

    func searchMailbox(path: String, query: String) async throws -> [Int] {
        try await selectMailbox(path: path)
        let response = try await command("UID SEARCH X-GM-RAW \(quote(query))")
        return IMAPServerResponseParser.parseSearchUIDs(response.lines).sorted(by: >)
    }

    func fetchMessages(uids: [Int], mailboxPath: String) async throws -> [MailMessage] {
        guard !uids.isEmpty else { return [] }
        try await selectMailbox(path: mailboxPath)
        let uidSet = uids.map(String.init).joined(separator: ",")
        let response = try await command("UID FETCH \(uidSet) (UID FLAGS INTERNALDATE ENVELOPE)")
        return response.lines.compactMap { IMAPServerResponseParser.parseMessage($0, mailboxPath: mailboxPath) }
            .sorted { $0.id > $1.id }
    }

    func selectMailbox(path: String) async throws {
        let selected = try await command("SELECT \(quote(path))")
        guard selected.lines.contains(where: { $0.localizedCaseInsensitiveContains("EXISTS") }) ||
                selected.lines.contains(where: { $0.localizedCaseInsensitiveContains("READ-WRITE") }) else {
            throw IMAPError.protocolError("Could not select mailbox \(path).")
        }
    }

    func fetchBody(uid: Int, full: Bool, preferHTML: Bool) async throws -> FetchedMessageBody {
        // Resolve the MIME structure first, then fetch only a text part on demand. No
        // attachment parts are requested or written to disk.
        let structureResponse = try await command("UID FETCH \(uid) (BODYSTRUCTURE)")
        guard let structure = Self.parseBodyStructure(structureResponse.lines),
              let bodyPart = Self.preferredTextPart(in: structure, preferHTML: preferHTML) else {
            throw IMAPError.protocolError("This message has no supported plain-text or HTML body part.")
        }
        let section = bodyPart.section.isEmpty ? "TEXT" : bodyPart.section
        let bodySection = full ? "BODY.PEEK[\(section)]" : "BODY.PEEK[\(section)]<0.65536>"
        let response = try await command("UID FETCH \(uid) (\(bodySection))")
        guard let literal = response.segments.compactMap({ segment -> Data? in
            guard case .literal(let data) = segment else { return nil }
            return data
        }).first else {
            throw IMAPError.protocolError("Gmail returned no message body.")
        }
        let fetchedBody = Self.decodeBody(
            literal,
            transferEncoding: bodyPart.transferEncoding,
            charset: bodyPart.charset,
            isHTML: bodyPart.isHTML,
            isPartial: !full && literal.count >= 65_536
        )
        guard bodyPart.isHTML, !bodyPart.inlineImages.isEmpty else { return fetchedBody }
        let inlineImages = try await fetchInlineImages(uid: uid, parts: bodyPart.inlineImages)
        let html = IMAPInlineImageResolver.replacingCIDReferences(in: fetchedBody.content, with: inlineImages)
        return FetchedMessageBody(content: html, isHTML: true, isPartial: fetchedBody.isPartial)
    }

    private func fetchInlineImages(uid: Int, parts: [IMAPInlineImage]) async throws -> [String: String] {
        let maximumInlineBytes = 4 * 1024 * 1024
        var declaredBytes = 0
        var eligible: [IMAPInlineImage] = []
        for part in parts where part.size >= 0 {
            guard declaredBytes + part.size <= maximumInlineBytes else { continue }
            declaredBytes += part.size
            eligible.append(part)
        }
        guard !eligible.isEmpty else { return [:] }

        let sections = eligible.map { "BODY.PEEK[\($0.section)]" }.joined(separator: " ")
        let response = try await command("UID FETCH \(uid) (\(sections))")
        var currentSection: String?
        var literals: [String: Data] = [:]
        for segment in response.segments {
            switch segment {
            case .line(let data):
                currentSection = Self.fetchedBodySection(in: String(decoding: data, as: UTF8.self))
            case .literal(let data):
                if let currentSection { literals[currentSection] = data }
                currentSection = nil
            }
        }

        var result: [String: String] = [:]
        var actualBytes = 0
        for part in eligible {
            guard let encoded = literals[part.section] else { continue }
            let data = Self.decodeTransferData(encoded, encoding: part.transferEncoding)
            guard actualBytes + data.count <= maximumInlineBytes else { continue }
            actualBytes += data.count
            result[part.contentID] = "data:\(part.mimeType);base64,\(data.base64EncodedString())"
        }
        return result
    }

    private static func fetchedBodySection(in line: String) -> String? {
        let pattern = #"(?i)BODY\[([^\]]+)\](?:<\d+>)?\s+\{\d+\}$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private static func decodeTransferData(_ data: Data, encoding: String) -> Data {
        switch encoding.lowercased() {
        case "base64":
            let compact = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: compact, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            return decodeQuotedPrintable(String(decoding: data, as: UTF8.self)) ?? data
        default:
            return data
        }
    }

    func archive(uid: Int) async throws {
        try await loadCapabilities()
        guard capabilities.contains("X-GM-EXT-1") else {
            throw IMAPError.protocolError("Gmail's label extension is unavailable; archive was not performed.")
        }
        _ = try await command("UID STORE \(uid) -X-GM-LABELS.SILENT (\\Inbox)")
    }

    func setStarred(uid: Int, starred: Bool) async throws {
        let operation = starred ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
        _ = try await command("UID STORE \(uid) \(operation) (\\Flagged)")
    }

    func move(uid: Int, to destination: String) async throws {
        try await loadCapabilities()
        if capabilities.contains("MOVE") {
            let moveCommand = "UID MOVE \(uid) \(quote(destination))"
            do {
                _ = try await command(moveCommand)
            } catch IMAPError.protocolError(let detail) where detail.localizedCaseInsensitiveContains("SYSTEM ERROR") {
                // UID MOVE is atomic and keyed by the source UID, so a single retry is safe:
                // if Gmail completed the first attempt but returned a transient error, the
                // second command simply finds no source UID to move.
                _ = try await command(moveCommand)
            }
        } else if capabilities.contains("UIDPLUS") {
            _ = try await command("UID COPY \(uid) \(quote(destination))")
            _ = try await command("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
            _ = try await command("UID EXPUNGE \(uid)")
        } else {
            throw IMAPError.protocolError("This Gmail server does not support a safe move operation.")
        }
    }

    func permanentlyDelete(uid: Int) async throws {
        try await loadCapabilities()
        guard capabilities.contains("UIDPLUS") else {
            throw IMAPError.protocolError("This Gmail server does not support safe permanent deletion.")
        }
        _ = try await command("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
        _ = try await command("UID EXPUNGE \(uid)")
    }

    private func loadCapabilities() async throws {
        guard capabilities.isEmpty else { return }
        let response = try await command("CAPABILITY")
        capabilities = Set(response.lines
            .filter { $0.uppercased().hasPrefix("* CAPABILITY") }
            .flatMap { $0.split(whereSeparator: \.isWhitespace).dropFirst(2).map { $0.uppercased() } })
    }

    func logout() async throws {
        guard connection != nil else { return }
        _ = try await command("LOGOUT")
    }

    func close() {
        connection?.cancel()
        connection = nil
        buffered.removeAll(keepingCapacity: false)
    }

    private func command(_ command: String) async throws -> Response {
        let tag = String(format: "A%04d", nextTag)
        nextTag += 1
        try await send("\(tag) \(command)\r\n")

        var segments: [Segment] = []
        while true {
            let line = try await readLineData()
            segments.append(.line(line))
            let text = String(decoding: line, as: UTF8.self)
            if let literalCount = Self.literalLength(in: text) {
                segments.append(.literal(try await readExactly(literalCount)))
            }
            if text.hasPrefix("\(tag) ") {
                let status = text.dropFirst(tag.count + 1).uppercased()
                if status.hasPrefix("NO") || status.hasPrefix("BAD") {
                    throw IMAPError.protocolError(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return Response(segments: segments)
            }
        }
    }

    private func send(_ string: String) async throws {
        guard let connection else { throw IMAPError.connection("Not connected.") }
        let data = Data(string.utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: IMAPError.connection(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    private func readLine() async throws -> String {
        String(decoding: try await readLineData(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readLineData() async throws -> Data {
        let delimiter = Data([0x0D, 0x0A])
        while true {
            if let range = buffered.range(of: delimiter) {
                let line = buffered.subdata(in: buffered.startIndex..<range.lowerBound)
                buffered.removeSubrange(buffered.startIndex..<range.upperBound)
                return line
            }
            try await receiveMore()
        }
    }

    private func readExactly(_ count: Int) async throws -> Data {
        guard count >= 0 else { throw IMAPError.protocolError("Invalid literal length.") }
        while buffered.count < count { try await receiveMore() }
        let result = buffered.prefix(count)
        buffered.removeFirst(count)
        return Data(result)
    }

    private func receiveMore() async throws {
        guard let connection else { throw IMAPError.connection("Connection closed.") }
        let chunk: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: IMAPError.connection(error.localizedDescription))
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(throwing: IMAPError.connection("Gmail closed the connection."))
                } else {
                    continuation.resume(throwing: IMAPError.connection("Gmail returned an empty response."))
                }
            }
        }
        buffered.append(chunk)
    }

    private func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func literalLength(in line: String) -> Int? {
        guard let close = line.lastIndex(of: "}"), close == line.index(before: line.endIndex),
              let open = line[..<close].lastIndex(of: "{") else { return nil }
        let digits = line[line.index(after: open)..<close].trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        return Int(digits)
    }

    private static func parseBodyStructure(_ lines: [String]) -> IMAPValue? {
        for line in lines {
            let tokens = IMAPTokenizer(line).tokens
            guard tokens.count > 4, tokens[0] == .atom("*"), tokens[2] == .atom("FETCH") else { continue }
            var cursor = 4
            while cursor < tokens.count, tokens[cursor] != .rightParen {
                guard case .atom(let key) = tokens[cursor] else { cursor += 1; continue }
                cursor += 1
                guard let value = IMAPTokenizer.parseValue(tokens, cursor: &cursor) else { break }
                if key.uppercased() == "BODYSTRUCTURE" { return value }
            }
        }
        return nil
    }

    private static func preferredTextPart(in structure: IMAPValue, preferHTML: Bool) -> IMAPTextPart? {
        let parts = textParts(in: structure, section: "")
        return IMAPMIMEPartSelector.preferredTextPart(in: parts, preferHTML: preferHTML)
    }

    private static func textParts(in value: IMAPValue, section: String, relatedImages: [IMAPInlineImage] = []) -> [IMAPTextPart] {
        guard case .list(let values) = value, !values.isEmpty else { return [] }

        var childStructures: [IMAPValue] = []
        for value in values {
            guard case .list = value else { break }
            childStructures.append(value)
        }
        if !childStructures.isEmpty {
            let subtype = values.dropFirst(childStructures.count).first?.stringValue?.lowercased()
            var nestedInlineImages = relatedImages
            if subtype == "related" {
                nestedInlineImages.append(contentsOf: childStructures.enumerated().flatMap { index, child in
                    let childSection = section.isEmpty ? String(index + 1) : "\(section).\(index + 1)"
                    return inlineImages(in: child, section: childSection)
                })
            }
            return childStructures.enumerated().flatMap { index, child in
                let childSection = section.isEmpty ? String(index + 1) : "\(section).\(index + 1)"
                return textParts(in: child, section: childSection, relatedImages: nestedInlineImages)
            }
        }

        guard values.count >= 7,
              let type = values[0].stringValue?.lowercased(),
              type == "text",
              let subtype = values[1].stringValue?.lowercased(),
              subtype == "plain" || subtype == "html" else { return [] }

        let parameters = parameterDictionary(values[2])
        let trailing = values.dropFirst(min(7, values.count))
        let disposition = trailing.compactMap { candidate -> (String, [String: String])? in
            guard case .list(let parts) = candidate, let name = parts.first?.stringValue?.lowercased(),
                  name == "attachment" || name == "inline" else { return nil }
            return (name, parts.dropFirst().first.map(parameterDictionary) ?? [:])
        }.first
        let filename = parameters["name"] ?? disposition?.1["filename"]
        guard disposition?.0 != "attachment", filename == nil else { return [] }

        return [IMAPTextPart(
            section: section,
            isHTML: subtype == "html",
            transferEncoding: values[5].stringValue?.lowercased() ?? "7bit",
            charset: parameters["charset"],
            inlineImages: relatedImages
        )]
    }

    private static func inlineImages(in value: IMAPValue, section: String) -> [IMAPInlineImage] {
        guard case .list(let values) = value, !values.isEmpty else { return [] }
        var childStructures: [IMAPValue] = []
        for value in values {
            guard case .list = value else { break }
            childStructures.append(value)
        }
        if !childStructures.isEmpty {
            return childStructures.enumerated().flatMap { index, child in
                let childSection = section.isEmpty ? String(index + 1) : "\(section).\(index + 1)"
                return inlineImages(in: child, section: childSection)
            }
        }

        guard values.count >= 7,
              let type = values[0].stringValue?.lowercased(), type == "image",
              let subtype = values[1].stringValue?.lowercased(),
              let rawContentID = values[3].stringValue, !rawContentID.isEmpty,
              let size = values[6].stringValue.flatMap(Int.init) else { return [] }
        let trailing = values.dropFirst(min(7, values.count))
        let disposition = trailing.compactMap { candidate -> String? in
            guard case .list(let parts) = candidate else { return nil }
            return parts.first?.stringValue?.lowercased()
        }.first
        guard disposition != "attachment" else { return [] }
        let contentID = rawContentID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        return [IMAPInlineImage(
            section: section,
            contentID: contentID,
            mimeType: "image/\(subtype)",
            transferEncoding: values[5].stringValue?.lowercased() ?? "7bit",
            size: size
        )]
    }

    private static func parameterDictionary(_ value: IMAPValue) -> [String: String] {
        guard case .list(let values) = value else { return [:] }
        var result: [String: String] = [:]
        var index = 0
        while index + 1 < values.count {
            if let key = values[index].stringValue?.lowercased(), let value = values[index + 1].stringValue {
                result[key] = value
            }
            index += 2
        }
        return result
    }

    private static func decodeBody(_ data: Data, transferEncoding: String, charset: String?, isHTML: Bool, isPartial: Bool) -> FetchedMessageBody {
        let decodedData: Data
        switch transferEncoding.lowercased() {
        case "base64":
            let compact = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
            decodedData = Data(base64Encoded: compact, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            decodedData = decodeQuotedPrintable(String(decoding: data, as: UTF8.self)) ?? data
        default:
            decodedData = data
        }
        let text: String
        if let charset {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            let stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
            text = String(data: decodedData, encoding: stringEncoding) ?? String(decoding: decodedData, as: UTF8.self)
        } else {
            text = String(data: decodedData, encoding: .utf8) ?? String(decoding: decodedData, as: UTF8.self)
        }
        return FetchedMessageBody(content: isHTML ? text : stripLeadingMIMEHeaders(text), isHTML: isHTML, isPartial: isPartial)
    }

    private static func stripLeadingMIMEHeaders(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let headerPattern = #"(?i)^(content-type|content-transfer-encoding|content-disposition|mime-version|content-id):"#
        var sawMIMEHeader = false
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if sawMIMEHeader {
                    return lines.dropFirst(index + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }
            if line.range(of: headerPattern, options: .regularExpression) != nil || (sawMIMEHeader && line.first?.isWhitespace == true) {
                sawMIMEHeader = true
                continue
            }
            return text
        }
        return text
    }

    private static func decodeQuotedPrintable(_ value: String) -> Data? {
        var bytes: [UInt8] = []
        let input = Array(value.utf8)
        var index = 0
        while index < input.count {
            if input[index] == 61, index + 2 < input.count, input[index + 1] == 13, input[index + 2] == 10 {
                index += 3
            } else if input[index] == 61, index + 1 < input.count, input[index + 1] == 10 {
                index += 2
            } else if input[index] == 61, index + 2 < input.count,
               let byte = UInt8(String(bytes: input[(index + 1)...(index + 2)], encoding: .utf8) ?? "", radix: 16) {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(input[index])
                index += 1
            }
        }
        return Data(bytes)
    }
}

struct IMAPInlineImage: Equatable, Sendable {
    let section: String
    let contentID: String
    let mimeType: String
    let transferEncoding: String
    let size: Int
}

struct IMAPTextPart: Equatable, Sendable {
    let section: String
    let isHTML: Bool
    let transferEncoding: String
    let charset: String?
    let inlineImages: [IMAPInlineImage]
}

enum IMAPMIMEPartSelector {
    static func preferredTextPart(in parts: [IMAPTextPart], preferHTML: Bool = true) -> IMAPTextPart? {
        let preferred = parts.first(where: { $0.isHTML == preferHTML })
        return preferred ?? parts.first
    }
}

enum IMAPServerResponseParser {
    static func parseSearchUIDs(_ lines: [String]) -> [Int] {
        var seen = Set<Int>()
        return lines
            .filter { $0.uppercased().hasPrefix("* SEARCH") }
            .flatMap { $0.split(whereSeparator: \.isWhitespace).dropFirst(2) }
            .compactMap { Int($0) }
            .filter { seen.insert($0).inserted }
    }

    static func parseMailbox(_ line: String) -> MailMailbox? {
        let tokens = IMAPTokenizer(line).tokens
        guard tokens.count > 5, tokens[0] == .atom("*"), tokens[1] == .atom("LIST") else { return nil }
        var cursor = 2
        guard case .list(let rawAttributes)? = IMAPTokenizer.parseValue(tokens, cursor: &cursor),
              let delimiter = IMAPTokenizer.parseValue(tokens, cursor: &cursor),
              let mailbox = IMAPTokenizer.parseValue(tokens, cursor: &cursor),
              let path = mailbox.stringValue else { return nil }
        _ = delimiter
        let attributes = Set(rawAttributes.compactMap(\.stringValue))
        let normalizedPath = path.caseInsensitiveCompare("INBOX") == .orderedSame ? "INBOX" : path
        let displayPath = IMAPMailboxNameCodec.decode(normalizedPath)
        let name: String
        if attributes.contains(where: { $0.caseInsensitiveCompare("\\Inbox") == .orderedSame }) || normalizedPath == "INBOX" {
            name = "Inbox"
        } else if attributes.contains(where: { $0.caseInsensitiveCompare("\\Sent") == .orderedSame }) {
            name = "Sent"
        } else if attributes.contains(where: { $0.caseInsensitiveCompare("\\Drafts") == .orderedSame }) {
            name = "Drafts"
        } else if attributes.contains(where: { $0.caseInsensitiveCompare("\\Trash") == .orderedSame }) {
            name = "Trash"
        } else if attributes.contains(where: { $0.caseInsensitiveCompare("\\Junk") == .orderedSame }) {
            name = "Spam"
        } else if attributes.contains(where: { $0.caseInsensitiveCompare("\\All") == .orderedSame }) {
            name = "All Mail"
        } else if attributes.contains(where: { $0.caseInsensitiveCompare("\\Flagged") == .orderedSame }) {
            name = "Starred"
        } else if displayPath.hasPrefix("[Gmail]/") {
            name = String(displayPath.dropFirst("[Gmail]/".count))
        } else {
            name = displayPath.components(separatedBy: "/").last ?? displayPath
        }
        return MailMailbox(path: normalizedPath, name: name, attributes: attributes)
    }

    static func parseMessage(_ line: String, mailboxPath: String) -> MailMessage? {
        let tokens = IMAPTokenizer(line).tokens
        guard tokens.count > 4, tokens[0] == .atom("*"), tokens[2] == .atom("FETCH") else { return nil }
        var cursor = 4
        var uid: Int?
        var flags: [String] = []
        var internalDate: Date?
        var envelope: [IMAPValue]?

        while cursor < tokens.count, tokens[cursor] != .rightParen {
            guard case .atom(let key) = tokens[cursor] else { cursor += 1; continue }
            cursor += 1
            guard let value = IMAPTokenizer.parseValue(tokens, cursor: &cursor) else { break }
            switch key.uppercased() {
            case "UID":
                if case .atom(let number) = value { uid = Int(number) }
            case "FLAGS":
                if case .list(let items) = value { flags = items.compactMap(\.stringValue) }
            case "INTERNALDATE":
                if case .string(let date) = value { internalDate = parseDate(date) }
            case "ENVELOPE":
                if case .list(let items) = value { envelope = items }
            default: break
            }
        }
        guard let uid, let envelope, envelope.count >= 3 else { return nil }
        let subject = envelope[1].stringValue.flatMap(decodeHeader) ?? "(No Subject)"
        let from = addresses(envelope[2])
        let sentDate = envelope[0].stringValue.flatMap(parseDate) ?? internalDate
        return MailMessage(
            id: uid,
            sender: from.name.isEmpty ? from.email : from.name,
            senderEmail: from.email,
            time: sentDate.map(formatDate) ?? "",
            sortDate: sentDate,
            subject: subject,
            preview: "Open to read this message online.",
            body: "",
            bodyIsPartial: true,
            unread: !flags.contains(where: { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }),
            flagged: flags.contains(where: { $0.caseInsensitiveCompare("\\Flagged") == .orderedSame }),
            isRemote: true,
            mailboxPath: mailboxPath
        )
    }

    private static func addresses(_ value: IMAPValue) -> (name: String, email: String) {
        guard case .list(let addresses) = value,
              case .list(let address)? = addresses.first, address.count >= 4 else { return ("", "") }
        let name = address[0].stringValue ?? ""
        let mailbox = address[2].stringValue ?? ""
        let host = address[3].stringValue ?? ""
        return (decodeHeader(name) ?? name, [mailbox, host].filter { !$0.isEmpty }.joined(separator: "@"))
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "dd-MMM-yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = .current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }

    private static func decodeHeader(_ value: String) -> String? {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        guard !matches.isEmpty else { return value }
        var output = value
        for match in matches.reversed() {
            let charset = nsValue.substring(with: match.range(at: 1))
            let transferEncoding = nsValue.substring(with: match.range(at: 2)).lowercased()
            let payload = nsValue.substring(with: match.range(at: 3))
            let bytes = transferEncoding == "b"
                ? Data(base64Encoded: payload)
                : decodeQuotedPrintable(payload.replacingOccurrences(of: "_", with: " "))
            let charsetEncoding = CFStringConvertEncodingToNSStringEncoding(
                CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            )
            let decoded = bytes.flatMap { String(data: $0, encoding: String.Encoding(rawValue: charsetEncoding)) } ?? payload
            if let range = Range(match.range, in: output) { output.replaceSubrange(range, with: decoded) }
        }
        return output
    }

    private static func decodeQuotedPrintable(_ value: String) -> Data? {
        var bytes: [UInt8] = []
        let input = Array(value.utf8)
        var index = 0
        while index < input.count {
            if input[index] == 61, index + 2 < input.count, input[index + 1] == 13, input[index + 2] == 10 {
                index += 3
            } else if input[index] == 61, index + 1 < input.count, input[index + 1] == 10 {
                index += 2
            } else if input[index] == 61, index + 2 < input.count,
                      let byte = UInt8(String(bytes: input[(index + 1)...(index + 2)], encoding: .utf8) ?? "", radix: 16) {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(input[index])
                index += 1
            }
        }
        return Data(bytes)
    }
}

private enum IMAPValue: Equatable {
    case atom(String)
    case string(String)
    case list([IMAPValue])
    case nilValue

    var stringValue: String? {
        switch self {
        case .atom(let value), .string(let value): value
        case .nilValue, .list: nil
        }
    }
}

private enum IMAPToken: Equatable {
    case atom(String)
    case string(String)
    case leftParen
    case rightParen
}

private struct IMAPTokenizer {
    let tokens: [IMAPToken]

    init(_ input: String) {
        let bytes = Array(input.utf8)
        var result: [IMAPToken] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 32 || bytes[index] == 9 || bytes[index] == 10 || bytes[index] == 13 {
                index += 1
            } else if bytes[index] == 40 {
                result.append(.leftParen); index += 1
            } else if bytes[index] == 41 {
                result.append(.rightParen); index += 1
            } else if bytes[index] == 34 {
                index += 1
                var value: [UInt8] = []
                while index < bytes.count, bytes[index] != 34 {
                    if bytes[index] == 92, index + 1 < bytes.count { index += 1 }
                    value.append(bytes[index]); index += 1
                }
                if index < bytes.count { index += 1 }
                result.append(.string(String(decoding: value, as: UTF8.self)))
            } else {
                let start = index
                while index < bytes.count, ![32, 9, 10, 13, 40, 41].contains(bytes[index]) { index += 1 }
                result.append(.atom(String(decoding: bytes[start..<index], as: UTF8.self)))
            }
        }
        tokens = result
    }

    static func parseValue(_ tokens: [IMAPToken], cursor: inout Int) -> IMAPValue? {
        guard cursor < tokens.count else { return nil }
        let token = tokens[cursor]
        cursor += 1
        switch token {
        case .leftParen:
            var values: [IMAPValue] = []
            while cursor < tokens.count, tokens[cursor] != .rightParen {
                guard let value = parseValue(tokens, cursor: &cursor) else { break }
                values.append(value)
            }
            if cursor < tokens.count, tokens[cursor] == .rightParen { cursor += 1 }
            return .list(values)
        case .rightParen:
            return nil
        case .string(let value):
            return .string(value)
        case .atom(let value):
            return value.caseInsensitiveCompare("NIL") == .orderedSame ? .nilValue : .atom(value)
        }
    }
}
