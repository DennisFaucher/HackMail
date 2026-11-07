import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Paper {
    static let canvas = Color(hex: 0xEFE6D6)
    static let sidebar = Color(hex: 0xF4ECDD)
    static let panel = Color(hex: 0xFFFAF1)
    static let reader = Color(hex: 0xFFFDF8)
    static let ink = Color(hex: 0x2B2217)
    static let secondary = Color(hex: 0x686056)
    static let border = Color(hex: 0xE3DED5)
    static let accent = Color(hex: 0x9E4B27)
    static let selected = Color(hex: 0xEAD4C0)
    static let selectedMessage = Color(hex: 0xF3DFD1)
    static let mailFont = "Atkinson Hyperlegible"
}

private let mailTableColumns: [GridItem] = [
    GridItem(.fixed(72), alignment: .center),
    GridItem(.flexible(minimum: 180, maximum: 400), alignment: .leading),
    GridItem(.flexible(minimum: 140), alignment: .leading),
    GridItem(.fixed(84), alignment: .trailing)
]

struct MailWindow: View {
    @EnvironmentObject private var store: MailStore
    @State private var showingSidebar = true
    @FocusState private var messageListFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if showingSidebar { MailSidebar(messageListFocused: $messageListFocused) }
            VStack(spacing: 0) {
                MailToolbar(showingSidebar: $showingSidebar, messageListFocused: $messageListFocused)
                VStack(spacing: 10) {
                    messageList
                    MessageReader(message: store.selectedMessage)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Paper.canvas)
        .foregroundStyle(Paper.ink)
        .sheet(isPresented: $store.showSettings) { AccountSettingsView().environmentObject(store) }
        .sheet(isPresented: $store.isComposing) { ComposeView() }
        .alert("Gmail", isPresented: Binding(
            get: { store.activeError != nil },
            set: { if !$0 { store.activeError = nil } }
        )) {
            Button("OK", role: .cancel) { store.activeError = nil }
        } message: {
            Text(store.activeError ?? "An unexpected Gmail error occurred.")
        }
        .confirmationDialog(
            store.pendingMultiPermanentDelete == nil ? "Permanently delete this message?" : "Permanently delete these messages?",
            isPresented: Binding(
            get: { store.pendingPermanentDelete != nil || store.pendingMultiPermanentDelete != nil },
            set: { if !$0 { store.cancelPermanentDelete() } }
        )) {
            Button(
                store.pendingMultiPermanentDelete.map { "Delete \($0.count) Permanently" } ?? "Delete Permanently",
                role: .destructive
            ) {
                if store.pendingMultiPermanentDelete != nil {
                    store.confirmMultiPermanentDelete()
                } else {
                    store.confirmPermanentDelete()
                }
            }
            Button("Cancel", role: .cancel) { store.cancelPermanentDelete() }
        } message: {
            Text(store.pendingMultiPermanentDelete == nil
                ? "This message will be permanently removed from Gmail and cannot be recovered."
                : "These messages will be permanently removed from Gmail and cannot be recovered.")
        }
        .task {
            if store.accounts.isEmpty {
                store.showSettings = true
                return
            }
            Task { await store.startInboxMonitoring() }
            guard let account = store.accounts.first, store.hasPassword(for: account) else { return }
            await store.refreshMailbox(for: account)
        }
    }

    private var messageList: some View {
        let visibleMessages = store.filteredMessages
        return ScrollView {
            if visibleMessages.isEmpty {
                if store.syncingAccount != nil {
                    ProgressView(store.activeSearchQuery == nil ? "Loading mailbox…" : "Searching this folder…")
                        .frame(maxWidth: .infinity, minHeight: 250)
                } else if let searchError = store.searchError {
                    ContentUnavailableView(
                        "Search Failed",
                        systemImage: "exclamationmark.magnifyingglass",
                        description: Text(searchError)
                    )
                    .frame(maxWidth: .infinity, minHeight: 250)
                } else if store.activeSearchQuery != nil {
                    ContentUnavailableView(
                        "No Matching Messages",
                        systemImage: "magnifyingglass",
                        description: Text("No messages in this folder matched the Gmail search.")
                    )
                        .frame(maxWidth: .infinity, minHeight: 250)
                } else {
                    ContentUnavailableView("No Messages", systemImage: "tray")
                        .frame(maxWidth: .infinity, minHeight: 250)
                }
            } else {
                VStack(spacing: 0) {
                    LazyVGrid(columns: mailTableColumns, alignment: .leading, spacing: 0) {
                        tableHeading(.flagged, alignment: .center)
                        tableHeading(.subject, alignment: .leading)
                        tableHeading(.sender, alignment: .leading)
                        tableHeading(.date, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(Color(hex: 0xF4EFE6))
                    Rectangle().fill(Paper.border).frame(height: 1)

                    LazyVStack(spacing: 0) {
                        ForEach(visibleMessages) { message in
                            MessageRow(
                                message: message,
                                selected: store.isMessageSelected(message.id),
                                onToggleStar: {
                                    store.toggleFlag(message)
                                    messageListFocused = true
                                },
                                onSelect: { modifiers in
                                    store.select(
                                        message,
                                        command: modifiers.contains(.command),
                                        shift: modifiers.contains(.shift),
                                        visibleMessages: visibleMessages
                                    )
                                    messageListFocused = true
                                }
                            )
                            .disabled(store.syncingAccount != nil)
                        }
                    }
                    if store.canLoadMoreSearchResults || store.isLoadingMoreSearchResults {
                        Button {
                            Task { await store.loadMoreSearchResults() }
                        } label: {
                            HStack(spacing: 8) {
                                if store.isLoadingMoreSearchResults { ProgressView().controlSize(.small) }
                                Text(store.isLoadingMoreSearchResults ? "Loading more…" : "Load more search results")
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isLoadingMoreSearchResults)
                    }
                    if let searchError = store.searchError {
                        Text(searchError).font(.system(size: 11)).foregroundStyle(.red)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 290)
        .background(Paper.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Paper.border, lineWidth: 1))
        .focusable()
        .focused($messageListFocused)
        .onMoveCommand { direction in
            switch direction {
            case .up: store.moveSelection(by: -1)
            case .down: store.moveSelection(by: 1)
            default: break
            }
        }
        .accessibilityHint("Click to select a message, Command-click to add or remove it, and Shift-click to select a range. Use the Up and Down arrow keys to move between messages.")
    }

    private func tableHeading(_ column: MessageSortColumn, alignment: Alignment) -> some View {
        Button {
            store.sortMessages(by: column)
            messageListFocused = true
        } label: {
            HStack(spacing: 4) {
                Text(column.title.uppercased())
                if store.sortColumn == column {
                    Image(systemName: store.sortDirection.indicatorSymbol)
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .bold)).tracking(0.7).foregroundStyle(Paper.secondary)
        .accessibilityLabel("Sort by \(column.title)")
        .accessibilityValue(store.sortColumn == column
            ? (store.sortDirection == .ascending ? "Ascending" : "Descending")
            : "Not sorted")
        .help(store.sortColumn == column
            ? "Sorted \(store.sortDirection == .ascending ? "ascending" : "descending"); click to reverse"
            : "Sort by \(column.title)")
        .disabled(store.syncingAccount != nil)
    }
}

private struct MailSidebar: View {
    @EnvironmentObject private var store: MailStore
    @FocusState.Binding var messageListFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: 0xFF5F57))
                    Circle().fill(Color(hex: 0xFEBC2E))
                    Circle().fill(Color(hex: 0x28C840))
                }
                .frame(width: 12, height: 12)
                Spacer()
                Button { store.showSettings = true } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(Paper.secondary)
                }
                .buttonStyle(.plain).help("Mail accounts and settings")
            }
            .padding(.horizontal, 20).frame(height: 52)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !store.favoriteMailboxes.isEmpty {
                        sectionTitle("Favorites")
                        ForEach(store.favoriteMailboxes) { mailbox in mailboxRow(mailbox) }
                    }

                    sectionTitle("Mailboxes")
                    if store.mailboxes.isEmpty {
                        if store.syncingAccount == store.selectedAccount {
                            HStack(alignment: .top, spacing: 9) {
                                ProgressView().controlSize(.small)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Connecting to Gmail…")
                                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Paper.ink)
                                    Text("Loading folders and recent messages. This can take around 10 seconds.")
                                        .font(.system(size: 10.5)).foregroundStyle(Paper.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        } else if let account = store.accounts.first(where: { $0.email == store.selectedAccount }), store.hasPassword(for: account) {
                            Button {
                                Task { await store.refreshMailbox(for: account) }
                            } label: {
                                Label("Reconnect to load folders", systemImage: "arrow.clockwise")
                                    .font(.system(size: 11.5)).foregroundStyle(Paper.secondary)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button { store.showSettings = true } label: {
                                Label("Add an account in Settings", systemImage: "gearshape")
                                    .font(.system(size: 11.5)).foregroundStyle(Paper.secondary)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        ForEach(store.mailboxes) { mailbox in mailboxRow(mailbox) }
                    }
                }
            }
            .scrollIndicators(.hidden)

            sectionTitle("Accounts")
            ForEach(store.accounts) { account in
                Button {
                    store.selectAccount(account)
                    messageListFocused = true
                } label: {
                    HStack(spacing: 8) {
                        let isConnected = store.accountStatuses[account.email]?.hasPrefix("Connected") == true
                        Circle().fill(isConnected ? Color(hex: 0x78A27B) : Color(hex: 0xC59B64)).frame(width: 7, height: 7)
                        Text(account.email).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11.5, weight: store.selectedAccount == account.email ? .semibold : .regular))
                    .foregroundStyle(Paper.ink).padding(.horizontal, 10).frame(height: 28)
                    .background(store.selectedAccount == account.email ? Paper.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain).padding(.horizontal, 10)
                .disabled(store.syncingAccount != nil)
                .help(store.hasPassword(for: account) ? "Connected account" : "Add its Google app password in Settings")
            }
            Spacer(minLength: 12)
            Button { store.showSettings = true } label: {
                Label("Account Settings…", systemImage: "gearshape")
                    .font(.system(size: 12)).foregroundStyle(Paper.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 0)
        .frame(width: 226)
        .background(Paper.sidebar, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0xD4CCBD), lineWidth: 1))
        .padding(.leading, 10).padding(.vertical, 10).padding(.trailing, 0)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(1)
            .foregroundStyle(Paper.secondary).padding(.leading, 20).padding(.top, 16).padding(.bottom, 5)
    }

    private func mailboxRow(_ mailbox: MailMailbox) -> some View {
        Button {
            store.selectMailbox(mailbox)
            messageListFocused = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: mailbox.symbol).font(.system(size: 12)).frame(width: 14)
                Text(mailbox.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5, weight: store.selectedMailboxPath == mailbox.path ? .semibold : .regular))
            .foregroundStyle(Paper.ink).padding(.horizontal, 10).frame(height: 26)
            .background(store.selectedMailboxPath == mailbox.path ? Paper.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).padding(.horizontal, 10).disabled(store.syncingAccount != nil)
    }
}

private struct MailToolbar: View {
    @EnvironmentObject private var store: MailStore
    @Binding var showingSidebar: Bool
    @FocusState.Binding var messageListFocused: Bool
    @State private var isShowingMoveMenu = false

    var body: some View {
        HStack(spacing: 8) {
            Button { showingSidebar.toggle() } label: {
                Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(Paper.secondary).frame(width: 28, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle sidebar")
            .help("Toggle sidebar")
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedMailbox?.name ?? "Inbox").font(.system(size: 15, weight: .bold))
                Text(store.mailboxMessageCountLabel).font(.system(size: 11.5)).foregroundStyle(Paper.secondary)
            }.frame(minWidth: 104, alignment: .leading)
            HStack(spacing: 7) {
                Button {
                    Task { await store.searchCurrentFolder() }
                } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(Paper.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search this folder")
                .help("Run Gmail search in this folder")
                .disabled(store.syncingAccount != nil)
                TextField("Search this folder", text: $store.searchText)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .accessibilityLabel("Search mail in this folder")
                    .help("Use Gmail search operators; press Return to search every message in this folder")
                    .onSubmit { Task { await store.searchCurrentFolder() } }
                    .disabled(store.syncingAccount != nil)
                if !store.searchText.isEmpty {
                    Button { store.clearSearchAndReload() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Paper.secondary)
                    }
                    .buttonStyle(.plain).help("Clear search and reload this folder")
                    .disabled(store.syncingAccount != nil)
                }
            }
            .padding(.horizontal, 10).frame(maxWidth: 270, minHeight: 30)
            .background(Paper.panel, in: RoundedRectangle(cornerRadius: 7))
            Spacer(minLength: 8)
            toolbarButton("arrow.clockwise", help: "Refresh Mailbox") {
                guard let account = store.accounts.first(where: { $0.email == store.selectedAccount }) else { return }
                Task { await store.refreshMailbox(for: account) }
                messageListFocused = true
            }.disabled(store.syncingAccount != nil)
            toolbarButton("square.and.pencil", help: "New Message") { store.beginNewMessage() }
                .disabled(store.isSendingMessage || store.isPreparingCompose)
            if store.isMultiSelectionActive {
                HStack(spacing: 5) {
                    Text("\(store.selectedMessages.count) selected")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Paper.secondary)
                        .lineLimit(1).fixedSize()
                    moveMailboxButton
                    toolbarButton("archivebox", help: "Archive Selected Messages") { store.archiveSelectedMessages() }
                        .disabled(!canApplyBulkAction)
                    toolbarButton(
                        store.selectedMessagesAreAllFlagged ? "flag.fill" : "flag",
                        help: store.selectedMessagesAreAllFlagged ? "Unflag Selected Messages" : "Flag Selected Messages"
                    ) { store.toggleFlagSelectedMessages() }
                        .disabled(!canApplyBulkAction)
                    toolbarButton("trash", help: store.selectedMailbox?.isTrash == true ? "Permanently Delete Selected" : "Move Selected to Trash") {
                        store.deleteSelectedMessages()
                    }
                    .disabled(!canApplyBulkAction)
                    toolbarButton("xmark", help: "Clear Multi-Selection") { store.clearMultiSelection() }
                }
            } else {
                toolbarButton("archivebox", help: "Archive") { store.archiveSelected() }
                    .disabled(store.selectedMessage?.isRemote != true || store.syncingAccount != nil)
                moveMailboxButton
                toolbarButton("trash", help: store.selectedMailbox?.isTrash == true ? "Delete Permanently" : "Move to Trash") { store.deleteSelected() }
                    .disabled(store.selectedMessage?.isRemote != true || store.syncingAccount != nil)
                Rectangle().fill(Paper.border).frame(width: 1, height: 18).padding(.horizontal, 5)
                toolbarButton("arrowshape.turn.up.left", help: "Reply") { store.beginReply() }
                    .disabled(store.selectedMessage == nil || store.selectedMessage?.senderEmail.isEmpty != false || store.selectedMessage?.bodyIsLoading == true || store.syncingAccount != nil || store.isSendingMessage || store.isPreparingCompose)
                toolbarButton("arrowshape.turn.up.right", help: "Forward") { store.beginForward() }
                    .disabled(store.selectedMessage == nil || store.selectedMessage?.bodyIsLoading == true || store.syncingAccount != nil || store.isSendingMessage || store.isPreparingCompose)
                toolbarButton("flag", help: "Flag") {
                    if let message = store.selectedMessage { store.toggleFlag(message) }
                }.disabled(store.syncingAccount != nil)
            }
            toolbarButton("gearshape", help: "Account Settings") { store.showSettings = true }
        }
        .padding(.horizontal, 16).frame(height: 62)
        .onChange(of: store.selectedMailboxPath) { _, _ in isShowingMoveMenu = false }
        .onChange(of: store.selectedAccount) { _, _ in isShowingMoveMenu = false }
    }

    private func toolbarButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Paper.ink).frame(width: 32, height: 30) }
            .buttonStyle(.plain)
            .accessibilityLabel(help)
            .help(help)
    }

    private var moveMailboxButton: some View {
        Button { isShowingMoveMenu = true } label: {
            Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(Paper.ink).frame(width: 32, height: 30)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .frame(width: 40, height: 30)
        .accessibilityLabel(store.isMultiSelectionActive ? "Move selected messages to mailbox" : "Move to mailbox")
        .help(store.isMultiSelectionActive ? "Move selected messages to mailbox" : "Move to mailbox")
        .disabled(store.isMultiSelectionActive
            ? (!canApplyBulkAction || store.mailboxes.count < 2)
            : (store.selectedMessage?.isRemote != true || store.syncingAccount != nil || store.mailboxes.count < 2))
        .popover(isPresented: $isShowingMoveMenu, arrowEdge: .bottom) { moveMailboxPopover }
    }

    private var canApplyBulkAction: Bool {
        !store.selectedMessages.isEmpty && store.selectedMessages.allSatisfy(\.isRemote) && store.syncingAccount == nil
    }

    private var moveMailboxPopover: some View {
        let destinations = store.mailboxes.filter { $0.path != store.selectedMailboxPath }
        let height = min(max(CGFloat(destinations.count * 32 + 48), 90), 320)
        return VStack(alignment: .leading, spacing: 8) {
            Text(store.isMultiSelectionActive
                ? "Move \(store.selectedMessages.count) messages to…"
                : "Move message to…")
                .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 6)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(destinations) { mailbox in
                        Button {
                            if store.isMultiSelectionActive {
                                store.moveSelectedMessages(to: mailbox)
                            } else {
                                store.moveSelected(to: mailbox)
                            }
                            isShowingMoveMenu = false
                        } label: {
                            Label(mailbox.name, systemImage: mailbox.symbol)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).frame(height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 250, height: height)
        .background(Paper.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MessageRow: View {
    let message: MailMessage
    let selected: Bool
    let onToggleStar: () -> Void
    let onSelect: (NSEvent.ModifierFlags) -> Void

    var body: some View {
        LazyVGrid(columns: mailTableColumns, alignment: .leading, spacing: 0) {
            Button(action: onToggleStar) {
                Image(systemName: message.flagged ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(message.flagged ? Paper.accent : Paper.secondary.opacity(0.65))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(message.flagged ? "Remove star from \(message.subject)" : "Star \(message.subject)")
            .help(message.flagged ? "Remove star" : "Star message")

            Button { onSelect(NSEvent.modifierFlags) } label: {
                HStack(spacing: 6) {
                    if message.unread { Circle().fill(Paper.accent).frame(width: 5, height: 5) }
                    Text(message.subject).font(.custom(Paper.mailFont, size: 13.5)).fontWeight(message.unread ? .semibold : .regular).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button { onSelect(NSEvent.modifierFlags) } label: {
                Text(message.sender).font(.custom(Paper.mailFont, size: 13)).lineLimit(1)
                    .foregroundStyle(message.unread ? Paper.ink : Paper.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Button { onSelect(NSEvent.modifierFlags) } label: {
                Text(message.time).font(.custom(Paper.mailFont, size: 12)).foregroundStyle(Paper.secondary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Paper.selectedMessage : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Paper.border).frame(height: 1) }
    }
}

private struct MessageReader: View {
    @EnvironmentObject private var store: MailStore
    let message: MailMessage?
    @State private var pendingLink: URL?
    @State private var pendingFullMessage: MailMessage?
    @State private var pendingFullMessageAccount: String?

    var body: some View {
        ScrollView {
            if let message {
                VStack(alignment: .leading, spacing: 0) {
                    Text("MESSAGE  ·  \(message.time.uppercased())")
                        .font(.system(size: 10.5, weight: .bold)).tracking(1.1).foregroundStyle(Paper.secondary)
                    Text(message.subject).font(.custom(Paper.mailFont, size: 25)).fontWeight(.semibold).lineSpacing(2).padding(.top, 6).padding(.bottom, 14)
                    HStack(spacing: 8) {
                        Circle().fill(Paper.selected).frame(width: 30, height: 30).overlay {
                            Text(String(message.sender.prefix(1))).font(.system(size: 13, weight: .semibold)).foregroundStyle(Paper.accent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.sender).font(.system(size: 12.5, weight: .semibold))
                            Text("to me · \(message.senderEmail)").font(.system(size: 11.5)).foregroundStyle(Paper.secondary)
                        }
                        Spacer()
                        Text(message.time).font(.system(size: 11.5)).foregroundStyle(Paper.secondary)
                    }.padding(.vertical, 8)
                    Rectangle().fill(Paper.border).frame(height: 1).padding(.vertical, 13)
                    if store.loadingMessageID == message.id {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Loading message from Gmail…").font(.system(size: 12)).foregroundStyle(Paper.secondary)
                            Spacer()
                            Button("Cancel (Esc)") { store.cancelCurrentMessageLoad() }
                                .buttonStyle(.bordered).controlSize(.small)
                                .keyboardShortcut(.cancelAction)
                        }
                        .padding(12)
                        .background(Color(hex: 0xF4EFE6), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Paper.border, lineWidth: 1))
                        .padding(.bottom, 14)
                    } else if message.isRemote && !message.bodyIsLoading && (message.bodyIsPartial || (message.bodyIsHTML && !message.allowsRemoteImages)) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(message.bodyIsPartial ? "Message preview is limited" : "Remote images are blocked")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(message.bodyIsPartial
                                     ? "Load the complete text part and, for HTML mail, opt in to remote images."
                                     : "Load images hosted by the sender’s email to see the complete design.")
                                    .font(.system(size: 11.5)).foregroundStyle(Paper.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Button(message.bodyIsPartial ? "Load Full Message…" : "Load Images…") {
                                pendingFullMessage = message
                                pendingFullMessageAccount = store.selectedAccount
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(store.syncingAccount != nil)
                        }
                        .padding(12)
                        .background(Color(hex: 0xF4EFE6), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Paper.border, lineWidth: 1))
                        .padding(.bottom, 14)
                    } else if message.isRemote && message.bodyIsHTML && message.allowsRemoteImages {
                        HStack(spacing: 8) {
                            Label("Remote images are allowed for this message", systemImage: "checkmark.shield")
                                .font(.system(size: 11.5)).foregroundStyle(Color(hex: 0x628067))
                            Spacer()
                            Button("Block") { store.blockRemoteImages(for: message) }
                                .buttonStyle(.borderless).font(.system(size: 11.5))
                        }
                        .padding(.bottom, 12)
                    }
                    if store.loadingMessageID == message.id {
                        EmptyView()
                    } else if message.bodyIsHTML {
                        HTMLMessageView(html: message.body, allowRemoteImages: message.allowsRemoteImages, onOpenLink: requestLinkConfirmation)
                            .frame(maxWidth: .infinity).frame(height: 480)
                            .padding(.top, 4)
                            .accessibilityLabel("Email message content")
                            .id("\(message.id)-\(message.allowsRemoteImages)")
                    } else {
                        Text(PlainTextLinkFormatter.format(message.body)).font(.custom(Paper.mailFont, size: 15)).lineSpacing(7).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(.horizontal, 24).padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .top)
            } else {
                ContentUnavailableView("No Message Selected", systemImage: "envelope")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.reader)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Paper.border, lineWidth: 1))
        .environment(\.openURL, OpenURLAction { url in
            requestLinkConfirmation(url)
            return .handled
        })
        .alert("Open this link outside HackMail?", isPresented: Binding(
            get: { pendingLink != nil },
            set: { if !$0 { pendingLink = nil } }
        )) {
            Button("Open in Browser") {
                if let pendingLink { NSWorkspace.shared.open(pendingLink) }
                pendingLink = nil
            }
            Button("Copy URL") {
                if let pendingLink {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pendingLink.absoluteString, forType: .string)
                }
                pendingLink = nil
            }
            Button("Cancel", role: .cancel) { pendingLink = nil }
        } message: {
            Text("Destination: \(pendingLink?.host ?? "unknown host"). Review it before opening.")
        }
        .confirmationDialog("Load full message content?", isPresented: Binding(
            get: { pendingFullMessage != nil },
            set: { if !$0 { pendingFullMessage = nil; pendingFullMessageAccount = nil } }
        )) {
            Button("Load Full Message") {
                if let pendingFullMessage {
                    let messageToLoad = pendingFullMessage
                    let accountToLoad = pendingFullMessageAccount
                    Task { await store.loadFullMessage(messageToLoad, accountEmail: accountToLoad) }
                }
                pendingFullMessage = nil
                pendingFullMessageAccount = nil
            }
            Button("Cancel", role: .cancel) {
                pendingFullMessage = nil
                pendingFullMessageAccount = nil
            }
        } message: {
            if pendingFullMessage?.bodyIsHTML == true {
                Text("This fetches the complete text part and allows remote images. Image servers may learn your IP address and that you opened the message. Scripts, attachments, remote stylesheets, and automatic link navigation remain blocked.")
            } else {
                Text("This fetches the complete text part on demand. It remains in memory only; attachments are not fetched.")
            }
        }
    }

    private func requestLinkConfirmation(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        pendingLink = url
    }

}

private struct ComposeView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @StateObject private var editorController = RichTextEditorController()
    @StateObject private var languageToolChecker = LanguageToolChecker()
    @State private var isImportingAttachments = false
    @State private var isShowingLinkPopover = false
    @State private var linkAddress = ""
    @State private var pendingQuotedLink: URL?
    @State private var isShowingRecipientSuggestions = false
    @State private var isShowingLanguageToolReview = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.composeTitle).font(.system(size: 19, weight: .semibold, design: .serif))
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction).disabled(store.isSendingMessage)
            }
                .padding(16)
            Divider()
            HStack(spacing: 12) {
                Text("From").foregroundStyle(Paper.secondary).frame(width: 54, alignment: .leading)
                Text(store.selectedAccount ?? "No Gmail account selected").lineLimit(1)
                Spacer()
            }
            .font(.system(size: 12.5)).padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                Text("To").foregroundStyle(Paper.secondary).frame(width: 54, alignment: .leading).padding(.top, 3)
                RecipientAutocompleteField(
                    recipients: $store.composeTo,
                    suggestionsVisible: $isShowingRecipientSuggestions,
                    containerIdentifier: store.selectedContactsContainerIdentifier,
                    isDisabled: store.isPreparingCompose || store.isSendingMessage
                )
            }
            .font(.system(size: 12.5)).padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            HStack(spacing: 12) {
                Text("Subject").foregroundStyle(Paper.secondary).frame(width: 54, alignment: .leading)
                TextField("Subject", text: $store.composeSubject).textFieldStyle(.plain)
                    .accessibilityLabel("Subject")
                    .disabled(store.isPreparingCompose || store.isSendingMessage)
            }
            .font(.system(size: 12.5)).padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if store.isPreparingCompose {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(store.composePreparationMessage.isEmpty ? "Preparing original message…" : store.composePreparationMessage)
                        .font(.system(size: 12.5)).foregroundStyle(Paper.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            HStack(spacing: 4) {
                formatButton("bold", label: "Bold", shortcut: "b") { editorController.toggleBold() }
                formatButton("italic", label: "Italic", shortcut: "i") { editorController.toggleItalic() }
                formatButton("underline", label: "Underline", shortcut: "u") { editorController.toggleUnderline() }
                formatButton("list.bullet", label: "Bulleted list", shortcut: nil) { editorController.toggleBullets() }
                formatButton("list.number", label: "Numbered list", shortcut: nil) { editorController.toggleNumberedList() }
                Button {
                    linkAddress = "https://"
                    isShowingLinkPopover = true
                } label: {
                    Image(systemName: "link").frame(width: 30, height: 28)
                }
                .buttonStyle(.borderless).accessibilityLabel("Insert link").help("Insert link")
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!editorController.hasSelection || store.isSendingMessage || store.isPreparingCompose)
                .popover(isPresented: $isShowingLinkPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Link address").font(.system(size: 12, weight: .semibold))
                        TextField("https://example.com", text: $linkAddress).textFieldStyle(.roundedBorder)
                        HStack {
                            Spacer()
                            Button("Insert") { insertLink() }
                                .buttonStyle(.borderedProminent).tint(Paper.accent)
                                .disabled(!isAllowedLink(linkAddress))
                        }
                    }
                    .padding(14).frame(width: 280)
                }
                Spacer()
                Button { isImportingAttachments = true } label: {
                    Label("Attach", systemImage: "paperclip").font(.system(size: 11.5))
                }
                .buttonStyle(.borderless).accessibilityLabel("Attach files")
                .help("Attach files (18 MB total limit; held in memory until sent)")
                .disabled(store.isSendingMessage || store.isPreparingCompose)
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(Color(hex: 0xF4EFE6))
            if store.languageToolEnabled {
                languageToolStatus
            }
            if store.composeBodyWasTruncated {
                Label("The quoted original was shortened to keep the composer responsive.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(Paper.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
            RichTextEditor(text: $store.composeBody, controller: editorController) { text in
                scheduleLanguageToolCheck(for: text)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .accessibilityLabel("Message body")
                .disabled(store.isSendingMessage || store.isPreparingCompose)
            if let quotedMessage = store.quotedMessage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(store.composeTitle == "Reply" ? "Original message" : "Forwarded message")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(quotedMessage.sender) · \(quotedMessage.time)")
                            .font(.system(size: 11)).foregroundStyle(Paper.secondary).lineLimit(1)
                    }
                    if quotedMessage.bodyIsHTML {
                        if !quotedMessage.allowsRemoteImages {
                            Text("Remote images remain blocked in this forwarded copy.")
                                .font(.system(size: 10.5)).foregroundStyle(Paper.secondary)
                        }
                        HTMLMessageView(
                            html: quotedMessage.body,
                            allowRemoteImages: quotedMessage.allowsRemoteImages,
                            onOpenLink: requestQuotedLinkConfirmation
                        )
                        .frame(maxWidth: .infinity).frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        ScrollView {
                            Text(PlainTextLinkFormatter.format(store.quotedPlainText))
                                .font(.custom(Paper.mailFont, size: 12)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    }
                }
                .padding(12)
                .background(Color(hex: 0xF4EFE6), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Paper.border, lineWidth: 1))
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if !store.composeAttachments.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.composeAttachments) { attachment in
                            HStack(spacing: 8) {
                                Image(systemName: "paperclip").foregroundStyle(Paper.accent)
                                Text(attachment.fileName).lineLimit(1)
                                Text(attachment.mimeType).foregroundStyle(Paper.secondary).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                                    .foregroundStyle(Paper.secondary)
                                Spacer()
                                Button { store.removeAttachment(attachment) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(Paper.secondary)
                                }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(attachment.fileName)")
                            }
                            .font(.system(size: 11.5)).padding(.horizontal, 14).padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxHeight: 84)
                .accessibilityLabel("Attachments")
            }
            }
            Divider()
            HStack(spacing: 10) {
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 11.5)).foregroundStyle(.red).lineLimit(2)
                } else if let preparationError = store.composePreparationError {
                    Text(preparationError).font(.system(size: 11.5)).foregroundStyle(.red).lineLimit(2)
                } else if !store.composeTo.isEmpty && GmailSMTPClient.parseRecipients(store.composeTo) == nil {
                    Text("Enter valid email addresses, separated by commas or semicolons.").font(.system(size: 11.5)).foregroundStyle(.red)
                } else if store.composeTo.isEmpty {
                    Text("Separate multiple recipients with commas or semicolons.").font(.system(size: 11.5)).foregroundStyle(Paper.secondary)
                } else if store.accounts.first(where: { $0.email == store.selectedAccount }).map({ store.hasPassword(for: $0) }) != true {
                    Text("Add an app password in Settings to send mail.").font(.system(size: 11.5)).foregroundStyle(Paper.secondary)
                }
                Spacer(minLength: 8)
                if store.isSendingMessage { ProgressView().controlSize(.small) }
                Button("Send") { send() }
                    .buttonStyle(.borderedProminent).tint(Paper.accent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canSendComposedMessage)
            }
                .padding(14)
        }
        .frame(
            width: 620,
            height: (store.quotedMessage == nil ? 500 : 700) + (isShowingRecipientSuggestions ? 320 : 0)
        )
        .background(Paper.reader)
        .environment(\.openURL, OpenURLAction { url in
            requestQuotedLinkConfirmation(url)
            return .handled
        })
        .alert("Open this link outside HackMail?", isPresented: Binding(
            get: { pendingQuotedLink != nil },
            set: { if !$0 { pendingQuotedLink = nil } }
        )) {
            Button("Open in Browser") {
                if let pendingQuotedLink { NSWorkspace.shared.open(pendingQuotedLink) }
                pendingQuotedLink = nil
            }
            Button("Copy URL") {
                if let pendingQuotedLink {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pendingQuotedLink.absoluteString, forType: .string)
                }
                pendingQuotedLink = nil
            }
            Button("Cancel", role: .cancel) { pendingQuotedLink = nil }
        } message: {
            Text("Destination: \(pendingQuotedLink?.host ?? "unknown host"). Review it before opening.")
        }
        .fileImporter(isPresented: $isImportingAttachments, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task {
                    do {
                        try await store.addAttachments(from: urls)
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .onAppear { scheduleLanguageToolCheck(for: store.composeBody.string) }
        .onChange(of: store.languageToolEnabled) { _, _ in scheduleLanguageToolCheck(for: store.composeBody.string) }
        .onChange(of: store.languageToolBaseURL) { _, _ in scheduleLanguageToolCheck(for: store.composeBody.string) }
        .onChange(of: store.languageToolLanguage) { _, _ in scheduleLanguageToolCheck(for: store.composeBody.string) }
        .onChange(of: languageToolChecker.matches) { _, matches in
            editorController.applyLanguageToolHighlights(matches)
        }
        .onDisappear {
            languageToolChecker.cancel()
            editorController.clearLanguageToolHighlights()
        }
    }

    private var languageToolStatus: some View {
        HStack(spacing: 8) {
            if languageToolChecker.isChecking {
                ProgressView().controlSize(.small)
                Text("Checking draft with LanguageTool…").foregroundStyle(Paper.secondary)
            } else if let error = languageToolChecker.errorMessage {
                Label("LanguageTool unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Paper.secondary).help(error)
                Spacer(minLength: 4)
                Button("Retry") { scheduleLanguageToolCheck(for: store.composeBody.string) }
                    .buttonStyle(.borderless)
            } else if !languageToolChecker.matches.isEmpty {
                Label("\(languageToolChecker.matches.count) suggestions", systemImage: "text.magnifyingglass")
                    .foregroundStyle(Paper.secondary)
                    .help("Misspelled words and grammar issues have red dotted underlines. Right-click an underlined word for quick corrections.")
                Spacer(minLength: 4)
                Button("Review") { isShowingLanguageToolReview = true }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $isShowingLanguageToolReview, arrowEdge: .top) {
                        languageToolReview
                    }
            } else if languageToolChecker.hasChecked {
                Label("No suggestions", systemImage: "checkmark.circle")
                    .foregroundStyle(Color(hex: 0x628067))
            } else {
                Label("LanguageTool checks after you pause typing", systemImage: "text.magnifyingglass")
                    .foregroundStyle(Paper.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 14).padding(.vertical, 5)
    }

    private var languageToolReview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review suggestions").font(.system(size: 13, weight: .semibold))
                ForEach(languageToolChecker.matches) { match in
                    VStack(alignment: .leading, spacing: 6) {
                        if let context = match.context?.text, !context.isEmpty {
                            Text(context).font(.system(size: 11.5)).foregroundStyle(Paper.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(match.message).font(.system(size: 12))
                        if match.replacements.isEmpty {
                            Text("Review this suggestion manually.")
                                .font(.system(size: 10.5)).foregroundStyle(Paper.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), alignment: .leading)], alignment: .leading, spacing: 6) {
                                ForEach(Array(match.replacements.prefix(4).enumerated()), id: \.offset) { item in
                                    Button(item.element.value) {
                                        editorController.applyReplacement(
                                            item.element.value,
                                            range: NSRange(location: match.offset, length: match.length)
                                        )
                                        isShowingLanguageToolReview = false
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if match.id != languageToolChecker.matches.last?.id { Divider() }
                }
            }
            .padding(14)
        }
        .frame(width: 360, height: 360)
    }

    private func scheduleLanguageToolCheck(for text: String) {
        languageToolChecker.scheduleCheck(
            text: text,
            enabled: store.languageToolEnabled,
            baseURL: store.languageToolBaseURL,
            language: store.languageToolLanguage
        )
    }

    @ViewBuilder
    private func formatButton(_ symbol: String, label: String, shortcut: KeyEquivalent?, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Image(systemName: symbol).frame(width: 30, height: 28)
        }
        .buttonStyle(.borderless).accessibilityLabel(label).help(label)
        .disabled(store.isSendingMessage || store.isPreparingCompose)
        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: .command)
        } else {
            button
        }
    }

    private func isAllowedLink(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "mailto" { return url.path.contains("@") }
        return ["http", "https"].contains(scheme) && url.host != nil
    }

    private func insertLink() {
        guard isAllowedLink(linkAddress), let url = URL(string: linkAddress) else { return }
        editorController.applyLink(url)
        isShowingLinkPopover = false
    }

    private func requestQuotedLinkConfirmation(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        pendingQuotedLink = url
    }

    private func send() {
        errorMessage = nil
        Task {
            do {
                try await store.sendComposedMessage()
                store.isComposing = false
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func close() {
        store.discardComposition()
        dismiss()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
