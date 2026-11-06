import Contacts
import Combine
import Foundation
import SwiftUI

struct ContactsList: Identifiable, Equatable, Sendable {
    let identifier: String
    let name: String

    var id: String { identifier }
}

struct ContactSuggestion: Identifiable, Equatable, Hashable, Sendable {
    let name: String
    let email: String

    var id: String { email.lowercased() }
}

enum ContactsDirectoryError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "HackMail does not have access to Contacts. Enable it in System Settings → Privacy & Security → Contacts."
        }
    }
}

enum ContactsDirectory {
    static var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    static func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            CNContactStore().requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    static func lists() async throws -> [ContactsList] {
        try await Task.detached(priority: .userInitiated) {
            guard authorizationStatus == .authorized else { throw ContactsDirectoryError.accessDenied }
            let store = CNContactStore()
            return try store.containers(matching: nil)
                .map { ContactsList(identifier: $0.identifier, name: $0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }

    static func contacts(in containerIdentifier: String) async throws -> [ContactSuggestion] {
        try await Task.detached(priority: .userInitiated) {
            guard authorizationStatus == .authorized else { throw ContactsDirectoryError.accessDenied }
            let store = CNContactStore()
            let request = CNContactFetchRequest(keysToFetch: [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor
            ])
            request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: containerIdentifier)
            request.unifyResults = false

            var resultsByEmail: [String: ContactSuggestion] = [:]
            try store.enumerateContacts(with: request) { contact, _ in
                let personalName = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let name = personalName.isEmpty ? contact.organizationName : personalName
                for address in contact.emailAddresses {
                    let email = String(address.value).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !email.isEmpty else { continue }
                    let key = email.lowercased()
                    let suggestion = ContactSuggestion(name: name.isEmpty ? email : name, email: email)
                    if let existing = resultsByEmail[key] {
                        if existing.name == existing.email && suggestion.name != suggestion.email {
                            resultsByEmail[key] = suggestion
                        }
                    } else {
                        resultsByEmail[key] = suggestion
                    }
                }
            }
            return resultsByEmail.values.sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                return nameOrder == .orderedSame
                    ? $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending
                    : nameOrder == .orderedAscending
            }
        }.value
    }
}

@MainActor
final class ContactAutocompleteModel: ObservableObject {
    @Published private(set) var matches: [ContactSuggestion] = []

    private var contactsByContainer: [String: [ContactSuggestion]] = [:]
    private var searchTask: Task<Void, Never>?

    func search(query: String, containerIdentifier: String?) {
        searchTask?.cancel()
        matches = []
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.count >= 2, let containerIdentifier else { return }

        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                let contacts: [ContactSuggestion]
                if let cached = contactsByContainer[containerIdentifier] {
                    contacts = cached
                } else {
                    contacts = try await ContactsDirectory.contacts(in: containerIdentifier)
                    guard !Task.isCancelled else { return }
                    contactsByContainer[containerIdentifier] = contacts
                }
                let filtered = Self.matching(normalizedQuery, in: contacts)
                guard !Task.isCancelled else { return }
                matches = Array(filtered.prefix(8))
            } catch is CancellationError {
                return
            } catch {
                self?.matches = []
            }
        }
    }

    func clear() {
        searchTask?.cancel()
        searchTask = nil
        matches = []
    }

    nonisolated static func matching(_ query: String, in contacts: [ContactSuggestion]) -> [ContactSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return contacts.filter {
            $0.name.localizedCaseInsensitiveContains(needle) ||
                $0.email.localizedCaseInsensitiveContains(needle)
        }.sorted { left, right in
            let leftStarts = left.name.localizedCaseInsensitiveHasPrefix(needle) || left.email.localizedCaseInsensitiveHasPrefix(needle)
            let rightStarts = right.name.localizedCaseInsensitiveHasPrefix(needle) || right.email.localizedCaseInsensitiveHasPrefix(needle)
            if leftStarts != rightStarts { return leftStarts }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }
}

enum RecipientAddressCompletion {
    static func activeToken(in recipients: String) -> String {
        guard let delimiter = recipients.indices.last(where: { recipients[$0] == "," || recipients[$0] == ";" }) else {
            return recipients.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return recipients[recipients.index(after: delimiter)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replacingActiveToken(in recipients: String, with email: String) -> String {
        let start: String.Index
        if let delimiter = recipients.indices.last(where: { recipients[$0] == "," || recipients[$0] == ";" }) {
            start = recipients.index(after: delimiter)
        } else {
            start = recipients.startIndex
        }
        let prefix = recipients[..<start]
        let currentToken = recipients[start...]
        let leadingWhitespace = currentToken.prefix(while: { $0.isWhitespace })
        return String(prefix) + String(leadingWhitespace) + email + ", "
    }
}

private extension String {
    func localizedCaseInsensitiveHasPrefix(_ prefix: String) -> Bool {
        range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
    }
}

struct RecipientAutocompleteField: View {
    @Binding var recipients: String
    @Binding var suggestionsVisible: Bool
    let containerIdentifier: String?
    let isDisabled: Bool

    @StateObject private var autocomplete = ContactAutocompleteModel()
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("name@example.com (separate with commas or semicolons)", text: $recipients)
                .textFieldStyle(.plain)
                .textContentType(.emailAddress)
                .accessibilityLabel("Recipients")
                .focused($isFieldFocused)
                .disabled(isDisabled)
                .onChange(of: recipients) { _, newValue in
                    autocomplete.search(
                        query: RecipientAddressCompletion.activeToken(in: newValue),
                        containerIdentifier: containerIdentifier
                    )
                }
                .onChange(of: containerIdentifier) { _, identifier in
                    autocomplete.search(
                        query: RecipientAddressCompletion.activeToken(in: recipients),
                        containerIdentifier: identifier
                    )
                }
                .onSubmit(chooseFirstMatch)
            if !autocomplete.matches.isEmpty && isFieldFocused {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(autocomplete.matches) { contact in
                            Button {
                                choose(contact)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "person.crop.circle")
                                        .foregroundStyle(Paper.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(contact.name).font(.system(size: 12, weight: .medium))
                                        if contact.name.caseInsensitiveCompare(contact.email) != .orderedSame {
                                            Text(contact.email).font(.system(size: 11)).foregroundStyle(Paper.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(contact.name), \(contact.email)")
                        }
                    }
                    .background(Paper.reader)
                }
                .frame(maxHeight: 300)
                .background(Paper.reader, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Paper.border, lineWidth: 1))
            }
        }
        .onChange(of: autocomplete.matches) { _, _ in updateVisibility() }
        .onChange(of: isFieldFocused) { _, _ in updateVisibility() }
        .onDisappear {
            autocomplete.clear()
            suggestionsVisible = false
        }
    }

    private func chooseFirstMatch() {
        guard let contact = autocomplete.matches.first else { return }
        choose(contact)
    }

    private func choose(_ contact: ContactSuggestion) {
        recipients = RecipientAddressCompletion.replacingActiveToken(in: recipients, with: contact.email)
        autocomplete.clear()
        isFieldFocused = true
        suggestionsVisible = false
    }

    private func updateVisibility() {
        suggestionsVisible = isFieldFocused && !autocomplete.matches.isEmpty
    }
}
