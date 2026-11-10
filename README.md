# HackMail

A native SwiftUI macOS Gmail client that works completely online with low RAM footprint.

<img width="1256" height="1049" alt="image" src="https://github.com/user-attachments/assets/beca47db-2348-41b7-beef-71b14e93430a" />

## Run

```sh
swift run
```

Run the automated checks with `swift test`.

No message is selected when you open a folder or finish a search; nothing loads until you click a message.
In the message list, click a row or mailbox to focus the list, then use **↑ / ↓** to move through
messages and update the reader. **Command-click** adds or removes messages from a selection;
**Shift-click** selects a range. Bulk toolbar actions move, flag/unflag, or delete selected messages.

Build and launch a local app bundle:

```sh
./Scripts/build-app.sh
open .build/HackMail.app
```

Launch the app bundle for macOS Contacts access; its Info.plist includes the Contacts permission description.

The app bundle identifier is read from `Scripts/bundle-identifier.txt`. Per-person defaults (suggested accounts,
the default LanguageTool server, and the Keychain service name) live in `Sources/HackMail/PersonalDefaults.swift`.

The bundle uses `Icons/PirateMail.icns` and is ad-hoc signed for local development. Distribution
requires Developer ID signing and Apple notarization.

Requires macOS 14 or later and Xcode/Swift 6. On first launch, Mail Accounts opens so users can enter their own Gmail address, display name, and Google app password. Passwords are saved in macOS Keychain; account addresses and sender display names are stored in UserDefaults.

Google app passwords are 16 characters (often displayed in four groups), not necessarily digits. The password field accepts the 16-character value with or without spaces.

## Current scope

* The app connects to Gmail over TLS and fetches recent mailbox headers. When you open a message, it
fetches a bounded HTML MIME body part when available, falling back to plain text.
* Press **Esc** or click **Cancel** to interrupt a stalled message-body load.
* The reader renders HTML in a JavaScript-disabled, non-persistent WebKit view that blocks remote resources; clicked HTTP(S) links require confirmation and open in the system browser.
* In plain-text mail, parenthesized long URLs display as links on their neighboring labels; standalone URLs remain visible.
* A separate full-message opt-in fetches the complete text body and permits remote images only after a privacy warning; scripts and remote stylesheets remain blocked. CID-referenced inline images bundled inside a message are resolved in memory; this does not contact the image host.
* While HackMail is running, Gmail IMAP IDLE watches each configured Inbox and refreshes the selected Inbox when new mail arrives.
* macOS notifications are enabled by default and show the message subject, but not the sender or body. The Dock badge shows the combined unread count for configured Inboxes; selecting an unread message marks it as read in Gmail. Notification permission can be changed in **Mail → Mail Accounts…**.
* Folders and incoming messages are held in memory only; there is no offline email cache. Attachment metadata is shown in the reader and the message list shows a paperclip for messages with attachments. Files are fetched only when you choose **Open** or **Save** (25 MiB limit per attachment); Open uses the macOS default app with a temporary copy removed when HackMail quits.
* While a folder loads or a search runs, the list shows the current step (for example "Step 4 of 6 · Gmail is searching this folder…") and elapsed time. Press **Esc** or click **Cancel Search** to stop a search and return to the folder.
* Search queries use Gmail's search syntax and are executed server-side against the selected folder; matching headers are loaded in pages.
* Remote folder navigation, star, move, and delete operations are implemented, including multi-select actions over Gmail IMAP.
* Click the message-list headers to sort by starred state, subject, sender, or date; the selected sort order also applies as search pages load.
* The reader lists each message's To and Cc recipients (long lists collapse behind **+N more**) and, on messages in your Sent folder, the Bcc recipients Gmail kept.
* Compose has optional **Cc** and **Bcc** rows (click **Cc/Bcc** next to To) with the same contact suggestions. Bcc addresses are used only to deliver the message and are never written into it; a message can have up to 100 recipients across all three fields.
* Press **Command-P** or click the printer button to print the selected message through the standard macOS print panel (including Save as PDF). The printout has a header with subject, sender, recipients, date, and folder; incomplete bodies are fetched in full first, and remote images print only if you already allowed them.
* Compose now supports basic rich formatting, HTML plus plain-text alternatives, and outgoing file attachments (18 MiB aggregate limit); selected files are read into memory for sending and are not copied into app storage. Each account can have its own optional email signature in Settings; it is inserted into new messages, replies, and forwards and remains editable in the draft. Images can be pasted into the compose body with **Command-V** or the contextual **Paste** command; they are sent inline with a 4 MiB combined limit.
* Reply/forward preparation fetches incomplete source bodies in the background, preserves the sanitized HTML original in a formatted quote, and supplies a bounded plain-text alternative to keep large-message preparation responsive.
* Bundled CID images are sent as inline related MIME parts; remote images remain subject to the reader's opt-in.
* Recipient autocomplete can search a user-selected macOS Contacts list after explicit Contacts permission; contact details are held in memory for the active compose session and are not saved by HackMail.
* Network operations time out (20 s to connect, 30 s without data) and server responses are size-capped, so a stalled or oversized response ends the request with an error instead of hanging.
* Email HTML is parsed and sanitized into a safe subset (no scripts, forms, embedded objects, unsafe links, or remote loads unless you opt in). Messages over 8 MiB, or HTML that cannot be parsed, display as plain text. The parser repairs malformed markup, so a few messages may lay out slightly differently than in other clients.
* There is no Reply All, and recipient addresses must have ASCII domains. Only one message can be printed at a time.
* Automated tests cover SMTP formatting and attachments, IMAP command quoting, and the HTML sanitizer; real-server and cross-client behavior should be verified with your own accounts before relying on it.

* LanguageTool spell/grammar checks are optional and off by default. When enabled, checks run against
the configured HTTPS server (redirects to non-HTTPS are refused; nothing is cached or stored) after a brief pause in typing. Only the editable message body is sent; quoted originals, recipients, and attachments are excluded. Issues appear with temporary red dotted underlines; suggestions are reviewed and applied explicitly from the review panel or by right-clicking an underlined issue, and are not saved by HackMail.
* The native compose editor enables macOS spelling and grammar checks while leaving automatic spelling
correction off.
