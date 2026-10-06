import SwiftUI
import AppKit
import Carbon
import ApplicationServices

// A small template drawing keeps the menu-bar mark crisp at either display scale.
private func menuBarMark() -> NSImage {
    let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
        NSColor.black.setStroke()
        let outline = NSBezierPath()
        outline.lineWidth = 1.45
        outline.lineJoinStyle = .round
        outline.lineCapStyle = .round
        outline.move(to: NSPoint(x: 12.5, y: 17))
        outline.line(to: NSPoint(x: 6, y: 17))
        outline.curve(to: NSPoint(x: 4, y: 15), controlPoint1: NSPoint(x: 4.7, y: 17), controlPoint2: NSPoint(x: 4, y: 16.3))
        outline.line(to: NSPoint(x: 4, y: 5))
        outline.curve(to: NSPoint(x: 6, y: 3), controlPoint1: NSPoint(x: 4, y: 3.7), controlPoint2: NSPoint(x: 4.7, y: 3))
        outline.line(to: NSPoint(x: 14, y: 3))
        outline.curve(to: NSPoint(x: 16, y: 5), controlPoint1: NSPoint(x: 15.3, y: 3), controlPoint2: NSPoint(x: 16, y: 3.7))
        outline.line(to: NSPoint(x: 16, y: 13.5))
        outline.line(to: NSPoint(x: 12.5, y: 17))
        outline.close()
        outline.stroke()
        let fold = NSBezierPath()
        fold.lineWidth = 1.15
        fold.lineJoinStyle = .round
        fold.move(to: NSPoint(x: 12.5, y: 16.5))
        fold.line(to: NSPoint(x: 12.5, y: 13.5))
        fold.line(to: NSPoint(x: 15.5, y: 13.5))
        fold.stroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1.25
        lines.lineCapStyle = .round
        lines.move(to: NSPoint(x: 7, y: 10)); lines.line(to: NSPoint(x: 12.5, y: 10))
        lines.move(to: NSPoint(x: 7, y: 7)); lines.line(to: NSPoint(x: 10.5, y: 7))
        lines.stroke()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "OpenPaste"
    return image
}

final class ShelfPanel: NSWindow { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }
final class ShelfHost: NSHostingView<ShelfView> { override var acceptsFirstResponder: Bool { true } }
final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: Controller!
    let preview = CommandLine.arguments.contains("--translation-workflow-test") || CommandLine.arguments.contains("--translation-ui-test") || CommandLine.arguments.contains("--feature-ui-test") || CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--layout-test") || CommandLine.arguments.contains("--shortcut-test") || CommandLine.arguments.contains("--ui-test")
    lazy var store = Store(ephemeral: preview)
    var panel: ShelfPanel!
    var status: NSStatusItem!
    var updateMenuItem: NSMenuItem?
    var target: NSRunningApplication?
    var hotkey: EventHotKeyRef?
    var shortcut = GlobalShortcut.load()
    var handler: EventHandlerRef?
    var keyMonitor: Any?
    var outsideClickMonitor: Any?
    var previewWindow: NSWindow?
    var editorWindow: NSWindow?
    var pauseTimer: Timer?
    var settingsWindow: NSWindow?
    var activationObserver: NSObjectProtocol?
    var lastExternalApp: NSRunningApplication?
    var toast: NSPanel?
    var toastGeneration = 0
    var pasteGeneration = 0
    var translationGeneration = 0
    var translationTask: URLSessionDataTask?
    var savedClipboard: [[ClipPart]]?
    var terminationSignals: [DispatchSourceSignal] = []
    var permissionTimer: Timer?
    var modalShowing = false
    func prepareAlert(_ alert: NSAlert) {
        alert.window.level = NSWindow.Level(rawValue: max(panel.level.rawValue, settingsWindow?.level.rawValue ?? 0) + 1)
        let screen = settingsWindow?.screen ?? panel.screen ?? NSScreen.main!
        let frame = screen.visibleFrame
        alert.window.setFrameOrigin(NSPoint(x: frame.midX - alert.window.frame.width / 2, y: frame.midY - alert.window.frame.height / 2))
    }
    func presentAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !modalShowing else { return }
        let parent = previewWindow?.isKeyWindow == true ? previewWindow! : (store.settings && settingsWindow?.isVisible == true ? settingsWindow! : panel!)
        prepareAlert(alert)
        modalShowing = true
        alert.beginSheetModal(for: parent) { [weak self] response in
            self?.modalShowing = false
            completion(response)
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
        let ax = AXIsProcessTrusted()
        let allowed = directPasteAllowed
        let status = allowed ? "已授权" : (ax ? "辅助功能已开，按键权限未生效" : "系统尚未识别授权")
        if store.directPasteAuthorized != allowed { store.directPasteAuthorized = allowed }
        if store.permissionStatus != status { store.permissionStatus = status }
    }
    func applicationDidBecomeActive(_ notification: Notification) { refreshPermission() }
    var directPasteAllowed: Bool {
        if CommandLine.arguments.contains("--ui-test"), CommandLine.arguments.contains("--force-manual") { return false }
        return AXIsProcessTrusted() && CGPreflightPostEventAccess()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Controller.shared = self
        if !preview && !CommandLine.arguments.contains(where: { $0.hasSuffix("-test") }) { UsageAnalytics.shared.start() }
        if let iconURL = Bundle.main.url(forResource: "OpenPaste-v2", withExtension: "icns"), let icon = NSImage(contentsOf: iconURL) { NSApp.applicationIconImage = icon }
        LinkPreviewCache.shared.enabled = store.networkPreviews
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
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","); settingsItem.target = self; appMenu.addItem(settingsItem); appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 OpenPaste", action: #selector(quit), keyEquivalent: "q"); quitItem.target = self; appMenu.addItem(quitItem); let editMenu = NSMenu(title: "编辑")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = editMenu; main.addItem(editItem)
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = main
        if CommandLine.arguments.contains("--translation-workflow-test") { savedClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { ClipPart(type: type.rawValue, data: $0) } } } }
        if preview { store.demo(); store.message = "演示模式 · 使用示例内容 · 不记录真实剪贴板" }
        if CommandLine.arguments.contains("--ui-test") {
            store.archive.clips[3] = fixtureImage()
            savedClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { ClipPart(type: type.rawValue, data: $0) } } }
            let text = "OpenPaste 输入验证：左右选择后按回车，再按 Command-V。"
            store.archive.clips[1].text = text
            store.archive.clips[1].title = "测试粘贴文本"
            store.archive.clips[1].kind = "文字"
            store.archive.clips[1].parts = [[ClipPart(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))]]
        }
        if CommandLine.arguments.contains("--feature-ui-test") {
            let values = ["https://maps.apple.com/?q=Blue%20Bottle%20Coffee&ll=37.7955,-122.3937", "https://www.apple.com/mac/", "#1A2B3C", "Text(store.shortcutNotice.isEmpty ? \"使用组合键\" : store.shortcutNotice).font(.caption).foregroundStyle(.secondary)"]
            store.archive.clips = values.enumerated().map { index, text in Clip(created: Date().addingTimeInterval(-Double(index * 60)), source: "测试内容", sourceID: "com.apple.Maps", kind: text.hasPrefix("http") ? "链接" : (CapturedColor.parse(text) != nil ? "颜色" : "文字"), title: text, text: text, parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(text.utf8))]]) }
            store.archive.clips.append(fixtureOCRImage())
        }
        panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: max(180, UserDefaults.standard.double(forKey: "shelfHeight") == 0 ? 300 : UserDefaults.standard.double(forKey: "shelfHeight"))), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.delegate = self
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.minSize = NSSize(width: 760, height: 180)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = ShelfHost(rootView: ShelfView(store: store))
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.lastExternalApp = app
            self.dismissShelfForExternalInteraction()
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.dismissShelfForExternalInteraction()
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = menuBarMark()
        status.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.addItem(withTitle: "打开剪贴板  \(shortcut.label)", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "暂停 / 继续记录", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        let updateItem = NSMenuItem(title: UpdateChecker.shared.menuTitle, action: #selector(checkUpdatesFromMenu), keyEquivalent: "")
        menu.addItem(updateItem); updateMenuItem = updateItem
        UpdateChecker.shared.onChange = { [weak self] in self?.updateMenuItem?.title = UpdateChecker.shared.menuTitle }
        if !preview { UpdateChecker.shared.start() }
        menu.addItem(withTitle: "退出 OpenPaste", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }; status.menu = menu
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in if Controller.shared?.modalShowing != true, Controller.shared?.store.recordingShortcut != true { Controller.shared?.toggle() }; return noErr }, 1, &spec, nil, &handler)
        _ = installShortcut(shortcut, persist: false)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .flagsChanged {
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                self.store.reverseHistory = !self.modalShowing && self.panel.isKeyWindow && !self.store.settings && !(self.panel.firstResponder is NSTextView) && modifiers == [.command, .shift]
                return event
            }
            if self.store.recordingShortcut, self.settingsWindow?.isKeyWindow == true {
                if event.keyCode == 53 { self.cancelShortcutRecording() }
                else {
                    let candidate = GlobalShortcut.from(event)
                    if candidate.valid { self.store.recordingShortcut = false; if !self.installShortcut(candidate, persist: true) { _ = self.installShortcut(self.shortcut, persist: false, preserveNotice: true) } }
                    else { self.store.shortcutNotice = "请使用 ⌃、⌥ 或 ⇧⌘ 加一个按键；Esc 取消" }
                }
                return nil
            }
            if self.store.settings, self.settingsWindow?.attachedSheet == nil, self.settingsWindow?.isKeyWindow == true, event.keyCode == 53 || (event.keyCode == 13 && event.modifierFlags.contains(.command)) { self.closeSettings(); return nil }
            if self.previewWindow?.isKeyWindow == true, !(self.previewWindow?.firstResponder is NSTextView) {
                if event.keyCode == 49 || event.keyCode == 53 { self.previewWindow?.close(); return nil }
                if event.modifierFlags.contains(.command), let clip = self.store.selectedClips.first {
                    switch event.charactersIgnoringModifiers?.lowercased() { case "e": self.edit(clip); return nil; case "r": self.rename(clip); return nil; case "o": self.openItem(clip); return nil; default: break }
                }
            }
            guard !self.modalShowing, self.panel.isKeyWindow, !self.store.settings else { return event }
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            if event.keyCode == 53 {
                if self.store.searchExpanded {
                    self.store.query = ""; self.store.kind = "全部"; self.store.sourceFilter = "全部来源"; self.store.todayOnly = false; self.store.dateRangeEnabled = false; self.store.filtersExpanded = false
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
            if !(self.panel.firstResponder is NSTextView) {
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                if event.modifierFlags.contains(.command) {
                    if event.keyCode == 36 { self.pasteNext(); return nil }
                    if key == "e", let clip = self.store.selectedClips.first { self.edit(clip); return nil }
                    if key == "r", let clip = self.store.selectedClips.first { self.rename(clip); return nil }
                    if key == "o", let clip = self.store.selectedClips.first { self.openItem(clip); return nil }
                    if key == "n" { if event.modifierFlags.contains(.shift) { self.newBoard() } else { self.createText() }; return nil }
                    if key == "z" { self.store.undoItemChange(); return nil }
                    if key == "t" { if self.store.paused { self.togglePause() } else { self.pauseMenu() }; return nil }
                }
                if event.keyCode == 49, let clip = self.store.selectedClips.first { self.showPreview(clip); return nil }
                if event.keyCode == 48 { self.store.searchFocused = true; return nil }
                if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { }
                else if let chars = event.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), ![36,49,123,124,125,126,48,53,51,117].contains(event.keyCode) { self.store.searchFocused = true; self.store.query += chars; return nil }
            } else if event.keyCode == 48 || event.keyCode == 125 { self.store.searchFocused = false; self.panel.makeFirstResponder(self.panel.contentView); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" { if self.store.searchExpanded { self.store.filtersExpanded.toggle() }; self.store.searchFocused = true; return nil }
            if event.modifierFlags.contains(.command), let n = Int(event.charactersIgnoringModifiers ?? ""), n >= 1, n <= 9, self.store.filtered.count >= n { self.paste(self.store.filtered[n - 1], plain: event.modifierFlags.contains(.shift)); return nil }
            if event.keyCode == 36, let clip = self.store.filtered.first(where: { $0.id == self.store.selected }) ?? self.store.filtered.first { self.pasteSelection(fallback: clip, plain: event.modifierFlags.contains(.shift)); return nil }
            if [123, 124].contains(event.keyCode), self.panel.firstResponder is NSTextView { return event }
            if [123, 124, 125].contains(event.keyCode), !event.modifierFlags.contains(.command) {
                self.store.searchFocused = false
                self.panel.makeFirstResponder(self.panel.contentView)
                if event.keyCode != 125 {
                    let delta = event.keyCode == 124 ? 1 : -1
                    if event.modifierFlags.contains(.shift), let index = self.store.filtered.firstIndex(where: { $0.id == self.store.selected }), !self.store.filtered.isEmpty { let id = self.store.filtered[max(0, min(self.store.filtered.count - 1, index + delta))].id; self.store.choose(id, modifiers: .shift) }
                    else { self.store.moveSelection(delta) }
                }
                return nil
            }
            return event
        }
        if CommandLine.arguments.contains("--shortcut-test") {
            let first = GlobalShortcut(keyCode: 111, modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey), keyName: "F12")
            guard installShortcut(first, persist: true), shortcut == first, store.shortcutLabel == first.label, hotkey != nil else { print("FAIL: custom hotkey registration"); exit(1) }
            var occupied: EventHotKeyRef?
            let second = GlobalShortcut(keyCode: 103, modifiers: first.modifiers, keyName: "F11")
            guard RegisterEventHotKey(second.keyCode, second.modifiers, EventHotKeyID(signature: 0x54455354, id: 2), GetApplicationEventTarget(), 0, &occupied) == noErr else { print("FAIL: prepare conflict test"); exit(1) }
            guard !installShortcut(second, persist: true), shortcut == first, hotkey != nil else { print("FAIL: conflict lost original hotkey"); exit(1) }
            if let occupied = occupied { UnregisterEventHotKey(occupied) }
            show(); openSettings(); beginShortcutRecording()
            guard store.recordingShortcut, hotkey == nil else { print("FAIL: begin recording"); exit(1) }
            cancelShortcutRecording()
            guard !store.recordingShortcut, hotkey != nil, shortcut == first else { print("FAIL: cancel recording did not restore hotkey"); exit(1) }
            beginShortcutRecording(); closeSettings()
            guard !store.recordingShortcut, !store.settings, hotkey != nil else { print("FAIL: close recording did not restore hotkey"); exit(1) }
            print("PASS: global registration, conflict preserves original, cancel and close restore shortcut")
            NSApp.terminate(nil)
        } else if CommandLine.arguments.contains("--layout-test") {
            show()
            let before = panel.frame
            guard let shelfScreen = panel.screen, before.minY == shelfScreen.frame.minY, before.minX == shelfScreen.frame.minX, before.width == shelfScreen.frame.width else { print("FAIL: shelf not flush with screen edges"); exit(1) }
            print("PASS: shelf fills screen width and touches physical bottom")
            openSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard self.panel.frame == before, !self.panel.isVisible else { print("FAIL: settings did not hide shelf or changed geometry"); exit(1) }
                guard let settings = self.settingsWindow, settings.level == .normal else { print("FAIL: settings remains always on top"); exit(1) }
                guard let closeButton = self.settingsWindow?.standardWindowButton(.closeButton), !closeButton.isHidden, closeButton.isEnabled else { print("FAIL: settings close button unavailable"); exit(1) }
                guard let window = self.settingsWindow, window.isVisible, let screen = window.screen, screen.visibleFrame.contains(window.frame) else { print("FAIL: settings outside visible screen"); exit(1) }
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
                NSApp.terminate(nil)
            }
        } else if preview { show(); if CommandLine.arguments.contains("--settings") { openSettings() }; if CommandLine.arguments.contains("--translation-ui-test") { translateSelection("Hello\n    world") } } else if !UserDefaults.standard.bool(forKey: "recordingAccepted") { onboarding() } else { store.start(); if CommandLine.arguments.contains("--settings") { openSettings() } }
    }
    func onboarding() {
        let alert = NSAlert(); alert.messageText = "欢迎使用 OpenPaste"
        alert.informativeText = "启用后，当前剪贴板以及之后复制的文字、链接、图片和文件引用都会保存到这台 Mac。默认跳过已标记的敏感内容和常见密码管理器。普通应用复制的敏感文字仍可能被记录，请按需要暂停或设置排除应用。\n\n默认保存在本机；可在数据管理中选择 iCloud Drive 目录，由系统同步历史。网页预览与快速翻译按各自的设置联网。"
        alert.addButton(withTitle: "启用本地记录"); alert.addButton(withTitle: "暂不启用")
        NSApp.activate()
        if runAlert(alert) == .alertFirstButtonReturn { UserDefaults.standard.set(true, forKey: "recordingAccepted"); store.start() } else { store.paused = true }
        show()
    }
    func showShelf() {
        guard !store.changingDataDirectory else { openSettings(); return }
        if store.settings { closeSettings() }
        let front = NSWorkspace.shared.frontmostApplication
        if let front = front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { target = front; lastExternalApp = front }
        else if target == nil || target?.isTerminated == true { target = lastExternalApp }
        if CommandLine.arguments.contains("--ui-test") { target = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.SwallOwDili.OpenPaste.fixture").first }
        if CommandLine.arguments.contains("--ui-test") { print("UI show target: \(target?.bundleIdentifier ?? "none")"); fflush(stdout) }
        pasteGeneration += 1
        store.board = nil; store.kind = "全部"; store.sourceFilter = "全部来源"; store.todayOnly = false; store.dateRangeEnabled = false; store.filtersExpanded = false; store.query = ""
        if !preview, UserDefaults.standard.bool(forKey: "recordingAccepted") { store.capture(force: true) }
        refreshPermission()
        store.searchFocused = false
        store.searchExpanded = false
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main!
        let r = screen.frame
        let h = min(max(panel.frame.height, 180), r.height * 0.75)
        panel.setFrame(NSRect(x: r.minX, y: r.minY, width: r.width, height: h), display: true)
        store.reverseHistory = false; store.selection.removeAll(); store.compact = h < 270
        store.selected = store.currentClipID ?? store.filtered.first?.id
        panel.makeKeyAndOrderFront(nil); NSApp.activate()
        panel.makeFirstResponder(panel.contentView)
        DispatchQueue.main.async { if self.panel.isKeyWindow, !self.store.searchFocused { self.panel.makeFirstResponder(self.panel.contentView) } }
    }
    func hideShelf() {
        cancelTranslation()
        store.reverseHistory = false
        panel.orderOut(nil)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier, let target = target { NSApp.yieldActivation(to: target); _ = target.activate(options: []) }
    }
    func toggle() { if panel.isVisible && panel.isKeyWindow { hideShelf() } else { show() } }
    @objc func togglePause() {
        if !UserDefaults.standard.bool(forKey: "recordingAccepted"), !preview { onboarding(); return }
        pauseTimer?.invalidate(); pauseTimer = nil
        store.paused.toggle()
        if !store.paused { store.capture(force: true) }
    }
    @objc func openSettings() {
        cancelTranslation()
        store.reverseHistory = false
        panel.orderOut(nil)
        refreshPermission()
        if settingsWindow == nil {
            let screen = panel.screen ?? NSScreen.main!
            let height = min(620, max(260, screen.visibleFrame.height - 100))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(760, screen.visibleFrame.width - 60), height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "OpenPaste 设置"
            window.isReleasedWhenClosed = false
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.closeButton)?.isEnabled = true
            window.level = .normal
            window.delegate = self
            let host = NSHostingView(rootView: SettingsView(store: store))
            host.sizingOptions = []
            window.contentView = host
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
            settingsWindow = window
        }
        store.settings = true
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
        let alert = NSAlert()
        alert.messageText = "OpenPaste \(release.version) 已发布"
        alert.informativeText = "下载后退出 OpenPaste，将新版替换到应用程序目录；历史保留。当前版本未公证，更新后可能需要重新授予辅助功能权限。"
        let notes = NSTextView(frame: NSRect(x: 0, y: 0, width: 430, height: 180))
        notes.string = String((release.body ?? "该版本没有提供更新说明。").prefix(12000))
        notes.isEditable = false
        notes.font = .systemFont(ofSize: 12)
        let scroll = NSScrollView(frame: notes.frame); scroll.hasVerticalScroller = true; scroll.documentView = notes
        alert.accessoryView = scroll
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")
        presentAlert(alert) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.openExternal(url) }
            else if response == .alertThirdButtonReturn { UpdateChecker.shared.skip() }
        }
    }
    func closeSettings() { cancelShortcutRecording(); settingsWindow?.close() }
    func beginShortcutRecording() {
        if store.recordingShortcut { cancelShortcutRecording(); return }
        if let hotkey = hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        store.recordingShortcut = true
        store.shortcutNotice = "现在按下新的组合键，Esc 取消"
        settingsWindow?.makeFirstResponder(nil)
    }
    func cancelShortcutRecording() {
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
            store.shortcutNotice = "\(candidate.label) 无法注册，可能已被占用。原快捷键保持不变。"
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
    func dismissShelfForExternalInteraction() {
        guard panel.isVisible, !modalShowing, panel.attachedSheet == nil,
              previewWindow?.isVisible != true, editorWindow?.isVisible != true, !store.settings else { return }
        cancelTranslation()
        store.reverseHistory = false
        panel.orderOut(nil)
    }
    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panel {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.panel.isKeyWindow else { return }
                let externalApp = NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
                let otherWindow = NSApp.keyWindow.map { $0 !== self.panel } ?? false
                if externalApp || otherWindow { self.dismissShelfForExternalInteraction() }
            }
        }
        if let window = notification.object as? NSWindow, window === settingsWindow { cancelShortcutRecording() }
    }
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        store.compact = window.frame.height < 270
        if !preview { UserDefaults.standard.set(Double(window.frame.height), forKey: "shelfHeight") }
        if let screen = window.screen, abs(window.frame.minY - screen.frame.minY) > 0.5 || abs(window.frame.width - screen.frame.width) > 0.5 { window.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: window.frame.height), display: true) }
    }
    func windowDidBecomeKey(_ notification: Notification) { refreshPermission() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow { cancelShortcutRecording(); store.settings = false }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
        cancelTranslation()
        refreshPermission()
        panel.orderOut(nil)
        pasteGeneration += 1
        let generation = pasteGeneration
        guard let target = target, !target.isTerminated else { showToast("已复制，请回到输入框按 ⌘V"); return }
        if CommandLine.arguments.contains("--ui-test") { print("UI paste target: \(target.bundleIdentifier ?? "none"), AX: \(AXIsProcessTrusted()), event access: \(CGPreflightPostEventAccess())"); fflush(stdout) }
        NSApp.yieldActivation(to: target)
        _ = target.activate(options: [])
        guard store.directPasteAuthorized else { showToast("已复制，按 ⌘V 粘贴 · 自动粘贴需要辅助功能授权"); return }
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
        cancelTranslation()
        closeSettings()
        panel.orderOut(nil)
        toast?.orderOut(nil)
        NSWorkspace.shared.open(url)
    }
    func requestAccessibility() {
        closeSettings()
        panel.orderOut(nil)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openExternal(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func newBoard() {
        let alert = NSAlert(); alert.messageText = "新建收藏板"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.placeholderString = "例如：常用文案"
        alert.accessoryView = field; alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        presentAlert(alert) { [weak self] response in if response == .alertFirstButtonReturn { self?.store.addBoard(field.stringValue) } }
    }
    func edit(_ clip: Clip) {
        if CapturedColor.parse(clip.text) != nil {
            editorWindow?.close(); let window = auxiliaryWindow("编辑颜色", size: NSSize(width: 400, height: 340)); editorWindow = window
            window.contentView = NSHostingView(rootView: ColorEditor(clip: clip, save: { [weak self] hex in var edited = clip; edited.text = hex; edited.title = hex; edited.kind = "颜色"; edited.parts = [[ClipPart(type: "public.utf8-plain-text", data: Data(hex.utf8))]]; edited.cachedDigest = nil; self?.store.replace(edited, label: "颜色") }, close: { [weak self] in self?.editorWindow?.close() })); window.makeKeyAndOrderFront(nil); return
        }
        editorWindow?.close()
        let window = auxiliaryWindow("编辑内容", size: NSSize(width: 700, height: 480)); editorWindow = window
        let editor = NativeEditor(clip: clip, save: { [weak self] rich in
            guard let self else { return }; var edited = clip
            edited.text = rich.string; edited.title = String(rich.string.prefix(100)); edited.kind = CapturedColor.parse(rich.string) != nil ? "颜色" : (URL(string: rich.string)?.scheme?.hasPrefix("http") == true ? "链接" : "文字")
            var parts = [ClipPart(type: "public.utf8-plain-text", data: Data(rich.string.utf8))]
            if let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) { parts.append(ClipPart(type: "public.rtf", data: rtf)) }
            edited.parts = [parts]; edited.cachedDigest = nil; edited.linkTitle = nil
            if store.archive.clips.contains(where: { $0.id == edited.id }) { store.replace(edited, label: "编辑") }
            else if !edited.text.isEmpty, let id = store.ingest(edited) { if id == edited.id { store.undoItems.append(ItemUndo(clips: [], ids: [id], label: "新建")) }; store.choose(id) }
        }, close: { [weak self] in self?.editorWindow?.close() })
        window.contentViewController = editor; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor.text)
    }
    func importPaste(selectFile: Bool = false) {
        guard !store.importingPaste, !store.changingDataDirectory else { return }
        if selectFile {
            let picker = NSOpenPanel(); picker.title = "选择 Paste 数据库"; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
            guard let parent = settingsWindow else { return }
            picker.beginSheetModal(for: parent) { response in if response == .OK, let url = picker.url { self.readPaste(urls: [url]) } }
            picker.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
        } else { readPaste(urls: PasteImport.candidates) }
    }
    private func readPaste(urls: [URL]) {
        store.importingPaste = true
        let existing = store.archive
        store.importProgress = ImportProgress(phase: "准备解析", completed: 0, total: 0)
        let destination = store.root
        let progress: (ImportProgress) -> Void = { update in DispatchQueue.main.async { self.store.importProgress = update } }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PasteImport.read(existing: existing, urls: urls, destination: destination, progress: progress) }
            DispatchQueue.main.async {
                self.store.importingPaste = false
                switch result {
                case .failure(let error):
                    let alert = NSAlert(); alert.messageText = "无法导入 Paste"; alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "好")
                    self.presentAlert(alert) { _ in }
                case .success(let result):
                    let alert = NSAlert(); alert.messageText = "从 Paste 导入"
                    alert.informativeText = result.summary + "\n去重后内容用量：\(ByteCountFormatter.string(fromByteCount: Int64(result.storageBytes), countStyle: .file))。按磁盘可用空间导入，不再设 2 GB 上限。\n\n保留时间、来源、收藏分组和原始格式。原有历史不会删除；导入前会自动备份。文件条目保留引用，原文件需仍然存在。"
                    alert.addButton(withTitle: "导入"); alert.addButton(withTitle: "取消")
                    self.presentAlert(alert) { response in
                        guard response == .alertFirstButtonReturn else { return }
                        self.store.importingPaste = true
                        // Freeze recording during the transactional write, then restore its state.
                        let wasPaused = self.store.paused; self.store.paused = true
                        self.panel.orderOut(nil)
                        let snapshot = self.store.archive; let root = self.store.root
                        self.store.settings = true
                        self.store.importProgress = ImportProgress(phase: "准备导入", completed: 0, total: result.clips.count)
                        self.store.message = "正在保存导入数据…"
                        self.store.persistenceQueue.async {
                            let outcome = Result { try PasteImport.commit(result, snapshot: snapshot, root: root, progress: progress) }
                            DispatchQueue.main.async {
                                switch outcome {
                                case .success(let (merged, added)):
                                    self.store.installImportedArchive(merged)
                                    let omitted = result.unreadable + result.oversized + result.capacity + max(0, result.clips.count - added)
                                    self.store.message = "已导入 \(added) 条；重复 \(result.duplicate) 条；其他跳过 \(omitted) 条。导入前的历史已备份。"
                                case .failure(let error): self.store.message = "导入失败：\(error.localizedDescription)"
                                }
                                self.store.paused = wasPaused; self.store.importingPaste = false
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
    @ObservedObject var store: Store
    @FocusState private var searchFocused: Bool
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
                    TextField("搜索文字、链接或来源", text: $store.query).textFieldStyle(.plain).focused($searchFocused).frame(width: 250)
                    if !store.query.isEmpty { Button { store.query = ""; store.searchFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("清空搜索") }
                    else { Text("⌘F").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    Button { resetSearch(); store.searchExpanded = false; store.searchFocused = false; Controller.shared.panel.makeFirstResponder(Controller.shared.panel.contentView) } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("退出搜索 · Esc")
                }.padding(.horizontal, 12).padding(.vertical, 9)
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
                        .onDrop(of: ["io.github.SwallOwDili.OpenPaste.clip-id"], isTargeted: nil) { providers in
                            if !store.draggingIDs.isEmpty, Date().timeIntervalSince(store.dragStartedAt) < 60 {
                                let ids = store.draggingIDs; store.draggingIDs.removeAll()
                                for id in ids { if let clip = store.archive.clips.first(where: { $0.id == id }), !clip.boards.contains(board.id) { store.pin(clip, to: board.id) } }
                                if CommandLine.arguments.contains("--feature-ui-test") { print("UI board pinned \(ids.count) items"); fflush(stdout) }
                                return true
                            }
                            guard let provider = providers.first else { return false }
                            provider.loadDataRepresentation(forTypeIdentifier: "io.github.SwallOwDili.OpenPaste.clip-id") { data, error in
                                if CommandLine.arguments.contains("--feature-ui-test") { print("UI drop data bytes=\(data?.count ?? -1) error=\(error?.localizedDescription ?? "none")"); fflush(stdout) }
                                guard let data, let string = String(data: data, encoding: .utf8), let id = UUID(uuidString: string) else { return }
                                DispatchQueue.main.async { if let clip = store.archive.clips.first(where: { $0.id == id }), !clip.boards.contains(board.id) { store.pin(clip, to: board.id) } }
                            }; return true
                        }
                        .contextMenu {
                            Menu("更改颜色") {
                                ForEach(["红色", "橙色", "黄色", "绿色", "青色", "蓝色", "紫色", "灰色"], id: \.self) { color in
                                    Button { store.setBoardColor(board.id, color: color) } label: {
                                        Label((board.color ?? "红色") == color ? "✓ " + color : color, systemImage: "circle.fill").foregroundStyle(boardColor(color))
                                    }
                                }
                            }
                            Divider()
                            Button("删除收藏板（保留内容）") { store.removeBoard(board.id) }
                        }
                }
                Button(action: { Controller.shared.newBoard() }) { Image(systemName: "plus") }.buttonStyle(.plain).help("新建收藏板")
                Spacer(minLength: 0)
                Menu {
                    Button("所选加入粘贴队列") { Controller.shared.enqueueSelection() }
                    Button("粘贴队列下一条 · ⌘↵") { Controller.shared.pasteNext() }.disabled(store.pasteQueue.isEmpty)
                    Button("新建文字 · ⌘N") { Controller.shared.createText() }
                    Button("撤销 · ⌘Z") { store.undoItemChange() }.disabled(store.undoItems.isEmpty)
                    Button("设置…") { Controller.shared.openSettings() }
                    Button(store.paused ? "继续记录" : "暂停记录… · ⌘T") { if store.paused { Controller.shared.togglePause() } else { Controller.shared.pauseMenu() } }
                    Divider()
                    Text("← → 选择 · ↵ 粘贴 · ⌘1–9 快速粘贴")
                    Button("关闭 · Esc") { Controller.shared.hideShelf() }
                } label: { Image(systemName: "ellipsis").font(.system(size: 16)).foregroundStyle(.secondary) }.menuStyle(.borderlessButton).fixedSize().help("更多")
            }.padding(.horizontal, 20).padding(.vertical, 12)
            if store.searchExpanded {
            HStack(spacing: 12) {
                ForEach(["全部", "文字", "链接", "图片", "文件", "颜色"], id: \.self) { kind in
                    Button { store.kind = kind } label: { Text(kind).font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5).foregroundStyle(store.kind == kind ? Color.white : Color.secondary).background(store.kind == kind ? Color.blue : Color.clear, in: Capsule()) }.buttonStyle(.plain)
                }
                Button { store.filtersExpanded.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.buttonStyle(.plain).popover(isPresented: $store.filtersExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("筛选历史").font(.headline)
                        Picker("来源", selection: $store.sourceFilter) { Text("全部来源").tag("全部来源"); ForEach(store.sources, id: \.self) { Text($0).tag($0) } }
                        Toggle("按日期范围", isOn: $store.dateRangeEnabled)
                        if store.dateRangeEnabled { DatePicker("开始", selection: $store.startDate, displayedComponents: .date); DatePicker("结束", selection: $store.endDate, in: store.startDate..., displayedComponents: .date) }
                        Button("清除筛选") { resetSearch(); store.dateRangeEnabled = false }
                    }.padding(20).frame(width: 300)
                }
                Divider().frame(height: 12)
                Menu { Button("全部来源") { store.sourceFilter = "全部来源" }; ForEach(store.sources, id: \.self) { source in Button(source) { store.sourceFilter = source } } } label: { Label(store.sourceFilter, systemImage: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
                Button { store.todayOnly.toggle() } label: { Label("今天", systemImage: "calendar").foregroundStyle(store.todayOnly ? Color.blue : Color.secondary) }.buttonStyle(.plain).font(.system(size: 12))
                Spacer()
                Text(store.paused ? "已暂停记录" : (store.query.isEmpty ? "\(store.filtered.count) 条历史" : "找到 \(store.filtered.count) 条结果")).font(.system(size: 12)).foregroundStyle(store.paused ? .orange : .secondary)
            }.padding(.horizontal, 20).padding(.vertical, 8)
            }
            if store.searchExpanded && !store.query.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(store.sources.filter { $0.localizedCaseInsensitiveContains(store.query) }.prefix(3)), id: \.self) { source in Button("应用：" + source) { store.sourceFilter = source; store.query = "" }.buttonStyle(.bordered).controlSize(.small) }
                    if ["今天", "本周", "本月"].contains(store.query) { Button("日期：" + store.query) { let days = store.query == "今天" ? 0 : (store.query == "本周" ? 7 : 30); store.startDate = Date().addingTimeInterval(-Double(days * 86400)); store.endDate = Date(); store.dateRangeEnabled = true; store.query = "" }.buttonStyle(.bordered).controlSize(.small) }
                }.padding(.horizontal, 20)
            }
            if !store.pasteQueue.isEmpty { HStack { Text("粘贴队列剩余 \(store.pasteQueue.count) 条"); Button("下一条 · ⌘↵") { Controller.shared.pasteNext() }; Button("结束") { store.pasteQueue.removeAll() } }.font(.caption) }
            if !store.ocrProgress.isEmpty { Text(store.ocrProgress).font(.caption).foregroundStyle(.secondary) }
            if !store.captureNotice.isEmpty { Text(store.captureNotice).font(.system(size: 12)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 4) }
            if store.filtered.isEmpty {
                VStack(spacing: 10) { Image(systemName: store.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass").font(.system(size: 35)).foregroundStyle(.tertiary); Text(store.query.isEmpty ? "复制一些内容，它们会出现在这里" : "没有找到“\(store.query)”").foregroundStyle(.secondary); Text(store.query.isEmpty ? "\(store.shortcutLabel) 随时打开 · 所有数据保存在本机" : "搜索文字、链接和来源应用；图片文字将在后台识别后加入搜索").font(.system(size: 12)).foregroundStyle(.tertiary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            if store.translating { VStack(spacing: 12) { ProgressView(); Text("正在翻译…"); Text("原文保持不变").font(.caption).foregroundStyle(.secondary) }.frame(width: store.compact ? 180 : 240).frame(maxHeight: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)) }
                            ForEach(Array(store.filtered.enumerated()), id: \.element.id) { index, clip in
                                ClipCard(clip: clip, index: index, selected: store.selection.contains(clip.id) || clip.id == store.selected, current: clip.id == store.currentClipID, store: store).equatable().id(clip.id)
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 8)
                    }.onChange(of: store.selected) { _, id in if let id = id { proxy.scrollTo(id) } }
                }
            }
            if !store.translationStatus.isEmpty { Text(store.translationStatus).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 6) }
            if !store.directPasteAuthorized {
                HStack { Text("↵ 复制后按 ⌘V 粘贴").foregroundStyle(.secondary); Button("开启直接粘贴…") { Controller.shared.openSettings() }.buttonStyle(.plain).foregroundStyle(.blue); Spacer() }.font(.system(size: 11)).padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.2)).frame(height: 1) }
        .onChange(of: store.query) { _, query in if !query.isEmpty { store.indexImages() } }
        .onChange(of: store.searchFocused) { _, focused in
            if focused { store.searchExpanded = true; DispatchQueue.main.async { searchFocused = true } } else { searchFocused = false; if store.query.isEmpty && store.kind == "全部" && store.sourceFilter == "全部来源" && !store.todayOnly { store.searchExpanded = false } }
        }
        .onChange(of: searchFocused) { _, focused in if store.searchFocused != focused { store.searchFocused = focused } }

    }
    func resetSearch() { store.query = ""; store.kind = "全部"; store.sourceFilter = "全部来源"; store.todayOnly = false }
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

struct ClipCard: View, Equatable {
    let clip: Clip
    let index: Int
    let selected: Bool
    let current: Bool
    @ObservedObject var store: Store
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.clip.id == rhs.clip.id && lhs.index == rhs.index && lhs.selected == rhs.selected && lhs.current == rhs.current && lhs.clip.title == rhs.clip.title && lhs.clip.text == rhs.clip.text && lhs.clip.kind == rhs.clip.kind && lhs.clip.boards == rhs.clip.boards && lhs.clip.created == rhs.clip.created && lhs.clip.source == rhs.clip.source && lhs.clip.ocrText == rhs.clip.ocrText && lhs.clip.linkTitle == rhs.clip.linkTitle
    }
    var color: Color { if clip.kind == "文字", CodeSyntax.language(clip.text) != nil { return .purple }; switch clip.kind { case "链接": return .blue; case "图片": return .purple; case "文件": return .orange; default: return .teal } }
    var icon: String { switch clip.kind { case "链接": return "link"; case "图片": return "photo"; case "文件": return "folder"; default: return "text.alignleft" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) { Text(MapLink.parse(clip.text) != nil ? "地图" : (clip.source == "快速翻译" ? "翻译" : (clip.kind == "文字" && CodeSyntax.language(clip.text) != nil ? "代码" : clip.kind))).font(.system(size: 12, weight: .medium)); if current { Text("当前").font(.system(size: 9)).opacity(0.75) }; if !clip.boards.isEmpty { Image(systemName: "pin.fill").font(.system(size: 9)) } }
                    if !store.compact { TimelineView(.periodic(from: .now, by: 60)) { context in Text(ageLabel(clip.created, now: context.date)).font(.system(size: 10)).opacity(0.8) } }
                }
                Spacer()
                if let sourceIcon = PreviewCache.shared.sourceIcon(clip.sourceID) { Image(nsImage: sourceIcon).resizable().frame(width: store.compact ? 20 : 28, height: store.compact ? 20 : 28).help(clip.source) }
                else { Image(systemName: icon).font(.system(size: 20)).opacity(0.6).help(clip.source) }
            }.foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, store.compact ? 5 : 9).background { Rectangle().fill(color.opacity(0.85)) }
            VStack(alignment: .leading, spacing: 9) {
                if clip.kind == "链接" { RichLinkCard(clip: clip, enabled: store.networkPreviews, store: store).id(clip.text) }
                else if let color = CapturedColor.parse(clip.text) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: color.nsColor)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(color.hex).font(.system(size: 16, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                }
                else if clip.kind == "文字", CodeSyntax.language(clip.text) != nil { CodeCardBody(text: clip.text, compact: store.compact) }
                else if clip.kind == "图片" { ClipThumbnail(clip: clip).allowsHitTesting(false) }
                else if clip.kind == "文件", let path = clip.text.components(separatedBy: "\n").first, ["png", "jpg", "jpeg", "tiff", "tif", "heic", "gif", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
                    ClipThumbnail(clip: clip)
                    Text(clip.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).onTapGesture { Controller.shared.rename(clip) }
                }
                else {
                    if clip.kind == "文字" {
                        Text(String(clip.text.prefix(1500))).font(.system(size: 13)).lineLimit(store.compact ? 3 : 8).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(clip.title).font(.system(size: 13)).lineLimit(2).onTapGesture { Controller.shared.rename(clip) }
                        if clip.text != clip.title { Text(String(clip.text.prefix(1500))).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    Spacer(minLength: 0)
                }
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background { Rectangle().fill(clip.kind == "文字" && CodeSyntax.language(clip.text) != nil ? Color(white: 0.14) : Color.clear) }
            if index < 9 { Text("\(index + 1)").font(.system(size: 10)).foregroundStyle(clip.kind == "文字" && CodeSyntax.language(clip.text) != nil ? Color.white.opacity(0.45) : Color.secondary).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 10).padding(.bottom, 7) }
        }
        .frame(width: store.compact ? 180 : 240).frame(maxHeight: .infinity)
        .background(clip.kind == "文字" && CodeSyntax.language(clip.text) != nil ? Color(white: 0.14) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.blue : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Controller.shared.pasteSelection(fallback: clip) }
        .onDrag { let selected = store.selectedClips; store.draggingIDs = selected.contains(where: { $0.id == clip.id }) ? selected.map(\.id) : [clip.id]; store.dragStartedAt = Date(); if CommandLine.arguments.contains("--feature-ui-test") { print("UI drag began kind=\(clip.kind)"); fflush(stdout) }; return clip.dragProvider() }
        .onTapGesture { store.searchFocused = false; store.choose(clip.id, modifiers: NSEvent.modifierFlags); Controller.shared.panel.makeFirstResponder(Controller.shared.panel.contentView) }
        .contextMenu {
            Button("粘贴") { Controller.shared.pasteSelection(fallback: clip) }
            Button("预览 · 空格") { Controller.shared.showPreview(clip) }
            Button("打开 · ⌘O") { Controller.shared.openItem(clip) }
            Button("重命名 · ⌘R") { Controller.shared.rename(clip) }
            if clip.kind == "图片" { Button("旋转图片") { Controller.shared.rotate(clip) }; Button("提取文字") { Controller.shared.extractText(clip) } }
            if let map = MapLink.parse(clip.text) { Button("在地图中打开") { Controller.shared.openExternal(map.url) } }
            Button("仅复制") { _ = store.restore(clip, plain: false); store.message = "已复制" }
            if clip.kind == "文字" || clip.kind == "链接" || clip.kind == "颜色" {
                Button("粘贴为纯文本") { Controller.shared.paste(clip, plain: true) }
                Button("编辑文字…") { Controller.shared.edit(clip) }
            }
            Menu("收藏到") { ForEach(store.archive.boards) { b in Button((clip.boards.contains(b.id) ? "✓ " : "") + b.name) { store.pin(clip, to: b.id) } }; Button("新建收藏板…") { Controller.shared.newBoard() } }
            Divider()
            Button("删除 · ⌘⌫", role: .destructive) { store.delete(clip.id) }
        }
    }
}

if CommandLine.arguments.contains("--update-test") {
    runUpdateTests()
} else if CommandLine.arguments.contains("--maintenance-test") {
    runMaintenanceTests()
} else if CommandLine.arguments.contains("--data-directory-test") {
    runDataDirectoryTests()
} else if CommandLine.arguments.contains("--code-style-test") {
    runCodeStyleTests()
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
