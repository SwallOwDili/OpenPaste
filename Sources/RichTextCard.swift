import AppKit
import SwiftUI

/// Caches the attributed form of rich clips (RTF / HTML) for shelf cards.
/// RTF and attachment reads happen on a background queue; HTML import needs the
/// main thread, so it is size-limited and done once per clip version.
final class RichTextCache {
    static let shared = RichTextCache()
    static let htmlByteLimit = 256 * 1024
    private let cache = NSCache<NSString, NSAttributedString>()
    private var failed = Set<String>()
    private var pending: [String: [(NSAttributedString?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "openpaste.richtext", qos: .userInitiated)
    init() { cache.countLimit = 300 }

    /// Formats apps put on the pasteboard, including the legacy NeXT/Apple names and RTFD.
    static let rtfTypes = ["public.rtf", "NeXT Rich Text Format v1.0 pasteboard type"]
    static let rtfdTypes = ["com.apple.flat-rtfd", "NeXT RTFD pasteboard type"]
    static let htmlTypes = ["public.html", "Apple HTML pasteboard type"]
    static func hasRichPart(_ clip: Clip) -> Bool {
        guard clip.kind == "文字" else { return false }
        let known = Set(rtfTypes + rtfdTypes + htmlTypes)
        return clip.parts.lazy.flatMap { $0 }.contains { known.contains($0.type) }
    }
    /// Characters beyond this are never drawn on a card, so they are not parsed either.
    static func truncated(_ text: NSAttributedString, limit: Int = 1200) -> NSAttributedString {
        text.length > limit ? text.attributedSubstring(from: NSRange(location: 0, length: limit)) : text
    }
    /// True when the attributed text carries formatting worth showing on top of plain text.
    static func hasVisibleFormatting(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { attributes, _, stop in
            if attributes[.link] != nil || attributes[.underlineStyle] != nil || attributes[.strikethroughStyle] != nil || attributes[.backgroundColor] != nil {
                found = true; stop.pointee = true; return
            }
            if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB),
               color.redComponent > 0.1 || color.greenComponent > 0.1 || color.blueComponent > 0.1 { found = true; stop.pointee = true; return }
            if let font = attributes[.font] as? NSFont,
               font.fontDescriptor.symbolicTraits.contains(.bold) || font.fontDescriptor.symbolicTraits.contains(.italic) || abs(font.pointSize - 12) > 3 {
                found = true; stop.pointee = true
            }
        }
        return found
    }
    private func key(_ clip: Clip) -> String { clip.id.uuidString + ":" + clip.fingerprint }

    func cached(_ clip: Clip) -> NSAttributedString? { cache.object(forKey: key(clip) as NSString) }
    func load(_ clip: Clip, completion: @escaping (NSAttributedString?) -> Void) {
        let key = key(clip)
        if let value = cache.object(forKey: key as NSString) { completion(value); return }
        if failed.contains(key) { completion(nil); return }
        if pending[key] != nil { pending[key]?.append(completion); return }
        pending[key] = [completion]
        queue.async { [weak self] in
            let parts = clip.exportParts().flatMap { $0 }
            var result: NSAttributedString?
            func data(_ types: [String]) -> Data? { types.lazy.compactMap { type in parts.first { $0.type == type }?.data }.first }
            if let rtf = data(Self.rtfTypes) { result = NSAttributedString(rtf: rtf, documentAttributes: nil) }
            if result == nil, let rtfd = data(Self.rtfdTypes) { result = NSAttributedString(rtfd: rtfd, documentAttributes: nil) }
            let html = result == nil ? data(Self.htmlTypes) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                if result == nil, let html, html.count <= Self.htmlByteLimit { result = NSAttributedString(html: html, documentAttributes: nil) }
                if let result, result.length > 0 { self.cache.setObject(Self.truncated(result), forKey: key as NSString) } else { self.failed.insert(key) }
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                let value = self.cache.object(forKey: key as NSString)
                callbacks.forEach { $0(value) }
            }
        }
    }
}

/// Prepares attributed text for display on a light page.
enum RichTextRendering {
    static let appearance = NSAppearance(named: .aqua)

    /// Replaces runs whose font resolved to LastResort, the system's placeholder font that draws
    /// every character as a boxed glyph (issue #22: code copied from VSCode). LastResort reports a
    /// glyph for every character, so a glyph-coverage check cannot catch it; it is matched by name.
    /// A document made only of LastResort runs, or whose other runs are fixed-pitch, gets the
    /// monospaced system font; otherwise the system font. Colours, links and paragraph styles stay.
    /// Returns the same object when nothing needs replacing.
    static func repairingFonts(_ source: NSAttributedString) -> NSAttributedString {
        let full = NSRange(location: 0, length: source.length)
        var broken: [(NSRange, CGFloat)] = []
        var proportional = false
        source.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let font = value as? NSFont else { return }
            if font.fontName.hasPrefix("LastResort") { broken.append((range, font.pointSize)) }
            else if !font.isFixedPitch { proportional = true }
        }
        guard !broken.isEmpty else { return source }
        let result = NSMutableAttributedString(attributedString: source)
        for (range, size) in broken {
            let font = proportional ? NSFont.systemFont(ofSize: size) : NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            result.addAttribute(.font, value: font, range: range)
        }
        return result
    }
    /// Prepares a display copy. Clipboard export uses the original representations.
    static func prepare(_ source: NSAttributedString, scale: CGFloat, limit: Int = 30_000) -> NSAttributedString {
        let trimmed = repairingFonts(source.length > limit ? source.attributedSubstring(from: NSRange(location: 0, length: limit)) : source)
        let result = NSMutableAttributedString(attributedString: trimmed)
        let full = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.font, in: full) { value, range, _ in
            guard scale != 1 else { return }
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 13)
            result.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font, range: range)
        }
        if result.length > 0, result.attribute(.font, at: 0, effectiveRange: nil) == nil || scale != 1 {
            result.enumerateAttribute(.font, in: full) { value, range, _ in
                if value == nil { result.addAttribute(.font, value: NSFont.systemFont(ofSize: 13 * scale), range: range) }
            }
        }
        let adjustColors = {
            trimmed.enumerateAttributes(in: full) { attributes, range, _ in
                if let color = readableForeground(for: attributes) {
                    result.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
        }
        if let appearance { appearance.performAsCurrentDrawingAppearance(adjustColors) }
        else { adjustColors() }
        return result
    }

    private static func readableForeground(for attributes: [NSAttributedString.Key: Any]) -> NSColor? {
        var background = SIMD3<Double>(repeating: 1)
        if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
            for block in paragraph.textBlocks { background = composite(block.backgroundColor, over: background) }
        }
        background = composite(attributes[.backgroundColor] as? NSColor, over: background)

        let originalColor = attributes[.foregroundColor] as? NSColor
        let foreground = luminance(composite(originalColor ?? .black, over: background))
        let backdrop = luminance(background)
        let contrast = (max(foreground, backdrop) + 0.05) / (min(foreground, backdrop) + 0.05)
        if contrast >= 4.5 { return originalColor == nil ? .black : nil }
        let blackContrast = (backdrop + 0.05) / 0.05
        let whiteContrast = 1.05 / (backdrop + 0.05)
        return whiteContrast > blackContrast ? .white : .black
    }

    private static func composite(_ color: NSColor?, over background: SIMD3<Double>) -> SIMD3<Double> {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return background }
        let foreground = SIMD3(Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
        let opacity = Double(rgb.alphaComponent)
        return foreground * opacity + background * (1 - opacity)
    }

    private static func luminance(_ color: SIMD3<Double>) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
    }

    /// Plain text styled like a document page.
    static func plain(_ text: String, size: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 3; style.paragraphSpacing = 6
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black, .paragraphStyle: style])
    }
}

/// Applies text once the view has a real width, and only limits lines for text without tables:
/// NSTextTable laid out under maximumNumberOfLines never finishes and freezes the main thread
/// (the card is clipped by its frame and fade mask instead).
final class RichTextScrollView: NSScrollView {
    var pending: NSAttributedString?
    var maximumLines = 0
    override func layout() { super.layout(); applyPending() }
    static func containsTable(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length), options: []) { value, _, stop in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { found = true; stop.pointee = true }
        }
        return found
    }
    func applyPending() {
        guard let text = pending, contentSize.width > 1, let view = documentView as? NSTextView else { return }
        pending = nil
        if view.frame.width < 1 { view.setFrameSize(NSSize(width: contentSize.width, height: max(view.frame.height, 1))) }
        if maximumLines > 0, !Self.containsTable(text) {
            view.textContainer?.maximumNumberOfLines = maximumLines; view.textContainer?.lineBreakMode = .byTruncatingTail
        } else {
            view.textContainer?.maximumNumberOfLines = 0; view.textContainer?.lineBreakMode = .byWordWrapping
        }
        view.textStorage?.setAttributedString(text)
        view.scroll(.zero)
    }
}

/// Read-only rich text, drawn by AppKit so paragraph spacing, line height and links survive
/// (SwiftUI's Text drops paragraph styles). Always renders as a light page.
struct RichTextView: NSViewRepresentable {
    let text: NSAttributedString
    let identity: String
    var scrolls = true
    var inset = NSSize.zero
    var maximumLines = 0

    final class Coordinator { var identity = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = RichTextScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = scrolls; scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.appearance = RichTextRendering.appearance
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = scrolls
        view.drawsBackground = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        scroll.maximumLines = maximumLines
        view.textContainerInset = inset
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.identity != identity, let scroll = scroll as? RichTextScrollView else { return }
        context.coordinator.identity = identity
        scroll.pending = text
        scroll.applyPending()
    }
}

/// Rich card body: the clip's own fonts, colours, spacing and links on a light page,
/// fading out at the bottom instead of being cut off.
struct RichTextCardBody: View {
    let clip: Clip
    let compact: Bool
    @State private var rendered: NSAttributedString?
    @State private var version = ""

    var body: some View {
        Group {
            if let rendered {
                RichTextView(text: rendered, identity: version, scrolls: false, maximumLines: compact ? 6 : 14).allowsHitTesting(false)
            } else {
                Text(String(clip.text.prefix(1500))).font(.system(size: 13)).lineLimit(compact ? 3 : 8).frame(maxWidth: .infinity, alignment: .topLeading)
                    .environment(\.colorScheme, .light).foregroundStyle(Color.black)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .onAppear { if version != clip.fingerprint { load() } }
        .onChange(of: clip.fingerprint) { _, _ in load() }
    }
    private func load() {
        let requested = clip.fingerprint
        version = requested
        RichTextCache.shared.load(clip) { value in
            guard version == requested else { return }
            guard let value, RichTextCache.hasVisibleFormatting(value) else { rendered = nil; return }
            rendered = RichTextRendering.prepare(value, scale: 1)
        }
    }
}
