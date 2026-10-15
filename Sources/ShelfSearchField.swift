import AppKit
import SwiftUI

private final class ShelfSearchEditor: NSTextView {
    var textStateChanged: (() -> Void)?
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        // AppKit can begin marked text without controlTextDidChange. Observe
        // the actual editor state so pending actions are blocked immediately.
        textStateChanged?()
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        textStateChanged?()
    }
    override func unmarkText() {
        super.unmarkText()
        textStateChanged?()
    }
    override func keyDown(with event: NSEvent) {
        // Unlike search.input (sent after editing), this includes AppKit input
        // handling. It remains a main-thread metric, not screen-paint latency.
        let finish = AcceptanceMetrics.begin("search.key")
        defer { finish() }
        super.keyDown(with: event)
    }
}

/// Search input has its own field editor: linguistic suggestions and automatic
/// replacements are neither useful for exact queries nor free on first input.
/// Keeping this editor separate also preserves settings on rename/edit fields.
final class ShelfSearchFieldCell: NSTextFieldCell {
    var textStateChanged: (() -> Void)?
    private lazy var searchEditor: NSTextView = {
        let editor = ShelfSearchEditor()
        editor.isFieldEditor = true
        editor.textStateChanged = { [weak self] in self?.textStateChanged?() }
        return editor
    }()
    override func fieldEditor(for controlView: NSView) -> NSTextView? { searchEditor }
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        if let editor = editor as? NSTextView {
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
        }
        return editor
    }
}

/// NSTextField owns the draft, so marked text never invalidates the card hierarchy.
struct CommittedSearchField: NSViewRepresentable {
    let store: Store
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let store: Store
        weak var field: NSTextField?
        var compositionCheck: DispatchWorkItem?
        var focusRequested = false
        var resetting = false
        var resetGeneration: Int
        var lastPublishedText: String?
        var lastPublishedComposition = false
        init(store: Store) { self.store = store; resetGeneration = store.searchInputResetGeneration }
        func controlTextDidBeginEditing(_ notification: Notification) { store.searchFocused = true }
        func controlTextDidChange(_ notification: Notification) { publish() }
        func controlTextDidEndEditing(_ notification: Notification) {
            compositionCheck?.cancel()
            if store.searchFocused { publish() }
            if store.searchFocused { store.searchFocused = false }
        }
        func publish() {
            guard let field, !resetting else { return }
            compositionCheck?.cancel()
            guard resetGeneration == store.searchInputResetGeneration else { return }
            let editor = field.currentEditor() as? NSTextView
            let composing = editor?.hasMarkedText() == true
            let value = editor?.string ?? field.stringValue
            if value != lastPublishedText || composing != lastPublishedComposition {
                lastPublishedText = value; lastPublishedComposition = composing
                let finish = AcceptanceMetrics.begin("search.input")
                store.setSearchInput(value, isComposing: composing)
                finish()
            }
            // Some IMEs only unmark an unchanged candidate on confirmation, without a
            // second text-change notification. Observe that transition as well.
            if composing {
                let work = DispatchWorkItem { [weak self] in self?.publish() }
                compositionCheck = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> NSTextField {
        Self.makeField(coordinator: context.coordinator)
    }
    static func makeField(coordinator: Coordinator) -> NSTextField {
        let store = coordinator.store
        let field = NSTextField(string: store.query)
        let cell = ShelfSearchFieldCell(textCell: store.query)
        cell.textStateChanged = { [weak coordinator] in coordinator?.publish() }
        field.cell = cell
        field.isEditable = true; field.isSelectable = true
        field.isAutomaticTextCompletionEnabled = false
        field.placeholderString = "搜索文字、链接或来源"
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none; field.font = .systemFont(ofSize: 13)
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityIdentifier("shelf-search")
        field.delegate = coordinator; coordinator.field = field
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        let editor = field.currentEditor() as? NSTextView
        if coordinator.resetGeneration != store.searchInputResetGeneration {
            coordinator.resetting = true
            coordinator.compositionCheck?.cancel()
            editor?.unmarkText()
            editor?.string = store.query
            field.stringValue = store.query
            coordinator.lastPublishedText = store.query
            coordinator.lastPublishedComposition = false
            coordinator.resetGeneration = store.searchInputResetGeneration
            coordinator.resetting = false
        }
        if editor?.hasMarkedText() != true, field.stringValue != store.query {
            field.stringValue = store.query
            coordinator.lastPublishedText = store.query
        }
        guard store.searchFocused, editor == nil, !coordinator.focusRequested else { return }
        coordinator.focusRequested = true
        DispatchQueue.main.async { [weak field, weak coordinator] in
            guard let field, let coordinator else { return }
            coordinator.focusRequested = false
            if coordinator.store.searchFocused { field.window?.makeFirstResponder(field) }
        }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.compositionCheck?.cancel(); coordinator.field = nil
        field.delegate = nil
    }
}

struct ShelfSearchBar: View {
    @ObservedObject var store: Store
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(store.searchFocused ? Color.blue : Color.secondary)
            CommittedSearchField(store: store).frame(width: 250, height: 18)
            if !store.query.isEmpty || store.searchInputIsComposing {
                Button {
                    store.cancelSearchInput(); store.setSearchInput("", isComposing: false); store.searchFocused = true
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("清空搜索")
            } else { Text("⌘F").font(.system(size: 10)).foregroundStyle(.tertiary) }
            Button {
                store.cancelSearchInput(); store.resetFilters(preserveBoard: true, preserveDateRange: true)
                store.searchExpanded = false; store.searchFocused = false
                Controller.shared.panel.makeFirstResponder(Controller.shared.panel.contentView)
            } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("退出搜索 · Esc")
        }.padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(store.searchFocused ? Color.blue.opacity(0.65) : Color.primary.opacity(0.1)))
    }
}
