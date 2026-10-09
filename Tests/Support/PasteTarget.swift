import AppKit

final class PasteTrackingTextView: NSTextView {
    var targetName = ""
    var didPaste: ((String, Bool, [String], String) -> Void)?
    var didCopy: ((Int) -> Void)?

    override func copy(_ sender: Any?) {
        let before = NSPasteboard.general.changeCount
        super.copy(sender)
        let after = NSPasteboard.general.changeCount
        if after != before { didCopy?(after) }
    }

    override func paste(_ sender: Any?) {
        let before = NSAttributedString(attributedString: attributedString())
        let types = Array(Set((NSPasteboard.general.pasteboardItems ?? []).flatMap { item in
            item.types.map(\.rawValue)
        })).sorted()
        super.paste(sender)
        didPaste?(targetName, !attributedString().isEqual(to: before), types, string)
    }
}

private struct ClipboardSnapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]]
}

private func completeClipboardSnapshot(_ pasteboard: NSPasteboard) -> ClipboardSnapshot? {
    let initialChangeCount = pasteboard.changeCount
    guard let sources = pasteboard.pasteboardItems else {
        guard pasteboard.types?.isEmpty != false,
              pasteboard.changeCount == initialChangeCount else { return nil }
        return ClipboardSnapshot(items: [])
    }
    var items: [[(NSPasteboard.PasteboardType, Data)]] = []
    for source in sources {
        guard !source.types.isEmpty else { return nil }
        var parts: [(NSPasteboard.PasteboardType, Data)] = []
        for type in source.types {
            guard let data = source.data(forType: type) else { return nil }
            parts.append((type, data))
        }
        guard !parts.isEmpty else { return nil }
        items.append(parts)
    }
    guard pasteboard.changeCount == initialChangeCount else { return nil }
    return ClipboardSnapshot(items: items)
}

// Standalone acceptance fixture. Does not read OpenPaste history or credentials.
final class Fixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let plain = PasteTrackingTextView()
    let rich = PasteTrackingTextView()
    let status = NSTextField(labelWithString: "粘贴事件：0 · 尚未收到粘贴")
    let eventLog = NSTextView()
    var pasteCount = 0
    private var original: ClipboardSnapshot?
    private var fixtureClipboardChangeCount: Int?
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenPaste-acceptance-target", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        original = completeClipboardSnapshot(.general)
        NSApp.setActivationPolicy(.regular)
        installMenu()
        installWindow()
    }

    private func installMenu() {
        let menu = NSMenu()
        let appTop = NSMenuItem(title: "PasteFixture", action: nil, keyEquivalent: "")
        let application = NSMenu(title: "PasteFixture")
        appTop.submenu = application
        menu.addItem(appTop)
        application.addItem(
            withTitle: "Quit PasteFixture",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editTop = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        editTop.submenu = edit
        menu.addItem(editTop)
        for (name, action, key) in [
            ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"),
            ("Select All", "selectAll:", "a"),
        ] {
            edit.addItem(withTitle: name, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
    }

    private func installWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenPaste 验收目标 · 专用测试内容"
        window.minSize = NSSize(width: 820, height: 620)
        window.isReleasedWhenClosed = false

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        for (index, title) in [
            "复制文字", "复制富文本", "复制颜色", "复制代码", "复制图片", "复制链接", "复制文件",
        ].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(copyFixture(_:)))
            button.tag = index
            buttons.addArrangedSubview(button)
        }

        plain.targetName = "纯文本目标"
        rich.targetName = "富文本目标"
        plain.isRichText = false
        rich.isRichText = true
        plain.setAccessibilityLabel("纯文本粘贴目标")
        rich.setAccessibilityLabel("富文本粘贴目标")
        let pasteRecorder: (String, Bool, [String], String) -> Void = { [weak self] target, changed, types, text in
            self?.recordPaste(target: target, changed: changed, types: types, text: text)
        }
        plain.didPaste = pasteRecorder
        rich.didPaste = pasteRecorder
        let copyRecorder: (Int) -> Void = { [weak self] changeCount in
            self?.fixtureClipboardChangeCount = changeCount
        }
        plain.didCopy = copyRecorder
        rich.didCopy = copyRecorder

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.distribution = .fillEqually
        columns.alignment = .top
        columns.spacing = 12
        for (editor, label) in [(plain, "纯文本目标"), (rich, "富文本目标")] {
            editor.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
            editor.font = .systemFont(ofSize: 18)
            editor.string = "等待测试粘贴"
            editor.isEditable = true
            editor.isSelectable = true
            editor.allowsUndo = true
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isVerticallyResizable = true
            editor.isHorizontallyResizable = false
            editor.autoresizingMask = [.width]
            editor.minSize = NSSize(width: 0, height: 300)
            editor.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            editor.textContainer?.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
            editor.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.documentView = editor
            scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
            let title = NSTextField(labelWithString: label + "（可手工编辑）")
            let copy = NSButton(
                title: "复制此框全部内容",
                target: self,
                action: #selector(copyEditorContents(_:))
            )
            copy.tag = editor === plain ? 100 : 101
            copy.setAccessibilityLabel("复制\(label)全部内容")
            let header = NSStackView(views: [title, copy])
            header.orientation = .horizontal
            header.distribution = .fill
            header.spacing = 8
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let column = NSStackView(views: [header, scroll])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 6
            header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            column.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
            columns.addArrangedSubview(column)
        }

        status.setAccessibilityLabel("粘贴事件状态")
        status.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let prepareTranslation = NSButton(
            title: "准备翻译验收",
            target: self,
            action: #selector(prepareTranslationAcceptance(_:))
        )
        prepareTranslation.setAccessibilityLabel("准备翻译验收")
        let reset = NSButton(title: "清空结果与计数", target: self, action: #selector(resetResults(_:)))
        let statusRow = NSStackView(views: [status, prepareTranslation, reset])
        statusRow.orientation = .horizontal
        statusRow.distribution = .fill
        statusRow.spacing = 12

        eventLog.isEditable = false
        eventLog.isSelectable = true
        eventLog.frame = NSRect(x: 0, y: 0, width: 880, height: 125)
        eventLog.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        eventLog.string = "事件记录会显示目标、剪贴板类型和粘贴后的内容摘要。\n"
        eventLog.setAccessibilityLabel("粘贴事件记录")
        eventLog.isVerticallyResizable = true
        eventLog.autoresizingMask = [.width]
        eventLog.textContainer?.widthTracksTextView = true
        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.documentView = eventLog
        logScroll.heightAnchor.constraint(equalToConstant: 125).isActive = true

        let stack = NSStackView(views: [buttons, columns, statusRow, logScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            columns.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            logScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(plain)
        NSApp.activate()
    }

    @objc private func prepareTranslationAcceptance(_ sender: Any?) {
        let selectedText = "Hello, this is an OpenPaste translation test.\nPlease keep the second line."
        let text = "LEFT-CASE1 | \(selectedText) | RIGHT-CASE1"
        let selectedRange = (text as NSString).range(of: selectedText)

        plain.string = text
        plain.setSelectedRange(selectedRange)
        plain.scrollRangeToVisible(selectedRange)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(plain)

        status.stringValue = "翻译验收已准备 · 应用激活：\(NSApp.isActive ? "是" : "否") · 选区：\(NSStringFromRange(plain.selectedRange()))"
    }

    @objc private func copyEditorContents(_ sender: NSButton) {
        let editor = sender.tag == 100 ? plain : rich
        guard !editor.string.isEmpty else {
            status.stringValue = "粘贴事件：\(pasteCount) · 该输入框为空，未复制"
            window.makeFirstResponder(editor)
            return
        }
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.copy(nil)
        status.stringValue = "粘贴事件：\(pasteCount) · 已复制\(editor.targetName)全部内容"
    }

    @objc func copyFixture(_ button: NSButton) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wrote: Bool
        switch button.tag {
        case 0:
            wrote = pasteboard.setString("OpenPaste acceptance 文本 🙂\nSecond line", forType: .string)
        case 1:
            let text = NSAttributedString(
                string: "Rich acceptance 红色粗体",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 20),
                    .foregroundColor: NSColor.systemRed,
                ]
            )
            let item = NSPasteboardItem()
            item.setString(text.string, forType: .string)
            if let data = try? text.data(
                from: NSRange(location: 0, length: text.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ) {
                item.setData(data, forType: .rtf)
            }
            wrote = pasteboard.writeObjects([item])
        case 2:
            wrote = pasteboard.setString("#1A2B3C", forType: .string)
        case 3:
            wrote = pasteboard.setString(
                "struct Acceptance {\n    let title: String = \"OpenPaste\"\n}",
                forType: .string
            )
        case 4:
            let image = NSImage(size: NSSize(width: 800, height: 300))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 800, height: 300).fill()
            ("OpenPaste OCR 2026" as NSString).draw(
                at: NSPoint(x: 40, y: 150),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 48),
                    .foregroundColor: NSColor.black,
                ]
            )
            image.unlockFocus()
            wrote = pasteboard.writeObjects([image])
        case 5:
            wrote = pasteboard.setString("https://www.apple.com/mac/", forType: .string)
        default:
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("acceptance.txt")
            try? Data("OpenPaste file acceptance".utf8).write(to: file)
            wrote = pasteboard.writeObjects([file as NSURL])
        }

        fixtureClipboardChangeCount = wrote ? pasteboard.changeCount : nil

        let copiedTypes = Array(Set((pasteboard.pasteboardItems ?? []).flatMap { item in
            item.types.map(\.rawValue)
        })).sorted().joined(separator: ", ")
        status.stringValue = "粘贴事件：\(pasteCount) · 已复制夹具 \(button.tag)：\(copiedTypes)"
        window.makeFirstResponder(plain)
        print("Copied fixture type \(button.tag): \(copiedTypes)")
        fflush(stdout)
    }

    private func recordPaste(target: String, changed: Bool, types: [String], text: String) {
        pasteCount += 1
        let outcome = changed ? "内容已变化" : "内容未变化"
        let summary = String(text.replacingOccurrences(of: "\n", with: "↵").prefix(120))
        let typeSummary = types.isEmpty ? "无类型" : types.joined(separator: ", ")
        let line = "#\(pasteCount) \(target) · \(outcome) · [\(typeSummary)] · \(summary)"
        status.stringValue = "粘贴事件：\(pasteCount) · 最近结果：\(target) / \(outcome)"
        eventLog.string += line + "\n"
        eventLog.scrollToEndOfDocument(nil)
        print(line)
        fflush(stdout)
    }

    @objc private func resetResults(_ sender: Any?) {
        pasteCount = 0
        plain.string = ""
        rich.string = ""
        eventLog.string = "事件记录已清空。\n"
        status.stringValue = "粘贴事件：0 · 等待测试粘贴"
        window.makeFirstResponder(plain)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let pasteboard = NSPasteboard.general
        guard let original,
              let fixtureClipboardChangeCount,
              pasteboard.changeCount == fixtureClipboardChangeCount else { return .terminateNow }
        let items = original.items.map { parts in
            let item = NSPasteboardItem()
            parts.forEach { item.setData($0.1, forType: $0.0) }
            return item
        }
        guard pasteboard.changeCount == fixtureClipboardChangeCount else { return .terminateNow }
        pasteboard.clearContents()
        if !items.isEmpty { _ = pasteboard.writeObjects(items) }
        return .terminateNow
    }
}

let app = NSApplication.shared
let fixture = Fixture()
app.delegate = fixture
app.run()
