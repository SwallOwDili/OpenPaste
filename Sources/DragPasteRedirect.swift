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
enum DragPasteRedirect {
    /// Apps that make link cards only from a paste.
    static let pasteOnlyApps: Set<String> = ["com.apple.MobileSMS"]
    /// Set by the controller: pastes the clip into the app with the same flow as Return. Called on the main thread.
    static var paste: ((Clip, pid_t) -> Void)?
    /// How long a drag may be held before the watch gives up.
    static let holdLimit: TimeInterval = 600
    /// How long to wait after the release for Messages to insert the dropped text.
    static let insertWait: TimeInterval = 1

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
        var fieldValue: (pid_t) -> String? = { InputField.value(of: $0) }
        var select: (pid_t, NSRange) -> Bool = { InputField.select($1, in: $0) }
        var paste: (Clip, pid_t) -> Void = { DragPasteRedirect.paste?($0, $1) }
        var poll: TimeInterval = 0.03
    }

    /// Called on the main thread when a card drag begins.
    static func begin(_ clip: Clip, environment: Environment = Environment()) {
        guard clip.kind == "链接" else { return }
        var before: [pid_t: String] = [:]
        for pid in environment.runningPasteOnlyApps() { before[pid] = environment.fieldValue(pid) }
        watch(clip, before: before, deadline: Date().addingTimeInterval(holdLimit), cancelled: false, environment: environment)
    }

    private static func watch(_ clip: Clip, before: [pid_t: String], deadline: Date, cancelled: Bool, environment: Environment) {
        guard Date() < deadline else { return }
        let cancelled = cancelled || environment.isEscapeDown()
        guard !environment.isButtonDown() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + environment.poll) {
                watch(clip, before: before, deadline: deadline, cancelled: cancelled, environment: environment)
            }
            return
        }
        guard !cancelled, let app = environment.pasteOnlyAppUnderPointer() else { return }
        replaceDroppedText(clip, in: app, before: before[app], until: Date().addingTimeInterval(insertWait), environment: environment)
    }

    /// Waits for the drop to land in the field, selects the URL it inserted, then pastes the card over it (or at the cursor).
    private static func replaceDroppedText(_ clip: Clip, in app: pid_t, before: String?, until: Date, environment: Environment) {
        if let before, let after = environment.fieldValue(app), let range = insertedURL(before: before, after: after, url: clip.text) {
            _ = environment.select(app, range)
            environment.paste(clip, app)
            return
        }
        guard Date() < until else { environment.paste(clip, app); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + environment.poll) {
            replaceDroppedText(clip, in: app, before: before, until: until, environment: environment)
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

    /// The focused text input of an app, through accessibility (OpenPaste already holds that permission for pasting).
    enum InputField {
        private static func element(of pid: pid_t) -> AXUIElement? {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success, let focused = value else { return nil }
            let element = focused as! AXUIElement
            var role: AnyObject?, subrole: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            guard ["AXTextField", "AXTextArea"].contains(role as? String ?? ""), (subrole as? String) != "AXSearchField" else { return nil }
            return element
        }
        static func value(of pid: pid_t) -> String? {
            guard let element = element(of: pid) else { return nil }
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            return value as? String ?? ""
        }
        static func select(_ range: NSRange, in pid: pid_t) -> Bool {
            guard let element = element(of: pid) else { return false }
            var cf = CFRange(location: range.location, length: range.length)
            guard let value = AXValueCreate(.cfRange, &cf) else { return false }
            return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
        }
    }
}
