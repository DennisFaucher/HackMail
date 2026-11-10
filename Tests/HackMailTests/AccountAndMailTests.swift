import XCTest
import AppKit
@testable import HackMail

final class AccountAndMailTests: XCTestCase {
    func testLegacyAccountSettingsGetSuggestedNameOnlyWhenConfigured() throws {
        let addresses = PersonalDefaults.suggestedAddresses + ["owner@example.com"]
        let legacyJSON = "[" + addresses.map { #"{"email":"\#($0)"}"# }.joined(separator: ",") + "]"
        let accounts = try JSONDecoder().decode([MailAccount].self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(accounts.map(\.fullName), addresses.map(PersonalDefaults.suggestedFullName(for:)))
        XCTAssertEqual(accounts.last?.fullName, "")
        XCTAssertEqual(accounts.map(\.signature), addresses.map { _ in "" })
    }

    func testFullNameRoundTripsWithAccountSettings() throws {
        let account = MailAccount(email: "sender@example.com", fullName: "Example Sender", signature: "Thanks,\nAlex")
        let decoded = try JSONDecoder().decode(MailAccount.self, from: JSONEncoder().encode(account))

        XCTAssertEqual(decoded, account)
    }

    func testSignatureDraftFormattingAndEmptySignature() {
        XCTAssertEqual(
            MailSignatureFormatter.draftBody(for: "  Thanks,\nAlex  ").string,
            "\n\n-- \nThanks,\nAlex\n"
        )
        XCTAssertEqual(MailSignatureFormatter.draftBody(for: " \n ").string, "")
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
        XCTAssertEqual(RecipientAddressCompletion.activeToken(in: "first@example.com;  ALE"), "ALE")
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

    @MainActor
    func testPastedInlineImageIsEmbeddedAndSentAsRelatedMIMEPart() throws {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
        image.unlockFocus()

        let attachment = NSTextAttachment()
        attachment.image = image
        let attributedBody = NSMutableAttributedString(string: "Before ")
        attributedBody.append(NSAttributedString(attachment: attachment))
        attributedBody.append(NSAttributedString(string: " after"))

        let body = try ComposeInlineImageProcessor.process(attributedBody)
        let message = SMTPMessageBuilder.build(
            from: "sender@example.com",
            fromName: "Example Sender",
            recipients: ["friend@example.com"],
            subject: "Image",
            body: body
        )

        XCTAssertTrue(body.html.contains("data:image/png;base64,"))
        XCTAssertFalse(body.html.contains("file://"))
        XCTAssertTrue(body.plainText.contains("[Inline image]"))
        XCTAssertTrue(message.contains("multipart/related"))
        XCTAssertTrue(message.contains("Content-ID: <hackmail-inline-"))
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

    func testIMAPBodyStructureListsNamedAttachmentsButNotInlineCIDImages() {
        let attachments = IMAPAttachmentParser.parse([
            #"* 4 FETCH (UID 99 BODYSTRUCTURE (("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 10 1 NIL NIL NIL) ("APPLICATION" "OCTET-STREAM" ("NAME" "notes.md") NIL NIL "BASE64" 12 ("ATTACHMENT" ("FILENAME" "notes.md")) NIL NIL) "MIXED" ("BOUNDARY" "mixed") NIL NIL))"#
        ])

        XCTAssertEqual(attachments, [MailAttachmentInfo(
            section: "2",
            fileName: "notes.md",
            mimeType: "application/octet-stream",
            encodedSize: 12,
            transferEncoding: "base64"
        )])

        let inlineImages = IMAPAttachmentParser.parse([
            #"* 4 FETCH (UID 99 BODYSTRUCTURE (("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 20 1 NIL NIL NIL) ("IMAGE" "PNG" ("NAME" "image.png") "<image-cid>" NIL "BASE64" 12 ("INLINE" ("FILENAME" "image.png")) NIL NIL) "RELATED" ("BOUNDARY" "related") NIL NIL))"#
        ])
        XCTAssertTrue(inlineImages.isEmpty)
    }

    func testIMAPAttachmentParserDecodesEncodedFilename() {
        let attachments = IMAPAttachmentParser.parse([
            #"* 4 FETCH (UID 99 BODYSTRUCTURE (("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 10 1 NIL NIL NIL) ("IMAGE" "PNG" ("NAME" "=?UTF-8?Q?Screenshot_2026-11-08_at_6.44.10=E2=80=AFPM.png?=") NIL NIL "BASE64" 12 ("ATTACHMENT" ("FILENAME" "=?UTF-8?Q?Screenshot_2026-11-08_at_6.44.10=E2=80=AFPM.png?=")) NIL NIL) "MIXED" ("BOUNDARY" "mixed") NIL NIL))"#
        ])

        XCTAssertEqual(attachments.first?.fileName, "Screenshot 2026-11-08 at 6.44.10\u{202F}PM.png")
    }

    func testFetchedMessageHeaderCarriesAttachmentIndicatorMetadata() throws {
        let line = #"* 4 FETCH (UID 99 FLAGS () INTERNALDATE "08-Nov-2026 20:00:00 +0000" ENVELOPE ("Sun, 8 Nov 2026 20:00:00 +0000" "Notes" (("Alex" NIL "alex" "example.test")) NIL NIL NIL NIL NIL NIL "<notes@example.test>") BODYSTRUCTURE (("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 10 1 NIL NIL NIL) ("TEXT" "PLAIN" ("CHARSET" "UTF-8" "NAME" "notes.md") NIL NIL "BASE64" 12 ("ATTACHMENT" ("FILENAME" "notes.md")) NIL NIL) "MIXED" ("BOUNDARY" "mixed") NIL NIL))"#

        let message = try XCTUnwrap(IMAPServerResponseParser.parseMessage(line, mailboxPath: "INBOX"))

        XCTAssertTrue(message.hasAttachments)
        XCTAssertEqual(message.attachments.first?.fileName, "notes.md")
    }

    func testIMAPSearchResponseParsesAndDeduplicatesMatchingUIDs() {
        let uids = IMAPServerResponseParser.parseSearchUIDs([
            "* SEARCH 12 25 40",
            "* SEARCH 40 51",
            "A003 OK SEARCH completed"
        ])

        XCTAssertEqual(uids, [12, 25, 40, 51])
    }

    func testIDLEUIDSearchFiltersOutThePreviousHighestUID() {
        XCTAssertEqual(
            IMAPServerResponseParser.parseSearchUIDs(["* SEARCH 120 121"], greaterThan: 121),
            []
        )
        XCTAssertEqual(
            IMAPServerResponseParser.parseSearchUIDs(["* SEARCH 120 121 122 123"], greaterThan: 121),
            [122, 123]
        )
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

    func testInboxNotificationUsesSubjectWithoutSenderDetails() {
        XCTAssertEqual(
            InboxNotificationService.notificationBody(subjects: [" Project update "], additionalCount: 0),
            "Project update"
        )
        XCTAssertEqual(
            InboxNotificationService.notificationBody(subjects: ["Invoice", "Second"], additionalCount: 1),
            "Invoice (+1 more)"
        )
        XCTAssertEqual(
            InboxNotificationService.notificationBody(subjects: [""], additionalCount: 0),
            "New mail has arrived in one of your Inboxes."
        )
    }

    func testDockBadgeOmitsZeroAndFormatsUnreadCount() {
        XCTAssertNil(DockBadgeFormatter.label(for: 0))
        XCTAssertNil(DockBadgeFormatter.label(for: -1))
        XCTAssertEqual(DockBadgeFormatter.label(for: 7), "7")
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

    func testOpenedAttachmentTemporaryFileIsRemovedOnCleanup() throws {
        let contents = Data("temporary preview".utf8)
        let url = try OpenedAttachmentFiles.write(contents, fileName: "notes.md")
        defer { OpenedAttachmentFiles.cleanup() }

        XCTAssertEqual(try Data(contentsOf: url), contents)
        OpenedAttachmentFiles.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

final class MailStoreNavigationTests: XCTestCase {
    @MainActor
    func testNewMessageStartsWithSelectedAccountsSignature() throws {
        let suiteName = "HackMailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MailStore(defaults: defaults)
        let account = MailAccount(email: "sender@example.test", signature: "Regards,\nAlex")
        store.accounts = [account]
        store.selectedAccount = account.email

        store.beginNewMessage()

        XCTAssertEqual(store.composeBody.string, "\n\n-- \nRegards,\nAlex\n")
    }

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

    func testIMAPQuoteEscapesAndRejectsControlCharacters() throws {
        XCTAssertEqual(try IMAPCommandText.quote("plain"), "\"plain\"")
        XCTAssertEqual(try IMAPCommandText.quote(#"a"b\c"#), #""a\"b\\c""#)
        for hostile in ["INBOX\r\nA1 DELETE x", "a\nb", "a\rb", "a\u{0}b", "a\tb"] {
            XCTAssertThrowsError(try IMAPCommandText.quote(hostile), hostile)
        }
    }

    func testLongNonASCIISubjectIsSplitIntoShortEncodedWords() throws {
        let subject = String(repeating: "Grüße 日本語 😀 ", count: 12)
        let encoded = SMTPMessageBuilder.encodedSubject(subject)
        let words = encoded.components(separatedBy: "\r\n ")
        XCTAssertGreaterThan(words.count, 1)
        var decoded = ""
        for word in words {
            XCTAssertLessThanOrEqual(word.count, 75, word)
            XCTAssertTrue(word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="))
            let base64 = String(word.dropFirst(10).dropLast(2))
            decoded += String(decoding: try XCTUnwrap(Data(base64Encoded: base64)), as: UTF8.self)
        }
        XCTAssertEqual(decoded, subject)
        XCTAssertEqual(SMTPMessageBuilder.encodedSubject("Plain subject"), "Plain subject")
    }

    func testMailboxLoadProgressDescribesEachSerialStep() {
        XCTAssertEqual(MailboxLoadProgress.connecting.displayText, "Step 1 of 6 · Connecting securely to Gmail…")
        XCTAssertEqual(MailboxLoadProgress.signingOut.step, MailboxLoadProgress.totalSteps)
    }

    func testSearchProgressStepsAreOrderedAndWithinTotal() {
        let searchSteps: [MailboxLoadProgress] = [
            .connecting, .signingIn, .searchOpeningFolder, .searching, .searchFetchingHeaders, .signingOut
        ]
        XCTAssertEqual(searchSteps.map(\.step), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(searchSteps.last?.step, MailboxLoadProgress.totalSteps)
        XCTAssertTrue(MailboxLoadProgress.searching.displayText.hasPrefix("Step 4 of 6 · "))
    }

    func testEnvelopeParsesToAndCcRecipientsAndSkipsGroupMarkers() throws {
        let response = #"* 9 FETCH (UID 77 FLAGS () INTERNALDATE "06-Nov-2026 15:30:00 +0000" ENVELOPE ("Fri, 6 Nov 2026 15:30:00 +0000" "Hi" (("Alice" NIL "alice" "example.com")) NIL NIL (("Bob Smith" NIL "bob" "example.com") ("=?UTF-8?B?w4lsb2lzZQ==?=" NIL "eloise" "example.org") (NIL NIL "team" NIL) (NIL NIL NIL NIL)) (("Cara" NIL "cara" "example.com")) NIL NIL "<id@example.com>"))"#
        let message = try XCTUnwrap(IMAPServerResponseParser.parseMessage(response, mailboxPath: "INBOX"))
        XCTAssertEqual(message.toRecipients.map(\.email), ["bob@example.com", "eloise@example.org"])
        XCTAssertEqual(message.toRecipients.map(\.display), ["Bob Smith <bob@example.com>", "Éloise <eloise@example.org>"])
        XCTAssertEqual(message.ccRecipients.map(\.email), ["cara@example.com"])
    }

    func testPrintHeaderListsToAndCcRecipients() {
        var message = MailMessage(id: 1, sender: "Alice", senderEmail: "alice@example.com", time: "Nov 6", subject: "Hi", preview: "", body: "x")
        message.toRecipients = [MailAddress(name: "Bob", email: "bob@example.com")]
        message.ccRecipients = [MailAddress(name: "", email: "cara@example.com")]
        let out = MessagePrintDocument.html(for: message, mailboxName: nil)
        XCTAssertTrue(out.contains("Bob &lt;bob@example.com&gt;"))
        XCTAssertTrue(out.contains("<th>Cc:</th><td>cara@example.com</td>"))
    }

    func testCcIsWrittenToHeadersButBccNeverIs() {
        let message = SMTPMessageBuilder.build(
            from: "sender@example.com", fromName: "Sender",
            recipients: ["to@example.com"], cc: ["cc@example.com", "cc2@example.com"],
            subject: "Hi", body: OutgoingEmailBody(plainText: "x", html: "<p>x</p>")
        )
        XCTAssertTrue(message.contains("\r\nCc: <cc@example.com>, <cc2@example.com>\r\n"))
        XCTAssertTrue(message.contains("\r\nTo: <to@example.com>\r\n"))
        XCTAssertFalse(message.lowercased().contains("bcc"))
    }

    func testBccOnlyMessageUsesUndisclosedRecipientsHeader() {
        let message = SMTPMessageBuilder.build(
            from: "sender@example.com", fromName: "Sender", recipients: [],
            subject: "Hi", body: OutgoingEmailBody(plainText: "x", html: "<p>x</p>")
        )
        XCTAssertTrue(message.contains("\r\nTo: undisclosed-recipients:;\r\n"))
        XCTAssertFalse(message.contains("\r\nCc:"))
    }

    func testEnvelopeIncludesBccAndRemovesDuplicatesIgnoringCase() {
        let envelope = SMTPMessageBuilder.envelopeRecipients(
            to: ["a@example.com", "B@example.com"], cc: ["b@example.com", "c@example.com"], bcc: ["C@example.com", "d@example.com"]
        )
        XCTAssertEqual(envelope, ["a@example.com", "B@example.com", "c@example.com", "d@example.com"])
    }

    func testOptionalRecipientParsingAcceptsEmptyAndRejectsInvalid() {
        XCTAssertEqual(GmailSMTPClient.parseOptionalRecipients("  "), [])
        XCTAssertEqual(GmailSMTPClient.parseOptionalRecipients("a@example.com; b@example.com"), ["a@example.com", "b@example.com"])
        XCTAssertNil(GmailSMTPClient.parseOptionalRecipients("a@example.com, nope"))
    }

    @MainActor
    func testComposeRecipientCountsAcrossFieldsAndValidates() throws {
        let store = MailStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "cc-bcc-\(UUID().uuidString)")))
        store.composeTo = ""
        store.composeBcc = "hidden@example.com"
        XCTAssertEqual(store.composeRecipientCount, 1)
        store.composeCc = "hidden@example.com, other@example.com"
        XCTAssertEqual(store.composeRecipientCount, 2)
        store.composeCc = "broken"
        XCTAssertNil(store.composeRecipients)
        XCTAssertEqual(store.composeRecipientCount, 0)
        store.clearComposeRecipients()
        XCTAssertEqual(store.composeRecipientCount, 0)
        XCTAssertFalse(store.composeShowsCcBcc)
    }

    func testEnvelopeParsesBccRecipientsWhenPresent() throws {
        let response = #"* 10 FETCH (UID 78 FLAGS () INTERNALDATE "06-Nov-2026 15:30:00 +0000" ENVELOPE ("Fri, 6 Nov 2026 15:30:00 +0000" "Sent" (("Me" NIL "me" "example.com")) NIL NIL (("Bob" NIL "bob" "example.com")) NIL (("Hidden" NIL "hidden" "example.com")) NIL "<id2@example.com>"))"#
        let message = try XCTUnwrap(IMAPServerResponseParser.parseMessage(response, mailboxPath: "[Gmail]/Sent Mail"))
        XCTAssertEqual(message.bccRecipients.map(\.email), ["hidden@example.com"])
        XCTAssertEqual(message.toRecipients.map(\.email), ["bob@example.com"])
        XCTAssertTrue(message.ccRecipients.isEmpty)
    }
}
