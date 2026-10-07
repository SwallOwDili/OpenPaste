import AppKit
import SwiftUI
import Vision
import WebKit
import Quartz
import UniformTypeIdentifiers
import ImageIO

struct CapturedColor {
    let hex: String
    var nsColor: NSColor { let n = UInt32(hex.dropFirst(), radix: 16) ?? 0; return NSColor(srgbRed: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255, alpha: 1) }
    static func parse(_ text: String) -> CapturedColor? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^#?[0-9a-fA-F]{6}$", options: .regularExpression) != nil, value.hasPrefix("#") || value.range(of: "[a-fA-F]", options: .regularExpression) != nil else { return nil }
        return CapturedColor(hex: "#" + value.replacingOccurrences(of: "#", with: "").uppercased())
    }
}
struct ItemUndo { var clips: [Clip]; var ids: Set<UUID>; var label: String }
extension Store {
    func enrichLink(_ clip: Clip) {
        LinkPreviewCache.shared.load(clip.text) { [weak self] result in
            guard let self, let result, let i = archive.clips.firstIndex(where: { $0.id == clip.id && $0.text == clip.text }) else { return }
            let metadata = result.title + "\n" + result.subtitle
            if archive.clips[i].linkTitle != metadata { archive.clips[i].linkTitle = metadata; save() }
        }
    }
    var selectedClips: [Clip] { filtered.filter { selection.contains($0.id) || (selection.isEmpty && $0.id == selected) } }
    func choose(_ id: UUID, modifiers: NSEvent.ModifierFlags = []) {
        if modifiers.contains(.command) {
            if selection.isEmpty, let selected { selection.insert(selected) }
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
            selected = selection.contains(id) ? id : filtered.first(where: { selection.contains($0.id) })?.id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor ?? selected, let a = filtered.firstIndex(where: { $0.id == anchor }), let b = filtered.firstIndex(where: { $0.id == id }) {
            selection = Set(filtered[min(a,b)...max(a,b)].map(\.id)); selected = id
        } else { selected = id; selection = [id]; selectionAnchor = id }
    }
    func remember(_ clips: [Clip], label: String) { undoItems.append(ItemUndo(clips: clips, ids: Set(clips.map(\.id)), label: label)); if undoItems.count > 10 { undoItems.removeFirst() } }
    func undoItemChange() {
        guard let undo = undoItems.popLast() else { return }
        archive.clips.removeAll { undo.ids.contains($0.id) }
        archive.clips.append(contentsOf: undo.clips); archive.clips.sort { $0.created > $1.created }
        if let id = deletedCurrentID, undo.ids.contains(id), deletedCurrentChange == change { currentClipID = id }
        selected = undo.clips.first?.id; selection = undo.ids; save(); message = "已撤销\(undo.label)"
    }
    func replace(_ clip: Clip, label: String) {
        guard let i = archive.clips.firstIndex(where: { $0.id == clip.id }), clip.byteCount <= 20 * 1024 * 1024 else { message = "内容超过单条 20 MB 上限"; return }
        remember([archive.clips[i]], label: label); var updated = clip; updated.cachedDigest = updated.fingerprint; archive.clips[i] = updated; save()
    }
    func deleteChosen() { let clips = selectedClips; guard !clips.isEmpty else { return }; remember(clips, label: "删除"); for clip in clips { delete(clip.id, recordUndo: false) }; selection = selected.map { [$0] } ?? [] }
    func restoreMany(_ clips: [Clip], plain: Bool, pasteboard: NSPasteboard = .general) -> Bool {
        guard !clips.isEmpty else { return false }
        if clips.count == 1 { return restore(clips[0], plain: plain, pasteboard: pasteboard) }
        let allText = clips.allSatisfy { !["图片", "文件"].contains($0.kind) && !$0.text.isEmpty }
        if plain || allText {
            guard allText else { message = "图片和文件无法合并为纯文本"; return false }
            let text = clips.map(\.text).joined(separator: "\n")
            let item = NSPasteboardItem(); item.setString(text, forType: .string)
            if !plain {
                let rich = NSMutableAttributedString(string: "")
                for (index, clip) in clips.enumerated() { if index > 0 { rich.append(NSAttributedString(string: "\n")) }; rich.append(clip.attributedText) }
                if let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) { item.setData(rtf, forType: .rtf) }
            }
            change = pasteboard.clearContents(); let ok = pasteboard.writeObjects([item]); change = pasteboard.changeCount; if ok { recordUse(clips) }; return ok
        }
        let items = clips.flatMap(\.parts).map { parts -> NSPasteboardItem in let item = NSPasteboardItem(); for part in parts { item.setData(part.data, forType: NSPasteboard.PasteboardType(part.type)) }; return item }
        pasteboard.clearContents(); let ok = pasteboard.writeObjects(items); change = pasteboard.changeCount; if ok { recordUse(clips) }; return ok
    }
    func indexImages() {
        guard !indexingImages else { return }
        let images = archive.clips.filter { $0.kind == "图片" && $0.ocrText == nil }
        guard !images.isEmpty else { return }
        indexingImages = true; ocrProgress = "识别图片 0 / \(images.count)"
        ocrQueue.async { [weak self] in
            for (index, clip) in images.enumerated() {
                let text: String = autoreleasepool { Self.recognize(clip) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let i = self.archive.clips.firstIndex(where: { $0.id == clip.id && $0.fingerprint == clip.fingerprint }) { self.archive.clips[i].ocrText = text }
                    self.ocrProgress = "识别图片 \(index + 1) / \(images.count)"
                    if index % 25 == 24 { self.save() }
                    if index == images.count - 1 { self.indexingImages = false; self.ocrProgress = ""; self.save() }
                }
            }
        }
    }
    static func recognize(_ clip: Clip) -> String {
        guard let data = clip.parts.flatMap({ $0 }).first(where: { ["public.png", "public.tiff", "public.jpeg", "public.heic"].contains($0.type) })?.data else { return "" }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true; request.recognitionLanguages = ["zh-Hans", "en-US"]
        do { try VNImageRequestHandler(data: data).perform([request]); return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? "" } catch { return "" }
    }
}
extension Clip {
    var attributedText: NSAttributedString {
        let parts = exportParts().flatMap { $0 }
        if let data = parts.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue })?.data, let text = NSAttributedString(rtf: data, documentAttributes: nil) { return text }
        if let data = parts.first(where: { $0.type == NSPasteboard.PasteboardType.html.rawValue })?.data, let text = NSAttributedString(html: data, documentAttributes: nil) { return text }
        return NSAttributedString(string: text)
    }
    func dragProvider() -> NSItemProvider {
        let provider: NSItemProvider
        if kind == "文件", let path = text.components(separatedBy: "\n").first, let file = NSItemProvider(contentsOf: URL(fileURLWithPath: path)) { provider = file } else { provider = NSItemProvider() }
        provider.suggestedName = kind == "图片" ? "OpenPaste-图片.png" : title
        for part in exportParts().flatMap({ $0 }) where UTType(part.type) != nil { provider.registerDataRepresentation(forTypeIdentifier: part.type, visibility: .all) { completion in completion(part.data, nil); return nil } }
        if kind == "图片", let png = parts.flatMap({ $0 }).first(where: { $0.type == "public.png" })?.data {
            provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPaste-drag", isDirectory: true)
                do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); let file = directory.appendingPathComponent(self.id.uuidString + ".png"); try png.write(to: file, options: .atomic); completion(file, false, nil) } catch { completion(nil, false, error) }; return nil
            }
        }
        if kind == "链接" { provider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in completion(Data(self.text.utf8), nil); return nil } }
        provider.registerDataRepresentation(forTypeIdentifier: "io.github.SwallOwDili.OpenPaste.clip-id", visibility: .all) { completion in completion(Data(self.id.uuidString.utf8), nil); return nil }
        return provider
    }
}

struct LinkBrowser: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView { let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); let view = WKWebView(frame: .zero, configuration: configuration); view.load(URLRequest(url: url)); return view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
struct SystemFilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { let view = QLPreviewView(frame: .zero, style: .normal)!; view.previewItem = url as NSURL; return view }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}
struct FullItemPreview: View {
    @ObservedObject var store: Store
    let id: UUID
    var clip: Clip? { store.archive.clips.first { $0.id == id } }
    var body: some View {
        VStack(spacing: 0) {
            if let clip {
                HStack {
                    Text(clip.title).font(.headline).lineLimit(1)
                    Spacer()
                    Button("重命名") { Controller.shared.rename(clip) }
                    if clip.kind == "图片" { Button("旋转") { Controller.shared.rotate(clip) }; Button("提取文字") { Controller.shared.extractText(clip) } }
                    else if clip.kind != "文件" { Button("编辑") { Controller.shared.edit(clip) } }
                    Button("关闭") { Controller.shared.previewWindow?.close() }.keyboardShortcut(.cancelAction)
                }.padding(12)
                Divider()
                if clip.kind == "链接", let url = URL(string: clip.text), LinkPreviewCache.allowed(url) { LinkBrowser(url: url) }
                else if clip.kind == "文件", let path = clip.text.components(separatedBy: "\n").first { SystemFilePreview(url: URL(fileURLWithPath: path)) }
                else if clip.kind == "图片" { FullImagePreview(clip: clip).padding(12) }
                else if clip.kind == "文字", CodeSyntax.language(clip.text) != nil { FullCodePreview(text: clip.text) }
                else { ScrollView { Text(AttributedString(clip.attributedText)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) } }
            } else { Text("该条目已删除") }
        }.frame(minWidth: 640, minHeight: 420)
    }
}
final class NativeEditor: NSViewController {
    let clip: Clip
    let save: (NSAttributedString) -> Void
    let close: () -> Void
    let text = NSTextView()
    init(clip: Clip, save: @escaping (NSAttributedString) -> Void, close: @escaping () -> Void) { self.clip = clip; self.save = save; self.close = close; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 480))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        if #available(macOS 15.0, *) { text.writingToolsBehavior = .complete }
        text.isRichText = true; text.isEditable = true; text.allowsUndo = true; text.isAutomaticQuoteSubstitutionEnabled = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width: 16, height: 16)
        text.textStorage?.setAttributedString(clip.attributedText); scroll.documentView = text
        let saveButton = NSButton(title: "保存", target: self, action: #selector(commit)); saveButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEdit)); cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, saveButton]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [scroll, buttons]); stack.orientation = .vertical; stack.alignment = .trailing; stack.spacing = 12; stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor), stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24)])
    }
    @objc func commit() { save(NSAttributedString(attributedString: text.textStorage ?? NSTextStorage())); close() }
    @objc func cancelEdit() { close() }
}
extension Controller {
    func auxiliaryWindow(_ title: String, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.level = NSWindow.Level(rawValue: panel.level.rawValue + 1); window.isReleasedWhenClosed = false; window.center(); window.delegate = self; return window
    }
    func showPreview(_ clip: Clip) {
        previewWindow?.close(); let window = auxiliaryWindow("内容预览", size: NSSize(width: 820, height: 580)); previewWindow = window
        window.contentView = NSHostingView(rootView: FullItemPreview(store: store, id: clip.id)); window.makeKeyAndOrderFront(nil)
    }
    func openItem(_ clip: Clip) { if let url = URL(string: clip.text), clip.kind == "链接" { openExternal(url) } else if clip.kind == "文件", let path = clip.text.components(separatedBy: "\n").first { openExternal(URL(fileURLWithPath: path)) } else { showPreview(clip) } }
    func rename(_ clip: Clip) {
        let alert = NSAlert(); alert.messageText = "重命名内容"; let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); field.stringValue = clip.title; alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = field
        presentAlert(alert) { [weak self] response in guard response == .alertFirstButtonReturn, let self else { return }; var edited = clip; edited.title = field.stringValue; edited.userLabel = field.stringValue; store.replace(edited, label: "重命名") }
    }
    func createText() { var clip = Clip(source: "OpenPaste", sourceID: Bundle.main.bundleIdentifier ?? "", kind: "文字", title: "新建文字", text: "", parts: []); clip.parts = [[ClipPart(type: "public.utf8-plain-text", data: Data())]]; edit(clip) }
    func rotate(_ clip: Clip) {
        store.captureQueue.async { [weak self] in
            guard let part = ImageTools.rotated(clip) else { return }
            var edited = clip; edited.parts = [[part]]; edited.ocrText = nil; edited.cachedDigest = nil
            DispatchQueue.main.async { self?.store.replace(edited, label: "旋转"); PreviewCache.shared.images.removeObject(forKey: clip.id.uuidString as NSString) }
        }
    }
    func extractText(_ clip: Clip) {
        showToast("正在识别图片文字…")
        store.ocrQueue.async { [weak self] in
            let text = Store.recognize(clip)
            DispatchQueue.main.async {
                guard let self else { return }
                if text.isEmpty { self.showToast("没有识别到文字"); return }
                var extracted = Clip(source: clip.source, sourceID: clip.sourceID, kind: "文字", title: String(text.prefix(100)), text: text, parts: [[ClipPart(type: "public.utf8-plain-text", data: Data(text.utf8))]])
                extracted.boards = clip.boards; _ = self.store.ingest(extracted); self.store.choose(extracted.id); self.edit(extracted)
            }
        }
    }
    func enqueueSelection() { store.pasteQueue = store.selectedClips.map(\.id) }
    func pasteNext() {
        while let id = store.pasteQueue.first { store.pasteQueue.removeFirst(); if let clip = store.archive.clips.first(where: { $0.id == id }) { paste(clip); return } }
        showToast("粘贴队列已完成")
    }
    func pauseFor(_ minutes: Int?) {
        pauseTimer?.invalidate(); pauseTimer = nil; store.paused = true
        if let minutes { pauseTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: false) { [weak self] _ in self?.store.paused = false; self?.store.capture(force: true); self?.pauseTimer = nil } }
    }
    func pauseMenu() {
        let alert = NSAlert(); alert.messageText = "暂停记录"; for name in ["5 分钟", "15 分钟", "1 小时", "直到手动恢复", "取消"] { alert.addButton(withTitle: name) }
        presentAlert(alert) { [weak self] response in let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue; guard index >= 0 && index < 4 else { return }; self?.pauseFor([5,15,60,nil][index]) }
    }
    func resizeShelf(_ height: CGFloat) { guard let screen = panel.screen else { return }; let frame = screen.frame; let height = min(max(height, 180), frame.height * 0.75); panel.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: height), display: true); store.compact = height < 270; if !preview { UserDefaults.standard.set(Double(height), forKey: "shelfHeight") } }
}

struct FullImagePreview: View {
    let clip: Clip
    @State var image: NSImage?
    @State var zoom: Double = 1
    var body: some View {
        VStack {
            if let image { GeometryReader { geometry in ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(width: max(100, geometry.size.width * zoom), height: max(100, geometry.size.height * zoom)) } } }
            else { ProgressView() }
            HStack { Text("缩放"); Slider(value: $zoom, in: 1...4); Text("\(Int(zoom * 100))%").monospacedDigit() }.frame(maxWidth: 400)
        }.task(id: clip.cachedDigest) {
            let data = clip.parts.flatMap { $0 }.first { ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.gif"].contains($0.type) }?.data
            image = await withCheckedContinuation { continuation in DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: data.flatMap { NSImage(data: $0) }) } }
        }
    }
}

struct ColorEditor: View {
    let clip: Clip
    let save: (String) -> Void
    let close: () -> Void
    @State var color: Color
    init(clip: Clip, save: @escaping (String) -> Void, close: @escaping () -> Void) { self.clip = clip; self.save = save; self.close = close; _color = State(initialValue: Color(nsColor: CapturedColor.parse(clip.text)?.nsColor ?? .white)) }
    var hex: String { let c = NSColor(color).usingColorSpace(.sRGB) ?? .white; return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255))) }
    var body: some View {
        VStack(spacing: 20) { RoundedRectangle(cornerRadius: 12).fill(color).frame(height: 160); ColorPicker("颜色", selection: $color, supportsOpacity: false); Text(hex).font(.title2.monospaced()); HStack { Button("取消", action: close); Button("保存") { save(hex); close() }.keyboardShortcut(.defaultAction) } }.padding(24).frame(width: 360)
    }
}

enum ImageTools {
    static func rotated(_ clip: Clip) -> ClipPart? {
        guard let data = clip.parts.flatMap({ $0 }).first(where: { ["public.png", "public.tiff", "public.jpeg", "public.heic"].contains($0.type) })?.data, let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: image.height * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: CGFloat(image.height), y: 0); context.rotate(by: .pi / 2); context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rotated = context.makeImage() else { return nil }
        let output = NSMutableData(); guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, rotated, nil); guard CGImageDestinationFinalize(destination) else { return nil }; return ClipPart(type: "public.png", data: output as Data)
    }
}
