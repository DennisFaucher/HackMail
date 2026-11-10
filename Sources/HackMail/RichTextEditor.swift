import AppKit
import SwiftUI

struct RichTextEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    @ObservedObject var controller: RichTextEditorController
    let onTextChange: (String) -> Void

    init(
        text: Binding<NSAttributedString>,
        controller: RichTextEditorController,
        onTextChange: @escaping (String) -> Void = { _ in }
    ) {
        self._text = text
        self.controller = controller
        self.onTextChange = onTextChange
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, controller: controller, onTextChange: onTextChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.importsGraphics = true
        textView.usesFontPanel = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 8)
        let font = NSFont(name: "AtkinsonHyperlegible-Regular", size: 14) ?? NSFont.systemFont(ofSize: 14)
        textView.font = font
        textView.textColor = NSColor(Paper.ink)
        textView.typingAttributes[.font] = font
        textView.typingAttributes[.foregroundColor] = NSColor(Paper.ink)
        textView.textStorage?.setAttributedString(text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        controller.textView = textView
        controller.updateSelectionState()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.controller = controller
        context.coordinator.onTextChange = onTextChange
        controller.textView = textView
        if !textView.attributedString().isEqual(to: text) {
            let selection = textView.selectedRange()
            context.coordinator.isApplyingBinding = true
            textView.textStorage?.setAttributedString(text)
            let safeLocation = min(selection.location, textView.string.utf16.count)
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
            context.coordinator.isApplyingBinding = false
            controller.clearLanguageToolHighlights()
        }
        controller.updateSelectionState()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<NSAttributedString>
        var controller: RichTextEditorController
        var onTextChange: (String) -> Void
        var isApplyingBinding = false

        init(text: Binding<NSAttributedString>, controller: RichTextEditorController, onTextChange: @escaping (String) -> Void) {
            self.text = text
            self.controller = controller
            self.onTextChange = onTextChange
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingBinding, let textView = notification.object as? NSTextView else { return }
            let updatedText = textView.attributedString()
            if !updatedText.isEqual(to: text.wrappedValue) {
                text.wrappedValue = updatedText
            }
            controller.clearLanguageToolHighlights()
            onTextChange(updatedText.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.updateSelectionState()
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard let match = controller.languageToolMatch(at: charIndex), !match.replacements.isEmpty else {
                return menu
            }
            if menu.items.isEmpty == false { menu.addItem(.separator()) }
            let heading = NSMenuItem(title: "LanguageTool suggestions", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for (index, replacement) in match.replacements.prefix(8).enumerated() {
                let item = NSMenuItem(title: replacement.value, action: #selector(applyLanguageToolSuggestion(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
            contextMenuReplacements = Array(match.replacements.prefix(8)).map {
                (range: NSRange(location: match.offset, length: match.length), value: $0.value)
            }
            return menu
        }

        private var contextMenuReplacements: [(range: NSRange, value: String)] = []

        @objc private func applyLanguageToolSuggestion(_ sender: NSMenuItem) {
            guard contextMenuReplacements.indices.contains(sender.tag) else { return }
            let suggestion = contextMenuReplacements[sender.tag]
            controller.applyReplacement(suggestion.value, range: suggestion.range)
            contextMenuReplacements = []
        }
    }
}

@MainActor
final class RichTextEditorController: ObservableObject {
    weak var textView: NSTextView?
    @Published private(set) var hasSelection = false
    private var languageToolMatches: [LanguageToolMatch] = []

    func toggleBold() { toggleFontTrait(.boldFontMask) }
    func toggleItalic() { toggleFontTrait(.italicFontMask) }
    func toggleUnderline() { textView?.underline(nil) }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView else { return }
        let manager = NSFontManager.shared
        let range = textView.selectedRange()
        if range.length == 0 {
            let current = textView.typingAttributes[.font] as? NSFont ?? textView.font ?? NSFont.systemFont(ofSize: 14)
            let hasTrait = manager.traits(of: current).contains(trait)
            textView.typingAttributes[.font] = hasTrait
                ? manager.convert(current, toNotHaveTrait: trait)
                : manager.convert(current, toHaveTrait: trait)
            return
        }

        guard let storage = textView.textStorage else { return }
        var updates: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let current = value as? NSFont ?? textView.font ?? NSFont.systemFont(ofSize: 14)
            let hasTrait = manager.traits(of: current).contains(trait)
            let updated = hasTrait
                ? manager.convert(current, toNotHaveTrait: trait)
                : manager.convert(current, toHaveTrait: trait)
            updates.append((subrange, updated))
        }
        storage.beginEditing()
        for (subrange, font) in updates { storage.addAttribute(.font, value: font, range: subrange) }
        storage.endEditing()
        textView.didChangeText()
    }

    func toggleBullets() {
        guard let textView else { return }
        let source = textView.string as NSString
        let selectedRange = textView.selectedRange()
        let paragraphRange = source.paragraphRange(for: selectedRange)
        let selectedText = source.substring(with: paragraphRange)
        let lines = selectedText.components(separatedBy: .newlines)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let shouldRemoveBullets = !nonEmptyLines.isEmpty && nonEmptyLines.allSatisfy { $0.hasPrefix("• ") }
        let formatted = lines.map { line in
            guard !line.isEmpty else { return line }
            if shouldRemoveBullets, line.hasPrefix("• ") { return String(line.dropFirst(2)) }
            return shouldRemoveBullets ? line : "• " + line
        }.joined(separator: "\n")
        textView.insertText(formatted, replacementRange: paragraphRange)
        updateSelectionState()
    }

    func toggleNumberedList() {
        guard let textView else { return }
        let source = textView.string as NSString
        let paragraphRange = source.paragraphRange(for: textView.selectedRange())
        let selectedText = source.substring(with: paragraphRange)
        let lines = selectedText.components(separatedBy: .newlines)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let numberPattern = #"^\d+\.\s"#
        let shouldRemoveNumbers = !nonEmptyLines.isEmpty && nonEmptyLines.allSatisfy {
            $0.range(of: numberPattern, options: .regularExpression) != nil
        }
        var number = 1
        let formatted = lines.map { line -> String in
            guard !line.isEmpty else { return line }
            if shouldRemoveNumbers {
                return line.replacingOccurrences(of: numberPattern, with: "", options: .regularExpression)
            }
            defer { number += 1 }
            return "\(number). \(line)"
        }.joined(separator: "\n")
        textView.insertText(formatted, replacementRange: paragraphRange)
        updateSelectionState()
    }

    func applyLink(_ url: URL) {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        textView.textStorage?.addAttribute(.link, value: url, range: range)
        textView.textStorage?.addAttribute(.foregroundColor, value: NSColor(Paper.accent), range: range)
        textView.textStorage?.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        textView.didChangeText()
    }

    func applyReplacement(_ replacement: String, range: NSRange) {
        guard let textView, range.location != NSNotFound,
              NSMaxRange(range) <= (textView.string as NSString).length else { return }
        textView.insertText(replacement, replacementRange: range)
        updateSelectionState()
    }

    func clearLanguageToolHighlights() {
        languageToolMatches = []
        removeLanguageToolTemporaryAttributes()
    }

    private func removeLanguageToolTemporaryAttributes() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        guard length > 0 else { return }
        let range = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
    }

    func applyLanguageToolHighlights(_ matches: [LanguageToolMatch]) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        languageToolMatches = matches
        removeLanguageToolTemporaryAttributes()
        let length = (textView.string as NSString).length
        let style = NSNumber(value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue)
        for match in matches where match.length > 0 && match.offset >= 0 && match.offset + match.length <= length {
            let range = NSRange(location: match.offset, length: match.length)
            layoutManager.addTemporaryAttribute(.underlineStyle, value: style, forCharacterRange: range)
            layoutManager.addTemporaryAttribute(.underlineColor, value: NSColor.systemRed, forCharacterRange: range)
        }
    }

    func languageToolMatch(at characterIndex: Int) -> LanguageToolMatch? {
        languageToolMatches.first { match in
            match.offset <= characterIndex && characterIndex < match.offset + match.length
        }
    }

    func updateSelectionState() {
        let updatedValue = (textView?.selectedRange().length ?? 0) > 0
        if hasSelection != updatedValue { hasSelection = updatedValue }
    }
}
