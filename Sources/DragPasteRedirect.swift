import AppKit
import ApplicationServices

/// Link cards dropped on Messages end up as a link card, as when pasted.
///
/// Messages turns a lone URL into a link card only when it is pasted; a drop always inserts the bare text (its text-field
/// drop handler only proposes an insert, and its conversation-area drop accepts nothing from other apps). The drag itself
/// is left alone: its data goes to whoever asks, so every other drop target behaves as before. When a link card's drag is
/// released over Messages, the URL text Messages inserted is found by comparing its input field before and after the drop,
/// selected, and replaced by pasting the card with the same flow as Return; if nothing was inserted (a drop on the
/// conversation area), the card is pasted at the cursor. A drag cancelled with Escape, or released anywhere else, is not
/// touched.
///
/// The paste is sent only when the outcome is certain; otherwise the bare URL Messages inserted stays as it is. That needs
/// the message body field (not the recipient field) focused at the start, and the same one at the release; when replacing, the selection read back must be exactly
/// the inserted URL; when pasting at the cursor, the field must be unchanged after the wait and have no selection (a ⌘V
/// would replace it). Both are checked again right before ⌘V, once Messages is in front, and the caret is put back where it
/// was. So a drop never leaves both the URL text and a card, and never overwrites selected draft text.
enum DragPasteRedirect {
    /// Apps that make link cards only from a paste.
    static let pasteOnlyApps: Set<String> = ["com.apple.MobileSMS"]
    /// Set by the controller: pastes the clip into the app with the same flow as Return. Called on the main thread. The
    /// last argument is called once the app is in front, right before ⌘V: it checks the field again (and puts the caret
    /// back where it was) and returns false to send nothing.
    static var paste: ((Clip, pid_t, @escaping () -> Bool) -> Void)?
    /// How long a drag may be held before the watch gives up.
    static let holdLimit: TimeInterval = 600
    /// How long to wait after the release for Messages to insert the dropped text.
    static let insertWait: TimeInterval = 1

    /// An app's focused text input: which element it is, its text and its selection (UTF-16, as accessibility uses).
    struct Field {
        let element: AnyObject
        let value: String
        let selection: NSRange
        func isSameInput(as other: Field) -> Bool { CFEqual(element as CFTypeRef, other.element as CFTypeRef) }
    }

    /// What the watch needs from the system; replaceable for tests.
    struct Environment {
        var isButtonDown: () -> Bool = { CGEventSource.buttonState(.combinedSessionState, button: .left) }
        var isEscapeDown: () -> Bool = { CGEventSource.keyState(.combinedSessionState, key: 53) }
        /// The paste-only app the pointer is over now (nil over OpenPaste, other apps or the desktop).
        var pasteOnlyAppUnderPointer: () -> pid_t? = {
            releaseApp(at: CGEvent(source: nil)?.location ?? .zero, ownPID: ProcessInfo.processInfo.processIdentifier, windows: onScreenWindows())
                .flatMap { pid in NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(DragPasteRedirect.pasteOnlyApps.contains) == true ? pid : nil }
        }
        /// Running paste-only apps, to note their input fields when the drag begins.
        var runningPasteOnlyApps: () -> [pid_t] = { NSWorkspace.shared.runningApplications.filter { DragPasteRedirect.pasteOnlyApps.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier) }
        var field: (pid_t) -> Field? = { InputField.focused(in: $0) }
        /// Selects the range in that very input; true when accessibility accepted it.
        var select: (Field, NSRange) -> Bool = { InputField.select($1, in: $0) }
        var paste: (Clip, pid_t, @escaping () -> Bool) -> Void = { DragPasteRedirect.paste?($0, $1, $2) }
        /// Why a drop over Messages was left alone (a fixed reason code, for the local diagnostics log).
        var skipped: (String) -> Void = { AppDiagnostics.record("drag.redirect-skipped", ["reason": $0]) }
        /// A step of the check right before ⌘V (a fixed code, for the local diagnostics log).
        var note: (String) -> Void = { AppDiagnostics.record("drag.redirect-presend", ["step": $0]) }
        var poll: TimeInterval = 0.03
    }

    /// Called on the main thread when a card drag begins.
    static func begin(_ clip: Clip, environment: Environment = Environment()) {
        guard clip.kind == "链接" else { return }
        var before: [pid_t: Field] = [:]
        for pid in environment.runningPasteOnlyApps() { before[pid] = environment.field(pid) }
        watch(clip, before: before, deadline: Date().addingTimeInterval(holdLimit), cancelled: false, environment: environment)
    }

    private static func watch(_ clip: Clip, before: [pid_t: Field], deadline: Date, cancelled: Bool, environment: Environment) {
        guard Date() < deadline else { return }
        let cancelled = cancelled || environment.isEscapeDown()
        guard !environment.isButtonDown() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + environment.poll) {
                watch(clip, before: before, deadline: deadline, cancelled: cancelled, environment: environment)
            }
            return
        }
        // Without the field as it was at the start there is nothing to compare: the drop is left as Messages made it.
        guard !cancelled, let app = environment.pasteOnlyAppUnderPointer() else { return }
        guard let field = before[app] else { environment.skipped("field-not-noted"); return }
        replaceDroppedText(clip, in: app, before: field, until: Date().addingTimeInterval(insertWait), environment: environment)
    }

    /// Waits for the drop to land in the field, selects the URL it inserted, then pastes the card over it; or, when the
    /// field stayed untouched, at the cursor. Anything uncertain leaves the field as it is.
    private static func replaceDroppedText(_ clip: Clip, in app: pid_t, before: Field, until: Date, environment: Environment) {
        let now = environment.field(app).flatMap { $0.isSameInput(as: before) ? $0 : nil }
        if let now, let range = insertedURL(before: before.value, after: now.value, url: clip.text) {
            guard environment.select(now, range) else { environment.skipped("select-failed"); return }
            guard let check = environment.field(app), check.isSameInput(as: before), check.selection == range else { environment.skipped("selection-mismatch"); return }
            // Right before ⌘V: still the same input, same text, the URL still selected.
            environment.paste(clip, app) {
                guard let last = environment.field(app), last.isSameInput(as: before), last.value == now.value else { environment.note("changed"); return false }
                if last.selection == range { environment.note("selection-kept"); return true }
                environment.note("reselect-from-\(last.selection.location)-\(last.selection.length)")
                return environment.select(last, range) && environment.field(app)?.selection == range
            }
            return
        }
        guard Date() >= until else {
            DispatchQueue.main.asyncAfter(deadline: .now() + environment.poll) {
                replaceDroppedText(clip, in: app, before: before, until: until, environment: environment)
            }
            return
        }
        guard let now else { environment.skipped("field-unreadable"); return }
        guard now.value == before.value else { environment.skipped("field-changed"); return }
        // Text selected at the start counts even if the selection collapsed since (showing the shelf can do that).
        guard before.selection.length == 0, now.selection.length == 0 else { environment.skipped("text-selected"); return }
        // Right before ⌘V: still the same input and text, nothing selected meanwhile; activating Messages moves the
        // caret, so it is put back where it was when the drag began.
        environment.paste(clip, app) {
            guard let last = environment.field(app), last.isSameInput(as: before), last.value == before.value else { return false }
            let caret = NSRange(location: before.selection.location, length: 0)
            if last.selection == caret { return true }
            guard last.selection.length == 0,
                  environment.select(last, caret), environment.field(app)?.selection == caret else { return false }
            return true
        }
    }

    /// The range (UTF-16, as accessibility uses) of `url` in the text a drop inserted, found by trimming what `before`
    /// and `after` share at both ends. Nil when nothing was inserted or the insertion is not that URL.
    static func insertedURL(before: String, after: String, url: String) -> NSRange? {
        let old = before as NSString, new = after as NSString
        guard new.length > old.length else { return nil }
        var prefix = 0
        while prefix < old.length && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < old.length - prefix && old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let inserted = NSRange(location: prefix, length: new.length - prefix - suffix)
        let target = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let found = (new.substring(with: inserted) as NSString).range(of: target)
        guard found.location != NSNotFound else { return nil }
        return NSRange(location: inserted.location + found.location, length: found.length)
    }

    /// The app the pointer is over: the first ordinary window under the point, skipping the drag image and other
    /// overlays. Nil over OpenPaste itself (a board, the strip) and where no app window is (the desktop).
    static func releaseApp(at point: CGPoint, ownPID: pid_t, windows: [[String: Any]]) -> pid_t? {
        let dragLevel = Int(CGWindowLevelForKey(.draggingWindow))
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(point) else { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            if layer >= dragLevel { continue }
            if pid_t(pid) == ownPID { return nil }
            guard layer == 0 else { continue }
            return pid_t(pid)
        }
        return nil
    }

    static func onScreenWindows() -> [[String: Any]] { (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? [] }

    /// Messages' message body input (the recipient field and search are other inputs), named the same in every language.
    static let messageBodyIdentifier = "messageBodyField"

    /// The focused message body input of an app, through accessibility (OpenPaste already holds that permission for pasting).
    enum InputField {
        static func focused(in pid: pid_t) -> Field? {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success, let focused = value,
                  CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            let element = focused as! AXUIElement
            // The timeout set on the application element does not carry over to its children: these calls run on the
            // main thread, so a busy Messages must not hold it for the default several seconds.
            AXUIElementSetMessagingTimeout(element, 0.25)
            var identifier: AnyObject?, text: AnyObject?, selected: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier)
            guard (identifier as? String) == messageBodyIdentifier else { return nil }
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success, let selected,
                  CFGetTypeID(selected) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            guard AXValueGetValue(selected as! AXValue, .cfRange, &range) else { return nil }
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &text)
            return Field(element: element, value: text as? String ?? "", selection: NSRange(location: range.location, length: range.length))
        }
        static func select(_ range: NSRange, in field: Field) -> Bool {
            guard CFGetTypeID(field.element as CFTypeRef) == AXUIElementGetTypeID() else { return false }
            var cf = CFRange(location: range.location, length: range.length)
            guard let value = AXValueCreate(.cfRange, &cf) else { return false }
            return AXUIElementSetAttributeValue(field.element as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, value) == .success
        }
    }
}
