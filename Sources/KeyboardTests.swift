import AppKit

// Run in a foreground desktop session with --keyboard-test. Uses demo history,
// restores the pasteboard on exit, and never pastes into an external application.
@MainActor
func runKeyboardTests(controller: Controller) async {
    let panel = controller.panel!
    let store = controller.store
    var checks = 0
    func check(_ value: Bool, _ label: String) {
        guard value else {
            print("FAIL: \(label)")
            let mode = RunLoop.current.currentMode?.rawValue ?? "none"
            print("Focus: active=\(NSApp.isActive), visible=\(panel.isVisible), key=\(panel.isKeyWindow), noKey=\(NSApp.keyWindow == nil), frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier), mode=\(mode)")
            _ = controller.applicationShouldTerminate(NSApp)
            exit(1)
        }
        checks += 1
    }
    // Yield the main actor so queued window-close callbacks can actually run.
    func drain() async { try? await Task.sleep(nanoseconds: 80_000_000) }
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<50 {
            if condition() { return }
            await drain()
        }
    }
    func loseKeyboardFocus() {
        // resignKey() alone is only a notification hook; ordering out updates
        // NSApplication's key-window bookkeeping before showing without focus.
        panel.orderOut(nil)
        panel.orderFront(nil)
    }
    func send(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow? = nil) {
        let destination = window ?? panel
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: destination.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        NSApp.sendEvent(event)
    }
    func sendFlags(_ modifiers: NSEvent.ModifierFlags, to window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers,
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          characters: "", charactersIgnoringModifiers: "",
                                          isARepeat: false, keyCode: 55) else {
            check(false, "AppKit could not create the modifier-release test event")
            return
        }
        NSApp.sendEvent(event)
    }
    func inEventTracking(_ operation: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.eventTracking]) {
            MainActor.assumeIsolated { operation() }
        }
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.08))
    }
    func descendants<T: NSView>(of type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: type, in: $0) }
    }
    // Keep unrelated desktop activity out of this in-process routing test.
    // External dismissal has its own layout test and is verified separately.
    if let observer = controller.activationObserver {
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        controller.activationObserver = nil
    }
    if let monitor = controller.outsideClickMonitor {
        NSEvent.removeMonitor(monitor)
        controller.outsideClickMonitor = nil
    }
    await drain()
    // The activation-policy change made during launch completes asynchronously.
    // Request foreground activation after launch, with external dismissal isolated.
    controller.showShelf()
    for _ in 0..<100 {
        if NSApp.isActive { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    check(NSApp.isActive, "keyboard tests require an active foreground desktop session; OpenPaste did not become active within 10 seconds")
    controller.showShelf()
    check(panel.isKeyWindow, "first shelf opening receives keyboard focus")
    let ids = store.filtered.map(\.id)
    check(ids.count >= 3, "demo history has enough cards")
    let reopenClip = store.filtered[0]
    store.query = reopenClip.source
    store.kind = reopenClip.kind
    store.sourceFilter = reopenClip.source
    store.selected = reopenClip.id
    store.selection = [reopenClip.id]
    store.pasteQueue = [reopenClip.id]
    let reopenPasteGeneration = controller.pasteGeneration
    _ = controller.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
    check(panel.isKeyWindow && store.query == reopenClip.source && store.kind == reopenClip.kind &&
          store.sourceFilter == reopenClip.source && store.selected == reopenClip.id &&
          store.selection == Set([reopenClip.id]) && store.pasteQueue == [reopenClip.id] &&
          controller.pasteGeneration == reopenPasteGeneration,
          "application reopen focuses a visible shelf without resetting its working state")
    store.pasteQueue.removeAll()
    store.resetFilters()
    store.selection.removeAll()
    store.choose(ids[0])
    send(124, "\u{F703}")
    check(store.selected == ids[1], "right arrow selects next card through local monitor")
    send(123, "\u{F702}")
    check(store.selected == ids[0], "left arrow selects previous card")
    send(124, "\u{F703}", modifiers: .shift)
    check(store.selection.contains(ids[0]) && store.selection.contains(ids[1]), "shift arrow extends selection")

    loseKeyboardFocus()
    check(NSApp.keyWindow == nil && panel.isVisible, "reproduce visible shelf without key window")
    controller.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
    check(panel.isKeyWindow, "activation callback recovers key window")
    store.choose(ids[0])
    loseKeyboardFocus()
    send(124, "\u{F703}")
    check(panel.isKeyWindow && store.selected == ids[1], "first arrow recovers already-active orphaned shelf")

    controller.showPreview(store.filtered[0])
    let preview = controller.previewWindow!
    controller.restoreShelfKeyboardFocus()
    check(preview.isKeyWindow, "recovery preserves preview focus")
    preview.close()
    loseKeyboardFocus()
    await drain()
    check(panel.isKeyWindow, "closing preview restores shelf focus")
    controller.edit(store.filtered[0])
    let editor = controller.editorWindow!
    controller.restoreShelfKeyboardFocus()
    check(editor.isKeyWindow, "recovery preserves editor focus")
    editor.close()
    loseKeyboardFocus()
    await drain()
    check(panel.isKeyWindow, "closing editor restores shelf focus")

    controller.modalShowing = true
    loseKeyboardFocus()
    controller.restoreShelfKeyboardFocus()
    check(NSApp.keyWindow == nil, "recovery does not steal modal focus")
    controller.modalShowing = false
    controller.restoreShelfKeyboardFocus()
    store.choose(ids[0])
    loseKeyboardFocus()
    var checkedTracking = false
    func checkMenuTracking() {
        let verify: @MainActor @Sendable () -> Void = {
            controller.restoreShelfKeyboardFocus()
            send(124, "\u{F703}")
            check(NSApp.keyWindow == nil && store.selected == ids[0], "menu tracking keeps arrows and keyboard focus")
            checkedTracking = true
        }
        inEventTracking(verify)
    }
    checkMenuTracking()
    check(checkedTracking, "menu tracking regression exercised")
    controller.restoreShelfKeyboardFocus()
    store.reverseHistory = true
    var checkedModifierRelease = false
    inEventTracking {
        sendFlags([], to: panel)
        check(!store.reverseHistory, "modifier release clears reverse history during menu tracking")
        checkedModifierRelease = true
    }
    check(checkedModifierRelease, "menu-tracking modifier release regression exercised")
    controller.restoreShelfKeyboardFocus()
    let other = controller.auxiliaryWindow("Keyboard focus fixture", size: NSSize(width: 200, height: 100))
    other.makeKeyAndOrderFront(nil)
    controller.restoreShelfKeyboardFocus()
    check(other.isKeyWindow, "recovery does not steal another window's focus")
    other.close()
    controller.restoreShelfKeyboardFocus()

    send(3, "f", modifiers: .command)
    await drain()
    check(store.searchFocused && panel.firstResponder is NSTextView, "search receives text focus")
    let selected = store.selected
    send(123, "\u{F702}")
    check(store.selected == selected, "left arrow in search does not move card selection")
    send(125, "\u{F701}")
    await drain()
    check(!store.searchFocused && !(panel.firstResponder is NSTextView), "down arrow returns from search to cards")

    let selectedClip = store.filtered[0]
    let previewClip = store.filtered[2]
    store.choose(selectedClip.id)
    controller.showPreview(previewClip)
    guard let targetedPreview = controller.previewWindow else {
        check(false, "showPreview creates a preview window")
        return
    }
    check(targetedPreview.isKeyWindow && controller.previewClipID == previewClip.id && controller.previewClip?.id == previewClip.id,
          "showPreview records and focuses its explicit clip")

    send(15, "r", modifiers: .command, to: targetedPreview)
    await waitUntil { targetedPreview.attachedSheet != nil }
    let renameSheet = targetedPreview.attachedSheet
    let renameField = descendants(of: NSTextField.self, in: renameSheet?.contentView).first { $0.isEditable }
    check(renameSheet != nil && renameField?.stringValue == previewClip.title,
          "preview Command-R renames the previewed clip instead of the shelf selection")
    let cancelRename = descendants(of: NSButton.self, in: renameSheet?.contentView).first { $0.title == "取消" }
    cancelRename?.performClick(nil)
    await waitUntil { targetedPreview.attachedSheet == nil && targetedPreview.isKeyWindow }
    check(targetedPreview.attachedSheet == nil && targetedPreview.isKeyWindow, "canceling preview rename restores preview focus")

    send(31, "o", modifiers: .command, to: targetedPreview)
    await drain()
    guard let reopenedPreview = controller.previewWindow else {
        check(false, "preview Command-O keeps a preview window")
        return
    }
    check(reopenedPreview.isKeyWindow && controller.previewClipID == previewClip.id && controller.previewClip?.id == previewClip.id,
          "preview Command-O opens the previewed clip instead of the shelf selection")

    send(14, "e", modifiers: .command, to: reopenedPreview)
    guard let targetedEditorWindow = controller.editorWindow,
          let targetedEditor = targetedEditorWindow.contentViewController as? NativeEditor else {
        check(false, "preview Command-E creates a native editor")
        return
    }
    check(targetedEditorWindow.isKeyWindow && targetedEditor.clip.id == previewClip.id,
          "preview Command-E edits the previewed clip instead of the shelf selection")
    let draft = "unsaved keyboard regression draft"
    targetedEditor.text.string = draft
    let entrypoints: [(String, () -> Void)] = [
        ("show", { controller.show() }),
        ("toggle", { controller.toggle() }),
        ("showShelf", { controller.showShelf() }),
        ("applicationShouldHandleReopen", { _ = controller.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) })
    ]
    for (name, invoke) in entrypoints {
        reopenedPreview.makeKeyAndOrderFront(nil)
        invoke()
        check(controller.editorWindow === targetedEditorWindow && targetedEditorWindow.isKeyWindow &&
              targetedEditor.text.string == draft && !panel.isKeyWindow,
              "\(name) focuses the visible editor without discarding its draft")
    }
    targetedEditorWindow.close()
    await drain()
    for (name, invoke) in entrypoints {
        panel.makeKeyAndOrderFront(nil)
        invoke()
        check(reopenedPreview.isKeyWindow && controller.previewClipID == previewClip.id &&
              controller.previewClip?.id == previewClip.id && !panel.isKeyWindow,
              "\(name) focuses the visible preview when no editor is open")
    }
    reopenedPreview.close()
    await drain()
    check(controller.previewClipID == nil && controller.previewClip == nil,
          "closing preview clears the tracked preview identity")

    var editorSaveSucceeds = false
    var editorCloseCount = 0
    let saveFixture = NativeEditor(clip: previewClip, save: { _ in editorSaveSucceeds }, close: { editorCloseCount += 1 })
    _ = saveFixture.view
    saveFixture.commit()
    check(editorCloseCount == 0, "native editor remains open when saving fails")
    editorSaveSucceeds = true
    saveFixture.commit()
    check(editorCloseCount == 1, "native editor closes after a successful save")

    for code: UInt16 in [36, 76] {
        controller.showShelf()
        store.choose(ids[1])
        let expected = store.selectedClips[0].text
        controller.target = nil
        controller.lastExternalApp = nil
        loseKeyboardFocus()
        send(code, code == 36 ? "\r" : "\u{3}")
        check(!panel.isVisible, "return \(code) recovers focus and takes selected card")
        check(NSPasteboard.general.string(forType: .string) == expected, "return \(code) copies selected content")
        controller.restoreShelfKeyboardFocus()
        check(!panel.isVisible, "recovery does not reopen a hidden shelf")
    }
    controller.openSettings()
    await drain()
    controller.restoreShelfKeyboardFocus()
    check(controller.settingsWindow?.isKeyWindow == true && !panel.isVisible, "settings keeps keyboard focus")
    guard let settings = controller.settingsWindow else {
        check(false, "settings window exists for attached-sheet regression")
        return
    }
    let picker = NSOpenPanel()
    picker.title = "Keyboard sheet fixture"
    picker.beginSheetModal(for: settings) { _ in }
    await waitUntil { settings.attachedSheet != nil }
    guard let attachedPicker = settings.attachedSheet else {
        check(false, "NSOpenPanel attaches to settings")
        return
    }
    for (name, invoke) in entrypoints {
        invoke()
        check(settings.isVisible && store.settings && settings.attachedSheet === attachedPicker &&
              attachedPicker.isVisible && !panel.isVisible,
              "\(name) preserves settings and its NSOpenPanel sheet")
    }
    picker.cancel(nil)
    await waitUntil { settings.attachedSheet == nil }
    check(settings.attachedSheet == nil && settings.isVisible && store.settings,
          "canceling the file sheet preserves settings")
    _ = controller.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
    check(settings.isKeyWindow && settings.isVisible && store.settings && !panel.isVisible,
          "application reopen preserves and focuses settings")
    func logFinalFocus(_ stage: String) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        let key = NSApp.keyWindow.map { $0 === panel ? "shelf" : ($0 === settings ? "settings" : ($0.title.isEmpty ? "untitled" : $0.title)) } ?? "none"
        print("Keyboard final focus \(stage): active=\(NSApp.isActive), frontmost=\(frontmost), key=\(key)")
    }
    logFinalFocus("before closeSettings")
    controller.closeSettings()
    logFinalFocus("after closeSettings")
    controller.showShelf()
    logFinalFocus("after showShelf")
    await drain()
    logFinalFocus("after drain")
    check(panel.isKeyWindow, "shelf regains keyboard focus after settings")
    print("PASS: \(checks) keyboard focus and event routing checks")
    NSApp.terminate(nil)
}
