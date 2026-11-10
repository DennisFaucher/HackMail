import Foundation

struct MailAccount: Identifiable, Codable, Equatable {
    var id: String { email.lowercased() }
    var email: String
    var fullName: String
    var signature: String

    init(email: String, fullName: String? = nil, signature: String = "") {
        self.email = email
        self.fullName = fullName ?? Self.suggestedFullName(for: email)
        self.signature = signature
    }

    static func suggestedFullName(for email: String) -> String {
        PersonalDefaults.suggestedFullName(for: email)
    }

    private enum CodingKeys: String, CodingKey {
        case email
        case fullName
        case signature
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        email = try values.decode(String.self, forKey: .email)
        fullName = try values.decodeIfPresent(String.self, forKey: .fullName) ?? Self.suggestedFullName(for: email)
        signature = try values.decodeIfPresent(String.self, forKey: .signature) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(email, forKey: .email)
        try values.encode(fullName, forKey: .fullName)
        try values.encode(signature, forKey: .signature)
    }
}

struct OutgoingEmailBody: Sendable {
    let plainText: String
    let html: String
}

struct MailAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let mimeType: String
    let data: Data
    var contentID: String?

    init(id: UUID = UUID(), fileName: String, mimeType: String, data: Data, contentID: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
    }

    var byteCount: Int { data.count }
}

struct MailAttachmentInfo: Identifiable, Equatable, Sendable {
    let section: String
    let fileName: String
    let mimeType: String
    let encodedSize: Int
    let transferEncoding: String

    var id: String { section }
}

struct MailMailbox: Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    let attributes: Set<String>

    var id: String { path }
    var isInbox: Bool { hasAttribute("\\Inbox") || path.caseInsensitiveCompare("INBOX") == .orderedSame }
    var isTrash: Bool { hasAttribute("\\Trash") || name.caseInsensitiveCompare("Trash") == .orderedSame }

    var symbol: String {
        if isInbox { return "tray" }
        if isTrash { return "trash" }
        if hasAttribute("\\Sent") { return "paperplane" }
        if hasAttribute("\\Drafts") { return "doc" }
        if hasAttribute("\\Junk") { return "exclamationmark.triangle" }
        if hasAttribute("\\Flagged") { return "star" }
        if hasAttribute("\\All") { return "archivebox" }
        return "folder"
    }

    private func hasAttribute(_ value: String) -> Bool {
        attributes.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }
}

struct MailAddress: Equatable, Hashable, Sendable {
    let name: String
    let email: String

    /// "Name <email>" when a display name exists, otherwise just the address.
    var display: String {
        name.isEmpty || name == email ? email : "\(name) <\(email)>"
    }
}

struct MailMessage: Identifiable, Equatable, Sendable {
    let id: Int
    let sender: String
    let senderEmail: String
    let time: String
    var sortDate: Date? = nil
    let subject: String
    let preview: String
    var body: String
    var bodyIsHTML = false
    var bodyIsPartial = false
    var bodyIsLoading = false
    var allowsRemoteImages = false
    var unread = false
    var flagged = false
    var isRemote = false
    var mailboxPath = "INBOX"
    var attachments: [MailAttachmentInfo] = []
    var toRecipients: [MailAddress] = []
    var ccRecipients: [MailAddress] = []
    var bccRecipients: [MailAddress] = []

    var hasAttachments: Bool { !attachments.isEmpty }
}

enum MessageSortColumn: String, Sendable {
    case flagged
    case subject
    case sender
    case date

    var title: String {
        switch self {
        case .flagged: "Starred"
        case .subject: "Subject"
        case .sender: "From"
        case .date: "Date"
        }
    }
}

enum MessageSortDirection: Sendable {
    case ascending
    case descending

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }

    var indicatorSymbol: String {
        self == .ascending ? "chevron.up" : "chevron.down"
    }
}

enum DockBadgeFormatter {
    static func label(for unreadCount: Int) -> String? {
        unreadCount > 0 ? String(unreadCount) : nil
    }
}

enum MailSignatureFormatter {
    static func draftBody(for signature: String) -> NSAttributedString {
        let trimmedSignature = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSignature.isEmpty else { return NSAttributedString(string: "") }
        return NSAttributedString(string: "\n\n-- \n\(trimmedSignature)\n")
    }
}
