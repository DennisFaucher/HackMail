import Foundation
import Network
import UniformTypeIdentifiers

struct GmailSMTPClient: Sendable {
    static func parseRecipients(_ input: String) -> [String]? {
        let raw = input.split(whereSeparator: { $0 == "," || $0 == ";" }).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !raw.isEmpty, raw.allSatisfy(isValidEmail) else { return nil }
        return raw
    }

    static func isValidEmail(_ email: String) -> Bool {
        let pattern = #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }

    func send(from: String, fromName: String, password: String, to recipients: [String], subject: String, body: OutgoingEmailBody, attachments: [MailAttachment]) async throws {
        guard Self.isValidEmail(from), !recipients.isEmpty, recipients.allSatisfy(Self.isValidEmail),
              fromName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              subject.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw SMTPError.invalidMessage
        }
        let session = SMTPSession()
        do {
            try await session.open()
            try await session.authenticate(email: from, password: password)
            try await session.sendMessage(from: from, fromName: fromName, recipients: recipients, subject: subject, body: body, attachments: attachments)
            // A final 250 response means Gmail accepted the message. QUIT failure after that
            // must not make the UI suggest retrying, which could send a duplicate.
            try? await session.quit()
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    }
}

enum SMTPMessageBuilder {
    static func build(from: String, fromName: String, recipients: [String], subject: String, body: OutgoingEmailBody, attachments: [MailAttachment] = []) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let domain = from.split(separator: "@").last.map(String.init) ?? "localhost"
        let messageID = "<\(UUID().uuidString.lowercased())@\(domain)>"
        let subjectHeader = encodedSubject(subject)
        let fromHeader = fromName.isEmpty ? "<\(from)>" : "\(encodedDisplayName(fromName)) <\(from)>"
        let (htmlWithCIDImages, inlineAttachments) = replaceInlineDataImages(in: body.html)
        let outgoingBody = OutgoingEmailBody(plainText: body.plainText, html: htmlWithCIDImages)
        let alternativeBoundary = "=_HackMail_Alternative_\(UUID().uuidString)"
        let alternative = multipartAlternative(outgoingBody, boundary: alternativeBoundary)
        let allAttachments = inlineAttachments + attachments
        let regularAttachments = allAttachments.filter { $0.contentID == nil }
        let relatedContent: (boundary: String, body: String)?
        if !inlineAttachments.isEmpty {
            let relatedBoundary = "=_HackMail_Related_\(UUID().uuidString)"
            let inlineParts = inlineAttachments.map { attachmentPart($0, boundary: relatedBoundary) }.joined()
            let relatedBody = "--\(relatedBoundary)\r\nContent-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"\r\n\r\n\(alternative)\(inlineParts)--\(relatedBoundary)--\r\n"
            relatedContent = (relatedBoundary, relatedBody)
        } else {
            relatedContent = nil
        }
        let contentType: String
        let content: String
        if !regularAttachments.isEmpty {
            let mixedBoundary = "=_HackMail_Mixed_\(UUID().uuidString)"
            if let relatedContent {
                contentType = "multipart/mixed; boundary=\"\(mixedBoundary)\""
                let regularParts = regularAttachments.map { attachmentPart($0, boundary: mixedBoundary) }.joined()
                content = "--\(mixedBoundary)\r\nContent-Type: multipart/related; type=\"multipart/alternative\"; boundary=\"\(relatedContent.boundary)\"\r\n\r\n\(relatedContent.body)--\(mixedBoundary)\r\n\(regularParts)--\(mixedBoundary)--\r\n"
            } else {
                contentType = "multipart/mixed; boundary=\"\(mixedBoundary)\""
                let regularParts = regularAttachments.map { attachmentPart($0, boundary: mixedBoundary) }.joined()
                content = "--\(mixedBoundary)\r\nContent-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"\r\n\r\n\(alternative)--\(mixedBoundary)\r\n\(regularParts)--\(mixedBoundary)--\r\n"
            }
        } else if let relatedContent {
            contentType = "multipart/related; type=\"multipart/alternative\"; boundary=\"\(relatedContent.boundary)\""
            content = relatedContent.body
        } else {
            contentType = "multipart/alternative; boundary=\"\(alternativeBoundary)\""
            content = alternative
        }
        let headers = [
            "From: \(fromHeader)",
            "To: \(recipients.map { "<\($0)>" }.joined(separator: ", "))",
            "Date: \(dateFormatter.string(from: Date()))",
            "Message-ID: \(messageID)",
            "Subject: \(subjectHeader)",
            "MIME-Version: 1.0",
            "Content-Type: \(contentType)"
        ].joined(separator: "\r\n")
        return headers + "\r\n\r\n" + content
    }

    private static func multipartAlternative(_ body: OutgoingEmailBody, boundary: String) -> String {
        let plain = encodedPart(body.plainText, contentType: "text/plain; charset=UTF-8", boundary: boundary)
        let html = encodedPart(body.html, contentType: "text/html; charset=UTF-8", boundary: boundary)
        return plain + html + "--\(boundary)--\r\n"
    }

    private static func encodedPart(_ text: String, contentType: String, boundary: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let body = base64Lines(Data(normalized.utf8))
        return "--\(boundary)\r\nContent-Type: \(contentType)\r\nContent-Transfer-Encoding: base64\r\n\r\n\(body)\r\n"
    }

    private static func attachmentPart(_ attachment: MailAttachment, boundary: String) -> String {
        let filename = rfc2231(attachment.fileName)
        let contentType = attachment.mimeType.contains("\r") || attachment.mimeType.contains("\n")
            ? "application/octet-stream" : attachment.mimeType
        let body = base64Lines(attachment.data)
        let disposition = attachment.contentID == nil ? "attachment" : "inline"
        let contentID = attachment.contentID.map { "Content-ID: <\($0)>\r\n" } ?? ""
        return "--\(boundary)\r\nContent-Type: \(contentType); name*=UTF-8''\(filename)\r\nContent-Disposition: \(disposition); filename*=UTF-8''\(filename)\r\n\(contentID)Content-Transfer-Encoding: base64\r\n\r\n\(body)\r\n"
    }

    private static func replaceInlineDataImages(in html: String) -> (String, [MailAttachment]) {
        let pattern = #"(?i)data:(image/[A-Za-z0-9.+-]+);base64,([A-Za-z0-9+/=\r\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (html, []) }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return (html, []) }
        let mutableHTML = NSMutableString(string: html)
        var attachments: [MailAttachment] = []
        var totalBytes = 0
        let maxInlineBytes = 4 * 1024 * 1024
        for match in matches.reversed() {
            let mimeType = nsHTML.substring(with: match.range(at: 1)).lowercased()
            let encoded = nsHTML.substring(with: match.range(at: 2)).filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
                  totalBytes + data.count <= maxInlineBytes else {
                mutableHTML.replaceCharacters(in: match.range, with: "")
                continue
            }
            totalBytes += data.count
            let contentID = "hackmail-inline-\(UUID().uuidString.lowercased())"
            let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "bin"
            attachments.append(MailAttachment(id: UUID(), fileName: "inline-image.\(ext)", mimeType: mimeType, data: data, contentID: contentID))
            mutableHTML.replaceCharacters(in: match.range, with: "cid:\(contentID)")
        }
        return (mutableHTML as String, attachments)
    }

    private static func base64Lines(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        return stride(from: 0, to: encoded.count, by: 76).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(76, encoded.distance(from: start, to: encoded.endIndex)))
            return String(encoded[start..<end])
        }.joined(separator: "\r\n")
    }

    private static func rfc2231(_ value: String) -> String {
        value.utf8.map { byte in
            let isSafe = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || [45, 46, 95, 126].contains(byte)
            return isSafe ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }

    /// RFC 2047 limits each encoded word to 75 characters, so long non-ASCII text is split on character
    /// boundaries into several base64 words joined by header folding (CRLF + space).
    static func encodedWords(_ text: String) -> String {
        let maximumChunkBytes = 45 // 45 raw bytes -> 60 base64 chars; with "=?UTF-8?B?" and "?=" that is 72.
        var chunks: [String] = []
        var current = ""
        for character in text {
            if current.utf8.count + String(character).utf8.count > maximumChunkBytes, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    static func encodedSubject(_ subject: String) -> String {
        guard !subject.unicodeScalars.allSatisfy(\.isASCII) else { return subject }
        return encodedWords(subject)
    }

    static func encodedDisplayName(_ name: String) -> String {
        if name.unicodeScalars.allSatisfy(\.isASCII) {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return encodedWords(name)
    }
}

private enum SMTPError: LocalizedError {
    case connection(String)
    case protocolError(String)
    case server(Int, String)
    case authentication
    case invalidMessage
    case deliveryUncertain
    case timeout
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .connection(let detail): "Could not connect to Gmail SMTP: \(detail)"
        case .protocolError(let detail): "Gmail returned an unexpected SMTP response: \(detail)"
        case .server(let code, let detail): "Gmail could not send the message (\(code)): \(detail)"
        case .authentication: "Gmail rejected the app password for sending. Check the account in Settings."
        case .invalidMessage: "Enter a valid sender, recipient, and single-line subject. Separate recipients with commas."
        case .deliveryUncertain: "The connection ended while Gmail was acknowledging the message. Check Sent before retrying to avoid a duplicate."
        case .timeout: "Gmail SMTP did not respond in time. Check your connection and try again."
        case .responseTooLarge: "Gmail SMTP sent a response larger than HackMail accepts, so sending was stopped."
        }
    }
}

private actor SMTPSession {
    private struct Reply {
        let code: Int
        let lines: [String]
        var summary: String { lines.joined(separator: " ") }
    }

    private static let connectTimeout: Duration = .seconds(20)
    private static let defaultReceiveTimeout: Duration = .seconds(30)
    // Gmail confirms a message only after receiving the whole payload, which can be tens of MiB.
    private static let acceptanceTimeout: Duration = .seconds(180)
    private static let maximumLineBytes = 64 * 1024
    private static let maximumReplyLines = 200

    private let queue = DispatchQueue(label: "HackMail.GmailSMTP")
    private var receiveTimeout: Duration = SMTPSession.defaultReceiveTimeout
    private var connection: NWConnection?
    private var buffered = Data()

    func open() async throws {
        guard let port = NWEndpoint.Port(rawValue: 465) else {
            throw SMTPError.connection("Invalid SMTP port.")
        }
        let connection = NWConnection(host: "smtp.gmail.com", port: port, using: .tls)
        self.connection = connection
        let deadline = ConnectionDeadline(after: Self.connectTimeout, connection: connection)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: SMTPError.connection(error.localizedDescription))
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: SMTPError.connection("Connection was cancelled."))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } catch {
            throw deadline.finish() ? SMTPError.timeout : error
        }
        deadline.finish()
        let greeting = try await readReply()
        try require(greeting, codes: [220])
        let hello = try await command("EHLO localhost")
        try require(hello, codes: [250])
    }

    func authenticate(email: String, password: String) async throws {
        let response: Reply
        do {
            response = try await command("AUTH LOGIN")
            try require(response, codes: [334])
            let userResponse = try await command(Data(email.utf8).base64EncodedString())
            try require(userResponse, codes: [334])
            let passwordResponse = try await command(Data(password.utf8).base64EncodedString())
            try require(passwordResponse, codes: [235])
        } catch SMTPError.server(let code, _) where code == 535 || code == 534 {
            throw SMTPError.authentication
        }
    }

    func sendMessage(from: String, fromName: String, recipients: [String], subject: String, body: OutgoingEmailBody, attachments: [MailAttachment]) async throws {
        let senderResponse = try await command("MAIL FROM:<\(from)>")
        try require(senderResponse, codes: [250])
        for recipient in recipients {
            let recipientResponse = try await command("RCPT TO:<\(recipient)>")
            try require(recipientResponse, codes: [250, 251])
        }
        let dataResponse = try await command("DATA")
        try require(dataResponse, codes: [354])

        let payload = SMTPMessageBuilder.build(from: from, fromName: fromName, recipients: recipients, subject: subject, body: body, attachments: attachments)
        do {
            try await send(payload + ".\r\n")
            receiveTimeout = Self.acceptanceTimeout
            defer { receiveTimeout = Self.defaultReceiveTimeout }
            let accepted = try await readReply()
            try require(accepted, codes: [250])
        } catch SMTPError.server(let code, let detail) {
            throw SMTPError.server(code, detail)
        } catch {
            throw SMTPError.deliveryUncertain
        }
    }

    func quit() async throws {
        let response = try await command("QUIT")
        try require(response, codes: [221])
    }

    func close() {
        connection?.cancel()
        connection = nil
        buffered.removeAll(keepingCapacity: false)
    }

    private func command(_ value: String) async throws -> Reply {
        try await send(value + "\r\n")
        return try await readReply()
    }

    private func readReply() async throws -> Reply {
        var lines: [String] = []
        var responseCode: Int?
        while true {
            let line = try await readLine()
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw SMTPError.protocolError(line)
            }
            if let responseCode, responseCode != code {
                throw SMTPError.protocolError("Mismatched response codes in multiline reply.")
            }
            responseCode = code
            lines.append(line.count > 4 ? String(line.dropFirst(4)) : "")
            guard lines.count <= Self.maximumReplyLines else { throw SMTPError.responseTooLarge }
            guard line.count < 4 || line[line.index(line.startIndex, offsetBy: 3)] != "-" else { continue }
            return Reply(code: code, lines: lines)
        }
    }

    private func require(_ reply: Reply, codes: Set<Int>) throws {
        guard codes.contains(reply.code) else { throw SMTPError.server(reply.code, reply.summary) }
    }

    private func require(_ reply: Reply, codes: [Int]) throws {
        try require(reply, codes: Set(codes))
    }

    private func send(_ string: String) async throws {
        guard let connection else { throw SMTPError.connection("Not connected.") }
        let data = Data(string.utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: SMTPError.connection(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    private func readLine() async throws -> String {
        let delimiter = Data([0x0D, 0x0A])
        while true {
            if let range = buffered.range(of: delimiter) {
                let lineData = buffered.subdata(in: buffered.startIndex..<range.lowerBound)
                buffered.removeSubrange(buffered.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            guard buffered.count <= Self.maximumLineBytes else { throw SMTPError.responseTooLarge }
            try await receiveMore()
        }
    }

    private func receiveMore() async throws {
        guard let connection else { throw SMTPError.connection("Connection closed.") }
        let deadline = ConnectionDeadline(after: receiveTimeout, connection: connection)
        let data: Data
        do {
            data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: SMTPError.connection(error.localizedDescription))
                    } else if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(throwing: SMTPError.connection("Gmail closed the connection."))
                    } else {
                        continuation.resume(throwing: SMTPError.connection("Gmail returned an empty response."))
                    }
                }
            }
        } catch {
            throw deadline.finish() ? SMTPError.timeout : error
        }
        deadline.finish()
        buffered.append(data)
    }

}
