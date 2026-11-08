import SwiftUI
import Contacts
import AppKit

struct AccountSettingsView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var fullName = ""
    @State private var appPassword = ""
    @State private var errorMessage: String?
    @State private var savedMessage: String?
    @State private var contactsAuthorizationStatus = ContactsDirectory.authorizationStatus
    @State private var contactsLists: [ContactsList] = []
    @State private var isLoadingContactsLists = false
    @State private var contactsErrorMessage: String?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mail Accounts").font(.system(size: 22, weight: .semibold, design: .serif))
                    Text("Connect Gmail using a Google app password.").font(.system(size: 13)).foregroundStyle(Paper.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(Paper.secondary.opacity(0.7)) }
                    .buttonStyle(.plain).help("Close")
            }

            VStack(spacing: 0) {
                if store.accounts.isEmpty {
                    Text("No Gmail accounts are configured yet. Add an address below to get started.")
                        .font(.system(size: 12)).foregroundStyle(Paper.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                } else {
                ForEach(store.accounts) { account in
                    HStack(spacing: 10) {
                        Image(systemName: "envelope.circle.fill").font(.system(size: 25)).foregroundStyle(Paper.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.email).font(.system(size: 13, weight: .medium))
                            let status = store.accountStatuses[account.email] ?? (store.hasPassword(for: account) ? "App password saved in Keychain" : "Needs app password")
                            Text([account.fullName, status].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 11.5)).foregroundStyle(store.accountStatuses[account.email] == "Connection failed" ? Color.red : Paper.secondary)
                        }
                        Spacer()
                        Button { loadAccount(account) } label: {
                            Image(systemName: "pencil").foregroundStyle(Paper.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit \(account.email)")
                        .help("Edit full name or app password")
                        if store.hasPassword(for: account) {
                            Button {
                                Task { await store.refreshMailbox(for: account) }
                            } label: {
                                if store.syncingAccount == account.email {
                                    ProgressView().controlSize(.small).frame(width: 58)
                                } else {
                                    Text(store.accountStatuses[account.email]?.hasPrefix("Connected") == true ? "Refresh" : "Connect")
                                        .frame(width: 58)
                                }
                            }
                            .buttonStyle(.bordered).controlSize(.small).disabled(store.syncingAccount != nil)
                        } else {
                            Button("Set up") { loadAccount(account) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                        Button { store.removeAccount(account) } label: { Image(systemName: "minus.circle").foregroundStyle(Paper.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(account.email)").help("Remove account")
                    }
                    .padding(12)
                    if let message = store.accountErrors[account.email] {
                        Text(message).font(.system(size: 11)).foregroundStyle(.red)
                            .padding(.horizontal, 12).padding(.bottom, 8)
                    }
                    if account.id != store.accounts.last?.id { Divider().padding(.leading, 48) }
                }
                }
            }
            .background(Paper.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Paper.border, lineWidth: 1))

            addressBookSection
            inboxNotificationSection
            languageToolSection

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Add or update account").font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Gmail address").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Paper.secondary)
                    TextField("name@gmail.com", text: $email).textFieldStyle(.roundedBorder).textContentType(.emailAddress)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Full name shown to recipients").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Paper.secondary)
                    TextField("Your name", text: $fullName).textFieldStyle(.roundedBorder).textContentType(.name)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Google app password").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Paper.secondary)
                        Spacer()
                        Text("16 characters").font(.system(size: 10.5)).foregroundStyle(Paper.secondary)
                    }
                    SecureField(hasSavedPasswordForForm ? "Leave blank to keep the saved password" : "xxxx xxxx xxxx xxxx", text: $appPassword)
                        .textFieldStyle(.roundedBorder)
                    if hasSavedPasswordForForm {
                        Text("Leave blank to change only the full name.").font(.system(size: 10.5)).foregroundStyle(Paper.secondary)
                    }
                }
                Text("Create an app password in your Google Account after enabling 2-Step Verification. It is stored only in macOS Keychain.")
                    .font(.system(size: 11.5)).foregroundStyle(Paper.secondary).fixedSize(horizontal: false, vertical: true)
                if let errorMessage { Text(errorMessage).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if let savedMessage { Text(savedMessage).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0x628067)) }
                HStack {
                    Spacer()
                    Button(saveButtonTitle) { saveAccount() }
                        .buttonStyle(.borderedProminent).tint(Paper.accent).disabled(!canSave)
                }
            }
            .padding(14)
            .background(Color(hex: 0xF4EFE6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Paper.border, lineWidth: 1))

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(Paper.accent)
                Text("Folders and messages are fetched from Gmail on demand. Message content stays in memory and is not saved for offline use. Move, archive, delete, and compose/send are implemented; SMTP sending still needs account testing.")
                    .font(.system(size: 11.5)).foregroundStyle(Paper.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        }
        .scrollIndicators(.hidden)
        .frame(width: 520, height: 820)
        .background(Paper.canvas)
        .task {
            if contactsAuthorizationStatus == .authorized {
                await loadContactsLists()
            }
        }
        .onChange(of: store.languageToolEnabled) { _, _ in store.persistLanguageToolSettings() }
        .onChange(of: store.languageToolBaseURL) { _, _ in store.persistLanguageToolSettings() }
        .onChange(of: store.languageToolLanguage) { _, _ in store.persistLanguageToolSettings() }
    }

    private var languageToolSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(Paper.accent)
                Text("LanguageTool").font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("Check drafts", isOn: $store.languageToolEnabled)
                    .toggleStyle(.switch)
                    .accessibilityLabel("Check drafts with LanguageTool")
            }
            Text("After a short pause, HackMail sends only the editable message text to your server over HTTPS. Quoted original messages, recipients, and attachments are not sent.")
                .font(.system(size: 11.5)).foregroundStyle(Paper.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("HTTPS server URL", text: $store.languageToolBaseURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("LanguageTool server URL")
            TextField("Language code (for example, en-US)", text: $store.languageToolLanguage)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("LanguageTool language")
            if !isValidLanguageToolBaseURL {
                Text("Enter an HTTPS URL such as https://languagetool.example/v2/.")
                    .font(.system(size: 10.5)).foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(Paper.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Paper.border, lineWidth: 1))
    }

    private var inboxNotificationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge").foregroundStyle(Paper.accent)
                Text("Inbox Notifications").font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("Notify for new inbox mail", isOn: Binding(
                    get: { store.inboxNotificationsEnabled },
                    set: { store.setInboxNotificationsEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Notify for new inbox mail")
            }
            Text("HackMail watches the Inbox on each connected account using IMAP IDLE. Notifications show the subject only, never the sender or body. The Dock badge shows the combined unread count; selecting an unread message marks it as read in Gmail.")
                .font(.system(size: 11.5)).foregroundStyle(Paper.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Unread Inbox total")
                Spacer()
                Text("\(store.totalUnreadInboxCount)")
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Paper.secondary)
            if store.inboxNotificationsEnabled && !store.inboxNotificationsAuthorized {
                Text("Allow HackMail notifications in macOS System Settings to receive alerts. Inbox monitoring and refresh will still work without notification permission.")
                    .font(.system(size: 10.5)).foregroundStyle(Paper.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Paper.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Paper.border, lineWidth: 1))
    }

    private var isValidLanguageToolBaseURL: Bool {
        guard let components = URLComponents(string: store.languageToolBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return components.scheme?.lowercased() == "https" && components.host != nil && components.user == nil &&
            components.password == nil && components.query == nil && components.fragment == nil
    }

    private var addressBookSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Paper.accent)
                Text("Address Book").font(.system(size: 14, weight: .semibold))
                Spacer()
                if isLoadingContactsLists {
                    ProgressView().controlSize(.small)
                } else if contactsAuthorizationStatus == .authorized {
                    Button("Refresh Lists") { Task { await loadContactsLists() } }
                        .buttonStyle(.bordered).controlSize(.small)
                } else if contactsAuthorizationStatus == .notDetermined {
                    Button("Allow Access…") { Task { await loadContactsLists(requestAuthorization: true) } }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            Text("Choose the macOS Contacts list to use for recipient suggestions. Suggestions search only that list.")
                .font(.system(size: 11.5)).foregroundStyle(Paper.secondary).fixedSize(horizontal: false, vertical: true)

            if contactsAuthorizationStatus == .authorized && !contactsLists.isEmpty {
                Picker("Contacts list", selection: Binding(
                    get: { store.selectedContactsContainerIdentifier ?? "" },
                    set: { store.selectContactsContainer($0.isEmpty ? nil : $0) }
                )) {
                    Text("Choose a list…").tag("")
                    ForEach(contactsLists) { list in
                        Text(list.name).tag(list.identifier)
                    }
                }
                .font(.system(size: 12))
                if store.selectedContactsContainerIdentifier == nil {
                    Text("Select the Google/Gmail list to enable recipient suggestions.")
                        .font(.system(size: 10.5)).foregroundStyle(Paper.secondary)
                }
            } else if contactsAuthorizationStatus == .denied || contactsAuthorizationStatus == .restricted {
                Text("Contacts access is unavailable. Allow HackMail in System Settings → Privacy & Security → Contacts.")
                    .font(.system(size: 11.5)).foregroundStyle(Paper.secondary).fixedSize(horizontal: false, vertical: true)
            } else if contactsAuthorizationStatus == .authorized && contactsLists.isEmpty && !isLoadingContactsLists {
                Text("No Contacts lists were found on this Mac.")
                    .font(.system(size: 11.5)).foregroundStyle(Paper.secondary)
            }

            if let contactsErrorMessage {
                Text(contactsErrorMessage).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(hex: 0xF4EFE6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Paper.border, lineWidth: 1))
    }

    private var canSave: Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = appPassword.filter { !$0.isWhitespace }
        let accountExists = store.accounts.contains(where: { $0.email.caseInsensitiveCompare(trimmedEmail) == .orderedSame })
        let validPassword = password.isEmpty ? accountExists : password.count == 16 && password.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return trimmedEmail.contains("@") && trimmedEmail.contains(".") && validPassword &&
            !fullName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private var hasSavedPasswordForForm: Bool {
        guard let account = store.accounts.first(where: { $0.email.caseInsensitiveCompare(email.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) else { return false }
        return store.hasPassword(for: account)
    }

    private var saveButtonTitle: String {
        let exists = store.accounts.contains(where: { $0.email.caseInsensitiveCompare(email.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame })
        if exists && appPassword.filter({ !$0.isWhitespace }).isEmpty { return "Save Changes" }
        return "Save Account Securely"
    }

    private func loadAccount(_ account: MailAccount) {
        email = account.email
        fullName = account.fullName
        appPassword = ""
        errorMessage = nil
        savedMessage = nil
    }

    private func saveAccount() {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let password = appPassword.filter { !$0.isWhitespace }
        guard normalizedEmail.contains("@"), normalizedEmail.contains(".") else {
            errorMessage = "Enter a valid email address."
            return
        }
        let existing = store.accounts.contains(where: { $0.email.caseInsensitiveCompare(normalizedEmail) == .orderedSame })
        guard password.isEmpty && existing || (password.count == 16 && password.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })) else {
            errorMessage = "Google app passwords are 16 characters. Remove spaces if needed and check the value."
            return
        }
        do {
            try store.saveAccount(email: normalizedEmail, fullName: fullName, password: password.isEmpty ? nil : password)
            appPassword = ""
            errorMessage = nil
            savedMessage = password.isEmpty ? "Full name saved." : "Account and app password saved securely."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadContactsLists(requestAuthorization: Bool = false) async {
        isLoadingContactsLists = true
        contactsErrorMessage = nil
        defer { isLoadingContactsLists = false }
        do {
            if requestAuthorization && contactsAuthorizationStatus == .notDetermined {
                let granted = try await ContactsDirectory.requestAccess()
                contactsAuthorizationStatus = ContactsDirectory.authorizationStatus
                guard granted else { return }
            }
            contactsAuthorizationStatus = ContactsDirectory.authorizationStatus
            guard contactsAuthorizationStatus == .authorized else { return }
            contactsLists = try await ContactsDirectory.lists()
            if let selected = store.selectedContactsContainerIdentifier,
               !contactsLists.contains(where: { $0.identifier == selected }) {
                store.selectContactsContainer(nil)
            }
            if store.selectedContactsContainerIdentifier == nil, contactsLists.count == 1,
               let onlyList = contactsLists.first {
                store.selectContactsContainer(onlyList.identifier)
            }
        } catch {
            contactsErrorMessage = error.localizedDescription
        }
    }
}
