import Foundation
import CoreFoundation
import Network

struct GmailIMAPClient {
    static let maximumAttachmentDownloadBytes = 25 * 1024 * 1024

    func fetchMailbox(
        email: String,
        password: String,
        path: String,
        limit: Int = 30,
        progress: (@Sendable (MailboxLoadProgress) -> Void)? = nil
    ) async throws -> MailboxSnapshot {
        try await withSession(email: email, password: password, progress: progress) { session in
            let mailboxes = try await session.fetchMailboxes()
            let messages = try await session.fetchMailbox(path: path, limit: limit)
            return MailboxSnapshot(mailboxes: mailboxes, messages: messages)
        }
    }

    func searchMailbox(
        email: String,
        password: String,
        path: String,
        query: String,
        limit: Int = 30,
        progress: (@Sendable (MailboxLoadProgress) -> Void)? = nil
    ) async throws -> MailboxSearchSnapshot {
        guard !query.isEmpty, query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw IMAPError.invalidSearchQuery
        }
        return try await withSession(email: email, password: password, progress: progress) { session in
            let matchingUIDs = try await session.searchMailbox(path: path, query: query)
            await session.report(.searchFetchingHeaders)
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

    func waitForInboxChange(
        email: String,
        password: String,
        knownMessageCount: Int?,
        knownLatestUID: Int?,
        timeout: Duration = .seconds(1_500)
    ) async throws -> InboxIdleUpdate {
        try await withSession(email: email, password: password) { session in
            let currentCount = try await session.selectMailboxAndGetMessageCount(path: "INBOX")
            let unreadCount = try await session.unseenMessageCount()
            let currentUIDs = try await session.searchUIDs(after: knownLatestUID)
            if let knownLatestUID, !currentUIDs.isEmpty {
                let headers = try await session.fetchMessages(uids: Array(currentUIDs.suffix(5)), mailboxPath: "INBOX")
                return InboxIdleUpdate(
                    messageCount: currentCount,
                    unreadCount: unreadCount,
                    hasNewMessages: true,
                    hasMailboxChange: true,
                    newestUID: currentUIDs.max() ?? knownLatestUID,
                    newMessageCount: currentUIDs.count,
                    newSubjects: headers.map(\.subject)
                )
            }
            if knownLatestUID != nil, currentUIDs.isEmpty,
               let knownMessageCount, currentCount > knownMessageCount {
                let allUIDs = try await session.searchUIDs(after: nil)
                let count = max(1, currentCount - knownMessageCount)
                let fallbackUIDs = Array(allUIDs.suffix(min(count, 5)))
                let headers = try await session.fetchMessages(uids: fallbackUIDs, mailboxPath: "INBOX")
                return InboxIdleUpdate(
                    messageCount: currentCount,
                    unreadCount: unreadCount,
                    hasNewMessages: true,
                    hasMailboxChange: true,
                    newestUID: allUIDs.max(),
                    newMessageCount: count,
                    newSubjects: headers.map(\.subject)
                )
            }
            let startingUID = knownLatestUID ?? currentUIDs.max()
            let idleUpdate = try await session.waitForInboxExists(after: currentCount, timeout: timeout)
            var newUIDs = try await session.searchUIDs(after: startingUID)
            var newMessageCount = newUIDs.count
            var newestUID = newUIDs.max() ?? startingUID
            if newUIDs.isEmpty, idleUpdate.sawNewMessage {
                let allUIDs = try await session.searchUIDs(after: nil)
                newMessageCount = max(1, idleUpdate.messageCount - currentCount)
                newUIDs = Array(allUIDs.suffix(min(newMessageCount, 5)))
                newestUID = allUIDs.max() ?? startingUID
            }
            let headers = try await session.fetchMessages(uids: Array(newUIDs.suffix(5)), mailboxPath: "INBOX")
            let latestUnreadCount = try await session.unseenMessageCount()
            return InboxIdleUpdate(
                messageCount: idleUpdate.messageCount,
                unreadCount: latestUnreadCount,
                hasNewMessages: idleUpdate.sawNewMessage || !newUIDs.isEmpty,
                hasMailboxChange: idleUpdate.hasMailboxChange || !newUIDs.isEmpty,
                newestUID: newestUID,
                newMessageCount: newMessageCount,
                newSubjects: headers.map(\.subject)
            )
        }
    }

    func fetchInboxMonitorState(email: String, password: String) async throws -> InboxMonitorState {
        try await withSession(email: email, password: password) { session in
            let messageCount = try await session.selectMailboxAndGetMessageCount(path: "INBOX")
            let unreadCount = try await session.unseenMessageCount()
            let latestUID = try await session.searchUIDs(after: nil).max()
            return InboxMonitorState(messageCount: messageCount, unreadCount: unreadCount, latestUID: latestUID)
        }
    }

    func fetchBody(uid: Int, mailboxPath: String, email: String, password: String, full: Bool = false, preferHTML: Bool = true) async throws -> FetchedMessageBody {
        try await withSession(email: email, password: password) { session in
            try await session.selectMailbox(path: mailboxPath)
            return try await session.fetchBody(uid: uid, full: full, preferHTML: preferHTML)
        }
    }

    func fetchAttachment(
        uid: Int,
        mailboxPath: String,
        attachment: MailAttachmentInfo,
        email: String,
        password: String
    ) async throws -> Data {
        guard attachment.encodedSize <= Self.maximumAttachmentDownloadBytes else {
            throw IMAPError.attachmentTooLarge
        }
        return try await withSession(email: email, password: password) { session in
            try await session.selectMailbox(path: mailboxPath)
            return try await session.fetchAttachment(
                uid: uid,
                section: attachment.section,
                transferEncoding: attachment.transferEncoding,
                maximumBytes: Self.maximumAttachmentDownloadBytes
            )
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

    func markAsRead(uid: Int, mailboxPath: String, email: String, password: String) async throws {
        try await withSession(email: email, password: password) { session in
            try await session.selectMailbox(path: mailboxPath)
            try await session.markAsRead(uid: uid)
        }
    }

    func setStarred(uids: [Int], mailboxPath: String, starred: Bool, email: String, password: String) async throws {
        guard !uids.isEmpty else { return }
        try await withSession(email: email, password: password, shouldLogout: false) { session in
            try await session.selectMailbox(path: mailboxPath)
            try await session.setStarred(uids: uids, starred: starred)
        }
    }

    func move(uid: Int, from mailboxPath: String, to destination: String, email: String, password: String) async throws {
        try await withSession(email: email, password: password) { session in
            try await session.selectMailbox(path: mailboxPath)
            try await session.move(uid: uid, to: destination)
        }
    }

    func move(uids: [Int], from mailboxPath: String, to destination: String, email: String, password: String) async throws {
        guard !uids.isEmpty else { return }
        try await withSession(email: email, password: password) { session in
            try await session.selectMailbox(path: mailboxPath)
            try await session.move(uids: uids, to: destination)
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

    func delete(uids: [Int], mailboxPath: String, isTrash: Bool, trashPath: String?, email: String, password: String) async throws {
        guard !uids.isEmpty else { return }
        try await withSession(email: email, password: password) { session in
            try await session.selectMailbox(path: mailboxPath)
            if isTrash {
                try await session.permanentlyDelete(uids: uids)
            } else if let trashPath {
                try await session.move(uids: uids, to: trashPath)
            } else {
                throw IMAPError.protocolError("Gmail did not provide a Trash mailbox.")
            }
        }
    }

    func archive(uids: [Int], mailboxPath: String, email: String, password: String) async throws {
        guard !uids.isEmpty else { return }
        try await withSession(email: email, password: password) { session in
            try await session.selectMailbox(path: mailboxPath)
            try await session.archive(uids: uids)
        }
    }

    private func withSession<T: Sendable>(
        email: String,
        password: String,
        shouldLogout: Bool = true,
        progress: (@Sendable (MailboxLoadProgress) -> Void)? = nil,
        operation: @Sendable (IMAPSession) async throws -> T
    ) async throws -> T {
        let session = IMAPSession()
        await session.setProgress(progress)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await session.open(email: email, password: password)
                let result = try await operation(session)
                try Task.checkCancellation()
                if shouldLogout {
                    await session.report(.signingOut)
                    try await session.logout()
                }
                await session.close()
                return result
            } catch {
                await session.close()
                throw error
            }
        } onCancel: {
            Task { await session.close() }
        }
    }
}

enum IMAPCommandText {
    /// Wraps `value` in an IMAP quoted string. Rejects CR, LF, NUL and other control characters, which
    /// would otherwise end the command early and let a value inject its own IMAP commands.
    static func quote(_ value: String) throws -> String {
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw IMAPError.invalidCommandText
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// One serial stage of loading a mailbox, reported so the UI can show what is happening.
struct MailboxLoadProgress: Sendable, Equatable {
    static let totalSteps = 6
    static let connecting = MailboxLoadProgress(step: 1, text: "Connecting securely to Gmail…")
    static let signingIn = MailboxLoadProgress(step: 2, text: "Signing in…")
    static let listingFolders = MailboxLoadProgress(step: 3, text: "Loading your folder list…")
    static let openingMailbox = MailboxLoadProgress(step: 4, text: "Opening the folder…")
    static let fetchingHeaders = MailboxLoadProgress(step: 5, text: "Fetching the newest messages…")
    static let signingOut = MailboxLoadProgress(step: 6, text: "Signing out…")
    // A folder search runs the same six stages in a different order after sign-in.
    static let searchOpeningFolder = MailboxLoadProgress(step: 3, text: "Opening the folder…")
    static let searching = MailboxLoadProgress(step: 4, text: "Gmail is searching this folder (large folders can take a while)…")
    static let searchFetchingHeaders = MailboxLoadProgress(step: 5, text: "Fetching the first matching messages…")

    let step: Int
    let text: String

    var displayText: String { "Step \(step) of \(Self.totalSteps) · \(text)" }
}

struct MailboxSnapshot: Sendable {
    let mailboxes: [MailMailbox]
    let messages: [MailMessage]
}

struct MailboxSearchSnapshot: Sendable {
    let matchingUIDs: [Int]
    let messages: [MailMessage]
}

struct InboxIdleUpdate: Sendable {
    let messageCount: Int
    let unreadCount: Int
    let hasNewMessages: Bool
    let hasMailboxChange: Bool
    let newestUID: Int?
    let newMessageCount: Int
    let newSubjects: [String]
}

struct InboxMonitorState: Sendable {
    let messageCount: Int
    let unreadCount: Int
    let latestUID: Int?
}

struct FetchedMessageBody: Sendable {
    let content: String
    let isHTML: Bool
    let isPartial: Bool
    var attachments: [MailAttachmentInfo] = []
}

private enum IMAPError: LocalizedError {
    case connection(String)
    case protocolError(String)
    case authentication
    case noInbox
    case invalidSearchQuery
    case attachmentTooLarge
    case timeout
    case responseTooLarge
    case invalidCommandText

    var errorDescription: String? {
        switch self {
        case .connection(let detail): "Could not connect to Gmail: \(detail)"
        case .protocolError(let detail): "Gmail returned an unexpected IMAP response: \(detail)"
        case .authentication: "Gmail rejected the app password. Check the address and app password in Account Settings."
        case .noInbox: "Gmail did not return an Inbox mailbox."
        case .invalidSearchQuery: "Enter a Gmail search query without line breaks or control characters."
        case .attachmentTooLarge: "This attachment exceeds HackMail's 25 MiB download limit."
        case .timeout: "Gmail did not respond in time. Check your connection and try again."
        case .invalidCommandText: "A value contained line breaks or control characters and was not sent to Gmail."
        case .responseTooLarge: "Gmail sent a response larger than HackMail accepts, so the request was stopped."
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

    // Network safety limits. A stalled server must not hang a request forever, and a hostile or
    // buggy server must not be able to grow memory without bound.
    private static let connectTimeout: Duration = .seconds(20)
    private static let defaultReceiveTimeout: Duration = .seconds(30)
    private static let searchReceiveTimeout: Duration = .seconds(180)
    private static let maximumLineBytes = 2 * 1024 * 1024
    private static let maximumLiteralBytes = 32 * 1024 * 1024
    private static let maximumResponseBytes = 64 * 1024 * 1024

    private let queue = DispatchQueue(label: "HackMail.GmailIMAP")
    private var receiveTimeout: Duration = IMAPSession.defaultReceiveTimeout
    private var progress: (@Sendable (MailboxLoadProgress) -> Void)?
    private var connection: NWConnection?
    private var buffered = Data()
    private var nextTag = 1
    private var capabilities: Set<String> = []
    private var activeIdleTag: String?
    private var didSendIdleDone = false

    func setProgress(_ progress: (@Sendable (MailboxLoadProgress) -> Void)?) {
        self.progress = progress
    }

    func report(_ step: MailboxLoadProgress) {
        progress?(step)
    }

    func open(email: String, password: String) async throws {
        report(.connecting)
        let endpoint = NWEndpoint.Host("imap.gmail.com")
        guard let port = NWEndpoint.Port(rawValue: 993) else {
            throw IMAPError.connection("Invalid IMAP port.")
        }
        let connection = NWConnection(host: endpoint, port: port, using: .tls)
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
        } catch {
            throw deadline.finish() ? IMAPError.timeout : error
        }
        deadline.finish()

        let greeting = try await readLine()
        guard greeting.uppercased().contains("* OK") else {
            throw IMAPError.protocolError(greeting)
        }
        report(.signingIn)
        do {
            _ = try await command("LOGIN \(try quote(email)) \(try quote(password))")
        } catch IMAPError.protocolError(let detail) where detail.localizedCaseInsensitiveContains("NO") || detail.localizedCaseInsensitiveContains("AUTHENTICATIONFAILED") {
            throw IMAPError.authentication
        }
    }

    func fetchMailboxes() async throws -> [MailMailbox] {
        report(.listingFolders)
        let response = try await command("LIST \"\" \"*\"")
        return response.lines.compactMap(IMAPServerResponseParser.parseMailbox)
            .filter { !$0.attributes.contains(where: { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame }) }
            .sorted { left, right in
                if left.isInbox != right.isInbox { return left.isInbox }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    func fetchMailbox(path: String, limit: Int) async throws -> [MailMessage] {
        // Fetch the newest messages by sequence number. UID SEARCH ALL returns every UID in the
        // mailbox, which is slow (and a huge single response) for large folders like Archive.
        report(.openingMailbox)
        let total = try await selectMailboxAndGetMessageCount(path: path)
        guard total > 0 else { return [] }
        report(.fetchingHeaders)
        let first = max(1, total - max(1, limit) + 1)
        let response = try await command("FETCH \(first):\(total) (UID FLAGS INTERNALDATE ENVELOPE BODYSTRUCTURE)")
        return response.lines.compactMap { IMAPServerResponseParser.parseMessage($0, mailboxPath: path) }
            .sorted { $0.id > $1.id }
    }

    func searchUIDs(after lastUID: Int?) async throws -> [Int] {
        let searchCommand: String
        if let lastUID, lastUID >= 0, lastUID < Int(UInt32.max) {
            searchCommand = "UID SEARCH UID \(lastUID + 1):*"
        } else {
            searchCommand = "UID SEARCH ALL"
        }
        let response = try await command(searchCommand)
        return IMAPServerResponseParser.parseSearchUIDs(response.lines, greaterThan: lastUID)
    }

    func unseenMessageCount() async throws -> Int {
        let response = try await command("UID SEARCH UNSEEN")
        return IMAPServerResponseParser.parseSearchUIDs(response.lines).count
    }

    func searchMailbox(path: String, query: String) async throws -> [Int] {
        report(.searchOpeningFolder)
        try await selectMailbox(path: path)
        report(.searching)
        // Gmail sends nothing until the search finishes, which can take a long time on a big folder.
        // Allow a generous silent period; the user can still cancel from the UI.
        receiveTimeout = Self.searchReceiveTimeout
        defer { receiveTimeout = Self.defaultReceiveTimeout }
        let response = try await command("UID SEARCH X-GM-RAW \(try quote(query))")
        return IMAPServerResponseParser.parseSearchUIDs(response.lines).sorted(by: >)
    }

    func fetchMessages(uids: [Int], mailboxPath: String) async throws -> [MailMessage] {
        guard !uids.isEmpty else { return [] }
        try await selectMailbox(path: mailboxPath)
        let uidSet = uids.map(String.init).joined(separator: ",")
        let response = try await command("UID FETCH \(uidSet) (UID FLAGS INTERNALDATE ENVELOPE BODYSTRUCTURE)")
        return response.lines.compactMap { IMAPServerResponseParser.parseMessage($0, mailboxPath: mailboxPath) }
            .sorted { $0.id > $1.id }
    }

    func selectMailbox(path: String) async throws {
        _ = try await selectMailboxAndGetMessageCount(path: path)
    }

    func selectMailboxAndGetMessageCount(path: String) async throws -> Int {
        let selected = try await command("SELECT \(try quote(path))")
        guard selected.lines.contains(where: { $0.localizedCaseInsensitiveContains("EXISTS") }) ||
                selected.lines.contains(where: { $0.localizedCaseInsensitiveContains("READ-WRITE") }) else {
            throw IMAPError.protocolError("Could not select mailbox \(path).")
        }
        return IMAPServerResponseParser.parseExistsCount(selected.lines) ?? 0
    }

    func waitForInboxExists(after initialCount: Int, timeout: Duration) async throws -> (messageCount: Int, sawNewMessage: Bool, hasMailboxChange: Bool) {
        try await loadCapabilities()
        guard capabilities.contains("IDLE") else {
            throw IMAPError.protocolError("This Gmail server does not support IMAP IDLE.")
        }

        let tag = String(format: "A%04d", nextTag)
        nextTag += 1
        activeIdleTag = tag
        didSendIdleDone = false
        // IDLE is silent until something changes; allow the full keepalive window plus grace.
        receiveTimeout = timeout + .seconds(90)
        try await send("\(tag) IDLE\r\n")
        let continuation = try await readLine()
        guard continuation.hasPrefix("+") else {
            throw IMAPError.protocolError(continuation)
        }

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                try await self.finishIdle(tag: tag)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        defer {
            timeoutTask.cancel()
            receiveTimeout = Self.defaultReceiveTimeout
            activeIdleTag = nil
            didSendIdleDone = false
        }

        var latestCount = initialCount
        var sawNewMessage = false
        var hasMailboxChange = false
        while true {
            let line = try await readLine()
            if line.uppercased().hasPrefix("* BYE") {
                throw IMAPError.connection(line)
            }
            if let existsCount = IMAPServerResponseParser.parseExistsCount([line]) {
                if existsCount != latestCount {
                    hasMailboxChange = true
                    if existsCount > latestCount { sawNewMessage = true }
                    try await finishIdle(tag: tag)
                }
                latestCount = existsCount
            }
            let uppercasedLine = line.uppercased()
            if (uppercasedLine.contains(" FETCH ") && uppercasedLine.contains(" FLAGS ")) || uppercasedLine.contains(" EXPUNGE") {
                hasMailboxChange = true
                try await finishIdle(tag: tag)
            }
            if line.hasPrefix("\(tag) ") {
                let response = line.dropFirst(tag.count + 1).uppercased()
                if response.hasPrefix("NO") || response.hasPrefix("BAD") {
                    throw IMAPError.protocolError(line)
                }
                return (latestCount, sawNewMessage, hasMailboxChange)
            }
        }
    }

    private func finishIdle(tag: String) async throws {
        guard activeIdleTag == tag, !didSendIdleDone else { return }
        didSendIdleDone = true
        try await send("DONE\r\n")
    }

    func fetchBody(uid: Int, full: Bool, preferHTML: Bool) async throws -> FetchedMessageBody {
        // Resolve MIME metadata first, then fetch only the selected text part and CID images.
        // Regular attachment bytes are fetched only after an explicit user save action.
        let structureResponse = try await command("UID FETCH \(uid) (BODYSTRUCTURE)")
        guard let structure = Self.parseBodyStructure(structureResponse.lines),
              let bodyPart = Self.preferredTextPart(in: structure, preferHTML: preferHTML) else {
            throw IMAPError.protocolError("This message has no supported plain-text or HTML body part.")
        }
        let attachments = IMAPAttachmentParser.parse(structureResponse.lines)
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
        guard bodyPart.isHTML, !bodyPart.inlineImages.isEmpty else {
            return FetchedMessageBody(
                content: fetchedBody.content,
                isHTML: fetchedBody.isHTML,
                isPartial: fetchedBody.isPartial,
                attachments: attachments
            )
        }
        let inlineImages = try await fetchInlineImages(uid: uid, parts: bodyPart.inlineImages)
        let html = IMAPInlineImageResolver.replacingCIDReferences(in: fetchedBody.content, with: inlineImages)
        return FetchedMessageBody(content: html, isHTML: true, isPartial: fetchedBody.isPartial, attachments: attachments)
    }

    func fetchAttachment(uid: Int, section: String, transferEncoding: String, maximumBytes: Int) async throws -> Data {
        guard section.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil else {
            throw IMAPError.protocolError("Gmail returned an invalid attachment part number.")
        }
        let response = try await command("UID FETCH \(uid) (BODY.PEEK[\(section)])")
        guard let encoded = response.segments.compactMap({ segment -> Data? in
            guard case .literal(let data) = segment else { return nil }
            return data
        }).first else {
            throw IMAPError.protocolError("Gmail returned no attachment data.")
        }
        let decoded = Self.decodeTransferData(encoded, encoding: transferEncoding)
        guard decoded.count <= maximumBytes else { throw IMAPError.attachmentTooLarge }
        return decoded
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
        try await archive(uids: [uid])
    }

    func archive(uids: [Int]) async throws {
        guard let uidSet = makeUIDSet(uids) else { return }
        try await loadCapabilities()
        guard capabilities.contains("X-GM-EXT-1") else {
            throw IMAPError.protocolError("Gmail's label extension is unavailable; archive was not performed.")
        }
        _ = try await command("UID STORE \(uidSet) -X-GM-LABELS.SILENT (\\Inbox)")
    }

    func setStarred(uid: Int, starred: Bool) async throws {
        try await setStarred(uids: [uid], starred: starred)
    }

    func setStarred(uids: [Int], starred: Bool) async throws {
        guard let uidSet = makeUIDSet(uids) else { return }
        let operation = starred ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
        _ = try await command("UID STORE \(uidSet) \(operation) (\\Flagged)")
    }

    func markAsRead(uid: Int) async throws {
        _ = try await command("UID STORE \(uid) +FLAGS.SILENT (\\Seen)")
    }

    func move(uid: Int, to destination: String) async throws {
        try await move(uids: [uid], to: destination)
    }

    func move(uids: [Int], to destination: String) async throws {
        guard let uidSet = makeUIDSet(uids) else { return }
        try await loadCapabilities()
        if capabilities.contains("MOVE") {
            let moveCommand = "UID MOVE \(uidSet) \(try quote(destination))"
            do {
                _ = try await command(moveCommand)
            } catch IMAPError.protocolError(let detail) where detail.localizedCaseInsensitiveContains("SYSTEM ERROR") {
                // UID MOVE is atomic and keyed by the source UID, so a single retry is safe:
                // if Gmail completed the first attempt but returned a transient error, the
                // second command simply finds no source UID to move.
                _ = try await command(moveCommand)
            }
        } else if capabilities.contains("UIDPLUS") {
            _ = try await command("UID COPY \(uidSet) \(try quote(destination))")
            _ = try await command("UID STORE \(uidSet) +FLAGS.SILENT (\\Deleted)")
            _ = try await command("UID EXPUNGE \(uidSet)")
        } else {
            throw IMAPError.protocolError("This Gmail server does not support a safe move operation.")
        }
    }

    func permanentlyDelete(uid: Int) async throws {
        try await permanentlyDelete(uids: [uid])
    }

    func permanentlyDelete(uids: [Int]) async throws {
        guard let uidSet = makeUIDSet(uids) else { return }
        try await loadCapabilities()
        guard capabilities.contains("UIDPLUS") else {
            throw IMAPError.protocolError("This Gmail server does not support safe permanent deletion.")
        }
        _ = try await command("UID STORE \(uidSet) +FLAGS.SILENT (\\Deleted)")
        _ = try await command("UID EXPUNGE \(uidSet)")
    }

    private func makeUIDSet(_ uids: [Int]) -> String? {
        let uniqueUIDs = Array(Set(uids.filter { $0 > 0 })).sorted()
        guard !uniqueUIDs.isEmpty else { return nil }
        return uniqueUIDs.map(String.init).joined(separator: ",")
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
        var responseBytes = 0
        while true {
            let line = try await readLineData()
            segments.append(.line(line))
            responseBytes += line.count
            let text = String(decoding: line, as: UTF8.self)
            if let literalCount = Self.literalLength(in: text) {
                responseBytes += max(0, literalCount)
                guard literalCount <= Self.maximumLiteralBytes, responseBytes <= Self.maximumResponseBytes else {
                    throw IMAPError.responseTooLarge
                }
                segments.append(.literal(try await readExactly(literalCount)))
            }
            guard responseBytes <= Self.maximumResponseBytes else { throw IMAPError.responseTooLarge }
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
            guard buffered.count <= Self.maximumLineBytes else { throw IMAPError.responseTooLarge }
            try await receiveMore()
        }
    }

    private func readExactly(_ count: Int) async throws -> Data {
        guard count >= 0 else { throw IMAPError.protocolError("Invalid literal length.") }
        guard count <= Self.maximumLiteralBytes else { throw IMAPError.responseTooLarge }
        while buffered.count < count { try await receiveMore() }
        let result = buffered.prefix(count)
        buffered.removeFirst(count)
        return Data(result)
    }

    private func receiveMore() async throws {
        guard let connection else { throw IMAPError.connection("Connection closed.") }
        let deadline = ConnectionDeadline(after: receiveTimeout, connection: connection)
        let chunk: Data
        do {
            chunk = try await withCheckedThrowingContinuation { continuation in
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
        } catch {
            throw deadline.finish() ? IMAPError.timeout : error
        }
        deadline.finish()
        buffered.append(chunk)
    }

    private func quote(_ value: String) throws -> String {
        try IMAPCommandText.quote(value)
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
    static func parseSearchUIDs(_ lines: [String], greaterThan lastUID: Int?) -> [Int] {
        let uids = parseSearchUIDs(lines)
        guard let lastUID else { return uids }
        return uids.filter { $0 > lastUID }
    }

    static func parseExistsCount(_ lines: [String]) -> Int? {
        for line in lines {
            let components = line.split(whereSeparator: \.isWhitespace)
            guard components.count >= 3,
                  components[0] == "*",
                  components[2].caseInsensitiveCompare("EXISTS") == .orderedSame,
                  let count = Int(components[1]) else { continue }
            return count
        }
        return nil
    }

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
            mailboxPath: mailboxPath,
            attachments: IMAPAttachmentParser.parse([line]),
            toRecipients: envelope.count > 5 ? addressList(envelope[5]) : [],
            ccRecipients: envelope.count > 6 ? addressList(envelope[6]) : [],
            bccRecipients: envelope.count > 7 ? addressList(envelope[7]) : []
        )
    }

    /// Every usable address in an ENVELOPE address list. Group start/end markers (no mailbox or host) are skipped.
    fileprivate static func addressList(_ value: IMAPValue) -> [MailAddress] {
        guard case .list(let entries) = value else { return [] }
        return entries.compactMap { entry in
            guard case .list(let address) = entry, address.count >= 4 else { return nil }
            let mailbox = address[2].stringValue ?? ""
            let host = address[3].stringValue ?? ""
            guard !mailbox.isEmpty, !host.isEmpty else { return nil }
            let name = address[0].stringValue ?? ""
            return MailAddress(name: decodeHeader(name) ?? name, email: "\(mailbox)@\(host)")
        }
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

    static func decodeHeader(_ value: String) -> String? {
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

enum IMAPAttachmentParser {
    static func parse(_ lines: [String]) -> [MailAttachmentInfo] {
        guard let structure = bodyStructure(in: lines) else { return [] }
        var attachments: [MailAttachmentInfo] = []
        collectAttachments(in: structure, section: "", into: &attachments)
        return attachments
    }

    private static func bodyStructure(in lines: [String]) -> IMAPValue? {
        for line in lines {
            let tokens = IMAPTokenizer(line).tokens
            guard tokens.count > 4, tokens[0] == .atom("*"), tokens[2] == .atom("FETCH") else { continue }
            var cursor = 4
            while cursor < tokens.count, tokens[cursor] != .rightParen {
                guard case .atom(let key) = tokens[cursor] else { cursor += 1; continue }
                cursor += 1
                guard let value = IMAPTokenizer.parseValue(tokens, cursor: &cursor) else { break }
                if key.caseInsensitiveCompare("BODYSTRUCTURE") == .orderedSame { return value }
            }
        }
        return nil
    }

    private static func collectAttachments(in value: IMAPValue, section: String, into attachments: inout [MailAttachmentInfo]) {
        guard case .list(let values) = value, !values.isEmpty else { return }
        var children: [IMAPValue] = []
        for item in values {
            guard case .list = item else { break }
            children.append(item)
        }

        if !children.isEmpty {
            let multipartParameters = values.dropFirst(children.count + 1).first.map(parameterDictionary) ?? [:]
            let disposition = disposition(in: values.dropFirst(children.count + 1))
            let filename = disposition?.parameters["filename"] ?? multipartParameters["name"]
            if disposition?.type == "attachment" || filename != nil {
                let subtype = values.dropFirst(children.count).first?.stringValue?.lowercased() ?? "mixed"
                appendAttachment(
                    section: section,
                    filename: filename,
                    mimeType: "multipart/\(subtype)",
                    size: 0,
                    encoding: "binary",
                    to: &attachments
                )
                return
            }

            for (index, child) in children.enumerated() {
                let childSection = section.isEmpty ? String(index + 1) : "\(section).\(index + 1)"
                collectAttachments(in: child, section: childSection, into: &attachments)
            }
            return
        }

        guard values.count >= 7,
              let mediaType = values[0].stringValue?.lowercased(),
              let subtype = values[1].stringValue?.lowercased() else { return }
        let parameters = parameterDictionary(values[2])
        let disposition = disposition(in: values.dropFirst(7))
        let filename = disposition?.parameters["filename"] ?? parameters["name"]
        let contentID = values[3].stringValue
        let isExplicitAttachment = disposition?.type == "attachment"
        let isNamedAttachment = filename != nil && !(contentID != nil && disposition?.type == "inline")
        guard isExplicitAttachment || isNamedAttachment else { return }

        let size = values[6].stringValue.flatMap(Int.init) ?? 0
        appendAttachment(
            section: section.isEmpty ? "1" : section,
            filename: filename,
            mimeType: "\(mediaType)/\(subtype)",
            size: size,
            encoding: values[5].stringValue?.lowercased() ?? "7bit",
            to: &attachments
        )
    }

    private static func appendAttachment(
        section: String,
        filename: String?,
        mimeType: String,
        size: Int,
        encoding: String,
        to attachments: inout [MailAttachmentInfo]
    ) {
        guard !section.isEmpty else { return }
        let normalizedFilename = filename.flatMap(IMAPServerResponseParser.decodeHeader) ?? filename
        let safeFilename = normalizedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = "attachment-\(section.replacingOccurrences(of: ".", with: "-")).bin"
        attachments.append(MailAttachmentInfo(
            section: section,
            fileName: (safeFilename?.isEmpty == false ? safeFilename : nil) ?? fallbackName,
            mimeType: mimeType,
            encodedSize: max(0, size),
            transferEncoding: encoding
        ))
    }

    private static func disposition(in values: some Collection<IMAPValue>) -> (type: String, parameters: [String: String])? {
        for value in values {
            guard case .list(let items) = value,
                  let type = items.first?.stringValue?.lowercased(),
                  type == "attachment" || type == "inline" else { continue }
            return (type, items.dropFirst().first.map(parameterDictionary) ?? [:])
        }
        return nil
    }

    private static func parameterDictionary(_ value: IMAPValue) -> [String: String] {
        guard case .list(let items) = value else { return [:] }
        var result: [String: String] = [:]
        var index = 0
        while index + 1 < items.count {
            if let key = items[index].stringValue?.lowercased(), let value = items[index + 1].stringValue {
                result[key] = value
            }
            index += 2
        }
        return result
    }
}
