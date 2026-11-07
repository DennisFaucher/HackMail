import XCTest
@testable import HackMail

final class AccountAndMailTests: XCTestCase {
    func testLegacyAccountSettingsDoNotSuggestPersonalNames() throws {
        let legacyJSON = #"[{"email":"owner@example.com"},{"email":"person@gmail.com"}]"#
        let accounts = try JSONDecoder().decode([MailAccount].self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(accounts.map(\.fullName), ["", ""])
    }

    func testFullNameRoundTripsWithAccountSettings() throws {
        let account = MailAccount(email: "sender@example.com", fullName: "Example Sender")
        let decoded = try JSONDecoder().decode(MailAccount.self, from: JSONEncoder().encode(account))

        XCTAssertEqual(decoded, account)
    }

    func testRecipientParserAcceptsCommaAndSemicolonSeparators() {
        XCTAssertEqual(
            GmailSMTPClient.parseRecipients("one@example.com; two@example.com, three@example.org"),
            ["one@example.com", "two@example.com", "three@example.org"]
        )
    }

    func testRecipientParserRejectsInvalidAddressAndHeaderInjection() {
        XCTAssertNil(GmailSMTPClient.parseRecipients("valid@example.com; invalid@"))
        XCTAssertNil(GmailSMTPClient.parseRecipients("valid@example.com\r\nBcc: victim@example.com"))
    }

    func testRecipientAutocompleteUsesOnlyTheActiveAddressToken() {
        XCTAssertEqual(RecipientAddressCompletion.activeToken(in: "first@example.com, alex"), "alex")
        XCTAssertEqual(RecipientAddressCompletion.activeToken(in: "first@example.com;  DEN"), "DEN")
        XCTAssertEqual(
            RecipientAddressCompletion.replacingActiveToken(in: "first@example.com, alex", with: "alex@example.com"),
            "first@example.com, alex@example.com, "
        )
    }

    func testContactAutocompleteMatchesNameAndEmailAndPrioritizesPrefixes() {
        let contacts = [
            ContactSuggestion(name: "Sam Example", email: "sam@example.com"),
            ContactSuggestion(name: "Alex Example", email: "alex@example.com"),
            ContactSuggestion(name: "Alexandra Example", email: "alexandra@example.com")
        ]

        let nameMatches = ContactAutocompleteModel.matching("alex", in: contacts)
        let emailMatches = ContactAutocompleteModel.matching("example.com", in: contacts)

        XCTAssertEqual(nameMatches.first?.name, "Alex Example")
        XCTAssertEqual(emailMatches.count, 3)
    }

    func testSMTPMessageUsesConfiguredDisplayNameAndBase64Body() {
        let message = SMTPMessageBuilder.build(
            from: "sender@example.com",
            fromName: "Example Sender",
            recipients: ["friend@example.com"],
            subject: "Hello",
            body: OutgoingEmailBody(plainText: "A private note", html: "<html><body><b>A private note</b></body></html>")
        )

        XCTAssertTrue(message.contains("From: \"Example Sender\" <sender@example.com>"))
        XCTAssertTrue(message.contains("To: <friend@example.com>"))
        XCTAssertTrue(message.contains("multipart/alternative"))
        XCTAssertTrue(message.contains("Content-Type: text/html; charset=UTF-8"))
        XCTAssertTrue(message.contains("Content-Transfer-Encoding: base64"))
        XCTAssertTrue(message.contains(Data("A private note".utf8).base64EncodedString()))
        XCTAssertTrue(message.contains(Data("<html><body><b>A private note</b></body></html>".utf8).base64EncodedString()))
        XCTAssertFalse(message.contains("\r\nA private note\r\n"))
    }

    func testSMTPBuilderWrapsAttachmentsInMultipartMixedAndEncodesFilename() {
        let attachment = MailAttachment(id: UUID(), fileName: "Résumé.pdf", mimeType: "application/pdf", data: Data([0, 1, 2]))
        let secondAttachment = MailAttachment(id: UUID(), fileName: "notes.txt", mimeType: "text/plain", data: Data("notes".utf8))
        let message = SMTPMessageBuilder.build(
            from: "sender@example.com",
            fromName: "Example Sender",
            recipients: ["friend@example.com"],
            subject: "Document",
            body: OutgoingEmailBody(plainText: "See attached", html: "<p>See attached</p>"),
            attachments: [attachment, secondAttachment]
        )

        XCTAssertTrue(message.contains("multipart/mixed"))
        XCTAssertTrue(message.contains("multipart/alternative"))
        XCTAssertTrue(message.contains("Content-Disposition: attachment; filename*=UTF-8''R%C3%A9sum%C3%A9.pdf"))
        XCTAssertTrue(message.contains(Data([0, 1, 2]).base64EncodedString()))
        XCTAssertTrue(message.contains("filename*=UTF-8''notes.txt"))
        XCTAssertTrue(message.contains(Data("notes".utf8).base64EncodedString()))
    }

    func testSMTPBuilderPreservesInlineImagesAsRelatedParts() {
        let image = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let html = #"<html><body><p>Forwarded</p><img src="data:image/jpeg;base64,/9j/2Q=="></body></html>"#

        let message = SMTPMessageBuilder.build(
            from: "sender@example.com",
            fromName: "Example Sender",
            recipients: ["friend@example.com"],
            subject: "Fwd: Photos",
            body: OutgoingEmailBody(plainText: "Forwarded", html: html)
        )

        XCTAssertTrue(message.contains("multipart/related"))
        XCTAssertTrue(message.contains("Content-Disposition: inline;"))
        XCTAssertTrue(message.contains("Content-ID: <hackmail-inline-"))
        XCTAssertTrue(message.contains(image.base64EncodedString()))
        XCTAssertFalse(message.contains("data:image/jpeg;base64"))
        let contentID = try! XCTUnwrap(
            message.components(separatedBy: "Content-ID: <").dropFirst().first?.components(separatedBy: ">").first
        )
        let rewrittenHTML = html.replacingOccurrences(
            of: "data:image/jpeg;base64,/9j/2Q==",
            with: "cid:\(contentID)"
        )
        let encodedHTML = Data(rewrittenHTML.utf8).base64EncodedString()
        XCTAssertTrue(message.replacingOccurrences(of: "\r\n", with: "").contains(encodedHTML))
    }

    func testAttachmentLoaderReadsSelectedFileIntoMemory() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("hackmail-attachment-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let bytes = Data("temporary test attachment".utf8)
        try bytes.write(to: fileURL)

        let attachments = try AttachmentLoader.load(urls: [fileURL], existingBytes: 0, maxBytes: 1024)

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].data, bytes)
        XCTAssertEqual(attachments[0].fileName, fileURL.lastPathComponent)
    }

    func testAttachmentLoaderEnforcesTotalSizeLimit() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("hackmail-large-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data([0, 1, 2]).write(to: fileURL)

        XCTAssertThrowsError(try AttachmentLoader.load(urls: [fileURL], existingBytes: 0, maxBytes: 2))
    }

    func testHTMLTextExtractorSkipsActiveContentAndKeepsVisibleText() {
        let html = "<html><head><style>body { display:none }</style></head><body><p>Watch <a href=\"https://example.com\">the trailer</a></p><script>ignore this</script></body></html>"

        let extracted = HTMLTextExtractor.extract(html)

        XCTAssertEqual(extracted.text, "Watch the trailer")
        XCTAssertFalse(extracted.wasTruncated)
    }

    func testHTMLTextExtractorSkipsLongInlineImageAttributes() {
        let html = "<p>Intro</p><img src=\"data:image/jpeg;base64,\(String(repeating: "A", count: 5_000))\"><p>Outro</p>"

        let extracted = HTMLTextExtractor.extract(html)

        XCTAssertTrue(extracted.text.contains("Intro"))
        XCTAssertTrue(extracted.text.contains("Outro"))
        XCTAssertFalse(extracted.text.contains("base64"))
    }

    func testHTMLTextExtractorBoundsForwardedText() {
        let extracted = HTMLTextExtractor.extract(String(repeating: "x", count: HTMLTextExtractor.maximumCharacters + 100))

        XCTAssertTrue(extracted.wasTruncated)
        XCTAssertTrue(extracted.text.hasSuffix("[Original message text shortened for responsiveness.]"))
    }

    func testPlainTextForwardQuoteAlsoBoundsParagraphCount() {
        let source = (1...500).map { "Line \($0)" }.joined(separator: "\n")
        let extracted = HTMLTextExtractor.limitPlainText(source)

        XCTAssertTrue(extracted.wasTruncated)
        XCTAssertLessThanOrEqual(extracted.text.components(separatedBy: .newlines).count, 302)
        XCTAssertTrue(extracted.text.contains("Line 300"))
        XCTAssertFalse(extracted.text.contains("Line 301"))
    }

    func testPlainTextTrackingURLsAreHiddenBehindNearbyLabels() {
        let source = "Town Meeting Information (https://tracking.example/meeting)\nRegister Here\n(https://tracking.example/register)\nLearn more at Harbortown Cultural District (https://tracking.example/event)\nunnamed (2) (https://tracking.example/unnamed)"
        let formatted = PlainTextLinkFormatter.format(source)
        let visible = String(formatted.characters)
        let linkedLabels = formatted.runs.compactMap { run -> String? in
            guard run.link != nil else { return nil }
            return String(formatted[run.range].characters)
        }

        XCTAssertEqual(visible, "Town Meeting Information\nRegister Here\nLearn more at Harbortown Cultural District\nunnamed (2)")
        XCTAssertEqual(linkedLabels, ["Town Meeting Information", "Register Here", "Harbortown Cultural District", "unnamed (2)"])
        XCTAssertFalse(visible.contains("tracking.example"))
    }

    func testModifiedUTF7MailboxNamesDecodeSpecialCharacters() {
        XCTAssertEqual(IMAPMailboxNameCodec.decode("&JgU-"), "★")
        XCTAssertEqual(IMAPMailboxNameCodec.decode("News &- Updates"), "News & Updates")
        XCTAssertEqual(IMAPMailboxNameCodec.decode("Folder/&JgU-"), "Folder/★")
    }

    func testListResponsePreservesEncodedMailboxPathAndDecodesDisplayName() {
        let mailbox = IMAPServerResponseParser.parseMailbox("* LIST (\\HasNoChildren) \"/\" \"&JgU-\"")

        XCTAssertEqual(mailbox?.path, "&JgU-")
        XCTAssertEqual(mailbox?.name, "★")
    }

    func testListResponseUsesSpecialUseName() {
        let mailbox = IMAPServerResponseParser.parseMailbox("* LIST (\\HasNoChildren \\Inbox) \"/\" \"INBOX\"")

        XCTAssertEqual(mailbox?.path, "INBOX")
        XCTAssertEqual(mailbox?.name, "Inbox")
        XCTAssertTrue(mailbox?.isInbox == true)
    }

    func testIMAPFetchEnvelopeParsesSenderSubjectFlagsAndUID() {
        let response = #"* 7 FETCH (UID 456 FLAGS (\Seen \Flagged) INTERNALDATE "06-Nov-2026 15:30:00 +0000" ENVELOPE ("Fri, 6 Nov 2026 15:30:00 +0000" "=?UTF-8?B?SGVsbG8=?=" (("Alice Example" NIL "alice" "example.com")) NIL NIL NIL NIL NIL NIL "<msg@example.com>"))"#

        let message = IMAPServerResponseParser.parseMessage(response, mailboxPath: "INBOX")

        XCTAssertEqual(message?.id, 456)
        XCTAssertEqual(message?.sender, "Alice Example")
        XCTAssertEqual(message?.senderEmail, "alice@example.com")
        XCTAssertEqual(message?.subject, "Hello")
        XCTAssertEqual(message?.unread, false)
        XCTAssertEqual(message?.flagged, true)
        XCTAssertEqual(message?.mailboxPath, "INBOX")
    }

    func testIMAPSearchResponseParsesAndDeduplicatesMatchingUIDs() {
        let uids = IMAPServerResponseParser.parseSearchUIDs([
            "* SEARCH 12 25 40",
            "* SEARCH 40 51",
            "A003 OK SEARCH completed"
        ])

        XCTAssertEqual(uids, [12, 25, 40, 51])
    }

    func testIMAPExistsResponseParsesMailboxMessageCount() {
        XCTAssertEqual(IMAPServerResponseParser.parseExistsCount(["* 24 EXISTS", "* 3 RECENT"]), 24)
        XCTAssertEqual(IMAPServerResponseParser.parseExistsCount(["* 0 EXISTS"]), 0)
        XCTAssertNil(IMAPServerResponseParser.parseExistsCount(["A001 OK SELECT completed"]))
    }

    func testLanguageToolResponseDecodesCorrectionRangesAndReplacements() throws {
        let json = #"{"matches":[{"message":"Possible spelling mistake","offset":0,"length":3,"replacements":[{"value":"the"}],"context":{"text":"teh cat","offset":0,"length":3},"rule":{"id":"MORFOLOGIK_RULE_EN_US"}}]}"#

        let response = try JSONDecoder().decode(LanguageToolResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.matches.count, 1)
        XCTAssertEqual(response.matches[0].offset, 0)
        XCTAssertEqual(response.matches[0].length, 3)
        XCTAssertEqual(response.matches[0].replacements.first?.value, "the")
        XCTAssertEqual(response.matches[0].context?.text, "teh cat")
    }

    func testLanguageToolEndpointAppendsCheckAndRequiresHTTPS() {
        XCTAssertEqual(
            LanguageToolClient.checkEndpoint(from: "https://languagetool.example/v2/")?.absoluteString,
            "https://languagetool.example/v2/check"
        )
        XCTAssertNil(LanguageToolClient.checkEndpoint(from: "http://languagetool.example/v2/"))
        XCTAssertNil(LanguageToolClient.checkEndpoint(from: "https://user:secret@languagetool.example/v2/"))
    }

    @MainActor
    func testLanguageToolCheckerDoesNotSubmitOversizedDrafts() {
        let checker = LanguageToolChecker()
        let draft = String(repeating: "a", count: LanguageToolChecker.maximumTextLength + 1)

        checker.scheduleCheck(
            text: draft,
            enabled: true,
            baseURL: "https://languagetool.example/v2/",
            language: "en-US"
        )

        XCTAssertTrue(checker.errorMessage?.contains("20,000") == true)
        XCTAssertFalse(checker.isChecking)
    }

    func testHTMLAlternativeIsPreferredOverPlainText() {
        let plain = IMAPTextPart(section: "1", isHTML: false, transferEncoding: "quoted-printable", charset: "UTF-8", inlineImages: [])
        let inlineImage = IMAPInlineImage(section: "1.2", contentID: "poster-123", mimeType: "image/jpeg", transferEncoding: "base64", size: 128)
        let html = IMAPTextPart(section: "2", isHTML: true, transferEncoding: "base64", charset: "UTF-8", inlineImages: [inlineImage])

        XCTAssertEqual(IMAPMIMEPartSelector.preferredTextPart(in: [plain, html]), html)
        XCTAssertEqual(IMAPMIMEPartSelector.preferredTextPart(in: [plain, html], preferHTML: false), plain)
        XCTAssertEqual(IMAPMIMEPartSelector.preferredTextPart(in: [plain]), plain)
        XCTAssertEqual(IMAPMIMEPartSelector.preferredTextPart(in: [plain, html])?.inlineImages, [inlineImage])
    }

    func testCIDInlineImagesAreInlinedAsDataURLsInMemory() {
        let html = #"<img src="cid:<poster-123>"><img src="cid:other">"#
        let resolved = IMAPInlineImageResolver.replacingCIDReferences(
            in: html,
            with: ["poster-123": "data:image/jpeg;base64,AAEC"]
        )

        XCTAssertEqual(resolved, #"<img src="data:image/jpeg;base64,AAEC"><img src="cid:other">"#)
    }
}

final class MailStoreNavigationTests: XCTestCase {
    @MainActor
    func testMailStoreStartsWithAnEmptyLiveMessageList() throws {
        let suiteName = "HackMailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MailStore(defaults: defaults)

        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNil(store.selectedMessage)
    }

    @MainActor
    func testSelectedContactsListIdentifierPersists() throws {
        let suiteName = "HackMailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MailStore(defaults: defaults)

        store.selectContactsContainer("google-contacts-list")
        let restoredStore = MailStore(defaults: defaults)

        XCTAssertEqual(restoredStore.selectedContactsContainerIdentifier, "google-contacts-list")
    }

    @MainActor
    func testLanguageToolDefaultsOffAndPersistsExplicitPreference() throws {
        let suiteName = "HackMailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MailStore(defaults: defaults)

        XCTAssertFalse(store.languageToolEnabled)
        store.languageToolEnabled = true
        store.persistLanguageToolSettings()

        XCTAssertTrue(MailStore(defaults: defaults).languageToolEnabled)
    }

    @MainActor
    func testArrowSelectionMovesThroughVisibleMessagesAndClampsAtEdges() throws {
        let suiteName = "HackMailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MailStore(defaults: defaults)
        store.messages = [
            MailMessage(id: 1, sender: "One", senderEmail: "one@example.com", time: "1 PM", subject: "First", preview: "", body: ""),
            MailMessage(id: 2, sender: "Two", senderEmail: "two@example.com", time: "2 PM", subject: "Second", preview: "", body: ""),
            MailMessage(id: 3, sender: "Three", senderEmail: "three@example.com", time: "3 PM", subject: "Third", preview: "", body: "")
        ]
        store.selectedMessageID = 1

        store.moveSelection(by: 1)
        XCTAssertEqual(store.selectedMessageID, 2)
        store.moveSelection(by: -1)
        XCTAssertEqual(store.selectedMessageID, 1)
        store.moveSelection(by: -1)
        XCTAssertEqual(store.selectedMessageID, 1)

        store.moveSelection(by: 2)
        XCTAssertEqual(store.selectedMessageID, 3)
        store.moveSelection(by: 1)
        XCTAssertEqual(store.selectedMessageID, 3)
    }

    @MainActor
    func testCommandAndShiftClickSelectMessageGroupsAndTrackFlagState() throws {
        let suiteName = "HackMailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MailStore(defaults: defaults)
        store.messages = (1...4).map { id in
            MailMessage(
                id: id,
                sender: "Sender \(id)",
                senderEmail: "sender\(id)@example.com",
                time: "",
                subject: "Message \(id)",
                preview: "",
                body: "",
                flagged: id == 1
            )
        }
        let visibleMessages = store.filteredMessages
        store.selectedMessageID = 1

        store.select(visibleMessages[2], command: true, shift: false, visibleMessages: visibleMessages)
        XCTAssertEqual(store.multiSelectedMessageIDs, [1, 3])
        XCTAssertFalse(store.selectedMessagesAreAllFlagged)

        store.select(visibleMessages[1])
        store.select(visibleMessages[3], command: false, shift: true, visibleMessages: visibleMessages)
        XCTAssertEqual(store.multiSelectedMessageIDs, [2, 3, 4])
        XCTAssertEqual(store.selectedMessages.map(\.id), [2, 3, 4])

        store.messages = store.messages.map { message in
            var updated = message
            updated.flagged = true
            return updated
        }
        XCTAssertTrue(store.selectedMessagesAreAllFlagged)
    }

    @MainActor
    func testMessageListCanSortAndResortAppendedSearchResults() throws {
        let suiteName = "HackMailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MailStore(defaults: defaults)
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        store.messages = [
            MailMessage(id: 1, sender: "Zoe", senderEmail: "zoe@example.com", time: "", sortDate: epoch, subject: "zebra", preview: "", body: ""),
            MailMessage(id: 2, sender: "Alice", senderEmail: "alice@example.com", time: "", sortDate: epoch.addingTimeInterval(300), subject: "Apple", preview: "", body: "", flagged: true),
            MailMessage(id: 3, sender: "Bob", senderEmail: "bob@example.com", time: "", sortDate: epoch.addingTimeInterval(200), subject: "Hello", preview: "", body: "")
        ]

        XCTAssertEqual(store.filteredMessages.map(\.id), [2, 3, 1])
        store.sortMessages(by: .subject)
        XCTAssertEqual(store.filteredMessages.map(\.id), [2, 3, 1])
        store.sortMessages(by: .subject)
        XCTAssertEqual(store.filteredMessages.map(\.id), [1, 3, 2])
        store.sortMessages(by: .flagged)
        XCTAssertEqual(store.filteredMessages.map(\.id), [2, 1, 3])

        store.messages.append(
            MailMessage(id: 4, sender: "Cara", senderEmail: "cara@example.com", time: "", sortDate: epoch.addingTimeInterval(100), subject: "Beta", preview: "", body: "")
        )
        store.sortMessages(by: .date)
        XCTAssertEqual(store.filteredMessages.map(\.id), [2, 3, 4, 1])
    }

    @MainActor
    func testSelectingLocalMessageClearsUnreadButRemoteStateRemainsServerOwned() throws {
        let suiteName = "HackMailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MailStore(defaults: defaults)
        let local = MailMessage(id: 1, sender: "Local", senderEmail: "local@example.test", time: "Now", subject: "Local", preview: "", body: "Body", unread: true)
        let remote = MailMessage(id: 2, sender: "Remote", senderEmail: "remote@example.test", time: "Now", subject: "Remote", preview: "", body: "Body", unread: true, isRemote: true)
        store.accounts = [MailAccount(email: "test@example.invalid")]
        store.selectedAccount = "test@example.invalid"
        store.messages = [local, remote]

        store.select(local)
        XCTAssertFalse(store.messages[0].unread)
        store.select(remote)
        XCTAssertTrue(store.messages[1].unread)
    }
}
