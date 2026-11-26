import SwiftUI
import AppKit
import Combine
import Carbon
import ApplicationServices

/// Non-activating, so the shelf can take the keyboard even when the system refuses to activate the app
/// (secure event input while a password field is focused).
final class ShelfPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }
final class ShelfHost: NSHostingView<ShelfView> { override var acceptsFirstResponder: Bool { true } }
final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    static var shared: Controller!
    let preview = TestMode.translationWorkflow || TestMode.translationUI || TestMode.featureUI || TestMode.preview || TestMode.layout || TestMode.shortcut || TestMode.ui || TestMode.keyboard
    lazy var store = Store(ephemeral: preview, loadHistoryAsynchronously: !preview && !TestMode.active)
    var panel: ShelfPanel!
    var status: NSStatusItem!
    var updateMenuItem: NSMenuItem?
    var target: NSRunningApplication?
    var hotkey: EventHotKeyRef?
    var shortcut = GlobalShortcut.load()
    var handler: EventHandlerRef?
    var keyMonitor: Any?
    var outsideClickMonitor: Any?
    var wheelMonitor: Any?
    /// Position of the shelf's card strip (focus, magnification, pan). Shared with the preview popover's anchor.
    let stripDriver = FocusDriver()
    var shelfAwaitingActivation = false
    var pendingSearchKeys: [NSEvent] = []
    var pendingSearchAttempts = 0
    var menuObservers: [NSObjectProtocol] = []
    var trackingMenus = Set<ObjectIdentifier>()
    var menuTransition = 0
    var menuFinishing = false
    var pendingOutsideClick = false
    var pendingApplicationSwitch = false
    var shelfPresentation = 0
    /// The preview is a system popover anchored to the selected card.
    var previewPopover: NSPopover?
    var previewHost: NSHostingController<FullItemPreview>?
    var previewSelectionObserver: AnyCancellable?
    var previewWindow: NSWindow? { previewPopover?.isShown == true ? previewHost?.view.window : nil }
    var previewClipID: UUID?
    var previewClip: Clip? { store.archive.clips.first { $0.id == previewClipID } }
    var editorWindow: NSWindow?
    var pendingShelfPresentation: (() -> Void)?
    var pauseTimer: Timer?
    var pauseTimerSchedule = RecordingPauseTimerSchedule()
    lazy var recordingPausePersistence = RecordingPausePersistence(defaults: AppEnvironment.current.defaults)
    var settingsWindow: NSWindow?
    var settingsRequest = 0
    var activationObserver: NSObjectProtocol?
    var lastExternalApp: NSRunningApplication?
    var toast: NSPanel?
    var toastGeneration = 0
    var pasteGeneration = 0
    var translationConfig = TranslationConfig.shared
    var translationGeneration = 0
    var translationTask: URLSessionDataTask?
    var savedClipboard: [[ClipPart]]?
    var terminationSignals: [DispatchSourceSignal] = []
    var permissionTimer: Timer?
    lazy var permissionMonitor = PermissionMonitor(
        query: { PermissionState(accessibility: AXIsProcessTrusted(), eventPosting: CGPreflightPostEventAccess()) },
        publish: { [weak self] state in
            guard let self else { return }
            let allowed = directPasteAllowed(accessibility: state.accessibility, eventPosting: state.eventPosting)
            let status = allowed ? "已授权" : (state.accessibility ? "辅助功能已开，按键权限未生效" : "系统尚未识别授权")
            if store.directPasteAuthorized != allowed { store.directPasteAuthorized = allowed }
            if store.translationSelectionAuthorized != state.accessibility { store.translationSelectionAuthorized = state.accessibility }
            if store.permissionStatus != status { store.permissionStatus = status }
        })
    var modalShowing = false
    func prepareAlert(_ alert: NSAlert) {
        alert.window.level = NSWindow.Level(rawValue: max(panel.level.rawValue, settingsWindow?.level.rawValue ?? 0) + 1)
        let screen = settingsWindow?.screen ?? panel.screen ?? NSScreen.main!
        let frame = screen.visibleFrame
        alert.window.setFrameOrigin(NSPoint(x: frame.midX - alert.window.frame.width / 2, y: frame.midY - alert.window.frame.height / 2))
    }
    func presentAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !interactionState.hasModalInteraction else { return }
        let parent = previewWindow?.isKeyWindow == true ? previewWindow! : (store.settings && settingsWindow?.isVisible == true ? settingsWindow! : panel!)
        prepareAlert(alert)
        modalShowing = true
        alert.beginSheetModal(for: parent) { [weak self] response in
            self?.modalShowing = false
            completion(response)
            DispatchQueue.main.async { self?.restoreWorkingWindowFocus() }
        }
        // AppKit may change sheet level during attachment; enforce it afterwards.
        alert.window.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
        alert.window.makeKeyAndOrderFront(nil)
    }
    func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        prepareAlert(alert)
        modalShowing = true
        defer { modalShowing = false }
        return alert.runModal()
    }
    func refreshPermission() {
        permissionMonitor.refresh()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermission()
        restoreWorkingWindowFocus()
    }
    var directPasteAllowed: Bool {
        directPasteAllowed(accessibility: AXIsProcessTrusted(), eventPosting: CGPreflightPostEventAccess())
    }
    func directPasteAllowed(accessibility: Bool, eventPosting: Bool) -> Bool {
        if TestMode.ui, TestMode.forceManual { return false }
        return accessibility && eventPosting
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A link card dropped on Messages is pasted there, the same way Return pastes it.
        DragPasteRedirect.paste = { [weak self] clip, pid in
            guard let self, let app = NSRunningApplication(processIdentifier: pid) else { return }
            self.target = app; self.lastExternalApp = app
            AppDiagnostics.record("drag.paste-instead")
            // As Return: the whole selection when the dragged card is part of it.
            self.pasteSelection(fallback: clip)
        }
        AcceptanceMetrics.start()
        AppDiagnostics.record("app.launch")
        Controller.shared = self
        let finishStoreInit = AcceptanceMetrics.begin("launch.store-init")
        _ = store
        finishStoreInit()
        restoreRecordingPause()
        if !preview && !TestMode.active && AppEnvironment.current.defaults.bool(forKey: "recordingAccepted") { UsageAnalytics.shared.start() }
        if let iconURL = Bundle.main.url(forResource: "OpenPaste-v2", withExtension: "icns"), let icon = NSImage(contentsOf: iconURL) { NSApp.applicationIconImage = icon }
        let finishStoreSetup = AcceptanceMetrics.begin("launch.link-cache")
        LinkPreviewCache.shared.enabled = store.networkPreviews
        finishStoreSetup()
        refreshPermission()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, self.panel?.isVisible == true || self.settingsWindow?.isVisible == true else { return }
            self.refreshPermission()
        }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        for value in [SIGTERM, SIGINT] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            terminationSignals.append(source)
        }
        NSApp.setActivationPolicy(.accessory)
        let main = NSMenu(); let appMenu = NSMenu(); let top = NSMenuItem(); top.submenu = appMenu; main.addItem(top)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: ","); settingsItem.target = self; appMenu.addItem(settingsItem); appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 OpenPaste", action: #selector(quit), keyEquivalent: "q"); quitItem.target = self; appMenu.addItem(quitItem); let editMenu = NSMenu(title: "编辑")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = editMenu; main.addItem(editItem)
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = main
        #if OPENPASTE_TESTING
        if TestMode.translationWorkflow || TestMode.keyboard { savedClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { ClipPart(type: type.rawValue, data: $0) } } } }
        if preview { store.demo(); store.message = "演示模式 · 使用示例内容 · 不记录真实剪贴板" }
        if TestMode.layout, CommandLine.arguments.contains("--startup-performance-test") || CommandLine.arguments.contains("--preview-toggle-test") {
            prepareStartupPerformanceFixture(store)
        }
        if TestMode.ui {
            store.archive.clips[3] = fixtureImage()
            savedClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { ClipPart(type: type.rawValue, data: $0) } } }
            let text = "OpenPaste 输入验证：左右选择后按回车，再按 Command-V。"
            store.archive.clips[1].text = text
            store.archive.clips[1].title = "测试粘贴文本"
            store.archive.clips[1].kind = "文字"
            store.archive.clips[1].parts = [[ClipPart(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))]]
        }
        if TestMode.featureUI {
            let values = ["https://maps.apple.com/?q=Blue%20Bottle%20Coffee&ll=37.7955,-122.3937", "https://www.apple.com/mac/", "#1A2B3C", "Text(store.shortcutNotice.isEmpty ? \"使用组合键\" : store.shortcutNotice).font(.caption).foregroundStyle(.secondary)"]
            store.archive.clips = values.enumerated().map { index, text in Clip(created: Date().addingTimeInterval(-Double(index * 60)), source: "测试内容", sourceID: "com.apple.Maps", kind: text.hasPrefix("http") ? "链接" : (CapturedColor.parse(text) != nil ? "颜色" : "文字"), title: text, text: text, parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(text.utf8))]]) }
            store.archive.clips.append(fixtureOCRImage())
        }
        #endif
        let finishPanelHost = AcceptanceMetrics.begin("launch.panel-host")
        let finishPanelWindow = AcceptanceMetrics.begin("launch.panel-window")
        panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: max(180, AppEnvironment.current.defaults.double(forKey: "shelfHeight") == 0 ? 300 : AppEnvironment.current.defaults.double(forKey: "shelfHeight"))), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = false; panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.minSize = NSSize(width: 760, height: 180)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        finishPanelWindow()
        let finishPanelContent = AcceptanceMetrics.begin("launch.panel-content")
        panel.contentView = ShelfHost(rootView: ShelfView(store: store, driver: stripDriver))
        finishPanelContent()
        finishPanelHost()
        observeMenuTracking()
        let finishApplicationSetup = AcceptanceMetrics.begin("launch.application-setup")
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.lastExternalApp = app
            self.dismissShelfForExternalInteraction(reason: .activation)
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) || !self.panel.isVisible else { return }
            self.dismissShelfForExternalInteraction(reason: .outsideClick)
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = MenuBarMark.image()
        status.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.addItem(withTitle: "打开剪贴板  \(shortcut.label)", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "暂停 / 继续记录", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        let updateItem = NSMenuItem(title: UpdateChecker.shared.menuTitle, action: #selector(checkUpdatesFromMenu), keyEquivalent: "")
        menu.addItem(updateItem); updateMenuItem = updateItem
        UpdateChecker.shared.onChange = { [weak self] in self?.updateMenuItem?.title = UpdateChecker.shared.menuTitle }
        if !preview {
            UpdateChecker.shared.start(); UpdateInstaller.shared.sweepStaleStaging()
            // Let the menu bar and windows settle before telling the user how the last update went.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showUpdateResultIfNeeded() }
        }
        menu.addItem(withTitle: "退出 OpenPaste", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }; status.menu = menu
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in Controller.shared?.hotkeyFired(eventTime: event.map { GetEventTime($0) }); return noErr }, 1, &spec, nil, &handler)
        _ = installShortcut(shortcut, persist: false)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .flagsChanged {
                let flags = event.modifierFlags
                self.store.reverseHistory = InteractionPolicy.reverseHistoryEnabled(
                    for: ModifierState(command: flags.contains(.command), shift: flags.contains(.shift), option: flags.contains(.option), control: flags.contains(.control)),
                    interaction: self.interactionState, shelfIsKey: self.panel.isKeyWindow,
                    textInputFocused: self.panel.firstResponder is NSTextView, settingsVisible: self.store.settings)
                return event
            }
            guard !self.interactionState.menuTracking, !self.interactionState.hasModalInteraction else { return event }
            self.restoreShelfKeyboardFocus()
            if self.store.recordingShortcut, self.settingsWindow?.isKeyWindow == true {
                if event.keyCode == 53 { self.cancelShortcutRecording() }
                else {
                    let candidate = GlobalShortcut.from(event)
                    if candidate.valid { self.store.recordingShortcut = false; if !self.installShortcut(candidate, persist: true) { _ = self.installShortcut(self.shortcut, persist: false, preserveNotice: true) } }
                    else { self.store.shortcutNotice = "请使用 ⌘、⌃ 或 ⌥ 加一个按键；Esc 取消" }
                }
                return nil
            }
            if let target = self.store.recordingChord, self.settingsWindow?.isKeyWindow == true {
                if event.keyCode == 53 { self.store.recordingChord = nil; self.store.chordNotice = "" }
                else { self.recordChord(ShelfChord.from(event), for: target) }
                return nil
            }
            if self.store.settings, self.settingsWindow?.attachedSheet == nil, self.settingsWindow?.isKeyWindow == true, event.keyCode == 53 || (event.keyCode == 13 && event.modifierFlags.contains(.command)) { self.closeSettings(); return nil }
            // Read-only text in the preview may hold focus; only a text view being edited keeps the arrow keys.
            if self.previewPopover?.isShown == true, !self.store.settings, (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable != true {
                let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                if event.keyCode == 49 || event.keyCode == 53 {
                    if !event.isARepeat { self.closePreview() }
                    return nil
                }
                // The preview follows the shelf selection, so arrows simply move it.
                if plain, event.keyCode == 123 || event.keyCode == 124 { self.store.searchFocused = false; self.store.moveSelection(event.keyCode == 124 ? 1 : -1); return nil }
                if event.modifierFlags.contains(.command), let clip = self.previewClip {
                    switch event.charactersIgnoringModifiers?.lowercased() { case "e": self.edit(clip); return nil; case "r": self.rename(clip); return nil; case "o": self.openItem(clip); return nil; default: break }
                }
            }
            guard !self.modalShowing, self.panel.isKeyWindow, !self.store.settings else { return event }
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            if self.store.renamingID != nil {
                if event.keyCode == 53 { self.cancelInlineRename(); return nil }
                return event
            }
            if event.keyCode == 53 {
                // A held Esc acts once: after it closed the preview or collapsed search, its repeats must not go on to
                // hide the shelf.
                if event.isARepeat { return nil }
                if self.store.filtersExpanded { withFilterCardAnimation { self.store.filtersExpanded = false } }
                else if self.store.searchExpanded {
                    self.store.resetFilters(preserveBoard: true); self.store.filtersExpanded = false
                    self.store.searchFocused = false; self.store.searchExpanded = false
                    self.panel.makeFirstResponder(self.panel.contentView)
                } else { self.hideShelf() }
                return nil
            }
            if event.keyCode == 51, [NSEvent.ModifierFlags.command, [.command, .shift]].contains(event.modifierFlags.intersection([.command, .option, .control, .shift])) {
                if self.panel.firstResponder is NSTextView { return event }
                self.store.reverseHistory = event.modifierFlags.contains(.shift)
                self.store.deleteChosen()
                return nil
            }
            for (chord, delta) in [(self.store.shelfShortcuts.nextBoard, 1), (self.store.shelfShortcuts.previousBoard, -1)] where chord.matches(event) {
                if self.panel.firstResponder is NSTextView, chord.movesTextCursor { break }
                self.switchBoard(delta); return nil
            }
            if !(self.panel.firstResponder is NSTextView) {
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                if event.modifierFlags.contains(.command) {
                    if event.keyCode == 36 || event.keyCode == 76 { self.pasteNext(); return nil }
                    if key == "e", let clip = self.store.selectedClips.first { self.edit(clip); return nil }
                    if key == "r", let clip = self.store.selectedClips.first { self.rename(clip); return nil }
                    if key == "o", let clip = self.store.selectedClips.first { self.openItem(clip); return nil }
                    if key == "n" { if event.modifierFlags.contains(.shift) { self.newBoard() } else { self.createText() }; return nil }
                    if key == "z" { self.store.undoItemChange(); return nil }
                    if key == "t" {
                        if self.store.recordingPauseControl.action == .pause { self.pauseMenu() }
                        else { self.togglePause() }
                        return nil
                    }
                }
                if event.keyCode == 49, let clip = self.store.selectedClips.first {
                    if !event.isARepeat { self.showPreview(clip) }
                    return nil
                }
                if event.keyCode == 48 { self.store.searchFocused = true; return nil }
                if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { }
                else if let chars = event.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), ![36,49,123,124,125,126,48,53,51,117].contains(event.keyCode) { self.beginTypeToSearch(event); return nil }
            } else if event.keyCode == 48 || event.keyCode == 125 { self.store.searchFocused = false; self.panel.makeFirstResponder(self.panel.contentView); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" { if self.store.searchExpanded { withFilterCardAnimation { self.store.filtersExpanded.toggle() } }; self.store.searchFocused = true; return nil }
            let quick = self.store.shelfShortcuts.quickPasteMatch(event.modifierFlags)
            if quick.matches, let n = Int(event.charactersIgnoringModifiers ?? ""), n >= 1, n <= 9, self.store.filtered.count >= n { self.paste(self.store.filtered[n - 1], plain: quick.plain); return nil }
            if event.keyCode == 36 || event.keyCode == 76, let clip = self.store.filtered.first(where: { $0.id == self.store.selected }) ?? self.store.filtered.first { self.pasteSelection(fallback: clip, plain: self.store.shelfShortcuts.isPlain(event.modifierFlags)); return nil }
            if [123, 124].contains(event.keyCode), self.panel.firstResponder is NSTextView { return event }
            if [123, 124, 125].contains(event.keyCode), !event.modifierFlags.contains(.command) {
                self.store.searchFocused = false
                self.panel.makeFirstResponder(self.panel.contentView)
                if event.keyCode != 125 {
                    let delta = event.keyCode == 124 ? 1 : -1
                    if event.modifierFlags.contains(.shift), let selected = self.store.selected, let index = self.store.visibleIndex(of: selected), !self.store.filtered.isEmpty { let id = self.store.filtered[max(0, min(self.store.filtered.count - 1, index + delta))].id; if id != selected { self.store.keyboardNavigated = true }; self.store.choose(id, modifiers: .shift) }
                    else { self.store.moveSelection(delta) }
                }
                return nil
            }
            return event
        }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            // The card strip has no scroll view of its own: trackpad and wheel scrolling over it pan the strip. While the
            // filter card is open it floats over the strip and may scroll itself (a short shelf), so its events pass through.
            guard let self, event.window === self.panel, !self.store.settings, let strip = self.stripDriver.hostView, strip.window === self.panel,
                  HorizontalWheel.pansStrip(pointerOverStrip: strip.bounds.contains(strip.convert(event.locationInWindow, from: nil)),
                                            filterCardOpen: self.store.filtersExpanded),
                  let delta = HorizontalWheel.panDelta(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas) else { return event }
            self.stripDriver.scroll(by: delta)
            return nil
        }
        finishApplicationSetup()
        #if OPENPASTE_TESTING
        if TestMode.keyboard {
            store.networkPreviews = false
            // Give the terminal-launched GUI test a Dock entry so macOS allows
            // it to activate. Production still uses the accessory policy above.
            NSApp.setActivationPolicy(.regular)
            showShelf()
            Task { @MainActor in await runKeyboardTests(controller: self) }
        } else if TestMode.shortcut {
            let first = GlobalShortcut(keyCode: 111, modifiers: UInt32(cmdKey), keyName: "F12")
            guard installShortcut(first, persist: true), shortcut == first, store.shortcutLabel == first.label, hotkey != nil else { print("FAIL: custom hotkey registration"); exit(1) }
            var occupied: EventHotKeyRef?
            let second = GlobalShortcut(keyCode: 103, modifiers: first.modifiers, keyName: "F11")
            guard RegisterEventHotKey(second.keyCode, second.modifiers, EventHotKeyID(signature: 0x54455354, id: 2), GetApplicationEventTarget(), 0, &occupied) == noErr else { print("FAIL: prepare conflict test"); exit(1) }
            guard !installShortcut(second, persist: true), shortcut == first, hotkey != nil else { print("FAIL: conflict lost original hotkey"); exit(1) }
            beginShortcutRecording()
            guard hotkey == nil, !installShortcut(second, persist: true), store.shortcutLabel.contains("未生效"), status.menu?.items.first?.title.contains("不可用") == true else { print("FAIL: unregistered shortcut conflict was not visible"); exit(1) }
            guard installShortcut(first, persist: false, preserveNotice: true), hotkey != nil, shortcut == first else { print("FAIL: conflict during recording did not restore prior shortcut"); exit(1) }
            store.recordingShortcut = false
            if let occupied = occupied { UnregisterEventHotKey(occupied) }
            show(); openSettings(); beginShortcutRecording()
            guard store.recordingShortcut, hotkey == nil else { print("FAIL: begin recording"); exit(1) }
            cancelShortcutRecording()
            guard !store.recordingShortcut, hotkey != nil, shortcut == first else { print("FAIL: cancel recording did not restore hotkey"); exit(1) }
            beginShortcutRecording(); closeSettings()
            guard !store.recordingShortcut, !store.settings, hotkey != nil else { print("FAIL: close recording did not restore hotkey"); exit(1) }
            print("PASS: global registration, conflict preserves original, cancel and close restore shortcut")
            NSApp.terminate(nil)
        } else if TestMode.layout {
            if CommandLine.arguments.contains("--preview-toggle-test") {
                Task { @MainActor in await runPreviewToggleTests(controller: self) }
                return
            }
            if CommandLine.arguments.contains("--startup-performance-test") {
                if CommandLine.arguments.contains("--startup-performance-interactive") {
                    runStartupPerformanceInteractive(controller: self)
                } else {
                    Task { @MainActor in await runStartupPerformanceTests(controller: self) }
                }
                return
            }
            show()
            let before = panel.frame
            guard let shelfScreen = panel.screen, before.minY == shelfScreen.frame.minY, before.minX == shelfScreen.frame.minX, before.width == shelfScreen.frame.width else { print("FAIL: shelf not flush with screen edges"); exit(1) }
            print("PASS: shelf fills screen width and touches physical bottom")
            openSettingsFromMenu()
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
            dismissShelfForExternalInteraction()
            guard panel.isVisible, settingsWindow == nil else { print("FAIL: menu transition hid shelf before settings was ready"); exit(1) }
            print("PASS: settings waits for menu tracking to finish and keeps shelf visible")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard self.panel.frame == before, !self.panel.isVisible else { print("FAIL: settings did not hide shelf or changed geometry"); exit(1) }
                guard let settings = self.settingsWindow, settings.level == .normal else { print("FAIL: settings remains always on top"); exit(1) }
                guard let closeButton = self.settingsWindow?.standardWindowButton(.closeButton), !closeButton.isHidden, closeButton.isEnabled else { print("FAIL: settings close button unavailable"); exit(1) }
                guard let window = self.settingsWindow, window.isVisible, let screen = window.screen, screen.visibleFrame.contains(window.frame) else { print("FAIL: settings outside visible screen"); exit(1) }
                if NSApp.isActive {
                    guard window.isKeyWindow else { print("FAIL: first settings opening did not receive focus"); exit(1) }
                    print("PASS: first menu settings request creates a visible focused window")
                } else { print("FAIL: focus assertion requires foreground user activation; focus has not been verified"); exit(1) }
                let ordinary = NSWindow(contentRect: window.frame.insetBy(dx: 80, dy: 80), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                ordinary.title = "Window ordering test"; ordinary.isReleasedWhenClosed = false
                ordinary.makeKeyAndOrderFront(nil)
                let ordered = NSApp.orderedWindows.filter { $0 === ordinary || $0 === window }
                guard ordered.first === ordinary else { print("FAIL: ordinary window cannot cover settings"); exit(1) }
                ordinary.close(); window.makeKeyAndOrderFront(nil)
                print("PASS: settings uses normal level and yields to another ordinary window")
                let alert = NSAlert(); self.prepareAlert(alert)
                guard alert.window.level.rawValue > window.level.rawValue else { print("FAIL: alert behind settings"); exit(1) }
                print("PASS: confirmation alert above settings and shelf")
                self.closeSettings()
                guard !self.store.settings, self.panel.frame == before else { print("FAIL: close settings changed shelf"); exit(1) }
                self.openSettingsFromMenu()
                self.closeSettings()
                guard !self.store.settings, !window.isVisible else { print("FAIL: canceled menu request reopened settings"); exit(1) }
                self.openSettings()
                guard self.settingsWindow === window, window.level == .normal, self.panel.frame == before else { print("FAIL: reopening settings"); exit(1) }
                self.showShelf()
                guard self.panel.isVisible, !self.store.settings, !window.isVisible else { print("FAIL: shelf reopening left settings active"); exit(1) }
                self.modalShowing = true
                self.dismissShelfForExternalInteraction()
                guard self.panel.isVisible else { print("FAIL: modal interaction dismissed shelf"); exit(1) }
                self.modalShowing = false
                self.store.reverseHistory = true
                self.dismissShelfForExternalInteraction()
                guard !self.panel.isVisible, !self.store.reverseHistory else { print("FAIL: outside interaction did not dismiss shelf/reset reverse order"); exit(1) }
                print("PASS: outside interaction dismisses shelf; modal interaction preserves it")
                self.showShelf()
                self.hideShelf()
                guard !self.panel.isVisible else { print("FAIL: reopened shelf cannot close"); exit(1) }
                print("PASS: opening settings hides shelf; reopening shelf closes settings; reopened shelf closes normally")
                runSettingsPageCacheTests(store: self.store)
                NSApp.terminate(nil)
            }
        }
        if TestMode.keyboard || TestMode.shortcut || TestMode.layout { return }
        #endif
        if preview {
            show()
            if CommandLine.arguments.contains("--settings") { let finish = AcceptanceMetrics.begin("launch.open-settings"); openSettings(); finish() }
            if TestMode.translationUI { translateSelection("Hello\n    world") }
        } else if !AppEnvironment.current.defaults.bool(forKey: "recordingAccepted") { onboarding() }
        else {
            let finishStart = AcceptanceMetrics.begin("launch.store-start"); store.start(); finishStart()
            if CommandLine.arguments.contains("--settings") { let finish = AcceptanceMetrics.begin("launch.open-settings"); openSettings(); finish() }
        }
    }
    func onboarding() {
        let sourceApp = resolveExternalTarget()
        let initialSource = sourceApp.map { ClipboardCaptureSource(name: $0.localizedName ?? "未知应用", bundleID: $0.bundleIdentifier ?? "") }
        let initialChangeCount = NSPasteboard.general.changeCount
        let alert = NSAlert(); alert.messageText = "欢迎使用 OpenPaste"
        alert.informativeText = "启用后，当前剪贴板以及之后复制的文字、链接、图片和文件引用都会保存到这台 Mac。默认跳过已标记的敏感内容和常见密码管理器。普通应用复制的敏感文字仍可能被记录，请按需要暂停或设置排除应用。\n\n默认保存在本机；可在数据管理中选择 iCloud Drive 目录，由系统同步历史。网页预览与快速翻译按各自的设置联网。"
        if UsageAnalytics.shared.available {
            alert.informativeText += "\n\n使用统计默认开启：向 Google Firebase Analytics 发送首次启动、粘贴取用和翻译成功次数，以及 SDK 的应用实例、设备和版本信息，不包含剪贴板正文或翻译密钥。可单独关闭，不影响本地记录。"
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "帮助改进 OpenPaste（发送使用统计）"
            alert.suppressionButton?.state = UsageAnalytics.shared.enabled ? .on : .off
        }
        alert.addButton(withTitle: "启用本地记录"); alert.addButton(withTitle: "暂不启用")
        NSApp.activate()
        let accepted = runAlert(alert) == .alertFirstButtonReturn
        if UsageAnalytics.shared.available {
            UsageAnalytics.shared.enabled = alert.suppressionButton?.state == .on
            UsageAnalytics.shared.start()
        }
        store.setRecordingAccepted(accepted)
        if accepted { store.start(initialSource: initialSource, initialChangeCount: initialChangeCount) }
        show()
    }
    func resolveExternalTarget(frontmost: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> NSRunningApplication? {
        [frontmost, lastExternalApp, target].compactMap { $0 }.first {
            !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }
    func rememberExternalTarget() {
        target = resolveExternalTarget()
        if let target { lastExternalApp = target }
    }
    func excludeCurrentTargetApplication() {
        rememberExternalTarget()
        guard let id = target?.bundleIdentifier else { return }
        let excluded = store.ignored.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if !excluded.contains(id) { store.ignored += "\n" + id }
    }
    /// Shows the shelf. With `activating: false` it is ordered in front without taking keyboard focus, so the
    /// frontmost app stays the target while the selection is read; call `activateShelf()` afterwards.
    func showShelf(activating: Bool = true) {
        let finishTiming = AcceptanceMetrics.begin("shelf.show"); defer { finishTiming() }
        guard prepareShelfPresentation({ [weak self] in self?.showShelf(activating: activating) }) else { return }
        guard !store.changingDataDirectory else { openSettings(); return }
        shelfPresentation += 1
        pendingOutsideClick = false
        pendingApplicationSwitch = false
        if store.settings { closeSettings() }
        rememberExternalTarget()
        if TestMode.ui { target = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.SwallOwDili.OpenPaste.fixture").first }
        if TestMode.ui { print("UI show target: \(target?.bundleIdentifier ?? "none")"); fflush(stdout) }
        pasteGeneration += 1
        store.resetFilters(); store.filtersExpanded = false
        if !preview, AppEnvironment.current.defaults.bool(forKey: "recordingAccepted") { store.capture(force: true) }
        refreshPermission()
        store.searchFocused = false
        store.searchExpanded = false
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main!
        let r = screen.frame
        let h = min(max(panel.frame.height, 180), r.height * 0.75)
        // Quick translation reads the selection synchronously after an unfocused presentation.
        panel.setFrame(NSRect(x: r.minX, y: r.minY, width: r.width, height: h), display: !activating)
        store.reverseHistory = false; store.selection.removeAll(); store.compact = h < 270
        store.selected = store.currentClipID ?? store.filtered.first?.id
        // A fresh shelf starts on the selection, without any pan left over from the last time it was open.
        stripDriver.snap(to: store.selected.flatMap { store.visibleIndex(of: $0) } ?? 0)
        if activating {
            shelfAwaitingActivation = false
            NSApp.activate(); panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panel.contentView)
            logInteraction("shelf.show")
            DispatchQueue.main.async { [weak self] in self?.restoreShelfKeyboardFocus() }
            verifyShelfActivation(attempt: 0)
        } else {
            shelfAwaitingActivation = true
            panel.orderFrontRegardless()
            logInteraction("shelf.show-unfocused")
        }
    }
    /// Gives a shelf that was shown without focus the keyboard, once the selection check is done.
    func activateShelf() {
        guard shelfAwaitingActivation else { return }
        shelfAwaitingActivation = false
        guard panel.isVisible else { return }
        NSApp.activate(); panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        logInteraction("shelf.activate")
        DispatchQueue.main.async { [weak self] in self?.restoreShelfKeyboardFocus() }
        verifyShelfActivation(attempt: 0)
    }
    /// The system can drop an activation request while another app stays frontmost. The shelf is a non-activating
    /// panel so it normally still becomes key; check that it did, retry otherwise, and record the result.
    func verifyShelfActivation(attempt: Int) {
        let presentation = shelfPresentation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.shelfPresentation == presentation, self.panel.isVisible, !self.shelfAwaitingActivation else { return }
            if self.panel.isKeyWindow { if attempt > 0 { self.logInteraction("shelf.activate-recovered") }; return }
            guard attempt < 3, !self.store.settings, !self.modalShowing, self.previewWindow?.isVisible != true, self.editorWindow?.isVisible != true else { return }
            self.logInteraction("shelf.activate-retry", reason: "attempt\(attempt + 1)")
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate()
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(self.panel.contentView)
            self.verifyShelfActivation(attempt: attempt + 1)
        }
    }
    func restoreShelfKeyboardFocus() {
        // A visible borderless shelf can lose its key window after activation or
        // closing an auxiliary window. Never steal focus from another app/window.
        guard let panel, panel.isVisible, NSApp.keyWindow == nil,
              !interactionState.menuTracking, NSApp.modalWindow == nil,
              !store.settings, !modalShowing, panel.attachedSheet == nil,
              settingsWindow?.isVisible != true, previewWindow?.isVisible != true,
              editorWindow?.isVisible != true, NSApp.isActive else { return }
        panel.makeKeyAndOrderFront(nil)
        if !store.searchFocused { panel.makeFirstResponder(panel.contentView) }
    }
    var interactionState: InteractionState {
        InteractionState(
            modal: modalShowing || NSApp.modalWindow != nil,
            attachedSheet: [panel, settingsWindow, previewWindow, editorWindow].contains { $0?.attachedSheet != nil },
            menuTracking: !trackingMenus.isEmpty || menuFinishing || RunLoop.current.currentMode == .eventTracking,
            recordingShortcut: store.recordingShortcut,
            editorVisible: editorWindow?.isVisible == true,
            previewVisible: previewWindow?.isVisible == true)
    }
    func prepareShelfPresentation(_ retry: @escaping () -> Void) -> Bool {
        switch InteractionPolicy.presentationDecision(for: interactionState) {
        case .ignored: return false
        case .deferred:
            if pendingShelfPresentation == nil {
                RunLoop.main.perform(inModes: [.default]) { [weak self] in
                    let action = self?.pendingShelfPresentation
                    self?.pendingShelfPresentation = nil
                    action?()
                }
            }
            pendingShelfPresentation = retry
            return false
        case .focusEditor:
            NSApp.activate(); editorWindow?.makeKeyAndOrderFront(nil)
            return false
        case .focusPreview:
            NSApp.activate(); previewWindow?.makeKeyAndOrderFront(nil)
            return false
        case .showShelf: return true
        }
    }
    func restoreWorkingWindowFocus() {
        guard NSApp.isActive, NSApp.keyWindow == nil, !interactionState.menuTracking, NSApp.modalWindow == nil else { return }
        let windows = [editorWindow, previewWindow, settingsWindow, panel].compactMap { $0 }.filter(\.isVisible)
        if let sheet = windows.compactMap(\.attachedSheet).first {
            sheet.makeKeyAndOrderFront(nil)
        } else if !modalShowing, let window = windows.first, window !== panel {
            window.makeKeyAndOrderFront(nil)
        } else {
            restoreShelfKeyboardFocus()
        }
    }
    func hideShelf() {
        logInteraction("shelf.hide", reason: "explicit")
        shelfAwaitingActivation = false
        closePreview()
        cancelTranslation()
        store.reverseHistory = false
        // Close the filter card with the shelf (no animation), so the next show does not briefly play its closing.
        store.filtersExpanded = false
        panel.orderOut(nil)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier, let target = target { NSApp.yieldActivation(to: target); _ = target.activate(options: []) }
    }
    /// Global hotkey entry. With the `diagnosticsShowTiming` preference set, records where time goes between the
    /// key event and the committed frame (numbers only): event-to-handler lag, synchronous show work, the wait for
    /// the next main-queue turn, and the Core Animation commit.
    func hotkeyFired(eventTime: Double?) {
        let enter = ProcessInfo.processInfo.systemUptime
        guard AppEnvironment.current.defaults.bool(forKey: "diagnosticsShowTiming") else { toggle(); return }
        toggle()
        let afterToggle = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            let turnStart = ProcessInfo.processInfo.systemUptime
            CATransaction.flush()
            let committed = ProcessInfo.processInfo.systemUptime
            func ms(_ value: Double) -> String { String(format: "%.1f", max(0, value) * 1000) }
            let visibleNow = self?.panel.isVisible == true
            let translating = AppEnvironment.current.defaults.bool(forKey: "translationEnabled")
            func record(visibleAt: Double?) {
                AppDiagnostics.record("shelf.timing", [
                    "lag-ms": eventTime.map { ms(enter - $0) } ?? "unknown",
                    "sync-ms": ms(afterToggle - enter),
                    "queue-ms": ms(turnStart - afterToggle),
                    "commit-ms": ms(committed - turnStart),
                    "visible-ms": visibleAt.map { ms($0 - (eventTime ?? enter)) } ?? "never",
                    "quick-translation": String(translating)
                ])
            }
            if visibleNow { record(visibleAt: committed); return }
            // The shelf can be shown later (quick translation reads the selection first); poll until it is.
            func poll() {
                let now = ProcessInfo.processInfo.systemUptime
                if self?.panel.isVisible == true { record(visibleAt: now) }
                else if now - enter > 3 { record(visibleAt: nil) }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { poll() } }
            }
            poll()
        }
    }
    func toggle() {
        guard prepareShelfPresentation({ [weak self] in self?.toggle() }) else { return }
        if panel.isVisible && (panel.isKeyWindow || shelfAwaitingActivation) { hideShelf() } else { show() }
    }
    @objc func togglePause() {
        switch store.recordingPauseControl.action {
        case .pause: pauseFor(nil)
        case .resume: resumeRecording()
        case .enable: onboarding()
        case .retryLoad, .retrySave: store.retryRecordingStorage()
        case .unavailable: showToast(store.recordingPauseControl.status)
        }
    }
    @objc func openSettings() {
        let finishTiming = AcceptanceMetrics.begin("settings.open"); defer { finishTiming() }
        rememberExternalTarget()
        settingsRequest += 1
        store.settings = true
        closePreview()
        cancelTranslation()
        store.reverseHistory = false
        refreshPermission()
        if settingsWindow == nil {
            let finishWindow = AcceptanceMetrics.begin("settings.window")
            let screen = panel.screen ?? NSScreen.main!
            let height = min(620, max(260, screen.visibleFrame.height - 100))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(760, screen.visibleFrame.width - 60), height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "OpenPaste 设置"
            window.isReleasedWhenClosed = false
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.closeButton)?.isEnabled = true
            window.level = .normal
            window.delegate = self
            finishWindow()
            let finishContent = AcceptanceMetrics.begin("settings.content")
            let host = NSHostingView(rootView: SettingsView(store: store))
            host.sizingOptions = []
            window.contentView = host
            finishContent()
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
            settingsWindow = window
        }
        let finishShow = AcceptanceMetrics.begin("settings.show")
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        finishShow()
        logInteraction("shelf.hide", reason: "settings")
        panel.orderOut(nil)
        logInteraction("settings.open")
        let request = settingsRequest
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self, self.settingsRequest == request, self.store.settings,
                  let window = self.settingsWindow, window.isVisible else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }
    @objc func openSettingsFromMenu() {
        logInteraction("settings.request")
        settingsRequest += 1
        let request = settingsRequest
        store.settings = true
        // Menu tracking must finish before creating and activating a normal window.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self, self.settingsRequest == request, self.store.settings else { return }
            self.openSettings()
        }
    }
    @objc func checkUpdatesFromMenu() {
        guard !modalShowing else { return }
        if UpdateChecker.shared.available != nil { showUpdateDetails(); return }
        openSettings()
        NotificationCenter.default.post(name: UpdateChecker.aboutNotification, object: nil)
        UpdateChecker.shared.check()
    }
    func showUpdateDetails() {
        guard !modalShowing, let release = UpdateChecker.shared.available, let url = release.pageURL else { return }
        openSettings()
        NotificationCenter.default.post(name: UpdateChecker.aboutNotification, object: nil)
        let installer = UpdateInstaller.shared
        let blocked = installer.blockingReason()
        let alert = NSAlert()
        alert.messageText = "OpenPaste \(release.version) 已发布"
        alert.informativeText = blocked == nil
            ? "选择“下载并更新”后，应用会下载并校验新版，确认后才会重启安装；历史保留，辅助功能授权不变。"
            : "\(blocked?.localizedDescription ?? "")。"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 260)); scroll.hasVerticalScroller = true
        let notes = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        notes.autoresizingMask = [.width]
        notes.isEditable = false
        notes.textContainerInset = NSSize(width: 4, height: 6)
        scroll.documentView = notes
        // Pictures get placeholders now and are loaded in the background; closing the dialog cancels what is left.
        let imageWidth = scroll.contentSize.width - 2 * notes.textContainerInset.width - 2 * (notes.textContainer?.lineFragmentPadding ?? 5)
        notes.textStorage?.setAttributedString(ReleaseNotes.attributed(String((release.body ?? "").prefix(12000)), imageWidth: imageWidth))
        let images = ReleaseNoteImageLoader()
        if let storage = notes.textStorage { images.load(into: storage, width: imageWidth) }
        alert.accessoryView = scroll
        alert.addButton(withTitle: blocked == nil ? "下载并更新" : "前往下载")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")
        presentAlert(alert) { [weak self] response in
            images.cancel()
            if response == .alertFirstButtonReturn {
                if blocked == nil {
                    installer.onReady = { [weak self] in self?.promptInstallReady() }
                    installer.prepare(release)
                } else { self?.openExternal(url) }
            }
            else if response == .alertThirdButtonReturn { UpdateChecker.shared.skip() }
        }
    }
    func showUpdateResultIfNeeded() {
        guard let notice = UpdateNotice.consumePending() else { return }
        guard !modalShowing else { return }
        openSettings()
        NotificationCenter.default.post(name: UpdateChecker.aboutNotification, object: nil)
        let alert = NSAlert()
        if notice.succeeded {
            alert.messageText = "OpenPaste 已更新到 \(notice.to)"
            alert.informativeText = "上一个版本是 \(notice.from)。历史与设置保持不变。"
        } else {
            alert.messageText = "更新未完成"
            alert.informativeText = "仍在使用 \(notice.from)，已保留当前版本。可以在「设置 → 关于」重新尝试，或前往 GitHub 手动下载。"
        }
        alert.addButton(withTitle: "好")
        presentAlert(alert) { _ in }
    }
    func promptInstallReady() {
        let installer = UpdateInstaller.shared
        guard installer.phase == .ready, let release = installer.preparedRelease, !modalShowing else { return }
        openSettings()
        NotificationCenter.default.post(name: UpdateChecker.aboutNotification, object: nil)
        let alert = NSAlert()
        alert.messageText = "OpenPaste \(release.version) 已准备好"
        alert.informativeText = "新版已下载，SHA-256 与签名均已验证。现在重启并安装？重启后会自动重新打开，历史数据保留。"
        alert.addButton(withTitle: "重启并安装")
        alert.addButton(withTitle: "稍后")
        presentAlert(alert) { response in
            if response == .alertFirstButtonReturn {
                if installer.installAndRelaunch() { NSApp.terminate(nil) }
            }
        }
    }
    func closeSettings() { settingsRequest += 1; store.settings = false; cancelShortcutRecording(); settingsWindow?.close() }
    func beginShortcutRecording() {
        if store.recordingShortcut { cancelShortcutRecording(); return }
        if let hotkey = hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        store.recordingShortcut = true
        store.shortcutNotice = "现在按下新的组合键，Esc 取消"
        settingsWindow?.makeFirstResponder(nil)
    }
    func recordChord(_ chord: ShelfChord, for target: ShelfChordTarget) {
        var updated = store.shelfShortcuts
        if target == .nextBoard { updated.nextBoard = chord } else { updated.previousBoard = chord }
        guard chord.valid else { store.chordNotice = "请使用 ⌘、⌃ 或 ⌥ 搭配一个未被占用的按键；Esc 取消"; return }
        guard updated.nextBoard != updated.previousBoard else { store.chordNotice = "上一个与下一个收藏板不能使用同一组合键"; return }
        store.shelfShortcuts = updated; store.recordingChord = nil; store.chordNotice = ""
    }
    func cancelShortcutRecording() {
        if store.recordingChord != nil { store.recordingChord = nil; store.chordNotice = "" }
        guard store.recordingShortcut else { return }
        store.recordingShortcut = false
        _ = installShortcut(shortcut, persist: false)
    }
    @discardableResult func installShortcut(_ candidate: GlobalShortcut, persist: Bool, preserveNotice: Bool = false) -> Bool {
        guard candidate.valid else { return false }
        if candidate == shortcut, hotkey != nil { store.shortcutNotice = ""; return true }
        var registered: EventHotKeyRef?
        let result = RegisterEventHotKey(candidate.keyCode, candidate.modifiers, EventHotKeyID(signature: 0x4C505354, id: 1), GetApplicationEventTarget(), 0, &registered)
        guard result == noErr else {
            if hotkey == nil {
                store.shortcutLabel = "\(candidate.label) · 未生效"
                store.shortcutNotice = "\(candidate.label) 无法注册，可能已被占用。请点击“更改…”设置其他快捷键。"
                status.menu?.items.first?.title = "打开剪贴板（快捷键不可用）"
            } else {
                store.shortcutNotice = "\(candidate.label) 无法注册，可能已被占用。原快捷键保持不变。"
            }
            store.message = "\(candidate.label) 无法注册；请从菜单栏打开或在设置中更换"
            return false
        }
        if let hotkey = hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = registered; shortcut = candidate
        store.shortcutLabel = candidate.label
        status.menu?.items.first?.title = "打开剪贴板  \(candidate.label)"
        if persist, !preview { candidate.save() }
        if !preserveNotice { store.shortcutNotice = persist ? "已保存，下次启动仍使用此快捷键" : "" }
        if !preview { store.message = store.storageDescription }
        return true
    }
    enum ShelfDismissReason: String { case outsideClick, activation, resignKey, menuEnd }
    var externalApplicationActive: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        return app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
    func logInteraction(_ event: String, reason: String = "none") {
        let keyWindow = NSApp.keyWindow
        let keyRole = keyWindow == nil ? "none" : (keyWindow === panel ? "shelf" : (keyWindow === settingsWindow ? "settings" : (keyWindow === previewWindow ? "preview" : (keyWindow === editorWindow ? "editor" : "temporary"))))
        AppDiagnostics.record(event, [
            "reason": reason, "visible": String(panel?.isVisible == true),
            "key": String(panel?.isKeyWindow == true), "active": String(NSApp.isActive),
            "external": String(externalApplicationActive), "menus": String(trackingMenus.count),
            "finishing": String(menuFinishing), "settings": String(store.settings), "keyRole": keyRole,
            "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
            "secure-input": String(IsSecureEventInputEnabled())
        ])
    }
    func observeMenuTracking() {
        let center = NotificationCenter.default
        menuObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self, let menu = notification.object as? NSMenu else { return }
            self.menuTransition += 1
            self.trackingMenus.insert(ObjectIdentifier(menu))
            self.logInteraction("menu.begin")
        })
        menuObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self, let menu = notification.object as? NSMenu else { return }
            self.trackingMenus.remove(ObjectIdentifier(menu))
            self.menuFinishing = true
            self.menuTransition += 1
            let transition = self.menuTransition
            self.logInteraction("menu.end")
            // Menu actions and temporary windows finish before normal focus decisions.
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                guard let self, self.menuTransition == transition, self.trackingMenus.isEmpty else { return }
                self.menuFinishing = false
                let outsideClick = self.pendingOutsideClick
                let applicationSwitch = self.pendingApplicationSwitch
                self.pendingOutsideClick = false
                self.pendingApplicationSwitch = false
                // A click consumed by menu tracking may already be stale after
                // the user returns to OpenPaste. Recheck the current application.
                if (outsideClick || applicationSwitch) && !NSApp.isActive && self.externalApplicationActive {
                    self.dismissShelfForExternalInteraction(reason: outsideClick ? .outsideClick : .menuEnd)
                } else {
                    self.restoreWorkingWindowFocus()
                }
                self.logInteraction("menu.settled")
            }
        })
    }
    func dismissShelfForExternalInteraction(reason: ShelfDismissReason = .outsideClick) {
        guard panel.isVisible, !modalShowing, panel.attachedSheet == nil,
              previewWindow?.isVisible != true, editorWindow?.isVisible != true, !store.settings else { return }
        if interactionState.menuTracking {
            if reason == .outsideClick { pendingOutsideClick = true }
            else { pendingApplicationSwitch = true }
            logInteraction("shelf.dismiss-deferred", reason: reason.rawValue)
            return
        }
        // Delayed activation/resign notifications must still refer to another app.
        guard reason == .outsideClick || (!NSApp.isActive && externalApplicationActive) else { return }
        logInteraction("shelf.hide", reason: reason.rawValue)
        cancelTranslation()
        store.reverseHistory = false
        store.filtersExpanded = false
        panel.orderOut(nil)
    }
    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panel {
            logInteraction("shelf.resign-key")
            store.reverseHistory = false
            let presentation = shelfPresentation
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                guard let self, self.shelfPresentation == presentation, !self.panel.isKeyWindow else { return }
                // AppKit's temporary popup windows are part of this interaction.
                // Known auxiliary windows manage shelf visibility explicitly.
                self.dismissShelfForExternalInteraction(reason: .resignKey)
            }
        }
        if let window = notification.object as? NSWindow, window === settingsWindow { cancelShortcutRecording() }
    }
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        store.compact = window.frame.height < 270
        if !preview { AppEnvironment.current.defaults.set(Double(window.frame.height), forKey: "shelfHeight") }
        if let screen = window.screen, abs(window.frame.minY - screen.frame.minY) > 0.5 || abs(window.frame.width - screen.frame.width) > 0.5 { window.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: window.frame.height), display: true) }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        refreshPermission()
        if notification.object as? NSWindow === panel { logInteraction("shelf.become-key") }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let finishTiming = AcceptanceMetrics.begin("app.reopen"); defer { finishTiming() }
        let workingWindows = [editorWindow, previewWindow, settingsWindow].compactMap { $0 }.filter(\.isVisible)
        var visibleWindows = workingWindows
        if let panel, panel.isVisible { visibleWindows.append(panel) }
        let attachedSheet = visibleWindows.compactMap(\.attachedSheet).first
        if let sheet = attachedSheet {
            NSApp.activate()
            sheet.makeKeyAndOrderFront(nil)
            return true
        }
        if let window = workingWindows.first {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return true
        }
        if panel.isVisible {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            return true
        }
        show()
        return true
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow { cancelShortcutRecording(); store.settings = false }
        if let window = notification.object as? NSWindow, window === editorWindow {
            if window === editorWindow { editorWindow = nil }
            DispatchQueue.main.async { [weak self] in self?.restoreWorkingWindowFocus() }
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDiagnostics.record("app.terminate")
        store.flush()
        if let savedClipboard = savedClipboard {
            let items = savedClipboard.map { parts in let item = NSPasteboardItem(); for part in parts { item.setData(part.data, forType: NSPasteboard.PasteboardType(part.type)) }; return item }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(items)
        }
        return .terminateNow
    }
    func paste(_ clip: Clip, plain: Bool = false) {
        guard store.restore(clip, plain: plain) else { store.message = "无法复制此内容"; return }
        pastePrepared()
    }
    func pasteSelection(fallback clip: Clip, plain: Bool = false) {
        let selected = store.selectedClips
        guard store.restoreMany(selected.contains(where: { $0.id == clip.id }) ? selected : [clip], plain: plain) else { showToast("无法合并所选内容"); return }; pastePrepared()
    }
    func pastePrepared() {
        closePreview()
        cancelTranslation()
        refreshPermission()
        logInteraction("shelf.hide", reason: "paste")
        panel.orderOut(nil)
        pasteGeneration += 1
        let generation = pasteGeneration
        guard let target = target, !target.isTerminated else { showToast("已复制，请回到输入框按 ⌘V"); return }
        if TestMode.ui { print("UI paste target: \(target.bundleIdentifier ?? "none"), AX: \(AXIsProcessTrusted()), event access: \(CGPreflightPostEventAccess())"); fflush(stdout) }
        NSApp.yieldActivation(to: target)
        _ = target.activate(options: [])
        // The background permission state is for display only. It may still be
        // unknown at startup; finishPaste checks live permission before sending.
        finishPaste(target: target, generation: generation, attempt: 0)
    }
    private func finishPaste(target: NSRunningApplication, generation: Int, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            guard generation == self.pasteGeneration else { return }
            let ready = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
            let modifiersReleased = NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            guard ready && modifiersReleased else {
                if attempt < 60 { self.finishPaste(target: target, generation: generation, attempt: attempt + 1) }
                else { self.showToast("已复制，自动粘贴未完成，请在输入框按 ⌘V") }
                return
            }
            guard self.directPasteAllowed else { self.showToast("已复制，请按 ⌘V 粘贴"); return }
            let source = CGEventSource(stateID: .privateState)
            let sent = PasteShortcut.send(
                makeEvent: { CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: $0) },
                post: { $0.post(tap: .cghidEventTap) },
                didSend: { UsageAnalytics.shared.record(.contentPasted) })
            if !sent { self.showToast("已复制，请按 ⌘V 粘贴") }
        }
    }
    func showToast(_ text: String) {
        store.message = text
        toastGeneration += 1
        let generation = toastGeneration
        if toast == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 58), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .statusBar; window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            toast = window
        }
        guard let toast = toast else { return }
        toast.contentView = NSHostingView(rootView: Text(text).font(.system(size: 13, weight: .medium)).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)))
        let frame = (panel.screen ?? NSScreen.main!).visibleFrame
        toast.setFrameOrigin(NSPoint(x: frame.midX - 260, y: frame.minY + 30))
        toast.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.toastGeneration == generation { toast.orderOut(nil) } }
    }
    func openExternal(_ url: URL) {
        closePreview()
        cancelTranslation()
        closeSettings()
        logInteraction("shelf.hide", reason: "open-external")
        panel.orderOut(nil)
        toast?.orderOut(nil)
        NSWorkspace.shared.open(url)
    }
    func requestAccessibility() {
        closeSettings()
        logInteraction("shelf.hide", reason: "permission-settings")
        panel.orderOut(nil)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openExternal(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func renameBoard(_ board: Board) {
        let alert = NSAlert(); alert.messageText = "重命名收藏板"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.stringValue = board.name
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        presentAlert(alert) { [weak self] response in if response == .alertFirstButtonReturn { self?.store.renameBoard(board.id, to: field.stringValue) } }
    }
    func confirmRemoveBoard(_ board: Board) {
        let alert = NSAlert(); alert.messageText = "删除收藏板“\(board.name)”？"; alert.informativeText = "收藏板内的内容会保留在历史中。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        presentAlert(alert) { [weak self] response in if response == .alertFirstButtonReturn { self?.store.removeBoard(board.id) } }
    }
    func newBoard() {
        let alert = NSAlert(); alert.messageText = "新建收藏板"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.placeholderString = "例如：常用文案"
        alert.accessoryView = field; alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        presentAlert(alert) { [weak self] response in if response == .alertFirstButtonReturn { self?.store.addBoard(field.stringValue) } }
    }
    func edit(_ clip: Clip) {
        if clip.kind == "图片" { showPreview(clip); return }
        if clip.kind == "文件" { showToast("文件不能直接编辑，按 ⌘O 打开原文件"); return }
        let editTarget = store.contentEditTarget(for: clip)
        if CapturedColor.parse(clip.text) != nil {
            editorWindow?.close(); let window = auxiliaryWindow("编辑颜色", size: NSSize(width: 400, height: 340)); editorWindow = window
            window.contentView = NSHostingView(rootView: ColorEditor(clip: clip, save: { [weak self] hex in
                guard let self else { return false }
                let saved = store.saveContentEdit(.color(hex), to: editTarget, label: "颜色")
                if !saved { showToast(store.message) }
                return saved
            }, close: { [weak self] in self?.editorWindow?.close() })); window.makeKeyAndOrderFront(nil); return
        }
        editorWindow?.close()
        let window = auxiliaryWindow("编辑内容", size: NSSize(width: 700, height: 480)); editorWindow = window
        let editor = NativeEditor(clip: clip, save: { [weak self] rich in
            guard let self else { return false }
            let saved = store.saveContentEdit(.text(rich), to: editTarget)
            if !saved { showToast(store.message) }
            return saved
        }, close: { [weak self] in self?.editorWindow?.close() })
        window.contentViewController = editor; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor.text)
    }
    func importPaste(selectFile: Bool = false) {
        guard store.canModifyHistory else { showToast(store.historyModificationNotice); return }
        guard !store.importingPaste, !store.changingDataDirectory else { return }
        if selectFile {
            let picker = NSOpenPanel(); picker.title = "选择 Paste 数据库"; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
            guard let parent = settingsWindow else { return }
            picker.beginSheetModal(for: parent) { response in if response == .OK, let url = picker.url { self.readPaste(urls: [url]) } }
            picker.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
        } else { readPaste(urls: PasteImport.candidates) }
    }
    private func readPaste(urls: [URL]) {
        guard store.canModifyHistory else { showToast(store.historyModificationNotice); return }
        store.importingPaste = true
        store.beginTemporaryPause()
        let existing = store.archive
        store.importProgress = ImportProgress(phase: "准备解析", completed: 0, total: 0)
        let destination = store.root
        let progress: (ImportProgress) -> Void = { update in DispatchQueue.main.async { self.store.importProgress = update } }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PasteImport.read(existing: existing, urls: urls, destination: destination, progress: progress) }
            DispatchQueue.main.async {
                self.store.importingPaste = false
                self.store.endTemporaryPause()
                switch result {
                case .failure(let error):
                    let alert = NSAlert(); alert.messageText = "无法导入 Paste"; alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "好")
                    self.presentAlert(alert) { _ in }
                case .success(let result):
                    let alert = NSAlert(); alert.messageText = "从 Paste 导入"
                    alert.informativeText = result.summary + "\n去重后内容用量：\(ByteCountFormatter.string(fromByteCount: Int64(result.storageBytes), countStyle: .file))。按磁盘可用空间导入，不再设 2 GB 上限。\n\n保留时间、来源、收藏分组和原始格式。原有历史不会删除；导入前会自动备份。文件条目保留引用，原文件需仍然存在。"
                    alert.addButton(withTitle: "导入"); alert.addButton(withTitle: "取消")
                    self.presentAlert(alert) { response in
                        guard response == .alertFirstButtonReturn, self.store.canModifyHistory else { return }
                        self.store.importingPaste = true
                        // Freeze recording during the transactional write, then restore its state.
                        self.store.beginTemporaryPause()
                        self.logInteraction("shelf.hide", reason: "import")
                        self.panel.orderOut(nil)
                        self.store.invalidatePendingStorageCallbacks()
                        let storageGeneration = self.store.storageCallbackGeneration
                        let snapshot = self.store.archive; let root = self.store.root
                        let syncBaseline = self.store.syncBaseline
                        let syncDevice = self.store.deviceIDForPersistence()
                        self.store.settings = true
                        self.store.importProgress = ImportProgress(phase: "准备导入", completed: 0, total: result.clips.count)
                        self.store.message = "正在保存导入数据…"
                        self.store.persistenceQueue.async {
                            let outcome = Result { try PasteImport.commit(result, snapshot: snapshot, root: root,
                                                                         syncBaseline: syncBaseline, syncDevice: syncDevice,
                                                                         progress: progress) }
                            DispatchQueue.main.async {
                                let current = self.store.storageCallbackGeneration == storageGeneration && self.store.root.standardizedFileURL == root.standardizedFileURL
                                if current {
                                    switch outcome {
                                    case .success(let (merged, added, synchronized)):
                                        if let synchronized { self.store.syncBaseline = synchronized }
                                        self.store.installImportedArchive(merged)
                                        let omitted = result.unreadable + result.oversized + result.capacity + max(0, result.clips.count - added)
                                        self.store.message = "已导入 \(added) 条；重复 \(result.duplicate) 条；其他跳过 \(omitted) 条。导入前的历史已备份。"
                                    case .failure(let error): self.store.message = "导入失败：\(error.localizedDescription)"
                                    }
                                } else {
                                    self.store.message = "导入结果已取消：数据目录状态已经变化。"
                                }
                                self.store.importingPaste = false; self.store.endTemporaryPause()
                                // The final save persists either the installed import or the
                                // unchanged archive after a failure, replacing saves cancelled
                                // when the transaction boundary was established.
                                self.store.save()
                            }
                        }
                    }
                }
            }
        }
    }
    func confirmClear() {
        let alert = NSAlert(); alert.messageText = "清空未收藏的历史？"; alert.informativeText = "收藏板中的内容将保留。此操作无法撤销。"; alert.addButton(withTitle: "清空历史"); alert.addButton(withTitle: "取消")
        presentAlert(alert) { [weak self] response in if response == .alertFirstButtonReturn { self?.store.clearHistory() } }
    }
}

struct ShelfView: View {
    @State private var resizeStart: CGFloat?
    @State private var lastRevealed: UUID?
    @ObservedObject var store: Store
    /// Position of the card strip. Held as a plain reference, so the shelf itself does not re-render on every animation
    /// frame; only the strip observes it.
    let driver: FocusDriver
    @FocusState private var searchFocused: Bool
    /// Text typed in the field; committed to the store after a short pause so large
    /// histories are not re-filtered per keystroke or during input-method composition.
    @State private var draftQuery = ""
    @State private var queryCommit: DispatchWorkItem?
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.clear).frame(height: 6).contentShape(Rectangle())
                .overlay(Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 36, height: 2))
                .gesture(DragGesture().onChanged { value in if resizeStart == nil { resizeStart = Controller.shared.panel.frame.height }; Controller.shared.resizeShelf((resizeStart ?? 300) - value.translation.height) }.onEnded { _ in resizeStart = nil })
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if !store.searchExpanded {
                Button { store.searchExpanded.toggle(); store.searchFocused = store.searchExpanded; if !store.searchExpanded { resetSearch() } } label: { Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("搜索 · ⌘F")
                }
                if store.searchExpanded {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(searchFocused ? Color.blue : Color.secondary)
                    TextField("搜索文字、链接或来源", text: $draftQuery).textFieldStyle(.plain).focused($searchFocused).frame(width: 190)
                    if !draftQuery.isEmpty { Button { draftQuery = ""; store.query = ""; store.searchFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("清空搜索") }
                    else { Text("⌘F").font(.system(size: 10)).foregroundStyle(.tertiary).frame(height: 14) }
                    Text(store.paused ? store.recordingPauseControl.status : (store.query.isEmpty && !store.filtersActive ? "\(store.filtered.count) 条" : "\(store.filtered.count) 条结果"))
                        .font(.system(size: 11)).foregroundStyle(store.paused ? Color.orange : Color.secondary).lineLimit(1).fixedSize()
                    filterButton
                    Button { resetSearch(); store.searchExpanded = false; store.searchFocused = false; Controller.shared.panel.makeFirstResponder(Controller.shared.panel.contentView) } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("退出搜索 · Esc")
                }.padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(searchFocused ? Color.blue.opacity(0.65) : Color.primary.opacity(0.1)))
                }
                tab("历史", icon: "clock.arrow.circlepath", active: store.board == nil) { store.board = nil }
                ForEach(store.archive.boards) { board in
                    Button { store.board = board.id } label: {
                        HStack(spacing: 7) {
                            Circle().fill(boardColor(board.color)).frame(width: 9, height: 9)
                            Text(board.name)
                        }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(store.board == board.id ? boardColor(board.color).opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(Color.primary)
                    }.buttonStyle(.plain).help("右键更改收藏板颜色")
                        // The private type only marks card drags as acceptable; which cards come from the drag counter, so the
                        // drop never reads data (a link card over Messages withholds it) and never takes a stale earlier drag.
                        .onDrop(of: ["io.github.SwallOwDili.OpenPaste.clip-id"], isTargeted: nil) { _ in
                            guard let ids = store.takeOwnDrag() else { return false }
                            for id in ids { if let clip = store.archive.clips.first(where: { $0.id == id }), !clip.boards.contains(board.id) { store.pin(clip, to: board.id) } }
                            if TestMode.featureUI { print("UI board pinned \(ids.count) items"); fflush(stdout) }
                            return true
                        }
                        .overlay {
                            RightClickMenu {
                                BoardMenuBuilder.menu(for: board,
                                                      rename: { Controller.shared.renameBoard(board) },
                                                      delete: { Controller.shared.confirmRemoveBoard(board) },
                                                      pick: { store.setBoardColor(board.id, color: $0) })
                            }
                        }
                }
                Button(action: { Controller.shared.newBoard() }) { Image(systemName: "plus") }.buttonStyle(.plain).help("新建收藏板")
                Spacer(minLength: 0)
                Menu {
                    Button("所选加入粘贴队列") { Controller.shared.enqueueSelection() }
                    Button("粘贴队列下一条 · ⌘↵") { Controller.shared.pasteNext() }.disabled(store.pasteQueue.isEmpty)
                    Button("新建文字 · ⌘N") { Controller.shared.createText() }
                    Button("撤销 · ⌘Z") { store.undoItemChange() }.disabled(store.undoItems.isEmpty)
                    Button("设置…") { Controller.shared.openSettingsFromMenu() }
                    Button(store.recordingPauseControl.buttonTitle + (store.recordingPauseControl.action == .pause ? "… · ⌘T" : "")) {
                        if store.recordingPauseControl.action == .pause { Controller.shared.pauseMenu() }
                        else { Controller.shared.togglePause() }
                    }.disabled(store.recordingPauseControl.action == .unavailable)
                    Divider()
                    Text("← → 选择 · ↵ 粘贴 · \(store.shelfShortcuts.quickPasteLabel) 快速粘贴")
                    Button("关闭 · Esc") { Controller.shared.hideShelf() }
                } label: { Image(systemName: "ellipsis").font(.system(size: 16)).foregroundStyle(.secondary) }.menuStyle(.borderlessButton).fixedSize().help("更多")
            }.frame(height: 34).padding(.horizontal, 20).padding(.vertical, 12)
            if !store.pasteQueue.isEmpty { HStack { Text("粘贴队列剩余 \(store.pasteQueue.count) 条"); Button("下一条 · ⌘↵") { Controller.shared.pasteNext() }; Button("结束") { store.pasteQueue.removeAll() } }.font(.caption) }
            if !store.ocrProgress.isEmpty { Text(store.ocrProgress).font(.caption).foregroundStyle(.secondary) }
            if !store.captureNotice.isEmpty { Text(store.captureNotice).font(.system(size: 12)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 4) }
            Group {
            if store.filtered.isEmpty {
                VStack(spacing: 10) { Image(systemName: store.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass").font(.system(size: 35)).foregroundStyle(.tertiary); Text(store.query.isEmpty ? "复制一些内容，它们会出现在这里" : "没有找到“\(store.query)”").foregroundStyle(.secondary); Text(store.query.isEmpty ? "\(store.shortcutLabel) 随时打开 · 所有数据保存在本机" : "搜索文字、链接和来源应用；图片文字将在后台识别后加入搜索").font(.system(size: 12)).foregroundStyle(.tertiary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in DockStrip(store: store, driver: driver, size: geometry.size) }
                    .onAppear { driver.snap(to: focusIndex); lastRevealed = store.selected }
                    .onChange(of: store.selected) { _, id in if let id { reveal(id) } }
                    // The selected card's index changed under the same selection (a clip was inserted or removed before it).
                    .onChange(of: focusIndex) { _, index in
                        guard store.selected == lastRevealed, Int(driver.target) != index else { return }
                        driver.follow(index: index)
                    }
            }
            }
            // Both overlays float above the cards and take no layout space, so searching or a status message never changes
            // the card height. Cards are full height at rest, so they are drawn as a deliberate floating layer (material,
            // hairline, shadow) instead of bare controls sitting on the card headers.
            .overlay(alignment: .top) { searchSuggestions }
            .overlay(alignment: .bottom) { translationBadge }
            if !store.directPasteAuthorized {
                HStack { Text("↵ 复制后按 ⌘V 粘贴").foregroundStyle(.secondary); Button("开启直接粘贴…") { Controller.shared.openSettings() }.buttonStyle(.plain).foregroundStyle(.blue); Spacer() }.font(.system(size: 11)).padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .overlayPreferenceValue(FunnelAnchorKey.self) { anchor in filterLayer(anchor) }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.2)).frame(height: 1) }
        .onChange(of: store.query) { _, query in
            if draftQuery != query { draftQuery = query }
            if !query.isEmpty { store.indexImages() }
        }
        .onChange(of: draftQuery) { _, value in
            queryCommit?.cancel()
            guard value != store.query else { return }
            if value.isEmpty { store.query = value; return }
            let work = DispatchWorkItem { [weak store] in
                guard let store else { return }
                // Wait until the input method has committed its marked text.
                if let editor = Controller.shared?.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return }
                store.query = value
            }
            queryCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        .onChange(of: store.searchFocused) { _, focused in
            if focused { store.searchExpanded = true; DispatchQueue.main.async { searchFocused = true } }
            else {
                searchFocused = false
                // Pressing the filter button blurs the field before the mouse is released. Collapsing at once would remove the
                // button mid-click, so the empty search is only closed if it is still idle shortly afterwards.
                collapseIdleSearchSoon()
            }
        }
        // Closing the filter card without choosing anything leaves an empty, unfocused search: close it as well.
        .onChange(of: store.filtersExpanded) { _, expanded in if !expanded { collapseIdleSearchSoon() } }
        .onChange(of: searchFocused) { _, focused in if store.searchFocused != focused { store.searchFocused = focused } }

    }
    /// Closes the search field shortly, if by then it is still empty, unfocused and no filter or filter card is open.
    private func collapseIdleSearchSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [store] in
            if !store.searchFocused && !store.filtersExpanded && store.query.isEmpty && !store.filtersActive { store.searchExpanded = false }
        }
    }
    /// Index of the selected card in the visible results (0 when nothing is selected).
    private var focusIndex: Int { store.selected.flatMap { store.visibleIndex(of: $0) } ?? 0 }
    /// "Apply source" / "date" shortcuts for the text typed in the search field. Shown only when there is something to
    /// apply, so no empty container is ever drawn; only the container itself takes clicks.
    @ViewBuilder
    private var searchSuggestions: some View {
        let sources = Array(store.sources.filter { $0.localizedCaseInsensitiveContains(store.query) }.prefix(3))
        let dateWord = ["今天", "本周", "本月"].contains(store.query)
        if store.searchExpanded && !store.query.isEmpty && !store.filtersExpanded && (!sources.isEmpty || dateWord) {
            HStack(spacing: 6) {
                ForEach(sources, id: \.self) { source in
                    suggestionChip("应用：" + source) { store.sourceFilter = source; store.query = "" }
                }
                if dateWord {
                    suggestionChip("日期：" + store.query) {
                        let days = store.query == "今天" ? 0 : (store.query == "本周" ? 7 : 30)
                        store.startDate = Date().addingTimeInterval(-Double(days * 86400)); store.endDate = Date(); store.dateRangeEnabled = true; store.query = ""
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .floatingCapsule()
            .padding(.top, 6)
            .transition(.opacity)
        }
    }
    private func suggestionChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .frame(maxWidth: 180)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }
    /// Widest text of the translation tip before it wraps.
    private static let tipTextWidth: CGFloat = 340
    /// Translation status (translating, done, failed, skipped). Centred at the bottom so it never covers the character
    /// count in the bottom-left corner of rich-text cards, and it lets clicks through to the cards.
    @ViewBuilder
    private var translationBadge: some View {
        if !store.translationStatus.isEmpty {
            // A small tip: it hugs its text. A flexible frame (`maxWidth`) would stretch it to the full width, so the width
            // is only fixed when the message is longer than a tip should be, and then it wraps to at most two lines.
            let tipFont = NSFont.systemFont(ofSize: 11)
            let wraps = (store.translationStatus as NSString).size(withAttributes: [.font: tipFont]).width + 2 > Self.tipTextWidth
            HStack(spacing: 5) {
                if store.translating { ProgressView().controlSize(.mini).scaleEffect(0.85) }
                else { Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary) }
                Text(store.translationStatus).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: wraps ? Self.tipTextWidth : nil, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .floatingCapsule()
            .padding(.horizontal, 24).padding(.bottom, 10)
            .allowsHitTesting(false)
        }
    }
    /// Type, source, today and date-range filters live in one small card so the header stays a single row. It is drawn
    /// inside the shelf (not an AppKit popover window), so opening it never changes the panel's key window or the
    /// search field's focus.
    private var filterButton: some View {
        Button { withFilterCardAnimation { store.filtersExpanded.toggle() } } label: {
            Image(systemName: store.filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 14)).foregroundStyle(store.filtersActive ? Color.blue : Color.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).help("筛选 · ⌘F")
        .anchorPreference(key: FunnelAnchorKey.self, value: .bounds) { $0 }
    }
    /// The filter card hangs under the funnel button with a small caret pointing at it; a click anywhere else closes it.
    private func filterLayer(_ anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { geometry in
            if store.filtersExpanded, let anchor {
                let frame = geometry[anchor]
                let width: CGFloat = 440
                let x = min(max(frame.midX - width / 2, 12), max(12, geometry.size.width - width - 12))
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { withFilterCardAnimation { store.filtersExpanded = false } }
                    // On a short (compact) shelf the card may not fit below the button; it then scrolls inside itself.
                    filterCard(width: width, caretX: frame.midX - x, maxHeight: max(80, geometry.size.height - frame.maxY - 8))
                        .offset(x: x, y: frame.maxY + 2)
                        .transition(.scale(scale: 0.97, anchor: UnitPoint(x: frame.midX / max(geometry.size.width, 1), y: 0)).combined(with: .opacity))
                }
            }
        }
        .allowsHitTesting(store.filtersExpanded)
    }
    private var timeScope: Binding<FilterTimeScope> {
        Binding(get: { store.timeScope }, set: { store.setTimeScope($0) })
    }
    private func filterCard(width: CGFloat, caretX: CGFloat, maxHeight: CGFloat) -> some View {
        let kinds: [FilterSegmentOption<String>] = [
            .init(value: "全部", title: "全部", symbol: "square.grid.2x2", tint: nil),
            .init(value: "文字", title: "文字", symbol: "text.alignleft", tint: .teal),
            .init(value: "链接", title: "链接", symbol: "link", tint: .blue),
            .init(value: "图片", title: "图片", symbol: "photo", tint: .purple),
            .init(value: "文件", title: "文件", symbol: "folder", tint: .orange),
            .init(value: "颜色", title: "颜色", symbol: "paintpalette", tint: .pink)]
        let times: [FilterSegmentOption<FilterTimeScope>] = [
            .init(value: .any, title: "不限", symbol: nil, tint: nil),
            .init(value: .today, title: "今天", symbol: nil, tint: nil),
            .init(value: .custom, title: "自定义", symbol: nil, tint: nil)]
        let sourceActive = store.sourceFilter != "全部来源"
        let shape = FilterCardShape(caretX: caretX)
        let content = VStack(alignment: .leading, spacing: 10) {
            FilterSegmented(options: kinds, selection: $store.kind)
            HStack(spacing: 8) {
                Menu {
                    Button("全部来源") { store.sourceFilter = "全部来源" }
                    ForEach(store.sources, id: \.self) { source in Button(source) { store.sourceFilter = source } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "app.dashed").font(.system(size: 12))
                        Text(store.sourceFilter).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.6)
                    }
                    .foregroundStyle(sourceActive ? Color.accentColor : Color.primary.opacity(0.8))
                    .padding(.horizontal, 10).frame(height: 30).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(sourceActive ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(sourceActive ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08)))
                    .contentShape(Rectangle())
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                FilterSegmented(options: times, selection: timeScope).frame(width: 190)
            }
            if store.dateRangeEnabled {
                HStack(spacing: 8) {
                    Text("从").font(.system(size: 12)).foregroundStyle(.secondary)
                    DatePicker("开始", selection: $store.startDate, displayedComponents: .date).labelsHidden().datePickerStyle(.compact)
                    Text("至").font(.system(size: 12)).foregroundStyle(.secondary)
                    DatePicker("结束", selection: $store.endDate, in: store.startDate..., displayedComponents: .date).labelsHidden().datePickerStyle(.compact)
                    Spacer(minLength: 0)
                }.transition(.opacity)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(store.filtered.count.formatted()).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Text("条结果").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                // Clears only what this card sets; the search text stays.
                Button { store.clearFilters() } label: {
                    Text("清除筛选").font(.system(size: 12, weight: .medium)).foregroundStyle(store.filtersActive ? Color.accentColor : Color.secondary.opacity(0.5))
                }.buttonStyle(.plain).disabled(!store.filtersActive)
            }.padding(.horizontal, 2)
        }
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 12 + FilterCardShape.caretHeight)
        return ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }
        }
        .frame(width: width)
        .background { shape.fill(.regularMaterial); shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.62)) }
        .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.14), radius: 22, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15), value: store.dateRangeEnabled)
        .frame(maxHeight: maxHeight, alignment: .top)
    }
    /// Brings the new selection to the middle of the shelf. The focus glides there (or snaps for far jumps such as search
    /// and filters); near either end the strip stops at its padding, so the selection sits off-centre there instead.
    func reveal(_ id: UUID) {
        // Read and clear the arrow-key flag right away, so the decision belongs to this selection change.
        let byKeyboard = store.keyboardNavigated
        store.keyboardNavigated = false
        guard let index = store.visibleIndex(of: id) else { return }
        lastRevealed = id
        // The Dock effect belongs to the arrow keys only: clicks, search and board switches leave the cards at full size.
        driver.move(to: index, keyboard: byKeyboard, magnify: byKeyboard && store.arrowKeyMagnification)
    }
    func resetSearch() { store.resetFilters(preserveBoard: true, preserveDateRange: true) }
    func tab(_ name: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(name, systemImage: icon).font(.system(size: 13, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6).background(active ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(Color.primary) }.buttonStyle(.plain)
    }
}
func boardColor(_ name: String?) -> Color {
    switch name {
    case "橙色": return .orange
    case "黄色": return .yellow
    case "绿色": return .green
    case "青色": return .cyan
    case "蓝色": return .blue
    case "紫色": return .purple
    case "灰色": return .gray
    default: return .red
    }
}
func ageLabel(_ date: Date, now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
    if minutes == 0 { return "刚刚" }
    if minutes < 60 { return "\(minutes) 分钟前" }
    if minutes < 1440 { return "\(minutes / 60) 小时前" }
    return "\(minutes / 1440) 天前"
}

private extension View {
    /// Material capsule with a hairline and a soft shadow, for short transient labels that float over the cards.
    func floatingCapsule() -> some View {
        background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
    }
}

struct FunnelAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

enum FilterTimeScope: Hashable { case any, today, custom }

struct FilterSegmentOption<Value: Hashable> {
    let value: Value
    let title: String
    let symbol: String?
    /// Colour of the icon while selected; the card header colours, so a filter looks like the cards it picks out.
    let tint: Color?
}

/// A track with a white pill that slides to the selected segment.
struct FilterSegmented<Value: Hashable>: View {
    let options: [FilterSegmentOption<Value>]
    @Binding var selection: Value
    @Namespace private var pill
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let on = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 4) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(on ? (option.tint ?? Color.primary) : Color.secondary.opacity(0.8))
                        }
                        Text(option.title).font(.system(size: 12, weight: on ? .semibold : .medium)).foregroundStyle(on ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(colorScheme == .dark ? Color.white.opacity(0.17) : Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 1.5, y: 1)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
    }
}

/// Rounded card outline with a small caret on the top edge, drawn as one path so the caret and the card share one border.
struct FilterCardShape: Shape {
    var caretX: CGFloat
    static let caretHeight: CGFloat = 8
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 16, w: CGFloat = 18
        let top = rect.minY + Self.caretHeight
        let cx = min(max(caretX, r + w / 2), rect.width - r - w / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: top))
        p.addLine(to: CGPoint(x: cx - w / 2, y: top))
        p.addLine(to: CGPoint(x: cx, y: rect.minY))
        p.addLine(to: CGPoint(x: cx + w / 2, y: top))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: top))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: top + r), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: rect.minX, y: top + r))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.minX + r, y: top), radius: r)
        p.closeSubpath()
        return p
    }
}

/// Whether `event` is the second (or later) click of a double-click. `clickCount` may only be read on mouse events (it
/// raises on any other type), so anything else counts as a single click.
func isDoubleClick(_ event: NSEvent?) -> Bool {
    guard let event, [.leftMouseDown, .leftMouseUp].contains(event.type) else { return false }
    return event.clickCount >= 2
}

/// Opens or closes the filter card with its short animation (none with reduced motion). Only the user's own actions go
/// through here; showing or hiding the shelf sets the flag directly, so the card never animates while the shelf appears.
func withFilterCardAnimation(_ change: () -> Void) {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { change() } else { withAnimation(.easeOut(duration: 0.16), change) }
}

/// A visible card and its position in the results.
private struct StripItem: Identifiable {
    let index: Int
    let clip: Clip
    var id: UUID { clip.id }
}

/// The shelf's card strip. It places the cards itself from one shared frame (focus, magnification, pan), so no scroll
/// view can hold a position that disagrees with where the cards are drawn. Only cards near the screen are built
/// (`FocusDriver.keptRange`); built cards that are off screen are parked at one fixed spot, so they cost nothing per
/// frame and are not rebuilt when they come back.
struct DockStrip: View {
    @ObservedObject var store: Store
    @ObservedObject var driver: FocusDriver
    let size: CGSize
    var body: some View {
        let clips = store.filtered
        let padding = CardMagnification.stripVerticalPadding
        let height = max(0, size.height - padding * 2)
        // Square cards: the width follows the height the strip leaves for a card.
        let cardWidth = CardMagnification.cardWidth(compact: store.compact, cardHeight: height)
        let leading: CGFloat = store.translating ? cardWidth + CardMagnification.spacing : 0
        let frame = driver.frame(count: clips.count, cardWidth: cardWidth, size: size, extraLeading: leading)
        let visible = frame.visible()
        let items = driver.keptRange(around: visible, count: clips.count).map { StripItem(index: $0, clip: clips[$0]) }
        let parked = -(cardWidth + 100)
        ZStack(alignment: .topLeading) {
            if store.translating {
                VStack(spacing: 12) { ProgressView(); Text("正在翻译…"); Text("原文保持不变").font(.caption).foregroundStyle(.secondary) }
                    .frame(width: cardWidth, height: height).background(.quaternary, in: CardChrome.shape())
                    .offset(x: frame.firstLeft - leading, y: padding)
            }
            ForEach(items) { item in
                let onScreen = visible.contains(item.index)
                let scale = onScreen ? frame.scale(item.index) : 1
                ClipCard(clip: item.clip, index: item.index, selected: store.selection.contains(item.clip.id) || item.clip.id == store.selected, current: item.clip.id == store.currentClipID, renaming: store.renamingID == item.clip.id, compact: store.compact, networkPreviews: store.networkPreviews, boards: store.archive.boards, store: store, cardHeight: height, quickSymbol: store.shelfShortcuts.quickPaste.symbol).equatable()
                    .frame(width: cardWidth, height: height)
                    .scaleEffect(scale, anchor: .bottom)
                    .offset(x: onScreen ? frame.centre(item.index) - cardWidth / 2 : parked, y: padding)
                    // Magnified cards reach over their neighbours, so larger cards draw on top.
                    .zIndex(Double(scale))
                    .allowsHitTesting(onScreen)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .background(StripHost(driver: driver))
    }
}

/// The strip's AppKit view: the display link and the preview popover's anchor come from it, and scroll events over it
/// pan the strip.
private struct StripHost: NSViewRepresentable {
    let driver: FocusDriver
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        driver.hostView = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        if driver.hostView !== view { driver.hostView = view }
    }
}

struct ClipCard: View, Equatable {
    let clip: Clip
    let index: Int
    let selected: Bool
    let current: Bool
    let renaming: Bool
    let compact: Bool
    let networkPreviews: Bool
    let boards: [Board]
    let store: Store
    /// Height the strip gives the card; it picks the header size class.
    var cardHeight: CGFloat = 0
    /// Symbol of the quick-paste modifier, shown before the index.
    var quickSymbol = "⌘"
    var compactHeader: Bool { CardChrome.compactHeader(cardHeight: cardHeight, compact: compact) }
    /// A link preview with an image runs full bleed: under the header, which becomes a scrim,
    /// and down to the card's bottom edge, with the index inside the caption bar.
    @State private var linkCover = false
    /// A link preview bubble is shown, with or without an image: it reaches the bottom edge and carries the index.
    @State private var linkBubble = false
    /// The file was read as audio: the header says “音频” instead of “文件”.
    @State private var audioParsed = false
    /// Page colour of a rich text card, picked from its text; nil until the text is parsed.
    @State private var richPage: NSColor?
    @Environment(\.colorScheme) private var colorScheme
    var headerTitle: String { audioParsed && clip.showsAudioTitle ? "音频" : clip.cardTitle }
    /// Header height for the card's size class.
    var headerHeight: CGFloat { CardChrome.headerHeight(cardHeight: cardHeight, compact: compact) }
    /// A click on an already selected card's title renames it; otherwise it selects the card.
    func titleTapped() {
        if selected && store.selection.count <= 1 { Controller.shared.rename(clip) }
        else { store.searchFocused = false; store.choose(clip.id, modifiers: NSEvent.modifierFlags); Controller.shared.panel.makeFirstResponder(Controller.shared.panel.contentView) }
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.clip.id == rhs.clip.id
            && lhs.clip.cachedDigest == rhs.clip.cachedDigest
            && lhs.index == rhs.index
            && lhs.selected == rhs.selected
            && lhs.current == rhs.current
            && lhs.renaming == rhs.renaming
            && lhs.compact == rhs.compact
            && lhs.cardHeight == rhs.cardHeight
            && lhs.quickSymbol == rhs.quickSymbol
            && lhs.networkPreviews == rhs.networkPreviews
            && lhs.boards == rhs.boards
            && lhs.store === rhs.store
            && lhs.clip.title == rhs.clip.title
            && lhs.clip.userLabel == rhs.clip.userLabel
            && lhs.clip.text == rhs.clip.text
            && lhs.clip.kind == rhs.clip.kind
            && lhs.clip.boards == rhs.clip.boards
            && lhs.clip.created == rhs.clip.created
            && lhs.clip.source == rhs.clip.source
            && lhs.clip.sourceID == rhs.clip.sourceID
            && lhs.clip.ocrText == rhs.clip.ocrText
            && lhs.clip.linkTitle == rhs.clip.linkTitle
            && (lhs.clip.cachedDigest != nil || lhs.clip.parts == rhs.clip.parts)
    }
    var color: Color { if clip.kind == "文字", CodeSyntax.language(clip.text) != nil { return .purple }; switch clip.kind { case "链接": return .blue; case "图片": return .purple; case "文件": return .orange; default: return .teal } }
    /// Header colour: the source app icon's dominant colour, falling back to the content-type colour.
    var headerFill: Color { PreviewCache.shared.accentColor(clip.sourceID).map { Color(nsColor: $0) } ?? color.opacity(0.85) }
    var characterCountLabel: String? {
        guard clip.kind == "文字" else { return nil }
        let bytes = clip.text.utf8.count
        return bytes > 200_000 ? "20 万+ 字符" : "\(clip.text.count) 个字符"
    }
    var icon: String { switch clip.kind { case "链接": return "link"; case "图片": return "photo"; case "文件": return "folder"; default: return "text.alignleft" } }
    /// What a card shows, decided once from the clip; the layout rules below read it instead of re-testing the clip.
    private enum BodyKind {
        case link, color(CapturedColor), code, richText, image, audio, file, text, other
        init(_ clip: Clip) {
            let color = clip.kind == "链接" ? nil : CapturedColor.parse(clip.text)
            let code = clip.kind == "文字" && CodeSyntax.language(clip.text) != nil
            if clip.kind == "链接" { self = .link }
            else if let color { self = .color(color) }
            else if code { self = .code }
            else if clip.kind == "文字" && RichTextCache.hasRichPart(clip) { self = .richText }
            else if clip.kind == "图片" { self = .image }
            else if clip.kind == "文件" { self = !clip.text.contains("\n") && AudioInfo.isAudio(URL(fileURLWithPath: clip.text)) ? .audio : .file }
            else { self = clip.kind == "文字" ? .text : .other }
        }
        /// Text on a page colour: rich text or plain text (not code, not a colour).
        var isTextPage: Bool { switch self { case .richText, .text: true; default: false } }
        var isCode: Bool { if case .code = self { true } else { false } }
        var capturedColor: CapturedColor? { if case .color(let color) = self { color } else { nil } }
    }
    /// Quick-paste label of the first nine cards, such as “⌘3”.
    private var indexLabel: String? { index < 9 ? quickSymbol + "\(index + 1)" : nil }
    private static let codeBackground = Color(white: 0.14)

    // MARK: Layout rules
    /// Text starts 10 below the header with 12 at the sides; link, image and file cards pad themselves.
    private func bodyInsets(_ kind: BodyKind) -> EdgeInsets {
        if clip.kind == "链接" || clip.kind == "图片" || clip.kind == "文件" { return EdgeInsets() }
        return EdgeInsets(top: kind.isTextPage ? 10 : 12, leading: 12, bottom: 12, trailing: 12)
    }
    /// Link bubbles, full-bleed covers, audio and image cards carry the index themselves and leave out the footer.
    private func showsFooter(_ kind: BodyKind) -> Bool {
        if linkCover || (clip.kind == "链接" && linkBubble) || clip.kind == "图片" { return false }
        if case .audio = kind { return false }
        return !compact || index < 9
    }
    /// Whether the footer sits on a dark surface: a colour card by its colour, code always, text by its page, the rest by appearance.
    private func footerIsOnDark(_ kind: BodyKind, textPage: NSColor) -> Bool {
        if let color = kind.capturedColor { return RichTextRendering.isDark(color.nsColor) }
        if kind.isCode { return true }
        return kind.isTextPage ? RichTextRendering.isDark(textPage) : colorScheme == .dark
    }
    private func cardBackground(_ kind: BodyKind, textPage: NSColor) -> Color {
        if let color = kind.capturedColor { return Color(nsColor: color.nsColor) }
        if kind.isCode { return Self.codeBackground }
        return kind.isTextPage ? Color(nsColor: textPage) : Color(nsColor: .controlBackgroundColor)
    }

    // MARK: Pieces
    private var header: some View {
        ZStack(alignment: .topTrailing) {
            if !linkCover { Rectangle().fill(headerFill) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if renaming { RenameField(initial: clip.cardTitle) { text in Controller.shared.commitInlineRename(clip.id, text: text) } }
                    else {
                        Text(headerTitle).font(.system(size: compactHeader ? 13 : 15, weight: compactHeader ? .semibold : .medium)).lineLimit(1).truncationMode(.tail).help(headerTitle)
                            .opacity(compactHeader ? 0.85 : 1).onTapGesture(perform: titleTapped)
                    }
                    if current { Text("当前").font(.system(size: 10)).opacity(0.75) }; if !clip.boards.isEmpty { Image(systemName: "pin.fill").font(.system(size: 10)) }
                    // The compact header keeps the time on the title's line.
                    if compactHeader, !renaming { TimelineView(.periodic(from: .now, by: 60)) { context in Text(ageLabel(clip.created, now: context.date)).font(.system(size: 13)).opacity(0.55).lineLimit(1).fixedSize() } }
                }
                if !compactHeader { TimelineView(.periodic(from: .now, by: 60)) { context in Text(ageLabel(clip.created, now: context.date)).font(.system(size: 12)).opacity(0.8) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 12).padding(.trailing, CardChrome.titleTrailing(cardHeight: cardHeight, compact: compact))
        }
        .foregroundStyle(.white).shadow(color: linkCover ? .black.opacity(0.45) : .clear, radius: 3, y: 1)
        .frame(height: headerHeight)
        // The icon is an overlay so its size never feeds the header's layout: inside the ZStack its
        // taller frame made the ZStack taller, and the fixed-height frame then centred it, lifting the
        // icon by half the difference and leaving a strip of header below it.
        .overlay(alignment: .trailing) { sourceIcon.opacity(linkCover ? CardChrome.coverIconOpacity : 1) }
        .clipped()
        .zIndex(1)
    }
    /// The source app's icon. Regular header: the artwork is 1.235 × the header height, centred vertically so it
    /// overhangs top and bottom equally, overhangs the card's right edge by 0.115 ×, with a faint shadow on the left
    /// (macOS app icons keep their artwork in the central 824/1024). Compact header: a 20 pt icon inside the header,
    /// 8 pt from the right edge, at 90%.
    @ViewBuilder private var sourceIcon: some View {
        if let sourceIcon = PreviewCache.shared.sourceIcon(clip.sourceID) {
            if compactHeader {
                Image(nsImage: sourceIcon).resizable().scaledToFit().frame(width: 20, height: 20).opacity(0.9).padding(.trailing, 8).help(clip.source)
            } else {
                let artwork = headerHeight * 1.235, canvas = artwork * 1024 / 824, inset = (canvas - artwork) / 2
                Image(nsImage: sourceIcon).resizable().scaledToFit()
                    .frame(width: canvas, height: canvas)
                    .shadow(color: .black.opacity(0.18), radius: 2, x: -1, y: 0)
                    .offset(x: inset + headerHeight * 0.115).help(clip.source)
            }
        } else {
            Image(systemName: icon).font(.system(size: compactHeader ? 16 : 32)).opacity(0.6).padding(.trailing, compactHeader ? 8 : 14).help(clip.source)
        }
    }
    @ViewBuilder private func bodyContent(_ kind: BodyKind) -> some View {
        switch kind {
        case .link:
            RichLinkCard(clip: clip, enabled: networkPreviews, store: store, indexLabel: indexLabel, titleTap: titleTapped, cover: $linkCover, bubble: $linkBubble, headerHeight: headerHeight).id(clip.text)
        case .color(let color):
            // The colour fills the card, its value centred in black or white by lightness.
            Text(color.hex).font(Font(NSFont.userFixedPitchFont(ofSize: 18) ?? .monospacedSystemFont(ofSize: 18, weight: .regular))).textSelection(.enabled)
                .foregroundStyle(Color(nsColor: RichTextRendering.labelColor(onDark: RichTextRendering.isDark(color.nsColor))))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .code:
            CodeCardBody(text: clip.text, compact: compact)
        case .richText:
            RichTextCardBody(clip: clip, compact: compact, page: $richPage)
        case .image:
            ImageCardBody(clip: clip, compact: compact, indexLabel: indexLabel).allowsHitTesting(false)
        case .audio:
            AudioCardBody(path: clip.text, compact: compact, indexLabel: indexLabel, parsed: $audioParsed, rename: titleTapped).id(clip.text)
        case .file:
            FileCardBody(clip: clip, compact: compact, rename: titleTapped)
        case .text, .other:
            Text(String(clip.text.prefix(1500))).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
    /// Character count centred, quick-paste badge 8 pt from the right and bottom edges.
    private func footer(onDark: Bool) -> some View {
        let footerColor = Color(nsColor: RichTextRendering.footerColor(onDark: onDark))
        return ZStack {
            if !compact, let label = characterCountLabel { Text(label).font(.system(size: 12)).foregroundStyle(footerColor) }
            if let indexLabel { ShortcutBadge(label: indexLabel, onDark: onDark).frame(maxWidth: .infinity, alignment: .trailing) }
        }.frame(height: 18).padding(.horizontal, 8).padding(.bottom, 8)
    }

    var body: some View {
        let kind = BodyKind(clip)
        let plainPage = RichTextRendering.plainPage(dark: colorScheme == .dark)
        let textPage: NSColor = { if case .richText = kind { return richPage ?? plainPage } else { return plainPage } }()
        let footerOnDark = footerIsOnDark(kind, textPage: textPage)
        let cardShape = CardChrome.shape()
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 9) { bodyContent(kind) }
                .padding(bodyInsets(kind)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { Rectangle().fill(kind.isCode ? Self.codeBackground : Color.clear) }
                .padding(.top, linkCover ? -headerHeight : 0)
            if showsFooter(kind) { footer(onDark: footerOnDark) }
        }
        .frame(width: CardMagnification.cardWidth(compact: compact, cardHeight: cardHeight)).frame(maxHeight: .infinity)
        .background(cardBackground(kind, textPage: textPage), in: cardShape)
        .clipShape(cardShape)
        // The selected card is marked by a ring in the accent colour just outside it (inset by -4), without a glow.
        .overlay { if selected { CardChrome.shape(radius: CardChrome.ringRadius).strokeBorder(Color.accentColor, lineWidth: CardChrome.ringInset).padding(-CardChrome.ringInset) } }
        .shadow(color: .black.opacity(CardChrome.shadowOpacity), radius: CardChrome.shadowRadius, y: CardChrome.shadowOffsetY)
        .contentShape(Rectangle())
        .onDrag { let selected = store.selectedClips; store.beginCardDrag(selected.contains(where: { $0.id == clip.id }) ? selected.map(\.id) : [clip.id]); DragPasteRedirect.begin(clip); if TestMode.featureUI { print("UI drag began kind=\(clip.kind)"); fflush(stdout) }; return clip.dragProvider() }
        // One click handler for both: a separate double-click gesture would make SwiftUI hold every single click for the
        // double-click interval (about half a second) before selecting. The first click selects, the second pastes.
        .onTapGesture {
            if isDoubleClick(NSApp.currentEvent), store.selected == clip.id { Controller.shared.pasteSelection(fallback: clip); return }
            store.searchFocused = false; store.choose(clip.id, modifiers: NSEvent.modifierFlags); Controller.shared.panel.makeFirstResponder(Controller.shared.panel.contentView)
        }
        .contextMenu {
            Button("粘贴") { Controller.shared.pasteSelection(fallback: clip) }
            Button("预览 · 空格") { Controller.shared.showPreview(clip) }
            Button("打开 · ⌘O") { Controller.shared.openItem(clip) }
            Button("重命名 · ⌘R") { Controller.shared.rename(clip) }
            if clip.kind == "图片" { Button("编辑 · ⌘E") { Controller.shared.edit(clip) }; Button("旋转图片") { Controller.shared.rotate(clip) }; Button("提取文字") { Controller.shared.extractText(clip) } }
            if let map = MapLink.parse(clip.text) { Button("在地图中打开") { Controller.shared.openExternal(map.url) } }
            Button("仅复制") { _ = store.restore(clip, plain: false); store.message = "已复制" }
            if clip.kind == "文字" || clip.kind == "链接" || clip.kind == "颜色" {
                Button("粘贴为纯文本") { Controller.shared.paste(clip, plain: true) }
                Button("编辑 · ⌘E") { Controller.shared.edit(clip) }
            }
            Menu("收藏到") { ForEach(boards) { b in Button((clip.boards.contains(b.id) ? "✓ " : "") + b.name) { store.pin(clip, to: b.id) } }; Button("新建收藏板…") { Controller.shared.newBoard() } }
            Divider()
            Button("删除 · ⌘⌫", role: .destructive) { store.delete(clip.id) }
        }
    }
}

#if OPENPASTE_TESTING
if CommandLine.arguments.contains("--interaction-policy-test") {
    runInteractionPolicyTests()
} else if CommandLine.arguments.contains("--recording-pause-test") {
    runRecordingPauseTests()
} else if CommandLine.arguments.contains("--storage-recovery-test") {
    runStorageRecoveryTests()
} else if CommandLine.arguments.contains("--permission-monitor-test") {
    runPermissionMonitorTests()
} else if CommandLine.arguments.contains("--content-editing-test") {
    runContentEditingTests()
} else if CommandLine.arguments.contains("--capture-boundary-test") {
    runCaptureBoundaryTests()
} else if CommandLine.arguments.contains("--filter-test") {
    runFilterTests()
} else if CommandLine.arguments.contains("--paste-queue-test") {
    runPasteQueueTests()
} else if CommandLine.arguments.contains("--clipboard-write-test") {
    runClipboardWriteTests()
} else if CommandLine.arguments.contains("--update-test") {
    runUpdateTests()
} else if CommandLine.arguments.contains("--maintenance-test") {
    runMaintenanceTests()
} else if CommandLine.arguments.contains("--data-directory-test") {
    runDataDirectoryTests()
} else if CommandLine.arguments.contains("--code-style-test") {
    runCodeStyleTests()
} else if CommandLine.arguments.contains("--rich-text-decode-test") {
    runRichTextDecodingTests()
} else if CommandLine.arguments.contains("--translation-config-test") {
    runTranslationConfigTests()
} else if CommandLine.arguments.contains("--translation-test") {
    DispatchQueue.global().async {
        runTranslationTests()
        exit(0)
    }
    dispatchMain()
} else if CommandLine.arguments.contains("--drag-provider-test") {
    runDragProviderTests()
} else if CommandLine.arguments.contains("--paste-import-unit-test") {
    runPasteImportUnitTests()
} else if CommandLine.arguments.contains("--paste-import-test") {
    runPasteImportTests()
} else if CommandLine.arguments.contains("--paste-import-inspect") {
    do { let result = try PasteImport.read(existing: Archive()); print(result.summary); print("databases=\(result.databases), boards=\(result.boards.count)") } catch { print(error.localizedDescription); exit(1) }
} else if CommandLine.arguments.contains("--current-clipboard-test") {
    runCurrentClipboardTests()
} else if CommandLine.arguments.contains("--preview-cache-test") {
    runPreviewTests()
} else if CommandLine.arguments.contains("--navigation-test") {
    runNavigationTests()
} else if CommandLine.arguments.contains("--shortcut-model-test") {
    runShortcutTests()
} else if CommandLine.arguments.contains("--self-test") {
    runTests()
} else {
    let app = NSApplication.shared
    let delegate = Controller(); app.delegate = delegate
    app.run()
}

#else
let app = NSApplication.shared
let delegate = Controller(); app.delegate = delegate
app.run()
#endif

/// Title field shown on a card while it is being renamed in place.
struct RenameField: View {
    let initial: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(Color.black)
            .focused($focused)
            .onSubmit { commit(text) }
            .onAppear {
                text = initial
                DispatchQueue.main.async {
                    focused = true
                    (Controller.shared.panel.firstResponder as? NSTextView)?.selectAll(nil)
                }
            }
            .onChange(of: focused) { was, now in if was && !now { commit(text) } }
    }
}
