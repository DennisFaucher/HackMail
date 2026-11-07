import Foundation
import AppKit

@MainActor
final class MailStore: ObservableObject {
    @Published var accounts: [MailAccount] = []
    @Published var selectedAccount: String?
    @Published var mailboxes: [MailMailbox] = []
    @Published var selectedMailboxPath = "INBOX"
    @Published var selectedMessageID = -1
    @Published private(set) var multiSelectedMessageIDs: Set<Int> = []
    @Published private(set) var isMultiSelectionActive = false
    @Published private(set) var sortColumn: MessageSortColumn = .date
    @Published private(set) var sortDirection: MessageSortDirection = .descending
    @Published var searchText = ""
    @Published private(set) var activeSearchQuery: String?
    @Published private(set) var searchResultUIDs: [Int] = []
    @Published var searchError: String?
    @Published var isLoadingMoreSearchResults = false
    @Published var showSettings = false
    @Published var selectedContactsContainerIdentifier: String?
    @Published var languageToolEnabled = false
    @Published var languageToolBaseURL = ""
    @Published var languageToolLanguage = "en-US"
    @Published var isComposing = false
    @Published var composeTitle = "New Message"
    @Published var composeTo = ""
    @Published var composeSubject = ""
    @Published var composeBody = NSAttributedString(string: "")
    @Published var composeBodyWasTruncated = false
    @Published var quotedMessage: MailMessage?
    @Published var quotedPlainText = ""
    @Published var composeAttachments: [MailAttachment] = []
    @Published var isSendingMessage = false
    @Published var isPreparingCompose = false
    @Published var composePreparationMessage = ""
    @Published var composePreparationError: String?
    @Published var messages: [MailMessage] = []
    @Published var accountStatuses: [String: String] = [:]
    @Published var accountErrors: [String: String] = [:]
    @Published var syncingAccount: String?
    @Published var activeError: String?
    @Published var pendingPermanentDelete: MailMessage?
    @Published var pendingMultiPermanentDelete: [MailMessage]?
    @Published private(set) var loadingMessageID: Int?

    private let accountsKey = "configured-mail-accounts"
    private let contactsContainerKey = "contacts-container-identifier"
    private let languageToolEnabledKey = "language-tool-enabled-v2"
    private let languageToolBaseURLKey = "language-tool-base-url"
    private let languageToolLanguageKey = "language-tool-language"
    private let defaults: UserDefaults
    private var composePreparationID = UUID()
    private var searchRequestID = UUID()
    private var searchNextUIDOffset = 0
    private var selectionAnchorID: Int?
    private var messageBodyLoadID = UUID()
    private var messageBodyLoadTask: Task<FetchedMessageBody, Error>?
    private var messageBodyBeforeLoad: String?

    static let defaultLanguageToolBaseURL = ""

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedContactsContainerIdentifier = defaults.string(forKey: contactsContainerKey)
        languageToolEnabled = defaults.object(forKey: languageToolEnabledKey) as? Bool ?? false
        languageToolBaseURL = defaults.string(forKey: languageToolBaseURLKey) ?? Self.defaultLanguageToolBaseURL
        languageToolLanguage = defaults.string(forKey: languageToolLanguageKey) ?? "en-US"
        if let data = defaults.data(forKey: accountsKey),
           let saved = try? JSONDecoder().decode([MailAccount].self, from: data) {
            accounts = saved
        } else {
            accounts = []
            persistAccounts()
        }
        selectedAccount = accounts.first?.email
    }

    var filteredMessages: [MailMessage] {
        messages.enumerated().sorted { left, right in
            let order = Self.compare(left.element, right.element, by: sortColumn)
            if order == .orderedSame { return left.offset < right.offset }
            return sortDirection == .ascending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.element)
    }

    func sortMessages(by column: MessageSortColumn) {
        guard syncingAccount == nil else { return }
        if sortColumn == column {
            sortDirection.toggle()
        } else {
            sortColumn = column
            sortDirection = column == .flagged || column == .date ? .descending : .ascending
        }
    }

    private static func compare(_ left: MailMessage, _ right: MailMessage, by column: MessageSortColumn) -> ComparisonResult {
        switch column {
        case .flagged:
            if left.flagged == right.flagged { return .orderedSame }
            return left.flagged ? .orderedDescending : .orderedAscending
        case .subject:
            return left.subject.localizedStandardCompare(right.subject)
        case .sender:
            return left.sender.localizedStandardCompare(right.sender)
        case .date:
            return (left.sortDate ?? .distantPast).compare(right.sortDate ?? .distantPast)
        }
    }

    var canLoadMoreSearchResults: Bool {
        activeSearchQuery != nil && searchNextUIDOffset < searchResultUIDs.count
    }

    var mailboxMessageCountLabel: String {
        if activeSearchQuery != nil {
            return "\(messages.count) of \(searchResultUIDs.count) matches"
        }
        return "\(messages.count) messages"
    }

    var selectedMessage: MailMessage? {
        filteredMessages.first(where: { $0.id == selectedMessageID }) ?? filteredMessages.first
    }

    var selectedMessages: [MailMessage] {
        if isMultiSelectionActive {
            return filteredMessages.filter { multiSelectedMessageIDs.contains($0.id) }
        }
        return selectedMessage.map { [$0] } ?? []
    }

    var selectedMessagesAreAllFlagged: Bool {
        !selectedMessages.isEmpty && selectedMessages.allSatisfy(\.flagged)
    }

    func isMessageSelected(_ messageID: Int) -> Bool {
        isMultiSelectionActive ? multiSelectedMessageIDs.contains(messageID) : selectedMessage?.id == messageID
    }

    func clearMultiSelection() {
        multiSelectedMessageIDs = []
        isMultiSelectionActive = false
        selectionAnchorID = selectedMessageID >= 0 ? selectedMessageID : nil
    }

    var selectedMailbox: MailMailbox? {
        mailboxes.first(where: { $0.path == selectedMailboxPath })
    }

    var favoriteMailboxes: [MailMailbox] {
        mailboxes.filter { mailbox in
            mailbox.isInbox || ["\\Flagged", "\\Drafts", "\\Sent"].contains(where: { flag in
                mailbox.attributes.contains(where: { $0.caseInsensitiveCompare(flag) == .orderedSame })
            })
        }
    }

    var canSendComposedMessage: Bool {
        guard let account = accounts.first(where: { $0.email == selectedAccount }) else { return false }
        return GmailSMTPClient.parseRecipients(composeTo) != nil &&
            !composeSubject.contains("\r") && !composeSubject.contains("\n") &&
            !isSendingMessage && !isPreparingCompose && hasPassword(for: account)
    }

    func beginNewMessage() {
        cancelQuotePreparation()
        composeTitle = "New Message"
        composeTo = ""
        composeSubject = ""
        composeBody = NSAttributedString(string: "")
        composeAttachments = []
        composeBodyWasTruncated = false
        quotedMessage = nil
        quotedPlainText = ""
        composePreparationError = nil
        isComposing = true
    }

    func beginReply() {
        guard let message = selectedMessage, !message.senderEmail.isEmpty else { return }
        composeTitle = "Reply"
        composeTo = message.senderEmail
        composeSubject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        composeAttachments = []
        quotedMessage = nil
        quotedPlainText = ""
        startPreparingQuote(for: message)
    }

    func beginForward() {
        guard let message = selectedMessage else { return }
        composeTitle = "Forward"
        composeTo = ""
        composeSubject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
        composeAttachments = []
        quotedMessage = nil
        quotedPlainText = ""
        startPreparingQuote(for: message)
    }

    func sendComposedMessage() async throws {
        guard let account = accounts.first(where: { $0.email == selectedAccount }) else {
            throw MailComposerError.noAccount
        }
        guard let password = try? KeychainStore.loadPassword(for: account.email) else {
            throw MailComposerError.missingPassword
        }
        guard let recipients = GmailSMTPClient.parseRecipients(composeTo) else {
            throw MailComposerError.invalidRecipients
        }
        guard !composeSubject.contains("\r"), !composeSubject.contains("\n") else {
            throw MailComposerError.invalidSubject
        }
        isSendingMessage = true
        defer { isSendingMessage = false }
        var plainText = composeBody.string
        let htmlData = try? composeBody.data(
            from: NSRange(location: 0, length: composeBody.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
        )
        var html = htmlData.flatMap { String(data: $0, encoding: .utf8) }
            .map(EmailHTMLSanitizer.bodyFragment)
            ?? "<pre>\(EmailHTMLSanitizer.escapeText(plainText))</pre>"
        if let quotedMessage {
            let isReply = composeTitle == "Reply"
            let headerText: String
            if isReply {
                headerText = "On \(quotedMessage.time), \(quotedMessage.sender) wrote:"
            } else {
                headerText = "---------- Forwarded message ----------\nFrom: \(quotedMessage.sender) <\(quotedMessage.senderEmail)>\nDate: \(quotedMessage.time)\nSubject: \(quotedMessage.subject)"
            }
            let quotedHTML: String
            if quotedMessage.bodyIsHTML {
                quotedHTML = EmailHTMLSanitizer.bodyFragment(
                    EmailHTMLSanitizer.forOutgoingMessage(quotedMessage.body, allowRemoteImages: quotedMessage.allowsRemoteImages)
                )
            } else {
                quotedHTML = "<pre>\(EmailHTMLSanitizer.escapeText(quotedPlainText))</pre>"
            }
            plainText += "\n\n\(headerText)\n\(quotedPlainText)"
            html += "<br><br><div>\(EmailHTMLSanitizer.escapeText(headerText))</div><blockquote style=\"border-left:2px solid #d4ccbd;margin-left:0;padding-left:14px\">\(quotedHTML)</blockquote>"
        }
        let htmlDocument = "<!doctype html><html><body>\(html)</body></html>"
        try await GmailSMTPClient().send(
            from: account.email,
            fromName: account.fullName,
            password: password,
            to: recipients,
            subject: composeSubject,
            body: OutgoingEmailBody(plainText: plainText, html: htmlDocument),
            attachments: composeAttachments
        )
        composeTo = ""
        composeSubject = ""
        composeAttachments = []
        composeBody = NSAttributedString(string: "")
        composeBodyWasTruncated = false
        quotedMessage = nil
        quotedPlainText = ""
        accountStatuses[account.email] = "Connected · Message sent"
    }

    func addAttachments(from urls: [URL]) async throws {
        let existingBytes = composeAttachments.reduce(0) { $0 + $1.byteCount }
        let maxBytes = Self.maximumAttachmentBytes
        let additions = try await Task.detached(priority: .userInitiated) {
            try AttachmentLoader.load(urls: urls, existingBytes: existingBytes, maxBytes: maxBytes)
        }.value
        composeAttachments.append(contentsOf: additions)
    }

    func removeAttachment(_ attachment: MailAttachment) {
        composeAttachments.removeAll { $0.id == attachment.id }
    }

    func discardComposition() {
        cancelQuotePreparation()
        composeTitle = "New Message"
        composeTo = ""
        composeSubject = ""
        composeBody = NSAttributedString(string: "")
        composeBodyWasTruncated = false
        quotedMessage = nil
        quotedPlainText = ""
        composeAttachments = []
        isComposing = false
    }

    private func startPreparingQuote(for message: MailMessage) {
        let preparationID = UUID()
        composePreparationID = preparationID
        composeBody = NSAttributedString(string: "")
        composeBodyWasTruncated = false
        composeAttachments = []
        isPreparingCompose = true
        isComposing = true
        composePreparationError = nil
        composePreparationMessage = "Preparing original message…"
        let accountEmail = selectedAccount
        Task { await prepareQuote(for: message, accountEmail: accountEmail, preparationID: preparationID) }
    }

    private func prepareQuote(for message: MailMessage, accountEmail: String?, preparationID: UUID) async {
        var originalBody = message.body
        var isHTML = message.bodyIsHTML
        if message.isRemote && (message.bodyIsPartial || originalBody.isEmpty || message.bodyIsHTML) {
            guard let account = accounts.first(where: { $0.email == accountEmail }),
                  let password = try? KeychainStore.loadPassword(for: account.email) else {
                failQuotePreparation("Could not load the complete original message. Check the Gmail account and try again.", preparationID: preparationID)
                return
            }
            syncingAccount = account.email
            composePreparationMessage = "Loading the complete original message…"
            do {
                let body = try await GmailIMAPClient().fetchBody(
                    uid: message.id,
                    mailboxPath: message.mailboxPath,
                    email: account.email,
                    password: password,
                    full: true,
                    preferHTML: true
                )
                syncingAccount = nil
                guard composePreparationID == preparationID else { return }
                originalBody = body.content
                isHTML = body.isHTML
                if selectedAccount == account.email, selectedMailboxPath == message.mailboxPath {
                    messages = messages.map { item in
                        guard item.id == message.id else { return item }
                        var updated = item
                        updated.body = body.content
                        updated.bodyIsHTML = body.isHTML
                        updated.bodyIsPartial = false
                        updated.bodyIsLoading = false
                        return updated
                    }
                }
            } catch {
                syncingAccount = nil
                failQuotePreparation("Could not load the complete original message: \(error.localizedDescription)", preparationID: preparationID)
                return
            }
        }

        var completeMessage = message
        completeMessage.body = originalBody
        completeMessage.bodyIsHTML = isHTML
        completeMessage.bodyIsPartial = false
        completeMessage.bodyIsLoading = false
        quotedMessage = completeMessage

        composePreparationMessage = "Preparing formatted quote…"
        let result = await Task.detached(priority: .userInitiated) {
            isHTML ? HTMLTextExtractor.extract(originalBody) : HTMLTextExtractor.limitPlainText(originalBody)
        }.value
        guard composePreparationID == preparationID else { return }
        composeBody = NSAttributedString(string: "")
        quotedPlainText = result.text
        composeBodyWasTruncated = result.wasTruncated
        composePreparationMessage = ""
        isPreparingCompose = false
    }

    private func failQuotePreparation(_ message: String, preparationID: UUID) {
        guard composePreparationID == preparationID else { return }
        composePreparationError = message
        composePreparationMessage = ""
        isPreparingCompose = false
    }

    func cancelQuotePreparation() {
        composePreparationID = UUID()
        composePreparationMessage = ""
        composePreparationError = nil
        isPreparingCompose = false
    }

    private static let maximumAttachmentBytes = 18 * 1024 * 1024

    private static func escapeHTML(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return "<html><body><pre>\(escaped)</pre></body></html>"
    }

    func saveAccount(email: String, fullName: String, password: String?) throws {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MailAccountSaveError.invalidName
        }
        if let password, !password.isEmpty {
            try KeychainStore.save(password: password, for: normalizedEmail)
            accountStatuses[normalizedEmail] = nil
        }
        if let index = accounts.firstIndex(where: { $0.email.caseInsensitiveCompare(normalizedEmail) == .orderedSame }) {
            accounts[index].fullName = normalizedName
        } else {
            guard let password, !password.isEmpty else { throw MailComposerError.missingPassword }
            accounts.append(MailAccount(email: normalizedEmail, fullName: normalizedName))
        }
        if selectedAccount != normalizedEmail {
            selectedAccount = normalizedEmail
            selectedMailboxPath = "INBOX"
            mailboxes = []
            messages = []
            selectedMessageID = -1
            searchText = ""
            resetSearchState()
        }
        persistAccounts()
    }

    func selectContactsContainer(_ identifier: String?) {
        selectedContactsContainerIdentifier = identifier
        if let identifier {
            defaults.set(identifier, forKey: contactsContainerKey)
        } else {
            defaults.removeObject(forKey: contactsContainerKey)
        }
    }

    func persistLanguageToolSettings() {
        defaults.set(languageToolEnabled, forKey: languageToolEnabledKey)
        defaults.set(languageToolBaseURL, forKey: languageToolBaseURLKey)
        defaults.set(languageToolLanguage, forKey: languageToolLanguageKey)
    }

    func removeAccount(_ account: MailAccount) {
        KeychainStore.delete(for: account.email)
        let wasSelected = selectedAccount == account.email
        accounts.removeAll { $0.id == account.id }
        if wasSelected {
            selectedAccount = accounts.first?.email
            selectedMailboxPath = "INBOX"
            mailboxes = []
            messages = []
            selectedMessageID = -1
            searchText = ""
            resetSearchState()
            if let nextAccount = accounts.first, hasPassword(for: nextAccount) {
                Task { await refreshMailbox(for: nextAccount) }
            }
        }
        persistAccounts()
    }

    func hasPassword(for account: MailAccount) -> Bool {
        KeychainStore.passwordExists(for: account.email)
    }

    func refreshMailbox(for account: MailAccount) async {
        if selectedAccount == account.email, let activeSearchQuery {
            await performFolderSearch(activeSearchQuery)
            return
        }
        clearMultiSelection()
        guard let password = try? KeychainStore.loadPassword(for: account.email) else {
            accountStatuses[account.email] = "Needs app password"
            accountErrors[account.email] = "Add a Google app password in Account Settings first."
            activeError = accountErrors[account.email]
            return
        }
        if selectedAccount != account.email {
            selectedAccount = account.email
            selectedMailboxPath = "INBOX"
            mailboxes = []
            messages = []
            selectedMessageID = -1
            searchText = ""
            resetSearchState()
        }
        let requestedPath = selectedMailboxPath
        syncingAccount = account.email
        accountStatuses[account.email] = "Connecting to Gmail…"
        accountErrors[account.email] = nil
        activeError = nil
        defer { syncingAccount = nil }
        do {
            let client = GmailIMAPClient()
            let snapshot = try await client.fetchMailbox(email: account.email, password: password, path: requestedPath)
            let previousSelection = selectedMessageID
            mailboxes = snapshot.mailboxes
            messages = snapshot.messages
            selectedMessageID = snapshot.messages.first(where: { $0.id == previousSelection })?.id
                ?? snapshot.messages.first?.id ?? -1
            selectedAccount = account.email
            accountStatuses[account.email] = "Connected · \(selectedMailbox?.name ?? "mailbox") loaded"
            if let selected = snapshot.messages.first(where: { $0.id == selectedMessageID }) {
                await loadBody(for: selected, accountEmail: account.email)
            }
        } catch {
            accountStatuses[account.email] = "Connection failed"
            accountErrors[account.email] = error.localizedDescription
            activeError = error.localizedDescription
        }
    }

    func selectMailbox(_ mailbox: MailMailbox) {
        selectedMailboxPath = mailbox.path
        searchText = ""
        resetSearchState()
        messages = []
        selectedMessageID = -1
        guard let account = accounts.first(where: { $0.email == selectedAccount }) else { return }
        Task { await refreshMailbox(for: account) }
    }

    func selectAccount(_ account: MailAccount) {
        guard selectedAccount != account.email else { return }
        selectedAccount = account.email
        selectedMailboxPath = "INBOX"
        mailboxes = []
        messages = []
        selectedMessageID = -1
        searchText = ""
        resetSearchState()
        Task { await refreshMailbox(for: account) }
    }

    func searchCurrentFolder() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSearchAndReload()
            return
        }
        await performFolderSearch(query)
    }

    func clearSearchAndReload() {
        searchText = ""
        resetSearchState()
        guard let account = accounts.first(where: { $0.email == selectedAccount }) else { return }
        Task { await refreshMailbox(for: account) }
    }

    func loadMoreSearchResults() async {
        guard canLoadMoreSearchResults, !isLoadingMoreSearchResults,
              let account = accounts.first(where: { $0.email == selectedAccount }),
              let password = try? KeychainStore.loadPassword(for: account.email) else { return }
        let mailboxPath = selectedMailboxPath
        let query = activeSearchQuery
        let requestID = searchRequestID
        let startIndex = searchNextUIDOffset
        let endIndex = min(startIndex + 30, searchResultUIDs.count)
        let nextUIDs = Array(searchResultUIDs[startIndex..<endIndex])
        isLoadingMoreSearchResults = true
        syncingAccount = account.email
        searchError = nil
        defer {
            isLoadingMoreSearchResults = false
            if searchRequestID == requestID { syncingAccount = nil }
        }

        do {
            let nextPage = try await GmailIMAPClient().fetchMessages(
                uids: nextUIDs,
                mailboxPath: mailboxPath,
                email: account.email,
                password: password
            )
            guard searchRequestID == requestID,
                  selectedAccount == account.email,
                  selectedMailboxPath == mailboxPath,
                  activeSearchQuery == query else { return }
            searchNextUIDOffset = endIndex
            let loadedUIDs = Set(messages.map(\.id))
            messages.append(contentsOf: nextPage.filter { !loadedUIDs.contains($0.id) })
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func performFolderSearch(_ query: String) async {
        clearMultiSelection()
        guard let account = accounts.first(where: { $0.email == selectedAccount }) else {
            searchError = "Select a Gmail account before searching."
            return
        }
        guard let password = try? KeychainStore.loadPassword(for: account.email) else {
            searchError = "Add a Google app password in Account Settings before searching."
            return
        }

        let mailboxPath = selectedMailboxPath
        let requestID = UUID()
        searchRequestID = requestID
        activeSearchQuery = query
        searchResultUIDs = []
        searchNextUIDOffset = 0
        searchError = nil
        messages = []
        selectedMessageID = -1
        syncingAccount = account.email
        defer {
            if searchRequestID == requestID { syncingAccount = nil }
        }

        do {
            let snapshot = try await GmailIMAPClient().searchMailbox(
                email: account.email,
                password: password,
                path: mailboxPath,
                query: query
            )
            guard searchRequestID == requestID,
                  selectedAccount == account.email,
                  selectedMailboxPath == mailboxPath else { return }
            searchResultUIDs = snapshot.matchingUIDs
            searchNextUIDOffset = min(snapshot.matchingUIDs.count, 30)
            messages = snapshot.messages
            selectedMessageID = messages.first?.id ?? -1
            if let selected = messages.first {
                await loadBody(for: selected, accountEmail: account.email)
            }
        } catch {
            guard searchRequestID == requestID else { return }
            searchError = error.localizedDescription
        }
    }

    private func resetSearchState() {
        searchRequestID = UUID()
        activeSearchQuery = nil
        searchResultUIDs = []
        searchNextUIDOffset = 0
        searchError = nil
        isLoadingMoreSearchResults = false
        clearMultiSelection()
    }

    func loadBody(for message: MailMessage, accountEmail: String?) async {
        guard message.isRemote, let account = accounts.first(where: { $0.email == accountEmail }),
              let password = try? KeychainStore.loadPassword(for: account.email) else { return }
        guard loadingMessageID != message.id else { return }
        messageBodyLoadTask?.cancel()
        let requestID = UUID()
        messageBodyLoadID = requestID
        loadingMessageID = message.id
        messageBodyBeforeLoad = message.body
        markBodyLoading(message.id, loading: true, replaceWithPlaceholder: true)
        syncingAccount = account.email
        defer {
            if messageBodyLoadID == requestID {
                messageBodyLoadTask = nil
                loadingMessageID = nil
                messageBodyBeforeLoad = nil
                if syncingAccount == account.email { syncingAccount = nil }
            }
        }
        do {
            let loadTask = Task {
                try await GmailIMAPClient().fetchBody(
                    uid: message.id,
                    mailboxPath: message.mailboxPath,
                    email: account.email,
                    password: password
                )
            }
            messageBodyLoadTask = loadTask
            let fetchedBody = try await loadTask.value
            guard messageBodyLoadID == requestID else { return }
            guard selectedAccount == account.email, selectedMailboxPath == message.mailboxPath else { return }
            messages = messages.map { item in
                guard item.id == message.id else { return item }
                var updated = item
                updated.body = fetchedBody.content
                updated.bodyIsHTML = fetchedBody.isHTML
                updated.bodyIsPartial = fetchedBody.isPartial
                updated.bodyIsLoading = false
                updated.allowsRemoteImages = false
                return updated
            }
        } catch {
            guard messageBodyLoadID == requestID else { return }
            guard selectedAccount == account.email, selectedMailboxPath == message.mailboxPath else { return }
            accountErrors[account.email] = "Could not load message body: \(error.localizedDescription)"
            activeError = accountErrors[account.email]
            messages = messages.map { item in
                guard item.id == message.id else { return item }
                var updated = item
                updated.body = "Could not load this message. Check the account connection and try refreshing the Inbox."
                updated.bodyIsLoading = false
                return updated
            }
        }
    }

    func cancelCurrentMessageLoad() {
        guard let messageID = loadingMessageID else { return }
        let accountEmail = selectedAccount
        let previousBody = messageBodyBeforeLoad ?? ""
        messageBodyLoadID = UUID()
        messageBodyLoadTask?.cancel()
        messageBodyLoadTask = nil
        loadingMessageID = nil
        messageBodyBeforeLoad = nil
        if syncingAccount == accountEmail { syncingAccount = nil }
        messages = messages.map { item in
            guard item.id == messageID else { return item }
            var updated = item
            updated.body = previousBody
            updated.bodyIsLoading = false
            return updated
        }
    }

    func loadFullMessage(_ message: MailMessage, accountEmail: String?) async {
        guard message.isRemote, let account = accounts.first(where: { $0.email == accountEmail }),
              let password = try? KeychainStore.loadPassword(for: account.email) else { return }
        if !message.bodyIsPartial {
            guard selectedAccount == account.email, selectedMailboxPath == message.mailboxPath else { return }
            if message.bodyIsHTML { setRemoteImagesAllowed(true, for: message.id) }
            return
        }
        messageBodyLoadTask?.cancel()
        let requestID = UUID()
        messageBodyLoadID = requestID
        loadingMessageID = message.id
        messageBodyBeforeLoad = message.body
        markBodyLoading(message.id, loading: true, replaceWithPlaceholder: false)
        syncingAccount = account.email
        defer {
            if messageBodyLoadID == requestID {
                messageBodyLoadTask = nil
                loadingMessageID = nil
                messageBodyBeforeLoad = nil
                if syncingAccount == account.email { syncingAccount = nil }
            }
        }
        do {
            let loadTask = Task {
                try await GmailIMAPClient().fetchBody(
                    uid: message.id,
                    mailboxPath: message.mailboxPath,
                    email: account.email,
                    password: password,
                    full: true
                )
            }
            messageBodyLoadTask = loadTask
            let fetchedBody = try await loadTask.value
            guard messageBodyLoadID == requestID else { return }
            guard selectedAccount == account.email, selectedMailboxPath == message.mailboxPath else { return }
            messages = messages.map { item in
                guard item.id == message.id else { return item }
                var updated = item
                updated.body = fetchedBody.content
                updated.bodyIsHTML = fetchedBody.isHTML
                updated.bodyIsPartial = false
                updated.bodyIsLoading = false
                updated.allowsRemoteImages = fetchedBody.isHTML
                return updated
            }
        } catch {
            guard messageBodyLoadID == requestID else { return }
            guard selectedAccount == account.email, selectedMailboxPath == message.mailboxPath else { return }
            accountErrors[account.email] = "Could not load the full message: \(error.localizedDescription)"
            activeError = accountErrors[account.email]
            markBodyLoading(message.id, loading: false, replaceWithPlaceholder: false)
        }
    }

    private func markBodyLoading(_ messageID: Int, loading: Bool, replaceWithPlaceholder: Bool) {
        messages = messages.map { item in
            guard item.id == messageID else { return item }
            var updated = item
            updated.bodyIsLoading = loading
            if replaceWithPlaceholder && loading { updated.body = "Loading message from Gmail…" }
            return updated
        }
    }

    private func setRemoteImagesAllowed(_ allowed: Bool, for messageID: Int) {
        messages = messages.map { item in
            guard item.id == messageID else { return item }
            var updated = item
            updated.allowsRemoteImages = allowed
            return updated
        }
    }

    func blockRemoteImages(for message: MailMessage) {
        setRemoteImagesAllowed(false, for: message.id)
    }

    func select(_ message: MailMessage) {
        clearMultiSelection()
        selectionAnchorID = message.id
        focusMessage(message)
    }

    func select(
        _ message: MailMessage,
        command: Bool,
        shift: Bool,
        visibleMessages: [MailMessage]
    ) {
        if shift {
            isMultiSelectionActive = true
            let anchorID = selectionAnchorID ?? selectedMessageID
            if let anchorIndex = visibleMessages.firstIndex(where: { $0.id == anchorID }),
               let clickedIndex = visibleMessages.firstIndex(where: { $0.id == message.id }) {
                let lower = min(anchorIndex, clickedIndex)
                let upper = max(anchorIndex, clickedIndex)
                multiSelectedMessageIDs = Set(visibleMessages[lower...upper].map(\.id))
            } else {
                multiSelectedMessageIDs = [message.id]
                selectionAnchorID = message.id
            }
        } else if command {
            if !isMultiSelectionActive {
                isMultiSelectionActive = true
                multiSelectedMessageIDs = selectedMessageID >= 0 ? [selectedMessageID] : []
            }
            if multiSelectedMessageIDs.contains(message.id) {
                multiSelectedMessageIDs.remove(message.id)
            } else {
                multiSelectedMessageIDs.insert(message.id)
            }
            if selectionAnchorID == nil { selectionAnchorID = selectedMessageID >= 0 ? selectedMessageID : message.id }
        } else {
            multiSelectedMessageIDs = []
            isMultiSelectionActive = false
            selectionAnchorID = message.id
        }
        focusMessage(message)
    }

    private func focusMessage(_ message: MailMessage) {
        selectedMessageID = message.id
        if !message.isRemote {
            messages = messages.map { item in
                guard item.id == message.id else { return item }
                var updated = item
                updated.unread = false
                return updated
            }
        }
        if message.isRemote && message.body.isEmpty {
            let accountEmail = selectedAccount
            Task { await loadBody(for: message, accountEmail: accountEmail) }
        }
    }

    func moveSelection(by offset: Int) {
        guard syncingAccount == nil else { return }
        let visibleMessages = filteredMessages
        guard !visibleMessages.isEmpty, offset != 0 else { return }
        let currentIndex = visibleMessages.firstIndex(where: { $0.id == selectedMessageID })
        let origin = currentIndex ?? (offset > 0 ? -1 : visibleMessages.count)
        let nextIndex = min(max(origin + offset, 0), visibleMessages.count - 1)
        select(visibleMessages[nextIndex])
    }

    func toggleFlag(_ message: MailMessage) {
        if message.isRemote {
            let accountEmail = selectedAccount
            Task { await performRemoteAction(.star(!message.flagged), message: message, accountEmail: accountEmail) }
            return
        }
        messages = messages.map { item in
            guard item.id == message.id else { return item }
            var updated = item
            updated.flagged.toggle()
            return updated
        }
    }

    func archiveSelected() {
        guard let message = selectedMessage, message.isRemote else { return }
        let accountEmail = selectedAccount
        Task { await performRemoteAction(.archive, message: message, accountEmail: accountEmail) }
    }

    func moveSelected(to mailbox: MailMailbox) {
        guard let message = selectedMessage, message.isRemote else { return }
        let accountEmail = selectedAccount
        Task { await performRemoteAction(.move(mailbox.path), message: message, accountEmail: accountEmail) }
    }

    func deleteSelected() {
        guard let message = selectedMessage, message.isRemote else { return }
        let currentMailboxIsTrash = selectedMailbox?.isTrash ?? false
        if currentMailboxIsTrash {
            pendingPermanentDelete = message
            return
        }
        let trashPath = mailboxes.first(where: { $0.isTrash })?.path
        let accountEmail = selectedAccount
        Task { await performRemoteAction(.delete(isTrash: false, trashPath: trashPath), message: message, accountEmail: accountEmail) }
    }

    func archiveSelectedMessages() {
        guard isMultiSelectionActive else { return }
        Task { await performBulkRemoteAction(.archive, messages: selectedMessages) }
    }

    func toggleFlagSelectedMessages() {
        guard isMultiSelectionActive else { return }
        let messagesToUpdate = selectedMessages
        guard !messagesToUpdate.isEmpty, messagesToUpdate.allSatisfy(\.isRemote) else { return }
        Task {
            await performBulkRemoteAction(.star(!messagesToUpdate.allSatisfy(\.flagged)), messages: messagesToUpdate)
        }
    }

    func moveSelectedMessages(to mailbox: MailMailbox) {
        guard isMultiSelectionActive else { return }
        Task { await performBulkRemoteAction(.move(mailbox.path), messages: selectedMessages) }
    }

    func deleteSelectedMessages() {
        guard isMultiSelectionActive else { return }
        let messagesToDelete = selectedMessages
        guard !messagesToDelete.isEmpty else { return }
        if selectedMailbox?.isTrash == true {
            pendingMultiPermanentDelete = messagesToDelete
            return
        }
        let trashPath = mailboxes.first(where: { $0.isTrash })?.path
        Task { await performBulkRemoteAction(.delete(isTrash: false, trashPath: trashPath), messages: messagesToDelete) }
    }

    func confirmPermanentDelete() {
        guard let message = pendingPermanentDelete else { return }
        let accountEmail = selectedAccount
        pendingPermanentDelete = nil
        Task { await performRemoteAction(.delete(isTrash: true, trashPath: nil), message: message, accountEmail: accountEmail) }
    }

    func confirmMultiPermanentDelete() {
        guard let messagesToDelete = pendingMultiPermanentDelete, !messagesToDelete.isEmpty else { return }
        pendingMultiPermanentDelete = nil
        Task { await performBulkRemoteAction(.delete(isTrash: true, trashPath: nil), messages: messagesToDelete) }
    }

    func cancelPermanentDelete() {
        pendingPermanentDelete = nil
        pendingMultiPermanentDelete = nil
    }

    private enum RemoteAction {
        case archive
        case star(Bool)
        case move(String)
        case delete(isTrash: Bool, trashPath: String?)
    }

    private enum BulkRemoteAction {
        case archive
        case star(Bool)
        case move(String)
        case delete(isTrash: Bool, trashPath: String?)
    }

    private func performBulkRemoteAction(_ action: BulkRemoteAction, messages messagesToActOn: [MailMessage]) async {
        guard !messagesToActOn.isEmpty,
              messagesToActOn.allSatisfy({ $0.isRemote && $0.mailboxPath == selectedMailboxPath }),
              let account = accounts.first(where: { $0.email == selectedAccount }),
              let password = try? KeychainStore.loadPassword(for: account.email) else { return }

        let sourceMailbox = selectedMailboxPath
        let messageIDs = Set(messagesToActOn.map(\.id))
        let uids = Array(messageIDs)
        syncingAccount = account.email
        accountErrors[account.email] = nil
        activeError = nil
        defer { syncingAccount = nil }

        do {
            let client = GmailIMAPClient()
            switch action {
            case .archive:
                try await client.archive(uids: uids, mailboxPath: sourceMailbox, email: account.email, password: password)
            case .star(let shouldStar):
                try await client.setStarred(uids: uids, mailboxPath: sourceMailbox, starred: shouldStar, email: account.email, password: password)
            case .move(let destination):
                try await client.move(uids: uids, from: sourceMailbox, to: destination, email: account.email, password: password)
            case .delete(let isTrash, let trashPath):
                try await client.delete(uids: uids, mailboxPath: sourceMailbox, isTrash: isTrash, trashPath: trashPath, email: account.email, password: password)
            }

            guard selectedAccount == account.email, selectedMailboxPath == sourceMailbox else { return }
            let shouldRemoveFromCurrentMailbox: Bool
            let status: String
            switch action {
            case .archive:
                shouldRemoveFromCurrentMailbox = selectedMailbox?.isInbox == true
                status = "Connected · \(messagesToActOn.count) messages archived"
            case .star(let shouldStar):
                shouldRemoveFromCurrentMailbox = selectedMailbox?.attributes.contains(where: {
                    $0.caseInsensitiveCompare("\\Flagged") == .orderedSame
                }) == true && !shouldStar
                status = shouldStar
                    ? "Connected · \(messagesToActOn.count) messages flagged"
                    : "Connected · \(messagesToActOn.count) messages unflagged"
            case .move:
                shouldRemoveFromCurrentMailbox = true
                status = "Connected · \(messagesToActOn.count) messages moved"
            case .delete(let isTrash, _):
                shouldRemoveFromCurrentMailbox = true
                status = isTrash
                    ? "Connected · \(messagesToActOn.count) messages permanently deleted"
                    : "Connected · \(messagesToActOn.count) messages moved to Trash"
            }
            if shouldRemoveFromCurrentMailbox {
                removeFromCurrentMailbox(messageIDs, account: account)
            } else if case .star(let shouldStar) = action {
                messages = messages.map { item in
                    guard messageIDs.contains(item.id) else { return item }
                    var updated = item
                    updated.flagged = shouldStar
                    return updated
                }
            }
            clearMultiSelection()
            accountStatuses[account.email] = status
        } catch {
            accountErrors[account.email] = error.localizedDescription
            activeError = error.localizedDescription
        }
    }

    private func performRemoteAction(_ action: RemoteAction, message: MailMessage, accountEmail: String?) async {
        guard let account = accounts.first(where: { $0.email == accountEmail }),
              let password = try? KeychainStore.loadPassword(for: account.email) else { return }
        syncingAccount = account.email
        accountErrors[account.email] = nil
        activeError = nil
        defer { syncingAccount = nil }
        let client = GmailIMAPClient()
        do {
            switch action {
            case .archive:
                try await client.archive(uid: message.id, mailboxPath: message.mailboxPath, email: account.email, password: password)
                if selectedMailbox?.isInbox == true {
                    removeFromCurrentMailbox(message.id, account: account)
                }
                accountStatuses[account.email] = "Connected · Message archived"
            case .star(let shouldStar):
                try await client.setStarred(uid: message.id, mailboxPath: message.mailboxPath, starred: shouldStar, email: account.email, password: password)
                messages = messages.map { item in
                    guard item.id == message.id else { return item }
                    var updated = item
                    updated.flagged = shouldStar
                    return updated
                }
                let isStarredMailbox = selectedMailbox?.attributes.contains(where: {
                    $0.caseInsensitiveCompare("\\Flagged") == .orderedSame
                }) == true
                if isStarredMailbox && !shouldStar {
                    removeFromCurrentMailbox(message.id, account: account)
                }
                accountStatuses[account.email] = "Connected · Star updated"
            case .move(let destination):
                try await client.move(uid: message.id, from: message.mailboxPath, to: destination, email: account.email, password: password)
                removeFromCurrentMailbox(message.id, account: account)
                accountStatuses[account.email] = "Connected · Message moved"
            case .delete(let isTrash, let trashPath):
                try await client.delete(uid: message.id, mailboxPath: message.mailboxPath, isTrash: isTrash, trashPath: trashPath, email: account.email, password: password)
                removeFromCurrentMailbox(message.id, account: account)
                accountStatuses[account.email] = isTrash ? "Connected · Message permanently deleted" : "Connected · Message moved to Trash"
            }
        } catch {
            accountErrors[account.email] = error.localizedDescription
            activeError = error.localizedDescription
        }
    }

    private func removeFromCurrentMailbox(_ messageID: Int, account: MailAccount) {
        removeFromCurrentMailbox([messageID], account: account)
    }

    private func removeFromCurrentMailbox(_ messageIDs: Set<Int>, account: MailAccount) {
        let selectedMessageWasRemoved = messageIDs.contains(selectedMessageID)
        messages.removeAll { messageIDs.contains($0.id) }
        if activeSearchQuery != nil {
            let loadedRemovedCount = searchResultUIDs.prefix(searchNextUIDOffset).filter { messageIDs.contains($0) }.count
            searchResultUIDs.removeAll { messageIDs.contains($0) }
            searchNextUIDOffset = max(0, searchNextUIDOffset - loadedRemovedCount)
        }
        multiSelectedMessageIDs.subtract(messageIDs)
        if multiSelectedMessageIDs.isEmpty { isMultiSelectionActive = false }
        guard selectedMessageWasRemoved else { return }
        selectedMessageID = filteredMessages.first?.id ?? -1
        if let nextMessage = selectedMessage, nextMessage.body.isEmpty {
            Task { await loadBody(for: nextMessage, accountEmail: account.email) }
        }
    }

    private func persistAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: accountsKey)
    }
}

private enum MailComposerError: LocalizedError {
    case noAccount
    case missingPassword
    case invalidRecipients
    case invalidSubject

    var errorDescription: String? {
        switch self {
        case .noAccount: "Select a Gmail account before sending."
        case .missingPassword: "Add this account's Google app password in Settings before sending."
        case .invalidRecipients: "Enter one or more valid email addresses, separated by commas."
        case .invalidSubject: "The subject cannot contain line breaks."
        }
    }
}

private enum MailAccountSaveError: LocalizedError {
    case invalidName

    var errorDescription: String? {
        "The full name cannot contain line breaks or control characters."
    }
}
